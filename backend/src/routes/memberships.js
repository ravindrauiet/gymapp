import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { HttpError, badRequest, conflict, notFound, validate } from '../utils/http.js';
import { VENUE_CATEGORY_IDS } from '../utils/constants.js';
import { notify } from '../utils/notify.js';
import { dateSchema, uuidSchema } from '../utils/schemas.js';
import { nowInTz, ownVenue, payoutRatePaise, venueCoinCost } from './bookings.js';

/**
 * BRD §2 — a centre's own (direct) membership plans: partners create them (admin approves), members buy them and
 * then book / check in at THAT centre for free within the plan's slot limits. FitKey takes a commission on each sale
 * (per centre → per category → default). Payments are mock (PAYMENTS_MODE=mock); memberships are non-refundable.
 */
const router = Router();

// Configurable defaults.
export const MEMBERSHIP_DEFAULTS = {
  commissionPct: 15, // FitKey commission on direct membership sales when no centre/category value is set
  maxStartAheadDays: 60, // a membership can start up to 60 days from today
};
export const DURATION_DAYS = { day: 1, monthly: 30, quarterly: 90, annual: 365 };
export const DURATION_LABELS = { day: 'Day pass', monthly: 'Monthly', quarterly: 'Quarterly', annual: 'Annual' };

const priceAfterOffer = (pricePaise, offerPct) => Math.round((pricePaise * (100 - (offerPct ?? 0))) / 100);

/** Commission % for a venue: centre override → its first category → default. */
async function commissionPctFor(venueId, client) {
  const r = await queryOne(
    `SELECT COALESCE(v.commission_pct, (SELECT commission_pct FROM category_commissions WHERE category = v.categories[1]), $2)
              AS pct
     FROM venues v WHERE v.id = $1`,
    [venueId, MEMBERSHIP_DEFAULTS.commissionPct],
    client,
  );
  return Number(r?.pct ?? MEMBERSHIP_DEFAULTS.commissionPct);
}

const PLAN_FIELDS = `p.id, p.venue_id, p.name, p.description, p.duration, p.duration_days, p.price_paise, p.inclusions,
  p.max_visits_per_day, p.max_visits_per_week, p.offer_pct,
  ROUND(p.price_paise * (100 - p.offer_pct) / 100.0)::int AS effective_price_paise,
  p.is_active, p.approval_status, p.review_note, p.reviewed_at, p.created_at, p.updated_at`;

const planBody = z
  .object({
    name: z.string().trim().min(2).max(120),
    description: z.string().trim().max(1000).optional().nullable(),
    duration: z.enum(['day', 'monthly', 'quarterly', 'annual']),
    pricePaise: z.number().int().min(100).max(10_000_000),
    inclusions: z.array(z.string().trim().min(1).max(80)).max(20).default([]),
    maxVisitsPerDay: z.number().int().min(1).max(10).optional().nullable(),
    maxVisitsPerWeek: z.number().int().min(1).max(70).optional().nullable(),
    offerPct: z.number().int().min(0).max(90).default(0),
    isActive: z.boolean().default(true),
  })
  .strict();

// ---------------------------------------------------------------------------------------------------------------
// Admin (FitKey team)
// ---------------------------------------------------------------------------------------------------------------
const admin = Router();
admin.use(requireAuth('admin'));
router.use('/admin', admin);

/** GET /memberships/admin/plans?status=pending|approved|rejected|all — centre plans to review. */
admin.get('/plans', async (req, res) => {
  const { status } = validate(z.object({ status: z.enum(['pending', 'approved', 'rejected', 'all']).default('pending') }), req.query);
  const plans = await query(
    `SELECT ${PLAN_FIELDS}, v.name AS venue_name, v.city AS venue_city, v.status AS venue_status, u.name AS owner_name,
            (SELECT COUNT(*) FROM direct_memberships m WHERE m.plan_id = p.id) AS sold
     FROM centre_plans p JOIN venues v ON v.id = p.venue_id JOIN users u ON u.id = v.owner_id
     WHERE p.archived_at IS NULL AND ($1 = 'all' OR p.approval_status = $1)
     ORDER BY p.updated_at DESC LIMIT 200`,
    [status],
  );
  res.json({ plans });
});

/** PATCH /memberships/admin/plans/:id/review {status: approved|rejected, note?} */
admin.patch('/plans/:id/review', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const { status, note } = validate(
    z.object({ status: z.enum(['approved', 'rejected']), note: z.string().trim().max(500).optional() }),
    req.body,
  );
  if (status === 'rejected' && !note) throw badRequest('Add a note telling the centre why the plan was rejected');
  const plan = await queryOne(
    `UPDATE centre_plans SET approval_status = $2, review_note = $3, reviewed_at = now()
     WHERE id = $1 AND archived_at IS NULL RETURNING id, venue_id, name`,
    [id, status, note ?? null],
  );
  if (!plan) throw notFound('Plan not found');
  const v = await queryOne(`SELECT owner_id, name FROM venues WHERE id = $1`, [plan.venueId]);
  await notify(v.ownerId, {
    type: 'membership_plan',
    title: status === 'approved' ? `Plan approved: ${plan.name}` : `Plan needs changes: ${plan.name}`,
    body: status === 'approved' ? `Members can now buy it at ${v.name}.` : note,
    data: { planId: plan.id, venueId: plan.venueId },
  });
  res.json({ plan: { ...plan, approvalStatus: status, reviewNote: note ?? null } });
});

/**
 * GET /memberships/admin/settings — commission (default, per category, per centre), visit payout rate and slot
 * capacity per centre, with the effective values.
 */
admin.get('/settings', async (_req, res) => {
  const cats = await query(`SELECT category, commission_pct FROM category_commissions`);
  const catMap = Object.fromEntries(cats.map((c) => [c.category, Number(c.commissionPct)]));
  let coinCosts = {};
  try {
    const rows = await query(`SELECT category, coins FROM visit_category_costs`);
    coinCosts = Object.fromEntries(rows.map((r) => [r.category, r.coins]));
  } catch {
    /* wallet tables not there yet */
  }
  const venues = await query(
    `SELECT id, name, city, area, categories, status, slot_capacity, visit_payout_paise, commission_pct
     FROM venues WHERE status IN ('live', 'submitted', 'under_review') ORDER BY status = 'live' DESC, name LIMIT 500`,
  );
  for (const v of venues) {
    v.commissionPct = v.commissionPct == null ? null : Number(v.commissionPct);
    v.effectiveCommissionPct = v.commissionPct ?? catMap[v.categories[0]] ?? MEMBERSHIP_DEFAULTS.commissionPct;
    v.coinCost = await venueCoinCost(v.id);
    v.effectivePayoutPaise = v.visitPayoutPaise ?? v.coinCost * 100;
  }
  res.json({
    defaultCommissionPct: MEMBERSHIP_DEFAULTS.commissionPct,
    categories: VENUE_CATEGORY_IDS.map((c) => ({ category: c, commissionPct: catMap[c] ?? null, coinCost: coinCosts[c] ?? null })),
    venues,
  });
});

/** PUT /memberships/admin/categories/:category/commission {commissionPct: number|null} — null = use the default. */
admin.put('/categories/:category/commission', async (req, res) => {
  const category = validate(z.enum(VENUE_CATEGORY_IDS), req.params.category);
  const { commissionPct } = validate(z.object({ commissionPct: z.number().min(0).max(100).nullable() }), req.body);
  if (commissionPct == null) await query(`DELETE FROM category_commissions WHERE category = $1`, [category]);
  else {
    await query(
      `INSERT INTO category_commissions (category, commission_pct) VALUES ($1, $2)
       ON CONFLICT (category) DO UPDATE SET commission_pct = EXCLUDED.commission_pct, updated_at = now()`,
      [category, commissionPct],
    );
  }
  res.json({ category, commissionPct });
});

/** PATCH /memberships/admin/venues/:id/settings {commissionPct?, visitPayoutPaise?, slotCapacity?} (null = default). */
admin.patch('/venues/:id/settings', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const body = validate(
    z
      .object({
        commissionPct: z.number().min(0).max(100).nullable().optional(),
        visitPayoutPaise: z.number().int().min(0).max(10_000_000).nullable().optional(),
        slotCapacity: z.number().int().min(1).max(1000).optional(),
      })
      .strict(),
    req.body,
  );
  const sets = [];
  const params = [id];
  const map = { commissionPct: 'commission_pct', visitPayoutPaise: 'visit_payout_paise', slotCapacity: 'slot_capacity' };
  for (const [k, col] of Object.entries(map)) {
    if (body[k] !== undefined) {
      params.push(body[k]);
      sets.push(`${col} = $${params.length}`);
    }
  }
  if (!sets.length) throw badRequest('Nothing to update');
  const venue = await queryOne(
    `UPDATE venues SET ${sets.join(', ')} WHERE id = $1 RETURNING id, name, slot_capacity, visit_payout_paise, commission_pct`,
    params,
  );
  if (!venue) throw notFound('Venue not found');
  res.json({ venue });
});

/** GET /memberships/admin/sales?month=YYYY-MM — direct membership sales with FitKey commission. */
admin.get('/sales', async (req, res) => {
  const { month } = validate(z.object({ month: z.string().regex(/^\d{4}-\d{2}$/).optional() }), req.query);
  const sales = await query(
    `WITH m AS (SELECT COALESCE($1::date, date_trunc('month', now() AT TIME ZONE $2)::date) AS s)
     SELECT d.id, d.plan_name, d.duration, d.starts_on, d.ends_on, d.amount_paise, d.commission_pct, d.commission_paise,
            d.created_at, v.name AS venue_name, u.name AS member_name, RIGHT(u.phone, 4) AS phone_last4
     FROM m, direct_memberships d JOIN venues v ON v.id = d.venue_id JOIN users u ON u.id = d.user_id
     WHERE (d.created_at AT TIME ZONE $2)::date >= m.s AND (d.created_at AT TIME ZONE $2)::date < (m.s + interval '1 month')::date
     ORDER BY d.created_at DESC LIMIT 500`,
    [month ? `${month}-01` : null, config.tz],
  );
  const totals = sales.reduce(
    (t, s) => ({ count: t.count + 1, grossPaise: t.grossPaise + s.amountPaise, commissionPaise: t.commissionPaise + s.commissionPaise }),
    { count: 0, grossPaise: 0, commissionPaise: 0 },
  );
  res.json({ month: month ?? null, totals, sales });
});

// ---------------------------------------------------------------------------------------------------------------
// Partner (venue owner) — ownership via venues.owner_id
// ---------------------------------------------------------------------------------------------------------------
const partner = Router();
partner.use(requireAuth('partner'));
router.use('/partner', partner);

async function ownPlan(planId, ownerId) {
  const id = validate(uuidSchema, planId);
  const plan = await queryOne(
    `SELECT p.*, v.owner_id FROM centre_plans p JOIN venues v ON v.id = p.venue_id WHERE p.id = $1 AND p.archived_at IS NULL`,
    [id],
  );
  if (!plan || plan.ownerId !== ownerId) throw notFound('Plan not found');
  return plan;
}

const planOut = (id) =>
  queryOne(
    `SELECT ${PLAN_FIELDS},
            (SELECT COUNT(*) FROM direct_memberships m WHERE m.plan_id = p.id) AS sold,
            (SELECT COUNT(*) FROM direct_memberships m WHERE m.plan_id = p.id AND m.status = 'active'
               AND (now() AT TIME ZONE $2)::date BETWEEN m.starts_on AND m.ends_on) AS active_members
     FROM centre_plans p WHERE p.id = $1`,
    [id, config.tz],
  );

/** GET /memberships/partner/venues/:venueId/plans — the centre's plans with approval status and sales. */
partner.get('/venues/:venueId/plans', async (req, res) => {
  const venue = await ownVenue(req.params.venueId, req.user.id);
  const plans = await query(
    `SELECT ${PLAN_FIELDS},
            (SELECT COUNT(*) FROM direct_memberships m WHERE m.plan_id = p.id) AS sold,
            (SELECT COUNT(*) FROM direct_memberships m WHERE m.plan_id = p.id AND m.status = 'active'
               AND (now() AT TIME ZONE $2)::date BETWEEN m.starts_on AND m.ends_on) AS active_members
     FROM centre_plans p WHERE p.venue_id = $1 AND p.archived_at IS NULL ORDER BY p.price_paise`,
    [venue.id, config.tz],
  );
  res.json({ plans, commissionPct: await commissionPctFor(venue.id) });
});

/** POST /memberships/partner/venues/:venueId/plans — new plan, pending FitKey approval. */
partner.post('/venues/:venueId/plans', async (req, res) => {
  const venue = await ownVenue(req.params.venueId, req.user.id);
  const b = validate(planBody, req.body);
  const row = await queryOne(
    `INSERT INTO centre_plans (venue_id, name, description, duration, duration_days, price_paise, inclusions,
                               max_visits_per_day, max_visits_per_week, offer_pct, is_active)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING id`,
    [venue.id, b.name, b.description ?? null, b.duration, DURATION_DAYS[b.duration], b.pricePaise, b.inclusions,
      b.maxVisitsPerDay ?? null, b.maxVisitsPerWeek ?? null, b.offerPct, b.isActive],
  );
  res.status(201).json({ plan: await planOut(row.id) });
});

/** PUT /memberships/partner/plans/:id — edit a plan (goes back to pending approval). Sold memberships keep their terms. */
partner.put('/plans/:id', async (req, res) => {
  const plan = await ownPlan(req.params.id, req.user.id);
  const b = validate(planBody, req.body);
  await query(
    `UPDATE centre_plans SET name = $2, description = $3, duration = $4, duration_days = $5, price_paise = $6, inclusions = $7,
       max_visits_per_day = $8, max_visits_per_week = $9, offer_pct = $10, is_active = $11,
       approval_status = 'pending', review_note = NULL, reviewed_at = NULL, updated_at = now()
     WHERE id = $1`,
    [plan.id, b.name, b.description ?? null, b.duration, DURATION_DAYS[b.duration], b.pricePaise, b.inclusions,
      b.maxVisitsPerDay ?? null, b.maxVisitsPerWeek ?? null, b.offerPct, b.isActive],
  );
  res.json({ plan: await planOut(plan.id) });
});

/** PATCH /memberships/partner/plans/:id/active {isActive} — switch a plan on/off (no re-approval). */
partner.patch('/plans/:id/active', async (req, res) => {
  const plan = await ownPlan(req.params.id, req.user.id);
  const { isActive } = validate(z.object({ isActive: z.boolean() }), req.body);
  await query(`UPDATE centre_plans SET is_active = $2, updated_at = now() WHERE id = $1`, [plan.id, isActive]);
  res.json({ plan: await planOut(plan.id) });
});

/** PATCH /memberships/partner/plans/:id/offer {offerPct: 0–90} — discount shown to members (no re-approval). */
partner.patch('/plans/:id/offer', async (req, res) => {
  const plan = await ownPlan(req.params.id, req.user.id);
  const { offerPct } = validate(z.object({ offerPct: z.number().int().min(0).max(90) }), req.body);
  await query(`UPDATE centre_plans SET offer_pct = $2, updated_at = now() WHERE id = $1`, [plan.id, offerPct]);
  res.json({ plan: await planOut(plan.id) });
});

/** DELETE /memberships/partner/plans/:id — removes the plan from sale (archived; members keep what they bought). */
partner.delete('/plans/:id', async (req, res) => {
  const plan = await ownPlan(req.params.id, req.user.id);
  await query(`UPDATE centre_plans SET archived_at = now(), is_active = false, updated_at = now() WHERE id = $1`, [plan.id]);
  res.status(204).end();
});

/**
 * GET /memberships/partner/venues/:venueId/members?status=active|upcoming|expired|all — direct members with validity
 * (separate from FitKey-pass visitors).
 */
partner.get('/venues/:venueId/members', async (req, res) => {
  const venue = await ownVenue(req.params.venueId, req.user.id);
  const { status } = validate(z.object({ status: z.enum(['active', 'upcoming', 'expired', 'all']).default('active') }), req.query);
  const members = await query(
    `SELECT * FROM (
       SELECT d.id, d.user_id, u.name AS member_name, RIGHT(u.phone, 4) AS phone_last4, d.plan_id, d.plan_name, d.duration,
              d.starts_on, d.ends_on, d.amount_paise, d.commission_paise, d.max_visits_per_day, d.max_visits_per_week, d.created_at,
              CASE WHEN d.status = 'cancelled' THEN 'cancelled'
                   WHEN t.today < d.starts_on THEN 'upcoming'
                   WHEN t.today > d.ends_on THEN 'expired' ELSE 'active' END AS state,
              GREATEST(0, d.ends_on - t.today + 1) AS days_left,
              (SELECT COUNT(*) FROM checkins c WHERE c.membership_id = d.id) AS visits,
              (SELECT MAX(c.checked_in_at) FROM checkins c WHERE c.membership_id = d.id) AS last_visit_at
       FROM direct_memberships d JOIN users u ON u.id = d.user_id,
            (SELECT (now() AT TIME ZONE $2)::date AS today) t
       WHERE d.venue_id = $1) x
     WHERE $3 = 'all' OR x.state = $3
     ORDER BY x.ends_on DESC LIMIT 500`,
    [venue.id, config.tz, status],
  );
  res.json({ count: members.length, members });
});

/**
 * GET /memberships/partner/venues/:venueId/fitkey-visitors?from=&to= — members who visited on a FitKey pass
 * (coins / session / legacy), with visit counts and payout, default: current month.
 */
partner.get('/venues/:venueId/fitkey-visitors', async (req, res) => {
  const venue = await ownVenue(req.params.venueId, req.user.id);
  const f = validate(z.object({ from: dateSchema.optional(), to: dateSchema.optional() }), req.query);
  const t = await nowInTz();
  const from = f.from ?? `${t.today.slice(0, 7)}-01`;
  const to = f.to ?? t.today;
  const visitors = await query(
    `SELECT u.id AS user_id, u.name AS member_name, RIGHT(u.phone, 4) AS phone_last4, COUNT(*) AS visits,
            COUNT(*) FILTER (WHERE COALESCE(c.paid_via, 'legacy') = 'coins') AS coins_visits,
            COUNT(*) FILTER (WHERE c.paid_via = 'session') AS session_visits,
            COUNT(*) FILTER (WHERE COALESCE(c.paid_via, 'legacy') = 'legacy') AS legacy_visits,
            COALESCE(SUM(p.amount_paise), 0) AS payout_paise, MAX(c.checked_in_at) AS last_visit_at
     FROM checkins c JOIN users u ON u.id = c.user_id LEFT JOIN visit_payouts p ON p.checkin_id = c.id
     WHERE c.venue_id = $1 AND c.checkin_date BETWEEN $2 AND $3 AND COALESCE(c.paid_via, 'legacy') IN ('coins', 'session', 'legacy')
     GROUP BY u.id ORDER BY visits DESC, last_visit_at DESC LIMIT 500`,
    [venue.id, from, to],
  );
  res.json({ from, to, count: visitors.length, visitors });
});

/** Earnings for venues over [from, to): direct membership sales minus commission + FitKey-pass visit payouts. */
async function earningsFor(venueIds, month) {
  return query(
    `WITH months AS (
       SELECT to_char(d, 'YYYY-MM') AS month, d::date AS s, (d + interval '1 month')::date AS e
       FROM generate_series($2::date, $3::date, interval '1 month') d
     )
     SELECT m.month,
            COALESCE(ms.count, 0) AS memberships_sold, COALESCE(ms.gross, 0) AS membership_gross_paise,
            COALESCE(ms.commission, 0) AS commission_paise, COALESCE(ms.gross, 0) - COALESCE(ms.commission, 0) AS membership_net_paise,
            COALESCE(vp.count, 0) AS fitkey_visits, COALESCE(vp.total, 0) AS visit_payout_paise,
            COALESCE(vp.coins, 0) AS coins_visits, COALESCE(vp.session, 0) AS session_visits, COALESCE(vp.legacy, 0) AS legacy_visits,
            COALESCE(mv.count, 0) AS membership_visits,
            COALESCE(ms.gross, 0) - COALESCE(ms.commission, 0) + COALESCE(vp.total, 0) AS total_payable_paise
     FROM months m
     LEFT JOIN LATERAL (
       SELECT COUNT(*) AS count, SUM(amount_paise) AS gross, SUM(commission_paise) AS commission FROM direct_memberships
       WHERE venue_id = ANY($1) AND (created_at AT TIME ZONE $4)::date >= m.s AND (created_at AT TIME ZONE $4)::date < m.e
     ) ms ON true
     LEFT JOIN LATERAL (
       SELECT COUNT(*) AS count, SUM(amount_paise) AS total,
              COUNT(*) FILTER (WHERE paid_via = 'coins') AS coins, COUNT(*) FILTER (WHERE paid_via = 'session') AS session,
              COUNT(*) FILTER (WHERE paid_via = 'legacy') AS legacy
       FROM visit_payouts WHERE venue_id = ANY($1) AND visit_date >= m.s AND visit_date < m.e
     ) vp ON true
     LEFT JOIN LATERAL (
       SELECT COUNT(*) AS count FROM checkins WHERE venue_id = ANY($1) AND paid_via = 'membership'
         AND checkin_date >= m.s AND checkin_date < m.e
     ) mv ON true
     ORDER BY m.month DESC`,
    [venueIds, month.from, month.to, config.tz],
  );
}

async function partnerVenueIds(ownerId, venueId) {
  if (venueId) return [(await ownVenue(venueId, ownerId)).id];
  return (await query(`SELECT id FROM venues WHERE owner_id = $1`, [ownerId])).map((v) => v.id);
}

/**
 * GET /memberships/partner/earnings?venueId=&month=YYYY-MM — one month's earnings (all own venues when no venueId):
 * direct membership sales − FitKey commission + FitKey-pass visit payouts, plus each venue's payout rate.
 */
partner.get('/earnings', async (req, res) => {
  const f = validate(
    z.object({ venueId: uuidSchema.optional(), month: z.string().regex(/^\d{4}-\d{2}$/).optional() }),
    req.query,
  );
  const ids = await partnerVenueIds(req.user.id, f.venueId);
  const t = await nowInTz();
  const month = f.month ?? t.today.slice(0, 7);
  const [row] = await earningsFor(ids, { from: `${month}-01`, to: `${month}-01` });
  const venues = await query(`SELECT id, name, visit_payout_paise, commission_pct FROM venues WHERE id = ANY($1) ORDER BY name`, [ids]);
  for (const v of venues) {
    v.payoutPerVisitPaise = await payoutRatePaise(v);
    v.commissionPct = await commissionPctFor(v.id);
    delete v.visitPayoutPaise;
  }
  res.json({ ...row, venues, paymentsMode: config.paymentsMode });
});

/** GET /memberships/partner/statement?venueId=&months=12 — monthly payout statement, newest month first. */
partner.get('/statement', async (req, res) => {
  const f = validate(
    z.object({ venueId: uuidSchema.optional(), months: z.coerce.number().int().min(1).max(36).default(12) }),
    req.query,
  );
  const ids = await partnerVenueIds(req.user.id, f.venueId);
  const t = await nowInTz();
  const end = new Date(`${t.today.slice(0, 7)}-01T00:00:00Z`);
  const start = new Date(end);
  start.setUTCMonth(start.getUTCMonth() - (f.months - 1));
  const months = await earningsFor(ids, { from: start.toISOString().slice(0, 10), to: end.toISOString().slice(0, 10) });
  const totals = months.reduce(
    (acc, m) => {
      for (const k of ['membershipGrossPaise', 'commissionPaise', 'membershipNetPaise', 'visitPayoutPaise', 'totalPayablePaise', 'fitkeyVisits', 'membershipsSold']) {
        acc[k] = (acc[k] ?? 0) + m[k];
      }
      return acc;
    },
    {},
  );
  res.json({ months, totals });
});

// ---------------------------------------------------------------------------------------------------------------
// Public: a centre's live plans (shown to everyone on the centre page)
// ---------------------------------------------------------------------------------------------------------------

/** GET /memberships/venues/:venueId/plans — approved, switched-on plans with the offer price. */
router.get('/venues/:venueId/plans', async (req, res) => {
  const venueId = validate(uuidSchema, req.params.venueId);
  const plans = await query(
    `SELECT ${PLAN_FIELDS} FROM centre_plans p JOIN venues v ON v.id = p.venue_id
     WHERE p.venue_id = $1 AND v.status = 'live' AND p.is_active AND p.approval_status = 'approved' AND p.archived_at IS NULL
     ORDER BY p.duration_days, p.price_paise`,
    [venueId],
  );
  for (const p of plans) {
    delete p.reviewNote;
    delete p.approvalStatus;
    delete p.reviewedAt;
  }
  res.json({ plans });
});

// ---------------------------------------------------------------------------------------------------------------
// Member
// ---------------------------------------------------------------------------------------------------------------
router.use(requireAuth('user'));

const MEMBERSHIP_SELECT = `
  SELECT d.id, d.venue_id, v.name AS venue_name, v.area AS venue_area, v.city AS venue_city, v.categories AS venue_categories,
         v.photos[1] AS venue_cover_photo, d.plan_id, d.plan_name, d.duration, d.starts_on, d.ends_on, d.price_paise,
         d.discount_pct, d.amount_paise, d.max_visits_per_day, d.max_visits_per_week, d.inclusions, d.payment_ref, d.created_at,
         CASE WHEN d.status = 'cancelled' THEN 'cancelled'
              WHEN (now() AT TIME ZONE $2)::date < d.starts_on THEN 'upcoming'
              WHEN (now() AT TIME ZONE $2)::date > d.ends_on THEN 'expired' ELSE 'active' END AS state,
         GREATEST(0, d.ends_on - (now() AT TIME ZONE $2)::date + 1) AS days_left,
         EXISTS (SELECT 1 FROM centre_plans p WHERE p.id = d.plan_id AND p.is_active AND p.approval_status = 'approved'
                 AND p.archived_at IS NULL AND v.status = 'live') AS can_renew
  FROM direct_memberships d JOIN venues v ON v.id = d.venue_id`;

/** The member's FitKey pass across models (legacy subscriptions, session plans, FitKey coins). */
async function fitkeyPassSummary(userId) {
  const legacy = await query(
    `SELECT s.id, p.name AS plan_name, p.categories, s.starts_at, s.ends_at,
            CASE WHEN now() < s.starts_at THEN 'upcoming' ELSE 'active' END AS state
     FROM subscriptions s JOIN plans p ON p.id = s.plan_id
     WHERE s.user_id = $1 AND s.status = 'active' AND s.ends_at > now() ORDER BY s.ends_at`,
    [userId],
  );
  let sessionPlans = [];
  let coins = null;
  try {
    sessionPlans = await query(
      `SELECT id, name, sessions_total, sessions_used, sessions_total - sessions_used AS sessions_left, starts_at, expires_at
       FROM fitkey_purchases WHERE user_id = $1 AND kind = 'session_plan' AND expires_at > now() AND sessions_used < sessions_total
       ORDER BY expires_at`,
      [userId],
    );
    const c = await queryOne(
      `SELECT COALESCE(SUM(coins_remaining), 0) AS balance, MIN(expires_at) FILTER (WHERE coins_remaining > 0) AS next_expiry
       FROM fitkey_purchases WHERE user_id = $1 AND kind = 'coin_pack' AND expires_at > now()`,
      [userId],
    );
    coins = { balance: c.balance, nextExpiry: c.nextExpiry };
  } catch {
    /* wallet v2 tables not there yet */
  }
  return { legacy, sessionPlans, coins, hasPass: legacy.length > 0 || sessionPlans.length > 0 || (coins?.balance ?? 0) > 0 };
}

/** GET /memberships/me — direct memberships (newest validity first) + the FitKey pass summary. */
router.get('/me', async (req, res) => {
  const [memberships, fitkeyPass] = await Promise.all([
    query(
      `${MEMBERSHIP_SELECT} WHERE d.user_id = $1
       ORDER BY CASE WHEN d.ends_on >= (now() AT TIME ZONE $2)::date THEN 0 ELSE 1 END, d.ends_on DESC LIMIT 100`,
      [req.user.id, config.tz],
    ),
    fitkeyPassSummary(req.user.id),
  ]);
  res.json({ memberships, fitkeyPass, nonRefundable: true });
});

async function buyMembership(userId, planId, startDate) {
  if (config.paymentsMode !== 'mock') throw new HttpError(501, 'Payment gateway not configured');
  return withTransaction(async (client) => {
    const plan = await queryOne(
      `SELECT p.*, v.name AS venue_name, v.owner_id FROM centre_plans p JOIN venues v ON v.id = p.venue_id
       WHERE p.id = $1 AND v.status = 'live' AND p.is_active AND p.approval_status = 'approved' AND p.archived_at IS NULL`,
      [planId],
      client,
    );
    if (!plan) throw notFound('This membership plan is not available right now');
    await client.query(`SELECT id FROM users WHERE id = $1 FOR UPDATE`, [userId]);
    const t = await nowInTz(client);
    const start = startDate ?? t.today;
    const latest = await queryOne(
      `SELECT to_char(($1::date + $2::int), 'YYYY-MM-DD') AS max_start`,
      [t.today, MEMBERSHIP_DEFAULTS.maxStartAheadDays],
      client,
    );
    if (start < t.today) throw badRequest('The start date cannot be in the past');
    if (start > latest.maxStart) throw badRequest(`Pick a start date within ${MEMBERSHIP_DEFAULTS.maxStartAheadDays} days`);

    const overlap = await queryOne(
      `SELECT plan_name, ends_on FROM direct_memberships
       WHERE user_id = $1 AND plan_id = $2 AND status = 'active' AND $3::date BETWEEN starts_on AND ends_on`,
      [userId, plan.id, start],
      client,
    );
    if (overlap) throw conflict(`Your ${overlap.planName} already runs until ${overlap.endsOn} — start the renewal after that`);

    const amount = priceAfterOffer(plan.pricePaise, plan.offerPct);
    const pct = await commissionPctFor(plan.venueId, client);
    const membership = await queryOne(
      `INSERT INTO direct_memberships (user_id, venue_id, plan_id, plan_name, duration, starts_on, ends_on, price_paise,
                                       discount_pct, amount_paise, commission_pct, commission_paise, max_visits_per_day,
                                       max_visits_per_week, inclusions, payment_ref)
       VALUES ($1, $2, $3, $4, $5, $6::date, $6::date + ($7::int - 1), $8, $9, $10, $11, $12, $13, $14, $15, $16)
       RETURNING id`,
      [userId, plan.venueId, plan.id, plan.name, plan.duration, start, plan.durationDays, plan.pricePaise, plan.offerPct,
        amount, pct, Math.round((amount * pct) / 100), plan.maxVisitsPerDay, plan.maxVisitsPerWeek, plan.inclusions,
        `MOCK-${Date.now()}`],
      client,
    );
    return { id: membership.id, plan };
  });
}

const buySchema = z.object({ planId: uuidSchema, startDate: dateSchema.optional() });

/**
 * POST /memberships {planId, startDate?} — buys a centre's membership (mock payment, active instantly, non-refundable).
 */
router.post('/', async (req, res) => {
  const body = validate(buySchema, req.body);
  const { id, plan } = await buyMembership(req.user.id, body.planId, body.startDate);
  const membership = await queryOne(`${MEMBERSHIP_SELECT} WHERE d.id = $1`, [id, config.tz]);
  await notify(req.user.id, {
    type: 'membership',
    title: `${plan.name} at ${plan.venueName} is yours`,
    body: `Valid ${membership.startsOn} → ${membership.endsOn}. Book a slot or scan the QR at the centre.`,
    data: { venueId: plan.venueId, membershipId: id },
  });
  const buyer = await queryOne(`SELECT name FROM users WHERE id = $1`, [req.user.id]);
  await notify(plan.ownerId, {
    type: 'membership_sale',
    title: `New member: ${plan.name}`,
    body: `${buyer?.name ?? 'A member'} bought ${plan.name} (${membership.startsOn} → ${membership.endsOn}).`,
    data: { venueId: plan.venueId, membershipId: id },
  });
  res.status(201).json({ membership, paymentsMode: config.paymentsMode });
});

/** POST /memberships/:id/renew {startDate?} — buys the same plan again, starting the day after it ends (or today). */
router.post('/:id/renew', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const { startDate } = validate(z.object({ startDate: dateSchema.optional() }), req.body ?? {});
  const current = await queryOne(
    `SELECT plan_id, to_char(GREATEST(ends_on + 1, (now() AT TIME ZONE $3)::date), 'YYYY-MM-DD') AS next_start
     FROM direct_memberships WHERE id = $1 AND user_id = $2`,
    [id, req.user.id, config.tz],
  );
  if (!current) throw notFound('Membership not found');
  if (!current.planId) throw conflict('This centre no longer offers that plan');
  const { id: newId, plan } = await buyMembership(req.user.id, current.planId, startDate ?? current.nextStart);
  const membership = await queryOne(`${MEMBERSHIP_SELECT} WHERE d.id = $1`, [newId, config.tz]);
  await notify(req.user.id, {
    type: 'membership',
    title: `Renewed: ${plan.name} at ${plan.venueName}`,
    body: `Valid ${membership.startsOn} → ${membership.endsOn}.`,
    data: { venueId: plan.venueId, membershipId: newId },
  });
  res.status(201).json({ membership, paymentsMode: config.paymentsMode });
});

export default router;

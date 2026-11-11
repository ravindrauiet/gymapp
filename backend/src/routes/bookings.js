import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { HttpError, badRequest, conflict, forbidden, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { visitPayoutFields } from '../utils/partner_money.js';
import { dateSchema, timeSchema, uuidSchema } from '../utils/schemas.js';
import {
  checkinOpen,
  dayClosure,
  generateSlots,
  isOpenDay,
  ladiesOnlyLabels,
  passBlockAt,
  passBlockLabels,
  passBlockedMessage,
  rangeLabel,
  toMin,
  weekdayOf,
} from '../utils/slots.js';
import { chargeVisit, refundVisit, venueVisitCoins, visitCost } from '../utils/wallet.js';

/**
 * Slot booking at FitKey centres + the shared "who may visit and how is it paid" rules (also used by
 * routes/checkins.js and routes/memberships.js).
 *
 * A visit is admitted, in this order, by: a direct centre membership (free, within its slot limits) →
 * a FitKey pass via utils/wallet.js (active session plan → coins; legacy pass = "Included in your pass").
 */
const router = Router();

// ---------------------------------------------------------------------------------------------------------------
// Configurable defaults (business can change them here; per-centre values are admin-set in venues.*).
// ---------------------------------------------------------------------------------------------------------------
export const BOOKING_DEFAULTS = {
  slotMinutes: 60, // hourly slots
  defaultOpensAt: '06:00', // used when a centre has no opening hours set
  defaultClosesAt: '22:00',
  bookAheadDays: 14, // today + 13 days
  freeCancelHours: 2, // free cancellation until 2 h before the slot start
  fallbackVisitCoins: 100, // used only if the wallet tables are missing
};

export const PAID_VIA_LABELS = {
  coins: 'FitKey coins',
  session: 'FitKey session plan',
  membership: 'Centre membership',
  legacy: 'FitKey pass (legacy)',
  event: 'Event entry',
};

/** Booking statuses that hold a place in a slot. 'requested' = waiting for the centre (auto-accept off). */
export const ACTIVE_BOOKING_STATUSES = ['requested', 'booked', 'attended'];
const ACTIVE_SQL = `('requested', 'booked', 'attended')`;
/** paid_via values that are FitKey-pass visits (pass blocks / pass caps apply; FitKey pays the centre). */
export const PASS_PAID_VIA = ['coins', 'session', 'legacy'];

/**
 * 409 for FitKey access rules, sent as { error, code } (code: PASS_BLOCKED | VENUE_CLOSED | PASS_SLOT_FULL).
 * Routers that can throw it end with `router.use(accessErrors)` (the global handler only knows { error, details }).
 */
export class AccessError extends HttpError {
  constructor(accessCode, message, details) {
    super(409, message, details);
    this.accessCode = accessCode;
  }
}
// eslint-disable-next-line no-unused-vars
export function accessErrors(err, _req, res, next) {
  if (err instanceof AccessError) return res.status(409).json({ error: err.message, code: err.accessCode, details: err.details });
  return next(err);
}

/** Today's date and current wall-clock time in the app time zone. */
export async function nowInTz(client) {
  return queryOne(
    `SELECT to_char(now() AT TIME ZONE $1, 'YYYY-MM-DD') AS today, to_char(now() AT TIME ZONE $1, 'HH24:MI') AS now_time,
            to_char((now() AT TIME ZONE $1)::date + $2::int, 'YYYY-MM-DD') AS last_day`,
    [config.tz, BOOKING_DEFAULTS.bookAheadDays - 1],
    client,
  );
}

/**
 * Slots for a venue on a date, honouring venue_hours (split shifts), slot_minutes and — when `rules` is given —
 * closures / pass blocks / ladies-only windows (see utils/slots.js). Empty when the centre is closed that day.
 */
export function slotTimes(venue, date, rules = {}) {
  return generateSlots(venue, rules, date);
}

export const VENUE_RULE_COLUMNS = `slot_capacity, slot_minutes, courts, pass_slot_cap, fitkey_pass_mode, auto_accept_bookings,
  monthly_fee_paise, opens_at, closes_at, open_days`;

export async function liveVenue(venueId, client) {
  const v = await queryOne(
    `SELECT id, owner_id, name, area, city, categories, ${VENUE_RULE_COLUMNS},
            visit_payout_paise, commission_pct, photos[1] AS cover_photo
     FROM venues WHERE id = $1 AND status = 'live'`,
    [venueId],
    client,
  );
  if (!v) throw notFound('Centre not found or not live on FitKey');
  return v;
}

/**
 * Timing rules of a venue: { hours, blocks, closures } (closures between from and to, inclusive).
 * Sequential queries so it is safe on a transaction client.
 */
export async function venueRules(venueId, from, to, client) {
  const hours = await query(
    `SELECT weekday, to_char(opens_at, 'HH24:MI') AS opens_at, to_char(closes_at, 'HH24:MI') AS closes_at, kind
     FROM venue_hours WHERE venue_id = $1 ORDER BY weekday, opens_at`,
    [venueId],
    client,
  );
  const blocks = await query(
    `SELECT id, days, to_char(starts_at, 'HH24:MI') AS starts_at, to_char(ends_at, 'HH24:MI') AS ends_at, note
     FROM venue_pass_blocks WHERE venue_id = $1 ORDER BY starts_at`,
    [venueId],
    client,
  );
  const closures = await query(
    `SELECT id, closed_on, to_char(slot_start, 'HH24:MI') AS slot_start, to_char(slot_end, 'HH24:MI') AS slot_end, note
     FROM venue_closures WHERE venue_id = $1 AND closed_on BETWEEN $2::date AND $3::date
     ORDER BY closed_on, slot_start NULLS FIRST`,
    [venueId, from, to],
    client,
  );
  return { hours, blocks, closures };
}

/** Bookings per slot start on a date: { 'HH:MM': { booked, pass } } (active statuses only). */
export async function slotCounts(venueId, date, client) {
  const rows = await query(
    `SELECT to_char(slot_start, 'HH24:MI') AS start, COUNT(*) AS booked,
            COUNT(*) FILTER (WHERE paid_via IN ('coins', 'session', 'legacy')) AS pass
     FROM slot_bookings WHERE venue_id = $1 AND slot_date = $2 AND status IN ${ACTIVE_SQL} GROUP BY slot_start`,
    [venueId, date],
    client,
  );
  return Object.fromEntries(rows.map((r) => [r.start, { booked: r.booked, pass: r.pass }]));
}

/**
 * Throws AccessError VENUE_CLOSED when a walk-in check-in at `time` is outside hours / on a closure, and
 * PASS_BLOCKED when `viaPass` and the time falls in a FitKey-pass block. Used by check-ins (member and partner scan).
 */
export function assertCheckinAllowed(venue, rules, date, time, { viaPass }) {
  const open = checkinOpen(venue, rules, date, time);
  if (!open.open) throw new AccessError('VENUE_CLOSED', open.reason);
  if (viaPass) {
    const block = passBlockAt(venue, rules.blocks, date, toMin(time));
    if (block) throw new AccessError('PASS_BLOCKED', passBlockedMessage(venue, block), { block: rangeLabel(block.startsAt, block.endsAt) });
  }
}

/**
 * FitKey-pass visit payout for a check-in (contract §F): passVisitPayout(monthly fee, owner go-live, visit time)
 * when the venue has a monthly fee, else the old flat per-visit rate. Inserts the visit_payouts row.
 */
export async function recordVisitPayout(client, { checkinId, venueId, userId, paidVia, visitDate, at = new Date() }) {
  const v = await queryOne(
    `SELECT v.id, v.monthly_fee_paise, v.visit_payout_paise, u.partner_go_live_at
     FROM venues v JOIN users u ON u.id = v.owner_id WHERE v.id = $1`,
    [venueId],
    client,
  );
  const oldRate = v.monthlyFeePaise ? 0 : await payoutRatePaise(v, client);
  const p = visitPayoutFields(v.monthlyFeePaise, v.partnerGoLiveAt, at, oldRate);
  await client.query(
    `INSERT INTO visit_payouts (checkin_id, venue_id, user_id, paid_via, amount_paise, visit_date, gross_paise, commission_pct, commission_paise)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) ON CONFLICT (checkin_id) DO NOTHING`,
    [checkinId, venueId, userId, paidVia, p.netPaise, visitDate, p.grossPaise, p.commissionPct, p.commissionPaise],
  );
  return p;
}

// ---------------------------------------------------------------------------------------------------------------
// Pricing helpers
// ---------------------------------------------------------------------------------------------------------------

/** Coin cost of one visit at this venue (wallet tables: per-centre override → first category → default). */
export async function venueCoinCost(venueId, client) {
  try {
    return await venueVisitCoins(venueId, client);
  } catch {
    return BOOKING_DEFAULTS.fallbackVisitCoins;
  }
}

/** What FitKey pays the centre per FitKey-pass visit: admin-set rate, default = coin cost in ₹ (1 coin = ₹1). */
export async function payoutRatePaise(venue, client) {
  if (venue.visitPayoutPaise != null) return venue.visitPayoutPaise;
  return (await venueCoinCost(venue.id, client)) * 100;
}

/** Active legacy subscription (old plans table) covering one of the venue's categories. */
export async function legacyPass(userId, categories, client) {
  return queryOne(
    `SELECT s.id, s.ends_at, p.name AS plan_name FROM subscriptions s JOIN plans p ON p.id = s.plan_id
     WHERE s.user_id = $1 AND s.status = 'active' AND now() BETWEEN s.starts_at AND s.ends_at AND p.categories && $2
     ORDER BY s.ends_at DESC LIMIT 1`,
    [userId, categories],
    client,
  );
}

const isNotImplemented = (e) => e instanceof HttpError && e.status === 501;

/**
 * FitKey-pass cost preview (wraps wallet.visitCost). While the wallet isn't live (501) it still recognises legacy
 * passes. Shape: {method: 'session'|'coins'|'legacy_pass'|null, amount, label, sufficient, balance, available}.
 */
export async function fitkeyCost(userId, venue) {
  try {
    const c = await visitCost(userId, venue.id);
    return { ...c, available: true };
  } catch (e) {
    if (!isNotImplemented(e)) throw e;
    const legacy = await legacyPass(userId, venue.categories);
    if (legacy) return { method: 'legacy_pass', amount: 0, label: 'Included in your pass', sufficient: true, balance: null, available: true };
    return { method: null, amount: 0, label: 'Coins & session plans are not live yet', sufficient: false, balance: null, available: false };
  }
}

/**
 * Charges one FitKey-pass visit inside `client`'s transaction. Returns {paidVia, amount, label, subscriptionId}.
 * Throws HttpError 402 (with a reason + what to buy) when the member can't pay.
 */
export async function payWithFitkey(client, userId, venue, { bookingId = null } = {}) {
  let r;
  try {
    r = await chargeVisit(client, userId, venue.id, { bookingId });
  } catch (e) {
    if (!isNotImplemented(e)) throw e;
    // Wallet not live yet: only legacy passes can pay.
    const legacy = await legacyPass(userId, venue.categories, client);
    if (legacy) return { paidVia: 'legacy', amount: 0, label: 'Included in your pass', subscriptionId: legacy.id, planName: legacy.planName };
    throw new HttpError(402, `You need a FitKey pass or a ${venue.name} membership to visit. Coins & session plans are not live yet.`, {
      reason: 'no_pass',
      buy: ['centre_membership', 'fitkey_pass'],
    });
  }
  const method = r?.method ?? r?.paidVia;
  const paidVia = method === 'legacy_pass' || method === 'legacy' ? 'legacy' : method;
  if (!['coins', 'session', 'legacy'].includes(paidVia)) {
    throw new HttpError(500, 'Unexpected payment method from the wallet');
  }
  let subscriptionId = null;
  let planName = null;
  if (paidVia === 'legacy') {
    const legacy = await legacyPass(userId, venue.categories, client);
    subscriptionId = legacy?.id ?? null;
    planName = legacy?.planName ?? null;
  }
  const amount = Number(r?.amount ?? 0);
  const label = r?.label ?? (paidVia === 'coins' ? `${amount} coins` : paidVia === 'session' ? '1 session' : 'Included in your pass');
  return { paidVia, amount, label, subscriptionId, planName };
}

// ---------------------------------------------------------------------------------------------------------------
// Direct memberships: validity + slot limits
// ---------------------------------------------------------------------------------------------------------------

/** How many visits a membership has used/reserved on `date` and in that date's Mon–Sun week. */
async function membershipUsage(membershipId, date, client, { excludeBookingId = null } = {}) {
  return queryOne(
    `SELECT
       (SELECT COUNT(*) FROM slot_bookings WHERE membership_id = $1 AND status NOT IN ('cancelled', 'rejected') AND slot_date = $2::date
          AND id IS DISTINCT FROM $3::uuid) +
       (SELECT COUNT(*) FROM checkins WHERE membership_id = $1 AND booking_id IS NULL AND checkin_date = $2::date) AS day,
       (SELECT COUNT(*) FROM slot_bookings WHERE membership_id = $1 AND status NOT IN ('cancelled', 'rejected')
          AND date_trunc('week', slot_date) = date_trunc('week', $2::date) AND id IS DISTINCT FROM $3::uuid) +
       (SELECT COUNT(*) FROM checkins WHERE membership_id = $1 AND booking_id IS NULL
          AND date_trunc('week', checkin_date) = date_trunc('week', $2::date)) AS week`,
    [membershipId, date, excludeBookingId],
    client,
  );
}

/**
 * The member's direct membership valid at `venueId` on `date`, honouring max visits per day/week.
 * Returns {membership, usable, reason}. membership is null when they hold none valid that day.
 */
export async function membershipFor(userId, venueId, date, client, opts = {}) {
  const list = await query(
    `SELECT id, plan_name, starts_on, ends_on, max_visits_per_day, max_visits_per_week
     FROM direct_memberships
     WHERE user_id = $1 AND venue_id = $2 AND status = 'active' AND $3::date BETWEEN starts_on AND ends_on
     ORDER BY ends_on`,
    [userId, venueId, date],
    client,
  );
  if (!list.length) return { membership: null, usable: false, reason: null };
  let reason = null;
  for (const m of list) {
    const u = await membershipUsage(m.id, date, client, opts);
    if (m.maxVisitsPerDay != null && u.day >= m.maxVisitsPerDay) {
      reason = `Your ${m.planName} membership allows ${m.maxVisitsPerDay} visit${m.maxVisitsPerDay > 1 ? 's' : ''} per day`;
      continue;
    }
    if (m.maxVisitsPerWeek != null && u.week >= m.maxVisitsPerWeek) {
      reason = `Your ${m.planName} membership allows ${m.maxVisitsPerWeek} visit${m.maxVisitsPerWeek > 1 ? 's' : ''} per week — this week's are used`;
      continue;
    }
    return { membership: m, usable: true, reason: null };
  }
  return { membership: list[0], usable: false, reason };
}

/** Cost preview for one visit on `date`: membership first, then the FitKey pass. */
export async function visitPreview(userId, venue, date) {
  const m = await membershipFor(userId, venue.id, date);
  if (m.usable) {
    return { method: 'membership', amount: 0, label: 'Included in your membership', sufficient: true, membershipName: m.membership.planName };
  }
  const c = await fitkeyCost(userId, venue);
  return { ...c, membershipLimit: m.reason };
}

// ---------------------------------------------------------------------------------------------------------------
// Partner (venue owner) endpoints — mounted before the member routes.
// ---------------------------------------------------------------------------------------------------------------
const partner = Router();
partner.use(requireAuth('partner'));
router.use('/partner', partner);

export async function ownVenue(venueId, ownerId, client) {
  const parsed = uuidSchema.safeParse(venueId);
  if (!parsed.success) throw notFound('Venue not found');
  const v = await queryOne(`SELECT * FROM venues WHERE id = $1`, [venueId], client);
  if (!v) throw notFound('Venue not found');
  if (v.ownerId !== ownerId) throw forbidden('This venue belongs to another partner');
  return v;
}


// ---------------------------------------------------------------------------------------------------------------
// Booking requests (auto-accept off). Decision: the visit is CHARGED when the request is made (a hold, so the
// member can't spend those coins / that session twice and the slot place is real) and REFUNDED in full when the
// centre rejects it, when the member withdraws it, or when it is still undecided at the slot start (auto-expiry).
// ---------------------------------------------------------------------------------------------------------------

/** Accepts / rejects a 'requested' booking at the owner's venue; notifies the member. */
export async function decideBooking(bookingId, ownerId, action, { reason = null, auto = false } = {}) {
  const id = validate(uuidSchema, bookingId);
  const result = await withTransaction(async (client) => {
    const b = await queryOne(
      `SELECT b.id, b.user_id, b.venue_id, b.status, b.paid_via, b.cost_label, b.slot_date,
              to_char(b.slot_start, 'HH24:MI') AS slot_start, to_char(b.slot_end, 'HH24:MI') AS slot_end,
              ((b.slot_date + b.slot_end)::timestamp AT TIME ZONE $2) < now() AS over,
              v.owner_id, v.name AS venue_name
       FROM slot_bookings b JOIN venues v ON v.id = b.venue_id WHERE b.id = $1 FOR UPDATE OF b`,
      [id, config.tz],
      client,
    );
    if (!b || (ownerId && b.ownerId !== ownerId)) throw notFound('Booking not found');
    if (b.status !== 'requested') throw conflict(`This booking is already ${b.status}`);
    if (action === 'accept') {
      if (b.over) throw conflict('This slot is already over — reject the request instead');
      await client.query(`UPDATE slot_bookings SET status = 'booked', decided_at = now() WHERE id = $1`, [b.id]);
      return { ...b, status: 'booked', refunded: false };
    }
    let refunded = false;
    if (b.paidVia === 'coins' || b.paidVia === 'session') {
      const r = await refundVisit(client, b.userId, { bookingId: b.id });
      refunded = r.refunded;
    }
    await client.query(
      `UPDATE slot_bookings SET status = 'rejected', decided_at = now(), reject_reason = $2, refunded = $3 WHERE id = $1`,
      [b.id, reason, refunded],
    );
    return { ...b, status: 'rejected', refunded, rejectReason: reason };
  });
  const when = `${result.slotDate} ${result.slotStart}`;
  if (result.status === 'booked') {
    await notify(result.userId, {
      type: 'booking_accepted',
      title: `Booking confirmed at ${result.venueName}`,
      body: `${result.venueName} accepted your ${when} slot. See you there!`,
      data: { bookingId: result.id, venueId: result.venueId },
    });
  } else {
    const back = result.refunded ? ` ${result.costLabel ?? 'Your visit'} is back on your FitKey pass.` : '';
    await notify(result.userId, {
      type: 'booking_rejected',
      title: auto ? `Booking request expired: ${result.venueName}` : `Booking declined by ${result.venueName}`,
      body: `${auto ? 'The centre did not confirm' : 'The centre could not take'} your ${when} slot${reason && !auto ? ` (${reason})` : ''}.${back}`,
      data: { bookingId: result.id, venueId: result.venueId },
    });
  }
  delete result.ownerId;
  delete result.over;
  return result;
}

/** Rejects (with refund) requests still undecided when their slot starts. Safe to call often. */
export async function expireStaleRequests(venueId = null) {
  const stale = await query(
    `SELECT id FROM slot_bookings
     WHERE status = 'requested' AND ($2::uuid IS NULL OR venue_id = $2)
       AND ((slot_date + slot_start)::timestamp AT TIME ZONE $1) <= now()
     LIMIT 200`,
    [config.tz, venueId],
  );
  let n = 0;
  for (const s of stale) {
    try {
      await decideBooking(s.id, null, 'reject', { reason: 'Not confirmed by the centre in time', auto: true });
      n += 1;
    } catch (e) {
      if (!(e instanceof HttpError)) console.error('expire booking request failed:', e.message);
    }
  }
  return n;
}

const partnerListSchema = z.object({
  date: dateSchema.optional(),
  from: dateSchema.optional(),
  to: dateSchema.optional(),
  status: z.enum(['requested', 'booked', 'attended', 'cancelled', 'rejected', 'all']).default('all'),
  paidVia: z.enum(['coins', 'session', 'membership', 'legacy']).optional(),
});

/**
 * GET /bookings/partner/venues/:venueId/bookings?date=|from=&to=&status=&paidVia=
 * Slot bookings at the partner's centre with how each was paid. Default: today.
 */
partner.get('/venues/:venueId/bookings', async (req, res) => {
  const venue = await ownVenue(req.params.venueId, req.user.id);
  const f = validate(partnerListSchema, req.query);
  const t = await nowInTz();
  const from = f.date ?? f.from ?? t.today;
  const to = f.date ?? f.to ?? from;
  const bookings = await query(
    `SELECT b.id, b.slot_date, to_char(b.slot_start, 'HH24:MI') AS slot_start, to_char(b.slot_end, 'HH24:MI') AS slot_end,
            b.status, b.paid_via, b.cost_label, b.cost_amount, b.refunded, b.attended_at, b.cancelled_at, b.decided_at,
            b.reject_reason, b.created_at,
            u.name AS member_name, RIGHT(u.phone, 4) AS phone_last4, m.plan_name AS membership_name
     FROM slot_bookings b JOIN users u ON u.id = b.user_id
     LEFT JOIN direct_memberships m ON m.id = b.membership_id
     WHERE b.venue_id = $1 AND b.slot_date BETWEEN $2 AND $3
       AND ($4 = 'all' OR b.status = $4) AND ($5::text IS NULL OR b.paid_via = $5)
     ORDER BY b.slot_date, b.slot_start, b.created_at`,
    [venue.id, from, to, f.status, f.paidVia ?? null],
  );
  const counts = { requested: 0, booked: 0, attended: 0, cancelled: 0, rejected: 0 };
  const byPaidVia = { coins: 0, session: 0, membership: 0, legacy: 0 };
  for (const b of bookings) {
    counts[b.status] = (counts[b.status] ?? 0) + 1;
    if (ACTIVE_BOOKING_STATUSES.includes(b.status) && b.paidVia) byPaidVia[b.paidVia] = (byPaidVia[b.paidVia] ?? 0) + 1;
  }
  res.json({ from, to, count: bookings.length, counts, byPaidVia, bookings });
});

/**
 * GET /bookings/partner/venues/:venueId/slots?date= — capacity per slot (booked / capacity) for a day.
 * (The richer board is GET /partner/venues/:id/slot-board.)
 */
partner.get('/venues/:venueId/slots', async (req, res) => {
  const venue = await ownVenue(req.params.venueId, req.user.id);
  const { date } = validate(z.object({ date: dateSchema.optional() }), req.query);
  const d = date ?? (await nowInTz()).today;
  const [rules, counts] = await Promise.all([venueRules(venue.id, d, d), slotCounts(venue.id, d)]);
  const slots = slotTimes(venue, d, rules).map((s) => ({
    start: s.start,
    end: s.end,
    capacity: s.capacity,
    booked: counts[s.start]?.booked ?? 0,
    passBooked: counts[s.start]?.pass ?? 0,
    passCap: s.passCap,
    blocked: s.blocked,
    passBlocked: s.passBlocked,
    ladiesOnly: s.ladiesOnly,
  }));
  res.json({ date: d, capacity: slots[0]?.capacity ?? venue.slotCapacity, open: slots.some((s) => !s.blocked), slots });
});

/**
 * GET /bookings/partner/venues/:venueId/visits?date=|from=&to= — check-ins with how each visit was paid
 * (coins / session / membership / legacy / event) and the payout FitKey owes for it.
 */
partner.get('/venues/:venueId/visits', async (req, res) => {
  const venue = await ownVenue(req.params.venueId, req.user.id);
  const f = validate(z.object({ date: dateSchema.optional(), from: dateSchema.optional(), to: dateSchema.optional() }), req.query);
  const t = await nowInTz();
  const from = f.date ?? f.from ?? t.today;
  const to = f.date ?? f.to ?? from;
  const visits = await query(
    `SELECT c.id, c.checkin_date, c.checked_in_at, c.method, c.paid_via, c.cost_label, c.booking_id IS NOT NULL AS booked,
            u.name AS member_name, RIGHT(u.phone, 4) AS phone_last4, m.plan_name AS membership_name,
            p.amount_paise AS payout_paise, COALESCE(p.gross_paise, p.amount_paise) AS gross_paise,
            p.commission_pct, p.commission_paise
     FROM checkins c JOIN users u ON u.id = c.user_id
     LEFT JOIN direct_memberships m ON m.id = c.membership_id
     LEFT JOIN visit_payouts p ON p.checkin_id = c.id
     WHERE c.venue_id = $1 AND c.checkin_date BETWEEN $2 AND $3
     ORDER BY c.checked_in_at DESC`,
    [venue.id, from, to],
  );
  const byPaidVia = {};
  let payoutPaise = 0;
  for (const v of visits) {
    const k = v.paidVia ?? 'legacy';
    byPaidVia[k] = (byPaidVia[k] ?? 0) + 1;
    payoutPaise += v.payoutPaise ?? 0;
  }
  res.json({ from, to, count: visits.length, byPaidVia, payoutPaise, visits });
});

// ---------------------------------------------------------------------------------------------------------------
// Member endpoints
// ---------------------------------------------------------------------------------------------------------------
router.use(requireAuth('user'));

/**
 * GET /bookings/venues/:venueId/access — what the member holds for this centre (venue page):
 * {fitkey: cost preview for today, hasFitkeyPass, memberships: [active/upcoming at this centre], legacy}.
 */
router.get('/venues/:venueId/access', async (req, res) => {
  const venue = await liveVenue(validate(uuidSchema, req.params.venueId));
  const t = await nowInTz();
  const [fitkey, memberships, legacy, rules] = await Promise.all([
    fitkeyCost(req.user.id, venue),
    query(
      `SELECT id, plan_name, duration, starts_on, ends_on, max_visits_per_day, max_visits_per_week,
              CASE WHEN $3::date < starts_on THEN 'upcoming' ELSE 'active' END AS state
       FROM direct_memberships WHERE user_id = $1 AND venue_id = $2 AND status = 'active' AND ends_on >= $3::date
       ORDER BY starts_on`,
      [req.user.id, venue.id, t.today],
    ),
    legacyPass(req.user.id, venue.categories),
    venueRules(venue.id, t.today, t.today),
  ]);
  res.json({
    venueId: venue.id,
    today: t.today,
    hasFitkeyPass: Boolean(fitkey.method && fitkey.sufficient),
    fitkey,
    legacy,
    memberships,
    hasMembership: memberships.some((m) => m.state === 'active'),
    passBlockLabels: passBlockLabels(venue, rules.blocks),
  });
});

/**
 * GET /bookings/venues/:venueId/slots?date=YYYY-MM-DD — bookable days, slots with availability and the cost of a
 * visit BEFORE booking ("120 coins", "1 session", "Included in your pass / membership"). Honours split shifts,
 * slot_minutes, closures (blocked), capacity × courts, FitKey-pass blocks and the pass cap per slot (only when the
 * visit would be paid with the FitKey pass — direct members are not affected), and flags ladies-only slots.
 * Each slot: { start, end, capacity, booked, left, past, available, blocked, passBlocked, passFull, ladiesOnly, reason }.
 */
router.get('/venues/:venueId/slots', async (req, res) => {
  const venue = await liveVenue(validate(uuidSchema, req.params.venueId));
  const { date } = validate(z.object({ date: dateSchema.optional() }), req.query);
  const t = await nowInTz();
  const d = date ?? t.today;
  if (d < t.today || d > t.lastDay) throw badRequest(`Pick a day between ${t.today} and ${t.lastDay}`);

  const rules = await venueRules(venue.id, t.today, t.lastDay);
  const days = [];
  for (let i = 0; i < BOOKING_DEFAULTS.bookAheadDays; i++) {
    const day = new Date(`${t.today}T00:00:00Z`);
    day.setUTCDate(day.getUTCDate() + i);
    const iso = day.toISOString().slice(0, 10);
    const closure = dayClosure(rules.closures, iso);
    days.push({ date: iso, weekday: weekdayOf(iso), open: isOpenDay(venue, rules, iso), closedNote: closure?.note ?? null });
  }

  const [counts, mine, cost] = await Promise.all([
    slotCounts(venue.id, d),
    queryOne(
      `SELECT id, to_char(slot_start, 'HH24:MI') AS slot_start, to_char(slot_end, 'HH24:MI') AS slot_end, status, paid_via, cost_label
       FROM slot_bookings WHERE user_id = $1 AND venue_id = $2 AND slot_date = $3 AND status IN ${ACTIVE_SQL}`,
      [req.user.id, venue.id, d],
    ),
    visitPreview(req.user.id, venue, d),
  ]);
  const viaPass = cost.method !== 'membership';
  const slots = slotTimes(venue, d, rules).map((s) => {
    const n = counts[s.start]?.booked ?? 0;
    const pn = counts[s.start]?.pass ?? 0;
    const past = d === t.today && s.start <= t.nowTime;
    const full = n >= s.capacity;
    const passFull = pn >= s.passCap;
    let reason = null;
    if (past) reason = 'past';
    else if (s.blocked) reason = 'closed';
    else if (full) reason = 'full';
    else if (viaPass && s.passBlocked) reason = 'pass_blocked';
    else if (viaPass && passFull) reason = 'pass_full';
    return {
      start: s.start,
      end: s.end,
      capacity: s.capacity,
      booked: n,
      left: Math.max(0, s.capacity - n),
      past,
      available: reason === null,
      blocked: s.blocked,
      passBlocked: s.passBlocked,
      passFull,
      ladiesOnly: s.ladiesOnly,
      reason,
    };
  });
  const closure = dayClosure(rules.closures, d);
  res.json({
    venue: { id: venue.id, name: venue.name, area: venue.area, city: venue.city, coverPhoto: venue.coverPhoto },
    date: d,
    days,
    slots,
    slotMinutes: venue.slotMinutes,
    closedNote: closure?.note ?? null,
    passBlockLabels: passBlockLabels(venue, rules.blocks),
    ladiesOnlyLabels: ladiesOnlyLabels(rules.hours),
    requiresApproval: venue.autoAcceptBookings === false,
    autoAcceptBookings: venue.autoAcceptBookings !== false, // read by the member app
    cost,
    myBooking: mine,
    freeCancelHours: BOOKING_DEFAULTS.freeCancelHours,
  });
});

const bookSchema = z.object({ venueId: uuidSchema, date: dateSchema, start: timeSchema });

/**
 * POST /bookings {venueId, date, start} — books a slot. Paid by a direct membership (free, not affected by pass
 * blocks) or the FitKey pass (wallet.chargeVisit) inside the same transaction. 402 = can't pay;
 * 409 code VENUE_CLOSED (closed day / blocked slot / outside hours), PASS_BLOCKED, PASS_SLOT_FULL.
 * When the centre has auto-accept off the booking is created as status 'requested' (charged now, refunded if rejected).
 */
router.post('/', async (req, res) => {
  const body = validate(bookSchema, req.body);
  const start = body.start.slice(0, 5);

  const booking = await withTransaction(async (client) => {
    const venue = await liveVenue(body.venueId, client);
    // Serialise bookings for this centre so slot capacity can't be oversold.
    await client.query(`SELECT id FROM venues WHERE id = $1 FOR UPDATE`, [venue.id]);
    const t = await nowInTz(client);
    if (body.date < t.today || body.date > t.lastDay) throw badRequest(`You can book between ${t.today} and ${t.lastDay}`);
    const rules = await venueRules(venue.id, body.date, body.date, client);
    const slot = slotTimes(venue, body.date, rules).find((s) => s.start === start);
    if (!slot) {
      const closed = dayClosure(rules.closures, body.date);
      throw new AccessError(
        'VENUE_CLOSED',
        closed
          ? `${venue.name} is closed on ${body.date}${closed.note ? ` (${closed.note})` : ''}`
          : `${venue.name} has no ${start} slot on that day — it is outside opening hours`,
      );
    }
    if (slot.blocked) {
      throw new AccessError('VENUE_CLOSED', `${venue.name} has blocked the ${start} slot on ${body.date}${slot.closureNote ? ` (${slot.closureNote})` : ''}`);
    }
    if (body.date === t.today && slot.start <= t.nowTime) throw badRequest('That slot has already started — pick a later one');

    const dup = await queryOne(
      `SELECT to_char(slot_start, 'HH24:MI') AS start FROM slot_bookings
       WHERE user_id = $1 AND venue_id = $2 AND slot_date = $3 AND status IN ${ACTIVE_SQL}`,
      [req.user.id, venue.id, body.date],
      client,
    );
    if (dup) throw conflict(`You already have a ${dup.start} booking at ${venue.name} that day`);
    const counts = await slotCounts(venue.id, body.date, client);
    if ((counts[start]?.booked ?? 0) >= slot.capacity) throw conflict('That slot is full — pick another time');

    const status = venue.autoAcceptBookings === false ? 'requested' : 'booked';
    const row = await queryOne(
      `INSERT INTO slot_bookings (user_id, venue_id, slot_date, slot_start, slot_end, status) VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
      [req.user.id, venue.id, body.date, slot.start, slot.end, status],
      client,
    );

    const m = await membershipFor(req.user.id, venue.id, body.date, client, { excludeBookingId: row.id });
    let pay;
    if (m.usable) {
      pay = { paidVia: 'membership', amount: 0, label: 'Included in your membership', membershipId: m.membership.id };
    } else {
      // FitKey-pass rules (direct members above are not affected).
      const why = m.reason ? `${m.reason}. ` : '';
      const block = passBlockAt(venue, rules.blocks, body.date, toMin(slot.start), toMin(slot.end));
      if (block) throw new AccessError('PASS_BLOCKED', `${why}${passBlockedMessage(venue, block)}`, { block: rangeLabel(block.startsAt, block.endsAt) });
      if ((counts[start]?.pass ?? 0) >= slot.passCap) {
        throw new AccessError('PASS_SLOT_FULL', `${why}FitKey pass places in the ${start} slot are full at ${venue.name} — pick another time`);
      }
      try {
        pay = await payWithFitkey(client, req.user.id, venue, { bookingId: row.id });
      } catch (e) {
        if (e instanceof HttpError && e.status === 402 && m.reason) {
          throw new HttpError(402, `${m.reason}, and your FitKey pass can't cover it: ${e.message}`, e.details);
        }
        throw e;
      }
    }

    const out = await queryOne(
      `UPDATE slot_bookings SET paid_via = $2, cost_amount = $3, cost_label = $4, membership_id = $5, subscription_id = $6
       WHERE id = $1
       RETURNING id, venue_id, slot_date, to_char(slot_start, 'HH24:MI') AS slot_start, to_char(slot_end, 'HH24:MI') AS slot_end,
                 status, paid_via, cost_amount, cost_label, created_at`,
      [row.id, pay.paidVia, pay.amount, pay.label, pay.membershipId ?? null, pay.subscriptionId ?? null],
      client,
    );
    return { ...out, ladiesOnly: slot.ladiesOnly, ownerId: venue.ownerId, venueName: venue.name };
  });

  const { ownerId, venueName, ...out } = booking;
  if (out.status === 'requested') {
    const who = await queryOne(`SELECT name FROM users WHERE id = $1`, [req.user.id]);
    await notify(ownerId, {
      type: 'booking_request',
      title: `Booking request: ${out.slotDate} ${out.slotStart}`,
      body: `${who?.name ?? 'A member'} wants the ${out.slotStart} slot at ${venueName}. Accept or reject in Bookings.`,
      data: { bookingId: out.id, venueId: out.venueId },
    });
    out.message = `Request sent — ${venueName} will confirm. ${out.costLabel ?? 'The visit'} is held and returned if they can't take you.`;
  }
  res.status(201).json({ booking: out });
});

const BOOKING_SELECT = `
  SELECT b.id, b.venue_id, v.name AS venue_name, v.area AS venue_area, v.city AS venue_city, v.categories AS venue_categories,
         v.photos[1] AS venue_cover_photo, b.slot_date, to_char(b.slot_start, 'HH24:MI') AS slot_start,
         to_char(b.slot_end, 'HH24:MI') AS slot_end, b.status, b.paid_via, b.cost_amount, b.cost_label, b.refunded,
         b.attended_at, b.cancelled_at, b.decided_at, b.reject_reason, b.created_at,
         ((b.slot_date + b.slot_start)::timestamp AT TIME ZONE $2) AS starts_at,
         ((b.slot_date + b.slot_end)::timestamp AT TIME ZONE $2) AS ends_at,
         (b.status IN ('booked', 'requested') AND ((b.slot_date + b.slot_end)::timestamp AT TIME ZONE $2) > now()) AS can_cancel,
         (b.status = 'requested' OR ((b.slot_date + b.slot_start)::timestamp AT TIME ZONE $2) - now() >= make_interval(hours => $3)) AS free_cancel
  FROM slot_bookings b JOIN venues v ON v.id = b.venue_id`;

const UPCOMING = `b.status IN ('booked', 'requested') AND ((b.slot_date + b.slot_end)::timestamp AT TIME ZONE $2) > now()`;

/** GET /bookings/me?scope=upcoming|past|all — the member's bookings (upcoming includes requests awaiting the centre). */
router.get('/me', async (req, res) => {
  const { scope } = validate(z.object({ scope: z.enum(['upcoming', 'past', 'all']).default('all') }), req.query);
  const cond = { upcoming: `AND ${UPCOMING}`, past: `AND NOT (${UPCOMING})`, all: '' }[scope];
  const bookings = await query(
    `${BOOKING_SELECT} WHERE b.user_id = $1 ${cond}
     ORDER BY CASE WHEN ${UPCOMING} THEN 0 ELSE 1 END,
              CASE WHEN ${UPCOMING} THEN b.slot_date + b.slot_start END ASC,
              b.slot_date DESC, b.slot_start DESC
     LIMIT 100`,
    [req.user.id, config.tz, BOOKING_DEFAULTS.freeCancelHours],
  );
  res.json({ bookings, freeCancelHours: BOOKING_DEFAULTS.freeCancelHours });
});

/**
 * POST /bookings/:id/cancel — cancels an upcoming booking. Free (coins/session returned via wallet.refundVisit)
 * until 2 h before the slot; later it is cancelled without a refund. A request the centre hasn't accepted yet is
 * always withdrawn with a full refund. Membership/legacy bookings cost nothing.
 */
router.post('/:id/cancel', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const result = await withTransaction(async (client) => {
    const b = await queryOne(
      `${BOOKING_SELECT} WHERE b.id = $1 AND b.user_id = $4 FOR UPDATE OF b`,
      [id, config.tz, BOOKING_DEFAULTS.freeCancelHours, req.user.id],
      client,
    );
    if (!b) throw notFound('Booking not found');
    if (b.status !== 'booked' && b.status !== 'requested') throw conflict(`This booking is already ${b.status}`);
    if (!b.canCancel) throw conflict('This slot is over and can no longer be cancelled');

    let refunded = false;
    if (b.freeCancel && (b.paidVia === 'coins' || b.paidVia === 'session')) {
      await refundVisit(client, req.user.id, { bookingId: b.id });
      refunded = true;
    }
    await client.query(
      `UPDATE slot_bookings SET status = 'cancelled', cancelled_at = now(), refunded = $2 WHERE id = $1`,
      [b.id, refunded],
    );
    let message;
    if (b.status === 'requested') message = refunded ? `Request withdrawn — ${b.costLabel ?? 'your visit'} returned to your FitKey pass` : 'Request withdrawn';
    else if (refunded) message = `Cancelled — ${b.costLabel ?? 'your visit'} returned to your FitKey pass`;
    else if (b.paidVia === 'coins' || b.paidVia === 'session') message = `Cancelled less than ${BOOKING_DEFAULTS.freeCancelHours} h before the slot, so ${b.costLabel ?? 'the visit'} is not returned`;
    else message = 'Booking cancelled';
    return { id: b.id, status: 'cancelled', refunded, message };
  });
  res.json(result);
});

router.use(accessErrors);

export default router;

import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { commissionPlan } from '../utils/commission.js';
import { badRequest, notFound, validate } from '../utils/http.js';
import {
  PAYOUT_SCHEDULE,
  addDays,
  csvRow,
  earningPerDayPaise,
  escapeHtml,
  maskPhone,
  memberStatus,
  nextMonday,
  planDaysFor,
  rupees,
} from '../utils/partner_money.js';
import { dateSchema, phoneSchema, timeSchema, uuidSchema } from '../utils/schemas.js';
import { ladiesOnlyLabels, passBlockLabels } from '../utils/slots.js';
import { accessErrors, decideBooking, expireStaleRequests, nowInTz, ownVenue, slotTimes, venueRules } from './bookings.js';
import { performCheckin, verifyMemberQr } from './checkins.js';

/**
 * Partner app Run / Sell / Earn (Partner BRD §10, contract §F + "Changes by backend-money"). Mounted at /partner
 * BEFORE routes/partner.js; every route carries its own requireAuth('partner') so paths this router doesn't define
 * fall through untouched. Staff "act-as" tokens are refused on /partner/earnings*, /partner/payouts* and
 * /partner/venues/:id/members* by the global guard in middleware/auth.js.
 */
const router = Router();
const auth = requireAuth('partner');

export const MEMBER_SOURCES = ['self', 'fitkey_pass', 'fitkey_direct', 'fitpass', 'other'];
const MANUAL_EARNING_SOURCES = ['self', 'fitpass', 'other']; // manual fitkey_* rows are notes, never money
const STATUS_ORDER = { expiring: 0, active: 1, expired: 2 };

const venueIdsOf = async (ownerId, venueId) =>
  venueId ? [(await ownVenue(venueId, ownerId)).id] : (await query(`SELECT id FROM venues WHERE owner_id = $1`, [ownerId])).map((v) => v.id);

const mondayOf = (date) => addDays(date, -((new Date(`${date}T00:00:00Z`).getUTCDay() + 6) % 7));

/**
 * Earnings rows per (day, source) for venues between from and to (inclusive):
 *   fitkey_pass   ← visit_payouts by visit_date (gross = fee ÷ 30, commission, net = amount_paise; no GST)
 *   fitkey_direct ← direct_memberships by purchase date (gross = amount paid, gst, commission, net = partner_net)
 *   self / fitpass / other ← partner_members.price_paise on joined_on (all of it is the partner's)
 */
async function earningRows(venueIds, from, to) {
  return query(
    `WITH x AS (
       SELECT visit_date AS d, 'fitkey_pass'::text AS source, COALESCE(gross_paise, amount_paise) AS gross,
              commission_paise AS commission, 0 AS gst, amount_paise AS net
       FROM visit_payouts WHERE venue_id = ANY($1) AND visit_date BETWEEN $2::date AND $3::date
       UNION ALL
       SELECT (created_at AT TIME ZONE $4)::date, 'fitkey_direct', amount_paise, commission_paise, gst_paise,
              COALESCE(partner_net_paise, amount_paise - commission_paise)
       FROM direct_memberships WHERE venue_id = ANY($1) AND status <> 'cancelled'
         AND (created_at AT TIME ZONE $4)::date BETWEEN $2::date AND $3::date
       UNION ALL
       SELECT joined_on, source, price_paise, 0, 0, price_paise
       FROM partner_members WHERE venue_id = ANY($1) AND archived_at IS NULL AND source = ANY($5)
         AND joined_on BETWEEN $2::date AND $3::date
     )
     SELECT to_char(d, 'YYYY-MM-DD') AS date, source, COUNT(*) AS count, SUM(gross) AS gross_paise,
            SUM(commission) AS commission_paise, SUM(gst) AS gst_paise, SUM(net) AS net_paise
     FROM x GROUP BY d, source ORDER BY d`,
    [venueIds, from, to, config.tz, MANUAL_EARNING_SOURCES],
  );
}

const zeroMoney = () => ({ grossPaise: 0, commissionPaise: 0, gstPaise: 0, netPaise: 0 });
function summarise(rows) {
  const totals = zeroMoney();
  const bySource = Object.fromEntries(MEMBER_SOURCES.map((s) => [s, { source: s, count: 0, ...zeroMoney() }]));
  const byDay = new Map();
  for (const r of rows) {
    const s = bySource[r.source] ?? (bySource[r.source] = { source: r.source, count: 0, ...zeroMoney() });
    s.count += r.count;
    for (const k of ['grossPaise', 'commissionPaise', 'gstPaise', 'netPaise']) {
      s[k] += r[k];
      totals[k] += r[k];
    }
    byDay.set(r.date, (byDay.get(r.date) ?? 0) + r.netPaise);
  }
  return {
    totals,
    bySource: Object.values(bySource),
    byDay: [...byDay.entries()].map(([date, netPaise]) => ({ date, netPaise })),
  };
}

// ---------------------------------------------------------------------------------------------------------- home

/**
 * GET /partner/home → { live, venues, earnings:{ todayPaise, weekPaise, monthPaise, bySource }, today:{ checkins,
 * bookings, pendingRequests, renewalsDue }, commission, checklist? (first non-live venue), setupVenue? }
 */
router.get('/home', auth, async (req, res) => {
  const [venues, owner, t] = await Promise.all([
    query(`SELECT id, name, status FROM venues WHERE owner_id = $1 ORDER BY created_at`, [req.user.id]),
    queryOne(`SELECT partner_go_live_at FROM users WHERE id = $1`, [req.user.id]),
    nowInTz(),
  ]);
  const ids = venues.map((v) => v.id);
  const monthStart = `${t.today.slice(0, 7)}-01`;
  const weekStart = mondayOf(t.today);
  const from = weekStart < monthStart ? weekStart : monthStart;
  const [rows, today] = await Promise.all([
    ids.length ? earningRows(ids, from, t.today) : [],
    queryOne(
      `SELECT (SELECT COUNT(*) FROM checkins WHERE venue_id = ANY($1) AND checkin_date = $2) AS checkins,
              (SELECT COUNT(*) FROM slot_bookings WHERE venue_id = ANY($1) AND slot_date = $2
                 AND status IN ('booked', 'attended')) AS bookings,
              (SELECT COUNT(*) FROM slot_bookings WHERE venue_id = ANY($1) AND status = 'requested'
                 AND slot_date >= $2) AS pending_requests,
              (SELECT COUNT(*) FROM partner_members WHERE venue_id = ANY($1) AND archived_at IS NULL
                 AND renewal_on BETWEEN $2::date AND $2::date + 7)
              + (SELECT COUNT(*) FROM direct_memberships WHERE venue_id = ANY($1) AND status = 'active'
                 AND ends_on BETWEEN $2::date AND $2::date + 7) AS renewals_due`,
      [ids, t.today],
    ),
  ]);
  const month = summarise(rows.filter((r) => r.date >= monthStart));
  const sumNet = (pred) => rows.filter(pred).reduce((s, r) => s + r.netPaise, 0);
  const out = {
    live: venues.some((v) => v.status === 'live'),
    venues,
    earnings: {
      todayPaise: sumNet((r) => r.date === t.today),
      weekPaise: sumNet((r) => r.date >= weekStart),
      monthPaise: month.totals.netPaise,
      bySource: month.bySource.map(({ source, netPaise }) => ({ source, netPaise })),
    },
    today: today ?? { checkins: 0, bookings: 0, pendingRequests: 0, renewalsDue: 0 },
    commission: commissionPlan(owner?.partnerGoLiveAt ?? null),
  };
  const setup = venues.find((v) => v.status !== 'live');
  if (setup) {
    out.setupVenue = setup;
    try {
      const partnerModule = await import('./partner.js');
      if (typeof partnerModule.checklistForVenue === 'function') {
        const row = await queryOne(`SELECT * FROM venues WHERE id = $1`, [setup.id]);
        out.checklist = await partnerModule.checklistForVenue(row);
      }
    } catch (e) {
      console.error('home checklist failed:', e.message);
    }
  }
  res.json(out);
});

// ------------------------------------------------------------------------------------------------------- members

const membersQuery = z.object({
  source: z.enum(MEMBER_SOURCES).optional(),
  status: z.enum(['active', 'expiring', 'expired']).optional(),
  q: z.string().trim().max(80).optional(),
});

/**
 * GET /partner/venues/:id/members?source=&status=&q= — the member register:
 * FitKey direct memberships (source fitkey_direct, phone masked), FitKey-pass visitors of the last 30 days
 * (fitkey_pass, phone masked, pricePaise = your net from their visits in those 30 days) and the members you added
 * (manual: true). earningPerDayPaise = price ÷ plan days; status expiring = renewal within 7 days.
 */
router.get('/venues/:id/members', auth, async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  const f = validate(membersQuery, req.query);
  const t = await nowInTz();
  const [direct, pass, manual] = await Promise.all([
    query(
      `SELECT d.id, d.user_id, u.name, u.phone, d.starts_on, d.ends_on, d.plan_name, d.duration, d.amount_paise,
              (d.ends_on - d.starts_on + 1) AS days
       FROM direct_memberships d JOIN users u ON u.id = d.user_id
       WHERE d.venue_id = $1 AND d.status = 'active' AND d.ends_on >= $2::date - 90
       ORDER BY d.ends_on DESC LIMIT 1000`,
      [venue.id, t.today],
    ),
    query(
      `SELECT c.user_id, u.name, u.phone, to_char(MIN(c.checkin_date), 'YYYY-MM-DD') AS first_visit,
              to_char(MAX(c.checkin_date), 'YYYY-MM-DD') AS last_visit, COUNT(*) AS visits,
              COALESCE(SUM(p.amount_paise), 0) AS net_paise
       FROM checkins c JOIN users u ON u.id = c.user_id LEFT JOIN visit_payouts p ON p.checkin_id = c.id
       WHERE c.venue_id = $1 AND c.checkin_date >= $2::date - 29 AND c.paid_via IN ('coins', 'session', 'legacy')
       GROUP BY c.user_id, u.name, u.phone ORDER BY MAX(c.checkin_date) DESC LIMIT 1000`,
      [venue.id, t.today],
    ),
    query(
      `SELECT id, user_id, name, phone, joined_on, plan_label, renewal_on, source, price_paise, remind_member, notes, created_at
       FROM partner_members WHERE venue_id = $1 AND archived_at IS NULL ORDER BY renewal_on NULLS LAST, name LIMIT 2000`,
      [venue.id],
    ),
  ]);

  let members = [
    ...direct.map((d) => ({
      key: `dm:${d.id}`,
      id: null,
      membershipId: d.id,
      name: d.name,
      phone: maskPhone(d.phone),
      joinedOn: d.startsOn,
      planLabel: d.planName,
      renewalOn: d.endsOn,
      source: 'fitkey_direct',
      pricePaise: d.amountPaise,
      earningPerDayPaise: earningPerDayPaise(d.amountPaise, d.days),
      status: memberStatus(d.endsOn, t.today),
      manual: false,
    })),
    ...pass.map((p) => ({
      key: `fp:${p.userId}`,
      id: null,
      name: p.name,
      phone: maskPhone(p.phone),
      joinedOn: p.firstVisit,
      planLabel: 'FitKey pass',
      renewalOn: null,
      source: 'fitkey_pass',
      pricePaise: p.netPaise,
      earningPerDayPaise: earningPerDayPaise(p.netPaise, 30),
      status: 'active',
      manual: false,
      visits: p.visits,
      lastVisitOn: p.lastVisit,
    })),
    ...manual.map((m) => ({
      key: `pm:${m.id}`,
      id: m.id,
      name: m.name,
      phone: m.userId ? maskPhone(m.phone) : m.phone,
      joinedOn: m.joinedOn,
      planLabel: m.planLabel,
      renewalOn: m.renewalOn,
      source: m.source,
      pricePaise: m.pricePaise,
      earningPerDayPaise: earningPerDayPaise(m.pricePaise, planDaysFor(m.planLabel, m.joinedOn, m.renewalOn)),
      status: memberStatus(m.renewalOn, t.today),
      manual: true,
      remindMember: m.remindMember,
      notes: m.notes,
    })),
  ];
  const counts = { total: members.length, active: 0, expiring: 0, expired: 0, bySource: Object.fromEntries(MEMBER_SOURCES.map((s) => [s, 0])) };
  for (const m of members) {
    counts[m.status] += 1;
    counts.bySource[m.source] = (counts.bySource[m.source] ?? 0) + 1;
  }
  if (f.source) members = members.filter((m) => m.source === f.source);
  if (f.status) members = members.filter((m) => m.status === f.status);
  if (f.q) {
    const q = f.q.toLowerCase();
    members = members.filter((m) => m.name?.toLowerCase().includes(q) || (m.manual && m.phone?.includes(f.q)));
  }
  members.sort(
    (a, b) => STATUS_ORDER[a.status] - STATUS_ORDER[b.status] || String(a.renewalOn ?? '9999').localeCompare(String(b.renewalOn ?? '9999')) || a.name.localeCompare(b.name),
  );
  res.json({ venueId: venue.id, today: t.today, counts, members });
});

const memberBody = z.object({
  name: z.string().trim().min(1).max(120),
  phone: phoneSchema.optional().nullable(),
  joinedOn: dateSchema,
  planLabel: z.string().trim().min(1).max(60),
  renewalOn: dateSchema.optional().nullable(),
  source: z.enum(MEMBER_SOURCES),
  pricePaise: z.number().int().min(0).max(100_000_000),
  remindMember: z.boolean().optional(),
  notes: z.string().trim().max(500).optional().nullable(),
});

const MEMBER_OUT = `id, name, phone, joined_on, plan_label, renewal_on, source, price_paise, remind_member, notes, created_at, updated_at`;
const memberOut = (m, today) => ({
  key: `pm:${m.id}`,
  ...m,
  earningPerDayPaise: earningPerDayPaise(m.pricePaise, planDaysFor(m.planLabel, m.joinedOn, m.renewalOn)),
  status: memberStatus(m.renewalOn, today),
  manual: true,
});

/** POST /partner/venues/:id/members { name, phone?, joinedOn, planLabel, renewalOn?, source, pricePaise, remindMember?, notes? } */
router.post('/venues/:id/members', auth, async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  const b = validate(memberBody, req.body);
  if (b.renewalOn && b.renewalOn < b.joinedOn) throw badRequest('renewalOn: Renewal date must be on or after the joining date');
  if (b.remindMember && !b.phone) throw badRequest('phone: Add the member\'s phone number to send renewal reminders');
  const row = await queryOne(
    `INSERT INTO partner_members (venue_id, name, phone, joined_on, plan_label, renewal_on, source, price_paise, remind_member, notes)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING ${MEMBER_OUT}`,
    [venue.id, b.name, b.phone ?? null, b.joinedOn, b.planLabel, b.renewalOn ?? null, b.source, b.pricePaise, b.remindMember ?? false, b.notes ?? null],
  );
  res.status(201).json({ member: memberOut(row, (await nowInTz()).today) });
});

async function ownMember(venueId, memberId) {
  const id = validate(uuidSchema, memberId);
  const m = await queryOne(`SELECT * FROM partner_members WHERE id = $1 AND venue_id = $2 AND archived_at IS NULL`, [id, venueId]);
  if (!m) throw notFound('Member not found');
  return m;
}

/** PUT /partner/venues/:id/members/:memberId — partial update of a member you added. */
router.put('/venues/:id/members/:memberId', auth, async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  const cur = await ownMember(venue.id, req.params.memberId);
  const b = validate(memberBody.partial(), req.body);
  const next = {
    name: b.name ?? cur.name,
    phone: b.phone === undefined ? cur.phone : b.phone,
    joinedOn: b.joinedOn ?? cur.joinedOn,
    planLabel: b.planLabel ?? cur.planLabel,
    renewalOn: b.renewalOn === undefined ? cur.renewalOn : b.renewalOn,
    source: b.source ?? cur.source,
    pricePaise: b.pricePaise ?? cur.pricePaise,
    remindMember: b.remindMember ?? cur.remindMember,
    notes: b.notes === undefined ? cur.notes : b.notes,
  };
  if (next.renewalOn && next.renewalOn < next.joinedOn) throw badRequest('renewalOn: Renewal date must be on or after the joining date');
  if (next.remindMember && !next.phone) throw badRequest('phone: Add the member\'s phone number to send renewal reminders');
  const row = await queryOne(
    `UPDATE partner_members SET name = $2, phone = $3, joined_on = $4, plan_label = $5, renewal_on = $6, source = $7,
            price_paise = $8, remind_member = $9, notes = $10, updated_at = now()
     WHERE id = $1 RETURNING ${MEMBER_OUT}`,
    [cur.id, next.name, next.phone, next.joinedOn, next.planLabel, next.renewalOn, next.source, next.pricePaise, next.remindMember, next.notes],
  );
  res.json({ member: memberOut(row, (await nowInTz()).today) });
});

/** DELETE /partner/venues/:id/members/:memberId — removes (archives) a member you added. */
router.delete('/venues/:id/members/:memberId', auth, async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  const cur = await ownMember(venue.id, req.params.memberId);
  await query(`UPDATE partner_members SET archived_at = now(), updated_at = now() WHERE id = $1`, [cur.id]);
  res.status(204).end();
});

// ----------------------------------------------------------------------------------------------------- slot board

/**
 * GET /partner/venues/:id/slot-board?date= → { date, slotMinutes, open, closedNote, passBlockLabels, ladiesOnlyLabels,
 * slots:[{ start, end, capacity, booked, requested, passBooked, passCap, available, blocked, passBlocked, ladiesOnly }] }
 * capacity = slot_capacity × courts; booked counts requested + booked + attended.
 */
router.get('/venues/:id/slot-board', auth, async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  const { date } = validate(z.object({ date: dateSchema.optional() }), req.query);
  const d = date ?? (await nowInTz()).today;
  const [rules, rows] = await Promise.all([
    venueRules(venue.id, d, d),
    query(
      `SELECT to_char(slot_start, 'HH24:MI') AS start, COUNT(*) AS booked,
              COUNT(*) FILTER (WHERE status = 'requested') AS requested,
              COUNT(*) FILTER (WHERE paid_via IN ('coins', 'session', 'legacy')) AS pass
       FROM slot_bookings WHERE venue_id = $1 AND slot_date = $2 AND status IN ('requested', 'booked', 'attended')
       GROUP BY slot_start`,
      [venue.id, d],
    ),
  ]);
  const counts = Object.fromEntries(rows.map((r) => [r.start, r]));
  const slots = slotTimes(venue, d, rules).map((s) => {
    const c = counts[s.start] ?? { booked: 0, requested: 0, pass: 0 };
    return {
      start: s.start,
      end: s.end,
      capacity: s.capacity,
      booked: c.booked,
      requested: c.requested,
      passBooked: c.pass,
      passCap: s.passCap,
      available: s.blocked ? 0 : Math.max(0, s.capacity - c.booked),
      blocked: s.blocked,
      closureNote: s.closureNote,
      passBlocked: s.passBlocked,
      ladiesOnly: s.ladiesOnly,
    };
  });
  const dayClosed = rules.closures.find((c) => c.closedOn === d && c.slotStart == null);
  res.json({
    date: d,
    slotMinutes: venue.slotMinutes,
    open: slots.some((s) => !s.blocked),
    closedNote: dayClosed ? (dayClosed.note ?? 'Closed') : null,
    passBlockLabels: passBlockLabels(venue, rules.blocks),
    ladiesOnlyLabels: ladiesOnlyLabels(rules.hours),
    autoAcceptBookings: venue.autoAcceptBookings,
    slots,
  });
});

// ------------------------------------------------------------------------------------------------ booking requests

/** GET /partner/venues/:id/booking-requests → { autoAcceptBookings, requests:[booking] } (undecided, upcoming). */
router.get('/venues/:id/booking-requests', auth, async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  await expireStaleRequests(venue.id);
  const requests = await query(
    `SELECT b.id, b.venue_id, b.slot_date, to_char(b.slot_start, 'HH24:MI') AS slot_start, to_char(b.slot_end, 'HH24:MI') AS slot_end,
            b.status, b.paid_via, b.cost_label, b.created_at, u.name AS member_name, u.phone AS member_phone,
            m.plan_name AS membership_name
     FROM slot_bookings b JOIN users u ON u.id = b.user_id LEFT JOIN direct_memberships m ON m.id = b.membership_id
     WHERE b.venue_id = $1 AND b.status = 'requested'
     ORDER BY b.slot_date, b.slot_start, b.created_at LIMIT 500`,
    [venue.id],
  );
  for (const r of requests) {
    r.memberPhone = maskPhone(r.memberPhone);
  }
  res.json({ autoAcceptBookings: venue.autoAcceptBookings, requests });
});

/** POST /partner/bookings/:id/accept — confirms a request; the member is notified. */
router.post('/bookings/:id/accept', auth, async (req, res) => {
  res.json({ booking: await decideBooking(req.params.id, req.user.id, 'accept') });
});

/** POST /partner/bookings/:id/reject { reason? } — declines a request; coins / session refunded; member notified. */
router.post('/bookings/:id/reject', auth, async (req, res) => {
  const { reason } = validate(z.object({ reason: z.string().trim().max(200).optional() }), req.body ?? {});
  res.json({ booking: await decideBooking(req.params.id, req.user.id, 'reject', { reason: reason || null }) });
});

/** PUT /partner/venues/:id/booking-settings { autoAcceptBookings } — off = new bookings arrive as requests. */
router.put('/venues/:id/booking-settings', auth, async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  const { autoAcceptBookings } = validate(z.object({ autoAcceptBookings: z.boolean() }), req.body);
  const row = await queryOne(
    `UPDATE venues SET auto_accept_bookings = $2, updated_at = now() WHERE id = $1 RETURNING id, auto_accept_bookings`,
    [venue.id, autoAcceptBookings],
  );
  const pending = await queryOne(`SELECT COUNT(*) AS n FROM slot_bookings WHERE venue_id = $1 AND status = 'requested'`, [venue.id]);
  res.json({ venueId: row.id, autoAcceptBookings: row.autoAcceptBookings, pendingRequests: pending.n });
});

// ------------------------------------------------------------------------------------------------------- closures

const closureBody = z
  .object({
    closedOn: dateSchema,
    slotStart: timeSchema.optional().nullable(),
    slotEnd: timeSchema.optional().nullable(),
    note: z.string().trim().max(160).optional().nullable(),
  })
  .refine((c) => (c.slotStart == null) === (c.slotEnd == null), { message: 'Give both slotStart and slotEnd, or neither for a whole day', path: ['slotEnd'] })
  .refine((c) => c.slotStart == null || c.slotEnd.slice(0, 5) > c.slotStart.slice(0, 5), { message: 'slotEnd must be after slotStart', path: ['slotEnd'] });

const CLOSURE_OUT = `id, closed_on, to_char(slot_start, 'HH24:MI') AS slot_start, to_char(slot_end, 'HH24:MI') AS slot_end, note, created_at`;

/** GET /partner/venues/:id/closures — upcoming holidays / blocked slots. */
router.get('/venues/:id/closures', auth, async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  const closures = await query(
    `SELECT ${CLOSURE_OUT} FROM venue_closures WHERE venue_id = $1 AND closed_on >= (now() AT TIME ZONE $2)::date
     ORDER BY closed_on, slot_start NULLS FIRST`,
    [venue.id, config.tz],
  );
  res.json({ closures });
});

/**
 * POST /partner/venues/:id/closures { closedOn, slotStart?, slotEnd?, note? } → { closure, affectedBookings }.
 * Existing bookings in that time are NOT cancelled automatically — affectedBookings tells the partner how many to handle.
 */
router.post('/venues/:id/closures', auth, async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  const c = validate(closureBody, req.body);
  const t = await nowInTz();
  if (c.closedOn < t.today) throw badRequest('closedOn: Pick today or a later date');
  const closure = await queryOne(
    `INSERT INTO venue_closures (venue_id, closed_on, slot_start, slot_end, note) VALUES ($1, $2, $3, $4, $5) RETURNING ${CLOSURE_OUT}`,
    [venue.id, c.closedOn, c.slotStart ?? null, c.slotEnd ?? null, c.note ?? null],
  );
  const affected = await queryOne(
    `SELECT COUNT(*) AS n FROM slot_bookings WHERE venue_id = $1 AND slot_date = $2 AND status IN ('requested', 'booked')
       AND ($3::time IS NULL OR (slot_start < $4::time AND $3::time < slot_end))`,
    [venue.id, c.closedOn, c.slotStart ?? null, c.slotEnd ?? null],
  );
  res.status(201).json({ closure, affectedBookings: affected.n });
});

/** DELETE /partner/venues/:id/closures/:closureId */
router.delete('/venues/:id/closures/:closureId', auth, async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  const id = validate(uuidSchema, req.params.closureId);
  const row = await queryOne(`DELETE FROM venue_closures WHERE id = $1 AND venue_id = $2 RETURNING id`, [id, venue.id]);
  if (!row) throw notFound('Closure not found');
  res.status(204).end();
});

// ------------------------------------------------------------------------------------------------- member QR scan

/**
 * POST /partner/venues/:id/checkin/scan { code } — the partner scans the member's QR (`FITKEYMEMBER:<jwt>` from
 * GET /checkins/member-qr). Same rules, payment, paid_via and visit_payouts as the member's own check-in
 * (409 PASS_BLOCKED / VENUE_CLOSED, 402 can't pay). → { checkin, member: { name, phone (masked) } }
 */
router.post('/venues/:id/checkin/scan', auth, async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  if (venue.status !== 'live') throw badRequest('Check-in opens once your venue is live');
  const { code } = validate(z.object({ code: z.string().trim().min(10).max(4000) }), req.body);
  const userId = verifyMemberQr(code);
  const member = await queryOne(`SELECT id, name, phone, role FROM users WHERE id = $1`, [userId]);
  if (!member || member.role !== 'user') throw badRequest('This QR is not a FitKey member QR');
  const checkin = await performCheckin({ userId, venueId: venue.id, method: 'qr', scannedBy: req.user.id });
  res.status(201).json({ checkin, member: { name: member.name, phone: maskPhone(member.phone) } });
});

// -------------------------------------------------------------------------------------------------------- earnings

/**
 * GET /partner/earnings?from=&to=&venueId= (default: this month to date) →
 * { from, to, totals:{grossPaise,commissionPaise,gstPaise,netPaise}, bySource:[{source,count,…}], byDay:[{date,netPaise}] }
 */
router.get('/earnings', auth, async (req, res) => {
  const f = validate(z.object({ from: dateSchema.optional(), to: dateSchema.optional(), venueId: uuidSchema.optional() }), req.query);
  const t = await nowInTz();
  const from = f.from ?? `${t.today.slice(0, 7)}-01`;
  const to = f.to ?? t.today;
  if (to < from) throw badRequest('to: must be on or after from');
  const ids = await venueIdsOf(req.user.id, f.venueId);
  const rows = ids.length ? await earningRows(ids, from, to) : [];
  res.json({ from, to, ...summarise(rows) });
});

/**
 * GET /partner/earnings/visits?date=&venueId= — per FitKey-pass visit that day:
 * { date, visits:[{ checkinId, memberName, venueName, time, paidVia, grossPaise, commissionPct, commissionPaise, netPaise }], totals }
 */
router.get('/earnings/visits', auth, async (req, res) => {
  const f = validate(z.object({ date: dateSchema.optional(), venueId: uuidSchema.optional() }), req.query);
  const date = f.date ?? (await nowInTz()).today;
  const ids = await venueIdsOf(req.user.id, f.venueId);
  const visits = await query(
    `SELECT p.checkin_id, u.name AS member_name, v.name AS venue_name,
            to_char(c.checked_in_at AT TIME ZONE $3, 'HH24:MI') AS time, p.paid_via,
            COALESCE(p.gross_paise, p.amount_paise) AS gross_paise, COALESCE(p.commission_pct, 0) AS commission_pct,
            p.commission_paise, p.amount_paise AS net_paise
     FROM visit_payouts p JOIN checkins c ON c.id = p.checkin_id JOIN users u ON u.id = p.user_id JOIN venues v ON v.id = p.venue_id
     WHERE p.venue_id = ANY($1) AND p.visit_date = $2 ORDER BY c.checked_in_at`,
    [ids, date, config.tz],
  );
  const totals = visits.reduce(
    (a, v) => ({ count: a.count + 1, grossPaise: a.grossPaise + v.grossPaise, commissionPaise: a.commissionPaise + v.commissionPaise, netPaise: a.netPaise + v.netPaise }),
    { count: 0, grossPaise: 0, commissionPaise: 0, netPaise: 0 },
  );
  res.json({ date, visits, totals });
});

// --------------------------------------------------------------------------------------------------------- payouts

const PAYOUT_OUT = `id, period_start, period_end, gross_paise, commission_paise, gst_paise, net_paise, status, utr, paid_at, created_at`;

/** GET /partner/payouts → { schedule:'weekly', nextPayoutOn, unsettledPaise, bankStatus, payouts:[…] } */
router.get('/payouts', auth, async (req, res) => {
  const t = await nowInTz();
  const [payouts, unsettled, bank] = await Promise.all([
    query(`SELECT ${PAYOUT_OUT} FROM partner_payouts WHERE owner_id = $1 ORDER BY period_start DESC, created_at DESC LIMIT 200`, [req.user.id]),
    queryOne(
      `SELECT COALESCE((SELECT SUM(p.amount_paise) FROM visit_payouts p JOIN venues v ON v.id = p.venue_id
                        WHERE v.owner_id = $1 AND p.payout_id IS NULL), 0)
            + COALESCE((SELECT SUM(COALESCE(d.partner_net_paise, d.amount_paise - d.commission_paise))
                        FROM direct_memberships d JOIN venues v ON v.id = d.venue_id
                        WHERE v.owner_id = $1 AND d.payout_id IS NULL AND d.status <> 'cancelled'), 0) AS paise`,
      [req.user.id],
    ),
    queryOne(`SELECT status FROM partner_bank_accounts WHERE owner_id = $1 AND is_primary ORDER BY created_at DESC LIMIT 1`, [req.user.id]),
  ]);
  res.json({
    schedule: PAYOUT_SCHEDULE,
    nextPayoutOn: nextMonday(t.today),
    unsettledPaise: unsettled.paise,
    bankStatus: bank?.status ?? null,
    payouts,
  });
});

async function ownPayout(id, ownerId) {
  const pid = validate(uuidSchema, id);
  const p = await queryOne(`SELECT ${PAYOUT_OUT}, owner_id, bank_account_id FROM partner_payouts WHERE id = $1`, [pid]);
  if (!p || p.ownerId !== ownerId) throw notFound('Payout not found');
  return p;
}

/** Earnings lines settled by a payout (FitKey-pass visits + direct plan sales). */
export async function payoutLines(payoutId) {
  return query(
    `SELECT * FROM (
       SELECT 'fitkey_pass' AS type, to_char(p.visit_date, 'YYYY-MM-DD') AS date, v.name AS venue_name, u.name AS member_name,
              p.checkin_id::text AS ref, COALESCE(p.gross_paise, p.amount_paise) AS gross_paise,
              COALESCE(p.commission_pct, 0) AS commission_pct, p.commission_paise, 0 AS gst_paise, p.amount_paise AS net_paise
       FROM visit_payouts p JOIN venues v ON v.id = p.venue_id JOIN users u ON u.id = p.user_id WHERE p.payout_id = $1
       UNION ALL
       SELECT 'fitkey_direct', to_char((d.created_at AT TIME ZONE $2)::date, 'YYYY-MM-DD'), v.name, u.name, d.id::text,
              d.amount_paise, d.commission_pct, d.commission_paise, d.gst_paise,
              COALESCE(d.partner_net_paise, d.amount_paise - d.commission_paise)
       FROM direct_memberships d JOIN venues v ON v.id = d.venue_id JOIN users u ON u.id = d.user_id WHERE d.payout_id = $1
     ) x ORDER BY date, type`,
    [payoutId, config.tz],
  );
}

/** GET /partner/payouts/:id/statement.csv — every visit / sale in the payout. */
router.get('/payouts/:id/statement.csv', auth, async (req, res) => {
  const p = await ownPayout(req.params.id, req.user.id);
  const lines = await payoutLines(p.id);
  const out = [
    csvRow(['Date', 'Type', 'Venue', 'Member', 'Reference', 'Gross (INR)', 'Commission %', 'Commission (INR)', 'GST (INR)', 'Net (INR)']),
    ...lines.map((l) =>
      csvRow([l.date, l.type === 'fitkey_pass' ? 'FitKey pass visit' : 'FitKey plan sale', l.venueName, l.memberName, l.ref,
        rupees(l.grossPaise), l.commissionPct, rupees(l.commissionPaise), rupees(l.gstPaise), rupees(l.netPaise)]),
    ),
    csvRow(['', 'Total', '', '', '', rupees(p.grossPaise), '', rupees(p.commissionPaise), rupees(p.gstPaise), rupees(p.netPaise)]),
  ];
  res.set('Content-Type', 'text/csv; charset=utf-8');
  res.set('Content-Disposition', `attachment; filename="fitkey-payout-${p.periodStart}-to-${p.periodEnd}.csv"`);
  res.send(`﻿${out.join('\r\n')}\r\n`);
});

/** GET /partner/payouts/:id/invoice — printable HTML GST invoice / settlement statement for the payout. */
router.get('/payouts/:id/invoice', auth, async (req, res) => {
  const p = await ownPayout(req.params.id, req.user.id);
  const [lines, owner, gstin, bank] = await Promise.all([
    payoutLines(p.id),
    queryOne(`SELECT name, phone, email, city FROM users WHERE id = $1`, [req.user.id]),
    queryOne(
      `SELECT doc_number FROM partner_documents WHERE owner_id = $1 AND doc_type = 'gst' AND status <> 'rejected' AND doc_number IS NOT NULL
       ORDER BY status = 'verified' DESC, created_at DESC LIMIT 1`,
      [req.user.id],
    ),
    p.bankAccountId
      ? queryOne(`SELECT holder_name, RIGHT(account_number, 4) AS last4, ifsc, bank_name FROM partner_bank_accounts WHERE id = $1`, [p.bankAccountId])
      : null,
  ]);
  const group = (type) => {
    const ls = lines.filter((l) => l.type === type);
    return ls.reduce(
      (a, l) => ({ count: a.count + 1, gross: a.gross + l.grossPaise, commission: a.commission + l.commissionPaise, gst: a.gst + l.gstPaise, net: a.net + l.netPaise }),
      { count: 0, gross: 0, commission: 0, gst: 0, net: 0 },
    );
  };
  const pass = group('fitkey_pass');
  const direct = group('fitkey_direct');
  const inr = (paise) => `₹${Number(rupees(paise)).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  const e = escapeHtml;
  const invoiceNo = `FK-PO-${p.periodEnd.replace(/-/g, '')}-${p.id.slice(0, 8).toUpperCase()}`;
  const row = (label, g) =>
    `<tr><td>${label}</td><td class="n">${g.count}</td><td class="n">${inr(g.gross)}</td><td class="n">${inr(g.gst)}</td><td class="n">${inr(g.commission)}</td><td class="n">${inr(g.net)}</td></tr>`;
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${e(invoiceNo)} · FitKey payout</title>
<style>
  body { font: 14px/1.5 system-ui, -apple-system, Segoe UI, Roboto, sans-serif; color: #111; background: #fff; margin: 0; padding: 24px; }
  .doc { max-width: 820px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px; } .muted { color: #555; } .grid { display: flex; gap: 24px; flex-wrap: wrap; margin: 16px 0; }
  .grid > div { flex: 1 1 240px; } table { width: 100%; border-collapse: collapse; margin: 16px 0; }
  th, td { border-bottom: 1px solid #ddd; padding: 8px 6px; text-align: left; } th { background: #f5f5f5; font-weight: 600; }
  td.n, th.n { text-align: right; font-variant-numeric: tabular-nums; } tfoot td { font-weight: 700; border-top: 2px solid #111; }
  .note { font-size: 12px; color: #555; } @media print { body { padding: 0; } .noprint { display: none; } }
</style></head>
<body><div class="doc">
  <h1>Tax invoice &amp; payout statement</h1>
  <div class="muted">Invoice no. ${e(invoiceNo)} · Issued ${e(new Date(p.createdAt).toISOString().slice(0, 10))}</div>
  <div class="grid">
    <div><strong>From</strong><br>FitKey (platform)<br><span class="muted">Commission &amp; GST settlement</span></div>
    <div><strong>To (partner)</strong><br>${e(owner?.name ?? '')}<br>${e(owner?.city ?? '')}<br>${gstin?.docNumber ? `GSTIN: ${e(gstin.docNumber)}` : '<span class="muted">GSTIN: not provided</span>'}</div>
    <div><strong>Period</strong><br>${e(p.periodStart)} to ${e(p.periodEnd)}<br><strong>Status</strong> ${e(p.status)}${p.utr ? `<br>UTR ${e(p.utr)}` : ''}${p.paidAt ? `<br>Paid ${e(new Date(p.paidAt).toISOString().slice(0, 10))}` : ''}</div>
  </div>
  <table>
    <thead><tr><th>Description</th><th class="n">Qty</th><th class="n">Gross</th><th class="n">GST (5% incl.)</th><th class="n">FitKey commission</th><th class="n">Net to partner</th></tr></thead>
    <tbody>
      ${row('FitKey pass check-ins (monthly fee ÷ 30)', pass)}
      ${row('Your plans sold on FitKey', direct)}
    </tbody>
    <tfoot><tr><td>Total</td><td class="n">${pass.count + direct.count}</td><td class="n">${inr(p.grossPaise)}</td><td class="n">${inr(p.gstPaise)}</td><td class="n">${inr(p.commissionPaise)}</td><td class="n">${inr(p.netPaise)}</td></tr></tfoot>
  </table>
  <p><strong>Amount payable to partner: ${inr(p.netPaise)}</strong>${bank ? ` → ${e(bank.bankName ?? '')} A/c XXXX${e(bank.last4)} (${e(bank.ifsc)})` : ''}</p>
  <p class="note">GST on plan sales is 5% included in the price (price × 5/105); FitKey collects, files and pays it on your behalf, so it is
  deducted from your payout. FitKey bears the GST on FitKey pass visits. Commission follows your Founding Partner plan
  (Year 1: 0%, Year 2: 2.5%, Year 3 onwards: 5%). Line-by-line detail: statement.csv.</p>
  <p class="note noprint">Use your browser's Print (Ctrl/Cmd + P) to save this as PDF.</p>
</div></body></html>`;
  res.type('html').send(html);
});

router.use(accessErrors);

export default router;

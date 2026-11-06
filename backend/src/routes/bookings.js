import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { HttpError, badRequest, conflict, forbidden, notFound, validate } from '../utils/http.js';
import { dateSchema, timeSchema, uuidSchema } from '../utils/schemas.js';
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

const WEEKDAY_KEYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
const weekdayOf = (date) => WEEKDAY_KEYS[new Date(`${date}T00:00:00Z`).getUTCDay()];
const toMin = (t) => {
  const [h, m] = String(t).split(':').map(Number);
  return h * 60 + (m || 0);
};
const fromMin = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;

/** Today's date and current wall-clock time in the app time zone. */
export async function nowInTz(client) {
  return queryOne(
    `SELECT to_char(now() AT TIME ZONE $1, 'YYYY-MM-DD') AS today, to_char(now() AT TIME ZONE $1, 'HH24:MI') AS now_time,
            to_char((now() AT TIME ZONE $1)::date + $2::int, 'YYYY-MM-DD') AS last_day`,
    [config.tz, BOOKING_DEFAULTS.bookAheadDays - 1],
    client,
  );
}

/** Hourly slots for a venue on a date: [{start:'06:00', end:'07:00'}]. Empty when the centre is closed that day. */
export function slotTimes(venue, date) {
  if (!(venue.openDays ?? []).includes(weekdayOf(date))) return [];
  const open = toMin(venue.opensAt ?? BOOKING_DEFAULTS.defaultOpensAt);
  let close = toMin(venue.closesAt ?? BOOKING_DEFAULTS.defaultClosesAt);
  if (close <= open) close = 24 * 60; // closes at/after midnight
  const out = [];
  for (let s = open; s + BOOKING_DEFAULTS.slotMinutes <= close; s += BOOKING_DEFAULTS.slotMinutes) {
    out.push({ start: fromMin(s), end: fromMin(s + BOOKING_DEFAULTS.slotMinutes) });
  }
  return out;
}

export async function liveVenue(venueId, client) {
  const v = await queryOne(
    `SELECT id, owner_id, name, area, city, categories, opens_at, closes_at, open_days, slot_capacity,
            visit_payout_paise, commission_pct, photos[1] AS cover_photo
     FROM venues WHERE id = $1 AND status = 'live'`,
    [venueId],
    client,
  );
  if (!v) throw notFound('Centre not found or not live on FitKey');
  return v;
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
       (SELECT COUNT(*) FROM slot_bookings WHERE membership_id = $1 AND status <> 'cancelled' AND slot_date = $2::date
          AND id IS DISTINCT FROM $3::uuid) +
       (SELECT COUNT(*) FROM checkins WHERE membership_id = $1 AND booking_id IS NULL AND checkin_date = $2::date) AS day,
       (SELECT COUNT(*) FROM slot_bookings WHERE membership_id = $1 AND status <> 'cancelled'
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

const partnerListSchema = z.object({
  date: dateSchema.optional(),
  from: dateSchema.optional(),
  to: dateSchema.optional(),
  status: z.enum(['booked', 'attended', 'cancelled', 'all']).default('all'),
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
            b.status, b.paid_via, b.cost_label, b.cost_amount, b.refunded, b.attended_at, b.cancelled_at, b.created_at,
            u.name AS member_name, RIGHT(u.phone, 4) AS phone_last4, m.plan_name AS membership_name
     FROM slot_bookings b JOIN users u ON u.id = b.user_id
     LEFT JOIN direct_memberships m ON m.id = b.membership_id
     WHERE b.venue_id = $1 AND b.slot_date BETWEEN $2 AND $3
       AND ($4 = 'all' OR b.status = $4) AND ($5::text IS NULL OR b.paid_via = $5)
     ORDER BY b.slot_date, b.slot_start, b.created_at`,
    [venue.id, from, to, f.status, f.paidVia ?? null],
  );
  const counts = { booked: 0, attended: 0, cancelled: 0 };
  const byPaidVia = { coins: 0, session: 0, membership: 0, legacy: 0 };
  for (const b of bookings) {
    counts[b.status] += 1;
    if (b.status !== 'cancelled' && b.paidVia) byPaidVia[b.paidVia] += 1;
  }
  res.json({ from, to, count: bookings.length, counts, byPaidVia, bookings });
});

/**
 * GET /bookings/partner/venues/:venueId/slots?date= — capacity per hourly slot (booked / capacity) for a day.
 */
partner.get('/venues/:venueId/slots', async (req, res) => {
  const venue = await ownVenue(req.params.venueId, req.user.id);
  const { date } = validate(z.object({ date: dateSchema.optional() }), req.query);
  const d = date ?? (await nowInTz()).today;
  const booked = await query(
    `SELECT to_char(slot_start, 'HH24:MI') AS start, COUNT(*) AS booked FROM slot_bookings
     WHERE venue_id = $1 AND slot_date = $2 AND status <> 'cancelled' GROUP BY slot_start`,
    [venue.id, d],
  );
  const map = Object.fromEntries(booked.map((b) => [b.start, b.booked]));
  const slots = slotTimes(venue, d).map((s) => ({ ...s, capacity: venue.slotCapacity, booked: map[s.start] ?? 0 }));
  res.json({ date: d, capacity: venue.slotCapacity, open: slots.length > 0, slots });
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
            p.amount_paise AS payout_paise
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
  const [fitkey, memberships, legacy] = await Promise.all([
    fitkeyCost(req.user.id, venue),
    query(
      `SELECT id, plan_name, duration, starts_on, ends_on, max_visits_per_day, max_visits_per_week,
              CASE WHEN $3::date < starts_on THEN 'upcoming' ELSE 'active' END AS state
       FROM direct_memberships WHERE user_id = $1 AND venue_id = $2 AND status = 'active' AND ends_on >= $3::date
       ORDER BY starts_on`,
      [req.user.id, venue.id, t.today],
    ),
    legacyPass(req.user.id, venue.categories),
  ]);
  res.json({
    venueId: venue.id,
    today: t.today,
    hasFitkeyPass: Boolean(fitkey.method && fitkey.sufficient),
    fitkey,
    legacy,
    memberships,
    hasMembership: memberships.some((m) => m.state === 'active'),
  });
});

/**
 * GET /bookings/venues/:venueId/slots?date=YYYY-MM-DD — bookable days, hourly slots with availability and the
 * cost of a visit BEFORE booking ("120 coins", "1 session", "Included in your pass / membership").
 */
router.get('/venues/:venueId/slots', async (req, res) => {
  const venue = await liveVenue(validate(uuidSchema, req.params.venueId));
  const { date } = validate(z.object({ date: dateSchema.optional() }), req.query);
  const t = await nowInTz();
  const d = date ?? t.today;
  if (d < t.today || d > t.lastDay) throw badRequest(`Pick a day between ${t.today} and ${t.lastDay}`);

  const days = [];
  for (let i = 0; i < BOOKING_DEFAULTS.bookAheadDays; i++) {
    const day = new Date(`${t.today}T00:00:00Z`);
    day.setUTCDate(day.getUTCDate() + i);
    const iso = day.toISOString().slice(0, 10);
    days.push({ date: iso, weekday: weekdayOf(iso), open: slotTimes(venue, iso).length > 0 });
  }

  const [booked, mine, cost] = await Promise.all([
    query(
      `SELECT to_char(slot_start, 'HH24:MI') AS start, COUNT(*) AS booked FROM slot_bookings
       WHERE venue_id = $1 AND slot_date = $2 AND status <> 'cancelled' GROUP BY slot_start`,
      [venue.id, d],
    ),
    queryOne(
      `SELECT id, to_char(slot_start, 'HH24:MI') AS slot_start, to_char(slot_end, 'HH24:MI') AS slot_end, status, paid_via, cost_label
       FROM slot_bookings WHERE user_id = $1 AND venue_id = $2 AND slot_date = $3 AND status <> 'cancelled'`,
      [req.user.id, venue.id, d],
    ),
    visitPreview(req.user.id, venue, d),
  ]);
  const map = Object.fromEntries(booked.map((b) => [b.start, b.booked]));
  const slots = slotTimes(venue, d).map((s) => {
    const n = map[s.start] ?? 0;
    const past = d === t.today && s.start <= t.nowTime;
    return { ...s, capacity: venue.slotCapacity, booked: n, left: Math.max(0, venue.slotCapacity - n), past, available: !past && n < venue.slotCapacity };
  });
  res.json({
    venue: { id: venue.id, name: venue.name, area: venue.area, city: venue.city, coverPhoto: venue.coverPhoto },
    date: d,
    days,
    slots,
    cost,
    myBooking: mine,
    freeCancelHours: BOOKING_DEFAULTS.freeCancelHours,
  });
});

const bookSchema = z.object({ venueId: uuidSchema, date: dateSchema, start: timeSchema });

/**
 * POST /bookings {venueId, date, start} — books an hourly slot. Paid by a direct membership (free) or the FitKey
 * pass (wallet.chargeVisit) inside the same transaction. 402 = can't pay (reason in `error`).
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
    const slot = slotTimes(venue, body.date).find((s) => s.start === start);
    if (!slot) throw badRequest(`${venue.name} has no ${start} slot on that day`);
    if (body.date === t.today && slot.start <= t.nowTime) throw badRequest('That slot has already started — pick a later one');

    const dup = await queryOne(
      `SELECT to_char(slot_start, 'HH24:MI') AS start FROM slot_bookings
       WHERE user_id = $1 AND venue_id = $2 AND slot_date = $3 AND status <> 'cancelled'`,
      [req.user.id, venue.id, body.date],
      client,
    );
    if (dup) throw conflict(`You already have a ${dup.start} booking at ${venue.name} that day`);
    const taken = await queryOne(
      `SELECT COUNT(*) AS n FROM slot_bookings WHERE venue_id = $1 AND slot_date = $2 AND slot_start = $3 AND status <> 'cancelled'`,
      [venue.id, body.date, start],
      client,
    );
    if (taken.n >= venue.slotCapacity) throw conflict('That slot is full — pick another time');

    const row = await queryOne(
      `INSERT INTO slot_bookings (user_id, venue_id, slot_date, slot_start, slot_end) VALUES ($1, $2, $3, $4, $5) RETURNING id`,
      [req.user.id, venue.id, body.date, slot.start, slot.end],
      client,
    );

    const m = await membershipFor(req.user.id, venue.id, body.date, client, { excludeBookingId: row.id });
    let pay;
    if (m.usable) {
      pay = { paidVia: 'membership', amount: 0, label: 'Included in your membership', membershipId: m.membership.id };
    } else {
      try {
        pay = await payWithFitkey(client, req.user.id, venue, { bookingId: row.id });
      } catch (e) {
        if (e instanceof HttpError && e.status === 402 && m.reason) {
          throw new HttpError(402, `${m.reason}, and your FitKey pass can't cover it: ${e.message}`, e.details);
        }
        throw e;
      }
    }

    return queryOne(
      `UPDATE slot_bookings SET paid_via = $2, cost_amount = $3, cost_label = $4, membership_id = $5, subscription_id = $6
       WHERE id = $1
       RETURNING id, venue_id, slot_date, to_char(slot_start, 'HH24:MI') AS slot_start, to_char(slot_end, 'HH24:MI') AS slot_end,
                 status, paid_via, cost_amount, cost_label, created_at`,
      [row.id, pay.paidVia, pay.amount, pay.label, pay.membershipId ?? null, pay.subscriptionId ?? null],
      client,
    );
  });

  res.status(201).json({ booking });
});

const BOOKING_SELECT = `
  SELECT b.id, b.venue_id, v.name AS venue_name, v.area AS venue_area, v.city AS venue_city, v.categories AS venue_categories,
         v.photos[1] AS venue_cover_photo, b.slot_date, to_char(b.slot_start, 'HH24:MI') AS slot_start,
         to_char(b.slot_end, 'HH24:MI') AS slot_end, b.status, b.paid_via, b.cost_amount, b.cost_label, b.refunded,
         b.attended_at, b.cancelled_at, b.created_at,
         ((b.slot_date + b.slot_start)::timestamp AT TIME ZONE $2) AS starts_at,
         ((b.slot_date + b.slot_end)::timestamp AT TIME ZONE $2) AS ends_at,
         (b.status = 'booked' AND ((b.slot_date + b.slot_end)::timestamp AT TIME ZONE $2) > now()) AS can_cancel,
         (((b.slot_date + b.slot_start)::timestamp AT TIME ZONE $2) - now() >= make_interval(hours => $3)) AS free_cancel
  FROM slot_bookings b JOIN venues v ON v.id = b.venue_id`;

/** GET /bookings/me?scope=upcoming|past|all — the member's bookings. */
router.get('/me', async (req, res) => {
  const { scope } = validate(z.object({ scope: z.enum(['upcoming', 'past', 'all']).default('all') }), req.query);
  const cond = {
    upcoming: `AND b.status = 'booked' AND ((b.slot_date + b.slot_end)::timestamp AT TIME ZONE $2) > now()`,
    past: `AND NOT (b.status = 'booked' AND ((b.slot_date + b.slot_end)::timestamp AT TIME ZONE $2) > now())`,
    all: '',
  }[scope];
  const bookings = await query(
    `${BOOKING_SELECT} WHERE b.user_id = $1 ${cond}
     ORDER BY CASE WHEN b.status = 'booked' AND ((b.slot_date + b.slot_end)::timestamp AT TIME ZONE $2) > now() THEN 0 ELSE 1 END,
              CASE WHEN b.status = 'booked' AND ((b.slot_date + b.slot_end)::timestamp AT TIME ZONE $2) > now()
                   THEN b.slot_date + b.slot_start END ASC,
              b.slot_date DESC, b.slot_start DESC
     LIMIT 100`,
    [req.user.id, config.tz, BOOKING_DEFAULTS.freeCancelHours],
  );
  res.json({ bookings, freeCancelHours: BOOKING_DEFAULTS.freeCancelHours });
});

/**
 * POST /bookings/:id/cancel — cancels an upcoming booking. Free (coins/session returned via wallet.refundVisit)
 * until 2 h before the slot; later it is cancelled without a refund. Membership/legacy bookings cost nothing.
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
    if (b.status !== 'booked') throw conflict(`This booking is already ${b.status}`);
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
    if (refunded) message = `Cancelled — ${b.costLabel ?? 'your visit'} returned to your FitKey pass`;
    else if (b.paidVia === 'coins' || b.paidVia === 'session') message = `Cancelled less than ${BOOKING_DEFAULTS.freeCancelHours} h before the slot, so ${b.costLabel ?? 'the visit'} is not returned`;
    else message = 'Booking cancelled';
    return { id: b.id, status: 'cancelled', refunded, message };
  });
  res.json(result);
});

export default router;

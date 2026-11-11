import crypto from 'node:crypto';
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, notFound, validate } from '../utils/http.js';
import { AMENITIES, VENUE_CATEGORY_IDS, WEEKDAYS } from '../utils/constants.js';
import { dateSchema, phoneSchema, timeSchema } from '../utils/schemas.js';
import { commissionPlan, passVisitPayout } from '../utils/commission.js';
import { listingTimeline, setListingStatus } from '../utils/listing.js';
import {
  DESCRIPTION_MIN,
  PARTNER_TYPES,
  PHOTOS_MAX,
  SPORTS,
  SPORTS_CATEGORY,
  submitBlockers,
  venueChecklist,
} from '../utils/partner_rules.js';
import { QR_PREFIX } from './checkins.js';
import { FILES_PATH } from './files.js';
import { emailInputSchema, loadMe } from './me.js';
import partnerListingRouter, { assertListingAccess } from './partner_listing.js';

export const photoUrlSchema = z
  .string()
  .refine(
    (s) => /^https?:\/\/\S+$/.test(s) || new RegExp(`^${FILES_PATH}[0-9a-f-]{36}$`).test(s),
    'Invalid photo URL',
  );

/**
 * FITKEY Partner app: venue listing (10-step wizard, Partner BRD §B), profile & commission plan (§A), status
 * timeline (§E), check-in codes and attendance. Documents / KYC / bank / agreement / assisted listing live in
 * partner_listing.js (mounted below, same /partner prefix).
 */
const router = Router();
router.use(requireAuth('partner'));

const CHECKIN_CODE_TTL_SECONDS = 5 * 60;

// ------------------------------------------------------------------------------------------------ profile (§A)

/** PUT /partner/profile { partnerType?, name?, email?, city? } → { user } */
router.put('/profile', async (req, res) => {
  const b = validate(
    z.object({
      partnerType: z.enum(PARTNER_TYPES).optional(),
      name: z.string().trim().min(2).max(120).optional(),
      email: emailInputSchema,
      city: z.string().trim().min(2).max(80).optional(),
    }),
    req.body ?? {},
  );
  await query(
    `UPDATE users SET partner_type = COALESCE($2, partner_type), name = COALESCE($3, name),
       email = COALESCE($4, email), city = COALESCE($5, city), updated_at = now()
     WHERE id = $1`,
    [req.user.id, b.partnerType ?? null, b.name ?? null, b.email ?? null, b.city ?? null],
  );
  res.json({ user: await loadMe(req.user.id, req) });
});

/** GET /partner/commission-plan — founding-partner plan counted from the partner's go-live date. */
router.get('/commission-plan', async (req, res) => {
  const u = await queryOne(`SELECT partner_go_live_at FROM users WHERE id = $1`, [req.user.id]);
  res.json(commissionPlan(u?.partnerGoLiveAt ?? null));
});

/** GET /partner/listings/:entityType/:id/timeline — owner (or the staff member who listed it). */
router.get('/listings/:entityType/:id/timeline', async (req, res) => {
  await assertListingAccess(req.params.entityType, req.params.id, req);
  res.json(await listingTimeline(req.params.entityType, req.params.id));
});

// ------------------------------------------------------------------------------------------------ venues (§B)

const hhmm = timeSchema.transform((s) => s.slice(0, 5));
const uuid = z.string().uuid();

const hoursRow = z
  .object({
    weekday: z.enum(WEEKDAYS),
    opensAt: hhmm,
    closesAt: hhmm,
    kind: z.enum(['open', 'ladies_only']).default('open'),
  })
  .refine((r) => r.closesAt > r.opensAt, { message: 'Closing time must be after opening time', path: ['closesAt'] });

const passBlockRow = z
  .object({
    id: uuid.optional(),
    days: z.array(z.enum(WEEKDAYS)).min(1).default([...WEEKDAYS]),
    startsAt: hhmm,
    endsAt: hhmm,
    note: z.string().trim().max(120).nullish(),
  })
  .refine((r) => r.endsAt > r.startsAt, { message: 'End time must be after start time', path: ['endsAt'] });

const closureRow = z
  .object({
    id: uuid.optional(),
    closedOn: dateSchema,
    slotStart: hhmm.nullish(),
    slotEnd: hhmm.nullish(),
    note: z.string().trim().max(160).nullish(),
  })
  .refine((r) => (r.slotStart == null) === (r.slotEnd == null) && (r.slotStart == null || r.slotEnd > r.slotStart), {
    message: 'Give both slot start and end (end after start), or neither for a full-day closure',
    path: ['slotEnd'],
  });

/** Every field optional (PUT); POST additionally requires name + categories (see createSchema). */
const venueFields = z.object({
  name: z.string().trim().min(2).max(160),
  description: z.string().trim().max(2000).nullish(),
  categories: z.array(z.enum(VENUE_CATEGORY_IDS)).min(1),
  address: z.string().trim().min(5).max(500),
  area: z.string().trim().max(120).nullish(),
  city: z.string().trim().min(2).max(80),
  latitude: z.number().min(-90).max(90).nullish(),
  longitude: z.number().min(-180).max(180).nullish(),
  opensAt: timeSchema.nullish(),
  closesAt: timeSchema.nullish(),
  openDays: z.array(z.enum(WEEKDAYS)),
  contactPhone: phoneSchema.nullish(),
  contactEmail: emailInputSchema.nullable(),
  trainerAvailable: z.boolean(),
  equipment: z.array(z.string().trim().min(1).max(80)).max(100),
  amenities: z.array(z.enum(AMENITIES)),
  // Photo URLs: either uploaded via POST /uploads (server-relative /api/v1/files/<id>) or absolute https URLs.
  photos: z.array(photoUrlSchema).max(PHOTOS_MAX, `Up to ${PHOTOS_MAX} photos`),
  // BRD v2
  sports: z.array(z.enum(SPORTS)).max(SPORTS.length),
  videoUrl: z.string().trim().url().max(500).nullish(),
  fitkeyPassMode: z.enum(['all', 'blocked']),
  passAccepted: z.boolean(),
  monthlyFeePaise: z.number().int().positive().max(100_000_000).nullish(),
  slotMinutes: z.number().int().min(15).max(480),
  slotCapacity: z.number().int().min(1).max(1000),
  passSlotCap: z.number().int().min(0).max(1000).nullish(),
  courts: z.number().int().min(1).max(100),
  autoAcceptBookings: z.boolean(),
  listingStep: z.number().int().min(1).max(10),
  hours: z.array(hoursRow).max(70),
  passBlocks: z.array(passBlockRow).max(30),
  closures: z.array(closureRow).max(200),
});
export const updateSchema = venueFields.partial();
export const createSchema = updateSchema.extend({ name: venueFields.shape.name, categories: venueFields.shape.categories });

/** API field → venues column (plain assignments). */
const VENUE_COLUMNS = {
  name: 'name', description: 'description', categories: 'categories', address: 'address', area: 'area', city: 'city',
  latitude: 'latitude', longitude: 'longitude', opensAt: 'opens_at', closesAt: 'closes_at', openDays: 'open_days',
  contactPhone: 'contact_phone', contactEmail: 'contact_email', trainerAvailable: 'trainer_available',
  equipment: 'equipment', amenities: 'amenities', photos: 'photos', sports: 'sports', videoUrl: 'video_url',
  fitkeyPassMode: 'fitkey_pass_mode', passAccepted: 'pass_accepted', monthlyFeePaise: 'monthly_fee_paise',
  slotMinutes: 'slot_minutes', slotCapacity: 'slot_capacity', passSlotCap: 'pass_slot_cap', courts: 'courts',
  autoAcceptBookings: 'auto_accept_bookings',
};

/**
 * Cross-field rules + derived columns. `existing` is the current row (null on create). Mutates and returns v.
 *  - description: when given it must be ≥ 40 chars ('' clears it)
 *  - sports only with the sports_club category; dropping the category clears them
 *  - hours rows also fill the legacy opens_at / closes_at / open_days (old apps, booking code)
 */
export function normalizeVenueInput(v, existing) {
  if (typeof v.description === 'string') {
    if (v.description.length === 0) v.description = null;
    else if (v.description.length < DESCRIPTION_MIN) {
      throw badRequest(`description: Write at least ${DESCRIPTION_MIN} characters about your centre`);
    }
  }
  const cats = v.categories ?? existing?.categories ?? [];
  if (!cats.includes(SPORTS_CATEGORY)) {
    if (v.sports?.length) throw badRequest('sports: Pick the Sports club category to add sports');
    if (existing?.sports?.length && v.categories) v.sports = [];
  }
  if (v.sports) v.sports = [...new Set(v.sports)];
  if (v.hours?.length) {
    const open = v.hours.filter((h) => h.kind === 'open');
    const rows = open.length ? open : v.hours;
    if (v.opensAt === undefined) v.opensAt = rows.reduce((m, h) => (h.opensAt < m ? h.opensAt : m), '23:59');
    if (v.closesAt === undefined) v.closesAt = rows.reduce((m, h) => (h.closesAt > m ? h.closesAt : m), '00:00');
    if (v.openDays === undefined) v.openDays = WEEKDAYS.filter((d) => v.hours.some((h) => h.weekday === d));
  }
  if (v.passBlocks) v.passBlocks = v.passBlocks.map((b) => ({ ...b, days: [...new Set(b.days)] }));
  return v;
}

/** SET fragments + params for the plain columns and the derived ones. */
function venueAssignments(v, params) {
  const cols = [];
  const vals = [];
  for (const [field, col] of Object.entries(VENUE_COLUMNS)) {
    if (v[field] === undefined) continue;
    params.push(v[field]);
    cols.push(col);
    vals.push(`$${params.length}`);
  }
  return { cols, vals };
}

/** Replace-all writes of the nested arrays (only those present in the body). */
async function writeVenueChildren(client, venueId, v) {
  if (v.hours) {
    await query(`DELETE FROM venue_hours WHERE venue_id = $1`, [venueId], client);
    for (const h of v.hours) {
      await query(`INSERT INTO venue_hours (venue_id, weekday, opens_at, closes_at, kind) VALUES ($1, $2, $3, $4, $5)`,
        [venueId, h.weekday, h.opensAt, h.closesAt, h.kind], client);
    }
  }
  if (v.passBlocks) {
    await query(`DELETE FROM venue_pass_blocks WHERE venue_id = $1`, [venueId], client);
    for (const b of v.passBlocks) {
      await query(
        `INSERT INTO venue_pass_blocks (id, venue_id, days, starts_at, ends_at, note)
         VALUES (COALESCE($1::uuid, gen_random_uuid()), $2, $3, $4, $5, $6) ON CONFLICT (id) DO NOTHING`,
        [b.id ?? null, venueId, b.days, b.startsAt, b.endsAt, b.note ?? null], client);
    }
  }
  if (v.closures) {
    // Past closures are history (attendance / payouts) — only upcoming ones are replaced.
    await query(`DELETE FROM venue_closures WHERE venue_id = $1 AND closed_on >= (now() AT TIME ZONE $2)::date`,
      [venueId, config.tz], client);
    for (const c of v.closures) {
      await query(
        `INSERT INTO venue_closures (id, venue_id, closed_on, slot_start, slot_end, note)
         VALUES (COALESCE($1::uuid, gen_random_uuid()), $2, $3, $4, $5, $6)
         ON CONFLICT (id) DO UPDATE SET closed_on = EXCLUDED.closed_on, slot_start = EXCLUDED.slot_start,
           slot_end = EXCLUDED.slot_end, note = EXCLUDED.note WHERE venue_closures.venue_id = EXCLUDED.venue_id`,
        [c.id ?? null, venueId, c.closedOn, c.slotStart ?? null, c.slotEnd ?? null, c.note ?? null], client);
    }
  }
}

async function ownVenue(venueId, ownerId) {
  if (!uuid.safeParse(venueId).success) throw notFound('Venue not found');
  const venue = await queryOne(`SELECT * FROM venues WHERE id = $1 AND owner_id = $2`, [venueId, ownerId]);
  if (!venue) throw notFound('Venue not found');
  return venue;
}

/** Inputs for the checklist that live outside the venues row. */
async function venueChecklistContext(venueId, ownerId) {
  return queryOne(
    `SELECT (SELECT COUNT(*) FROM venue_hours WHERE venue_id = $1) AS hours_count,
            (SELECT COUNT(*) FROM venue_pass_blocks WHERE venue_id = $1) AS pass_blocks_count,
            (SELECT COUNT(*) FROM centre_plans WHERE venue_id = $1 AND is_active AND archived_at IS NULL
               AND approval_status <> 'rejected') AS active_plans,
            EXISTS (SELECT 1 FROM partner_documents WHERE entity_type = 'venue' AND entity_id = $1
                      AND doc_type = 'licence' AND status <> 'rejected') AS has_licence,
            EXISTS (SELECT 1 FROM partner_kyc WHERE owner_id = $2 AND status <> 'rejected') AS has_kyc,
            EXISTS (SELECT 1 FROM partner_bank_accounts WHERE owner_id = $2 AND is_primary
                      AND status IN ('pending', 'verified')) AS has_bank`,
    [venueId, ownerId],
  );
}

/** Checklist for a venue row (exported for /partner/home and the admin API). */
export async function checklistForVenue(venue) {
  return venueChecklist(venue, await venueChecklistContext(venue.id, venue.ownerId));
}

/** Full venue JSON: row + hours, passBlocks, upcoming closures, plans, checklist, timeline, passPayoutPreview. */
export async function venueDetail(venue) {
  const [hours, passBlocks, closures, plans, owner, listedBy, timeline, checklist] = await Promise.all([
    query(
      `SELECT weekday, to_char(opens_at, 'HH24:MI') AS opens_at, to_char(closes_at, 'HH24:MI') AS closes_at, kind
       FROM venue_hours WHERE venue_id = $1
       ORDER BY array_position(ARRAY['mon','tue','wed','thu','fri','sat','sun']::varchar[], weekday), opens_at`,
      [venue.id],
    ),
    query(
      `SELECT id, days, to_char(starts_at, 'HH24:MI') AS starts_at, to_char(ends_at, 'HH24:MI') AS ends_at, note
       FROM venue_pass_blocks WHERE venue_id = $1 ORDER BY starts_at, created_at`,
      [venue.id],
    ),
    query(
      `SELECT id, closed_on, to_char(slot_start, 'HH24:MI') AS slot_start, to_char(slot_end, 'HH24:MI') AS slot_end, note
       FROM venue_closures WHERE venue_id = $1 AND closed_on >= (now() AT TIME ZONE $2)::date
       ORDER BY closed_on, slot_start NULLS FIRST`,
      [venue.id, config.tz],
    ),
    query(
      `SELECT p.id, p.name, p.description, p.duration, p.duration_days, p.price_paise, p.inclusions,
              p.max_visits_per_day, p.max_visits_per_week, p.offer_pct,
              ROUND(p.price_paise * (100 - p.offer_pct) / 100.0)::int AS effective_price_paise,
              p.is_active, p.approval_status, p.review_note, p.created_at
       FROM centre_plans p WHERE p.venue_id = $1 AND p.archived_at IS NULL ORDER BY p.duration_days, p.price_paise`,
      [venue.id],
    ),
    queryOne(`SELECT partner_go_live_at FROM users WHERE id = $1`, [venue.ownerId]),
    venue.listedBy ? queryOne(`SELECT name FROM users WHERE id = $1`, [venue.listedBy]) : null,
    listingTimeline('venue', venue.id),
    checklistForVenue(venue),
  ]);
  return {
    ...venue,
    listedByName: listedBy?.name ?? null,
    hours,
    passBlocks,
    closures,
    plans,
    checklist,
    timeline,
    passPayoutPreview: venue.monthlyFeePaise ? passVisitPayout(venue.monthlyFeePaise, owner?.partnerGoLiveAt ?? null) : null,
  };
}

router.get('/venues', async (req, res) => {
  const venues = await query(
    `SELECT v.id, v.name, v.area, v.city, v.categories, v.sports, v.status, v.review_note, v.photos[1] AS cover_photo, v.updated_at,
            v.rating_avg, v.rating_count, v.listing_step, v.submitted_at, v.admin_approved_at, v.partner_accepted_at,
            v.go_live_at, v.listed_by,
            (SELECT COUNT(*) FROM checkins c WHERE c.venue_id = v.id AND c.checkin_date = (now() AT TIME ZONE $2)::date) AS today_checkins,
            (SELECT COUNT(*) FROM checkins c WHERE c.venue_id = v.id
               AND c.checkin_date >= date_trunc('month', now() AT TIME ZONE $2)::date) AS month_checkins
     FROM venues v WHERE v.owner_id = $1 ORDER BY v.created_at DESC`,
    [req.user.id, config.tz],
  );
  res.json({ venues });
});

router.get('/venues/:id', async (req, res) => {
  res.json({ venue: await venueDetail(await ownVenue(req.params.id, req.user.id)) });
});

router.post('/venues', async (req, res) => {
  const v = normalizeVenueInput(validate(createSchema, req.body ?? {}), null);
  const params = [req.user.id, req.staffId ?? null];
  const { cols, vals } = venueAssignments(v, params);
  if (v.passAccepted) {
    cols.push('pass_consent_at');
    vals.push('now()');
  }
  if (v.listingStep !== undefined) {
    params.push(v.listingStep);
    cols.push('listing_step');
    vals.push(`${params.length}`);
  }
  const venue = await withTransaction(async (client) => {
    const row = await queryOne(
      `INSERT INTO venues (owner_id, listed_by${cols.map((c) => `, ${c}`).join('')})
       VALUES ($1, $2${vals.map((x) => `, ${x}`).join('')}) RETURNING *`,
      params,
      client,
    );
    await writeVenueChildren(client, row.id, v);
    return row;
  });
  res.status(201).json({ venue: await venueDetail(venue) });
});

/** PUT /partner/venues/:id — edits venue details (status is unchanged; use /submit to send for review). */
router.put('/venues/:id', async (req, res) => {
  const existing = await ownVenue(req.params.id, req.user.id);
  const v = normalizeVenueInput(validate(updateSchema, req.body ?? {}), existing);
  const params = [existing.id, req.user.id];
  const { cols, vals } = venueAssignments(v, params);
  const sets = cols.map((c, i) => `${c} = ${vals[i]}`);
  if (v.passAccepted !== undefined) {
    sets.push(v.passAccepted ? 'pass_consent_at = COALESCE(pass_consent_at, now())' : 'pass_consent_at = NULL');
  }
  if (v.listingStep !== undefined) {
    params.push(v.listingStep);
    sets.push(`listing_step = GREATEST(listing_step, $${params.length})`);
  }
  sets.push('updated_at = now()');
  const venue = await withTransaction(async (client) => {
    const row = await queryOne(
      `UPDATE venues SET ${sets.join(', ')} WHERE id = $1 AND owner_id = $2 RETURNING *`,
      params,
      client,
    );
    await writeVenueChildren(client, row.id, v);
    return row;
  });
  res.json({ venue: await venueDetail(venue) });
});

/** DELETE /partner/venues/:id — only drafts and rejected listings can be deleted. */
router.delete('/venues/:id', async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  if (!['draft', 'rejected'].includes(venue.status)) throw badRequest('Only draft or rejected listings can be deleted');
  await query(`DELETE FROM venues WHERE id = $1`, [venue.id]);
  res.status(204).end();
});

/**
 * POST /partner/venues/:id/submit — draft / changes_needed / rejected → submitted (FITKEY team then reviews).
 * 400 { error, missing:[{step,label,hint}] } while steps 1–9 are incomplete.
 */
router.post('/venues/:id/submit', async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  if (!['draft', 'changes_needed', 'rejected'].includes(venue.status)) {
    throw badRequest(`Venue is already ${venue.status.replace('_', ' ')}`);
  }
  const missing = submitBlockers(await checklistForVenue(venue));
  if (missing.length) {
    return res.status(400).json({
      error: `Complete these steps before submitting: ${missing.map((m) => m.label).join(', ')}`,
      missing,
    });
  }
  await setListingStatus('venue', venue.id, 'submitted', {
    actorId: req.staffId ?? req.user.id,
    extraSet: ', listing_step = 10',
  });
  res.json({ venue: await venueDetail(await ownVenue(venue.id, req.user.id)) });
});

// Documents, KYC, bank, agreement OTP, pending acceptance, assisted listing (staff).
router.use(partnerListingRouter);

/**
 * GET /partner/venues/:id/checkin-code — what the venue displays at the front desk:
 * a short-lived QR payload (signed token) and a 6-digit OTP fallback. The partner app refreshes it before expiry.
 */
router.get('/venues/:id/checkin-code', async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  if (venue.status !== 'live') throw badRequest('Check-in opens once your venue is live');

  const token = jwt.sign({ typ: 'checkin', vid: venue.id, n: crypto.randomUUID() }, config.checkinSecret, {
    expiresIn: CHECKIN_CODE_TTL_SECONDS,
  });
  const otp = String(crypto.randomInt(100000, 1000000));
  const code = await queryOne(
    `INSERT INTO checkin_codes (venue_id, otp, expires_at)
     VALUES ($1, $2, now() + make_interval(secs => $3)) RETURNING expires_at`,
    [venue.id, otp, CHECKIN_CODE_TTL_SECONDS],
  );
  // Housekeeping: drop codes that expired over a day ago.
  await query(`DELETE FROM checkin_codes WHERE venue_id = $1 AND expires_at < now() - interval '1 day'`, [venue.id]);

  res.json({ qr: `${QR_PREFIX}${token}`, otp, expiresAt: code.expiresAt, venueId: venue.id });
});

/** GET /partner/venues/:id/attendance?date=YYYY-MM-DD — members who checked in that day. */
router.get('/venues/:id/attendance', async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  const { date } = validate(z.object({ date: dateSchema.optional() }), req.query);
  const checkins = await query(
    `SELECT c.id, c.checked_in_at, c.method, u.name AS member_name, RIGHT(u.phone, 4) AS phone_last4, p.name AS plan_name
     FROM checkins c JOIN users u ON u.id = c.user_id
     LEFT JOIN subscriptions s ON s.id = c.subscription_id LEFT JOIN plans p ON p.id = s.plan_id
     WHERE c.venue_id = $1 AND c.checkin_date = COALESCE($2::date, (now() AT TIME ZONE $3)::date)
     ORDER BY c.checked_in_at DESC`,
    [venue.id, date ?? null, config.tz],
  );
  res.json({ date: date ?? null, count: checkins.length, checkins });
});

/** GET /partner/venues/:id/attendance/summary?month=YYYY-MM — daily counts for a month. */
router.get('/venues/:id/attendance/summary', async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  const { month } = validate(z.object({ month: z.string().regex(/^\d{4}-\d{2}$/).optional() }), req.query);
  const start = month ? `${month}-01` : null;

  const days = await query(
    `WITH m AS (SELECT COALESCE($2::date, date_trunc('month', now() AT TIME ZONE $3)::date) AS start_d)
     SELECT d::date AS date, COUNT(c.id) AS count
     FROM m, generate_series(m.start_d, (m.start_d + interval '1 month - 1 day')::date, interval '1 day') d
     LEFT JOIN checkins c ON c.venue_id = $1 AND c.checkin_date = d::date
     GROUP BY d ORDER BY d`,
    [venue.id, start, config.tz],
  );
  const total = days.reduce((sum, d) => sum + d.count, 0);
  const uniqueMembers = await queryOne(
    `SELECT COUNT(DISTINCT user_id) AS count FROM checkins WHERE venue_id = $1 AND checkin_date BETWEEN $2 AND $3`,
    [venue.id, days[0]?.date, days[days.length - 1]?.date],
  );
  res.json({ month: days[0]?.date.slice(0, 7), total, uniqueMembers: uniqueMembers.count, days });
});

export default router;

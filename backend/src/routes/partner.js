import crypto from 'node:crypto';
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, notFound, validate } from '../utils/http.js';
import { AMENITIES, VENUE_CATEGORY_IDS, WEEKDAYS } from '../utils/constants.js';
import { dateSchema, phoneSchema, timeSchema } from '../utils/schemas.js';
import { QR_PREFIX } from './checkins.js';
import { FILES_PATH } from './files.js';

const photoUrlSchema = z
  .string()
  .refine(
    (s) => /^https?:\/\/\S+$/.test(s) || new RegExp(`^${FILES_PATH}[0-9a-f-]{36}$`).test(s),
    'Invalid photo URL',
  );

/** FITKEY Partner app (P2–P8): venue listing, check-in codes and attendance dashboard. */
const router = Router();
router.use(requireAuth('partner'));

const CHECKIN_CODE_TTL_SECONDS = 5 * 60;

const venueSchema = z.object({
  name: z.string().trim().min(2).max(160),
  description: z.string().trim().max(2000).optional(),
  categories: z.array(z.enum(VENUE_CATEGORY_IDS)).min(1),
  address: z.string().trim().min(5).max(500),
  area: z.string().trim().max(120).optional(),
  city: z.string().trim().min(2).max(80),
  latitude: z.number().min(-90).max(90).optional(),
  longitude: z.number().min(-180).max(180).optional(),
  opensAt: timeSchema.optional(),
  closesAt: timeSchema.optional(),
  openDays: z.array(z.enum(WEEKDAYS)).optional(),
  contactPhone: phoneSchema.optional(),
  contactEmail: z.string().trim().email().optional(),
  trainerAvailable: z.boolean().optional(),
  equipment: z.array(z.string().trim().min(1).max(80)).max(100).optional(),
  amenities: z.array(z.enum(AMENITIES)).optional(),
  // Photo URLs: either uploaded via POST /uploads (server-relative /api/v1/files/<id>) or absolute https URLs.
  photos: z.array(photoUrlSchema).max(8).optional(),
});

async function ownVenue(venueId, ownerId) {
  const venue = await queryOne(`SELECT * FROM venues WHERE id = $1 AND owner_id = $2`, [venueId, ownerId]);
  if (!venue) throw notFound('Venue not found');
  return venue;
}

router.get('/venues', async (req, res) => {
  const venues = await query(
    `SELECT v.id, v.name, v.area, v.city, v.categories, v.status, v.review_note, v.photos[1] AS cover_photo, v.updated_at,
            (SELECT COUNT(*) FROM checkins c WHERE c.venue_id = v.id AND c.checkin_date = (now() AT TIME ZONE $2)::date) AS today_checkins,
            (SELECT COUNT(*) FROM checkins c WHERE c.venue_id = v.id
               AND c.checkin_date >= date_trunc('month', now() AT TIME ZONE $2)::date) AS month_checkins
     FROM venues v WHERE v.owner_id = $1 ORDER BY v.created_at DESC`,
    [req.user.id, config.tz],
  );
  res.json({ venues });
});

router.get('/venues/:id', async (req, res) => {
  res.json({ venue: await ownVenue(req.params.id, req.user.id) });
});

router.post('/venues', async (req, res) => {
  const v = validate(venueSchema, req.body);
  const venue = await queryOne(
    `INSERT INTO venues (owner_id, name, description, categories, address, area, city, latitude, longitude,
       opens_at, closes_at, open_days, contact_phone, contact_email, trainer_available, equipment, amenities, photos)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, COALESCE($12::text[], '{mon,tue,wed,thu,fri,sat}'), $13, $14,
             COALESCE($15::boolean, false), COALESCE($16::text[], '{}'), COALESCE($17::text[], '{}'), COALESCE($18::text[], '{}'))
     RETURNING *`,
    [
      req.user.id, v.name, v.description ?? null, v.categories, v.address, v.area ?? null, v.city,
      v.latitude ?? null, v.longitude ?? null, v.opensAt ?? null, v.closesAt ?? null, v.openDays ?? null,
      v.contactPhone ?? null, v.contactEmail ?? null, v.trainerAvailable ?? null, v.equipment ?? null,
      v.amenities ?? null, v.photos ?? null,
    ],
  );
  res.status(201).json({ venue });
});

/** PUT /partner/venues/:id — edits venue details (status is unchanged; use /submit to send for review). */
router.put('/venues/:id', async (req, res) => {
  const existing = await ownVenue(req.params.id, req.user.id);
  const v = validate(venueSchema.partial(), req.body);

  const venue = await queryOne(
    `UPDATE venues SET
       name = COALESCE($3, name), description = COALESCE($4, description), categories = COALESCE($5, categories),
       address = COALESCE($6, address), area = COALESCE($7, area), city = COALESCE($8, city),
       latitude = COALESCE($9, latitude), longitude = COALESCE($10, longitude),
       opens_at = COALESCE($11, opens_at), closes_at = COALESCE($12, closes_at), open_days = COALESCE($13, open_days),
       contact_phone = COALESCE($14, contact_phone), contact_email = COALESCE($15, contact_email),
       trainer_available = COALESCE($16, trainer_available), equipment = COALESCE($17, equipment),
       amenities = COALESCE($18, amenities), photos = COALESCE($19, photos),
       updated_at = now()
     WHERE id = $1 AND owner_id = $2 RETURNING *`,
    [
      existing.id, req.user.id, v.name, v.description, v.categories, v.address, v.area, v.city, v.latitude,
      v.longitude, v.opensAt, v.closesAt, v.openDays, v.contactPhone, v.contactEmail, v.trainerAvailable,
      v.equipment, v.amenities, v.photos,
    ],
  );
  res.json({ venue });
});

/** DELETE /partner/venues/:id — only drafts and rejected listings can be deleted. */
router.delete('/venues/:id', async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  if (!['draft', 'rejected'].includes(venue.status)) throw badRequest('Only draft or rejected listings can be deleted');
  await query(`DELETE FROM venues WHERE id = $1`, [venue.id]);
  res.status(204).end();
});

/** POST /partner/venues/:id/submit — draft/rejected → submitted (FITKEY team then reviews). */
router.post('/venues/:id/submit', async (req, res) => {
  const venue = await ownVenue(req.params.id, req.user.id);
  if (!['draft', 'rejected'].includes(venue.status)) throw badRequest(`Venue is already ${venue.status}`);
  if (venue.photos.length < 4) throw badRequest('Add at least 4 photos before submitting');
  if (!venue.opensAt || !venue.closesAt) throw badRequest('Add opening hours before submitting');

  const updated = await queryOne(
    `UPDATE venues SET status = 'submitted', review_note = NULL, updated_at = now() WHERE id = $1 RETURNING *`,
    [venue.id],
  );
  res.json({ venue: updated });
});

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

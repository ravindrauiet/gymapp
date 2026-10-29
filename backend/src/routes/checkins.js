import { Router } from 'express';
import jwt from 'jsonwebtoken';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { HttpError, badRequest, conflict, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { pagination, uuidSchema } from '../utils/schemas.js';
import { markEventAttendance, registeredEventsToday } from './events.js';

const router = Router();
router.use(requireAuth('user'));

export const QR_PREFIX = 'FITKEY:';

// Limits OTP guessing — a venue OTP is only 6 digits.
const checkinLimiter = rateLimit({
  windowMs: 10 * 60 * 1000,
  limit: 15,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.user.id,
  message: { error: 'Too many check-in attempts — please wait a few minutes' },
});

const checkinSchema = z.union([
  z.object({ qr: z.string().min(10) }),
  z.object({ venueId: uuidSchema, otp: z.string().regex(/^\d{6}$/, 'OTP must be 6 digits') }),
]);

/**
 * POST /checkins — mark attendance by scanning the venue's QR ({ qr }) or typing its OTP ({ venueId, otp }).
 * Requires an active subscription whose plan covers one of the venue's categories. One check-in per venue per day.
 */
router.post('/', checkinLimiter, async (req, res) => {
  const body = validate(checkinSchema, req.body);

  let venueId;
  let method;
  if ('qr' in body) {
    const token = body.qr.startsWith(QR_PREFIX) ? body.qr.slice(QR_PREFIX.length) : body.qr;
    try {
      const payload = jwt.verify(token, config.checkinSecret);
      if (payload.typ !== 'checkin') throw new Error('wrong token type');
      venueId = payload.vid;
    } catch {
      throw badRequest('This QR code is invalid or has expired. Ask the venue to refresh it.');
    }
    method = 'qr';
  } else {
    const code = await queryOne(
      `SELECT id FROM checkin_codes WHERE venue_id = $1 AND otp = $2 AND expires_at > now()`,
      [body.venueId, body.otp],
    );
    if (!code) throw badRequest('Incorrect or expired venue OTP');
    venueId = body.venueId;
    method = 'otp';
  }

  const checkin = await withTransaction(async (client) => {
    const venue = await queryOne(
      `SELECT id, name, area, city, categories FROM venues WHERE id = $1 AND status = 'live'`,
      [venueId],
      client,
    );
    if (!venue) throw notFound('Venue is not live on FITKEY');

    const subscription = await queryOne(
      `SELECT s.id, p.name AS plan_name FROM subscriptions s JOIN plans p ON p.id = s.plan_id
       WHERE s.user_id = $1 AND s.status = 'active' AND now() BETWEEN s.starts_at AND s.ends_at
         AND p.categories && $2
       ORDER BY s.ends_at DESC LIMIT 1`,
      [req.user.id, venue.categories],
      client,
    );
    // Members registered for an on-ground event here today may check in for it even without a plan.
    const eventsToday = await registeredEventsToday(req.user.id, venue.id, client);
    if (!subscription && !eventsToday.length) {
      throw new HttpError(402, 'You need an active plan that covers this venue', { venueCategories: venue.categories });
    }

    let row = await queryOne(
      `INSERT INTO checkins (user_id, venue_id, subscription_id, method, checkin_date)
       VALUES ($1, $2, $3, $4, (now() AT TIME ZONE $5)::date)
       ON CONFLICT (user_id, venue_id, checkin_date) DO NOTHING
       RETURNING id, checked_in_at, checkin_date, method`,
      [req.user.id, venue.id, subscription?.id ?? null, method, config.tz],
      client,
    );
    // On-ground events: a check-in at the event venue on the event day marks attendance.
    const eventsAttended = await markEventAttendance(req.user.id, venue.id, client);
    if (!row) {
      if (!eventsAttended.length) throw conflict(`You have already checked in at ${venue.name} today`);
      row = await queryOne(
        `SELECT id, checked_in_at, checkin_date, method FROM checkins
         WHERE user_id = $1 AND venue_id = $2 AND checkin_date = (now() AT TIME ZONE $3)::date`,
        [req.user.id, venue.id, config.tz],
        client,
      );
    }

    return { ...row, venue, planName: subscription?.planName ?? null, eventsAttended };
  });

  for (const e of checkin.eventsAttended) {
    await notify(req.user.id, {
      type: 'event_attended',
      title: `Attendance marked: ${e.title}`,
      body: `Checked in at ${checkin.venue.name}. Enjoy the event!`,
      data: { contestId: e.id },
    });
  }

  res.status(201).json({ checkin });
});

/** GET /checkins/me — attendance history. */
router.get('/me', async (req, res) => {
  const { page, limit } = validate(z.object(pagination), req.query);
  const checkins = await query(
    `SELECT c.id, c.checked_in_at, c.checkin_date, c.method,
            v.id AS venue_id, v.name AS venue_name, v.area AS venue_area, v.categories AS venue_categories
     FROM checkins c JOIN venues v ON v.id = c.venue_id
     WHERE c.user_id = $1 ORDER BY c.checked_in_at DESC LIMIT $2 OFFSET $3`,
    [req.user.id, limit, (page - 1) * limit],
  );
  res.json({ checkins, page, limit });
});

export default router;

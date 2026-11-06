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
import { PAID_VIA_LABELS, legacyPass, membershipFor, nowInTz, payWithFitkey, payoutRatePaise } from './bookings.js';
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
 * Admitted by (in order): today's slot booking (marked attended) → a direct membership for this centre (within its
 * slot limits) → an active legacy pass covering the venue → an on-ground event registration → a walk-in paid now
 * with the FitKey pass (wallet.chargeVisit: session plan, else coins). Otherwise 402 with the reason and what to buy.
 * One check-in per venue per day. Each check-in records paid_via (coins / session / membership / legacy / event);
 * FitKey-pass visits (coins / session / legacy) also get a visit_payouts row at the centre's agreed rate.
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
      `SELECT id, name, area, city, categories, visit_payout_paise FROM venues WHERE id = $1 AND status = 'live'`,
      [venueId],
      client,
    );
    if (!venue) throw notFound('Venue is not live on FITKEY');
    // Serialise this member's check-ins so a double scan can't charge twice.
    await client.query(`SELECT id FROM users WHERE id = $1 FOR UPDATE`, [req.user.id]);
    const { today } = await nowInTz(client);
    const eventsToday = await registeredEventsToday(req.user.id, venue.id, client);

    // Already checked in today: never charge twice. Only an on-ground event attendance can still be marked.
    const existing = await queryOne(
      `SELECT id, checked_in_at, checkin_date, method, paid_via, cost_label FROM checkins
       WHERE user_id = $1 AND venue_id = $2 AND checkin_date = $3`,
      [req.user.id, venue.id, today],
      client,
    );
    if (existing) {
      const eventsAttended = await markEventAttendance(req.user.id, venue.id, client);
      if (!eventsAttended.length) throw conflict(`You have already checked in at ${venue.name} today`);
      delete venue.visitPayoutPaise;
      return { ...existing, venue, planName: existing.costLabel, eventsAttended };
    }

    let admit = null;
    const booking = await queryOne(
      `SELECT b.id, b.paid_via, b.cost_label, b.membership_id, b.subscription_id, m.plan_name AS membership_name
       FROM slot_bookings b LEFT JOIN direct_memberships m ON m.id = b.membership_id
       WHERE b.user_id = $1 AND b.venue_id = $2 AND b.slot_date = $3 AND b.status = 'booked'
       FOR UPDATE OF b`,
      [req.user.id, venue.id, today],
      client,
    );
    if (booking) {
      admit = {
        paidVia: booking.paidVia,
        label: booking.paidVia === 'membership' ? (booking.membershipName ?? 'Membership') : booking.costLabel,
        bookingId: booking.id,
        membershipId: booking.membershipId,
        subscriptionId: booking.subscriptionId,
      };
    }
    let membershipBlock = null;
    if (!admit) {
      const m = await membershipFor(req.user.id, venue.id, today, client);
      if (m.usable) admit = { paidVia: 'membership', label: m.membership.planName, membershipId: m.membership.id };
      else membershipBlock = m.reason;
    }
    if (!admit) {
      const legacy = await legacyPass(req.user.id, venue.categories, client);
      if (legacy) admit = { paidVia: 'legacy', label: legacy.planName, subscriptionId: legacy.id };
    }
    // Members registered for an on-ground event here today may check in for it without paying.
    if (!admit && eventsToday.length) admit = { paidVia: 'event', label: 'Event entry' };
    if (!admit) {
      // Walk-in: pay the visit now with the FitKey pass (session plan first, else coins).
      try {
        const pay = await payWithFitkey(client, req.user.id, venue);
        admit = {
          paidVia: pay.paidVia,
          label: pay.paidVia === 'legacy' ? (pay.planName ?? pay.label) : pay.label,
          subscriptionId: pay.subscriptionId,
        };
      } catch (e) {
        if (e instanceof HttpError && e.status === 402) {
          const why = membershipBlock ? `${membershipBlock}. ` : '';
          throw new HttpError(
            402,
            `${why}No booking or membership for ${venue.name} today, so a walk-in is paid with your FitKey pass — ` +
              `${e.message.replace(/[.\s]+$/, '')}. You can also buy a ${venue.name} membership`,
            { reason: membershipBlock ? 'membership_limit' : 'cannot_pay', venueId: venue.id, buy: ['fitkey_pass', 'centre_membership'] },
          );
        }
        throw e;
      }
    }

    const row = await queryOne(
      `INSERT INTO checkins (user_id, venue_id, subscription_id, method, checkin_date, paid_via, booking_id, membership_id, cost_label)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
       RETURNING id, checked_in_at, checkin_date, method, paid_via, cost_label`,
      [
        req.user.id, venue.id, admit.subscriptionId ?? null, method, today, admit.paidVia,
        admit.bookingId ?? null, admit.membershipId ?? null, admit.label ?? null,
      ],
      client,
    );
    if (admit.bookingId) {
      await client.query(`UPDATE slot_bookings SET status = 'attended', attended_at = now() WHERE id = $1`, [admit.bookingId]);
    }
    // FitKey-pass visits earn the centre its agreed per-visit payout, whatever the pass type.
    if (['coins', 'session', 'legacy'].includes(admit.paidVia)) {
      await client.query(
        `INSERT INTO visit_payouts (checkin_id, venue_id, user_id, paid_via, amount_paise, visit_date)
         VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (checkin_id) DO NOTHING`,
        [row.id, venue.id, req.user.id, admit.paidVia, await payoutRatePaise(venue, client), today],
      );
    }
    // On-ground events: a check-in at the event venue on the event day marks attendance.
    const eventsAttended = await markEventAttendance(req.user.id, venue.id, client);
    delete venue.visitPayoutPaise;
    return { ...row, venue, planName: admit.label ?? null, paidViaLabel: PAID_VIA_LABELS[admit.paidVia], eventsAttended };
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

/** GET /checkins/me — attendance history (paidVia / planName say how each visit was paid). */
router.get('/me', async (req, res) => {
  const { page, limit } = validate(z.object(pagination), req.query);
  const checkins = await query(
    `SELECT c.id, c.checked_in_at, c.checkin_date, c.method, c.paid_via, c.cost_label AS plan_name,
            v.id AS venue_id, v.name AS venue_name, v.area AS venue_area, v.categories AS venue_categories
     FROM checkins c JOIN venues v ON v.id = c.venue_id
     WHERE c.user_id = $1 ORDER BY c.checked_in_at DESC LIMIT $2 OFFSET $3`,
    [req.user.id, limit, (page - 1) * limit],
  );
  res.json({ checkins, page, limit });
});

export default router;

import crypto from 'node:crypto';
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
import {
  PAID_VIA_LABELS,
  VENUE_RULE_COLUMNS,
  accessErrors,
  assertCheckinAllowed,
  legacyPass,
  membershipFor,
  nowInTz,
  payWithFitkey,
  recordVisitPayout,
  venueRules,
} from './bookings.js';
import { markEventAttendance, registeredEventsToday } from './events.js';

const router = Router();
router.use(requireAuth('user'));

export const QR_PREFIX = 'FITKEY:';

// ---------------------------------------------------------------------------------------------------------------
// Member QR (the member shows it, the partner scans it: POST /partner/venues/:id/checkin/scan).
// Payload: `FITKEYMEMBER:<jwt>`; jwt claims { mqr: userId, typ: 'member_qr' }, 5-min TTL. It is signed with a key
// derived from the app's JWT secret (HMAC-SHA256(JWT_SECRET, 'fitkey-member-qr')) so a member-QR token can never be
// used as an access token and vice versa.
// ---------------------------------------------------------------------------------------------------------------
export const MEMBER_QR_PREFIX = 'FITKEYMEMBER:';
export const MEMBER_QR_TTL_SECONDS = 5 * 60;
const memberQrKey = () => crypto.createHmac('sha256', config.jwtSecret).update('fitkey-member-qr').digest();

export function signMemberQr(userId) {
  const token = jwt.sign({ mqr: userId, typ: 'member_qr', n: crypto.randomUUID() }, memberQrKey(), {
    expiresIn: MEMBER_QR_TTL_SECONDS,
  });
  return `${MEMBER_QR_PREFIX}${token}`;
}

/** Member user id from a scanned member-QR payload; 400 when invalid / expired. */
export function verifyMemberQr(code) {
  const raw = String(code ?? '').trim();
  const token = raw.startsWith(MEMBER_QR_PREFIX) ? raw.slice(MEMBER_QR_PREFIX.length) : raw;
  try {
    const payload = jwt.verify(token, memberQrKey());
    if (payload.typ !== 'member_qr' || !payload.mqr) throw new Error('wrong token type');
    return payload.mqr;
  } catch {
    throw badRequest('This member QR is invalid or has expired. Ask the member to refresh it in the FitKey app.');
  }
}

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
 * Checks a member in at a live venue (shared by POST /checkins and the partner's member-QR scan).
 * Admitted by (in order): today's slot booking (booked, or a request not yet decided — the member is at the desk)
 * → a direct membership for this centre (within its slot limits) → an active legacy pass covering the venue → an
 * on-ground event registration → a walk-in paid now with the FitKey pass (wallet.chargeVisit: session plan, else
 * coins). Otherwise 402 with the reason and what to buy. One check-in per venue per day.
 * Without a booking: closures / outside hours (30-min early grace) → 409 VENUE_CLOSED; FitKey-pass admissions
 * (legacy pass or wallet) inside a pass block → 409 PASS_BLOCKED. Booked visits were validated when booked.
 * FitKey-pass visits (coins / session / legacy) get a visit_payouts row (recordVisitPayout: monthly fee ÷ 30 −
 * that year's commission when the venue has a monthly fee, else the old flat rate).
 * @returns {Promise<object>} the check-in (with venue, planName, paidViaLabel, eventsAttended)
 */
export async function performCheckin({ userId, venueId, method, scannedBy = null }) {
  const checkin = await withTransaction(async (client) => {
    const venue = await queryOne(
      `SELECT id, name, area, city, categories, ${VENUE_RULE_COLUMNS} FROM venues WHERE id = $1 AND status = 'live'`,
      [venueId],
      client,
    );
    if (!venue) throw notFound('Venue is not live on FITKEY');
    // Serialise this member's check-ins so a double scan can't charge twice.
    await client.query(`SELECT id FROM users WHERE id = $1 FOR UPDATE`, [userId]);
    const { today, nowTime } = await nowInTz(client);
    const eventsToday = await registeredEventsToday(userId, venue.id, client);
    const publicVenue = { id: venue.id, name: venue.name, area: venue.area, city: venue.city, categories: venue.categories };

    // Already checked in today: never charge twice. Only an on-ground event attendance can still be marked.
    const existing = await queryOne(
      `SELECT id, checked_in_at, checkin_date, method, paid_via, cost_label FROM checkins
       WHERE user_id = $1 AND venue_id = $2 AND checkin_date = $3`,
      [userId, venue.id, today],
      client,
    );
    if (existing) {
      const eventsAttended = await markEventAttendance(userId, venue.id, client);
      if (!eventsAttended.length) throw conflict(`Already checked in at ${venue.name} today`);
      return { ...existing, venue: publicVenue, planName: existing.costLabel, eventsAttended };
    }

    let admit = null;
    const booking = await queryOne(
      `SELECT b.id, b.status, b.paid_via, b.cost_label, b.membership_id, b.subscription_id, m.plan_name AS membership_name
       FROM slot_bookings b LEFT JOIN direct_memberships m ON m.id = b.membership_id
       WHERE b.user_id = $1 AND b.venue_id = $2 AND b.slot_date = $3 AND b.status IN ('booked', 'requested')
       FOR UPDATE OF b`,
      [userId, venue.id, today],
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
    const rules = booking ? null : await venueRules(venue.id, today, today, client);
    let membershipBlock = null;
    if (!admit) {
      const m = await membershipFor(userId, venue.id, today, client);
      if (m.usable) {
        // Own-plan members: pass blocks don't apply, but closures / hours do.
        assertCheckinAllowed(venue, rules, today, nowTime, { viaPass: false });
        admit = { paidVia: 'membership', label: m.membership.planName, membershipId: m.membership.id };
      } else membershipBlock = m.reason;
    }
    // FitKey pass (legacy pass or a walk-in paid now): opening hours, closures and pass blocks apply.
    let passDenied = null;
    if (!admit) {
      try {
        assertCheckinAllowed(venue, rules, today, nowTime, { viaPass: true });
      } catch (e) {
        passDenied = e;
      }
    }
    if (!admit && !passDenied) {
      const legacy = await legacyPass(userId, venue.categories, client);
      if (legacy) admit = { paidVia: 'legacy', label: legacy.planName, subscriptionId: legacy.id };
    }
    // Members registered for an on-ground event here today may check in for it without paying.
    if (!admit && eventsToday.length) admit = { paidVia: 'event', label: 'Event entry' };
    if (!admit && passDenied) throw passDenied;
    if (!admit) {
      try {
        const pay = await payWithFitkey(client, userId, venue);
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
      `INSERT INTO checkins (user_id, venue_id, subscription_id, method, checkin_date, paid_via, booking_id, membership_id, cost_label, scanned_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
       RETURNING id, checked_in_at, checkin_date, method, paid_via, cost_label`,
      [
        userId, venue.id, admit.subscriptionId ?? null, method, today, admit.paidVia,
        admit.bookingId ?? null, admit.membershipId ?? null, admit.label ?? null, scannedBy,
      ],
      client,
    );
    if (admit.bookingId) {
      await client.query(
        `UPDATE slot_bookings SET status = 'attended', attended_at = now(),
                decided_at = CASE WHEN status = 'requested' THEN now() ELSE decided_at END
         WHERE id = $1`,
        [admit.bookingId],
      );
    }
    // FitKey-pass visits earn the centre its per-visit payout, whatever the pass type.
    if (['coins', 'session', 'legacy'].includes(admit.paidVia)) {
      await recordVisitPayout(client, { checkinId: row.id, venueId: venue.id, userId, paidVia: admit.paidVia, visitDate: today });
    }
    // On-ground events: a check-in at the event venue on the event day marks attendance.
    const eventsAttended = await markEventAttendance(userId, venue.id, client);
    return { ...row, venue: publicVenue, planName: admit.label ?? null, paidViaLabel: PAID_VIA_LABELS[admit.paidVia], eventsAttended };
  });

  for (const e of checkin.eventsAttended) {
    await notify(userId, {
      type: 'event_attended',
      title: `Attendance marked: ${e.title}`,
      body: `Checked in at ${checkin.venue.name}. Enjoy the event!`,
      data: { contestId: e.id },
    });
  }
  return checkin;
}

/**
 * POST /checkins — mark attendance by scanning the venue's QR ({ qr }) or typing its OTP ({ venueId, otp }).
 * Rules: see performCheckin. 409 { error, code }: PASS_BLOCKED | VENUE_CLOSED.
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

  const checkin = await performCheckin({ userId: req.user.id, venueId, method });
  res.status(201).json({ checkin });
});

/**
 * GET /checkins/member-qr — the member's own check-in QR for the partner to scan:
 * { qr: 'FITKEYMEMBER:<jwt>', expiresAt, ttlSeconds }. Refresh before expiry (5 min).
 */
router.get('/member-qr', async (req, res) => {
  res.set('Cache-Control', 'no-store');
  const qr = signMemberQr(req.user.id);
  res.json({
    qr,
    code: qr, // alias read by the member app
    expiresAt: new Date(Date.now() + MEMBER_QR_TTL_SECONDS * 1000).toISOString(),
    ttlSeconds: MEMBER_QR_TTL_SECONDS,
  });
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

router.use(accessErrors);

export default router;

import crypto from 'node:crypto';
import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { signAccessToken } from '../middleware/auth.js';
import { HttpError, forbidden, unauthorized, validate } from '../utils/http.js';
import { phoneSchema } from '../utils/schemas.js';
import { sendOtpSms } from '../utils/sms.js';
import { notify } from '../utils/notify.js';
import {
  WELCOME_BONUS,
  applyReferral,
  deviceIdSchema,
  grantWelcomeBonus,
  notifyReferralSignup,
  recordDevice,
  referralCodeSchema,
} from './wallet.js';

const router = Router();

const OTP_TTL_MINUTES = 5;
const OTP_MAX_ATTEMPTS = 5;

const limiterDefaults = {
  windowMs: 10 * 60 * 1000,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many attempts — please wait a few minutes and try again' },
};
// Per phone number (stops OTP spam / brute force on one account) …
const otpPhoneLimiter = rateLimit({
  ...limiterDefaults,
  limit: 8,
  keyGenerator: (req) => `${String(req.body?.phone ?? '').replace(/\D/g, '').slice(-10)}:${req.body?.role ?? 'user'}`,
});
// … and a looser per-IP cap (many users can share one mobile-carrier IP).
const otpIpLimiter = rateLimit({ ...limiterDefaults, limit: 100 });
const otpLimiter = [otpIpLimiter, otpPhoneLimiter];

const roleSchema = z.enum(['user', 'partner', 'admin']).default('user');

const hashOtp = (phone, role, code) =>
  crypto.createHmac('sha256', config.otpSecret).update(`${phone}:${role}:${code}`).digest('hex');

/** POST /auth/otp/request { phone, role? } — role is 'user' (member app) or 'partner' (partner app). */
router.post('/otp/request', otpLimiter, async (req, res) => {
  const { phone, role } = validate(z.object({ phone: phoneSchema, role: roleSchema }), req.body);

  if (role === 'admin') {
    const admin = await queryOne(`SELECT id FROM users WHERE phone = $1 AND role = 'admin'`, [phone]);
    if (!admin) throw forbidden('Not an admin account');
  }

  const code = String(crypto.randomInt(100000, 1000000));
  await query(`UPDATE otp_codes SET consumed_at = now() WHERE phone = $1 AND role = $2 AND consumed_at IS NULL`, [
    phone,
    role,
  ]);
  await query(
    `INSERT INTO otp_codes (phone, role, code_hash, expires_at)
     VALUES ($1, $2, $3, now() + make_interval(mins => $4))`,
    [phone, role, hashOtp(phone, role, code), OTP_TTL_MINUTES],
  );
  await sendOtpSms(phone, code);

  res.json({
    message: 'OTP sent',
    expiresInSeconds: OTP_TTL_MINUTES * 60,
    ...(config.exposeDevOtp ? { devOtp: code } : {}),
  });
});

/**
 * POST /auth/otp/verify { phone, otp, role?, referralCode?, deviceId? } → { token, user, isNewUser, referral? }
 * New members get the locked welcome coins. referralCode / deviceId are optional (the app can also apply a code
 * later via POST /wallet/referral/apply); a bad referral code never blocks login — it is reported in `referral`.
 */
router.post('/otp/verify', otpLimiter, async (req, res) => {
  const { phone, otp, role, referralCode, deviceId } = validate(
    z.object({
      phone: phoneSchema,
      otp: z.string().regex(/^\d{6}$/, 'OTP must be 6 digits'),
      role: roleSchema,
      referralCode: referralCodeSchema.nullish().catch(null),
      deviceId: deviceIdSchema.nullish().catch(null),
    }),
    req.body,
  );

  const record = await queryOne(
    `SELECT id, code_hash, attempts FROM otp_codes
     WHERE phone = $1 AND role = $2 AND consumed_at IS NULL AND expires_at > now()
     ORDER BY created_at DESC LIMIT 1`,
    [phone, role],
  );
  if (!record) throw unauthorized('OTP expired — request a new one');
  if (record.attempts >= OTP_MAX_ATTEMPTS) throw new HttpError(429, 'Too many attempts — request a new OTP');

  const expected = Buffer.from(record.codeHash, 'hex');
  const actual = Buffer.from(hashOtp(phone, role, otp), 'hex');
  if (!crypto.timingSafeEqual(expected, actual)) {
    await query(`UPDATE otp_codes SET attempts = attempts + 1 WHERE id = $1`, [record.id]);
    throw unauthorized('Incorrect OTP');
  }
  await query(`UPDATE otp_codes SET consumed_at = now() WHERE id = $1`, [record.id]);

  const user = await queryOne(
    `INSERT INTO users (phone, role) VALUES ($1, $2)
     ON CONFLICT (phone, role) DO UPDATE SET updated_at = now()
     RETURNING id, phone, email, name, role, city, gender, birth_date, avatar_url, created_at, (xmax = 0) AS inserted`,
    [phone, role],
  );
  const { inserted, ...publicUser } = user;

  let referral;
  if (role === 'user') {
    await recordDevice(user.id, deviceId);
    const granted = await grantWelcomeBonus(user.id);
    if (granted && inserted) {
      await notify(user.id, {
        type: 'coins_welcome',
        title: `Welcome to FITKEY! ${WELCOME_BONUS} coins added 🎁`,
        body: 'Your welcome coins unlock with your first FitKey Pass. Invite friends to earn more.',
      });
    }
    if (referralCode) {
      try {
        const r = await withTransaction((client) => applyReferral(client, user.id, { code: referralCode, deviceId }));
        await notifyReferralSignup(r, user.name);
        referral = { applied: true, referrerName: r.referrerName };
      } catch (err) {
        if (!(err instanceof HttpError)) throw err;
        referral = { applied: false, error: err.message };
      }
    }
  }

  res.json({ token: signAccessToken(publicUser), user: publicUser, isNewUser: !user.name, ...(referral ? { referral } : {}) });
});

export default router;

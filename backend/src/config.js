import dotenv from 'dotenv';

dotenv.config({ quiet: true });

function required(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable ${name} (see .env.example)`);
  }
  return value;
}

const isProd = process.env.NODE_ENV === 'production';

/** Env values pasted into a dashboard often carry spaces or quotes: "Razorpay ", 'rzp_live_…'. */
function clean(v) {
  return String(v ?? '').trim().replace(/^['"]|['"]$/g, '').trim();
}

export const config = {
  isProd,
  port: Number(process.env.PORT ?? 4000),
  databaseUrl: required('DATABASE_URL'),
  jwtSecret: required('JWT_SECRET'),
  checkinSecret: required('CHECKIN_SECRET'),
  otpSecret: required('OTP_SECRET'),
  tz: process.env.APP_TZ ?? 'Asia/Kolkata',
  exposeDevOtp: !isProd && process.env.EXPOSE_DEV_OTP === 'true',
  // mock = purchases activate instantly without payment (dev / demo); razorpay = real payments via Razorpay.
  paymentsMode: clean(process.env.PAYMENTS_MODE).toLowerCase() || 'mock',
  // Razorpay (set on the server only — never in the apps or the repo). Key ID is public; the secrets are not.
  razorpayKeyId: clean(process.env.RAZORPAY_KEY_ID),
  razorpayKeySecret: clean(process.env.RAZORPAY_KEY_SECRET),
  razorpayWebhookSecret: clean(process.env.RAZORPAY_WEBHOOK_SECRET),
  adminPhone: process.env.ADMIN_PHONE,
  openaiApiKey: process.env.OPENAI_API_KEY || '',
  // Model used by Mansi and the meal / label scanner. gpt-4o-mini handles vision well at low cost.
  openaiModel: process.env.OPENAI_MODEL || 'gpt-4o-mini',
  // YouTube Data API v3 key for the Studio importer (durations, full playlists, embeddable status). Optional.
  youtubeApiKey: process.env.YOUTUBE_API_KEY || '',
  corsOrigins: (process.env.CORS_ORIGINS ?? '*').split(',').map((s) => s.trim()),
};

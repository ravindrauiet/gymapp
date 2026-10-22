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

export const config = {
  isProd,
  port: Number(process.env.PORT ?? 4000),
  databaseUrl: required('DATABASE_URL'),
  jwtSecret: required('JWT_SECRET'),
  checkinSecret: required('CHECKIN_SECRET'),
  otpSecret: required('OTP_SECRET'),
  tz: process.env.APP_TZ ?? 'Asia/Kolkata',
  exposeDevOtp: !isProd && process.env.EXPOSE_DEV_OTP === 'true',
  paymentsMode: process.env.PAYMENTS_MODE ?? 'mock',
  adminPhone: process.env.ADMIN_PHONE,
  openaiApiKey: process.env.OPENAI_API_KEY || '',
  // Model used by Mansi and the meal / label scanner. gpt-4o-mini handles vision well at low cost.
  openaiModel: process.env.OPENAI_MODEL || 'gpt-4o-mini',
  corsOrigins: (process.env.CORS_ORIGINS ?? '*').split(',').map((s) => s.trim()),
};

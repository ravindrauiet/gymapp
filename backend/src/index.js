import { createApp } from './app.js';
import { config } from './config.js';
import { pool } from './db/index.js';
import { runMigrations } from './db/runMigrations.js';
import { startMoneyJobs } from './utils/renewals.js';
import { sweepOpenPayments } from './routes/payments.js';

// Schema changes are idempotent, so applying them on boot keeps every deploy (e.g. Render) in sync.
await runMigrations({ log: () => {} });

const app = createApp();
const server = app.listen(config.port, () => {
  console.log(`FITKEY API listening on http://localhost:${config.port}/api/v1`);
  // Payments status (never prints secrets): check this line in Render → Logs when the payment page doesn't open.
  const k = config.razorpayKeyId;
  if (config.paymentsMode !== 'razorpay') {
    console.log(`[payments] DEMO mode (PAYMENTS_MODE="${config.paymentsMode}") — purchases activate without payment. Set PAYMENTS_MODE=razorpay for real payments.`);
  } else {
    const missing = [!k && 'RAZORPAY_KEY_ID', !config.razorpayKeySecret && 'RAZORPAY_KEY_SECRET'].filter(Boolean);
    if (missing.length) console.warn(`[payments] PAYMENTS_MODE=razorpay but ${missing.join(' and ')} not set — falling back to DEMO mode.`);
    else console.log(`[payments] Razorpay ${k.startsWith('rzp_live_') ? 'LIVE' : 'TEST'} mode, key ${k.slice(0, 12)}…${config.razorpayWebhookSecret ? '' : ' (webhook secret not set — the 10-minute sweep covers missed payments)'}`);
  }
});
startMoneyJobs(); // daily renewal alerts + booking-request expiry (skipped under node --test / NODE_ENV=test)
// Razorpay safety net: fulfil checkouts that were paid but never verified (app closed, webhook not set up).
if (process.env.NODE_ENV !== 'test') setInterval(() => sweepOpenPayments().catch(() => {}), 10 * 60 * 1000).unref();

function shutdown() {
  server.close(() => pool.end().finally(() => process.exit(0)));
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

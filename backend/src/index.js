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
});
startMoneyJobs(); // daily renewal alerts + booking-request expiry (skipped under node --test / NODE_ENV=test)
// Razorpay safety net: fulfil checkouts that were paid but never verified (app closed, webhook not set up).
if (process.env.NODE_ENV !== 'test') setInterval(() => sweepOpenPayments().catch(() => {}), 10 * 60 * 1000).unref();

function shutdown() {
  server.close(() => pool.end().finally(() => process.exit(0)));
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

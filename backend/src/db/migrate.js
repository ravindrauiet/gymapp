import { pool } from './index.js';
import { runMigrations } from './runMigrations.js';

try {
  await runMigrations();
  console.log('✔ Schema applied');
} catch (err) {
  console.error('✖ Migration failed:', err.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}

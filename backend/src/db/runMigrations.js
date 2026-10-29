import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { pool } from './index.js';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));

/**
 * Applies schema.sql, then every file in migrations/ in name order.
 * Every statement must be idempotent (IF NOT EXISTS / ON CONFLICT), because this runs on every server start.
 */
export async function runMigrations({ log = console.log } = {}) {
  await pool.query(await readFile(here('./schema.sql'), 'utf8'));
  const files = (await readdir(here('./migrations/'))).filter((f) => f.endsWith('.sql')).sort();
  for (const f of files) {
    await pool.query(await readFile(here(`./migrations/${f}`), 'utf8'));
    log(`  ✔ ${f}`);
  }
}

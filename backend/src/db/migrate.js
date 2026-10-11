import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { pool } from './index.js';

const schemaPath = fileURLToPath(new URL('./schema.sql', import.meta.url));

try {
  const sql = await readFile(schemaPath, 'utf8');
  await pool.query(sql);
  console.log('✔ Schema applied');
} catch (err) {
  console.error('✖ Migration failed:', err.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}

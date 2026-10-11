import pg from 'pg';
import { config } from '../config.js';

const { Pool, types } = pg;

// Return NUMERIC and BIGINT (e.g. COUNT) as JS numbers, DATE as 'YYYY-MM-DD' strings.
types.setTypeParser(types.builtins.NUMERIC, (v) => (v === null ? null : parseFloat(v)));
types.setTypeParser(types.builtins.INT8, (v) => (v === null ? null : parseInt(v, 10)));
types.setTypeParser(types.builtins.DATE, (v) => v);

export const pool = new Pool({
  connectionString: config.databaseUrl,
  max: 10,
  idleTimeoutMillis: 30_000,
});

pool.on('error', (err) => {
  console.error('Unexpected Postgres pool error', err);
});

const toCamel = (key) => key.replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase());

function camelizeRow(row) {
  const out = {};
  for (const [key, value] of Object.entries(row)) out[toCamel(key)] = value;
  return out;
}

/** Runs a query and returns rows with camelCase keys. */
export async function query(text, params = [], client = pool) {
  const result = await client.query(text, params);
  return result.rows.map(camelizeRow);
}

export async function queryOne(text, params = [], client = pool) {
  const rows = await query(text, params, client);
  return rows[0] ?? null;
}

/** Runs `fn(client)` inside a transaction. */
export async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

// Act-as (assisted listing) token tests. Only paths that never touch the database are exercised here:
// the pg pool connects lazily, so importing the middleware does not open a connection.
import { test } from 'node:test';
import assert from 'node:assert/strict';

process.env.DATABASE_URL ??= 'postgres://test:test@127.0.0.1:1/none';
process.env.JWT_SECRET ??= 'test-jwt';
process.env.CHECKIN_SECRET ??= 'test-checkin';
process.env.OTP_SECRET ??= 'test-otp';

const { default: jwt } = await import('jsonwebtoken');
const { config } = await import('../config.js');
const { forbidStaffActing, requireAuth, signAccessToken } = await import('./auth.js');

const run = (mw, req) =>
  new Promise((resolve) => {
    mw(req, {}, (err) => resolve({ err, req }));
  });

test('normal token: no staffId claim, 30-day expiry', async () => {
  const token = signAccessToken({ id: 'u1', role: 'partner' });
  const p = jwt.verify(token, config.jwtSecret);
  assert.equal(p.staffId, undefined);
  assert.ok(p.exp - p.iat >= 29 * 86400);
  const { err, req } = await run(requireAuth('partner'), { headers: { authorization: `Bearer ${token}` }, originalUrl: '/api/v1/partner/venues' });
  assert.equal(err, undefined);
  assert.equal(req.staffId, null);
  assert.deepEqual(req.user, { id: 'u1', role: 'partner' });
});

test('act-as token carries staffId and is short-lived', () => {
  const token = signAccessToken({ id: 'p1', role: 'partner' }, { staffId: 's1' });
  const p = jwt.verify(token, config.jwtSecret);
  assert.equal(p.staffId, 's1');
  assert.equal(p.sub, 'p1');
  assert.ok(p.exp - p.iat <= 12 * 3600);
});

test('act-as token is refused on money paths (before any DB lookup)', async () => {
  const token = signAccessToken({ id: 'p1', role: 'partner' }, { staffId: 's1' });
  for (const url of ['/api/v1/partner/earnings', '/api/v1/partner/payouts/1/statement.csv', '/api/v1/partner/venues/v1/members']) {
    const { err } = await run(requireAuth('partner'), { method: 'GET', headers: { authorization: `Bearer ${token}` }, originalUrl: url });
    assert.equal(err?.status, 403, url);
  }
});

test('forbidStaffActing', async () => {
  assert.equal((await run(forbidStaffActing, { staffId: 's1' })).err?.status, 403);
  assert.equal((await run(forbidStaffActing, { staffId: null })).err, undefined);
});

import assert from 'node:assert/strict';
import { test } from 'node:test';

process.env.DATABASE_URL ??= 'postgres://x:y@127.0.0.1:1/none';
process.env.JWT_SECRET ??= 'test';
process.env.CHECKIN_SECRET ??= 'test';
process.env.OTP_SECRET ??= 'test';
const { costUsd, preview, priceFor } = await import('./ai_usage.js');

test('cost: gpt-4o-mini at $0.15 in / $0.60 out per 1M tokens', () => {
  assert.equal(costUsd('gpt-4o-mini', 1_000_000, 0), 0.15);
  assert.equal(costUsd('gpt-4o-mini', 0, 1_000_000), 0.6);
  assert.ok(Math.abs(costUsd('gpt-4o-mini', 1000, 500) - 0.00045) < 1e-12);
});

test('dated model snapshots use their family price; unknown models have no price', () => {
  assert.deepEqual(priceFor('gpt-4o-mini-2024-07-18'), priceFor('gpt-4o-mini'));
  assert.deepEqual(priceFor('gpt-4o-2024-11-20'), priceFor('gpt-4o'));
  assert.equal(costUsd('some-new-model', 1000, 1000), null);
});

test('previews mask phone numbers and emails and are capped', () => {
  const p = preview('Call me on +91 98765 43210 or mail riya@gmail.com about my diet');
  assert.ok(!p.includes('98765'));
  assert.ok(!p.includes('riya@gmail.com'));
  assert.ok(p.includes('[number]') && p.includes('[email]'));
  assert.equal(preview('x'.repeat(500)).length, 240);
});

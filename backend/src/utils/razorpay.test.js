import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';

process.env.DATABASE_URL ??= 'postgres://x:y@127.0.0.1:1/none';
process.env.JWT_SECRET ??= 'test';
process.env.CHECKIN_SECRET ??= 'test';
process.env.OTP_SECRET ??= 'test';
const { verifyCheckoutSignature, verifyWebhookSignature } = await import('./razorpay.js');

const secret = 'test_secret_123';
const sign = (data) => crypto.createHmac('sha256', secret).update(data).digest('hex');

test('checkout signature: valid order|payment signature passes', () => {
  assert.equal(verifyCheckoutSignature('order_A1', 'pay_B2', sign('order_A1|pay_B2'), secret), true);
});

test('checkout signature: tampered payment id, wrong secret or missing parts fail', () => {
  assert.equal(verifyCheckoutSignature('order_A1', 'pay_XX', sign('order_A1|pay_B2'), secret), false);
  assert.equal(verifyCheckoutSignature('order_A1', 'pay_B2', sign('order_A1|pay_B2'), 'other'), false);
  assert.equal(verifyCheckoutSignature('order_A1', 'pay_B2', '', secret), false);
  assert.equal(verifyCheckoutSignature('order_A1', 'pay_B2', 'abc', secret), false);
});

test('webhook signature is checked against the exact raw body', () => {
  const body = Buffer.from(JSON.stringify({ event: 'payment.captured', payload: {} }));
  assert.equal(verifyWebhookSignature(body, sign(body), secret), true);
  const changed = Buffer.from(JSON.stringify({ event: 'payment.captured', payload: { x: 1 } }));
  assert.equal(verifyWebhookSignature(changed, sign(body), secret), false);
  assert.equal(verifyWebhookSignature(body, sign(body), ''), false);
});

/**
 * Minimal Razorpay client (REST, no SDK): orders, payments, capture, refunds and signature checks.
 * Keys come from the server environment only (config.razorpayKeyId / razorpayKeySecret / razorpayWebhookSecret).
 * Docs: https://razorpay.com/docs/api/
 */
import crypto from 'node:crypto';
import { config } from '../config.js';
import { HttpError } from './http.js';

const BASE = 'https://api.razorpay.com/v1';

export const razorpayEnabled = () =>
  config.paymentsMode === 'razorpay' && Boolean(config.razorpayKeyId && config.razorpayKeySecret);

async function call(method, path, body) {
  if (!config.razorpayKeyId || !config.razorpayKeySecret) throw new HttpError(503, 'Payments are not configured');
  const auth = Buffer.from(`${config.razorpayKeyId}:${config.razorpayKeySecret}`).toString('base64');
  let res;
  try {
    res = await fetch(`${BASE}${path}`, {
      method,
      headers: { Authorization: `Basic ${auth}`, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(20_000),
    });
  } catch {
    throw new HttpError(502, 'Could not reach the payment gateway. Please try again.');
  }
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = json?.error?.description || `Payment gateway error (${res.status})`;
    console.error('[razorpay]', method, path, res.status, json?.error?.code, msg);
    throw new HttpError(502, msg);
  }
  return json;
}

/** Creates an order. amountPaise ≥ 100 (Razorpay minimum ₹1). receipt ≤ 40 chars. */
export const createOrder = ({ amountPaise, receipt, notes = {} }) =>
  call('POST', '/orders', { amount: amountPaise, currency: 'INR', receipt: String(receipt).slice(0, 40), notes, payment_capture: 1 });

export const fetchPayment = (paymentId) => call('GET', `/payments/${encodeURIComponent(paymentId)}`);

export const capturePayment = (paymentId, amountPaise) =>
  call('POST', `/payments/${encodeURIComponent(paymentId)}/capture`, { amount: amountPaise, currency: 'INR' });

/** Refunds a payment (amountPaise omitted = full refund). */
export const refundPayment = (paymentId, amountPaise, notes = {}) =>
  call('POST', `/payments/${encodeURIComponent(paymentId)}/refund`, { ...(amountPaise ? { amount: amountPaise } : {}), speed: 'normal', notes });

function safeEqualHex(a, b) {
  const x = Buffer.from(String(a), 'utf8');
  const y = Buffer.from(String(b), 'utf8');
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

/** Checkout success signature: HMAC_SHA256(order_id + "|" + payment_id, key_secret). */
export function verifyCheckoutSignature(orderId, paymentId, signature, secret = config.razorpayKeySecret) {
  if (!orderId || !paymentId || !signature || !secret) return false;
  const expected = crypto.createHmac('sha256', secret).update(`${orderId}|${paymentId}`).digest('hex');
  return safeEqualHex(expected, signature);
}

/** Webhook signature: HMAC_SHA256(raw body, webhook secret) in the X-Razorpay-Signature header. */
export function verifyWebhookSignature(rawBody, signature, secret = config.razorpayWebhookSecret) {
  if (!rawBody || !signature || !secret) return false;
  const expected = crypto.createHmac('sha256', secret).update(rawBody).digest('hex');
  return safeEqualHex(expected, signature);
}

/** Payments made against an order (used by the sweep for checkouts the app never verified). */
export const fetchOrderPayments = (orderId) => call('GET', `/orders/${encodeURIComponent(orderId)}/payments`);

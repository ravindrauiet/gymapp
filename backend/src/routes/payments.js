/**
 * Payments (Razorpay). Everything a member buys with money goes through here when PAYMENTS_MODE=razorpay:
 *
 *   1. POST /payments/orders  { purpose, payload }  → the purchase is validated + priced on the server, a Razorpay
 *      order is created and the checkout options are returned (key id, order id, amount, prefill).
 *   2. The app opens Razorpay Checkout; on success it gets { razorpay_order_id, razorpay_payment_id, razorpay_signature }.
 *   3. POST /payments/verify  → signature check + payment fetched from Razorpay (amount / order / status) → the purchase
 *      is fulfilled exactly once and its normal response is returned (same JSON as the old instant endpoint).
 *   4. POST /payments/webhook (Razorpay → server, payment.captured / order.paid) does step 3 too, so a purchase is
 *      fulfilled even if the app was closed right after paying.
 *
 * If fulfilment fails after the money is taken (plan withdrawn, item out of stock…) the payment is refunded in full.
 * Prices always come from the server; the app never sends an amount.
 *
 * Purposes: subscription (FitKey pass plan) · wallet_pass (coin pack / session plan) · membership · membership_renew
 *           (centre's own plans) · store_order (online store checkout).
 */
import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { HttpError, badRequest, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import {
  capturePayment,
  createOrder,
  fetchOrderPayments,
  fetchPayment,
  razorpayEnabled,
  refundPayment,
  verifyCheckoutSignature,
  verifyWebhookSignature,
} from '../utils/razorpay.js';
import { membershipPurchase, membershipRenewal } from './memberships.js';
import { storeOrderPurchase } from './marketplace.js';
import { subscriptionPurchase } from './plans.js';
import { walletPassPurchase } from './wallet.js';

export const PURPOSES = {
  subscription: subscriptionPurchase,
  wallet_pass: walletPassPurchase,
  membership: membershipPurchase,
  membership_renew: membershipRenewal,
  store_order: storeOrderPurchase,
};

const router = Router();

// ------------------------------------------------------------------------------------------------ webhook (no auth)

router.post('/webhook', async (req, res) => {
  const signature = req.get('x-razorpay-signature');
  if (!verifyWebhookSignature(req.rawBody, signature)) {
    return res.status(400).json({ error: 'Invalid signature' });
  }
  const event = req.body?.event;
  const payment = req.body?.payload?.payment?.entity;
  try {
    if ((event === 'payment.captured' || event === 'order.paid' || event === 'payment.authorized') && payment?.order_id) {
      const row = await queryOne(`SELECT id FROM payment_orders WHERE razorpay_order_id = $1`, [payment.order_id]);
      if (row) await finalize(row.id, payment.id);
    } else if (event === 'payment.failed' && payment?.order_id) {
      await query(
        `UPDATE payment_orders SET error = $2 WHERE razorpay_order_id = $1 AND status = 'created'`,
        [payment.order_id, String(payment.error_description ?? 'Payment failed').slice(0, 500)],
      );
    }
  } catch (e) {
    console.error('[payments] webhook', event, e.message);
    // 5xx makes Razorpay retry later.
    return res.status(500).json({ error: 'retry' });
  }
  res.json({ ok: true });
});

router.use(requireAuth('user'));

// ------------------------------------------------------------------------------------------------ member endpoints

/** GET /payments/config → how the app should pay. keyId is the PUBLIC key (safe to ship to the app). */
router.get('/config', (_req, res) => {
  res.json({
    mode: razorpayEnabled() ? 'razorpay' : 'mock',
    keyId: razorpayEnabled() ? config.razorpayKeyId : null,
    testMode: config.razorpayKeyId.startsWith('rzp_test_'),
    merchantName: 'FITKEY',
  });
});

const orderSchema = z.object({ purpose: z.enum(Object.keys(PURPOSES)), payload: z.record(z.string(), z.any()).default({}) });

/** POST /payments/orders { purpose, payload } → Razorpay checkout options (or the result directly when nothing is due). */
router.post('/orders', async (req, res) => {
  if (!razorpayEnabled()) throw badRequest('Online payments are not switched on');
  const { purpose, payload } = validate(orderSchema, req.body);
  const handler = PURPOSES[purpose];
  const quote = await handler.quote(req.user.id, payload);
  const amount = Math.max(0, Math.round(quote.amountPaise));

  const row = await queryOne(
    `INSERT INTO payment_orders (user_id, purpose, payload, description, amount_paise)
     VALUES ($1, $2, $3::jsonb, $4, $5) RETURNING id`,
    [req.user.id, purpose, JSON.stringify(quote.payload), quote.description?.slice(0, 200) ?? null, amount],
  );

  // Fully paid with coins: nothing to charge.
  if (amount === 0) {
    const out = await runFulfillment(row.id, `COINS-${row.id.slice(0, 8)}`, null);
    return res.status(201).json({ paid: true, paymentOrderId: row.id, result: out });
  }
  if (amount < 100) throw badRequest('The amount to pay must be at least ₹1 — use fewer coins');

  const order = await createOrder({
    amountPaise: amount,
    receipt: row.id.replace(/-/g, '').slice(0, 32),
    notes: { paymentOrderId: row.id, purpose, userId: req.user.id },
  });
  await query(`UPDATE payment_orders SET razorpay_order_id = $2 WHERE id = $1`, [row.id, order.id]);

  const user = await queryOne(`SELECT name, phone, email FROM users WHERE id = $1`, [req.user.id]);
  res.status(201).json({
    paid: false,
    paymentOrderId: row.id,
    checkout: {
      key: config.razorpayKeyId,
      order_id: order.id,
      amount,
      currency: 'INR',
      name: 'FITKEY',
      description: quote.description ?? 'FITKEY',
      prefill: { name: user?.name ?? '', contact: user?.phone ? `+91${String(user.phone).replace(/\D/g, '').slice(-10)}` : '', email: user?.email ?? '' },
      notes: { paymentOrderId: row.id, purpose },
      theme: { color: '#FF5A36' },
    },
  });
});

const verifySchema = z.object({
  razorpayOrderId: z.string().min(5).max(40),
  razorpayPaymentId: z.string().min(5).max(40),
  razorpaySignature: z.string().min(10).max(200),
});

/** POST /payments/verify — after Checkout success. Returns the purchase result (fulfilled exactly once). */
router.post('/verify', async (req, res) => {
  const b = validate(verifySchema, req.body);
  const row = await queryOne(`SELECT id, user_id FROM payment_orders WHERE razorpay_order_id = $1`, [b.razorpayOrderId]);
  if (!row || row.userId !== req.user.id) throw notFound('Payment not found');
  if (!verifyCheckoutSignature(b.razorpayOrderId, b.razorpayPaymentId, b.razorpaySignature)) {
    throw badRequest('Payment could not be verified. If money was deducted it will be refunded automatically.');
  }
  const out = await finalize(row.id, b.razorpayPaymentId);
  res.json(out);
});

/** GET /payments/orders/:id — status of a checkout (the app polls this if verify was interrupted). */
router.get('/orders/:id', async (req, res) => {
  const row = await queryOne(
    `SELECT id, purpose, status, amount_paise, result, error, refunded_paise, created_at, paid_at, fulfilled_at
     FROM payment_orders WHERE id = $1 AND user_id = $2`,
    [req.params.id, req.user.id],
  );
  if (!row) throw notFound('Payment not found');
  res.json({ payment: row });
});

// ------------------------------------------------------------------------------------------------ core

/**
 * Confirms the payment with Razorpay and fulfils the purchase once. Safe to call repeatedly / concurrently
 * (verify + webhook): the 'fulfilling' claim is atomic and a fulfilled row just returns its stored result.
 */
export async function finalize(paymentOrderId, paymentId) {
  const row = await queryOne(`SELECT * FROM payment_orders WHERE id = $1`, [paymentOrderId]);
  if (!row) throw notFound('Payment not found');
  if (row.status === 'fulfilled') return { status: 'fulfilled', paymentOrderId, result: row.result };
  if (row.status === 'refunded' || row.status === 'failed') {
    throw new HttpError(409, row.error ?? 'This payment was refunded', { code: 'PAYMENT_REFUNDED', paymentOrderId });
  }

  // Trust Razorpay, not the client: the payment must belong to this order and cover the full amount.
  const p = await fetchPayment(paymentId);
  if (p.order_id !== row.razorpayOrderId) throw badRequest('Payment does not match this order');
  if (Number(p.amount) !== row.amountPaise || p.currency !== 'INR') throw badRequest('Payment amount does not match');
  if (p.status === 'authorized') await capturePayment(paymentId, row.amountPaise);
  else if (p.status !== 'captured') {
    throw new HttpError(409, p.status === 'failed' ? (p.error_description ?? 'Payment failed') : 'Payment is not complete yet', {
      code: 'PAYMENT_PENDING',
      paymentOrderId,
    });
  }

  await query(
    `UPDATE payment_orders SET status = 'paid', razorpay_payment_id = $2, paid_at = COALESCE(paid_at, now())
     WHERE id = $1 AND status = 'created'`,
    [paymentOrderId, paymentId],
  );
  const result = await runFulfillment(paymentOrderId, paymentId, paymentId);
  return { status: 'fulfilled', paymentOrderId, result };
}

/** Claims the row and runs the purpose's fulfil step; refunds the payment if it fails. */
async function runFulfillment(paymentOrderId, paymentRef, paymentId) {
  const claimed = await queryOne(
    `UPDATE payment_orders SET status = 'fulfilling' WHERE id = $1 AND status IN ('created', 'paid') RETURNING *`,
    [paymentOrderId],
  );
  if (!claimed) {
    // Someone else (webhook / a second verify) is fulfilling it — wait for their result.
    for (let i = 0; i < 20; i++) {
      const r = await queryOne(`SELECT status, result, error FROM payment_orders WHERE id = $1`, [paymentOrderId]);
      if (r?.status === 'fulfilled') return r.result;
      if (r?.status === 'refunded' || r?.status === 'failed') throw new HttpError(409, r.error ?? 'Payment refunded', { code: 'PAYMENT_REFUNDED' });
      await new Promise((ok) => setTimeout(ok, 500));
    }
    throw new HttpError(409, 'Your payment is being processed — check again in a minute', { code: 'PAYMENT_PENDING', paymentOrderId });
  }

  const handler = PURPOSES[claimed.purpose];
  try {
    const out = await handler.fulfill(claimed.userId, claimed.payload, { paymentRef });
    const { _overpaidPaise: overpaid = 0, ...result } = out ?? {};
    await query(`UPDATE payment_orders SET status = 'fulfilled', result = $2::jsonb, fulfilled_at = now() WHERE id = $1`, [
      paymentOrderId,
      JSON.stringify(result),
    ]);
    // Coins planned at checkout weren't there any more → the member paid more than they should: refund it.
    if (overpaid > 0 && paymentId) {
      try {
        const refund = await refundPayment(paymentId, Math.min(overpaid, claimed.amountPaise), { reason: 'coins_unavailable' });
        await query(`UPDATE payment_orders SET refund_id = $2, refunded_paise = $3 WHERE id = $1`, [paymentOrderId, refund.id, refund.amount]);
      } catch (e) {
        console.error('[payments] partial refund failed', paymentOrderId, e.message);
      }
    }
    return result;
  } catch (err) {
    const reason = String(err?.message ?? 'Could not complete the purchase').slice(0, 400);
    let refunded = false;
    if (paymentId) {
      try {
        const refund = await refundPayment(paymentId, undefined, { reason: 'fulfilment_failed' });
        await query(`UPDATE payment_orders SET refund_id = $2, refunded_paise = $3 WHERE id = $1`, [paymentOrderId, refund.id, refund.amount]);
        refunded = true;
      } catch (e) {
        console.error('[payments] REFUND FAILED — refund manually', paymentOrderId, paymentId, e.message);
      }
    }
    await query(`UPDATE payment_orders SET status = $2, error = $3 WHERE id = $1`, [
      paymentOrderId,
      refunded || !paymentId ? 'refunded' : 'failed',
      reason,
    ]);
    if (paymentId) {
      await notify(claimed.userId, {
        type: 'payment_refunded',
        title: refunded ? 'Payment refunded' : 'Payment issue — we are on it',
        body: refunded
          ? `${reason}. ₹${(claimed.amountPaise / 100).toLocaleString('en-IN')} is on its way back to you (5–7 working days).`
          : `${reason}. Our team will refund ₹${(claimed.amountPaise / 100).toLocaleString('en-IN')} to you shortly.`,
        data: { screen: 'wallet', paymentOrderId },
      });
    }
    throw new HttpError(err?.status && err.status < 500 ? 409 : 500, refunded ? `${reason}. Your payment has been refunded.` : reason, {
      code: 'PAYMENT_REFUNDED',
      paymentOrderId,
    });
  }
}

/**
 * Sweeps checkouts that were paid but never verified (app killed, no webhook configured): asks Razorpay for the
 * order's payments and fulfils captured ones. Runs every 10 minutes from index.js.
 */
export async function sweepOpenPayments() {
  if (!razorpayEnabled()) return;
  const open = await query(
    `SELECT id, razorpay_order_id FROM payment_orders
     WHERE status IN ('created', 'paid') AND razorpay_order_id IS NOT NULL
       AND created_at < now() - interval '3 minutes' AND created_at > now() - interval '3 days'
     ORDER BY created_at LIMIT 50`,
    [],
  );
  for (const o of open) {
    try {
      const list = await fetchOrderPayments(o.razorpayOrderId);
      const paid = (list.items ?? []).find((p) => p.status === 'captured' || p.status === 'authorized');
      if (paid) await finalize(o.id, paid.id);
    } catch (e) {
      console.error('[payments] sweep', o.id, e.message);
    }
  }
}

export default router;

import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { HttpError, notFound, validate } from '../utils/http.js';
import { paymentRequired } from '../utils/payments.js';
import { uuidSchema } from '../utils/schemas.js';
import { activateReferralRewards, notifyReferralActivation } from '../utils/wallet.js';

export const plansRouter = Router();
export const subscriptionsRouter = Router();

const PLAN_FIELDS = `p.id, p.code, p.name, p.description, p.categories, p.price_paise, p.duration_days, p.features,
  (SELECT COUNT(*) FROM venues v WHERE v.status = 'live' AND v.categories && p.categories) AS venue_count`;

/** GET /plans — active plans with how many live venues each covers. */
plansRouter.get('/', async (_req, res) => {
  const plans = await query(`SELECT ${PLAN_FIELDS} FROM plans p WHERE p.is_active ORDER BY p.sort_order, p.price_paise`);
  res.json({ plans });
});

plansRouter.get('/:id', async (req, res) => {
  const plan = await queryOne(`SELECT ${PLAN_FIELDS} FROM plans p WHERE p.id = $1 AND p.is_active`, [req.params.id]);
  if (!plan) throw notFound('Plan not found');
  res.json({ plan });
});

/** GET /plans/:id/venues?city= — venues this plan unlocks. */
plansRouter.get('/:id/venues', async (req, res) => {
  const { city } = validate(z.object({ city: z.string().optional() }), req.query);
  const venues = await query(
    `SELECT v.id, v.name, v.area, v.city, v.categories, v.photos[1] AS cover_photo, v.rating_avg, v.rating_count
     FROM venues v JOIN plans p ON p.id = $1
     WHERE v.status = 'live' AND v.categories && p.categories AND ($2::text IS NULL OR v.city ILIKE $2)
     ORDER BY v.city, v.name LIMIT 200`,
    [req.params.id, city ?? null],
  );
  res.json({ venues });
});

subscriptionsRouter.use(requireAuth('user'));

/** GET /subscriptions/me — purchase history, newest first, with a computed state. */
subscriptionsRouter.get('/me', async (req, res) => {
  const subscriptions = await query(
    `SELECT s.id, s.status, s.starts_at, s.ends_at, s.amount_paise, s.payment_ref, s.created_at,
            p.id AS plan_id, p.name AS plan_name, p.categories,
            CASE WHEN s.status <> 'active' THEN s.status
                 WHEN now() < s.starts_at THEN 'upcoming'
                 WHEN now() > s.ends_at THEN 'expired'
                 ELSE 'active' END AS state
     FROM subscriptions s JOIN plans p ON p.id = s.plan_id
     WHERE s.user_id = $1 ORDER BY s.ends_at DESC`,
    [req.user.id],
  );
  res.json({ subscriptions });
});

/**
 * Buying a FitKey pass plan, split for payments (routes/payments.js):
 *  quote   → validates and prices it (nothing written)
 *  fulfill → creates the subscription once the money is in (or instantly with PAYMENTS_MODE=mock).
 * Legacy (category, unlimited-visit) plans: kept for existing members and old app builds. A purchase no longer earns
 * "1 coin per ₹1" (only coin packs credit coins); it still counts as a FitKey pass for activating welcome / referral coins.
 */
const subscriptionSchema = z.object({ planId: uuidSchema });

export const subscriptionPurchase = {
  async quote(userId, payload) {
    const { planId } = validate(subscriptionSchema, payload);
    const plan = await queryOne(`SELECT id, name, price_paise FROM plans WHERE id = $1 AND is_active`, [planId]);
    if (!plan) throw notFound('Plan not found');
    return { amountPaise: plan.pricePaise, description: `FITKEY ${plan.name}`, payload: { planId } };
  },

  async fulfill(userId, payload, { paymentRef }) {
    const { planId } = validate(subscriptionSchema, payload);
    const { subscription, coins, planName, buyerName } = await withTransaction(async (client) => {
      const plan = await queryOne(`SELECT * FROM plans WHERE id = $1`, [planId], client);
      if (!plan) throw notFound('Plan not found');
      // Serialise concurrent purchases for this user so stacking is computed correctly.
      const buyer = await queryOne(`SELECT id, name FROM users WHERE id = $1 FOR UPDATE`, [userId], client);
      const latest = await queryOne(
        `SELECT MAX(ends_at) AS ends_at FROM subscriptions
         WHERE user_id = $1 AND plan_id = $2 AND status = 'active' AND ends_at > now()`,
        [userId, planId],
        client,
      );
      const startsAt = latest?.endsAt ?? new Date();
      const sub = await queryOne(
        `INSERT INTO subscriptions (user_id, plan_id, status, starts_at, ends_at, amount_paise, payment_ref)
         VALUES ($1, $2, 'active', $3, $3::timestamptz + make_interval(days => $4), $5, $6)
         RETURNING *`,
        [userId, planId, startsAt, plan.durationDays, plan.pricePaise, paymentRef],
        client,
      );
      const credit = await activateReferralRewards(client, userId);
      return { subscription: sub, coins: credit, planName: plan.name, buyerName: buyer?.name };
    });
    await notifyReferralActivation(userId, coins, { buyerName });
    return {
      subscription,
      planName,
      coins: { earned: 0, unlocked: coins.unlocked, referralRewarded: Boolean(coins.referral) },
    };
  },
};

/** POST /subscriptions { planId } — mock mode only; with Razorpay the app pays via /payments (purpose subscription). */
subscriptionsRouter.post('/', async (req, res) => {
  if (config.paymentsMode !== 'mock') throw paymentRequired('subscription');
  await subscriptionPurchase.quote(req.user.id, req.body);
  res.status(201).json(await subscriptionPurchase.fulfill(req.user.id, req.body, { paymentRef: `MOCK-${Date.now()}` }));
});

import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { pool, query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { HttpError, badRequest, conflict, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { uuidSchema } from '../utils/schemas.js';
import {
  activateReferralRewards,
  balances,
  checkLowBalance,
  notifyReferralActivation,
  redeemCoins,
  redeemable,
  visitCost,
  walletSettings,
} from '../utils/wallet.js';

/**
 * FitKey wallet (BRD §3 FitKey pass in two models, §4 earning/spending coins) + Refer & Earn.
 *
 *  - FitKey pass = a COIN PACK (buy coins; each visit deducts the centre's coin cost) or a SESSION PLAN (N visits
 *    within validity, 1 per visit at any centre). Buying a coin pack credits the pack's coins — that is the
 *    purchase; session plans give no bonus coins. Legacy subscriptions (old plans) stay valid and make visits free.
 *  - Three balances: FitKey coins (bought; visits only), Referral coins (welcome bonus + referral rewards; locked
 *    until the first FitKey pass; Store + pass checkout, max 50%), ProveIt coins (earned; Store only).
 *  - Referral: a new member who signs up with a code → BOTH get REFERRAL_REWARD coins, LOCKED. When the new member
 *    buys a FitKey pass both become active (+ notification). One reward per new member; self-referral and a device
 *    already used by another account are blocked.
 * Core money logic lives in utils/wallet.js (shared with bookings / ProveIt / Store).
 */
const router = Router();

export const WELCOME_BONUS = 100;
export const REFERRAL_REWARD = 100; // default; the live value is wallet_settings.referral_reward
export const APPLY_WINDOW_DAYS = 7;
const PLAY_STORE_URL = 'https://play.google.com/store/apps/details?id=com.fitkey.fitkey_user';

export const referralCodeSchema = z
  .string()
  .trim()
  .transform((s) => s.toUpperCase().replace(/\s+/g, ''))
  .pipe(z.string().regex(/^[A-Z0-9]{4,12}$/, 'Enter a valid referral code'));
export const deviceIdSchema = z.string().trim().min(6).max(128);

/** "Rahul Sharma" → "Rahul S." — referral lists never expose full names or phone numbers. */
export function maskName(name) {
  const parts = String(name ?? '').trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return 'FitKey member';
  return parts.length === 1 ? parts[0] : `${parts[0]} ${parts[parts.length - 1][0].toUpperCase()}.`;
}

export const shareLinkFor = (code) => `${PLAY_STORE_URL}&referrer=${encodeURIComponent(code)}`;

const shareMessageFor = (code, reward) =>
  `Join me on FITKEY — one pass for gyms, pools, yoga & more near you! ` +
  `Use my referral code ${code} when you sign up and we both get ${reward} coins. Download: ${shareLinkFor(code)}`;

/** Has this member ever bought a FitKey pass (legacy plan, coin pack or session plan)? */
const HAS_BOUGHT_SQL = `(EXISTS (SELECT 1 FROM subscriptions WHERE user_id = $1)
  OR EXISTS (SELECT 1 FROM fitkey_purchases WHERE user_id = $1))`;

/**
 * Credits the welcome bonus (unchanged owner rule; idempotent, one per member). It is a referral-type coin:
 * locked until the member's first FitKey pass.
 */
export async function grantWelcomeBonus(userId, client = pool) {
  const row = await queryOne(
    `INSERT INTO coin_ledger (user_id, amount, kind, wallet, status, unlocked_at)
     SELECT $1, $2, 'welcome_bonus', 'referral', CASE WHEN has_pass THEN 'available' ELSE 'locked' END, CASE WHEN has_pass THEN now() END
     FROM (SELECT ${HAS_BOUGHT_SQL} AS has_pass) x
     ON CONFLICT DO NOTHING
     RETURNING id`,
    [userId, WELCOME_BONUS],
    client,
  );
  return Boolean(row);
}

/** Remembers the first device an account was used on (never overwritten). */
export async function recordDevice(userId, deviceId, client = pool) {
  if (!deviceId) return;
  await query(`UPDATE users SET signup_device_id = $2 WHERE id = $1 AND signup_device_id IS NULL`, [userId, deviceId], client);
}

/**
 * Links a new member to the owner of `code` and gives BOTH the locked referral reward. Must run inside a
 * transaction. Throws 400/409 with a member-friendly message when the code can't be used.
 * Returns { referralId, referrerId, referrerName, reward }.
 */
export async function applyReferral(client, userId, { code, deviceId }) {
  const me = await queryOne(
    `SELECT id, role, referral_code, referred_by, signup_device_id, created_at FROM users WHERE id = $1 FOR UPDATE`,
    [userId],
    client,
  );
  if (!me || me.role !== 'user') throw badRequest('Only member accounts can use a referral code');
  if (me.referredBy) throw conflict("You've already used a referral code");
  if (Date.now() - new Date(me.createdAt).getTime() > APPLY_WINDOW_DAYS * 86_400_000) {
    throw badRequest(`Referral codes can only be added within ${APPLY_WINDOW_DAYS} days of joining`);
  }
  const bought = await queryOne(`SELECT ${HAS_BOUGHT_SQL} AS x`, [userId], client);
  if (bought.x) throw badRequest('Referral codes can only be used before your first FitKey pass');
  if (code === me.referralCode) throw badRequest("That's your own code — share it with friends to earn coins");

  const referrer = await queryOne(
    `SELECT id, name, referred_by, signup_device_id FROM users WHERE referral_code = $1 AND role = 'user'`,
    [code],
    client,
  );
  if (!referrer) throw badRequest("We couldn't find that referral code — please check it and try again");
  if (referrer.referredBy === userId) throw badRequest("You can't use the code of a friend you invited");

  const device = me.signupDeviceId ?? deviceId ?? null;
  if (device) {
    if (referrer.signupDeviceId === device) {
      throw badRequest("This code belongs to an account on this same phone — self-referrals aren't allowed");
    }
    const other = await queryOne(
      `SELECT 1 AS x FROM users WHERE signup_device_id = $1 AND id <> $2 AND role = 'user' LIMIT 1`,
      [device, userId],
      client,
    );
    if (other) throw conflict('This phone is already linked to another FitKey account, so a referral code can’t be used');
  }

  let referral;
  try {
    await client.query('SAVEPOINT apply_referral');
    referral = await queryOne(
      `INSERT INTO referrals (referrer_id, referred_user_id, code, device_id) VALUES ($1, $2, $3, $4) RETURNING id`,
      [referrer.id, userId, code, device],
      client,
    );
    await client.query('RELEASE SAVEPOINT apply_referral');
  } catch (err) {
    await client.query('ROLLBACK TO SAVEPOINT apply_referral');
    if (err.code === '23505') {
      throw conflict(
        String(err.constraint).includes('device')
          ? 'This phone has already been used for a referral'
          : "You've already used a referral code",
      );
    }
    throw err;
  }
  await query(
    `UPDATE users SET referred_by = $2, signup_device_id = COALESCE(signup_device_id, $3), updated_at = now() WHERE id = $1`,
    [userId, referrer.id, device],
    client,
  );
  const { referral_reward: reward } = await walletSettings(client);
  for (const [uid, note] of [[referrer.id, 'Referral reward'], [userId, 'Joined with a referral code']]) {
    await query(
      `INSERT INTO coin_ledger (user_id, amount, kind, wallet, status, referral_id, note)
       VALUES ($1, $2, 'referral_signup', 'referral', 'locked', $3, $4) ON CONFLICT DO NOTHING`,
      [uid, reward, referral.id, note],
      client,
    );
  }
  return { referralId: referral.id, referrerId: referrer.id, referrerName: maskName(referrer.name), reward };
}

/** Tells both sides about the locked reward. Call after the transaction commits. */
export async function notifyReferralSignup(result, referredName, referredUserId) {
  await notify(result.referrerId, {
    type: 'referral_signup',
    title: `${referredName ? maskName(referredName) : 'A friend'} joined FITKEY with your code`,
    body: `${result.reward} coins added (locked). They become active as soon as your friend buys a FitKey pass.`,
    data: { referralId: result.referralId },
  });
  if (referredUserId) {
    await notify(referredUserId, {
      type: 'referral_joined',
      title: `${result.reward} referral coins added (locked)`,
      body: `Thanks to ${result.referrerName}'s code. Buy any FitKey pass — coins or sessions — to activate them.`,
      data: { referralId: result.referralId },
    });
  }
}

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

const packOut = (p) => ({
  id: p.id, code: p.code, name: p.name, description: p.description, pricePaise: p.pricePaise, coins: p.coins,
  bonusCoins: Math.max(0, p.coins - Math.floor(p.pricePaise / 100)), validityDays: p.validityDays,
  isActive: p.isActive, sortOrder: p.sortOrder,
});
const planOut = (p) => ({
  id: p.id, code: p.code, name: p.name, description: p.description, pricePaise: p.pricePaise, sessions: p.sessions,
  validityDays: p.validityDays, perSessionPaise: Math.round(p.pricePaise / p.sessions), isActive: p.isActive,
  sortOrder: p.sortOrder,
});
const purchaseOut = (p) => {
  const active = new Date(p.expiresAt) > new Date();
  const base = {
    id: p.id, kind: p.kind, name: p.name, pricePaise: p.pricePaise, coinsRedeemed: p.coinsRedeemed, paidPaise: p.paidPaise,
    paymentRef: p.paymentRef, startsAt: p.startsAt, expiresAt: p.expiresAt, createdAt: p.createdAt,
  };
  if (p.kind === 'coin_pack') {
    return { ...base, coins: p.coins, coinsRemaining: active ? p.coinsRemaining : 0,
      state: !active ? 'expired' : p.coinsRemaining === 0 ? 'used' : 'active' };
  }
  const left = p.sessionsTotal - p.sessionsUsed;
  return { ...base, sessionsTotal: p.sessionsTotal, sessionsUsed: p.sessionsUsed, sessionsLeft: active ? left : 0,
    state: !active ? 'expired' : left === 0 ? 'used' : 'active' };
};

async function categoryCosts(client = pool) {
  return query(`SELECT category, coins FROM visit_category_costs ORDER BY coins, category`, [], client);
}

// ---------------------------------------------------------------------------
// Admin (FITKEY team) — mounted before the member auth below
// ---------------------------------------------------------------------------

const admin = Router();
admin.use(requireAuth('admin'));

const packBody = z.object({
  code: z.string().trim().regex(/^[a-z0-9_]{2,40}$/, 'Use lowercase letters, digits and _'),
  name: z.string().trim().min(2).max(120),
  description: z.string().trim().max(500).nullish(),
  pricePaise: z.number().int().min(100),
  coins: z.number().int().min(1).max(1_000_000),
  validityDays: z.number().int().min(1).max(3650).default(180),
  isActive: z.boolean().default(true),
  sortOrder: z.number().int().default(0),
});
const planBody = z.object({
  code: z.string().trim().regex(/^[a-z0-9_]{2,40}$/, 'Use lowercase letters, digits and _'),
  name: z.string().trim().min(2).max(120),
  description: z.string().trim().max(500).nullish(),
  pricePaise: z.number().int().min(100),
  sessions: z.number().int().min(1).max(1000),
  validityDays: z.number().int().min(1).max(3650),
  isActive: z.boolean().default(true),
  sortOrder: z.number().int().default(0),
});

const uniqueCode = (err) => {
  if (err.code === '23505') throw conflict('That code is already used');
  throw err;
};

/** Generic PATCH: only the fields sent are changed. */
async function patchRow(table, id, body, columns) {
  const sets = [];
  const params = [id];
  for (const [key, col] of Object.entries(columns)) {
    if (body[key] === undefined) continue;
    params.push(body[key]);
    sets.push(`${col} = $${params.length}`);
  }
  if (!sets.length) throw badRequest('Nothing to update');
  const row = await queryOne(
    `UPDATE ${table} SET ${sets.join(', ')}, updated_at = now() WHERE id = $1 RETURNING *`,
    params,
  ).catch(uniqueCode);
  if (!row) throw notFound('Not found');
  return row;
}
const PACK_COLS = { code: 'code', name: 'name', description: 'description', pricePaise: 'price_paise', coins: 'coins', validityDays: 'validity_days', isActive: 'is_active', sortOrder: 'sort_order' };
const PLAN_COLS = { code: 'code', name: 'name', description: 'description', pricePaise: 'price_paise', sessions: 'sessions', validityDays: 'validity_days', isActive: 'is_active', sortOrder: 'sort_order' };

/** GET /wallet/admin/catalog — every pack & plan (incl. hidden), category costs, settings, headline numbers. */
admin.get('/catalog', async (_req, res) => {
  const [packs, plans, costs, settings, stats] = await Promise.all([
    query(`SELECT * FROM coin_packs ORDER BY sort_order, price_paise`),
    query(`SELECT * FROM session_plans ORDER BY sort_order, price_paise`),
    categoryCosts(),
    walletSettings(),
    queryOne(
      `SELECT COUNT(*) FILTER (WHERE created_at > now() - interval '30 days')::int AS purchases_30d,
              COALESCE(SUM(paid_paise) FILTER (WHERE created_at > now() - interval '30 days'), 0)::int AS revenue_30d_paise,
              COALESCE(SUM(coins_remaining) FILTER (WHERE kind = 'coin_pack' AND expires_at > now()), 0)::int AS coins_outstanding,
              COALESCE(SUM(sessions_total - sessions_used) FILTER (WHERE kind = 'session_plan' AND expires_at > now()), 0)::int AS sessions_outstanding
       FROM fitkey_purchases`,
    ),
  ]);
  res.json({ coinPacks: packs.map(packOut), sessionPlans: plans.map(planOut), categoryCosts: costs, settings, stats });
});

admin.post('/coin-packs', async (req, res) => {
  const b = validate(packBody, req.body);
  const row = await queryOne(
    `INSERT INTO coin_packs (code, name, description, price_paise, coins, validity_days, is_active, sort_order)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING *`,
    [b.code, b.name, b.description ?? null, b.pricePaise, b.coins, b.validityDays, b.isActive, b.sortOrder],
  ).catch(uniqueCode);
  res.status(201).json({ coinPack: packOut(row) });
});
admin.patch('/coin-packs/:id', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const b = validate(packBody.partial(), req.body);
  res.json({ coinPack: packOut(await patchRow('coin_packs', id, b, PACK_COLS)) });
});

admin.post('/session-plans', async (req, res) => {
  const b = validate(planBody, req.body);
  const row = await queryOne(
    `INSERT INTO session_plans (code, name, description, price_paise, sessions, validity_days, is_active, sort_order)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING *`,
    [b.code, b.name, b.description ?? null, b.pricePaise, b.sessions, b.validityDays, b.isActive, b.sortOrder],
  ).catch(uniqueCode);
  res.status(201).json({ sessionPlan: planOut(row) });
});
admin.patch('/session-plans/:id', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const b = validate(planBody.partial(), req.body);
  res.json({ sessionPlan: planOut(await patchRow('session_plans', id, b, PLAN_COLS)) });
});

/** PUT /wallet/admin/category-costs/:category { coins } — coin cost of one visit for a venue category. */
admin.put('/category-costs/:category', async (req, res) => {
  const category = validate(z.string().regex(/^[a-z_]{2,40}$/), req.params.category);
  const { coins } = validate(z.object({ coins: z.number().int().min(1).max(100_000) }), req.body);
  const row = await queryOne(
    `INSERT INTO visit_category_costs (category, coins) VALUES ($1, $2)
     ON CONFLICT (category) DO UPDATE SET coins = EXCLUDED.coins, updated_at = now() RETURNING category, coins`,
    [category, coins],
  );
  res.json({ categoryCost: row });
});

/** GET /wallet/admin/venue-costs?q= — live/submitted venues with their effective visit cost and override. */
admin.get('/venue-costs', async (req, res) => {
  const { q } = validate(z.object({ q: z.string().trim().max(80).optional() }), req.query);
  const venues = await query(
    `SELECT v.id, v.name, v.area, v.city, v.status, v.categories, o.coins AS override_coins, c.coins AS category_coins,
            COALESCE(o.coins, c.coins, (SELECT value FROM wallet_settings WHERE key = 'default_visit_coins'), 100)::int AS coins
     FROM venues v
     LEFT JOIN venue_visit_costs o ON o.venue_id = v.id
     LEFT JOIN visit_category_costs c ON c.category = v.categories[1]
     WHERE ($1::text IS NULL OR v.name ILIKE '%' || $1 || '%' OR v.city ILIKE '%' || $1 || '%')
     ORDER BY (o.coins IS NULL), v.status = 'live' DESC, v.name LIMIT 200`,
    [q || null],
  );
  res.json({ venues });
});

/** PUT /wallet/admin/venue-costs/:venueId { coins: number | null } — per-centre override (null = use category). */
admin.put('/venue-costs/:venueId', async (req, res) => {
  const venueId = validate(uuidSchema, req.params.venueId);
  const { coins } = validate(z.object({ coins: z.number().int().min(1).max(100_000).nullable() }), req.body);
  const venue = await queryOne(`SELECT id FROM venues WHERE id = $1`, [venueId]);
  if (!venue) throw notFound('Venue not found');
  if (coins == null) await query(`DELETE FROM venue_visit_costs WHERE venue_id = $1`, [venueId]);
  else {
    await query(
      `INSERT INTO venue_visit_costs (venue_id, coins) VALUES ($1, $2)
       ON CONFLICT (venue_id) DO UPDATE SET coins = EXCLUDED.coins, updated_at = now()`,
      [venueId, coins],
    );
  }
  res.json({ ok: true });
});

/** PUT /wallet/admin/settings/:key { value } — business rules (coin caps, referral reward, default visit cost). */
admin.put('/settings/:key', async (req, res) => {
  const key = validate(z.enum(['store_max_coin_pct', 'pass_max_coin_pct', 'referral_reward', 'default_visit_coins']), req.params.key);
  const max = key.endsWith('_pct') ? 100 : 100_000;
  const { value } = validate(z.object({ value: z.number().int().min(0).max(max) }), req.body);
  await query(
    `INSERT INTO wallet_settings (key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()`,
    [key, value],
  );
  res.json({ settings: await walletSettings() });
});

/** GET /wallet/admin/purchases — latest FitKey pass purchases. */
admin.get('/purchases', async (_req, res) => {
  const rows = await query(
    `SELECT p.*, u.name AS user_name, u.phone FROM fitkey_purchases p JOIN users u ON u.id = p.user_id
     ORDER BY p.created_at DESC LIMIT 100`,
  );
  res.json({ purchases: rows.map((r) => ({ ...purchaseOut(r), userName: r.userName, phone: r.phone })) });
});

router.use('/admin', admin);

// ---------------------------------------------------------------------------
// Member routes
// ---------------------------------------------------------------------------

router.use(requireAuth('user'));

function ledgerTitle(row) {
  switch (row.kind) {
    case 'welcome_bonus':
      return { title: 'Welcome bonus', subtitle: row.status === 'locked' ? 'Activates with your first FitKey pass' : 'Joining reward' };
    case 'plan_purchase':
      return { title: row.planName ? `Bought ${row.planName}` : 'FitKey Pass purchase', subtitle: 'Earlier reward: 1 coin per ₹1 paid' };
    case 'referral_reward':
      return { title: `Referral: ${maskName(row.referredName)}`, subtitle: 'Your friend bought a FitKey pass' };
    case 'referral_signup':
      return row.isReferrer
        ? { title: `Referral: ${maskName(row.referredName)}`, subtitle: row.status === 'locked' ? 'Activates when your friend buys a FitKey pass' : 'Your friend bought a FitKey pass' }
        : { title: 'Joined with a referral code', subtitle: row.status === 'locked' ? 'Activates with your first FitKey pass' : 'Referral reward' };
    case 'referral_credit':
      return { title: row.note ?? 'Referral coins', subtitle: null };
    case 'proveit':
      return { title: row.note ?? 'ProveIt reward', subtitle: 'Usable in the Store' };
    case 'pack_purchase':
      return { title: row.note ?? 'Coin pack', subtitle: 'FitKey coins for visits' };
    case 'visit':
      return { title: row.note ?? 'Visit', subtitle: 'Paid with FitKey coins' };
    case 'visit_refund':
      return { title: row.note ?? 'Booking cancelled', subtitle: 'Coins returned' };
    case 'store_redemption':
      return { title: 'Store order', subtitle: row.wallet === 'proveit' ? 'Paid with ProveIt coins' : 'Paid with referral coins' };
    case 'pass_redemption':
      return { title: row.note ?? 'FitKey pass purchase', subtitle: 'Paid with referral coins' };
    default:
      return { title: row.note ?? 'Coins', subtitle: null };
  }
}

async function rules() {
  const s = await walletSettings();
  return {
    coinValuePaise: 100,
    storeMaxCoinPct: s.store_max_coin_pct,
    passMaxCoinPct: s.pass_max_coin_pct,
    referralReward: s.referral_reward,
  };
}

/** GET /wallet/catalog — what can be bought (coin packs, session plans) and what a visit costs per category. */
router.get('/catalog', async (_req, res) => {
  const [packs, plans, costs, r] = await Promise.all([
    query(`SELECT * FROM coin_packs WHERE is_active ORDER BY sort_order, price_paise`),
    query(`SELECT * FROM session_plans WHERE is_active ORDER BY sort_order, price_paise`),
    categoryCosts(),
    rules(),
  ]);
  res.json({ coinPacks: packs.map(packOut), sessionPlans: plans.map(planOut), categoryCosts: costs, rules: r });
});

/** GET /wallet?before= — every balance, the legacy pass, and the latest ledger entries (newest first). */
router.get('/', async (req, res) => {
  const { before } = validate(z.object({ before: z.string().datetime({ offset: true }).optional() }), req.query);
  await grantWelcomeBonus(req.user.id); // self-heals accounts created before the wallet existed
  const [b, legacy, activePlans, rows, r] = await Promise.all([
    balances(req.user.id),
    queryOne(
      `SELECT p.name, s.ends_at FROM subscriptions s JOIN plans p ON p.id = s.plan_id
       WHERE s.user_id = $1 AND s.status = 'active' AND now() BETWEEN s.starts_at AND s.ends_at ORDER BY s.ends_at DESC LIMIT 1`,
      [req.user.id],
    ),
    query(
      `SELECT * FROM fitkey_purchases WHERE user_id = $1 AND kind = 'session_plan' AND expires_at > now()
         AND sessions_used < sessions_total ORDER BY expires_at`,
      [req.user.id],
    ),
    query(
      `SELECT l.id, l.amount, l.kind, l.wallet, l.status, l.note, l.created_at, l.unlocked_at,
              p.name AS plan_name, ru.name AS referred_name, (r.referrer_id = l.user_id) AS is_referrer
       FROM coin_ledger l
       LEFT JOIN subscriptions s ON s.id = l.subscription_id
       LEFT JOIN plans p ON p.id = s.plan_id
       LEFT JOIN referrals r ON r.id = l.referral_id
       LEFT JOIN users ru ON ru.id = r.referred_user_id
       WHERE l.user_id = $1 AND ($2::timestamptz IS NULL OR l.created_at < $2)
       ORDER BY l.created_at DESC LIMIT 50`,
      [req.user.id, before ?? null],
    ),
    rules(),
  ]);
  const hasPass = Boolean(legacy) || b.fitkey > 0 || b.sessionsLeft > 0;
  res.json({
    wallet: {
      fitkey: { balance: b.fitkey, expiresAt: b.fitkeyExpiresAt },
      sessions: { left: b.sessionsLeft, expiresAt: b.sessionsExpiresAt, plans: activePlans.map(purchaseOut) },
      referral: { available: b.referral, locked: b.referralLocked },
      proveit: { available: b.proveit },
      legacyPass: legacy ? { name: legacy.name, endsAt: legacy.endsAt } : null,
      hasPass,
      rules: r,
      // Backwards-compatible fields (older app builds).
      available: b.referral + b.proveit,
      locked: b.referralLocked,
      totalEarned: rows.filter((x) => x.amount > 0 && x.wallet !== 'fitkey').reduce((s, x) => s + x.amount, 0),
      referralCoins: b.referral,
    },
    ledger: rows.map((row) => ({
      id: row.id,
      amount: row.amount,
      kind: row.kind,
      wallet: row.wallet,
      status: row.status,
      ...ledgerTitle(row),
      createdAt: row.createdAt,
      unlockedAt: row.unlockedAt,
    })),
  });
});

/** GET /wallet/purchases — FitKey pass purchase history (coin packs + session plans), newest first. */
router.get('/purchases', async (req, res) => {
  const rows = await query(`SELECT * FROM fitkey_purchases WHERE user_id = $1 ORDER BY created_at DESC LIMIT 100`, [req.user.id]);
  res.json({ purchases: rows.map(purchaseOut) });
});

/** GET /wallet/low-balance — the Home banner (also sends the in-app alert once per pass / top-up). */
router.get('/low-balance', async (req, res) => {
  const s = await checkLowBalance(req.user.id);
  res.json({
    low: Boolean(s.low),
    kind: s.kind ?? null,
    title: s.title ?? null,
    message: s.message ?? null,
    sessionsLeft: s.sessionsLeft ?? 0,
    coins: s.coins ?? 0,
    visitCoins: s.visitCoins ?? null,
  });
});

/** GET /wallet/visit-cost/:venueId — what a visit there would cost me now (no charge). */
router.get('/visit-cost/:venueId', async (req, res) => {
  const venueId = validate(uuidSchema, req.params.venueId);
  res.json({ cost: await visitCost(req.user.id, venueId) });
});

/** GET /wallet/redeemable?context=store|pass&amountPaise= — coins usable on that amount (server-side caps). */
router.get('/redeemable', async (req, res) => {
  const { context, amountPaise } = validate(
    z.object({ context: z.enum(['store', 'pass']), amountPaise: z.coerce.number().int().min(0).max(100_000_000) }),
    req.query,
  );
  res.json({ redeemable: await redeemable(req.user.id, context, amountPaise) });
});

/**
 * POST /wallet/passes { kind: 'coin_pack'|'session_plan', id, useCoins?: boolean, coins?: number }
 * Buys a FitKey pass. Referral coins (only) may pay up to pass_max_coin_pct% of the price.
 * PAYMENTS_MODE=mock: activates instantly, no money is taken — swap in a gateway order + webhook before launch.
 */
router.post('/passes', async (req, res) => {
  const body = validate(
    z.object({
      kind: z.enum(['coin_pack', 'session_plan']),
      id: uuidSchema,
      useCoins: z.boolean().default(false),
      coins: z.number().int().min(0).optional(),
    }),
    req.body,
  );
  if (config.paymentsMode !== 'mock') throw new HttpError(501, 'Payment gateway not configured');

  const result = await withTransaction(async (client) => {
    const buyer = await queryOne(`SELECT id, name FROM users WHERE id = $1 FOR UPDATE`, [req.user.id], client);
    const item = await queryOne(
      body.kind === 'coin_pack'
        ? `SELECT * FROM coin_packs WHERE id = $1 AND is_active`
        : `SELECT * FROM session_plans WHERE id = $1 AND is_active`,
      [body.id],
      client,
    );
    if (!item) throw notFound(body.kind === 'coin_pack' ? 'Coin pack not found' : 'Session plan not found');

    const id = crypto.randomUUID();
    const isPack = body.kind === 'coin_pack';
    const purchase = await queryOne(
      `INSERT INTO fitkey_purchases (id, user_id, kind, coin_pack_id, session_plan_id, name, price_paise, paid_paise,
         payment_ref, coins, coins_remaining, sessions_total, expires_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $7, $8, $9, $9, $10, now() + make_interval(days => $11)) RETURNING *`,
      [id, req.user.id, body.kind, isPack ? item.id : null, isPack ? null : item.id, item.name, item.pricePaise,
        `MOCK-${Date.now()}`, isPack ? item.coins : 0, isPack ? 0 : item.sessions, item.validityDays],
      client,
    );

    let used = { coins: 0, referral: 0, proveit: 0 };
    if (body.useCoins && (body.coins ?? 1) > 0) {
      used = await redeemCoins(client, req.user.id, {
        context: 'pass', amountPaise: item.pricePaise, requested: body.coins ?? null, ref: `purchase:${id}`, purchaseId: id,
      });
    }
    const final = await queryOne(
      `UPDATE fitkey_purchases SET coins_redeemed = $2, paid_paise = price_paise - $2 * 100 WHERE id = $1 RETURNING *`,
      [id, used.coins],
      client,
    );
    if (isPack) {
      await query(
        `INSERT INTO coin_ledger (user_id, amount, kind, wallet, status, unlocked_at, purchase_id, ref, note)
         VALUES ($1, $2, 'pack_purchase', 'fitkey', 'available', now(), $3::uuid, ($3::uuid)::text, $4)`,
        [req.user.id, item.coins, id, `Bought ${item.name}`],
        client,
      );
    }
    const activation = await activateReferralRewards(client, req.user.id);
    const b = await balances(req.user.id, client);
    return { purchase: final ?? purchase, used, activation, buyerName: buyer?.name, balances: b };
  });

  await notifyReferralActivation(req.user.id, result.activation, { buyerName: result.buyerName });
  const p = result.purchase;
  await notify(req.user.id, {
    type: 'wallet_purchase',
    title: p.kind === 'coin_pack' ? `${p.coins.toLocaleString('en-IN')} FitKey coins added` : `${p.name} plan active · ${p.sessionsTotal} sessions`,
    body: `Valid till ${new Date(p.expiresAt).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', timeZone: config.tz })}.` +
      (result.used.coins ? ` ${result.used.coins} referral coins applied.` : ''),
    data: { screen: 'wallet', purchaseId: p.id },
  });
  res.status(201).json({
    purchase: purchaseOut(p),
    coinsUsed: result.used.coins,
    paidPaise: p.paidPaise,
    coinsActivated: result.activation.unlocked,
    referralActivated: Boolean(result.activation.referral),
    balances: result.balances,
  });
});

/** GET /wallet/referrals — the member's code, share link, stats and invited friends. */
router.get('/referrals', async (req, res) => {
  const me = await queryOne(
    `SELECT u.referral_code, u.referred_by, u.created_at, ref.name AS referrer_name, ${HAS_BOUGHT_SQL.replaceAll('$1', 'u.id')} AS has_bought
     FROM users u LEFT JOIN users ref ON ref.id = u.referred_by WHERE u.id = $1`,
    [req.user.id],
  );
  const rows = await query(
    `SELECT r.id, r.status, r.created_at, r.pass_bought_at, u.name, u.avatar_url,
            COALESCE(SUM(l.amount), 0)::int AS coins, COALESCE(bool_or(l.status = 'locked'), false) AS locked
     FROM referrals r JOIN users u ON u.id = r.referred_user_id
     LEFT JOIN coin_ledger l ON l.referral_id = r.id AND l.user_id = r.referrer_id AND l.kind IN ('referral_reward', 'referral_signup')
     WHERE r.referrer_id = $1 GROUP BY r.id, u.id ORDER BY r.created_at DESC LIMIT 200`,
    [req.user.id],
  );
  const { referral_reward: reward } = await walletSettings();
  const applyDeadline = new Date(new Date(me.createdAt).getTime() + APPLY_WINDOW_DAYS * 86_400_000);
  const passBought = rows.filter((r) => r.status === 'pass_bought').length;

  res.json({
    code: me.referralCode,
    shareLink: shareLinkFor(me.referralCode),
    shareMessage: shareMessageFor(me.referralCode, reward),
    rewardPerReferral: reward,
    stats: {
      invited: rows.length,
      signedUp: rows.length - passBought,
      passBought,
      coinsEarned: rows.filter((r) => !r.locked).reduce((s, r) => s + r.coins, 0),
      coinsLocked: rows.filter((r) => r.locked).reduce((s, r) => s + r.coins, 0),
    },
    referrals: rows.map((r) => ({
      id: r.id,
      name: maskName(r.name),
      avatarUrl: r.avatarUrl,
      status: r.status,
      joinedAt: r.createdAt,
      passBoughtAt: r.passBoughtAt,
      coins: r.coins,
      locked: r.locked,
    })),
    referredBy: me.referredBy ? { name: maskName(me.referrerName) } : null,
    canApplyCode: !me.referredBy && !me.hasBought && applyDeadline.getTime() > Date.now(),
    applyDeadline,
  });
});

/** POST /wallet/referral/apply { code, deviceId? } — a new member enters a friend's code. */
router.post('/referral/apply', async (req, res) => {
  const { code, deviceId } = validate(
    z.object({ code: referralCodeSchema, deviceId: deviceIdSchema.nullish() }),
    req.body,
  );
  const result = await withTransaction((client) => applyReferral(client, req.user.id, { code, deviceId }));
  const me = await queryOne(`SELECT name FROM users WHERE id = $1`, [req.user.id]);
  await notifyReferralSignup(result, me?.name, req.user.id);
  res.status(201).json({
    referral: { referrerName: result.referrerName, reward: result.reward },
    message: `Code applied! You and ${result.referrerName} each got ${result.reward} coins — they activate when you buy your first FitKey pass.`,
  });
});

/** POST /wallet/device { deviceId } — remembers the first device of this account (anti-abuse for referrals). */
router.post('/device', async (req, res) => {
  const { deviceId } = validate(z.object({ deviceId: deviceIdSchema }), req.body);
  await recordDevice(req.user.id, deviceId);
  res.json({ ok: true });
});

export default router;

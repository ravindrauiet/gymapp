import { Router } from 'express';
import { z } from 'zod';
import { pool, query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, conflict, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';

/**
 * FitKey Coins wallet + Refer & Earn (BRD §9).
 *
 * Rules:
 *  - Every member gets WELCOME_BONUS coins at signup, LOCKED until they buy their first pass.
 *  - Every pass purchase earns coins = rupees paid (₹1,500 → 1,500 coins) and unlocks locked coins.
 *  - A referral counts once the referred friend buys their first pass: the referrer gets REFERRAL_REWARD coins.
 *  - One reward per referred member; self-referral and a device already used by another account are blocked.
 * Coins can't be spent yet (₹ value / redemption / expiry are still to be decided) — the ledger is append-only so
 * spending can be added later as negative 'redemption' rows.
 */
const router = Router();

export const WELCOME_BONUS = 100;
export const REFERRAL_REWARD = 100;
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

const shareMessageFor = (code) =>
  `Join me on FITKEY — one pass for gyms, pools, yoga & more near you! ` +
  `Use my referral code ${code} when you sign up. Download: ${shareLinkFor(code)}`;

/**
 * Credits the welcome bonus (idempotent: at most one per member, enforced by a unique index).
 * Locked unless the member already owns a pass.
 */
export async function grantWelcomeBonus(userId, client = pool) {
  const row = await queryOne(
    `INSERT INTO coin_ledger (user_id, amount, kind, status, unlocked_at)
     SELECT $1, $2, 'welcome_bonus', CASE WHEN has_pass THEN 'available' ELSE 'locked' END, CASE WHEN has_pass THEN now() END
     FROM (SELECT EXISTS (SELECT 1 FROM subscriptions WHERE user_id = $1 AND status = 'active') AS has_pass) x
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
 * Links a new member to the owner of `code`. Must run inside a transaction. Throws 400/409 with a member-friendly
 * message when the code can't be used. Returns { referralId, referrerId, referrerName }.
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
  const bought = await queryOne(`SELECT 1 AS x FROM subscriptions WHERE user_id = $1 LIMIT 1`, [userId], client);
  if (bought) throw badRequest('Referral codes can only be used before your first FitKey Pass');
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
  return { referralId: referral.id, referrerId: referrer.id, referrerName: maskName(referrer.name) };
}

/** Tells the referrer a friend joined with their code. Call after the transaction commits. */
export async function notifyReferralSignup(result, referredName) {
  await notify(result.referrerId, {
    type: 'referral_signup',
    title: `${referredName ? maskName(referredName) : 'A friend'} joined FITKEY with your code`,
    body: `You'll get ${REFERRAL_REWARD} coins as soon as they buy their first FitKey Pass.`,
    data: { referralId: result.referralId },
  });
}

async function balances(userId, client = pool) {
  return queryOne(
    `SELECT COALESCE(SUM(amount) FILTER (WHERE status = 'available'), 0)::int AS available,
            COALESCE(SUM(amount) FILTER (WHERE status = 'locked'), 0)::int AS locked,
            COALESCE(SUM(amount) FILTER (WHERE amount > 0), 0)::int AS total_earned,
            COALESCE(SUM(amount) FILTER (WHERE kind = 'referral_reward'), 0)::int AS referral_coins
     FROM coin_ledger WHERE user_id = $1`,
    [userId],
    client,
  );
}

/**
 * Pass purchase side-effects. Must run in the purchase transaction, after the subscription row is inserted:
 * earns coins = rupees paid, unlocks locked coins, and rewards the referrer on the buyer's first pass.
 */
export async function creditPlanPurchase(client, userId, subscription) {
  const earned = Math.floor(Number(subscription.amountPaise ?? 0) / 100);
  if (earned > 0) {
    await query(
      `INSERT INTO coin_ledger (user_id, amount, kind, status, subscription_id, unlocked_at)
       VALUES ($1, $2, 'plan_purchase', 'available', $3, now()) ON CONFLICT DO NOTHING`,
      [userId, earned, subscription.id],
      client,
    );
  }
  // Accounts that somehow missed the welcome bonus still get it (then unlocked below).
  await query(
    `INSERT INTO coin_ledger (user_id, amount, kind, status) VALUES ($1, $2, 'welcome_bonus', 'locked') ON CONFLICT DO NOTHING`,
    [userId, WELCOME_BONUS],
    client,
  );
  const unlockedRows = await query(
    `UPDATE coin_ledger SET status = 'available', unlocked_at = now()
     WHERE user_id = $1 AND status = 'locked' RETURNING amount`,
    [userId],
    client,
  );
  const unlocked = unlockedRows.reduce((s, r) => s + r.amount, 0);

  let referral = null;
  const ref = await queryOne(
    `UPDATE referrals SET status = 'pass_bought', pass_bought_at = now(), rewarded_at = now()
     WHERE referred_user_id = $1 AND status = 'signed_up' RETURNING id, referrer_id`,
    [userId],
    client,
  );
  if (ref) {
    const credited = await queryOne(
      `INSERT INTO coin_ledger (user_id, amount, kind, status, referral_id, unlocked_at)
       VALUES ($1, $2, 'referral_reward', 'available', $3, now()) ON CONFLICT DO NOTHING RETURNING id`,
      [ref.referrerId, REFERRAL_REWARD, ref.id],
      client,
    );
    if (credited) referral = { referralId: ref.id, referrerId: ref.referrerId };
  }

  const balance = await balances(userId, client);
  return { earned, unlocked, available: balance.available, locked: balance.locked, referral };
}

/** Purchase notifications. Call after the purchase transaction commits. */
export async function notifyPlanCoins(userId, coins, { planName, buyerName }) {
  if (coins.earned > 0 || coins.unlocked > 0) {
    await notify(userId, {
      type: 'coins_earned',
      title: `You earned ${(coins.earned + coins.unlocked).toLocaleString('en-IN')} FitKey Coins`,
      body:
        `${coins.earned.toLocaleString('en-IN')} coins for your ${planName}` +
        (coins.unlocked ? ` + ${coins.unlocked} welcome coins unlocked.` : '.') +
        ` Balance: ${coins.available.toLocaleString('en-IN')} coins.`,
      data: {},
    });
  }
  if (coins.referral) {
    await notify(coins.referral.referrerId, {
      type: 'referral_reward',
      title: `You earned ${REFERRAL_REWARD} coins 🎉`,
      body: `${maskName(buyerName)} bought a FitKey Pass with your referral code.`,
      data: { referralId: coins.referral.referralId },
    });
  }
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

router.use(requireAuth('user'));

function ledgerTitle(row) {
  switch (row.kind) {
    case 'welcome_bonus':
      return { title: 'Welcome bonus', subtitle: row.status === 'locked' ? 'Unlocks with your first FitKey Pass' : 'Joining reward' };
    case 'plan_purchase':
      return { title: row.planName ? `Bought ${row.planName}` : 'FitKey Pass purchase', subtitle: '1 coin for every ₹1 paid' };
    case 'referral_reward':
      return { title: `Referral: ${maskName(row.referredName)}`, subtitle: 'Your friend bought a FitKey Pass' };
    default:
      return { title: row.note ?? 'Coins', subtitle: null };
  }
}

/** GET /wallet?before= — balances and the latest ledger entries (newest first). */
router.get('/', async (req, res) => {
  const { before } = validate(z.object({ before: z.string().datetime({ offset: true }).optional() }), req.query);
  await grantWelcomeBonus(req.user.id); // self-heals accounts created before the wallet existed
  const [balance, pass, rows] = await Promise.all([
    balances(req.user.id),
    queryOne(`SELECT 1 AS x FROM subscriptions WHERE user_id = $1 AND status = 'active' LIMIT 1`, [req.user.id]),
    query(
      `SELECT l.id, l.amount, l.kind, l.status, l.note, l.created_at, l.unlocked_at,
              p.name AS plan_name, ru.name AS referred_name
       FROM coin_ledger l
       LEFT JOIN subscriptions s ON s.id = l.subscription_id
       LEFT JOIN plans p ON p.id = s.plan_id
       LEFT JOIN referrals r ON r.id = l.referral_id
       LEFT JOIN users ru ON ru.id = r.referred_user_id
       WHERE l.user_id = $1 AND ($2::timestamptz IS NULL OR l.created_at < $2)
       ORDER BY l.created_at DESC LIMIT 50`,
      [req.user.id, before ?? null],
    ),
  ]);
  res.json({
    wallet: {
      available: balance.available,
      locked: balance.locked,
      totalEarned: balance.totalEarned,
      referralCoins: balance.referralCoins,
      hasPass: Boolean(pass),
      unlockHint: balance.locked > 0 ? `${balance.locked} coins unlock with your first pass` : null,
    },
    ledger: rows.map((r) => ({
      id: r.id,
      amount: r.amount,
      kind: r.kind,
      status: r.status,
      ...ledgerTitle(r),
      createdAt: r.createdAt,
      unlockedAt: r.unlockedAt,
    })),
  });
});

/** GET /wallet/referrals — the member's code, share link, stats and invited friends. */
router.get('/referrals', async (req, res) => {
  const me = await queryOne(
    `SELECT u.referral_code, u.referred_by, u.created_at, ref.name AS referrer_name,
            EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = u.id) AS has_bought
     FROM users u LEFT JOIN users ref ON ref.id = u.referred_by WHERE u.id = $1`,
    [req.user.id],
  );
  const rows = await query(
    `SELECT r.id, r.status, r.created_at, r.pass_bought_at, u.name, u.avatar_url
     FROM referrals r JOIN users u ON u.id = r.referred_user_id
     WHERE r.referrer_id = $1 ORDER BY r.created_at DESC LIMIT 200`,
    [req.user.id],
  );
  const applyDeadline = new Date(new Date(me.createdAt).getTime() + APPLY_WINDOW_DAYS * 86_400_000);
  const passBought = rows.filter((r) => r.status === 'pass_bought').length;
  const coins = await queryOne(
    `SELECT COALESCE(SUM(amount), 0)::int AS c FROM coin_ledger WHERE user_id = $1 AND kind = 'referral_reward'`,
    [req.user.id],
  );

  res.json({
    code: me.referralCode,
    shareLink: shareLinkFor(me.referralCode),
    shareMessage: shareMessageFor(me.referralCode),
    rewardPerReferral: REFERRAL_REWARD,
    stats: { invited: rows.length, signedUp: rows.length - passBought, passBought, coinsEarned: coins.c },
    referrals: rows.map((r) => ({
      id: r.id,
      name: maskName(r.name),
      avatarUrl: r.avatarUrl,
      status: r.status,
      joinedAt: r.createdAt,
      passBoughtAt: r.passBoughtAt,
      coins: r.status === 'pass_bought' ? REFERRAL_REWARD : 0,
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
  await notifyReferralSignup(result, me?.name);
  res.status(201).json({
    referral: { referrerName: result.referrerName, reward: REFERRAL_REWARD },
    message: `Code applied! ${result.referrerName} gets ${REFERRAL_REWARD} coins when you buy your first pass.`,
  });
});

/** POST /wallet/device { deviceId } — remembers the first device of this account (anti-abuse for referrals). */
router.post('/device', async (req, res) => {
  const { deviceId } = validate(z.object({ deviceId: deviceIdSchema }), req.body);
  await recordDevice(req.user.id, deviceId);
  res.json({ ok: true });
});

export default router;

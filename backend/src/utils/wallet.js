// FitKey wallet core (BRD §3 + §4). Contract used by Bookings (visitCost / chargeVisit / refundVisit) and ProveIt
// (creditCoins), plus the shared money helpers used by routes/wallet.js, routes/plans.js and routes/marketplace.js.
//
// Balances (1 coin = ₹1):
//   fitkey   — coins bought in coin packs; the ONLY coins that pay for visits. Held as lots in
//              fitkey_purchases.coins_remaining, spent FIFO by expiry. Expired lots simply stop counting.
//   referral — welcome bonus + referral rewards (+ legacy "coins per ₹ paid"); 'locked' until the member's first
//              FitKey pass; spendable on Store orders and FitKey pass checkout (max 50% each), NOT on visits.
//   proveit  — earned in ProveIt; available instantly; Store only.
// Sessions — session plans: N visits within validity; 1 session per visit at any centre.
// A visit is paid by: an active legacy pass covering the venue (free) → an active session plan → FitKey coins.
import { pool, query, queryOne } from '../db/index.js';
import { HttpError, badRequest, notFound } from './http.js';
import { notify } from './notify.js';

export const WALLETS = ['fitkey', 'referral', 'proveit'];
const SETTING_DEFAULTS = { store_max_coin_pct: 50, pass_max_coin_pct: 50, referral_reward: 100, default_visit_coins: 100 };

/** Admin-editable business rules (wallet_settings), with code defaults. */
export async function walletSettings(client = pool) {
  const rows = await query(`SELECT key, value FROM wallet_settings`, [], client).catch(() => []);
  const out = { ...SETTING_DEFAULTS };
  for (const r of rows) out[r.key] = r.value;
  return out;
}

const plural = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
const fmt = (n) => Number(n).toLocaleString('en-IN');

// ---------------------------------------------------------------------------------------------------------------
// Balances
// ---------------------------------------------------------------------------------------------------------------

/** All balances of a member. */
export async function balances(userId, client = pool) {
  // One statement: `client` may be a transaction client (no concurrent queries on one pg client).
  const r = await queryOne(
    `SELECT c.balance AS fitkey, c.expires_at AS fitkey_expires_at, s.left AS sessions_left, s.expires_at AS sessions_expires_at,
            l.referral, l.referral_locked, l.proveit
     FROM (SELECT COALESCE(SUM(coins_remaining), 0)::int AS balance,
                  MIN(expires_at) FILTER (WHERE coins_remaining > 0) AS expires_at
           FROM fitkey_purchases WHERE user_id = $1 AND kind = 'coin_pack' AND expires_at > now()) c,
          (SELECT COALESCE(SUM(sessions_total - sessions_used), 0)::int AS left,
                  MIN(expires_at) FILTER (WHERE sessions_used < sessions_total) AS expires_at
           FROM fitkey_purchases WHERE user_id = $1 AND kind = 'session_plan' AND starts_at <= now() AND expires_at > now()) s,
          (SELECT COALESCE(SUM(amount) FILTER (WHERE wallet = 'referral' AND status = 'available'), 0)::int AS referral,
                  COALESCE(SUM(amount) FILTER (WHERE wallet = 'referral' AND status = 'locked'), 0)::int AS referral_locked,
                  COALESCE(SUM(amount) FILTER (WHERE wallet = 'proveit' AND status = 'available'), 0)::int AS proveit
           FROM coin_ledger WHERE user_id = $1) l`,
    [userId],
    client,
  );
  return r;
}

/** Legacy FitKey subscription (old plans table) active right now and covering the venue's categories. */
async function legacyPassFor(userId, venueId, client) {
  return queryOne(
    `SELECT s.id, p.name FROM subscriptions s JOIN plans p ON p.id = s.plan_id JOIN venues v ON v.id = $2
     WHERE s.user_id = $1 AND s.status = 'active' AND now() BETWEEN s.starts_at AND s.ends_at
       AND p.categories && v.categories
     ORDER BY s.ends_at DESC LIMIT 1`,
    [userId, venueId],
    client,
  );
}

/** Coin cost of one visit: per-centre override → cost of the venue's first category → default. */
export async function venueVisitCoins(venueId, client = pool) {
  const row = await queryOne(
    `SELECT v.id, COALESCE(o.coins, c.coins, (SELECT value FROM wallet_settings WHERE key = 'default_visit_coins'), 100)::int AS coins
     FROM venues v
     LEFT JOIN venue_visit_costs o ON o.venue_id = v.id
     LEFT JOIN visit_category_costs c ON c.category = v.categories[1]
     WHERE v.id = $1`,
    [venueId],
    client,
  );
  if (!row) throw notFound('Venue not found');
  return row.coins;
}

/** Session plan that would pay the next visit (soonest-expiring with sessions left). */
async function nextSessionPass(userId, client, lock = false) {
  return queryOne(
    `SELECT id, name, sessions_total, sessions_used, expires_at FROM fitkey_purchases
     WHERE user_id = $1 AND kind = 'session_plan' AND starts_at <= now() AND expires_at > now()
       AND sessions_used < sessions_total
     ORDER BY expires_at, created_at LIMIT 1 ${lock ? 'FOR UPDATE' : ''}`,
    [userId],
    client,
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Contract: visits
// ---------------------------------------------------------------------------------------------------------------

/**
 * What a visit to `venueId` would cost this user right now, without charging.
 * @returns {Promise<{method: 'session'|'coins'|'legacy_pass'|null, amount: number, label: string, sufficient: boolean,
 *   balance: number|null, coinCost: number, sessionsLeft: number, coins: number}>}
 *   label e.g. "120 coins", "1 session", "Included in your pass". method null = the member has no session plan and
 *   no FitKey coins at all (label still says the coin price; sufficient false).
 */
export async function visitCost(userId, venueId, client = pool) {
  const coinCost = await venueVisitCoins(venueId, client);
  const legacy = await legacyPassFor(userId, venueId, client);
  const b = await balances(userId, client);
  const base = { coinCost, sessionsLeft: b.sessionsLeft, coins: b.fitkey };
  if (legacy) {
    return { method: 'legacy_pass', amount: 0, label: 'Included in your pass', sufficient: true, balance: null, passName: legacy.name, ...base };
  }
  if (b.sessionsLeft > 0) {
    return { method: 'session', amount: 1, label: '1 session', sufficient: true, balance: b.sessionsLeft, ...base };
  }
  return {
    method: b.fitkey > 0 ? 'coins' : null,
    amount: coinCost,
    label: `${fmt(coinCost)} coins`,
    sufficient: b.fitkey >= coinCost,
    balance: b.fitkey,
    ...base,
  };
}

/**
 * Charges one visit inside the caller's transaction. Idempotent per bookingId (a second call returns the first
 * charge). Throws HttpError 402 when the user can't pay (details: {needed, balance, method}).
 * @returns {Promise<{chargeId, method, amount, label, balanceAfter, alreadyCharged?}>}
 */
export async function chargeVisit(client, userId, venueId, { bookingId } = {}) {
  await client.query(`SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, [userId]); // serialise this member's money
  if (bookingId) {
    const prior = await queryOne(`SELECT * FROM visit_charges WHERE booking_id = $1`, [bookingId], client);
    if (prior) {
      if (prior.userId !== userId) throw badRequest('This booking belongs to another member');
      if (prior.status === 'charged') {
        return { chargeId: prior.id, method: prior.method, amount: prior.amount, label: chargeLabel(prior.method, prior.amount), balanceAfter: null, alreadyCharged: true };
      }
      throw new HttpError(409, 'This booking was already cancelled and refunded — please book again');
    }
  }

  const cost = await visitCost(userId, venueId, client);
  let charge;
  if (cost.method === 'legacy_pass') {
    charge = await queryOne(
      `INSERT INTO visit_charges (user_id, venue_id, booking_id, method, amount) VALUES ($1, $2, $3, 'legacy_pass', 0) RETURNING *`,
      [userId, venueId, bookingId ?? null],
      client,
    );
  } else if (cost.method === 'session') {
    const pass = await nextSessionPass(userId, client, true);
    if (!pass) throw new HttpError(402, 'No sessions left on your plan', { needed: 1, balance: 0, method: 'session' });
    await query(`UPDATE fitkey_purchases SET sessions_used = sessions_used + 1 WHERE id = $1`, [pass.id], client);
    charge = await queryOne(
      `INSERT INTO visit_charges (user_id, venue_id, booking_id, method, amount, purchase_id)
       VALUES ($1, $2, $3, 'session', 1, $4) RETURNING *`,
      [userId, venueId, bookingId ?? null, pass.id],
      client,
    );
  } else {
    const needed = cost.amount;
    const lots = await query(
      `SELECT id, coins_remaining FROM fitkey_purchases
       WHERE user_id = $1 AND kind = 'coin_pack' AND expires_at > now() AND coins_remaining > 0
       ORDER BY expires_at, created_at FOR UPDATE`,
      [userId],
      client,
    );
    const have = lots.reduce((s, l) => s + l.coinsRemaining, 0);
    if (have < needed) {
      throw new HttpError(
        402,
        have === 0
          ? `This visit costs ${fmt(needed)} FitKey coins. Buy a coin pack or a session plan to book.`
          : `This visit costs ${fmt(needed)} coins but you have ${fmt(have)}. Top up your FitKey coins to book.`,
        { needed, balance: have, method: 'coins' },
      );
    }
    const allocations = [];
    let left = needed;
    for (const lot of lots) {
      if (left <= 0) break;
      const take = Math.min(left, lot.coinsRemaining);
      allocations.push({ purchaseId: lot.id, coins: take });
      left -= take;
      await query(`UPDATE fitkey_purchases SET coins_remaining = coins_remaining - $2 WHERE id = $1`, [lot.id, take], client);
    }
    charge = await queryOne(
      `INSERT INTO visit_charges (user_id, venue_id, booking_id, method, amount, allocations)
       VALUES ($1, $2, $3, 'coins', $4, $5) RETURNING *`,
      [userId, venueId, bookingId ?? null, needed, JSON.stringify(allocations)],
      client,
    );
    await query(
      `INSERT INTO coin_ledger (user_id, amount, kind, wallet, status, visit_charge_id, ref, note)
       SELECT $1, $2, 'visit', 'fitkey', 'available', $3::uuid, ($3::uuid)::text, 'Visit · ' || v.name FROM venues v WHERE v.id = $4`,
      [userId, -needed, charge.id, venueId],
      client,
    );
  }
  scheduleLowBalanceCheck(userId);
  const after = await balances(userId, client);
  return {
    chargeId: charge.id,
    method: charge.method,
    amount: charge.amount,
    label: chargeLabel(charge.method, charge.amount),
    balanceAfter: charge.method === 'session' ? after.sessionsLeft : charge.method === 'coins' ? after.fitkey : null,
  };
}

function chargeLabel(method, amount) {
  if (method === 'legacy_pass') return 'Included in your pass';
  if (method === 'session') return plural(amount, 'session');
  return `${fmt(amount)} coins`;
}

/**
 * Returns what chargeVisit took for this booking (the caller enforces the cancellation window). Idempotent.
 * @returns {Promise<{refunded: boolean, method?, amount?, label?, alreadyRefunded?: boolean}>}
 */
export async function refundVisit(client, userId, { bookingId } = {}) {
  if (!bookingId) return { refunded: false };
  const charge = await queryOne(
    `SELECT * FROM visit_charges WHERE booking_id = $1 AND user_id = $2 FOR UPDATE`,
    [bookingId, userId],
    client,
  );
  if (!charge) return { refunded: false };
  const label = chargeLabel(charge.method, charge.amount);
  if (charge.status === 'refunded') return { refunded: false, alreadyRefunded: true, method: charge.method, amount: charge.amount, label };

  if (charge.method === 'session' && charge.purchaseId) {
    await query(`UPDATE fitkey_purchases SET sessions_used = GREATEST(sessions_used - 1, 0) WHERE id = $1`, [charge.purchaseId], client);
  } else if (charge.method === 'coins') {
    for (const a of charge.allocations ?? []) {
      await query(
        `UPDATE fitkey_purchases SET coins_remaining = LEAST(coins_remaining + $2, coins) WHERE id = $1`,
        [a.purchaseId, a.coins],
        client,
      );
    }
    await query(
      `INSERT INTO coin_ledger (user_id, amount, kind, wallet, status, visit_charge_id, ref, note)
       SELECT $1, $2, 'visit_refund', 'fitkey', 'available', $3::uuid, ($3::uuid)::text, 'Booking cancelled · ' || v.name
       FROM venues v WHERE v.id = $4 ON CONFLICT DO NOTHING`,
      [userId, charge.amount, charge.id, charge.venueId],
      client,
    );
  }
  await query(`UPDATE visit_charges SET status = 'refunded', refunded_at = now() WHERE id = $1`, [charge.id], client);
  return { refunded: true, method: charge.method, amount: charge.amount, label };
}

// ---------------------------------------------------------------------------------------------------------------
// Contract: earned coins
// ---------------------------------------------------------------------------------------------------------------

/**
 * Credits earned coins: kind 'proveit' (Store only, available instantly) or 'referral' (Store + pass checkout).
 * Idempotent per (user, kind, ref): a repeat call with the same ref credits nothing. Does not notify (the caller
 * notifies after its transaction commits).
 * @returns {Promise<{credited: boolean, amount: number, balance: number}>} balance = that wallet's available coins.
 */
export async function creditCoins(client, userId, amount, { kind, ref, title } = {}) {
  if (!['proveit', 'referral'].includes(kind)) throw badRequest(`Unknown coin kind: ${kind}`);
  const n = Math.floor(Number(amount));
  if (!Number.isFinite(n) || n <= 0) throw badRequest('Coin amount must be a positive whole number');
  const row = await queryOne(
    `INSERT INTO coin_ledger (user_id, amount, kind, wallet, status, unlocked_at, ref, note)
     VALUES ($1, $2, $3, $4, 'available', now(), $5, $6)
     ON CONFLICT DO NOTHING RETURNING id`,
    [userId, n, kind === 'proveit' ? 'proveit' : 'referral_credit', kind, ref == null ? null : String(ref).slice(0, 120), title ? String(title).slice(0, 160) : null],
    client,
  );
  const b = await balances(userId, client);
  return { credited: Boolean(row), amount: row ? n : 0, balance: kind === 'proveit' ? b.proveit : b.referral };
}

// ---------------------------------------------------------------------------------------------------------------
// Spending earned coins (Store / pass checkout)
// ---------------------------------------------------------------------------------------------------------------

/**
 * How many coins can pay `amountPaise` in this context.
 *  store: ProveIt coins first, then referral coins, max store_max_coin_pct% of the order.
 *  pass:  referral coins only, max pass_max_coin_pct% of the price.
 */
export async function redeemable(userId, context, amountPaise, client = pool) {
  const b = await balances(userId, client);
  const s = await walletSettings(client);
  const pct = context === 'store' ? s.store_max_coin_pct : s.pass_max_coin_pct;
  const maxCoins = Math.max(0, Math.floor((Math.floor(amountPaise / 100) * pct) / 100));
  const proveitUsable = context === 'store' ? Math.min(b.proveit, maxCoins) : 0;
  const referralUsable = Math.min(b.referral, maxCoins - proveitUsable);
  return {
    context,
    maxPct: pct,
    maxCoins,
    proveitBalance: b.proveit,
    referralBalance: b.referral,
    referralLocked: b.referralLocked,
    proveit: proveitUsable,
    referral: Math.max(0, referralUsable),
    coins: proveitUsable + Math.max(0, referralUsable),
  };
}

/**
 * Spends coins inside the caller's transaction (locks the member first). `requested` caps the total (null = as many
 * as allowed). Writes negative ledger rows. Returns {proveit, referral, coins}.
 */
export async function redeemCoins(client, userId, { context, amountPaise, requested = null, ref, orderId = null, purchaseId = null }) {
  await client.query(`SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, [userId]);
  const r = await redeemable(userId, context, amountPaise, client);
  let budget = requested == null ? r.coins : Math.min(Math.max(0, Math.floor(requested)), r.coins);
  const proveit = Math.min(r.proveit, budget);
  budget -= proveit;
  const referral = Math.min(r.referral, budget);
  const kind = context === 'store' ? 'store_redemption' : 'pass_redemption';
  const note = context === 'store' ? 'Used on a Store order' : 'Used on a FitKey pass';
  for (const [wallet, n] of [['proveit', proveit], ['referral', referral]]) {
    if (n <= 0) continue;
    await query(
      `INSERT INTO coin_ledger (user_id, amount, kind, wallet, status, ref, order_id, purchase_id, note)
       VALUES ($1, $2, $3, $4, 'available', $5, $6, $7, $8)`,
      [userId, -n, kind, wallet, `${ref}:${wallet}`, orderId, purchaseId, note],
      client,
    );
  }
  return { proveit, referral, coins: proveit + referral };
}

// ---------------------------------------------------------------------------------------------------------------
// Referral activation on a FitKey pass purchase
// ---------------------------------------------------------------------------------------------------------------

/**
 * Call inside every FitKey pass purchase transaction (coin pack, session plan, legacy plan). Unlocks the buyer's
 * locked referral-type coins (welcome bonus + their own "joined with a code" reward) and, on the buyer's first pass,
 * activates the referrer's reward. Returns {unlocked, referral: {referralId, referrerId, reward} | null}.
 */
export async function activateReferralRewards(client, userId) {
  const { referral_reward: reward } = await walletSettings(client);
  const ref = await queryOne(
    `UPDATE referrals SET status = 'pass_bought', pass_bought_at = now(), rewarded_at = now()
     WHERE referred_user_id = $1 AND status = 'signed_up' RETURNING id, referrer_id`,
    [userId],
    client,
  );
  let referral = null;
  let freshForBuyer = 0;
  if (ref) {
    // Rows normally exist (locked) since signup; insert defensively as available for older referrals.
    const ins = async (uid, note) =>
      queryOne(
        `INSERT INTO coin_ledger (user_id, amount, kind, wallet, status, referral_id, unlocked_at, note)
         VALUES ($1, $2, 'referral_signup', 'referral', 'available', $3, now(), $4) ON CONFLICT DO NOTHING RETURNING amount`,
        [uid, reward, ref.id, note],
        client,
      );
    const referrerNew = await ins(ref.referrerId, 'Referral reward');
    freshForBuyer = (await ins(userId, 'Joined with a referral code'))?.amount ?? 0;
    const activated = await query(
      `UPDATE coin_ledger SET status = 'available', unlocked_at = now()
       WHERE referral_id = $1 AND kind = 'referral_signup' AND user_id = $2 AND status = 'locked' RETURNING amount`,
      [ref.id, ref.referrerId],
      client,
    );
    const amount = (activated[0]?.amount ?? 0) + (referrerNew?.amount ?? 0);
    if (amount > 0) referral = { referralId: ref.id, referrerId: ref.referrerId, reward: amount };
  }
  const unlockedRows = await query(
    `UPDATE coin_ledger l SET status = 'available', unlocked_at = now()
     WHERE l.user_id = $1 AND l.status = 'locked'
       AND (l.kind = 'welcome_bonus'
            OR (l.kind = 'referral_signup' AND EXISTS (SELECT 1 FROM referrals r WHERE r.id = l.referral_id AND r.referred_user_id = $1)))
     RETURNING amount`,
    [userId],
    client,
  );
  const unlocked = unlockedRows.reduce((s, r) => s + r.amount, 0) + freshForBuyer;
  return { unlocked, referral };
}

/** Notifications for activateReferralRewards. Call after the purchase transaction commits. */
export async function notifyReferralActivation(userId, result, { buyerName } = {}) {
  if (result.unlocked > 0) {
    await notify(userId, {
      type: 'coins_active',
      title: `Your ${fmt(result.unlocked)} coins are now active`,
      body: 'Use referral coins on Store orders and FitKey pass purchases (up to 50% of the price).',
      data: {},
    });
  }
  if (result.referral) {
    const first = String(buyerName ?? '').trim().split(/\s+/)[0] || 'Your friend';
    await notify(result.referral.referrerId, {
      type: 'referral_reward',
      title: `Your ${fmt(result.referral.reward)} coins are now active`,
      body: `${first} bought a FitKey pass with your referral code.`,
      data: { referralId: result.referral.referralId },
    });
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Low balance
// ---------------------------------------------------------------------------------------------------------------

/** Coin cost at the member's most-visited centre (last 90 days), else the cheapest live centre. */
async function usualVisitCoins(userId, client) {
  const usual = await queryOne(
    `SELECT venue_id FROM (
       SELECT venue_id, created_at FROM visit_charges WHERE user_id = $1 AND status = 'charged' AND created_at > now() - interval '90 days'
       UNION ALL
       SELECT venue_id, checked_in_at FROM checkins WHERE user_id = $1 AND checked_in_at > now() - interval '90 days'
     ) x GROUP BY venue_id ORDER BY COUNT(*) DESC, MAX(created_at) DESC LIMIT 1`,
    [userId],
    client,
  );
  if (usual) return { coins: await venueVisitCoins(usual.venueId, client), basis: 'usual' };
  const cheapest = await queryOne(
    `SELECT MIN(COALESCE(o.coins, c.coins, 100))::int AS coins FROM venues v
     LEFT JOIN venue_visit_costs o ON o.venue_id = v.id
     LEFT JOIN visit_category_costs c ON c.category = v.categories[1]
     WHERE v.status = 'live'`,
    [],
    client,
  );
  return { coins: cheapest?.coins ?? 100, basis: 'cheapest' };
}

/**
 * Whether the member is running low: 1 session left on their plan, or FitKey coins below one visit at their
 * usual (else cheapest) centre. Only for members who have bought a FitKey pass and have no active legacy pass.
 * @returns {Promise<{low: boolean, kind?: 'sessions'|'coins', title?, message?, sessionsLeft, coins, visitCoins, alertKey?}>}
 */
export async function lowBalanceStatus(userId, client = pool) {
  const b = await balances(userId, client);
  const base = { low: false, sessionsLeft: b.sessionsLeft, coins: b.fitkey };
  const legacy = await queryOne(
    `SELECT 1 AS x FROM subscriptions WHERE user_id = $1 AND status = 'active' AND now() BETWEEN starts_at AND ends_at LIMIT 1`,
    [userId],
    client,
  );
  if (legacy) return base;
  const last = await queryOne(
    `SELECT id, kind FROM fitkey_purchases WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1`,
    [userId],
    client,
  );
  if (!last) return base;
  const { coins: visitCoins, basis } = await usualVisitCoins(userId, client);
  base.visitCoins = visitCoins;
  if (b.fitkey >= visitCoins) return base; // coins still cover a visit
  const where = basis === 'usual' ? 'your usual centre' : 'the nearest-priced centre';
  if (b.sessionsLeft === 1) {
    const pass = await nextSessionPass(userId, client);
    return {
      ...base, low: true, kind: 'sessions', alertKey: `sessions:${pass?.id}`,
      title: 'Only 1 session left',
      message: 'Renew your session plan or buy coins so you can keep booking.',
    };
  }
  if (b.sessionsLeft > 1) return base;
  if (last.kind === 'session_plan' && b.fitkey === 0) {
    return {
      ...base, low: true, kind: 'sessions', alertKey: `sessions_out:${last.id}`,
      title: 'Your sessions are used up',
      message: 'Renew a session plan or buy coins to book your next visit.',
    };
  }
  return {
    ...base, low: true, kind: 'coins', alertKey: `coins:${last.id}`,
    title: b.fitkey === 0 ? 'You are out of FitKey coins' : `Only ${fmt(b.fitkey)} coins left`,
    message: `A visit at ${where} costs ${fmt(visitCoins)} coins. Top up to keep booking.`,
  };
}

/** Sends the low-balance in-app notification once per pass / top-up. Never throws. */
export async function checkLowBalance(userId) {
  try {
    const s = await lowBalanceStatus(userId);
    if (!s.low) return s;
    const fresh = await queryOne(
      `INSERT INTO low_balance_alerts (user_id, alert_key) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING alert_key`,
      [userId, s.alertKey],
    );
    if (fresh) {
      await notify(userId, { type: 'wallet_low_balance', title: s.title, body: s.message, data: { screen: 'wallet', kind: s.kind } });
    }
    return s;
  } catch (err) {
    console.error('low balance check failed', err);
    return { low: false };
  }
}

/** After a charge commits (re-reads committed state, so a rolled-back charge sends nothing). */
function scheduleLowBalanceCheck(userId) {
  setTimeout(() => void checkLowBalance(userId), 1500).unref?.();
}

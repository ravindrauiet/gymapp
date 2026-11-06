-- Wallet v2 (BRD §3 FitKey pass in two models + §4 earning/spending coins). Idempotent and additive.
--
-- Three coin balances, all 1 coin = ₹1:
--   * FitKey coins  — bought with money in coin packs; pay for visits; expire per pack (default 180 days).
--                     Held as "lots" in fitkey_purchases.coins_remaining (FIFO by expiry); the ledger keeps history.
--   * Referral coins — welcome bonus + referral rewards (locked until the member buys a FitKey pass); usable on
--                     Store orders and FitKey pass checkout (max 50%), NOT on visits.
--   * ProveIt coins — earned in ProveIt; usable instantly, Store only.
-- Session plans give N visits (1 session per visit at any centre) within their validity.

-- --- Catalogue ---------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS coin_packs (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code          VARCHAR(40) UNIQUE NOT NULL,
  name          VARCHAR(120) NOT NULL,
  description   TEXT,
  price_paise   INT NOT NULL CHECK (price_paise > 0),
  coins         INT NOT NULL CHECK (coins > 0),
  validity_days INT NOT NULL DEFAULT 180 CHECK (validity_days > 0),
  is_active     BOOLEAN NOT NULL DEFAULT true,
  sort_order    INT NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS session_plans (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code          VARCHAR(40) UNIQUE NOT NULL,
  name          VARCHAR(120) NOT NULL,
  description   TEXT,
  price_paise   INT NOT NULL CHECK (price_paise > 0),
  sessions      INT NOT NULL CHECK (sessions > 0),
  validity_days INT NOT NULL CHECK (validity_days > 0),
  is_active     BOOLEAN NOT NULL DEFAULT true,
  sort_order    INT NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO coin_packs (code, name, description, price_paise, coins, validity_days, sort_order) VALUES
  ('coins_500',  'Starter coins', '500 FitKey coins for pay-per-visit', 50000, 500, 180, 1),
  ('coins_1500', 'Regular coins', '1,500 FitKey coins for pay-per-visit', 150000, 1500, 180, 2),
  ('coins_3000', 'Power coins', '3,150 FitKey coins — 5% bonus included', 300000, 3150, 180, 3)
ON CONFLICT (code) DO NOTHING;

INSERT INTO session_plans (code, name, description, price_paise, sessions, validity_days, sort_order) VALUES
  ('sessions_weekly',  'Weekly',  '5 visits in 7 days at any FitKey centre', 69900, 5, 7, 1),
  ('sessions_starter', 'Starter', '8 visits in 30 days at any FitKey centre', 99900, 8, 30, 2),
  ('sessions_monthly', 'Monthly', '21 visits in 30 days at any FitKey centre', 249900, 21, 30, 3)
ON CONFLICT (code) DO NOTHING;

-- Coin cost of one visit, by venue category (the venue's FIRST listed category), with optional per-centre override.
CREATE TABLE IF NOT EXISTS visit_category_costs (
  category   VARCHAR(40) PRIMARY KEY,
  coins      INT NOT NULL CHECK (coins > 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO visit_category_costs (category, coins) VALUES
  ('gym', 100), ('yoga_studio', 120), ('dance', 120), ('martial_arts', 150), ('mma', 150),
  ('swimming_pool', 150), ('sports_club', 200)
ON CONFLICT (category) DO NOTHING;

CREATE TABLE IF NOT EXISTS venue_visit_costs (
  venue_id   UUID PRIMARY KEY REFERENCES venues(id) ON DELETE CASCADE,
  coins      INT NOT NULL CHECK (coins > 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Business rules the team can change from the admin panel.
CREATE TABLE IF NOT EXISTS wallet_settings (
  key        VARCHAR(40) PRIMARY KEY,
  value      INT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO wallet_settings (key, value) VALUES
  ('store_max_coin_pct', 50),     -- max % of a Store order payable with coins (ProveIt first, then referral)
  ('pass_max_coin_pct', 50),      -- max % of a FitKey pass price payable with referral coins
  ('referral_reward', 100),       -- coins for BOTH referrer and new member (locked until the new member buys a pass)
  ('default_visit_coins', 100)    -- visit cost for a category with no row in visit_category_costs
ON CONFLICT (key) DO NOTHING;

-- --- Purchases (coin packs and session plans) ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fitkey_purchases (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind            VARCHAR(12) NOT NULL CHECK (kind IN ('coin_pack', 'session_plan')),
  coin_pack_id    UUID REFERENCES coin_packs(id),
  session_plan_id UUID REFERENCES session_plans(id),
  name            VARCHAR(120) NOT NULL,
  price_paise     INT NOT NULL CHECK (price_paise >= 0),
  coins_redeemed  INT NOT NULL DEFAULT 0 CHECK (coins_redeemed >= 0),  -- referral coins applied at checkout
  paid_paise      INT NOT NULL CHECK (paid_paise >= 0),
  payment_ref     VARCHAR(120),
  coins           INT NOT NULL DEFAULT 0,          -- coin pack: coins credited
  coins_remaining INT NOT NULL DEFAULT 0 CHECK (coins_remaining >= 0),
  sessions_total  INT NOT NULL DEFAULT 0,          -- session plan: visits included
  sessions_used   INT NOT NULL DEFAULT 0 CHECK (sessions_used >= 0),
  starts_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at      TIMESTAMPTZ NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (sessions_used <= sessions_total),
  CHECK (coins_remaining <= coins)
);
CREATE INDEX IF NOT EXISTS fitkey_purchases_user_idx ON fitkey_purchases (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS fitkey_purchases_active_idx ON fitkey_purchases (user_id, kind, expires_at);

-- One row per charged visit (booking). Allocations remember which coin lots paid, so a refund returns them exactly.
CREATE TABLE IF NOT EXISTS visit_charges (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  venue_id    UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  booking_id  UUID,                                  -- bookings table is created later (migration 140): no FK
  method      VARCHAR(12) NOT NULL CHECK (method IN ('session', 'coins', 'legacy_pass')),
  amount      INT NOT NULL DEFAULT 0,                -- coins or sessions taken
  purchase_id UUID REFERENCES fitkey_purchases(id),  -- session plan used
  allocations JSONB NOT NULL DEFAULT '[]',           -- [{purchaseId, coins}]
  status      VARCHAR(10) NOT NULL DEFAULT 'charged' CHECK (status IN ('charged', 'refunded')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  refunded_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS visit_charges_booking_uniq ON visit_charges (booking_id) WHERE booking_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS visit_charges_user_idx ON visit_charges (user_id, created_at DESC);

-- Low-balance alerts already sent (one per pass / per coin top-up), so the member isn't nagged.
CREATE TABLE IF NOT EXISTS low_balance_alerts (
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  alert_key  VARCHAR(80) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, alert_key)
);

-- --- Ledger: three balances ------------------------------------------------------------------------------------
ALTER TABLE coin_ledger ADD COLUMN IF NOT EXISTS wallet VARCHAR(10) NOT NULL DEFAULT 'referral';
ALTER TABLE coin_ledger ADD COLUMN IF NOT EXISTS ref VARCHAR(120);
ALTER TABLE coin_ledger ADD COLUMN IF NOT EXISTS purchase_id UUID REFERENCES fitkey_purchases(id) ON DELETE SET NULL;
ALTER TABLE coin_ledger ADD COLUMN IF NOT EXISTS visit_charge_id UUID REFERENCES visit_charges(id) ON DELETE SET NULL;
ALTER TABLE coin_ledger ADD COLUMN IF NOT EXISTS order_id UUID REFERENCES marketplace_orders(id) ON DELETE SET NULL;
ALTER TABLE coin_ledger DROP CONSTRAINT IF EXISTS coin_ledger_wallet_check;
ALTER TABLE coin_ledger ADD CONSTRAINT coin_ledger_wallet_check CHECK (wallet IN ('fitkey', 'referral', 'proveit'));
ALTER TABLE coin_ledger DROP CONSTRAINT IF EXISTS coin_ledger_kind_check;
ALTER TABLE coin_ledger ADD CONSTRAINT coin_ledger_kind_check CHECK (kind IN (
  'welcome_bonus', 'plan_purchase', 'referral_reward', 'redemption', 'expiry', 'adjustment',
  'referral_signup',   -- v2 referral reward: both sides, locked until the new member buys a FitKey pass
  'referral_credit',   -- creditCoins(kind 'referral')
  'proveit',           -- creditCoins(kind 'proveit')
  'pack_purchase',     -- FitKey coins bought in a coin pack
  'visit', 'visit_refund',
  'store_redemption', 'pass_redemption'
));
-- Legacy 'plan_purchase' rows (old "1 coin per ₹1 paid" rule) and welcome/referral rewards stay referral-type coins.
CREATE INDEX IF NOT EXISTS coin_ledger_wallet_idx ON coin_ledger (user_id, wallet, status);
CREATE UNIQUE INDEX IF NOT EXISTS coin_ledger_ref_uniq ON coin_ledger (user_id, kind, ref) WHERE ref IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS coin_ledger_referral_signup_uniq ON coin_ledger (user_id, referral_id) WHERE kind = 'referral_signup';

-- Store orders: coins applied and what was left to pay.
ALTER TABLE marketplace_orders ADD COLUMN IF NOT EXISTS coins_redeemed INT NOT NULL DEFAULT 0;
ALTER TABLE marketplace_orders ADD COLUMN IF NOT EXISTS proveit_coins_redeemed INT NOT NULL DEFAULT 0;
ALTER TABLE marketplace_orders ADD COLUMN IF NOT EXISTS referral_coins_redeemed INT NOT NULL DEFAULT 0;
ALTER TABLE marketplace_orders ADD COLUMN IF NOT EXISTS payable_paise INT;

-- Referrals still waiting for the friend's first pass get the v2 reward now: 100 locked coins for BOTH sides.
-- (Referrals already completed under the old rule were rewarded with 'referral_reward' and are left alone.)
INSERT INTO coin_ledger (user_id, amount, kind, wallet, status, referral_id, note)
SELECT r.referrer_id, 100, 'referral_signup', 'referral', 'locked', r.id, 'Referral reward'
FROM referrals r WHERE r.status = 'signed_up'
ON CONFLICT DO NOTHING;
INSERT INTO coin_ledger (user_id, amount, kind, wallet, status, referral_id, note)
SELECT r.referred_user_id, 100, 'referral_signup', 'referral', 'locked', r.id, 'Joined with a referral code'
FROM referrals r WHERE r.status = 'signed_up'
ON CONFLICT DO NOTHING;

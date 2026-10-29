-- FitKey Coins wallet + Refer & Earn (BRD §9). Idempotent and additive: runs on every server start.
--
-- Coins live in an append-only ledger (one row per credit; later spending/expiry will be negative rows with their
-- own kinds). Balance = SUM(amount) per status. A row is 'locked' until the member buys their first pass.

-- Referral codes look like FK7QX2M9 (no 0/O/1/I to avoid confusion when typed).
CREATE OR REPLACE FUNCTION fitkey_gen_referral_code() RETURNS text AS $$
DECLARE
  alphabet CONSTANT text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  code text;
BEGIN
  LOOP
    code := 'FK';
    FOR i IN 1..6 LOOP
      code := code || substr(alphabet, 1 + floor(random() * 32)::int, 1);
    END LOOP;
    EXIT WHEN NOT EXISTS (SELECT 1 FROM users WHERE referral_code = code);
  END LOOP;
  RETURN code;
END;
$$ LANGUAGE plpgsql VOLATILE;

ALTER TABLE users ADD COLUMN IF NOT EXISTS referral_code VARCHAR(12);
ALTER TABLE users ADD COLUMN IF NOT EXISTS referred_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS signup_device_id VARCHAR(128);

-- Backfill codes for existing accounts one row at a time (so the uniqueness check inside the generator sees them).
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT id FROM users WHERE referral_code IS NULL LOOP
    UPDATE users SET referral_code = fitkey_gen_referral_code() WHERE id = r.id;
  END LOOP;
END;
$$;

ALTER TABLE users ALTER COLUMN referral_code SET DEFAULT fitkey_gen_referral_code();
CREATE UNIQUE INDEX IF NOT EXISTS users_referral_code_uniq ON users (referral_code);
CREATE INDEX IF NOT EXISTS users_signup_device_idx ON users (signup_device_id) WHERE signup_device_id IS NOT NULL;

-- One row per referred member: who invited them and how far they got.
CREATE TABLE IF NOT EXISTS referrals (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  referred_user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  code             VARCHAR(12) NOT NULL,
  status           VARCHAR(12) NOT NULL DEFAULT 'signed_up' CHECK (status IN ('signed_up', 'pass_bought')),
  device_id        VARCHAR(128),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  pass_bought_at   TIMESTAMPTZ,
  rewarded_at      TIMESTAMPTZ,
  CHECK (referrer_id <> referred_user_id)
);
CREATE INDEX IF NOT EXISTS referrals_referrer_idx ON referrals (referrer_id, created_at DESC);
-- A device can be used for at most one referred signup.
CREATE UNIQUE INDEX IF NOT EXISTS referrals_device_uniq ON referrals (device_id) WHERE device_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS coin_ledger (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- Positive = credit. Spending / expiry (not live yet) will be negative rows.
  amount          INT NOT NULL CHECK (amount <> 0),
  kind            VARCHAR(24) NOT NULL
                  CHECK (kind IN ('welcome_bonus', 'plan_purchase', 'referral_reward', 'redemption', 'expiry', 'adjustment')),
  status          VARCHAR(12) NOT NULL DEFAULT 'available' CHECK (status IN ('locked', 'available')),
  subscription_id UUID REFERENCES subscriptions(id) ON DELETE SET NULL,
  referral_id     UUID REFERENCES referrals(id) ON DELETE SET NULL,
  note            VARCHAR(160),
  unlocked_at     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS coin_ledger_user_idx ON coin_ledger (user_id, created_at DESC);
-- The same reward can never be granted twice.
CREATE UNIQUE INDEX IF NOT EXISTS coin_ledger_welcome_uniq ON coin_ledger (user_id) WHERE kind = 'welcome_bonus';
CREATE UNIQUE INDEX IF NOT EXISTS coin_ledger_plan_uniq ON coin_ledger (subscription_id) WHERE kind = 'plan_purchase';
CREATE UNIQUE INDEX IF NOT EXISTS coin_ledger_referral_uniq ON coin_ledger (referral_id) WHERE kind = 'referral_reward';

-- Every member gets 100 welcome coins: locked until their first pass, already usable if they have bought one.
INSERT INTO coin_ledger (user_id, amount, kind, status, unlocked_at)
SELECT u.id, 100, 'welcome_bonus',
       CASE WHEN EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = u.id AND s.status = 'active') THEN 'available' ELSE 'locked' END,
       CASE WHEN EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = u.id AND s.status = 'active') THEN now() END
FROM users u WHERE u.role = 'user'
ON CONFLICT DO NOTHING;

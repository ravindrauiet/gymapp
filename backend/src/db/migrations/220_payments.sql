-- Razorpay payments (PAYMENTS_MODE=razorpay). Idempotent and additive.
-- One row per checkout: what is being bought (purpose + payload), the amount, the Razorpay order / payment, and the
-- result of fulfilling it. Fulfilment happens once (status 'fulfilling' is claimed atomically) from either the app's
-- verify call or the Razorpay webhook, whichever arrives first.
CREATE TABLE IF NOT EXISTS payment_orders (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose             VARCHAR(30) NOT NULL,   -- subscription | wallet_pass | membership | membership_renew | store_order
  payload             JSONB NOT NULL DEFAULT '{}'::jsonb,
  description         VARCHAR(200),
  amount_paise        INT NOT NULL CHECK (amount_paise >= 0),
  currency            VARCHAR(3) NOT NULL DEFAULT 'INR',
  razorpay_order_id   VARCHAR(40) UNIQUE,
  razorpay_payment_id VARCHAR(40),
  status              VARCHAR(16) NOT NULL DEFAULT 'created'
                      CHECK (status IN ('created', 'paid', 'fulfilling', 'fulfilled', 'failed', 'refunded')),
  result              JSONB,
  error               VARCHAR(500),
  refund_id           VARCHAR(40),
  refunded_paise      INT NOT NULL DEFAULT 0,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  paid_at             TIMESTAMPTZ,
  fulfilled_at        TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS payment_orders_user_idx ON payment_orders (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS payment_orders_open_idx ON payment_orders (created_at) WHERE status IN ('created', 'paid');

-- Store orders paid online keep the Razorpay payment id.
ALTER TABLE marketplace_orders ADD COLUMN IF NOT EXISTS payment_ref VARCHAR(60);

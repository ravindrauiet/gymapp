-- Partner BRD §7 / §10.4: run / sell / earn for trainers, clinics, chemists and store sellers.
-- Additive and idempotent (owner: backend-types). Depends on 211_partner_types.sql.

-- ---------------------------------------------------------------------------------------------- trainers
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS experience_years INT CHECK (experience_years IS NULL OR experience_years BETWEEN 0 AND 60);
-- A partner listing is created on the first save of the profile step, before the price is known.
-- Members never see such a row (it is not live), and booking refuses a trainer without a price.
ALTER TABLE trainers ALTER COLUMN hourly_rate_paise DROP NOT NULL;
ALTER TABLE trainers ALTER COLUMN bio SET DEFAULT '';
ALTER TABLE trainer_bookings ADD COLUMN IF NOT EXISTS commission_pct NUMERIC(5, 2);
ALTER TABLE trainer_bookings ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;

-- ---------------------------------------------------------------------------------------------- clinics
CREATE TABLE IF NOT EXISTS clinic_appointments (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id    UUID NOT NULL REFERENCES health_clinics(id) ON DELETE CASCADE,
  user_id      UUID REFERENCES users(id) ON DELETE SET NULL,      -- NULL for walk-ins added by the clinic
  patient_name VARCHAR(120) NOT NULL,
  patient_phone VARCHAR(16),
  doctor_name  VARCHAR(120),
  appt_date    DATE NOT NULL,
  slot_time    VARCHAR(5) NOT NULL,                               -- HH:MM
  token_no     INT NOT NULL DEFAULT 1,                            -- queue position for the day
  fee_paise    INT NOT NULL DEFAULT 0 CHECK (fee_paise >= 0),
  source       VARCHAR(12) NOT NULL DEFAULT 'fitkey' CHECK (source IN ('fitkey', 'walk_in')),
  status       VARCHAR(16) NOT NULL DEFAULT 'booked'
               CHECK (status IN ('booked', 'checked_in', 'in_consultation', 'completed', 'cancelled', 'no_show')),
  reason       VARCHAR(300),
  note         VARCHAR(500),
  commission_pct NUMERIC(5, 2),
  completed_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS clinic_appointments_clinic_day_idx ON clinic_appointments (clinic_id, appt_date, token_no);
CREATE INDEX IF NOT EXISTS clinic_appointments_user_idx ON clinic_appointments (user_id, appt_date DESC);

-- ---------------------------------------------------------------------------------------------- chemists
ALTER TABLE health_chemists ADD COLUMN IF NOT EXISTS home_delivery BOOLEAN;  -- BRD "home delivery yes/no" (delivery_available mirrors it)

CREATE TABLE IF NOT EXISTS chemist_orders (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  chemist_id       UUID NOT NULL REFERENCES health_chemists(id) ON DELETE CASCADE,
  user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  items            JSONB NOT NULL DEFAULT '[]'::jsonb,            -- [{ "name": "Paracetamol 500", "qty": 2, "note": "" }]
  prescription_url TEXT,
  fulfilment       VARCHAR(10) NOT NULL DEFAULT 'delivery' CHECK (fulfilment IN ('delivery', 'pickup')),
  address          JSONB,
  phone            VARCHAR(16),
  status           VARCHAR(20) NOT NULL DEFAULT 'requested'
                   CHECK (status IN ('requested', 'accepted', 'packed', 'out_for_delivery', 'delivered', 'picked_up', 'rejected', 'cancelled')),
  mrp_paise        INT CHECK (mrp_paise IS NULL OR mrp_paise >= 0),   -- quoted by the chemist on accept
  discount_paise   INT NOT NULL DEFAULT 0 CHECK (discount_paise >= 0),
  amount_paise     INT CHECK (amount_paise IS NULL OR amount_paise >= 0),
  commission_pct   NUMERIC(5, 2),
  note             VARCHAR(500),
  reject_reason    VARCHAR(200),
  accepted_at      TIMESTAMPTZ,
  delivered_at     TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS chemist_orders_chemist_idx ON chemist_orders (chemist_id, created_at DESC);
CREATE INDEX IF NOT EXISTS chemist_orders_user_idx ON chemist_orders (user_id, created_at DESC);

-- ---------------------------------------------------------------------------------------------- store sellers
-- BRD store categories join the legacy product categories.
ALTER TABLE marketplace_products DROP CONSTRAINT IF EXISTS marketplace_products_category_check;
ALTER TABLE marketplace_products ADD CONSTRAINT marketplace_products_category_check CHECK (category IN
  ('supplements', 'apparel', 'wearables', 'gear', 'activewear', 'gym_gear', 'healthy_food', 'wellness', 'accessories'));
-- Low-stock alert threshold per SKU.
ALTER TABLE marketplace_products ADD COLUMN IF NOT EXISTS low_stock_threshold INT NOT NULL DEFAULT 5 CHECK (low_stock_threshold >= 0);
ALTER TABLE marketplace_products ADD COLUMN IF NOT EXISTS sku VARCHAR(60);

-- Returns per order line.
ALTER TABLE marketplace_order_items ADD COLUMN IF NOT EXISTS return_status VARCHAR(12)
  CHECK (return_status IS NULL OR return_status IN ('requested', 'approved', 'rejected', 'received', 'refunded'));
ALTER TABLE marketplace_order_items ADD COLUMN IF NOT EXISTS return_reason VARCHAR(300);
ALTER TABLE marketplace_order_items ADD COLUMN IF NOT EXISTS return_note VARCHAR(300);
ALTER TABLE marketplace_order_items ADD COLUMN IF NOT EXISTS return_requested_at TIMESTAMPTZ;
ALTER TABLE marketplace_order_items ADD COLUMN IF NOT EXISTS return_updated_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS marketplace_order_items_vendor_idx ON marketplace_order_items (vendor_id);
CREATE INDEX IF NOT EXISTS marketplace_order_items_returns_idx ON marketplace_order_items (vendor_id) WHERE return_status IS NOT NULL;

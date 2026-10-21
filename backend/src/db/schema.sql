-- FITKEY schema (Phase 1). Idempotent: safe to run repeatedly via `npm run migrate`.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- Accounts: one table for members, partners (venue owners) and FITKEY admins.
-- The same phone can hold a member account and a partner account.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone       VARCHAR(16)  NOT NULL,
  email       VARCHAR(255),
  name        VARCHAR(120),
  role        VARCHAR(10)  NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'partner', 'admin')),
  city        VARCHAR(80),
  gender      VARCHAR(12)  CHECK (gender IN ('male', 'female', 'other')),
  birth_date  DATE,
  avatar_url  TEXT,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  UNIQUE (phone, role)
);

CREATE TABLE IF NOT EXISTS otp_codes (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone       VARCHAR(16) NOT NULL,
  role        VARCHAR(10) NOT NULL,
  code_hash   TEXT        NOT NULL,
  attempts    INT         NOT NULL DEFAULT 0,
  expires_at  TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS otp_codes_phone_role_idx ON otp_codes (phone, role, created_at DESC);

-- ---------------------------------------------------------------------------
-- Venues (Partner app P2–P5, P8)
-- categories: gym, swimming_pool, sports_club, yoga_studio, mma, martial_arts, dance
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS venues (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name              VARCHAR(160) NOT NULL,
  description       TEXT,
  categories        TEXT[] NOT NULL DEFAULT '{}',
  address           TEXT,
  area              VARCHAR(120),
  city              VARCHAR(80),
  latitude          DOUBLE PRECISION,
  longitude         DOUBLE PRECISION,
  opens_at          TIME,
  closes_at         TIME,
  open_days         TEXT[] NOT NULL DEFAULT '{mon,tue,wed,thu,fri,sat}',
  contact_phone     VARCHAR(16),
  contact_email     VARCHAR(255),
  trainer_available BOOLEAN NOT NULL DEFAULT false,
  equipment         TEXT[] NOT NULL DEFAULT '{}',
  amenities         TEXT[] NOT NULL DEFAULT '{}',
  photos            TEXT[] NOT NULL DEFAULT '{}',
  status            VARCHAR(16) NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'submitted', 'under_review', 'live', 'rejected')),
  review_note       TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS venues_status_city_idx ON venues (status, city);
CREATE INDEX IF NOT EXISTS venues_categories_idx ON venues USING GIN (categories);
CREATE INDEX IF NOT EXISTS venues_owner_idx ON venues (owner_id);

-- ---------------------------------------------------------------------------
-- Plans & subscriptions (User app U2). A plan covers venues whose categories
-- overlap the plan's categories.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS plans (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code          VARCHAR(40) UNIQUE NOT NULL,
  name          VARCHAR(120) NOT NULL,
  description   TEXT,
  categories    TEXT[] NOT NULL,
  price_paise   INT NOT NULL CHECK (price_paise >= 0),
  duration_days INT NOT NULL CHECK (duration_days > 0),
  features      TEXT[] NOT NULL DEFAULT '{}',
  is_active     BOOLEAN NOT NULL DEFAULT true,
  sort_order    INT NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS subscriptions (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plan_id      UUID NOT NULL REFERENCES plans(id),
  status       VARCHAR(12) NOT NULL DEFAULT 'active' CHECK (status IN ('pending', 'active', 'cancelled')),
  starts_at    TIMESTAMPTZ NOT NULL,
  ends_at      TIMESTAMPTZ NOT NULL,
  amount_paise INT NOT NULL,
  payment_ref  VARCHAR(120),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS subscriptions_user_idx ON subscriptions (user_id, ends_at DESC);

-- ---------------------------------------------------------------------------
-- Check-ins (P6, P7, U4)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS checkin_codes (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id   UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  otp        VARCHAR(6) NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS checkin_codes_venue_idx ON checkin_codes (venue_id, expires_at DESC);

CREATE TABLE IF NOT EXISTS checkins (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  venue_id        UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  subscription_id UUID REFERENCES subscriptions(id),
  method          VARCHAR(4) NOT NULL CHECK (method IN ('qr', 'otp')),
  checkin_date    DATE NOT NULL,
  checked_in_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, venue_id, checkin_date)
);
CREATE INDEX IF NOT EXISTS checkins_venue_date_idx ON checkins (venue_id, checkin_date);
CREATE INDEX IF NOT EXISTS checkins_user_date_idx ON checkins (user_id, checkin_date);

-- ---------------------------------------------------------------------------
-- FitKey Studio video library (U5)
-- categories: gym, yoga, dance, boxing, martial_arts
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS videos (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category         VARCHAR(20) NOT NULL,
  title            VARCHAR(200) NOT NULL,
  description      TEXT,
  trainer_name     VARCHAR(120),
  level            VARCHAR(12) NOT NULL DEFAULT 'beginner' CHECK (level IN ('beginner', 'intermediate', 'advanced')),
  video_url        TEXT NOT NULL,
  thumbnail_url    TEXT,
  duration_seconds INT,
  is_published     BOOLEAN NOT NULL DEFAULT true,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS videos_category_idx ON videos (category, created_at DESC);

-- ---------------------------------------------------------------------------
-- Find your gym buddy (U6)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS buddy_posts (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  venue_id   UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  slot_date  DATE NOT NULL,
  slot_start TIME NOT NULL,
  slot_end   TIME NOT NULL,
  note       VARCHAR(280),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (slot_end > slot_start)
);
CREATE INDEX IF NOT EXISTS buddy_posts_venue_date_idx ON buddy_posts (venue_id, slot_date);

CREATE TABLE IF NOT EXISTS buddy_requests (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_post_id UUID NOT NULL REFERENCES buddy_posts(id) ON DELETE CASCADE,
  to_post_id   UUID NOT NULL REFERENCES buddy_posts(id) ON DELETE CASCADE,
  from_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  to_user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status       VARCHAR(10) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (from_post_id, to_post_id)
);

CREATE TABLE IF NOT EXISTS buddy_messages (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id UUID NOT NULL REFERENCES buddy_requests(id) ON DELETE CASCADE,
  sender_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  body       VARCHAR(1000) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS buddy_messages_request_idx ON buddy_messages (request_id, created_at);

CREATE TABLE IF NOT EXISTS user_blocks (
  blocker_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id)
);

CREATE TABLE IF NOT EXISTS user_reports (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  reported_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  reason      VARCHAR(500) NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Health tracking (U9) — also feeds running contests
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS activity_logs (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type         VARCHAR(16) NOT NULL CHECK (type IN ('workout', 'running', 'cycling', 'swimming', 'yoga', 'sports', 'other')),
  title        VARCHAR(120),
  duration_min INT CHECK (duration_min >= 0),
  distance_km  NUMERIC(6, 2) CHECK (distance_km >= 0),
  calories     INT CHECK (calories >= 0),
  notes        VARCHAR(500),
  logged_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS activity_logs_user_idx ON activity_logs (user_id, logged_at DESC);

CREATE TABLE IF NOT EXISTS weight_logs (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  weight_kg NUMERIC(5, 2) NOT NULL CHECK (weight_kg > 0),
  logged_on DATE NOT NULL,
  UNIQUE (user_id, logged_on)
);

-- ---------------------------------------------------------------------------
-- Contests & leaderboard (U7, U8)
-- metric: checkins (distinct check-in days), running_km, streak (longest run of consecutive check-in days)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS contests (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title       VARCHAR(160) NOT NULL,
  description TEXT,
  period      VARCHAR(8)  NOT NULL CHECK (period IN ('weekly', 'monthly')),
  metric      VARCHAR(12) NOT NULL CHECK (metric IN ('checkins', 'running_km', 'streak')),
  starts_on   DATE NOT NULL,
  ends_on     DATE NOT NULL,
  reward      VARCHAR(200),
  city        VARCHAR(80),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (ends_on >= starts_on)
);

CREATE TABLE IF NOT EXISTS contest_participants (
  contest_id UUID NOT NULL REFERENCES contests(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  joined_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (contest_id, user_id)
);

-- ---------------------------------------------------------------------------
-- Uploaded images (venue photos). Stored in Postgres so Phase 1 needs no object storage;
-- move to S3/Cloudinary when volume grows — clients only ever see the URL.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS files (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id   UUID REFERENCES users(id) ON DELETE SET NULL,
  mime       VARCHAR(60) NOT NULL,
  size_bytes INT NOT NULL,
  data       BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 1. Goal-Based Onboarding & User Profiling
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_goals (
  user_id               UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  goal_type             VARCHAR(20) NOT NULL CHECK (goal_type IN ('weight_loss', 'muscle_gain', 'maintenance')),
  age                   INT NOT NULL CHECK (age >= 10 AND age <= 120),
  gender                VARCHAR(12) NOT NULL CHECK (gender IN ('male', 'female', 'other')),
  height_cm             NUMERIC(5, 2) NOT NULL CHECK (height_cm >= 50 AND height_cm <= 300),
  current_weight_kg     NUMERIC(5, 2) NOT NULL CHECK (current_weight_kg >= 20 AND current_weight_kg <= 400),
  target_weight_kg      NUMERIC(5, 2) NOT NULL CHECK (target_weight_kg >= 20 AND target_weight_kg <= 400),
  activity_level        VARCHAR(20) NOT NULL CHECK (activity_level IN ('sedentary', 'light', 'moderate', 'very_active')),
  daily_calorie_target  INT NOT NULL CHECK (daily_calorie_target > 0),
  daily_protein_g       INT NOT NULL CHECK (daily_protein_g >= 0),
  daily_carbs_g         INT NOT NULL CHECK (daily_carbs_g >= 0),
  daily_fat_g           INT NOT NULL CHECK (daily_fat_g >= 0),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 2. Marketplace / Store Module
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS marketplace_vendors (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  business_name       VARCHAR(160) NOT NULL,
  gstin               VARCHAR(30),
  bank_name           VARCHAR(100),
  bank_account_no     VARCHAR(40),
  ifsc_code           VARCHAR(20),
  verification_status VARCHAR(20) NOT NULL DEFAULT 'verified' CHECK (verification_status IN ('pending', 'verified', 'rejected')),
  commission_rate     NUMERIC(4, 2) NOT NULL DEFAULT 10.00,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (partner_id)
);

CREATE TABLE IF NOT EXISTS marketplace_products (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id            UUID REFERENCES marketplace_vendors(id) ON DELETE CASCADE,
  title                VARCHAR(200) NOT NULL,
  brand                VARCHAR(100) NOT NULL,
  category             VARCHAR(30) NOT NULL CHECK (category IN ('supplements', 'apparel', 'wearables', 'gear')),
  description          TEXT NOT NULL,
  price_paise          INT NOT NULL CHECK (price_paise >= 0),
  original_price_paise INT NOT NULL CHECK (original_price_paise >= 0),
  stock_quantity       INT NOT NULL DEFAULT 10 CHECK (stock_quantity >= 0),
  images               TEXT[] NOT NULL DEFAULT '{}',
  specs                JSONB NOT NULL DEFAULT '{}',
  is_active            BOOLEAN NOT NULL DEFAULT true,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS marketplace_products_cat_idx ON marketplace_products (category, is_active);

CREATE TABLE IF NOT EXISTS marketplace_orders (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status             VARCHAR(20) NOT NULL DEFAULT 'placed'
                     CHECK (status IN ('placed', 'processing', 'dispatched', 'out_for_delivery', 'delivered', 'cancelled')),
  total_amount_paise INT NOT NULL CHECK (total_amount_paise >= 0),
  payment_method     VARCHAR(30) NOT NULL CHECK (payment_method IN ('upi', 'card', 'netbanking', 'cod')),
  payment_status     VARCHAR(20) NOT NULL DEFAULT 'paid' CHECK (payment_status IN ('pending', 'paid', 'cod_pending')),
  shipping_address   JSONB NOT NULL,
  tracking_number    VARCHAR(80),
  dispatched_at      TIMESTAMPTZ,
  delivered_at       TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS marketplace_orders_user_idx ON marketplace_orders (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS marketplace_order_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    UUID NOT NULL REFERENCES marketplace_orders(id) ON DELETE CASCADE,
  product_id  UUID REFERENCES marketplace_products(id) ON DELETE SET NULL,
  vendor_id   UUID REFERENCES marketplace_vendors(id) ON DELETE SET NULL,
  title       VARCHAR(200) NOT NULL,
  price_paise INT NOT NULL CHECK (price_paise >= 0),
  quantity    INT NOT NULL DEFAULT 1 CHECK (quantity > 0)
);

-- ---------------------------------------------------------------------------
-- 3. "Fuel Log" (Nutrition & Meal Tracker Module)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS food_items (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  barcode           VARCHAR(32),
  name              VARCHAR(160) NOT NULL,
  serving_unit      VARCHAR(60) NOT NULL,
  calories          INT NOT NULL CHECK (calories >= 0),
  protein_g         NUMERIC(6, 2) NOT NULL DEFAULT 0,
  carbs_g           NUMERIC(6, 2) NOT NULL DEFAULT 0,
  fat_g             NUMERIC(6, 2) NOT NULL DEFAULT 0,
  fibre_g           NUMERIC(6, 2) NOT NULL DEFAULT 0,
  iron_mg           NUMERIC(6, 2) NOT NULL DEFAULT 0,
  magnesium_mg      NUMERIC(6, 2) NOT NULL DEFAULT 0,
  calcium_mg        NUMERIC(6, 2) NOT NULL DEFAULT 0,
  sodium_mg         NUMERIC(6, 2) NOT NULL DEFAULT 0,
  category          VARCHAR(40) NOT NULL DEFAULT 'general',
  educational_notes TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS food_items_name_idx ON food_items (name);
CREATE INDEX IF NOT EXISTS food_items_barcode_idx ON food_items (barcode);

CREATE TABLE IF NOT EXISTS meal_logs (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  meal_type  VARCHAR(20) NOT NULL CHECK (meal_type IN ('breakfast', 'lunch', 'dinner', 'snacks')),
  food_id    UUID REFERENCES food_items(id) ON DELETE SET NULL,
  food_name  VARCHAR(160) NOT NULL,
  servings   NUMERIC(4, 2) NOT NULL DEFAULT 1.0 CHECK (servings > 0),
  calories   INT NOT NULL CHECK (calories >= 0),
  protein_g  NUMERIC(6, 2) NOT NULL DEFAULT 0,
  carbs_g    NUMERIC(6, 2) NOT NULL DEFAULT 0,
  fat_g      NUMERIC(6, 2) NOT NULL DEFAULT 0,
  logged_on  DATE NOT NULL,
  logged_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS meal_logs_user_date_idx ON meal_logs (user_id, logged_on);

-- ---------------------------------------------------------------------------
-- 4. Activity & Movement Tracking Engine
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS step_logs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  log_date        DATE NOT NULL,
  steps           INT NOT NULL DEFAULT 0 CHECK (steps >= 0),
  distance_km     NUMERIC(6, 2) NOT NULL DEFAULT 0 CHECK (distance_km >= 0),
  active_calories INT NOT NULL DEFAULT 0 CHECK (active_calories >= 0),
  source          VARCHAR(40) NOT NULL DEFAULT 'health_connect',
  synced_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, log_date)
);

-- ---------------------------------------------------------------------------
-- 6. FitPro On-Demand (Book a Trainer)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS trainers (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_id          UUID REFERENCES users(id) ON DELETE SET NULL,
  name                VARCHAR(160) NOT NULL,
  photo_url           TEXT,
  bio                 TEXT NOT NULL,
  rating              NUMERIC(3, 2) NOT NULL DEFAULT 4.9,
  review_count        INT NOT NULL DEFAULT 24,
  certifications      TEXT[] NOT NULL DEFAULT '{}',
  specializations     TEXT[] NOT NULL DEFAULT '{}',
  training_modes      TEXT[] NOT NULL DEFAULT '{online,home,gym}',
  hourly_rate_paise   INT NOT NULL CHECK (hourly_rate_paise > 0),
  buffer_minutes      INT NOT NULL DEFAULT 30,
  working_hours       JSONB NOT NULL DEFAULT '{"start": "06:00", "end": "21:00"}',
  verification_status VARCHAR(20) NOT NULL DEFAULT 'verified' CHECK (verification_status IN ('pending', 'verified', 'rejected')),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS trainer_bookings (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trainer_id       UUID NOT NULL REFERENCES trainers(id) ON DELETE CASCADE,
  user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mode             VARCHAR(20) NOT NULL CHECK (mode IN ('online', 'home', 'gym')),
  session_date     DATE NOT NULL,
  slot_time        VARCHAR(20) NOT NULL,
  duration_minutes INT NOT NULL DEFAULT 60,
  amount_paise     INT NOT NULL CHECK (amount_paise >= 0),
  status           VARCHAR(20) NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed', 'completed', 'cancelled')),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS trainer_bookings_trainer_idx ON trainer_bookings (trainer_id, session_date);
CREATE INDEX IF NOT EXISTS trainer_bookings_user_idx ON trainer_bookings (user_id, session_date);

-- ---------------------------------------------------------------------------
-- 7. HealthStop Near You (Clinics & Chemists)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS health_chemists (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name               VARCHAR(160) NOT NULL,
  address            TEXT NOT NULL,
  city               VARCHAR(80) NOT NULL,
  distance_km        NUMERIC(4, 1) NOT NULL DEFAULT 1.2,
  operational_hours  VARCHAR(80) NOT NULL,
  delivery_available BOOLEAN NOT NULL DEFAULT true,
  delivery_time_est  VARCHAR(60) NOT NULL DEFAULT '30-45 mins',
  phone              VARCHAR(20) NOT NULL,
  latitude           DOUBLE PRECISION,
  longitude          DOUBLE PRECISION,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS health_clinics (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name                   VARCHAR(160) NOT NULL,
  address                TEXT NOT NULL,
  city                   VARCHAR(80) NOT NULL,
  distance_km            NUMERIC(4, 1) NOT NULL DEFAULT 1.5,
  doctors                JSONB NOT NULL DEFAULT '[]',
  facilities             TEXT[] NOT NULL DEFAULT '{}',
  slot_timings           VARCHAR(120) NOT NULL,
  consultation_fee_paise INT NOT NULL CHECK (consultation_fee_paise >= 0),
  phone                  VARCHAR(20) NOT NULL,
  latitude               DOUBLE PRECISION,
  longitude              DOUBLE PRECISION,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

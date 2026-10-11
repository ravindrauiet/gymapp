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

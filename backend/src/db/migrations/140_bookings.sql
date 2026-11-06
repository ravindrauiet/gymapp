-- Slot booking, check-in access rules, per-visit payouts and direct centre memberships (BRD §2, §3.2).
-- Idempotent and additive: runs on every server start.

-- Per-centre settings (admin-set). NULL = use the default.
ALTER TABLE venues ADD COLUMN IF NOT EXISTS slot_capacity INT NOT NULL DEFAULT 20;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS visit_payout_paise INT;      -- NULL = the centre's coin cost in ₹
ALTER TABLE venues ADD COLUMN IF NOT EXISTS commission_pct NUMERIC(5, 2); -- NULL = category / global default
ALTER TABLE venues DROP CONSTRAINT IF EXISTS venues_slot_capacity_chk;
ALTER TABLE venues ADD CONSTRAINT venues_slot_capacity_chk CHECK (slot_capacity BETWEEN 1 AND 1000);

-- FitKey commission on direct memberships per venue category (admin-set). Missing row = global default (15%).
CREATE TABLE IF NOT EXISTS category_commissions (
  category       VARCHAR(20) PRIMARY KEY,
  commission_pct NUMERIC(5, 2) NOT NULL CHECK (commission_pct >= 0 AND commission_pct <= 100),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- A centre's own membership plans (BRD §2). Live for members only when approved AND active.
CREATE TABLE IF NOT EXISTS centre_plans (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id            UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  name                VARCHAR(120) NOT NULL,
  description         VARCHAR(1000),
  duration            VARCHAR(12) NOT NULL CHECK (duration IN ('day', 'monthly', 'quarterly', 'annual')),
  duration_days       INT NOT NULL CHECK (duration_days > 0),
  price_paise         INT NOT NULL CHECK (price_paise > 0),
  inclusions          TEXT[] NOT NULL DEFAULT '{}',
  max_visits_per_day  INT CHECK (max_visits_per_day > 0),
  max_visits_per_week INT CHECK (max_visits_per_week > 0),
  offer_pct           INT NOT NULL DEFAULT 0 CHECK (offer_pct BETWEEN 0 AND 90),
  is_active           BOOLEAN NOT NULL DEFAULT true,
  approval_status     VARCHAR(10) NOT NULL DEFAULT 'pending' CHECK (approval_status IN ('pending', 'approved', 'rejected')),
  review_note         VARCHAR(500),
  reviewed_at         TIMESTAMPTZ,
  archived_at         TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS centre_plans_venue_idx ON centre_plans (venue_id) WHERE archived_at IS NULL;
CREATE INDEX IF NOT EXISTS centre_plans_pending_idx ON centre_plans (created_at) WHERE approval_status = 'pending';

-- A member's purchased direct membership. Plan terms are copied so later plan edits don't change what was bought.
CREATE TABLE IF NOT EXISTS direct_memberships (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  venue_id            UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  plan_id             UUID REFERENCES centre_plans(id) ON DELETE SET NULL,
  plan_name           VARCHAR(120) NOT NULL,
  duration            VARCHAR(12) NOT NULL,
  starts_on           DATE NOT NULL,
  ends_on             DATE NOT NULL,
  price_paise         INT NOT NULL,
  discount_pct        INT NOT NULL DEFAULT 0,
  amount_paise        INT NOT NULL CHECK (amount_paise >= 0),
  commission_pct      NUMERIC(5, 2) NOT NULL,
  commission_paise    INT NOT NULL,
  max_visits_per_day  INT,
  max_visits_per_week INT,
  inclusions          TEXT[] NOT NULL DEFAULT '{}',
  status              VARCHAR(10) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cancelled')),
  payment_ref         VARCHAR(120),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (ends_on >= starts_on)
);
CREATE INDEX IF NOT EXISTS direct_memberships_user_idx ON direct_memberships (user_id, venue_id, ends_on DESC);
CREATE INDEX IF NOT EXISTS direct_memberships_venue_idx ON direct_memberships (venue_id, created_at DESC);

-- Hourly slot bookings at a centre. paid_via says how the visit was paid (shown to partners, BRD §3.2).
CREATE TABLE IF NOT EXISTS slot_bookings (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  venue_id        UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  slot_date       DATE NOT NULL,
  slot_start      TIME NOT NULL,
  slot_end        TIME NOT NULL,
  status          VARCHAR(10) NOT NULL DEFAULT 'booked' CHECK (status IN ('booked', 'attended', 'cancelled')),
  paid_via        VARCHAR(12) CHECK (paid_via IN ('coins', 'session', 'membership', 'legacy')),
  cost_amount     INT NOT NULL DEFAULT 0,          -- coins or sessions taken (0 for membership / legacy)
  cost_label      VARCHAR(80),
  membership_id   UUID REFERENCES direct_memberships(id) ON DELETE SET NULL,
  subscription_id UUID REFERENCES subscriptions(id) ON DELETE SET NULL,
  refunded        BOOLEAN NOT NULL DEFAULT false,
  attended_at     TIMESTAMPTZ,
  cancelled_at    TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS slot_bookings_slot_idx ON slot_bookings (venue_id, slot_date, slot_start) WHERE status <> 'cancelled';
CREATE INDEX IF NOT EXISTS slot_bookings_user_idx ON slot_bookings (user_id, slot_date DESC);
-- One live booking per member per centre per day (check-in is once per day).
CREATE UNIQUE INDEX IF NOT EXISTS slot_bookings_one_per_day ON slot_bookings (user_id, venue_id, slot_date) WHERE status <> 'cancelled';

-- How each check-in was paid / admitted.
ALTER TABLE checkins ADD COLUMN IF NOT EXISTS paid_via VARCHAR(12);
ALTER TABLE checkins ADD COLUMN IF NOT EXISTS booking_id UUID REFERENCES slot_bookings(id) ON DELETE SET NULL;
ALTER TABLE checkins ADD COLUMN IF NOT EXISTS membership_id UUID REFERENCES direct_memberships(id) ON DELETE SET NULL;
ALTER TABLE checkins ADD COLUMN IF NOT EXISTS cost_label VARCHAR(80);
ALTER TABLE checkins DROP CONSTRAINT IF EXISTS checkins_paid_via_chk;
ALTER TABLE checkins ADD CONSTRAINT checkins_paid_via_chk
  CHECK (paid_via IS NULL OR paid_via IN ('coins', 'session', 'membership', 'legacy', 'event'));
CREATE INDEX IF NOT EXISTS checkins_membership_idx ON checkins (membership_id) WHERE membership_id IS NOT NULL;

-- What FitKey owes the centre for each FitKey-pass visit (coins / session / legacy pass), at the agreed rate.
-- Direct-membership visits have no payout row: the centre already got the membership money.
CREATE TABLE IF NOT EXISTS visit_payouts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  checkin_id   UUID NOT NULL UNIQUE REFERENCES checkins(id) ON DELETE CASCADE,
  venue_id     UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  paid_via     VARCHAR(12) NOT NULL CHECK (paid_via IN ('coins', 'session', 'legacy')),
  amount_paise INT NOT NULL CHECK (amount_paise >= 0),
  visit_date   DATE NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS visit_payouts_venue_date_idx ON visit_payouts (venue_id, visit_date);

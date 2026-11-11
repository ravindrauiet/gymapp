-- Partner App BRD (Nov 2026): partner types, 10-step venue listing, FitKey-pass access hours, founding-partner
-- commission, documents / KYC / bank, agreement by OTP, status timeline, assisted listing, member register,
-- booking requests, payouts. Idempotent and additive: runs on every server start.
-- Contract: docs/partner_brd_contract.md. Other partner types (clinic / chemist / trainer / store) → 211_partner_types.sql.

-- ------------------------------------------------------------------------------------------------ partners (users)
ALTER TABLE users ADD COLUMN IF NOT EXISTS partner_type VARCHAR(20);
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_partner_type_chk;
ALTER TABLE users ADD CONSTRAINT users_partner_type_chk CHECK (partner_type IS NULL OR partner_type IN
  ('fitness_centre', 'sports_centre', 'trainer', 'clinic', 'chemist', 'store_seller'));
-- FitKey employee who can list partners on their behalf (Assisted Listing, BRD §8). Set by admin only.
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_fitkey_staff BOOLEAN NOT NULL DEFAULT false;
-- Founding-partner commission years are counted from this date (first listing to go live), BRD §5.3.
ALTER TABLE users ADD COLUMN IF NOT EXISTS partner_go_live_at TIMESTAMPTZ;

-- ------------------------------------------------------------------------------------------------ venues
ALTER TABLE venues ADD COLUMN IF NOT EXISTS sports TEXT[] NOT NULL DEFAULT '{}';      -- badminton, table_tennis, …
ALTER TABLE venues ADD COLUMN IF NOT EXISTS video_url TEXT;                            -- optional video tour
ALTER TABLE venues ADD COLUMN IF NOT EXISTS fitkey_pass_mode VARCHAR(10) NOT NULL DEFAULT 'all';
ALTER TABLE venues DROP CONSTRAINT IF EXISTS venues_fitkey_pass_mode_chk;
ALTER TABLE venues ADD CONSTRAINT venues_fitkey_pass_mode_chk CHECK (fitkey_pass_mode IN ('all', 'blocked'));
ALTER TABLE venues ADD COLUMN IF NOT EXISTS pass_accepted BOOLEAN NOT NULL DEFAULT false;  -- step 7 consent box
ALTER TABLE venues ADD COLUMN IF NOT EXISTS pass_consent_at TIMESTAMPTZ;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS monthly_fee_paise INT CHECK (monthly_fee_paise IS NULL OR monthly_fee_paise > 0);
ALTER TABLE venues ADD COLUMN IF NOT EXISTS slot_minutes INT NOT NULL DEFAULT 60;
ALTER TABLE venues DROP CONSTRAINT IF EXISTS venues_slot_minutes_chk;
ALTER TABLE venues ADD CONSTRAINT venues_slot_minutes_chk CHECK (slot_minutes BETWEEN 15 AND 480);
ALTER TABLE venues ADD COLUMN IF NOT EXISTS pass_slot_cap INT CHECK (pass_slot_cap IS NULL OR pass_slot_cap >= 0);
ALTER TABLE venues ADD COLUMN IF NOT EXISTS courts INT NOT NULL DEFAULT 1;            -- courts / lanes per slot (sports)
ALTER TABLE venues ADD COLUMN IF NOT EXISTS auto_accept_bookings BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS listing_step INT NOT NULL DEFAULT 1;      -- furthest step reached (1–10)
ALTER TABLE venues ADD COLUMN IF NOT EXISTS listed_by UUID REFERENCES users(id) ON DELETE SET NULL; -- staff (assisted)
ALTER TABLE venues ADD COLUMN IF NOT EXISTS partner_accepted_at TIMESTAMPTZ;           -- owner's agreement OTP
ALTER TABLE venues ADD COLUMN IF NOT EXISTS admin_approved_at TIMESTAMPTZ;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS submitted_at TIMESTAMPTZ;
ALTER TABLE venues ADD COLUMN IF NOT EXISTS go_live_at TIMESTAMPTZ;
-- Status gains 'changes_needed' (with per-step fixes, see venue_status_events) and 'approved' (admin OK, waiting
-- for the owner's OTP acceptance on an assisted listing).
ALTER TABLE venues DROP CONSTRAINT IF EXISTS venues_status_check;
ALTER TABLE venues ADD CONSTRAINT venues_status_check
  CHECK (status IN ('draft', 'submitted', 'under_review', 'changes_needed', 'approved', 'live', 'rejected'));
-- Photos: up to 10 (was 8 in the API schema only).

-- Opening hours per weekday; several rows per day = split shifts. kind 'ladies_only' marks ladies-only windows.
-- When a venue has no rows here, venues.opens_at / closes_at / open_days still apply (old listings).
CREATE TABLE IF NOT EXISTS venue_hours (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id  UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  weekday   VARCHAR(3) NOT NULL CHECK (weekday IN ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')),
  opens_at  TIME NOT NULL,
  closes_at TIME NOT NULL,
  kind      VARCHAR(12) NOT NULL DEFAULT 'open' CHECK (kind IN ('open', 'ladies_only')),
  CHECK (closes_at > opens_at)
);
CREATE INDEX IF NOT EXISTS venue_hours_venue_idx ON venue_hours (venue_id, weekday);

-- Windows when FitKey-pass users are NOT allowed (BRD §4). Venue's own-pass members are unaffected.
CREATE TABLE IF NOT EXISTS venue_pass_blocks (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id   UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  days       TEXT[] NOT NULL DEFAULT '{mon,tue,wed,thu,fri,sat,sun}',
  starts_at  TIME NOT NULL,
  ends_at    TIME NOT NULL,
  note       VARCHAR(120),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at)
);
CREATE INDEX IF NOT EXISTS venue_pass_blocks_venue_idx ON venue_pass_blocks (venue_id);

-- Holidays / closed dates, and blocked slots on a date (slot_start NULL = whole day closed).
CREATE TABLE IF NOT EXISTS venue_closures (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id   UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  closed_on  DATE NOT NULL,
  slot_start TIME,
  slot_end   TIME,
  note       VARCHAR(160),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((slot_start IS NULL AND slot_end IS NULL) OR (slot_start IS NOT NULL AND slot_end > slot_start))
);
CREATE INDEX IF NOT EXISTS venue_closures_venue_idx ON venue_closures (venue_id, closed_on);

-- Status timeline (BRD §6.4): Submitted → Under review → Changes needed (fixes) → Approved → Live.
-- fixes = [{ "step": 7, "message": "Add a monthly price" }, …] (only for changes_needed).
CREATE TABLE IF NOT EXISTS listing_status_events (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type VARCHAR(12) NOT NULL CHECK (entity_type IN ('venue', 'trainer', 'clinic', 'chemist', 'store')),
  entity_id   UUID NOT NULL,
  status      VARCHAR(16) NOT NULL,
  note        VARCHAR(1000),
  fixes       JSONB NOT NULL DEFAULT '[]'::jsonb,
  actor_id    UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS listing_status_events_entity_idx ON listing_status_events (entity_type, entity_id, created_at);

-- ------------------------------------------------------------------------------------------------ plans (step 7)
-- Venue's own plans: add hourly, weekly, yearly (BRD §5.1). 'annual' kept for old rows.
ALTER TABLE centre_plans DROP CONSTRAINT IF EXISTS centre_plans_duration_check;
ALTER TABLE centre_plans ADD CONSTRAINT centre_plans_duration_check
  CHECK (duration IN ('hourly', 'day', 'weekly', 'monthly', 'quarterly', 'annual', 'yearly'));
ALTER TABLE centre_plans ADD COLUMN IF NOT EXISTS slot_limit_note VARCHAR(160);
-- GST (5% inclusive) on direct purchases is deducted from the partner payout: price × 5/105 (Case 1).
ALTER TABLE direct_memberships ADD COLUMN IF NOT EXISTS gst_paise INT NOT NULL DEFAULT 0;
ALTER TABLE direct_memberships ADD COLUMN IF NOT EXISTS partner_net_paise INT;

-- FitKey-pass visit payout: monthly fee ÷ 30 minus that year's commission (Case 2, no GST deducted).
ALTER TABLE visit_payouts ADD COLUMN IF NOT EXISTS gross_paise INT;
ALTER TABLE visit_payouts ADD COLUMN IF NOT EXISTS commission_pct NUMERIC(5, 2);
ALTER TABLE visit_payouts ADD COLUMN IF NOT EXISTS commission_paise INT NOT NULL DEFAULT 0;

-- Booking requests (BRD §10.1): when auto-accept is off, new bookings start as 'requested'.
ALTER TABLE slot_bookings DROP CONSTRAINT IF EXISTS slot_bookings_status_check;
ALTER TABLE slot_bookings ADD CONSTRAINT slot_bookings_status_check
  CHECK (status IN ('requested', 'booked', 'attended', 'cancelled', 'rejected'));
ALTER TABLE slot_bookings ADD COLUMN IF NOT EXISTS decided_at TIMESTAMPTZ;
ALTER TABLE slot_bookings ADD COLUMN IF NOT EXISTS reject_reason VARCHAR(200);
ALTER TABLE slot_bookings ADD COLUMN IF NOT EXISTS court_no INT;

-- ------------------------------------------------------------------------------------------------ KYC / docs / bank
-- Owner KYC: only the masked Aadhaar is stored (XXXX-XXXX-1234) — never the full number or the card image.
CREATE TABLE IF NOT EXISTS partner_kyc (
  owner_id       UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  method         VARCHAR(16) NOT NULL CHECK (method IN ('digilocker', 'offline_ekyc')),
  aadhaar_masked VARCHAR(16) NOT NULL CHECK (aadhaar_masked ~ '^XXXX-XXXX-[0-9]{4}$'),
  name_on_id     VARCHAR(160),
  status         VARCHAR(10) NOT NULL DEFAULT 'verified' CHECK (status IN ('pending', 'verified', 'rejected')),
  verified_at    TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Licences, GST, FSSAI, drug licence, certificates… for any listing type.
CREATE TABLE IF NOT EXISTS partner_documents (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  entity_type VARCHAR(12) NOT NULL CHECK (entity_type IN ('venue', 'trainer', 'clinic', 'chemist', 'store')),
  entity_id   UUID NOT NULL,
  doc_type    VARCHAR(24) NOT NULL CHECK (doc_type IN ('licence', 'gst', 'fssai', 'drug_licence',
                'clinic_registration', 'doctor_registration', 'certificate', 'achievement', 'trademark', 'other')),
  file_url    TEXT NOT NULL,
  doc_number  VARCHAR(60),
  expires_on  DATE,
  status      VARCHAR(10) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'verified', 'rejected')),
  review_note VARCHAR(500),
  reviewed_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS partner_documents_entity_idx ON partner_documents (entity_type, entity_id);
CREATE INDEX IF NOT EXISTS partner_documents_pending_idx ON partner_documents (created_at) WHERE status = 'pending';

-- Payout bank account, verified by penny-drop. Payouts go only to a verified account.
CREATE TABLE IF NOT EXISTS partner_bank_accounts (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  holder_name    VARCHAR(160) NOT NULL,
  account_number VARCHAR(34) NOT NULL,     -- never returned in full to the app (last 4 only)
  ifsc           VARCHAR(11) NOT NULL CHECK (ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  bank_name      VARCHAR(120),
  status         VARCHAR(10) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'verified', 'failed')),
  verified_name  VARCHAR(160),             -- name returned by the penny-drop
  verified_at    TIMESTAMPTZ,
  is_primary     BOOLEAN NOT NULL DEFAULT true,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS partner_bank_accounts_owner_idx ON partner_bank_accounts (owner_id) WHERE is_primary;

-- Partner agreement acceptance by OTP (commission plan, payout rule, terms), per listing.
CREATE TABLE IF NOT EXISTS partner_agreements (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  entity_type VARCHAR(12) NOT NULL,
  entity_id   UUID NOT NULL,
  version     VARCHAR(20) NOT NULL DEFAULT '2026-11',
  terms       JSONB NOT NULL DEFAULT '{}'::jsonb,  -- commission plan + payout rule snapshot shown to the partner
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (entity_type, entity_id, version)
);

-- ------------------------------------------------------------------------------------------------ Run: members
-- Member register (BRD §10.1). FitKey members are derived automatically (direct memberships / pass check-ins);
-- this table holds members the partner adds by hand (walk-in, Fitpass, other) and any FitKey rows they annotate.
CREATE TABLE IF NOT EXISTS partner_members (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id      UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  user_id       UUID REFERENCES users(id) ON DELETE SET NULL,
  name          VARCHAR(120) NOT NULL,
  phone         VARCHAR(16),
  joined_on     DATE NOT NULL,
  plan_label    VARCHAR(60) NOT NULL,          -- Monthly, Quarterly, …
  renewal_on    DATE,
  source        VARCHAR(16) NOT NULL CHECK (source IN ('self', 'fitkey_pass', 'fitkey_direct', 'fitpass', 'other')),
  price_paise   INT NOT NULL DEFAULT 0 CHECK (price_paise >= 0),
  remind_member BOOLEAN NOT NULL DEFAULT false, -- optional WhatsApp reminder to the member
  notes         VARCHAR(500),
  archived_at   TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS partner_members_venue_idx ON partner_members (venue_id, renewal_on) WHERE archived_at IS NULL;

-- Renewal alerts sent (7 days / 1 day before), so each goes out once.
CREATE TABLE IF NOT EXISTS partner_member_alerts (
  member_key VARCHAR(80) NOT NULL,   -- 'pm:<partner_members.id>' or 'dm:<direct_memberships.id>'
  kind       VARCHAR(4) NOT NULL CHECK (kind IN ('7d', '1d')),
  renewal_on DATE NOT NULL,
  sent_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (member_key, kind, renewal_on)
);

-- ------------------------------------------------------------------------------------------------ Earn: payouts
CREATE TABLE IF NOT EXISTS partner_payouts (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  period_start     DATE NOT NULL,
  period_end       DATE NOT NULL,
  gross_paise      INT NOT NULL DEFAULT 0,
  commission_paise INT NOT NULL DEFAULT 0,
  gst_paise        INT NOT NULL DEFAULT 0,
  net_paise        INT NOT NULL DEFAULT 0,
  status           VARCHAR(12) NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'processing', 'paid', 'failed', 'on_hold')),
  bank_account_id  UUID REFERENCES partner_bank_accounts(id) ON DELETE SET NULL,
  utr              VARCHAR(40),
  paid_at          TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (owner_id, period_start, period_end)
);

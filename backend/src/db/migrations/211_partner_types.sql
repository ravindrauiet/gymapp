-- Partner BRD §7: trainers, clinics, chemists and store sellers get the same listing lifecycle as venues
-- (profile → pricing → availability → documents → review → live). Idempotent and additive.
-- Every listable table gets the same lifecycle columns; venues use venues.status, these use listing_status.

-- ---------------------------------------------------------------------------------------------- clinics & chemists
ALTER TABLE health_clinics  ADD COLUMN IF NOT EXISTS owner_id UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE health_chemists ADD COLUMN IF NOT EXISTS owner_id UUID REFERENCES users(id) ON DELETE SET NULL;
CREATE UNIQUE INDEX IF NOT EXISTS health_clinics_owner_uidx  ON health_clinics (owner_id)  WHERE owner_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS health_chemists_owner_uidx ON health_chemists (owner_id) WHERE owner_id IS NOT NULL;

ALTER TABLE health_clinics ADD COLUMN IF NOT EXISTS speciality VARCHAR(80);
ALTER TABLE health_clinics ADD COLUMN IF NOT EXISTS area VARCHAR(120);
ALTER TABLE health_clinics ADD COLUMN IF NOT EXISTS photos TEXT[] NOT NULL DEFAULT '{}';
-- OPD hours: [{ "weekday": "mon", "opensAt": "10:00", "closesAt": "14:00" }, …]; appointment slot length.
ALTER TABLE health_clinics ADD COLUMN IF NOT EXISTS opd_hours JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE health_clinics ADD COLUMN IF NOT EXISTS slot_minutes INT NOT NULL DEFAULT 15;

ALTER TABLE health_chemists ADD COLUMN IF NOT EXISTS area VARCHAR(120);
ALTER TABLE health_chemists ADD COLUMN IF NOT EXISTS photos TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE health_chemists ADD COLUMN IF NOT EXISTS delivery_radius_km NUMERIC(5, 1);
ALTER TABLE health_chemists ADD COLUMN IF NOT EXISTS discount_pct INT NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 90);
ALTER TABLE health_chemists ADD COLUMN IF NOT EXISTS open_hours JSONB NOT NULL DEFAULT '[]'::jsonb;

-- ---------------------------------------------------------------------------------------------- trainers
-- trainers already: name, photo, specialisations, experience, price, mode, verification_status, partner_id …
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS subtypes TEXT[] NOT NULL DEFAULT '{}';
  -- physiotherapist, yoga_master, gym_trainer_gym, gym_trainer_home, sports_coach, boxing, karate, mma, dance, nutritionist
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS achievements TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS languages TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS service_area VARCHAR(160);
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS max_sessions_per_day INT CHECK (max_sessions_per_day IS NULL OR max_sessions_per_day > 0);
-- Packages: [{ "name": "10 sessions", "sessions": 10, "pricePaise": 900000 }, …]
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS packages JSONB NOT NULL DEFAULT '[]'::jsonb;
-- Weekly availability: [{ "weekday": "mon", "start": "06:00", "end": "09:00" }, …]
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS weekly_slots JSONB NOT NULL DEFAULT '[]'::jsonb;
-- "Verified" badge only after the FitKey team checks the certificates (BRD §7).
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS certificates_verified_at TIMESTAMPTZ;

-- ---------------------------------------------------------------------------------------------- store sellers
ALTER TABLE marketplace_vendors ADD COLUMN IF NOT EXISTS brand_name VARCHAR(160);
ALTER TABLE marketplace_vendors ADD COLUMN IF NOT EXISTS logo_url TEXT;
ALTER TABLE marketplace_vendors ADD COLUMN IF NOT EXISTS about VARCHAR(2000);
ALTER TABLE marketplace_vendors ADD COLUMN IF NOT EXISTS categories TEXT[] NOT NULL DEFAULT '{}';
  -- supplements, activewear, gym_gear, healthy_food, wellness, accessories
ALTER TABLE marketplace_vendors ADD COLUMN IF NOT EXISTS dispatch_days INT CHECK (dispatch_days IS NULL OR dispatch_days BETWEEN 0 AND 30);
-- Supplements and food products cannot go live without a verified FSSAI licence (BRD §7).
ALTER TABLE marketplace_vendors ADD COLUMN IF NOT EXISTS fssai_verified_at TIMESTAMPTZ;

-- ---------------------------------------------------------------------------------------------- shared lifecycle
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['trainers', 'health_clinics', 'health_chemists', 'marketplace_vendors'] LOOP
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS listing_status VARCHAR(16)', t);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS listing_step INT NOT NULL DEFAULT 1', t);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS listed_by UUID REFERENCES users(id) ON DELETE SET NULL', t);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS partner_accepted_at TIMESTAMPTZ', t);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS admin_approved_at TIMESTAMPTZ', t);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS submitted_at TIMESTAMPTZ', t);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS go_live_at TIMESTAMPTZ', t);
    EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS review_note TEXT', t);
    EXECUTE format('ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I', t, t || '_listing_status_chk');
    EXECUTE format($c$ALTER TABLE %I ADD CONSTRAINT %I CHECK (listing_status IS NULL OR listing_status IN
      ('draft', 'submitted', 'under_review', 'changes_needed', 'approved', 'live', 'rejected'))$c$, t, t || '_listing_status_chk');
  END LOOP;
END $$;

-- Rows that existed before this BRD (seeded clinics / chemists, admin-created trainers and vendors) stay visible:
-- NULL listing_status = legacy row, treated as live by the user app.

-- Events, org verification and the Trophy board (BRD §3.1 / §3.4). Additive & idempotent.

-- Work / college email OTPs used to verify org membership (one active code per user + email).
CREATE TABLE IF NOT EXISTS org_email_otps (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  org_id      UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
  email       VARCHAR(255) NOT NULL,
  code_hash   TEXT NOT NULL,
  attempts    INT NOT NULL DEFAULT 0,
  expires_at  TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS org_email_otps_user_idx ON org_email_otps (user_id, created_at DESC);

-- College ID photo uploads wait for an admin; keep the proof and who reviewed it.
ALTER TABLE org_memberships ADD COLUMN IF NOT EXISTS id_proof_url TEXT;
ALTER TABLE org_memberships ADD COLUMN IF NOT EXISTS requested_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE org_memberships ADD COLUMN IF NOT EXISTS reviewed_by UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE org_memberships ADD COLUMN IF NOT EXISTS review_note VARCHAR(300);
CREATE INDEX IF NOT EXISTS org_memberships_status_idx ON org_memberships (status, requested_at);

CREATE INDEX IF NOT EXISTS contests_window_idx ON contests (starts_on, ends_on);
CREATE INDEX IF NOT EXISTS contests_org_idx ON contests (org_id);
CREATE INDEX IF NOT EXISTS contest_participants_user_idx ON contest_participants (user_id);

-- Starter FitKey events (open to everyone). Only inserted when no event with the same title exists.
INSERT INTO contests (title, description, period, metric, starts_on, ends_on, reward, kind, format)
SELECT 'FitKey 50K Monthly Run',
       'Run 50 km this month — outdoors or on the treadmill. Log every run in the app; every kilometre counts towards the board.',
       'monthly', 'running_km',
       date_trunc('month', now() AT TIME ZONE 'Asia/Kolkata')::date,
       (date_trunc('month', now() AT TIME ZONE 'Asia/Kolkata') + interval '1 month - 1 day')::date,
       'Top 3 runners win a FitKey finisher kit', 'fitkey', 'virtual'
WHERE NOT EXISTS (SELECT 1 FROM contests WHERE title = 'FitKey 50K Monthly Run');

INSERT INTO contests (title, description, period, metric, starts_on, ends_on, reward, kind, format)
SELECT '30-Day Consistency Streak',
       'Check in at any FitKey venue on as many consecutive days as you can. Your longest streak in the 30 days is your score.',
       'custom', 'streak',
       (now() AT TIME ZONE 'Asia/Kolkata')::date,
       ((now() AT TIME ZONE 'Asia/Kolkata')::date + 29),
       'Everyone with a 21+ day streak gets a free week on their next plan', 'fitkey', 'virtual'
WHERE NOT EXISTS (SELECT 1 FROM contests WHERE title = '30-Day Consistency Streak');

INSERT INTO contests (title, description, period, metric, starts_on, ends_on, reward, kind, format, arena_exercise)
SELECT 'AI Push-up Showdown',
       'Do your best set of push-ups in the AI Arena. The camera counts only full-range reps — your best set this week is your score.',
       'weekly', 'arena_reps',
       date_trunc('week', now() AT TIME ZONE 'Asia/Kolkata')::date,
       (date_trunc('week', now() AT TIME ZONE 'Asia/Kolkata') + interval '6 days')::date,
       'Weekly champion featured on the FitKey board', 'fitkey', 'ai', 'pushups'
WHERE NOT EXISTS (SELECT 1 FROM contests WHERE title = 'AI Push-up Showdown');

-- Events (BRD §3.1): contests become Events — FitKey, Org (company / college) and Partner events,
-- in virtual, on-ground or AI-verified formats. Shared by the member app (/events) and the Corporate Dashboard.

ALTER TABLE contests ADD COLUMN IF NOT EXISTS kind VARCHAR(10) NOT NULL DEFAULT 'fitkey';
ALTER TABLE contests ADD COLUMN IF NOT EXISTS format VARCHAR(10) NOT NULL DEFAULT 'virtual';
ALTER TABLE contests ADD COLUMN IF NOT EXISTS org_id UUID REFERENCES orgs(id) ON DELETE CASCADE;
ALTER TABLE contests ADD COLUMN IF NOT EXISTS venue_id UUID REFERENCES venues(id) ON DELETE SET NULL;
ALTER TABLE contests ADD COLUMN IF NOT EXISTS members_only BOOLEAN NOT NULL DEFAULT false; -- partner events: venue members only
ALTER TABLE contests ADD COLUMN IF NOT EXISTS arena_exercise VARCHAR(20);                   -- AI-verified events, e.g. 'pushups'
ALTER TABLE contests ADD COLUMN IF NOT EXISTS event_date DATE;                              -- on-ground event day
ALTER TABLE contests ADD COLUMN IF NOT EXISTS cover_url TEXT;
ALTER TABLE contests ADD COLUMN IF NOT EXISTS sponsor VARCHAR(120);
ALTER TABLE contests ADD COLUMN IF NOT EXISTS registration_fee_paise INT NOT NULL DEFAULT 0;
ALTER TABLE contests ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE contests DROP CONSTRAINT IF EXISTS contests_kind_check;
ALTER TABLE contests ADD CONSTRAINT contests_kind_check CHECK (kind IN ('fitkey', 'org', 'partner'));
ALTER TABLE contests DROP CONSTRAINT IF EXISTS contests_format_check;
ALTER TABLE contests ADD CONSTRAINT contests_format_check CHECK (format IN ('virtual', 'onground', 'ai'));
-- Events can run for any date range, not only a week or month.
ALTER TABLE contests DROP CONSTRAINT IF EXISTS contests_period_check;
ALTER TABLE contests ADD CONSTRAINT contests_period_check CHECK (period IN ('weekly', 'monthly', 'custom'));
-- attendance: on-ground check-ins on the event day; arena_reps: best AI-counted set of arena_exercise.
ALTER TABLE contests DROP CONSTRAINT IF EXISTS contests_metric_check;
ALTER TABLE contests ADD CONSTRAINT contests_metric_check
  CHECK (metric IN ('checkins', 'running_km', 'streak', 'attendance', 'arena_reps'));

-- Inter-org battles (e.g. Zomato vs Swiggy): every org listed here may join and is ranked as a team.
CREATE TABLE IF NOT EXISTS contest_orgs (
  contest_id UUID NOT NULL REFERENCES contests(id) ON DELETE CASCADE,
  org_id     UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
  PRIMARY KEY (contest_id, org_id)
);

-- Which org a participant represents, and on-ground attendance.
ALTER TABLE contest_participants ADD COLUMN IF NOT EXISTS org_id UUID REFERENCES orgs(id) ON DELETE SET NULL;
ALTER TABLE contest_participants ADD COLUMN IF NOT EXISTS attended_at TIMESTAMPTZ;

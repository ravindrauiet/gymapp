-- Circles (BRD §3.3): recurring local fitness groups in parks and societies — yoga, morning walk, laughter club.
-- Additive and idempotent: runs on every server start.

CREATE TABLE IF NOT EXISTS circles (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  leader_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name         VARCHAR(120) NOT NULL,
  activity     VARCHAR(20)  NOT NULL DEFAULT 'yoga',
  description  VARCHAR(600),
  place_name   VARCHAR(160) NOT NULL,           -- park / society, e.g. "Sector 12 Central Park"
  area         VARCHAR(120),
  city         VARCHAR(80)  NOT NULL,
  lat          DOUBLE PRECISION,
  lng          DOUBLE PRECISION,
  days         SMALLINT[]   NOT NULL,           -- ISO weekdays 1 = Mon … 7 = Sun
  start_time   TIME         NOT NULL,
  end_time     TIME         NOT NULL,
  invite_code  VARCHAR(12)  NOT NULL UNIQUE,
  qr_version   INT          NOT NULL DEFAULT 1, -- bump to invalidate printed posters
  status       VARCHAR(10)  NOT NULL DEFAULT 'active',
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);
ALTER TABLE circles DROP CONSTRAINT IF EXISTS circles_activity_check;
ALTER TABLE circles ADD CONSTRAINT circles_activity_check
  CHECK (activity IN ('yoga', 'walk', 'laughter', 'running', 'dance', 'meditation', 'exercise', 'cycling', 'other'));
ALTER TABLE circles DROP CONSTRAINT IF EXISTS circles_status_check;
ALTER TABLE circles ADD CONSTRAINT circles_status_check CHECK (status IN ('active', 'archived'));
CREATE INDEX IF NOT EXISTS circles_city_idx ON circles (lower(city));
CREATE INDEX IF NOT EXISTS circles_leader_idx ON circles (leader_id);

CREATE TABLE IF NOT EXISTS circle_members (
  circle_id  UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role       VARCHAR(10) NOT NULL DEFAULT 'member' CHECK (role IN ('leader', 'member')),
  joined_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (circle_id, user_id)
);
CREATE INDEX IF NOT EXISTS circle_members_user_idx ON circle_members (user_id);

-- Members without a smartphone; the leader marks their attendance.
CREATE TABLE IF NOT EXISTS circle_offline_members (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  circle_id  UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
  name       VARCHAR(80) NOT NULL,
  phone      VARCHAR(16),
  active     BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS circle_offline_members_circle_idx ON circle_offline_members (circle_id);

-- One row per person per session day. Exactly one of user_id / offline_member_id is set.
CREATE TABLE IF NOT EXISTS circle_attendance (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  circle_id          UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
  user_id            UUID REFERENCES users(id) ON DELETE CASCADE,
  offline_member_id  UUID REFERENCES circle_offline_members(id) ON DELETE CASCADE,
  session_date       DATE NOT NULL,
  method             VARCHAR(10) NOT NULL CHECK (method IN ('qr', 'gps', 'leader')),
  marked_by          UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((user_id IS NULL) <> (offline_member_id IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS circle_attendance_user_day_uq
  ON circle_attendance (circle_id, user_id, session_date) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS circle_attendance_offline_day_uq
  ON circle_attendance (circle_id, offline_member_id, session_date) WHERE offline_member_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS circle_attendance_circle_date_idx ON circle_attendance (circle_id, session_date);

-- Special sessions: Yoga Day, Diwali walk, health camps …
CREATE TABLE IF NOT EXISTS circle_specials (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  circle_id     UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
  title         VARCHAR(120) NOT NULL,
  kind          VARCHAR(12) NOT NULL DEFAULT 'special' CHECK (kind IN ('special', 'festival', 'yoga_day', 'health_camp')),
  session_date  DATE NOT NULL,
  start_time    TIME,
  end_time      TIME,
  note          VARCHAR(500),
  created_by    UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS circle_specials_circle_idx ON circle_specials (circle_id, session_date);

CREATE TABLE IF NOT EXISTS circle_special_rsvps (
  special_id  UUID NOT NULL REFERENCES circle_specials(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (special_id, user_id)
);

-- Circle chat: text and voice notes (audio_url → /api/v1/files/<id>).
CREATE TABLE IF NOT EXISTS circle_messages (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  circle_id      UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
  user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  body           VARCHAR(1000),
  audio_url      TEXT,
  audio_seconds  INT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (body IS NOT NULL OR audio_url IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS circle_messages_circle_idx ON circle_messages (circle_id, created_at);

-- Family link: a child follows a parent's circle streaks.
CREATE TABLE IF NOT EXISTS circle_family_codes (
  user_id     UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  code        VARCHAR(12) NOT NULL UNIQUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS circle_family_links (
  parent_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  child_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (parent_id, child_id),
  CHECK (parent_id <> child_id)
);
CREATE INDEX IF NOT EXISTS circle_family_links_child_idx ON circle_family_links (child_id);

-- "Missed 2 sessions in a row" alerts already sent, one per run of misses (run_start = first missed session).
CREATE TABLE IF NOT EXISTS circle_miss_alerts (
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  circle_id   UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
  run_start   DATE NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, circle_id, run_start)
);

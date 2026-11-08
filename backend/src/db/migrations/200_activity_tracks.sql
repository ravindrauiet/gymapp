-- Move tracker: recorded walks / runs / rides / travel with a GPS route. Idempotent and additive.
-- path is a simplified [[lat, lng], …] array (≈10 m tolerance) so the member's map can redraw it; members can delete tracks.
CREATE TABLE IF NOT EXISTS activity_tracks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  started_at   timestamptz NOT NULL,
  ended_at     timestamptz NOT NULL,
  mode         text NOT NULL DEFAULT 'walk' CHECK (mode IN ('walk', 'run', 'cycle', 'travel')),
  distance_m   integer NOT NULL DEFAULT 0 CHECK (distance_m >= 0),
  duration_s   integer NOT NULL DEFAULT 0 CHECK (duration_s >= 0),
  moving_s     integer NOT NULL DEFAULT 0 CHECK (moving_s >= 0),
  steps        integer NOT NULL DEFAULT 0 CHECK (steps >= 0),
  area_m2      double precision NOT NULL DEFAULT 0,
  max_speed_ms double precision,
  path         jsonb NOT NULL DEFAULT '[]'::jsonb,
  min_lat      double precision,
  min_lng      double precision,
  max_lat      double precision,
  max_lng      double precision,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS activity_tracks_user_idx ON activity_tracks (user_id, started_at DESC);

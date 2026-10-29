-- AI Arena (BRD §3.2): always-on, all-India exercise challenges. The member app counts reps on-device with
-- ML Kit pose detection; the server stores every attempt, ranks them and awards points.
-- Idempotent and additive: runs on every server start.

CREATE TABLE IF NOT EXISTS arena_exercises (
  id            TEXT PRIMARY KEY,                -- pushups | pullups | squats | plank | burpees
  name          VARCHAR(40)  NOT NULL,
  unit          VARCHAR(10)  NOT NULL CHECK (unit IN ('reps', 'seconds')),
  levels        INT[]        NOT NULL,           -- e.g. {25,50,100}; plank in seconds {30,60,120}
  level_points  INT[]        NOT NULL,           -- points for completing levels[i] (same length as levels)
  max_per_min   INT          NOT NULL,           -- anti-cheat: highest plausible reps (or seconds) per minute
  max_single    INT          NOT NULL,           -- anti-cheat: highest plausible single set
  tagline       VARCHAR(140),
  how_to        TEXT[]       NOT NULL DEFAULT '{}',
  tips          TEXT[]       NOT NULL DEFAULT '{}',
  sort          INT          NOT NULL DEFAULT 0
);

INSERT INTO arena_exercises (id, name, unit, levels, level_points, max_per_min, max_single, tagline, how_to, tips, sort) VALUES
  ('pushups', 'Pushups', 'reps', '{25,50,100}', '{10,25,60}', 80, 400,
   'The classic upper-body test. Chest to the floor, arms locked out at the top.',
   '{"Place the phone on the floor 1.5–2 m to your side so your whole body is visible.","Hands just wider than shoulders, body in one straight line from head to heels.","Lower until your elbows bend past 90°, then press up until your arms are straight."}',
   '{"Keep your hips level — sagging or piking breaks the count.","Half reps do not count: go low and lock out every rep.","Breathe in on the way down, out as you press."}', 1),
  ('pullups', 'Pullups', 'reps', '{10,20,40}', '{10,25,60}', 40, 120,
   'Pure pulling strength. Chin over the bar, full hang at the bottom.',
   '{"Prop the phone 2–3 m in front of the bar so your head, hands and hips are in frame.","Start from a dead hang with your arms fully straight.","Pull until your chin clears your hands, then lower all the way down."}',
   '{"No kipping — swinging makes tracking unreliable.","Straighten your arms fully between reps or the rep will not count.","A front-facing camera angle works best."}', 2),
  ('squats', 'Squats', 'reps', '{25,50,100}', '{10,25,60}', 80, 600,
   'Bodyweight squats to depth. The best all-round leg challenge.',
   '{"Stand side-on to the phone, 2–3 m away, so hips, knees and ankles are visible.","Feet shoulder-width apart, chest up.","Sit back until your thighs are at least parallel, then stand fully upright."}',
   '{"Depth matters — the counter waits until your knees bend past ~100°.","Stand all the way up between reps.","Keep your heels on the floor."}', 3),
  ('plank', 'Plank', 'seconds', '{30,60,120}', '{10,25,60}', 61, 1800,
   'Core endurance. Hold a straight line — the timer only runs while your form is good.',
   '{"Place the phone on the floor 1.5–2 m to your side.","Forearms on the floor, elbows under shoulders, legs straight.","Hold your body in one straight line from shoulders to ankles."}',
   '{"The timer pauses the moment your hips sag or pike.","Squeeze your glutes and brace your core.","Keep your neck neutral — look at the floor."}', 4),
  ('burpees', 'Burpees', 'reps', '{15,30,60}', '{10,25,60}', 35, 300,
   'Full-body conditioning. Floor to standing with a jump or reach overhead.',
   '{"Stand 2–3 m from the phone so your whole body fits in the frame, standing and on the floor.","Drop your hands to the floor and jump your feet back into a plank.","Jump your feet in and stand up tall with your hands overhead (or jump)."}',
   '{"Each rep needs the floor position AND a full stand with arms overhead.","Keep the whole body in frame — step back if the counter loses you.","Pace yourself: consistent reps beat a fast start."}', 5)
ON CONFLICT (id) DO NOTHING;

-- One row per set. reps = seconds held for plank.
CREATE TABLE IF NOT EXISTS arena_attempts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  exercise_id  TEXT NOT NULL,
  level        INT,
  reps         INT NOT NULL,
  completed    BOOLEAN NOT NULL,
  points       INT NOT NULL DEFAULT 0,
  clip_url     TEXT,
  city         VARCHAR(80),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Another feature may have created a compatible stub first — make sure every column exists.
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS exercise_id TEXT;
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS level INT;
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS reps INT NOT NULL DEFAULT 0;
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS completed BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS points INT NOT NULL DEFAULT 0;
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS clip_url TEXT;
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS city VARCHAR(80);
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();
-- Arena-specific extras.
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS duration_sec INT;          -- active set time reported by the app
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS partial_reps INT NOT NULL DEFAULT 0; -- reps rejected for range/form
-- none: not needed · pending: top-10 set, clip upload expected · uploaded · unavailable: device could not record
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS clip_status VARCHAR(12) NOT NULL DEFAULT 'none';

ALTER TABLE arena_attempts DROP CONSTRAINT IF EXISTS arena_attempts_exercise_check;
ALTER TABLE arena_attempts ADD CONSTRAINT arena_attempts_exercise_check
  CHECK (exercise_id IN ('pushups', 'pullups', 'squats', 'plank', 'burpees'));
ALTER TABLE arena_attempts DROP CONSTRAINT IF EXISTS arena_attempts_clip_status_check;
ALTER TABLE arena_attempts ADD CONSTRAINT arena_attempts_clip_status_check
  CHECK (clip_status IN ('none', 'pending', 'uploaded', 'unavailable'));

CREATE INDEX IF NOT EXISTS arena_attempts_board_idx ON arena_attempts (exercise_id, reps DESC, created_at);
CREATE INDEX IF NOT EXISTS arena_attempts_user_idx ON arena_attempts (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS arena_attempts_week_idx ON arena_attempts (exercise_id, created_at);

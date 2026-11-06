-- ProveIt (BRD §1, formerly "AI Arena"). Internal ids stay arena_*; this adds Levels vs Unlimited, v1 scope,
-- badges and ProveIt coins. Idempotent and additive: runs on every server start.

-- Levels mode = a target (badge + points + coins on first completion); Unlimited = one continuous set, ranks India.
-- Existing sets were all "level" sets, so they keep counting for points/history but not for the All India Rank.
ALTER TABLE arena_attempts ADD COLUMN IF NOT EXISTS mode VARCHAR(10) NOT NULL DEFAULT 'levels';
ALTER TABLE arena_attempts DROP CONSTRAINT IF EXISTS arena_attempts_mode_check;
ALTER TABLE arena_attempts ADD CONSTRAINT arena_attempts_mode_check CHECK (mode IN ('levels', 'unlimited'));
CREATE INDEX IF NOT EXISTS arena_attempts_air_idx ON arena_attempts (exercise_id, mode, reps DESC, created_at);

-- v1 scope: pushups, squats, pullups, plank. Burpees are hidden (data kept). Set once; editable in SQL afterwards.
ALTER TABLE arena_exercises ADD COLUMN IF NOT EXISTS active BOOLEAN;
UPDATE arena_exercises SET active = (id <> 'burpees') WHERE active IS NULL;

-- ProveIt coins for completing level 1/2/3 the first time (per exercise per level). Set once, then editable.
ALTER TABLE arena_exercises ADD COLUMN IF NOT EXISTS level_coins INT[];
UPDATE arena_exercises SET level_coins = '{10,25,50}' WHERE level_coins IS NULL;

-- BRD levels: 25/50/100 reps (plank 30/60/120 s). Pullups were 10/20/40 — only changed while still at the old default.
UPDATE arena_exercises SET levels = '{25,50,100}' WHERE id = 'pullups' AND levels = '{10,20,40}';

-- Copy for the reworked plank timer and the pullup hang rules.
UPDATE arena_exercises SET
  tagline = 'Pure pulling strength. Only real hanging reps count — chin over the bar, full hang at the bottom.',
  how_to = '{"Stand the phone upright 2–3 m in front of the bar, so your hands, head, hips AND legs are all in view.","Hang from the bar with straight arms — feet off the floor.","Pull until your chin is over your hands, then lower all the way to straight arms."}',
  tips = '{"Standing and copying the arm movement counts 0 — your whole body must rise.","Straighten your arms fully between reps or the rep will not count.","No jumping or pushing off the floor — your legs must rise with you."}'
  WHERE id = 'pullups';
UPDATE arena_exercises SET
  tips = '{"The timer only runs while shoulders, hips and ankles are in one line.","It pauses when your hips sag or rise, or your knees touch the floor.","Leaving the plank (lying down, kneeling up) ends the hold."}'
  WHERE id = 'plank';

-- One badge per member per exercise per level, earned the first time that level is completed (Levels mode).
-- coins_status: credited | pending (wallet not available yet — retried automatically) | none (0 coins configured).
CREATE TABLE IF NOT EXISTS proveit_badges (
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  exercise_id   TEXT NOT NULL,
  level_no      INT  NOT NULL,           -- 1, 2, 3
  target        INT  NOT NULL,           -- reps / seconds of that level when it was earned
  attempt_id    UUID REFERENCES arena_attempts(id) ON DELETE SET NULL,
  coins         INT  NOT NULL DEFAULT 0,
  coins_status  VARCHAR(10) NOT NULL DEFAULT 'pending',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, exercise_id, level_no)
);
ALTER TABLE proveit_badges DROP CONSTRAINT IF EXISTS proveit_badges_coins_status_check;
ALTER TABLE proveit_badges ADD CONSTRAINT proveit_badges_coins_status_check
  CHECK (coins_status IN ('credited', 'pending', 'none'));
CREATE INDEX IF NOT EXISTS proveit_badges_pending_idx ON proveit_badges (user_id) WHERE coins_status = 'pending';

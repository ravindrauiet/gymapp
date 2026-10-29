-- Studio categories + search (BRD §5, §7).
-- A video has one primary group (group_key) and any number of video types (types[]); every type belongs to a group,
-- so "Gym: Chest" and "Body Part: Upper Body" can both apply to the same video. A video is listed in its primary
-- group AND in every group one of its types belongs to. The old `category` column stays for old clients.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS video_groups (
  key        VARCHAR(30) PRIMARY KEY,
  label      VARCHAR(60) NOT NULL,
  sort_order INT NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS video_types (
  key        VARCHAR(40) PRIMARY KEY,
  group_key  VARCHAR(30) NOT NULL REFERENCES video_groups(key) ON DELETE CASCADE,
  label      VARCHAR(80) NOT NULL,
  sort_order INT NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS video_types_group_idx ON video_types (group_key, sort_order);

INSERT INTO video_groups (key, label, sort_order) VALUES
  ('home', 'Home Workouts', 10),
  ('gym', 'Gym Workouts', 20),
  ('goal', 'Goal-based', 30),
  ('yoga_mind', 'Yoga & Mind', 40),
  ('dance_cardio', 'Dance & Cardio', 50),
  ('martial_arts', 'Martial Arts', 60),
  ('body_part', 'Body Part', 70),
  ('recovery', 'Recovery', 80),
  ('special', 'Special Audiences', 90),
  ('learn', 'Learn', 100)
ON CONFLICT (key) DO NOTHING;

INSERT INTO video_types (key, group_key, label, sort_order) VALUES
  ('home_no_equipment', 'home', 'No-equipment', 1),
  ('home_dumbbell', 'home', 'Dumbbell at home', 2),
  ('home_band', 'home', 'Resistance band', 3),
  ('home_quick10', 'home', '10-min quick workouts', 4),
  ('home_office', 'home', 'Office / Desk workout', 5),
  ('gym_ppl', 'gym', 'Push / Pull / Legs', 1),
  ('gym_chest', 'gym', 'Chest', 2),
  ('gym_back', 'gym', 'Back', 3),
  ('gym_shoulders', 'gym', 'Shoulders', 4),
  ('gym_arms', 'gym', 'Arms', 5),
  ('gym_legs', 'gym', 'Legs', 6),
  ('gym_machines', 'gym', 'Machine guides for beginners', 7),
  ('goal_weight_loss', 'goal', 'Weight Loss', 1),
  ('goal_belly_fat', 'goal', 'Belly Fat', 2),
  ('goal_muscle_gain', 'goal', 'Muscle Gain', 3),
  ('goal_stamina', 'goal', 'Stamina / Cardio', 4),
  ('goal_flexibility', 'goal', 'Flexibility', 5),
  ('goal_toning', 'goal', 'Toning', 6),
  ('yoga_general', 'yoga_mind', 'Yoga (beginner to advanced)', 1),
  ('yoga_power', 'yoga_mind', 'Power Yoga', 2),
  ('yoga_back_pain', 'yoga_mind', 'Yoga for back pain', 3),
  ('yoga_pranayama', 'yoga_mind', 'Pranayama', 4),
  ('yoga_meditation', 'yoga_mind', 'Meditation', 5),
  ('yoga_sleep', 'yoga_mind', 'Sleep / Relaxation', 6),
  ('dance_zumba', 'dance_cardio', 'Zumba', 1),
  ('dance_bollywood', 'dance_cardio', 'Bollywood Dance', 2),
  ('dance_aerobics', 'dance_cardio', 'Aerobics', 3),
  ('dance_hiit', 'dance_cardio', 'HIIT', 4),
  ('dance_kickboxing', 'dance_cardio', 'Kickboxing cardio', 5),
  ('ma_judo_karate', 'martial_arts', 'Judo / Karate', 1),
  ('ma_boxing', 'martial_arts', 'Boxing basics', 2),
  ('ma_mma', 'martial_arts', 'MMA drills', 3),
  ('ma_self_defence', 'martial_arts', 'Self-defence', 4),
  ('body_abs', 'body_part', 'Abs / Core', 1),
  ('body_glutes', 'body_part', 'Glutes', 2),
  ('body_upper', 'body_part', 'Upper Body', 3),
  ('body_lower', 'body_part', 'Lower Body', 4),
  ('body_full', 'body_part', 'Full Body', 5),
  ('rec_stretching', 'recovery', 'Stretching', 1),
  ('rec_mobility', 'recovery', 'Mobility', 2),
  ('rec_foam_rolling', 'recovery', 'Foam rolling', 3),
  ('rec_cooldown', 'recovery', 'Post-workout cool down', 4),
  ('rec_posture', 'recovery', 'Posture correction', 5),
  ('aud_women', 'special', 'Women''s fitness', 1),
  ('aud_prenatal', 'special', 'Prenatal / Postnatal', 2),
  ('aud_seniors', 'special', 'Seniors (chair yoga, light exercise)', 3),
  ('aud_kids', 'special', 'Kids', 4),
  ('learn_form', 'learn', 'Exercise form guides', 1),
  ('learn_nutrition', 'learn', 'Nutrition basics', 2),
  ('learn_recipes', 'learn', 'Healthy Indian recipes', 3)
ON CONFLICT (key) DO NOTHING;

ALTER TABLE videos ADD COLUMN IF NOT EXISTS group_key VARCHAR(30);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS types TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE videos ADD COLUMN IF NOT EXISTS equipment VARCHAR(10);
ALTER TABLE videos DROP CONSTRAINT IF EXISTS videos_equipment_check;
ALTER TABLE videos ADD CONSTRAINT videos_equipment_check CHECK (equipment IS NULL OR equipment IN ('none', 'dumbbells', 'gym'));

CREATE INDEX IF NOT EXISTS videos_group_idx ON videos (group_key);
CREATE INDEX IF NOT EXISTS videos_types_idx ON videos USING GIN (types);
CREATE INDEX IF NOT EXISTS videos_title_trgm_idx ON videos USING GIN (title gin_trgm_ops);
CREATE INDEX IF NOT EXISTS health_clinics_name_trgm_idx ON health_clinics USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS health_chemists_name_trgm_idx ON health_chemists USING GIN (name gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- Backfill — only rows that have never been tagged (group_key IS NULL), so it is idempotent and never overrides
-- tags set by the FITKEY team. First the seeded demo videos by exact title, then a keyword/category fallback.
-- ---------------------------------------------------------------------------
UPDATE videos v SET group_key = s.g, types = s.t, equipment = s.e
FROM (VALUES
  ('Full Body Strength — 30 min', 'gym', '{body_full,goal_muscle_gain,gym_machines}'::text[], 'gym'),
  ('Push Day Hypertrophy', 'gym', '{gym_ppl,gym_chest,gym_shoulders,goal_muscle_gain,body_upper}'::text[], 'gym'),
  ('Morning Sun Salutations', 'yoga_mind', '{yoga_general,goal_flexibility,home_no_equipment}'::text[], 'none'),
  ('Hip Mobility Flow', 'recovery', '{rec_mobility,rec_stretching,yoga_general,body_lower}'::text[], 'none'),
  ('Zumba Cardio Party', 'dance_cardio', '{dance_zumba,goal_weight_loss,goal_stamina}'::text[], 'none'),
  ('Boxing Basics: Stance & Jab', 'martial_arts', '{ma_boxing,ma_self_defence}'::text[], 'none'),
  ('Heavy Bag HIIT', 'martial_arts', '{ma_boxing,dance_hiit,goal_stamina}'::text[], 'gym'),
  ('Karate Kata for Beginners', 'martial_arts', '{ma_judo_karate}'::text[], 'none'),
  ('Judo Breakfalls (Ukemi)', 'martial_arts', '{ma_judo_karate,ma_self_defence}'::text[], 'none')
) AS s(title, g, t, e)
WHERE v.group_key IS NULL AND v.title = s.title;

UPDATE videos v SET
  group_key = CASE v.category
    WHEN 'yoga' THEN 'yoga_mind'
    WHEN 'dance' THEN 'dance_cardio'
    WHEN 'boxing' THEN 'martial_arts'
    WHEN 'martial_arts' THEN 'martial_arts'
    ELSE 'gym' END,
  types = COALESCE(NULLIF(ARRAY_REMOVE(ARRAY[
      CASE WHEN v.title ~* 'zumba' THEN 'dance_zumba' END,
      CASE WHEN v.title ~* 'bollywood' THEN 'dance_bollywood' END,
      CASE WHEN v.title ~* 'aerobic' THEN 'dance_aerobics' END,
      CASE WHEN v.title ~* 'hiit' THEN 'dance_hiit' END,
      CASE WHEN v.title ~* 'kickbox' THEN 'dance_kickboxing' END,
      CASE WHEN v.title ~* 'box' THEN 'ma_boxing' END,
      CASE WHEN v.title ~* 'judo|karate' THEN 'ma_judo_karate' END,
      CASE WHEN v.title ~* 'mma' THEN 'ma_mma' END,
      CASE WHEN v.title ~* 'self[- ]?defen' THEN 'ma_self_defence' END,
      CASE WHEN v.title ~* 'power yoga' THEN 'yoga_power' END,
      CASE WHEN v.title ~* 'pranayam|breath' THEN 'yoga_pranayama' END,
      CASE WHEN v.title ~* 'meditat' THEN 'yoga_meditation' END,
      CASE WHEN v.title ~* 'sleep|relax' THEN 'yoga_sleep' END,
      CASE WHEN v.title ~* 'push|pull|legs day|ppl' THEN 'gym_ppl' END,
      CASE WHEN v.title ~* 'chest' THEN 'gym_chest' END,
      CASE WHEN v.title ~* 'back' AND v.category = 'gym' THEN 'gym_back' END,
      CASE WHEN v.title ~* 'shoulder' THEN 'gym_shoulders' END,
      CASE WHEN v.title ~* 'arm|bicep|tricep' THEN 'gym_arms' END,
      CASE WHEN v.title ~* 'abs|core' THEN 'body_abs' END,
      CASE WHEN v.title ~* 'glute' THEN 'body_glutes' END,
      CASE WHEN v.title ~* 'full body' THEN 'body_full' END,
      CASE WHEN v.title ~* 'stretch' THEN 'rec_stretching' END,
      CASE WHEN v.title ~* 'mobility' THEN 'rec_mobility' END,
      CASE WHEN v.title ~* 'weight loss|fat burn' THEN 'goal_weight_loss' END,
      CASE WHEN v.title ~* 'belly' THEN 'goal_belly_fat' END,
      CASE WHEN v.title ~* 'muscle|hypertrophy|strength' THEN 'goal_muscle_gain' END
    ], NULL), '{}'),
    CASE v.category
      WHEN 'yoga' THEN '{yoga_general}'::text[]
      WHEN 'dance' THEN '{dance_aerobics}'::text[]
      WHEN 'boxing' THEN '{ma_boxing}'::text[]
      WHEN 'martial_arts' THEN '{ma_judo_karate}'::text[]
      ELSE '{}'::text[] END),
  equipment = COALESCE(v.equipment, CASE WHEN v.category = 'gym' THEN 'gym' ELSE 'none' END)
WHERE v.group_key IS NULL;

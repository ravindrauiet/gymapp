-- Progress revamp (BRD §4): goal-based report, workout/steps goals, editable nutrition targets,
-- daily water log, MET-estimated activity calories and Health Connect / HealthKit step sync.

-- Weekly workout-days and daily-steps goals (BRD §4: every metric is shown against a goal).
ALTER TABLE user_goals ADD COLUMN IF NOT EXISTS workout_days_per_week INT NOT NULL DEFAULT 4;
ALTER TABLE user_goals ADD COLUMN IF NOT EXISTS daily_steps_target INT NOT NULL DEFAULT 8000;
ALTER TABLE user_goals ADD COLUMN IF NOT EXISTS water_glasses_target INT NOT NULL DEFAULT 8;
ALTER TABLE user_goals DROP CONSTRAINT IF EXISTS user_goals_workout_days_check;
ALTER TABLE user_goals ADD CONSTRAINT user_goals_workout_days_check CHECK (workout_days_per_week BETWEEN 1 AND 7);
ALTER TABLE user_goals DROP CONSTRAINT IF EXISTS user_goals_steps_target_check;
ALTER TABLE user_goals ADD CONSTRAINT user_goals_steps_target_check CHECK (daily_steps_target BETWEEN 1000 AND 50000);
ALTER TABLE user_goals DROP CONSTRAINT IF EXISTS user_goals_water_target_check;
ALTER TABLE user_goals ADD CONSTRAINT user_goals_water_target_check CHECK (water_glasses_target BETWEEN 1 AND 30);

-- Member overrides of the auto-calculated (Mifflin-St Jeor) targets. NULL = use the calculated value.
-- daily_calorie_target / daily_protein_g / … keep holding the EFFECTIVE value (override ?? calculated),
-- so every existing reader (Fuel Log, AI coach) keeps working unchanged.
ALTER TABLE user_goals ADD COLUMN IF NOT EXISTS calorie_target_override INT;
ALTER TABLE user_goals ADD COLUMN IF NOT EXISTS protein_g_override INT;
ALTER TABLE user_goals ADD COLUMN IF NOT EXISTS carbs_g_override INT;
ALTER TABLE user_goals ADD COLUMN IF NOT EXISTS fat_g_override INT;

-- Daily water intake (glasses of ~250 ml).
CREATE TABLE IF NOT EXISTS water_logs (
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  log_date   DATE NOT NULL,
  glasses    INT NOT NULL DEFAULT 0 CHECK (glasses >= 0 AND glasses <= 40),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, log_date)
);

-- Activity calories: true when the server estimated them with the MET formula (member left calories empty).
ALTER TABLE activity_logs ADD COLUMN IF NOT EXISTS calories_estimated BOOLEAN NOT NULL DEFAULT false;

-- Steps: true when active calories were measured by the phone / wearable (Health Connect, HealthKit),
-- false when estimated from the step count. Measured burn overrides FITKEY's own estimates for that day.
ALTER TABLE step_logs ADD COLUMN IF NOT EXISTS calories_measured BOOLEAN NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS step_logs_user_date_idx ON step_logs (user_id, log_date);
CREATE INDEX IF NOT EXISTS weight_logs_user_date_idx ON weight_logs (user_id, logged_on DESC);

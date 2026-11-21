-- Admin dashboard: user activity + moderation. Idempotent and additive.
-- last_seen_at: updated (at most once a minute per user) by requireAuth on any API call → DAU / WAU / MAU.
-- is_suspended: admin can suspend an account; suspended accounts can't log in or call the API.
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_suspended BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS suspended_reason VARCHAR(300);
ALTER TABLE users ADD COLUMN IF NOT EXISTS suspended_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS users_last_seen_idx ON users (role, last_seen_at DESC);
CREATE INDEX IF NOT EXISTS users_created_idx ON users (role, created_at DESC);

-- Indexes for the per-user activity timeline and the global feed.
CREATE INDEX IF NOT EXISTS checkins_user_time_idx ON checkins (user_id, checked_in_at DESC);
CREATE INDEX IF NOT EXISTS checkins_time_idx ON checkins (checked_in_at DESC);
CREATE INDEX IF NOT EXISTS meal_logs_user_time_idx ON meal_logs (user_id, logged_at DESC);
CREATE INDEX IF NOT EXISTS meal_logs_time_idx ON meal_logs (logged_at DESC);
CREATE INDEX IF NOT EXISTS arena_attempts_user_time_idx ON arena_attempts (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS activity_logs_user_time_idx ON activity_logs (user_id, logged_at DESC);
CREATE INDEX IF NOT EXISTS subscriptions_created_idx ON subscriptions (created_at DESC);
CREATE INDEX IF NOT EXISTS fitkey_purchases_user_time_idx ON fitkey_purchases (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS marketplace_orders_created_idx ON marketplace_orders (created_at DESC);
CREATE INDEX IF NOT EXISTS step_logs_user_date_idx ON step_logs (user_id, log_date DESC);

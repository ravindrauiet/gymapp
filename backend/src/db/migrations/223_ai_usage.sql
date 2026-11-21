-- AI usage log (admin panel → AI usage): every OpenAI call with tokens, latency, outcome and estimated cost.
-- Only short redacted text previews are stored; images never. Idempotent and additive.
CREATE TABLE IF NOT EXISTS ai_usage_logs (
  id                BIGSERIAL PRIMARY KEY,
  user_id           UUID REFERENCES users(id) ON DELETE SET NULL,
  feature           VARCHAR(24) NOT NULL,      -- mansi_chat | topic_guard | meal_scan | label_scan | other
  model             VARCHAR(60) NOT NULL,
  prompt_tokens     INT NOT NULL DEFAULT 0,
  completion_tokens INT NOT NULL DEFAULT 0,
  total_tokens      INT NOT NULL DEFAULT 0,
  cost_usd          NUMERIC(12, 6),            -- NULL when the model's price is unknown
  cost_inr          NUMERIC(12, 4),
  latency_ms        INT,
  status            VARCHAR(12) NOT NULL DEFAULT 'ok' CHECK (status IN ('ok', 'error', 'declined')),
  http_status       INT,
  error             VARCHAR(300),
  input_preview     VARCHAR(300),
  output_preview    VARCHAR(400),
  has_image         BOOLEAN NOT NULL DEFAULT false,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ai_usage_logs_time_idx ON ai_usage_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS ai_usage_logs_user_idx ON ai_usage_logs (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ai_usage_logs_feature_idx ON ai_usage_logs (feature, created_at DESC);

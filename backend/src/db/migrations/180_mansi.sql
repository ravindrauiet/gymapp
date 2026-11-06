-- Ask Mansi topic guard (BRD §6). Idempotent and additive: runs on every server start.
--
-- Messages Mansi declined as off-topic, kept so the team can tune the allowed-topic list.
-- Deliberately anonymous: no user id, and the excerpt is redacted (phones, emails, names) and capped at 200 chars.
CREATE TABLE IF NOT EXISTS mansi_declines (
  id         bigserial PRIMARY KEY,
  category   text NOT NULL,                 -- coding | homework | news_politics | finance | general_knowledge | …
  verdict    text NOT NULL DEFAULT 'out_of_scope', -- out_of_scope | mixed (health part answered, rest declined)
  source     text NOT NULL DEFAULT 'classifier',   -- keyword | classifier | output_guard
  excerpt    text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mansi_declines_created_idx ON mansi_declines (created_at DESC);
CREATE INDEX IF NOT EXISTS mansi_declines_category_idx ON mansi_declines (category, created_at DESC);

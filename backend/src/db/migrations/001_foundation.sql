-- Shared foundations used by several features (FitFeed, Events, Circles, Wallet, Corporate Dashboard).

-- In-app notifications (likes, comments, follows, coins, events …)
CREATE TABLE IF NOT EXISTS notifications (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type        VARCHAR(40) NOT NULL,
  title       VARCHAR(160) NOT NULL,
  body        VARCHAR(500),
  data        JSONB NOT NULL DEFAULT '{}'::jsonb,
  read_at     TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notifications_user_idx ON notifications (user_id, created_at DESC);

-- Organisations (companies & colleges) for Org Events and the Corporate Dashboard.
CREATE TABLE IF NOT EXISTS orgs (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        VARCHAR(120) NOT NULL,
  kind        VARCHAR(12) NOT NULL DEFAULT 'company' CHECK (kind IN ('company', 'college')),
  logo_url    TEXT,
  invite_code VARCHAR(24) UNIQUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Email domains that prove membership of an org, e.g. zomato.com
CREATE TABLE IF NOT EXISTS org_domains (
  domain  VARCHAR(120) PRIMARY KEY,
  org_id  UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE
);

-- A verified member of an org (gives the profile badge, reused for future events of that org).
CREATE TABLE IF NOT EXISTS org_memberships (
  org_id       UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  work_email   VARCHAR(255),
  method       VARCHAR(12) NOT NULL DEFAULT 'email' CHECK (method IN ('email', 'invite_code', 'id_upload', 'hr_invite')),
  status       VARCHAR(12) NOT NULL DEFAULT 'verified' CHECK (status IN ('pending', 'verified', 'removed')),
  department   VARCHAR(80),
  verified_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, user_id)
);
CREATE INDEX IF NOT EXISTS org_memberships_user_idx ON org_memberships (user_id);

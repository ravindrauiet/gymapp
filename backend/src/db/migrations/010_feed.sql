-- FitFeed (BRD §1): photo posts, expert blogs and transformation journeys, with likes, comments, saves,
-- shares and follows. Separate from Community (buddy finder). Idempotent and additive.

-- Expert verification + a short public bio for the FitFeed profile.
ALTER TABLE users ADD COLUMN IF NOT EXISTS verified_nutritionist BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS verified_nutritionist_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS feed_bio VARCHAR(300);

CREATE TABLE IF NOT EXISTS feed_posts (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind           VARCHAR(10) NOT NULL,
  status         VARCHAR(10) NOT NULL DEFAULT 'published',
  visibility     VARCHAR(10) NOT NULL DEFAULT 'public',
  category       VARCHAR(20),
  caption        VARCHAR(2200),
  title          VARCHAR(160),
  cover_url      TEXT,
  body           TEXT,
  images         TEXT[] NOT NULL DEFAULT '{}',
  journey        JSONB,
  faces_blurred  BOOLEAN NOT NULL DEFAULT false,
  like_count     INT NOT NULL DEFAULT 0,
  comment_count  INT NOT NULL DEFAULT 0,
  save_count     INT NOT NULL DEFAULT 0,
  share_count    INT NOT NULL DEFAULT 0,
  published_at   TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE feed_posts DROP CONSTRAINT IF EXISTS feed_posts_kind_check;
ALTER TABLE feed_posts ADD CONSTRAINT feed_posts_kind_check CHECK (kind IN ('photo', 'blog', 'journey'));
ALTER TABLE feed_posts DROP CONSTRAINT IF EXISTS feed_posts_status_check;
ALTER TABLE feed_posts ADD CONSTRAINT feed_posts_status_check CHECK (status IN ('draft', 'published'));
ALTER TABLE feed_posts DROP CONSTRAINT IF EXISTS feed_posts_visibility_check;
ALTER TABLE feed_posts ADD CONSTRAINT feed_posts_visibility_check CHECK (visibility IN ('public', 'followers'));
ALTER TABLE feed_posts DROP CONSTRAINT IF EXISTS feed_posts_category_check;
ALTER TABLE feed_posts ADD CONSTRAINT feed_posts_category_check CHECK (
  category IS NULL OR category IN ('gym', 'yoga', 'nutrition', 'weight_loss', 'weight_gain', 'mental_wellness', 'sports'));
CREATE INDEX IF NOT EXISTS feed_posts_published_idx ON feed_posts (published_at DESC, id DESC) WHERE status = 'published';
CREATE INDEX IF NOT EXISTS feed_posts_user_idx ON feed_posts (user_id, created_at DESC);

-- Journey timeline: progress updates the author adds over time.
CREATE TABLE IF NOT EXISTS feed_journey_updates (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id     UUID NOT NULL REFERENCES feed_posts(id) ON DELETE CASCADE,
  note        VARCHAR(1000),
  photo_url   TEXT,
  weight_kg   NUMERIC(5, 1),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS feed_journey_updates_post_idx ON feed_journey_updates (post_id, created_at);

CREATE TABLE IF NOT EXISTS feed_likes (
  post_id    UUID NOT NULL REFERENCES feed_posts(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, user_id)
);

CREATE TABLE IF NOT EXISTS feed_saves (
  post_id    UUID NOT NULL REFERENCES feed_posts(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, user_id)
);
CREATE INDEX IF NOT EXISTS feed_saves_user_idx ON feed_saves (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS feed_comments (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id     UUID NOT NULL REFERENCES feed_posts(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  body        VARCHAR(1000) NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS feed_comments_post_idx ON feed_comments (post_id, created_at DESC);

CREATE TABLE IF NOT EXISTS feed_follows (
  follower_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  followee_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (follower_id, followee_id)
);
ALTER TABLE feed_follows DROP CONSTRAINT IF EXISTS feed_follows_self_check;
ALTER TABLE feed_follows ADD CONSTRAINT feed_follows_self_check CHECK (follower_id <> followee_id);
CREATE INDEX IF NOT EXISTS feed_follows_followee_idx ON feed_follows (followee_id, created_at DESC);

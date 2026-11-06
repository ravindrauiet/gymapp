-- Studio YouTube videos (BRD §7). Videos stay on YouTube and play through the official embedded player;
-- FITKEY stores only the id + metadata. Re-importing the owner's sheet upserts on youtube_id (no duplicates).

ALTER TABLE videos ADD COLUMN IF NOT EXISTS source VARCHAR(10) NOT NULL DEFAULT 'upload';
ALTER TABLE videos DROP CONSTRAINT IF EXISTS videos_source_check;
ALTER TABLE videos ADD CONSTRAINT videos_source_check CHECK (source IN ('upload', 'youtube'));

ALTER TABLE videos ADD COLUMN IF NOT EXISTS youtube_id VARCHAR(11);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS channel_name VARCHAR(200);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS channel_url TEXT;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS playlist_id VARCHAR(64);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS playlist_title VARCHAR(300);
-- "Studio Name" from the owner's sheet the video was imported under (for re-imports and the admin list).
ALTER TABLE videos ADD COLUMN IF NOT EXISTS sheet_name VARCHAR(160);
-- Where duration_seconds came from: api (YouTube Data API), page (public YouTube page), admin. NULL = unknown.
ALTER TABLE videos ADD COLUMN IF NOT EXISTS duration_source VARCHAR(10);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS imported_at TIMESTAMPTZ;

CREATE UNIQUE INDEX IF NOT EXISTS videos_youtube_id_uidx ON videos (youtube_id) WHERE youtube_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS videos_source_idx ON videos (source);

-- Videos added through the admin form with a YouTube link before this migration: tag them as YouTube
-- (oldest row per id only, so the unique index can never be violated).
UPDATE videos v SET
  youtube_id = s.yid,
  source = 'youtube'
FROM (
  SELECT DISTINCT ON (yid) id, yid FROM (
    SELECT id, created_at,
           substring(video_url FROM '(?:youtu\.be/|[?&]v=|/embed/|/shorts/|/live/)([A-Za-z0-9_-]{11})') AS yid
    FROM videos WHERE youtube_id IS NULL
  ) x
  WHERE yid IS NOT NULL
  ORDER BY yid, created_at
) s
WHERE v.id = s.id
  AND NOT EXISTS (SELECT 1 FROM videos o WHERE o.youtube_id = s.yid);

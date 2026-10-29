-- BRD §6 Trainer categories + BRD §8 Ratings for fitness centres and trainers.
-- Idempotent and additive: runs on every server start.

-- ---------------------------------------------------------------------------
-- Trainer types (keys from TRAINER_GROUPS in routes/trainers.js)
-- ---------------------------------------------------------------------------
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS trainer_types TEXT[] NOT NULL DEFAULT '{}';
CREATE INDEX IF NOT EXISTS trainers_types_idx ON trainers USING GIN (trainer_types);

-- Backfill trainers that have no types yet from their free-text specializations (and bio as a fallback).
WITH map(pattern, type_key) AS (
  VALUES
    ('%gym%', 'personal_trainer'), ('%personal train%', 'personal_trainer'),
    ('%weight loss%', 'weight_loss'), ('%fat loss%', 'weight_loss'),
    ('%bodybuild%', 'muscle_gain'), ('%muscle%', 'muscle_gain'), ('%physique%', 'muscle_gain'),
    ('%strength%', 'strength_conditioning'), ('%conditioning%', 'strength_conditioning'),
    ('%weightlift%', 'strength_conditioning'), ('%powerlift%', 'powerlifting'),
    ('%functional%', 'functional'), ('%crossfit%', 'crossfit'), ('%calisthenic%', 'calisthenics'),
    ('%yoga%', 'yoga'), ('%therapeutic yoga%', 'therapeutic_yoga'), ('%pranayam%', 'pranayama'),
    ('%breath%', 'pranayama'), ('%meditat%', 'meditation'), ('%mental%', 'mental_wellness'),
    ('%zumba%', 'zumba'), ('%bollywood%', 'bollywood_dance'), ('%aerobic%', 'aerobics'),
    ('%pilates%', 'pilates'), ('%hiit%', 'hiit'), ('%bootcamp%', 'hiit'), ('%spinning%', 'spinning'),
    ('%cycling%', 'spinning'), ('%kickbox%', 'kickboxing'),
    ('%boxing%', 'boxing'), ('%mma%', 'mma'), ('%judo%', 'judo_karate'), ('%karate%', 'judo_karate'),
    ('%taekwondo%', 'taekwondo'), ('%kalari%', 'kalaripayattu'), ('%self-defen%', 'self_defence_women'),
    ('%self defen%', 'self_defence_women'),
    ('%swim%', 'swimming'), ('%badminton%', 'badminton'), ('%tennis%', 'tennis'), ('%cricket%', 'cricket'),
    ('%football%', 'football'), ('%running%', 'running'), ('%marathon%', 'running'), ('%skating%', 'skating'),
    ('%physio%', 'physiotherapist'), ('%rehab%', 'sports_rehab'), ('%injury%', 'sports_rehab'),
    ('%posture%', 'posture_corrective'), ('%corrective%', 'posture_corrective'), ('%mobility%', 'mobility'),
    ('%stretch%', 'mobility'), ('%massage%', 'sports_massage'),
    ('%nutrition%', 'nutritionist'), ('%dietitian%', 'dietitian'), ('%sports nutrition%', 'sports_nutritionist'),
    ('%pcos%', 'clinical_diet'), ('%diabet%', 'clinical_diet'), ('%thyroid%', 'clinical_diet'),
    ('%prenatal%', 'prenatal_postnatal'), ('%postnatal%', 'prenatal_postnatal'), ('%senior%', 'senior_fitness'),
    ('%kids%', 'kids_teen'), ('%teen%', 'kids_teen'), ('%women%', 'womens_fitness')
),
derived AS (
  SELECT t.id, ARRAY_AGG(DISTINCT m.type_key ORDER BY m.type_key) AS types
  FROM trainers t
  JOIN LATERAL unnest(t.specializations) s(spec) ON true
  JOIN map m ON s.spec ILIKE m.pattern
  WHERE t.trainer_types = '{}'
  GROUP BY t.id
)
UPDATE trainers t SET trainer_types = d.types FROM derived d WHERE d.id = t.id AND t.trainer_types = '{}';

-- Anyone still untyped is a general personal trainer.
UPDATE trainers SET trainer_types = '{personal_trainer}' WHERE trainer_types = '{}';

-- ---------------------------------------------------------------------------
-- Ratings: one per user per centre / trainer, updatable. Stars 1–5, optional sub-ratings (1–5 each).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS venue_ratings (
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  venue_id    UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  stars       SMALLINT NOT NULL CHECK (stars BETWEEN 1 AND 5),
  sub_ratings JSONB NOT NULL DEFAULT '{}'::jsonb, -- cleanliness, equipment, staff, crowd, value
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, venue_id)
);
CREATE INDEX IF NOT EXISTS venue_ratings_venue_idx ON venue_ratings (venue_id);

CREATE TABLE IF NOT EXISTS trainer_ratings (
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  trainer_id  UUID NOT NULL REFERENCES trainers(id) ON DELETE CASCADE,
  stars       SMALLINT NOT NULL CHECK (stars BETWEEN 1 AND 5),
  sub_ratings JSONB NOT NULL DEFAULT '{}'::jsonb, -- knowledge, punctuality, communication, results
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, trainer_id)
);
CREATE INDEX IF NOT EXISTS trainer_ratings_trainer_idx ON trainer_ratings (trainer_id);

-- Denormalised aggregates for fast sort / filter / ranking. Recomputed on every rating write.
ALTER TABLE venues ADD COLUMN IF NOT EXISTS rating_avg NUMERIC(3, 2);
ALTER TABLE venues ADD COLUMN IF NOT EXISTS rating_count INT NOT NULL DEFAULT 0;
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS rating_avg NUMERIC(3, 2);
ALTER TABLE trainers ADD COLUMN IF NOT EXISTS rating_count INT NOT NULL DEFAULT 0;

-- Keep aggregates honest (cheap; also repairs drift). Legacy trainers.rating / review_count are seed values and unused.
UPDATE venues v SET rating_avg = r.avg, rating_count = r.n
FROM (SELECT venue_id, ROUND(AVG(stars)::numeric, 2) AS avg, COUNT(*)::int AS n FROM venue_ratings GROUP BY venue_id) r
WHERE r.venue_id = v.id AND (v.rating_avg IS DISTINCT FROM r.avg OR v.rating_count <> r.n);
UPDATE trainers t SET rating_avg = r.avg, rating_count = r.n
FROM (SELECT trainer_id, ROUND(AVG(stars)::numeric, 2) AS avg, COUNT(*)::int AS n FROM trainer_ratings GROUP BY trainer_id) r
WHERE r.trainer_id = t.id AND (t.rating_avg IS DISTINCT FROM r.avg OR t.rating_count <> r.n);

-- In-app rating prompts: one row per visit (check-in / trainer booking). "Not now" sets dismissed_at.
CREATE TABLE IF NOT EXISTS rating_prompts (
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_type  VARCHAR(10) NOT NULL CHECK (target_type IN ('venue', 'trainer')),
  target_id    UUID NOT NULL,
  source_id    UUID NOT NULL, -- checkins.id or trainer_bookings.id
  notified_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  dismissed_at TIMESTAMPTZ,
  PRIMARY KEY (user_id, target_type, source_id)
);
CREATE INDEX IF NOT EXISTS rating_prompts_target_idx ON rating_prompts (user_id, target_type, target_id);

-- Ops alerts for the FitKey team: every rating of ≤ 2 stars.
CREATE TABLE IF NOT EXISTS rating_alerts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  target_type     VARCHAR(10) NOT NULL CHECK (target_type IN ('venue', 'trainer')),
  target_id       UUID NOT NULL,
  user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  stars           SMALLINT NOT NULL,
  sub_ratings     JSONB NOT NULL DEFAULT '{}'::jsonb,
  status          VARCHAR(10) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
  resolution_note VARCHAR(500),
  resolved_by     UUID REFERENCES users(id) ON DELETE SET NULL,
  resolved_at     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS rating_alerts_status_idx ON rating_alerts (status, created_at DESC);

-- Targets whose ratings were all removed (e.g. user accounts deleted) go back to "New".
UPDATE venues v SET rating_avg = NULL, rating_count = 0
WHERE v.rating_count <> 0 AND NOT EXISTS (SELECT 1 FROM venue_ratings r WHERE r.venue_id = v.id);
UPDATE trainers t SET rating_avg = NULL, rating_count = 0
WHERE t.rating_count <> 0 AND NOT EXISTS (SELECT 1 FROM trainer_ratings r WHERE r.trainer_id = t.id);

-- BRD §5 — Fuel Log: Indian food database (INDB 2024, ICMR-NIN; 1,014 cooked dishes + 1,095 raw ingredients).
-- Rows are loaded by `npm run import-foods -- <file.xlsx|.csv> [--dry-run]` (src/db/importFoods.js), upserted by the
-- file's stable Food ID. This migration only creates the structure — it never inserts food data.
--
-- Rules carried from the data file's developer notes:
--  * food_id is the file's Food ID (unique, stable) — meal logs store it, never the name.
--  * NULL nutrient = "not available" in the source, NOT zero.
--  * Rows with a Data Note (e.g. a "serving" above 1,200 kcal = probably the whole recipe) start as
--    review_status 'pending' and are HIDDEN from member search until an admin approves (or fixes) them.
--  * Packaged foods are not in this file — barcode foods stay in food_items.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS food_db (
  food_id           TEXT PRIMARY KEY,
  name              TEXT NOT NULL,
  local_name        TEXT,
  category          TEXT NOT NULL,
  food_type         TEXT NOT NULL CHECK (food_type IN ('cooked', 'raw')),
  diet              TEXT CHECK (diet IN ('veg', 'egg', 'nonveg')),
  serving_unit      TEXT NOT NULL,
  serving_weight_g  NUMERIC(9, 2),
  -- per serving (as in the file)
  kcal              NUMERIC(9, 2),
  protein_g         NUMERIC(9, 2),
  carbs_g           NUMERIC(9, 2),
  fat_g             NUMERIC(9, 2),
  fibre_g           NUMERIC(9, 2),
  -- per 100 g
  kcal_100g         NUMERIC(9, 2),
  protein_100g      NUMERIC(9, 2),
  carbs_100g        NUMERIC(9, 2),
  fat_100g          NUMERIC(9, 2),
  fibre_100g        NUMERIC(9, 2),
  -- key vitamins / minerals, e.g. {"ironMg": 2.1, "vitaminCMg": 4} (keys carry the unit)
  micros_100g       JSONB NOT NULL DEFAULT '{}'::jsonb,
  micros_serving    JSONB NOT NULL DEFAULT '{}'::jsonb,
  -- every other column of the file (incl. the "All Nutrients" sheet), kept verbatim by header
  extra             JSONB NOT NULL DEFAULT '{}'::jsonb,
  serving_weight_computed BOOLEAN NOT NULL DEFAULT false, -- true = weight derived as kcal/serving ÷ kcal/100 g × 100
  data_note         TEXT,
  -- live = searchable; pending = has a Data Note, awaiting review (hidden); approved = reviewed, searchable;
  -- hidden = removed from search by an admin.
  review_status     TEXT NOT NULL DEFAULT 'live' CHECK (review_status IN ('live', 'pending', 'approved', 'hidden')),
  review_comment    TEXT,
  reviewed_by       UUID REFERENCES users(id) ON DELETE SET NULL,
  reviewed_at       TIMESTAMPTZ,
  -- admin "fix serving": overrides survive re-imports; per-serving values are then recomputed from per-100 g
  serving_unit_override     TEXT,
  serving_weight_override_g NUMERIC(9, 2),
  source            TEXT NOT NULL DEFAULT 'INDB 2024 (ICMR-NIN)',
  import_id         UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS food_db_name_trgm_idx ON food_db USING gin (lower(name) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS food_db_local_trgm_idx ON food_db USING gin (lower(local_name) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS food_db_category_idx ON food_db (food_type, category);
CREATE INDEX IF NOT EXISTS food_db_status_idx ON food_db (review_status);

-- One row per importer run (dry runs are not stored).
CREATE TABLE IF NOT EXISTS food_db_imports (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  file_name   TEXT NOT NULL,
  rows_total  INT NOT NULL DEFAULT 0,
  inserted    INT NOT NULL DEFAULT 0,
  updated     INT NOT NULL DEFAULT 0,
  skipped     INT NOT NULL DEFAULT 0,
  mapping     JSONB NOT NULL DEFAULT '{}'::jsonb,
  report      JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Meal logs: which database food + the quantity the member chose. Old rows keep food_id (food_items) / food_name.
ALTER TABLE meal_logs ADD COLUMN IF NOT EXISTS db_food_id TEXT REFERENCES food_db(food_id) ON DELETE SET NULL;
ALTER TABLE meal_logs ADD COLUMN IF NOT EXISTS quantity NUMERIC(9, 2);
ALTER TABLE meal_logs ADD COLUMN IF NOT EXISTS quantity_unit TEXT;
ALTER TABLE meal_logs DROP CONSTRAINT IF EXISTS meal_logs_quantity_unit_check;
ALTER TABLE meal_logs ADD CONSTRAINT meal_logs_quantity_unit_check CHECK (quantity_unit IS NULL OR quantity_unit IN ('serving', 'g'));
ALTER TABLE meal_logs ADD COLUMN IF NOT EXISTS grams NUMERIC(9, 2);
ALTER TABLE meal_logs ADD COLUMN IF NOT EXISTS fibre_g NUMERIC(9, 2);
-- Nutrients the source did not have for this food (e.g. {fibreG}). Their columns hold 0 (NOT NULL legacy columns),
-- so totals sum only the AVAILABLE values and the app shows "—" + "some values unavailable".
ALTER TABLE meal_logs ADD COLUMN IF NOT EXISTS unavailable TEXT[] NOT NULL DEFAULT '{}';
CREATE INDEX IF NOT EXISTS meal_logs_db_food_idx ON meal_logs (db_food_id) WHERE db_food_id IS NOT NULL;

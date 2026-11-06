import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, notFound, validate } from '../utils/http.js';
import { dateSchema } from '../utils/schemas.js';
import { effectiveTargets } from './goals.js';

const router = Router();

// ============================================================================
// 3.1 Module A: Food Encyclopedia (Nutrient Info Bank) - Public browsing
// ============================================================================

// ============================================================================
// Indian food database (BRD §5) — INDB 2024 (ICMR-NIN), imported by `npm run import-foods` into food_db.
// NULL nutrient = "not available" (never treated as 0 per food); Data-Note rows stay hidden until an admin approves.
// ============================================================================
export const FOOD_DB_CREDIT = 'Nutrition data: Indian Nutrient Databank (INDB) 2024, ICMR-NIN';
const VISIBLE = `review_status IN ('live', 'approved')`;
const MACRO_KEYS = ['calories', 'proteinG', 'carbsG', 'fatG', 'fibreG'];

/** True once at least one real database food is searchable — the old dummy list is then hidden. */
async function foodDbReady() {
  const r = await queryOne(`SELECT EXISTS (SELECT 1 FROM food_db WHERE ${VISIBLE}) AS ready`);
  return !!r?.ready;
}

const num = (v) => (v == null ? null : +v);
const r1 = (v) => (v == null ? null : Math.round(v * 10) / 10);

/** food_db row (camelCase) → API shape with EFFECTIVE serving (admin fix overrides the file's serving). */
export function shapeDbFood(f) {
  const overridden = f.servingWeightOverrideG != null;
  const weight = num(overridden ? f.servingWeightOverrideG : f.servingWeightG);
  const per100g = {
    calories: num(f.kcal100g),
    proteinG: num(f.protein100g),
    carbsG: num(f.carbs100g),
    fatG: num(f.fat100g),
    fibreG: num(f.fibre100g),
  };
  const file = { calories: num(f.kcal), proteinG: num(f.proteinG), carbsG: num(f.carbsG), fatG: num(f.fatG), fibreG: num(f.fibreG) };
  const scale = (v) => (v == null || weight == null ? null : (v * weight) / 100);
  const perServing = {};
  for (const k of MACRO_KEYS) perServing[k] = r1(overridden ? scale(per100g[k]) : (file[k] ?? scale(per100g[k])));
  if (perServing.calories != null) perServing.calories = Math.round(perServing.calories);
  const micros100g = f.micros100g ?? {};
  const microsServing = { ...(f.microsServing ?? {}) };
  for (const [k, v] of Object.entries(micros100g)) {
    if (overridden || microsServing[k] == null) {
      const s = scale(v);
      if (s != null) microsServing[k] = Math.round(s * 100) / 100;
    }
  }
  return {
    id: f.foodId,
    source: 'indb',
    name: f.name,
    localName: f.localName ?? null,
    category: f.category,
    type: f.foodType,
    diet: f.diet ?? null,
    servingUnit: f.servingUnitOverride ?? f.servingUnit,
    servingWeightG: weight,
    servingWeightComputed: !overridden && !!f.servingWeightComputed,
    perServing,
    per100g,
    micros100g,
    microsServing,
    dataNote: f.dataNote ?? null,
    reviewStatus: f.reviewStatus,
  };
}

/** food_items row (barcode / legacy) → the same API shape (per-serving only). */
function shapeItem(f) {
  return {
    id: f.id,
    source: f.barcode ? 'packaged' : 'legacy',
    barcode: f.barcode ?? null,
    name: f.name,
    localName: null,
    category: f.category,
    type: 'packaged',
    diet: null,
    servingUnit: f.servingUnit,
    servingWeightG: null,
    servingWeightComputed: false,
    perServing: { calories: num(f.calories), proteinG: num(f.proteinG), carbsG: num(f.carbsG), fatG: num(f.fatG), fibreG: num(f.fibreG) },
    per100g: null,
    micros100g: {},
    microsServing: { ironMg: num(f.ironMg), calciumMg: num(f.calciumMg), magnesiumMg: num(f.magnesiumMg), sodiumMg: num(f.sodiumMg) },
    dataNote: null,
    reviewStatus: 'live',
  };
}

/**
 * Nutrients for a chosen quantity: servings → per-serving × n; grams → per-100 g × g ÷ 100
 * (falls back to per-serving × g ÷ serving weight). Returns null values for nutrients that are not available.
 */
export function nutrientsFor(food, { unit, quantity }) {
  const out = {};
  let grams = null;
  if (unit === 'g') {
    grams = quantity;
    for (const k of MACRO_KEYS) {
      const p100 = food.per100g?.[k];
      const ps = food.perServing?.[k];
      out[k] = p100 != null ? (p100 * grams) / 100 : ps != null && food.servingWeightG ? (ps * grams) / food.servingWeightG : null;
    }
  } else {
    grams = food.servingWeightG ? food.servingWeightG * quantity : null;
    for (const k of MACRO_KEYS) out[k] = food.perServing?.[k] != null ? food.perServing[k] * quantity : null;
  }
  for (const k of MACRO_KEYS) out[k] = k === 'calories' ? (out[k] == null ? null : Math.round(out[k])) : r1(out[k]);
  return { ...out, grams: r1(grams), unavailable: MACRO_KEYS.filter((k) => out[k] == null) };
}

const escLike = (s) => s.replace(/[\\%_]/g, (c) => `\\${c}`);

/** GET /nutrition/food-db/status — is the Indian food database loaded? (+ credit line) */
router.get('/food-db/status', async (_req, res) => {
  const r = await queryOne(
    `SELECT COUNT(*) FILTER (WHERE ${VISIBLE}) AS searchable, COUNT(*) FILTER (WHERE food_type = 'cooked' AND ${VISIBLE}) AS cooked,
            COUNT(*) FILTER (WHERE food_type = 'raw' AND ${VISIBLE}) AS raw FROM food_db`,
  );
  res.json({ ready: r.searchable > 0, searchable: r.searchable, cooked: r.cooked, raw: r.raw, credit: FOOD_DB_CREDIT });
});

/** GET /nutrition/food-db/categories?diet= — chips: cooked-dish categories first, then raw ingredients. */
router.get('/food-db/categories', async (req, res) => {
  const { diet } = validate(z.object({ diet: z.enum(['veg', 'egg', 'nonveg']).optional() }), req.query);
  const rows = await query(
    `SELECT category AS name, food_type AS type, COUNT(*) AS count FROM food_db
      WHERE ${VISIBLE} AND ($1::text IS NULL OR diet = $1)
      GROUP BY category, food_type
      ORDER BY (food_type = 'cooked') DESC, COUNT(*) DESC, category`,
    [diet ?? null],
  );
  res.json({ categories: rows, credit: FOOD_DB_CREDIT });
});

const searchSchema = z.object({
  q: z.string().trim().max(80).optional(),
  category: z.string().trim().max(120).optional(),
  type: z.enum(['cooked', 'raw']).optional(),
  diet: z.enum(['veg', 'egg', 'nonveg']).optional(),
  limit: z.coerce.number().int().min(1).max(60).default(30),
  offset: z.coerce.number().int().min(0).max(5000).default(0),
});

/**
 * GET /nutrition/food-search?q=&category=&type=&diet=&limit=&offset=
 * Searches Food Name AND Local / Other Name (all words, any order) with pg_trgm typo tolerance.
 * Barcode-registered packaged foods are included in text searches. Before the database is imported the old
 * food_items list is returned instead, so the Fuel Log never goes empty.
 */
router.get('/food-search', async (req, res) => {
  const p = validate(searchSchema, req.query);
  const q = p.q ? p.q.toLowerCase() : null;
  const tokens = q ? q.split(/\s+/).filter(Boolean).map((t) => `%${escLike(t)}%`) : [];
  const ready = await foodDbReady();

  if (!ready) {
    const rows = await query(
      `SELECT * FROM food_items
        WHERE ($1::text IS NULL OR name ILIKE $2 OR similarity(lower(name), $1) > 0.3)
        ORDER BY name LIMIT $3 OFFSET $4`,
      [q, q ? `%${escLike(q)}%` : null, p.limit + 1, p.offset],
    );
    return res.json({ ready, foods: rows.slice(0, p.limit).map(shapeItem), hasMore: rows.length > p.limit, credit: null });
  }

  const hay = `lower(f.name || ' ' || coalesce(f.local_name, ''))`;
  const rows = await query(
    `SELECT f.*,
            CASE WHEN $1::text IS NULL THEN 0
                 ELSE GREATEST(word_similarity($1, lower(f.name)), word_similarity($1, lower(coalesce(f.local_name, '')))) END AS score,
            CASE WHEN $1::text IS NULL THEN 0
                 WHEN lower(f.name) = $1 OR lower(coalesce(f.local_name, '')) = $1 THEN 0
                 WHEN lower(f.name) LIKE $7 OR lower(coalesce(f.local_name, '')) LIKE $7 THEN 1
                 WHEN ${hay} LIKE ALL($2::text[]) THEN 2 ELSE 3 END AS rank
       FROM food_db f
      WHERE f.${VISIBLE}
        AND ($3::text IS NULL OR f.category = $3)
        AND ($4::text IS NULL OR f.food_type = $4)
        AND ($5::text IS NULL OR f.diet = $5)
        AND ($1::text IS NULL OR ${hay} LIKE ALL($2::text[])
             OR word_similarity($1, lower(f.name)) > 0.45 OR word_similarity($1, lower(coalesce(f.local_name, ''))) > 0.45)
      ORDER BY rank, score DESC, (f.food_type = 'cooked') DESC, length(f.name), f.name
      LIMIT $6 OFFSET $8`,
    [q, tokens, p.category ?? null, p.type ?? null, p.diet ?? null, p.limit + 1, q ? `${escLike(q)}%` : null, p.offset],
  );
  const foods = rows.slice(0, p.limit).map(shapeDbFood);

  // Packaged (barcode) foods: only for a plain text search, on the first page.
  if (q && !p.category && !p.type && !p.diet && p.offset === 0) {
    const packaged = await query(
      `SELECT * FROM food_items WHERE barcode IS NOT NULL
          AND (lower(name) LIKE ALL($1::text[]) OR word_similarity($2, lower(name)) > 0.5)
        ORDER BY word_similarity($2, lower(name)) DESC, name LIMIT 5`,
      [tokens, q],
    );
    foods.push(...packaged.map(shapeItem));
  }
  res.json({ ready, foods, hasMore: rows.length > p.limit, credit: FOOD_DB_CREDIT });
});

/** GET /nutrition/food-db/:foodId — one database food (visible ones only). */
router.get('/food-db/:foodId', async (req, res) => {
  const f = await queryOne(`SELECT * FROM food_db WHERE food_id = $1 AND ${VISIBLE}`, [req.params.foodId]);
  if (!f) throw notFound('Food not found');
  res.json({ food: shapeDbFood(f), credit: FOOD_DB_CREDIT });
});

// ---- Admin: review Data-Note rows, fix servings, hide, import stats (admin panel → Food DB tab) -----------------
router.use('/admin', requireAuth('admin'));

router.get('/admin/food-db/stats', async (_req, res) => {
  const [totals, byCategory, imports, legacy, usage] = await Promise.all([
    queryOne(
      `SELECT COUNT(*) AS total,
              COUNT(*) FILTER (WHERE food_type = 'cooked') AS cooked, COUNT(*) FILTER (WHERE food_type = 'raw') AS raw,
              COUNT(*) FILTER (WHERE review_status = 'live') AS live, COUNT(*) FILTER (WHERE review_status = 'pending') AS pending,
              COUNT(*) FILTER (WHERE review_status = 'approved') AS approved, COUNT(*) FILTER (WHERE review_status = 'hidden') AS hidden,
              COUNT(*) FILTER (WHERE data_note IS NOT NULL) AS with_note,
              COUNT(*) FILTER (WHERE diet = 'veg') AS veg, COUNT(*) FILTER (WHERE diet = 'egg') AS egg,
              COUNT(*) FILTER (WHERE diet = 'nonveg') AS nonveg, COUNT(*) FILTER (WHERE diet IS NULL) AS untagged,
              COUNT(*) FILTER (WHERE serving_weight_override_g IS NOT NULL) AS serving_fixed
         FROM food_db`,
    ),
    query(
      `SELECT category AS name, food_type AS type, COUNT(*) AS count,
              COUNT(*) FILTER (WHERE review_status IN ('live', 'approved')) AS searchable
         FROM food_db GROUP BY category, food_type ORDER BY (food_type = 'cooked') DESC, category`,
    ),
    query(`SELECT id, file_name, rows_total, inserted, updated, skipped, report, mapping, created_at FROM food_db_imports ORDER BY created_at DESC LIMIT 10`),
    queryOne(`SELECT COUNT(*) FILTER (WHERE barcode IS NULL) AS dummy, COUNT(*) FILTER (WHERE barcode IS NOT NULL) AS packaged FROM food_items`),
    queryOne(`SELECT COUNT(*) AS logs, COUNT(DISTINCT user_id) AS members FROM meal_logs WHERE db_food_id IS NOT NULL`),
  ]);
  const ready = totals.live + totals.approved > 0;
  res.json({
    totals,
    byCategory,
    imports,
    legacy: { ...legacy, dummyHiddenFromSearch: ready },
    usage,
    credit: FOOD_DB_CREDIT,
    importCommand: 'npm run import-foods -- <FitKey_Food_Database.xlsx> [--dry-run]',
  });
});

router.get('/admin/food-db/foods', async (req, res) => {
  const p = validate(
    z.object({
      status: z.enum(['pending', 'approved', 'hidden', 'live', 'noted', 'all']).default('pending'),
      q: z.string().trim().max(80).optional(),
      limit: z.coerce.number().int().min(1).max(100).default(50),
      offset: z.coerce.number().int().min(0).default(0),
    }),
    req.query,
  );
  const where = `($1::text = 'all' OR ($1::text = 'noted' AND data_note IS NOT NULL) OR review_status = $1::text)`;
  const rows = await query(
    `SELECT *, COUNT(*) OVER () AS total_count FROM food_db
      WHERE ${where} AND ($2::text IS NULL OR name ILIKE $3 OR local_name ILIKE $3 OR food_id ILIKE $3)
      ORDER BY COALESCE(kcal, 0) DESC, name LIMIT $4 OFFSET $5`,
    [p.status, p.q ?? null, p.q ? `%${escLike(p.q)}%` : null, p.limit, p.offset],
  );
  res.json({
    total: rows[0]?.totalCount ?? 0,
    foods: rows.map((r) => ({
      ...shapeDbFood(r),
      file: { servingUnit: r.servingUnit, servingWeightG: num(r.servingWeightG), kcal: num(r.kcal) },
      reviewComment: r.reviewComment,
      reviewedAt: r.reviewedAt,
    })),
  });
});

router.patch('/admin/food-db/foods/:foodId', async (req, res) => {
  const b = validate(
    z
      .object({
        action: z.enum(['approve', 'hide', 'unhide', 'pending']).optional(),
        servingUnit: z.string().trim().min(1).max(80).nullable().optional(),
        servingWeightG: z.number().positive().max(5000).nullable().optional(),
        comment: z.string().trim().max(500).optional(),
      })
      .refine((x) => x.action || x.servingUnit !== undefined || x.servingWeightG !== undefined, 'Nothing to change'),
    req.body,
  );
  const row = await queryOne(
    `UPDATE food_db SET
       review_status = CASE $2::text
         WHEN 'approve' THEN 'approved' WHEN 'hide' THEN 'hidden' WHEN 'pending' THEN 'pending'
         WHEN 'unhide' THEN CASE WHEN data_note IS NULL THEN 'live' ELSE 'pending' END
         ELSE review_status END,
       serving_unit_override = CASE WHEN $3::boolean THEN $4::text ELSE serving_unit_override END,
       serving_weight_override_g = CASE WHEN $5::boolean THEN $6::numeric ELSE serving_weight_override_g END,
       review_comment = COALESCE($7, review_comment),
       reviewed_by = $8, reviewed_at = now(), updated_at = now()
     WHERE food_id = $1 RETURNING *`,
    [
      req.params.foodId,
      b.action ?? null,
      b.servingUnit !== undefined,
      b.servingUnit ?? null,
      b.servingWeightG !== undefined,
      b.servingWeightG ?? null,
      b.comment ?? null,
      req.user.id,
    ],
  );
  if (!row) throw notFound('Food not found');
  res.json({ food: shapeDbFood(row) });
});

// ---- Legacy encyclopedia (food_items). Once the real database is imported, the old dummy rows
// (no barcode) are hidden; barcode-registered packaged foods stay. Existing meal logs are untouched.
router.get('/foods', async (req, res) => {
  const { q, category, limit = 50 } = req.query;
  const conditions = [];
  const params = [];
  if (await foodDbReady()) conditions.push('barcode IS NOT NULL');

  if (category && category !== 'all') {
    params.push(category);
    conditions.push(`category = $${params.length}`);
  }
  if (q && q.trim()) {
    params.push(`%${q.trim()}%`);
    conditions.push(`name ILIKE $${params.length}`);
  }

  const whereClause = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
  params.push(+limit);

  const foods = await query(
    `SELECT * FROM food_items ${whereClause} ORDER BY name ASC LIMIT $${params.length}`,
    params,
  );
  res.json({ foods });
});

router.get('/foods/:id', async (req, res) => {
  const food = await queryOne(`SELECT * FROM food_items WHERE id = $1`, [req.params.id]);
  if (!food) throw notFound('Food item not found');
  res.json({ food });
});

// Barcode Lookup for Food Scanner
const PACKAGED_BARCODES = {
  '8906067020012': {
    name: 'MuscleBlaze High Protein Dark Chocolate Muesli',
    servingUnit: '100g serving',
    calories: 382,
    proteinG: 25.0,
    carbsG: 52.0,
    fatG: 8.5,
    fibreG: 7.2,
    ironMg: 4.2,
    magnesiumMg: 120,
    calciumMg: 85,
    sodiumMg: 140,
    category: 'Cereals & Muesli',
    educationalNotes: 'Fortified with whey protein isolate and roasted almonds for sustained energy.',
  },
  '8901030890123': {
    name: 'Epigamia Natural Greek Yogurt',
    servingUnit: '1 cup (100g)',
    calories: 97,
    proteinG: 10.0,
    carbsG: 3.6,
    fatG: 5.0,
    fibreG: 0.0,
    ironMg: 0.1,
    magnesiumMg: 11,
    calciumMg: 120,
    sodiumMg: 35,
    category: 'Dairy',
    educationalNotes: 'Traditional Greek strained curd with zero preservatives and active gut cultures.',
  },
  '8908001150456': {
    name: 'Yoga Bar 20g High Protein Bar (Almond Fudge)',
    servingUnit: '1 bar (50g)',
    calories: 210,
    proteinG: 20.0,
    carbsG: 16.0,
    fatG: 7.0,
    fibreG: 8.0,
    ironMg: 1.8,
    magnesiumMg: 45,
    calciumMg: 75,
    sodiumMg: 110,
    category: 'Protein Bars',
    educationalNotes: 'Complete protein blend from whey and almonds with prebiotic dietary fibre.',
  },
  '8904223800010': {
    name: 'Amul High Protein Lassi (Rose/Plain)',
    servingUnit: '1 tetrapack (200ml)',
    calories: 128,
    proteinG: 15.0,
    carbsG: 14.0,
    fatG: 1.2,
    fibreG: 0.0,
    ironMg: 0.2,
    magnesiumMg: 18,
    calciumMg: 420,
    sodiumMg: 80,
    category: 'Dairy Beverages',
    educationalNotes: 'Ultra-filtered milk beverage providing 15g natural casein and whey protein.',
  },
  '0748927028669': {
    name: 'Optimum Nutrition Gold Standard 100% Whey',
    servingUnit: '1 scoop (30.4g)',
    calories: 120,
    proteinG: 24.0,
    carbsG: 3.0,
    fatG: 1.0,
    fibreG: 0.0,
    ironMg: 0.4,
    magnesiumMg: 24,
    calciumMg: 130,
    sodiumMg: 90,
    category: 'Supplements',
    educationalNotes: 'Microfiltered Whey Protein Isolate primary source with 5.5g branched chain amino acids.',
  },
  '8901725181234': {
    name: 'MyFitness Chocolate Peanut Butter Smooth',
    servingUnit: '2 tbsp (32g)',
    calories: 195,
    proteinG: 10.0,
    carbsG: 6.0,
    fatG: 15.0,
    fibreG: 2.2,
    ironMg: 0.9,
    magnesiumMg: 52,
    calciumMg: 22,
    sodiumMg: 4,
    category: 'Spreads & Healthy Fats',
    educationalNotes: 'Slow-roasted export grade peanuts enriched with Belgian dark chocolate paste.',
  },
  '8901058860012': {
    name: 'Nestle A+ Nourish Toned Milk',
    servingUnit: '1 glass (200ml)',
    calories: 116,
    proteinG: 6.4,
    carbsG: 9.6,
    fatG: 6.0,
    fibreG: 0.0,
    ironMg: 0.1,
    magnesiumMg: 22,
    calciumMg: 240,
    sodiumMg: 96,
    category: 'Dairy',
    educationalNotes: 'Pasteurized UHT milk maintaining high bone-density building calcium levels.',
  },
};

router.get('/barcode/:code', async (req, res) => {
  const code = req.params.code.trim();

  // 1. Look up in PostgreSQL database
  let food = await queryOne(`SELECT * FROM food_items WHERE barcode = $1`, [code]);
  if (food) {
    return res.json({ found: true, food, source: 'database' });
  }

  // 2. Check catalog and auto-insert into DB
  const catalogItem = PACKAGED_BARCODES[code];
  if (catalogItem) {
    food = await queryOne(
      `INSERT INTO food_items (
         barcode, name, serving_unit, calories, protein_g, carbs_g, fat_g,
         fibre_g, iron_mg, magnesium_mg, calcium_mg, sodium_mg, category, educational_notes
       ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
       RETURNING *`,
      [
        code,
        catalogItem.name,
        catalogItem.servingUnit,
        catalogItem.calories,
        catalogItem.proteinG,
        catalogItem.carbsG,
        catalogItem.fatG,
        catalogItem.fibreG,
        catalogItem.ironMg,
        catalogItem.magnesiumMg,
        catalogItem.calciumMg,
        catalogItem.sodiumMg,
        catalogItem.category,
        catalogItem.educationalNotes,
      ],
    );
    return res.json({ found: true, food, source: 'catalog' });
  }

  // 3. Not found - allow user to quick-register
  res.json({ found: false, barcode: code });
});

router.post('/barcode/register', async (req, res) => {
  const registerSchema = z.object({
    barcode: z.string().min(4),
    name: z.string().min(2),
    servingUnit: z.string().default('1 serving'),
    calories: z.number().int().min(0),
    proteinG: z.number().min(0).default(0),
    carbsG: z.number().min(0).default(0),
    fatG: z.number().min(0).default(0),
    category: z.string().default('Packaged Food'),
  });

  const body = validate(registerSchema, req.body);
  const food = await queryOne(
    `INSERT INTO food_items (barcode, name, serving_unit, calories, protein_g, carbs_g, fat_g, category)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
     RETURNING *`,
    [body.barcode, body.name, body.servingUnit, body.calories, body.proteinG, body.carbsG, body.fatG, body.category],
  );
  res.status(201).json({ food });
});

// ============================================================================
// 3.2 Module B: Daily Meal Tracker (Intake Logger) - Requires Member Auth
// ============================================================================
router.use('/meals', requireAuth('user'));

const mealLogSchema = z.object({
  mealType: z.enum(['breakfast', 'lunch', 'dinner', 'snacks']),
  foodId: z.string().uuid().optional(),
  foodName: z.string().min(2),
  servings: z.number().min(0.1).max(20).default(1.0),
  calories: z.number().int().min(0),
  proteinG: z.number().min(0).default(0),
  carbsG: z.number().min(0).default(0),
  fatG: z.number().min(0).default(0),
  loggedOn: dateSchema.optional(),
});

/** Logging a database food: the server computes nutrients from food_db (the client only sends id + quantity). */
const dbMealSchema = z
  .object({
    mealType: z.enum(['breakfast', 'lunch', 'dinner', 'snacks']),
    dbFoodId: z.string().trim().min(1).max(64),
    unit: z.enum(['serving', 'g']).default('serving'),
    quantity: z.number().positive().default(1),
    loggedOn: dateSchema.optional(),
  })
  .refine((b) => (b.unit === 'g' ? b.quantity >= 1 && b.quantity <= 3000 : b.quantity >= 0.25 && b.quantity <= 20), {
    message: 'Use 0.25–20 servings or 1–3000 g',
    path: ['quantity'],
  });

router.post('/meals', async (req, res) => {
  if (req.body?.dbFoodId != null) {
    const b = validate(dbMealSchema, req.body);
    const row = await queryOne(`SELECT * FROM food_db WHERE food_id = $1 AND ${VISIBLE}`, [b.dbFoodId]);
    if (!row) throw notFound('Food not found');
    const food = shapeDbFood(row);
    if (b.unit === 'g' && !food.per100g?.calories && !(food.perServing.calories != null && food.servingWeightG)) {
      throw badRequest('Grams are not available for this food — log it in servings');
    }
    const n = nutrientsFor(food, b);
    const servings =
      b.unit === 'serving' ? b.quantity : food.servingWeightG ? b.quantity / food.servingWeightG : b.quantity / 100;
    const meal = await queryOne(
      `INSERT INTO meal_logs (
         user_id, meal_type, db_food_id, food_name, servings, calories, protein_g, carbs_g, fat_g, fibre_g,
         quantity, quantity_unit, grams, unavailable, logged_on
       ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
                 COALESCE($15::date, (now() AT TIME ZONE $16)::date))
       RETURNING *`,
      [
        req.user.id,
        b.mealType,
        food.id,
        food.name.slice(0, 160),
        Math.min(99.99, Math.max(0.01, Math.round(servings * 100) / 100)),
        n.calories ?? 0,
        n.proteinG ?? 0,
        n.carbsG ?? 0,
        n.fatG ?? 0,
        n.fibreG,
        b.quantity,
        b.unit,
        n.grams,
        n.unavailable,
        b.loggedOn ?? null,
        config.tz,
      ],
    );
    return res.status(201).json({ meal: { ...meal, servingUnit: food.servingUnit } });
  }

  const data = validate(mealLogSchema, req.body);
  const entry = await queryOne(
    `INSERT INTO meal_logs (
       user_id, meal_type, food_id, food_name, servings, calories, protein_g, carbs_g, fat_g, logged_on
     ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, COALESCE($10::date, (now() AT TIME ZONE $11)::date))
     RETURNING *`,
    [
      req.user.id,
      data.mealType,
      data.foodId ?? null,
      data.foodName,
      data.servings,
      data.calories,
      data.proteinG,
      data.carbsG,
      data.fatG,
      data.loggedOn ?? null,
      config.tz,
    ],
  );
  res.status(201).json({ meal: entry });
});

/** Current hour (0-23) in the app time zone. */
function hourInTz() {
  return +new Intl.DateTimeFormat('en-GB', { hour: '2-digit', hourCycle: 'h23', timeZone: config.tz }).format(new Date());
}

router.get('/meals', async (req, res) => {
  const { date } = validate(z.object({ date: dateSchema.optional() }), req.query);

  const [meals, goal, day] = await Promise.all([
    query(
      `SELECT m.*, COALESCE(f.serving_unit_override, f.serving_unit) AS serving_unit
         FROM meal_logs m LEFT JOIN food_db f ON f.food_id = m.db_food_id
        WHERE m.user_id = $1 AND m.logged_on = COALESCE($2::date, (now() AT TIME ZONE $3)::date)
        ORDER BY m.logged_at ASC`,
      [req.user.id, date ?? null, config.tz],
    ),
    queryOne(`SELECT * FROM user_goals WHERE user_id = $1`, [req.user.id]),
    queryOne(
      `SELECT d::text AS date, d = (now() AT TIME ZONE $2)::date AS is_today,
              (SELECT glasses FROM water_logs WHERE user_id = $3 AND log_date = d) AS glasses
         FROM (SELECT COALESCE($1::date, (now() AT TIME ZONE $2)::date) AS d) x`,
      [date ?? null, config.tz, req.user.id],
    ),
  ]);

  // Group by meal category (rows come back camelCase from the db helper).
  const categories = { breakfast: [], lunch: [], dinner: [], snacks: [] };
  let totalCalories = 0;
  let totalProteinG = 0;
  let totalCarbsG = 0;
  let totalFatG = 0;
  // Nutrients the source did not have (NULL in the food database) are not counted — the app says
  // "some values unavailable" instead of pretending they were 0.
  const unavailable = { calories: 0, proteinG: 0, carbsG: 0, fatG: 0 };
  let unavailableItems = 0;
  for (const m of meals) {
    const miss = (m.unavailable ?? []).filter((k) => k in unavailable);
    if (miss.length) unavailableItems += 1;
    for (const k of miss) unavailable[k] += 1;
    categories[m.mealType]?.push(m);
    totalCalories += +m.calories || 0;
    totalProteinG += +m.proteinG || 0;
    totalCarbsG += +m.carbsG || 0;
    totalFatG += +m.fatG || 0;
  }

  // Targets: goal (auto Mifflin-St Jeor or member override) or defaults — never 0 / NaN.
  const t = effectiveTargets(goal);
  const targets = { calories: t.calories, proteinG: t.proteinG, carbsG: t.carbsG, fatG: t.fatG, source: t.source };

  const remCalories = Math.round(targets.calories - totalCalories);
  const remProtein = Math.round(targets.proteinG - totalProteinG);

  const nudges = [];
  if (day.isToday) {
    const hour = hourInTz();
    if (categories.breakfast.length === 0 && hour < 12) {
      nudges.push("Kickstart your metabolism: Don't forget to log your breakfast!");
    }
    if (categories.lunch.length === 0 && hour >= 14) {
      nudges.push("Lunch hasn't been logged yet. Keep your nutrition on track!");
    }
    if (categories.dinner.length === 0 && hour >= 20) {
      nudges.push("Log your dinner to complete today's intake diary.");
    }
  }
  if (meals.length > 0) {
    if (remProtein > 20) {
      nudges.push(`You still need ${remProtein}g more protein ${day.isToday ? 'today' : 'that day'} to hit your target.`);
    } else if (remProtein <= 0) {
      nudges.push("Great job! You've achieved your daily protein goal.");
    }
  }

  let calorieBalance = '';
  if (meals.length > 0) {
    calorieBalance =
      remCalories > 0 ? `${remCalories} kcal under target` : remCalories < 0 ? `${Math.abs(remCalories)} kcal over target` : 'Right on target';
  }

  res.json({
    date: day.date,
    isToday: day.isToday,
    summary: {
      totalCalories,
      totalProteinG: Math.round(totalProteinG * 10) / 10,
      totalCarbsG: Math.round(totalCarbsG * 10) / 10,
      totalFatG: Math.round(totalFatG * 10) / 10,
      targets,
      remainingCalories: remCalories,
      calorieBalance,
      unavailableItems,
      unavailable,
    },
    water: { glasses: day.glasses ?? 0, target: t.waterGlassesTarget },
    categories,
    nudges,
  });
});

router.delete('/meals/:id', async (req, res) => {
  const deleted = await queryOne(
    `DELETE FROM meal_logs WHERE id = $1 AND user_id = $2 RETURNING id`,
    [req.params.id, req.user.id],
  );
  if (!deleted) throw notFound('Meal log not found');
  res.status(204).end();
});

// ============================================================================
// Water intake (glasses per day) — shown in the Fuel Log and the Progress → Nutrition tab
// ============================================================================
router.use('/water', requireAuth('user'));

router.get('/water', async (req, res) => {
  const { date } = validate(z.object({ date: dateSchema.optional() }), req.query);
  const [row, goal] = await Promise.all([
    queryOne(
      `SELECT d::text AS date, (SELECT glasses FROM water_logs WHERE user_id = $1 AND log_date = d) AS glasses
         FROM (SELECT COALESCE($2::date, (now() AT TIME ZONE $3)::date) AS d) x`,
      [req.user.id, date ?? null, config.tz],
    ),
    queryOne(`SELECT water_glasses_target FROM user_goals WHERE user_id = $1`, [req.user.id]),
  ]);
  res.json({ water: { date: row.date, glasses: row.glasses ?? 0, target: goal?.waterGlassesTarget ?? 8 } });
});

/** POST /nutrition/water { delta: +1 | -1 } or { glasses: n }, optional date (not in the future). */
router.post('/water', async (req, res) => {
  const body = validate(
    z
      .object({
        delta: z.number().int().min(-10).max(10).optional(),
        glasses: z.number().int().min(0).max(40).optional(),
        date: dateSchema.optional(),
      })
      .refine((b) => (b.delta === undefined) !== (b.glasses === undefined), 'Send either delta or glasses'),
    req.body,
  );
  const day = await queryOne(
    `SELECT COALESCE($1::date, (now() AT TIME ZONE $2)::date) AS d, COALESCE($1::date, (now() AT TIME ZONE $2)::date) > (now() AT TIME ZONE $2)::date AS future`,
    [body.date ?? null, config.tz],
  );
  if (day.future) throw badRequest("You can't log water for a future day");
  const row = await queryOne(
    `INSERT INTO water_logs (user_id, log_date, glasses, updated_at)
     VALUES ($1, $2::date, LEAST(40, GREATEST(0, $3::int)), now())
     ON CONFLICT (user_id, log_date) DO UPDATE SET
       glasses = LEAST(40, GREATEST(0, CASE WHEN $4::boolean THEN water_logs.glasses + $3::int ELSE $3::int END)),
       updated_at = now()
     RETURNING log_date::text AS date, glasses`,
    [req.user.id, day.d, body.delta ?? body.glasses, body.delta !== undefined],
  );
  const goal = await queryOne(`SELECT water_glasses_target FROM user_goals WHERE user_id = $1`, [req.user.id]);
  res.status(201).json({ water: { ...row, target: goal?.waterGlassesTarget ?? 8 } });
});

export default router;

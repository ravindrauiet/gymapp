import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notFound, validate } from '../utils/http.js';
import { dateSchema } from '../utils/schemas.js';

const router = Router();

// ============================================================================
// 3.1 Module A: Food Encyclopedia (Nutrient Info Bank) - Public browsing
// ============================================================================

router.get('/foods', async (req, res) => {
  const { q, category, limit = 50 } = req.query;
  const conditions = [];
  const params = [];

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

router.post('/meals', async (req, res) => {
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

router.get('/meals', async (req, res) => {
  const { date } = req.query;
  const targetDateQuery = date ? '$2::date' : '(now() AT TIME ZONE $2)::date';
  const targetDateParam = date || config.tz;

  const [meals, goal] = await Promise.all([
    query(
      `SELECT * FROM meal_logs WHERE user_id = $1 AND logged_on = ${targetDateQuery} ORDER BY logged_at ASC`,
      [req.user.id, targetDateParam],
    ),
    queryOne(`SELECT * FROM user_goals WHERE user_id = $1`, [req.user.id]),
  ]);

  // Group by meal category
  const categories = {
    breakfast: [],
    lunch: [],
    dinner: [],
    snacks: [],
  };

  let totalCalories = 0;
  let totalProteinG = 0;
  let totalCarbsG = 0;
  let totalFatG = 0;

  for (const m of meals) {
    if (categories[m.meal_type]) {
      categories[m.meal_type].push(m);
    }
    totalCalories += m.calories;
    totalProteinG += +m.protein_g;
    totalCarbsG += +m.carbs_g;
    totalFatG += +m.fat_g;
  }

  // Target comparison
  const targets = {
    calories: goal ? goal.daily_calorie_target : 2000,
    proteinG: goal ? goal.daily_protein_g : 120,
    carbsG: goal ? goal.daily_carbs_g : 220,
    fatG: goal ? goal.daily_fat_g : 55,
  };

  // Push nudges
  const nudges = [];
  const remCalories = targets.calories - totalCalories;
  const remProtein = Math.round(targets.proteinG - totalProteinG);

  if (categories.breakfast.length === 0) {
    nudges.push('Kickstart your metabolism: Don\'t forget to log your breakfast!');
  }
  if (categories.lunch.length === 0 && new Date().getHours() >= 14) {
    nudges.push('Lunch hasn\'t been logged yet. Keep your nutrition on track!');
  }
  if (categories.dinner.length === 0 && new Date().getHours() >= 20) {
    nudges.push('Log your dinner to complete today\'s intake diary.');
  }
  if (remProtein > 20) {
    nudges.push(`You still need ${remProtein}g more protein today to hit your muscle target.`);
  } else if (remProtein <= 0) {
    nudges.push('Great job! You\'ve achieved your daily protein goal today.');
  }

  res.json({
    date: date || 'today',
    summary: {
      totalCalories,
      totalProteinG: Math.round(totalProteinG * 10) / 10,
      totalCarbsG: Math.round(totalCarbsG * 10) / 10,
      totalFatG: Math.round(totalFatG * 10) / 10,
      targets,
      calorieBalance: remCalories >= 0 ? `Deficit of ${remCalories} kcal` : `Surplus of ${Math.abs(remCalories)} kcal`,
    },
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

export default router;

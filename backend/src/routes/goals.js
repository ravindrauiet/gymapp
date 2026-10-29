import { Router } from 'express';
import { z } from 'zod';
import { queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notFound, validate } from '../utils/http.js';

const router = Router();
router.use(requireAuth('user'));

export const GOAL_DEFAULTS = { workoutDaysPerWeek: 4, dailyStepsTarget: 8000, waterGlassesTarget: 8 };

const habitFields = {
  workoutDaysPerWeek: z.number().int().min(1).max(7).optional(),
  dailyStepsTarget: z.number().int().min(1000).max(50000).optional(),
  waterGlassesTarget: z.number().int().min(1).max(30).optional(),
};

const goalSchema = z.object({
  goalType: z.enum(['weight_loss', 'muscle_gain', 'maintenance']),
  age: z.number().int().min(12).max(100),
  gender: z.enum(['male', 'female', 'other']),
  heightCm: z.number().min(80).max(250),
  currentWeightKg: z.number().min(30).max(300),
  targetWeightKg: z.number().min(30).max(300),
  activityLevel: z.enum(['sedentary', 'light', 'moderate', 'very_active']),
  ...habitFields,
});

/** null clears an override (back to the auto-calculated value). */
const patchSchema = z
  .object({
    ...habitFields,
    calorieTarget: z.number().int().min(800).max(8000).nullable().optional(),
    proteinG: z.number().int().min(0).max(500).nullable().optional(),
    carbsG: z.number().int().min(0).max(1000).nullable().optional(),
    fatG: z.number().int().min(0).max(400).nullable().optional(),
    resetTargets: z.boolean().optional(),
  })
  .strict();

/**
 * Calculates BMR, TDEE, Caloric target and Macro breakdown.
 */
export function calculateTargets({ goalType, age, gender, heightCm, currentWeightKg, activityLevel }) {
  // Mifflin-St Jeor formula
  let bmr = 10 * currentWeightKg + 6.25 * heightCm - 5 * age;
  if (gender === 'male') {
    bmr += 5;
  } else {
    bmr -= 161;
  }

  const multipliers = {
    sedentary: 1.2,
    light: 1.375,
    moderate: 1.55,
    very_active: 1.725,
  };
  const tdee = Math.round(bmr * (multipliers[activityLevel] || 1.375));

  let calorieTarget = tdee;
  if (goalType === 'weight_loss') {
    calorieTarget = Math.max(1200, tdee - 500); // 500 kcal deficit
  } else if (goalType === 'muscle_gain') {
    calorieTarget = tdee + 400; // 400 kcal surplus
  }

  // Protein: 2.0g per kg for muscle gain, 1.8g for weight loss, 1.5g for maintenance
  const proteinMultiplier = goalType === 'muscle_gain' ? 2.0 : goalType === 'weight_loss' ? 1.8 : 1.5;
  const proteinG = Math.round(currentWeightKg * proteinMultiplier);
  const proteinCals = proteinG * 4;

  // Fat: ~25% of calories
  const fatCals = calorieTarget * 0.25;
  const fatG = Math.round(fatCals / 9);

  // Carbs: remainder
  const carbCals = Math.max(0, calorieTarget - proteinCals - fatCals);
  const carbsG = Math.round(carbCals / 4);

  return {
    dailyCalorieTarget: calorieTarget,
    dailyProteinG: proteinG,
    dailyCarbsG: carbsG,
    dailyFatG: fatG,
    bmr: Math.round(bmr),
    tdee,
  };
}

/** Auto targets for a stored goal row (camelCase), or null when there is no goal. */
export function autoTargetsFor(goal) {
  if (!goal) return null;
  return calculateTargets({
    goalType: goal.goalType,
    age: goal.age,
    gender: goal.gender,
    heightCm: +goal.heightCm,
    currentWeightKg: +goal.currentWeightKg,
    activityLevel: goal.activityLevel,
  });
}

/**
 * The member's effective daily targets, never NaN/0: their goal (with any overrides) when one exists,
 * otherwise sensible defaults flagged `source: 'default'` so the app can ask them to set a goal.
 */
export function effectiveTargets(goal) {
  if (!goal) {
    return {
      source: 'default',
      calories: 2000,
      proteinG: 60,
      carbsG: 315,
      fatG: 55,
      workoutDaysPerWeek: GOAL_DEFAULTS.workoutDaysPerWeek,
      dailyStepsTarget: GOAL_DEFAULTS.dailyStepsTarget,
      waterGlassesTarget: GOAL_DEFAULTS.waterGlassesTarget,
    };
  }
  const auto = autoTargetsFor(goal);
  const pick = (override, stored, calc) => override ?? (stored > 0 ? stored : calc);
  const custom = [goal.calorieTargetOverride, goal.proteinGOverride, goal.carbsGOverride, goal.fatGOverride].some((v) => v != null);
  return {
    source: custom ? 'custom' : 'goal',
    calories: pick(goal.calorieTargetOverride, goal.dailyCalorieTarget, auto.dailyCalorieTarget),
    proteinG: pick(goal.proteinGOverride, goal.dailyProteinG, auto.dailyProteinG),
    carbsG: pick(goal.carbsGOverride, goal.dailyCarbsG, auto.dailyCarbsG),
    fatG: pick(goal.fatGOverride, goal.dailyFatG, auto.dailyFatG),
    workoutDaysPerWeek: goal.workoutDaysPerWeek ?? GOAL_DEFAULTS.workoutDaysPerWeek,
    dailyStepsTarget: goal.dailyStepsTarget ?? GOAL_DEFAULTS.dailyStepsTarget,
    waterGlassesTarget: goal.waterGlassesTarget ?? GOAL_DEFAULTS.waterGlassesTarget,
  };
}

/** Adds the auto-calculated targets and an override flag to a goal row for the app. */
function present(goal) {
  if (!goal) return null;
  const auto = autoTargetsFor(goal);
  return {
    ...goal,
    autoTargets: auto,
    customTargets: [goal.calorieTargetOverride, goal.proteinGOverride, goal.carbsGOverride, goal.fatGOverride].some(
      (v) => v != null,
    ),
  };
}

router.get('/', async (req, res) => {
  const goal = await queryOne(`SELECT * FROM user_goals WHERE user_id = $1`, [req.user.id]);
  res.json({ goal: present(goal) });
});

/** Saves body stats + goal; recalculates targets. Re-running the wizard clears custom nutrition targets. */
router.post('/', async (req, res) => {
  const data = validate(goalSchema, req.body);
  const targets = calculateTargets(data);

  const goal = await queryOne(
    `INSERT INTO user_goals (
       user_id, goal_type, age, gender, height_cm, current_weight_kg, target_weight_kg,
       activity_level, daily_calorie_target, daily_protein_g, daily_carbs_g, daily_fat_g,
       workout_days_per_week, daily_steps_target, water_glasses_target, updated_at
     ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
               COALESCE($13::int, $16::int), COALESCE($14::int, $17::int), COALESCE($15::int, $18::int), now())
     ON CONFLICT (user_id) DO UPDATE SET
       goal_type = EXCLUDED.goal_type,
       age = EXCLUDED.age,
       gender = EXCLUDED.gender,
       height_cm = EXCLUDED.height_cm,
       current_weight_kg = EXCLUDED.current_weight_kg,
       target_weight_kg = EXCLUDED.target_weight_kg,
       activity_level = EXCLUDED.activity_level,
       daily_calorie_target = EXCLUDED.daily_calorie_target,
       daily_protein_g = EXCLUDED.daily_protein_g,
       daily_carbs_g = EXCLUDED.daily_carbs_g,
       daily_fat_g = EXCLUDED.daily_fat_g,
       workout_days_per_week = COALESCE($13::int, user_goals.workout_days_per_week),
       daily_steps_target = COALESCE($14::int, user_goals.daily_steps_target),
       water_glasses_target = COALESCE($15::int, user_goals.water_glasses_target),
       calorie_target_override = NULL,
       protein_g_override = NULL,
       carbs_g_override = NULL,
       fat_g_override = NULL,
       updated_at = now()
     RETURNING *`,
    [
      req.user.id,
      data.goalType,
      data.age,
      data.gender,
      data.heightCm,
      data.currentWeightKg,
      data.targetWeightKg,
      data.activityLevel,
      targets.dailyCalorieTarget,
      targets.dailyProteinG,
      targets.dailyCarbsG,
      targets.dailyFatG,
      data.workoutDaysPerWeek ?? null,
      data.dailyStepsTarget ?? null,
      data.waterGlassesTarget ?? null,
      GOAL_DEFAULTS.workoutDaysPerWeek,
      GOAL_DEFAULTS.dailyStepsTarget,
      GOAL_DEFAULTS.waterGlassesTarget,
    ],
  );

  res.status(201).json({ goal: present(goal), targets });
});

/**
 * PATCH /goals — edit habit goals (workout days, steps, water) and/or override nutrition targets.
 * Pass a target as null (or resetTargets: true) to go back to the auto-calculated value.
 */
router.patch('/', async (req, res) => {
  const body = validate(patchSchema, req.body);
  const goal = await queryOne(`SELECT * FROM user_goals WHERE user_id = $1`, [req.user.id]);
  if (!goal) throw notFound('Set your goal first');

  const auto = autoTargetsFor(goal);
  const override = (key, current) => (body.resetTargets ? null : body[key] === undefined ? current : body[key]);
  const cal = override('calorieTarget', goal.calorieTargetOverride);
  const pro = override('proteinG', goal.proteinGOverride);
  const carb = override('carbsG', goal.carbsGOverride);
  const fat = override('fatG', goal.fatGOverride);

  const updated = await queryOne(
    `UPDATE user_goals SET
       workout_days_per_week = $2, daily_steps_target = $3, water_glasses_target = $4,
       calorie_target_override = $5, protein_g_override = $6, carbs_g_override = $7, fat_g_override = $8,
       daily_calorie_target = $9, daily_protein_g = $10, daily_carbs_g = $11, daily_fat_g = $12,
       updated_at = now()
     WHERE user_id = $1 RETURNING *`,
    [
      req.user.id,
      body.workoutDaysPerWeek ?? goal.workoutDaysPerWeek,
      body.dailyStepsTarget ?? goal.dailyStepsTarget,
      body.waterGlassesTarget ?? goal.waterGlassesTarget,
      cal,
      pro,
      carb,
      fat,
      cal ?? auto.dailyCalorieTarget,
      pro ?? auto.dailyProteinG,
      carb ?? auto.dailyCarbsG,
      fat ?? auto.dailyFatG,
    ],
  );
  res.json({ goal: present(updated) });
});

export default router;

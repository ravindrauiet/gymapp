import { Router } from 'express';
import { z } from 'zod';
import { queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { validate } from '../utils/http.js';

const router = Router();
router.use(requireAuth('user'));

const goalSchema = z.object({
  goalType: z.enum(['weight_loss', 'muscle_gain', 'maintenance']),
  age: z.number().int().min(12).max(100),
  gender: z.enum(['male', 'female', 'other']),
  heightCm: z.number().min(80).max(250),
  currentWeightKg: z.number().min(30).max(300),
  targetWeightKg: z.number().min(30).max(300),
  activityLevel: z.enum(['sedentary', 'light', 'moderate', 'very_active']),
});

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

router.get('/', async (req, res) => {
  const goal = await queryOne(
    `SELECT * FROM user_goals WHERE user_id = $1`,
    [req.user.id],
  );
  res.json({ goal: goal || null });
});

router.post('/', async (req, res) => {
  const data = validate(goalSchema, req.body);
  const targets = calculateTargets(data);

  const goal = await queryOne(
    `INSERT INTO user_goals (
       user_id, goal_type, age, gender, height_cm, current_weight_kg, target_weight_kg,
       activity_level, daily_calorie_target, daily_protein_g, daily_carbs_g, daily_fat_g, updated_at
     ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, now())
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
    ],
  );

  res.status(201).json({ goal, targets });
});

export default router;

import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notFound, validate } from '../utils/http.js';
import { ACTIVITY_TYPES } from '../utils/constants.js';
import { dateSchema, pagination } from '../utils/schemas.js';

/** Health / gym report (U9): weight log, activity log, step tracker and an aggregated progress report. */
const router = Router();
router.use(requireAuth('user'));

// ---- Steps & Movement Tracking (Health Connect / Google Fit / Apple HealthKit) ----
const stepSyncSchema = z.object({
  date: dateSchema.optional(),
  steps: z.number().int().min(0).max(100000),
  distanceKm: z.number().min(0).max(200).optional(),
  activeCalories: z.number().int().min(0).max(10000).optional(),
  source: z.string().default('health_connect'),
});

router.post('/steps/sync', async (req, res) => {
  const data = validate(stepSyncSchema, req.body);
  const distance = data.distanceKm ?? Math.round((data.steps * 0.00075) * 100) / 100;
  const calories = data.activeCalories ?? Math.round(data.steps * 0.04);

  const entry = await queryOne(
    `INSERT INTO step_logs (user_id, log_date, steps, distance_km, active_calories, source, synced_at)
     VALUES ($1, COALESCE($2::date, (now() AT TIME ZONE $3)::date), $4, $5, $6, $7, now())
     ON CONFLICT (user_id, log_date) DO UPDATE SET
       steps = EXCLUDED.steps,
       distance_km = EXCLUDED.distance_km,
       active_calories = EXCLUDED.active_calories,
       source = EXCLUDED.source,
       synced_at = now()
     RETURNING *`,
    [req.user.id, data.date ?? null, config.tz, data.steps, distance, calories, data.source],
  );
  res.status(201).json({ stepLog: entry });
});

router.get('/steps/today', async (req, res) => {
  const today = await queryOne(
    `SELECT * FROM step_logs WHERE user_id = $1 AND log_date = (now() AT TIME ZONE $2)::date`,
    [req.user.id, config.tz],
  );
  res.json({
    today: today || {
      steps: 0,
      distance_km: 0,
      active_calories: 0,
      source: 'none',
    },
  });
});

router.post('/weights', async (req, res) => {
  const body = validate(z.object({ weightKg: z.number().min(20).max(400), loggedOn: dateSchema.optional() }), req.body);
  const entry = await queryOne(
    `INSERT INTO weight_logs (user_id, weight_kg, logged_on)
     VALUES ($1, $2, COALESCE($3::date, (now() AT TIME ZONE $4)::date))
     ON CONFLICT (user_id, logged_on) DO UPDATE SET weight_kg = EXCLUDED.weight_kg
     RETURNING id, weight_kg, logged_on`,
    [req.user.id, body.weightKg, body.loggedOn ?? null, config.tz],
  );
  res.status(201).json({ entry });
});

router.get('/weights', async (req, res) => {
  const { days } = validate(z.object({ days: z.coerce.number().int().min(7).max(730).default(90) }), req.query);
  const entries = await query(
    `SELECT id, weight_kg, logged_on FROM weight_logs
     WHERE user_id = $1 AND logged_on >= (now() AT TIME ZONE $2)::date - $3::int
     ORDER BY logged_on`,
    [req.user.id, config.tz, days],
  );
  res.json({ entries });
});

const activitySchema = z.object({
  type: z.enum(ACTIVITY_TYPES),
  title: z.string().trim().max(120).optional(),
  durationMin: z.number().int().min(0).max(1440).optional(),
  distanceKm: z.number().min(0).max(500).optional(),
  calories: z.number().int().min(0).max(20000).optional(),
  notes: z.string().trim().max(500).optional(),
  loggedAt: z.string().datetime({ offset: true }).optional(),
});

router.post('/activities', async (req, res) => {
  const a = validate(activitySchema, req.body);
  const activity = await queryOne(
    `INSERT INTO activity_logs (user_id, type, title, duration_min, distance_km, calories, notes, logged_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, COALESCE($8::timestamptz, now()))
     RETURNING *`,
    [req.user.id, a.type, a.title ?? null, a.durationMin ?? null, a.distanceKm ?? null, a.calories ?? null, a.notes ?? null, a.loggedAt ?? null],
  );
  res.status(201).json({ activity });
});

router.get('/activities', async (req, res) => {
  const { page, limit } = validate(z.object(pagination), req.query);
  const activities = await query(
    `SELECT * FROM activity_logs WHERE user_id = $1 ORDER BY logged_at DESC LIMIT $2 OFFSET $3`,
    [req.user.id, limit, (page - 1) * limit],
  );
  res.json({ activities, page, limit });
});

router.delete('/activities/:id', async (req, res) => {
  const deleted = await queryOne(`DELETE FROM activity_logs WHERE id = $1 AND user_id = $2 RETURNING id`, [
    req.params.id,
    req.user.id,
  ]);
  if (!deleted) throw notFound('Activity not found');
  res.status(204).end();
});

/** Counts consecutive days (ending today or yesterday) present in a descending list of 'YYYY-MM-DD'. */
function currentStreak(datesDesc, today) {
  const dayMs = 86_400_000;
  const toDay = (s) => Date.UTC(+s.slice(0, 4), +s.slice(5, 7) - 1, +s.slice(8, 10)) / dayMs;
  let expected = toDay(today);
  if (datesDesc[0] && toDay(datesDesc[0]) === expected - 1) expected -= 1; // today not done yet
  let streak = 0;
  for (const d of datesDesc) {
    if (toDay(d) !== expected) break;
    streak += 1;
    expected -= 1;
  }
  return streak;
}

/** GET /health/report?days=30 — Central Integration Architecture (Gym & Health Report Engine). */
router.get('/report', async (req, res) => {
  const { days } = validate(z.object({ days: z.coerce.number().int().min(7).max(365).default(30) }), req.query);
  const params = [req.user.id, config.tz, days];
  const since = `(now() AT TIME ZONE $2)::date - $3::int`;

  const [today, attendance, perDay, allDates, venues, workouts, byType, weights, userGoal, stepsData, nutritionData] = await Promise.all([
    queryOne(`SELECT (now() AT TIME ZONE $1)::date AS d`, [config.tz]),
    queryOne(
      `SELECT COUNT(*) AS total_checkins, COUNT(DISTINCT venue_id) AS unique_venues, COUNT(DISTINCT checkin_date) AS active_days
       FROM checkins WHERE user_id = $1 AND checkin_date > ${since}`,
      params,
    ),
    query(
      `SELECT checkin_date AS date, COUNT(*) AS count FROM checkins
       WHERE user_id = $1 AND checkin_date > ${since} GROUP BY checkin_date ORDER BY checkin_date`,
      params,
    ),
    query(`SELECT DISTINCT checkin_date AS d FROM checkins WHERE user_id = $1 ORDER BY d DESC LIMIT 400`, [req.user.id]),
    query(
      `SELECT v.id, v.name, COUNT(*) AS visits FROM checkins c JOIN venues v ON v.id = c.venue_id
       WHERE c.user_id = $1 AND c.checkin_date > ${since} GROUP BY v.id, v.name ORDER BY visits DESC LIMIT 5`,
      params,
    ),
    queryOne(
      `SELECT COUNT(*) AS count, COALESCE(SUM(duration_min), 0) AS total_minutes,
              COALESCE(SUM(distance_km), 0) AS total_distance_km, COALESCE(SUM(calories), 0) AS total_calories
       FROM activity_logs WHERE user_id = $1 AND (logged_at AT TIME ZONE $2)::date > ${since}`,
      params,
    ),
    query(
      `SELECT type, COUNT(*) AS count, COALESCE(SUM(duration_min), 0) AS minutes
       FROM activity_logs WHERE user_id = $1 AND (logged_at AT TIME ZONE $2)::date > ${since}
       GROUP BY type ORDER BY count DESC`,
      params,
    ),
    query(
      `SELECT weight_kg, logged_on FROM weight_logs WHERE user_id = $1 AND logged_on > ${since} ORDER BY logged_on`,
      params,
    ),
    queryOne(`SELECT * FROM user_goals WHERE user_id = $1`, [req.user.id]),
    queryOne(
      `SELECT COALESCE(SUM(steps), 0) AS total_steps,
              COALESCE(SUM(distance_km), 0) AS total_step_distance_km,
              COALESCE(SUM(active_calories), 0) AS total_active_burn,
              COUNT(DISTINCT log_date) AS logged_days
       FROM step_logs WHERE user_id = $1 AND log_date > ${since}`,
      params,
    ),
    queryOne(
      `SELECT COALESCE(SUM(calories), 0) AS total_calories,
              COALESCE(SUM(protein_g), 0) AS total_protein_g,
              COALESCE(SUM(carbs_g), 0) AS total_carbs_g,
              COALESCE(SUM(fat_g), 0) AS total_fat_g,
              COUNT(DISTINCT logged_on) AS meal_days
       FROM meal_logs WHERE user_id = $1 AND logged_on > ${since}`,
      params,
    ),
  ]);

  const latestWeight = await queryOne(
    `SELECT weight_kg, logged_on FROM weight_logs WHERE user_id = $1 ORDER BY logged_on DESC LIMIT 1`,
    [req.user.id],
  );
  const first = weights[0];
  const last = weights[weights.length - 1];

  const streak = currentStreak(allDates.map((r) => r.d), today.d);

  // 1. Gym Consistency Score (0-100) based on recommended 4 sessions/week
  const targetCheckins = Math.max(1, Math.round((days / 7) * 4));
  const totalCheckins = +(attendance.totalCheckins ?? attendance.total_checkins ?? 0);
  const gymConsistencyScore = Math.min(100, Math.round(((totalCheckins + streak * 0.5) / targetCheckins) * 100));

  // 2. Daily Movement Score (0-100) based on 8,000 steps/day or 400 active kcal/day
  const totSteps = +(stepsData.totalSteps ?? stepsData.total_steps ?? 0);
  const logDays = Math.max(1, +(stepsData.loggedDays ?? stepsData.logged_days ?? 1));
  const totBurn = +(stepsData.totalActiveBurn ?? stepsData.total_active_burn ?? 0);
  const totDist = +(stepsData.totalStepDistanceKm ?? stepsData.total_step_distance_km ?? 0);

  const avgDailySteps = Math.round(totSteps / logDays);
  const avgDailyActiveBurn = Math.round(totBurn / logDays);
  const movementScore = Math.min(100, Math.round((avgDailySteps / 8000) * 60 + (avgDailyActiveBurn / 400) * 40));

  // 3. Nutrition & Baselines
  const mealDays = Math.max(1, +(nutritionData.mealDays ?? nutritionData.meal_days ?? 1));
  const totCals = +(nutritionData.totalCalories ?? nutritionData.total_calories ?? 0);
  const totProtein = +(nutritionData.totalProteinG ?? nutritionData.total_protein_g ?? 0);
  const totCarbs = +(nutritionData.totalCarbsG ?? nutritionData.total_carbs_g ?? 0);
  const totFat = +(nutritionData.totalFatG ?? nutritionData.total_fat_g ?? 0);

  const avgDailyCalories = Math.round(totCals / mealDays);
  const avgDailyProtein = Math.round((totProtein / mealDays) * 10) / 10;
  const avgDailyCarbs = Math.round((totCarbs / mealDays) * 10) / 10;
  const avgDailyFat = Math.round((totFat / mealDays) * 10) / 10;

  const baselineCalories = userGoal ? (userGoal.dailyCalorieTarget ?? userGoal.daily_calorie_target ?? 2000) : 2000;
  const baselineProtein = userGoal ? (userGoal.dailyProteinG ?? userGoal.daily_protein_g ?? 120) : 120;
  const baselineCarbs = userGoal ? (userGoal.dailyCarbsG ?? userGoal.daily_carbs_g ?? 220) : 220;
  const baselineFat = userGoal ? (userGoal.dailyFatG ?? userGoal.daily_fat_g ?? 55) : 55;
  const goalType = userGoal ? (userGoal.goalType ?? userGoal.goal_type ?? 'maintenance') : 'maintenance';

  const calorieDelta = avgDailyCalories - baselineCalories;
  let deficitSurplusStatus = 'Balanced (Isocaloric)';
  if (calorieDelta < -150) {
    deficitSurplusStatus = `Deficit (-${Math.abs(calorieDelta)} kcal/day)`;
  } else if (calorieDelta > 150) {
    deficitSurplusStatus = `Surplus (+${calorieDelta} kcal/day)`;
  }

  res.json({
    days,
    attendance: {
      ...attendance,
      currentStreak: streak,
      gymConsistencyScore,
      perDay,
      topVenues: venues,
    },
    workouts: { ...workouts, byType },
    movement: {
      totalSteps: totSteps,
      avgDailySteps,
      totalDistanceKm: Math.round(totDist * 10) / 10,
      totalActiveBurn: totBurn,
      avgDailyActiveBurn,
      movementScore,
    },
    nutrition: {
      avgDailyCalories,
      avgDailyProtein,
      avgDailyCarbs,
      avgDailyFat,
      deficitSurplusStatus,
      mealDays,
      baselines: {
        dailyCalories: baselineCalories,
        dailyProteinG: baselineProtein,
        dailyCarbsG: baselineCarbs,
        dailyFatG: baselineFat,
        goalType,
      },
    },
    weight: {
      latest: latestWeight,
      changeKg: first && last ? Math.round((last.weightKg - first.weightKg) * 10) / 10 : null,
      series: weights,
    },
    integrationArchitecture: [
      { source: 'Onboarding Profile', metric: 'Calorie & Nutrient Target Baselines', outcome: `${baselineCalories} kcal / ${baselineProtein}g protein daily benchmark` },
      { source: 'Activity Tracker', metric: 'Steps, Distance (KM), Active Burn', outcome: `${avgDailySteps.toLocaleString()} steps/day · Movement Score ${movementScore}/100` },
      { source: 'FitKey Gym Check-in', metric: 'Attendance Logs, Session Frequency', outcome: `${totalCheckins} check-ins · Consistency Score ${gymConsistencyScore}/100` },
      { source: 'Fuel Log (Nutrition)', metric: 'Total Calorie & Macro/Micro Intake', outcome: deficitSurplusStatus },
    ],
  });
});

export default router;

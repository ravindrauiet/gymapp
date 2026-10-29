import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, notFound, validate } from '../utils/http.js';
import { ACTIVITY_TYPES } from '../utils/constants.js';
import { dateSchema, pagination } from '../utils/schemas.js';
import { effectiveTargets } from './goals.js';

/**
 * Health / gym report (U9, BRD §4 Progress): weight log, activity log, step sync (Health Connect / HealthKit /
 * manual), MET calorie estimates and the goal-based progress report (Overview | Workout | Nutrition).
 */
const router = Router();
router.use(requireAuth('user'));

// ---------------------------------------------------------------------------
// Calorie estimates — Compendium of Physical Activities (Ainsworth et al., 2011 update)
// kcal = MET × body weight (kg) × hours
// ---------------------------------------------------------------------------

/** Typical MET per logged activity type. */
export const ACTIVITY_MET = {
  workout: 5.0, // resistance / gym training, general (02054 3.5 … circuit 8.0 → 5.0 typical session)
  running: 9.8, // 02:12050 running 6 mph (9.7 km/h)
  cycling: 7.5, // 01015 bicycling, general
  swimming: 6.0, // 18310 swimming, leisurely, not lap swimming, general
  yoga: 2.5, // 02150 yoga, hatha
  sports: 7.0, // e.g. 15610 soccer casual 7.0, 15020 badminton 5.5, 15055 basketball 6.5
  other: 4.0,
};

/** MET for a check-in day with no logged activity, by venue category (assumes a 60-minute session). */
const VENUE_MET = {
  gym: 5.0,
  swimming_pool: 6.0,
  sports_club: 7.0,
  yoga_studio: 2.5,
  mma: 5.5, // 15100 boxing, punching bag
  martial_arts: 5.3, // 15430 martial arts, slower pace
  dance: 5.5, // 03025 ballroom / general dance
};

/** Running MET by speed (km/h) — Compendium 12xxx codes. */
const RUN_MET = [
  [16.1, 14.5], [14.5, 12.8], [13.8, 12.3], [12.9, 11.8], [12.1, 11.5], [11.3, 11.0], [10.8, 10.5],
  [9.7, 9.8], [8.4, 9.0], [8.0, 8.3], [6.4, 6.0], [5.6, 4.3], [0, 3.5],
];
/** Cycling MET by speed (km/h) — Compendium 01xxx codes. */
const CYCLE_MET = [[30.6, 15.8], [25.7, 12.0], [22.5, 10.0], [19.3, 8.0], [16.0, 6.8], [0, 4.0]];
const TYPICAL_KMH = { running: 9.7, cycling: 18, swimming: 2.5 };

const lookup = (table, kmh) => (table.find(([min]) => kmh >= min) ?? table[table.length - 1])[1];

/** MET-based kcal estimate for an activity, or null when there is no duration or distance to go on. */
export function estimateActivityCalories({ type, durationMin, distanceKm }, weightKg) {
  let minutes = +durationMin || 0;
  const km = +distanceKm || 0;
  if (!minutes && km && TYPICAL_KMH[type]) minutes = (km / TYPICAL_KMH[type]) * 60;
  if (!minutes) return null;
  let met = ACTIVITY_MET[type] ?? ACTIVITY_MET.other;
  if (km && durationMin) {
    const kmh = km / (durationMin / 60);
    if (type === 'running') met = lookup(RUN_MET, kmh);
    if (type === 'cycling') met = lookup(CYCLE_MET, kmh);
  }
  return Math.round(met * weightKg * (minutes / 60));
}

const DEFAULT_WEIGHT_KG = 70;

/** Body weight for estimates: latest logged weight, else the goal's current weight, else 70 kg. */
async function bodyWeight(userId) {
  const row = await queryOne(
    `SELECT (SELECT weight_kg FROM weight_logs WHERE user_id = $1 ORDER BY logged_on DESC LIMIT 1) AS logged,
            (SELECT current_weight_kg FROM user_goals WHERE user_id = $1) AS goal`,
    [userId],
  );
  if (row?.logged) return { kg: +row.logged, source: 'weight_log' };
  if (row?.goal) return { kg: +row.goal, source: 'goal' };
  return { kg: DEFAULT_WEIGHT_KG, source: 'default' };
}

// ---- Steps & Movement Tracking (Health Connect / Apple HealthKit / manual) ----
const DEVICE_SOURCES = ['health_connect', 'apple_healthkit', 'google_fit'];

const stepDaySchema = z.object({
  date: dateSchema.optional(),
  steps: z.number().int().min(0).max(100000),
  distanceKm: z.number().min(0).max(200).optional(),
  activeCalories: z.number().int().min(0).max(10000).optional(),
});
const stepSyncSchema = stepDaySchema.extend({ source: z.string().max(40).default('health_connect') });
const stepBatchSchema = z.object({
  source: z.string().max(40).default('health_connect'),
  days: z.array(stepDaySchema.extend({ date: dateSchema })).min(1).max(120),
});

async function upsertSteps(userId, d, source) {
  const distance = d.distanceKm ?? Math.round(d.steps * 0.00075 * 100) / 100;
  const measured = d.activeCalories != null && d.activeCalories > 0 && DEVICE_SOURCES.includes(source);
  const calories = d.activeCalories != null && (measured || source === 'manual') ? d.activeCalories : Math.round(d.steps * 0.04);
  return queryOne(
    `INSERT INTO step_logs (user_id, log_date, steps, distance_km, active_calories, source, calories_measured, synced_at)
     SELECT $1, day, $4, $5, $6, $7, $8, now()
       FROM (SELECT COALESCE($2::date, (now() AT TIME ZONE $3)::date) AS day) x
      WHERE day <= (now() AT TIME ZONE $3)::date
     ON CONFLICT (user_id, log_date) DO UPDATE SET
       steps = EXCLUDED.steps,
       distance_km = EXCLUDED.distance_km,
       active_calories = EXCLUDED.active_calories,
       source = EXCLUDED.source,
       calories_measured = EXCLUDED.calories_measured,
       synced_at = now()
     RETURNING *`,
    [userId, d.date ?? null, config.tz, d.steps, distance, calories, source, measured],
  );
}

/**
 * POST /health/steps/sync — one day `{steps, date?, distanceKm?, activeCalories?, source}` or a back-fill batch
 * `{source, days: [{date, steps, distanceKm?, activeCalories?}]}` (Health Connect / HealthKit, last 7–90 days).
 * activeCalories from a device source are treated as measured and override FITKEY's own estimates for that day.
 */
router.post('/steps/sync', async (req, res) => {
  if (Array.isArray(req.body?.days)) {
    const { source, days } = validate(stepBatchSchema, req.body);
    const saved = [];
    for (const d of days) {
      const row = await upsertSteps(req.user.id, d, source);
      if (row) saved.push(row);
    }
    return res.status(201).json({ synced: saved.length, stepLogs: saved });
  }
  const data = validate(stepSyncSchema, req.body);
  const entry = await upsertSteps(req.user.id, data, data.source);
  if (!entry) throw badRequest("You can't add steps for a future day");
  res.status(201).json({ stepLog: entry });
});

router.get('/steps/today', async (req, res) => {
  const [today, lastDevice] = await Promise.all([
    queryOne(`SELECT * FROM step_logs WHERE user_id = $1 AND log_date = (now() AT TIME ZONE $2)::date`, [
      req.user.id,
      config.tz,
    ]),
    queryOne(
      `SELECT source, synced_at FROM step_logs WHERE user_id = $1 AND source = ANY($2) ORDER BY synced_at DESC LIMIT 1`,
      [req.user.id, DEVICE_SOURCES],
    ),
  ]);
  res.json({
    today: today || { steps: 0, distanceKm: 0, activeCalories: 0, source: 'none' },
    lastDeviceSync: lastDevice,
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

async function insertActivity(userId, a) {
  let calories = a.calories ?? null;
  let estimated = false;
  if (calories == null) {
    const w = await bodyWeight(userId);
    calories = estimateActivityCalories(a, w.kg);
    estimated = calories != null;
  }
  return queryOne(
    `INSERT INTO activity_logs (user_id, type, title, duration_min, distance_km, calories, calories_estimated, notes, logged_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, COALESCE($9::timestamptz, now()))
     RETURNING *`,
    [userId, a.type, a.title ?? null, a.durationMin ?? null, a.distanceKm ?? null, calories, estimated, a.notes ?? null, a.loggedAt ?? null],
  );
}

/** Logs an activity. Without a calorie value the server estimates it (MET × weight × hours). */
router.post('/activities', async (req, res) => {
  const a = validate(activitySchema, req.body);
  const activity = await insertActivity(req.user.id, a);
  res.status(201).json({ activity });
});

/** One-tap "repeat last activity": logs the member's most recent activity again, now. */
router.post('/activities/repeat', async (req, res) => {
  const last = await queryOne(`SELECT * FROM activity_logs WHERE user_id = $1 ORDER BY logged_at DESC LIMIT 1`, [req.user.id]);
  if (!last) throw notFound('No activity to repeat yet — log one first');
  const activity = await insertActivity(req.user.id, {
    type: last.type,
    title: last.title ?? undefined,
    durationMin: last.durationMin ?? undefined,
    distanceKm: last.distanceKm ?? undefined,
    // Re-estimate when the original value was an estimate (weight may have changed).
    calories: last.caloriesEstimated ? undefined : (last.calories ?? undefined),
  });
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
  const { id } = validate(z.object({ id: z.string().uuid() }), req.params);
  const deleted = await queryOne(`DELETE FROM activity_logs WHERE id = $1 AND user_id = $2 RETURNING id`, [id, req.user.id]);
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

/** 'YYYY-MM-DD' list of the last `days` days ending at `today` (inclusive). */
function dayRange(today, days) {
  const base = Date.UTC(+today.slice(0, 4), +today.slice(5, 7) - 1, +today.slice(8, 10));
  return Array.from({ length: days }, (_, i) => new Date(base - (days - 1 - i) * 86_400_000).toISOString().slice(0, 10));
}

const round1 = (v) => Math.round(v * 10) / 10;

/** Higher-is-better goal ring: ahead (≥100%), on_track (≥85%), behind, or no_data. */
function higherBetter(value, target, hasData) {
  if (!hasData) return { status: 'no_data', score: null };
  const ratio = target > 0 ? value / target : 0;
  return { status: ratio >= 1 ? 'ahead' : ratio >= 0.85 ? 'on_track' : 'behind', score: Math.min(1, ratio) };
}

/** Calories vs target, judged by goal: under is good when losing weight, over is good when building muscle. */
function calorieStatus(avg, target, goalType, hasData) {
  if (!hasData) return { status: 'no_data', score: null, deviation: 0 };
  const dev = target > 0 ? (avg - target) / target : 0;
  const favourable = (goalType === 'weight_loss' && dev < 0) || (goalType === 'muscle_gain' && dev > 0);
  let status;
  if (Math.abs(dev) <= 0.1) status = 'on_track';
  else if (favourable && Math.abs(dev) <= 0.3) status = 'ahead';
  else status = 'behind';
  const score = Math.abs(dev) <= 0.1 || (favourable && Math.abs(dev) <= 0.3) ? 1 : Math.max(0, 1 - Math.abs(dev));
  return { status, score, deviation: dev };
}

function bmiCategory(bmi) {
  if (bmi < 18.5) return 'Underweight';
  if (bmi < 25) return 'Healthy';
  if (bmi < 30) return 'Overweight';
  return 'Obese';
}

/** GET /health/report?days=7|30|90 — Gym & Health Report Engine, goal-based (Overview | Workout | Nutrition). */
router.get('/report', async (req, res) => {
  const { days } = validate(z.object({ days: z.coerce.number().int().min(7).max(365).default(30) }), req.query);
  const uid = req.user.id;
  const params = [uid, config.tz, days];
  const since = `(now() AT TIME ZONE $2)::date - $3::int`;

  const [
    today,
    attendance,
    perDay,
    allDates,
    venues,
    activityRows,
    weights,
    userGoal,
    stepRows,
    mealRows,
    waterRows,
    checkinDays,
    latestWeight,
    usage,
    lastActivity,
    lastDevice,
  ] = await Promise.all([
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
    query(`SELECT DISTINCT checkin_date AS d FROM checkins WHERE user_id = $1 ORDER BY d DESC LIMIT 400`, [uid]),
    query(
      `SELECT v.id, v.name, COUNT(*) AS visits FROM checkins c JOIN venues v ON v.id = c.venue_id
       WHERE c.user_id = $1 AND c.checkin_date > ${since} GROUP BY v.id, v.name ORDER BY visits DESC LIMIT 5`,
      params,
    ),
    query(
      `SELECT id, type, title, duration_min, distance_km, calories, calories_estimated,
              (logged_at AT TIME ZONE $2)::date::text AS day
       FROM activity_logs WHERE user_id = $1 AND (logged_at AT TIME ZONE $2)::date > ${since}`,
      params,
    ),
    query(
      `SELECT weight_kg, logged_on FROM weight_logs WHERE user_id = $1 AND logged_on > ${since} ORDER BY logged_on`,
      params,
    ),
    queryOne(`SELECT * FROM user_goals WHERE user_id = $1`, [uid]),
    query(
      `SELECT log_date::text AS date, steps, distance_km, active_calories, source, calories_measured
       FROM step_logs WHERE user_id = $1 AND log_date > ${since} ORDER BY log_date`,
      params,
    ),
    query(
      `SELECT logged_on::text AS date, COUNT(*) AS items, COUNT(DISTINCT meal_type) AS slots,
              BOOL_OR(meal_type = 'breakfast') AS breakfast,
              COALESCE(SUM(calories), 0) AS calories, COALESCE(SUM(protein_g), 0) AS protein_g,
              COALESCE(SUM(carbs_g), 0) AS carbs_g, COALESCE(SUM(fat_g), 0) AS fat_g
       FROM meal_logs WHERE user_id = $1 AND logged_on > ${since} GROUP BY logged_on ORDER BY logged_on`,
      params,
    ),
    query(
      `SELECT log_date::text AS date, glasses FROM water_logs
       WHERE user_id = $1 AND log_date > ${since} ORDER BY log_date`,
      params,
    ),
    query(
      `SELECT c.checkin_date::text AS date, (array_agg(v.categories[1] ORDER BY c.checked_in_at))[1] AS category
       FROM checkins c JOIN venues v ON v.id = c.venue_id
       WHERE c.user_id = $1 AND c.checkin_date > ${since} GROUP BY c.checkin_date`,
      params,
    ),
    queryOne(`SELECT weight_kg, logged_on FROM weight_logs WHERE user_id = $1 ORDER BY logged_on DESC LIMIT 1`, [uid]),
    queryOne(
      `SELECT EXISTS (SELECT 1 FROM checkins WHERE user_id = $1 AND checkin_date > (now() AT TIME ZONE $2)::date - 90) AS checkins,
              EXISTS (SELECT 1 FROM activity_logs WHERE user_id = $1 AND logged_at > now() - interval '90 days') AS activities,
              EXISTS (SELECT 1 FROM meal_logs WHERE user_id = $1 AND logged_on > (now() AT TIME ZONE $2)::date - 90) AS meals`,
      [uid, config.tz],
    ),
    queryOne(`SELECT * FROM activity_logs WHERE user_id = $1 ORDER BY logged_at DESC LIMIT 1`, [uid]),
    queryOne(
      `SELECT source, synced_at FROM step_logs WHERE user_id = $1 AND source = ANY($2) ORDER BY synced_at DESC LIMIT 1`,
      [uid, DEVICE_SOURCES],
    ),
  ]);

  const todayStr = today.d;
  const range = dayRange(todayStr, days);
  const weeks = days / 7;
  const t = effectiveTargets(userGoal);
  const goalType = userGoal?.goalType ?? 'maintenance';

  // Body weight used for MET estimates.
  const weightKg = latestWeight ? +latestWeight.weightKg : userGoal ? +userGoal.currentWeightKg : DEFAULT_WEIGHT_KG;
  const weightSource = latestWeight ? 'weight_log' : userGoal ? 'goal' : 'default';

  // ---- Attendance & streak ----
  const streak = currentStreak(allDates.map((r) => r.d), todayStr);
  const totalCheckins = +attendance.totalCheckins || 0;
  const targetCheckins = Math.max(1, Math.round(weeks * t.workoutDaysPerWeek));
  const gymConsistencyScore = Math.min(100, Math.round(((totalCheckins + streak * 0.5) / targetCheckins) * 100));

  // ---- Workouts (logged activities; missing calories → MET estimate) ----
  const activityByDay = new Map();
  const typeAgg = new Map();
  let workoutMinutes = 0;
  let workoutDistance = 0;
  let activityKcal = 0;
  let estimatedActivities = 0;
  for (const a of activityRows) {
    let kcal = a.calories;
    if (kcal == null) {
      kcal = estimateActivityCalories(a, weightKg) ?? 0;
      if (kcal) estimatedActivities += 1;
    } else if (a.caloriesEstimated) {
      estimatedActivities += 1;
    }
    activityKcal += kcal;
    workoutMinutes += a.durationMin ?? 0;
    workoutDistance += +a.distanceKm || 0;
    activityByDay.set(a.day, (activityByDay.get(a.day) ?? 0) + kcal);
    const agg = typeAgg.get(a.type) ?? { type: a.type, count: 0, minutes: 0, calories: 0 };
    agg.count += 1;
    agg.minutes += a.durationMin ?? 0;
    agg.calories += kcal;
    typeAgg.set(a.type, agg);
  }
  const byType = [...typeAgg.values()].sort((x, y) => y.count - x.count);

  // ---- Movement (steps) & calories burned per day ----
  const stepsByDay = new Map(stepRows.map((s) => [s.date, s]));
  const checkinCat = new Map(checkinDays.map((c) => [c.date, c.category]));
  let totSteps = 0;
  let totDist = 0;
  let totStepBurn = 0;
  let checkinKcal = 0;
  let estimatedDayActivityKcal = 0;
  let deviceKcal = 0;
  let measuredDays = 0;
  let burnedTotal = 0;
  const movementSeries = [];
  const workoutDaySet = new Set([...checkinCat.keys(), ...activityByDay.keys()]);
  for (const d of range) {
    const s = stepsByDay.get(d);
    const act = activityByDay.get(d) ?? 0;
    // Gym visit with nothing logged that day → estimated 60-minute session at the venue's MET.
    const visit = !activityByDay.has(d) && checkinCat.has(d) ? Math.round((VENUE_MET[checkinCat.get(d)] ?? 5.0) * weightKg) : 0;
    const stepBurn = s ? +s.activeCalories || 0 : 0;
    let burned;
    if (s?.caloriesMeasured) {
      burned = stepBurn; // wearable / Health data overrides FITKEY's estimates
      deviceKcal += stepBurn;
      measuredDays += 1;
    } else {
      burned = act + visit + stepBurn;
      estimatedDayActivityKcal += act;
      checkinKcal += visit;
      totStepBurn += stepBurn;
    }
    burnedTotal += burned;
    if (s) {
      totSteps += s.steps;
      totDist += +s.distanceKm || 0;
    }
    movementSeries.push({
      date: d,
      steps: s?.steps ?? 0,
      distanceKm: s ? round1(+s.distanceKm || 0) : 0,
      activeCalories: burned,
      source: s?.source ?? null,
      measured: !!s?.caloriesMeasured,
    });
  }
  const stepDays = stepRows.length;
  const avgDailySteps = stepDays ? Math.round(totSteps / stepDays) : 0;
  const avgDailyActiveBurn = Math.round(burnedTotal / days);
  const movementScore = stepDays
    ? Math.min(100, Math.round(Math.min(1, avgDailySteps / t.dailyStepsTarget) * 60 + Math.min(1, avgDailyActiveBurn / 400) * 40))
    : 0;

  // ---- Nutrition ----
  const mealDays = mealRows.length;
  const sum = (k) => mealRows.reduce((acc, r) => acc + (+r[k] || 0), 0);
  const avgDailyCalories = mealDays ? Math.round(sum('calories') / mealDays) : 0;
  const avgDailyProtein = mealDays ? round1(sum('proteinG') / mealDays) : 0;
  const avgDailyCarbs = mealDays ? round1(sum('carbsG') / mealDays) : 0;
  const avgDailyFat = mealDays ? round1(sum('fatG') / mealDays) : 0;
  const calorieDelta = avgDailyCalories - t.calories;
  let deficitSurplusStatus = mealDays ? 'Balanced (Isocaloric)' : 'No meals logged';
  if (mealDays && calorieDelta < -150) deficitSurplusStatus = `Deficit (-${Math.abs(calorieDelta)} kcal/day)`;
  else if (mealDays && calorieDelta > 150) deficitSurplusStatus = `Surplus (+${calorieDelta} kcal/day)`;
  const daysOnCalorieTarget = mealRows.filter((r) => Math.abs(+r.calories - t.calories) <= t.calories * 0.1).length;
  const daysHitProtein = mealRows.filter((r) => +r.proteinG >= t.proteinG * 0.9).length;
  const mealByDay = new Map(mealRows.map((r) => [r.date, r]));
  const nutritionSeries = range.map((d) => {
    const r = mealByDay.get(d);
    return {
      date: d,
      calories: r ? +r.calories : 0,
      proteinG: r ? round1(+r.proteinG) : 0,
      carbsG: r ? round1(+r.carbsG) : 0,
      fatG: r ? round1(+r.fatG) : 0,
      meals: r ? +r.slots : 0,
    };
  });

  // ---- Water ----
  const waterByDay = new Map(waterRows.map((w) => [w.date, w.glasses]));
  const waterLoggedDays = waterRows.filter((w) => w.glasses > 0).length;
  const water = {
    target: t.waterGlassesTarget,
    today: waterByDay.get(todayStr) ?? 0,
    avgGlasses: waterLoggedDays ? round1(waterRows.reduce((a, w) => a + w.glasses, 0) / waterLoggedDays) : 0,
    loggedDays: waterLoggedDays,
    daysHit: waterRows.filter((w) => w.glasses >= t.waterGlassesTarget).length,
    series: range.map((d) => ({ date: d, glasses: waterByDay.get(d) ?? 0 })),
  };

  // ---- Weight & BMI ----
  const first = weights[0];
  const last = weights[weights.length - 1];
  const heightCm = userGoal ? +userGoal.heightCm : null;
  const bmiWeight = latestWeight ? +latestWeight.weightKg : userGoal ? +userGoal.currentWeightKg : null;
  const bmiValue = heightCm && bmiWeight ? round1(bmiWeight / (heightCm / 100) ** 2) : null;

  // ---- Goal rings & weekly score (Overview) ----
  const workoutDays = [...workoutDaySet].length;
  const workoutDaysPerWeek = round1(workoutDays / weeks);
  const hasWorkoutData = workoutDays > 0 || usage.checkins || usage.activities;
  const wk = higherBetter(workoutDaysPerWeek, t.workoutDaysPerWeek, hasWorkoutData);
  const st = higherBetter(avgDailySteps, t.dailyStepsTarget, stepDays > 0);
  const cal = calorieStatus(avgDailyCalories, t.calories, goalType, mealDays > 0);
  const pr = higherBetter(avgDailyProtein, t.proteinG, mealDays > 0);
  const rings = [
    {
      key: 'workout_days',
      label: 'Workout days',
      value: workoutDaysPerWeek,
      target: t.workoutDaysPerWeek,
      unit: 'days/wk',
      ...wk,
    },
    { key: 'steps', label: 'Steps', value: avgDailySteps, target: t.dailyStepsTarget, unit: 'steps/day', ...st },
    {
      key: 'calories',
      label: 'Calories',
      value: avgDailyCalories,
      target: t.calories,
      unit: 'kcal/day',
      status: cal.status,
      score: cal.score,
    },
    { key: 'protein', label: 'Protein', value: avgDailyProtein, target: t.proteinG, unit: 'g/day', ...pr },
  ];
  const scored = rings.filter((r) => r.score != null);
  const overallScore = scored.length ? Math.round((scored.reduce((a, r) => a + r.score, 0) / scored.length) * 100) : null;
  for (const r of rings) r.progress = r.target > 0 ? Math.round((r.value / r.target) * 100) / 100 : 0;

  // One-line insight, e.g. "Gym 3/4 days, protein 20% low".
  const fmtDays = (v) => (Number.isInteger(v) ? `${v}` : v.toFixed(1));
  const parts = [];
  if (hasWorkoutData) {
    parts.push(
      days === 7
        ? `Gym ${workoutDays}/${t.workoutDaysPerWeek} days`
        : `Gym ${fmtDays(workoutDaysPerWeek)}/${t.workoutDaysPerWeek} days a week`,
    );
  }
  const gaps = [];
  if (st.status === 'behind') gaps.push({ gap: 1 - avgDailySteps / t.dailyStepsTarget, text: (p) => `steps ${p}% low` });
  if (pr.status === 'behind') gaps.push({ gap: 1 - avgDailyProtein / t.proteinG, text: (p) => `protein ${p}% low` });
  if (cal.status === 'behind') {
    gaps.push({ gap: Math.abs(cal.deviation), text: (p) => `calories ${p}% ${cal.deviation > 0 ? 'over' : 'under'} target` });
  }
  gaps.sort((a, b) => b.gap - a.gap);
  for (const g of gaps.slice(0, parts.length ? 1 : 2)) parts.push(g.text(Math.round(g.gap * 100)));
  let insight;
  if (!scored.length) insight = 'Check in at a gym, sync steps or log a meal to start your report';
  else if (!gaps.length && wk.status !== 'behind') insight = `${parts.length ? `${parts[0]} — ` : ''}you're on track with every goal`;
  else insight = parts.join(', ');
  insight = insight.charAt(0).toUpperCase() + insight.slice(1);

  // Default tab by usage (last 90 days): only Fuel Log → Nutrition; only gym → Workout; both/neither → Overview.
  const gymUser = usage.checkins || usage.activities;
  const foodUser = usage.meals;
  const defaultTab = gymUser && !foodUser ? 'workout' : foodUser && !gymUser ? 'nutrition' : 'overview';

  res.json({
    days,
    defaultTab,
    usage: { gym: gymUser, nutrition: foodUser },
    goals: {
      hasGoal: !!userGoal,
      goalType,
      workoutDaysPerWeek: t.workoutDaysPerWeek,
      dailyStepsTarget: t.dailyStepsTarget,
      waterGlassesTarget: t.waterGlassesTarget,
      calories: t.calories,
      proteinG: t.proteinG,
      carbsG: t.carbsG,
      fatG: t.fatG,
      targetsSource: t.source,
      targetWeightKg: userGoal ? +userGoal.targetWeightKg : null,
    },
    overview: { score: overallScore, insight, rings, workoutDays },
    attendance: {
      ...attendance,
      currentStreak: streak,
      gymConsistencyScore,
      perDay,
      topVenues: venues,
    },
    workouts: {
      count: activityRows.length,
      totalMinutes: workoutMinutes,
      totalDistanceKm: round1(workoutDistance),
      totalCalories: activityKcal,
      estimatedCount: estimatedActivities,
      byType,
      last: lastActivity,
    },
    movement: {
      totalSteps: totSteps,
      avgDailySteps,
      loggedDays: stepDays,
      totalDistanceKm: round1(totDist),
      totalActiveBurn: burnedTotal,
      avgDailyActiveBurn,
      movementScore,
      series: movementSeries,
      lastDeviceSync: lastDevice,
    },
    caloriesBurned: {
      total: burnedTotal,
      avgPerDay: avgDailyActiveBurn,
      fromActivities: estimatedDayActivityKcal,
      fromGymVisits: checkinKcal,
      fromSteps: totStepBurn,
      fromDevice: deviceKcal,
      measuredDays,
      weightKgUsed: weightKg,
      weightSource,
      method: 'MET × weight (kg) × hours — Compendium of Physical Activities',
    },
    nutrition: {
      avgDailyCalories,
      avgDailyProtein,
      avgDailyCarbs,
      avgDailyFat,
      deficitSurplusStatus,
      mealDays,
      daysOnCalorieTarget,
      daysHitProtein,
      breakfastDays: mealRows.filter((r) => r.breakfast).length,
      avgMealsPerDay: mealDays ? round1(mealRows.reduce((a, r) => a + +r.slots, 0) / mealDays) : 0,
      series: nutritionSeries,
      baselines: {
        dailyCalories: t.calories,
        dailyProteinG: t.proteinG,
        dailyCarbsG: t.carbsG,
        dailyFatG: t.fatG,
        goalType,
        source: t.source,
      },
    },
    water,
    weight: {
      latest: latestWeight,
      changeKg: first && last ? round1(last.weightKg - first.weightKg) : null,
      series: weights,
      targetKg: userGoal ? +userGoal.targetWeightKg : null,
    },
    bmi: bmiValue == null ? null : { value: bmiValue, category: bmiCategory(bmiValue), heightCm, weightKg: bmiWeight },
    integrationArchitecture: [
      {
        source: 'Onboarding Profile',
        metric: 'Calorie & Nutrient Target Baselines',
        outcome: `${t.calories} kcal / ${t.proteinG}g protein daily benchmark`,
      },
      {
        source: 'Activity Tracker',
        metric: 'Steps, Distance (KM), Active Burn',
        outcome: `${avgDailySteps.toLocaleString('en-IN')} steps/day · Movement Score ${movementScore}/100`,
      },
      {
        source: 'FitKey Gym Check-in',
        metric: 'Attendance Logs, Session Frequency',
        outcome: `${totalCheckins} check-ins · Consistency Score ${gymConsistencyScore}/100`,
      },
      { source: 'Fuel Log (Nutrition)', metric: 'Total Calorie & Macro/Micro Intake', outcome: deficitSurplusStatus },
    ],
  });
});

export default router;

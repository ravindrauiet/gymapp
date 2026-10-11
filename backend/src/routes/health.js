import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notFound, validate } from '../utils/http.js';
import { ACTIVITY_TYPES } from '../utils/constants.js';
import { dateSchema, pagination } from '../utils/schemas.js';

/** Health / gym report (U9): weight log, activity log and an aggregated progress report. */
const router = Router();
router.use(requireAuth('user'));

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

/** GET /health/report?days=30 — attendance, workouts and weight trend for the progress screen. */
router.get('/report', async (req, res) => {
  const { days } = validate(z.object({ days: z.coerce.number().int().min(7).max(365).default(30) }), req.query);
  const params = [req.user.id, config.tz, days];
  const since = `(now() AT TIME ZONE $2)::date - $3::int`;

  const [today, attendance, perDay, allDates, venues, workouts, byType, weights] = await Promise.all([
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
  ]);

  const latestWeight = await queryOne(
    `SELECT weight_kg, logged_on FROM weight_logs WHERE user_id = $1 ORDER BY logged_on DESC LIMIT 1`,
    [req.user.id],
  );
  const first = weights[0];
  const last = weights[weights.length - 1];

  res.json({
    days,
    attendance: {
      ...attendance,
      currentStreak: currentStreak(allDates.map((r) => r.d), today.d),
      perDay,
      topVenues: venues,
    },
    workouts: { ...workouts, byType },
    weight: {
      latest: latestWeight,
      changeKg: first && last ? Math.round((last.weightKg - first.weightKg) * 10) / 10 : null,
      series: weights,
    },
  });
});

export default router;

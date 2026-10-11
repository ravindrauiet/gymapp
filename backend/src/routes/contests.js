import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, notFound, validate } from '../utils/http.js';

export const contestsRouter = Router();
export const leaderboardRouter = Router();
contestsRouter.use(requireAuth('user'));
leaderboardRouter.use(requireAuth('user'));

/**
 * Returns a SQL sub-query yielding (user_id, score) for a contest metric between the dates in
 * placeholders $startParam / $endParam (inclusive, in APP_TZ).
 */
function scoreSql(metric, startParam, endParam, tzParam) {
  switch (metric) {
    case 'checkins':
      return `SELECT user_id, COUNT(DISTINCT checkin_date)::numeric AS score
              FROM checkins WHERE checkin_date BETWEEN ${startParam} AND ${endParam} GROUP BY user_id`;
    case 'running_km':
      return `SELECT user_id, COALESCE(SUM(distance_km), 0)::numeric AS score
              FROM activity_logs
              WHERE type = 'running' AND (logged_at AT TIME ZONE ${tzParam})::date BETWEEN ${startParam} AND ${endParam}
              GROUP BY user_id`;
    case 'streak':
      // Longest run of consecutive check-in days (gaps-and-islands).
      return `SELECT user_id, MAX(run)::numeric AS score FROM (
                SELECT user_id, COUNT(*) AS run FROM (
                  SELECT user_id, d, d - (ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY d))::int AS grp
                  FROM (SELECT DISTINCT user_id, checkin_date AS d FROM checkins
                        WHERE checkin_date BETWEEN ${startParam} AND ${endParam}) days
                ) islands GROUP BY user_id, grp
              ) runs GROUP BY user_id`;
    default:
      throw new Error(`Unknown metric ${metric}`);
  }
}

const METRIC_UNITS = { checkins: 'days', running_km: 'km', streak: 'day streak' };

/** GET /contests?status=active|upcoming|past */
contestsRouter.get('/', async (req, res) => {
  const { status } = validate(z.object({ status: z.enum(['active', 'upcoming', 'past']).default('active') }), req.query);
  const condition = {
    active: `c.starts_on <= today.d AND c.ends_on >= today.d`,
    upcoming: `c.starts_on > today.d`,
    past: `c.ends_on < today.d`,
  }[status];

  const contests = await query(
    `SELECT c.*,
       (SELECT COUNT(*) FROM contest_participants cp WHERE cp.contest_id = c.id) AS participant_count,
       EXISTS (SELECT 1 FROM contest_participants cp WHERE cp.contest_id = c.id AND cp.user_id = $1) AS joined
     FROM contests c, (SELECT (now() AT TIME ZONE $2)::date AS d) today
     WHERE ${condition}
     ORDER BY ${status === 'past' ? 'c.ends_on DESC' : 'c.starts_on ASC'} LIMIT 50`,
    [req.user.id, config.tz],
  );
  res.json({ contests: contests.map((c) => ({ ...c, unit: METRIC_UNITS[c.metric] })) });
});

async function contestLeaderboard(contest, userId, city) {
  // Postgres rejects unused parameters, so the time zone ($5) is only passed for metrics that use it.
  const needsTz = contest.metric === 'running_km';
  const rows = await query(
    `WITH scores AS (${scoreSql(contest.metric, '$2::date', '$3::date', '$5')})
     SELECT u.id AS user_id, u.name, u.city, u.avatar_url, COALESCE(s.score, 0) AS score,
            RANK() OVER (ORDER BY COALESCE(s.score, 0) DESC) AS rank
     FROM contest_participants cp
     JOIN users u ON u.id = cp.user_id
     LEFT JOIN scores s ON s.user_id = cp.user_id
     WHERE cp.contest_id = $1 AND ($4::text IS NULL OR u.city ILIKE $4)
     ORDER BY rank, u.name`,
    [contest.id, contest.startsOn, contest.endsOn, city ?? null, ...(needsTz ? [config.tz] : [])],
  );
  return {
    entries: rows.slice(0, 100),
    me: rows.find((r) => r.userId === userId) ?? null,
  };
}

/** GET /contests/:id?city= — contest details + leaderboard. */
contestsRouter.get('/:id', async (req, res) => {
  const { city } = validate(z.object({ city: z.string().trim().min(1).optional() }), req.query);
  const contest = await queryOne(
    `SELECT c.*,
       EXISTS (SELECT 1 FROM contest_participants cp WHERE cp.contest_id = c.id AND cp.user_id = $2) AS joined
     FROM contests c WHERE c.id = $1`,
    [req.params.id, req.user.id],
  );
  if (!contest) throw notFound('Contest not found');
  const leaderboard = await contestLeaderboard(contest, req.user.id, city);
  res.json({ contest: { ...contest, unit: METRIC_UNITS[contest.metric] }, leaderboard });
});

contestsRouter.post('/:id/join', async (req, res) => {
  const contest = await queryOne(
    `SELECT id, ends_on, city FROM contests WHERE id = $1 AND ends_on >= (now() AT TIME ZONE $2)::date`,
    [req.params.id, config.tz],
  );
  if (!contest) throw notFound('Contest not found or already finished');
  if (contest.city) {
    const user = await queryOne(`SELECT city FROM users WHERE id = $1`, [req.user.id]);
    if (user?.city?.toLowerCase() !== contest.city.toLowerCase()) {
      throw badRequest(`This contest is only for members in ${contest.city}`);
    }
  }
  await query(`INSERT INTO contest_participants (contest_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [
    contest.id,
    req.user.id,
  ]);
  res.status(201).json({ joined: true });
});

/**
 * GET /leaderboard?period=weekly|monthly&city=
 * Overall FITKEY points for the current week/month: 10 per check-in day + 1 per km run + 5 per logged workout.
 */
leaderboardRouter.get('/', async (req, res) => {
  const { period, city } = validate(
    z.object({ period: z.enum(['weekly', 'monthly']).default('weekly'), city: z.string().trim().min(1).optional() }),
    req.query,
  );
  const unit = period === 'weekly' ? 'week' : 'month';

  const rows = await query(
    `WITH win AS (
       SELECT date_trunc($1, (now() AT TIME ZONE $2))::date AS start_d,
              (now() AT TIME ZONE $2)::date AS end_d
     ),
     points AS (
       SELECT user_id, SUM(pts) AS score FROM (
         SELECT c.user_id, 10 * COUNT(DISTINCT c.checkin_date) AS pts
         FROM checkins c, win WHERE c.checkin_date BETWEEN win.start_d AND win.end_d GROUP BY c.user_id
         UNION ALL
         SELECT a.user_id,
                ROUND(COALESCE(SUM(a.distance_km) FILTER (WHERE a.type = 'running'), 0)) + 5 * COUNT(*) AS pts
         FROM activity_logs a, win
         WHERE (a.logged_at AT TIME ZONE $2)::date BETWEEN win.start_d AND win.end_d GROUP BY a.user_id
       ) p GROUP BY user_id
     )
     SELECT u.id AS user_id, u.name, u.city, u.avatar_url, pts.score,
            RANK() OVER (ORDER BY pts.score DESC) AS rank
     FROM points pts JOIN users u ON u.id = pts.user_id
     WHERE u.role = 'user' AND ($3::text IS NULL OR u.city ILIKE $3)
     ORDER BY rank, u.name`,
    [unit, config.tz, city ?? null],
  );

  res.json({
    period,
    city: city ?? null,
    entries: rows.slice(0, 100),
    me: rows.find((r) => r.userId === req.user.id) ?? null,
    scoring: { perCheckinDay: 10, perRunningKm: 1, perWorkoutLog: 5 },
  });
});

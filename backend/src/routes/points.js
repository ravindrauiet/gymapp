import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { validate } from '../utils/http.js';
import { arenaTableExists } from './events.js';

/**
 * Trophy board (BRD §3.4): overall FitKey points, rank and badges across all activity.
 * Points: 10 per check-in day, 5 per logged workout, 1 per km run, plus AI Arena points.
 */
const router = Router();
router.use(requireAuth('user'));

export const SCORING = { perCheckinDay: 10, perWorkoutLog: 5, perRunningKm: 1, arena: 'AI Arena points as earned' };

/**
 * Ranked points for the current week / month in APP_TZ, optionally for one city.
 * Returns rows { userId, name, city, avatarUrl, score, rank, checkinDays, workouts, runningKm, arenaPoints }.
 */
export async function pointsBoard({ period, city }) {
  const unit = period === 'month' ? 'month' : 'week';
  const hasArena = await arenaTableExists();
  return query(
    `WITH win AS (
       SELECT date_trunc($1, (now() AT TIME ZONE $2))::date AS start_d, (now() AT TIME ZONE $2)::date AS end_d
     ),
     parts AS (
       SELECT c.user_id, COUNT(DISTINCT c.checkin_date) AS ci, 0::bigint AS wk, 0::numeric AS km, 0::bigint AS ar
       FROM checkins c, win WHERE c.checkin_date BETWEEN win.start_d AND win.end_d GROUP BY c.user_id
       UNION ALL
       SELECT a.user_id, 0, COUNT(*), COALESCE(SUM(a.distance_km) FILTER (WHERE a.type = 'running'), 0), 0
       FROM activity_logs a, win
       WHERE (a.logged_at AT TIME ZONE $2)::date BETWEEN win.start_d AND win.end_d GROUP BY a.user_id
       ${
         hasArena
           ? `UNION ALL
       SELECT t.user_id, 0, 0, 0, COALESCE(SUM(t.points), 0)
       FROM arena_attempts t, win
       WHERE (t.created_at AT TIME ZONE $2)::date BETWEEN win.start_d AND win.end_d GROUP BY t.user_id`
           : ''
       }
     ),
     totals AS (
       SELECT user_id, SUM(ci) AS checkin_days, SUM(wk) AS workouts, ROUND(SUM(km), 1) AS running_km, SUM(ar) AS arena_points,
              10 * SUM(ci) + 5 * SUM(wk) + FLOOR(SUM(km)) + SUM(ar) AS score
       FROM parts GROUP BY user_id
     )
     SELECT u.id AS user_id, u.name, u.city, u.avatar_url, t.score, t.checkin_days, t.workouts, t.running_km, t.arena_points,
            RANK() OVER (ORDER BY t.score DESC) AS rank
     FROM totals t JOIN users u ON u.id = t.user_id
     WHERE u.role = 'user' AND t.score > 0 AND ($3::text IS NULL OR u.city ILIKE $3)
     ORDER BY rank, u.name`,
    [unit, config.tz, city ?? null],
  );
}

const milestone = (id, title, description, icon, current, target, earnedAt = null) => ({
  id,
  title,
  description,
  icon,
  earned: current >= target,
  earnedAt: current >= target ? earnedAt : null,
  progress: Math.min(current, target),
  target,
});

/** Real, all-time badges derived from the member's own data. Earned ones first, then the next milestones. */
export async function badgesFor(userId) {
  const hasArena = await arenaTableExists();
  const [stats, orgs, arena] = await Promise.all([
    queryOne(
      `SELECT
         (SELECT COUNT(DISTINCT checkin_date) FROM checkins WHERE user_id = $1) AS checkin_days,
         (SELECT MIN(checked_in_at) FROM checkins WHERE user_id = $1) AS first_checkin,
         (SELECT COALESCE(SUM(distance_km), 0) FROM activity_logs WHERE user_id = $1 AND type = 'running') AS running_km,
         (SELECT COUNT(*) FROM activity_logs WHERE user_id = $1) AS workouts,
         (SELECT COUNT(*) FROM contest_participants WHERE user_id = $1) AS events_joined,
         (SELECT MIN(joined_at) FROM contest_participants WHERE user_id = $1) AS first_event,
         (SELECT COUNT(*) FROM contest_participants WHERE user_id = $1 AND attended_at IS NOT NULL) AS events_attended,
         (SELECT COALESCE(MAX(run), 0) FROM (
            SELECT COUNT(*) AS run FROM (
              SELECT d, d - (ROW_NUMBER() OVER (ORDER BY d))::int AS grp
              FROM (SELECT DISTINCT checkin_date AS d FROM checkins WHERE user_id = $1) days
            ) islands GROUP BY grp
          ) runs) AS best_streak`,
      [userId],
    ),
    query(
      `SELECT m.org_id, m.verified_at, o.name, o.kind FROM org_memberships m JOIN orgs o ON o.id = m.org_id
       WHERE m.user_id = $1 AND m.status = 'verified' ORDER BY m.verified_at`,
      [userId],
    ),
    hasArena
      ? queryOne(
          `SELECT COUNT(*) AS sets, MIN(created_at) AS first_at, COALESCE(SUM(points), 0) AS points
           FROM arena_attempts WHERE user_id = $1`,
          [userId],
        )
      : Promise.resolve({ sets: 0, firstAt: null, points: 0 }),
  ]);

  const badges = [
    ...orgs.map((o) => ({
      id: `org:${o.orgId}`,
      title: `${o.name} verified`,
      description: o.kind === 'college' ? 'Verified student' : 'Verified employee',
      icon: o.kind === 'college' ? 'school' : 'business',
      earned: true,
      earnedAt: o.verifiedAt,
      progress: 1,
      target: 1,
      orgId: o.orgId,
    })),
    milestone('first_checkin', 'First check-in', 'Checked in at a FitKey venue', 'login', stats.checkinDays, 1, stats.firstCheckin),
    milestone('checkins_10', '10 gym days', 'Checked in on 10 different days', 'fitness', stats.checkinDays, 10),
    milestone('checkins_50', '50 gym days', 'Checked in on 50 different days', 'fitness', stats.checkinDays, 50),
    milestone('checkins_100', 'Century club', 'Checked in on 100 different days', 'fitness', stats.checkinDays, 100),
    milestone('streak_3', '3-day streak', 'Checked in 3 days in a row', 'fire', stats.bestStreak, 3),
    milestone('streak_7', '7-day streak', 'Checked in 7 days in a row', 'fire', stats.bestStreak, 7),
    milestone('streak_30', '30-day streak', 'Checked in 30 days in a row', 'fire', stats.bestStreak, 30),
    milestone('run_10', '10 km runner', 'Logged 10 km of running', 'run', Math.floor(stats.runningKm), 10),
    milestone('run_50', '50 km runner', 'Logged 50 km of running', 'run', Math.floor(stats.runningKm), 50),
    milestone('run_100', '100 km club', 'Logged 100 km of running', 'run', Math.floor(stats.runningKm), 100),
    milestone('workouts_25', '25 workouts', 'Logged 25 workouts', 'workout', stats.workouts, 25),
    milestone('first_event', 'Event debut', 'Joined your first FitKey event', 'event', stats.eventsJoined, 1, stats.firstEvent),
    milestone('onground', 'Showed up', 'Attended an on-ground event', 'place', stats.eventsAttended, 1),
    milestone('arena_first', 'Arena debut', 'Completed a set in the AI Arena', 'arena', arena.sets, 1, arena.firstAt),
  ];
  const earned = badges.filter((b) => b.earned);
  // Only the next locked milestone of each family, so the list shows real progress rather than a wall of locks.
  const seen = new Set();
  const next = badges.filter((b) => {
    if (b.earned) return false;
    const family = b.id.replace(/_\d+$/, '');
    if (seen.has(family)) return false;
    seen.add(family);
    return true;
  });
  return { badges: [...earned, ...next], earnedCount: earned.length, arenaPointsAllTime: arena.points };
}

/** GET /points?period=week|month&city= — overall board, my rank & points breakdown, my badges. */
router.get('/', async (req, res) => {
  const { period, city } = validate(
    z.object({
      period: z
        .enum(['week', 'month', 'weekly', 'monthly'])
        .default('week')
        .transform((p) => (p.startsWith('month') ? 'month' : 'week')),
      city: z.string().trim().min(1).max(80).optional(),
    }),
    req.query,
  );
  const [rows, badges, me] = await Promise.all([
    pointsBoard({ period, city }),
    badgesFor(req.user.id),
    queryOne(`SELECT id, name, city, avatar_url FROM users WHERE id = $1`, [req.user.id]),
  ]);
  const mine = rows.find((r) => r.userId === req.user.id);
  res.json({
    period,
    city: city ?? null,
    entries: rows.slice(0, 100),
    me: mine ?? {
      userId: me.id,
      name: me.name,
      city: me.city,
      avatarUrl: me.avatarUrl,
      score: 0,
      rank: null,
      checkinDays: 0,
      workouts: 0,
      runningKm: 0,
      arenaPoints: 0,
    },
    totalRanked: rows.length,
    ...badges,
    scoring: SCORING,
  });
});

export default router;

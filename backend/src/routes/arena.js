import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notify } from '../utils/notify.js';
import { badRequest, conflict, forbidden, notFound, validate } from '../utils/http.js';
import { FILES_PATH } from './files.js';

/**
 * AI Arena (BRD §3.2). Reps are counted on-device by pose estimation; the server ranks attempts and awards points.
 *
 * Leaderboards
 *  - best:   one row per member, their best single set (max reps / seconds). Ties go to whoever set it first.
 *  - weekly: total reps (seconds for plank) this week, Monday-based in APP_TZ.
 *
 * Points (read by the overall points board from arena_attempts.points)
 *  - Each exercise has levels with points, e.g. pushups 25/50/100 reps → 10/25/60 points.
 *  - A set earns the points of the highest level its reps reach, whatever level was picked.
 *  - Per exercise per day (APP_TZ) a member can earn at most the top level's points: a set only earns the
 *    difference between its level points and what that exercise already paid today. Repeating easy sets farms nothing.
 *
 * Anti-cheat
 *  - The app only counts full-range reps; partial reps are reported separately.
 *  - Server checks: reps ≤ the exercise's plausible single-set max, reps ≤ duration × plausible rate,
 *    sets cannot overlap in time with the previous set, and submissions are rate-limited.
 *  - A set that enters the all-India top 10 is marked clip_status='pending' and the app uploads a short proof clip
 *    (or reports 'unavailable' when the device cannot record).
 */
const router = Router();
router.use(requireAuth('user'));

const EXERCISE_IDS = ['pushups', 'pullups', 'squats', 'plank', 'burpees'];
const TOP_N = 10;

const submitLimiter = rateLimit({
  windowMs: 10 * 60 * 1000,
  limit: 15,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.user.id,
  message: { error: 'Easy, champ — too many sets in a short time. Take a breather and try again in a few minutes.' },
});

const exerciseIdSchema = z.enum(EXERCISE_IDS);
const citySchema = z.object({ city: z.string().trim().min(1).max(80).optional() });

async function getExercise(id) {
  const parsed = exerciseIdSchema.safeParse(id);
  if (!parsed.success) throw notFound('Exercise not found');
  const ex = await queryOne(`SELECT * FROM arena_exercises WHERE id = $1`, [parsed.data]);
  if (!ex) throw notFound('Exercise not found');
  return ex;
}

const publicExercise = (ex) => ({
  id: ex.id,
  name: ex.name,
  unit: ex.unit,
  levels: ex.levels.map((reps, i) => ({ target: reps, points: ex.levelPoints[i] ?? 0 })),
  dailyPointsCap: Math.max(0, ...ex.levelPoints),
  tagline: ex.tagline,
  howTo: ex.howTo,
  tips: ex.tips,
});

/** SQL yielding each member's best set for $1 (exercise), with an all-India ROW_NUMBER rank. */
const BEST_SQL = `
  WITH best AS (
    SELECT DISTINCT ON (a.user_id) a.user_id, a.id AS attempt_id, a.reps, a.created_at, a.clip_url, a.clip_status,
           COALESCE(a.city, u.city) AS city
    FROM arena_attempts a JOIN users u ON u.id = a.user_id
    WHERE a.exercise_id = $1 AND u.role = 'user'
    ORDER BY a.user_id, a.reps DESC, a.created_at ASC
  )
  SELECT b.*, ROW_NUMBER() OVER (ORDER BY b.reps DESC, b.created_at ASC) AS rank FROM best b`;

/** Start of the current week (Monday 00:00 in APP_TZ) as a timestamptz expression using parameter `tzParam`. */
const weekStart = (tzParam) => `(date_trunc('week', now() AT TIME ZONE ${tzParam}) AT TIME ZONE ${tzParam})`;
const dayStart = (tzParam) => `(date_trunc('day', now() AT TIME ZONE ${tzParam}) AT TIME ZONE ${tzParam})`;

/** Stats shown on exercise cards and the detail header for one member. */
async function myStats(exerciseId, userId) {
  const row = await queryOne(
    `WITH ranked AS (${BEST_SQL})
     SELECT
       (SELECT COUNT(*) FROM ranked) AS participants,
       (SELECT reps FROM ranked WHERE rank = ${TOP_N}) AS top10_threshold,
       (SELECT reps FROM ranked WHERE user_id = $2) AS my_best,
       (SELECT rank FROM ranked WHERE user_id = $2) AS my_rank,
       (SELECT COALESCE(SUM(reps), 0) FROM arena_attempts
          WHERE exercise_id = $1 AND user_id = $2 AND created_at >= ${weekStart('$3')}) AS my_week_total,
       (SELECT COALESCE(SUM(points), 0) FROM arena_attempts
          WHERE exercise_id = $1 AND user_id = $2 AND created_at >= ${dayStart('$3')}) AS points_today,
       (SELECT COUNT(*) FROM arena_attempts WHERE exercise_id = $1 AND user_id = $2) AS my_attempts`,
    [exerciseId, userId, config.tz],
  );
  return {
    participants: row.participants,
    top10Threshold: row.top10Threshold, // null while fewer than 10 members have a set → any set qualifies
    myBest: row.myBest,
    myRank: row.myRank,
    myWeekTotal: row.myWeekTotal,
    pointsToday: row.pointsToday,
    myAttempts: row.myAttempts,
  };
}

/** Rank a set of `reps` would take on the all-India best board, and whether it would be a new board entry. */
async function wouldRank(exerciseId, userId, reps) {
  const row = await queryOne(
    `WITH ranked AS (${BEST_SQL})
     SELECT 1 + (SELECT COUNT(*) FROM ranked WHERE user_id <> $2 AND reps >= $3) AS rank,
            (SELECT reps FROM ranked WHERE user_id = $2) AS my_best`,
    [exerciseId, userId, reps],
  );
  const improves = row.myBest == null || reps > row.myBest;
  return { rank: row.rank, myBest: row.myBest, improves, qualifies: reps > 0 && improves && row.rank <= TOP_N };
}

const attemptOut = (a) => ({
  id: a.id,
  exerciseId: a.exerciseId,
  level: a.level,
  reps: a.reps,
  completed: a.completed,
  points: a.points,
  durationSec: a.durationSec,
  partialReps: a.partialReps,
  clipUrl: a.clipUrl,
  clipStatus: a.clipStatus,
  city: a.city,
  createdAt: a.createdAt,
});

/** GET /arena/exercises — all exercises with my best, my rank and board stats. */
router.get('/exercises', async (req, res) => {
  const exercises = await query(`SELECT * FROM arena_exercises WHERE id = ANY($1) ORDER BY sort, id`, [EXERCISE_IDS]);
  const out = await Promise.all(
    exercises.map(async (ex) => ({ ...publicExercise(ex), stats: await myStats(ex.id, req.user.id) })),
  );
  res.json({ exercises: out });
});

/** GET /arena/exercises/:id — exercise detail with my stats. */
router.get('/exercises/:id', async (req, res) => {
  const ex = await getExercise(req.params.id);
  res.json({ exercise: { ...publicExercise(ex), stats: await myStats(ex.id, req.user.id) } });
});

/** GET /arena/exercises/:id/leaderboard?board=best|weekly&city= */
router.get('/exercises/:id/leaderboard', async (req, res) => {
  const ex = await getExercise(req.params.id);
  const { board, city } = validate(
    citySchema.extend({ board: z.enum(['best', 'weekly']).default('best') }),
    req.query,
  );

  let rows;
  if (board === 'best') {
    // City boards re-rank members by their best set within that city; all-India rank is kept as `indiaRank`.
    rows = await query(
      `WITH ranked AS (${BEST_SQL})
       SELECT r.user_id, u.name, r.city, u.avatar_url, r.reps AS score, r.attempt_id, r.created_at AS set_at,
              r.rank AS india_rank,
              CASE WHEN r.rank <= ${TOP_N} THEN r.clip_url END AS clip_url,
              ROW_NUMBER() OVER (ORDER BY r.rank) AS rank
       FROM ranked r JOIN users u ON u.id = r.user_id
       WHERE ($2::text IS NULL OR r.city ILIKE $2)
       ORDER BY r.rank`,
      [ex.id, city ?? null],
    );
  } else {
    rows = await query(
      `WITH totals AS (
         SELECT a.user_id, SUM(a.reps)::int AS score, COUNT(*)::int AS sets, MIN(a.created_at) AS first_at
         FROM arena_attempts a
         WHERE a.exercise_id = $1 AND a.created_at >= ${weekStart('$3')}
         GROUP BY a.user_id
       )
       SELECT t.user_id, u.name, u.city, u.avatar_url, t.score, t.sets,
              RANK() OVER (ORDER BY t.score DESC) AS rank
       FROM totals t JOIN users u ON u.id = t.user_id
       WHERE u.role = 'user' AND ($2::text IS NULL OR u.city ILIKE $2)
       ORDER BY rank, t.first_at`,
      [ex.id, city ?? null, config.tz],
    );
  }

  res.json({
    board,
    city: city ?? null,
    unit: ex.unit,
    entries: rows.slice(0, 100),
    me: rows.find((r) => r.userId === req.user.id) ?? null,
    total: rows.length,
  });
});

/** GET /arena/exercises/:id/qualifies?reps=N — would a set of N enter the all-India top 10? */
router.get('/exercises/:id/qualifies', async (req, res) => {
  const ex = await getExercise(req.params.id);
  const { reps } = validate(z.object({ reps: z.coerce.number().int().min(0).max(100000) }), req.query);
  const r = await wouldRank(ex.id, req.user.id, reps);
  res.json({ reps, rank: r.rank, qualifies: r.qualifies, myBest: r.myBest, top: TOP_N });
});

const submitSchema = z.object({
  exerciseId: exerciseIdSchema,
  level: z.number().int().positive().nullable().optional(),
  reps: z.number().int().min(1, 'No reps were counted — nothing to save').max(100000),
  durationSec: z.number().int().min(3, 'That set was too short to save').max(3600),
  partialReps: z.number().int().min(0).max(100000).default(0),
});

/** POST /arena/attempts — save an AI-counted set. */
router.post('/attempts', submitLimiter, async (req, res) => {
  const body = validate(submitSchema, req.body);
  const ex = await getExercise(body.exerciseId);
  if (body.level != null && !ex.levels.includes(body.level)) throw badRequest('Unknown level for this exercise');

  // --- sanity checks against obvious cheating -------------------------------------------------------------
  const unitWord = ex.unit === 'seconds' ? 'seconds' : 'reps';
  if (body.reps > ex.maxSingle) throw badRequest(`${body.reps} ${unitWord} in one set is beyond what we can verify`);
  const allowed = ex.unit === 'seconds' ? body.durationSec + 2 : Math.ceil((ex.maxPerMin * body.durationSec) / 60) + 2;
  if (body.reps > allowed) {
    throw badRequest(`${body.reps} ${unitWord} in ${body.durationSec}s is faster than humanly plausible — set not saved`);
  }
  const last = await queryOne(
    `SELECT EXTRACT(EPOCH FROM (now() - created_at))::int AS ago FROM arena_attempts
     WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1`,
    [req.user.id],
  );
  if (last && last.ago + 5 < body.durationSec) {
    throw conflict('This set overlaps your previous one — sets must be done one after another');
  }

  // --- points: highest level reached, capped per exercise per day -----------------------------------------
  let reachedIdx = -1;
  ex.levels.forEach((target, i) => {
    if (body.reps >= target) reachedIdx = i;
  });
  const levelPoints = reachedIdx >= 0 ? ex.levelPoints[reachedIdx] ?? 0 : 0;
  const today = await queryOne(
    `SELECT COALESCE(SUM(points), 0) AS pts FROM arena_attempts
     WHERE user_id = $1 AND exercise_id = $2 AND created_at >= ${dayStart('$3')}`,
    [req.user.id, ex.id, config.tz],
  );
  const points = Math.max(0, levelPoints - today.pts);
  const completed = body.level != null ? body.reps >= body.level : reachedIdx >= 0;

  const before = await wouldRank(ex.id, req.user.id, body.reps);
  const user = await queryOne(`SELECT name, city FROM users WHERE id = $1`, [req.user.id]);

  const attempt = await queryOne(
    `INSERT INTO arena_attempts (user_id, exercise_id, level, reps, completed, points, city, duration_sec, partial_reps, clip_status)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING *`,
    [
      req.user.id,
      ex.id,
      body.level ?? null,
      body.reps,
      completed,
      points,
      user?.city ?? null,
      body.durationSec,
      body.partialReps,
      before.qualifies ? 'pending' : 'none',
    ],
  );

  const personalBest = before.improves && before.myBest != null;
  const unit = ex.unit === 'seconds' ? 's' : ' reps';
  if (before.qualifies) {
    await notify(req.user.id, {
      type: 'arena_top10',
      title: `You're #${before.rank} in India for ${ex.name}!`,
      body: `${body.reps}${unit} in one set puts you in the all-India top ${TOP_N}.`,
      data: { exerciseId: ex.id, attemptId: attempt.id },
    });
  } else if (personalBest) {
    await notify(req.user.id, {
      type: 'arena_pb',
      title: `New ${ex.name} personal best: ${body.reps}${unit}`,
      body: `You beat your previous best of ${before.myBest}${unit}. You're #${before.rank} in India.`,
      data: { exerciseId: ex.id, attemptId: attempt.id },
    });
  }

  res.status(201).json({
    attempt: attemptOut(attempt),
    pointsAwarded: points,
    levelPoints,
    // Points this exercise had already paid today (the reason pointsAwarded can be below levelPoints).
    earnedTodayBefore: today.pts,
    dailyCapReached: today.pts + points >= Math.max(0, ...ex.levelPoints),
    rank: before.improves ? before.rank : null,
    previousBest: before.myBest,
    personalBest: before.improves,
    qualifiesTop10: before.qualifies,
    clipRequired: before.qualifies,
  });
});

const clipSchema = z.union([
  z.object({ clipUrl: z.string().trim().startsWith(FILES_PATH).max(200) }),
  z.object({ unavailable: z.literal(true) }),
]);

/** POST /arena/attempts/:id/clip — attach the proof clip for a top-10 set, or report that none could be recorded. */
router.post('/attempts/:id/clip', async (req, res) => {
  if (!z.string().uuid().safeParse(req.params.id).success) throw notFound('Attempt not found');
  const body = validate(clipSchema, req.body);
  const attempt = await queryOne(
    `SELECT *, created_at > now() - interval '1 hour' AS fresh FROM arena_attempts WHERE id = $1`,
    [req.params.id],
  );
  if (!attempt) throw notFound('Attempt not found');
  if (attempt.userId !== req.user.id) throw forbidden('This is not your set');
  if (attempt.clipStatus === 'uploaded') throw conflict('A clip is already attached to this set');
  if (!attempt.fresh) throw badRequest('Clips can only be attached within an hour of the set');

  let updated;
  if ('clipUrl' in body) {
    const fileId = body.clipUrl.slice(FILES_PATH.length);
    if (!z.string().uuid().safeParse(fileId).success) throw badRequest('Invalid clip url');
    const file = await queryOne(`SELECT owner_id, mime FROM files WHERE id = $1`, [fileId]);
    if (!file || file.ownerId !== req.user.id) throw badRequest('Upload the clip first');
    if (file.mime !== 'video/mp4') throw badRequest('The clip must be an mp4 video');
    updated = await queryOne(
      `UPDATE arena_attempts SET clip_url = $2, clip_status = 'uploaded' WHERE id = $1 RETURNING *`,
      [attempt.id, body.clipUrl],
    );
  } else {
    updated = await queryOne(
      `UPDATE arena_attempts SET clip_status = 'unavailable' WHERE id = $1 RETURNING *`,
      [attempt.id],
    );
  }
  res.json({ attempt: attemptOut(updated) });
});

/** GET /arena/attempts/me?exerciseId=&limit=&before= — my history, newest first. */
router.get('/attempts/me', async (req, res) => {
  const q = validate(
    z.object({
      exerciseId: exerciseIdSchema.optional(),
      limit: z.coerce.number().int().min(1).max(100).default(30),
      before: z.string().datetime({ offset: true }).optional(),
    }),
    req.query,
  );
  const rows = await query(
    `SELECT * FROM arena_attempts
     WHERE user_id = $1 AND ($2::text IS NULL OR exercise_id = $2) AND ($3::timestamptz IS NULL OR created_at < $3)
     ORDER BY created_at DESC LIMIT $4`,
    [req.user.id, q.exerciseId ?? null, q.before ?? null, q.limit],
  );
  res.json({ attempts: rows.map(attemptOut) });
});

export default router;

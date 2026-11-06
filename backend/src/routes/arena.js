import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notify } from '../utils/notify.js';
import { badRequest, conflict, forbidden, notFound, validate } from '../utils/http.js';
import { creditCoins } from '../utils/wallet.js';
import { FILES_PATH } from './files.js';

/**
 * ProveIt — "Only real reps count" (BRD §1; formerly "ProveIt", internal ids /arena and arena_* are kept).
 * Reps are counted on-device by pose estimation; the server ranks sets and awards badges, points and coins.
 *
 * Modes
 *  - levels:    pick a target (25/50/100 reps, plank 30/60/120 s). Completing it earns level points (capped per
 *               exercise per day) and, the FIRST time per exercise + level, a badge and ProveIt coins (10/25/50,
 *               arena_exercises.level_coins). Levels sets never affect rank.
 *  - unlimited: one continuous set with no target (the app ends it 5 s after the last rep / when a plank breaks).
 *               Earns no points or coins: it is only for the All India Rank.
 *
 * All India Rank (AIR): each member's best single UNLIMITED set (ties: whoever set it first). City rank = the same
 * board filtered to the member's city. Weekly board: total unlimited reps this week (Monday-based, APP_TZ).
 *
 * Coins go through utils/wallet.js creditCoins (idempotent per ref). If the wallet is unavailable (e.g. 501 while
 * it is being built) the badge is stored with coins_status='pending' and the credit is retried on later requests.
 *
 * Anti-cheat: the app only counts full-range reps; the server checks plausible single-set max and rate, that sets
 * do not overlap in time, rate-limits submissions, and asks for a proof clip for new all-India top-10 sets.
 */
const router = Router();
router.use(requireAuth('user'));

const EXERCISE_IDS = ['pushups', 'pullups', 'squats', 'plank', 'burpees']; // burpees: data kept, hidden in v1
const MODES = ['levels', 'unlimited'];
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
  if (!parsed.success) throw notFound('Challenge not found');
  const ex = await queryOne(`SELECT * FROM arena_exercises WHERE id = $1 AND active IS NOT FALSE`, [parsed.data]);
  if (!ex) throw notFound('This ProveIt challenge is not available');
  return ex;
}

const levelCoins = (ex, i) => (ex.levelCoins ?? [10, 25, 50])[i] ?? 0;

const publicExercise = (ex, badges = []) => ({
  id: ex.id,
  name: ex.name,
  unit: ex.unit,
  levels: ex.levels.map((target, i) => {
    const b = badges.find((x) => x.exerciseId === ex.id && x.levelNo === i + 1);
    return {
      level: i + 1,
      target,
      points: ex.levelPoints[i] ?? 0,
      coins: levelCoins(ex, i),
      badge: b ? { earnedAt: b.createdAt, coins: b.coins, coinsStatus: b.coinsStatus } : null,
    };
  }),
  dailyPointsCap: Math.max(0, ...ex.levelPoints),
  tagline: ex.tagline,
  howTo: ex.howTo,
  tips: ex.tips,
});

/** Each member's best UNLIMITED set for $1 (exercise) with the all-India ROW_NUMBER rank. */
const BEST_SQL = `
  WITH best AS (
    SELECT DISTINCT ON (a.user_id) a.user_id, a.id AS attempt_id, a.reps, a.created_at, a.clip_url, a.clip_status,
           COALESCE(a.city, u.city) AS city
    FROM arena_attempts a JOIN users u ON u.id = a.user_id
    WHERE a.exercise_id = $1 AND a.mode = 'unlimited' AND u.role = 'user'
    ORDER BY a.user_id, a.reps DESC, a.created_at ASC
  )
  SELECT b.*, ROW_NUMBER() OVER (ORDER BY b.reps DESC, b.created_at ASC) AS rank,
         ROW_NUMBER() OVER (PARTITION BY lower(b.city) ORDER BY b.reps DESC, b.created_at ASC) AS city_rank
  FROM best b`;

const weekStart = (tzParam) => `(date_trunc('week', now() AT TIME ZONE ${tzParam}) AT TIME ZONE ${tzParam})`;
const dayStart = (tzParam) => `(date_trunc('day', now() AT TIME ZONE ${tzParam}) AT TIME ZONE ${tzParam})`;

/** Stats shown on challenge cards and the detail header for one member. */
async function myStats(exerciseId, userId) {
  const row = await queryOne(
    `WITH ranked AS (${BEST_SQL}), me AS (SELECT * FROM ranked WHERE user_id = $2),
          my_city AS (SELECT COALESCE((SELECT city FROM me), (SELECT city FROM users WHERE id = $2)) AS city)
     SELECT
       (SELECT COUNT(*) FROM ranked) AS participants,
       (SELECT reps FROM ranked WHERE rank = ${TOP_N}) AS top10_threshold,
       (SELECT reps FROM me) AS my_best,
       (SELECT rank FROM me) AS my_rank,
       (SELECT city_rank FROM me) AS my_city_rank,
       (SELECT city FROM my_city) AS my_city,
       (SELECT COUNT(*) FROM ranked WHERE lower(city) = lower((SELECT city FROM my_city))) AS city_participants,
       (SELECT MAX(reps) FROM arena_attempts WHERE exercise_id = $1 AND user_id = $2 AND mode = 'levels') AS levels_best,
       (SELECT COALESCE(SUM(reps), 0) FROM arena_attempts
          WHERE exercise_id = $1 AND user_id = $2 AND mode = 'unlimited' AND created_at >= ${weekStart('$3')}) AS my_week_total,
       (SELECT COALESCE(SUM(points), 0) FROM arena_attempts
          WHERE exercise_id = $1 AND user_id = $2 AND created_at >= ${dayStart('$3')}) AS points_today,
       (SELECT COUNT(*) FROM arena_attempts WHERE exercise_id = $1 AND user_id = $2) AS my_attempts`,
    [exerciseId, userId, config.tz],
  );
  return {
    participants: row.participants,
    top10Threshold: row.top10Threshold, // null while fewer than 10 members have a set → any set qualifies
    myBest: row.myBest, // best unlimited set = the score behind the AIR
    myRank: row.myRank, // All India Rank
    myCityRank: row.myCityRank,
    myCity: row.myCity,
    cityParticipants: row.cityParticipants,
    levelsBest: row.levelsBest,
    myWeekTotal: row.myWeekTotal,
    pointsToday: row.pointsToday,
    myAttempts: row.myAttempts,
  };
}

/** AIR a set of `reps` would take, and whether it would be a new board entry for this member. */
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

async function myBadges(userId) {
  return query(
    `SELECT exercise_id, level_no, target, attempt_id, coins, coins_status, created_at FROM proveit_badges
     WHERE user_id = $1 ORDER BY created_at DESC`,
    [userId],
  );
}

/**
 * Credits coins for badges still marked 'pending' (wallet unavailable when earned). Never throws: a wallet error
 * just leaves the badge pending for the next try. Returns the number of coins credited now.
 */
async function settlePendingCoins(userId) {
  const pending = await query(
    `SELECT b.exercise_id, b.level_no, b.coins, e.name FROM proveit_badges b
     JOIN arena_exercises e ON e.id = b.exercise_id
     WHERE b.user_id = $1 AND b.coins_status = 'pending'`,
    [userId],
  );
  let credited = 0;
  for (const b of pending) {
    try {
      await withTransaction(async (client) => {
        if (b.coins > 0) {
          await creditCoins(client, userId, b.coins, {
            kind: 'proveit',
            ref: `proveit:${userId}:${b.exerciseId}:L${b.levelNo}`,
            title: `ProveIt badge: ${b.name} level ${b.levelNo}`,
          });
        }
        await client.query(
          `UPDATE proveit_badges SET coins_status = $4 WHERE user_id = $1 AND exercise_id = $2 AND level_no = $3`,
          [userId, b.exerciseId, b.levelNo, b.coins > 0 ? 'credited' : 'none'],
        );
      });
      credited += b.coins;
    } catch (e) {
      if (e?.status !== 501) console.warn('ProveIt: coin credit failed, will retry', e?.message ?? e);
      break; // wallet not available: try again on a later request
    }
  }
  return credited;
}

const attemptOut = (a) => ({
  id: a.id,
  exerciseId: a.exerciseId,
  mode: a.mode,
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

const activeExercises = () =>
  query(`SELECT * FROM arena_exercises WHERE id = ANY($1) AND active IS NOT FALSE ORDER BY sort, id`, [EXERCISE_IDS]);

/** GET /arena/exercises — the v1 challenges with my AIR, city rank, best, and level badges. */
router.get('/exercises', async (req, res) => {
  await settlePendingCoins(req.user.id);
  const [exercises, badges] = await Promise.all([activeExercises(), myBadges(req.user.id)]);
  const out = await Promise.all(
    exercises.map(async (ex) => ({ ...publicExercise(ex, badges), stats: await myStats(ex.id, req.user.id) })),
  );
  res.json({ exercises: out });
});

/** GET /arena/exercises/:id — challenge detail with my stats. */
router.get('/exercises/:id', async (req, res) => {
  const ex = await getExercise(req.params.id);
  const badges = await myBadges(req.user.id);
  res.json({ exercise: { ...publicExercise(ex, badges), stats: await myStats(ex.id, req.user.id) } });
});

/** GET /arena/me — my ProveIt summary: badges, coins from ProveIt, AIR per challenge. */
router.get('/me', async (req, res) => {
  await settlePendingCoins(req.user.id);
  const [exercises, badges] = await Promise.all([activeExercises(), myBadges(req.user.id)]);
  const names = Object.fromEntries(exercises.map((e) => [e.id, e]));
  const ranks = await Promise.all(
    exercises.map(async (ex) => {
      const s = await myStats(ex.id, req.user.id);
      return { exerciseId: ex.id, name: ex.name, unit: ex.unit, best: s.myBest, rank: s.myRank, cityRank: s.myCityRank,
        city: s.myCity, participants: s.participants };
    }),
  );
  const visible = badges.filter((b) => names[b.exerciseId]);
  res.json({
    badges: visible.map((b) => ({
      exerciseId: b.exerciseId,
      name: names[b.exerciseId].name,
      unit: names[b.exerciseId].unit,
      level: b.levelNo,
      target: b.target,
      coins: b.coins,
      coinsStatus: b.coinsStatus,
      earnedAt: b.createdAt,
    })),
    coinsEarned: visible.filter((b) => b.coinsStatus === 'credited').reduce((s, b) => s + b.coins, 0),
    coinsPending: visible.filter((b) => b.coinsStatus === 'pending').reduce((s, b) => s + b.coins, 0),
    badgesTotal: exercises.reduce((s, e) => s + e.levels.length, 0),
    ranks,
  });
});

/** GET /arena/exercises/:id/cities — cities on this AIR board, most members first (for the city filter). */
router.get('/exercises/:id/cities', async (req, res) => {
  const ex = await getExercise(req.params.id);
  const rows = await query(
    `WITH ranked AS (${BEST_SQL})
     SELECT initcap(lower(city)) AS city, COUNT(*)::int AS members FROM ranked
     WHERE city IS NOT NULL AND city <> '' GROUP BY lower(city) ORDER BY members DESC, lower(city) LIMIT 30`,
    [ex.id],
  );
  res.json({ cities: rows });
});

/** GET /arena/exercises/:id/leaderboard?board=best|weekly&city= — Unlimited sets only. */
router.get('/exercises/:id/leaderboard', async (req, res) => {
  const ex = await getExercise(req.params.id);
  const { board, city } = validate(
    citySchema.extend({ board: z.enum(['best', 'weekly']).default('best') }),
    req.query,
  );

  let rows;
  if (board === 'best') {
    // City boards re-rank members by their best set within that city; the All India Rank is kept as `indiaRank`.
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
         WHERE a.exercise_id = $1 AND a.mode = 'unlimited' AND a.created_at >= ${weekStart('$3')}
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

/** GET /arena/exercises/:id/qualifies?reps=N — would an Unlimited set of N enter the all-India top 10? */
router.get('/exercises/:id/qualifies', async (req, res) => {
  const ex = await getExercise(req.params.id);
  const { reps } = validate(z.object({ reps: z.coerce.number().int().min(0).max(100000) }), req.query);
  const r = await wouldRank(ex.id, req.user.id, reps);
  res.json({ reps, rank: r.rank, qualifies: r.qualifies, myBest: r.myBest, top: TOP_N });
});

const submitSchema = z
  .object({
    exerciseId: exerciseIdSchema,
    mode: z.enum(MODES).default('levels'),
    level: z.number().int().positive().nullable().optional(), // the level's target (reps / seconds)
    reps: z.number().int().min(1, 'No reps were counted — nothing to save').max(100000),
    durationSec: z.number().int().min(3, 'That set was too short to save').max(3600),
    partialReps: z.number().int().min(0).max(100000).default(0),
  })
  .refine((b) => b.mode !== 'levels' || b.level != null, { message: 'Pick a level for a Levels challenge', path: ['level'] })
  .refine((b) => b.mode !== 'unlimited' || b.level == null, { message: 'Unlimited sets have no level', path: ['level'] });

/** POST /arena/attempts — save an AI-counted set. */
router.post('/attempts', submitLimiter, async (req, res) => {
  const body = validate(submitSchema, req.body);
  const ex = await getExercise(body.exerciseId);
  const levelIdx = body.level == null ? -1 : ex.levels.indexOf(body.level);
  if (body.mode === 'levels' && levelIdx < 0) throw badRequest('Unknown level for this challenge');

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

  const unlimited = body.mode === 'unlimited';
  const completed = !unlimited && body.reps >= body.level;

  // --- points (Levels only): highest level reached, capped per exercise per day -----------------------------
  let reachedIdx = -1;
  if (!unlimited) {
    ex.levels.forEach((target, i) => {
      if (body.reps >= target) reachedIdx = i;
    });
  }
  const levelPoints = reachedIdx >= 0 ? ex.levelPoints[reachedIdx] ?? 0 : 0;
  const today = await queryOne(
    `SELECT COALESCE(SUM(points), 0) AS pts FROM arena_attempts
     WHERE user_id = $1 AND exercise_id = $2 AND created_at >= ${dayStart('$3')}`,
    [req.user.id, ex.id, config.tz],
  );
  const points = Math.max(0, levelPoints - today.pts);

  const before = unlimited ? await wouldRank(ex.id, req.user.id, body.reps) : null;
  const user = await queryOne(`SELECT name, city FROM users WHERE id = $1`, [req.user.id]);

  const attempt = await queryOne(
    `INSERT INTO arena_attempts (user_id, exercise_id, mode, level, reps, completed, points, city, duration_sec,
                                 partial_reps, clip_status)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING *`,
    [
      req.user.id,
      ex.id,
      body.mode,
      body.level ?? null,
      body.reps,
      completed,
      points,
      user?.city ?? null,
      body.durationSec,
      body.partialReps,
      before?.qualifies ? 'pending' : 'none',
    ],
  );

  // --- badge + coins: first completion of this exercise + level -------------------------------------------
  let badge = null;
  if (completed) {
    const coins = levelCoins(ex, levelIdx);
    const row = await queryOne(
      `INSERT INTO proveit_badges (user_id, exercise_id, level_no, target, attempt_id, coins, coins_status)
       VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT DO NOTHING RETURNING *`,
      [req.user.id, ex.id, levelIdx + 1, body.level, attempt.id, coins, coins > 0 ? 'pending' : 'none'],
    );
    if (row) {
      await settlePendingCoins(req.user.id);
      const now = await queryOne(
        `SELECT coins, coins_status FROM proveit_badges WHERE user_id = $1 AND exercise_id = $2 AND level_no = $3`,
        [req.user.id, ex.id, levelIdx + 1],
      );
      badge = { level: levelIdx + 1, target: body.level, coins: now.coins, coinsStatus: now.coinsStatus };
      await notify(req.user.id, {
        type: 'arena_badge',
        title: `ProveIt badge unlocked: ${ex.name} level ${levelIdx + 1}`,
        body:
          coins > 0
            ? now.coinsStatus === 'credited'
              ? `${body.level}${ex.unit === 'seconds' ? 's' : ' reps'} done — +${coins} ProveIt coins added to your wallet.`
              : `${body.level}${ex.unit === 'seconds' ? 's' : ' reps'} done — your ${coins} ProveIt coins will be added shortly.`
            : `${body.level}${ex.unit === 'seconds' ? 's' : ' reps'} done. Only real reps count!`,
        data: { exerciseId: ex.id, attemptId: attempt.id },
      });
    }
  }

  // --- rank notifications (Unlimited only) ------------------------------------------------------------------
  const unit = ex.unit === 'seconds' ? 's' : ' reps';
  if (before?.qualifies) {
    await notify(req.user.id, {
      type: 'arena_top10',
      title: `ProveIt: you're AIR #${before.rank} for ${ex.name}!`,
      body: `${body.reps}${unit} in one set puts you in the All India top ${TOP_N}.`,
      data: { exerciseId: ex.id, attemptId: attempt.id },
    });
  } else if (before?.improves && before.myBest != null) {
    await notify(req.user.id, {
      type: 'arena_pb',
      title: `ProveIt: new ${ex.name} best — ${body.reps}${unit}`,
      body: `You beat your previous best of ${before.myBest}${unit}. Your All India Rank is now #${before.rank}.`,
      data: { exerciseId: ex.id, attemptId: attempt.id },
    });
  }

  const after = unlimited ? await myStats(ex.id, req.user.id) : null;
  res.status(201).json({
    attempt: attemptOut(attempt),
    mode: body.mode,
    pointsAwarded: points,
    levelPoints,
    earnedTodayBefore: today.pts,
    dailyCapReached: !unlimited && today.pts + points >= Math.max(0, ...ex.levelPoints),
    badge, // new badge from this set (Levels), with coins and whether they are credited yet
    rank: before?.improves ? before.rank : null, // AIR of this set when it became my best (Unlimited)
    myRank: after?.myRank ?? null,
    myCityRank: after?.myCityRank ?? null,
    myCity: after?.myCity ?? null,
    previousBest: before?.myBest ?? null,
    personalBest: Boolean(before?.improves),
    qualifiesTop10: Boolean(before?.qualifies),
    clipRequired: Boolean(before?.qualifies),
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

/** GET /arena/attempts/me?exerciseId=&mode=&limit=&before= — my history, newest first. */
router.get('/attempts/me', async (req, res) => {
  const q = validate(
    z.object({
      exerciseId: exerciseIdSchema.optional(),
      mode: z.enum(MODES).optional(),
      limit: z.coerce.number().int().min(1).max(100).default(30),
      before: z.string().datetime({ offset: true }).optional(),
    }),
    req.query,
  );
  const rows = await query(
    `SELECT a.* FROM arena_attempts a JOIN arena_exercises e ON e.id = a.exercise_id
     WHERE a.user_id = $1 AND e.active IS NOT FALSE AND ($2::text IS NULL OR a.exercise_id = $2)
       AND ($3::text IS NULL OR a.mode = $3) AND ($4::timestamptz IS NULL OR a.created_at < $4)
     ORDER BY a.created_at DESC LIMIT $5`,
    [req.user.id, q.exerciseId ?? null, q.mode ?? null, q.before ?? null, q.limit],
  );
  res.json({ attempts: rows.map(attemptOut) });
});

export default router;

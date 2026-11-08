import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notFound, validate } from '../utils/http.js';
import { uuidSchema } from '../utils/schemas.js';

/**
 * Move tracker + contacts.
 *  POST   /activity/tracks           save a finished walk / run / ride / travel (route recorded on the phone)
 *  GET    /activity/tracks?days=30   tracks with their routes (for the "area you covered" map)
 *  GET    /activity/summary?days=30  totals per mode + per day
 *  DELETE /activity/tracks/:id
 *  POST   /activity/contacts/match   {hashes: [sha256(last 10 digits)]} → which contacts are already on FITKEY
 */
const router = Router();
router.use(requireAuth('user'));

const point = z.tuple([z.number().min(-90).max(90), z.number().min(-180).max(180)]);
const trackSchema = z.object({
  startedAt: z.string().datetime({ offset: true }),
  endedAt: z.string().datetime({ offset: true }),
  mode: z.enum(['walk', 'run', 'cycle', 'travel']).default('walk'),
  distanceM: z.number().min(0).max(2_000_000),
  durationS: z.number().int().min(0).max(86_400 * 2),
  movingS: z.number().int().min(0).max(86_400 * 2).default(0),
  steps: z.number().int().min(0).max(200_000).default(0),
  areaM2: z.number().min(0).max(1e11).default(0),
  maxSpeedMs: z.number().min(0).max(400).optional(),
  path: z.array(point).max(5000).default([]),
});

const COLS = `id, started_at, ended_at, mode, distance_m, duration_s, moving_s, steps, area_m2, max_speed_ms,
  min_lat, min_lng, max_lat, max_lng, created_at`;

router.post('/tracks', async (req, res) => {
  const t = validate(trackSchema, req.body);
  const lats = t.path.map((p) => p[0]);
  const lngs = t.path.map((p) => p[1]);
  const bbox = t.path.length
    ? [Math.min(...lats), Math.min(...lngs), Math.max(...lats), Math.max(...lngs)]
    : [null, null, null, null];
  const track = await queryOne(
    `INSERT INTO activity_tracks (user_id, started_at, ended_at, mode, distance_m, duration_s, moving_s, steps, area_m2,
       max_speed_ms, path, min_lat, min_lng, max_lat, max_lng)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb,$12,$13,$14,$15)
     RETURNING ${COLS}, path`,
    [req.user.id, t.startedAt, t.endedAt, t.mode, Math.round(t.distanceM), t.durationS, t.movingS, t.steps, t.areaM2,
      t.maxSpeedMs ?? null, JSON.stringify(t.path), ...bbox],
  );
  res.status(201).json({ track });
});

router.get('/tracks', async (req, res) => {
  const { days, withPath } = validate(
    z.object({
      days: z.coerce.number().int().min(1).max(365).default(30),
      withPath: z.enum(['true', 'false']).default('true'),
    }),
    req.query,
  );
  const tracks = await query(
    `SELECT ${COLS}${withPath === 'true' ? ', path' : ''} FROM activity_tracks
      WHERE user_id = $1 AND started_at >= now() - make_interval(days => $2)
      ORDER BY started_at DESC LIMIT 500`,
    [req.user.id, days],
  );
  res.json({ tracks });
});

router.get('/summary', async (req, res) => {
  const { days } = validate(z.object({ days: z.coerce.number().int().min(1).max(365).default(30) }), req.query);
  const [byMode, byDay] = await Promise.all([
    query(
      `SELECT mode, COUNT(*)::int AS tracks, COALESCE(SUM(distance_m),0)::int AS distance_m,
              COALESCE(SUM(duration_s),0)::int AS duration_s, COALESCE(SUM(area_m2),0)::float AS area_m2
         FROM activity_tracks WHERE user_id = $1 AND started_at >= now() - make_interval(days => $2)
        GROUP BY mode`,
      [req.user.id, days],
    ),
    query(
      `SELECT to_char((started_at AT TIME ZONE $3)::date, 'YYYY-MM-DD') AS day, COALESCE(SUM(distance_m),0)::int AS distance_m
         FROM activity_tracks WHERE user_id = $1 AND started_at >= now() - make_interval(days => $2)
        GROUP BY 1 ORDER BY 1`,
      [req.user.id, days, config.tz],
    ),
  ]);
  const totalDistanceM = byMode.reduce((s, m) => s + Number(m.distanceM), 0);
  res.json({ days, totalDistanceM, byMode, byDay });
});

router.delete('/tracks/:id', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const row = await queryOne(`DELETE FROM activity_tracks WHERE id = $1 AND user_id = $2 RETURNING id`, [id, req.user.id]);
  if (!row) throw notFound('Track not found');
  res.json({ deleted: true });
});

// Phone numbers never leave the device in plain text: the app sends SHA-256 (hex) of each number's last 10 digits.
const PHONE_HASH = `encode(digest(right(regexp_replace(u.phone, '[^0-9]', '', 'g'), 10), 'sha256'), 'hex')`;

router.post('/contacts/match', async (req, res) => {
  const { hashes } = validate(
    z.object({ hashes: z.array(z.string().regex(/^[0-9a-f]{64}$/)).max(3000) }),
    req.body,
  );
  if (!hashes.length) return res.json({ matches: [] });
  const matches = await query(
    `SELECT u.id, u.name, u.avatar_url, u.city, ${PHONE_HASH} AS hash
       FROM users u
      WHERE u.role = 'user' AND u.id <> $1
        AND ${PHONE_HASH} = ANY($2)
        AND NOT EXISTS (SELECT 1 FROM user_blocks b WHERE (b.blocker_id = $1 AND b.blocked_id = u.id)
                                                   OR (b.blocker_id = u.id AND b.blocked_id = $1))
      LIMIT 500`,
    [req.user.id, hashes],
  );
  res.json({ matches });
});

export default router;

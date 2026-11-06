import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../db/index.js';
import { importYoutube, refreshYoutubeDetails, rowsFromFile, rowsFromText } from '../db/importYoutube.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, conflict, notFound, validate } from '../utils/http.js';
import { VIDEO_CATEGORIES, VIDEO_CATEGORY_IDS } from '../utils/constants.js';
import { pagination } from '../utils/schemas.js';

const router = Router();
router.use(requireAuth());

const LEVELS = ['beginner', 'intermediate', 'advanced'];
const EQUIPMENT = ['none', 'dumbbells', 'gym'];
/**
 * Duration buckets for the Studio filter: "10 min" (≤15), "20 min" (16–25), "30+ min" (>25).
 * Videos whose duration is unknown (NULL) match none of them — they are never treated as 0 minutes.
 */
const DURATIONS = {
  10: 'duration_seconds <= 900',
  20: 'duration_seconds > 900 AND duration_seconds <= 1500',
  30: 'duration_seconds > 1500',
};
const durationBucket = (secs) => (secs == null ? null : secs <= 900 ? '10' : secs <= 1500 ? '20' : '30');

/** Primary group for rows created before 060_studio (old clients / old admin form only set `category`). */
const PRIMARY_GROUP = `COALESCE(v.group_key, CASE v.category WHEN 'yoga' THEN 'yoga_mind' WHEN 'dance' THEN 'dance_cardio'
  WHEN 'boxing' THEN 'martial_arts' WHEN 'martial_arts' THEN 'martial_arts' ELSE 'gym' END)`;

/** YouTube id of a row: the stored one (importer), else parsed from video_url (videos added through the admin form). */
const YT_ID = `COALESCE(v.youtube_id,
  substring(v.video_url FROM '(?:youtu\\.be/|[?&]v=|/embed/|/shorts/|/live/)([A-Za-z0-9_-]{11})'))`;

/**
 * Published videos with their resolved groups (primary group + groups of every type) and a search haystack
 * (title, trainer, channel, description, category, level, equipment, group and type labels).
 * When no trainer is known the YouTube channel is credited as the trainer (cards, player, trainer filter).
 */
const STUDIO_VIDEOS = `
  SELECT v.id, v.category, v.title, v.description, COALESCE(v.trainer_name, v.channel_name) AS trainer_name, v.level,
         v.video_url,
         COALESCE(v.thumbnail_url,
                  CASE WHEN ${YT_ID} IS NOT NULL THEN 'https://i.ytimg.com/vi/' || ${YT_ID} || '/hqdefault.jpg' END)
           AS thumbnail_url,
         v.duration_seconds, v.created_at, ${PRIMARY_GROUP} AS group_key, pg.label AS group_label, v.types,
         v.equipment,
         CASE WHEN ${YT_ID} IS NOT NULL THEN 'youtube' ELSE v.source END AS source, ${YT_ID} AS youtube_id,
         v.channel_name, v.channel_url, v.playlist_title,
         ARRAY(SELECT DISTINCT x FROM unnest(COALESCE(tg.groups, '{}') || ${PRIMARY_GROUP}::text) x) AS groups,
         lower(concat_ws(' ', v.title, v.trainer_name, v.channel_name, v.description, v.category, v.level, v.equipment,
                         pg.label, tg.labels)) AS haystack
  FROM videos v
  LEFT JOIN video_groups pg ON pg.key = ${PRIMARY_GROUP}
  LEFT JOIN LATERAL (
    SELECT array_agg(t.group_key)::text[] AS groups, string_agg(t.label || ' ' || g.label, ' ') AS labels
    FROM video_types t JOIN video_groups g ON g.key = t.group_key
    WHERE t.key = ANY(v.types)
  ) tg ON true
  WHERE v.is_published`;

const VIDEO_COLUMNS = `id, category, title, description, trainer_name, level, video_url, thumbnail_url, duration_seconds,
  created_at, group_key, group_label, types, equipment, groups, source, youtube_id, channel_name, channel_url,
  playlist_title`;

/** Escapes LIKE wildcards in user input. */
const likeEscape = (s) => s.replace(/[\\%_]/g, (c) => `\\${c}`);

/** GET /videos/categories — legacy Studio categories with video counts (kept for old clients). */
router.get('/categories', async (_req, res) => {
  const counts = await query(
    `SELECT category, COUNT(*) AS count FROM videos WHERE is_published GROUP BY category`,
  );
  const byId = Object.fromEntries(counts.map((c) => [c.category, c.count]));
  res.json({ categories: VIDEO_CATEGORIES.map((c) => ({ ...c, count: byId[c.id] ?? 0 })) });
});

/**
 * GET /videos/groups — BRD §7 Studio categories. Only groups (and types) with at least one published video,
 * each with the filter values that actually exist inside it (levels, duration buckets, equipment, trainers).
 */
router.get('/groups', async (_req, res) => {
  const [groups, types, videos] = await Promise.all([
    query(`SELECT key, label FROM video_groups ORDER BY sort_order, label`),
    query(`SELECT key, group_key, label FROM video_types ORDER BY sort_order, label`),
    query(`SELECT id, level, duration_seconds, equipment, trainer_name, types, groups FROM (${STUDIO_VIDEOS}) s`),
  ]);

  const out = [];
  for (const g of groups) {
    const inGroup = videos.filter((v) => v.groups.includes(g.key));
    if (!inGroup.length) continue;
    const groupTypes = types
      .filter((t) => t.groupKey === g.key)
      .map((t) => ({ key: t.key, label: t.label, count: inGroup.filter((v) => v.types.includes(t.key)).length }))
      .filter((t) => t.count > 0);
    const distinct = (pick, order) => {
      const set = [...new Set(inGroup.map(pick).filter((x) => x != null && x !== ''))];
      return order ? order.filter((o) => set.includes(o)) : set.sort((a, b) => a.localeCompare(b));
    };
    out.push({
      key: g.key,
      label: g.label,
      count: inGroup.length,
      types: groupTypes,
      filters: {
        levels: distinct((v) => v.level, LEVELS),
        durations: distinct((v) => durationBucket(v.durationSeconds), ['10', '20', '30']),
        equipment: distinct((v) => v.equipment, EQUIPMENT),
        trainers: distinct((v) => v.trainerName),
      },
    });
  }
  res.json({ groups: out, total: videos.length });
});

/**
 * GET /videos?q=&group=&type=&level=&duration=10|20|30&equipment=&trainer=&category=
 * q searches title, trainer, channel, description and category/type names (every word must match; typo-tolerant on
 * titles). trainer matches the trainer, or the YouTube channel when no trainer is set.
 */
router.get('/', async (req, res) => {
  const f = validate(
    z.object({
      q: z.string().trim().max(80).optional(),
      category: z.enum(VIDEO_CATEGORY_IDS).optional(),
      group: z.string().trim().max(30).optional(),
      type: z.string().trim().max(40).optional(),
      level: z.enum(LEVELS).optional(),
      duration: z.enum(['10', '20', '30']).optional(),
      equipment: z.enum(EQUIPMENT).optional(),
      trainer: z.string().trim().max(200).optional(),
      ...pagination,
    }),
    req.query,
  );

  const where = [];
  const params = [];
  const p = (value) => {
    params.push(value);
    return `$${params.length}`;
  };
  if (f.category) where.push(`category = ${p(f.category)}`);
  if (f.group) where.push(`${p(f.group)} = ANY(groups)`);
  if (f.type) where.push(`${p(f.type)} = ANY(types)`);
  if (f.level) where.push(`level = ${p(f.level)}`);
  if (f.equipment) where.push(`equipment = ${p(f.equipment)}`);
  if (f.trainer) where.push(`lower(trainer_name) = lower(${p(f.trainer)})`);
  if (f.duration) where.push(DURATIONS[f.duration]);

  let order = 'created_at DESC';
  const q = f.q?.toLowerCase();
  if (q) {
    const words = q.split(/\s+/).filter(Boolean).slice(0, 6);
    const all = words.map((w) => `haystack LIKE ${p(`%${likeEscape(w)}%`)}`).join(' AND ');
    const qp = p(q);
    where.push(`((${all}) OR word_similarity(${qp}, lower(title || ' ' || coalesce(trainer_name, ''))) >= 0.5)`);
    order = `(lower(title) LIKE ${p(`%${likeEscape(q)}%`)}) DESC,
             word_similarity(${qp}, lower(title || ' ' || coalesce(trainer_name, ''))) DESC, created_at DESC`;
  }

  const videos = await query(
    `SELECT ${VIDEO_COLUMNS} FROM (${STUDIO_VIDEOS}) s
     ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
     ORDER BY ${order} LIMIT ${p(f.limit)} OFFSET ${p((f.page - 1) * f.limit)}`,
    params,
  );
  res.json({ videos, page: f.page, limit: f.limit });
});

// -------------------------------------------------------------------------------------------------------------------
// Admin — YouTube import (the admin panel's "Studio import" tab, public/admin/ext-studio-import.js).
// Add / edit / delete of single videos stays in routes/admin.js (/admin/videos).
// -------------------------------------------------------------------------------------------------------------------

const adminOnly = requireAuth('admin');
let importRunning = false;

/** GET /videos/admin/youtube — every YouTube video (active and inactive) + the state of the old sample clips. */
router.get('/admin/youtube', adminOnly, async (_req, res) => {
  const [videos, samples] = await Promise.all([
    query(
      `SELECT v.id, v.title, v.youtube_id, v.channel_name, v.trainer_name, v.level, v.equipment, v.group_key, v.types,
              v.duration_seconds, v.duration_source, v.thumbnail_url, v.playlist_title, v.sheet_name, v.is_published,
              v.imported_at, v.created_at, g.label AS group_label
       FROM videos v LEFT JOIN video_groups g ON g.key = v.group_key
       WHERE v.source = 'youtube'
       ORDER BY v.sheet_name NULLS LAST, v.playlist_id NULLS FIRST, v.created_at`,
    ),
    queryOne(
      `SELECT COUNT(*) FILTER (WHERE is_published) AS active, COUNT(*) FILTER (WHERE NOT is_published) AS inactive
       FROM videos WHERE source <> 'youtube' AND video_url ILIKE '%commondatastorage.googleapis.com/gtv-videos-bucket%'`,
    ),
  ]);
  res.json({ videos, samples });
});

const importSchema = z.object({
  /** Pasted rows (tab-separated from Excel/Sheets, CSV, or "Name — link" lines). */
  text: z.string().max(500_000).optional(),
  /** Uploaded .xlsx / .csv as base64. */
  file: z.object({ name: z.string().max(200), base64: z.string().max(14_000_000) }).optional(),
  /** Already-parsed rows (arrays of cells). */
  rows: z.array(z.array(z.string().max(2000)).max(30)).max(2000).optional(),
  dryRun: z.boolean().default(false),
  retag: z.boolean().default(false),
  deactivateSamples: z.boolean().default(true),
});

/**
 * POST /videos/admin/youtube/import — imports the owner's sheet (upsert on YouTube id) and returns the import report.
 * Takes up to a minute for big playlists (each video is checked on YouTube).
 */
router.post('/admin/youtube/import', adminOnly, async (req, res) => {
  const b = validate(importSchema, req.body);
  let rows;
  if (b.file) {
    try {
      rows = await rowsFromFile(Buffer.from(b.file.base64, 'base64'), b.file.name);
    } catch (err) {
      throw badRequest(`Could not read ${b.file.name}: ${err.message}`);
    }
  } else if (b.rows) rows = b.rows;
  else if (b.text?.trim()) rows = rowsFromText(b.text);
  else throw badRequest('Upload a .xlsx / .csv file or paste rows');
  if (!rows.length) throw badRequest('The sheet is empty');
  if (importRunning) throw conflict('Another import is running — wait for it to finish');
  importRunning = true;
  try {
    res.json({ report: await importYoutube(rows, b) });
  } finally {
    importRunning = false;
  }
});

/** POST /videos/admin/youtube/refresh — fills missing channel / thumbnail / duration of YouTube videos. */
router.post('/admin/youtube/refresh', adminOnly, async (_req, res) => {
  if (importRunning) throw conflict('An import is running — try again when it finishes');
  importRunning = true;
  try {
    res.json({ result: await refreshYoutubeDetails() });
  } finally {
    importRunning = false;
  }
});

/** PATCH /videos/admin/:id/active {active} — show / hide a video in Studio without deleting it. */
router.patch('/admin/:id/active', adminOnly, async (req, res) => {
  if (!z.string().uuid().safeParse(req.params.id).success) throw notFound('Video not found');
  const { active } = validate(z.object({ active: z.boolean() }), req.body);
  const video = await queryOne(`UPDATE videos SET is_published = $2 WHERE id = $1 RETURNING id, is_published`, [req.params.id, active]);
  if (!video) throw notFound('Video not found');
  res.json({ video });
});

/** POST /videos/admin/samples {active} — the old Google sample clips: hide (default after import) or bring back. */
router.post('/admin/samples', adminOnly, async (req, res) => {
  const { active } = validate(z.object({ active: z.boolean() }), req.body);
  const rows = await query(
    `UPDATE videos SET is_published = $1
     WHERE source <> 'youtube' AND video_url ILIKE '%commondatastorage.googleapis.com/gtv-videos-bucket%' AND is_published <> $1
     RETURNING id`,
    [active],
  );
  res.json({ changed: rows.length });
});

router.get('/:id', async (req, res) => {
  if (!z.string().uuid().safeParse(req.params.id).success) throw notFound('Video not found');
  const video = await queryOne(`SELECT ${VIDEO_COLUMNS} FROM (${STUDIO_VIDEOS}) s WHERE id = $1`, [req.params.id]);
  if (!video) throw notFound('Video not found');
  res.json({ video });
});

export default router;

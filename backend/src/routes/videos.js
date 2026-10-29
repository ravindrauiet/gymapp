import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notFound, validate } from '../utils/http.js';
import { VIDEO_CATEGORIES, VIDEO_CATEGORY_IDS } from '../utils/constants.js';
import { pagination } from '../utils/schemas.js';

const router = Router();
router.use(requireAuth());

const LEVELS = ['beginner', 'intermediate', 'advanced'];
const EQUIPMENT = ['none', 'dumbbells', 'gym'];
/** Duration buckets for the Studio filter: "10 min" (≤15), "20 min" (16–25), "30+ min" (>25). */
const DURATIONS = {
  10: 'duration_seconds <= 900',
  20: 'duration_seconds > 900 AND duration_seconds <= 1500',
  30: 'duration_seconds > 1500',
};
const durationBucket = (secs) => (secs == null ? null : secs <= 900 ? '10' : secs <= 1500 ? '20' : '30');

/** Primary group for rows created before 060_studio (old clients / old admin form only set `category`). */
const PRIMARY_GROUP = `COALESCE(v.group_key, CASE v.category WHEN 'yoga' THEN 'yoga_mind' WHEN 'dance' THEN 'dance_cardio'
  WHEN 'boxing' THEN 'martial_arts' WHEN 'martial_arts' THEN 'martial_arts' ELSE 'gym' END)`;

/**
 * Published videos with their resolved groups (primary group + groups of every type) and a search haystack
 * (title, trainer, description, category, level, equipment, group and type labels).
 */
const STUDIO_VIDEOS = `
  SELECT v.id, v.category, v.title, v.description, v.trainer_name, v.level, v.video_url, v.thumbnail_url,
         v.duration_seconds, v.created_at, ${PRIMARY_GROUP} AS group_key, pg.label AS group_label, v.types,
         v.equipment,
         ARRAY(SELECT DISTINCT x FROM unnest(COALESCE(tg.groups, '{}') || ${PRIMARY_GROUP}::text) x) AS groups,
         lower(concat_ws(' ', v.title, v.trainer_name, v.description, v.category, v.level, v.equipment,
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
  created_at, group_key, group_label, types, equipment, groups`;

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
 * q searches title, trainer, description and category/type names (every word must match; typo-tolerant on titles).
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
      trainer: z.string().trim().max(120).optional(),
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

router.get('/:id', async (req, res) => {
  if (!z.string().uuid().safeParse(req.params.id).success) throw notFound('Video not found');
  const video = await queryOne(`SELECT * FROM videos WHERE id = $1 AND is_published`, [req.params.id]);
  if (!video) throw notFound('Video not found');
  res.json({ video });
});

export default router;

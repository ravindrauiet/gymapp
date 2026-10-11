import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notFound, validate } from '../utils/http.js';
import { VIDEO_CATEGORIES, VIDEO_CATEGORY_IDS } from '../utils/constants.js';
import { pagination } from '../utils/schemas.js';

const router = Router();
router.use(requireAuth());

/** GET /videos/categories — FitKey Studio categories with video counts. */
router.get('/categories', async (_req, res) => {
  const counts = await query(
    `SELECT category, COUNT(*) AS count FROM videos WHERE is_published GROUP BY category`,
  );
  const byId = Object.fromEntries(counts.map((c) => [c.category, c.count]));
  res.json({ categories: VIDEO_CATEGORIES.map((c) => ({ ...c, count: byId[c.id] ?? 0 })) });
});

/** GET /videos?category=&level= */
router.get('/', async (req, res) => {
  const f = validate(
    z.object({
      category: z.enum(VIDEO_CATEGORY_IDS).optional(),
      level: z.enum(['beginner', 'intermediate', 'advanced']).optional(),
      ...pagination,
    }),
    req.query,
  );
  const videos = await query(
    `SELECT id, category, title, description, trainer_name, level, video_url, thumbnail_url, duration_seconds, created_at
     FROM videos
     WHERE is_published AND ($1::text IS NULL OR category = $1) AND ($2::text IS NULL OR level = $2)
     ORDER BY created_at DESC LIMIT $3 OFFSET $4`,
    [f.category ?? null, f.level ?? null, f.limit, (f.page - 1) * f.limit],
  );
  res.json({ videos, page: f.page, limit: f.limit });
});

router.get('/:id', async (req, res) => {
  const video = await queryOne(`SELECT * FROM videos WHERE id = $1 AND is_published`, [req.params.id]);
  if (!video) throw notFound('Video not found');
  res.json({ video });
});

export default router;

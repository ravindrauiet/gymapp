import { Router } from 'express';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';

const router = Router();
router.use(requireAuth());

/** GET /notifications?before=<iso> → { notifications, unread } (newest first, 30 per page) */
router.get('/', async (req, res) => {
  const before = req.query.before ? new Date(String(req.query.before)) : null;
  const notifications = await query(
    `SELECT id, type, title, body, data, read_at, created_at FROM notifications
      WHERE user_id = $1 AND ($2::timestamptz IS NULL OR created_at < $2)
      ORDER BY created_at DESC LIMIT 30`,
    [req.user.id, before && !Number.isNaN(before.getTime()) ? before : null],
  );
  const { unread } = await queryOne(
    `SELECT COUNT(*)::int AS unread FROM notifications WHERE user_id = $1 AND read_at IS NULL`,
    [req.user.id],
  );
  res.json({ notifications, unread });
});

/** GET /notifications/unread-count → { unread } */
router.get('/unread-count', async (req, res) => {
  const { unread } = await queryOne(
    `SELECT COUNT(*)::int AS unread FROM notifications WHERE user_id = $1 AND read_at IS NULL`,
    [req.user.id],
  );
  res.json({ unread });
});

/** POST /notifications/read  { ids?: string[] } — marks the given (or all) notifications read. */
router.post('/read', async (req, res) => {
  const ids = Array.isArray(req.body?.ids) ? req.body.ids.filter((x) => typeof x === 'string') : null;
  await query(
    `UPDATE notifications SET read_at = now()
      WHERE user_id = $1 AND read_at IS NULL AND ($2::uuid[] IS NULL OR id = ANY($2::uuid[]))`,
    [req.user.id, ids],
  );
  res.json({ ok: true });
});

export default router;

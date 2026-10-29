import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, notFound, validate } from '../utils/http.js';
import { VENUE_CATEGORY_IDS, VIDEO_CATEGORY_IDS } from '../utils/constants.js';
import { dateSchema } from '../utils/schemas.js';

/** FITKEY team operations: venue verification (P8) and content management (plans, videos, contests). */
const router = Router();
router.use(requireAuth('admin'));

/** GET /admin/stats — headline numbers for the admin panel. */
router.get('/stats', async (_req, res) => {
  const stats = await queryOne(
    `SELECT
       (SELECT COUNT(*) FROM users WHERE role = 'user') AS members,
       (SELECT COUNT(*) FROM users WHERE role = 'partner') AS partners,
       (SELECT COUNT(*) FROM venues WHERE status = 'live') AS live_venues,
       (SELECT COUNT(*) FROM venues WHERE status IN ('submitted', 'under_review')) AS pending_venues,
       (SELECT COUNT(*) FROM subscriptions WHERE status = 'active' AND now() BETWEEN starts_at AND ends_at) AS active_subscriptions,
       (SELECT COALESCE(SUM(amount_paise), 0) FROM subscriptions WHERE created_at >= date_trunc('month', now())) AS revenue_this_month_paise,
       (SELECT COUNT(*) FROM checkins WHERE checkin_date = (now() AT TIME ZONE $1)::date) AS checkins_today,
       (SELECT COUNT(*) FROM user_reports) AS reports,
       (SELECT COUNT(*) FROM marketplace_orders) AS total_orders,
       (SELECT COALESCE(SUM(total_amount_paise), 0) FROM marketplace_orders WHERE payment_status = 'paid') AS store_revenue_paise,
       (SELECT COUNT(*) FROM trainers WHERE verification_status = 'verified') AS verified_trainers,
       (SELECT COUNT(*) FROM marketplace_products WHERE is_active = true) AS active_products`,
    [config.tz],
  );
  res.json({ stats });
});

router.get('/venues', async (req, res) => {
  const { status } = validate(
    z.object({ status: z.enum(['draft', 'submitted', 'under_review', 'live', 'rejected']).optional() }),
    req.query,
  );
  const venues = await query(
    `SELECT v.*, u.name AS owner_name, u.phone AS owner_phone FROM venues v JOIN users u ON u.id = v.owner_id
     WHERE ($1::text IS NULL OR v.status = $1) ORDER BY v.updated_at DESC LIMIT 200`,
    [status ?? null],
  );
  res.json({ venues });
});

/** PATCH /admin/venues/:id/status { status: under_review|live|rejected, note? } */
router.patch('/venues/:id/status', async (req, res) => {
  const { status, note } = validate(
    z.object({ status: z.enum(['under_review', 'live', 'rejected']), note: z.string().trim().max(500).optional() }),
    req.body,
  );
  if (status === 'rejected' && !note) throw badRequest('Add a note explaining the rejection');
  const venue = await queryOne(
    `UPDATE venues SET status = $2, review_note = $3, updated_at = now() WHERE id = $1 RETURNING *`,
    [req.params.id, status, note ?? null],
  );
  if (!venue) throw notFound('Venue not found');
  res.json({ venue });
});

const planSchema = z.object({
  code: z.string().trim().regex(/^[a-z0-9_]+$/).max(40),
  name: z.string().trim().min(2).max(120),
  description: z.string().trim().max(1000).optional(),
  categories: z.array(z.enum(VENUE_CATEGORY_IDS)).min(1),
  pricePaise: z.number().int().min(0),
  durationDays: z.number().int().min(1).max(730),
  features: z.array(z.string().trim().max(120)).optional(),
  isActive: z.boolean().optional(),
  sortOrder: z.number().int().optional(),
});

router.get('/plans', async (_req, res) => {
  res.json({ plans: await query(`SELECT * FROM plans ORDER BY sort_order, price_paise`) });
});

router.post('/plans', async (req, res) => {
  const p = validate(planSchema, req.body);
  const plan = await queryOne(
    `INSERT INTO plans (code, name, description, categories, price_paise, duration_days, features, is_active, sort_order)
     VALUES ($1, $2, $3, $4, $5, $6, COALESCE($7::text[], '{}'), COALESCE($8::boolean, true), COALESCE($9::int, 0)) RETURNING *`,
    [p.code, p.name, p.description ?? null, p.categories, p.pricePaise, p.durationDays, p.features ?? null, p.isActive ?? null, p.sortOrder ?? null],
  );
  res.status(201).json({ plan });
});

router.patch('/plans/:id', async (req, res) => {
  const p = validate(planSchema.partial(), req.body);
  const plan = await queryOne(
    `UPDATE plans SET name = COALESCE($2, name), description = COALESCE($3, description),
       categories = COALESCE($4, categories), price_paise = COALESCE($5, price_paise),
       duration_days = COALESCE($6, duration_days), features = COALESCE($7, features),
       is_active = COALESCE($8, is_active), sort_order = COALESCE($9, sort_order)
     WHERE id = $1 RETURNING *`,
    [req.params.id, p.name, p.description, p.categories, p.pricePaise, p.durationDays, p.features, p.isActive, p.sortOrder],
  );
  if (!plan) throw notFound('Plan not found');
  res.json({ plan });
});

const VIDEO_EQUIPMENT = ['none', 'dumbbells', 'gym'];
/** Legacy `category` (old clients) derived from the Studio group when the admin doesn't pick one. */
const GROUP_TO_CATEGORY = { yoga_mind: 'yoga', dance_cardio: 'dance', martial_arts: 'martial_arts' };

const videoSchema = z.object({
  category: z.enum(VIDEO_CATEGORY_IDS).optional(),
  title: z.string().trim().min(2).max(200),
  description: z.string().trim().max(2000).optional(),
  trainerName: z.string().trim().max(120).optional(),
  level: z.enum(['beginner', 'intermediate', 'advanced']).optional(),
  videoUrl: z.string().url(),
  thumbnailUrl: z.string().url().optional(),
  durationSeconds: z.number().int().positive().optional(),
  groupKey: z.string().trim().max(30).optional(),
  types: z.array(z.string().trim().max(40)).max(12).optional(),
  equipment: z.enum(VIDEO_EQUIPMENT).optional(),
});

/** Checks group/type keys against the Studio taxonomy; returns the resolved primary group. */
async function checkTaxonomy(groupKey, types) {
  if (groupKey && !(await queryOne(`SELECT 1 FROM video_groups WHERE key = $1`, [groupKey]))) {
    throw badRequest(`Unknown Studio group "${groupKey}"`);
  }
  if (types?.length) {
    const found = await query(`SELECT key, group_key FROM video_types WHERE key = ANY($1)`, [types]);
    const missing = types.filter((t) => !found.some((f) => f.key === t));
    if (missing.length) throw badRequest(`Unknown video type(s): ${missing.join(', ')}`);
    return groupKey ?? found.find((f) => f.key === types[0])?.groupKey ?? null;
  }
  return groupKey ?? null;
}

/** GET /admin/video-taxonomy — every Studio group with its video types (for the admin form). */
router.get('/video-taxonomy', async (_req, res) => {
  const [groups, types] = await Promise.all([
    query(`SELECT key, label FROM video_groups ORDER BY sort_order, label`),
    query(`SELECT key, group_key, label FROM video_types ORDER BY sort_order, label`),
  ]);
  res.json({ groups: groups.map((g) => ({ ...g, types: types.filter((t) => t.groupKey === g.key) })) });
});

router.get('/videos', async (_req, res) => {
  res.json({ videos: await query(`SELECT * FROM videos ORDER BY category, created_at DESC`) });
});

router.post('/videos', async (req, res) => {
  const v = validate(videoSchema, req.body);
  if (!v.category && !v.groupKey && !v.types?.length) throw badRequest('Pick a Studio group or a category');
  const groupKey = await checkTaxonomy(v.groupKey, v.types);
  const category = v.category ?? GROUP_TO_CATEGORY[groupKey] ?? 'gym';
  const video = await queryOne(
    `INSERT INTO videos (category, title, description, trainer_name, level, video_url, thumbnail_url, duration_seconds,
       group_key, types, equipment)
     VALUES ($1, $2, $3, $4, COALESCE($5, 'beginner'), $6, $7, $8, $9, $10, $11) RETURNING *`,
    [category, v.title, v.description ?? null, v.trainerName ?? null, v.level ?? null, v.videoUrl, v.thumbnailUrl ?? null,
      v.durationSeconds ?? null, groupKey, v.types ?? [], v.equipment ?? null],
  );
  res.status(201).json({ video });
});

/** PATCH /admin/videos/:id — edit a video (e.g. re-tag its Studio group / types / equipment). */
router.patch('/videos/:id', async (req, res) => {
  if (!z.string().uuid().safeParse(req.params.id).success) throw notFound('Video not found');
  const v = validate(videoSchema.partial(), req.body);
  const current = await queryOne(`SELECT group_key, types FROM videos WHERE id = $1`, [req.params.id]);
  if (!current) throw notFound('Video not found');
  const groupKey = v.groupKey !== undefined || v.types !== undefined
    ? await checkTaxonomy(v.groupKey ?? current.groupKey ?? undefined, v.types ?? current.types)
    : undefined;
  const video = await queryOne(
    `UPDATE videos SET category = COALESCE($2, category), title = COALESCE($3, title),
       description = COALESCE($4, description), trainer_name = COALESCE($5, trainer_name), level = COALESCE($6, level),
       video_url = COALESCE($7, video_url), thumbnail_url = COALESCE($8, thumbnail_url),
       duration_seconds = COALESCE($9, duration_seconds), group_key = COALESCE($10, group_key),
       types = COALESCE($11, types), equipment = COALESCE($12, equipment)
     WHERE id = $1 RETURNING *`,
    [req.params.id, v.category ?? null, v.title ?? null, v.description ?? null, v.trainerName ?? null, v.level ?? null,
      v.videoUrl ?? null, v.thumbnailUrl ?? null, v.durationSeconds ?? null, groupKey ?? null, v.types ?? null,
      v.equipment ?? null],
  );
  res.json({ video });
});

router.delete('/videos/:id', async (req, res) => {
  const deleted = await queryOne(`DELETE FROM videos WHERE id = $1 RETURNING id`, [req.params.id]);
  if (!deleted) throw notFound('Video not found');
  res.status(204).end();
});

const contestSchema = z.object({
  title: z.string().trim().min(3).max(160),
  description: z.string().trim().max(2000).optional(),
  period: z.enum(['weekly', 'monthly']),
  metric: z.enum(['checkins', 'running_km', 'streak']),
  startsOn: dateSchema,
  endsOn: dateSchema,
  reward: z.string().trim().max(200).optional(),
  city: z.string().trim().max(80).optional(),
});

router.get('/contests', async (_req, res) => {
  const contests = await query(
    `SELECT c.*, (SELECT COUNT(*) FROM contest_participants p WHERE p.contest_id = c.id) AS participant_count
     FROM contests c ORDER BY c.starts_on DESC LIMIT 200`,
  );
  res.json({ contests });
});

router.delete('/contests/:id', async (req, res) => {
  const deleted = await queryOne(`DELETE FROM contests WHERE id = $1 RETURNING id`, [req.params.id]);
  if (!deleted) throw notFound('Contest not found');
  res.status(204).end();
});

router.post('/contests', async (req, res) => {
  const c = validate(contestSchema, req.body);
  if (c.endsOn < c.startsOn) throw badRequest('endsOn must be on or after startsOn');
  const contest = await queryOne(
    `INSERT INTO contests (title, description, period, metric, starts_on, ends_on, reward, city)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING *`,
    [c.title, c.description ?? null, c.period, c.metric, c.startsOn, c.endsOn, c.reward ?? null, c.city ?? null],
  );
  res.status(201).json({ contest });
});

router.get('/reports', async (_req, res) => {
  const reports = await query(
    `SELECT r.*, a.name AS reporter_name, b.name AS reported_name, b.phone AS reported_phone
     FROM user_reports r JOIN users a ON a.id = r.reporter_id JOIN users b ON b.id = r.reported_id
     ORDER BY r.created_at DESC LIMIT 200`,
  );
  res.json({ reports });
});

// Marketplace Orders overview for Admin
router.get('/orders', async (_req, res) => {
  const orders = await query(
    `SELECT o.*, u.name AS member_name, u.phone AS member_phone
     FROM marketplace_orders o
     JOIN users u ON u.id = o.user_id
     ORDER BY o.created_at DESC LIMIT 200`,
  );
  res.json({ orders });
});

// Vendor verification for Admin
router.get('/vendors', async (_req, res) => {
  const vendors = await query(
    `SELECT v.*, u.name AS partner_name, u.phone AS partner_phone
     FROM marketplace_vendors v
     JOIN users u ON u.id = v.partner_id
     ORDER BY v.created_at DESC`,
  );
  res.json({ vendors });
});

router.patch('/vendors/:id/status', async (req, res) => {
  const { status } = validate(z.object({ status: z.enum(['pending', 'verified', 'rejected']) }), req.body);
  const vendor = await queryOne(
    `UPDATE marketplace_vendors SET verification_status = $1 WHERE id = $2 RETURNING *`,
    [status, req.params.id],
  );
  if (!vendor) throw notFound('Vendor not found');
  res.json({ vendor });
});

// Trainer verification for Admin
router.get('/trainers', async (_req, res) => {
  const trainers = await query(`SELECT * FROM trainers ORDER BY created_at DESC`);
  res.json({ trainers });
});

router.patch('/trainers/:id/status', async (req, res) => {
  const { status } = validate(z.object({ status: z.enum(['pending', 'verified', 'rejected']) }), req.body);
  const trainer = await queryOne(
    `UPDATE trainers SET verification_status = $1 WHERE id = $2 RETURNING *`,
    [status, req.params.id],
  );
  if (!trainer) throw notFound('Trainer not found');
  res.json({ trainer });
});

export default router;

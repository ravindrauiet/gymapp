import { Router } from 'express';
import { z } from 'zod';
import { queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notFound, validate } from '../utils/http.js';
import { dateSchema } from '../utils/schemas.js';

const router = Router();
router.use(requireAuth());

const USER_FIELDS = 'id, phone, email, name, role, city, gender, birth_date, avatar_url, created_at';

/** GET /me — profile plus the currently active subscription (if any). */
router.get('/', async (req, res) => {
  const user = await queryOne(`SELECT ${USER_FIELDS} FROM users WHERE id = $1`, [req.user.id]);
  if (!user) throw notFound('Account not found');

  const activeSubscription = await queryOne(
    `SELECT s.id, s.starts_at, s.ends_at, p.id AS plan_id, p.name AS plan_name, p.categories
     FROM subscriptions s JOIN plans p ON p.id = s.plan_id
     WHERE s.user_id = $1 AND s.status = 'active' AND now() BETWEEN s.starts_at AND s.ends_at
     ORDER BY s.ends_at DESC LIMIT 1`,
    [req.user.id],
  );
  res.json({ user, activeSubscription });
});

const profileSchema = z.object({
  name: z.string().trim().min(2).max(120).optional(),
  email: z.string().trim().email().max(255).optional(),
  city: z.string().trim().min(2).max(80).optional(),
  gender: z.enum(['male', 'female', 'other']).optional(),
  birthDate: dateSchema.optional(),
  avatarUrl: z.string().url().optional(),
});

/** PATCH /me — update profile fields. */
router.patch('/', async (req, res) => {
  const body = validate(profileSchema, req.body);
  const user = await queryOne(
    `UPDATE users SET
       name = COALESCE($2, name),
       email = COALESCE($3, email),
       city = COALESCE($4, city),
       gender = COALESCE($5, gender),
       birth_date = COALESCE($6, birth_date),
       avatar_url = COALESCE($7, avatar_url),
       updated_at = now()
     WHERE id = $1
     RETURNING ${USER_FIELDS}`,
    [req.user.id, body.name, body.email, body.city, body.gender, body.birthDate, body.avatarUrl],
  );
  res.json({ user });
});

export default router;

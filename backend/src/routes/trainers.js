import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notFound, validate } from '../utils/http.js';
import { dateSchema } from '../utils/schemas.js';

export const trainersRouter = Router();

// ============================================================================
// Consumer App Endpoints (FITKEY)
// ============================================================================

trainersRouter.get('/', async (req, res) => {
  const { modes, category, q } = req.query;
  const conditions = ["verification_status = 'verified'"];
  const params = [];

  // modes can be comma-separated or array e.g. "online,home"
  if (modes) {
    const modeList = modes.split(',').map((m) => m.trim()).filter(Boolean);
    if (modeList.length > 0) {
      params.push(modeList);
      conditions.push(`training_modes && $${params.length}`);
    }
  }

  if (category && category !== 'all') {
    params.push(category);
    conditions.push(`$${params.length} = ANY(specializations)`);
  }

  if (q && q.trim()) {
    params.push(`%${q.trim()}%`);
    conditions.push(`(name ILIKE $${params.length} OR bio ILIKE $${params.length})`);
  }

  const trainers = await query(
    `SELECT * FROM trainers WHERE ${conditions.join(' AND ')} ORDER BY rating DESC`,
    params,
  );
  res.json({ trainers });
});

trainersRouter.get('/:id', async (req, res) => {
  const trainer = await queryOne(`SELECT * FROM trainers WHERE id = $1`, [req.params.id]);
  if (!trainer) throw notFound('Trainer not found');

  // Dynamic slot generation for the next 7 days
  const timeSlots = ['06:30 AM', '08:00 AM', '09:30 AM', '11:00 AM', '04:00 PM', '05:30 PM', '07:00 PM'];
  res.json({ trainer, availableSlots: timeSlots });
});

const bookTrainerSchema = z.object({
  mode: z.enum(['online', 'home', 'gym']),
  sessionDate: dateSchema,
  slotTime: z.string().min(4),
});

trainersRouter.post('/:id/book', requireAuth('user'), async (req, res) => {
  const trainer = await queryOne(`SELECT * FROM trainers WHERE id = $1`, [req.params.id]);
  if (!trainer) throw notFound('Trainer not found');

  const data = validate(bookTrainerSchema, req.body);

  const booking = await queryOne(
    `INSERT INTO trainer_bookings (
       trainer_id, user_id, mode, session_date, slot_time, duration_minutes, amount_paise, status
     ) VALUES ($1, $2, $3, $4, $5, 60, $6, 'confirmed')
     RETURNING *`,
    [trainer.id, req.user.id, data.mode, data.sessionDate, data.slotTime, trainer.hourly_rate_paise],
  );

  res.status(201).json({ booking, trainerName: trainer.name });
});

trainersRouter.get('/bookings/me', requireAuth('user'), async (req, res) => {
  const bookings = await query(
    `SELECT b.*, t.name AS trainer_name, t.photo_url, t.specializations
     FROM trainer_bookings b
     JOIN trainers t ON t.id = b.trainer_id
     WHERE b.user_id = $1
     ORDER BY b.session_date DESC, b.slot_time DESC`,
    [req.user.id],
  );
  res.json({ bookings });
});

// ============================================================================
// Partner App Scope (FITKEY Partner - Trainer Module)
// ============================================================================

export const partnerTrainerRouter = Router();
partnerTrainerRouter.use(requireAuth('partner'));

partnerTrainerRouter.get('/profile', async (req, res) => {
  const trainer = await queryOne(`SELECT * FROM trainers WHERE partner_id = $1`, [req.user.id]);
  res.json({ trainer: trainer || null });
});

const partnerTrainerSchema = z.object({
  name: z.string().min(2),
  bio: z.string().min(10),
  photoUrl: z.string().optional(),
  certifications: z.array(z.string()).default([]),
  specializations: z.array(z.string()).min(1),
  trainingModes: z.array(z.enum(['online', 'home', 'gym'])).min(1),
  hourlyRatePaise: z.number().int().min(10000), // at least ₹100
  bufferMinutes: z.number().int().min(0).max(120).default(30),
  workingHours: z.object({ start: z.string(), end: z.string() }).default({ start: '06:00', end: '21:00' }),
});

partnerTrainerRouter.post('/profile', async (req, res) => {
  const data = validate(partnerTrainerSchema, req.body);

  const existing = await queryOne(`SELECT id FROM trainers WHERE partner_id = $1`, [req.user.id]);

  let trainer;
  if (existing) {
    trainer = await queryOne(
      `UPDATE trainers SET
         name = $1, bio = $2, photo_url = COALESCE($3, photo_url),
         certifications = $4, specializations = $5, training_modes = $6,
         hourly_rate_paise = $7, buffer_minutes = $8, working_hours = $9
       WHERE id = $10 RETURNING *`,
      [
        data.name,
        data.bio,
        data.photoUrl ?? null,
        data.certifications,
        data.specializations,
        data.trainingModes,
        data.hourlyRatePaise,
        data.bufferMinutes,
        JSON.stringify(data.workingHours),
        existing.id,
      ],
    );
  } else {
    trainer = await queryOne(
      `INSERT INTO trainers (
         partner_id, name, bio, photo_url, certifications, specializations,
         training_modes, hourly_rate_paise, buffer_minutes, working_hours, verification_status
       ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'verified')
       RETURNING *`,
      [
        req.user.id,
        data.name,
        data.bio,
        data.photoUrl ?? null,
        data.certifications,
        data.specializations,
        data.trainingModes,
        data.hourlyRatePaise,
        data.bufferMinutes,
        JSON.stringify(data.workingHours),
      ],
    );
  }

  res.status(201).json({ trainer });
});

partnerTrainerRouter.get('/bookings', async (req, res) => {
  const trainer = await queryOne(`SELECT id FROM trainers WHERE partner_id = $1`, [req.user.id]);
  if (!trainer) return res.json({ bookings: [] });

  const bookings = await query(
    `SELECT b.*, u.name AS member_name, u.phone AS member_phone
     FROM trainer_bookings b
     JOIN users u ON u.id = b.user_id
     WHERE b.trainer_id = $1
     ORDER BY b.session_date DESC, b.slot_time DESC`,
    [trainer.id],
  );
  res.json({ bookings });
});

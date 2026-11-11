import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { commissionPct } from '../utils/commission.js';
import { conflict, forbidden, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { earningsSummary, slotsForDay, todayIst, weekdayOf } from '../utils/partner_types.js';
import { dateSchema } from '../utils/schemas.js';

export const trainersRouter = Router();

// ============================================================================
// Trainer categories (BRD §6): groups → types. Keys are stored in trainers.trainer_types.
// ============================================================================

export const TRAINER_GROUPS = [
  {
    key: 'gym_strength',
    label: 'Gym & Strength',
    types: [
      ['personal_trainer', 'Personal Trainer'],
      ['weight_loss', 'Weight Loss Trainer'],
      ['muscle_gain', 'Muscle Gain / Bodybuilding Coach'],
      ['strength_conditioning', 'Strength & Conditioning Coach'],
      ['powerlifting', 'Powerlifting Coach'],
      ['functional', 'Functional Training'],
      ['crossfit', 'CrossFit Coach'],
      ['calisthenics', 'Calisthenics Coach'],
    ],
  },
  {
    key: 'yoga_mind',
    label: 'Yoga & Mind',
    types: [
      ['yoga', 'Yoga Instructor (Hatha, Power, Ashtanga)'],
      ['therapeutic_yoga', 'Therapeutic Yoga'],
      ['pranayama', 'Pranayama / Breathwork'],
      ['meditation', 'Meditation Coach'],
      ['mental_wellness', 'Mental Wellness Coach'],
    ],
  },
  {
    key: 'dance_group',
    label: 'Dance & Group',
    types: [
      ['zumba', 'Zumba'],
      ['bollywood_dance', 'Bollywood Dance'],
      ['aerobics', 'Aerobics'],
      ['pilates', 'Pilates'],
      ['hiit', 'HIIT / Bootcamp'],
      ['spinning', 'Spinning / Cycling'],
      ['kickboxing', 'Kickboxing'],
    ],
  },
  {
    key: 'martial_arts',
    label: 'Martial Arts & Combat',
    types: [
      ['boxing', 'Boxing'],
      ['mma', 'MMA'],
      ['judo_karate', 'Judo / Karate'],
      ['taekwondo', 'Taekwondo'],
      ['kalaripayattu', 'Kalaripayattu'],
      ['self_defence_women', 'Self-defence (women)'],
    ],
  },
  {
    key: 'sports',
    label: 'Sports Coaches',
    types: [
      ['swimming', 'Swimming'],
      ['badminton', 'Badminton'],
      ['tennis', 'Tennis'],
      ['cricket', 'Cricket'],
      ['football', 'Football'],
      ['running', 'Running / Marathon Coach'],
      ['skating', 'Skating'],
    ],
  },
  {
    key: 'health_recovery',
    label: 'Health & Recovery',
    types: [
      ['physiotherapist', 'Physiotherapist'],
      ['sports_rehab', 'Sports Rehab / Injury Recovery'],
      ['posture_corrective', 'Posture & Corrective Exercise'],
      ['mobility', 'Mobility / Stretching Coach'],
      ['sports_massage', 'Sports Massage Therapist'],
    ],
  },
  {
    key: 'nutrition',
    label: 'Nutrition',
    types: [
      ['nutritionist', 'Nutritionist'],
      ['dietitian', 'Dietitian'],
      ['sports_nutritionist', 'Sports Nutritionist'],
      ['clinical_diet', 'Clinical Diet (PCOS, Diabetes, Thyroid)'],
    ],
  },
  {
    key: 'special',
    label: 'Special Audiences',
    types: [
      ['prenatal_postnatal', 'Prenatal / Postnatal'],
      ['senior_fitness', 'Senior Citizen Fitness'],
      ['kids_teen', 'Kids / Teen Fitness'],
      ['womens_fitness', "Women's Fitness"],
    ],
  },
];

export const TRAINER_TYPE_KEYS = TRAINER_GROUPS.flatMap((g) => g.types.map(([k]) => k));
const TYPE_LABELS = Object.fromEntries(TRAINER_GROUPS.flatMap((g) => g.types));

/** Keyword → type, used when a partner saves a profile without picking types (mirrors the 070 migration backfill). */
const TYPE_KEYWORDS = [
  [/gym|personal train/i, 'personal_trainer'],
  [/weight loss|fat loss/i, 'weight_loss'],
  [/bodybuild|muscle|physique/i, 'muscle_gain'],
  [/strength|conditioning|weightlift/i, 'strength_conditioning'],
  [/powerlift/i, 'powerlifting'],
  [/functional/i, 'functional'],
  [/crossfit/i, 'crossfit'],
  [/calisthenic/i, 'calisthenics'],
  [/yoga/i, 'yoga'],
  [/therapeutic yoga/i, 'therapeutic_yoga'],
  [/pranayam|breath/i, 'pranayama'],
  [/meditat/i, 'meditation'],
  [/mental/i, 'mental_wellness'],
  [/zumba/i, 'zumba'],
  [/bollywood/i, 'bollywood_dance'],
  [/aerobic/i, 'aerobics'],
  [/pilates/i, 'pilates'],
  [/hiit|bootcamp/i, 'hiit'],
  [/spinning|cycling/i, 'spinning'],
  [/kickbox/i, 'kickboxing'],
  [/boxing/i, 'boxing'],
  [/mma/i, 'mma'],
  [/judo|karate/i, 'judo_karate'],
  [/taekwondo/i, 'taekwondo'],
  [/kalari/i, 'kalaripayattu'],
  [/self.defen/i, 'self_defence_women'],
  [/swim/i, 'swimming'],
  [/badminton/i, 'badminton'],
  [/tennis/i, 'tennis'],
  [/cricket/i, 'cricket'],
  [/football/i, 'football'],
  [/running|marathon/i, 'running'],
  [/skating/i, 'skating'],
  [/physio/i, 'physiotherapist'],
  [/rehab|injury/i, 'sports_rehab'],
  [/posture|corrective/i, 'posture_corrective'],
  [/mobility|stretch/i, 'mobility'],
  [/massage/i, 'sports_massage'],
  [/nutrition/i, 'nutritionist'],
  [/dietitian/i, 'dietitian'],
  [/sports nutrition/i, 'sports_nutritionist'],
  [/pcos|diabet|thyroid/i, 'clinical_diet'],
  [/prenatal|postnatal/i, 'prenatal_postnatal'],
  [/senior/i, 'senior_fitness'],
  [/kids|teen/i, 'kids_teen'],
  [/women/i, 'womens_fitness'],
];

export function deriveTrainerTypes(specializations = []) {
  const out = new Set();
  for (const s of specializations) for (const [re, key] of TYPE_KEYWORDS) if (re.test(s)) out.add(key);
  return out.size ? [...out] : ['personal_trainer'];
}

/**
 * Public trainer columns. The legacy `rating` / `review_count` columns hold seed values, so they are replaced by
 * the real aggregates from trainer_ratings (null / 0 until someone rates).
 */
/**
 * Partner BRD §7: the "Verified" badge on a partner-listed trainer needs certificates checked by FitKey
 * (certificates_verified_at, kept in step by utils/partner_types.js onDocumentVerified). Legacy rows
 * (listing_status NULL) keep their verification_status.
 */
const VERIFIED_STATUS = `(CASE WHEN t.listing_status IS NULL THEN t.verification_status
  WHEN t.certificates_verified_at IS NOT NULL THEN 'verified' ELSE 'pending' END)`;

/** Members see legacy verified trainers and partner-listed trainers whose listing is live. */
const MEMBER_VISIBLE = `((t.listing_status IS NULL AND t.verification_status = 'verified') OR t.listing_status = 'live')`;

const TRAINER_COLS = `t.id, t.partner_id, t.name, t.photo_url, t.bio, t.certifications, t.specializations, t.trainer_types,
  t.training_modes, t.hourly_rate_paise, t.buffer_minutes, t.working_hours, t.created_at,
  t.rating_avg, t.rating_count, t.rating_avg AS rating, t.rating_count AS review_count,
  t.subtypes, t.achievements, t.languages, t.service_area, t.experience_years, t.packages, t.weekly_slots,
  t.max_sessions_per_day, t.listing_status, t.certificates_verified_at,
  ${VERIFIED_STATUS} AS verification_status, (${VERIFIED_STATUS} = 'verified') AS verified_badge`;

/** Ranking key that only trusts averages backed by ≥ 5 ratings ("New" trainers sort after rated ones). */
const RATED_AVG = `CASE WHEN t.rating_count >= 5 THEN t.rating_avg END`;

/** Adds human labels for trainer_types, e.g. ["Zumba", "Pilates"]. */
const withTypeLabels = (t) => {
  t.trainerTypeLabels = (t.trainerTypes ?? []).map((k) => TYPE_LABELS[k]).filter(Boolean);
  return t;
};

// ============================================================================
// Consumer App Endpoints (FITKEY)
// ============================================================================

/** GET /trainers/categories — groups and types that have at least one verified trainer, with counts. */
trainersRouter.get('/categories', async (_req, res) => {
  const rows = await query(
    `SELECT k AS key, COUNT(*)::int AS n FROM trainers t, unnest(t.trainer_types) k
     WHERE ${MEMBER_VISIBLE} GROUP BY k`,
  );
  const counts = Object.fromEntries(rows.map((r) => [r.key, r.n]));
  const total = await queryOne(`SELECT COUNT(*)::int AS n FROM trainers t WHERE ${MEMBER_VISIBLE}`);
  const groups = [];
  for (const g of TRAINER_GROUPS) {
    const types = g.types.filter(([k]) => counts[k] > 0).map(([key, label]) => ({ key, label, count: counts[key] }));
    if (!types.length) continue;
    const groupCount = await queryOne(
      `SELECT COUNT(*)::int AS n FROM trainers t WHERE ${MEMBER_VISIBLE} AND t.trainer_types && $1`,
      [g.types.map(([k]) => k)],
    );
    groups.push({ key: g.key, label: g.label, count: groupCount.n, types });
  }
  res.json({ groups, total: total.n });
});

const listSchema = z.object({
  modes: z.string().optional(),
  category: z.string().optional(), // legacy: exact specialization
  group: z.string().optional(),
  type: z.string().optional(),
  q: z.string().trim().max(80).optional(),
  minRating: z.coerce.number().min(1).max(5).optional(),
  sort: z.enum(['relevance', 'rating', 'price_low', 'price_high']).optional(),
});

/**
 * GET /trainers — verified trainers. Filters: modes (csv), group, type, category (specialization), q, minRating.
 * Order: relevance (when searching) then rating; or sort=rating|price_low|price_high.
 */
trainersRouter.get('/', async (req, res) => {
  const f = validate(listSchema, req.query);
  const conditions = [MEMBER_VISIBLE];
  const params = [];
  const p = (v) => {
    params.push(v);
    return `$${params.length}`;
  };

  if (f.modes) {
    const modeList = f.modes.split(',').map((m) => m.trim()).filter(Boolean);
    if (modeList.length > 0) conditions.push(`t.training_modes && ${p(modeList)}`);
  }
  if (f.category && f.category !== 'all') conditions.push(`${p(f.category)} = ANY(t.specializations)`);
  if (f.group) {
    const g = TRAINER_GROUPS.find((x) => x.key === f.group);
    if (g) conditions.push(`t.trainer_types && ${p(g.types.map(([k]) => k))}`);
  }
  if (f.type) conditions.push(`${p(f.type)} = ANY(t.trainer_types)`);
  if (f.minRating) conditions.push(`t.rating_count >= 5 AND t.rating_avg >= ${p(f.minRating)}`);

  let relevance = '0';
  if (f.q) {
    const like = p(`%${f.q}%`);
    const prefix = p(`${f.q}%`);
    // Types whose label matches the query, e.g. "zumba", "physio", "weight loss".
    const qLower = f.q.toLowerCase();
    const matchedTypes = TRAINER_TYPE_KEYS.filter((k) => TYPE_LABELS[k].toLowerCase().includes(qLower));
    const types = p(matchedTypes);
    const specMatch = `EXISTS (SELECT 1 FROM unnest(t.specializations) s WHERE s ILIKE ${like})`;
    conditions.push(`(t.name ILIKE ${like} OR t.bio ILIKE ${like} OR ${specMatch} OR t.trainer_types && ${types})`);
    relevance = `(CASE WHEN t.name ILIKE ${prefix} THEN 4 WHEN t.name ILIKE ${like} THEN 3 ELSE 0 END
      + CASE WHEN t.trainer_types && ${types} OR ${specMatch} THEN 2 ELSE 0 END
      + CASE WHEN t.bio ILIKE ${like} THEN 1 ELSE 0 END)`;
  }

  const byRating = `${RATED_AVG} DESC NULLS LAST, t.rating_count DESC`;
  const order = {
    rating: `${byRating}, t.name`,
    price_low: `t.hourly_rate_paise, ${byRating}`,
    price_high: `t.hourly_rate_paise DESC, ${byRating}`,
    relevance: `relevance DESC, ${byRating}, t.name`,
  }[f.sort ?? 'relevance'];

  const trainers = await query(
    `SELECT ${TRAINER_COLS}, ${relevance} AS relevance FROM trainers t
     WHERE ${conditions.join(' AND ')} ORDER BY ${order}`,
    params,
  );
  for (const t of trainers) {
    delete t.relevance;
    withTypeLabels(t);
  }
  res.json({ trainers });
});

const LEGACY_SLOTS = ['06:30 AM', '08:00 AM', '09:30 AM', '11:00 AM', '04:00 PM', '05:30 PM', '07:00 PM'];

const addDays = (ymd, n) => new Date(Date.parse(`${ymd}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);

/** Session start times for each of the next `days` days from the trainer's weekly slots (60-minute sessions). */
function slotsByDate(weeklySlots, from = todayIst(), days = 7) {
  const out = [];
  for (let i = 0; i < days; i += 1) {
    const date = addDays(from, i);
    out.push({ date, slots: slotsForDay(weeklySlots ?? [], weekdayOf(date), 60) });
  }
  return out;
}

trainersRouter.get('/:id', async (req, res) => {
  const trainer = await queryOne(`SELECT ${TRAINER_COLS} FROM trainers t WHERE t.id = $1 AND ${MEMBER_VISIBLE}`, [req.params.id]);
  if (!trainer) throw notFound('Trainer not found');
  withTypeLabels(trainer);

  // Partner-listed trainers publish weekly slots (BRD §7); legacy profiles keep the fixed list.
  if (trainer.weeklySlots?.length) {
    const byDate = slotsByDate(trainer.weeklySlots);
    const availableSlots = [...new Set(byDate.flatMap((d) => d.slots))].sort();
    return res.json({ trainer, availableSlots, slotsByDate: byDate });
  }
  res.json({ trainer, availableSlots: LEGACY_SLOTS });
});

const bookTrainerSchema = z.object({
  mode: z.enum(['online', 'home', 'gym']),
  sessionDate: dateSchema,
  slotTime: z.string().min(4),
});

trainersRouter.post('/:id/book', requireAuth('user'), async (req, res) => {
  const trainer = await queryOne(`SELECT t.* FROM trainers t WHERE t.id = $1 AND ${MEMBER_VISIBLE}`, [req.params.id]);
  if (!trainer) throw notFound('Trainer not found');
  if (!trainer.hourlyRatePaise) throw conflict('This trainer has not set a price yet');

  const data = validate(bookTrainerSchema, req.body);
  if (trainer.trainingModes?.length && !trainer.trainingModes.includes(data.mode)) {
    throw conflict(`This trainer does not offer ${data.mode} sessions`);
  }
  if (trainer.maxSessionsPerDay) {
    const day = await queryOne(
      `SELECT COUNT(*)::int AS n FROM trainer_bookings WHERE trainer_id = $1 AND session_date = $2 AND status <> 'cancelled'`,
      [trainer.id, data.sessionDate],
    );
    if (day.n >= trainer.maxSessionsPerDay) throw conflict('This trainer is fully booked that day. Please pick another date.');
  }

  const booking = await queryOne(
    `INSERT INTO trainer_bookings (
       trainer_id, user_id, mode, session_date, slot_time, duration_minutes, amount_paise, status
     ) VALUES ($1, $2, $3, $4, $5, 60, $6, 'confirmed')
     RETURNING *`,
    [trainer.id, req.user.id, data.mode, data.sessionDate, data.slotTime, trainer.hourlyRatePaise],
  );

  // Tell the trainer (partner app).
  if (trainer.partnerId) {
    const member = await queryOne(`SELECT name FROM users WHERE id = $1`, [req.user.id]);
    await notify(trainer.partnerId, {
      type: 'trainer_booking',
      title: `New ${data.mode} session booked`,
      body: `${member?.name?.trim().split(/\s+/)[0] || 'A member'} booked ${data.sessionDate} at ${data.slotTime}`,
      data: { bookingId: booking.id, trainer: true },
    });
  }

  res.status(201).json({ booking, trainerName: trainer.name });
});

trainersRouter.get('/bookings/me', requireAuth('user'), async (req, res) => {
  const bookings = await query(
    `SELECT b.*, t.name AS trainer_name, t.photo_url, t.specializations,
            r.stars AS my_rating
     FROM trainer_bookings b
     JOIN trainers t ON t.id = b.trainer_id
     LEFT JOIN trainer_ratings r ON r.trainer_id = b.trainer_id AND r.user_id = b.user_id
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

/** GET /partner/trainer/types — the category catalogue for the onboarding picker. */
partnerTrainerRouter.get('/types', (_req, res) => {
  res.json({
    groups: TRAINER_GROUPS.map((g) => ({ key: g.key, label: g.label, types: g.types.map(([key, label]) => ({ key, label })) })),
  });
});

partnerTrainerRouter.get('/profile', async (req, res) => {
  const trainer = await queryOne(`SELECT ${TRAINER_COLS} FROM trainers t WHERE t.partner_id = $1`, [req.user.id]);
  res.json({ trainer: trainer || null });
});

const partnerTrainerSchema = z.object({
  name: z.string().min(2),
  bio: z.string().min(10),
  photoUrl: z.string().optional(),
  certifications: z.array(z.string()).default([]),
  specializations: z.array(z.string()).min(1),
  // BRD §6 trainer types (keys from GET /partner/trainer/types). Optional: derived from specializations when omitted.
  trainerTypes: z.array(z.enum(TRAINER_TYPE_KEYS)).min(1).max(12).optional(),
  trainingModes: z.array(z.enum(['online', 'home', 'gym'])).min(1),
  hourlyRatePaise: z.number().int().min(10000), // at least ₹100
  bufferMinutes: z.number().int().min(0).max(120).default(30),
  workingHours: z.object({ start: z.string(), end: z.string() }).default({ start: '06:00', end: '21:00' }),
});

partnerTrainerRouter.post('/profile', async (req, res) => {
  const data = validate(partnerTrainerSchema, req.body);

  const existing = await queryOne(`SELECT id, trainer_types FROM trainers WHERE partner_id = $1`, [req.user.id]);
  const types = data.trainerTypes
    ? [...new Set(data.trainerTypes)]
    : existing?.trainerTypes?.length
      ? existing.trainerTypes
      : deriveTrainerTypes(data.specializations);

  let saved;
  if (existing) {
    saved = await queryOne(
      `UPDATE trainers SET
         name = $1, bio = $2, photo_url = COALESCE($3, photo_url),
         certifications = $4, specializations = $5, training_modes = $6,
         hourly_rate_paise = $7, buffer_minutes = $8, working_hours = $9, trainer_types = $10
       WHERE id = $11 RETURNING id`,
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
        types,
        existing.id,
      ],
    );
  } else {
    saved = await queryOne(
      `INSERT INTO trainers (
         partner_id, name, bio, photo_url, certifications, specializations,
         training_modes, hourly_rate_paise, buffer_minutes, working_hours, trainer_types, verification_status, listing_status
       ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'pending', 'draft')
       RETURNING id`,
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
        types,
      ],
    );
  }

  const trainer = await queryOne(`SELECT ${TRAINER_COLS} FROM trainers t WHERE t.id = $1`, [saved.id]);
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

// ---------------------------------------------------------------------------------------------- Run / Earn (BRD §10.4)

/** The partner's trainer row (one per owner), or 404. */
async function myTrainer(req) {
  const t = await queryOne(
    `SELECT id, name, weekly_slots, max_sessions_per_day, listing_status FROM trainers WHERE partner_id = $1 ORDER BY created_at LIMIT 1`,
    [req.user.id],
  );
  if (!t) throw notFound('Set up your trainer listing first');
  return t;
}

const calendarSchema = z.object({ from: dateSchema.optional(), days: z.coerce.number().int().min(1).max(31).default(7) });

/**
 * GET /partner/trainer/calendar?from=&days= → { from, to, maxSessionsPerDay, days:[{ date, weekday, sessions, freeSlots, full }] }
 * Session calendar: booked sessions per day + the still-free slots from the weekly availability.
 */
partnerTrainerRouter.get('/calendar', async (req, res) => {
  const f = validate(calendarSchema, req.query);
  const trainer = await myTrainer(req);
  const from = f.from ?? todayIst();
  const to = addDays(from, f.days - 1);
  const sessions = await query(
    `SELECT b.id, b.user_id, b.mode, to_char(b.session_date, 'YYYY-MM-DD') AS date, b.slot_time, b.duration_minutes,
            b.amount_paise, b.status, u.name AS member_name, u.phone AS member_phone
       FROM trainer_bookings b JOIN users u ON u.id = b.user_id
      WHERE b.trainer_id = $1 AND b.session_date BETWEEN $2 AND $3
      ORDER BY b.session_date, b.slot_time`,
    [trainer.id, from, to],
  );
  const days = slotsByDate(trainer.weeklySlots, from, f.days).map(({ date, slots }) => {
    const daySessions = sessions.filter((s) => s.date === date);
    const active = daySessions.filter((s) => s.status !== 'cancelled');
    const taken = new Set(active.map((s) => s.slotTime));
    const full = trainer.maxSessionsPerDay ? active.length >= trainer.maxSessionsPerDay : false;
    return { date, weekday: weekdayOf(date), sessions: daySessions, freeSlots: full ? [] : slots.filter((t) => !taken.has(t)), full };
  });
  res.json({ from, to, maxSessionsPerDay: trainer.maxSessionsPerDay, weeklySlots: trainer.weeklySlots, days });
});

/** GET /partner/trainer/clients → { clients:[{ userId, name, phone, sessions, completed, lastSessionOn, nextSessionOn, totalPaise }] } */
partnerTrainerRouter.get('/clients', async (req, res) => {
  const trainer = await myTrainer(req);
  const clients = await query(
    `SELECT b.user_id, u.name, u.phone,
            COUNT(*) FILTER (WHERE b.status <> 'cancelled')::int AS sessions,
            COUNT(*) FILTER (WHERE b.status = 'completed')::int AS completed,
            to_char(MAX(b.session_date) FILTER (WHERE b.session_date < current_date AND b.status <> 'cancelled'), 'YYYY-MM-DD') AS last_session_on,
            to_char(MIN(b.session_date) FILTER (WHERE b.session_date >= current_date AND b.status = 'confirmed'), 'YYYY-MM-DD') AS next_session_on,
            COALESCE(SUM(b.amount_paise) FILTER (WHERE b.status <> 'cancelled'), 0)::int AS total_paise
       FROM trainer_bookings b JOIN users u ON u.id = b.user_id
      WHERE b.trainer_id = $1
      GROUP BY b.user_id, u.name, u.phone
      ORDER BY MAX(b.session_date) DESC`,
    [trainer.id],
  );
  res.json({ clients });
});

/** POST /partner/trainer/bookings/:id/status { status: 'completed'|'cancelled', note? } — mark a session done / cancel it. */
partnerTrainerRouter.post('/bookings/:id/status', async (req, res) => {
  const d = validate(z.object({ status: z.enum(['completed', 'cancelled']), note: z.string().trim().max(300).optional() }), req.body);
  const trainer = await myTrainer(req);
  const booking = await queryOne(`SELECT * FROM trainer_bookings WHERE id = $1 AND trainer_id = $2`, [req.params.id, trainer.id]);
  if (!booking) throw notFound('Booking not found');
  if (booking.status !== 'confirmed') throw conflict(`This session is already ${booking.status}`);
  const owner = await queryOne(`SELECT partner_go_live_at FROM users WHERE id = $1`, [req.user.id]);
  const updated = await queryOne(
    `UPDATE trainer_bookings SET status = $2::text,
       completed_at = CASE WHEN $2::text = 'completed' THEN now() ELSE completed_at END,
       commission_pct = CASE WHEN $2::text = 'completed' THEN $3::numeric ELSE commission_pct END
     WHERE id = $1 RETURNING *`,
    [booking.id, d.status, commissionPct(owner?.partnerGoLiveAt ?? null, `${booking.sessionDate}T12:00:00Z`)],
  );
  if (d.status === 'cancelled') {
    await notify(booking.userId, {
      type: 'trainer_booking_cancelled',
      title: `${trainer.name} cancelled your ${booking.sessionDate} session`,
      body: d.note ?? null,
      data: { bookingId: booking.id, trainer: true },
    });
  }
  res.json({ booking: updated });
});

/** GET /partner/trainer/earnings?from=&to= — sessions (confirmed / completed), commission by founding-partner year. */
partnerTrainerRouter.get('/earnings', async (req, res) => {
  if (req.staffId) throw forbidden('FitKey staff cannot view partner earnings');
  const f = validate(z.object({ from: dateSchema.optional(), to: dateSchema.optional() }), req.query);
  const trainer = await myTrainer(req);
  const to = f.to ?? todayIst();
  const from = f.from ?? addDays(to, -29);
  const rows = await query(
    `SELECT to_char(session_date, 'YYYY-MM-DD') AS date, amount_paise AS gross_paise, mode AS source
       FROM trainer_bookings
      WHERE trainer_id = $1 AND status IN ('confirmed', 'completed') AND session_date BETWEEN $2 AND $3`,
    [trainer.id, from, to],
  );
  const owner = await queryOne(`SELECT partner_go_live_at FROM users WHERE id = $1`, [req.user.id]);
  res.json({ from, to, ...earningsSummary(rows, owner?.partnerGoLiveAt ?? null) });
});

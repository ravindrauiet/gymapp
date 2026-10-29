import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { notFound, validate } from '../utils/http.js';
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
const TRAINER_COLS = `t.id, t.partner_id, t.name, t.photo_url, t.bio, t.certifications, t.specializations, t.trainer_types,
  t.training_modes, t.hourly_rate_paise, t.buffer_minutes, t.working_hours, t.verification_status, t.created_at,
  t.rating_avg, t.rating_count, t.rating_avg AS rating, t.rating_count AS review_count`;

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
    `SELECT k AS key, COUNT(*)::int AS n FROM trainers, unnest(trainer_types) k
     WHERE verification_status = 'verified' GROUP BY k`,
  );
  const counts = Object.fromEntries(rows.map((r) => [r.key, r.n]));
  const total = await queryOne(`SELECT COUNT(*)::int AS n FROM trainers WHERE verification_status = 'verified'`);
  const groups = [];
  for (const g of TRAINER_GROUPS) {
    const types = g.types.filter(([k]) => counts[k] > 0).map(([key, label]) => ({ key, label, count: counts[key] }));
    if (!types.length) continue;
    const groupCount = await queryOne(
      `SELECT COUNT(*)::int AS n FROM trainers WHERE verification_status = 'verified' AND trainer_types && $1`,
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
  const conditions = ["t.verification_status = 'verified'"];
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

trainersRouter.get('/:id', async (req, res) => {
  const trainer = await queryOne(`SELECT ${TRAINER_COLS} FROM trainers t WHERE t.id = $1`, [req.params.id]);
  if (!trainer) throw notFound('Trainer not found');
  withTypeLabels(trainer);

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
    [trainer.id, req.user.id, data.mode, data.sessionDate, data.slotTime, trainer.hourlyRatePaise],
  );

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
         training_modes, hourly_rate_paise, buffer_minutes, working_hours, trainer_types, verification_status
       ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'verified')
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

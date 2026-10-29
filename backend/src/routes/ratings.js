import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { forbidden, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { uuidSchema } from '../utils/schemas.js';

/**
 * BRD §8 — 1–5 star ratings (no text) for fitness centres and trainers.
 *  - Only verified users rate: centres → has a check-in there; trainers → has a session that has ended (not cancelled).
 *  - One rating per user per centre / trainer; re-posting updates it.
 *  - Ratings ≤ 2 stars open an ops alert (rating_alerts) for the FitKey team.
 *  - Averages are shown as "New" in the apps until a target has ≥ 5 ratings.
 */
const router = Router();

export const NEW_UNTIL = 5;
const ALERT_AT_OR_BELOW = 2;
const PROMPT_AFTER_CHECKIN = '1 hour';
const PROMPT_WINDOW = '7 days';
const MAX_DISMISSALS = 3; // after this many "Not now"s for the same centre / trainer, stop asking

export const SUB_RATINGS = {
  venue: ['cleanliness', 'equipment', 'staff', 'crowd', 'value'],
  trainer: ['knowledge', 'punctuality', 'communication', 'results'],
};

const T = {
  venue: { table: 'venue_ratings', col: 'venue_id', parent: 'venues' },
  trainer: { table: 'trainer_ratings', col: 'trainer_id', parent: 'trainers' },
};

/** End of a trainer booking `b` as timestamptz. slot_time is free text like "06:30 AM"; unparsable → end of day. */
const sessionEndSql = (tzParam) => `(
  (b.session_date + CASE WHEN b.slot_time ~* '^\\s*\\d{1,2}:\\d{2}\\s*([AP]M)?\\s*$' THEN b.slot_time::time ELSE time '23:59' END)
  AT TIME ZONE ${tzParam}::text) + make_interval(mins => b.duration_minutes)`;

/** Reads the bearer token if present (public endpoints that personalise when signed in). */
function optionalUser(req) {
  const header = req.headers.authorization ?? '';
  if (!header.startsWith('Bearer ')) return null;
  try {
    const payload = jwt.verify(header.slice(7), config.jwtSecret);
    return { id: payload.sub, role: payload.role };
  } catch {
    return null;
  }
}

async function canRate(userId, type, targetId, client) {
  if (type === 'venue') {
    const row = await queryOne(
      `SELECT 1 AS ok FROM checkins WHERE user_id = $1 AND venue_id = $2 LIMIT 1`,
      [userId, targetId],
      client,
    );
    return !!row;
  }
  const row = await queryOne(
    `SELECT 1 AS ok FROM trainer_bookings b
     WHERE b.user_id = $1 AND b.trainer_id = $2 AND b.status <> 'cancelled' AND ${sessionEndSql('$3')} <= now()
     LIMIT 1`,
    [userId, targetId, config.tz],
    client,
  );
  return !!row;
}

/** Recomputes the denormalised average / count on venues or trainers. */
async function refreshAggregate(type, targetId, client) {
  const { table, col, parent } = T[type];
  return queryOne(
    `UPDATE ${parent} p SET rating_avg = r.avg, rating_count = r.n
     FROM (SELECT ROUND(AVG(stars)::numeric, 2) AS avg, COUNT(*)::int AS n FROM ${table} WHERE ${col} = $1) r
     WHERE p.id = $1 RETURNING p.rating_avg AS avg, p.rating_count AS count`,
    [targetId],
    client,
  );
}

async function summary(type, targetId, userId) {
  const { table, col, parent } = T[type];
  const agg = await queryOne(`SELECT rating_avg AS avg, rating_count AS count FROM ${parent} WHERE id = $1`, [targetId]);
  if (!agg) throw notFound(type === 'venue' ? 'Centre not found' : 'Trainer not found');
  const dist = await query(`SELECT stars, COUNT(*)::int AS n FROM ${table} WHERE ${col} = $1 GROUP BY stars`, [targetId]);
  const subs = await query(
    `SELECT s.key, ROUND(AVG(s.value::int)::numeric, 2) AS avg, COUNT(*)::int AS n
     FROM ${table} r, jsonb_each_text(r.sub_ratings) s WHERE r.${col} = $1 GROUP BY s.key`,
    [targetId],
  );
  const distribution = { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 };
  for (const d of dist) distribution[d.stars] = d.n;
  const subRatings = {};
  for (const s of subs) if (SUB_RATINGS[type].includes(s.key)) subRatings[s.key] = { avg: s.avg, count: s.n };

  let myRating = null;
  let eligible = null;
  if (userId) {
    myRating = await queryOne(
      `SELECT stars, sub_ratings, updated_at FROM ${table} WHERE user_id = $1 AND ${col} = $2`,
      [userId, targetId],
    );
    eligible = await canRate(userId, type, targetId);
  }
  return {
    targetType: type,
    targetId,
    avg: agg.avg,
    count: agg.count,
    isNew: agg.count < NEW_UNTIL,
    distribution,
    subRatings,
    subRatingKeys: SUB_RATINGS[type],
    myRating,
    canRate: eligible,
  };
}

// ============================================================================
// Admin — ops alerts for ratings ≤ 2 stars (defined before /:targetType/:id so "admin" isn't a target type)
// ============================================================================

const alertsQuerySchema = z.object({
  status: z.enum(['open', 'resolved', 'all']).default('open'),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  before: z.string().datetime().optional(),
});

/** GET /ratings/admin/alerts?status=open|resolved|all&limit=&before= — newest first. */
router.get('/admin/alerts', requireAuth('admin'), async (req, res) => {
  const f = validate(alertsQuerySchema, req.query);
  const params = [f.limit];
  const where = [];
  if (f.status !== 'all') {
    params.push(f.status);
    where.push(`a.status = $${params.length}`);
  }
  if (f.before) {
    params.push(f.before);
    where.push(`a.created_at < $${params.length}`);
  }
  const alerts = await query(
    `SELECT a.id, a.target_type, a.target_id, a.stars, a.sub_ratings, a.status, a.resolution_note, a.resolved_at,
            a.created_at, a.updated_at,
            COALESCE(v.name, t.name) AS target_name, v.area AS venue_area, v.city AS venue_city,
            u.id AS user_id, u.name AS user_name, u.phone AS user_phone,
            rb.name AS resolved_by_name
     FROM rating_alerts a
     JOIN users u ON u.id = a.user_id
     LEFT JOIN venues v ON a.target_type = 'venue' AND v.id = a.target_id
     LEFT JOIN trainers t ON a.target_type = 'trainer' AND t.id = a.target_id
     LEFT JOIN users rb ON rb.id = a.resolved_by
     ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
     ORDER BY a.created_at DESC LIMIT $1`,
    params,
  );
  const counts = await queryOne(
    `SELECT COUNT(*) FILTER (WHERE status = 'open')::int AS open, COUNT(*) FILTER (WHERE status = 'resolved')::int AS resolved
     FROM rating_alerts`,
  );
  res.json({ alerts, counts });
});

const resolveSchema = z.object({
  status: z.enum(['open', 'resolved']).default('resolved'),
  note: z.string().trim().max(500).optional(),
});

/** PATCH /ratings/admin/alerts/:id { status?: resolved|open, note? } */
router.patch('/admin/alerts/:id', requireAuth('admin'), async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const body = validate(resolveSchema, req.body ?? {});
  const resolved = body.status === 'resolved';
  const alert = await queryOne(
    `UPDATE rating_alerts SET status = $2, resolution_note = COALESCE($3, resolution_note),
            resolved_by = CASE WHEN $4 THEN $5::uuid END, resolved_at = CASE WHEN $4 THEN now() END, updated_at = now()
     WHERE id = $1 RETURNING *`,
    [id, body.status, body.note ?? null, resolved, req.user.id],
  );
  if (!alert) throw notFound('Alert not found');
  res.json({ alert });
});

// ============================================================================
// Partners — ratings dashboard for the venues I own (venues.owner_id) and my trainer profile (trainers.partner_id).
// Members stay anonymous: the feed shows at most a masked first name, never names / phones / ids.
// ============================================================================

const partner = Router();
partner.use(requireAuth('partner'));
router.use('/partner', partner);

const TREND_MONTHS = 6;

/** The venue (by id) or trainer profile this partner owns; 404 when it isn't theirs. */
async function ownedTarget(type, partnerId, venueId) {
  const row =
    type === 'venue'
      ? await queryOne(
          `SELECT id, name, area, city, categories, photos[1] AS photo_url, status FROM venues WHERE id = $1 AND owner_id = $2`,
          [venueId, partnerId],
        )
      : await queryOne(`SELECT id, name, photo_url FROM trainers WHERE partner_id = $1`, [partnerId]);
  if (!row) throw notFound(type === 'venue' ? 'Centre not found' : 'You have no trainer profile yet');
  return row;
}

/** Average / count per month for the last TREND_MONTHS months (empty months included, avg null). */
async function monthlyTrend(type, targetId) {
  const { table, col } = T[type];
  return query(
    `WITH months AS (
       SELECT generate_series(date_trunc('month', now() AT TIME ZONE $2) - make_interval(months => $3 - 1),
                              date_trunc('month', now() AT TIME ZONE $2), interval '1 month')::date AS m
     )
     SELECT to_char(months.m, 'YYYY-MM') AS month, ROUND(AVG(r.stars)::numeric, 2) AS avg, COUNT(r.stars)::int AS count
     FROM months
     LEFT JOIN ${table} r ON r.${col} = $1 AND date_trunc('month', r.updated_at AT TIME ZONE $2)::date = months.m
     GROUP BY months.m ORDER BY months.m`,
    [targetId, config.tz, TREND_MONTHS],
  );
}

async function partnerSummary(type, target) {
  const { table, col } = T[type];
  const s = await summary(type, target.id, null);
  const recent = await queryOne(
    `SELECT ROUND(AVG(stars)::numeric, 2) AS avg, COUNT(*)::int AS count,
            ROUND(AVG(stars) FILTER (WHERE updated_at < now() - interval '30 days')::numeric, 2) AS before_avg
     FROM ${table} WHERE ${col} = $1 AND updated_at >= now() - interval '60 days'`,
    [target.id],
  );
  const last30 = await queryOne(
    `SELECT ROUND(AVG(stars)::numeric, 2) AS avg, COUNT(*)::int AS count FROM ${table}
     WHERE ${col} = $1 AND updated_at >= now() - interval '30 days'`,
    [target.id],
  );
  const { myRating: _m, canRate: _c, ...rest } = s;
  return {
    ...rest,
    newUntil: NEW_UNTIL,
    target: { ...target, type },
    trend: await monthlyTrend(type, target.id),
    last30Days: { avg: last30.avg, count: last30.count, previousAvg: recent.beforeAvg },
  };
}

const feedQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(50).default(20),
  before: z.string().datetime({ offset: true }).optional(),
});

async function partnerFeed(type, targetId, q) {
  const { table, col } = T[type];
  const ratings = await query(
    `SELECT r.stars, r.sub_ratings, r.created_at, r.updated_at, (r.updated_at > r.created_at + interval '1 minute') AS edited,
            CASE WHEN NULLIF(trim(u.name), '') IS NULL THEN 'FitKey member'
                 ELSE upper(left(trim(u.name), 1)) || '•••'
            END AS member
     FROM ${table} r JOIN users u ON u.id = r.user_id
     WHERE r.${col} = $1 AND ($2::timestamptz IS NULL OR r.updated_at < $2)
     ORDER BY r.updated_at DESC LIMIT $3`,
    [targetId, q.before ?? null, q.limit],
  );
  return { ratings, nextBefore: ratings.length === q.limit ? ratings.at(-1).updatedAt : null };
}

/** GET /ratings/partner/targets — my venues + trainer profile with their headline rating. */
partner.get('/targets', async (req, res) => {
  const venues = await query(
    `SELECT id, name, area, city, categories, photos[1] AS photo_url, status, rating_avg AS avg, rating_count AS count
     FROM venues WHERE owner_id = $1 ORDER BY created_at`,
    [req.user.id],
  );
  const trainer = await queryOne(
    `SELECT id, name, photo_url, rating_avg AS avg, rating_count AS count FROM trainers WHERE partner_id = $1`,
    [req.user.id],
  );
  const mark = (r) => ({ ...r, isNew: r.count < NEW_UNTIL });
  res.json({ venues: venues.map(mark), trainer: trainer ? mark(trainer) : null, newUntil: NEW_UNTIL });
});

/** GET /ratings/partner/venues/:id — summary, star breakdown, sub-rating averages, monthly trend. */
partner.get('/venues/:id', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  res.json({ summary: await partnerSummary('venue', await ownedTarget('venue', req.user.id, id)) });
});

/** GET /ratings/partner/venues/:id/ratings?limit=&before= — recent ratings (anonymous), newest first. */
partner.get('/venues/:id/ratings', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const q = validate(feedQuerySchema, req.query);
  const target = await ownedTarget('venue', req.user.id, id);
  res.json(await partnerFeed('venue', target.id, q));
});

/** GET /ratings/partner/trainer — same for my trainer profile. */
partner.get('/trainer', async (req, res) => {
  res.json({ summary: await partnerSummary('trainer', await ownedTarget('trainer', req.user.id)) });
});

/** GET /ratings/partner/trainer/ratings?limit=&before= */
partner.get('/trainer/ratings', async (req, res) => {
  const q = validate(feedQuerySchema, req.query);
  const target = await ownedTarget('trainer', req.user.id);
  res.json(await partnerFeed('trainer', target.id, q));
});

// ============================================================================
// Members
// ============================================================================

/**
 * GET /ratings/pending — unrated centres / trainers the member can rate now:
 * centres with a check-in ≥ 1 h ago (within 7 days), trainers whose session ended (within 7 days).
 * Skips visits the member dismissed ("Not now") and targets dismissed 3+ times.
 * Each new visit also creates one in-app notification (no push infra yet).
 */
router.get('/pending', requireAuth('user'), async (req, res) => {
  const uid = req.user.id;
  const notDismissed = (type) => `
    NOT EXISTS (SELECT 1 FROM rating_prompts rp WHERE rp.user_id = $1 AND rp.target_type = '${type}'
                AND rp.source_id = x.source_id AND rp.dismissed_at IS NOT NULL)
    AND (SELECT COUNT(*) FROM rating_prompts rp WHERE rp.user_id = $1 AND rp.target_type = '${type}'
         AND rp.target_id = x.target_id AND rp.dismissed_at IS NOT NULL) < ${MAX_DISMISSALS}`;

  const venues = await query(
    `SELECT 'venue' AS target_type, x.* FROM (
       SELECT DISTINCT ON (c.venue_id) c.id AS source_id, c.venue_id AS target_id, c.checked_in_at AS occurred_at,
              v.name, v.photos[1] AS photo_url, v.categories, NULLIF(CONCAT_WS(', ', v.area, v.city), '') AS subtitle
       FROM checkins c JOIN venues v ON v.id = c.venue_id AND v.status = 'live'
       WHERE c.user_id = $1
         AND c.checked_in_at <= now() - interval '${PROMPT_AFTER_CHECKIN}'
         AND c.checked_in_at >= now() - interval '${PROMPT_WINDOW}'
         AND NOT EXISTS (SELECT 1 FROM venue_ratings r WHERE r.user_id = c.user_id AND r.venue_id = c.venue_id)
       ORDER BY c.venue_id, c.checked_in_at DESC
     ) x WHERE ${notDismissed('venue')}`,
    [uid],
  );

  const trainers = await query(
    `SELECT 'trainer' AS target_type, x.* FROM (
       SELECT DISTINCT ON (b.trainer_id) b.id AS source_id, b.trainer_id AS target_id, ${sessionEndSql('$2')} AS occurred_at,
              t.name, t.photo_url, NULL::text[] AS categories,
              b.mode || ' session · ' || to_char(b.session_date, 'DD Mon') || ', ' || b.slot_time AS subtitle
       FROM trainer_bookings b JOIN trainers t ON t.id = b.trainer_id
       WHERE b.user_id = $1 AND b.status <> 'cancelled'
         AND ${sessionEndSql('$2')} <= now()
         AND ${sessionEndSql('$2')} >= now() - interval '${PROMPT_WINDOW}'
         AND NOT EXISTS (SELECT 1 FROM trainer_ratings r WHERE r.user_id = b.user_id AND r.trainer_id = b.trainer_id)
       ORDER BY b.trainer_id, ${sessionEndSql('$2')} DESC
     ) x WHERE ${notDismissed('trainer')}`,
    [uid, config.tz],
  );

  const items = [...trainers, ...venues].sort((a, b) => new Date(b.occurredAt) - new Date(a.occurredAt));

  for (const it of items) {
    it.subRatingKeys = SUB_RATINGS[it.targetType];
    const fresh = await queryOne(
      `INSERT INTO rating_prompts (user_id, target_type, target_id, source_id) VALUES ($1, $2, $3, $4)
       ON CONFLICT DO NOTHING RETURNING source_id`,
      [uid, it.targetType, it.targetId, it.sourceId],
    );
    if (fresh) {
      await notify(uid, {
        type: 'rating',
        title: it.targetType === 'venue' ? `How was your visit to ${it.name}?` : `How was your session with ${it.name}?`,
        body: 'Tap to rate it — it takes 5 seconds and helps other members.',
        data: it.targetType === 'venue' ? { venueId: it.targetId } : { trainerId: it.targetId },
      });
    }
  }

  res.json({ items });
});

const dismissSchema = z.object({
  targetType: z.enum(['venue', 'trainer']),
  targetId: uuidSchema,
  sourceId: uuidSchema,
});

/** POST /ratings/dismiss { targetType, targetId, sourceId } — "Not now" for this visit. */
router.post('/dismiss', requireAuth('user'), async (req, res) => {
  const b = validate(dismissSchema, req.body);
  await query(
    `INSERT INTO rating_prompts (user_id, target_type, target_id, source_id, dismissed_at) VALUES ($1, $2, $3, $4, now())
     ON CONFLICT (user_id, target_type, source_id) DO UPDATE SET dismissed_at = now()`,
    [req.user.id, b.targetType, b.targetId, b.sourceId],
  );
  res.json({ ok: true });
});

const star = z.number().int().min(1).max(5);
const subSchema = (type) =>
  z
    .object(Object.fromEntries(SUB_RATINGS[type].map((k) => [k, star.optional()])))
    .strict()
    .default({});

const rateSchema = z.discriminatedUnion('targetType', [
  z.object({ targetType: z.literal('venue'), targetId: uuidSchema, stars: star, subRatings: subSchema('venue') }),
  z.object({ targetType: z.literal('trainer'), targetId: uuidSchema, stars: star, subRatings: subSchema('trainer') }),
]);

/** POST /ratings { targetType: venue|trainer, targetId, stars 1–5, subRatings? } — create or update my rating. */
router.post('/', requireAuth('user'), async (req, res) => {
  const b = validate(rateSchema, req.body);
  const { table, col, parent } = T[b.targetType];
  const uid = req.user.id;
  const subs = Object.fromEntries(Object.entries(b.subRatings).filter(([, v]) => v != null));

  const result = await withTransaction(async (client) => {
    const target = await queryOne(`SELECT id, name FROM ${parent} WHERE id = $1`, [b.targetId], client);
    if (!target) throw notFound(b.targetType === 'venue' ? 'Centre not found' : 'Trainer not found');
    if (!(await canRate(uid, b.targetType, b.targetId, client))) {
      throw forbidden(
        b.targetType === 'venue'
          ? 'You can rate a centre after you check in there'
          : 'You can rate a trainer after your session with them',
      );
    }

    const rating = await queryOne(
      `INSERT INTO ${table} (user_id, ${col}, stars, sub_ratings) VALUES ($1, $2, $3, $4)
       ON CONFLICT (user_id, ${col}) DO UPDATE SET stars = EXCLUDED.stars, sub_ratings = EXCLUDED.sub_ratings, updated_at = now()
       RETURNING stars, sub_ratings, created_at, updated_at, (xmax = 0) AS created`,
      [uid, b.targetId, b.stars, subs],
      client,
    );
    const agg = await refreshAggregate(b.targetType, b.targetId, client);

    let alertId = null;
    if (b.stars <= ALERT_AT_OR_BELOW) {
      const open = await queryOne(
        `UPDATE rating_alerts SET stars = $4, sub_ratings = $5, updated_at = now()
         WHERE user_id = $1 AND target_type = $2 AND target_id = $3 AND status = 'open' RETURNING id`,
        [uid, b.targetType, b.targetId, b.stars, subs],
        client,
      );
      const row =
        open ??
        (await queryOne(
          `INSERT INTO rating_alerts (target_type, target_id, user_id, stars, sub_ratings) VALUES ($1, $2, $3, $4, $5)
           RETURNING id`,
          [b.targetType, b.targetId, uid, b.stars, subs],
          client,
        ));
      alertId = row.id;
    }
    return { rating, agg, alertId };
  });

  // Tell the centre owner / trainer (partner app). Anonymous: stars only, no member details.
  const owner = await queryOne(
    b.targetType === 'venue'
      ? `SELECT owner_id AS partner_id, name FROM venues WHERE id = $1`
      : `SELECT partner_id, name FROM trainers WHERE id = $1`,
    [b.targetId],
  );
  if (owner?.partnerId) {
    const { avg, count } = result.agg;
    await notify(owner.partnerId, {
      type: 'rating_received',
      title: `${result.rating.created ? 'New' : 'Updated'} ${b.stars}★ rating for ${b.targetType === 'venue' ? owner.name : 'your training'}`,
      body:
        count < NEW_UNTIL
          ? `${count} of ${NEW_UNTIL} ratings — your average shows to members after ${NEW_UNTIL}.`
          : `Your average is now ${Number(avg).toFixed(1)}★ from ${count} ratings.`,
      data:
        b.targetType === 'venue'
          ? { venueId: b.targetId, stars: b.stars }
          : { trainer: true, trainerId: b.targetId, stars: b.stars },
    });
  }

  res.status(result.rating.created ? 201 : 200).json({
    rating: { stars: result.rating.stars, subRatings: result.rating.subRatings, updatedAt: result.rating.updatedAt },
    summary: { avg: result.agg.avg, count: result.agg.count, isNew: result.agg.count < NEW_UNTIL },
    alerted: result.alertId != null,
  });
});

/** GET /ratings/:targetType/:id — average, count, distribution, sub-rating averages; myRating + canRate when signed in. */
router.get('/:targetType/:id', async (req, res) => {
  const type = validate(z.enum(['venue', 'trainer']), req.params.targetType);
  const id = validate(uuidSchema, req.params.id);
  const u = optionalUser(req);
  res.json({ summary: await summary(type, id, u?.role === 'user' ? u.id : null) });
});

export default router;

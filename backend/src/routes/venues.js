import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../db/index.js';
import { notFound, validate } from '../utils/http.js';
import { VENUE_CATEGORY_IDS } from '../utils/constants.js';
import { pagination } from '../utils/schemas.js';

const router = Router();

/** SQL for great-circle distance (km) from ($lat, $lng) placeholders to the venue row `v`. */
export const distanceSql = (latParam, lngParam) => `
  6371 * 2 * ASIN(SQRT(
    POWER(SIN(RADIANS(v.latitude - ${latParam}) / 2), 2) +
    COS(RADIANS(${latParam})) * COS(RADIANS(v.latitude)) *
    POWER(SIN(RADIANS(v.longitude - ${lngParam}) / 2), 2)
  ))`;

const searchSchema = z.object({
  category: z.enum(VENUE_CATEGORY_IDS).optional(),
  city: z.string().trim().min(1).optional(),
  q: z.string().trim().min(1).max(80).optional(),
  lat: z.coerce.number().min(-90).max(90).optional(),
  lng: z.coerce.number().min(-180).max(180).optional(),
  radiusKm: z.coerce.number().positive().max(200).optional(),
  minRating: z.coerce.number().min(1).max(5).optional(),
  sort: z.enum(['relevance', 'rating', 'distance']).optional(),
  ...pagination,
});

/** Ranking key that only trusts averages backed by ≥ 5 ratings ("New" venues sort after rated ones). */
const RATED_AVG = `CASE WHEN t.rating_count >= 5 THEN t.rating_avg END`;

/**
 * GET /venues — search live venues by category, city, text and/or distance; optional minRating filter
 * (only venues with ≥ 5 ratings qualify). Order:
 *   sort=relevance (default): text relevance when searching → rating → distance → name
 *   sort=rating: rating → distance;  sort=distance: nearest first (needs lat/lng) → rating.
 */
router.get('/', async (req, res) => {
  const f = validate(searchSchema, req.query);
  const params = [];
  const where = [`v.status = 'live'`];
  const p = (value) => {
    params.push(value);
    return `$${params.length}`;
  };

  if (f.category) where.push(`${p(f.category)} = ANY(v.categories)`);
  if (f.city) where.push(`v.city ILIKE ${p(f.city)}`);
  let relevance = '0';
  if (f.q) {
    const like = p(`%${f.q}%`);
    const prefix = p(`${f.q}%`);
    where.push(`(v.name ILIKE ${like} OR v.area ILIKE ${like} OR v.address ILIKE ${like})`);
    relevance = `(CASE WHEN v.name ILIKE ${prefix} THEN 4 WHEN v.name ILIKE ${like} THEN 3 ELSE 0 END
      + CASE WHEN v.area ILIKE ${like} THEN 2 ELSE 0 END + CASE WHEN v.address ILIKE ${like} THEN 1 ELSE 0 END)`;
  }
  if (f.minRating) where.push(`v.rating_count >= 5 AND v.rating_avg >= ${p(f.minRating)}`);

  const hasGeo = f.lat !== undefined && f.lng !== undefined;
  const distance = hasGeo ? distanceSql(p(f.lat), p(f.lng)) : 'NULL::float';

  const byRating = `${RATED_AVG} DESC NULLS LAST, t.rating_count DESC`;
  const order = {
    relevance: `t.relevance DESC, ${byRating}, t.distance_km NULLS LAST, t.name`,
    rating: `${byRating}, t.distance_km NULLS LAST, t.name`,
    distance: `t.distance_km NULLS LAST, ${byRating}, t.name`,
  }[f.sort ?? 'relevance'];

  const limit = p(f.limit);
  const offset = p((f.page - 1) * f.limit);

  const venues = await query(
    `SELECT * FROM (
       SELECT v.id, v.name, v.area, v.city, v.categories, v.opens_at, v.closes_at,
              v.trainer_available, v.amenities, v.photos[1] AS cover_photo, v.latitude, v.longitude,
              v.rating_avg, v.rating_count, ${relevance} AS relevance,
              ${distance} AS distance_km
       FROM venues v WHERE ${where.join(' AND ')}
     ) t
     ${hasGeo && f.radiusKm ? `WHERE t.distance_km <= ${p(f.radiusKm)}` : ''}
     ORDER BY ${order}
     LIMIT ${limit} OFFSET ${offset}`,
    params,
  );
  for (const v of venues) delete v.relevance;

  res.json({ venues, page: f.page, limit: f.limit });
});

/** GET /venues/:id — full venue details plus the plans that unlock it. */
router.get('/:id', async (req, res) => {
  const venue = await queryOne(
    `SELECT id, name, description, categories, address, area, city, latitude, longitude, opens_at, closes_at,
            open_days, contact_phone, contact_email, trainer_available, equipment, amenities, photos,
            rating_avg, rating_count
     FROM venues WHERE id = $1 AND status = 'live'`,
    [req.params.id],
  );
  if (!venue) throw notFound('Venue not found');

  const plans = await query(
    `SELECT id, name, price_paise, duration_days FROM plans
     WHERE is_active AND categories && $1 ORDER BY sort_order, price_paise`,
    [venue.categories],
  );
  res.json({ venue, plans });
});

export default router;

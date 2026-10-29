import { Router } from 'express';
import { z } from 'zod';
import { query } from '../db/index.js';
import { validate } from '../utils/http.js';

const router = Router();

const listQuery = z.object({
  city: z.string().trim().max(80).optional(),
  q: z.string().trim().max(80).optional(),
});

/** Escapes LIKE wildcards in user input. */
const likeEscape = (s) => s.replace(/[\\%_]/g, (c) => `\\${c}`);

/**
 * Builds WHERE + ORDER BY for a directory search: every word of `q` must appear somewhere in `haystack`
 * (name, address/area, city, specialities…), with a typo-tolerant fallback on the name.
 */
function directoryFilter({ city, q }, haystack) {
  const conditions = [];
  const params = [];
  const p = (v) => {
    params.push(v);
    return `$${params.length}`;
  };
  if (city) conditions.push(`lower(city) = lower(${p(city)})`);
  let order = 'distance_km ASC';
  const term = q?.toLowerCase();
  if (term) {
    const words = term.split(/\s+/).filter(Boolean).slice(0, 6);
    const all = words.map((w) => `${haystack} LIKE ${p(`%${likeEscape(w)}%`)}`).join(' AND ');
    const qp = p(term);
    conditions.push(`((${all}) OR word_similarity(${qp}, lower(name)) >= 0.5)`);
    order = `(lower(name) LIKE ${p(`%${likeEscape(term)}%`)}) DESC, distance_km ASC`;
  }
  return { where: conditions.length ? `WHERE ${conditions.join(' AND ')}` : '', order, params };
}

/** GET /healthstop/chemists?city=&q= — search by name, address / area or city. */
router.get('/chemists', async (req, res) => {
  const f = validate(listQuery, req.query);
  const { where, order, params } = directoryFilter(f, `lower(concat_ws(' ', name, address, city))`);
  const chemists = await query(`SELECT * FROM health_chemists ${where} ORDER BY ${order}`, params);
  res.json({ chemists });
});

/** GET /healthstop/clinics?city=&q= — search by name, address / area, city, doctor names & specialities, facilities. */
router.get('/clinics', async (req, res) => {
  const f = validate(listQuery, req.query);
  const haystack = `lower(concat_ws(' ', name, address, city, array_to_string(facilities, ' '),
    (SELECT string_agg(concat_ws(' ', d->>'name', d->>'specialty', d->>'degree'), ' ')
       FROM jsonb_array_elements(doctors) d)))`;
  const { where, order, params } = directoryFilter(f, haystack);
  const clinics = await query(`SELECT * FROM health_clinics ${where} ORDER BY ${order}`, params);
  res.json({ clinics });
});

export default router;

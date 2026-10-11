import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, conflict, forbidden, notFound, validate } from '../utils/http.js';
import { dateSchema, timeSchema, uuidSchema } from '../utils/schemas.js';

/**
 * Find your gym buddy (U6):
 * 1. Each user posts "I'm going to <venue> on <date> between <start>-<end>".
 * 2. GET /buddy/posts/:id/matches lists others with an overlapping slot at the same venue.
 * 3. A sends a request (from A's post to B's post); B accepts → both can chat.
 */
const router = Router();
router.use(requireAuth('user'));

const NOT_BLOCKED = (meParam, otherCol) => `NOT EXISTS (
  SELECT 1 FROM user_blocks b
  WHERE (b.blocker_id = ${meParam} AND b.blocked_id = ${otherCol})
     OR (b.blocker_id = ${otherCol} AND b.blocked_id = ${meParam}))`;

const postSchema = z.object({
  venueId: uuidSchema,
  slotDate: dateSchema,
  slotStart: timeSchema,
  slotEnd: timeSchema,
  note: z.string().trim().max(280).optional(),
});

router.post('/posts', async (req, res) => {
  const body = validate(postSchema, req.body);
  if (body.slotEnd <= body.slotStart) throw badRequest('End time must be after start time');

  const venue = await queryOne(`SELECT id FROM venues WHERE id = $1 AND status = 'live'`, [body.venueId]);
  if (!venue) throw notFound('Venue not found');

  const today = await queryOne(`SELECT (now() AT TIME ZONE $1)::date AS d`, [config.tz]);
  if (body.slotDate < today.d) throw badRequest('Pick today or a future date');

  const post = await queryOne(
    `INSERT INTO buddy_posts (user_id, venue_id, slot_date, slot_start, slot_end, note)
     VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
    [req.user.id, body.venueId, body.slotDate, body.slotStart, body.slotEnd, body.note ?? null],
  );
  res.status(201).json({ post });
});

/** GET /buddy/posts/me — my upcoming posts with match counts. */
router.get('/posts/me', async (req, res) => {
  const posts = await query(
    `SELECT bp.*, v.name AS venue_name, v.area AS venue_area,
       (SELECT COUNT(*) FROM buddy_posts o
        WHERE o.venue_id = bp.venue_id AND o.slot_date = bp.slot_date AND o.user_id <> bp.user_id
          AND o.slot_start < bp.slot_end AND o.slot_end > bp.slot_start
          AND ${NOT_BLOCKED('$1', 'o.user_id')}) AS match_count
     FROM buddy_posts bp JOIN venues v ON v.id = bp.venue_id
     WHERE bp.user_id = $1 AND bp.slot_date >= (now() AT TIME ZONE $2)::date
     ORDER BY bp.slot_date, bp.slot_start`,
    [req.user.id, config.tz],
  );
  res.json({ posts });
});

router.delete('/posts/:id', async (req, res) => {
  const deleted = await queryOne(`DELETE FROM buddy_posts WHERE id = $1 AND user_id = $2 RETURNING id`, [
    req.params.id,
    req.user.id,
  ]);
  if (!deleted) throw notFound('Post not found');
  res.status(204).end();
});

/** GET /buddy/posts/:id/matches — people going to the same venue at an overlapping time. */
router.get('/posts/:id/matches', async (req, res) => {
  const mine = await queryOne(`SELECT * FROM buddy_posts WHERE id = $1 AND user_id = $2`, [req.params.id, req.user.id]);
  if (!mine) throw notFound('Post not found');

  const matches = await query(
    `SELECT o.id AS post_id, o.slot_start, o.slot_end, o.note,
            u.id AS user_id, u.name, u.gender, u.city, u.avatar_url,
            r.id AS request_id, r.status AS request_status,
            CASE WHEN r.id IS NULL THEN NULL WHEN r.from_user_id = $2 THEN 'outgoing' ELSE 'incoming' END AS request_direction
     FROM buddy_posts o
     JOIN users u ON u.id = o.user_id
     LEFT JOIN buddy_requests r ON (r.from_post_id = $1 AND r.to_post_id = o.id) OR (r.from_post_id = o.id AND r.to_post_id = $1)
     WHERE o.venue_id = $3 AND o.slot_date = $4 AND o.user_id <> $2
       AND o.slot_start < $6 AND o.slot_end > $5
       AND ${NOT_BLOCKED('$2', 'o.user_id')}
     ORDER BY o.slot_start`,
    [mine.id, req.user.id, mine.venueId, mine.slotDate, mine.slotStart, mine.slotEnd],
  );
  res.json({ matches });
});

/** POST /buddy/requests { fromPostId, toPostId } — opt in to going together. */
router.post('/requests', async (req, res) => {
  const { fromPostId, toPostId } = validate(z.object({ fromPostId: uuidSchema, toPostId: uuidSchema }), req.body);

  const from = await queryOne(`SELECT * FROM buddy_posts WHERE id = $1 AND user_id = $2`, [fromPostId, req.user.id]);
  if (!from) throw notFound('Your post was not found');
  const to = await queryOne(
    `SELECT o.* FROM buddy_posts o
     WHERE o.id = $1 AND o.venue_id = $2 AND o.slot_date = $3 AND o.user_id <> $4
       AND o.slot_start < $6 AND o.slot_end > $5 AND ${NOT_BLOCKED('$4', 'o.user_id')}`,
    [toPostId, from.venueId, from.slotDate, req.user.id, from.slotStart, from.slotEnd],
  );
  if (!to) throw notFound('That buddy slot is no longer available');

  const existing = await queryOne(
    `SELECT id FROM buddy_requests WHERE (from_post_id = $1 AND to_post_id = $2) OR (from_post_id = $2 AND to_post_id = $1)`,
    [fromPostId, toPostId],
  );
  if (existing) throw conflict('A request already exists between these slots');

  const request = await queryOne(
    `INSERT INTO buddy_requests (from_post_id, to_post_id, from_user_id, to_user_id)
     VALUES ($1, $2, $3, $4) RETURNING *`,
    [fromPostId, toPostId, req.user.id, to.userId],
  );
  res.status(201).json({ request });
});

/** GET /buddy/requests — all my buddy connections (incoming, outgoing, accepted). */
router.get('/requests', async (req, res) => {
  const requests = await query(
    `SELECT r.id, r.status, r.created_at,
            CASE WHEN r.from_user_id = $1 THEN 'outgoing' ELSE 'incoming' END AS direction,
            u.id AS other_user_id, u.name AS other_name, u.gender AS other_gender, u.avatar_url AS other_avatar_url,
            v.name AS venue_name, p.slot_date, p.slot_start, p.slot_end,
            (SELECT body FROM buddy_messages m WHERE m.request_id = r.id ORDER BY m.created_at DESC LIMIT 1) AS last_message
     FROM buddy_requests r
     JOIN users u ON u.id = CASE WHEN r.from_user_id = $1 THEN r.to_user_id ELSE r.from_user_id END
     JOIN buddy_posts p ON p.id = r.to_post_id
     JOIN venues v ON v.id = p.venue_id
     WHERE (r.from_user_id = $1 OR r.to_user_id = $1) AND r.status <> 'declined'
       AND ${NOT_BLOCKED('$1', 'u.id')}
     ORDER BY r.updated_at DESC`,
    [req.user.id],
  );
  res.json({ requests });
});

/** PATCH /buddy/requests/:id { status: accepted|declined } — only the recipient can respond. */
router.patch('/requests/:id', async (req, res) => {
  const { status } = validate(z.object({ status: z.enum(['accepted', 'declined']) }), req.body);
  const request = await queryOne(
    `UPDATE buddy_requests SET status = $3, updated_at = now()
     WHERE id = $1 AND to_user_id = $2 AND status = 'pending' RETURNING *`,
    [req.params.id, req.user.id, status],
  );
  if (!request) throw notFound('Pending request not found');
  res.json({ request });
});

async function loadAcceptedRequest(requestId, userId) {
  const request = await queryOne(`SELECT * FROM buddy_requests WHERE id = $1 AND (from_user_id = $2 OR to_user_id = $2)`, [
    requestId,
    userId,
  ]);
  if (!request) throw notFound('Conversation not found');
  if (request.status !== 'accepted') throw forbidden('Chat opens once both of you have opted in');
  return request;
}

/** GET /buddy/requests/:id/messages?after=<ISO timestamp> — poll for new messages. */
router.get('/requests/:id/messages', async (req, res) => {
  const { after } = validate(z.object({ after: z.string().datetime({ offset: true }).optional() }), req.query);
  await loadAcceptedRequest(req.params.id, req.user.id);
  const messages = await query(
    `SELECT id, sender_id, body, created_at, (sender_id = $2) AS is_mine FROM buddy_messages
     WHERE request_id = $1 AND ($3::timestamptz IS NULL OR created_at > $3)
     ORDER BY created_at ASC LIMIT 200`,
    [req.params.id, req.user.id, after ?? null],
  );
  res.json({ messages });
});

router.post('/requests/:id/messages', async (req, res) => {
  const { body } = validate(z.object({ body: z.string().trim().min(1).max(1000) }), req.body);
  await loadAcceptedRequest(req.params.id, req.user.id);
  const message = await queryOne(
    `INSERT INTO buddy_messages (request_id, sender_id, body) VALUES ($1, $2, $3)
     RETURNING id, sender_id, body, created_at, true AS is_mine`,
    [req.params.id, req.user.id, body],
  );
  res.status(201).json({ message });
});

/** POST /buddy/block { userId } — hides each user from the other everywhere in buddy. */
router.post('/block', async (req, res) => {
  const { userId } = validate(z.object({ userId: uuidSchema }), req.body);
  if (userId === req.user.id) throw badRequest('You cannot block yourself');
  await query(`INSERT INTO user_blocks (blocker_id, blocked_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [
    req.user.id,
    userId,
  ]);
  res.status(204).end();
});

/** POST /buddy/report { userId, reason } — flags a user for the FITKEY team. */
router.post('/report', async (req, res) => {
  const { userId, reason } = validate(
    z.object({ userId: uuidSchema, reason: z.string().trim().min(3).max(500) }),
    req.body,
  );
  await query(`INSERT INTO user_reports (reporter_id, reported_id, reason) VALUES ($1, $2, $3)`, [
    req.user.id,
    userId,
    reason,
  ]);
  res.status(201).json({ message: 'Thanks — our team will review this report' });
});

export default router;

import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, forbidden, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';

/**
 * FitFeed (BRD §1) — content feed: photo posts, blogs and transformation journeys.
 *
 * Member endpoints (role `user`), all under /api/v1/feed:
 *   GET    /                       ?tab=foryou|following|journeys|experts&category=&cursor=&limit=  → {posts, nextCursor}
 *   GET    /suggestions            people / experts to follow
 *   GET    /drafts                 my drafts
 *   GET    /saved                  ?cursor=  my saved posts
 *   GET    /me | PATCH /me {bio}   my FitFeed profile
 *   POST   /posts                  create (photo | blog | journey, draft or published)
 *   GET    /posts/:id              detail (+ journey timeline)
 *   PATCH  /posts/:id              edit own post (publishing a draft sets published_at)
 *   DELETE /posts/:id              delete own post
 *   POST   /posts/:id/updates      add a journey timeline update (owner) · DELETE /posts/:id/updates/:updateId
 *   POST|DELETE /posts/:id/like    · POST|DELETE /posts/:id/save
 *   POST   /posts/:id/share        {toUserIds?} counts a share, optionally sends it in-app to people
 *   POST   /posts/:id/report       {reason}
 *   GET|POST /posts/:id/comments   · DELETE /comments/:id (comment author or post author)
 *   GET    /users/:id              public profile · GET /users/:id/posts?kind=&cursor=
 *   POST|DELETE /users/:id/follow  · GET /users/:id/followers · GET /users/:id/following
 * Public (no auth):
 *   GET    /share/:id              small HTML preview of a public post (the link shared to WhatsApp / Instagram)
 * Admin (role `admin`):
 *   GET    /admin/nutritionists?q=           candidates + currently verified nutritionists
 *   POST   /admin/nutritionists/:userId      {verified: boolean} grant / revoke the "Verified Nutritionist" badge
 */
const router = Router();

const KINDS = ['photo', 'blog', 'journey'];
const CATEGORIES = ['gym', 'yoga', 'nutrition', 'weight_loss', 'weight_gain', 'mental_wellness', 'sports'];
const PAGE = 12;

// ---------------------------------------------------------------------------
// SQL building blocks. In every query below $1 is the viewer's user id.
// ---------------------------------------------------------------------------

/** id of the approved trainer profile owned by user `u` (trainer profiles belong to the partner account with the same phone). */
const trainerOf = (u) => `(SELECT t.id FROM trainers t JOIN users tp ON tp.id = t.partner_id
   WHERE tp.phone = ${u}.phone AND t.verification_status = 'verified' ORDER BY t.created_at LIMIT 1)`;
const hasJourney = (u) =>
  `EXISTS (SELECT 1 FROM feed_posts j WHERE j.user_id = ${u}.id AND j.kind = 'journey' AND j.status = 'published')`;
const viewerFollows = (userCol) =>
  `EXISTS (SELECT 1 FROM feed_follows vf WHERE vf.follower_id = $1 AND vf.followee_id = ${userCol})`;
const notBlocked = (userCol) => `NOT EXISTS (SELECT 1 FROM user_blocks b
   WHERE (b.blocker_id = $1 AND b.blocked_id = ${userCol}) OR (b.blocker_id = ${userCol} AND b.blocked_id = $1))`;

/** A published post the viewer may see: public, own, or followers-only from someone they follow; never from a block. */
const VISIBLE = `p.status = 'published'
  AND (p.visibility = 'public' OR p.user_id = $1 OR ${viewerFollows('p.user_id')})
  AND ${notBlocked('p.user_id')}`;

/** Author is a verified trainer or nutritionist. */
const IS_EXPERT = `(u.verified_nutritionist OR ${trainerOf('u')} IS NOT NULL)`;

const POST_SELECT = `
  SELECT p.*, to_char(p.published_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS cursor_key,
    u.name AS author_name, u.avatar_url AS author_avatar_url, u.city AS author_city,
    u.verified_nutritionist AS author_nutritionist,
    ${trainerOf('u')} AS author_trainer_id,
    ${hasJourney('u')} AS author_has_journey,
    ${viewerFollows('u.id')} AS author_following,
    EXISTS (SELECT 1 FROM feed_likes l WHERE l.post_id = p.id AND l.user_id = $1) AS liked,
    EXISTS (SELECT 1 FROM feed_saves s WHERE s.post_id = p.id AND s.user_id = $1) AS saved
  FROM feed_posts p JOIN users u ON u.id = p.user_id`;

/** Time-decayed engagement score (ranking v1): engagement / (age in hours + 2)^1.4, relative to `asOf`. */
const scoreSql = (asOfParam) => `(
  (1 + p.like_count + 2 * p.comment_count + 2 * p.save_count + 3 * p.share_count
     + CASE WHEN ${viewerFollows('p.user_id')} THEN 4 ELSE 0 END
     + CASE WHEN ${IS_EXPERT} THEN 2 ELSE 0 END)::float
  / POWER(GREATEST(EXTRACT(EPOCH FROM (${asOfParam}::timestamptz - p.published_at)), 0) / 3600 + 2, 1.4))`;

function badgeOf({ trainerId, nutritionist, journey }) {
  if (trainerId) return 'trainer';
  if (nutritionist) return 'nutritionist';
  if (journey) return 'journey';
  return null;
}

const stripMarkdown = (s) =>
  (s ?? '')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
    .replace(/[#*_>`-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

/** Shapes a POST_SELECT row for the API. `full` keeps the blog body (detail view). */
function toPost(r, viewerId, { full = false } = {}) {
  const words = stripMarkdown(r.body).split(' ').filter(Boolean).length;
  return {
    id: r.id,
    kind: r.kind,
    status: r.status,
    visibility: r.visibility,
    category: r.category,
    caption: r.caption,
    title: r.title,
    coverUrl: r.coverUrl,
    body: full ? r.body : null,
    excerpt: r.kind === 'blog' ? stripMarkdown(r.body).slice(0, 220) : null,
    readMinutes: r.kind === 'blog' ? Math.max(1, Math.ceil(words / 200)) : null,
    images: r.images ?? [],
    journey: r.journey,
    facesBlurred: r.facesBlurred,
    likeCount: r.likeCount,
    commentCount: r.commentCount,
    saveCount: r.saveCount,
    shareCount: r.shareCount,
    liked: r.liked,
    saved: r.saved,
    isMine: r.userId === viewerId,
    publishedAt: r.publishedAt,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    author: {
      id: r.userId,
      name: r.authorName,
      avatarUrl: r.authorAvatarUrl,
      city: r.authorCity,
      badge: badgeOf({ trainerId: r.authorTrainerId, nutritionist: r.authorNutritionist, journey: r.authorHasJourney }),
      trainerId: r.authorTrainerId,
      following: r.authorFollowing,
    },
  };
}

// ---------------------------------------------------------------------------
// Cursors (opaque base64url JSON)
// ---------------------------------------------------------------------------
const encodeCursor = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
function decodeCursor(c) {
  if (!c) return null;
  try {
    const o = JSON.parse(Buffer.from(String(c), 'base64url').toString('utf8'));
    if (typeof o !== 'object' || o === null) throw new Error();
    return o;
  } catch {
    throw badRequest('Invalid cursor');
  }
}

const uuid = z.string().uuid();
/** A keyset cursor {t: timestamptz text, id: uuid} that is safe to bind. */
const validKey = (c) =>
  typeof c?.t === 'string' &&
  c.t.length < 64 &&
  !Number.isNaN(Date.parse(c.t.replace(' ', 'T'))) &&
  uuid.safeParse(c.id).success;
const idOf = (req, name = 'id') => {
  const r = uuid.safeParse(req.params[name]);
  if (!r.success) throw notFound('Not found');
  return r.data;
};

const mediaUrl = z
  .string()
  .trim()
  .min(1)
  .max(600)
  .refine((s) => s.startsWith('/') || /^https?:\/\//.test(s), 'must be an uploaded file URL');

// ---------------------------------------------------------------------------
// Public share preview (no auth) — must be registered before the auth middleware.
// ---------------------------------------------------------------------------
const esc = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

router.get('/share/:id', async (req, res) => {
  const id = uuid.safeParse(req.params.id);
  const p = id.success
    ? await queryOne(
        `SELECT p.kind, p.title, p.caption, p.body, p.images, p.cover_url, p.journey, u.name
         FROM feed_posts p JOIN users u ON u.id = p.user_id
         WHERE p.id = $1 AND p.status = 'published' AND p.visibility = 'public'`,
        [id.data],
      )
    : null;
  const origin = `${req.protocol}://${req.get('host')}`;
  const abs = (u) => (u ? (u.startsWith('/') ? origin + u : u) : null);
  const title = p ? p.title || `${p.name ?? 'A FITKEY member'} on FitFeed` : 'FitFeed on FITKEY';
  const desc = p
    ? (p.kind === 'blog' ? stripMarkdown(p.body) : p.caption || 'A fitness journey on FITKEY').slice(0, 200)
    : 'This post is private or no longer available.';
  const image = p ? abs(p.coverUrl || p.images?.[0] || p.journey?.afterUrl) : null;
  res
    .status(p ? 200 : 404)
    .type('html')
    .send(`<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}">
${image ? `<meta property="og:image" content="${esc(image)}">` : ''}<meta property="og:site_name" content="FITKEY">
</head><body style="font-family:system-ui,sans-serif;background:#F5F6FA;color:#1A1B25;margin:0;padding:24px">
<div style="max-width:520px;margin:auto;background:#fff;border-radius:20px;overflow:hidden;box-shadow:0 6px 18px rgba(26,27,37,.06)">
${image ? `<img src="${esc(image)}" alt="" style="width:100%;display:block;max-height:520px;object-fit:cover">` : ''}
<div style="padding:20px"><div style="color:#FF5A36;font-weight:800;font-size:13px;letter-spacing:.4px">FITFEED</div>
<h1 style="font-size:22px;margin:8px 0">${esc(title)}</h1><p style="color:#5C5F6E;line-height:1.5">${esc(desc)}</p>
<p style="color:#9396A5;font-size:13px">Open the FITKEY app to like, comment and follow.</p></div></div></body></html>`);
});

// ---------------------------------------------------------------------------
// Admin: nutritionist verification (wired into the admin panel by the lead).
// ---------------------------------------------------------------------------
router.get('/admin/nutritionists', requireAuth('admin'), async (req, res) => {
  const { q } = validate(z.object({ q: z.string().trim().max(80).optional() }), req.query);
  const users = await query(
    `SELECT u.id, u.name, u.phone, u.city, u.avatar_url, u.verified_nutritionist, u.verified_nutritionist_at,
       (SELECT COUNT(*) FROM feed_posts p WHERE p.user_id = u.id AND p.status = 'published') AS post_count,
       (SELECT COUNT(*) FROM feed_posts p WHERE p.user_id = u.id AND p.status = 'published' AND p.category = 'nutrition') AS nutrition_post_count,
       (SELECT COUNT(*) FROM feed_follows f WHERE f.followee_id = u.id) AS followers
     FROM users u
     WHERE u.role = 'user' AND (
       ($1::text IS NOT NULL AND (u.name ILIKE '%' || $1 || '%' OR u.phone LIKE '%' || $1 || '%'))
       OR ($1::text IS NULL AND (u.verified_nutritionist OR EXISTS (
            SELECT 1 FROM feed_posts p WHERE p.user_id = u.id AND p.category = 'nutrition' AND p.status = 'published'))))
     ORDER BY u.verified_nutritionist DESC, nutrition_post_count DESC, u.name LIMIT 100`,
    [q || null],
  );
  res.json({ users });
});

router.post('/admin/nutritionists/:userId', requireAuth('admin'), async (req, res) => {
  const userId = idOf(req, 'userId');
  const { verified } = validate(z.object({ verified: z.boolean() }), req.body ?? {});
  const user = await queryOne(
    `UPDATE users SET verified_nutritionist = $2, verified_nutritionist_at = CASE WHEN $2 THEN now() ELSE NULL END
     WHERE id = $1 AND role = 'user'
     RETURNING id, name, phone, verified_nutritionist, verified_nutritionist_at`,
    [userId, verified],
  );
  if (!user) throw notFound('Member not found');
  if (verified) {
    await notify(userId, {
      type: 'feed_verified',
      title: "You're now a Verified Nutritionist on FitFeed",
      body: 'Your posts and blogs now carry the Verified Nutritionist badge.',
      data: { userId },
    });
  }
  res.json({ user });
});

// ---------------------------------------------------------------------------
// Everything below is for members.
// ---------------------------------------------------------------------------
router.use(requireAuth('user'));

const viewerName = async (id) => (await queryOne(`SELECT name FROM users WHERE id = $1`, [id]))?.name || 'Someone';

/** Loads a post the viewer may interact with (visible, or their own in any status). */
async function loadPost(viewerId, postId) {
  const row = await queryOne(
    `SELECT p.id, p.user_id, p.kind, p.title, p.caption, p.status FROM feed_posts p
     WHERE p.id = $2 AND ((${VISIBLE}) OR p.user_id = $1)`,
    [viewerId, postId],
  );
  if (!row) throw notFound('Post not found');
  return row;
}

const postLabel = (p) => (p.title ? `“${p.title.slice(0, 60)}”` : p.kind === 'journey' ? 'your journey' : 'your post');

/** GET / — the feed. */
router.get('/', async (req, res) => {
  const q = validate(
    z.object({
      tab: z.enum(['foryou', 'following', 'journeys', 'experts']).default('foryou'),
      category: z.enum(CATEGORIES).optional(),
      cursor: z.string().max(400).optional(),
      limit: z.coerce.number().int().min(1).max(30).default(PAGE),
    }),
    req.query,
  );
  const me = req.user.id;
  const cur = decodeCursor(q.cursor);
  const params = [me];
  const where = [VISIBLE];
  if (q.category) {
    params.push(q.category);
    where.push(`p.category = $${params.length}`);
  }
  if (q.tab === 'following') where.push(`(p.user_id = $1 OR ${viewerFollows('p.user_id')})`);
  if (q.tab === 'journeys') where.push(`p.kind = 'journey'`);
  if (q.tab === 'experts') where.push(`p.kind = 'blog' AND ${IS_EXPERT}`);

  let rows;
  let nextCursor = null;
  if (q.tab === 'following') {
    // Chronological, keyset on (published_at, id).
    if (validKey(cur)) {
      params.push(cur.t, cur.id);
      where.push(`(p.published_at, p.id) < ($${params.length - 1}::timestamptz, $${params.length}::uuid)`);
    }
    params.push(q.limit + 1);
    rows = await query(
      `${POST_SELECT} WHERE ${where.join(' AND ')} ORDER BY p.published_at DESC, p.id DESC LIMIT $${params.length}`,
      params,
    );
    if (rows.length > q.limit) {
      rows = rows.slice(0, q.limit);
      const last = rows[rows.length - 1];
      nextCursor = encodeCursor({ t: last.cursorKey, id: last.id });
    }
  } else {
    // Ranked (recency + engagement) relative to a fixed "as of" time so pages stay consistent.
    // "now" comes from the database so app-server clock skew can't hide fresh posts.
    const asOf =
      typeof cur?.a === 'string' && cur.a.length < 64 && !Number.isNaN(Date.parse(cur.a.replace(' ', 'T')))
        ? cur.a
        : (await queryOne(`SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS t`)).t;
    const offset = Number.isInteger(cur?.o) && cur.o >= 0 && cur.o < 5000 ? cur.o : 0;
    params.push(asOf);
    const asOfParam = `$${params.length}`;
    where.push(`p.published_at <= ${asOfParam}::timestamptz`);
    params.push(q.limit + 1, offset);
    rows = await query(
      `${POST_SELECT} WHERE ${where.join(' AND ')}
       ORDER BY ${scoreSql(asOfParam)} DESC, p.published_at DESC, p.id DESC
       LIMIT $${params.length - 1} OFFSET $${params.length}`,
      params,
    );
    if (rows.length > q.limit) {
      rows = rows.slice(0, q.limit);
      nextCursor = encodeCursor({ a: asOf, o: offset + q.limit });
    }
  }
  res.json({ posts: rows.map((r) => toPost(r, me)), nextCursor });
});

/** GET /suggestions — experts and active members to follow. */
router.get('/suggestions', async (req, res) => {
  const rows = await query(
    `SELECT u.id, u.name, u.avatar_url, u.city, u.verified_nutritionist, ${trainerOf('u')} AS trainer_id,
       ${hasJourney('u')} AS has_journey,
       (SELECT COUNT(*) FROM feed_follows f WHERE f.followee_id = u.id) AS followers,
       (SELECT COUNT(*) FROM feed_posts p WHERE p.user_id = u.id AND p.status = 'published') AS post_count
     FROM users u
     WHERE u.role = 'user' AND u.id <> $1 AND NOT ${viewerFollows('u.id')} AND ${notBlocked('u.id')}
       AND EXISTS (SELECT 1 FROM feed_posts p WHERE p.user_id = u.id AND p.status = 'published' AND p.visibility = 'public')
     ORDER BY ${IS_EXPERT} DESC, followers DESC, post_count DESC LIMIT 12`,
    [req.user.id],
  );
  res.json({ users: rows.map((r) => toPerson(r)) });
});

function toPerson(r) {
  return {
    id: r.id,
    name: r.name,
    avatarUrl: r.avatarUrl,
    city: r.city,
    badge: badgeOf({ trainerId: r.trainerId, nutritionist: r.verifiedNutritionist, journey: r.hasJourney }),
    followers: r.followers ?? null,
    postCount: r.postCount ?? null,
    following: r.following ?? false,
  };
}

/** GET /drafts */
router.get('/drafts', async (req, res) => {
  const rows = await query(`${POST_SELECT} WHERE p.user_id = $1 AND p.status = 'draft' ORDER BY p.updated_at DESC LIMIT 50`, [
    req.user.id,
  ]);
  res.json({ posts: rows.map((r) => toPost(r, req.user.id, { full: true })) });
});

/** GET /saved?cursor= */
router.get('/saved', async (req, res) => {
  const { cursor } = validate(z.object({ cursor: z.string().max(400).optional() }), req.query);
  const cur = decodeCursor(cursor);
  const params = [req.user.id];
  let keyset = '';
  if (validKey(cur)) {
    params.push(cur.t, cur.id);
    keyset = `AND (sv.created_at, p.id) < ($2::timestamptz, $3::uuid)`;
  }
  params.push(PAGE + 1);
  let rows = await query(
    `${POST_SELECT.replace('FROM feed_posts p', `, to_char(sv.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS saved_key FROM feed_posts p`)}
     JOIN feed_saves sv ON sv.post_id = p.id AND sv.user_id = $1
     WHERE ${VISIBLE} ${keyset}
     ORDER BY sv.created_at DESC, p.id DESC LIMIT $${params.length}`,
    params,
  );
  let nextCursor = null;
  if (rows.length > PAGE) {
    rows = rows.slice(0, PAGE);
    const last = rows[rows.length - 1];
    nextCursor = encodeCursor({ t: last.savedKey, id: last.id });
  }
  res.json({ posts: rows.map((r) => toPost(r, req.user.id)), nextCursor });
});

// ---------------------------------------------------------------------------
// Profiles & follows
// ---------------------------------------------------------------------------
async function profile(viewerId, userId) {
  const u = await queryOne(
    `SELECT u.id, u.name, u.avatar_url, u.city, u.feed_bio AS bio, u.verified_nutritionist,
       ${trainerOf('u')} AS trainer_id, ${hasJourney('u')} AS has_journey,
       (SELECT COUNT(*) FROM feed_follows f WHERE f.followee_id = u.id) AS followers,
       (SELECT COUNT(*) FROM feed_follows f WHERE f.follower_id = u.id) AS following_count,
       (SELECT COUNT(*) FROM feed_posts p WHERE p.user_id = u.id AND p.status = 'published') AS post_count,
       (SELECT COUNT(*) FROM feed_posts p WHERE p.user_id = u.id AND p.status = 'published' AND p.kind = 'journey') AS journey_count,
       ${viewerFollows('u.id')} AS is_following,
       EXISTS (SELECT 1 FROM feed_follows f WHERE f.follower_id = u.id AND f.followee_id = $1) AS follows_me
     FROM users u WHERE u.id = $2 AND u.role = 'user' AND ${notBlocked('u.id')}`,
    [viewerId, userId],
  );
  if (!u) throw notFound('Profile not found');
  return {
    id: u.id,
    name: u.name,
    avatarUrl: u.avatarUrl,
    city: u.city,
    bio: u.bio,
    badge: badgeOf({ trainerId: u.trainerId, nutritionist: u.verifiedNutritionist, journey: u.hasJourney }),
    trainerId: u.trainerId,
    followers: u.followers,
    following: u.followingCount,
    postCount: u.postCount,
    journeyCount: u.journeyCount,
    isFollowing: u.isFollowing,
    followsMe: u.followsMe,
    isMe: u.id === viewerId,
  };
}

router.get('/me', async (req, res) => res.json({ profile: await profile(req.user.id, req.user.id) }));

router.patch('/me', async (req, res) => {
  const { bio } = validate(z.object({ bio: z.string().trim().max(300).nullable() }), req.body ?? {});
  await query(`UPDATE users SET feed_bio = $2 WHERE id = $1`, [req.user.id, bio || null]);
  res.json({ profile: await profile(req.user.id, req.user.id) });
});

router.get('/users/:id', async (req, res) => res.json({ profile: await profile(req.user.id, idOf(req)) }));

router.get('/users/:id/posts', async (req, res) => {
  const userId = idOf(req);
  const q = validate(
    z.object({ kind: z.enum(KINDS).optional(), cursor: z.string().max(400).optional() }),
    req.query,
  );
  const cur = decodeCursor(q.cursor);
  const params = [req.user.id, userId];
  const where = [VISIBLE, 'p.user_id = $2'];
  if (q.kind) {
    params.push(q.kind);
    where.push(`p.kind = $${params.length}`);
  }
  if (validKey(cur)) {
    params.push(cur.t, cur.id);
    where.push(`(p.published_at, p.id) < ($${params.length - 1}::timestamptz, $${params.length}::uuid)`);
  }
  params.push(PAGE + 1);
  let rows = await query(
    `${POST_SELECT} WHERE ${where.join(' AND ')} ORDER BY p.published_at DESC, p.id DESC LIMIT $${params.length}`,
    params,
  );
  let nextCursor = null;
  if (rows.length > PAGE) {
    rows = rows.slice(0, PAGE);
    const last = rows[rows.length - 1];
    nextCursor = encodeCursor({ t: last.cursorKey, id: last.id });
  }
  res.json({ posts: rows.map((r) => toPost(r, req.user.id)), nextCursor });
});

const followCounts = async (userId) =>
  (await queryOne(`SELECT COUNT(*) AS followers FROM feed_follows WHERE followee_id = $1`, [userId])).followers;

router.post('/users/:id/follow', async (req, res) => {
  const userId = idOf(req);
  const me = req.user.id;
  if (userId === me) throw badRequest("You can't follow yourself");
  const target = await queryOne(`SELECT u.id FROM users u WHERE u.id = $2 AND u.role = 'user' AND ${notBlocked('u.id')}`, [
    me,
    userId,
  ]);
  if (!target) throw notFound('Profile not found');
  const added = await queryOne(
    `INSERT INTO feed_follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING follower_id`,
    [me, userId],
  );
  if (added) {
    await notify(userId, {
      type: 'follow',
      title: `${await viewerName(me)} started following you`,
      body: 'Tap to see their FitFeed profile.',
      data: { userId: me },
    });
  }
  res.status(added ? 201 : 200).json({ following: true, followers: await followCounts(userId) });
});

router.delete('/users/:id/follow', async (req, res) => {
  const userId = idOf(req);
  await query(`DELETE FROM feed_follows WHERE follower_id = $1 AND followee_id = $2`, [req.user.id, userId]);
  res.json({ following: false, followers: await followCounts(userId) });
});

async function followList(req, res, direction) {
  const userId = idOf(req);
  const { cursor } = validate(z.object({ cursor: z.string().max(400).optional() }), req.query);
  const cur = decodeCursor(cursor);
  // followers: people following userId; following: people userId follows.
  const [matchCol, otherCol] = direction === 'followers' ? ['followee_id', 'follower_id'] : ['follower_id', 'followee_id'];
  const params = [req.user.id, userId];
  let keyset = '';
  if (validKey(cur)) {
    params.push(cur.t, cur.id);
    keyset = `AND (f.created_at, u.id) < ($3::timestamptz, $4::uuid)`;
  }
  params.push(30 + 1);
  let rows = await query(
    `SELECT u.id, u.name, u.avatar_url, u.city, u.verified_nutritionist, ${trainerOf('u')} AS trainer_id,
       ${hasJourney('u')} AS has_journey, ${viewerFollows('u.id')} AS following, to_char(f.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS key
     FROM feed_follows f JOIN users u ON u.id = f.${otherCol}
     WHERE f.${matchCol} = $2 AND ${notBlocked('u.id')} ${keyset}
     ORDER BY f.created_at DESC, u.id DESC LIMIT $${params.length}`,
    params,
  );
  let nextCursor = null;
  if (rows.length > 30) {
    rows = rows.slice(0, 30);
    const last = rows[rows.length - 1];
    nextCursor = encodeCursor({ t: last.key, id: last.id });
  }
  res.json({ users: rows.map((r) => ({ ...toPerson(r), isMe: r.id === req.user.id })), nextCursor });
}
router.get('/users/:id/followers', (req, res) => followList(req, res, 'followers'));
router.get('/users/:id/following', (req, res) => followList(req, res, 'following'));

// ---------------------------------------------------------------------------
// Posts
// ---------------------------------------------------------------------------
const stats = z
  .object({
    weightKg: z.number().min(20).max(400).nullish(),
    bodyFatPct: z.number().min(2).max(75).nullish(),
    waistCm: z.number().min(30).max(250).nullish(),
    calories: z.number().int().min(0).max(10000).nullish(),
    proteinG: z.number().min(0).max(1000).nullish(),
    date: z
      .string()
      .regex(/^\d{4}-\d{2}-\d{2}$/)
      .nullish(),
  })
  .strict();

const journeySchema = z
  .object({
    goal: z.enum(['weight_loss', 'weight_gain', 'fitness']).default('fitness'),
    beforeUrl: mediaUrl.nullish(),
    afterUrl: mediaUrl.nullish(),
    start: stats.default({}),
    current: stats.default({}),
  })
  .strict();

const postFields = {
  status: z.enum(['draft', 'published']),
  visibility: z.enum(['public', 'followers']),
  category: z.enum(CATEGORIES).nullable(),
  caption: z.string().trim().max(2200).nullable(),
  title: z.string().trim().max(160).nullable(),
  coverUrl: mediaUrl.nullable(),
  body: z.string().max(20000).nullable(),
  images: z.array(mediaUrl).max(10),
  journey: journeySchema.nullable(),
  facesBlurred: z.boolean(),
};

const createSchema = z
  .object({
    kind: z.enum(KINDS),
    status: postFields.status.default('published'),
    visibility: postFields.visibility.default('public'),
    category: postFields.category.optional(),
    caption: postFields.caption.optional(),
    title: postFields.title.optional(),
    coverUrl: postFields.coverUrl.optional(),
    body: postFields.body.optional(),
    images: postFields.images.default([]),
    journey: postFields.journey.optional(),
    facesBlurred: postFields.facesBlurred.default(false),
  })
  .strict();

const patchSchema = z.object(Object.fromEntries(Object.entries(postFields).map(([k, v]) => [k, v.optional()]))).strict();

/** A published post must be complete for its format. Drafts may be partial. */
function checkPublishable(p) {
  if (p.status !== 'published') return;
  if (p.kind === 'photo' && !(p.images?.length >= 1)) throw badRequest('Add at least one photo');
  if (p.kind === 'blog') {
    if (!p.title || p.title.length < 3) throw badRequest('Give your blog a title');
    if (!p.body || stripMarkdown(p.body).length < 20) throw badRequest('Your blog needs a little more text');
  }
  if (p.kind === 'journey') {
    if (!p.journey?.beforeUrl || !p.journey?.afterUrl) throw badRequest('Add a before and an after photo');
  }
}

async function postById(viewerId, id, { full = true } = {}) {
  const row = await queryOne(`${POST_SELECT} WHERE p.id = $2 AND ((${VISIBLE}) OR p.user_id = $1)`, [viewerId, id]);
  if (!row) return null;
  const post = toPost(row, viewerId, { full });
  if (post.kind === 'journey') {
    post.updates = await query(
      `SELECT id, note, photo_url, weight_kg, created_at FROM feed_journey_updates WHERE post_id = $1 ORDER BY created_at`,
      [id],
    );
  }
  return post;
}

/** Tells an expert's followers about their new post (BRD: "posts from followed experts"). Fire and forget. */
async function announceExpertPost(authorId, post) {
  const author = await queryOne(
    `SELECT u.name, u.verified_nutritionist, ${trainerOf('u')} AS trainer_id FROM users u WHERE u.id = $1`,
    [authorId],
  );
  if (!author || !(author.verifiedNutritionist || author.trainerId)) return;
  const followers = await query(`SELECT follower_id FROM feed_follows WHERE followee_id = $1 LIMIT 1000`, [authorId]);
  const what = post.kind === 'blog' ? 'a new blog' : post.kind === 'journey' ? 'a new journey' : 'a new post';
  for (const f of followers) {
    await notify(f.followerId, {
      type: 'feed_expert_post',
      title: `${author.name ?? 'An expert you follow'} published ${what}`,
      body: post.title || post.caption?.slice(0, 120) || null,
      data: { postId: post.id, userId: authorId },
    });
  }
}

router.post('/posts', async (req, res) => {
  const v = validate(createSchema, req.body ?? {});
  checkPublishable(v);
  const me = req.user.id;
  const row = await queryOne(
    `INSERT INTO feed_posts (user_id, kind, status, visibility, category, caption, title, cover_url, body, images, journey,
       faces_blurred, published_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, CASE WHEN $13 THEN now() END)
     RETURNING id`,
    [
      me,
      v.kind,
      v.status,
      v.visibility,
      v.category ?? null,
      v.caption || null,
      v.title || null,
      v.coverUrl ?? null,
      v.body || null,
      v.images,
      v.journey ?? null,
      v.facesBlurred,
      v.status === 'published',
    ],
  );
  const post = await postById(me, row.id);
  if (post.status === 'published') announceExpertPost(me, post).catch(() => {});
  res.status(201).json({ post });
});

router.get('/posts/:id', async (req, res) => {
  const post = await postById(req.user.id, idOf(req));
  if (!post) throw notFound('Post not found');
  res.json({ post });
});

router.patch('/posts/:id', async (req, res) => {
  const id = idOf(req);
  const me = req.user.id;
  const v = validate(patchSchema, req.body ?? {});
  const existing = await queryOne(`SELECT * FROM feed_posts WHERE id = $1`, [id]);
  if (!existing) throw notFound('Post not found');
  if (existing.userId !== me) throw forbidden('You can only edit your own posts');
  const merged = { ...existing, ...Object.fromEntries(Object.entries(v).filter(([, x]) => x !== undefined)) };
  checkPublishable(merged);
  const firstPublish = merged.status === 'published' && !existing.publishedAt;
  await query(
    `UPDATE feed_posts SET status = $2, visibility = $3, category = $4, caption = $5, title = $6, cover_url = $7, body = $8,
       images = $9, journey = $10, faces_blurred = $11, updated_at = now(),
       published_at = CASE WHEN $12 THEN COALESCE(published_at, now()) ELSE published_at END
     WHERE id = $1`,
    [
      id,
      merged.status,
      merged.visibility,
      merged.category ?? null,
      merged.caption || null,
      merged.title || null,
      merged.coverUrl ?? null,
      merged.body || null,
      merged.images ?? [],
      merged.journey ?? null,
      merged.facesBlurred,
      merged.status === 'published',
    ],
  );
  const post = await postById(me, id);
  if (firstPublish) announceExpertPost(me, post).catch(() => {});
  res.json({ post });
});

router.delete('/posts/:id', async (req, res) => {
  const id = idOf(req);
  const existing = await queryOne(`SELECT user_id FROM feed_posts WHERE id = $1`, [id]);
  if (!existing) throw notFound('Post not found');
  if (existing.userId !== req.user.id) throw forbidden('You can only delete your own posts');
  await query(`DELETE FROM feed_posts WHERE id = $1`, [id]);
  res.json({ deleted: true });
});

// Journey timeline ------------------------------------------------------------
router.post('/posts/:id/updates', async (req, res) => {
  const id = idOf(req);
  const v = validate(
    z
      .object({
        note: z.string().trim().max(1000).optional(),
        photoUrl: mediaUrl.optional(),
        weightKg: z.number().min(20).max(400).optional(),
      })
      .strict()
      .refine((x) => x.note || x.photoUrl || x.weightKg, 'Add a note, a photo or your weight'),
    req.body ?? {},
  );
  const post = await queryOne(`SELECT user_id, kind FROM feed_posts WHERE id = $1`, [id]);
  if (!post) throw notFound('Post not found');
  if (post.userId !== req.user.id) throw forbidden('Only the author can add updates');
  if (post.kind !== 'journey') throw badRequest('Updates are only for journey posts');
  const update = await queryOne(
    `INSERT INTO feed_journey_updates (post_id, note, photo_url, weight_kg) VALUES ($1, $2, $3, $4)
     RETURNING id, note, photo_url, weight_kg, created_at`,
    [id, v.note || null, v.photoUrl ?? null, v.weightKg ?? null],
  );
  // The latest logged weight becomes the journey's "current" stat.
  await query(
    `UPDATE feed_posts SET updated_at = now(),
       journey = CASE WHEN $2::numeric IS NULL THEN journey
                      ELSE jsonb_set(COALESCE(journey, '{}'::jsonb), '{current}',
                             COALESCE(journey->'current', '{}'::jsonb) || jsonb_build_object('weightKg', $2::numeric,
                               'date', to_char(now(), 'YYYY-MM-DD'))) END
     WHERE id = $1`,
    [id, v.weightKg ?? null],
  );
  res.status(201).json({ update });
});

router.delete('/posts/:id/updates/:updateId', async (req, res) => {
  const id = idOf(req);
  const updateId = idOf(req, 'updateId');
  const post = await queryOne(`SELECT user_id FROM feed_posts WHERE id = $1`, [id]);
  if (!post) throw notFound('Post not found');
  if (post.userId !== req.user.id) throw forbidden('Only the author can remove updates');
  await query(`DELETE FROM feed_journey_updates WHERE id = $1 AND post_id = $2`, [updateId, id]);
  res.json({ deleted: true });
});

// Engagement -----------------------------------------------------------------
router.post('/posts/:id/like', async (req, res) => {
  const me = req.user.id;
  const post = await loadPost(me, idOf(req));
  const r = await queryOne(
    `WITH ins AS (INSERT INTO feed_likes (post_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING 1)
     UPDATE feed_posts SET like_count = like_count + (SELECT COUNT(*) FROM ins) WHERE id = $1
     RETURNING like_count, (SELECT COUNT(*) FROM ins) AS added`,
    [post.id, me],
  );
  if (r.added && post.userId !== me) {
    await notify(post.userId, {
      type: 'feed_like',
      title: `${await viewerName(me)} liked ${postLabel(post)}`,
      data: { postId: post.id, userId: me },
    });
  }
  res.json({ liked: true, likeCount: r.likeCount });
});

router.delete('/posts/:id/like', async (req, res) => {
  const post = await loadPost(req.user.id, idOf(req));
  const r = await queryOne(
    `WITH del AS (DELETE FROM feed_likes WHERE post_id = $1 AND user_id = $2 RETURNING 1)
     UPDATE feed_posts SET like_count = GREATEST(like_count - (SELECT COUNT(*) FROM del), 0) WHERE id = $1 RETURNING like_count`,
    [post.id, req.user.id],
  );
  res.json({ liked: false, likeCount: r.likeCount });
});

router.post('/posts/:id/save', async (req, res) => {
  const post = await loadPost(req.user.id, idOf(req));
  const r = await queryOne(
    `WITH ins AS (INSERT INTO feed_saves (post_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING 1)
     UPDATE feed_posts SET save_count = save_count + (SELECT COUNT(*) FROM ins) WHERE id = $1 RETURNING save_count`,
    [post.id, req.user.id],
  );
  res.json({ saved: true, saveCount: r.saveCount });
});

router.delete('/posts/:id/save', async (req, res) => {
  const post = await loadPost(req.user.id, idOf(req));
  const r = await queryOne(
    `WITH del AS (DELETE FROM feed_saves WHERE post_id = $1 AND user_id = $2 RETURNING 1)
     UPDATE feed_posts SET save_count = GREATEST(save_count - (SELECT COUNT(*) FROM del), 0) WHERE id = $1 RETURNING save_count`,
    [post.id, req.user.id],
  );
  res.json({ saved: false, saveCount: r.saveCount });
});

router.post('/posts/:id/share', async (req, res) => {
  const me = req.user.id;
  const post = await loadPost(me, idOf(req));
  const { toUserIds } = validate(z.object({ toUserIds: z.array(uuid).max(10).default([]) }).strict(), req.body ?? {});
  const r = await queryOne(`UPDATE feed_posts SET share_count = share_count + 1 WHERE id = $1 RETURNING share_count`, [post.id]);
  let sentTo = 0;
  if (toUserIds.length) {
    const targets = await query(
      `SELECT u.id FROM users u WHERE u.id = ANY($2::uuid[]) AND u.id <> $1 AND u.role = 'user' AND ${notBlocked('u.id')}`,
      [me, toUserIds],
    );
    const name = await viewerName(me);
    for (const t of targets) {
      await notify(t.id, {
        type: 'feed_share',
        title: `${name} shared a post with you`,
        body: post.title || post.caption?.slice(0, 120) || null,
        data: { postId: post.id, userId: me },
      });
    }
    sentTo = targets.length;
  }
  res.json({ shareCount: r.shareCount, sentTo });
});

router.post('/posts/:id/report', async (req, res) => {
  const post = await loadPost(req.user.id, idOf(req));
  const { reason } = validate(z.object({ reason: z.string().trim().min(3).max(400) }), req.body ?? {});
  if (post.userId === req.user.id) throw badRequest("You can't report your own post");
  await query(`INSERT INTO user_reports (reporter_id, reported_id, reason) VALUES ($1, $2, $3)`, [
    req.user.id,
    post.userId,
    `[FitFeed post ${post.id}] ${reason}`,
  ]);
  res.status(201).json({ reported: true });
});

// Comments -------------------------------------------------------------------
const COMMENT_SELECT = `
  SELECT c.id, c.body, c.created_at, to_char(c.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS key, c.user_id, p.user_id AS post_author_id,
    u.name, u.avatar_url, u.verified_nutritionist, ${trainerOf('u')} AS trainer_id, ${hasJourney('u')} AS has_journey
  FROM feed_comments c JOIN users u ON u.id = c.user_id JOIN feed_posts p ON p.id = c.post_id`;

const toComment = (r, me) => ({
  id: r.id,
  body: r.body,
  createdAt: r.createdAt,
  user: {
    id: r.userId,
    name: r.name,
    avatarUrl: r.avatarUrl,
    badge: badgeOf({ trainerId: r.trainerId, nutritionist: r.verifiedNutritionist, journey: r.hasJourney }),
  },
  isMine: r.userId === me,
  canDelete: r.userId === me || r.postAuthorId === me,
});

router.get('/posts/:id/comments', async (req, res) => {
  const me = req.user.id;
  const post = await loadPost(me, idOf(req));
  const { cursor } = validate(z.object({ cursor: z.string().max(400).optional() }), req.query);
  const cur = decodeCursor(cursor);
  const params = [me, post.id];
  let keyset = '';
  if (validKey(cur)) {
    params.push(cur.t, cur.id);
    keyset = `AND (c.created_at, c.id) < ($3::timestamptz, $4::uuid)`;
  }
  params.push(20 + 1);
  let rows = await query(
    `${COMMENT_SELECT} WHERE c.post_id = $2 AND ${notBlocked('c.user_id')} ${keyset}
     ORDER BY c.created_at DESC, c.id DESC LIMIT $${params.length}`,
    params,
  );
  let nextCursor = null;
  if (rows.length > 20) {
    rows = rows.slice(0, 20);
    const last = rows[rows.length - 1];
    nextCursor = encodeCursor({ t: last.key, id: last.id });
  }
  res.json({ comments: rows.map((r) => toComment(r, me)), nextCursor });
});

router.post('/posts/:id/comments', async (req, res) => {
  const me = req.user.id;
  const post = await loadPost(me, idOf(req));
  if (post.status !== 'published') throw badRequest('Publish the post before commenting');
  const { body } = validate(z.object({ body: z.string().trim().min(1).max(1000) }).strict(), req.body ?? {});
  const ins = await queryOne(`INSERT INTO feed_comments (post_id, user_id, body) VALUES ($1, $2, $3) RETURNING id`, [
    post.id,
    me,
    body,
  ]);
  await query(`UPDATE feed_posts SET comment_count = comment_count + 1 WHERE id = $1`, [post.id]);
  const row = await queryOne(`${COMMENT_SELECT} WHERE c.id = $2 AND $1::uuid IS NOT NULL`, [me, ins.id]);
  if (post.userId !== me) {
    await notify(post.userId, {
      type: 'feed_comment',
      title: `${row.name ?? 'Someone'} commented on ${postLabel(post)}`,
      body: body.slice(0, 200),
      data: { postId: post.id, userId: me },
    });
  }
  res.status(201).json({ comment: toComment(row, me) });
});

router.delete('/comments/:id', async (req, res) => {
  const id = idOf(req);
  const c = await queryOne(
    `SELECT c.user_id, c.post_id, p.user_id AS post_author_id FROM feed_comments c JOIN feed_posts p ON p.id = c.post_id
     WHERE c.id = $1`,
    [id],
  );
  if (!c) throw notFound('Comment not found');
  if (c.userId !== req.user.id && c.postAuthorId !== req.user.id) throw forbidden('You can only delete your own comments');
  await query(`DELETE FROM feed_comments WHERE id = $1`, [id]);
  await query(`UPDATE feed_posts SET comment_count = GREATEST(comment_count - 1, 0) WHERE id = $1`, [c.postId]);
  res.json({ deleted: true });
});

export default router;

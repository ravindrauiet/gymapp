import crypto from 'node:crypto';
import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { sendEmailOtp } from '../utils/email.js';
import { HttpError, badRequest, conflict, forbidden, notFound, unauthorized, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { dateSchema, uuidSchema } from '../utils/schemas.js';

/**
 * Events (BRD §3.1) — the evolution of contests.
 *  kind:   fitkey (anyone) | org (company / college members, verified) | partner (gym / studio; optionally venue members only)
 *  format: virtual (checkins / running_km / streak) | onground (attendance via venue check-in on event_date)
 *          | ai (best AI Arena set of arena_exercise)
 * Inter-org battles: orgs listed in contest_orgs may all join; teams are ranked by average score.
 */
const router = Router();

export const METRIC_UNITS = {
  checkins: 'days',
  running_km: 'km',
  streak: 'day streak',
  attendance: 'attended',
  arena_reps: 'reps',
};

const todaySql = `(now() AT TIME ZONE $TZ)::date`;

// ---------------------------------------------------------------------------
// Shared helpers (also used by routes/contests.js and routes/checkins.js)
// ---------------------------------------------------------------------------

let arenaTableKnown = false;
/** AI Arena attempts live in a table owned by the Arena feature; tolerate it not existing yet. */
export async function arenaTableExists() {
  if (arenaTableKnown) return true;
  const row = await queryOne(`SELECT to_regclass('public.arena_attempts') IS NOT NULL AS ok`);
  arenaTableKnown = Boolean(row?.ok);
  return arenaTableKnown;
}

/**
 * SQL yielding (user_id, score) for a metric. References the CTE `p` with columns
 * cid (contest id), s / e (window dates), tz (time zone), ex (arena exercise).
 */
function scoreSql(metric, hasArena) {
  switch (metric) {
    case 'checkins':
      return `SELECT user_id, COUNT(DISTINCT checkin_date)::numeric AS score
              FROM checkins, p WHERE checkin_date BETWEEN p.s AND p.e GROUP BY user_id`;
    case 'running_km':
      return `SELECT user_id, COALESCE(SUM(distance_km), 0)::numeric AS score
              FROM activity_logs, p
              WHERE type = 'running' AND (logged_at AT TIME ZONE p.tz)::date BETWEEN p.s AND p.e
              GROUP BY user_id`;
    case 'streak':
      // Longest run of consecutive check-in days (gaps-and-islands).
      return `SELECT user_id, MAX(run)::numeric AS score FROM (
                SELECT user_id, COUNT(*) AS run FROM (
                  SELECT user_id, d, d - (ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY d))::int AS grp
                  FROM (SELECT DISTINCT user_id, checkin_date AS d FROM checkins, p
                        WHERE checkin_date BETWEEN p.s AND p.e) days
                ) islands GROUP BY user_id, grp
              ) runs GROUP BY user_id`;
    case 'attendance':
      return `SELECT user_id, 1::numeric AS score FROM contest_participants, p
              WHERE contest_id = p.cid AND attended_at IS NOT NULL`;
    case 'arena_reps':
      if (!hasArena) return `SELECT NULL::uuid AS user_id, 0::numeric AS score WHERE false`;
      // Best single AI-counted set of the event's exercise inside the window.
      return `SELECT user_id, MAX(reps)::numeric AS score FROM arena_attempts, p
              WHERE exercise_id = p.ex AND (created_at AT TIME ZONE p.tz)::date BETWEEN p.s AND p.e
              GROUP BY user_id`;
    default:
      throw new Error(`Unknown metric ${metric}`);
  }
}

/** Ranked participants of an event, optionally filtered to one city or one org. */
export async function eventLeaderboard(event, userId, { city, orgId } = {}) {
  const hasArena = event.metric === 'arena_reps' ? await arenaTableExists() : false;
  const rows = await query(
    `WITH p AS (SELECT $1::uuid AS cid, $2::date AS s, $3::date AS e, $4::text AS tz, $5::text AS ex),
     scores AS (${scoreSql(event.metric, hasArena)})
     SELECT u.id AS user_id, u.name, u.city, u.avatar_url, cp.org_id, o.name AS org_name, cp.attended_at,
            COALESCE(s.score, 0) AS score,
            RANK() OVER (ORDER BY COALESCE(s.score, 0) DESC) AS rank
     FROM contest_participants cp
     JOIN users u ON u.id = cp.user_id
     LEFT JOIN orgs o ON o.id = cp.org_id
     LEFT JOIN scores s ON s.user_id = cp.user_id
     WHERE cp.contest_id = $1 AND ($6::text IS NULL OR u.city ILIKE $6) AND ($7::uuid IS NULL OR cp.org_id = $7)
     ORDER BY rank, u.name`,
    [event.id, event.startsOn, event.endsOn, config.tz, event.arenaExercise ?? null, city ?? null, orgId ?? null],
  );
  return { all: rows, entries: rows.slice(0, 100), me: rows.find((r) => r.userId === userId) ?? null };
}

/** Team ranking for inter-org battles: average (and total) score per org. */
function teamRanking(battleOrgs, rows) {
  const teams = battleOrgs.map((o) => {
    const members = rows.filter((r) => r.orgId === o.id);
    const total = members.reduce((sum, r) => sum + Number(r.score), 0);
    return {
      orgId: o.id,
      name: o.name,
      logoUrl: o.logoUrl ?? null,
      members: members.length,
      totalScore: Math.round(total * 100) / 100,
      averageScore: members.length ? Math.round((total / members.length) * 100) / 100 : 0,
    };
  });
  teams.sort((a, b) => b.averageScore - a.averageScore || b.totalScore - a.totalScore);
  let rank = 0;
  let prev = null;
  teams.forEach((t, i) => {
    if (prev === null || t.averageScore !== prev) rank = i + 1;
    prev = t.averageScore;
    t.rank = rank;
  });
  return teams;
}

const EVENT_SELECT = `
  SELECT c.*, o.name AS org_name, o.kind AS org_kind, o.logo_url AS org_logo_url,
         v.name AS venue_name, v.area AS venue_area, v.city AS venue_city, v.address AS venue_address,
         v.photos[1] AS venue_photo,
         (SELECT COUNT(*) FROM contest_participants x WHERE x.contest_id = c.id) AS participant_count,
         (me.user_id IS NOT NULL) AS joined, me.attended_at AS my_attended_at, me.org_id AS my_org_id,
         COALESCE((SELECT json_agg(json_build_object('id', bo.id, 'name', bo.name, 'kind', bo.kind, 'logoUrl', bo.logo_url)
                                   ORDER BY bo.name)
                   FROM contest_orgs co JOIN orgs bo ON bo.id = co.org_id WHERE co.contest_id = c.id), '[]'::json) AS battle_orgs,
         CASE WHEN c.ends_on < today.d THEN 'past' WHEN c.starts_on > today.d THEN 'upcoming' ELSE 'live' END AS status
  FROM contests c
  CROSS JOIN (SELECT (now() AT TIME ZONE $2)::date AS d) today
  LEFT JOIN orgs o ON o.id = c.org_id
  LEFT JOIN venues v ON v.id = c.venue_id
  LEFT JOIN contest_participants me ON me.contest_id = c.id AND me.user_id = $1`;

/** Orgs whose verified members may join (the host org plus any battle orgs). */
function allowedOrgs(event) {
  const list = [...(event.battleOrgs ?? [])];
  if (event.orgId && !list.some((o) => o.id === event.orgId)) {
    list.unshift({ id: event.orgId, name: event.orgName, kind: event.orgKind, logoUrl: event.orgLogoUrl });
  }
  return list;
}

function shapeEvent(e) {
  const { battleOrgs, myAttendedAt, myOrgId, createdBy: _createdBy, ...rest } = e;
  return {
    ...rest,
    unit: METRIC_UNITS[e.metric] ?? '',
    battleOrgs: battleOrgs ?? [],
    isBattle: (battleOrgs ?? []).length > 1,
    attended: myAttendedAt != null,
    attendedAt: myAttendedAt ?? null,
    myOrgId: myOrgId ?? null,
    venue: e.venueId
      ? { id: e.venueId, name: e.venueName, area: e.venueArea, city: e.venueCity, address: e.venueAddress, photo: e.venuePhoto }
      : null,
  };
}

async function myOrgMemberships(userId) {
  return query(
    `SELECT m.org_id, m.status, m.method, m.work_email, m.department, m.verified_at, m.requested_at, m.review_note,
            o.name AS org_name, o.kind AS org_kind, o.logo_url AS org_logo_url
     FROM org_memberships m JOIN orgs o ON o.id = m.org_id
     WHERE m.user_id = $1 AND m.status <> 'removed' ORDER BY o.name`,
    [userId],
  );
}

/** "Venue members only" = has checked in at that venue, or holds an active plan covering it. */
async function isVenueMember(userId, venueId) {
  const row = await queryOne(
    `SELECT EXISTS (SELECT 1 FROM checkins WHERE user_id = $1 AND venue_id = $2)
         OR EXISTS (SELECT 1 FROM subscriptions s JOIN plans pl ON pl.id = s.plan_id JOIN venues v ON v.id = $2
                    WHERE s.user_id = $1 AND s.status = 'active' AND now() BETWEEN s.starts_at AND s.ends_at
                      AND pl.categories && v.categories) AS ok`,
    [userId, venueId],
  );
  return Boolean(row?.ok);
}

/**
 * Who may join: returns { canJoin, reason, message, orgs, eligibleOrgIds, pendingOrgIds }.
 * reason: joined | ended | city | org_verification | org_pending | venue_members | null
 */
async function eligibility(event, userId, memberships) {
  const orgs = allowedOrgs(event).map((o) => ({ id: o.id, name: o.name, kind: o.kind, logoUrl: o.logoUrl ?? null }));
  const verified = new Set(memberships.filter((m) => m.status === 'verified').map((m) => m.orgId));
  const pending = new Set(memberships.filter((m) => m.status === 'pending').map((m) => m.orgId));
  const eligibleOrgIds = orgs.filter((o) => verified.has(o.id)).map((o) => o.id);
  const pendingOrgIds = orgs.filter((o) => pending.has(o.id)).map((o) => o.id);
  const base = { orgs, eligibleOrgIds, pendingOrgIds };

  if (event.joined) return { ...base, canJoin: false, reason: 'joined', message: "You're registered" };
  if (event.status === 'past') return { ...base, canJoin: false, reason: 'ended', message: 'This event has ended' };
  if (event.city) {
    const u = await queryOne(`SELECT city FROM users WHERE id = $1`, [userId]);
    if (u?.city?.toLowerCase() !== event.city.toLowerCase()) {
      return { ...base, canJoin: false, reason: 'city', message: `Only for members in ${event.city}` };
    }
  }
  if (orgs.length && !eligibleOrgIds.length) {
    const names = orgs.map((o) => o.name).join(' / ');
    if (pendingOrgIds.length) {
      return { ...base, canJoin: false, reason: 'org_pending', message: 'Your ID is being reviewed by the FitKey team' };
    }
    return { ...base, canJoin: false, reason: 'org_verification', message: `Verify you're part of ${names} to join` };
  }
  if (event.kind === 'partner' && event.membersOnly && event.venueId && !(await isVenueMember(userId, event.venueId))) {
    return {
      ...base,
      canJoin: false,
      reason: 'venue_members',
      message: `Only for ${event.venueName ?? 'venue'} members — check in there or get a plan that covers it`,
    };
  }
  return { ...base, canJoin: true, reason: null, message: null };
}

const listQuerySchema = z.object({
  scope: z.enum(['all', 'org', 'open']).default('all'),
  status: z
    .enum(['live', 'active', 'upcoming', 'past', 'any'])
    .default('live')
    .transform((s) => (s === 'active' ? 'live' : s)),
  kind: z.enum(['fitkey', 'org', 'partner']).optional(),
  q: z.string().trim().max(80).optional(),
  limit: z.coerce.number().int().min(1).max(100).default(50),
});

/** Lists events visible to a member. Org events are listed so members can discover and verify for them. */
export async function listEvents(userId, opts) {
  const { scope, status, kind, q, limit } = opts;
  const memberships = await myOrgMemberships(userId);
  const myOrgIds = memberships.filter((m) => m.status === 'verified').map((m) => m.orgId);
  const where = [];
  const params = [userId, config.tz];
  const add = (v) => {
    params.push(v);
    return `$${params.length}`;
  };
  if (status === 'live') where.push(`c.starts_on <= today.d AND c.ends_on >= today.d`);
  if (status === 'upcoming') where.push(`c.starts_on > today.d`);
  if (status === 'past') where.push(`c.ends_on < today.d`);
  if (kind) where.push(`c.kind = ${add(kind)}`);
  if (scope === 'org') {
    const ids = add(myOrgIds);
    where.push(`(c.org_id = ANY(${ids}::uuid[])
                 OR EXISTS (SELECT 1 FROM contest_orgs co WHERE co.contest_id = c.id AND co.org_id = ANY(${ids}::uuid[])))`);
  }
  if (scope === 'open') {
    where.push(`c.kind <> 'org' AND NOT c.members_only
                AND NOT EXISTS (SELECT 1 FROM contest_orgs co WHERE co.contest_id = c.id)`);
  }
  if (q) {
    const like = add(`%${q.replace(/[%_\\]/g, (m) => `\\${m}`)}%`);
    where.push(`(c.title ILIKE ${like} OR c.description ILIKE ${like} OR c.city ILIKE ${like} OR o.name ILIKE ${like}
                 OR v.name ILIKE ${like} OR v.area ILIKE ${like} OR v.city ILIKE ${like} OR c.sponsor ILIKE ${like}
                 OR c.arena_exercise ILIKE ${like} OR c.metric ILIKE ${like})`);
  }
  const order =
    status === 'past' ? 'c.ends_on DESC' : status === 'upcoming' ? 'c.starts_on ASC' : 'joined DESC, c.ends_on ASC';
  const rows = await query(
    `${EVENT_SELECT} ${where.length ? `WHERE ${where.join(' AND ')}` : ''} ORDER BY ${order} LIMIT ${add(limit)}`,
    params,
  );
  const verified = new Set(myOrgIds);
  return {
    events: rows.map((r) => {
      const e = shapeEvent(r);
      const orgs = allowedOrgs(r);
      return { ...e, requiresOrg: orgs.length > 0, isMyOrg: orgs.some((o) => verified.has(o.id)) };
    }),
    myOrgs: memberships,
  };
}

async function loadEvent(id, userId) {
  if (!uuidSchema.safeParse(id).success) throw notFound('Event not found');
  const row = await queryOne(`${EVENT_SELECT} WHERE c.id = $3`, [userId, config.tz, id]);
  if (!row) throw notFound('Event not found');
  return row;
}

export async function eventDetail(id, userId, { city, orgId } = {}) {
  const row = await loadEvent(id, userId);
  const memberships = await myOrgMemberships(userId);
  const board = await eventLeaderboard(row, userId, { city, orgId });
  const battle = row.battleOrgs ?? [];
  // Team ranking needs the unfiltered board.
  const teams =
    battle.length > 1
      ? teamRanking(battle, orgId || city ? (await eventLeaderboard(row, userId)).all : board.all)
      : null;
  return {
    event: { ...shapeEvent(row), requiresOrg: allowedOrgs(row).length > 0 },
    leaderboard: { entries: board.entries, me: board.me },
    teams,
    teamRanking: teams ? 'average' : null,
    eligibility: await eligibility(row, userId, memberships),
  };
}

export async function joinEvent(id, userId, { orgId } = {}) {
  const row = await loadEvent(id, userId);
  if (row.joined) return { joined: true, already: true };
  const memberships = await myOrgMemberships(userId);
  const el = await eligibility(row, userId, memberships);
  if (!el.canJoin) {
    if (el.reason === 'org_verification' || el.reason === 'org_pending') {
      throw new HttpError(403, el.message, { reason: el.reason, orgs: el.orgs });
    }
    throw badRequest(el.message);
  }
  let repOrg = null;
  if (el.orgs.length) {
    repOrg = orgId && el.eligibleOrgIds.includes(orgId) ? orgId : el.eligibleOrgIds[0];
  } else {
    // Open events: still record a verified org so org-wise leaderboards work.
    repOrg = memberships.find((m) => m.status === 'verified' && m.orgId === orgId)?.orgId ?? null;
  }
  const inserted = await queryOne(
    `INSERT INTO contest_participants (contest_id, user_id, org_id) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING
     RETURNING contest_id`,
    [row.id, userId, repOrg],
  );
  if (inserted && row.kind === 'partner' && row.venueId) await notifyHostOfRegistration(row, userId);
  // Registered after already checking in at the venue on the event day → count attendance now.
  if (row.format === 'onground' && row.venueId) {
    await query(
      `UPDATE contest_participants cp SET attended_at = now()
       FROM checkins ch
       WHERE cp.contest_id = $1 AND cp.user_id = $2 AND cp.attended_at IS NULL
         AND ch.user_id = $2 AND ch.venue_id = $3 AND ch.checkin_date = $4::date
         AND ch.checkin_date = (now() AT TIME ZONE $5)::date`,
      [row.id, userId, row.venueId, row.eventDate, config.tz],
    );
  }
  await notify(userId, {
    type: 'event_joined',
    title: `You're in: ${row.title}`,
    body:
      row.format === 'onground'
        ? `See you on ${row.eventDate} at ${row.venueName ?? 'the venue'} — check in there to mark attendance.`
        : 'Your score updates on the event leaderboard as you train.',
    data: { contestId: row.id },
  });
  return { joined: true };
}

/**
 * Called by POST /checkins: marks attendance for on-ground events at this venue today that the member registered for.
 * Returns the events newly attended.
 */
export async function markEventAttendance(userId, venueId, client) {
  return query(
    `UPDATE contest_participants cp SET attended_at = now()
     FROM contests c
     WHERE cp.contest_id = c.id AND cp.user_id = $1 AND cp.attended_at IS NULL
       AND c.format = 'onground' AND c.venue_id = $2 AND c.event_date = (now() AT TIME ZONE $3)::date
     RETURNING c.id, c.title`,
    [userId, venueId, config.tz],
    client,
  );
}

/** On-ground events today at this venue that the member is registered for (lets them check in without a plan). */
export async function registeredEventsToday(userId, venueId, client) {
  return query(
    `SELECT c.id, c.title FROM contests c
     JOIN contest_participants cp ON cp.contest_id = c.id AND cp.user_id = $1
     WHERE c.format = 'onground' AND c.venue_id = $2 AND c.event_date = (now() AT TIME ZONE $3)::date`,
    [userId, venueId, config.tz],
    client,
  );
}

// ---------------------------------------------------------------------------
// Admin (FitKey team) — mounted first so /admin/* never reaches the member routes.
// ---------------------------------------------------------------------------

const admin = Router();
admin.use(requireAuth('admin'));
router.use('/admin', admin);

const domainSchema = z
  .string()
  .trim()
  .toLowerCase()
  .transform((d) => d.replace(/^@/, ''))
  .refine((d) => /^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(d), 'Enter a domain like company.com');
const inviteCodeSchema = z
  .string()
  .trim()
  .toUpperCase()
  .regex(/^[A-Z0-9-]{4,24}$/, 'Invite codes are 4–24 letters, digits or dashes');
const urlSchema = z.string().trim().max(1000).refine((u) => /^(https?:\/\/|\/api\/v1\/files\/)/.test(u), 'Invalid URL');

const orgBody = {
  name: z.string().trim().min(2).max(120),
  kind: z.enum(['company', 'college']),
  logoUrl: urlSchema.nullable(),
  inviteCode: inviteCodeSchema.nullable(),
  domains: z.array(domainSchema).max(20),
};

async function setOrgDomains(client, orgId, domains) {
  for (const d of domains) {
    const owner = await queryOne(`SELECT org_id FROM org_domains WHERE domain = $1`, [d], client);
    if (owner && owner.orgId !== orgId) throw conflict(`${d} already belongs to another org`);
  }
  await query(`DELETE FROM org_domains WHERE org_id = $1 AND NOT (domain = ANY($2::text[]))`, [orgId, domains], client);
  for (const d of domains) {
    await query(`INSERT INTO org_domains (domain, org_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [d, orgId], client);
  }
}

const ORG_ADMIN_SELECT = `
  SELECT o.*,
    COALESCE((SELECT array_agg(d.domain ORDER BY d.domain) FROM org_domains d WHERE d.org_id = o.id), '{}') AS domains,
    (SELECT COUNT(*) FROM org_memberships m WHERE m.org_id = o.id AND m.status = 'verified') AS verified_members,
    (SELECT COUNT(*) FROM org_memberships m WHERE m.org_id = o.id AND m.status = 'pending') AS pending_members
  FROM orgs o`;

/** GET /events/admin/orgs */
admin.get('/orgs', async (_req, res) => {
  res.json({ orgs: await query(`${ORG_ADMIN_SELECT} ORDER BY o.name`) });
});

function pgUniqueToConflict(err) {
  if (err?.code === '23505') return conflict('That invite code is already used by another org');
  return err;
}

/** POST /events/admin/orgs { name, kind, logoUrl?, inviteCode?, domains? } */
admin.post('/orgs', async (req, res) => {
  const b = validate(
    z.object({
      name: orgBody.name,
      kind: orgBody.kind.default('company'),
      logoUrl: orgBody.logoUrl.optional(),
      inviteCode: orgBody.inviteCode.optional(),
      domains: orgBody.domains.default([]),
    }),
    req.body,
  );
  try {
    const id = await withTransaction(async (client) => {
      const org = await queryOne(
        `INSERT INTO orgs (name, kind, logo_url, invite_code) VALUES ($1, $2, $3, $4) RETURNING id`,
        [b.name, b.kind, b.logoUrl ?? null, b.inviteCode ?? null],
        client,
      );
      await setOrgDomains(client, org.id, b.domains);
      return org.id;
    });
    res.status(201).json({ org: await queryOne(`${ORG_ADMIN_SELECT} WHERE o.id = $1`, [id]) });
  } catch (err) {
    throw pgUniqueToConflict(err);
  }
});

/** PATCH /events/admin/orgs/:id { name?, kind?, logoUrl?, inviteCode? (null clears), domains? (replaces the list) } */
admin.patch('/orgs/:id', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const b = validate(z.object(orgBody).partial(), req.body);
  try {
    await withTransaction(async (client) => {
      const org = await queryOne(`SELECT id FROM orgs WHERE id = $1 FOR UPDATE`, [id], client);
      if (!org) throw notFound('Org not found');
      const sets = [];
      const params = [id];
      for (const [key, col] of [['name', 'name'], ['kind', 'kind'], ['logoUrl', 'logo_url'], ['inviteCode', 'invite_code']]) {
        if (b[key] !== undefined) {
          params.push(b[key]);
          sets.push(`${col} = $${params.length}`);
        }
      }
      if (sets.length) await query(`UPDATE orgs SET ${sets.join(', ')} WHERE id = $1`, params, client);
      if (b.domains) await setOrgDomains(client, id, b.domains);
    });
  } catch (err) {
    throw pgUniqueToConflict(err);
  }
  res.json({ org: await queryOne(`${ORG_ADMIN_SELECT} WHERE o.id = $1`, [id]) });
});

/** GET /events/admin/memberships?status=pending|verified|removed&orgId= */
admin.get('/memberships', async (req, res) => {
  const { status, orgId } = validate(
    z.object({ status: z.enum(['pending', 'verified', 'removed']).default('pending'), orgId: uuidSchema.optional() }),
    req.query,
  );
  const memberships = await query(
    `SELECT m.*, o.name AS org_name, o.kind AS org_kind, u.name AS user_name, u.phone AS user_phone, u.city AS user_city
     FROM org_memberships m JOIN orgs o ON o.id = m.org_id JOIN users u ON u.id = m.user_id
     WHERE m.status = $1 AND ($2::uuid IS NULL OR m.org_id = $2)
     ORDER BY m.requested_at DESC LIMIT 200`,
    [status, orgId ?? null],
  );
  res.json({ memberships });
});

async function reviewMembership(req, res, approve) {
  const orgId = validate(uuidSchema, req.params.orgId);
  const userId = validate(uuidSchema, req.params.userId);
  const { note, department } = validate(
    z.object({ note: z.string().trim().max(300).optional(), department: z.string().trim().max(80).optional() }),
    req.body ?? {},
  );
  const m = await queryOne(
    `UPDATE org_memberships SET status = $3::varchar, reviewed_by = $4, review_note = $5,
            department = COALESCE($6, department), verified_at = CASE WHEN $3::varchar = 'verified' THEN now() ELSE verified_at END
     WHERE org_id = $1 AND user_id = $2 RETURNING *`,
    [orgId, userId, approve ? 'verified' : 'removed', req.user.id, note ?? null, department ?? null],
  );
  if (!m) throw notFound('Membership request not found');
  const org = await queryOne(`SELECT name FROM orgs WHERE id = $1`, [orgId]);
  await notify(userId, {
    type: approve ? 'org_verified' : 'org_rejected',
    title: approve ? `You're verified at ${org.name}` : `We couldn't verify your ${org.name} ID`,
    body: approve
      ? 'Your org badge is live — you can now join its events.'
      : (note ?? 'Please upload a clearer photo of your ID or use your official email.'),
    data: { orgId },
  });
  res.json({ membership: m });
}

/** POST /events/admin/memberships/:orgId/:userId/approve { department?, note? } */
admin.post('/memberships/:orgId/:userId/approve', (req, res) => reviewMembership(req, res, true));
/** POST /events/admin/memberships/:orgId/:userId/reject { note? } */
admin.post('/memberships/:orgId/:userId/reject', (req, res) => reviewMembership(req, res, false));

const VIRTUAL_METRICS = ['checkins', 'running_km', 'streak'];

const eventInputSchema = z.object({
  title: z.string().trim().min(3).max(160),
  description: z.string().trim().max(4000).nullable().optional(),
  kind: z.enum(['fitkey', 'org', 'partner']).default('fitkey'),
  format: z.enum(['virtual', 'onground', 'ai']).default('virtual'),
  metric: z.enum(['checkins', 'running_km', 'streak', 'attendance', 'arena_reps']).optional(),
  period: z.enum(['weekly', 'monthly', 'custom']).default('custom'),
  startsOn: dateSchema.optional(),
  endsOn: dateSchema.optional(),
  eventDate: dateSchema.nullable().optional(),
  reward: z.string().trim().max(200).nullable().optional(),
  city: z.string().trim().max(80).nullable().optional(),
  orgId: uuidSchema.nullable().optional(),
  venueId: uuidSchema.nullable().optional(),
  membersOnly: z.boolean().default(false),
  arenaExercise: z
    .string()
    .trim()
    .regex(/^[a-z0-9_]{2,20}$/, 'Use the AI Arena exercise id, e.g. pushups')
    .nullable()
    .optional(),
  coverUrl: urlSchema.nullable().optional(),
  sponsor: z.string().trim().max(120).nullable().optional(),
  registrationFeePaise: z.number().int().min(0).max(10_000_000).default(0),
  battleOrgIds: z.array(uuidSchema).max(20).optional(),
});

/** Validates the cross-field rules and returns DB-ready values. */
async function normalizeEvent(input) {
  const e = validate(eventInputSchema, input);
  const today = (await queryOne(`SELECT (now() AT TIME ZONE $1)::date AS d`, [config.tz])).d;
  if (e.format === 'onground') {
    if (!e.venueId) throw badRequest('On-ground events need a venueId');
    if (!e.eventDate) throw badRequest('On-ground events need an eventDate');
    e.metric = 'attendance';
    e.startsOn ??= e.eventDate < today ? e.eventDate : today;
    e.endsOn ??= e.eventDate;
    if (e.eventDate < e.startsOn || e.eventDate > e.endsOn) throw badRequest('eventDate must be within startsOn–endsOn');
  } else if (e.format === 'ai') {
    if (!e.arenaExercise) throw badRequest('AI-verified events need an arenaExercise (e.g. pushups)');
    e.metric = 'arena_reps';
  } else {
    if (!e.metric || !VIRTUAL_METRICS.includes(e.metric)) {
      throw badRequest(`Virtual events need a metric: ${VIRTUAL_METRICS.join(', ')}`);
    }
  }
  if (!e.startsOn || !e.endsOn) throw badRequest('startsOn and endsOn are required');
  if (e.endsOn < e.startsOn) throw badRequest('endsOn must be on or after startsOn');
  if (e.format !== 'onground') e.eventDate = null;
  if (e.format !== 'ai') e.arenaExercise = null;
  if (e.kind === 'org' && !e.orgId) throw badRequest('Org events need an orgId');
  if (e.kind !== 'org') e.orgId = null;
  if (e.kind === 'partner' && !e.venueId) throw badRequest('Partner events need the host venueId');
  if (e.kind !== 'partner') e.membersOnly = false;
  if (e.orgId && !(await queryOne(`SELECT 1 FROM orgs WHERE id = $1`, [e.orgId]))) throw badRequest('Unknown orgId');
  if (e.venueId && !(await queryOne(`SELECT 1 FROM venues WHERE id = $1`, [e.venueId]))) throw badRequest('Unknown venueId');
  if (e.battleOrgIds?.length) {
    const found = await query(`SELECT id FROM orgs WHERE id = ANY($1::uuid[])`, [e.battleOrgIds]);
    if (found.length !== new Set(e.battleOrgIds).size) throw badRequest('Unknown org in battleOrgIds');
  }
  return e;
}

const EVENT_COLUMNS = [
  ['title', 'title'],
  ['description', 'description'],
  ['kind', 'kind'],
  ['format', 'format'],
  ['metric', 'metric'],
  ['period', 'period'],
  ['startsOn', 'starts_on'],
  ['endsOn', 'ends_on'],
  ['eventDate', 'event_date'],
  ['reward', 'reward'],
  ['city', 'city'],
  ['orgId', 'org_id'],
  ['venueId', 'venue_id'],
  ['membersOnly', 'members_only'],
  ['arenaExercise', 'arena_exercise'],
  ['coverUrl', 'cover_url'],
  ['sponsor', 'sponsor'],
  ['registrationFeePaise', 'registration_fee_paise'],
];

async function setBattleOrgs(client, contestId, orgIds) {
  await query(`DELETE FROM contest_orgs WHERE contest_id = $1 AND NOT (org_id = ANY($2::uuid[]))`, [contestId, orgIds], client);
  for (const o of orgIds) {
    await query(`INSERT INTO contest_orgs (contest_id, org_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [contestId, o], client);
  }
}

const ADMIN_EVENT_SELECT = `
  SELECT c.*, o.name AS org_name, v.name AS venue_name,
    (SELECT COUNT(*) FROM contest_participants p WHERE p.contest_id = c.id) AS participant_count,
    (SELECT COUNT(*) FROM contest_participants p WHERE p.contest_id = c.id AND p.attended_at IS NOT NULL) AS attended_count,
    COALESCE((SELECT array_agg(co.org_id) FROM contest_orgs co WHERE co.contest_id = c.id), '{}') AS battle_org_ids
  FROM contests c LEFT JOIN orgs o ON o.id = c.org_id LEFT JOIN venues v ON v.id = c.venue_id`;

/** GET /events/admin/events?status=live|upcoming|past|any */
admin.get('/events', async (req, res) => {
  const { status } = validate(z.object({ status: z.enum(['live', 'upcoming', 'past', 'any']).default('any') }), req.query);
  const cond = {
    any: 'true',
    live: `c.starts_on <= ${todaySql} AND c.ends_on >= ${todaySql}`,
    upcoming: `c.starts_on > ${todaySql}`,
    past: `c.ends_on < ${todaySql}`,
  }[status].replaceAll('$TZ', '$1');
  const events = await query(
    `${ADMIN_EVENT_SELECT} WHERE ${cond} AND $1::text IS NOT NULL ORDER BY c.starts_on DESC LIMIT 300`,
    [config.tz],
  );
  res.json({ events: events.map((e) => ({ ...e, unit: METRIC_UNITS[e.metric] ?? '' })) });
});

/** POST /events/admin/events — see eventInputSchema for fields. */
admin.post('/events', async (req, res) => {
  const e = await normalizeEvent(req.body);
  const id = await withTransaction(async (client) => {
    const cols = EVENT_COLUMNS.map(([, c]) => c).concat('created_by');
    const vals = EVENT_COLUMNS.map(([k]) => e[k] ?? null).concat(req.user.id);
    vals[EVENT_COLUMNS.findIndex(([k]) => k === 'membersOnly')] = e.membersOnly;
    vals[EVENT_COLUMNS.findIndex(([k]) => k === 'registrationFeePaise')] = e.registrationFeePaise;
    const row = await queryOne(
      `INSERT INTO contests (${cols.join(', ')}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(', ')}) RETURNING id`,
      vals,
      client,
    );
    if (e.battleOrgIds) await setBattleOrgs(client, row.id, e.battleOrgIds);
    return row.id;
  });
  res.status(201).json({ event: await queryOne(`${ADMIN_EVENT_SELECT} WHERE c.id = $1`, [id]) });
});

/** PATCH /events/admin/events/:id — any subset of the create fields; battleOrgIds replaces the list. */
admin.patch('/events/:id', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const existing = await queryOne(`SELECT * FROM contests WHERE id = $1`, [id]);
  if (!existing) throw notFound('Event not found');
  const body = validate(z.record(z.string(), z.unknown()), req.body ?? {});
  const merged = {};
  for (const [k] of EVENT_COLUMNS) if (existing[k] !== null && existing[k] !== undefined) merged[k] = existing[k];
  const e = await normalizeEvent({ ...merged, ...body });
  await withTransaction(async (client) => {
    const params = [id, ...EVENT_COLUMNS.map(([k]) => e[k] ?? null)];
    params[1 + EVENT_COLUMNS.findIndex(([k]) => k === 'membersOnly')] = e.membersOnly;
    params[1 + EVENT_COLUMNS.findIndex(([k]) => k === 'registrationFeePaise')] = e.registrationFeePaise;
    await query(
      `UPDATE contests SET ${EVENT_COLUMNS.map(([, c], i) => `${c} = $${i + 2}`).join(', ')} WHERE id = $1`,
      params,
      client,
    );
    if (e.battleOrgIds) await setBattleOrgs(client, id, e.battleOrgIds);
  });
  res.json({ event: await queryOne(`${ADMIN_EVENT_SELECT} WHERE c.id = $1`, [id]) });
});

/** DELETE /events/admin/events/:id */
admin.delete('/events/:id', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const deleted = await queryOne(`DELETE FROM contests WHERE id = $1 RETURNING id`, [id]);
  if (!deleted) throw notFound('Event not found');
  res.status(204).end();
});

/** GET /events/admin/events/:id/participants — registrations with attendance, for on-ground ops. */
admin.get('/events/:id/participants', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const participants = await query(
    `SELECT cp.user_id, u.name, u.phone, u.city, cp.joined_at, cp.attended_at, cp.org_id, o.name AS org_name
     FROM contest_participants cp JOIN users u ON u.id = cp.user_id LEFT JOIN orgs o ON o.id = cp.org_id
     WHERE cp.contest_id = $1 ORDER BY cp.joined_at`,
    [id],
  );
  res.json({ participants });
});

// ---------------------------------------------------------------------------
// Partner (gym / studio / sports club owners) — Partner Events for venues they own (venues.owner_id).
// Mounted before the member routes so /partner/* never reaches them.
// ---------------------------------------------------------------------------

const partner = Router();
partner.use(requireAuth('partner'));
router.use('/partner', partner);

/** Tells the venue owner that a member registered for their partner event. Never throws (notify doesn't). */
async function notifyHostOfRegistration(row, userId) {
  try {
    const host = await queryOne(
      `SELECT v.owner_id, u.name AS member_name,
              (SELECT COUNT(*) FROM contest_participants x WHERE x.contest_id = $3) AS registered
       FROM venues v, users u WHERE v.id = $1 AND u.id = $2`,
      [row.venueId, userId, row.id],
    );
    if (!host?.ownerId) return;
    const first = host.memberName?.trim().split(/\s+/)[0] || 'A member';
    await notify(host.ownerId, {
      type: 'event_registration',
      title: `New registration: ${row.title}`,
      body: `${first} registered · ${host.registered} registered so far`,
      data: { contestId: row.id, venueId: row.venueId, partnerEvent: true },
    });
  } catch (err) {
    console.error('event host notify failed:', err.message);
  }
}

const PARTNER_EVENT_SELECT = `
  SELECT c.*, v.name AS venue_name, v.area AS venue_area, v.city AS venue_city, v.address AS venue_address,
         v.photos[1] AS venue_photo, v.categories AS venue_categories, v.status AS venue_status,
         (SELECT COUNT(*) FROM contest_participants p WHERE p.contest_id = c.id) AS participant_count,
         (SELECT COUNT(*) FROM contest_participants p WHERE p.contest_id = c.id AND p.attended_at IS NOT NULL) AS attended_count,
         CASE WHEN c.ends_on < today.d THEN 'past' WHEN c.starts_on > today.d THEN 'upcoming' ELSE 'live' END AS status
  FROM contests c
  JOIN venues v ON v.id = c.venue_id AND v.owner_id = $1
  CROSS JOIN (SELECT (now() AT TIME ZONE $2)::date AS d) today`;

function shapePartnerEvent(e) {
  const {
    createdBy: _c,
    venueName,
    venueArea,
    venueCity,
    venueAddress,
    venuePhoto,
    venueCategories,
    venueStatus,
    orgId: _o,
    ...rest
  } = e;
  return {
    ...rest,
    unit: METRIC_UNITS[e.metric] ?? '',
    // Only partner-kind events are the owner's to change; FitKey events hosted at their venue are read-only.
    canEdit: e.kind === 'partner',
    venue: {
      id: e.venueId,
      name: venueName,
      area: venueArea,
      city: venueCity,
      address: venueAddress,
      photo: venuePhoto,
      categories: venueCategories ?? [],
      status: venueStatus,
    },
  };
}

async function loadPartnerEvent(id, partnerId) {
  if (!uuidSchema.safeParse(id).success) throw notFound('Event not found');
  const row = await queryOne(`${PARTNER_EVENT_SELECT} WHERE c.id = $3`, [partnerId, config.tz, id]);
  if (!row) throw notFound('Event not found');
  return row;
}

async function assertOwnVenue(venueId, partnerId) {
  if (!venueId) throw badRequest('Choose the venue hosting this event');
  const v = await queryOne(`SELECT status, name FROM venues WHERE id = $1 AND owner_id = $2`, [venueId, partnerId]);
  if (!v) throw forbidden('You can only host events at your own venues');
  if (v.status !== 'live') throw badRequest(`${v.name} must be live on FitKey before it can host events`);
}

// Partners set everything except who hosts it (always their venue, kind 'partner') and org / battle / fee fields.
const partnerEventSchema = eventInputSchema.omit({ kind: true, orgId: true, battleOrgIds: true, registrationFeePaise: true });

const PARTNER_FIELDS_NOTIFIED = [
  ['title', 'title'],
  ['startsOn', 'dates'],
  ['endsOn', 'dates'],
  ['eventDate', 'event day'],
  ['venueId', 'venue'],
  ['format', 'format'],
  ['metric', 'scoring'],
  ['arenaExercise', 'exercise'],
];

/** GET /events/partner/events?status=live|upcoming|past|any&venueId= — events hosted at my venues. */
partner.get('/events', async (req, res) => {
  const { status, venueId } = validate(
    z.object({ status: z.enum(['live', 'upcoming', 'past', 'any']).default('any'), venueId: uuidSchema.optional() }),
    req.query,
  );
  const where = [];
  if (status === 'live') where.push(`c.starts_on <= today.d AND c.ends_on >= today.d`);
  if (status === 'upcoming') where.push(`c.starts_on > today.d`);
  if (status === 'past') where.push(`c.ends_on < today.d`);
  const params = [req.user.id, config.tz];
  if (venueId) {
    params.push(venueId);
    where.push(`c.venue_id = $${params.length}`);
  }
  const order = status === 'past' ? 'c.ends_on DESC' : 'c.starts_on ASC, c.ends_on ASC';
  const rows = await query(
    `${PARTNER_EVENT_SELECT} ${where.length ? `WHERE ${where.join(' AND ')}` : ''} ORDER BY ${order} LIMIT 200`,
    params,
  );
  const counts = await queryOne(
    `SELECT COUNT(*) FILTER (WHERE c.starts_on <= today.d AND c.ends_on >= today.d)::int AS live,
            COUNT(*) FILTER (WHERE c.starts_on > today.d)::int AS upcoming,
            COUNT(*) FILTER (WHERE c.ends_on < today.d)::int AS past
     FROM contests c JOIN venues v ON v.id = c.venue_id AND v.owner_id = $1
     CROSS JOIN (SELECT (now() AT TIME ZONE $2)::date AS d) today
     WHERE ($3::uuid IS NULL OR c.venue_id = $3)`,
    [req.user.id, config.tz, venueId ?? null],
  );
  res.json({ events: rows.map(shapePartnerEvent), counts });
});

/** GET /events/partner/events/:id — event + its leaderboard (same scoring as the member app). */
partner.get('/events/:id', async (req, res) => {
  const row = await loadPartnerEvent(req.params.id, req.user.id);
  const board = await eventLeaderboard(row, null);
  res.json({ event: shapePartnerEvent(row), leaderboard: { entries: board.entries.map(publicEntry) } });
});

/** Leaderboard row without org / ids beyond what the member app shows publicly. */
function publicEntry(r) {
  return { userId: r.userId, name: r.name, city: r.city, avatarUrl: r.avatarUrl, score: r.score, rank: r.rank, attendedAt: r.attendedAt };
}

/** GET /events/partner/events/:id/leaderboard */
partner.get('/events/:id/leaderboard', async (req, res) => {
  const row = await loadPartnerEvent(req.params.id, req.user.id);
  const board = await eventLeaderboard(row, null);
  res.json({ entries: board.entries.map(publicEntry), unit: METRIC_UNITS[row.metric] ?? '' });
});

/** GET /events/partner/events/:id/participants — registrations with attendance (no phone numbers). */
partner.get('/events/:id/participants', async (req, res) => {
  const row = await loadPartnerEvent(req.params.id, req.user.id);
  const participants = await query(
    `SELECT cp.user_id, u.name, u.city, u.avatar_url, cp.joined_at, cp.attended_at
     FROM contest_participants cp JOIN users u ON u.id = cp.user_id
     WHERE cp.contest_id = $1 ORDER BY cp.attended_at IS NULL, cp.joined_at`,
    [row.id],
  );
  res.json({
    participants: participants.map((p) => ({ ...p, attended: p.attendedAt != null })),
    total: participants.length,
    attended: participants.filter((p) => p.attendedAt != null).length,
  });
});

/** POST /events/partner/events — create a partner event at one of my live venues. */
partner.post('/events', async (req, res) => {
  const body = validate(partnerEventSchema, req.body ?? {});
  await assertOwnVenue(body.venueId, req.user.id);
  const e = await normalizeEvent({ ...body, kind: 'partner', registrationFeePaise: 0 });
  const cols = EVENT_COLUMNS.map(([, c]) => c).concat('created_by');
  const vals = EVENT_COLUMNS.map(([k]) => e[k] ?? null).concat(req.user.id);
  vals[EVENT_COLUMNS.findIndex(([k]) => k === 'membersOnly')] = e.membersOnly;
  vals[EVENT_COLUMNS.findIndex(([k]) => k === 'registrationFeePaise')] = 0;
  const created = await queryOne(
    `INSERT INTO contests (${cols.join(', ')}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(', ')}) RETURNING id`,
    vals,
  );
  res.status(201).json({ event: shapePartnerEvent(await loadPartnerEvent(created.id, req.user.id)) });
});

/** PATCH /events/partner/events/:id — any subset of the create fields; registered members are notified of changes. */
partner.patch('/events/:id', async (req, res) => {
  const existing = await loadPartnerEvent(req.params.id, req.user.id);
  if (existing.kind !== 'partner') throw forbidden('FitKey-run events at your venue can only be changed by the FitKey team');
  if (existing.status === 'past') throw badRequest('This event has ended and can no longer be edited');
  const body = validate(partnerEventSchema.partial(), req.body ?? {});
  if (body.venueId !== undefined && body.venueId !== existing.venueId) await assertOwnVenue(body.venueId, req.user.id);
  const merged = {};
  for (const [k] of EVENT_COLUMNS) if (existing[k] !== null && existing[k] !== undefined) merged[k] = existing[k];
  const e = await normalizeEvent({ ...merged, ...body, kind: 'partner', orgId: null, registrationFeePaise: 0 });
  const params = [existing.id, ...EVENT_COLUMNS.map(([k]) => e[k] ?? null)];
  params[1 + EVENT_COLUMNS.findIndex(([k]) => k === 'membersOnly')] = e.membersOnly;
  params[1 + EVENT_COLUMNS.findIndex(([k]) => k === 'registrationFeePaise')] = 0;
  await query(`UPDATE contests SET ${EVENT_COLUMNS.map(([, c], i) => `${c} = $${i + 2}`).join(', ')} WHERE id = $1`, params);
  const updated = await loadPartnerEvent(existing.id, req.user.id);

  const changed = [
    ...new Set(PARTNER_FIELDS_NOTIFIED.filter(([k]) => (existing[k] ?? null) !== (updated[k] ?? null)).map(([, l]) => l)),
  ];
  let notified = 0;
  if (changed.length) {
    const people = await query(`SELECT user_id FROM contest_participants WHERE contest_id = $1`, [existing.id]);
    const when =
      updated.format === 'onground'
        ? `Now on ${updated.eventDate} at ${updated.venueName}.`
        : `Runs ${updated.startsOn} – ${updated.endsOn}.`;
    for (const p of people) {
      await notify(p.userId, {
        type: 'event_updated',
        title: `Event updated: ${updated.title}`,
        body: `${updated.venueName} changed the ${changed.join(', ')}. ${when}`,
        data: { contestId: existing.id },
      });
    }
    notified = people.length;
  }
  res.json({ event: shapePartnerEvent(updated), changed, notified });
});

/** DELETE /events/partner/events/:id — cancels an event that hasn't ended; registered members are notified. */
partner.delete('/events/:id', async (req, res) => {
  const existing = await loadPartnerEvent(req.params.id, req.user.id);
  if (existing.kind !== 'partner') throw forbidden('FitKey-run events at your venue can only be changed by the FitKey team');
  if (existing.status === 'past') throw badRequest('Past events stay on members’ history and can’t be deleted');
  const people = await query(`SELECT user_id FROM contest_participants WHERE contest_id = $1`, [existing.id]);
  await query(`DELETE FROM contests WHERE id = $1`, [existing.id]);
  for (const p of people) {
    await notify(p.userId, {
      type: 'event_cancelled',
      title: `Cancelled: ${existing.title}`,
      body: `${existing.venueName} has cancelled this event. Sorry for the change of plans!`,
      data: { venueId: existing.venueId },
    });
  }
  res.json({ deleted: true, notified: people.length });
});

// ---------------------------------------------------------------------------
// Member routes
// ---------------------------------------------------------------------------

router.use(requireAuth('user'));

const OTP_TTL_MINUTES = 10;
const OTP_MAX_ATTEMPTS = 5;
const hashOtp = (userId, email, code) =>
  crypto.createHmac('sha256', config.otpSecret).update(`org:${userId}:${email}:${code}`).digest('hex');

const verifyLimiter = rateLimit({
  windowMs: 10 * 60 * 1000,
  limit: 20,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.user.id,
  message: { error: 'Too many attempts — please wait a few minutes and try again' },
});

const emailSchema = z.string().trim().toLowerCase().email('Enter a valid email address').max(255);

/** Finds the org for an email by its domain or any parent domain (mail.iitd.ac.in → iitd.ac.in). */
async function orgForEmail(email) {
  const parts = email.split('@')[1].split('.');
  const candidates = [];
  for (let i = 0; i < parts.length - 1; i++) candidates.push(parts.slice(i).join('.'));
  return queryOne(
    `SELECT o.id, o.name, o.kind, d.domain FROM org_domains d JOIN orgs o ON o.id = d.org_id
     WHERE d.domain = ANY($1::text[]) ORDER BY length(d.domain) DESC LIMIT 1`,
    [candidates],
  );
}

async function upsertMembership(userId, orgId, { method, status, workEmail = null, idProofUrl = null, department = null }) {
  return queryOne(
    `INSERT INTO org_memberships (org_id, user_id, work_email, method, status, department, id_proof_url, verified_at, requested_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, now(), now())
     ON CONFLICT (org_id, user_id) DO UPDATE SET
       work_email = COALESCE(EXCLUDED.work_email, org_memberships.work_email),
       method = EXCLUDED.method, status = EXCLUDED.status,
       department = COALESCE(EXCLUDED.department, org_memberships.department),
       id_proof_url = COALESCE(EXCLUDED.id_proof_url, org_memberships.id_proof_url),
       verified_at = CASE WHEN EXCLUDED.status = 'verified' THEN now() ELSE org_memberships.verified_at END,
       requested_at = now(), review_note = NULL
     RETURNING org_id, status, method, work_email, department, verified_at`,
    [orgId, userId, workEmail, method, status, department, idProofUrl],
  );
}

/** GET /events/orgs/mine — my org memberships (verified ones are the profile badges). */
router.get('/orgs/mine', async (req, res) => {
  res.json({ memberships: await myOrgMemberships(req.user.id) });
});

/** POST /events/orgs/email/request { email, orgId? } — sends an OTP to a work / college email. */
router.post('/orgs/email/request', verifyLimiter, async (req, res) => {
  const { email, orgId } = validate(z.object({ email: emailSchema, orgId: uuidSchema.optional() }), req.body);
  const org = await orgForEmail(email);
  if (!org) {
    throw badRequest(
      `@${email.split('@')[1]} isn't registered with FitKey yet. Ask your HR / college to partner with FitKey, or use an invite code.`,
    );
  }
  if (orgId && org.id !== orgId) {
    const wanted = await queryOne(`SELECT name FROM orgs WHERE id = $1`, [orgId]);
    throw badRequest(`That email belongs to ${org.name}${wanted ? `, not ${wanted.name}` : ''}`);
  }
  const existing = await queryOne(`SELECT status FROM org_memberships WHERE org_id = $1 AND user_id = $2`, [
    org.id,
    req.user.id,
  ]);
  if (existing?.status === 'verified') return res.json({ alreadyVerified: true, org });
  const taken = await queryOne(
    `SELECT 1 FROM org_memberships WHERE org_id = $1 AND lower(work_email) = $2 AND user_id <> $3 AND status = 'verified'`,
    [org.id, email, req.user.id],
  );
  if (taken) throw conflict('This email is already verified on another FitKey account');

  const code = String(crypto.randomInt(100000, 1000000));
  await query(`UPDATE org_email_otps SET consumed_at = now() WHERE user_id = $1 AND consumed_at IS NULL`, [req.user.id]);
  await query(
    `INSERT INTO org_email_otps (user_id, org_id, email, code_hash, expires_at)
     VALUES ($1, $2, $3, $4, now() + make_interval(mins => $5))`,
    [req.user.id, org.id, email, hashOtp(req.user.id, email, code), OTP_TTL_MINUTES],
  );
  await sendEmailOtp(email, code, { orgName: org.name });
  res.json({
    sent: true,
    org: { id: org.id, name: org.name, kind: org.kind },
    expiresInSeconds: OTP_TTL_MINUTES * 60,
    ...(config.exposeDevOtp ? { devOtp: code } : {}),
  });
});

/** POST /events/orgs/email/verify { email, otp } → verified membership (org badge). */
router.post('/orgs/email/verify', verifyLimiter, async (req, res) => {
  const { email, otp } = validate(
    z.object({ email: emailSchema, otp: z.string().regex(/^\d{6}$/, 'OTP must be 6 digits') }),
    req.body,
  );
  const record = await queryOne(
    `SELECT r.id, r.org_id, r.code_hash, r.attempts, o.name AS org_name FROM org_email_otps r JOIN orgs o ON o.id = r.org_id
     WHERE r.user_id = $1 AND r.email = $2 AND r.consumed_at IS NULL AND r.expires_at > now()
     ORDER BY r.created_at DESC LIMIT 1`,
    [req.user.id, email],
  );
  if (!record) throw unauthorized('Code expired — request a new one');
  if (record.attempts >= OTP_MAX_ATTEMPTS) throw new HttpError(429, 'Too many attempts — request a new code');
  const ok = crypto.timingSafeEqual(
    Buffer.from(record.codeHash, 'hex'),
    Buffer.from(hashOtp(req.user.id, email, otp), 'hex'),
  );
  if (!ok) {
    await query(`UPDATE org_email_otps SET attempts = attempts + 1 WHERE id = $1`, [record.id]);
    throw badRequest('Incorrect code');
  }
  await query(`UPDATE org_email_otps SET consumed_at = now() WHERE id = $1`, [record.id]);
  const membership = await upsertMembership(req.user.id, record.orgId, { method: 'email', status: 'verified', workEmail: email });
  await notify(req.user.id, {
    type: 'org_verified',
    title: `You're verified at ${record.orgName}`,
    body: 'Your org badge is live — join your org events and battles.',
    data: { orgId: record.orgId },
  });
  res.json({ membership: { ...membership, orgName: record.orgName } });
});

/** POST /events/orgs/invite { code } — colleges / companies without official email. */
router.post('/orgs/invite', verifyLimiter, async (req, res) => {
  const { code } = validate(z.object({ code: z.string().trim().toUpperCase().min(4).max(24) }), req.body);
  const org = await queryOne(`SELECT id, name FROM orgs WHERE upper(invite_code) = $1`, [code]);
  if (!org) throw badRequest('That invite code is not valid');
  const membership = await upsertMembership(req.user.id, org.id, { method: 'invite_code', status: 'verified' });
  await notify(req.user.id, {
    type: 'org_verified',
    title: `You're verified at ${org.name}`,
    body: 'Your org badge is live — join your org events and battles.',
    data: { orgId: org.id },
  });
  res.json({ membership: { ...membership, orgName: org.name } });
});

/** POST /events/orgs/id-upload { orgId, idProofUrl, department? } — pending until a FitKey admin approves. */
router.post('/orgs/id-upload', verifyLimiter, async (req, res) => {
  const { orgId, idProofUrl, department } = validate(
    z.object({ orgId: uuidSchema, idProofUrl: urlSchema, department: z.string().trim().max(80).optional() }),
    req.body,
  );
  const org = await queryOne(`SELECT id, name FROM orgs WHERE id = $1`, [orgId]);
  if (!org) throw notFound('Org not found');
  const existing = await queryOne(`SELECT status FROM org_memberships WHERE org_id = $1 AND user_id = $2`, [orgId, req.user.id]);
  if (existing?.status === 'verified') return res.json({ membership: { ...existing, orgId, orgName: org.name } });
  const membership = await upsertMembership(req.user.id, orgId, {
    method: 'id_upload',
    status: 'pending',
    idProofUrl,
    department: department ?? null,
  });
  res.status(201).json({ membership: { ...membership, orgName: org.name } });
});

/** GET /events?scope=all|org|open&status=live|upcoming|past|any&kind=&q= */
router.get('/', async (req, res) => {
  res.json(await listEvents(req.user.id, validate(listQuerySchema, req.query)));
});

/** GET /events/:id?city=&orgId= — event + its own leaderboard (+ team ranking for battles) + whether I can join. */
router.get('/:id', async (req, res) => {
  const { city, orgId } = validate(
    z.object({ city: z.string().trim().min(1).max(80).optional(), orgId: uuidSchema.optional() }),
    req.query,
  );
  res.json(await eventDetail(req.params.id, req.user.id, { city, orgId }));
});

/** POST /events/:id/join { orgId? } — 403 with details.reason = org_verification when org proof is needed. */
router.post('/:id/join', async (req, res) => {
  const { orgId } = validate(z.object({ orgId: uuidSchema.optional() }), req.body ?? {});
  const r = await joinEvent(req.params.id, req.user.id, { orgId });
  res.status(r.already ? 200 : 201).json({ joined: true });
});

/** DELETE /events/:id/join — leave an event that hasn't ended. */
router.delete('/:id/join', async (req, res) => {
  const row = await loadEvent(req.params.id, req.user.id);
  if (row.status === 'past') throw forbidden('This event has ended');
  if (row.attendedAt || row.myAttendedAt) throw badRequest('Attendance is already recorded for this event');
  await query(`DELETE FROM contest_participants WHERE contest_id = $1 AND user_id = $2`, [row.id, req.user.id]);
  res.json({ joined: false });
});

export default router;

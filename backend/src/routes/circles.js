import crypto from 'node:crypto';
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, conflict, forbidden, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { uuidSchema, timeSchema, dateSchema } from '../utils/schemas.js';

/**
 * Circles (BRD §3.3): recurring local fitness groups (park yoga, morning walk, laughter club).
 *
 * Attendance: the leader prints / shares a QR poster whose payload is `FITKEY-CIRCLE:<jwt>` signed with
 * CHECKIN_SECRET ({typ:'circle', cid, v}). It does not expire (it is printed) — the leader rotates it (v + 1) to kill a
 * leaked poster. Members can also tap "I'm here" (GPS within GPS_RADIUS_M of the circle's pin). The leader can mark
 * anyone, including offline members without a phone. One attendance per person per session day, only on scheduled days
 * (or a special-session day) inside [start − EARLY_MIN, end + LATE_MIN] in APP_TZ.
 *
 * There is no cron: "missed 2 sessions in a row" family alerts are computed lazily whenever the member's stats are
 * computed (their own Circles view, a child's Family view, the leader's member list) and de-duplicated per run of misses.
 */
const router = Router();
router.use(requireAuth('user'));

export const CIRCLE_QR_PREFIX = 'FITKEY-CIRCLE:';
const ACTIVITIES = ['yoga', 'walk', 'laughter', 'running', 'dance', 'meditation', 'exercise', 'cycling', 'other'];
const SPECIAL_KINDS = ['special', 'festival', 'yoga_day', 'health_camp'];
const EARLY_MIN = 30;
const LATE_MIN = 60;
const GPS_RADIUS_M = 300;
const HISTORY_DAYS = 400;
const MAX_LED = 10;
const DAY_NAMES = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

const attendLimiter = rateLimit({
  windowMs: 10 * 60 * 1000,
  limit: 30,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.user.id,
  message: { error: 'Too many attempts — please wait a few minutes' },
});

// ---------------------------------------------------------------------------
// Time helpers (all session logic runs in APP_TZ)
// ---------------------------------------------------------------------------

function localNow() {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-CA', {
      timeZone: config.tz,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23',
    })
      .formatToParts(new Date())
      .map((p) => [p.type, p.value]),
  );
  return { date: `${parts.year}-${parts.month}-${parts.day}`, minutes: Number(parts.hour) * 60 + Number(parts.minute) };
}

const toMin = (t) => {
  const [h, m] = String(t).split(':').map(Number);
  return h * 60 + m;
};
const hhmm = (t) => (t == null ? null : String(t).slice(0, 5));
const fmtMin = (m) => {
  const h = Math.floor(m / 60) % 24;
  const mm = String(m % 60).padStart(2, '0');
  return `${h % 12 === 0 ? 12 : h % 12}:${mm} ${h < 12 ? 'AM' : 'PM'}`;
};
const isoDow = (date) => {
  const d = new Date(`${date}T00:00:00Z`).getUTCDay();
  return d === 0 ? 7 : d;
};
const addDays = (date, n) => {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
const monthStart = (date) => `${date.slice(0, 7)}-01`;
const prevMonthRange = (date) => {
  const end = addDays(monthStart(date), -1);
  return { start: monthStart(end), end };
};

/** The session held on `date`, or null. Specials replace (or add) the day's session. */
function sessionOn(circle, date, specialsByDate) {
  const sp = specialsByDate?.get(date);
  if (sp) {
    return {
      start: toMin(sp.startTime ?? circle.startTime),
      end: toMin(sp.endTime ?? circle.endTime),
      special: { id: sp.id, title: sp.title, kind: sp.kind },
    };
  }
  if (circle.days.includes(isoDow(date))) return { start: toMin(circle.startTime), end: toMin(circle.endTime), special: null };
  return null;
}

/** 'due' (finished), 'open' (attendance window open now), 'upcoming' (later today or in the future). */
function sessionStatus(session, date, now) {
  if (date < now.date) return 'due';
  if (date > now.date) return 'upcoming';
  if (now.minutes > session.end + LATE_MIN) return 'due';
  if (now.minutes >= session.start - EARLY_MIN) return 'open';
  return 'upcoming';
}

function specialsMap(specials) {
  const m = new Map();
  for (const s of specials) m.set(s.sessionDate, s);
  return m;
}

/**
 * Streak = consecutive scheduled sessions attended, newest first (today's session doesn't break it until it's over).
 * missedInRow = consecutive finished sessions missed, newest first.
 */
function computeStats(circle, spMap, since, attended, now) {
  let streak = 0;
  let missedInRow = 0;
  let missRunStart = null;
  let phase = 'start'; // start → streak | miss → done
  let monthCount = 0;
  let monthSessions = 0;
  const mStart = monthStart(now.date);
  let d = now.date;
  for (let i = 0; i < HISTORY_DAYS && d >= since; i += 1, d = addDays(d, -1)) {
    const s = sessionOn(circle, d, spMap);
    if (!s) continue;
    const status = sessionStatus(s, d, now);
    const was = attended.has(d);
    if (d >= mStart && (status !== 'upcoming' || was)) {
      monthSessions += 1;
      if (was) monthCount += 1;
    }
    if (phase === 'done') continue;
    if (!was && status !== 'due') continue; // today's session not over yet
    if (phase === 'start') phase = was ? 'streak' : 'miss';
    if (phase === 'streak') {
      if (was) streak += 1;
      else phase = 'done';
    } else if (phase === 'miss') {
      if (!was) {
        missedInRow += 1;
        missRunStart = d;
      } else phase = 'done';
    }
  }
  const lastAttended = [...attended].sort().pop() ?? null;
  return { streak, missedInRow, missRunStart, monthCount, monthSessions, lastAttended, attendedToday: attended.has(now.date) };
}

/** Next session from today (within two weeks), with its status. */
function nextSession(circle, spMap, now) {
  for (let i = 0; i < 15; i += 1) {
    const d = addDays(now.date, i);
    const s = sessionOn(circle, d, spMap);
    if (!s) continue;
    const status = sessionStatus(s, d, now);
    if (status === 'due') continue;
    return { date: d, startTime: fmtHH(s.start), endTime: fmtHH(s.end), status, special: s.special };
  }
  return null;
}
const fmtHH = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;

function scheduleText(circle) {
  const days = [...circle.days].sort((a, b) => a - b);
  const d =
    days.length === 7
      ? 'daily'
      : days.join(',') === '1,2,3,4,5'
        ? 'Mon–Fri'
        : days.join(',') === '6,7'
          ? 'weekends'
          : days.map((x) => DAY_NAMES[x]).join(', ');
  return `${fmtMin(toMin(circle.startTime))}–${fmtMin(toMin(circle.endTime))} ${d}`;
}

// ---------------------------------------------------------------------------
// Data helpers
// ---------------------------------------------------------------------------

const CIRCLE_COLS = `c.id, c.leader_id, c.name, c.activity, c.description, c.place_name, c.area, c.city, c.lat, c.lng,
  c.days, c.start_time, c.end_time, c.invite_code, c.qr_version, c.status, c.created_at,
  (c.created_at AT TIME ZONE '${config.tz.replace(/'/g, '')}')::date AS created_on,
  u.name AS leader_name, u.avatar_url AS leader_avatar_url,
  (SELECT COUNT(*) FROM circle_members cm WHERE cm.circle_id = c.id) AS member_count,
  (SELECT COUNT(*) FROM circle_offline_members o WHERE o.circle_id = c.id AND o.active) AS offline_count`;

function publicCircle(c, { includeCode = false } = {}) {
  return {
    id: c.id,
    leaderId: c.leaderId,
    leaderName: c.leaderName,
    leaderAvatarUrl: c.leaderAvatarUrl,
    name: c.name,
    activity: c.activity,
    description: c.description,
    placeName: c.placeName,
    area: c.area,
    city: c.city,
    lat: c.lat,
    lng: c.lng,
    days: [...c.days].sort((a, b) => a - b),
    startTime: hhmm(c.startTime),
    endTime: hhmm(c.endTime),
    schedule: scheduleText(c),
    memberCount: c.memberCount,
    offlineCount: c.offlineCount,
    status: c.status,
    ...(c.distanceKm !== undefined ? { distanceKm: c.distanceKm == null ? null : Math.round(c.distanceKm * 10) / 10 } : {}),
    ...(c.joined !== undefined ? { joined: c.joined } : {}),
    ...(includeCode ? { inviteCode: c.inviteCode } : {}),
  };
}

async function loadCircle(id, client) {
  const c = await queryOne(`SELECT ${CIRCLE_COLS} FROM circles c JOIN users u ON u.id = c.leader_id WHERE c.id = $1`, [id], client);
  if (!c || c.status !== 'active') throw notFound('Circle not found');
  return c;
}

async function membership(circleId, userId, client) {
  return queryOne(
    `SELECT role, (joined_at AT TIME ZONE $3)::date AS joined_on FROM circle_members WHERE circle_id = $1 AND user_id = $2`,
    [circleId, userId, config.tz],
    client,
  );
}

async function requireLeader(circleId, userId) {
  const c = await loadCircle(circleId);
  if (c.leaderId !== userId) throw forbidden('Only the circle leader can do this');
  return c;
}

async function circleSpecials(circleIds) {
  if (!circleIds.length) return new Map();
  const rows = await query(
    `SELECT id, circle_id, title, kind, session_date, start_time, end_time FROM circle_specials WHERE circle_id = ANY($1::uuid[])`,
    [circleIds],
  );
  const byCircle = new Map();
  for (const r of rows) {
    if (!byCircle.has(r.circleId)) byCircle.set(r.circleId, []);
    byCircle.get(r.circleId).push(r);
  }
  return new Map([...circleIds].map((id) => [id, specialsMap(byCircle.get(id) ?? [])]));
}

/** Stats for one user in each of the given circles (circle rows must include joinedOn). */
async function userStats(userId, circles, now) {
  if (!circles.length) return new Map();
  const ids = circles.map((c) => c.id);
  const [sp, att] = await Promise.all([
    circleSpecials(ids),
    query(
      `SELECT circle_id, session_date FROM circle_attendance
       WHERE user_id = $1 AND circle_id = ANY($2::uuid[]) AND session_date >= $3::date`,
      [userId, ids, addDays(now.date, -HISTORY_DAYS)],
    ),
  ]);
  const attended = new Map(ids.map((id) => [id, new Set()]));
  for (const a of att) attended.get(a.circleId).add(a.sessionDate);
  return new Map(
    circles.map((c) => {
      const since = c.joinedOn && c.joinedOn > c.createdOn ? c.joinedOn : c.createdOn;
      return [c.id, { ...computeStats(c, sp.get(c.id), since, attended.get(c.id), now), next: nextSession(c, sp.get(c.id), now) }];
    }),
  );
}

async function familyChildren(parentId) {
  return query(`SELECT child_id FROM circle_family_links WHERE parent_id = $1`, [parentId]);
}

async function displayName(userId) {
  const u = await queryOne(`SELECT name FROM users WHERE id = $1`, [userId]);
  return u?.name || 'Your family member';
}

/** Sends the one-per-run "missed 2 sessions in a row" alert to a member's family. */
async function maybeMissAlert(userId, circle, stats) {
  if (stats.missedInRow < 2 || !stats.missRunStart) return;
  const children = await familyChildren(userId);
  if (!children.length) return;
  const row = await queryOne(
    `INSERT INTO circle_miss_alerts (user_id, circle_id, run_start) VALUES ($1, $2, $3)
     ON CONFLICT DO NOTHING RETURNING run_start`,
    [userId, circle.id, stats.missRunStart],
  );
  if (!row) return;
  const name = await displayName(userId);
  for (const ch of children) {
    await notify(ch.childId, {
      type: 'circle_family_missed',
      title: `${name} missed ${stats.missedInRow} sessions of ${circle.name} in a row`,
      body: 'A quick call or a walk together can help them get back into the routine.',
      data: { circleId: circle.id },
    });
  }
}

/** Tells a member's family they attended. */
async function familyAttended(userId, circle) {
  const children = await familyChildren(userId);
  if (!children.length) return;
  const now = localNow();
  const m = await membership(circle.id, userId);
  const stats = (await userStats(userId, [{ ...circle, joinedOn: m?.joinedOn }], now)).get(circle.id);
  const name = await displayName(userId);
  for (const ch of children) {
    await notify(ch.childId, {
      type: 'circle_family_attended',
      title: `${name} attended ${circle.name} today`,
      body: stats.streak > 1 ? `${stats.streak} sessions in a row — keep cheering them on!` : 'Their streak has started again.',
      data: { circleId: circle.id },
    });
  }
}

function todayState(circle, spMap, now) {
  const s = sessionOn(circle, now.date, spMap);
  if (!s) return { isSessionDay: false, status: 'none', opensAt: null, closesAt: null, special: null };
  const status = sessionStatus(s, now.date, now);
  return {
    isSessionDay: true,
    status: status === 'due' ? 'over' : status,
    startTime: fmtHH(s.start),
    endTime: fmtHH(s.end),
    opensAt: fmtHH(Math.max(0, s.start - EARLY_MIN)),
    closesAt: fmtHH(Math.min(24 * 60 - 1, s.end + LATE_MIN)),
    special: s.special,
  };
}

function haversineSql(latP, lngP) {
  return `(6371 * 2 * ASIN(SQRT(POWER(SIN(RADIANS(c.lat - ${latP}) / 2), 2) +
          COS(RADIANS(${latP})) * COS(RADIANS(c.lat)) * POWER(SIN(RADIANS(c.lng - ${lngP}) / 2), 2))))`;
}

function distanceM(lat1, lng1, lat2, lng2) {
  const r = (x) => (x * Math.PI) / 180;
  const a = Math.sin(r(lat2 - lat1) / 2) ** 2 + Math.cos(r(lat1)) * Math.cos(r(lat2)) * Math.sin(r(lng2 - lng1) / 2) ** 2;
  return 6371000 * 2 * Math.asin(Math.sqrt(a));
}

const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const randomCode = (n = 6) => Array.from({ length: n }, () => CODE_ALPHABET[crypto.randomInt(CODE_ALPHABET.length)]).join('');

/** Circle vs Circle: average attendance rate in [start, end] for every active circle of a city. */
async function cityBoard(city, start, end) {
  const rows = await query(
    `SELECT c.id, c.name, c.area, c.city, c.activity, c.place_name,
       (SELECT COUNT(*) FROM circle_members cm WHERE cm.circle_id = c.id)
         + (SELECT COUNT(*) FROM circle_offline_members o WHERE o.circle_id = c.id AND o.active) AS headcount,
       (SELECT COUNT(*) FROM circle_attendance a WHERE a.circle_id = c.id AND a.session_date BETWEEN $2::date AND $3::date) AS attendances,
       (SELECT COUNT(*) FROM generate_series(GREATEST($2::date, (c.created_at AT TIME ZONE $4)::date), $3::date, interval '1 day') g(d)
          WHERE EXTRACT(ISODOW FROM g.d)::smallint = ANY(c.days)
             OR g.d::date IN (SELECT sp.session_date FROM circle_specials sp WHERE sp.circle_id = c.id)) AS sessions
     FROM circles c
     WHERE c.status = 'active' AND ($1::text IS NULL OR lower(c.city) = lower($1::text))`,
    [city ?? null, start, end, config.tz],
  );
  const scored = rows
    .map((r) => {
      const possible = r.sessions * r.headcount;
      return {
        circleId: r.id,
        name: r.name,
        area: r.area,
        city: r.city,
        activity: r.activity,
        placeName: r.placeName,
        members: r.headcount,
        sessions: r.sessions,
        attendances: r.attendances,
        rate: possible > 0 ? Math.min(1, r.attendances / possible) : 0,
      };
    })
    .filter((r) => r.sessions > 0 && r.members > 0)
    .sort((a, b) => b.rate - a.rate || b.attendances - a.attendances || a.name.localeCompare(b.name));
  scored.forEach((r, i) => {
    r.rank = i + 1;
    r.rate = Math.round(r.rate * 1000) / 1000;
  });
  return scored;
}

async function mostRegular(circleId, start, end) {
  return queryOne(
    `SELECT COALESCE(u.name, o.name, 'Member') AS name, u.avatar_url, a.user_id, a.offline_member_id, COUNT(*) AS sessions
     FROM circle_attendance a
     LEFT JOIN users u ON u.id = a.user_id
     LEFT JOIN circle_offline_members o ON o.id = a.offline_member_id
     WHERE a.circle_id = $1 AND a.session_date BETWEEN $2::date AND $3::date
     GROUP BY 1, 2, 3, 4 ORDER BY sessions DESC, MIN(a.created_at) ASC LIMIT 1`,
    [circleId, start, end],
  );
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

const optText = (max) =>
  z
    .string()
    .trim()
    .max(max)
    .nullish()
    .transform((s) => (s ? s : null));

const circleFields = {
  name: z.string().trim().min(3, 'Name is too short').max(120),
  activity: z.enum(ACTIVITIES),
  description: optText(600),
  placeName: z.string().trim().min(2, 'Add the park or society').max(160),
  area: optText(120),
  city: z.string().trim().min(2, 'Add the city').max(80),
  lat: z.number().min(-90).max(90).nullish(),
  lng: z.number().min(-180).max(180).nullish(),
  days: z
    .array(z.number().int().min(1).max(7))
    .min(1, 'Pick at least one day')
    .max(7)
    .transform((d) => [...new Set(d)].sort()),
  startTime: timeSchema,
  endTime: timeSchema,
};

function checkTiming(start, end, lat, lng) {
  if (toMin(end) <= toMin(start)) throw badRequest('End time must be after the start time');
  if (toMin(end) - toMin(start) > 6 * 60) throw badRequest('A session can be at most 6 hours long');
  if ((lat == null) !== (lng == null)) throw badRequest('Send both lat and lng for the map pin');
}

const idParam = (req) => validate(uuidSchema, req.params.id);

// ---------------------------------------------------------------------------
// Lists
// ---------------------------------------------------------------------------

/** GET /circles/mine — circles I lead or belong to, with my streak and the next session. */
router.get('/mine', async (req, res) => {
  const now = localNow();
  const rows = await query(
    `SELECT ${CIRCLE_COLS}, m.role, (m.joined_at AT TIME ZONE $2)::date AS joined_on
     FROM circle_members m JOIN circles c ON c.id = m.circle_id JOIN users u ON u.id = c.leader_id
     WHERE m.user_id = $1 AND c.status = 'active' ORDER BY m.joined_at DESC`,
    [req.user.id, config.tz],
  );
  const stats = await userStats(req.user.id, rows, now);
  for (const c of rows) await maybeMissAlert(req.user.id, c, stats.get(c.id));
  res.json({
    circles: rows.map((c) => {
      const s = stats.get(c.id);
      return {
        ...publicCircle(c, { includeCode: true }),
        joined: true,
        isLeader: c.leaderId === req.user.id,
        streak: s.streak,
        attendedToday: s.attendedToday,
        monthCount: s.monthCount,
        monthSessions: s.monthSessions,
        nextSession: s.next,
      };
    }),
  });
});

/**
 * GET /circles/nearby?lat&lng&radiusKm&city&q — "Circles near me". With lat/lng: Haversine distance sort within radius.
 * Without (permission denied / web): circles in `city` (defaults to the member's profile city).
 */
router.get('/nearby', async (req, res) => {
  const p = validate(
    z.object({
      lat: z.coerce.number().min(-90).max(90).optional(),
      lng: z.coerce.number().min(-180).max(180).optional(),
      radiusKm: z.coerce.number().min(1).max(200).default(25),
      city: z.string().trim().max(80).optional(),
      q: z.string().trim().max(80).optional(),
    }),
    req.query,
  );
  const hasLoc = p.lat !== undefined && p.lng !== undefined;
  let city = p.city || null;
  if (!hasLoc && !city) city = (await queryOne(`SELECT city FROM users WHERE id = $1`, [req.user.id]))?.city ?? null;

  const params = [req.user.id, p.q ? `%${p.q}%` : null];
  let distance = 'NULL::float8';
  let where = '';
  if (hasLoc) {
    params.push(p.lat, p.lng, p.radiusKm);
    distance = haversineSql('$3::float8', '$4::float8');
    where = `AND c.lat IS NOT NULL AND ${distance} <= $5::float8`;
  } else if (city) {
    params.push(city);
    where = `AND lower(c.city) = lower($3::text)`;
  }
  const rows = await query(
    `SELECT ${CIRCLE_COLS}, ${distance} AS distance_km,
       EXISTS (SELECT 1 FROM circle_members m WHERE m.circle_id = c.id AND m.user_id = $1) AS joined
     FROM circles c JOIN users u ON u.id = c.leader_id
     WHERE c.status = 'active' ${where}
       AND ($2::text IS NULL OR c.name ILIKE $2 OR c.area ILIKE $2 OR c.place_name ILIKE $2 OR c.city ILIKE $2)
     ORDER BY distance_km ASC NULLS LAST, member_count DESC, c.created_at DESC LIMIT 50`,
    params,
  );
  res.json({ mode: hasLoc ? 'location' : city ? 'city' : 'all', city, circles: rows.map((c) => publicCircle(c)) });
});

/** GET /circles/leaderboard?city — Circle vs Circle (attendance rate this month) + last month's Circle of the month. */
router.get('/leaderboard', async (req, res) => {
  const { city: cityQ } = validate(z.object({ city: z.string().trim().max(80).optional() }), req.query);
  const city = cityQ || (await queryOne(`SELECT city FROM users WHERE id = $1`, [req.user.id]))?.city || null;
  const now = localNow();
  const prev = prevMonthRange(now.date);
  const [current, last] = await Promise.all([cityBoard(city, monthStart(now.date), now.date), cityBoard(city, prev.start, prev.end)]);
  res.json({
    city,
    month: now.date.slice(0, 7),
    entries: current.slice(0, 50),
    circleOfTheMonth: last[0] && last[0].attendances > 0 ? { ...last[0], month: prev.start.slice(0, 7) } : null,
  });
});

// ---------------------------------------------------------------------------
// Family link
// ---------------------------------------------------------------------------

async function familyCode(userId) {
  const existing = await queryOne(`SELECT code FROM circle_family_codes WHERE user_id = $1`, [userId]);
  if (existing) return existing.code;
  for (let i = 0; i < 5; i += 1) {
    const row = await queryOne(
      `INSERT INTO circle_family_codes (user_id, code) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING code`,
      [userId, `F${randomCode(7)}`],
    );
    if (row) return row.code;
    const again = await queryOne(`SELECT code FROM circle_family_codes WHERE user_id = $1`, [userId]);
    if (again) return again.code;
  }
  throw conflict('Could not create a family code, please try again');
}

/** GET /circles/family — my family code, the people I follow (with their circle streaks) and my followers. */
router.get('/family', async (req, res) => {
  const now = localNow();
  const code = await familyCode(req.user.id);
  const parents = await query(
    `SELECT u.id AS user_id, u.name, u.avatar_url, l.created_at AS linked_at
     FROM circle_family_links l JOIN users u ON u.id = l.parent_id WHERE l.child_id = $1 ORDER BY l.created_at`,
    [req.user.id],
  );
  const children = await query(
    `SELECT u.id AS user_id, u.name, u.avatar_url, l.created_at AS linked_at
     FROM circle_family_links l JOIN users u ON u.id = l.child_id WHERE l.parent_id = $1 ORDER BY l.created_at`,
    [req.user.id],
  );
  const following = [];
  for (const p of parents) {
    const circles = await query(
      `SELECT ${CIRCLE_COLS}, (m.joined_at AT TIME ZONE $2)::date AS joined_on
       FROM circle_members m JOIN circles c ON c.id = m.circle_id JOIN users u ON u.id = c.leader_id
       WHERE m.user_id = $1 AND c.status = 'active' ORDER BY m.joined_at`,
      [p.userId, config.tz],
    );
    const stats = await userStats(p.userId, circles, now);
    for (const c of circles) await maybeMissAlert(p.userId, c, stats.get(c.id));
    following.push({
      ...p,
      circles: circles.map((c) => {
        const s = stats.get(c.id);
        return {
          circleId: c.id,
          name: c.name,
          activity: c.activity,
          placeName: c.placeName,
          schedule: scheduleText(c),
          streak: s.streak,
          missedInRow: s.missedInRow,
          attendedToday: s.attendedToday,
          lastAttended: s.lastAttended,
          monthCount: s.monthCount,
          monthSessions: s.monthSessions,
        };
      }),
    });
  }
  res.json({ code, following, followers: children });
});

/** POST /circles/family/code/rotate — new family code (old one stops working; existing links stay). */
router.post('/family/code/rotate', async (req, res) => {
  for (let i = 0; i < 5; i += 1) {
    const row = await queryOne(
      `INSERT INTO circle_family_codes (user_id, code) VALUES ($1, $2)
       ON CONFLICT (user_id) DO UPDATE SET code = EXCLUDED.code, created_at = now() RETURNING code`,
      [req.user.id, `F${randomCode(7)}`],
    ).catch((e) => (e.code === '23505' ? null : Promise.reject(e)));
    if (row) return res.json({ code: row.code });
  }
  throw conflict('Could not create a family code, please try again');
});

/** POST /circles/family/link { code } — follow the parent who shared this code. */
router.post('/family/link', async (req, res) => {
  const { code } = validate(z.object({ code: z.string().trim().min(4).max(12).transform((s) => s.toUpperCase()) }), req.body);
  const owner = await queryOne(`SELECT user_id FROM circle_family_codes WHERE code = $1`, [code]);
  if (!owner) throw notFound('No one has this family code — check it and try again');
  if (owner.userId === req.user.id) throw badRequest("That's your own family code — share it with your family instead");
  const row = await queryOne(
    `INSERT INTO circle_family_links (parent_id, child_id) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING parent_id`,
    [owner.userId, req.user.id],
  );
  if (!row) throw conflict('You already follow this family member');
  const childName = (await queryOne(`SELECT name FROM users WHERE id = $1`, [req.user.id]))?.name || 'A family member';
  await notify(owner.userId, {
    type: 'circle_family_linked',
    title: `${childName} now follows your Circle streaks`,
    body: 'They will get an update when you attend, or if you miss two sessions in a row.',
    data: {},
  });
  res.status(201).json({ linked: true, parentId: owner.userId });
});

/** DELETE /circles/family/:userId — unlink (works from either side). */
router.delete('/family/:userId', async (req, res) => {
  const other = validate(uuidSchema, req.params.userId);
  const rows = await query(
    `DELETE FROM circle_family_links WHERE (parent_id = $1 AND child_id = $2) OR (parent_id = $2 AND child_id = $1) RETURNING parent_id`,
    [req.user.id, other],
  );
  if (!rows.length) throw notFound('Link not found');
  res.json({ removed: true });
});

// ---------------------------------------------------------------------------
// Create / join
// ---------------------------------------------------------------------------

/** POST /circles — create a circle; the creator becomes its leader. */
router.post('/', async (req, res) => {
  const body = validate(z.object(circleFields), req.body);
  checkTiming(body.startTime, body.endTime, body.lat, body.lng);
  const led = await queryOne(`SELECT COUNT(*) AS n FROM circles WHERE leader_id = $1 AND status = 'active'`, [req.user.id]);
  if (led.n >= MAX_LED) throw badRequest(`You can lead up to ${MAX_LED} circles`);

  const id = await withTransaction(async (client) => {
    let row = null;
    for (let i = 0; i < 5 && !row; i += 1) {
      row = await queryOne(
        `INSERT INTO circles (leader_id, name, activity, description, place_name, area, city, lat, lng, days, start_time, end_time, invite_code)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::smallint[], $11, $12, $13)
         ON CONFLICT (invite_code) DO NOTHING RETURNING id`,
        [
          req.user.id,
          body.name,
          body.activity,
          body.description,
          body.placeName,
          body.area,
          body.city,
          body.lat ?? null,
          body.lng ?? null,
          body.days,
          body.startTime,
          body.endTime,
          randomCode(6),
        ],
        client,
      );
    }
    if (!row) throw conflict('Could not create an invite code, please try again');
    await query(`INSERT INTO circle_members (circle_id, user_id, role) VALUES ($1, $2, 'leader')`, [row.id, req.user.id], client);
    return row.id;
  });
  const c = await loadCircle(id);
  res.status(201).json({ circle: publicCircle(c, { includeCode: true }) });
});

async function joinCircle(circle, userId) {
  const row = await queryOne(
    `INSERT INTO circle_members (circle_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING circle_id`,
    [circle.id, userId],
  );
  if (row && circle.leaderId !== userId) {
    const name = (await queryOne(`SELECT name FROM users WHERE id = $1`, [userId]))?.name || 'A new member';
    await notify(circle.leaderId, {
      type: 'circle_join',
      title: `${name} joined ${circle.name}`,
      body: 'Say hello in the circle chat.',
      data: { circleId: circle.id },
    });
  }
  return !!row;
}

/** POST /circles/join { code } — join with the leader's invite code (from the WhatsApp invite). */
router.post('/join', async (req, res) => {
  const { code } = validate(z.object({ code: z.string().trim().min(4).max(12).transform((s) => s.toUpperCase()) }), req.body);
  const found = await queryOne(`SELECT id FROM circles WHERE invite_code = $1 AND status = 'active'`, [code]);
  if (!found) throw notFound('No circle has this invite code — check it and try again');
  const circle = await loadCircle(found.id);
  const joined = await joinCircle(circle, req.user.id);
  res.status(joined ? 201 : 200).json({ circleId: circle.id, joined: true, alreadyMember: !joined });
});

/** POST /circles/attend { qr } — scan the circle's QR poster. Joins the circle if needed, then marks today. */
router.post('/attend', attendLimiter, async (req, res) => {
  const { qr } = validate(z.object({ qr: z.string().min(10).max(2000) }), req.body);
  if (!qr.startsWith(CIRCLE_QR_PREFIX)) throw badRequest("That's not a FITKEY Circle QR code");
  let payload;
  try {
    payload = jwt.verify(qr.slice(CIRCLE_QR_PREFIX.length), config.checkinSecret);
    if (payload.typ !== 'circle') throw new Error('wrong type');
  } catch {
    throw badRequest('This QR code is not valid. Ask your circle leader for the latest poster.');
  }
  const circle = await loadCircle(payload.cid).catch(() => {
    throw badRequest('This circle is no longer active');
  });
  if (payload.v !== circle.qrVersion) throw badRequest('This poster has been replaced. Ask your circle leader for the new one.');
  const joinedNow = await joinCircle(circle, req.user.id);
  const result = await markSelf(circle, req.user.id, 'qr');
  res.status(201).json({ ...result, joinedNow });
});

// ---------------------------------------------------------------------------
// Specials RSVP (before /:id routes)
// ---------------------------------------------------------------------------

/** POST /circles/specials/:sid/rsvp { going } */
router.post('/specials/:sid/rsvp', async (req, res) => {
  const sid = validate(uuidSchema, req.params.sid);
  const { going } = validate(z.object({ going: z.boolean() }), req.body);
  const sp = await queryOne(`SELECT id, circle_id, session_date FROM circle_specials WHERE id = $1`, [sid]);
  if (!sp) throw notFound('Special session not found');
  if (!(await membership(sp.circleId, req.user.id))) throw forbidden('Join the circle to RSVP');
  if (going) {
    if (sp.sessionDate < localNow().date) throw badRequest('This special session is over');
    await query(`INSERT INTO circle_special_rsvps (special_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [sid, req.user.id]);
  } else {
    await query(`DELETE FROM circle_special_rsvps WHERE special_id = $1 AND user_id = $2`, [sid, req.user.id]);
  }
  const { n } = await queryOne(`SELECT COUNT(*) AS n FROM circle_special_rsvps WHERE special_id = $1`, [sid]);
  res.json({ going, rsvpCount: n });
});

// ---------------------------------------------------------------------------
// One circle
// ---------------------------------------------------------------------------

/** GET /circles/:id — detail, today's session state, my stats, specials, most regular member, city rank. */
router.get('/:id', async (req, res) => {
  const id = idParam(req);
  const now = localNow();
  const c = await loadCircle(id);
  const m = await membership(id, req.user.id);
  const isLeader = c.leaderId === req.user.id;
  const sp = (await circleSpecials([id])).get(id);

  let me = null;
  if (m) {
    const s = (await userStats(req.user.id, [{ ...c, joinedOn: m.joinedOn }], now)).get(id);
    await maybeMissAlert(req.user.id, c, s);
    me = {
      streak: s.streak,
      missedInRow: s.missedInRow,
      attendedToday: s.attendedToday,
      monthCount: s.monthCount,
      monthSessions: s.monthSessions,
      lastAttended: s.lastAttended,
    };
  }

  const prev = prevMonthRange(now.date);
  const [specials, todayCount, regularNow, regularLast, board, lastBoard] = await Promise.all([
    query(
      `SELECT s.id, s.title, s.kind, s.session_date, s.start_time, s.end_time, s.note,
         (SELECT COUNT(*) FROM circle_special_rsvps r WHERE r.special_id = s.id) AS rsvp_count,
         EXISTS (SELECT 1 FROM circle_special_rsvps r WHERE r.special_id = s.id AND r.user_id = $2) AS going
       FROM circle_specials s WHERE s.circle_id = $1 AND s.session_date >= $3::date ORDER BY s.session_date LIMIT 20`,
      [id, req.user.id, now.date],
    ),
    queryOne(`SELECT COUNT(*) AS n FROM circle_attendance WHERE circle_id = $1 AND session_date = $2::date`, [id, now.date]),
    mostRegular(id, monthStart(now.date), now.date),
    mostRegular(id, prev.start, prev.end),
    cityBoard(c.city, monthStart(now.date), now.date),
    cityBoard(c.city, prev.start, prev.end),
  ]);
  const mine = board.find((b) => b.circleId === id);
  res.json({
    circle: { ...publicCircle(c, { includeCode: !!m }), joined: !!m, isLeader },
    today: { ...todayState(c, sp, now), attendeeCount: todayCount.n },
    nextSession: nextSession(c, sp, now),
    me,
    specials: specials.map((s) => ({ ...s, startTime: hhmm(s.startTime), endTime: hhmm(s.endTime) })),
    mostRegular: { thisMonth: regularNow, lastMonth: regularLast },
    cityRank: mine ? { rank: mine.rank, total: board.length, rate: mine.rate, city: c.city } : null,
    circleOfTheMonth: !!(lastBoard[0] && lastBoard[0].circleId === id && lastBoard[0].attendances > 0),
  });
});

/** PATCH /circles/:id — leader edits the circle. */
router.patch('/:id', async (req, res) => {
  const id = idParam(req);
  const c = await requireLeader(id, req.user.id);
  const body = validate(z.object(circleFields).partial(), req.body);
  const merged = {
    startTime: body.startTime ?? hhmm(c.startTime),
    endTime: body.endTime ?? hhmm(c.endTime),
    lat: body.lat !== undefined ? body.lat : c.lat,
    lng: body.lng !== undefined ? body.lng : c.lng,
  };
  checkTiming(merged.startTime, merged.endTime, merged.lat, merged.lng);
  const cols = {
    name: 'name',
    activity: 'activity',
    description: 'description',
    placeName: 'place_name',
    area: 'area',
    city: 'city',
    lat: 'lat',
    lng: 'lng',
    days: 'days',
    startTime: 'start_time',
    endTime: 'end_time',
  };
  const sets = [];
  const params = [id];
  for (const [k, col] of Object.entries(cols)) {
    if (body[k] === undefined) continue;
    params.push(body[k]);
    sets.push(`${col} = $${params.length}${k === 'days' ? '::smallint[]' : ''}`);
  }
  if (sets.length) await query(`UPDATE circles SET ${sets.join(', ')} WHERE id = $1`, params);
  res.json({ circle: publicCircle(await loadCircle(id), { includeCode: true }) });
});

/** DELETE /circles/:id — leader closes the circle (archived; history kept). */
router.delete('/:id', async (req, res) => {
  const id = idParam(req);
  await requireLeader(id, req.user.id);
  await query(`UPDATE circles SET status = 'archived' WHERE id = $1`, [id]);
  res.json({ archived: true });
});

/** POST /circles/:id/join — join from "Circles near me". */
router.post('/:id/join', async (req, res) => {
  const circle = await loadCircle(idParam(req));
  const joined = await joinCircle(circle, req.user.id);
  res.status(joined ? 201 : 200).json({ joined: true, alreadyMember: !joined });
});

/** POST /circles/:id/leave */
router.post('/:id/leave', async (req, res) => {
  const circle = await loadCircle(idParam(req));
  if (circle.leaderId === req.user.id) throw badRequest('Leaders cannot leave their own circle — close it instead');
  await query(`DELETE FROM circle_members WHERE circle_id = $1 AND user_id = $2`, [circle.id, req.user.id]);
  res.json({ left: true });
});

/** GET /circles/:id/members — members (with streaks and today's status) and offline members. Members only. */
router.get('/:id/members', async (req, res) => {
  const id = idParam(req);
  const now = localNow();
  const c = await loadCircle(id);
  if (!(await membership(id, req.user.id))) throw forbidden('Join the circle to see its members');
  const [members, offline, att, spAll] = await Promise.all([
    query(
      `SELECT u.id AS user_id, u.name, u.avatar_url, m.role, (m.joined_at AT TIME ZONE $2)::date AS joined_on
       FROM circle_members m JOIN users u ON u.id = m.user_id WHERE m.circle_id = $1 ORDER BY m.role, u.name NULLS LAST`,
      [id, config.tz],
    ),
    query(
      `SELECT id, name, phone, (created_at AT TIME ZONE $2)::date AS joined_on
       FROM circle_offline_members WHERE circle_id = $1 AND active ORDER BY name`,
      [id, config.tz],
    ),
    query(
      `SELECT user_id, offline_member_id, session_date FROM circle_attendance WHERE circle_id = $1 AND session_date >= $2::date`,
      [id, addDays(now.date, -HISTORY_DAYS)],
    ),
    circleSpecials([id]),
  ]);
  const sp = spAll.get(id);
  const byPerson = new Map();
  for (const a of att) {
    const key = a.userId ?? `o:${a.offlineMemberId}`;
    if (!byPerson.has(key)) byPerson.set(key, new Set());
    byPerson.get(key).add(a.sessionDate);
  }
  const since = (joinedOn) => (joinedOn > c.createdOn ? joinedOn : c.createdOn);
  const isLeader = c.leaderId === req.user.id;
  const out = [];
  for (const m of members) {
    const s = computeStats(c, sp, since(m.joinedOn), byPerson.get(m.userId) ?? new Set(), now);
    if (isLeader) await maybeMissAlert(m.userId, c, s);
    out.push({
      userId: m.userId,
      name: m.name,
      avatarUrl: m.avatarUrl,
      role: m.role,
      streak: s.streak,
      attendedToday: s.attendedToday,
      monthCount: s.monthCount,
      monthSessions: s.monthSessions,
    });
  }
  res.json({
    today: todayState(c, sp, now),
    members: out,
    offlineMembers: offline.map((o) => {
      const s = computeStats(c, sp, since(o.joinedOn), byPerson.get(`o:${o.id}`) ?? new Set(), now);
      return {
        id: o.id,
        name: o.name,
        phone: isLeader ? o.phone : null,
        streak: s.streak,
        attendedToday: s.attendedToday,
        monthCount: s.monthCount,
        monthSessions: s.monthSessions,
      };
    }),
  });
});

/** DELETE /circles/:id/members/:userId — leader removes a member. */
router.delete('/:id/members/:userId', async (req, res) => {
  const id = idParam(req);
  const userId = validate(uuidSchema, req.params.userId);
  const c = await requireLeader(id, req.user.id);
  if (userId === c.leaderId) throw badRequest('You cannot remove yourself');
  const rows = await query(`DELETE FROM circle_members WHERE circle_id = $1 AND user_id = $2 RETURNING user_id`, [id, userId]);
  if (!rows.length) throw notFound('Member not found');
  res.json({ removed: true });
});

/** POST /circles/:id/offline-members { name, phone? } — leader adds a member without a smartphone. */
router.post('/:id/offline-members', async (req, res) => {
  const id = idParam(req);
  await requireLeader(id, req.user.id);
  const body = validate(
    z.object({
      name: z.string().trim().min(2, 'Enter a name').max(80),
      phone: z
        .string()
        .trim()
        .max(16)
        .nullish()
        .transform((s) => (s ? s.replace(/[\s-]/g, '') : null))
        .refine((s) => s == null || /^\+?\d{10,15}$/.test(s), 'Enter a valid phone number'),
    }),
    req.body,
  );
  const { n } = await queryOne(`SELECT COUNT(*) AS n FROM circle_offline_members WHERE circle_id = $1 AND active`, [id]);
  if (n >= 200) throw badRequest('This circle already has 200 offline members');
  const row = await queryOne(
    `INSERT INTO circle_offline_members (circle_id, name, phone) VALUES ($1, $2, $3) RETURNING id, name, phone`,
    [id, body.name, body.phone],
  );
  res.status(201).json({ offlineMember: row });
});

/** DELETE /circles/:id/offline-members/:mid — leader removes an offline member (history kept). */
router.delete('/:id/offline-members/:mid', async (req, res) => {
  const id = idParam(req);
  const mid = validate(uuidSchema, req.params.mid);
  await requireLeader(id, req.user.id);
  const rows = await query(
    `UPDATE circle_offline_members SET active = false WHERE id = $1 AND circle_id = $2 AND active RETURNING id`,
    [mid, id],
  );
  if (!rows.length) throw notFound('Offline member not found');
  res.json({ removed: true });
});

/** Marks the member present today (self check-in), enforcing the schedule and time window. */
async function markSelf(circle, userId, method) {
  const now = localNow();
  const sp = (await circleSpecials([circle.id])).get(circle.id);
  const s = sessionOn(circle, now.date, sp);
  if (!s) throw badRequest(`No session today — ${circle.name} meets ${scheduleText(circle)}`);
  const status = sessionStatus(s, now.date, now);
  if (status === 'upcoming') throw badRequest(`Too early — attendance opens at ${fmtMin(Math.max(0, s.start - EARLY_MIN))}`);
  if (status === 'due') throw badRequest(`Today's session is over — attendance closed at ${fmtMin(s.end + LATE_MIN)}`);
  const row = await queryOne(
    `INSERT INTO circle_attendance (circle_id, user_id, session_date, method, marked_by)
     VALUES ($1, $2, $3::date, $4, $2)
     ON CONFLICT (circle_id, user_id, session_date) WHERE user_id IS NOT NULL DO NOTHING
     RETURNING id, session_date, method, created_at`,
    [circle.id, userId, now.date, method],
  );
  if (!row) throw conflict(`You are already marked present at ${circle.name} today`);
  await familyAttended(userId, circle);
  const m = await membership(circle.id, userId);
  const stats = (await userStats(userId, [{ ...circle, joinedOn: m?.joinedOn }], now)).get(circle.id);
  return { attendance: row, circleId: circle.id, circleName: circle.name, streak: stats.streak };
}

/** POST /circles/:id/attend { lat, lng } — one-tap "I'm here" using the phone's location near the circle's pin. */
router.post('/:id/attend', attendLimiter, async (req, res) => {
  const circle = await loadCircle(idParam(req));
  const { lat, lng } = validate(z.object({ lat: z.number().min(-90).max(90), lng: z.number().min(-180).max(180) }), req.body);
  if (!(await membership(circle.id, req.user.id))) throw forbidden('Join the circle first');
  if (circle.lat == null || circle.lng == null) {
    throw badRequest('This circle has no map pin — scan the QR poster or ask your leader to mark you');
  }
  const meters = distanceM(lat, lng, circle.lat, circle.lng);
  if (meters > GPS_RADIUS_M) {
    throw badRequest(`You seem to be ${Math.round(meters)} m away from ${circle.placeName}. Scan the QR poster at the spot instead.`);
  }
  res.status(201).json(await markSelf(circle, req.user.id, 'gps'));
});

/** POST /circles/:id/attendance/mark { userId | offlineMemberId, present } — leader marks / unmarks today. */
router.post('/:id/attendance/mark', async (req, res) => {
  const id = idParam(req);
  const c = await requireLeader(id, req.user.id);
  const body = validate(
    z
      .object({ userId: uuidSchema.optional(), offlineMemberId: uuidSchema.optional(), present: z.boolean() })
      .refine((b) => !!b.userId !== !!b.offlineMemberId, 'Send exactly one of userId or offlineMemberId'),
    req.body,
  );
  const now = localNow();
  const sp = (await circleSpecials([id])).get(id);
  if (!sessionOn(c, now.date, sp)) throw badRequest(`No session today — ${c.name} meets ${scheduleText(c)}`);

  if (body.userId) {
    if (!(await membership(id, body.userId))) throw notFound('Member not found');
  } else {
    const o = await queryOne(`SELECT id FROM circle_offline_members WHERE id = $1 AND circle_id = $2 AND active`, [
      body.offlineMemberId,
      id,
    ]);
    if (!o) throw notFound('Offline member not found');
  }
  const col = body.userId ? 'user_id' : 'offline_member_id';
  const personId = body.userId ?? body.offlineMemberId;
  if (body.present) {
    const row = await queryOne(
      `INSERT INTO circle_attendance (circle_id, ${col}, session_date, method, marked_by)
       VALUES ($1, $2, $3::date, 'leader', $4)
       ON CONFLICT (circle_id, ${col}, session_date) WHERE ${col} IS NOT NULL DO NOTHING RETURNING id`,
      [id, personId, now.date, req.user.id],
    );
    if (row && body.userId) await familyAttended(body.userId, c);
  } else {
    await query(`DELETE FROM circle_attendance WHERE circle_id = $1 AND ${col} = $2 AND session_date = $3::date`, [
      id,
      personId,
      now.date,
    ]);
  }
  res.json({ present: body.present, date: now.date });
});

/** GET /circles/:id/qr — the leader's QR poster payload. */
router.get('/:id/qr', async (req, res) => {
  const c = await requireLeader(idParam(req), req.user.id);
  const token = jwt.sign({ typ: 'circle', cid: c.id, v: c.qrVersion }, config.checkinSecret);
  res.json({ qr: `${CIRCLE_QR_PREFIX}${token}`, version: c.qrVersion });
});

/** POST /circles/:id/qr/rotate — invalidate printed posters and issue a new one. */
router.post('/:id/qr/rotate', async (req, res) => {
  const c = await requireLeader(idParam(req), req.user.id);
  const { qrVersion } = await queryOne(`UPDATE circles SET qr_version = qr_version + 1 WHERE id = $1 RETURNING qr_version`, [c.id]);
  const token = jwt.sign({ typ: 'circle', cid: c.id, v: qrVersion }, config.checkinSecret);
  res.json({ qr: `${CIRCLE_QR_PREFIX}${token}`, version: qrVersion });
});

/** POST /circles/:id/specials — leader schedules a special session (Yoga Day, Diwali walk, health camp…). */
router.post('/:id/specials', async (req, res) => {
  const id = idParam(req);
  const c = await requireLeader(id, req.user.id);
  const body = validate(
    z.object({
      title: z.string().trim().min(3).max(120),
      kind: z.enum(SPECIAL_KINDS).default('special'),
      date: dateSchema,
      startTime: timeSchema.nullish(),
      endTime: timeSchema.nullish(),
      note: optText(500),
    }),
    req.body,
  );
  const today = localNow().date;
  if (body.date < today) throw badRequest('Pick today or a future date');
  if (body.date > addDays(today, 365)) throw badRequest('Pick a date within the next year');
  const start = body.startTime ?? hhmm(c.startTime);
  const end = body.endTime ?? hhmm(c.endTime);
  if (toMin(end) <= toMin(start)) throw badRequest('End time must be after the start time');
  const clash = await queryOne(`SELECT 1 FROM circle_specials WHERE circle_id = $1 AND session_date = $2::date`, [id, body.date]);
  if (clash) throw conflict('There is already a special session on that day');
  const sp = await queryOne(
    `INSERT INTO circle_specials (circle_id, title, kind, session_date, start_time, end_time, note, created_by)
     VALUES ($1, $2, $3, $4::date, $5, $6, $7, $8) RETURNING id, title, kind, session_date, start_time, end_time, note`,
    [id, body.title, body.kind, body.date, body.startTime ?? null, body.endTime ?? null, body.note, req.user.id],
  );
  const members = await query(`SELECT user_id FROM circle_members WHERE circle_id = $1 AND user_id <> $2`, [id, req.user.id]);
  const when = new Date(`${body.date}T00:00:00Z`).toLocaleDateString('en-IN', {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    timeZone: 'UTC',
  });
  for (const m of members) {
    await notify(m.userId, {
      type: 'circle_special',
      title: `${body.title} · ${c.name}`,
      body: `${when}, ${fmtMin(toMin(start))}. Tap to RSVP.`,
      data: { circleId: id, specialId: sp.id },
    });
  }
  res.status(201).json({ special: { ...sp, startTime: hhmm(sp.startTime), endTime: hhmm(sp.endTime), rsvpCount: 0, going: false } });
});

/** DELETE /circles/:id/specials/:sid — leader cancels a special session. */
router.delete('/:id/specials/:sid', async (req, res) => {
  const id = idParam(req);
  const sid = validate(uuidSchema, req.params.sid);
  await requireLeader(id, req.user.id);
  const rows = await query(`DELETE FROM circle_specials WHERE id = $1 AND circle_id = $2 RETURNING id`, [sid, id]);
  if (!rows.length) throw notFound('Special session not found');
  res.json({ removed: true });
});

// ---------------------------------------------------------------------------
// Chat (text + voice notes), polled by the app
// ---------------------------------------------------------------------------

const AUDIO_URL = /^\/api\/v1\/files\/([0-9a-f-]{36})$/;

/** GET /circles/:id/messages?after=ISO — the latest 100, or those after a timestamp. */
router.get('/:id/messages', async (req, res) => {
  const id = idParam(req);
  const { after } = validate(z.object({ after: z.string().datetime({ offset: true }).optional() }), req.query);
  await loadCircle(id);
  if (!(await membership(id, req.user.id))) throw forbidden('Join the circle to see its chat');
  const rows = after
    ? await query(
        `SELECT m.id, m.user_id, u.name AS user_name, u.avatar_url, m.body, m.audio_url, m.audio_seconds, m.created_at
         FROM circle_messages m JOIN users u ON u.id = m.user_id
         WHERE m.circle_id = $1 AND m.created_at > $2::timestamptz ORDER BY m.created_at LIMIT 100`,
        [id, after],
      )
    : await query(
        `SELECT * FROM (SELECT m.id, m.user_id, u.name AS user_name, u.avatar_url, m.body, m.audio_url, m.audio_seconds, m.created_at
         FROM circle_messages m JOIN users u ON u.id = m.user_id
         WHERE m.circle_id = $1 ORDER BY m.created_at DESC LIMIT 100) t ORDER BY created_at`,
        [id],
      );
  res.json({ messages: rows.map((r) => ({ ...r, mine: r.userId === req.user.id })) });
});

/** POST /circles/:id/messages { body?, audioUrl?, audioSeconds? } */
router.post('/:id/messages', async (req, res) => {
  const id = idParam(req);
  const body = validate(
    z
      .object({
        body: optText(1000),
        audioUrl: z.string().regex(AUDIO_URL, 'Upload the voice note first').nullish(),
        audioSeconds: z.number().int().min(1).max(600).nullish(),
      })
      .refine((b) => b.body || b.audioUrl, 'Type a message or record a voice note'),
    req.body,
  );
  await loadCircle(id);
  if (!(await membership(id, req.user.id))) throw forbidden('Join the circle to chat');
  if (body.audioUrl) {
    const fileId = AUDIO_URL.exec(body.audioUrl)[1];
    const f = await queryOne(`SELECT owner_id, mime FROM files WHERE id = $1`, [fileId]);
    if (!f || f.ownerId !== req.user.id || !f.mime.startsWith('audio/')) throw badRequest('Voice note not found — record it again');
  }
  const row = await queryOne(
    `INSERT INTO circle_messages (circle_id, user_id, body, audio_url, audio_seconds) VALUES ($1, $2, $3, $4, $5)
     RETURNING id, user_id, body, audio_url, audio_seconds, created_at`,
    [id, req.user.id, body.body, body.audioUrl ?? null, body.audioUrl ? (body.audioSeconds ?? null) : null],
  );
  const u = await queryOne(`SELECT name, avatar_url FROM users WHERE id = $1`, [req.user.id]);
  res.status(201).json({ message: { ...row, userName: u?.name, avatarUrl: u?.avatarUrl, mine: true } });
});

export default router;

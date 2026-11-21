/**
 * Admin dashboard: analytics, user directory, user 360° profile and activity timelines.
 *
 *  GET  /admin/insights/overview?days=30           KPIs, revenue by source, daily series, top lists, funnel
 *  GET  /admin/insights/users?q=&segment=&city=&sort=&page=&limit=
 *  GET  /admin/insights/users/:id                  everything about one member
 *  GET  /admin/insights/users/:id/activity?before=&limit=&type=
 *  GET  /admin/insights/activity?before=&limit=&type=   global live activity feed
 *  POST /admin/insights/users/:id/suspend { suspended, reason? }
 *  POST /admin/insights/users/:id/notify  { title, body }
 *  POST /admin/insights/users/:id/coins   { amount, note }   (bonus / referral-wallet coins; negative = deduct)
 */
import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { forgetSeen, requireAuth } from '../middleware/auth.js';
import { badRequest, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { balances } from '../utils/wallet.js';
import { AI_PRICES, USD_INR } from '../utils/ai_usage.js';

const router = Router();
router.use(requireAuth('admin'));

const uuid = z.string().uuid();

// ------------------------------------------------------------------------------------------------ activity events
/**
 * Every member action as one event stream: { at, user_id, type, title, detail, amount_paise, ref_id }.
 * Each branch is limited separately so the union stays cheap; $1 = user id (or NULL for everyone), $2 = before,
 * $3 = per-branch limit.
 */
const EVENT_BRANCHES = {
  signup: `SELECT u.created_at AS at, u.id AS user_id, 'signup' AS type, 'Joined FITKEY' AS title,
                  COALESCE(u.city, '') AS detail, NULL::int AS amount_paise, u.id AS ref_id
           FROM users u WHERE u.role = 'user'`,
  checkin: `SELECT c.checked_in_at, c.user_id, 'checkin', 'Checked in at ' || v.name,
                   COALESCE(c.cost_label, c.paid_via, c.method), NULL::int, c.id
            FROM checkins c JOIN venues v ON v.id = c.venue_id`,
  booking: `SELECT b.created_at, b.user_id, 'booking', 'Booked a slot at ' || v.name,
                   to_char(b.slot_date, 'DD Mon') || ' ' || to_char(b.slot_start, 'HH24:MI') || ' · ' || b.status, NULL::int, b.id
            FROM slot_bookings b JOIN venues v ON v.id = b.venue_id`,
  subscription: `SELECT s.created_at, s.user_id, 'purchase', 'Bought ' || p.name, 'FitKey pass plan', s.amount_paise, s.id
                 FROM subscriptions s JOIN plans p ON p.id = s.plan_id`,
  wallet_pass: `SELECT f.created_at, f.user_id, 'purchase', 'Bought ' || f.name,
                       CASE WHEN f.kind = 'coin_pack' THEN f.coins || ' coins' ELSE f.sessions_total || ' sessions' END, f.paid_paise, f.id
                FROM fitkey_purchases f`,
  membership: `SELECT m.created_at, m.user_id, 'purchase', 'Bought ' || m.plan_name || ' at ' || v.name,
                      'Centre membership · ' || to_char(m.starts_on, 'DD Mon') || ' → ' || to_char(m.ends_on, 'DD Mon YYYY'), m.amount_paise, m.id
               FROM direct_memberships m JOIN venues v ON v.id = m.venue_id`,
  store_order: `SELECT o.created_at, o.user_id, 'order', 'Store order · ' || o.status,
                       o.payment_method || ' · ' || o.payment_status, COALESCE(o.payable_paise, o.total_amount_paise), o.id
                FROM marketplace_orders o`,
  payment: `SELECT p.created_at, p.user_id, 'payment', 'Payment ' || p.status || ' · ' || replace(p.purpose, '_', ' '),
                   COALESCE(p.description, ''), p.amount_paise, p.id
            FROM payment_orders p WHERE p.status <> 'fulfilled' AND (p.status <> 'created' OR p.created_at < now() - interval '30 minutes')`,
  meal: `SELECT ml.logged_at, ml.user_id, 'meal', 'Logged ' || ml.food_name, ml.meal_type || ' · ' || ml.calories || ' kcal', NULL::int, ml.id
         FROM meal_logs ml`,
  steps: `SELECT sl.synced_at, sl.user_id, 'steps', sl.steps || ' steps', to_char(sl.log_date, 'DD Mon') || ' · ' || sl.source, NULL::int, sl.id
          FROM step_logs sl`,
  workout: `SELECT a.logged_at, a.user_id, 'workout', COALESCE(a.title, initcap(a.type)),
                   concat_ws(' · ', a.duration_min || ' min', a.distance_km || ' km', a.calories || ' kcal'), NULL::int, a.id
            FROM activity_logs a`,
  trip: `SELECT t.started_at, t.user_id, 'trip', initcap(t.mode) || ' · ' || round(t.distance_m / 1000.0, 2) || ' km',
                (t.duration_s / 60) || ' min', NULL::int, t.id
         FROM activity_tracks t`,
  proveit: `SELECT aa.created_at, aa.user_id, 'proveit', 'ProveIt · ' || initcap(replace(aa.exercise_id, '_', ' ')),
                   aa.reps || ' reps' || CASE WHEN aa.completed THEN ' · completed' ELSE '' END, NULL::int, aa.id
            FROM arena_attempts aa`,
  post: `SELECT fp.created_at, fp.user_id, 'post', 'Posted on FitFeed', left(COALESCE(fp.caption, fp.title, fp.kind), 120), NULL::int, fp.id
         FROM feed_posts fp`,
  comment: `SELECT fc.created_at, fc.user_id, 'comment', 'Commented on a post', left(fc.body, 120), NULL::int, fc.id
            FROM feed_comments fc`,
  weight: `SELECT w.logged_on::timestamptz + interval '12 hours', w.user_id, 'weight', 'Logged weight', w.weight_kg || ' kg', NULL::int, w.id
           FROM weight_logs w`,
  referral: `SELECT r.created_at, r.referrer_id, 'referral', 'Invited a friend', r.status, NULL::int, r.id FROM referrals r`,
  coins: `SELECT cl.created_at, cl.user_id, 'coins', (CASE WHEN cl.amount > 0 THEN '+' ELSE '' END) || cl.amount || ' ' || cl.wallet || ' coins',
                 replace(cl.kind, '_', ' ') || COALESCE(' · ' || cl.note, ''), NULL::int, cl.id
          FROM coin_ledger cl`,
  trainer: `SELECT tb.created_at, tb.user_id, 'trainer', 'Booked trainer ' || t.name, to_char(tb.session_date, 'DD Mon') || ' · ' || tb.status, tb.amount_paise, tb.id
            FROM trainer_bookings tb JOIN trainers t ON t.id = tb.trainer_id`,
  rating: `SELECT vr.updated_at, vr.user_id, 'rating', 'Rated ' || v.name || ' ' || vr.stars || '★', '', NULL::int, vr.venue_id
           FROM venue_ratings vr JOIN venues v ON v.id = vr.venue_id`,
  circle: `SELECT cm.joined_at, cm.user_id, 'circle', 'Joined circle ' || c.name, c.place_name, NULL::int, c.id
           FROM circle_members cm JOIN circles c ON c.id = cm.circle_id`,
  event: `SELECT cp.joined_at, cp.user_id, 'event', 'Joined ' || ct.title, '', NULL::int, ct.id
          FROM contest_participants cp JOIN contests ct ON ct.id = cp.contest_id`,
  report: `SELECT ur.created_at, ur.reported_id, 'report', 'Was reported by a member', left(ur.reason, 120), NULL::int, ur.id
           FROM user_reports ur`,
};

/** The SQL column (per branch) holding the event's user, for the per-user filter. */
const USER_COL = {
  signup: 'u.id', checkin: 'c.user_id', booking: 'b.user_id', subscription: 's.user_id', wallet_pass: 'f.user_id',
  membership: 'm.user_id', store_order: 'o.user_id', payment: 'p.user_id', meal: 'ml.user_id', steps: 'sl.user_id',
  workout: 'a.user_id', trip: 't.user_id', proveit: 'aa.user_id', post: 'fp.user_id', comment: 'fc.user_id',
  weight: 'w.user_id', referral: 'r.referrer_id', coins: 'cl.user_id', trainer: 'tb.user_id', rating: 'vr.user_id',
  circle: 'cm.user_id', event: 'cp.user_id', report: 'ur.reported_id',
};
/** The SQL expression (per branch) holding the event time, for "before" paging. */
const TIME_COL = {
  signup: 'u.created_at', checkin: 'c.checked_in_at', booking: 'b.created_at', subscription: 's.created_at',
  wallet_pass: 'f.created_at', membership: 'm.created_at', store_order: 'o.created_at', payment: 'p.created_at',
  meal: 'ml.logged_at', steps: 'sl.synced_at', workout: 'a.logged_at', trip: 't.started_at', proveit: 'aa.created_at',
  post: 'fp.created_at', comment: 'fc.created_at', weight: "(w.logged_on::timestamptz + interval '12 hours')",
  referral: 'r.created_at', coins: 'cl.created_at', trainer: 'tb.created_at', rating: 'vr.updated_at',
  circle: 'cm.joined_at', event: 'cp.joined_at', report: 'ur.created_at',
};
/** Activity filter groups shown in the admin panel. */
export const EVENT_GROUPS = {
  all: Object.keys(EVENT_BRANCHES),
  money: ['subscription', 'wallet_pass', 'membership', 'store_order', 'payment', 'trainer', 'coins'],
  visits: ['checkin', 'booking', 'trainer'],
  fitness: ['steps', 'workout', 'trip', 'proveit', 'meal', 'weight'],
  social: ['post', 'comment', 'circle', 'event', 'referral', 'rating', 'report'],
  signups: ['signup'],
};

function eventsSql(branches) {
  const parts = branches.map((b) => {
    const sql = EVENT_BRANCHES[b];
    const joiner = /\bWHERE\b/i.test(sql.split('FROM').pop()) ? 'AND' : 'WHERE';
    return `(${sql} ${joiner} ($1::uuid IS NULL OR ${USER_COL[b]} = $1::uuid) AND ${TIME_COL[b]} < $2::timestamptz
             ORDER BY 1 DESC LIMIT $3)`;
  });
  return `SELECT e.*, us.name AS user_name, us.phone AS user_phone
          FROM (${parts.join('\nUNION ALL\n')}) e (at, user_id, type, title, detail, amount_paise, ref_id)
          LEFT JOIN users us ON us.id = e.user_id
          WHERE e.at IS NOT NULL
          ORDER BY e.at DESC LIMIT $3`;
}

const feedQuery = z.object({
  before: z.string().datetime({ offset: true }).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(60),
  type: z.enum(Object.keys(EVENT_GROUPS)).default('all'),
});

async function events(userId, q) {
  const rows = await query(eventsSql(EVENT_GROUPS[q.type]), [userId, q.before ?? new Date(Date.now() + 60_000).toISOString(), q.limit]);
  return { events: rows, nextBefore: rows.length === q.limit ? rows[rows.length - 1].at : null };
}

router.get('/activity', async (req, res) => {
  res.json(await events(null, validate(feedQuery, req.query)));
});

router.get('/users/:id/activity', async (req, res) => {
  const id = validate(uuid, req.params.id);
  res.json(await events(id, validate(feedQuery, req.query)));
});

// ------------------------------------------------------------------------------------------------ overview
router.get('/overview', async (req, res) => {
  const { days } = validate(z.object({ days: z.coerce.number().int().min(7).max(365).default(30) }), req.query);
  const tz = config.tz;
  const since = `((now() AT TIME ZONE $1)::date - ($2::int - 1))`;

  const [kpis, revenue, series, cities, venues, exercises, funnel, partners, engagement, sources] = await Promise.all([
    queryOne(
      `SELECT
         (SELECT COUNT(*) FROM users WHERE role = 'user')::int AS members,
         (SELECT COUNT(*) FROM users WHERE role = 'user' AND (created_at AT TIME ZONE $1)::date >= ${since})::int AS new_members,
         (SELECT COUNT(*) FROM users WHERE role = 'user' AND (created_at AT TIME ZONE $1)::date = (now() AT TIME ZONE $1)::date)::int AS new_today,
         (SELECT COUNT(*) FROM users WHERE role = 'user' AND last_seen_at >= date_trunc('day', now() AT TIME ZONE $1) AT TIME ZONE $1)::int AS active_today,
         (SELECT COUNT(*) FROM users WHERE role = 'user' AND last_seen_at >= now() - interval '7 days')::int AS active_7d,
         (SELECT COUNT(*) FROM users WHERE role = 'user' AND last_seen_at >= now() - interval '30 days')::int AS active_30d,
         (SELECT COUNT(*) FROM users WHERE role = 'user' AND is_suspended)::int AS suspended,
         (SELECT COUNT(*) FROM users WHERE role = 'partner')::int AS partners,
         (SELECT COUNT(DISTINCT user_id) FROM (
            SELECT user_id FROM subscriptions UNION SELECT user_id FROM fitkey_purchases
            UNION SELECT user_id FROM direct_memberships UNION SELECT user_id FROM marketplace_orders) x)::int AS paying_members,
         (SELECT COUNT(*) FROM subscriptions WHERE status = 'active' AND now() BETWEEN starts_at AND ends_at)::int
           + (SELECT COUNT(DISTINCT user_id) FROM fitkey_purchases WHERE expires_at > now()
                AND (coins_remaining > 0 OR sessions_total > 0))::int AS active_passes,
         (SELECT COUNT(*) FROM direct_memberships WHERE status = 'active' AND (now() AT TIME ZONE $1)::date BETWEEN starts_on AND ends_on)::int AS active_memberships,
         (SELECT COUNT(*) FROM checkins WHERE checkin_date = (now() AT TIME ZONE $1)::date)::int AS checkins_today,
         (SELECT COUNT(*) FROM checkins WHERE checkin_date >= ${since})::int AS checkins_period,
         (SELECT COUNT(*) FROM venues WHERE status = 'live')::int AS live_venues,
         (SELECT COUNT(*) FROM venues WHERE status IN ('submitted', 'under_review'))::int AS pending_venues,
         (SELECT COUNT(*) FROM marketplace_orders WHERE (created_at AT TIME ZONE $1)::date >= ${since})::int AS orders_period,
         (SELECT COUNT(*) FROM user_reports WHERE created_at >= now() - make_interval(days => $2))::int AS reports_period`,
      [tz, days],
    ),
    queryOne(
      `SELECT
         (SELECT COALESCE(SUM(amount_paise), 0) FROM subscriptions WHERE (created_at AT TIME ZONE $1)::date >= ${since})::bigint AS subscriptions,
         (SELECT COALESCE(SUM(paid_paise), 0) FROM fitkey_purchases WHERE (created_at AT TIME ZONE $1)::date >= ${since})::bigint AS wallet_passes,
         (SELECT COALESCE(SUM(amount_paise), 0) FROM direct_memberships WHERE status <> 'cancelled' AND (created_at AT TIME ZONE $1)::date >= ${since})::bigint AS memberships,
         (SELECT COALESCE(SUM(COALESCE(payable_paise, total_amount_paise)), 0) FROM marketplace_orders
            WHERE status <> 'cancelled' AND (payment_status = 'paid' OR status = 'delivered') AND (created_at AT TIME ZONE $1)::date >= ${since})::bigint AS store,
         (SELECT COALESCE(SUM(amount_paise), 0) FROM payment_orders WHERE status = 'fulfilled' AND (created_at AT TIME ZONE $1)::date >= ${since})::bigint AS collected_online,
         (SELECT COALESCE(SUM(refunded_paise), 0) FROM payment_orders WHERE (created_at AT TIME ZONE $1)::date >= ${since})::bigint AS refunded,
         (SELECT COALESCE(SUM(commission_paise), 0) FROM direct_memberships WHERE (created_at AT TIME ZONE $1)::date >= ${since})::bigint
           + (SELECT COALESCE(SUM(commission_paise), 0) FROM visit_payouts WHERE visit_date >= ${since})::bigint AS commission,
         (SELECT COALESCE(SUM(amount_paise), 0) FROM visit_payouts WHERE visit_date >= ${since})::bigint AS owed_to_venues`,
      [tz, days],
    ),
    query(
      `WITH d AS (SELECT generate_series(${since}, (now() AT TIME ZONE $1)::date, interval '1 day')::date AS day)
       SELECT to_char(d.day, 'YYYY-MM-DD') AS day,
         (SELECT COUNT(*) FROM users WHERE role = 'user' AND (created_at AT TIME ZONE $1)::date = d.day)::int AS signups,
         (SELECT COUNT(*) FROM checkins WHERE checkin_date = d.day)::int AS checkins,
         (SELECT COUNT(*) FROM slot_bookings WHERE (created_at AT TIME ZONE $1)::date = d.day)::int AS bookings,
         ((SELECT COALESCE(SUM(amount_paise), 0) FROM subscriptions WHERE (created_at AT TIME ZONE $1)::date = d.day)
          + (SELECT COALESCE(SUM(paid_paise), 0) FROM fitkey_purchases WHERE (created_at AT TIME ZONE $1)::date = d.day)
          + (SELECT COALESCE(SUM(amount_paise), 0) FROM direct_memberships WHERE status <> 'cancelled' AND (created_at AT TIME ZONE $1)::date = d.day)
          + (SELECT COALESCE(SUM(COALESCE(payable_paise, total_amount_paise)), 0) FROM marketplace_orders
               WHERE status <> 'cancelled' AND (payment_status = 'paid' OR status = 'delivered') AND (created_at AT TIME ZONE $1)::date = d.day))::bigint AS revenue_paise,
         (SELECT COUNT(*) FROM meal_logs WHERE logged_on = d.day)::int AS meals,
         (SELECT COUNT(*) FROM step_logs WHERE log_date = d.day)::int AS step_syncs,
         (SELECT COUNT(*) FROM arena_attempts WHERE (created_at AT TIME ZONE $1)::date = d.day)::int AS proveit,
         (SELECT COUNT(*) FROM feed_posts WHERE (created_at AT TIME ZONE $1)::date = d.day)::int AS posts,
         (SELECT COUNT(DISTINCT user_id) FROM (
            SELECT user_id FROM checkins WHERE checkin_date = d.day
            UNION SELECT user_id FROM meal_logs WHERE logged_on = d.day
            UNION SELECT user_id FROM step_logs WHERE log_date = d.day
            UNION SELECT user_id FROM arena_attempts WHERE (created_at AT TIME ZONE $1)::date = d.day
            UNION SELECT user_id FROM activity_logs WHERE (logged_at AT TIME ZONE $1)::date = d.day
            UNION SELECT user_id FROM feed_posts WHERE (created_at AT TIME ZONE $1)::date = d.day
            UNION SELECT user_id FROM slot_bookings WHERE (created_at AT TIME ZONE $1)::date = d.day) a)::int AS active_users
       FROM d ORDER BY d.day`,
      [tz, days],
    ),
    query(
      `SELECT COALESCE(NULLIF(trim(city), ''), 'Unknown') AS city, COUNT(*)::int AS members
       FROM users WHERE role = 'user' GROUP BY 1 ORDER BY 2 DESC LIMIT 10`,
    ),
    query(
      `SELECT v.id, v.name, v.city, COUNT(c.id)::int AS checkins, COUNT(DISTINCT c.user_id)::int AS members
       FROM checkins c JOIN venues v ON v.id = c.venue_id
       WHERE c.checkin_date >= ${since} GROUP BY v.id ORDER BY 4 DESC LIMIT 10`,
      [tz, days],
    ),
    query(
      `SELECT exercise_id, COUNT(*)::int AS attempts, COUNT(DISTINCT user_id)::int AS members, MAX(reps)::int AS best
       FROM arena_attempts WHERE (created_at AT TIME ZONE $1)::date >= ${since} GROUP BY 1 ORDER BY 2 DESC LIMIT 8`,
      [tz, days],
    ),
    queryOne(
      `WITH cohort AS (SELECT id FROM users WHERE role = 'user' AND (created_at AT TIME ZONE $1)::date >= ${since})
       SELECT (SELECT COUNT(*) FROM cohort)::int AS signed_up,
              (SELECT COUNT(*) FROM users WHERE id IN (SELECT id FROM cohort) AND name IS NOT NULL)::int AS profile_done,
              (SELECT COUNT(DISTINCT user_id) FROM (
                 SELECT user_id FROM subscriptions UNION SELECT user_id FROM fitkey_purchases
                 UNION SELECT user_id FROM direct_memberships) x WHERE user_id IN (SELECT id FROM cohort))::int AS purchased,
              (SELECT COUNT(DISTINCT user_id) FROM checkins WHERE user_id IN (SELECT id FROM cohort))::int AS checked_in,
              (SELECT COUNT(*) FROM (SELECT user_id FROM checkins WHERE user_id IN (SELECT id FROM cohort)
                 GROUP BY user_id HAVING COUNT(*) >= 3) r)::int AS regulars`,
      [tz, days],
    ).catch(() => null),
    queryOne(
      `SELECT
         (SELECT COUNT(*) FROM venues WHERE status = 'live')::int AS live_venues,
         (SELECT COUNT(*) FROM venues WHERE status IN ('submitted', 'under_review', 'changes_needed', 'approved'))::int AS venues_in_review,
         (SELECT COUNT(*) FROM venues WHERE status = 'draft')::int AS venue_drafts,
         (SELECT COUNT(*) FROM trainers WHERE listing_status = 'live' OR listing_status IS NULL)::int AS trainers,
         (SELECT COUNT(*) FROM marketplace_vendors)::int AS store_sellers,
         (SELECT COUNT(*) FROM centre_plans WHERE approval_status = 'pending' AND archived_at IS NULL)::int AS plans_pending,
         (SELECT COUNT(*) FROM partner_payouts WHERE status IN ('scheduled', 'processing', 'on_hold'))::int AS payouts_open,
         (SELECT COALESCE(SUM(net_paise), 0) FROM partner_payouts WHERE status IN ('scheduled', 'processing', 'on_hold'))::bigint AS payouts_open_paise`,
    ),
    queryOne(
      `SELECT
         (SELECT ROUND(AVG(steps)) FROM step_logs WHERE log_date >= (now() AT TIME ZONE $1)::date - 6)::int AS avg_steps_7d,
         (SELECT COUNT(DISTINCT user_id) FROM step_logs WHERE log_date >= (now() AT TIME ZONE $1)::date - 6)::int AS step_users_7d,
         (SELECT COUNT(*) FROM meal_logs WHERE logged_on >= (now() AT TIME ZONE $1)::date - 6)::int AS meals_7d,
         (SELECT COUNT(DISTINCT user_id) FROM meal_logs WHERE logged_on >= (now() AT TIME ZONE $1)::date - 6)::int AS meal_users_7d,
         (SELECT COUNT(*) FROM arena_attempts WHERE created_at >= now() - interval '7 days')::int AS proveit_7d,
         (SELECT COUNT(*) FROM activity_tracks WHERE started_at >= now() - interval '7 days')::int AS trips_7d,
         (SELECT COALESCE(ROUND(SUM(distance_m) / 1000.0), 0) FROM activity_tracks WHERE started_at >= now() - interval '7 days')::int AS trip_km_7d,
         (SELECT COUNT(*) FROM feed_posts WHERE created_at >= now() - interval '7 days')::int AS posts_7d,
         (SELECT COUNT(*) FROM referrals WHERE created_at >= now() - interval '7 days')::int AS referrals_7d`,
      [tz],
    ),
    query(
      `SELECT COALESCE(source, 'unknown') AS source, COUNT(DISTINCT user_id)::int AS members
       FROM step_logs WHERE log_date >= (now() AT TIME ZONE $1)::date - 29 GROUP BY 1 ORDER BY 2 DESC`,
      [tz],
    ),
  ]);

  res.json({ days, kpis, revenue, series, topCities: cities, topVenues: venues, topExercises: exercises, funnel, partners, engagement, stepSources: sources });
});

// ------------------------------------------------------------------------------------------------ users
const usersQuery = z.object({
  q: z.string().trim().max(80).default(''),
  segment: z.enum(['all', 'new', 'active', 'inactive', 'paying', 'never_paid', 'suspended']).default('all'),
  city: z.string().trim().max(80).optional(),
  sort: z.enum(['recent', 'last_seen', 'spend', 'checkins']).default('recent'),
  page: z.coerce.number().int().min(1).max(1000).default(1),
  limit: z.coerce.number().int().min(10).max(200).default(50),
});

const SPEND_SQL = `(COALESCE((SELECT SUM(amount_paise) FROM subscriptions WHERE user_id = u.id), 0)
  + COALESCE((SELECT SUM(paid_paise) FROM fitkey_purchases WHERE user_id = u.id), 0)
  + COALESCE((SELECT SUM(amount_paise) FROM direct_memberships WHERE user_id = u.id AND status <> 'cancelled'), 0)
  + COALESCE((SELECT SUM(COALESCE(payable_paise, total_amount_paise)) FROM marketplace_orders WHERE user_id = u.id AND status <> 'cancelled'
      AND (payment_status = 'paid' OR status = 'delivered')), 0))`;

router.get('/users', async (req, res) => {
  const f = validate(usersQuery, req.query);
  const digits = f.q.replace(/[^0-9]/g, '');
  const where = [`u.role = 'user'`];
  const params = [];
  const p = (v) => {
    params.push(v);
    return `$${params.length}`;
  };
  if (f.q) {
    const qp = p(f.q);
    where.push(`(u.name ILIKE '%' || ${qp} || '%' OR u.email ILIKE '%' || ${qp} || '%'${digits ? ` OR u.phone LIKE '%' || ${p(digits)} || '%'` : ''})`);
  }
  if (f.city) where.push(`u.city ILIKE ${p(f.city)}`);
  const seg = {
    new: `u.created_at >= now() - interval '7 days'`,
    active: `u.last_seen_at >= now() - interval '7 days'`,
    inactive: `(u.last_seen_at IS NULL OR u.last_seen_at < now() - interval '30 days')`,
    paying: `${SPEND_SQL} > 0`,
    never_paid: `${SPEND_SQL} = 0`,
    suspended: `u.is_suspended`,
  }[f.segment];
  if (seg) where.push(seg);
  const order = {
    recent: 'u.created_at DESC',
    last_seen: 'u.last_seen_at DESC NULLS LAST',
    spend: 'spend_paise DESC',
    checkins: 'checkins DESC',
  }[f.sort];
  const whereSql = where.join(' AND ');
  const [rows, total] = await Promise.all([
    query(
      `SELECT u.id, u.name, u.phone, u.email, u.city, u.gender, u.avatar_url, u.created_at, u.last_seen_at, u.is_suspended,
              (SELECT COUNT(*) FROM checkins WHERE user_id = u.id)::int AS checkins,
              ${SPEND_SQL}::bigint AS spend_paise,
              (EXISTS (SELECT 1 FROM subscriptions s WHERE s.user_id = u.id AND s.status = 'active' AND now() BETWEEN s.starts_at AND s.ends_at)
               OR EXISTS (SELECT 1 FROM fitkey_purchases fp WHERE fp.user_id = u.id AND fp.expires_at > now())
               OR EXISTS (SELECT 1 FROM direct_memberships dm WHERE dm.user_id = u.id AND dm.status = 'active' AND dm.ends_on >= (now() AT TIME ZONE '${config.tz.replace(/'/g, '')}')::date)) AS has_active_pass
       FROM users u WHERE ${whereSql}
       ORDER BY ${order} LIMIT ${p(f.limit)} OFFSET ${p((f.page - 1) * f.limit)}`,
      params,
    ),
    queryOne(`SELECT COUNT(*)::int AS n FROM users u WHERE ${whereSql}`, params.slice(0, params.length - 2)),
  ]);
  res.json({ users: rows, total: total.n, page: f.page, limit: f.limit });
});

router.get('/users/:id', async (req, res) => {
  const id = validate(uuid, req.params.id);
  const user = await queryOne(
    `SELECT u.id, u.name, u.phone, u.email, u.role, u.city, u.gender, u.birth_date, u.avatar_url, u.created_at, u.updated_at,
            u.last_seen_at, u.is_suspended, u.suspended_reason, u.suspended_at, u.referral_code,
            rb.name AS referred_by_name, rb.id AS referred_by_id
     FROM users u LEFT JOIN users rb ON rb.id = u.referred_by WHERE u.id = $1`,
    [id],
  );
  if (!user) throw notFound('User not found');
  const tz = config.tz;
  const [stats, passes, purchases, memberships, orders, payments, checkins, bookings, steps, weights, meals, proveit,
    goal, referrals, circles, reports, wallet] = await Promise.all([
    queryOne(
      `SELECT
         (SELECT COUNT(*) FROM checkins WHERE user_id = $1)::int AS checkins,
         (SELECT COUNT(DISTINCT venue_id) FROM checkins WHERE user_id = $1)::int AS venues_visited,
         (SELECT MAX(checked_in_at) FROM checkins WHERE user_id = $1) AS last_checkin_at,
         (SELECT COUNT(*) FROM slot_bookings WHERE user_id = $1)::int AS bookings,
         (SELECT COUNT(*) FROM meal_logs WHERE user_id = $1)::int AS meals,
         (SELECT COUNT(*) FROM arena_attempts WHERE user_id = $1)::int AS proveit_attempts,
         (SELECT COUNT(*) FROM feed_posts WHERE user_id = $1)::int AS posts,
         (SELECT COUNT(*) FROM activity_logs WHERE user_id = $1)::int AS workouts,
         (SELECT COUNT(*) FROM activity_tracks WHERE user_id = $1)::int AS trips,
         (SELECT COALESCE(ROUND(SUM(distance_m) / 1000.0, 1), 0) FROM activity_tracks WHERE user_id = $1)::float AS trip_km,
         (SELECT COALESCE(ROUND(AVG(steps)), 0) FROM step_logs WHERE user_id = $1 AND log_date >= (now() AT TIME ZONE $2)::date - 6)::int AS avg_steps_7d,
         (SELECT COUNT(*) FROM referrals WHERE referrer_id = $1)::int AS invited,
         (SELECT COUNT(*) FROM user_reports WHERE reported_id = $1)::int AS reports_against,
         ${SPEND_SQL.replace(/u\.id/g, '$1')}::bigint AS spend_paise`,
      [id, tz],
    ),
    query(
      `SELECT s.id, p.name, s.status, s.starts_at, s.ends_at, s.amount_paise, s.payment_ref, s.created_at
       FROM subscriptions s JOIN plans p ON p.id = s.plan_id WHERE s.user_id = $1 ORDER BY s.created_at DESC LIMIT 20`,
      [id],
    ),
    query(
      `SELECT id, kind, name, price_paise, paid_paise, coins, coins_remaining, sessions_total, coins_redeemed, expires_at, payment_ref, created_at
       FROM fitkey_purchases WHERE user_id = $1 ORDER BY created_at DESC LIMIT 20`,
      [id],
    ),
    query(
      `SELECT m.id, m.plan_name, v.name AS venue_name, m.duration, m.starts_on, m.ends_on, m.amount_paise, m.status, m.payment_ref, m.created_at
       FROM direct_memberships m JOIN venues v ON v.id = m.venue_id WHERE m.user_id = $1 ORDER BY m.created_at DESC LIMIT 20`,
      [id],
    ),
    query(
      `SELECT o.id, o.status, o.payment_method, o.payment_status, o.total_amount_paise, o.payable_paise, o.coins_redeemed, o.created_at,
              (SELECT COUNT(*) FROM marketplace_order_items i WHERE i.order_id = o.id)::int AS items
       FROM marketplace_orders o WHERE o.user_id = $1 ORDER BY o.created_at DESC LIMIT 20`,
      [id],
    ),
    query(
      `SELECT id, purpose, status, amount_paise, description, razorpay_payment_id, refunded_paise, error, created_at
       FROM payment_orders WHERE user_id = $1 ORDER BY created_at DESC LIMIT 20`,
      [id],
    ),
    query(
      `SELECT c.id, v.name AS venue_name, c.checked_in_at, c.method, c.paid_via, c.cost_label
       FROM checkins c JOIN venues v ON v.id = c.venue_id WHERE c.user_id = $1 ORDER BY c.checked_in_at DESC LIMIT 20`,
      [id],
    ),
    query(
      `SELECT b.id, v.name AS venue_name, b.slot_date, b.slot_start, b.status, b.paid_via, b.created_at
       FROM slot_bookings b JOIN venues v ON v.id = b.venue_id WHERE b.user_id = $1 ORDER BY b.created_at DESC LIMIT 20`,
      [id],
    ),
    query(
      `SELECT to_char(log_date, 'YYYY-MM-DD') AS date, steps, distance_km, source FROM step_logs
       WHERE user_id = $1 AND log_date >= (now() AT TIME ZONE $2)::date - 29 ORDER BY log_date`,
      [id, tz],
    ),
    query(`SELECT to_char(logged_on, 'YYYY-MM-DD') AS date, weight_kg FROM weight_logs WHERE user_id = $1 ORDER BY logged_on DESC LIMIT 30`, [id]),
    query(
      `SELECT to_char(logged_on, 'YYYY-MM-DD') AS date, COUNT(*)::int AS items, SUM(calories)::int AS calories,
              ROUND(SUM(protein_g))::int AS protein_g
       FROM meal_logs WHERE user_id = $1 AND logged_on >= (now() AT TIME ZONE $2)::date - 13 GROUP BY logged_on ORDER BY logged_on`,
      [id, tz],
    ),
    query(
      `SELECT exercise_id, COUNT(*)::int AS attempts, MAX(reps)::int AS best_reps, MAX(level)::int AS best_level, MAX(created_at) AS last_at
       FROM arena_attempts WHERE user_id = $1 GROUP BY exercise_id ORDER BY 2 DESC`,
      [id],
    ),
    queryOne(`SELECT * FROM user_goals WHERE user_id = $1`, [id]).catch(() => null),
    query(
      `SELECT r.status, r.created_at, u.id AS user_id, u.name, u.phone FROM referrals r JOIN users u ON u.id = r.referred_user_id
       WHERE r.referrer_id = $1 ORDER BY r.created_at DESC LIMIT 30`,
      [id],
    ),
    query(
      `SELECT c.id, c.name, c.place_name, cm.role, cm.joined_at FROM circle_members cm JOIN circles c ON c.id = cm.circle_id
       WHERE cm.user_id = $1 ORDER BY cm.joined_at DESC`,
      [id],
    ),
    query(
      `SELECT ur.reason, ur.created_at, rp.name AS reporter_name FROM user_reports ur JOIN users rp ON rp.id = ur.reporter_id
       WHERE ur.reported_id = $1 ORDER BY ur.created_at DESC LIMIT 20`,
      [id],
    ),
    balances(id).catch(() => null),
  ]);
  const ai = await queryOne(
    `SELECT COUNT(*)::int AS calls, COUNT(*) FILTER (WHERE feature = 'mansi_chat')::int AS chats,
            COUNT(*) FILTER (WHERE feature IN ('meal_scan', 'label_scan'))::int AS scans,
            COUNT(*) FILTER (WHERE status = 'declined')::int AS declined,
            COALESCE(SUM(total_tokens), 0)::bigint AS tokens, COALESCE(SUM(cost_inr), 0)::float AS cost_inr,
            MAX(created_at) AS last_at
     FROM ai_usage_logs WHERE user_id = $1`,
    [id],
  ).catch(() => null);
  res.json({
    user,
    stats,
    wallet,
    passes: { subscriptions: passes, purchases, memberships },
    orders,
    payments,
    recent: { checkins, bookings },
    health: { steps, weights, meals, goal },
    proveit,
    social: { referrals, circles, reportsAgainst: reports },
    ai,
  });
});

// ------------------------------------------------------------------------------------------------ AI usage
const AI_FEATURES = ['mansi_chat', 'topic_guard', 'meal_scan', 'label_scan', 'other'];

/** GET /admin/insights/ai?days=30 — calls, tokens, estimated cost (₹ / $), errors, latency; by feature / model / day. */
router.get('/ai', async (req, res) => {
  const { days } = validate(z.object({ days: z.coerce.number().int().min(1).max(365).default(30) }), req.query);
  const tz = config.tz;
  const since = '((now() AT TIME ZONE $1)::date - ($2::int - 1))';
  const inPeriod = (col = 'created_at') => '(' + col + ' AT TIME ZONE $1)::date >= ' + since;
  const [totals, byFeature, byModel, series, topUsers, today, month] = await Promise.all([
    queryOne(
      'SELECT COUNT(*)::int AS calls,' +
        " COUNT(*) FILTER (WHERE status = 'error')::int AS errors," +
        " COUNT(*) FILTER (WHERE status = 'declined')::int AS declined," +
        ' COUNT(*) FILTER (WHERE has_image)::int AS image_calls,' +
        ' COALESCE(SUM(prompt_tokens), 0)::bigint AS prompt_tokens,' +
        ' COALESCE(SUM(completion_tokens), 0)::bigint AS completion_tokens,' +
        ' COALESCE(SUM(total_tokens), 0)::bigint AS total_tokens,' +
        ' COALESCE(SUM(cost_usd), 0)::float AS cost_usd,' +
        ' COALESCE(SUM(cost_inr), 0)::float AS cost_inr,' +
        " ROUND(AVG(latency_ms) FILTER (WHERE status = 'ok'))::int AS avg_latency_ms," +
        " ROUND((PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY latency_ms) FILTER (WHERE status = 'ok'))::numeric)::int AS p95_latency_ms," +
        ' COUNT(DISTINCT user_id)::int AS users,' +
        " COUNT(*) FILTER (WHERE cost_usd IS NULL AND status = 'ok')::int AS unpriced_calls" +
        ' FROM ai_usage_logs WHERE ' + inPeriod(),
      [tz, days],
    ),
    query(
      'SELECT feature, COUNT(*)::int AS calls,' +
        " COUNT(*) FILTER (WHERE status = 'error')::int AS errors," +
        ' COALESCE(SUM(total_tokens), 0)::bigint AS tokens, COALESCE(SUM(cost_inr), 0)::float AS cost_inr,' +
        ' COALESCE(SUM(cost_usd), 0)::float AS cost_usd, ROUND(AVG(latency_ms))::int AS avg_latency_ms,' +
        ' COALESCE(SUM(cost_inr), 0)::float / GREATEST(COUNT(*), 1) AS cost_inr_per_call' +
        ' FROM ai_usage_logs WHERE ' + inPeriod() + ' GROUP BY feature ORDER BY cost_inr DESC',
      [tz, days],
    ),
    query(
      'SELECT model, COUNT(*)::int AS calls, COALESCE(SUM(prompt_tokens), 0)::bigint AS prompt_tokens,' +
        ' COALESCE(SUM(completion_tokens), 0)::bigint AS completion_tokens, COALESCE(SUM(cost_inr), 0)::float AS cost_inr' +
        ' FROM ai_usage_logs WHERE ' + inPeriod() + ' GROUP BY model ORDER BY cost_inr DESC',
      [tz, days],
    ),
    query(
      "WITH d AS (SELECT generate_series(" + since + ", (now() AT TIME ZONE $1)::date, interval '1 day')::date AS day)" +
        " SELECT to_char(d.day, 'YYYY-MM-DD') AS day, COUNT(l.id)::int AS calls," +
        ' COALESCE(SUM(l.total_tokens), 0)::bigint AS tokens, COALESCE(SUM(l.cost_inr), 0)::float AS cost_inr,' +
        " COUNT(l.id) FILTER (WHERE l.status = 'error')::int AS errors," +
        " COUNT(l.id) FILTER (WHERE l.feature = 'mansi_chat')::int AS chat," +
        " COUNT(l.id) FILTER (WHERE l.feature IN ('meal_scan', 'label_scan'))::int AS scans" +
        ' FROM d LEFT JOIN ai_usage_logs l ON (l.created_at AT TIME ZONE $1)::date = d.day' +
        ' GROUP BY d.day ORDER BY d.day',
      [tz, days],
    ),
    query(
      'SELECT l.user_id, u.name, u.phone, COUNT(*)::int AS calls, COALESCE(SUM(l.total_tokens), 0)::bigint AS tokens,' +
        ' COALESCE(SUM(l.cost_inr), 0)::float AS cost_inr' +
        ' FROM ai_usage_logs l LEFT JOIN users u ON u.id = l.user_id' +
        ' WHERE ' + inPeriod('l.created_at') + ' AND l.user_id IS NOT NULL' +
        ' GROUP BY l.user_id, u.name, u.phone ORDER BY cost_inr DESC LIMIT 15',
      [tz, days],
    ),
    queryOne(
      'SELECT COUNT(*)::int AS calls, COALESCE(SUM(cost_inr), 0)::float AS cost_inr FROM ai_usage_logs' +
        ' WHERE (created_at AT TIME ZONE $1)::date = (now() AT TIME ZONE $1)::date',
      [tz],
    ),
    queryOne(
      'SELECT COUNT(*)::int AS calls, COALESCE(SUM(cost_inr), 0)::float AS cost_inr FROM ai_usage_logs' +
        " WHERE created_at >= date_trunc('month', now() AT TIME ZONE $1) AT TIME ZONE $1",
      [tz],
    ),
  ]);
  // Run-rate projection for a 30-day month from the last 7 days.
  const recent = series.slice(-7);
  const last7 = recent.reduce((a, d) => a + Number(d.costInr), 0);
  res.json({
    days,
    totals,
    today,
    month,
    projectedMonthInr: Math.round((last7 / Math.max(1, recent.length)) * 30 * 100) / 100,
    byFeature,
    byModel,
    series,
    topUsers,
    pricing: {
      usdInr: USD_INR,
      models: AI_PRICES,
      note: 'Estimated from OpenAI token counts at list prices; your OpenAI bill is the source of truth.',
    },
  });
});

/** GET /admin/insights/ai/logs?feature=&status=&userId=&q=&before=&limit= — individual calls, newest first. */
router.get('/ai/logs', async (req, res) => {
  const f = validate(
    z.object({
      feature: z.enum(AI_FEATURES).optional(),
      status: z.enum(['ok', 'error', 'declined']).optional(),
      userId: uuid.optional(),
      q: z.string().trim().max(80).optional(),
      before: z.coerce.number().int().positive().optional(),
      limit: z.coerce.number().int().min(1).max(200).default(50),
    }),
    req.query,
  );
  const where = ['TRUE'];
  const params = [];
  const p = (v) => {
    params.push(v);
    return '$' + params.length;
  };
  if (f.feature) where.push('l.feature = ' + p(f.feature));
  if (f.status) where.push('l.status = ' + p(f.status));
  if (f.userId) where.push('l.user_id = ' + p(f.userId));
  if (f.q) {
    const qp = p(f.q);
    where.push(
      "(l.input_preview ILIKE '%' || " + qp + " || '%' OR l.output_preview ILIKE '%' || " + qp + " || '%' OR u.name ILIKE '%' || " + qp + " || '%')",
    );
  }
  if (f.before) where.push('l.id < ' + p(f.before));
  const logs = await query(
    'SELECT l.id, l.created_at, l.user_id, u.name AS user_name, u.phone AS user_phone, l.feature, l.model, l.status,' +
      ' l.http_status, l.error, l.prompt_tokens, l.completion_tokens, l.total_tokens, l.cost_usd::float AS cost_usd,' +
      ' l.cost_inr::float AS cost_inr, l.latency_ms, l.has_image, l.input_preview, l.output_preview' +
      ' FROM ai_usage_logs l LEFT JOIN users u ON u.id = l.user_id' +
      ' WHERE ' + where.join(' AND ') + ' ORDER BY l.id DESC LIMIT ' + p(f.limit),
    params,
  );
  res.json({ logs, nextBefore: logs.length === f.limit ? logs[logs.length - 1].id : null });
});

// ------------------------------------------------------------------------------------------------ actions
router.post('/users/:id/suspend', async (req, res) => {
  const id = validate(uuid, req.params.id);
  const b = validate(z.object({ suspended: z.boolean(), reason: z.string().trim().max(300).optional() }), req.body ?? {});
  const user = await queryOne(
    `UPDATE users SET is_suspended = $2, suspended_reason = CASE WHEN $2 THEN $3 ELSE NULL END,
       suspended_at = CASE WHEN $2 THEN now() ELSE NULL END, updated_at = now()
     WHERE id = $1 AND role <> 'admin' RETURNING id, name, is_suspended, suspended_reason, suspended_at`,
    [id, b.suspended, b.reason ?? null],
  );
  if (!user) throw notFound('User not found');
  forgetSeen(id);
  res.json({ user });
});

router.post('/users/:id/notify', async (req, res) => {
  const id = validate(uuid, req.params.id);
  const b = validate(z.object({ title: z.string().trim().min(2).max(120), body: z.string().trim().max(500).optional() }), req.body ?? {});
  const exists = await queryOne(`SELECT id FROM users WHERE id = $1`, [id]);
  if (!exists) throw notFound('User not found');
  await notify(id, { type: 'admin_message', title: b.title, body: b.body ?? null, data: { from: 'fitkey' } });
  res.json({ sent: true });
});

router.post('/users/:id/coins', async (req, res) => {
  const id = validate(uuid, req.params.id);
  const b = validate(
    z.object({ amount: z.number().int().min(-100000).max(100000).refine((n) => n !== 0, 'Amount cannot be 0'), note: z.string().trim().min(3).max(160) }),
    req.body ?? {},
  );
  const exists = await queryOne(`SELECT id FROM users WHERE id = $1 AND role = 'user'`, [id]);
  if (!exists) throw notFound('Member not found');
  if (b.amount < 0) {
    const w = await balances(id);
    if ((w?.referral ?? 0) + b.amount < 0) throw badRequest(`They only have ${w?.referral ?? 0} bonus coins`);
  }
  await query(
    `INSERT INTO coin_ledger (user_id, amount, kind, wallet, status, unlocked_at, note)
     VALUES ($1, $2, 'adjustment', 'referral', 'available', now(), $3)`,
    [id, b.amount, `Admin: ${b.note}`],
  );
  if (b.amount > 0) {
    await notify(id, { type: 'coins_admin', title: `${b.amount} bonus coins added`, body: b.note, data: { screen: 'wallet' } });
  }
  res.status(201).json({ balances: await balances(id) });
});

export default router;

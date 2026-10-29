import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { HttpError, badRequest, conflict, forbidden, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { dateSchema, phoneSchema, uuidSchema } from '../utils/schemas.js';

/**
 * Corporate Dashboard API (BRD §10) — mounted at /api/v1/corporate.
 *
 * Auth: HR admins sign in with the normal member OTP (role 'user'). Every /orgs/:orgId/* route then checks
 * corporate_admins for that org (owner > admin > viewer). The FITKEY team creates orgs through /admin/* (role 'admin').
 *
 * PRIVACY RULE: HR sees usage (passes, check-ins, centres) and participation (events) only. No query in this file
 * touches weight_logs, meal_logs, user_goals, step_logs or any other health / nutrition table. Running km is read
 * from activity_logs ONLY to score running events the employee chose to join, and only inside the event window.
 */
const router = Router();

const ROLE_RANK = { viewer: 1, admin: 2, owner: 3 };
const FREE_EMAIL_DOMAINS = new Set([
  'gmail.com', 'googlemail.com', 'yahoo.com', 'yahoo.co.in', 'outlook.com', 'hotmail.com', 'live.com', 'icloud.com',
  'me.com', 'aol.com', 'proton.me', 'protonmail.com', 'rediffmail.com', 'zoho.com', 'gmx.com', 'mail.com', 'yandex.com',
]);
const METRIC_UNITS = { checkins: 'days', running_km: 'km', streak: 'day streak', attendance: 'attended', arena_reps: 'reps' };

const emailSchema = z.string().trim().toLowerCase().email('Enter a valid email').max(255);
const domainSchema = z
  .string()
  .trim()
  .toLowerCase()
  .transform((s) => s.replace(/^@/, ''))
  .refine((s) => /^(?=.{3,120}$)([a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/.test(s), 'Enter a domain like company.com');
const optText = (max) => z.string().trim().max(max).optional().nullable().transform((v) => (v ? v : null));

const newToken = () => crypto.randomBytes(24).toString('base64url');
const newInviteCode = () => crypto.randomBytes(5).toString('hex').toUpperCase();
const todaySql = `(now() AT TIME ZONE '${config.tz.replace(/'/g, '')}')::date`;

/** Logs what would be emailed — there is no email provider yet. */
function logEmail(to, subject, body) {
  console.log(`[corporate-email] (not sent — no email provider) To: ${to} | ${subject}\n  ${body}`);
}

function joinLink(req, token) {
  return `${req.protocol}://${req.get('host')}/corporate/join.html?token=${encodeURIComponent(token)}`;
}

/** requireAuth('user') + corporate_admins check for :orgId with at least `min` role. Sets req.org, req.hrRole. */
function hr(min = 'viewer') {
  return [
    requireAuth('user'),
    async (req, _res, next) => {
      if (!uuidSchema.safeParse(req.params.orgId).success) throw notFound('Organisation not found');
      const row = await queryOne(
        `SELECT o.id, o.name, o.kind, o.logo_url, o.invite_code, ca.role
         FROM corporate_admins ca JOIN orgs o ON o.id = ca.org_id
         WHERE ca.org_id = $1 AND ca.user_id = $2`,
        [req.params.orgId, req.user.id],
      );
      if (!row) throw forbidden('You are not an HR admin of this organisation');
      if (ROLE_RANK[row.role] < ROLE_RANK[min]) throw forbidden(`This action needs the ${min} role`);
      req.org = row;
      req.hrRole = row.role;
      next();
    },
  ];
}

/* ============================================================== FITKEY team (role admin) */

const createOrgSchema = z.object({
  name: z.string().trim().min(2).max(120),
  kind: z.enum(['company', 'college']).default('company'),
  ownerPhone: phoneSchema,
  ownerName: optText(120),
  domains: z.array(domainSchema).max(10).default([]),
});

/**
 * POST /corporate/admin/orgs { name, kind, ownerPhone, ownerName?, domains? } — FITKEY team onboards a company:
 * creates the org and makes the phone number its HR owner (they sign in to /corporate with that phone's OTP).
 */
router.post('/admin/orgs', requireAuth('admin'), async (req, res) => {
  const body = validate(createOrgSchema, req.body);
  for (const d of body.domains) if (FREE_EMAIL_DOMAINS.has(d)) throw badRequest(`${d} is a public email domain`);
  const result = await withTransaction(async (client) => {
    const org = await queryOne(
      `INSERT INTO orgs (name, kind, invite_code) VALUES ($1, $2, $3) RETURNING *`,
      [body.name, body.kind, newInviteCode()],
      client,
    );
    for (const d of body.domains) {
      const taken = await queryOne(`SELECT org_id FROM org_domains WHERE domain = $1`, [d], client);
      if (taken) throw conflict(`${d} already belongs to another organisation`);
      await client.query(`INSERT INTO org_domains (domain, org_id) VALUES ($1, $2)`, [d, org.id]);
    }
    const owner = await queryOne(
      `INSERT INTO users (phone, role, name) VALUES ($1, 'user', $2)
       ON CONFLICT (phone, role) DO UPDATE SET name = COALESCE(users.name, EXCLUDED.name), updated_at = now()
       RETURNING id, phone, name`,
      [body.ownerPhone, body.ownerName],
      client,
    );
    await client.query(
      `INSERT INTO corporate_admins (org_id, user_id, role, added_by) VALUES ($1, $2, 'owner', $3)`,
      [org.id, owner.id, req.user.id],
    );
    await client.query(`INSERT INTO corporate_org_profiles (org_id) VALUES ($1) ON CONFLICT DO NOTHING`, [org.id]);
    return { org, owner };
  });
  res.status(201).json({ ...result, domains: body.domains, dashboardUrl: `${req.protocol}://${req.get('host')}/corporate/` });
});

/** GET /corporate/admin/orgs — every org with HR admin / member counts. */
router.get('/admin/orgs', requireAuth('admin'), async (_req, res) => {
  const orgs = await query(
    `SELECT o.id, o.name, o.kind, o.invite_code, o.created_at,
       (SELECT COUNT(*) FROM corporate_admins ca WHERE ca.org_id = o.id) AS admin_count,
       (SELECT COUNT(*) FROM org_memberships om WHERE om.org_id = o.id AND om.status = 'verified') AS member_count,
       COALESCE((SELECT array_agg(d.domain ORDER BY d.domain) FROM org_domains d WHERE d.org_id = o.id), '{}') AS domains
     FROM orgs o ORDER BY o.created_at DESC`,
  );
  res.json({ orgs });
});

/** POST /corporate/admin/orgs/:orgId/admins { phone, role, name? } — FITKEY team adds an HR admin (support). */
router.post('/admin/orgs/:orgId/admins', requireAuth('admin'), async (req, res) => {
  const body = validate(
    z.object({ phone: phoneSchema, role: z.enum(['owner', 'admin', 'viewer']).default('admin'), name: optText(120) }),
    req.body,
  );
  const org = await queryOne(`SELECT id FROM orgs WHERE id = $1`, [req.params.orgId]);
  if (!org) throw notFound('Organisation not found');
  const admin = await upsertAdmin(org.id, body, req.user.id);
  res.status(201).json({ admin });
});

async function upsertAdmin(orgId, { phone, role, name }, addedBy) {
  const user = await queryOne(
    `INSERT INTO users (phone, role, name) VALUES ($1, 'user', $2)
     ON CONFLICT (phone, role) DO UPDATE SET name = COALESCE(users.name, EXCLUDED.name), updated_at = now()
     RETURNING id, phone, name`,
    [phone, name ?? null],
  );
  await query(
    `INSERT INTO corporate_admins (org_id, user_id, role, added_by) VALUES ($1, $2, $3, $4)
     ON CONFLICT (org_id, user_id) DO UPDATE SET role = EXCLUDED.role`,
    [orgId, user.id, role, addedBy],
  );
  return { userId: user.id, phone: user.phone, name: user.name, role };
}

/* ============================================================== public invite links */

/** GET /corporate/join/:token — what an invite link is for (no auth; shows org name + masked email). */
router.get('/join/:token', async (req, res) => {
  const inv = await queryOne(
    `SELECT i.email, i.status, o.name AS org_name, o.kind AS org_kind, o.logo_url
     FROM corporate_invites i JOIN orgs o ON o.id = i.org_id WHERE i.token = $1`,
    [req.params.token],
  );
  if (!inv) throw notFound('This invite link is not valid');
  const [local, domain] = inv.email.split('@');
  res.json({
    invite: {
      status: inv.status,
      email: `${local.slice(0, 2)}${'•'.repeat(Math.max(1, local.length - 2))}@${domain}`,
      org: { name: inv.orgName, kind: inv.orgKind, logoUrl: inv.logoUrl },
    },
  });
});

/**
 * POST /corporate/join/:token — the signed-in member accepts an HR invite. Creates a verified org membership
 * (method hr_invite); the DB trigger then activates any pass HR assigned to that email.
 */
router.post('/join/:token', requireAuth('user'), async (req, res) => {
  const inv = await queryOne(`SELECT * FROM corporate_invites WHERE token = $1`, [req.params.token]);
  if (!inv) throw notFound('This invite link is not valid');
  if (inv.status === 'revoked') throw new HttpError(410, 'This invite was withdrawn by your HR team');
  if (inv.status === 'accepted' && inv.acceptedUserId !== req.user.id) throw conflict('This invite was already used');
  await query(
    `INSERT INTO org_memberships (org_id, user_id, work_email, method, status, department, verified_at)
     VALUES ($1, $2, $3, 'hr_invite', 'verified', $4, now())
     ON CONFLICT (org_id, user_id) DO UPDATE
       SET status = 'verified', work_email = EXCLUDED.work_email, method = 'hr_invite', verified_at = now(),
           department = COALESCE(org_memberships.department, EXCLUDED.department)`,
    [inv.orgId, req.user.id, inv.email, inv.department],
  );
  await query(
    `UPDATE corporate_invites SET status = 'accepted', accepted_user_id = $2, accepted_at = COALESCE(accepted_at, now())
     WHERE id = $1`,
    [inv.id, req.user.id],
  );
  if (inv.name) await query(`UPDATE users SET name = $2 WHERE id = $1 AND name IS NULL`, [req.user.id, inv.name]);
  const org = await queryOne(`SELECT id, name, kind FROM orgs WHERE id = $1`, [inv.orgId]);
  const passes = await query(
    `SELECT p.name AS plan_name, s.ends_at FROM corporate_pass_assignments a
     JOIN subscriptions s ON s.id = a.subscription_id JOIN plans p ON p.id = a.plan_id
     WHERE a.org_id = $1 AND a.user_id = $2 AND a.status = 'active' AND s.ends_at > now()`,
    [inv.orgId, req.user.id],
  );
  res.json({ joined: true, org, passes });
});

/* ============================================================== HR: who am I */

/** GET /corporate/me — the signed-in user and the orgs they administer. */
router.get('/me', requireAuth('user'), async (req, res) => {
  const user = await queryOne(`SELECT id, name, phone, avatar_url FROM users WHERE id = $1`, [req.user.id]);
  const orgs = await query(
    `SELECT o.id, o.name, o.kind, o.logo_url, o.invite_code, ca.role FROM corporate_admins ca JOIN orgs o ON o.id = ca.org_id
     WHERE ca.user_id = $1 ORDER BY o.name`,
    [req.user.id],
  );
  res.json({ user, orgs, paymentsMode: config.paymentsMode });
});

/* ============================================================== org profile, domains, HR admins */

router.get('/orgs/:orgId', hr(), async (req, res) => {
  const profile = await queryOne(`SELECT * FROM corporate_org_profiles WHERE org_id = $1`, [req.org.id]);
  const domains = await query(`SELECT domain FROM org_domains WHERE org_id = $1 ORDER BY domain`, [req.org.id]);
  res.json({
    org: { ...req.org, role: undefined },
    myRole: req.hrRole,
    profile: profile ?? { orgId: req.org.id },
    domains: domains.map((d) => d.domain),
  });
});

const profileSchema = z.object({
  name: z.string().trim().min(2).max(120).optional(),
  kind: z.enum(['company', 'college']).optional(),
  logoUrl: optText(500),
  legalName: optText(160),
  industry: optText(80),
  city: optText(80),
  address: optText(400),
  billingEmail: z.union([emailSchema, z.literal(''), z.null()]).optional().transform((v) => (v ? v : null)),
  gstin: z
    .string()
    .trim()
    .toUpperCase()
    .optional()
    .nullable()
    .refine((v) => !v || /^[0-9A-Z]{15}$/.test(v), 'GSTIN is 15 letters/digits')
    .transform((v) => (v ? v : null)),
  employeeCount: z.coerce.number().int().min(0).max(10_000_000).optional().nullable(),
});

router.patch('/orgs/:orgId', hr('admin'), async (req, res) => {
  const b = validate(profileSchema, req.body);
  await query(
    `UPDATE orgs SET name = COALESCE($2, name), kind = COALESCE($3, kind),
       logo_url = CASE WHEN $4::boolean THEN $5 ELSE logo_url END WHERE id = $1`,
    [req.org.id, b.name ?? null, b.kind ?? null, 'logoUrl' in req.body, b.logoUrl ?? null],
  );
  await query(
    `INSERT INTO corporate_org_profiles (org_id, legal_name, industry, city, address, billing_email, gstin, employee_count, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now())
     ON CONFLICT (org_id) DO UPDATE SET legal_name = $2, industry = $3, city = $4, address = $5, billing_email = $6,
       gstin = $7, employee_count = $8, updated_at = now()`,
    [req.org.id, b.legalName, b.industry, b.city, b.address, b.billingEmail, b.gstin, b.employeeCount ?? null],
  );
  res.json({ ok: true });
});

/** POST /orgs/:orgId/invite-code — rotate the org's join code (members can join with it in the app). */
router.post('/orgs/:orgId/invite-code', hr('admin'), async (req, res) => {
  const row = await queryOne(`UPDATE orgs SET invite_code = $2 WHERE id = $1 RETURNING invite_code`, [
    req.org.id,
    newInviteCode(),
  ]);
  res.json({ inviteCode: row.inviteCode });
});

router.post('/orgs/:orgId/domains', hr('admin'), async (req, res) => {
  const { domain } = validate(z.object({ domain: domainSchema }), req.body);
  if (FREE_EMAIL_DOMAINS.has(domain)) throw badRequest(`${domain} is a public email provider — use your company domain`);
  const taken = await queryOne(`SELECT org_id FROM org_domains WHERE domain = $1`, [domain]);
  if (taken && taken.orgId !== req.org.id) throw conflict(`${domain} is already linked to another organisation`);
  await query(`INSERT INTO org_domains (domain, org_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [domain, req.org.id]);
  res.status(201).json({ domain });
});

router.delete('/orgs/:orgId/domains/:domain', hr('admin'), async (req, res) => {
  await query(`DELETE FROM org_domains WHERE domain = $1 AND org_id = $2`, [req.params.domain.toLowerCase(), req.org.id]);
  res.status(204).end();
});

router.get('/orgs/:orgId/admins', hr(), async (req, res) => {
  const admins = await query(
    `SELECT ca.user_id, ca.role, ca.created_at, u.name, u.phone FROM corporate_admins ca JOIN users u ON u.id = ca.user_id
     WHERE ca.org_id = $1 ORDER BY CASE ca.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, u.name`,
    [req.org.id],
  );
  res.json({ admins, me: req.user.id });
});

router.post('/orgs/:orgId/admins', hr('owner'), async (req, res) => {
  const body = validate(
    z.object({ phone: phoneSchema, role: z.enum(['owner', 'admin', 'viewer']).default('admin'), name: optText(120) }),
    req.body,
  );
  const admin = await upsertAdmin(req.org.id, body, req.user.id);
  console.log(`[corporate] ${body.phone} added as ${body.role} HR admin of ${req.org.name} — they sign in at /corporate`);
  res.status(201).json({ admin });
});

async function ensureAnotherOwner(orgId, userId) {
  const row = await queryOne(
    `SELECT COUNT(*) AS n FROM corporate_admins WHERE org_id = $1 AND role = 'owner' AND user_id <> $2`,
    [orgId, userId],
  );
  if (!row.n) throw badRequest('An organisation needs at least one owner');
}

router.patch('/orgs/:orgId/admins/:userId', hr('owner'), async (req, res) => {
  const { role } = validate(z.object({ role: z.enum(['owner', 'admin', 'viewer']) }), req.body);
  if (role !== 'owner') await ensureAnotherOwner(req.org.id, req.params.userId);
  const row = await queryOne(
    `UPDATE corporate_admins SET role = $3 WHERE org_id = $1 AND user_id = $2 RETURNING user_id`,
    [req.org.id, req.params.userId, role],
  );
  if (!row) throw notFound('HR admin not found');
  res.json({ ok: true });
});

router.delete('/orgs/:orgId/admins/:userId', hr('owner'), async (req, res) => {
  await ensureAnotherOwner(req.org.id, req.params.userId);
  await query(`DELETE FROM corporate_admins WHERE org_id = $1 AND user_id = $2`, [req.org.id, req.params.userId]);
  res.status(204).end();
});

/* ============================================================== overview */

router.get('/orgs/:orgId/overview', hr(), async (req, res) => {
  const id = req.org.id;
  const kpis = await queryOne(
    `WITH m AS (SELECT user_id FROM org_memberships WHERE org_id = $1 AND status = 'verified'), t AS (SELECT ${todaySql} AS d)
     SELECT
       (SELECT COUNT(*) FROM m) AS members,
       (SELECT COUNT(*) FROM corporate_invites WHERE org_id = $1 AND status = 'pending') AS pending_invites,
       (SELECT COUNT(DISTINCT c.user_id) FROM checkins c, t WHERE c.user_id IN (SELECT user_id FROM m)
          AND c.checkin_date > t.d - 30) AS active_30d,
       (SELECT COUNT(*) FROM checkins c, t WHERE c.user_id IN (SELECT user_id FROM m) AND c.checkin_date > t.d - 30) AS checkins_30d,
       (SELECT COUNT(*) FROM checkins c, t WHERE c.user_id IN (SELECT user_id FROM m)
          AND c.checkin_date BETWEEN t.d - 59 AND t.d - 30) AS checkins_prev_30d,
       (SELECT COUNT(*) FROM corporate_pass_assignments a JOIN subscriptions s ON s.id = a.subscription_id
          WHERE a.org_id = $1 AND a.status = 'active' AND s.status = 'active' AND s.ends_at > now()) AS active_passes,
       (SELECT COUNT(*) FROM corporate_pass_assignments WHERE org_id = $1 AND status = 'pending') AS pending_passes,
       (SELECT COUNT(*) FROM corporate_pass_assignments a JOIN subscriptions s ON s.id = a.subscription_id
          WHERE a.org_id = $1 AND a.status = 'active' AND s.status = 'active'
            AND s.ends_at BETWEEN now() AND now() + interval '14 days') AS renewals_due,
       (SELECT COUNT(*) FROM corporate_battle_invites WHERE to_org_id = $1 AND status = 'pending') AS battle_invites,
       (SELECT COUNT(*) FROM contests c, t WHERE (c.org_id = $1 OR EXISTS
          (SELECT 1 FROM contest_orgs co WHERE co.contest_id = c.id AND co.org_id = $1)) AND c.ends_on >= t.d) AS live_events`,
    [id],
  );
  const seats = await seatInventory(id);
  kpis.seatsAvailable = seats.reduce((s, r) => s + r.available, 0);
  const series = await query(
    `WITH m AS (SELECT user_id FROM org_memberships WHERE org_id = $1 AND status = 'verified'),
          days AS (SELECT generate_series(${todaySql} - 29, ${todaySql}, interval '1 day')::date AS d)
     SELECT days.d AS date, COUNT(c.id) AS checkins, COUNT(DISTINCT c.user_id) AS employees
     FROM days LEFT JOIN checkins c ON c.checkin_date = days.d AND c.user_id IN (SELECT user_id FROM m)
     GROUP BY days.d ORDER BY days.d`,
    [id],
  );
  const events = await listEvents(id, 'live', 4);
  res.json({ kpis, series, events });
});

/* ============================================================== members & invites */

router.get('/orgs/:orgId/members', hr(), async (req, res) => {
  const { status, q, department } = validate(
    z.object({
      status: z.enum(['verified', 'removed', 'pending']).default('verified'),
      q: z.string().trim().max(80).optional(),
      department: z.string().trim().max(80).optional(),
    }),
    req.query,
  );
  const members = await query(
    `SELECT om.user_id, u.name, u.avatar_url, om.work_email, om.department, om.method, om.status, om.verified_at,
       (SELECT COUNT(*) FROM checkins c WHERE c.user_id = om.user_id AND c.checkin_date > ${todaySql} - 30) AS checkins_30d,
       (SELECT MAX(c.checkin_date) FROM checkins c WHERE c.user_id = om.user_id) AS last_checkin,
       (SELECT COUNT(*) FROM contest_participants cp JOIN contests ct ON ct.id = cp.contest_id
          WHERE cp.user_id = om.user_id AND (ct.org_id = om.org_id OR cp.org_id = om.org_id)) AS events_joined,
       (SELECT json_build_object('assignmentId', a.id, 'planName', p.name, 'endsAt', s.ends_at, 'startsAt', s.starts_at)
          FROM corporate_pass_assignments a JOIN subscriptions s ON s.id = a.subscription_id JOIN plans p ON p.id = a.plan_id
          WHERE a.org_id = om.org_id AND a.user_id = om.user_id AND a.status = 'active' AND s.status = 'active'
            AND s.ends_at > now() ORDER BY s.ends_at DESC LIMIT 1) AS pass
     FROM org_memberships om JOIN users u ON u.id = om.user_id
     WHERE om.org_id = $1 AND om.status = $2
       AND ($3::text IS NULL OR u.name ILIKE '%' || $3 || '%' OR om.work_email ILIKE '%' || $3 || '%')
       AND ($4::text IS NULL OR om.department = $4)
     ORDER BY u.name NULLS LAST, om.work_email LIMIT 2000`,
    [req.org.id, status, q || null, department || null],
  );
  const departments = await query(
    `SELECT DISTINCT department FROM org_memberships WHERE org_id = $1 AND department IS NOT NULL ORDER BY department`,
    [req.org.id],
  );
  res.json({ members, departments: departments.map((d) => d.department) });
});

router.patch('/orgs/:orgId/members/:userId', hr('admin'), async (req, res) => {
  const { department } = validate(z.object({ department: optText(80) }), req.body);
  const row = await queryOne(
    `UPDATE org_memberships SET department = $3 WHERE org_id = $1 AND user_id = $2 RETURNING user_id`,
    [req.org.id, req.params.userId, department],
  );
  if (!row) throw notFound('Member not found');
  res.json({ ok: true });
});

/** DELETE /orgs/:orgId/members/:userId — removes the member (status 'removed') and revokes their company passes. */
router.delete('/orgs/:orgId/members/:userId', hr('admin'), async (req, res) => {
  const revoked = await withTransaction(async (client) => {
    const row = await queryOne(
      `UPDATE org_memberships SET status = 'removed' WHERE org_id = $1 AND user_id = $2 AND status <> 'removed'
       RETURNING user_id`,
      [req.org.id, req.params.userId],
      client,
    );
    if (!row) throw notFound('Member not found');
    const passes = await query(
      `SELECT id FROM corporate_pass_assignments WHERE org_id = $1 AND user_id = $2 AND status IN ('pending', 'active')`,
      [req.org.id, req.params.userId],
      client,
    );
    for (const p of passes) await revokeAssignment(client, req.org.id, p.id);
    return passes.length;
  });
  await notify(req.params.userId, {
    type: 'corporate_removed',
    title: `You were removed from ${req.org.name}`,
    body: revoked ? 'Your company FITKEY pass has ended.' : null,
    data: { orgId: req.org.id },
  });
  res.json({ removed: true, passesRevoked: revoked });
});

router.get('/orgs/:orgId/invites', hr(), async (req, res) => {
  const { status } = validate(z.object({ status: z.enum(['pending', 'accepted', 'revoked']).default('pending') }), req.query);
  const invites = await query(
    `SELECT i.id, i.email, i.name, i.department, i.token, i.status, i.last_sent_at, i.created_at, i.accepted_at,
       (SELECT p.name FROM corporate_pass_assignments a JOIN plans p ON p.id = a.plan_id
          WHERE a.org_id = i.org_id AND lower(a.email) = lower(i.email) AND a.status = 'pending' LIMIT 1) AS pending_pass
     FROM corporate_invites i WHERE i.org_id = $1 AND i.status = $2 ORDER BY i.created_at DESC LIMIT 2000`,
    [req.org.id, status],
  );
  res.json({ invites: invites.map((i) => ({ ...i, link: joinLink(req, i.token) })) });
});

const inviteRowSchema = z.object({ email: emailSchema, name: optText(120), department: optText(80) });

/**
 * Creates invites for rows (already validated). Skips people who are already verified members or already invited.
 * Optionally queues a pass of planId for each new invite (as long as seats remain).
 */
async function createInvites(req, rows, planId) {
  const orgId = req.org.id;
  const domains = new Set((await query(`SELECT domain FROM org_domains WHERE org_id = $1`, [orgId])).map((d) => d.domain));
  const created = [];
  const skipped = [];
  const seen = new Set();
  await withTransaction(async (client) => {
    await client.query(`SELECT id FROM orgs WHERE id = $1 FOR UPDATE`, [orgId]);
    let seatsLeft = planId ? (await seatInventory(orgId, client)).find((s) => s.planId === planId)?.available ?? 0 : 0;
    if (planId && seatsLeft <= 0) throw badRequest('No unassigned passes left for that plan — buy more first');
    for (const r of rows) {
      if (seen.has(r.email)) {
        skipped.push({ email: r.email, reason: 'Duplicate row' });
        continue;
      }
      seen.add(r.email);
      const member = await queryOne(
        `SELECT 1 FROM org_memberships WHERE org_id = $1 AND lower(work_email) = $2 AND status = 'verified'`,
        [orgId, r.email],
        client,
      );
      if (member) {
        skipped.push({ email: r.email, reason: 'Already a verified member' });
        continue;
      }
      const existing = await queryOne(
        `SELECT id FROM corporate_invites WHERE org_id = $1 AND lower(email) = $2 AND status = 'pending'`,
        [orgId, r.email],
        client,
      );
      if (existing) {
        skipped.push({ email: r.email, reason: 'Already invited' });
        continue;
      }
      const inv = await queryOne(
        `INSERT INTO corporate_invites (org_id, email, name, department, token, invited_by)
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, email, name, department, token, status, created_at`,
        [orgId, r.email, r.name, r.department, newToken(), req.user.id],
        client,
      );
      let passQueued = false;
      if (planId && seatsLeft > 0) {
        await client.query(
          `INSERT INTO corporate_pass_assignments (org_id, plan_id, email, status, assigned_by) VALUES ($1, $2, $3, 'pending', $4)`,
          [orgId, planId, r.email, req.user.id],
        );
        seatsLeft -= 1;
        passQueued = true;
      }
      created.push({
        ...inv,
        link: joinLink(req, inv.token),
        outsideDomain: !domains.has(r.email.split('@')[1]),
        passQueued,
      });
    }
  });
  for (const inv of created) {
    logEmail(
      inv.email,
      `${req.org.name} invited you to FITKEY`,
      `Join with your work email in the FITKEY app (domain verification) or open ${inv.link}` +
        (inv.passQueued ? ' — a company pass is waiting for you.' : ''),
    );
  }
  return { created, skipped };
}

router.post('/orgs/:orgId/invites', hr('admin'), async (req, res) => {
  const body = validate(inviteRowSchema.extend({ planId: uuidSchema.optional().nullable() }), req.body);
  const result = await createInvites(req, [body], body.planId ?? null);
  if (!result.created.length) throw conflict(result.skipped[0]?.reason ?? 'Not invited');
  res.status(201).json({ invite: result.created[0] });
});

/** POST /orgs/:orgId/invites/bulk { rows: [{email, name?, department?}], planId? } — CSV upload (parsed in the browser). */
router.post('/orgs/:orgId/invites/bulk', hr('admin'), async (req, res) => {
  const body = validate(
    z.object({ rows: z.array(inviteRowSchema).min(1).max(2000), planId: uuidSchema.optional().nullable() }),
    req.body,
  );
  const result = await createInvites(req, body.rows, body.planId ?? null);
  res.status(201).json(result);
});

/** POST /orgs/:orgId/invites/:id/resend — no email provider: logs the email and returns the link to share. */
router.post('/orgs/:orgId/invites/:id/resend', hr('admin'), async (req, res) => {
  const inv = await queryOne(
    `UPDATE corporate_invites SET last_sent_at = now() WHERE id = $1 AND org_id = $2 AND status = 'pending'
     RETURNING email, token`,
    [req.params.id, req.org.id],
  );
  if (!inv) throw notFound('Pending invite not found');
  const link = joinLink(req, inv.token);
  logEmail(inv.email, `Reminder: ${req.org.name} invited you to FITKEY`, `Open ${link}`);
  res.json({ link, emailed: false });
});

router.delete('/orgs/:orgId/invites/:id', hr('admin'), async (req, res) => {
  await withTransaction(async (client) => {
    const inv = await queryOne(
      `UPDATE corporate_invites SET status = 'revoked' WHERE id = $1 AND org_id = $2 AND status = 'pending' RETURNING email`,
      [req.params.id, req.org.id],
      client,
    );
    if (!inv) throw notFound('Pending invite not found');
    await client.query(
      `UPDATE corporate_pass_assignments SET status = 'revoked', revoked_at = now()
       WHERE org_id = $1 AND lower(email) = lower($2) AND status = 'pending' AND user_id IS NULL`,
      [req.org.id, inv.email],
    );
  });
  res.status(204).end();
});

/* ============================================================== passes & orders */

/** Seats per plan: bought (paid / mock-paid orders) minus used (pending + active + activated-then-revoked). */
async function seatInventory(orgId, client) {
  return query(
    `WITH bought AS (
       SELECT plan_id, SUM(quantity)::int AS total FROM corporate_orders
       WHERE org_id = $1 AND status IN ('mock_paid', 'paid') GROUP BY plan_id
     ), used AS (
       SELECT plan_id,
         COUNT(*) FILTER (WHERE status = 'pending')::int AS pending,
         COUNT(*) FILTER (WHERE status = 'active')::int AS active,
         COUNT(*) FILTER (WHERE status IN ('pending', 'active') OR activated_at IS NOT NULL)::int AS used
       FROM corporate_pass_assignments WHERE org_id = $1 GROUP BY plan_id
     )
     SELECT p.id AS plan_id, p.name AS plan_name, p.duration_days, p.price_paise, b.total,
            COALESCE(u.pending, 0) AS pending, COALESCE(u.active, 0) AS active,
            b.total - COALESCE(u.used, 0) AS available
     FROM bought b JOIN plans p ON p.id = b.plan_id LEFT JOIN used u ON u.plan_id = b.plan_id
     ORDER BY p.sort_order, p.price_paise`,
    [orgId],
    client,
  );
}

/** Cancels an assignment: pending → seat returns to the pool; active → its subscription is cancelled now. */
async function revokeAssignment(client, orgId, assignmentId) {
  const a = await queryOne(
    `UPDATE corporate_pass_assignments SET status = 'revoked', revoked_at = now()
     WHERE id = $1 AND org_id = $2 AND status IN ('pending', 'active') RETURNING *`,
    [assignmentId, orgId],
    client,
  );
  if (!a) throw notFound('Pass not found or already revoked');
  if (a.subscriptionId) {
    await client.query(`UPDATE subscriptions SET status = 'cancelled' WHERE id = $1 AND status = 'active'`, [a.subscriptionId]);
  }
  return a;
}

router.get('/orgs/:orgId/passes', hr(), async (req, res) => {
  const { status } = validate(z.object({ status: z.enum(['active', 'pending', 'expired', 'revoked', 'all']).default('all') }), req.query);
  const inventory = await seatInventory(req.org.id);
  const assignments = await query(
    `SELECT * FROM (
       SELECT a.id, a.plan_id, p.name AS plan_name, a.user_id, u.name, COALESCE(om.work_email, a.email) AS email,
              om.department, a.assigned_at, a.activated_at, a.revoked_at, s.starts_at, s.ends_at,
              CASE WHEN a.status = 'active' AND (s.ends_at <= now() OR s.status <> 'active') THEN 'expired' ELSE a.status END AS state
       FROM corporate_pass_assignments a JOIN plans p ON p.id = a.plan_id
       LEFT JOIN users u ON u.id = a.user_id
       LEFT JOIN org_memberships om ON om.org_id = a.org_id AND om.user_id = a.user_id
       LEFT JOIN subscriptions s ON s.id = a.subscription_id
       WHERE a.org_id = $1
     ) x WHERE ($2 = 'all' OR x.state = $2)
     ORDER BY CASE x.state WHEN 'active' THEN 0 WHEN 'pending' THEN 1 WHEN 'expired' THEN 2 ELSE 3 END, x.ends_at NULLS LAST
     LIMIT 3000`,
    [req.org.id, status],
  );
  res.json({ inventory, assignments, paymentsMode: config.paymentsMode });
});

/**
 * POST /orgs/:orgId/orders { planId, quantity } — buy passes in bulk.
 * PAYMENTS_MODE=mock: the order is recorded as 'mock_paid' with a 'mock' invoice — no money is collected.
 */
router.post('/orgs/:orgId/orders', hr('admin'), async (req, res) => {
  const { planId, quantity } = validate(
    z.object({ planId: uuidSchema, quantity: z.coerce.number().int().min(1).max(10000) }),
    req.body,
  );
  if (config.paymentsMode !== 'mock') throw new HttpError(501, 'Payment gateway not configured');
  const plan = await queryOne(`SELECT id, name, price_paise FROM plans WHERE id = $1 AND is_active`, [planId]);
  if (!plan) throw notFound('Plan not found');
  const result = await withTransaction(async (client) => {
    const order = await queryOne(
      `INSERT INTO corporate_orders (org_id, plan_id, quantity, unit_price_paise, amount_paise, payment_mode, status, payment_ref, created_by)
       VALUES ($1, $2, $3, $4, $5, 'mock', 'mock_paid', $6, $7) RETURNING *`,
      [req.org.id, plan.id, quantity, plan.pricePaise, plan.pricePaise * quantity, `MOCK-${Date.now()}`, req.user.id],
      client,
    );
    const ymd = new Date().toISOString().slice(0, 10).replace(/-/g, '');
    const invoice = await queryOne(
      `INSERT INTO corporate_invoices (org_id, order_id, number, amount_paise, status, note)
       VALUES ($1, $2, $3, $4, 'mock', $5) RETURNING *`,
      [
        req.org.id,
        order.id,
        `FKC-${ymd}-${order.id.slice(0, 6).toUpperCase()}`,
        order.amountPaise,
        'Mock invoice: PAYMENTS_MODE=mock, no payment was collected. Not a tax invoice.',
      ],
      client,
    );
    return { order: { ...order, planName: plan.name }, invoice };
  });
  res.status(201).json(result);
});

router.get('/orgs/:orgId/orders', hr(), async (req, res) => {
  const orders = await query(
    `SELECT o.*, p.name AS plan_name, i.id AS invoice_id, i.number AS invoice_number, i.status AS invoice_status,
            u.name AS created_by_name
     FROM corporate_orders o JOIN plans p ON p.id = o.plan_id
     LEFT JOIN corporate_invoices i ON i.order_id = o.id LEFT JOIN users u ON u.id = o.created_by
     WHERE o.org_id = $1 ORDER BY o.created_at DESC`,
    [req.org.id],
  );
  res.json({ orders });
});

const assignSchema = z
  .object({
    planId: uuidSchema,
    userIds: z.array(uuidSchema).max(2000).default([]),
    emails: z.array(emailSchema).max(2000).default([]),
  })
  .refine((b) => b.userIds.length + b.emails.length > 0, 'Choose at least one employee');

/**
 * POST /orgs/:orgId/passes/assign { planId, userIds?, emails? } — gives passes from the bought pool.
 * Verified members get a subscription now; invited emails get a pending pass that activates when they verify.
 */
router.post('/orgs/:orgId/passes/assign', hr('admin'), async (req, res) => {
  const body = validate(assignSchema, req.body);
  const orgId = req.org.id;
  const plan = await queryOne(`SELECT id, name, duration_days FROM plans WHERE id = $1`, [body.planId]);
  if (!plan) throw notFound('Plan not found');
  const assigned = [];
  const skipped = [];
  const toNotify = [];
  await withTransaction(async (client) => {
    await client.query(`SELECT id FROM orgs WHERE id = $1 FOR UPDATE`, [orgId]);
    let seatsLeft = (await seatInventory(orgId, client)).find((s) => s.planId === plan.id)?.available ?? 0;

    // Resolve targets: user ids must be verified members; emails may be members or pending invites.
    const targets = [];
    for (const userId of new Set(body.userIds)) {
      const m = await queryOne(
        `SELECT om.user_id, om.work_email, u.name FROM org_memberships om JOIN users u ON u.id = om.user_id
         WHERE om.org_id = $1 AND om.user_id = $2 AND om.status = 'verified'`,
        [orgId, userId],
        client,
      );
      if (m) targets.push({ userId: m.userId, email: m.workEmail, label: m.name ?? m.workEmail });
      else skipped.push({ target: userId, reason: 'Not a verified member' });
    }
    for (const email of new Set(body.emails)) {
      const m = await queryOne(
        `SELECT user_id FROM org_memberships WHERE org_id = $1 AND lower(work_email) = $2 AND status = 'verified'`,
        [orgId, email],
        client,
      );
      if (m) {
        if (!targets.some((t) => t.userId === m.userId)) targets.push({ userId: m.userId, email, label: email });
        continue;
      }
      const inv = await queryOne(
        `SELECT id FROM corporate_invites WHERE org_id = $1 AND lower(email) = $2 AND status = 'pending'`,
        [orgId, email],
        client,
      );
      if (inv) targets.push({ userId: null, email, label: email });
      else skipped.push({ target: email, reason: 'Not a member or invited — invite them first' });
    }

    for (const t of targets) {
      const dup = await queryOne(
        `SELECT 1 FROM corporate_pass_assignments a LEFT JOIN subscriptions s ON s.id = a.subscription_id
         WHERE a.org_id = $1 AND a.plan_id = $2 AND (a.status = 'pending' OR (a.status = 'active' AND s.status = 'active'
               AND s.ends_at > now() + interval '14 days'))
           AND (($3::uuid IS NOT NULL AND a.user_id = $3) OR ($4::text IS NOT NULL AND lower(a.email) = lower($4)))`,
        [orgId, plan.id, t.userId, t.email],
        client,
      );
      if (dup) {
        skipped.push({ target: t.label, reason: 'Already has this pass (more than 14 days left)' });
        continue;
      }
      if (seatsLeft <= 0) {
        skipped.push({ target: t.label, reason: 'No unassigned passes left' });
        continue;
      }
      seatsLeft -= 1;
      if (!t.userId) {
        const a = await queryOne(
          `INSERT INTO corporate_pass_assignments (org_id, plan_id, email, status, assigned_by)
           VALUES ($1, $2, $3, 'pending', $4) RETURNING id, status`,
          [orgId, plan.id, t.email, req.user.id],
          client,
        );
        assigned.push({ ...a, target: t.label });
        continue;
      }
      // Same stacking rule as POST /subscriptions: a renewal starts when the current pass of that plan ends.
      await client.query(`SELECT id FROM users WHERE id = $1 FOR UPDATE`, [t.userId]);
      const latest = await queryOne(
        `SELECT MAX(ends_at) AS ends_at FROM subscriptions
         WHERE user_id = $1 AND plan_id = $2 AND status = 'active' AND ends_at > now()`,
        [t.userId, plan.id],
        client,
      );
      const startsAt = latest?.endsAt ?? new Date();
      const a = await queryOne(
        `INSERT INTO corporate_pass_assignments (org_id, plan_id, user_id, email, status, assigned_by, activated_at)
         VALUES ($1, $2, $3, $4, 'active', $5, now()) RETURNING id, status`,
        [orgId, plan.id, t.userId, t.email, req.user.id],
        client,
      );
      const sub = await queryOne(
        `INSERT INTO subscriptions (user_id, plan_id, status, starts_at, ends_at, amount_paise, payment_ref)
         VALUES ($1, $2, 'active', $3, $3::timestamptz + make_interval(days => $4), 0, $5) RETURNING id, starts_at, ends_at`,
        [t.userId, plan.id, startsAt, plan.durationDays, `CORP-${a.id}`],
        client,
      );
      await client.query(`UPDATE corporate_pass_assignments SET subscription_id = $2 WHERE id = $1`, [a.id, sub.id]);
      assigned.push({ ...a, target: t.label, startsAt: sub.startsAt, endsAt: sub.endsAt });
      toNotify.push({ userId: t.userId, subscriptionId: sub.id });
    }
  });
  for (const n of toNotify) {
    await notify(n.userId, {
      type: 'corporate_pass',
      title: `${req.org.name} gave you a ${plan.name} pass`,
      body: 'Your company FITKEY pass is active — check in at any covered centre.',
      data: { orgId, subscriptionId: n.subscriptionId },
    });
  }
  res.status(201).json({ assigned, skipped });
});

router.post('/orgs/:orgId/passes/:id/revoke', hr('admin'), async (req, res) => {
  const a = await withTransaction((client) => revokeAssignment(client, req.org.id, req.params.id));
  if (a.userId && a.subscriptionId) {
    await notify(a.userId, {
      type: 'corporate_pass_revoked',
      title: 'Your company pass has ended',
      body: `${req.org.name} has withdrawn your FITKEY pass.`,
      data: { orgId: req.org.id },
    });
  }
  res.json({ revoked: true, seatReturned: !a.activatedAt });
});

/* ============================================================== billing */

router.get('/orgs/:orgId/invoices', hr(), async (req, res) => {
  const invoices = await query(
    `SELECT i.*, o.quantity, o.unit_price_paise, o.payment_mode, o.status AS order_status, o.payment_ref, p.name AS plan_name
     FROM corporate_invoices i JOIN corporate_orders o ON o.id = i.order_id JOIN plans p ON p.id = o.plan_id
     WHERE i.org_id = $1 ORDER BY i.issued_at DESC`,
    [req.org.id],
  );
  res.json({ invoices });
});

router.get('/orgs/:orgId/invoices/:id', hr(), async (req, res) => {
  const invoice = await queryOne(
    `SELECT i.*, o.quantity, o.unit_price_paise, o.payment_mode, o.status AS order_status, o.payment_ref,
            p.name AS plan_name, p.duration_days, u.name AS created_by_name
     FROM corporate_invoices i JOIN corporate_orders o ON o.id = i.order_id JOIN plans p ON p.id = o.plan_id
     LEFT JOIN users u ON u.id = o.created_by
     WHERE i.org_id = $1 AND i.id = $2`,
    [req.org.id, req.params.id],
  );
  if (!invoice) throw notFound('Invoice not found');
  const profile = await queryOne(`SELECT * FROM corporate_org_profiles WHERE org_id = $1`, [req.org.id]);
  res.json({ invoice, org: { id: req.org.id, name: req.org.name }, profile });
});

/** GET /orgs/:orgId/renewals — company passes ending in the next 14 days (renewal reminders). */
router.get('/orgs/:orgId/renewals', hr(), async (req, res) => {
  const passes = await query(
    `SELECT a.id, a.plan_id, p.name AS plan_name, u.name, COALESCE(om.work_email, a.email) AS email, om.department, s.ends_at,
            CEIL(EXTRACT(EPOCH FROM (s.ends_at - now())) / 86400)::int AS days_left,
            EXISTS (SELECT 1 FROM subscriptions s2 WHERE s2.user_id = a.user_id AND s2.plan_id = a.plan_id
                    AND s2.status = 'active' AND s2.starts_at >= s.ends_at) AS renewed
     FROM corporate_pass_assignments a JOIN subscriptions s ON s.id = a.subscription_id JOIN plans p ON p.id = a.plan_id
     LEFT JOIN users u ON u.id = a.user_id
     LEFT JOIN org_memberships om ON om.org_id = a.org_id AND om.user_id = a.user_id
     WHERE a.org_id = $1 AND a.status = 'active' AND s.status = 'active'
       AND s.ends_at BETWEEN now() AND now() + interval '14 days'
     ORDER BY s.ends_at`,
    [req.org.id],
  );
  res.json({ passes });
});

/* ============================================================== events & battles */

const EVENT_STATE = `CASE WHEN c.starts_on > ${todaySql} THEN 'upcoming' WHEN c.ends_on < ${todaySql} THEN 'past' ELSE 'live' END`;

async function listEvents(orgId, scope = 'all', limit = 200) {
  const where = { all: 'TRUE', live: `c.ends_on >= ${todaySql}`, past: `c.ends_on < ${todaySql}` }[scope];
  const events = await query(
    `SELECT c.id, c.title, c.description, c.metric, c.format, c.starts_on, c.ends_on, c.event_date, c.reward, c.cover_url,
            c.sponsor, c.arena_exercise, c.venue_id, v.name AS venue_name, c.org_id AS host_org_id, ho.name AS host_org_name,
            (c.org_id = $1) AS is_host, ${EVENT_STATE} AS state,
            (SELECT COUNT(*) FROM contest_participants cp WHERE cp.contest_id = c.id) AS participant_count,
            (SELECT COUNT(*) FROM contest_participants cp WHERE cp.contest_id = c.id AND (cp.org_id = $1 OR
               (cp.org_id IS NULL AND EXISTS (SELECT 1 FROM org_memberships om WHERE om.user_id = cp.user_id
                 AND om.org_id = $1 AND om.status = 'verified')))) AS my_participants,
            COALESCE((SELECT json_agg(json_build_object('id', o.id, 'name', o.name) ORDER BY o.name)
               FROM contest_orgs co JOIN orgs o ON o.id = co.org_id WHERE co.contest_id = c.id), '[]') AS battle_orgs
     FROM contests c JOIN orgs ho ON ho.id = c.org_id LEFT JOIN venues v ON v.id = c.venue_id
     WHERE c.kind = 'org' AND (c.org_id = $1 OR EXISTS (SELECT 1 FROM contest_orgs co WHERE co.contest_id = c.id AND co.org_id = $1))
       AND ${where}
     ORDER BY CASE WHEN c.ends_on >= ${todaySql} THEN 0 ELSE 1 END, c.starts_on ${scope === 'past' ? 'DESC' : 'ASC'}
     LIMIT ${Number(limit)}`,
    [orgId],
  );
  return events.map((e) => ({ ...e, unit: METRIC_UNITS[e.metric], isBattle: e.battleOrgs.length > 0 }));
}

router.get('/orgs/:orgId/events', hr(), async (req, res) => {
  const { scope } = validate(z.object({ scope: z.enum(['all', 'live', 'past']).default('all') }), req.query);
  const events = await listEvents(req.org.id, scope);
  const battleInvites = await query(
    `SELECT b.id, b.contest_id, b.status, b.message, b.created_at, b.responded_at, c.title, c.metric, c.starts_on, c.ends_on,
            b.from_org_id, fo.name AS from_org_name, b.to_org_id, tor.name AS to_org_name, (b.to_org_id = $1) AS incoming
     FROM corporate_battle_invites b JOIN contests c ON c.id = b.contest_id
     JOIN orgs fo ON fo.id = b.from_org_id JOIN orgs tor ON tor.id = b.to_org_id
     WHERE (b.to_org_id = $1 OR b.from_org_id = $1) AND b.status IN ('pending', 'declined')
     ORDER BY b.created_at DESC LIMIT 100`,
    [req.org.id],
  );
  res.json({ events, battleInvites, arenaAvailable: !!(await arenaTable()) });
});

const eventBase = z.object({
  title: z.string().trim().min(3).max(160),
  description: optText(2000),
  metric: z.enum(['checkins', 'running_km', 'streak', 'attendance', 'arena_reps']),
  format: z.enum(['virtual', 'onground', 'ai']),
  startsOn: dateSchema,
  endsOn: dateSchema,
  eventDate: dateSchema.optional().nullable(),
  venueId: uuidSchema.optional().nullable(),
  arenaExercise: z.string().trim().toLowerCase().regex(/^[a-z_]{2,20}$/, 'Use a short exercise id like pushups').optional().nullable(),
  reward: optText(200),
  sponsor: optText(120),
  coverUrl: optText(500),
  battle: z.boolean().default(false),
});

function checkEvent(e) {
  if (e.endsOn < e.startsOn) throw badRequest('End date must be on or after the start date');
  if (e.metric === 'attendance' && (e.format !== 'onground' || !e.venueId || !e.eventDate)) {
    throw badRequest('Attendance events must be on-ground with a venue and an event date');
  }
  if (e.format === 'onground' && (!e.venueId || !e.eventDate)) throw badRequest('On-ground events need a venue and an event date');
  if (e.eventDate && (e.eventDate < e.startsOn || e.eventDate > e.endsOn)) throw badRequest('Event date must be within the dates');
  if (e.metric === 'arena_reps' && (e.format !== 'ai' || !e.arenaExercise)) {
    throw badRequest('AI rep challenges need the AI format and an exercise');
  }
}

router.post('/orgs/:orgId/events', hr('admin'), async (req, res) => {
  const e = validate(eventBase, req.body);
  checkEvent(e);
  if (e.venueId && !(await queryOne(`SELECT 1 FROM venues WHERE id = $1 AND status = 'live'`, [e.venueId]))) {
    throw badRequest('Venue not found');
  }
  const event = await withTransaction(async (client) => {
    const c = await queryOne(
      `INSERT INTO contests (title, description, period, metric, starts_on, ends_on, reward, kind, format, org_id, venue_id,
                             arena_exercise, event_date, cover_url, sponsor, created_by)
       VALUES ($1, $2, 'custom', $3, $4, $5, $6, 'org', $7, $8, $9, $10, $11, $12, $13, $14) RETURNING *`,
      [e.title, e.description, e.metric, e.startsOn, e.endsOn, e.reward, e.format, req.org.id, e.venueId ?? null,
        e.format === 'ai' ? e.arenaExercise : null, e.eventDate ?? null, e.coverUrl, e.sponsor, req.user.id],
      client,
    );
    if (e.battle) {
      await client.query(`INSERT INTO contest_orgs (contest_id, org_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [c.id, req.org.id]);
    }
    // In-app notification for every verified member (no push / email provider yet).
    await client.query(
      `INSERT INTO notifications (user_id, type, title, body, data)
       SELECT om.user_id, 'event_new', $2, $3, jsonb_build_object('contestId', $4::text, 'orgId', $1::uuid::text)
       FROM org_memberships om WHERE om.org_id = $1::uuid AND om.status = 'verified'`,
      [req.org.id, `New ${req.org.name} event: ${e.title}`.slice(0, 160), `${e.startsOn} → ${e.endsOn}. Join from Events.`, c.id],
    );
    return c;
  });
  res.status(201).json({ event });
});

async function hostedEvent(orgId, id) {
  if (!uuidSchema.safeParse(id).success) throw notFound('Event not found');
  const c = await queryOne(`SELECT * FROM contests WHERE id = $1 AND kind = 'org'`, [id]);
  if (!c) throw notFound('Event not found');
  if (c.orgId !== orgId) throw forbidden('Only the host organisation can change this event');
  return c;
}

router.patch('/orgs/:orgId/events/:id', hr('admin'), async (req, res) => {
  const c = await hostedEvent(req.org.id, req.params.id);
  const patch = validate(eventBase.partial().omit({ battle: true }), req.body);
  const merged = {
    title: c.title, description: c.description, metric: c.metric, format: c.format, startsOn: c.startsOn, endsOn: c.endsOn,
    eventDate: c.eventDate, venueId: c.venueId, arenaExercise: c.arenaExercise, reward: c.reward, sponsor: c.sponsor,
    coverUrl: c.coverUrl, ...Object.fromEntries(Object.entries(patch).filter(([k]) => k in req.body)),
  };
  checkEvent(merged);
  const started = (await queryOne(`SELECT $1::date <= ${todaySql} AS s`, [c.startsOn])).s;
  if (started && (merged.metric !== c.metric || merged.startsOn !== c.startsOn)) {
    throw badRequest('The metric and start date cannot change once the event has started');
  }
  const event = await queryOne(
    `UPDATE contests SET title = $2, description = $3, metric = $4, format = $5, starts_on = $6, ends_on = $7, event_date = $8,
       venue_id = $9, arena_exercise = $10, reward = $11, sponsor = $12, cover_url = $13 WHERE id = $1 RETURNING *`,
    [c.id, merged.title, merged.description, merged.metric, merged.format, merged.startsOn, merged.endsOn, merged.eventDate,
      merged.venueId, merged.format === 'ai' ? merged.arenaExercise : null, merged.reward, merged.sponsor, merged.coverUrl],
  );
  res.json({ event });
});

/** DELETE /orgs/:orgId/events/:id — only while nobody has joined; otherwise end it early with PATCH endsOn. */
router.delete('/orgs/:orgId/events/:id', hr('admin'), async (req, res) => {
  const c = await hostedEvent(req.org.id, req.params.id);
  const n = await queryOne(`SELECT COUNT(*) AS n FROM contest_participants WHERE contest_id = $1`, [c.id]);
  if (n.n) throw conflict('People have joined this event — end it early instead of deleting');
  await query(`DELETE FROM contests WHERE id = $1`, [c.id]);
  res.status(204).end();
});

/** Detects the AI Arena attempts table (built by another feature) and its column names, if it exists yet. */
async function arenaTable() {
  const t = await queryOne(`SELECT to_regclass('public.arena_attempts') IS NOT NULL AS ok`);
  if (!t.ok) return null;
  const cols = new Set(
    (await query(`SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'arena_attempts'`))
      .map((c) => c.columnName),
  );
  const pick = (names) => names.find((n) => cols.has(n));
  const reps = pick(['reps', 'rep_count', 'count', 'score']);
  const exercise = pick(['exercise', 'exercise_id', 'exercise_code', 'exercise_key']);
  const at = pick(['created_at', 'attempted_at', 'recorded_at', 'completed_at']);
  if (!cols.has('user_id') || !reps || !exercise || !at) return null;
  return { reps, exercise, at, verified: cols.has('verified') ? 'verified' : null };
}

/**
 * Scores (user_id, score) for an event — computed here from the raw tables (checkins, activity_logs running km,
 * participant attendance, arena attempts). Params: $1 contest id, $2 start, $3 end, $4 tz, $5 venue, $6 event date, $7 exercise.
 */
async function scoreSql(c) {
  switch (c.metric) {
    case 'checkins':
      return `SELECT user_id, COUNT(DISTINCT checkin_date)::numeric AS score FROM checkins
              WHERE checkin_date BETWEEN $2 AND $3 AND ($5::uuid IS NULL OR venue_id = $5) GROUP BY user_id`;
    case 'running_km':
      return `SELECT user_id, COALESCE(SUM(distance_km), 0)::numeric AS score FROM activity_logs
              WHERE type = 'running' AND (logged_at AT TIME ZONE $4)::date BETWEEN $2 AND $3 GROUP BY user_id`;
    case 'streak':
      return `SELECT user_id, MAX(run)::numeric AS score FROM (
                SELECT user_id, COUNT(*) AS run FROM (
                  SELECT user_id, d, d - (ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY d))::int AS grp
                  FROM (SELECT DISTINCT user_id, checkin_date AS d FROM checkins WHERE checkin_date BETWEEN $2 AND $3) days
                ) islands GROUP BY user_id, grp
              ) runs GROUP BY user_id`;
    case 'attendance':
      return `SELECT cp.user_id, 1::numeric AS score FROM contest_participants cp
              WHERE cp.contest_id = $1 AND (cp.attended_at IS NOT NULL OR EXISTS (
                SELECT 1 FROM checkins ch WHERE ch.user_id = cp.user_id AND ch.venue_id = $5
                  AND ch.checkin_date = COALESCE($6::date, $2)))`;
    case 'arena_reps': {
      const a = await arenaTable();
      if (!a) return `SELECT NULL::uuid AS user_id, 0::numeric AS score WHERE FALSE`;
      return `SELECT user_id, MAX("${a.reps}")::numeric AS score FROM arena_attempts
              WHERE "${a.exercise}"::text = $7 AND ("${a.at}" AT TIME ZONE $4)::date BETWEEN $2 AND $3
                ${a.verified ? `AND "${a.verified}"` : ''}
              GROUP BY user_id`;
    }
    default:
      throw new Error(`Unknown metric ${c.metric}`);
  }
}

/**
 * Leaderboard for an event as seen by `viewerOrgId`: individual names only for the viewer's own employees;
 * other orgs in a battle appear as team totals only.
 */
async function eventLeaderboard(c, viewerOrgId) {
  const battleOrgs = await query(
    `SELECT o.id, o.name FROM contest_orgs co JOIN orgs o ON o.id = co.org_id WHERE co.contest_id = $1`,
    [c.id],
  );
  const orgIds = battleOrgs.length ? battleOrgs.map((o) => o.id) : [c.orgId];
  const rows = await query(
    `WITH scores AS (${await scoreSql(c)})
     SELECT cp.user_id, u.name, u.avatar_url, cp.joined_at, cp.attended_at, om.department,
            COALESCE(cp.org_id, (SELECT m.org_id FROM org_memberships m WHERE m.user_id = cp.user_id AND m.status = 'verified'
                                   AND m.org_id = ANY($8::uuid[]) LIMIT 1)) AS team_org_id,
            COALESCE(s.score, 0) AS score
     FROM contest_participants cp JOIN users u ON u.id = cp.user_id
     LEFT JOIN scores s ON s.user_id = cp.user_id
     LEFT JOIN org_memberships om ON om.user_id = cp.user_id AND om.org_id = $9
     WHERE cp.contest_id = $1
       -- Not every metric uses every parameter; these typed no-ops let Postgres infer all of them.
       AND $2::date IS NOT NULL AND $3::date IS NOT NULL AND $4::text IS NOT NULL
       AND ($5::uuid IS NULL OR TRUE) AND ($6::date IS NULL OR TRUE) AND $7::text IS NOT NULL
     ORDER BY score DESC, u.name`,
    [c.id, c.startsOn, c.endsOn, config.tz, c.venueId, c.eventDate, c.arenaExercise ?? '', orgIds, viewerOrgId],
  );
  let rank = 0;
  let last = null;
  const mine = [];
  rows.forEach((r, i) => {
    if (r.score !== last) {
      rank = i + 1;
      last = r.score;
    }
    if (r.teamOrgId === viewerOrgId) {
      mine.push({ rank, userId: r.userId, name: r.name, avatarUrl: r.avatarUrl, department: r.department, score: r.score,
        joinedAt: r.joinedAt, attendedAt: r.attendedAt });
    }
  });
  const teams = (battleOrgs.length ? battleOrgs : [{ id: c.orgId, name: '' }])
    .map((o) => {
      const t = rows.filter((r) => r.teamOrgId === o.id);
      const total = t.reduce((s, r) => s + Number(r.score), 0);
      return { orgId: o.id, name: o.name, participants: t.length, total: Math.round(total * 100) / 100,
        average: t.length ? Math.round((total / t.length) * 100) / 100 : 0, isMine: o.id === viewerOrgId };
    })
    .sort((a, b) => b.total - a.total)
    .map((t, i) => ({ ...t, rank: i + 1 }));
  return { entries: mine.slice(0, 500), teams: battleOrgs.length ? teams : [], totalParticipants: rows.length };
}

router.get('/orgs/:orgId/events/:id', hr(), async (req, res) => {
  if (!uuidSchema.safeParse(req.params.id).success) throw notFound('Event not found');
  const c = await queryOne(
    `SELECT c.*, v.name AS venue_name, o.name AS host_org_name, ${EVENT_STATE} AS state FROM contests c
     JOIN orgs o ON o.id = c.org_id LEFT JOIN venues v ON v.id = c.venue_id
     WHERE c.id = $1 AND c.kind = 'org'
       AND (c.org_id = $2 OR EXISTS (SELECT 1 FROM contest_orgs co WHERE co.contest_id = c.id AND co.org_id = $2))`,
    [req.params.id, req.org.id],
  );
  if (!c) throw notFound('Event not found');
  const leaderboard = await eventLeaderboard(c, req.org.id);
  const invites = await query(
    `SELECT b.id, b.status, b.to_org_id, o.name AS to_org_name, b.created_at, b.responded_at
     FROM corporate_battle_invites b JOIN orgs o ON o.id = b.to_org_id WHERE b.contest_id = $1 AND b.from_org_id = $2
     ORDER BY b.created_at DESC`,
    [c.id, req.org.id],
  );
  const members = await queryOne(`SELECT COUNT(*) AS n FROM org_memberships WHERE org_id = $1 AND status = 'verified'`, [req.org.id]);
  const arenaReady = c.metric !== 'arena_reps' || !!(await arenaTable());
  res.json({
    event: { ...c, unit: METRIC_UNITS[c.metric], isHost: c.orgId === req.org.id },
    leaderboard,
    invites,
    memberCount: members.n,
    ...(arenaReady ? {} : { notice: 'AI Arena scores will appear once the Arena feature records attempts.' }),
  });
});

/** GET /orgs/:orgId/org-search?q= — find another org to challenge (name + kind only). */
router.get('/orgs/:orgId/org-search', hr('admin'), async (req, res) => {
  const { q } = validate(z.object({ q: z.string().trim().min(2).max(80) }), req.query);
  const orgs = await query(
    `SELECT id, name, kind, logo_url FROM orgs WHERE id <> $1 AND name ILIKE '%' || $2 || '%' ORDER BY name LIMIT 10`,
    [req.org.id, q],
  );
  res.json({ orgs });
});

async function orgAdmins(orgId, minRole = 'admin') {
  const roles = Object.keys(ROLE_RANK).filter((r) => ROLE_RANK[r] >= ROLE_RANK[minRole]);
  return query(`SELECT user_id FROM corporate_admins WHERE org_id = $1 AND role = ANY($2)`, [orgId, roles]);
}

/** POST /orgs/:orgId/events/:id/battle-invites { toOrgId, message? } — challenge another org (they must accept). */
router.post('/orgs/:orgId/events/:id/battle-invites', hr('admin'), async (req, res) => {
  const c = await hostedEvent(req.org.id, req.params.id);
  const { toOrgId, message } = validate(z.object({ toOrgId: uuidSchema, message: optText(300) }), req.body);
  if (toOrgId === req.org.id) throw badRequest('Choose another organisation');
  if ((await queryOne(`SELECT ends_on < ${todaySql} AS over FROM contests WHERE id = $1`, [c.id])).over) {
    throw badRequest('This event has finished');
  }
  const to = await queryOne(`SELECT id, name FROM orgs WHERE id = $1`, [toOrgId]);
  if (!to) throw notFound('Organisation not found');
  if (await queryOne(`SELECT 1 FROM contest_orgs WHERE contest_id = $1 AND org_id = $2`, [c.id, toOrgId])) {
    throw conflict(`${to.name} is already in this battle`);
  }
  const invite = await withTransaction(async (client) => {
    await client.query(`INSERT INTO contest_orgs (contest_id, org_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [c.id, req.org.id]);
    const existing = await queryOne(
      `SELECT id FROM corporate_battle_invites WHERE contest_id = $1 AND to_org_id = $2 AND status = 'pending'`,
      [c.id, toOrgId],
      client,
    );
    if (existing) throw conflict(`${to.name} already has a pending invite`);
    return queryOne(
      `INSERT INTO corporate_battle_invites (contest_id, from_org_id, to_org_id, message, created_by)
       VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      [c.id, req.org.id, toOrgId, message, req.user.id],
      client,
    );
  });
  for (const a of await orgAdmins(toOrgId)) {
    await notify(a.userId, {
      type: 'corporate_battle_invite',
      title: `${req.org.name} challenged ${to.name}`,
      body: `"${c.title}" — accept or decline in the Corporate Dashboard.`,
      data: { orgId: toOrgId, contestId: c.id },
    });
  }
  console.log(`[corporate] battle invite ${req.org.name} → ${to.name} for "${c.title}"`);
  res.status(201).json({ invite });
});

router.post('/orgs/:orgId/battle-invites/:inviteId/:action', hr('admin'), async (req, res) => {
  const { action } = validate(z.object({ action: z.enum(['accept', 'decline', 'cancel']) }), req.params);
  if (!uuidSchema.safeParse(req.params.inviteId).success) throw notFound('Invite not found');
  const result = await withTransaction(async (client) => {
    const b = await queryOne(
      `SELECT b.*, c.title, c.ends_on < ${todaySql} AS over FROM corporate_battle_invites b JOIN contests c ON c.id = b.contest_id
       WHERE b.id = $1 FOR UPDATE OF b`,
      [req.params.inviteId],
      client,
    );
    if (!b || b.status !== 'pending') throw notFound('Pending invite not found');
    if (action === 'cancel' ? b.fromOrgId !== req.org.id : b.toOrgId !== req.org.id) throw forbidden('Not your invite');
    if (action === 'accept' && b.over) throw badRequest('This event has already finished');
    const status = { accept: 'accepted', decline: 'declined', cancel: 'cancelled' }[action];
    await client.query(
      `UPDATE corporate_battle_invites SET status = $2, responded_by = $3, responded_at = now() WHERE id = $1`,
      [b.id, status, req.user.id],
    );
    if (action === 'accept') {
      await client.query(`INSERT INTO contest_orgs (contest_id, org_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`, [b.contestId, b.toOrgId]);
      await client.query(
        `INSERT INTO notifications (user_id, type, title, body, data)
         SELECT om.user_id, 'event_new', $2, $3, jsonb_build_object('contestId', $4::text, 'orgId', $1::uuid::text)
         FROM org_memberships om WHERE om.org_id = $1::uuid AND om.status = 'verified'`,
        [b.toOrgId, `${req.org.name} joined the battle: ${b.title}`.slice(0, 160), 'Represent your team — join from Events.', b.contestId],
      );
    }
    return { ...b, status };
  });
  if (action !== 'cancel') {
    for (const a of await orgAdmins(result.fromOrgId)) {
      await notify(a.userId, {
        type: 'corporate_battle_reply',
        title: `${req.org.name} ${result.status} your challenge`,
        body: `"${result.title}"`,
        data: { orgId: result.fromOrgId, contestId: result.contestId },
      });
    }
  }
  res.json({ status: result.status, contestId: result.contestId });
});

/** GET /orgs/:orgId/venues?q= — live venues for on-ground events. */
router.get('/orgs/:orgId/venues', hr(), async (req, res) => {
  const { q } = validate(z.object({ q: z.string().trim().max(80).optional() }), req.query);
  const venues = await query(
    `SELECT id, name, area, city FROM venues WHERE status = 'live'
       AND ($1::text IS NULL OR name ILIKE '%' || $1 || '%' OR city ILIKE '%' || $1 || '%' OR area ILIKE '%' || $1 || '%')
     ORDER BY city, name LIMIT 50`,
    [q || null],
  );
  res.json({ venues });
});

/* ============================================================== analytics (usage + participation only) */

router.get('/orgs/:orgId/analytics', hr(), async (req, res) => {
  const { days } = validate(z.object({ days: z.coerce.number().int().min(7).max(365).default(30) }), req.query);
  const id = req.org.id;
  const M = `m AS (SELECT user_id, department FROM org_memberships WHERE org_id = $1 AND status = 'verified'),
             w AS (SELECT ${todaySql} - ($2::int - 1) AS s, ${todaySql} AS e),
             ci AS (SELECT c.* FROM checkins c, w WHERE c.checkin_date BETWEEN w.s AND w.e AND c.user_id IN (SELECT user_id FROM m))`;
  const summary = await queryOne(
    `WITH ${M}
     SELECT (SELECT COUNT(*) FROM m) AS members,
            (SELECT COUNT(DISTINCT user_id) FROM ci) AS active_employees,
            (SELECT COUNT(*) FROM ci) AS checkins,
            (SELECT COUNT(DISTINCT venue_id) FROM ci) AS centres_used,
            (SELECT COUNT(*) FROM org_memberships om, w WHERE om.org_id = $1 AND om.status = 'verified'
               AND (om.verified_at AT TIME ZONE '${config.tz.replace(/'/g, '')}')::date BETWEEN w.s AND w.e) AS new_members,
            (SELECT COUNT(DISTINCT cp.user_id) FROM contest_participants cp JOIN contests ct ON ct.id = cp.contest_id, w
               WHERE cp.user_id IN (SELECT user_id FROM m) AND ct.kind = 'org' AND ct.ends_on >= w.s AND ct.starts_on <= w.e
               AND (ct.org_id = $1 OR EXISTS (SELECT 1 FROM contest_orgs co WHERE co.contest_id = ct.id AND co.org_id = $1)))
               AS event_participants`,
    [id, days],
  );
  const series = await query(
    `WITH ${M}, d AS (SELECT generate_series(w.s, w.e, interval '1 day')::date AS d FROM w)
     SELECT d.d AS date, COUNT(ci.id) AS checkins, COUNT(DISTINCT ci.user_id) AS employees
     FROM d LEFT JOIN ci ON ci.checkin_date = d.d GROUP BY d.d ORDER BY d.d`,
    [id, days],
  );
  const topCentres = await query(
    `WITH ${M}
     SELECT v.id, v.name, v.area, v.city, COUNT(*) AS checkins, COUNT(DISTINCT ci.user_id) AS employees
     FROM ci JOIN venues v ON v.id = ci.venue_id GROUP BY v.id ORDER BY checkins DESC LIMIT 10`,
    [id, days],
  );
  const byDepartment = await query(
    `WITH ${M}
     SELECT COALESCE(m.department, 'Unassigned') AS department, COUNT(*) AS members,
            COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM ci WHERE ci.user_id = m.user_id)) AS active,
            COALESCE(SUM((SELECT COUNT(*) FROM ci WHERE ci.user_id = m.user_id)), 0) AS checkins
     FROM m GROUP BY 1 ORDER BY members DESC, 1`,
    [id, days],
  );
  const weekday = await query(
    `WITH ${M}
     SELECT EXTRACT(ISODOW FROM ci.checkin_date)::int AS dow, COUNT(*) AS checkins FROM ci GROUP BY 1 ORDER BY 1`,
    [id, days],
  );
  const events = await query(
    `WITH ${M}
     SELECT ct.id, ct.title, ct.metric, ct.starts_on, ct.ends_on,
            (SELECT COUNT(*) FROM contest_participants cp WHERE cp.contest_id = ct.id AND cp.user_id IN (SELECT user_id FROM m)) AS participants
     FROM contests ct, w
     WHERE ct.kind = 'org' AND ct.ends_on >= w.s AND ct.starts_on <= w.e
       AND (ct.org_id = $1 OR EXISTS (SELECT 1 FROM contest_orgs co WHERE co.contest_id = ct.id AND co.org_id = $1))
     ORDER BY ct.starts_on DESC LIMIT 12`,
    [id, days],
  );
  const passes = await queryOne(
    `WITH ${M}, holders AS (
       SELECT DISTINCT a.user_id FROM corporate_pass_assignments a JOIN subscriptions s ON s.id = a.subscription_id
       WHERE a.org_id = $1 AND a.status = 'active' AND s.status = 'active' AND s.ends_at > now())
     SELECT (SELECT COUNT(*) FROM holders) AS holders,
            (SELECT COUNT(*) FROM holders h WHERE EXISTS (SELECT 1 FROM ci WHERE ci.user_id = h.user_id)) AS using_pass`,
    [id, days],
  );
  res.json({ days, summary, series, topCentres, byDepartment, weekday, events, passes });
});

export default router;

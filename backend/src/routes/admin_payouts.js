import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, conflict, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { PAYOUT_SCHEDULE, lastFullWeek, nextMonday, rupees } from '../utils/partner_money.js';
import { dateSchema, uuidSchema } from '../utils/schemas.js';

/**
 * FitKey team: partner payouts (contract §I). Mounted at /admin/payouts before routes/admin.js.
 *   GET  /admin/payouts?status=&ownerId=   list (+ schedule, nextPayoutOn, unsettled totals)
 *   POST /admin/payouts/run { periodStart?, periodEnd? }   default = last full Mon–Sun week
 *   POST /admin/payouts/:id { status, utr? }
 * A run creates one partner_payouts row per owner from the not-yet-settled visit_payouts (by visit_date) and
 * direct_memberships (by purchase date) in the period, and stamps those rows with payout_id so nothing is paid twice.
 * Manual member sources (self / fitpass / other) are never in a payout. Payouts go only to a VERIFIED bank
 * account: without one the payout is created 'on_hold' and can't be moved to processing / paid.
 */
const router = Router();
router.use(requireAuth('admin'));

const PAYOUT_STATUSES = ['scheduled', 'processing', 'paid', 'failed', 'on_hold'];

const today = async () => (await queryOne(`SELECT to_char(now() AT TIME ZONE $1, 'YYYY-MM-DD') AS d`, [config.tz])).d;

const verifiedBank = (ownerId, client) =>
  queryOne(
    `SELECT id, RIGHT(account_number, 4) AS last4, ifsc, bank_name FROM partner_bank_accounts
     WHERE owner_id = $1 AND is_primary AND status = 'verified' ORDER BY verified_at DESC NULLS LAST, created_at DESC LIMIT 1`,
    [ownerId],
    client,
  );

/** GET /admin/payouts?status=&ownerId= */
router.get('/', async (req, res) => {
  const f = validate(z.object({ status: z.enum(PAYOUT_STATUSES).optional(), ownerId: uuidSchema.optional() }), req.query);
  const [payouts, unsettled, d] = await Promise.all([
    query(
      `SELECT p.id, p.owner_id, u.name AS owner_name, u.phone AS owner_phone, p.period_start, p.period_end, p.gross_paise,
              p.commission_paise, p.gst_paise, p.net_paise, p.status, p.utr, p.paid_at, p.created_at,
              b.id AS bank_account_id, RIGHT(b.account_number, 4) AS bank_last4, b.ifsc AS bank_ifsc, b.status AS bank_status
       FROM partner_payouts p JOIN users u ON u.id = p.owner_id
       LEFT JOIN partner_bank_accounts b ON b.id = p.bank_account_id
       WHERE ($1::text IS NULL OR p.status = $1) AND ($2::uuid IS NULL OR p.owner_id = $2)
       ORDER BY p.period_end DESC, u.name LIMIT 500`,
      [f.status ?? null, f.ownerId ?? null],
    ),
    queryOne(
      `SELECT COALESCE((SELECT SUM(amount_paise) FROM visit_payouts WHERE payout_id IS NULL), 0) AS visit_net_paise,
              COALESCE((SELECT SUM(COALESCE(partner_net_paise, amount_paise - commission_paise)) FROM direct_memberships
                        WHERE payout_id IS NULL AND status <> 'cancelled'), 0) AS direct_net_paise`,
    ),
    today(),
  ]);
  res.json({
    schedule: PAYOUT_SCHEDULE,
    nextPayoutOn: nextMonday(d),
    suggestedPeriod: lastFullWeek(d),
    unsettled,
    payouts,
  });
});

/** POST /admin/payouts/run { periodStart?, periodEnd? } → { periodStart, periodEnd, created:[…], skipped } */
router.post('/run', async (req, res) => {
  const body = validate(z.object({ periodStart: dateSchema.optional(), periodEnd: dateSchema.optional() }), req.body ?? {});
  const d = await today();
  const def = lastFullWeek(d);
  const periodStart = body.periodStart ?? def.periodStart;
  const periodEnd = body.periodEnd ?? def.periodEnd;
  if (periodEnd < periodStart) throw badRequest('periodEnd: must be on or after periodStart');
  if (periodEnd >= d) throw badRequest('periodEnd: a payout can only cover days that are over (up to yesterday)');

  const owners = await query(
    `SELECT DISTINCT v.owner_id FROM visit_payouts p JOIN venues v ON v.id = p.venue_id
     WHERE p.payout_id IS NULL AND p.visit_date BETWEEN $1::date AND $2::date
     UNION
     SELECT DISTINCT v.owner_id FROM direct_memberships m JOIN venues v ON v.id = m.venue_id
     WHERE m.payout_id IS NULL AND m.status <> 'cancelled' AND (m.created_at AT TIME ZONE $3)::date BETWEEN $1::date AND $2::date`,
    [periodStart, periodEnd, config.tz],
  );

  const created = [];
  let skipped = 0;
  for (const { ownerId } of owners) {
    const payout = await withTransaction(async (client) => {
      const bank = await verifiedBank(ownerId, client);
      const row = await queryOne(
        `INSERT INTO partner_payouts (owner_id, period_start, period_end, status, bank_account_id)
         VALUES ($1, $2, $3, $4, $5) ON CONFLICT (owner_id, period_start, period_end) DO NOTHING RETURNING id`,
        [ownerId, periodStart, periodEnd, bank ? 'scheduled' : 'on_hold', bank?.id ?? null],
        client,
      );
      if (!row) return null; // already run for this exact period
      await client.query(
        `UPDATE visit_payouts p SET payout_id = $1 FROM venues v
         WHERE v.id = p.venue_id AND v.owner_id = $2 AND p.payout_id IS NULL AND p.visit_date BETWEEN $3::date AND $4::date`,
        [row.id, ownerId, periodStart, periodEnd],
      );
      await client.query(
        `UPDATE direct_memberships m SET payout_id = $1 FROM venues v
         WHERE v.id = m.venue_id AND v.owner_id = $2 AND m.payout_id IS NULL AND m.status <> 'cancelled'
           AND (m.created_at AT TIME ZONE $5)::date BETWEEN $3::date AND $4::date`,
        [row.id, ownerId, periodStart, periodEnd, config.tz],
      );
      return queryOne(
        `UPDATE partner_payouts SET
           gross_paise = t.gross, commission_paise = t.commission, gst_paise = t.gst, net_paise = t.net
         FROM (
           SELECT COALESCE(SUM(gross), 0) AS gross, COALESCE(SUM(commission), 0) AS commission,
                  COALESCE(SUM(gst), 0) AS gst, COALESCE(SUM(net), 0) AS net
           FROM (
             SELECT COALESCE(gross_paise, amount_paise) AS gross, commission_paise AS commission, 0 AS gst, amount_paise AS net
             FROM visit_payouts WHERE payout_id = $1
             UNION ALL
             SELECT amount_paise, commission_paise, gst_paise, COALESCE(partner_net_paise, amount_paise - commission_paise)
             FROM direct_memberships WHERE payout_id = $1
           ) x
         ) t
         WHERE partner_payouts.id = $1
         RETURNING partner_payouts.id, owner_id, period_start, period_end, gross_paise, commission_paise, gst_paise, net_paise, status`,
        [row.id],
        client,
      );
    });
    if (!payout) {
      skipped += 1;
      continue;
    }
    created.push(payout);
    await notify(ownerId, {
      type: 'payout_scheduled',
      title: payout.status === 'on_hold' ? 'Payout on hold: verify your bank account' : `Payout scheduled: ₹${rupees(payout.netPaise)}`,
      body:
        payout.status === 'on_hold'
          ? `Your FitKey earnings for ${periodStart} to ${periodEnd} (₹${rupees(payout.netPaise)}) are ready, but payouts go only to a verified bank account. Add or verify it in Account → Bank.`
          : `Your FitKey earnings for ${periodStart} to ${periodEnd} will be paid to your bank account.`,
      data: { payoutId: payout.id },
    });
  }
  res.status(201).json({ periodStart, periodEnd, created, skipped });
});

/** POST /admin/payouts/:id { status, utr? } — paid needs a UTR and a verified bank account; partner notified when paid. */
router.post('/:id', async (req, res) => {
  const id = validate(uuidSchema, req.params.id);
  const body = validate(
    z.object({ status: z.enum(PAYOUT_STATUSES), utr: z.string().trim().min(4).max(40).optional() }),
    req.body,
  );
  const result = await withTransaction(async (client) => {
    const p = await queryOne(`SELECT * FROM partner_payouts WHERE id = $1 FOR UPDATE`, [id], client);
    if (!p) throw notFound('Payout not found');
    if (p.status === 'paid' && body.status !== 'paid') throw conflict('This payout is already paid');
    let bankId = p.bankAccountId;
    if (['scheduled', 'processing', 'paid'].includes(body.status)) {
      const bank = await verifiedBank(p.ownerId, client);
      if (!bank) throw conflict('The partner has no verified bank account — keep this payout on hold');
      bankId = bank.id;
    }
    if (body.status === 'paid' && !(body.utr ?? p.utr)) throw badRequest('utr: Enter the bank UTR / reference of the transfer');
    const updated = await queryOne(
      `UPDATE partner_payouts SET status = $2, utr = COALESCE($3, utr), bank_account_id = $4,
              paid_at = CASE WHEN $2 = 'paid' THEN COALESCE(paid_at, now()) ELSE NULL END
       WHERE id = $1
       RETURNING id, owner_id, period_start, period_end, gross_paise, commission_paise, gst_paise, net_paise, status, utr, paid_at`,
      [id, body.status, body.utr ?? null, bankId],
      client,
    );
    return { ...updated, previousStatus: p.status };
  });
  if (result.status === 'paid' && result.previousStatus !== 'paid') {
    await notify(result.ownerId, {
      type: 'payout_paid',
      title: `Payout sent: ₹${rupees(result.netPaise)}`,
      body: `FitKey paid your earnings for ${result.periodStart} to ${result.periodEnd}. UTR ${result.utr}.`,
      data: { payoutId: result.id },
    });
  }
  delete result.previousStatus;
  res.json({ payout: result });
});

export default router;

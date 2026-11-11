import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, queryOne, withTransaction } from '../db/index.js';
import { requireStaff, signAccessToken } from '../middleware/auth.js';
import { HttpError, badRequest, conflict, forbidden, notFound, unauthorized, validate } from '../utils/http.js';
import { dateSchema, phoneSchema } from '../utils/schemas.js';
import { PAYOUT_RULE, commissionPlan } from '../utils/commission.js';
import { LISTING_ENTITIES, maybeGoLive } from '../utils/listing.js';
import { sendSms } from '../utils/sms.js';
import {
  DOC_TYPES,
  ENTITY_TYPES,
  PARTNER_TYPES,
  bankNameFromIfsc,
  isValidAccountNumber,
  isValidIfsc,
  maskAadhaar,
  normalizeAccountNumber,
  normalizeIfsc,
} from '../utils/partner_rules.js';
import { FILES_PATH } from './files.js';
import { OTP_MAX_ATTEMPTS, OTP_TTL_MINUTES, hashOtp } from './auth.js';

/**
 * Partner BRD §C / §D (mounted inside routes/partner.js, so requireAuth('partner') has already run):
 * documents, owner KYC, payout bank account, agreement acceptance by OTP, listings waiting for acceptance,
 * and assisted listing by FitKey staff.
 */
const router = Router();

const uuid = z.string().uuid();
const entityTypeSchema = z.enum(ENTITY_TYPES);
const AGREEMENT_VERSION = '2026-11';
const AGREEMENT_OTP_ROLE = 'agreement';
const mockKyc = () => process.env.KYC_MODE !== 'live';
const mockPennyDrop = () => process.env.PENNY_DROP_MODE !== 'live';

const fileUrlSchema = z
  .string()
  .trim()
  .refine((s) => /^https?:\/\/\S+$/.test(s) || new RegExp(`^${FILES_PATH}[0-9a-f-]{36}$`).test(s), 'Invalid file URL');

// --------------------------------------------------------------------------------------------- listing helpers

/**
 * Union of every listable table with the shared lifecycle columns:
 * entity_type, entity_id, name, status, owner_id, listed_by, submitted_at, admin_approved_at, partner_accepted_at,
 * go_live_at, created_at, city. Wrap it: `SELECT … FROM (${listingsUnionSql()}) l WHERE …`.
 */
export function listingsUnionSql() {
  const city = { venue: 't.city', trainer: 'NULL::varchar', clinic: 't.city', chemist: 't.city', store: 'NULL::varchar' };
  return Object.entries(LISTING_ENTITIES)
    .map(
      ([type, m]) =>
        `SELECT '${type}'::text AS entity_type, t.id AS entity_id, t.${m.name}::text AS name, t.${m.status}::text AS status,
                t.${m.owner} AS owner_id, t.listed_by, t.submitted_at, t.admin_approved_at, t.partner_accepted_at,
                t.go_live_at, t.created_at, ${city[type]}::text AS city
         FROM ${m.table} t`,
    )
    .join('\nUNION ALL\n');
}

/** Listing (or 404) — { ownerId, listedBy, status, name, partnerAcceptedAt, adminApprovedAt }. */
export async function loadListingMeta(entityType, id) {
  if (!entityTypeSchema.safeParse(entityType).success) throw badRequest('Unknown entityType');
  if (!uuid.safeParse(id).success) throw notFound('Listing not found');
  const m = LISTING_ENTITIES[entityType];
  const row = await queryOne(
    `SELECT id, ${m.owner} AS owner_id, ${m.name} AS name, ${m.status} AS status, listed_by, partner_accepted_at,
            admin_approved_at, submitted_at, go_live_at
     FROM ${m.table} WHERE id = $1`,
    [id],
  );
  if (!row) throw notFound('Listing not found');
  return row;
}

/** Owner only (an act-as token counts as the owner). */
export async function assertOwnListing(entityType, id, userId) {
  const row = await loadListingMeta(entityType, id);
  if (row.ownerId !== userId) throw notFound('Listing not found');
  return row;
}

/** Owner, or the FitKey employee who listed it (own token) — for read-only views like the timeline. */
export async function assertListingAccess(entityType, id, req) {
  const row = await loadListingMeta(entityType, id);
  if (row.ownerId === req.user.id) return row;
  if (!req.staffId && row.listedBy === req.user.id) return row;
  throw notFound('Listing not found');
}

// --------------------------------------------------------------------------------------------- documents

const DOC_FIELDS = `id, entity_type, entity_id, doc_type, file_url, doc_number, expires_on, status, review_note, reviewed_at, created_at`;

/** GET /partner/documents?entityType=&entityId= */
router.get('/documents', async (req, res) => {
  const q = validate(z.object({ entityType: entityTypeSchema, entityId: uuid }), req.query);
  await assertOwnListing(q.entityType, q.entityId, req.user.id);
  const documents = await query(
    `SELECT ${DOC_FIELDS} FROM partner_documents WHERE entity_type = $1 AND entity_id = $2 ORDER BY created_at`,
    [q.entityType, q.entityId],
  );
  res.json({ documents });
});

/** POST /partner/documents { entityType, entityId, docType, fileUrl, docNumber?, expiresOn? } */
router.post('/documents', async (req, res) => {
  const b = validate(
    z.object({
      entityType: entityTypeSchema,
      entityId: uuid,
      docType: z.enum(DOC_TYPES),
      fileUrl: fileUrlSchema,
      docNumber: z.string().trim().max(60).nullish(),
      expiresOn: dateSchema.nullish(),
    }),
    req.body ?? {},
  );
  await assertOwnListing(b.entityType, b.entityId, req.user.id);
  const count = await queryOne(`SELECT COUNT(*) AS n FROM partner_documents WHERE entity_type = $1 AND entity_id = $2`, [
    b.entityType,
    b.entityId,
  ]);
  if (count.n >= 30) throw badRequest('Too many documents on this listing — delete old ones first');
  const document = await queryOne(
    `INSERT INTO partner_documents (owner_id, entity_type, entity_id, doc_type, file_url, doc_number, expires_on)
     VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING ${DOC_FIELDS}`,
    [req.user.id, b.entityType, b.entityId, b.docType, b.fileUrl, b.docNumber || null, b.expiresOn ?? null],
  );
  res.status(201).json({ document });
});

/** DELETE /partner/documents/:id */
router.delete('/documents/:id', async (req, res) => {
  if (!uuid.safeParse(req.params.id).success) throw notFound('Document not found');
  const deleted = await queryOne(`DELETE FROM partner_documents WHERE id = $1 AND owner_id = $2 RETURNING id`, [
    req.params.id,
    req.user.id,
  ]);
  if (!deleted) throw notFound('Document not found');
  res.status(204).end();
});

// --------------------------------------------------------------------------------------------- KYC

const KYC_FIELDS = `method, aadhaar_masked, name_on_id, status, verified_at`;

router.get('/kyc', async (req, res) => {
  res.json({ kyc: await queryOne(`SELECT ${KYC_FIELDS} FROM partner_kyc WHERE owner_id = $1`, [req.user.id]) });
});

/**
 * POST /partner/kyc { method, aadhaarLast4, nameOnId } — only XXXX-XXXX-<last4> is stored; a full Aadhaar number is
 * rejected. Mock verification unless KYC_MODE=live (a real DigiLocker / offline e-KYC integration plugs in here).
 */
router.post('/kyc', async (req, res) => {
  const b = validate(
    z.object({
      method: z.enum(['digilocker', 'offline_ekyc']),
      aadhaarLast4: z.union([z.string(), z.number()]).transform(String),
      nameOnId: z.string().trim().min(2).max(160),
    }),
    req.body ?? {},
  );
  let masked;
  try {
    masked = maskAadhaar(b.aadhaarLast4);
  } catch (err) {
    throw badRequest(`aadhaarLast4: ${err.message}`);
  }
  const verified = mockKyc();
  const kyc = await queryOne(
    `INSERT INTO partner_kyc (owner_id, method, aadhaar_masked, name_on_id, status, verified_at)
     VALUES ($1, $2, $3, $4, $5, CASE WHEN $5 = 'verified' THEN now() END)
     ON CONFLICT (owner_id) DO UPDATE SET method = EXCLUDED.method, aadhaar_masked = EXCLUDED.aadhaar_masked,
       name_on_id = EXCLUDED.name_on_id, status = EXCLUDED.status, verified_at = EXCLUDED.verified_at, updated_at = now()
     RETURNING ${KYC_FIELDS}`,
    [req.user.id, b.method, masked, b.nameOnId, verified ? 'verified' : 'pending'],
  );
  res.json({ kyc });
});

// --------------------------------------------------------------------------------------------- bank

const BANK_FIELDS = `id, holder_name, RIGHT(account_number, 4) AS last4, ifsc, bank_name, status, verified_name, verified_at`;

/** GET /partner/bank — the primary payout account; never the full account number. */
router.get('/bank', async (req, res) => {
  const account = await queryOne(
    `SELECT ${BANK_FIELDS} FROM partner_bank_accounts WHERE owner_id = $1 AND is_primary ORDER BY created_at DESC LIMIT 1`,
    [req.user.id],
  );
  res.json({ account });
});

/**
 * POST /partner/bank { holderName, accountNumber, ifsc } — becomes the only primary account. Penny-drop is mocked
 * (verified at once, verifiedName = holderName) unless PENNY_DROP_MODE=live.
 */
router.post('/bank', async (req, res) => {
  const b = validate(
    z.object({
      holderName: z.string().trim().min(2).max(160),
      accountNumber: z
        .union([z.string(), z.number()])
        .transform((s) => normalizeAccountNumber(String(s)))
        .refine(isValidAccountNumber, 'Account number must be 9–18 digits'),
      ifsc: z
        .string()
        .transform(normalizeIfsc)
        .refine(isValidIfsc, 'Enter a valid IFSC (e.g. HDFC0001234)'),
    }),
    req.body ?? {},
  );
  const mock = mockPennyDrop();
  const account = await withTransaction(async (client) => {
    await query(`UPDATE partner_bank_accounts SET is_primary = false WHERE owner_id = $1 AND is_primary`, [req.user.id], client);
    return queryOne(
      `INSERT INTO partner_bank_accounts (owner_id, holder_name, account_number, ifsc, bank_name, status, verified_name,
                                          verified_at, is_primary)
       VALUES ($1, $2, $3, $4, $5, $6, $7, CASE WHEN $6 = 'verified' THEN now() END, true)
       RETURNING ${BANK_FIELDS}`,
      [req.user.id, b.holderName, b.accountNumber, b.ifsc, bankNameFromIfsc(b.ifsc), mock ? 'verified' : 'pending',
        mock ? b.holderName : null],
      client,
    );
  });
  res.json({ account });
});

// --------------------------------------------------------------------------------------------- agreement (OTP)

const entityBody = z.object({ entityType: entityTypeSchema, entityId: uuid });
const agreementHash = (phone, entityType, entityId, code) =>
  hashOtp(phone, `${AGREEMENT_OTP_ROLE}:${entityType}:${entityId}`, code);

async function ownerPhone(userId) {
  const u = await queryOne(`SELECT phone FROM users WHERE id = $1`, [userId]);
  if (!u?.phone) throw badRequest('Add a mobile number to your account first');
  return u.phone;
}

/** POST /partner/agreement/otp { entityType, entityId } → { sent, expiresInSeconds, devOtp? } (OTP to the owner). */
router.post('/agreement/otp', async (req, res) => {
  const b = validate(entityBody, req.body ?? {});
  const listing = await assertOwnListing(b.entityType, b.entityId, req.user.id);
  if (listing.partnerAcceptedAt) throw conflict('You have already accepted the agreement for this listing');
  if (['live', 'rejected'].includes(listing.status)) throw badRequest(`This listing is ${listing.status}`);
  const phone = await ownerPhone(req.user.id);

  const recent = await queryOne(
    `SELECT COUNT(*) AS n FROM otp_codes WHERE phone = $1 AND role = $2 AND created_at > now() - interval '10 minutes'`,
    [phone, AGREEMENT_OTP_ROLE],
  );
  if (recent.n >= 5) throw new HttpError(429, 'Too many OTPs — please wait a few minutes and try again');

  const code = String(crypto.randomInt(100000, 1000000));
  await query(`UPDATE otp_codes SET consumed_at = now() WHERE phone = $1 AND role = $2 AND consumed_at IS NULL`, [
    phone,
    AGREEMENT_OTP_ROLE,
  ]);
  await query(
    `INSERT INTO otp_codes (phone, role, code_hash, expires_at) VALUES ($1, $2, $3, now() + make_interval(mins => $4))`,
    [phone, AGREEMENT_OTP_ROLE, agreementHash(phone, b.entityType, b.entityId, code), OTP_TTL_MINUTES],
  );
  await sendSms(
    phone,
    `${code} is your FITKEY Partner OTP to accept the partner agreement for ${listing.name ?? 'your listing'}. ` +
      `Valid for ${OTP_TTL_MINUTES} minutes. Do not share it with anyone.`,
  );
  res.json({ sent: true, expiresInSeconds: OTP_TTL_MINUTES * 60, ...(config.exposeDevOtp ? { devOtp: code } : {}) });
});

/**
 * POST /partner/agreement/accept { entityType, entityId, otp } → { agreement, listing }. Stores the accepted terms
 * (commission plan + payout rule snapshot), sets partner_accepted_at and goes live if the admin already approved.
 */
router.post('/agreement/accept', async (req, res) => {
  const b = validate(entityBody.extend({ otp: z.string().trim().regex(/^\d{6}$/, 'OTP must be 6 digits') }), req.body ?? {});
  const listing = await assertOwnListing(b.entityType, b.entityId, req.user.id);
  if (listing.status === 'rejected') throw badRequest('This listing was not approved');
  const phone = await ownerPhone(req.user.id);

  const record = await queryOne(
    `SELECT id, code_hash, attempts FROM otp_codes
     WHERE phone = $1 AND role = $2 AND consumed_at IS NULL AND expires_at > now()
     ORDER BY created_at DESC LIMIT 1`,
    [phone, AGREEMENT_OTP_ROLE],
  );
  if (!record) throw unauthorized('OTP expired — request a new one');
  if (record.attempts >= OTP_MAX_ATTEMPTS) throw new HttpError(429, 'Too many attempts — request a new OTP');
  const expected = Buffer.from(record.codeHash, 'hex');
  const actual = Buffer.from(agreementHash(phone, b.entityType, b.entityId, b.otp), 'hex');
  if (expected.length !== actual.length || !crypto.timingSafeEqual(expected, actual)) {
    await query(`UPDATE otp_codes SET attempts = attempts + 1 WHERE id = $1`, [record.id]);
    throw unauthorized('Incorrect OTP');
  }
  await query(`UPDATE otp_codes SET consumed_at = now() WHERE id = $1`, [record.id]);

  const owner = await queryOne(`SELECT partner_go_live_at FROM users WHERE id = $1`, [req.user.id]);
  const terms = {
    commissionPlan: commissionPlan(owner?.partnerGoLiveAt ?? null),
    payoutRule: PAYOUT_RULE,
    acceptedVia: 'otp',
    phoneLast4: phone.slice(-4),
    assistedBy: req.staffId ?? null,
  };
  const m = LISTING_ENTITIES[b.entityType];
  const agreement = await withTransaction(async (client) => {
    const a = await queryOne(
      `INSERT INTO partner_agreements (owner_id, entity_type, entity_id, version, terms)
       VALUES ($1, $2, $3, $4, $5::jsonb)
       ON CONFLICT (entity_type, entity_id, version) DO UPDATE SET owner_id = EXCLUDED.owner_id, terms = EXCLUDED.terms,
         accepted_at = now()
       RETURNING id, entity_type, entity_id, version, terms, accepted_at`,
      [req.user.id, b.entityType, b.entityId, AGREEMENT_VERSION, JSON.stringify(terms)],
      client,
    );
    await query(`UPDATE ${m.table} SET partner_accepted_at = COALESCE(partner_accepted_at, now()) WHERE id = $1`, [b.entityId], client);
    return a;
  });
  await maybeGoLive(b.entityType, b.entityId, req.user.id);
  const after = await loadListingMeta(b.entityType, b.entityId);
  res.json({
    agreement,
    listing: {
      entityType: b.entityType,
      entityId: b.entityId,
      name: after.name,
      status: after.status,
      partnerAcceptedAt: after.partnerAcceptedAt,
      adminApprovedAt: after.adminApprovedAt,
      goLiveAt: after.goLiveAt,
    },
  });
});

/** GET /partner/pending-acceptance — admin-approved listings waiting for this owner's OTP acceptance. */
router.get('/pending-acceptance', async (req, res) => {
  const items = await query(
    `SELECT l.entity_type, l.entity_id, l.name, s.name AS listed_by_name, l.admin_approved_at
     FROM (${listingsUnionSql()}) l LEFT JOIN users s ON s.id = l.listed_by
     WHERE l.owner_id = $1 AND l.status = 'approved' AND l.partner_accepted_at IS NULL
     ORDER BY l.admin_approved_at NULLS LAST`,
    [req.user.id],
  );
  res.json({ items });
});

// --------------------------------------------------------------------------------------------- assisted listing (§D)

/**
 * POST /partner/staff/partners { phone, name, partnerType, city? } → { partner, actAsToken } (staff's own token only).
 * Creates or finds the partner account; the act-as token carries a staffId claim (see middleware/auth.js).
 */
router.post('/staff/partners', requireStaff, async (req, res) => {
  const b = validate(
    z.object({
      phone: phoneSchema,
      name: z.string().trim().min(2).max(120),
      partnerType: z.enum(PARTNER_TYPES),
      city: z.string().trim().min(2).max(80).optional(),
    }),
    req.body ?? {},
  );
  const partner = await queryOne(
    `INSERT INTO users (phone, role, name, partner_type, city) VALUES ($1, 'partner', $2, $3, $4)
     ON CONFLICT (phone, role) DO UPDATE SET name = COALESCE(users.name, EXCLUDED.name),
       partner_type = COALESCE(users.partner_type, EXCLUDED.partner_type), city = COALESCE(users.city, EXCLUDED.city),
       updated_at = now()
     RETURNING id, phone, name, role, city, partner_type, is_fitkey_staff, partner_go_live_at, (xmax = 0) AS inserted`,
    [b.phone, b.name, b.partnerType, b.city ?? null],
  );
  if (partner.id === req.user.id || partner.isFitkeyStaff) throw forbidden('You cannot act for a FitKey staff account');
  const live = await queryOne(
    `SELECT 1 AS x FROM (${listingsUnionSql()}) l WHERE l.owner_id = $1 AND l.status = 'live' LIMIT 1`,
    [partner.id],
  );
  if (live) throw forbidden('This partner is already live — they manage their listings themselves');
  const { inserted, ...publicPartner } = partner;
  res.status(inserted ? 201 : 200).json({
    partner: { ...publicPartner, isNew: inserted },
    actAsToken: signAccessToken({ id: partner.id, role: 'partner' }, { staffId: req.user.id }),
  });
});

/** GET /partner/staff/listings — listings this employee created on behalf of partners. */
router.get('/staff/listings', requireStaff, async (req, res) => {
  const listings = await query(
    `SELECT l.entity_type, l.entity_id, l.name, l.status, l.created_at, l.submitted_at, l.admin_approved_at,
            l.partner_accepted_at, l.go_live_at, u.id AS partner_id, u.name AS partner_name, u.phone AS partner_phone
     FROM (${listingsUnionSql()}) l LEFT JOIN users u ON u.id = l.owner_id
     WHERE l.listed_by = $1 ORDER BY l.created_at DESC LIMIT 500`,
    [req.user.id],
  );
  res.json({ listings });
});

export default router;

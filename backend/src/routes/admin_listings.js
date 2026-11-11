import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../db/index.js';
import { badRequest, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { sendSms } from '../utils/sms.js';
import { LISTING_ENTITIES, LISTING_STATUSES, listingTimeline, maybeGoLive, setListingStatus } from '../utils/listing.js';
import { ENTITY_TYPES } from '../utils/partner_rules.js';
import { goLiveBlockers, onDocumentVerified } from '../utils/partner_types.js';
import { listingsUnionSql, loadListingMeta } from './partner_listing.js';
import { venueDetail } from './partner.js';

/**
 * FITKEY team: partner listing review queue across all partner types (Partner BRD §I), document / bank review,
 * staff flags and the assisted-listing report. Mounted inside routes/admin.js (requireAuth('admin') already ran).
 */
const router = Router();

const uuid = z.string().uuid();
const entityTypeSchema = z.enum(ENTITY_TYPES);
export const PARTNER_APP_LINK = 'https://play.google.com/store/apps/details?id=com.fitkey.fitkey_partner';

/**
 * Review action shared by POST /admin/listings/:entityType/:id/review and the legacy PATCH /admin/venues/:id/status.
 * approve: sets admin_approved_at; owner already accepted → live (maybeGoLive); otherwise status 'approved' and the
 * owner gets an SMS/WhatsApp with the app link ("log in with your mobile number").
 */
export async function reviewListing(entityType, id, action, { note = null, fixes = [], actorId = null } = {}) {
  const listing = await loadListingMeta(entityType, id);
  const m = LISTING_ENTITIES[entityType];
  switch (action) {
    case 'under_review':
      if (['live', 'approved'].includes(listing.status)) throw badRequest(`Listing is already ${listing.status}`);
      await setListingStatus(entityType, id, 'under_review', { note, actorId });
      break;
    case 'changes_needed':
      if (listing.status === 'live') throw badRequest('Listing is live');
      if (!fixes?.length && !note) throw badRequest('Tell the partner what to fix (fixes or note)');
      await setListingStatus(entityType, id, 'changes_needed', {
        note: (note ?? fixes.map((f) => f.message).join(' · ')).slice(0, 1000),
        fixes,
        actorId,
      });
      break;
    case 'reject':
      if (!note) throw badRequest('Add a note explaining the rejection');
      await setListingStatus(entityType, id, 'rejected', { note, actorId });
      break;
    case 'approve': {
      if (listing.status === 'live') throw badRequest('Listing is already live');
      // Type-specific go-live gates (e.g. supplements / healthy-food stores need a verified FSSAI licence).
      const blockers = goLiveBlockers(entityType, await queryOne(`SELECT * FROM ${m.table} WHERE id = $1`, [id]));
      if (blockers.length) {
        throw badRequest(`Cannot approve yet: ${blockers.map((x) => x.label).join('; ')}`, blockers);
      }
      if (listing.partnerAcceptedAt) {
        // Both approvals now in place → straight to live (timeline: approved, then live).
        await query(`UPDATE ${m.table} SET ${m.status} = 'approved', admin_approved_at = now() WHERE id = $1`, [id]);
        await query(
          `INSERT INTO listing_status_events (entity_type, entity_id, status, note, actor_id) VALUES ($1, $2, 'approved', $3, $4)`,
          [entityType, id, note, actorId],
        );
        await maybeGoLive(entityType, id, actorId);
      } else {
        await setListingStatus(entityType, id, 'approved', { note, actorId });
        const owner = listing.ownerId ? await queryOne(`SELECT phone FROM users WHERE id = $1`, [listing.ownerId]) : null;
        if (owner?.phone) {
          try {
            await sendSms(
              owner.phone,
              `FITKEY: ${listing.name ?? 'Your listing'} is approved. Accept the partner agreement to go live. ` +
                `Download FITKEY Partner: ${PARTNER_APP_LINK} — log in with your mobile number ${owner.phone}`,
            );
          } catch {
            /* best effort */
          }
        }
      }
      break;
    }
    default:
      throw badRequest('Unknown action');
  }
  return loadListingMeta(entityType, id);
}

// --------------------------------------------------------------------------------------------- queue

/** GET /admin/listings?status=&entityType= — default: submitted + under_review; status=all for everything. */
router.get('/listings', async (req, res) => {
  const q = validate(
    z.object({
      status: z.enum([...LISTING_STATUSES, 'all']).optional(),
      entityType: entityTypeSchema.optional(),
      q: z.string().trim().max(80).optional(),
    }),
    req.query,
  );
  const statuses = q.status === 'all' ? null : q.status ? [q.status] : ['submitted', 'under_review'];
  const listings = await query(
    `SELECT l.entity_type, l.entity_id, l.name, l.status, l.city, l.created_at, l.submitted_at, l.admin_approved_at,
            l.partner_accepted_at, l.go_live_at,
            o.id AS owner_id, o.name AS owner_name, o.phone AS owner_phone, o.partner_type,
            s.id AS listed_by, s.name AS listed_by_name,
            (SELECT COUNT(*) FROM partner_documents d WHERE d.entity_type = l.entity_type AND d.entity_id = l.entity_id) AS docs_total,
            (SELECT COUNT(*) FROM partner_documents d WHERE d.entity_type = l.entity_type AND d.entity_id = l.entity_id
               AND d.status = 'pending') AS docs_pending,
            (SELECT COUNT(*) FROM partner_documents d WHERE d.entity_type = l.entity_type AND d.entity_id = l.entity_id
               AND d.status = 'verified') AS docs_verified,
            (SELECT status FROM partner_kyc k WHERE k.owner_id = l.owner_id) AS kyc_status,
            (SELECT status FROM partner_bank_accounts b WHERE b.owner_id = l.owner_id AND b.is_primary
               ORDER BY b.created_at DESC LIMIT 1) AS bank_status
     FROM (${listingsUnionSql()}) l
     LEFT JOIN users o ON o.id = l.owner_id LEFT JOIN users s ON s.id = l.listed_by
     WHERE l.status IS NOT NULL AND ($1::text[] IS NULL OR l.status = ANY($1::text[]))
       AND ($2::text IS NULL OR l.entity_type = $2)
       AND ($3::text IS NULL OR l.name ILIKE '%' || $3 || '%' OR o.phone LIKE '%' || $3 || '%')
     ORDER BY l.submitted_at NULLS LAST, l.created_at DESC LIMIT 300`,
    [statuses, q.entityType ?? null, q.q || null],
  );
  res.json({ listings });
});

/** GET /admin/listings/:entityType/:id — full listing + owner + documents + KYC + bank (last 4) + timeline. */
router.get('/listings/:entityType/:id', async (req, res) => {
  const { entityType, id } = req.params;
  const meta = await loadListingMeta(entityType, id); // validates type + id, 404s
  const m = LISTING_ENTITIES[entityType];
  const row = await queryOne(`SELECT * FROM ${m.table} WHERE id = $1`, [id]);
  const ownerId = meta.ownerId;
  const listing = entityType === 'venue' ? await venueDetail(row) : row;
  const [owner, listedBy, documents, kyc, bank, agreements, timeline] = await Promise.all([
    ownerId
      ? queryOne(`SELECT id, name, phone, email, city, partner_type, is_fitkey_staff, partner_go_live_at FROM users WHERE id = $1`, [ownerId])
      : null,
    row.listedBy ? queryOne(`SELECT id, name, phone FROM users WHERE id = $1`, [row.listedBy]) : null,
    query(
      `SELECT id, doc_type, file_url, doc_number, expires_on, status, review_note, reviewed_at, created_at
       FROM partner_documents WHERE entity_type = $1 AND entity_id = $2 ORDER BY created_at`,
      [entityType, id],
    ),
    ownerId ? queryOne(`SELECT method, aadhaar_masked, name_on_id, status, verified_at FROM partner_kyc WHERE owner_id = $1`, [ownerId]) : null,
    ownerId
      ? queryOne(
          `SELECT id, holder_name, RIGHT(account_number, 4) AS last4, ifsc, bank_name, status, verified_name, verified_at
           FROM partner_bank_accounts WHERE owner_id = $1 AND is_primary ORDER BY created_at DESC LIMIT 1`,
          [ownerId],
        )
      : null,
    query(
      `SELECT id, version, terms, accepted_at FROM partner_agreements WHERE entity_type = $1 AND entity_id = $2 ORDER BY accepted_at DESC`,
      [entityType, id],
    ),
    listingTimeline(entityType, id),
  ]);
  res.json({ entityType, listing, owner, listedBy, documents, kyc, bank, agreements, timeline, goLiveBlockers: goLiveBlockers(entityType, row) });
});

/** POST /admin/listings/:entityType/:id/review { action, note?, fixes?:[{step,message}] } */
router.post('/listings/:entityType/:id/review', async (req, res) => {
  const b = validate(
    z.object({
      action: z.enum(['under_review', 'changes_needed', 'approve', 'reject']),
      note: z.string().trim().max(1000).optional(),
      fixes: z
        .array(z.object({ step: z.number().int().min(1).max(10), message: z.string().trim().min(2).max(300) }))
        .max(20)
        .optional(),
    }),
    req.body ?? {},
  );
  const listing = await reviewListing(req.params.entityType, req.params.id, b.action, {
    note: b.note || null,
    fixes: b.fixes ?? [],
    actorId: req.user.id,
  });
  res.json({ listing: { entityType: req.params.entityType, ...listing } });
});

// --------------------------------------------------------------------------------------------- documents & bank

/** POST /admin/partner-documents/:id { status: verified|rejected, note? } */
router.post('/partner-documents/:id', async (req, res) => {
  if (!uuid.safeParse(req.params.id).success) throw notFound('Document not found');
  const b = validate(
    z.object({ status: z.enum(['verified', 'rejected', 'pending']), note: z.string().trim().max(500).optional() }),
    req.body ?? {},
  );
  if (b.status === 'rejected' && !b.note) throw badRequest('Add a note explaining why the document was rejected');
  const doc = await queryOne(
    `UPDATE partner_documents SET status = $2, review_note = $3, reviewed_at = now() WHERE id = $1
     RETURNING id, owner_id, entity_type, entity_id, doc_type, file_url, doc_number, expires_on, status, review_note, reviewed_at, created_at`,
    [req.params.id, b.status, b.note ?? null],
  );
  if (!doc) throw notFound('Document not found');
  // Badges / go-live gates that depend on verified documents (trainer certificates, store FSSAI) — BRD §7.
  await onDocumentVerified(doc);
  if (b.status !== 'pending') {
    await notify(doc.ownerId, {
      type: `document_${b.status}`,
      title: b.status === 'verified' ? 'Document verified' : 'Document not accepted',
      body: b.note ?? null,
      data: { documentId: doc.id, entityType: doc.entityType, entityId: doc.entityId },
    });
  }
  res.json({ document: doc });
});

/** POST /admin/partner-bank/:id { status: verified|failed|pending } */
router.post('/partner-bank/:id', async (req, res) => {
  if (!uuid.safeParse(req.params.id).success) throw notFound('Bank account not found');
  const b = validate(z.object({ status: z.enum(['verified', 'failed', 'pending']), verifiedName: z.string().trim().max(160).optional() }), req.body ?? {});
  const account = await queryOne(
    `UPDATE partner_bank_accounts SET status = $2,
       verified_at = CASE WHEN $2 = 'verified' THEN now() ELSE NULL END,
       verified_name = CASE WHEN $2 = 'verified' THEN COALESCE($3, verified_name, holder_name) ELSE verified_name END
     WHERE id = $1
     RETURNING id, owner_id, holder_name, RIGHT(account_number, 4) AS last4, ifsc, bank_name, status, verified_name, verified_at, is_primary`,
    [req.params.id, b.status, b.verifiedName ?? null],
  );
  if (!account) throw notFound('Bank account not found');
  if (b.status !== 'pending') {
    await notify(account.ownerId, {
      type: `bank_${b.status}`,
      title: b.status === 'verified' ? 'Bank account verified' : 'Bank account could not be verified',
      body: b.status === 'verified' ? `Payouts go to the account ending ${account.last4}.` : 'Please add the account again.',
      data: { bankAccountId: account.id },
    });
  }
  res.json({ account });
});

// --------------------------------------------------------------------------------------------- staff

/** GET /admin/users?role=partner&q= — find accounts by name or phone (staff toggle in the admin panel). */
router.get('/users', async (req, res) => {
  const { role, q } = validate(
    z.object({ role: z.enum(['user', 'partner', 'admin']).optional(), q: z.string().trim().max(80).default('') }),
    req.query,
  );
  const digits = q.replace(/\D/g, '');
  const users = await query(
    `SELECT id, name, phone, role, city, partner_type, is_fitkey_staff, created_at FROM users
      WHERE ($1::text IS NULL OR role = $1)
        AND ($2 = '' OR name ILIKE '%' || $2 || '%' OR ($3 <> '' AND phone LIKE '%' || $3 || '%'))
      ORDER BY created_at DESC LIMIT 50`,
    [role ?? null, q, digits],
  );
  res.json({ users });
});

/** PUT /admin/users/:id/staff { isFitkeyStaff } — FitKey employees are partner accounts with this flag. */
router.put('/users/:id/staff', async (req, res) => {
  if (!uuid.safeParse(req.params.id).success) throw notFound('User not found');
  const b = validate(z.object({ isFitkeyStaff: z.boolean() }), req.body ?? {});
  const target = await queryOne(`SELECT id, role FROM users WHERE id = $1`, [req.params.id]);
  if (!target) throw notFound('User not found');
  if (b.isFitkeyStaff && target.role !== 'partner') throw badRequest('Staff must use a partner-app account (role partner)');
  const user = await queryOne(
    `UPDATE users SET is_fitkey_staff = $2, updated_at = now() WHERE id = $1
     RETURNING id, name, phone, role, city, partner_type, is_fitkey_staff`,
    [req.params.id, b.isFitkeyStaff],
  );
  res.json({ user });
});

/** GET /admin/staff-report — per employee: listings created, approved, live (assisted listing, BRD §8). */
router.get('/staff-report', async (_req, res) => {
  const staff = await query(
    `SELECT u.id, u.name, u.phone, u.is_fitkey_staff,
            COUNT(l.entity_id) AS listings_created,
            COUNT(l.entity_id) FILTER (WHERE l.status IN ('submitted', 'under_review', 'changes_needed')) AS in_review,
            COUNT(l.entity_id) FILTER (WHERE l.admin_approved_at IS NOT NULL) AS approved,
            COUNT(l.entity_id) FILTER (WHERE l.status = 'live') AS live,
            MAX(l.created_at) AS last_listing_at
     FROM users u LEFT JOIN (${listingsUnionSql()}) l ON l.listed_by = u.id
     WHERE u.is_fitkey_staff OR l.entity_id IS NOT NULL
     GROUP BY u.id ORDER BY live DESC, listings_created DESC, u.name`,
  );
  res.json({ staff });
});

export default router;

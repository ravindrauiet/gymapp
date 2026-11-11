/**
 * Shared listing lifecycle for every partner type (Partner BRD §6.4, §7, §8).
 *
 *   draft → submitted → under_review → (changes_needed → submitted …) → approved → live
 *                                     ↘ rejected
 *
 * A listing goes live only when BOTH the admin approved it AND the owner accepted the partner agreement by OTP.
 * Whichever happens last flips it to 'live' (see maybeGoLive). Every status change is written to
 * listing_status_events (the timeline) and the owner is notified (in-app + SMS/WhatsApp).
 */
import { query, queryOne } from '../db/index.js';
import { notify } from './notify.js';

/** entity_type → table, status column, owner column, display-name column. */
export const LISTING_ENTITIES = {
  venue: { table: 'venues', status: 'status', owner: 'owner_id', name: 'name' },
  trainer: { table: 'trainers', status: 'listing_status', owner: 'partner_id', name: 'name' },
  clinic: { table: 'health_clinics', status: 'listing_status', owner: 'owner_id', name: 'name' },
  chemist: { table: 'health_chemists', status: 'listing_status', owner: 'owner_id', name: 'name' },
  store: { table: 'marketplace_vendors', status: 'listing_status', owner: 'partner_id', name: 'business_name' },
};

export const LISTING_STATUSES = ['draft', 'submitted', 'under_review', 'changes_needed', 'approved', 'live', 'rejected'];

/** Target review time shown to partners ("within 48 hours"). */
export const REVIEW_TARGET_HOURS = 48;

const LABELS = {
  submitted: 'Submitted',
  under_review: 'Under review',
  changes_needed: 'Changes needed',
  approved: 'Approved — accept the agreement to go live',
  live: 'Live',
  rejected: 'Not approved',
};

export function entityMeta(entityType) {
  const m = LISTING_ENTITIES[entityType];
  if (!m) throw new Error(`Unknown listing entity: ${entityType}`);
  return m;
}

export async function getListing(entityType, id) {
  const m = entityMeta(entityType);
  return queryOne(`SELECT * FROM ${m.table} WHERE id = $1`, [id]);
}

/** Owner of a listing (users.id) or null. */
export async function listingOwner(entityType, id) {
  const m = entityMeta(entityType);
  const row = await queryOne(`SELECT ${m.owner} AS owner_id, ${m.name} AS name FROM ${m.table} WHERE id = $1`, [id]);
  return row ?? null;
}

/**
 * Writes a status change + timeline event and notifies the owner.
 * fixes: [{ step: 7, message: 'Add a monthly price' }] for changes_needed.
 */
export async function setListingStatus(entityType, id, status, { note = null, fixes = [], actorId = null, extraSet = '' } = {}) {
  if (!LISTING_STATUSES.includes(status)) throw new Error(`Bad status ${status}`);
  const m = entityMeta(entityType);
  const stamp =
    status === 'submitted' ? ', submitted_at = now()' : status === 'approved' ? ', admin_approved_at = now()' : '';
  const reviewNote = status === 'changes_needed' || status === 'rejected' ? ', review_note = $3' : status === 'live' || status === 'submitted' ? ', review_note = NULL' : '';
  const updatedAt = entityType === 'venue' ? ', updated_at = now()' : '';
  const params = [id, status];
  if (reviewNote.includes('$3')) params.push(note);
  const row = await queryOne(
    `UPDATE ${m.table} SET ${m.status} = $2${stamp}${reviewNote}${updatedAt}${extraSet} WHERE id = $1
     RETURNING *, ${m.owner} AS "zz_listing_owner", ${m.name} AS "zz_listing_name"`,
    params,
  );
  if (!row) return null;
  await query(
    `INSERT INTO listing_status_events (entity_type, entity_id, status, note, fixes, actor_id) VALUES ($1, $2, $3, $4, $5::jsonb, $6)`,
    [entityType, id, status, note, JSON.stringify(fixes ?? []), actorId],
  );
  const owner = row.zzListingOwner; // db layer camelCases aliases ("__owner" became "_Owner")
  delete row.zzListingOwner;
  const name = row.zzListingName;
  delete row.zzListingName;
  if (owner && LABELS[status]) {
    const body =
      status === 'changes_needed'
        ? `${fixes?.length ? fixes.map((f) => f.message).join(' · ') : note ?? 'Please update your listing.'}`
        : status === 'submitted'
          ? `We'll review it within ${REVIEW_TARGET_HOURS} hours.`
          : note ?? null;
    await notify(owner, {
      type: `listing_${status}`,
      title: `${name ?? 'Your listing'}: ${LABELS[status]}`,
      body,
      data: { entityType, entityId: id, status, ...(entityType === 'venue' ? { venueId: id } : {}) },
    });
    // SMS / WhatsApp at each status change (BRD §6.4) — best effort; sms.js decides the channel / dev logging.
    try {
      const { sendSms } = await import('./sms.js');
      const u = await queryOne(`SELECT phone FROM users WHERE id = $1`, [owner]);
      if (u?.phone && typeof sendSms === 'function') {
        await sendSms(u.phone, `FITKEY Partner: ${name ?? 'Your listing'} is now "${LABELS[status]}".${body ? ` ${body}` : ''}`);
      }
    } catch {
      /* messaging is best effort */
    }
  }
  return row;
}

/**
 * Flips an approved listing to live once the owner has also accepted the agreement. Sets go_live_at and the
 * partner's commission start date (users.partner_go_live_at) the first time any of their listings goes live.
 */
export async function maybeGoLive(entityType, id, actorId = null) {
  const m = entityMeta(entityType);
  const row = await queryOne(
    `SELECT ${m.status} AS status, admin_approved_at, partner_accepted_at, ${m.owner} AS owner_id FROM ${m.table} WHERE id = $1`,
    [id],
  );
  if (!row || row.status === 'live') return false;
  if (!row.adminApprovedAt || !row.partnerAcceptedAt) return false;
  if (!['approved', 'under_review', 'submitted'].includes(row.status)) return false;
  await setListingStatus(entityType, id, 'live', { actorId, extraSet: ', go_live_at = COALESCE(go_live_at, now())' });
  if (row.ownerId) {
    await query(`UPDATE users SET partner_go_live_at = COALESCE(partner_go_live_at, now()) WHERE id = $1`, [row.ownerId]);
  }
  return true;
}

/** Timeline for the app: events oldest → newest + the current status and review target. */
export async function listingTimeline(entityType, id) {
  const events = await query(
    `SELECT e.status, e.note, e.fixes, e.created_at, u.name AS actor_name
       FROM listing_status_events e LEFT JOIN users u ON u.id = e.actor_id
      WHERE e.entity_type = $1 AND e.entity_id = $2 ORDER BY e.created_at`,
    [entityType, id],
  );
  return { events, reviewTargetHours: REVIEW_TARGET_HOURS };
}

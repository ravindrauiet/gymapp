/**
 * Partner BRD §7 — trainers, clinics, chemists and store sellers (owner: backend-types).
 *
 * Pure helpers (checklist, submit validation, hours/slots, earnings maths) plus `onDocumentVerified(doc)`, which the
 * admin documents endpoint (`POST /admin/partner-documents/:id`) must call after it changes a document's status:
 * it keeps trainers.certificates_verified_at and marketplace_vendors.fssai_verified_at in step with the documents.
 *
 * Everything except onDocumentVerified is DB-free so it can be unit tested (partner_types.test.js).
 */
import { commissionPct } from './commission.js';

export const LISTING_TYPES = ['trainer', 'clinic', 'chemist', 'store'];

/** Steps for every non-venue partner type: profile → pricing → availability → documents → review. */
export const STEP_LABELS = { 1: 'Profile', 2: 'Pricing', 3: 'Availability', 4: 'Documents & bank', 5: 'Review & submit' };
export const STEP_COUNT = 5;

export const WEEKDAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

export const TRAINER_SUBTYPES = [
  'physiotherapist', 'yoga_master', 'gym_trainer_gym', 'gym_trainer_home', 'sports_coach',
  'boxing', 'karate', 'mma', 'dance', 'nutritionist',
];

/** BRD subtype → the member-app trainer category key (routes/trainers.js TRAINER_GROUPS). */
export const SUBTYPE_TO_TRAINER_TYPE = {
  physiotherapist: 'physiotherapist',
  yoga_master: 'yoga',
  gym_trainer_gym: 'personal_trainer',
  gym_trainer_home: 'personal_trainer',
  sports_coach: 'strength_conditioning',
  boxing: 'boxing',
  karate: 'judo_karate',
  mma: 'mma',
  dance: 'zumba',
  nutritionist: 'nutritionist',
};

export const STORE_CATEGORIES = ['supplements', 'activewear', 'gym_gear', 'healthy_food', 'wellness', 'accessories'];
/** Product / store categories that need a verified FSSAI licence before members can see them (BRD §7). */
export const FSSAI_CATEGORIES = ['supplements', 'healthy_food'];
/** Every category a marketplace product may have (legacy + BRD). */
export const PRODUCT_CATEGORIES = ['supplements', 'apparel', 'wearables', 'gear', ...STORE_CATEGORIES.filter((c) => c !== 'supplements')];

export const DOC_LABELS = {
  certificate: 'Upload your certificates',
  clinic_registration: 'Upload the clinic registration',
  doctor_registration: 'Upload the doctor registration',
  drug_licence: 'Upload the drug licence',
  gst: 'Upload the GST certificate',
  trademark: 'Upload brand / trademark proof',
  fssai: 'Upload the FSSAI licence (needed for supplements & food)',
};

/** Statuses from which a listing can be (re)submitted. NULL = legacy row, created before the BRD. */
export const SUBMITTABLE_STATUSES = [null, undefined, 'draft', 'changes_needed', 'rejected'];

/** Member apps show a partner listing only when it is legacy (NULL) or live. */
export const isMemberVisible = (status) => status == null || status === 'live';

const filled = (v) => v != null && (typeof v !== 'string' || v.trim().length > 0);
const nonEmpty = (a) => Array.isArray(a) && a.length > 0;

export const needsFssai = (categories) => (categories ?? []).some((c) => FSSAI_CATEGORIES.includes(c));

/** Document types a listing must have uploaded (pending or verified) before it can be submitted. */
export function requiredDocs(type, listing = {}) {
  switch (type) {
    case 'trainer':
      return ['certificate'];
    case 'clinic':
      return ['clinic_registration', 'doctor_registration'];
    case 'chemist':
      return ['drug_licence', 'gst'];
    case 'store':
      return ['gst', 'trademark', ...(needsFssai(listing?.categories) ? ['fssai'] : [])];
    default:
      throw new Error(`Unknown listing type: ${type}`);
  }
}

/** Missing requirements for steps 1–3 (type specific). */
function stepGaps(type, l, ctx) {
  const gaps = [];
  // Only the basics are required to submit (owner's call, Nov 2026); everything else is a recommended tip.
  const need = (ok, step, label, required = false) => {
    if (!ok) gaps.push({ step, label, required });
  };
  if (type === 'trainer') {
    const modes = l.trainingModes ?? [];
    need(filled(l.name), 1, 'Add your name', true);
    need(filled(l.photoUrl), 1, 'Add a profile photo');
    need(nonEmpty(l.subtypes), 1, 'Pick what you train (at least one type)', true);
    need(l.experienceYears != null, 1, 'Add your years of experience');
    need(nonEmpty(l.languages), 1, 'Add the languages you speak');
    need(nonEmpty(modes), 1, 'Choose how you train: online, at home or at gym');
    need(!modes.some((m) => m === 'home' || m === 'gym') || filled(l.serviceArea), 1, 'Add your service area');
    need((l.hourlyRatePaise ?? 0) > 0, 2, 'Set your price per hour / session');
    need(nonEmpty(l.weeklySlots), 3, 'Add your weekly slots');
    need((l.maxSessionsPerDay ?? 0) > 0, 3, 'Set the maximum sessions per day');
  } else if (type === 'clinic') {
    need(filled(l.name), 1, 'Add the clinic name', true);
    need(filled(l.speciality), 1, 'Add the speciality');
    need(nonEmpty(l.doctors), 1, 'Add at least one doctor');
    need(filled(l.city), 1, 'Add your city', true);
    need(filled(l.address), 1, 'Add the address');
    need(nonEmpty(l.photos), 1, 'Add at least one photo');
    need((l.consultationFeePaise ?? 0) > 0, 2, 'Set the consultation fee');
    need(nonEmpty(l.opdHours), 3, 'Add OPD days & hours');
    need((l.slotMinutes ?? 0) > 0, 3, 'Set the appointment slot length');
  } else if (type === 'chemist') {
    const delivers = l.homeDelivery ?? l.deliveryAvailable;
    need(filled(l.name), 1, 'Add the store name', true);
    need(filled(l.city), 1, 'Add your city', true);
    need(filled(l.address), 1, 'Add the address');
    need(nonEmpty(l.photos), 1, 'Add at least one photo');
    need(!delivers || (l.deliveryRadiusKm ?? 0) > 0, 1, 'Set the delivery radius');
    // 0 % is a valid choice, so the step counts once the partner moved past it or set a discount.
    need((l.discountPct ?? 0) > 0 || (l.listingStep ?? 1) > 2, 2, 'Set the discount on MRP');
    need(nonEmpty(l.openHours), 3, 'Add the open hours');
    need(l.homeDelivery != null, 3, 'Choose whether you do home delivery');
  } else if (type === 'store') {
    const products = ctx.products ?? [];
    const priced = products.filter((p) => p.isActive !== false && p.pricePaise > 0 && p.pricePaise <= (p.originalPricePaise ?? p.pricePaise));
    need(filled(l.brandName), 1, 'Add the brand name', true);
    need(filled(l.logoUrl), 1, 'Add the brand logo');
    need(filled(l.about) && l.about.trim().length >= 20, 1, 'Tell members about the brand (20+ characters)');
    need(nonEmpty(l.categories), 1, 'Pick your categories', true);
    need(priced.length > 0, 2, 'Add at least one product with MRP and selling price');
    need(products.some((p) => p.isActive !== false && (p.stockQuantity ?? 0) > 0), 3, 'Add stock for your products');
    need(l.dispatchDays != null, 3, 'Set the dispatch time');
  } else {
    throw new Error(`Unknown listing type: ${type}`);
  }
  return gaps;
}

/** Step 4: type-specific documents + KYC + bank (pending or verified counts as done, as for venues). */
function docGaps(type, l, ctx) {
  const gaps = [];
  const docs = (ctx.docs ?? []).filter((d) => d.status !== 'rejected');
  for (const t of requiredDocs(type, l)) {
    if (!docs.some((d) => d.docType === t)) gaps.push({ step: 4, label: DOC_LABELS[t] ?? `Upload ${t}`, required: false });
  }
  if (!ctx.kyc || ctx.kyc.status === 'rejected') gaps.push({ step: 4, label: 'Complete KYC (Aadhaar)', required: false });
  if (!ctx.bank || ctx.bank.status === 'failed') gaps.push({ step: 4, label: 'Add your bank account', required: false });
  return gaps;
}

/**
 * Setup checklist shown on the listing screen: { percent, done:[step], missing:[{step,label}] }.
 * `listing` is the camelCased row (or null before the first save); ctx = { docs, kyc, bank, products }.
 * Step 5 is done once the listing has been submitted (any status past draft / changes_needed / rejected).
 */
export function listingChecklist(type, listing, ctx = {}) {
  const l = listing ?? {};
  const gaps = listing ? [...stepGaps(type, l, ctx), ...docGaps(type, l, ctx)] : [];
  if (!listing) {
    for (let s = 1; s <= 4; s += 1) gaps.push({ step: s, label: `Complete ${STEP_LABELS[s].toLowerCase()}`, required: s === 1 });
  }
  const status = l.listingStatus ?? null;
  const submitted = listing && status != null && !SUBMITTABLE_STATUSES.includes(status);
  if (!submitted) gaps.push({ step: 5, label: 'Review & submit for verification' });
  const missingSteps = new Set(gaps.map((g) => g.step));
  const done = [];
  for (let s = 1; s <= STEP_COUNT; s += 1) if (!missingSteps.has(s)) done.push(s);
  return { percent: Math.round((done.length / STEP_COUNT) * 100), done, missing: gaps };
}

/** What still blocks submission: only the required basics. Empty array = ready to submit. */
export function submitMissing(type, listing, ctx = {}) {
  return listingChecklist(type, listing, ctx).missing.filter((m) => m.step < 5 && m.required);
}

/**
 * Reasons an approved listing must not go live yet, beyond the shared admin-approval + OTP rule.
 * Store sellers with supplements / healthy food need a verified FSSAI licence.
 */
export function goLiveBlockers(type, listing) {
  const out = [];
  if (type === 'store' && needsFssai(listing?.categories) && !listing?.fssaiVerifiedAt) {
    out.push({ step: 4, label: 'FSSAI licence must be verified before supplements / food can go live' });
  }
  return out;
}

/** Trainer "Verified" badge: legacy rows keep verification_status; partner listings need checked certificates. */
export function trainerVerifiedBadge(t) {
  if (!t) return false;
  if (t.listingStatus == null) return t.verificationStatus === 'verified';
  return t.certificatesVerifiedAt != null;
}

/** Maps BRD subtypes to member-app trainer types (deduped). */
export function subtypesToTrainerTypes(subtypes = []) {
  return [...new Set(subtypes.map((s) => SUBTYPE_TO_TRAINER_TYPE[s]).filter(Boolean))];
}

// ------------------------------------------------------------------------------------------------ hours & slots

const toMin = (hhmm) => {
  const [h, m] = String(hhmm).split(':').map(Number);
  return h * 60 + m;
};
const toHhmm = (min) => `${String(Math.floor(min / 60)).padStart(2, '0')}:${String(min % 60).padStart(2, '0')}`;
const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);

/** Weekday key (mon…sun) of a YYYY-MM-DD date (UTC calendar day). */
export function weekdayOf(ymd) {
  const d = new Date(`${ymd}T00:00:00Z`).getUTCDay(); // 0 = Sunday
  return WEEKDAYS[(d + 6) % 7];
}

/**
 * Human label for hours rows [{weekday, opensAt, closesAt}] (or trainer slots {weekday, start, end}),
 * e.g. "Mon–Fri 10:00–14:00, 17:00–20:00 · Sat 10:00–13:00". Consecutive days with identical hours are merged.
 */
export function hoursLabel(hours = []) {
  const byDay = WEEKDAYS.map((d) => {
    const ranges = hours
      .filter((h) => h.weekday === d)
      .map((h) => [h.opensAt ?? h.start, h.closesAt ?? h.end])
      .sort((a, b) => toMin(a[0]) - toMin(b[0]))
      .map(([a, b]) => `${a}–${b}`)
      .join(', ');
    return { d, ranges };
  });
  const parts = [];
  let i = 0;
  while (i < 7) {
    if (!byDay[i].ranges) {
      i += 1;
      continue;
    }
    let j = i;
    while (j + 1 < 7 && byDay[j + 1].ranges === byDay[i].ranges) j += 1;
    const days = i === j ? cap(byDay[i].d) : `${cap(byDay[i].d)}–${cap(byDay[j].d)}`;
    parts.push(`${days} ${byDay[i].ranges}`);
    i = j + 1;
  }
  return parts.join(' · ');
}

/** Slot start times (HH:MM) for one weekday from hours rows, `slotMinutes` apart, each slot fully inside a range. */
export function slotsForDay(hours = [], weekday, slotMinutes = 15) {
  const step = Math.max(5, slotMinutes | 0);
  const out = new Set();
  for (const h of hours) {
    if (h.weekday !== weekday) continue;
    const start = toMin(h.opensAt ?? h.start);
    const end = toMin(h.closesAt ?? h.end);
    for (let t = start; t + step <= end; t += step) out.add(toHhmm(t));
  }
  return [...out].sort();
}

/** True when start < end for "HH:MM" strings. */
export const timeRangeOk = (start, end) => toMin(start) < toMin(end);

// ------------------------------------------------------------------------------------------------ money

/**
 * Earnings for partner types whose sales are direct (trainer sessions, clinic consultations, chemist orders,
 * store sales). Commission follows the founding-partner plan (commission.js, by year from go-live); no GST is
 * deducted here — these amounts are what the member paid the partner through FitKey.
 * rows: [{ date:'YYYY-MM-DD', grossPaise, source? }]
 */
export function earningsSummary(rows = [], goLiveAt = null) {
  const totals = { count: 0, grossPaise: 0, commissionPaise: 0, netPaise: 0 };
  const days = new Map();
  const sources = new Map();
  for (const r of rows) {
    const gross = Math.max(0, Math.round(Number(r.grossPaise) || 0));
    const pct = commissionPct(goLiveAt, r.date ? `${r.date}T12:00:00Z` : new Date());
    const commission = Math.round((gross * pct) / 100);
    const net = gross - commission;
    totals.count += 1;
    totals.grossPaise += gross;
    totals.commissionPaise += commission;
    totals.netPaise += net;
    if (r.date) days.set(r.date, (days.get(r.date) ?? 0) + net);
    const src = r.source ?? 'fitkey';
    const s = sources.get(src) ?? { source: src, count: 0, grossPaise: 0, commissionPaise: 0, netPaise: 0 };
    s.count += 1;
    s.grossPaise += gross;
    s.commissionPaise += commission;
    s.netPaise += net;
    sources.set(src, s);
  }
  return {
    totals,
    bySource: [...sources.values()],
    byDay: [...days.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([date, netPaise]) => ({ date, netPaise })),
    commissionPct: commissionPct(goLiveAt),
  };
}

/** Today's date (YYYY-MM-DD) in India. */
export const todayIst = (now = Date.now()) => new Date(now + 5.5 * 3_600_000).toISOString().slice(0, 10);

/** Allowed clinic appointment status moves (patient queue). */
export const CLINIC_TRANSITIONS = {
  booked: ['checked_in', 'in_consultation', 'completed', 'cancelled', 'no_show'],
  checked_in: ['in_consultation', 'completed', 'cancelled', 'no_show', 'booked'],
  in_consultation: ['completed', 'checked_in'],
  no_show: ['checked_in', 'booked'],
  completed: [],
  cancelled: [],
};

/** Allowed chemist order status moves (accept → pack → deliver / pickup). */
export const CHEMIST_TRANSITIONS = {
  requested: ['accepted', 'rejected'],
  accepted: ['packed', 'out_for_delivery', 'picked_up', 'cancelled'],
  packed: ['out_for_delivery', 'picked_up', 'cancelled'],
  out_for_delivery: ['delivered'],
  delivered: [],
  picked_up: [],
  rejected: [],
  cancelled: [],
};

/** Chemist bill: MRP minus the store's discount %, in paise. */
export function chemistBill(mrpPaise, discountPct = 0) {
  const mrp = Math.max(0, Math.round(mrpPaise));
  const discount = Math.round((mrp * Math.min(90, Math.max(0, discountPct))) / 100);
  return { mrpPaise: mrp, discountPaise: discount, amountPaise: mrp - discount };
}

// ------------------------------------------------------------------------------------------------ admin hook

/**
 * Call after an admin verifies / rejects a partner document (POST /admin/partner-documents/:id).
 * doc: the partner_documents row (camelCase or snake_case). Recomputes, from the documents themselves:
 *   trainer + certificate → trainers.certificates_verified_at ("Verified" badge)
 *   store   + fssai       → marketplace_vendors.fssai_verified_at (supplements / food visible to members)
 * A verified document counts while it has not expired. Returns { field, verified } or null when not relevant.
 */
export async function onDocumentVerified(doc) {
  if (!doc) return null;
  const entityType = doc.entityType ?? doc.entity_type;
  const entityId = doc.entityId ?? doc.entity_id;
  const docType = doc.docType ?? doc.doc_type;
  const target =
    entityType === 'trainer' && docType === 'certificate'
      ? { table: 'trainers', field: 'certificates_verified_at' }
      : entityType === 'store' && docType === 'fssai'
        ? { table: 'marketplace_vendors', field: 'fssai_verified_at' }
        : null;
  if (!target || !entityId) return null;
  const { queryOne } = await import('../db/index.js');
  const row = await queryOne(
    `UPDATE ${target.table} SET ${target.field} = CASE
        WHEN EXISTS (SELECT 1 FROM partner_documents d
                      WHERE d.entity_type = $2 AND d.entity_id = $1 AND d.doc_type = $3 AND d.status = 'verified'
                        AND (d.expires_on IS NULL OR d.expires_on >= current_date))
        THEN COALESCE(${target.field}, now()) ELSE NULL END
      WHERE id = $1 RETURNING ${target.field} AS v`,
    [entityId, entityType, docType],
  );
  return row ? { field: target.field, verified: row.v != null } : null;
}

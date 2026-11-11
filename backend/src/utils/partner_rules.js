/**
 * Pure helpers for the Partner BRD listing flow (no DB / config imports, so they are unit-testable):
 * venue checklist (10 steps), Aadhaar masking, IFSC / bank-number checks, the assisted-listing (act-as) path guard.
 * Contract: docs/partner_brd_contract.md §A–§E.
 */

export const PARTNER_TYPES = ['fitness_centre', 'sports_centre', 'trainer', 'clinic', 'chemist', 'store_seller'];
export const SPORTS = ['badminton', 'table_tennis', 'cricket', 'football', 'basketball', 'tennis', 'squash', 'skating', 'swimming'];
/** Venue category that unlocks the sports multi-select. */
export const SPORTS_CATEGORY = 'sports_club';
export const DOC_TYPES = ['licence', 'gst', 'fssai', 'drug_licence', 'clinic_registration', 'doctor_registration',
  'certificate', 'achievement', 'trademark', 'other'];
export const ENTITY_TYPES = ['venue', 'trainer', 'clinic', 'chemist', 'store'];

export const DESCRIPTION_MIN = 40;
export const PHOTOS_MIN = 4;
export const PHOTOS_MAX = 10;

/** Venue listing steps (BRD §6). */
export const VENUE_STEPS = [
  { step: 1, label: 'Category' },
  { step: 2, label: 'Details' },
  { step: 3, label: 'Location' },
  { step: 4, label: 'Timings & FitKey access' },
  { step: 5, label: 'Photos' },
  { step: 6, label: 'Facilities' },
  { step: 7, label: 'Pricing & FitKey pass' },
  { step: 8, label: 'Slots & capacity' },
  { step: 9, label: 'Documents & bank' },
  { step: 10, label: 'Review & submit' },
];

const len = (a) => (Array.isArray(a) ? a.length : 0);
const str = (s) => (typeof s === 'string' ? s.trim() : '');

/**
 * Checklist for a venue listing.
 * @param venue camelCased venues row (categories, sports, name, description, address, city, latitude, longitude,
 *              opensAt, closesAt, fitkeyPassMode, photos, amenities, equipment, monthlyFeePaise, passAccepted,
 *              slotMinutes, slotCapacity, status)
 * @param ctx   { hoursCount, passBlocksCount, activePlans, hasLicence, hasKyc, hasBank }
 * @returns { percent, done:[step], missing:[{step,label,hint}] }
 */
export function venueChecklist(venue, ctx = {}) {
  const v = venue ?? {};
  const cats = Array.isArray(v.categories) ? v.categories : [];
  const checks = {
    1: cats.length > 0 && (!cats.includes(SPORTS_CATEGORY) || len(v.sports) > 0)
      ? null
      : cats.length ? 'Pick the sports you offer' : 'Pick a category',
    2: str(v.name).length < 2
      ? 'Add your centre name'
      : str(v.description).length < DESCRIPTION_MIN
        ? `Write a description of at least ${DESCRIPTION_MIN} characters`
        : null,
    3: str(v.address).length < 5 || str(v.city).length < 2
      ? 'Add your address and city'
      : v.latitude == null || v.longitude == null
        ? 'Pin your location on the map'
        : null,
    4: !((ctx.hoursCount ?? 0) > 0 || (v.opensAt && v.closesAt))
      ? 'Add your opening hours'
      : v.fitkeyPassMode === 'blocked' && !((ctx.passBlocksCount ?? 0) > 0)
        ? 'Add the hours when the FitKey pass is not valid'
        : null,
    5: len(v.photos) >= PHOTOS_MIN ? null : `Add at least ${PHOTOS_MIN} photos`,
    6: len(v.amenities) > 0 || len(v.equipment) > 0 ? null : 'Add your facilities',
    7: !((ctx.activePlans ?? 0) > 0)
      ? 'Add at least one membership plan'
      : !(v.monthlyFeePaise > 0)
        ? 'Add your monthly fee'
        : !v.passAccepted
          ? 'Accept FitKey pass members'
          : null,
    8: v.slotMinutes > 0 && v.slotCapacity > 0 ? null : 'Set slot length and capacity',
    9: !ctx.hasLicence
      ? 'Upload your business licence'
      : !ctx.hasKyc
        ? 'Complete owner KYC'
        : !ctx.hasBank
          ? 'Add your bank account'
          : null,
    10: ['draft', 'changes_needed', 'rejected', undefined, null].includes(v.status) ? 'Review and submit' : null,
  };
  const done = [];
  const missing = [];
  for (const s of VENUE_STEPS) {
    if (checks[s.step]) missing.push({ step: s.step, label: s.label, hint: checks[s.step] });
    else done.push(s.step);
  }
  return { percent: Math.round((done.length / VENUE_STEPS.length) * 100), done, missing };
}

/** Steps that block submission (everything but step 10 itself). */
export const submitBlockers = (checklist) => checklist.missing.filter((m) => m.step !== 10);

// ------------------------------------------------------------------------------------------------------- KYC

export const AADHAAR_MASK_RE = /^XXXX-XXXX-\d{4}$/;

/**
 * Turns what the app sent into `XXXX-XXXX-1234`. Accepts the last 4 digits ("1234") or an already-masked value.
 * Throws on anything that looks like a full Aadhaar (≥ 8 digits) — we never accept or store the full number.
 */
export function maskAadhaar(input) {
  const s = String(input ?? '').trim().toUpperCase();
  const digits = s.replace(/\D/g, '');
  if (digits.length >= 8) throw new Error('Send only the last 4 digits of the Aadhaar number');
  if (/^\d{4}$/.test(s)) return `XXXX-XXXX-${s}`;
  const masked = s.replace(/\s/g, '-');
  if (AADHAAR_MASK_RE.test(masked)) return masked;
  throw new Error('Enter the last 4 digits of the Aadhaar number');
}

// ------------------------------------------------------------------------------------------------------- bank

export const IFSC_RE = /^[A-Z]{4}0[A-Z0-9]{6}$/;
export const normalizeIfsc = (s) => String(s ?? '').replace(/\s/g, '').toUpperCase();
export const isValidIfsc = (s) => IFSC_RE.test(normalizeIfsc(s));
export const normalizeAccountNumber = (s) => String(s ?? '').replace(/[\s-]/g, '');
/** Indian bank account numbers: 9–18 digits. */
export const isValidAccountNumber = (s) => /^\d{9,18}$/.test(normalizeAccountNumber(s));

const BANKS = {
  SBIN: 'State Bank of India', HDFC: 'HDFC Bank', ICIC: 'ICICI Bank', UTIB: 'Axis Bank', KKBK: 'Kotak Mahindra Bank',
  PUNB: 'Punjab National Bank', BARB: 'Bank of Baroda', CNRB: 'Canara Bank', UBIN: 'Union Bank of India',
  IDIB: 'Indian Bank', YESB: 'Yes Bank', IDFB: 'IDFC FIRST Bank', BKID: 'Bank of India', INDB: 'IndusInd Bank',
  FDRL: 'Federal Bank', MAHB: 'Bank of Maharashtra', CBIN: 'Central Bank of India', IOBA: 'Indian Overseas Bank',
  UCBA: 'UCO Bank', PSIB: 'Punjab & Sind Bank', AUBL: 'AU Small Finance Bank', RATN: 'RBL Bank',
};
export const bankNameFromIfsc = (ifsc) => BANKS[normalizeIfsc(ifsc).slice(0, 4)] ?? null;

// ------------------------------------------------------------------------------------------------------- email

/** Cleans an e-mail typed on a phone: trims, drops zero-width chars, lower-cases. '' → undefined (not provided). */
export function cleanEmail(v) {
  if (typeof v !== 'string') return v;
  const s = v.replace(/[​-‍⁠﻿]/g, '').trim().toLowerCase();
  return s === '' ? undefined : s;
}

// ------------------------------------------------------------------------------------------------------- act-as guard

/**
 * Paths a FitKey employee acting for a partner (token with a staffId claim) may never call: money and member data.
 * Matched against the URL without the /api/v1 prefix and query string.
 */
const STAFF_BLOCKED = [
  /^\/partner\/earnings(\/|$)/,
  /^\/partner\/payouts(\/|$)/,
  /^\/partner\/venues\/[^/]+\/members(\/|$)/,
  /^\/partner\/bank\/full(\/|$)/,
  /^\/partner\/vendor\/commissions(\/|$)/,
  /^\/partner\/statements?(\/|$)/,
  /^\/memberships\/partner\/earnings(\/|$)/,
  /^\/memberships\/partner\/statement(\/|$)/,
  /^\/memberships\/partner\/venues\/[^/]+\/(members|fitkey-visitors)(\/|$)/,
  /^\/bookings\/partner\/venues\/[^/]+\/visits(\/|$)/,
  /^\/partner\/staff(\/|$)/, // staff tools need the employee's own token
];

export function staffBlockedPath(_method, url) {
  let p = String(url ?? '').split('?')[0].split('#')[0];
  p = p.replace(/^\/api\/v1(?=\/)/, '').replace(/\/{2,}/g, '/');
  if (p.length > 1) p = p.replace(/\/+$/, '');
  p = p.toLowerCase();
  return STAFF_BLOCKED.some((re) => re.test(p));
}

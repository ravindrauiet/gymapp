/**
 * Partner BRD §7 / §10.4 — trainers, clinics, chemists and store sellers (owner: backend-types).
 *
 *   /partner/listing/{trainer|clinic|chemist|store}          GET · PUT        listing + checklist + timeline
 *   /partner/listing/{trainer|clinic|chemist|store}/submit   POST             → setListingStatus('submitted')
 *   /partner/clinic/*                                                         appointments, patient queue, earnings
 *   /partner/chemist/*                                                        orders & delivery status, earnings
 *
 * Trainer run endpoints live in routes/trainers.js (/partner/trainer/*), store seller ones in routes/marketplace.js
 * (/partner/vendor/*). Contract: docs/partner_brd_contract.md §H.
 */
import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { commissionPct } from '../utils/commission.js';
import { badRequest, conflict, forbidden, notFound, validate } from '../utils/http.js';
import { LISTING_ENTITIES, listingTimeline, REVIEW_TARGET_HOURS, setListingStatus } from '../utils/listing.js';
import { notify } from '../utils/notify.js';
import {
  CHEMIST_TRANSITIONS,
  chemistBill,
  CLINIC_TRANSITIONS,
  earningsSummary,
  goLiveBlockers,
  hoursLabel,
  listingChecklist,
  PRODUCT_CATEGORIES,
  STORE_CATEGORIES,
  submitMissing,
  SUBMITTABLE_STATUSES,
  subtypesToTrainerTypes,
  timeRangeOk,
  todayIst,
  TRAINER_SUBTYPES,
  trainerVerifiedBadge,
  WEEKDAYS,
} from '../utils/partner_types.js';
import { dateSchema, timeSchema } from '../utils/schemas.js';

// ------------------------------------------------------------------------------------------------ schemas

const weekday = z.enum(WEEKDAYS);
const hhmm = timeSchema.transform((s) => s.slice(0, 5));
const hoursRow = z
  .object({ weekday, opensAt: hhmm, closesAt: hhmm })
  .refine((h) => timeRangeOk(h.opensAt, h.closesAt), 'opensAt must be before closesAt');
const slotRow = z
  .object({ weekday, start: hhmm, end: hhmm })
  .refine((h) => timeRangeOk(h.start, h.end), 'start must be before end');
const url = z.string().trim().min(1).max(2000);
const str = (max) => z.string().trim().max(max);
const listingStep = z.number().int().min(1).max(5);

const trainerSchema = z.object({
  name: str(160).min(2).optional(),
  photoUrl: url.nullable().optional(),
  bio: str(4000).optional(),
  subtypes: z.array(z.enum(TRAINER_SUBTYPES)).max(10).optional(),
  trainerTypes: z.array(z.string().max(40)).max(12).optional(),
  experienceYears: z.number().int().min(0).max(60).nullable().optional(),
  achievements: z.array(str(200)).max(20).optional(),
  languages: z.array(str(40)).max(12).optional(),
  trainingModes: z.array(z.enum(['online', 'home', 'gym'])).max(3).optional(),
  serviceArea: str(160).nullable().optional(),
  certifications: z.array(str(160)).max(20).optional(),
  specializations: z.array(str(80)).max(20).optional(),
  hourlyRatePaise: z.number().int().min(10000).nullable().optional(), // ≥ ₹100
  packages: z
    .array(z.object({ name: str(80).min(1), sessions: z.number().int().min(1).max(500), pricePaise: z.number().int().min(0) }))
    .max(10)
    .optional(),
  weeklySlots: z.array(slotRow).max(70).optional(),
  maxSessionsPerDay: z.number().int().min(1).max(24).nullable().optional(),
  bufferMinutes: z.number().int().min(0).max(120).optional(),
  listingStep: listingStep.optional(),
});

const doctor = z.object({
  name: str(120).min(2),
  specialty: str(80).optional(),
  degree: str(80).optional(),
  registrationNo: str(40).optional(),
  experienceYears: z.number().int().min(0).max(70).optional(),
  photoUrl: url.optional(),
});

const clinicSchema = z.object({
  name: str(160).min(2).optional(),
  speciality: str(80).nullable().optional(),
  doctors: z.array(doctor).max(30).optional(),
  address: str(500).optional(),
  area: str(120).nullable().optional(),
  city: str(80).optional(),
  phone: str(20).optional(),
  latitude: z.number().min(-90).max(90).nullable().optional(),
  longitude: z.number().min(-180).max(180).nullable().optional(),
  photos: z.array(url).max(10).optional(),
  facilities: z.array(str(80)).max(30).optional(),
  consultationFeePaise: z.number().int().min(0).optional(),
  opdHours: z.array(hoursRow).max(70).optional(),
  slotMinutes: z.number().int().min(5).max(120).optional(),
  listingStep: listingStep.optional(),
});

const chemistSchema = z.object({
  name: str(160).min(2).optional(),
  address: str(500).optional(),
  area: str(120).nullable().optional(),
  city: str(80).optional(),
  phone: str(20).optional(),
  latitude: z.number().min(-90).max(90).nullable().optional(),
  longitude: z.number().min(-180).max(180).nullable().optional(),
  photos: z.array(url).max(10).optional(),
  deliveryRadiusKm: z.number().min(0).max(50).nullable().optional(),
  discountPct: z.number().int().min(0).max(90).optional(),
  openHours: z.array(hoursRow).max(70).optional(),
  homeDelivery: z.boolean().optional(),
  deliveryTimeEst: str(60).optional(),
  listingStep: listingStep.optional(),
});

const storeSchema = z.object({
  businessName: str(160).min(2).optional(),
  brandName: str(160).min(2).optional(),
  logoUrl: url.nullable().optional(),
  about: str(2000).optional(),
  categories: z.array(z.enum(STORE_CATEGORIES)).max(6).optional(),
  gstin: str(30).nullable().optional(),
  dispatchDays: z.number().int().min(0).max(30).nullable().optional(),
  listingStep: listingStep.optional(),
});

/**
 * Per type: zod schema, writable fields (camelCase key → column; json: stored as JSONB), and the extra columns
 * derived on save. Column names here are a fixed whitelist — never user input.
 */
const TYPES = {
  trainer: {
    schema: trainerSchema,
    fields: {
      name: 'name', photoUrl: 'photo_url', bio: 'bio', subtypes: 'subtypes', trainerTypes: 'trainer_types',
      experienceYears: 'experience_years', achievements: 'achievements', languages: 'languages',
      trainingModes: 'training_modes', serviceArea: 'service_area', certifications: 'certifications',
      specializations: 'specializations', hourlyRatePaise: 'hourly_rate_paise', packages: ['packages', 'json'],
      weeklySlots: ['weekly_slots', 'json'], maxSessionsPerDay: 'max_sessions_per_day', bufferMinutes: 'buffer_minutes',
      listingStep: 'listing_step',
    },
    derive(d) {
      const extra = {};
      if (d.subtypes && !d.trainerTypes) {
        const t = subtypesToTrainerTypes(d.subtypes);
        if (t.length) extra.trainer_types = t;
      }
      if (d.weeklySlots?.length) {
        const starts = d.weeklySlots.map((s) => s.start).sort();
        const ends = d.weeklySlots.map((s) => s.end).sort();
        extra.working_hours = ['json', { start: starts[0], end: ends[ends.length - 1] }];
      }
      return extra;
    },
  },
  clinic: {
    schema: clinicSchema,
    fields: {
      name: 'name', speciality: 'speciality', doctors: ['doctors', 'json'], address: 'address', area: 'area',
      city: 'city', phone: 'phone', latitude: 'latitude', longitude: 'longitude', photos: 'photos',
      facilities: 'facilities', consultationFeePaise: 'consultation_fee_paise', opdHours: ['opd_hours', 'json'],
      slotMinutes: 'slot_minutes', listingStep: 'listing_step',
    },
    derive(d) {
      return d.opdHours ? { slot_timings: hoursLabel(d.opdHours).slice(0, 120) } : {};
    },
  },
  chemist: {
    schema: chemistSchema,
    fields: {
      name: 'name', address: 'address', area: 'area', city: 'city', phone: 'phone', latitude: 'latitude',
      longitude: 'longitude', photos: 'photos', deliveryRadiusKm: 'delivery_radius_km', discountPct: 'discount_pct',
      openHours: ['open_hours', 'json'], homeDelivery: 'home_delivery', deliveryTimeEst: 'delivery_time_est',
      listingStep: 'listing_step',
    },
    derive(d) {
      const extra = {};
      if (d.openHours) extra.operational_hours = hoursLabel(d.openHours).slice(0, 80);
      if (d.homeDelivery != null) extra.delivery_available = d.homeDelivery;
      return extra;
    },
  },
  store: {
    schema: storeSchema,
    fields: {
      businessName: 'business_name', brandName: 'brand_name', logoUrl: 'logo_url', about: 'about',
      categories: 'categories', gstin: 'gstin', dispatchDays: 'dispatch_days', listingStep: 'listing_step',
    },
    derive: () => ({}),
  },
};

// ------------------------------------------------------------------------------------------------ helpers

const typeParam = z.enum(['trainer', 'clinic', 'chemist', 'store']);

/** The owner's listing of a type (one per owner per type). */
async function ownerListing(type, ownerId) {
  const m = LISTING_ENTITIES[type];
  return queryOne(`SELECT * FROM ${m.table} WHERE ${m.owner} = $1 ORDER BY created_at LIMIT 1`, [ownerId]);
}

/** Documents, KYC, bank and (store) products used by the checklist. */
async function listingContext(type, listing, ownerId) {
  const docs = listing
    ? await query(
        `SELECT id, doc_type, file_url, doc_number, expires_on, status, review_note, created_at
           FROM partner_documents WHERE entity_type = $1 AND entity_id = $2 ORDER BY created_at DESC`,
        [type, listing.id],
      )
    : [];
  const kyc = await queryOne(`SELECT method, aadhaar_masked, name_on_id, status, verified_at FROM partner_kyc WHERE owner_id = $1`, [ownerId]);
  const bank = await queryOne(
    `SELECT id, holder_name, right(account_number, 4) AS last4, ifsc, bank_name, status, verified_name, verified_at
       FROM partner_bank_accounts WHERE owner_id = $1 ORDER BY is_primary DESC, created_at DESC LIMIT 1`,
    [ownerId],
  );
  const products =
    type === 'store' && listing
      ? await query(
          `SELECT id, category, price_paise, original_price_paise, stock_quantity, is_active FROM marketplace_products WHERE vendor_id = $1`,
          [listing.id],
        )
      : [];
  return { docs, kyc, bank, products };
}

/** Listing JSON for the app: never the vendor's legacy full bank account number. */
function present(type, listing, ctx) {
  if (!listing) return null;
  const out = { ...listing, entityType: type, status: listing.listingStatus ?? null };
  if (type === 'trainer') out.verifiedBadge = trainerVerifiedBadge(listing);
  if (type === 'clinic') out.opdHoursLabel = hoursLabel(listing.opdHours ?? []);
  if (type === 'chemist') out.openHoursLabel = hoursLabel(listing.openHours ?? []);
  if (type === 'store') {
    if (out.bankAccountNo) out.bankAccountNo = `XXXX${String(out.bankAccountNo).slice(-4)}`;
    out.fssaiRequired = (listing.categories ?? []).some((c) => c === 'supplements' || c === 'healthy_food');
    out.productsSummary = {
      total: ctx.products.length,
      active: ctx.products.filter((p) => p.isActive).length,
      inStock: ctx.products.filter((p) => p.isActive && p.stockQuantity > 0).length,
    };
  }
  return out;
}

async function listingPayload(type, listing, ownerId) {
  const ctx = await listingContext(type, listing, ownerId);
  return {
    listing: present(type, listing, ctx),
    checklist: listingChecklist(type, listing, ctx),
    timeline: listing ? await listingTimeline(type, listing.id) : { events: [], reviewTargetHours: REVIEW_TARGET_HOURS },
    documents: ctx.docs,
    goLiveBlockers: listing ? goLiveBlockers(type, listing) : [],
  };
}

/** Creates the listing row on the first save (status draft; listed_by = acting staff). */
async function createListing(type, ownerId, data, staffId) {
  const user = await queryOne(`SELECT name, phone FROM users WHERE id = $1`, [ownerId]);
  const fallbackName = (data.name ?? data.brandName ?? data.businessName ?? user?.name ?? '').trim() || 'My listing';
  const phone = data.phone ?? user?.phone ?? '';
  switch (type) {
    case 'trainer':
      return queryOne(
        `INSERT INTO trainers (partner_id, name, bio, verification_status, listing_status, listed_by)
         VALUES ($1, $2, '', 'pending', 'draft', $3) RETURNING *`,
        [ownerId, fallbackName, staffId],
      );
    case 'clinic':
      return queryOne(
        `INSERT INTO health_clinics (owner_id, name, address, city, slot_timings, consultation_fee_paise, phone, listing_status, listed_by)
         VALUES ($1, $2, '', '', '', 0, $3, 'draft', $4) RETURNING *`,
        [ownerId, fallbackName, phone, staffId],
      );
    case 'chemist':
      return queryOne(
        `INSERT INTO health_chemists (owner_id, name, address, city, operational_hours, phone, delivery_available, listing_status, listed_by)
         VALUES ($1, $2, '', '', '', $3, false, 'draft', $4) RETURNING *`,
        [ownerId, fallbackName, phone, staffId],
      );
    case 'store':
      return queryOne(
        `INSERT INTO marketplace_vendors (partner_id, business_name, brand_name, verification_status, listing_status, listed_by)
         VALUES ($1, $2, $3, 'pending', 'draft', $4)
         ON CONFLICT (partner_id) DO UPDATE SET partner_id = EXCLUDED.partner_id RETURNING *`,
        [ownerId, data.businessName ?? fallbackName, data.brandName ?? null, staffId],
      );
    default:
      throw badRequest('Unknown listing type');
  }
}

/** UPDATE … SET only the fields that were sent (+ derived columns). */
async function updateListing(type, id, data) {
  const cfg = TYPES[type];
  const m = LISTING_ENTITIES[type];
  const sets = [];
  const params = [id];
  const add = (column, value, json) => {
    params.push(json ? JSON.stringify(value) : value);
    sets.push(`${column} = $${params.length}${json ? '::jsonb' : ''}`);
  };
  for (const [key, spec] of Object.entries(cfg.fields)) {
    if (!(key in data) || data[key] === undefined) continue;
    const [column, kind] = Array.isArray(spec) ? spec : [spec];
    add(column, data[key], kind === 'json');
  }
  for (const [column, v] of Object.entries(cfg.derive(data))) {
    if (Array.isArray(v) && v[0] === 'json') add(column, v[1], true);
    else add(column, v, false);
  }
  if (!sets.length) return queryOne(`SELECT * FROM ${m.table} WHERE id = $1`, [id]);
  return queryOne(`UPDATE ${m.table} SET ${sets.join(', ')} WHERE id = $1 RETURNING *`, params);
}

/** Staff acting for a partner (act-as token, req.staffId) may not see money. */
function denyStaff(req) {
  if (req.staffId) throw forbidden('FitKey staff cannot view partner earnings');
}

const rangeSchema = z.object({ from: dateSchema.optional(), to: dateSchema.optional() });

/** Default range: last 30 days up to today (IST). */
function range(q) {
  const f = validate(rangeSchema, q);
  const to = f.to ?? todayIst();
  const from = f.from ?? new Date(Date.parse(`${to}T00:00:00Z`) - 29 * 86_400_000).toISOString().slice(0, 10);
  return { from, to };
}

const goLiveOf = async (ownerId) =>
  (await queryOne(`SELECT partner_go_live_at FROM users WHERE id = $1`, [ownerId]))?.partnerGoLiveAt ?? null;

// ================================================================================================ listing router

export const partnerListingRouter = Router();
partnerListingRouter.use(requireAuth('partner'));

/** GET /partner/listing/:type → { listing, checklist, timeline, documents, goLiveBlockers } */
partnerListingRouter.get('/:type', async (req, res) => {
  const type = validate(typeParam, req.params.type);
  const listing = await ownerListing(type, req.user.id);
  res.json(await listingPayload(type, listing, req.user.id));
});

/** PUT /partner/listing/:type — partial save of any step; creates the listing on the first save. */
partnerListingRouter.put('/:type', async (req, res) => {
  const type = validate(typeParam, req.params.type);
  const data = validate(TYPES[type].schema, req.body ?? {});
  let listing = await ownerListing(type, req.user.id);
  if (!listing) listing = await createListing(type, req.user.id, data, req.staffId ?? null);
  listing = await updateListing(type, listing.id, data);
  res.json(await listingPayload(type, listing, req.user.id));
});

/** POST /partner/listing/:type/submit — 400 { error, missing } when incomplete; else status submitted. */
partnerListingRouter.post('/:type/submit', async (req, res) => {
  const type = validate(typeParam, req.params.type);
  const listing = await ownerListing(type, req.user.id);
  if (!listing) throw notFound('Fill in your listing first');
  if (!SUBMITTABLE_STATUSES.includes(listing.listingStatus)) {
    throw conflict(`Your listing is already ${String(listing.listingStatus).replace('_', ' ')}`);
  }
  const ctx = await listingContext(type, listing, req.user.id);
  const missing = submitMissing(type, listing, ctx);
  if (missing.length) {
    return res.status(400).json({ error: 'Please complete these before submitting', missing });
  }
  const updated = await setListingStatus(type, listing.id, 'submitted', { actorId: req.staffId ?? req.user.id });
  res.json(await listingPayload(type, updated ?? listing, req.user.id));
});

/** GET /partner/listing/meta/options — pick-lists for the app (subtypes, store / product categories). */
partnerListingRouter.get('/meta/options', (_req, res) => {
  res.json({ trainerSubtypes: TRAINER_SUBTYPES, storeCategories: STORE_CATEGORIES, productCategories: PRODUCT_CATEGORIES, weekdays: WEEKDAYS });
});

// ================================================================================================ clinic (run / earn)

export const partnerClinicRouter = Router();
partnerClinicRouter.use(requireAuth('partner'));
partnerClinicRouter.use(async (req, _res, next) => {
  req.clinic = await ownerListing('clinic', req.user.id);
  if (!req.clinic) return next(notFound('Set up your clinic listing first'));
  next();
});

const APPT_COLS = `a.id, a.clinic_id, a.user_id, a.patient_name, a.patient_phone, a.doctor_name, a.appt_date, a.slot_time,
  a.token_no, a.fee_paise, a.source, a.status, a.reason, a.note, a.completed_at, a.created_at`;

const apptListSchema = z.object({
  date: dateSchema.optional(),
  from: dateSchema.optional(),
  to: dateSchema.optional(),
  status: z.enum(['booked', 'checked_in', 'in_consultation', 'completed', 'cancelled', 'no_show']).optional(),
});

/** GET /partner/clinic/appointments?date=|from=&to=&status= → { appointments } */
partnerClinicRouter.get('/appointments', async (req, res) => {
  const f = validate(apptListSchema, req.query);
  const params = [req.clinic.id];
  const cond = ['a.clinic_id = $1'];
  if (f.date) {
    params.push(f.date);
    cond.push(`a.appt_date = $${params.length}`);
  } else {
    params.push(f.from ?? todayIst());
    cond.push(`a.appt_date >= $${params.length}`);
    if (f.to) {
      params.push(f.to);
      cond.push(`a.appt_date <= $${params.length}`);
    }
  }
  if (f.status) {
    params.push(f.status);
    cond.push(`a.status = $${params.length}`);
  }
  const appointments = await query(
    `SELECT ${APPT_COLS} FROM clinic_appointments a WHERE ${cond.join(' AND ')} ORDER BY a.appt_date, a.token_no LIMIT 500`,
    params,
  );
  res.json({ appointments });
});

/** GET /partner/clinic/queue?date= — the day's patient queue by token, with counts and who is being seen now. */
partnerClinicRouter.get('/queue', async (req, res) => {
  const date = validate(z.object({ date: dateSchema.optional() }), req.query).date ?? todayIst();
  const rows = await query(
    `SELECT ${APPT_COLS} FROM clinic_appointments a WHERE a.clinic_id = $1 AND a.appt_date = $2 ORDER BY a.token_no`,
    [req.clinic.id, date],
  );
  const counts = { booked: 0, checkedIn: 0, inConsultation: 0, completed: 0, cancelled: 0, noShow: 0 };
  const key = { booked: 'booked', checked_in: 'checkedIn', in_consultation: 'inConsultation', completed: 'completed', cancelled: 'cancelled', no_show: 'noShow' };
  for (const r of rows) counts[key[r.status]] += 1;
  const queue = rows.filter((r) => ['booked', 'checked_in', 'in_consultation'].includes(r.status));
  res.json({
    date,
    nowServing: rows.find((r) => r.status === 'in_consultation') ?? null,
    queue,
    done: rows.filter((r) => !queue.includes(r)),
    counts,
  });
});

const walkInSchema = z.object({
  patientName: str(120).min(2),
  patientPhone: str(16).optional(),
  doctorName: str(120).optional(),
  date: dateSchema.optional(),
  slotTime: hhmm.optional(),
  feePaise: z.number().int().min(0).optional(),
  reason: str(300).optional(),
});

/** POST /partner/clinic/appointments — add a walk-in patient to the queue. */
partnerClinicRouter.post('/appointments', async (req, res) => {
  const d = validate(walkInSchema, req.body);
  const date = d.date ?? todayIst();
  const nowIst = new Date(Date.now() + 5.5 * 3_600_000).toISOString().slice(11, 16);
  const appointment = await queryOne(
    `INSERT INTO clinic_appointments (clinic_id, patient_name, patient_phone, doctor_name, appt_date, slot_time, token_no, fee_paise, source, reason)
     VALUES ($1, $2, $3, $4, $5, $6,
             (SELECT COALESCE(MAX(token_no), 0) + 1 FROM clinic_appointments WHERE clinic_id = $1 AND appt_date = $5),
             $7, 'walk_in', $8)
     RETURNING *`,
    [req.clinic.id, d.patientName, d.patientPhone ?? null, d.doctorName ?? null, date, d.slotTime ?? nowIst,
      d.feePaise ?? req.clinic.consultationFeePaise ?? 0, d.reason ?? null],
  );
  res.status(201).json({ appointment });
});

/** POST /partner/clinic/appointments/:id/status { status, note? } — move a patient through the queue. */
partnerClinicRouter.post('/appointments/:id/status', async (req, res) => {
  const d = validate(
    z.object({ status: z.enum(['checked_in', 'in_consultation', 'completed', 'cancelled', 'no_show', 'booked']), note: str(500).optional() }),
    req.body,
  );
  const appt = await queryOne(`SELECT * FROM clinic_appointments WHERE id = $1 AND clinic_id = $2`, [req.params.id, req.clinic.id]);
  if (!appt) throw notFound('Appointment not found');
  if (!(CLINIC_TRANSITIONS[appt.status] ?? []).includes(d.status)) {
    throw conflict(`Cannot change a ${appt.status.replace('_', ' ')} appointment to ${d.status.replace('_', ' ')}`);
  }
  const pct = d.status === 'completed' ? commissionPct(await goLiveOf(req.user.id)) : null;
  const appointment = await queryOne(
    `UPDATE clinic_appointments SET status = $2::text, note = COALESCE($3::text, note),
       completed_at = CASE WHEN $2::text = 'completed' THEN now() ELSE completed_at END,
       commission_pct = COALESCE($4::numeric, commission_pct)
     WHERE id = $1 RETURNING *`,
    [appt.id, d.status, d.note ?? null, pct],
  );
  if (appt.userId && ['checked_in', 'in_consultation', 'cancelled'].includes(d.status)) {
    const msg = {
      checked_in: `You're checked in at ${req.clinic.name}. Token #${appt.tokenNo}.`,
      in_consultation: `It's your turn at ${req.clinic.name} — please go in.`,
      cancelled: `${req.clinic.name} cancelled your appointment on ${appt.apptDate}.`,
    }[d.status];
    await notify(appt.userId, { type: 'clinic_appointment', title: msg, body: d.note ?? null, data: { appointmentId: appt.id, clinicId: req.clinic.id } });
  }
  res.json({ appointment });
});

/** GET /partner/clinic/patients?q= — patients seen / booked (FitKey members and walk-ins). */
partnerClinicRouter.get('/patients', async (req, res) => {
  const q = validate(z.object({ q: str(80).optional() }), req.query).q;
  const params = [req.clinic.id];
  let filter = '';
  if (q) {
    params.push(`%${q}%`);
    filter = `AND (a.patient_name ILIKE $2 OR a.patient_phone ILIKE $2)`;
  }
  const patients = await query(
    `SELECT COALESCE(a.user_id::text, a.patient_phone, a.patient_name) AS key,
            MAX(a.user_id::text) AS user_id, MAX(a.patient_name) AS name, MAX(a.patient_phone) AS phone,
            COUNT(*) FILTER (WHERE a.status = 'completed')::int AS visits,
            MAX(a.appt_date) FILTER (WHERE a.status = 'completed') AS last_visit_on,
            MIN(a.appt_date) FILTER (WHERE a.status IN ('booked', 'checked_in') AND a.appt_date >= current_date) AS next_appointment_on
       FROM clinic_appointments a
      WHERE a.clinic_id = $1 ${filter}
      GROUP BY 1 ORDER BY MAX(a.appt_date) DESC LIMIT 300`,
    params,
  );
  res.json({ patients });
});

/** GET /partner/clinic/earnings?from=&to= — FitKey-booked consultations completed, commission by plan year. */
partnerClinicRouter.get('/earnings', async (req, res) => {
  denyStaff(req);
  const { from, to } = range(req.query);
  const rows = await query(
    `SELECT to_char(appt_date, 'YYYY-MM-DD') AS date, fee_paise AS gross_paise, source
       FROM clinic_appointments WHERE clinic_id = $1 AND status = 'completed' AND appt_date BETWEEN $2 AND $3`,
    [req.clinic.id, from, to],
  );
  const fitkey = rows.filter((r) => r.source === 'fitkey');
  const walkIns = rows.filter((r) => r.source === 'walk_in');
  res.json({
    from,
    to,
    ...earningsSummary(fitkey, await goLiveOf(req.user.id)),
    walkIns: { count: walkIns.length, feesPaise: walkIns.reduce((s, r) => s + r.grossPaise, 0), note: 'Collected at the clinic — no FitKey commission.' },
  });
});

// ================================================================================================ chemist (run / earn)

export const partnerChemistRouter = Router();
partnerChemistRouter.use(requireAuth('partner'));
partnerChemistRouter.use(async (req, _res, next) => {
  req.chemist = await ownerListing('chemist', req.user.id);
  if (!req.chemist) return next(notFound('Set up your chemist listing first'));
  next();
});

const ORDER_COLS = `o.id, o.chemist_id, o.user_id, o.items, o.prescription_url, o.fulfilment, o.address, o.phone, o.status,
  o.mrp_paise, o.discount_paise, o.amount_paise, o.note, o.reject_reason, o.accepted_at, o.delivered_at, o.created_at, o.updated_at,
  u.name AS member_name`;

/** GET /partner/chemist/orders?status=&open=true → { orders } (open = not yet delivered / closed). */
partnerChemistRouter.get('/orders', async (req, res) => {
  const f = validate(z.object({ status: z.string().max(20).optional(), open: z.enum(['true', 'false']).optional() }), req.query);
  const params = [req.chemist.id];
  const cond = ['o.chemist_id = $1'];
  if (f.status) {
    params.push(f.status);
    cond.push(`o.status = $${params.length}`);
  }
  if (f.open === 'true') cond.push(`o.status IN ('requested', 'accepted', 'packed', 'out_for_delivery')`);
  const orders = await query(
    `SELECT ${ORDER_COLS} FROM chemist_orders o JOIN users u ON u.id = o.user_id
      WHERE ${cond.join(' AND ')} ORDER BY o.created_at DESC LIMIT 300`,
    params,
  );
  res.json({ orders });
});

const chemistUpdateSchema = z.object({
  status: z.enum(['accepted', 'packed', 'out_for_delivery', 'delivered', 'picked_up', 'rejected', 'cancelled']),
  mrpPaise: z.number().int().min(0).optional(), // required on accept: the bill at MRP; the store discount is applied
  note: str(500).optional(),
  rejectReason: str(200).optional(),
});

/** POST /partner/chemist/orders/:id { status, mrpPaise?, note?, rejectReason? } — accept / pack / deliver. */
partnerChemistRouter.post('/orders/:id', async (req, res) => {
  const d = validate(chemistUpdateSchema, req.body);
  const order = await queryOne(`SELECT * FROM chemist_orders WHERE id = $1 AND chemist_id = $2`, [req.params.id, req.chemist.id]);
  if (!order) throw notFound('Order not found');
  if (!(CHEMIST_TRANSITIONS[order.status] ?? []).includes(d.status)) {
    throw conflict(`Cannot change a ${order.status.replace(/_/g, ' ')} order to ${d.status.replace(/_/g, ' ')}`);
  }
  if (d.status === 'out_for_delivery' && order.fulfilment !== 'delivery') throw badRequest('This order is for store pickup');
  if (d.status === 'picked_up' && order.fulfilment !== 'pickup') throw badRequest('This order is for home delivery');
  let bill = null;
  if (d.status === 'accepted') {
    if (d.mrpPaise == null) throw badRequest('mrpPaise: enter the bill amount at MRP');
    bill = chemistBill(d.mrpPaise, req.chemist.discountPct ?? 0);
  }
  const closing = d.status === 'delivered' || d.status === 'picked_up';
  const updated = await queryOne(
    `UPDATE chemist_orders SET status = $2::text, note = COALESCE($3::text, note), reject_reason = COALESCE($4::text, reject_reason),
       mrp_paise = COALESCE($5::int, mrp_paise), discount_paise = COALESCE($6::int, discount_paise), amount_paise = COALESCE($7::int, amount_paise),
       accepted_at = CASE WHEN $2::text = 'accepted' THEN now() ELSE accepted_at END,
       delivered_at = CASE WHEN $8::boolean THEN now() ELSE delivered_at END,
       commission_pct = CASE WHEN $8::boolean THEN $9::numeric ELSE commission_pct END,
       updated_at = now()
     WHERE id = $1 RETURNING *`,
    [order.id, d.status, d.note ?? null, d.rejectReason ?? null, bill?.mrpPaise ?? null, bill?.discountPaise ?? null,
      bill?.amountPaise ?? null, closing, closing ? commissionPct(await goLiveOf(req.user.id)) : null],
  );
  const title = {
    accepted: `${req.chemist.name} accepted your order${bill ? ` · ₹${(bill.amountPaise / 100).toLocaleString('en-IN')}` : ''}`,
    packed: `Your order from ${req.chemist.name} is packed`,
    out_for_delivery: `Your medicines are out for delivery`,
    delivered: `Your order from ${req.chemist.name} was delivered`,
    picked_up: `Order picked up from ${req.chemist.name}`,
    rejected: `${req.chemist.name} couldn't take your order`,
    cancelled: `${req.chemist.name} cancelled your order`,
  }[d.status];
  await notify(order.userId, { type: 'chemist_order', title, body: d.rejectReason ?? d.note ?? null, data: { chemistOrderId: order.id } });
  res.json({ order: updated });
});

/** GET /partner/chemist/earnings?from=&to= — delivered / picked-up orders, commission by plan year. */
partnerChemistRouter.get('/earnings', async (req, res) => {
  denyStaff(req);
  const { from, to } = range(req.query);
  const rows = await query(
    `SELECT to_char((delivered_at AT TIME ZONE 'Asia/Kolkata')::date, 'YYYY-MM-DD') AS date, COALESCE(amount_paise, 0) AS gross_paise, fulfilment AS source
       FROM chemist_orders
      WHERE chemist_id = $1 AND status IN ('delivered', 'picked_up')
        AND (delivered_at AT TIME ZONE 'Asia/Kolkata')::date BETWEEN $2 AND $3`,
    [req.chemist.id, from, to],
  );
  res.json({ from, to, ...earningsSummary(rows, await goLiveOf(req.user.id)) });
});

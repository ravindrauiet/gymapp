import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, conflict, notFound, validate } from '../utils/http.js';
import { notify } from '../utils/notify.js';
import { slotsForDay, todayIst, weekdayOf } from '../utils/partner_types.js';
import { dateSchema, timeSchema } from '../utils/schemas.js';

const router = Router();

const listQuery = z.object({
  city: z.string().trim().max(80).optional(),
  q: z.string().trim().max(80).optional(),
});

/** Escapes LIKE wildcards in user input. */
const likeEscape = (s) => s.replace(/[\\%_]/g, (c) => `\\${c}`);

/**
 * Partner-owned clinics / chemists are shown only once live (Partner BRD §7). NULL listing_status = legacy row
 * (seeded or created before the BRD), always shown.
 */
const VISIBLE = `(listing_status IS NULL OR listing_status = 'live')`;

/**
 * Builds WHERE + ORDER BY for a directory search: every word of `q` must appear somewhere in `haystack`
 * (name, address/area, city, specialities…), with a typo-tolerant fallback on the name.
 */
function directoryFilter({ city, q }, haystack) {
  const conditions = [VISIBLE];
  const params = [];
  const p = (v) => {
    params.push(v);
    return `$${params.length}`;
  };
  if (city) conditions.push(`lower(city) = lower(${p(city)})`);
  let order = 'distance_km ASC';
  const term = q?.toLowerCase();
  if (term) {
    const words = term.split(/\s+/).filter(Boolean).slice(0, 6);
    const all = words.map((w) => `${haystack} LIKE ${p(`%${likeEscape(w)}%`)}`).join(' AND ');
    const qp = p(term);
    conditions.push(`((${all}) OR word_similarity(${qp}, lower(name)) >= 0.5)`);
    order = `(lower(name) LIKE ${p(`%${likeEscape(term)}%`)}) DESC, distance_km ASC`;
  }
  return { where: `WHERE ${conditions.join(' AND ')}`, order, params };
}

/** `bookable` / `orderable`: a partner owns the listing, so FitKey appointments / orders reach someone. */
// Member-facing columns only: never owner_id or the internal listing lifecycle fields.
const CHEMIST_COLS = `id, name, address, area, city, distance_km, operational_hours, open_hours, delivery_available,
  home_delivery, delivery_time_est, delivery_radius_km, discount_pct, phone, latitude, longitude, photos, created_at,
  (owner_id IS NOT NULL) AS orderable`;
const CLINIC_COLS = `id, name, address, area, city, distance_km, doctors, facilities, slot_timings, speciality, opd_hours,
  slot_minutes, consultation_fee_paise, phone, latitude, longitude, photos, created_at,
  (owner_id IS NOT NULL) AS bookable`;

/** GET /healthstop/chemists?city=&q= — search by name, address / area or city. */
router.get('/chemists', async (req, res) => {
  const f = validate(listQuery, req.query);
  const { where, order, params } = directoryFilter(f, `lower(concat_ws(' ', name, address, area, city))`);
  const chemists = await query(`SELECT ${CHEMIST_COLS} FROM health_chemists ${where} ORDER BY ${order}`, params);
  res.json({ chemists });
});

/** GET /healthstop/clinics?city=&q= — search by name, address / area, city, doctor names & specialities, facilities. */
router.get('/clinics', async (req, res) => {
  const f = validate(listQuery, req.query);
  const haystack = `lower(concat_ws(' ', name, address, area, city, speciality, array_to_string(facilities, ' '),
    (SELECT string_agg(concat_ws(' ', d->>'name', d->>'specialty', d->>'degree'), ' ')
       FROM jsonb_array_elements(doctors) d)))`;
  const { where, order, params } = directoryFilter(f, haystack);
  const clinics = await query(`SELECT ${CLINIC_COLS} FROM health_clinics ${where} ORDER BY ${order}`, params);
  res.json({ clinics });
});

const visibleClinic = (id) => queryOne(`SELECT ${CLINIC_COLS} FROM health_clinics WHERE id = $1 AND ${VISIBLE}`, [id]);
const visibleChemist = (id) => queryOne(`SELECT ${CHEMIST_COLS} FROM health_chemists WHERE id = $1 AND ${VISIBLE}`, [id]);

/** GET /healthstop/clinics/:id */
router.get('/clinics/:id', async (req, res) => {
  const clinic = await visibleClinic(req.params.id);
  if (!clinic) throw notFound('Clinic not found');
  res.json({ clinic });
});

/** GET /healthstop/chemists/:id */
router.get('/chemists/:id', async (req, res) => {
  const chemist = await visibleChemist(req.params.id);
  if (!chemist) throw notFound('Chemist not found');
  res.json({ chemist });
});

// ------------------------------------------------------------------------------------------------ clinic appointments

/** Free appointment slots on a date, from the clinic's OPD hours (one patient per slot). */
async function clinicSlots(clinic, date) {
  const all = slotsForDay(clinic.opdHours ?? [], weekdayOf(date), clinic.slotMinutes ?? 15);
  const taken = await query(
    `SELECT slot_time FROM clinic_appointments WHERE clinic_id = $1 AND appt_date = $2 AND status <> 'cancelled'`,
    [clinic.id, date],
  );
  const busy = new Set(taken.map((t) => t.slotTime));
  const today = todayIst();
  const nowIst = new Date(Date.now() + 5.5 * 3_600_000).toISOString().slice(11, 16);
  return all.map((time) => ({ time, available: !busy.has(time) && (date > today || (date === today && time > nowIst)) }));
}

/** GET /healthstop/clinics/:id/slots?date= → { date, slotMinutes, slots:[{ time, available }] } */
router.get('/clinics/:id/slots', async (req, res) => {
  const date = validate(z.object({ date: dateSchema.optional() }), req.query).date ?? todayIst();
  const clinic = await visibleClinic(req.params.id);
  if (!clinic) throw notFound('Clinic not found');
  res.json({ date, slotMinutes: clinic.slotMinutes ?? 15, slots: clinic.bookable ? await clinicSlots(clinic, date) : [] });
});

const appointmentSchema = z.object({
  date: dateSchema,
  slotTime: timeSchema.transform((s) => s.slice(0, 5)),
  doctorName: z.string().trim().max(120).optional(),
  patientName: z.string().trim().min(2).max(120).optional(),
  reason: z.string().trim().max(300).optional(),
});

/** POST /healthstop/clinics/:id/appointments — member books a consultation slot. */
router.post('/clinics/:id/appointments', requireAuth('user'), async (req, res) => {
  const d = validate(appointmentSchema, req.body);
  const clinic = await visibleClinic(req.params.id);
  if (!clinic) throw notFound('Clinic not found');
  if (!clinic.bookable) throw conflict('This clinic does not take FitKey appointments yet. Please call them.');
  const slot = (await clinicSlots(clinic, d.date)).find((s) => s.time === d.slotTime);
  if (!slot) throw badRequest('The clinic is not open at that time');
  if (!slot.available) throw conflict('That slot is taken. Please pick another time.');
  const me = await queryOne(`SELECT name, phone FROM users WHERE id = $1`, [req.user.id]);
  const appointment = await queryOne(
    `INSERT INTO clinic_appointments (clinic_id, user_id, patient_name, patient_phone, doctor_name, appt_date, slot_time, token_no, fee_paise, source, reason)
     VALUES ($1, $2, $3, $4, $5, $6, $7,
             (SELECT COALESCE(MAX(token_no), 0) + 1 FROM clinic_appointments WHERE clinic_id = $1 AND appt_date = $6),
             $8, 'fitkey', $9)
     RETURNING *`,
    [clinic.id, req.user.id, d.patientName ?? me?.name ?? 'Member', me?.phone ?? null, d.doctorName ?? null, d.date, d.slotTime,
      clinic.consultationFeePaise ?? 0, d.reason ?? null],
  );
  await notify(clinic.ownerId, {
    type: 'clinic_appointment_new',
    title: `New appointment · ${d.date} ${d.slotTime}`,
    body: `${appointment.patientName}${d.doctorName ? ` with ${d.doctorName}` : ''} · token #${appointment.tokenNo}`,
    data: { appointmentId: appointment.id },
  });
  res.status(201).json({ appointment, clinicName: clinic.name });
});

/** GET /healthstop/appointments/me */
router.get('/appointments/me', requireAuth('user'), async (req, res) => {
  const appointments = await query(
    `SELECT a.*, c.name AS clinic_name, c.address AS clinic_address, c.phone AS clinic_phone
       FROM clinic_appointments a JOIN health_clinics c ON c.id = a.clinic_id
      WHERE a.user_id = $1 ORDER BY a.appt_date DESC, a.slot_time DESC LIMIT 100`,
    [req.user.id],
  );
  res.json({ appointments });
});

/** POST /healthstop/appointments/:id/cancel */
router.post('/appointments/:id/cancel', requireAuth('user'), async (req, res) => {
  const appointment = await queryOne(
    `UPDATE clinic_appointments SET status = 'cancelled' WHERE id = $1 AND user_id = $2 AND status = 'booked' RETURNING *`,
    [req.params.id, req.user.id],
  );
  if (!appointment) throw notFound('No upcoming appointment to cancel');
  const clinic = await queryOne(`SELECT owner_id FROM health_clinics WHERE id = $1`, [appointment.clinicId]);
  if (clinic?.ownerId) {
    await notify(clinic.ownerId, {
      type: 'clinic_appointment_cancelled',
      title: `Appointment cancelled · ${appointment.apptDate} ${appointment.slotTime}`,
      body: appointment.patientName,
      data: { appointmentId: appointment.id },
    });
  }
  res.json({ appointment });
});

// ------------------------------------------------------------------------------------------------ chemist orders

const chemistOrderSchema = z
  .object({
    items: z
      .array(z.object({ name: z.string().trim().min(1).max(120), qty: z.number().int().min(1).max(100), note: z.string().trim().max(200).optional() }))
      .max(40)
      .default([]),
    prescriptionUrl: z.string().trim().max(2000).optional(),
    fulfilment: z.enum(['delivery', 'pickup']).default('delivery'),
    address: z
      .object({ addressLine: z.string().trim().min(5).max(300), city: z.string().trim().max(80).optional(), pincode: z.string().trim().max(10).optional() })
      .optional(),
    phone: z.string().trim().max(16).optional(),
    note: z.string().trim().max(500).optional(),
  })
  .refine((o) => o.items.length > 0 || o.prescriptionUrl, 'Add medicines or a prescription photo')
  .refine((o) => o.fulfilment === 'pickup' || o.address, 'Add a delivery address');

/** POST /healthstop/chemists/:id/orders — member requests an order; the chemist quotes and accepts in the partner app. */
router.post('/chemists/:id/orders', requireAuth('user'), async (req, res) => {
  const d = validate(chemistOrderSchema, req.body);
  const chemist = await visibleChemist(req.params.id);
  if (!chemist) throw notFound('Chemist not found');
  if (!chemist.orderable) throw conflict('This chemist does not take FitKey orders yet. Please call them.');
  if (d.fulfilment === 'delivery' && !(chemist.homeDelivery ?? chemist.deliveryAvailable)) {
    throw conflict('This chemist does not deliver. Choose store pickup.');
  }
  const me = await queryOne(`SELECT name, phone FROM users WHERE id = $1`, [req.user.id]);
  const order = await queryOne(
    `INSERT INTO chemist_orders (chemist_id, user_id, items, prescription_url, fulfilment, address, phone, note)
     VALUES ($1, $2, $3::jsonb, $4, $5, $6::jsonb, $7, $8) RETURNING *`,
    [chemist.id, req.user.id, JSON.stringify(d.items), d.prescriptionUrl ?? null, d.fulfilment,
      d.address ? JSON.stringify(d.address) : null, d.phone ?? me?.phone ?? null, d.note ?? null],
  );
  await notify(chemist.ownerId, {
    type: 'chemist_order_new',
    title: `New ${d.fulfilment === 'pickup' ? 'pickup' : 'delivery'} order`,
    body: `${me?.name ?? 'A member'} · ${d.items.length ? `${d.items.length} item${d.items.length === 1 ? '' : 's'}` : 'prescription attached'}`,
    data: { chemistOrderId: order.id },
  });
  res.status(201).json({ order, chemistName: chemist.name });
});

/** GET /healthstop/chemist-orders/me */
router.get('/chemist-orders/me', requireAuth('user'), async (req, res) => {
  const orders = await query(
    `SELECT o.*, c.name AS chemist_name, c.phone AS chemist_phone
       FROM chemist_orders o JOIN health_chemists c ON c.id = o.chemist_id
      WHERE o.user_id = $1 ORDER BY o.created_at DESC LIMIT 100`,
    [req.user.id],
  );
  res.json({ orders });
});

/** POST /healthstop/chemist-orders/:id/cancel — before it is packed. */
router.post('/chemist-orders/:id/cancel', requireAuth('user'), async (req, res) => {
  const order = await queryOne(
    `UPDATE chemist_orders SET status = 'cancelled', updated_at = now()
      WHERE id = $1 AND user_id = $2 AND status IN ('requested', 'accepted') RETURNING *`,
    [req.params.id, req.user.id],
  );
  if (!order) throw notFound('No open order to cancel');
  const chemist = await queryOne(`SELECT owner_id FROM health_chemists WHERE id = $1`, [order.chemistId]);
  if (chemist?.ownerId) {
    await notify(chemist.ownerId, { type: 'chemist_order_cancelled', title: 'A member cancelled their order', data: { chemistOrderId: order.id } });
  }
  res.json({ order });
});

export default router;

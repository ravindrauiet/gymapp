import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  CHEMIST_TRANSITIONS,
  chemistBill,
  earningsSummary,
  goLiveBlockers,
  hoursLabel,
  listingChecklist,
  requiredDocs,
  slotsForDay,
  submitMissing,
  subtypesToTrainerTypes,
  todayIst,
  trainerVerifiedBadge,
  weekdayOf,
} from './partner_types.js';

const kyc = { status: 'verified' };
const bank = { status: 'pending' };
const docs = (...types) => types.map((docType) => ({ docType, status: 'pending' }));

const trainer = {
  name: 'Asha Rao',
  photoUrl: 'https://x/p.jpg',
  subtypes: ['yoga_master'],
  experienceYears: 6,
  languages: ['English', 'Hindi'],
  trainingModes: ['online', 'home'],
  serviceArea: 'Indiranagar, Bengaluru',
  hourlyRatePaise: 80000,
  weeklySlots: [{ weekday: 'mon', start: '06:00', end: '09:00' }],
  maxSessionsPerDay: 4,
  listingStatus: 'draft',
};

test('empty listing: 0% and every step missing', () => {
  const c = listingChecklist('clinic', null);
  assert.equal(c.percent, 0);
  assert.deepEqual([...new Set(c.missing.map((m) => m.step))], [1, 2, 3, 4, 5]);
});

test('complete trainer draft: steps 1–4 done, only review left; submit has nothing missing', () => {
  const ctx = { docs: docs('certificate'), kyc, bank };
  const c = listingChecklist('trainer', trainer, ctx);
  assert.deepEqual(c.done, [1, 2, 3, 4]);
  assert.equal(c.percent, 80);
  assert.deepEqual(submitMissing('trainer', trainer, ctx), []);
});

test('submitted listing counts step 5 done', () => {
  const c = listingChecklist('trainer', { ...trainer, listingStatus: 'submitted' }, { docs: docs('certificate'), kyc, bank });
  assert.equal(c.percent, 100);
});

test('trainer: service area needed only for home / gym; rejected docs do not count', () => {
  const online = { ...trainer, trainingModes: ['online'], serviceArea: null };
  assert.deepEqual(submitMissing('trainer', online, { docs: docs('certificate'), kyc, bank }), []);
  const home = { ...trainer, serviceArea: '' };
  const miss = submitMissing('trainer', home, { docs: [{ docType: 'certificate', status: 'rejected' }], kyc, bank });
  assert.ok(miss.some((m) => m.step === 1 && /service area/.test(m.label)));
  assert.ok(miss.some((m) => m.step === 4 && /certificates/.test(m.label)));
});

test('KYC and bank are required for every type', () => {
  const miss = submitMissing('trainer', trainer, { docs: docs('certificate'), kyc: null, bank: { status: 'failed' } });
  assert.deepEqual(miss.map((m) => m.label), ['Complete KYC (Aadhaar)', 'Add your bank account']);
});

test('required docs per type; FSSAI only for supplements / healthy food sellers', () => {
  assert.deepEqual(requiredDocs('clinic'), ['clinic_registration', 'doctor_registration']);
  assert.deepEqual(requiredDocs('chemist'), ['drug_licence', 'gst']);
  assert.deepEqual(requiredDocs('store', { categories: ['activewear'] }), ['gst', 'trademark']);
  assert.deepEqual(requiredDocs('store', { categories: ['activewear', 'healthy_food'] }), ['gst', 'trademark', 'fssai']);
});

test('store: pricing needs a product with price ≤ MRP; availability needs stock + dispatch time', () => {
  const store = { brandName: 'FitFuel', logoUrl: 'l.png', about: 'Clean protein made in India.', categories: ['supplements'], listingStatus: 'draft' };
  const ctx = { docs: docs('gst', 'trademark'), kyc, bank, products: [{ pricePaise: 200000, originalPricePaise: 150000, stockQuantity: 0, isActive: true }] };
  const steps = submitMissing('store', store, ctx).map((m) => m.step);
  assert.deepEqual(steps, [2, 3, 3, 4]); // bad price, no stock, no dispatch days, no FSSAI
  const ok = { ...store, dispatchDays: 2 };
  const okCtx = { ...ctx, docs: docs('gst', 'trademark', 'fssai'), products: [{ pricePaise: 150000, originalPricePaise: 200000, stockQuantity: 5, isActive: true }] };
  assert.deepEqual(submitMissing('store', ok, okCtx), []);
  assert.equal(goLiveBlockers('store', ok).length, 1);
  assert.equal(goLiveBlockers('store', { ...ok, fssaiVerifiedAt: '2026-11-11T00:00:00Z' }).length, 0);
  assert.equal(goLiveBlockers('store', { ...ok, categories: ['activewear'] }).length, 0);
});

test('chemist: delivery radius only when delivering; 0% discount accepted once past step 2', () => {
  const chem = { name: 'Apollo', address: '12 MG Road', city: 'Pune', photos: ['a'], openHours: [{ weekday: 'mon', opensAt: '09:00', closesAt: '21:00' }], homeDelivery: false, discountPct: 0, listingStep: 3, listingStatus: 'draft' };
  assert.deepEqual(submitMissing('chemist', chem, { docs: docs('drug_licence', 'gst'), kyc, bank }), []);
  const delivering = { ...chem, homeDelivery: true, listingStep: 2 };
  const steps = submitMissing('chemist', delivering, { docs: docs('drug_licence', 'gst'), kyc, bank }).map((m) => m.step);
  assert.deepEqual(steps, [1, 2]);
});

test('trainer Verified badge: legacy uses verification_status, partner listings need certificates checked', () => {
  assert.equal(trainerVerifiedBadge({ listingStatus: null, verificationStatus: 'verified' }), true);
  assert.equal(trainerVerifiedBadge({ listingStatus: 'live', verificationStatus: 'verified' }), false);
  assert.equal(trainerVerifiedBadge({ listingStatus: 'live', certificatesVerifiedAt: '2026-11-01' }), true);
});

test('subtypes map to member-app trainer types', () => {
  assert.deepEqual(subtypesToTrainerTypes(['gym_trainer_gym', 'gym_trainer_home', 'karate']), ['personal_trainer', 'judo_karate']);
});

test('hours label merges consecutive identical days and split shifts', () => {
  const rows = ['mon', 'tue', 'wed', 'thu', 'fri'].flatMap((weekday) => [
    { weekday, opensAt: '17:00', closesAt: '20:00' },
    { weekday, opensAt: '10:00', closesAt: '14:00' },
  ]);
  rows.push({ weekday: 'sat', opensAt: '10:00', closesAt: '13:00' });
  assert.equal(hoursLabel(rows), 'Mon–Fri 10:00–14:00, 17:00–20:00 · Sat 10:00–13:00');
  assert.equal(hoursLabel([]), '');
});

test('slots for a weekday fit fully inside each range', () => {
  const rows = [{ weekday: 'mon', opensAt: '10:00', closesAt: '11:00' }, { weekday: 'tue', opensAt: '10:00', closesAt: '12:00' }];
  assert.deepEqual(slotsForDay(rows, 'mon', 20), ['10:00', '10:20', '10:40']);
  assert.deepEqual(slotsForDay([{ weekday: 'mon', start: '06:00', end: '08:30' }], 'mon', 60), ['06:00', '07:00']);
  assert.deepEqual(slotsForDay(rows, 'sun', 15), []);
});

test('weekdayOf / todayIst', () => {
  assert.equal(weekdayOf('2026-11-11'), 'wed');
  assert.equal(weekdayOf('2026-11-15'), 'sun');
  assert.equal(todayIst(Date.parse('2026-11-10T20:00:00Z')), '2026-11-11'); // 01:30 IST next day
});

test('earnings use the founding-partner commission by date (0% / 2.5% / 5%)', () => {
  const live = '2027-03-15T00:00:00Z';
  const s = earningsSummary(
    [
      { date: '2027-06-01', grossPaise: 100000, source: 'online' },
      { date: '2028-06-01', grossPaise: 100000, source: 'home' },
      { date: '2029-06-01', grossPaise: 100000, source: 'home' },
    ],
    live,
  );
  assert.deepEqual(s.totals, { count: 3, grossPaise: 300000, commissionPaise: 7500, netPaise: 292500 });
  assert.deepEqual(s.byDay.map((d) => d.netPaise), [100000, 97500, 95000]);
  assert.equal(s.bySource.find((b) => b.source === 'home').netPaise, 192500);
  assert.equal(earningsSummary([], null).commissionPct, 0);
});

test('chemist bill applies the store discount; transitions are one-way', () => {
  assert.deepEqual(chemistBill(50000, 10), { mrpPaise: 50000, discountPaise: 5000, amountPaise: 45000 });
  assert.ok(CHEMIST_TRANSITIONS.requested.includes('accepted'));
  assert.deepEqual(CHEMIST_TRANSITIONS.delivered, []);
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { z } from 'zod';
import {
  bankNameFromIfsc,
  cleanEmail,
  isValidAccountNumber,
  isValidIfsc,
  maskAadhaar,
  normalizeIfsc,
  staffBlockedPath,
  submitBlockers,
  venueChecklist,
} from './partner_rules.js';

const completeVenue = {
  status: 'draft',
  categories: ['gym'],
  sports: [],
  name: 'Iron Paradise',
  description: 'A well-equipped strength and conditioning gym with certified trainers.',
  address: '12 MG Road, Indiranagar',
  city: 'Bengaluru',
  latitude: 12.97,
  longitude: 77.64,
  opensAt: null,
  closesAt: null,
  fitkeyPassMode: 'all',
  photos: ['a', 'b', 'c', 'd'],
  amenities: ['locker'],
  equipment: [],
  monthlyFeePaise: 150000,
  passAccepted: true,
  slotMinutes: 60,
  slotCapacity: 20,
};
const completeCtx = { hoursCount: 7, passBlocksCount: 0, activePlans: 1, hasLicence: true, hasKyc: true, hasBank: true };

test('complete draft: only step 10 missing, nothing blocks submit', () => {
  const c = venueChecklist(completeVenue, completeCtx);
  assert.deepEqual(c.done, [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  assert.equal(c.percent, 90);
  assert.deepEqual(c.missing.map((m) => m.step), [10]);
  assert.equal(submitBlockers(c).length, 0);
});

test('submitted venue is 100%', () => {
  const c = venueChecklist({ ...completeVenue, status: 'submitted' }, completeCtx);
  assert.equal(c.percent, 100);
  assert.equal(c.missing.length, 0);
});

test('empty venue: every step missing with labels', () => {
  const c = venueChecklist({}, {});
  assert.equal(c.percent, 0);
  assert.equal(c.missing.length, 10);
  assert.deepEqual(c.missing[0], { step: 1, label: 'Category', hint: 'Pick a category', required: true });
});

test('sports category needs sports', () => {
  const v = { ...completeVenue, categories: ['sports_club'], sports: [] };
  assert.ok(venueChecklist(v, completeCtx).missing.some((m) => m.step === 1));
  assert.ok(!venueChecklist({ ...v, sports: ['badminton'] }, completeCtx).missing.some((m) => m.step === 1));
});

test('description under 40 chars fails step 2', () => {
  const c = venueChecklist({ ...completeVenue, description: 'Short text' }, completeCtx);
  assert.ok(c.missing.some((m) => m.step === 2));
});

test('step 4: legacy opens/closes count, blocked mode needs a pass block', () => {
  const noHours = { ...completeCtx, hoursCount: 0 };
  assert.ok(venueChecklist(completeVenue, noHours).missing.some((m) => m.step === 4));
  assert.ok(!venueChecklist({ ...completeVenue, opensAt: '06:00:00', closesAt: '22:00:00' }, noHours).missing.some((m) => m.step === 4));
  assert.ok(venueChecklist({ ...completeVenue, fitkeyPassMode: 'blocked' }, completeCtx).missing.some((m) => m.step === 4));
  assert.ok(!venueChecklist({ ...completeVenue, fitkeyPassMode: 'blocked' }, { ...completeCtx, passBlocksCount: 1 }).missing.some((m) => m.step === 4));
});

test('photos need at least 4', () => {
  assert.ok(venueChecklist({ ...completeVenue, photos: ['a', 'b', 'c'] }, completeCtx).missing.some((m) => m.step === 5));
});

test('step 7 needs plan, monthly fee and pass consent', () => {
  for (const [v, ctx] of [
    [completeVenue, { ...completeCtx, activePlans: 0 }],
    [{ ...completeVenue, monthlyFeePaise: null }, completeCtx],
    [{ ...completeVenue, passAccepted: false }, completeCtx],
  ]) {
    assert.ok(venueChecklist(v, ctx).missing.some((m) => m.step === 7));
  }
});

test('step 9 needs licence, KYC and bank', () => {
  for (const k of ['hasLicence', 'hasKyc', 'hasBank']) {
    assert.ok(venueChecklist(completeVenue, { ...completeCtx, [k]: false }).missing.some((m) => m.step === 9), k);
  }
});

test('maskAadhaar keeps only the last 4', () => {
  assert.equal(maskAadhaar('1234'), 'XXXX-XXXX-1234');
  assert.equal(maskAadhaar(' 0042 '), 'XXXX-XXXX-0042');
  assert.equal(maskAadhaar('XXXX-XXXX-9876'), 'XXXX-XXXX-9876');
  assert.equal(maskAadhaar('xxxx xxxx 9876'), 'XXXX-XXXX-9876');
});

test('maskAadhaar rejects full numbers and junk', () => {
  assert.throws(() => maskAadhaar('123456789012'), /last 4/);
  assert.throws(() => maskAadhaar('1234 5678 9012'), /last 4/);
  assert.throws(() => maskAadhaar('1234-5678-9012'), /last 4/);
  assert.throws(() => maskAadhaar('123'));
  assert.throws(() => maskAadhaar('abcd'));
  assert.throws(() => maskAadhaar(''));
});

test('IFSC validation', () => {
  assert.ok(isValidIfsc('HDFC0001234'));
  assert.ok(isValidIfsc(' sbin0005943 '));
  assert.equal(normalizeIfsc(' sbin 0005943'), 'SBIN0005943');
  assert.ok(!isValidIfsc('HDFC1001234')); // 5th char must be 0
  assert.ok(!isValidIfsc('HDF00001234'));
  assert.ok(!isValidIfsc('HDFC000123'));
  assert.equal(bankNameFromIfsc('icic0000001'), 'ICICI Bank');
  assert.equal(bankNameFromIfsc('ZZZZ0000001'), null);
});

test('account numbers: 9–18 digits', () => {
  assert.ok(isValidAccountNumber('123456789'));
  assert.ok(isValidAccountNumber('1234 5678 9012 3456'));
  assert.ok(!isValidAccountNumber('12345678'));
  assert.ok(!isValidAccountNumber('1234567890123456789'));
  assert.ok(!isValidAccountNumber('12345678A'));
});

test('e-mail cleaning accepts normal addresses', () => {
  const schema = z.preprocess(cleanEmail, z.string().email().optional());
  assert.equal(schema.parse('name@gmail.com'), 'name@gmail.com');
  assert.equal(schema.parse('  Name@Gmail.com '), 'name@gmail.com');
  assert.equal(schema.parse('name@gmail.com​'), 'name@gmail.com');
  assert.equal(schema.parse(''), undefined);
  assert.equal(schema.parse(undefined), undefined);
  assert.throws(() => schema.parse('not-an-email'));
});

test('act-as guard: money and member paths blocked', () => {
  for (const url of [
    '/api/v1/partner/earnings',
    '/api/v1/partner/earnings/visits?date=2026-11-11',
    '/api/v1/partner/payouts',
    '/api/v1/partner/payouts/abc/statement.csv',
    '/api/v1/partner/venues/0b7c/members',
    '/api/v1/partner/venues/0b7c/members/123',
    '/api/v1/memberships/partner/earnings',
    '/api/v1/memberships/partner/statement?month=2026-10',
    '/api/v1/memberships/partner/venues/x/members',
    '/api/v1/memberships/partner/venues/x/fitkey-visitors',
    '/api/v1/partner/vendor/commissions',
    '/api/v1/partner/staff/partners',
    '/api/v1/Partner/Earnings/',
  ]) {
    assert.ok(staffBlockedPath('GET', url), url);
  }
});

test('act-as guard: listing paths allowed', () => {
  for (const url of [
    '/api/v1/partner/venues',
    '/api/v1/partner/venues/0b7c',
    '/api/v1/partner/venues/0b7c/submit',
    '/api/v1/partner/documents?entityType=venue&entityId=1',
    '/api/v1/partner/kyc',
    '/api/v1/partner/bank',
    '/api/v1/partner/agreement/otp',
    '/api/v1/me',
    '/api/v1/partner/earningsx',
    '/api/v1/memberships/partner/venues/x/plans',
  ]) {
    assert.ok(!staffBlockedPath('GET', url), url);
  }
});

test('only the basics block submission; documents, pricing, description length are recommended', () => {
  const basic = { categories: ['gym'], name: 'Iron Gym', city: 'Delhi', address: 'Delhi', opensAt: '06:00', closesAt: '22:00', photos: ['/api/v1/files/x'] };
  const c = venueChecklist(basic, { hoursCount: 0 });
  assert.equal(submitBlockers(c).length, 0);
  // Still shown as tips.
  assert.ok(c.missing.some((m) => m.step === 9 && m.required === false));
  assert.ok(c.missing.some((m) => m.step === 7 && m.required === false));
});

test('location: a map pin can stand in for a short address', () => {
  const basic = { categories: ['gym'], name: 'Iron Gym', city: 'Delhi', address: '', latitude: 28.6, longitude: 77.2, opensAt: '06:00', closesAt: '22:00', photos: ['p'] };
  assert.equal(submitBlockers(venueChecklist(basic, {})).length, 0);
  assert.ok(submitBlockers(venueChecklist({ ...basic, latitude: null, longitude: null }, {})).some((m) => m.step === 3));
});

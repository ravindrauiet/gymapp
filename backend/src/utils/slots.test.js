import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  checkinOpen,
  closureAt,
  dayWindows,
  daysLabel,
  generateSlots,
  isOpenDay,
  ladiesOnlyLabels,
  mergeWindows,
  overlaps,
  passBlockAt,
  passBlockLabels,
  passBlockedMessage,
  passCapFor,
  rangeLabel,
  slotCapacity,
  toMin,
  weekdayOf,
} from './slots.js';

// 2026-11-16 is a Monday, 2026-11-21 a Saturday, 2026-11-22 a Sunday.
const MON = '2026-11-16';
const SAT = '2026-11-21';
const SUN = '2026-11-22';

const venue = (o = {}) => ({ name: 'Iron Gym', slotMinutes: 60, slotCapacity: 10, courts: 1, passSlotCap: null, fitkeyPassMode: 'blocked', ...o });
const split = [
  { weekday: 'mon', opensAt: '06:00', closesAt: '10:00', kind: 'open' },
  { weekday: 'mon', opensAt: '17:00', closesAt: '21:00', kind: 'open' },
  { weekday: 'mon', opensAt: '10:00', closesAt: '12:00', kind: 'ladies_only' },
];

test('weekday + time helpers', () => {
  assert.equal(weekdayOf(MON), 'mon');
  assert.equal(weekdayOf(SUN), 'sun');
  assert.equal(toMin('18:30:00'), 1110);
  assert.equal(overlaps(1020, 1080, 1080, 1200), false); // 17–18 vs 18–20 touch only
  assert.equal(overlaps(1079, 1080, 1080, 1200), false);
  assert.equal(overlaps(1080, 1081, 1080, 1200), true);
  assert.deepEqual(mergeWindows([{ start: 600, end: 720 }, { start: 360, end: 600 }, { start: 1020, end: 1260 }]), [
    { start: 360, end: 720 },
    { start: 1020, end: 1260 },
  ]);
});

test('split shifts: two grids, ladies-only rows count as open and flag their slots', () => {
  const slots = generateSlots(venue(), { hours: split }, MON);
  assert.deepEqual(slots.map((s) => s.start), ['06:00', '07:00', '08:00', '09:00', '10:00', '11:00', '17:00', '18:00', '19:00', '20:00']);
  assert.deepEqual(slots.filter((s) => s.ladiesOnly).map((s) => s.start), ['10:00', '11:00']);
  // A weekday without rows is closed once a venue has hours rows.
  assert.deepEqual(generateSlots(venue(), { hours: split }, SAT), []);
});

test('split shift with 90-minute slots only fits whole slots in each shift', () => {
  const slots = generateSlots(venue({ slotMinutes: 90 }), { hours: split.slice(0, 2) }, MON);
  assert.deepEqual(slots.map((s) => `${s.start}-${s.end}`), ['06:00-07:30', '07:30-09:00', '17:00-18:30', '18:30-20:00']);
});

test('fallback to opens_at / closes_at / open_days when no hours rows', () => {
  const v = venue({ opensAt: '06:00:00', closesAt: '09:00:00', openDays: ['mon', 'tue', 'wed', 'thu', 'fri', 'sat'] });
  assert.deepEqual(generateSlots(v, {}, MON).map((s) => s.start), ['06:00', '07:00', '08:00']);
  assert.deepEqual(generateSlots(v, {}, SUN), []);
  // closes at midnight
  const late = venue({ opensAt: '22:00', closesAt: '00:00', openDays: ['mon'] });
  assert.deepEqual(dayWindows(late, [], MON).open, [{ start: 1320, end: 1440 }]);
  assert.equal(generateSlots(late, {}, MON).at(-1).end, '24:00');
});

test('pass blocks: overlap incl. edge minutes, days, mode all', () => {
  const blocks = [{ days: ['mon', 'tue', 'wed', 'thu', 'fri'], startsAt: '18:00', endsAt: '20:00', note: 'Peak' }];
  const v = venue();
  const slots = generateSlots(v, { hours: split, blocks }, MON);
  assert.deepEqual(slots.filter((s) => s.passBlocked).map((s) => s.start), ['18:00', '19:00']);
  assert.equal(slots.find((s) => s.start === '17:00').passBlocked, false); // 17–18 ends as block starts
  assert.equal(slots.find((s) => s.start === '20:00').passBlocked, false); // starts as block ends
  // point checks for walk-in check-ins
  assert.equal(passBlockAt(v, blocks, MON, toMin('17:59')), null);
  assert.ok(passBlockAt(v, blocks, MON, toMin('18:00')));
  assert.ok(passBlockAt(v, blocks, MON, toMin('19:59')));
  assert.equal(passBlockAt(v, blocks, MON, toMin('20:00')), null);
  // a 30-min slot 17:45–18:15 overlaps
  assert.ok(passBlockAt(v, blocks, MON, toMin('17:45'), toMin('18:15')));
  // weekend not blocked
  assert.equal(passBlockAt(v, blocks, SAT, toMin('19:00')), null);
  // empty days = every day
  assert.ok(passBlockAt(v, [{ days: [], startsAt: '18:00', endsAt: '20:00' }], SUN, toMin('18:30')));
  // mode 'all' = pass valid at all hours, blocks ignored
  assert.equal(passBlockAt(venue({ fitkeyPassMode: 'all' }), blocks, MON, toMin('19:00')), null);
  assert.deepEqual(passBlockLabels(venue({ fitkeyPassMode: 'all' }), blocks), []);
});

test('closures: whole day and blocked slot', () => {
  const closures = [
    { closedOn: MON, slotStart: '07:00', slotEnd: '08:30', note: 'Deep clean' },
    { closedOn: SAT, slotStart: null, slotEnd: null, note: 'Diwali' },
  ];
  const slots = generateSlots(venue(), { hours: split, closures }, MON);
  assert.deepEqual(slots.filter((s) => s.blocked).map((s) => s.start), ['07:00', '08:00']);
  assert.equal(slots.find((s) => s.start === '07:00').closureNote, 'Deep clean');
  assert.equal(slots.find((s) => s.start === '06:00').blocked, false);
  assert.equal(closureAt(closures, MON, toMin('08:30'), toMin('09:30')), null);
  const allWeek = WEEK();
  assert.deepEqual(generateSlots(venue(), { hours: allWeek, closures }, SAT), []);
  assert.equal(isOpenDay(venue(), { hours: allWeek, closures }, SAT), false);
  assert.equal(isOpenDay(venue(), { hours: allWeek, closures }, MON), true);
});

function WEEK() {
  return ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'].map((weekday) => ({ weekday, opensAt: '06:00', closesAt: '22:00', kind: 'open' }));
}

test('capacity = slot capacity × courts; pass cap capped by capacity', () => {
  assert.equal(slotCapacity(venue({ slotCapacity: 4, courts: 3 })), 12);
  assert.equal(slotCapacity(venue({ slotCapacity: 4, courts: null })), 4);
  assert.equal(passCapFor(venue({ slotCapacity: 4, courts: 3, passSlotCap: 5 })), 5);
  assert.equal(passCapFor(venue({ slotCapacity: 4, courts: 3, passSlotCap: 50 })), 12);
  assert.equal(passCapFor(venue({ slotCapacity: 4, courts: 3, passSlotCap: 0 })), 0);
  assert.equal(passCapFor(venue({ slotCapacity: 4, courts: 3 })), 12);
  const s = generateSlots(venue({ slotCapacity: 2, courts: 4, passSlotCap: 3 }), { hours: split }, MON)[0];
  assert.equal(s.capacity, 8);
  assert.equal(s.passCap, 3);
});

test('walk-in check-in: hours with 30-min grace, closures', () => {
  const v = venue();
  assert.equal(checkinOpen(v, { hours: split }, MON, '05:30').open, true);
  assert.equal(checkinOpen(v, { hours: split }, MON, '05:29').open, false);
  assert.equal(checkinOpen(v, { hours: split }, MON, '13:00').open, false);
  assert.equal(checkinOpen(v, { hours: split }, MON, '20:59').open, true);
  assert.equal(checkinOpen(v, { hours: split }, MON, '21:00').open, false);
  assert.match(checkinOpen(v, { hours: split }, SAT, '09:00').reason, /closed right now/);
  const closures = [{ closedOn: MON, slotStart: '07:00', slotEnd: '08:00', note: null }];
  assert.equal(checkinOpen(v, { hours: split, closures }, MON, '07:30').open, false);
  assert.equal(checkinOpen(v, { hours: split, closures }, MON, '08:00').open, true);
});

test('human labels', () => {
  assert.equal(rangeLabel('18:00', '20:00'), '6–8 PM');
  assert.equal(rangeLabel('06:30', '09:00'), '6:30–9 AM');
  assert.equal(rangeLabel('11:00', '13:00'), '11 AM–1 PM');
  assert.equal(rangeLabel('22:00', '24:00'), '10 PM–12 AM');
  assert.equal(daysLabel(['mon', 'tue', 'wed', 'thu', 'fri']), 'Mon–Fri');
  assert.equal(daysLabel(['sun', 'sat']), 'Sat–Sun');
  assert.equal(daysLabel(['mon', 'wed', 'fri']), 'Mon, Wed, Fri');
  assert.equal(daysLabel([]), 'every day');
  const blocks = [{ days: ['mon', 'tue', 'wed', 'thu', 'fri'], startsAt: '18:00', endsAt: '20:00' }];
  assert.deepEqual(passBlockLabels(venue(), blocks), ['FitKey pass not valid 6–8 PM (Mon–Fri)']);
  assert.equal(
    passBlockedMessage(venue(), blocks[0]),
    'FitKey pass not valid 6–8 PM at this venue. Your own Iron Gym pass works at any time.',
  );
  const ladies = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat'].map((weekday) => ({ weekday, opensAt: '07:00:00', closesAt: '09:00:00', kind: 'ladies_only' }));
  assert.deepEqual(ladiesOnlyLabels([...ladies, ...split.slice(0, 2)]), ['Ladies only 7–9 AM (Mon–Sat)']);
});

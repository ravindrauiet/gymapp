import assert from 'node:assert/strict';
import { test } from 'node:test';
import { commissionPct, commissionPlan, directSalePayout, passVisitPayout, planYear } from './commission.js';

// BRD §5.3 worked examples: monthly fee ₹1,500.
test('Case 1 per ₹1,500 pass sold: 1428.57 / 1391.07 / 1353.57', () => {
  const live = '2027-03-15T00:00:00Z';
  assert.equal(directSalePayout(150000, live, '2027-06-01').netPaise, 142857);
  assert.equal(directSalePayout(150000, live, '2028-06-01').netPaise, 139107);
  assert.equal(directSalePayout(150000, live, '2029-06-01').netPaise, 135357);
});

test('Case 2 per FitKey pass check-in: 50.00 / 48.75 / 47.50', () => {
  const live = '2027-03-15T00:00:00Z';
  assert.equal(passVisitPayout(150000, live, '2027-06-01').netPaise, 5000);
  assert.equal(passVisitPayout(150000, live, '2028-06-01').netPaise, 4875);
  assert.equal(passVisitPayout(150000, live, '2029-06-01').netPaise, 4750);
});

test('years count from go-live: 15 Mar 2027 → 0% through 14 Mar 2028', () => {
  const live = '2027-03-15T00:00:00Z';
  assert.equal(commissionPct(live, '2028-03-14T23:00:00Z'), 0);
  assert.equal(commissionPct(live, '2028-03-15T00:00:00Z'), 2.5);
  assert.equal(planYear(live, '2029-03-15T00:00:00Z'), 3);
  const plan = commissionPlan(live, '2027-05-01');
  assert.equal(plan.years[0].to, '2028-03-14');
  assert.equal(plan.currentYearEndsOn, '2028-03-14');
  assert.equal(plan.years[2].to, null);
});

test('not live yet → year 1 rate', () => {
  assert.equal(commissionPct(null), 0);
  assert.equal(commissionPlan(null).currentYear, 1);
});

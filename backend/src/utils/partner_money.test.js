import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  csvRow,
  earningPerDayPaise,
  escapeHtml,
  lastFullWeek,
  maskPhone,
  memberStatus,
  nextMonday,
  planDaysFor,
  visitPayoutFields,
} from './partner_money.js';

test('phone masking for FitKey members', () => {
  assert.equal(maskPhone('+919812345621'), '98XXXXXX21');
  assert.equal(maskPhone('9812345621'), '98XXXXXX21');
  assert.equal(maskPhone('+91 98123 45621'), '98XXXXXX21');
  assert.equal(maskPhone(null), null);
});

test('earning per day = price ÷ plan days', () => {
  assert.equal(planDaysFor('Monthly', '2026-11-01', '2026-12-01'), 30);
  assert.equal(planDaysFor('Quarterly', '2026-11-01', null), 90);
  assert.equal(planDaysFor('Half-yearly', null, null), 180);
  assert.equal(planDaysFor('Yearly', null, null), 365);
  assert.equal(planDaysFor('Annual', null, null), 365);
  assert.equal(planDaysFor('Weekly', null, null), 7);
  assert.equal(planDaysFor('Day pass', null, null), 1);
  assert.equal(planDaysFor('Custom', null, null), null);
  assert.equal(earningPerDayPaise(150000, 30), 5000);
  assert.equal(earningPerDayPaise(100000, 3), 33333);
  assert.equal(earningPerDayPaise(150000, null), null);
});

test('member status: expiring within 7 days, expired after renewal date', () => {
  const today = '2026-11-11';
  assert.equal(memberStatus(null, today), 'active');
  assert.equal(memberStatus('2026-11-30', today), 'active');
  assert.equal(memberStatus('2026-11-18', today), 'expiring');
  assert.equal(memberStatus('2026-11-11', today), 'expiring');
  assert.equal(memberStatus('2026-11-10', today), 'expired');
});

test('FitKey-pass visit payout uses passVisitPayout when the monthly fee is set', () => {
  const live = '2027-03-15T00:00:00Z';
  assert.deepEqual(visitPayoutFields(150000, live, '2027-06-01', 9999), { grossPaise: 5000, commissionPct: 0, commissionPaise: 0, netPaise: 5000 });
  assert.deepEqual(visitPayoutFields(150000, live, '2028-06-01', 9999), { grossPaise: 5000, commissionPct: 2.5, commissionPaise: 125, netPaise: 4875 });
  assert.deepEqual(visitPayoutFields(150000, live, '2029-06-01', 9999), { grossPaise: 5000, commissionPct: 5, commissionPaise: 250, netPaise: 4750 });
  // old rule without a monthly fee
  assert.deepEqual(visitPayoutFields(null, live, '2029-06-01', 12000), { grossPaise: 12000, commissionPct: 0, commissionPaise: 0, netPaise: 12000 });
});

test('weekly payout dates', () => {
  assert.equal(nextMonday('2026-11-11'), '2026-11-16'); // Wed → next Mon
  assert.equal(nextMonday('2026-11-16'), '2026-11-23'); // Mon → following Mon
  assert.equal(nextMonday('2026-11-15'), '2026-11-16'); // Sun → tomorrow
  assert.deepEqual(lastFullWeek('2026-11-11'), { periodStart: '2026-11-02', periodEnd: '2026-11-08' });
  assert.deepEqual(lastFullWeek('2026-11-16'), { periodStart: '2026-11-09', periodEnd: '2026-11-15' });
});

test('csv + html escaping', () => {
  assert.equal(csvRow(['a', 'b,c', 'say "hi"', null, 12.5, '-3.00']), 'a,"b,c","say ""hi""",,12.5,-3.00');
  assert.equal(csvRow(['=HYPERLINK("x")']), `"'=HYPERLINK(""x"")"`);
  assert.equal(escapeHtml('<b>"A&B"</b>'), '&lt;b&gt;&quot;A&amp;B&quot;&lt;/b&gt;');
});

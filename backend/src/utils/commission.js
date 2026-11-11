/**
 * Founding-partner commission plan + payout maths (Partner BRD §5). Single source of truth — every route that
 * computes a partner payout or shows the plan must use these helpers.
 *
 *  Year 1 (from go-live)  0%    · Year 2  2.5%   · Year 3 onwards  5% (standard)
 *  Years are counted from the partner's go-live date (users.partner_go_live_at), not calendar years:
 *  go-live 15 Mar 2027 → 0% until 14 Mar 2028 (inclusive), 2.5% until 14 Mar 2029, then 5%.
 *  Before go-live (no date yet) the Year-1 rate applies.
 *
 *  Case 1 — member buys the venue's own plan:   partner gets price − GST (price × 5/105) − commission on price.
 *  Case 2 — member uses the FitKey pass:        partner gets (monthly fee ÷ 30) − commission; FitKey bears GST.
 */

export const STANDARD_COMMISSION_PCT = 5;
export const GST_PCT = 5;
export const PLAN_YEARS = [
  { year: 1, pct: 0, label: 'Year 1', note: 'First year free' },
  { year: 2, pct: 2.5, label: 'Year 2', note: 'Founding-partner rate' },
  { year: 3, pct: 5, label: 'Year 3 onwards', note: 'Standard rate' },
];
export const COMMISSION_MESSAGE =
  'Our standard commission is 5%. As a FitKey Founding Partner, your first year is free (0%), the second year is ' +
  '2.5%, and the standard 5% applies from the third year.';
export const PAYOUT_RULE =
  'For each FitKey pass check-in you are paid your monthly fee ÷ 30, minus that year\'s commission. FitKey bears the ' +
  'GST on FitKey pass visits. When a member buys your own plan, the GST part (price × 5/105) and the commission are ' +
  'deducted from your payout; FitKey files and pays the GST for you.';

const DAY = 86_400_000;

/** goLive + n years, as a Date (same calendar day). */
function addYears(d, n) {
  const x = new Date(d.getTime());
  x.setFullYear(x.getFullYear() + n);
  return x;
}

/** Which plan year (1, 2, 3+) a date falls in, counted from go-live. */
export function planYear(goLiveAt, at = new Date()) {
  if (!goLiveAt) return 1;
  const live = new Date(goLiveAt);
  const when = new Date(at);
  if (when < addYears(live, 1)) return 1;
  if (when < addYears(live, 2)) return 2;
  return 3;
}

export function commissionPct(goLiveAt, at = new Date()) {
  return PLAN_YEARS[Math.min(planYear(goLiveAt, at), 3) - 1].pct;
}

const toYmd = (d) => d.toISOString().slice(0, 10);

/** The plan as shown in the apps: each year's window, the current year and when it ends. */
export function commissionPlan(goLiveAt, at = new Date()) {
  const live = goLiveAt ? new Date(goLiveAt) : null;
  const current = planYear(goLiveAt, at);
  const years = PLAN_YEARS.map((y) => {
    if (!live) return { ...y, from: null, to: null, current: y.year === 1 };
    const from = addYears(live, y.year - 1);
    const to = y.year < 3 ? new Date(addYears(live, y.year).getTime() - DAY) : null;
    return { ...y, from: toYmd(from), to: to ? toYmd(to) : null, current: y.year === current };
  });
  const cur = years[current - 1];
  return {
    standardPct: STANDARD_COMMISSION_PCT,
    goLiveAt: live ? live.toISOString() : null,
    currentYear: current,
    currentPct: cur.pct,
    currentYearEndsOn: cur.to,
    years,
    message: COMMISSION_MESSAGE,
    payoutRule: PAYOUT_RULE,
  };
}

/** Case 2: payout for one FitKey-pass check-in, in paise. */
export function passVisitPayout(monthlyFeePaise, goLiveAt, at = new Date()) {
  const gross = Math.floor(monthlyFeePaise / 30);
  const pct = commissionPct(goLiveAt, at);
  const commission = Math.round((gross * pct) / 100);
  return { grossPaise: gross, commissionPct: pct, commissionPaise: commission, netPaise: gross - commission };
}

/** Case 1: partner's share of a direct plan sale (price includes 5% GST), in paise. */
export function directSalePayout(pricePaise, goLiveAt, at = new Date()) {
  const gst = Math.round((pricePaise * GST_PCT) / (100 + GST_PCT));
  const pct = commissionPct(goLiveAt, at);
  const commission = Math.round((pricePaise * pct) / 100);
  return { grossPaise: pricePaise, gstPaise: gst, commissionPct: pct, commissionPaise: commission, netPaise: pricePaise - gst - commission };
}

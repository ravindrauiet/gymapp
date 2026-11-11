/**
 * Pure helpers for the partner Run / Earn screens and payouts (contract §F). No database access — unit-tested in
 * partner_money.test.js. Commission / GST maths stays in utils/commission.js; this file only applies it.
 */
import { passVisitPayout } from './commission.js';

export const PAYOUT_SCHEDULE = 'weekly'; // BRD open question; weekly (every Monday, for the previous Mon–Sun)
export const EXPIRING_DAYS = 7;

const DAY = 86_400_000;
const ymd = (d) => d.toISOString().slice(0, 10);
export const addDays = (date, n) => ymd(new Date(Date.parse(`${date}T00:00:00Z`) + n * DAY));
export const daysBetween = (from, to) => Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / DAY);

/** FitKey members' phones are masked for partners: +919812345621 → "98XXXXXX21". */
export function maskPhone(phone) {
  if (!phone) return null;
  let d = String(phone).replace(/\D/g, '');
  if (d.length > 10) d = d.slice(-10);
  if (d.length < 4) return 'XXXX';
  return `${d.slice(0, 2)}${'X'.repeat(d.length - 4)}${d.slice(-2)}`;
}

const LABEL_DAYS = [
  [/hour/i, 1],
  [/\bday|daily|day pass/i, 1],
  [/week/i, 7],
  [/half[\s-]?year|6[\s-]?month/i, 180],
  [/quarter|3[\s-]?month/i, 90],
  [/year|annual|12[\s-]?month/i, 365],
  [/month/i, 30],
];

/** Days a plan covers: renewalOn − joinedOn when both are known, else from the label (Monthly → 30 …), else null. */
export function planDaysFor(planLabel, joinedOn, renewalOn) {
  if (joinedOn && renewalOn) {
    const d = daysBetween(joinedOn, renewalOn);
    if (d > 0) return d;
  }
  for (const [re, days] of LABEL_DAYS) if (re.test(planLabel ?? '')) return days;
  return null;
}

/** Earning per day = price ÷ plan days (rounded paise); null when the plan length is unknown. */
export function earningPerDayPaise(pricePaise, days) {
  if (!days || days <= 0) return null;
  return Math.round((pricePaise ?? 0) / days);
}

/** active | expiring (renewal within 7 days) | expired (renewal date passed). No renewal date → active. */
export function memberStatus(renewalOn, today) {
  if (!renewalOn) return 'active';
  const left = daysBetween(today, renewalOn);
  if (left < 0) return 'expired';
  if (left <= EXPIRING_DAYS) return 'expiring';
  return 'active';
}

/**
 * Payout row for one FitKey-pass check-in. With the venue's monthly fee set: passVisitPayout (fee ÷ 30 − that year's
 * commission, no GST). Without it the old flat rate stands (gross = net = oldRatePaise, 0% commission).
 */
export function visitPayoutFields(monthlyFeePaise, goLiveAt, visitDate, oldRatePaise) {
  if (monthlyFeePaise) {
    const p = passVisitPayout(monthlyFeePaise, goLiveAt, visitDate);
    return { grossPaise: p.grossPaise, commissionPct: p.commissionPct, commissionPaise: p.commissionPaise, netPaise: p.netPaise };
  }
  const rate = Math.max(0, Math.round(oldRatePaise ?? 0));
  return { grossPaise: rate, commissionPct: 0, commissionPaise: 0, netPaise: rate };
}

/** Next Monday strictly after `today` (payout day). */
export function nextMonday(today) {
  const dow = new Date(`${today}T00:00:00Z`).getUTCDay(); // 0 = Sun
  return addDays(today, ((8 - dow) % 7) || 7);
}

/** The last complete Mon–Sun week before `today`. */
export function lastFullWeek(today) {
  const dow = new Date(`${today}T00:00:00Z`).getUTCDay();
  const thisMonday = addDays(today, -((dow + 6) % 7));
  return { periodStart: addDays(thisMonday, -7), periodEnd: addDays(thisMonday, -1) };
}

export const rupees = (paise) => ((paise ?? 0) / 100).toFixed(2);

/** One CSV line (RFC 4180 quoting; cells starting with = + - @ are prefixed with ' against formula injection). */
export function csvRow(values) {
  return values
    .map((v) => {
      let s = v == null ? '' : String(v);
      if (/^[=+\-@]/.test(s) && !/^-?\d+(\.\d+)?$/.test(s)) s = `'${s}`;
      return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    })
    .join(',');
}

export const escapeHtml = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

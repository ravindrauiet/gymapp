/**
 * Pure venue-timing helpers (Partner BRD §4, contract §F/§G): opening hours with split shifts, ladies-only windows,
 * FitKey-pass blocked windows, closures (holidays / blocked slots), slot generation and per-slot capacity.
 * No database access here — routes load the rows and pass them in, so everything is unit-testable.
 *
 * Inputs use the camelCased db rows:
 *   venue   { openDays, opensAt, closesAt, slotMinutes, slotCapacity, courts, passSlotCap, fitkeyPassMode, name }
 *   hours   [{ weekday, opensAt, closesAt, kind: 'open'|'ladies_only' }]   (all weekdays of the venue)
 *   blocks  [{ days:[weekday], startsAt, endsAt, note }]
 *   closures[{ closedOn:'YYYY-MM-DD', slotStart, slotEnd, note }]         (slotStart null = whole day closed)
 * Times may be 'HH:MM' or 'HH:MM:SS' (pg TIME). All ranges are half-open [start, end) in minutes since midnight.
 */

export const WEEKDAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const JS_DAY = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

export const SLOT_DEFAULTS = {
  slotMinutes: 60,
  opensAt: '06:00', // when a centre has no hours at all
  closesAt: '22:00',
  checkinGraceMinutes: 30, // a member may check in up to 30 min before a shift opens
};

export const weekdayOf = (date) => JS_DAY[new Date(`${date}T00:00:00Z`).getUTCDay()];

export function toMin(t) {
  if (t == null) return null;
  const [h, m] = String(t).split(':').map(Number);
  return h * 60 + (m || 0);
}

export const fromMin = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
export const hhmm = (t) => (t == null ? null : String(t).slice(0, 5));

/** Half-open interval overlap: [aS, aE) ∩ [bS, bE) ≠ ∅. Touching edges (18:00 end / 18:00 start) do not overlap. */
export const overlaps = (aS, aE, bS, bE) => aS < bE && bS < aE;

/** Sorts and merges overlapping / touching windows. */
export function mergeWindows(ws) {
  const sorted = ws.filter((w) => w.end > w.start).sort((a, b) => a.start - b.start);
  const out = [];
  for (const w of sorted) {
    const last = out[out.length - 1];
    if (last && w.start <= last.end) last.end = Math.max(last.end, w.end);
    else out.push({ start: w.start, end: w.end });
  }
  return out;
}

/** End minute of a closing time; closes at/after midnight (00:00 or before open) → 24:00. */
function endMin(open, close) {
  const c = toMin(close);
  return c == null || c <= open ? 24 * 60 : c;
}

/**
 * Open and ladies-only windows on `date`. With no venue_hours rows at all, the old opens_at / closes_at /
 * open_days apply. With rows, a weekday that has none is closed. Ladies-only rows count as open time too.
 */
export function dayWindows(venue, hours, date) {
  const wd = weekdayOf(date);
  if (!hours || hours.length === 0) {
    const days = venue.openDays ?? WEEKDAYS.slice(0, 6);
    if (!days.includes(wd)) return { open: [], ladies: [] };
    const open = toMin(venue.opensAt ?? SLOT_DEFAULTS.opensAt);
    return { open: [{ start: open, end: endMin(open, venue.closesAt ?? SLOT_DEFAULTS.closesAt) }], ladies: [] };
  }
  const rows = hours.filter((h) => h.weekday === wd);
  const ws = rows.map((h) => {
    const s = toMin(h.opensAt);
    return { start: s, end: endMin(s, h.closesAt), kind: h.kind ?? 'open' };
  });
  return {
    open: mergeWindows(ws),
    ladies: mergeWindows(ws.filter((w) => w.kind === 'ladies_only')),
  };
}

/** Whole-day closure on `date`, if any. */
export const dayClosure = (closures, date) =>
  (closures ?? []).find((c) => c.closedOn === date && c.slotStart == null) ?? null;

/** Closure (whole day or blocked slot) touching [s, e) on `date`, if any. */
export function closureAt(closures, date, s, e) {
  for (const c of closures ?? []) {
    if (c.closedOn !== date) continue;
    if (c.slotStart == null) return c;
    if (overlaps(s, e, toMin(c.slotStart), toMin(c.slotEnd))) return c;
  }
  return null;
}

/** Whether FitKey-pass blocks apply at this venue: mode 'all' = pass valid at all open hours. */
export const passBlocksApply = (venue) => (venue.fitkeyPassMode ?? 'blocked') !== 'all';

/** The FitKey-pass block touching [s, e) on `date` (null when the pass is valid). */
export function passBlockAt(venue, blocks, date, s, e = s + 1) {
  if (!passBlocksApply(venue)) return null;
  const wd = weekdayOf(date);
  for (const b of blocks ?? []) {
    const days = b.days?.length ? b.days : WEEKDAYS;
    if (!days.includes(wd)) continue;
    if (overlaps(s, e, toMin(b.startsAt), toMin(b.endsAt))) return b;
  }
  return null;
}

/** Capacity of one slot = slot_capacity × courts; pass cap = pass_slot_cap (null = no separate cap). */
export function slotCapacity(venue) {
  return Math.max(1, Number(venue.slotCapacity ?? 20)) * Math.max(1, Number(venue.courts ?? 1));
}
export function passCapFor(venue) {
  const cap = slotCapacity(venue);
  return venue.passSlotCap == null ? cap : Math.min(cap, Number(venue.passSlotCap));
}

/**
 * Slots on `date`: each open window is cut into slotMinutes pieces (a split shift starts its own grid).
 * Returns [{ start, end, capacity, passCap, blocked, closureNote, passBlocked, passBlockNote, ladiesOnly }].
 * Slots blocked by a closure are kept (blocked=true) so boards can show them; whole-day closures give [].
 */
export function generateSlots(venue, { hours, blocks, closures } = {}, date) {
  if (dayClosure(closures, date)) return [];
  const len = Math.max(15, Number(venue.slotMinutes ?? SLOT_DEFAULTS.slotMinutes));
  const { open, ladies } = dayWindows(venue, hours, date);
  const capacity = slotCapacity(venue);
  const passCap = passCapFor(venue);
  const out = [];
  for (const w of open) {
    for (let s = w.start; s + len <= w.end; s += len) {
      const e = s + len;
      const c = closureAt(closures, date, s, e);
      const pb = passBlockAt(venue, blocks, date, s, e);
      out.push({
        start: fromMin(s),
        end: fromMin(e),
        capacity,
        passCap,
        blocked: Boolean(c),
        closureNote: c?.note ?? null,
        passBlocked: Boolean(pb),
        passBlockNote: pb?.note ?? null,
        ladiesOnly: ladies.some((l) => overlaps(s, e, l.start, l.end)),
      });
    }
  }
  return out;
}

/** Is the day bookable at all (open windows and not closed)? */
export function isOpenDay(venue, rules, date) {
  return generateSlots(venue, rules, date).some((s) => !s.blocked);
}

/**
 * Walk-in check-in at `time` ('HH:MM') on `date`: closed / outside hours → { closed: reason }.
 * Opening times are relaxed by checkinGraceMinutes so early arrivals can scan in.
 */
export function checkinOpen(venue, { hours, closures } = {}, date, time) {
  const now = toMin(time);
  const day = dayClosure(closures, date);
  if (day) return { open: false, reason: `${venue.name ?? 'This venue'} is closed today${day.note ? ` (${day.note})` : ''}` };
  const c = closureAt(closures, date, now, now + 1);
  if (c) return { open: false, reason: `${venue.name ?? 'This venue'} has blocked this time${c.note ? ` (${c.note})` : ''}` };
  // Older listings (no per-day hours saved in the new listing flow) were never hour-checked at the desk and often
  // have default open days that don't match reality — only closures apply to them.
  if (!hours?.length) return { open: true };
  const { open } = dayWindows(venue, hours, date);
  const g = SLOT_DEFAULTS.checkinGraceMinutes;
  if (!open.some((w) => now >= w.start - g && now < w.end)) {
    return { open: false, reason: `${venue.name ?? 'This venue'} is closed right now${open.length ? ` — open ${windowsLabel(open)} today` : ' today'}` };
  }
  return { open: true };
}

// ------------------------------------------------------------------------------------------------- human labels

/** 18:00 → "6 PM", 06:30 → "6:30 AM", 00:00 → "12 AM", 12:00 → "12 PM". */
function clock(min, withSuffix = true) {
  const m = ((min % 1440) + 1440) % 1440;
  const h = Math.floor(m / 60);
  const mm = m % 60;
  const h12 = h % 12 === 0 ? 12 : h % 12;
  const suffix = h < 12 ? 'AM' : 'PM';
  return `${h12}${mm ? `:${String(mm).padStart(2, '0')}` : ''}${withSuffix ? ` ${suffix}` : ''}`;
}

/** "6–8 PM", "11 AM–1 PM", "6:30–9 AM". En dash, suffix shared when both ends are in the same half of the day. */
export function rangeLabel(start, end) {
  const s = typeof start === 'number' ? start : toMin(start);
  const e = typeof end === 'number' ? end : toMin(end);
  const same = (s < 720) === (e % 1440 < 720) && e < 1440 && e > s;
  return same ? `${clock(s, false)}–${clock(e)}` : `${clock(s)}–${clock(e)}`;
}

const windowsLabel = (ws) => ws.map((w) => rangeLabel(w.start, w.end)).join(', ');
const DAY_SHORT = { mon: 'Mon', tue: 'Tue', wed: 'Wed', thu: 'Thu', fri: 'Fri', sat: 'Sat', sun: 'Sun' };

/** ['mon'…'fri'] → "Mon–Fri"; all 7 → "every day"; ['mon','wed','fri'] → "Mon, Wed, Fri"; ['sat','sun'] → "Sat–Sun". */
export function daysLabel(days) {
  const idx = [...new Set((days?.length ? days : WEEKDAYS).map((d) => WEEKDAYS.indexOf(d)).filter((i) => i >= 0))].sort((a, b) => a - b);
  if (idx.length === 7) return 'every day';
  const runs = [];
  for (const i of idx) {
    const r = runs[runs.length - 1];
    if (r && i === r[1] + 1) r[1] = i;
    else runs.push([i, i]);
  }
  return runs
    .map(([a, b]) => (a === b ? DAY_SHORT[WEEKDAYS[a]] : `${DAY_SHORT[WEEKDAYS[a]]}–${DAY_SHORT[WEEKDAYS[b]]}`))
    .join(', ');
}

/** ["FitKey pass not valid 6–8 PM (Mon–Fri)", …] — empty when the pass is valid at all hours. */
export function passBlockLabels(venue, blocks) {
  if (!passBlocksApply(venue)) return [];
  return (blocks ?? []).map((b) => `FitKey pass not valid ${rangeLabel(b.startsAt, b.endsAt)} (${daysLabel(b.days)})`);
}

/** 409 message when a FitKey-pass booking / check-in falls in a block. */
export function passBlockedMessage(venue, block) {
  return `FitKey pass not valid ${rangeLabel(block.startsAt, block.endsAt)} at this venue. Your own ${venue.name} pass works at any time.`;
}

/** ["Ladies only 7–9 AM (Mon–Sat)"] — ladies-only rows grouped by identical time range. */
export function ladiesOnlyLabels(hours) {
  const groups = new Map();
  for (const h of hours ?? []) {
    if (h.kind !== 'ladies_only') continue;
    const k = `${hhmm(h.opensAt)}-${hhmm(h.closesAt)}`;
    if (!groups.has(k)) groups.set(k, { s: h.opensAt, e: h.closesAt, days: [] });
    groups.get(k).days.push(h.weekday);
  }
  return [...groups.values()].map((g) => `Ladies only ${rangeLabel(g.s, g.e)} (${daysLabel(g.days)})`);
}

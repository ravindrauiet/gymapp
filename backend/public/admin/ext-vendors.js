// FITKEY admin — "Register vendor" tab. The FitKey team registers a vendor (centre, trainer, clinic, chemist, store
// seller) on their behalf and fills in everything: listing, photos, plans, documents, KYC, bank, submit, approve and the
// owner's agreement OTP. Uses POST /admin/partners (+ /act-as) for a 12 h partner "act-as" token, then talks to the
// normal PARTNER endpoints with that token (asVendor). The act-as token lives in memory only — never in localStorage.
const A = window.FitkeyAdmin;
const { h, api, toast, label, when, assetUrl } = A;
const API = '/api/v1';

// ------------------------------------------------------------------------------------------------ constants

const PARTNER_TYPES = [
  ['fitness_centre', 'Fitness centre (gym, yoga, dance…)'],
  ['sports_centre', 'Sports centre / academy'],
  ['trainer', 'Trainer / coach'],
  ['clinic', 'Clinic'],
  ['chemist', 'Chemist'],
  ['store_seller', 'Store seller'],
];
const TYPE_TEXT = Object.fromEntries(PARTNER_TYPES);
const KIND_BY_TYPE = { fitness_centre: 'venue', sports_centre: 'venue', trainer: 'trainer', clinic: 'clinic', chemist: 'chemist', store_seller: 'store' };
const KIND_LABELS = { venue: 'Centre', trainer: 'Trainer', clinic: 'Clinic', chemist: 'Chemist', store: 'Store' };
const CATEGORIES = ['gym', 'swimming_pool', 'sports_club', 'yoga_studio', 'mma', 'martial_arts', 'dance'];
const SPORTS = ['badminton', 'table_tennis', 'cricket', 'football', 'basketball', 'tennis', 'squash', 'skating', 'swimming'];
const AMENITIES = ['locker', 'shower', 'parking', 'ac', 'wifi', 'changing_room', 'drinking_water', 'cafe', 'steam_sauna'];
const WEEKDAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const DURATIONS = [['hourly', '1-hour visit'], ['day', 'Day pass'], ['weekly', 'Weekly'], ['monthly', 'Monthly'], ['quarterly', 'Quarterly'], ['yearly', 'Yearly']];
const DURATION_TEXT = { ...Object.fromEntries(DURATIONS), annual: 'Yearly' };
const FALLBACK_OPTIONS = {
  trainerSubtypes: ['physiotherapist', 'yoga_master', 'gym_trainer_gym', 'gym_trainer_home', 'sports_coach', 'boxing', 'karate', 'mma', 'dance', 'nutritionist'],
  storeCategories: ['supplements', 'activewear', 'gym_gear', 'healthy_food', 'wellness', 'accessories'],
  productCategories: ['supplements', 'apparel', 'wearables', 'gear', 'activewear', 'gym_gear', 'healthy_food', 'wellness', 'accessories'],
};
const DOC_TYPES = {
  venue: ['licence', 'gst', 'other'],
  trainer: ['certificate', 'achievement', 'other'],
  clinic: ['clinic_registration', 'doctor_registration', 'gst', 'other'],
  chemist: ['drug_licence', 'gst', 'other'],
  store: ['gst', 'trademark', 'fssai', 'other'],
};
const REQUIRED_DOCS = {
  venue: () => ['licence'],
  trainer: () => ['certificate'],
  clinic: () => ['clinic_registration', 'doctor_registration'],
  chemist: () => ['drug_licence', 'gst'],
  store: (l) => ['gst', 'trademark', ...((l?.categories ?? []).some((c) => c === 'supplements' || c === 'healthy_food') ? ['fssai'] : [])],
};
const STATUS_LABELS = {
  draft: 'Draft',
  submitted: 'Submitted',
  under_review: 'Under review',
  changes_needed: 'Changes needed',
  approved: 'Approved · waiting for owner OTP',
  live: 'Live',
  rejected: 'Rejected',
};
const SUBMITTABLE = [null, undefined, 'draft', 'changes_needed', 'rejected'];
const VENUE_STEPS = ['Category', 'Details', 'Location', 'Timings & FitKey access', 'Photos', 'Facilities',
  'Pricing & FitKey pass', 'Slots & capacity', 'Documents & bank', 'Review & submit'];
const OTHER_STEPS = ['Profile', 'Pricing', 'Availability', 'Documents & bank', 'Review & submit'];

// Texts the admin reads out to the owner (same wording as the partner app / utils/commission.js).
const COMMISSION_TEXT = 'Our standard commission is 5%. As a FitKey Founding Partner, your first year is free (0%), the ' +
  'second year is 2.5%, and the standard 5% applies from the third year. Years are counted from your go-live date.';
const PAYOUT_RULE = 'For each FitKey pass check-in you are paid your monthly fee ÷ 30, minus that year\'s commission. ' +
  'FitKey bears the GST on FitKey pass visits. When a member buys your own plan, the GST part (price × 5/105) and the ' +
  'commission are deducted from your payout; FitKey files and pays the GST for you.';
const PASS_CONSENT_TEXT = 'I allow FitKey pass users at my venue. For each FitKey pass check-in I will be paid my monthly ' +
  'fee ÷ 30, minus that year\'s commission. FitKey bears the GST on FitKey pass visits.';
const GST_NOTE = 'Prices include GST (5%). When a member buys a plan, the GST part (price × 5/105) is deducted from the ' +
  'payout; FitKey files and pays it.';

// ------------------------------------------------------------------------------------------------ state

const state = {
  q: '',
  session: null, // { partner, token } — act-as session, memory only
  kind: null, // venue | trainer | clinic | chemist | store
  venueId: null, // centre open in the editor
  open: new Set(['profile']), // expanded sections
};

if (!document.getElementById('vx-style')) {
  document.head.append(h('style', { id: 'vx-style' }, `
.vx-sec { padding: 0; }
.vx-sec + .vx-sec { margin-top: 12px; }
.vx-sec > summary { cursor: pointer; padding: 16px 20px; list-style: none; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.vx-sec > summary::-webkit-details-marker { display: none; }
.vx-sec > summary::before { content: '▸'; color: var(--lime); display: inline-block; transition: transform .15s; }
.vx-sec[open] > summary::before { transform: rotate(90deg); }
.vx-sec > .vx-body { padding: 0 20px 20px; }
.vx-grid { display: grid; gap: 0 16px; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); }
.vx-thumbs { display: flex; gap: 10px; flex-wrap: wrap; }
.vx-thumb { position: relative; width: 150px; }
.vx-thumb img { width: 150px; height: 96px; object-fit: cover; border-radius: 10px; background: var(--surface-2); display: block; }
.vx-thumb .row { gap: 4px; margin-top: 4px; }
.vx-mini { padding: 4px 9px; font-size: 12px; }
.vx-cover { position: absolute; top: 6px; left: 6px; }
.vx-day { display: flex; gap: 8px; align-items: flex-start; flex-wrap: wrap; padding: 6px 0; border-bottom: 1px solid var(--outline); }
.vx-day > strong { width: 44px; padding-top: 8px; }
.vx-shifts { display: flex; flex-direction: column; gap: 6px; flex: 1; min-width: 220px; }
.vx-inline { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.vx-inline > input, .vx-inline > select, .vx-inline label > input, .vx-inline label > select { width: auto; margin: 0; }
.vx-inline > label { margin: 0; }
.vx-bar { height: 8px; background: var(--surface-2); border-radius: 8px; overflow: hidden; }
.vx-bar > div { height: 100%; background: var(--lime); }
.vx-note { background: var(--surface-2); border-radius: 10px; padding: 10px 12px; }
.vx-req { color: var(--danger); }
.vx-scroll { overflow-x: auto; }
.vx-days label { font-size: 12px; }
@media (max-width: 640px) {
  .vx-sec > .vx-body { padding: 0 12px 16px; }
  .vx-sec > summary { padding: 14px 12px; }
}
`));
}

// ------------------------------------------------------------------------------------------------ small helpers

const hhmm = (t) => (t ? String(t).slice(0, 5) : '');
const numOrNull = (s) => (s === '' || s == null ? null : Number(s));
const toPaise = (s) => (s === '' || s == null ? null : Math.round(Number(s) * 100));
const toRupees = (p) => (p == null ? '' : p / 100);
const inr = (p) => `₹${(Number(p ?? 0) / 100).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`;
const lines = (s) => String(s ?? '').split('\n').map((x) => x.trim()).filter(Boolean);
const csvList = (s) => String(s ?? '').split(',').map((x) => x.trim()).filter(Boolean);
const statusPill = (s) => {
  const cls = s === 'approved' ? 'upcoming' : s === 'changes_needed' ? 'pending' : s ?? '';
  return h('span', { class: `pill ${cls}` }, s ? STATUS_LABELS[s] ?? label(s) : 'Not saved yet');
};

/** 10-digit Indian mobile (accepts +91 / 91 / 0 prefixes, spaces, dashes) → "+91XXXXXXXXXX", else null. */
function normPhone(s) {
  let d = String(s ?? '').replace(/\D/g, '');
  if (d.length === 12 && d.startsWith('91')) d = d.slice(2);
  else if (d.length === 11 && d.startsWith('0')) d = d.slice(1);
  return /^[6-9]\d{9}$/.test(d) ? `+91${d}` : null;
}

function field(text, input, hint) {
  return h('label', {}, text, input, hint ? h('div', { class: 'muted', style: 'font-weight:400;font-size:12px' }, hint) : null);
}
function textInput(value, attrs = {}) {
  const el = h('input', attrs);
  el.value = value ?? '';
  return el;
}
function textArea(value, attrs = {}) {
  const el = h('textarea', attrs);
  el.value = value ?? '';
  return el;
}
function select(options, value, attrs = {}) {
  const el = h('select', attrs, options.map(([v, t]) => h('option', { value: v }, t)));
  if (value != null) el.value = value;
  return el;
}
function checkbox(checked, attrs = {}) {
  const el = h('input', { type: 'checkbox', style: 'width:auto;margin:0', ...attrs });
  el.checked = Boolean(checked);
  return el;
}
/** Checkbox group: returns { el, values() }. */
function checkGroup(options, selected, { labeler = label, onchange } = {}) {
  const boxes = options.map((o) => {
    const b = checkbox((selected ?? []).includes(o), { value: o });
    if (onchange) b.addEventListener('change', onchange);
    return b;
  });
  return {
    el: h('div', { class: 'checks' }, boxes.map((b, i) => h('label', {}, b, labeler(options[i])))),
    values: () => boxes.filter((b) => b.checked).map((b) => b.value),
  };
}

/** Button that runs an async action with a busy state; errors become red toasts. */
function actionButton(text, fn, { cls = '', type = 'button' } = {}) {
  const b = h('button', { type, class: cls }, text);
  b.addEventListener('click', async (e) => {
    e.preventDefault();
    if (b.disabled) return;
    b.disabled = true;
    try {
      await fn();
    } catch (err) {
      showError(err);
    } finally {
      b.disabled = false;
    }
  });
  return b;
}

function showError(err) {
  const missing = err?.data?.missing;
  if (Array.isArray(missing) && missing.length) {
    toast(err.message, true);
    alert(`${err.message}\n\n${missing.map((m) => `• Step ${m.step}: ${m.label}${m.hint ? ` — ${m.hint}` : ''}`).join('\n')}`);
    return;
  }
  toast(err?.message ?? String(err), true);
}

/** Collapsible card; the body is built (and data loaded) the first time it opens. build(refresh) → nodes. */
function section(key, title, build, sub) {
  const body = h('div', { class: 'stack vx-body' });
  const d = h('details', { class: 'card vx-sec', open: state.open.has(key) },
    h('summary', {}, h('strong', {}, title), sub ? h('span', { class: 'muted' }, sub) : null), body);
  let built = false;
  const fill = async () => {
    body.replaceChildren(h('p', { class: 'muted', style: 'margin:0' }, 'Loading…'));
    try {
      const c = await build(fill);
      body.replaceChildren(...[c].flat().filter(Boolean));
    } catch (err) {
      body.replaceChildren(h('p', { class: 'muted', style: 'margin:0' }, err.message));
    }
  };
  d.addEventListener('toggle', () => {
    if (d.open) {
      state.open.add(key);
      if (!built) { built = true; fill(); }
    } else state.open.delete(key);
  });
  if (d.open) { built = true; fill(); }
  return d;
}

// ------------------------------------------------------------------------------------------------ act-as fetch

/** Fresh act-as token for the current vendor (tokens last 12 h). */
async function renewToken() {
  const r = await api(`/admin/partners/${state.session.partner.id}/act-as`, { method: 'POST' });
  state.session.token = r.actAsToken;
  state.session.partner = { ...state.session.partner, ...r.partner };
}

/** fetch with the vendor's act-as token; one silent token renewal on an expired-token 401. */
async function vendorFetch(path, init = {}, retry = true) {
  if (!state.session) throw new Error('Open a vendor first');
  const res = await fetch(API + path, { ...init, headers: { ...(init.headers ?? {}), Authorization: `Bearer ${state.session.token}` } });
  if (res.status === 401 && retry) {
    const data = await res.clone().json().catch(() => null);
    if (/token|sign in/i.test(data?.error ?? '')) {
      await renewToken();
      return vendorFetch(path, init, false);
    }
  }
  return res;
}

/** Mirrors api() but acts as the vendor. Errors carry .status and .data (e.g. 400 { error, missing }). */
async function asVendor(path, { method = 'GET', body } = {}) {
  const res = await vendorFetch(path, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = res.status === 204 ? null : await res.json().catch(() => null);
  if (!res.ok) {
    const err = new Error(data?.error ?? `Request failed (${res.status})`);
    err.status = res.status;
    err.data = data;
    throw err;
  }
  return data;
}

/** POST /uploads as the vendor → server-relative URL. kinds: image | doc (image or PDF) | video. */
async function uploadAsVendor(file, kind = 'image') {
  const isImg = /^image\/(jpeg|png|webp)$/.test(file.type);
  const isPdf = file.type === 'application/pdf';
  const isVideo = file.type === 'video/mp4';
  if (kind === 'image' && !isImg) throw new Error('Use a JPEG, PNG or WebP image');
  if (kind === 'doc' && !isImg && !isPdf) throw new Error('Use an image (JPEG, PNG, WebP) or a PDF');
  if (kind === 'video' && !isVideo) throw new Error('Use an MP4 video');
  if (isImg && file.size > 3 * 1024 * 1024) throw new Error(`${file.name}: images must be under 3 MB`);
  if (isPdf && file.size > 5 * 1024 * 1024) throw new Error(`${file.name}: PDFs must be under 5 MB`);
  if (isVideo && file.size > 12 * 1024 * 1024) throw new Error(`${file.name}: videos must be under 12 MB (or paste a YouTube / hosted link)`);
  const fd = new FormData();
  fd.append('file', file);
  const res = await vendorFetch('/uploads', { method: 'POST', body: fd });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(data?.error ?? `Upload failed (${res.status})`);
  return data.url;
}

// ------------------------------------------------------------------------------------------------ reusable editors

/** Single image (URL or upload) with preview → { el, get() }. */
function singleImage(text, initial) {
  const input = textInput(initial, { placeholder: 'https://… or upload' });
  const preview = h('img', { class: 'thumb', alt: '', hidden: true });
  const sync = () => {
    const u = input.value.trim();
    preview.hidden = !u;
    if (u) preview.src = assetUrl(u);
  };
  input.addEventListener('input', sync);
  const picker = h('input', { type: 'file', accept: 'image/jpeg,image/png,image/webp' });
  picker.addEventListener('change', async () => {
    const f = picker.files[0];
    if (!f) return;
    try {
      input.value = await uploadAsVendor(f, 'image');
      sync();
      toast('Image uploaded — remember to save');
    } catch (err) {
      toast(err.message, true);
    }
    picker.value = '';
  });
  sync();
  return { el: h('label', {}, text, input, picker, preview), get: () => input.value.trim() || null };
}

/** Up to `max` photos: first = cover, reorder, remove, upload many, or add by URL → { el, get() }. */
function photoManager(initial, max = 10) {
  const photos = [...(initial ?? [])];
  const grid = h('div', { class: 'vx-thumbs' });
  const count = h('span', { class: 'muted' });
  const move = (i, d) => {
    const j = i + d;
    if (j < 0 || j >= photos.length) return;
    [photos[i], photos[j]] = [photos[j], photos[i]];
    draw();
  };
  function draw() {
    count.textContent = `${photos.length}/${max} photos · the first one is the cover`;
    grid.replaceChildren(...(photos.length ? photos.map((p, i) => h('div', { class: 'vx-thumb' },
      h('a', { href: assetUrl(p), target: '_blank', rel: 'noopener' }, h('img', { src: assetUrl(p), alt: '', loading: 'lazy' })),
      i === 0 ? h('span', { class: 'pill live vx-cover' }, 'Cover') : null,
      h('div', { class: 'row' },
        h('button', { type: 'button', class: 'ghost vx-mini', title: 'Move left', disabled: i === 0, onclick: () => move(i, -1) }, '←'),
        h('button', { type: 'button', class: 'ghost vx-mini', title: 'Move right', disabled: i === photos.length - 1, onclick: () => move(i, 1) }, '→'),
        i > 0 ? h('button', { type: 'button', class: 'ghost vx-mini', title: 'Make cover', onclick: () => { photos.unshift(...photos.splice(i, 1)); draw(); } }, 'Cover') : null,
        h('button', { type: 'button', class: 'danger vx-mini', title: 'Remove', onclick: () => { photos.splice(i, 1); draw(); } }, '✕')),
    )) : [h('p', { class: 'muted', style: 'margin:0' }, 'No photos yet.')]));
  }
  const picker = h('input', { type: 'file', accept: 'image/jpeg,image/png,image/webp', multiple: true });
  picker.addEventListener('change', async () => {
    const files = [...picker.files];
    picker.value = '';
    const room = max - photos.length;
    if (files.length > room) toast(`Only ${room} more photo${room === 1 ? '' : 's'} allowed — extra files skipped`, true);
    let ok = 0;
    for (const f of files.slice(0, Math.max(0, room))) {
      try {
        photos.push(await uploadAsVendor(f, 'image'));
        ok += 1;
        draw();
      } catch (err) {
        toast(err.message, true);
      }
    }
    if (ok) toast(`${ok} photo${ok === 1 ? '' : 's'} uploaded — remember to save`);
  });
  const urlIn = h('input', { placeholder: 'or paste an https:// image link' });
  draw();
  return {
    el: h('div', { class: 'stack' }, count, grid,
      h('div', { class: 'vx-inline' }, h('label', {}, 'Upload photos', picker)),
      h('div', { class: 'vx-inline' }, urlIn, h('button', { type: 'button', class: 'ghost', onclick: () => {
        const u = urlIn.value.trim();
        if (!/^https?:\/\/\S+$/.test(u)) return toast('Paste a full https:// link', true);
        if (photos.length >= max) return toast(`Up to ${max} photos`, true);
        photos.push(u);
        urlIn.value = '';
        draw();
      } }, 'Add link'))),
    get: () => [...photos],
  };
}

/** List of editable objects with add / remove. renderRow(item, remove) → node. */
function repeater(items, renderRow, makeNew, addText) {
  const list = h('div', { class: 'stack' });
  const draw = () => list.replaceChildren(...(items.length
    ? items.map((it, i) => renderRow(it, () => { items.splice(i, 1); draw(); }))
    : [h('p', { class: 'muted', style: 'margin:0' }, 'None.')]));
  draw();
  return h('div', { class: 'stack' }, list,
    h('button', { type: 'button', class: 'ghost', onclick: () => { items.push(makeNew()); draw(); } }, addText));
}
/** Input bound to obj[key]. */
function bound(obj, key, attrs = {}, parse = (x) => x) {
  const el = h('input', { style: 'width:auto;margin:0', ...attrs });
  el.value = obj[key] ?? '';
  el.addEventListener('input', () => { obj[key] = parse(el.value); });
  return el;
}
function dayChecks(obj, key) {
  return h('div', { class: 'checks vx-days' }, WEEKDAYS.map((d) => {
    const b = checkbox((obj[key] ?? []).includes(d));
    b.addEventListener('change', () => {
      const set = new Set(obj[key] ?? []);
      if (b.checked) set.add(d); else set.delete(d);
      obj[key] = WEEKDAYS.filter((x) => set.has(x));
    });
    return h('label', {}, b, label(d));
  }));
}

/**
 * Weekly hours: rows [{weekday, <start>, <end>, kind?}], several rows a day = split shift.
 * Quick generator ("same hours Mon–Sat / all 7 days") + per-day shifts → { el, read() }.
 */
function hoursEditor(initial, { start = 'opensAt', end = 'closesAt', withKind = false, defFrom = '06:00', defTo = '22:00' } = {}) {
  const rows = (initial ?? []).map((r) => ({ weekday: r.weekday, [start]: hhmm(r[start]), [end]: hhmm(r[end]), ...(withKind ? { kind: r.kind ?? 'open' } : {}) }));
  const box = h('div');
  const from = textInput(defFrom, { type: 'time' });
  const to = textInput(defTo, { type: 'time' });
  const kindSel = withKind ? select([['open', 'Open'], ['ladies_only', 'Ladies only']], 'open') : null;
  const gen = (days, replace) => {
    if (!from.value || !to.value || to.value <= from.value) return toast('Closing time must be after opening time (same day)', true);
    const kind = kindSel?.value ?? 'open';
    for (const d of days) {
      if (replace) for (let i = rows.length - 1; i >= 0; i -= 1) if (rows[i].weekday === d) rows.splice(i, 1);
      rows.push({ weekday: d, [start]: from.value, [end]: to.value, ...(withKind ? { kind } : {}) });
    }
    draw();
  };
  function draw() {
    box.replaceChildren(...WEEKDAYS.map((d) => {
      const mine = rows.filter((r) => r.weekday === d).sort((a, b) => String(a[start]).localeCompare(String(b[start])));
      return h('div', { class: 'vx-day' },
        h('strong', {}, label(d)),
        h('div', { class: 'vx-shifts' },
          mine.length ? mine.map((r) => h('div', { class: 'vx-inline' },
            bound(r, start, { type: 'time' }), '–', bound(r, end, { type: 'time' }),
            withKind ? (() => {
              const s = select([['open', 'Open'], ['ladies_only', 'Ladies only']], r.kind ?? 'open', { style: 'width:auto;margin:0' });
              s.addEventListener('change', () => { r.kind = s.value; });
              return s;
            })() : null,
            h('button', { type: 'button', class: 'ghost vx-mini', onclick: () => { rows.splice(rows.indexOf(r), 1); draw(); } }, '✕'),
          )) : h('span', { class: 'muted', style: 'padding-top:8px' }, 'Closed')),
        h('button', { type: 'button', class: 'ghost vx-mini', onclick: () => {
          const last = mine[mine.length - 1];
          rows.push({ weekday: d, [start]: last ? last[end] : from.value, [end]: last ? '' : to.value, ...(withKind ? { kind: 'open' } : {}) });
          draw();
        } }, '+ shift'),
      );
    }));
  }
  draw();
  return {
    el: h('div', { class: 'stack' },
      h('div', { class: 'vx-note stack' },
        h('div', { class: 'vx-inline' }, h('strong', {}, 'Quick fill'), from, '–', to, kindSel),
        h('div', { class: 'vx-inline' },
          h('button', { type: 'button', class: 'ghost', onclick: () => gen(WEEKDAYS.slice(0, 6), true) }, 'Same hours Mon–Sat'),
          h('button', { type: 'button', class: 'ghost', onclick: () => gen(WEEKDAYS, true) }, 'All 7 days'),
          h('button', { type: 'button', class: 'ghost', onclick: () => gen(WEEKDAYS.slice(0, 6), false) }, 'Add as extra shift Mon–Sat'),
          h('button', { type: 'button', class: 'ghost', onclick: () => { rows.length = 0; draw(); } }, 'Clear all')),
        h('div', { class: 'muted', style: 'font-size:12px' }, 'Split shift (e.g. 6–11 AM and 4–10 PM): use “+ shift” on a day, or quick-fill the second shift with “Add as extra shift”.')),
      box),
    read() {
      const out = [];
      for (const r of rows) {
        if (!r[start] && !r[end]) continue;
        if (!r[start] || !r[end] || r[end] <= r[start]) throw new Error(`${label(r.weekday)}: each shift needs a start and an end after it (same day)`);
        out.push({ weekday: r.weekday, [start]: r[start], [end]: r[end], ...(withKind ? { kind: r.kind ?? 'open' } : {}) });
      }
      return out.sort((a, b) => WEEKDAYS.indexOf(a.weekday) - WEEKDAYS.indexOf(b.weekday) || a[start].localeCompare(b[start]));
    },
  };
}

/** Address / area / city / lat / lng with "Find on map" (Nominatim) and a paste-coordinates helper. */
function locationFields(v) {
  const address = textInput(v.address, { placeholder: 'Shop no, building, street' });
  const area = textInput(v.area, { placeholder: 'Locality' });
  const city = textInput(v.city);
  const lat = textInput(v.latitude ?? '', { type: 'number', step: 'any' });
  const lng = textInput(v.longitude ?? '', { type: 'number', step: 'any' });
  const results = h('div', { class: 'stack' });
  const osm = h('a', { class: 'link', target: '_blank', rel: 'noopener' }, 'View the pin on OpenStreetMap ↗');
  const syncLink = () => {
    const ok = lat.value !== '' && lng.value !== '';
    osm.hidden = !ok;
    if (ok) osm.href = `https://www.openstreetmap.org/?mlat=${lat.value}&mlon=${lng.value}#map=17/${lat.value}/${lng.value}`;
  };
  lat.addEventListener('input', syncLink);
  lng.addEventListener('input', syncLink);
  const setPoint = (la, lo) => {
    lat.value = Number(la).toFixed(6);
    lng.value = Number(lo).toFixed(6);
    syncLink();
  };
  const query = () => [address.value, area.value, city.value].map((s) => s.trim()).filter(Boolean).join(', ');
  const find = async () => {
    const q = query();
    if (!q) return toast('Type the address and city first', true);
    results.replaceChildren(h('p', { class: 'muted', style: 'margin:0' }, 'Searching the map…'));
    try {
      const res = await fetch(`https://nominatim.openstreetmap.org/search?format=json&countrycodes=in&limit=5&q=${encodeURIComponent(q)}`);
      const list = await res.json();
      if (!Array.isArray(list) || !list.length) {
        results.replaceChildren(h('p', { class: 'muted', style: 'margin:0' }, 'No match — try a shorter address (area + city), or paste the coordinates below.'));
        return;
      }
      if (list.length === 1) setPoint(list[0].lat, list[0].lon);
      results.replaceChildren(h('div', { class: 'muted' }, list.length === 1 ? 'Pinned:' : 'Pick the right place:'),
        ...list.map((r) => h('button', { type: 'button', class: 'ghost', style: 'text-align:left;font-weight:500', onclick: () => { setPoint(r.lat, r.lon); toast('Location set — remember to save'); } },
          r.display_name)));
    } catch {
      // The panel's Content-Security-Policy may block calls to other sites — fall back to OSM in a new tab.
      window.open(`https://www.openstreetmap.org/search?query=${encodeURIComponent(q)}`, '_blank', 'noopener');
      results.replaceChildren(h('p', { class: 'muted', style: 'margin:0' },
        'Opened OpenStreetMap in a new tab. Right-click the exact spot → “Show address”, copy the two numbers (or copy a Google Maps link) and paste them below.'));
    }
  };
  const paste = h('input', { placeholder: 'Paste “12.9716, 77.5946” or a Google Maps / OSM link' });
  paste.addEventListener('change', () => {
    const s = paste.value;
    const m = s.match(/mlat=(-?\d+(?:\.\d+)?)&mlon=(-?\d+(?:\.\d+)?)/) ?? s.match(/@(-?\d+\.\d+),(-?\d+\.\d+)/) ??
      s.match(/(-?\d{1,2}\.\d{3,})\s*[,/ ]\s*(-?\d{1,3}\.\d{3,})/);
    if (!m) return toast('Could not read coordinates from that', true);
    setPoint(m[1], m[2]);
    paste.value = '';
    toast('Location set — remember to save');
  });
  syncLink();
  return {
    el: h('div', { class: 'stack' },
      h('div', { class: 'vx-grid' }, field('Address', address), field('Area / locality', area), field('City', city),
        field('Latitude', lat), field('Longitude', lng)),
      h('div', { class: 'vx-inline' }, h('button', { type: 'button', class: 'ghost', onclick: find }, 'Find on map'), osm),
      results,
      field('Paste coordinates', paste)),
    read() {
      const la = numOrNull(lat.value);
      const lo = numOrNull(lng.value);
      if ((la == null) !== (lo == null)) throw new Error('Give both latitude and longitude, or neither');
      return { address: address.value.trim(), area: area.value.trim() || null, city: city.value.trim(), latitude: la, longitude: lo };
    },
  };
}

function checklistView(c, steps) {
  if (!c) return null;
  const missing = c.missing ?? [];
  const required = missing.filter((m) => m.required && m.step !== steps.length);
  return h('div', { class: 'stack' },
    h('div', { class: 'row' }, h('strong', {}, `Setup ${c.percent ?? 0}% done`), h('span', { class: 'spacer' }),
      required.length ? h('span', { class: 'pill rejected' }, `${required.length} required item${required.length === 1 ? '' : 's'} left`)
        : h('span', { class: 'pill live' }, 'Ready to submit')),
    h('div', { class: 'vx-bar' }, h('div', { style: `width:${Math.max(0, Math.min(100, c.percent ?? 0))}%` })),
    missing.length ? h('ul', { style: 'margin:0;padding-left:18px' }, missing.map((m) => h('li', {},
      h('span', { class: m.required ? 'vx-req' : 'muted' }, m.required ? 'Required · ' : 'Recommended · '),
      `Step ${m.step} ${steps[m.step - 1] ?? ''}: `, h('strong', {}, m.hint ?? m.label)))) : h('p', { class: 'muted', style: 'margin:0' }, 'Everything is filled in.'),
  );
}

// ------------------------------------------------------------------------------------------------ Partner listings jump

function waitFor(fn, ms = 8000) {
  return new Promise((resolve, reject) => {
    const t0 = Date.now();
    const tick = () => {
      const r = fn();
      if (r) return resolve(r);
      if (Date.now() - t0 > ms) return reject(new Error('timeout'));
      setTimeout(tick, 80);
    };
    tick();
  });
}
const btnByText = (t) => [...document.querySelectorAll('#view button')].find((b) => b.textContent.trim() === t);

/** Opens the "Partner listings" tab, status = All, searched by the vendor's phone (best effort, no edits there). */
async function openInPartnerListings(phone) {
  const tab = document.querySelector('#tabs [data-tab="partners"]');
  const q = String(phone ?? '').replace(/\D/g, '').slice(-10);
  if (!tab) return toast('The Partner listings tab is not loaded', true);
  tab.click();
  const sel = '#view input[placeholder="Name or owner phone…"]';
  try {
    let input = await waitFor(() => document.querySelector(sel) || btnByText('← Back to queue') || btnByText('Listings queue'));
    if (!(input instanceof HTMLInputElement)) {
      (btnByText('← Back to queue') ?? btnByText('Listings queue')).click();
      input = await waitFor(() => document.querySelector(sel));
    }
    const all = btnByText('All');
    if (all && !all.classList.contains('active')) {
      all.click();
      const old = input;
      input = await waitFor(() => { const i = document.querySelector(sel); return i && i !== old ? i : null; });
    }
    if (q) {
      input.value = q;
      input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    }
  } catch {
    toast(`In Partner listings, search for ${q}`);
  }
}

// ------------------------------------------------------------------------------------------------ vendor list + register

async function manage(partnerId, { kind, venueId } = {}) {
  const r = await api(`/admin/partners/${partnerId}/act-as`, { method: 'POST' });
  startSession(r.partner, r.actAsToken, { kind, venueId });
}

function startSession(partner, token, { kind, venueId } = {}) {
  state.session = { partner, token };
  state.kind = kind ?? KIND_BY_TYPE[partner.partnerType] ?? 'venue';
  state.venueId = venueId ?? null;
  state.open = new Set(['profile']);
  A.rerender();
}

function registerForm() {
  const phone = h('input', { placeholder: '98765 43210', inputmode: 'tel', required: true });
  const name = h('input', { placeholder: 'Owner or business name', required: true, minlength: 2, maxlength: 120 });
  const type = select(PARTNER_TYPES, 'fitness_centre');
  const city = h('input', { placeholder: 'e.g. Bengaluru' });
  const email = h('input', { type: 'email', placeholder: 'optional' });
  const preview = h('div', { class: 'muted', style: 'font-size:12px;font-weight:400' });
  phone.addEventListener('input', () => {
    const p = normPhone(phone.value);
    preview.textContent = phone.value.trim() ? (p ? `Will register ${p}` : 'Enter a 10-digit Indian mobile number') : '';
  });
  const form = h('form', { class: 'card stack' },
    h('h3', {}, 'Register a new vendor'),
    h('p', { class: 'muted', style: 'margin:0' },
      'Creates the partner account for this mobile number (or opens the existing one) so you can set up everything for them. ' +
      'The owner later signs in to the FITKEY Partner app with this number + OTP — no password is shared.'),
    h('div', { class: 'vx-grid' },
      h('label', {}, 'Mobile number', phone, preview),
      field('Name', name),
      field('Partner type', type),
      field('City', city),
      field('E-mail (optional)', email)),
    h('div', { class: 'row' }, h('button', { type: 'submit' }, 'Register & open editor')),
  );
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const p = normPhone(phone.value);
    if (!p) return toast('Enter a valid 10-digit Indian mobile number', true);
    if (name.value.trim().length < 2) return toast('Enter the name', true);
    if (city.value.trim() && city.value.trim().length < 2) return toast('City is too short', true);
    const btn = form.querySelector('button[type=submit]');
    btn.disabled = true;
    try {
      const r = await api('/admin/partners', {
        method: 'POST',
        body: {
          phone: p,
          name: name.value.trim(),
          partnerType: type.value,
          city: city.value.trim() || undefined,
          email: email.value.trim() || undefined,
        },
      });
      toast(r.partner.isNew ? `${r.partner.name ?? p} registered` : `${r.partner.name ?? p} already had an account — opened it`);
      startSession(r.partner, r.actAsToken);
    } catch (err) {
      toast(err.message, true);
    } finally {
      btn.disabled = false;
    }
  });
  return form;
}

async function homeView() {
  const raw = state.q;
  // Phone-looking searches go as plain digits (last 10) so "+91 98765…" also matches.
  const q = /^[\d\s+()-]+$/.test(raw) ? raw.replace(/\D/g, '').slice(-10) : raw;
  const { partners } = await api(`/admin/partners${q ? `?q=${encodeURIComponent(q)}` : ''}`);
  const search = h('input', { placeholder: 'Search name or phone…', style: 'max-width:260px;margin:0' });
  search.value = raw;
  const go = () => { state.q = search.value.trim(); A.rerender(); };
  search.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });

  const listingChip = (p, l) => h('button', {
    class: 'ghost vx-mini', style: 'margin:0 6px 6px 0', title: 'Open in the editor',
    onclick: () => manage(p.id, { kind: l.entityType, venueId: l.entityType === 'venue' ? l.entityId : null }).catch((err) => toast(err.message, true)),
  }, `${KIND_LABELS[l.entityType] ?? l.entityType}: ${l.name ?? '(no name)'} · ${STATUS_LABELS[l.status] ?? label(l.status ?? 'draft')}`);

  return h('div', { class: 'stack' },
    registerForm(),
    h('div', { class: 'card stack' },
      h('div', { class: 'row' }, h('h3', { style: 'margin:0' }, 'Vendors'), h('span', { class: 'spacer' }), search,
        h('button', { class: 'ghost', onclick: go }, 'Search'),
        raw ? h('button', { class: 'ghost', onclick: () => { state.q = ''; A.rerender(); } }, 'Clear') : null),
      partners.length === 0 ? h('p', { class: 'muted', style: 'margin:0' }, raw ? 'No vendor matches.' : 'No vendors yet.') : h('div', { class: 'vx-scroll' }, h('table', {},
        h('tr', {}, ['Vendor', 'Type', 'Listings', 'Joined', ''].map((t) => h('th', {}, t))),
        partners.map((p) => h('tr', {},
          h('td', {}, h('strong', {}, p.name ?? '—'), h('div', { class: 'muted' }, [p.phone, p.city, p.email].filter(Boolean).join(' · ')),
            p.partnerGoLiveAt ? h('span', { class: 'pill live' }, `Live since ${when(p.partnerGoLiveAt)}`) : null),
          h('td', {}, p.partnerType ? TYPE_TEXT[p.partnerType] ?? label(p.partnerType) : '—'),
          h('td', {}, (p.listings ?? []).length ? (p.listings ?? []).map((l) => listingChip(p, l)) : h('span', { class: 'muted' }, 'Nothing listed yet')),
          h('td', {}, when(p.createdAt)),
          h('td', {}, h('div', { class: 'row', style: 'gap:6px' },
            actionButton('Manage', () => manage(p.id)),
            (p.listings ?? []).length ? h('button', { class: 'ghost', onclick: () => openInPartnerListings(p.phone) }, 'Open in Partner listings') : null)),
        )))),
    ),
  );
}

// ------------------------------------------------------------------------------------------------ editor shell

function profileSection() {
  return section('profile', 'Vendor profile', async () => {
    const p = state.session.partner;
    const name = textInput(p.name);
    const email = textInput(p.email, { type: 'email' });
    const city = textInput(p.city);
    const type = select(PARTNER_TYPES, p.partnerType ?? 'fitness_centre');
    return [
      h('div', { class: 'vx-grid' }, field('Name', name), field('E-mail', email), field('City', city), field('Partner type', type)),
      h('div', { class: 'row' }, actionButton('Save profile', async () => {
        const body = { partnerType: type.value };
        if (name.value.trim()) body.name = name.value.trim();
        if (email.value.trim()) body.email = email.value.trim();
        if (city.value.trim()) body.city = city.value.trim();
        const { user } = await asVendor('/partner/profile', { method: 'PUT', body });
        state.session.partner = { ...state.session.partner, ...user };
        toast('Profile saved');
      })),
    ];
  }, ' — name, e-mail, city, type');
}

async function editorView() {
  const p = state.session.partner;
  const kinds = Object.keys(KIND_LABELS).map((k) => h('button', {
    class: k === state.kind ? 'active' : '',
    onclick: () => { state.kind = k; state.venueId = null; A.rerender(); },
  }, KIND_LABELS[k]));
  let panel;
  try {
    panel = state.kind === 'venue' ? (state.venueId ? await venueEditor(state.venueId) : await venuesPanel()) : await listingEditor(state.kind);
  } catch (err) {
    panel = h('p', { class: 'muted' }, err.message);
  }
  return h('div', { class: 'stack' },
    h('div', { class: 'card stack', style: 'border-color:var(--lime)' },
      h('div', { class: 'row' },
        h('button', { class: 'ghost', onclick: () => { state.session = null; state.venueId = null; A.rerender(); } }, '← All vendors'),
        h('div', {}, h('strong', {}, `Acting for ${p.name ?? 'vendor'}`), h('div', { class: 'muted' },
          [p.phone, p.partnerType ? TYPE_TEXT[p.partnerType] : null, p.city].filter(Boolean).join(' · '))),
        h('span', { class: 'spacer' }),
        h('button', { class: 'ghost', onclick: () => openInPartnerListings(p.phone) }, 'Open in Partner listings')),
      h('p', { class: 'muted', style: 'margin:0;font-size:12px' },
        'Everything you save here is done on the vendor’s behalf and recorded as “listed by” you. The session is kept in this browser tab only.'),
    ),
    profileSection(),
    h('div', { class: 'row filters' }, h('span', { class: 'muted' }, 'Set up:'), kinds),
    panel,
  );
}

// ------------------------------------------------------------------------------------------------ owner-level cards

function documentsSection(entityType, entityId, listing, onChange) {
  return section(`docs-${entityType}`, 'Documents', async (refresh) => {
    const { documents } = await asVendor(`/partner/documents?entityType=${entityType}&entityId=${entityId}`);
    const need = REQUIRED_DOCS[entityType](listing);
    const has = (t) => documents.some((d) => d.docType === t && d.status !== 'rejected');
    const docType = select(DOC_TYPES[entityType].map((t) => [t, label(t)]), need.find((t) => !has(t)) ?? DOC_TYPES[entityType][0]);
    const file = h('input', { type: 'file', accept: 'image/jpeg,image/png,image/webp,application/pdf' });
    const number = h('input', { placeholder: 'optional' });
    const expires = h('input', { type: 'date' });
    return [
      h('div', { class: 'vx-note' }, 'Needed: ', need.map((t) => h('span', { class: `pill ${has(t) ? 'live' : 'pending'}`, style: 'margin-right:6px' }, `${has(t) ? '✓' : '•'} ${label(t)}`)),
        h('span', { class: 'muted' }, ' (recommended — they do not block submission)')),
      documents.length === 0 ? h('p', { class: 'muted', style: 'margin:0' }, 'No documents uploaded yet.') : h('div', { class: 'vx-scroll' }, h('table', {},
        h('tr', {}, ['Type', 'Number / expiry', 'Uploaded', 'Status', ''].map((t) => h('th', {}, t))),
        documents.map((d) => h('tr', {},
          h('td', {}, h('strong', {}, label(d.docType)), h('div', {}, h('a', { class: 'link', href: assetUrl(d.fileUrl), target: '_blank', rel: 'noopener' }, 'Open file ↗'))),
          h('td', {}, d.docNumber ?? '—', d.expiresOn ? h('div', { class: 'muted' }, `Expires ${String(d.expiresOn).slice(0, 10)}`) : null),
          h('td', {}, when(d.createdAt)),
          h('td', {}, h('span', { class: `pill ${d.status}` }, label(d.status ?? 'pending')), d.reviewNote ? h('div', { class: 'muted' }, d.reviewNote) : null),
          h('td', {}, actionButton('Delete', async () => {
            if (!confirm(`Delete this ${label(d.docType)}?`)) return;
            await asVendor(`/partner/documents/${d.id}`, { method: 'DELETE' });
            toast('Document deleted');
            await refresh();
            onChange?.();
          }, { cls: 'danger vx-mini' })),
        )))),
      h('div', { class: 'vx-grid' }, field('Document type', docType), field('File (image ≤ 3 MB or PDF ≤ 5 MB)', file),
        field('Number', number), field('Expires on', expires)),
      h('div', { class: 'row' }, actionButton('Upload document', async () => {
        const f = file.files[0];
        if (!f) throw new Error('Choose a file');
        const fileUrl = await uploadAsVendor(f, 'doc');
        await asVendor('/partner/documents', {
          method: 'POST',
          body: { entityType, entityId, docType: docType.value, fileUrl, docNumber: number.value.trim() || null, expiresOn: expires.value || null },
        });
        toast(`${label(docType.value)} uploaded`);
        await refresh();
        onChange?.();
      })),
    ];
  }, ' — licences, registrations, GST');
}

function kycBankSection(onChange) {
  return section('kycbank', 'Owner KYC & bank account', async (refresh) => {
    const [{ kyc }, { account }] = await Promise.all([asVendor('/partner/kyc'), asVendor('/partner/bank')]);
    const method = select([['offline_ekyc', 'Offline e-KYC (Aadhaar XML / card seen)'], ['digilocker', 'DigiLocker']], kyc?.method ?? 'offline_ekyc');
    const last4 = h('input', { inputmode: 'numeric', maxlength: 4, placeholder: '4 digits', autocomplete: 'off' });
    last4.addEventListener('input', () => { last4.value = last4.value.replace(/\D/g, '').slice(0, 4); });
    const nameOnId = textInput(kyc?.nameOnId ?? state.session.partner.name);
    const holder = textInput(account?.holderName ?? '');
    const acc = h('input', { inputmode: 'numeric', autocomplete: 'off', placeholder: '9–18 digits' });
    const acc2 = h('input', { inputmode: 'numeric', autocomplete: 'off', placeholder: 'type it again' });
    const ifsc = textInput(account?.ifsc ?? '', { placeholder: 'HDFC0001234', style: 'text-transform:uppercase' });
    return [
      h('div', { class: 'grid', style: 'grid-template-columns:repeat(auto-fit,minmax(280px,1fr))' },
        h('div', { class: 'stack' },
          h('h3', {}, 'KYC (Aadhaar)'),
          kyc ? h('div', { class: 'vx-note' }, `${label(kyc.method ?? '')} · ${kyc.aadhaarMasked ?? ''} · ${kyc.nameOnId ?? ''} `,
            h('span', { class: `pill ${kyc.status}` }, label(kyc.status ?? 'pending'))) : h('p', { class: 'muted', style: 'margin:0' }, 'Not done yet.'),
          h('p', { class: 'muted', style: 'margin:0;font-size:12px' }, 'Only the LAST 4 digits of the Aadhaar are taken. Never type or store the full 12-digit number.'),
          field('Method', method), field('Aadhaar — last 4 digits only', last4), field('Name on the ID', nameOnId),
          h('div', { class: 'row' }, actionButton(kyc ? 'Update KYC' : 'Save KYC', async () => {
            if (!/^\d{4}$/.test(last4.value)) throw new Error('Enter exactly the last 4 digits of the Aadhaar');
            if (nameOnId.value.trim().length < 2) throw new Error('Enter the name as on the ID');
            await asVendor('/partner/kyc', { method: 'POST', body: { method: method.value, aadhaarLast4: last4.value, nameOnId: nameOnId.value.trim() } });
            toast('KYC saved');
            await refresh();
            onChange?.();
          }))),
        h('div', { class: 'stack' },
          h('h3', {}, 'Bank account for payouts'),
          account ? h('div', { class: 'vx-note' }, `•••• ${account.last4} · ${[account.ifsc, account.bankName].filter(Boolean).join(' · ')} · ${account.holderName ?? ''} `,
            h('span', { class: `pill ${account.status === 'failed' ? 'rejected' : account.status}` }, label(account.status ?? 'pending'))) : h('p', { class: 'muted', style: 'margin:0' }, 'No bank account yet.'),
          field('Account holder name', holder), field('Account number', acc), field('Confirm account number', acc2), field('IFSC', ifsc),
          h('div', { class: 'row' }, actionButton(account ? 'Replace bank account' : 'Save bank account', async () => {
            const a = acc.value.replace(/[\s-]/g, '');
            const code = ifsc.value.replace(/\s/g, '').toUpperCase();
            if (holder.value.trim().length < 2) throw new Error('Enter the account holder name');
            if (!/^\d{9,18}$/.test(a)) throw new Error('Account number must be 9–18 digits');
            if (a !== acc2.value.replace(/[\s-]/g, '')) throw new Error('The two account numbers do not match');
            if (!/^[A-Z]{4}0[A-Z0-9]{6}$/.test(code)) throw new Error('Enter a valid IFSC (e.g. HDFC0001234)');
            await asVendor('/partner/bank', { method: 'POST', body: { holderName: holder.value.trim(), accountNumber: a, ifsc: code } });
            toast('Bank account saved');
            await refresh();
            onChange?.();
          })))),
    ];
  }, ' — shared by all of this vendor’s listings');
}

/** "Owner agreement" — OTP to the owner's phone, admin types what the owner reads out. */
function agreementBox(entityType, entityId, listing) {
  const phone = state.session.partner.phone;
  if (listing?.partnerAcceptedAt) {
    return h('div', { class: 'card stack' }, h('h3', {}, 'Owner agreement'),
      h('p', { style: 'margin:0' }, h('span', { class: 'pill live' }, 'Accepted'), ` by the owner on ${when(listing.partnerAcceptedAt)}.`));
  }
  const otp = h('input', { inputmode: 'numeric', maxlength: 6, placeholder: '6-digit OTP', style: 'max-width:160px;margin:0' });
  const info = h('div', { class: 'muted' });
  return h('div', { class: 'card stack' },
    h('h3', {}, 'Owner agreement'),
    h('p', { class: 'muted', style: 'margin:0' }, 'The listing goes live only after BOTH FitKey approval and the owner’s OTP acceptance (either order). Read this to the owner:'),
    h('div', { class: 'vx-note stack' },
      h('div', {}, h('strong', {}, 'Commission: '), '0% in year 1 · 2.5% in year 2 · 5% from year 3 (counted from go-live).'),
      h('div', {}, COMMISSION_TEXT),
      h('div', {}, h('strong', {}, 'Payouts: '), 'monthly fee ÷ 30 per FitKey pass check-in, minus that year’s commission. GST on own-plan sales = price × 5/105.'),
      h('div', { class: 'muted' }, PAYOUT_RULE)),
    h('div', { class: 'vx-inline' },
      actionButton('Send OTP to owner', async () => {
        const r = await asVendor('/partner/agreement/otp', { method: 'POST', body: { entityType, entityId } });
        info.textContent = `OTP sent to ${phone}${r.expiresInSeconds ? ` · valid ${Math.round(r.expiresInSeconds / 60)} min` : ''}${r.devOtp ? ` · Dev OTP: ${r.devOtp}` : ''}. Ask the owner to read it out.`;
        toast('OTP sent to the owner');
        otp.focus();
      }, { cls: 'ghost' }),
      otp,
      actionButton('Accept for owner', async () => {
        if (!/^\d{6}$/.test(otp.value.trim())) throw new Error('Type the 6-digit OTP the owner reads out');
        const r = await asVendor('/partner/agreement/accept', { method: 'POST', body: { entityType, entityId, otp: otp.value.trim() } });
        toast(r.listing?.status === 'live' ? 'Agreement accepted — listing is LIVE' : 'Agreement accepted — goes live once FitKey approves');
        A.rerender();
      })),
    info,
    h('p', { class: 'muted', style: 'margin:0;font-size:12px' }, 'Or the owner accepts it themselves on first login to the FITKEY Partner app.'),
  );
}

/** Submit / submit & approve / approve, with the 400 `missing` list shown inline. */
function submitBox(entityType, entityId, status, submitPath) {
  const out = h('div');
  const approve = async () => {
    await api(`/admin/listings/${entityType}/${entityId}/review`, { method: 'POST', body: { action: 'approve' } });
  };
  const submit = async () => {
    try {
      await asVendor(submitPath, { method: 'POST' });
    } catch (err) {
      const missing = err?.data?.missing;
      if (Array.isArray(missing) && missing.length) {
        out.replaceChildren(h('div', { class: 'vx-note stack', style: 'border:1px solid var(--danger)' },
          h('strong', { class: 'vx-req' }, err.message),
          h('ul', { style: 'margin:0;padding-left:18px' }, missing.map((m) => h('li', {}, `Step ${m.step} · ${m.label}${m.hint ? ` — ${m.hint}` : ''}`)))));
        err.data = null; // already shown
      }
      throw err;
    }
  };
  const can = SUBMITTABLE.includes(status);
  return h('div', { class: 'card stack' },
    h('div', { class: 'row' }, h('h3', { style: 'margin:0' }, 'Review & submit'), statusPill(status)),
    h('div', { class: 'row' },
      can ? actionButton('Submit for review', async () => { await submit(); toast('Submitted for review'); A.rerender(); }) : null,
      can ? actionButton('Submit & approve', async () => {
        if (!confirm('Submit this listing and approve it right away as FitKey admin?')) return;
        await submit();
        try {
          await approve();
        } catch (err) {
          toast(`Submitted, but approval failed: ${err.message}`, true);
          A.rerender();
          return;
        }
        toast('Submitted and approved');
        A.rerender();
      }, { cls: 'ghost' }) : null,
      ['submitted', 'under_review', 'changes_needed'].includes(status) && !can ? actionButton('Approve now', async () => {
        if (!confirm('Approve this listing as FitKey admin?')) return;
        await approve();
        toast('Approved');
        A.rerender();
      }) : null,
      h('button', { class: 'ghost', onclick: () => openInPartnerListings(state.session.partner.phone) }, 'Open in Partner listings (review, request changes, reject)'),
    ),
    status === 'approved' ? h('p', { class: 'muted', style: 'margin:0' }, 'Approved — waiting for the owner’s OTP acceptance (below), then it goes live.') : null,
    status === 'live' ? h('p', { class: 'muted', style: 'margin:0' }, 'This listing is live. You can still edit it here.') : null,
    out,
  );
}

// ------------------------------------------------------------------------------------------------ centres (venues)

async function venuesPanel() {
  const { venues } = await asVendor('/partner/venues');
  const name = h('input', { placeholder: 'Centre name', maxlength: 160 });
  const sportsWrap = h('div', { hidden: true });
  const sports = checkGroup(SPORTS, []);
  sportsWrap.append(h('div', { class: 'muted' }, 'Sports offered'), sports.el);
  const cats = checkGroup(CATEGORIES, state.session.partner.partnerType === 'sports_centre' ? ['sports_club'] : [], {
    onchange: () => { sportsWrap.hidden = !cats.values().includes('sports_club'); },
  });
  sportsWrap.hidden = !cats.values().includes('sports_club');
  return h('div', { class: 'stack' },
    h('div', { class: 'card stack' },
      h('h3', {}, 'Centres'),
      venues.length === 0 ? h('p', { class: 'muted', style: 'margin:0' }, 'No centre yet — create one below.') : h('div', { class: 'vx-scroll' }, h('table', {},
        h('tr', {}, ['Centre', 'Categories', 'Status', 'Updated', ''].map((t) => h('th', {}, t))),
        venues.map((v) => h('tr', {},
          h('td', {}, h('strong', {}, v.name), h('div', { class: 'muted' }, [v.area, v.city].filter(Boolean).join(' · '))),
          h('td', {}, (v.categories ?? []).map(label).join(', '), (v.sports ?? []).length ? h('div', { class: 'muted' }, v.sports.map(label).join(', ')) : null),
          h('td', {}, statusPill(v.status), v.reviewNote ? h('div', { class: 'muted' }, v.reviewNote) : null),
          h('td', {}, when(v.updatedAt)),
          h('td', {}, h('button', { onclick: () => { state.venueId = v.id; state.open = new Set(['checklist']); A.rerender(); } }, 'Edit')),
        )))),
    ),
    h('div', { class: 'card stack' },
      h('h3', {}, 'Create a centre'),
      field('Name', name),
      h('div', {}, h('div', { class: 'muted' }, 'Categories'), cats.el),
      sportsWrap,
      h('div', { class: 'row' }, actionButton('Create & edit', async () => {
        if (name.value.trim().length < 2) throw new Error('Enter the centre name');
        const c = cats.values();
        if (!c.length) throw new Error('Pick at least one category');
        const body = { name: name.value.trim(), categories: c };
        if (c.includes('sports_club')) body.sports = sports.values();
        const city = state.session.partner.city;
        if (city && city.length >= 2) body.city = city;
        const { venue } = await asVendor('/partner/venues', { method: 'POST', body });
        toast('Centre created');
        state.venueId = venue.id;
        state.open = new Set(['v-details']);
        A.rerender();
      })),
    ),
  );
}

async function venueEditor(venueId) {
  let v = (await asVendor(`/partner/venues/${venueId}`)).venue;
  const head = h('div', { class: 'row' });
  const checklistBox = h('div');
  const renderTop = () => {
    head.replaceChildren(
      h('button', { class: 'ghost', onclick: () => { state.venueId = null; A.rerender(); } }, '← All centres'),
      h('h2', { style: 'margin:0' }, v.name), statusPill(v.status),
      v.listedByName ? h('span', { class: 'muted' }, `Listed by ${v.listedByName}`) : null);
    checklistBox.replaceChildren(checklistView(v.checklist, VENUE_STEPS));
  };
  renderTop();
  const save = async (body, step, ok = 'Saved') => {
    const r = await asVendor(`/partner/venues/${v.id}`, { method: 'PUT', body: { ...body, listingStep: step } });
    v = r.venue;
    renderTop();
    toast(ok);
  };
  const reload = async () => {
    v = (await asVendor(`/partner/venues/${v.id}`)).venue;
    renderTop();
  };
  const saveRow = (text, fn) => h('div', { class: 'row' }, actionButton(text, fn));

  const sections = [
    section('v-cat', '1 · Category & sports', () => {
      const sportsWrap = h('div');
      const sports = checkGroup(SPORTS, v.sports ?? []);
      const cats = checkGroup(CATEGORIES, v.categories ?? [], { onchange: () => { sportsWrap.hidden = !cats.values().includes('sports_club'); } });
      sportsWrap.append(h('div', { class: 'muted' }, 'Sports (needed for a sports club)'), sports.el);
      sportsWrap.hidden = !cats.values().includes('sports_club');
      return [h('div', {}, h('div', { class: 'muted' }, 'Categories'), cats.el), sportsWrap,
        saveRow('Save categories', async () => {
          const c = cats.values();
          if (!c.length) throw new Error('Pick at least one category');
          const s = c.includes('sports_club') ? sports.values() : [];
          if (c.includes('sports_club') && !s.length) throw new Error('Pick the sports offered');
          await save({ categories: c, sports: s }, 1, 'Categories saved');
        })];
    }),
    section('v-details', '2 · Details', () => {
      const name = textInput(v.name);
      const desc = textArea(v.description, { rows: 4, placeholder: 'What members get — equipment, classes, vibe… (at least 40 characters)' });
      const counter = h('div', { class: 'muted', style: 'font-size:12px;font-weight:400' });
      const sync = () => { const n = desc.value.trim().length; counter.textContent = `${n} characters${n && n < 40 ? ' — needs at least 40' : ''}`; };
      desc.addEventListener('input', sync);
      sync();
      const phone = textInput(v.contactPhone, { placeholder: 'Front desk mobile' });
      const email = textInput(v.contactEmail, { type: 'email' });
      return [field('Centre name', name), h('label', {}, 'Description', desc, counter),
        h('div', { class: 'vx-grid' }, field('Contact phone', phone), field('Contact e-mail', email)),
        saveRow('Save details', async () => {
          const d = desc.value.trim();
          if (name.value.trim().length < 2) throw new Error('Enter the centre name');
          if (d && d.length < 40) throw new Error('Description needs at least 40 characters (or leave it empty)');
          let cp = null;
          if (phone.value.trim()) {
            cp = normPhone(phone.value) ?? (/^\+\d{10,15}$/.test(phone.value.replace(/[\s-]/g, '')) ? phone.value.replace(/[\s-]/g, '') : null);
            if (!cp) throw new Error('Enter a valid contact phone');
          }
          await save({ name: name.value.trim(), description: d, contactPhone: cp, contactEmail: email.value.trim() || null }, 2, 'Details saved');
        })];
    }),
    section('v-loc', '3 · Location', () => {
      const loc = locationFields(v);
      return [loc.el, saveRow('Save location', async () => {
        const l = loc.read();
        const body = { area: l.area, latitude: l.latitude, longitude: l.longitude };
        if (l.address) {
          if (l.address.length < 5) throw new Error('Address is too short');
          body.address = l.address;
        }
        if (l.city) {
          if (l.city.length < 2) throw new Error('City is too short');
          body.city = l.city;
        }
        await save(body, 3, 'Location saved');
      })];
    }),
    section('v-time', '4 · Timings & FitKey access', () => {
      const hours = hoursEditor(v.hours, { withKind: true });
      const mode = select([['all', 'FitKey pass valid at all open hours'], ['blocked', 'FitKey pass NOT valid at some times']], v.fitkeyPassMode ?? 'all');
      const blocks = (v.passBlocks ?? []).map((b) => ({ id: b.id, days: b.days ?? [...WEEKDAYS], startsAt: hhmm(b.startsAt), endsAt: hhmm(b.endsAt), note: b.note ?? '' }));
      const blocksWrap = h('div', { class: 'stack' }, h('div', { class: 'muted' }, 'Times when the FitKey pass is not valid (e.g. 6–8 PM Mon–Fri). Own-plan members are not affected.'),
        repeater(blocks, (b, remove) => h('div', { class: 'vx-note stack' },
          dayChecks(b, 'days'),
          h('div', { class: 'vx-inline' }, bound(b, 'startsAt', { type: 'time' }), '–', bound(b, 'endsAt', { type: 'time' }),
            bound(b, 'note', { placeholder: 'note (optional)', maxlength: 120 }),
            h('button', { type: 'button', class: 'ghost vx-mini', onclick: remove }, 'Remove'))),
        () => ({ days: WEEKDAYS.slice(0, 5), startsAt: '18:00', endsAt: '20:00', note: '' }), '+ Add blocked time'));
      const syncMode = () => { blocksWrap.hidden = mode.value !== 'blocked'; };
      mode.addEventListener('change', syncMode);
      syncMode();
      const closures = (v.closures ?? []).map((c) => ({ id: c.id, closedOn: String(c.closedOn ?? '').slice(0, 10), slotStart: hhmm(c.slotStart), slotEnd: hhmm(c.slotEnd), note: c.note ?? '' }));
      return [
        h('h3', {}, 'Opening hours'), hours.el,
        h('h3', {}, 'FitKey pass access'), field('Mode', mode), blocksWrap,
        h('h3', {}, 'Holidays & closures'),
        h('p', { class: 'muted', style: 'margin:0' }, 'Upcoming closed days. Leave the times empty for a full-day closure.'),
        repeater(closures, (c, remove) => h('div', { class: 'vx-inline' },
          bound(c, 'closedOn', { type: 'date' }), bound(c, 'slotStart', { type: 'time' }), '–', bound(c, 'slotEnd', { type: 'time' }),
          bound(c, 'note', { placeholder: 'e.g. Diwali', maxlength: 160 }),
          h('button', { type: 'button', class: 'ghost vx-mini', onclick: remove }, 'Remove')),
        () => ({ closedOn: '', slotStart: '', slotEnd: '', note: '' }), '+ Add closure'),
        saveRow('Save timings', async () => {
          const hrs = hours.read();
          const pb = mode.value === 'blocked' ? blocks.map((b) => {
            if (!b.days?.length) throw new Error('Each blocked time needs at least one day');
            if (!b.startsAt || !b.endsAt || b.endsAt <= b.startsAt) throw new Error('Blocked time: end must be after start');
            return { ...(b.id ? { id: b.id } : {}), days: b.days, startsAt: b.startsAt, endsAt: b.endsAt, note: b.note?.trim() || null };
          }) : [];
          if (mode.value === 'blocked' && !pb.length) throw new Error('Add at least one blocked time, or choose “valid at all open hours”');
          const cl = closures.filter((c) => c.closedOn).map((c) => {
            if (Boolean(c.slotStart) !== Boolean(c.slotEnd) || (c.slotStart && c.slotEnd <= c.slotStart)) throw new Error(`Closure ${c.closedOn}: give both times (end after start) or neither`);
            return { ...(c.id ? { id: c.id } : {}), closedOn: c.closedOn, slotStart: c.slotStart || null, slotEnd: c.slotEnd || null, note: c.note?.trim() || null };
          });
          const body = { hours: hrs, fitkeyPassMode: mode.value, closures: cl };
          if (mode.value === 'blocked') body.passBlocks = pb;
          await save(body, 4, 'Timings saved');
        }),
      ];
    }),
    section('v-photos', '5 · Photos & video', () => {
      const pm = photoManager(v.photos, 10);
      const video = textInput(v.videoUrl ? assetUrl(v.videoUrl) : '', { placeholder: 'https://youtube.com/… or upload an MP4' });
      const vpick = h('input', { type: 'file', accept: 'video/mp4' });
      vpick.addEventListener('change', async () => {
        const f = vpick.files[0];
        vpick.value = '';
        if (!f) return;
        try {
          video.value = location.origin + (await uploadAsVendor(f, 'video')); // venue videoUrl must be an absolute URL
          toast('Video uploaded — remember to save');
        } catch (err) {
          toast(err.message, true);
        }
      });
      return [h('p', { class: 'muted', style: 'margin:0' }, 'At least 1 photo is required, 4+ recommended, up to 10.'), pm.el,
        field('Video tour (optional)', video), h('label', {}, 'Upload MP4 (≤ 12 MB)', vpick),
        saveRow('Save photos & video', async () => {
          const u = video.value.trim();
          if (u && !/^https?:\/\/\S+$/.test(u)) throw new Error('Video link must start with https://');
          await save({ photos: pm.get(), videoUrl: u || null }, 5, 'Photos saved');
        })];
    }),
    section('v-fac', '6 · Facilities', () => {
      const trainer = checkbox(v.trainerAvailable);
      const am = checkGroup(AMENITIES, v.amenities ?? []);
      const eq = textArea((v.equipment ?? []).join('\n'), { rows: 4, placeholder: 'One per line — e.g. Treadmill' });
      return [h('label', { class: 'row' }, trainer, 'Trainer available'),
        h('div', {}, h('div', { class: 'muted' }, 'Amenities'), am.el),
        field('Equipment (one per line)', eq),
        saveRow('Save facilities', async () => save({ trainerAvailable: trainer.checked, amenities: am.values(), equipment: lines(eq.value).slice(0, 100) }, 6, 'Facilities saved'))];
    }),
    section('v-price', '7 · Pricing & FitKey pass', async (refresh) => plansAndFee(v, save, reload, refresh)),
    section('v-slots', '8 · Slots & capacity', () => {
      const sm = textInput(v.slotMinutes ?? 60, { type: 'number', min: 15, max: 480 });
      const cap = textInput(v.slotCapacity ?? 20, { type: 'number', min: 1, max: 1000 });
      const pcap = textInput(v.passSlotCap ?? '', { type: 'number', min: 0, max: 1000, placeholder: 'same as capacity' });
      const courts = textInput(v.courts ?? 1, { type: 'number', min: 1, max: 100 });
      const auto = checkbox(v.autoAcceptBookings ?? true);
      return [h('div', { class: 'vx-grid' },
        field('Slot length (minutes)', sm), field('Members per slot', cap, 'Per court for sports'),
        field('Max FitKey pass members per slot', pcap, 'Empty = no separate cap'), field('Courts / lanes', courts)),
      h('label', { class: 'row' }, auto, 'Auto-accept bookings (off = owner accepts each request)'),
      saveRow('Save slots', async () => {
        const body = {
          slotMinutes: Number(sm.value), slotCapacity: Number(cap.value), passSlotCap: numOrNull(pcap.value),
          courts: Number(courts.value || 1), autoAcceptBookings: auto.checked,
        };
        if (!(body.slotMinutes >= 15 && body.slotMinutes <= 480)) throw new Error('Slot length must be 15–480 minutes');
        if (!(body.slotCapacity >= 1)) throw new Error('Members per slot must be at least 1');
        await save(body, 8, 'Slots saved');
      })];
    }),
    documentsSection('venue', v.id, v, reload),
    kycBankSection(reload),
  ];

  return h('div', { class: 'stack' },
    head,
    h('div', { class: 'card stack' }, checklistBox,
      h('p', { class: 'muted', style: 'margin:0;font-size:12px' }, 'Only “Required” items block submission; the rest are recommended.')),
    h('div', {}, sections),
    submitBox('venue', v.id, v.status, `/partner/venues/${v.id}/submit`),
    agreementBox('venue', v.id, v),
  );
}

/** Step 7: centre plans (memberships partner endpoints) + monthly fee + FitKey pass consent. */
async function plansAndFee(v, save, reload, refresh) {
  const { plans } = await asVendor(`/memberships/partner/venues/${v.id}/plans`);
  let editing = null;
  const name = h('input', { maxlength: 120, placeholder: 'e.g. Monthly unlimited' });
  const duration = select(DURATIONS, 'monthly');
  const price = h('input', { type: 'number', min: 1, step: '1', placeholder: '₹ incl. GST' });
  const offer = h('input', { type: 'number', min: 0, max: 90, value: 0 });
  const desc = h('input', { maxlength: 1000 });
  const incl = h('input', { placeholder: 'comma separated — e.g. Locker, Steam' });
  const perDay = h('input', { type: 'number', min: 1, max: 10, placeholder: 'unlimited' });
  const perWeek = h('input', { type: 'number', min: 1, max: 70, placeholder: 'unlimited' });
  const active = checkbox(true);
  const formTitle = h('h3', {}, 'Add a plan');
  const syncDur = () => { const hr = duration.value === 'hourly'; perDay.disabled = hr; perWeek.disabled = hr; };
  duration.addEventListener('change', syncDur);
  const resetForm = () => {
    editing = null;
    formTitle.textContent = 'Add a plan';
    [name, price, desc, incl, perDay, perWeek].forEach((x) => { x.value = ''; });
    offer.value = 0;
    duration.value = 'monthly';
    active.checked = true;
    syncDur();
  };
  const edit = (p) => {
    editing = p;
    formTitle.textContent = `Edit “${p.name}” (goes back to FitKey approval)`;
    name.value = p.name;
    duration.value = p.duration === 'annual' ? 'yearly' : p.duration;
    price.value = p.pricePaise / 100;
    offer.value = p.offerPct ?? 0;
    desc.value = p.description ?? '';
    incl.value = (p.inclusions ?? []).join(', ');
    perDay.value = p.maxVisitsPerDay ?? '';
    perWeek.value = p.maxVisitsPerWeek ?? '';
    active.checked = p.isActive;
    syncDur();
    formTitle.scrollIntoView({ behavior: 'smooth', block: 'center' });
  };
  const after = async (msg) => { toast(msg); await reload(); await refresh(); };

  // Monthly fee + consent
  const fee = textInput(toRupees(v.monthlyFeePaise), { type: 'number', min: 1, step: '1', placeholder: '₹ per month' });
  const consent = checkbox(v.passAccepted);
  const preview = h('div', { class: 'vx-note' });
  const syncFee = () => {
    const p = toPaise(fee.value);
    if (!p) { preview.textContent = 'Enter the monthly fee to see the FitKey pass payout per check-in.'; return; }
    const perVisit = p / 30;
    preview.replaceChildren(h('strong', {}, `${inr(perVisit)} per FitKey pass check-in in Year 1`), ` (= ${inr(p)} ÷ 30, 0% commission)`,
      h('div', { class: 'muted' }, `Year 2: ${inr(perVisit * 0.975)} (2.5%) · Year 3+: ${inr(perVisit * 0.95)} (5%). FitKey bears the GST on pass visits.`));
  };
  fee.addEventListener('input', syncFee);
  syncFee();

  return [
    h('h3', {}, 'Centre plans (sold on FitKey)'),
    h('p', { class: 'muted', style: 'margin:0' }, `${GST_NOTE} New / edited plans wait for FitKey approval (Memberships tab).`),
    plans.length === 0 ? h('p', { class: 'muted', style: 'margin:0' }, 'No plans yet — at least one is recommended.') : h('div', { class: 'vx-scroll' }, h('table', {},
      h('tr', {}, ['Plan', 'Duration', 'Price', 'Limits', 'Includes', 'Approval', ''].map((t) => h('th', {}, t))),
      plans.map((p) => h('tr', {},
        h('td', {}, h('strong', {}, p.name), p.description ? h('div', { class: 'muted' }, p.description) : null,
          p.isActive ? null : h('span', { class: 'pill rejected' }, 'Off')),
        h('td', {}, DURATION_TEXT[p.duration] ?? label(p.duration)),
        h('td', {}, inr(p.effectivePricePaise ?? p.pricePaise), p.offerPct ? h('div', { class: 'muted' }, `${p.offerPct}% off ${inr(p.pricePaise)}`) : null),
        h('td', {}, [p.maxVisitsPerDay ? `${p.maxVisitsPerDay}/day` : null, p.maxVisitsPerWeek ? `${p.maxVisitsPerWeek}/week` : null].filter(Boolean).join(' · ') || 'Unlimited'),
        h('td', {}, (p.inclusions ?? []).join(', ') || '—'),
        h('td', {}, h('span', { class: `pill ${p.approvalStatus === 'approved' ? 'live' : p.approvalStatus}` }, label(p.approvalStatus ?? 'pending')),
          p.reviewNote ? h('div', { class: 'muted' }, p.reviewNote) : null),
        h('td', {}, h('div', { class: 'row', style: 'gap:6px' },
          h('button', { class: 'ghost vx-mini', onclick: () => edit(p) }, 'Edit'),
          actionButton(p.isActive ? 'Switch off' : 'Switch on', async () => {
            await asVendor(`/memberships/partner/plans/${p.id}/active`, { method: 'PATCH', body: { isActive: !p.isActive } });
            await after(p.isActive ? 'Plan switched off' : 'Plan switched on');
          }, { cls: 'ghost vx-mini' }),
          actionButton('Delete', async () => {
            if (!confirm(`Remove “${p.name}” from sale? Members keep what they bought.`)) return;
            await asVendor(`/memberships/partner/plans/${p.id}`, { method: 'DELETE' });
            await after('Plan removed');
          }, { cls: 'danger vx-mini' }))),
      )))),
    h('div', { class: 'vx-note stack' },
      formTitle,
      h('div', { class: 'vx-grid' }, field('Plan name', name), field('Duration', duration), field('Price (₹, incl. GST)', price),
        field('Offer % off', offer), field('Max visits / day', perDay), field('Max visits / week', perWeek)),
      field('Description', desc), field('What’s included', incl),
      h('label', { class: 'row' }, active, 'On sale'),
      h('div', { class: 'row' },
        actionButton('Save plan', async () => {
          const pricePaise = toPaise(price.value);
          if (name.value.trim().length < 2) throw new Error('Enter the plan name');
          if (!pricePaise || pricePaise < 100) throw new Error('Enter a price of at least ₹1');
          const hr = duration.value === 'hourly';
          const body = {
            name: name.value.trim(), description: desc.value.trim() || null, duration: duration.value, pricePaise,
            inclusions: csvList(incl.value).slice(0, 20), offerPct: Number(offer.value || 0), isActive: active.checked,
            maxVisitsPerDay: hr ? null : numOrNull(perDay.value), maxVisitsPerWeek: hr ? null : numOrNull(perWeek.value),
          };
          if (editing) await asVendor(`/memberships/partner/plans/${editing.id}`, { method: 'PUT', body });
          else await asVendor(`/memberships/partner/venues/${v.id}/plans`, { method: 'POST', body });
          resetForm();
          await after(editing ? 'Plan updated' : 'Plan added');
        }),
        h('button', { type: 'button', class: 'ghost', onclick: resetForm }, 'Clear'))),
    h('h3', {}, 'FitKey pass'),
    field('Monthly fee a regular member pays (₹)', fee, 'FitKey pays this ÷ 30 for every FitKey pass check-in'),
    preview,
    h('label', { class: 'row', style: 'font-weight:500;align-items:flex-start;flex-wrap:nowrap' }, consent, h('span', {}, PASS_CONSENT_TEXT)),
    h('p', { class: 'muted', style: 'margin:0;font-size:12px' }, 'Tick only after reading this consent to the owner and getting their OK.'),
    h('div', { class: 'row' }, actionButton('Save fee & consent', async () => {
      const p = toPaise(fee.value);
      if (fee.value !== '' && !(p > 0)) throw new Error('Enter a valid monthly fee');
      await save({ monthlyFeePaise: p, passAccepted: consent.checked }, 7, 'FitKey pass settings saved');
    })),
  ];
}

// ------------------------------------------------------------------------------------------------ trainer / clinic / chemist / store

async function listingEditor(kind) {
  let pl = await asVendor(`/partner/listing/${kind}`);
  const options = { ...FALLBACK_OPTIONS, ...(await asVendor('/partner/listing/meta/options').catch(() => ({}))) };
  const created = Boolean(pl.listing);
  const head = h('div', { class: 'row' });
  const checklistBox = h('div');
  const renderTop = () => {
    const l = pl.listing;
    head.replaceChildren(h('h2', { style: 'margin:0' }, l?.name ?? l?.brandName ?? l?.businessName ?? `New ${KIND_LABELS[kind].toLowerCase()} listing`),
      statusPill(l?.status), l?.verifiedBadge ? h('span', { class: 'pill live' }, 'Verified badge') : null);
    checklistBox.replaceChildren(checklistView(pl.checklist, OTHER_STEPS),
      (pl.goLiveBlockers ?? []).length ? h('div', { class: 'vx-note vx-req' }, `Cannot go live yet: ${pl.goLiveBlockers.map((b) => b.label).join('; ')}`) : null);
  };
  renderTop();
  const L = () => pl.listing ?? {};
  const save = async (body, ok = 'Saved') => {
    pl = await asVendor(`/partner/listing/${kind}`, { method: 'PUT', body });
    renderTop();
    toast(ok);
    if (!created) A.rerender(); // first save created the listing — show documents / submit sections
  };
  const reload = async () => { pl = await asVendor(`/partner/listing/${kind}`); renderTop(); };
  const saveRow = (text, fn) => h('div', { class: 'row' }, actionButton(text, fn));
  const s = [];

  if (kind === 'trainer') {
    s.push(section('t-profile', '1 · Profile', () => {
      const l = L();
      const name = textInput(l.name ?? state.session.partner.name);
      const photo = singleImage('Profile photo', l.photoUrl);
      const bio = textArea(l.bio, { rows: 4 });
      const subtypes = checkGroup(options.trainerSubtypes, l.subtypes ?? []);
      const exp = textInput(l.experienceYears ?? '', { type: 'number', min: 0, max: 60 });
      const ach = textArea((l.achievements ?? []).join('\n'), { rows: 3, placeholder: 'One per line' });
      const langs = textInput((l.languages ?? []).join(', '), { placeholder: 'Hindi, English' });
      const modes = checkGroup(['online', 'home', 'gym'], l.trainingModes ?? [], { labeler: (m) => ({ online: 'Online', home: 'At member’s home', gym: 'At gym' }[m]) });
      const area = textInput(l.serviceArea, { placeholder: 'e.g. Koramangala, HSR (for home / gym)' });
      const certs = textArea((l.certifications ?? []).join('\n'), { rows: 3, placeholder: 'One per line — upload the certificates under Documents' });
      const specs = textInput((l.specializations ?? []).join(', '), { placeholder: 'Weight loss, strength…' });
      return [h('div', { class: 'vx-grid' }, field('Name', name), field('Experience (years)', exp), field('Languages', langs), field('Service area', area)),
        photo.el, field('About / bio', bio),
        h('div', {}, h('div', { class: 'muted' }, 'What they train'), subtypes.el),
        h('div', {}, h('div', { class: 'muted' }, 'Training modes'), modes.el),
        field('Achievements', ach), field('Certifications', certs), field('Specialisations', specs),
        saveRow('Save profile', async () => {
          if (name.value.trim().length < 2) throw new Error('Enter the name');
          await save({
            name: name.value.trim(), photoUrl: photo.get(), bio: bio.value.trim(), subtypes: subtypes.values(),
            experienceYears: numOrNull(exp.value), achievements: lines(ach.value).slice(0, 20), languages: csvList(langs.value).slice(0, 12),
            trainingModes: modes.values(), serviceArea: area.value.trim() || null, certifications: lines(certs.value).slice(0, 20),
            specializations: csvList(specs.value).slice(0, 20), listingStep: 1,
          }, 'Profile saved');
        })];
    }));
    s.push(section('t-price', '2 · Pricing', () => {
      const l = L();
      const rate = textInput(toRupees(l.hourlyRatePaise), { type: 'number', min: 100, placeholder: '₹ per hour / session' });
      const packs = (l.packages ?? []).map((p) => ({ name: p.name, sessions: p.sessions, price: toRupees(p.pricePaise) }));
      return [field('Hourly / per-session rate (₹, min 100)', rate),
        h('div', { class: 'muted' }, 'Packages (optional)'),
        repeater(packs, (p, remove) => h('div', { class: 'vx-inline' },
          bound(p, 'name', { placeholder: 'e.g. 12 sessions' }), bound(p, 'sessions', { type: 'number', min: 1, placeholder: 'sessions' }),
          bound(p, 'price', { type: 'number', min: 0, placeholder: '₹ total' }),
          h('button', { type: 'button', class: 'ghost vx-mini', onclick: remove }, 'Remove')),
        () => ({ name: '', sessions: '', price: '' }), '+ Add package'),
        saveRow('Save pricing', async () => {
          const r = toPaise(rate.value);
          if (r != null && r < 10000) throw new Error('Rate must be at least ₹100');
          const packages = packs.filter((p) => p.name || p.sessions || p.price).map((p) => {
            if (!String(p.name).trim() || !(Number(p.sessions) >= 1) || p.price === '') throw new Error('Each package needs a name, sessions and a price');
            return { name: String(p.name).trim(), sessions: Number(p.sessions), pricePaise: toPaise(p.price) };
          });
          await save({ hourlyRatePaise: r, packages, listingStep: 2 }, 'Pricing saved');
        })];
    }));
    s.push(section('t-avail', '3 · Availability', () => {
      const l = L();
      const slots = hoursEditor(l.weeklySlots, { start: 'start', end: 'end', defFrom: '06:00', defTo: '10:00' });
      const max = textInput(l.maxSessionsPerDay ?? '', { type: 'number', min: 1, max: 24 });
      const buffer = textInput(l.bufferMinutes ?? '', { type: 'number', min: 0, max: 120, placeholder: '0' });
      return [h('div', { class: 'muted' }, 'Weekly time windows when members can book'), slots.el,
        h('div', { class: 'vx-grid' }, field('Max sessions per day', max), field('Buffer between sessions (min)', buffer)),
        saveRow('Save availability', async () => {
          const body = { weeklySlots: slots.read(), maxSessionsPerDay: numOrNull(max.value), listingStep: 3 };
          if (buffer.value !== '') body.bufferMinutes = Number(buffer.value);
          await save(body, 'Availability saved');
        })];
    }));
  }

  if (kind === 'clinic') {
    s.push(section('c-profile', '1 · Profile', () => {
      const l = L();
      const name = textInput(l.name ?? state.session.partner.name);
      const spec = textInput(l.speciality, { placeholder: 'e.g. Physiotherapy, Orthopaedics' });
      const phone = textInput(l.phone ?? state.session.partner.phone);
      const loc = locationFields({ ...l, city: l.city || state.session.partner.city });
      const pm = photoManager(l.photos, 10);
      const fac = textInput((l.facilities ?? []).join(', '), { placeholder: 'comma separated' });
      const doctors = (l.doctors ?? []).map((d) => ({ ...d }));
      return [h('div', { class: 'vx-grid' }, field('Clinic name', name), field('Speciality', spec), field('Phone', phone)),
        loc.el, h('div', { class: 'muted' }, 'Photos'), pm.el, field('Facilities', fac),
        h('div', { class: 'muted' }, 'Doctors'),
        repeater(doctors, (d, remove) => h('div', { class: 'vx-inline vx-note' },
          bound(d, 'name', { placeholder: 'Dr. name' }), bound(d, 'specialty', { placeholder: 'speciality' }), bound(d, 'degree', { placeholder: 'degree' }),
          bound(d, 'registrationNo', { placeholder: 'reg. no' }), bound(d, 'experienceYears', { type: 'number', min: 0, max: 70, placeholder: 'yrs', style: 'width:80px;margin:0' }),
          h('button', { type: 'button', class: 'ghost vx-mini', onclick: remove }, 'Remove')),
        () => ({ name: '', specialty: '', degree: '', registrationNo: '', experienceYears: '' }), '+ Add doctor'),
        saveRow('Save profile', async () => {
          if (name.value.trim().length < 2) throw new Error('Enter the clinic name');
          const lo = loc.read();
          const docs = doctors.filter((d) => String(d.name ?? '').trim()).map((d) => {
            if (String(d.name).trim().length < 2) throw new Error('Doctor name is too short');
            const o = { name: String(d.name).trim() };
            for (const k of ['specialty', 'degree', 'registrationNo']) if (String(d[k] ?? '').trim()) o[k] = String(d[k]).trim();
            if (d.experienceYears !== '' && d.experienceYears != null) o.experienceYears = Number(d.experienceYears);
            if (d.photoUrl) o.photoUrl = d.photoUrl;
            return o;
          });
          await save({ name: name.value.trim(), speciality: spec.value.trim() || null, phone: phone.value.trim(), ...lo, photos: pm.get(),
            facilities: csvList(fac.value).slice(0, 30), doctors: docs, listingStep: 1 }, 'Profile saved');
        })];
    }));
    s.push(section('c-price', '2 · Pricing', () => {
      const fee = textInput(toRupees(L().consultationFeePaise), { type: 'number', min: 0 });
      return [field('Consultation fee (₹)', fee), saveRow('Save pricing', async () => save({ consultationFeePaise: toPaise(fee.value) ?? 0, listingStep: 2 }, 'Pricing saved'))];
    }));
    s.push(section('c-avail', '3 · Availability', () => {
      const l = L();
      const opd = hoursEditor(l.opdHours, { defFrom: '10:00', defTo: '14:00' });
      const sm = textInput(l.slotMinutes ?? 15, { type: 'number', min: 5, max: 120 });
      return [h('div', { class: 'muted' }, 'OPD days & hours'), opd.el, field('Appointment slot (minutes)', sm),
        saveRow('Save availability', async () => save({ opdHours: opd.read(), slotMinutes: Number(sm.value || 15), listingStep: 3 }, 'Availability saved'))];
    }));
  }

  if (kind === 'chemist') {
    s.push(section('ch-profile', '1 · Profile', () => {
      const l = L();
      const name = textInput(l.name ?? state.session.partner.name);
      const phone = textInput(l.phone ?? state.session.partner.phone);
      const loc = locationFields({ ...l, city: l.city || state.session.partner.city });
      const pm = photoManager(l.photos, 10);
      const home = checkbox(l.homeDelivery ?? l.deliveryAvailable);
      const radius = textInput(l.deliveryRadiusKm ?? '', { type: 'number', min: 0, max: 50, step: '0.5' });
      const eta = textInput(l.deliveryTimeEst, { placeholder: 'e.g. 60–90 min' });
      return [h('div', { class: 'vx-grid' }, field('Store name', name), field('Phone', phone)), loc.el,
        h('div', { class: 'muted' }, 'Photos'), pm.el,
        h('label', { class: 'row' }, home, 'Home delivery'),
        h('div', { class: 'vx-grid' }, field('Delivery radius (km)', radius), field('Delivery time', eta)),
        saveRow('Save profile', async () => {
          if (name.value.trim().length < 2) throw new Error('Enter the store name');
          const body = { name: name.value.trim(), phone: phone.value.trim(), ...loc.read(), photos: pm.get(), homeDelivery: home.checked,
            deliveryRadiusKm: numOrNull(radius.value), listingStep: 1 };
          if (eta.value.trim()) body.deliveryTimeEst = eta.value.trim();
          await save(body, 'Profile saved');
        })];
    }));
    s.push(section('ch-price', '2 · Pricing', () => {
      const d = textInput(L().discountPct ?? 0, { type: 'number', min: 0, max: 90 });
      return [field('Discount on MRP (%)', d, '0 is allowed'), saveRow('Save discount', async () => {
        const n = Number(d.value || 0);
        if (!(n >= 0 && n <= 90)) throw new Error('Discount must be 0–90%');
        await save({ discountPct: Math.round(n), listingStep: Math.max(L().listingStep ?? 1, 3) }, 'Discount saved');
      })];
    }));
    s.push(section('ch-avail', '3 · Availability', () => {
      const oh = hoursEditor(L().openHours, { defFrom: '08:00', defTo: '22:00' });
      return [h('div', { class: 'muted' }, 'Open hours'), oh.el, saveRow('Save hours', async () => save({ openHours: oh.read(), listingStep: 3 }, 'Hours saved'))];
    }));
  }

  if (kind === 'store') {
    s.push(section('s-profile', '1 · Brand profile', () => {
      const l = L();
      const business = textInput(l.businessName ?? state.session.partner.name);
      const brand = textInput(l.brandName);
      const logo = singleImage('Brand logo', l.logoUrl);
      const about = textArea(l.about, { rows: 3, placeholder: 'At least 20 characters' });
      const cats = checkGroup(options.storeCategories, l.categories ?? []);
      const gstin = textInput(l.gstin, { placeholder: 'optional' });
      return [h('div', { class: 'vx-grid' }, field('Business name', business), field('Brand name', brand), field('GSTIN', gstin)),
        logo.el, field('About the brand', about),
        h('div', {}, h('div', { class: 'muted' }, 'Categories (supplements / healthy food need a verified FSSAI licence to go live)'), cats.el),
        saveRow('Save brand profile', async () => {
          if (brand.value.trim().length < 2) throw new Error('Enter the brand name');
          const body = { brandName: brand.value.trim(), logoUrl: logo.get(), about: about.value.trim(), categories: cats.values(), gstin: gstin.value.trim() || null, listingStep: 1 };
          if (business.value.trim().length >= 2) body.businessName = business.value.trim();
          await save(body, 'Brand profile saved');
        })];
    }));
    s.push(section('s-products', '2 · Products', async (refresh) => {
      if (!pl.listing) return h('p', { class: 'muted', style: 'margin:0' }, 'Save the brand profile first.');
      return productsPanel(options, refresh, reload);
    }));
    s.push(section('s-avail', '3 · Dispatch', () => {
      const dd = textInput(L().dispatchDays ?? '', { type: 'number', min: 0, max: 30 });
      return [field('Dispatch within (days)', dd), saveRow('Save', async () => save({ dispatchDays: numOrNull(dd.value), listingStep: 3 }, 'Dispatch time saved'))];
    }));
  }

  const l = pl.listing;
  return h('div', { class: 'stack' },
    head,
    h('div', { class: 'card stack' }, checklistBox),
    h('div', {}, s,
      l ? documentsSection(kind, l.id, l, reload) : h('div', { class: 'card vx-sec', style: 'margin-top:12px;padding:16px 20px' }, h('span', { class: 'muted' }, 'Documents: save the profile first.')),
      kycBankSection(reload)),
    l ? submitBox(kind, l.id, l.status, `/partner/listing/${kind}/submit`) : null,
    l ? agreementBox(kind, l.id, l) : null,
  );
}

/** Store seller products (/partner/vendor/products). */
async function productsPanel(options, refresh, reload) {
  const { products } = await asVendor('/partner/vendor/products');
  let editing = null;
  const title = h('input', { placeholder: 'Product title' });
  const brand = h('input', { placeholder: 'Brand' });
  const category = select(options.productCategories.map((c) => [c, label(c)]), options.productCategories[0]);
  const desc = h('textarea', { rows: 2, placeholder: 'At least 10 characters' });
  const mrp = h('input', { type: 'number', min: 0, step: '0.01' });
  const sell = h('input', { type: 'number', min: 0, step: '0.01' });
  const stock = h('input', { type: 'number', min: 0, value: 0 });
  const sku = h('input', { placeholder: 'optional' });
  const active = checkbox(true);
  const pm = { photos: [] };
  const imgBox = h('div');
  const drawImgs = () => {
    const m = photoManager(pm.photos, 6);
    pm.get = m.get;
    imgBox.replaceChildren(m.el);
  };
  drawImgs();
  const formTitle = h('h3', {}, 'Add a product');
  const reset = () => {
    editing = null;
    formTitle.textContent = 'Add a product';
    [title, desc, mrp, sell, sku].forEach((x) => { x.value = ''; });
    stock.value = 0;
    active.checked = true;
    pm.photos = [];
    drawImgs();
  };
  const edit = (p) => {
    editing = p;
    formTitle.textContent = `Edit “${p.title}”`;
    title.value = p.title;
    brand.value = p.brand ?? '';
    category.value = p.category;
    desc.value = p.description ?? '';
    mrp.value = toRupees(p.originalPricePaise);
    sell.value = toRupees(p.pricePaise);
    stock.value = p.stockQuantity ?? 0;
    sku.value = p.sku ?? '';
    active.checked = p.isActive !== false;
    pm.photos = [...(p.images ?? [])];
    drawImgs();
    formTitle.scrollIntoView({ behavior: 'smooth', block: 'center' });
  };
  return [
    products.length === 0 ? h('p', { class: 'muted', style: 'margin:0' }, 'No products yet.') : h('div', { class: 'vx-scroll' }, h('table', {},
      h('tr', {}, ['Product', 'Category', 'MRP', 'Price', 'Stock', 'Visible?', ''].map((t) => h('th', {}, t))),
      products.map((p) => h('tr', {},
        h('td', {}, h('strong', {}, p.title), h('div', { class: 'muted' }, [p.brand, p.sku].filter(Boolean).join(' · '))),
        h('td', {}, label(p.category ?? '')),
        h('td', {}, inr(p.originalPricePaise)), h('td', {}, inr(p.pricePaise)),
        h('td', {}, p.stockQuantity ?? 0, p.lowStock ? h('div', { class: 'muted vx-req' }, 'Low') : null),
        h('td', {}, p.hiddenReason ? h('span', { class: 'pill pending' }, label(p.hiddenReason)) : h('span', { class: 'pill live' }, 'Shown')),
        h('td', {}, h('button', { class: 'ghost vx-mini', onclick: () => edit(p) }, 'Edit')),
      )))),
    h('div', { class: 'vx-note stack' },
      formTitle,
      h('div', { class: 'vx-grid' }, field('Title', title), field('Brand', brand), field('Category', category),
        field('MRP (₹)', mrp), field('Selling price (₹)', sell), field('Stock', stock), field('SKU', sku)),
      field('Description', desc),
      h('div', { class: 'muted' }, 'Images'), imgBox,
      h('label', { class: 'row' }, active, 'Listed in the store'),
      h('div', { class: 'row' },
        actionButton('Save product', async () => {
          const body = {
            title: title.value.trim(), brand: brand.value.trim(), category: category.value, description: desc.value.trim(),
            originalPricePaise: toPaise(mrp.value), pricePaise: toPaise(sell.value), stockQuantity: Number(stock.value || 0),
            images: pm.get ? pm.get() : [],
          };
          if (sku.value.trim()) body.sku = sku.value.trim();
          if (body.title.length < 3) throw new Error('Title needs at least 3 characters');
          if (body.brand.length < 2) throw new Error('Enter the brand');
          if (body.description.length < 10) throw new Error('Description needs at least 10 characters');
          if (body.originalPricePaise == null || body.pricePaise == null) throw new Error('Enter MRP and selling price');
          if (body.pricePaise > body.originalPricePaise) throw new Error('Selling price cannot be more than the MRP');
          if (editing) await asVendor(`/partner/vendor/products/${editing.id}`, { method: 'PUT', body: { ...body, isActive: active.checked } });
          else {
            const { product } = await asVendor('/partner/vendor/products', { method: 'POST', body });
            if (!active.checked && product?.id) await asVendor(`/partner/vendor/products/${product.id}`, { method: 'PUT', body: { isActive: false } });
          }
          toast(editing ? 'Product updated' : 'Product added');
          reset();
          await reload();
          await refresh();
        }),
        h('button', { type: 'button', class: 'ghost', onclick: reset }, 'Clear'))),
  ];
}

// ------------------------------------------------------------------------------------------------ tab

A.register('vendors', 'Register vendor', async () => {
  let body;
  try {
    body = state.session ? await editorView() : await homeView();
  } catch (err) {
    body = h('p', { class: 'muted' }, err.message);
  }
  return h('div', { class: 'stack' },
    h('div', { class: 'row' }, h('h2', { style: 'margin:0' }, 'Register a vendor'), h('span', { class: 'spacer' }),
      h('span', { class: 'muted' }, 'Set up centres, trainers, clinics, chemists and stores on the owner’s behalf')),
    body,
  );
});

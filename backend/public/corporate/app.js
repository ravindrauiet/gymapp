// FITKEY Corporate Dashboard — plain JS SPA. Talks to /api/v1 (same backend as the apps).
// HR admins sign in with the member OTP (role 'user'); /api/v1/corporate/* checks they administer the org.
'use strict';

const API = '/api/v1';
const TOKEN_KEY = 'fitkey_corporate_token';
const ORG_KEY = 'fitkey_corporate_org';

const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } },
  del(k) { try { localStorage.removeItem(k); } catch { /* private mode */ } },
};

const S = { token: store.get(TOKEN_KEY), me: null, orgs: [], org: null, role: 'viewer', paymentsMode: 'mock', plans: null };
const $ = (sel, root = document) => root.querySelector(sel);

/* ======================================================================== helpers */

/** h('div', {class, onclick, ...}, children…) — strings are always inserted as text (escaped). */
function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs ?? {})) {
    if (v === false || v == null) continue;
    if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
    else if (k === 'value') el.value = v;
    else if (k === 'checked' || k === 'disabled' || k === 'selected') el[k] = !!v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  append(el, children);
  return el;
}
function append(el, children) {
  for (const c of children.flat(Infinity)) if (c != null && c !== false) el.append(c instanceof Node ? c : String(c));
  return el;
}
const SVGNS = 'http://www.w3.org/2000/svg';
function s(tag, attrs = {}, ...children) {
  const el = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs)) if (v != null) el.setAttribute(k, v);
  for (const c of children.flat()) if (c != null) el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  return el;
}

function toast(msg, error = false) {
  const t = $('#toast');
  t.textContent = msg;
  t.className = error ? 'error' : '';
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (t.hidden = true), 3800);
}

async function api(path, { method = 'GET', body } = {}) {
  let res;
  try {
    res = await fetch(API + path, {
      method,
      headers: { 'Content-Type': 'application/json', ...(S.token ? { Authorization: `Bearer ${S.token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new Error('Network error — check your connection');
  }
  if (res.status === 401 && S.token) {
    logout();
    throw new Error('Your session expired — please sign in again');
  }
  const data = res.status === 204 ? null : await res.json().catch(() => null);
  if (!res.ok) throw new Error(data?.error ?? `Request failed (${res.status})`);
  return data;
}
const orgApi = (path, opts) => api(`/corporate/orgs/${S.org.id}${path}`, opts);

const inr = (paise) => `₹${(Number(paise || 0) / 100).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`;
const num = (n) => Number(n || 0).toLocaleString('en-IN');
const pct = (a, b) => (b ? Math.round((a / b) * 100) : 0);
function toDate(v) {
  if (!v) return null;
  return typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) ? new Date(`${v}T00:00:00`) : new Date(v);
}
const fmtDate = (v, opts = { day: 'numeric', month: 'short', year: 'numeric' }) => (v ? toDate(v).toLocaleDateString('en-IN', opts) : '—');
const fmtShort = (v) => fmtDate(v, { day: 'numeric', month: 'short' });
const fmtDateTime = (v) => (v ? toDate(v).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' }) : '—');
const isoDay = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const initials = (name) => (name || '?').split(/[\s@.]+/).filter(Boolean).slice(0, 2).map((p) => p[0].toUpperCase()).join('');
const can = (role) => ({ viewer: 1, admin: 2, owner: 3 })[S.role] >= ({ viewer: 1, admin: 2, owner: 3 })[role];
const METRICS = {
  checkins: { label: 'Check-in days', unit: 'days', hint: 'Distinct days with a gym/centre check-in' },
  running_km: { label: 'Running distance', unit: 'km', hint: 'Kilometres from runs logged during the event' },
  streak: { label: 'Longest streak', unit: 'days', hint: 'Longest run of consecutive check-in days' },
  attendance: { label: 'On-ground attendance', unit: 'attended', hint: 'Checked in at the venue on the event day' },
  arena_reps: { label: 'AI rep challenge', unit: 'reps', hint: 'Best AI-counted set in the FITKEY Arena' },
};
const FORMATS = { virtual: 'Virtual', onground: 'On-ground', ai: 'AI-verified' };

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const ta = h('textarea', { style: { position: 'fixed', opacity: '0' } }, text);
    document.body.append(ta);
    ta.select();
    document.execCommand('copy');
    ta.remove();
  }
  toast('Copied to clipboard');
}
function download(filename, text, type = 'text/csv') {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = h('a', { href: url, download: filename });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
const csvCell = (v) => (/[",\n]/.test(String(v ?? '')) ? `"${String(v).replace(/"/g, '""')}"` : String(v ?? ''));

/* ---------- states */
function loadingState(kind = 'page') {
  if (kind === 'page') {
    return h('div', { class: 'stack' },
      h('div', { class: 'kpis' }, [1, 2, 3, 4].map(() => h('div', { class: 'skeleton sk-kpi' }))),
      h('div', { class: 'skeleton sk-card' }));
  }
  return h('div', {}, [1, 2, 3, 4].map(() => h('div', { class: 'skeleton sk-row' })));
}
function emptyState(icon, title, text, action) {
  return h('div', { class: 'state' }, h('div', { class: 'ico' }, icon), h('h3', {}, title), text && h('p', {}, text), action);
}
function errorState(message, retry) {
  return h('div', { class: 'state error' }, h('div', { class: 'ico' }, '!'), h('h3', {}, 'Something went wrong'), h('p', {}, message),
    retry && h('button', { class: 'btn', onclick: retry }, 'Try again'));
}
/** Renders an async section into `box`, with loading and error states. */
async function section(box, loader, kind = 'rows') {
  box.replaceChildren(loadingState(kind));
  try {
    const content = await loader();
    box.replaceChildren(...[content].flat().filter(Boolean));
  } catch (err) {
    box.replaceChildren(errorState(err.message, () => section(box, loader, kind)));
  }
}
function badge(text, color = '', plain = false) {
  return h('span', { class: `badge ${color} ${plain ? 'plain' : ''}` }, text);
}
function card(title, sub, right, ...body) {
  return h('section', { class: 'card' },
    h('div', { class: 'card-head' }, h('div', {}, h('h2', {}, title), sub && h('p', { class: 'muted' }, sub)), right && h('div', { class: 'right' }, right)),
    ...body);
}
function kpi(label, value, sub, accent) {
  const wordy = typeof value === 'string' && /[a-z]{3}/i.test(value) && value.length > 8;
  return h('div', { class: `kpi ${accent ? 'accent' : ''}` }, h('div', { class: 'label' }, label), h('div', { class: `value ${wordy ? 'text' : ''}` }, value), sub && h('div', { class: 'sub' }, sub));
}
function tabs(options, current, onChange) {
  const wrap = h('div', { class: 'tabs', role: 'tablist' });
  for (const [value, label] of options) {
    wrap.append(h('button', { class: value === current ? 'active' : '', role: 'tab', 'aria-selected': String(value === current),
      onclick: () => { wrap.querySelectorAll('button').forEach((b) => { b.classList.remove('active'); b.setAttribute('aria-selected', 'false'); });
        const btn = [...wrap.children].find((b) => b.dataset.v === String(value)); btn.classList.add('active'); btn.setAttribute('aria-selected', 'true'); onChange(value); },
      'data-v': String(value) }, label));
  }
  return wrap;
}

/* ---------- modal */
function modal({ title, sub, body, actions = [], wide = false, onClose }) {
  const root = $('#modal-root');
  const close = () => { backdrop.remove(); document.removeEventListener('keydown', onKey); onClose?.(); };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  const foot = h('div', { class: 'modal-foot' });
  const box = h('div', { class: `modal ${wide ? 'wide' : ''}`, role: 'dialog', 'aria-modal': 'true', 'aria-label': title },
    h('div', { class: 'modal-head' }, h('div', {}, h('h2', {}, title), sub && h('p', { class: 'muted' }, sub)),
      h('button', { class: 'icon-btn', 'aria-label': 'Close', onclick: close }, '✕')),
    h('div', { class: 'modal-body' }, body),
    foot);
  const backdrop = h('div', { class: 'modal-backdrop', onmousedown: (e) => { if (e.target === backdrop) close(); } }, box);
  const setActions = (list) => {
    foot.replaceChildren(...list.map((a) => h('button', {
      class: `btn ${a.kind ?? ''}`, type: 'button', disabled: a.disabled,
      onclick: async (e) => {
        if (!a.run) return close();
        const btn = e.currentTarget;
        btn.disabled = true;
        try { const keep = await a.run(close); if (keep !== true) close(); } catch (err) { toast(err.message, true); } finally { btn.disabled = false; }
      },
    }, a.label)));
    foot.hidden = !list.length;
  };
  setActions(actions);
  root.append(backdrop);
  document.addEventListener('keydown', onKey);
  setTimeout(() => box.querySelector('input, select, textarea')?.focus(), 30);
  return { close, setActions, box };
}
function confirmDialog({ title, text, confirm = 'Confirm', danger = true, run }) {
  modal({ title, body: h('p', { class: 'muted' }, text), actions: [{ label: 'Cancel', kind: 'ghost' }, { label: confirm, kind: danger ? 'danger' : 'primary', run }] });
}
/** Builds a form from fields; returns { el, values() }. */
function formFields(fields) {
  const el = h('div', { class: 'stack' });
  const inputs = {};
  const row = (f) => {
    let input;
    if (f.type === 'select') {
      input = h('select', { name: f.name }, f.options.map(([v, l]) => h('option', { value: v, selected: String(v) === String(f.value ?? '') }, l)));
    } else if (f.type === 'textarea') {
      input = h('textarea', { name: f.name, placeholder: f.placeholder ?? '', maxlength: f.max }, f.value ?? '');
    } else {
      input = h('input', { name: f.name, type: f.type ?? 'text', value: f.value ?? '', placeholder: f.placeholder ?? '', required: f.required, min: f.min, max: f.maxValue, maxlength: f.max, inputmode: f.inputmode });
    }
    if (f.onchange) input.addEventListener('input', f.onchange);
    inputs[f.name] = input;
    return h('label', { class: 'field', 'data-field': f.name, hidden: f.hidden }, h('span', {}, f.label), input, f.hint && h('small', { class: 'hint' }, f.hint));
  };
  for (const f of fields) el.append(Array.isArray(f) ? h('div', { class: f.length === 3 ? 'grid3' : 'grid2' }, f.map(row)) : row(f));
  return { el, inputs, values: () => Object.fromEntries(Object.entries(inputs).map(([k, i]) => [k, i.value.trim()])) };
}

/* ======================================================================== charts (SVG, no library) */

const tip = {
  show(e, html) {
    const t = $('#tooltip');
    t.replaceChildren(...html);
    t.hidden = false;
    const x = Math.min(e.clientX + 14, window.innerWidth - t.offsetWidth - 8);
    const y = Math.max(8, e.clientY - t.offsetHeight - 12);
    t.style.left = `${x}px`;
    t.style.top = `${y}px`;
  },
  hide() { $('#tooltip').hidden = true; },
};
function niceMax(v) {
  if (v <= 4) return 4;
  const p = 10 ** Math.floor(Math.log10(v));
  const m = [1, 2, 2.5, 5, 10].find((k) => k * p >= v);
  return m * p;
}

/** Single-series line/area over dates. rows: [{date, value}] */
function lineChart(rows, { label, unit = '' } = {}) {
  const W = 720, H = 230, L = 36, R = 12, T = 12, B = 26;
  const max = niceMax(Math.max(0, ...rows.map((r) => r.value)));
  const x = (i) => L + (rows.length <= 1 ? 0 : (i / (rows.length - 1)) * (W - L - R));
  const y = (v) => T + (1 - v / max) * (H - T - B);
  const svg = s('svg', { viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': `${label} chart` });
  svg.append(s('defs', {}, s('linearGradient', { id: 'fk-area', x1: 0, y1: 0, x2: 0, y2: 1 },
    s('stop', { offset: '0%', 'stop-color': '#FF5A36', 'stop-opacity': 0.18 }), s('stop', { offset: '100%', 'stop-color': '#FF5A36', 'stop-opacity': 0 }))));
  const grid = s('g', { class: 'grid' });
  const axis = s('g', { class: 'axis' });
  for (let k = 0; k <= 4; k++) {
    const v = (max / 4) * k;
    grid.append(s('line', { x1: L, x2: W - R, y1: y(v), y2: y(v) }));
    axis.append(s('text', { x: L - 8, y: y(v) + 4, 'text-anchor': 'end' }, Number.isInteger(v) ? v : v.toFixed(1)));
  }
  const step = Math.max(1, Math.ceil(rows.length / 7));
  rows.forEach((r, i) => {
    if (i % step === 0 || i === rows.length - 1) {
      axis.append(s('text', { x: x(i), y: H - 6, 'text-anchor': i === 0 ? 'start' : i === rows.length - 1 ? 'end' : 'middle' }, fmtShort(r.date)));
    }
  });
  svg.append(grid, axis);
  if (rows.length) {
    const pts = rows.map((r, i) => `${x(i)},${y(r.value)}`);
    svg.append(s('path', { class: 'area', d: `M${x(0)},${y(0)} L${pts.join(' L')} L${x(rows.length - 1)},${y(0)} Z` }));
    svg.append(s('path', { class: 'line', d: `M${pts.join(' L')}` }));
  }
  const cross = s('line', { class: 'cross', y1: T, y2: H - B, visibility: 'hidden' });
  const dot = s('circle', { class: 'dot', r: 5, visibility: 'hidden' });
  const hit = s('rect', { class: 'hit', x: L, y: T, width: W - L - R, height: H - T - B });
  svg.append(cross, dot, hit);
  const move = (e) => {
    const rect = svg.getBoundingClientRect();
    const px = ((e.clientX - rect.left) / rect.width) * W;
    const i = Math.max(0, Math.min(rows.length - 1, Math.round(((px - L) / (W - L - R)) * (rows.length - 1))));
    const r = rows[i];
    if (!r) return;
    cross.setAttribute('x1', x(i)); cross.setAttribute('x2', x(i)); cross.setAttribute('visibility', 'visible');
    dot.setAttribute('cx', x(i)); dot.setAttribute('cy', y(r.value)); dot.setAttribute('visibility', 'visible');
    tip.show(e, [h('b', {}, `${num(r.value)} ${unit}`), fmtDate(r.date, { weekday: 'short', day: 'numeric', month: 'short' }), r.extra ? h('div', {}, r.extra) : null].filter(Boolean));
  };
  hit.addEventListener('mousemove', move);
  hit.addEventListener('mouseleave', () => { cross.setAttribute('visibility', 'hidden'); dot.setAttribute('visibility', 'hidden'); tip.hide(); });
  return h('div', { class: 'chart' }, svg);
}

/** Vertical bars for a few categories. rows: [{label, value}] */
function barChart(rows, { unit = '' } = {}) {
  const W = 420, H = 200, L = 30, R = 6, T = 12, B = 24;
  const max = niceMax(Math.max(0, ...rows.map((r) => r.value)));
  const bw = (W - L - R) / rows.length;
  const y = (v) => T + (1 - v / max) * (H - T - B);
  const svg = s('svg', { viewBox: `0 0 ${W} ${H}`, role: 'img' });
  const grid = s('g', { class: 'grid' });
  const axis = s('g', { class: 'axis' });
  for (let k = 0; k <= 4; k++) {
    const v = (max / 4) * k;
    grid.append(s('line', { x1: L, x2: W - R, y1: y(v), y2: y(v) }));
    axis.append(s('text', { x: L - 6, y: y(v) + 4, 'text-anchor': 'end' }, Number.isInteger(v) ? v : v.toFixed(1)));
  }
  svg.append(grid, axis);
  const top = Math.max(...rows.map((r) => r.value));
  rows.forEach((r, i) => {
    const bx = L + i * bw + bw * 0.22;
    const w = bw * 0.56;
    const hgt = Math.max(0, y(0) - y(r.value));
    const rr = Math.min(4, w / 2, hgt);
    const yy = y(r.value);
    // Rounded top, square base anchored to the baseline.
    const d = hgt > 0 ? `M${bx},${y(0)} V${yy + rr} Q${bx},${yy} ${bx + rr},${yy} H${bx + w - rr} Q${bx + w},${yy} ${bx + w},${yy + rr} V${y(0)} Z` : '';
    if (d) svg.append(s('path', { class: `bar ${r.value === top ? '' : 'dim'}`, d }));
    axis.append(s('text', { x: bx + w / 2, y: H - 6, 'text-anchor': 'middle' }, r.label));
    const hit = s('rect', { class: 'hit', x: L + i * bw, y: T, width: bw, height: H - T - B });
    hit.addEventListener('mousemove', (e) => tip.show(e, [h('b', {}, `${num(r.value)} ${unit}`), r.full ?? r.label]));
    hit.addEventListener('mouseleave', tip.hide);
    svg.append(hit);
  });
  return h('div', { class: 'chart' }, svg);
}

/** Horizontal labelled bars. rows: [{name, sub?, value, display?}] */
function hBars(rows, { max } = {}) {
  const m = max ?? Math.max(1, ...rows.map((r) => r.value));
  return h('div', { class: 'hbars' }, rows.map((r) => h('div', { class: 'hbar' },
    h('div', { class: 'name', title: r.name }, r.name, r.sub && h('small', {}, r.sub)),
    h('div', { class: 'track' }, h('div', { class: 'fill', style: { width: `${Math.max(1, (r.value / m) * 100)}%` } })),
    h('div', { class: 'val' }, r.display ?? num(r.value)))));
}

/* ======================================================================== auth */

let loginPhone = '';
$('#login-phone').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = e.submitter;
  btn.disabled = true;
  try {
    loginPhone = e.target.phone.value;
    const r = await api('/auth/otp/request', { method: 'POST', body: { phone: loginPhone, role: 'user' } });
    $('#login-phone').hidden = true;
    $('#login-otp').hidden = false;
    $('#dev-otp').textContent = r.devOtp ? `Development code: ${r.devOtp}` : `We sent a code to ${loginPhone}.`;
    $('#login-otp').otp.focus();
  } catch (err) {
    toast(err.message, true);
  } finally {
    btn.disabled = false;
  }
});
$('#login-otp').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = e.submitter;
  btn.disabled = true;
  try {
    const r = await api('/auth/otp/verify', { method: 'POST', body: { phone: loginPhone, otp: e.target.otp.value, role: 'user' } });
    S.token = r.token;
    store.set(TOKEN_KEY, r.token);
    e.target.reset();
    await boot();
  } catch (err) {
    toast(err.message, true);
  } finally {
    btn.disabled = false;
  }
});
$('#login-back').addEventListener('click', () => { $('#login-otp').hidden = true; $('#login-phone').hidden = false; });
document.addEventListener('click', (e) => { if (e.target.closest('[data-action="logout"]')) logout(); });

function logout() {
  S.token = null;
  store.del(TOKEN_KEY);
  showView('login');
}
function showView(v) {
  $('#login-view').hidden = v !== 'login';
  $('#noaccess-view').hidden = v !== 'noaccess';
  $('#app-view').hidden = v !== 'app';
  if (v === 'login') { $('#login-otp').hidden = true; $('#login-phone').hidden = false; }
}

async function boot() {
  if (!S.token) return showView('login');
  try {
    const r = await api('/corporate/me');
    S.me = r.user;
    S.orgs = r.orgs;
    S.paymentsMode = r.paymentsMode;
  } catch (err) {
    if (!S.token) return; // logged out by 401
    showView('login');
    return toast(err.message, true);
  }
  if (!S.orgs.length) return showView('noaccess');
  const saved = store.get(ORG_KEY);
  selectOrg(S.orgs.find((o) => o.id === saved) ?? S.orgs[0], false);
  $('#me-name').textContent = S.me.name || 'HR admin';
  $('#me-phone').textContent = S.me.phone;
  $('#me-avatar').textContent = initials(S.me.name || 'HR');
  const sel = $('#org-select');
  sel.replaceChildren(...S.orgs.map((o) => h('option', { value: o.id, selected: o.id === S.org.id }, o.name)));
  sel.onchange = () => selectOrg(S.orgs.find((o) => o.id === sel.value));
  $('#mock-banner').hidden = S.paymentsMode !== 'mock';
  showView('app');
  route();
}
function selectOrg(org, rerender = true) {
  S.org = org;
  S.role = org.role;
  store.set(ORG_KEY, org.id);
  const av = $('#org-avatar');
  av.replaceChildren(org.logoUrl ? h('img', { src: org.logoUrl, alt: '' }) : initials(org.name));
  $('#org-role').textContent = `${org.role} · ${org.kind}`;
  if (rerender) route();
}
/** Keeps the sidebar badges (battle invites, renewals) fresh. */
async function refreshBadges() {
  try {
    const r = await orgApi('/overview');
    const set = (id, n) => { const el = $(id); el.textContent = n; el.hidden = !n; };
    set('#nav-battles', r.kpis.battleInvites);
    set('#nav-renewals', r.kpis.renewalsDue);
    return r;
  } catch { return null; }
}

/* ======================================================================== router */

const PAGES = {
  overview: { title: 'Overview', sub: 'How your people are using FITKEY', render: renderOverview },
  members: { title: 'Members', sub: 'Verified employees, invitations and departments', render: renderMembers },
  passes: { title: 'Passes', sub: 'Buy passes in bulk and assign them to employees', render: renderPasses },
  events: { title: 'Events', sub: 'Company challenges and inter-org battles', render: renderEvents },
  analytics: { title: 'Analytics', sub: 'Usage and participation — never health data', render: renderAnalytics },
  billing: { title: 'Billing', sub: 'Invoices, payment history and renewals', render: renderBilling },
  settings: { title: 'Settings', sub: 'Company profile, email domains, HR admins and privacy', render: renderSettings },
};
let renderSeq = 0;
function route() {
  if (!S.org) return;
  const key = (location.hash.slice(1) || 'overview').split('?')[0];
  const page = PAGES[key] ?? PAGES.overview;
  document.querySelectorAll('#nav a').forEach((a) => a.classList.toggle('active', a.dataset.page === key));
  $('#page-title').textContent = page.title;
  $('#page-sub').textContent = `${S.org.name} · ${page.sub}`;
  document.title = `${page.title} · FITKEY for Business`;
  $('#page-actions').replaceChildren();
  $('#app-view').classList.remove('nav-open');
  const box = $('#page');
  box.replaceChildren(loadingState('page'));
  const seq = ++renderSeq;
  Promise.resolve()
    .then(() => page.render(box, seq))
    .catch((err) => { if (seq === renderSeq) box.replaceChildren(errorState(err.message, route)); });
  refreshBadges();
}
window.addEventListener('hashchange', route);
$('#menu-btn').addEventListener('click', () => $('#app-view').classList.add('nav-open'));
$('#scrim').addEventListener('click', () => $('#app-view').classList.remove('nav-open'));
const actions = (...btns) => $('#page-actions').replaceChildren(...btns.filter(Boolean));
const stale = (seq) => seq !== renderSeq;

/* ======================================================================== overview */

async function renderOverview(box, seq) {
  const r = await orgApi('/overview');
  if (stale(seq)) return;
  const k = r.kpis;
  const delta = k.checkinsPrev30d ? Math.round(((k.checkins30d - k.checkinsPrev30d) / k.checkinsPrev30d) * 100) : null;
  actions(can('admin') && h('button', { class: 'btn', onclick: () => openInvite() }, '+ Invite employee'),
    can('admin') && h('button', { class: 'btn primary', onclick: () => openBuy() }, 'Buy passes'));

  const callouts = [];
  if (k.battleInvites) callouts.push(h('div', { class: 'callout orange' }, h('div', { class: 'grow' }, h('b', {}, `${k.battleInvites} battle challenge${k.battleInvites > 1 ? 's' : ''} waiting`), h('div', { class: 'hint' }, 'Another organisation wants to compete with your team.')), h('a', { class: 'btn small', href: '#events' }, 'Review')));
  if (k.renewalsDue) callouts.push(h('div', { class: 'callout blue' }, h('div', { class: 'grow' }, h('b', {}, `${k.renewalsDue} pass${k.renewalsDue > 1 ? 'es' : ''} expire in the next 14 days`), h('div', { class: 'hint' }, 'Buy renewal passes and reassign to keep people active.')), h('a', { class: 'btn small', href: '#billing' }, 'See renewals')));
  if (!k.members && !k.pendingInvites) callouts.push(h('div', { class: 'callout green' }, h('div', { class: 'grow' }, h('b', {}, 'Get started: invite your people'), h('div', { class: 'hint' }, 'Add your email domain in Settings so employees can verify with their work email, or invite them by CSV.')), h('a', { class: 'btn small', href: '#members' }, 'Invite')));

  const series = r.series.map((d) => ({ date: d.date, value: d.checkins, extra: `${d.employees} employee${d.employees === 1 ? '' : 's'}` }));
  const totalChecks = series.reduce((a, b) => a + b.value, 0);

  box.replaceChildren(
    h('div', { class: 'kpis' },
      kpi('Verified members', num(k.members), `${num(k.pendingInvites)} invite${k.pendingInvites === 1 ? '' : 's'} pending`, true),
      kpi('Active employees · 30d', num(k.active30d), `${pct(k.active30d, k.members)}% of members checked in`),
      kpi('Check-ins · 30d', num(k.checkins30d), delta == null ? 'vs previous 30 days: —' : h('span', {}, h('span', { class: `delta ${delta >= 0 ? 'up' : 'down'}` }, `${delta >= 0 ? '▲' : '▼'} ${Math.abs(delta)}%`), ' vs previous 30 days')),
      kpi('Active passes', num(k.activePasses), `${num(k.seatsAvailable)} unassigned · ${num(k.pendingPasses)} awaiting signup`)),
    ...callouts,
    h('div', { class: 'cols' },
      card('Daily check-ins', 'Last 30 days, all centres', h('a', { class: 'btn small ghost', href: '#analytics' }, 'Analytics →'),
        totalChecks ? lineChart(series, { label: 'Daily check-ins', unit: 'check-ins' }) : emptyState('▥', 'No check-ins yet', 'Once employees with passes visit a FITKEY centre, daily activity shows up here.')),
      card('Upcoming & live events', null, h('a', { class: 'btn small ghost', href: '#events' }, 'All events →'),
        r.events.length ? h('div', { class: 'list' }, r.events.map((e) => h('div', { class: 'list-item' },
          h('div', { class: 'avatar' }, '⚑'),
          h('div', { class: 'grow' }, h('b', {}, e.title), h('small', {}, `${fmtShort(e.startsOn)} – ${fmtShort(e.endsOn)} · ${e.myParticipants} joined`)),
          stateBadge(e.state))))
          : emptyState('⚑', 'No events running', 'Create a step-up challenge or battle another company.', can('admin') && h('a', { class: 'btn small primary', href: '#events' }, 'Create event')))),
  );
}
function stateBadge(state) {
  return { live: badge('Live', 'green'), upcoming: badge('Upcoming', 'blue'), past: badge('Ended') }[state] ?? badge(state);
}

/* ======================================================================== members */

const memberState = { tab: 'verified', q: '', department: '' };

async function renderMembers(box) {
  actions(
    can('admin') && h('button', { class: 'btn', onclick: () => openBulk() }, '⇪ Bulk upload CSV'),
    can('admin') && h('button', { class: 'btn primary', onclick: () => openInvite() }, '+ Invite employee'),
  );
  const body = h('div');
  const search = h('input', { class: 'input', type: 'search', placeholder: 'Search name or work email', value: memberState.q });
  const dept = h('select', { class: 'input', 'aria-label': 'Department' }, h('option', { value: '' }, 'All departments'));
  let timer;
  search.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => { memberState.q = search.value.trim(); load(); }, 250); });
  dept.addEventListener('change', () => { memberState.department = dept.value; load(); });
  const t = tabs([['verified', 'Verified'], ['invites', 'Pending invites'], ['removed', 'Removed']], memberState.tab, (v) => { memberState.tab = v; load(); });
  const toolbar = h('div', { class: 'toolbar' }, t, search, dept);
  const load = () => section(body, async () => {
    search.hidden = dept.hidden = memberState.tab === 'invites';
    if (memberState.tab === 'invites') return invitesTable(await orgApi('/invites'));
    const p = new URLSearchParams({ status: memberState.tab });
    if (memberState.q) p.set('q', memberState.q);
    if (memberState.department) p.set('department', memberState.department);
    const r = await orgApi(`/members?${p}`);
    dept.replaceChildren(h('option', { value: '' }, 'All departments'), ...r.departments.map((d) => h('option', { value: d, selected: d === memberState.department }, d)));
    return membersTable(r.members);
  });
  box.replaceChildren(
    joinHelp(),
    h('section', { class: 'card' }, toolbar, body));
  load();
}
function joinHelp() {
  return h('div', { class: 'callout green' },
    h('div', { class: 'grow' }, h('b', {}, 'How employees join'),
      h('div', { class: 'hint' }, 'In the FITKEY app, employees verify their work email (any domain listed in Settings) — or you invite them here and share their personal invite link. Passes you queued activate the moment they verify.')),
    S.org.inviteCode ? h('span', { class: 'hint' }, 'Org join code ', h('b', { class: 'mono' }, S.org.inviteCode)) : null);
}
function membersTable(members) {
  if (!members.length) {
    return memberState.tab === 'removed'
      ? emptyState('☺', 'No removed members', null)
      : emptyState('☺', memberState.q || memberState.department ? 'No matches' : 'No verified members yet',
        memberState.q || memberState.department ? 'Try a different search or department.' : 'Invite employees by email or CSV, or add your company domain so they can self-verify in the app.',
        can('admin') && !memberState.q && h('button', { class: 'btn primary small', onclick: () => openBulk() }, 'Upload CSV'));
  }
  const removed = memberState.tab === 'removed';
  return h('div', {},
    h('div', { class: 'table-wrap' }, h('table', {},
      h('thead', {}, h('tr', {}, h('th', {}, 'Employee'), h('th', {}, 'Department'), h('th', {}, 'Joined via'), h('th', {}, 'Company pass'),
        h('th', { class: 'num' }, 'Check-ins 30d'), h('th', {}, 'Last visit'), h('th', { class: 'num' }, 'Events'), h('th', {}))),
      h('tbody', {}, members.map((m) => h('tr', {},
        h('td', {}, h('div', { class: 'person' }, h('div', { class: 'avatar' }, initials(m.name || m.workEmail)), h('div', {}, h('b', {}, m.name || 'Name not set'), h('small', {}, m.workEmail || '—')))),
        h('td', {}, m.department || h('span', { class: 'hint' }, '—')),
        h('td', {}, { email: 'Work email', invite_code: 'Join code', id_upload: 'ID upload', hr_invite: 'HR invite' }[m.method] ?? m.method,
          h('div', { class: 'hint' }, fmtDate(m.verifiedAt))),
        h('td', {}, m.pass ? h('div', {}, badge(m.pass.planName, 'green'), h('div', { class: 'hint' }, `until ${fmtDate(m.pass.endsAt)}`)) : badge('No pass', '', true)),
        h('td', { class: 'num' }, num(m.checkins30d)),
        h('td', {}, m.lastCheckin ? fmtDate(m.lastCheckin) : h('span', { class: 'hint' }, 'Never')),
        h('td', { class: 'num' }, num(m.eventsJoined)),
        h('td', {}, can('admin') && !removed && h('div', { class: 'row-actions' },
          !m.pass && h('button', { class: 'btn small', onclick: () => openAssign({ userIds: [m.userId], label: m.name || m.workEmail }) }, 'Give pass'),
          h('button', { class: 'btn small ghost', onclick: () => editDepartment(m) }, 'Edit'),
          h('button', { class: 'btn small ghost', onclick: () => removeMember(m) }, 'Remove')))))))),
    h('p', { class: 'fine' }, `${members.length} ${removed ? 'removed' : 'verified'} member${members.length === 1 ? '' : 's'}. Only usage and participation are shown — FITKEY never shares weight, nutrition or health data with employers.`));
}
function editDepartment(m) {
  const f = formFields([{ name: 'department', label: 'Department', value: m.department ?? '', max: 80, placeholder: 'e.g. Engineering' }]);
  modal({ title: `Edit ${m.name || m.workEmail}`, body: f.el, actions: [{ label: 'Cancel', kind: 'ghost' }, { label: 'Save', kind: 'primary', run: async () => {
    await orgApi(`/members/${m.userId}`, { method: 'PATCH', body: { department: f.values().department || null } });
    toast('Department updated');
    route();
  } }] });
}
function removeMember(m) {
  confirmDialog({
    title: `Remove ${m.name || m.workEmail}?`,
    text: `They lose the ${S.org.name} badge and access to org events${m.pass ? `, and their ${m.pass.planName} company pass ends immediately` : ''}. They keep their personal FITKEY account. They can rejoin later by verifying again.`,
    confirm: 'Remove member',
    run: async () => {
      const r = await orgApi(`/members/${m.userId}`, { method: 'DELETE' });
      toast(r.passesRevoked ? 'Member removed and pass revoked' : 'Member removed');
      route();
    },
  });
}
function invitesTable({ invites }) {
  if (!invites.length) return emptyState('✉', 'No pending invites', 'Invite people one by one or upload a CSV of work emails.', can('admin') && h('button', { class: 'btn primary small', onclick: () => openInvite() }, 'Invite employee'));
  return h('div', {},
    h('div', { class: 'toolbar' }, h('span', { class: 'hint' }, 'No email is sent automatically yet — copy each person\'s invite link and share it (email, Slack, Teams).'),
      h('button', { class: 'btn small', style: { marginLeft: 'auto' }, onclick: () => download(`${S.org.name}-invites.csv`, ['email,name,department,invite_link', ...invites.map((i) => [i.email, i.name, i.department, i.link].map(csvCell).join(','))].join('\n')) }, '⇩ Export links (CSV)')),
    h('div', { class: 'table-wrap' }, h('table', {},
      h('thead', {}, h('tr', {}, h('th', {}, 'Email'), h('th', {}, 'Department'), h('th', {}, 'Queued pass'), h('th', {}, 'Last shared'), h('th', {}))),
      h('tbody', {}, invites.map((i) => h('tr', {},
        h('td', {}, h('div', { class: 'person' }, h('div', { class: 'avatar' }, initials(i.name || i.email)), h('div', {}, h('b', {}, i.name || i.email), i.name && h('small', {}, i.email)))),
        h('td', {}, i.department || h('span', { class: 'hint' }, '—')),
        h('td', {}, i.pendingPass ? badge(i.pendingPass, 'amber') : h('span', { class: 'hint' }, '—')),
        h('td', {}, fmtDateTime(i.lastSentAt)),
        h('td', {}, h('div', { class: 'row-actions' },
          h('button', { class: 'btn small', onclick: () => copyText(i.link) }, 'Copy link'),
          can('admin') && h('button', { class: 'btn small ghost', onclick: async () => { try { const r = await orgApi(`/invites/${i.id}/resend`, { method: 'POST' }); await copyText(r.link); toast('Reminder logged — link copied to share'); } catch (e) { toast(e.message, true); } } }, 'Remind'),
          can('admin') && h('button', { class: 'btn small ghost', onclick: () => confirmDialog({ title: 'Withdraw invite?', text: `${i.email}'s link will stop working${i.pendingPass ? ' and the queued pass returns to your pool' : ''}.`, confirm: 'Withdraw', run: async () => { await orgApi(`/invites/${i.id}`, { method: 'DELETE' }); toast('Invite withdrawn'); route(); } }) }, 'Withdraw')))))))));
}

async function getPlans() {
  if (!S.plans) S.plans = (await api('/plans')).plans;
  return S.plans;
}
async function getInventory() {
  return (await orgApi('/passes?status=pending')).inventory;
}
function planOptions(inventory, includeNone = true) {
  const opts = inventory.filter((s) => s.available > 0).map((s) => [s.planId, `${s.planName} — ${s.available} unassigned`]);
  return [...(includeNone ? [['', 'No pass for now']] : []), ...opts];
}
async function openInvite() {
  let inventory = [];
  try { inventory = await getInventory(); } catch { /* still allow inviting */ }
  const f = formFields([
    { name: 'email', label: 'Work email', type: 'email', required: true, placeholder: 'name@company.com' },
    [{ name: 'name', label: 'Name (optional)', max: 120 }, { name: 'department', label: 'Department (optional)', max: 80 }],
    { name: 'planId', label: 'Give a pass', type: 'select', options: planOptions(inventory), hint: inventory.some((s) => s.available) ? 'The pass activates when they verify.' : 'Buy passes first to queue one with the invite.' },
  ]);
  const m = modal({
    title: 'Invite an employee', sub: 'We create a personal invite link you can share.', body: f.el,
    actions: [{ label: 'Cancel', kind: 'ghost' }, { label: 'Create invite', kind: 'primary', run: async () => {
      const v = f.values();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.email)) throw new Error('Enter a valid work email');
      const r = await orgApi('/invites', { method: 'POST', body: { email: v.email, name: v.name || null, department: v.department || null, planId: v.planId || null } });
      showInviteResult(m, r.invite);
      return true;
    } }],
  });
}
function showInviteResult(m, inv) {
  const link = h('input', { class: 'input', readonly: true, value: inv.link });
  m.box.querySelector('.modal-body').replaceChildren(
    h('div', { class: 'callout green' }, h('div', { class: 'grow' }, h('b', {}, `Invite created for ${inv.email}`), h('div', { class: 'hint' }, inv.passQueued ? 'A pass is queued and activates when they join.' : 'They can join from this link with their FITKEY account.'))),
    inv.outsideDomain ? h('p', { class: 'warn-text' }, 'Heads up: this email is outside your verified domains, so the invite link is the only way for them to join.') : '',
    h('label', { class: 'field' }, h('span', {}, 'Invite link — share it with them'), h('div', { class: 'copy-row' }, link, h('button', { class: 'btn', onclick: () => copyText(inv.link) }, 'Copy'))),
    h('p', { class: 'fine' }, 'Email delivery is not connected yet; the message that would be sent is recorded in the server log.'));
  m.setActions([{ label: 'Invite another', run: () => { m.close(); openInvite(); } }, { label: 'Done', kind: 'primary', run: () => { route(); } }]);
}

/* ---------- CSV bulk upload */
function parseCsv(text) {
  const rows = [];
  let row = [], cell = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"' && text[i + 1] === '"') { cell += '"'; i++; } else if (c === '"') q = false; else cell += c;
    } else if (c === '"') q = true;
    else if (c === ',' || c === ';' || c === '\t') { row.push(cell); cell = ''; }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++;
      row.push(cell); rows.push(row); row = []; cell = '';
    } else cell += c;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  return rows.map((r) => r.map((c) => c.trim())).filter((r) => r.some(Boolean));
}
async function openBulk() {
  let inventory = [];
  let domains = [];
  try {
    const [inv, org] = await Promise.all([getInventory(), orgApi('')]);
    inventory = inv;
    domains = org.domains;
  } catch (err) {
    return toast(err.message, true);
  }
  let parsed = [];
  const file = h('input', { type: 'file', accept: '.csv,text/csv,text/plain', hidden: true });
  const drop = h('div', { class: 'dropzone', tabindex: 0, role: 'button' },
    h('b', {}, 'Drop a CSV here or click to choose'),
    h('span', { class: 'hint' }, 'Columns: email (required), name, department · up to 2,000 rows'),
    h('button', { class: 'btn small link', type: 'button', onclick: (e) => { e.stopPropagation(); download('fitkey-invite-template.csv', `email,name,department\npriya@${domains[0] ?? 'company.com'},Priya Sharma,Engineering\nrahul@${domains[0] ?? 'company.com'},Rahul Verma,Sales\n`); } }, 'Download template'));
  const preview = h('div');
  const planSel = h('select', { class: 'input' }, planOptions(inventory).map(([v, l]) => h('option', { value: v }, l)));
  const opts = h('label', { class: 'field', hidden: true }, h('span', {}, 'Queue a pass for each new invite'), planSel,
    h('small', { class: 'hint' }, 'Passes are queued in file order until that plan runs out of unassigned seats.'));
  const handle = async (f) => {
    if (!f) return;
    if (f.size > 2 * 1024 * 1024) return toast('That file is over 2 MB', true);
    const text = await f.text();
    parsed = validateRows(parseCsv(text), domains);
    renderPreview();
  };
  drop.addEventListener('click', () => file.click());
  drop.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') file.click(); });
  file.addEventListener('change', () => handle(file.files[0]));
  drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('over'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('over'));
  drop.addEventListener('drop', (e) => { e.preventDefault(); drop.classList.remove('over'); handle(e.dataTransfer.files[0]); });

  const m = modal({ title: 'Bulk invite from CSV', sub: 'Check the preview before anything is created.', wide: true, body: h('div', { class: 'stack' }, drop, file, preview, opts), actions: [{ label: 'Cancel', kind: 'ghost' }] });

  function renderPreview() {
    const ok = parsed.filter((r) => !r.error);
    const bad = parsed.length - ok.length;
    const warn = ok.filter((r) => r.warning).length;
    opts.hidden = !ok.length;
    if (!parsed.length) {
      preview.replaceChildren(h('p', { class: 'err-text' }, 'No rows found. Make sure the file has an email column.'));
    } else {
      preview.replaceChildren(
        h('div', { class: 'summary-row' }, badge(`${parsed.length} rows`, '', true), badge(`${ok.length} ready`, 'green'), bad > 0 && badge(`${bad} with errors (skipped)`, 'red'), warn > 0 && badge(`${warn} outside your domains`, 'amber')),
        h('div', { class: 'preview-table' }, h('table', {},
          h('thead', {}, h('tr', {}, h('th', {}, '#'), h('th', {}, 'Email'), h('th', {}, 'Name'), h('th', {}, 'Department'), h('th', {}, 'Check'))),
          h('tbody', {}, parsed.slice(0, 500).map((r) => h('tr', { class: r.error ? 'bad' : '' },
            h('td', {}, r.line), h('td', {}, r.email || h('i', { class: 'hint' }, 'empty')), h('td', {}, r.name), h('td', {}, r.department),
            h('td', {}, r.error ? h('span', { class: 'err-text' }, r.error) : r.warning ? h('span', { class: 'warn-text' }, r.warning) : badge('OK', 'green'))))))),
        parsed.length > 500 ? h('p', { class: 'fine' }, `Showing the first 500 of ${parsed.length} rows.`) : '');
    }
    m.setActions([{ label: 'Cancel', kind: 'ghost' }, { label: `Invite ${ok.length} ${ok.length === 1 ? 'person' : 'people'}`, kind: 'primary', disabled: !ok.length, run: async () => {
      const r = await orgApi('/invites/bulk', { method: 'POST', body: { rows: ok.map(({ email, name, department }) => ({ email, name: name || null, department: department || null })), planId: planSel.value || null } });
      showBulkResult(r);
      return true;
    } }]);
  }
  function showBulkResult(r) {
    const queued = r.created.filter((c) => c.passQueued).length;
    m.box.querySelector('.modal-body').replaceChildren(
      h('div', { class: 'callout green' }, h('div', { class: 'grow' }, h('b', {}, `${r.created.length} invite${r.created.length === 1 ? '' : 's'} created`), h('div', { class: 'hint' }, `${queued ? `${queued} with a queued pass. ` : ''}${r.skipped.length} skipped.`))),
      r.skipped.length > 0 ? card('Skipped', null, null, h('div', { class: 'preview-table' }, h('table', {}, h('tbody', {}, r.skipped.map((s2) => h('tr', {}, h('td', {}, s2.email), h('td', { class: 'hint' }, s2.reason))))))) : '',
      r.created.length > 0 ? h('p', { class: 'hint' }, 'Email delivery isn\'t connected yet. Export the personal invite links and send them through your usual channel — or employees can simply verify their work email in the app.') : '',
    );
    m.setActions([
      r.created.length && { label: '⇩ Export invite links', run: () => { download(`${S.org.name}-new-invites.csv`, ['email,name,department,invite_link', ...r.created.map((c) => [c.email, c.name, c.department, c.link].map(csvCell).join(','))].join('\n')); return true; } },
      { label: 'Done', kind: 'primary', run: () => { memberState.tab = 'invites'; location.hash = '#members'; route(); } },
    ].filter(Boolean));
  }
}
function validateRows(rows, domains) {
  if (!rows.length) return [];
  const head = rows[0].map((c) => c.toLowerCase().replace(/[^a-z]/g, ''));
  const hasHeader = head.some((c) => c.includes('email'));
  const idx = {
    email: hasHeader ? head.findIndex((c) => c.includes('email')) : 0,
    name: hasHeader ? head.findIndex((c) => c === 'name' || c === 'fullname' || c === 'employeename') : 1,
    department: hasHeader ? head.findIndex((c) => c.startsWith('dep') || c === 'team') : 2,
  };
  const seen = new Set();
  return rows.slice(hasHeader ? 1 : 0).slice(0, 2000).map((r, i) => {
    const email = (r[idx.email] ?? '').toLowerCase();
    const row = { line: i + (hasHeader ? 2 : 1), email, name: idx.name >= 0 ? (r[idx.name] ?? '').slice(0, 120) : '', department: idx.department >= 0 ? (r[idx.department] ?? '').slice(0, 80) : '' };
    if (!email) row.error = 'Missing email';
    else if (!/^[^\s@,;]+@[^\s@,;]+\.[a-z]{2,}$/i.test(email) || email.length > 255) row.error = 'Not a valid email';
    else if (seen.has(email)) row.error = 'Duplicate in file';
    else if (domains.length && !domains.includes(email.split('@')[1])) row.warning = 'Outside your domains — invite link only';
    seen.add(email);
    return row;
  });
}

/* ======================================================================== passes */

const passState = { status: 'all' };

async function renderPasses(box, seq) {
  const r = await orgApi('/passes?status=all');
  if (stale(seq)) return;
  actions(
    can('admin') && h('button', { class: 'btn', disabled: !r.inventory.some((s2) => s2.available > 0), onclick: () => openAssign({}) }, 'Assign passes'),
    can('admin') && h('button', { class: 'btn primary', onclick: () => openBuy() }, 'Buy passes'));
  const inv = r.inventory.length
    ? h('div', { class: 'seat-cards' }, r.inventory.map((s2) => {
      const used = s2.total - s2.available;
      return h('div', { class: 'seat' },
        h('b', {}, s2.planName), h('div', { class: 'hint' }, `${s2.durationDays} days · ${inr(s2.pricePaise)} per pass`),
        h('div', { class: 'big' }, num(s2.available), h('span', { class: 'hint', style: { fontSize: '13px', fontWeight: 600 } }, ` of ${num(s2.total)} unassigned`)),
        h('div', { class: 'meter', title: `${s2.active} active · ${s2.pending} awaiting signup` },
          h('i', { style: { width: `${pct(s2.active, s2.total)}%` } }), h('i', { class: 'pending', style: { width: `${pct(s2.pending, s2.total)}%` } })),
        h('div', { class: 'hint' }, `${num(s2.active)} active · ${num(s2.pending)} awaiting signup · ${num(used - s2.active - s2.pending)} used up`));
    }))
    : emptyState('▤', 'No passes yet', 'Buy passes in bulk, then assign them to employees. Each pass becomes that person\'s FITKEY membership.', can('admin') && h('button', { class: 'btn primary small', onclick: () => openBuy() }, 'Buy passes'));

  const listBox = h('div');
  const draw = () => {
    const rows = r.assignments.filter((a) => passState.status === 'all' || a.state === passState.status);
    listBox.replaceChildren(rows.length ? h('div', { class: 'table-wrap' }, h('table', {},
      h('thead', {}, h('tr', {}, h('th', {}, 'Employee'), h('th', {}, 'Plan'), h('th', {}, 'Status'), h('th', {}, 'Valid'), h('th', {}, 'Assigned'), h('th', {}))),
      h('tbody', {}, rows.map((a) => h('tr', {},
        h('td', {}, h('div', { class: 'person' }, h('div', { class: 'avatar' }, initials(a.name || a.email)), h('div', {}, h('b', {}, a.name || a.email), a.name && h('small', {}, a.email)))),
        h('td', {}, a.planName),
        h('td', {}, { active: badge('Active', 'green'), pending: badge('Awaiting signup', 'amber'), expired: badge('Expired'), revoked: badge('Revoked', 'red') }[a.state]),
        h('td', {}, a.startsAt ? `${fmtShort(a.startsAt)} – ${fmtDate(a.endsAt)}` : h('span', { class: 'hint' }, 'Starts when they join')),
        h('td', {}, fmtDate(a.assignedAt)),
        h('td', {}, can('admin') && (a.state === 'active' || a.state === 'pending') && h('div', { class: 'row-actions' },
          h('button', { class: 'btn small ghost', onclick: () => confirmDialog({
            title: 'Revoke this pass?',
            text: a.state === 'pending'
              ? `${a.email} hasn't joined yet, so the pass goes back to your unassigned pool.`
              : `${a.name || a.email}'s ${a.planName} membership ends immediately. A pass that has already started is used up and does not return to the pool.`,
            confirm: 'Revoke pass',
            run: async () => { const x = await orgApi(`/passes/${a.id}/revoke`, { method: 'POST' }); toast(x.seatReturned ? 'Pass revoked — seat returned to pool' : 'Pass revoked'); route(); },
          }) }, 'Revoke')))))))) : emptyState('▤', 'Nothing here', passState.status === 'all' ? 'Assigned passes will be listed here.' : 'No passes with this status.'));
  };
  draw();
  box.replaceChildren(
    card('Pass inventory', 'Passes bought by your organisation, per plan', null, inv),
    card('Assigned passes', 'Each pass is a FITKEY membership for one employee', tabs([['all', 'All'], ['active', 'Active'], ['pending', 'Awaiting signup'], ['expired', 'Expired'], ['revoked', 'Revoked']], passState.status, (v) => { passState.status = v; draw(); }), listBox));
}

async function openBuy(preset = {}) {
  let plans;
  try { plans = await getPlans(); } catch (err) { return toast(err.message, true); }
  if (!plans.length) return toast('No plans are available right now', true);
  const f = formFields([
    { name: 'planId', label: 'Plan', type: 'select', value: preset.planId, options: plans.map((p) => [p.id, `${p.name} — ${inr(p.pricePaise)} / ${p.durationDays} days`]) },
    { name: 'quantity', label: 'Number of passes', type: 'number', min: 1, maxValue: 10000, value: preset.quantity ?? 10, required: true },
  ]);
  const total = h('div', { class: 'callout orange' });
  const plansById = Object.fromEntries(plans.map((p) => [p.id, p]));
  const upd = () => {
    const p = plansById[f.inputs.planId.value];
    const q = Math.max(0, Math.floor(Number(f.inputs.quantity.value) || 0));
    total.replaceChildren(h('div', { class: 'grow' }, h('b', { style: { fontSize: '20px' } }, inr(p.pricePaise * q)), h('div', { class: 'hint' }, `${q} × ${inr(p.pricePaise)} · ${p.categories?.map((c) => c.replace(/_/g, ' ')).join(', ') ?? ''}`)),
      p.venueCount != null && badge(`${p.venueCount} centres`, 'orange', true));
  };
  f.inputs.planId.addEventListener('change', upd);
  f.inputs.quantity.addEventListener('input', upd);
  upd();
  modal({
    title: 'Buy passes', sub: 'Passes go into your pool; assign them to employees any time.',
    body: h('div', { class: 'stack' }, f.el, total,
      S.paymentsMode === 'mock' && h('p', { class: 'warn-text' }, 'Payments are in mock mode: the order and invoice are recorded and the passes are usable, but no payment is collected. The invoice is marked "MOCK — not a tax invoice".')),
    actions: [{ label: 'Cancel', kind: 'ghost' }, { label: 'Place order', kind: 'primary', run: async () => {
      const q = Math.floor(Number(f.inputs.quantity.value));
      if (!(q >= 1 && q <= 10000)) throw new Error('Enter between 1 and 10,000 passes');
      const r = await orgApi('/orders', { method: 'POST', body: { planId: f.inputs.planId.value, quantity: q } });
      toast(`Order placed — invoice ${r.invoice.number}`);
      if (location.hash === '#passes') route(); else location.hash = '#passes';
    } }],
  });
}

async function openAssign({ userIds, label }) {
  let inventory, members, invites;
  try {
    [inventory, members, invites] = await Promise.all([getInventory(), userIds ? null : orgApi('/members?status=verified'), userIds ? null : orgApi('/invites')]);
  } catch (err) { return toast(err.message, true); }
  const avail = inventory.filter((s2) => s2.available > 0);
  if (!avail.length) {
    return modal({ title: 'No unassigned passes', body: h('p', { class: 'muted' }, 'Buy passes first, then assign them.'), actions: [{ label: 'Cancel', kind: 'ghost' }, { label: 'Buy passes', kind: 'primary', run: () => openBuy() }] });
  }
  const planSel = h('select', { class: 'input' }, avail.map((s2) => h('option', { value: s2.planId }, `${s2.planName} — ${s2.available} unassigned`)));
  const picked = new Set();
  let listEl = null;
  const count = h('span', { class: 'hint' });
  if (!userIds) {
    const people = [
      ...members.members.filter((m) => !m.pass).map((m) => ({ key: `u:${m.userId}`, label: m.name || m.workEmail, sub: `${m.workEmail ?? ''}${m.department ? ` · ${m.department}` : ''}`, tag: null })),
      ...invites.invites.filter((i) => !i.pendingPass).map((i) => ({ key: `e:${i.email}`, label: i.name || i.email, sub: `${i.email}${i.department ? ` · ${i.department}` : ''}`, tag: 'Invited' })),
    ];
    const filter = h('input', { class: 'input', type: 'search', placeholder: 'Filter people' });
    const items = h('div', { class: 'list', style: { maxHeight: '320px', overflow: 'auto' } });
    const drawList = () => {
      const q = filter.value.trim().toLowerCase();
      const shown = people.filter((p) => !q || `${p.label} ${p.sub}`.toLowerCase().includes(q));
      items.replaceChildren(...(shown.length ? shown.map((p) => h('label', { class: 'list-item check' },
        h('input', { type: 'checkbox', checked: picked.has(p.key), onchange: (e) => { e.target.checked ? picked.add(p.key) : picked.delete(p.key); count.textContent = `${picked.size} selected`; } }),
        h('div', { class: 'grow' }, h('b', {}, p.label), h('small', {}, p.sub)), p.tag && badge(p.tag, 'amber'))) : [emptyState('☺', 'Everyone has a pass', 'Members and invitees without a pass appear here.')]));
    };
    filter.addEventListener('input', drawList);
    const all = h('button', { class: 'btn small', type: 'button', onclick: () => { people.forEach((p) => picked.add(p.key)); count.textContent = `${picked.size} selected`; drawList(); } }, 'Select all');
    drawList();
    listEl = h('div', { class: 'stack' }, h('div', { class: 'toolbar', style: { margin: 0 } }, filter, all, count), items);
  }
  modal({
    title: label ? `Give ${label} a pass` : 'Assign passes',
    sub: 'Verified members get their membership immediately; invited people get it when they join.',
    body: h('div', { class: 'stack' }, h('label', { class: 'field' }, h('span', {}, 'Plan'), planSel), listEl),
    actions: [{ label: 'Cancel', kind: 'ghost' }, { label: 'Assign', kind: 'primary', run: async () => {
      const body = { planId: planSel.value, userIds: userIds ?? [], emails: [] };
      if (!userIds) for (const k of picked) (k.startsWith('u:') ? body.userIds : body.emails).push(k.slice(2));
      if (!body.userIds.length && !body.emails.length) throw new Error('Select at least one person');
      const r = await orgApi('/passes/assign', { method: 'POST', body });
      if (r.skipped.length) toast(`${r.assigned.length} assigned · ${r.skipped.length} skipped: ${r.skipped[0].reason}`, !r.assigned.length);
      else toast(`${r.assigned.length} pass${r.assigned.length === 1 ? '' : 'es'} assigned`);
      route();
    } }],
  });
}

/* ======================================================================== events */

const eventState = { scope: 'live' };

async function renderEvents(box, seq) {
  const r = await orgApi('/events?scope=all');
  if (stale(seq)) return;
  actions(can('admin') && h('button', { class: 'btn primary', onclick: () => openEventForm(null, r.arenaAvailable) }, '+ Create event'));
  const incoming = r.battleInvites.filter((b) => b.incoming && b.status === 'pending');
  const outgoing = r.battleInvites.filter((b) => !b.incoming);
  const parts = [];
  if (incoming.length) {
    parts.push(card('Battle challenges for you', 'Accepting adds your organisation to the battle; your members can then join and are ranked as a team.', null,
      h('div', { class: 'list' }, incoming.map((b) => h('div', { class: 'list-item' },
        h('div', { class: 'avatar' }, '⚔'),
        h('div', { class: 'grow' }, h('b', {}, `${b.fromOrgName} challenged you: ${b.title}`), h('small', {}, `${METRICS[b.metric]?.label ?? b.metric} · ${fmtShort(b.startsOn)} – ${fmtDate(b.endsOn)}${b.message ? ` · “${b.message}”` : ''}`)),
        can('admin') ? h('div', { class: 'row-actions' },
          h('button', { class: 'btn small ghost', onclick: () => confirmDialog({ title: 'Decline challenge?', text: `${b.fromOrgName} will be told you declined.`, confirm: 'Decline', run: async () => { await orgApi(`/battle-invites/${b.id}/decline`, { method: 'POST' }); toast('Challenge declined'); route(); } }) }, 'Decline'),
          h('button', { class: 'btn small primary', onclick: async (e) => { e.target.disabled = true; try { await orgApi(`/battle-invites/${b.id}/accept`, { method: 'POST' }); toast('Challenge accepted — your members were notified'); route(); } catch (err) { toast(err.message, true); e.target.disabled = false; } } }, 'Accept'))
          : badge('Awaiting admin', 'amber'))))));
  }
  const grid = h('div');
  const draw = () => {
    const list = r.events.filter((e) => (eventState.scope === 'live' ? e.state !== 'past' : e.state === 'past'));
    grid.replaceChildren(list.length ? h('div', { class: 'event-grid' }, list.map((e) => h('button', { class: 'event-card', type: 'button', onclick: () => openEvent(e.id, r.arenaAvailable) },
      h('div', { class: 'event-meta' }, stateBadge(e.state), badge(FORMATS[e.format] ?? e.format, 'blue', true), e.isBattle && badge(`Battle · ${e.battleOrgs.length} orgs`, 'purple', true), !e.isHost && badge(`Hosted by ${e.hostOrgName}`, '', true)),
      h('h3', {}, e.title),
      h('div', { class: 'hint' }, `${METRICS[e.metric]?.label ?? e.metric}${e.metric === 'arena_reps' && e.arenaExercise ? ` · ${e.arenaExercise}` : ''}${e.venueName ? ` · ${e.venueName}` : ''}`),
      e.reward && h('div', { class: 'hint' }, `🏆 ${e.reward}`),
      h('div', { class: 'event-foot' }, h('span', {}, `${fmtShort(e.startsOn)} – ${fmtDate(e.endsOn)}`), h('span', {}, `${e.myParticipants} of your people joined`)))))
      : emptyState('⚑', eventState.scope === 'live' ? 'No live or upcoming events' : 'No past events', eventState.scope === 'live' ? 'Run a monthly check-in challenge, a running week, an on-ground fitness day — or battle another company.' : null,
        eventState.scope === 'live' && can('admin') && h('button', { class: 'btn primary small', onclick: () => openEventForm(null, r.arenaAvailable) }, 'Create event')));
  };
  draw();
  parts.push(card('Events', 'Members join from the Events tab in the FITKEY app', tabs([['live', 'Live & upcoming'], ['past', 'Past']], eventState.scope, (v) => { eventState.scope = v; draw(); }), grid));
  if (outgoing.length) {
    parts.push(card('Challenges you sent', null, null, h('div', { class: 'list' }, outgoing.map((b) => h('div', { class: 'list-item' },
      h('div', { class: 'grow' }, h('b', {}, `${b.toOrgName} · ${b.title}`), h('small', {}, `Sent ${fmtDate(b.createdAt)}`)),
      b.status === 'pending' ? badge('Waiting for reply', 'amber') : badge('Declined', 'red'),
      can('admin') && b.status === 'pending' && h('button', { class: 'btn small ghost', onclick: () => confirmDialog({ title: 'Cancel challenge?', text: `${b.toOrgName} will no longer see this invite.`, confirm: 'Cancel challenge', run: async () => { await orgApi(`/battle-invites/${b.id}/cancel`, { method: 'POST' }); toast('Challenge cancelled'); route(); } }) }, 'Cancel'))))));
  }
  box.replaceChildren(...parts);
}

async function openEventForm(existing, arenaAvailable) {
  const today = isoDay(new Date());
  const in30 = isoDay(new Date(Date.now() + 29 * 864e5));
  const e = existing ?? {};
  const started = existing && e.startsOn <= today;
  const f = formFields([
    { name: 'title', label: 'Event name', value: e.title ?? '', max: 160, required: true, placeholder: 'e.g. November Move Challenge' },
    { name: 'description', label: 'Description', type: 'textarea', value: e.description ?? '', max: 2000, placeholder: 'What should people do? Any rules?' },
    [{ name: 'format', label: 'Format', type: 'select', value: e.format ?? 'virtual', options: Object.entries(FORMATS) },
      { name: 'metric', label: 'Ranked by', type: 'select', value: e.metric ?? 'checkins', options: Object.entries(METRICS).map(([k, v]) => [k, v.label]) }],
    [{ name: 'startsOn', label: 'Starts', type: 'date', value: e.startsOn ?? today }, { name: 'endsOn', label: 'Ends', type: 'date', value: e.endsOn ?? in30 }],
    { name: 'eventDate', label: 'Event day (on-ground)', type: 'date', value: e.eventDate ?? '' },
    { name: 'arenaExercise', label: 'AI exercise', type: 'select', value: e.arenaExercise ?? 'pushups', options: [['pushups', 'Push-ups'], ['squats', 'Squats'], ['situps', 'Sit-ups'], ['jumping_jacks', 'Jumping jacks'], ['lunges', 'Lunges']],
      hint: arenaAvailable ? 'Scores come from AI-counted sets in the FITKEY Arena.' : 'Scores appear once the AI Arena records attempts.' },
    [{ name: 'reward', label: 'Reward (optional)', value: e.reward ?? '', max: 200, placeholder: 'e.g. Team dinner + trophy' }, { name: 'sponsor', label: 'Sponsor (optional)', value: e.sponsor ?? '', max: 120 }],
  ]);
  // Venue picker (on-ground)
  let venueId = e.venueId ?? null;
  const venueLabel = h('span', { class: 'hint' }, e.venueName ? `Selected: ${e.venueName}` : 'No venue selected');
  const vq = h('input', { class: 'input', type: 'search', placeholder: 'Search live FITKEY centres by name or city' });
  const vlist = h('div', { class: 'list' });
  let vt;
  vq.addEventListener('input', () => { clearTimeout(vt); vt = setTimeout(async () => {
    try {
      const r = await orgApi(`/venues?q=${encodeURIComponent(vq.value.trim())}`);
      vlist.replaceChildren(...r.venues.slice(0, 6).map((v) => h('button', { type: 'button', class: 'list-item btn ghost', style: { justifyContent: 'flex-start' }, onclick: () => { venueId = v.id; venueLabel.textContent = `Selected: ${v.name}, ${v.area ?? ''} ${v.city ?? ''}`; vlist.replaceChildren(); } }, `${v.name} · ${[v.area, v.city].filter(Boolean).join(', ')}`)));
      if (!r.venues.length) vlist.replaceChildren(h('p', { class: 'hint' }, 'No centres match.'));
    } catch (err) { vlist.replaceChildren(h('p', { class: 'err-text' }, err.message)); }
  }, 250); });
  const venueField = h('div', { class: 'field' }, h('span', {}, 'Venue'), vq, vlist, venueLabel);
  const battle = h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'battle' }), h('span', {}, h('b', {}, 'Inter-org battle'), h('br'), h('span', { class: 'hint' }, 'Challenge other companies after creating it; they must accept. Teams are ranked by total score.')));
  const sync = () => {
    const fmt = f.inputs.format.value;
    const metric = f.inputs.metric.value;
    $('[data-field="eventDate"]', f.el).hidden = fmt !== 'onground';
    $('[data-field="arenaExercise"]', f.el).hidden = fmt !== 'ai';
    venueField.hidden = fmt !== 'onground';
    if (fmt === 'ai' && metric !== 'arena_reps') f.inputs.metric.value = 'arena_reps';
    if (fmt !== 'ai' && metric === 'arena_reps') f.inputs.metric.value = 'checkins';
    if (fmt !== 'onground' && metric === 'attendance') f.inputs.metric.value = 'checkins';
  };
  f.inputs.format.addEventListener('change', sync);
  f.inputs.metric.addEventListener('change', () => {
    if (f.inputs.metric.value === 'arena_reps') f.inputs.format.value = 'ai';
    if (f.inputs.metric.value === 'attendance') f.inputs.format.value = 'onground';
    sync();
  });
  if (started) { f.inputs.metric.disabled = true; f.inputs.startsOn.disabled = true; f.inputs.format.disabled = true; }
  sync();
  modal({
    title: existing ? 'Edit event' : 'Create an event', sub: existing ? null : `All verified ${S.org.name} members get an in-app notification.`, wide: true,
    body: h('div', { class: 'stack' }, f.el, venueField, !existing && battle),
    actions: [{ label: 'Cancel', kind: 'ghost' }, { label: existing ? 'Save changes' : 'Create event', kind: 'primary', run: async () => {
      const v = f.values();
      if (v.title.length < 3) throw new Error('Give the event a name');
      if (v.endsOn < v.startsOn) throw new Error('End date must be on or after the start date');
      const body = { title: v.title, description: v.description || null, reward: v.reward || null, sponsor: v.sponsor || null, endsOn: v.endsOn };
      if (!started) Object.assign(body, { format: v.format, metric: v.metric, startsOn: v.startsOn });
      const fmt = started ? e.format : v.format;
      body.eventDate = fmt === 'onground' ? v.eventDate || null : null;
      body.venueId = fmt === 'onground' ? venueId : null;
      body.arenaExercise = fmt === 'ai' ? v.arenaExercise : null;
      if (fmt === 'onground' && (!body.eventDate || !body.venueId)) throw new Error('On-ground events need a venue and an event day');
      if (existing) {
        await orgApi(`/events/${e.id}`, { method: 'PATCH', body });
        toast('Event updated');
      } else {
        body.battle = battle.querySelector('input').checked;
        const r = await orgApi('/events', { method: 'POST', body });
        toast('Event created — members notified');
        if (body.battle) setTimeout(() => openEvent(r.event.id, arenaAvailable), 50);
      }
      route();
    } }],
  });
}

async function openEvent(id, arenaAvailable) {
  const body = h('div', {}, loadingState('rows'));
  const m = modal({ title: 'Event', wide: true, body });
  let data;
  try {
    data = await orgApi(`/events/${id}`);
  } catch (err) {
    body.replaceChildren(errorState(err.message, () => { m.close(); openEvent(id, arenaAvailable); }));
    return;
  }
  const { event: e, leaderboard: lb, invites } = data;
  const unit = METRICS[e.metric]?.unit ?? '';
  m.box.querySelector('.modal-head h2').textContent = e.title;
  const u = (v) => (unit === 'days' && Number(v) === 1 ? 'day' : unit);
  const fmtScore = (v) => (e.metric === 'attendance' ? (Number(v) ? 'Attended' : '—') : `${num(v)} ${u(v)}`);
  const parts = [
    h('div', { class: 'event-meta' }, stateBadge(e.state), badge(FORMATS[e.format], 'blue', true), badge(METRICS[e.metric]?.label ?? e.metric, 'orange', true), lb.teams.length > 0 && badge('Inter-org battle', 'purple', true), !e.isHost && badge(`Hosted by ${e.hostOrgName}`, '', true)),
    h('p', { class: 'muted' }, `${fmtDate(e.startsOn)} – ${fmtDate(e.endsOn)}${e.eventDate ? ` · event day ${fmtDate(e.eventDate)}` : ''}${e.venueName ? ` · ${e.venueName}` : ''}${e.reward ? ` · 🏆 ${e.reward}` : ''}`),
    e.description && h('p', {}, e.description),
    h('div', { class: 'kpis' }, kpi('Your participants', num(lb.entries.length), `${pct(lb.entries.length, data.memberCount)}% of ${num(data.memberCount)} members`), kpi('Everyone in event', num(lb.totalParticipants)), kpi('Ranked by', METRICS[e.metric]?.label ?? e.metric, METRICS[e.metric]?.hint)),
    data.notice && h('p', { class: 'warn-text' }, data.notice),
  ];
  if (lb.teams.length) {
    parts.push(card('Team standings', 'Ranked by total score; other organisations are shown only as team totals.', null,
      h('div', { class: 'podium' }, lb.teams.map((t) => h('div', { class: `team ${t.isMine ? 'mine' : ''}` },
        h('div', { class: `rank ${t.rank === 1 && t.total > 0 ? 'r1' : ''}` }, t.rank),
        h('div', {}, h('b', {}, t.name, t.isMine ? ' (you)' : ''), h('div', { class: 'hint' }, `${t.participants} participant${t.participants === 1 ? '' : 's'} · avg ${num(t.average)} ${u(t.average)}`)),
        h('b', {}, `${num(t.total)} ${u(t.total)}`))))));
  }
  parts.push(card(`${S.org.name} leaderboard`, 'Your employees who joined this event', null,
    lb.entries.length ? h('div', { class: 'table-wrap' }, h('table', {},
      h('thead', {}, h('tr', {}, h('th', {}, 'Rank'), h('th', {}, 'Employee'), h('th', {}, 'Department'), h('th', { class: 'num' }, 'Score'))),
      h('tbody', {}, lb.entries.map((r) => h('tr', {}, h('td', {}, h('div', { class: `rank ${r.rank === 1 && Number(r.score) > 0 ? 'r1' : ''}` }, r.rank)),
        h('td', {}, h('div', { class: 'person' }, h('div', { class: 'avatar' }, initials(r.name)), h('b', {}, r.name || 'Member'))),
        h('td', {}, r.department || '—'), h('td', { class: 'num' }, fmtScore(r.score)))))))
      : emptyState('⚑', 'Nobody from your team has joined yet', 'Employees join from the Events tab in the FITKEY app. Share the event in your team channels!')));

  if (e.isHost && can('admin') && e.state !== 'past') {
    const q = h('input', { class: 'input', type: 'search', placeholder: 'Search organisations by name' });
    const msg = h('input', { class: 'input', placeholder: 'Message (optional)', maxlength: 300 });
    const results = h('div', { class: 'list' });
    let t;
    q.addEventListener('input', () => { clearTimeout(t); t = setTimeout(async () => {
      if (q.value.trim().length < 2) return results.replaceChildren();
      try {
        const r = await orgApi(`/org-search?q=${encodeURIComponent(q.value.trim())}`);
        results.replaceChildren(...(r.orgs.length ? r.orgs.map((o) => h('div', { class: 'list-item' }, h('div', { class: 'avatar' }, initials(o.name)), h('div', { class: 'grow' }, h('b', {}, o.name), h('small', {}, o.kind)),
          h('button', { class: 'btn small primary', onclick: async (ev) => { ev.target.disabled = true; try { await orgApi(`/events/${e.id}/battle-invites`, { method: 'POST', body: { toOrgId: o.id, message: msg.value.trim() || null } }); toast(`Challenge sent to ${o.name}`); m.close(); openEvent(id, arenaAvailable); } catch (err) { toast(err.message, true); ev.target.disabled = false; } } }, 'Challenge')))
          : [h('p', { class: 'hint' }, 'No organisation found. Only companies and colleges on FITKEY can be challenged.')]));
      } catch (err) { results.replaceChildren(h('p', { class: 'err-text' }, err.message)); }
    }, 300); });
    parts.push(card('Challenge another organisation', 'They must accept before they appear in the battle.', null,
      h('div', { class: 'stack' }, h('div', { class: 'grid2' }, q, msg), results,
        invites.length > 0 && h('div', { class: 'chip-list' }, invites.map((i) => badge(`${i.toOrgName}: ${i.status}`, { pending: 'amber', accepted: 'green', declined: 'red', cancelled: '' }[i.status]))))));
  }
  body.replaceChildren(h('div', { class: 'stack' }, ...parts.filter(Boolean)));
  const today = isoDay(new Date());
  m.setActions(e.isHost && can('admin') ? [
    { label: 'Delete', kind: 'ghost', run: () => { confirmDialog({ title: 'Delete this event?', text: lb.totalParticipants ? 'People have joined, so it cannot be deleted. End it early instead.' : 'This cannot be undone.', confirm: 'Delete event', run: async () => { await orgApi(`/events/${e.id}`, { method: 'DELETE' }); toast('Event deleted'); m.close(); route(); } }); return true; } },
    e.state === 'live' && { label: 'End today', run: () => { confirmDialog({ title: 'End this event today?', text: 'The leaderboard freezes at the end of today.', confirm: 'End today', danger: false, run: async () => { await orgApi(`/events/${e.id}`, { method: 'PATCH', body: { endsOn: today } }); toast('Event ends today'); m.close(); route(); } }); return true; } },
    e.state !== 'past' && { label: 'Edit', kind: 'primary', run: () => { m.close(); openEventForm(e, arenaAvailable); } },
  ].filter(Boolean) : []);
}

/* ======================================================================== analytics */

const anState = { days: 30 };

async function renderAnalytics(box) {
  const range = tabs([[7, '7 days'], [30, '30 days'], [90, '90 days'], [365, '12 months']], anState.days, (v) => { anState.days = v; load(); });
  actions(range);
  const content = h('div', { class: 'stack' });
  box.replaceChildren(
    h('div', { class: 'callout green' }, h('div', { class: 'grow' }, h('b', {}, 'Privacy by design'), h('div', { class: 'hint' }, 'Analytics use check-ins, passes and event participation only. FITKEY never shows employers anyone\'s weight, nutrition, steps or other health data — not individually and not in aggregate.'))),
    content);
  const load = () => section(content, async () => {
    const r = await orgApi(`/analytics?days=${anState.days}`);
    const sm = r.summary;
    const series = r.series.map((d) => ({ date: d.date, value: d.checkins, extra: `${d.employees} employee${d.employees === 1 ? '' : 's'}` }));
    const active = r.series.map((d) => ({ date: d.date, value: d.employees }));
    const dows = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const fullDows = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const weekday = dows.map((l, i) => ({ label: l, full: fullDows[i], value: r.weekday.find((w) => w.dow === i + 1)?.checkins ?? 0 }));
    const hasActivity = sm.checkins > 0;
    const tableView = h('div', { hidden: true }, h('div', { class: 'preview-table' }, h('table', {},
      h('thead', {}, h('tr', {}, h('th', {}, 'Date'), h('th', { class: 'num' }, 'Check-ins'), h('th', { class: 'num' }, 'Employees'))),
      h('tbody', {}, r.series.slice().reverse().map((d) => h('tr', {}, h('td', {}, fmtDate(d.date)), h('td', { class: 'num' }, num(d.checkins)), h('td', { class: 'num' }, num(d.employees))))))));
    const chartView = h('div', {}, hasActivity ? lineChart(series, { label: 'Daily check-ins', unit: 'check-ins' }) : emptyState('▥', 'No check-ins in this period', 'Activity appears as soon as employees with passes visit a centre.'));
    const toggle = h('button', { class: 'btn small ghost', onclick: () => { tableView.hidden = !tableView.hidden; chartView.hidden = !tableView.hidden; toggle.textContent = tableView.hidden ? 'View as table' : 'View as chart'; } }, 'View as table');
    return [
      h('div', { class: 'kpis' },
        kpi('Active employees', num(sm.activeEmployees), `${pct(sm.activeEmployees, sm.members)}% of ${num(sm.members)} members`, true),
        kpi('Check-ins', num(sm.checkins), `${sm.activeEmployees ? (sm.checkins / sm.activeEmployees).toFixed(1) : 0} per active employee`),
        kpi('Centres used', num(sm.centresUsed)),
        kpi('Event participants', num(sm.eventParticipants), `${pct(sm.eventParticipants, sm.members)}% of members`),
        kpi('Pass utilisation', `${pct(r.passes.usingPass, r.passes.holders)}%`, `${num(r.passes.usingPass)} of ${num(r.passes.holders)} pass holders checked in`)),
      card('Check-ins per day', `Last ${anState.days} days`, toggle, chartView, tableView),
      h('div', { class: 'cols even' },
        card('Daily active employees', 'Distinct employees checking in each day', null, hasActivity ? lineChart(active, { label: 'Active employees', unit: 'employees' }) : emptyState('☺', 'No activity yet', null)),
        card('Busiest days of the week', 'Check-ins by weekday', null, hasActivity ? barChart(weekday, { unit: 'check-ins' }) : emptyState('▥', 'No activity yet', null))),
      h('div', { class: 'cols even' },
        card('Top centres', 'Where your people work out', null, r.topCentres.length ? hBars(r.topCentres.map((c) => ({ name: c.name, sub: [c.area, c.city].filter(Boolean).join(', '), value: c.checkins, display: `${num(c.checkins)} · ${c.employees} ppl` }))) : emptyState('⌖', 'No centre visits yet', null)),
        card('By department', 'Share of members active in the period', null, r.byDepartment.length ? h('div', { class: 'stack' },
          hBars(r.byDepartment.map((d) => ({ name: d.department, sub: `${num(d.members)} members`, value: pct(d.active, d.members), display: `${pct(d.active, d.members)}%` })), { max: 100 }),
          h('div', { class: 'table-wrap' }, h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, 'Department'), h('th', { class: 'num' }, 'Members'), h('th', { class: 'num' }, 'Active'), h('th', { class: 'num' }, 'Check-ins'))),
            h('tbody', {}, r.byDepartment.map((d) => h('tr', {}, h('td', {}, d.department), h('td', { class: 'num' }, num(d.members)), h('td', { class: 'num' }, num(d.active)), h('td', { class: 'num' }, num(d.checkins)))))))) : emptyState('☺', 'No members yet', 'Departments come from invites (CSV) or can be edited per member.'))),
      card('Event participation', 'Your members in events overlapping this period', null, r.events.length ? hBars(r.events.map((e) => ({ name: e.title, sub: `${fmtShort(e.startsOn)} – ${fmtShort(e.endsOn)} · ${METRICS[e.metric]?.label ?? e.metric}`, value: e.participants, display: `${num(e.participants)} · ${pct(e.participants, sm.members)}%` }))) : emptyState('⚑', 'No events in this period', null, can('admin') && h('a', { class: 'btn small primary', href: '#events' }, 'Create event'))),
    ];
  }, 'page');
  load();
}

/* ======================================================================== billing */

async function renderBilling(box, seq) {
  const [inv, orders, ren] = await Promise.all([orgApi('/invoices'), orgApi('/orders'), orgApi('/renewals')]);
  if (stale(seq)) return;
  actions(can('admin') && h('button', { class: 'btn primary', onclick: () => openBuy() }, 'Buy passes'));
  const due = ren.passes.filter((p) => !p.renewed);
  const byPlan = {};
  for (const p of due) byPlan[p.planId] = { name: p.planName, n: (byPlan[p.planId]?.n ?? 0) + 1 };
  const total = inv.invoices.reduce((a, b) => a + b.amountPaise, 0);
  box.replaceChildren(
    h('div', { class: 'kpis' },
      kpi('Renewals due · 14 days', num(due.length), due.length ? 'Passes expiring soon' : 'Nothing expiring soon', due.length > 0),
      kpi('Invoices', num(inv.invoices.length), `${inr(total)} billed in total`),
      kpi('Payment mode', S.paymentsMode === 'mock' ? 'Mock' : 'Live', S.paymentsMode === 'mock' ? 'No money is collected yet' : 'Gateway payments')),
    card('Renewal reminders', 'Company passes ending in the next 14 days', can('admin') && Object.keys(byPlan).length > 0 && h('div', { class: 'row-actions' }, Object.entries(byPlan).map(([planId, p]) => h('button', { class: 'btn small primary', onclick: () => openBuy({ planId, quantity: p.n }) }, `Renew ${p.n} × ${p.name}`))),
      ren.passes.length ? h('div', { class: 'table-wrap' }, h('table', {},
        h('thead', {}, h('tr', {}, h('th', {}, 'Employee'), h('th', {}, 'Plan'), h('th', {}, 'Ends'), h('th', { class: 'num' }, 'Days left'), h('th', {}))),
        h('tbody', {}, ren.passes.map((p) => h('tr', {},
          h('td', {}, h('div', { class: 'person' }, h('div', { class: 'avatar' }, initials(p.name || p.email)), h('div', {}, h('b', {}, p.name || p.email), h('small', {}, [p.email, p.department].filter(Boolean).join(' · '))))),
          h('td', {}, p.planName), h('td', {}, fmtDate(p.endsAt)), h('td', { class: 'num' }, p.daysLeft <= 3 ? badge(`${p.daysLeft} days`, 'red') : `${p.daysLeft} days`),
          h('td', {}, p.renewed ? badge('Renewed', 'green') : can('admin') && h('div', { class: 'row-actions' }, h('a', { class: 'btn small', href: '#passes' }, 'Reassign'))))))))
        : emptyState('✓', 'No renewals due', 'Passes expiring within 14 days show up here so you can renew in time.')),
    card('Invoices', S.paymentsMode === 'mock' ? 'Mock invoices — recorded honestly, no payment collected, not tax invoices' : null, null,
      inv.invoices.length ? h('div', { class: 'table-wrap' }, h('table', {},
        h('thead', {}, h('tr', {}, h('th', {}, 'Invoice'), h('th', {}, 'Date'), h('th', {}, 'Items'), h('th', { class: 'num' }, 'Amount'), h('th', {}, 'Status'), h('th', {}))),
        h('tbody', {}, inv.invoices.map((i) => h('tr', {},
          h('td', {}, h('b', { class: 'mono' }, i.number)), h('td', {}, fmtDate(i.issuedAt)), h('td', {}, `${num(i.quantity)} × ${i.planName}`),
          h('td', { class: 'num' }, inr(i.amountPaise)),
          h('td', {}, { mock: badge('Mock · unpaid gateway', 'amber'), paid: badge('Paid', 'green'), due: badge('Due', 'red'), void: badge('Void') }[i.status]),
          h('td', {}, h('div', { class: 'row-actions' }, h('button', { class: 'btn small', onclick: () => openInvoice(i.id) }, 'View'))))))))
        : emptyState('₹', 'No invoices yet', 'Buying passes creates an invoice here.')),
    card('Payment history', null, null,
      orders.orders.length ? h('div', { class: 'table-wrap' }, h('table', {},
        h('thead', {}, h('tr', {}, h('th', {}, 'Date'), h('th', {}, 'Order'), h('th', {}, 'Placed by'), h('th', {}, 'Method'), h('th', {}, 'Reference'), h('th', { class: 'num' }, 'Amount'), h('th', {}, 'Status'))),
        h('tbody', {}, orders.orders.map((o) => h('tr', {},
          h('td', {}, fmtDateTime(o.createdAt)), h('td', {}, `${num(o.quantity)} × ${o.planName}`), h('td', {}, o.createdByName || '—'),
          h('td', {}, o.paymentMode === 'mock' ? 'Mock (no gateway)' : o.paymentMode), h('td', { class: 'mono' }, o.paymentRef || '—'),
          h('td', { class: 'num' }, inr(o.amountPaise)),
          h('td', {}, { mock_paid: badge('Recorded · not charged', 'amber'), paid: badge('Paid', 'green'), pending: badge('Pending', 'blue'), cancelled: badge('Cancelled') }[o.status]))))))
        : emptyState('₹', 'No payments yet', null)),
  );
}
async function openInvoice(id) {
  let r;
  try { r = await orgApi(`/invoices/${id}`); } catch (err) { return toast(err.message, true); }
  const i = r.invoice;
  const p = r.profile ?? {};
  const doc = h('div', { class: 'invoice print-area' },
    h('div', { class: 'inv-head' },
      h('div', {}, h('div', { class: 'brand' }, h('span', { class: 'logo' }, 'F'), h('span', {}, 'FITKEY')), h('p', { class: 'hint' }, 'FITKEY Corporate Wellness')),
      h('div', { style: { textAlign: 'right' } }, h('h2', {}, 'Invoice'), h('div', { class: 'mono' }, i.number), h('div', { class: 'hint' }, `Issued ${fmtDate(i.issuedAt)}`), i.status === 'mock' && h('div', { class: 'stamp', style: { marginTop: '8px' } }, 'MOCK · NOT A TAX INVOICE'))),
    h('div', {}, h('div', { class: 'hint' }, 'Billed to'), h('b', {}, p.legalName || r.org.name), [p.address, p.city].filter(Boolean).length > 0 && h('div', {}, [p.address, p.city].filter(Boolean).join(', ')),
      p.gstin && h('div', { class: 'hint' }, `GSTIN ${p.gstin}`), p.billingEmail && h('div', { class: 'hint' }, p.billingEmail)),
    h('table', {}, h('thead', {}, h('tr', {}, h('th', {}, 'Description'), h('th', { class: 'num' }, 'Qty'), h('th', { class: 'num' }, 'Unit price'), h('th', { class: 'num' }, 'Amount'))),
      h('tbody', {}, h('tr', {}, h('td', {}, `${i.planName} pass (${i.durationDays} days)`), h('td', { class: 'num' }, num(i.quantity)), h('td', { class: 'num' }, inr(i.unitPricePaise)), h('td', { class: 'num' }, inr(i.amountPaise))),
        h('tr', {}, h('td', { colspan: 3, class: 'num' }, h('b', {}, 'Total')), h('td', { class: 'num' }, h('b', {}, inr(i.amountPaise)))))),
    h('p', { class: 'fine' }, i.note || '', ' Payment reference: ', h('span', { class: 'mono' }, i.paymentRef || '—'), '. Ordered by ', i.createdByName || 'HR admin', '.'));
  modal({ title: `Invoice ${i.number}`, wide: true, body: doc, actions: [{ label: 'Close', kind: 'ghost' }, { label: 'Print / Save PDF', kind: 'primary', run: () => { window.print(); return true; } }] });
}

/* ======================================================================== settings */

async function renderSettings(box, seq) {
  const [o, a] = await Promise.all([orgApi(''), orgApi('/admins')]);
  if (stale(seq)) return;
  const p = o.profile ?? {};
  S.org.inviteCode = o.org.inviteCode;
  const ro = !can('admin');
  const f = formFields([
    [{ name: 'name', label: 'Display name', value: o.org.name, max: 120 }, { name: 'kind', label: 'Type', type: 'select', value: o.org.kind, options: [['company', 'Company'], ['college', 'College']] }],
    [{ name: 'legalName', label: 'Legal name (for invoices)', value: p.legalName ?? '', max: 160 }, { name: 'industry', label: 'Industry', value: p.industry ?? '', max: 80 }],
    [{ name: 'billingEmail', label: 'Billing email', type: 'email', value: p.billingEmail ?? '' }, { name: 'gstin', label: 'GSTIN', value: p.gstin ?? '', max: 15 }],
    [{ name: 'city', label: 'City', value: p.city ?? '', max: 80 }, { name: 'employeeCount', label: 'Number of employees', type: 'number', min: 0, value: p.employeeCount ?? '' }],
    { name: 'address', label: 'Registered address', value: p.address ?? '', max: 400 },
    { name: 'logoUrl', label: 'Logo URL', value: o.org.logoUrl ?? '', max: 500, placeholder: 'https://…', hint: 'Shown on member badges and events.' },
  ]);
  if (ro) Object.values(f.inputs).forEach((i) => (i.disabled = true));
  const save = !ro && h('button', { class: 'btn primary', onclick: async (e) => {
    e.target.disabled = true;
    try {
      const v = f.values();
      await orgApi('', { method: 'PATCH', body: { ...v, logoUrl: v.logoUrl || null, employeeCount: v.employeeCount === '' ? null : Number(v.employeeCount) } });
      toast('Profile saved');
      const me = await api('/corporate/me');
      S.orgs = me.orgs;
      selectOrg(S.orgs.find((x) => x.id === S.org.id) ?? S.org, false);
      $('#org-select').replaceChildren(...S.orgs.map((x) => h('option', { value: x.id, selected: x.id === S.org.id }, x.name)));
    } catch (err) { toast(err.message, true); } finally { e.target.disabled = false; }
  } }, 'Save profile');

  const domInput = h('input', { class: 'input', placeholder: 'company.com', 'aria-label': 'Email domain' });
  const addDomain = async () => {
    try { await orgApi('/domains', { method: 'POST', body: { domain: domInput.value } }); toast('Domain added'); route(); } catch (err) { toast(err.message, true); }
  };
  domInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') addDomain(); });
  const domains = h('div', { class: 'stack' },
    o.domains.length ? h('div', { class: 'chip-list' }, o.domains.map((d) => h('span', { class: 'chip' }, `@${d}`, !ro && h('button', { 'aria-label': `Remove ${d}`, title: 'Remove', onclick: () => confirmDialog({ title: `Remove @${d}?`, text: 'New employees will no longer be able to verify with this domain. Existing members stay verified.', confirm: 'Remove domain', run: async () => { await orgApi(`/domains/${encodeURIComponent(d)}`, { method: 'DELETE' }); toast('Domain removed'); route(); } }) }, '✕'))))
      : h('p', { class: 'hint' }, 'No domains yet. Add one so employees can verify themselves with a work-email code in the app.'),
    !ro && h('div', { class: 'copy-row' }, domInput, h('button', { class: 'btn', onclick: addDomain }, 'Add domain')),
    h('p', { class: 'fine' }, 'Public email providers (gmail.com, outlook.com …) cannot be added. A domain can belong to only one organisation.'));

  const code = h('div', { class: 'callout orange' }, h('div', { class: 'grow' }, h('div', { class: 'hint' }, 'Org join code'), h('b', { class: 'mono', style: { fontSize: '20px', letterSpacing: '0.1em' } }, o.org.inviteCode || '—'), h('div', { class: 'hint' }, 'For people without a work email (e.g. contractors, students). Anyone with the code can join — rotate it if it leaks.')),
    h('button', { class: 'btn small', onclick: () => copyText(o.org.inviteCode) }, 'Copy'),
    !ro && h('button', { class: 'btn small ghost', onclick: () => confirmDialog({ title: 'Rotate join code?', text: 'The old code stops working immediately. Existing members are not affected.', confirm: 'Rotate code', danger: false, run: async () => { await orgApi('/invite-code', { method: 'POST' }); toast('New join code created'); route(); } }) }, 'Rotate'));

  const owner = can('owner');
  const admins = h('div', { class: 'stack' },
    h('div', { class: 'table-wrap' }, h('table', {},
      h('thead', {}, h('tr', {}, h('th', {}, 'Name'), h('th', {}, 'Phone'), h('th', {}, 'Role'), h('th', {}, 'Added'), h('th', {}))),
      h('tbody', {}, a.admins.map((x) => h('tr', {},
        h('td', {}, h('div', { class: 'person' }, h('div', { class: 'avatar' }, initials(x.name || 'HR')), h('b', {}, x.name || 'Not set', x.userId === a.me ? ' (you)' : ''))),
        h('td', { class: 'mono' }, x.phone),
        h('td', {}, owner ? h('select', { class: 'input', style: { width: 'auto', padding: '5px 8px' }, onchange: async (e) => { try { await orgApi(`/admins/${x.userId}`, { method: 'PATCH', body: { role: e.target.value } }); toast('Role updated'); if (x.userId === a.me) boot(); } catch (err) { toast(err.message, true); e.target.value = x.role; } } },
          ['owner', 'admin', 'viewer'].map((r) => h('option', { value: r, selected: r === x.role }, r[0].toUpperCase() + r.slice(1)))) : badge(x.role, x.role === 'owner' ? 'orange' : x.role === 'admin' ? 'blue' : '', true)),
        h('td', {}, fmtDate(x.createdAt)),
        h('td', {}, owner && h('div', { class: 'row-actions' }, h('button', { class: 'btn small ghost', onclick: () => confirmDialog({ title: `Remove ${x.name || x.phone}?`, text: 'They lose access to this dashboard. Their FITKEY member account is not affected.', confirm: 'Remove admin', run: async () => { await orgApi(`/admins/${x.userId}`, { method: 'DELETE' }); toast('Admin removed'); if (x.userId === a.me) boot(); else route(); } }) }, 'Remove')))))))),
    h('p', { class: 'fine' }, 'Owner: everything, including HR admins. Admin: members, passes, events, billing. Viewer: read-only.'));
  const addAdmin = owner && h('button', { class: 'btn small primary', onclick: () => {
    const af = formFields([{ name: 'phone', label: 'Phone number', inputmode: 'tel', placeholder: '+91 98765 43210', required: true }, { name: 'name', label: 'Name', max: 120 }, { name: 'role', label: 'Role', type: 'select', value: 'admin', options: [['admin', 'Admin'], ['viewer', 'Viewer'], ['owner', 'Owner']] }]);
    modal({ title: 'Add an HR admin', sub: 'They sign in here with this phone number (OTP).', body: af.el, actions: [{ label: 'Cancel', kind: 'ghost' }, { label: 'Add admin', kind: 'primary', run: async () => { const v = af.values(); await orgApi('/admins', { method: 'POST', body: { phone: v.phone, name: v.name || null, role: v.role } }); toast('HR admin added'); route(); } }] });
  } }, '+ Add admin');

  box.replaceChildren(
    h('div', { class: 'cols' },
      card('Company profile', ro ? 'Read-only for viewers' : 'Used on invoices and member badges', save, f.el),
      h('div', { class: 'stack' },
        card('Verified email domains', 'Employees with these email domains can self-verify in the app', null, domains),
        card('Join code', null, null, code))),
    card('HR admins', 'People who can use this dashboard', addAdmin, admins),
    card('Privacy commitment', null, null, h('div', { class: 'stack' },
      h('p', { class: 'muted' }, 'FITKEY for Business shows you how your people use the benefit you pay for — never how their bodies are doing.'),
      h('div', { class: 'grid2' },
        h('div', { class: 'callout green' }, h('div', { class: 'grow' }, h('b', {}, 'You can see'), h('div', { class: 'hint' }, 'Membership & pass status · check-ins and centres visited · event participation and event scores (only for events people choose to join).'))),
        h('div', { class: 'callout orange' }, h('div', { class: 'grow' }, h('b', {}, 'You can never see'), h('div', { class: 'hint' }, 'Weight, body measurements, nutrition & meals, goals, steps, health records or AI-coach conversations — individually or in aggregate.')))),
      h('p', { class: 'fine' }, 'This is enforced by the FITKEY API itself: the corporate endpoints never query health or nutrition tables.'))),
  );
}

/* ======================================================================== start */
boot();

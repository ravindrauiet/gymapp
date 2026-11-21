// FITKEY admin — "Insights" (analytics dashboard), "Users" (directory + User 360) and "Live activity" tabs.
// Loaded by admin.js; talks to /api/v1/admin/insights/*. Charts are drawn as inline SVG because the panel's CSP
// (helmet default: script-src 'self') blocks CDN chart libraries.
const A = window.FitkeyAdmin;
const { h, api, toast, label, assetUrl } = A;

// ------------------------------------------------------------------------------------------------ styles
const CSS = `
.ins-head { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; margin-bottom: 16px; }
.ins-head h2 { margin: 0; }
.ins-seg { display: inline-flex; background: var(--surface); border: 1px solid var(--outline); border-radius: 12px; padding: 3px; gap: 2px; flex-wrap: wrap; }
.ins-seg button { background: transparent; color: var(--muted); padding: 6px 12px; border-radius: 9px; }
.ins-seg button.active { background: var(--surface-2); color: var(--lime); }
.ins-chips { display: flex; gap: 6px; flex-wrap: wrap; }
.ins-chips button { background: var(--surface-2); color: var(--muted); padding: 5px 12px; border-radius: 20px; font-size: 13px; }
.ins-chips button.active { background: rgba(200,243,29,.15); color: var(--lime); }
.ins-kpis { display: grid; gap: 12px; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); margin-bottom: 16px; }
.ins-kpi { background: var(--surface); border: 1px solid var(--outline); border-radius: 14px; padding: 14px 16px; min-width: 0; }
.ins-kpi .k { color: var(--muted); font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: .4px; }
.ins-kpi .v { font-size: 26px; font-weight: 800; line-height: 1.25; margin-top: 2px; font-variant-numeric: tabular-nums; }
.ins-kpi .s { color: var(--muted); font-size: 12px; margin-top: 2px; }
.ins-kpi .s b { color: var(--text); font-weight: 700; }
.ins-kpi.hero { border-color: rgba(200,243,29,.35); }
.ins-kpi.warn .v { color: var(--orange); }
.ins-kpi.click { cursor: pointer; } .ins-kpi.click:hover { border-color: var(--lime); }
.ins-grid2 { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); margin-bottom: 16px; }
.ins-grid3 { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); margin-bottom: 16px; }
.ins-card { background: var(--surface); border: 1px solid var(--outline); border-radius: 16px; padding: 16px 18px; min-width: 0; }
.ins-card h3 { font-size: 15px; margin: 0 0 2px; }
.ins-card .sub { color: var(--muted); font-size: 12px; margin-bottom: 10px; }
.ins-chart { position: relative; width: 100%; }
.ins-chart svg { display: block; width: 100%; overflow: visible; }
.ins-chart .grid { stroke: var(--outline); stroke-width: 1; }
.ins-chart .axis { fill: var(--muted); font-size: 11px; font-family: inherit; }
.ins-chart .xh { stroke: var(--muted); stroke-width: 1; stroke-dasharray: 3 3; }
.ins-tip { position: absolute; pointer-events: none; background: var(--surface-2); border: 1px solid var(--outline); border-radius: 10px; padding: 8px 10px; font-size: 12px; white-space: nowrap; z-index: 2; box-shadow: 0 6px 20px rgba(0,0,0,.35); }
.ins-tip .d { color: var(--muted); margin-bottom: 2px; }
.ins-tip .r { display: flex; gap: 8px; align-items: center; justify-content: space-between; }
.ins-tip .r b { font-variant-numeric: tabular-nums; }
.ins-sw { display: inline-block; width: 10px; height: 10px; border-radius: 3px; flex: none; }
.ins-legend { display: flex; gap: 6px 16px; flex-wrap: wrap; font-size: 12px; color: var(--muted); margin-top: 8px; }
.ins-legend span { display: inline-flex; gap: 6px; align-items: center; }
.ins-legend b { color: var(--text); }
.ins-stack { display: flex; height: 14px; border-radius: 7px; overflow: hidden; gap: 2px; background: var(--surface-2); margin: 6px 0 4px; }
.ins-stack div { height: 100%; min-width: 2px; }
.ins-bars .row1 { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 8px; align-items: baseline; font-size: 13px; padding: 5px 0 2px; }
.ins-bars .row1 .n { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ins-bars .row1 .m { color: var(--muted); font-size: 12px; font-variant-numeric: tabular-nums; }
.ins-bars .row1 .m b { color: var(--text); }
.ins-bar { height: 6px; border-radius: 3px; background: var(--surface-2); overflow: hidden; }
.ins-bar div { height: 100%; border-radius: 3px; background: var(--lime); }
.ins-funnel .st { display: grid; grid-template-columns: 130px minmax(0, 1fr) 120px; gap: 10px; align-items: center; margin: 8px 0; font-size: 13px; }
.ins-funnel .tr { height: 26px; background: var(--surface-2); border-radius: 6px; overflow: hidden; }
.ins-funnel .tr div { height: 100%; background: linear-gradient(90deg, rgba(200,243,29,.85), rgba(200,243,29,.55)); border-radius: 6px; min-width: 2px; }
.ins-funnel .num { text-align: right; font-variant-numeric: tabular-nums; }
.ins-funnel .num small { display: block; color: var(--muted); font-size: 11px; }
.ins-mini { display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); gap: 10px; }
.ins-mini > div { background: var(--surface-2); border-radius: 12px; padding: 10px 12px; min-width: 0; }
.ins-mini .k { color: var(--muted); font-size: 12px; }
.ins-mini .v { font-size: 18px; font-weight: 800; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
.ins-mini > div.click { cursor: pointer; } .ins-mini > div.click:hover { outline: 1px solid var(--lime); }
.ins-mini > div.alert .v { color: var(--orange); }
.ins-table { width: 100%; border-collapse: collapse; font-size: 13px; }
.ins-table th, .ins-table td { padding: 8px 8px; }
.ins-table td.num, .ins-table th.num { text-align: right; font-variant-numeric: tabular-nums; }
.ins-table tbody tr.click { cursor: pointer; } .ins-table tbody tr.click:hover { background: var(--surface-2); }
.ins-scroll { overflow-x: auto; }
.ins-av { width: 34px; height: 34px; border-radius: 50%; display: inline-grid; place-items: center; font-weight: 800; font-size: 13px; color: #000; flex: none; object-fit: cover; background: var(--surface-2); }
.ins-av.lg { width: 64px; height: 64px; font-size: 24px; }
.ins-who { display: flex; gap: 10px; align-items: center; min-width: 0; }
.ins-who .nm { font-weight: 700; } .ins-who .ph { color: var(--muted); font-size: 12px; }
.ins-toolbar { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; margin-bottom: 12px; }
.ins-toolbar input, .ins-toolbar select { width: auto; margin: 0; padding: 8px 12px; }
.ins-toolbar input[type=search] { flex: 1; min-width: 200px; }
.ins-pager { display: flex; gap: 10px; align-items: center; justify-content: flex-end; margin-top: 12px; flex-wrap: wrap; }
.ins-skel { background: linear-gradient(90deg, var(--surface-2) 0%, #2a2f38 50%, var(--surface-2) 100%); background-size: 200% 100%; animation: ins-sh 1.2s infinite linear; border-radius: 10px; }
@keyframes ins-sh { from { background-position: 200% 0; } to { background-position: -200% 0; } }
.ins-dim { opacity: .55; transition: opacity .15s; pointer-events: none; }
.ins-backdrop { position: fixed; inset: 0; background: rgba(0,0,0,.55); z-index: 30; }
.ins-drawer { position: fixed; top: 0; right: 0; bottom: 0; width: min(1000px, 100vw); background: var(--bg); border-left: 1px solid var(--outline); z-index: 31; overflow-y: auto; box-shadow: -10px 0 40px rgba(0,0,0,.4); animation: ins-in .18s ease-out; }
@keyframes ins-in { from { transform: translateX(40px); opacity: 0; } to { transform: none; opacity: 1; } }
.ins-dhead { position: sticky; top: 0; z-index: 3; background: var(--surface); border-bottom: 1px solid var(--outline); padding: 16px 20px 0; }
.ins-dbody { padding: 18px 20px 40px; }
.ins-dtop { display: flex; gap: 14px; align-items: flex-start; flex-wrap: wrap; }
.ins-dtop .info { flex: 1; min-width: 220px; }
.ins-dtop h2 { margin: 0; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.ins-meta { color: var(--muted); font-size: 13px; display: flex; gap: 4px 14px; flex-wrap: wrap; margin-top: 4px; }
.ins-meta b { color: var(--text); font-weight: 600; }
.ins-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.ins-actions button { padding: 7px 12px; font-size: 13px; }
.ins-dtabs { display: flex; gap: 2px; overflow-x: auto; margin-top: 14px; }
.ins-dtabs button { background: transparent; color: var(--muted); border-radius: 10px 10px 0 0; padding: 8px 14px; white-space: nowrap; border-bottom: 2px solid transparent; }
.ins-dtabs button.active { color: var(--lime); border-bottom-color: var(--lime); }
.ins-banner { background: rgba(255,84,112,.12); border: 1px solid rgba(255,84,112,.4); color: var(--danger); border-radius: 12px; padding: 10px 14px; margin-top: 12px; font-size: 13px; }
.ins-sec { margin-bottom: 20px; }
.ins-sec > h3 { font-size: 14px; color: var(--muted); text-transform: uppercase; letter-spacing: .5px; margin: 0 0 10px; }
.ins-tl { position: relative; }
.ins-day { color: var(--muted); font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: .5px; margin: 14px 0 6px; }
.ins-ev { display: grid; grid-template-columns: 36px minmax(0, 1fr) auto; gap: 10px; align-items: center; padding: 8px 10px; border-radius: 12px; }
.ins-ev:hover { background: var(--surface); }
.ins-ev.fresh { animation: ins-fresh 2.5s ease-out; }
@keyframes ins-fresh { from { background: rgba(200,243,29,.18); } to { background: transparent; } }
.ins-ic { width: 36px; height: 36px; border-radius: 50%; display: grid; place-items: center; font-size: 17px; background: var(--surface-2); }
.ins-ev .t { font-weight: 600; overflow: hidden; text-overflow: ellipsis; }
.ins-ev .dt { color: var(--muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ins-ev .rt { text-align: right; font-size: 12px; color: var(--muted); white-space: nowrap; }
.ins-ev .rt b { display: block; color: var(--lime); font-size: 13px; }
.ins-ulink { color: var(--sky); cursor: pointer; font-weight: 600; background: none; padding: 0; border-radius: 0; font-size: inherit; }
.ins-ulink:hover { text-decoration: underline; }
.ins-modal { position: fixed; inset: 0; z-index: 40; display: grid; place-items: center; background: rgba(0,0,0,.55); padding: 16px; }
.ins-modal form { width: min(440px, 100%); }
.ins-live { display: inline-flex; gap: 6px; align-items: center; color: var(--muted); font-size: 13px; font-weight: 600; margin: 0; }
.ins-live input { width: auto; margin: 0; }
.ins-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--lime); display: inline-block; animation: ins-pulse 1.6s infinite; }
@keyframes ins-pulse { 50% { opacity: .3; } }
.ins-empty { color: var(--muted); padding: 24px 0; text-align: center; }
.pill.ins-ok { background: rgba(200,243,29,.15); color: var(--lime); }
.pill.ins-bad { background: rgba(255,84,112,.15); color: var(--danger); }
.pill.ins-warn { background: rgba(255,107,53,.15); color: var(--orange); }
.pill.ins-info { background: rgba(76,201,240,.15); color: var(--sky); }
@media (max-width: 640px) {
  .ins-grid2 { grid-template-columns: 1fr; }
  .ins-funnel .st { grid-template-columns: 90px minmax(0, 1fr) 84px; }
  .ins-kpi .v { font-size: 22px; }
  .ins-dhead, .ins-dbody { padding-left: 14px; padding-right: 14px; }
}
`;
if (!document.getElementById('ins-css')) document.head.append(h('style', { id: 'ins-css' }, CSS));

// ------------------------------------------------------------------------------------------------ formatting
const n = (v) => Number(v ?? 0);
const num = (v) => n(v).toLocaleString('en-IN');
/** Paise → "₹1,23,456" (whole rupees, paise only when present). compact: ₹4.5L / ₹1.2Cr. */
function inr(paise, compact = false) {
  const r = n(paise) / 100;
  const a = Math.abs(r);
  if (compact && a >= 1e7) return `₹${(r / 1e7).toFixed(a >= 1e8 ? 1 : 2)}Cr`;
  if (compact && a >= 1e5) return `₹${(r / 1e5).toFixed(a >= 1e6 ? 1 : 2)}L`;
  return `₹${r.toLocaleString('en-IN', { maximumFractionDigits: Number.isInteger(r) || compact ? 0 : 2 })}`;
}
const pct = (a, b) => (n(b) > 0 ? `${Math.round((n(a) / n(b)) * 1000) / 10}%` : '—');
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** "2026-11-21" → "21 Nov" (date-only strings are not shifted by time zone). */
const dayLabel = (d) => { const [y, m, dd] = String(d).slice(0, 10).split('-'); return `${+dd} ${MON[+m - 1]}${y && +y !== new Date().getFullYear() ? ` ${y.slice(2)}` : ''}`; };
const date = (iso) => (iso ? (/^\d{4}-\d{2}-\d{2}$/.test(String(iso)) ? dayLabel(iso) : new Date(iso).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })) : '—');
const dateTime = (iso) => (iso ? new Date(iso).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' }) : '—');
const time = (iso) => new Date(iso).toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit' });
function ago(iso) {
  if (!iso) return 'never';
  const s = (Date.now() - new Date(iso).getTime()) / 1000;
  if (s < 0) return 'just now';
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  if (s < 86400 * 30) return `${Math.floor(s / 86400)} d ago`;
  if (s < 86400 * 365) return `${Math.floor(s / 86400 / 30)} mo ago`;
  return `${Math.floor(s / 86400 / 365)} y ago`;
}
function age(birth) {
  if (!birth) return null;
  const b = new Date(birth);
  if (Number.isNaN(b.getTime())) return null;
  const t = new Date();
  let a = t.getFullYear() - b.getFullYear();
  if (t.getMonth() < b.getMonth() || (t.getMonth() === b.getMonth() && t.getDate() < b.getDate())) a--;
  return a;
}
const initials = (name, phone) => (name ? name.trim().split(/\s+/).slice(0, 2).map((w) => w[0]).join('').toUpperCase() : String(phone ?? '?').slice(-2));
const AV_COLORS = ['#c8f31d', '#4cc9f0', '#ff6b35', '#c49bff', '#ffd166', '#06d6a0'];
function avatar(u, large = false) {
  const cls = `ins-av${large ? ' lg' : ''}`;
  if (u.avatarUrl) return h('img', { class: cls, src: assetUrl(u.avatarUrl), alt: '' });
  const hash = [...String(u.id ?? u.phone ?? '')].reduce((a, c) => a + c.charCodeAt(0), 0);
  return h('span', { class: cls, style: `background:${AV_COLORS[hash % AV_COLORS.length]}` }, initials(u.name, u.phone));
}
const pill = (text, kind = '') => h('span', { class: `pill ${kind}` }, text);
const STATUS_KIND = {
  active: 'ins-ok', paid: 'ins-ok', fulfilled: 'ins-ok', delivered: 'ins-ok', confirmed: 'ins-ok', completed: 'ins-ok', attended: 'ins-ok', rewarded: 'ins-ok', joined: 'ins-ok',
  pending: 'ins-warn', created: 'ins-warn', placed: 'ins-warn', processing: 'ins-warn', booked: 'ins-info', shipped: 'ins-info', upcoming: 'ins-info',
  cancelled: 'ins-bad', failed: 'ins-bad', expired: 'ins-bad', refunded: 'ins-bad', no_show: 'ins-bad', rejected: 'ins-bad',
};
const statusPill = (s) => (s ? pill(label(String(s)), STATUS_KIND[s] ?? '') : '—');

// Categorical series colours, validated for the panel's dark surface (#171a1f): lightness band, CVD separation, contrast.
const SERIES = ['#7f9e0c', '#2f94b5', '#e0592a', '#9474d6'];
const LIME = '#c8f31d';

function skel(height, width = '100%') { return h('div', { class: 'ins-skel', style: `height:${height}px;width:${width}` }); }
function card(title, sub, ...body) { return h('div', { class: 'ins-card' }, h('h3', {}, title), sub ? h('div', { class: 'sub' }, sub) : null, ...body); }
function openTab(key) { document.querySelector(`#tabs [data-tab="${key}"]`)?.click(); }

// ------------------------------------------------------------------------------------------------ SVG charts
const SVGNS = 'http://www.w3.org/2000/svg';
function s(tag, attrs = {}, ...children) {
  const el = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs)) if (v != null && v !== false) el.setAttribute(k, v);
  for (const c of children.flat()) if (c != null) el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  return el;
}
function niceMax(v, integer) {
  if (!(v > 0)) return integer ? 4 : 1;
  const p = 10 ** Math.floor(Math.log10(v));
  let m = [1, 2, 2.5, 5, 10].map((x) => x * p).find((x) => x >= v);
  if (integer) m = Math.max(4, Math.ceil(m / 4) * 4);
  return m;
}
const shortNum = (v) => (v >= 1e7 ? `${+(v / 1e7).toFixed(2)}Cr` : v >= 1e5 ? `${+(v / 1e5).toFixed(2)}L` : v >= 1e3 ? `${+(v / 1e3).toFixed(2)}k` : `${+v.toFixed(2)}`);

/**
 * Responsive line/area or column chart with a crosshair tooltip.
 * opts: { labels: ['YYYY-MM-DD'…], series: [{ name, color, values }], type: 'line'|'bar', fmt, axisFmt, height, integer }
 */
function chart(opts) {
  const { labels, series, type = 'line', height = 190, integer = true } = opts;
  const fmt = opts.fmt ?? num;
  const axisFmt = opts.axisFmt ?? shortNum;
  const wrap = h('div', { class: 'ins-chart', style: `height:${height}px` });
  const tip = h('div', { class: 'ins-tip', hidden: true });
  const nPts = labels.length;
  const max = niceMax(Math.max(0, ...series.flatMap((x) => x.values.map(n))), integer);
  let lastW = 0;

  function draw() {
    const W = wrap.clientWidth;
    if (!W || W === lastW) return;
    lastW = W;
    const pad = { l: 40, r: 10, t: 8, b: 22 };
    const iw = Math.max(10, W - pad.l - pad.r);
    const ih = height - pad.t - pad.b;
    const band = iw / Math.max(1, nPts);
    const xAt = (i) => (type === 'bar' ? pad.l + band * i + band / 2 : pad.l + (nPts > 1 ? (iw * i) / (nPts - 1) : iw / 2));
    const yAt = (v) => pad.t + ih - (n(v) / max) * ih;
    const svg = s('svg', { viewBox: `0 0 ${W} ${height}`, height, role: 'img', 'aria-label': opts.aria ?? series.map((x) => x.name).join(', ') });

    for (let k = 0; k <= 4; k++) {
      const v = (max / 4) * k;
      const y = yAt(v);
      svg.append(s('line', { class: 'grid', x1: pad.l, x2: W - pad.r, y1: y, y2: y, 'stroke-opacity': k === 0 ? 1 : 0.5 }));
      svg.append(s('text', { class: 'axis', x: pad.l - 6, y: y + 4, 'text-anchor': 'end' }, axisFmt(v)));
    }
    const ticks = Math.min(nPts, Math.max(2, Math.floor(iw / 70)));
    const step = Math.max(1, Math.round((nPts - 1) / Math.max(1, ticks - 1)));
    for (let i = 0; i < nPts; i += step) {
      const x = xAt(i);
      svg.append(s('text', { class: 'axis', x, y: height - 5, 'text-anchor': i === 0 && type !== 'bar' ? 'start' : 'middle' }, dayLabel(labels[i])));
    }

    if (type === 'bar') {
      const per = series.length;
      const groupW = Math.max(1, band * 0.72);
      const bw = Math.max(1, groupW / per - (per > 1 ? 2 : 0));
      series.forEach((sr, si) => sr.values.forEach((v, i) => {
        if (!n(v)) return;
        const x = xAt(i) - groupW / 2 + si * (groupW / per);
        const y = yAt(v);
        const bh = pad.t + ih - y;
        const r = Math.min(4, bw / 2, bh);
        svg.append(s('path', {
          d: `M${x},${pad.t + ih}V${y + r}Q${x},${y} ${x + r},${y}H${x + bw - r}Q${x + bw},${y} ${x + bw},${y + r}V${pad.t + ih}Z`,
          fill: sr.color,
        }));
      }));
    } else {
      series.forEach((sr, si) => {
        const pts = sr.values.map((v, i) => `${xAt(i).toFixed(1)},${yAt(v).toFixed(1)}`);
        if (series.length === 1 && opts.area !== false) {
          const gid = `ins-g${Math.random().toString(36).slice(2, 8)}`;
          svg.append(s('defs', {}, s('linearGradient', { id: gid, x1: 0, x2: 0, y1: 0, y2: 1 },
            s('stop', { offset: '0%', 'stop-color': sr.color, 'stop-opacity': 0.28 }),
            s('stop', { offset: '100%', 'stop-color': sr.color, 'stop-opacity': 0 }))));
          svg.append(s('path', { d: `M${xAt(0)},${pad.t + ih}L${pts.join('L')}L${xAt(nPts - 1)},${pad.t + ih}Z`, fill: `url(#${gid})` }));
        }
        svg.append(s('polyline', { points: pts.join(' '), fill: 'none', stroke: sr.color, 'stroke-width': 2, 'stroke-linejoin': 'round', 'stroke-linecap': 'round' }));
        if (nPts === 1) svg.append(s('circle', { cx: xAt(0), cy: yAt(sr.values[0]), r: 4, fill: sr.color }));
        void si;
      });
    }

    // hover layer
    const cross = s('line', { class: 'xh', y1: pad.t, y2: pad.t + ih, visibility: 'hidden' });
    const dots = series.map((sr) => s('circle', { r: 4, fill: sr.color, stroke: '#171a1f', 'stroke-width': 2, visibility: 'hidden' }));
    svg.append(cross, ...dots);
    const hit = s('rect', { x: pad.l, y: pad.t, width: iw, height: ih, fill: 'transparent' });
    svg.append(hit);
    const move = (ev) => {
      const rect = svg.getBoundingClientRect();
      const px = ((ev.clientX - rect.left) / rect.width) * W;
      let i = type === 'bar' ? Math.floor((px - pad.l) / band) : Math.round(((px - pad.l) / iw) * (nPts - 1));
      i = Math.max(0, Math.min(nPts - 1, i));
      const x = xAt(i);
      cross.setAttribute('x1', x); cross.setAttribute('x2', x); cross.setAttribute('visibility', 'visible');
      dots.forEach((d, k) => {
        d.setAttribute('cx', type === 'bar' ? x : x); d.setAttribute('cy', yAt(series[k].values[i]));
        d.setAttribute('visibility', type === 'bar' ? 'hidden' : 'visible');
      });
      tip.replaceChildren(h('div', { class: 'd' }, dayLabel(labels[i])),
        ...series.map((sr) => h('div', { class: 'r' }, h('span', { style: 'display:inline-flex;gap:6px;align-items:center' },
          h('span', { class: 'ins-sw', style: `background:${sr.color}` }), sr.name), h('b', {}, fmt(sr.values[i])))));
      tip.hidden = false;
      const tx = (x / W) * rect.width;
      const tw = tip.offsetWidth;
      tip.style.left = `${Math.max(0, Math.min(rect.width - tw, tx + 12 > rect.width - tw ? tx - tw - 12 : tx + 12))}px`;
      tip.style.top = '4px';
    };
    hit.addEventListener('mousemove', move);
    hit.addEventListener('touchstart', (e) => move(e.touches[0]), { passive: true });
    hit.addEventListener('mouseleave', () => { tip.hidden = true; cross.setAttribute('visibility', 'hidden'); dots.forEach((d) => d.setAttribute('visibility', 'hidden')); });
    wrap.replaceChildren(svg, tip);
  }
  new ResizeObserver(() => draw()).observe(wrap);
  const out = h('div', {}, wrap);
  if (series.length > 1) {
    out.append(h('div', { class: 'ins-legend' }, series.map((sr) =>
      h('span', {}, h('span', { class: 'ins-sw', style: `background:${sr.color}` }), sr.name,
        h('b', {}, fmt(sr.values.reduce((a, v) => a + n(v), 0)))))));
  }
  return out;
}

/** Stacked share bar + legend: parts [{ name, value }] (value already numeric), fmt for legend values. */
function shareBar(parts, fmt = num) {
  const total = parts.reduce((a, p) => a + n(p.value), 0);
  const colored = parts.map((p, i) => ({ ...p, color: p.color ?? SERIES[i % SERIES.length] }));
  return h('div', {},
    h('div', { class: 'ins-stack' }, total > 0
      ? colored.filter((p) => n(p.value) > 0).map((p) => h('div', { style: `flex:${n(p.value)};background:${p.color}`, title: `${p.name}: ${fmt(p.value)} (${pct(p.value, total)})` }))
      : null),
    h('div', { class: 'ins-legend' }, colored.map((p) =>
      h('span', {}, h('span', { class: 'ins-sw', style: `background:${p.color}` }), p.name, h('b', {}, fmt(p.value)), total > 0 ? `${pct(p.value, total)}` : ''))),
  );
}

/** Ranked list with inline bars: rows [{ name, value, meta }]. */
function rankBars(rows, empty = 'No data in this period.') {
  if (!rows.length) return h('div', { class: 'ins-empty' }, empty);
  const max = Math.max(1, ...rows.map((r) => n(r.value)));
  return h('div', { class: 'ins-bars' }, rows.map((r) => h('div', {},
    h('div', { class: 'row1' }, h('span', { class: 'n', title: r.name }, r.name), h('span', { class: 'm' }, r.meta)),
    h('div', { class: 'ins-bar' }, h('div', { style: `width:${(n(r.value) / max) * 100}%` })))));
}

// ------------------------------------------------------------------------------------------------ 1. Insights
const ins = { days: 30, cache: {} };

async function insightsView() {
  const root = h('div', {});
  const body = h('div', {});
  const periods = h('div', { class: 'ins-seg' }, [7, 30, 90, 365].map((d) =>
    h('button', { class: d === ins.days ? 'active' : '', 'data-d': d, onclick: () => { ins.days = d; periods.querySelectorAll('button').forEach((b) => b.classList.toggle('active', +b.dataset.d === d)); load(); } },
      d === 365 ? '1 year' : `${d} days`)));
  const stamp = h('span', { class: 'muted', style: 'font-size:12px' });
  root.append(h('div', { class: 'ins-head' }, h('h2', {}, 'Insights'), h('span', { class: 'muted' }, 'Everything happening on FITKEY'),
    h('span', { class: 'spacer' }), stamp, periods, h('button', { class: 'ghost', onclick: () => { delete ins.cache[ins.days]; load(); } }, 'Refresh')), body);

  async function load() {
    const days = ins.days;
    if (ins.cache[days]) body.replaceChildren(renderOverview(ins.cache[days].data));
    else if (body.childElementCount) body.classList.add('ins-dim');
    else body.replaceChildren(overviewSkeleton());
    try {
      const data = await api(`/admin/insights/overview?days=${days}`);
      ins.cache[days] = { data, at: new Date() };
      if (days !== ins.days) return;
      body.replaceChildren(renderOverview(data));
      stamp.textContent = `Updated ${time(new Date())}`;
    } catch (err) {
      if (!ins.cache[days]) body.replaceChildren(h('p', { class: 'muted' }, err.message));
      toast(err.message, true);
    } finally {
      body.classList.remove('ins-dim');
    }
  }
  load();
  return root;
}

function overviewSkeleton() {
  return h('div', {},
    h('div', { class: 'ins-kpis' }, Array.from({ length: 12 }, () => h('div', { class: 'ins-kpi' }, skel(12, '60%'), h('div', { style: 'height:8px' }), skel(28, '45%'), h('div', { style: 'height:6px' }), skel(10, '70%')))),
    h('div', { class: 'ins-grid2' }, Array.from({ length: 4 }, () => h('div', { class: 'ins-card' }, skel(14, '40%'), h('div', { style: 'height:12px' }), skel(190)))),
  );
}

function kpi(k, v, sub, { hero, warn, tab, title } = {}) {
  return h('div', { class: `ins-kpi${hero ? ' hero' : ''}${warn ? ' warn' : ''}${tab ? ' click' : ''}`, title: title ?? null, onclick: tab ? () => openTab(tab) : null },
    h('div', { class: 'k' }, k), h('div', { class: 'v' }, v), sub ? h('div', { class: 's' }, sub) : null);
}
const subs = (...parts) => parts;

function renderOverview(o) {
  const k = o.kpis ?? {};
  const r = o.revenue ?? {};
  const series = o.series ?? [];
  const labels = series.map((d) => d.day);
  const col = (key) => series.map((d) => n(d[key]));
  const per = o.days === 365 ? 'last year' : `last ${o.days} days`;
  const revTotal = n(r.subscriptions) + n(r.walletPasses) + n(r.memberships) + n(r.store);
  const p = o.partners ?? {};
  const e = o.engagement ?? {};
  const f = o.funnel;

  const kpis = h('div', { class: 'ins-kpis' },
    kpi('Members', num(k.members), subs(h('b', {}, `+${num(k.newMembers)}`), ` in ${o.days}d · `, h('b', {}, `+${num(k.newToday)}`), ' today'), { hero: true, tab: 'users' }),
    kpi('Active today (DAU)', num(k.activeToday), subs(h('b', {}, pct(k.activeToday, k.members)), ' of members')),
    kpi('Active 7 days (WAU)', num(k.active7d), subs(h('b', {}, pct(k.active7d, k.members)), ' of members')),
    kpi('Active 30 days (MAU)', num(k.active30d), subs(h('b', {}, pct(k.active30d, k.members)), ' · stickiness ', h('b', {}, pct(k.activeToday, k.active30d)))),
    kpi('Paying members', num(k.payingMembers), subs(h('b', {}, pct(k.payingMembers, k.members)), ' conversion')),
    kpi('Active passes', num(k.activePasses), subs(h('b', {}, num(k.activeMemberships)), ' venue memberships')),
    kpi('Check-ins today', num(k.checkinsToday), subs(h('b', {}, num(k.checkinsPeriod)), ` in ${o.days}d`)),
    kpi(`Revenue · ${o.days}d`, inr(revTotal, true), subs('online ', h('b', {}, inr(r.collectedOnline, true))), { hero: true, title: inr(revTotal) }),
    kpi('Commission earned', inr(r.commission, true), subs('owed to venues ', h('b', {}, inr(r.owedToVenues, true)))),
    kpi('Refunded', inr(r.refunded, true), subs(h('b', {}, pct(r.refunded, r.collectedOnline)), ' of online'), { warn: n(r.refunded) > 0 }),
    kpi('Store orders', num(k.ordersPeriod), `in ${o.days}d`),
    kpi('Venues awaiting review', num(k.pendingVenues), subs(h('b', {}, num(k.liveVenues)), ' live'), { warn: n(k.pendingVenues) > 0, tab: 'partners' }),
    kpi('Plans pending', num(p.plansPending), 'centre plans to approve', { warn: n(p.plansPending) > 0, tab: 'partners' }),
    kpi('Open payouts', num(p.payoutsOpen), subs(h('b', {}, inr(p.payoutsOpenPaise, true)), ' to pay'), { warn: n(p.payoutsOpen) > 0, tab: 'partners' }),
    kpi('Suspended', num(k.suspended), subs(h('b', {}, num(k.reportsPeriod)), ` reports in ${o.days}d`), { warn: n(k.suspended) > 0 }),
    kpi('Partners', num(k.partners), 'partner accounts'),
  );

  const revenueCard = card('Revenue by source', `${per} · ${inr(revTotal)} total`,
    shareBar([
      { name: 'FitKey plans', value: n(r.subscriptions) },
      { name: 'Wallet passes', value: n(r.walletPasses) },
      { name: 'Memberships', value: n(r.memberships) },
      { name: 'Store', value: n(r.store) },
    ], (v) => inr(v, true)),
    h('div', { class: 'ins-mini', style: 'margin-top:12px' },
      h('div', {}, h('div', { class: 'k' }, 'Collected online'), h('div', { class: 'v' }, inr(r.collectedOnline, true))),
      h('div', {}, h('div', { class: 'k' }, 'Commission'), h('div', { class: 'v' }, inr(r.commission, true))),
      h('div', {}, h('div', { class: 'k' }, 'Owed to venues'), h('div', { class: 'v' }, inr(r.owedToVenues, true))),
      h('div', { class: n(r.refunded) ? 'alert' : '' }, h('div', { class: 'k' }, 'Refunded'), h('div', { class: 'v' }, inr(r.refunded, true)))));

  const charts = h('div', { class: 'ins-grid2' },
    card('Daily active members', 'Members who checked in, booked, logged a meal or workout, synced steps, posted or did ProveIt',
      chart({ labels, series: [{ name: 'Active members', color: LIME, values: col('activeUsers') }] })),
    card('Revenue per day', `${per} · plans, passes, memberships and store`,
      chart({ labels, type: 'bar', integer: false, series: [{ name: 'Revenue', color: LIME, values: col('revenuePaise') }], fmt: (v) => inr(v), axisFmt: (v) => `₹${shortNum(v / 100)}` })),
    card('Signups per day', `${num(col('signups').reduce((a, b) => a + b, 0))} new members`,
      chart({ labels, type: 'bar', series: [{ name: 'Signups', color: LIME, values: col('signups') }] })),
    card('Check-ins & slot bookings', `${num(col('checkins').reduce((a, b) => a + b, 0))} check-ins · ${num(col('bookings').reduce((a, b) => a + b, 0))} bookings`,
      chart({ labels, series: [{ name: 'Check-ins', color: SERIES[0], values: col('checkins') }, { name: 'Bookings', color: SERIES[1], values: col('bookings') }] })),
  );

  const engagementChart = card('Engagement per day', 'Meals logged, step syncs, ProveIt attempts and FitFeed posts',
    chart({ labels, height: 220, series: [
      { name: 'Meals', color: SERIES[0], values: col('meals') },
      { name: 'Step syncs', color: SERIES[1], values: col('stepSyncs') },
      { name: 'ProveIt', color: SERIES[2], values: col('proveit') },
      { name: 'Posts', color: SERIES[3], values: col('posts') },
    ] }));

  let funnelCard;
  if (f) {
    const steps = [['Signed up', f.signedUp], ['Profile done', f.profileDone], ['Purchased', f.purchased], ['Checked in', f.checkedIn], ['Regulars (3+ visits)', f.regulars]];
    const top = Math.max(1, n(f.signedUp));
    funnelCard = card('Activation funnel', `Members who joined in the ${per}`,
      h('div', { class: 'ins-funnel' }, steps.map(([name, v], i) => h('div', { class: 'st' },
        h('span', {}, name),
        h('div', { class: 'tr' }, h('div', { style: `width:${(n(v) / top) * 100}%` })),
        h('div', { class: 'num' }, h('b', {}, num(v)), h('small', {}, i === 0 ? '100%' : `${pct(v, steps[i - 1][1])} of prev · ${pct(v, top)}`))))));
  } else funnelCard = card('Activation funnel', 'Unavailable', h('div', { class: 'ins-empty' }, 'Funnel query failed on the server.'));

  const engagementBlock = card('Engagement · last 7 days', 'Across all members',
    h('div', { class: 'ins-mini' },
      h('div', {}, h('div', { class: 'k' }, 'Avg steps / day'), h('div', { class: 'v' }, num(e.avgSteps7d)), h('div', { class: 'k' }, `${num(e.stepUsers7d)} members`)),
      h('div', {}, h('div', { class: 'k' }, 'Meals logged'), h('div', { class: 'v' }, num(e.meals7d)), h('div', { class: 'k' }, `${num(e.mealUsers7d)} members`)),
      h('div', {}, h('div', { class: 'k' }, 'ProveIt attempts'), h('div', { class: 'v' }, num(e.proveit7d))),
      h('div', {}, h('div', { class: 'k' }, 'Trips tracked'), h('div', { class: 'v' }, num(e.trips7d)), h('div', { class: 'k' }, `${num(e.tripKm7d)} km`)),
      h('div', {}, h('div', { class: 'k' }, 'FitFeed posts'), h('div', { class: 'v' }, num(e.posts7d))),
      h('div', {}, h('div', { class: 'k' }, 'Referrals'), h('div', { class: 'v' }, num(e.referrals7d)))),
    h('div', { style: 'margin-top:14px' }, h('div', { class: 'sub', style: 'margin:0' }, 'Step data source · members, last 30 days'),
      (o.stepSources ?? []).length ? shareBar(o.stepSources.map((x) => ({ name: label(x.source), value: n(x.members) }))) : h('div', { class: 'muted', style: 'font-size:13px' }, 'No step syncs yet.')));

  const tile = (k2, v, tab, alert) => h('div', { class: `${tab ? 'click' : ''}${alert ? ' alert' : ''}`, onclick: tab ? () => openTab(tab) : null },
    h('div', { class: 'k' }, k2), h('div', { class: 'v' }, v));
  const partnerBlock = card('Partner health', 'Supply side — click to open the queue',
    h('div', { class: 'ins-mini' },
      tile('Live venues', num(p.liveVenues), 'venues'),
      tile('Venues in review', num(p.venuesInReview), 'partners', n(p.venuesInReview) > 0),
      tile('Venue drafts', num(p.venueDrafts), 'partners'),
      tile('Trainers', num(p.trainers)),
      tile('Store sellers', num(p.storeSellers)),
      tile('Plans pending', num(p.plansPending), 'partners', n(p.plansPending) > 0),
      tile('Open payouts', num(p.payoutsOpen), 'partners', n(p.payoutsOpen) > 0),
      tile('Payout amount', inr(p.payoutsOpenPaise, true), 'partners')));

  const cities = card('Top cities', 'All members by city',
    rankBars((o.topCities ?? []).map((c) => ({ name: c.city, value: c.members, meta: h('span', {}, h('b', {}, num(c.members)), ` · ${pct(c.members, k.members)}`) })), 'No members yet.'));
  const venues = card('Top venues', `By check-ins · ${per}`,
    rankBars((o.topVenues ?? []).map((v) => ({ name: `${v.name}${v.city ? ` · ${v.city}` : ''}`, value: v.checkins, meta: h('span', {}, h('b', {}, num(v.checkins)), ` check-ins · ${num(v.members)} members`) }))));
  const exercises = card('Top ProveIt exercises', `By attempts · ${per}`,
    rankBars((o.topExercises ?? []).map((x) => ({ name: label(x.exerciseId ?? '—'), value: x.attempts, meta: h('span', {}, h('b', {}, num(x.attempts)), ` · ${num(x.members)} members · best ${num(x.best)}`) }))));

  return h('div', {},
    kpis,
    h('div', { class: 'ins-grid2' }, revenueCard, funnelCard),
    charts,
    h('div', { style: 'margin-bottom:16px' }, engagementChart),
    h('div', { class: 'ins-grid2' }, engagementBlock, partnerBlock),
    h('div', { class: 'ins-grid3' }, cities, venues, exercises),
  );
}

// ------------------------------------------------------------------------------------------------ 2. Users directory
const SEGMENTS = [['all', 'All'], ['new', 'New (7d)'], ['active', 'Active (7d)'], ['inactive', 'Inactive (30d+)'], ['paying', 'Paying'], ['never_paid', 'Never paid'], ['suspended', 'Suspended']];
const SORTS = [['recent', 'Newest first'], ['last_seen', 'Last active'], ['spend', 'Top spenders'], ['checkins', 'Most check-ins']];
const usr = { q: '', segment: 'all', city: '', sort: 'recent', page: 1, limit: 50, last: null };

async function usersView() {
  const tableBox = h('div', {});
  const countEl = h('span', { class: 'muted' });
  const search = h('input', { type: 'search', placeholder: 'Search name, phone or email…', value: usr.q });
  let timer;
  search.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => { usr.q = search.value.trim(); usr.page = 1; load(); }, 300); });
  const cityList = h('datalist', { id: 'ins-cities' });
  const city = h('input', { placeholder: 'City', list: 'ins-cities', value: usr.city, style: 'width:150px' });
  city.addEventListener('change', () => { usr.city = city.value.trim(); usr.page = 1; load(); });
  const sort = h('select', { onchange: (e) => { usr.sort = e.target.value; usr.page = 1; load(); } },
    SORTS.map(([v, t]) => h('option', { value: v, selected: v === usr.sort }, t)));
  const limit = h('select', { title: 'Rows per page', onchange: (e) => { usr.limit = +e.target.value; usr.page = 1; load(); } },
    [25, 50, 100, 200].map((v) => h('option', { value: v, selected: v === usr.limit }, `${v} / page`)));
  const chips = h('div', { class: 'ins-chips' }, SEGMENTS.map(([v, t]) =>
    h('button', { class: v === usr.segment ? 'active' : '', 'data-v': v, onclick: () => { usr.segment = v; usr.page = 1; chips.querySelectorAll('button').forEach((b) => b.classList.toggle('active', b.dataset.v === v)); load(); } }, t)));
  const exportBtn = h('button', { class: 'ghost', onclick: () => exportCsv() }, 'Export CSV');

  // City suggestions from the overview (if loaded) or the API.
  const cachedCities = Object.values(ins.cache)[0]?.data?.topCities;
  const fillCities = (list) => cityList.replaceChildren(...list.filter((c) => c.city !== 'Unknown').map((c) => h('option', { value: c.city })));
  if (cachedCities) fillCities(cachedCities);
  else api('/admin/insights/overview?days=7').then((d) => { ins.cache[7] = { data: d, at: new Date() }; fillCities(d.topCities ?? []); }).catch(() => {});

  const root = h('div', {},
    h('div', { class: 'ins-head' }, h('h2', {}, 'Users'), countEl, h('span', { class: 'spacer' }), exportBtn),
    h('div', { class: 'ins-toolbar' }, search, city, cityList, sort, limit),
    h('div', { style: 'margin-bottom:12px' }, chips),
    h('div', { class: 'ins-card', style: 'padding:6px 10px' }, tableBox));

  let seq = 0;
  async function load() {
    const my = ++seq;
    if (!tableBox.childElementCount) tableBox.replaceChildren(usersSkeleton());
    else tableBox.classList.add('ins-dim');
    const qs = new URLSearchParams({ segment: usr.segment, sort: usr.sort, page: usr.page, limit: usr.limit });
    if (usr.q) qs.set('q', usr.q);
    if (usr.city) qs.set('city', usr.city);
    try {
      const d = await api(`/admin/insights/users?${qs}`);
      if (my !== seq) return;
      usr.last = d;
      countEl.textContent = `${num(d.total)} member${d.total === 1 ? '' : 's'}`;
      tableBox.replaceChildren(usersTable(d, load));
    } catch (err) {
      if (my === seq) tableBox.replaceChildren(h('p', { class: 'muted', style: 'padding:12px' }, err.message));
    } finally {
      if (my === seq) tableBox.classList.remove('ins-dim');
    }
  }
  usersView.reload = load;
  load();
  return root;
}

function usersSkeleton() {
  return h('div', {}, Array.from({ length: 8 }, () => h('div', { style: 'display:flex;gap:12px;align-items:center;padding:10px 4px' },
    h('div', { class: 'ins-skel', style: 'width:34px;height:34px;border-radius:50%' }), skel(14, '30%'), skel(14, '15%'), skel(14, '20%'))));
}

function usersTable(d, reload) {
  if (!d.users.length) return h('div', { class: 'ins-empty' }, 'No members match these filters.');
  const from = (d.page - 1) * d.limit + 1;
  const to = from + d.users.length - 1;
  const pages = Math.max(1, Math.ceil(d.total / d.limit));
  return h('div', {},
    h('div', { class: 'ins-scroll' }, h('table', { class: 'ins-table' },
      h('thead', {}, h('tr', {}, ['Member', 'City', 'Joined', 'Last active', 'Check-ins', 'Spend', 'Pass', ''].map((t, i) =>
        h('th', { class: i === 4 || i === 5 ? 'num' : '' }, t)))),
      h('tbody', {}, d.users.map((u) => h('tr', { class: 'click', onclick: () => openUser(u.id) },
        h('td', {}, h('div', { class: 'ins-who' }, avatar(u), h('div', { style: 'min-width:0' },
          h('div', { class: 'nm' }, u.name || 'No name yet'), h('div', { class: 'ph' }, u.phone, u.email ? ` · ${u.email}` : '')))),
        h('td', {}, u.city || '—'),
        h('td', { title: dateTime(u.createdAt) }, date(u.createdAt)),
        h('td', { title: dateTime(u.lastSeenAt) }, ago(u.lastSeenAt)),
        h('td', { class: 'num' }, num(u.checkins)),
        h('td', { class: 'num' }, n(u.spendPaise) ? inr(u.spendPaise) : h('span', { class: 'muted' }, '—')),
        h('td', {}, u.hasActivePass ? pill('Active', 'ins-ok') : h('span', { class: 'muted' }, 'None')),
        h('td', {}, u.isSuspended ? pill('Suspended', 'ins-bad') : ''),
      ))))),
    h('div', { class: 'ins-pager' },
      h('span', { class: 'muted' }, `${num(from)}–${num(to)} of ${num(d.total)}`),
      h('button', { class: 'ghost', disabled: d.page <= 1, onclick: () => { usr.page = d.page - 1; reload(); } }, '‹ Prev'),
      h('span', {}, `Page ${d.page} / ${pages}`),
      h('button', { class: 'ghost', disabled: d.page >= pages, onclick: () => { usr.page = d.page + 1; reload(); } }, 'Next ›')),
  );
}

function exportCsv() {
  const d = usr.last;
  if (!d?.users?.length) return toast('Nothing to export', true);
  const cols = ['id', 'name', 'phone', 'email', 'city', 'gender', 'createdAt', 'lastSeenAt', 'checkins', 'spendRupees', 'hasActivePass', 'isSuspended'];
  const esc = (v) => { const t = v == null ? '' : String(v); return /[",\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t; };
  const lines = [cols.join(','), ...d.users.map((u) => cols.map((c) => esc(c === 'spendRupees' ? n(u.spendPaise) / 100 : u[c])).join(','))];
  const blob = new Blob([`﻿${lines.join('\n')}`], { type: 'text/csv;charset=utf-8' });
  const a = h('a', { href: URL.createObjectURL(blob), download: `fitkey-users-${usr.segment}-p${d.page}-${new Date().toISOString().slice(0, 10)}.csv` });
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
  toast(`Exported ${d.users.length} rows`);
}

// ------------------------------------------------------------------------------------------------ activity timeline
const GROUPS = [['all', 'All'], ['money', 'Money'], ['visits', 'Visits'], ['fitness', 'Fitness'], ['social', 'Social'], ['signups', 'Signups']];
const EV = {
  signup: ['👋', 'rgba(200,243,29,.15)'], checkin: ['📍', 'rgba(76,201,240,.15)'], booking: ['📅', 'rgba(76,201,240,.15)'],
  purchase: ['💳', 'rgba(200,243,29,.15)'], order: ['🛍️', 'rgba(200,243,29,.15)'], payment: ['💰', 'rgba(200,243,29,.15)'],
  meal: ['🍽️', 'rgba(255,107,53,.15)'], steps: ['👟', 'rgba(255,107,53,.15)'], workout: ['🏋️', 'rgba(255,107,53,.15)'],
  trip: ['🚴', 'rgba(255,107,53,.15)'], proveit: ['🏆', 'rgba(255,107,53,.15)'], weight: ['⚖️', 'rgba(255,107,53,.15)'],
  post: ['📝', 'rgba(196,155,255,.15)'], comment: ['💬', 'rgba(196,155,255,.15)'], referral: ['🤝', 'rgba(196,155,255,.15)'],
  coins: ['🪙', 'rgba(255,209,102,.15)'], trainer: ['🧑‍🏫', 'rgba(76,201,240,.15)'], rating: ['⭐', 'rgba(255,209,102,.15)'],
  circle: ['👥', 'rgba(196,155,255,.15)'], event: ['🎟️', 'rgba(196,155,255,.15)'], report: ['🚩', 'rgba(255,84,112,.18)'],
};
const dayKey = (iso) => new Date(iso).toLocaleDateString('en-CA');
function dayHeading(iso) {
  const k = dayKey(iso);
  const t = new Date();
  if (k === t.toLocaleDateString('en-CA')) return 'Today';
  t.setDate(t.getDate() - 1);
  if (k === t.toLocaleDateString('en-CA')) return 'Yesterday';
  return new Date(iso).toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
}

/**
 * Event timeline with group chips and "Load more". base: '/admin/insights/activity' or '/admin/insights/users/:id/activity'.
 * Returns { el, refresh } — refresh() prepends events newer than the newest shown.
 */
function timeline(base, { showUser = false, limit = 60, state = { type: 'all' } } = {}) {
  const list = h('div', { class: 'ins-tl' });
  const more = h('button', { class: 'ghost', hidden: true, onclick: () => fetchPage(true) }, 'Load more');
  let nextBefore = null;
  let newest = null;
  let lastDay = null;
  let seq = 0;
  const chips = h('div', { class: 'ins-chips' }, GROUPS.map(([v, t]) =>
    h('button', { class: v === state.type ? 'active' : '', 'data-v': v, onclick: () => { state.type = v; chips.querySelectorAll('button').forEach((b) => b.classList.toggle('active', b.dataset.v === v)); fetchPage(false); } }, t)));

  function row(e, fresh) {
    const [icon, bg] = EV[e.type] ?? ['•', 'var(--surface-2)'];
    const who = showUser && e.userId
      ? h('button', { class: 'ins-ulink', onclick: (ev) => { ev.stopPropagation(); openUser(e.userId); } }, e.userName || e.userPhone || 'Member')
      : null;
    return h('div', { class: `ins-ev${fresh ? ' fresh' : ''}` },
      h('div', { class: 'ins-ic', style: `background:${bg}`, title: label(e.type) }, icon),
      h('div', { style: 'min-width:0' },
        h('div', { class: 't' }, who, who ? ' · ' : '', e.title),
        h('div', { class: 'dt' }, [label(e.type), e.detail, showUser && e.userPhone && e.userName ? e.userPhone : null].filter(Boolean).join(' · '))),
      h('div', { class: 'rt', title: dateTime(e.at) }, e.amountPaise != null ? h('b', {}, inr(e.amountPaise)) : null, time(e.at)));
  }
  function append(events) {
    for (const e of events) {
      const dk = dayKey(e.at);
      if (dk !== lastDay) { list.append(h('div', { class: 'ins-day' }, dayHeading(e.at))); lastDay = dk; }
      list.append(row(e));
    }
  }
  async function fetchPage(older) {
    const my = ++seq;
    const qs = new URLSearchParams({ type: state.type, limit });
    if (older && nextBefore) qs.set('before', nextBefore);
    if (!older) {
      list.replaceChildren(...Array.from({ length: 6 }, () => h('div', { class: 'ins-ev' }, h('div', { class: 'ins-skel', style: 'width:36px;height:36px;border-radius:50%' }), h('div', {}, skel(13, '50%'), h('div', { style: 'height:5px' }), skel(10, '30%')), skel(12, '40px'))));
      more.hidden = true;
    } else more.disabled = true;
    try {
      const d = await api(`${base}?${qs}`);
      if (my !== seq) return;
      if (!older) {
        list.replaceChildren();
        lastDay = null;
        newest = d.events[0]?.at ?? null;
        if (!d.events.length) list.append(h('div', { class: 'ins-empty' }, 'No activity yet.'));
      }
      append(d.events);
      nextBefore = d.nextBefore;
      more.hidden = !nextBefore;
    } catch (err) {
      if (my === seq) { if (!older) list.replaceChildren(h('p', { class: 'muted' }, err.message)); else toast(err.message, true); }
    } finally {
      more.disabled = false;
    }
  }
  async function refresh() {
    if (!newest) return fetchPage(false);
    const my = seq;
    const d = await api(`${base}?${new URLSearchParams({ type: state.type, limit })}`);
    if (my !== seq) return 0;
    const fresh = d.events.filter((e) => new Date(e.at) > new Date(newest));
    if (!fresh.length) return 0;
    if (fresh.length >= limit) { fetchPage(false); return fresh.length; }
    newest = fresh[0].at;
    // Fresh events are newer than everything shown: insert them right under the top day heading when they share its
    // day, otherwise prepend with their own heading(s).
    const first = list.firstElementChild;
    const topDay = first?.classList.contains('ins-day') ? first.textContent : null;
    const sameDay = document.createDocumentFragment(); // belongs under the existing top heading
    const newer = document.createDocumentFragment(); // later days, with their own headings
    let cur = null;
    for (const e of fresh) {
      const hd = dayHeading(e.at);
      if (hd === topDay) { sameDay.append(row(e, true)); continue; }
      if (hd !== cur) { cur = hd; newer.append(h('div', { class: 'ins-day' }, hd)); }
      newer.append(row(e, true));
    }
    if (topDay) first.after(sameDay);
    list.prepend(newer);
    list.querySelector('.ins-empty')?.remove();
    return fresh.length;
  }
  fetchPage(false);
  return { el: h('div', {}, h('div', { style: 'margin-bottom:8px' }, chips), list, h('div', { style: 'text-align:center;margin-top:12px' }, more)), refresh };
}

// ------------------------------------------------------------------------------------------------ 3. Live activity
const live = { auto: true, state: { type: 'all' } };
async function liveView() {
  const tl = timeline('/admin/insights/activity', { showUser: true, state: live.state });
  const stamp = h('span', { class: 'muted', style: 'font-size:12px' }, `Updated ${time(new Date())}`);
  const dot = h('span', { class: 'ins-dot', hidden: !live.auto });
  const toggle = h('input', { type: 'checkbox', checked: live.auto, onchange: (e) => { live.auto = e.target.checked; dot.hidden = !live.auto; } });
  const root = h('div', {},
    h('div', { class: 'ins-head' }, h('h2', {}, 'Live activity'), dot, h('span', { class: 'muted' }, 'Every member action across FITKEY'),
      h('span', { class: 'spacer' }), stamp,
      h('label', { class: 'ins-live' }, toggle, 'Auto-refresh 30 s'),
      h('button', { class: 'ghost', onclick: () => tick(true) }, 'Refresh')),
    h('div', { class: 'ins-card' }, tl.el));
  async function tick(manual) {
    try {
      const added = await tl.refresh();
      stamp.textContent = `Updated ${time(new Date())}${added ? ` · ${added} new` : ''}`;
      if (manual) toast(added ? `${added} new event${added === 1 ? '' : 's'}` : 'No new activity');
    } catch (err) {
      if (manual) toast(err.message, true);
    }
  }
  const iv = setInterval(() => {
    if (!root.isConnected) return clearInterval(iv);
    if (live.auto && document.visibilityState === 'visible') tick(false);
  }, 30_000);
  return root;
}

// ------------------------------------------------------------------------------------------------ User 360 drawer
const drawer = { id: null, tab: 'overview', el: null, backdrop: null, data: null, tlState: { type: 'all' } };
const DTABS = [['overview', 'Overview'], ['activity', 'Activity'], ['passes', 'Passes'], ['money', 'Orders & payments'], ['visits', 'Visits'], ['health', 'Health'], ['proveit', 'ProveIt'], ['social', 'Social']];

function closeUser() {
  drawer.el?.remove(); drawer.backdrop?.remove();
  drawer.el = drawer.backdrop = null; drawer.id = null; drawer.data = null;
  document.removeEventListener('keydown', escClose);
}
function escClose(e) { if (e.key === 'Escape' && !document.querySelector('.ins-modal')) closeUser(); }

async function openUser(id, { keepTab = false } = {}) {
  if (!drawer.el) {
    drawer.backdrop = h('div', { class: 'ins-backdrop', onclick: closeUser });
    drawer.el = h('aside', { class: 'ins-drawer', role: 'dialog', 'aria-label': 'Member profile' });
    document.body.append(drawer.backdrop, drawer.el);
    document.addEventListener('keydown', escClose);
  }
  if (!keepTab || drawer.id !== id) { drawer.tab = 'overview'; drawer.tlState = { type: 'all' }; }
  drawer.id = id;
  if (!keepTab) {
    drawer.el.replaceChildren(h('div', { class: 'ins-dhead', style: 'padding-bottom:16px' },
      h('div', { class: 'ins-dtop' }, h('div', { class: 'ins-skel', style: 'width:64px;height:64px;border-radius:50%' }),
        h('div', { class: 'info' }, skel(22, '40%'), h('div', { style: 'height:8px' }), skel(12, '70%'), h('div', { style: 'height:6px' }), skel(12, '55%')),
        h('button', { class: 'ghost', onclick: closeUser }, '✕'))),
    h('div', { class: 'ins-dbody' }, h('div', { class: 'ins-mini' }, Array.from({ length: 12 }, () => h('div', {}, skel(10, '60%'), h('div', { style: 'height:6px' }), skel(18, '40%'))))));
    drawer.el.scrollTop = 0;
  }
  try {
    const d = await api(`/admin/insights/users/${id}`);
    if (drawer.id !== id || !drawer.el) return;
    drawer.data = d;
    renderDrawer();
  } catch (err) {
    if (!drawer.el) return;
    drawer.el.replaceChildren(h('div', { class: 'ins-dbody' }, h('div', { class: 'row' }, h('p', { class: 'muted' }, err.message), h('span', { class: 'spacer' }), h('button', { class: 'ghost', onclick: closeUser }, 'Close'))));
  }
}

function renderDrawer() {
  const d = drawer.data;
  const u = d.user;
  const st = d.stats ?? {};
  const a = age(u.birthDate);
  const body = h('div', { class: 'ins-dbody' });
  const tabs = h('div', { class: 'ins-dtabs' }, DTABS.map(([k, t]) =>
    h('button', { class: k === drawer.tab ? 'active' : '', 'data-k': k, onclick: () => { drawer.tab = k; tabs.querySelectorAll('button').forEach((b) => b.classList.toggle('active', b.dataset.k === k)); fillBody(); } }, t)));
  const metaItem = (k, v) => (v ? h('span', {}, `${k} `, h('b', {}, v)) : null);
  const head = h('div', { class: 'ins-dhead' },
    h('div', { class: 'ins-dtop' },
      avatar(u, true),
      h('div', { class: 'info' },
        h('h2', {}, u.name || 'No name yet',
          u.isSuspended ? pill('Suspended', 'ins-bad') : pill('Active', 'ins-ok'),
          u.role && u.role !== 'user' ? pill(label(u.role), 'ins-info') : null),
        h('div', { class: 'ins-meta' },
          h('span', {}, h('b', {}, u.phone)), u.email ? h('span', {}, u.email) : null,
          u.city ? h('span', {}, u.city) : null, u.gender ? h('span', {}, label(u.gender)) : null,
          a != null ? h('span', {}, `${a} yrs`) : null),
        h('div', { class: 'ins-meta' },
          metaItem('Joined', `${date(u.createdAt)} (${ago(u.createdAt)})`),
          metaItem('Last active', ago(u.lastSeenAt)),
          metaItem('Referral code', u.referralCode),
          u.referredByName || u.referredById
            ? h('span', {}, 'Referred by ', u.referredById ? h('button', { class: 'ins-ulink', onclick: () => openUser(u.referredById) }, u.referredByName || 'member') : h('b', {}, u.referredByName))
            : null)),
      h('div', { class: 'ins-actions' },
        h('button', { class: 'ghost', onclick: () => notifyDialog(u) }, '🔔 Notify'),
        h('button', { class: 'ghost', onclick: () => coinsDialog(u, d.wallet) }, '🪙 Coins'),
        u.isSuspended
          ? h('button', { onclick: () => suspendDialog(u, false) }, 'Restore')
          : h('button', { class: 'danger', onclick: () => suspendDialog(u, true) }, 'Suspend'),
        h('button', { class: 'ghost', title: 'Copy member ID', onclick: () => navigator.clipboard?.writeText(u.id).then(() => toast('Member ID copied')) }, 'ID'),
        h('button', { class: 'ghost', title: 'Close (Esc)', onclick: closeUser }, '✕'))),
    u.isSuspended ? h('div', { class: 'ins-banner' }, `Suspended ${u.suspendedAt ? ago(u.suspendedAt) : ''}${u.suspendedReason ? ` — ${u.suspendedReason}` : ''}`) : null,
    tabs);

  function fillBody() {
    const map = { overview: secOverview, activity: secActivity, passes: secPasses, money: secMoney, visits: secVisits, health: secHealth, proveit: secProveit, social: secSocial };
    body.replaceChildren(map[drawer.tab](d, st));
  }
  drawer.el.replaceChildren(head, body);
  fillBody();
}

const tbl = (cols, rows, empty = 'Nothing yet.') => (rows.length
  ? h('div', { class: 'ins-card', style: 'padding:4px 10px' }, h('div', { class: 'ins-scroll' }, h('table', { class: 'ins-table' },
    h('thead', {}, h('tr', {}, cols.map((c) => h('th', { class: c.num ? 'num' : '' }, c.t)))),
    h('tbody', {}, rows.map((r) => h('tr', {}, cols.map((c) => h('td', { class: c.num ? 'num' : '' }, c.v(r) ?? '—'))))))))
  : h('div', { class: 'ins-card ins-empty' }, empty));
const sec = (title, ...c) => h('div', { class: 'ins-sec' }, h('h3', {}, title), ...c);
const mini = (items) => h('div', { class: 'ins-mini' }, items.filter(Boolean).map(([k, v, alert]) => h('div', { class: alert ? 'alert' : '' }, h('div', { class: 'k' }, k), h('div', { class: 'v' }, v))));

function secOverview(d, st) {
  const w = d.wallet ?? {};
  const g = d.health?.goal;
  const lastSteps = d.health?.steps ?? [];
  return h('div', {},
    sec('Lifetime stats', mini([
      ['Total spend', inr(st.spendPaise)],
      ['Check-ins', num(st.checkins)],
      ['Venues visited', num(st.venuesVisited)],
      ['Last check-in', st.lastCheckinAt ? ago(st.lastCheckinAt) : '—'],
      ['Slot bookings', num(st.bookings)],
      ['Meals logged', num(st.meals)],
      ['Workouts', num(st.workouts)],
      ['Trips', `${num(st.trips)} · ${n(st.tripKm).toLocaleString('en-IN')} km`],
      ['Avg steps (7d)', num(st.avgSteps7d)],
      ['ProveIt attempts', num(st.proveitAttempts)],
      ['FitFeed posts', num(st.posts)],
      ['Friends invited', num(st.invited)],
      ['Reports against', num(st.reportsAgainst), n(st.reportsAgainst) > 0],
    ])),
    sec('Wallet', d.wallet ? mini([
      ['FitKey coins', num(w.fitkey)],
      w.fitkeyExpiresAt ? ['Coins expire', date(w.fitkeyExpiresAt)] : null,
      ['Sessions left', num(w.sessionsLeft)],
      w.sessionsExpiresAt ? ['Sessions expire', date(w.sessionsExpiresAt)] : null,
      ['Bonus / referral coins', num(w.referral)],
      ['Locked referral coins', num(w.referralLocked)],
      ['ProveIt coins', num(w.proveit)],
    ]) : h('div', { class: 'ins-card ins-empty' }, 'Wallet unavailable.')),
    lastSteps.length ? sec('Steps · last 30 days', h('div', { class: 'ins-card' }, stepsChart(lastSteps))) : null,
    g ? sec('Goal', h('div', { class: 'ins-card' }, goalView(g))) : null,
  );
}

function goalView(g) {
  const skip = new Set(['id', 'userId', 'createdAt', 'updatedAt']);
  return mini(Object.entries(g).filter(([k, v]) => !skip.has(k) && v != null && typeof v !== 'object').map(([k, v]) => [label(k.replace(/([A-Z])/g, '_$1').toLowerCase()), typeof v === 'number' ? num(v) : String(v)]));
}

/** Fill the last N days so gaps show as zero. */
function lastDays(count, rows, key) {
  const byDate = Object.fromEntries(rows.map((r) => [r.date, r]));
  const out = [];
  const t = new Date();
  for (let i = count - 1; i >= 0; i--) {
    const dd = new Date(t); dd.setDate(t.getDate() - i);
    const k = dd.toLocaleDateString('en-CA');
    out.push({ date: k, v: n(byDate[k]?.[key]) });
  }
  return out;
}
function stepsChart(steps) {
  const days = lastDays(30, steps, 'steps');
  return chart({ labels: days.map((x) => x.date), type: 'bar', height: 160, series: [{ name: 'Steps', color: LIME, values: days.map((x) => x.v) }] });
}

function secActivity(d) {
  return h('div', {}, timeline(`/admin/insights/users/${d.user.id}/activity`, { state: drawer.tlState, limit: 50 }).el);
}

function secPasses(d) {
  const p = d.passes ?? {};
  return h('div', {},
    sec(`FitKey plans (${(p.subscriptions ?? []).length})`, tbl([
      { t: 'Plan', v: (r) => r.name }, { t: 'Status', v: (r) => statusPill(r.status) },
      { t: 'Period', v: (r) => `${date(r.startsAt)} → ${date(r.endsAt)}` }, { t: 'Amount', num: true, v: (r) => inr(r.amountPaise) },
      { t: 'Payment ref', v: (r) => (r.paymentRef ? h('code', {}, r.paymentRef) : '—') }, { t: 'Bought', v: (r) => dateTime(r.createdAt) },
    ], p.subscriptions ?? [], 'No FitKey plans bought.')),
    sec(`Wallet passes (${(p.purchases ?? []).length})`, tbl([
      { t: 'Pass', v: (r) => r.name }, { t: 'Kind', v: (r) => label(r.kind ?? '—') },
      { t: 'Paid', num: true, v: (r) => inr(r.paidPaise) },
      { t: 'Coins left', num: true, v: (r) => (r.coins ? `${num(r.coinsRemaining)} / ${num(r.coins)}` : '—') },
      { t: 'Sessions', num: true, v: (r) => (r.sessionsTotal ? num(r.sessionsTotal) : '—') },
      { t: 'Expires', v: (r) => (r.expiresAt ? h('span', { class: new Date(r.expiresAt) < new Date() ? 'muted' : '' }, date(r.expiresAt)) : '—') },
      { t: 'Bought', v: (r) => dateTime(r.createdAt) },
    ], p.purchases ?? [], 'No wallet passes bought.')),
    sec(`Venue memberships (${(p.memberships ?? []).length})`, tbl([
      { t: 'Plan', v: (r) => r.planName }, { t: 'Venue', v: (r) => r.venueName }, { t: 'Duration', v: (r) => (r.duration ? label(String(r.duration)) : '—') },
      { t: 'Period', v: (r) => `${date(r.startsOn)} → ${date(r.endsOn)}` }, { t: 'Status', v: (r) => statusPill(r.status) },
      { t: 'Amount', num: true, v: (r) => inr(r.amountPaise) },
    ], p.memberships ?? [], 'No venue memberships.')),
  );
}

function secMoney(d) {
  const pays = d.payments ?? [];
  const refunded = pays.reduce((a, p) => a + n(p.refundedPaise), 0);
  return h('div', {},
    sec(`Payments (${pays.length})`,
      refunded ? h('p', { class: 'muted', style: 'margin:0 0 8px' }, `Refunded so far: ${inr(refunded)}`) : null,
      tbl([
        { t: 'When', v: (r) => dateTime(r.createdAt) }, { t: 'Purpose', v: (r) => h('div', {}, label(r.purpose ?? '—'), r.description ? h('div', { class: 'muted', style: 'font-size:12px' }, r.description) : null) },
        { t: 'Status', v: (r) => h('div', {}, statusPill(r.status), r.error ? h('div', { style: 'color:var(--danger);font-size:12px' }, r.error) : null) },
        { t: 'Amount', num: true, v: (r) => inr(r.amountPaise) },
        { t: 'Refunded', num: true, v: (r) => (n(r.refundedPaise) ? h('span', { style: 'color:var(--danger)' }, inr(r.refundedPaise)) : '—') },
        { t: 'Razorpay ID', v: (r) => (r.razorpayPaymentId ? h('code', {}, r.razorpayPaymentId) : '—') },
      ], pays, 'No online payments.')),
    sec(`Store orders (${(d.orders ?? []).length})`, tbl([
      { t: 'When', v: (r) => dateTime(r.createdAt) }, { t: 'Order', v: (r) => h('code', { title: r.id }, String(r.id).slice(0, 8)) },
      { t: 'Items', num: true, v: (r) => num(r.items) }, { t: 'Status', v: (r) => statusPill(r.status) },
      { t: 'Payment', v: (r) => h('span', {}, label(r.paymentMethod ?? '—'), ' ', statusPill(r.paymentStatus)) },
      { t: 'Total', num: true, v: (r) => inr(r.totalAmountPaise) }, { t: 'Payable', num: true, v: (r) => inr(r.payablePaise ?? r.totalAmountPaise) },
      { t: 'Coins used', num: true, v: (r) => (n(r.coinsRedeemed) ? num(r.coinsRedeemed) : '—') },
    ], d.orders ?? [], 'No store orders.')),
  );
}

function secVisits(d) {
  const r = d.recent ?? {};
  return h('div', {},
    sec('Recent check-ins', tbl([
      { t: 'When', v: (x) => dateTime(x.checkedInAt) }, { t: 'Venue', v: (x) => x.venueName },
      { t: 'Method', v: (x) => (x.method ? label(x.method) : '—') }, { t: 'Paid via', v: (x) => (x.paidVia ? label(x.paidVia) : '—') },
      { t: 'Cost', v: (x) => x.costLabel || '—' },
    ], r.checkins ?? [], 'No check-ins yet.')),
    sec('Recent slot bookings', tbl([
      { t: 'Slot', v: (x) => `${date(x.slotDate)} · ${String(x.slotStart ?? '').slice(0, 5)}` }, { t: 'Venue', v: (x) => x.venueName },
      { t: 'Status', v: (x) => statusPill(x.status) }, { t: 'Paid via', v: (x) => (x.paidVia ? label(x.paidVia) : '—') },
      { t: 'Booked', v: (x) => dateTime(x.createdAt) },
    ], r.bookings ?? [], 'No slot bookings yet.')),
  );
}

function secHealth(d) {
  const hl = d.health ?? {};
  const steps = hl.steps ?? [];
  const meals = lastDays(14, hl.meals ?? [], 'calories');
  const weights = hl.weights ?? [];
  const totalSteps = steps.reduce((a, x) => a + n(x.steps), 0);
  const sources = [...new Set(steps.map((x) => x.source).filter(Boolean))];
  return h('div', {},
    sec('Steps · last 30 days', h('div', { class: 'ins-card' },
      h('div', { class: 'sub' }, steps.length ? `${num(totalSteps)} steps over ${steps.length} synced day${steps.length === 1 ? '' : 's'} · avg ${num(Math.round(totalSteps / Math.max(1, steps.length)))} / day${sources.length ? ` · source: ${sources.map(label).join(', ')}` : ''}` : 'No step syncs in the last 30 days.'),
      stepsChart(steps))),
    sec('Meals · last 14 days', h('div', { class: 'ins-card' },
      h('div', { class: 'sub' }, (hl.meals ?? []).length ? `${num((hl.meals ?? []).reduce((a, m) => a + n(m.items), 0))} items logged · avg ${num(Math.round((hl.meals ?? []).reduce((a, m) => a + n(m.calories), 0) / Math.max(1, (hl.meals ?? []).length)))} kcal on logged days` : 'No meals logged in the last 14 days.'),
      chart({ labels: meals.map((x) => x.date), type: 'bar', height: 150, series: [{ name: 'Calories', color: SERIES[2], values: meals.map((x) => x.v) }], fmt: (v) => `${num(v)} kcal` }),
      (hl.meals ?? []).length ? h('div', { style: 'margin-top:10px' }, tbl([
        { t: 'Day', v: (m) => date(m.date) }, { t: 'Items', num: true, v: (m) => num(m.items) },
        { t: 'Calories', num: true, v: (m) => `${num(m.calories)} kcal` }, { t: 'Protein', num: true, v: (m) => `${num(m.proteinG)} g` },
      ], [...hl.meals].reverse())) : null)),
    sec(`Weight log (${weights.length})`, weights.length
      ? h('div', { class: 'ins-card' },
        weights.length > 1 ? chart({ labels: [...weights].reverse().map((w) => w.date), integer: false, height: 150, series: [{ name: 'Weight', color: SERIES[1], values: [...weights].reverse().map((w) => n(w.weightKg)) }], fmt: (v) => `${v} kg` }) : null,
        h('div', { class: 'ins-legend' }, weights.slice(0, 10).map((w) => h('span', {}, date(w.date), h('b', {}, `${w.weightKg} kg`)))))
      : h('div', { class: 'ins-card ins-empty' }, 'No weights logged.')),
    hl.goal ? sec('Goal', h('div', { class: 'ins-card' }, goalView(hl.goal))) : null,
  );
}

function secProveit(d) {
  return sec('ProveIt bests', tbl([
    { t: 'Exercise', v: (r) => label(r.exerciseId ?? '—') }, { t: 'Attempts', num: true, v: (r) => num(r.attempts) },
    { t: 'Best reps', num: true, v: (r) => num(r.bestReps) }, { t: 'Best level', num: true, v: (r) => (r.bestLevel != null ? num(r.bestLevel) : '—') },
    { t: 'Last attempt', v: (r) => dateTime(r.lastAt) },
  ], d.proveit ?? [], 'No ProveIt attempts yet.'));
}

function secSocial(d) {
  const s2 = d.social ?? {};
  return h('div', {},
    sec(`Friends invited (${(s2.referrals ?? []).length})`, tbl([
      { t: 'Friend', v: (r) => h('button', { class: 'ins-ulink', onclick: () => openUser(r.userId) }, r.name || r.phone) },
      { t: 'Phone', v: (r) => r.phone }, { t: 'Status', v: (r) => statusPill(r.status) }, { t: 'When', v: (r) => dateTime(r.createdAt) },
    ], s2.referrals ?? [], 'Has not invited anyone yet.')),
    sec(`Circles (${(s2.circles ?? []).length})`, tbl([
      { t: 'Circle', v: (r) => r.name }, { t: 'Place', v: (r) => r.placeName || '—' }, { t: 'Role', v: (r) => (r.role ? label(r.role) : '—') }, { t: 'Joined', v: (r) => dateTime(r.joinedAt) },
    ], s2.circles ?? [], 'Not in any circle.')),
    sec(`Reports against this member (${(s2.reportsAgainst ?? []).length})`, tbl([
      { t: 'When', v: (r) => dateTime(r.createdAt) }, { t: 'Reporter', v: (r) => r.reporterName || '—' }, { t: 'Reason', v: (r) => r.reason },
    ], s2.reportsAgainst ?? [], 'No reports. 🎉')),
  );
}

// ------------------------------------------------------------------------------------------------ admin actions
function modal(title, fields, submitText, onSubmit, { danger = false, note } = {}) {
  const err = h('p', { style: 'color:var(--danger);margin:0', hidden: true });
  const btn = h('button', { type: 'submit', class: danger ? 'danger' : '' }, submitText);
  const form = h('form', { class: 'card stack' }, h('h3', {}, title), note ? h('p', { class: 'muted', style: 'margin:0' }, note) : null, ...fields, err,
    h('div', { class: 'row' }, h('span', { class: 'spacer' }), h('button', { type: 'button', class: 'ghost', onclick: () => wrap.remove() }, 'Cancel'), btn));
  const wrap = h('div', { class: 'ins-modal', onclick: (e) => { if (e.target === wrap) wrap.remove(); } }, form);
  form.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.stopPropagation(); wrap.remove(); } });
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    err.hidden = true;
    btn.disabled = true;
    try {
      await onSubmit(form);
      wrap.remove();
    } catch (ex) {
      err.textContent = ex.message;
      err.hidden = false;
    } finally {
      btn.disabled = false;
    }
  });
  document.body.append(wrap);
  form.querySelector('input, textarea')?.focus();
}

async function afterAction(msg) {
  toast(msg);
  await openUser(drawer.id, { keepTab: true });
  if (usersView.reload && document.querySelector('.ins-toolbar')) usersView.reload();
}

function suspendDialog(u, suspend) {
  const who = u.name || u.phone;
  if (suspend) {
    modal(`Suspend ${who}?`, [h('label', {}, 'Reason (shown to the team)', h('textarea', { name: 'reason', maxlength: 300, placeholder: 'e.g. Repeated harassment reports' }))],
      'Suspend member', async (f) => {
        await api(`/admin/insights/users/${u.id}/suspend`, { method: 'POST', body: { suspended: true, reason: f.reason.value.trim() || undefined } });
        await afterAction(`${who} suspended`);
      }, { danger: true, note: 'They will be blocked from using the app until restored.' });
  } else {
    modal(`Restore ${who}?`, [], 'Restore access', async () => {
      await api(`/admin/insights/users/${u.id}/suspend`, { method: 'POST', body: { suspended: false } });
      await afterAction(`${who} restored`);
    }, { note: u.suspendedReason ? `Suspended for: ${u.suspendedReason}` : 'They will be able to use the app again.' });
  }
}

function notifyDialog(u) {
  modal(`Send a notification to ${u.name || u.phone}`, [
    h('label', {}, 'Title', h('input', { name: 'title', required: true, minlength: 2, maxlength: 120, placeholder: 'e.g. Your pass is about to expire' })),
    h('label', {}, 'Message (optional)', h('textarea', { name: 'body', maxlength: 500 })),
  ], 'Send', async (f) => {
    await api(`/admin/insights/users/${u.id}/notify`, { method: 'POST', body: { title: f.title.value.trim(), body: f.body.value.trim() || undefined } });
    toast('Notification sent');
  }, { note: 'Arrives as an in-app / push notification from FITKEY.' });
}

function coinsDialog(u, wallet) {
  const have = n(wallet?.referral);
  modal(`Bonus coins for ${u.name || u.phone}`, [
    h('label', {}, 'Amount (use a minus sign to deduct)', h('input', { name: 'amount', type: 'number', step: 1, min: -100000, max: 100000, required: true, placeholder: 'e.g. 100 or -50' })),
    h('label', {}, 'Note', h('input', { name: 'note', required: true, minlength: 3, maxlength: 160, placeholder: 'e.g. Sorry for the failed check-in' })),
  ], 'Apply', async (f) => {
    const amount = parseInt(f.amount.value, 10);
    if (!amount) throw new Error('Enter a non-zero whole number');
    if (amount < 0 && -amount > have) throw new Error(`They only have ${have} bonus coins`);
    if (!window.confirm(`${amount > 0 ? 'Grant' : 'Deduct'} ${Math.abs(amount)} bonus coins ${amount > 0 ? 'to' : 'from'} ${u.name || u.phone}?`)) return;
    const r = await api(`/admin/insights/users/${u.id}/coins`, { method: 'POST', body: { amount, note: f.note.value.trim() } });
    await afterAction(`${amount > 0 ? 'Granted' : 'Deducted'} ${Math.abs(amount)} coins · bonus balance ${num(r?.balances?.referral)}`);
  }, { note: `Current bonus balance: ${num(have)} coins. Grants notify the member.` });
}

// ------------------------------------------------------------------------------------------------ register
A.register('insights', 'Insights', insightsView);
A.register('users', 'Users', usersView);
A.register('live', 'Live activity', liveView);
// Show the analytics tabs right after "Dashboard" instead of at the end of the nav.
{
  const nav = document.querySelector('#tabs');
  const dash = nav?.querySelector('[data-tab="dashboard"]');
  const mine = ['insights', 'users', 'live'].map((k) => nav?.querySelector(`[data-tab="${k}"]`)).filter(Boolean);
  if (dash && mine.length) dash.after(...mine);
}
// Let other modules open a member profile: window.FitkeyAdmin.openUser(id)
A.openUser = openUser;

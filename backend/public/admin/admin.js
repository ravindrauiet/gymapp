// FITKEY admin panel — plain JS, talks to the same /api/v1 as the apps (role = admin).
const API = '/api/v1';
const TOKEN_KEY = 'fitkey_admin_token';
const CATEGORIES = ['gym', 'swimming_pool', 'sports_club', 'yoga_studio', 'mma', 'martial_arts', 'dance'];
const VIDEO_CATEGORIES = ['gym', 'yoga', 'dance', 'boxing', 'martial_arts'];

let token = localStorage.getItem(TOKEN_KEY);
let currentTab = 'dashboard';
const $ = (sel) => document.querySelector(sel);

/** Tiny element builder: h('div', {class: 'x', onclick}, 'text', child) — text is always escaped. */
function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs ?? {})) {
    if (v === false || v == null) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat()) if (c != null && c !== false) el.append(c instanceof Node ? c : String(c));
  return el;
}

function toast(msg, error = false) {
  const t = $('#toast');
  t.textContent = msg;
  t.className = error ? 'error' : '';
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (t.hidden = true), 3500);
}

async function api(path, { method = 'GET', body } = {}) {
  const res = await fetch(API + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401 && token) {
    logout();
    throw new Error('Session expired — sign in again');
  }
  const data = res.status === 204 ? null : await res.json().catch(() => null);
  if (!res.ok) throw new Error(data?.error ?? `Request failed (${res.status})`);
  return data;
}

const rupees = (paise) => `₹${(paise / 100).toLocaleString('en-IN')}`;
const label = (s) => s.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
const today = () => new Date().toISOString().slice(0, 10);
const localToday = () => new Date().toLocaleDateString('en-CA'); // YYYY-MM-DD in the browser's time zone
const when = (iso) => (iso ? new Date(iso).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short' }) : '—');
const csv = (s) => s.split(',').map((x) => x.trim()).filter(Boolean);
const stars = (n) => '★'.repeat(n) + '☆'.repeat(Math.max(0, 5 - n));
/** Uploaded files come back server-relative (/api/v1/files/…) — prefix the API origin. */
const assetUrl = (u) => (u && u.startsWith('/') ? location.origin + u : u);
const ARENA_EXERCISES = ['pushups', 'pullups', 'squats', 'plank', 'burpees'];

/** POST /uploads (multipart "file") → server-relative URL. */
async function uploadFile(file) {
  const fd = new FormData();
  fd.append('file', file);
  const res = await fetch(`${API}/uploads`, { method: 'POST', headers: token ? { Authorization: `Bearer ${token}` } : {}, body: fd });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(data?.error ?? `Upload failed (${res.status})`);
  return data.url;
}

/** URL input + file picker that uploads and fills the URL, with a preview. */
function imageField(text, name) {
  const input = h('input', { name, placeholder: 'https://… or upload a file' });
  const preview = h('img', { class: 'thumb', alt: '', hidden: true });
  const sync = () => {
    const u = input.value.trim();
    preview.hidden = !u;
    if (u) preview.src = assetUrl(u);
  };
  input.addEventListener('input', sync);
  const picker = h('input', {
    type: 'file', accept: 'image/jpeg,image/png,image/webp',
    onchange: async (e) => {
      const file = e.target.files[0];
      if (!file) return;
      try {
        input.value = await uploadFile(file);
        sync();
        toast('Image uploaded');
      } catch (err) {
        toast(err.message, true);
      }
      e.target.value = '';
    },
  });
  return { el: h('label', {}, text, input, picker, preview), input, sync };
}

/** Nav badges: open rating alerts and pending org ID approvals. Returns the counts (null when unavailable). */
function setBadge(key, n, capped = false) {
  const b = document.querySelector(`[data-badge="${key}"]`);
  if (!b) return;
  b.textContent = capped ? `${n}+` : String(n);
  b.hidden = !n;
}
async function refreshBadges() {
  const [a, m] = await Promise.allSettled([
    api('/ratings/admin/alerts?status=open&limit=1'),
    api('/events/admin/memberships?status=pending'),
  ]);
  const openAlerts = a.status === 'fulfilled' ? a.value.counts.open : null;
  const pendingIds = m.status === 'fulfilled' ? m.value.memberships.length : null;
  if (openAlerts != null) setBadge('alerts', openAlerts);
  if (pendingIds != null) setBadge('ids', pendingIds, pendingIds >= 200);
  return { openAlerts, pendingIds };
}

// ---------------------------------------------------------------- auth
let loginPhone = '';

$('#login-phone').addEventListener('submit', async (e) => {
  e.preventDefault();
  loginPhone = e.target.phone.value;
  try {
    const r = await api('/auth/otp/request', { method: 'POST', body: { phone: loginPhone, role: 'admin' } });
    $('#login-otp').hidden = false;
    $('#dev-otp').textContent = r.devOtp ? `Dev OTP: ${r.devOtp}` : 'OTP sent by SMS.';
    $('#login-otp').otp.focus();
  } catch (err) {
    toast(err.message, true);
  }
});

$('#login-otp').addEventListener('submit', async (e) => {
  e.preventDefault();
  try {
    const r = await api('/auth/otp/verify', {
      method: 'POST',
      body: { phone: loginPhone, otp: e.target.otp.value, role: 'admin' },
    });
    token = r.token;
    localStorage.setItem(TOKEN_KEY, token);
    render();
  } catch (err) {
    toast(err.message, true);
  }
});

function logout() {
  token = null;
  localStorage.removeItem(TOKEN_KEY);
  render();
}
$('#logout').addEventListener('click', logout);

function goTab(tab) {
  currentTab = tab;
  document.querySelectorAll('#tabs button').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
  render();
}
$('#tabs').addEventListener('click', (e) => {
  const tab = e.target.closest('button')?.dataset.tab;
  if (tab) goTab(tab);
});

// ---------------------------------------------------------------- views
const views = {
  async dashboard() {
    const [{ stats }, badges] = await Promise.all([api('/admin/stats'), refreshBadges()]);
    const shown = (n, cap) => (n == null ? '—' : n >= cap ? `${n}+` : n);
    const tiles = [
      ['Members', stats.members],
      ['Partners', stats.partners],
      ['Live venues', stats.liveVenues],
      ['Awaiting review', stats.pendingVenues],
      ['Active subscriptions', stats.activeSubscriptions],
      ['Revenue this month', rupees(stats.revenueThisMonthPaise)],
      ['Check-ins today', stats.checkinsToday],
      ['User reports', stats.reports],
      ['Marketplace Orders', stats.totalOrders || 0],
      ['Store Revenue', rupees(stats.storeRevenuePaise || 0)],
      ['Verified Trainers', stats.verifiedTrainers || 0],
      ['Active SKUs', stats.activeProducts || 0],
      ['Pending org ID approvals', shown(badges.pendingIds, 200), 'ids'],
      ['Open rating alerts', shown(badges.openAlerts, Infinity), 'alerts'],
    ];
    return h('div', {},
      h('h2', {}, 'Dashboard'),
      h('div', { class: 'grid' }, tiles.map(([k, v, tab]) =>
        h('div', { class: `card stat${tab ? ' clickable' : ''}`, onclick: tab ? () => goTab(tab) : null },
          h('div', { class: 'muted' }, k), h('div', { class: 'value' }, v)))),
    );
  },

  async venues() {
    const status = views.venues.status ?? 'submitted';
    const { venues } = await api(`/admin/venues${status === 'all' ? '' : `?status=${status}`}`);
    const filters = ['submitted', 'under_review', 'live', 'rejected', 'draft', 'all'].map((s) =>
      h('button', { class: s === status ? 'active' : '', onclick: () => { views.venues.status = s; render(); } }, label(s)));

    const setStatus = async (v, next) => {
      let note;
      if (next === 'rejected') {
        note = prompt('Reason for rejection (shown to the partner):');
        if (!note) return;
      }
      try {
        await api(`/admin/venues/${v.id}/status`, { method: 'PATCH', body: { status: next, note } });
        toast(`${v.name} → ${label(next)}`);
        render();
      } catch (err) {
        toast(err.message, true);
      }
    };

    return h('div', {},
      h('div', { class: 'row' }, h('h2', {}, 'Venue listings'), h('span', { class: 'spacer' }), h('div', { class: 'row filters' }, filters)),
      venues.length === 0 ? h('p', { class: 'muted' }, 'Nothing here.') : null,
      venues.map((v) => h('div', { class: 'card venue stack' },
        h('div', { class: 'row' },
          h('h3', {}, v.name), h('span', { class: `pill ${v.status}` }, label(v.status)), h('span', { class: 'spacer' }),
          h('span', { class: 'muted' }, `Owner: ${v.ownerName ?? '—'} · ${v.ownerPhone}`)),
        h('div', { class: 'muted' }, [v.address, v.area, v.city].filter(Boolean).join(' · ')),
        h('div', {}, v.categories.map((c) => h('span', { class: 'pill' }, label(c))), ' ',
          `Timings ${v.opensAt?.slice(0, 5) ?? '?'}–${v.closesAt?.slice(0, 5) ?? '?'} · ${v.openDays.join(', ')}`),
        h('div', { class: 'photos' }, v.photos.map((p) => h('img', { src: p, alt: '', loading: 'lazy' }))),
        h('div', {}, `Trainer: ${v.trainerAvailable ? 'Yes' : 'No'} · Amenities: ${v.amenities.map(label).join(', ') || '—'}`),
        v.equipment.length ? h('div', { class: 'muted' }, `Equipment: ${v.equipment.join(', ')}`) : null,
        v.latitude ? h('a', { href: `https://www.google.com/maps?q=${v.latitude},${v.longitude}`, target: '_blank', style: 'color: var(--sky)' }, 'View on map ↗') : null,
        v.reviewNote ? h('div', { class: 'muted' }, `Review note: ${v.reviewNote}`) : null,
        h('div', { class: 'row' },
          v.status === 'submitted' ? h('button', { class: 'ghost', onclick: () => setStatus(v, 'under_review') }, 'Start review') : null,
          v.status !== 'live' ? h('button', { onclick: () => setStatus(v, 'live') }, 'Approve & go live') : null,
          v.status !== 'rejected' ? h('button', { class: 'danger', onclick: () => setStatus(v, 'rejected') }, v.status === 'live' ? 'Take down' : 'Reject') : null),
      )),
    );
  },

  async plans() {
    const { plans } = await api('/admin/plans');
    const form = h('form', { class: 'card stack' },
      h('h3', {}, 'New plan'),
      h('div', { class: 'grid' },
        h('label', {}, 'Code', h('input', { name: 'code', placeholder: 'gym_quarterly', required: true })),
        h('label', {}, 'Name', h('input', { name: 'name', required: true })),
        h('label', {}, 'Price (₹)', h('input', { name: 'price', type: 'number', min: 0, required: true })),
        h('label', {}, 'Duration (days)', h('input', { name: 'days', type: 'number', min: 1, value: 30, required: true })),
      ),
      h('label', {}, 'Description', h('input', { name: 'description' })),
      h('label', {}, 'Features (comma separated)', h('input', { name: 'features' })),
      h('div', {}, h('div', { class: 'muted' }, 'Covers categories'),
        h('div', { class: 'row' }, CATEGORIES.map((c) => h('label', { class: 'row' }, h('input', { type: 'checkbox', name: 'cat', value: c, style: 'width:auto' }), label(c))))),
      h('button', { type: 'submit' }, 'Create plan'),
    );
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const f = e.target;
      try {
        await api('/admin/plans', {
          method: 'POST',
          body: {
            code: f.elements.code.value.trim(),
            name: f.elements.name.value.trim(),
            description: f.elements.description.value.trim() || undefined,
            pricePaise: Math.round(Number(f.elements.price.value) * 100),
            durationDays: Number(f.elements.days.value),
            features: f.elements.features.value.split(',').map((s) => s.trim()).filter(Boolean),
            categories: [...f.querySelectorAll('input[name=cat]:checked')].map((i) => i.value),
          },
        });
        toast('Plan created');
        render();
      } catch (err) {
        toast(err.message, true);
      }
    });

    const update = async (p, body) => {
      try {
        await api(`/admin/plans/${p.id}`, { method: 'PATCH', body });
        toast('Plan updated');
        render();
      } catch (err) {
        toast(err.message, true);
      }
    };

    return h('div', { class: 'stack' },
      h('h2', {}, 'Plans'),
      h('div', { class: 'card' }, h('table', {},
        h('tr', {}, ['Plan', 'Categories', 'Price', 'Days', 'Status', ''].map((t) => h('th', {}, t))),
        plans.map((p) => h('tr', {},
          h('td', {}, h('strong', {}, p.name), h('div', { class: 'muted' }, p.code)),
          h('td', {}, p.categories.map(label).join(', ')),
          h('td', {}, rupees(p.pricePaise)),
          h('td', {}, p.durationDays),
          h('td', {}, h('span', { class: `pill ${p.isActive ? 'live' : 'rejected'}` }, p.isActive ? 'Active' : 'Hidden')),
          h('td', { class: 'row' },
            h('button', { class: 'ghost', onclick: () => {
              const v = prompt(`New price for ${p.name} (₹)`, p.pricePaise / 100);
              if (v) update(p, { pricePaise: Math.round(Number(v) * 100) });
            } }, 'Edit price'),
            h('button', { class: 'ghost', onclick: () => update(p, { isActive: !p.isActive }) }, p.isActive ? 'Hide' : 'Show')),
        )),
      )),
      form,
    );
  },

  async videos() {
    const [{ videos }, { groups }] = await Promise.all([api('/admin/videos'), api('/admin/video-taxonomy')]);
    const groupLabel = Object.fromEntries(groups.map((g) => [g.key, g.label]));
    const typeLabel = Object.fromEntries(groups.flatMap((g) => g.types.map((t) => [t.key, t.label])));
    let editing = null; // video being edited, or null when adding

    const typeBoxes = h('div', { class: 'grid', style: 'grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 8px 16px' },
      groups.map((g) => h('fieldset', { style: 'border: 1px solid var(--outline); border-radius: 10px; padding: 8px 12px; margin: 0' },
        h('legend', { class: 'muted', style: 'font-weight: 700; padding: 0 4px' }, g.label),
        g.types.map((t) => h('label', { style: 'display: flex; gap: 8px; align-items: center; font-weight: 500; margin: 2px 0' },
          h('input', { type: 'checkbox', name: 'types', value: t.key, style: 'width: auto; margin: 0' }), t.label)),
      )));
    const title = h('h3', {}, 'Add video');
    const submit = h('button', { type: 'submit' }, 'Publish video');
    const cancel = h('button', { type: 'button', class: 'ghost', hidden: true, onclick: () => reset() }, 'Cancel edit');
    const form = h('form', { class: 'card stack' },
      title,
      h('div', { class: 'grid' },
        h('label', {}, 'Studio group', h('select', { name: 'group', required: true },
          groups.map((g) => h('option', { value: g.key }, g.label)))),
        h('label', {}, 'Legacy category (old apps)', h('select', { name: 'category' },
          h('option', { value: '' }, 'Auto from group'), VIDEO_CATEGORIES.map((c) => h('option', { value: c }, label(c))))),
        h('label', {}, 'Equipment', h('select', { name: 'equipment' },
          [['none', 'None'], ['dumbbells', 'Dumbbells'], ['gym', 'Gym']].map(([v, l]) => h('option', { value: v }, l)))),
        h('label', {}, 'Title', h('input', { name: 'title', required: true })),
        h('label', {}, 'Trainer', h('input', { name: 'trainer' })),
        h('label', {}, 'Level', h('select', { name: 'level' }, ['beginner', 'intermediate', 'advanced'].map((l) => h('option', { value: l }, label(l))))),
        h('label', {}, 'Duration (minutes)', h('input', { name: 'minutes', type: 'number', min: 1 })),
      ),
      h('div', {}, h('p', { class: 'muted', style: 'margin: 0 0 6px' },
        'Video types: tick every type that applies. The video appears in each of their groups (e.g. Gym > Chest and Body Part > Upper Body).'),
        typeBoxes),
      h('label', {}, 'Video URL (MP4 / HLS)', h('input', { name: 'url', type: 'url', required: true })),
      h('label', {}, 'Thumbnail URL (optional)', h('input', { name: 'thumb', type: 'url' })),
      h('label', {}, 'Description', h('textarea', { name: 'description' })),
      h('div', { class: 'row' }, submit, cancel),
    );
    const checked = () => [...form.querySelectorAll('input[name=types]:checked')].map((i) => i.value);

    function reset() {
      editing = null;
      form.reset();
      title.textContent = 'Add video';
      submit.textContent = 'Publish video';
      cancel.hidden = true;
    }
    function edit(v) {
      editing = v;
      const el = form.elements;
      el.group.value = v.groupKey ?? groups[0]?.key;
      el.category.value = v.category ?? '';
      el.equipment.value = v.equipment ?? 'none';
      el.title.value = v.title;
      el.trainer.value = v.trainerName ?? '';
      el.level.value = v.level;
      el.minutes.value = v.durationSeconds ? Math.round(v.durationSeconds / 60) : '';
      el.url.value = v.videoUrl;
      el.thumb.value = v.thumbnailUrl ?? '';
      el.description.value = v.description ?? '';
      form.querySelectorAll('input[name=types]').forEach((i) => (i.checked = (v.types ?? []).includes(i.value)));
      title.textContent = `Edit "${v.title}"`;
      submit.textContent = 'Save changes';
      cancel.hidden = false;
      form.scrollIntoView({ behavior: 'smooth' });
    }

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const f = e.target.elements;
      const body = {
        groupKey: f.group.value,
        types: checked(),
        equipment: f.equipment.value,
        category: f.category.value || undefined,
        title: f.title.value.trim(),
        trainerName: f.trainer.value.trim() || undefined,
        level: f.level.value,
        durationSeconds: f.minutes.value ? Number(f.minutes.value) * 60 : undefined,
        videoUrl: f.url.value.trim(),
        thumbnailUrl: f.thumb.value.trim() || undefined,
        description: f.description.value.trim() || undefined,
      };
      try {
        if (editing) await api(`/admin/videos/${editing.id}`, { method: 'PATCH', body });
        else await api('/admin/videos', { method: 'POST', body });
        toast(editing ? 'Video updated' : 'Video published');
        render();
      } catch (err) {
        toast(err.message, true);
      }
    });

    return h('div', { class: 'stack' },
      h('h2', {}, 'FitKey Studio videos'),
      h('div', { class: 'card' }, h('table', {},
        h('tr', {}, ['Title', 'Group', 'Types', 'Equipment', 'Trainer', 'Level', ''].map((t) => h('th', {}, t))),
        videos.map((v) => h('tr', {},
          h('td', {}, h('a', { href: v.videoUrl, target: '_blank', style: 'color: var(--text)' }, v.title)),
          h('td', {}, groupLabel[v.groupKey] ?? label(v.category)),
          h('td', { class: 'muted' }, (v.types ?? []).map((t) => typeLabel[t] ?? t).join(', ') || '—'),
          h('td', {}, v.equipment ? label(v.equipment) : '—'),
          h('td', {}, v.trainerName ?? '—'), h('td', {}, label(v.level)),
          h('td', { class: 'row' },
            h('button', { class: 'ghost', onclick: () => edit(v) }, 'Edit'),
            h('button', { class: 'danger', onclick: async () => {
              if (!confirm(`Delete "${v.title}"?`)) return;
              try { await api(`/admin/videos/${v.id}`, { method: 'DELETE' }); render(); } catch (err) { toast(err.message, true); }
            } }, 'Delete')),
        )),
      )),
      form,
    );
  },

  // Events (fitkey / org / partner × virtual / on-ground / AI) — replaces the old contest form; same contests table.
  async events() {
    const status = views.events.status ?? 'any';
    const [{ events }, { orgs }, { venues }] = await Promise.all([
      api(`/events/admin/events?status=${status}`), api('/events/admin/orgs'), api('/admin/venues'),
    ]);
    const filters = ['any', 'live', 'upcoming', 'past'].map((s) =>
      h('button', { class: s === status ? 'active' : '', onclick: () => { views.events.status = s; render(); } }, s === 'any' ? 'All' : label(s)));
    const now = localToday();
    const phase = (e) => (e.endsOn < now ? 'past' : e.startsOn > now ? 'upcoming' : 'live');
    let editing = null;

    const opts = (pairs) => pairs.map(([v, l]) => h('option', { value: v }, l));
    const only = (key, ...kids) => h('label', { 'data-field': key }, ...kids);
    const cover = imageField('Cover image (optional)', 'coverUrl');
    const title = h('h3', {}, 'New event');
    const submit = h('button', { type: 'submit' }, 'Create event');
    const cancel = h('button', { type: 'button', class: 'ghost', hidden: true, onclick: () => reset() }, 'Cancel edit');
    const form = h('form', { class: 'card stack' },
      title,
      h('div', { class: 'grid' },
        h('label', {}, 'Title', h('input', { name: 'title', required: true, minlength: 3, maxlength: 160 })),
        h('label', {}, 'Kind', h('select', { name: 'kind' },
          opts([['fitkey', 'FitKey (everyone)'], ['org', 'Org (company / college)'], ['partner', 'Partner (gym / studio)']]))),
        h('label', {}, 'Format', h('select', { name: 'format' },
          opts([['virtual', 'Virtual'], ['onground', 'On-ground (attendance)'], ['ai', 'AI-verified (Arena)']]))),
        only('metric', 'Metric', h('select', { name: 'metric' },
          opts([['checkins', 'Check-in days'], ['running_km', 'Running km'], ['streak', 'Longest streak']]))),
        only('autoMetric', 'Metric', h('input', { name: 'autoMetric', disabled: true })),
        only('arena', 'Arena exercise', h('select', { name: 'arenaExercise' }, opts(ARENA_EXERCISES.map((x) => [x, label(x)])))),
        h('label', {}, 'Period', h('select', { name: 'period' }, opts([['weekly', 'Weekly'], ['monthly', 'Monthly'], ['custom', 'Custom']]))),
        h('label', {}, h('span', { 'data-hint': 'starts' }, 'Starts'), h('input', { name: 'startsOn', type: 'date', value: today() })),
        h('label', {}, h('span', { 'data-hint': 'ends' }, 'Ends'), h('input', { name: 'endsOn', type: 'date' })),
        only('eventDate', 'Event date', h('input', { name: 'eventDate', type: 'date' })),
        only('org', 'Organisation', h('select', { name: 'orgId' },
          h('option', { value: '' }, orgs.length ? 'Select org…' : 'No orgs — add one in Orgs'), opts(orgs.map((o) => [o.id, o.name])))),
        only('venue', 'Venue', h('select', { name: 'venueId' },
          h('option', { value: '' }, 'Select venue…'),
          opts(venues.map((v) => [v.id, `${v.name} — ${[v.area, v.city].filter(Boolean).join(', ')}${v.status === 'live' ? '' : ` (${label(v.status)})`}`])))),
        only('membersOnly', 'Who can join', h('select', { name: 'membersOnly' },
          opts([['false', 'Everyone'], ['true', 'Venue members only']]))),
        h('label', {}, 'City (optional)', h('input', { name: 'city' })),
        h('label', {}, 'Sponsor (optional)', h('input', { name: 'sponsor' })),
        h('label', {}, 'Registration fee (₹)', h('input', { name: 'fee', type: 'number', min: 0, step: '0.01', value: 0 })),
      ),
      h('label', {}, 'Reward', h('input', { name: 'reward', placeholder: 'e.g. FITKEY T-shirt + 1 week free' })),
      h('label', {}, 'Description', h('textarea', { name: 'description' })),
      cover.el,
      h('div', {}, h('div', { class: 'muted' }, 'Inter-org battle (optional) — members of these orgs compete as teams, ranked by average score'),
        orgs.length
          ? h('div', { class: 'checks' }, orgs.map((o) => h('label', {}, h('input', { type: 'checkbox', name: 'battle', value: o.id }), o.name)))
          : h('p', { class: 'muted', style: 'margin: 0' }, 'No orgs yet.')),
      h('div', { class: 'row' }, submit, cancel),
    );
    const el = form.elements;

    // Mirrors normalizeEvent() in routes/events.js.
    function sync() {
      const kind = el.kind.value;
      const format = el.format.value;
      const show = (key, on) => form.querySelectorAll(`[data-field="${key}"]`).forEach((n) => (n.hidden = !on));
      const needsVenue = format === 'onground' || kind === 'partner';
      show('metric', format === 'virtual');
      show('autoMetric', format !== 'virtual');
      el.autoMetric.value = format === 'onground' ? 'Attendance (auto)' : format === 'ai' ? 'Best AI Arena set — reps (auto)' : '';
      show('arena', format === 'ai');
      show('eventDate', format === 'onground');
      show('org', kind === 'org');
      show('venue', needsVenue);
      show('membersOnly', kind === 'partner');
      el.eventDate.required = format === 'onground';
      el.venueId.required = needsVenue;
      el.orgId.required = kind === 'org';
      el.startsOn.required = el.endsOn.required = format !== 'onground';
      form.querySelector('[data-hint=starts]').textContent = format === 'onground' ? 'Registration opens (optional)' : 'Starts';
      form.querySelector('[data-hint=ends]').textContent = format === 'onground' ? 'Ends (optional, defaults to event date)' : 'Ends';
    }
    el.kind.addEventListener('change', sync);
    el.format.addEventListener('change', sync);
    sync();

    function reset() {
      editing = null;
      form.reset();
      cover.sync();
      sync();
      title.textContent = 'New event';
      submit.textContent = 'Create event';
      cancel.hidden = true;
    }
    function edit(e) {
      editing = e;
      for (const k of ['title', 'kind', 'format', 'period', 'startsOn', 'endsOn']) el[k].value = e[k] ?? '';
      el.metric.value = ['checkins', 'running_km', 'streak'].includes(e.metric) ? e.metric : 'checkins';
      el.arenaExercise.value = e.arenaExercise ?? ARENA_EXERCISES[0];
      el.eventDate.value = e.eventDate ?? '';
      el.orgId.value = e.orgId ?? '';
      el.venueId.value = e.venueId ?? '';
      el.membersOnly.value = String(Boolean(e.membersOnly));
      el.city.value = e.city ?? '';
      el.sponsor.value = e.sponsor ?? '';
      el.fee.value = (e.registrationFeePaise ?? 0) / 100;
      el.reward.value = e.reward ?? '';
      el.description.value = e.description ?? '';
      cover.input.value = e.coverUrl ?? '';
      cover.sync();
      form.querySelectorAll('input[name=battle]').forEach((i) => (i.checked = (e.battleOrgIds ?? []).includes(i.value)));
      sync();
      title.textContent = `Edit "${e.title}"`;
      submit.textContent = 'Save changes';
      cancel.hidden = false;
      form.scrollIntoView({ behavior: 'smooth' });
    }

    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const kind = el.kind.value;
      const format = el.format.value;
      const needsVenue = format === 'onground' || kind === 'partner';
      const text = (k) => el[k].value.trim() || null;
      const body = {
        title: el.title.value.trim(),
        description: text('description'),
        kind,
        format,
        metric: format === 'virtual' ? el.metric.value : undefined,
        period: el.period.value,
        startsOn: el.startsOn.value || undefined,
        endsOn: el.endsOn.value || undefined,
        eventDate: format === 'onground' ? el.eventDate.value : null,
        reward: text('reward'),
        city: text('city'),
        orgId: kind === 'org' ? el.orgId.value : null,
        venueId: needsVenue ? el.venueId.value : null,
        membersOnly: kind === 'partner' && el.membersOnly.value === 'true',
        arenaExercise: format === 'ai' ? el.arenaExercise.value : null,
        coverUrl: text('coverUrl'),
        sponsor: text('sponsor'),
        registrationFeePaise: Math.round(Number(el.fee.value || 0) * 100),
        battleOrgIds: [...form.querySelectorAll('input[name=battle]:checked')].map((i) => i.value),
      };
      try {
        if (editing) await api(`/events/admin/events/${editing.id}`, { method: 'PATCH', body });
        else await api('/events/admin/events', { method: 'POST', body });
        toast(editing ? 'Event updated' : 'Event created');
        render();
      } catch (err) {
        toast(err.message, true);
      }
    });

    const participantsBox = h('div', { class: 'card stack', hidden: true });
    async function showParticipants(e) {
      participantsBox.hidden = false;
      participantsBox.replaceChildren(h('p', { class: 'muted' }, 'Loading…'));
      participantsBox.scrollIntoView({ behavior: 'smooth' });
      try {
        const { participants } = await api(`/events/admin/events/${e.id}/participants`);
        participantsBox.replaceChildren(
          h('div', { class: 'row' }, h('h3', {}, `Participants — ${e.title}`), h('span', { class: 'spacer' }),
            h('button', { class: 'ghost', onclick: () => (participantsBox.hidden = true) }, 'Close')),
          participants.length === 0 ? h('p', { class: 'muted' }, 'Nobody has joined yet.') : h('table', {},
            h('tr', {}, ['Member', 'Phone', 'City', 'Org', 'Joined', 'Attended'].map((t) => h('th', {}, t))),
            participants.map((p) => h('tr', {},
              h('td', {}, p.name ?? '—'), h('td', {}, p.phone), h('td', {}, p.city ?? '—'), h('td', {}, p.orgName ?? '—'),
              h('td', {}, when(p.joinedAt)), h('td', {}, p.attendedAt ? when(p.attendedAt) : '—'),
            ))),
        );
      } catch (err) {
        participantsBox.replaceChildren(h('p', { class: 'muted' }, err.message));
      }
    }

    const metricText = (e) => (e.format === 'ai' ? `AI reps · ${label(e.arenaExercise ?? '?')}` : e.metric === 'running_km' ? 'Running km' : label(e.metric));
    const host = (e) => [e.orgName, e.venueName, e.city].filter(Boolean).join(' · ') || 'Everyone';
    return h('div', { class: 'stack' },
      h('div', { class: 'row' }, h('h2', {}, 'Events'), h('span', { class: 'spacer' }), h('div', { class: 'row filters' }, filters)),
      h('p', { class: 'muted', style: 'margin: 0' }, 'FitKey, org and partner events — virtual, on-ground or AI-verified. (Replaces the old Contests tab; existing contests are listed here.)'),
      events.length === 0 ? h('p', { class: 'muted' }, 'No events here.') : h('div', { class: 'card' }, h('table', {},
        h('tr', {}, ['Event', 'Type', 'Metric', 'Dates', 'Host / audience', 'Players', 'Fee', ''].map((t) => h('th', {}, t))),
        events.map((e) => h('tr', {},
          h('td', {}, h('strong', {}, e.title), ' ', h('span', { class: `pill ${phase(e)}` }, label(phase(e))),
            h('div', { class: 'muted' }, [e.reward, e.sponsor && `Sponsor: ${e.sponsor}`].filter(Boolean).join(' · '))),
          h('td', {}, h('span', { class: 'pill' }, { fitkey: 'FitKey', org: 'Org', partner: 'Partner' }[e.kind] ?? e.kind), ' ',
            h('span', { class: 'pill' }, { virtual: 'Virtual', onground: 'On-ground', ai: 'AI' }[e.format] ?? e.format)),
          h('td', {}, metricText(e)),
          h('td', {}, `${e.startsOn} → ${e.endsOn}`, e.eventDate ? h('div', { class: 'muted' }, `On ${e.eventDate}`) : null),
          h('td', {}, host(e), e.membersOnly ? h('div', { class: 'muted' }, 'Members only') : null,
            e.battleOrgIds?.length ? h('div', { class: 'muted' }, `Battle: ${e.battleOrgIds.length} orgs`) : null),
          h('td', {}, e.participantCount, e.format === 'onground' ? h('div', { class: 'muted' }, `${e.attendedCount} attended`) : null),
          h('td', {}, e.registrationFeePaise ? rupees(e.registrationFeePaise) : 'Free'),
          h('td', { class: 'row' },
            h('button', { class: 'ghost', onclick: () => edit(e) }, 'Edit'),
            h('button', { class: 'ghost', onclick: () => showParticipants(e) }, 'Participants'),
            h('button', { class: 'danger', onclick: async () => {
              if (!confirm(`Delete "${e.title}"? Its ${e.participantCount} registrations are removed too.`)) return;
              try { await api(`/events/admin/events/${e.id}`, { method: 'DELETE' }); toast('Event deleted'); render(); } catch (err) { toast(err.message, true); }
            } }, 'Delete')),
        )),
      )),
      participantsBox,
      form,
    );
  },

  // Organisations (companies / colleges) that members verify into.
  async orgs() {
    const { orgs } = await api('/events/admin/orgs');
    let editing = null;
    const logo = imageField('Logo (optional)', 'logoUrl');
    const title = h('h3', {}, 'New organisation');
    const submit = h('button', { type: 'submit' }, 'Create org');
    const cancel = h('button', { type: 'button', class: 'ghost', hidden: true, onclick: () => reset() }, 'Cancel edit');
    const form = h('form', { class: 'card stack' },
      title,
      h('div', { class: 'grid' },
        h('label', {}, 'Name', h('input', { name: 'name', required: true, minlength: 2, maxlength: 120 })),
        h('label', {}, 'Kind', h('select', { name: 'kind' }, h('option', { value: 'company' }, 'Company'), h('option', { value: 'college' }, 'College'))),
        h('label', {}, 'Invite code (optional)', h('input', { name: 'inviteCode', placeholder: 'ACME-2026 (4–24 letters, digits, dashes)' })),
      ),
      h('label', {}, 'Email domains (comma separated — members with these emails verify instantly)',
        h('input', { name: 'domains', placeholder: 'acme.com, acme.in' })),
      logo.el,
      h('div', { class: 'row' }, submit, cancel),
    );
    const el = form.elements;
    function reset() {
      editing = null;
      form.reset();
      logo.sync();
      title.textContent = 'New organisation';
      submit.textContent = 'Create org';
      cancel.hidden = true;
    }
    function edit(o) {
      editing = o;
      el.name.value = o.name;
      el.kind.value = o.kind;
      el.inviteCode.value = o.inviteCode ?? '';
      el.domains.value = (o.domains ?? []).join(', ');
      logo.input.value = o.logoUrl ?? '';
      logo.sync();
      title.textContent = `Edit "${o.name}"`;
      submit.textContent = 'Save changes';
      cancel.hidden = false;
      form.scrollIntoView({ behavior: 'smooth' });
    }
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const body = {
        name: el.name.value.trim(),
        kind: el.kind.value,
        inviteCode: el.inviteCode.value.trim() || null, // null clears it on edit
        logoUrl: el.logoUrl.value.trim() || null,
        domains: csv(el.domains.value),
      };
      try {
        if (editing) await api(`/events/admin/orgs/${editing.id}`, { method: 'PATCH', body });
        else await api('/events/admin/orgs', { method: 'POST', body });
        toast(editing ? 'Org updated' : 'Org created');
        render();
      } catch (err) {
        toast(err.message, true);
      }
    });

    const reviewIds = (o) => { views.ids.orgId = o.id; views.ids.status = 'pending'; goTab('ids'); };
    return h('div', { class: 'stack' },
      h('h2', {}, 'Organisations'),
      h('p', { class: 'muted', style: 'margin: 0' }, 'Companies and colleges for org events and verified badges. Corporate wellness clients (Corporate tab) are orgs too.'),
      orgs.length === 0 ? h('p', { class: 'muted' }, 'No orgs yet.') : h('div', { class: 'card' }, h('table', {},
        h('tr', {}, ['Organisation', 'Kind', 'Domains', 'Invite code', 'Verified', 'Pending IDs', ''].map((t) => h('th', {}, t))),
        orgs.map((o) => h('tr', {},
          h('td', { class: 'row' }, o.logoUrl ? h('img', { src: assetUrl(o.logoUrl), alt: '', style: 'width: 32px; height: 32px; border-radius: 8px; object-fit: cover' }) : null,
            h('strong', {}, o.name)),
          h('td', {}, label(o.kind)),
          h('td', { class: 'muted' }, (o.domains ?? []).join(', ') || '—'),
          h('td', {}, o.inviteCode ? h('code', {}, o.inviteCode) : '—'),
          h('td', {}, o.verifiedMembers),
          h('td', {}, Number(o.pendingMembers)
            ? h('a', { href: '#', class: 'link', onclick: (e) => { e.preventDefault(); reviewIds(o); } }, `${o.pendingMembers} to review`)
            : '0'),
          h('td', {}, h('button', { class: 'ghost', onclick: () => edit(o) }, 'Edit')),
        )),
      )),
      form,
    );
  },

  // Org ID-card uploads waiting for a FitKey admin.
  async ids() {
    const status = views.ids.status ?? 'pending';
    const orgId = views.ids.orgId ?? '';
    const [{ memberships }, { orgs }] = await Promise.all([
      api(`/events/admin/memberships?status=${status}${orgId ? `&orgId=${orgId}` : ''}`),
      api('/events/admin/orgs'),
    ]);
    const filters = ['pending', 'verified', 'removed'].map((s) =>
      h('button', { class: s === status ? 'active' : '', onclick: () => { views.ids.status = s; render(); } }, label(s)));
    const orgFilter = h('select', { style: 'width: auto; margin: 0', onchange: (e) => { views.ids.orgId = e.target.value; render(); } },
      h('option', { value: '' }, 'All orgs'), orgs.map((o) => h('option', { value: o.id, selected: o.id === orgId }, o.name)));

    const review = async (m, approve) => {
      const who = m.userName ?? m.userPhone;
      let body;
      if (approve) {
        const department = prompt(`Approve ${who} at ${m.orgName}. Department (optional):`, m.department ?? '');
        if (department === null) return;
        body = { department: department.trim() || undefined };
      } else {
        const note = prompt(`${m.status === 'verified' ? 'Remove' : 'Reject'} ${who} at ${m.orgName}. Reason (sent to the member):`);
        if (note === null) return;
        body = { note: note.trim() || undefined };
      }
      try {
        await api(`/events/admin/memberships/${m.orgId}/${m.userId}/${approve ? 'approve' : 'reject'}`, { method: 'POST', body });
        toast(`${who} → ${approve ? 'verified' : 'removed'}`);
        render();
      } catch (err) {
        toast(err.message, true);
      }
    };

    return h('div', {},
      h('div', { class: 'row' }, h('h2', {}, 'Org ID approvals'), h('span', { class: 'spacer' }), orgFilter, h('div', { class: 'row filters' }, filters)),
      memberships.length === 0 ? h('p', { class: 'muted' }, status === 'pending' ? 'No ID cards waiting. 🎉' : 'Nothing here.') : null,
      memberships.length >= 200 ? h('p', { class: 'muted' }, 'Showing the latest 200.') : null,
      memberships.map((m) => h('div', { class: 'card venue stack' },
        h('div', { class: 'row' },
          h('h3', {}, m.userName ?? 'Member'), h('span', { class: `pill ${m.status}` }, label(m.status)), h('span', { class: 'spacer' }),
          h('span', { class: 'muted' }, [m.userPhone, m.userCity].filter(Boolean).join(' · '))),
        h('div', {}, h('strong', {}, m.orgName), ` (${label(m.orgKind)}) · via ${label(m.method ?? '—')}`,
          m.workEmail ? ` · ${m.workEmail}` : '', m.department ? ` · Dept: ${m.department}` : ''),
        h('div', { class: 'muted' }, `Requested ${when(m.requestedAt)}${m.verifiedAt && m.status === 'verified' ? ` · Verified ${when(m.verifiedAt)}` : ''}`),
        m.idProofUrl
          ? h('a', { class: 'idproof', href: assetUrl(m.idProofUrl), target: '_blank', title: 'Open full size' },
            h('img', { src: assetUrl(m.idProofUrl), alt: 'ID proof', loading: 'lazy' }))
          : h('div', { class: 'muted' }, 'No ID photo (work email or invite code).'),
        m.reviewNote ? h('div', { class: 'muted' }, `Review note: ${m.reviewNote}`) : null,
        h('div', { class: 'row' },
          m.status !== 'verified' ? h('button', { onclick: () => review(m, true) }, 'Approve') : null,
          m.status !== 'removed' ? h('button', { class: 'danger', onclick: () => review(m, false) }, m.status === 'verified' ? 'Remove' : 'Reject') : null),
      )),
    );
  },

  // Corporate wellness clients — HR dashboard lives at /corporate.
  async corporate() {
    const { orgs } = await api('/corporate/admin/orgs');
    const last = views.corporate.last;

    const create = h('form', { class: 'card stack' },
      h('h3', {}, 'Onboard a company'),
      h('div', { class: 'grid' },
        h('label', {}, 'Organisation name', h('input', { name: 'name', required: true, minlength: 2, maxlength: 120 })),
        h('label', {}, 'Kind', h('select', { name: 'kind' }, h('option', { value: 'company' }, 'Company'), h('option', { value: 'college' }, 'College'))),
        h('label', {}, 'HR owner phone', h('input', { name: 'ownerPhone', placeholder: '+91 98xxx xxxxx', required: true })),
        h('label', {}, 'HR owner name (optional)', h('input', { name: 'ownerName' })),
      ),
      h('label', {}, 'Email domains (optional, comma separated)', h('input', { name: 'domains', placeholder: 'acme.com' })),
      h('button', { type: 'submit' }, 'Create client'),
    );
    create.addEventListener('submit', async (e) => {
      e.preventDefault();
      const f = e.target.elements;
      try {
        views.corporate.last = await api('/corporate/admin/orgs', {
          method: 'POST',
          body: {
            name: f.name.value.trim(),
            kind: f.kind.value,
            ownerPhone: f.ownerPhone.value.trim(),
            ownerName: f.ownerName.value.trim() || undefined,
            domains: csv(f.domains.value),
          },
        });
        toast('Corporate client created');
        render();
      } catch (err) {
        toast(err.message, true);
      }
    });

    const addAdmin = h('form', { class: 'card stack' },
      h('h3', {}, 'Add an HR admin'),
      h('div', { class: 'grid' },
        h('label', {}, 'Organisation', h('select', { name: 'orgId', required: true },
          h('option', { value: '' }, 'Select org…'), orgs.map((o) => h('option', { value: o.id }, o.name)))),
        h('label', {}, 'Phone', h('input', { name: 'phone', placeholder: '+91 98xxx xxxxx', required: true })),
        h('label', {}, 'Role', h('select', { name: 'role' },
          [['admin', 'Admin'], ['viewer', 'Viewer (read-only)'], ['owner', 'Owner']].map(([v, l]) => h('option', { value: v }, l)))),
        h('label', {}, 'Name (optional)', h('input', { name: 'name' })),
      ),
      h('button', { type: 'submit' }, 'Add HR admin'),
    );
    addAdmin.addEventListener('submit', async (e) => {
      e.preventDefault();
      const f = e.target.elements;
      try {
        const { admin } = await api(`/corporate/admin/orgs/${f.orgId.value}/admins`, {
          method: 'POST',
          body: { phone: f.phone.value.trim(), role: f.role.value, name: f.name.value.trim() || undefined },
        });
        toast(`${admin.phone} added as ${admin.role}`);
        render();
      } catch (err) {
        toast(err.message, true);
      }
    });
    const pickOrg = (o) => { addAdmin.elements.orgId.value = o.id; addAdmin.scrollIntoView({ behavior: 'smooth' }); addAdmin.elements.phone.focus(); };

    return h('div', { class: 'stack' },
      h('div', { class: 'row' }, h('h2', {}, 'Corporate clients'), h('span', { class: 'spacer' }),
        h('a', { href: '/corporate/', target: '_blank', class: 'link' }, 'Open HR dashboard ↗')),
      last ? h('div', { class: 'card stack', style: 'border-color: var(--lime)' },
        h('div', { class: 'row' }, h('h3', {}, `${last.org.name} is ready`), h('span', { class: 'spacer' }),
          h('button', { class: 'ghost', onclick: () => { views.corporate.last = null; render(); } }, 'Dismiss')),
        h('div', {}, `HR owner ${last.owner.name ?? ''} ${last.owner.phone} signs in with phone OTP at `,
          h('a', { href: last.dashboardUrl, target: '_blank', class: 'link' }, last.dashboardUrl)),
        h('div', { class: 'muted' }, `Invite code: ${last.org.inviteCode ?? '—'} · Domains: ${last.domains.join(', ') || '—'}`),
      ) : null,
      orgs.length === 0 ? h('p', { class: 'muted' }, 'No organisations yet.') : h('div', { class: 'card' }, h('table', {},
        h('tr', {}, ['Organisation', 'Domains', 'Invite code', 'HR admins', 'Verified members', 'Created', ''].map((t) => h('th', {}, t))),
        orgs.map((o) => h('tr', {},
          h('td', {}, h('strong', {}, o.name), h('div', { class: 'muted' }, label(o.kind))),
          h('td', { class: 'muted' }, (o.domains ?? []).join(', ') || '—'),
          h('td', {}, o.inviteCode ? h('code', {}, o.inviteCode) : '—'),
          h('td', {}, Number(o.adminCount) ? o.adminCount : h('span', { class: 'pill upcoming' }, 'None')),
          h('td', {}, o.memberCount),
          h('td', {}, when(o.createdAt)),
          h('td', {}, h('button', { class: 'ghost', onclick: () => pickOrg(o) }, 'Add HR admin')),
        )),
      )),
      create,
      addAdmin,
    );
  },

  // FitFeed "Verified Nutritionist" badge.
  async fitfeed() {
    const q = views.fitfeed.q ?? '';
    const { users } = await api(`/feed/admin/nutritionists${q ? `?q=${encodeURIComponent(q)}` : ''}`);
    const search = h('form', { class: 'row' },
      h('input', { name: 'q', value: q, placeholder: 'Search members by name or phone', style: 'width: 280px; margin: 0' }),
      h('button', { type: 'submit' }, 'Search'),
      q ? h('button', { type: 'button', class: 'ghost', onclick: () => { views.fitfeed.q = ''; render(); } }, 'Clear') : null);
    search.addEventListener('submit', (e) => {
      e.preventDefault();
      views.fitfeed.q = e.target.elements.q.value.trim();
      render();
    });
    const toggle = async (u) => {
      const verified = !u.verifiedNutritionist;
      if (!verified && !confirm(`Revoke the Verified Nutritionist badge from ${u.name ?? u.phone}?`)) return;
      try {
        await api(`/feed/admin/nutritionists/${u.id}`, { method: 'POST', body: { verified } });
        toast(verified ? `${u.name ?? u.phone} is now a Verified Nutritionist` : 'Badge revoked');
        render();
      } catch (err) {
        toast(err.message, true);
      }
    };
    return h('div', { class: 'stack' },
      h('div', { class: 'row' }, h('h2', {}, 'FitFeed nutritionists'), h('span', { class: 'spacer' }), search),
      h('p', { class: 'muted', style: 'margin: 0' }, q
        ? `Members matching "${q}".`
        : 'Verified nutritionists and members who post nutrition content. Search by name or phone to find anyone.'),
      users.length === 0 ? h('p', { class: 'muted' }, 'No members found.') : h('div', { class: 'card' }, h('table', {},
        h('tr', {}, ['Member', 'City', 'Posts', 'Nutrition posts', 'Followers', 'Badge', ''].map((t) => h('th', {}, t))),
        users.map((u) => h('tr', {},
          h('td', {}, h('strong', {}, u.name ?? '—'), h('div', { class: 'muted' }, u.phone)),
          h('td', {}, u.city ?? '—'),
          h('td', {}, u.postCount), h('td', {}, u.nutritionPostCount), h('td', {}, u.followers),
          h('td', {}, u.verifiedNutritionist
            ? h('span', { class: 'pill verified', title: `Since ${when(u.verifiedNutritionistAt)}` }, 'Verified')
            : h('span', { class: 'muted' }, '—')),
          h('td', {}, h('button', { class: u.verifiedNutritionist ? 'danger' : '', onclick: () => toggle(u) },
            u.verifiedNutritionist ? 'Revoke' : 'Grant badge')),
        )),
      )),
    );
  },

  // Ops alerts for centre / trainer ratings of 2 stars or less.
  async alerts() {
    const status = views.alerts.status ?? 'open';
    const PAGE = 50;
    const path = (before) => `/ratings/admin/alerts?status=${status}&limit=${PAGE}${before ? `&before=${encodeURIComponent(before)}` : ''}`;
    const { alerts, counts } = await api(path());
    setBadge('alerts', counts.open);
    const filters = [['open', `Open (${counts.open})`], ['resolved', `Resolved (${counts.resolved})`], ['all', 'All']].map(([s, t]) =>
      h('button', { class: s === status ? 'active' : '', onclick: () => { views.alerts.status = s; render(); } }, t));

    const setStatus = async (a, next) => {
      let note;
      if (next === 'resolved') {
        note = prompt(`Resolve the ${a.stars}★ alert for ${a.targetName ?? 'this target'}. What was done? (optional)`);
        if (note === null) return;
      }
      try {
        await api(`/ratings/admin/alerts/${a.id}`, { method: 'PATCH', body: { status: next, note: note?.trim() || undefined } });
        toast(next === 'resolved' ? 'Alert resolved' : 'Alert reopened');
        render();
      } catch (err) {
        toast(err.message, true);
      }
    };
    const card = (a) => h('div', { class: 'card venue stack' },
      h('div', { class: 'row' },
        h('span', { class: 'stars', title: `${a.stars} of 5` }, stars(a.stars)),
        h('h3', { style: 'margin: 0' }, a.targetName ?? '(deleted)'),
        h('span', { class: 'pill' }, a.targetType === 'venue' ? 'Centre' : 'Trainer'),
        h('span', { class: `pill ${a.status}` }, label(a.status)),
        h('span', { class: 'spacer' }), h('span', { class: 'muted' }, when(a.createdAt))),
      a.targetType === 'venue' && (a.venueArea || a.venueCity)
        ? h('div', { class: 'muted' }, [a.venueArea, a.venueCity].filter(Boolean).join(' · ')) : null,
      Object.keys(a.subRatings ?? {}).length
        ? h('div', { class: 'row', style: 'gap: 6px' }, Object.entries(a.subRatings).map(([k, v]) => h('span', { class: 'pill' }, `${label(k)} ${v}★`)))
        : null,
      h('div', {}, `By ${a.userName ?? 'Member'} · `, h('a', { href: `tel:${a.userPhone}`, class: 'link' }, a.userPhone)),
      a.status === 'resolved' ? h('div', { class: 'muted' },
        `Resolved${a.resolvedByName ? ` by ${a.resolvedByName}` : ''} ${when(a.resolvedAt)}${a.resolutionNote ? ` — ${a.resolutionNote}` : ''}`) : null,
      h('div', { class: 'row' }, a.status === 'open'
        ? h('button', { onclick: () => setStatus(a, 'resolved') }, 'Resolve')
        : h('button', { class: 'ghost', onclick: () => setStatus(a, 'open') }, 'Reopen')),
    );

    const list = h('div', {}, alerts.map(card));
    let oldest = alerts.at(-1)?.createdAt;
    const more = h('button', { class: 'ghost', hidden: alerts.length < PAGE, onclick: async () => {
      more.disabled = true;
      try {
        const next = await api(path(oldest));
        list.append(...next.alerts.map(card));
        oldest = next.alerts.at(-1)?.createdAt ?? oldest;
        more.hidden = next.alerts.length < PAGE;
      } catch (err) {
        toast(err.message, true);
      }
      more.disabled = false;
    } }, 'Load older');

    return h('div', { class: 'stack' },
      h('div', { class: 'row' }, h('h2', {}, 'Rating alerts'), h('span', { class: 'spacer' }), h('div', { class: 'row filters' }, filters)),
      h('p', { class: 'muted', style: 'margin: 0' }, 'Raised automatically when a member rates a centre or trainer 2★ or lower. Call the member, fix it, then resolve.'),
      alerts.length === 0 ? h('p', { class: 'muted' }, status === 'open' ? 'No open alerts. 🎉' : 'Nothing here.') : list,
      more,
    );
  },

  async reports() {
    const { reports } = await api('/admin/reports');
    return h('div', { class: 'stack' },
      h('h2', {}, 'Gym-buddy reports'),
      reports.length === 0 ? h('p', { class: 'muted' }, 'No reports. 🎉') : h('div', { class: 'card' }, h('table', {},
        h('tr', {}, ['When', 'Reporter', 'Reported member', 'Reason'].map((t) => h('th', {}, t))),
        reports.map((r) => h('tr', {},
          h('td', {}, new Date(r.createdAt).toLocaleString('en-IN')),
          h('td', {}, r.reporterName ?? '—'),
          h('td', {}, `${r.reportedName ?? '—'} (${r.reportedPhone})`),
          h('td', {}, r.reason),
        )),
      )),
    );
  },
};

async function render() {
  const signedIn = Boolean(token);
  $('#login').hidden = signedIn;
  $('#tabs').hidden = !signedIn;
  $('#logout').hidden = !signedIn;
  const view = $('#view');
  view.replaceChildren();
  if (!signedIn) {
    $('#login-otp').hidden = true;
    return;
  }
  view.append(h('p', { class: 'muted' }, 'Loading…'));
  if (currentTab !== 'dashboard') refreshBadges(); // dashboard fetches them itself
  try {
    const content = await views[currentTab]();
    view.replaceChildren(content);
  } catch (err) {
    view.replaceChildren(h('p', { class: 'muted' }, err.message));
  }
}

render();

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

$('#tabs').addEventListener('click', (e) => {
  const tab = e.target.dataset?.tab;
  if (!tab) return;
  currentTab = tab;
  document.querySelectorAll('#tabs button').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
  render();
});

// ---------------------------------------------------------------- views
const views = {
  async dashboard() {
    const { stats } = await api('/admin/stats');
    const tiles = [
      ['Members', stats.members],
      ['Partners', stats.partners],
      ['Live venues', stats.liveVenues],
      ['Awaiting review', stats.pendingVenues],
      ['Active subscriptions', stats.activeSubscriptions],
      ['Revenue this month', rupees(stats.revenueThisMonthPaise)],
      ['Check-ins today', stats.checkinsToday],
      ['User reports', stats.reports],
    ];
    return h('div', {},
      h('h2', {}, 'Dashboard'),
      h('div', { class: 'grid' }, tiles.map(([k, v]) =>
        h('div', { class: 'card stat' }, h('div', { class: 'muted' }, k), h('div', { class: 'value' }, v)))),
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
    const { videos } = await api('/admin/videos');
    const form = h('form', { class: 'card stack' },
      h('h3', {}, 'Add video'),
      h('div', { class: 'grid' },
        h('label', {}, 'Category', h('select', { name: 'category' }, VIDEO_CATEGORIES.map((c) => h('option', { value: c }, label(c))))),
        h('label', {}, 'Title', h('input', { name: 'title', required: true })),
        h('label', {}, 'Trainer', h('input', { name: 'trainer' })),
        h('label', {}, 'Level', h('select', { name: 'level' }, ['beginner', 'intermediate', 'advanced'].map((l) => h('option', { value: l }, label(l))))),
        h('label', {}, 'Duration (minutes)', h('input', { name: 'minutes', type: 'number', min: 1 })),
      ),
      h('label', {}, 'Video URL (MP4 / HLS)', h('input', { name: 'url', type: 'url', required: true })),
      h('label', {}, 'Thumbnail URL (optional)', h('input', { name: 'thumb', type: 'url' })),
      h('label', {}, 'Description', h('textarea', { name: 'description' })),
      h('button', { type: 'submit' }, 'Publish video'),
    );
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const f = e.target;
      try {
        await api('/admin/videos', {
          method: 'POST',
          body: {
            category: f.elements.category.value,
            title: f.elements.title.value.trim(),
            trainerName: f.elements.trainer.value.trim() || undefined,
            level: f.elements.level.value,
            durationSeconds: f.elements.minutes.value ? Number(f.elements.minutes.value) * 60 : undefined,
            videoUrl: f.elements.url.value.trim(),
            thumbnailUrl: f.elements.thumb.value.trim() || undefined,
            description: f.elements.description.value.trim() || undefined,
          },
        });
        toast('Video published');
        render();
      } catch (err) {
        toast(err.message, true);
      }
    });

    return h('div', { class: 'stack' },
      h('h2', {}, 'FitKey Studio videos'),
      h('div', { class: 'card' }, h('table', {},
        h('tr', {}, ['Title', 'Category', 'Trainer', 'Level', ''].map((t) => h('th', {}, t))),
        videos.map((v) => h('tr', {},
          h('td', {}, h('a', { href: v.videoUrl, target: '_blank', style: 'color: var(--text)' }, v.title)),
          h('td', {}, label(v.category)), h('td', {}, v.trainerName ?? '—'), h('td', {}, label(v.level)),
          h('td', {}, h('button', { class: 'danger', onclick: async () => {
            if (!confirm(`Delete "${v.title}"?`)) return;
            try { await api(`/admin/videos/${v.id}`, { method: 'DELETE' }); render(); } catch (err) { toast(err.message, true); }
          } }, 'Delete')),
        )),
      )),
      form,
    );
  },

  async contests() {
    const { contests } = await api('/admin/contests');
    const form = h('form', { class: 'card stack' },
      h('h3', {}, 'New contest'),
      h('div', { class: 'grid' },
        h('label', {}, 'Title', h('input', { name: 'title', required: true })),
        h('label', {}, 'Period', h('select', { name: 'period' }, h('option', { value: 'weekly' }, 'Weekly'), h('option', { value: 'monthly' }, 'Monthly'))),
        h('label', {}, 'Metric', h('select', { name: 'metric' },
          h('option', { value: 'checkins' }, 'Check-in days'), h('option', { value: 'running_km' }, 'Running km'), h('option', { value: 'streak' }, 'Longest streak'))),
        h('label', {}, 'Starts', h('input', { name: 'start', type: 'date', value: today(), required: true })),
        h('label', {}, 'Ends', h('input', { name: 'end', type: 'date', required: true })),
        h('label', {}, 'City (optional)', h('input', { name: 'city' })),
      ),
      h('label', {}, 'Reward', h('input', { name: 'reward', placeholder: 'e.g. FITKEY T-shirt + 1 week free' })),
      h('label', {}, 'Description', h('textarea', { name: 'description' })),
      h('button', { type: 'submit' }, 'Create contest'),
    );
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const f = e.target;
      try {
        await api('/admin/contests', {
          method: 'POST',
          body: {
            title: f.elements.title.value.trim(),
            period: f.elements.period.value,
            metric: f.elements.metric.value,
            startsOn: f.elements.start.value,
            endsOn: f.elements.end.value,
            city: f.elements.city.value.trim() || undefined,
            reward: f.elements.reward.value.trim() || undefined,
            description: f.elements.description.value.trim() || undefined,
          },
        });
        toast('Contest created');
        render();
      } catch (err) {
        toast(err.message, true);
      }
    });

    return h('div', { class: 'stack' },
      h('h2', {}, 'Contests'),
      h('div', { class: 'card' }, h('table', {},
        h('tr', {}, ['Contest', 'Metric', 'Dates', 'City', 'Players', ''].map((t) => h('th', {}, t))),
        contests.map((c) => h('tr', {},
          h('td', {}, h('strong', {}, c.title), h('div', { class: 'muted' }, c.reward ?? '')),
          h('td', {}, label(c.metric)), h('td', {}, `${c.startsOn} → ${c.endsOn}`), h('td', {}, c.city ?? 'All'),
          h('td', {}, c.participantCount),
          h('td', {}, h('button', { class: 'danger', onclick: async () => {
            if (!confirm(`Delete "${c.title}"?`)) return;
            try { await api(`/admin/contests/${c.id}`, { method: 'DELETE' }); render(); } catch (err) { toast(err.message, true); }
          } }, 'Delete')),
        )),
      )),
      form,
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
  try {
    const content = await views[currentTab]();
    view.replaceChildren(content);
  } catch (err) {
    view.replaceChildren(h('p', { class: 'muted' }, err.message));
  }
}

render();

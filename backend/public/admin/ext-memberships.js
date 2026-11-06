// Admin tab: direct centre memberships (BRD §2) — plan approvals, FitKey commission, visit payout rates, slot capacity.
const A = window.FitkeyAdmin;
const { h, api, toast, rupees, label, when } = A;

const DURATIONS = { day: 'Day pass', monthly: 'Monthly', quarterly: 'Quarterly', annual: 'Annual' };
let planFilter = 'pending';

const num = (v) => (v === '' || v == null ? null : Number(v));

async function save(path, method, body, msg) {
  try {
    await api(path, { method, body });
    toast(msg);
    A.rerender();
  } catch (err) {
    toast(err.message, true);
  }
}

function plansCard(plans) {
  const filters = ['pending', 'approved', 'rejected', 'all'].map((s) =>
    h('button', { class: s === planFilter ? 'active' : '', onclick: () => { planFilter = s; A.rerender(); } }, label(s)));
  const review = (p, status) => {
    let note;
    if (status === 'rejected') {
      note = prompt(`Why is "${p.name}" rejected? (sent to the centre)`);
      if (!note) return;
    }
    save(`/memberships/admin/plans/${p.id}/review`, 'PATCH', { status, note }, status === 'approved' ? 'Plan approved' : 'Plan rejected');
  };
  return h('div', { class: 'card stack' },
    h('div', { class: 'row' }, h('h3', {}, 'Centre plans'), h('span', { class: 'spacer' }), h('div', { class: 'row filters' }, filters)),
    h('p', { class: 'muted', style: 'margin:0' }, 'New and edited plans stay hidden from members until approved. Switching on/off and offers do not need approval.'),
    plans.length === 0
      ? h('p', { class: 'muted' }, planFilter === 'pending' ? 'No plans waiting for approval.' : 'Nothing here.')
      : h('table', {},
        h('tr', {}, ['Centre', 'Plan', 'Price', 'Limits', 'Inclusions', 'Status', ''].map((t) => h('th', {}, t))),
        plans.map((p) => h('tr', {},
          h('td', {}, h('strong', {}, p.venueName), h('div', { class: 'muted' }, `${p.venueCity ?? ''} · ${p.ownerName ?? 'Partner'}`)),
          h('td', {}, h('strong', {}, p.name), h('div', { class: 'muted' }, `${DURATIONS[p.duration]} · ${p.durationDays} days`),
            p.description ? h('div', { class: 'muted' }, p.description) : null),
          h('td', {}, rupees(p.effectivePricePaise),
            p.offerPct ? h('div', { class: 'muted' }, `${p.offerPct}% off ${rupees(p.pricePaise)}`) : null),
          h('td', {}, [p.maxVisitsPerDay ? `${p.maxVisitsPerDay}/day` : null, p.maxVisitsPerWeek ? `${p.maxVisitsPerWeek}/week` : null]
            .filter(Boolean).join(' · ') || 'Unlimited'),
          h('td', {}, p.inclusions.length ? p.inclusions.join(', ') : '—'),
          h('td', {},
            h('span', { class: `pill ${p.approvalStatus === 'approved' ? 'live' : p.approvalStatus}` }, label(p.approvalStatus)),
            h('div', { class: 'muted' }, p.isActive ? 'Switched on' : 'Switched off'),
            p.reviewNote ? h('div', { class: 'muted' }, `Note: ${p.reviewNote}`) : null,
            h('div', { class: 'muted' }, `Sold: ${p.sold} · ${when(p.updatedAt)}`)),
          h('td', { class: 'row' },
            p.approvalStatus !== 'approved' ? h('button', { onclick: () => review(p, 'approved') }, 'Approve') : null,
            p.approvalStatus !== 'rejected' ? h('button', { class: 'danger', onclick: () => review(p, 'rejected') }, 'Reject') : null),
        )),
      ),
  );
}

function categoriesCard(settings) {
  return h('div', { class: 'card stack' },
    h('h3', {}, 'FitKey commission by category'),
    h('p', { class: 'muted', style: 'margin:0' },
      `Commission FitKey keeps on direct membership sales. Empty = default ${settings.defaultCommissionPct}%. A centre's own value (below) wins over its category; a centre's category is its first listed one.`),
    h('table', {},
      h('tr', {}, ['Category', 'Commission %', 'Visit coin cost', ''].map((t) => h('th', {}, t))),
      settings.categories.map((c) => {
        const input = h('input', { type: 'number', min: 0, max: 100, step: '0.5', value: c.commissionPct ?? '', placeholder: String(settings.defaultCommissionPct), style: 'max-width:120px' });
        return h('tr', {},
          h('td', {}, label(c.category)),
          h('td', {}, input),
          h('td', {}, c.coinCost != null ? `${c.coinCost} coins` : '—'),
          h('td', {}, h('button', { class: 'ghost', onclick: () => save(`/memberships/admin/categories/${c.category}/commission`, 'PUT', { commissionPct: num(input.value) }, 'Commission saved') }, 'Save')),
        );
      }),
    ),
  );
}

function venuesCard(settings) {
  let q = '';
  const tbody = h('tbody');
  const draw = () => {
    tbody.replaceChildren(...settings.venues
      .filter((v) => !q || `${v.name} ${v.city ?? ''} ${v.area ?? ''}`.toLowerCase().includes(q))
      .map((v) => {
        const pct = h('input', { type: 'number', min: 0, max: 100, step: '0.5', value: v.commissionPct ?? '', placeholder: `${v.effectiveCommissionPct}`, style: 'max-width:100px' });
        const payout = h('input', { type: 'number', min: 0, step: '1', value: v.visitPayoutPaise == null ? '' : v.visitPayoutPaise / 100, placeholder: `${v.coinCost}`, style: 'max-width:110px' });
        const cap = h('input', { type: 'number', min: 1, max: 1000, value: v.slotCapacity, style: 'max-width:90px' });
        return h('tr', {},
          h('td', {}, h('strong', {}, v.name), h('div', { class: 'muted' }, `${[v.area, v.city].filter(Boolean).join(', ')} · ${v.categories.map(label).join(', ')}`),
            v.status !== 'live' ? h('span', { class: `pill ${v.status}` }, label(v.status)) : null),
          h('td', {}, pct, h('div', { class: 'muted' }, `Effective ${v.effectiveCommissionPct}%`)),
          h('td', {}, payout, h('div', { class: 'muted' }, `Effective ${rupees(v.effectivePayoutPaise)} (coin cost ${v.coinCost})`)),
          h('td', {}, cap),
          h('td', {}, h('button', { class: 'ghost', onclick: () => {
            const capacity = Number(cap.value);
            if (!Number.isInteger(capacity) || capacity < 1) return toast('Slot capacity must be 1 or more', true);
            save(`/memberships/admin/venues/${v.id}/settings`, 'PATCH', {
              commissionPct: num(pct.value),
              visitPayoutPaise: payout.value === '' ? null : Math.round(Number(payout.value) * 100),
              slotCapacity: capacity,
            }, `${v.name} saved`);
          } }, 'Save')),
        );
      }));
  };
  draw();
  const search = h('input', { placeholder: 'Search centres…', style: 'max-width:260px', oninput: (e) => { q = e.target.value.trim().toLowerCase(); draw(); } });
  return h('div', { class: 'card stack' },
    h('div', { class: 'row' }, h('h3', {}, 'Centre settings'), h('span', { class: 'spacer' }), search),
    h('p', { class: 'muted', style: 'margin:0' },
      'Commission % on direct memberships (empty = category/default) · payout FitKey owes per FitKey-pass visit in ₹ (empty = the centre\'s coin cost, 1 coin = ₹1) · bookable people per hourly slot.'),
    h('table', {}, h('thead', {}, h('tr', {}, ['Centre', 'Commission %', 'Payout ₹ / visit', 'Slot capacity', ''].map((t) => h('th', {}, t)))), tbody),
  );
}

function salesCard(sales) {
  const t = sales.totals;
  return h('div', { class: 'card stack' },
    h('h3', {}, 'Direct membership sales this month'),
    h('div', { class: 'grid' },
      h('div', { class: 'stat' }, h('div', { class: 'muted' }, 'Sold'), h('div', { class: 'value' }, t.count)),
      h('div', { class: 'stat' }, h('div', { class: 'muted' }, 'Gross (mock payments)'), h('div', { class: 'value' }, rupees(t.grossPaise))),
      h('div', { class: 'stat' }, h('div', { class: 'muted' }, 'FitKey commission'), h('div', { class: 'value' }, rupees(t.commissionPaise))),
    ),
    sales.sales.length === 0 ? h('p', { class: 'muted' }, 'No memberships sold yet this month.') : h('table', {},
      h('tr', {}, ['When', 'Centre', 'Plan', 'Member', 'Valid', 'Paid', 'Commission'].map((x) => h('th', {}, x))),
      sales.sales.slice(0, 50).map((s) => h('tr', {},
        h('td', {}, when(s.createdAt)),
        h('td', {}, s.venueName),
        h('td', {}, s.planName),
        h('td', {}, `${s.memberName ?? 'Member'} (…${s.phoneLast4})`),
        h('td', {}, `${s.startsOn} → ${s.endsOn}`),
        h('td', {}, rupees(s.amountPaise)),
        h('td', {}, `${rupees(s.commissionPaise)} (${Number(s.commissionPct)}%)`),
      )),
    ),
  );
}

A.register('memberships', 'Memberships', async () => {
  const [plans, settings, sales] = await Promise.all([
    api(`/memberships/admin/plans?status=${planFilter}`),
    api('/memberships/admin/settings'),
    api('/memberships/admin/sales'),
  ]);
  return h('div', { class: 'stack' },
    h('h2', {}, 'Centre memberships & visit payouts'),
    plansCard(plans.plans),
    salesCard(sales),
    categoriesCard(settings),
    venuesCard(settings),
  );
});

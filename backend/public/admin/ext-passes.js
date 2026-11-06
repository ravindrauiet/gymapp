// FITKEY admin — "Passes & coins" tab (wallet v2): coin packs, session plans, visit coin costs per category and per
// centre, and the coin rules. Loaded by admin.js; talks to /api/v1/wallet/admin/*.
const A = window.FitkeyAdmin;
const { h, api, toast, rupees, label, when } = A;

const SETTING_LABELS = {
  store_max_coin_pct: ['Store: max % of order payable with coins', '%'],
  pass_max_coin_pct: ['FitKey pass: max % payable with referral coins', '%'],
  referral_reward: ['Referral reward (coins, each side, locked until first pass)', 'coins'],
  default_visit_coins: ['Visit cost for a category without a price', 'coins'],
};

async function run(fn, ok) {
  try {
    await fn();
    toast(ok);
    A.rerender();
  } catch (err) {
    toast(err.message, true);
  }
}

const num = (v) => Number(String(v).trim());

/** Form for a coin pack or session plan (create when `item` is null, edit otherwise). */
function itemForm(kind, item) {
  const isPack = kind === 'pack';
  const f = h('form', { class: 'card stack' },
    h('h3', {}, item ? `Edit ${item.name}` : isPack ? 'New coin pack' : 'New session plan'),
    h('div', { class: 'grid' },
      h('label', {}, 'Code', h('input', { name: 'code', required: true, value: item?.code ?? '', placeholder: isPack ? 'coins_5000' : 'sessions_quarterly' })),
      h('label', {}, 'Name', h('input', { name: 'name', required: true, value: item?.name ?? '' })),
      h('label', {}, 'Price (₹)', h('input', { name: 'price', type: 'number', min: 1, step: '0.01', required: true, value: item ? item.pricePaise / 100 : '' })),
      isPack
        ? h('label', {}, 'Coins credited', h('input', { name: 'coins', type: 'number', min: 1, required: true, value: item?.coins ?? '' }))
        : h('label', {}, 'Sessions (visits)', h('input', { name: 'sessions', type: 'number', min: 1, required: true, value: item?.sessions ?? '' })),
      h('label', {}, 'Validity (days)', h('input', { name: 'days', type: 'number', min: 1, required: true, value: item?.validityDays ?? (isPack ? 180 : 30) })),
      h('label', {}, 'Sort order', h('input', { name: 'sort', type: 'number', value: item?.sortOrder ?? 0 })),
    ),
    h('label', {}, 'Description', h('input', { name: 'description', value: item?.description ?? '' })),
    h('label', { class: 'row' }, h('input', { type: 'checkbox', name: 'active', style: 'width:auto', checked: item ? item.isActive : true }), 'Active (visible in the app)'),
    h('div', { class: 'row' },
      h('button', { type: 'submit' }, item ? 'Save changes' : 'Create'),
      item ? h('button', { type: 'button', class: 'ghost', onclick: () => A.rerender() }, 'Cancel') : null),
  );
  f.addEventListener('submit', (e) => {
    e.preventDefault();
    const el = f.elements;
    const body = {
      code: el.code.value.trim(),
      name: el.name.value.trim(),
      description: el.description.value.trim() || null,
      pricePaise: Math.round(num(el.price.value) * 100),
      validityDays: num(el.days.value),
      sortOrder: num(el.sort.value || 0),
      isActive: el.active.checked,
      ...(isPack ? { coins: num(el.coins.value) } : { sessions: num(el.sessions.value) }),
    };
    const path = isPack ? '/wallet/admin/coin-packs' : '/wallet/admin/session-plans';
    run(() => api(item ? `${path}/${item.id}` : path, { method: item ? 'PATCH' : 'POST', body }), item ? 'Saved' : 'Created');
  });
  return f;
}

function catalogTable(kind, items, onEdit) {
  const isPack = kind === 'pack';
  const path = isPack ? '/wallet/admin/coin-packs' : '/wallet/admin/session-plans';
  return h('table', {},
    h('tr', {}, (isPack ? ['Pack', 'Price', 'Coins', 'Validity', 'Status', ''] : ['Plan', 'Price', 'Sessions', 'Per visit', 'Validity', 'Status', ''])
      .map((t) => h('th', {}, t))),
    items.map((p) => h('tr', {},
      h('td', {}, h('strong', {}, p.name), h('div', { class: 'muted' }, p.code)),
      h('td', {}, rupees(p.pricePaise)),
      isPack
        ? h('td', {}, p.coins.toLocaleString('en-IN'), p.bonusCoins ? h('div', { class: 'muted' }, `+${p.bonusCoins} bonus`) : null)
        : h('td', {}, p.sessions),
      isPack ? null : h('td', {}, rupees(p.perSessionPaise)),
      h('td', {}, `${p.validityDays} days`),
      h('td', {}, h('span', { class: `pill ${p.isActive ? 'live' : 'rejected'}` }, p.isActive ? 'Active' : 'Hidden')),
      h('td', { class: 'row' },
        h('button', { class: 'ghost', onclick: () => onEdit(p) }, 'Edit'),
        h('button', { class: 'ghost', onclick: () => run(() => api(`${path}/${p.id}`, { method: 'PATCH', body: { isActive: !p.isActive } }), 'Updated') },
          p.isActive ? 'Hide' : 'Show')),
    )),
  );
}

async function venueCosts(costs) {
  const box = h('div', { class: 'stack' });
  const search = h('input', { placeholder: 'Search centre or city…' });
  const list = h('div', {});
  const load = async () => {
    list.replaceChildren(h('p', { class: 'muted' }, 'Loading…'));
    try {
      const { venues } = await api(`/wallet/admin/venue-costs?q=${encodeURIComponent(search.value.trim())}`);
      list.replaceChildren(h('table', {},
        h('tr', {}, ['Centre', 'Category', 'Category price', 'Override', 'Visit cost', ''].map((t) => h('th', {}, t))),
        venues.map((v) => {
          const input = h('input', { type: 'number', min: 1, value: v.overrideCoins ?? '', placeholder: '—', style: 'width:90px' });
          return h('tr', {},
            h('td', {}, h('strong', {}, v.name), h('div', { class: 'muted' }, [v.area, v.city].filter(Boolean).join(', '), ' · ', label(v.status))),
            h('td', {}, v.categories[0] ? label(v.categories[0]) : '—'),
            h('td', {}, v.categoryCoins ?? '—'),
            h('td', {}, input),
            h('td', {}, h('strong', {}, `${v.coins} coins`)),
            h('td', { class: 'row' },
              h('button', { class: 'ghost', onclick: () => {
                const coins = input.value.trim() ? num(input.value) : null;
                run(() => api(`/wallet/admin/venue-costs/${v.id}`, { method: 'PUT', body: { coins } }), coins ? 'Override saved' : 'Override removed');
              } }, 'Save'),
              v.overrideCoins ? h('button', { class: 'ghost', onclick: () => run(() => api(`/wallet/admin/venue-costs/${v.id}`, { method: 'PUT', body: { coins: null } }), 'Override removed') }, 'Use category') : null),
          );
        }),
      ));
    } catch (err) {
      list.replaceChildren(h('p', { class: 'muted' }, err.message));
    }
  };
  let t;
  search.addEventListener('input', () => { clearTimeout(t); t = setTimeout(load, 300); });
  box.append(
    h('h3', {}, 'Visit cost per centre'),
    h('p', { class: 'muted' }, 'A centre costs the price of its first category unless you set an override here. Members with a session plan pay 1 session instead; legacy passes visit free.'),
    search, list,
  );
  load();
  void costs;
  return box;
}

A.register('passes', 'Passes & coins', async () => {
  const data = await api('/wallet/admin/catalog');
  const root = h('div', { class: 'stack' });
  let editPack = null;
  let editPlan = null;

  const draw = async () => {
    const s = data.stats;
    const categoryRows = h('table', {},
      h('tr', {}, ['Category', 'Coins per visit', ''].map((t) => h('th', {}, t))),
      data.categoryCosts.map((c) => {
        const input = h('input', { type: 'number', min: 1, value: c.coins, style: 'width:100px' });
        return h('tr', {},
          h('td', {}, label(c.category)),
          h('td', {}, input),
          h('td', {}, h('button', { class: 'ghost', onclick: () => run(() => api(`/wallet/admin/category-costs/${c.category}`, { method: 'PUT', body: { coins: num(input.value) } }), 'Price saved') }, 'Save')));
      }),
    );
    const addCat = h('form', { class: 'row' },
      h('input', { name: 'cat', placeholder: 'new_category', style: 'width:180px' }),
      h('input', { name: 'coins', type: 'number', min: 1, placeholder: 'coins', style: 'width:100px' }),
      h('button', { type: 'submit', class: 'ghost' }, 'Add category price'));
    addCat.addEventListener('submit', (e) => {
      e.preventDefault();
      run(() => api(`/wallet/admin/category-costs/${addCat.elements.cat.value.trim()}`, { method: 'PUT', body: { coins: num(addCat.elements.coins.value) } }), 'Price saved');
    });

    const settings = h('table', {},
      Object.entries(SETTING_LABELS).map(([key, [text, unit]]) => {
        const input = h('input', { type: 'number', min: 0, value: data.settings[key], style: 'width:100px' });
        return h('tr', {},
          h('td', {}, text),
          h('td', { class: 'row' }, input, h('span', { class: 'muted' }, unit)),
          h('td', {}, h('button', { class: 'ghost', onclick: () => run(() => api(`/wallet/admin/settings/${key}`, { method: 'PUT', body: { value: num(input.value) } }), 'Rule saved') }, 'Save')));
      }),
    );

    const purchases = h('div', {}, h('p', { class: 'muted' }, 'Loading…'));
    api('/wallet/admin/purchases').then(({ purchases: rows }) => {
      purchases.replaceChildren(rows.length
        ? h('table', {},
          h('tr', {}, ['When', 'Member', 'Item', 'Price', 'Coins used', 'Paid', 'Balance', 'Valid till'].map((t) => h('th', {}, t))),
          rows.map((p) => h('tr', {},
            h('td', {}, when(p.createdAt)),
            h('td', {}, p.userName ?? '—', h('div', { class: 'muted' }, p.phone)),
            h('td', {}, p.name, h('div', { class: 'muted' }, p.kind === 'coin_pack' ? 'Coin pack' : 'Session plan')),
            h('td', {}, rupees(p.pricePaise)),
            h('td', {}, p.coinsRedeemed || '—'),
            h('td', {}, rupees(p.paidPaise), h('div', { class: 'muted' }, p.paymentRef ?? '')),
            h('td', {}, p.kind === 'coin_pack' ? `${p.coinsRemaining}/${p.coins} coins` : `${p.sessionsLeft}/${p.sessionsTotal} sessions`),
            h('td', {}, when(p.expiresAt), h('div', { class: 'muted' }, label(p.state))),
          )))
        : h('p', { class: 'muted' }, 'No FitKey pass purchases yet.'));
    }).catch((err) => purchases.replaceChildren(h('p', { class: 'muted' }, err.message)));

    root.replaceChildren(
      h('h2', {}, 'Passes & coins'),
      h('p', { class: 'muted' }, 'FitKey pass comes in two models: coin packs (each visit deducts the centre’s coin cost) and session plans (1 session per visit at any centre). Payments are in demo mode (PAYMENTS_MODE=mock).'),
      h('div', { class: 'row' },
        h('div', { class: 'card' }, h('div', { class: 'muted' }, 'Purchases (30 days)'), h('strong', {}, s.purchases30d)),
        h('div', { class: 'card' }, h('div', { class: 'muted' }, 'Revenue (30 days)'), h('strong', {}, rupees(s.revenue30dPaise))),
        h('div', { class: 'card' }, h('div', { class: 'muted' }, 'Unspent FitKey coins'), h('strong', {}, s.coinsOutstanding.toLocaleString('en-IN'))),
        h('div', { class: 'card' }, h('div', { class: 'muted' }, 'Unused sessions'), h('strong', {}, s.sessionsOutstanding.toLocaleString('en-IN')))),
      h('div', { class: 'card stack' }, h('h3', {}, 'Coin packs'), catalogTable('pack', data.coinPacks, (p) => { editPack = p; draw(); })),
      itemForm('pack', editPack),
      h('div', { class: 'card stack' }, h('h3', {}, 'Session plans'), catalogTable('plan', data.sessionPlans, (p) => { editPlan = p; draw(); })),
      itemForm('plan', editPlan),
      h('div', { class: 'card stack' }, h('h3', {}, 'Visit cost per category'),
        h('p', { class: 'muted' }, 'Coins deducted for one visit (1 coin = ₹1). Uses the centre’s first listed category.'), categoryRows, addCat),
      h('div', { class: 'card stack' }, await venueCosts(data.categoryCosts)),
      h('div', { class: 'card stack' }, h('h3', {}, 'Coin rules'), settings,
        h('p', { class: 'muted' }, 'FitKey coins (bought) pay for visits only. Referral coins: Store and FitKey pass checkout. ProveIt coins: Store only (used first).')),
      h('div', { class: 'card stack' }, h('h3', {}, 'Latest purchases'), purchases),
    );
  };
  await draw();
  return root;
});

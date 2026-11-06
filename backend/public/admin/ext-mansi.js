// Ask Mansi — off-topic messages Mansi declined (BRD §6). Anonymous and redacted on the server
// (no user id; phones, emails and names stripped), so the team can see what members ask for and tune the allowed list.
const A = window.FitkeyAdmin;
const { h } = A;

const state = { days: 30, category: '' };

A.register('mansi', 'Ask Mansi', async () => {
  const qs = new URLSearchParams({ days: String(state.days) });
  if (state.category) qs.set('category', state.category);
  const data = await A.api(`/ai/admin/mansi-declines?${qs}`);

  const daysSelect = h('select', { onchange: (e) => { state.days = Number(e.target.value); A.rerender(); } },
    [1, 7, 30, 90, 365].map((d) => h('option', { value: d, selected: d === state.days }, d === 1 ? 'Last 24 hours' : `Last ${d} days`)));
  const catSelect = h('select', { onchange: (e) => { state.category = e.target.value; A.rerender(); } },
    h('option', { value: '' }, 'All categories'),
    data.byCategory.map((c) => h('option', { value: c.category, selected: c.category === state.category }, A.label(c.category))));

  const tiles = [
    ['Declined messages', data.total],
    ['Last 24 hours', data.last24h],
    ['Top category', data.byCategory[0] ? A.label(data.byCategory[0].category) : '—'],
  ];

  return h('div', { class: 'stack' },
    h('div', { class: 'row' }, h('h2', {}, 'Ask Mansi — declined topics'), h('span', { class: 'spacer' }),
      h('div', { class: 'row filters' }, daysSelect, catSelect)),
    h('p', { class: 'muted', style: 'margin: 0' },
      'Mansi only answers fitness, nutrition, wellness, health and FitKey questions. These are messages she declined ' +
      '("mixed" = she answered the health part and declined the rest). Stored without user ids; phone numbers, emails ' +
      'and names are removed. If members keep asking something that should be allowed, update the topic rules in ' +
      'backend/src/routes/ai.js.'),
    h('div', { class: 'grid' }, tiles.map(([k, v]) =>
      h('div', { class: 'card stat' }, h('div', { class: 'muted' }, k), h('div', { class: 'value' }, v)))),
    data.byCategory.length === 0 ? null : h('div', { class: 'card' }, h('table', {},
      h('tr', {}, ['Category', 'Declined', 'Of which mixed', 'Share'].map((t) => h('th', {}, t))),
      data.byCategory.map((c) => h('tr', { style: 'cursor: pointer', onclick: () => { state.category = c.category; A.rerender(); } },
        h('td', {}, A.label(c.category)),
        h('td', {}, c.count),
        h('td', {}, c.mixed),
        h('td', {}, data.total ? `${Math.round((c.count / data.total) * 100)}%` : '—'),
      )),
    )),
    data.items.length === 0
      ? h('p', { class: 'muted' }, 'Nothing declined in this period. 🎉')
      : h('div', { class: 'card' }, h('table', {},
        h('tr', {}, ['When', 'Category', 'Type', 'Caught by', 'Message (redacted)'].map((t) => h('th', {}, t))),
        data.items.map((r) => h('tr', {},
          h('td', { style: 'white-space: nowrap' }, A.when(r.createdAt)),
          h('td', {}, A.label(r.category)),
          h('td', {}, h('span', { class: `pill ${r.verdict === 'mixed' ? 'pending' : 'rejected'}` }, r.verdict === 'mixed' ? 'Mixed' : 'Declined')),
          h('td', { class: 'muted' }, A.label(r.source)),
          h('td', {}, r.excerpt),
        )),
      )),
    data.items.length >= 300 ? h('p', { class: 'muted' }, 'Showing the latest 300 messages.') : null,
  );
});

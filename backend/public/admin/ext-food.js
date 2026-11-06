// Admin → "Food DB" tab (BRD §5): Indian food database (INDB 2024, ICMR-NIN) — import stats + review of rows that
// carry a Data Note (e.g. a "serving" above 1,200 kcal = probably the whole recipe). Data-Note rows stay HIDDEN from
// member search until approved here; "Fix serving" sets a serving unit + weight (per-serving values are then
// recomputed from the per-100 g values) and survives re-imports. Import itself runs on the server:
//   npm run import-foods -- <FitKey_Food_Database.xlsx> [--dry-run]
const A = window.FitkeyAdmin;
const { h, api, toast, when } = A;

const STATUS = ['pending', 'noted', 'approved', 'hidden', 'live', 'all'];
const STATUS_LABEL = { pending: 'Needs review', noted: 'All with Data Note', approved: 'Approved', hidden: 'Hidden', live: 'Live', all: 'All' };
const DIET = { veg: 'Veg', egg: 'Egg', nonveg: 'Non-veg' };
const state = { status: 'pending', q: '', offset: 0 };
const LIMIT = 50;

const v = (x, unit = '') => (x == null ? '—' : `${Math.round(x * 10) / 10}${unit}`);
const n = (x) => (x ?? 0).toLocaleString('en-IN');

function statCard(label, value, sub) {
  return h('div', { class: 'card', style: 'flex:1; min-width:140px' },
    h('div', { class: 'muted' }, label),
    h('div', { style: 'font-size:24px; font-weight:800' }, value),
    sub ? h('div', { class: 'muted', style: 'font-size:12px' }, sub) : null);
}

function foodRow(f) {
  const unit = h('input', { value: f.servingUnit ?? '', style: 'width:110px', placeholder: 'e.g. 1 plate' });
  const weight = h('input', { type: 'number', min: '1', step: '1', value: f.servingWeightG ?? '', style: 'width:80px', placeholder: 'g' });
  const comment = h('input', { value: f.reviewComment ?? '', style: 'width:150px', placeholder: 'comment (optional)' });
  const send = async (body, msg) => {
    try {
      await api(`/nutrition/admin/food-db/foods/${encodeURIComponent(f.id)}`, { method: 'PATCH', body: { ...body, comment: comment.value.trim() || undefined } });
      toast(msg);
      A.rerender();
    } catch (e) {
      toast(e.message, true);
    }
  };
  const fixServing = () => {
    const w = Number(weight.value);
    if (!unit.value.trim() || !(w > 0)) return toast('Enter a serving unit and a weight in grams', true);
    send({ action: 'approve', servingUnit: unit.value.trim(), servingWeightG: w }, `${f.name}: serving fixed & approved`);
  };
  const per100 = f.per100g ?? {};
  const ps = f.perServing ?? {};
  return h('tr', {},
    h('td', {}, h('div', { style: 'font-weight:700' }, f.name), h('div', { class: 'muted', style: 'font-size:12px' },
      `${f.id} · ${f.type === 'cooked' ? 'Cooked dish' : 'Raw ingredient'} · ${f.category}${f.diet ? ` · ${DIET[f.diet]}` : ''}`),
      f.localName ? h('div', { class: 'muted', style: 'font-size:12px' }, `aka ${f.localName}`) : null),
    h('td', {}, f.dataNote ? h('span', { class: 'pill pending' }, f.dataNote) : h('span', { class: 'muted' }, '—')),
    h('td', {}, h('div', {}, `${f.servingUnit} (${v(f.servingWeightG, ' g')}${f.servingWeightComputed ? ', computed' : ''})`),
      f.file && (f.file.servingUnit !== f.servingUnit || f.file.servingWeightG !== f.servingWeightG)
        ? h('div', { class: 'muted', style: 'font-size:12px' }, `file: ${f.file.servingUnit} (${v(f.file.servingWeightG, ' g')}), ${v(f.file.kcal)} kcal`) : null),
    h('td', {}, h('b', {}, v(ps.calories, ' kcal')), h('div', { class: 'muted', style: 'font-size:12px' }, `P ${v(ps.proteinG)} · C ${v(ps.carbsG)} · F ${v(ps.fatG)}`)),
    h('td', {}, v(per100.calories, ' kcal'), h('div', { class: 'muted', style: 'font-size:12px' }, `P ${v(per100.proteinG)} · C ${v(per100.carbsG)} · F ${v(per100.fatG)}`)),
    h('td', {}, h('span', { class: `pill ${f.reviewStatus === 'hidden' ? 'rejected' : f.reviewStatus === 'pending' ? 'pending' : 'verified'}` }, STATUS_LABEL[f.reviewStatus] ?? f.reviewStatus),
      f.reviewedAt ? h('div', { class: 'muted', style: 'font-size:12px' }, when(f.reviewedAt)) : null),
    h('td', {},
      h('div', { class: 'row', style: 'gap:6px; flex-wrap:wrap' },
        f.reviewStatus !== 'approved' && f.reviewStatus !== 'live'
          ? h('button', { onclick: () => send({ action: 'approve' }, `${f.name} approved — now searchable`) }, 'Approve as is') : null,
        f.reviewStatus !== 'hidden'
          ? h('button', { class: 'ghost', onclick: () => send({ action: 'hide' }, `${f.name} hidden from search`) }, 'Hide')
          : h('button', { class: 'ghost', onclick: () => send({ action: 'unhide' }, `${f.name} un-hidden`) }, 'Un-hide')),
      h('div', { class: 'row', style: 'gap:6px; margin-top:6px; flex-wrap:wrap' }, unit, weight, h('button', { onclick: fixServing }, 'Fix serving & approve')),
      h('div', { style: 'margin-top:6px' }, comment)),
  );
}

A.register('food', 'Food DB', async () => {
  const qs = new URLSearchParams({ status: state.status, limit: String(LIMIT), offset: String(state.offset) });
  if (state.q) qs.set('q', state.q);
  const [stats, list] = await Promise.all([api('/nutrition/admin/food-db/stats'), api(`/nutrition/admin/food-db/foods?${qs}`)]);
  const t = stats.totals;

  if (t.total === 0) {
    return h('div', { class: 'stack' },
      h('h2', {}, 'Food database'),
      h('div', { class: 'card' },
        h('p', {}, 'The Indian food database has not been imported yet — members still see the old food list.'),
        h('p', {}, 'On the server, from the backend folder:'),
        h('pre', {}, 'npm run import-foods -- "<path>/FitKey_Food_Database.xlsx" --dry-run\nnpm run import-foods -- "<path>/FitKey_Food_Database.xlsx"'),
        h('p', { class: 'muted' }, 'The dry run prints the detected column mapping and a report (cooked vs raw, categories, Data-Note rows, blanks) and writes nothing.')),
      h('p', { class: 'muted' }, stats.credit));
  }

  const search = h('input', { placeholder: 'Search name / local name / Food ID', value: state.q, style: 'min-width:240px' });
  search.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      state.q = search.value.trim();
      state.offset = 0;
      A.rerender();
    }
  });
  const filters = STATUS.map((s) => h('button', {
    class: s === state.status ? 'active' : '',
    onclick: () => { state.status = s; state.offset = 0; A.rerender(); },
  }, `${STATUS_LABEL[s]}${s === 'pending' && t.pending ? ` (${t.pending})` : ''}`));

  const last = stats.imports[0];
  const pager = h('div', { class: 'row' },
    h('span', { class: 'muted' }, `${list.total ? state.offset + 1 : 0}–${state.offset + list.foods.length} of ${n(list.total)}`),
    h('span', { class: 'spacer' }),
    h('button', { class: 'ghost', disabled: state.offset === 0, onclick: () => { state.offset = Math.max(0, state.offset - LIMIT); A.rerender(); } }, 'Previous'),
    h('button', { class: 'ghost', disabled: state.offset + LIMIT >= list.total, onclick: () => { state.offset += LIMIT; A.rerender(); } }, 'Next'));

  return h('div', { class: 'stack' },
    h('div', { class: 'row' }, h('h2', {}, 'Food database'), h('span', { class: 'spacer' }), h('span', { class: 'muted' }, stats.credit)),
    h('div', { class: 'row', style: 'gap:12px; flex-wrap:wrap' },
      statCard('Foods', n(t.total), `${n(t.cooked)} cooked dishes · ${n(t.raw)} raw ingredients`),
      statCard('Searchable', n(t.live + t.approved), `${n(t.approved)} approved after review`),
      statCard('Needs review', n(t.pending), `${n(t.withNote)} rows have a Data Note`),
      statCard('Hidden', n(t.hidden), `${n(t.servingFixed)} servings fixed`),
      statCard('Diet tags', `${n(t.veg)} / ${n(t.egg)} / ${n(t.nonveg)}`, `veg / egg / non-veg · ${n(t.untagged)} untagged`),
      statCard('In meal logs', n(stats.usage.logs), `${n(stats.usage.members)} members`)),
    h('div', { class: 'card' },
      h('div', {}, last ? `Last import: ${last.fileName} — ${when(last.createdAt)} · ${n(last.rowsTotal)} rows · ${n(last.inserted)} new · ${n(last.updated)} updated · ${n(last.skipped)} skipped`
        : 'No import recorded.'),
      h('div', { class: 'muted', style: 'font-size:12px; margin-top:4px' },
        `Old food list: ${n(stats.legacy.dummy)} demo rows ${stats.legacy.dummyHiddenFromSearch ? 'hidden from search' : 'still shown'} (existing meal logs unaffected) · ${n(stats.legacy.packaged)} barcode foods kept. `,
        'Veg tags come from keyword rules in the source file — spot-check before relying on a strict veg filter. Re-import: ', h('code', {}, stats.importCommand)),
      last?.report?.invalid?.length ? h('details', { style: 'margin-top:6px' }, h('summary', {}, `${last.report.invalid.length} skipped rows in the last import`),
        h('ul', {}, last.report.invalid.slice(0, 50).map((x) => h('li', {}, `row ${x.row}: ${x.error} ${x.foodId ?? ''} ${x.name ?? ''}`)))) : null,
      last?.report?.bigServingNoNote?.length ? h('details', { style: 'margin-top:6px' }, h('summary', {}, `${last.report.bigServingNoNote.length} servings above 1,200 kcal without a Data Note`),
        h('ul', {}, last.report.bigServingNoNote.slice(0, 50).map((x) => h('li', {}, `${x.foodId} ${x.name} — ${x.kcal} kcal`)))) : null),
    h('details', { class: 'card' }, h('summary', {}, 'Per category'),
      h('table', {}, h('tr', {}, ['Type', 'Category', 'Foods', 'Searchable'].map((x) => h('th', {}, x))),
        stats.byCategory.map((c) => h('tr', {}, h('td', {}, c.type), h('td', {}, c.name), h('td', {}, n(c.count)), h('td', {}, n(c.searchable)))))),
    h('div', { class: 'row filters', style: 'flex-wrap:wrap' }, filters, h('span', { class: 'spacer' }), search),
    h('p', { class: 'muted', style: 'margin:0' }, 'Rows with a Data Note are hidden from members until approved. "Fix serving" sets the serving unit + grams; calories and macros per serving are recomputed from the per-100 g values. — = not available in the source.'),
    list.foods.length === 0 ? h('p', { class: 'muted' }, state.status === 'pending' ? 'Nothing waiting for review. 🎉' : 'No foods here.') : h('div', { class: 'card' }, h('table', {},
      h('tr', {}, ['Food', 'Data Note', 'Serving', 'Per serving', 'Per 100 g', 'Status', 'Action'].map((x) => h('th', {}, x))),
      list.foods.map(foodRow))),
    pager);
});

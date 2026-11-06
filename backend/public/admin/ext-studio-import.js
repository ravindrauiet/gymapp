// FITKEY admin — "Studio import" tab (BRD §7): import the owner's YouTube sheet into Studio.
// Upserts on the YouTube video id, so the same sheet can be uploaded again later without duplicates.
// Single videos are still added / edited / deleted in the "Videos" tab.
const A = window.FitkeyAdmin;
const { h, api, toast } = A;

const fmtDur = (s) => (s ? `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}` : 'unknown');
const TEMPLATE = 'Studio Name,Playlist Link,Video Link\n' +
  'Home Workout (No Equipment),,https://youtu.be/VIDEO_ID\n' +
  'Karate,https://youtube.com/playlist?list=PLAYLIST_ID,\n';

let lastReport = null;

function readBase64(file) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).split(',')[1] ?? '');
    r.onerror = () => reject(new Error('Could not read the file'));
    r.readAsDataURL(file);
  });
}

function tile(label, value, tone) {
  return h('div', { class: 'card stat' }, h('div', { class: 'muted' }, label),
    h('div', { class: 'value', style: tone ? `color: var(--${tone})` : null }, String(value)));
}

function reportView(r) {
  const t = r.totals;
  return h('div', { class: 'stack' },
    h('div', { class: 'row' },
      h('h3', {}, r.dryRun ? 'Import preview (nothing saved)' : 'Import report'),
      h('span', { class: 'spacer' }),
      h('span', { class: 'muted' }, `Metadata: ${r.metadataSource} · ${r.tookSeconds}s`)),
    h('div', { class: 'grid' },
      tile('Rows', t.rows), tile('Unique videos', t.videos), tile(r.dryRun ? 'Would add' : 'Added', t.added, 'lime'),
      tile('Updated', t.updated, 'sky'), tile('Unchanged', t.unchanged), tile('Skipped', t.skipped, t.skipped ? 'danger' : null),
      tile('Duration unknown', t.durationUnknown, t.durationUnknown ? 'orange' : null)),
    !r.dryRun ? h('p', { class: 'muted' }, `Old Google sample clips set inactive: ${r.samplesDeactivated}`) : null,
    r.warnings.length ? h('div', { class: 'card stack' }, h('strong', {}, 'Warnings'),
      h('ul', {}, r.warnings.map((w) => h('li', {}, w)))) : null,
    h('div', { class: 'card' }, h('table', {},
      h('tr', {}, ['Row', 'Studio Name', 'Mapped to', 'Found', 'Added', 'Updated', 'Same', 'Skipped', 'Playlist'].map((x) => h('th', {}, x))),
      r.rows.map((row) => h('tr', {},
        h('td', {}, row.line), h('td', {}, row.name || '—'),
        h('td', {}, row.error ? h('span', { style: 'color: var(--danger)' }, row.error) : `${row.group} · ${row.types.join(', ') || '—'}`),
        h('td', {}, row.found), h('td', {}, row.added), h('td', {}, row.updated), h('td', {}, row.unchanged), h('td', {}, row.skipped),
        h('td', {}, row.playlists.map((p) => h('div', { class: 'muted' }, p.error ? `✖ ${p.error}` :
          `${p.title ?? p.id}: ${p.listed}${p.expected != null ? ` of ${p.expected}` : ''} (${p.via})`))),
      )))),
    r.skipped.length ? h('div', { class: 'card stack' },
      h('strong', {}, `Skipped (${r.skipped.length}) — broken, private, deleted or embedding disabled`),
      h('table', {},
        h('tr', {}, ['Row', 'Studio Name', 'Link', 'Reason'].map((x) => h('th', {}, x))),
        r.skipped.map((s) => h('tr', {},
          h('td', {}, s.line), h('td', {}, s.name || '—'),
          h('td', {}, s.link ? h('a', { href: s.link, target: '_blank', rel: 'noopener', style: 'color: var(--sky)' },
            s.title ?? s.youtubeId ?? s.playlistId ?? s.link) : '—'),
          h('td', {}, s.reason))))) : null,
    h('details', { class: 'card' },
      h('summary', {}, `All videos in this import (${r.items.length})`),
      h('table', {},
        h('tr', {}, ['Status', 'Video', 'Channel', 'Group / types', 'Level', 'Equipment', 'Duration'].map((x) => h('th', {}, x))),
        r.items.map((i) => h('tr', {},
          h('td', {}, h('span', { class: `pill ${i.status === 'added' ? 'live' : ''}` }, i.status)),
          h('td', {}, h('a', { href: `https://www.youtube.com/watch?v=${i.youtubeId}`, target: '_blank', rel: 'noopener', style: 'color: var(--text)' }, i.title)),
          h('td', {}, i.channel ?? '—'),
          h('td', {}, h('div', {}, i.group), h('div', { class: 'muted' }, i.types.join(', '))),
          h('td', {}, i.level), h('td', {}, i.equipment ?? '—'), h('td', {}, fmtDur(i.durationSeconds))))),
    ),
  );
}

async function view() {
  const { videos, samples } = await api('/videos/admin/youtube');

  const fileInput = h('input', { type: 'file', accept: '.xlsx,.csv,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
  const text = h('textarea', { rows: 6, placeholder: 'Or paste rows copied from the sheet (Studio Name | Playlist Link | Video Link), one per line' });
  const dry = h('input', { type: 'checkbox', style: 'width:auto' });
  const retag = h('input', { type: 'checkbox', style: 'width:auto' });
  const hideSamples = h('input', { type: 'checkbox', style: 'width:auto', checked: true });
  const go = h('button', { type: 'submit' }, 'Import');
  const out = h('div', {}, lastReport ? reportView(lastReport) : null);

  const form = h('form', { class: 'card stack' },
    h('h3', {}, 'Import YouTube sheet'),
    h('p', { class: 'muted' },
      'Columns: Studio Name, Playlist Link, Video Link (header row optional; optional Group, Types, Level, Equipment, Trainer columns override the automatic mapping). ',
      'Playlists are expanded into their videos. Videos are matched on their YouTube id, so re-uploading the sheet updates instead of duplicating. ',
      'Videos stay on YouTube and play in the official embedded player; private, deleted or embed-blocked links are skipped and listed below.'),
    h('label', {}, 'Sheet (.xlsx or .csv)', fileInput),
    h('label', {}, 'Paste rows', text),
    h('div', { class: 'row' },
      h('label', { class: 'row' }, dry, 'Preview only (don\'t save)'),
      h('label', { class: 'row' }, retag, 'Overwrite title / group / types / level / equipment of videos already imported'),
      h('label', { class: 'row' }, hideSamples, 'Hide the old Google sample clips')),
    h('div', { class: 'row' }, go,
      h('a', { href: URL.createObjectURL(new Blob([TEMPLATE], { type: 'text/csv' })), download: 'studio-youtube-template.csv', style: 'color: var(--sky)' },
        'Download CSV template')),
  );
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const file = fileInput.files?.[0];
    if (!file && !text.value.trim()) return toast('Choose a file or paste rows', true);
    const body = { dryRun: dry.checked, retag: retag.checked, deactivateSamples: hideSamples.checked };
    try {
      if (file) body.file = { name: file.name, base64: await readBase64(file) };
      else body.text = text.value;
      go.disabled = true;
      go.textContent = 'Importing… (checks every video on YouTube, can take a minute)';
      const { report } = await api('/videos/admin/youtube/import', { method: 'POST', body });
      lastReport = report;
      toast(report.dryRun ? `Preview: ${report.totals.added} new, ${report.totals.skipped} skipped`
        : `Imported: ${report.totals.added} added, ${report.totals.updated} updated, ${report.totals.skipped} skipped`);
      if (report.dryRun) out.replaceChildren(reportView(report));
      else A.rerender();
    } catch (err) {
      toast(err.message, true);
    } finally {
      go.disabled = false;
      go.textContent = 'Import';
    }
  });

  const refresh = h('button', { class: 'ghost', onclick: async () => {
    refresh.disabled = true;
    try {
      const { result } = await api('/videos/admin/youtube/refresh', { method: 'POST' });
      toast(`Checked ${result.checked}, filled ${result.updated}${result.failed.length ? `, ${result.failed.length} unavailable` : ''}`);
      A.rerender();
    } catch (err) { toast(err.message, true); } finally { refresh.disabled = false; }
  } }, 'Fetch missing YouTube details');

  const sampleBtn = h('button', { class: 'ghost', onclick: async () => {
    try {
      await api('/videos/admin/samples', { method: 'POST', body: { active: samples.active === 0 } });
      A.rerender();
    } catch (err) { toast(err.message, true); }
  } }, samples.active ? 'Hide sample clips' : 'Show sample clips again');

  const active = videos.filter((v) => v.isPublished).length;
  const list = h('div', { class: 'card stack' },
    h('div', { class: 'row' },
      h('h3', {}, `YouTube videos in Studio (${active} active / ${videos.length})`),
      h('span', { class: 'spacer' }), refresh),
    h('div', { class: 'row muted' },
      `Old Google sample clips: ${samples.active} active, ${samples.inactive} inactive`, sampleBtn),
    videos.length === 0 ? h('p', { class: 'muted' }, 'No YouTube videos yet — import the sheet above.') :
      h('table', {},
        h('tr', {}, ['', 'Video', 'Channel / trainer', 'Group', 'Level', 'Equip.', 'Duration', 'Status', ''].map((x) => h('th', {}, x))),
        videos.map((v) => h('tr', {},
          h('td', {}, v.thumbnailUrl ? h('img', { src: v.thumbnailUrl, alt: '', loading: 'lazy', style: 'width:96px;border-radius:8px' }) : null),
          h('td', {}, h('a', { href: `https://www.youtube.com/watch?v=${v.youtubeId}`, target: '_blank', rel: 'noopener', style: 'color: var(--text)' }, v.title),
            h('div', { class: 'muted' }, [v.sheetName, v.playlistTitle].filter(Boolean).join(' · '))),
          h('td', {}, v.trainerName ?? v.channelName ?? '—'),
          h('td', {}, v.groupLabel ?? v.groupKey ?? '—', h('div', { class: 'muted' }, (v.types ?? []).join(', '))),
          h('td', {}, v.level), h('td', {}, v.equipment ?? '—'),
          h('td', {}, v.durationSeconds ? fmtDur(v.durationSeconds) : h('span', { class: 'muted', title: 'Not in duration filters' }, 'unknown')),
          h('td', {}, h('span', { class: `pill ${v.isPublished ? 'live' : 'rejected'}` }, v.isPublished ? 'Active' : 'Hidden')),
          h('td', {}, h('button', { class: 'ghost', onclick: async () => {
            try {
              await api(`/videos/admin/${v.id}/active`, { method: 'PATCH', body: { active: !v.isPublished } });
              A.rerender();
            } catch (err) { toast(err.message, true); }
          } }, v.isPublished ? 'Hide' : 'Show')),
        ))),
    h('p', { class: 'muted' }, 'Edit tags or delete a video in the Videos tab.'),
  );

  return h('div', { class: 'stack' }, h('h2', {}, 'Studio — YouTube import'), form, out, list);
}

A.register('studio-import', 'Studio import', view);

/**
 * Studio YouTube importer (BRD §7) — shared by the admin "Studio import" tab (POST /videos/admin/youtube/import)
 * and the CLI:
 *
 *   npm run import-youtube -- <sheet.xlsx|sheet.csv> [--dry-run] [--retag] [--keep-samples] [--json report.json]
 *
 * The sheet has the owner's columns "Studio Name | Playlist Link | Video Link" (any order, header optional; optional
 * extra columns Group, Types, Level, Equipment, Trainer override the automatic mapping). Every row is mapped to a
 * Studio group + video types (060_studio taxonomy), playlists are expanded into their videos, and every video is
 * upserted on its YouTube id — so the sheet can be re-uploaded later without creating duplicates.
 *
 * Metadata: with YOUTUBE_API_KEY set the YouTube Data API v3 gives title, channel, thumbnail, duration, embeddable and
 * privacy status and full playlists. Without a key: oEmbed (title, channel, thumbnail; 401/404 = private, deleted or
 * embedding disabled) + YouTube's public watch / playlist pages for duration and playlist items. When those pages
 * can't be read the duration stays NULL ("unknown" — such videos are left out of duration filters, never shown as 0)
 * and the report says so.
 */
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import ExcelJS from 'exceljs';
import { config } from '../config.js';
import { pool, query, queryOne } from './index.js';

// ---------------------------------------------------------------------------------------------------------------
// Links
// ---------------------------------------------------------------------------------------------------------------

const ID_RE = /^[A-Za-z0-9_-]{11}$/;

/** Canonical 11-char video id from any YouTube link (youtu.be, watch?v=, embed, shorts, live, nocookie), or null. */
export function parseVideoId(link) {
  const s = String(link ?? '').trim();
  if (ID_RE.test(s)) return s;
  let u;
  try {
    u = new URL(/^https?:\/\//i.test(s) ? s : `https://${s}`);
  } catch {
    return null;
  }
  const host = u.hostname.replace(/^(www|m|music)\./, '');
  if (host === 'youtu.be') {
    const id = u.pathname.split('/')[1];
    return ID_RE.test(id ?? '') ? id : null;
  }
  if (!/(^|\.)youtube(-nocookie)?\.com$/.test(host)) return null;
  const v = u.searchParams.get('v');
  if (v && ID_RE.test(v)) return v;
  const m = u.pathname.match(/^\/(?:embed|shorts|live|v)\/([A-Za-z0-9_-]{11})/);
  return m ? m[1] : null;
}

/** Playlist id from a YouTube link (list=…), or null. Mixes/radio lists (RD…) and "watch later" aren't importable. */
export function parsePlaylistId(link) {
  const s = String(link ?? '').trim();
  let u;
  try {
    u = new URL(/^https?:\/\//i.test(s) ? s : `https://${s}`);
  } catch {
    return null;
  }
  const host = u.hostname.replace(/^(www|m|music)\./, '');
  if (!/(^|\.)youtube(-nocookie)?\.com$/.test(host) && host !== 'youtu.be') return null;
  const list = u.searchParams.get('list');
  return list && /^[A-Za-z0-9_-]{10,64}$/.test(list) && !/^(RD|WL|LL)/.test(list) ? list : null;
}

const isYoutubeLink = (s) => /(?:youtu\.be|youtube(?:-nocookie)?\.com)\//i.test(s);
const URL_RE = /(?:https?:\/\/)?(?:[\w-]+\.)*(?:youtu\.be|youtube(?:-nocookie)?\.com)\/[^\s,;"'<>|]+/gi;
const ANY_URL_RE = /https?:\/\/[^\s,;"'<>|]+/gi;

export const watchUrl = (id) => `https://www.youtube.com/watch?v=${id}`;
export const playlistUrl = (id) => `https://www.youtube.com/playlist?list=${id}`;
export const thumbUrl = (id) => `https://i.ytimg.com/vi/${id}/hqdefault.jpg`;

// ---------------------------------------------------------------------------------------------------------------
// Sheet parsing (xlsx / csv / pasted rows) → raw rows (arrays of cell strings)
// ---------------------------------------------------------------------------------------------------------------

/** Minimal RFC-4180 CSV parser (quotes, escaped quotes, newlines in quotes); delimiter auto: tab, ; or ,. */
export function parseCsv(text) {
  const src = String(text).replace(/^﻿/, '');
  const firstLine = src.split(/\r?\n/, 1)[0] ?? '';
  const delim = firstLine.includes('\t') ? '\t' : (firstLine.split(';').length > firstLine.split(',').length ? ';' : ',');
  const rows = [];
  let row = [];
  let cell = '';
  let quoted = false;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (quoted) {
      if (c === '"' && src[i + 1] === '"') { cell += '"'; i++; }
      else if (c === '"') quoted = false;
      else cell += c;
    } else if (c === '"' && cell === '') quoted = true;
    else if (c === delim) { row.push(cell); cell = ''; }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && src[i + 1] === '\n') i++;
      row.push(cell); rows.push(row); row = []; cell = '';
    } else cell += c;
  }
  if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
  return rows.map((r) => r.map((x) => x.trim())).filter((r) => r.some(Boolean));
}

/** Cell → text, preferring the hyperlink target of linked cells. */
function cellText(cell) {
  const v = cell?.value;
  if (v == null) return '';
  if (typeof v === 'object') {
    if (v.hyperlink) return String(v.hyperlink);
    if (v.text != null) return typeof v.text === 'string' ? v.text : (v.text.richText ?? []).map((t) => t.text).join('');
    if (v.richText) return v.richText.map((t) => t.text).join('');
    if (v.result != null) return String(v.result);
  }
  return String(cell.hyperlink ?? cell.text ?? v);
}

/** Rows of the first non-empty worksheet of an .xlsx file. */
export async function parseXlsx(buffer) {
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(buffer);
  for (const ws of wb.worksheets) {
    const rows = [];
    ws.eachRow({ includeEmpty: false }, (row) => {
      const cells = [];
      for (let c = 1; c <= row.cellCount; c++) cells.push(cellText(row.getCell(c)).trim());
      if (cells.some(Boolean)) rows.push(cells);
    });
    if (rows.length) return rows;
  }
  return [];
}

/** Raw rows from an uploaded file (by extension / magic bytes). */
export async function rowsFromFile(buffer, fileName = '') {
  const isZip = buffer[0] === 0x50 && buffer[1] === 0x4b; // xlsx is a zip
  if (/\.xlsx$/i.test(fileName) || isZip) return parseXlsx(buffer);
  if (/\.xls$/i.test(fileName)) throw new Error('Old .xls files are not supported — save the sheet as .xlsx or .csv');
  return parseCsv(buffer.toString('utf8'));
}

/** Raw rows from pasted text: tab-separated (copied from Excel/Sheets), CSV, or free text lines with links. */
export function rowsFromText(text) {
  return String(text ?? '')
    .split(/\r?\n/)
    .filter((l) => l.trim())
    .map((line) => (line.includes('\t') ? line.split('\t').map((c) => c.trim()) : parseCsv(line)[0] ?? [line.trim()]));
}

// ---------------------------------------------------------------------------------------------------------------
// Studio mapping (sheet "Studio Name" → 060_studio group / types; level + equipment from the title)
// ---------------------------------------------------------------------------------------------------------------

/** Ordered: specific disciplines first, so "Boxing Workout (At home)" is Martial Arts, not Home. */
const GROUP_RULES = [
  [/yoga|pranayam|meditat/i, 'yoga_mind', 'none'],
  [/hiit|cardio|aerobic/i, 'dance_cardio', 'none'],
  [/zumba|dance|bollywood/i, 'dance_cardio', 'none'],
  [/karate|judo|\bmma\b|mixed martial|box|kickbox|self[- ]?defen|martial|taekwondo|kung ?fu/i, 'martial_arts', 'none'],
  [/\bgym\b/i, 'gym', 'gym'],
  [/dumbbell/i, 'home', 'dumbbells'],
  [/home|no[- ]equipment|bodyweight|without equipment/i, 'home', 'none'],
  [/stretch|mobility|recovery|cool ?down|posture|foam roll/i, 'recovery', 'none'],
  [/chest|back|shoulder|bicep|tricep|\barms?\b|\blegs?\b|full body|abs\b|core|push|pull/i, 'gym', 'gym'],
  [/weight loss|fat|belly|muscle|stamina|flexib|toning/i, 'goal', null],
  [/women|prenatal|postnatal|senior|kids|chair/i, 'special', 'none'],
  [/nutrition|recipe|diet|form guide/i, 'learn', 'none'],
];

/** Types from the sheet's Studio Name (all matching rules apply). */
const NAME_TYPE_RULES = [
  [/dumbbell/i, ['home_dumbbell']],
  [/no[- ]equipment|without equipment|bodyweight|at home/i, ['home_no_equipment']],
  [/resistance band|\bband\b/i, ['home_band']],
  [/office|desk/i, ['home_office']],
  [/full body/i, ['body_full']],
  [/shoulder/i, ['gym_shoulders', 'body_upper']],
  [/\babs\b|core|six pack/i, ['body_abs']],
  [/bicep|tricep|\barms?\b/i, ['gym_arms', 'body_upper']],
  [/chest/i, ['gym_chest', 'body_upper']],
  [/\bback\b/i, ['gym_back', 'body_upper']],
  [/\blegs?\b|squat/i, ['gym_legs', 'body_lower']],
  [/glute/i, ['body_glutes']],
  [/push|pull|\bppl\b/i, ['gym_ppl']],
  [/machine/i, ['gym_machines']],
  [/power yoga/i, ['yoga_power']],
  [/yoga/i, ['yoga_general']],
  [/pranayam|breath/i, ['yoga_pranayama']],
  [/meditat/i, ['yoga_meditation']],
  [/hiit/i, ['dance_hiit', 'goal_stamina']],
  [/zumba/i, ['dance_zumba']],
  [/bollywood/i, ['dance_bollywood']],
  [/aerobic/i, ['dance_aerobics']],
  [/kickbox/i, ['dance_kickboxing']],
  [/karate|judo/i, ['ma_judo_karate']],
  [/\bmma\b|mixed martial/i, ['ma_mma']],
  [/box(?!ing ?day)/i, ['ma_boxing']],
  [/self[- ]?defen/i, ['ma_self_defence']],
  [/stretch/i, ['rec_stretching']],
  [/mobility/i, ['rec_mobility']],
  [/weight loss|fat burn/i, ['goal_weight_loss']],
  [/belly/i, ['goal_belly_fat']],
];

/** Extra types a video's own YouTube title can add (only unambiguous keywords). */
const TITLE_TYPE_RULES = [
  [/weight loss|fat burn|fat loss|lose weight/i, ['goal_weight_loss']],
  [/belly/i, ['goal_belly_fat']],
  [/full body/i, ['body_full']],
  [/\babs\b|six pack|core workout/i, ['body_abs']],
  [/stretch/i, ['rec_stretching']],
  [/self[- ]?defen/i, ['ma_self_defence']],
  [/power yoga/i, ['yoga_power']],
  [/back pain/i, ['yoga_back_pain']],
  [/pranayam/i, ['yoga_pranayama']],
  [/meditat/i, ['yoga_meditation']],
  [/kickbox/i, ['dance_kickboxing']],
  [/glute/i, ['body_glutes']],
  [/\b(?:women|female|girls)\b/i, ['aud_women']],
];

const LEVELS = ['beginner', 'intermediate', 'advanced'];
const EQUIPMENT = ['none', 'dumbbells', 'gym'];

export function levelFromTitle(title) {
  const t = String(title ?? '');
  if (/\b(advanced|extreme|intense|hardcore|insane|killer|expert)\b/i.test(t)) return 'advanced';
  if (/\bintermediate\b/i.test(t)) return 'intermediate';
  if (/\b(beginners?|basics?|easy|starter|newbies?|for starters)\b/i.test(t)) return 'beginner';
  return null;
}

export function equipmentFromTitle(title) {
  const t = String(title ?? '');
  if (/dumbbell/i.test(t)) return 'dumbbells';
  if (/barbell|machine|cable|kettlebell|smith|leg press/i.test(t)) return 'gym';
  if (/no[- ]equipment|without equipment|bodyweight|body weight|no gym/i.test(t)) return 'none';
  return null;
}

const GROUP_TO_CATEGORY = { home: 'gym', gym: 'gym', goal: 'gym', yoga_mind: 'yoga', dance_cardio: 'dance', body_part: 'gym',
  recovery: 'yoga', special: 'gym', learn: 'gym' };
const categoryFor = (group, types) =>
  group === 'martial_arts' ? (types.includes('ma_boxing') ? 'boxing' : 'martial_arts') : GROUP_TO_CATEGORY[group] ?? 'gym';

/** Loads the Studio taxonomy (groups + types) from the DB. */
async function loadTaxonomy() {
  const [groups, types] = await Promise.all([
    query(`SELECT key, label FROM video_groups`),
    query(`SELECT key, group_key, label FROM video_types`),
  ]);
  return { groups, types, typeKeys: new Set(types.map((t) => t.key)), groupKeys: new Set(groups.map((g) => g.key)) };
}

const norm = (s) => String(s ?? '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

/**
 * Maps a sheet row's Studio Name (plus optional override columns) to {group, types, equipment, level}, or {error}.
 */
export function mapStudioName(name, overrides, tax) {
  const types = new Set();
  let group = null;
  let equipment = null;

  // Overrides from optional columns: group / types accept keys or labels.
  if (overrides.group) {
    const o = norm(overrides.group);
    group = tax.groups.find((g) => g.key === overrides.group.trim() || norm(g.label) === o)?.key ?? null;
    if (!group) return { error: `Unknown Studio group "${overrides.group}"` };
  }
  if (overrides.types) {
    for (const raw of overrides.types.split(/[,;|]/).map((s) => s.trim()).filter(Boolean)) {
      const t = tax.types.find((x) => x.key === raw || norm(x.label) === norm(raw));
      if (!t) return { error: `Unknown video type "${raw}"` };
      types.add(t.key);
    }
  }

  if (!group) {
    for (const [re, g, eq] of GROUP_RULES) {
      if (re.test(name)) { group = g; equipment = eq; break; }
    }
  }
  if (!overrides.types) for (const [re, ts] of NAME_TYPE_RULES) if (re.test(name)) ts.forEach((t) => types.add(t));
  // "Home workout with dumbbells" is not also a no-equipment workout.
  if (types.has('home_dumbbell')) types.delete('home_no_equipment');

  // Fallback: the name is a type or group label itself (e.g. "Pranayama", "Recovery").
  if (!group) {
    const n = norm(name);
    const t = tax.types.find((x) => norm(x.label) === n || n.includes(norm(x.label)));
    if (t) { group = t.groupKey; types.add(t.key); }
    else group = tax.groups.find((g) => norm(g.label) === n)?.key ?? null;
  }
  if (!group && types.size) group = tax.types.find((t) => types.has(t.key))?.groupKey ?? null;
  if (!group) return { error: `Couldn't map "${name}" to a Studio group — add a Group column (e.g. gym, yoga_mind) or rename it` };

  const level = overrides.level && LEVELS.includes(overrides.level.toLowerCase()) ? overrides.level.toLowerCase() : null;
  const eqOverride = overrides.equipment ? norm(overrides.equipment).replace(/^no equipment$/, 'none') : null;
  return {
    group,
    types: [...types].filter((t) => tax.typeKeys.has(t)),
    equipment: EQUIPMENT.includes(eqOverride) ? eqOverride : equipment,
    equipmentFixed: EQUIPMENT.includes(eqOverride),
    level,
    // Gym splits and HIIT default to intermediate; everything else to beginner — a keyword in the title wins.
    defaultLevel: group === 'gym' || types.has('dance_hiit') ? 'intermediate' : 'beginner',
  };
}

// ---------------------------------------------------------------------------------------------------------------
// Rows → normalized import rows
// ---------------------------------------------------------------------------------------------------------------

/** Detects the header row and column roles; returns [{line, name, videos[], playlists[], overrides, error?}]. */
export function normalizeRows(rawRows) {
  const rows = rawRows.filter((r) => r.some((c) => String(c ?? '').trim()));
  let cols = null;
  let start = 0;
  const first = rows[0] ?? [];
  if (first.length && !first.some((c) => isYoutubeLink(String(c))) &&
      first.some((c) => /link|url|studio|name|playlist|video|category/i.test(String(c)))) {
    const find = (re, not) => first.findIndex((c) => re.test(String(c)) && !(not && not.test(String(c))));
    cols = {
      name: find(/studio|name|category|title/i, /link|url/i),
      playlist: find(/playlist/i),
      video: find(/video|link|url/i, /playlist|name/i),
      group: find(/^\s*group\s*$/i),
      types: find(/^\s*(video )?types?\s*$/i),
      level: find(/level/i),
      equipment: find(/equip/i),
      trainer: find(/trainer|coach/i),
    };
    start = 1;
  }

  const out = [];
  for (let i = start; i < rows.length; i++) {
    const cells = rows[i].map((c) => String(c ?? '').trim());
    const line = i + 1;
    const at = (k) => (cols && cols[k] >= 0 ? cells[cols[k]] ?? '' : '');
    const linkCells = new Set([cols?.playlist, cols?.video].filter((x) => x != null && x >= 0));

    // Name: the Studio Name column, else the first cell's text before any link.
    let name = at('name');
    if (!name) {
      const firstText = cells.find((c, idx) => c && !linkCells.has(idx) && !isYoutubeLink(c)) ??
        (cells[0] ?? '').split(/https?:\/\//i)[0];
      name = firstText ?? '';
    }
    name = name.replace(URL_RE, '').replace(/\s*(?:[—–|:,-]\s*)?(?:playlist)?\s*[—–|:,-]*\s*$/i, '').trim();

    const videos = [];
    const playlists = [];
    const bad = [];
    cells.forEach((c, idx) => {
      if ([cols?.name, cols?.group, cols?.types, cols?.level, cols?.equipment, cols?.trainer].includes(idx) &&
          !isYoutubeLink(c)) return;
      const links = c.match(URL_RE) ?? [];
      for (const raw of links) {
        const vid = parseVideoId(raw);
        const list = parsePlaylistId(raw);
        const inPlaylistCol = cols?.playlist === idx;
        if (list && (inPlaylistCol || !vid)) playlists.push({ id: list, link: raw });
        else if (vid) videos.push({ id: vid, link: raw });
        else bad.push(raw);
      }
      for (const raw of c.match(ANY_URL_RE) ?? []) if (!isYoutubeLink(raw)) bad.push(raw);
    });

    const row = {
      line,
      name,
      videos,
      playlists,
      overrides: { group: at('group'), types: at('types'), level: at('level'), equipment: at('equipment'), trainer: at('trainer') },
    };
    if (!videos.length && !playlists.length) {
      row.error = bad.length ? `Not a YouTube video/playlist link: ${bad[0]}` : 'No YouTube link in this row';
    } else if (bad.length) row.warning = `Ignored non-YouTube link ${bad[0]}`;
    if (!name) row.error = row.error ?? 'Studio Name is empty';
    out.push(row);
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------------------
// YouTube metadata
// ---------------------------------------------------------------------------------------------------------------

const BROWSER_HEADERS = {
  'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36',
  'accept-language': 'en-US,en;q=0.9',
  cookie: 'CONSENT=YES+1; SOCS=CAI', // skip the EU cookie-consent interstitial
};

async function fetchRetry(url, init = {}, tries = 2) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try {
      return await fetch(url, { ...init, signal: AbortSignal.timeout(20_000) });
    } catch (err) {
      lastErr = err;
    }
  }
  throw lastErr;
}

/** Runs `fn` over `items` with at most `limit` in flight. */
async function mapLimit(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i], i);
    }
  }));
  return out;
}

const isoDuration = (s) => {
  const m = String(s ?? '').match(/^P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$/);
  if (!m) return null;
  const secs = (+m[1] || 0) * 86400 + (+m[2] || 0) * 3600 + (+m[3] || 0) * 60 + Math.round(+m[4] || 0);
  return secs > 0 ? secs : null;
};
const clockToSeconds = (s) => {
  const m = String(s ?? '').trim().match(/^(?:(\d+):)?(\d{1,2}):(\d{2})$/);
  return m ? (+m[1] || 0) * 3600 + +m[2] * 60 + +m[3] : null;
};

/** oEmbed — works for public, embeddable videos; 401 = private or embedding disabled, 404/400 = not found. */
async function oembed(id) {
  let res;
  try {
    res = await fetchRetry(`https://www.youtube.com/oembed?format=json&url=${encodeURIComponent(watchUrl(id))}`);
  } catch {
    return { ok: false, reason: 'Could not reach YouTube (network error) — try again', retryable: true };
  }
  if (res.status === 401 || res.status === 403) return { ok: false, reason: 'Private video or embedding disabled by the owner' };
  if (res.status === 404 || res.status === 400) return { ok: false, reason: 'Video not found (deleted, private or wrong link)' };
  if (!res.ok) return { ok: false, reason: `YouTube returned HTTP ${res.status}`, retryable: true };
  const j = await res.json().catch(() => null);
  if (!j?.title) return { ok: false, reason: 'YouTube returned no details for this video', retryable: true };
  return { ok: true, title: j.title, channelName: j.author_name ?? null, channelUrl: j.author_url ?? null,
    thumbnailUrl: j.thumbnail_url ?? thumbUrl(id) };
}

/** Public watch page → duration + playability (age-restricted / not embeddable). Never throws. */
async function watchPage(id) {
  try {
    const res = await fetchRetry(watchUrl(id), { headers: BROWSER_HEADERS });
    if (!res.ok) return { seconds: null, error: `watch page HTTP ${res.status}` };
    const html = await res.text();
    const vd = html.match(new RegExp(`"videoDetails":\\{"videoId":"${id}"[\\s\\S]{0,3000}?"lengthSeconds":"(\\d+)"`));
    const meta = html.match(/<meta itemprop="duration" content="([^"]+)"/);
    const seconds = vd ? Number(vd[1]) || null : isoDuration(meta?.[1]);
    const status = html.match(/"playabilityStatus":\{"status":"(\w+)"/)?.[1] ?? null;
    const embeddable = html.match(/"playableInEmbed":(true|false)/)?.[1];
    return { seconds, status, embeddable: embeddable == null ? null : embeddable === 'true', error: seconds ? null : 'no duration on the page' };
  } catch (err) {
    return { seconds: null, error: err.message };
  }
}

/** Walks any JSON value, calling fn on every object. */
const walk = (o, fn) => {
  if (o && typeof o === 'object') {
    fn(o);
    for (const v of Object.values(o)) walk(v, fn);
  }
};

/**
 * Public playlist page (+ its "load more" continuations through YouTube's own web endpoint) → items in order with
 * durations where the page shows them. Falls back to the RSS feed (first 15 only) when the page can't be parsed.
 */
async function playlistFromPage(listId) {
  const items = new Map(); // videoId → {index, seconds, title}
  let title = null;
  let expected = null;
  try {
    const res = await fetchRetry(playlistUrl(listId), { headers: BROWSER_HEADERS });
    if (!res.ok) throw new Error(`playlist page HTTP ${res.status}`);
    const html = await res.text();
    const dataMatch = html.match(/var ytInitialData = (\{[\s\S]*?\});<\/script>/);
    if (!dataMatch) {
      if (/"status":"ERROR"|This playlist does not exist|playlist is private/i.test(html)) {
        return { ok: false, reason: 'Playlist not found or private' };
      }
      throw new Error('playlist page layout not recognised');
    }
    const data = JSON.parse(dataMatch[1]);
    const alerts = [];
    walk(data.alerts ?? [], (o) => { if (o.text?.simpleText) alerts.push(o.text.simpleText); if (o.text?.runs) alerts.push(o.text.runs.map((r) => r.text).join('')); });
    title = data.metadata?.playlistMetadataRenderer?.title ?? null;
    walk(data.sidebar ?? data.header ?? {}, (o) => {
      if (expected == null) {
        const txt = o.runs ? o.runs.map((r) => r.text).join('') : typeof o.content === 'string' ? o.content : o.simpleText;
        const m = typeof txt === 'string' && txt.match(/^([\d,]+)\s+videos?$/i);
        if (m) expected = Number(m[1].replace(/,/g, ''));
      }
    });

    const collect = (root) => {
      const tokens = [];
      walk(root, (o) => {
        // Old layout: playlistVideoRenderer {videoId, lengthSeconds, title}; new layout: lockupViewModel {contentId,
        // badge "34:21"}. Both carry a watchEndpoint with this playlistId + index, which is what we key on.
        if (o.playlistVideoRenderer?.videoId) {
          const r = o.playlistVideoRenderer;
          const it = items.get(r.videoId) ?? {};
          items.set(r.videoId, { ...it, index: it.index ?? Number(r.index?.simpleText ?? items.size) - 1,
            seconds: Number(r.lengthSeconds) || it.seconds || null, title: r.title?.runs?.[0]?.text ?? it.title,
            playable: r.isPlayable !== false });
        }
        if (o.lockupViewModel?.contentId && o.lockupViewModel.contentType === 'LOCKUP_CONTENT_TYPE_VIDEO') {
          const l = o.lockupViewModel;
          let secs = null;
          walk(l.contentImage ?? {}, (x) => { if (x.thumbnailBadgeViewModel?.text) secs = secs ?? clockToSeconds(x.thumbnailBadgeViewModel.text); });
          const it = items.get(l.contentId) ?? {};
          items.set(l.contentId, { ...it, seconds: it.seconds ?? secs,
            title: it.title ?? l.metadata?.lockupMetadataViewModel?.title?.content });
        }
        const we = o.watchEndpoint;
        if (we?.videoId && we.playlistId === listId) {
          const it = items.get(we.videoId) ?? {};
          items.set(we.videoId, { ...it, index: we.index ?? it.index ?? items.size });
        }
        if (o.continuationCommand?.token) tokens.push(o.continuationCommand.token);
      });
      return tokens;
    };

    let tokens = collect(data.contents ?? {});
    const key = html.match(/"INNERTUBE_API_KEY":"([^"]+)"/)?.[1];
    const version = html.match(/"INNERTUBE_CLIENT_VERSION":"([^"]+)"/)?.[1] ?? '2.20240101.00.00';
    const seen = new Set();
    for (let page = 0; tokens.length && page < 40; page++) {
      const before = items.size;
      let progressed = false;
      const next = [];
      for (const token of tokens) {
        if (seen.has(token)) continue;
        seen.add(token);
        const r = await fetchRetry(`https://www.youtube.com/youtubei/v1/browse?prettyPrint=false${key ? `&key=${key}` : ''}`, {
          method: 'POST',
          headers: { ...BROWSER_HEADERS, 'content-type': 'application/json' },
          body: JSON.stringify({ context: { client: { clientName: 'WEB', clientVersion: version, hl: 'en' } }, continuation: token }),
        }).catch(() => null);
        if (!r?.ok) continue;
        const j = await r.json().catch(() => null);
        if (!j) continue;
        const size = items.size;
        const more = collect(j.onResponseReceivedActions ?? j);
        if (items.size > size) { progressed = true; next.push(...more); break; }
      }
      if (!progressed || items.size === before) break;
      tokens = next;
    }
    // Lockups that never got a watchEndpoint index keep page order.
    const list = [...items.entries()]
      .map(([id, it], i) => ({ id, index: it.index ?? i, seconds: it.seconds ?? null, title: it.title ?? null, playable: it.playable !== false }))
      .sort((a, b) => a.index - b.index);
    if (!list.length) throw new Error(alerts[0] ?? 'no videos found on the playlist page');
    return { ok: true, title, expected, items: list, via: 'page',
      complete: expected == null || list.length >= expected,
      note: expected != null && list.length < expected
        ? `YouTube says ${expected} videos but only ${list.length} are listed publicly (the rest are private, deleted or hidden)` : null };
  } catch (err) {
    // RSS fallback: public, stable, but only the 15 most recent items and no durations.
    try {
      const r = await fetchRetry(`https://www.youtube.com/feeds/videos.xml?playlist_id=${listId}`);
      if (r.status === 404) return { ok: false, reason: 'Playlist not found or private' };
      const xml = await r.text();
      const ids = [...xml.matchAll(/<yt:videoId>([A-Za-z0-9_-]{11})<\/yt:videoId>/g)].map((m) => m[1]);
      if (!ids.length) return { ok: false, reason: `Could not read the playlist (${err.message})` };
      return { ok: true, title: xml.match(/<title>([^<]+)<\/title>/)?.[1] ?? title, expected: null, via: 'rss', complete: false,
        items: ids.map((id, index) => ({ id, index, seconds: null, title: null, playable: true })),
        note: `Playlist page unreadable (${err.message}); used YouTube's RSS feed, which only lists the latest ${ids.length} videos — set YOUTUBE_API_KEY to import the full playlist` };
    } catch {
      return { ok: false, reason: `Could not read the playlist (${err.message})` };
    }
  }
}

// ---- YouTube Data API v3 (when YOUTUBE_API_KEY is set) -------------------------------------------------------

async function ytApi(pathname, params) {
  const u = new URL(`https://www.googleapis.com/youtube/v3/${pathname}`);
  for (const [k, v] of Object.entries({ ...params, key: config.youtubeApiKey })) if (v != null) u.searchParams.set(k, v);
  const res = await fetchRetry(u);
  const j = await res.json().catch(() => null);
  if (!res.ok) {
    const e = new Error(j?.error?.message ?? `YouTube Data API HTTP ${res.status}`);
    e.status = res.status;
    e.notFound = res.status === 404;
    throw e;
  }
  return j;
}

async function apiPlaylist(listId) {
  try {
    const meta = await ytApi('playlists', { part: 'snippet,contentDetails', id: listId });
    const pl = meta.items?.[0];
    if (!pl) return { ok: false, reason: 'Playlist not found or private' };
    const items = [];
    let pageToken;
    do {
      const j = await ytApi('playlistItems', { part: 'contentDetails,status', playlistId: listId, maxResults: 50, pageToken });
      for (const it of j.items ?? []) items.push({ id: it.contentDetails.videoId, index: items.length, seconds: null, title: null,
        playable: it.status?.privacyStatus !== 'private' });
      pageToken = j.nextPageToken;
    } while (pageToken && items.length < 2000);
    const expected = pl.contentDetails?.itemCount ?? null;
    return { ok: true, title: pl.snippet?.title ?? null, expected, items, via: 'api', complete: true };
  } catch (err) {
    if (err.notFound) return { ok: false, reason: 'Playlist not found or private' };
    throw err;
  }
}

/** videos.list for up to 50 ids per call → Map id → details | {skip reason}. */
async function apiVideos(ids) {
  const out = new Map();
  for (let i = 0; i < ids.length; i += 50) {
    const batch = ids.slice(i, i + 50);
    const j = await ytApi('videos', { part: 'snippet,contentDetails,status', id: batch.join(','), maxResults: 50 });
    for (const v of j.items ?? []) {
      const t = v.snippet?.thumbnails ?? {};
      out.set(v.id, {
        title: v.snippet?.title,
        channelName: v.snippet?.channelTitle ?? null,
        channelUrl: v.snippet?.channelId ? `https://www.youtube.com/channel/${v.snippet.channelId}` : null,
        thumbnailUrl: (t.maxres ?? t.standard ?? t.high ?? t.medium ?? t.default)?.url ?? thumbUrl(v.id),
        seconds: isoDuration(v.contentDetails?.duration),
        skip: v.status?.privacyStatus === 'private' ? 'Private video'
          : v.status?.embeddable === false ? 'Embedding disabled by the owner'
            : v.status?.uploadStatus && !['processed', 'uploaded'].includes(v.status.uploadStatus) ? `Video is ${v.status.uploadStatus}`
              : v.contentDetails?.contentRating?.ytRating === 'ytAgeRestricted' ? 'Age-restricted — YouTube blocks it in embedded players'
                : null,
      });
    }
    for (const id of batch) if (!out.has(id)) out.set(id, { skip: 'Video not found (deleted, private or wrong link)' });
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------------------------------------------

const SAMPLE_URL_LIKE = '%commondatastorage.googleapis.com/gtv-videos-bucket%';
const YT_ID_SQL = `substring(video_url FROM '(?:youtu\\.be/|[?&]v=|/embed/|/shorts/|/live/)([A-Za-z0-9_-]{11})')`;

/**
 * Imports normalized-able raw rows. Options: dryRun (no writes), retag (overwrite title/group/types/level/equipment of
 * videos that already exist), deactivateSamples (default true: hide the old Google sample clips once YouTube videos
 * are live), log (progress callback).
 */
export async function importYoutube(rawRows, { dryRun = false, retag = false, deactivateSamples = true, log = () => {} } = {}) {
  const started = Date.now();
  const tax = await loadTaxonomy();
  const rows = normalizeRows(rawRows);
  let useApi = Boolean(config.youtubeApiKey);
  const warnings = [];
  const report = {
    dryRun, retag,
    metadataSource: useApi ? 'YouTube Data API v3' : 'oEmbed + public YouTube pages (no YOUTUBE_API_KEY)',
    rows: [],
    items: [],
    skipped: [],
    warnings,
    totals: { rows: rows.length, videos: 0, added: 0, updated: 0, unchanged: 0, skipped: 0, durationUnknown: 0, duplicatesInSheet: 0 },
    samplesDeactivated: 0,
  };

  // 1) Map rows and expand playlists → candidate list (first occurrence of a video id wins).
  const candidates = new Map(); // youtubeId → candidate
  for (const row of rows) {
    const rr = { line: row.line, name: row.name, links: row.videos.length + row.playlists.length, found: 0,
      added: 0, updated: 0, unchanged: 0, skipped: 0, playlists: [] };
    report.rows.push(rr);
    if (row.warning) warnings.push(`Row ${row.line}: ${row.warning}`);
    if (row.error) {
      rr.error = row.error;
      report.skipped.push({ line: row.line, name: row.name, link: null, youtubeId: null, reason: row.error });
      continue;
    }
    const map = mapStudioName(row.name, row.overrides, tax);
    if (map.error) {
      rr.error = map.error;
      for (const l of [...row.videos, ...row.playlists]) report.skipped.push({ line: row.line, name: row.name, link: l.link, youtubeId: l.id, reason: map.error });
      continue;
    }
    Object.assign(rr, { group: map.group, types: map.types });

    const add = (id, link, extra = {}) => {
      rr.found++;
      if (candidates.has(id)) {
        report.totals.duplicatesInSheet++;
        const first = candidates.get(id);
        if (first.line !== row.line) warnings.push(`Row ${row.line}: ${id} is already in row ${first.line} — imported once, under row ${first.line}`);
        return;
      }
      candidates.set(id, { id, link, line: row.line, name: row.name, map, trainer: row.overrides.trainer || null, rr, ...extra });
    };
    for (const v of row.videos) add(v.id, v.link);
    for (const p of row.playlists) {
      log(`Row ${row.line}: reading playlist ${p.id}…`);
      let pl;
      if (useApi) {
        try {
          pl = await apiPlaylist(p.id);
        } catch (err) {
          warnings.push(`YouTube Data API failed (${err.message}) — falling back to public pages`);
          useApi = false;
          report.metadataSource = 'oEmbed + public YouTube pages (Data API failed)';
        }
      }
      pl = pl ?? (await playlistFromPage(p.id));
      if (!pl.ok) {
        rr.playlists.push({ id: p.id, error: pl.reason });
        report.skipped.push({ line: row.line, name: row.name, link: p.link, youtubeId: null, playlistId: p.id, reason: pl.reason });
        continue;
      }
      rr.playlists.push({ id: p.id, title: pl.title, expected: pl.expected, listed: pl.items.length, via: pl.via, complete: pl.complete, note: pl.note ?? null });
      if (pl.note) warnings.push(`Row ${row.line} (${row.name}): ${pl.note}`);
      for (const it of pl.items) {
        add(it.id, watchUrl(it.id), { playlistId: p.id, playlistTitle: pl.title, pageSeconds: it.seconds, pageTitle: it.title, playable: it.playable });
      }
    }
  }

  // 2) Metadata per video.
  const list = [...candidates.values()];
  report.totals.videos = list.length;
  log(`Fetching details for ${list.length} videos (${useApi ? 'YouTube Data API' : 'oEmbed + public pages'})…`);
  let apiInfo = null;
  if (useApi && list.length) {
    try {
      apiInfo = await apiVideos(list.map((c) => c.id));
    } catch (err) {
      warnings.push(`YouTube Data API failed (${err.message}) — falling back to oEmbed + public pages`);
      useApi = false;
      report.metadataSource = 'oEmbed + public YouTube pages (Data API failed)';
    }
  }
  let pageFailures = 0;
  await mapLimit(list, 6, async (c) => {
    if (apiInfo) {
      const a = apiInfo.get(c.id);
      if (a.skip) { c.skip = a.skip; return; }
      Object.assign(c, { title: a.title, channelName: a.channelName, channelUrl: a.channelUrl, thumbnailUrl: a.thumbnailUrl,
        seconds: a.seconds, durationSource: a.seconds ? 'api' : null });
      return;
    }
    let o = await oembed(c.id);
    if (!o.ok && o.retryable) o = await oembed(c.id);
    if (!o.ok) { c.skip = o.reason; return; }
    Object.assign(c, { title: o.title, channelName: o.channelName, channelUrl: o.channelUrl, thumbnailUrl: o.thumbnailUrl });
    if (c.pageSeconds) { c.seconds = c.pageSeconds; c.durationSource = 'page'; return; }
    const w = await watchPage(c.id);
    if (w.status && w.status !== 'OK') {
      c.skip = w.status === 'LOGIN_REQUIRED' ? 'Age-restricted or sign-in required — YouTube blocks it in embedded players'
        : `Not playable on YouTube (${w.status.toLowerCase()})`;
      return;
    }
    if (w.embeddable === false) { c.skip = 'Embedding disabled by the owner'; return; }
    if (w.seconds) { c.seconds = w.seconds; c.durationSource = 'page'; } else { c.seconds = null; pageFailures++; }
  });
  if (pageFailures) {
    warnings.push(`${pageFailures} video(s): duration could not be read from YouTube's public page — stored as unknown ` +
      '(left out of the duration filters, not shown as 0). Set YOUTUBE_API_KEY and re-import to fill them in.');
  }

  // 3) Upsert.
  const ids = list.map((c) => c.id);
  const existing = ids.length
    ? await query(
      `SELECT id, title, category, level, group_key, types, equipment, trainer_name, thumbnail_url, duration_seconds,
              duration_source, channel_name, channel_url, playlist_id, playlist_title, sheet_name, youtube_id, source,
              video_url, is_published, COALESCE(youtube_id, ${YT_ID_SQL}) AS yid
       FROM videos WHERE youtube_id = ANY($1) OR ${YT_ID_SQL} = ANY($1)
       ORDER BY created_at`,
      [ids],
    )
    : [];
  const byYid = new Map();
  for (const e of existing) if (!byYid.has(e.yid)) byYid.set(e.yid, e);

  for (const c of list) {
    const rr = c.rr;
    if (c.skip) {
      rr.skipped++;
      report.totals.skipped++;
      report.skipped.push({ line: c.line, name: c.name, link: c.link, youtubeId: c.id, playlistId: c.playlistId ?? null,
        title: c.pageTitle ?? null, reason: c.skip });
      continue;
    }
    const titleLevel = levelFromTitle(`${c.title} ${c.playlistTitle ?? ''}`);
    const titleEq = c.map.equipmentFixed ? null : equipmentFromTitle(c.title);
    const types = new Set(c.map.types);
    for (const [re, ts] of TITLE_TYPE_RULES) if (re.test(c.title)) ts.forEach((t) => tax.typeKeys.has(t) && types.add(t));
    const tags = {
      title: String(c.title).slice(0, 200),
      groupKey: c.map.group,
      types: [...types],
      level: c.map.level ?? titleLevel ?? c.map.defaultLevel,
      equipment: titleEq ?? c.map.equipment ?? null,
      category: categoryFor(c.map.group, [...types]),
    };
    if (!c.seconds) report.totals.durationUnknown++;
    const item = { line: c.line, name: c.name, youtubeId: c.id, title: tags.title, channel: c.channelName,
      durationSeconds: c.seconds ?? null, group: tags.groupKey, types: tags.types, level: tags.level, equipment: tags.equipment,
      playlist: c.playlistTitle ?? null };
    const ex = byYid.get(c.id);

    if (!ex) {
      item.status = 'added';
      if (!dryRun) {
        const row = await queryOne(
          `INSERT INTO videos (category, title, trainer_name, level, video_url, thumbnail_url, duration_seconds, group_key,
             types, equipment, source, youtube_id, channel_name, channel_url, playlist_id, playlist_title, sheet_name,
             duration_source, imported_at)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'youtube',$11,$12,$13,$14,$15,$16,$17, now())
           ON CONFLICT (youtube_id) WHERE youtube_id IS NOT NULL DO NOTHING
           RETURNING id`,
          [tags.category, tags.title, c.trainer, tags.level, watchUrl(c.id), c.thumbnailUrl, c.seconds ?? null, tags.groupKey,
            tags.types, tags.equipment, c.id, c.channelName?.slice(0, 200) ?? null, c.channelUrl, c.playlistId ?? null,
            c.playlistTitle?.slice(0, 300) ?? null, c.name.slice(0, 160), c.durationSource ?? null],
        );
        if (!row) item.status = 'unchanged'; // inserted concurrently by another import
        item.id = row?.id;
      }
    } else {
      item.id = ex.id;
      item.active = ex.isPublished;
      const next = {
        source: 'youtube',
        youtubeId: c.id,
        channelName: c.channelName?.slice(0, 200) ?? ex.channelName,
        channelUrl: c.channelUrl ?? ex.channelUrl,
        thumbnailUrl: !ex.thumbnailUrl || /ytimg\.com|img\.youtube\.com/.test(ex.thumbnailUrl) ? c.thumbnailUrl : ex.thumbnailUrl,
        durationSeconds: c.seconds && ex.durationSource !== 'admin' ? c.seconds : ex.durationSeconds,
        durationSource: c.seconds && ex.durationSource !== 'admin' ? c.durationSource : ex.durationSource,
        playlistId: c.playlistId ?? ex.playlistId,
        playlistTitle: c.playlistTitle?.slice(0, 300) ?? ex.playlistTitle,
        sheetName: ex.sheetName ?? c.name.slice(0, 160),
        trainerName: c.trainer ?? ex.trainerName,
        ...(retag ? { ...tags, sheetName: c.name.slice(0, 160) } : {}),
      };
      const same = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
      const changed = Object.keys(next).filter((k) => !same(next[k], ex[k]));
      item.status = changed.length ? 'updated' : 'unchanged';
      if (changed.length) item.changed = changed;
      if (changed.length && !dryRun) {
        await query(
          `UPDATE videos SET source = $2, youtube_id = $3, channel_name = $4, channel_url = $5, thumbnail_url = $6,
             duration_seconds = $7, duration_source = $8, playlist_id = $9, playlist_title = $10, sheet_name = $11,
             trainer_name = $12, title = $13, group_key = $14, types = $15, level = $16, equipment = $17, category = $18,
             imported_at = now()
           WHERE id = $1`,
          [ex.id, next.source, next.youtubeId, next.channelName, next.channelUrl, next.thumbnailUrl, next.durationSeconds,
            next.durationSource, next.playlistId, next.playlistTitle, next.sheetName, next.trainerName,
            next.title ?? ex.title, next.groupKey ?? ex.groupKey, next.types ?? ex.types, next.level ?? ex.level,
            next.equipment !== undefined ? next.equipment : ex.equipment, next.category ?? ex.category],
        );
      }
    }
    rr[item.status]++;
    report.totals[item.status]++;
    report.items.push(item);
  }

  // 4) Old Google sample clips → inactive (never deleted) once real YouTube workouts are live.
  if (deactivateSamples && !dryRun) {
    const live = await queryOne(`SELECT COUNT(*) AS n FROM videos WHERE source = 'youtube' AND is_published`);
    if (live.n > 0) {
      const off = await query(
        `UPDATE videos SET is_published = false WHERE is_published AND source <> 'youtube' AND video_url ILIKE $1 RETURNING id`,
        [SAMPLE_URL_LIKE],
      );
      report.samplesDeactivated = off.length;
    }
  }
  report.totals.skipped = report.skipped.length; // rows that couldn't be mapped + unavailable videos / playlists
  report.tookSeconds = Math.round((Date.now() - started) / 100) / 10;
  return report;
}

/** Fills title/channel/thumbnail/duration for YouTube videos that are missing them (e.g. added via the admin form). */
export async function refreshYoutubeDetails({ log = () => {} } = {}) {
  const rows = await query(
    `SELECT id, COALESCE(youtube_id, ${YT_ID_SQL}) AS yid, title, channel_name, thumbnail_url, duration_seconds, duration_source
     FROM videos
     WHERE (source = 'youtube' OR ${YT_ID_SQL} IS NOT NULL)
       AND (channel_name IS NULL OR thumbnail_url IS NULL OR duration_seconds IS NULL OR youtube_id IS NULL)`,
  );
  const result = { checked: rows.length, updated: 0, failed: [] };
  const api = config.youtubeApiKey ? await apiVideos(rows.map((r) => r.yid)).catch(() => null) : null;
  await mapLimit(rows, 6, async (r) => {
    let info;
    if (api?.get(r.yid) && !api.get(r.yid).skip) info = { ...api.get(r.yid), durationSource: 'api' };
    else {
      const o = await oembed(r.yid);
      if (!o.ok) { result.failed.push({ id: r.id, youtubeId: r.yid, title: r.title, reason: o.reason }); return; }
      const w = r.durationSeconds ? { seconds: null } : await watchPage(r.yid);
      info = { ...o, seconds: w.seconds, durationSource: 'page' };
    }
    const taken = await queryOne(`SELECT id FROM videos WHERE youtube_id = $1 AND id <> $2`, [r.yid, r.id]);
    await query(
      `UPDATE videos SET source = 'youtube', youtube_id = COALESCE(youtube_id, $2), channel_name = COALESCE(channel_name, $3),
         channel_url = COALESCE(channel_url, $4), thumbnail_url = COALESCE(thumbnail_url, $5),
         duration_seconds = COALESCE(duration_seconds, $6),
         duration_source = CASE WHEN duration_seconds IS NULL AND $6::int IS NOT NULL THEN $7 ELSE duration_source END
       WHERE id = $1`,
      [r.id, taken ? null : r.yid, info.channelName ?? null, info.channelUrl ?? null, info.thumbnailUrl ?? null,
        info.seconds ?? null, info.durationSource],
    );
    result.updated++;
    log(`✔ ${r.title}`);
  });
  return result;
}

// ---------------------------------------------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------------------------------------------

const fmtDur = (s) => (s ? `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}` : '—');

export function printReport(r, out = console.log) {
  out(`\nStudio YouTube import${r.dryRun ? ' (DRY RUN — nothing written)' : ''} — metadata: ${r.metadataSource}`);
  out('─'.repeat(100));
  for (const row of r.rows) {
    const pls = row.playlists.map((p) => (p.error ? ` playlist ✖ ${p.error}` :
      ` playlist "${p.title}" ${p.listed}${p.expected != null ? `/${p.expected}` : ''} via ${p.via}`)).join(';');
    out(`Row ${String(row.line).padStart(2)}  ${row.name.padEnd(32).slice(0, 32)} → ${row.error ? `✖ ${row.error}` :
      `${row.group} [${row.types.join(', ')}]  found ${row.found}: +${row.added} added, ${row.updated} updated, ${row.unchanged} unchanged, ${row.skipped} skipped${pls}`}`);
  }
  out('─'.repeat(100));
  const t = r.totals;
  out(`Totals: ${t.rows} rows, ${t.videos} unique videos → ${t.added} added, ${t.updated} updated, ${t.unchanged} unchanged, ` +
    `${t.skipped} skipped; duration unknown for ${t.durationUnknown}; ${t.duplicatesInSheet} duplicate link(s) in the sheet`);
  if (!r.dryRun) out(`Old Google sample clips set inactive: ${r.samplesDeactivated}`);
  if (r.skipped.length) {
    out('\nSkipped:');
    for (const s of r.skipped) out(`  row ${s.line} ${s.name}: ${s.youtubeId ?? s.playlistId ?? s.link ?? ''} ${s.title ? `"${s.title}" ` : ''}— ${s.reason}`);
  }
  if (r.warnings.length) {
    out('\nWarnings:');
    for (const w of r.warnings) out(`  • ${w}`);
  }
  out(`\nVideos (${r.items.length}):`);
  for (const i of r.items) {
    out(`  [${i.status.padEnd(9)}] ${i.youtubeId}  ${fmtDur(i.durationSeconds).padStart(7)}  ${i.level.padEnd(12)} ${String(i.equipment ?? '—').padEnd(9)} ` +
      `${i.group}/${i.types.join(',')}  "${i.title}" — ${i.channel ?? '?'}`);
  }
  out(`\nDone in ${r.tookSeconds}s.`);
}

async function main() {
  const args = process.argv.slice(2);
  const file = args.find((a) => !a.startsWith('--') && !args[args.indexOf(a) - 1]?.startsWith('--json'));
  if (!file) {
    console.error('Usage: npm run import-youtube -- <sheet.xlsx|sheet.csv> [--dry-run] [--retag] [--keep-samples] [--json report.json]');
    process.exitCode = 1;
    return;
  }
  const jsonIdx = args.indexOf('--json');
  const buffer = await readFile(path.resolve(file));
  const rows = await rowsFromFile(buffer, file);
  const report = await importYoutube(rows, {
    dryRun: args.includes('--dry-run'),
    retag: args.includes('--retag'),
    deactivateSamples: !args.includes('--keep-samples'),
    log: (m) => console.log(m),
  });
  printReport(report);
  if (jsonIdx >= 0 && args[jsonIdx + 1]) {
    await writeFile(path.resolve(args[jsonIdx + 1]), JSON.stringify(report, null, 2));
    console.log(`Report written to ${args[jsonIdx + 1]}`);
  }
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try {
    await main();
  } catch (err) {
    console.error('✖ Import failed:', err.message);
    process.exitCode = 1;
  } finally {
    await pool.end();
  }
}

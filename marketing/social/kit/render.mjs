#!/usr/bin/env node
/**
 * FITKEY social renderer.
 *   node render.mjs <plan.json> <outDir> [--only id[,id2]] [--concurrency 4] [--chrome <path>] [--launch coming|live]
 *
 * --launch overrides LAUNCH_STATE in kit.js for this run (store badge / button wording).
 * Every 1080x1920 story renders through templates/story.html (one story system for all slide types).
 *
 * Renders every carousel slide / post / story in the plan to an exact-size PNG
 * (device scale 1) with the locally installed Chrome, then writes <outDir>/index.html
 * (contact sheet) and <outDir>/manifest.json.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import puppeteer from 'puppeteer-core';

const KIT = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(KIT, '..', '..', '..'); // repo root (F:\gym app)
const PATHS = {
  templates: path.join(KIT, 'templates'),
  photos: path.join(ROOT, 'marketing', 'social', 'photos'), // 2400px copies of the app photos (Unsplash)
  screens: path.resolve(KIT, '..', 'screens'),
};
const FORMATS = { post: [1080, 1350], square: [1080, 1080], story: [1080, 1920] };
const TYPE_FILES = {
  cover: 'cover', feature: 'feature', split: 'split', screenshot: 'screenshot',
  'stat-free-bullets': 'stat-free-bullets', bullets: 'stat-free-bullets', list: 'stat-free-bullets',
  cta: 'cta', quote: 'quote', oneliner: 'quote', 'quote/oneliner': 'quote', vs: 'vs',
};
const CHROME_CANDIDATES = [
  process.env.CHROME_PATH,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome',
].filter(Boolean);

function parseArgs(argv) {
  const a = { positional: [], only: null, concurrency: 4, chrome: null, launch: process.env.FITKEY_LAUNCH_STATE || null };
  for (let i = 0; i < argv.length; i++) {
    const v = argv[i];
    if (v === '--only') a.only = new Set(argv[++i].split(',').map((s) => s.trim()).filter(Boolean));
    else if (v.startsWith('--only=')) a.only = new Set(v.slice(7).split(','));
    else if (v === '--concurrency') a.concurrency = Math.max(1, +argv[++i] || 4);
    else if (v === '--chrome') a.chrome = argv[++i];
    else if (v === '--launch') a.launch = argv[++i];
    else if (v.startsWith('--launch=')) a.launch = v.slice(9);
    else a.positional.push(v);
  }
  return a;
}

const fileUrl = (p) => pathToFileURL(p).href + (fs.existsSync(p) && fs.statSync(p).isDirectory() ? '/' : '');
const FORMAT_ALIASES = { '1080x1350': 'post', '1080x1080': 'square', '1080x1920': 'story', '4:5': 'post', '1:1': 'square', '9:16': 'story', feed: 'post', portrait: 'post', reel: 'story' };
const normFormat = (f, def) => { const k = String(f || def).toLowerCase(); return FORMAT_ALIASES[k] || k; };
const pad = (n) => String(n).padStart(2, '0');

function buildJobs(plan, outDir, only) {
  const jobs = [];
  const want = (id) => !only || only.has(id);
  for (const car of plan.carousels || []) {
    if (!want(car.id)) continue;
    const format = normFormat(car.format, 'post');
    const slides = car.slides || [];
    slides.forEach((slide, index) => jobs.push({
      group: `carousel:${car.id}`, id: `${car.id}/${pad(index + 1)}`, slide: { ...slide, format },
      ctx: { kind: 'carousel', id: car.id, index, total: slides.length, format },
      out: path.join(outDir, car.id, `${pad(index + 1)}.png`), rel: `${car.id}/${pad(index + 1)}.png`,
    }));
  }
  for (const [list, dir, defFmt] of [[plan.posts, 'posts', 'post'], [plan.stories, 'stories', 'story']]) {
    for (const p of list || []) {
      if (!want(p.id)) continue;
      const format = dir === 'stories' ? 'story' : normFormat(p.format, defFmt);
      jobs.push({
        group: dir, id: `${dir}/${p.id}`, slide: { ...p, format }, ctx: { kind: dir === 'stories' ? 'story' : 'post', id: p.id, index: 0, total: 1, format },
        out: path.join(outDir, dir, `${p.id}.png`), rel: `${dir}/${p.id}.png`,
      });
    }
  }
  return jobs;
}

let LAUNCH = null;
async function renderJob(browser, job) {
  const type = String(job.slide.type || '').toLowerCase();
  const tpl = job.ctx.format === 'story' ? 'story' : TYPE_FILES[type];
  if (!tpl) throw new Error(`unknown slide type "${job.slide.type}" (known: ${Object.keys(TYPE_FILES).join(', ')})`);
  if (!FORMATS[job.ctx.format]) throw new Error(`unknown format "${job.ctx.format}"`);
  const [width, height] = FORMATS[job.ctx.format];
  const page = await browser.newPage();
  try {
    await page.setViewport({ width, height, deviceScaleFactor: 1 });
    await page.bringToFront().catch(() => {});
    const cfg = { photos: fileUrl(PATHS.photos) + '/', screens: fileUrl(PATHS.screens) + '/' };
    cfg.photos = cfg.photos.replace(/\/+$/, '/'); cfg.screens = cfg.screens.replace(/\/+$/, '/');
    if (process.env.FITKEY_HANDLE) cfg.handle = process.env.FITKEY_HANDLE;
    if (LAUNCH) cfg.launchState = LAUNCH;
    await page.evaluateOnNewDocument((data, c) => { window.__SLIDE__ = data; window.__KIT_CFG__ = c; },
      { slide: job.slide, ctx: job.ctx }, cfg);
    const logs = [];
    page.on('pageerror', (e) => logs.push('pageerror: ' + e.message));
    page.on('requestfailed', (r) => { if (!/\/screens\//.test(r.url())) logs.push('requestfailed: ' + decodeURI(r.url())); });
    await page.goto(fileUrl(path.join(PATHS.templates, `${tpl}.html`)), { waitUntil: 'load', timeout: 60000 });
    await page.waitForFunction('window.__KIT_READY__ === true', { timeout: 60000 });
    const rep = await page.evaluate(() => window.__KIT_REPORT__);
    fs.mkdirSync(path.dirname(job.out), { recursive: true });
    await page.screenshot({ path: job.out, type: 'png', clip: { x: 0, y: 0, width, height }, captureBeyondViewport: false });
    return { warnings: [...logs, ...(rep?.warnings || [])], info: rep?.info || [], width, height };
  } finally {
    await page.close();
  }
}

function contactSheet(plan, jobs, results, outDir) {
  const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const groups = new Map();
  for (const j of jobs) { if (!groups.has(j.group)) groups.set(j.group, []); groups.get(j.group).push(j); }
  const card = (j) => {
    const r = results.get(j.id) || {};
    const [w, h] = FORMATS[j.ctx.format];
    const flags = (r.warnings || []).length ? `<span class="warn" title="${esc(r.warnings.join('\n'))}">⚠ ${r.warnings.length}</span>` : '';
    return `<figure><a href="${esc(j.rel)}" target="_blank"><img src="${esc(j.rel)}?v=${Date.now()}" loading="lazy" style="aspect-ratio:${w}/${h}"></a>
      <figcaption><b>${esc(j.id)}</b> <span>${esc(j.slide.type)} · ${j.ctx.format} ${w}×${h}</span>${flags}<em>${esc(String(j.slide.headline || '').replace(/\*/g, '').replace(/\\n|\n/g, ' '))}</em></figcaption></figure>`;
  };
  const sections = [...groups.entries()].map(([g, js]) => {
    const [kind, id] = g.split(':');
    const title = kind === 'carousel' ? `Carousel · ${id}` : kind === 'posts' ? 'Posts' : 'Stories';
    return `<section><h2>${esc(title)} <small>${js.length} frame${js.length > 1 ? 's' : ''}</small></h2><div class="${kind === 'carousel' ? 'strip' : 'grid'}">${js.map(card).join('')}</div></section>`;
  }).join('\n');
  const font = fileUrl(path.join(ROOT, 'user_app', 'assets', 'fonts'));
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FITKEY social · contact sheet</title><style>
@font-face{font-family:PJS;font-weight:500;src:url("${font}/PlusJakartaSans-Medium.ttf")}
@font-face{font-family:PJS;font-weight:800;src:url("${font}/PlusJakartaSans-ExtraBold.ttf")}
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#111218;color:#fff;font:500 14px/1.4 PJS,system-ui,sans-serif;padding:40px 32px 80px}
header{display:flex;align-items:center;gap:14px;margin-bottom:36px}header .appic{width:44px;height:44px;border-radius:22%;box-shadow:0 0 18px rgba(200,243,29,.25)}
h1{font:800 26px PJS;letter-spacing:-.02em;margin:0}header span{color:#9396A5}
section{margin:0 0 48px}h2{font:800 18px PJS;margin:0 0 16px;letter-spacing:-.01em}h2 small{color:#9396A5;font-weight:500;margin-left:8px}
.strip{display:flex;gap:16px;overflow-x:auto;padding-bottom:12px}.strip figure{flex:none;width:300px}
.grid{display:flex;flex-wrap:wrap;gap:16px}.grid figure{width:300px}
figure{margin:0}figure img{width:100%;display:block;border-radius:10px;background:#23252F;box-shadow:0 10px 30px rgba(0,0,0,.4)}
figcaption{margin-top:10px;display:flex;flex-wrap:wrap;gap:4px 8px;font-size:12.5px}figcaption b{font-weight:800}figcaption span{color:#9396A5}
figcaption em{flex-basis:100%;font-style:normal;color:#C9CBD6}.warn{color:#FFA41B;font-weight:800;cursor:help}
</style></head><body><header><img class="appic" src="app_icon.png" alt=""><h1>FITKEY social</h1><span>${jobs.length} frames · store state: ${LAUNCH || "kit default (LAUNCH_STATE in kit.js)"} · rendered ${new Date().toLocaleString('en-IN')}</span></header>
${sections}</body></html>`;
  const icon = path.join(KIT, 'assets', 'app_icon_tile.png');
  if (fs.existsSync(icon)) fs.copyFileSync(icon, path.join(outDir, 'app_icon.png'));
  fs.writeFileSync(path.join(outDir, 'index.html'), html);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const [planPath, outArg] = args.positional;
  if (!planPath || !outArg) {
    console.error('usage: node render.mjs <plan.json> <outDir> [--only id[,id]] [--concurrency N] [--chrome path]');
    process.exit(2);
  }
  const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));
  if (args.launch) {
    if (!['coming', 'live'].includes(args.launch)) { console.error('--launch must be "coming" or "live"'); process.exit(2); }
    LAUNCH = args.launch;
  }
  const outDir = path.resolve(outArg);
  fs.mkdirSync(outDir, { recursive: true });
  const jobs = buildJobs(plan, outDir, args.only);
  if (!jobs.length) { console.error('nothing to render (check --only ids)'); process.exit(1); }

  const executablePath = args.chrome || CHROME_CANDIDATES.find((p) => fs.existsSync(p));
  if (!executablePath) throw new Error('Chrome not found — pass --chrome <path> or set CHROME_PATH');
  const browser = await puppeteer.launch({
    executablePath, headless: true,
    args: ['--allow-file-access-from-files', '--force-color-profile=srgb', '--font-render-hinting=none', '--hide-scrollbars', '--disable-lcd-text'],
  });
  const results = new Map();
  let failed = 0, warned = 0;
  const t0 = Date.now();
  try {
    const queue = [...jobs];
    await Promise.all(Array.from({ length: Math.min(args.concurrency, jobs.length) }, async () => {
      while (queue.length) {
        const job = queue.shift();
        try {
          const r = await renderJob(browser, job);
          results.set(job.id, r);
          if (r.warnings.length) warned++;
          console.log(`${r.warnings.length ? '!' : '✓'} ${job.id.padEnd(28)} ${job.slide.type.padEnd(18)} ${r.width}x${r.height}`);
          for (const w of r.warnings) console.log(`    ⚠ ${w}`);
          for (const i of r.info) console.log(`    · ${i}`);
        } catch (e) {
          failed++;
          results.set(job.id, { warnings: ['FAILED: ' + e.message] });
          console.log(`✗ ${job.id}  ${e.message}`);
        }
      }
    }));
  } finally {
    await browser.close();
  }
  if (!args.only) contactSheet(plan, jobs, results, outDir);
  else {
    // partial run: rebuild the sheet from the whole plan so it stays complete
    const all = buildJobs(plan, outDir, null);
    contactSheet(plan, all.filter((j) => fs.existsSync(j.out)), results, outDir);
  }
  fs.writeFileSync(path.join(outDir, 'manifest.json'), JSON.stringify(
    jobs.map((j) => ({ id: j.id, file: j.rel, type: j.slide.type, format: j.ctx.format, warnings: results.get(j.id)?.warnings || [] })), null, 2));
  console.log(`\n${jobs.length - failed}/${jobs.length} rendered in ${((Date.now() - t0) / 1000).toFixed(1)}s` +
    `${warned ? ` · ${warned} with warnings` : ''}${failed ? ` · ${failed} FAILED` : ''}\ncontact sheet: ${path.join(outDir, 'index.html')}`);
  process.exit(failed ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });

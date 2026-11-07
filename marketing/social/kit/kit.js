/* =====================================================================
   FITKEY social kit — shared runtime for every template.
   A template calls Kit.mount(renderFn, demoData). The renderer injects
   window.__SLIDE__ = { slide, ctx } and window.__KIT_CFG__ before load,
   then waits for window.__KIT_READY__ and reads window.__KIT_REPORT__.
   ===================================================================== */
(function () {
  /* ------------------------------------------------------------------
     LAUNCH STATE: the ONE switch for store wording across the whole kit.
       'coming' -> badge "Coming to Google Play", button "Coming soon to Google Play"
       'live'   -> badge "Now on Google Play",    button "Get it on Google Play"
     Flip it here, or per render without editing this file:
       node render.mjs ../content_plan.json ../out_live --launch live
       (or set env FITKEY_LAUNCH_STATE=live)
     A slide's own `badge` field in the plan still wins over the default badge.
     ------------------------------------------------------------------ */
  const LAUNCH_STATE = 'coming';

  const FORMATS = { post: [1080, 1350], square: [1080, 1080], story: [1080, 1920] };
  const CFG = Object.assign(
    { photos: '../../photos/', screens: '../../screens/', assets: '../assets/', handle: '@fitkeyapp', launchState: LAUNCH_STATE },
    window.__KIT_CFG__ || {}
  );
  const LAUNCH_COPY = {
    coming: { badge: 'Coming to Google Play', small: 'Coming soon to', big: 'Google Play', cta: 'Coming soon to Google Play' },
    live: { badge: 'Now on Google Play', small: 'Get it on', big: 'Google Play', cta: 'Get it on Google Play' },
  };
  const LAUNCH = LAUNCH_COPY[CFG.launchState] || LAUNCH_COPY.coming;
  const COLORS = {
    ember: '#FF5A36', primary: '#FF5A36', orange: '#FF5A36', lime: '#C8F31D', ink: '#1A1B25', green: '#1BA672', purple: '#7C5CFF',
    pink: '#FF4F9A', blue: '#3D7BFF', amber: '#FFA41B', teal: '#14B8A6', mansi: '#7C5CFF',
  };
  const report = { warnings: [], info: [] };
  const warn = (m) => report.warnings.push(m);

  /* ---------------- text ---------------- */
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  /** *word* -> highlight, **word** -> bold, \n -> line break */
  const rich = (s) => esc(s)
    .replace(/([A-Za-z])&#39;([A-Za-z])/g, '$1’$2')
    .replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')
    .replace(/\*(.+?)\*/g, '<em>$1</em>')
    .replace(/\\n|\n/g, '<br>');
  const plain = (s) => String(s ?? '').replace(/\*/g, '');

  /* ---------------- icons (hand-drawn, 24px grid, stroke) ---------------- */
  const P = {
    check: 'M5 12.5l4.5 4.5L19 7.5',
    arrow: 'M4.5 12h15M13.5 6l6 6-6 6',
    x: 'M6.5 6.5l11 11M17.5 6.5l-11 11',
    dumbbell: 'M6.5 6v12M17.5 6v12M3.5 9v6M20.5 9v6M6.5 12h11',
    swim: 'M2.5 16.5c1.6 0 1.6-1.4 3.2-1.4s1.6 1.4 3.2 1.4 1.6-1.4 3.2-1.4 1.6 1.4 3.2 1.4 1.6-1.4 3.2-1.4 1.6 1.4 1.5 1.4M2.5 20.5c1.6 0 1.6-1.4 3.2-1.4s1.6 1.4 3.2 1.4 1.6-1.4 3.2-1.4 1.6 1.4 3.2 1.4 1.6-1.4 3.2-1.4 1.6 1.4 1.5 1.4M8 13V5.5a2 2 0 014 0M15 13V5.5a2 2 0 014 0M8 8.5h7',
    yoga: 'M12 7.2a2.1 2.1 0 100-4.2 2.1 2.1 0 000 4.2zM12 9.5v5M5 10.5l7 3 7-3M4.5 19.5c2.5-2.6 5-3.2 7.5-3.2s5 .6 7.5 3.2M8 16.8l-2.5 2.7M16 16.8l2.5 2.7',
    run: 'M14.5 6.2a1.9 1.9 0 100-3.8 1.9 1.9 0 000 3.8zM7 21l3.2-5.5 3.3 2.5V22M5.5 11.5l3-3.2h4.3l2.3 3.6 3.4 1M10.8 8.4l-1.6 6.8',
    qr: 'M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h2.5v2.5H14zM18 18h2v2h-2zM14 19.5h1.5M19.5 14v1.5',
    key: 'M8 16a4 4 0 100-8 4 4 0 000 8zM12 12h8.5M17.5 12v3M14.5 12v2',
    sparkle: 'M11 3.5l1.9 5.1 5.1 1.9-5.1 1.9L11 17.5l-1.9-5.1L4 10.5l5.1-1.9zM18.5 15l.9 2.1 2.1.9-2.1.9-.9 2.1-.9-2.1-2.1-.9 2.1-.9z',
    play: 'M3.5 6.5a2.5 2.5 0 012.5-2.5h12a2.5 2.5 0 012.5 2.5v11a2.5 2.5 0 01-2.5 2.5H6a2.5 2.5 0 01-2.5-2.5zM10 9v6l5-3z',
    users: 'M9 11a3.3 3.3 0 100-6.6A3.3 3.3 0 009 11zM2.8 20c0-3.4 2.8-5.8 6.2-5.8s6.2 2.4 6.2 5.8M16.5 11.2a2.6 2.6 0 100-5.2M17.5 14.4c2.3.4 3.8 2.3 3.8 5',
    heart: 'M12 20s-7.5-4.6-7.5-10.3A4.2 4.2 0 0112 7.2a4.2 4.2 0 017.5 2.5C19.5 15.4 12 20 12 20z',
    pulse: 'M2.5 12.5h4.2l2.3-6 4.5 12 2.3-6h5.7',
    food: 'M3 11.5h18a9 9 0 01-18 0zM8 8c0-1.6 1-2 1-3.5M12 8c0-1.6 1-2 1-3.5M16 8c0-1.6 1-2 1-3.5',
    bag: 'M5 8h14l-1.1 12.1a1 1 0 01-1 .9H7.1a1 1 0 01-1-.9zM9 8V6.5a3 3 0 016 0V8',
    rupee: 'M7 4h10M7 8.7h10M7 4h2.5a4.4 4.4 0 010 8.8H7l8 7.2',
    pin: 'M12 21s-7-6.1-7-11.5a7 7 0 0114 0C19 14.9 12 21 12 21zM12 12a2.5 2.5 0 100-5 2.5 2.5 0 000 5z',
    calendar: 'M3.5 7.5a2.5 2.5 0 012.5-2.5h12a2.5 2.5 0 012.5 2.5V18a2.5 2.5 0 01-2.5 2.5H6A2.5 2.5 0 013.5 18zM3.5 10h17M8 3v4M16 3v4',
    trophy: 'M8 4h8v5.5a4 4 0 01-8 0zM8 6H4.5v1a3.5 3.5 0 003.5 3.5M16 6h3.5v1a3.5 3.5 0 01-3.5 3.5M12 13.5V17M8 20.5h8M9.5 17h5v3.5h-5z',
    bolt: 'M13.5 2.5L4.5 14h7l-1 7.5 9-11.5h-7z',
    flame: 'M12 21.5c3.9 0 7-2.7 7-6.8 0-4.4-3.8-6.6-5-10.7-2 1.8-3 3.9-3 5.8-1-.8-1.6-2-1.6-3.2C6.6 8.6 5 11.1 5 14.7c0 4.1 3.1 6.8 7 6.8z',
    clock: 'M12 21a9 9 0 100-18 9 9 0 000 18zM12 7v5l3.2 2',
    shield: 'M12 3l8 3v6c0 5-3.4 8-8 9-4.6-1-8-4-8-9V6zM8.5 12l2.4 2.4 4.6-4.8',
    chat: 'M4 6.5A2.5 2.5 0 016.5 4h11A2.5 2.5 0 0120 6.5v7a2.5 2.5 0 01-2.5 2.5H9l-5 4z',
    camera: 'M4 8h3l2-2.5h6L17 8h3v11H4zM12 16.5a3.5 3.5 0 100-7 3.5 3.5 0 000 7z',
    download: 'M12 4v11M7 10.5l5 5 5-5M5 20h14',
    ball: 'M12 21a9 9 0 100-18 9 9 0 000 18zM5.6 5.6c3.5 3.5 3.5 9.3 0 12.8M18.4 5.6c-3.5 3.5-3.5 9.3 0 12.8',
    music: 'M9 18V5.5l11-2V16M6 21a3 3 0 100-6 3 3 0 000 6zM17 19a3 3 0 100-6 3 3 0 000 6z',
    glove: 'M7 13V7.5A4.5 4.5 0 0111.5 3h2A4.5 4.5 0 0118 7.5V12a5 5 0 01-5 5h-2.5L7 13.5zM7 17h9.5v4H7zM11 9h4',
    gift: 'M3.5 8h17v4h-17zM5 12v8.5h14V12M12 8v12.5M12 8c-1.8-3.8-6-3.8-6-1.4C6 8 9 8 12 8zm0 0c1.8-3.8 6-3.8 6-1.4C18 8 15 8 12 8z',
    city: 'M4 21V8.5l6-4V21M10 21V10h10v11M2.5 21h19M13.5 13.5h3M13.5 17h3M6.5 12h1M6.5 15.5h1',
    target: 'M12 21a9 9 0 100-18 9 9 0 000 18zM12 16.5a4.5 4.5 0 100-9 4.5 4.5 0 000 9zM12 12.5a.5.5 0 100-1 .5.5 0 000 1z',
    star: 'M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.8l-5.2 2.8 1-5.8-4.3-4.1 5.9-.8z',
    lock: 'M6 10.5h12v10H6zM8.5 10.5V7.5a3.5 3.5 0 017 0v3',
    phone: 'M7.5 2.5h9a1.5 1.5 0 011.5 1.5v16a1.5 1.5 0 01-1.5 1.5h-9A1.5 1.5 0 016 20V4a1.5 1.5 0 011.5-1.5zM10.5 18.5h3',
    refresh: 'M20 11a8 8 0 00-14.6-4.5M4 4.5v4h4M4 13a8 8 0 0014.6 4.5M20 19.5v-4h-4',
    coin: 'M12 21a9 9 0 100-18 9 9 0 000 18zM12 17.5a5.5 5.5 0 100-11 5.5 5.5 0 000 11zM12 9.5v5',
    steps: 'M8 13.5c-1.7 0-2.8-1.8-2.8-4.4S6.4 3.5 8.2 3.5s2.6 2.6 2.4 5.4c-.2 2.6-1 4.6-2.6 4.6zM6 16.2l4.5-.6.4 2.7c.2 1.4-.8 2.4-2.1 2.4-1.2 0-2.3-.9-2.6-2.4zM16 10c1.7 0 2.8 1.8 2.8 4.4s-1.2 5.6-3 5.6',
  };
  const ALIAS = {
    gym: 'dumbbell', strength: 'dumbbell', workout: 'dumbbell', pool: 'swim', swimming: 'swim', run: 'run', running: 'run',
    ai: 'sparkle', mansi: 'sparkle', coach: 'sparkle', video: 'play', class: 'play', classes: 'play', community: 'users',
    friends: 'users', circle: 'users', circles: 'users', health: 'heart', track: 'pulse', tracking: 'pulse', diet: 'food',
    nutrition: 'food', meal: 'food', store: 'bag', shop: 'bag', wallet: 'rupee', pay: 'rupee', price: 'rupee', money: 'rupee', coins: 'coin', cancel: 'refresh', refund: 'refresh',
    location: 'pin', near: 'pin', nearby: 'pin', map: 'pin', book: 'calendar', booking: 'calendar', slot: 'calendar',
    challenge: 'trophy', arena: 'trophy', proveit: 'camera', leaderboard: 'trophy', streak: 'flame', fast: 'bolt',
    instant: 'bolt', time: 'clock', safe: 'shield', verified: 'shield', checkin: 'qr', 'check-in': 'qr', pass: 'key',
    sports: 'ball', dance: 'music', zumba: 'music', boxing: 'glove', mma: 'glove', rewards: 'gift', city: 'city',
    goals: 'target', goal: 'target', steps: 'steps', private: 'lock', app: 'phone',
  };
  const AUTO = [ // keyword -> icon for bullets without an explicit icon
    [/\b(gyms?|weights?|strength|lift)/i, 'dumbbell'], [/\b(pools?|swim)/i, 'swim'], [/\byoga|pilates|stretch/i, 'yoga'],
    [/\b(mansi|ai|coach)\b/i, 'sparkle'], [/\b(qr|scan|check-?in|walk in)/i, 'qr'], [/\b(pass|key|membership)/i, 'key'],
    [/\b(run|jog|cardio)/i, 'run'], [/\b(video|class|stream|live)/i, 'play'], [/\b(friends?|circle|community|crew|buddy)/i, 'users'],
    [/\b(food|diet|meal|nutrition|protein|calorie)/i, 'food'], [/\b(store|shop|gear|supplement)/i, 'bag'],
    [/(₹|\bpay|wallet|price|money|cash|save)/i, 'rupee'], [/\b(near|nearby|city|area|map|locat)/i, 'pin'],
    [/\b(book|slot|schedul|calendar)/i, 'calendar'], [/\b(challenge|arena|prove|leaderboard|win|trophy)/i, 'trophy'],
    [/\b(streak|burn|hot)/i, 'flame'], [/\b(heart|health|sleep|track|steps)/i, 'pulse'], [/\b(dance|zumba|music)/i, 'music'],
    [/\b(box|mma|martial|fight|kick)/i, 'glove'], [/\b(sport|badminton|tennis|football|cricket)/i, 'ball'],
    [/\b(safe|secure|verified|trust)/i, 'shield'], [/\b(reward|gift|offer)/i, 'gift'], [/\b(goal|target)/i, 'target'],
  ];
  const FALLBACK_ICONS = ['bolt', 'star', 'target', 'flame', 'heart', 'sparkle'];
  function icon(name, extra = '') {
    const n = P[name] ? name : ALIAS[String(name || '').toLowerCase()] || 'bolt';
    return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" ${extra}><path d="${P[n]}"/></svg>`;
  }
  function autoIcon(text, i = 0, title = '') {
    if (title) for (const [re, n] of AUTO) if (re.test(title)) return n;
    for (const [re, n] of AUTO) if (re.test(text)) return n;
    return FALLBACK_ICONS[i % FALLBACK_ICONS.length];
  }

  /* ---------------- brand ---------------- */
  /** The real app icon (assets/app_icon_tile.png, 675px square). Never rendered above 320px. */
  function mark(size = 64) {
    const px = Math.min(size, 320);
    return `<img class="mark" src="${esc(CFG.assets)}app_icon_tile.png" width="${px}" height="${px}" style="--ms:${px}px" alt="FITKEY">`;
  }
  const lockup = (size = 60) => `<div class="lockup">${mark(size)}<span class="word">FITKEY</span></div>`;

  /* ---------------- visuals ---------------- */
  /** Visual syntax (plan `visual` field):
        photo:<name> | screen:<name> | icon:<name>
        "<a> + <b>"  -> a is the main visual, b an inset (e.g. photo:roti + screen:meal_scan)
        "<a> vs <b>" -> side-by-side comparison (left a, right b; labels from the slide's 2 bullets) */
  function parseVisual(v) {
    if (!v) return { kind: 'none' };
    if (typeof v === 'object') return v;
    const vs = String(v).split(/\s+vs\s+/i);
    if (vs.length === 2) { const l = parseVisual(vs[0]), r = parseVisual(vs[1]); return { ...l, pair: { left: l, right: r } }; }
    const plus = String(v).split(/\s*\+\s*/);
    if (plus.length === 2) { const m = parseVisual(plus[0]); return { ...m, inset: parseVisual(plus[1]) }; }
    const m = String(v).match(/^(photo|screen|icon):(.+)$/);
    if (!m) return { kind: 'none' };
    const [, kind, raw] = m;
    // optional focal point: photo:name@center 30%
    const [name, focus] = raw.split('@').map((x) => x.trim());
    const psrc = (n) => CFG.photos + (/\.\w+$/.test(n) ? n : n + '.jpg');
    if (kind === 'photo' && name.includes(',')) {
      const names = name.split(',').map((x) => x.trim()).filter(Boolean);
      return { kind, name: names[0], src: psrc(names[0]), focus, collage: names.map((n) => ({ kind, name: n, src: psrc(n) })) };
    }
    if (kind === 'photo') return { kind, name, src: psrc(name), focus };
    if (kind === 'screen') return { kind, name, src: CFG.screens + (/\.\w+$/.test(name) ? name : name + '.png') };
    return { kind, name };
  }
  const pretty = (n) => String(n || 'Screen').replace(/\.\w+$/, '').replace(/[_-]+/g, ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase()).replace(/\bAi\b/g, 'AI').replace(/\bQr\b/g, 'QR')
    .replace(/\bProveit\b/g, 'ProveIt').replace(/\bFitfeed\b/g, 'FitFeed');
  function placeholderScreen(name) {
    const dots = ['#FF5A36', '#7C5CFF', '#1BA672'];
    return `<div class="ph"><div class="ph-top"><div class="ph-k">FITKEY</div><div class="ph-name">${esc(pretty(name))}</div></div>
      <div class="ph-body">${dots.map((c) => `<div class="ph-card"><div class="ph-dot" style="background:${c}"></div><div class="ph-lines"><i></i><i></i><i></i></div></div>`).join('')}
      <div class="ph-tag">Screen preview</div></div></div>`;
  }
  /** iPhone-style mockup. v = parsed visual. */
  /* The app screenshots carry no status bar, so the mockup draws a clean one (time, signal, wifi,
     battery) and insets the screenshot BELOW it: app content never sits under the dynamic island. */
  const STATUS_ICONS = `<svg viewBox="0 0 78 14" fill="currentColor" aria-hidden="true">
      <rect x="0" y="9" width="3.2" height="4.6" rx="1"/><rect x="5" y="6.5" width="3.2" height="7.1" rx="1"/><rect x="10" y="3.8" width="3.2" height="9.8" rx="1"/><rect x="15" y="1" width="3.2" height="12.6" rx="1"/>
      <path d="M31.5 3.3a10.6 10.6 0 017.5 3.1l1.5-1.5a12.7 12.7 0 00-18 0l1.5 1.5a10.6 10.6 0 017.5-3.1zm0 4.2a6.4 6.4 0 014.5 1.9l1.5-1.5a8.5 8.5 0 00-12 0l1.5 1.5a6.4 6.4 0 014.5-1.9zm0 4.2a2.2 2.2 0 011.6.7l-1.6 1.6-1.6-1.6a2.2 2.2 0 011.6-.7z"/>
      <rect x="47.5" y="1.2" width="25" height="12" rx="3.8" fill="none" stroke="currentColor" stroke-width="1.2" opacity=".45"/>
      <rect x="49.6" y="3.3" width="20.8" height="7.8" rx="2.2"/><path d="M74 5v4.4c.9-.3 1.5-1.2 1.5-2.2S74.9 5.3 74 5z" opacity=".5"/></svg>`;
  function phone(v, w = 400, style = '', auto = false) {
    const inner = v && v.kind === 'screen'
      ? `<img data-screen="${esc(v.name)}" src="${esc(v.src)}" alt="">`
      : placeholderScreen(v && v.name ? v.name : 'FitKey');
    return `<div class="phone"${auto ? ' data-auto' : ''} style="--pw:${w}px;${style}"><div class="scr">
      <div class="sbar"><span class="sb-time">9:41</span><span class="sb-ic">${STATUS_ICONS}</span></div><div class="island"></div>
      <div class="app">${inner}</div><div class="homebar"></div><div class="glare"></div></div></div>`;
  }
  /** Store button that follows LAUNCH_STATE. */
  function storeBtn(cls = '') {
    return `<div class="storebtn ${cls}"><span class="sb-ic">${icon('download')}</span><span class="sb-t"><small>${esc(LAUNCH.small)}</small><b>${esc(LAUNCH.big)}</b></span></div>`;
  }
  /** Compact launch pill (for single posts / stories). */
  function launchPill(cls = '') {
    return `<div class="lpill ${cls}"><span class="lp-ic">${icon(CFG.launchState === 'live' ? 'download' : 'clock')}</span>${esc(LAUNCH.cta)}</div>`;
  }
  /* post-fit layout hooks: templates register fns that run after fonts/images load and text is fitted */
  const afterFitFns = [];
  const afterFit = (fn) => afterFitFns.push(fn);
  function photo(v, focus = 'center', extra = '') {
    if (!v || v.kind !== 'photo') return `<div class="photo" style="background:var(--ember-grad)"></div>`;
    if (v.focus) focus = v.focus;
    if (v.collage) return `<div class="photo collage n${v.collage.length}" ${extra}>${v.collage.map((p) => `<img data-photo="${esc(p.name)}" src="${esc(p.src)}" alt="">`).join('')}</div>`;
    return `<div class="photo" ${extra}><img data-photo="${esc(v.name)}" src="${esc(v.src)}" style="object-position:${esc(focus)}" alt=""></div>`;
  }

  /* ---------------- theme ---------------- */
  /** dark slides: highlight is always lime (brand rule); glow follows accent.
      light slides: highlight follows accent (lime falls back to ember). */
  const normAccent = (a) => { a = String(a || '').toLowerCase(); return a === 'primary' || a === 'orange' || !COLORS[a] ? 'ember' : a; };
  const THEMES = ['dark', 'light', 'ember', 'lime', 'mansi'];
  function themeVars(theme, accent) {
    const a = normAccent(accent);
    const vars = [`--glow:${COLORS[a === 'lime' ? 'ember' : a]}`];
    if (theme === 'light') {
      const hl = a === 'lime' ? 'ember' : a === 'mansi' ? 'purple' : a;
      vars.push(`--hl:${COLORS[hl]}`, `--accent:${COLORS[hl]}`);
    }
    return vars.join(';');
  }
  const accentColor = (a, fallback = 'ember') => COLORS[normAccent(a)] || COLORS[fallback];

  function shell(s, c, { theme, cls = '', inner, header = true, footer = true, style = '' }) {
    // lime is the dark-surface accent: a lime-accented slide whose layout defaults to light goes dark instead
    const t = THEMES.includes(s.theme) ? s.theme : theme === 'light' && normAccent(s.accent) === 'lime' ? 'dark' : theme || 'dark';
    return `<div class="slide t-${t} ${cls}" data-type="${esc(s.type)}" style="${themeVars(t, s.accent)};${style}">
      <div class="bgfx"></div>${inner}
      <div class="grain"></div></div>`;
  }
  function hdr(c, { right } = {}) {
    return `<div class="hdr">${lockup(c.format === 'story' ? 68 : 60)}${right ?? `<span class="handle">${esc(CFG.handle)}</span>`}</div>`;
  }
  function ftr(c, { right, left } = {}) {
    const carousel = c.kind === 'carousel' && c.total > 1;
    // single feed posts carry the store-state pill where carousels carry their dots
    const dots = carousel ? `<div class="dots">${Array.from({ length: c.total }, (_, i) => `<i class="${i === c.index ? 'on' : ''}"></i>`).join('')}</div>`
      : c.kind === 'post' ? launchPill() : '<span></span>';
    const nxt = carousel && c.index < c.total - 1 ? `<div class="next">${icon('arrow')}</div>` : '<span></span>';
    return `<div class="ftr">${left ?? dots}${right ?? nxt}</div>`;
  }
  const swipe = (label = 'Swipe') => `<div class="swipe">${esc(label)} ${icon('arrow')}</div>`;
  /** Headline with highlight. Explicit *marks* win; highlight:false disables; highlight:"phrase" picks;
      otherwise the last sentence of a multi-sentence line, or the last word, gets the accent. */
  const tightPunct = (html) => html.replace(/([A-Za-zÀ-ɏ])([.!?,])/g, '$1<span class="pt">$2</span>');
  /* dialogue lines ("Mummy: ek roti aur? Me: scan first.") break before the second speaker */
  function headline(s) {
    let h = tightPunct(headlineRaw(s));
    if ((String(s.headline || '').match(/[A-Za-z]+:\s/g) || []).length >= 2) {
      const parts = h.split(/(?<=(?:\?|!|\.)(?:<\/span>)?)\s+(?=(?:<em>)?[A-Z][a-z]*(?:<span class="pt">)?:)/);
      // each speaker on one unbroken line; the auto-fitter shrinks the size until both fit
      if (parts.length === 2) h = parts.map((p) => `<span style="white-space:nowrap">${p}</span>`).join('<br>');
    }
    return h;
  }
  function headlineRaw(s) {
    const h = String(s.headline || '');
    if (s.highlight === false || h.includes('*')) return rich(h);
    if (typeof s.highlight === 'string' && h.includes(s.highlight)) return rich(h.replace(s.highlight, '*' + s.highlight + '*'));
    const parts = h.match(/[^.!?]+[.!?]+["”’]?\s*/g);
    if (parts && parts.length > 1 && parts.join('').trim() === h.trim()) {
      const last = parts.pop();
      return rich(parts.join('') + '*' + last.trim() + '*');
    }
    const m = h.match(/^([\s\S]*\s)(\S+)$/);
    return m ? rich(m[1] + '*' + m[2] + '*') : rich(h);
  }
  /* Store-availability claims follow LAUNCH_STATE too: while 'coming', an eyebrow that says
     "New/Now on Google Play" would be false, so it renders as the 'coming' badge (with a warning). */
  const STORE_CLAIM = /^\s*(new|now|live)\s+on\s+google\s+play\s*$/i;
  const eyebrow = (s) => {
    if (!s.eyebrow) return '';
    let t = s.eyebrow;
    if (CFG.launchState !== 'live' && STORE_CLAIM.test(t)) { warn(`eyebrow "${t}" swapped for "${LAUNCH.badge}" (LAUNCH_STATE=coming)`); t = LAUNCH.badge; }
    return `<div class="eyebrow">${esc(t)}</div>`;
  };
  function ticks(items) {
    if (!items || !items.length) return '';
    return `<ul class="ticks">${items.map((b) => `<li><span class="tk">${icon('check')}</span><span>${rich(typeof b === 'string' ? b : b.title || b.text)}</span></li>`).join('')}</ul>`;
  }
  /** Normalise bullets to {icon,title,text}. Accepts "Title|sub", "Title — sub" or objects. */
  function items(list) {
    return (list || []).map((b, i) => {
      if (typeof b === 'object') return { icon: b.icon || autoIcon(`${b.title} ${b.text || ''}`, i, b.title), title: b.title || b.text || '', text: b.title ? b.text || '' : '' };
      const [title, text = ''] = String(b).split(/\s*\|\s*|\s+[—–]\s+/);
      return { icon: autoIcon(String(b), i, title), title, text };
    });
  }

  /* ---------------- auto-fit ---------------- */
  function fitAll() {
    document.querySelectorAll('[data-box]').forEach((box) => {
      const stack = box.querySelector(':scope > .stack') || box.firstElementChild;
      if (!stack) return;
      const fits = [...box.querySelectorAll('[data-fit]')].sort((a, b) => (+a.dataset.order || 0) - (+b.dataset.order || 0));
      const over = () => stack.offsetHeight > box.clientHeight + 0.5 ||
        fits.some((f) => f.scrollWidth > f.clientWidth + 1) || stack.scrollWidth > stack.clientWidth + 1;
      for (const f of fits) f.style.fontSize = f.dataset.fit.split(',')[0] + 'px';
      for (const f of fits) {
        const min = +f.dataset.fit.split(',')[1];
        let s = parseFloat(f.style.fontSize);
        while (over() && s > min) { s -= 2; f.style.fontSize = s + 'px'; }
      }
      if (stack.dataset.grow !== undefined) stack.style.flex = "1 1 auto";
      if (over()) warn(`content overflows box "${box.dataset.box || ''}" even at minimum sizes — shorten copy`);
    });
  }

  /* ---------------- validation ---------------- */
  function validate(fmt) {
    const [W, H] = FORMATS[fmt];
    const edge = 40, top = fmt === 'story' ? 250 : edge, bottom = fmt === 'story' ? H - 250 : H - edge;
    document.querySelectorAll('.h,.body,.ticks,.eyebrow,.handle,.lockup,.chip,.storebtn,.swipe,.dots,.vs-col,.li,.qattr,.lpill,.hint').forEach((el) => {
      const r = el.getBoundingClientRect();
      if (!r.width || !r.height) return;
      if (r.left < edge - 0.5 || r.right > W - edge + 0.5 || r.top < top - 0.5 || r.bottom > bottom + 0.5) {
        warn(`${el.className.split(' ')[0]} outside safe area (${Math.round(r.left)},${Math.round(r.top)} → ${Math.round(r.right)},${Math.round(r.bottom)})`);
      }
    });
    document.querySelectorAll('img[data-photo]').forEach((img) => {
      const r = img.getBoundingClientRect();
      const scale = Math.max(r.width / img.naturalWidth, r.height / img.naturalHeight);
      if (img.naturalWidth && scale > 1.6) report.info.push(`photo "${img.dataset.photo}" upscaled ${scale.toFixed(2)}x (source ${img.naturalWidth}x${img.naturalHeight})`);
    });
    if (!document.fonts.check('800 40px PJS')) warn('Plus Jakarta Sans failed to load');
  }

  // every wait is capped so one slow decode can never stall a render (renderer times out at 60 s)
  const capped = (p, ms = 15000) => Promise.race([p, new Promise((r) => setTimeout(r, ms))]);
  async function ready(fmt) {
    try {
      await capped(Promise.all([400, 500, 600, 700, 800].map((w) => document.fonts.load(`${w} 40px PJS`, 'FITKEY Aa₹'))));
      await capped(document.fonts.ready);
      const imgs = [...document.images];
      await capped(Promise.all(imgs.map((img) => (img.complete ? 0 : new Promise((r) => { img.addEventListener('load', r); img.addEventListener('error', r); })))), 30000);
      for (const img of imgs) {
        if (img.naturalWidth) continue;
        if (img.dataset.screen) { report.info.push(`screen "${img.dataset.screen}" missing → placeholder`); img.outerHTML = placeholderScreen(img.dataset.screen); }
        else if (img.dataset.photo) { warn(`photo "${img.dataset.photo}" not found`); img.parentElement.style.background = 'var(--ember-grad)'; img.remove(); }
      }
      await capped(Promise.all([...document.images].map((i) => (i.decode ? i.decode().catch(() => {}) : 0))));
      fitAll();
      // phones marked data-auto shrink to fit their parent's height (never grow)
      document.querySelectorAll('.phone[data-auto]').forEach((p) => {
        const h = p.parentElement.clientHeight, w = parseFloat(p.style.getPropertyValue('--pw'));
        const max = Math.floor((h - 8) / (19.5 / 9));
        if (h && max < w) p.style.setProperty('--pw', max + 'px');
      });
      for (const fn of afterFitFns) fn();
      validate(fmt);
    } catch (e) { warn('kit error: ' + e.message); }
    // rAF can stall in background tabs during parallel renders, so a timer backs it up
    const done = () => { window.__KIT_REPORT__ = report; window.__KIT_READY__ = true; };
    requestAnimationFrame(() => requestAnimationFrame(done)); setTimeout(done, 250);
  }

  function mount(render, demo) {
    const d = window.__SLIDE__ || demo;
    const slide = d.slide || d;
    const FMT_ALIAS = { '1080x1350': 'post', '1080x1080': 'square', '1080x1920': 'story', feed: 'post', portrait: 'post', reel: 'story' };
    if (FMT_ALIAS[slide.format]) slide.format = FMT_ALIAS[slide.format];
    const ctx = Object.assign({ index: 0, total: 1, kind: 'post', format: slide.format || 'post' }, d.ctx || {});
    if (FMT_ALIAS[ctx.format]) ctx.format = FMT_ALIAS[ctx.format];
    if (!FORMATS[ctx.format]) ctx.format = 'post';
    document.body.className = 'fmt-' + ctx.format;
    if (ctx.format === 'story' && slide.sticker) document.body.classList.add('has-sticker');
    document.title = `${slide.type || 'slide'} · ${ctx.format}`;
    try { document.body.innerHTML = render(slide, ctx); }
    catch (e) { warn('render error: ' + e.message); document.body.innerHTML = `<pre style="color:#fff;font:24px monospace;padding:40px">${esc(e.stack)}</pre>`; }
    ready(ctx.format);
  }

  window.Kit = {
    FORMATS, CFG, COLORS, esc, rich, plain, icon, autoIcon, mark, lockup, parseVisual, phone, photo, placeholderScreen,
    shell, hdr, ftr, headline, normAccent, THEMES, swipe, eyebrow, ticks, items, accentColor, mount, warn, pretty,
    LAUNCH, LAUNCH_STATE: CFG.launchState, storeBtn, launchPill, afterFit, fitAll,
  };
})();

// FITKEY admin — "Partners" tab (Partner App BRD §I): listing review queue across every partner type, listing
// detail with documents / KYC / bank review and the change-request form, FitKey staff flags + assisted-listing
// report, and partner payouts. Loaded by admin.js; talks to /api/v1/admin/*.
const A = window.FitkeyAdmin;
const { h, api, toast, rupees, label, when, assetUrl } = A;

const STATUSES = ['submitted', 'under_review', 'changes_needed', 'approved', 'live', 'rejected', 'draft', 'all'];
const TYPES = ['all', 'venue', 'trainer', 'clinic', 'chemist', 'store'];
const TYPE_LABELS = { venue: 'Centre', trainer: 'Trainer', clinic: 'Clinic', chemist: 'Chemist', store: 'Store seller' };
const STATUS_LABELS = {
  draft: 'Draft',
  submitted: 'Submitted',
  under_review: 'Under review',
  changes_needed: 'Changes needed',
  approved: 'Approved · waiting for owner OTP',
  live: 'Live',
  rejected: 'Rejected',
};
// Steps the partner app walks through — "Changes needed" points at one of these.
const VENUE_STEPS = ['Category', 'Details', 'Location', 'Timings & FitKey access', 'Photos', 'Facilities',
  'Pricing & FitKey pass', 'Slots & capacity', 'Documents & bank', 'Review & submit'];
const OTHER_STEPS = ['Profile', 'Pricing', 'Availability', 'Documents', 'Review'];
const DEFAULT_TARGET_HOURS = 48;

const state = {
  section: 'listings', // listings | staff | payouts
  status: 'submitted',
  type: 'all',
  q: '',
  open: null, // { entityType, id } — listing detail
};

const n = (v) => Number(v ?? 0);
const hhmm = (t) => (t ? String(t).slice(0, 5) : '?');
const statusPill = (s) => {
  const cls = s === 'approved' ? 'upcoming' : s === 'changes_needed' ? 'pending' : s;
  return h('span', { class: `pill ${cls}` }, STATUS_LABELS[s] ?? label(s ?? '—'));
};

async function run(fn, ok, { rerender = true } = {}) {
  try {
    const r = await fn();
    if (ok) toast(ok);
    if (rerender) A.rerender();
    return r;
  } catch (err) {
    toast(err.message, true);
    return null;
  }
}

/** Hours since submission while the listing waits for FitKey (submitted / under review). */
function waiting(l, target) {
  if (!['submitted', 'under_review'].includes(l.status) || !l.submittedAt) return null;
  const hrs = (Date.now() - new Date(l.submittedAt).getTime()) / 36e5;
  const txt = hrs < 1 ? `${Math.round(hrs * 60)} min` : `${Math.floor(hrs)} h`;
  const over = hrs > target;
  const near = !over && hrs > target * 0.75;
  return h('span', {
    class: `pill ${over ? 'rejected' : near ? 'pending' : 'live'}`,
    title: `Review target: ${target} h`,
  }, over ? `${txt} · over ${target} h target` : `${txt} of ${target} h`);
}

// ------------------------------------------------------------------------------------------------ queue

async function listingsView() {
  const qs = new URLSearchParams();
  qs.set('status', state.status);
  if (state.type !== 'all') qs.set('entityType', state.type);
  if (state.q) qs.set('q', state.q);
  const all = (await api(`/admin/listings?${qs}`)).listings;
  // "Listings" from the staff report: only that employee's assisted listings.
  const listings = state.staffFilter ? all.filter((l) => l.listedBy === state.staffFilter) : all;
  const staffName = state.staffFilter ? all.find((l) => l.listedBy === state.staffFilter)?.listedByName ?? 'employee' : null;

  const statusFilters = STATUSES.map((s) =>
    h('button', { class: s === state.status ? 'active' : '', onclick: () => { state.status = s; A.rerender(); } },
      s === 'all' ? 'All' : STATUS_LABELS[s].split(' · ')[0]));
  const typeFilters = TYPES.map((t) =>
    h('button', { class: t === state.type ? 'active' : '', onclick: () => { state.type = t; A.rerender(); } },
      t === 'all' ? 'All types' : TYPE_LABELS[t]));
  const search = h('input', { placeholder: 'Name or owner phone…', value: state.q, style: 'max-width:240px' });
  search.addEventListener('keydown', (e) => { if (e.key === 'Enter') { state.q = search.value.trim(); A.rerender(); } });

  const overdue = listings.filter((l) => ['submitted', 'under_review'].includes(l.status) && l.submittedAt &&
    Date.now() - new Date(l.submittedAt).getTime() > DEFAULT_TARGET_HOURS * 36e5).length;

  return h('div', { class: 'stack' },
    h('div', { class: 'row filters' }, statusFilters),
    h('div', { class: 'row' }, h('div', { class: 'row filters' }, typeFilters), h('span', { class: 'spacer' }), search),
    overdue ? h('p', { class: 'muted', style: 'margin:0;color:var(--danger)' }, `${overdue} listing${overdue === 1 ? '' : 's'} past the ${DEFAULT_TARGET_HOURS}-hour review target.`) : null,
    staffName ? h('div', { class: 'row' }, h('span', { class: 'pill' }, `Listed by ${staffName}`),
      h('button', { class: 'ghost', onclick: () => { state.staffFilter = null; A.rerender(); } }, 'Show all')) : null,
    listings.length === 0 ? h('p', { class: 'muted' }, 'Nothing here.') : h('div', { class: 'card' }, h('table', {},
      h('tr', {}, ['Listing', 'Owner', 'Listed by', 'Submitted', 'Waiting', 'Docs · KYC · Bank', 'Status', ''].map((t) => h('th', {}, t))),
      listings.map((l) => h('tr', {},
        h('td', {}, h('strong', {}, l.name ?? '(no name yet)'),
          h('div', { class: 'muted' }, [TYPE_LABELS[l.entityType] ?? l.entityType, l.city].filter(Boolean).join(' · '))),
        h('td', {}, l.ownerName ?? '—', h('div', { class: 'muted' }, l.ownerPhone ?? '')),
        h('td', {}, l.listedByName ? h('span', { class: 'pill' }, `Staff: ${l.listedByName}`) : h('span', { class: 'muted' }, 'Owner')),
        h('td', {}, when(l.submittedAt)),
        h('td', {}, waiting(l, DEFAULT_TARGET_HOURS) ?? h('span', { class: 'muted' }, '—')),
        h('td', {},
          h('div', {}, `${n(l.docsVerified)}/${n(l.docsTotal)} verified${n(l.docsPending) ? ` · ${n(l.docsPending)} pending` : ''}`),
          h('div', { class: 'muted' }, `KYC ${l.kycStatus ?? '—'} · Bank ${l.bankStatus ?? '—'}`)),
        h('td', {}, statusPill(l.status),
          l.status === 'approved' && !l.partnerAcceptedAt ? h('div', { class: 'muted' }, 'Owner OTP pending') : null),
        h('td', {}, h('button', { class: 'ghost', onclick: () => { state.open = { entityType: l.entityType, id: l.entityId }; A.rerender(); } }, 'Open')),
      )),
    )),
  );
}

// ------------------------------------------------------------------------------------------------ detail

function kv(rows) {
  return h('table', {}, rows.filter(([, v]) => v != null && v !== '' && !(Array.isArray(v) && !v.length)).map(([k, v]) =>
    h('tr', {}, h('th', { style: 'width:200px' }, k), h('td', {}, Array.isArray(v) ? v.join(', ') : v))));
}

function hoursCard(l) {
  const hours = l.hours ?? [];
  const blocks = l.passBlocks ?? [];
  const closures = l.closures ?? [];
  if (!hours.length && !blocks.length && !closures.length && !l.opensAt) return null;
  const days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  return h('div', { class: 'card stack' },
    h('h3', {}, 'Timings & FitKey access'),
    hours.length
      ? h('table', {}, days.map((d) => {
        const rows = hours.filter((x) => x.weekday === d).sort((a, b) => String(a.opensAt).localeCompare(String(b.opensAt)));
        return h('tr', {}, h('th', { style: 'width:80px' }, label(d)),
          h('td', {}, rows.length ? rows.map((x) => h('span', { class: `pill ${x.kind === 'ladies_only' ? 'pending' : ''}`, style: 'margin-right:6px' },
            `${hhmm(x.opensAt)}–${hhmm(x.closesAt)}${x.kind === 'ladies_only' ? ' · ladies only' : ''}`)) : h('span', { class: 'muted' }, 'Closed')));
      }))
      : h('div', {}, `Timings ${hhmm(l.opensAt)}–${hhmm(l.closesAt)} · ${(l.openDays ?? []).join(', ')}`),
    h('div', {}, h('strong', {}, 'FitKey pass: '), l.fitkeyPassMode === 'blocked' ? 'Blocked at some times' : 'Accepted at all open hours',
      l.passAccepted === false ? h('span', { class: 'pill rejected', style: 'margin-left:6px' }, 'Pass consent not given') : null),
    blocks.length ? h('ul', {}, blocks.map((b) => h('li', {}, `Not valid ${hhmm(b.startsAt)}–${hhmm(b.endsAt)} on ${(b.days ?? []).map(label).join(', ')}${b.note ? ` — ${b.note}` : ''}`))) : null,
    closures.length ? h('div', {}, h('strong', {}, 'Upcoming closures: '),
      closures.map((c) => `${String(c.closedOn).slice(0, 10)}${c.slotStart ? ` ${hhmm(c.slotStart)}–${hhmm(c.slotEnd)}` : ' (all day)'}${c.note ? ` ${c.note}` : ''}`).join(' · ')) : null,
  );
}

function plansCard(l) {
  const plans = l.plans ?? [];
  if (!plans.length && !l.monthlyFeePaise) return null;
  return h('div', { class: 'card stack' },
    h('h3', {}, 'Pricing & plans'),
    l.monthlyFeePaise ? h('div', {}, `Monthly fee (pass payout base): ${rupees(l.monthlyFeePaise)}`,
      l.passPayoutPreview?.netPaise != null ? h('span', { class: 'muted' }, ` · per FitKey visit ≈ ${rupees(l.passPayoutPreview.netPaise)} net`) : null) : null,
    plans.length ? h('table', {},
      h('tr', {}, ['Plan', 'Duration', 'Price', 'Limits', "What's included", 'Approval'].map((t) => h('th', {}, t))),
      plans.map((p) => h('tr', {},
        h('td', {}, h('strong', {}, p.name), p.description ? h('div', { class: 'muted' }, p.description) : null),
        h('td', {}, `${label(p.duration === 'annual' ? 'yearly' : p.duration ?? '')}${p.durationDays ? ` · ${p.durationDays} d` : ''}`),
        h('td', {}, rupees(n(p.effectivePricePaise ?? p.pricePaise)), p.offerPct ? h('div', { class: 'muted' }, `${p.offerPct}% off`) : null),
        h('td', {}, [p.maxVisitsPerDay ? `${p.maxVisitsPerDay}/day` : null, p.maxVisitsPerWeek ? `${p.maxVisitsPerWeek}/week` : null, p.slotLimitNote]
          .filter(Boolean).join(' · ') || 'Unlimited'),
        h('td', {}, (p.inclusions ?? []).join(', ') || '—'),
        h('td', {}, p.approvalStatus ? h('span', { class: `pill ${p.approvalStatus === 'approved' ? 'live' : p.approvalStatus}` }, label(p.approvalStatus)) : '—'),
      ))) : null,
  );
}

function documentsCard(documents) {
  const review = (d, status) => {
    let note;
    if (status === 'rejected') {
      note = prompt(`Why is the ${label(d.docType)} rejected? (shown to the partner)`);
      if (!note) return;
    }
    run(() => api(`/admin/partner-documents/${d.id}`, { method: 'POST', body: { status, note } }), `${label(d.docType)} ${status}`);
  };
  return h('div', { class: 'card stack' },
    h('h3', {}, 'Documents'),
    documents.length === 0 ? h('p', { class: 'muted' }, 'No documents uploaded.') : h('table', {},
      h('tr', {}, ['Type', 'Number / expiry', 'Uploaded', 'Status', ''].map((t) => h('th', {}, t))),
      documents.map((d) => h('tr', {},
        h('td', {}, h('strong', {}, label(d.docType)), h('div', {}, h('a', { class: 'link', href: assetUrl(d.fileUrl), target: '_blank', rel: 'noopener' }, 'Open file ↗'))),
        h('td', {}, d.docNumber ?? '—', d.expiresOn ? h('div', { class: 'muted' }, `Expires ${String(d.expiresOn).slice(0, 10)}`) : null),
        h('td', {}, when(d.createdAt)),
        h('td', {}, h('span', { class: `pill ${d.status}` }, label(d.status)), d.reviewNote ? h('div', { class: 'muted' }, d.reviewNote) : null),
        h('td', { class: 'row' },
          d.status !== 'verified' ? h('button', { onclick: () => review(d, 'verified') }, 'Verify') : null,
          d.status !== 'rejected' ? h('button', { class: 'danger', onclick: () => review(d, 'rejected') }, 'Reject') : null),
      ))),
  );
}

function kycBankCard(kyc, bank) {
  const setBank = (status) => run(() => api(`/admin/partner-bank/${bank.id}`, { method: 'POST', body: { status } }), `Bank account ${status}`);
  return h('div', { class: 'grid', style: 'grid-template-columns:repeat(auto-fit,minmax(320px,1fr))' },
    h('div', { class: 'card stack' },
      h('h3', {}, 'KYC'),
      kyc ? kv([
        ['Method', label(kyc.method ?? '')],
        ['Aadhaar', kyc.aadhaarMasked], // masked only — the full number is never stored
        ['Name on ID', kyc.nameOnId],
        ['Status', h('span', { class: `pill ${kyc.status}` }, label(kyc.status ?? '—'))],
        ['Verified', kyc.verifiedAt ? when(kyc.verifiedAt) : null],
      ]) : h('p', { class: 'muted' }, 'Not done yet.'),
    ),
    h('div', { class: 'card stack' },
      h('h3', {}, 'Bank account'),
      bank ? [
        kv([
          ['Account', `•••• ${bank.last4}`],
          ['Holder', bank.holderName],
          ['Verified name', bank.verifiedName ? h('span', {}, bank.verifiedName,
            bank.holderName && bank.verifiedName.trim().toLowerCase() !== bank.holderName.trim().toLowerCase()
              ? h('span', { class: 'pill rejected', style: 'margin-left:6px' }, 'Name mismatch') : null) : null],
          ['IFSC', [bank.ifsc, bank.bankName].filter(Boolean).join(' · ')],
          ['Status', h('span', { class: `pill ${bank.status === 'failed' ? 'rejected' : bank.status}` }, label(bank.status ?? '—'))],
        ]),
        h('div', { class: 'row' },
          bank.status !== 'verified' ? h('button', { onclick: () => setBank('verified') }, 'Verify') : null,
          bank.status !== 'failed' ? h('button', { class: 'danger', onclick: () => setBank('failed') }, 'Mark failed') : null),
      ] : h('p', { class: 'muted' }, 'No bank account yet.'),
    ),
  );
}

function timelineCard(timeline, steps) {
  const events = timeline?.events ?? [];
  return h('div', { class: 'card stack' },
    h('h3', {}, 'Status timeline'),
    events.length === 0 ? h('p', { class: 'muted' }, 'No events yet.') : h('table', {},
      events.map((e) => h('tr', {},
        h('td', { style: 'width:190px' }, when(e.createdAt)),
        h('td', {}, statusPill(e.status), e.actorName ? h('span', { class: 'muted' }, ` by ${e.actorName}`) : null,
          e.note ? h('div', {}, e.note) : null,
          (e.fixes ?? []).length ? h('ul', { style: 'margin:4px 0 0' }, e.fixes.map((f) =>
            h('li', {}, h('strong', {}, `Step ${f.step} · ${steps[f.step - 1] ?? ''}: `), f.message))) : null),
      ))),
  );
}

/** Review buttons + the "Request changes" form (one message per step to fix). */
function actionsCard(entityType, id, l, steps) {
  const review = async (body, ok) => {
    // Raw fetch so a refused approval can show its go-live blockers (400 { error, details:[{step,label}] }).
    const token = localStorage.getItem('fitkey_admin_token');
    try {
      const res = await fetch(`/api/v1/admin/listings/${entityType}/${id}/review`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
        body: JSON.stringify(body),
      });
      const data = await res.json().catch(() => null);
      if (!res.ok) {
        const blockers = Array.isArray(data?.details) ? data.details.filter((b) => b && b.label) : [];
        const msg = data?.error ?? `Request failed (${res.status})`;
        toast(blockers.length ? `${msg}: ${blockers.map((b) => `${b.step ? `step ${b.step} · ` : ''}${b.label}`).join('; ')}` : msg, true);
        if (blockers.length) alert(`${msg}\n\n${blockers.map((b) => `• ${b.step ? `Step ${b.step}: ` : ''}${b.label}`).join('\n')}`);
        return;
      }
      toast(ok);
      A.rerender();
    } catch (err) {
      toast(err.message, true);
    }
  };
  const fixRows = steps.map((name, i) => {
    const box = h('input', { type: 'checkbox', style: 'width:auto;margin:0' });
    const msg = h('input', { placeholder: `What to fix in “${name}”`, disabled: true });
    box.addEventListener('change', () => { msg.disabled = !box.checked; if (box.checked) msg.focus(); });
    return { step: i + 1, box, msg, el: h('div', { class: 'row', style: 'flex-wrap:nowrap' },
      h('label', { class: 'row', style: 'margin:0;min-width:240px;font-weight:500' }, box, `${i + 1}. ${name}`), msg) };
  });
  const note = h('textarea', { placeholder: 'Note to the partner (optional)' });
  const form = h('div', { class: 'stack', hidden: true },
    h('p', { class: 'muted', style: 'margin:0' }, 'Tick each step that needs a fix and say exactly what to change — the partner app takes them straight to that step.'),
    fixRows.map((r) => r.el),
    note,
    h('div', { class: 'row' },
      h('button', { onclick: () => {
        const fixes = fixRows.filter((r) => r.box.checked).map((r) => ({ step: r.step, message: r.msg.value.trim() }));
        if (fixes.some((f) => f.message.length < 2)) return toast('Write a message for every ticked step', true);
        if (!fixes.length && !note.value.trim()) return toast('Pick at least one step to fix, or write a note', true);
        review({ action: 'changes_needed', fixes, note: note.value.trim() || undefined }, 'Changes requested');
      } }, 'Send change request'),
      h('button', { class: 'ghost', onclick: () => { form.hidden = true; } }, 'Cancel')),
  );
  const s = l.status;
  return h('div', { class: 'card stack' },
    h('h3', {}, 'Review'),
    h('div', { class: 'row' },
      ['submitted', 'changes_needed', 'rejected', 'draft'].includes(s)
        ? h('button', { class: 'ghost', onclick: () => review({ action: 'under_review' }, 'Marked under review') }, 'Mark under review') : null,
      s !== 'live' ? h('button', { class: 'ghost', onclick: () => { form.hidden = !form.hidden; } }, 'Request changes') : null,
      !['live', 'approved'].includes(s) ? h('button', { onclick: () => {
        const n2 = prompt('Approve this listing? Optional note to the partner:', '');
        if (n2 === null) return;
        review({ action: 'approve', note: n2.trim() || undefined }, 'Approved');
      } }, 'Approve') : null,
      s !== 'live' && s !== 'rejected' ? h('button', { class: 'danger', onclick: () => {
        const n2 = prompt('Reason for rejection (shown to the partner):');
        if (!n2) return;
        review({ action: 'reject', note: n2.trim() }, 'Rejected');
      } }, 'Reject') : null,
    ),
    s === 'approved' ? h('p', { class: 'muted', style: 'margin:0' },
      l.partnerAcceptedAt ? 'Owner accepted — going live.' : 'Approved. Waiting for the owner to accept the agreement by OTP (SMS sent with the app link).') : null,
    form,
  );
}

async function detailView() {
  const { entityType, id } = state.open;
  const d = await api(`/admin/listings/${entityType}/${id}`);
  const l = d.listing ?? {};
  const steps = entityType === 'venue' ? VENUE_STEPS : OTHER_STEPS;
  const target = d.timeline?.reviewTargetHours ?? DEFAULT_TARGET_HOURS;
  const status = l.status ?? l.listingStatus;
  const listingRow = { ...l, status, submittedAt: l.submittedAt };
  const photos = l.photos ?? (l.photoUrl ? [l.photoUrl] : []);
  const skip = new Set(['id', 'photos', 'hours', 'passBlocks', 'closures', 'plans', 'checklist', 'timeline', 'passPayoutPreview',
    'status', 'listingStatus', 'description', 'name', 'businessName']);
  const fields = Object.entries(l)
    .filter(([k, v]) => !skip.has(k) && v != null && v !== '' && typeof v !== 'object')
    .map(([k, v]) => [label(k.replace(/([A-Z])/g, '_$1').toLowerCase()), /At$|On$/.test(k) && /^\d{4}-\d{2}-\d{2}/.test(String(v)) ? when(v) : String(v)]);
  const arrays = Object.entries(l)
    .filter(([k, v]) => !skip.has(k) && Array.isArray(v) && v.length && v.every((x) => typeof x !== 'object'))
    .map(([k, v]) => [label(k.replace(/([A-Z])/g, '_$1').toLowerCase()), v.map((x) => label(String(x)))]);
  const checklist = l.checklist;

  return h('div', { class: 'stack' },
    h('div', { class: 'row' },
      h('button', { class: 'ghost', onclick: () => { state.open = null; A.rerender(); } }, '← Back to queue'),
      h('h2', { style: 'margin:0' }, l.name ?? l.businessName ?? 'Listing'),
      statusPill(status), h('span', { class: 'pill' }, TYPE_LABELS[entityType] ?? entityType),
      waiting(listingRow, target),
    ),
    h('div', { class: 'card stack' },
      h('div', { class: 'row' },
        h('div', {}, h('strong', {}, 'Owner: '), d.owner ? `${d.owner.name ?? '—'} · ${d.owner.phone}${d.owner.partnerType ? ` · ${label(d.owner.partnerType)}` : ''}` : '—'),
        h('span', { class: 'spacer' }),
        h('div', {}, h('strong', {}, 'Listed by: '), d.listedBy ? `${d.listedBy.name ?? '—'} (FitKey staff · ${d.listedBy.phone})` : 'Owner'),
      ),
      h('div', { class: 'muted' }, `Submitted ${when(l.submittedAt)} · Admin approved ${when(l.adminApprovedAt)} · Owner accepted ${when(l.partnerAcceptedAt)} · Live ${when(l.goLiveAt)}`),
      checklist ? h('div', {}, h('strong', {}, `Checklist ${checklist.percent ?? 0}%`),
        (checklist.missing ?? []).length ? h('span', { class: 'muted' }, ` — missing: ${checklist.missing.map((m) => `${m.step}. ${m.label}`).join(' · ')}`) : ' — complete') : null,
      l.description ? h('p', { style: 'margin:0' }, l.description) : null,
      photos.length ? h('div', { class: 'photos' }, photos.map((p) => h('a', { href: assetUrl(p), target: '_blank', rel: 'noopener' }, h('img', { src: assetUrl(p), alt: '', loading: 'lazy' })))) : null,
      l.videoUrl ? h('a', { class: 'link', href: assetUrl(l.videoUrl), target: '_blank', rel: 'noopener' }, 'Video tour ↗') : null,
      l.latitude ? h('a', { class: 'link', href: `https://www.google.com/maps?q=${l.latitude},${l.longitude}`, target: '_blank', rel: 'noopener' }, 'View on map ↗') : null,
    ),
    (d.goLiveBlockers ?? []).length ? h('div', { class: 'card stack', style: 'border-color:var(--danger)' },
      h('h3', { style: 'color:var(--danger)' }, 'Cannot go live yet'),
      h('ul', { style: 'margin:0' }, d.goLiveBlockers.map((b) => h('li', {}, `${b.step ? `Step ${b.step} · ` : ''}${b.label}`)))) : null,
    actionsCard(entityType, id, { ...l, status }, steps),
    h('div', { class: 'card stack' }, h('h3', {}, 'All fields'), kv([...arrays, ...fields])),
    hoursCard(l),
    plansCard(l),
    documentsCard(d.documents ?? []),
    kycBankCard(d.kyc, d.bank),
    (d.agreements ?? []).length ? h('div', { class: 'card' }, h('h3', {}, 'Agreement'),
      d.agreements.map((a) => h('div', {}, `Version ${a.version} accepted ${when(a.acceptedAt)}`))) : null,
    timelineCard(d.timeline, steps),
  );
}

// ------------------------------------------------------------------------------------------------ staff

/** Partner accounts by phone. Uses /admin/users when the server has it; otherwise owners found via the listings queue
 *  and the staff report (a brand-new partner with no listing yet must create one, or be found by phone there). */
async function findPartners(q) {
  try {
    const r = await api(`/admin/users?role=partner&q=${encodeURIComponent(q)}`);
    if (Array.isArray(r?.users)) return r.users;
  } catch { /* endpoint not available — fall back */ }
  const [{ listings }, { staff }] = await Promise.all([
    api(`/admin/listings?status=all&q=${encodeURIComponent(q)}`),
    api('/admin/staff-report'),
  ]);
  const byId = new Map();
  for (const s of staff) if (`${s.name ?? ''} ${s.phone ?? ''}`.toLowerCase().includes(q.toLowerCase())) byId.set(s.id, { id: s.id, name: s.name, phone: s.phone, isFitkeyStaff: s.isFitkeyStaff });
  for (const l of listings) {
    if (l.ownerId && !byId.has(l.ownerId)) byId.set(l.ownerId, { id: l.ownerId, name: l.ownerName, phone: l.ownerPhone, partnerType: l.partnerType, isFitkeyStaff: null });
  }
  const staffIds = new Set(staff.filter((s) => s.isFitkeyStaff).map((s) => s.id));
  return [...byId.values()].map((u) => ({ ...u, isFitkeyStaff: u.isFitkeyStaff ?? staffIds.has(u.id) }));
}

async function staffView() {
  const { staff } = await api('/admin/staff-report');
  const setStaff = (u, on) => run(() => api(`/admin/users/${u.id}/staff`, { method: 'PUT', body: { isFitkeyStaff: on } }),
    on ? `${u.name ?? u.phone} is now FitKey staff` : `${u.name ?? u.phone} is no longer staff`);

  const results = h('div');
  const input = h('input', { placeholder: 'Partner phone or name…', style: 'max-width:260px' });
  const search = async () => {
    const q = input.value.trim();
    if (q.length < 3) return toast('Type at least 3 characters', true);
    results.replaceChildren(h('p', { class: 'muted' }, 'Searching…'));
    try {
      const users = await findPartners(q);
      results.replaceChildren(users.length === 0
        ? h('p', { class: 'muted' }, 'No partner account found. The employee must first log in to the FITKEY Partner app with this number.')
        : h('table', {}, h('tr', {}, ['Partner', 'Phone', 'Staff', ''].map((t) => h('th', {}, t))),
          users.map((u) => h('tr', {},
            h('td', {}, u.name ?? '—', u.partnerType ? h('div', { class: 'muted' }, label(u.partnerType)) : null),
            h('td', {}, u.phone ?? '—'),
            h('td', {}, u.isFitkeyStaff ? h('span', { class: 'pill live' }, 'FitKey staff') : h('span', { class: 'muted' }, 'No')),
            h('td', {}, h('button', { class: u.isFitkeyStaff ? 'danger' : '', onclick: () => setStaff(u, !u.isFitkeyStaff) },
              u.isFitkeyStaff ? 'Remove staff' : 'Make FitKey staff')),
          ))));
    } catch (err) {
      results.replaceChildren(h('p', { class: 'muted' }, err.message));
    }
  };
  input.addEventListener('keydown', (e) => { if (e.key === 'Enter') search(); });

  const totals = staff.reduce((t, s) => ({ c: t.c + n(s.listingsCreated), a: t.a + n(s.approved), l: t.l + n(s.live) }), { c: 0, a: 0, l: 0 });
  return h('div', { class: 'stack' },
    h('div', { class: 'card stack' },
      h('h3', {}, 'FitKey staff (assisted listing)'),
      h('p', { class: 'muted', style: 'margin:0' }, 'Staff use their own FITKEY Partner app login to list centres, trainers, clinics and stores on behalf of owners. Their access to a listing ends once it goes live.'),
      h('div', { class: 'row' }, input, h('button', { onclick: search }, 'Search')),
      results,
    ),
    h('div', { class: 'grid' },
      h('div', { class: 'card stat' }, h('div', { class: 'muted' }, 'Listings created by staff'), h('div', { class: 'value' }, totals.c)),
      h('div', { class: 'card stat' }, h('div', { class: 'muted' }, 'Approved'), h('div', { class: 'value' }, totals.a)),
      h('div', { class: 'card stat' }, h('div', { class: 'muted' }, 'Live'), h('div', { class: 'value' }, totals.l)),
    ),
    h('div', { class: 'card stack' },
      h('h3', {}, 'Staff report'),
      staff.length === 0 ? h('p', { class: 'muted' }, 'No staff yet.') : h('table', {},
        h('tr', {}, ['Employee', 'Created', 'In review', 'Approved', 'Live', 'Last listing', ''].map((t) => h('th', {}, t))),
        staff.map((s) => h('tr', {},
          h('td', {}, h('strong', {}, s.name ?? '—'), h('div', { class: 'muted' }, s.phone ?? ''),
            s.isFitkeyStaff ? null : h('span', { class: 'pill rejected' }, 'Not staff any more')),
          h('td', {}, n(s.listingsCreated)),
          h('td', {}, n(s.inReview)),
          h('td', {}, n(s.approved)),
          h('td', {}, h('strong', {}, n(s.live))),
          h('td', {}, when(s.lastListingAt)),
          h('td', { class: 'row' },
            n(s.listingsCreated) ? h('button', { class: 'ghost', onclick: () => {
              state.section = 'listings'; state.status = 'all'; state.type = 'all'; state.q = ''; state.staffFilter = s.id; A.rerender();
            } }, 'Listings') : null,
            s.isFitkeyStaff ? h('button', { class: 'danger', onclick: () => setStaff(s, false) }, 'Remove staff') : null),
        ))),
    ),
  );
}

// ------------------------------------------------------------------------------------------------ payouts

async function payoutsView() {
  const r = await api('/admin/payouts');
  const payouts = r.payouts ?? [];
  // Default period: last full Monday–Sunday week (weekly payouts).
  const now = new Date();
  const lastSun = new Date(now); lastSun.setDate(now.getDate() - ((now.getDay() + 7) % 7 || 7));
  const lastMon = new Date(lastSun); lastMon.setDate(lastSun.getDate() - 6);
  const ymd = (d) => d.toLocaleDateString('en-CA');
  const from = h('input', { type: 'date', value: ymd(lastMon) });
  const to = h('input', { type: 'date', value: ymd(lastSun) });
  const runPeriod = () => {
    if (!from.value || !to.value || from.value > to.value) return toast('Pick a valid period', true);
    if (!confirm(`Create payouts for ${from.value} → ${to.value}? (FitKey-pass visits + direct plan sales; manual members are excluded)`)) return;
    run(async () => {
      const res = await api('/admin/payouts/run', { method: 'POST', body: { periodStart: from.value, periodEnd: to.value } });
      const count = res?.created ?? res?.payouts?.length ?? res?.count;
      if (count != null) toast(`${count} payout${count === 1 ? '' : 's'} created`);
    }, null);
  };
  const markPaid = (p) => {
    const utr = prompt(`UTR / bank reference for ${rupees(n(p.netPaise))} to ${p.partnerName ?? p.ownerName ?? 'the partner'}:`);
    if (!utr) return;
    run(() => api(`/admin/payouts/${p.id}`, { method: 'POST', body: { status: 'paid', utr: utr.trim() } }), 'Marked paid');
  };
  const setStatus = (p, status) => run(() => api(`/admin/payouts/${p.id}`, { method: 'POST', body: { status } }), `Payout ${label(status)}`);

  const pending = payouts.filter((p) => p.status !== 'paid' && p.status !== 'cancelled');
  return h('div', { class: 'stack' },
    h('div', { class: 'card stack' },
      h('h3', {}, 'Run a payout period'),
      h('div', { class: 'row' }, h('label', { style: 'margin:0' }, 'From', from), h('label', { style: 'margin:0' }, 'To', to),
        h('button', { onclick: runPeriod, style: 'align-self:flex-end' }, 'Create payouts')),
    ),
    h('div', { class: 'grid' },
      h('div', { class: 'card stat' }, h('div', { class: 'muted' }, 'To pay'), h('div', { class: 'value' }, rupees(pending.reduce((t, p) => t + n(p.netPaise), 0)))),
      h('div', { class: 'card stat' }, h('div', { class: 'muted' }, 'Pending payouts'), h('div', { class: 'value' }, pending.length)),
    ),
    h('div', { class: 'card' },
      payouts.length === 0 ? h('p', { class: 'muted' }, 'No payouts yet.') : h('table', {},
        h('tr', {}, ['Partner', 'Period', 'Gross', 'Commission', 'GST', 'Net', 'Bank', 'Status', ''].map((t) => h('th', {}, t))),
        payouts.map((p) => h('tr', {},
          h('td', {}, h('strong', {}, p.partnerName ?? p.ownerName ?? '—'), h('div', { class: 'muted' }, p.partnerPhone ?? p.ownerPhone ?? '')),
          h('td', {}, `${String(p.periodStart ?? '').slice(0, 10)} → ${String(p.periodEnd ?? '').slice(0, 10)}`),
          h('td', {}, rupees(n(p.grossPaise))),
          h('td', {}, rupees(n(p.commissionPaise))),
          h('td', {}, rupees(n(p.gstPaise))),
          h('td', {}, h('strong', {}, rupees(n(p.netPaise)))),
          h('td', {}, p.bankLast4 ? `•••• ${p.bankLast4}` : '—', p.bankStatus && p.bankStatus !== 'verified' ? h('div', { class: 'muted', style: 'color:var(--danger)' }, `Bank ${p.bankStatus}`) : null),
          h('td', {}, h('span', { class: `pill ${p.status === 'paid' ? 'live' : p.status === 'failed' || p.status === 'cancelled' ? 'rejected' : 'pending'}` }, label(p.status ?? '—')),
            p.utr ? h('div', { class: 'muted' }, `UTR ${p.utr}`) : null, p.paidAt ? h('div', { class: 'muted' }, when(p.paidAt)) : null),
          h('td', { class: 'row' },
            p.status !== 'paid' ? h('button', { onclick: () => markPaid(p) }, 'Mark paid') : null,
            p.status === 'pending' ? h('button', { class: 'ghost', onclick: () => setStatus(p, 'processing') }, 'Processing') : null,
            p.status !== 'paid' && p.status !== 'failed' ? h('button', { class: 'danger', onclick: () => setStatus(p, 'failed') }, 'Failed') : null),
        ))),
    ),
  );
}

// ------------------------------------------------------------------------------------------------ tab

A.register('partners', 'Partner listings', async () => {
  const sections = [['listings', 'Listings queue'], ['staff', 'Staff'], ['payouts', 'Payouts']].map(([k, t]) =>
    h('button', { class: k === state.section ? 'active' : '', onclick: () => { state.section = k; state.open = null; A.rerender(); } }, t));
  let body;
  try {
    body = state.section === 'staff' ? await staffView()
      : state.section === 'payouts' ? await payoutsView()
        : state.open ? await detailView() : await listingsView();
  } catch (err) {
    body = h('p', { class: 'muted' }, err.message);
  }
  return h('div', { class: 'stack' },
    h('div', { class: 'row' }, h('h2', { style: 'margin:0' }, 'Partners'), h('span', { class: 'spacer' }), h('div', { class: 'row filters' }, sections)),
    body,
  );
});

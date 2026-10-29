// Employee invite page: /corporate/join.html?token=… — sign in with the FITKEY member OTP and accept the HR invite.
'use strict';

const API = '/api/v1';
const token = new URLSearchParams(location.search).get('token') || '';
const body = document.getElementById('join-body');
let session = null;

function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (k === 'class') e.className = v;
    else e.setAttribute(k, v === true ? '' : v);
  }
  for (const k of kids.flat()) if (k != null && k !== false) e.append(k instanceof Node ? k : String(k));
  return e;
}
function toast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'error';
  t.hidden = false;
  clearTimeout(toast.t);
  toast.t = setTimeout(() => (t.hidden = true), 4000);
}
async function api(path, method = 'GET', data) {
  const res = await fetch(API + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(session ? { Authorization: `Bearer ${session}` } : {}) },
    body: data ? JSON.stringify(data) : undefined,
  }).catch(() => { throw new Error('Network error — check your connection'); });
  const json = await res.json().catch(() => null);
  if (!res.ok) throw new Error(json?.error ?? `Request failed (${res.status})`);
  return json;
}
function fail(title, text) {
  body.replaceChildren(el('div', { class: 'state error' }, el('div', { class: 'ico' }, '!'), el('h3', {}, title), el('p', {}, text)));
}

async function start() {
  if (!token) return fail('Invite link incomplete', 'Open the full link your HR team shared with you.');
  let inv;
  try {
    inv = (await api(`/corporate/join/${encodeURIComponent(token)}`)).invite;
  } catch (err) {
    return fail('Invite not available', err.message);
  }
  if (inv.status === 'revoked') return fail('Invite withdrawn', `${inv.org.name} has withdrawn this invite. Contact your HR team.`);
  const phoneForm = el('form', { class: 'stack' },
    el('label', { class: 'field' }, el('span', {}, 'Your phone number (FITKEY account)'), el('input', { name: 'phone', inputmode: 'tel', placeholder: '+91 98765 43210', required: true })),
    el('button', { class: 'btn primary block', type: 'submit' }, 'Send code'));
  const otpForm = el('form', { class: 'stack', hidden: true },
    el('label', { class: 'field' }, el('span', {}, '6-digit code'), el('input', { name: 'otp', inputmode: 'numeric', maxlength: 6, required: true })),
    el('p', { class: 'hint', id: 'dev' }),
    el('button', { class: 'btn primary block', type: 'submit' }, `Join ${inv.org.name}`));
  let phone = '';
  phoneForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    try {
      phone = phoneForm.phone.value;
      const r = await api('/auth/otp/request', 'POST', { phone, role: 'user' });
      phoneForm.hidden = true;
      otpForm.hidden = false;
      otpForm.querySelector('#dev').textContent = r.devOtp ? `Development code: ${r.devOtp}` : `We sent a code to ${phone}.`;
      otpForm.otp.focus();
    } catch (err) { toast(err.message); }
  });
  otpForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = otpForm.querySelector('button');
    btn.disabled = true;
    try {
      session = (await api('/auth/otp/verify', 'POST', { phone, otp: otpForm.otp.value, role: 'user' })).token;
      const r = await api(`/corporate/join/${encodeURIComponent(token)}`, 'POST');
      body.replaceChildren(el('div', { class: 'state' }, el('div', { class: 'ico' }, '✓'), el('h3', {}, `You're in, welcome to ${r.org.name}!`),
        el('p', {}, r.passes.length ? `Your company pass is active: ${r.passes.map((p) => p.planName).join(', ')}. Open the FITKEY app to check in at any covered centre.` : 'Your profile now shows your organisation badge, and you can join company events in the FITKEY app.')));
    } catch (err) {
      toast(err.message);
      btn.disabled = false;
    }
  });
  body.replaceChildren(
    el('h1', {}, `${inv.org.name} invited you`),
    el('p', { class: 'muted' }, `This invite is for ${inv.email}. Sign in with your FITKEY phone number to join — new to FITKEY? Your account is created automatically.`),
    inv.status === 'accepted' ? el('p', { class: 'hint' }, 'This invite was already accepted. Signing in with the same number shows your membership again.') : null,
    phoneForm, otpForm,
    el('p', { class: 'fine' }, `${inv.org.name} will see your pass status, check-ins and event participation — never your weight, nutrition or health data.`));
}
start();

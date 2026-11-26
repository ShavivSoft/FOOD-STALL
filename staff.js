// Burger Bytes — shared code for the Intake, Kitchen and Delivery screens.
// Each page sets window.ROLE = 'intake' | 'kitchen' | 'delivery' before loading this file.
const ROLE = window.ROLE;
if (!window.canReload) window.canReload = () => !document.querySelector('.flash');
const TITLES = { intake: 'INTAKE · COUNTER', kitchen: 'KITCHEN', delivery: 'DELIVERY' };
const CFG = window.STALL_CONFIG;
const sb = supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY, { auth: { persistSession: false } });
const $ = (id) => document.getElementById(id);
const rupee = (n) => '₹' + (Math.round(Number(n) * 100) / 100).toLocaleString('en-IN');
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

let pin = localStorage.getItem('pin-' + ROLE) || '';
let S = {};            // settings from the server
let orders = [];       // today's orders
let prev = new Map();  // id -> status, to spot changes
let firstLoad = true, lastOk = 0, clockSkew = 0, pollTimer = null;
const serverNow = () => Date.now() + clockSkew;
const mins = (iso) => Math.max(0, Math.floor((serverNow() - new Date(iso)) / 60000));

// ---------- page frame ----------
document.body.insertAdjacentHTML('afterbegin', `
  <div id="pinScreen" class="pin hidden">
    <img src="logo.png" alt="Burger Bytes">
    <h1>${TITLES[ROLE]}</h1>
    <input id="pinIn" type="password" inputmode="numeric" autocomplete="off" maxlength="8" placeholder="PIN">
    <div class="err" id="pinErr"></div>
    <button class="go" id="pinGo">Start</button>
  </div>
  <div id="app" class="hidden">
    <div class="bar">
      <img src="logo.png" alt=""><span class="role">${TITLES[ROLE]}</span><span class="sp"></span>
      <span><span class="dot" id="dot"></span><span id="live">Connecting…</span></span>
      <span class="clock" id="clock"></span>
      <button class="out" id="logout">Lock</button>
    </div>
    <div class="alertbar closed hidden" id="closedBar">🔴 STALL IS CLOSED${ROLE === 'intake' ? ' — no new orders. Ask the admin to open it.' : ' — finish the remaining tokens.'}</div>
    <div class="alertbar offline hidden" id="offBar">⚠️ No connection — reconnecting… Don't trust this screen until it turns green.</div>
    <div class="alertbar sound" id="soundBar">🔈 Tap anywhere once to turn on sound alerts</div>
    <main id="main"></main>
  </div>`);

// ---------- sound + keep screen awake ----------
let actx = null, wake = null;
async function keepAwake() { try { if ('wakeLock' in navigator && !wake) { wake = await navigator.wakeLock.request('screen'); wake.addEventListener('release', () => { wake = null; }); } } catch {} }
document.addEventListener('pointerdown', () => {
  try { actx = actx || new (window.AudioContext || window.webkitAudioContext)(); actx.resume(); $('soundBar').classList.add('hidden'); } catch {}
  keepAwake();
});
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') { keepAwake(); poll(); } });
function tone(freqs, gap = 0.18, vol = 0.45) {
  if (!actx) return;
  freqs.forEach((f, i) => {
    const o = actx.createOscillator(), g = actx.createGain(), t = actx.currentTime + i * gap;
    o.frequency.value = f; o.type = 'square';
    g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(vol, t + 0.02); g.gain.exponentialRampToValueAtTime(0.0001, t + gap * 0.9);
    o.connect(g).connect(actx.destination); o.start(t); o.stop(t + gap);
  });
}
const beepNew = () => tone([660, 880, 660, 880]);
const beepReady = () => { tone([880, 1175, 1568, 1175, 1568], 0.16); if (navigator.vibrate) navigator.vibrate([400, 150, 400, 150, 400]); };
const beepCancel = () => tone([440, 330, 220], 0.25);

// ---------- login ----------
function showPin(msg) {
  clearTimeout(pollTimer);
  $('app').classList.add('hidden'); $('pinScreen').classList.remove('hidden');
  $('pinErr').textContent = msg || ''; $('pinIn').value = ''; $('pinIn').focus();
}
$('pinGo').onclick = async () => {
  const p = $('pinIn').value.trim(); if (!p) return;
  $('pinGo').disabled = true; $('pinErr').textContent = '';
  const { data, error } = await sb.rpc('staff_login', { p_role: ROLE, p_pin: p });
  $('pinGo').disabled = false;
  if (error) return ($('pinErr').textContent = 'No connection — try again');
  if (!data.ok) return ($('pinErr').textContent = data.error);
  pin = p; localStorage.setItem('pin-' + ROLE, p); start();
};
$('pinIn').onkeydown = (e) => { if (e.key === 'Enter') $('pinGo').click(); };
$('logout').onclick = () => { if (confirm('Lock this screen? You will need the PIN again.')) { localStorage.removeItem('pin-' + ROLE); pin = ''; showPin(); } };

// ---------- live data ----------
let inFlight = false, again = false;
async function poll() {
  clearTimeout(pollTimer);
  if (!pin) return;
  if (inFlight) { again = true; return; } // one refresh at a time, so an alert never fires twice
  inFlight = true;
  try {
    const { data, error } = await sb.rpc('staff_board', { p_role: ROLE, p_pin: pin });
    if (error) throw error;
    if (!data.ok) { inFlight = false; localStorage.removeItem('pin-' + ROLE); pin = ''; return showPin('PIN changed — enter the new PIN'); }
    clockSkew = new Date(data.now) - Date.now();
    S = data.settings; lastOk = Date.now();
    const next = data.orders;
    if (!firstLoad) window.onChanges?.(next, prev);
    orders = next; prev = new Map(next.map((o) => [o.id, o.status])); firstLoad = false;
    window.render?.();
  } catch { /* offline: banner shows below */ }
  inFlight = false;
  if (again) { again = false; return poll(); }
  paintStatus();
  pollTimer = setTimeout(poll, document.visibilityState === 'visible' ? 2000 : 6000);
}
function paintStatus() {
  const online = Date.now() - lastOk < 7000;
  $('dot').classList.toggle('on', online);
  $('live').textContent = online ? 'Live' : 'Offline';
  $('offBar').classList.toggle('hidden', online || !lastOk);
  $('closedBar').classList.toggle('hidden', S.isOpen !== false);
}
setInterval(() => {
  $('clock').textContent = new Date(serverNow()).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  if (lastOk) paintStatus();
}, 1000);

async function act(id, action) {
  const { data, error } = await sb.rpc('staff_act', { p_role: ROLE, p_pin: pin, p_id: id, p_action: action });
  if (error) { alert('No connection — the tap did not go through. Try again.'); return null; }
  if (!data.ok) { alert(data.error); poll(); return null; }
  await poll();
  return data.order;
}

function flash(kind, title, n, text, ms = 6000) {
  const el = document.createElement('div');
  el.className = 'flash ' + kind;
  el.innerHTML = `<div><h2>${title}</h2><div class="n">#${n}</div><p>${text}</p><button>OK</button></div>`;
  el.querySelector('button').onclick = () => el.remove();
  document.body.appendChild(el);
  setTimeout(() => el.remove(), ms);
}

// item lines, big and plain for the kitchen / delivery
function lines(o, { coke = true } = {}) {
  const L = [];
  if (o.cheese) L.push(`<div class="line"><b>${o.cheese}×</b>🧀 WITH CHEESE</div>`);
  if (o.plain) L.push(`<div class="line"><b>${o.plain}×</b>NO CHEESE</div>`);
  if (coke && o.coke) L.push(`<div class="line coke"><b>${o.coke}×</b>🥤 ${esc((S.cokeName || 'Diet Coke').toUpperCase())}</div>`);
  return `<div class="lines">${L.join('')}</div>`;
}
function short(o) {
  const L = [];
  if (o.cheese) L.push(`${o.cheese}× Cheese`);
  if (o.plain) L.push(`${o.plain}× No cheese`);
  if (o.coke) L.push(`${o.coke}× ${esc(S.cokeName || 'Diet Coke')}`);
  return L.join(' · ');
}
const ageClass = (m) => (m >= 12 ? 'late' : m >= 7 ? 'warn' : '');

function start() {
  $('pinScreen').classList.add('hidden'); $('app').classList.remove('hidden');
  firstLoad = true; poll();
}
if (pin) start(); else showPin();

'use strict';

/*
  防休眠控制台 — the only script on the page.

  Constraints held throughout:
    * zero dependency, zero network: this file only ever talks to 127.0.0.1 on
      the port this folder is served from;
    * every dynamic value goes in through textContent. Log lines and powercfg
      output are file content and must never be parsed as HTML;
    * the UI shows what the worker reported, not what was asked for. Where the
      two disagree the gap is stated out loud instead of papered over;
    * the heartbeat trace is drawn from antiLockIntervalSec and lastPulseEpoch
      only - pulses are strictly periodic, so the ticks on screen are arithmetic
      on real data, not decoration pretending to be a signal;
    * no human-facing string is written here any more: every one of them is a
      dictionary lookup (KA.t, see i18n.js), including the ones that embed
      computed values. What stays literal is machine data only - API paths,
      the header the server checks, power flag names, log tokens and the
      regular expressions that interpret what the backend reports.
*/

const H  = { 'X-Ka-Client': 'ka-dashboard' };
const HJ = { 'X-Ka-Client': 'ka-dashboard', 'Content-Type': 'application/json' };

const $ = (id) => document.getElementById(id);
const els = {};
[
  'conn', 'connText', 'clock', 'version', 'dais', 'nav', 'langSeg',
  'stateDot', 'stateTitle', 'stateDetail', 'modes', 'alerts',
  'ringArc', 'mLeft', 'mLeftHint', 'gaugeMeta',
  'bits', 'eng1State', 'eng1Note', 'eng2State', 'eng2Spec', 'eng2Note',
  'traceCanvas', 'traceIdle', 'traceStart', 'traceMid', 'traceEnd',
  'mElapsed', 'mElapsedSub', 'mPulses', 'mPulsesSub', 'mIdle', 'mIdleSub',
  'mBattery', 'mBatterySub', 'mEfficacy', 'mEfficacySub',
  'presets', 'customMin', 'optDisplay', 'optAntiLock', 'optInterval', 'optReassert',
  'optAway', 'optBattOff', 'optFloor', 'methodSegs', 'lockRow', 'intervalHint',
  'btnStart', 'btnStop', 'btnSave', 'btnRefresh', 'busy',
  'evRange', 'evSummary', 'timeline', 'btnEvidence', 'evCounts', 'evNote',
  'evfChips', 'evfSearch', 'evfHits', 'evfLens',
  'guide', 'btnGuideDismiss', 'preview',
  'pvDur', 'pvFlags', 'pvHb', 'pvAway', 'pvBattery', 'pvRisks', 'pvConfirm', 'pvCancel',
  'planTable', 'machineCard', 'riskList', 'lidNow', 'btnCheck', 'checkHint',
  'btnGuard', 'guardText', 'guardTable',
  'log', 'logPath', 'btnLog', 'autoLog', 'btnStopServer', 'footInfo', 'toasts'
].forEach((k) => { els[k] = $(k); });

const ES = { continuous: 0x80000000, system: 0x00000001, display: 0x00000002, away: 0x00000040 };
const RING_C = 326.73;

const state = {
  s: null,               // last /api/state
  report: null,
  evData: null,          // last /api/evidence, so a language change can repaint it
  logLines: null,        // last /api/log, same reason
  evHours: 6,
  evFilter: { chip: 'all', q: '' },   // a view lens only - aggregates stay window-wide
  previewOpen: false,
  skew: 0,               // serverEpoch - localEpoch, so countdowns survive clock drift
  stopping: false,
  controlsDirty: false,
  langChoice: 'auto',    // what config.json says: auto | zh | en
  renderErr: ''
};

/* ------------------------------------------------------------------ helpers */
function text(el, t) { if (el) el.textContent = t == null ? '' : String(t); }
function cls(el, c) { if (el) el.className = c; }

/*
  The report payload carries facts, not sentences: an entry is { id, ...vars } where id is
  a dictionary key shared with ka-core.ps1. Unknown ids and older plain-string payloads
  show as-is - a greppable fragment beats a hole where a warning used to be.
*/
function prose(e) {
  if (e == null) return '';
  if (typeof e === 'string') return e;
  if (e.id) return KA.has(e.id) ? KA.t(e.id, e) : String(e.id);
  return JSON.stringify(e);
}

/* `instrument` is one of five machine names the backend picks (full / both / s3-only /
   no-session-events / blind). Same doctrine as ev.reason.*: word it from the panel dictionary,
   show the raw token when a language is missing wording, never invent a sentence. The four
   classifier functions above must stay self-contained - the test harness extracts them one by
   one - so this helper is only reachable from the render layer. */
function kaInstrumentLabel(token) {
  const t = String(token || '');
  if (!t) return '';
  return KA.has('ev.instrument.' + t) ? KA.t('ev.instrument.' + t) : t;
}

/*
  KA.apply cannot reach a Chinese sentence that is broken across several direct text
  nodes with markup in between - <b>S</b> start, a <span class="mono"> command in the
  middle of a clause - because writing textContent into the parent would delete that
  markup. index.html declares those runs with data-i18n-inline="key1 key2 ...": the
  keys are handed to the element's own text nodes in order, so the styling survives
  and every fragment still has a dictionary entry. Leading and trailing spaces of each
  node are kept, which is what makes the zh values come out byte-for-byte identical.
*/
function fillInlineRuns() {
  document.querySelectorAll('[data-i18n-inline]').forEach((el) => {
    const keys = (el.getAttribute('data-i18n-inline') || '').split(/\s+/).filter(Boolean);
    const nodes = [];
    for (let n = el.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3 && /\S/.test(n.nodeValue)) nodes.push(n);
    }
    for (let i = 0; i < keys.length && i < nodes.length; i++) {
      const lead = /^\s*/.exec(nodes[i].nodeValue)[0];
      const trail = /\s*$/.exec(nodes[i].nodeValue)[0];
      nodes[i].nodeValue = lead + KA.t(keys[i]) + trail;
    }
  });
}

function fmtDuration(sec) {
  sec = Math.max(0, Math.floor(sec || 0));
  if (sec < 60) return KA.t('dur.sec', { n: sec });
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60);
  if (h < 1) return m + KA.t('dur.min');
  if (h < 24) return h + KA.t('dur.h') + (m ? ' ' + m + KA.t('dur.m') : '');
  return Math.floor(h / 24) + KA.t('dur.d') + (h % 24) + KA.t('dur.h');
}

function fmtClock(epoch) {
  if (!epoch) return '—';
  const d = new Date(Number(epoch) * 1000);
  const p = (n) => String(n).padStart(2, '0');
  return p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

function hhmmss(epoch) {
  const d = new Date(Number(epoch) * 1000), p = (n) => String(n).padStart(2, '0');
  return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

function nowEpoch() { return Math.floor(Date.now() / 1000) + state.skew; }

function selectedMinutes() {
  const custom = parseInt(els.customMin.value, 10);
  if (Number.isFinite(custom) && custom > 0) return Math.min(10080, custom);
  const on = els.presets.querySelector('.seg.is-on');
  return on ? parseInt(on.dataset.min, 10) : 0;
}

function toast(msg, kind) {
  if (!msg) return;
  const el = document.createElement('div');
  el.className = 'toast ' + (kind || 'info');
  el.textContent = msg;
  els.toasts.appendChild(el);
  while (els.toasts.children.length > 4) els.toasts.removeChild(els.toasts.firstChild);
  setTimeout(() => {
    el.classList.add('toast--out');
    setTimeout(() => el.remove(), 320);
  }, 9000);
}

function setBusy(b) {
  els.busy.hidden = !b;
  [els.btnStart, els.btnStop, els.btnSave, els.btnRefresh, els.btnGuard, els.btnCheck, els.pvConfirm, els.pvCancel].forEach((x) => { if (x) x.disabled = !!b; });
  if (!b && state.s) els.btnStop.disabled = !state.s.running && !kaUnrecorded(state.s);
}

async function api(path, opts) {
  // One funnel, so no call site can forget the language. The server writes the strings it
  // returns (rejection reasons, config errors) and must write them in the language this
  // panel is showing: under language=auto the browser and the OS display language can
  // disagree, and the panel already decided which one the visitor is reading.
  const o = Object.assign({}, opts);
  o.headers = Object.assign({}, o.headers, { 'X-Ka-Lang': KA.lang });
  const res = await fetch(path, o);
  let data = null;
  try { data = await res.json(); } catch (e) { data = { ok: false, reason: KA.t('api.notJson', { status: res.status }) }; }
  if (!res.ok || data.ok === false) {
    const err = new Error(data.reason || data.error_text || KA.t('api.http', { status: res.status }));
    err.status = res.status; err.data = data;
    throw err;
  }
  return data;
}

function flagOn(flags, bit) { return ((Number(flags) || 0) >>> 0 & bit) !== 0; }

/* ---------------------------------------------------------------- dais: render */
function renderConn(ok, slow) {
  cls(els.conn, 'link ' + (ok ? 'link--ok' : (slow ? 'link--slow' : 'link--bad')));
  text(els.connText, ok ? KA.t('conn.ok') : (slow ? KA.t('conn.gone') : KA.t('conn.dead')));
}

/* A worker that is alive but cannot write state.json reads as "not running" everywhere the
   panel looks. This one predicate is what every other surface consults before it is allowed
   to state an absence: "no power request", "idle plan applies", "heartbeat off" are all
   claims about engines whose readings are simply missing in that state. */
function kaUnrecorded(s) {
  return !!(s && !s.running && Number(s.workerCount || 0) > 0);
}

function renderPills(s) {
  els.modes.textContent = '';
  const add = (label, tone) => {
    const el = document.createElement('span');
    el.className = 'pill' + (tone ? ' pill--' + tone : '');
    el.textContent = label;
    els.modes.appendChild(el);
  };
  const w = s.running ? s.worker : null;
  if (w) {
    add(w.displayActive ? KA.t('pill.displayOn') : (w.keepDisplayOn ? KA.t('pill.displayDowngraded') : KA.t('pill.systemOnly')), w.displayActive ? 'on' : 'warn');
    add(w.antiLock ? KA.t('pill.heartbeat', { method: w.antiLockMethod, sec: w.antiLockInterval }) : KA.t('pill.heartbeatOff'), w.antiLock ? 'on' : 'warn');
    if (w.awayMode) add(KA.t('pill.away'), 'warn');
    add(KA.t('pill.reassert', { sec: (w.reassertSec || 60) }));
    if (w.lockSkips > 0) add(KA.t('pill.lockSkips', { n: w.lockSkips }), 'warn');
    if (w.ilSkips > 0) add(KA.t('pill.ilSkips', { n: w.ilSkips }), 'warn');
    // Machine tokens, not sentences: a worker newer than this page cannot push an
    // unreadable string into the pill. An unknown token shows raw, which is greppable.
    if (w.note) {
      const k = 'pill.note.' + w.note;
      add(KA.has(k) ? KA.t(k, { pct: w.batteryPercent, floor: w.batteryFloor }) : String(w.note), 'warn');
    }
    if (w.error) {
      const at = String(w.error).indexOf(':');
      const code = at < 0 ? String(w.error) : String(w.error).slice(0, at);
      const k = 'pill.error.' + code;
      add(KA.has(k) ? KA.t(k, { why: at < 0 ? '' : String(w.error).slice(at + 1) }) : String(w.error), 'bad');
    }

    // config vs reality: name the gap rather than letting it read as a silent success.
    const c = s.config || {}, drift = [];
    if (!!c.keepDisplayOn !== !!w.keepDisplayOn) drift.push('keepDisplayOn');
    if (!!c.antiLock !== !!w.antiLock) drift.push('antiLock');
    if ((c.antiLockMethod || '') !== (w.antiLockMethod || '')) drift.push('antiLockMethod');
    if (Number(c.antiLockIntervalSec) !== Number(w.antiLockInterval)) drift.push('antiLockIntervalSec');
    if (!!c.awayMode !== !!w.awayMode) drift.push('awayMode');
    if (Number(c.batteryFloorPercent) !== Number(w.batteryFloor)) drift.push('batteryFloorPercent');
    if (drift.length) add(KA.t('pill.drift', { keys: drift.join(KA.t('common.listSep')) }), 'warn');
  } else {
    const c = s.config || {};
    add(KA.t(kaUnrecorded(s) ? 'pill.unrecorded' : 'pill.idlePlan'));
    if (c.antiLock) add(KA.t('pill.standby', { method: c.antiLockMethod, sec: c.antiLockIntervalSec }));
  }
  const comp = (s.competitors || {}).suspected;
  if (Array.isArray(comp) && comp.length) add(KA.t('pill.competitors', { list: comp.map((x) => prose(x.label)).join(KA.t('common.listSep')) }), 'warn');
}

function renderAlerts(s) {
  els.alerts.textContent = '';
  (s.alert || []).forEach((a) => {
    const div = document.createElement('div');
    div.className = 'alert' + (a.level === 'bad' ? ' alert--bad' : '');
    div.textContent = prose(a);
    els.alerts.appendChild(div);
  });
}

function readout(el, tone) {
  const ro = el && el.closest('.ro');
  if (!ro) return;
  ['good', 'warn', 'bad'].forEach((tone1) => ro.classList.toggle('is-' + tone1, tone1 === tone));
}

function renderGauge(s) {
  const w = s.worker;
  let frac = 0, val = '—', hint = KA.t('gauge.hint.idle');
  if (s.running && w) {
    const total = (w.expiresEpoch > 0) ? (w.expiresEpoch - w.startedEpoch) : 0;
    if (total > 0) {
      const left = Math.max(0, w.expiresEpoch - nowEpoch());
      frac = Math.min(1, left / total);
      val = fmtDuration(left);
      hint = KA.t('gauge.hint.expires', { at: fmtClock(w.expiresEpoch) });
    } else {
      frac = 1; val = '∞'; hint = KA.t('gauge.hint.infinite');
    }
  } else if (s.intent && s.intent.desired === 'awake') {
    hint = KA.t('gauge.hint.intentOrphan');
  }
  els.ringArc.style.strokeDashoffset = String(RING_C * (1 - frac));
  text(els.mLeft, val);
  els.mLeft.classList.toggle('is-long', val.length > 6);
  text(els.mLeftHint, hint);

  const it = s.intent || {};
  els.gaugeMeta.textContent = '';
  const meta = (k, v) => {
    const li = document.createElement('li');
    const a = document.createElement('span'); a.textContent = k;
    const b = document.createElement('b'); b.textContent = v;
    li.appendChild(a); li.appendChild(b);
    els.gaugeMeta.appendChild(li);
  };
  meta('intent', it.desired === 'awake' ? KA.t('gauge.meta.intentAwake') : (it.desired || 'off'));
  meta(KA.t('gauge.meta.duration'), it.minutes ? fmtDuration(it.minutes * 60) : (s.running ? KA.t('gauge.meta.unlimited') : KA.t('gauge.meta.notSet')));
  meta(KA.t('gauge.meta.intentWritten'), it.updatedAt ? fmtClock(it.updatedAt) : KA.t('gauge.meta.never'));
  const alien = (s.foreignWorkers || []);
  meta('worker',
    (s.running ? ('pid ' + w.pid)
      : ((s.workerCount || 0) > 0 ? KA.t('gauge.meta.orphans', { n: s.workerCount }) : KA.t('gauge.meta.none')))
    + (alien.length
      ? KA.t('gauge.meta.alien', { n: alien.length, root: (alien[0].root || KA.t('gauge.meta.otherRoot')) })
      : ''));
  meta(KA.t('gauge.meta.lastReport'), (s.running && w.lastTickEpoch) ? KA.t('gauge.meta.ago', { n: Math.max(0, nowEpoch() - Number(w.lastTickEpoch)) }) : '—');
}

function renderEngines(s) {
  const w = s.worker;
  els.bits.textContent = '';
  const bit = (label, hex, live, requested) => {
    const el = document.createElement('span');
    el.className = 'bit ' + (live ? 'bit--live' : (requested ? 'bit--down' : 'bit--off'));
    const i = document.createElement('i');
    const b = document.createElement('b'); b.textContent = label;
    const e = document.createElement('em'); e.textContent = hex;
    el.appendChild(i); el.appendChild(b); el.appendChild(e);
    el.title = KA.t('engine.bitTip', {
      label: label, hex: hex,
      state: KA.t(live ? 'engine.bit.live' : (requested ? 'engine.bit.requested' : 'engine.bit.off'))
    });
    els.bits.appendChild(el);
  };
  if (!w) {
    bit('ES_CONTINUOUS', '0x80000000', false, false);
    bit('ES_SYSTEM_REQUIRED', '0x00000001', false, false);
    bit('ES_DISPLAY_REQUIRED', '0x00000002', false, false);
    bit('ES_AWAYMODE_REQUIRED', '0x00000040', false, false);
    const unrec = kaUnrecorded(s);
    text(els.eng1State, KA.t(unrec ? 'engine.unrecordedState' : 'engine1.none'));
    text(els.eng1Note, KA.t(unrec ? 'engine.unrecordedNote' : 'engine1.noteIdle'));
  } else {
    const base = Number(w.baseFlags) || 0, active = Number(w.activeFlags) || 0;
    bit('ES_CONTINUOUS', '0x80000000', flagOn(active, ES.continuous), flagOn(base, ES.continuous));
    bit('ES_SYSTEM_REQUIRED', '0x00000001', flagOn(active, ES.system), flagOn(base, ES.system));
    bit('ES_DISPLAY_REQUIRED', '0x00000002', flagOn(active, ES.display), flagOn(base, ES.display));
    bit('ES_AWAYMODE_REQUIRED', '0x00000040', flagOn(active, ES.away), flagOn(base, ES.away));
    text(els.eng1State, KA.t('engine1.state', { pid: w.pid, hex: '0x' + ((active >>> 0).toString(16).toUpperCase().padStart(8, '0')) }));
    text(els.eng1Note, KA.t(flagOn(active, ES.system) ? 'engine1.noteOk' : 'engine1.noteRejected'));
  }

  els.eng2Spec.textContent = '';
  const spec = (k, v, tone) => {
    const li = document.createElement('li');
    const a = document.createElement('span'); a.className = 'k'; a.textContent = k;
    const b = document.createElement('span'); b.className = 'v' + (tone ? ' v--' + tone : ''); b.textContent = v;
    li.appendChild(a); li.appendChild(b);
    els.eng2Spec.appendChild(li);
  };
  if (!w || !w.antiLock) {
    const unrec = !w && kaUnrecorded(s);
    text(els.eng2State, KA.t(unrec ? 'engine.unrecordedState' : 'engine2.off'));
    spec(KA.t('engine2.spec.state'),
      unrec ? KA.t('engine2.spec.unrecorded')
             : (w ? KA.t('engine2.spec.notEnabled') : KA.t('engine2.spec.notRunning')));
    spec(KA.t('engine2.spec.effect'), KA.t('engine2.spec.resetOnly'));
    text(els.eng2Note, KA.t(unrec ? 'engine.unrecordedNote' : 'engine2.noteIdle'));
  } else {
    const next = (Number(w.lastPulseEpoch) || w.startedEpoch) + Number(w.antiLockInterval);
    text(els.eng2State, KA.t('engine2.every', { sec: w.antiLockInterval }));
    spec(KA.t('engine2.spec.method'), w.antiLockMethod);
    spec(KA.t('engine2.spec.sent'), KA.t('engine2.times', { n: w.pulses }));
    spec(KA.t('engine2.spec.last'), w.lastPulseEpoch ? fmtClock(w.lastPulseEpoch) : KA.t('engine2.spec.none'));
    spec(KA.t('engine2.spec.next'), '~' + hhmmss(next));
    spec(KA.t('engine2.spec.result'), w.lastPulseResult || '-', /not-restored|rejected|error/.test(w.lastPulseResult || '') ? 'bad' : '');
    spec(KA.t('engine2.spec.skips'), KA.t('engine2.times', { n: w.lockSkips }), w.lockSkips > 0 ? 'warn' : '');
    if (Number(w.lastLockEpoch) > 0) spec(KA.t('engine2.spec.lastLock'), fmtClock(w.lastLockEpoch), 'warn');
    text(els.eng2Note, KA.t(/not-restored|rejected/.test(w.lastPulseResult || '') ? 'engine2.noteFailed' : 'engine2.noteOk'));
  }
}

/* The classification rules below are deliberately free of DOM and dictionary lookups: a test
   drives them with plain counters. Both branches have lied in the field. The run readout
   printed a question mark for a worker that had not seen a single 506 - "nothing to attribute"
   is not the same answer as "unknown" - and the history verdict named the unplaceable sleeps
   while silently dropping the unprotected ones from the same sentence. */
function kaRealSleeps(ev) {
  // A 506 also fires when the display merely blanks, so without a 566 session event the
  // honest proxy for "did it sleep" is enters, not 0. Kernel-Power 42 deliberately stays out
  // of this number: on a classic-S3 box enters is 0 because 506 never fires there, and one
  // merged counter would make every ratio built on enters wrong on the hybrid machines.
  return ev.sessionKnown ? Number(ev.realSleeps || 0) : Number(ev.enters || 0);
}

function kaRunKind(ev) {
  // An observed bypass outranks "we could not see everything": hiding the one thing this
  // box did prove is how a verdict becomes comfort.
  if (Number(ev.bypasses || 0) + Number(ev.s3Bypasses || 0) > 0) return 'bypass';
  // A recorded sleep outranks it for the same reason. These two buckets are exactly the
  // non-bypassed real records (the backend identity ties them to realSleeps / s3Enters), so
  // a hybrid box that logged two Kernel-Power 42 entries while its capability read failed
  // used to print "cannot prove" and hide the sleeps it had in hand.
  if (Number(ev.unprotectedSleeps || 0) + Number(ev.spanUnknown || 0) +
      Number(ev.s3Unprotected || 0) + Number(ev.s3SpanUnknown || 0) > 0) return 'slept';
  if (ev.canSee === false) return 'unproven';
  return (kaRealSleeps(ev) > 0 || Number(ev.s3Enters || 0) > 0) ? 'slept' : 'clean';
}

function kaSleepsShown(ev) {
  if (ev.sessionKnown || Number(ev.enters || 0) === 0) { return String(Number(ev.realSleeps || 0)); }
  return '?';
}

function kaVerdictKind(ev) {
  // 'mixed' exists because two independent answers can be true in one window, and picking
  // only one of them is how a verdict becomes a claim rather than a reading.
  if (!ev || !ev.queriesOk) { return 'failed'; }
  const unprot = Number(ev.unprotectedSleeps || 0) + Number(ev.s3Unprotected || 0);
  const unknown = Number(ev.spanUnknown || 0) + Number(ev.s3SpanUnknown || 0);
  if (Number(ev.bypasses || 0) + Number(ev.s3Bypasses || 0) > 0) { return 'bypass'; }
  // Ordered before the blind check on purpose: a sleep these counters hold was recorded, and
  // "the capability read failed" does not unrecord it.
  if (unprot > 0) { return unknown > 0 ? 'mixed' : 'unprotected'; }
  if (unknown > 0) { return 'unknown'; }
  // Strict === false: every payload written before this field existed leaves it undefined,
  // and treating "the product has not told me yet" as "unprovable" would turn every panel
  // on earth amber.
  if (ev.canSee === false) { return 'unproven'; }
  if (kaRealSleeps(ev) > 0 || Number(ev.s3Enters || 0) > 0) { return 'unknown'; }
  if (Number(ev.enters || 0) > 0 && ev.sessionKnown) { return 'screenOnly'; }
  return 'clean';
}

/* e is a timeline event pre-annotated by the render layer: 'mark' is the marker class the
   axis would draw ('enter', 'enter--out', 'dim', 'exit', ...), 'clock' its HH:MM:SS string.
   Annotating outside keeps this function pure - "did it really sleep" needs the whole event
   list (reallySlept), which is not a property of one event. The filter is a lens: it selects
   markers, it never recomputes any aggregate. */
function kaEventMatches(e, f) {
  if (!e) { return false; }
  const chip = (f && f.chip) || 'all';
  const q = String((f && f.q) || '').trim().toLowerCase();
  // An entry is an entry whichever instrument wrote it. Restricting these three chips to
  // 'standbyEnter' left a classic-S3 machine with a "sleep" filter that hid every sleep.
  const isEnter = (e.kind === 'standbyEnter' || e.kind === 's3Enter');
  if (chip !== 'all') {
    if (chip === 'sleep') {
      if (!(isEnter && String(e.mark || '').indexOf('enter') === 0)) return false;
    } else if (chip === 'screenOff') {
      if (!(e.kind === 'standbyEnter' && e.mark === 'dim')) return false;
    } else if (chip === 'lid') {
      if (e.lid !== 'closed') return false;
    } else if (chip === 'bypass') {
      if (!(isEnter && Number(e.prot) === 1)) return false;
    } else if (chip === 'out') {
      if (!(isEnter && Number(e.prot) === 0)) return false;
    } else { return false; }
  }
  if (!q) { return true; }
  const hay = [e.kind, e.reason, e.lid, e.extMon, String(e.id == null ? '' : e.id), String(e.clock || '')].join(' ').toLowerCase();
  return hay.indexOf(q) !== -1;
}

/* Mirrors ka-worker.ps1: ES_SYSTEM_REQUIRED always; ES_DISPLAY_REQUIRED with keepDisplayOn;
   ES_AWAYMODE_REQUIRED with awayMode; ES_CONTINUOUS is ORed in on every apply. The battery
   floor does NOT shape these flags - it is a runtime step-down, so it is shown as behaviour
   text in the preview, never as a flag. */
function kaPreviewFlags(p) {
  const v = (x, d) => { const n = Number(x); return Number.isFinite(n) ? n : d; };
  const on = (x) => v(x, 0) === 1 || x === true;
  let f = 0x80000000 | 0x00000001;   // ES_CONTINUOUS | ES_SYSTEM_REQUIRED
  const names = ['ES_CONTINUOUS', 'ES_SYSTEM_REQUIRED'];
  if (on(p && p.keepDisplayOn)) { f |= 0x00000002; names.push('ES_DISPLAY_REQUIRED'); }
  if (on(p && p.awayMode)) { f |= 0x00000040; names.push('ES_AWAYMODE_REQUIRED'); }
  return { value: f, hex: '0x' + (f >>> 0).toString(16), names: names };
}

function renderState(s) {
  state.skew = Number(s.nowEpoch || 0) - Math.floor(Date.now() / 1000);
  ['mElapsed', 'mPulses', 'mIdle', 'mBattery', 'mEfficacy'].forEach((k) => readout(els[k], ''));
  const ev = s.evidence;
  const runKind = (ev && ev.queriesOk) ? kaRunKind(ev) : 'unreadable';
  const bad = s.running && runKind === 'bypass';
  cls(els.dais, 'dais reveal in' + (bad ? ' is-bad' : (s.running ? ' is-on' : ' is-idle')));
  cls(els.stateDot, 'dot ' + (s.running ? (bad ? 'dot--bad' : 'dot--on') : (state.stopping ? 'dot--off' : 'dot--idle')));

  if (s.running) {
    text(els.stateTitle, KA.t('state.running', { pid: s.worker.pid }));
    text(els.stateDetail, KA.t('state.detail', { disp: KA.t(s.worker.displayActive ? 'state.detailDisplayOn' : 'state.detailDisplayOff') }));
    text(els.mElapsed, fmtDuration(s.nowEpoch - s.worker.startedEpoch));
    text(els.mElapsedSub, KA.t('state.since', { at: fmtClock(s.worker.startedEpoch) }));
    text(els.mPulses, String(s.worker.pulses || 0));
    text(els.mPulsesSub, s.worker.antiLock ? KA.t('state.pulseSub', { sec: s.worker.antiLockInterval, method: s.worker.antiLockMethod }) : KA.t('state.pulseSubOff'));
    if (runKind !== 'unreadable') {
      const s3N = Number(ev.s3Enters || 0);
      const bypassN = Number(ev.bypasses || 0) + Number(ev.s3Bypasses || 0);
      if (runKind === 'bypass') {
        text(els.mEfficacy, KA.t('state.efficacyBypass', { n: bypassN }));
        readout(els.mEfficacy, 'bad');
      } else if (runKind === 'slept') {
        // On a classic-S3 box the 566 family is empty by construction, so "0 sleeps" there is
        // not a count - the 42 entries are the only records that machine leaves.
        const sleepsN = kaRealSleeps(ev);
        text(els.mEfficacy, KA.t('state.efficacySleeps', { n: sleepsN > 0 ? sleepsN : s3N }));
        readout(els.mEfficacy, 'warn');
      } else if (runKind === 'unproven') {
        text(els.mEfficacy, KA.t('state.efficacyUnproven'));
        readout(els.mEfficacy, 'warn');
      } else {
        text(els.mEfficacy, KA.t('state.efficacyOk'));
        readout(els.mEfficacy, 'good');
      }
      let sub = KA.t('state.efficacySub', {
        enters: (ev.enters || 0),
        sleeps: kaSleepsShown(ev),
        bypass: Number(ev.bypasses || 0),
        exits: (ev.exits || 0)
      });
      // The two instruments are never merged into one number, so the second family is named in
      // its own clause - and a hybrid box then shows both.
      if (s3N > 0 || Number(ev.s3Exits || 0) > 0) {
        sub += ' · ' + KA.t('state.efficacySubS3', { n: s3N, exits: Number(ev.s3Exits || 0) });
      }
      if (ev.canSee === false) {
        sub += ' · ' + KA.t('state.efficacySubBlind', { name: kaInstrumentLabel(ev.instrument) });
      }
      text(els.mEfficacySub, sub);
    } else {
      text(els.mEfficacy, KA.t('common.unreadable'));
      readout(els.mEfficacy, 'warn');
      text(els.mEfficacySub, (ev && ev.reason) ? ev.reason : KA.t('state.evFailed'));
    }
  } else if (kaUnrecorded(s)) {
    // A worker of this install is alive and state.json cannot be read. running is false
    // because nothing about its parameters can be proven - but "not running" would be a
    // lie, and the power request is most likely still held.
    const wp = (s.orphans && s.orphans[0]) ? s.orphans[0].pid : '?';
    text(els.stateTitle, KA.t('state.unrecorded', { pid: wp }));
    text(els.stateDetail, KA.t('state.detailUnrecorded'));
    text(els.mElapsed, '—'); text(els.mElapsedSub, KA.t('state.unrecordedSub'));
    text(els.mPulses, '—'); text(els.mPulsesSub, KA.t('state.unrecordedSub'));
    text(els.mEfficacy, '—'); readout(els.mEfficacy, 'warn');
    text(els.mEfficacySub, KA.t('state.unrecordedEfficacySub'));
  } else {
    text(els.stateTitle, KA.t('state.notRunning'));
    text(els.stateDetail, s.intent && s.intent.expired
      ? KA.t('state.detailExpired')
      : KA.t('state.detailIdle'));
    text(els.mElapsed, '—'); text(els.mElapsedSub, KA.t('state.elapsedNone'));
    text(els.mPulses, '—'); text(els.mPulsesSub, KA.t('state.pulseNone'));
    text(els.mEfficacy, '—'); readout(els.mEfficacy, '');
    text(els.mEfficacySub, KA.t('state.efficacySubIdle'));
  }

  const idle = Number(s.idleSec);
  text(els.mIdle, Number.isFinite(idle) && idle >= 0 ? fmtDuration(idle) : KA.t('common.unreadable'));
  readout(els.mIdle, (!Number.isFinite(idle) || idle < 0) ? 'warn' : (idle > 300 ? 'warn' : ''));
  text(els.mIdleSub, KA.t('state.idleSub'));

  const b = s.battery || {}, floor = (s.config || {}).batteryFloorPercent;
  const bpct = Number(b.percent) >= 0 ? Number(b.percent) + '%' : '?';
  if (!b.known) {
    text(els.mBattery, KA.t('common.unreadable'));
    readout(els.mBattery, 'warn');
    text(els.mBatterySub, KA.t('state.battUnknown'));
  } else if (!b.hasBattery) {
    text(els.mBattery, KA.t('state.battNone'));
    readout(els.mBattery, b.acOnline ? 'good' : 'warn');
    text(els.mBatterySub, KA.t(b.acOnline ? 'state.battNoneSub' : 'state.battNoneOdd'));
  } else {
    const onBattLow = !b.acOnline && Number(b.percent) >= 0 && Number.isFinite(floor) && Number(b.percent) <= floor;
    text(els.mBattery, KA.t(b.acOnline ? 'state.battAc' : 'state.battDc', { p: bpct }));
    readout(els.mBattery, b.acOnline ? 'good' : (onBattLow ? 'bad' : 'warn'));
    text(els.mBatterySub, b.acOnline ? KA.t('state.battAcOk')
      : KA.t(onBattLow ? 'state.battDcLow' : 'state.battDcFloor', { floor: floor }));
  }

  text(els.version, 'v' + (s.version || '—'));
  renderGauge(s);
  renderEngines(s);
  renderPills(s);
  renderAlerts(s);
  drawTrace();

  // /api/stop finds workers by process, so it works with no state record at all. Gating
  // this on s.running alone would announce a live worker and grey out its only stop button.
  els.btnStop.disabled = !s.running && !kaUnrecorded(s);
  document.title = KA.t(s.running ? 'docTitle.running' : 'docTitle.idle', { name: KA.t('page.name') });

  text(els.footInfo, KA.t('foot.info', {
    root: (s.root || ''), session: ((s.session || {}).state || '—'),
    priv: KA.t(s.elevated ? 'foot.elevated' : 'foot.user'),
    clock: (s.nowEpoch ? fmtClock(s.nowEpoch) : '')
  }));
}

function syncControls(cfg) {
  // The poll re-renders every 2s. Overwriting the form then would silently undo any
  // edit not yet followed by 启动保护, so once a control is touched it keeps its value
  // until an explicit 刷新 / 存为默认.
  if (!cfg || state.controlsDirty) return;
  els.optDisplay.checked  = !!cfg.keepDisplayOn;
  els.optAntiLock.checked = !!cfg.antiLock;
  els.optAway.checked     = !!cfg.awayMode;
  els.optBattOff.checked  = cfg.batteryAllowDisplayOff !== false;
  els.optInterval.value   = cfg.antiLockIntervalSec;
  els.optReassert.value   = cfg.reassertSec;
  els.optFloor.value      = cfg.batteryFloorPercent;
  selectSeg(els.methodSegs, 'method', cfg.antiLockMethod === 'mouse' ? 'mouse' : 'key');
  els.lockRow.classList.toggle('is-dim', !cfg.antiLock);
}

function syncPresets(s) {
  // Duration lives in intent.json, not config.json — without this the preset row keeps
  // its markup default and contradicts the countdown ring while protection is running.
  if (state.controlsDirty) return;
  const it = s.intent || {};
  if (!s.running && !(it.desired === 'awake' && !it.expired)) return;
  const min = Math.max(0, parseInt(it.minutes, 10) || 0);
  if (min === 0) { selectSeg(els.presets, 'min', '0'); els.customMin.value = ''; return; }
  const key = String(min);
  if (els.presets.querySelector('.seg[data-min="' + key + '"]')) {
    selectSeg(els.presets, 'min', key);
    els.customMin.value = '';
    return;
  }
  els.presets.querySelectorAll('.seg').forEach((b) => b.classList.remove('is-on'));
  els.customMin.value = key;
}

function selectSeg(container, key, value) {
  container.querySelectorAll('.seg').forEach((b) => b.classList.toggle('is-on', b.dataset[key] === value));
}

/* -------------------------------------------------------- heartbeat trace */
let cv = null, ctx2d = null, cvW = -1;
function sizeCanvas() {
  if (!cv) return false;
  const cssW = cv.clientWidth || 0;
  if (!cssW || cssW === cvW) return false;      // nothing to size against yet
  const dpr = Math.min(2.5, window.devicePixelRatio || 1);
  const h = 120;
  cv.width = Math.round(cssW * dpr);
  cv.height = Math.round(h * dpr);
  ctx2d.setTransform(dpr, 0, 0, dpr, 0, 0);
  cvW = cssW;
  return true;
}

function spike(x, yBase, amp, w) {
  ctx2d.beginPath();
  ctx2d.moveTo(x - w, yBase);
  ctx2d.lineTo(x - w * 0.52, yBase - amp * 0.10);
  ctx2d.lineTo(x - w * 0.26, yBase + amp * 0.12);
  ctx2d.lineTo(x, yBase - amp);
  ctx2d.lineTo(x + w * 0.22, yBase + amp * 0.30);
  ctx2d.lineTo(x + w * 0.48, yBase - amp * 0.20);
  ctx2d.lineTo(x + w, yBase);
  ctx2d.stroke();
}

function drawTrace() {
  if (!ctx2d) return;
  sizeCanvas();
  const s = state.s, w = s && s.running ? s.worker : null;
  const live = !!(w && w.antiLock);
  cv.parentNode.classList.toggle('is-live', live);
  if (!live) {
    text(els.traceIdle, KA.t(w ? 'trace.idleNoEngine' : (kaUnrecorded(s) ? 'trace.unrecorded' : 'trace.idle')));
  }

  const W = cvW || 600, Hh = 120, pad = 10;
  const interval = live ? Math.max(10, Number(w.antiLockInterval) || 240) : 240;
  const elapsed = w ? Math.max(0, nowEpoch() - Number(w.startedEpoch)) : 0;
  let span = Math.max(interval * 3.2, 240);
  if (w && elapsed > 0) span = Math.max(span * 0.6, Math.min(elapsed * 1.18, span));
  span = Math.min(span, 4 * 3600);

  const t = Date.now() / 1000;
  const now = nowEpoch() + (t - Math.floor(t));          // sub-second so the sweep is smooth
  const x = (e) => pad + ((e - (now - span)) / span) * (W - pad * 2);
  const yBase = Hh * 0.74;

  ctx2d.clearRect(0, 0, W, Hh);
  ctx2d.lineWidth = 1;
  ctx2d.strokeStyle = 'rgba(150,180,215,.16)';
  ctx2d.beginPath(); ctx2d.moveTo(0, yBase + .5); ctx2d.lineTo(W, yBase + .5); ctx2d.stroke();

  if (!live) {
    ctx2d.strokeStyle = 'rgba(93,110,134,.55)';
    ctx2d.lineWidth = 1.4;
    ctx2d.beginPath();
    for (let px = pad; px <= W - pad; px += 3) {
      const yy = yBase - Math.sin((px / W) * 6.2 + t * 0.6) * 1.4;
      px === pad ? ctx2d.moveTo(px, yy) : ctx2d.lineTo(px, yy);
    }
    ctx2d.stroke();
    axisLabels(now, span, false, 0, interval);
    return;
  }

  const first = Number(w.lastPulseEpoch) || Number(w.startedEpoch);
  const last = Math.min(first, now);
  const k0 = Math.ceil((now - span - last) / interval);
  const k1 = Math.floor((now - last) / interval);
  const shown = Math.max(0, k1 - k0 + 1);

  for (let k = k0; k <= k1; k++) {
    const e = last + k * interval;
    if (w.startedEpoch && e < Number(w.startedEpoch)) continue;
    const px = x(e);
    if (px < pad - 20 || px > W - pad + 20) continue;
    const age = Math.min(1, (now - e) / span);
    const a = 1 - age * 0.8;
    ctx2d.strokeStyle = 'rgba(62,224,143,' + (a * 0.92).toFixed(3) + ')';
    ctx2d.lineWidth = 1.7;
    ctx2d.shadowColor = 'rgba(62,224,143,' + (a * 0.6).toFixed(3) + ')';
    ctx2d.shadowBlur = 8 * a;
    spike(px, yBase, Hh * 0.46, Math.max(13, interval * (W - pad * 2) / span * 0.055));
  }
  ctx2d.shadowBlur = 0;

  const next = first + (Math.floor((now - first) / interval) + 1) * interval;
  const nx = x(next);
  if (nx < W - pad) {
    ctx2d.strokeStyle = 'rgba(255,154,60,.5)';
    ctx2d.setLineDash([3, 4]); ctx2d.lineWidth = 1;
    ctx2d.beginPath(); ctx2d.moveTo(nx, 8); ctx2d.lineTo(nx, Hh - 8); ctx2d.stroke();
    ctx2d.setLineDash([]);
    text(els.traceMid, KA.t('trace.next', { at: hhmmss(next), left: Math.max(0, Math.ceil(next - now)) }));
  } else {
    text(els.traceMid, KA.t('trace.window', { span: fmtDuration(span), sec: interval }));
  }

  // the "now" edge: a traveling pip on the baseline, so the panel visibly breathes
  const ex = W - pad;
  ctx2d.fillStyle = 'rgba(255,154,60,.9)';
  ctx2d.beginPath();
  ctx2d.arc(ex, yBase - Math.abs(Math.sin(t * 1.8)) * 3, 2.6 + Math.sin(t * 3.6) * 0.7, 0, 6.2832);
  ctx2d.fill();
  ctx2d.strokeStyle = 'rgba(255,154,60,.18)';
  ctx2d.beginPath(); ctx2d.moveTo(ex, 4); ctx2d.lineTo(ex, Hh - 4); ctx2d.stroke();

  axisLabels(now, span, true, shown, interval);
}

function axisLabels(now, span, live, shown, interval) {
  text(els.traceStart, hhmmss(now - span));
  if (!live) text(els.traceMid, KA.t('trace.silent'));
  text(els.traceEnd, KA.t('trace.now', { at: hhmmss(now) }));
  if (live) {
    els.traceCanvas.setAttribute('aria-label',
      KA.t('trace.aria', { sec: interval, span: fmtDuration(span), n: (shown || 0) }));
  }
}

function traceLoop() {
  if (!state.stopping) drawTrace();
  requestAnimationFrame(() => setTimeout(traceLoop, 90));
}

/* ------------------------------------------------------------------ report */
function renderReport(r) {
  els.planTable.textContent = '';
  const p = r.plan || {};
  const row = (k, v, tone) => {
    const tr = document.createElement('div'); tr.className = 'tr';
    const a = document.createElement('div'); a.className = 'k'; a.textContent = k;
    const b = document.createElement('div'); b.className = 'v' + (tone ? ' ' + tone : ''); b.textContent = v;
    tr.appendChild(a); tr.appendChild(b);
    els.planTable.appendChild(tr);
  };
  const secs = (v) => v == null ? KA.t('common.unreadable') : (Number(v) === 0 ? KA.t('common.never') : fmtDuration(v));
  const yesNo = (v) => KA.t(v ? 'common.yes' : 'common.no');
  const sup = (v) => KA.t(v ? 'common.supported' : 'common.unsupported');
  const s = r.sleepStates || {};
  row(KA.t('report.sleepState'), KA.t('report.sleep', { ms: yesNo(s.modernStandby), s3: sup(s.s3), hib: sup(s.hibernate) }),
    s.modernStandby ? 'warn' : 'ok');
  row(KA.t('report.planSleep'), KA.t('report.acDc', { ac: secs(p.sleepAcSec), dc: secs(p.sleepDcSec) }));
  row(KA.t('report.planVideo'), KA.t('report.acDc', { ac: secs(p.videoAcSec), dc: secs(p.videoDcSec) }));
  row(KA.t('report.unattended'), secs(p.unattendedAcSec));
  row(KA.t('report.lid'), p.lidAc == null ? KA.t('report.lidHidden')
    : KA.t('report.lidVals', { ac: p.lidAc, dc: (p.lidDc == null ? '?' : p.lidDc) }),
    p.lidAc == null ? 'warn' : (Number(p.lidAc) === 0 ? 'ok' : 'bad'));
  row(KA.t('report.consoleLock'), p.consoleLockAc == null ? KA.t('report.consoleLockHidden') : KA.t(Number(p.consoleLockAc) === 0 ? 'report.lockNo' : 'report.lockYes'));
  row(KA.t('report.gpo'), p.inactivityPolicySec ? KA.t('report.gpoIdle', { dur: fmtDuration(p.inactivityPolicySec) }) : KA.t('report.gpoNone'));
  row(KA.t('report.screensaver'), p.screensaver ? (p.screensaver.exe + ' · ' + secs(p.screensaver.timeoutSec) + KA.t(p.screensaver.secure ? 'report.ssSecure' : 'report.ssOpen')) : KA.t('common.none'));
  row(KA.t('report.eng1'), r.powerTightestSec ? KA.t('report.eng1Tight', { dur: fmtDuration(r.powerTightestSec) }) : KA.t('report.eng1Never'), 'ok');
  row(KA.t('report.eng2'), r.lockTightestSec ? KA.t('report.eng2Tight', { dur: fmtDuration(r.lockTightestSec) }) : KA.t('report.eng2None'));
  row(KA.t('report.reco'), KA.t('report.recoVal', { sec: r.recommendedIntervalSec, why: prose(r.recommendedWhy) }), 'ok');

  els.machineCard.textContent = '';
  const mrow = (k, v) => {
    const tr = document.createElement('div'); tr.className = 'tr';
    const a = document.createElement('div'); a.className = 'k'; a.textContent = k;
    const b = document.createElement('div'); b.className = 'v'; b.textContent = v;
    tr.appendChild(a); tr.appendChild(b);
    els.machineCard.appendChild(tr);
  };
  mrow(KA.t('machine.os'), r.os || KA.t('common.unknown'));
  mrow('PowerShell', r.psVersion || KA.t('common.unknown'));
  const mb = r.battery || {};
  mrow(KA.t('machine.battery'), !mb.known ? KA.t('machine.unknown')
    : (mb.hasBattery ? KA.t('machine.laptop') : KA.t('machine.desktop')));
  mrow(KA.t('machine.checkedAt'), r.generatedAt || '—');
  mrow(KA.t('machine.store'), KA.t('machine.storeNote'));

  els.riskList.textContent = '';
  (r.risk || []).forEach((x) => {
    const div = document.createElement('div');
    div.className = 'risk';
    div.textContent = prose(x);
    els.riskList.appendChild(div);
  });
  if (!(r.risk || []).length) {
    const div = document.createElement('div');
    div.className = 'risk';
    div.textContent = KA.t('report.noRisk');
    els.riskList.appendChild(div);
  }

  els.lidNow.textContent = '';
  const lid = r.lid;
  if (lid) {
    const title = document.createElement('div');
    title.className = 'lidnow__title';
    title.textContent = KA.t('lid.title');
    els.lidNow.appendChild(title);
    const line = (txt, tone) => {
      const div = document.createElement('div');
      div.className = 'lidnow__line' + (tone ? ' ' + tone : '');
      div.textContent = txt;
      els.lidNow.appendChild(div);
    };
    if (lid.lidPresent === false) {
      // One line and no more: the forecast sends nothing else for this case, and the values
      // it would have shown belong to a control that cannot be triggered here.
      line(KA.t('lid.nolid'));
    } else {
      if (!lid.lidKnown) line(KA.t('lid.presenceUnknown'), 'bad');
      if (!lid.readable) {
        line(KA.t('lid.hidden'));
      } else {
        const onAc = !!lid.acOnline;
        const pct = Number(lid.batteryPercent) >= 0 ? Number(lid.batteryPercent) + '%' : '?';
        const tier = KA.t(onAc ? 'lid.tierAc' : 'lid.tierDc', { pct: pct });
        const idx = Number(onAc ? lid.actionAc : lid.actionDc);
        const act = (idx >= 0 && idx <= 3) ? KA.t('lid.act.' + idx) : KA.t('lid.unknown', { v: idx });
        line(KA.t('lid.now', { tier: tier, action: act }), idx === 0 ? 'ok' : 'bad');
        line(KA.t('lid.verify.' + (lid.verified || 'unknown'), {
          apply: lid.lastApplyEpoch ? fmtClock(lid.lastApplyEpoch) : '',
          when: lid.lastClosed ? fmtClock(lid.lastClosed.epoch) : ''
        }), lid.verified === 'slept' ? 'bad' : (lid.verified === 'no-sleep' ? 'ok' : ''));
      }
      if (lid.lastLidStandby && lid.lastLidStandby.epoch) {
        line(KA.t('lid.last', { when: fmtClock(lid.lastLidStandby.epoch) }), 'bad');
      }
      const note = document.createElement('div');
      note.className = 'lidnow__note';
      note.textContent = KA.t('lid.note');
      els.lidNow.appendChild(note);
    }
  }

  const rec = Number(r.recommendedIntervalSec), cur = Number(els.optInterval.value);
  if (Number.isFinite(rec) && Number.isFinite(cur) && cur > rec) {
    text(els.intervalHint, KA.t('hint.intervalBig', { tight: fmtDuration(rec * 2), cur: cur, rec: rec }));
    els.intervalHint.style.color = 'var(--warn)';
  } else {
    text(els.intervalHint, rec ? KA.t('hint.intervalOk', { rec: rec }) : '');
    els.intervalHint.style.color = '';
  }
}

/* --------------------------------------------------------------- evidence */
function clearAxis() {
  const parent = els.timeline.parentNode;
  Array.from(parent.querySelectorAll('.tl-axis')).forEach((n) => n.remove());
}

function renderEvidence(data) {
  // Clear here, not at the call site: this runs from the fetch path AND from a language
  // change, and an axis left behind from the previous paint still shows the old labels.
  clearAxis();
  const ev = data.evidence || {};
  const hours = data.hours || state.evHours;
  const now = nowEpoch();
  const start = now - hours * 3600;
  const span = Math.max(1, now - start);
  const pct = (e) => Math.min(100, Math.max(0, ((Number(e) - start) / span) * 100));

  els.timeline.textContent = '';
  // Every protected span, not just the live one: a red dot sitting in a gap between two
  // bars is the whole argument that the platform did NOT ignore a request there.
  const spans = ev.spans || [];
  spans.forEach((sp) => {
    const from = pct(Math.max(start, sp.from));
    const to = pct(Math.min(now, sp.to));
    if (to - from <= 0) return;
    const bar = document.createElement('div');
    bar.className = 'tl-run';
    bar.style.left = from + '%';
    bar.style.width = (to - from) + '%';
    bar.title = KA.t('ev.spanTip', { from: fmtClock(sp.from), to: fmtClock(sp.to) });
    els.timeline.appendChild(bar);
  });
  const events = ev.events || [];
  // A 506 means "a low-power session began", which on this platform includes a plain
  // display-off. Only the 566 session records say whether the machine actually left, so
  // a red dot now means "entered, and reached the sleep session within two minutes" - the
  // same correlation the backend counts as screenOffToSleep. The session records are not
  // drawn: they land seconds from their own 506 and would double up on the axis.
  const sleeps = events.filter((e) => e.kind === 'session' && Number(e.to) === 2);
  const reallySlept = (t) => sleeps.some((s) => s.epoch - t >= 0 && s.epoch - t <= 120);
  // Annotate first, then filter: kaEventMatches needs the marker class, which is a fact
  // about the whole event list (reallySlept), not about one event.
  const markers = events.filter((e) => e.kind !== 'session').map((e) => {
    let mark = 'exit';
    if (e.kind === 'standbyEnter') {
      if (!reallySlept(e.epoch)) mark = 'dim';
      else if (Number(e.prot) === 1) mark = 'enter';
      else if (Number(e.prot) === 0) mark = 'enter enter--out';
      else mark = 'enter enter--unknown';
    } else if (e.kind === 's3Enter') {
      // A 42 already IS an entry into a sleep state: applying the 566 pairing above to it
      // would paint every sleep of a classic-S3 box as a display that merely blanked,
      // because that box writes no 566 records at all.
      if (Number(e.prot) === 1) mark = 'enter enter--s3';
      else if (Number(e.prot) === 0) mark = 'enter enter--out enter--s3';
      else mark = 'enter enter--unknown enter--s3';
    }
    return { kind: e.kind, epoch: e.epoch, id: e.id, reason: e.reason, lid: e.lid, extMon: e.extMon,
             from: e.from, to: e.to, prot: e.prot, mark: mark, clock: hhmmss(e.epoch) };
  });
  const filterOn = state.evFilter.chip !== 'all' || !!String(state.evFilter.q || '').trim();
  const shown = markers.filter((e) => kaEventMatches(e, state.evFilter));
  if (els.evfHits) {
    text(els.evfHits, filterOn ? KA.t('evf.hits', { hit: shown.length, total: markers.length }) : '');
    if (els.evfLens) els.evfLens.hidden = !filterOn;
  }
  shown.forEach((e) => {
    const m = document.createElement('div');
    m.className = 'tl-mark ' + e.mark;
    m.style.left = pct(e.epoch) + '%';
    m.title = fmtClock(e.epoch) + '  ' + e.kind + (e.reason ? ' reason=' + e.reason : '')
      + (e.lid ? ' lid=' + e.lid : '') + (e.extMon ? ' extMon=' + e.extMon : '')
      + (e.to != null ? ' session=' + e.from + '->' + e.to : '')
      + (e.mark.indexOf('enter') === 0 ? ' prot=' + e.prot : '')
      + ' (id=' + e.id + ')';   // backend tokens, not sentences
    els.timeline.appendChild(m);
  });
  if (!markers.length && !spans.length) {
    const empty = document.createElement('div');
    empty.className = 'tl-empty';
    empty.textContent = KA.t('ev.empty');
    els.timeline.appendChild(empty);
  } else if (!shown.length && filterOn) {
    const empty = document.createElement('div');
    empty.className = 'tl-empty';
    empty.textContent = KA.t('evf.empty');
    els.timeline.appendChild(empty);
  }

  const axis = document.createElement('div');
  axis.className = 'tl-axis';
  [hours, hours * 3 / 4, hours / 2, hours / 4, 0].forEach((h) => {
    const sp = document.createElement('span');
    sp.textContent = h === 0 ? KA.t('common.now') : ('-' + Math.round(h) + 'h');
    axis.appendChild(sp);
  });
  els.timeline.parentNode.insertBefore(axis, els.timeline.nextSibling);

  const bypasses = Number(ev.bypasses || 0);
  const unprot = Number(ev.unprotectedSleeps || 0);
  const unplaceable = Number(ev.spanUnknown || 0);
  const s3N = Number(ev.s3Enters || 0);
  // The verdict sentences speak for the whole window, so they add the two record families;
  // the counts row below keeps them apart, because on a hybrid machine the same episode can
  // be logged twice and only the split is auditable.
  const bypassAll = bypasses + Number(ev.s3Bypasses || 0);
  const unprotAll = unprot + Number(ev.s3Unprotected || 0);
  const unplaceAll = unplaceable + Number(ev.s3SpanUnknown || 0);
  const kind = kaVerdictKind(ev);
  const warnKinds = { failed: 1, unprotected: 1, mixed: 1, unknown: 1, unproven: 1 };
  els.evSummary.className = 'verdict ' + (kind === 'bypass' ? 'verdict--bad' : (warnKinds[kind] ? 'verdict--warn' : ''));
  let verdict;
  if (kind === 'failed') {
    verdict = KA.t('ev.failed', { reason: (ev.reason || KA.t('ev.reasonUnknown')) });
  } else if (kind === 'bypass') {
    verdict = KA.t('ev.hit', { hours: hours, enters: bypassAll });
  } else if (kind === 'unprotected' || kind === 'mixed') {
    // It slept. Not while we were holding anything - which is a fact about the window, not
    // an excuse invented after the fact. The unplaceable remainder is named in the same
    // breath: dropping it would quietly turn "3 outside, 1 unknown" into "3 outside".
    verdict = KA.t('ev.unprotected', { hours: hours, n: unprotAll })
      + (kind === 'mixed' ? KA.t('ev.plusUnknown', { n: unplaceAll }) : '');
  } else if (kind === 'unknown') {
    // Two facts share this kind. The unplaceable count is the first; when it is zero the kind
    // can only have come from the enters proxy, i.e. a machine that writes 506 but no 566. One
    // sentence for both printed "0 real sleeps cannot be placed" under a tile reading "5 sleeps".
    verdict = unplaceAll > 0
      ? KA.t('ev.spanUnknown', { hours: hours, n: unplaceAll })
      : KA.t('ev.enterOnly', { hours: hours, n: Number(ev.enters || 0) });
  } else if (kind === 'unproven') {
    // The one answer that used to be silently folded into "0 sleeps, working": this machine
    // declares a sleep state that leaves no record the query can read.
    verdict = KA.t('ev.unproven', { hours: hours });
  } else if (kind === 'screenOnly') {
    // The distinction this whole block exists for: the screen went dark, the machine stayed.
    verdict = KA.t('ev.screenOnly', { hours: hours, n: ev.enters });
  } else {
    verdict = KA.t('ev.clean', { hours: hours })
      + (events.length ? KA.t('ev.cleanSome', { n: events.length }) : KA.t('ev.cleanNone'));
  }
  text(els.evSummary, verdict);
  let counts = KA.t('ev.counts', { enters: (ev.enters || 0), exits: (ev.exits || 0), events: events.length, result: (ev.queriesOk ? 'OK' : 'FAIL') });
  if (ev.sessionKnown) {
    counts += ' · ' + KA.t('ev.sessions', { screenOff: (ev.screenOffs || 0), sleeps: (ev.realSleeps || 0) });
    if (ev.screenOffToSleep) {
      counts += ' · ' + KA.t('ev.offToSleep', { n: ev.screenOffToSleep, secs: (ev.lastScreenOffToSleepSecs || 0) });
    }
  }
  if (s3N > 0 || Number(ev.s3Exits || 0) > 0) {
    counts += ' · ' + KA.t('ev.s3Counts', {
      n: s3N, exits: (ev.s3Exits || 0), bypass: (ev.s3Bypasses || 0),
      out: (ev.s3Unprotected || 0), unknown: (ev.s3SpanUnknown || 0)
    });
  }
  if (ev.spansKnown) {
    counts += ' · ' + KA.t('ev.spanCounts', { spans: spans.length, bypass: bypasses, out: unprot, unknown: unplaceable });
    if (ev.spansCoveredFrom && ev.spansCoveredFrom > start) {
      counts += ' · ' + KA.t('ev.spansPartial', { time: fmtClock(ev.spansCoveredFrom) });
    }
  } else {
    counts += ' · ' + KA.t('ev.spansNone');
  }
  if (ev.truncated) counts += ' · ' + KA.t('ev.truncated', { n: (ev.max || 1000) });
  if (ev.instrument) counts += ' · ' + KA.t('ev.readout', { name: kaInstrumentLabel(ev.instrument) });
  const reasons = ev.reasons || {};
  const reasonKeys = Object.keys(reasons);
  if (reasonKeys.length) {
    const ordered = reasonKeys.slice().sort((a, b) => (reasons[b] - reasons[a]) || (a < b ? -1 : a > b ? 1 : 0));
    counts += ' · ' + ordered
      .map((k) => (KA.has('ev.reason.' + k) ? KA.t('ev.reason.' + k) : k) + ' x' + reasons[k])
      .join(' · ');
  }
  text(els.evCounts, counts);
  text(els.evNote, KA.t('ev.note'));
}

/* --------------------------------------------------------------------- log */
function renderLog(lines) {
  els.log.textContent = '';
  if (!lines || !lines.length) { text(els.log, KA.t('log.empty')); return; }
  const frag = document.createDocumentFragment();
  lines.forEach((line) => {
    const span = document.createElement('span');
    if (/FAIL|EXIT|STOPPED|REJECT|异常|失败/.test(line)) span.className = 'l-bad';
    else if (/WARN|DOWNGRADE|SKIP|RESUMED/.test(line)) span.className = 'l-warn';
    else if (/STARTED|RESTORE|HEARTBEAT|OK|installed/.test(line)) span.className = 'l-hit';
    span.textContent = line;
    frag.appendChild(span);
  });
  els.log.appendChild(frag);
  els.log.scrollTop = els.log.scrollHeight;
}

/* ---------------------------------------------------------------- loadings */
async function loadState() {
  let s;
  try {
    s = await api('/api/state', { headers: H });
  } catch (e) {
    renderConn(false, state.stopping);
    text(els.stateTitle, KA.t('state.noPanel'));
    text(els.stateDetail, e.message);
    return false;
  }
  state.s = s;
  renderConn(true);
  try {
    renderState(s);
    renderGuard(s);
    syncControls(s.config);
    syncPresets(s);
  } catch (e) {
    // Never let a UI bug impersonate a connectivity problem: the panel answered fine.
    const msg = KA.t('err.render', { msg: e.message });
    text(els.stateDetail, msg);
    if (state.renderErr !== msg) { state.renderErr = msg; toast(msg, 'err'); }
  }
  return true;
}

function kaGuardAction(g) {
  // A registered-but-Disabled watchdog needs re-registering, not uninstalling. Two states
  // here would have put "Uninstall" next to a verdict that said "Installed".
  return (g && g.installed && g.enabled !== false) ? 'uninstall' : 'install';
}

function renderGuard(s) {
  const g = s.guard;
  const op = kaGuardAction(g);
  const off = !!(g && g.installed && g.enabled === false);
  text(els.btnGuard, KA.t(op === 'uninstall' ? 'btn.guard.uninstall' : (off ? 'btn.guard.reinstall' : 'btn.guard.install')));
  els.btnGuard.dataset.op = op;
  els.guardText.className = 'verdict ' + (g && g.installed && g.enabled !== false ? '' : 'verdict--warn');
  text(els.guardText, g
    ? KA.t(g.installed ? (off ? 'guard.disabled' : 'guard.installed') : 'guard.missing',
           { names: ((g.disabled || []).join(', ')) })
    : KA.t('guard.unknown'));
  renderGuardTasks(g);
}

function renderGuardTasks(g) {
  els.guardTable.textContent = '';
  const tasks = (g && g.tasks) || [];
  const head = document.createElement('div');
  head.className = 'tr head';
  [KA.t('guard.headTask'), KA.t('guard.headState')].forEach((label) => {
    const d = document.createElement('div'); d.textContent = label; head.appendChild(d);
  });
  els.guardTable.appendChild(head);
  if (!tasks.length) {
    const tr = document.createElement('div'); tr.className = 'tr';
    const a = document.createElement('div'); a.className = 'k'; a.textContent = KA.t('guard.tasks');
    const b = document.createElement('div'); b.className = 'v warn'; b.textContent = KA.t('guard.notInstalled');
    tr.appendChild(a); tr.appendChild(b);
    els.guardTable.appendChild(tr);
    return;
  }
  tasks.forEach((t) => {
    const tr = document.createElement('div'); tr.className = 'tr';
    const a = document.createElement('div'); a.className = 'k'; a.textContent = t.name;
    const b = document.createElement('div');
    b.className = 'v ' + (t.state === 'Ready' ? 'ok' : 'warn');
    b.textContent = KA.t('guard.row', { state: t.state, last: t.lastRun, next: t.nextRun, result: t.lastResult });
    tr.appendChild(a); tr.appendChild(b);
    els.guardTable.appendChild(tr);
  });
}

async function loadReport() {
  try { state.report = await api('/api/report', { headers: H }); renderReport(state.report); }
  catch (e) { text(els.checkHint, KA.t('report.fail', { msg: e.message })); els.checkHint.style.color = 'var(--stop)'; }
}

async function loadEvidence() {
  clearAxis();
  try { state.evData = await api('/api/evidence?hours=' + state.evHours, { headers: H }); renderEvidence(state.evData); }
  catch (e) {
    els.evSummary.className = 'verdict verdict--bad';
    text(els.evSummary, KA.t('ev.fail', { msg: e.message }));
  }
}

async function loadLog() {
  try {
    const d = await api('/api/log?tail=150', { headers: H });
    text(els.logPath, d.path || '');
    state.logLines = d.lines || [];
    renderLog(state.logLines);
  } catch (e) { /* the log is context, never a reason to withhold status */ }
}

/* ------------------------------------------------- preview before starting */
function renderPreview() {
  const body = collectPayload();
  const mins = Number(body.minutes || 0);
  text(els.pvDur, mins
    ? fmtDuration(mins * 60) + ' · ' + KA.t('preview.ends', { at: fmtClock(nowEpoch() + mins * 60) })
    : KA.t('preview.unlimited'));

  const fl = kaPreviewFlags(body);
  els.pvFlags.textContent = '';
  const hex = document.createElement('span');
  hex.className = 'flag flag--hex';
  hex.textContent = 'ES_CONTINUOUS | ' + fl.hex;
  els.pvFlags.appendChild(hex);
  const flagKey = {
    'ES_CONTINUOUS': 'preview.flag.continuous',
    'ES_SYSTEM_REQUIRED': 'preview.flag.system',
    'ES_DISPLAY_REQUIRED': 'preview.flag.display',
    'ES_AWAYMODE_REQUIRED': 'preview.flag.away'
  };
  fl.names.forEach((n) => {
    const row = document.createElement('span');
    row.className = 'flag';
    const code = document.createElement('code');
    code.textContent = n;
    row.appendChild(code);
    if (flagKey[n]) {
      const desc = document.createElement('span');
      desc.className = 'flag__desc';
      desc.textContent = KA.t(flagKey[n]);
      row.appendChild(desc);
    }
    els.pvFlags.appendChild(row);
  });

  text(els.pvHb, body.antiLock
    ? KA.t('preview.hbOn', { sec: body.antiLockIntervalSec, method: body.antiLockMethod })
    : KA.t('preview.hbOff'));
  text(els.pvAway, body.awayMode ? KA.t('preview.awayOn') : KA.t('preview.awayOff'));
  text(els.pvBattery, body.batteryAllowDisplayOff
    ? KA.t('preview.battAllow', { floor: body.batteryFloorPercent })
    : KA.t('preview.battKeep', { floor: body.batteryFloorPercent }));

  els.pvRisks.textContent = '';
  const risks = (state.report && state.report.risk) || [];
  if (!risks.length) {
    const div = document.createElement('div');
    div.className = 'risk';
    div.textContent = KA.t('preview.noRisks');
    els.pvRisks.appendChild(div);
  }
  risks.forEach((x) => {
    const div = document.createElement('div');
    div.className = 'risk';
    div.textContent = prose(x);
    els.pvRisks.appendChild(div);
  });
}

function openPreview() {
  renderPreview();
  els.preview.hidden = false;
  state.previewOpen = true;
  els.preview.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  els.pvConfirm.focus();
}

function closePreview() {
  els.preview.hidden = true;
  state.previewOpen = false;
}

els.pvConfirm.addEventListener('click', () => { closePreview(); doStart(); });
els.pvCancel.addEventListener('click', closePreview);

/* ------------------------------------------------------------------ actions */
function collectPayload() {
  const on = els.methodSegs.querySelector('.seg.is-on');
  const n = (el, dflt) => { const v = parseInt(el.value, 10); return Number.isFinite(v) ? v : dflt; };
  return {
    minutes: selectedMinutes(),
    keepDisplayOn: els.optDisplay.checked,
    antiLock: els.optAntiLock.checked,
    antiLockMethod: on ? on.dataset.method : 'key',
    antiLockIntervalSec: Math.min(3600, Math.max(10, n(els.optInterval, 240))),
    reassertSec: Math.min(3600, Math.max(15, n(els.optReassert, 60))),
    awayMode: els.optAway.checked,
    batteryAllowDisplayOff: els.optBattOff.checked,
    batteryFloorPercent: Math.min(90, Math.max(0, n(els.optFloor, 20)))
  };
}

async function doStart() {
  const body = collectPayload();
  setBusy(true);
  try {
    const r = await api('/api/start', { method: 'POST', headers: HJ, body: JSON.stringify(body) });
    await loadState();
    const got = r.applied || body;
    const clamped = r.applied && (
      Number(got.batteryFloorPercent) !== Number(body.batteryFloorPercent) ||
      Number(got.antiLockIntervalSec) !== Number(body.antiLockIntervalSec) ||
      Number(got.reassertSec) !== Number(body.reassertSec));
    const unrecorded = (r.StateRecorded === false);
    toast(KA.t('start.summary', {
      head: KA.t(unrecorded ? 'start.unrecorded' : (r.restarted ? 'start.restarted' : (r.AlreadyRunning ? 'start.already' : 'start.started'))),
      pid: r.Pid,
      disp: KA.t(got.keepDisplayOn ? 'pill.displayOn' : 'start.dispOff'),
      hb: KA.t(got.antiLock ? 'start.hb' : 'start.hbOff', { method: got.antiLockMethod, sec: got.antiLockIntervalSec }),
      dur: KA.t(body.minutes ? 'start.endsIn' : 'common.unlimited', { dur: fmtDuration(body.minutes * 60) }),
      clamp: KA.t(clamped ? 'start.clamped' : '')
    }), !r.Ok ? 'err' : (unrecorded ? 'info' : 'ok'));
  } catch (e) { toast(KA.t('start.fail', { msg: e.message }), 'err'); }
  finally { setBusy(false); loadLog(); }
}

async function doStop() {
  setBusy(true);
  try {
    const r = await api('/api/stop', { method: 'POST', headers: HJ, body: '{}' });
    await loadState();
    const uncoop = (r.Cooperative === false);
    toast(KA.t('stop.done', {
      n: (r.Stopped || 0),
      forced: KA.t(r.Forced ? 'stop.forced' : '', { n: r.Forced }) + KA.t(uncoop ? 'stop.uncoop' : '')
    }), (r.Forced || uncoop) ? 'info' : 'ok');
    loadEvidence();
  } catch (e) { toast(KA.t('stop.fail', { msg: e.message }), 'err'); }
  finally { setBusy(false); loadLog(); }
}

async function doSave() {
  const p = collectPayload();
  const patch = {
    keepDisplayOn: els.optDisplay.checked,
    antiLock: p.antiLock, antiLockMethod: p.antiLockMethod,
    antiLockIntervalSec: p.antiLockIntervalSec, reassertSec: p.reassertSec,
    awayMode: p.awayMode, batteryAllowDisplayOff: p.batteryAllowDisplayOff,
    batteryFloorPercent: p.batteryFloorPercent
  };
  setBusy(true);
  try {
    await api('/api/config', { method: 'POST', headers: HJ, body: JSON.stringify({ patch: patch }) });
    state.controlsDirty = false;
    await loadState();
    toast(KA.t('save.done'), 'ok');
  } catch (e) { toast(KA.t('save.fail', { msg: e.message }), 'err'); }
  finally { setBusy(false); }
}

async function doGuard() {
  const op = els.btnGuard.dataset.op === 'uninstall' ? 'uninstall' : 'install';
  setBusy(true);
  try {
    await api(op === 'uninstall' ? '/api/guard/uninstall' : '/api/guard/install', { method: 'POST', headers: HJ, body: '{}' });
    await loadState();
    toast(KA.t(op === 'uninstall' ? 'guard.toastUninstalled' : 'guard.toastInstalled'), 'ok');
  } catch (e) { toast(KA.t('guard.fail', { op: KA.t(op === 'uninstall' ? 'verb.uninstall' : 'verb.install'), msg: e.message }), 'err'); }
  finally { setBusy(false); loadLog(); }
}

async function doCheck() {
  setBusy(true);
  text(els.checkHint, KA.t('check.running')); els.checkHint.style.color = 'var(--faint)';
  try {
    const r = await api('/api/check', { method: 'POST', headers: HJ, body: '{}' });
    await loadReport();
    text(els.checkHint, KA.t('check.done', { sec: r.recommendedIntervalSec, why: prose(r.recommendedWhy) }));
    els.checkHint.style.color = 'var(--go)';
    toast(KA.t('check.toast'), 'ok');
  } catch (e) {
    text(els.checkHint, KA.t('check.fail', { msg: e.message })); els.checkHint.style.color = 'var(--stop)';
  } finally { setBusy(false); }
}

async function doStopServer() {
  if (!window.confirm(KA.t('confirm.stopServer'))) return;
  try { await api('/api/server/stop', { method: 'POST', headers: HJ, body: '{}' }); } catch (e) { /* it is about to die */ }
  state.stopping = true;
  renderConn(false, true);
  text(els.stateTitle, KA.t('gone.title'));
  text(els.stateDetail, KA.t('gone.detail'));
  document.title = KA.t('docTitle.gone', { name: KA.t('page.name') });
}

/* -------------------------------------------------------- language switcher */
/*
  The choice is stored in config.json under `language`, next to antiLockMethod, so the
  command line and the tray follow the panel. 'auto' is resolved here in the browser.
  Switching is not a control edit: it saves itself and never touches controlsDirty.
*/
function markLangSeg(choice) {
  els.langSeg.querySelectorAll('[data-lang]').forEach((b) => b.classList.toggle('is-on', b.dataset.lang === choice));
}

async function readLanguageChoice() {
  try {
    const c = await api('/api/config', { headers: H });
    const v = c && c.language ? String(c.language) : 'auto';
    return (v === 'zh' || v === 'en') ? v : 'auto';
  } catch (e) {
    return 'auto';      // no config readable yet: follow the browser rather than guessing
  }
}

function applyLanguage(choice) {
  state.langChoice = choice;
  KA.set(choice === 'auto' ? KA.detect() : choice);   // fires ka-lang, see renderI18n below
  markLangSeg(choice);                                 // after set(): it marks zh/en only
}

function renderI18n() {
  fillInlineRuns();
  if (state.s) { try { renderState(state.s); renderGuard(state.s); } catch (e) { /* the next poll retries */ } }
  if (state.report) renderReport(state.report);
  if (state.evData) renderEvidence(state.evData);
  if (state.logLines) renderLog(state.logLines);
}

/* ------------------------------------------------------------------- wiring */
els.presets.addEventListener('click', (e) => {
  const btn = e.target.closest('.seg');
  if (!btn) return;
  selectSeg(els.presets, 'min', btn.dataset.min);
  els.customMin.value = '';
  if (state.previewOpen) renderPreview();
});
els.customMin.addEventListener('input', () => {
  if (els.customMin.value) els.presets.querySelectorAll('.seg').forEach((b) => b.classList.remove('is-on'));
  if (state.previewOpen) renderPreview();
});
els.methodSegs.addEventListener('click', (e) => {
  const btn = e.target.closest('.seg');
  if (!btn) return;
  selectSeg(els.methodSegs, 'method', btn.dataset.method);
  state.controlsDirty = true;
  if (state.previewOpen) renderPreview();
});
els.langSeg.addEventListener('click', async (e) => {
  const btn = e.target.closest('.seg');
  if (!btn) return;
  const choice = btn.dataset.lang;
  try {
    await api('/api/config', { method: 'POST', headers: HJ, body: JSON.stringify({ patch: { language: choice } }) });
  } catch (err) {
    toast(KA.t('lang.fail', { msg: err.message }), 'err');   // still switch locally, just say it did not stick
  }
  applyLanguage(choice);
});
document.addEventListener('ka-lang', renderI18n);
els.evRange.addEventListener('click', (e) => {
  const btn = e.target.closest('.seg');
  if (!btn) return;
  state.evHours = parseInt(btn.dataset.hours, 10);
  selectSeg(els.evRange, 'hours', btn.dataset.hours);
  loadEvidence();
});
els.evfChips.addEventListener('click', (e) => {
  const btn = e.target.closest('.chip');
  if (!btn) return;
  state.evFilter.chip = btn.dataset.evf || 'all';
  els.evfChips.querySelectorAll('.chip').forEach((c) => c.classList.toggle('is-on', c === btn));
  if (state.evData) renderEvidence(state.evData);   // a lens, not a query - no refetch
});
let evfTimer = 0;
els.evfSearch.addEventListener('input', () => {
  state.evFilter.q = els.evfSearch.value;
  clearTimeout(evfTimer);
  evfTimer = setTimeout(() => { if (state.evData) renderEvidence(state.evData); }, 140);
});

const dirty = () => {
  state.controlsDirty = true;
  if (state.previewOpen) renderPreview();   // live preview: edits are reflected before confirming
};
['optDisplay', 'optAntiLock', 'optInterval', 'optReassert', 'optAway', 'optBattOff', 'optFloor'].forEach((k) => {
  els[k].addEventListener('input', dirty);
  els[k].addEventListener('change', dirty);
});
els.optAntiLock.addEventListener('change', () => {
  els.lockRow.classList.toggle('is-dim', !els.optAntiLock.checked);
  drawTrace();
});

els.btnStart.addEventListener('click', openPreview);
els.btnStop.addEventListener('click', doStop);
els.btnSave.addEventListener('click', doSave);
els.btnGuard.addEventListener('click', doGuard);
els.btnCheck.addEventListener('click', doCheck);
els.btnEvidence.addEventListener('click', loadEvidence);
els.btnLog.addEventListener('click', loadLog);
els.btnStopServer.addEventListener('click', doStopServer);
els.btnRefresh.addEventListener('click', () => {
  state.controlsDirty = false;      // explicit refresh = "show me what the server has"
  loadState(); loadLog(); loadEvidence();
  toast(KA.t('refresh.done'), 'info');
});

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && state.previewOpen) { closePreview(); return; }
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const tag = (e.target.tagName || '').toLowerCase();
  if (tag === 'input' || tag === 'textarea' || tag === 'select' || e.target.isContentEditable) return;
  const k = e.key.toLowerCase();
  if (k === 's') { e.preventDefault(); openPreview(); }
  else if (k === 'x') { e.preventDefault(); if (!els.btnStop.disabled) doStop(); }
  else if (k === 'r') { e.preventDefault(); els.btnRefresh.click(); }
});

window.addEventListener('resize', () => { sizeCanvas(); drawTrace(); });

/* --------------------------------------------------------------- reveal / nav */
function initReveal() {
  const items = Array.from(document.querySelectorAll('.reveal'));
  items.forEach((el) => {
    const sibs = Array.from(el.parentNode.children).filter((n) => n.classList && n.classList.contains('reveal'));
    el.style.transitionDelay = Math.min(6, sibs.indexOf(el)) * 0.055 + 's';
  });
  if (!('IntersectionObserver' in window)) { items.forEach((el) => el.classList.add('in')); return; }
  const io = new IntersectionObserver((entries) => {
    entries.forEach((en) => { if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); } });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.02 });
  items.forEach((el) => io.observe(el));
  // safety net: a page that cannot animate must still be a page that can be read
  setTimeout(() => document.querySelectorAll('.reveal:not(.in)').forEach((el) => el.classList.add('in')), 1800);
}

function initNav() {
  if (!('IntersectionObserver' in window)) return;
  const links = Array.from(els.nav.querySelectorAll('a'));
  const map = {};
  links.forEach((a) => { map[a.getAttribute('href').slice(1)] = a; });
  const io = new IntersectionObserver((entries) => {
    entries.forEach((en) => {
      const a = map[en.target.id];
      if (!a) return;
      if (en.isIntersecting) {
        links.forEach((x) => x.style.color = '');
        a.style.color = 'var(--brand)';
      }
    });
  }, { rootMargin: '-45% 0px -50% 0px' });
  document.querySelectorAll('.panel').forEach((p) => io.observe(p));
}

function initGuide() {
  // One-time onboarding, dismissed for good: a guide that comes back is noise, not help.
  let seen = false;
  try { seen = localStorage.getItem('ka.guideSeen') === '1'; } catch (e) { /* private mode */ }
  if (seen) return;
  els.guide.hidden = false;
  els.btnGuideDismiss.addEventListener('click', () => {
    els.guide.hidden = true;
    try { localStorage.setItem('ka.guideSeen', '1'); } catch (e) { /* still hide it */ }
  });
}

/* ------------------------------------------------------------------ polling */
async function tick() {
  if (state.stopping) return;
  await loadState();
}
function bootClock() {
  setInterval(() => { text(els.clock, hhmmss(nowEpoch())); }, 1000);
  text(els.clock, hhmmss(Math.floor(Date.now() / 1000)));
}

cv = els.traceCanvas;
ctx2d = cv.getContext ? cv.getContext('2d') : null;
sizeCanvas();
initReveal();
initNav();
initGuide();
bootClock();
if (ctx2d) traceLoop();

/*
  Language first, render second: KA.set is awaited before the first data render so an
  English machine never paints Chinese and then flips. Everything below waits for it.
*/
(async function boot() {
  applyLanguage(await readLanguageChoice());
  tick();
  loadReport();
  loadEvidence();
  loadLog();
  setInterval(tick, 2000);
  setInterval(() => { if (els.autoLog.checked) loadLog(); }, 6000);
  setInterval(() => { if (!document.hidden) loadEvidence(); }, 30000);
}());
document.addEventListener('visibilitychange', () => { if (!document.hidden) { tick(); loadLog(); } });

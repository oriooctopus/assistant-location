// Cycle store: storage adapter, session, shared-row cache, private tier, outbox
// and Supabase sync (plain fetch against PostgREST + GoTrue, no supabase-js).
//
// Two storage backends, chosen ONCE at boot: the native `cycle` bridge when the
// iOS shell injected it (native data survives app updates; file-origin web
// storage does not), otherwise localStorage with no-op notifications (dev + tests).
var CycleStore = (function () {
  'use strict';
  var C = CycleCore;
  var cfg = window.CYCLE_CONFIG;
  if (!cfg || !cfg.supabaseUrl || !cfg.supabaseAnonKey) throw new Error('config.js missing or incomplete: window.CYCLE_CONFIG needs supabaseUrl + supabaseAnonKey');

  // ---- storage adapter --------------------------------------------------
  var hasNative = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cycle);
  var calls = {}, callSeq = 0;
  // Native replies arrive on this global; ids pair them with their promise.
  window.__cycleReply = function (id, result, error) {
    var p = calls[id]; delete calls[id];
    if (!p) throw new Error('cycle bridge reply for unknown call ' + id);
    if (error) p.reject(new Error(error)); else p.resolve(result);
  };
  function bridge(cmd, args) {
    return new Promise(function (resolve, reject) {
      var id = ++callSeq; calls[id] = { resolve: resolve, reject: reject };
      window.webkit.messageHandlers.cycle.postMessage({ id: id, cmd: cmd, args: args || {} });
    });
  }
  var LS = 'cycle:';
  var kv = hasNative ? {
    get: function (k) { return bridge('store.get', { key: k }); },
    set: function (k, v) { return bridge('store.set', { key: k, value: v }); },
    keys: function (p) { return bridge('store.keys', { prefix: p }); }
  } : {
    get: function (k) { return Promise.resolve(localStorage.getItem(LS + k)); },
    set: function (k, v) { if (v === null) localStorage.removeItem(LS + k); else localStorage.setItem(LS + k, v); return Promise.resolve(); },
    keys: function (p) { return Promise.resolve(Object.keys(localStorage).filter(function (k) { return k.indexOf(LS + p) === 0; }).map(function (k) { return k.slice(LS.length); })); }
  };
  var native = {
    permission: function () { return hasNative ? bridge('notify.permission') : Promise.resolve(false); },
    schedule: function (o) { return hasNative ? bridge('notify.schedule', o) : Promise.resolve(); },
    cancel: function (id) { return hasNative ? bridge('notify.cancel', { id: id }) : Promise.resolve(); },
    haptic: function (kind) { return hasNative ? bridge('haptic', { kind: kind }) : Promise.resolve(); }
  };

  // ---- state ---------------------------------------------------------------
  var SHARED = ['items', 'todos', 'todo_events', 'checkins', 'fight_markers', 'rewards', 'redemptions'];
  // Pull strategy per table: cursor column, or null = re-pull everything each sync.
  var CURSOR = { items: 'updated_at', todos: 'updated_at', checkins: 'updated_at', rewards: 'updated_at', redemptions: 'updated_at', todo_events: 'at', fight_markers: null };
  var S = { session: null, couple: null, members: [], rows: {}, cursors: {}, outbox: [], priv: null, syncError: null, syncing: false };
  SHARED.forEach(function (t) { S.rows[t] = {}; });
  var listeners = [];
  function emit() { listeners.forEach(function (f) { f(); }); }
  function on(f) { listeners.push(f); }
  function nowIso() { return new Date().toISOString(); }
  function uuid() { return crypto.randomUUID(); }

  function me() { return S.session && S.session.user.id; }
  function partner() { return S.members.filter(function (m) { return m.user_id !== me(); })[0] || null; }
  function myMember() { return S.members.filter(function (m) { return m.user_id === me(); })[0] || null; }
  function list(t) { return Object.keys(S.rows[t]).map(function (k) { return S.rows[t][k]; }); }
  function get(t, id) { return S.rows[t][id]; }

  // ---- persistence ---------------------------------------------------------
  var persistTimer = 0;
  function persist() {
    clearTimeout(persistTimer);
    persistTimer = setTimeout(persistNow, 50);
  }
  function persistNow() {
    clearTimeout(persistTimer);
    var uid = me();
    var jobs = [kv.set('session', JSON.stringify(S.session))];
    if (uid) {
      jobs.push(kv.set('shared.' + uid, JSON.stringify({ couple: S.couple, members: S.members, rows: S.rows, cursors: S.cursors, outbox: S.outbox })));
      if (S.priv) jobs.push(kv.set('priv.' + uid, JSON.stringify(S.priv)));
    }
    return Promise.all(jobs);
  }

  function emptyPriv() { return { fights: [], affirmations: [], prefs: {} }; }

  // ---- HTTP ------------------------------------------------------------------
  function authHeaders(extra) {
    var h = { apikey: cfg.supabaseAnonKey, 'Content-Type': 'application/json' };
    if (S.session) h.Authorization = 'Bearer ' + S.session.access_token;
    else h.Authorization = 'Bearer ' + cfg.supabaseAnonKey;
    for (var k in extra) h[k] = extra[k];
    return h;
  }
  function setSession(j) {
    S.session = { access_token: j.access_token, refresh_token: j.refresh_token, expires_at: Math.floor(Date.now() / 1000) + (j.expires_in || 3600), user: { id: j.user.id, email: j.user.email } };
  }
  async function gotrue(path, body) {
    var r = await fetch(cfg.supabaseUrl + '/auth/v1' + path, { method: 'POST', headers: { apikey: cfg.supabaseAnonKey, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    var j = await r.json();
    if (!r.ok) throw new Error(j.msg || j.error_description || j.message || 'auth failed ' + r.status);
    return j;
  }
  // Refresh shortly before expiry; a refresh the server rejects ends the session loudly.
  async function ensureFresh() {
    if (!S.session || S.session.expires_at - Date.now() / 1000 > 60) return;
    var j = await gotrue('/token?grant_type=refresh_token', { refresh_token: S.session.refresh_token });
    setSession(j); persist();
  }
  async function api(method, path, body, extra) {
    await ensureFresh();
    var r = await fetch(cfg.supabaseUrl + '/rest/v1/' + path, { method: method, headers: authHeaders(extra), body: body === undefined ? undefined : JSON.stringify(body) });
    if (!r.ok) {
      var text = await r.text(), err = new Error(method + ' ' + path.split('?')[0] + ' ' + r.status + ' ' + text);
      err.status = r.status; err.body = text; throw err;
    }
    return r.status === 204 ? null : r.json().catch(function () { return null; });
  }

  // ---- auth --------------------------------------------------------------------
  async function loadUserData(uid) {
    var sh = JSON.parse((await kv.get('shared.' + uid)) || 'null');
    if (sh) { S.couple = sh.couple; S.members = sh.members; S.rows = sh.rows; S.cursors = sh.cursors; S.outbox = sh.outbox; }
    else { S.couple = null; S.members = []; SHARED.forEach(function (t) { S.rows[t] = {}; }); S.cursors = {}; S.outbox = []; }
    S.priv = JSON.parse((await kv.get('priv.' + uid)) || 'null') || emptyPriv();
  }
  async function signUp(email, password) {
    var j = await gotrue('/signup', { email: email, password: password });
    if (!j.access_token) throw new Error('Account created but no session: email confirmation is still on');
    setSession(j); await loadUserData(j.user.id); await persistNow(); emit();
  }
  async function signIn(email, password) {
    var j = await gotrue('/token?grant_type=password', { email: email, password: password });
    setSession(j); await loadUserData(j.user.id); await persistNow(); await sync(); emit();
  }
  async function signOut() {
    cancelAllNotifications();
    S.session = null; S.couple = null; S.members = []; S.outbox = []; S.priv = null;
    SHARED.forEach(function (t) { S.rows[t] = {}; }); S.cursors = {};
    await kv.set('session', null); emit();
  }

  // ---- couple setup ---------------------------------------------------------------
  async function createCouple(name, tz) {
    var code = await api('POST', 'rpc/create_couple', { p_name: name, p_tz: tz });
    await sync(); return code;
  }
  async function joinCouple(code, name) {
    await api('POST', 'rpc/join_couple', { p_code: code, p_name: name });
    await sync();
  }

  // ---- sync -------------------------------------------------------------------------
  var syncTimer = 0, syncAgain = false;
  function scheduleSync() { clearTimeout(syncTimer); syncTimer = setTimeout(sync, 400); }
  async function pullTable(t) {
    var cur = CURSOR[t], since = cur && S.cursors[t];
    var q = t + '?select=*' + (since ? '&' + cur + '=gte.' + encodeURIComponent(since) : '') + '&order=' + (cur || 'at') + '.asc';
    var max = since || null, from = 0;
    for (;;) { // PostgREST caps a response at 1000 rows: page with Range until a short page
      var page = await api('GET', q, undefined, { Range: from + '-' + (from + 999), 'Range-Unit': 'items' });
      page.forEach(function (row) {
        var pend = S.outbox.filter(function (o) { return o.table === t && o.id === row.id; });
        // A local edit not yet pushed wins over the server copy (last write wins).
        pend.forEach(function (o) { if (o.op === 'patch') for (var k in o.patch) row[k] = o.patch[k]; });
        S.rows[t][row.id] = row;
        if (cur && (!max || row[cur] > max)) max = row[cur];
      });
      if (page.length < 1000) break;
      from += 1000;
    }
    if (cur) S.cursors[t] = max;
  }
  async function pull() {
    var c = await api('GET', 'couples?select=*');
    S.couple = c[0] || null;
    S.members = await api('GET', 'members?select=*');
    if (!S.couple) return;
    for (var i = 0; i < SHARED.length; i++) await pullTable(SHARED[i]);
  }
  async function push() {
    while (S.outbox.length) {
      var o = S.outbox[0];
      try {
        if (o.op === 'insert') await api('POST', o.table, o.row, { Prefer: 'return=minimal' });
        else await api('PATCH', o.table + '?id=eq.' + o.id, o.patch, { Prefer: 'return=minimal' });
      } catch (e) {
        // 409 on insert = this id already reached the server (response lost, retried): applied.
        if (!(o.op === 'insert' && e.status === 409)) throw e;
      }
      S.outbox.shift();
    }
  }
  // Push local writes first so the pull that follows returns their server-stamped rows.
  async function sync() {
    if (!S.session || S.syncing) { syncAgain = !!S.session; return; }
    if (typeof navigator !== 'undefined' && navigator.onLine === false) return;
    S.syncing = true;
    try {
      if (S.couple) await push();
      await pull();
      S.syncError = null;
    } catch (e) {
      if (e instanceof TypeError) { /* fetch rejected: offline, retried on the next trigger */ }
      else { S.syncError = e.message; console.error('cycle sync failed:', e); }
    } finally {
      S.syncing = false; persist(); emit(); reschedule();
      if (syncAgain) { syncAgain = false; scheduleSync(); }
    }
  }

  // ---- writes -------------------------------------------------------------------------
  function insert(t, row) {
    S.rows[t][row.id] = row;
    S.outbox.push({ op: 'insert', table: t, id: row.id, row: Object.assign({}, row) });
    persist(); emit(); scheduleSync(); reschedule();
    return row;
  }
  // Partial update. Folds into a still-unsent insert or patch of the same row so the
  // outbox stays small and a recipient only ever PATCHes the columns it may change.
  function patch(t, id, fields) {
    var row = S.rows[t][id];
    if (!row) throw new Error('patch of unknown ' + t + ' ' + id);
    var cols = Object.assign({}, fields);
    Object.assign(row, cols);
    if ('updated_at' in row) row.updated_at = nowIso();
    var last = S.outbox.filter(function (o) { return o.table === t && o.id === id; }).pop();
    if (last && last.op === 'insert') Object.assign(last.row, cols);
    else if (last && last.op === 'patch' && last === S.outbox[S.outbox.length - 1]) Object.assign(last.patch, cols);
    else S.outbox.push({ op: 'patch', table: t, id: id, patch: cols });
    persist(); emit(); scheduleSync(); reschedule();
  }

  // ---- private tier --------------------------------------------------------------------
  var backupTimer = 0;
  function savePriv() {
    persist(); emit();
    clearTimeout(backupTimer);
    backupTimer = setTimeout(backup, 3000);
  }
  // Best-effort private backup to the box. Only the box owner's account is allowed
  // (403 for everyone else), so 403 is the one silent outcome; everything else is loud.
  async function backup() {
    if (!cfg.boxUrl || !S.session || (typeof navigator !== 'undefined' && navigator.onLine === false)) return;
    try {
      await ensureFresh();
      var r = await fetch(cfg.boxUrl + '/backup', { method: 'PUT', headers: { Authorization: 'Bearer ' + S.session.access_token, 'Content-Type': 'application/json' }, body: JSON.stringify(S.priv) });
      if (!r.ok && r.status !== 403) console.error('cycle backup failed: HTTP ' + r.status);
    } catch (e) { if (!(e instanceof TypeError)) console.error('cycle backup failed:', e); }
  }
  // The vent leaves the phone only here, only on an explicit Rewrite tap.
  async function rewrite(vent) {
    if (!cfg.boxUrl) throw new Error('Rewrite unavailable');
    await ensureFresh();
    var r;
    try { r = await fetch(cfg.boxUrl + '/rewrite', { method: 'POST', headers: { Authorization: 'Bearer ' + S.session.access_token, 'Content-Type': 'application/json' }, body: JSON.stringify({ vent: vent }) }); }
    catch (e) { throw new Error('Rewrite unavailable'); }
    if (!r.ok) throw new Error('Rewrite unavailable');
    return (await r.json()).text;
  }

  // ---- local notifications -----------------------------------------------------------------
  // Everything the shell must have scheduled is derived from state on every change; ids that
  // were scheduled before but are no longer wanted are cancelled. Native replaces a re-used id.
  var scheduledIds = [], reschedTimer = 0;
  function reschedule() { clearTimeout(reschedTimer); reschedTimer = setTimeout(rescheduleNow, 200); }
  function wanted() {
    var out = [], m = myMember(), now = Date.now();
    if (!m || !S.couple) return out;
    var tz = m.tz || S.couple.tz, today = C.localDay(now, tz), parts = m.checkin_time.split(':');
    var done = list('checkins').some(function (c) { return c.user_id === me() && c.day === today; });
    for (var add = done ? 1 : 0; add < 3; add++) {
      var day = C.addDays(today, add), at = zonedMs(day, +parts[0], +parts[1], tz);
      if (at > now) { out.push({ id: 'checkin', at: at, title: 'Check-in', body: '', route: 'today' }); break; }
    }
    list('items').forEach(function (i) {
      if (i.sender_id === me() && i.status === 'held' && !i.deleted_at)
        out.push({ id: 'held-' + i.id, at: Math.max(C.ms(i.held_until), now + 1000), title: 'Still send?', body: i.kind.charAt(0).toUpperCase() + i.kind.slice(1), route: 'held/' + i.id });
    });
    (S.priv ? S.priv.fights : []).forEach(function (f) {
      var at = f.at + 24 * 3600000;
      if (at > now && !f.followed) out.push({ id: 'fu-' + f.id, at: at, title: 'Follow up', body: '', route: 'log-followup' });
    });
    return out;
  }
  // Wall-clock HH:MM in a tz -> epoch ms (search the offset; Intl has no inverse).
  function zonedMs(day, h, mi, tz) {
    var guess = Date.parse(day + 'T' + String(h).padStart(2, '0') + ':' + String(mi).padStart(2, '0') + ':00Z');
    for (var i = 0; i < 2; i++) {
      var f = new Intl.DateTimeFormat('en-CA', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).formatToParts(new Date(guess)), p = {};
      f.forEach(function (x) { p[x.type] = x.value; });
      var shown = Date.parse(p.year + '-' + p.month + '-' + p.day + 'T' + p.hour + ':' + p.minute + ':00Z');
      guess += Date.parse(day + 'T' + String(h).padStart(2, '0') + ':' + String(mi).padStart(2, '0') + ':00Z') - shown;
    }
    return guess;
  }
  async function rescheduleNow() {
    if (!hasNative || !S.session) return;
    var w = wanted(), ids = w.map(function (x) { return x.id; });
    for (var i = 0; i < scheduledIds.length; i++) if (ids.indexOf(scheduledIds[i]) < 0) await native.cancel(scheduledIds[i]);
    for (var j = 0; j < w.length; j++) await native.schedule(w[j]);
    scheduledIds = ids;
  }
  function cancelAllNotifications() { scheduledIds.forEach(native.cancel); scheduledIds = []; }

  // ---- boot ------------------------------------------------------------------------------------
  async function boot() {
    var s = JSON.parse((await kv.get('session')) || 'null');
    if (s) { S.session = s; await loadUserData(s.user.id); }
    window.addEventListener('online', sync);
    if (S.session) { native.permission(); sync(); }
  }

  return {
    S: S, boot: boot, on: on, emit: emit, uuid: uuid, me: me, partner: partner, myMember: myMember, list: list, get: get,
    signUp: signUp, signIn: signIn, signOut: signOut, createCouple: createCouple, joinCouple: joinCouple,
    sync: sync, insert: insert, patch: patch, savePriv: savePriv, rewrite: rewrite, native: native, reschedule: reschedule,
    api: api, persistNow: persistNow, hasNative: hasNative, zonedMs: zonedMs, backup: backup
  };
})();

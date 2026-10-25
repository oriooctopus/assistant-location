// Cycle UI: router, screens, sheets and event handling.
//
// Rendering model: every screen is a pure function of (store state + `ui` view state) that
// returns an HTML string; render() swaps it into #app. Input text lives in `ui.d` (updated on
// every keystroke) so a re-render never loses what was typed. Store changes re-render, except
// while a text field has focus (that would drop the caret and close the keyboard); the
// re-render is deferred to blur instead.
//
// All clicks go through one delegated listener keyed on data-a="name:arg" (see ACT). Markup and
// class names come from the approved mockups; nothing here invents visual styling.
(function () {
'use strict';
var C = CycleCore, St = CycleStore, S = St.S, M = Motion;
var app = document.getElementById('app');

// ---- view state --------------------------------------------------------------------------
var ui = {
  route: 'home', stack: [], sheet: null, d: {}, err: null, errTimer: 0,
  reorder: false, dirty: false, ready: false, cyc: null, kind: 'truth', atype: 'task', tgt: 10,
  mode: 'create', code: null, todoTab: 'all'
};

// ---- small helpers -----------------------------------------------------------------------
var L = St.list;
var MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
var WD = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
var KIND = { focus: 'Focus', kudos: 'Kudos', truth: 'Truth', ask: 'Ask' };
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
function ic(id, cls) { return '<svg class="ic ' + (cls || '') + '"><use href="#' + id + '"/></svg>'; }
function now() { return Date.now(); }
function tz() { return S.couple.tz; }
function today() { return C.localDay(now(), tz()); }
function dayName(day) { return WD[C.dow(day)]; }
function fmtDay(day) { var p = day.split('-'); return dayName(day) + ' ' + (+p[2]) + ' ' + MON[+p[1] - 1]; }
function fmtTime(ms) { return new Date(ms).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: tz() }).toLowerCase(); }
function dispPick(type, v) { return !v ? 'Pick' : type === 'time' ? fmtHM(v) : fmtDay(v); }
// Time and date fields are a pill showing the formatted value with the native input transparent over it,
// so the shown text never carries seconds or the platform's own layout.
function dpick(type, k, v, cls) {
  return '<label class="pick dp ' + (cls || '') + '"><span class="pv">' + esc(dispPick(type, v)) + '</span><input type="' + type + '"' + (type === 'time' ? ' step="60"' : '') + ' data-d="' + k + '" data-pt="' + type + '" value="' + esc(v) + '"></label>';
}
function clip(s, n) { return s.length > n ? s.slice(0, n - 1) + '\u2026' : s; }
function hm5(t) { return String(t).slice(0, 5); }
function fmtHM(hhmm) { var p = hhmm.split(':'), h = +p[0]; return ((h + 11) % 12 + 1) + ':' + p[1] + ' ' + (h < 12 ? 'am' : 'pm'); }
function sg(n) { return n > 0 ? '+' + n : n < 0 ? '−' + (-n) : '0'; }
function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }
function pName() { var p = St.partner(); return p ? p.name : 'Partner'; }
// A name that may be long renders as one ellipsized run so it can never wrap a pill, segment or row.
function pnx(n) { return '<span class="pn">' + esc(n) + '</span>'; }
function pn() { return pnx(pName()); }
function nameOf(uid) { var m = S.members.filter(function (x) { return x.user_id === uid; })[0]; return m ? m.name : ''; }
function nowIso() { return new Date().toISOString(); }
function prefs() { return S.priv.prefs; }
function byDelivered(a, b) { return C.ms(b.delivered_at || b.created_at) - C.ms(a.delivered_at || a.created_at); }

function myItems() { return L('items').filter(function (i) { return i.sender_id === St.me() && !i.deleted_at; }); }
function heldItems() { return myItems().filter(function (i) { return i.status === 'held'; }).sort(function (a, b) { return C.ms(a.held_until) - C.ms(b.held_until); }); }
function myTodos() { return L('todos').filter(function (t) { return t.owner_id === St.me() && !t.deleted_at; }); }
function openTodos(list) { return list.filter(function (t) { return !t.done_at; }); }
function ledger() {
  return C.computeLedger({ members: S.members, items: L('items'), todos: L('todos'), todo_events: L('todo_events'), checkins: L('checkins'), fight_markers: L('fight_markers'), redemptions: L('redemptions') },
    { tz: tz(), now: now(), since: C.localDay(C.ms(S.couple.created_at), tz()) });
}
function itemLabel(i) { return i.origin === 'fight' && i.response_type ? cap(i.response_type) : KIND[i.kind]; }
function itemTitle(i) { return i.origin === 'fight' ? itemLabel(i) : i.body; }

// ---- errors ---------------------------------------------------------------------------------
// Failures surface as a short pink line (and the console); a guarded action never leaves a rejected promise behind.
// Backend text is mapped to a plain label; anything unmapped shows by status class, never raw JSON.
var PLAIN = [
  [/invalid login credentials/i, 'Wrong email or password'],
  [/already registered|already been registered/i, 'Email already used'],
  [/password should be at least|weak password/i, 'Password too short'],
  [/unable to validate email|invalid format|valid email/i, 'Check the email'],
  [/email not confirmed/i, 'Confirm email first'],
  [/rate limit|too many/i, 'Wait a minute'],
  [/join_couple/, 'Wrong code'],
  [/failed to fetch|load failed|networkerror|internet connection|network request failed/i, 'No connection']
];
function plain(e) {
  var m = String((e && e.message) || e);
  for (var i = 0; i < PLAIN.length; i++) if (PLAIN[i][0].test(m)) return PLAIN[i][1];
  if (e && e.status >= 500) return 'Server error';
  if (e && (e.status === 401 || e.status === 403)) return 'Sign in again';
  if (e && e.status) return 'Try again';
  return m.length <= 28 ? m : 'Try again';
}
function showErr(msg) {
  ui.err = msg; render();
  clearTimeout(ui.errTimer); ui.errTimer = setTimeout(function () { ui.err = null; render(); }, 5000);
}
function guard(fn) {
  return function () {
    var args = arguments;
    return Promise.resolve().then(function () { return fn.apply(null, args); }).catch(function (e) { console.error('cycle action failed:', e); showErr(plain(e)); });
  };
}

// ---- layout pieces -------------------------------------------------------------------------------
// opts.band=false for screens whose mockup has no pink band (Log fight, Settings).
function phone(cls, inner, o) {
  o = o || {};
  var band = o.band === false ? '' : '<div class="band" aria-hidden="true"></div>';
  var err = ui.err || S.syncError;
  var off = !navigator.onLine || (S.outbox && S.outbox.length) ? '<span class="off' + (o.band === false ? ' nb' : '') + '">Offline</span>' : '';
  return '<div class="phone ' + cls + (o.tab === false ? ' nt' : '') + '"><div class="scr">' + band + off + '<div class="status"></div><main>' + inner + '</main></div>' +
    (o.tab === false ? '' : tabbar(o.tab)) + (o.sheet || '') + (err ? '<div class="errbar' + (o.sheet ? ' top' : '') + '" role="alert">' + esc(err) + '</div>' : '') + '</div>';
}
function tabbar(active) {
  // Badge: open to-dos the partner created for me (what an Ask turns into).
  var n = openTodos(myTodos()).filter(function (t) { return t.created_by !== St.me() && t.type !== 'response'; }).length;
  function tab(id, icon, label, badge) {
    return '<span class="tab' + (active === id ? ' on' : '') + '" data-a="tab:' + id + '">' + ic(icon) + '<b>' + label + '</b>' + (badge ? '<i class="bdg">' + badge + '</i>' : '') + '</span>';
  }
  return '<nav class="tabbar">' + tab('home', 'moon', 'Today') + tab('todo', 'circ', 'To do', n) + tab('us', 'us', 'Us') + '</nav>';
}
function tabFor(r) { return r === 'todo' ? 'todo' : ['us', 'send', 'held', 'points', 'shop', 'settings', 'cycle', 'kept'].indexOf(r) >= 0 ? 'us' : 'home'; }
function backLabel() { var p = ui.stack[ui.stack.length - 1]; return { home: 'Today', us: 'Us', send: 'Send', points: 'Points', todo: 'To do', settings: 'Settings' }[p && p.route] || 'Today'; }
function back() { var p = ui.stack.pop(); ui.route = p ? p.route : 'home'; ui.d = {}; ui.sheet = null; render(); }
function go(route, extra) {
  ui.stack.push({ route: ui.route });
  ui.route = route; ui.d = {}; ui.sheet = null; ui.reorder = false;
  if (extra) Object.assign(ui, extra);
  render(); var sc = document.querySelector('.scr'); if (sc) sc.scrollTop = 0;
}
function tab(id) { ui.stack = []; ui.route = id; ui.d = {}; ui.sheet = null; ui.reorder = false; render(); }
function hdBack(label) { return '<p class="txtbtn back" data-a="back">' + ic('chev', 'sm') + label + '</p>'; }
function ptsBack(label) { return '<p class="back" data-a="back"><svg><use href="#chev"/></svg>' + label + '</p>'; }
function val(k, def) { return ui.d[k] == null ? (def == null ? '' : def) : ui.d[k]; }
function inp(k, ph, extra) { return '<input class="inp" data-d="' + k + '" value="' + esc(val(k)) + '" placeholder="' + esc(ph || '') + '" ' + (extra || '') + '>'; }
function seg(items, cur, act, cls) {
  return '<div class="seg ' + (cls || '') + '">' + items.map(function (x) { return '<span class="' + (String(x[0]) === String(cur) ? 'on' : '') + '" data-a="' + act + ':' + x[0] + '">' + x[1] + '</span>'; }).join('') + '</div>';
}
function sheet(cls, inner, fam) {
  return '<div class="sheetlayer"><div class="dim" data-a="sheet:close"></div><div class="bs ' + (cls || '') + '"><div class="grab"></div>' + inner + '</div></div>';
}

// ---- screens -------------------------------------------------------------------------------------
var SCREEN = {};

SCREEN.auth = function () {
  return phone('p2 au', '<header class="hd"><div><h2>Cycle</h2></div></header>' +
    '<section><p class="lab">Email</p><input class="inp" type="email" autocomplete="email" autocapitalize="none" data-d="email" value="' + esc(val('email')) + '"></section>' +
    '<section><p class="lab">Password</p><input class="inp" type="password" autocomplete="current-password" data-d="password" value="' + esc(val('password')) + '"></section>' +
    '<div class="pair"><span class="save" data-a="signin">Sign in</span><span class="ghost" data-a="signup">Create account</span></div>', { tab: false });
};

SCREEN.setup = function () {
  if (ui.code) {
    return phone('p2 au', '<header class="hd"><div><h2>Invite code</h2></div></header>' +
      '<section><p class="lab">Code</p><p class="code" id="invite-code">' + esc(ui.code) + '</p>' +
      '<div class="pair two"><span class="ghost" id="copy-code" data-a="copycode">' + (ui.copied ? 'Copied' : 'Copy') + '</span><span class="ghost" data-a="sharecode">Share</span></div></section>' +
      '<div class="save" data-a="codedone">Continue</div>', { tab: false });
  }
  var c = ui.mode === 'create';
  return phone('p2 au', '<header class="hd"><div><h2>Couple</h2></div></header>' +
    seg([['create', 'Create'], ['join', 'Join']], ui.mode, 'mode') +
    '<section><p class="lab">Your name</p>' + inp('name') + '</section>' +
    (c ? '' : '<section><p class="lab">Code</p>' + inp('code', '', 'autocapitalize="characters" maxlength="12"') + '</section>') +
    '<section><p class="lab">Check-in time</p>' + dpick('time', 'time', hm5(val('time', '21:00')), 'wide') + '</section>' +
    '<div class="save" data-a="' + (c ? 'create' : 'join') + '">' + (c ? 'Create couple' : 'Join couple') + '</div>' +
    '<span class="ghost out" data-a="signout">Sign out</span>', { tab: false });
};

function rowsOrder() {
  var def = ['send', 'todo', 'fight'], o = prefs().rows;
  return o && o.length === 3 ? o : def;
}
function rowMeta(id) {
  if (id === 'send') return 'To ' + pn();
  if (id === 'todo') return openTodos(myTodos()).length + ' open';
  var f = S.priv.fights.slice().sort(function (a, b) { return b.at - a.at; })[0];
  if (!f) return 'None';
  var d = C.localDay(f.at, tz());
  return d === today() ? 'Today' : d === C.addDays(today(), -1) ? 'Yesterday' : 'Last ' + dayName(d);
}
var ROWLAB = { send: 'Send', todo: 'To do', fight: 'Log fight' };

SCREEN.home = function () {
  var led = ledger(), t = today();
  var cards = C.needsYou({ me: St.me(), now: now(), tz: tz(), items: L('items'), checkins: L('checkins'), redemptions: L('redemptions'), members: S.members });
  var html = cards.map(function (n) {
    if (n.type === 'ready') {
      return '<div class="nc pk" data-a="still:' + n.item.id + '"><div class="mid"><p class="s">Still send? &middot; ' + n.count + ' ready</p><p class="x">' + esc(itemTitle(n.item)) + '</p></div><span class="go">Send</span></div>';
    }
    if (n.type === 'approve') {
      var rw = S.rows.rewards[n.redemption.reward_id];
      return '<div class="nc pk tall"><div class="mid"><p class="s">' + pnx(nameOf(n.redemption.requested_by)) + '</p><p class="x">' + esc(rw ? rw.name : '') + ' &middot; ' + n.redemption.price + '</p></div><div class="two"><span class="go" data-a="approve:' + n.redemption.id + '">Approve</span><span class="go o" data-a="decline:' + n.redemption.id + '">Decline</span></div></div>';
    }
    if (n.type === 'checkin') {
      return '<div class="nc"><div class="mid"><p class="x">Check-in</p><p class="s">' + fmtHM(St.myMember().checkin_time) + '</p></div><span class="go o" data-a="go:today">Start</span></div>';
    }
    return '<div class="nc" data-a="open:' + n.item.id + '"><div class="mid"><p class="s">' + KIND[n.type] + ' from ' + pn() + '</p><p class="x">' + esc(n.item.body) + '</p></div>' + ic('chevr', 'chv') + '</div>';
  }).join('');
  // Week close appears from Sunday until acknowledged.
  if (C.dow(t) === 6 && prefs().weekSeen !== led.current.start) {
    html += '<div class="nc" data-a="go:week"><div class="mid"><p class="x">Week</p><p class="s">' + sg(led.current.net) + '</p></div>' + ic('chevr', 'chv') + '</div>';
  }
  var rows = rowsOrder().map(function (id) {
    return '<div class="row r2" data-id="' + id + '" data-a="row:' + id + '">' + (ui.reorder ? '<i class="slot"></i>' : '') + '<p class="lb">' + ROWLAB[id] + '</p><p class="mt">' + rowMeta(id) + '</p></div>';
  }).join('');
  var right = ui.reorder ? '<span class="done" data-a="reorderdone">Done</span>' :
    '<div class="hr"><span class="bal" data-a="go:points">' + led.balance + '</span><span class="usb" data-a="tab:us">' + ic('us') + 'Us</span></div>';
  return phone('pts' + (ui.reorder ? ' hold' : ''), '<header class="hd"><div class="ttl"><span class="mark"><svg><use href="#arwh"/></svg></span><div><h2>Today</h2><p class="dl">' + fmtDay(t) + '</p></div></div>' + right + '</header>' +
    '<div class="rows">' + rows + '</div>' + (html ? '<div class="nd"><p class="lab">Needs you</p>' + html + '</div>' : ''), { tab: false });
};

SCREEN.send = function () {
  var k = ui.kind, mins = C.holdMinutes(S.couple, k), held = heldItems().length;
  var ask = k !== 'ask' ? '' :
    '<section><p class="lab">Kind</p>' + seg([['task', 'Task'], ['habit', 'Habit']], ui.atype, 'atype') + '</section>' +
    (ui.atype === 'task' ? '<section><p class="lab">Due</p>' + dpick('date', 'due', val('due'), 'wide') + '</section>' :
      '<section><p class="lab">Target</p>' + stepper() + '</section>');
  return phone('p2 sd', '<header class="hd"><div>' + hdBack(backLabel()) + '<h2>Send</h2><p class="dl">To ' + pn() + '</p></div>' + (held ? '<span class="fight" data-a="go:held">Held ' + held + '</span>' : '') + '</header>' +
    '<section><p class="lab">Type</p>' + seg([['focus', 'Focus'], ['kudos', 'Kudos'], ['truth', 'Truth'], ['ask', 'Ask']], k, 'kind', 'ty') + '</section>' +
    '<section class="grow"><p class="lab">Message</p><div class="ta msg"><textarea data-d="body">' + esc(val('body')) + '</textarea></div></section>' + ask +
    (mins ? '<p class="hnote q"><svg><use href="#hg"/></svg>Holds ' + C.durText(mins) + '</p>' : '') +
    '<div class="save" data-a="sendit">' + (mins ? 'Hold' : 'Send') + '</div>', { tab: 'us' });
};
function stepper() {
  return '<div class="stp"><span data-a="tgt:-1"><svg class="ic sm"><path d="M6 12h12"/></svg></span><b>' + ui.tgt + '</b><span data-a="tgt:1">' + ic('plus', 'sm') + '</span></div>';
}

SCREEN.held = function () {
  var h = heldItems();
  var list = h.map(function (i) {
    return '<div class="hr"><div class="tx"><div class="mt"><span class="tch">' + KIND[i.kind] + '</span>' + (i.due_date ? '<span class="due">' + dayName(i.due_date) + '</span>' : '') + '</div><p>' + esc(itemTitle(i)) + '</p></div><div class="rt"><span class="cd">' + C.countdown(C.ms(i.held_until), now()) + '</span><span class="elink" data-a="still:' + i.id + '">Edit</span></div></div>';
  }).join('');
  return phone('p2 hl2', '<header class="hd"><div>' + hdBack(backLabel()) + '<h2>Held</h2><p class="dl">' + h.length + ' waiting</p></div></header><section class="list">' + (list || '<p class="empty">None</p>') + '</section>', { tab: 'us' });
};

// A "Still send?" notification or card can outlive its item: the hold may have been delivered or dropped
// on another phone, or by this one. Only a still-held item may offer Send / Edit / Drop.
function stillHeld(id) { return C.isStillHeld(S.rows.items[id]); }
function stillSheet() {
  var i = L('items').filter(function (x) { return x.id === ui.sheet.id; })[0];
  if (!C.isStillHeld(i)) return '';
  var e = ui.sheet.edit;
  return sheet('cf', '<div class="bsh"><h3>Still send?</h3><span class="x" data-a="sheet:close">&#x2715;</span></div>' +
    (i.origin === 'fight' ? '<p class="fm"><svg><use href="#fa"/></svg>Fight</p>' : '') +
    (e ? '<div class="ta"><textarea data-d="edit">' + esc(val('edit', i.body)) + '</textarea></div>' : '<p class="ask">' + esc(i.body) + '</p>') +
    '<p class="to">To ' + esc(nameOf(i.recipient_id)) + '</p>' +
    '<div class="acts"><div class="save" data-a="' + (e ? 'editsave' : 'deliver') + ':' + i.id + '">' + (e ? 'Save' : 'Send') + '</div>' + (e ? '' : '<div class="ghost" data-a="edit:' + i.id + '">Edit</div>') + '<div class="tdrop" data-a="drop:' + i.id + '">Drop</div></div>');
}

SCREEN.todo = function () {
  var mine = myTodos(), op = openTodos(mine), t = today();
  var held = heldItems();
  function eb(x) { return x.created_by !== St.me() ? '<span class="eb">' + esc(nameOf(x.created_by).charAt(0).toUpperCase()) + '</span>' : ''; }
  function row(x) {
    var resp = x.type === 'response', habit = x.type === 'habit', om = resp ? '<svg><use href="#fa"/></svg>' : eb(x);
    var due = x.due_date ? '<small><span class="due">' + dayName(x.due_date) + '</span></small>' : '';
    if (habit) {
      var wk = C.weekStart(t), n = L('todo_events').filter(function (e) { return e.todo_id === x.id && e.kind === 'tally' && C.localDay(C.ms(e.at), tz()) >= wk; }).length;
      var bar = x.target ? '<div class="pb"><i style="width:' + Math.min(100, Math.round(100 * x.tally / x.target)) + '%"></i></div>' : '<small>This week<span class="dt">' + Array(Math.min(n, 7) + 1).join('<i></i>') + '</span></small>';
      return '<div class="td-row" data-todo="' + x.id + '"><span class="om">' + om + '</span><div class="tx"><p>' + esc(x.title) + '</p>' + bar + '</div><span class="hv">' + (x.target ? x.tally + '/' + x.target : x.tally) + '</span><span class="p1b" data-a="tally:' + x.id + '">+1</span></div>';
    }
    return '<div class="td-row" data-todo="' + x.id + '"><span class="om">' + om + '</span><div class="tx"><p>' + esc(x.title) + '</p>' + due + '</div><span class="done" data-a="done:' + x.id + '">Done</span></div>';
  }
  var heldHtml = held.length ? '<section class="list held"><p class="lab">Held</p>' + held.map(function (i) {
    var rd = C.ms(i.held_until) <= now();
    return '<div class="td-row hrow2"><span class="om"><svg class="hold-ic"><use href="#hg"/></svg></span><p class="ht">' + esc(itemTitle(i)) + '</p><p class="hm2">To ' + pn() + '</p><div class="hact"><span class="cd">' + C.countdown(C.ms(i.held_until), now()) + '</span><span class="elink" data-a="still:' + i.id + '">' + (rd ? 'Send' : 'Edit') + '</span></div></div>';
  }).join('') + '</section>' : '';
  var theirs = openTodos(L('todos').filter(function (x) { return x.owner_id !== St.me() && !x.deleted_at; }));
  var ro = theirs.length ? '<section class="list ro2"><p class="lab">' + pnx(pName() + '\u2019s') + '</p>' + theirs.map(function (x) {
    var resp = x.type === 'response';
    return '<div class="td-row"><span class="om">' + (resp ? '<svg><use href="#fa"/></svg>' : '') + '</span><div class="tx"><p>' + esc(x.title) + '</p>' + (x.type === 'habit' && x.target ? '<div class="pb"><i style="width:' + Math.min(100, Math.round(100 * x.tally / x.target)) + '%"></i></div>' : '') + '</div>' + (x.type === 'habit' ? '<span class="hv">' + (x.target ? x.tally + '/' + x.target : x.tally) + '</span>' : '') + '</div>';
  }).join('') + '</section>' : '';
  var sh = ui.sheet && ui.sheet.type === 'newtodo' ? newTodoSheet() : ui.sheet && ui.sheet.type === 'still' ? stillSheet() : '';
  return phone('p2 td' + (held.length ? ' hl' : ''), '<header class="hd"><div><h2>To do</h2><p class="dl">' + op.length + ' open</p></div><span class="fight" data-a="newtodo">Add</span></header>' + heldHtml +
    '<section class="list">' + (op.length ? op.map(row).join('') : '<p class="empty">None</p>') + '</section>' + ro, { tab: 'todo', sheet: sh });
};
function newTodoSheet() {
  var s = ui.sheet;
  return sheet('', '<div class="bsh"><h3>New to do</h3><span class="x" data-a="sheet:close">&#x2715;</span></div>' +
    inp('title', 'Title').replace('class="inp"', 'class="inp fill"') +
    '<div class="frow"><span class="lab0">For</span>' + seg([['me', 'You'], ['them', pn()]], s.who, 'nfor') + '</div>' +
    '<div class="frow"><span class="lab0">Type</span>' + seg([['task', 'Task'], ['habit', 'Habit']], s.kind, 'nkind') + '</div>' +
    (s.kind === 'task' ? '<div class="frow"><span class="lab0">Due</span><span class="chip' + (val('due') ? '' : ' on') + '" data-a="nodue">None</span>' + dpick('date', 'due', val('due')) + '</div>' : '') +
    (s.kind === 'habit' ? '<div class="frow"><span class="lab0">Target</span>' + stepper() + '</div><div class="frow"><span class="lab0">Ongoing</span><span class="tg' + (s.ongoing ? ' on' : '') + '" data-a="ongoing"><i></i></span></div>' : '') +
    '<div class="save" data-a="savetodo">Save</div>');
}

SCREEN.fight = function () {
  var d = ui.d, i = d.int || 3, chips = d.chips || {};
  var arrows = [1, 2, 3, 4, 5].map(function (n) {
    return '<span' + (n === i ? ' class="sel"' : ' style="color:#5e5e5e"') + ' data-a="int:' + n + '"><svg><use href="#' + (n === i ? 'arwh' : 'arw') + '"/></svg><b>' + n + '</b></span>';
  }).join('');
  var rew = d.rewritten ? '<div class="aff rew"><p class="lab">Rewritten</p><p>' + esc(d.rewritten) + '</p></div>' : '';
  return phone('p2 s2', '<header class="hd"><div><h2>Log a fight</h2></div><span class="txtbtn" data-a="back">Cancel</span></header>' +
    '<section><p class="lab">Intensity</p><div class="arrows">' + arrows + '</div><div class="ends"><span>Low</span><span>High</span></div></section>' +
    '<section><p class="lab">About<span class="tag">Only you</span></p>' + inp('about').replace('class="inp"', 'class="inp fill"') + '</section>' +
    '<section><p class="lab">Vent<span class="tag">This phone only</span></p><div class="ta"><textarea data-d="vent">' + esc(val('vent')) + '</textarea><span class="rw" data-a="rewrite">Rewrite</span></div></section>' + rew +
    '<section><p class="lab">To do</p><div class="tdc">' + [['apologize', 'Apologize'], ['reflect', 'Reflect'], ['custom', 'Custom']].map(function (c) { return '<span class="chip' + (chips[c[0]] ? ' on' : '') + '" data-a="chip:' + c[0] + '">' + c[1] + '</span>'; }).join('') + '</div>' +
    (chips.custom ? '<p class="lab">Title<span class="tag">Shared</span></p>' + inp('customTitle') : '') + '</section>' +
    '<div class="pair"><span class="save' + (d.rewritten ? '' : ' dis') + '" data-a="fightshare">Share with ' + pn() + '</span><span class="ghost" data-a="fightsave">Keep private</span></div>', { band: false, tab: 'home' });
};

SCREEN.us = function () {
  var t = today(), wk = C.weekStart(t), cks = L('checkins');
  var truths = L('items').filter(function (i) { return i.kind === 'truth' && i.recipient_id === St.me() && i.status === 'delivered' && !i.deleted_at; }).sort(byDelivered).slice(0, 3);
  var tr = truths.length ? truths.map(function (i) {
    var hl = C.heldLabel(i);
    return '<div class="tru"><p>' + esc(i.body) + '</p><p class="hm">' + (hl ? '<svg><use href="#hg"/></svg>' + hl + ' &middot; ' : '') + pnx(nameOf(i.sender_id)) + ' &middot; ' + dayName(C.localDay(C.ms(i.delivered_at), tz())) + '</p></div>';
  }).join('') : '<p class="empty">None</p>';
  var kept = L('items').filter(function (i) { return i.kind === 'kudos' && i.recipient_id === St.me() && i.kept === true; }).length;
  function strip(uid) {
    var cells = '';
    for (var n = 0; n < 7; n++) {
      var day = C.addDays(wk, n), f = cks.some(function (c) { return c.user_id === uid && c.day === day; });
      cells += '<i class="' + (f ? 'f' : day > t ? 'fut' : '') + '"></i>';
    }
    return cells;
  }
  var me = St.myMember();
  return phone('p2 s4 ur', '<header class="hd"><div><h2>Us</h2><p class="dl">This week</p></div><span class="gear" data-a="go:settings">' + ic('cog') + '</span></header>' +
    '<section><p class="lab">Truths</p>' + tr + '</section>' +
    '<section><p class="lab">Kudos</p><div class="ta ph"><textarea data-d="kudos" placeholder="For ' + esc(clip(pName(), 16)) + '">' + esc(val('kudos')) + '</textarea><span class="rw pk" data-a="sendkudos">Send</span></div></section>' +
    '<div class="cnt" data-a="go:kept"><span>Kept</span><span class="val">' + kept + ic('chevr', 'sm') + '</span></div>' +
    '<section class="wk"><p class="lab">Check-ins</p><div class="wr hdr"><span></span><b>M</b><b>T</b><b>W</b><b>T</b><b>F</b><b>S</b><b>S</b></div>' +
    '<div class="wr"><span>You</span>' + strip(St.me()) + '</div><div class="wr"><span>' + esc(pName()) + '</span>' + strip(St.partner() ? St.partner().user_id : '') + '</div></section>' +
    '<div class="srow" data-a="go:cycle"><span>Cycle</span>' + ic('chevr', 'sm') + '</div>', { tab: 'us' });
};

SCREEN.kept = function () {
  var ks = L('items').filter(function (i) { return i.kind === 'kudos' && i.recipient_id === St.me() && i.kept === true; }).sort(byDelivered);
  return phone('p2 hl2', '<header class="hd"><div>' + hdBack('Us') + '<h2>Kept</h2><p class="dl">' + ks.length + '</p></div></header><section class="list">' +
    (ks.map(function (i) { return '<div class="hr"><div class="tx"><div class="mt"><span class="tch">' + esc(nameOf(i.sender_id)) + '</span><span class="due">' + dayName(C.localDay(C.ms(i.delivered_at), tz())) + '</span></div><p>' + esc(i.body) + '</p></div></div>'; }).join('') || '<p class="empty">None</p>') + '</section>', { tab: 'us' });
};

SCREEN.kudos = function () {
  var i = S.rows.items[ui.itemId];
  var k = i.kind === 'kudos';
  return phone('p2 k4', '<header class="hd"><div><h2>' + KIND[i.kind] + '</h2><p class="dl">' + fmtDay(C.localDay(C.ms(i.delivered_at), tz())) + '</p></div><span class="gear" style="font-weight:700" data-a="back">&#x2715;</span></header>' +
    '<div class="card in"><span class="stk"><svg viewBox="0 0 48 48"><use href="#ah"/></svg></span><p class="q">' + esc(i.body) + '</p><p class="by">' + esc(nameOf(i.sender_id)) + ', ' + fmtTime(C.ms(i.delivered_at)) + '<svg class="px" viewBox="0 0 16 14"><use href="#px"/></svg></p><svg class="arr" viewBox="0 0 84 40"><use href="#sarr"/></svg></div>' +
    (k ? '<div class="pair"><span class="save" data-a="keep:1">Keep</span><span class="ghost" data-a="keep:0">Dismiss</span></div>' : '<div class="pair"><span class="save" data-a="back">Done</span></div>'), { tab: false });
};

SCREEN.today = function () {
  var t = today(), mine = S.priv.affirmations[0], focus = L('items').filter(function (i) { return i.kind === 'focus' && i.recipient_id === St.me() && i.status === 'delivered' && !i.deleted_at; }).sort(byDelivered)[0];
  var ex = L('checkins').filter(function (c) { return c.user_id === St.me() && c.day === t; })[0];
  if (ex && ui.d.did == null) { ui.d.did = ex.did_differently || ''; ui.d.want = ex.want_from || ''; }
  var yours = ui.d.editAff ? '<div class="ta"><textarea data-d="aff">' + esc(val('aff', mine)) + '</textarea></div>' : '<p class="mine">' + esc(mine || '') + '</p>';
  var fh = focus ? C.heldLabel(focus) : null;
  return phone('p2 s1', '<header class="hd"><div class="ttl"><span class="mark"><svg><use href="#arwh"/></svg></span><div><h2>Today</h2><p class="dl">' + fmtDay(t) + '</p></div></div><span class="fight" data-a="go:fight">Log fight</span></header>' +
    '<section class="yours"><p class="lab">Yours<span class="edit" data-a="' + (ui.d.editAff ? 'affsave' : 'affedit') + '">' + (ui.d.editAff ? 'Save' : 'Edit') + '</span></p>' + yours + '</section>' +
    (focus ? '<div class="aff"><p class="lab">From ' + pn() + '</p><p>' + esc(focus.body) + '</p>' + (fh ? '<small class="hm"><svg><use href="#hg"/></svg>' + fh + ' &middot; ' + fmtTime(C.ms(focus.delivered_at)) + '</small>' : '') + '</div>' : '') +
    '<section class="fields"><div><p class="lab">Do differently</p>' + inp('did', 'Optional') + '</div><div><p class="lab">Want from ' + pn() + '</p>' + inp('want', 'Optional') + '</div></section>' +
    '<div class="srow fur" data-a="tab:todo"><span>To do</span><span class="val">' + openTodos(myTodos()).length + ' open' + ic('chevr', 'sm') + '</span></div>' +
    '<div class="save" data-a="checkin">Save</div>', { tab: 'home' });
};

SCREEN.settings = function () {
  var me = St.myMember(), p = St.partner();
  var hrs = [[0, 'None'], [60, '1h'], [120, '2h'], [720, '12h'], [1440, '24h']];
  function hold(kind) { return '<div class="hrw2"><span class="hl0">' + KIND[kind] + '</span>' + seg(hrs, C.holdMinutes(S.couple, kind), 'hold' + kind, 'h5') + '</div>'; }
  return phone('p2 s5 st', '<header class="hd"><div>' + hdBack('Us') + '<h2>Settings</h2></div></header>' +
    '<section class="grp"><p class="lab">Check-in time</p><div class="srow"><span>Yours</span><label class="pick"><span>' + fmtHM(me.checkin_time) + '</span><input type="time" step="60" id="mytime" value="' + esc(hm5(me.checkin_time)) + '"></label></div>' +
    (p ? '<div class="srow ro"><span>' + pnx(p.name + '\u2019s') + '</span><span class="val">' + fmtHM(p.checkin_time) + '</span></div>' : '') + '</section>' +
    '<section class="grp"><p class="lab">Holds<span class="tag">Shared</span></p>' + hold('kudos') + hold('focus') + hold('truth') + hold('ask') + '</section>' +
    (St.hasNative ? '<div class="srow" data-a="facelock"><span>Face ID</span><span class="val">' + (ui.lockOn ? 'On' : 'Off') + '</span></div>' : '') +
    '<div class="srow" data-a="export"><span>Export</span>' + ic('chevr', 'sm') + '</div>' +
    '<span class="ghost out" data-a="signout">Sign out</span>', { tab: 'us' });
};

// ---- points family --------------------------------------------------------------------------------
SCREEN.points = function () {
  var led = ledger(), days = {};
  Object.keys(led.weeks).forEach(function (w) { Object.keys(led.weeks[w].days).forEach(function (d) { days[d] = days[d] || []; days[d] = days[d].concat(led.weeks[w].days[d].lines); }); });
  led.spends.forEach(function (s) { var rw = S.rows.rewards[s.reward_id]; (days[s.day] = days[s.day] || []).push({ pts: s.pts, label: 'Redeemed', who: rw ? rw.name : '' }); });
  // Same-day lines arrive in member-iteration order, which differs per phone; sort so both
  // partners read an identical ledger.
  Object.keys(days).forEach(function (d) { days[d].sort(function (a, b) { return b.pts - a.pts || a.label.localeCompare(b.label) || String(a.who).localeCompare(String(b.who)); }); });
  var html = Object.keys(days).sort().reverse().map(function (d) {
    var net = days[d].reduce(function (a, l) { return a + l.pts; }, 0);
    return '<div class="day"><div class="dh"><p class="lab">' + fmtDay(d) + '</p><p class="s">' + sg(net) + '</p></div>' + days[d].map(function (l) {
      return '<div class="ln' + (l.pts < 0 ? ' ls' : '') + '"><span class="am">' + sg(l.pts) + '</span><p class="t">' + esc(l.label) + (l.who ? ' <span>&middot; ' + esc(l.who) + '</span>' : '') + '</p></div>';
    }).join('') + '</div>';
  }).join('');
  return phone('pts', '<header class="hd"><div>' + ptsBack(backLabel()) + '<h2>Points</h2></div><span class="pillb" data-a="go:shop">Shop</span></header>' +
    '<div class="sum"><div><p class="lab">Balance</p><p class="big" id="balance">' + led.balance + '</p></div><div class="r"><p class="lab">This week</p><p class="big">' + sg(led.current.net) + '</p></div></div><div class="ledger">' + (html || '<p class="empty">None</p>') + '</div>', { tab: 'us' });
};

SCREEN.shop = function () {
  var led = ledger(), pend = L('redemptions').filter(function (r) { return r.status === 'pending'; });
  var items = L('rewards').filter(function (r) { return !r.archived; }).sort(function (a, b) { return a.price - b.price; }).map(function (r) {
    var isP = pend.some(function (p) { return p.reward_id === r.id; });
    return '<div class="it' + (r.price > led.balance ? ' no' : '') + '" data-a="reward:' + r.id + '"><span class="nm">' + esc(r.name) + '</span><span class="pr">' + (isP ? 'Pending' : r.price) + '</span></div>';
  }).join('');
  var sh = '';
  if (ui.sheet && ui.sheet.type === 'redeem') {
    var r = S.rows.rewards[ui.sheet.id];
    sh = sheet('', '<div class="bsh"><h3>' + esc(r.name) + '</h3><span class="xb" data-a="sheet:close">&#x2715;</span></div><p class="ask">Spend ' + r.price + '?</p><p class="to">' + led.balance + ' &rarr; ' + (led.balance - r.price) + '</p><div class="acts"><div class="save" data-a="redeem:' + r.id + '">Ask ' + pn() + '</div><div class="tdrop" data-a="sheet:close">Cancel</div></div>');
  } else if (ui.sheet && ui.sheet.type === 'addreward') {
    sh = sheet('', '<div class="bsh"><h3>Add</h3><span class="xb" data-a="sheet:close">&#x2715;</span></div>' + '<p class="lab">Reward</p>' + inp('rname').replace('class="inp"', 'class="inp fill"') + '<div class="frow"><span class="lab0">Price</span><input class="inp" type="number" inputmode="numeric" min="0" data-d="rprice" value="' + esc(val('rprice')) + '"></div><div class="save" data-a="savereward">Save</div>');
  }
  return phone('pts', '<header class="hd"><div>' + ptsBack('Points') + '<h2>Shop</h2></div><span class="bal" style="transform:translateY(-8px)">' + led.balance + '</span></header><div class="shop">' + items + '<div class="it add" data-a="addreward"><span class="nm">Add</span></div></div>', { tab: 'us', sheet: sh });
};

SCREEN.week = function () {
  var led = ledger(), w = led.current, g = C.groupWeek(w);
  function lines(a) { return a.map(function (x) { return '<div class="cl"><span class="am">' + sg(x.pts) + '</span><span class="t">' + esc(x.label) + '</span></div>'; }).join(''); }
  return phone('pts wc k4', '<header class="hd"><div><h2>Week</h2><p class="dl">' + fmtDay(today()) + '</p></div><span class="gear" data-a="weekdone">&#x2715;</span></header>' +
    '<div class="card in"><p class="q">Week &middot; ' + sg(w.net) + '</p>' + (g.earned.length ? '<div class="grp"><p class="lab">Earned</p>' + lines(g.earned) + '</div>' : '') + (g.lost.length ? '<div class="grp"><p class="lab">Lost</p>' + lines(g.lost) + '</div>' : '') +
    '<div class="nb"><p class="lab">Balance</p><b>' + led.balance + '</b></div></div><div class="pair"><span class="save" data-a="weekshop">Shop</span><span class="ghost" data-a="weekdone">Done</span></div>', { tab: false });
};

// ---- Cycle (private) screen -----------------------------------------------------------------------------
// Ring geometry and per-phase angles are measured from the approved mockup (degrees clockwise from top).
var SEG = { Fight: [4.3, 31.7], Cool: [40.3, 146.9], Warm: [155.5, 283.7], Tension: [292.3, 355.7] };
function pt(r, a) { var t = a * Math.PI / 180; return [173 + r * Math.sin(t), 143 - r * Math.cos(t)]; }
function ring(ph) {
  var out = '';
  Object.keys(SEG).forEach(function (n) {
    var a = SEG[n], p0 = pt(96, a[0]), p1 = pt(96, a[1]), mid = (a[0] + a[1]) / 2, lp = pt(122, mid), on = ph && ph.name === n;
    out += '<path d="M' + p0[0].toFixed(1) + ' ' + p0[1].toFixed(1) + 'A96 96 0 0 1 ' + p1[0].toFixed(1) + ' ' + p1[1].toFixed(1) + '" fill="none" stroke="' + (on ? '#ff2e88' : '#3a3a3a') + '" stroke-width="20"/>' +
      '<text x="' + lp[0].toFixed(1) + '" y="' + lp[1].toFixed(1) + '" font-size="13" fill="' + (on ? '#ff2e88' : '#bdbdbd') + '"' + (lp[0] > 173 ? '' : ' text-anchor="end"') + ' dominant-baseline="middle" letter-spacing="1.3">' + n.toUpperCase() + '</text>';
  });
  var mk = '', mid = 'NONE', sub = '';
  if (ph) {
    var a = SEG[ph.name], since = ph.day - 1, f;
    f = ph.name === 'Fight' ? .5 : ph.name === 'Cool' ? (since - 1) / 2 + .25 : ph.name === 'Warm' ? (since - 3) / Math.max(1, ph.warmEnd - 3) : (since - ph.warmEnd) / Math.max(1, ph.len - ph.warmEnd);
    var m = pt(96, a[0] + (a[1] - a[0]) * Math.max(0, Math.min(1, f)));
    mk = '<circle cx="' + m[0].toFixed(1) + '" cy="' + m[1].toFixed(1) + '" r="15" fill="#fff" stroke="#0a0a0a" stroke-width="4"/>';
    mid = ph.name.toUpperCase(); sub = 'DAY ' + ph.day;
  }
  return '<svg class="chart" viewBox="2 14 342 248" width="342" height="248">' + out + mk + '<text class="ab" x="173" y="139" font-size="26" fill="#fff" text-anchor="middle">' + mid + '</text>' +
    '<text x="173" y="167" font-size="16" fill="#bdbdbd" text-anchor="middle" letter-spacing="1">' + sub + '</text></svg>';
}
function fightRecs() { return S.priv.fights.slice().sort(function (a, b) { return b.at - a.at; }); }
function chipsFor(f) {
  var tds = L('todos').filter(function (t) { return t.fight_marker_id === f.id; }), out = '';
  var chk = '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>';
  tds.forEach(function (t) { out += '<span class="rc' + (t.done_at ? ' d' : '') + '">' + (t.done_at ? chk : '') + esc(t.title) + '</span>'; });
  if (f.shared) out += '<span class="rc d">' + chk + 'Rewrite shared</span>';
  return out;
}
function ix(n) { var s = ''; for (var i = 1; i <= 5; i++) s += '<i' + (i <= n ? ' class="f"' : '') + '></i>'; return '<span class="ix">' + s + '</span>'; }
SCREEN.cycle = function () {
  var fights = fightRecs(), n = now(), t = today();
  var ph = C.phase(fights, n, tz(), 14);
  if (!ui.cyc) { var p = t.split('-'); ui.cyc = { y: +p[0], m: +p[1], sel: fights[0] ? C.localDay(fights[0].at, tz()) : null }; }
  var cy = ui.cyc, grid = C.monthGrid(cy.y, cy.m), byDay = {};
  fights.forEach(function (f) { var d = C.localDay(f.at, tz()); byDay[d] = Math.max(byDay[d] || 0, f.intensity); });
  var cells = '';
  for (var b = 0; b < grid.blanks; b++) cells += '<i></i>';
  grid.days.forEach(function (d) {
    var inten = byDay[d], h = inten ? 14 + 5 * inten : 0;
    cells += '<div class="d' + (inten ? ' f' : '') + (d === cy.sel ? ' sel' : '') + (d === t ? ' now' : '') + '" data-a="day:' + d + '"><span class="num">' + (+d.slice(8)) + '</span>' + (inten ? '<svg width="' + (h * 40 / 56).toFixed(1) + '" height="' + h + '" viewBox="0 0 40 56"><use href="#arw"/></svg>' : '') + '</div>';
  });
  var selF = fights.filter(function (f) { return C.localDay(f.at, tz()) === cy.sel; })[0];
  var det = selF ? '<section class="det"><div class="meta"><span>' + dayName(cy.sel) + ' ' + (+cy.sel.slice(8)) + ' &middot; ' + fmtTime(selF.at) + '</span>' + ix(selF.intensity) + '</div><p>' + esc(selF.about || '') + '</p><div class="rcs">' + chipsFor(selF) + '</div></section>' : '';
  var recent = fights.slice(0, 4).map(function (f) {
    var d = C.localDay(f.at, tz());
    return '<div class="rf"><div class="meta"><span>' + dayName(d) + ' ' + (+d.slice(8)) + ' &middot; ' + fmtTime(f.at) + '</span>' + ix(f.intensity) + '</div><p>' + esc(f.about || '') + '</p><div class="rcs">' + chipsFor(f) + '</div></div>';
  }).join('');
  var last = fights[0];
  return phone('p2 cyc', '<header class="hd"><div>' + hdBack(backLabel()) + '<div class="hrow"><h2>Cycle</h2><span class="tag">Only you</span></div><p class="dl">' + fmtDay(t) + '</p></div></header>' +
    '<section class="ring">' + ring(ph) + '</section>' +
    '<section class="stats"><div><b>' + (ph && ph.avg != null ? ph.avg.toFixed(1) + ' d' : '—') + '</b><span>Avg cycle</span></div><div><b>' + (last ? dayName(C.localDay(last.at, tz())) + ' ' + fmtTime(last.at) : '—') + '</b><span>Last fight</span></div></section>' +
    '<section><div class="mon"><b>' + ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][cy.m - 1] + '</b><div class="nav"><span data-a="mon:-1">' + ic('chev') + '</span><span data-a="mon:1">' + ic('chevr') + '</span></div></div><div class="cal"><span class="wd">M</span><span class="wd">T</span><span class="wd">W</span><span class="wd">T</span><span class="wd">F</span><span class="wd">S</span><span class="wd">S</span>' + cells + '</div></section>' +
    det + (recent ? '<section><p class="lab h">Recent</p><div class="list">' + recent + '</div></section>' : '') + '<div class="endpad"></div>', { tab: 'us' });
};

// ---- render ------------------------------------------------------------------------------------------------
function currentScreen() {
  if (!S.session) return 'auth';
  if (!S.couple || ui.code) return 'setup';
  return ui.route;
}
function sheetHtml() { return ''; }
var lastKey = '';
function render() {
  if (!ui.ready) return;
  var sc = document.querySelector('.scr'), top = sc ? sc.scrollTop : 0, name = currentScreen(), key = name + (ui.sheet ? 's' : '');
  var html = SCREEN[name]();
  // Sheets are rendered inside the owning screen (so they inherit its family CSS); screens that
  // host sheets read ui.sheet themselves. Everything else shows the sheet via the shared hook below.
  if (ui.sheet && name !== 'todo' && name !== 'shop') html = html.replace(/<\/div>$/, sheetFor() + '</div>');
  app.innerHTML = html;
  var ns = document.querySelector('.scr');
  if (ns && lastKey.split('|')[0] === name) ns.scrollTop = top;
  markScrolled();
  lastKey = name + '|' + (ui.sheet ? 1 : 0);
}
// Once content scrolls, a solid strip covers the status area so nothing slides under the clock.
function markScrolled() { var sc = document.querySelector('.scr'), ph = document.querySelector('.phone'); if (sc && ph) ph.classList.toggle('sc', sc.scrollTop > 8); }
app.addEventListener('scroll', markScrolled, true);
// Keyboard: the page itself never scrolls; the app column shrinks to the visual viewport so the pinned primary pill stays above the keys.
if (window.visualViewport) {
  var vv = window.visualViewport;
  // scroll only pins (iOS fires it while revealing the caret; reacting there made a feedback loop). resize reveals via .scr.scrollTop alone, since element.scrollIntoView also scrolls the window.
  var pin = function () { if (window.scrollY || vv.offsetTop) window.scrollTo(0, 0); };
  var fit = function () {
    document.documentElement.style.setProperty('--vvh', vv.height + 'px'); pin();
    var a = document.activeElement, sc = document.querySelector('.scr');
    if (!typing() || !sc || !sc.contains(a)) return;
    var r = a.getBoundingClientRect(), v = sc.getBoundingClientRect();
    if (r.top < v.top) sc.scrollTop -= v.top - r.top + 12; else if (r.bottom > v.bottom) sc.scrollTop += r.bottom - v.bottom + 12;
  };
  vv.addEventListener('resize', fit); vv.addEventListener('scroll', pin);
}
function sheetFor() { return ui.sheet.type === 'still' ? stillSheet() : ''; }

// Re-render on store changes unless the user is typing.
function typing() { var a = document.activeElement; return a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA'); }
window.addEventListener('online', function () { if (ui.ready) render(); });
window.addEventListener('offline', function () { if (ui.ready) render(); });
St.on(function () { if (!ui.ready) return; if (typing()) ui.dirty = true; else render(); });
document.addEventListener('focusout', function () { setTimeout(function () { if (ui.dirty && !typing()) { ui.dirty = false; render(); } }, 0); });
app.addEventListener('input', function (e) {
  var k = e.target.getAttribute('data-d'); if (!k) return;
  ui.d[k] = e.target.value;
  var pt = e.target.getAttribute('data-pt');
  if (pt) e.target.previousElementSibling.textContent = dispPick(pt, e.target.value);
});

// ---- actions ---------------------------------------------------------------------------------------------------
function deliver(item) {
  St.patch('items', item.id, { status: 'delivered', delivered_at: nowIso() });
  if (item.kind === 'ask') St.insert('todos', C.askToTodo(S.rows.items[item.id], St.uuid(), now()));
}
function sendItem(kind, o) {
  var item = C.buildItem({ id: St.uuid(), couple: S.couple, me: St.me(), to: St.partner().user_id, kind: kind, body: o.body, ask_type: o.ask_type, due_date: o.due_date, target: o.target, origin: o.origin, response_type: o.response_type, now: now() });
  if (o.ongoing) item.target = null;
  St.insert('items', item);
  if (item.status === 'delivered' && kind === 'ask') St.insert('todos', C.askToTodo(item, St.uuid(), now()));
  return item;
}
function celebrate(item, el) { M.play(item.status === 'held' ? 'hold' : item.kind === 'kudos' ? 'kudos' : 'send', el); St.native.haptic('success'); }
function todoDone(t, el) {
  St.patch('todos', t.id, { done_at: nowIso() });
  St.insert('todo_events', { id: St.uuid(), couple_id: S.couple.id, todo_id: t.id, user_id: St.me(), kind: 'done', at: nowIso() });
  if (t.type === 'response') {
    var f = S.priv.fights.filter(function (x) { return x.id === t.fight_marker_id; })[0];
    if (f) { f.followed = true; St.savePriv(); }
    var mk = t.fight_marker_id && S.rows.fight_markers[t.fight_marker_id];
    if (mk && !mk.repaired_at) St.patch('fight_markers', mk.id, { repaired_at: nowIso() });
  }
  M.play('todo', el); St.native.haptic('success');
}
function logFight(share) {
  var d = ui.d, id = St.uuid(), at = now(), chips = d.chips || {}, el = document.querySelector('.pair .save');
  St.insert('fight_markers', { id: id, couple_id: S.couple.id, logged_by: St.me(), at: new Date(at).toISOString(), repaired_at: null });
  var titles = [];
  if (chips.apologize) titles.push('Apologize');
  if (chips.reflect) titles.push('Reflect');
  if (chips.custom && d.customTitle) titles.push(d.customTitle);
  titles.forEach(function (title) {
    St.insert('todos', { id: St.uuid(), couple_id: S.couple.id, owner_id: St.me(), created_by: St.me(), item_id: null, fight_marker_id: id, title: title, type: 'response', due_date: null, target: null, tally: 0, done_at: null, created_at: nowIso(), updated_at: nowIso(), deleted_at: null });
  });
  // Only the rewritten text may be shared; the vent and the About stay on this phone.
  if (share) sendItem('truth', { body: d.rewritten, origin: 'fight', response_type: chips.apologize ? 'apologize' : chips.reflect ? 'reflect' : 'custom' });
  S.priv.fights.push({ id: id, at: at, intensity: d.int || 3, about: d.about || '', vent: d.vent || '', rewritten: d.rewritten || '', shared: !!share });
  St.savePriv();
  M.play('crack', el);
  tab('home');
}

var ACT = {
  back: back,
  go: function (r) { go(r); },
  tab: tab,
  sheet: function () { ui.sheet = null; ui.d = {}; render(); },
  mode: function (m) { ui.mode = m; render(); },
  kind: function (k) { ui.kind = k; render(); },
  atype: function (k) { ui.atype = k; render(); },
  tgt: function (n) { ui.tgt = Math.max(1, ui.tgt + +n); render(); },
  signin: guard(async function () { await St.signIn(ui.d.email, ui.d.password); ui.d = {}; render(); }),
  signup: guard(async function () { await St.signUp(ui.d.email, ui.d.password); ui.d = {}; render(); }),
  signout: guard(async function () { await St.signOut(); ui.route = 'home'; ui.stack = []; ui.d = {}; render(); }),
  create: guard(async function () {
    if (!ui.d.name) throw new Error('Name needed');
    ui.code = await St.createCouple(ui.d.name, Intl.DateTimeFormat().resolvedOptions().timeZone);
    await setMember({ checkin_time: val('time', '21:00') }); render();
  }),
  join: guard(async function () {
    if (!ui.d.name || !ui.d.code) throw new Error('Name and code needed');
    await St.joinCouple(ui.d.code.trim().toUpperCase(), ui.d.name);
    await setMember({ checkin_time: val('time', '21:00') }); ui.d = {}; render();
  }),
  copycode: guard(async function () {
    await St.native.copy(ui.code);
    St.native.haptic('success');
    ui.copied = true; render();
    clearTimeout(ui.copiedTimer); ui.copiedTimer = setTimeout(function () { ui.copied = false; render(); }, 1500);
  }),
  sharecode: guard(function () { return St.native.shareText('Cycle code: ' + ui.code); }),
  codedone: function () { ui.code = null; ui.copied = false; ui.d = {}; render(); },
  row: function (id) { if (ui.reorder) return; go(id === 'fight' ? 'fight' : id); },
  reorderdone: function () { ui.reorder = false; render(); },
  decline: guard(function (id) { St.patch('redemptions', id, { status: 'declined', decided_by: St.me(), decided_at: nowIso() }); }),
  approve: guard(function (id) {
    var el = document.querySelector('.nc.tall'), price = S.rows.redemptions[id].price;
    St.patch('redemptions', id, { status: 'approved', decided_by: St.me(), decided_at: nowIso() });
    M.play('points', el, -price);
  }),
  still: function (id) { ui.sheet = stillHeld(id) ? { type: 'still', id: id } : null; ui.d = {}; render(); },
  edit: function (id) { ui.sheet.edit = true; render(); },
  editsave: guard(function (id) { var b = (ui.d.edit || '').trim(); if (!b) throw new Error('Message needed'); St.patch('items', id, { body: b }); ui.sheet.edit = false; ui.d = {}; render(); }),
  deliver: guard(function (id) { var el = document.querySelector('.bs .save'); deliver(S.rows.items[id]); M.play('send', el); ui.sheet = null; render(); }),
  drop: guard(function (id) { St.patch('items', id, { status: 'dropped' }); ui.sheet = null; render(); }),
  open: guard(function (id) {
    var i = S.rows.items[id];
    if (!i.opened_at) St.patch('items', id, { opened_at: nowIso() });
    go('kudos', { itemId: id });
  }),
  keep: guard(function (v) { var el = document.querySelector('.pair .save'); St.patch('items', ui.itemId, { kept: v === '1' }); if (v === '1') M.play('kudos', el); back(); }),
  sendit: guard(function () {
    var body = (ui.d.body || '').trim(); if (!body) { M.play('jiggle', document.querySelector('.ta')); throw new Error('Message needed'); }
    var el = document.querySelector('.p2.sd .save'), k = ui.kind;
    var item = sendItem(k, { body: body, ask_type: ui.atype, due_date: ui.d.due, target: ui.tgt });
    celebrate(item, el); ui.d = {}; render();
  }),
  sendkudos: guard(function () {
    var body = (ui.d.kudos || '').trim(); if (!body) return;
    var el = document.querySelector('.rw.pk'), item = sendItem('kudos', { body: body });
    celebrate(item, el); ui.d = {}; render();
  }),
  newtodo: function () { ui.sheet = { type: 'newtodo', who: 'me', kind: 'task', ongoing: false }; ui.d = {}; render(); },
  nfor: function (v) { ui.sheet.who = v; render(); },
  nkind: function (v) { ui.sheet.kind = v; render(); },
  nodue: function () { ui.d.due = ''; render(); },
  ongoing: function () { ui.sheet.ongoing = !ui.sheet.ongoing; render(); },
  savetodo: guard(function () {
    var s = ui.sheet, title = (ui.d.title || '').trim(); if (!title) throw new Error('Title needed');
    if (s.who === 'them') sendItem('ask', { body: title, ask_type: s.kind, due_date: s.kind === 'task' ? ui.d.due || null : null, target: ui.tgt, ongoing: s.kind === 'habit' && s.ongoing });
    else St.insert('todos', { id: St.uuid(), couple_id: S.couple.id, owner_id: St.me(), created_by: St.me(), item_id: null, fight_marker_id: null, title: title, type: s.kind, due_date: s.kind === 'task' ? ui.d.due || null : null, target: s.kind === 'habit' && !s.ongoing ? ui.tgt : null, tally: 0, done_at: null, created_at: nowIso(), updated_at: nowIso(), deleted_at: null });
    ui.sheet = null; ui.d = {}; render();
  }),
  done: guard(function (id) { todoDone(S.rows.todos[id], document.querySelector('[data-todo="' + id + '"] .om')); }),
  tally: guard(function (id) {
    var t = S.rows.todos[id], n = t.tally + 1, f = { tally: n }, el = document.querySelector('[data-todo="' + id + '"] .p1b');
    if (t.target && n >= t.target) f.done_at = nowIso();
    St.patch('todos', id, f);
    St.insert('todo_events', { id: St.uuid(), couple_id: S.couple.id, todo_id: id, user_id: St.me(), kind: 'tally', at: nowIso() });
    M.play('points', el, 1);
  }),
  int: function (n) { ui.d.int = +n; render(); },
  chip: function (c) { ui.d.chips = ui.d.chips || {}; ui.d.chips[c] = !ui.d.chips[c]; render(); },
  rewrite: guard(async function () {
    if (!(ui.d.vent || '').trim()) return;
    ui.d.rewritten = await St.rewrite(ui.d.vent); render();
  }),
  fightshare: guard(function () { if (!ui.d.rewritten) return; logFight(true); }),
  fightsave: guard(function () { logFight(false); }),
  affedit: function () { ui.d.editAff = true; render(); },
  affsave: function () { var v = (ui.d.aff || '').trim(); S.priv.affirmations[0] = v; St.savePriv(); ui.d.editAff = false; render(); },
  checkin: guard(function () {
    var el = document.querySelector('.p2.s1 .save'), t = today(), ex = L('checkins').filter(function (c) { return c.user_id === St.me() && c.day === t; })[0];
    var f = { did_differently: ui.d.did || null, want_from: ui.d.want || null };
    if (ex) St.patch('checkins', ex.id, f);
    else {
      St.insert('checkins', Object.assign({ id: St.uuid(), couple_id: S.couple.id, user_id: St.me(), day: t, created_at: nowIso(), updated_at: nowIso() }, f));
      M.play('points', el, 2);
    }
    tab('home');
  }),
  hold: guard(function (arg) { /* arg = kind:minutes */ }),
  mytime: function () {},
  facelock: guard(async function () { await St.native.lockSet(!ui.lockOn); ui.lockOn = await St.native.lockGet(); render(); }),
  export: guard(function () {
    var text = JSON.stringify(S.priv, null, 2);
    // WKWebView cannot download a blob URL, so inside the shell the export goes through the native share sheet.
    if (St.hasNative) return St.native.share({ filename: 'cycle-private.json', text: text });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type: 'application/json' })); a.download = 'cycle-private.json'; a.click();
  }),
  reward: function (id) {
    var r = S.rows.rewards[id], led = ledger();
    if (L('redemptions').some(function (x) { return x.reward_id === id && x.status === 'pending'; })) return;
    if (r.price > led.balance) { M.play('jiggle', document.querySelector('[data-a="reward:' + id + '"]')); return; }
    ui.sheet = { type: 'redeem', id: id }; render();
  },
  redeem: guard(function (id) {
    var r = S.rows.rewards[id];
    St.insert('redemptions', { id: St.uuid(), couple_id: S.couple.id, reward_id: id, price: r.price, requested_by: St.me(), status: 'pending', decided_by: null, decided_at: null, created_at: nowIso(), updated_at: nowIso() });
    ui.sheet = null; render();
  }),
  addreward: function () { ui.sheet = { type: 'addreward' }; ui.d = {}; render(); },
  savereward: guard(function () {
    var n = (ui.d.rname || '').trim(), p = parseInt(ui.d.rprice, 10);
    if (!n || !(p >= 0)) throw new Error('Name and price needed');
    St.insert('rewards', { id: St.uuid(), couple_id: S.couple.id, name: n, price: p, created_by: St.me(), archived: false, created_at: nowIso(), updated_at: nowIso() });
    ui.sheet = null; ui.d = {}; render();
  }),
  weekshop: function () { M.play('week'); prefs().weekSeen = ledger().current.start; St.savePriv(); ui.route = 'shop'; ui.stack = [{ route: 'home' }]; render(); },
  weekdone: function () { M.play('week'); prefs().weekSeen = ledger().current.start; St.savePriv(); tab('home'); },
  day: function (d) { ui.cyc.sel = d; render(); },
  mon: function (n) { var c = ui.cyc, m = c.m + +n; c.y += m < 1 ? -1 : m > 12 ? 1 : 0; c.m = m < 1 ? 12 : m > 12 ? 1 : m; render(); }
};

// Shared-setting writes go straight to REST (couples/members are not in the offline outbox).
async function setMember(f) {
  await St.api('PATCH', 'members?user_id=eq.' + St.me(), f, { Prefer: 'return=minimal' });
  Object.assign(St.myMember(), f); await St.persistNow(); St.reschedule(); St.emit();
}
async function setHold(kind, min) {
  var field = 'hold_' + kind + '_min';
  await St.api('PATCH', 'couples?id=eq.' + S.couple.id, (function (o) { o[field] = min; return o; })({}), { Prefer: 'return=minimal' });
  S.couple[field] = min; await St.persistNow(); St.emit();
}
['kudos', 'focus', 'truth', 'ask'].forEach(function (k) { ACT['hold' + k] = guard(function (m) { return setHold(k, +m); }); });

app.addEventListener('click', function (e) {
  var el = e.target.closest('[data-a]');
  if (!el || el.tagName === 'INPUT') return;
  if (ui.suppressClick) { ui.suppressClick = false; return; }
  var a = el.getAttribute('data-a'), i = a.indexOf(':'), name = i < 0 ? a : a.slice(0, i), arg = i < 0 ? undefined : a.slice(i + 1);
  if (!ACT[name]) throw new Error('no action ' + name);
  ACT[name](arg);
});
// Time input: change fires after the picker closes.
app.addEventListener('change', function (e) {
  if (e.target.id === 'mytime' && e.target.value) guard(function () { return setMember({ checkin_time: e.target.value }); })();
});

// ---- Home reorder: long-press a row, then drag ------------------------------------------------------------------
(function () {
  var timer = 0, drag = null, pid = 0, y0 = 0, pos = 0;
  function startDrag(row, y) { drag = { row: row, y: y }; row.classList.add('drag'); row.setPointerCapture(pid); }
  app.addEventListener('pointerdown', function (e) {
    var row = e.target.closest('.rows .row');
    if (!row) return;
    pid = e.pointerId; y0 = pos = e.clientY;
    if (!ui.reorder) {
      // Press-hold enters reorder mode and the same finger carries straight on into the drag.
      var id = row.getAttribute('data-id');
      timer = setTimeout(function () {
        timer = 0; ui.reorder = true; ui.suppressClick = true; render();
        startDrag(document.querySelector('.rows .row[data-id="' + id + '"]'), pos);
      }, 500);
      return;
    }
    startDrag(row, e.clientY);
  });
  app.addEventListener('pointermove', function (e) {
    pos = e.clientY;
    if (timer && Math.abs(pos - y0) > 10) { clearTimeout(timer); timer = 0; }
    if (!drag) return;
    drag.row.style.transform = 'translateY(' + (e.clientY - drag.y) + 'px) scale(1.03)';
    var rows = Array.prototype.slice.call(document.querySelectorAll('.rows .row')).filter(function (r) { return r !== drag.row; });
    var before = rows.filter(function (r) { var b = r.getBoundingClientRect(); return e.clientY < b.top + b.height / 2; })[0];
    var parent = drag.row.parentNode, y0r = drag.row.getBoundingClientRect().top;
    parent.insertBefore(drag.row, before || null);
    drag.y += y0r - drag.row.getBoundingClientRect().top; // keep the row under the finger after the DOM move
    drag.row.style.transform = 'translateY(' + (e.clientY - drag.y) + 'px) scale(1.03)';
  });
  function end() {
    clearTimeout(timer); timer = 0;
    if (!drag) return;
    prefs().rows = Array.prototype.map.call(document.querySelectorAll('.rows .row'), function (r) { return r.getAttribute('data-id'); });
    St.savePriv(); drag = null; render();
  }
  app.addEventListener('pointerup', end); app.addEventListener('pointercancel', end);
})();

// ---- Back swipe: drag from the left edge, as in a UINavigationController -------------------------------------------
// Works wherever back() has somewhere to go: a pushed screen, or a non-tab screen opened from a notification (Today).
function canBack() { return !!(S.session && S.couple && !ui.sheet && (ui.stack.length || ['home', 'todo', 'us'].indexOf(ui.route) < 0)); }
(function () {
  var EDGE = 24, sw = null;
  function ph() { return document.querySelector('.phone'); }
  function place(p, dx) { p.style.transform = 'translateX(' + dx + 'px)'; p.style.opacity = 1 - dx / p.offsetWidth / 2; }
  app.addEventListener('touchstart', function (e) {
    var t = e.touches[0];
    sw = e.touches.length === 1 && t.clientX <= EDGE && canBack() ? { x: t.clientX, y: t.clientY, dx: 0, v: 0, t: e.timeStamp, on: false } : null;
  }, { passive: true });
  app.addEventListener('touchmove', function (e) {
    if (!sw) return;
    var t = e.touches[0], dx = Math.max(0, t.clientX - sw.x), dy = Math.abs(t.clientY - sw.y);
    if (!sw.on) {
      if (dy > 10 && dy > dx) { sw = null; return; }
      if (dx < 10) return;
      sw.on = true; if (typing()) document.activeElement.blur();
    }
    e.preventDefault();
    sw.v = (dx - sw.dx) / Math.max(1, e.timeStamp - sw.t); sw.t = e.timeStamp; sw.dx = dx;
    place(ph(), dx);
  }, { passive: false });
  function end() {
    var s = sw; sw = null;
    if (!s || !s.on) return;
    var p = ph(), w = p.offsetWidth, leave = s.dx > w / 3 || s.v > 0.5;
    p.style.transition = 'transform .2s ease-out, opacity .2s ease-out';
    place(p, leave ? w : 0);
    setTimeout(function () { if (leave) back(); else { p.style.transition = p.style.transform = p.style.opacity = ''; } }, 200);
  }
  app.addEventListener('touchend', end); app.addEventListener('touchcancel', end);
})();

// ---- native routes ---------------------------------------------------------------------------------------------------
// cycleNative exists from the first script tick so the shell can call route() at any time;
// routes that arrive before boot finishes wait in routeQ and apply once the UI is ready.
var routeQ = [];
function applyRoute(r) {
  if (!S.session || !S.couple) return;
  var m = /^held\/(.+)$/.exec(r);
  if (m) { ui.stack = []; ui.route = 'todo'; ui.sheet = stillHeld(m[1]) ? { type: 'still', id: m[1] } : null; ui.d = {}; render(); }
  else if (r === 'today') { ui.stack = []; ui.route = 'today'; ui.d = {}; ui.sheet = null; render(); }
  else if (r === 'log-followup') tab('todo');
  else throw new Error('unknown route ' + r);
}
window.cycleNative = {
  route: function (r) { if (ui.ready) applyRoute(r); else routeQ.push(r); },
  ready: function () { while (ui.ready && routeQ.length) applyRoute(routeQ.shift()); },
  foreground: function () { if (S.session) St.sync(); render(); }
};

// ---- boot --------------------------------------------------------------------------------------------------------------
St.boot().then(function () { return St.hasNative ? St.native.lockGet() : false; }).then(function (lockOn) {
  ui.lockOn = lockOn; ui.ready = true; render(); window.cycleNative.ready();
  // No realtime channel: poll while visible (cursor-based, so a quiet poll is 9 tiny GETs), plus the
  // 15s repaint that moves countdowns and promotes a held item to "ready".
  setInterval(function () { if (document.visibilityState === 'visible' && S.session) St.sync(); }, 5000);
  setInterval(function () { if (!typing()) render(); }, 15000);
  document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible') window.cycleNative.foreground(); });
});
})();

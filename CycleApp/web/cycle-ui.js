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
  reorder: false, dirty: false, ready: false, cyc: null, tgt: 10,
  mode: 'create', code: null, todoTab: 'all',
  ntier: 'esme', tip: false, nid: null, nedit: null, nfor: 'esme', sendId: null
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
function dispPick(v) { return !v ? 'Pick' : fmtDay(v); }
// Date fields are a pill showing the formatted value with the native input transparent over it,
// so the shown text never carries seconds or the platform's own layout.
function dpick(type, k, v, cls) {
  return '<label class="pick dp ' + (cls || '') + '"><span class="pv">' + esc(dispPick(v)) + '</span><input type="' + type + '"' + ' data-d="' + k + '" data-pt="' + type + '" value="' + esc(v) + '"></label>';
}
function clip(s, n) { return s.length > n ? s.slice(0, n - 1) + '\u2026' : s; }
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
  return C.computeLedger({ members: S.members, items: L('items'), todos: L('todos'), todo_events: L('todo_events'), fight_markers: L('fight_markers'), redemptions: L('redemptions'), nudge_sends: L('nudge_sends'), nudge_awards: L('nudge_awards') },
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
function tabFor(r) { return r === 'todo' ? 'todo' : ['us', 'points', 'shop', 'settings', 'cycle'].indexOf(r) >= 0 ? 'us' : 'home'; }
function backLabel() { var p = ui.stack[ui.stack.length - 1]; return { home: 'Today', us: 'Us', points: 'Points', todo: 'To do', settings: 'Settings', nudges: 'Nudges', nudge: 'Nudge', nudgedone: 'Done' }[p && p.route] || 'Today'; }
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
      '<section><p class="lab">Code</p><p class="code" id="invite-code" style="--n:' + ui.code.length + '">' + esc(ui.code) + '</p>' +
      '<div class="pair two"><span class="ghost" id="copy-code" data-a="copycode">' + (ui.copied ? 'Copied' : 'Copy') + '</span><span class="ghost" data-a="sharecode">Share</span></div></section>' +
      '<div class="save" data-a="codedone">Continue</div>', { tab: false });
  }
  var c = ui.mode === 'create';
  return phone('p2 au', '<header class="hd"><div><h2>Couple</h2></div></header>' +
    seg([['create', 'Create'], ['join', 'Join']], ui.mode, 'mode') +
    '<section><p class="lab">Your name</p>' + inp('name') + '</section>' +
    (c ? '' : '<section><p class="lab">Code</p>' + inp('code', '', 'autocapitalize="characters" maxlength="12"') + '</section>') +
    '<div class="save" data-a="' + (c ? 'create' : 'join') + '">' + (c ? 'Create couple' : 'Join couple') + '</div>' +
    '<span class="ghost out" data-a="signout">Sign out</span>', { tab: false });
};

function rowsOrder() {
  // A saved order from an older row set (pre-Nudges, or one still holding the removed Send row) no
  // longer matches; checking membership, not just length, keeps a stale same-length order from rendering
  // a row with no label or screen.
  var def = ['nudges', 'todo', 'fight'], o = prefs().rows;
  return o && o.length === def.length && def.every(function (id) { return o.indexOf(id) >= 0; }) ? o : def;
}
function rowMeta(id) {
  if (id === 'nudges') {
    // A queued send to the partner shows the moon tag; otherwise the size of the library.
    if (nudgeTier('esme').sends.some(isQueued)) return '<span class="tmr">' + ic('moon') + 'Tmrw 8 am</span>';
    return nudgeTier('esme').nudges.filter(live).length + ' saved';
  }
  if (id === 'todo') return openTodos(myTodos()).length + ' open';
  var f = S.priv.fights.slice().sort(function (a, b) { return b.at - a.at; })[0];
  if (!f) return 'None';
  var d = C.localDay(f.at, tz());
  return d === today() ? 'Today' : d === C.addDays(today(), -1) ? 'Yesterday' : 'Last ' + dayName(d);
}
var ROWLAB = { nudges: 'Nudges', todo: 'To do', fight: 'Log fight' };

SCREEN.home = function () {
  var led = ledger(), t = today();
  var cards = C.needsYou({ me: St.me(), now: now(), tz: tz(), items: L('items'), redemptions: L('redemptions'), members: S.members,
    nudge_sends: L('nudge_sends'), nudge_replies: L('nudge_replies') });
  var html = cards.map(function (n) {
    if (n.type === 'ready') {
      return '<div class="nc pk" data-a="still:' + n.item.id + '"><div class="mid"><p class="s">Still send? &middot; ' + n.count + ' ready</p><p class="x">' + esc(itemTitle(n.item)) + '</p></div><span class="go">Send</span></div>';
    }
    if (n.type === 'approve') {
      var rw = S.rows.rewards[n.redemption.reward_id];
      return '<div class="nc pk tall"><div class="mid"><p class="s">' + pnx(nameOf(n.redemption.requested_by)) + '</p><p class="x">' + esc(rw ? rw.name : '') + ' &middot; ' + n.redemption.price + '</p></div><div class="two"><span class="go" data-a="approve:' + n.redemption.id + '">Approve</span><span class="go o" data-a="decline:' + n.redemption.id + '">Decline</span></div></div>';
    }
    if (n.type === 'nudge') {
      return '<div class="nc" data-a="nudgein:' + n.send.id + '"><div class="mid"><p class="s">From ' + pnx(nameOf(n.send.sender_id)) + '</p><p class="x">' + esc(n.send.body) + '</p></div>' + ic('chevr', 'chv') + '</div>';
    }
    // n.type === 'reply': a reply from the other person on one of the nudge threads.
    return '<div class="nc" data-a="replyopen:' + n.reply.send_id + '"><div class="mid"><p class="s">Reply from ' + pnx(nameOf(n.reply.author_id)) + '</p><p class="x">' + esc(n.reply.body) + '</p></div>' + ic('chevr', 'chv') + '</div>';
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

function stepper() {
  return '<div class="stp"><span data-a="tgt:-1"><svg class="ic sm"><path d="M6 12h12"/></svg></span><b>' + ui.tgt + '</b><span data-a="tgt:1">' + ic('plus', 'sm') + '</span></div>';
}

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

function tdDesc(x) { return x.description ? '<p class="tdd">' + esc(x.description) + '</p>' : ''; }
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
      return '<div class="td-row" data-todo="' + x.id + '"><span class="om">' + om + '</span><div class="tx"><p>' + esc(x.title) + '</p>' + tdDesc(x) + bar + '</div><span class="hv">' + (x.target ? x.tally + '/' + x.target : x.tally) + '</span><span class="p1b" data-a="tally:' + x.id + '">+1</span></div>';
    }
    return '<div class="td-row" data-todo="' + x.id + '"><span class="om">' + om + '</span><div class="tx"><p>' + esc(x.title) + '</p>' + tdDesc(x) + due + '</div><span class="done" data-a="done:' + x.id + '">Done</span></div>';
  }
  var heldHtml = held.length ? '<section class="list held"><p class="lab">Held</p>' + held.map(function (i) {
    var rd = C.ms(i.held_until) <= now();
    return '<div class="td-row hrow2"><span class="om"><svg class="hold-ic"><use href="#hg"/></svg></span><p class="ht">' + esc(itemTitle(i)) + '</p><p class="hm2">To ' + pn() + '</p><div class="hact"><span class="cd">' + C.countdown(C.ms(i.held_until), now()) + '</span><span class="elink" data-a="still:' + i.id + '">' + (rd ? 'Send' : 'Edit') + '</span></div></div>';
  }).join('') + '</section>' : '';
  var theirs = openTodos(L('todos').filter(function (x) { return x.owner_id !== St.me() && !x.deleted_at; }));
  var ro = theirs.length ? '<section class="list ro2"><p class="lab">' + pnx(pName() + '\u2019s') + '</p>' + theirs.map(function (x) {
    var resp = x.type === 'response';
    return '<div class="td-row"><span class="om">' + (resp ? '<svg><use href="#fa"/></svg>' : '') + '</span><div class="tx"><p>' + esc(x.title) + '</p>' + tdDesc(x) + (x.type === 'habit' && x.target ? '<div class="pb"><i style="width:' + Math.min(100, Math.round(100 * x.tally / x.target)) + '%"></i></div>' : '') + '</div>' + (x.type === 'habit' ? '<span class="hv">' + (x.target ? x.tally + '/' + x.target : x.tally) + '</span>' : '') + '</div>';
  }).join('') + '</section>' : '';
  var sh = ui.sheet && ui.sheet.type === 'newtodo' ? newTodoSheet() : ui.sheet && ui.sheet.type === 'still' ? stillSheet() : '';
  return phone('p2 td' + (held.length ? ' hl' : ''), '<header class="hd"><div><h2>To do</h2><p class="dl">' + op.length + ' open</p></div><span class="fight" data-a="newtodo">Add</span></header>' + heldHtml +
    '<section class="list">' + (op.length ? op.map(row).join('') : '<p class="empty">None</p>') + '</section>' + ro, { tab: 'todo', sheet: sh });
};
function newTodoSheet() {
  var s = ui.sheet;
  return sheet('', '<div class="bsh"><h3>New to do</h3><span class="x" data-a="sheet:close">&#x2715;</span></div>' +
    inp('title', 'Title').replace('class="inp"', 'class="inp fill"') +
    '<div class="ta msg"><textarea data-d="desc" placeholder="Description (optional)">' + esc(val('desc')) + '</textarea></div>' +
    // No For row until the partner has joined: a partner-bound ask needs their user id (sendItem would throw).
    (St.partner() ? '<div class="frow"><span class="lab0">For</span>' + seg([['me', 'You'], ['them', pn()]], s.who, 'nfor') + '</div>' : '') +
    '<div class="frow"><span class="lab0">Type</span>' + seg([['task', 'Task'], ['habit', 'Habit']], s.kind, 'nkind') + '</div>' +
    (s.kind === 'task' ? '<div class="frow"><span class="lab0">Due</span><span class="chip' + (val('due') ? '' : ' on') + '" data-a="nodue">None</span>' + dpick('date', 'due', val('due')) + '</div>' : '') +
    (s.kind === 'habit' ? '<div class="frow"><span class="lab0">Ongoing</span><span class="tg' + (s.ongoing ? ' on' : '') + '" data-a="ongoing"><i></i></span></div>' + (s.ongoing ? '' : '<div class="frow"><span class="lab0">Target</span>' + stepper() + '</div>') : '') +
    '<div class="save" data-a="savetodo">Save</div>');
}

// Single-choice Yes/No chips for a Log fight question; tapping the selected chip clears it.
function yn(k) {
  return '<div class="tdc">' + [['yes', 'Yes'], ['no', 'No']].map(function (c) { return '<span class="chip' + (ui.d[k] === c[0] ? ' on' : '') + '" data-a="yn:' + k + ':' + c[0] + '">' + c[1] + '</span>'; }).join('') + '</div>';
}
function ynVal(v) { return v === 'yes' ? true : v === 'no' ? false : null; }
SCREEN.fight = function () {
  var d = ui.d, i = d.int || 3, chips = d.chips || {};
  var arrows = [1, 2, 3, 4, 5].map(function (n) {
    return '<span' + (n === i ? ' class="sel"' : ' style="color:#5e5e5e"') + ' data-a="int:' + n + '"><svg><use href="#' + (n === i ? 'arwh' : 'arw') + '"/></svg><b>' + n + '</b></span>';
  }).join('');
  var rew = d.rewritten ? '<div class="aff rew"><p class="lab">Rewritten</p><p>' + esc(d.rewritten) + '</p></div>' : '';
  return phone('p2 s2', '<header class="hd"><div><h2>Log a fight</h2></div><span class="txtbtn" data-a="back">Cancel</span></header>' +
    '<section><p class="lab">Intensity</p><div class="arrows">' + arrows + '</div><div class="ends"><span>Low</span><span>High</span></div></section>' +
    '<section><p class="lab">Did she hit herself?</p>' + yn('hit') +
    (d.hit === 'yes' ? '<div class="ck' + (d.hitNot ? ' on' : '') + '" data-a="hitnot"><i></i><span>Click here if it was not related to you</span></div>' : '') + '</section>' +
    '<section><p class="lab">About<span class="tag">Only you</span></p>' + inp('about').replace('class="inp"', 'class="inp fill"') + '</section>' +
    '<section><p class="lab">Vent<span class="tag">This phone only</span></p><div class="ta"><textarea data-d="vent">' + esc(val('vent')) + '</textarea><span class="rw" data-a="rewrite">Rewrite</span></div></section>' + rew +
    '<section><p class="lab">To do</p><div class="tdc">' + [['apologize', 'Apologize'], ['reflect', 'Reflect'], ['custom', 'Custom']].map(function (c) { return '<span class="chip' + (chips[c[0]] ? ' on' : '') + '" data-a="chip:' + c[0] + '">' + c[1] + '</span>'; }).join('') + '</div>' +
    (chips.custom ? '<p class="lab">Title<span class="tag">Shared</span></p>' + inp('customTitle') : '') + '</section>' +
    '<div class="pair"><span class="save' + (d.rewritten ? '' : ' dis') + '" data-a="fightshare">Share with ' + pn() + '</span><span class="ghost" data-a="fightsave">Keep private</span></div>', { band: false, tab: 'home' });
};

SCREEN.us = function () {
  var truths = L('items').filter(function (i) { return i.kind === 'truth' && i.recipient_id === St.me() && i.status === 'delivered' && !i.deleted_at; }).sort(byDelivered).slice(0, 3);
  var tr = truths.length ? truths.map(function (i) {
    var hl = C.heldLabel(i);
    return '<div class="tru"><p>' + esc(i.body) + '</p><p class="hm">' + (hl ? '<svg><use href="#hg"/></svg>' + hl + ' &middot; ' : '') + pnx(nameOf(i.sender_id)) + ' &middot; ' + dayName(C.localDay(C.ms(i.delivered_at), tz())) + '</p></div>';
  }).join('') : '<p class="empty">None</p>';
  return phone('p2 s4 ur', '<header class="hd"><div><h2>Us</h2></div><span class="gear" data-a="go:settings">' + ic('cog') + '</span></header>' +
    '<section><p class="lab">Truths</p>' + tr + '</section>' +
    '<div class="srow" data-a="go:cycle"><span>Cycle</span>' + ic('chevr', 'sm') + '</div>', { tab: 'us' });
};

SCREEN.settings = function () {
  var hrs = [[0, 'None'], [60, '1h'], [120, '2h'], [720, '12h'], [1440, '24h']];
  function hold(kind) { return '<div class="hrw2"><span class="hl0">' + KIND[kind] + '</span>' + seg(hrs, C.holdMinutes(S.couple, kind), 'hold' + kind, 'h5') + '</div>'; }
  return phone('p2 s5 st', '<header class="hd"><div>' + hdBack('Us') + '<h2>Settings</h2></div></header>' +
    '<section class="grp"><p class="lab">Holds<span class="tag">Shared</span></p>' + hold('truth') + hold('ask') + '</section>' +
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

// ---- Nudges ---------------------------------------------------------------------------------------------------
// Two tiers share one code path. 'esme' = the synced tables (author-only library, one send row per
// delivery, replies on a send). 'me' = the same row shapes held in S.priv, which never reaches Supabase:
// a Me send has recipient = me and no replies. Every helper takes the tier so no screen forks on it.
var TIP_TEXT = 'After 8 pm, it goes out tomorrow at 8 am.';
function live(n) { return !n.deleted_at && !n.archived_at; }
function isQueued(s) { return !s.deleted_at && C.ms(s.deliver_at) > now(); }
function nudgeTier(tier) {
  if (tier === 'me') return { nudges: S.priv.nudges, sends: S.priv.nudge_sends.filter(function (s) { return !s.deleted_at; }) };
  return { nudges: L('nudges').filter(function (n) { return n.author_id === St.me(); }), sends: L('nudge_sends').filter(function (s) { return s.sender_id === St.me() && !s.deleted_at; }) };
}
function nudgeRow(tier, id) { return tier === 'me' ? S.priv.nudges.filter(function (x) { return x.id === id; })[0] : S.rows.nudges[id]; }
function nPatch(tier, id, f) {
  if (tier === 'me') { Object.assign(nudgeRow('me', id), f, { updated_at: nowIso() }); St.savePriv(); } else St.patch('nudges', id, f);
}
function findSend(id) { return S.rows.nudge_sends[id] || S.priv.nudge_sends.filter(function (s) { return s.id === id; })[0]; }
function myTz() { return St.myMember().tz || S.couple.tz; }
// The recipient's clock decides what "8 am" means, so a partner in another zone still gets it at 8 am their time.
function recipientTz(tier) { var p = tier === 'me' ? null : St.partner(); return (p && p.tz) || myTz(); }
// True when sending right now would be deferred to tomorrow morning (the 8 pm rule).
function isLate(tier) { var n = now(); return C.deliverAt(n, myTz(), recipientTz(tier)) > n; }
// Writes the send row for a nudge. The body is a snapshot so a later library edit never rewrites what was sent.
function doSend(tier, nudge) {
  var n = now(), at = C.deliverAt(n, myTz(), recipientTz(tier));
  var row = { id: St.uuid(), nudge_id: nudge.id, sender_id: St.me(), recipient_id: tier === 'me' ? St.me() : St.partner().user_id, body: nudge.body,
    deliver_at: new Date(at).toISOString(), opened_at: null, created_at: nowIso(), updated_at: nowIso(), deleted_at: null };
  if (tier === 'me') { S.priv.nudge_sends.push(row); St.savePriv(); St.reschedule(); }
  else { row.couple_id = S.couple.id; St.insert('nudge_sends', row); }
  return row;
}
function ago(ms) {
  var d = C.dayDiff(C.localDay(ms, tz()), today());
  return d <= 0 ? 'today' : d === 1 ? 'yesterday' : d + ' days ago';
}
function repliesFor(sendIds) {
  return L('nudge_replies').filter(function (r) { return sendIds[r.send_id] && !r.deleted_at; }).sort(function (a, b) { return C.ms(a.created_at) - C.ms(b.created_at); });
}
function idSet(sends) { var o = {}; sends.forEach(function (s) { o[s.id] = true; }); return o; }
// Everything that was sent from one nudge, as the current user sees it: the sender's own sends, or for the
// recipient only the delivered ones (the server hides the rest anyway).
function sendsOfNudge(nudgeId) {
  return L('nudge_sends').filter(function (s) { return s.nudge_id === nudgeId && !s.deleted_at && (s.sender_id === St.me() || C.ms(s.deliver_at) <= now()); });
}
function markRead(sendIds) {
  repliesFor(sendIds).filter(function (r) { return r.author_id !== St.me() && !r.read_at; }).forEach(function (r) { St.patch('nudge_replies', r.id, { read_at: nowIso() }); });
}
// The award behind a done nudge (one per nudge: Done is offered once, and a done nudge leaves the library).
function awardOf(nudgeId) { return L('nudge_awards').filter(function (a) { return a.nudge_id === nudgeId && !a.deleted_at; })[0]; }
function fmtShort(day) { var p = day.split('-'); return (+p[2]) + ' ' + MON[+p[1] - 1]; }
// "10 of 30 paid . next 26 Nov" while paying out, "30 paid . 3 Sep" when complete, "10 of 30 paid . stopped" when cut.
function paidText(a) {
  var st = C.awardStatus(a, today(), tz());
  return (st.complete ? st.total + ' paid' : st.paid + ' of ' + st.total + ' paid') + (st.stopped ? ' \u00b7 stopped' : st.complete ? ' \u00b7 ' + fmtShort(st.last) : ' \u00b7 next ' + fmtShort(st.next));
}
// Row meta: sent/added/queued · reply count with a pink dot while any reply is unread.
function nudgeMeta(tier, n) {
  if (n.done_at) return paidText(awardOf(n.id));
  var ss = nudgeTier(tier).sends.filter(function (s) { return s.nudge_id === n.id; });
  var last = ss.filter(function (s) { return !isQueued(s); }).sort(function (a, b) { return C.ms(b.created_at) - C.ms(a.created_at); })[0];
  var what = ss.some(isQueued) ? 'queued' : last ? 'sent ' + ago(C.ms(last.created_at)) : 'added ' + ago(C.ms(n.created_at));
  var html = esc(what);
  if (tier === 'me') return html;
  var reps = repliesFor(idSet(ss));
  if (!reps.length) return html;
  var unread = reps.some(function (r) { return r.author_id !== St.me() && !r.read_at; });
  return html + ' · <span class="rcn">' + reps.length + (reps.length === 1 ? ' reply' : ' replies') + (unread ? '<i class="dotn"></i>' : '') + '</span>';
}

SCREEN.nudges = function () {
  var tier = ui.ntier, T = nudgeTier(tier), sec = C.sectionNudges(T.nudges, T.sends);
  function row(n, grip) {
    var q = T.sends.some(function (s) { return s.nudge_id === n.id && isQueued(s); });
    var right = (q ? '<span class="tmr">' + ic('moon', 'moon') + 'Tmrw</span>' : '') + (grip ? '<svg class="ic gr" data-a="noop" data-grip="1"><use href="#grip"/></svg>' : '');
    return '<div class="rem c' + (q ? ' t' : '') + '" data-nid="' + n.id + '" data-a="nudge:' + n.id + '"><div><p>' + esc(n.body) + '</p><small>' + nudgeMeta(tier, n) + '</small></div>' + (right ? '<div class="rt">' + right + '</div>' : '') + '</div>';
  }
  function group(label, list, key, grip) {
    return list.length ? '<div class="lst" data-sec="' + key + '"><p class="lab">' + label + '</p>' + list.map(function (n) { return row(n, grip); }).join('') + '</div>' : '';
  }
  var total = sec.pinned.length + sec.recent.length + sec.all.length, all = total + sec.done.length;
  return phone('p2 nd', '<header class="hd"><div>' + hdBack(backLabel()) + '<h2>Nudges</h2><p class="dl">' + total + ' saved</p></div><span class="plus" data-a="nudgenew">' + ic('plus') + '</span></header>' +
    seg([['esme', pn()], ['me', 'Me']], tier, 'ntier') +
    (all ? group('Pinned', sec.pinned, 'pinned', true) + group('Recent', sec.recent, 'recent', false) + group('All', sec.all, 'all', true) + group('Done', sec.done, 'done', false) : '<p class="empty">None</p>'), { tab: false });
};

function thread(sends) {
  // Replies grouped under the date their nudge went out; sends without replies are skipped.
  return sends.slice().sort(function (a, b) { return C.ms(a.deliver_at) - C.ms(b.deliver_at); }).map(function (s) {
    var reps = repliesFor(idSet([s]));
    if (!reps.length) return '';
    var p = C.localDay(C.ms(s.deliver_at), tz()).split('-');
    return '<p class="when">' + (+p[2]) + ' ' + MON[+p[1] - 1] + '</p>' + reps.map(function (r) {
      var mine = r.author_id === St.me();
      return '<div class="bub ' + (mine ? 'me' : 'her') + '">' + esc(r.body) + '<small>' + esc(mine ? 'You' : nameOf(r.author_id)) + ' · ' + fmtTime(C.ms(r.created_at)) + '</small></div>';
    }).join('');
  }).join('');
}
function replyBox() {
  return '<div class="cmp"><input class="in" data-d="reply" value="' + esc(val('reply')) + '" placeholder="Reply"><span class="go2" data-a="nreply">' + ic('up') + '</span></div>';
}
// Where a reply typed on the current screen goes: the opened send, or the latest delivered send of the open nudge.
function replyTarget() {
  if (ui.route === 'nudgein') return findSend(ui.sendId);
  return sendsOfNudge(ui.nid).filter(function (s) { return !isQueued(s); }).sort(function (a, b) { return C.ms(b.deliver_at) - C.ms(a.deliver_at); })[0];
}

// Library row opened: its actions (Send / Pin / Edit / Archive) above the reply thread and a reply box.
SCREEN.nudge = function () {
  var tier = ui.ntier, n = nudgeRow(tier, ui.nid), sends = nudgeTier(tier).sends.filter(function (s) { return s.nudge_id === n.id; });
  var late = isLate(tier), shared = tier === 'esme', aw = n.done_at && awardOf(n.id);
  var thr = shared ? '<div class="th">' + thread(sends) + '</div>' + (replyTarget() ? replyBox() : '') : '';
  if (aw) {
    // Done card: Send again is a normal send (8 pm rule applies) and the nudge stays in Done.
    var st = C.awardStatus(aw, today(), tz());
    return phone('p2 nd', '<header class="hd"><div>' + hdBack(backLabel()) + '<h2>Nudges</h2><p class="dl">' + (sends.length ? 'Sent ' + sends.length + (sends.length === 1 ? ' time' : ' times') : 'Not sent') + '</p></div></header>' +
      '<div class="card dn"><p class="q2">' + esc(n.body) + '</p><p class="meta">Done ' + fmtShort(C.localDay(C.ms(n.done_at), tz())) + ' \u00b7 ' + (st.complete ? st.total + ' paid' : st.paid + ' of ' + st.total + ' paid') + '</p>' +
      (late && ui.tip ? '<div class="tip">' + TIP_TEXT + '</div>' : '') +
      '<div class="row3"><span class="btn o" data-a="nudgesend">Send again' + (late ? '<span class="qm" data-a="tip">?</span>' : '') + '</span>' +
      (st.complete || st.stopped ? '' : '<span class="btn g bd" data-a="nudgestop">Stop the rest</span>') + '</div></div>' + thr, { tab: false });
  }
  return phone('p2 nd', '<header class="hd"><div>' + hdBack(backLabel()) + '<h2>Nudges</h2><p class="dl">' + (sends.length ? 'Sent ' + sends.length + (sends.length === 1 ? ' time' : ' times') : 'Not sent') + '</p></div></header>' +
    '<div class="card"><p class="q2">' + esc(n.body) + '</p>' + (n.pinned ? '<p class="meta">pinned</p>' : '') +
    (late && ui.tip ? '<div class="tip">' + TIP_TEXT + '</div>' : '') +
    '<span class="btn f" data-a="nudgesend">' + (late ? 'Send tomorrow<span class="qm" data-a="tip">?</span>' : 'Send') + '</span>' +
    '<div class="row3"><span class="btn o" data-a="nudgepin">' + (n.pinned ? 'Unpin' : 'Pin') + '</span><span class="btn o" data-a="nudgeedit">Edit</span></div>' +
    // Points only exist between the two of us: a Me nudge can be archived but never marked done.
    (shared ? '<div class="row3"><span class="btn o" data-a="nudgedone">Done</span><span class="btn g bd" data-a="nudgearchive">Archive</span></div>' : '<span class="btn g" data-a="nudgearchive">Archive</span>') + '</div>' + thr, { tab: false });
};

// ---- Done, with points ------------------------------------------------------------------------------
var PTS = [10, 20, 30, 50];
// Chosen points: a chip, or the Other input (positive integer only; anything else is null and blocks Mark done).
function donePts() { return ui.dother ? (/^[1-9]\d*$/.test((ui.d.dotherv || '').trim()) ? +ui.d.dotherv.trim() : null) : ui.dpts; }
function doneSched() {
  var pts = donePts();
  if (pts === null) return '';
  return C.splitPayout(pts, ui.dpay, today()).map(function (x, i, a) {
    return '<div class="rem c"><p>' + (x.day === today() ? 'Now' : fmtShort(x.day)) + '</p><p class="' + (i === 0 ? 'pk' : 'mu') + '">+' + x.points + '</p></div>';
  }).join('');
}
function doneBtn() { var p = donePts(); return '<span class="btn f' + (p === null ? ' dis' : '') + '" data-a="donemark">Mark done' + (p === null ? '' : ' \u00b7 ' + p) + '</span>'; }
SCREEN.nudgedone = function () {
  var n = nudgeRow('esme', ui.nid);
  return phone('p2 nd', '<header class="hd"><div><h2>Done</h2></div><span class="txtbtn" data-a="back">Cancel</span></header>' +
    '<div class="card"><p class="q2">' + esc(n.body) + '</p></div>' +
    '<div><p class="lab">Points</p><div class="pchips">' + PTS.map(function (v) { return '<span class="pch' + (!ui.dother && ui.dpts === v ? ' on' : '') + '" data-a="donepts:' + v + '">' + v + '</span>'; }).join('') +
    '<span class="pch' + (ui.dother ? ' on' : '') + '" data-a="donepts:other">+ Other</span></div>' +
    (ui.dother ? '<input class="inp" inputmode="numeric" data-d="dotherv" value="' + esc(val('dotherv')) + '" placeholder="Points">' : '') + '</div>' +
    '<div><p class="lab">Pay out</p>' + seg([['now', 'All now'], ['3mo', 'Over 3 months']], ui.dpay, 'donepay') + '</div>' +
    '<div class="lst dsch" style="gap:0">' + doneSched() + '</div><div style="flex:1"></div><div class="dbtn">' + doneBtn() + '</div>', { tab: false });
};
// Typing in Other must not re-render (it would drop focus), so refresh just the schedule and button.
function doneRefresh() {
  var a = document.querySelector('.dsch'), b = document.querySelector('.dbtn');
  if (a) a.innerHTML = doneSched();
  if (b) b.innerHTML = doneBtn();
}

// A delivered nudge as its recipient sees it: the nudge, replies so far on every send of it, a reply box.
SCREEN.nudgein = function () {
  var s = findSend(ui.sendId), priv = !S.rows.nudge_sends[ui.sendId];
  var name = priv ? '' : nameOf(s.sender_id);
  return phone('p2 nd', '<header class="hd"><div>' + hdBack(backLabel()) + '<h2>' + (priv ? 'Nudge' : 'From ' + pnx(name)) + '</h2><p class="dl">' + fmtDay(C.localDay(C.ms(s.deliver_at), tz())) + '</p></div></header>' +
    '<div class="card"><p class="quote">' + esc(s.body) + '</p></div>' +
    (priv ? '' : '<div class="th">' + thread(sendsOfNudge(s.nudge_id)) + '</div>' + replyBox()), { tab: false });
};

// Add / edit. Edit keeps the nudge in its tier, so For is only offered when creating.
SCREEN.nudgenew = function () {
  var edit = ui.nedit ? nudgeRow(ui.nfor, ui.nedit) : null;
  if (edit && ui.d.nbody == null) ui.d.nbody = edit.body;
  var late = isLate(ui.nfor);
  return phone('p2 nd', '<header class="hd"><div><h2>' + (edit ? 'Edit' : 'New') + '</h2><p class="dl">&nbsp;</p></div><span class="txtbtn" data-a="back">Cancel</span></header>' +
    '<div class="ta msg"><textarea data-d="nbody">' + esc(val('nbody')) + '</textarea></div>' +
    (edit ? '' : '<section><p class="lab">For</p>' + seg([['esme', pn()], ['me', 'Me']], ui.nfor, 'nudgefor') + '</section>') +
    (late && ui.tip && !edit ? '<div class="tip">' + TIP_TEXT + '</div>' : '') +
    (edit ? '<div class="save" data-a="nudgesave">Save</div>' :
      '<div class="pair"><span class="ghost" data-a="nudgesave">Save</span><span class="save" data-a="nudgenewsend">' + (late ? 'Send tomorrow<span class="qm" data-a="tip">?</span>' : 'Send') + '</span></div>'), { tab: false });
};

// Creates (or, when editing, updates) the nudge from the form. Returns the row so Send can follow.
function saveNudge() {
  var body = (ui.d.nbody || '').trim();
  if (!body) { M.play('jiggle', document.querySelector('.ta')); throw new Error('Message needed'); }
  if (ui.nedit) { nPatch(ui.nfor, ui.nedit, { body: body }); return nudgeRow(ui.nfor, ui.nedit); }
  var T = nudgeTier(ui.nfor);
  var row = { id: St.uuid(), body: body, pinned: false, sort_order: T.nudges.reduce(function (m, n) { return Math.max(m, n.sort_order); }, -1) + 1,
    archived_at: null, created_at: nowIso(), updated_at: nowIso(), deleted_at: null };
  if (ui.nfor === 'me') { S.priv.nudges.push(row); St.savePriv(); }
  else { row.couple_id = S.couple.id; row.author_id = St.me(); St.insert('nudges', row); }
  return row;
}
// Opening a delivered nudge stamps opened_at (recipient only; the DB guard enforces it) and marks the
// other person's replies on that nudge read, which clears the sender's Needs-you card and the dot.
function openSend(id) {
  var s = findSend(id), priv = !S.rows.nudge_sends[id];
  if (s.recipient_id === St.me() && !s.opened_at) {
    if (priv) { s.opened_at = nowIso(); St.savePriv(); } else St.patch('nudge_sends', id, { opened_at: nowIso() });
  }
  if (!priv) markRead(idSet(sendsOfNudge(s.nudge_id)));
}

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
  var mk = S.rows.fight_markers[f.id], hit = mk && C.hitText(mk, 'me');
  if (hit) out += '<span class="rc">' + esc(hit) + '</span>';
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
  // A tapped control must not close the keyboard: hand focus to the field's twin after the swap (else .scr grows and clamps scrollTop).
  var fa = document.activeElement, fk = typing() && fa.getAttribute('data-d'), fs = fk && fa.selectionStart, fe = fk && fa.selectionEnd;
  var html = SCREEN[name]();
  // Sheets are rendered inside the owning screen (so they inherit its family CSS); screens that
  // host sheets read ui.sheet themselves. Everything else shows the sheet via the shared hook below.
  if (ui.sheet && name !== 'todo' && name !== 'shop') html = html.replace(/<\/div>$/, sheetFor() + '</div>');
  app.innerHTML = html;
  var ns = document.querySelector('.scr');
  var nf = fk && lastKey.split('|')[0] === name && document.querySelector('[data-d="' + fk + '"]');
  if (nf) { nf.focus({ preventScroll: true }); if (fs != null) nf.setSelectionRange(fs, fe); } // email inputs have no selection
  if (ns && lastKey.split('|')[0] === name) ns.scrollTop = top;
  markScrolled(); fitPair();
  lastKey = name + '|' + (ui.sheet ? 1 : 0);
}
// Log fight pills sit side by side; when that would clip the name or a label, stack them (measured, not by name length).
function fitPair() {
  var pr = document.querySelector('.p2.s2 .pair');
  if (!pr) return;
  var clips = function () { return [].some.call(pr.querySelectorAll('.pn, .save, .ghost'), function (e) { return e.scrollWidth > e.clientWidth; }); };
  pr.classList.toggle('stk', clips());
}
if (document.fonts) document.fonts.ready.then(fitPair);
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
  if (k === 'dotherv') doneRefresh();
  var pt = e.target.getAttribute('data-pt');
  if (pt) e.target.previousElementSibling.textContent = dispPick(pt, e.target.value);
});

// ---- actions ---------------------------------------------------------------------------------------------------
function deliver(item) {
  St.patch('items', item.id, { status: 'delivered', delivered_at: nowIso() });
  if (item.kind === 'ask') St.insert('todos', C.askToTodo(S.rows.items[item.id], St.uuid(), now()));
}
function sendItem(kind, o) {
  var item = C.buildItem({ id: St.uuid(), couple: S.couple, me: St.me(), to: St.partner().user_id, kind: kind, body: o.body, description: o.description, ask_type: o.ask_type, due_date: o.due_date, target: o.target, origin: o.origin, response_type: o.response_type, now: now() });
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
  St.insert('fight_markers', { id: id, couple_id: S.couple.id, logged_by: St.me(), at: new Date(at).toISOString(), repaired_at: null,
    // Shared on purpose: the partner sees these on the Points ledger's Fight line. null = not answered;
    // hit_related is false only when the "not related" box is checked after a Yes (the DB rejects it otherwise), else null.
    hit_self: ynVal(d.hit), hit_related: d.hit === 'yes' && d.hitNot ? false : null });
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
  tgt: function (n) { ui.tgt = Math.max(1, ui.tgt + +n); render(); },
  signin: guard(async function () { await St.signIn(ui.d.email, ui.d.password); ui.d = {}; render(); }),
  signup: guard(async function () { await St.signUp(ui.d.email, ui.d.password); ui.d = {}; render(); }),
  signout: guard(async function () { await St.signOut(); ui.route = 'home'; ui.stack = []; ui.d = {}; render(); }),
  create: guard(async function () {
    if (!ui.d.name) throw new Error('Name needed');
    ui.code = await St.createCouple(ui.d.name, Intl.DateTimeFormat().resolvedOptions().timeZone); render();
  }),
  join: guard(async function () {
    if (!ui.d.name || !ui.d.code) throw new Error('Name and code needed');
    await St.joinCouple(ui.d.code.trim().toUpperCase(), ui.d.name); ui.d = {}; render();
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
  newtodo: function () { ui.sheet = { type: 'newtodo', who: St.partner() ? 'them' : 'me', kind: 'task', ongoing: false }; ui.d = {}; render(); },
  nfor: function (v) { ui.sheet.who = v; render(); },
  nkind: function (v) { ui.sheet.kind = v; render(); },
  nodue: function () { ui.d.due = ''; render(); },
  ongoing: function () { ui.sheet.ongoing = !ui.sheet.ongoing; render(); },
  savetodo: guard(function () {
    var s = ui.sheet, title = (ui.d.title || '').trim(), desc = (ui.d.desc || '').trim() || null; if (!title) throw new Error('Title needed');
    if (s.who === 'them') sendItem('ask', { body: title, description: desc, ask_type: s.kind, due_date: s.kind === 'task' ? ui.d.due || null : null, target: ui.tgt, ongoing: s.kind === 'habit' && s.ongoing });
    else St.insert('todos', { id: St.uuid(), couple_id: S.couple.id, owner_id: St.me(), created_by: St.me(), item_id: null, fight_marker_id: null, title: title, description: desc, type: s.kind, due_date: s.kind === 'task' ? ui.d.due || null : null, target: s.kind === 'habit' && !s.ongoing ? ui.tgt : null, tally: 0, done_at: null, created_at: nowIso(), updated_at: nowIso(), deleted_at: null });
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
  yn: function (a) { var p = a.split(':'), k = p[0], v = p[1]; ui.d[k] = ui.d[k] === v ? null : v; render(); },
  hitnot: function () { ui.d.hitNot = !ui.d.hitNot; render(); },
  chip: function (c) { ui.d.chips = ui.d.chips || {}; ui.d.chips[c] = !ui.d.chips[c]; render(); },
  rewrite: guard(async function () {
    if (!(ui.d.vent || '').trim()) return;
    ui.d.rewritten = await St.rewrite(ui.d.vent); render();
  }),
  fightshare: guard(function () { if (!ui.d.rewritten) return; logFight(true); }),
  fightsave: guard(function () { logFight(false); }),
  hold: guard(function (arg) { /* arg = kind:minutes */ }),
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
  // ---- Nudges ----
  noop: function () {},
  ntier: function (t) { ui.ntier = t; render(); },
  nudge: function (id) { markRead(idSet(sendsOfNudge(id))); go('nudge', { nid: id, tip: false }); },
  tip: function () { ui.tip = !ui.tip; render(); },
  nudgesend: guard(function () {
    var el = document.querySelector('.card .btn.f') || document.querySelector('.card .btn.o');
    doSend(ui.ntier, nudgeRow(ui.ntier, ui.nid)); ui.tip = false;
    M.play('send', el); render();
  }),
  nudgepin: guard(function () { var n = nudgeRow(ui.ntier, ui.nid); nPatch(ui.ntier, n.id, { pinned: !n.pinned }); render(); }),
  nudgeedit: function () { go('nudgenew', { nedit: ui.nid, nfor: ui.ntier }); },
  nudgedone: function () { go('nudgedone', { dpts: 30, dother: false, dpay: '3mo' }); },
  donepts: function (v) { if (v === 'other') ui.dother = true; else { ui.dother = false; ui.dpts = +v; } render(); },
  donepay: function (v) { ui.dpay = v; render(); },
  // The award (couple-visible, so Esme's ledger pays it) and nudges.done_at go out together; the nudge then
  // leaves the library for the Done section. Back twice: Done sheet -> nudge card -> library.
  donemark: guard(function () {
    var pts = donePts(), n = nudgeRow('esme', ui.nid);
    if (pts === null) throw new Error('Points needed');
    var at = new Date(now()).toISOString();
    St.insert('nudge_awards', { id: St.uuid(), couple_id: S.couple.id, author_id: St.me(), recipient_id: St.partner().user_id, nudge_id: n.id, body: n.body,
      points: pts, payout: ui.dpay, done_at: at, stopped_at: null, created_at: nowIso(), updated_at: nowIso(), deleted_at: null });
    nPatch('esme', n.id, { done_at: at });
    ui.stack.pop(); back();
  }),
  nudgestop: guard(function () { St.patch('nudge_awards', awardOf(ui.nid).id, { stopped_at: new Date(now()).toISOString() }); render(); }),
  nudgearchive: guard(function () { nPatch(ui.ntier, ui.nid, { archived_at: nowIso() }); back(); }),
  nudgenew: function () { go('nudgenew', { nedit: null, nfor: ui.ntier }); },
  nudgefor: function (v) { ui.nfor = v; render(); },
  // Save only: the nudge joins the library of the tier chosen in For, and the library shows that tier.
  nudgesave: guard(function () { saveNudge(); ui.ntier = ui.nfor; back(); }),
  nudgenewsend: guard(function () {
    var el = document.querySelector('.pair .save');
    var row = saveNudge(); doSend(ui.nfor, row); ui.ntier = ui.nfor; ui.tip = false;
    M.play('send', el); back();
  }),
  // Replies are not held: the row goes straight into the outbox.
  nreply: guard(function () {
    var body = (ui.d.reply || '').trim(), s = replyTarget();
    if (!body) return;
    St.insert('nudge_replies', { id: St.uuid(), couple_id: S.couple.id, send_id: s.id, author_id: St.me(), body: body, read_at: null,
      created_at: nowIso(), updated_at: nowIso(), deleted_at: null });
    ui.d.reply = ''; render();
  }),
  nudgein: function (id) { openSend(id); go('nudgein', { sendId: id }); },
  replyopen: function (id) { openSend(id); go('nudgein', { sendId: id }); },
  day: function (d) { ui.cyc.sel = d; render(); },
  mon: function (n) { var c = ui.cyc, m = c.m + +n; c.y += m < 1 ? -1 : m > 12 ? 1 : 0; c.m = m < 1 ? 12 : m > 12 ? 1 : m; render(); }
};

// Shared-setting writes go straight to REST (couples/members are not in the offline outbox).
async function setHold(kind, min) {
  var field = 'hold_' + kind + '_min';
  await St.api('PATCH', 'couples?id=eq.' + S.couple.id, (function (o) { o[field] = min; return o; })({}), { Prefer: 'return=minimal' });
  S.couple[field] = min; await St.persistNow(); St.emit();
}
['truth', 'ask'].forEach(function (k) { ACT['hold' + k] = guard(function (m) { return setHold(k, +m); }); });

// Tapping a non-field control keeps the focused field (and keyboard), as on iOS.
app.addEventListener('mousedown', function (e) {
  var el = e.target.closest('[data-a]');
  if (el && typing() && !/^(INPUT|TEXTAREA|LABEL)$/.test(el.tagName)) e.preventDefault();
});
app.addEventListener('click', function (e) {
  var el = e.target.closest('[data-a]');
  if (!el || el.tagName === 'INPUT') return;
  if (ui.suppressClick) { ui.suppressClick = false; return; }
  var a = el.getAttribute('data-a'), i = a.indexOf(':'), name = i < 0 ? a : a.slice(0, i), arg = i < 0 ? undefined : a.slice(i + 1);
  if (!ACT[name]) throw new Error('no action ' + name);
  ACT[name](arg);
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

// ---- Nudge library reorder: hold the grip, drag within its own section -----------------------------------------
// Same hold-then-drag gesture as Home. A row can only move among the rows of its own section (Pinned or All),
// so the sort_order rewrite on drop never has to reconcile two sections. Recent has no grip: it is derived.
(function () {
  var timer = 0, drag = null, y0 = 0, pos = 0, pid = 0;
  function siblings() { return Array.prototype.slice.call(drag.row.parentNode.querySelectorAll('.rem')); }
  app.addEventListener('pointerdown', function (e) {
    var g = e.target.closest('[data-grip]');
    if (!g) return;
    var row = g.closest('.rem'); pid = e.pointerId; y0 = pos = e.clientY;
    timer = setTimeout(function () {
      timer = 0; ui.suppressClick = true;
      drag = { row: row, y: pos }; row.classList.add('lift'); row.setPointerCapture(pid);
    }, 500);
  });
  app.addEventListener('pointermove', function (e) {
    pos = e.clientY;
    if (timer && Math.abs(pos - y0) > 10) { clearTimeout(timer); timer = 0; }
    if (!drag) return;
    var others = siblings().filter(function (r) { return r !== drag.row; });
    var before = others.filter(function (r) { var b = r.getBoundingClientRect(); return e.clientY < b.top + b.height / 2; })[0];
    var top0 = drag.row.getBoundingClientRect().top;
    drag.row.parentNode.insertBefore(drag.row, before || null);
    drag.y += top0 - drag.row.getBoundingClientRect().top; // keep the row under the finger after the DOM move
    drag.row.style.transform = 'translateY(' + (e.clientY - drag.y) + 'px) scale(1.03) rotate(-1deg)';
  });
  function end() {
    clearTimeout(timer); timer = 0;
    if (!drag) return;
    siblings().forEach(function (r, i) { nPatch(ui.ntier, r.getAttribute('data-nid'), { sort_order: i }); });
    drag = null; render();
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
  else if ((m = /^nudge\/(.+)$/.exec(r))) { ui.stack = []; ui.route = 'nudgein'; ui.sendId = m[1]; ui.d = {}; ui.sheet = null; openSend(m[1]); render(); }
  else if (r === 'today') tab('home'); // a reminder scheduled by an older build
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

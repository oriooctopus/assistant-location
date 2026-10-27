import test from 'node:test';
import assert from 'node:assert/strict';
import C from './cycle-load.mjs';

const TZ = 'America/New_York'; // EDT (UTC-4) through 2026-11-01
// 2026-10-19 is a Monday. at('2026-10-20', 14) = Tue 14:00 New York time.
const at = (day, h = 12, m = 0) => Date.parse(`${day}T${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:00-04:00`);
const iso = (day, h, m) => new Date(at(day, h, m)).toISOString();
const ME = 'u-me', YOU = 'u-you';
const members = [{ user_id: ME, name: 'Alex' }, { user_id: YOU, name: 'Sam' }];
const rows = (o = {}) => ({ members, items: [], todos: [], todo_events: [], fight_markers: [], redemptions: [], nudge_sends: [], nudge_awards: [], ...o });
const L = (r, now, since = '2026-10-19') => C.computeLedger(r, { tz: TZ, now, since });
const kudo = (id, sender, d, h) => ({ id, kind: 'kudos', status: 'delivered', sender_id: sender, recipient_id: sender === ME ? YOU : ME, delivered_at: iso(d, h), created_at: iso(d, h), deleted_at: null });
const todo = (o) => ({ id: 't1', type: 'task', title: 'Book flight', due_date: null, done_at: null, fight_marker_id: null, deleted_at: null, ...o });

test('week runs Monday to Sunday in the couple tz', () => {
  assert.equal(C.weekStart('2026-10-25'), '2026-10-19'); // Sunday -> Monday before
  assert.equal(C.weekStart('2026-10-26'), '2026-10-26');
  // 23:30 Sunday NY is already Monday in UTC: it must still count for the old week.
  const r = rows({ items: [kudo('a', ME, '2026-10-25', 23), kudo('b', ME, '2026-10-26', 0)] });
  const l = L(r, at('2026-10-26', 12), '2026-10-26'); // since = Monday so no calm days before
  assert.equal(l.weeks['2026-10-19'].days['2026-10-25'].lines.filter((x) => x.label === 'Kudos').length, 1);
  assert.equal(l.weeks['2026-10-26'].days['2026-10-26'].lines.filter((x) => x.label === 'Kudos').length, 1);
});

test('kudos cap is 3 per sender per day, other sender counts separately', () => {
  const items = [1, 2, 3, 4, 5].map((i) => kudo('m' + i, ME, '2026-10-20', 8 + i)).concat([kudo('y1', YOU, '2026-10-20', 9)]);
  const l = L(rows({ items }), at('2026-10-20', 22), '2026-10-20');
  const lines = l.weeks['2026-10-19'].days['2026-10-20'].lines.filter((x) => x.label === 'Kudos');
  assert.equal(lines.length, 4); // 3 from me + 1 from you
});

test('overdue applies once and replaces the on-time bonus when done late', () => {
  const t = todo({ due_date: '2026-10-20' });
  const l = L(rows({ todos: [t] }), at('2026-10-23', 10), '2026-10-23');
  const all = Object.values(l.weeks).flatMap((w) => Object.values(w.days)).flatMap((d) => d.lines).filter((x) => x.label === 'To do overdue');
  assert.equal(all.length, 1);
  assert.equal(all[0].pts, -3);
  // Recomputing later (same rows, later now) must not add a second penalty.
  const l2 = L(rows({ todos: [t] }), at('2026-10-30', 10), '2026-10-23');
  const all2 = Object.values(l2.weeks).flatMap((w) => Object.values(w.days)).flatMap((d) => d.lines).filter((x) => x.label === 'To do overdue');
  assert.equal(all2.length, 1);
  const late = todo({ due_date: '2026-10-20', done_at: iso('2026-10-22', 9) });
  const l3 = L(rows({ todos: [late] }), at('2026-10-23', 10), '2026-10-23');
  const labels = Object.values(l3.weeks).flatMap((w) => Object.values(w.days)).flatMap((d) => d.lines).map((x) => x.label);
  assert.ok(labels.includes('To do overdue'));
  assert.ok(!labels.includes('To do on time'));
});

test('to do not yet due is neutral, done on the due day is +3', () => {
  const l = L(rows({ todos: [todo({ due_date: '2026-10-23' })] }), at('2026-10-23', 10), '2026-10-23');
  assert.equal(l.balance, 0);
  const done = todo({ due_date: '2026-10-23', done_at: iso('2026-10-23', 9) });
  assert.equal(L(rows({ todos: [done] }), at('2026-10-23', 10), '2026-10-23').balance, 3);
});

test('a fight week can go negative; fight is -5 plus 1 for logging, no calm day on it', () => {
  const r = rows({ fight_markers: [{ id: 'f1', at: iso('2026-10-19', 21), logged_by: ME }] });
  const l = L(r, at('2026-10-20', 12), '2026-10-19');
  assert.equal(l.weeks['2026-10-19'].net, -4);
  assert.equal(l.balance, -4);
  assert.equal(l.current.net, -4);
});

test('calm day only after the day fully elapsed, never on a fight day', () => {
  const l = L(rows(), at('2026-10-21', 12), '2026-10-19'); // Mon, Tue elapsed; Wed is today
  assert.equal(l.balance, 6);
  assert.ok(!l.weeks['2026-10-19'].days['2026-10-21']);
});

test('approved redemptions subtract, pending and declined do not; balance may go negative', () => {
  const base = rows({ items: [kudo('k', ME, '2026-10-19', 9)] }); // +1
  const red = (id, status, price) => ({ id, status, price, reward_id: 'r', decided_at: iso('2026-10-20', 9), requested_by: ME });
  const now = at('2026-10-19', 22);
  assert.equal(L({ ...base, redemptions: [red('a', 'pending', 50), red('b', 'declined', 50)] }, now).balance, 1);
  const l = L({ ...base, redemptions: [red('a', 'approved', 50)] }, now);
  assert.equal(l.balance, -49);
  assert.equal(l.spent, 50);
  assert.equal(l.current.net, 1); // redemptions are not part of the week's net
});

test('no check-in points exist: rows with a checkins list change nothing', () => {
  const base = L(rows(), at('2026-10-21', 9));
  const withCk = L(rows({ checkins: [{ user_id: ME, day: '2026-10-20' }, { user_id: YOU, day: '2026-10-20' }] }), at('2026-10-21', 9));
  assert.deepEqual(withCk, base);
  assert.ok(!JSON.stringify(withCk).includes('heck-in'));
});

test('partner nudge: opened same day +1, unopened after its day -1, today pending and future are neutral', () => {
  const f = (id, d, opened, h = 9) => ({ id, nudge_id: 'n', sender_id: YOU, recipient_id: ME, deliver_at: iso(d, h), opened_at: opened, deleted_at: null });
  const now = at('2026-10-22', 12);
  assert.equal(L(rows({ nudge_sends: [f('a', '2026-10-20', iso('2026-10-20', 20))] }), now, '2026-10-22').balance, 1);
  assert.equal(L(rows({ nudge_sends: [f('a', '2026-10-20', null)] }), now, '2026-10-22').balance, -1);
  assert.equal(L(rows({ nudge_sends: [f('a', '2026-10-22', null)] }), now, '2026-10-22').balance, 0);
  assert.equal(L(rows({ nudge_sends: [f('a', '2026-10-22', null, 18)] }), at('2026-10-23', 12), '2026-10-23').balance, -1); // queued for later today, then unopened by midnight
  assert.equal(L(rows({ nudge_sends: [f('a', '2026-10-23', null, 8)] }), now, '2026-10-22').balance, 0); // not delivered yet
});

// ---- nudges: 8 pm rule and library sections -------------------------------------
test('deliverAt: before 20:00 is immediate, at/after 20:00 is 08:00 next day in the recipient tz', () => {
  const LA = 'America/Los_Angeles';
  const t1959 = at('2026-10-20', 19, 59), t2000 = at('2026-10-20', 20, 0);
  assert.equal(C.deliverAt(t1959, TZ, TZ), t1959);
  assert.equal(C.deliverAt(t2000, TZ, TZ), at('2026-10-21', 8));
  assert.equal(C.deliverAt(t2000, TZ, LA), Date.parse('2026-10-21T08:00:00-07:00'));
  assert.equal(C.deliverAt(at('2026-10-20', 23, 59), TZ, TZ), at('2026-10-21', 8));
  assert.equal(C.deliverAt(at('2026-10-21', 0, 5), TZ, TZ), at('2026-10-21', 0, 5)); // past midnight, new day, before 20:00
});

test('deliverAt: DST change day (fall back 2026-11-01 in New York)', () => {
  // Sat 20:30 EDT -> Sunday 08:00 is already EST (UTC-5); Sunday 20:30 EST -> Monday 08:00 EST.
  assert.equal(C.deliverAt(Date.parse('2026-10-31T20:30:00-04:00'), TZ, TZ), Date.parse('2026-11-01T08:00:00-05:00'));
  assert.equal(C.deliverAt(Date.parse('2026-11-01T20:30:00-05:00'), TZ, TZ), Date.parse('2026-11-02T08:00:00-05:00'));
  assert.equal(C.deliverAt(Date.parse('2026-11-01T19:59:00-05:00'), TZ, TZ), Date.parse('2026-11-01T19:59:00-05:00'));
  // Spring forward 2026-03-08: Sat 21:00 EST -> Sunday 08:00 EDT (UTC-4)
  assert.equal(C.deliverAt(Date.parse('2026-03-07T21:00:00-05:00'), TZ, TZ), Date.parse('2026-03-08T08:00:00-04:00'));
});

test('sectionNudges: Pinned / Recent (4, unpinned) / All with no nudge in two sections; archived hidden', () => {
  const mk = (id, d, o = {}) => ({ id, created_at: iso(d, 9), sort_order: +id.slice(1), pinned: false, archived_at: null, deleted_at: null, ...o });
  const ns = [mk('n1', '2026-10-01', { pinned: true }), mk('n2', '2026-10-02'), mk('n3', '2026-10-03'), mk('n4', '2026-10-04'),
    mk('n5', '2026-10-05'), mk('n6', '2026-10-06'), mk('n7', '2026-10-07', { archived_at: iso('2026-10-08', 9) }), mk('n8', '2026-10-01', { pinned: true })];
  const sends = [{ nudge_id: 'n2', created_at: iso('2026-10-20', 9), deleted_at: null }];
  const s = C.sectionNudges(ns, sends);
  assert.deepEqual(s.pinned.map((n) => n.id), ['n1', 'n8']);
  assert.deepEqual(s.recent.map((n) => n.id), ['n2', 'n6', 'n5', 'n4']); // n2 resurfaces because it was sent last
  assert.deepEqual(s.all.map((n) => n.id), ['n3']);
  const ids = [...s.pinned, ...s.recent, ...s.all].map((n) => n.id);
  assert.equal(new Set(ids).size, ids.length);
  assert.ok(!ids.includes('n7'));
});

test('repair: response to do done within 48h of its marker is +5, later is nothing', () => {
  const m = { id: 'f1', at: iso('2026-10-20', 21), logged_by: ME };
  const resp = (done) => todo({ id: 'r1', type: 'response', fight_marker_id: 'f1', done_at: done });
  const now = at('2026-10-23', 12);
  const withRepair = L(rows({ fight_markers: [m], todos: [resp(iso('2026-10-22', 20))] }), now, '2026-10-23');
  const late = L(rows({ fight_markers: [m], todos: [resp(iso('2026-10-22', 22))] }), now, '2026-10-23');
  assert.equal(withRepair.balance - late.balance, 5);
});

test('habit tally is +1 per event', () => {
  const t = todo({ id: 'h', type: 'habit', target: 10 });
  const ev = [1, 2, 3].map((i) => ({ id: 'e' + i, todo_id: 'h', kind: 'tally', at: iso('2026-10-22', 8 + i) }));
  assert.equal(L(rows({ todos: [t], todo_events: ev }), at('2026-10-22', 20), '2026-10-22').balance, 3);
});

test('computeLedger refuses to guess missing options', () => {
  assert.throws(() => C.computeLedger(rows(), { tz: TZ, now: 1 }), /needs tz, now, since/);
});

test('both phones compute an identical ledger from the same rows', () => {
  const r = rows({ items: [kudo('a', ME, '2026-10-20', 10)] });
  assert.deepEqual(L(r, at('2026-10-22', 9)), L(JSON.parse(JSON.stringify(r)), at('2026-10-22', 9)));
});

test('groupWeek sums by label and splits earned / lost', () => {
  const r = rows({ items: [kudo('k1', ME, '2026-10-19', 9), kudo('k2', YOU, '2026-10-19', 9)], fight_markers: [{ id: 'f', at: iso('2026-10-20', 20), logged_by: ME }] });
  const g = C.groupWeek(L(r, at('2026-10-21', 9)).weeks['2026-10-19']);
  assert.deepEqual(g.earned.find((x) => x.label === 'Kudos'), { label: 'Kudos', pts: 2 });
  assert.deepEqual(g.lost, [{ label: 'Fight', pts: -5 }]);
});

// ---- holds ------------------------------------------------------------------
test('hold math: held_until, countdown text, Held label', () => {
  const now = at('2026-10-20', 9);
  assert.equal(C.heldUntil(now, 720), now + 12 * 3600000);
  assert.equal(C.countdown(now + (11 * 60 + 42) * 60000, now), '11h 42m');
  assert.equal(C.countdown(now + (11 * 60 + 5) * 60000, now), '11h 05m');
  assert.equal(C.countdown(now + 52 * 60000, now), '52m');
  assert.equal(C.countdown(now + 30000, now), '1m');
  assert.equal(C.countdown(now, now), 'Ready');
  assert.equal(C.heldLabel({ held_until: iso('2026-10-21', 9), created_at: iso('2026-10-20', 9) }), 'Held 24h');
  assert.equal(C.heldLabel({ held_until: new Date(now + 720 * 60000).toISOString(), created_at: new Date(now).toISOString() }), 'Held 12h');
  assert.equal(C.heldLabel({ held_until: new Date(now + 60000).toISOString(), created_at: new Date(now).toISOString() }), 'Held 1m');
  assert.equal(C.heldLabel({ held_until: null, created_at: iso('2026-10-20', 9) }), null);
});

test('buildItem: held when the couple hold is > 0, delivered at once when 0', () => {
  const couple = { id: 'c', hold_focus_min: 60, hold_truth_min: 720, hold_ask_min: 720, hold_kudos_min: 0 };
  const now = at('2026-10-20', 9);
  const t = C.buildItem({ id: 'i1', couple, me: ME, to: YOU, kind: 'truth', body: 'x', now });
  assert.equal(t.status, 'held');
  assert.equal(Date.parse(t.held_until), now + 720 * 60000);
  assert.equal(t.delivered_at, null);
  const k = C.buildItem({ id: 'i2', couple, me: ME, to: YOU, kind: 'kudos', body: 'x', now });
  assert.equal(k.status, 'delivered');
  assert.equal(k.held_until, null);
  assert.equal(Date.parse(k.delivered_at), now);
  assert.throws(() => C.holdMinutes(couple, 'nope'), /unknown item kind/);
});

test('askToTodo: recipient owns it, sender created it, item linked', () => {
  const couple = { id: 'c', hold_ask_min: 0, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 };
  const item = C.buildItem({ id: 'i', couple, me: ME, to: YOU, kind: 'ask', ask_type: 'habit', target: 5, body: 'Stretch', now: 1000 });
  const td = C.askToTodo(item, 'td', 1000);
  assert.deepEqual([td.owner_id, td.created_by, td.item_id, td.type, td.target, td.title], [YOU, ME, 'i', 'habit', 5, 'Stretch']);
  assert.equal(td.fight_marker_id, null);
});

test('askToTodo: a fight ask becomes a response todo on the fight marker', () => {
  const couple = { id: 'c', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 };
  const item = C.buildItem({ id: 'i', couple, me: ME, to: YOU, kind: 'ask', ask_type: 'task', body: 'Apologize', origin: 'fight', response_type: 'apologize', fight_marker_id: 'fm1', now: 1000 });
  assert.equal(item.status, 'held'); // the ask hold still applies
  assert.equal(item.fight_marker_id, 'fm1');
  const td = C.askToTodo(item, 'td', 1000);
  assert.deepEqual([td.type, td.fight_marker_id, td.owner_id], ['response', 'fm1', YOU]);
});

test('askToTodo carries the ask description; non-ask items never get one', () => {
  const couple = { id: 'c', hold_ask_min: 0, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 };
  const item = C.buildItem({ id: 'i', couple, me: ME, to: YOU, kind: 'ask', body: 'Call mom', description: 'About Sunday', now: 1000 });
  assert.equal(C.askToTodo(item, 'td', 1000).description, 'About Sunday');
  assert.equal(C.askToTodo(C.buildItem({ id: 'j', couple, me: ME, to: YOU, kind: 'ask', body: 'x', now: 1000 }), 'td', 1000).description, null);
  assert.equal(C.buildItem({ id: 'k', couple, me: ME, to: YOU, kind: 'kudos', body: 'x', description: 'y', now: 1000 }).description, null);
});

// ---- phase ------------------------------------------------------------------
test('phase: Fight / Cool / Warm / Tension from the fight log', () => {
  // fights Oct 1 and Oct 11 -> avg cycle 10 days, Warm until 6
  const fights = [{ at: at('2026-10-01', 20) }, { at: at('2026-10-11', 20) }];
  const P = (d) => C.phase(fights, at(d, 12), TZ);
  assert.equal(P('2026-10-11').name, 'Fight');
  assert.equal(P('2026-10-12').name, 'Cool');
  assert.equal(P('2026-10-13').name, 'Cool');
  assert.equal(P('2026-10-14').name, 'Warm');
  assert.equal(P('2026-10-16').name, 'Warm');
  assert.equal(P('2026-10-17').name, 'Tension');
  assert.equal(P('2026-10-13').day, 3);
  assert.equal(P('2026-10-13').avg, 10);
  assert.equal(C.phase([], 0, TZ), null);
});

// ---- needs you ----------------------------------------------------------------
test('needsYou: ready held, approvals for the non-requester, unread partner focus/kudos', () => {
  const now = at('2026-10-22', 21);
  const items = [
    { id: 'h1', kind: 'truth', sender_id: ME, recipient_id: YOU, status: 'held', held_until: iso('2026-10-22', 20), deleted_at: null },
    { id: 'h2', kind: 'truth', sender_id: ME, recipient_id: YOU, status: 'held', held_until: iso('2026-10-23', 20), deleted_at: null },
    { id: 'tr', kind: 'truth', sender_id: YOU, recipient_id: ME, status: 'delivered', delivered_at: iso('2026-10-22', 9), opened_at: null, deleted_at: null }
  ];
  const redemptions = [{ id: 'r1', status: 'pending', requested_by: YOU }, { id: 'r2', status: 'pending', requested_by: ME }];
  const sends = [
    { id: 's1', sender_id: YOU, recipient_id: ME, deliver_at: iso('2026-10-22', 9), opened_at: null, deleted_at: null },
    { id: 's2', sender_id: YOU, recipient_id: ME, deliver_at: iso('2026-10-22', 9), opened_at: iso('2026-10-22', 10), deleted_at: null },
    { id: 's3', sender_id: YOU, recipient_id: ME, deliver_at: iso('2026-10-23', 8), opened_at: null, deleted_at: null }, // not delivered yet
    { id: 's4', sender_id: ME, recipient_id: YOU, deliver_at: iso('2026-10-22', 9), opened_at: null, deleted_at: null } // mine, not a card
  ];
  const replies = [
    { id: 'p1', send_id: 's4', author_id: YOU, read_at: null, created_at: iso('2026-10-22', 11), deleted_at: null },
    { id: 'p2', send_id: 's4', author_id: YOU, read_at: null, created_at: iso('2026-10-22', 12), deleted_at: null },
    { id: 'p3', send_id: 's2', author_id: ME, read_at: null, created_at: iso('2026-10-22', 12), deleted_at: null },
    { id: 'p4', send_id: 's2', author_id: YOU, read_at: iso('2026-10-22', 13), created_at: iso('2026-10-22', 12), deleted_at: null }
  ];
  const n = C.needsYou({ me: ME, now, tz: TZ, items, redemptions, nudge_sends: sends, nudge_replies: replies, fight_markers: [], fight_notes: [], acks: [] });
  assert.deepEqual(n.map((x) => x.type), ['ready', 'approve', 'nudge', 'reply']);
  assert.equal(n[0].count, 1);
  assert.equal(n[1].redemption.id, 'r1');
  assert.equal(n[2].send.id, 's1');
  assert.equal(n[3].reply.id, 'p2'); // newest unread reply, one card per thread
  assert.ok(!n.some((x) => x.type === 'checkin')); // there is no check-in card, ever
});

test('needsYou: a partner-logged unrepaired fight needs my version until I write a note', () => {
  const now = at('2026-10-22', 21);
  const base = { me: ME, now, tz: TZ, items: [], redemptions: [], nudge_sends: [], nudge_replies: [], acks: [] };
  const mk = (id, by, extra) => ({ id, logged_by: by, at: iso('2026-10-22', 9), repaired_at: null, ...extra });
  const fights = [mk('f1', YOU), mk('f2', ME), mk('f3', YOU, { repaired_at: iso('2026-10-22', 10) }), mk('f4', YOU)];
  const note = (id, by) => ({ id: 'n' + id, fight_marker_id: id, author_id: by });
  const types = (notes) => C.needsYou({ ...base, fight_markers: fights, fight_notes: notes }).filter((x) => x.type === 'fight').map((x) => x.marker.id);
  assert.deepEqual(types([]), ['f1', 'f4']); // not my own (f2), not repaired (f3)
  assert.deepEqual(types([note('f1', ME)]), ['f4']); // my note clears it
  assert.deepEqual(types([note('f1', YOU)]), ['f1', 'f4']); // their own note does not
});

test('monthGrid is Monday-first', () => {
  const g = C.monthGrid(2026, 10); // Oct 1 2026 is a Thursday
  assert.equal(g.blanks, 3);
  assert.equal(g.days.length, 31);
});

test('isStillHeld: only a live held item may offer Send/Edit/Drop', () => {
  assert.equal(C.isStillHeld({ status: 'held', deleted_at: null }), true);
  assert.equal(C.isStillHeld({ status: 'delivered', deleted_at: null }), false);
  assert.equal(C.isStillHeld({ status: 'dropped', deleted_at: null }), false);
  assert.equal(C.isStillHeld({ status: 'held', deleted_at: '2026-10-20T00:00:00Z' }), false);
  assert.equal(C.isStillHeld(undefined), false);
});

test('hitText: the four outputs, named for the logger', () => {
  assert.equal(C.hitText({ hit_self: null, hit_related: null }, 'Alex'), null);
  assert.equal(C.hitText({ hit_self: false, hit_related: null }, 'Alex'), null);
  assert.equal(C.hitText({ hit_self: true, hit_related: null }, 'Alex'), 'Hit herself');
  assert.equal(C.hitText({ hit_self: true, hit_related: true }, 'Alex'), 'Hit herself, related to Alex');
  assert.equal(C.hitText({ hit_self: true, hit_related: false }, 'Alex'), 'Hit herself, not related to Alex');
});

test('ledger Fight line carries hitText as who, using the logger\'s name', () => {
  const fightLine = (m) => {
    const l = L(rows({ fight_markers: [{ id: 'f', at: iso('2026-10-20', 20), logged_by: YOU, ...m }] }), at('2026-10-21', 12), '2026-10-20');
    return l.weeks['2026-10-19'].days['2026-10-20'].lines.find((x) => x.label === 'Fight');
  };
  assert.equal(fightLine({ hit_self: true, hit_related: true }).who, 'Hit herself, related to Sam');
  assert.equal(fightLine({ hit_self: true, hit_related: false }).who, 'Hit herself, not related to Sam');
  assert.equal(fightLine({ hit_self: true, hit_related: null }).who, 'Hit herself');
  assert.equal(fightLine({ hit_self: null, hit_related: null }).who, null);
  assert.equal(fightLine({ hit_self: false, hit_related: null }).who, null);
});

// ---- Done, with points: payout schedule + ledger ----
test('splitPayout: all now is one row; 3mo puts the remainder on the earliest', () => {
  assert.deepEqual(C.splitPayout(20, 'now', '2026-10-25'), [{ day: '2026-10-25', points: 20 }]);
  const pts = (n) => C.splitPayout(n, '3mo', '2026-10-25').map((x) => x.points);
  assert.deepEqual(pts(20), [7, 7, 6]);
  assert.deepEqual(pts(10), [4, 3, 3]);
  assert.deepEqual(pts(30), [10, 10, 10]);
  assert.deepEqual(pts(50), [17, 17, 16]);
  assert.deepEqual(C.splitPayout(20, '3mo', '2026-10-25').map((x) => x.day), ['2026-10-25', '2026-11-25', '2027-01-25']);
  assert.deepEqual(pts(1), [1], 'zero-point parts are dropped');
});
test('splitPayout: month steps clamp to the last day of the month', () => {
  assert.deepEqual(C.splitPayout(9, '3mo', '2027-01-31').map((x) => x.day), ['2027-01-31', '2027-02-28', '2027-04-30']);
  assert.deepEqual(C.splitPayout(9, '3mo', '2028-01-31').map((x) => x.day), ['2028-01-31', '2028-02-29', '2028-04-30']);
});
const award = (o = {}) => ({ id: 'a', recipient_id: 'her', points: 30, payout: '3mo', done_at: iso('2026-10-01', 14), stopped_at: null, deleted_at: null, ...o });
test('ledger: only installments due by today count', () => {
  const total = (day) => L(rows({ nudge_awards: [award()] }), at(day, 12), '2026-10-01').balance;
  const base = (day) => L(rows(), at(day, 12), '2026-10-01').balance;
  assert.equal(total('2026-10-15') - base('2026-10-15'), 10);
  assert.equal(total('2026-11-01') - base('2026-11-01'), 20);
  assert.equal(total('2026-12-31') - base('2026-12-31'), 20, 'third installment (1 Jan) not due yet');
  assert.equal(total('2027-01-02') - base('2027-01-02'), 30);
});
test('ledger: Stop the rest cuts installments dated on or after the stop day, keeps earlier ones', () => {
  const stopped = award({ stopped_at: iso('2026-11-15', 12) }); // between the 1 Nov and 1 Jan installments
  const d = (day) => L(rows({ nudge_awards: [stopped] }), at(day, 12), '2026-10-01').balance - L(rows(), at(day, 12), '2026-10-01').balance;
  assert.equal(d('2027-02-01'), 20, 'later installment never paid');
  const st = C.awardStatus(stopped, '2027-02-01', TZ);
  assert.deepEqual([st.paid, st.stopped, st.complete, st.next], [20, true, false, null]);
  const sameDay = award({ stopped_at: iso('2026-11-01', 20) }); // the 1 Nov installment is dated the stop day: cut
  assert.equal(C.awardStatus(sameDay, '2027-02-01', TZ).paid, 10);
});

// ---- per-todo points, habit goals (N per day / week / month), notes, edited tag ----
const hab = (o) => todo({ id: 'h', type: 'habit', target: 2, period: 'week', created_at: iso('2026-10-05', 12), ...o });
const logs = (...stamps) => stamps.map((s, i) => ({ id: 'e' + i, todo_id: 'h', kind: 'tally', user_id: ME, at: s }));
const misses = (t, ev, day) => C.habitMisses(t, ev, day, TZ).map((p) => p.start);

test('per-todo points replace the constants, null keeps the defaults, 0 makes no line', () => {
  const bal = (t, now) => L(rows({ todos: [t] }), at(now, 10), now).balance;
  assert.equal(bal(todo({ due_date: '2026-10-23', done_at: iso('2026-10-23', 9), points_earn: 5 }), '2026-10-23'), 5);
  assert.equal(bal(todo({ due_date: '2026-10-23', done_at: iso('2026-10-23', 9), points_earn: null }), '2026-10-23'), 3);
  assert.equal(bal(todo({ due_date: '2026-10-20', points_miss: 2 }), '2026-10-23'), -2);
  assert.equal(bal(todo({ due_date: '2026-10-20', points_miss: 0 }), '2026-10-23'), 0);
  assert.equal(bal(todo({ due_date: '2026-10-20' }), '2026-10-23'), -3);
  const h = hab({ points_earn: 2 }), ev = logs(iso('2026-10-22', 9), iso('2026-10-22', 10));
  assert.equal(L(rows({ todos: [h], todo_events: ev }), at('2026-10-22', 20), '2026-10-22').balance, 4);
});

test('a weekly habit that closes under target is a miss, once per missed week; the open week never counts', () => {
  // created Mon 10-05; week of 10-05 hit (2), week of 10-12 missed (1), week of 10-19 is open and empty.
  const ev = logs(iso('2026-10-06', 9), iso('2026-10-07', 9), iso('2026-10-13', 9));
  assert.deepEqual(misses(hab(), ev, '2026-10-21'), ['2026-10-12']);
  const l = L(rows({ todos: [hab({ points_miss: 4 })], todo_events: ev }), at('2026-10-21', 10), '2026-10-21');
  const line = l.weeks['2026-10-19'].days['2026-10-19'].lines.filter((x) => x.label === 'Habit missed');
  assert.deepEqual(line.map((x) => x.pts), [-4]);
  assert.equal(l.balance, 3 - 4); // 3 tally points (default 1 each) minus the one miss
  // default habit miss is 0: same rows, no miss line
  const l0 = L(rows({ todos: [hab()], todo_events: ev }), at('2026-10-21', 10), '2026-10-21');
  assert.equal(l0.balance, 3);
});

test('periods before the habit existed never count; the period it was created in is skipped unless it began that day', () => {
  const t = hab({ created_at: iso('2026-10-14', 12) }); // Wed of the week starting 10-12
  assert.deepEqual(misses(t, [], '2026-10-26'), ['2026-10-19']); // 10-12 week skipped, 10-19 week closed and empty
  assert.deepEqual(misses(t, [], '2026-10-25'), []); // 10-19 week still open on its last day
  assert.deepEqual(misses(hab({ created_at: iso('2026-10-12', 8) }), [], '2026-10-19'), ['2026-10-12']); // created on the Monday: counts
});

test('daily habit: a log at 23:30 New York belongs to that day, not the next UTC day', () => {
  const t = hab({ period: 'day', target: 1, created_at: iso('2026-10-19', 9) });
  const ev = logs(iso('2026-10-19', 12), iso('2026-10-20', 23, 30), iso('2026-10-22', 0, 30));
  assert.deepEqual(misses(t, ev, '2026-10-22'), ['2026-10-21']); // 10-20 23:30 is 10-21 03:30Z: counted for the 20th only
});

test('monthly habit: calendar months, partial creation month skipped, Feb leap end', () => {
  const t = hab({ period: 'month', target: 3, created_at: iso('2026-08-15', 12) });
  const ev = logs(iso('2026-09-10', 9));
  assert.deepEqual(misses(t, ev, '2026-10-25'), ['2026-09-01']); // Aug partial, Sep under, Oct open
  assert.deepEqual(C.periodOf('month', '2028-02-10'), { start: '2028-02-01', end: '2028-02-29' });
  assert.deepEqual(C.periodOf('week', '2026-10-25'), { start: '2026-10-19', end: '2026-10-25' });
});

test('a habit with no target or period (pre-goal row) has no misses; deleted habits add nothing', () => {
  assert.deepEqual(misses(hab({ target: null }), [], '2026-12-01'), []);
  assert.deepEqual(misses(hab({ period: null }), [], '2026-12-01'), []);
  const l = L(rows({ todos: [hab({ points_miss: 4, deleted_at: iso('2026-10-10', 9) })] }), at('2026-12-01', 9), '2026-12-01');
  assert.equal(l.balance - l.challenges.reduce((a, c) => a + c.earned, 0), 0); // challenges pay from their own start
});

test('a to do that needs a note refuses an empty one', () => {
  const t = todo({ needs_note: true });
  for (const n of ['', '   ', undefined, null]) assert.throws(() => C.requireNote(t, n), /Note needed/);
  C.requireNote(t, 'booked it');
  C.requireNote(todo({ needs_note: false }), '');
});

test('Edited shows for the owner until they next log it', () => {
  const t = todo({ owner_id: ME, created_by: YOU, edited_at: iso('2026-10-22', 12) });
  const ev = (h) => [{ todo_id: 't1', user_id: ME, kind: 'tally', at: iso('2026-10-22', h) }];
  assert.equal(C.isEdited(t, [], ME), true);
  assert.equal(C.isEdited(t, ev(9), ME), true); // logged before the edit
  assert.equal(C.isEdited(t, ev(15), ME), false); // logged after
  assert.equal(C.isEdited(t, [], YOU), false); // the editor never sees it
  assert.equal(C.isEdited(todo({ owner_id: ME, created_by: ME, edited_at: iso('2026-10-22', 12) }), [], ME), false);
});
test('askToAck: recipient authors a requested ack, sender requested it, item linked', () => {
  const couple = { id: 'c', hold_ask_min: 0, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 };
  const item = C.buildItem({ id: 'i', couple, me: ME, to: YOU, kind: 'ask', ask_type: 'ack', body: 'I go meta', description: 'It escalates', now: 1000 });
  assert.deepEqual([item.points_earn, item.points_miss, item.target, item.period], [null, null, null, null]);
  const a = C.askToAck(item, 'a1', 1000);
  assert.deepEqual([a.author_id, a.requested_by, a.item_id, a.title, a.description, a.status, a.done_at, a.read_at], [YOU, ME, 'i', 'I go meta', 'It escalates', 'requested', null, null]);
  assert.throws(() => C.askToAck({ ...item, ask_type: 'task' }, 'a2', 1000), /needs an ack ask/);
});

test('needsYou: a requested ack to me, then partner acks I have not read; own, read, deleted and done-by-me excluded', () => {
  const now = at('2026-10-22', 21);
  const ack = (id, author, extra) => ({ id, author_id: author, requested_by: author === ME ? YOU : null, status: 'done', created_at: iso('2026-10-22', 9), done_at: iso('2026-10-22', 10), read_at: null, deleted_at: null, title: id, ...extra });
  const acks = [
    ack('req', ME, { status: 'requested', done_at: null }),
    ack('reqdel', ME, { status: 'requested', done_at: null, deleted_at: iso('2026-10-22', 11) }),
    ack('reqher', YOU, { status: 'requested', done_at: null }),
    ack('in1', YOU), ack('in2', YOU, { done_at: iso('2026-10-22', 12) }),
    ack('inread', YOU, { read_at: iso('2026-10-22', 13) }), ack('indel', YOU, { deleted_at: iso('2026-10-22', 13) }),
    ack('mine', ME, { requested_by: null }),
  ];
  const n = C.needsYou({ me: ME, now, tz: TZ, items: [], redemptions: [], nudge_sends: [], nudge_replies: [], fight_markers: [], fight_notes: [], acks });
  assert.deepEqual(n.map((x) => x.type + ':' + x.ack.id), ['ackreq:req', 'ackin:in2', 'ackin:in1']);
});


test('no-fight challenge pays its streak day number and a fight resets it', () => {
  const fm = (id, d) => ({ id, at: iso(d, 15), logged_by: ME, hit_self: false });
  const ch = (l) => l.challenges.find((c) => c.id === 'no-fight');
  const pays = (l) => Object.values(l.weeks).flatMap((w) => Object.values(w.days).flatMap((d) => d.lines.filter((x) => x.label === 'No fights').map((x) => [d.day, x.pts, x.who])));

  // Start day still in progress: nothing paid yet, today is day 1.
  let l = L(rows(), at('2026-10-26', 20));
  assert.deepEqual(pays(l), []);
  assert.deepEqual(ch(l), { id: 'no-fight', name: 'No fights', day: 1, best: 0, earned: 0 });

  // Three clean days: +1, +2, +3; today is day 4.
  l = L(rows(), at('2026-10-29', 9));
  assert.deepEqual(pays(l), [['2026-10-26', 1, 'Day 1'], ['2026-10-27', 2, 'Day 2'], ['2026-10-28', 3, 'Day 3']]);
  assert.equal(ch(l).day, 4); assert.equal(ch(l).earned, 6);

  // Fight on the 28th: that day pays nothing, the 29th is day 1 again, best stays 2.
  l = L(rows({ fight_markers: [fm('f1', '2026-10-28')] }), at('2026-10-30', 9));
  assert.deepEqual(pays(l), [['2026-10-26', 1, 'Day 1'], ['2026-10-27', 2, 'Day 2'], ['2026-10-29', 1, 'Day 1']]);
  assert.deepEqual(ch(l), { id: 'no-fight', name: 'No fights', day: 2, best: 2, earned: 4 });

  // Fight today: day 0, and fights before the start date never count.
  l = L(rows({ fight_markers: [fm('f0', '2026-10-20'), fm('f2', '2026-10-27')] }), at('2026-10-27', 18));
  assert.equal(ch(l).day, 0); assert.deepEqual(pays(l), [['2026-10-26', 1, 'Day 1']]);
});

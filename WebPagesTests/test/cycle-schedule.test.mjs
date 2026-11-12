// Scheduled to dos: written at once, stamped with their future time T, invisible to both partners until T.
// Core logic is pure (vm-loaded); the screens, the save flow, Cancel and wanted() run in WebKit
// (set GL_WEBKIT_PW/GL_WEBKIT_EXEC, see ~/.claude/bin/cycle-webkit.sh); skipped without it.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import C from './cycle-load.mjs';

const TZ = 'America/New_York';
const NOW = Date.parse('2026-10-21T15:00:00Z'); // Wed 11:00 New York
const T = Date.parse('2026-10-23T13:00:00Z'); // Fri 09:00 New York
const iso = (ms) => new Date(ms).toISOString();
const ME = 'u-me', HER = 'u-her';
const couple = { id: 'c1', tz: TZ, created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 };

// The import must run before the first describe: under `node --test` (Node 20) a describe registered after a top-level
// await, once an earlier describe exists, is silently never run, which hid this file's whole webkit block until 2026-11.
const haveWebkit = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = haveWebkit ? await import(process.env.GL_WEBKIT_PW) : null;

describe('core', () => {
  test('isScheduled: future delivered_at / created_at is scheduled, now and past are not', () => {
    assert.equal(C.isScheduled({ created_at: iso(T) }, NOW), true);
    assert.equal(C.isScheduled({ created_at: iso(NOW) }, NOW), false);
    assert.equal(C.isScheduled({ created_at: iso(NOW - 1000) }, NOW), false);
    assert.equal(C.isScheduled({ created_at: iso(NOW), delivered_at: iso(T) }, NOW), true);
  });

  test('partner-bound schedule: delivered item (no held status) plus a todo stamped T; T clamps to now + hold', () => {
    const at = C.scheduleAt(couple, 'ask', T, NOW);
    assert.equal(at, T);
    const item = C.buildItem({ id: 'i1', couple, me: ME, to: HER, kind: 'ask', body: 'Bins', ask_type: 'task', now: NOW, at });
    assert.equal(item.status, 'delivered');
    assert.equal(item.held_until, null);
    assert.equal(item.delivered_at, iso(T));
    const todo = C.askToTodo(item, 't1', C.ms(item.delivered_at));
    assert.equal(todo.created_at, iso(T));
    assert.equal(todo.owner_id, HER);
    const ownup = C.askToTodo(C.buildItem({ id: 'i2', couple, me: ME, to: HER, kind: 'ask', body: 'Sorry', ask_type: 'ownup', now: NOW, at }), 'a1', T);
    assert.equal(ownup.created_at, iso(T));
    assert.equal(ownup.type, 'ownup');
    const early = C.scheduleAt(couple, 'ask', NOW + 10 * 60000, NOW);
    assert.equal(early, NOW + 60 * 60000);
    assert.equal(C.buildItem({ id: 'i3', couple, me: ME, to: HER, kind: 'ask', body: 'x', now: NOW }).status, 'held');
  });

  test('the ledger does not count a scheduled row before T', () => {
    const members = [{ user_id: ME, name: 'Me' }, { user_id: HER, name: 'Her' }];
    const todo = { id: 't1', type: 'task', title: 'Old', owner_id: ME, due_date: '2026-10-01', done_at: null, fight_marker_id: null, deleted_at: null, created_at: iso(T) };
    const rows = (t) => ({ members, items: [], todos: t, todo_events: [], fight_markers: [], redemptions: [], nudge_sends: [], nudge_awards: [] });
    const run = (t, now) => C.computeLedger(rows(t), { tz: TZ, now, since: '2026-10-21' });
    const overdue = (l) => JSON.stringify(l).split('overdue').length - 1;
    const early = run([todo], NOW);
    assert.equal(overdue(early), overdue(run([], NOW)));
    assert.equal(JSON.stringify(early), JSON.stringify(run([], NOW)));
    assert.notEqual(JSON.stringify(run([todo], T + 1000)), JSON.stringify(run([], T + 1000)));
  });

  test('needsYou hides a scheduled finished owning-up until T', () => {
    const ownup = { id: 'a1', type: 'ownup', owner_id: ME, title: 'x', deleted_at: null, created_at: iso(T), done_at: iso(T) };
    const s = (now) => ({ me: HER, now, items: [], redemptions: [], nudge_sends: [], nudge_replies: [], fight_markers: [], fight_notes: [], todos: [ownup], seen: [], since: 0 });
    const before = JSON.stringify(C.needsYou(s(NOW)));
    const after = JSON.stringify(C.needsYou(s(T + 1)));
    assert.notEqual(before, after);
    assert.ok(!before.includes('a1'));
  });
});

const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';

const base = { couple_id: 'c1', updated_at: iso(NOW - 864e5), deleted_at: null };
const td = (id, o) => ({ ...base, id, owner_id: ME, created_by: ME, item_id: null, fight_marker_id: null, title: id, description: null, type: 'task', due_date: null, target: null, period: null, points_earn: null, points_miss: null, needs_note: false, edited_at: null, tally: 0, done_at: null, created_at: iso(NOW - 864e5), ...o });
const item = (id, o) => ({ ...base, id, sender_id: ME, recipient_id: HER, kind: 'ask', body: id, ask_type: 'task', description: null, due_date: null, target: null, period: null, points_earn: null, points_miss: null, needs_note: false, origin: null, response_type: null, fight_marker_id: null, held_until: null, status: 'delivered', delivered_at: iso(T), opened_at: null, kept: null, created_at: iso(NOW - 6e4), ...o });
const byId = (rs) => Object.fromEntries(rs.map((r) => [r.id, r]));

describe('webkit', { skip: !haveWebkit }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  async function open({ uid = ME, rows = {}, now = NOW, boxUrl = '' } = {}) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(now));
    const sd = {
      session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: uid, email: 'x@x.test' } },
      ['shared.' + uid]: { couple, members: [{ user_id: ME, name: 'Me', checkin_time: '21:00', hits_self: false }, { user_id: HER, name: 'Her', checkin_time: '21:00', hits_self: true }],
        rows: { items: byId(rows.items || []), todos: byId(rows.todos || []), todo_events: {}, checkins: {}, fight_markers: {}, rewards: {}, redemptions: {}, nudges: {}, nudge_sends: {}, nudge_replies: {}, nudge_awards: {}, fight_notes: {}, challenges: {} }, cursors: {}, outbox: [] },
      ['priv.' + uid]: { fights: [], affirmations: [], prefs: {}, queued: [], nudges: [], nudge_sends: [] },
    };
    await context.addInitScript(([sd, boxUrl]) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl };
      if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
      window.__calls = [];
      window.webkit = { messageHandlers: { cycle: { postMessage: ({ id, cmd, args }) => {
        window.__calls.push({ cmd, args });
        let r = null;
        if (cmd === 'store.get') r = localStorage.getItem('cycle:' + args.key);
        else if (cmd === 'store.set') { if (args.value === null) localStorage.removeItem('cycle:' + args.key); else localStorage.setItem('cycle:' + args.key, args.value); }
        else if (cmd === 'store.keys') r = Object.keys(localStorage).filter((k) => k.indexOf('cycle:' + args.prefix) === 0).map((k) => k.slice(6));
        else if (cmd === 'notify.status') r = 'granted';
        else if (cmd === 'lock.get') r = false;
        else if (cmd === 'notify.permission') r = true;
        setTimeout(() => window.__cycleReply && window.__cycleReply(id, r, null), 0);
      } } } };
    }, [sd, boxUrl]);
    await context.route('https://x.test/**', (r) => r.abort());
    const boxReqs = [];
    await context.route('https://box.test/**', (r) => { const q = r.request(); boxReqs.push({ method: q.method(), url: q.url(), auth: q.headers().authorization, body: q.postData() }); return r.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' }); });
    const page = await context.newPage();
    page.boxReqs = boxReqs;
    page.on('pageerror', (e) => console.error('PAGEERROR', String(e)));
    await context.route('**/cycle.css', (r) => r.fulfill({ contentType: 'text/css', body: CSS }));
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-a="go:fight"]', { timeout: 8000 });
    return { context, page };
  }
  const act = (page, a) => page.evaluate((a) => { const m = document.querySelector('main'); m.insertAdjacentHTML('beforeend', `<span id="nv" data-a="${a}">x</span>`); const el = document.getElementById('nv'); el.click(); el.remove(); }, a);
  const text = (page) => page.evaluate(() => document.body.textContent);
  const outbox = async (page) => { await page.waitForTimeout(150); return page.evaluate(() => JSON.parse(localStorage.getItem('cycle:shared.' + JSON.parse(localStorage.getItem('cycle:session')).user.id)).outbox); };
  const clockTo = async (context, page, ms) => { await context.clock.setFixedTime(new Date(ms)); await page.evaluate(() => window.cycleNative.foreground()); };

  test('a scheduled self to do is hidden before T and visible after', async () => {
    const { context, page } = await open({ rows: { todos: [td('Plan trip', { created_at: iso(T) })] } });
    await act(page, 'tab:todo');
    let t = await text(page);
    assert.ok(t.includes('Scheduled') && t.includes('Plan trip') && t.includes('Shows '), 'sender sees it only under Scheduled');
    await clockTo(context, page, T + 1000);
    await act(page, 'tab:todo');
    t = await text(page);
    assert.ok(t.includes('Plan trip') && !t.includes('Scheduled'));
    await context.close();
  });

  test('a to do scheduled for her is hidden from her until T, listed for me as Scheduled with its time', async () => {
    const rows = { items: [item('i1')], todos: [td('Take bins', { owner_id: HER, item_id: 'i1', created_at: iso(T) })] };
    const her = await open({ uid: HER, rows });
    await act(her.page, 'tab:todo');
    assert.ok(!(await text(her.page)).includes('Take bins'));
    await clockTo(her.context, her.page, T + 1000);
    await act(her.page, 'tab:todo');
    assert.ok((await text(her.page)).includes('Take bins'));
    await her.context.close();
    const me = await open({ uid: ME, rows });
    await act(me.page, 'tab:todo');
    const t = await text(me.page);
    assert.ok(t.includes('Scheduled') && t.includes('Take bins') && t.includes('Sends Fri 9:00am'), t);
    await me.context.close();
  });

  test('saving a to do for her with Later: delivered item (never held) + todo stamped T; early picks clamp to now + hold', async () => {
    const { context, page } = await open({});
    const setWhen = (d, t) => page.evaluate(([d, t]) => { for (const [k, v] of [['schD', d], ['schT', t]]) { const i = document.querySelector(`[data-d=${k}]`); i.value = v; i.dispatchEvent(new Event('input', { bubbles: true })); i.dispatchEvent(new Event('change', { bubbles: true })); } }, [d, t]);
    await act(page, 'tab:todo'); await act(page, 'addpick'); await act(page, 'newtodo:task');
    await page.fill('[data-d=title]', 'Take bins');
    await act(page, 'nwhen:later');
    await setWhen('2026-10-23', '09:00');
    await act(page, 'savetodo');
    let ob = await outbox(page);
    const item1 = ob.find((o) => o.table === 'items').row, todo1 = ob.find((o) => o.table === 'todos').row;
    assert.equal(item1.status, 'delivered'); assert.equal(item1.held_until, null); assert.equal(item1.delivered_at, iso(T));
    assert.equal(todo1.created_at, iso(T)); assert.equal(todo1.owner_id, HER);
    assert.equal(todo1.scheduled_at, iso(NOW), 'the moment it was written');
    await act(page, 'addpick'); await act(page, 'newtodo:task');
    await page.fill('[data-d=title]', 'Soon');
    await act(page, 'nwhen:later');
    await setWhen('2026-10-21', '11:10');
    await act(page, 'savetodo');
    ob = await outbox(page);
    const soon = ob.filter((o) => o.table === 'todos').map((o) => o.row).find((r) => r.title === 'Soon');
    assert.equal(soon.created_at, iso(NOW + 60 * 60000));
    await context.close();
  });

  test('wanted(): only my own scheduled to do notifies locally; the partner\'s to dos come as remote push', async () => {
    const rows = { todos: [td('My own later', { created_at: iso(T) }), td('From her', { created_by: HER, created_at: iso(T) }), td('Gone', { created_at: iso(T), deleted_at: iso(NOW) })] };
    const { context, page } = await open({ uid: ME, rows });
    await page.waitForTimeout(800);
    const all = await page.evaluate(() => window.__calls.filter((x) => x.cmd.indexOf('notify') === 0).map((x) => ({ cmd: x.cmd, args: x.args })));
    const sched = JSON.stringify(all);
    assert.ok(sched.includes('My own later'), 'own scheduled to do missing in ' + sched);
    for (const b of ['From her', 'Gone']) assert.ok(!sched.includes(b), b + ' present in ' + sched);
    await context.close();
  });

  test('a real tap on Pause inside the tappable row pauses and does not open the edit sheet; a tap on the row opens its page, Edit opens the sheet', async () => {
    const { context, page } = await open({ rows: { todos: [td('Plan trip', { created_at: iso(T) })] } });
    await act(page, 'tab:todo');
    await page.click('.hrow2 .ht');
    assert.ok(await page.$('[data-a^="schednow:"]'), 'row tap opens the page with Send now');
    assert.equal(await page.$('[data-a="savetodo"]'), null);
    await page.click('[data-a^="etodo:"]');
    assert.ok(await page.$('[data-a="savetodo"]'), 'Edit opens the edit sheet');
    await act(page, 'sheet:close'); await act(page, 'back');
    await page.click('[data-a^="schedpause:"]');
    assert.equal(await page.$('[data-a="savetodo"]'), null, 'Pause must not open the edit sheet');
    assert.ok((await text(page)).includes('Paused'));
    await context.close();
  });

  test('push token handoff: cycleNative.pushToken POSTs it to the box /push/register with the session bearer, once', async () => {
    const { context, page } = await open({ boxUrl: 'https://box.test' });
    await page.waitForTimeout(500);
    assert.deepEqual(page.boxReqs, [], 'nothing is sent before native hands over a token');
    await page.evaluate(() => window.cycleNative.pushToken('ab12cd34'));
    await page.waitForTimeout(500);
    assert.deepEqual(page.boxReqs.map((r) => [r.method, r.url, r.auth, JSON.parse(r.body)]), [['POST', 'https://box.test/push/register', 'Bearer t', { token: 'ab12cd34' }]]);
    await page.evaluate(() => window.cycleNative.pushToken('ab12cd34'));
    await page.waitForTimeout(300);
    assert.equal(page.boxReqs.length, 1, 'the same token for the same account is not re-registered');
    await page.evaluate(() => window.cycleNative.pushToken('ef56'));
    await page.waitForTimeout(300);
    assert.equal(page.boxReqs.length, 2);
    await context.close();
  });

  test('Cancel soft-deletes the todo and its item', async () => {
    const rows = { items: [item('i1')], todos: [td('Take bins', { owner_id: HER, item_id: 'i1', created_at: iso(T) })] };
    const { context, page } = await open({ rows });
    await act(page, 'tab:todo');
    await page.click('[data-a="schedcancel:Take bins"]');
    assert.ok(!(await text(page)).includes('Take bins'));
    const ob = await outbox(page);
    const patched = (table, id) => ob.some((o) => JSON.stringify(o).includes(table) && JSON.stringify(o).includes(id) && JSON.stringify(o).includes('deleted_at'));
    assert.ok(patched('todos', 'Take bins') && patched('items', 'i1'), JSON.stringify(ob));
    await context.close();
  });

  test('Edit on a scheduled row opens the edit sheet; Save renames the todo and its item and keeps it scheduled', async () => {
    const rows = { items: [item('i1')], todos: [td('Take bins', { owner_id: HER, item_id: 'i1', created_at: iso(T), type: 'ownup' })] };
    const { context, page } = await open({ rows });
    await act(page, 'tab:todo');
    const shots = process.env.LAYOUT_SHOTS; // optional evidence screenshots, same env as the layout sweep
    if (shots) await page.screenshot({ path: path.join(shots, 'sched-edit-row.png') });
    await page.click('.hrow2 .ht'); // Edit sits in the opened page's header, not on the row
    await page.click('[data-a="etodo:Take bins"]');
    if (shots) await page.screenshot({ path: path.join(shots, 'sched-edit-sheet.png') });
    assert.equal(await page.inputValue('[data-d=title]'), 'Take bins');
    await page.fill('[data-d=title]', 'Charger');
    await page.click('[data-a="savetodo"]');
    const t = await text(page);
    assert.ok(t.includes('Charger') && !t.includes('Take bins'), t);
    const ob = await outbox(page), s = JSON.stringify(ob);
    const todoPatch = ob.find((o) => o.table === 'todos' && JSON.stringify(o).includes('Charger'));
    assert.ok(todoPatch && !JSON.stringify(todoPatch).includes('created_at'), 'schedule time untouched: ' + s);
    assert.ok(ob.some((o) => o.table === 'items' && JSON.stringify(o).includes('Charger')), s);
    await context.close();
  });

  test('Delete in a scheduled row\'s edit sheet soft-deletes the todo and its item, like Cancel', async () => {
    const rows = { items: [item('i1')], todos: [td('Take bins', { owner_id: HER, item_id: 'i1', created_at: iso(T) })] };
    const { context, page } = await open({ rows });
    await act(page, 'tab:todo');
    await page.click('.hrow2 .ht'); // Edit sits in the opened page's header, not on the row
    await page.click('[data-a="etodo:Take bins"]');
    await page.click('[data-a="tododel:Take bins"]');
    assert.ok(!(await text(page)).includes('Take bins'));
    const ob = await outbox(page), del = (table, id) => ob.some((o) => o.table === table && o.id === id && JSON.stringify(o).includes('deleted_at'));
    assert.ok(del('todos', 'Take bins') && del('items', 'i1'), JSON.stringify(ob));
    await context.close();
  });

  // Pause: created_at is immutable, so the to do moves to S.priv.paused and its rows are soft-deleted; Resume re-creates it.
  const priv = async (page) => { await page.waitForTimeout(150); return page.evaluate(() => JSON.parse(localStorage.getItem('cycle:priv.u-me'))); };
  const openTitles = (page) => page.evaluate(() => [...document.querySelectorAll('[data-a^="tview:"]')].map((e) => e.textContent));
  const inserts = (ob, table) => ob.filter((o) => o.table === table && o.row).map((o) => o.row);
  const deleted = (ob, table, id) => ob.some((o) => o.table === table && o.id === id && JSON.stringify(o).includes('deleted_at'));

  test('Pause keeps a self to do listed as Paused, deletes its row, never opens at T, and cancels its local notification', async () => {
    const { context, page } = await open({ rows: { todos: [td('Plan trip', { created_at: iso(T) })] } });
    await act(page, 'tab:todo');
    await page.click('[data-a="schedpause:Plan trip"]');
    const t = await text(page);
    assert.ok(t.includes('Scheduled') && t.includes('Plan trip') && t.includes('Paused'), t);
    assert.ok(deleted(await outbox(page), 'todos', 'Plan trip'));
    const p = (await priv(page)).paused;
    assert.equal(p.length, 1); assert.equal(p[0].f.title, 'Plan trip'); assert.equal(p[0].at, T); assert.equal(p[0].who, 'me');
    await clockTo(context, page, T + 1000);
    await act(page, 'tab:todo');
    assert.ok((await text(page)).includes('Paused'));
    assert.deepEqual(await openTitles(page), [], 'paused to do must not open at T');
    const cancels = await page.evaluate(() => window.__calls.filter((x) => x.cmd === 'notify.cancel').map((x) => JSON.stringify(x.args)));
    assert.ok(cancels.some((c) => c.includes('sched-Plan trip')), JSON.stringify(cancels));
    await context.close();
  });

  test('Resume before T re-creates the to do at T; after T it is created now and opens at once', async () => {
    const early = await open({ rows: { todos: [td('Plan trip', { created_at: iso(T) })] } });
    await act(early.page, 'tab:todo');
    await early.page.click('[data-a="schedpause:Plan trip"]');
    await early.page.click('[data-a^="schedresume:"]');
    const made = inserts(await outbox(early.page), 'todos').filter((r) => r.title === 'Plan trip' && r.id !== 'Plan trip');
    assert.equal(made.length, 1); assert.equal(made[0].created_at, iso(T));
    assert.deepEqual((await priv(early.page)).paused, []);
    assert.ok(!(await text(early.page)).includes('Paused'));
    await early.context.close();
    const late = await open({ rows: { todos: [td('Plan trip', { created_at: iso(T) })] } });
    await act(late.page, 'tab:todo');
    await late.page.click('[data-a="schedpause:Plan trip"]');
    await clockTo(late.context, late.page, T + 1000);
    await act(late.page, 'tab:todo');
    await late.page.click('[data-a^="schedresume:"]');
    const made2 = inserts(await outbox(late.page), 'todos').filter((r) => r.title === 'Plan trip' && r.id !== 'Plan trip');
    assert.equal(made2.length, 1); assert.equal(made2[0].created_at, iso(T + 1000));
    assert.ok((await openTitles(late.page)).some((x) => x.startsWith('Plan trip')));
    assert.ok(!(await text(late.page)).includes('Paused'));
    await late.context.close();
  });

  test('a to do scheduled for her: Pause deletes todo and item, Resume before T inserts a new delivered item and todo at T', async () => {
    const rows = { items: [item('i1')], todos: [td('Take bins', { owner_id: HER, item_id: 'i1', created_at: iso(T) })] };
    const { context, page } = await open({ rows });
    await act(page, 'tab:todo');
    await page.click('[data-a="schedpause:Take bins"]');
    let ob = await outbox(page);
    assert.ok(deleted(ob, 'todos', 'Take bins') && deleted(ob, 'items', 'i1'), JSON.stringify(ob));
    assert.equal((await priv(page)).paused[0].who, 'them');
    await page.click('[data-a^="schedresume:"]');
    ob = await outbox(page);
    const newItem = inserts(ob, 'items')[0], newTodo = inserts(ob, 'todos').find((r) => r.id !== 'Take bins');
    assert.ok(newItem && newTodo, JSON.stringify(ob));
    assert.equal(newItem.status, 'delivered'); assert.equal(newItem.delivered_at, iso(T));
    assert.equal(newTodo.created_at, iso(T)); assert.equal(newTodo.owner_id, HER);
    await context.close();
  });

  test('Cancel on a paused entry removes it and inserts nothing', async () => {
    const { context, page } = await open({ rows: { todos: [td('Plan trip', { created_at: iso(T) })] } });
    await act(page, 'tab:todo');
    await page.click('[data-a="schedpause:Plan trip"]');
    const before = (await outbox(page)).length;
    await page.click('[data-a^="pausedcancel:"]');
    const t = await text(page);
    assert.ok(!t.includes('Plan trip') && !t.includes('Paused'), t);
    assert.deepEqual((await priv(page)).paused, []);
    assert.equal((await outbox(page)).length, before);
    await context.close();
  });

  test('a paused to do survives a reload', async () => {
    const { context, page } = await open({ rows: { todos: [td('Plan trip', { created_at: iso(T) })] } });
    await act(page, 'tab:todo');
    await page.click('[data-a="schedpause:Plan trip"]');
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-a="go:fight"]', { timeout: 8000 });
    await act(page, 'tab:todo');
    const t = await text(page);
    assert.ok(t.includes('Plan trip') && t.includes('Paused'), t);
    await context.close();
  });

  test('scheduled_at: a Later to do for me carries it, a Now to do does not', async () => {
    const { context, page } = await open({});
    const save = async (title, when) => {
      await act(page, 'addpick'); await act(page, 'newtodo:task');
      await act(page, 'nfor:me');
      await page.fill('[data-d=title]', title);
      if (when) {
        await act(page, 'nwhen:later');
        await page.evaluate(([d, t]) => { for (const [k, v] of [['schD', d], ['schT', t]]) { const i = document.querySelector(`[data-d=${k}]`); i.value = v; i.dispatchEvent(new Event('input', { bubbles: true })); i.dispatchEvent(new Event('change', { bubbles: true })); } }, when);
      }
      await act(page, 'savetodo');
    };
    await act(page, 'tab:todo');
    await save('Later self', ['2026-10-23', '09:00']);
    await save('Now self', null);
    const rows = (await outbox(page)).filter((o) => o.table === 'todos').map((o) => o.row);
    assert.equal(rows.find((r) => r.title === 'Later self').scheduled_at, iso(NOW));
    assert.ok(!rows.find((r) => r.title === 'Now self').scheduled_at, 'a to do sent at once has no scheduled_at');
    await context.close();
  });

  test('detail page: a delivered to do with scheduled_at shows the Scheduled line, one without shows none', async () => {
    const rows = { todos: [td('Was later', { scheduled_at: iso(NOW - 864e5) }), td('Was now')] };
    const { context, page } = await open({ rows });
    await act(page, 'tview:Was later');
    const line = await page.textContent('.schd');
    assert.ok(line.startsWith('Scheduled'), line);
    await act(page, 'back');
    await act(page, 'tview:Was now');
    assert.equal(await page.locator('.schd').count(), 0);
    await context.close();
  });

  const schedRows = () => ({ items: [item('i1')], todos: [td('Take bins', { owner_id: HER, item_id: 'i1', created_at: iso(T) })] });

  test('tapping the Scheduled row opens the detail with Send now and no Comments', async () => {
    const { context, page } = await open({ rows: schedRows() });
    await act(page, 'tab:todo');
    await page.click('.td-row.hrow2 .ht');
    assert.equal(await page.locator('[data-a="schednow:Take bins"]').count(), 1);
    assert.ok((await page.textContent('.schd')).startsWith('Sends '));
    assert.ok(!(await text(page)).includes('Comments'));
    await context.close();
  });

  test('Send now for a For = You to do: old row deleted, a live one with the same title in the open list, Scheduled gone', async () => {
    const rows = { todos: [td('Plan trip', { created_at: iso(T) })] };
    const { context, page } = await open({ rows });
    await act(page, 'tab:todo');
    await page.click('.td-row.hrow2 .ht');
    await page.click('[data-a="schednow:Plan trip"]');
    const t = await text(page);
    assert.ok(t.includes('Plan trip') && !t.includes('Scheduled'), t);
    const ob = await outbox(page);
    assert.ok(ob.some((o) => o.table === 'todos' && o.id === 'Plan trip' && JSON.stringify(o).includes('deleted_at')), JSON.stringify(ob));
    const fresh = ob.filter((o) => o.table === 'todos' && o.row).map((o) => o.row).find((r) => r.title === 'Plan trip');
    assert.ok(fresh && fresh.id !== 'Plan trip' && !fresh.deleted_at && fresh.created_at === iso(NOW), JSON.stringify(fresh));
    await context.close();
  });

  test('Send now for a partner-bound to do with hold 60: old todo and item deleted, a new held item', async () => {
    const { context, page } = await open({ rows: schedRows() });
    await act(page, 'tab:todo');
    await page.click('.td-row.hrow2 .ht');
    await page.click('[data-a="schednow:Take bins"]');
    const ob = await outbox(page), del = (table, id) => ob.some((o) => o.table === table && o.id === id && JSON.stringify(o).includes('deleted_at'));
    assert.ok(del('todos', 'Take bins') && del('items', 'i1'), JSON.stringify(ob));
    const held = ob.filter((o) => o.table === 'items' && o.row).map((o) => o.row).find((r) => r.body === 'Take bins');
    assert.ok(held && held.status === 'held' && held.id !== 'i1', JSON.stringify(held));
    await context.close();
  });
});

// To-dos and reminders "for Both": a Both to-do is ONE shared row (owner = partner, created_by = sender, shared = true)
// that sits in both people's Open list tagged Both, with Done for either; a Both reminder sends in the shared tier (to the
// partner) and the private Me tier. Real app in headless WebKit against seeded localStorage; the backend is aborted
// (offline) so every write is observed in the store's own persistence. Needs GL_WEBKIT_PW / GL_WEBKIT_EXEC
// (see cycle-fight.test.mjs). SHARED_SHOTS=<dir> also writes screenshots.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HAS_WK = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = HAS_WK ? await import(process.env.GL_WEBKIT_PW) : null;
const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const SHOTS = process.env.SHARED_SHOTS;
if (SHOTS) fs.mkdirSync(SHOTS, { recursive: true });

const ME = 'u-me', HER = 'u-her';
const LONG = 'Bartholomew-Alexandria'; // the partner's name in the 390px fit check
const NOW = '2026-10-21T15:00:00Z'; // Wed 11:00 New York
const NIGHT = '2026-10-22T01:00:00Z'; // Wed 9 pm New York, after the 8 pm reminder cutoff
const td = (id, o = {}) => ({ id, couple_id: 'c1', owner_id: HER, created_by: ME, item_id: null, fight_marker_id: null, title: id, description: null, type: 'task',
  due_date: null, target: null, period: null, points_earn: null, points_miss: null, needs_note: false, edited_at: null, tally: 0, done_at: null,
  created_at: '2026-10-05T12:00:00Z', updated_at: '2026-10-05T12:00:00Z', deleted_at: null, ...o });
const BOTH = td('both', { title: 'Plan the trip', shared: true });

function seed(who, { todos = [], events = [], hold = 0, herName = 'Esme' } = {}) {
  const byId = (a) => Object.fromEntries(a.map((r) => [r.id, r]));
  return {
    session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: who, email: who + '@x.test' } },
    ['shared.' + who]: { couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: hold },
      members: [{ user_id: ME, name: 'Me', checkin_time: '21:00' }, { user_id: HER, name: herName, checkin_time: '21:00' }],
      rows: { items: {}, todos: byId(todos), todo_events: byId(events), checkins: {}, fight_markers: {}, rewards: {}, redemptions: {}, nudges: {}, nudge_sends: {}, nudge_replies: {}, nudge_awards: {} },
      cursors: {}, outbox: [] },
    ['priv.' + who]: { fights: [], affirmations: [], prefs: {} },
  };
}

describe('for Both (webkit)', { skip: !HAS_WK && 'needs GL_WEBKIT_PW and GL_WEBKIT_EXEC' }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  async function open(s, at = NOW) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(at));
    await context.addInitScript((sd) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, s);
    await context.route('**/cycle.css', (r) => r.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (r) => r.abort()); // offline: writes stay in the outbox
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.click('[data-a="tab:todo"]');
    await page.waitForSelector('[data-a="addpick"]');
    return { context, page };
  }
  // The store persists on a debounce through an async kv: wait until `ok` holds on the stored state, then return it.
  async function stored(page, who, ok = () => true) {
    const key = 'cycle:shared.' + who, fn = `(() => { const s = JSON.parse(localStorage.getItem('${key}')); return (${ok.toString()})(s); })()`;
    await page.waitForFunction(fn);
    return page.evaluate((k) => JSON.parse(localStorage.getItem(k)), key);
  }
  const shot = (page, name) => SHOTS && page.screenshot({ path: path.join(SHOTS, name + '.png') });
  const openRows = (page) => page.$$eval('[data-todo]', (es) => es.map((e) => ({ id: e.dataset.todo, tag: [...e.querySelectorAll('.tt')].map((t) => t.textContent).join('|'), done: !!e.querySelector('.done') })));

  async function newTodoBoth(page) {
    await page.click('[data-a="addpick"]');
    await page.click('.bs [data-a="newtodo:task"]');
    await page.click('[data-a="nfor:both"]');
    await page.fill('input[data-d="title"]', 'Plan the trip');
    await page.click('[data-a="savetodo"]');
  }

  test('hold 0: a Both to-do is ONE shared row, once in my Open list tagged Both with Done', async () => {
    const { page, context } = await open(seed(ME, { hold: 0 }));
    await newTodoBoth(page);
    const s = await stored(page, ME, (x) => Object.keys(x.rows.todos).length === 1);
    const [item] = Object.values(s.rows.items), [todo] = Object.values(s.rows.todos);
    assert.deepEqual([item.kind, item.shared, item.status], ['ask', true, 'delivered']);
    assert.deepEqual([todo.shared, todo.owner_id, todo.created_by, todo.item_id], [true, HER, ME, item.id]);
    // Once: in mine, not repeated under the partner's rows; the header counts it for me, not twice.
    assert.deepEqual(await openRows(page), [{ id: todo.id, tag: 'Both', done: true }]);
    assert.equal(await page.$eval('.dl', (e) => e.textContent), 'You 1 · Esme 1');
    await shot(page, 'both-created');
    await context.close();
  });

  test('the partner sees the same row tagged Both with Done; their Done closes it for both', async () => {
    const her = await open(seed(HER, { todos: [BOTH] }));
    assert.deepEqual(await openRows(her.page), [{ id: 'both', tag: 'Both', done: true }]);
    await shot(her.page, 'both-partner');
    await her.page.click('[data-a="done:both"]');
    const sh = await stored(her.page, HER, (x) => x.rows.todos.both.done_at);
    const ev = Object.values(sh.rows.todo_events);
    assert.deepEqual(ev.map((e) => [e.todo_id, e.user_id, e.kind]), [['both', HER, 'done']]);
    assert.deepEqual(await openRows(her.page), []); // closed: leaves Open
    await her.context.close();

    // Oliver's phone after the sync: the same shared row is closed there too, and the detail page names who did it.
    const done = { ...BOTH, done_at: '2026-10-21T14:00:00Z' };
    const me = await open(seed(ME, { todos: [done], events: [{ id: 'e1', couple_id: 'c1', todo_id: 'both', user_id: HER, kind: 'done', at: '2026-10-21T14:00:00Z', note: null, deleted_at: null }] }));
    assert.deepEqual(await openRows(me.page), []);
    await me.page.click('[data-a="doneopen"]');
    assert.equal(await me.page.$eval('.dn .tt', (e) => e.textContent), 'Both');
    await me.page.click('[data-a="tview:both"]');
    const facts = await me.page.$$eval('.frow', (es) => es.map((e) => e.textContent));
    // From, For, Done and who ticked it are one line above the facts; no separate For / From / Done / Done by rows remain.
    assert.match(await me.page.$eval('.tdd2 .who', (e) => e.textContent), /^\S+→Both·Done .+·Esme$/);
    assert.ok(!facts.some((f) => /^(For|From|Done)/.test(f)), facts.join('|'));
    assert.equal(await me.page.$eval('.tdd2 header + section > p', (e) => e.className), 'meta who', 'the line is the first thing under the header');
    assert.equal(await me.page.$eval('.tdd2 .who', (e) => e.scrollWidth <= e.clientWidth && e.getBoundingClientRect().height < 24), true, 'the line fits on one line');
    assert.equal(await me.page.$('[data-a="tundo:both"]'), null, "the partner's tick has no Undo for me (events are undone by their author)");
    assert.equal(await me.page.$('[data-a^="tnudge"]'), null);
    await me.context.close();
  });

  test('an open Both to-do has no Ping, and its creator can still edit it long after delivery', async () => {
    const { page, context } = await open(seed(ME, { todos: [BOTH] }));
    await page.click('[data-a="tview:both"]');
    assert.equal(await page.$('[data-a="tnudge:both"]'), null, 'no Ping on a Both to-do');
    assert.ok(await page.$('[data-a="etodo:both"]'), 'creator edits any time (created 16 days ago, past the edit window)');
    await context.close();
  });

  test('with a hold the ask waits: the Held row says Both', async () => {
    const { page, context } = await open(seed(ME, { hold: 60 }));
    await newTodoBoth(page);
    await page.waitForSelector('.hrow2');
    assert.equal(await page.$eval('.hrow2 .hm2', (e) => e.textContent), 'To Both');
    const s = await stored(page, ME, (x) => Object.keys(x.rows.items).length === 1);
    assert.deepEqual([Object.values(s.rows.items)[0].shared, Object.keys(s.rows.todos).length], [true, 0]); // no to-do until it is sent
    await context.close();
  });

  test('the three-way For control fits at 390px with a long partner name', async () => {
    const { page, context } = await open(seed(ME, { herName: LONG }));
    await page.click('[data-a="addpick"]');
    await page.click('.bs [data-a="newtodo:task"]');
    const fit = await page.$eval('[data-a="nfor:both"]', (b) => {
      const seg = b.parentElement, r = seg.getBoundingClientRect();
      return { overflow: seg.scrollWidth - seg.clientWidth, right: r.right, vw: innerWidth, cells: [...seg.children].map((c) => { const x = c.getBoundingClientRect(); return [x.left >= r.left - 0.5, x.right <= r.right + 0.5, c.textContent]; }) };
    });
    assert.ok(fit.overflow <= 0 && fit.right <= fit.vw, JSON.stringify(fit));
    assert.ok(fit.cells.every((c) => c[0] && c[1]), JSON.stringify(fit.cells));
    await shot(page, 'for-control-long-name');
    await context.close();
  });

  test('a Both reminder sends once in the shared tier and once in the private tier, and the library shows the partner tier', async () => {
    const { page, context } = await open(seed(ME));
    await page.click('[data-a="todoseg:rem"]');
    await page.click('[data-a="nudgenew"]');
    await page.fill('textarea[data-d="nbody"]', 'Water the plants');
    await page.click('[data-a="nudgefor:both"]');
    assert.equal(await page.$('[data-a="nudgesave"]'), null, 'Send stays the only button');
    await shot(page, 'reminder-both');
    await page.click('[data-a="nudgenewsend"]');
    await page.waitForSelector('[data-nid]');
    const sh = await stored(page, ME, (x) => Object.keys(x.rows.nudge_sends).length === 1);
    const sends = Object.values(sh.rows.nudge_sends);
    assert.deepEqual([sends[0].body, sends[0].recipient_id], ['Water the plants', HER]);
    assert.equal(Object.keys(sh.rows.nudges).length, 1);
    await page.waitForTimeout(400);
    const pv = await page.evaluate((w) => JSON.parse(localStorage.getItem('cycle:priv.' + w)), ME);
    assert.deepEqual([pv.nudges.length, pv.nudge_sends.length, pv.nudge_sends[0].recipient_id], [1, 1, ME]);
    assert.ok(await page.locator('[data-a="ntier:esme"].on').count(), 'library shows the partner tier');
    await context.close();
  });

  test('Both reminder after 8 pm reads Send tomorrow (the partner tier decides)', async () => {
    const { page, context } = await open(seed(ME), NIGHT);
    await page.click('[data-a="todoseg:rem"]');
    await page.click('[data-a="nudgenew"]');
    await page.click('[data-a="nudgefor:both"]');
    assert.match(await page.$eval('[data-a="nudgenewsend"]', (e) => e.textContent), /^Send tomorrow/);
    await context.close();
  });
});

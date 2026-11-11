// To-do Time (option D, set from the detail page): propose / agree / counter / clear / solo, the "?" on rows, and the
// local alert `time-<id>` (only when agreed and still ahead). Real app in headless WebKit against seeded localStorage;
// the backend is aborted (offline) so every write is read from the store's own persistence (rows + outbox), and the
// native bridge is a page-side stub that records notify.schedule / notify.cancel in window.__calls.
// Needs GL_WEBKIT_PW / GL_WEBKIT_EXEC (see cycle-todo-detail.test.mjs). TIME_SHOTS=<dir> also writes screenshots.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HAS_WK = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = HAS_WK ? await import(process.env.GL_WEBKIT_PW) : null;
const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const SHOTS = process.env.TIME_SHOTS;
if (SHOTS) fs.mkdirSync(SHOTS, { recursive: true });

const ME = 'u-me', HER = 'u-her';
const NOW = '2026-10-21T15:00:00Z'; // Wed 11:00 New York (EDT)
const THU7PM = '2026-10-22T23:00:00.000Z'; // Thu 7:00pm New York, what the "Tomorrow 7:00pm" chip writes
const COUPLE = { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60 };
const MEMBERS = [{ user_id: ME, name: 'Me', checkin_time: '21:00' }, { user_id: HER, name: 'Esme', checkin_time: '21:00' }];
const td = (id, o = {}) => ({ id, couple_id: 'c1', owner_id: ME, created_by: ME, item_id: null, fight_marker_id: null, title: id, description: null, type: 'task',
  due_date: null, target: null, period: null, points_earn: null, points_miss: null, needs_note: false, edited_at: null, tally: 0, done_at: null,
  shared: false, time_at: null, time_by: null, time_ok_at: null,
  created_at: '2026-10-05T12:00:00Z', updated_at: '2026-10-05T12:00:00Z', deleted_at: null, ...o });
const BOTH = (o = {}) => td('both', { title: 'Plan the trip', shared: true, ...o });

function seed(todos) {
  return {
    session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: ME, email: 'me@x.test' } },
    ['shared.' + ME]: { couple: COUPLE, members: MEMBERS,
      rows: { items: {}, todos: Object.fromEntries(todos.map((r) => [r.id, r])), todo_events: {}, checkins: {}, fight_markers: {}, rewards: {}, redemptions: {}, nudges: {}, nudge_sends: {}, nudge_replies: {}, nudge_awards: {} },
      cursors: {}, outbox: [] },
    ['priv.' + ME]: { fights: [], affirmations: [], prefs: {} },
  };
}

describe('to-do time (webkit)', { skip: !HAS_WK && 'needs GL_WEBKIT_PW and GL_WEBKIT_EXEC' }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  async function open(s, now = NOW) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(now));
    await context.addInitScript((sd) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
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
        else if (!['ready', 'notify.schedule', 'notify.cancel', 'app.openSettings'].includes(cmd)) throw new Error('unexpected bridge cmd ' + cmd);
        setTimeout(() => window.__cycleReply(id, r, null), 0);
      } } } };
    }, s);
    await context.route('**/cycle.css', (r) => r.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (r) => r.abort());
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.click('[data-a="tab:todo"]');
    await page.waitForSelector('[data-a="addpick"]');
    return { context, page };
  }
  // The row as persisted: poll until `ok` holds, then return it (the store writes after the tap, not during it).
  async function row(page, id, ok = () => true) {
    const key = 'cycle:shared.' + ME, fn = `(() => { const r = JSON.parse(localStorage.getItem('${key}')).rows.todos['${id}']; return (${ok.toString()})(r); })()`;
    await page.waitForFunction(fn);
    return page.evaluate(([k, i]) => JSON.parse(localStorage.getItem(k)).rows.todos[i], [key, id]);
  }
  const triple = (r) => [r.time_at, r.time_by, r.time_ok_at];
  const detail = async (page) => { await page.click('.td-row .tx p'); await page.waitForSelector('.tdd2'); };
  // Page screenshot clipped to the element's box (full width): element screenshots fail on the animating sheet and the re-rendering list.
  async function shot(page, name, sel) {
    if (!SHOTS) return;
    await page.waitForTimeout(400); // let the sheet slide-in / re-render settle before reading the box
    const b = await page.$eval(sel, (e) => { const r = e.getBoundingClientRect(); return { y: r.top, h: r.height }; });
    await page.screenshot({ path: path.join(SHOTS, name + '.png'), clip: { x: 0, y: Math.max(0, b.y), width: 390, height: Math.min(b.h, 844 - Math.max(0, b.y)) } });
  }
  const scheduled = (page) => page.evaluate(() => window.__calls.filter((c) => c.cmd === 'notify.schedule').map((c) => c.args.id));
  const cancelled = (page) => page.evaluate(() => window.__calls.filter((c) => c.cmd === 'notify.cancel').map((c) => c.args.id));
  const waitCall = (page, cmd, id) => page.waitForFunction(([c, i]) => window.__calls.some((x) => x.cmd === c && x.args.id === i), [cmd, id]);

  test('propose on a Both to-do: sheet says Propose, the write is mine and unagreed, the row shows "?", and nothing is scheduled', async () => {
    const { page, context } = await open(seed([BOTH()]));
    await detail(page);
    assert.equal(await page.$$eval('.tdd2 [data-a^="timeopen:"]', (e) => e.length), 1);
    assert.equal(await page.$eval('.tdd2 [data-a^="timeopen:"]', (e) => e.textContent), 'Schedule a time');
    await shot(page, '1-detail-set', '.tdd2');
    await page.click('.tdd2 [data-a^="timeopen:"]');
    await page.waitForSelector('[data-a^="timego:"]');
    assert.equal(await page.$eval('[data-a^="timego:"]', (e) => e.textContent), 'Propose');
    await shot(page, '2-time-sheet', '.bs');
    await page.click('.chip >> text=Tomorrow 7:00pm');
    await page.click('[data-a^="timego:"]');
    const r = await row(page, 'both', (x) => x.time_at);
    assert.deepEqual(triple(r), [THU7PM, ME, null]);
    assert.match(await page.$eval('.tdd2', (e) => e.textContent), /Waiting on Esme/);
    await shot(page, '3-proposer-waiting', '.tdd2');
    await page.click('.tabbar [data-a="tab:todo"]');
    assert.equal(await page.$eval('.td-row .tm', (e) => e.textContent), 'Thu 7:00pm?');
    await shot(page, '6-row-proposed', '.td-row');
    assert.deepEqual((await scheduled(page)).filter((i) => i.startsWith('time-')), [], 'a proposal must not alert');
    await context.close();
  });

  test('other person: Works makes it agreed (no "?") and schedules time-<id>', async () => {
    const { page, context } = await open(seed([BOTH({ time_at: THU7PM, time_by: HER })]));
    assert.equal(await page.$eval('.td-row .tm', (e) => e.textContent), 'Thu 7:00pm?');
    await detail(page);
    assert.deepEqual(await page.$$eval('.tdd2 .tmb > *', (e) => e.map((x) => x.textContent)), ['Works', 'Other']);
    assert.match(await page.$eval('.tdd2', (e) => e.textContent), /Esme proposed/);
    await shot(page, '4-other-works', '.tdd2');
    await page.click('.tdd2 [data-a^="timeworks:"]');
    const r = await row(page, 'both', (x) => x.time_ok_at);
    assert.equal(r.time_at, THU7PM); assert.equal(r.time_by, HER); assert.ok(r.time_ok_at);
    assert.deepEqual(await page.$$eval('.tdd2 .tmb > *', (e) => e.map((x) => x.textContent)), ['Change', 'Clear']);
    await shot(page, '5-agreed-detail', '.tdd2');
    await waitCall(page, 'notify.schedule', 'time-both');
    const call = await page.evaluate(() => window.__calls.find((c) => c.cmd === 'notify.schedule' && c.args.id === 'time-both').args);
    assert.equal(call.title, 'To do'); assert.equal(call.body, 'Plan the trip'); assert.equal(call.route, 'todo/both');
    assert.equal(new Date(call.at).toISOString(), THU7PM);
    await page.click('.tabbar [data-a="tab:todo"]');
    assert.equal(await page.$eval('.td-row .tm', (e) => e.textContent), 'Thu 7:00pm');
    await shot(page, '7-row-agreed', '.td-row');
    await context.close();
  });

  test('other person: Other opens the same sheet and saving makes them the proposer of a new time', async () => {
    const { page, context } = await open(seed([BOTH({ time_at: THU7PM, time_by: HER })]));
    await detail(page);
    await page.click('.tdd2 [data-a^="timeopen:"]');
    await page.click('.chip >> text=Sat 10:00am');
    await page.click('[data-a^="timego:"]');
    const r = await row(page, 'both', (x) => x.time_by === 'u-me');
    assert.deepEqual(triple(r), ['2026-10-24T14:00:00.000Z', ME, null]);
    assert.match(await page.$eval('.tdd2', (e) => e.textContent), /Waiting on Esme/);
    await context.close();
  });

  test('Clear on an agreed time nulls all three columns and cancels the alert', async () => {
    const { page, context } = await open(seed([BOTH({ time_at: THU7PM, time_by: HER, time_ok_at: '2026-10-21T14:00:00Z' })]));
    await waitCall(page, 'notify.schedule', 'time-both');
    await detail(page);
    await page.click('.tdd2 [data-a^="timeclear:"]');
    const r = await row(page, 'both', (x) => !x.time_at);
    assert.deepEqual(triple(r), [null, null, null]);
    await waitCall(page, 'notify.cancel', 'time-both');
    assert.equal(await page.$$eval('.tdd2 [data-a^="timeopen:"]', (e) => e.length), 1);
    assert.equal(await page.$eval('.tdd2 [data-a^="timeopen:"]', (e) => e.textContent), 'Schedule a time');
    await context.close();
  });

  test('solo to-do: Set agrees at once (time_ok_at written) and schedules the alert', async () => {
    const { page, context } = await open(seed([td('solo', { title: 'Call the bank' })]));
    await detail(page);
    await page.click('.tdd2 [data-a^="timeopen:"]');
    assert.equal(await page.$eval('[data-a^="timego:"]', (e) => e.textContent), 'Set');
    await page.click('.chip >> text=Tomorrow 7:00pm');
    await page.click('[data-a^="timego:"]');
    const r = await row(page, 'solo', (x) => x.time_at);
    assert.deepEqual([r.time_at, r.time_by], [THU7PM, ME]);
    assert.ok(r.time_ok_at, 'solo is agreed at once');
    await waitCall(page, 'notify.schedule', 'time-solo');
    await page.click('.tabbar [data-a="tab:todo"]');
    assert.equal(await page.$eval('.td-row .tm', (e) => e.textContent), 'Thu 7:00pm');
    await context.close();
  });

  test('time- alerts exist only for agreed, still-ahead, open to-dos', async () => {
    const AGREED = '2026-10-21T14:00:00Z';
    const { page, context } = await open(seed([
      td('ok', { time_at: THU7PM, time_by: ME, time_ok_at: AGREED }),
      td('proposed', { time_at: THU7PM, time_by: ME }),
      td('past', { time_at: '2026-10-20T23:00:00.000Z', time_by: ME, time_ok_at: AGREED }),
      td('done', { time_at: THU7PM, time_by: ME, time_ok_at: AGREED, done_at: '2026-10-21T14:30:00Z' }),
      td('gone', { time_at: THU7PM, time_by: ME, time_ok_at: AGREED, deleted_at: '2026-10-21T14:30:00Z' }),
    ]));
    await waitCall(page, 'notify.schedule', 'time-ok');
    assert.deepEqual((await scheduled(page)).filter((i) => i.startsWith('time-')), ['time-ok']);
    await context.close();
  });
});

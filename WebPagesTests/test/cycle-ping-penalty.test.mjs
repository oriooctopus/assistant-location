// Ping with a penalty: the Ping sheet (None / stepper / dollars / time), the rows on the to-do page, the Home kicker, the
// owner's open being recorded, and applied penalties in the points ledger. Real app in headless WebKit against seeded
// localStorage; the backend is aborted (offline) so every write is observed in the store's own persistence (outbox + rows).
// Needs GL_WEBKIT_PW / GL_WEBKIT_EXEC (see cycle-todo-detail.test.mjs). PING_SHOTS=<dir> also writes screenshots.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HAS_WK = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = HAS_WK ? await import(process.env.GL_WEBKIT_PW) : null;
const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const SHOTS = process.env.PING_SHOTS;
if (SHOTS) fs.mkdirSync(SHOTS, { recursive: true });

const ME = 'u-me', HER = 'u-her';
const NOW = '2026-10-21T15:00:00Z'; // Wed 11:00 New York (EDT)
const COUPLE = { id: 'c1', tz: 'America/New_York', created_at: '2026-10-01T00:00:00Z', hold_ask_min: 60 };
const MEMBERS = [{ user_id: ME, name: 'Me', checkin_time: '21:00' }, { user_id: HER, name: 'Esme', checkin_time: '21:00' }];
const td = (id, o = {}) => ({ id, couple_id: 'c1', owner_id: ME, created_by: ME, item_id: null, fight_marker_id: null, title: id, description: null, type: 'task',
  due_date: null, target: null, period: null, points_earn: null, points_miss: null, needs_note: false, edited_at: null, tally: 0, done_at: null,
  created_at: '2026-10-05T12:00:00Z', updated_at: '2026-10-05T12:00:00Z', deleted_at: null, ...o });
// Her to-do (I can ping it), due Sun 25 Oct so the Not done default is Sun 9:00pm. My to-do from her, which she pinged with both penalties.
const HERS = td('hers', { title: 'Renew insurance', owner_id: HER, created_by: ME, due_date: '2026-10-25' });
const MINE = td('mine', { title: 'Take the bins out', owner_id: ME, created_by: HER });
const NUDGE = { id: 'n1', couple_id: 'c1', todo_id: 'mine', sender_id: HER, created_at: '2026-10-21T14:30:00Z', updated_at: '2026-10-21T14:30:00Z', deleted_at: null,
  open_by: '2026-10-21T17:00:00Z', open_pts: 5, done_by: '2026-10-26T01:00:00Z', done_pts: 10 }; // 1:00pm today, Sun 9:00pm

function seed({ todos = [], extra = {} } = {}) {
  const byId = (a) => Object.fromEntries(a.map((r) => [r.id, r]));
  return {
    session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: ME, email: 'me@x.test' } },
    ['shared.' + ME]: { couple: COUPLE, members: MEMBERS,
      rows: { items: {}, todos: byId(todos), todo_events: {}, checkins: {}, fight_markers: {}, rewards: {}, redemptions: {}, nudges: {}, nudge_sends: {}, nudge_replies: {}, nudge_awards: {},
        ...Object.fromEntries(Object.entries(extra).map(([k, v]) => [k, byId(v)])) },
      cursors: {}, outbox: [] },
    ['priv.' + ME]: { fights: [], affirmations: [], prefs: {} },
  };
}

describe('ping with a penalty (webkit)', { skip: !HAS_WK && 'needs GL_WEBKIT_PW and GL_WEBKIT_EXEC' }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  async function open(s, now = NOW) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(now));
    await context.addInitScript((sd) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, s);
    await context.route('**/cycle.css', (r) => r.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (r) => r.abort()); // offline: writes stay in the outbox
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-a="tab:todo"]');
    return { context, page };
  }
  async function stored(page, ok = () => true) {
    const key = 'cycle:shared.' + ME, fn = `(() => { const s = JSON.parse(localStorage.getItem('${key}')); return (${ok.toString()})(s); })()`;
    await page.waitForFunction(fn);
    return page.evaluate((k) => JSON.parse(localStorage.getItem(k)), key);
  }
  const shot = (page, name) => SHOTS && page.screenshot({ path: path.join(SHOTS, name + '.png') });
  const openDetail = async (page, id) => { await page.click('[data-a="tab:todo"]'); await page.click(`[data-todo="${id}"] .tx p`); await page.waitForSelector('.tdd2'); };
  const rowsText = (page) => page.$$eval('.tdd2 .frow.top', (es) => es.map((e) => e.textContent.replace(/\s+/g, ' ').trim()));

  test('Ping with both penalties None writes the plain nudge, as before', async () => {
    const { page, context } = await open(seed({ todos: [HERS] }));
    await openDetail(page, 'hers');
    await page.click('[data-a="tnudge:hers"]');
    assert.equal(await page.$eval('.bs.ts h3', (e) => e.textContent), 'Ping');
    assert.deepEqual(await page.$$eval('.bs.ts .frow .chip', (es) => es.map((e) => e.textContent)), ['None', 'None']);
    await page.click('[data-a="tnudgego"]');
    const s = await stored(page, (x) => Object.keys(x.rows.todo_nudges || {}).length === 1);
    const n = Object.values(s.rows.todo_nudges)[0];
    assert.deepEqual([n.todo_id, n.sender_id, n.open_by, n.done_by], ['hers', ME, undefined, undefined]);
    assert.equal(await page.$('.bs.ts'), null, 'sheet closed');
    assert.equal(await page.$$eval('.tdd2 .frow.top', (e) => e.length), 0, 'no penalty rows');
    await context.close();
  });

  test('both penalties: defaults, stepper, typed amount, dollars, and the rows on the sender page', async () => {
    const { page, context } = await open(seed({ todos: [HERS] }));
    await openDetail(page, 'hers');
    await page.click('[data-a="tnudge:hers"]');
    await page.click('[data-a="pon:pOpen"]');
    await page.click('[data-a="pon:pDone"]');
    const sheet = () => page.$$eval('.bs.ts .frow', (es) => es.map((e) => [e.querySelector('input.stpn').value, e.querySelector('.dollar').textContent, e.querySelector('.pv').textContent]));
    // 2 hours from 11:00 rounded up = 1:00pm; due Sun 25 Oct -> 9:00pm that day.
    assert.deepEqual(await sheet(), [['−5', '$1.50', '1:00pm'], ['−10', '$3', 'Sun 9:00pm']]);
    await shot(page, 'sheet-both');
    await page.click('[data-a="pstp:pOpen:1"]');
    assert.deepEqual((await sheet())[0].slice(0, 2), ['−10', '$3']);
    await page.click('[data-a="pstp:pOpen:-1"]'); await page.click('[data-a="pstp:pOpen:-1"]');
    assert.equal(await page.$$eval('.bs.ts .frow .chip', (es) => es.map((e) => e.textContent).join()), 'None', 'stepping to 0 returns the row to None');
    await page.click('[data-a="pon:pOpen"]');
    await page.fill('input[data-s="pOpen"]', '20');
    assert.deepEqual((await sheet())[0].slice(0, 2), ['−20', '$6.01'], 'typed amount updates the dollars live');
    await page.fill('input[data-s="pOpen"]', '5');
    await page.click('[data-a="tnudgego"]');
    const s = await stored(page, (x) => Object.keys(x.rows.todo_nudges || {}).length === 1);
    const n = Object.values(s.rows.todo_nudges)[0];
    assert.deepEqual([n.open_by, n.open_pts, n.done_by, n.done_pts], ['2026-10-21T17:00:00.000Z', 5, '2026-10-26T01:00:00.000Z', 10]);
    assert.ok(s.outbox.some((o) => o.op === 'insert' && o.table === 'todo_nudges' && o.row.open_pts === 5), 'queued with its penalties');
    assert.deepEqual(await rowsText(page), ['Not opened\u22125 \u00b7 $1.50By 1:00pm \u00b7 2h', 'Not done\u221210 \u00b7 $3By Sun 9:00pm \u00b7 106h']);
    assert.equal(await page.locator('.tdd2 .ghost', { hasText: /^Pinged$/ }).count(), 1);
    await shot(page, 'sender-pending');
    await context.close();
  });

  test('a time in the past is refused visibly and writes nothing', async () => {
    const { page, context } = await open(seed({ todos: [HERS] }));
    await openDetail(page, 'hers');
    await page.click('[data-a="tnudge:hers"]');
    await page.click('[data-a="pon:pOpen"]');
    await page.fill('input[data-d="pOpenAt"]', '2026-10-21T09:00');
    await page.click('[data-a="tnudgego"]');
    assert.match(await page.textContent('body'), /Pick a time in the future/);
    assert.deepEqual((await stored(page)).rows.todo_nudges, {});
    await context.close();
  });

  test('recipient: Home kicker shows pending penalties; opening the to-do records the open once, then rows read the same', async () => {
    const { page, context } = await open(seed({ todos: [MINE], extra: { todo_nudges: [NUDGE] } }));
    assert.equal(await page.$eval('.nc[data-todo="mine"] .s', (e) => e.textContent), '−5 by 1pm · −10 by Sun 9pm');
    assert.ok(await page.$eval('.nc[data-todo="mine"] .s', (e) => e.classList.contains('pen')));
    await shot(page, 'recipient-home');
    await page.click('.nc[data-todo="mine"]');
    await page.waitForSelector('.tdd2');
    const s = await stored(page, (x) => Object.keys(x.rows.todo_nudge_opens || {}).length === 1);
    const o = Object.values(s.rows.todo_nudge_opens)[0];
    assert.deepEqual([o.nudge_id, o.todo_id, o.opener_id, o.opened_at], ['n1', 'mine', ME, NOW.replace('Z', '.000Z')]);
    assert.ok(s.outbox.some((x) => x.op === 'insert' && x.table === 'todo_nudge_opens' && x.id === o.id), 'open queued for sync');
    assert.deepEqual(await rowsText(page), ['Not openedAvoidedOpened 11:00am', 'Not done\u221210 \u00b7 $3By Sun 9:00pm \u00b7 106h']);
    await page.click('[data-a="back"]');
    await openDetail(page, 'mine');
    assert.equal(Object.keys((await stored(page)).rows.todo_nudge_opens).length, 1, 'a second visit writes no second open');
    await context.close();
  });

  test('the owner opening AFTER the open deadline records nothing', async () => {
    const { page, context } = await open(seed({ todos: [MINE], extra: { todo_nudges: [NUDGE] } }), '2026-10-21T18:00:00Z');
    await openDetail(page, 'mine');
    await page.waitForTimeout(500);
    assert.deepEqual((await stored(page)).rows.todo_nudge_opens, {});
    await context.close();
  });

  test('deadlines passed: rows read applied, and the points list carries both lose lines', async () => {
    const { page, context } = await open(seed({ todos: [MINE], extra: { todo_nudges: [NUDGE] } }), '2026-10-26T02:00:00Z'); // Sun 10:00pm
    await openDetail(page, 'mine');
    assert.deepEqual(await rowsText(page), ['Not opened\u22125 appliedNot opened by Wed 1:00pm', 'Not done\u221210 appliedNot done by 9:00pm']);
    await shot(page, 'applied');
    await page.click('[data-a="back"]');
    await page.click('[data-a="tab:progress"]');
    await page.click('[data-a="go:points"]');
    const lines = await page.$$eval('.ln', (es) => es.map((e) => e.textContent.replace(/\s+/g, ' ').trim()).filter((t) => /not (opened|done)/.test(t)));
    assert.deepEqual(lines.sort(), ['−10Take the bins out · not done', '−5Take the bins out · not opened']);
    await context.close();
  });
});

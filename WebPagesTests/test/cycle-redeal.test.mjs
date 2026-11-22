// New deal: a missed to-do's creator re-dates it with a higher miss penalty from its page. Real app in headless WebKit against seeded localStorage; the backend is aborted (offline) so
// every write is observed in the store's own persistence (outbox + rows). Needs GL_WEBKIT_PW / GL_WEBKIT_EXEC (see
// cycle-fight.test.mjs). DETAIL_SHOTS=<dir> also writes screenshots.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HAS_WK = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = HAS_WK ? await import(process.env.GL_WEBKIT_PW) : null;
const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const SHOTS = process.env.DETAIL_SHOTS;
if (SHOTS) fs.mkdirSync(SHOTS, { recursive: true });

const ME = 'u-me', HER = 'u-her';
const NOW = '2026-10-21T15:00:00Z'; // Wed 11:00 New York
const COUPLE = { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60 };
const MEMBERS = [{ user_id: ME, name: 'Me', checkin_time: '21:00' }, { user_id: HER, name: 'Esme', checkin_time: '21:00' }];
const td = (id, o = {}) => ({ id, couple_id: 'c1', owner_id: ME, created_by: ME, item_id: null, fight_marker_id: null, title: id, description: null, type: 'task',
  due_date: null, target: null, period: null, points_earn: null, points_miss: null, needs_note: false, edited_at: null, tally: 0, done_at: null,
  created_at: '2026-10-05T12:00:00Z', updated_at: '2026-10-05T12:00:00Z', deleted_at: null, ...o });

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

describe('new deal (webkit)', { skip: !HAS_WK && 'needs GL_WEBKIT_PW and GL_WEBKIT_EXEC' }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  async function open(s, id) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(NOW));
    await context.addInitScript((sd) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, s);
    await context.route('**/cycle.css', (r) => r.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (r) => r.abort());
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.click('[data-a="tab:todo"]');
    await page.click('[data-todo="' + id + '"] .tx p');
    await page.waitForSelector('.tdd2');
    return { context, page };
  }

  test('missed creator to-do: New deal sheet saves due_date, points_miss and prior_misses', async () => {
    const { page, context } = await open(seed({ todos: [td('m', { title: 'Missed', owner_id: HER, due_date: '2026-10-18', points_earn: 4, points_miss: 5 })] }), 'm');
    await page.click('[data-a="redeal:m"]');
    await page.waitForSelector('.bs');
    assert.equal(await page.$eval('.bs input.stpn', (e) => e.value), '10', 'defaults to miss x2');
    assert.equal(await page.$eval('.bs [data-d="rdD"]', (e) => e.value), '2026-10-22', 'defaults to tomorrow');
    await page.click('.bs [data-a="redealgo:m"]');
    await page.waitForFunction(() => !document.querySelector('.bs'));
    await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')).rows.todos.m.due_date === '2026-10-22');
    const st = await page.evaluate(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')));
    const row = st.rows.todos.m;
    assert.equal(row.due_date, '2026-10-22');
    assert.equal(row.points_miss, 10);
    assert.equal(row.points_earn, 4);
    assert.equal(row.prior_misses.length, 1);
    assert.deepEqual({ d: row.prior_misses[0].due_date, p: row.prior_misses[0].points }, { d: '2026-10-18', p: 5 });
    assert.ok(row.prior_misses[0].at);
    assert.match(await page.$eval('.tdd2', (e) => e.textContent), /Missed Sun 18 Oct\s*−5/);
    assert.equal(await page.$('[data-a="redeal:m"]'), null, 'no longer missed');
    await context.close();
  });

  test('a miss that is not higher is refused and writes nothing', async () => {
    const { page, context } = await open(seed({ todos: [td('m', { title: 'Missed', due_date: '2026-10-18', points_miss: 5 })] }), 'm');
    await page.click('[data-a="redeal:m"]');
    await page.fill('.bs input.stpn', '5');
    await page.click('.bs [data-a="redealgo:m"]');
    await page.waitForSelector('.bs');
    const st = await page.evaluate(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')));
    assert.equal(st.rows.todos.m.due_date, '2026-10-18');
    assert.equal(st.rows.todos.m.prior_misses, undefined);
    await context.close();
  });

  test('no New deal for a not-yet-due to-do or one the partner created', async () => {
    const { page, context } = await open(seed({ todos: [td('soon', { title: 'Soon', due_date: '2026-10-25', points_miss: 5 }), td('hers', { title: 'Hers', owner_id: ME, created_by: HER, due_date: '2026-10-18', points_miss: 5 })] }), 'soon');
    assert.equal(await page.$('[data-a^="redeal:"]'), null);
    await context.close();
    const o = await open(seed({ todos: [td('hers', { title: 'Hers', owner_id: ME, created_by: HER, due_date: '2026-10-18', points_miss: 5 })] }), 'hers');
    assert.equal(await o.page.$('[data-a^="redeal:"]'), null);
    await o.context.close();
  });
});

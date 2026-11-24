// Creator tick: the creator of a to-do for the partner marks it done (and undoes it) from its page. Real app in headless WebKit against seeded localStorage; the backend is aborted (offline) so
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

describe('creator marks partner to-do done (webkit)', { skip: !HAS_WK && 'needs GL_WEBKIT_PW and GL_WEBKIT_EXEC' }, () => {
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

  test('creator sees Mark done on the partner\'s open task; tapping sets done_at and shows Undo done', async () => {
    const { page, context } = await open(seed({ todos: [td('t', { title: 'Sign it', owner_id: HER, created_by: ME })] }), 't');
    await page.click('[data-a="done:t"]');
    await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')).rows.todos.t.done_at);
    const st = await page.evaluate(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')));
    assert.ok(st.rows.todos.t.done_at);
    assert.equal(Object.values(st.rows.todos.t && st.rows.todo_events).filter((e) => e.kind === 'done' && e.user_id === ME).length, 1);
    await page.waitForSelector('[data-a="tundo:t"]');
    assert.equal(await page.$('[data-a="done:t"]'), null);
    await page.click('[data-a="tundo:t"]');
    await page.waitForFunction(() => !JSON.parse(localStorage.getItem('cycle:shared.u-me')).rows.todos.t.done_at);
    await page.waitForSelector('[data-a="done:t"]');
    await context.close();
  });

  test('no Mark done on a to-do the partner created for me, or on a habit I made for her', async () => {
    const a = await open(seed({ todos: [td('hers', { owner_id: ME, created_by: HER })] }), 'hers');
    assert.equal(await a.page.$('[data-a="done:hers"]'), null);
    await a.context.close();
    const b = await open(seed({ todos: [td('h', { owner_id: HER, created_by: ME, type: 'habit', target: 3, period: 'week' })] }), 'h');
    assert.equal(await b.page.$('[data-a="done:h"]'), null);
    await b.context.close();
  });
});

// Today's first-open points banner: what it shows, and that dismissing it holds until the next local day.
// WebKit only (set GL_WEBKIT_PW/GL_WEBKIT_EXEC); skipped without it. The clock is faked so day rollover is real.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const haveWebkit = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = haveWebkit ? await import(process.env.GL_WEBKIT_PW) : null;

const UID = 'u-me', PID = 'u-her';
const FRI = '2026-10-30T14:00:00Z', SAT = '2026-10-31T14:00:00Z', SUN = '2026-11-01T14:00:00Z';
const seed = (rows, created = '2026-10-29T12:00:00Z') => ({
  session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } },
  ['shared.' + UID]: {
    couple: { id: 'c1', tz: 'America/New_York', created_at: created, hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [{ user_id: UID, name: 'Me', checkin_time: '21:00', hits_self: false }, { user_id: PID, name: 'Her', checkin_time: '21:00', hits_self: true }],
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, fight_markers: {}, fight_notes: {}, rewards: {}, redemptions: {}, acks: {}, ...rows },
    cursors: {}, outbox: [],
  },
  ['priv.' + UID]: { fights: [], affirmations: [], prefs: {} },
});
const task = (id, title, doneAt) => ({ id, couple_id: 'c1', owner_id: PID, created_by: PID, type: 'task', title, done_at: doneAt, created_at: '2026-10-29T12:00:00Z', updated_at: doneAt, deleted_at: null });

describe('webkit', { skip: !haveWebkit }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  async function open(s, at) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.addInitScript(([sd, t]) => {
      const real = Date.now, off = new Date(t).getTime() - real();
      Date.now = () => real() + off;
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, [s, at]);
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (route) => route.abort());
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.rows .row');
    return { context, page };
  }
  const rows = { todos: { a: task('a', 'Book vet', '2026-10-29T16:00:00Z') } };

  test('first open shows yesterday: label, net and the partner\'s line', async () => {
    const { context, page } = await open(seed(rows), FRI);
    assert.equal(await page.textContent('.dg .lab'), 'Yesterday');
    // +3 on-time to do, +3 calm day (couple created yesterday).
    assert.equal(await page.textContent('.dgn'), '+6');
    assert.ok((await page.$$eval('.dgl', (e) => e.map((x) => x.textContent))).includes('+3To do on time · Book vet'));
    assert.equal(await page.$('.dgm'), null, 'no "+0 more" when every line fits');
    await context.close();
  });

  test('X keeps it gone through a relaunch that day, and it returns the next day', async () => {
    const { context, page } = await open(seed(rows), FRI);
    await page.tap('.dgx');
    assert.equal(await page.$('.dg'), null);
    assert.equal(await page.$('.pts .ledger'), null, 'X must not open Points');
    await page.waitForTimeout(500); // the store persists on a debounce
    await page.reload(); await page.waitForSelector('.rows .row');
    assert.equal(await page.$('.dg'), null, 'dismissal survives a relaunch');
    const saved = await page.evaluate(() => localStorage.getItem('cycle:priv.u-me'));
    await context.close();

    const s = seed(rows); s['priv.' + UID] = JSON.parse(saved);
    const next = await open(s, SAT);
    assert.equal(await next.page.textContent('.dg .lab'), 'Yesterday');
    await next.context.close();
    // Skipping a day widens the range back to the dismissed day rather than dropping what was missed.
    const later = await open(s, SUN);
    assert.equal(await later.page.textContent('.dg .lab'), 'Since Fri');
    await later.context.close();
  });

  test('tapping the card opens Points and dismisses it', async () => {
    const { context, page } = await open(seed(rows), FRI);
    await page.tap('.dg .dgl');
    await page.waitForSelector('#balance');
    await page.tap('.tab[data-a="tab:home"]');
    await page.waitForSelector('.rows .row');
    assert.equal(await page.$('.dg'), null);
    await context.close();
  });

  test('no card when nothing moved, and only three lines plus a count', async () => {
    const empty = await open(seed({}, FRI), FRI); // couple created today: no lines before today
    assert.equal(await empty.page.$('.dg'), null);
    await empty.context.close();
    const many = { todos: Object.fromEntries(['a', 'b', 'c', 'd'].map((id) => [id, task(id, 'T ' + id, '2026-10-29T16:00:00Z')])) };
    const { context, page } = await open(seed(many), FRI);
    assert.equal((await page.$$('.dgl')).length, 3);
    assert.equal(await page.textContent('.dgm'), '+2 more');
    await context.close();
  });
});

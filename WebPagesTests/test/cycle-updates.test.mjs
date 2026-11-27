// What's new: the pure count rule (cycle-core) and the Settings row -> page -> back round trip in headless WebKit against
// seeded localStorage (needs GL_WEBKIT_PW / GL_WEBKIT_EXEC, see cycle-todo-detail.test.mjs; the WebKit part skips without them).
// The entries file is replaced per test through a route, so the tests do not depend on the real cycle-updates.js wording.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import C from './cycle-load.mjs';

// Top-level await first: tests registered before it finish the file's run before the WebKit suite below is registered.
const HAS_WK = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = HAS_WK ? await import(process.env.GL_WEBKIT_PW) : null;

const H24 = 24 * 3600 * 1000;
const e = (at) => ({ at, text: at });

test('updatesCount: counts entries newer than the last open; 0 when none are', () => {
  const entries = [e('2026-11-09T12:00:00Z'), e('2026-11-05T12:00:00Z'), e('2026-11-01T12:00:00Z')];
  const t = (iso) => Date.parse(iso);
  assert.equal(C.updatesCount({ entries, seen: 0 }), 3, 'never opened: all of them');
  assert.equal(C.updatesCount({ entries, seen: t('2026-11-03T00:00:00Z') }), 2, 'only those after the last open');
  assert.equal(C.updatesCount({ entries, seen: t('2026-11-09T12:00:00Z') }), 0, 'nothing newer');
});

test('homeList: never carries a What’s new card', () => {
  const todos = [{ id: 'late', title: 'late', owner_id: 'u-me', due_date: '2026-10-18', created_at: '2026-10-01T09:00:00Z' }];
  const base = { me: 'u-me', now: Date.parse('2026-10-20T12:00:00Z'), today: '2026-10-20', todos, cards: [{ type: 'nudge', send: { id: 's1' } }], week: null };
  assert.deepEqual(C.homeList(base).map((x) => (x.kind === 'todo' ? x.todo.id : x.card.type)), ['late', 'nudge']);
});

const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web');
const URL_ = 'file://' + path.join(WEB, 'index.html');
const CSS = fs.readFileSync(path.join(WEB, 'cycle.css'), 'utf8') + '\n#fx{display:none}';

const ME = 'u-me', HER = 'u-her';
const NOW = '2026-11-12T15:00:00Z';
const COUPLE = { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60 };
const MEMBERS = [{ user_id: ME, name: 'Me', checkin_time: '21:00' }, { user_id: HER, name: 'Esme', checkin_time: '21:00' }];
const BINS = { id: 'bins', couple_id: 'c1', owner_id: ME, created_by: HER, item_id: null, fight_marker_id: null, title: 'Take the bins out', description: null, type: 'task',
  due_date: null, target: null, period: null, points_earn: null, points_miss: null, needs_note: false, edited_at: null, tally: 0, done_at: null,
  created_at: '2026-11-05T12:00:00Z', updated_at: '2026-11-05T12:00:00Z', deleted_at: null };

function seed(updatesSeen) {
  return {
    session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: ME, email: 'me@x.test' } },
    ['shared.' + ME]: { couple: COUPLE, members: MEMBERS,
      rows: { items: {}, todos: { bins: BINS }, todo_events: {}, checkins: {}, fight_markers: {}, rewards: {}, redemptions: {}, nudges: {}, nudge_sends: {}, nudge_replies: {}, nudge_awards: {} },
      cursors: {}, outbox: [] },
    ['priv.' + ME]: { fights: [], affirmations: [], prefs: updatesSeen == null ? {} : { updatesSeen } },
  };
}

describe('What’s new page (webkit)', { skip: !HAS_WK && 'needs GL_WEBKIT_PW and GL_WEBKIT_EXEC' }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  async function open(entries, updatesSeen) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(NOW));
    await context.addInitScript((sd) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, seed(updatesSeen));
    await context.route('**/cycle.css', (r) => r.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('**/cycle-updates.js', (r) => r.fulfill({ contentType: 'text/javascript', body: 'window.CYCLE_UPDATES = ' + JSON.stringify(entries) + ';' }));
    await context.route('https://x.test/**', (r) => r.abort());
    const page = await context.newPage();
    page.on('pageerror', (err) => { throw err; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.nd');
    return { context, page };
  }
  const texts = (page, sel) => page.$$eval(sel, (els) => els.map((x) => x.textContent));
  const lines = (page) => texts(page, '.ue .ub > p:first-child');
  // The list's children as a sequence: ud = date heading, ue = entry, sn = Seen divider.
  const order = (page) => page.$$eval('.ulist > *', (els) => els.map((x) => (x.classList.contains('ud') ? 'ud' : x.classList.contains('sn') ? 'sn' : 'ue')));

  // More -> Settings -> What's new.
  async function toUpdates(page) {
    await page.click('[data-a="go:more"]');
    await page.click('.srow[data-a="go:settings"]');
    await page.click('.srow[data-a="go:updates"]');
    await page.waitForSelector('.ue');
  }

  test('not on Home, To-dos or More; Settings row shows the new count; opening lists entries by day with the Seen divider; back returns to Settings with no count; reopening has no divider', async () => {
    const entries = [e('2026-11-09T12:00:00Z'), e('2026-11-05T12:00:00Z'), e('2026-11-01T12:00:00Z')].map((x) => ({ ...x, text: 'Entry ' + x.at.slice(0, 10) }));
    const { page, context } = await open(entries, Date.parse('2026-11-03T15:00:00Z'));
    assert.equal(await page.locator('[data-a="go:updates"]').count(), 0, 'Home');
    assert.equal(await page.locator('.nd .nc').first().locator('.x').textContent(), 'Take the bins out');
    await page.click('.tab[data-a="tab:todo"]');
    await page.waitForSelector('.td');
    assert.equal(await page.locator('[data-a="go:updates"]').count(), 0, 'To-dos');
    assert.equal(await page.locator('[data-a="doneopen"]').count(), 0, 'no Done section from What’s new');
    await page.click('.tab[data-a="tab:home"]');
    await page.click('[data-a="go:more"]');
    assert.equal(await page.locator('[data-a="go:updates"]').count(), 0, 'More');
    await page.click('.srow[data-a="go:settings"]');
    const row = page.locator('.srow[data-a="go:updates"]');
    assert.equal(await row.locator('span').first().textContent(), 'What’s new');
    assert.equal(await row.locator('.val').textContent(), '2');
    await row.click();
    await page.waitForSelector('.ue');
    assert.deepEqual(await lines(page), ['Entry 2026-11-09', 'Entry 2026-11-05', 'Entry 2026-11-01']);
    assert.deepEqual(await texts(page, '.ud'), ['9 Nov', '5 Nov', '1 Nov']);
    assert.deepEqual(await texts(page, '.lab.sn'), ['Seen 3 Nov']);
    assert.deepEqual(await order(page), ['ud', 'ue', 'ud', 'ue', 'sn', 'ud', 'ue']);
    const seen = await page.evaluate((k) => JSON.parse(localStorage.getItem(k)).prefs.updatesSeen, 'cycle:priv.' + ME);
    assert.equal(seen, Date.parse(NOW));
    await page.click('[data-a="back"]');
    await page.waitForSelector('.srow[data-a="go:updates"]');
    assert.equal(await page.locator('h2').first().textContent(), 'Settings');
    assert.equal(await row.locator('.val').count(), 0, 'count cleared');
    await row.click();
    await page.waitForSelector('.ue');
    assert.equal(await page.locator('.ue').count(), 3);
    assert.equal(await page.locator('.lab.sn').count(), 0);
    await context.close();
  });

  test('entries of one day share a single date heading, and the Seen divider can fall inside that day without repeating it', async () => {
    const entries = [e('2026-11-09T18:00:00Z'), e('2026-11-09T14:00:00Z'), e('2026-11-09T12:00:00Z'), e('2026-11-06T12:00:00Z')];
    const { page, context } = await open(entries, Date.parse('2026-11-09T13:00:00Z'));
    await toUpdates(page);
    assert.deepEqual(await texts(page, '.ud'), ['9 Nov', '6 Nov']);
    assert.deepEqual(await order(page), ['ud', 'ue', 'ue', 'sn', 'ue', 'ud', 'ue']);
    assert.deepEqual(await texts(page, '.lab.sn'), ['Seen 9 Nov']);
    await context.close();
  });

  test('first open (never seen) has no divider', async () => {
    const entries = [e('2026-11-09T12:00:00Z'), e('2026-11-05T12:00:00Z')];
    const { page, context } = await open(entries, null);
    await toUpdates(page);
    assert.equal(await page.locator('.lab.sn').count(), 0);
    await context.close();
  });

  test('tapping an entry with more opens it in place, one at a time; an entry without more has no caret and is not tappable', async () => {
    const entries = [{ ...e('2026-11-09T18:00:00Z'), text: 'A', more: 'More about A' }, { ...e('2026-11-09T14:00:00Z'), text: 'B', more: 'More about B' }, { ...e('2026-11-09T12:00:00Z'), text: 'C' }];
    const { page, context } = await open(entries, null);
    await toUpdates(page);
    assert.equal(await page.locator('.um').count(), 0, 'collapsed by default');
    assert.equal(await page.locator('.ue .ca').count(), 2);
    const c = page.locator('.ue').nth(2);
    assert.equal(await c.getAttribute('data-a'), null);
    assert.equal(await c.locator('.ca').count(), 0);
    await page.locator('.ue').nth(0).click();
    assert.deepEqual(await texts(page, '.um'), ['More about A']);
    await page.locator('.ue').nth(1).click();
    assert.deepEqual(await texts(page, '.um'), ['More about B'], 'opening B closes A');
    await page.locator('.ue').nth(1).click();
    assert.equal(await page.locator('.um').count(), 0, 'tapping again closes');
    await c.click();
    assert.equal(await page.locator('.um').count(), 0, 'the entry without more does nothing');
    await context.close();
  });

  test('infinite scroll: 30 entries first, 30 more at the sentinel, until all 65 show; a day split by a chunk has one heading; the open entry stays open', async () => {
    // Hourly entries: the 30/31 boundary falls inside one local day (New York, UTC-5), so a naive per-chunk heading would repeat it.
    const entries = Array.from({ length: 65 }, (_, i) => ({ at: new Date(Date.parse('2026-11-10T00:00:00Z') - i * 3600000).toISOString(), text: 'Entry ' + i, ...(i === 0 ? { more: 'Open me' } : {}) }));
    const days = (n) => new Set(entries.slice(0, n).map((x) => new Date(Date.parse(x.at) - 5 * 3600000).toISOString().slice(0, 10))).size;
    const { page, context } = await open(entries, null);
    await toUpdates(page);
    assert.equal(await page.locator('.ue').count(), 30);
    assert.equal(days(30), days(31), 'fixture: entry 30 is on the same day as entry 29');
    await page.locator('.ue').first().click();
    for (const want of [60, 65]) {
      await page.evaluate(() => { document.querySelector('.scr').scrollTop = 1e6; });
      await page.waitForFunction((n) => document.querySelectorAll('.ue').length === n, want);
      const heads = await texts(page, '.ud');
      assert.equal(heads.length, days(want), 'one heading per day at ' + want);
      assert.equal(new Set(heads).size, heads.length, 'no repeated heading at ' + want);
    }
    assert.equal(await page.locator('#updmore').count(), 0);
    assert.deepEqual(await texts(page, '.um'), ['Open me'], 'a re-render from the sentinel keeps the entry open');
    assert.ok(await page.evaluate(() => document.querySelector('.scr').scrollTop) > 0, 'scroll position is kept');
    await context.close();
  });
});

// Log fight "Did she hit herself?" question: chips, optional follow-up, persisted record, history chip.
// Runs in Chromium, plus WebKit when GL_WEBKIT_PW/GL_WEBKIT_EXEC are set.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const engines = { chromium };
if (process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC) {
  const pw = await import(process.env.GL_WEBKIT_PW);
  engines.webkit = { launch: (o) => pw.webkit.launch({ ...o, executablePath: process.env.GL_WEBKIT_EXEC }) };
}

const UID = 'u-me', PID = 'u-her';
const SEED = {
  session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } },
  ['shared.' + UID]: {
    couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z' },
    members: [
      { user_id: UID, name: 'Me', checkin_time: '21:00' },
      { user_id: PID, name: 'Her', checkin_time: '21:00' },
    ],
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, fight_markers: {}, rewards: {}, redemptions: {} },
    cursors: {}, outbox: [],
  },
  ['priv.' + UID]: { fights: [], affirmations: [], prefs: {} },
};

for (const [name, type] of Object.entries(engines)) describe(name, () => {
  let browser;
  before(async () => { browser = await type.launch({ headless: true }); });
  after(async () => { await browser.close(); });

  async function open() {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.addInitScript((seed) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) for (const k in seed) localStorage.setItem('cycle:' + k, JSON.stringify(seed[k]));
    }, SEED);
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    // Backend calls fail like offline; the store treats that as retry-later.
    await context.route('https://x.test/**', (route) => route.abort());
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.click('[data-a="row:fight"]');
    await page.waitForSelector('[data-a="fightsave"]');
    return { context, page };
  }
  const on = (page, a) => page.$eval(`[data-a="${a}"]`, (e) => e.classList.contains('on'));
  const present = async (page, a) => (await page.$(`[data-a="${a}"]`)) !== null;
  // Read the real persistence path (localStorage), waiting for the debounced write. Returns the shared
  // fight marker (where the answers live) and the private fight record (which must not carry them).
  async function save(page) {
    await page.click('[data-a="fightsave"]');
    await page.waitForFunction(() => Object.keys(JSON.parse(localStorage.getItem('cycle:shared.u-me')).rows.fight_markers).length > 0
      && JSON.parse(localStorage.getItem('cycle:priv.u-me')).fights.length > 0);
    const { markers, fights } = await page.evaluate(() => ({
      markers: Object.values(JSON.parse(localStorage.getItem('cycle:shared.u-me')).rows.fight_markers),
      fights: JSON.parse(localStorage.getItem('cycle:priv.u-me')).fights,
    }));
    assert.equal(markers.length, 1);
    assert.equal(fights.length, 1);
    assert.equal(fights[0].id, markers[0].id);
    assert.equal('hitSelf' in fights[0], false);
    assert.equal('hitRelated' in fights[0], false);
    return markers;
  }
  async function pointsText(page) {
    await page.click('[data-a="go:points"]');
    await page.waitForSelector('.ledger', { state: 'attached' });
    return page.$$eval('.ledger .ln', (els) => els.map((e) => e.textContent.replace(/\s+/g, ' ').trim()));
  }
  async function history(page) {
    await page.click('[data-a="tab:us"]');
    await page.click('[data-a="go:cycle"]');
    await page.waitForSelector('.rcs', { state: 'attached' });
    return page.$$eval('.rcs .rc', (els) => els.map((e) => e.textContent.trim()));
  }

  test('follow-up is hidden until hit is Yes', async () => {
    const { context, page } = await open();
    assert.equal(await present(page, 'yn:hitRel:yes'), false);
    await page.click('[data-a="yn:hit:no"]');
    assert.equal(await present(page, 'yn:hitRel:yes'), false);
    await page.click('[data-a="yn:hit:yes"]');
    assert.equal(await present(page, 'yn:hitRel:yes'), true);
    assert.equal(await present(page, 'yn:hitRel:no'), true);
    assert.match(await page.textContent('body'), /Was it related to you\?/);
    await context.close();
  });

  test('yes + related yes is saved and shown in history', async () => {
    const { context, page } = await open();
    await page.click('[data-a="yn:hit:yes"]');
    await page.click('[data-a="yn:hitRel:yes"]');
    const fights = await save(page);
    assert.equal(fights[0].hit_self, true);
    assert.equal(fights[0].hit_related, true);
    assert.ok((await pointsText(page)).includes('\u22125Fight · Hit herself, related to Me'), 'Points Fight line');
    assert.ok((await history(page)).includes('Hit herself, related to me'));
    await context.close();
  });

  test('yes + related no shows "not related to me"', async () => {
    const { context, page } = await open();
    await page.click('[data-a="yn:hit:yes"]');
    await page.click('[data-a="yn:hitRel:no"]');
    const fights = await save(page);
    assert.equal(fights[0].hit_self, true);
    assert.equal(fights[0].hit_related, false);
    assert.ok((await history(page)).includes('Hit herself, not related to me'));
    await context.close();
  });

  test('yes + related unanswered shows plain "Hit herself"', async () => {
    const { context, page } = await open();
    await page.click('[data-a="yn:hit:yes"]');
    const fights = await save(page);
    assert.equal(fights[0].hit_self, true);
    assert.equal(fights[0].hit_related, null);
    assert.ok((await history(page)).includes('Hit herself'));
    await context.close();
  });

  test('related chosen then hit flipped to No saves hitRelated null and hides follow-up', async () => {
    const { context, page } = await open();
    await page.click('[data-a="yn:hit:yes"]');
    await page.click('[data-a="yn:hitRel:yes"]');
    await page.click('[data-a="yn:hit:no"]');
    assert.equal(await present(page, 'yn:hitRel:yes'), false);
    const fights = await save(page);
    assert.equal(fights[0].hit_self, false);
    assert.equal(fights[0].hit_related, null);
    assert.deepEqual((await history(page)).filter((t) => /Hit herself/.test(t)), []);
    await context.close();
  });

  test('untouched saves both null', async () => {
    const { context, page } = await open();
    const fights = await save(page);
    assert.equal(fights[0].hit_self, null);
    assert.equal(fights[0].hit_related, null);
    await context.close();
  });

  test('tapping the selected chip clears it', async () => {
    const { context, page } = await open();
    await page.click('[data-a="yn:hit:yes"]');
    assert.equal(await on(page, 'yn:hit:yes'), true);
    assert.equal(await present(page, 'yn:hitRel:yes'), true);
    await page.click('[data-a="yn:hit:yes"]');
    assert.equal(await on(page, 'yn:hit:yes'), false);
    assert.equal(await on(page, 'yn:hit:no'), false);
    assert.equal(await present(page, 'yn:hitRel:yes'), false);
    const fights = await save(page);
    assert.equal(fights[0].hit_self, null);
    await context.close();
  });

  test('partner-logged marker shows "not related to <partner>" on Points', async () => {
    const { context, page } = await open();
    await page.evaluate(([pid]) => {
      const k = 'cycle:shared.u-me', sh = JSON.parse(localStorage.getItem(k));
      sh.rows.fight_markers.fp = { id: 'fp', couple_id: 'c1', logged_by: pid, at: new Date(Date.now() - 36e5).toISOString(), repaired_at: null, hit_self: true, hit_related: false };
      localStorage.setItem(k, JSON.stringify(sh));
    }, [PID]);
    await page.reload({ waitUntil: 'domcontentloaded' });
    assert.ok((await pointsText(page)).includes('\u22125Fight · Hit herself, not related to Her'), 'Points Fight line');
    await context.close();
  });
});

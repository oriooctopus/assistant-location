// Log fight "Did she hit herself?" question: chips, "not related" checkbox, persisted record, history chip.
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

  test('not-related checkbox is hidden until hit is Yes', async () => {
    const { context, page } = await open();
    assert.equal(await present(page, 'hitnot'), false);
    await page.click('[data-a="yn:hit:no"]');
    assert.equal(await present(page, 'hitnot'), false);
    await page.click('[data-a="yn:hit:yes"]');
    assert.equal(await present(page, 'hitnot'), true);
    assert.equal(await on(page, 'hitnot'), false);
    assert.equal((await page.textContent('[data-a="hitnot"]')).trim(), 'Click here if it was not related to you');
    assert.ok((await page.$eval('[data-a="hitnot"]', (e) => e.getBoundingClientRect().height)) >= 44, 'tap target >= 44px');
    await context.close();
  });

  test('yes + checked saves hit_related false and shows "not related to <name>"', async () => {
    const { context, page } = await open();
    await page.click('[data-a="yn:hit:yes"]');
    await page.click('[data-a="hitnot"]');
    assert.equal(await on(page, 'hitnot'), true);
    const fights = await save(page);
    assert.equal(fights[0].hit_self, true);
    assert.equal(fights[0].hit_related, false);
    assert.ok((await pointsText(page)).includes('\u22125Fight \u00b7 Hit herself, not related to Me'), 'Points Fight line');
    assert.ok((await history(page)).includes('Hit herself, not related to me'));
    await context.close();
  });

  test('yes + unchecked (or checked then unchecked) saves hit_related null, plain "Hit herself"', async () => {
    const { context, page } = await open();
    await page.click('[data-a="yn:hit:yes"]');
    await page.click('[data-a="hitnot"]');
    await page.click('[data-a="hitnot"]');
    assert.equal(await on(page, 'hitnot'), false);
    const fights = await save(page);
    assert.equal(fights[0].hit_self, true);
    assert.equal(fights[0].hit_related, null);
    assert.ok((await pointsText(page)).includes('\u22125Fight \u00b7 Hit herself'), 'Points Fight line');
    assert.ok((await history(page)).includes('Hit herself'));
    await context.close();
  });

  test('checked then hit flipped to No saves hit_related null and hides the checkbox', async () => {
    const { context, page } = await open();
    await page.click('[data-a="yn:hit:yes"]');
    await page.click('[data-a="hitnot"]');
    await page.click('[data-a="yn:hit:no"]');
    assert.equal(await present(page, 'hitnot'), false);
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
    assert.equal(await present(page, 'hitnot'), true);
    await page.click('[data-a="yn:hit:yes"]');
    assert.equal(await on(page, 'yn:hit:yes'), false);
    assert.equal(await on(page, 'yn:hit:no'), false);
    assert.equal(await present(page, 'hitnot'), false);
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

  // Keyboard open (iOS): tapping a non-field control must keep the field focused. If it blurs, the keyboard closes,
  // .scr grows and its scrollTop is clamped (the screen jumps). Keyboard is simulated via visualViewport height + resize.
  async function typeVent(page) {
    await page.fill('textarea[data-d="vent"]', 'hello');
    await page.evaluate(() => { const t = document.querySelector('textarea[data-d="vent"]'); t.focus(); t.setSelectionRange(2, 4); });
    await page.evaluate(() => { Object.defineProperty(window.visualViewport, 'height', { configurable: true, get: () => 844 - 336 }); window.visualViewport.dispatchEvent(new Event('resize')); });
    await page.evaluate(() => { const s = document.querySelector('.scr'); s.scrollTop = s.scrollHeight; });
  }
  async function tap(page, a) { // real mouse at measured coordinates, no Playwright auto-scroll
    const box = await (await page.$(`[data-a="${a}"]`)).boundingBox();
    const hit = await page.evaluate(([x, y, a]) => document.elementFromPoint(x, y).closest('[data-a]')?.getAttribute('data-a') === a, [box.x + box.width / 2, box.y + box.height / 2, a]);
    assert.ok(hit, a + ' must be tappable without scrolling');
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  }
  const focused = (page) => page.evaluate(() => { const a = document.activeElement; return a.getAttribute('data-d') + '|' + a.value + '|' + a.selectionStart + '-' + a.selectionEnd; });
  const scrollTop = (page) => page.evaluate(() => document.querySelector('.scr').scrollTop);

  test('tapping Apologize with the Vent keyboard open keeps Vent focused and .scr still', async () => {
    const { context, page } = await open();
    await typeVent(page);
    const before = await scrollTop(page);
    assert.ok(before > 100, 'precondition: scrolled with keyboard open, got ' + before);
    await tap(page, 'chip:apologize');
    await page.waitForFunction(() => document.querySelector('[data-a="chip:apologize"]').classList.contains('on'));
    // iOS closes the keyboard when no field is focused any more.
    if (await page.evaluate(() => !/^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName))) {
      await page.evaluate(() => { Object.defineProperty(window.visualViewport, 'height', { configurable: true, get: () => 844 }); window.visualViewport.dispatchEvent(new Event('resize')); });
      await page.waitForTimeout(100);
    }
    assert.equal(await scrollTop(page), before);
    assert.equal(await focused(page), 'vent|hello|2-4');
    await context.close();
  });

  test('tapping Custom (adds the Title input) keeps Vent focused', async () => {
    const { context, page } = await open();
    await typeVent(page);
    await tap(page, 'chip:custom');
    await page.waitForSelector('input[data-d="customTitle"]');
    assert.equal(await focused(page), 'vent|hello|2-4');
    await context.close();
  });

  test('Rewrite keeps the text and Cancel still leaves the screen with a field focused', async () => {
    const { context, page } = await open();
    await typeVent(page);
    await tap(page, 'rewrite');
    await page.waitForTimeout(300);
    assert.equal(await page.$eval('textarea[data-d="vent"]', (e) => e.value), 'hello');
    await page.evaluate(() => { document.querySelector('.scr').scrollTop = 0; });
    await tap(page, 'back');
    await page.waitForSelector('[data-a="row:fight"]');
    await context.close();
  });
});

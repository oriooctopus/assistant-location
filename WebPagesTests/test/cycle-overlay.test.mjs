// Optional local overlay hook: with CYCLE_CONFIG.overlays naming a script, that script's registered row appears last
// on Home and opens its screen; with none configured Home is exactly the three built-in rows.
// Runs in Chromium, plus WebKit when GL_WEBKIT_PW/GL_WEBKIT_EXEC are set.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web');
const URL_ = 'file://' + path.join(WEB, 'index.html');
const CSS = fs.readFileSync(path.join(WEB, 'cycle.css'), 'utf8') + '\n#fx{display:none}';
const engines = { chromium };
if (process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC) {
  const pw = await import(process.env.GL_WEBKIT_PW);
  engines.webkit = { launch: (o) => pw.webkit.launch({ ...o, executablePath: process.env.GL_WEBKIT_EXEC }) };
}

const OVERLAY = `
CycleOverlay.register({
  id: 'fixture', label: 'Fixture row', meta: function () { return 'meta ok'; },
  screen: function () {
    var a = CycleOverlay.api;
    return a.phone('p2', '<header class="hd"><div>' + a.hdBack('Today') + '<h2>Fixture screen</h2></div></header>', { tab: false });
  }
});`;

// A signed-in, set-up user held entirely in localStorage (no native bridge), so Home renders offline.
const SEED = () => {
  const day = new Date().toISOString();
  localStorage.setItem('cycle:session', JSON.stringify({ access_token: 'a', refresh_token: 'r', expires_at: Date.now() / 1000 + 86400, user: { id: 'u1', email: 'a@b.test' } }));
  const rows = {}; ['items', 'todos', 'todo_events', 'checkins', 'fight_markers', 'rewards', 'redemptions'].forEach((t) => { rows[t] = {}; });
  localStorage.setItem('cycle:shared.u1', JSON.stringify({
    couple: { id: 'c1', tz: 'UTC', created_at: day },
    members: [{ user_id: 'u1', name: 'Me', checkin_time: '21:00:00' }, { user_id: 'u2', name: 'You', checkin_time: '21:00:00' }],
    rows, cursors: {}, outbox: []
  }));
};

for (const [name, type] of Object.entries(engines)) describe(name, () => {
  let browser;
  before(async () => { browser = await type.launch({ headless: true }); });
  after(async () => { await browser.close(); });

  async function open(overlays) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
    await context.addInitScript((o) => { window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '', overlays: o }; }, overlays);
    await context.addInitScript(SEED);
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (route) => route.abort());
    await context.route('**/private/fixture.js', (route) => route.fulfill({ contentType: 'text/javascript', body: OVERLAY }));
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e));
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.rows .row');
    return { context, page, errors };
  }
  const labels = (page) => page.$$eval('.rows .row .lb', (els) => els.map((e) => e.textContent));

  test('overlay row and route appear when an overlay is configured', async () => {
    const { context, page, errors } = await open(['private/fixture.js']);
    assert.deepEqual(await labels(page), ['Send', 'To do', 'Log fight', 'Fixture row']);
    assert.equal(await page.textContent('.rows .row.ovr .mt'), 'meta ok');
    await page.click('.rows .row.ovr');
    await page.waitForSelector('h2');
    assert.equal(await page.textContent('h2'), 'Fixture screen');
    await page.click('[data-a=back]');
    await page.waitForSelector('.rows .row');
    assert.deepEqual(await labels(page), ['Send', 'To do', 'Log fight', 'Fixture row']);
    assert.deepEqual(errors, []);
    await context.close();
  });

  test('a native route naming the overlay opens its screen', async () => {
    const { context, page, errors } = await open(['private/fixture.js']);
    await page.evaluate(() => window.cycleNative.route('fixture'));
    await page.waitForSelector('h2');
    assert.equal(await page.textContent('h2'), 'Fixture screen');
    assert.deepEqual(errors, []);
    await context.close();
  });

  test('Home is unchanged when no overlay is configured', async () => {
    const { context, page, errors } = await open(undefined);
    assert.deepEqual(await labels(page), ['Send', 'To do', 'Log fight']);
    assert.equal(await page.$('.ovr'), null);
    assert.deepEqual(errors, []);
    await context.close();
  });

  test('a configured overlay that fails to load is loud, not silently skipped', async () => {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
    await context.addInitScript(() => { window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '', overlays: ['private/missing.js'] }; });
    await context.addInitScript(SEED);
    await context.route('https://x.test/**', (route) => route.abort());
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(500);
    assert.ok(errors.some((m) => /overlay failed to load: private\/missing\.js/.test(m)), 'got ' + JSON.stringify(errors));
    assert.equal(await page.$('.rows .row'), null);
    await context.close();
  });
});

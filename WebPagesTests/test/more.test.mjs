// Tests for Modules/WebPages/more.html against a MOCKED GL bridge (see
// mock-bridge.mjs) -- no native app, no network. Loaded via file:// exactly
// as WKWebView loads it, since that's what "bundled, offline" means here.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { buildMockBridgeScript } from './mock-bridge.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MORE_URL = 'file://' + path.join(HERE, '../../Modules/WebPages/more.html');

let browser;

before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { await browser.close(); });

function defaultModules() {
  return [
    { identifier: 'a', title: 'Alpha' },
    { identifier: 'b', title: 'Beta' },
    { identifier: 'c', title: 'Gamma' },
  ];
}

async function openMore(config, { hasTouch = true } = {}) {
  const context = await browser.newContext({ hasTouch, viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript(config));
  const page = await context.newPage();
  await page.goto(MORE_URL);
  return { context, page };
}

function baseConfig(overrides = {}) {
  return {
    boot: { palette: null, mode: 'dark', themeId: null, platform: 'ios' },
    responses: {
      listModules: { modules: defaultModules() },
      getPref: { value: null }, // both moreOrder and moreHeroes default to "nothing saved"
      openModule: { opened: true },
      setPref: {},
    },
    ...overrides,
  };
}

test('renders a tile per module, in module order, when no prefs are saved', async () => {
  const { context, page } = await openMore(baseConfig());
  await page.waitForSelector('.gl-tile');
  const titles = await page.locator('.gl-tile-title').allTextContents();
  assert.deepEqual(titles, ['Alpha', 'Beta', 'Gamma']);
  await context.close();
});

test('a saved order is honored; a module missing from it is appended in module order', async () => {
  const { context, page } = await openMore(baseConfig({
    responses: {
      listModules: { modules: defaultModules() },
      getPref: { value: ['c', 'a'] }, // 'b' is missing from the saved order
      openModule: { opened: true },
      setPref: {},
    },
  }));
  await page.waitForSelector('.gl-tile');
  const titles = await page.locator('.gl-tile-title').allTextContents();
  assert.deepEqual(titles, ['Gamma', 'Alpha', 'Beta']);
  await context.close();
});

test('unknown ids in the saved order are skipped', async () => {
  const { context, page } = await openMore(baseConfig({
    responses: {
      listModules: { modules: defaultModules() },
      getPref: { value: ['ghost', 'b', 'nope', 'a'] },
      openModule: { opened: true },
      setPref: {},
    },
  }));
  await page.waitForSelector('.gl-tile');
  const titles = await page.locator('.gl-tile-title').allTextContents();
  assert.deepEqual(titles, ['Beta', 'Alpha', 'Gamma']);
  await context.close();
});

test('an empty module list shows an empty state, never a blank grid', async () => {
  const { context, page } = await openMore(baseConfig({
    responses: { listModules: { modules: [] }, getPref: { value: null }, openModule: { opened: true }, setPref: {} },
  }));
  await page.waitForSelector('#gl-empty:not(.gl-hidden)');
  assert.equal(await page.locator('#gl-empty').textContent(), 'No modules available.');
  assert.equal(await page.locator('.gl-tile').count(), 0);
  await context.close();
});

test('duplicate identifiers in listModules render exactly one tile each, no blank grid', async () => {
  const { context, page } = await openMore(baseConfig({
    responses: {
      listModules: { modules: [
        { identifier: 'a', title: 'Alpha' },
        { identifier: 'a', title: 'Alpha Duplicate' },
        { identifier: 'b', title: 'Beta' },
      ] },
      getPref: { value: null },
      openModule: { opened: true },
      setPref: {},
    },
  }));
  await page.waitForSelector('.gl-tile');
  const titles = await page.locator('.gl-tile-title').allTextContents();
  assert.deepEqual(titles, ['Alpha', 'Beta']);
  await context.close();
});

test('a bridge that never replies to listModules shows the error state with retry, and retry recovers', async () => {
  const { context, page } = await openMore(baseConfig({
    responses: {},
    neverReply: ['listModules'],
  }));
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 8000 });
  assert.match(await page.locator('#gl-error-text').textContent(), /timeout/);

  // Fix the bridge for the retry and click it.
  await page.evaluate(() => window.__glMock.configure({
    neverReply: [],
    responses: { listModules: { modules: [{ identifier: 'a', title: 'Alpha' }] }, getPref: { value: null } },
  }));
  await page.click('#gl-retry-btn');
  await page.waitForSelector('.gl-tile');
  assert.deepEqual(await page.locator('.gl-tile-title').allTextContents(), ['Alpha']);
  await context.close();
});

test('a reply arriving after the timeout has already fired an error must not double-render', async () => {
  const { context, page } = await openMore(baseConfig({
    responses: { getPref: { value: null } },
    neverReply: ['listModules'],
  }));
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 8000 });

  // The late reply arrives now, well after the 5s timeout already rejected the call.
  await page.evaluate(() => window.__glMock.replyNow('listModules', { modules: [{ identifier: 'a', title: 'Alpha' }] }));
  await page.waitForTimeout(300);
  // Still on the error screen -- a late reply to an already-timed-out call must be ignored.
  assert.equal(await page.locator('#gl-error').isVisible(), true);
  assert.equal(await page.locator('.gl-tile').count(), 0);
  await context.close();
});

test('a single tap opens the module exactly once', async () => {
  const { context, page } = await openMore(baseConfig());
  await page.waitForSelector('.gl-tile');
  await page.locator('.gl-tile').first().click();
  await page.waitForTimeout(100);
  const calls = await page.evaluate(() => window.__glCallLog.filter(c => c.method === 'openModule'));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].params.identifier, 'a');
  await context.close();
});

test('a double tap opens the module only once (double-fire guard while a call is pending)', async () => {
  const { context, page } = await openMore(baseConfig({
    responses: {
      listModules: { modules: defaultModules() },
      getPref: { value: null },
      openModule: { opened: true },
      setPref: {},
    },
    delays: { openModule: 200 }, // wide enough to make a same-tick double-click land inside the pending window
  }));
  await page.waitForSelector('.gl-tile');
  const tile = page.locator('.gl-tile').first();
  await tile.click();
  await tile.click({ force: true });
  await page.waitForTimeout(400);
  const calls = await page.evaluate(() => window.__glCallLog.filter(c => c.method === 'openModule'));
  assert.equal(calls.length, 1);
  await context.close();
});

test('toggling the hero badge persists the complete hero set and applies the hero span', async () => {
  const { context, page } = await openMore(baseConfig());
  await page.waitForSelector('.gl-tile');
  const firstBadge = page.locator('[data-role="hero-badge"]').first();
  await firstBadge.click();
  await page.waitForTimeout(50);
  assert.equal(await page.locator('.gl-tile').first().evaluate(el => el.classList.contains('hero')), true);
  const calls = await page.evaluate(() => window.__glCallLog.filter(c => c.method === 'setPref' && c.params.key === 'moreHeroes'));
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[calls.length - 1].params.value, ['a']);
  await context.close();
});

test('toggling a SECOND hero persists the complete set, not just the latest one', async () => {
  // A single-hero version of this test can't tell "persists the set" apart
  // from "persists only the most recently toggled id" (e.g. a `.slice(0, 1)`
  // truncation bug) -- both would show one id and look correct. Two heroes
  // is the minimum that forces the persisted array to actually be a set.
  const { context, page } = await openMore(baseConfig());
  await page.waitForSelector('.gl-tile');
  await page.locator('[data-role="hero-badge"]').nth(0).click(); // 'a'
  await page.waitForTimeout(50);
  await page.locator('[data-role="hero-badge"]').nth(1).click(); // 'b'
  await page.waitForTimeout(50);

  assert.equal(await page.locator('.gl-tile[data-id="a"]').evaluate(el => el.classList.contains('hero')), true);
  assert.equal(await page.locator('.gl-tile[data-id="b"]').evaluate(el => el.classList.contains('hero')), true);

  const calls = await page.evaluate(() => window.__glCallLog.filter(c => c.method === 'setPref' && c.params.key === 'moreHeroes'));
  const lastPersisted = calls[calls.length - 1].params.value;
  assert.deepEqual(lastPersisted.slice().sort(), ['a', 'b']);
  await context.close();
});

test('no white flash: body background is themed before first paint when palette is null', async () => {
  const { context, page } = await openMore(baseConfig());
  const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  assert.equal(bg, 'rgb(13, 15, 18)'); // default dark palette bg #0d0f12
  await context.close();
});

test('__glThemeChanged re-themes in place, preserving hero state', async () => {
  const { context, page } = await openMore(baseConfig());
  await page.waitForSelector('.gl-tile');
  await page.locator('[data-role="hero-badge"]').first().click();
  await page.waitForTimeout(50);

  await page.evaluate(() => window.__glThemeChanged({
    palette: { bg: '#123456', surface: '#000000', text: '#ffffff', 'text-dim': '#aaaaaa', accent: '#ff0000', danger: '#ff0000' },
    mode: 'light', themeId: 'test-theme',
  }));

  const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  assert.equal(bg, 'rgb(18, 52, 86)');
  assert.equal(await page.locator('.gl-tile').first().evaluate(el => el.classList.contains('hero')), true);
  await context.close();
});

// -------- Drag reorder (long-press + touch) --------

async function longPressDragTo(page, fromSelector, toSelector) {
  await page.evaluate(({ fromSelector, toSelector }) => {
    function centerOf(el) {
      const r = el.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    }
    const fromEl = document.querySelector(fromSelector);
    const toEl = document.querySelector(toSelector);
    window.__dragState = { fromEl, start: centerOf(fromEl), end: centerOf(toEl) };
    function fire(type, el, x, y) {
      const touch = new Touch({ identifier: 1, target: el, clientX: x, clientY: y });
      el.dispatchEvent(new TouchEvent(type, {
        touches: type === 'touchend' ? [] : [touch],
        targetTouches: type === 'touchend' ? [] : [touch],
        changedTouches: [touch],
        bubbles: true, cancelable: true,
      }));
    }
    window.__fireTouch = fire;
    fire('touchstart', fromEl, window.__dragState.start.x, window.__dragState.start.y);
  }, { fromSelector, toSelector });

  await page.waitForTimeout(450); // exceed the 400ms long-press threshold so drag mode activates

  await page.evaluate(() => {
    const { fromEl, end } = window.__dragState;
    window.__fireTouch('touchmove', fromEl, end.x, end.y);
  });
  await page.waitForTimeout(50);
  await page.evaluate(() => {
    const { fromEl, end } = window.__dragState;
    window.__fireTouch('touchend', fromEl, end.x, end.y);
  });
}

test('dragging the first tile onto the last tile moves it to the end and persists the complete order', async () => {
  const { context, page } = await openMore(baseConfig());
  await page.waitForSelector('.gl-tile');
  await longPressDragTo(page, '.gl-tile[data-id="a"]', '.gl-tile[data-id="c"]');
  await page.waitForTimeout(100);
  const titles = await page.locator('.gl-tile-title').allTextContents();
  assert.deepEqual(titles, ['Beta', 'Gamma', 'Alpha']);
  const calls = await page.evaluate(() => window.__glCallLog.filter(c => c.method === 'setPref' && c.params.key === 'moreOrder'));
  assert.deepEqual(calls[calls.length - 1].params.value, ['b', 'c', 'a']);
  await context.close();
});

test('dragging the last tile onto the first tile moves it to the front', async () => {
  const { context, page } = await openMore(baseConfig());
  await page.waitForSelector('.gl-tile');
  await longPressDragTo(page, '.gl-tile[data-id="c"]', '.gl-tile[data-id="a"]');
  await page.waitForTimeout(100);
  const titles = await page.locator('.gl-tile-title').allTextContents();
  assert.deepEqual(titles, ['Gamma', 'Alpha', 'Beta']);
  const calls = await page.evaluate(() => window.__glCallLog.filter(c => c.method === 'setPref' && c.params.key === 'moreOrder'));
  assert.deepEqual(calls[calls.length - 1].params.value, ['c', 'a', 'b']);
  await context.close();
});

test('a hero tile can be dragged into a normal (non-hero) slot without losing its hero flag', async () => {
  const { context, page } = await openMore(baseConfig());
  await page.waitForSelector('.gl-tile');
  await page.locator('[data-role="hero-badge"]').first().click(); // make 'a' a hero
  await page.waitForTimeout(50);
  assert.equal(await page.locator('.gl-tile[data-id="a"]').evaluate(el => el.classList.contains('hero')), true);

  await longPressDragTo(page, '.gl-tile[data-id="a"]', '.gl-tile[data-id="c"]');
  await page.waitForTimeout(100);
  const titles = await page.locator('.gl-tile-title').allTextContents();
  assert.deepEqual(titles, ['Beta', 'Gamma', 'Alpha']);
  assert.equal(await page.locator('.gl-tile[data-id="a"]').evaluate(el => el.classList.contains('hero')), true);
  await context.close();
});

test('a short tap (released before the long-press threshold) opens instead of starting a drag', async () => {
  const { context, page } = await openMore(baseConfig());
  await page.waitForSelector('.gl-tile');
  await page.evaluate(() => {
    function centerOf(el) { const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; }
    const el = document.querySelector('.gl-tile[data-id="a"]');
    const p = centerOf(el);
    const touch = new Touch({ identifier: 1, target: el, clientX: p.x, clientY: p.y });
    el.dispatchEvent(new TouchEvent('touchstart', { touches: [touch], targetTouches: [touch], changedTouches: [touch], bubbles: true, cancelable: true }));
    el.dispatchEvent(new TouchEvent('touchend', { touches: [], targetTouches: [], changedTouches: [touch], bubbles: true, cancelable: true }));
  });
  await page.waitForTimeout(100);
  const calls = await page.evaluate(() => window.__glCallLog.filter(c => c.method === 'openModule'));
  assert.equal(calls.length, 1);
  await context.close();
});

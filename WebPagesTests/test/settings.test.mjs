// Tests for Modules/WebPages/settings.html against a MOCKED GL bridge.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { buildMockBridgeScript } from './mock-bridge.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SETTINGS_URL = 'file://' + path.join(HERE, '../../Modules/WebPages/settings.html');

let browser;

before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { await browser.close(); });

function themes() {
  return [
    { id: 'light', label: 'Light', mode: 'light' },
    { id: 'dark', label: 'Dark', mode: 'dark' },
    { id: 'void', label: 'Void', mode: 'dark' },
  ];
}

function baseConfig(overrides = {}) {
  return {
    boot: { palette: null, mode: 'dark', themeId: null, platform: 'ios' },
    responses: {
      getMode: { mode: 0 },
      getThemeState: { selectedId: 'dark', themes: themes(), error: null },
      setTheme: { ok: true },
      setMode: {},
      locationPermission: { status: 'always' },
      requestLocationPermission: {},
      configureWifiZone: {},
    },
    ...overrides,
  };
}

async function openSettings(config) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript(config));
  const page = await context.newPage();
  await page.goto(SETTINGS_URL);
  return { context, page };
}

test('appearance segment reflects getMode and setMode is optimistic', async () => {
  // delays.setMode is the whole point of this test: without it, a same-tick
  // synchronous DOM click handler updates the UI before ANY promise (mocked
  // or not) can resolve, so the assertion would pass even if renderMode were
  // wrongly moved into the .then() -- see the mutation-proof note below.
  const { context, page } = await openSettings(baseConfig({
    responses: { getMode: { mode: 2 } },
    delays: { setMode: 300 },
  }));
  await page.waitForFunction(() => document.querySelector('.gl-segment.selected')?.dataset.mode === '2');

  await page.locator('.gl-segment[data-mode="1"]').click();
  // Optimistic: the UI flips immediately, well before the 300ms delayed
  // reply has any chance to resolve.
  assert.equal(await page.locator('.gl-segment.selected').getAttribute('data-mode'), '1');
  const calls = await page.evaluate(() => window.__glCallLog.filter(c => c.method === 'setMode'));
  assert.deepEqual(calls.map(c => c.params.mode), [1]);
  await context.close();
});

test('theme list shows the selected theme with a check and Auto when selectedId is null', async () => {
  const { context, page } = await openSettings(baseConfig({
    responses: { getThemeState: { selectedId: null, themes: themes(), error: null } },
  }));
  await page.waitForSelector('#gl-theme-list:not(.gl-hidden)');
  const rows = page.locator('#gl-theme-list .gl-row');
  assert.equal(await rows.count(), 1 + themes().length);
  const autoRow = rows.first();
  assert.equal(await autoRow.locator('.gl-check').evaluate(el => el.classList.contains('selected')), true);
  await context.close();
});

test('getThemeState error shows "Theme server unreachable" while the rest of the page stays usable', async () => {
  const { context, page } = await openSettings(baseConfig({
    responses: {
      getMode: { mode: 0 },
      getThemeState: { selectedId: null, themes: [], error: 'server down' },
      locationPermission: { status: 'always' },
    },
  }));
  await page.waitForSelector('#gl-theme-error:not(.gl-hidden)');
  assert.equal((await page.locator('#gl-theme-error').textContent()).includes('Theme server unreachable'), true);

  // Appearance and Location are unaffected by the theme section's failure.
  await page.waitForFunction(() => document.querySelector('.gl-segment.selected')?.dataset.mode === '0');
  assert.equal(await page.locator('#gl-location-label').textContent(), 'Location: Always ✓');
  await context.close();
});

test('theme retry recovers after the server comes back', async () => {
  const { context, page } = await openSettings(baseConfig({
    responses: { getThemeState: { selectedId: null, themes: [], error: 'down' } },
  }));
  await page.waitForSelector('#gl-theme-error:not(.gl-hidden)');
  await page.evaluate((themesList) => window.__glMock.configure({
    responses: { getThemeState: { selectedId: 'dark', themes: themesList, error: null } },
  }), themes());
  await page.click('#gl-theme-retry');
  await page.waitForSelector('#gl-theme-list:not(.gl-hidden)');
  assert.equal(await page.locator('#gl-theme-list .gl-row').count(), 1 + themes().length);
  await context.close();
});

test('rapid theme switching: the last tap wins even though an earlier (failed) reply resolves later', async () => {
  // On a SUCCESSFUL setTheme reply, selectTheme's .then() branch is a no-op
  // regardless of the stale-reply token guard (it only acts on res.ok===false),
  // so two successful replies resolving out of order can never actually show
  // a wrong theme -- that version of this test (both calls succeeding) could
  // never fail even with the token guard deleted. To put the guard on the
  // critical path, the FIRST tap's call must FAIL (so its handler wants to
  // revert `themeState.selectedId`) and its reply must land AFTER the SECOND
  // tap has already taken over -- exactly what a real "user tapped twice
  // while the first request was still in flight and it errored" looks like.
  const { context, page } = await openSettings(baseConfig({
    responses: { getThemeState: { selectedId: 'dark', themes: themes(), error: null } },
    errors: { setTheme: ['light rejected by native', null] }, // call #0 (light) fails, call #1 (void) succeeds
    delays: { setTheme: [300, 20] }, // light's failing reply arrives LAST, well after void's
  }));
  await page.waitForSelector('#gl-theme-list:not(.gl-hidden)');

  await page.locator('[data-theme-id="light"]').click();
  await page.locator('[data-theme-id="void"]').click();

  await page.waitForTimeout(60); // let void's fast, successful reply land
  assert.equal(await page.locator('[data-theme-id="void"] .gl-check').evaluate(el => el.classList.contains('selected')), true);

  await page.waitForTimeout(300); // let light's slow, FAILING reply land too
  // Without the token guard, light's failure handler would revert
  // themeState.selectedId back to 'dark' (what it was when light was
  // tapped), stomping the already-applied 'void' selection.
  assert.equal(await page.locator('[data-theme-id="void"] .gl-check').evaluate(el => el.classList.contains('selected')), true);
  assert.equal(await page.locator('[data-theme-id="light"] .gl-check').evaluate(el => el.classList.contains('selected')), false);
  assert.equal(await page.locator('[data-theme-id="dark"] .gl-check').evaluate(el => el.classList.contains('selected')), false);

  const calls = await page.evaluate(() => window.__glCallLog.filter(c => c.method === 'setTheme'));
  assert.deepEqual(calls.map(c => c.params.id), ['light', 'void']);
  await context.close();
});

test('a setTheme reply of {ok:false} reverts the selection and surfaces the native error', async () => {
  const { context, page } = await openSettings(baseConfig({
    responses: {
      getThemeState: { selectedId: 'dark', themes: themes(), error: null },
      setTheme: { ok: false, error: 'theme rejected by native' },
    },
  }));
  await page.waitForSelector('#gl-theme-list:not(.gl-hidden)');

  await page.locator('[data-theme-id="light"]').click();
  // Selection reverts back to the pre-tap theme -- never left showing 'light' as if the tap had taken.
  await page.waitForFunction(() => document.querySelector('[data-theme-id="dark"] .gl-check')?.classList.contains('selected'));
  assert.equal(await page.locator('[data-theme-id="light"] .gl-check').evaluate(el => el.classList.contains('selected')), false);
  assert.equal(await page.locator('#gl-theme-action-error').isVisible(), true);
  assert.equal(await page.locator('#gl-theme-action-error-text').textContent(), 'theme rejected by native');
  await context.close();
});

test('a rejected setTheme call reverts the selection and surfaces an error', async () => {
  const { context, page } = await openSettings(baseConfig({
    responses: { getThemeState: { selectedId: 'dark', themes: themes(), error: null } },
    errors: { setTheme: 'native bridge crashed' },
  }));
  await page.waitForSelector('#gl-theme-list:not(.gl-hidden)');

  await page.locator('[data-theme-id="light"]').click();
  await page.waitForFunction(() => document.querySelector('[data-theme-id="dark"] .gl-check')?.classList.contains('selected'));
  assert.equal(await page.locator('[data-theme-id="light"] .gl-check').evaluate(el => el.classList.contains('selected')), false);
  assert.equal(await page.locator('#gl-theme-action-error').isVisible(), true);
  assert.equal(await page.locator('#gl-theme-action-error-text').textContent(), 'native bridge crashed');
  await context.close();
});

test('a bridge that never replies to getThemeState surfaces the real 5s GLBridge timeout as an error', async () => {
  // Distinct from the existing "getThemeState error" test above, which feeds
  // back a `{error: '...'}` PAYLOAD -- that never exercises gl-bridge.js's
  // own 5000ms setTimeout rejection path at all. neverReply does: the mock
  // swallows the call entirely, so the only thing that ever settles this
  // promise is GLBridge's internal timer. (Per the audit: before this test,
  // no settings test would fail if that timeout were deleted outright.)
  const { context, page } = await openSettings(baseConfig({
    responses: { getMode: { mode: 0 }, locationPermission: { status: 'always' } },
    neverReply: ['getThemeState'],
  }));
  await page.waitForSelector('#gl-theme-error:not(.gl-hidden)', { timeout: 8000 });
  // The rest of the page must be unaffected -- same invariant as the existing error-payload test.
  await page.waitForFunction(() => document.querySelector('.gl-segment.selected')?.dataset.mode === '0');
  await context.close();
});

const statusMatrix = [
  ['always', 'Location: Always ✓', false],
  ['whenInUse', 'Location: While Using — background tracking needs Always', true],
  ['denied', 'Location: Denied — background tracking needs Always', true],
  ['restricted', 'Location: Restricted — background tracking needs Always', true],
  ['notDetermined', 'Location: Not Determined — background tracking needs Always', true],
];

for (const [status, expectedText, expectButton] of statusMatrix) {
  test(`location status "${status}" renders the matching copy and button visibility`, async () => {
    const { context, page } = await openSettings(baseConfig({
      responses: { locationPermission: { status } },
    }));
    await page.waitForFunction((text) => document.getElementById('gl-location-label').textContent === text, expectedText);
    assert.equal(await page.locator('#gl-location-request-btn').isVisible(), expectButton);
    await context.close();
  });
}

test('the request button is wired to requestLocationPermission and refreshes status', async () => {
  const { context, page } = await openSettings(baseConfig({
    responses: { locationPermission: { status: 'denied' } },
  }));
  await page.waitForSelector('#gl-location-request-btn:visible');
  await page.evaluate(() => window.__glMock.configure({ responses: { locationPermission: { status: 'always' } } }));
  await page.click('#gl-location-request-btn');
  await page.waitForFunction(() => document.getElementById('gl-location-label').textContent === 'Location: Always ✓');
  assert.equal(await page.locator('#gl-location-request-btn').isVisible(), false);
  await context.close();
});

test('visibilitychange refreshes location and theme state', async () => {
  const { context, page } = await openSettings(baseConfig({
    responses: { locationPermission: { status: 'denied' }, getThemeState: { selectedId: 'dark', themes: themes(), error: null } },
  }));
  await page.waitForSelector('#gl-location-request-btn:visible');
  await page.waitForFunction(() => document.querySelector('[data-theme-id="dark"] .gl-check')?.classList.contains('selected'));

  // Change what BOTH mocked calls return, so the assertions below can only
  // pass if visibilitychange actually re-fetched each -- a stale in-memory
  // location or theme selection would fail these, not just leave the old
  // (also-passing) values in place.
  await page.evaluate((themesList) => window.__glMock.configure({
    responses: { locationPermission: { status: 'always' }, getThemeState: { selectedId: 'void', themes: themesList, error: null } },
  }), themes());
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await page.waitForFunction(() => document.getElementById('gl-location-label').textContent === 'Location: Always ✓');
  await page.waitForFunction(() => document.querySelector('[data-theme-id="void"] .gl-check')?.classList.contains('selected'));
  assert.equal(await page.locator('[data-theme-id="dark"] .gl-check').evaluate(el => el.classList.contains('selected')), false);
  await context.close();
});

test('wifi row calls configureWifiZone', async () => {
  const { context, page } = await openSettings(baseConfig());
  await page.waitForSelector('#gl-wifi-btn');
  await page.click('#gl-wifi-btn');
  const calls = await page.evaluate(() => window.__glCallLog.filter(c => c.method === 'configureWifiZone'));
  assert.equal(calls.length, 1);
  await context.close();
});

test('no white flash: body background is themed before first paint when palette is null', async () => {
  const { context, page } = await openSettings(baseConfig());
  const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  assert.equal(bg, 'rgb(13, 15, 18)');
  await context.close();
});

test('__glThemeChanged re-themes in place, preserving the appearance selection', async () => {
  const { context, page } = await openSettings(baseConfig({ responses: { getMode: { mode: 2 } } }));
  await page.waitForFunction(() => document.querySelector('.gl-segment.selected')?.dataset.mode === '2');

  await page.evaluate(() => window.__glThemeChanged({
    palette: { bg: '#123456', surface: '#000000', text: '#ffffff', 'text-dim': '#aaaaaa', accent: '#ff0000', danger: '#ff0000' },
    mode: 'light', themeId: 'test-theme',
  }));

  const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  assert.equal(bg, 'rgb(18, 52, 86)');
  assert.equal(await page.locator('.gl-segment.selected').getAttribute('data-mode'), '2');
  await context.close();
});

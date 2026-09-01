// Tests for Modules/WebPages/recents.html against a MOCKED GL bridge (see
// mock-bridge.mjs) -- no native app, no network. Loaded via file:// exactly
// as GLWebPageCache's -activeWebPagesDirectory loads it (see
// Shared/GLWebModuleViewController.m's -initWithManagedPageNamed:), same
// convention as more.test.mjs/settings.test.mjs.
//
// This is the ONE thing that changed about recents.html's own behavior when
// it moved here from location-server/public/ as part of the web-page
// asset-update task: it used to be loaded ONLY over HTTP from
// location-server itself, so a bare `fetch('/journal/recordings')` always
// resolved against that same origin. Now that it can load from a file://
// bundle/cache copy, that relative fetch would resolve against file:// and
// fail -- so it now builds the URL from GL_BOOT.apiBase (added to every
// managed page's boot injection, see GLWebModuleViewController.m's
// -bootScriptSource) when present, falling back to the old relative
// behavior when it's absent (a plain browser, or GL_BOOT missing
// entirely) -- see recents.html's own apiBase() helper. The two tests below
// are what actually exercises that fallback: everything else about this
// page's rendering (transcript fallbacks, Clean/Raw toggle, etc.) already
// has real-network coverage against the genuine data API in
// location-server/test_recents.mjs, so isn't duplicated here.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { buildMockBridgeScript } from './mock-bridge.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RECENTS_URL = 'file://' + path.join(HERE, '../../Modules/WebPages/recents.html');

let browser;

before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { await browser.close(); });

function baseBoot(overrides = {}) {
  return { palette: null, mode: 'dark', themeId: null, platform: 'ios', ...overrides };
}

function baseConfig(bootOverrides = {}) {
  return {
    boot: baseBoot(bootOverrides),
    responses: {
      getApiToken: { token: 'test-token' },
      getPref: { value: true },
      goBack: {},
      setPref: {},
    },
  };
}

test('page.css and gl-bridge.js load as SIBLING files, not inlined -- the shared-asset-group contract', async () => {
  // Direct proof of the thing this file's move exists to establish: unlike
  // its previous inlined-bridge copy, this page must now actually reach out
  // to gl-bridge.js/page.css as separate <script src>/<link href> requests
  // sitting next to it on disk -- if GLWebPageCache ever promoted an HTML
  // file without its matching shared CSS/JS (the exact "atomic per set" bug
  // this task's mechanism exists to prevent), THIS is what would break.
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  const page = await context.newPage();
  const seenSiblingRequests = [];
  page.on('request', (req) => {
    if (req.url().endsWith('/gl-bridge.js') || req.url().endsWith('/page.css')) {
      seenSiblingRequests.push(req.url());
    }
  });
  await page.goto(RECENTS_URL);
  await page.waitForSelector('#gl-empty:not(.gl-hidden), .gl-card, #gl-error:not(.gl-hidden)');
  assert.ok(seenSiblingRequests.some((u) => u.endsWith('/gl-bridge.js')), 'gl-bridge.js was never requested as a sibling file');
  assert.ok(seenSiblingRequests.some((u) => u.endsWith('/page.css')), 'page.css was never requested as a sibling file');
  await context.close();
});

test('with no GL_BOOT.apiBase, loaded via file:// (no host to fall back to), the fetch fails fast into the error state -- no hang, no unhandled rejection', async () => {
  // Confirmed by hand (see this test's own history): Chromium's fetch()
  // refuses the "file" scheme outright ("Fetch API cannot load
  // file:///journal/recordings...") -- so a relative fetch('/journal/...')
  // from a file://-loaded page can NEVER reach a real server no matter what
  // GLWebPageCache does; this is a browser-level constraint, not something
  // recents.html's own code controls. In the REAL app this branch is moot
  // in practice: GLWebModuleViewController's -bootScriptSource sets
  // apiBase unconditionally on every managed page's boot, so a real
  // file://-loaded recents.html always has one (see the two tests below).
  // What actually matters here is that the failure is IMMEDIATE and lands
  // in this page's own designed error state, not a silent hang or a
  // console-only unhandled rejection a real user would just see as a
  // stuck spinner.
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig())); // no apiBase key in boot
  const page = await context.newPage();
  await page.goto(RECENTS_URL);
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 5000 });
  const text = await page.locator('#gl-error-text').textContent();
  assert.ok(text.startsWith("Couldn't load recordings:"), text);
  await context.close();
});

test('with GL_BOOT.apiBase set, the recordings fetch goes to that absolute origin and the response still renders', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig({ apiBase: 'http://192.0.2.55:8302' })));
  const page = await context.newPage();
  let requestedURL = null;
  await page.route('http://192.0.2.55:8302/journal/recordings*', (route) => {
    requestedURL = route.request().url();
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ recordings: [{ kind: 'voice', transcript: 'apiBase round trip', savedAt: '2026-01-01T00:00:00Z' }] }),
    });
  });
  await page.goto(RECENTS_URL);
  await page.waitForSelector('.gl-card');
  assert.equal(requestedURL, 'http://192.0.2.55:8302/journal/recordings?limit=20');
  assert.equal(await page.locator('.gl-transcript').first().textContent(), 'apiBase round trip');
  await context.close();
});

test('an unreachable apiBase host shows the error state, not a hang or a crash', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig({ apiBase: 'http://192.0.2.66:8302' })));
  const page = await context.newPage();
  await page.route('http://192.0.2.66:8302/journal/recordings*', (route) => route.abort('connectionrefused'));
  await page.goto(RECENTS_URL);
  await page.waitForSelector('#gl-error:not(.gl-hidden)');
  const text = await page.locator('#gl-error-text').textContent();
  assert.ok(text.startsWith("Couldn't load recordings:"), text);
  await context.close();
});

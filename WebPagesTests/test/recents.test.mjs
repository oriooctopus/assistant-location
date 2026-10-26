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

// A voice entry recorded while the page is open must not stay on
// "Transcribing…" once the server has the transcript (2026-10-25: the tab was
// left open across the recording and never refetched). Each request serves the
// next body in `bodies`, the last one repeating.
async function openSequencedPage(apiBase, bodies) {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig({ apiBase })));
  const page = await context.newPage();
  let calls = 0;
  await page.route(`${apiBase}/journal/recordings*`, (route) => {
    const transcript = bodies[Math.min(calls++, bodies.length - 1)];
    route.fulfill({
      status: 200, contentType: 'application/json',
      body: JSON.stringify({ recordings: [{ kind: 'voice', filename: 'v.m4a', transcript, savedAt: '2026-01-01T00:00:00Z' }] }),
    });
  });
  await page.goto(RECENTS_URL);
  await page.waitForSelector('.gl-card');
  return { context, page };
}

test('a pending transcript is re-polled until it arrives', async () => {
  const { context, page } = await openSequencedPage('http://192.0.2.88:8302', [null, 'heard it']);
  assert.equal(await page.locator('.gl-transcript').first().textContent(), 'Transcribing…');
  await page.waitForFunction(() => document.querySelector('.gl-transcript').textContent === 'heard it', null, { timeout: 8000 });
  await context.close();
});

test('returning to the page refetches the list', async () => {
  const { context, page } = await openSequencedPage('http://192.0.2.99:8302', ['old text', 'new text']);
  assert.equal(await page.locator('.gl-transcript').first().textContent(), 'old text');
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
  await page.waitForFunction(() => document.querySelector('.gl-transcript').textContent === 'new text', null, { timeout: 3000 });
  await context.close();
});

// --- Private entries (Face ID lock + optimistic, offline-durable toggle) -----
// Fully mocked: bridge `authenticate` via the mock bridge, the private-flag
// POST via page.route. The real-server round trip lives in
// location-server/test_recents.mjs in the assistant repo.
const API = 'http://192.0.2.77:8302';
const SECRET = 'my deeply private thought';
const QUEUE_KEY = 'gl.recents.privateQueue';

async function openPrivatePage(bridgeExtra = {}, onPost = null) {
  const config = baseConfig({ apiBase: API });
  config.responses.authenticate = { ok: true };
  Object.assign(config, bridgeExtra);
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(config));
  const page = await context.newPage();
  await page.route(`${API}/journal/recordings?*`, (route) => route.fulfill({
    status: 200, contentType: 'application/json',
    body: JSON.stringify({ recordings: [
      { kind: 'note', filename: 'a.txt', transcript: SECRET, isPrivate: true, savedAt: '2026-01-01T00:00:00Z' },
      { kind: 'note', filename: 'b.txt', transcript: 'a normal entry', isPrivate: false, savedAt: '2026-01-02T00:00:00Z' },
    ] }),
  }));
  await page.route(`${API}/journal/recordings/private`, (route) => onPost(route));
  await page.goto(RECENTS_URL);
  await page.waitForSelector('.gl-card');
  return { context, page };
}

const queueLen = (page) => page.evaluate((k) => JSON.parse(localStorage.getItem(k) || '[]').length, QUEUE_KEY);

test('private card is a placeholder with no text in the DOM; authenticate success reveals it', async () => {
  const { context, page } = await openPrivatePage({}, (r) => r.abort('failed'));
  assert.equal(await page.locator('.gl-card.gl-locked .gl-transcript').textContent(), '\u{1F512} Private entry');
  assert.equal((await page.content()).includes(SECRET), false);
  await page.locator('.gl-card.gl-locked').click();
  await page.waitForSelector('.gl-card:not(.gl-locked) >> text=' + SECRET);
  await context.close();
});

for (const [label, errors, msg] of [
  ['cancelled', { authenticate: 'cancelled' }, 0],
  ['unknown method', { authenticate: 'unknown method authenticate' }, 1],
]) {
  test(`authenticate error (${label}) keeps the card locked`, async () => {
    const { context, page } = await openPrivatePage({ errors }, (r) => r.abort('failed'));
    await page.locator('.gl-card.gl-locked').click();
    await page.waitForFunction(() => window.__glCallLog.some((c) => c.method === 'authenticate'));
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(await page.locator('.gl-card.gl-locked').count(), 1);
    assert.equal((await page.content()).includes(SECRET), false);
    assert.equal(await page.locator('.gl-lock-msg').count(), msg);
    await context.close();
  });
}

test('toggle is optimistic, queued before the request, kept on network failure, replayed on online', async () => {
  let blocked = true;
  let posted = null;
  const { context, page } = await openPrivatePage({}, (route) => {
    if (blocked) return route.abort('failed');
    posted = JSON.parse(route.request().postData());
    return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
  });
  await page.locator('.gl-card:not(.gl-locked) .gl-lock-btn').click();
  await page.waitForFunction(() => document.querySelectorAll('.gl-card.gl-locked').length === 2); // optimistic: both locked
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(await queueLen(page), 1, 'network failure keeps the op queued');
  blocked = false;
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await page.waitForFunction((k) => JSON.parse(localStorage.getItem(k) || '[]').length === 0, QUEUE_KEY);
  assert.deepEqual({ filename: posted.filename, private: posted.private }, { filename: 'b.txt', private: true });
  assert.ok(posted.opId);
  await context.close();
});

test('a 4xx on the private POST reverts the optimistic lock and drops the op', async () => {
  const { context, page } = await openPrivatePage({}, (route) => route.fulfill({ status: 404, contentType: 'application/json', body: '{}' }));
  await page.locator('.gl-card:not(.gl-locked) .gl-lock-btn').click();
  await page.waitForFunction((k) => JSON.parse(localStorage.getItem(k) || '[]').length === 0, QUEUE_KEY);
  await page.waitForFunction(() => document.querySelectorAll('.gl-card.gl-locked').length === 1);
  await context.close();
});

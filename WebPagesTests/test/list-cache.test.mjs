// Last-successful-list cache on the three bundled pages that fetch a list
// (recents.html, questions.html, session.html's Recent sessions). Each used to
// go blank offline. Now each paints its saved copy first, marked "Saved copy",
// replaces it when the live fetch succeeds, and never reads another page's
// cache (file:// pages share ONE localStorage, so keys must be per-page).
//
// Same harness as recents.test.mjs / session.test.mjs: mocked GL bridge,
// page.route()-mocked fetches, pages loaded via file://. A "reload" is a
// second page in the SAME browser context, so localStorage carries over.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { buildMockBridgeScript } from './mock-bridge.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const API = 'http://192.0.2.88:8302'; // TEST-NET-1 (RFC 5737) -- never a real host
const pageUrl = (f) => 'file://' + path.join(HERE, '../../Modules/WebPages', f);

let browser;
before(async () => {
  browser = await chromium.launch({ headless: true });
  const newContext = browser.newContext.bind(browser);
  browser.newContext = async (options) => {
    const context = await newContext(options);
    context.setDefaultTimeout(8000);
    return context;
  };
});
after(async () => { await browser.close(); });

async function newContext() {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript({
    boot: { palette: null, mode: 'dark', themeId: null, platform: 'ios', apiBase: API },
    responses: { getApiToken: { token: 't' }, getPref: { value: true }, setPref: {}, goBack: {} },
  }));
  return context;
}

// One entry per page: how to route its list endpoint, how to build a list of
// labelled items, and how to read back what is painted / whether the saved
// mark shows.
const PAGES = {
  recents: {
    file: 'recents.html',
    async route(context, labels, opts = {}) {
      await context.route(`${API}/journal/recordings*`, (route) => respond(route, opts, {
        recordings: labels.map((t) => ({ kind: 'voice', transcript: t, savedAt: '2026-01-01T00:00:00Z' })),
      }));
    },
    painted: (page) => page.locator('.gl-transcript:visible').allTextContents(),
    saved: (page) => page.locator('#gl-saved').isVisible(),
    cacheKey: 'gl.recents.cache',
  },
  questions: {
    file: 'questions.html',
    async route(context, labels, opts = {}) {
      await context.route(`${API}/questions`, (route) => respond(route, opts, {
        questions: labels.map((t, i) => ({ id: 'q' + i, source: 'marketplace', title: t, body: 'b', createdAt: new Date().toISOString(), context: {}, answer: { endpoint: '/x', payload: {} } })),
        visits: [], pending: [], takeovers: [],
      }));
    },
    painted: (page) => page.locator('#q-list:visible .q-item .q-title').allTextContents(),
    saved: (page) => page.locator('#q-saved').isVisible(),
    cacheKey: 'gl.questions.cache',
    refresh: (page) => page.evaluate(() => window.refreshQuestions()), // native calls this when the page returns to screen
  },
  session: {
    file: 'session.html',
    async route(context, labels, opts = {}) {
      await context.route(`${API}/sessions/projects*`, (route) =>
        route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ projects: ['p1'] }) }));
      await context.route(`${API}/sessions/recent*`, (route) => respond(route, opts, {
        sessions: labels.map((t) => ({ name: t, project: 'p1', state: 'done', startedAt: '2026-01-01T00:00:00Z' })),
      }));
    },
    painted: (page) => page.locator('#session-recent-list:visible .gl-row-label').allTextContents(),
    saved: (page) => page.locator('#session-recent-saved').isVisible(),
    cacheKey: 'gl-session-recent-cache-v1',
    refresh: (page) => page.click('#gl-refresh-btn'),
  },
};

// opts.fail -> network failure; opts.gate -> promise the response waits on.
async function respond(route, opts, body) {
  if (opts.fail) return route.abort('connectionrefused');
  if (opts.gate) await opts.gate;
  return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
}

/** Polls until the page has painted `n` list items (the live list has rendered). */
async function waitPainted(page, spec, n, why = 'live list did not render') {
  const deadline = Date.now() + 6000;
  while ((await spec.painted(page)).length !== n) {
    assert.ok(Date.now() < deadline, why + ': never painted ' + n + ' items, got ' + JSON.stringify(await spec.painted(page)));
    await page.waitForTimeout(50);
  }
}

/** Opens the page in `context` and waits for its first list/error paint to settle. */
async function open(context, spec) {
  const page = await context.newPage();
  await page.goto(pageUrl(spec.file));
  return page;
}

// Re-route the same context (page.route handlers in a context stack; unroute all first).
async function reroute(context, spec, labels, opts) {
  await context.unrouteAll({ behavior: 'wait' });
  await spec.route(context, labels, opts);
}

for (const [name, spec] of Object.entries(PAGES)) {
  test(`${name}: with a saved copy and a failing fetch, the saved list is painted and marked "Saved copy"`, async () => {
    const context = await newContext();
    await spec.route(context, ['alpha one', 'alpha two']);
    const first = await open(context, spec);
    await waitPainted(first, spec, 2);
    assert.deepEqual(await spec.painted(first), ['alpha one', 'alpha two']);
    assert.notEqual(await first.evaluate((k) => localStorage.getItem(k), spec.cacheKey), null, 'a successful live fetch must write the cache');
    assert.equal(await spec.saved(first), false, 'a live list must not carry the Saved copy mark');
    await first.close();

    await reroute(context, spec, [], { fail: true });
    // The saved mark is visible from the first paint, so wait for the FAILED
    // fetch to actually settle (the request was aborted) before asserting the
    // list survived it; otherwise this passes on the pre-fetch paint alone.
    const second = await context.newPage();
    const aborted = second.waitForEvent('requestfailed');
    await second.goto(pageUrl(spec.file));
    await aborted;
    await second.waitForTimeout(300); // let the page's own .catch() run
    assert.deepEqual(await spec.painted(second), ['alpha one', 'alpha two'], 'the saved copy must stay on screen when the fetch fails');
    assert.equal(await spec.saved(second), true);
    assert.match(await second.locator('.gl-saved-mark:not(.gl-hidden)').first().textContent(), /Saved copy/);
    await context.close();
  });

  test(`${name}: the saved copy paints BEFORE the live fetch resolves, then a successful fetch replaces it`, async () => {
    const context = await newContext();
    await spec.route(context, ['old one', 'old two']);
    const first = await open(context, spec);
    await waitPainted(first, spec, 2);
    assert.notEqual(await first.evaluate((k) => localStorage.getItem(k), spec.cacheKey), null, 'a successful live fetch must write the cache');
    await first.close();

    let release;
    const gate = new Promise((r) => { release = r; });
    await reroute(context, spec, ['new only'], { gate });
    const second = await open(context, spec);
    await waitPainted(second, spec, 2, 'saved copy must paint while the fetch is still in flight');
    assert.deepEqual(await spec.painted(second), ['old one', 'old two']);
    assert.equal(await spec.saved(second), true);

    release();
    await waitPainted(second, spec, 1, 'the live list must replace the saved copy');
    assert.deepEqual(await spec.painted(second), ['new only']);
    assert.equal(await spec.saved(second), false);
    const stored = await second.evaluate((k) => localStorage.getItem(k), spec.cacheKey);
    assert.ok(stored.includes('new only') && !stored.includes('old one'), 'the cache must now hold the live list: ' + stored);
    await context.close();
  });

  // A list that arrived live and is then followed by a failed refresh is now
  // just a copy of the last good fetch: it must say so. (recents has no
  // refresh trigger after load other than the Retry that only the mark shows.)
  if (spec.refresh) test(`${name}: a failed refresh after a live load marks the on-screen list "Saved copy" and keeps it`, async () => {
    const context = await newContext();
    await spec.route(context, ['live one', 'live two']);
    const page = await open(context, spec);
    await waitPainted(page, spec, 2);
    assert.equal(await spec.saved(page), false);
    await reroute(context, spec, [], { fail: true });
    const aborted = page.waitForEvent('requestfailed');
    await spec.refresh(page);
    await aborted;
    await page.waitForTimeout(300); // let the page's own .catch() run
    assert.equal(await spec.saved(page), true, 'failed refresh must mark the list as a saved copy');
    assert.deepEqual(await spec.painted(page), ['live one', 'live two'], 'failed refresh must keep the list');
    await context.close();
  });

  test(`${name}: never paints another page's cache`, async () => {
    const context = await newContext();
    // Populate the OTHER two pages' caches through real successful loads.
    for (const [otherName, other] of Object.entries(PAGES)) {
      if (otherName === name) continue;
      await other.route(context, ['FOREIGN ' + otherName]);
      const p = await open(context, other);
      await waitPainted(p, other, 1);
      assert.ok(await p.evaluate(() => localStorage.length) > 0, otherName + ' wrote nothing to localStorage, so there is no foreign cache to ignore');
      await p.close();
    }
    await context.unrouteAll({ behavior: 'wait' });
    await spec.route(context, [], { fail: true });
    const page = await context.newPage();
    const aborted = page.waitForEvent('requestfailed');
    await page.goto(pageUrl(spec.file));
    await aborted;
    await page.waitForTimeout(300); // let the page's own .catch() run
    // Failed fetch with NO cache of its own: the page's own error state, no list, no saved mark.
    assert.match(await page.evaluate(() => document.body.innerText), /Couldn't load/i, 'with no cache of its own the page must show its error state');
    assert.deepEqual(await spec.painted(page), [], 'another page\'s cache was painted');
    assert.equal(await spec.saved(page), false, 'Saved copy mark shown with no cache of its own');
    assert.ok(!(await page.evaluate(() => document.body.innerText)).includes('FOREIGN'), 'foreign cache text leaked into the page');
    await context.close();
  });
}

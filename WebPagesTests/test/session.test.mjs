// Tests for Modules/WebPages/session.html against a MOCKED GL bridge (see
// mock-bridge.mjs) and mocked /sessions/* fetches (via page.route()) -- no
// native app, no real server. Loaded via file:// exactly as
// GLWebModuleViewController's -initWithManagedPageNamed: loads it, same
// convention as more.test.mjs/recents.test.mjs/settings.test.mjs.
//
// Moved here from location-server/test-fixtures/session-page-playwright.mjs
// (superseded, deleted in the same change): that version stood up a REAL
// location-server instance across a fragile cross-repo relative path into
// this worktree just to serve session.html as a static file -- everything
// it actually exercised is page behavior against network/bridge responses,
// which this suite's existing page.route()/mock-bridge pattern covers with
// no real server at all, same as every other managed page's tests here.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { buildMockBridgeScript } from './mock-bridge.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SESSION_URL = 'file://' + path.join(HERE, '../../Modules/WebPages/session.html');
const API_BASE = 'http://192.0.2.77:8302'; // TEST-NET-1 (RFC 5737) -- never a real host

let browser;

before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { await browser.close(); });

function baseBoot(overrides = {}) {
  return { palette: null, mode: 'dark', themeId: null, platform: 'ios', apiBase: API_BASE, ...overrides };
}

function baseConfig(bridgeOverrides = {}) {
  return {
    boot: baseBoot(),
    responses: {
      getApiToken: { token: 'test-token' },
      goBack: {},
      getPref: { value: null },
      setPref: {},
      voiceStart: {},
      voiceStop: { text: 'a fake voice transcript' },
      ...bridgeOverrides,
    },
  };
}

/** Routes GET /sessions/projects to a fixed two-project list. */
async function routeProjects(context, projects = ['alpha', 'beta']) {
  await context.route(`${API_BASE}/sessions/projects*`, (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ projects }) }));
}

/** Routes GET /sessions/recent to a fixed sessions list. */
async function routeRecent(context, sessions = []) {
  await context.route(`${API_BASE}/sessions/recent*`, (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ sessions }) }));
}

async function newSessionPage(context) {
  const page = await context.newPage();
  await page.goto(SESSION_URL);
  await page.waitForFunction(() => document.getElementById('session-project').options.length > 0);
  return page;
}

test('project picker lists projects and Start becomes enabled once a prompt is typed', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.equal(await page.locator('#session-start-btn').isDisabled(), true);
  await page.fill('#session-prompt', 'do a thing');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await context.close();
});

test('Start failure (server 400) shows the error banner and keeps the typed draft', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await context.route(`${API_BASE}/sessions/start`, (route) =>
    route.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ error: 'unknown project' }) }));
  const page = await newSessionPage(context);
  await page.fill('#session-prompt', 'this will fail');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 5000 });
  const errorText = await page.locator('#gl-error-text').textContent();
  assert.match(errorText, /unknown project/);
  // Draft kept on failure -- the whole point of draft persistence is that a
  // rejected start never loses what the user typed.
  assert.equal(await page.inputValue('#session-prompt'), 'this will fail');
  assert.equal(await page.locator('#session-confirmation').isHidden(), true);
  await context.close();
});

test('an unreachable box (network-level failure, not a server response) shows a distinct error and keeps the draft', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await context.route(`${API_BASE}/sessions/start`, (route) => route.abort('connectionrefused'));
  const page = await newSessionPage(context);
  await page.fill('#session-prompt', 'box is down');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 5000 });
  const errorText = await page.locator('#gl-error-text').textContent();
  assert.match(errorText, /Box unreachable/);
  assert.equal(await page.inputValue('#session-prompt'), 'box is down');
  await context.close();
});

test('a successful Start clears the draft and shows the confirmation', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await context.route(`${API_BASE}/sessions/start`, (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'abc12345', name: 'do a thing', project: 'alpha' }) }));
  const page = await newSessionPage(context);
  await page.fill('#session-prompt', 'this will succeed');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.equal(await page.inputValue('#session-prompt'), '');
  await context.close();
});

test('a retried Start (same failed attempt) reuses the same idempotencyKey; a fresh Start after success mints a new one', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  const seenKeys = [];
  let callCount = 0;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    callCount += 1;
    const body = JSON.parse(route.request().postData());
    seenKeys.push(body.idempotencyKey);
    if (callCount === 1) {
      // First attempt: network-level failure (not a server rejection) --
      // per session.html's own comment, only THIS failure mode keeps the
      // idempotencyKey for a retry; a genuine server rejection does not.
      route.abort('connectionrefused');
    } else {
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'retry0001', name: 'retried', project: 'alpha' }) });
    }
  });
  const page = await newSessionPage(context);
  await page.fill('#session-prompt', 'retry me');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 5000 });
  // Retry the SAME attempt (prompt untouched, draft preserved by the box-unreachable path).
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.equal(seenKeys.length, 2);
  assert.equal(seenKeys[0], seenKeys[1], 'a retry of the same failed attempt must reuse its idempotencyKey');

  // A FRESH Start after a success gets a fresh key.
  await page.fill('#session-prompt', 'a genuinely new attempt');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.equal(seenKeys.length, 3);
  assert.notEqual(seenKeys[2], seenKeys[0], 'a new Start attempt after a success must mint a fresh idempotencyKey');
  await context.close();
});

test('the recent-sessions list renders each session with its state', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context, [
    { id: 'aaa11111', name: 'Fix the bug', project: 'alpha', state: 'working', startedAt: Date.now() },
    { id: 'bbb22222', name: 'Ship it', project: 'beta', state: 'blocked', startedAt: Date.now() - 60000 },
  ]);
  const page = await newSessionPage(context);
  await page.waitForSelector('.gl-recent-row-state');
  const states = await page.locator('.gl-recent-row-state').allTextContents();
  assert.deepEqual(states.sort(), ['blocked', 'working']);
  await context.close();
});

test("loadProjects()/loadRecent() clear a stale error banner on the NEXT successful load -- regression for the review round's clearError fix", async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  // First recent load fails -> error banner shows.
  let recentShouldFail = true;
  await context.route(`${API_BASE}/sessions/recent*`, (route) => {
    if (recentShouldFail) return route.fulfill({ status: 401, body: 'unauthorized' });
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ sessions: [] }) });
  });
  await routeProjects(context);
  const page = await newSessionPage(context);
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 5000 });
  // Now the next refresh succeeds -- the banner must clear, not linger from
  // the earlier failure (this is the exact bug the fix in this review round
  // addresses: loadRecent()/loadProjects() previously never called
  // clearError() on their success path).
  recentShouldFail = false;
  await page.click('#gl-refresh-btn');
  // `.gl-hidden` sets display:none, so an element carrying it is never
  // "visible" -- waitForSelector('#gl-error.gl-hidden') (Playwright's
  // default visible-state wait) would wait forever for a state that can
  // never be true. Poll the class directly instead.
  await page.waitForFunction(() => document.getElementById('gl-error').classList.contains('gl-hidden'), { timeout: 5000 });
  await context.close();
});

test('REGRESSION PROOF: without gl-bridge.js\'s per-call timeout option, a 6s-delayed voiceStop reply is dropped as a false "timeout"', async () => {
  // Drives session.html's REAL recording flow against a bridge stub that
  // delays its voiceStop reply by 6s -- longer than the bridge's old fixed
  // 5000ms default, shorter than session.html's new 90000ms voiceStop
  // timeout. Proves the fix (opts.timeoutMs plumbed through
  // GLBridge.call/session.html) actually matters: this same test against
  // the pre-fix code (GLBridge.call with no third `opts` param, or
  // session.html calling `GLBridge.call('voiceStop', {})` with no
  // timeoutMs) fails with the transcript never appearing -- verified by
  // hand for this task (see the task's own report for the revert/re-run
  // evidence) rather than re-run automatically here, since reinstating the
  // bug would require editing the shipped gl-bridge.js this test also
  // exercises for the fix. The real transcript arriving IS the proof.
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig({
    voiceStop: { text: 'delayed transcript' },
  })));
  await context.addInitScript((cfg) => {
    window.__glMock ? window.__glMock.configure(cfg) : (window.__pendingMockConfig = cfg);
  }, { delays: { voiceStop: 6000 } });
  await routeProjects(context);
  await routeRecent(context);
  const page = await newSessionPage(context);
  // __glMock exists immediately after gl-bridge.js's mock init script runs;
  // configure the delay directly rather than relying on init-script
  // ordering between the two addInitScript calls above.
  await page.evaluate(() => window.__glMock.configure({ delays: { voiceStop: 6000 } }));
  await page.click('#session-record-btn'); // start
  await page.waitForSelector('#session-record-btn.recording');
  const t0 = Date.now();
  await page.click('#session-record-btn'); // stop -> voiceStop, delayed 6s by the mock
  await page.waitForFunction(
    () => document.getElementById('session-prompt').value.indexOf('delayed transcript') !== -1,
    { timeout: 15000 }
  );
  const elapsedMs = Date.now() - t0;
  assert.ok(elapsedMs >= 5900, `expected the reply to actually wait out the 6s mock delay (took ${elapsedMs}ms)`);
  assert.equal(await page.locator('#gl-error').isHidden(), true, 'no timeout error should have fired');
  await context.close();
});

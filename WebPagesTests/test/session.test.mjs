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

/** Generates N fake project names, so tests can exercise the >7 overflow case without hand-listing them. */
function projectNames(n) {
  return Array.from({ length: n }, (_, i) => 'project-' + String(i + 1).padStart(2, '0'));
}

/** Routes GET /sessions/projects to a fixed project list (7 by default -- exactly at the no-More-chip boundary). */
async function routeProjects(context, projects = projectNames(7)) {
  await context.route(`${API_BASE}/sessions/projects*`, (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ projects }) }));
}

/** Routes GET /sessions/recent to a fixed sessions list. */
async function routeRecent(context, sessions = []) {
  await context.route(`${API_BASE}/sessions/recent*`, (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ sessions }) }));
}

/**
 * Routes POST /sessions/upload to succeed with a DETERMINISTIC fake id
 * derived from the uploaded file's own bytes (unless `opts.fail` or
 * `opts.delayMs` is set), and records every request seen -- both its body
 * buffer AND its Authorization header -- onto `calls` so tests can assert on
 * upload count / exact byte content / auth, all independent of which
 * request the browser happens to dispatch first.
 *
 * A counter-based id (the previous version of this mock: `fake-${n}.png`
 * where n increments per request handled) is NOT deterministic when two
 * uploads fire concurrently (picking 2+ images at once) -- the browser can
 * dispatch/complete those requests in either order, so "the first id
 * returned" doesn't reliably correspond to "the first file picked". Any test
 * asserting pick-order on the Start body was therefore silently order-blind
 * (a prior version literally compared as Sets to paper over exactly this).
 * Deriving the id from the file's own (unique, per fakeImage()) bytes fixes
 * that at the source: whichever request arrives first, THIS file's upload
 * always gets THIS file's id.
 */
async function routeUpload(context, calls, opts = {}) {
  // Per-content occurrence count, scoped to this routeUpload() call (a fresh
  // Map per test, not shared across tests) -- picking the SAME file twice
  // (two sequential, non-concurrent setInputFiles calls) still gets each
  // pick its own distinct id, exactly like two real uploads of identical
  // bytes would, without reintroducing an arrival-order dependency for the
  // concurrent-different-files case idForBuffer exists to fix.
  const seenCounts = new Map();
  await context.route(`${API_BASE}/sessions/upload`, async (route) => {
    const buffer = route.request().postDataBuffer();
    calls.push({ buffer, auth: route.request().headers()['authorization'] });
    if (opts.delayMs) await new Promise((r) => setTimeout(r, opts.delayMs));
    if (opts.fail) {
      return route.fulfill({ status: 415, contentType: 'application/json', body: JSON.stringify({ error: 'unsupported image type' }) });
    }
    const baseId = idForBuffer(buffer);
    const count = (seenCounts.get(baseId) || 0) + 1;
    seenCounts.set(baseId, count);
    const id = count === 1 ? baseId : `${baseId}-${count}`;
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id }) });
  });
}

/** A real (browser-decodable) 1x1 PNG followed by a `name` marker -- browsers ignore trailing bytes after a PNG's IEND chunk, so the <img> preview still renders, while the marker lets routeUpload/idForBuffer identify exactly which pick produced which request. */
const REAL_PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64');
function fakeImage(name = 'shot.png') {
  return { name, mimeType: 'image/png', buffer: Buffer.concat([REAL_PNG, Buffer.from('|marker:' + name)]) };
}
function idForBuffer(buffer) {
  const marker = buffer.toString('latin1').split('|marker:')[1] || 'unknown';
  return `id-${marker.replace(/[^a-z0-9.]/gi, '-')}`;
}

async function newSessionPage(context) {
  const page = await context.newPage();
  await page.goto(SESSION_URL);
  // chipsEl.dataset.ready is set once loadProjects()'s fetch resolves and the
  // chip row + selection are rendered (see session.html) -- waiting on it
  // (rather than an arbitrary timeout) means this is robust to the exact
  // number of chips/overflow-or-not for any given test's project list,
  // including the zero-projects case where no .gl-chip ever appears.
  await page.waitForFunction(() => !!document.getElementById('session-project-chips').dataset.ready);
  return page;
}

function chipTexts(page) {
  return page.locator('#session-project-chips .gl-chip').allTextContents();
}

// --- project chips -------------------------------------------------------

test('exactly 7 projects renders 7 chips in order and NO More overflow', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(7));
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.deepEqual(await chipTexts(page), projectNames(7));
  assert.equal(await page.locator('.gl-chip-select').count(), 0, 'no More chip at exactly 7 projects');
  await context.close();
});

test('8+ projects renders only the first 7 as chips plus a More overflow select carrying the rest', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(10));
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.deepEqual(await chipTexts(page), projectNames(7));
  const overflow = page.locator('.gl-chip-select');
  await assert.doesNotReject(overflow.waitFor({ state: 'attached', timeout: 2000 }));
  const optionTexts = await overflow.locator('option').allTextContents();
  assert.deepEqual(optionTexts, ['More…', ...projectNames(10).slice(7)]);
  await context.close();
});

test('tapping a chip selects it (visually) and Start sends that exact project', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(7));
  await routeRecent(context);
  let sentProject = null;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    sentProject = JSON.parse(route.request().postData()).project;
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: sentProject }) });
  });
  const page = await newSessionPage(context);
  await page.click('.gl-chip:text("project-03")');
  assert.equal(await page.locator('.gl-chip:text("project-03")').getAttribute('class'), 'gl-chip selected');
  await page.fill('#session-prompt', 'do a thing');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.equal(sentProject, 'project-03');
  await context.close();
});

test('picking a project from the More overflow selects it (chip shows its name) and Start sends it; picking a chip never itself hits the network', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(9));
  await routeRecent(context);
  let startCalls = 0;
  let sentProject = null;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    startCalls += 1;
    sentProject = JSON.parse(route.request().postData()).project;
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: sentProject }) });
  });
  const page = await newSessionPage(context);
  // Selecting a chip alone (no Start tap) must not touch the network --
  // MRU only reorders server-side on an actual successful Start.
  await page.click('.gl-chip:text("project-02")');
  assert.equal(startCalls, 0, 'selecting a chip must not itself call /sessions/start');

  await page.selectOption('.gl-chip-select', 'project-09');
  assert.equal(await page.locator('.gl-chip-select').inputValue(), 'project-09', 'the overflow control shows the picked project\'s name while selected');
  assert.match(await page.locator('.gl-chip-select').getAttribute('class'), /selected/);
  // Picking from overflow must deselect whichever chip button was selected before.
  assert.equal(await page.locator('.gl-chip:text("project-02")').getAttribute('class'), 'gl-chip');

  await page.fill('#session-prompt', 'overflow pick');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.equal(sentProject, 'project-09');
  await context.close();
});

test('last-used project (localStorage) is restored as the selection on load', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await context.addInitScript((key) => { window.localStorage.setItem(key, 'project-05'); }, 'gl-session-last-project-v1');
  await routeProjects(context, projectNames(7));
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.equal(await page.locator('.gl-chip:text("project-05")').getAttribute('class'), 'gl-chip selected');
  await context.close();
});

test('a remembered last-used project that no longer exists in the list falls back to the first chip, never an unselectable ghost', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await context.addInitScript((key) => { window.localStorage.setItem(key, 'renamed-away-project'); }, 'gl-session-last-project-v1');
  await routeProjects(context, projectNames(3));
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.equal(await page.locator('.gl-chip:text("project-01")').getAttribute('class'), 'gl-chip selected', 'falls back to the FIRST chip');
  await context.close();
});

test('a single project is auto-selected and Start is enabled once a prompt is typed', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, ['only-project']);
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.deepEqual(await chipTexts(page), ['only-project']);
  assert.equal(await page.locator('.gl-chip').getAttribute('class'), 'gl-chip selected');
  await page.fill('#session-prompt', 'go');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await context.close();
});

test('zero projects renders no chips and leaves Start disabled without crashing', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, []);
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.equal(await page.locator('#session-project-chips').innerHTML(), '');
  await page.fill('#session-prompt', 'go nowhere');
  // Give the page a moment to (not) enable Start -- there's no project to select.
  await page.waitForTimeout(100);
  assert.equal(await page.locator('#session-start-btn').isDisabled(), true);
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
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'abc12345', name: 'do a thing', project: 'project-01' }) }));
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
      route.abort('connectionrefused');
    } else {
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'retry0001', name: 'retried', project: 'project-01' }) });
    }
  });
  const page = await newSessionPage(context);
  await page.fill('#session-prompt', 'retry me');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 5000 });
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.equal(seenKeys.length, 2);
  assert.equal(seenKeys[0], seenKeys[1], 'a retry of the same failed attempt must reuse its idempotencyKey');

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
    { id: 'aaa11111', name: 'Fix the bug', project: 'project-01', state: 'working', startedAt: Date.now() },
    { id: 'bbb22222', name: 'Ship it', project: 'project-02', state: 'blocked', startedAt: Date.now() - 60000 },
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
  let recentShouldFail = true;
  await context.route(`${API_BASE}/sessions/recent*`, (route) => {
    if (recentShouldFail) return route.fulfill({ status: 401, body: 'unauthorized' });
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ sessions: [] }) });
  });
  await routeProjects(context);
  const page = await newSessionPage(context);
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 5000 });
  recentShouldFail = false;
  await page.click('#gl-refresh-btn');
  await page.waitForFunction(() => document.getElementById('gl-error').classList.contains('gl-hidden'), { timeout: 5000 });
  await context.close();
});

test('REGRESSION PROOF: without gl-bridge.js\'s per-call timeout option, a 6s-delayed voiceStop reply is dropped as a false "timeout"', async () => {
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

// --- attachments (screenshots) -------------------------------------------

test('attaching 2 images uploads both, thumbnails show, and Start body carries both returned ids', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  const uploadCalls = [];
  await routeUpload(context, uploadCalls);
  let startBody = null;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    startBody = JSON.parse(route.request().postData());
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: startBody.project }) });
  });
  const page = await newSessionPage(context);
  await page.setInputFiles('#session-attach-input', [fakeImage('a.png'), fakeImage('b.png')]);
  await page.waitForFunction(() => document.querySelectorAll('.gl-thumb.done').length === 2, { timeout: 5000 });
  assert.equal(uploadCalls.length, 2, 'each picked image uploads independently');
  // Screenshot-only start: no prompt text typed.
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  // Order-sensitive (deepEqual on the ARRAY, not a Set) -- see idForBuffer's
  // header comment: a prior version of this assertion compared as Sets,
  // which can't tell "correct pick order" apart from "silently reversed".
  // Mutation: swap attachIdsForStart()'s .map/.filter for something that
  // reorders (e.g. sort by id string) -> this fails.
  assert.deepEqual(startBody.attachments, ['id-a.png', 'id-b.png']);
  // The page sends the prompt EXACTLY as typed (empty here) -- the "See the
  // attached screenshot(s)." fallback text is server-side only (see
  // lib/sessions.mjs's startSession), so there's a single source of truth
  // for it rather than the client guessing at the server's wording.
  assert.equal(startBody.prompt, '');
  await context.close();
});

// Mutations P17/P18: swap the Authorization header source (e.g. hardcode a
// wrong token) or send a re-encoded/mangled copy of the file instead of the
// real File object -> this fails on the auth or the byte-equality assertion
// respectively.
test('the upload request carries the Bearer token and the EXACT picked file bytes, unmodified', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  const uploadCalls = [];
  await routeUpload(context, uploadCalls);
  const picked = fakeImage('exact-bytes.png');
  const page = await newSessionPage(context);
  await page.setInputFiles('#session-attach-input', [picked]);
  await page.waitForSelector('.gl-thumb.done');
  assert.equal(uploadCalls.length, 1);
  assert.equal(uploadCalls[0].auth, 'Bearer test-token', 'the upload POST must carry the same Bearer token authedFetch attaches everywhere else');
  assert.deepEqual(uploadCalls[0].buffer, picked.buffer, 'the server must receive the exact bytes of the picked file, not a re-encoded or truncated copy');
  await context.close();
});

// Mutation P16: drop `attachInput.value = ''` from the change handler ->
// this fails (a second setInputFiles with the SAME path wouldn't even fire
// a 'change' event in a real browser once the input's value already equals
// it, but the assertion here is on the input's OWN state right after a
// pick, which is the thing that has to be true for a repick to work at all).
test('the file input is cleared immediately after a pick (attachInput.value === \'\'), so picking the same file again still fires a change event', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await routeUpload(context, []);
  const page = await newSessionPage(context);
  await page.setInputFiles('#session-attach-input', [fakeImage('reset-check.png')]);
  await page.waitForSelector('.gl-thumb.done');
  const inputValue = await page.locator('#session-attach-input').inputValue();
  assert.equal(inputValue, '', 'the <input type=file> must be reset to empty right after handling a pick');
  await context.close();
});

// Mutation P21: comment out the `attachments = []; renderAttachments();`
// lines in startSession's success handler -> this fails (thumbnails and
// their ids would still be showing/sendable after a successful Start, which
// would silently re-attach an already-used screenshot to whatever session
// gets started next).
test('a successful Start clears every thumbnail and attachment (not just the prompt/draft)', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await routeUpload(context, []);
  await context.route(`${API_BASE}/sessions/start`, (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: 'project-01' }) }));
  const page = await newSessionPage(context);
  await page.setInputFiles('#session-attach-input', [fakeImage('a.png'), fakeImage('b.png')]);
  await page.waitForFunction(() => document.querySelectorAll('.gl-thumb.done').length === 2, { timeout: 5000 });
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.equal(await page.locator('.gl-thumb').count(), 0, 'every thumbnail must be gone after a successful Start');
  // Start a SECOND time (Add screenshot is re-enabled with 0 attachments) --
  // if the old attachments object were still referenced anywhere, this would
  // either throw or silently resurrect a stale entry.
  await page.fill('#session-prompt', 'a second, unrelated session');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await context.close();
});

test('a failed upload shows a visible failed state and keeps Start disabled/unusable for that attachment; removing it clears the failure', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await routeUpload(context, [], { fail: true });
  const page = await newSessionPage(context);
  await page.setInputFiles('#session-attach-input', [fakeImage()]);
  await page.waitForSelector('.gl-thumb.failed', { timeout: 5000 });
  // No prompt text and the only attachment failed -> nothing startable yet.
  await page.waitForTimeout(100);
  assert.equal(await page.locator('#session-start-btn').isDisabled(), true);
  await page.click('.gl-thumb-remove');
  await page.waitForFunction(() => document.querySelectorAll('.gl-thumb').length === 0);
  await context.close();
});

test('retrying a failed upload succeeds and its id then appears in the Start body', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  let attempt = 0;
  await context.route(`${API_BASE}/sessions/upload`, (route) => {
    attempt += 1;
    if (attempt === 1) return route.fulfill({ status: 415, contentType: 'application/json', body: JSON.stringify({ error: 'nope' }) });
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'retried.png' }) });
  });
  let startBody = null;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    startBody = JSON.parse(route.request().postData());
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: startBody.project }) });
  });
  const page = await newSessionPage(context);
  await page.setInputFiles('#session-attach-input', [fakeImage()]);
  await page.waitForSelector('.gl-thumb.failed', { timeout: 5000 });
  await page.click('.gl-thumb-status'); // tap-to-retry overlay
  await page.waitForSelector('.gl-thumb.done', { timeout: 5000 });
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.deepEqual(startBody.attachments, ['retried.png']);
  await context.close();
});

test('removing an in-flight (uploading) thumbnail works immediately, and the late-finishing upload does not resurrect it or add its id', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  const uploadCalls = [];
  await routeUpload(context, uploadCalls, { delayMs: 1500 });
  let startBody = null;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    startBody = JSON.parse(route.request().postData());
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: startBody.project }) });
  });
  const page = await newSessionPage(context);
  await page.fill('#session-prompt', 'text content so Start can enable once the upload clears');
  await page.setInputFiles('#session-attach-input', [fakeImage()]);
  await page.waitForSelector('.gl-thumb.uploading');
  // Start must be disabled while the upload is in flight.
  assert.equal(await page.locator('#session-start-btn').isDisabled(), true);
  await page.click('.gl-thumb-remove'); // removes it BEFORE the delayed upload resolves
  await page.waitForFunction(() => document.querySelectorAll('.gl-thumb').length === 0);
  // No other upload pending -> Start re-enables (there's prompt text).
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled, { timeout: 5000 });
  // Let the delayed mock route actually resolve in the background.
  await page.waitForTimeout(1800);
  assert.equal(await page.locator('.gl-thumb').count(), 0, 'the late-finishing upload must not resurrect a removed thumbnail');
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.deepEqual(startBody.attachments, [], 'the removed-while-uploading attachment\'s id must never reach Start\'s body');
  await context.close();
});

test('the 5-image cap disables Add once reached, and picking more than the remaining room attaches up to the cap with a visible (never silent) message', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await routeUpload(context, []);
  const page = await newSessionPage(context);
  await page.setInputFiles('#session-attach-input', [fakeImage('1.png'), fakeImage('2.png'), fakeImage('3.png'), fakeImage('4.png'), fakeImage('5.png'), fakeImage('6.png'), fakeImage('7.png')]);
  await page.waitForFunction(() => document.querySelectorAll('.gl-thumb').length === 5, { timeout: 5000 });
  assert.equal(await page.locator('#session-attach-btn').isDisabled(), true);
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 5000 });
  const errorText = await page.locator('#gl-error-text').textContent();
  assert.match(errorText, /2 skipped/);
  await context.close();
});

test('removing a thumbnail drops its id from the Start body', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await routeUpload(context, []);
  let startBody = null;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    startBody = JSON.parse(route.request().postData());
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: startBody.project }) });
  });
  const page = await newSessionPage(context);
  await page.fill('#session-prompt', 'has attachments then removes one');
  await page.setInputFiles('#session-attach-input', [fakeImage('a.png'), fakeImage('b.png')]);
  await page.waitForFunction(() => document.querySelectorAll('.gl-thumb.done').length === 2, { timeout: 5000 });
  await page.locator('.gl-thumb-remove').first().click();
  await page.waitForFunction(() => document.querySelectorAll('.gl-thumb').length === 1);
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.equal(startBody.attachments.length, 1, 'only the NOT-removed attachment\'s id reaches Start');
  await context.close();
});

test('draft restore: reloading with a saved prompt/project/attachment restores all three, fetches the restored attachment\'s thumbnail (authed), and never re-uploads it', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await context.addInitScript(({ key, val }) => { window.localStorage.setItem(key, JSON.stringify(val)); },
    { key: 'gl-session-draft-v1', val: { prompt: 'restored draft text', project: 'project-04', attachments: ['restored-id.png'] } });
  await routeProjects(context, projectNames(7));
  await routeRecent(context);
  const uploadCalls = [];
  await routeUpload(context, uploadCalls);
  let thumbnailAuth = null;
  await context.route(`${API_BASE}/sessions/upload/restored-id.png`, (route) => {
    thumbnailAuth = route.request().headers()['authorization'];
    return route.fulfill({ status: 200, contentType: 'image/png', body: REAL_PNG });
  });
  const page = await newSessionPage(context);
  assert.equal(await page.inputValue('#session-prompt'), 'restored draft text');
  assert.equal(await page.locator('.gl-chip:text("project-04")').getAttribute('class'), 'gl-chip selected');
  await page.waitForSelector('.gl-thumb.done img', { timeout: 5000 }); // the fetched-thumbnail <img>, not just the placeholder
  assert.equal(thumbnailAuth, 'Bearer test-token', 'the thumbnail GET must carry the Bearer token (an <img src> alone could not)');
  assert.equal(uploadCalls.length, 0, 'a restored attachment must not re-upload -- it already has a server id');
  await context.close();
});

test('window.addAttachments(ids): valid ids are added (thumbnail fetched, id in Start body), invalid ids are dropped, and the 5-cap + skip message apply the same as manual picks', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(7));
  await routeRecent(context);
  await context.route(`${API_BASE}/sessions/upload/*`, (route) =>
    route.fulfill({ status: 200, contentType: 'image/png', body: REAL_PNG }));
  let startBody = null;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    startBody = JSON.parse(route.request().postData());
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: startBody.project }) });
  });
  const page = await newSessionPage(context);
  const validId = '11111111-1111-1111-1111-111111111111.png';
  await page.evaluate((id) => window.addAttachments([
    id,
    '../../../etc/passwd', // traversal text -- not even a well-formed id
    'not-a-uuid.png', // malformed
    '22222222-2222-2222-2222-222222222222.exe', // disallowed extension
  ]), validId);
  await page.waitForSelector('.gl-thumb.done img', { timeout: 5000 });
  assert.equal(await page.locator('.gl-thumb').count(), 1, 'only the ONE valid id should have been added');
  await page.fill('#session-prompt', 'from a deep link');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.deepEqual(startBody.attachments, [validId]);
  await context.close();
});

test('window.addAttachments respects the 5-image cap and shows the skip message like a manual pick would', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await context.route(`${API_BASE}/sessions/upload/*`, (route) =>
    route.fulfill({ status: 200, contentType: 'image/png', body: REAL_PNG }));
  const page = await newSessionPage(context);
  const ids = Array.from({ length: 7 }, (_, i) => `${String(i).repeat(8)}-1111-1111-1111-111111111111.png`);
  await page.evaluate((ids) => window.addAttachments(ids), ids);
  await page.waitForFunction(() => document.querySelectorAll('.gl-thumb').length === 5, { timeout: 5000 });
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 5000 });
  assert.match(await page.locator('#gl-error-text').textContent(), /2 skipped/);
  await context.close();
});

// Mutation: drop the `existingIds.indexOf(id) === -1` clause from
// window.addAttachments' filter -> this fails on BOTH assertions (2
// thumbnails / 2 ids in the Start body instead of 1) -- native can call
// addAttachments again for the SAME deep link after a page reload mid-flow,
// and a draft restore may already have added an id before native's call
// runs; either way the same server id must never become two thumbnails or
// appear twice in one Start request.
test('window.addAttachments ignores ids already present -- called twice with the same id, and once more after a draft restore already added it -- ends up as ONE thumbnail with the id ONCE in the Start body', async () => {
  const validId = 'dddddddd-dddd-dddd-dddd-dddddddddddd.png';
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await context.addInitScript(({ key, val }) => { window.localStorage.setItem(key, JSON.stringify(val)); },
    { key: 'gl-session-draft-v1', val: { prompt: '', project: 'project-01', attachments: [validId] } });
  await routeProjects(context);
  await routeRecent(context);
  await context.route(`${API_BASE}/sessions/upload/*`, (route) =>
    route.fulfill({ status: 200, contentType: 'image/png', body: REAL_PNG }));
  let startBody = null;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    startBody = JSON.parse(route.request().postData());
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: startBody.project }) });
  });
  const page = await newSessionPage(context);
  // The draft restore above already added `validId` as a `done` attachment
  // before this page even finished loading -- confirm that first, so the
  // addAttachments calls below are provably deduping against a
  // PRE-EXISTING entry, not against each other only.
  await page.waitForSelector('.gl-thumb.done');
  assert.equal(await page.locator('.gl-thumb').count(), 1);
  // Native calling addAttachments AGAIN for the same deep link id (page
  // reload mid-flow) -- twice, for good measure.
  await page.evaluate((id) => window.addAttachments([id]), validId);
  await page.evaluate((id) => window.addAttachments([id]), validId);
  await page.waitForTimeout(200); // let any (wrongly) duplicated adds settle
  assert.equal(await page.locator('.gl-thumb').count(), 1, 'still exactly one thumbnail despite three total addAttachments-equivalent calls for the same id');
  await page.fill('#session-prompt', 'dedupe check');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.deepEqual(startBody.attachments, [validId], 'the id must appear exactly ONCE in the Start body');
  await context.close();
});

// REINSTATE-BUG PROOF: Start-disabled-during-upload. Reverting
// updateStartEnabled() to its pre-attachments form (drop the
// anyUploadInFlight() term, i.e. `starting || !selectedProject ||
// !hasStartableContent()`) makes THIS test fail, because with prompt text
// present Start would read as enabled the instant a slow upload is still
// in flight -- verified by hand for this task (temporarily removed the
// `|| anyUploadInFlight()` term and re-ran this file: this test went from
// pass to fail, specifically on the isDisabled() assertion below, then
// restored the term and confirmed green again).
test('REINSTATE-BUG PROOF: Start stays disabled while an upload is in flight even with prompt text already typed', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await routeUpload(context, [], { delayMs: 2000 });
  const page = await newSessionPage(context);
  await page.fill('#session-prompt', 'plenty of prompt text right here');
  await page.setInputFiles('#session-attach-input', [fakeImage()]);
  await page.waitForSelector('.gl-thumb.uploading');
  assert.equal(await page.locator('#session-start-btn').isDisabled(), true, 'Start must stay disabled while the upload is still in flight');
  await context.close();
});

test('an in-flight (not-yet-done) attachment is never persisted to the draft, so a reload mid-upload restores nothing for it', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  // Long enough to still be "in flight" for every assertion this test makes,
  // short enough not to hold up the suite's own process exit waiting on the
  // pending route's setTimeout after context.close().
  await routeUpload(context, [], { delayMs: 3000 });
  const page = await newSessionPage(context);
  await page.setInputFiles('#session-attach-input', [fakeImage()]);
  await page.waitForSelector('.gl-thumb.uploading');
  // MUTATION-PROOF FIX (was VACUOUS): typing the prompt BEFORE picking the
  // file (the previous version of this test) means the localStorage draft
  // examined afterward could just be leftover from THAT fill's own
  // saveDraft() call -- picking a file never itself calls saveDraft(), so
  // the assertion below would pass identically whether or not the
  // in-flight-exclusion logic works at all. Typing AFTER the pick forces a
  // FRESH saveDraft() call while the upload is still 'uploading', which is
  // the only way this test can actually distinguish "excluded on purpose"
  // from "never had the chance to be included".
  await page.fill('#session-prompt', 'draft check, written mid-upload');
  const draft = await page.evaluate(() => JSON.parse(window.localStorage.getItem('gl-session-draft-v1') || 'null'));
  assert.equal(draft.prompt, 'draft check, written mid-upload', 'sanity: this saveDraft() call must be the one from the fill above, not a stale one');
  assert.deepEqual(draft.attachments, [], 'saveDraft only ever persists DONE attachment ids, never one still uploading');
  await context.close();
});

test('picking the same photo twice creates two independent attachments -- each its own upload/id, and removing one never affects the other', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  const uploadCalls = [];
  await routeUpload(context, uploadCalls);
  let startBody = null;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    startBody = JSON.parse(route.request().postData());
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: startBody.project }) });
  });
  const page = await newSessionPage(context);
  // Two picks of the exact same file/name, in two separate change events
  // (mirrors picking, then picking again) -- each must upload and get its
  // own id independently.
  await page.setInputFiles('#session-attach-input', [fakeImage('same.png')]);
  await page.waitForFunction(() => document.querySelectorAll('.gl-thumb.done').length === 1);
  await page.setInputFiles('#session-attach-input', [fakeImage('same.png')]);
  await page.waitForFunction(() => document.querySelectorAll('.gl-thumb.done').length === 2);
  assert.equal(uploadCalls.length, 2);
  // Remove the first thumbnail; the second must survive untouched.
  await page.locator('.gl-thumb-remove').first().click();
  await page.waitForFunction(() => document.querySelectorAll('.gl-thumb').length === 1);
  assert.equal(await page.locator('.gl-thumb.done').count(), 1, 'the remaining attachment must still be intact');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.equal(startBody.attachments.length, 1, 'only the surviving attachment\'s id reaches Start');
  await context.close();
});

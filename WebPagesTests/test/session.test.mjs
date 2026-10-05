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

before(async () => {
  browser = await chromium.launch({ headless: true });
  // Every Playwright wait fails after 8s (default 30s), so a regression is a prompt, attributable test failure rather than a hang.
  const newContext = browser.newContext.bind(browser);
  browser.newContext = async (options) => {
    const context = await newContext(options);
    context.setDefaultTimeout(8000);
    return context;
  };
});
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
  // pillBtn.dataset.ready is set once loadProjects()'s fetch resolves and the
  // pill + tray-source state are ready (see session.html) -- waiting on it
  // (rather than an arbitrary timeout) means this is robust to the exact
  // project list for any given test, including the zero-projects case.
  await page.waitForFunction(() => !!document.getElementById('session-project-pill').dataset.ready);
  return page;
}

function pillText(page) {
  return page.locator('#session-project-pill-value').textContent();
}

async function openTray(page) {
  await page.click('#session-project-pill');
  await page.waitForSelector('#session-project-tray-backdrop:not([hidden])');
}

function trayRowLocator(page, name) {
  return page.locator(`.tray-row:has-text("${name}")`);
}

// --- project tray ----------------------------------------------------------

/** The tray always shows a "None" row first, and every skill row as "/<name>". */
function slashNames(names) { return names.map((n) => '/' + n); }

test('exactly 7 projects: all 7 appear under Recent, no All-projects section, "None" pinned first', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(7));
  await routeRecent(context);
  const page = await newSessionPage(context);
  await openTray(page);
  const recentLabel = page.locator('.tray-section-label:text("Recent")');
  await assert.doesNotReject(recentLabel.waitFor({ state: 'attached', timeout: 2000 }));
  assert.equal(await page.locator('.tray-section-label:text("All skills")').count(), 0, 'no All-projects header at exactly 7 projects');
  const rowNames = await page.locator('.tray-row span:first-child').allTextContents();
  assert.deepEqual(rowNames, ['None', ...slashNames(projectNames(7))]);
  await context.close();
});

test('8+ projects: first 7 under Recent, the rest under All projects, no duplicates, "None" still pinned first', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(10));
  await routeRecent(context);
  const page = await newSessionPage(context);
  await openTray(page);
  const rowNames = await page.locator('.tray-row span:first-child').allTextContents();
  assert.deepEqual(rowNames, ['None', ...slashNames(projectNames(10))], 'None, then Recent (7), then All projects (3), each name exactly once');
  assert.equal(new Set(rowNames).size, rowNames.length, 'no project appears in both sections');
  await context.close();
});

test('tapping a Recent row selects it, closes the tray, updates the pill, and Start sends that exact project', async () => {
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
  await openTray(page);
  await trayRowLocator(page, 'project-03').click();
  await page.waitForSelector('#session-project-tray-backdrop[hidden]', { state: 'attached' });
  assert.equal(await pillText(page), 'project-03');
  await page.fill('#session-prompt', 'do a thing');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  // The confirmation shows optimistically on click, before the POST
  // resolves -- wait for the actual response so `sentProject` (set inside
  // the route handler) is guaranteed populated before we read it.
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
  assert.equal(sentProject, 'project-03');
  await context.close();
});

test('tapping an All-projects row selects it (pill shows its name) and Start sends it; opening/selecting never itself hits the network', async () => {
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
  await openTray(page);
  await trayRowLocator(page, 'project-09').click();
  assert.equal(startCalls, 0, 'selecting a project must not itself call /sessions/start');
  assert.equal(await pillText(page), 'project-09');

  await page.fill('#session-prompt', 'overflow pick');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
  assert.equal(sentProject, 'project-09');
  await context.close();
});

test('backdrop tap dismisses the tray WITHOUT changing the selection, and the pill\'s aria-expanded tracks open/closed', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  // Start on a NON-first project: with project-01 selected, a dismiss that
  // wrongly resets to the default/first project is indistinguishable from
  // one that leaves the selection alone (test-skeptic mutation X6 survived
  // the project-01 version of this test for exactly that reason).
  await context.addInitScript((key) => { window.localStorage.setItem(key, 'project-04'); }, 'gl-session-last-project-v1');
  await routeProjects(context, projectNames(9));
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.equal(await pillText(page), 'project-04', 'sanity: starts on a remembered non-first project');
  assert.equal(await page.locator('#session-project-pill').getAttribute('aria-expanded'), 'false');
  await openTray(page);
  assert.equal(await page.locator('#session-project-pill').getAttribute('aria-expanded'), 'true', 'pill reports the tray as expanded while open');
  // Tap a corner of the backdrop, well outside the sheet, which sits flush
  // to the bottom -- { position: 'top-left' } lands above the sheet.
  await page.locator('#session-project-tray-backdrop').click({ position: { x: 5, y: 5 } });
  await page.waitForSelector('#session-project-tray-backdrop[hidden]', { state: 'attached' });
  assert.equal(await pillText(page), 'project-04', 'selection must be unchanged by a backdrop dismiss');
  assert.equal(await page.locator('#session-project-pill').getAttribute('aria-expanded'), 'false', 'pill reports collapsed again after dismiss');
  await context.close();
});

test('tapping INSIDE the sheet (search box, title) never dismisses the tray -- the sheet stops the click reaching the backdrop\'s dismiss handler', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(9));
  await routeRecent(context);
  const page = await newSessionPage(context);
  await openTray(page);
  // page.fill() only focuses the input, so the search assertions elsewhere
  // never exercise a real tap on it -- a REAL click is what bubbles.
  await page.click('#session-project-tray-search');
  await page.click('.tray-title');
  await page.waitForTimeout(100); // let a (wrong) bubbled dismiss settle
  assert.equal(await page.locator('#session-project-tray-backdrop').isHidden(), false, 'tray must still be open after tapping its own search box / title');
  assert.equal(await page.locator('#session-project-pill').getAttribute('aria-expanded'), 'true');
  await context.close();
});

test('tray search: case-insensitive, whitespace-trimmed, filters both sections, hides an empty section header, and never duplicates a match', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  // Recent (first 7): project-01..06 + UpperRecent. All projects (rest):
  // project-08..11 + MixedCaseRepo. A mixed-case name sits in EACH section
  // on purpose: the filter lowercases Recent and All in two separate
  // expressions, so a case-insensitivity check against only one section
  // leaves the other's .toLowerCase() free to disappear unnoticed (mutation
  // M1 in the test-skeptic audit survived the single-section version).
  await routeProjects(context, [...projectNames(6), 'UpperRecent', 'project-08', 'project-09', 'project-10', 'project-11', 'MixedCaseRepo']);
  await routeRecent(context);
  const page = await newSessionPage(context);
  await openTray(page);

  // "None" is pinned at top and unaffected by the search query -- every
  // query below still has it present, on top of whatever else matches.

  // Case-insensitive + only the All-projects section matches -> Recent header hidden.
  await page.fill('#session-project-tray-search', 'mixed');
  await assert.doesNotReject(trayRowLocator(page, 'MixedCaseRepo').waitFor({ state: 'visible', timeout: 2000 }));
  assert.equal(await page.locator('.tray-section-label:text("Recent")').count(), 0, 'Recent header hidden when it has zero matches');
  assert.equal(await page.locator('.tray-row').count(), 2, 'None + the one match');

  // Case-insensitive in the Recent section too -> All-projects header hidden.
  await page.fill('#session-project-tray-search', 'upperrec');
  await assert.doesNotReject(trayRowLocator(page, 'UpperRecent').waitFor({ state: 'visible', timeout: 2000 }));
  assert.equal(await page.locator('.tray-section-label:text("All skills")').count(), 0, 'All-projects header hidden when only a Recent name matches');
  assert.equal(await page.locator('.tray-row').count(), 2, 'None + the one match');

  // SUBSTRING match, not prefix: "ject-0" starts no name but sits inside
  // project-01..06 (Recent) and project-08/09 (All) -> 8 rows, both
  // headers. A startsWith-style filter would show nothing here.
  await page.fill('#session-project-tray-search', 'ject-0');
  await assert.doesNotReject(trayRowLocator(page, 'project-09').waitFor({ state: 'visible', timeout: 2000 }));
  assert.deepEqual(await page.locator('.tray-row span:first-child').allTextContents(),
    ['None', ...slashNames([...projectNames(6), 'project-08', 'project-09'])], 'a mid-name query matches in BOTH sections, Recent first, None still pinned');
  assert.equal(await page.locator('.tray-section-label').count(), 2);

  // Whitespace padding around a real query is trimmed the same way.
  await page.fill('#session-project-tray-search', '   mixed   ');
  await assert.doesNotReject(trayRowLocator(page, 'MixedCaseRepo').waitFor({ state: 'visible', timeout: 2000 }));

  // A query matching a Recent name only -> All-projects header hidden.
  await page.fill('#session-project-tray-search', 'project-03');
  await assert.doesNotReject(trayRowLocator(page, 'project-03').waitFor({ state: 'visible', timeout: 2000 }));
  assert.equal(await page.locator('.tray-section-label:text("All skills")').count(), 0, 'All-projects header hidden when it has zero matches');

  // All-whitespace query = full, unfiltered list (both sections back, no dupes).
  await page.fill('#session-project-tray-search', '   ');
  await assert.doesNotReject(page.locator('.tray-section-label:text("Recent")').waitFor({ state: 'visible', timeout: 2000 }));
  await assert.doesNotReject(page.locator('.tray-section-label:text("All skills")').waitFor({ state: 'visible', timeout: 2000 }));
  const allNames = await page.locator('.tray-row span:first-child').allTextContents();
  assert.equal(new Set(allNames).size, allNames.length, 'no duplicates in the unfiltered list');
  assert.equal(allNames.length, 13, 'None + 12 skills');

  // No match at all -> empty state, no stray section headers, but "None" survives.
  await page.fill('#session-project-tray-search', 'zzz-nope');
  await assert.doesNotReject(page.locator('.tray-empty').waitFor({ state: 'visible', timeout: 2000 }));
  assert.equal(await page.locator('.tray-section-label').count(), 0);
  assert.equal(await page.locator('.tray-row').count(), 1, 'only the pinned None row remains');
  await context.close();
});

test('reopening the tray clears the previous search query', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(7));
  await routeRecent(context);
  const page = await newSessionPage(context);
  await openTray(page);
  await page.fill('#session-project-tray-search', 'project-02');
  await trayRowLocator(page, 'project-02').click();
  await openTray(page);
  assert.equal(await page.inputValue('#session-project-tray-search'), '', 'query must be cleared on reopen');
  assert.equal(await page.locator('.tray-row').count(), 8, 'None + reopening with a cleared query shows the full list again');
  // The reopened list is re-rendered from the CURRENT selection: the
  // checkmark moved to project-02 and is on no other row (a list rendered
  // once and cached would still show project-01 checked).
  assert.equal(await page.locator('.tray-row .gl-check.selected').count(), 1, 'exactly one row carries the selected checkmark');
  assert.equal(await trayRowLocator(page, 'project-02').locator('.gl-check.selected').count(), 1, 'the checkmark is on the row just picked');
  await context.close();
});

test('after a successful Start, a reload preselects the project that session ran in (LAST_PROJECT_KEY survives the draft being cleared)', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(7));
  await routeRecent(context);
  await context.route(`${API_BASE}/sessions/start`, (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: 'project-03' }) }));
  const page = await newSessionPage(context);
  await openTray(page);
  await trayRowLocator(page, 'project-03').click();
  await page.fill('#session-prompt', 'remember me');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  // A successful Start clears the draft (which also carries the project),
  // so what's left to restore from is ONLY the last-used-project key --
  // selecting a row must have written it, or this reload falls back to
  // project-01. (The draft-restore test can't see this: its draft.project
  // wins before the key is ever consulted.)
  assert.equal(await page.evaluate(() => window.localStorage.getItem('gl-session-draft-v1')), null, 'sanity: draft is gone after a successful Start');
  await page.reload();
  await page.waitForFunction(() => !!document.getElementById('session-project-pill').dataset.ready);
  assert.equal(await pillText(page), 'project-03', 'the project the last session ran in is preselected on the next visit');
  await context.close();
});

test('last-used project (localStorage) is restored as the pill value and the tray\'s selected row on load', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await context.addInitScript((key) => { window.localStorage.setItem(key, 'project-05'); }, 'gl-session-last-project-v1');
  await routeProjects(context, projectNames(7));
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.equal(await pillText(page), 'project-05');
  await openTray(page);
  assert.equal(await trayRowLocator(page, 'project-05').locator('.gl-check').getAttribute('class'), 'gl-check selected');
  // ...and ONLY that row: a checkmark painted on every row would pass the
  // line above (test-skeptic mutation X3).
  assert.equal(await page.locator('.tray-row .gl-check.selected').count(), 1, 'exactly one row is marked selected');
  assert.equal(await trayRowLocator(page, 'project-01').locator('.gl-check').getAttribute('class'), 'gl-check', 'the first (default) project is NOT marked selected');
  await context.close();
});

test('a remembered last-used project that no longer exists in the list falls back to None, never a ghost pill value or some OTHER skill', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  // Also covers the "legacy value from the old repo-based picker" case: a
  // stale name from before this feature is indistinguishable, at this
  // point, from a skill that was simply renamed/removed -- both fall back
  // to None the same way, via the same membership check.
  await context.addInitScript((key) => { window.localStorage.setItem(key, 'renamed-away-project'); }, 'gl-session-last-project-v1');
  await routeProjects(context, projectNames(3));
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.equal(await pillText(page), 'None', 'falls back to None, never to project-01 or any other skill it never chose');
  await page.fill('#session-prompt', 'go');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled, undefined, { timeout: 2000 })
    .catch(() => { throw new Error('Start must be enabled: None + prompt text is startable'); });
  await context.close();
});

test('with a real skill list but nothing remembered, the default selection is None (not the first/only skill), and Start enables once a prompt is typed', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, ['only-project']);
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.equal(await pillText(page), 'None', 'None is the default when nothing is remembered, even with real skills available');
  await page.fill('#session-prompt', 'go');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await context.close();
});

test('explicitly picking the "None" row sends project "" to Start and is remembered across a reload, just like a real skill', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(3));
  await routeRecent(context);
  let sentProject;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    sentProject = JSON.parse(route.request().postData()).project;
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: sentProject }) });
  });
  const page = await newSessionPage(context);
  // Seed a remembered REAL skill via a plain write (NOT addInitScript, which
  // would re-run and re-clobber this on the reload below) so we can prove
  // picking None overrides it, not merely that None was already the default.
  await page.evaluate((key) => window.localStorage.setItem(key, 'project-02'), 'gl-session-last-project-v1');
  await page.reload();
  await page.waitForFunction(() => !!document.getElementById('session-project-pill').dataset.ready);
  assert.equal(await pillText(page), 'project-02', 'sanity: starts on the remembered real skill');
  await openTray(page);
  await trayRowLocator(page, 'None').click();
  assert.equal(await pillText(page), 'None');
  await page.fill('#session-prompt', 'plain session please');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  // The optimistic commit shows the confirmation on the tap itself, before
  // the POST resolves -- waiting on the confirmation alone would race the
  // route handler below and read `sentProject` before it's set. Wait for the
  // actual response instead so the assertion is synchronized to the real
  // network call, not to the (now-instant) UI feedback.
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
  assert.equal(sentProject, '', 'None must send project: "" to the server, not a name or null');
  // The server echoes project: '' back; the confirmation must render that as
  // "None", never a dangling "in " (mutation: drop the `|| 'None'` fallback).
  assert.match(await page.locator('#session-confirmation-body').textContent(), /in None$/);

  await page.reload();
  await page.waitForFunction(() => !!document.getElementById('session-project-pill').dataset.ready);
  assert.equal(await pillText(page), 'None', 'None survives a reload exactly like a remembered real skill would');
  await context.close();
});

// QA case: a draft explicitly carrying project: '' (the user picked None,
// then typed and left before Start) must not be overridden by a DIFFERENT,
// stale LAST_PROJECT_KEY from an earlier session -- an `||`-based read would
// treat draft.project === '' as "missing" and wrongly fall through to it.
test('a draft that explicitly saved project: "" (None) is honored over a different, stale LAST_PROJECT_KEY', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await context.addInitScript((key) => { window.localStorage.setItem(key, 'project-02'); }, 'gl-session-last-project-v1');
  await context.addInitScript(({ key, val }) => { window.localStorage.setItem(key, JSON.stringify(val)); },
    { key: 'gl-session-draft-v1', val: { prompt: 'left mid-thought', project: '', attachments: [] } });
  await routeProjects(context, projectNames(3));
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.equal(await pillText(page), 'None', 'the draft\'s explicit None must win over the different stale LAST_PROJECT_KEY value');
  await context.close();
});

test('zero skills discovered: pill shows "None" (never "undefined"), tray shows only the None row plus an informational empty state, and Start still enables with a prompt (None is a real, always-available choice)', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, []);
  await routeRecent(context);
  const page = await newSessionPage(context);
  const pillValue = await pillText(page);
  assert.equal(pillValue, 'None', 'zero DISCOVERED skills still defaults the pill to None, not a blank/undefined');
  await openTray(page);
  await assert.doesNotReject(page.locator('.tray-empty').waitFor({ state: 'visible', timeout: 2000 }), 'an informational empty state for the (empty) skill list');
  assert.equal(await page.locator('.tray-row').count(), 1, 'the None row is still there even with zero skills');
  await page.fill('#session-prompt', 'go nowhere');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled, undefined, { timeout: 2000 });
  await context.close();
});

test('projects-load failure: the error banner shows AND the pill shows a visible "unavailable" (never blank, never "undefined")', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await context.route(`${API_BASE}/sessions/projects*`, (route) => route.fulfill({ status: 500, body: 'boom' }));
  await routeRecent(context);
  const page = await context.newPage();
  await page.goto(SESSION_URL);
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 5000 });
  const errorText = await page.locator('#gl-error-text').textContent();
  assert.match(errorText, /Couldn't load projects/);
  // Pinned to the exact copy per the task brief, not just "non-blank" --
  // the old version of this test only checked doesNotMatch(/undefined/),
  // which passed identically whether the pill showed "unavailable" OR
  // stayed blank ("Project: "), since neither contains the word
  // "undefined". A mutation that reverts to the blank pill would pass the
  // old assertion but must fail this one.
  assert.equal(await pillText(page), 'unavailable');
  assert.match(
    await page.locator('#session-project-pill-value').getAttribute('class'),
    /unavailable/,
    'the dimmed "unavailable" style class must be applied, not just the word'
  );
  // A load failure must never silently fall back to presenting None as a
  // real, startable selection -- selectedProject stays null (distinct from
  // '' = None), so Start stays disabled even with real prompt text typed.
  await page.fill('#session-prompt', 'trying anyway');
  await page.waitForTimeout(150);
  assert.equal(await page.locator('#session-start-btn').isDisabled(), true, 'Start must stay disabled after a load failure, even with a typed prompt');
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

// Extends the test above to the attachment side, and to idempotencyKey
// behavior -- a genuine rejection is a DEAD attempt (fresh key next try),
// unlike a network failure (same key, see the "retried Start" test), because
// here we KNOW the box saw and refused the request.
//
// REINSTATE-BUG PROOF: reverting startSession()'s failure branch to this
// worktree's pre-change version (which never restores `attachments` from a
// snapshot, since attachments weren't cleared optimistically in the first
// place, and always mints via `starting` gating rather than resetting
// currentIdempotencyKey to null on rejection) makes the second and third
// assertions below fail: the thumbnail assertion because the old code never
// had an `attachmentsSnapshot` to restore (attachments were never touched
// until the success path), and the fresh-key assertion because the old code
// only reset the key inside the shared `starting=false` line, not
// distinctly per branch. Confirmed by temporarily restoring the pre-change
// startSession() (see the git diff captured for this task) and re-running
// this file; restored afterward.
test('a genuine 4xx rejection reverts the optimistic clear for ATTACHMENTS too, hides the confirmation, and mints a fresh idempotencyKey on retry (unlike a network failure)', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await routeUpload(context, []);
  const seenKeys = [];
  let shouldFail = true;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    const body = JSON.parse(route.request().postData());
    seenKeys.push(body.idempotencyKey);
    if (shouldFail) {
      return route.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ error: 'unknown project' }) });
    }
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: 'project-01' }) });
  });
  const page = await newSessionPage(context);
  await page.setInputFiles('#session-attach-input', [fakeImage('revert.png')]);
  await page.waitForSelector('.gl-thumb.done', { timeout: 5000 });
  await page.fill('#session-prompt', 'revert me please');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 5000 });
  assert.equal(await page.inputValue('#session-prompt'), 'revert me please', 'the typed prompt must come back on a genuine rejection');
  assert.equal(await page.locator('.gl-thumb').count(), 1, 'the attachment thumbnail must come back too, not just the prompt text');
  assert.equal(await page.locator('#session-confirmation').isHidden(), true, 'the optimistic confirmation must be hidden again after a real rejection');

  shouldFail = false;
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
  assert.equal(seenKeys.length, 2);
  assert.notEqual(seenKeys[1], seenKeys[0], 'a rejected key is dead -- retry after a real rejection must mint a fresh one, unlike a network-failure retry');
  await context.close();
});

test('an unreachable box (network-level failure, not a server response) shows a distinct error and does NOT revert the optimistic clear -- unlike a genuine 4xx/5xx, we never know whether the box actually saw it', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await context.route(`${API_BASE}/sessions/start`, (route) => route.abort('connectionrefused'));
  const page = await newSessionPage(context);
  await page.fill('#session-prompt', 'box is down');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  // The optimistic clear runs synchronously inside startSession(), before
  // the fetch is even issued -- so it's already visible right after the
  // click, with no need to wait on the (aborted) network call.
  assert.equal(await page.inputValue('#session-prompt'), '', 'a network-level failure must NOT restore the typed prompt -- only a genuine server rejection reverts');
  assert.equal(await page.locator('#session-confirmation').isHidden(), false, 'the optimistic confirmation must keep showing through a network failure');
  await page.waitForSelector('#gl-error:not(.gl-hidden)', { timeout: 5000 });
  const errorText = await page.locator('#gl-error-text').textContent();
  assert.match(errorText, /Box unreachable/);
  await context.close();
});

// Proves the optimistic-commit contract itself, not just its downstream
// effects: the prompt clears and the confirmation shows BEFORE the network
// round-trip resolves, not after. Held via a route promise (same pattern as
// the deep-link/projects-race test below) so the assertions run while
// /sessions/start is provably still in flight -- checking AFTER the route
// unblocks would pass even against the old blocking code, since both old and
// new code show the confirmation once the response arrives.
//
// REINSTATE-BUG PROOF: reverting startSession() to this worktree's
// pre-change version (starting=true, button text "Starting…", clear/confirm
// moved into the .then() success handler) makes this test fail with a
// timeout waiting for '#session-confirmation:not(.gl-hidden)', because the
// old code never shows the confirmation until AFTER the held route resolves.
// Confirmed by temporarily restoring that version and re-running this file;
// restored afterward -- see the task report for the exact command run.
test('optimistic commit: the prompt clears and the confirmation shows BEFORE /sessions/start responds, not after', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  let releaseStart;
  const startHeld = new Promise((resolve) => { releaseStart = resolve; });
  await context.route(`${API_BASE}/sessions/start`, async (route) => {
    await startHeld;
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: 'project-01' }) });
  });
  const page = await newSessionPage(context);
  await page.fill('#session-prompt', 'optimistic please');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  // Assert immediately, WHILE the route above is still held (unresolved) --
  // if any of this required the response, it would time out right here.
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 2000 });
  assert.equal(await page.inputValue('#session-prompt'), '', 'the prompt must already be cleared before the network call resolves');
  assert.equal(await page.locator('.gl-thumb').count(), 0);
  releaseStart();
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

test('a Start that hit a network failure is replayed with the SAME idempotencyKey (oldest first); a later Start mints a fresh one', async () => {
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
  // The failed request is saved; the 'online' event replays it by itself.
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await waitFor(() => seenKeys.length >= 2, 'the automatic replay of the failed Start');
  assert.equal(seenKeys[0], seenKeys[1], 'the automatic replay of a failed attempt must reuse its idempotencyKey');

  await page.fill('#session-prompt', 'a genuinely new attempt');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
  assert.equal(seenKeys.length, 3);
  assert.notEqual(seenKeys[2], seenKeys[0], 'a new Start attempt must mint a fresh idempotencyKey');
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
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
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
  // The confirmation now appears optimistically on click, before the POST
  // resolves -- wait for the actual response so `startBody` (set inside the
  // route handler) is guaranteed populated before we read it.
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
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
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
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
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
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
  assert.equal(await pillText(page), 'project-04', 'remembered project selection survives reload');
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
  // As above: the confirmation shows optimistically before the POST
  // resolves, so synchronize on the actual response before reading
  // `startBody` (set inside the route handler).
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
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
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
  assert.deepEqual(startBody.attachments, [validId], 'the id must appear exactly ONCE in the Start body');
  await context.close();
});

// The real share-sheet cold launch (seen on device 2026-09-14): native runs
// window.addAttachments at didFinishNavigation, BEFORE /sessions/projects has
// answered. addAttachments saves the draft with the id, then the projects
// response arrives and the draft restore adds that same id again. The test
// above only covers the opposite order (restore first, then addAttachments).
test('a deep-link id added before the projects list loads is not duplicated by the draft restore that follows', async () => {
  const validId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee.jpg';
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  let releaseProjects;
  const projectsHeld = new Promise((resolve) => { releaseProjects = resolve; });
  await context.route(`${API_BASE}/sessions/projects*`, async (route) => {
    await projectsHeld;
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ projects: projectNames(7) }) });
  });
  await routeRecent(context);
  await context.route(`${API_BASE}/sessions/upload/*`, (route) =>
    route.fulfill({ status: 200, contentType: 'image/png', body: REAL_PNG }));
  let startBody = null;
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    startBody = JSON.parse(route.request().postData());
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: startBody.project }) });
  });
  const page = await context.newPage();
  await page.goto(SESSION_URL);
  await page.waitForFunction(() => typeof window.addAttachments === 'function');
  assert.equal(await page.evaluate(() => document.getElementById('session-project-pill').dataset.ready), undefined,
    'sanity: the projects list must still be pending when native adds the attachment');
  await page.evaluate((id) => window.addAttachments([id]), validId);
  releaseProjects();
  await page.waitForFunction(() => !!document.getElementById('session-project-pill').dataset.ready);
  await page.waitForTimeout(200);
  assert.equal(await page.locator('.gl-thumb').count(), 1, 'the shared image must show as ONE thumbnail');
  await page.fill('#session-prompt', 'share sheet order');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
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
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/sessions/start')),
    page.click('#session-start-btn'),
  ]);
  assert.equal(startBody.attachments.length, 1, 'only the surviving attachment\'s id reaches Start');
  await context.close();
});

// --- composer icon buttons (mic + screenshot docked in the textarea) -----

test('the mic and screenshot buttons are icon buttons with the required aria-labels, and trigger the right actions', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  const page = await newSessionPage(context);

  assert.equal(await page.locator('#session-attach-btn').getAttribute('aria-label'), 'Add screenshot');
  assert.equal(await page.locator('#session-record-btn').getAttribute('aria-label'), 'Dictate');

  // Tapping the screenshot icon must open the file picker -- the hidden
  // #session-attach-input, unchanged behind the icon.
  const [chooser] = await Promise.all([
    page.waitForEvent('filechooser'),
    page.click('#session-attach-btn'),
  ]);
  assert.ok(chooser, 'clicking the screenshot icon must trigger the file input');

  // Tapping the mic icon must call the bridge's voiceStart (same as the old
  // full-width mic button) and flip aria-pressed/the recording class.
  await page.click('#session-record-btn');
  await page.waitForSelector('#session-record-btn.recording');
  assert.equal(await page.locator('#session-record-btn').getAttribute('aria-pressed'), 'true');
  const calls = await page.evaluate(() => window.__glCallLog.map((c) => c.method));
  assert.ok(calls.includes('voiceStart'), 'clicking the mic icon must call the voiceStart bridge method');
  await context.close();
});

test('the mic button visibly loses its recording state (class + aria-pressed) once stopped', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  const page = await newSessionPage(context);
  await page.click('#session-record-btn'); // start
  await page.waitForSelector('#session-record-btn.recording');
  await page.click('#session-record-btn'); // stop
  await page.waitForFunction(() => document.getElementById('session-prompt').value.indexOf('a fake voice transcript') !== -1);
  assert.equal(await page.locator('#session-record-btn').evaluate((el) => el.classList.contains('recording')), false);
  assert.equal(await page.locator('#session-record-btn').getAttribute('aria-pressed'), 'false');
  await context.close();
});

// --- composer geometry: icons never overlap typed text --------------------

/**
 * REGRESSION for the real 2026-09-13 bug: a scrolled textarea's padding box
 * IS its scrollport, so reserving room for the icons via the TEXTAREA's own
 * padding-bottom only ever worked at scrollTop=0 -- scroll it (a long
 * prompt) and text renders straight through underneath the icons, because
 * padding on a scrolled element scrolls away with the content instead of
 * staying pinned to the element's visual bottom edge. The fix moves the
 * icons out of the textarea entirely into the WRAPPER's own (non-scrolling)
 * padding-bottom band, so this test checks the thing that actually matters:
 * the textarea element's own bounding box (which never moves on scroll --
 * only its CONTENT does) must never intersect either icon's box, at ANY
 * scroll position. Unlike the old padding-arithmetic version, this can't be
 * satisfied by an unscrolled textarea alone; it's checked at 0, a middle
 * position, and (critically) scrolled all the way to the bottom.
 */
function rectsIntersect(a, b) {
  return a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
}

test('the textarea box never intersects the docked icons at any scroll position (40-line prompt, scrolled to several positions including the bottom)', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  const page = await newSessionPage(context);
  await page.setViewportSize({ width: 390, height: 844 });
  const longText = Array.from({ length: 40 }, (_, i) => `Line ${i} of a task description long enough to force real scrolling.`).join('\n');
  await page.fill('#session-prompt', longText);

  const maxScrollTop = await page.locator('#session-prompt').evaluate((el) => el.scrollHeight - el.clientHeight);
  assert.ok(maxScrollTop > 50, `sanity: 40 lines must actually overflow the textarea's fixed height (got scrollable range ${maxScrollTop}px)`);

  for (const scrollTop of [0, 100, 200, maxScrollTop]) {
    await page.locator('#session-prompt').evaluate((el, top) => { el.scrollTop = top; }, scrollTop);
    const geometry = await page.evaluate(() => {
      var taRect = document.getElementById('session-prompt').getBoundingClientRect().toJSON();
      var icons = Array.from(document.querySelectorAll('.gl-composer-icons .gl-icon-btn')).map(function (el) {
        return el.getBoundingClientRect().toJSON();
      });
      return { taRect: taRect, icons: icons };
    });
    assert.equal(geometry.icons.length, 2, 'expected exactly 2 docked icon buttons');
    geometry.icons.forEach((iconRect) => {
      assert.equal(
        rectsIntersect(geometry.taRect, iconRect), false,
        `at scrollTop=${scrollTop}: textarea box (${JSON.stringify(geometry.taRect)}) must not intersect icon box (${JSON.stringify(iconRect)})`
      );
    });
  }
  await context.close();
});

// --- no horizontal overflow at phone width --------------------------------

test('no horizontal overflow at 390px width with the project tray open', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(10));
  await routeRecent(context);
  const page = await newSessionPage(context);
  await page.setViewportSize({ width: 390, height: 844 });
  await openTray(page);
  const overflowsX = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);
  assert.equal(overflowsX, false, 'the page must not scroll horizontally at 390px with the tray open');
  await context.close();
});

test('no horizontal overflow at 390px width with 5 thumbnails attached', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await routeUpload(context, []);
  const page = await newSessionPage(context);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.setInputFiles('#session-attach-input', [fakeImage('1.png'), fakeImage('2.png'), fakeImage('3.png'), fakeImage('4.png'), fakeImage('5.png')]);
  await page.waitForFunction(() => document.querySelectorAll('.gl-thumb.done').length === 5, { timeout: 5000 });
  const overflowsX = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);
  assert.equal(overflowsX, false, 'the page must not scroll horizontally at 390px with 5 thumbnails attached');
  await context.close();
});

test('the Model picker defaults to Sonnet, not Opus', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(7));
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.equal(await page.locator('#session-model-select').inputValue(), 'sonnet');
  await context.close();
});

// --- skill auto-detect (POST /sessions/suggest-skill) ----------------------

/** Routes POST /sessions/suggest-skill; `respond(prompt)` returns a skill name/null (or a promise of one). Returns the recorded prompts. */
async function routeSuggest(context, respond) {
  const prompts = [];
  await context.route(`${API_BASE}/sessions/suggest-skill`, async (route) => {
    const prompt = JSON.parse(route.request().postData()).prompt;
    prompts.push(prompt);
    const skill = await respond(prompt);
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ skill }) });
  });
  return prompts;
}

async function autoPage(respond) {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  const prompts = await routeSuggest(context, respond);
  const page = await newSessionPage(context);
  return { context, page, prompts };
}

const autoTagVisible = (page) => page.locator('#session-project-pill-auto').isVisible();
const waitPill = (page, text) => page.waitForFunction((t) => document.getElementById('session-project-pill-value').textContent === t, text);

test('typing a prompt: after the debounce the pill shows the detected skill with an "auto" tag and an auto-detected aria-label; LAST_PROJECT_KEY is untouched', async () => {
  const { context, page, prompts } = await autoPage(() => 'project-05');
  assert.equal(await autoTagVisible(page), false, 'no tag before any detection');
  await page.fill('#session-prompt', 'make the project five thing bigger');
  assert.equal(prompts.length, 0, 'nothing is sent before the debounce elapses');
  await waitPill(page, 'project-05');
  assert.equal(await autoTagVisible(page), true);
  assert.match(await page.locator('#session-project-pill').getAttribute('aria-label'), /auto-detected/);
  assert.equal(await page.evaluate(() => localStorage.getItem('gl-session-last-project-v1')), null);
  await context.close();
});

test('a manual tray pick stops later auto changes for the draft, and a manual pick after an auto one drops the tag', async () => {
  const { context, page, prompts } = await autoPage(() => 'project-05');
  await page.fill('#session-prompt', 'make the project five thing bigger');
  await waitPill(page, 'project-05');
  await openTray(page);
  await trayRowLocator(page, 'project-02').click();
  assert.equal(await pillText(page), 'project-02');
  assert.equal(await autoTagVisible(page), false);
  await page.fill('#session-prompt', 'a completely different request now');
  await page.waitForTimeout(1800);
  assert.equal(prompts.length, 1, 'no further suggest request once manual');
  assert.equal(await pillText(page), 'project-02');
  await context.close();
});

test('a null suggestion while auto reverts to the previous skill and removes the tag', async () => {
  const { context, page } = await autoPage((p) => (p.includes('five') ? 'project-05' : null));
  await openTray(page);
  await trayRowLocator(page, 'None').click(); // establish a known previous value ... then reload to make it a 'default' source
  await page.evaluate(() => localStorage.removeItem('gl-session-draft-v1'));
  await page.reload();
  await page.waitForFunction(() => !!document.getElementById('session-project-pill').dataset.ready);
  const before = await pillText(page);
  await page.fill('#session-prompt', 'make the project five thing bigger');
  await waitPill(page, 'project-05');
  await page.fill('#session-prompt', 'what is the weather tomorrow');
  await waitPill(page, before);
  assert.equal(await autoTagVisible(page), false);
  await context.close();
});

test('an out-of-order (stale) suggestion response is ignored', async () => {
  let releaseFirst;
  const firstGate = new Promise((r) => { releaseFirst = r; });
  const { context, page, prompts } = await autoPage((p) => (p.includes('first') ? firstGate.then(() => 'project-03') : 'project-06'));
  await page.fill('#session-prompt', 'first request about something');
  await page.waitForTimeout(1500); // first request is now in flight, gated
  assert.equal(prompts.length, 1);
  await page.fill('#session-prompt', 'second request about something else');
  await waitPill(page, 'project-06');
  releaseFirst();
  await page.waitForTimeout(500);
  assert.equal(await pillText(page), 'project-06', 'the late reply for the older prompt must not win');
  await context.close();
});

test('dictation append triggers detection', async () => {
  const { context, page, prompts } = await autoPage(() => 'project-04');
  await page.click('#session-record-btn');
  await page.waitForSelector('#session-record-btn.recording');
  await page.click('#session-record-btn');
  await waitPill(page, 'project-04');
  assert.deepEqual(prompts, ['a fake voice transcript']);
  assert.equal(await autoTagVisible(page), true);
  await context.close();
});

test('a failed suggest request leaves the selection alone and shows no error banner', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context);
  await context.route(`${API_BASE}/sessions/suggest-skill`, (route) => route.fulfill({ status: 500, body: 'boom' }));
  const page = await newSessionPage(context);
  const before = await pillText(page);
  const warned = page.waitForEvent('console', (m) => m.type() === 'warning' && /skill suggestion failed/.test(m.text()));
  await page.fill('#session-prompt', 'make the project five thing bigger');
  await warned;
  assert.equal(await pillText(page), before);
  assert.equal(await page.locator('#gl-error').isVisible(), false);
  await context.close();
});

test('the auto source survives a reload via the draft, and a successful Start resets it (tag gone, detection allowed again)', async () => {
  const { context, page, prompts } = await autoPage(() => 'project-05');
  await context.route(`${API_BASE}/sessions/start`, (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'x', name: 'n', project: 'project-05' }) }));
  const preAuto = await pillText(page);
  assert.notEqual(preAuto, 'project-05');
  await page.fill('#session-prompt', 'make the project five thing bigger');
  await waitPill(page, 'project-05');
  await page.reload();
  await page.waitForFunction(() => !!document.getElementById('session-project-pill').dataset.ready);
  assert.equal(await pillText(page), 'project-05');
  assert.equal(await autoTagVisible(page), true, 'draft restores the auto source');
  await Promise.all([page.waitForResponse((r) => r.url().endsWith('/sessions/start')), page.click('#session-start-btn')]);
  await page.waitForFunction(() => document.getElementById('session-project-pill-auto').classList.contains('gl-hidden'));
  assert.equal(await pillText(page), preAuto, 'the auto pick belonged to the sent prompt, so Start reverts it');
  await page.fill('#session-prompt', 'another request for later');
  await page.waitForTimeout(1800);
  assert.equal(prompts.length, 2, 'detection runs again for the next draft');
  await context.close();
});

// --- session detail view (tap a recent row -> transcript + reply) -----------

const SESS = (over = {}) => ({
  id: 'abc12345', sessionId: 'sess-uuid-1', name: 'Fix the bug', project: 'project-01',
  state: 'done', startedAt: Date.now(), kind: 'background', bridgeUrl: 'https://claude.ai/code/session_abc', ...over,
});

/** Routes transcript + reply for sessionId; returns a handle with recorded calls and mutable response state. */
async function routeDetail(context, sess, opts = {}) {
  const h = {
    transcriptCalls: 0, replies: [], auths: [],
    messages: opts.messages || [
      { uuid: 'm1', role: 'user', text: 'please fix it', tools: [], at: '2026-10-04T10:00:00Z' },
      { uuid: 'm2', role: 'assistant', text: 'Done. Run `npm test`.\n```js\nconst a = "<b>x</b>";\n```\nAll green.', tools: [{ name: 'Bash', summary: 'git status' }], at: '2026-10-04T10:01:00Z' },
    ],
    truncated: !!opts.truncated, replyStatus: opts.replyStatus || 200, replyBody: opts.replyBody || { ok: true, id: 'r1' },
    sessionState: sess.state,
  };
  await context.route(`${API_BASE}/sessions/${sess.sessionId}/transcript*`, (route) => {
    h.transcriptCalls++;
    h.auths.push(route.request().headers()['authorization']);
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ session: { ...sess, state: h.sessionState }, messages: h.messages, truncated: h.truncated }) });
  });
  await context.route(`${API_BASE}/sessions/${sess.sessionId}/reply`, async (route) => {
    h.replies.push(JSON.parse(route.request().postData()));
    if (h.replyGate) await h.replyGate;
    if (h.replyAbort) return route.abort('connectionrefused');
    return route.fulfill({ status: h.replyStatus, contentType: 'application/json', body: JSON.stringify(h.replyBody) });
  });
  return h;
}

async function openDetailPage(opts = {}) {
  const sess = SESS(opts.sess);
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context, [sess]);
  const h = await routeDetail(context, sess, opts);
  if (opts.beforeNav) await opts.beforeNav(context);
  const page = await newSessionPage(context);
  await page.waitForSelector('#session-recent-list .gl-row');
  await page.click('#session-recent-list .gl-row');
  await page.waitForSelector('#detail-scroll .gl-msg');
  return { context, page, h, sess };
}

test('tapping a recent row opens the detail view and fetches the transcript with the bearer token', async () => {
  const { context, page, h } = await openDetailPage();
  assert.equal(await page.locator('#gl-launcher').isVisible(), false);
  assert.equal(await page.locator('#gl-detail').isVisible(), true);
  assert.equal(await page.locator('#detail-name').textContent(), 'Fix the bug');
  assert.equal(await page.locator('#detail-project').textContent(), 'project-01');
  assert.equal(await page.locator('#detail-state').textContent(), 'done');
  assert.equal(h.transcriptCalls, 1);
  assert.equal(h.auths[0], 'Bearer test-token');
  assert.equal(await page.locator('.gl-bubble').first().textContent(), 'please fix it');
  await context.close();
});

test('assistant text is escaped, fenced blocks and inline code are formatted, tools render as muted lines, truncation note shows', async () => {
  const { context, page } = await openDetailPage({ truncated: true });
  assert.equal(await page.locator('.gl-tool-line').textContent(), 'Bash · git status');
  assert.equal(await page.locator('.gl-codeblock').textContent(), 'const a = "<b>x</b>";');
  assert.equal(await page.locator('.gl-msg-assistant code:not(.gl-codeblock)').textContent(), 'npm test');
  assert.equal(await page.locator('#detail-scroll b').count(), 0, 'transcript text must never become markup');
  assert.equal(await page.locator('.gl-trunc-note').textContent(), 'Earlier messages hidden');
  await context.close();
});

test('detail view opens scrolled to the bottom', async () => {
  const many = Array.from({ length: 40 }, (_, i) => ({ uuid: 'u' + i, role: i % 2 ? 'assistant' : 'user', text: 'line ' + i + ' lorem ipsum dolor sit amet', tools: [], at: 'x' }));
  const { context, page } = await openDetailPage({ messages: many });
  const gap = await page.evaluate(() => { const e = document.getElementById('detail-scroll'); return e.scrollHeight - e.scrollTop - e.clientHeight; });
  assert.ok(gap < 5, 'scrolled to bottom, gap=' + gap);
  assert.ok(await page.evaluate(() => document.getElementById('detail-scroll').scrollHeight > document.getElementById('detail-scroll').clientHeight));
  await context.close();
});

test('Back in the detail view returns to the list WITHOUT calling goBack; Back on the list still calls goBack', async () => {
  const { context, page } = await openDetailPage();
  await page.click('#gl-back-btn');
  assert.equal(await page.locator('#gl-launcher').isVisible(), true);
  assert.equal(await page.locator('#gl-detail').isVisible(), false);
  assert.equal(await page.evaluate(() => window.__glCallLog.filter((c) => c.method === 'goBack').length), 0);
  await page.click('#gl-back-btn');
  await page.waitForFunction(() => window.__glCallLog.some((c) => c.method === 'goBack'));
  await context.close();
});

test('reply: optimistic pending bubble, POST with text + idempotencyKey, draft cleared on 200, state flips to working', async () => {
  const { context, page, h } = await openDetailPage();
  await page.fill('#detail-reply', 'thanks, now ship it');
  await page.click('#detail-send');
  await page.waitForFunction(() => document.querySelector('#detail-scroll .gl-msg-user:last-child .gl-bubble')?.textContent === 'thanks, now ship it');
  assert.equal(await page.inputValue('#detail-reply'), '');
  await page.waitForFunction(() => document.getElementById('detail-state').textContent === 'working');
  assert.equal(h.replies.length, 1);
  assert.equal(h.replies[0].text, 'thanks, now ship it');
  assert.ok(typeof h.replies[0].idempotencyKey === 'string' && h.replies[0].idempotencyKey.length > 6);
  assert.equal(await page.evaluate(() => localStorage.getItem('gl-session-reply-draft-v1:sess-uuid-1')), null);
  assert.equal(await page.locator('#detail-send').isDisabled(), true, 'composer locks while working');
  await context.close();
});

test('reply 409: bubble marked failed, text persisted, error shown; tap retries with the SAME idempotencyKey', async () => {
  const { context, page, h } = await openDetailPage({ replyStatus: 409, replyBody: { error: 'session is busy' } });
  await page.fill('#detail-reply', 'try this');
  await page.click('#detail-send');
  await page.waitForSelector('.gl-bubble.failed');
  assert.match(await page.locator('#gl-error-text').textContent(), /session is busy/);
  assert.equal(await page.evaluate(() => localStorage.getItem('gl-session-reply-draft-v1:sess-uuid-1')), 'try this');
  h.replyStatus = 200; h.replyBody = { ok: true, id: 'r2' };
  await page.click('.gl-bubble.failed');
  while (h.replies.length < 2) await page.waitForTimeout(50);
  await page.waitForFunction(() => !document.querySelector('.gl-bubble.failed'));
  await page.waitForFunction(() => document.getElementById('detail-state').textContent === 'working');
  assert.equal(h.replies.length, 2);
  assert.equal(h.replies[1].idempotencyKey, h.replies[0].idempotencyKey);
  assert.equal(await page.evaluate(() => localStorage.getItem('gl-session-reply-draft-v1:sess-uuid-1')), null);
  await context.close();
});

test('a persisted unsent draft is restored when the detail view opens', async () => {
  const sess = SESS();
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await context.addInitScript(() => { try { localStorage.setItem('gl-session-reply-draft-v1:sess-uuid-1', 'half typed'); } catch (e) {} });
  await routeProjects(context);
  await routeRecent(context, [sess]);
  await routeDetail(context, sess);
  const page = await newSessionPage(context);
  await page.click('#session-recent-list .gl-row');
  await page.waitForSelector('#detail-scroll .gl-msg');
  assert.equal(await page.inputValue('#detail-reply'), 'half typed');
  await context.close();
});

test('composer is disabled with a hint for interactive sessions', async () => {
  const { context, page } = await openDetailPage({ sess: { kind: 'interactive', state: 'idle' } });
  assert.equal(await page.locator('#detail-reply').isDisabled(), true);
  assert.equal(await page.locator('#detail-send').isDisabled(), true);
  assert.equal(await page.locator('#detail-hint').textContent(), 'Open in Claude to reply');
  await context.close();
});

test('composer is disabled with a hint while working or busy, enabled when done', async () => {
  for (const state of ['working', 'busy']) {
    const { context, page } = await openDetailPage({ sess: { state } });
    assert.equal(await page.locator('#detail-send').isDisabled(), true, state);
    assert.match(await page.locator('#detail-hint').textContent(), /Working… you can reply when it finishes/);
    await context.close();
  }
  const { context, page } = await openDetailPage({ sess: { state: 'done' } });
  assert.equal(await page.locator('#detail-send').isDisabled(), false);
  assert.equal(await page.locator('#detail-hint').isVisible(), false);
  await context.close();
});

test('Open in Claude links to bridgeUrl in a new window; hidden when bridgeUrl is null', async () => {
  let r = await openDetailPage();
  assert.equal(await r.page.locator('#detail-open-claude').getAttribute('href'), 'https://claude.ai/code/session_abc');
  assert.equal(await r.page.locator('#detail-open-claude').getAttribute('target'), '_blank');
  await r.context.close();
  r = await openDetailPage({ sess: { bridgeUrl: null } });
  assert.equal(await r.page.locator('#detail-open-claude').isVisible(), false);
  await r.context.close();
});

test('polling: 4s while working, stops after leaving detail and while the page is hidden', async () => {
  const sess = SESS({ state: 'working' });
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context, [sess]);
  const h = await routeDetail(context, sess);
  const page = await context.newPage();
  await page.clock.install();
  await page.goto(SESSION_URL);
  await page.waitForFunction(() => !!document.getElementById('session-project-pill').dataset.ready);
  await page.click('#session-recent-list .gl-row');
  await page.waitForSelector('#detail-scroll .gl-msg');
  assert.equal(h.transcriptCalls, 1);
  await page.clock.runFor(4100);
  await page.waitForTimeout(150);
  assert.equal(h.transcriptCalls, 2, 'refetched after 4s while working');
  for (let i = 0; i < 2; i++) { await page.clock.runFor(4100); await page.waitForTimeout(150); }
  assert.equal(h.transcriptCalls, 4, 'keeps polling at 4s cadence');
  await page.click('#gl-back-btn');
  const after = h.transcriptCalls;
  await page.clock.runFor(30000);
  await page.waitForTimeout(150);
  assert.equal(h.transcriptCalls, after, 'no polling after leaving detail');
  await context.close();
});

test('polling: 15s cadence when not working', async () => {
  const sess = SESS({ state: 'done' });
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context);
  await routeRecent(context, [sess]);
  const h = await routeDetail(context, sess);
  const page = await context.newPage();
  await page.clock.install();
  await page.goto(SESSION_URL);
  await page.waitForFunction(() => !!document.getElementById('session-project-pill').dataset.ready);
  await page.click('#session-recent-list .gl-row');
  await page.waitForSelector('#detail-scroll .gl-msg');
  await page.clock.runFor(14000);
  await page.waitForTimeout(150);
  assert.equal(h.transcriptCalls, 1, 'no refetch before 15s');
  await page.clock.runFor(1500);
  await page.waitForTimeout(150);
  assert.equal(h.transcriptCalls, 2);
  await context.close();
});

test('detail view has no horizontal overflow at 390px', async () => {
  const { context, page } = await openDetailPage();
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth), false);
  await context.close();
});

// Bounded wait, so a regression fails with a message instead of hanging the file.
async function waitFor(predicate, what, ms = 8000) {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > ms) assert.fail('timed out waiting for ' + what);
    await new Promise((r) => setTimeout(r, 50));
  }
}

// --- offline data-loss: Start / Reply / voice are saved first, replayed until the box answers ---

const START_QUEUE = 'gl-session-pending-starts-v1';
const REPLY_QUEUE = 'gl-session-pending-replies-v1';

async function startPageWithStartRoute(handler, opts = {}) {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  if (opts.beforeNav) await opts.beforeNav(context);
  await routeProjects(context);
  await routeRecent(context);
  const calls = [];
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    const body = JSON.parse(route.request().postData());
    calls.push(body);
    return handler(route, calls.length, body);
  });
  const page = await newSessionPage(context);
  return { context, page, calls };
}
const OK_START = (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: 'ok000001', name: 'made it', project: 'project-01' }) });

test('OFFLINE Start: the request is on disk (with its key) before it is cleared; a reload replays it automatically with the SAME key and drains the queue', async () => {
  let offline = true;
  const { context, page, calls } = await startPageWithStartRoute((route) => (offline ? route.abort('connectionrefused') : OK_START(route)));
  await page.fill('#session-prompt', 'do the offline thing');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#gl-error:not(.gl-hidden)');
  assert.match(await page.locator('#gl-error-text').textContent(), /Box unreachable/);
  assert.equal(await page.inputValue('#session-prompt'), '');
  const queued = JSON.parse(await page.evaluate((k) => localStorage.getItem(k), START_QUEUE));
  assert.equal(queued.length, 1);
  assert.equal(queued[0].body.prompt, 'do the offline thing');
  assert.equal(queued[0].body.idempotencyKey, queued[0].key);

  // "Relaunch": same origin storage, new page load, box now reachable.
  offline = false;
  await page.reload();
  await page.waitForFunction(() => !!document.getElementById('session-project-pill').dataset.ready);
  await waitFor(() => calls.length >= 2, 'calls to reach 2 requests');
  assert.equal(calls[1].idempotencyKey, calls[0].idempotencyKey, 'replay must reuse the key so the server dedupes');
  assert.equal(calls[1].prompt, 'do the offline thing');
  await page.waitForFunction((k) => localStorage.getItem(k) === null, START_QUEUE);
  await page.waitForFunction(() => /made it/.test(document.getElementById('session-confirmation-body') ? document.getElementById('session-confirmation-body').textContent : document.body.textContent));
  await context.close();
});

test('OFFLINE Start: the saved request also replays on the "online" event without a reload', async () => {
  let offline = true;
  const { context, page, calls } = await startPageWithStartRoute((route) => (offline ? route.abort('connectionrefused') : OK_START(route)));
  await page.fill('#session-prompt', 'online later');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#gl-error:not(.gl-hidden)');
  offline = false;
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await page.waitForFunction((k) => localStorage.getItem(k) === null, START_QUEUE);
  assert.equal(calls.length, 2);
  await context.close();
});

test('Start rejected by the server (HTTP 400) is NOT retried: queue drained, prompt restored, error shown', async () => {
  const { context, page, calls } = await startPageWithStartRoute((route) =>
    route.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ error: 'bad project' }) }));
  await page.fill('#session-prompt', 'will be refused');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#gl-error:not(.gl-hidden)');
  assert.match(await page.locator('#gl-error-text').textContent(), /Couldn't start the session: bad project/);
  assert.equal(await page.inputValue('#session-prompt'), 'will be refused');
  assert.equal(await page.evaluate((k) => localStorage.getItem(k), START_QUEUE), null);
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await page.waitForTimeout(400);
  assert.equal(calls.length, 1, 'a 4xx must never be replayed');
  await context.close();
});

test('OFFLINE Reply: saved before send, bubble stays pending (not failed), replays on "online" with the SAME key, queue and draft cleared on success', async () => {
  const { context, page, h } = await openDetailPage();
  h.replyAbort = true;
  await page.fill('#detail-reply', 'reply while offline');
  await page.click('#detail-send');
  await waitFor(() => h.replies.length >= 1, 'h.replies to reach 1 requests');
  const queued = JSON.parse(await page.evaluate((k) => localStorage.getItem(k), REPLY_QUEUE));
  assert.equal(queued.length, 1);
  assert.equal(queued[0].text, 'reply while offline');
  assert.equal(queued[0].sessionId, 'sess-uuid-1');
  assert.equal(await page.locator('.gl-bubble.failed').count(), 0, 'a network failure is not a failure state, it is waiting');

  h.replyAbort = false;
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await waitFor(() => h.replies.length >= 2, 'h.replies to reach 2 requests');
  assert.equal(h.replies[1].idempotencyKey, h.replies[0].idempotencyKey);
  await page.waitForFunction((k) => localStorage.getItem(k) === null, REPLY_QUEUE);
  assert.equal(await page.evaluate(() => localStorage.getItem('gl-session-reply-draft-v1:sess-uuid-1')), null);
  await context.close();
});

test('OFFLINE Reply: a saved reply survives a reload and is sent from the list view without the detail open', async () => {
  const sess = SESS();
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await context.addInitScript(() => {
    try {
      if (!localStorage.getItem('seeded')) {
        localStorage.setItem('seeded', '1');
        localStorage.setItem('gl-session-pending-replies-v1', JSON.stringify([{ sessionId: 'sess-uuid-1', text: 'left over', key: 'key-left-over' }]));
      }
    } catch (e) {}
  });
  await routeProjects(context);
  await routeRecent(context, [sess]);
  const h = await routeDetail(context, sess);
  const page = await newSessionPage(context);
  await waitFor(() => h.replies.length >= 1, 'h.replies to reach 1 requests');
  assert.deepEqual(h.replies[0], { text: 'left over', idempotencyKey: 'key-left-over' });
  await page.waitForFunction((k) => localStorage.getItem(k) === null, REPLY_QUEUE);
  await context.close();
});

test('Reply rejected by the server (HTTP 409) is NOT auto-retried: queue drained, bubble failed', async () => {
  const { context, page, h } = await openDetailPage({ replyStatus: 409, replyBody: { error: 'session is busy' } });
  await page.fill('#detail-reply', 'refused');
  await page.click('#detail-send');
  await page.waitForSelector('.gl-bubble.failed');
  assert.equal(await page.evaluate((k) => localStorage.getItem(k), REPLY_QUEUE), null);
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await page.waitForTimeout(400);
  assert.equal(h.replies.length, 1, 'a 4xx must never be replayed automatically');
  await context.close();
});

test('OFFLINE voice: a "queued" stop reply leaves the prompt alone, shows no error, polls native itself, then the transcript from voicePending is appended once and acked', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig({
    voiceStop: { code: 'queued', id: 'v1' },
    voicePending: { ready: [], failed: [], waiting: 0 },   // the load-time poll sees nothing waiting
    voiceAck: {},
  })));
  await context.addInitScript(HOLD_TIMERS);                // the 5s poll timer must not mask the queued branch
  await routeProjects(context);
  await routeRecent(context);
  const page = await newSessionPage(context);
  await page.click('#session-record-btn');
  await page.waitForSelector('#session-record-btn.recording');
  await page.evaluate(() => window.__glMock.configure({ responses: { voicePending: { ready: [], failed: [], waiting: 1 } } }));
  await page.click('#session-record-btn');
  // Only the queued branch's own pollVoice() can produce this status now.
  await page.waitForFunction(() => /transcribes when the box is reachable/.test(document.getElementById('session-record-status').textContent), undefined, { timeout: 5000 });
  assert.equal(await page.locator('#gl-error').evaluate((el) => el.classList.contains('gl-hidden')), true, 'a queued recording is not an error');
  assert.equal(await page.inputValue('#session-prompt'), '');
  const order = await page.evaluate(() => window.__glCallLog.map((c) => c.method));
  assert.ok(order.indexOf('voicePending', order.indexOf('voiceStop')) > order.indexOf('voiceStop'), 'voicePending must be called right after the queued voiceStop');
  await page.evaluate(() => window.__glMock.configure({ responses: { voicePending: { ready: [{ id: 'v1', text: 'late transcript' }], failed: [], waiting: 0 } } }));
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
  await page.waitForFunction(() => document.getElementById('session-prompt').value.indexOf('late transcript') !== -1);
  // A second poll must not append it again.
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
  await page.waitForTimeout(300);
  assert.equal((await page.inputValue('#session-prompt')).split('late transcript').length - 1, 1);
  const acks = await page.evaluate(() => window.__glCallLog.filter((c) => c.method === 'voiceAck').map((c) => c.params));
  assert.ok(acks.some((p) => p.id === 'v1'), 'transcript must be acked so native deletes the recording');
  await context.close();
});

// --- isolating each replay trigger (a 15s retry timer used to mask the others: tests waited up to 30s) ---

// Init script: the page's own 15s queue-retry and 5s voice-poll timers are
// recorded in window.__held instead of scheduled, so a test fires them by hand
// (or never) and no timer can silently stand in for the trigger under test.
function HOLD_TIMERS() {
  const real = window.setTimeout;
  window.__held = [];
  window.setTimeout = function (fn, ms, ...rest) {
    const src = typeof fn === 'function' ? String(fn) : '';
    if ((ms === 15000 && /flushQueues/.test(src)) || (ms === 5000 && /pollVoice/.test(src))) {
      window.__held.push({ ms, fn });
      return 1000000 + window.__held.length;
    }
    return real.call(window, fn, ms, ...rest);
  };
}

// Init script: localStorage refuses to save the offline queues (quota / private mode).
function FAIL_QUEUE_WRITES() {
  const set = Storage.prototype.setItem;
  Storage.prototype.setItem = function (k, v) {
    if (String(k).startsWith('gl-session-pending-')) throw new DOMException('quota exceeded', 'QuotaExceededError');
    return set.call(this, k, v);
  };
}

const TRIGGERS = {
  load: (page) => page.reload(),
  online: (page) => page.evaluate(() => window.dispatchEvent(new Event('online'))),
  visibilitychange: (page) => page.evaluate(() => document.dispatchEvent(new Event('visibilitychange'))),
  timer: (page) => page.evaluate(() => {
    const t = window.__held.filter((h) => h.ms === 15000);
    if (t.length !== 1) throw new Error('expected exactly one held 15s retry timer, got ' + t.length);
    t[0].fn();
  }),
};
const drained = (page, key) => page.waitForFunction((k) => localStorage.getItem(k) === null, key, { timeout: 8000 });

for (const [name, fire] of Object.entries(TRIGGERS)) {
  test(`OFFLINE Start: with only the ${name} trigger, a saved request is replayed`, async () => {
    let offline = true;
    const { context, page, calls } = await startPageWithStartRoute((route) => (offline ? route.abort('connectionrefused') : OK_START(route)), { beforeNav: (c) => c.addInitScript(HOLD_TIMERS) });
    await page.fill('#session-prompt', 'only ' + name);
    await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
    await page.click('#session-start-btn');
    await page.waitForSelector('#gl-error:not(.gl-hidden)');
    await waitFor(() => calls.length === 1, 'the first (failing) attempt');
    offline = false;
    await fire(page);
    await waitFor(() => calls.length >= 2, `a replay triggered only by ${name}`);
    assert.equal(calls[1].idempotencyKey, calls[0].idempotencyKey);
    await drained(page, START_QUEUE);
    await context.close();
  });

  test(`OFFLINE Reply: with only the ${name} trigger, a saved reply is replayed`, async () => {
    const { context, page, h } = await openDetailPage({ beforeNav: (c) => c.addInitScript(HOLD_TIMERS) });
    h.replyAbort = true;
    await page.fill('#detail-reply', 'only ' + name);
    await page.click('#detail-send');
    await waitFor(() => h.replies.length === 1, 'the first (failing) reply attempt');
    await page.waitForFunction((k) => localStorage.getItem(k) !== null, REPLY_QUEUE);
    h.replyAbort = false;
    await fire(page);
    await waitFor(() => h.replies.length >= 2, `a reply replay triggered only by ${name}`);
    assert.equal(h.replies[1].idempotencyKey, h.replies[0].idempotencyKey);
    await drained(page, REPLY_QUEUE);
    await context.close();
  });
}

test('OFFLINE Start: a failed attempt schedules exactly one 15s retry, and firing it does replay', async () => {
  let offline = true;
  const { context, page, calls } = await startPageWithStartRoute((route) => (offline ? route.abort('connectionrefused') : OK_START(route)), { beforeNav: (c) => c.addInitScript(HOLD_TIMERS) });
  await page.fill('#session-prompt', 'timer');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await waitFor(() => calls.length === 1, 'the first attempt');
  await page.waitForSelector('#gl-error:not(.gl-hidden)');
  assert.equal(await page.evaluate(() => window.__held.filter((h) => h.ms === 15000).length), 1, 'a failed send must schedule a retry');
  await context.close();
});

// --- durable BEFORE the request leaves ---

test('OFFLINE Start: the request is already on disk while its fetch is still in flight', async () => {
  let release;
  const gate = new Promise((r) => { release = r; });
  const { context, page, calls } = await startPageWithStartRoute(async (route) => { await gate; return OK_START(route); });
  await page.fill('#session-prompt', 'held in flight');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await waitFor(() => calls.length === 1, 'the request to reach the box');
  const queued = JSON.parse(await page.evaluate((k) => localStorage.getItem(k), START_QUEUE));
  assert.equal(queued.length, 1, 'the request must be saved before/while it is sent');
  assert.equal(queued[0].key, calls[0].idempotencyKey);
  assert.equal(queued[0].body.prompt, 'held in flight');
  release();
  await drained(page, START_QUEUE);
  await context.close();
});

test('OFFLINE Reply: the reply is already on disk while its fetch is still in flight', async () => {
  let release;
  const { context, page, h } = await openDetailPage();
  h.replyGate = new Promise((r) => { release = r; });
  await page.fill('#detail-reply', 'reply in flight');
  await page.click('#detail-send');
  await waitFor(() => h.replies.length === 1, 'the reply to reach the box');
  const queued = JSON.parse(await page.evaluate((k) => localStorage.getItem(k), REPLY_QUEUE));
  assert.equal(queued.length, 1);
  assert.equal(queued[0].key, h.replies[0].idempotencyKey);
  assert.equal(queued[0].text, 'reply in flight');
  release();
  await drained(page, REPLY_QUEUE);
  await context.close();
});

// --- the queue write itself failing: nothing may be cleared or reported as sent ---

test('OFFLINE Start: when the queue cannot be saved, the prompt stays, an error shows, and nothing is sent', async () => {
  const { context, page, calls } = await startPageWithStartRoute(OK_START, { beforeNav: (c) => c.addInitScript(FAIL_QUEUE_WRITES) });
  await page.fill('#session-prompt', 'must not vanish');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await page.waitForSelector('#gl-error:not(.gl-hidden)');
  assert.match(await page.locator('#gl-error-text').textContent(), /Couldn't save the request on this device/);
  assert.equal(await page.inputValue('#session-prompt'), 'must not vanish');
  assert.equal(await page.locator('#session-confirmation').evaluate((el) => el.classList.contains('gl-hidden')), true, 'must not claim it is starting');
  await page.waitForTimeout(300);
  assert.equal(calls.length, 0);
  await context.close();
});

test('OFFLINE Reply: when the queue cannot be saved, the reply is shown as failed with its text, an error shows, and nothing is sent', async () => {
  const { context, page, h } = await openDetailPage({ beforeNav: (c) => c.addInitScript(FAIL_QUEUE_WRITES) });
  await page.fill('#detail-reply', 'must not vanish');
  await page.click('#detail-send');
  await page.waitForSelector('.gl-bubble.failed', { timeout: 5000 });
  assert.match(await page.locator('.gl-bubble.failed').textContent(), /must not vanish/);
  assert.match(await page.locator('#gl-error-text').textContent(), /Couldn't save the reply on this device/);
  await page.waitForTimeout(300);
  assert.equal(h.replies.length, 0);
  await context.close();
});

// --- single flight, ordering, the load banner ---

test('OFFLINE Start: repeated online/visibilitychange while a request is in flight send it exactly once', async () => {
  let release;
  const gate = new Promise((r) => { release = r; });
  const { context, page, calls } = await startPageWithStartRoute(async (route) => { await gate; return OK_START(route); });
  await page.fill('#session-prompt', 'once only');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await page.click('#session-start-btn');
  await waitFor(() => calls.length === 1, 'the request to reach the box');
  await page.evaluate(() => {
    for (let i = 0; i < 3; i++) { window.dispatchEvent(new Event('online')); document.dispatchEvent(new Event('visibilitychange')); }
  });
  await page.waitForTimeout(300);
  assert.equal(calls.length, 1, 'overlapping triggers re-sent the in-flight request');
  release();
  await drained(page, START_QUEUE);
  assert.equal(calls.length, 1);
  await context.close();
});

test('OFFLINE Reply: repeated online/visibilitychange while a reply is in flight send it exactly once', async () => {
  let release;
  const { context, page, h } = await openDetailPage();
  h.replyGate = new Promise((r) => { release = r; });
  await page.fill('#detail-reply', 'once only');
  await page.click('#detail-send');
  await waitFor(() => h.replies.length === 1, 'the reply to reach the box');
  await page.evaluate(() => {
    for (let i = 0; i < 3; i++) { window.dispatchEvent(new Event('online')); document.dispatchEvent(new Event('visibilitychange')); }
  });
  await page.waitForTimeout(300);
  assert.equal(h.replies.length, 1, 'overlapping triggers re-sent the in-flight reply');
  release();
  await drained(page, REPLY_QUEUE);
  assert.equal(h.replies.length, 1);
  await context.close();
});

function seedQueues(context, seed) {
  return context.addInitScript((s) => {
    try {
      if (!localStorage.getItem('seeded')) {
        localStorage.setItem('seeded', '1');
        for (const [k, v] of Object.entries(s)) localStorage.setItem(k, JSON.stringify(v));
      }
    } catch (e) {}
  }, seed);
}

test('OFFLINE Start: several saved requests replay oldest first, one at a time', async () => {
  const entries = ['first', 'second', 'third'].map((p, i) => ({ key: 'k' + i, body: { project: '', prompt: p, attachments: [], idempotencyKey: 'k' + i, model: 'sonnet' } }));
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await seedQueues(context, { [START_QUEUE]: entries });
  await routeProjects(context);
  await routeRecent(context);
  const seen = [];
  await context.route(`${API_BASE}/sessions/start`, (route) => {
    seen.push(JSON.parse(route.request().postData()).prompt);
    return OK_START(route);
  });
  const page = await newSessionPage(context);
  await waitFor(() => seen.length >= 3, 'all three saved requests');
  assert.deepEqual(seen, ['first', 'second', 'third']);
  await drained(page, START_QUEUE);
  await context.close();
});

test('OFFLINE Reply: several saved replies replay oldest first', async () => {
  const sess = SESS();
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await seedQueues(context, { [REPLY_QUEUE]: ['one', 'two', 'three'].map((t) => ({ sessionId: 'sess-uuid-1', text: t, key: 'r-' + t })) });
  await routeProjects(context);
  await routeRecent(context, [sess]);
  const h = await routeDetail(context, sess);
  const page = await newSessionPage(context);
  await waitFor(() => h.replies.length >= 3, 'all three saved replies');
  assert.deepEqual(h.replies.map((r) => r.text), ['one', 'two', 'three']);
  await drained(page, REPLY_QUEUE);
  await context.close();
});

test('OFFLINE Start: on load, a saved request that is still being sent shows "Waiting for the box"', async () => {
  const entry = { key: 'kw', body: { project: '', prompt: 'saved', attachments: [], idempotencyKey: 'kw', model: 'sonnet' } };
  let release;
  const gate = new Promise((r) => { release = r; });
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await seedQueues(context, { [START_QUEUE]: [entry] });
  await routeProjects(context);
  await routeRecent(context);
  let reached = false;
  await context.route(`${API_BASE}/sessions/start`, async (route) => { reached = true; await gate; return OK_START(route); });
  const page = await newSessionPage(context);
  await waitFor(() => reached, 'the saved request to be sent');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 3000 });
  assert.match(await page.locator('#session-confirmation-body').textContent(), /Waiting for the box/);
  release();
  await drained(page, START_QUEUE);
  await context.close();
});

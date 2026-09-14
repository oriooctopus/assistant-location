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

test('exactly 7 projects: all 7 appear under Recent, no All-projects section', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(7));
  await routeRecent(context);
  const page = await newSessionPage(context);
  await openTray(page);
  const recentLabel = page.locator('.tray-section-label:text("Recent")');
  await assert.doesNotReject(recentLabel.waitFor({ state: 'attached', timeout: 2000 }));
  assert.equal(await page.locator('.tray-section-label:text("All projects")').count(), 0, 'no All-projects header at exactly 7 projects');
  const rowNames = await page.locator('.tray-row span:first-child').allTextContents();
  assert.deepEqual(rowNames, projectNames(7));
  await context.close();
});

test('8+ projects: first 7 under Recent, the rest under All projects, no duplicates', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, projectNames(10));
  await routeRecent(context);
  const page = await newSessionPage(context);
  await openTray(page);
  const rowNames = await page.locator('.tray-row span:first-child').allTextContents();
  assert.deepEqual(rowNames, projectNames(10), 'Recent (7) then All projects (3), each name exactly once');
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
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
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
  await page.click('#session-start-btn');
  await page.waitForSelector('#session-confirmation:not(.gl-hidden)', { timeout: 5000 });
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

  // Case-insensitive + only the All-projects section matches -> Recent header hidden.
  await page.fill('#session-project-tray-search', 'mixed');
  await assert.doesNotReject(trayRowLocator(page, 'MixedCaseRepo').waitFor({ state: 'visible', timeout: 2000 }));
  assert.equal(await page.locator('.tray-section-label:text("Recent")').count(), 0, 'Recent header hidden when it has zero matches');
  assert.equal(await page.locator('.tray-row').count(), 1);

  // Case-insensitive in the Recent section too -> All-projects header hidden.
  await page.fill('#session-project-tray-search', 'upperrec');
  await assert.doesNotReject(trayRowLocator(page, 'UpperRecent').waitFor({ state: 'visible', timeout: 2000 }));
  assert.equal(await page.locator('.tray-section-label:text("All projects")').count(), 0, 'All-projects header hidden when only a Recent name matches');
  assert.equal(await page.locator('.tray-row').count(), 1);

  // SUBSTRING match, not prefix: "ject-0" starts no name but sits inside
  // project-01..06 (Recent) and project-08/09 (All) -> 8 rows, both
  // headers. A startsWith-style filter would show nothing here.
  await page.fill('#session-project-tray-search', 'ject-0');
  await assert.doesNotReject(trayRowLocator(page, 'project-09').waitFor({ state: 'visible', timeout: 2000 }));
  assert.deepEqual(await page.locator('.tray-row span:first-child').allTextContents(),
    [...projectNames(6), 'project-08', 'project-09'], 'a mid-name query matches in BOTH sections, Recent first');
  assert.equal(await page.locator('.tray-section-label').count(), 2);

  // Whitespace padding around a real query is trimmed the same way.
  await page.fill('#session-project-tray-search', '   mixed   ');
  await assert.doesNotReject(trayRowLocator(page, 'MixedCaseRepo').waitFor({ state: 'visible', timeout: 2000 }));

  // A query matching a Recent name only -> All-projects header hidden.
  await page.fill('#session-project-tray-search', 'project-03');
  await assert.doesNotReject(trayRowLocator(page, 'project-03').waitFor({ state: 'visible', timeout: 2000 }));
  assert.equal(await page.locator('.tray-section-label:text("All projects")').count(), 0, 'All-projects header hidden when it has zero matches');

  // All-whitespace query = full, unfiltered list (both sections back, no dupes).
  await page.fill('#session-project-tray-search', '   ');
  await assert.doesNotReject(page.locator('.tray-section-label:text("Recent")').waitFor({ state: 'visible', timeout: 2000 }));
  await assert.doesNotReject(page.locator('.tray-section-label:text("All projects")').waitFor({ state: 'visible', timeout: 2000 }));
  const allNames = await page.locator('.tray-row span:first-child').allTextContents();
  assert.equal(new Set(allNames).size, allNames.length, 'no duplicates in the unfiltered list');
  assert.equal(allNames.length, 12);

  // No match at all -> empty state, no stray section headers.
  await page.fill('#session-project-tray-search', 'zzz-nope');
  await assert.doesNotReject(page.locator('.tray-empty').waitFor({ state: 'visible', timeout: 2000 }));
  assert.equal(await page.locator('.tray-section-label').count(), 0);
  assert.equal(await page.locator('.tray-row').count(), 0);
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
  assert.equal(await page.locator('.tray-row').count(), 7, 'reopening with a cleared query shows the full list again');
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

test('a remembered last-used project that no longer exists in the list falls back to the first project, never a ghost pill value', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await context.addInitScript((key) => { window.localStorage.setItem(key, 'renamed-away-project'); }, 'gl-session-last-project-v1');
  await routeProjects(context, projectNames(3));
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.equal(await pillText(page), 'project-01', 'falls back to the FIRST project');
  await context.close();
});

test('a single project is auto-selected in the pill and Start is enabled once a prompt is typed', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, ['only-project']);
  await routeRecent(context);
  const page = await newSessionPage(context);
  assert.equal(await pillText(page), 'only-project');
  await page.fill('#session-prompt', 'go');
  await page.waitForFunction(() => !document.getElementById('session-start-btn').disabled);
  await context.close();
});

test('zero projects: pill shows a visible placeholder (never "undefined"), tray shows an empty state, and Start stays disabled', async () => {
  const context = await browser.newContext();
  await context.addInitScript(buildMockBridgeScript(baseConfig()));
  await routeProjects(context, []);
  await routeRecent(context);
  const page = await newSessionPage(context);
  const pillValue = await pillText(page);
  assert.notEqual(pillValue.trim(), '', 'the pill must show SOMETHING visible, never a blank');
  assert.doesNotMatch(pillValue, /undefined/);
  await openTray(page);
  await assert.doesNotReject(page.locator('.tray-empty').waitFor({ state: 'visible', timeout: 2000 }));
  await page.fill('#session-prompt', 'go nowhere');
  // Give the page a moment to (not) enable Start -- there's no project to select.
  await page.waitForTimeout(100);
  assert.equal(await page.locator('#session-start-btn').isDisabled(), true);
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

// Oliver's private check-in journal on the fight page ("Just me" + "View change"). Privacy is the point: with the box answering 200 the
// section shows and the typed text survives a reload; with 404 (Esme, or Funnel) nothing renders at all; and neither the journal text nor
// the view-change text ever reaches Supabase, the outbox, or any request other than GET /checkins (response) and PUT /backup (owner box).
// Runs in WebKit only (set GL_WEBKIT_PW/GL_WEBKIT_EXEC, e.g. via ~/.claude/bin/cycle-webkit.sh); skipped without it.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web');
// Served over http, not file://: a reloaded file:// document can read an empty localStorage (see cycle-vent.test.mjs).
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.json': 'application/json', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf' };
const srv = http.createServer((req, res) => {
  const f = path.join(WEB, new URL(req.url, 'http://x').pathname);
  fs.readFile(f, (e, b) => { if (e) { res.statusCode = 404; res.end(); } else { res.setHeader('content-type', MIME[path.extname(f)] || 'application/octet-stream'); res.end(b); } });
});
await new Promise((r) => srv.listen(0, '127.0.0.1', r));
srv.unref();
const URL_ = 'http://127.0.0.1:' + srv.address().port + '/index.html';
const CSS = fs.readFileSync(path.join(WEB, 'cycle.css'), 'utf8') + '\n#fx{display:none}';
const engines = {};
if (process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC) {
  const pw = await import(process.env.GL_WEBKIT_PW);
  engines.webkit = { launch: (o) => pw.webkit.launch({ ...o, executablePath: process.env.GL_WEBKIT_EXEC }) };
}

const UID = 'u-me', PID = 'u-her', HOUR = 36e5;
const FIGHT = Date.now() - 72 * HOUR;
const iso = (ms) => new Date(ms).toISOString();
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': 'Authorization, Content-Type', 'access-control-allow-methods': 'GET, PUT, OPTIONS' };
const NOTE_BEFORE = 'FAKE-NOTE-BEFORE-ZQX', NOTE_AFTER = 'FAKE-NOTE-AFTER-ZQX', NOTE_SELF = 'FAKE-SELF-NOTE-ZQX', VIEW = 'FAKE view change typed ZQX';
const SECRETS = [NOTE_BEFORE, NOTE_AFTER, NOTE_SELF, VIEW];
const ENTRIES = [
  { kind: 'checkin', at: iso(FIGHT - 20 * HOUR), date: '2026-11-05', leaveScore: 2, hurtHerself: false, text: NOTE_BEFORE },
  { kind: 'checkin', at: iso(FIGHT + 10 * HOUR), date: '2026-11-06', leaveScore: 6, hurtHerself: false, text: NOTE_AFTER },
  { kind: 'checkin', at: iso(FIGHT + 11 * HOUR), date: '2026-11-06', leaveScore: 4, hurtHerself: false, text: '' },
  { kind: 'self_note', at: iso(FIGHT + 30 * HOUR), text: NOTE_SELF },
];
const seed = () => {
  const sh = {
    couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [{ user_id: UID, name: 'Alex', checkin_time: '21:00', hits_self: false }, { user_id: PID, name: 'Sam', checkin_time: '21:00', hits_self: true }],
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, fight_notes: {}, fight_ratings: {}, fight_vents: {}, rewards: {}, redemptions: {}, nudges: {}, nudge_sends: {}, nudge_replies: {}, nudge_awards: {}, todo_comments: {}, todo_nudges: {}, challenges: {}, challenge_breaks: {}, challenge_days: {}, challenge_nudges: {},
      fight_markers: { f1: { id: 'f1', couple_id: 'c1', logged_by: UID, at: iso(FIGHT), repaired_at: null, hit_self: null, hit_related: null, summary: null, summary_notes_at: null } } },
    cursors: {}, outbox: [],
  };
  return { session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } }, ['shared.' + UID]: sh, ['priv.' + UID]: { fights: [], affirmations: [], prefs: {} } };
};

for (const [name, type] of Object.entries(engines)) describe(name, () => {
  let browser;
  before(async () => { browser = await type.launch({ headless: true }); });
  after(async () => { await browser.close(); });

  // checkinsStatus: what the box's GET /checkins answers (200 = Oliver, 404 = anyone else).
  async function open(checkinsStatus) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.addInitScript(({ sd }) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: 'https://box.test' };
      if (location.search === '?seed') for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, { sd: seed() });
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    const reqs = []; // every request that tried to leave the page, with its body
    context.on('request', (r) => { if (!r.url().startsWith('http://127.0.0.1')) reqs.push({ method: r.method(), url: r.url(), body: r.postData() || '' }); });
    await context.route('https://x.test/**', (route) => route.abort());
    await context.route('https://box.test/**', (route) => {
      const u = new URL(route.request().url()), m = route.request().method();
      if (m === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS });
      if (u.pathname === '/checkins') {
        return checkinsStatus === 200
          ? route.fulfill({ status: 200, contentType: 'application/json', headers: CORS, body: JSON.stringify({ entries: ENTRIES }) })
          : route.fulfill({ status: 404, contentType: 'application/json', headers: CORS, body: '{"error":"not found"}' });
      }
      if (u.pathname === '/backup') return route.fulfill({ status: m === 'GET' ? 404 : 200, contentType: 'application/json', headers: CORS, body: m === 'GET' ? '{"error":"no backup"}' : '{"ok":true}' });
      return route.fulfill({ status: 404, headers: CORS, body: '' });
    });
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_ + '?seed', { waitUntil: 'domcontentloaded' });
    return { context, page, reqs };
  }
  async function openFight(page) { await page.waitForSelector('[data-a="tab:fights"]'); await page.click('[data-a="tab:fights"]'); await page.click('.rf[data-a="openfight:f1"]'); await page.waitForSelector('.fd'); }
  const priv = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('cycle:priv.u-me')));
  const shared = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')));

  test('200: Just me shows before -> after leave scores and the notes; View change text survives a reload; nothing leaves except GET /checkins and PUT /backup', async () => {
    const { context, page, reqs } = await open(200);
    await openFight(page);
    await page.waitForSelector('.fd .jm');
    const labels = await page.$$eval('.fd .jm .lab', (e) => e.map((x) => x.textContent.trim()));
    assert.deepEqual(labels, ['Just me', 'View change']);
    assert.match(await page.textContent('.jm .jml'), /Leave\s*2\s*→\s*6, 4/);
    // collapsed: count and range only, no text until expanded
    assert.match(await page.textContent('.jm [data-a="jmtoggle"]'), /^3 notes · /);
    assert.equal(await page.locator('.jm .fn').count(), 0);
    await page.click('.jm [data-a="jmtoggle"]');
    const items = await page.$$eval('.jm .fns > *', (e) => e.map((x) => (x.className === 'jmdiv' ? 'DIV' : x.querySelector('p:not(.meta)').textContent)));
    assert.deepEqual(items, [NOTE_BEFORE, 'DIV', NOTE_AFTER, NOTE_SELF]);
    // 16px/24px/15px/44px minimums
    assert.ok((await page.locator('.jm [data-a="jmtoggle"]').boundingBox()).height >= 44);
    assert.equal(await page.$eval('.jm .fn p:not(.meta)', (e) => getComputedStyle(e).fontSize), '15px');
    assert.equal(await page.$eval('.jm .jmvl', (e) => getComputedStyle(e).marginTop), '24px');

    await page.fill('textarea[data-d="vchg"]', VIEW);
    await page.waitForFunction((v) => (JSON.parse(localStorage.getItem('cycle:priv.u-me')).viewChange.f1 || {}).text === v, VIEW);
    // vcMirror schedules the owner-box backup 3s out; wait for it before reloading (a reload kills the timer).
    await page.waitForTimeout(4000);
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await openFight(page);
    await page.waitForSelector('.fd .jm');
    assert.equal(await page.inputValue('textarea[data-d="vchg"]'), VIEW, 'typed text survives reload');
    const pv = await priv(page);
    assert.equal(pv.checkinOk, true);
    assert.equal(pv.viewChange.f1.text, VIEW);
    assert.equal(pv.checkins.f1.entries.length, ENTRIES.length);

    // Leak audit over everything that left the page during this test.
    const sh = await shared(page);
    const outbox = JSON.stringify(sh.outbox), rows = JSON.stringify(sh.rows);
    for (const s of [...SECRETS, 'viewChange', 'checkins"', 'checkinOk']) assert.equal(outbox.includes(s), false, 'outbox has ' + s);
    for (const s of SECRETS) assert.equal(rows.includes(s), false, 'shared rows have ' + s);
    const carrying = reqs.filter((r) => SECRETS.some((s) => r.body.includes(s)) || /viewChange|"checkins"/.test(r.body) || SECRETS.some((s) => decodeURIComponent(r.url).includes(s)));
    assert.ok(carrying.length > 0, 'PUT /backup should have carried the private tier to the owner box');
    for (const r of carrying) assert.ok(r.method === 'PUT' && r.url === 'https://box.test/backup', 'data in ' + r.method + ' ' + r.url);
    assert.deepEqual(reqs.filter((r) => r.url.startsWith('https://x.test')).filter((r) => r.body).filter((r) => SECRETS.some((s) => r.body.includes(s))), [], 'Supabase never sees the text');
    assert.ok(reqs.every((r) => r.url.startsWith('https://box.test') || r.url.startsWith('https://x.test')), 'no third host');
    await context.close();
  });

  test('404: the fight page shows no Just me section and no View change, and nothing is stored', async () => {
    const { context, page } = await open(404);
    await openFight(page);
    await page.waitForTimeout(1500); // let the /checkins round-trip finish
    assert.equal(await page.locator('.fd .jm').count(), 0);
    const text = await page.textContent('.fd');
    assert.equal(text.includes('View change'), false);
    assert.equal(await page.locator('.fd .lab', { hasText: /^Just me$/ }).count(), 0);
    assert.equal(await page.locator('textarea[data-d="vchg"]').count(), 0);
    const pv = await priv(page);
    assert.ok(!pv.checkinOk && !Object.keys(pv.checkins || {}).length && !Object.keys(pv.viewChange || {}).length);
    await context.close();
  });
});

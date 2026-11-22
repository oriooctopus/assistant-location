// Oliver's private "Action items" / "Growth reminders" sections and box-delivered vents on the fight page (GET /followups). Same privacy as Just me:
// 200 renders the sections from the box's to-do proposals and merges box vents into the private tier once; 404 (Esme, Funnel) renders and stores nothing.
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
const ITEMS = [
  { id: 'p1', kind: 'action', title: 'FAKE-ACT-ONE-ZQX', notes: 'FAKE-ACT-NOTE-ZQX', status: 'proposed', dest: 'todo' },
  { id: 'p2', kind: 'action', title: 'FAKE-ACT-TWO-ZQX', notes: '', status: 'dropped', dest: 'todo' },
  { id: 'p3', kind: 'growth', title: 'FAKE-GROW-ZQX', notes: 'FAKE-GROW-NOTE-ZQX', status: 'confirmed', dest: 'lists' },
];
const VENT = { id: 'v-box-1', body: 'FAKE-BOX-VENT-ZQX', created_at: iso(FIGHT + HOUR) };
const seed = () => {
  const sh = {
    couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [{ user_id: UID, name: 'Alex', checkin_time: '21:00', hits_self: false }, { user_id: PID, name: 'Sam', checkin_time: '21:00', hits_self: true }],
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, fight_notes: {}, fight_ratings: {}, fight_vents: {}, rewards: {}, redemptions: {}, nudges: {}, nudge_sends: {}, nudge_replies: {}, nudge_awards: {}, todo_comments: {}, todo_nudges: {}, challenges: {}, challenge_breaks: {}, challenge_days: {}, challenge_nudges: {},
      fight_markers: { f1: { id: 'f1', couple_id: 'c1', logged_by: UID, at: iso(FIGHT), repaired_at: null, hit_self: null, hit_related: null, summary: null, summary_notes_at: null, text_on: true, texts: [{ ts: iso(FIGHT), by: UID, body: 'Fixture text' }], texts_wider: 0, texts_grabbed_wider: 0 } } },
    cursors: {}, outbox: [],
  };
  return { session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } }, ['shared.' + UID]: sh, ['priv.' + UID]: { fights: [], affirmations: [], prefs: {} } };
};

for (const [name, type] of Object.entries(engines)) describe(name, () => {
  let browser;
  before(async () => { browser = await type.launch({ headless: true }); });
  after(async () => { await browser.close(); });

  // st: the box's GET /followups status; the body is { items, vents }.
  async function open(st, items = ITEMS) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.addInitScript(({ sd }) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: 'https://box.test' };
      if (location.search === '?seed') for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, { sd: seed() });
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    const reqs = [];
    context.on('request', (r) => { if (!r.url().startsWith('http://127.0.0.1')) reqs.push({ method: r.method(), url: r.url(), body: r.postData() || '' }); });
    await context.route('https://x.test/**', (route) => route.abort());
    const box = { followups: st };
    await context.route('https://box.test/**', (route) => {
      const u = new URL(route.request().url()), m = route.request().method();
      if (m === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS });
      if (u.pathname === '/followups') {
        if (box.followups === 'offline') return route.abort();
        return box.followups === 200
          ? route.fulfill({ status: 200, contentType: 'application/json', headers: CORS, body: JSON.stringify({ items, vents: [VENT] }) })
          : route.fulfill({ status: box.followups, contentType: 'application/json', headers: CORS, body: '{"error":"x"}' });
      }
      if (u.pathname === '/checkins') return route.fulfill({ status: 404, contentType: 'application/json', headers: CORS, body: '{}' });
      if (u.pathname === '/backup') return route.fulfill({ status: m === 'GET' ? 404 : 200, contentType: 'application/json', headers: CORS, body: m === 'GET' ? '{"error":"no backup"}' : '{"ok":true}' });
      return route.fulfill({ status: 404, headers: CORS, body: '' });
    });
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_ + '?seed', { waitUntil: 'domcontentloaded' });
    return { context, page, reqs, box };
  }
  async function openFight(page) { await page.waitForSelector('[data-a="tab:fights"]'); await page.click('[data-a="tab:fights"]'); await page.click('.rf[data-a="openfight:f1"]'); await page.waitForSelector('.fd'); }
  const priv = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('cycle:priv.u-me')));
  const shared = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')));
  const sections = (page) => page.$$eval('.fd section.fu', (ss) => ss.map((s) => ({ lab: s.querySelector('.lab').textContent.trim(), rows: [...s.querySelectorAll('.fur')].map((r) => ({ title: r.querySelector('.fut p:not(.meta)').textContent, note: (r.querySelector('.fut .meta') || {}).textContent || null, status: r.querySelector('.fus').textContent })) })));

  test('200: Action items and Growth reminders render with title, note and a bare status; an empty section is omitted; the cache renders offline; nothing is written anywhere', async () => {
    const { context, page, reqs, box } = await open(200);
    await openFight(page);
    await page.waitForSelector('.fd .fu');
    assert.deepEqual(await sections(page), [
      { lab: 'Action items', rows: [{ title: 'FAKE-ACT-ONE-ZQX', note: 'FAKE-ACT-NOTE-ZQX', status: 'In swiper' }, { title: 'FAKE-ACT-TWO-ZQX', note: null, status: 'Dropped' }] },
      { lab: 'Growth reminders', rows: [{ title: 'FAKE-GROW-ZQX', note: 'FAKE-GROW-NOTE-ZQX', status: 'Added' }] },
    ]);
    // sits after Texts (Just me is absent here: /checkins is 404) and before the notes
    assert.ok(await page.$eval('.fd section.fu', (e) => e.previousElementSibling.classList.contains('txs')));
    // status is right-aligned in the row
    const [rb, sb] = await page.$eval('.fd .fur', (r) => [r.getBoundingClientRect().right, r.querySelector('.fus').getBoundingClientRect().right]);
    assert.ok(Math.abs(rb - sb) < 1, 'status sits at the right edge');
    // rows stack under the label (a flex-row section once squeezed titles to one word per line)
    const geo = await page.$eval('.fd section.fu', (e) => { const l = e.querySelector('.lab').getBoundingClientRect(), r = e.querySelector('.fur').getBoundingClientRect(), t = e.querySelector('.fut').getBoundingClientRect(), s = e.getBoundingClientRect(); return { labBottom: l.bottom, rowTop: r.top, titleW: t.width, secW: s.width }; });
    assert.ok(geo.rowTop >= geo.labBottom - 1, 'row is below the label');
    assert.ok(geo.titleW > geo.secW * 0.6, 'title gets most of the width ' + JSON.stringify(geo));
    assert.equal(await page.locator('.fd .fu [data-a]').count(), 0, 'read-only: no actions');
    // offline: reload with the box unreachable, the cached rows still draw
    await page.waitForTimeout(500);
    box.followups = 'offline';
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await openFight(page);
    await page.waitForSelector('.fd .fu');
    assert.equal((await sections(page)).length, 2);
    // only GET /followups (and the owner backup) carry the text
    const sh = await shared(page);
    assert.deepEqual(sh.outbox, []);
    assert.equal(JSON.stringify(sh.rows).includes('ZQX'), false, 'no shared row carries it');
    for (const r of reqs.filter((r) => r.url.startsWith('https://x.test'))) assert.ok(r.method === 'GET' && !r.body, 'no Supabase write');
    for (const r of reqs.filter((r) => /ZQX/.test(decodeURIComponent(r.url) + r.body))) assert.ok(r.method === 'PUT' && r.url === 'https://box.test/backup', 'text in ' + r.method + ' ' + r.url);
    await context.close();
  });

  test('a section with no rows is omitted: only growth rows draw only Growth reminders', async () => {
    const { context, page } = await open(200, ITEMS.filter((i) => i.kind === 'growth'));
    await openFight(page);
    await page.waitForSelector('.fd .fu');
    assert.deepEqual((await sections(page)).map((s) => s.lab), ['Growth reminders']);
    await context.close();
  });

  for (const st of [404, 502]) test(st + ': nothing renders, nothing is stored, no request carries a body', async () => {
    const { context, page, reqs } = await open(st);
    await openFight(page);
    await page.waitForTimeout(1500);
    assert.equal(await page.locator('.fd .fu').count(), 0);
    const text = await page.textContent('.fd');
    assert.equal(/Action items|Growth reminders/.test(text), false);
    assert.equal(text.includes('FAKE-BOX-VENT'), false);
    const pv = await priv(page);
    assert.ok(!pv.followupsOk && !Object.keys(pv.followups || {}).length && !Object.keys(pv.ventImported || {}).length && !(pv.vents || []).length);
    assert.ok(reqs.some((r) => r.method === 'GET' && r.url.startsWith('https://box.test/followups')), 'the page did ask');
    assert.deepEqual(reqs.filter((r) => r.method !== 'GET' || r.body), [], 'no write and no body on any request');
    assert.deepEqual((await shared(page)).outbox, []);
    await context.close();
  });

  test('a box vent is imported once into the private vents, shown under Vent as Just me, and not re-added after Oliver deletes it', async () => {
    const { context, page } = await open(200);
    await openFight(page);
    await page.waitForSelector('.fd .fu');
    const ventCount = () => page.locator('.fd .vent', { hasText: 'FAKE-BOX-VENT-ZQX' }).count();
    assert.equal(await ventCount(), 1);
    let pv = await priv(page);
    assert.deepEqual(pv.vents.map((v) => [v.id, v.fight_marker_id, v.body]), [['v-box-1', 'f1', 'FAKE-BOX-VENT-ZQX']]);
    assert.equal(pv.ventImported['v-box-1'], true);
    // a second fetch (leave and reopen the fight) does not duplicate it
    await page.click('.hd [data-a]'); await page.waitForSelector('[data-a="tab:fights"]');
    await page.click('.rf[data-a="openfight:f1"]'); await page.waitForSelector('.fd .fu');
    await page.waitForTimeout(800);
    assert.equal((await priv(page)).vents.length, 1);
    // delete it on the phone
    await page.click('[data-a="ventdel:v-box-1"]');
    await page.click('[data-a="ventdelok"]');
    await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:priv.u-me')).vents.length === 0);
    // reopen: the box still returns it, it stays deleted
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await openFight(page);
    await page.waitForSelector('.fd .fu');
    await page.waitForTimeout(800);
    pv = await priv(page);
    assert.equal(pv.vents.length, 0, 'deleted vent is not re-added');
    assert.equal(await ventCount(), 0);
    await context.close();
  });
});

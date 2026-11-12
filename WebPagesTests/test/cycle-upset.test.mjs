// "I'm upset" flow: a private four-step stepper stored only in priv.upsets, hand-offs into the existing create screens,
// a follow-up notification and answer, Past list, delete. Runs in Chromium, plus WebKit when GL_WEBKIT_PW/GL_WEBKIT_EXEC are set.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web');
// Served over http, not file://: see cycle-vent.test.mjs (a reloaded file:// document can read an empty localStorage).
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.json': 'application/json', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf' };
const srv = http.createServer((req, res) => {
  const f = path.join(WEB, new URL(req.url, 'http://x').pathname);
  fs.readFile(f, (e, b) => { if (e) { res.statusCode = 404; res.end(); } else { res.setHeader('content-type', MIME[path.extname(f)] || 'application/octet-stream'); res.end(b); } });
});
await new Promise((r) => srv.listen(0, '127.0.0.1', r));
srv.unref();
const URL_ = 'http://127.0.0.1:' + srv.address().port + '/index.html';
const CSS = fs.readFileSync(path.join(WEB, 'cycle.css'), 'utf8') + '\n#fx{display:none}';
const engines = { chromium };
if (process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC) {
  const pw = await import(process.env.GL_WEBKIT_PW);
  engines.webkit = { launch: (o) => pw.webkit.launch({ ...o, executablePath: process.env.GL_WEBKIT_EXEC }) };
}

const UID = 'u-me', PID = 'u-her', HOUR = 36e5;
const ago = (h) => new Date(Date.now() - h * HOUR).toISOString();
const nudge = (id, body, o) => ({ id, body, pinned: false, sort_order: 0, archived_at: null, created_at: ago(5), updated_at: ago(5), deleted_at: null, ...o });
const seed = (privTweak) => {
  const sh = {
    couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [{ user_id: UID, name: 'Me', checkin_time: '21:00', hits_self: false }, { user_id: PID, name: 'Hera Smith', checkin_time: '21:00', hits_self: true }],
    // A partner-tier reminder: the Reminders step must never show it.
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, fight_markers: {}, fight_notes: {}, fight_vents: {}, rewards: {}, redemptions: {},
      nudges: { np: { id: 'np', couple_id: 'c1', author_id: PID, tier: 'partner', body: 'PARTNER-TIER-TEXT', pinned: false, sort_order: 0, archived_at: null, created_at: ago(1), updated_at: ago(1), deleted_at: null } } },
    cursors: {}, outbox: [],
  };
  const priv = { fights: [], affirmations: [], prefs: {} }; // an older install: no upsets yet, the migration must add them
  privTweak?.(priv);
  return { session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } }, ['shared.' + UID]: sh, ['priv.' + UID]: priv };
};

for (const [name, type] of Object.entries(engines)) describe(name, () => {
  let browser;
  before(async () => { browser = await type.launch({ headless: true }); });
  after(async () => { await browser.close(); });

  // suggest: handler body for POST /upset/suggest on the box, or null for no box. native: stub the iOS bridge and record notify calls.
  async function open({ priv, suggest = null, native = false } = {}) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.addInitScript(({ sd, box, native }) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: box ? 'https://box.test' : '' };
      window.__calls = [];
      if (location.search === '?seed') for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
      if (!native) return;
      window.webkit = { messageHandlers: { cycle: { postMessage: ({ id, cmd, args }) => {
        window.__calls.push({ cmd, args });
        let r = null;
        if (cmd === 'store.get') r = localStorage.getItem('cycle:' + args.key);
        else if (cmd === 'store.set') { if (args.value === null) localStorage.removeItem('cycle:' + args.key); else localStorage.setItem('cycle:' + args.key, args.value); }
        else if (cmd === 'store.keys') r = Object.keys(localStorage).filter((k) => k.indexOf('cycle:' + args.prefix) === 0).map((k) => k.slice(6));
        else if (cmd === 'notify.status') r = 'granted';
        else if (cmd === 'lock.get') r = false;
        else if (cmd === 'notify.permission') r = true;
        else if (!['ready', 'notify.schedule', 'notify.cancel', 'app.openSettings'].includes(cmd)) throw new Error('unexpected bridge cmd ' + cmd);
        setTimeout(() => window.__cycleReply(id, r, null), 0);
      } } } };
    }, { sd: seed(priv), box: !!suggest, native });
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    const sent = []; // every request that tried to leave the phone for Supabase
    await context.route('https://x.test/**', (route) => { sent.push(route.request().method() + ' ' + route.request().url() + ' ' + (route.request().postData() || '')); return route.abort(); });
    const suggestCalls = [];
    if (suggest) await context.route('https://box.test/**', (route) => {
      const u = new URL(route.request().url());
      if (u.pathname !== '/upset/suggest') return route.fulfill({ status: 404, body: '' });
      suggestCalls.push(route.request().postDataJSON());
      return suggest(route, suggestCalls.length);
    });
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_ + '?seed', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-a="upset"]');
    return { context, page, sent, suggestCalls };
  }
  const reload = async (page) => { await page.goto(URL_, { waitUntil: 'domcontentloaded' }); await page.waitForSelector('[data-a="upset"]'); };
  const stored = (page) => page.evaluate(() => ({ sh: JSON.parse(localStorage.getItem('cycle:shared.u-me')), pv: JSON.parse(localStorage.getItem('cycle:priv.u-me')) }));
  const calls = (page, cmd) => page.evaluate((c) => window.__calls.filter((x) => x.cmd === c).map((x) => x.args), cmd);
  const steps = (page) => page.$$eval('.tt-s', (els) => els.map((e) => e.textContent.trim()));
  const ok = (route, todos) => route.fulfill({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' }, body: JSON.stringify({ todos }) });
  async function toTurn(page, her = 'she felt ignored', need = 'an evening together') {
    await page.click('[data-a="upset"]');
    await page.fill('textarea[data-d="dump"]', 'my private dump');
    await page.click('[data-a="upnext"]');
    if (await page.locator('[data-a="upprev"]').count() && !(await page.locator('textarea[data-d="her"]').count())) await page.click('[data-a="upnext"]'); // Reminders
    await page.fill('textarea[data-d="her"]', her);
    await page.fill('textarea[data-d="need"]', need);
  }

  test('draft survives a reload mid-step and the Home row resumes it', async () => {
    const { context, page } = await open();
    await page.click('[data-a="upset"]');
    assert.equal(await page.locator('[data-a="upnext"].dis').count(), 1, 'Next disabled while the dump is empty');
    await page.fill('textarea[data-d="dump"]', 'typed before reload');
    await page.waitForFunction(() => (JSON.parse(localStorage.getItem('cycle:priv.u-me')).upsets || []).some((u) => u.dump === 'typed before reload'));
    await reload(page);
    await page.click('[data-a="upset"]');
    assert.equal(await page.inputValue('textarea[data-d="dump"]'), 'typed before reload');
    await page.click('[data-a="upnext"]'); // no Me reminders: straight to Turn it
    await page.fill('textarea[data-d="her"]', 'half written');
    await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:priv.u-me')).upsets[0].her === 'half written');
    await reload(page);
    await page.click('[data-a="upset"]');
    assert.equal(await page.inputValue('textarea[data-d="her"]'), 'half written', 'resumes on the same step with its text');
    assert.equal((await stored(page)).pv.upsets.length, 1);
    await context.close();
  });

  test('Reminders step is skipped with no Me reminders, shown with them (pinned first), never the partner tier', async () => {
    const a = await open();
    await a.page.click('[data-a="upset"]');
    await a.page.fill('textarea[data-d="dump"]', 'x');
    assert.equal((await steps(a.page)).length, 3, 'three steps in the progress row');
    await a.page.click('[data-a="upnext"]');
    await a.page.waitForSelector('textarea[data-d="her"]');
    assert.equal(await a.page.locator('.upr').count(), 0);
    await a.context.close();

    const b = await open({ priv: (p) => { p.nudges = [nudge('n1', 'older me', { created_at: ago(9) }), nudge('n2', 'newest me'), nudge('n3', 'pinned me', { pinned: true, created_at: ago(20) }), nudge('n4', 'gone', { deleted_at: ago(1) }), nudge('n5', 'archived', { archived_at: ago(1) })]; } });
    await b.page.click('[data-a="upset"]');
    await b.page.fill('textarea[data-d="dump"]', 'x');
    assert.equal((await steps(b.page)).length, 4, 'four steps');
    await b.page.click('[data-a="upnext"]');
    await b.page.waitForSelector('.upr');
    assert.deepEqual(await b.page.$$eval('.upr .x', (e) => e.map((x) => x.textContent)), ['pinned me', 'newest me', 'older me']);
    assert.equal(await b.page.$$eval('.upr .s', (e) => e.every((x) => x.textContent.startsWith('Me'))), true);
    assert.equal((await b.page.content()).includes('PARTNER-TIER-TEXT'), false);
    assert.equal(await b.page.locator('.upr [data-a], [data-a^="nudge"]').count(), 0, 'read-only: no add or edit control');
    await b.context.close();
  });

  test('Log fight hand-off prefills the note from the answers, makes a Just-me vent of the dump, and returns marked done', async () => {
    const { context, page } = await open();
    await toTurn(page);
    await page.click('[data-a="upnext"]');
    await page.click('[data-a="upfight"]');
    assert.equal(await page.inputValue('textarea[data-d="note"]'), 'she felt ignored\n\nan evening together');
    await page.click('[data-a="fightsave"]');
    await page.waitForSelector('.upd .dn');
    assert.equal(await page.locator('[data-a="upopen:fight"]').count(), 1, 'row links to the fight it made');
    await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:priv.u-me')).upsets[0].routed.fightId && JSON.parse(localStorage.getItem('cycle:shared.u-me')).outbox.length);
    const { sh, pv } = await stored(page);
    const fid = pv.upsets[0].routed.fightId;
    assert.ok(fid);
    assert.deepEqual(pv.vents.map((v) => [v.fight_marker_id, v.body]), [[fid, 'my private dump']]);
    assert.deepEqual(Object.keys(pv.ventFollow || {}), [], 'no vent follow-up');
    const notes = sh.outbox.filter((o) => o.table === 'fight_notes');
    assert.equal(notes.length, 1);
    assert.equal(notes[0].row.body, 'she felt ignored\n\nan evening together');
    await page.click('[data-a="upopen:fight"]');
    await page.waitForSelector('.vent');
    await context.close();
  });

  test('accepting a suggestion opens the normal composer and Send goes into the held ask, not delivered', async () => {
    const { context, page, sent, suggestCalls } = await open({ suggest: (r) => ok(r, ['Plan Saturday dinner', 'Call the plumber']) });
    await toTurn(page);
    await page.click('[data-a="upnext"]');
    await page.waitForSelector('[data-a="upacc:0"]');
    assert.deepEqual(suggestCalls, [{ her: 'she felt ignored', need: 'an evening together' }], 'dump is never sent to the box');
    await page.click('[data-a="upacc:0"]');
    assert.equal(await page.inputValue('textarea[data-d="nbody"]'), 'Plan Saturday dinner');
    await page.click('[data-a="toasksend"]');
    await page.waitForSelector('.upd .dn');
    await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:priv.u-me')).upsets[0].routed.todoIds.length && JSON.parse(localStorage.getItem('cycle:shared.u-me')).outbox.length);
    const { sh, pv } = await stored(page);
    const asks = sh.outbox.filter((o) => o.table === 'items');
    assert.equal(asks.length, 1);
    assert.equal(asks[0].row.body, 'Plan Saturday dinner');
    assert.ok(Date.parse(asks[0].row.held_until) > Date.now(), 'held, not delivered directly');
    assert.deepEqual(pv.upsets[0].routed.todoIds, [asks[0].row.id]);
    assert.equal(await page.locator('[data-a="upacc:0"]').count(), 0, 'accepted suggestion is gone');
    assert.equal(await page.locator('[data-a="upacc:1"]').count(), 1);
    // Re-entering Where it goes does not refetch.
    await page.click('[data-a="upprev"]'); await page.click('[data-a="upnext"]');
    await page.waitForSelector('[data-a="upacc:1"]');
    assert.equal(suggestCalls.length, 1);
    assert.equal(sent.some((s) => s.includes('my private dump')), false);
    await context.close();
  });

  test('suggest failure shows Retry, the manual to-do row still works, Retry recovers', async () => {
    const { context, page, suggestCalls } = await open({ suggest: (r, n) => (n === 1 ? r.fulfill({ status: 502, headers: { 'access-control-allow-origin': '*' }, body: '{}' }) : ok(r, ['Plan dinner'])) });
    await page.addInitScript(() => {});
    await toTurn(page);
    page.on('console', () => {});
    await page.click('[data-a="upnext"]');
    await page.waitForSelector('[data-a="upsug"]');
    assert.ok((await page.textContent('.ups')).includes('Couldn’t load'));
    await page.click('[data-a="uptodo"]');
    assert.equal(await page.inputValue('textarea[data-d="nbody"]'), '', 'manual row: empty title');
    await page.click('[data-a="back"]');
    await page.click('[data-a="upsug"]');
    await page.waitForSelector('[data-a="upacc:0"]');
    assert.equal(suggestCalls.length, 2);
    await context.close();
  });

  test('Raise issue is prefilled with the need and marks done; Talk it through needs a fight', async () => {
    const { context, page } = await open();
    await toTurn(page);
    await page.click('[data-a="upnext"]');
    assert.equal(await page.locator('.upd.dis').count() >= 1, true, 'Talk it through disabled without a fight');
    await page.click('[data-a="upissue"]');
    assert.equal(await page.inputValue('textarea[data-d="ibody"]'), 'an evening together');
    await page.click('[data-a="issuesave"]');
    await page.waitForSelector('[data-a="upopen:issue"]');
    await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:priv.u-me')).upsets[0].routed.issueId);
    await context.close();
  });

  test('nothing from an upset is uploaded or queued: no Supabase request, no outbox row with its text', async () => {
    const { context, page, sent } = await open();
    await toTurn(page);
    await page.click('[data-a="upnext"]');
    await page.click('[data-a="upkeep"]');
    await page.waitForSelector('[data-a="upset"]');
    await page.waitForFunction(() => (JSON.parse(localStorage.getItem('cycle:priv.u-me')).upsets[0] || {}).done_at);
    await page.waitForTimeout(500);
    const { sh, pv } = await stored(page);
    assert.deepEqual(sh.outbox, []);
    assert.equal(sent.filter((s) => /my private dump|she felt ignored|an evening together/.test(s)).length, 0);
    assert.equal(sent.filter((s) => s.startsWith('POST') && !s.includes('/auth/')).length, 0, 'no insert of any kind');
    assert.equal(pv.upsets[0].dump, 'my private dump');
    await context.close();
  });

  test('follow-up: schedules a notification with no written text; answering saves a Me reminder; Redo; Past; Delete cancels', async () => {
    const { context, page } = await open({ native: true });
    await toTurn(page);
    await page.click('[data-a="upnext"]');
    await page.click('[data-a="upfu:12"]');
    await page.click('[data-a="updone"]');
    await page.waitForFunction(() => window.__calls.some((c) => c.cmd === 'notify.schedule' && c.args.id.startsWith('upsetfu-')));
    const { pv } = await stored(page);
    const u = pv.upsets[0];
    const [a] = (await calls(page, 'notify.schedule')).filter((x) => x.id.startsWith('upsetfu-'));
    assert.equal(a.id, 'upsetfu-' + u.id); assert.equal(a.route, 'upset/' + u.id);
    assert.equal(a.title, 'Follow up');
    assert.equal(/dump|ignored|evening|Hera/.test(JSON.stringify(a)), false, 'no written text, no partner name');
    assert.ok(Math.abs(Date.parse(u.follow.at) - Date.now() - 12 * HOUR) < 60e3);

    // The notification's route opens the upset's page, still showing when the follow-up is due.
    await page.evaluate((id) => window.cycleNative.route('upset/' + id), u.id);
    await page.waitForSelector('.upk .meta');
    assert.ok((await page.textContent('.upk')).includes('my private dump'));
    await page.click('[data-a="back"]');
    await page.click('[data-a="upset"]');
    await page.click('[data-a="uppast"]');
    assert.equal(await page.locator('[data-a^="updetail:"]').count(), 1);
    await page.click('[data-a^="updetail:"]');
    await page.click('[data-a="updel"]');
    await page.click('[data-a="updelok"]');
    await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:priv.u-me')).upsets.length === 0);
    await page.waitForFunction((id) => window.__calls.some((c) => c.cmd === 'notify.cancel' && JSON.stringify(c.args).includes('upsetfu-' + id)), u.id);
    await context.close();
  });
  test('a due follow-up: outcome plus notes, a filled reminder becomes a Me reminder, Redo reopens it', async () => {
    const id = 'up-due';
    const { context, page } = await open({ priv: (p) => { p.upsets = [{ id, created_at: ago(30), updated_at: ago(30), step: 'where', dump: 'my private dump', her: 'h', need: 'n', done_at: ago(25), routed: { fightId: null, todoIds: [], issueId: null, talk: false }, follow: { at: ago(1), hours: 24, done: null }, sug: null }]; } });
    await page.evaluate((id) => window.cycleNative.route('upset/' + id), id);
    await page.waitForSelector('[data-a^="upfo:"]');
    assert.ok((await page.textContent('.upk')).includes('my private dump'));
    assert.equal(await page.locator('[data-a="upfsave"].dis').count(), 1, 'Save waits for an outcome');
    await page.click('[data-a^="upfo:"]');
    await page.fill('textarea[data-d="upft"]', 'it passed');
    await page.fill('textarea[data-d="upfr"]', 'Take a walk first');
    await page.click('[data-a="upfsave"]');
    await page.waitForSelector('[data-a="upredo"]');
    await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:priv.u-me')).nudges.length === 1);
    const s = (await stored(page)).pv;
    assert.equal(s.upsets[0].follow.done.text, 'it passed');
    assert.deepEqual(s.nudges.map((n) => [n.body, n.deleted_at, n.archived_at]), [['Take a walk first', null, null]], 'saved as a Me reminder');
    await page.click('[data-a="upredo"]'); await page.click('[data-a="upredook"]');
    await page.waitForSelector('[data-a^="upfo:"]');
    assert.equal(await page.locator('[data-a="upredo"]').count(), 0);
    await context.close();
  });
});

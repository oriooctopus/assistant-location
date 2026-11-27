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
const seed = (privTweak, me = UID) => {
  const sh = {
    couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [{ user_id: me, name: 'Me', checkin_time: '21:00', hits_self: false }, { user_id: PID, name: 'Hera Smith', checkin_time: '21:00', hits_self: true }],
    // A partner-tier reminder: the Reminders step must never show it.
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, fight_markers: {}, fight_notes: {}, fight_vents: {}, rewards: {}, redemptions: {},
      nudges: { np: { id: 'np', couple_id: 'c1', author_id: PID, tier: 'partner', body: 'PARTNER-TIER-TEXT', pinned: false, sort_order: 0, archived_at: null, created_at: ago(1), updated_at: ago(1), deleted_at: null } } },
    cursors: {}, outbox: [],
  };
  const priv = { fights: [], affirmations: [], prefs: {} }; // an older install: no upsets yet, the migration must add them
  privTweak?.(priv);
  return { session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: me, email: 'me@x.test' } }, ['shared.' + me]: sh, ['priv.' + me]: priv };
};

for (const [name, type] of Object.entries(engines)) describe(name, () => {
  let browser;
  before(async () => { browser = await type.launch({ headless: true }); });
  after(async () => { await browser.close(); });

  // suggest: handler body for POST /upset/suggest on the box, or null for no box. native: stub the iOS bridge and record notify calls.
  async function open({ priv, suggest = null, native = false, uid } = {}) {
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
    }, { sd: seed(priv, uid), box: !!suggest, native });
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
    assert.deepEqual(await b.page.$$eval('.upr .upt', (e) => e.map((x) => x.textContent)), ['pinned me', 'newest me', 'older me']);
    // A global `.x` rule once squeezed the text into a 44px column; this pins that the text spans the card.
    assert.equal(await b.page.$$eval('.upr .upt', (e) => e.every((x) => x.getBoundingClientRect().width > 200)), true);
    assert.equal(await b.page.$$eval('.upr .s',(e) => e.every((x) => x.textContent.startsWith('Me'))), true);
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
    assert.equal(await page.locator('.upc.dis').count() >= 1, true, 'Talk it through disabled without a fight');
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
    assert.equal((await page.textContent('.hd h2')).trim(), 'Past', 'delete returns to Past, not Home');
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
  test('Where cards: chevron and read-only previews, suggestions inside the To-do card, 18px icons in 44px targets; Dump has no label and a draft line', async () => {
    const { context, page } = await open({ suggest: (r) => ok(r, ['Plan Saturday dinner', 'Call the plumber']) });
    await page.click('[data-a="upset"]');
    assert.equal(await page.locator('.upk .tt-f .lab').count(), 0, 'no "Dump it" label');
    await page.fill('textarea[data-d="dump"]', 'my private dump');
    await page.click('[data-a="upnext"]');
    if (!(await page.locator('textarea[data-d="her"]').count())) await page.click('[data-a="upnext"]');
    assert.match(await page.textContent('.hd .dl'), /^Draft saved \d{1,2}:\d{2}(am|pm)$/);
    await page.fill('textarea[data-d="her"]', 'she felt ignored');
    await page.fill('textarea[data-d="need"]', 'an evening together');
    await page.click('[data-a="upnext"]');
    await page.waitForSelector('.upc .ups [data-a="upacc:0"]');
    assert.equal(await page.locator('.upd .chv').count() >= 4, true, 'chevron on every enabled row');
    assert.equal(await page.locator('.upd .mt').count(), 0, 'no plus');
    const fight = await page.textContent('.upc:nth-of-type(1)');
    assert.ok(fight.includes('Note') && fight.includes('she felt ignored') && fight.includes('an evening together') && fight.includes('Vent') && fight.includes('my private dump'));
    assert.ok((await page.textContent('.upc:nth-of-type(2) .pvt')).includes('Send hold'));
    const box = await page.$eval('[data-a="upacc:0"]', (a) => { const i = a.querySelector('.upi').getBoundingClientRect(), r = a.getBoundingClientRect(); return [i.width, i.height, r.width, r.height]; });
    assert.deepEqual(box, [18, 18, 44, 44]);
    const dbox = await page.$eval('[data-a="updis:0"]', (a) => { const i = a.querySelector('.upi').getBoundingClientRect(), r = a.getBoundingClientRect(); return [i.width, i.height, r.width, r.height]; });
    assert.deepEqual(dbox, [18, 18, 44, 44]);
    await page.click('[data-a="updis:0"]');
    assert.equal(await page.locator('[data-a="upacc:0"]').count(), 0, 'dismissed suggestion is gone at once');
    await page.click('[data-a="updone"]');
    await page.waitForFunction(() => (JSON.parse(localStorage.getItem('cycle:priv.u-me')).upsets[0] || {}).done_at);
    const log = (await stored(page)).pv.upsets[0].log.map((e) => e.kind);
    assert.deepEqual(log, ['created', 'done']);
    await context.close();
  });

  test('detail: Went to (None), history, Edit/Delete at the bottom; Past pill when the follow up is due; chips 2x2', async () => {
    const id = 'up-due';
    const { context, page } = await open({ priv: (p) => { p.upsets = [{ id, created_at: ago(30), updated_at: ago(30), step: 'where', dump: 'my private dump', her: 'h', need: 'n', done_at: ago(25), routed: { fightId: null, todoIds: [], issueId: null, talk: false }, follow: { at: ago(1), hours: 24, done: null }, sug: null }]; } });
    await page.click('[data-a="upset"]');
    await page.click('[data-a="uppast"]');
    assert.equal(await page.locator('.upr .fp').count(), 1, 'Follow up pill on a due, unanswered upset');
    await page.click('[data-a="updetail:' + id + '"]');
    await page.waitForSelector('[data-a="upfsave"]');
    assert.equal((await page.textContent('.upk')).includes('None'), true, 'Went to: None');
    assert.ok((await page.textContent('.upk')).includes('History') && (await page.textContent('.upk')).includes('Logged'));
    const chips = await page.$$eval('.upk .chips .lk', (els) => els.map((e) => { const r = e.getBoundingClientRect(); return [Math.round(r.left), Math.round(r.top), Math.round(r.height)]; }));
    assert.equal(chips.length, 4);
    assert.equal(chips.every((c) => c[2] >= 44), true);
    assert.equal(chips[0][1], chips[1][1], 'two per row');
    assert.equal(chips[2][1], chips[3][1]);
    const gap = await page.$eval('.upk .lab.frl', (l) => { const prev = l.previousElementSibling.getBoundingClientRect(), r = l.getBoundingClientRect(); return Math.round(r.top - prev.bottom); });
    assert.equal(gap >= 24, true, 'standard section gap above Reminder for next time, got ' + gap);
    const last = await page.$$eval('.upk .pair .ghost', (els) => els.map((e) => e.textContent));
    assert.deepEqual(last, ['Edit', 'Delete']);
    await context.close();
  });

  // ---- quick finish + check-ins ----
  const quickUp = (id, o) => ({ id, created_at: ago(2), updated_at: ago(2), step: 'dump', dump: 'quick dump text', her: '', need: '', done_at: ago(2), quick: true, checks: [], routed: { fightId: null, todoIds: [], issueId: null, talk: false }, follow: { at: null, hours: 0, done: null }, sug: null, log: [{ at: ago(2), kind: 'created' }, { at: ago(2), kind: 'done' }], ...o });
  const chkCall = async (page) => (await calls(page, 'notify.schedule')).filter((c) => c.id.startsWith('upsetchk-')).pop();

  test('Dump: Finish is disabled when empty, then logs done, returns Home with a check-in row and schedules the first check at +1h', async () => {
    const { context, page } = await open({ native: true });
    await page.click('[data-a="upset"]');
    assert.equal(await page.locator('[data-a="upquick"].dis').count(), 1, 'Finish dimmed with an empty dump');
    assert.equal(await page.locator('[data-a="upnext"].dis').count(), 1);
    await page.fill('textarea[data-d="dump"]', 'quick dump text');
    assert.equal(await page.locator('[data-a="upquick"].dis').count(), 0, 'Finish live once there is text');
    await page.click('[data-a="upquick"]');
    await page.waitForSelector('[data-a="upset"]');
    assert.equal(await page.locator('.upck').count(), 0, 'no Home check-in row before the first hour is up');
    await page.waitForTimeout(300); const u = (await stored(page)).pv.upsets[0];
    assert.equal(u.quick, true);
    assert.deepEqual(u.log.map((e) => e.kind), ['created', 'done']);
    await page.waitForFunction(() => window.__calls.some((c) => c.cmd === 'notify.schedule' && c.args.id.startsWith('upsetchk-')));
    const c = await chkCall(page);
    assert.equal(c.category, 'upsetcheck');
    assert.equal(c.title, 'Still feeling this?');
    assert.match(c.body, /^Since \d{1,2}:\d\d(am|pm)$/);
    assert.equal(c.body.includes('quick dump'), false, 'no dump text in the notification');
    assert.equal(c.route, 'upset/' + u.id);
    assert.ok(Math.abs(c.at - (Date.parse(u.created_at) + HOUR)) < 1000, 'first check at created + 1h');
    await context.close();
  });

  test('detail: a note is added straight from the page, kept on the record and in History, and saved on the private record', async () => {
    const id = 'up-n1';
    const { context, page } = await open({ priv: (p) => { p.upsets = [quickUp(id, { created_at: ago(5), log: [{ at: ago(5), kind: 'created' }, { at: ago(5), kind: 'done' }] })]; } });
    await page.click('[data-a="updetail:' + id + '"]');
    assert.equal(await page.isVisible('[data-a="upnotesave"]'), false, 'no Save until there is text');
    await page.fill('.upnotes textarea', 'Also she forgot to call back');
    assert.equal(await page.isVisible('[data-a="upnotesave"]'), true);
    await page.click('[data-a="upnotesave"]');
    await page.waitForSelector('.upnote');
    assert.equal(await page.textContent('.upnote p:last-child'), 'Also she forgot to call back');
    assert.equal(await page.inputValue('.upnotes textarea'), '', 'box clears for the next note');
    assert.deepEqual(await page.$$eval('.uptl .lb', (els) => els.map((e) => e.textContent)), ['Logged', 'Added note']);
    await page.waitForTimeout(300); const u = (await stored(page)).pv.upsets[0];
    assert.deepEqual(u.notes.map((n) => n.text), ['Also she forgot to call back']);
    assert.deepEqual(u.log.map((e) => e.kind), ['created', 'done', 'note']);
    await context.close();
  });

  test('detail: Talk about it opens a new chat with the dump and notes in the box, or the chat the upset came from', async () => {
    // Chat exists only for the insights account (C.INSIGHTS_UID), with a box url configured: anyone else gets no row.
    const box = (r) => ok(r, []), OLIVER = '78b76b33-e11c-4491-baa4-28aa38bd17c6';
    const o0 = await open({ priv: (p) => { p.upsets = [quickUp('up-c0')]; } });
    await o0.page.click('[data-a="updetail:up-c0"]');
    await o0.page.waitForSelector('.updt');
    assert.equal(await o0.page.locator('[data-a="upchat"]').count(), 0, 'no Talk about it without Chat');
    await o0.context.close();
    const { context, page } = await open({ uid: OLIVER, suggest: box, priv: (p) => { p.upsets = [quickUp('up-c1', { notes: [{ at: ago(1), text: 'she said sorry later' }] }), quickUp('up-c2', { from: 'chat', conv: 'conv-from' })]; } });
    await page.click('[data-a="updetail:up-c1"]');
    assert.equal(await page.locator('[data-a="upturn"]').count(), 0, 'no Turn it row on the detail page');
    assert.equal(await page.locator('.upan [data-a="upchat"]').count(), 1, 'Talk about it is the round button beside Still feeling it / It passed');
    await page.click('[data-a="upchat"]');
    await page.waitForSelector('.insbar textarea[data-d="ins_msg"]');
    assert.equal(await page.inputValue('.insbar textarea[data-d="ins_msg"]'), 'quick dump text\n\nshe said sorry later');
    await context.close();
    // An upset the chat spotted: the row reopens that conversation instead of starting a new one.
    const o2 = await open({ uid: OLIVER, suggest: box, priv: (p) => { p.upsets = [quickUp('up-c2', { from: 'chat', conv: 'conv-from' })]; } });
    await o2.page.click('[data-a="updetail:up-c2"]');
    await o2.page.click('[data-a="upchat"]');
    await o2.page.waitForSelector('.insbar textarea[data-d="ins_msg"]');
    await o2.page.waitForFunction(() => /conv-from/.test(location.href));
    assert.equal(await o2.page.inputValue('.insbar textarea[data-d="ins_msg"]'), '', 'no dump pasted into the existing chat');
    await o2.context.close();
  });
  test('detail: Still schedules the next check 3h out, Passed shows a Lasted range, editing the passed time gives an exact length', async () => {
    const id = 'up-q1';
    const { context, page } = await open({ native: true, priv: (p) => { p.upsets = [quickUp(id, { created_at: ago(5), log: [{ at: ago(5), kind: 'created' }, { at: ago(5), kind: 'done' }] })]; } });
    await page.click('[data-a="updetail:' + id + '"]');
    await page.click('[data-a="upstill"]');
    await page.waitForSelector('.uptl.wh');
    const t0 = Date.now();
    await page.waitForFunction(() => window.__calls.some((c) => c.cmd === 'notify.schedule' && c.args.id.startsWith('upsetchk-') && /2nd/.test(c.args.body)));
    const c = await chkCall(page);
    assert.ok(Math.abs(c.at - (t0 + 3 * HOUR)) < 5000, 'next check 3h after the answer');
    assert.match(c.body, /· 2nd$/);
    assert.equal(await page.locator('[data-a="uppassed"]').count(), 1, 'still pending: the pair stays');
    await page.click('[data-a="uppassed"]');
    await page.waitForSelector('.uplast');
    assert.match(await page.textContent('.uplast .upbig'), /^\d+-\d+h$/);
    assert.equal(await page.locator('[data-a="upstill"]').count(), 0);
    assert.equal(await page.locator('.upck').count(), 0, 'no more checks once passed');
    const tl = await page.$$eval('.uptl .lb', (els) => els.map((e) => e.textContent));
    assert.deepEqual(tl, ['Logged', 'Still on', 'Passed']);
    // Editing the passed time makes the headline exact. The edit is only valid inside [last still, passed answer]; both were just
    // answered, so use the midpoint between them.
    await page.waitForTimeout(300); const u0 = (await stored(page)).pv.upsets[0];
    const still = Date.parse(u0.checks.find((x) => x.ans === 'still').at), pas = Date.parse(u0.checks.find((x) => x.ans === 'passed').at);
    const mid = new Date((still + pas) / 2 - ((still + pas) / 2) % 60000);
    const hm2 = mid.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZone: 'America/New_York' });
    await page.click('[data-a="uppsheet"]');
    await page.fill('#uptm', hm2);
    await page.click('[data-a="upptsave"]');
    await page.waitForSelector('.uplast');
    assert.match(await page.textContent('.uplast .upbig'), /^\d+h( \d+m)?$|^\d+m$/, 'exact length, no range dash');
    await page.waitForTimeout(300); const u1 = (await stored(page)).pv.upsets[0];
    assert.ok(u1.passedAt);
    assert.equal(u1.log.filter((e) => e.kind === 'edited').length, 1);
    assert.equal(u1.checks.length, 2, 'answers untouched by the time edit');
    await context.close();
  });

  // The label's logged time as Home prints it: the clock alone for today, else "Wed 11:55pm".
  const NY = { timeZone: 'America/New_York' };
  const stamp = (iso) => {
    const d = new Date(iso), clock = d.toLocaleTimeString('en-US', { ...NY, hour: 'numeric', minute: '2-digit' }).toLowerCase().replace(' ', '');
    return d.toLocaleDateString('en-US', NY) === new Date().toLocaleDateString('en-US', NY) ? clock : d.toLocaleDateString('en-US', { ...NY, weekday: 'short' }) + ' ' + clock;
  };
  test('Home row names when the upset was logged: the clock for today, weekday and clock for an earlier day', async () => {
    const { context, page } = await open({ priv: (p) => { p.upsets = [quickUp('up-l1', { created_at: ago(30), dump: 'x' }), quickUp('up-l2', { created_at: ago(1.5) })]; } });
    const rows = await page.$$eval('.upck', (els) => els.map((e) => e.textContent));
    assert.deepEqual(rows, ['Upset \u00b7 ' + stamp(ago(30)) + 'Still feeling this?', 'Upset \u00b7 ' + stamp(ago(1.5)) + 'Still feeling this?']);
    assert.match(rows[0], /^Upset \u00b7 (Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2}:\d\d(am|pm)Still/, 'an earlier day carries its weekday');
    await context.close();
  });

  test('due upset sits inside the Home To do section and its count, and on the To-dos tab; tapping opens the detail', async () => {
    const id = 'up-t1';
    const { context, page } = await open({ priv: (p) => { p.upsets = [quickUp(id)]; } });
    assert.equal(await page.locator('.nd:has(> .lab) > .upck').count(), 1, 'row is a direct child of the To do section');
    assert.equal(await page.locator('.upn').count(), 0, 'no separate block above the tiles');
    const nRows = await page.locator('.nd:has(> .lab) > .nc').count();
    assert.equal(await page.locator('.nd:has(> .lab) > .nc.upck:first-of-type, .nd > .lab + .upck').count(), 1, 'first row in the section');
    assert.equal((await page.textContent('.nd .lab')).replace(/\s+/g, ' '), 'To do \u00b7 ' + nRows, 'counted in the To do count');
    assert.equal(await page.locator('.nd:has(> .upck) > .empty').count(), 0, 'no None while an upset row is due');
    await page.click('.tabbar [data-a="tab:todo"]');
    await page.waitForSelector('.td-row.upck');
    assert.equal(await page.locator('.td-row.upck').count(), 1);
    assert.match(await page.textContent('.td-row.upck'), /Still feeling this\?/);
    assert.match(await page.textContent('.hd .dl'), /^You 1\b/, 'counted in You');
    assert.equal(await page.locator('.td-row.upck [data-a^="done"], .td-row.upck[data-sw]').count(), 0, 'no Done or swipe');
    await page.click('.td-row.upck');
    await page.waitForSelector('.upnotes');
    assert.equal(Object.keys((await stored(page)).sh.rows.todos).length, 0, 'never in the shared store');
    await context.close();
  });

  test('custom check-in (q): plain notification at firstAt titled with the question, Home row and detail show q, Done ends it, no Still', async () => {
    const id = 'up-q1', later = 'up-q2';
    const { context, page } = await open({ native: true, priv: (p) => { p.upsets = [
      quickUp(id, { created_at: ago(9), q: 'How much work did Esme get done?', short: 'her work today', firstAt: ago(0.01), from: 'chat' }),
      quickUp(later, { created_at: ago(0.1), q: 'Later one?', short: 'later', firstAt: new Date(Date.now() + 8 * HOUR).toISOString(), from: 'chat' })]; } });
    assert.equal(await page.locator('.upck').count(), 1, 'only the due check-in is a Home row');
    assert.equal(await page.textContent('.upck .x'), 'How much work did Esme get done?');
    await page.waitForFunction(() => window.__calls.some((c) => c.cmd === 'notify.schedule' && c.args.id === 'upsetchk-up-q2'));
    const c = await chkCall(page);
    assert.equal(c.title, 'Later one?'); assert.equal(c.body, 'later');
    assert.equal(c.category, undefined, 'plain notification, no buttons'); assert.equal(c.next, undefined);
    assert.equal(c.route, 'upset/' + later);
    assert.ok(Math.abs(c.at - (Date.now() + 8 * HOUR)) < 5000, 'first ask at firstAt');
    await page.click('[data-a="updetail:' + id + '"]');
    assert.match(await page.textContent('.tt-f .tt-body'), /How much work did Esme get done\?/);
    assert.equal(await page.locator('[data-a="upstill"]').count(), 0, 'no Still feeling it');
    assert.equal(await page.textContent('.upan .save'), 'Done');
    assert.equal(await page.locator('.upszb').count(), 1, 'snooze stays');
    await page.click('[data-a="uppassed"]');
    await page.waitForSelector('.upan', { state: 'detached' });
    assert.equal(await page.locator('.upszb').count(), 0, 'one-shot: nothing pending after Done');
    assert.deepEqual(await page.$$eval('.uptl .lb', (els) => els.map((e) => e.textContent)), ['Logged', 'Done']);
    await page.click('.hd [data-a="back"]');
    await page.waitForSelector('[data-a="upset"]');
    assert.equal(await page.locator('.upck').count(), 0, 'answered: no row');
    await context.close();
  });

  test('due check-in: Home row, Due-style snooze sheet moves the ask and hides the row; Still answer supersedes it; not-yet-due shows no row', async () => {
    const id = 'up-s1', early = 'up-s0';
    const { context, page } = await open({ native: true, priv: (p) => { p.upsets = [quickUp(id), quickUp(early, { created_at: new Date(Date.now() - 20 * 60000).toISOString() })]; } });
    assert.equal(await page.locator('.upck').count(), 1, 'only the due one is on Home');
    assert.equal(await page.textContent('.upck .x'), 'Still feeling this?');
    await page.click('[data-a="updetail:' + id + '"]');
    assert.equal(await page.textContent('.upszb'), 'Snooze');
    await page.click('.upszb');
    assert.deepEqual(await page.$$eval('.upszg span', (els) => els.map((e) => e.textContent)),
      ['9:30am', '12pm', '6:30pm', '10pm', '+10m', '+1h', '+3h', '+1d', '\u221210m', '\u22121h', '\u22123h', '\u22121d']);
    assert.equal(await page.textContent('.upszbar em'), 'Past', 'starts at now');
    assert.equal(await page.locator('[data-a="upszok"].dis').count(), 1, 'OK off until the time is ahead');
    const t0 = Date.now();
    await page.click('[data-a="upszp:1:1"]'); await page.click('[data-a="upszp:1:0"]'); await page.click('[data-a="upszp:2:0"]');
    assert.equal(await page.textContent('.upszbar em'), 'in 1h');
    await page.click('[data-a="upszok"]');
    await page.waitForSelector('.upszs', { state: 'detached' });
    await page.waitForFunction(() => window.__calls.some((c) => c.cmd === 'notify.schedule' && c.args.id === 'upsetchk-up-s1'));
    const c = (await calls(page, 'notify.schedule')).filter((x) => x.id === 'upsetchk-up-s1').pop();
    assert.ok(Math.abs(c.at - (t0 + HOUR)) < 5000, 'next ask 1h out');
    assert.match(await page.textContent('.upszb'), /\d{1,2}:\d\d(am|pm)$/, 'header shows the next ask');
    assert.deepEqual(await page.$$eval('.uptl .lb', (els) => els.map((e) => e.textContent)), ['Logged', 'Snoozed']);
    await page.click('[data-a="upstill"]');
    await page.waitForSelector('.uptl.wh');
    await page.waitForTimeout(300);
    const c2 = (await calls(page, 'notify.schedule')).filter((x) => x.id === 'upsetchk-up-s1').pop();
    assert.ok(Math.abs(c2.at - (Date.now() + 3 * HOUR)) < 5000, 'a Still answer replaces the snooze with the normal +3h');
    await page.click('.hd [data-a="back"]');
    await page.waitForSelector('[data-a="upset"]');
    assert.equal(await page.locator('.upck').count(), 0, 'nothing due on Home');
    await context.close();
  });

  test('snooze before due: header shows the pending time, the sheet starts there, X discards, a past pick disables OK, saved snooze survives reload', async () => {
    const id = 'up-s2', made = Date.now() - 20 * 60000;
    const { context, page } = await open({ native: true, priv: (p) => { p.upsets = [quickUp(id, { created_at: new Date(made).toISOString() })]; } });
    assert.equal(await page.locator('.upck').count(), 0, 'not due: no Home row');
    await page.evaluate((i) => window.cycleNative.route('upset/' + i), id);
    await page.waitForSelector('.upszb');
    assert.match(await page.textContent('.upszb'), /\d{1,2}:\d\d(am|pm)$/, 'not due: header names the pending ask');
    await page.click('.upszb');
    assert.equal(await page.textContent('.upszbar em'), 'in 40m', 'draft starts at the pending ask (+1h from logging)');
    await page.click('[data-a="upszp:2:3"]'); // -1d
    assert.equal(await page.textContent('.upszbar em'), 'Past');
    assert.equal(await page.locator('[data-a="upszok"].dis').count(), 1);
    await page.$eval('[data-a="upszok"]', (e) => e.click()); // tap through the disabled style: the handler must still refuse
    assert.equal(await page.locator('.upszs').count(), 1, 'OK on a past time does nothing');
    await page.click('.upszs [data-a="sheet:close"]');
    await page.waitForSelector('.upszs', { state: 'detached' });
    await page.waitForTimeout(300);
    let u = (await stored(page)).pv.upsets[0];
    assert.equal(u.snooze, undefined, 'X saves nothing');
    assert.deepEqual(u.log.map((e) => e.kind), ['created', 'done']);
    await page.click('.upszb');
    assert.equal(await page.textContent('.upszbar em'), 'in 40m', 'reopening starts fresh from the pending ask');
    await page.click('[data-a="upszp:1:2"]'); // +3h
    assert.equal(await page.textContent('.upszbar em'), 'in 3h 40m');
    await page.click('[data-a="upszok"]');
    await page.waitForTimeout(400);
    const c = (await calls(page, 'notify.schedule')).filter((x) => x.id === 'upsetchk-' + id).pop();
    assert.ok(Math.abs(c.at - (made + 4 * HOUR)) < 2000, 'ask moved to logged + 1h + 3h');
    await reload(page);
    await page.evaluate((i) => window.cycleNative.route('upset/' + i), id);
    await page.waitForSelector('.upszb');
    assert.match(await page.textContent('.upszb'), /\d{1,2}:\d\d(am|pm)$/, 'header still shows a time after reload');
    u = (await stored(page)).pv.upsets[0];
    assert.ok(Math.abs(Date.parse(u.snooze.until) - (made + 4 * HOUR)) < 2000, 'snooze persisted');
    assert.deepEqual(await page.$$eval('.uptl .lb', (els) => els.map((e) => e.textContent)), ['Logged', 'Snoozed']);
    await context.close();
  });

  test('an expired snooze is due again (Home row back, header Snooze); Passed after a snooze ends checks and cancels the ask', async () => {
    const id = 'up-s3', t = (h) => new Date(Date.now() - h * HOUR).toISOString();
    const { context, page } = await open({ native: true, priv: (p) => { p.upsets = [quickUp(id, { created_at: t(3), snooze: { at: t(2), until: t(0.5) }, log: [{ at: t(3), kind: 'created' }, { at: t(3), kind: 'done' }, { at: t(2), kind: 'snoozed' }] })]; } });
    assert.equal(await page.locator('.upck').count(), 1, 'snooze over: due again on Home');
    await page.click('[data-a="updetail:' + id + '"]');
    assert.equal(await page.textContent('.upszb'), 'Snooze');
    await page.click('[data-a="uppassed"]');
    await page.waitForSelector('.uplast');
    assert.equal(await page.locator('.upszb').count(), 0, 'no snooze once passed');
    await page.waitForTimeout(400);
    const u = (await stored(page)).pv.upsets[0];
    assert.deepEqual(u.checks.map((c) => c.ans), ['passed']);
    assert.equal((await calls(page, 'notify.schedule')).some((x) => x.id === 'upsetchk-' + id), false, 'no ask scheduled after Passed');
    await page.click('.hd [data-a="back"]');
    await page.waitForSelector('[data-a="upset"]');
    assert.equal(await page.locator('.upck').count(), 0);
    await context.close();
  });

  test('a seeded upsetAnswers store key drains once, and a second drain changes nothing', async () => {
    const id = 'up-q2';
    const { context, page } = await open({ native: true, priv: (p) => { p.upsets = [quickUp(id, { created_at: ago(2), log: [{ at: ago(2), kind: 'created' }, { at: ago(2), kind: 'done' }] })]; } });
    const at = new Date(Date.now() - 60000).toISOString();
    const key = 'cycle:upsetAnswers:' + id + ':' + at;
    await page.evaluate(([k, v]) => localStorage.setItem(k, v), [key, JSON.stringify({ id, ans: 'still', at })]);
    const drain = () => page.evaluate(() => window.cycleNative.foreground());
    await drain();
    await page.waitForFunction((k) => localStorage.getItem(k) === null, key);
    await page.waitForTimeout(300); const u1 = (await stored(page)).pv.upsets[0];
    assert.deepEqual(u1.checks, [{ at, ans: 'still' }]);
    assert.equal(u1.log.filter((e) => e.kind === 'still').length, 1);
    // The same answer delivered again (a replayed key) is deduped by id + at.
    await page.evaluate(([k, v]) => localStorage.setItem(k, v), [key, JSON.stringify({ id, ans: 'still', at })]);
    await drain();
    await page.waitForFunction((k) => localStorage.getItem(k) === null, key);
    await page.waitForTimeout(300); const u2 = (await stored(page)).pv.upsets[0];
    assert.equal(u2.checks.length, 1);
    assert.equal(u2.log.filter((e) => e.kind === 'still').length, 1);
    await context.close();
  });

  test('Past: summary card with the median of the last passed, chips per row', async () => {
    // lastedH: exact length via passedAt (null = still ongoing). Lengths 0.5h, 1h, 2h: median 1h; chips <1h, 1-3h, 1-3h.
    const mk = (id, h, lastedH) => quickUp(id, { created_at: ago(h), log: [{ at: ago(h), kind: 'created' }, { at: ago(h), kind: 'done' }],
      checks: lastedH == null ? [] : [{ at: ago(h - lastedH), ans: 'passed' }], passedAt: lastedH == null ? undefined : ago(h - lastedH) });
    const { context, page } = await open({ priv: (p) => { p.upsets = [mk('a', 100, 0.5), mk('b', 80, 1), mk('c', 60, 2), mk('d', 30, null)]; } });
    await page.click('[data-a="upset"]');
    await page.click('[data-a="uppast"]');
    assert.match(await page.textContent('.upsum .upsh'), /^Last 4 . 1h median$/);
    assert.equal(await page.locator('.upsum .upbars i').count(), 4);
    assert.equal(await page.locator('.upsum .upbars i.on').count(), 1, 'ongoing is an outline');
    const chips = await page.$$eval('.uprow', (rows) => rows.map((r) => (r.querySelector('.upchip') || {}).textContent));
    assert.deepEqual(chips, ['Still on', '1-3h', '1-3h', '<1h'], 'newest first');
    await context.close();
  });
});

test('upsetCheckBody leads with the chat-given short label when there is one, else just the time', async () => {
  const { default: C } = await import('./cycle-load.mjs');
  const u = { created_at: '2026-11-26T17:57:00Z' }; // 12:57pm New York (EST)
  assert.equal(C.upsetCheckBody(u, 'America/New_York', 0), 'Since 12:57pm');
  assert.equal(C.upsetCheckBody({ ...u, short: "she doesn't try" }, 'America/New_York', 0), "she doesn't try · since 12:57pm");
  assert.equal(C.upsetCheckBody({ ...u, short: 'x' }, 'America/New_York', 1), 'x · since 12:57pm · 2nd');
});

test('upsetNextCheck for a custom check-in: asks once at firstAt, a snooze moves it, Done (passed) ends it, upsets are unchanged', async () => {
  const { default: C } = await import('./cycle-load.mjs');
  const first = '2026-11-28T02:12:00Z', base = { quick: true, q: 'How much work did Esme get done?', short: 'her work', created_at: '2026-11-27T18:12:00Z', firstAt: first, checks: [] };
  assert.equal(C.upsetNextCheck(base, 'America/New_York'), Date.parse(first));
  assert.equal(C.upsetNextCheck({ ...base, checks: [{ at: '2026-11-28T02:13:00Z', ans: 'still' }] }, 'America/New_York'), Date.parse(first), 'no backoff: still is not an answer to it');
  const sz = { at: '2026-11-27T19:00:00Z', until: '2026-11-28T05:00:00Z' };
  assert.equal(C.upsetNextCheck({ ...base, snooze: sz }, 'America/New_York'), Date.parse(sz.until));
  assert.equal(C.upsetNextCheck({ ...base, checks: [{ at: '2026-11-28T02:20:00Z', ans: 'passed' }] }, 'America/New_York'), null);
  assert.equal(C.upsetCheckBody(base, 'America/New_York', 0), 'her work');
  assert.equal(C.upsetNextCheck({ quick: true, created_at: '2026-11-27T18:12:00Z', checks: [] }, 'America/New_York'), Date.parse('2026-11-27T19:12:00Z'), 'an upset keeps its +1h');
});

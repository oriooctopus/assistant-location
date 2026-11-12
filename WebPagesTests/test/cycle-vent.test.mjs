// Vent on the fight detail: Just me stays on the device, Tap to see / Open are shared rows through the outbox, the partner sees
// a flame cover until tapped, and a vent not yet due never shows. Runs in Chromium, plus WebKit when GL_WEBKIT_PW/GL_WEBKIT_EXEC are set.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web');
// Served over http, not file://: a reloaded file:// document in Chromium can read an EMPTY localStorage at start even though the previous document wrote to it (measured 10 of 30 reloads), which looked like data loss in every reload test.
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.json': 'application/json', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf' };
const srv = http.createServer((req, res) => {
  const f = path.join(WEB, new URL(req.url, 'http://x').pathname);
  fs.readFile(f, (e, b) => { if (e) { res.statusCode = 404; res.end(); } else { res.setHeader('content-type', MIME[path.extname(f)] || 'application/octet-stream'); res.end(b); } });
});
await new Promise((r) => srv.listen(0, '127.0.0.1', r));
srv.unref();
const URL_ = 'http://127.0.0.1:' + srv.address().port + '/index.html';
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const engines = { chromium };
if (process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC) {
  const pw = await import(process.env.GL_WEBKIT_PW);
  engines.webkit = { launch: (o) => pw.webkit.launch({ ...o, executablePath: process.env.GL_WEBKIT_EXEC }) };
}

const UID = 'u-me', PID = 'u-her', HOUR = 36e5;
const ago = (h) => new Date(Date.now() - h * HOUR).toISOString();
const seed = (tweak, privTweak) => {
  const sh = {
    couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [{ user_id: UID, name: 'Me', checkin_time: '21:00', hits_self: false }, { user_id: PID, name: 'Her', checkin_time: '21:00', hits_self: true }],
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, fight_markers: { fp: { id: 'fp', couple_id: 'c1', logged_by: PID, at: ago(2), repaired_at: null, hit_self: null, hit_related: null } },
      fight_notes: {}, fight_vents: {}, rewards: {}, redemptions: {} },
    cursors: {}, outbox: [],
  };
  tweak?.(sh);
  const priv = { fights: [], affirmations: [], prefs: {} }; // an older install: no vents / ventSeen / ventFollow yet, the migration must add them
  privTweak?.(priv);
  return {
    session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } },
    ['shared.' + UID]: sh,
    ['priv.' + UID]: priv,
  };
};
const vent = (id, o) => ({ id, couple_id: 'c1', fight_marker_id: 'fp', author_id: PID, body: id, reveal: 'tap', visible_at: ago(1), created_at: ago(1), updated_at: ago(1), deleted_at: null, ...o });

for (const [name, type] of Object.entries(engines)) describe(name, () => {
  let browser;
  before(async () => { browser = await type.launch({ headless: true }); });
  after(async () => { await browser.close(); });

  const reloadSettled = (page) => page.goto(URL_, { waitUntil: 'domcontentloaded' }); // not page.reload(): see the seed note in open()
  async function open(tweak, privTweak) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    // Seed only on the first load (URL marked ?seed): the init script runs again on every navigation, so seeding unconditionally would overwrite the app's own saved data on a reload. Reload with goto(URL_) (no marker), not page.reload().
    await context.addInitScript((sd) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (location.search === '?seed') for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, seed(tweak, privTweak));
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (route) => route.abort()); // offline: writes stay in the outbox
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_ + '?seed', { waitUntil: 'domcontentloaded' });
    await page.click('[data-a="tab:progress"]'); await page.click('[data-a="go:points"]');
    await page.click('.ln[data-a="openfight:fp"]');
    await page.waitForSelector('.vent');
    return { context, page };
  }
  const stored = (page) => page.evaluate(() => ({ sh: JSON.parse(localStorage.getItem('cycle:shared.u-me')), pv: JSON.parse(localStorage.getItem('cycle:priv.u-me')) }));
  const cards = (page) => page.$$eval('.vent .vt', (els) => els.map((e) => e.textContent.replace(/\s+/g, ' ').trim()));
  async function write(page, text, who, wait) {
    if (who) await page.click(`[data-a="vwho:${who}"]`);
    if (wait) await page.click(`[data-a="vwait:${wait}"]`);
    await page.fill('textarea[data-d="vent"]', text);
    await page.click('[data-a="ventsave"]');
  }
  // The debounced persist writes localStorage a beat after the click.
  const settled = (page, fn, arg) => page.waitForFunction(fn, arg);

  test('writing a vent each way: Just me never enters the outbox or shared rows', async () => {
    const { context, page } = await open();
    // Attribute alone is not enough: .save{display:flex} once beat [hidden] and left Save drawn under an empty box.
    assert.equal(await page.locator('[data-a="ventsave"]').isVisible(), false, 'Save not drawn while the box is empty');
    await page.fill('textarea[data-d="vent"]', 'x');
    assert.equal(await page.locator('[data-a="ventsave"]').isVisible(), true, 'Save drawn once there is text');
    await page.fill('textarea[data-d="vent"]', '');
    assert.equal(await page.locator('[data-a="ventsave"]').isVisible(), false, 'Save hidden again when cleared');
    assert.equal(await page.$eval('[data-a="vwho:tap"]', (e) => e.classList.contains('on')), true, 'defaults to Tap to see');
    await write(page, 'private rant', 'me');
    await write(page, 'tap rant', 'tap', '1h');
    await write(page, 'open rant', 'open', '0');
    await settled(page, () => Object.keys(JSON.parse(localStorage.getItem('cycle:shared.u-me')).rows.fight_vents).length === 2);
    const { sh, pv } = await stored(page);
    assert.deepEqual(pv.vents.map((v) => v.body), ['private rant']);
    assert.deepEqual(pv.ventSeen, {});
    const shared = Object.values(sh.rows.fight_vents);
    assert.deepEqual(shared.map((v) => v.body).sort(), ['open rant', 'tap rant']);
    assert.equal(JSON.stringify(sh).includes('private rant'), false, 'Just me text is nowhere in the shared tier');
    assert.equal(sh.outbox.length, 2);
    assert.ok(sh.outbox.every((o) => o.op === 'insert' && o.table === 'fight_vents' && o.row.body !== 'private rant'));
    const tap = shared.find((v) => v.reveal === 'tap'), opn = shared.find((v) => v.reveal === 'open');
    assert.equal(opn.reveal, 'open');
    assert.ok(Math.abs(Date.parse(tap.visible_at) - Date.now() - HOUR) < 60e3, 'Unlock 1h sets visible_at an hour out');
    assert.ok(Date.parse(opn.visible_at) <= Date.now() + 1000, 'Now is due at once');
    const c = await cards(page);
    assert.equal(c.length, 3);
    assert.match(c[0], /private rant/); assert.match(c[0], /Just me/);
    assert.match(c[1], /Opens .*\d:\d\d (am|pm).*tap rant/);
    assert.match(c[2], /Open.*open rant/);
    assert.equal(await page.inputValue('textarea[data-d="vent"]'), '', 'box cleared after save');
    // Ember canvas: every render() rebuilt the section, so exactly one canvas must exist (no stacked leftovers) and it must not eat taps.
    assert.equal(await page.locator('.vent canvas.em').count(), 1, 'one ember canvas after many re-renders');
    assert.equal(await page.$eval('.vent canvas.em', (e) => getComputedStyle(e).pointerEvents), 'none');
    await context.close();
  });

  test('partner Tap to see shows a cover, tap reveals and stays revealed; a not-yet-due vent is absent', async () => {
    const { context, page } = await open((sh) => {
      sh.rows.fight_vents.v1 = vent('v1', { body: 'she is furious' });
      sh.rows.fight_vents.v2 = vent('v2', { body: 'later one', visible_at: new Date(Date.now() + 3 * HOUR).toISOString() });
      sh.rows.fight_vents.v3 = vent('v3', { body: 'open one', reveal: 'open' });
      sh.rows.fight_vents.v4 = vent('v4', { body: 'deleted one', reveal: 'open', deleted_at: ago(0.5) });
    });
    let c = await cards(page);
    assert.equal(c.length, 2, 'later and deleted vents are not shown');
    assert.match(c[0], /Her vented\s*Tap to see/);
    assert.equal(c[0].includes('furious'), false, 'covered body is not in the DOM');
    assert.match(c[1], /open one/);
    await page.click('.vt.cov');
    c = await cards(page);
    assert.match(c[0], /Her .*she is furious/);
    await settled(page, () => !!JSON.parse(localStorage.getItem('cycle:priv.u-me')).ventSeen.v1);
    await reloadSettled(page);
    await page.click('[data-a="tab:progress"]'); await page.click('[data-a="go:points"]');
    await page.click('.ln[data-a="openfight:fp"]');
    await page.waitForSelector('.vent');
    c = await cards(page);
    assert.match(c[0], /she is furious/, 'stays revealed after a reload');
    await context.close();
  });

  test('a reveal tapped and followed at once by a reload is not lost (pagehide flush)', async () => {
    const { context, page } = await open((sh) => { sh.rows.fight_vents.v1 = vent('v1', { body: 'she is furious' }); });
    await page.click('.vt.cov');
    await reloadSettled(page); // straight after the tap: only the 50ms debounce and the pagehide flush stand between it and the disk
    await page.click('[data-a="tab:progress"]'); await page.click('[data-a="go:points"]');
    await page.click('.ln[data-a="openfight:fp"]');
    await page.waitForSelector('.vent');
    assert.match((await cards(page))[0], /she is furious/);
    await context.close();
  });

  test('deleting: Just me is removed from the device, shared is soft-deleted and queued', async () => {
    const { context, page } = await open();
    await write(page, 'private rant', 'me');
    await write(page, 'tap rant', 'tap', '0');
    await page.click('[data-a^="ventdel:"] >> nth=0');
    await page.click('[data-a="ventdelok"]');
    await page.click('[data-a^="ventdel:"]');
    await page.click('[data-a="ventdelok"]');
    assert.equal((await cards(page)).length, 0);
    await settled(page, () => JSON.parse(localStorage.getItem('cycle:priv.u-me')).vents.length === 0
      && Object.values(JSON.parse(localStorage.getItem('cycle:shared.u-me')).rows.fight_vents).every((v) => v.deleted_at));
    const { sh } = await stored(page);
    assert.equal(sh.outbox.length, 1, 'the insert and its delete folded into one outbox entry');
    assert.ok(sh.outbox[0].row.deleted_at);
    await context.close();
  });

  // ---- follow-up -------------------------------------------------------------------------------------------------
  const own = (id, o) => ({ id, fight_marker_id: 'fp', body: 'mine ' + id, created_at: ago(30), ...o });
  const fu = (at, done = null) => ({ at, hours: 24, done });
  const reopen = async (page) => {
    await reloadSettled(page);
    await page.click('[data-a="tab:progress"]'); await page.click('[data-a="go:points"]');
    await page.click('.ln[data-a="openfight:fp"]');
    await page.waitForSelector('.vent');
  };
  const dueIn = (h) => new Date(Date.now() + h * HOUR).toISOString();
  const onDisk = (page, id) => stored(page).then(({ pv }) => pv.ventFollow[id]);

  test('composer: Follow up defaults to 24h; a saved vent gets a private-tier follow-up, and a shared one sends nothing of it', async () => {
    const { context, page } = await open();
    assert.deepEqual(await page.$$eval('[data-a^="vfu:"]', (els) => els.map((e) => e.textContent)), ['12h', '24h', 'Off']);
    assert.equal(await page.$eval('[data-a="vfu:24"]', (e) => e.classList.contains('on')), true, 'defaults to 24h');
    await write(page, 'shared rant', 'tap', '0'); // 24h default
    await page.click('[data-a="vfu:12"]');
    await write(page, 'private rant', 'me');
    await page.click('[data-a="vfu:0"]');
    await write(page, 'quiet rant', 'open', '0');
    await settled(page, () => Object.keys(JSON.parse(localStorage.getItem('cycle:shared.u-me')).rows.fight_vents).length === 2 && JSON.parse(localStorage.getItem('cycle:priv.u-me')).vents.length === 1);
    const { sh, pv } = await stored(page);
    const shared = Object.values(sh.rows.fight_vents).find((v) => v.body === 'shared rant'), priv = pv.vents[0];
    const noFu = Object.values(sh.rows.fight_vents).find((v) => v.body === 'quiet rant');
    assert.deepEqual(Object.keys(pv.ventFollow).sort(), [shared.id, priv.id].sort(), 'Off writes no entry');
    assert.equal(pv.ventFollow[shared.id].hours, 24);
    assert.equal(pv.ventFollow[priv.id].hours, 12);
    assert.ok(Math.abs(Date.parse(pv.ventFollow[shared.id].at) - Date.now() - 24 * HOUR) < 60e3);
    assert.equal(pv.ventFollow[shared.id].done, null);
    assert.equal(pv.ventFollow[noFu.id], undefined);
    assert.equal(JSON.stringify(sh).toLowerCase().includes('follow'), false, 'nothing about a follow-up in the shared tier');
    assert.ok(sh.outbox.every((o) => !Object.keys(o.row).some((k) => /follow|hours|outcome/i.test(k))), 'insert payloads carry no follow-up fields');
    assert.deepEqual(Object.keys(sh.outbox[0].row).sort(), ['author_id', 'body', 'couple_id', 'created_at', 'deleted_at', 'fight_marker_id', 'id', 'reveal', 'updated_at', 'visible_at']);
    await context.close();
  });

  test('before due: a quiet bare time on my own card, none on the partner\'s', async () => {
    const { context, page } = await open((sh) => {
      sh.rows.fight_vents.s1 = vent('s1', { author_id: UID, body: 'shared mine', visible_at: ago(20), created_at: ago(20) });
      sh.rows.fight_vents.p1 = vent('p1', { body: 'hers', reveal: 'open' });
    }, (pv) => { pv.vents = [own('m1')]; pv.ventFollow = { m1: fu(dueIn(5)), s1: fu(dueIn(30)), p1: fu(ago(2)) }; });
    const c = await page.$$eval('.vent .vt', (els) => els.map((e) => ({ t: e.textContent.replace(/\s+/g, ' ').trim(), fu: e.querySelector('.vfu')?.textContent.replace(/\s+/g, ' ').trim() ?? null })));
    const mine = c.find((x) => x.t.includes('mine m1')), shared = c.find((x) => x.t.includes('shared mine')), hers = c.find((x) => x.t.includes('hers'));
    assert.match(mine.fu, /^→ (\d+ Nov )?\d{1,2}:\d\d (am|pm)$/);
    assert.match(shared.fu, /^→ \d+ Nov \d{1,2}:\d\d (am|pm)$/, 'a time on another day carries the date');
    assert.equal(hers.fu, null, 'partner view of a shared vent shows no follow-up UI, even if a stray entry exists');
    assert.equal(await page.locator('.vfu.dueq').count(), 0);
    await context.close();
  });

  test('due: the block saves the answer to the private tier on disk, survives a reload, and Redo reopens it', async () => {
    const { context, page } = await open(null, (pv) => { pv.vents = [own('m1')]; pv.ventFollow = { m1: fu(ago(1)) }; });
    assert.equal(await page.locator('.vfu.dueq').count(), 1);
    assert.deepEqual(await page.$$eval('.vfu.dueq [data-a^="vfo:"]', (els) => els.map((e) => e.textContent)), ['Faded', 'Still there', 'Grew', 'Acted on it']);
    assert.equal(await page.locator('.vfu.dueq .lk.on').count(), 0, 'nothing preselected');
    assert.equal(await page.getAttribute('.vfu.dueq textarea', 'placeholder'), 'Notes');
    assert.ok(await page.$eval('[data-a="vfsave:m1"]', (e) => e.classList.contains('dis')), 'Save is disabled until an outcome is picked');
    await page.click('[data-a="vfsave:m1"]', { force: true });
    assert.equal(await page.locator('.vfu.dueq').count(), 1, 'a Save with no outcome leaves the block open');
    const box = () => page.$eval('[data-a="vfsave:m1"]', (e) => e.getBoundingClientRect().y);
    const y0 = await box();
    await page.click('[data-a="vfo:m1:still"]');
    assert.equal(await page.locator('.vfu.dueq .lk.on').textContent(), 'Still there');
    assert.equal(await box(), y0, 'a chip tap does not move Save (notes box has one fixed height)');
    await page.fill('.vfu.dueq textarea', 'calmer now');
    assert.equal(await box(), y0, 'typing a short note does not move Save');
    assert.equal(await page.$eval('.vfu.dueq .chips', (e) => getComputedStyle(e).columnGap), '10px');
    await page.click('[data-a="vfsave:m1"]');
    assert.equal(await page.locator('.vfu.dueq').count(), 0, 'optimistic: the block is gone on the tap');
    await settled(page, () => JSON.parse(localStorage.getItem('cycle:priv.u-me')).ventFollow.m1.done);
    let d = (await onDisk(page, 'm1')).done;
    assert.equal(d.outcome, 'still'); assert.equal(d.text, 'calmer now'); assert.ok(Math.abs(Date.parse(d.at) - Date.now()) < 60e3);
    assert.equal((await stored(page)).sh.outbox.length, 0, 'nothing queued for the partner');
    await reopen(page);
    assert.match(await page.textContent('.vfu'), /^Still there · \d+ NovRedocalmer now$/);
    assert.equal(await page.locator('.vfu.dueq').count(), 0);
    await page.click('[data-a="vfredo:m1"]');
    assert.equal(await page.textContent('.sheetlayer h3'), 'Redo follow up?');
    await page.click('[data-a="vfredook"]');
    assert.equal(await page.locator('.vfu.dueq').count(), 1);
    await settled(page, () => JSON.parse(localStorage.getItem('cycle:priv.u-me')).ventFollow.m1.done === null);
    await context.close();
  });

  test('route ventfu/<id> opens that vent\'s fight on its card; a gone vent goes Home', async () => {
    const { context, page } = await open((sh) => {
      sh.rows.fight_markers.f2 = { id: 'f2', couple_id: 'c1', logged_by: UID, at: ago(40), repaired_at: null, hit_self: null, hit_related: null };
      sh.rows.fight_vents.s2 = vent('s2', { author_id: UID, fight_marker_id: 'f2', body: 'on the second fight', created_at: ago(30), visible_at: ago(30) });
    }, (pv) => { pv.vents = [own('m1')]; pv.ventFollow = { m1: fu(ago(1)), s2: fu(ago(1)) }; });
    await page.evaluate(() => window.cycleNative.route('ventfu/s2'));
    await page.waitForSelector('.vt[data-v="s2"]');
    assert.equal(await page.textContent('.hd h2'), 'Fight');
    assert.equal(await page.locator('.vt[data-v="m1"]').count(), 0, 'the other fight\'s vent is not here');
    assert.equal(await page.locator('.vt[data-v="s2"] .vfu.dueq').count(), 1);
    assert.equal(await page.locator('.vt[data-v="s2"]').evaluate((e) => { const r = e.getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight; }), true, 'scrolled into view');
    await page.click('[data-a="back"], .back').catch(() => {});
    await page.evaluate(() => window.cycleNative.route('ventfu/nope'));
    await page.waitForFunction(() => !document.querySelector('.vent'));
    assert.equal(await page.locator('.vent').count(), 0, 'not a fight page');
    await context.close();
  });
});

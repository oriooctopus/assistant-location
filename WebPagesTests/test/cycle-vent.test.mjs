// Vent on the fight detail: Just me stays on the device, Tap to see / Open are shared rows through the outbox, the partner sees
// a flame cover until tapped, and a vent not yet due never shows. Runs in Chromium, plus WebKit when GL_WEBKIT_PW/GL_WEBKIT_EXEC are set.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const engines = { chromium };
if (process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC) {
  const pw = await import(process.env.GL_WEBKIT_PW);
  engines.webkit = { launch: (o) => pw.webkit.launch({ ...o, executablePath: process.env.GL_WEBKIT_EXEC }) };
}

const UID = 'u-me', PID = 'u-her', HOUR = 36e5;
const ago = (h) => new Date(Date.now() - h * HOUR).toISOString();
const seed = (tweak) => {
  const sh = {
    couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [{ user_id: UID, name: 'Me', checkin_time: '21:00', hits_self: false }, { user_id: PID, name: 'Her', checkin_time: '21:00', hits_self: true }],
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, fight_markers: { fp: { id: 'fp', couple_id: 'c1', logged_by: PID, at: ago(2), repaired_at: null, hit_self: null, hit_related: null } },
      fight_notes: {}, fight_vents: {}, rewards: {}, redemptions: {} },
    cursors: {}, outbox: [],
  };
  tweak?.(sh);
  return {
    session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } },
    ['shared.' + UID]: sh,
    ['priv.' + UID]: { fights: [], affirmations: [], prefs: {} }, // an older install: no vents / ventSeen yet, the migration must add them
  };
};
const vent = (id, o) => ({ id, couple_id: 'c1', fight_marker_id: 'fp', author_id: PID, body: id, reveal: 'tap', visible_at: ago(1), created_at: ago(1), updated_at: ago(1), deleted_at: null, ...o });

for (const [name, type] of Object.entries(engines)) describe(name, () => {
  let browser;
  before(async () => { browser = await type.launch({ headless: true }); });
  after(async () => { await browser.close(); });

  async function open(tweak) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.addInitScript((sd) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, seed(tweak));
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (route) => route.abort()); // offline: writes stay in the outbox
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
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
    assert.match(c[0], /private rant$/); assert.match(c[0], /Just me/);
    assert.match(c[1], /Opens .*\d:\d\d (am|pm).*tap rant$/);
    assert.match(c[2], /Open.*open rant$/);
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
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.click('[data-a="tab:progress"]'); await page.click('[data-a="go:points"]');
    await page.click('.ln[data-a="openfight:fp"]');
    await page.waitForSelector('.vent');
    c = await cards(page);
    assert.match(c[0], /she is furious/, 'stays revealed after a reload');
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
});

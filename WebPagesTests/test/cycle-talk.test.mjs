// Talk (was Acknowledge): rename, Kudos subsection, self-kudos (private / shared), Points toggle on partner kudos.
// WebKit only (set GL_WEBKIT_PW/GL_WEBKIT_EXEC); skipped without it. TALK_SHOTS=<dir> saves screenshots.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import C from './cycle-load.mjs';

const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const haveWebkit = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = haveWebkit ? await import(process.env.GL_WEBKIT_PW) : null;

const UID = 'u-me', PID = 'u-her', TZ = 'America/New_York';
const HOUR = 36e5;
const ago = (h) => new Date(Date.now() - h * HOUR).toISOString();
const members = [{ user_id: UID, name: 'Me', checkin_time: '21:00', hits_self: false }, { user_id: PID, name: 'Her', checkin_time: '21:00', hits_self: true }];
const seed = () => ({
  session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } },
  ['shared.' + UID]: {
    couple: { id: 'c1', tz: TZ, created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members,
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, fight_markers: {}, fight_notes: {}, rewards: {}, redemptions: {}, acks: {} },
    cursors: {}, outbox: [],
  },
  ['priv.' + UID]: { fights: [], affirmations: [], prefs: {} },
});
const item = (id, o) => ({ id, couple_id: 'c1', sender_id: PID, recipient_id: UID, kind: 'kudos', body: id, ask_type: null, status: 'delivered', delivered_at: ago(5), created_at: ago(5), updated_at: ago(5), deleted_at: null, opened_at: null, kept: null, ...o });
const ack = (id, o) => ({ id, couple_id: 'c1', author_id: PID, requested_by: null, item_id: null, title: id, description: null, status: 'done', done_at: ago(2), read_at: null, created_at: ago(3), updated_at: ago(2), deleted_at: null, ...o });
const ledgerRows = (items) => ({ members, items, todos: [], todo_events: [], fight_markers: [], redemptions: [], nudge_sends: [], nudge_awards: [], challenges: [] });
// Number of Kudos point lines the ledger pays for these item rows.
const kudosPts = (items) => {
  const l = C.computeLedger(ledgerRows(items), { tz: TZ, now: Date.now() + HOUR, since: C.localDay(Date.now() - 48 * HOUR, TZ) });
  return Object.values(l.weeks).flatMap((w) => Object.values(w.days)).flatMap((d) => d.lines).filter((x) => x.label === 'Kudos').length;
};

describe('webkit', { skip: !haveWebkit }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  async function open(tweak) {
    const s = seed();
    if (tweak) tweak(s['shared.' + UID], s['priv.' + UID]);
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.addInitScript((sd) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, s);
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    const writes = [];
    await context.route('https://x.test/**', (route) => { if (route.request().method() !== 'GET') writes.push(route.request().method() + ' ' + route.request().url()); route.abort(); });
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.rows .row');
    return { context, page, writes };
  }
  const read = async (page, key) => { await page.waitForTimeout(500); return page.evaluate((k) => JSON.parse(localStorage.getItem('cycle:' + k)), key); };
  const rowsOf = async (page, t) => Object.values((await read(page, 'shared.' + UID)).rows[t]);
  const openKudos = async (page) => { await page.click('[data-a="row:ack"]'); await page.click('[data-a="kudosnew"]'); };

  test('Acknowledge is renamed Talk everywhere, with Kudos and Owning up subsections', async () => {
    const { context, page } = await open();
    assert.match(await page.textContent('[data-id="ack"]'), /Talk/);
    await page.click('[data-a="row:ack"]');
    assert.equal(await page.textContent('h2'), 'Talk');
    assert.deepEqual(await page.$$eval('main > section > .lab', (els) => els.map((e) => e.textContent.replace('Add', ''))), ['Kudos', 'Owning up']);
    await page.click('[data-a="kudosnew"]');
    await page.click('[data-a="back"]');
    assert.match(await page.textContent('.hd .back'), /Today/);
    await page.click('[data-a="acknew"]');
    await page.fill('input[data-d="atitle"]', 'I go meta');
    await page.click('[data-a="acksave"]');
    await page.waitForSelector('.nd .rem');
    await page.click('[data-a="kudosnew"]');
    await page.click('[data-a="kudossave"]').catch(() => {});
    await page.click('[data-a="back"]');
    await page.click('[data-a="back"]');
    assert.doesNotMatch(await page.textContent('body'), /Acknowledge/);
    await context.close();
  });

  test('private self-kudos stays on this phone: no write, not in shared rows, scores nothing', async () => {
    const { context, page, writes } = await open();
    await openKudos(page);
    assert.equal(await page.$eval('[data-a="kudosto:me"]', (e) => e.classList.contains('on')), true, 'To defaults to Me');
    assert.equal(await page.$eval('[data-a="kudospriv:on"]', (e) => e.classList.contains('on')), true, 'Private defaults On');
    await page.click('[data-a="kudossave"]');
    assert.equal((await read(page, 'priv.' + UID)).kudos?.length ?? 0, 0, 'empty text saves nothing');
    await page.fill('input[data-d="ktext"]', 'I handled that calmly');
    await page.click('[data-a="kudossave"]');
    await page.waitForSelector('.nd .rem');
    assert.match(await page.textContent('.nd .rem small'), /Me · Private/);
    const priv = await read(page, 'priv.' + UID);
    assert.deepEqual(priv.kudos.map((k) => k.body), ['I handled that calmly']);
    const sh = await read(page, 'shared.' + UID);
    assert.deepEqual(sh.outbox, [], 'nothing queued for sync');
    assert.equal(Object.keys(sh.rows.items).length + Object.keys(sh.rows.acks).length, 0);
    assert.deepEqual(writes, [], 'no network write');
    assert.ok(!JSON.stringify(sh).includes('calmly'), 'text appears nowhere in shared state');
    assert.equal(kudosPts(Object.values(sh.rows.items)), 0);
    await context.close();
  });

  test('shared self-kudos is an acks row of kind kudos, visible under Kudos only, and scores nothing', async () => {
    const { context, page } = await open();
    await openKudos(page);
    await page.click('[data-a="kudospriv:off"]');
    await page.fill('input[data-d="ktext"]', 'Proud of the apology');
    await page.click('[data-a="kudossave"]');
    await page.waitForSelector('.nd .rem');
    const acks = await rowsOf(page, 'acks');
    assert.equal(acks.length, 1);
    assert.deepEqual([acks[0].author_id, acks[0].requested_by, acks[0].status, acks[0].kind, acks[0].title], [UID, null, 'done', 'kudos', 'Proud of the apology']);
    assert.equal((await rowsOf(page, 'items')).length, 0, 'no items row, so no kudos hold or points branch');
    assert.equal((await read(page, 'priv.' + UID)).kudos.length, 0);
    assert.match(await page.textContent('.nd .rem small'), /^Me · /);
    assert.equal(await page.$$eval('main > section:nth-of-type(2) .rem', (e) => e.length), 0, 'not under Owning up');
    await context.close();
  });

  test('partner kudos with Points Off scores 0, On scores +1 (real rows through the ledger)', async () => {
    const { context, page } = await open();
    await openKudos(page);
    await page.click('[data-a="kudosto:them"]');
    assert.equal(await page.$eval('[data-a="kudospts:on"]', (e) => e.classList.contains('on')), true, 'Points defaults On');
    await page.fill('input[data-d="ktext"]', 'Thanks for dinner');
    await page.click('[data-a="kudossave"]');
    await page.waitForSelector('.nd .rem');
    await page.click('[data-a="kudosnew"]');
    await page.click('[data-a="kudosto:them"]');
    await page.click('[data-a="kudospts:off"]');
    await page.fill('input[data-d="ktext"]', 'Nice parking');
    await page.click('[data-a="kudossave"]');
    await page.waitForFunction(() => document.querySelectorAll('.nd .rem').length === 2);
    const items = await rowsOf(page, 'items');
    const on = items.find((i) => i.body === 'Thanks for dinner'), off = items.find((i) => i.body === 'Nice parking');
    for (const i of [on, off]) assert.deepEqual([i.kind, i.sender_id, i.recipient_id, i.status], ['kudos', UID, PID, 'delivered']);
    assert.notEqual(on.points, false);
    assert.equal(off.points, false);
    assert.equal(kudosPts([on]), 1, 'Points on: +1');
    assert.equal(kudosPts([off]), 0, 'Points off: 0');
    assert.match(await page.textContent('.nd'), /To Her · No points/);
    await context.close();
  });

  test('Kudos lists received, given and shared kudos; her shared self-kudos is not an Owning up row', async () => {
    const { context, page } = await open((sh, priv) => {
      sh.rows.items = Object.fromEntries([item('You were patient'), item('Thanks for the soup', { sender_id: UID, recipient_id: PID, points: false })].map((r) => [r.id, r]));
      sh.rows.acks = Object.fromEntries([ack('I stayed calm today', { kind: 'kudos' }), ack('I went quiet')].map((r) => [r.id, r]));
      priv.kudos = [{ id: 'p1', body: 'I got up and went for a walk', created_at: ago(1) }];
    });
    await page.click('[data-a="row:ack"]');
    const kud = await page.$$eval('main > section:nth-of-type(1) .rem', (els) => els.map((e) => e.textContent));
    assert.equal(kud.length, 4);
    assert.ok(kud.some((t) => /You were patient.*From Her/.test(t)));
    assert.ok(kud.some((t) => /Thanks for the soup.*To Her · No points/.test(t)));
    assert.ok(kud.some((t) => /I stayed calm today.*Her/.test(t)));
    assert.ok(kud.some((t) => /walk.*Me · Private/.test(t)));
    const own = await page.$$eval('main > section:nth-of-type(2) .rem', (els) => els.map((e) => e.textContent));
    assert.equal(own.length, 1);
    assert.match(own[0], /I went quiet/);
    if (process.env.TALK_SHOTS) {
      await page.screenshot({ path: path.join(process.env.TALK_SHOTS, 'talk.png') });
      await page.click('[data-a="kudosnew"]');
      await page.click('[data-a="kudosto:them"]');
      await page.fill('input[data-d="ktext"]', 'Thanks for the soup');
      await page.screenshot({ path: path.join(process.env.TALK_SHOTS, 'kudos-new.png') });
      await page.click('[data-a="back"]'); // out of the form, back on Talk
    }
    // Only the real acknowledgment reaches the home count / needs-you.
    await page.click('[data-a="back"]');
    assert.match(await page.textContent('[data-id="ack"]'), /1/);
    assert.equal(await page.$$eval('.nc', (e) => e.filter((n) => /stayed calm/.test(n.textContent)).length), 0);
    await context.close();
  });
});

// Acknowledge: self-written acks, requests through the Ask hold, partner-side fulfil, needs-you cards, row order.
// WebKit only (set GL_WEBKIT_PW/GL_WEBKIT_EXEC); skipped without it.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const haveWebkit = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = haveWebkit ? await import(process.env.GL_WEBKIT_PW) : null;

const UID = 'u-me', PID = 'u-her';
const HOUR = 36e5;
const ago = (h) => new Date(Date.now() - h * HOUR).toISOString();
const seed = () => ({
  session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } },
  ['shared.' + UID]: {
    couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [
      { user_id: UID, name: 'Me', checkin_time: '21:00', hits_self: false },
      { user_id: PID, name: 'Her', checkin_time: '21:00', hits_self: true },
    ],
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, fight_markers: {}, fight_notes: {}, rewards: {}, redemptions: {}, acks: {} },
    cursors: {}, outbox: [],
  },
  ['priv.' + UID]: { fights: [], affirmations: [], prefs: {} },
});
const ack = (id, author, extra) => ({ id, couple_id: 'c1', author_id: author, requested_by: author === UID ? PID : null, item_id: null, title: id, description: null, status: 'done', done_at: ago(2), read_at: null, created_at: ago(3), updated_at: ago(2), deleted_at: null, ...extra });

describe('webkit', { skip: !haveWebkit }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  async function open(tweak, prefs) {
    const s = seed();
    if (tweak) tweak(s['shared.' + UID]);
    if (prefs) s['priv.' + UID].prefs = prefs;
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.addInitScript((sd) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, s);
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (route) => route.abort());
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.rows .row');
    return { context, page };
  }
  const shared = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')));
  // The store persists on a debounce; wait for it, then read the real localStorage copy.
  const rowsOf = async (page, t) => { await page.waitForTimeout(500); return Object.values((await shared(page)).rows[t]); };

  test('home row order keeps an old saved order and appends ack', async () => {
    const { context, page } = await open(null, { rows: ['fight', 'todo', 'nudges'] });
    assert.deepEqual(await page.$$eval('.rows .row:not(.ovr)', (els) => els.map((e) => e.dataset.id)), ['fight', 'todo', 'nudges', 'ack']);
    await context.close();
  });

  test('self-written ack is saved done, shows under Mine, and is not held', async () => {
    const { context, page } = await open();
    assert.match(await page.textContent('[data-id="ack"]'), /None/);
    await page.click('[data-a="row:ack"]');
    await page.click('[data-a="acknew"]');
    await page.click('[data-a="acksave"]');
    assert.equal((await rowsOf(page, 'acks')).length, 0, 'empty title saves nothing');
    await page.fill('input[data-d="atitle"]', 'I go meta');
    await page.fill('textarea[data-d="adesc"]', 'It escalates');
    await page.click('[data-a="acksave"]');
    await page.waitForSelector('.nd .rem');
    const rows = await rowsOf(page, 'acks');
    assert.equal(rows.length, 1);
    assert.deepEqual([rows[0].author_id, rows[0].requested_by, rows[0].status, rows[0].title, rows[0].description], [UID, null, 'done', 'I go meta', 'It escalates']);
    assert.ok(rows[0].done_at);
    assert.deepEqual(await page.$$eval('.nd .lab', (els) => els.map((e) => e.textContent)), ['Mine']);
    assert.equal((await rowsOf(page, 'items')).length, 0);
    await context.close();
  });

  test('requesting is a held ask with no ack row; delivery creates the requested ack for her', async () => {
    const { context, page } = await open();
    await page.click('[data-a="row:ack"]');
    await page.click('[data-a="acknew"]');
    await page.click('[data-a="acknfrom:them"]');
    assert.equal((await page.textContent('[data-a="acksave"]')).trim(), 'Ask Her');
    await page.fill('input[data-d="atitle"]', 'Say sorry first');
    await page.click('[data-a="acksave"]');
    const items = await rowsOf(page, 'items');
    assert.equal(items.length, 1);
    assert.deepEqual([items[0].kind, items[0].ask_type, items[0].status, items[0].recipient_id], ['ask', 'ack', 'held', PID]);
    assert.equal((await rowsOf(page, 'acks')).length, 0);
    assert.match(await page.textContent('.nd'), /Asked/, 'pending request shown under her section');
    await context.close();

    // Hold over: the Still send? path delivers it.
    const b = await open((sh) => {
      sh.rows.items.i1 = { id: 'i1', couple_id: 'c1', sender_id: UID, recipient_id: PID, kind: 'ask', ask_type: 'ack', body: 'Say sorry first', description: null, status: 'held', held_until: ago(1), created_at: ago(3), delivered_at: null, deleted_at: null, updated_at: ago(3) };
    });
    await b.page.click('[data-a="still:i1"]');
    await b.page.click('[data-a="deliver:i1"]');
    const acks = await rowsOf(b.page, 'acks');
    assert.equal(acks.length, 1);
    assert.deepEqual([acks[0].author_id, acks[0].requested_by, acks[0].item_id, acks[0].status, acks[0].title], [PID, UID, 'i1', 'requested', 'Say sorry first']);
    assert.equal((await rowsOf(b.page, 'todos')).length, 0);
    await b.context.close();
  });

  test('partner request shows a needs-you card; fulfilling turns it done', async () => {
    const { context, page } = await open((sh) => { sh.rows.acks.r1 = ack('r1', UID, { status: 'requested', done_at: null, requested_by: PID, title: 'Own the tone' }); });
    assert.match(await page.textContent('[data-a="ackedit:r1"]'), /Her asks[\s\S]*Own the tone/);
    assert.match(await page.textContent('[data-id="ack"]'), /1 asked/);
    await page.click('[data-a="ackedit:r1"]');
    assert.equal(await page.inputValue('input[data-d="atitle"]'), 'Own the tone');
    assert.equal(await page.$('[data-a="acknfrom:them"]'), null, 'no From seg when fulfilling');
    await page.fill('textarea[data-d="adesc"]', 'Next time I pause');
    await page.click('[data-a="acksave"]');
    const [a] = await rowsOf(page, 'acks');
    assert.deepEqual([a.status, a.description, a.title], ['done', 'Next time I pause', 'Own the tone']);
    assert.ok(a.done_at);
    await context.close();
  });

  test('partner done ack shows a card until opened, which marks it read', async () => {
    const { context, page } = await open((sh) => { sh.rows.acks.p1 = ack('p1', PID, { title: 'I interrupt' }); });
    assert.match(await page.textContent('[data-a="acks"]'), /From Her[\s\S]*I interrupt/);
    await page.click('[data-a="acks"]');
    await page.waitForSelector('.nd .rem');
    assert.deepEqual(await page.$$eval('.nd .lab', (els) => els.map((e) => e.textContent)), ['Her’s']);
    const [a] = await rowsOf(page, 'acks');
    assert.ok(a.read_at);
    await context.close();
  });
});

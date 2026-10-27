// Challenges: Points chip -> detail (stats, streak-band calendar, hit gap, no x marks) -> Edit sheet rename, sent as a PATCH.
// WebKit only (set GL_WEBKIT_PW/GL_WEBKIT_EXEC); skipped without it. SHOTS=<dir> also writes 390px screenshots.
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
const SHOTS = process.env.SHOTS;

const UID = 'u-me', PID = 'u-her', TZ = 'America/New_York';
const today = C.localDay(Date.now(), TZ);
const day = (n) => C.addDays(today, n); // n days from today
// Start 30 days ago, hits 18 and 5 days ago: run of 12 (week bonus on day 7), gap, run of 12, gap, current run of 5 (today = day 5).
const START = day(-30), HITS = [day(-18), day(-5)];
const fight = (d) => ({ id: 'f-' + d, couple_id: 'c1', at: new Date(C.addDays(d, 0) + 'T16:00:00Z').toISOString(), logged_by: PID, hit_self: true, hit_count: 1 });
const seed = () => ({
  session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } },
  ['shared.' + UID]: {
    couple: { id: 'c1', tz: TZ, created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [{ user_id: UID, name: 'Me', checkin_time: '21:00', hits_self: false }, { user_id: PID, name: 'Her', checkin_time: '21:00', hits_self: true }],
    rows: {
      items: {}, todos: {}, todo_events: {}, checkins: {}, fight_notes: {}, rewards: {}, redemptions: {}, acks: {},
      fight_markers: Object.fromEntries(HITS.map((d) => [fight(d).id, fight(d)])),
      challenges: { 'no-hit': { id: 'no-hit', couple_id: 'c1', name: 'No hitting', start: START, created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-01T00:00:00Z' } },
    },
    cursors: {}, outbox: [],
  },
  ['priv.' + UID]: { fights: [], affirmations: [], prefs: {} },
});

describe('webkit', { skip: !haveWebkit }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  async function open(tweak) {
    const s = seed();
    if (tweak) tweak(s['shared.' + UID]);
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.addInitScript((sd) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, s);
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    const sent = [];
    await context.route('https://x.test/**', (route) => {
      const rq = route.request();
      if (rq.method() === 'PATCH' && /\/rest\/v1\/challenges/.test(rq.url())) { sent.push({ url: rq.url(), body: rq.postDataJSON() }); return route.fulfill({ status: 204, body: '' }); }
      return route.abort();
    });
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.rows .row');
    await page.click('[data-a="go:points"]');
    return { context, page, sent };
  }
  const shot = (page, name) => SHOTS && page.screenshot({ path: path.join(SHOTS, name + '.png') });

  test('Points shows a chip per challenge; tapping it opens the detail with stats and calendar', async () => {
    const { context, page } = await open();
    assert.equal((await page.textContent('.chip')).replace(/\s+/g, ' ').trim(), 'No hitting Day 5');
    await shot(page, 'points');
    await page.click('.chip');
    assert.equal(await page.textContent('.hd h2'), 'No hitting');
    assert.deepEqual(await page.$$eval('.four .lab', (e) => e.map((x) => x.textContent)), ['Day', 'Tonight', 'Best', 'Earned']);
    const big = await page.$$eval('.four .big', (e) => e.map((x) => x.textContent));
    assert.deepEqual(big, ['5', '+5', '12', '180']); // a 12-day run = 55 (days 1-10) + 20 (days 11-12) + 10 week bonus = 85, twice = 170, plus days 1-4 of the current run = 10
    assert.equal(await page.$$eval('.ccal .wl', (e) => e.length), 5);
    assert.deepEqual(await page.$$eval('.ccal .wk', (e) => e.map((x) => x.textContent).join('')), 'MTWTFSS');
    const rules = await page.$$eval('.rule', (e) => e.map((x) => x.textContent));
    assert.deepEqual(rules, ['+1, +2, +3… up to +10 a day, plus +10 every week and +100 every month!', 'A hit: −10, then −5 for each more that day.']);
    await shot(page, 'detail');
    await context.close();
  });

  test('a hit day is an empty gap, runs are connected bands, no x marks anywhere', async () => {
    const { context, page } = await open();
    await page.click('.chip');
    const cells = await page.$$eval('.ccal .cx', (e) => e.map((x) => ({ c: x.className.replace('cx ', ''), t: x.textContent })));
    // Last cell of the 5th row may be a future dot; today's cell is the one with .t and the in-progress number.
    assert.equal(cells.length, 35);
    const todayCell = cells.filter((x) => /\bt\b/.test(x.c));
    assert.equal(todayCell.length, 1);
    assert.equal(todayCell[0].t, '5');
    // Exactly two hit gaps inside the window or before it; gaps hold no text.
    const gaps = cells.filter((x) => /\bg\b/.test(x.c));
    assert.ok(gaps.length >= 1 && gaps.length <= 2);
    gaps.forEach((g) => assert.equal(g.t, ''));
    assert.equal((await page.textContent('.ccal')).includes('×'), false);
    assert.equal((await page.textContent('main')).includes('×'), false);
    // Band cells carry their streak number; a band never spans a gap: a cell right after a gap starts a run.
    cells.forEach((x, i) => { if (/\bb\b/.test(x.c) && i % 7 !== 0 && /\bg\b/.test(cells[i - 1].c)) assert.match(x.c, /\bs\b/); });
    // Computed shape: a mid-run cell has square corners, a run end is rounded on its right only.
    const radii = await page.$$eval('.ccal .cx.b', (e) => e.map((x) => [x.className, getComputedStyle(x).borderTopLeftRadius, getComputedStyle(x).borderTopRightRadius]));
    const mid = radii.find(([c]) => !/\bs\b/.test(c) && !/\be\b/.test(c));
    assert.deepEqual([mid[1], mid[2]], ['0px', '0px']);
    const end = radii.find(([c]) => /\be\b/.test(c) && !/\bs\b/.test(c) && !/\bt\b/.test(c));
    assert.deepEqual([end[1], end[2]], ['0px', '20px']);
    await context.close();
  });

  test('a hit today renders today as an outlined gap with day 0', async () => {
    const { context, page } = await open((sh) => { sh.rows.fight_markers['f-today'] = fight(today); });
    await page.click('.chip');
    assert.deepEqual(await page.$$eval('.four .big', (e) => e.map((x) => x.textContent).slice(0, 2)), ['0', '0']);
    const t = await page.$eval('.ccal .cx.t', (e) => [e.className, e.textContent]);
    assert.match(t[0], /\bg\b/); assert.equal(t[1], '');
    await context.close();
  });

  test('the calendar starts at the challenge start week, and week labels clear the first column', async () => {
    const { context, page } = await open((sh) => { sh.rows.challenges['no-hit'].start = today; sh.rows.fight_markers = {}; });
    await page.click('.chip');
    assert.equal(await page.$$eval('.ccal .wl', (e) => e.length), 1);
    const [l, c] = await page.$$eval('.ccal .wl, .ccal .cx', (e) => e.slice(0, 2).map((x) => x.getBoundingClientRect()));
    const w = await page.$eval('.ccal .wl', (e) => { const r = document.createRange(); r.selectNodeContents(e); return r.getBoundingClientRect().right; });
    assert.ok(w + 4 <= c.left, `label text ends at ${w}, first cell starts at ${c.left}`);
    await shot(page, 'detail-new');
    await context.close();
  });

  test('Edit renames: sheet shows the name, Save updates chip, title and the PATCH sent', async () => {
    const { context, page, sent } = await open();
    await page.click('.chip');
    await page.click('[data-a="chedit"]');
    assert.equal(await page.inputValue('.bs input[data-d="chname"]'), 'No hitting');
    await shot(page, 'edit');
    await page.fill('.bs input[data-d="chname"]', '  No yelling ');
    await page.click('[data-a="chsave"]');
    assert.equal(await page.textContent('.hd h2'), 'No yelling');
    assert.equal(await page.$('.bs'), null, 'sheet closed');
    for (let i = 0; i < 50 && !sent.length; i++) await page.waitForTimeout(100);
    assert.equal(sent.length, 1);
    assert.match(sent[0].url, /challenges\?id=eq\.no-hit$/);
    assert.deepEqual(sent[0].body, { name: 'No yelling' });
    await page.click('[data-a="back"]');
    assert.equal((await page.textContent('.chip')).replace(/\s+/g, ' ').trim(), 'No yelling Day 5');
    // Blank name is refused and nothing is sent.
    await page.click('.chip'); await page.click('[data-a="chedit"]');
    await page.fill('.bs input[data-d="chname"]', '   ');
    await page.click('[data-a="chsave"]');
    assert.match(await page.textContent('.errbar'), /Name needed/);
    assert.equal(sent.length, 1);
    await context.close();
  });

  test('no challenge rows: Points shows no Challenges block', async () => {
    const { context, page } = await open((sh) => { sh.rows.challenges = {}; });
    assert.equal(await page.$('.ent'), null);
    await context.close();
  });
});

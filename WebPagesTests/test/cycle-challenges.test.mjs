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
      challenges: { 'no-hit': { id: 'no-hit', couple_id: 'c1', name: 'No hitting', start: START, for_user: PID, accepted_at: '2026-01-01T00:00:00Z', created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-01T00:00:00Z' } },
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
      if (rq.method() === 'POST' && /\/rest\/v1\/challenge/.test(rq.url())) { sent.push({ url: rq.url(), body: rq.postDataJSON() }); return route.fulfill({ status: 201, body: '' }); }
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

  test('Us is the points hub: summary opens Points, challenge chip opens its detail, Shop row opens Shop, back returns to Us', async () => {
    const { context, page } = await open();
    await page.click('[data-a="tab:us"]');
    assert.equal(await page.textContent('.hd h2'), 'Us');
    assert.deepEqual(await page.$$eval('.ur .sum .lab', (e) => e.map((x) => x.textContent)), ['Balance', 'This week']);
    assert.equal((await page.textContent('.ur .chip[data-a^="challenge:"]')).replace(/\s+/g, ' ').trim(), 'No hitting Day 5');
    await shot(page, 'us');
    for (const [sel, title] of [['.ur .sum', 'Points'], ['.ur .chip[data-a^="challenge:"]', 'No hitting'], ['.ur [data-a="go:shop"]', 'Shop']]) {
      await page.click(sel);
      assert.equal(await page.textContent('.hd h2'), title);
      assert.equal((await page.textContent('.hd .back')).trim(), 'Us');
      await page.click('.hd .back');
      assert.equal(await page.textContent('.hd h2'), 'Us');
    }
    await context.close();
  });

  test('Points shows a chip per challenge; tapping it opens the detail with stats and calendar', async () => {
    const { context, page } = await open();
    assert.equal((await page.textContent('.chip[data-a^="challenge:"]')).replace(/\s+/g, ' ').trim(), 'No hitting Day 5');
    await shot(page, 'points');
    await page.click('.chip[data-a^="challenge:"]');
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
    await page.click('.chip[data-a^="challenge:"]');
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
    await page.click('.chip[data-a^="challenge:"]');
    assert.deepEqual(await page.$$eval('.four .big', (e) => e.map((x) => x.textContent).slice(0, 2)), ['0', '0']);
    const t = await page.$eval('.ccal .cx.t', (e) => [e.className, e.textContent]);
    assert.match(t[0], /\bg\b/); assert.equal(t[1], '');
    await context.close();
  });

  test('the calendar starts at the challenge start week, and week labels clear the first column', async () => {
    const { context, page } = await open((sh) => { sh.rows.challenges['no-hit'].start = today; sh.rows.fight_markers = {}; });
    await page.click('.chip[data-a^="challenge:"]');
    assert.equal(await page.$$eval('.ccal .wl', (e) => e.length), 1);
    const [l, c] = await page.$$eval('.ccal .wl, .ccal .cx', (e) => e.slice(0, 2).map((x) => x.getBoundingClientRect()));
    const w = await page.$eval('.ccal .wl', (e) => { const r = document.createRange(); r.selectNodeContents(e); return r.getBoundingClientRect().right; });
    assert.ok(w + 4 <= c.left, `label text ends at ${w}, first cell starts at ${c.left}`);
    await shot(page, 'detail-new');
    await context.close();
  });

  test('Edit renames: sheet shows the name, Save updates chip, title and the PATCH sent', async () => {
    const { context, page, sent } = await open();
    await page.click('.chip[data-a^="challenge:"]');
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
    assert.equal((await page.textContent('.chip[data-a^="challenge:"]')).replace(/\s+/g, ' ').trim(), 'No yelling Day 5');
    // Blank name is refused and nothing is sent.
    await page.click('.chip[data-a^="challenge:"]'); await page.click('[data-a="chedit"]');
    await page.fill('.bs input[data-d="chname"]', '   ');
    await page.click('[data-a="chsave"]');
    assert.match(await page.textContent('.errbar'), /Name needed/);
    assert.equal(sent.length, 1);
    await context.close();
  });

  test('New chip leads the row (also with no challenges); the screen defaults to Her + Tap, blank name cannot save, Save inserts and opens the detail as Not started', async () => {
    const { context, page, sent } = await open();
    assert.equal((await page.textContent('.chip')).trim(), 'New');
    assert.equal(await page.$eval('.chip', (e) => e.classList.contains('lead')), true);
    await page.click('[data-a="tab:us"]');
    assert.equal((await page.textContent('.ur .chip')).trim(), 'New');
    await page.click('.ur .chip.add');
    assert.equal(await page.textContent('.hd h2'), 'New');
    assert.equal((await page.textContent('.hd .back')).trim(), 'Us');
    assert.equal(await page.$eval('.tabbar .tab.on b', (e) => e.textContent), 'Us');
    assert.deepEqual(await page.$$eval('.tile', (e) => e.map((x) => [x.textContent, x.classList.contains('on')])), [['HHer', true], ['MMe', false]]);
    assert.deepEqual(await page.$$eval('.orow', (e) => e.map((x) => [x.textContent, x.classList.contains('on')])), [['Hit', false], ['Tap', true]]);
    assert.equal(await page.$eval('#chnew', (e) => e.classList.contains('dis')), true);
    await shot(page, 'new');
    await page.fill('[data-d="chname"]', '   ');
    assert.equal(await page.$eval('#chnew', (e) => e.classList.contains('dis')), true);
    await page.fill('[data-d="chname"]', '  No yelling ');
    assert.equal(await page.$eval('#chnew', (e) => e.classList.contains('dis')), false);
    await page.click('.tile:nth-child(2)');
    assert.equal(await page.$eval('.tile.on', (e) => e.textContent), 'MMe');
    assert.equal(await page.inputValue('[data-d="chname"]'), '  No yelling ', 'typed name survives a selection');
    await page.click('.tile:nth-child(1)'); await page.click('.orow:nth-child(1)');
    await page.click('.orow:nth-child(2)');
    await page.click('#chnew');
    assert.equal(await page.textContent('.hd h2'), 'No yelling');
    assert.equal((await page.textContent('.hd .back')).trim(), 'Us', 'back skips the form');
    assert.equal(await page.$('.four'), null);
    assert.equal(await page.textContent('.pts main .lab'), 'Waiting for Her');
    for (let i = 0; i < 50 && !sent.length; i++) await page.waitForTimeout(100);
    assert.equal(sent.length, 1);
    const b = sent[0].body;
    assert.match(sent[0].url, /\/rest\/v1\/challenges$/);
    assert.deepEqual([b.name, b.for_user, b.breaks_on, b.start, b.accepted_at], ['No yelling', PID, 'tap', today, null]);
    assert.ok(b.id && b.id !== 'no-hit');
    // Both chips show on the hub, the new one as Not started.
    await page.click('.hd .back');
    assert.deepEqual((await page.$$eval('.ur .chip', (e) => e.map((x) => x.textContent.replace(/\s+/g, ' ').trim()))), ['New', 'No hitting Day 5', 'No yelling Not started']);
    await context.close();
  });

  test('New screen back returns to where it was opened from, and a blank Save sends nothing', async () => {
    const { context, page, sent } = await open();
    await page.click('.chip.add');
    assert.equal((await page.textContent('.hd .back')).trim(), 'Points');
    await page.click('#chnew', { force: true });
    assert.equal(await page.textContent('.hd h2'), 'New');
    await page.click('.hd .back');
    assert.equal(await page.textContent('.hd h2'), 'Points');
    await page.waitForTimeout(300);
    assert.equal(sent.length, 0);
    await context.close();
  });

  const TAP = { id: 'tap1', couple_id: 'c1', name: 'No yelling', start: START, for_user: UID, breaks_on: 'tap', accepted_at: '2026-01-01T00:00:00Z', created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-01T00:00:00Z' };
  const openTap = (tweak) => open((sh) => { sh.rows.challenges.tap1 = TAP; sh.rows.fight_markers = {}; if (tweak) tweak(sh); });

  test('accepted tap challenge: only the first rule, Broke it sheet with note inserts a break; the cell turns into a hit-day cell and the button goes', async () => {
    const { context, page, sent } = await openTap();
    await page.click('.chip[data-a="challenge:tap1"]');
    assert.equal((await page.$$('.rule')).length, 1);
    assert.equal(await page.textContent('.pin .ghost'), 'Broke it');
    const before = await page.$eval('.ccal .cx.t', (e) => e.className);
    assert.match(before, /\bb\b/);
    await shot(page, 'tap-detail');
    await page.click('[data-a="broke"]');
    assert.equal(await page.textContent('.bs h3'), 'Broke it');
    await shot(page, 'broke');
    await page.fill('.bs [data-d="brnote"]', ' snapped at dinner ');
    await page.click('[data-a="brsave"]');
    assert.equal(await page.$('.bs'), null, 'sheet closed');
    assert.equal(await page.$('[data-a="broke"]'), null, 'button gone');
    const t = await page.$eval('.ccal .cx.t', (e) => [e.className, e.textContent]);
    assert.match(t[0], /\bg\b/); assert.match(t[0], /\bk\b/); assert.equal(t[1], '');
    assert.equal(await page.$eval('.ccal .cx.t', (e) => getComputedStyle(e, '::after').content), '"×"');
    assert.deepEqual(await page.$$eval('.four .big', (e) => e.map((x) => x.textContent).slice(0, 2)), ['0', '0']);
    for (let i = 0; i < 50 && !sent.length; i++) await page.waitForTimeout(100);
    assert.equal(sent.length, 1);
    assert.match(sent[0].url, /\/rest\/v1\/challenge_breaks$/);
    const b = sent[0].body;
    assert.deepEqual([b.challenge_id, b.day, b.note, b.by], ['tap1', today, 'snapped at dinner', UID]);
    await context.close();
  });

  test('tap challenge: a break from the partner today hides the button; hits do not break it; hit challenge shows no Broke it', async () => {
    const { context, page } = await openTap((sh) => {
      sh.rows.challenge_breaks = { b1: { id: 'b1', couple_id: 'c1', challenge_id: 'tap1', day: today, note: null, by: PID } };
      sh.rows.fight_markers = { fx: fight(day(-1)) };
    });
    await page.click('.chip[data-a="challenge:tap1"]');
    assert.equal(await page.$('[data-a="broke"]'), null);
    assert.equal((await page.$$('.cx.g.k')).length, 1, 'only the break day is broken; yesterday hit is ignored');
    await page.click('.hd .back');
    await page.click('.chip[data-a="challenge:no-hit"]');
    assert.equal(await page.$('[data-a="broke"]'), null);
    assert.equal((await page.$$('.rule')).length, 2);
    await context.close();
  });

  test('unaccepted: for_user sees Accept, which sends accepted_at and shows day 1; no stats before', async () => {
    const { context, page, sent } = await open((sh) => { Object.assign(sh.rows.challenges['no-hit'], { for_user: UID, accepted_at: null }); sh.rows.fight_markers = {}; });
    assert.equal((await page.textContent('.chip[data-a^="challenge:"]')).replace(/\s+/g, ' ').trim(), 'No hitting Not started');
    await page.click('.chip[data-a^="challenge:"]');
    assert.equal(await page.$('.four'), null); assert.equal(await page.$('.ccal'), null);
    assert.equal((await page.$$('.rule')).length, 2);
    assert.equal(await page.textContent('[data-a="chaccept"]'), 'Accept');
    await shot(page, 'accept');
    await page.click('[data-a="chaccept"]');
    assert.deepEqual(await page.$$eval('.four .big', (e) => e.map((x) => x.textContent).slice(0, 2)), ['1', '+1']);
    assert.equal(await page.$('[data-a="chaccept"]'), null);
    assert.equal(await page.$$eval('.ccal .wl', (e) => e.length), 1);
    for (let i = 0; i < 50 && !sent.length; i++) await page.waitForTimeout(100);
    assert.equal(sent.length, 1);
    assert.match(sent[0].url, /challenges\?id=eq\.no-hit$/);
    assert.deepEqual(Object.keys(sent[0].body), ['accepted_at']);
    assert.ok(Math.abs(Date.now() - Date.parse(sent[0].body.accepted_at)) < 60000);
    await context.close();
  });

  test('unaccepted: the partner sees Waiting for <name> and no button', async () => {
    const { context, page } = await open((sh) => { sh.rows.challenges['no-hit'].accepted_at = null; });
    assert.equal((await page.textContent('.chip[data-a^="challenge:"]')).replace(/\s+/g, ' ').trim(), 'No hitting Not started');
    await page.click('.chip[data-a^="challenge:"]');
    assert.equal(await page.textContent('.pts main .lab'), 'Waiting for Her');
    assert.equal(await page.$('[data-a="chaccept"]'), null);
    assert.equal(await page.$('.four'), null);
    await shot(page, 'waiting');
    await context.close();
  });

  test('no challenge rows: Points still shows the Challenges block with only the New chip', async () => {
    const { context, page } = await open((sh) => { sh.rows.challenges = {}; });
    assert.deepEqual(await page.$$eval('.ent .chip', (e) => e.map((x) => x.textContent.trim())), ['New']);
    await context.close();
  });
});

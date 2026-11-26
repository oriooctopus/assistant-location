// Insights views and the Ask box on the real page: view tiles/list/page, live re-render, CRUD, Save as view, tag chip, auto-grow + expand, Cmd/Ctrl+Enter.
// WebKit only (GL_WEBKIT_PW/GL_WEBKIT_EXEC, see ~/.claude/bin/cycle-webkit.sh); skipped without it.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const haveWebkit = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = haveWebkit ? await import(process.env.GL_WEBKIT_PW) : null;

const OLIVER = '78b76b33-e11c-4491-baa4-28aa38bd17c6', ESME = '31f233a3-8acf-4d0f-a609-1f3854c6613e';
const NOW = '2026-11-23T15:00:00Z';
const COUPLE = { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 };
const MEMBERS = [{ user_id: OLIVER, name: 'Oliver', checkin_time: '21:00', hits_self: false }, { user_id: ESME, name: 'Esme', checkin_time: '21:00', hits_self: true }];
const EMPTY = ['items', 'todos', 'todo_events', 'todo_comments', 'todo_nudges', 'checkins', 'fight_markers', 'fight_notes', 'rewards', 'redemptions', 'nudges', 'nudge_sends', 'nudge_replies', 'nudge_awards', 'challenges', 'challenge_logs', 'upsets', 'issues', 'kudos'];
function seed(uid, convs) {
  const rows = Object.fromEntries(EMPTY.map((t) => [t, {}]));
  const sd = {
    session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: uid, email: 'x@x.test' } },
    ['shared.' + uid]: { couple: COUPLE, members: MEMBERS, rows, cursors: {}, outbox: [], deadLetters: [] },
    ['priv.' + uid]: { fights: [], nudges: [], nudge_sends: [], prefs: {}, queued: [], drafts: {} },
  };
  if (convs) sd['ins.' + uid] = convs;
  return sd;
}

describe('insights views + composer (webkit)', { skip: !haveWebkit }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  // box(req) -> {status, body}; held answers: return a promise to keep the request open. Every box call lands in `boxCalls`.
  async function open({ uid = OLIVER, box, convs, live } = {}) {
    const boxCalls = [];
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(NOW));
    await context.addInitScript(({ sd }) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: 'https://box.test', insAutoDelays: [] };
      if (!sessionStorage.getItem('seeded')) { sessionStorage.setItem('seeded', '1'); for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k])); }
    }, { sd: seed(uid, convs) });
    // live: POST /insights answers with a stream the test feeds by hand (window.__sc), so a half-finished answer can be looked at.
    if (live) await context.addInitScript(() => {
      const real = window.fetch; window.__posts = [];
      window.fetch = (u, o) => {
        if (String(u).endsWith('/insights') && o && o.method === 'POST') {
          window.__posts.push(JSON.parse(o.body));
          return Promise.resolve(new Response(new ReadableStream({ start(c) { window.__sc = c; } }), { status: 200, headers: { 'Content-Type': 'text/event-stream' } }));
        }
        return real.call(window, u, o);
      };
    });
    await context.route('**/cycle.css', (r) => r.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(new URL(r.request().url()).pathname.endsWith('couples') ? [COUPLE] : new URL(r.request().url()).pathname.endsWith('members') ? MEMBERS : []) }));
    await context.route('https://box.test/**', async (route) => {
      const req = route.request(), u = new URL(req.url()), rec = { method: req.method(), path: u.pathname, query: u.search, body: req.postData() ? JSON.parse(req.postData()) : null };
      boxCalls.push(rec);
      const r = box && u.pathname.startsWith('/insights') ? await box(rec) : undefined; // other box paths (state backups) are refused, as when offline
      if (!r) return route.abort();
      if (r.sse) return route.fulfill({ status: 200, contentType: 'text/event-stream', body: r.sse.map((e) => 'data: ' + JSON.stringify(e) + '\n\n').join('') });
      return route.fulfill({ status: r.status, contentType: 'application/json', body: JSON.stringify(r.body) });
    });
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; }); if (process.env.DBG) page.on('console', (m) => console.log('CONSOLE', m.text()));
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.tabbar');
    return { context, page, boxCalls };
  }

  const posts = (o) => o.boxCalls.filter((c) => c.method === 'POST' && c.path === '/insights');
  const writes = (o, m) => o.boxCalls.filter((c) => c.method === m);
  const answer = (text, extra = {}) => ({ sse: [{ t: 'start', mode: 'normal', model: 'opus' }, { t: 'd', text }, { t: 'done', conversation_id: 'x', answer: text, mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0, ...extra }] });
  const STAT = { type: 'stats', tiles: [{ dataset: 'summary', key: 'total_fights' }] };
  const CHART = { type: 'chart', dataset: 'fight_topics', kind: 'bar', title: 'Fights by category' };
  const mkView = (o = {}) => ({ id: 'v1', title: 'Fight categories', blocks: [CHART, STAT], created: '2026-11-23T10:00:00Z', updated: '2026-11-23T10:00:00Z', history: [{ at: '2026-11-23T10:00:00Z', what: 'created', blocks: 2 }], ...o });
  const dsOf = (n, topics = [['Money', 5], ['Chores', 3]]) => ({ datasets: { summary: { id: 'summary', title: 'Totals', shape: 'values', values: { total_fights: { label: 'Fights logged', y: n, unit: 'fights' } } }, fight_topics: { id: 'fight_topics', title: 'Fight topics', shape: 'series', unit: 'fights', points: topics.map(([x, y]) => ({ x, label: x, y })) } } });
  const seedX = (views, ds) => ({ convs: [], byId: {}, x: { gems: [], techniques: [], rules: {}, changelog: [], lessons: [], text: 'Rita', followup: null, views }, ds });
  const boxFor = (state, mut) => async (req) => {
    if (req.method === 'GET') {
      if (req.path === '/insights/views') return { status: 200, body: { views: state.views } };
      if (req.path === '/insights/datasets') return state.dsFail ? { status: 500, body: { error: 'down' } } : { status: 200, body: state.ds };
      const k = { '/insights/gems': 'gems', '/insights/techniques': 'techniques', '/insights/lessons': 'lessons', '/insights/changelog': 'changelog', '/insights/followup': 'followup' }[req.path];
      return k ? { status: 200, body: { [k]: k === 'followup' ? null : [] } } : undefined;
    }
    return mut ? mut(req) : undefined;
  };

  test('views: tiles on the empty state and the list open a page that paints the dataset numbers; the next opening shows the CHANGED value', async () => {
    const state = { views: [mkView()], ds: dsOf(7) };
    const o = await open({ convs: seedX(state.views, null), box: boxFor(state) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.waitForSelector('.gems .gt[data-view="v1"]');
    assert.equal(await o.page.textContent('.gems .gt[data-view="v1"] b'), 'Fight categories');
    await o.page.click('[data-a="viewopen:v1"]');
    await o.page.waitForSelector('.vblk .bkstats b');
    assert.equal(await o.page.textContent('.vblk .bkstats b'), '7');
    assert.equal((await o.page.$$('.vblk svg .bkbar')).length, 2, 'chart drew the two topics');
    assert.ok(await o.page.textContent('.vwb'), 'no error chip'); assert.equal((await o.page.$$('.vwb .bkerr')).length, 0);
    // dataset changes on the box; reopening the view re-reads it
    state.ds = dsOf(9, [['Money', 5], ['Chores', 3], ['Time', 1]]);
    await o.page.click('[data-a="back"]');
    await o.page.click('[data-a="insto:views"]');
    await o.page.click('[data-a="viewopen:v1"]');
    await o.page.waitForFunction(() => document.querySelector('.vblk .bkstats b').textContent === '9');
    assert.equal((await o.page.$$('.vblk svg .bkbar')).length, 3);
    await o.context.close();
  });

  test('views: a block naming a dataset the box no longer has shows the visible error chip, not an empty box', async () => {
    const state = { views: [mkView({ blocks: [{ type: 'chart', dataset: 'gone' }] })], ds: dsOf(1) };
    const o = await open({ convs: seedX(state.views, null), box: boxFor(state) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.click('[data-a="insto:views"]'); await o.page.click('[data-a="viewopen:v1"]');
    await o.page.waitForSelector('.vwb .bkerr');
    assert.match(await o.page.textContent('.vwb .bkerr'), /dataset "gone" is not available/);
    await o.context.close();
  });

  test('views: a failed dataset refresh shows Retry, and Retry re-reads', async () => {
    const state = { views: [mkView()], ds: dsOf(7), dsFail: true };
    const o = await open({ convs: seedX(state.views, dsOf(5)), box: boxFor(state) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.click('[data-a="insto:views"]'); await o.page.click('[data-a="viewopen:v1"]');
    await o.page.waitForSelector('[data-a="viewretry"]');
    state.dsFail = false; await o.page.click('[data-a="viewretry"]');
    await o.page.waitForFunction(() => document.querySelector('.vblk .bkstats b').textContent === '7' && !document.querySelector('[data-a="viewretry"]'));
    await o.context.close();
  });

  test('views CRUD: rename shows at once and PATCHes, delete a block and reorder PATCH the block list, delete removes it, history lists the change', async () => {
    const state = { views: [mkView()], ds: dsOf(7) };
    const o = await open({ convs: seedX(state.views, dsOf(7)), box: boxFor(state, async (req) => {
      if (req.method === 'PATCH') { const v = { ...state.views[0], ...req.body, updated: 'x', history: [...state.views[0].history, { at: '2026-11-24T10:00:00Z', what: 'edited', changes: Object.fromEntries(Object.keys(req.body).map((k) => [k, 1])) }] }; state.views = [v]; return { status: 200, body: { view: v } }; }
      if (req.method === 'DELETE') { state.views = []; return { status: 200, body: { ok: true } }; }
    }) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.click('[data-a="insto:views"]'); await o.page.click('[data-a="viewopen:v1"]');
    await o.page.click('[data-a="viewedit"]');
    await o.page.click('[data-a="viewrename"]');
    await o.page.fill('[data-d="view_name"]', 'Fights by topic');
    await o.page.click('[data-a="viewrenamesave"]');
    await o.page.waitForFunction(() => document.querySelector('.insp .hd h2').textContent === 'Fights by topic');
    await o.page.waitForFunction(() => document.querySelectorAll('.list .hist').length === 2);
    assert.deepEqual(writes(o, 'PATCH')[0].body, { title: 'Fights by topic' });
    await o.page.click('[data-a="viewmove:0:1"]');
    await o.page.waitForFunction(() => document.querySelector('.vblk .bkstats'));
    assert.deepEqual(writes(o, 'PATCH')[1].body.blocks.map((b) => b.type), ['stats', 'chart']);
    assert.equal(await o.page.evaluate(() => document.querySelector('.vblk').querySelector('.bkstats') ? 'stats-first' : 'chart-first'), 'stats-first');
    await o.page.click('[data-a="viewblkdel:0"]');
    await o.page.waitForFunction(() => document.querySelectorAll('.vblk').length === 1);
    assert.deepEqual(writes(o, 'PATCH')[2].body.blocks, [CHART]);
    await o.page.click('[data-a="viewdel:v1"]');
    await o.page.waitForFunction(() => !document.querySelector('[data-a="viewopen:v1"]'));
    assert.equal(writes(o, 'DELETE')[0].path, '/insights/views/v1');
    assert.equal((await o.page.$$('[data-a="viewopen:v1"]')).length, 0);
    await o.context.close();
  });

  test('views: a failed save keeps the edit visible and offers Retry (one PATCH per try)', async () => {
    const state = { views: [mkView()], ds: dsOf(7) }; let fail = true;
    const o = await open({ convs: seedX(state.views, dsOf(7)), box: boxFor(state, async (req) => { if (req.method === 'PATCH') return fail ? { status: 500, body: { error: 'x' } } : { status: 200, body: { view: { ...state.views[0], title: req.body.title } } }; }) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.click('[data-a="insto:views"]'); await o.page.click('[data-a="viewopen:v1"]');
    await o.page.click('[data-a="viewedit"]'); await o.page.click('[data-a="viewrename"]'); await o.page.fill('[data-d="view_name"]', 'New name'); await o.page.click('[data-a="viewrenamesave"]');
    await o.page.waitForSelector('[data-a="insredo"]');
    assert.equal(await o.page.textContent('.insp .hd h2'), 'New name');
    fail = false; await o.page.click('[data-a="insredo"]');
    await o.page.waitForFunction(() => !document.querySelector('[data-a="insredo"]'));
    assert.equal(writes(o, 'PATCH').length, 2);
    await o.context.close();
  });

  test('Save as view: shows only for an answer with dataset blocks, flips to Saved before the box answers, POSTs {from}, becomes a link to the view', async () => {
    let release; const gate = new Promise((r) => { release = r; });
    const state = { views: [], ds: dsOf(7) };
    const text = 'Here.\n```ui\n' + JSON.stringify(CHART) + '\n```';
    const conv = { id: 'c1', title: 'Fight categories chat', created_at: '2026-11-24T10:00:00Z', updated_at: '2026-11-24T10:00:00Z', model: 'opus', messages: [{ role: 'user', text: 'chart', at: 'x' }, { role: 'assistant', text, mode: 'normal', model: 'opus', at: 'x' }, { role: 'user', text: 'hi', at: 'x' }, { role: 'assistant', text: 'plain', mode: 'normal', model: 'opus', at: 'x' }] };
    const o = await open({ convs: { ...seedX([], dsOf(7)), convs: [{ id: 'c1', title: conv.title, updated_at: conv.updated_at }], byId: { c1: conv } }, box: boxFor(state, async (req) => {
      if (req.method === 'POST' && req.path === '/insights/views') { await gate; const v = mkView({ id: 'v9', blocks: [CHART], title: conv.title }); state.views = [v]; return { status: 200, body: { view: v } }; }
    }) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.click('[data-a="insto:inslist"], [data-a="go:inslist"]'); await o.page.click('[data-a="insopen:c1"]');
    await o.page.waitForSelector('.im.a');
    await o.page.click('[data-a="insmore:1"]');
    assert.equal((await o.page.$$('[data-a="insview:1"]')).length, 1);
    assert.equal((await o.page.$$('[data-a="insview:3"]')).length, 0, 'plain answer has no Save as view');
    await o.page.click('[data-a="insview:1"]');
    await o.page.waitForSelector('.im.vlk.dis');
    assert.match(await o.page.textContent('.im.vlk'), /Saved: Fight categories chat/);
    assert.equal((await o.page.$$('[data-a="insview:1"]')).length, 0);
    release();
    await o.page.waitForSelector('.im.vlk:not(.dis)[data-a="viewopen:v9"]');
    assert.deepEqual(writes(o, 'POST').filter((c) => c.path === '/insights/views')[0].body, { from: { conversation_id: 'c1', index: 1 } });
    await o.page.click('[data-a="viewopen:v9"]');
    await o.page.waitForSelector('.vwb .bkbar');
    await o.context.close();
  });

  test('chat tag: the done event\'s view becomes a "Made it" link that opens the view; a view error shows with Retry', async () => {
    const state = { views: [mkView()], ds: dsOf(7) };
    const o = await open({ convs: seedX(state.views, dsOf(7)), box: boxFor(state, async (req) => (req.path === '/insights' ? answer('This view has the topics.', { views: [{ id: 'v1', title: 'Fight categories' }], view_errors: ['Bad: block 1: dataset "nope" is not available'] }) : undefined)) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'create an insights view of our fight categories'); await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.vlk');
    assert.equal((await o.page.textContent('.im.vlk')).trim(), 'Made it: Fight categories');
    assert.match(await o.page.textContent('.im.err'), /dataset "nope" is not available/);
    assert.equal((await o.page.$$('.im.err [data-a], .im.err .txtbtn')).length >= 1, true);
    await o.page.click('.im.vlk');
    await o.page.waitForSelector('.vwb .bkstats');
    await o.context.close();
  });

  test('Ask box: grows with its text, stops at 40% of the viewport and scrolls inside; the expand button shows only past 3 lines', async () => {
    const o = await open({ convs: seedX([], null), box: boxFor({ views: [], ds: dsOf(1) }) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.waitForSelector('.insbar textarea');
    const probe = () => o.page.evaluate(() => { const t = document.querySelector('.insbar textarea'); return { h: t.getBoundingClientRect().height, vh: (window.visualViewport || window).height || window.innerHeight, ov: getComputedStyle(t).overflowY, xb: getComputedStyle(document.querySelector('.insxb')).display }; });
    const h0 = (await probe()).h;
    await o.page.fill('[data-d="ins_msg"]', 'a\nb\nc');
    let p = await probe(); assert.ok(p.h > h0, `grew for 3 lines (${h0} -> ${p.h})`); assert.equal(p.xb, 'none', 'no expand at 3 lines');
    await o.page.fill('[data-d="ins_msg"]', 'a\nb\nc\nd');
    p = await probe(); assert.equal(p.xb, 'flex', 'expand appears at 4 lines');
    await o.page.fill('[data-d="ins_msg"]', Array.from({ length: 60 }, (_, i) => 'line ' + i).join('\n'));
    p = await probe(); assert.ok(p.h <= p.vh * 0.4 + 1, `capped: ${p.h} <= ${p.vh * 0.4}`); assert.ok(p.h >= p.vh * 0.4 - 24, `reached the cap: ${p.h}`); assert.equal(p.ov, 'auto');
    await o.page.fill('[data-d="ins_msg"]', 'short');
    p = await probe(); assert.equal(p.h, h0, 'shrinks back'); assert.equal(p.xb, 'none');
    await o.context.close();
  });

  test('Expand: opens a full-height composer with the same draft, Collapse keeps what was typed, Send from it sends once and closes it; the Send glyph is not the expand glyph', async () => {
    const state = { views: [], ds: dsOf(1) };
    const o = await open({ convs: seedX([], null), box: boxFor(state, async (req) => (req.path === '/insights' ? answer('ok') : undefined)) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'one\ntwo\nthree\nfour');
    const sym = (sel) => o.page.evaluate((s) => document.querySelector(s + ' use').getAttribute('href'), sel);
    assert.equal(await sym('[data-a="inssend"]'), '#i-send'); assert.equal(await sym('[data-a="insexpand"]'), '#i-expand');
    assert.notEqual(await o.page.evaluate(() => document.querySelector('#i-send path').getAttribute('d')), await o.page.evaluate(() => document.querySelector('#i-expand path').getAttribute('d')));
    await o.page.click('[data-a="insexpand"]');
    await o.page.waitForSelector('.insxt');
    assert.equal(await o.page.inputValue('.insxt'), 'one\ntwo\nthree\nfour');
    assert.ok((await o.page.evaluate(() => document.querySelector('.insxt').getBoundingClientRect().height)) > 844 * 0.4, 'full-height box');
    await o.page.fill('.insxt', 'one\ntwo\nthree\nfour\nfive');
    await o.page.click('[data-a="inscollapse"]');
    await o.page.waitForSelector('.insbar textarea');
    assert.equal(await o.page.inputValue('.insbar textarea'), 'one\ntwo\nthree\nfour\nfive');
    await o.page.click('[data-a="insexpand"]'); await o.page.waitForSelector('.insxt');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.a');
    assert.equal(posts(o).length, 1); assert.equal(posts(o)[0].body.message, 'one\ntwo\nthree\nfour\nfive');
    assert.equal((await o.page.$$('.insxt')).length, 0, 'closed after send');
    await o.context.close();
  });

  test('Expand then Collapse returns to the newest message of a long chat, not the top of it', async () => {
    const msgs = []; for (let i = 0; i < 20; i++) msgs.push({ role: 'user', text: 'q' + i + ' ' + 'word '.repeat(40), at: 'x' }, { role: 'assistant', text: 'a' + i + ' ' + 'word '.repeat(40), mode: 'normal', model: 'opus', at: 'x' });
    const conv = { id: 'c1', title: 'Long', created_at: '2026-11-24T10:00:00Z', updated_at: '2026-11-24T10:00:00Z', model: 'opus', messages: msgs };
    const o = await open({ convs: { ...seedX([], null), convs: [{ id: 'c1', title: 'Long', updated_at: conv.updated_at }], byId: { c1: conv } }, box: boxFor({ views: [], ds: dsOf(1) }) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.click('[data-a="go:inslist"]'); await o.page.click('[data-a="insopen:c1"]');
    await o.page.waitForSelector('.im.a');
    await o.page.evaluate(() => { const s = document.querySelector('.scr'); s.scrollTop = s.scrollHeight; });
    assert.ok((await o.page.evaluate(() => document.querySelector('.scr').scrollHeight)) > 3000, 'chat is long enough to scroll');
    await o.page.fill('[data-d="ins_msg"]', 'a\nb\nc\nd');
    await o.page.click('[data-a="insexpand"]'); await o.page.waitForSelector('.insxt');
    await o.page.click('[data-a="inscollapse"]'); await o.page.waitForSelector('.insbar textarea');
    await o.page.waitForFunction(() => { const s = document.querySelector('.scr'); return s.scrollTop > 0 && s.scrollHeight - s.scrollTop - s.clientHeight < 4; }, null, { timeout: 3000 });
    await o.context.close();
  });

  test('Cmd+Enter and Ctrl+Enter send exactly once (also a held key and a double press); plain Enter only adds a newline; works in the expanded composer', async () => {
    const o = await open({ convs: seedX([], null), box: boxFor({ views: [], ds: dsOf(1) }, async (req) => (req.path === '/insights' ? answer('ok') : undefined)) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.click('[data-d="ins_msg"]'); await o.page.keyboard.type('first');
    await o.page.keyboard.press('Enter');
    assert.equal(await o.page.inputValue('[data-d="ins_msg"]'), 'first\n'); assert.equal(posts(o).length, 0, 'plain Enter does not send');
    await o.page.keyboard.type('line');
    // two Meta+Enter keydowns back to back (the second is a repeat in a real held key)
    await o.page.evaluate(() => { const t = document.querySelector('[data-d="ins_msg"]'); for (const rep of [false, true, false]) t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', metaKey: true, repeat: rep, bubbles: true, cancelable: true })); });
    await o.page.waitForSelector('.im.a');
    assert.equal(posts(o).length, 1, 'sent exactly once'); assert.equal(posts(o)[0].body.message, 'first\nline');
    // Ctrl+Enter from the expanded composer
    await o.page.fill('[data-d="ins_msg"]', 'a\nb\nc\nd'); await o.page.click('[data-a="insexpand"]'); await o.page.waitForSelector('.insxt');
    await o.page.focus('.insxt'); await o.page.keyboard.press('Control+Enter');
    await o.page.waitForFunction(() => document.querySelectorAll('.im.a').length === 2);
    assert.equal(posts(o).length, 2); assert.equal(posts(o)[1].body.message, 'a\nb\nc\nd');
    await o.context.close();
  });

  test('suggestion chips: the text never touches the pill border, however many lines it wraps to', async () => {
    const o = await open({ convs: seedX([], null), box: boxFor({ views: [], ds: dsOf(1) }) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.waitForSelector('.chip.ic2');
    const gaps = await o.page.evaluate(() => [...document.querySelectorAll('.chip.ic2')].map((c) => { const r = document.createRange(); r.selectNodeContents(c); const t = r.getBoundingClientRect(), b = c.getBoundingClientRect(); return Math.min(t.top - b.top, b.bottom - t.bottom); }));
    assert.equal(gaps.length, 4); assert.ok(gaps.every((g) => g >= 8), 'vertical padding >= 8px: ' + gaps.join(','));
    await o.context.close();
  });

  test('Esme never sees any of it: no views fetch, no tiles, no Insights tab', async () => {
    const o = await open({ uid: ESME, convs: undefined, box: boxFor({ views: [mkView()], ds: dsOf(1) }) });
    assert.equal((await o.page.$$('[data-a="tab:insights"]')).length, 0);
    assert.equal(o.boxCalls.filter((c) => c.path.startsWith('/insights')).length, 0);
    await o.context.close();
  });
});

// "Talk it through": the asynchronous four-step talk (Side, Heard, Own up, Requests) on a fight. Two browser contexts (Oliver, Esme)
// talk to ONE in-memory fake Supabase that applies the same visibility rule as the live RLS policy tt_select (the real policy is
// proven against the live project in cycle-tracker supabase/rls.test.mjs, "talk:" checks). Nothing here touches live Supabase.
// Runs in Chromium, plus WebKit when GL_WEBKIT_PW/GL_WEBKIT_EXEC are set. Not related to cycle-talk.test.mjs (the voice Talk).
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
const SHOTS = process.env.TT_SHOTS; // when set, the flow test saves a screenshot of every real screen here

const ME = 'u-me', HER = 'u-her', HOUR = 36e5;
const ago = (h) => new Date(Date.now() - h * HOUR).toISOString();
const COUPLE = { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 };
const MEMBERS = [{ user_id: ME, name: 'Oliver', checkin_time: '21:00', hits_self: false }, { user_id: HER, name: 'Esme', checkin_time: '21:00', hits_self: true }];
const HIDDEN_UNTIL_DONE = { side: 'side_done', ownup: 'ownup_done' };

// The fake server. visible() is tt_select from the migration, word for word.
function makeServer(tables) {
  const t = { fight_markers: {}, fight_notes: {}, talkthrough_events: {}, items: {}, todos: {}, ...tables };
  const posts = [], offline = new Set();
  const finished = (uid, marker, kind) => Object.values(t.talkthrough_events).some((e) => e.fight_marker_id === marker && e.author_id === uid && e.kind === kind);
  const visible = (uid, e) => e.author_id === uid || ['side_done', 'ownup_done', 'requests_done', 'heard', 'verdict'].includes(e.kind) ||
    (HIDDEN_UNTIL_DONE[e.kind] && finished(uid, e.fight_marker_id, HIDDEN_UNTIL_DONE[e.kind]));
  async function handle(uid, route) {
    const req = route.request(), u = new URL(req.url()), table = u.pathname.replace('/rest/v1/', '');
    if (offline.has(uid)) return route.abort();
    const ok = (status, body) => route.fulfill({ status, contentType: 'application/json', body: body === undefined ? '' : JSON.stringify(body) });
    if (req.method() === 'GET') {
      if (table === 'couples') return ok(200, [COUPLE]);
      if (table === 'members') return ok(200, MEMBERS);
      if (!t[table]) return ok(200, []);
      const rows = Object.values(t[table]);
      return ok(200, table === 'talkthrough_events' ? rows.filter((e) => visible(uid, e)) : rows);
    }
    if (req.method() === 'POST') {
      const row = JSON.parse(req.postData());
      posts.push({ uid, table, row });
      if (!t[table]) t[table] = {};
      t[table][row.id] = { updated_at: new Date().toISOString(), ...row };
      return ok(201);
    }
    if (req.method() === 'PATCH') {
      const id = decodeURIComponent(u.search.match(/id=eq\.([^&]+)/)[1]);
      Object.assign(t[table][id], JSON.parse(req.postData()), { updated_at: new Date().toISOString() });
      return ok(200, [t[table][id]]);
    }
    return ok(204);
  }
  return { t, posts, offline, handle };
}
const marker = (o) => ({ id: 'fp', couple_id: 'c1', logged_by: ME, at: ago(3), repaired_at: null, hit_self: false, hit_related: null, hit_count: null, summary: null, ...o });
const note = (id, uid, body, o) => ({ id, couple_id: 'c1', fight_marker_id: 'fp', author_id: uid, body, created_at: ago(2), updated_at: ago(2), deleted_at: null, ...o });

for (const [name, type] of Object.entries(engines)) describe(name, () => {
  let browser;
  before(async () => { browser = await type.launch({ headless: true }); });
  after(async () => { await browser.close(); });

  // One phone for one person, wired to the shared fake server.
  async function phone(srv, uid, route = 'fight/fp') {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.addInitScript(({ uid }) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) {
        localStorage.setItem('cycle:session', JSON.stringify({ access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: uid, email: uid + '@x.test' } }));
        localStorage.setItem('cycle:priv.' + uid, JSON.stringify({ fights: [], nudges: [], nudge_sends: [], prefs: {}, queued: [], drafts: {}, vents: [], ventSeen: {} }));
      }
    }, { uid });
    await context.route('**/cycle.css', (r) => r.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (r) => srv.handle(uid, r));
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e));
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await sync(page);
    await page.evaluate((r) => cycleNative.route(r), route);
    await page.waitForSelector('.fd');
    return { context, page, errors, uid };
  }
  const sync = async (page) => { await page.evaluate(() => CycleStore.syncNow()); await page.waitForTimeout(150); };
  const text = (page, sel = '.phone') => page.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim());
  const shot = async (page, file) => { if (SHOTS && name === (engines.webkit ? 'webkit' : 'chromium')) await page.screenshot({ path: path.join(SHOTS, file + '.png') }); };
  async function side(p, what, about) {
    if (what !== undefined) await p.page.fill('textarea[data-d="ts_what"]', what);
    if (about !== undefined) await p.page.fill('textarea[data-d="ts_about"]', about);
    await p.page.click('[data-a="ttside"]');
  }
  async function doHeard(p, heard, sense) {
    await p.page.fill('textarea[data-d="th_heard"]', heard); await p.page.fill('textarea[data-d="th_sense"]', sense); await p.page.click('[data-a="ttheard"]');
  }
  // Both people through step 1 with fresh text, returning both phones on the Heard step.
  async function bothSides(srv, ph) {
    const o = ph.o, e = ph.e;
    await o.page.click('[data-a="ttstart:fp"]'); await side(o, 'I felt attacked at 1am.', 'I want money talks when rested.'); await sync(o.page);
    await sync(e.page); await e.page.click('[data-a="ttgo:fp"]'); await side(e, 'I felt left out.', 'The trip is $355.'); await sync(e.page); await sync(o.page);
  }
  async function pair(tables) {
    const srv = makeServer({ fight_markers: { fp: marker() }, ...tables });
    const o = await phone(srv, ME), e = await phone(srv, HER);
    return { srv, o, e, ph: { o, e }, close: () => Promise.all([o.context.close(), e.context.close()]) };
  }

  test('full flow for both people: Side, Heard (Not quite, revise, Got it), Own up, Requests', async () => {
    const { srv, o, e, ph, close } = await pair();
    await shot(o.page, 'fight-not-started');
    assert.match(await text(o.page, '.tt-card'), /Talk it through/);
    await o.page.click('[data-a="ttstart:fp"]');
    await shot(o.page, 'step1-nothing-logged');
    await side(o, 'I felt attacked at 1am.', 'I want money talks when rested.');
    await sync(o.page);
    // Oliver now waits; Esme's card says it is her turn.
    assert.match(await text(o.page), /Waiting on Esme/);
    await sync(e.page); await e.page.reload(); await sync(e.page); await e.page.evaluate(() => cycleNative.route('fight/fp')); await e.page.waitForSelector('.tt-card');
    assert.match(await text(e.page, '.tt-card'), /Step 1 of 4 · Side/); assert.match(await text(e.page, '.tt-card'), /Your turn/);
    await shot(e.page, 'fight-in-progress-your-turn');
    await e.page.click('[data-a="ttgo:fp"]');
    assert.match(await text(e.page, '.ttk'), /Oliver's side is in · new parts hidden until yours is/);
    await shot(e.page, 'step1-partner-side-in');
    await side(e, 'I felt left out.', 'The trip is $355.');
    await sync(e.page); await sync(o.page);
    // Step 2: each sees the other's side, source-marked, plus the two reflection fields.
    assert.match(await text(o.page, '.ttk'), /Esme's side[\s\S]*Written here[\s\S]*I felt left out\.[\s\S]*Written here[\s\S]*The trip is \$355\./);
    assert.match(await text(o.page, '.ttk'), /What I heard[\s\S]*What makes sense/);
    await shot(o.page, 'step2-reading-and-heard');
    await doHeard(o, 'You felt rejected.', 'Makes sense you felt unwanted.');
    await doHeard(e, 'You felt shut down.', 'Makes sense at 1am.');
    await sync(o.page); await sync(e.page); await sync(o.page);
    // Esme (author of the side Oliver reflected on) says Not quite, with a note.
    assert.match(await text(e.page, '.ttk'), /Oliver heard[\s\S]*You felt rejected\./);
    await shot(e.page, 'step2-verdict');
    await e.page.fill('textarea[data-d="tv_note"]', 'More about the trip cost.');
    await e.page.click('[data-a="ttverdict:not_quite"]');
    await o.page.click('[data-a="ttverdict:got_it"]');
    await sync(e.page); await sync(o.page);
    // Oliver gets the step back: her note, his old words prefilled, revise, send.
    assert.match(await text(o.page, '.ttk'), /Esme said not quite[\s\S]*More about the trip cost\./);
    assert.equal(await o.page.inputValue('textarea[data-d="th_heard"]'), 'You felt rejected.');
    await shot(o.page, 'step2-not-quite-revise');
    await o.page.fill('textarea[data-d="th_heard"]', 'You felt rejected and the $355 mattered.');
    await o.page.click('[data-a="ttheard"]');
    await sync(o.page); await sync(e.page);
    await e.page.click('[data-a="ttverdict:got_it"]');
    await sync(e.page); await sync(o.page);
    // Step 3
    assert.match(await text(o.page, '.tt-prog'), /3 Own up/);
    // A finished step is a flat label with a rule above it. The app's global .done class is a 44px outlined pill and once leaked in here.
    assert.ok((await o.page.locator('.tt-s.tt-done').first().boundingBox()).height < 36, 'done step is not a pill');
    await shot(o.page, 'step3-own-up');
    await o.page.fill('textarea[data-d="to_part"]', 'I said no before hearing you out.'); await o.page.click('[data-a="ttown"]');
    await sync(o.page); await sync(e.page);
    assert.match(await text(e.page, '.ttk'), /Oliver's is in · hidden until yours is/);
    await e.page.fill('textarea[data-d="to_part"]', 'I texted at 1am.'); await e.page.click('[data-a="ttown"]');
    await sync(e.page); await sync(o.page);
    // Step 4: two lists, lines added then submitted
    assert.match(await text(o.page, '.tt-prog'), /4 Requests/);
    await o.page.fill('textarea[data-d="tr_next"]', 'No big topics after 11pm'); await o.page.click('[data-a="ttreq:next"]');
    await o.page.fill('textarea[data-d="tr_decision"]', 'Decide trip budget by Thursday'); await o.page.click('[data-a="ttreq:decision"]');
    await shot(o.page, 'step4-requests');
    await o.page.click('[data-a="ttreqs"]');
    await e.page.click('[data-a="ttreqs"]');
    await sync(o.page); await sync(e.page); await sync(o.page);
    assert.match(await text(o.page, '.ttk'), /Done/);
    await o.page.click('[data-a="back"]');
    assert.match(await text(o.page, '.tt-card'), /Done/);
    assert.deepEqual([...o.errors, ...e.errors], []);
    await close();
  });

  test('step 1 prefills from the logged note and analysis; untouched offers Use as my side, which writes no new text', async () => {
    const { srv, o, close } = await pair({ fight_notes: { n1: note('n1', ME, 'She texted at 1am.'), a1: note('a1', ME, 'Money talks when rested.', { kind: 'analysis', linked_fight_ids: [] }) } });
    await sync(o.page); await o.page.click('[data-a="ttstart:fp"]');
    assert.equal(await o.page.inputValue('textarea[data-d="ts_what"]'), 'She texted at 1am.');
    assert.equal(await o.page.inputValue('textarea[data-d="ts_about"]'), 'Money talks when rested.');
    const t = await text(o.page, '.ttk');
    assert.match(t, /From your note · \d+ \w+/); assert.match(t, /From your analysis · \d+ \w+/);
    assert.equal(await o.page.locator('[data-a="ttside"]').textContent(), 'Use as my side');
    await shot(o.page, 'step1-note-and-analysis-logged');
    await o.page.click('[data-a="ttside"]'); await sync(o.page);
    const ev = Object.values(srv.t.talkthrough_events).map((e) => e.kind);
    assert.deepEqual(ev, ['side_done'], 'no side text rows: the note and analysis already are the side');
    await close();
  });

  test('editing a prefilled note shows Edited with Undo, and the edit updates the note once both sides are in', async () => {
    const { srv, o, e, close } = await pair({ fight_notes: { n1: note('n1', ME, 'She texted at 1am.') } });
    await sync(o.page); await o.page.click('[data-a="ttstart:fp"]');
    assert.equal(await o.page.locator('[data-ttedit="ts_what"]').isVisible(), false);
    await o.page.fill('textarea[data-d="ts_what"]', 'She texted at 1am. I went to the other room.');
    assert.equal(await o.page.locator('[data-ttedit="ts_what"]').isVisible(), true);
    assert.match(await text(o.page, '[data-ttedit="ts_what"]'), /Edited · updates your note\s*Undo/);
    await shot(o.page, 'step1-edited-undo');
    await o.page.click('[data-a="ttundo:ts_what"]');
    assert.equal(await o.page.inputValue('textarea[data-d="ts_what"]'), 'She texted at 1am.');
    await o.page.fill('textarea[data-d="ts_what"]', 'She texted at 1am. I went to the other room.');
    await o.page.fill('textarea[data-d="ts_about"]', 'about me');
    await o.page.click('[data-a="ttside"]'); await sync(o.page);
    assert.equal(srv.t.fight_notes.n1.body, 'She texted at 1am.', 'hidden-until-both: the note itself is untouched while Esme has not submitted');
    await sync(e.page); await e.page.click('[data-a="ttgo:fp"]'); await side(e, 'her what', 'her about');
    await sync(e.page); await sync(o.page); await sync(o.page);
    assert.equal(srv.t.fight_notes.n1.body, 'She texted at 1am. I went to the other room.', 'now both are in: the edit is the note');
    const created = Object.values(srv.t.fight_notes).filter((n) => n.kind === 'analysis' && n.author_id === ME);
    assert.equal(created.length, 1); assert.equal(created[0].body, 'about me', 'new "about" text became an analysis');
    await close();
  });

  test('several logged notes stack with times and an Add field; a long note clamps with Show all', async () => {
    const long = 'word '.repeat(80).trim();
    const { o, close } = await pair({ fight_notes: { n1: note('n1', ME, 'first note', { created_at: ago(3) }), n2: note('n2', ME, long, { created_at: ago(2) }) } });
    await sync(o.page); await o.page.click('[data-a="ttstart:fp"]');
    const t = await text(o.page, '.ttk');
    assert.match(t, /From your notes[\s\S]*first note[\s\S]*Add/);
    assert.equal(await o.page.locator('.tt-cl').count(), 2);
    await shot(o.page, 'step1-several-notes');
    await o.page.click('[data-a="ttall:ts_what"]');
    assert.equal(await o.page.locator('.tt-cl').count(), 0, 'Show all removes the clamp');
    await close();
  });

  test('the partner\'s new side text never reaches the other phone before both sides are in', async () => {
    const { srv, o, e, close } = await pair();
    await o.page.click('[data-a="ttstart:fp"]'); await side(o, 'SECRET-WHAT-OLIVER', 'SECRET-ABOUT-OLIVER'); await sync(o.page);
    await sync(e.page); await e.page.waitForTimeout(300);
    const stored = await e.page.evaluate(() => JSON.stringify(Object.assign({}, localStorage)) + document.documentElement.innerHTML);
    assert.ok(!stored.includes('SECRET-WHAT-OLIVER') && !stored.includes('SECRET-ABOUT-OLIVER'), 'Esme\'s phone holds none of the hidden text');
    assert.ok(Object.values(srv.t.fight_notes).every((n) => !n.body.includes('SECRET')), 'and it is not in fight_notes either until both are in');
    // the marker is visible: her chip
    await e.page.click('[data-a="ttgo:fp"]');
    assert.match(await text(e.page, '.ttk'), /Oliver's side is in/);
    await side(e, 'her what', 'her about'); await sync(e.page); await sync(o.page); await sync(o.page);
    assert.ok(Object.values(srv.t.fight_notes).some((n) => n.body === 'SECRET-WHAT-OLIVER'), 'both in: Oliver\'s side is copied into his notes');
    await close();
  });

  test('a draft survives a reload and shows Draft saved; nothing is sent', async () => {
    const { srv, o, close } = await pair();
    await o.page.click('[data-a="ttstart:fp"]');
    await o.page.fill('textarea[data-d="ts_what"]', 'half a thought');
    assert.equal(await o.page.locator('[data-ttds="ts_what"]').isVisible(), true);
    // Wait until the draft is on disk (the priv write is debounced; a fixed sleep flaked under parallel load) before pulling the plug.
    await o.page.waitForFunction(() => localStorage.getItem('cycle:priv.u-me').includes('half a thought'));
    await o.page.reload(); await sync(o.page);
    await o.page.evaluate(() => cycleNative.route('fight/fp')); await o.page.waitForSelector('.tt-card');
    assert.match(await text(o.page, '.tt-card'), /Step 1 of 4 · Side[\s\S]*Draft saved \d+:\d\d(am|pm)/);
    await o.page.click('[data-a="ttgo:fp"]');
    assert.equal(await o.page.inputValue('textarea[data-d="ts_what"]'), 'half a thought');
    assert.deepEqual(Object.values(srv.t.talkthrough_events), []);
    await close();
  });

  test('offline: the side queues in the outbox and syncs when the connection returns', async () => {
    const { srv, o, close } = await pair();
    await o.page.click('[data-a="ttstart:fp"]');
    srv.offline.add(ME);
    await side(o, 'written offline', 'about offline');
    await o.page.waitForTimeout(700);
    assert.match(await text(o.page), /Waiting on Esme/, 'the screen already moved on from the local write');
    const q = await o.page.evaluate(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')).outbox.filter((x) => x.table === 'talkthrough_events').length);
    assert.equal(q, 3, 'two side rows and the side_done marker are queued');
    assert.deepEqual(Object.values(srv.t.talkthrough_events), []);
    srv.offline.delete(ME);
    await o.page.evaluate(() => CycleStore.retryPush()); await sync(o.page); await sync(o.page);
    const kinds = Object.values(srv.t.talkthrough_events).map((e) => e.kind).sort();
    assert.deepEqual(kinds, ['side', 'side', 'side_done']);
    await close();
  });

  test('fights list chips show step and whose turn, on both phones', async () => {
    const { o, e, close } = await pair();
    await o.page.click('[data-a="ttstart:fp"]'); await side(o, 'a', 'b'); await sync(o.page); await sync(e.page);
    await o.page.click('.tabbar [data-a="tab:fights"]'); await e.page.click('.tabbar [data-a="tab:fights"]');
    await o.page.waitForSelector('.rf'); await e.page.waitForSelector('.rf');
    assert.equal(await text(o.page, '.rf .tt-chip'), 'Talk · step 1 of 4 · Esme\'s turn');
    assert.equal(await text(e.page, '.rf .tt-chip'), 'Talk · step 1 of 4 · your turn');
    await shot(e.page, 'fights-list-chip');
    await close();
  });

  test('requests go through the ask Send hold: held items for the partner, no direct to-do, request text not in talk events', async () => {
    const { srv, o, e, ph, close } = await pair();
    await bothSides(srv, ph);
    await doHeard(o, 'h1', 's1'); await doHeard(e, 'h2', 's2'); await sync(o.page); await sync(e.page); await sync(o.page);
    await o.page.click('[data-a="ttverdict:got_it"]'); await e.page.click('[data-a="ttverdict:got_it"]'); await sync(o.page); await sync(e.page); await sync(o.page);
    await o.page.fill('textarea[data-d="to_part"]', 'mine'); await o.page.click('[data-a="ttown"]'); await e.page.fill('textarea[data-d="to_part"]', 'hers'); await e.page.click('[data-a="ttown"]');
    await sync(o.page); await sync(e.page); await sync(o.page);
    await o.page.fill('textarea[data-d="tr_next"]', 'NO-BIG-TOPICS'); await o.page.click('[data-a="ttreq:next"]');
    await o.page.fill('textarea[data-d="tr_decision"]', 'DECIDE-BUDGET'); await o.page.click('[data-a="ttreqs"]');
    await sync(o.page);
    const items = Object.values(srv.t.items);
    assert.deepEqual(items.map((i) => i.body).sort(), ['DECIDE-BUDGET', 'NO-BIG-TOPICS']);
    assert.ok(items.every((i) => i.kind === 'ask' && i.status === 'held' && i.recipient_id === HER && i.sender_id === ME), 'held asks to Esme');
    assert.deepEqual(Object.values(srv.t.todos), [], 'no to-do exists until the hold ends');
    assert.ok(!JSON.stringify(Object.values(srv.t.talkthrough_events)).includes('NO-BIG-TOPICS'), 'request text is not in the talk events');
    await close();
  });

  test('no notification of any kind: a whole talk writes only talk events, notes and the held asks', async () => {
    const { srv, o, e, ph, close } = await pair();
    await bothSides(srv, ph);
    await doHeard(o, 'h1', 's1'); await sync(o.page);
    const tables = new Set(srv.posts.map((p) => p.table));
    for (const bad of ['nudges', 'nudge_sends', 'todo_nudges', 'issues']) assert.ok(!tables.has(bad), bad + ' untouched');
    assert.deepEqual([...tables].filter((t) => !['talkthrough_events', 'fight_notes'].includes(t)), []);
    await close();
  });

  test('the "?" opens the explainer with How and Why tabs, and nothing else explains', async () => {
    const { o, close } = await pair();
    await o.page.click('.tt-card .tt-q');
    let t = await text(o.page, '.tt-info');
    assert.match(t, /How this works[\s\S]*1 · Your side\. Each of you writes what happened for you and what it's about for you\. New parts stay hidden until both are in\./);
    assert.match(t, /Your own time\. You don't do this together\. Leave any time and your draft is kept\./);
    await shot(o.page, 'explainer-how');
    await o.page.click('[data-a="ttinfo:why"]');
    t = await text(o.page, '.tt-info');
    assert.match(t, /Feeling understood calms the body\.[\s\S]*Shenk & Fruzzetti, 2011[\s\S]*Not proven[\s\S]*Gottman et al\., 1998/);
    await shot(o.page, 'explainer-why');
    await o.page.click('.tt-info ~ * , .dim').catch(() => {});
    await close();
  });

  test('back from the step screen returns to the fight at the same scroll offset, by button', async () => {
    const { o, close } = await pair({ fight_notes: Object.fromEntries(Array.from({ length: 14 }, (_, i) => ['n' + i, note('n' + i, ME, 'a long note number ' + i + ' '.repeat(1) + 'filler '.repeat(30), { created_at: ago(20 - i) })])) });
    await sync(o.page); await o.page.evaluate(() => cycleNative.route('fight/fp')); await o.page.waitForSelector('.tt-card');
    await o.page.evaluate(() => { document.querySelector('.scr').scrollTop = 300; });
    const before = await o.page.evaluate(() => document.querySelector('.scr').scrollTop);
    assert.ok(before > 100, 'the fight page scrolls (' + before + ')');
    await o.page.click('[data-a="ttstart:fp"]'); await o.page.waitForSelector('.tt-prog');
    assert.equal(await o.page.evaluate(() => document.querySelector('.scr').scrollTop), 0, 'a fresh screen starts at the top');
    assert.match(await text(o.page, '[data-a="back"]'), /Fight/);
    await o.page.click('[data-a="back"]'); await o.page.waitForSelector('.tt-card');
    assert.equal(await o.page.evaluate(() => document.querySelector('.scr').scrollTop), before);
    await close();
  });
});

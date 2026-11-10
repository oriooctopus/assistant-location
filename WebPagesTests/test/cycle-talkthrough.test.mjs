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
  const posts = [], patches = [], refused = [], offline = new Set();
  const finished = (uid, marker, kind) => Object.values(t.talkthrough_events).some((e) => e.fight_marker_id === marker && e.author_id === uid && e.kind === kind);
  const visible = (uid, e) => e.author_id === uid || ['side_done', 'ownup_done', 'requests_done', 'heard', 'verdict'].includes(e.kind) ||
    (HIDDEN_UNTIL_DONE[e.kind] && finished(uid, e.fight_marker_id, HIDDEN_UNTIL_DONE[e.kind]));
  // What the live policy tt_insert (20261110000004 + 20261110000005) and the table's constraints refuse, as {status, code}.
  const hasRow = (uid, e, kind) => Object.values(t.talkthrough_events).some((x) => x.fight_marker_id === e.fight_marker_id && x.author_id === uid && x.kind === kind);
  const hasNote = (uid, marker) => Object.values(t.fight_notes).some((n) => n.fight_marker_id === marker && n.author_id === uid && !n.deleted_at);
  function refuse(uid, table, e) {
    if (t[table] && t[table][e.id]) return { status: 409, code: '23505' };
    if (table !== 'talkthrough_events') return null;
    if (e.author_id !== uid) return { status: 403, code: '42501' };
    if (['side_done', 'ownup_done', 'requests_done'].includes(e.kind) && hasRow(uid, e, e.kind)) return { status: 409, code: '23505' };
    if (e.kind === 'side_done' && !hasRow(uid, e, 'side') && !hasNote(uid, e.fight_marker_id)) return { status: 403, code: '42501' };
    if (e.kind === 'ownup_done' && !hasRow(uid, e, 'ownup')) return { status: 403, code: '42501' };
    if (e.kind === 'side' && hasRow(uid, e, 'side_done')) return { status: 403, code: '42501' };
    if (e.kind === 'ownup' && hasRow(uid, e, 'ownup_done')) return { status: 403, code: '42501' };
    if (e.kind === 'verdict') {
      const h = t.talkthrough_events[e.ref_id];
      if (!h || h.kind !== 'heard' || h.fight_marker_id !== e.fight_marker_id || h.author_id === uid) return { status: 403, code: '42501' };
    }
    return null;
  }
  async function handle(uid, route) {
    const req = route.request(), u = new URL(req.url()), table = u.pathname.replace('/rest/v1/', '');
    if (offline.has(uid)) return route.abort();
    const ok = (status, body) => route.fulfill({ status, contentType: 'application/json', body: body === undefined ? '' : JSON.stringify(body) });
    if (req.method() === 'GET') {
      if (table === 'couples') return ok(200, [COUPLE]);
      if (table === 'members') return ok(200, srv.members || MEMBERS);
      if (!t[table]) return ok(200, []);
      let rows = Object.values(t[table]);
      const idq = u.searchParams.get('id'); if (idq && idq.startsWith('eq.')) rows = rows.filter((x) => x.id === idq.slice(3));
      return ok(200, table === 'talkthrough_events' ? rows.filter((e) => visible(uid, e)) : rows);
    }
    if (req.method() === 'POST') {
      const row = JSON.parse(req.postData());
      posts.push({ uid, table, row });
      const bad = refuse(uid, table, row);
      if (bad) { refused.push({ uid, table, row, ...bad }); return route.fulfill({ status: bad.status, contentType: 'application/json', body: JSON.stringify({ code: bad.code, message: 'refused' }) }); }
      if (!t[table]) t[table] = {};
      t[table][row.id] = { updated_at: new Date().toISOString(), ...row };
      return ok(201);
    }
    if (req.method() === 'PATCH') {
      const id = decodeURIComponent(u.search.match(/id=eq\.([^&]+)/)[1]);
      patches.push({ uid, table, id, patch: JSON.parse(req.postData()) });
      Object.assign(t[table][id], JSON.parse(req.postData()), { updated_at: new Date().toISOString() });
      return ok(200, [t[table][id]]);
    }
    return ok(204);
  }
  const srv = { t, posts, patches, refused, offline, handle, members: null };
  return srv;
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
      // The native shell bridge, so the real mic renders on every micTa field (it only shows when the shell is there).
      window.webkit = { messageHandlers: { cycle: { postMessage: ({ id, cmd, args }) => setTimeout(() => {
        let r = null;
        if (cmd === 'store.get') r = localStorage.getItem('cycle:' + args.key);
        else if (cmd === 'store.set') localStorage.setItem('cycle:' + args.key, args.value);
        else if (cmd === 'store.keys') r = Object.keys(localStorage).filter((k) => k.startsWith('cycle:' + args.prefix)).map((k) => k.slice(6));
        else if (cmd === 'notify.status') r = 'granted';
        else if (cmd === 'lock.get') r = false;
        else if (cmd === 'app.info') r = { shell: 4, native: 0 };
        else if (cmd === 'speech.orphans') r = [];
        window.__cycleReply(id, r, null);
      }, 0) } } };
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
  async function pair(tables, members) {
    const srv = makeServer({ fight_markers: { fp: marker() }, ...tables });
    if (members) srv.members = members;
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
    // On the partner's turn the fight page still opens the talk (it had no button at all, so the waiting screen was unreachable).
    await o.page.evaluate(() => cycleNative.route('fight/fp')); await o.page.waitForSelector('.tt-card');
    assert.equal(await text(o.page, '.tt-card [data-a="ttgo:fp"]'), 'Open');
    await o.page.click('[data-a="ttgo:fp"]'); await o.page.waitForSelector('.ttk');
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
    await e.page.click('[data-a="ttnq:open"]');
    await e.page.fill('textarea[data-d="tv_note"]', 'More about the trip cost.');
    await e.page.click('[data-a="ttnqsend"]');
    await o.page.click('[data-a="ttverdict:got_it"]');
    await sync(e.page); await sync(o.page);
    // Oliver gets the step back: her note, his old words prefilled, revise, send.
    assert.match(await text(o.page, '.ttk'), /Esme says you missed[\s\S]*More about the trip cost\./);
    assert.equal(await o.page.inputValue('textarea[data-d="th_heard"]'), '', 'revise starts with an empty heard box');
    assert.equal(await o.page.inputValue('textarea[data-d="th_sense"]'), '', 'and an empty makes-sense box');
    assert.match(await text(o.page, '.tt-prev'), /You wrote\s*You felt rejected\.\s*What makes sense\s*Makes sense you felt unwanted\./, 'my previous attempt is shown read-only');
    assert.equal(await o.page.locator('.tt-prev textarea').count(), 0);
    await shot(o.page, 'revise-blank-boxes');
    await shot(o.page, 'step2-not-quite-revise');
    await o.page.fill('textarea[data-d="th_heard"]', 'You felt rejected and the $355 mattered.');
    await o.page.click('[data-a="ttheard"]');
    await sync(o.page); await sync(e.page);
    assert.equal(Object.values(srv.t.talkthrough_events).filter((x) => x.kind === 'heard' && x.author_id === ME).pop().body, 'You felt rejected and the $355 mattered.', 'the revision is a new heard row with the new text');
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
    const tp = srv.posts.filter((p) => p.table === 'talkthrough_events');
    assert.equal(tp.length, 3, 'each queued write was sent exactly once (a double replay would show 6): ' + tp.map((p) => p.row.kind));
    assert.deepEqual(srv.refused, [], 'and nothing was refused');
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
    const lead = ['From the Gottman Method.', 'Two sides first.', 'Hear before you answer.', 'Own your part.', 'One thing for next time.'];
    let at = 0; for (const l of lead) { const i = t.indexOf(l, at); assert.ok(i >= 0, 'Why lead-in in order: ' + l); at = i; }
    assert.match(t, /\u201cAftermath of a Fight\u201d exercise that Gottman couples therapists use to work through a fight once you're both calm\./);
    assert.match(t, /It ends with a concrete request, so the same fight goes differently\.$/);
    assert.doesNotMatch(t, /Not proven|Shenk|Fruzzetti|Gordon|Finkel|Hawkins|Gottman et al|\b(19|20)\d\d\b|study|studies/i, 'no citations');
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

  // Every talk textarea has its durable mic, and the primary action sits fully inside the viewport, above the tab bar.
  const micsOk = (page) => page.evaluate(() => { const t = [...document.querySelectorAll('.ttk textarea[data-d]')]; return t.length > 0 && t.every((x) => x.parentElement.querySelector('.mic[data-a="mic:' + x.dataset.d + '"]')); });
  const pinned = (page, sel) => page.evaluate((sel) => { const b = document.querySelector(sel).getBoundingClientRect(), tb = document.querySelector('.tabbar'), t = tb ? tb.getBoundingClientRect().top : 844; return { top: b.top, bottom: b.bottom, tab: t, vh: innerHeight }; }, sel);
  test('every talk field has the voice mic; Draft saved shows after typing; the primary button is pinned above the tab bar on step 4', async () => {
    const { o, e, close } = await pair();
    await o.page.click('[data-a="ttstart:fp"]');
    assert.equal(await micsOk(o.page), true, 'step 1 fields');
    await o.page.fill('textarea[data-d="ts_what"]', 'x');
    assert.equal(await o.page.locator('[data-ttds="ts_what"]').isVisible(), true);
    await side(o, 'I felt attacked.', 'Money talks when rested.'); await sync(o.page);
    await sync(e.page); await e.page.reload(); await sync(e.page); await e.page.evaluate(() => cycleNative.route('fight/fp')); await e.page.click('[data-a="ttgo:fp"]');
    await side(e, 'I felt left out.', 'The trip.'); await sync(e.page); await sync(o.page);
    assert.equal(await micsOk(o.page), true, 'step 2 fields');
    await doHeard(o, 'You felt left out.', 'The trip is a lot.'); await doHeard(e, 'You felt attacked.', 'Late.');
    await sync(o.page); await sync(e.page); await sync(o.page);
    await e.page.click('[data-a="ttnq:open"]'); // the verdict note box only exists once Not quite is tapped
    assert.equal(await micsOk(e.page), true, 'verdict note field');
    await e.page.click('[data-a="ttnq:cancel"]');
    await e.page.click('[data-a="ttverdict:got_it"]'); await o.page.click('[data-a="ttverdict:got_it"]'); await sync(e.page); await sync(o.page);
    assert.equal(await micsOk(o.page), true, 'step 3 fields');
    await o.page.fill('textarea[data-d="to_part"]', 'I shut down.'); await o.page.click('[data-a="ttown"]'); await sync(o.page); await sync(e.page);
    await e.page.fill('textarea[data-d="to_part"]', 'I texted at 1am.'); await e.page.click('[data-a="ttown"]'); await sync(e.page); await sync(o.page);
    assert.equal(await micsOk(o.page), true, 'step 4 fields');
    await o.page.waitForSelector('.tt-foot');
    for (const y of [0, 9999]) {
      await o.page.evaluate((y) => { const m = document.querySelector('.scr main'); m.scrollTop = y; }, y);
      const b = await pinned(o.page, '[data-a="ttreqs"]');
      assert.ok(b.top >= 0 && b.bottom <= b.tab + 0.5 && b.bottom <= b.vh, 'Submit inside viewport above tab bar at scroll ' + y + ': ' + JSON.stringify(b));
    }
    await close();
  });

  // ---- pixel defects found in review at 390x844: whole-line clamp, caption gap, pinned primary button, fixed-height explainer, no-scroll step 1 ----
  const LONG = 'The dishes sat there again and I got louder than I wanted to be, and then it went on for a long while after that. '.repeat(4).trim();
  const footTop = (page) => page.$eval('.tt-foot .save', (e) => e.getBoundingClientRect().top);

  async function clampedStep1() {
    const r = await pair({ fight_notes: { n1: note('n1', ME, LONG) } });
    await sync(r.o.page); await r.o.page.click('[data-a="ttstart:fp"]');
    return r;
  }
  test('layout: the clamped note box shows a whole number of lines (no glyph row cut in half)', async () => {
    const { o, close } = await clampedStep1();
    await shot(o.page, 'step1-prefilled-clamped');
    const c = await o.page.$eval('.tt-clamp textarea', (t) => { const cs = getComputedStyle(t), lh = parseFloat(cs.lineHeight);
      return { inner: t.clientHeight - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom), lh, overflowing: t.scrollHeight > t.clientHeight }; });
    assert.ok(c.overflowing, 'the note really is clamped');
    assert.ok(Math.abs(c.inner / c.lh - Math.round(c.inner / c.lh)) * c.lh <= 1, 'clamped inner height is a whole number of lines: ' + JSON.stringify(c));
    await close();
  });
  test('layout: the "From your note" caption sits at least 8px above its box', async () => {
    const { o, close } = await clampedStep1();
    const g = await o.page.evaluate(() => document.querySelector('.tt-clamp').getBoundingClientRect().top - document.querySelector('.tt-src').getBoundingClientRect().bottom);
    assert.ok(g >= 8, 'caption-to-box gap ' + g);
    await close();
  });
  test('layout: step 1 with a prefilled clamped note fits the phone without scrolling', async () => {
    const { o, close } = await clampedStep1();
    const sc = await o.page.$eval('.scr', (m) => ({ sh: m.scrollHeight, ch: m.clientHeight }));
    const m = await o.page.evaluate(() => ({ lastBottom: [...document.querySelectorAll('.ttk .ta')].pop().getBoundingClientRect().bottom, footTop: document.querySelector('.tt-foot').getBoundingClientRect().top, btn: document.querySelector('.tt-foot .save').getBoundingClientRect().top }));
    assert.ok(sc.sh <= sc.ch + 1, 'step 1 does not scroll: ' + JSON.stringify(sc));
    assert.ok(m.lastBottom <= m.footTop + 1, 'the last field ends above the footer fade: ' + JSON.stringify(m));
    await close();
  });

  test('layout: the primary button sits at the same y on a short step as on step 1', async () => {
    const { srv, o, e, ph, close } = await pair({ fight_notes: { n1: note('n1', ME, LONG) } });
    await sync(o.page); await o.page.click('[data-a="ttstart:fp"]');
    const y1 = await footTop(o.page);
    await o.page.click('[data-a="ttside"]'); await sync(o.page);
    await sync(e.page); await e.page.reload(); await sync(e.page); await e.page.evaluate(() => cycleNative.route('fight/fp')); await e.page.click('[data-a="ttgo:fp"]');
    await side(e, 'I felt left out.', 'The trip is $355.'); await sync(e.page); await sync(o.page);
    await doHeard(o, 'You felt left out.', 'It is a lot.'); await doHeard(e, 'You felt loud.', 'Late.');
    await sync(o.page); await sync(e.page); await sync(o.page);
    await e.page.click('[data-a="ttverdict:got_it"]'); await o.page.click('[data-a="ttverdict:got_it"]'); await sync(e.page); await sync(o.page);
    assert.match(await text(o.page, '.tt-prog'), /3 Own up/);
    await shot(o.page, 'step3-own-up-short');
    const y3 = await footTop(o.page);
    assert.ok(Math.abs(y1 - y3) <= 2, 'step 1 button y ' + y1 + ' vs step 3 ' + y3);
    await close();
  });

  test('layout: the explainer keeps its height, so the How/Why control does not move', async () => {
    const { o, close } = await pair();
    await o.page.click('.tt-card .tt-q');
    const top = () => o.page.$eval('.tt-info .seg', (s) => s.getBoundingClientRect().top);
    const how = await top(); await shot(o.page, 'explainer-how-fixed');
    await o.page.click('.tt-info [data-a="ttinfo:why"]'); const why = await top(); await shot(o.page, 'explainer-why-fixed');
    await o.page.click('.tt-info [data-a="ttinfo:how"]'); const back = await top();
    assert.ok(Math.abs(how - why) <= 1 && Math.abs(how - back) <= 1, 'segmented control top: how ' + how + ', why ' + why + ', how again ' + back);
    await close();
  });

  // ---- follow-up: fight texts as context, grow-on-tap text boxes, the About ? sheet ----
  const SPAN = { text_on: true, texts_at: ago(4), texts_wider: 0, texts_grabbed_wider: 0, texts: [{ ts: ago(5), by: HER, body: 'you never listen' }, { ts: ago(4.9), by: ME, body: 'that is not fair' }] };
  const bubbles = (page) => page.$$eval('.ttk .txm p', (e) => e.map((p) => p.textContent));
  test('step 1 and step 2 show the fight\'s texts read-only: collapsed with a Texts count, expanding in place, same as the fight page, nothing sent', async () => {
    const { srv, o, e, ph, close } = await pair({ fight_markers: { fp: marker(SPAN) } });
    const fightPage = await o.page.$$eval('.txm p', (x) => x.length); // collapsed on the fight page too
    assert.equal(fightPage, 0);
    await o.page.click('[data-a="txtoggle"]'); const onFight = await o.page.$$eval('.txm p', (x) => x.map((p) => p.textContent));
    await o.page.click('[data-a="ttstart:fp"]');
    assert.match(await text(o.page, '.tt-tx'), /^Texts · 2$/);
    assert.equal((await bubbles(o.page)).length, 0, 'collapsed by default');
    await shot(o.page, 'step1-texts-collapsed');
    const posts0 = srv.posts.length, patches0 = srv.patches.length;
    await o.page.click('[data-a="tttx"]');
    assert.deepEqual(await bubbles(o.page), onFight, 'the same messages the fight page shows');
    assert.deepEqual(onFight, ['you never listen', 'that is not fair']);
    assert.equal(await o.page.locator('.ttk textarea').count(), 2, 'step 1 fields still there');
    await shot(o.page, 'step1-texts-expanded');
    await o.page.click('[data-a="tttx"]'); assert.equal((await bubbles(o.page)).length, 0, 'tap again collapses');
    assert.equal(srv.posts.length, posts0); assert.equal(srv.patches.length, patches0, 'reading texts writes nothing');
    // The partner sees the same block (the span is on the shared marker, which both phones read), and step 2 has it too.
    await sync(e.page); await e.page.reload(); await sync(e.page); await e.page.evaluate(() => cycleNative.route('fight/fp'));
    await e.page.waitForSelector('.fd'); await e.page.click('[data-a="ttstart:fp"]');
    assert.match(await text(e.page, '.tt-tx'), /^Texts · 2$/);
    await e.page.fill('textarea[data-d="ts_what"]', 'I felt left out.'); await e.page.click('[data-a="ttside"]');
    await sync(o.page); await o.page.fill('textarea[data-d="ts_what"]', 'I felt attacked.'); await o.page.click('[data-a="ttside"]'); await sync(o.page); await sync(e.page);
    assert.match(await text(o.page, '.ttk'), /What I heard/);
    assert.match(await text(o.page, '.tt-tx'), /^Texts · 2$/, 'step 2 shows the block');
    await o.page.click('[data-a="tttx"]'); assert.deepEqual(await bubbles(o.page), onFight);
    await close();
  });
  test('no texts attached (none found, still finding, or not asked): Talk it through renders no Texts block', async () => {
    for (const mk of [marker(), marker({ text_on: true, texts: null }), marker({ ...SPAN, texts: [] })]) {
      const { o, close } = await pair({ fight_markers: { fp: mk } });
      await o.page.click('[data-a="ttstart:fp"]');
      assert.equal(await o.page.locator('.tt-tx').count(), 0, JSON.stringify(mk.texts));
      await close();
    }
  });

  // Fields grow on tap. grown() reports whether the box shows everything: no inner scroll and no clipped line.
  const fits = (page, sel) => page.$eval(sel, (t) => ({ sh: t.scrollHeight, ch: t.clientHeight, lh: parseFloat(getComputedStyle(t).lineHeight) }));
  test('a clamped prefilled talk box is whole lines until tapped, then grows to show everything, and Show all is gone', async () => {
    const { o, close } = await clampedStep1();
    const sel = '.tt-clamp textarea';
    const before = await fits(o.page, sel);
    assert.ok(before.sh > before.ch + 1, 'clamped before the tap: ' + JSON.stringify(before));
    assert.ok(Math.abs(before.ch / before.lh - Math.round(before.ch / before.lh)) * before.lh <= 1, 'whole lines before the tap');
    assert.equal(await o.page.locator('[data-a="ttall:ts_what"]').count(), 0, 'no Show all link on the box');
    await shot(o.page, 'step1-clamped-before-tap');
    await o.page.focus(sel);
    const after = await fits(o.page, sel);
    assert.ok(after.sh <= after.ch + 1, 'whole text shown after the tap: ' + JSON.stringify(after));
    assert.ok(after.ch > before.ch, 'grew');
    await shot(o.page, 'step1-clamped-after-tap');
    await close();
  });
  test('a tapped box grows as you type (min 5 lines) and the caret line stays above the pinned footer', async () => {
    const { o, close } = await clampedStep1();
    const sel = 'textarea[data-d="ts_about"]'; // the empty box: 3 lines at rest
    const rest = await fits(o.page, sel);
    await o.page.focus(sel);
    const f = await fits(o.page, sel);
    assert.ok(f.ch >= 5 * f.lh - 1, 'at least 5 lines once tapped: ' + JSON.stringify({ rest, f }));
    await o.page.fill(sel, 'long thought '.repeat(120));
    const g = await fits(o.page, sel);
    assert.ok(g.sh <= g.ch + 1 && g.ch > f.ch, 'keeps growing with the text: ' + JSON.stringify(g));
    const m = await o.page.evaluate((s) => ({ boxBottom: document.querySelector(s).getBoundingClientRect().bottom, footTop: document.querySelector('.tt-foot').getBoundingClientRect().top, scrTop: document.querySelector('.scr').getBoundingClientRect().top }), sel);
    assert.ok(m.boxBottom <= m.footTop + 1 && m.boxBottom > m.scrTop, 'caret line (end of text) is in view above the footer: ' + JSON.stringify(m));
    await close();
  });
  test('a non-talk box (the fight page note field) grows to its content on tap too', async () => {
    const { o, close } = await pair();
    const sel = 'textarea[data-d="more"]';
    // Set programmatically, like a restored draft or dictation: no input event, so only the tap can grow it.
    await o.page.$eval(sel, (t) => { t.value = 'a line of what happened\n'.repeat(14).trim(); });
    const before = await fits(o.page, sel);
    assert.ok(before.sh > before.ch + 1, 'overflowing before the tap: ' + JSON.stringify(before));
    await o.page.focus(sel);
    const after = await fits(o.page, sel);
    assert.ok(after.sh <= after.ch + 1, 'whole text shown after the tap: ' + JSON.stringify(after));
    await shot(o.page, 'fight-note-expanded');
    await close();
  });
  test('the ? next to "What it\'s about for me" opens a small sheet with that title and exactly the given text; "Draft saved" stays at the right end', async () => {
    const { o, close } = await clampedStep1();
    const q = o.page.locator('.ttk .lab .tt-q').first();
    const bb = await q.boundingBox(); assert.ok(bb.width >= 44 && bb.height >= 44, 'hit box ' + JSON.stringify(bb));
    const ring = await o.page.$eval('.ttk .lab .tt-q i', (i) => i.getBoundingClientRect().width);
    assert.equal(ring, await o.page.$eval('.tt-prog .tt-q i', (i) => i.getBoundingClientRect().width), 'same circle as the stepper ?');
    await o.page.fill('textarea[data-d="ts_about"]', 'x'); // "Draft saved" only shows once something is typed
    const pos = await o.page.evaluate(() => { const l = [...document.querySelectorAll('.ttk .lab')].find((x) => x.querySelector('.tt-q')), lab = l.querySelector('.tt-lh'), ds = l.querySelector('.tt-ds'), r = (e) => e.getBoundingClientRect();
      return { qLeft: r(l.querySelector('.tt-q i')).left, labText: r(lab).left, dsRight: r(ds).right, rowRight: r(l).right, txt: lab.textContent }; });
    assert.equal(pos.txt, 'What it\u2019s about for me?'); // the ? glyph is part of the label's textContent
    assert.ok(pos.qLeft - pos.labText < 230, 'the ? follows the label text: ' + JSON.stringify(pos));
    assert.ok(Math.abs(pos.rowRight - pos.dsRight) <= 1, '"Draft saved" slot at the right end: ' + JSON.stringify(pos));
    assert.equal(await o.page.locator('.ttk .lab .tt-q').count(), 1, 'only on that label');
    await q.click();
    assert.equal(await text(o.page, '.tt-help h3'), 'What it\u2019s about for me');
    assert.equal(await o.page.$eval('.tt-help .tt-hb', (p) => p.textContent), 'The deeper reason this fight mattered to you. Name the feeling, the need, or the old sore spot underneath, apart from what actually happened.');
    await shot(o.page, 'about-help-sheet');
    await o.page.click('.tt-help .xb'); assert.equal(await o.page.locator('.tt-help').count(), 0);
    await close();
  });

  // ---- follow-up: a submit shows the partner's rows at once, and a waiting screen advances on its own (no navigation, no manual sync) ----
  // Waits for the app's own sync tick / write-triggered sync; NEVER calls syncNow or navigates, which is what the earlier tests did.
  const until = (page, fn, arg, ms = 9000) => page.waitForFunction(fn, arg, { timeout: ms });
  const onStep = (n) => (k) => new RegExp('^' + n + ' ').test(document.querySelector('.tt-prog .tt-cur')?.textContent.replace(/\s+/g, ' ').trim() || '');
  async function esmeSubmitsFirst() {
    const r = await pair();
    await r.e.page.click('[data-a="ttstart:fp"]'); await side(r.e, 'I felt left out.', 'The trip is $355.'); await sync(r.e.page);
    await r.o.page.click('[data-a="ttstart:fp"]');
    return r;
  }
  test('Oliver submits after Esme: his screen moves to step 2 and shows her side with no navigation or manual sync', async () => {
    const { o, close } = await esmeSubmitsFirst();
    await side(o, 'I felt attacked.', 'Money talks when rested.');
    await until(o.page, () => /Esme's side/.test(document.querySelector('.ttk')?.textContent || '') && /2 Heard/.test(document.querySelector('.tt-prog')?.textContent.replace(/\s+/g, ' ')));
    assert.match(await text(o.page, '.ttk'), /I felt left out\.[\s\S]*The trip is \$355\./);
    await shot(o.page, 'step2-straight-after-submit');
    await close();
  });
  test('a phone on "Waiting on partner" advances by itself when the partner submits (step 1 to 2)', async () => {
    const { o, e, close } = await esmeSubmitsFirst();
    await side(o, 'I felt attacked.', 'Money talks when rested.');
    await until(o.page, () => /Esme's side/.test(document.querySelector('.ttk')?.textContent || ''));
    await doHeard(o, 'You felt left out.', 'It is a lot.');
    assert.match(await text(o.page, '.ttk'), /Waiting on Esme/);
    await sync(o.page);
    // Esme's phone is on the screen since her own submit: she now submits step 2 and Oliver (waiting) must see her answer arrive.
    await until(e.page, () => /Oliver's side/.test(document.querySelector('.ttk')?.textContent || ''));
    await doHeard(e, 'You felt loud.', 'Late.');
    await until(o.page, () => /Esme heard/.test(document.querySelector('.ttk')?.textContent || ''));
    await close();
  });
  test('step 3: after both submit their own-up, each sees the other\'s at once with no navigation', async () => {
    const { srv, o, e, close } = await esmeSubmitsFirst();
    await side(o, 'I felt attacked.', 'Money talks when rested.');
    await until(o.page, () => /Esme's side/.test(document.querySelector('.ttk')?.textContent || ''));
    await until(e.page, () => /Oliver's side/.test(document.querySelector('.ttk')?.textContent || ''));
    await doHeard(o, 'You felt left out.', 'It is a lot.'); await doHeard(e, 'You felt loud.', 'Late.');
    for (const p of [o, e]) await until(p.page, () => !!document.querySelector('[data-a="ttverdict:got_it"]'));
    await o.page.click('[data-a="ttverdict:got_it"]'); await e.page.click('[data-a="ttverdict:got_it"]');
    await until(o.page, () => /3 Own up/.test(document.querySelector('.tt-prog')?.textContent.replace(/\s+/g, ' ')));
    await until(e.page, () => /3 Own up/.test(document.querySelector('.tt-prog')?.textContent.replace(/\s+/g, ' ')));
    await e.page.fill('textarea[data-d="to_part"]', 'I snapped.'); await e.page.click('[data-a="ttown"]');
    await o.page.fill('textarea[data-d="to_part"]', 'I went quiet.'); await o.page.click('[data-a="ttown"]');
    await until(o.page, () => /Esme's part[\s\S]*I snapped\./.test(document.querySelector('.ttk')?.textContent || ''));
    await until(e.page, () => /Oliver's part[\s\S]*I went quiet\./.test(document.querySelector('.ttk')?.textContent || ''));
    await close();
  });
  test('text being typed survives a sync that delivers the partner\'s rows (value, focus and caret kept)', async () => {
    const { srv, o, e, close } = await pair();
    await o.page.click('[data-a="ttstart:fp"]'); await e.page.click('[data-a="ttstart:fp"]');
    await o.page.focus('textarea[data-d="ts_what"]'); await o.page.keyboard.type('half a thought');
    await o.page.keyboard.press('ArrowLeft'); await o.page.keyboard.press('ArrowLeft');
    await side(e, 'I felt left out.', 'The trip is $355.'); await sync(e.page);
    await sync(o.page); await o.page.waitForTimeout(300); // Esme's rows arrive on Oliver's phone while he is typing
    const st = await o.page.evaluate(() => { const t = document.querySelector('textarea[data-d="ts_what"]'); return { v: t.value, focus: document.activeElement === t, caret: t.selectionStart }; });
    assert.deepEqual(st, { v: 'half a thought', focus: true, caret: 12 });
    await close();
  });

  // ---- follow-up: Not quite collects a clarification before anything is sent ----
  const verdictRows = (srv) => Object.values(srv.t.talkthrough_events).filter((x) => x.kind === 'verdict');
  // Both on step 2 with Oliver's heard in; Esme (author of the side he reflected on) holds the verdict controls.
  async function atVerdict(tables, members) {
    const r = await pair(tables, members);
    await r.o.page.click('[data-a="ttstart:fp"]'); await r.e.page.click('[data-a="ttstart:fp"]');
    await side(r.o, 'I felt attacked.', 'Money talks.'); await side(r.e, 'I felt left out.', 'The trip.');
    await until(r.o.page, () => /Esme's side/.test(document.querySelector('.ttk')?.textContent || ''));
    await doHeard(r.o, 'You felt left out.', 'Fair.');
    await until(r.e.page, () => !!document.querySelector('[data-a="ttverdict:got_it"]'));
    return r;
  }
  test('Not quite: starts as two buttons, tapping Not quite writes nothing and opens "What Oliver missed" with Send disabled until there is text; Cancel restores the buttons', async () => {
    const { srv, e, close } = await atVerdict();
    assert.equal(await e.page.locator('textarea[data-d="tv_note"]').count(), 0, 'no note field up front');
    assert.equal(await e.page.locator('[data-a="ttverdict:got_it"], [data-a="ttnq:open"]').count(), 2);
    await shot(e.page, 'verdict-before-not-quite');
    // Owing both a heard and a verdict: my heard Send must be tappable, not covered by the pinned Got it / Not quite bar
    // (both were sticky footers and stacked, hiding Send).
    const hit = await e.page.evaluate(() => { const b = document.querySelector('[data-a="ttheard"]'); b.scrollIntoView({ block: 'center' }); const r = b.getBoundingClientRect(); return document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) === b; });
    assert.ok(hit, 'heard Send is not covered');
    for (const y of [0, 9999]) { // and never covered at either scroll extreme where it is in view
      const cov = await e.page.evaluate((y) => { const sc = document.scrollingElement; sc.scrollTop = y; document.querySelectorAll('*').forEach((n) => { if (n.scrollHeight > n.clientHeight + 40 && getComputedStyle(n).overflowY !== 'visible') n.scrollTop = y; }); const b = document.querySelector('[data-a="ttheard"]'), r = b.getBoundingClientRect(), bar = document.querySelector('[data-a="ttverdict:got_it"]').getBoundingClientRect(); return r.bottom > bar.top && r.top < bar.bottom; }, y);
      assert.ok(!cov, 'heard Send overlaps the verdict bar at scroll ' + y);
    }
    const n0 = srv.posts.length;
    await e.page.click('[data-a="ttnq:open"]');
    assert.equal(verdictRows(srv).length, 0); assert.equal(srv.posts.length, n0, 'tapping Not quite sends nothing');
    assert.match(await text(e.page, '.ttk'), /What Oliver missed/);
    assert.ok(await e.page.locator('[data-a="ttnqsend"].dis').count(), 'Send disabled when blank');
    await e.page.fill('textarea[data-d="tv_note"]', '   '); assert.ok(await e.page.locator('[data-a="ttnqsend"].dis').count(), 'blank text keeps Send disabled');
    await e.page.fill('textarea[data-d="tv_note"]', 'You skipped the money part.');
    assert.equal(await e.page.locator('[data-a="ttnqsend"].dis').count(), 0, 'text enables Send');
    await shot(e.page, 'verdict-after-not-quite');
    await e.page.click('[data-a="ttnq:cancel"]');
    assert.equal(verdictRows(srv).length, 0, 'Cancel writes nothing');
    assert.equal(await e.page.locator('[data-a="ttverdict:got_it"]').count(), 1); assert.equal(await e.page.locator('[data-a="ttnq:open"]').count(), 1);
    await close();
  });
  test('Not quite + text + Send writes one not_quite verdict with that body; the partner\'s revise screen shows it above the field; Got it is unchanged', async () => {
    const { srv, o, e, close } = await atVerdict();
    await e.page.click('[data-a="ttnq:open"]'); await e.page.fill('textarea[data-d="tv_note"]', 'You skipped the money part.'); await e.page.click('[data-a="ttnqsend"]');
    await until(e.page, () => !document.querySelector('[data-a="ttnqsend"]'));
    const v = verdictRows(srv); assert.equal(v.length, 1);
    assert.deepEqual([v[0].verdict, v[0].body, v[0].author_id], ['not_quite', 'You skipped the money part.', HER]);
    await until(o.page, () => /Esme says you missed/.test(document.querySelector('.ttk')?.textContent || ''));
    assert.match(await text(o.page, '.ttk'), /Esme says you missed\s*You skipped the money part\.[\s\S]*What I heard/);
    await shot(o.page, 'verdict-partner-revise');
    await close();
    const b = await atVerdict();
    await b.e.page.click('[data-a="ttverdict:got_it"]');
    await sync(b.e.page);
    const g = verdictRows(b.srv); assert.deepEqual([g.length, g[0].verdict, g[0].body], [1, 'got_it', null]);
    await b.close();
  });
  test('an empty Not quite that was already sent can still be clarified from the waiting screen: a newer verdict row, and the partner sees it', async () => {
    const { srv, o, e, close } = await atVerdict();
    // The old behaviour, written straight into the shared state: an empty not_quite on Oliver's heard row.
    await doHeard(e, 'You felt loud.', 'Late.'); // Esme has written hers, so on Oliver's heard she only waits (the waiting screen is where the box goes)
    const heard = Object.values(srv.t.talkthrough_events).find((x) => x.kind === 'heard' && x.author_id === ME);
    await e.page.evaluate((h) => { const ev = { id: crypto.randomUUID(), couple_id: 'c1', fight_marker_id: 'fp', author_id: 'u-her', kind: 'verdict', ref_id: h.id, verdict: 'not_quite', body: null, created_at: new Date().toISOString() }; CycleStore.insert('talkthrough_events', ev); }, heard);
    await until(e.page, () => /Waiting on Oliver/.test(document.querySelector('.ttk')?.textContent || '') && !!document.querySelector('[data-a="ttnqsend"]'));
    assert.match(await text(e.page, '.ttk'), /What Oliver missed/);
    await e.page.fill('textarea[data-d="tv_note"]', 'The money part.'); await e.page.click('[data-a="ttnqsend"]');
    await until(o.page, () => /Esme says you missed[\s\S]*The money part\./.test(document.querySelector('.ttk')?.textContent || ''));
    assert.equal(verdictRows(srv).length, 2, 'a second row, the first untouched'); 
    await close();
  });
  test('typing in a talk box while the partner\'s answer arrives: the screen updates and the typed text, focus and caret stay', async () => {
    const { o, e, close } = await pair();
    await o.page.click('[data-a="ttstart:fp"]'); await e.page.click('[data-a="ttstart:fp"]');
    await side(o, 'I felt attacked.', 'Money talks.'); await side(e, 'I felt left out.', 'The trip.');
    await until(o.page, () => /Esme's side/.test(document.querySelector('.ttk')?.textContent || ''));
    await until(e.page, () => /Oliver's side/.test(document.querySelector('.ttk')?.textContent || ''));
    await o.page.focus('textarea[data-d="th_heard"]'); await o.page.keyboard.type('You felt le'); await o.page.keyboard.press('ArrowLeft');
    await doHeard(e, 'You felt loud.', 'Late.');
    await until(o.page, () => !!document.querySelector('[data-a="ttnq:open"]'));
    const st = await o.page.evaluate(() => { const t = document.querySelector('textarea[data-d="th_heard"]'); return { v: t.value, focus: document.activeElement === t, caret: t.selectionStart }; });
    assert.deepEqual(st, { v: 'You felt le', focus: true, caret: 10 });
    await close();
  });

  test('step 2 (writing) has a "Why can\'t I argue?" link under the last field: opens a sheet, closing keeps the typed draft; no such link on steps 1, 3, 4', async () => {
    const { o, e, close } = await pair();
    await o.page.click('[data-a="ttstart:fp"]');
    assert.equal(await o.page.locator('.tt-wl').count(), 0, 'not on step 1');
    await side(o, 'I felt attacked.', 'Money talks.'); await e.page.click('[data-a="ttstart:fp"]'); await side(e, 'I felt left out.', 'The trip.');
    await until(o.page, () => /2 Heard/.test(document.querySelector('.tt-prog')?.textContent.replace(/\s+/g, ' ')));
    const link = o.page.locator('.tt-wl');
    assert.equal((await link.textContent()).replace('?', '', ), 'Why can\u2019t I argue?', 'label after the circled ?');
    assert.ok((await link.boundingBox()).height >= 44, '44px hit height');
    await o.page.evaluate(() => { document.querySelector('.scr').scrollTop = 9999; }); // the footer is pinned, so measure with the content scrolled to its end
    const pos = await o.page.evaluate(() => ({ last: [...document.querySelectorAll('.ttk .ta')].pop().getBoundingClientRect().bottom, link: document.querySelector('.tt-wl').getBoundingClientRect().top, foot: document.querySelector('.tt-foot').getBoundingClientRect().top }));
    assert.ok(pos.link >= pos.last - 1 && pos.link + 44 <= pos.foot + 1, 'directly under the last field, above the footer: ' + JSON.stringify(pos));
    await shot(o.page, 'step2-why-cant-i-argue-link');
    await o.page.fill('textarea[data-d="th_heard"]', 'You felt left out.');
    await link.click();
    assert.equal(await text(o.page, '.tt-help h3'), 'Why can\u2019t I argue?');
    assert.deepEqual(await o.page.locator('.tt-help .tt-hb').allTextContents(), [
      'This step is only for showing you heard them. Your disagreement already has a place: your own side in step 1 and your requests in step 4.',
      '\u201cWhat makes sense\u201d isn\u2019t agreeing. It means you can see why it felt that way to them, even if you think they\u2019re wrong.',
      'If they got your side wrong, tap Not quite and say what they missed.']);
    await shot(o.page, 'why-cant-i-argue-sheet');
    await o.page.click('.tt-help .xb');
    assert.equal(await o.page.locator('.tt-help').count(), 0);
    assert.equal(await o.page.inputValue('textarea[data-d="th_heard"]'), 'You felt left out.', 'draft intact');
    await doHeard(o, 'You felt left out.', 'Fair.'); await doHeard(e, 'You felt loud.', 'Late.');
    for (const p of [o, e]) await until(p.page, () => !!document.querySelector('[data-a="ttverdict:got_it"]'));
    await o.page.click('[data-a="ttverdict:got_it"]'); await e.page.click('[data-a="ttverdict:got_it"]');
    for (const p of [o, e]) await until(p.page, () => /3 Own up/.test(document.querySelector('.tt-prog')?.textContent.replace(/\s+/g, ' ')));
    assert.equal(await o.page.locator('.tt-wl').count(), 0, 'not on step 3');
    await o.page.fill('textarea[data-d="to_part"]', 'x'); await o.page.click('[data-a="ttown"]'); await e.page.fill('textarea[data-d="to_part"]', 'y'); await e.page.click('[data-a="ttown"]');
    for (const p of [o, e]) await until(p.page, () => /4 Requests/.test(document.querySelector('.tt-prog')?.textContent.replace(/\s+/g, ' ')));
    assert.equal(await o.page.locator('.tt-wl').count(), 0, 'not on step 4');
    await close();
  });

  // ---- audit follow-ups: materialize is safe across devices and replays; the partner's own-up shows; a verdict note survives Send ----
  const N1 = () => note('n1', ME, 'old note text');
  const mineOnFight = (srv) => Object.values(srv.t.fight_notes).filter((n) => n.author_id === ME && n.fight_marker_id === 'fp');
  async function sidesWithEdit(srv, ph, between) {
    const o = ph.o, e = ph.e;
    await sync(o.page); await o.page.evaluate(() => cycleNative.route('fight/fp')); await o.page.waitForSelector('.tt-card');
    await o.page.click('[data-a="ttstart:fp"]');
    await o.page.fill('textarea[data-d="ts_what"]', 'edited in the talk'); await o.page.fill('textarea[data-d="ts_about"]', 'what it is about');
    await o.page.click('[data-a="ttside"]'); await sync(o.page);
    if (between) await between();
    await sync(e.page); await e.page.reload(); await sync(e.page); await e.page.evaluate(() => cycleNative.route('fight/fp')); await e.page.click('[data-a="ttgo:fp"]');
    await side(e, 'her what', 'her about'); await sync(e.page); await sync(o.page); await sync(o.page);
  }
  test('materialize twice from two fresh contexts of the same person: one new note, one edit, right text', async () => {
    const { srv, ph, o, close } = await pair({ fight_notes: { n1: N1() } });
    await sidesWithEdit(srv, ph);
    const analyses = () => mineOnFight(srv).filter((n) => n.kind === 'analysis');
    assert.equal(mineOnFight(srv).length, 2, JSON.stringify(mineOnFight(srv).map((n) => n.body)));
    assert.equal(srv.t.fight_notes.n1.body, 'edited in the talk');
    assert.equal(analyses()[0].body, 'what it is about');
    const o2 = await phone(srv, ME);                                // reinstall / second device: nothing on disk
    await sync(o2.page); await sync(o2.page); await o2.page.waitForTimeout(300); await sync(o2.page);
    assert.equal(mineOnFight(srv).length, 2, 'still two notes: ' + JSON.stringify(mineOnFight(srv).map((n) => n.body)));
    const mine = srv.posts.filter((p) => p.table === 'fight_notes' && p.uid === ME), bad = srv.refused.filter((p) => p.table === 'fight_notes' && p.uid === ME);
    assert.equal(mine.length - bad.length, 1, 'accepted once ' + JSON.stringify([mine.map((p) => p.row.id), bad.map((p) => [p.status, p.row.id])]));
    assert.equal(srv.patches.filter((p) => p.table === 'fight_notes' && p.uid === ME).length, 1, 'the edit was applied once');
    assert.equal(srv.t.fight_notes.n1.body, 'edited in the talk');
    await o2.context.close(); await close();
  });
  test('an edit made on the fight page after submitting is never overwritten by the older talk text', async () => {
    const { srv, ph, close } = await pair({ fight_notes: { n1: N1() } });
    await sidesWithEdit(srv, ph, async () => {
      await ph.o.page.evaluate(() => CycleStore.patch('fight_notes', 'n1', { body: 'a newer edit' })); await sync(ph.o.page);
    });
    assert.equal(srv.t.fight_notes.n1.body, 'a newer edit');
    assert.equal(srv.patches.filter((p) => p.table === 'fight_notes' && p.id === 'n1').length, 1, 'only the person\'s own edit');
    await close();
  });
  async function toOwnUp(ph) {
    const o = ph.o, e = ph.e;
    await o.page.click('[data-a="ttstart:fp"]'); await side(o, 'I felt attacked.', 'Money talks when rested.'); await sync(o.page);
    await sync(e.page); await e.page.reload(); await sync(e.page); await e.page.evaluate(() => cycleNative.route('fight/fp')); await e.page.click('[data-a="ttgo:fp"]');
    await side(e, 'I felt left out.', 'The trip.'); await sync(e.page); await sync(o.page);
    await doHeard(o, 'You felt left out.', 'Fair.'); await doHeard(e, 'You felt attacked.', 'Late.'); await sync(o.page); await sync(e.page); await sync(o.page);
    await e.page.click('[data-a="ttverdict:got_it"]'); await o.page.click('[data-a="ttverdict:got_it"]'); await sync(e.page); await sync(o.page);
  }
  test('the partner\'s own-up arrives once both are in, and is absent before', async () => {
    const { ph, o, e, close } = await pair();
    await toOwnUp(ph);
    await o.page.fill('textarea[data-d="to_part"]', 'I said no before hearing you out.'); await o.page.click('[data-a="ttown"]'); await sync(o.page); await sync(e.page);
    assert.doesNotMatch(await text(e.page, '.ttk'), /I said no before hearing/, 'hidden while Esme has not finished hers');
    assert.doesNotMatch(await text(o.page, '.ttk'), /Esme's part/);
    await e.page.fill('textarea[data-d="to_part"]', 'I texted at 1am.'); await e.page.click('[data-a="ttown"]'); await sync(e.page); await sync(o.page);
    assert.match(await text(o.page, '.ttk'), /Esme's part[\s\S]*I texted at 1am\./);
    assert.match(await text(e.page, '.ttk'), /Oliver's part[\s\S]*I said no before hearing you out\./);
    await shot(o.page, 'step4-partner-part');
    await close();
  });
  test('sending What I heard keeps a verdict note typed on the same screen', async () => {
    const { ph, o, e, close } = await pair();
    await o.page.click('[data-a="ttstart:fp"]'); await side(o, 'I felt attacked.', 'Money talks.'); await sync(o.page);
    await sync(e.page); await e.page.reload(); await sync(e.page); await e.page.evaluate(() => cycleNative.route('fight/fp')); await e.page.click('[data-a="ttgo:fp"]');
    await side(e, 'I felt left out.', 'The trip.'); await sync(e.page); await sync(o.page);
    await doHeard(o, 'You felt left out.', 'Fair.'); await sync(o.page); await sync(e.page);
    await e.page.fill('textarea[data-d="th_heard"]', 'You felt attacked.');
    await e.page.click('[data-a="ttnq:open"]');
    await e.page.fill('textarea[data-d="tv_note"]', 'a note I am still writing');
    await e.page.click('[data-a="ttnq:cancel"]'); await e.page.click('[data-a="ttheard"]');
    await e.page.click('[data-a="ttnq:open"]'); // (the missed-box hides my heard form, so the note is now typed after the heard is filled and kept across Cancel and Send)
    assert.equal(await e.page.inputValue('textarea[data-d="tv_note"]'), 'a note I am still writing');
    await close();
  });
  test('the fake server refuses what the live policy refuses (so "once" and "refused" claims are real)', async () => {
    const { srv, o, close } = await pair();
    await o.page.click('[data-a="ttstart:fp"]'); await side(o, 'only mine', undefined); await sync(o.page);
    const post = (uid, row) => o.page.evaluate(async (r) => { const res = await fetch('https://x.test/rest/v1/talkthrough_events', { method: 'POST', body: JSON.stringify(r) }); return res.status; }, row);
    // note: these requests go through the same route handler as the app's, as Oliver
    const base = { couple_id: 'c1', fight_marker_id: 'fp' };
    assert.equal(await post(ME, { id: 'x1', author_id: HER, kind: 'side', field: 'what', body: 'forged', ...base }), 403);
    assert.equal(await post(ME, { id: 'x2', author_id: ME, kind: 'side_done', ...base }), 409, 'second marker');
    assert.equal(await post(ME, { id: 'x3', author_id: ME, kind: 'side', field: 'about', body: 'late', ...base }), 403, 'text after the marker');
    assert.equal(await post(ME, { id: 'x4', author_id: ME, kind: 'ownup_done', ...base }), 403, 'marker without text');
    await close();
  });

  // ---- UI review fixes: one Send, in-flow Send on the waiting screen, full-width singles, first names, texts while waiting, label gaps, hit areas ----
  const visCount = (page, sel) => page.$$eval(sel, (els) => els.filter((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(e).visibility !== 'hidden'; }).length);
  const rect = (page, sel) => page.$eval(sel, (e) => { const r = e.getBoundingClientRect(); return { top: r.top + document.querySelector('.scr').scrollTop, bottom: r.bottom + document.querySelector('.scr').scrollTop, width: r.width, left: r.left, height: r.height }; });
  test('Not quite open: exactly one Send is visible (my own form is hidden, its drafts survive Cancel) and the "<Name> heard" heading has the normal section gap', async () => {
    const { e, close } = await atVerdict();
    await e.page.fill('textarea[data-d="th_heard"]', 'my half-written reflection');
    assert.equal(await visCount(e.page, '[data-a="ttheard"]'), 1, 'my own Send shows before Not quite');
    await e.page.click('[data-a="ttnq:open"]'); await e.page.fill('textarea[data-d="tv_note"]', 'You skipped the money part.');
    assert.equal(await visCount(e.page, '[data-a="ttheard"], [data-a="ttnqsend"]'), 1, 'one Send while the missed box is open');
    assert.equal(await visCount(e.page, '[data-a="ttnqsend"]'), 1);
    assert.equal(await e.page.locator('textarea[data-d="th_heard"]').count(), 0, 'my heard form is gone while the missed box is open');
    const g = await e.page.evaluate(() => {
      const secs = [...document.querySelectorAll('.ttk main > section')], i = secs.findIndex((x) => x.classList.contains('tt-hd'));
      return { before: secs[i].getBoundingClientRect().top - secs[i - 1].getBoundingClientRect().bottom, after: secs[i + 1].getBoundingClientRect().top - secs[i].getBoundingClientRect().bottom };
    });
    assert.ok(Math.abs(g.before - g.after) <= 1 && g.before >= 20, 'heard heading gap equals the gap to the next section: ' + JSON.stringify(g));
    await shot(e.page, 'not-quite-open');
    await e.page.click('[data-a="ttnq:cancel"]');
    assert.equal(await e.page.inputValue('textarea[data-d="th_heard"]'), 'my half-written reflection', 'draft restored on Cancel');
    assert.equal(await visCount(e.page, '[data-a="ttheard"]'), 1);
    await close();
  });
  test('waiting screen after an empty Not quite: the Send for the late box is in flow, full width, right under the box, which has the partner\'s heard above it; texts show on the waiting screens of steps 1 and 2', async () => {
    const { srv, o, e, close } = await atVerdict({ fight_markers: { fp: marker(SPAN) } });
    await doHeard(e, 'You felt loud.', 'Late.');
    const heard = Object.values(srv.t.talkthrough_events).find((x) => x.kind === 'heard' && x.author_id === ME);
    await e.page.evaluate((h) => { CycleStore.insert('talkthrough_events', { id: crypto.randomUUID(), couple_id: 'c1', fight_marker_id: 'fp', author_id: 'u-her', kind: 'verdict', ref_id: h.id, verdict: 'not_quite', body: null, created_at: new Date().toISOString() }); }, heard);
    await until(e.page, () => /Waiting on Oliver/.test(document.querySelector('.ttk')?.textContent || '') && !!document.querySelector('[data-a="ttnqsend"]'));
    await e.page.evaluate(() => { document.querySelector('.scr').scrollTop = 0; });
    assert.equal(await e.page.locator('.tt-foot').count(), 0, 'no pinned footer');
    const box = await rect(e.page, '.ttk .ta'), send = await rect(e.page, '[data-a="ttnqsend"]'), hd = await rect(e.page, '.tt-hd');
    assert.ok(send.top >= box.bottom && send.top - box.bottom <= 24, 'Send directly under the box: ' + JSON.stringify({ box, send }));
    assert.ok(Math.abs(send.width - box.width) <= 1 && Math.abs(send.left - (await rect(e.page, '.ttk .ta')).left) <= 1, 'Send is as wide as the box: ' + JSON.stringify({ box, send }));
    assert.ok(hd.bottom <= box.top, 'the partner\'s heard is above the box');
    assert.match(await text(e.page, '.tt-hd'), /Oliver heard\s*You felt left out\./);
    assert.match(await text(e.page, '.tt-tx'), /^Texts · 2$/, 'texts block on the step 2 waiting screen');
    await shot(e.page, 'waiting-screen-with-missed-box');
    // Step 1 waiting screen: Oliver submitted first, Esme not yet.
    const r = await pair({ fight_markers: { fp: marker(SPAN) } });
    await r.o.page.click('[data-a="ttstart:fp"]'); await side(r.o, 'I felt attacked.', 'Money talks.');
    await until(r.o.page, () => /Waiting on Esme/.test(document.querySelector('.ttk')?.textContent || ''));
    assert.match(await text(r.o.page, '.tt-tx'), /^Texts · 2$/, 'texts block on the step 1 waiting screen');
    await shot(r.o.page, 'step1-waiting-texts');
    await r.close(); await close();
  });
  test('a lone action button is full width, not half a two-column grid; a real pair stays two columns', async () => {
    const { e, close } = await atVerdict();
    const w = async () => e.page.$eval('.tt-foot .pair', (p) => [...p.children].map((c) => c.getBoundingClientRect().width));
    const two = await w(); assert.equal(two.length, 2);
    await e.page.evaluate(() => document.querySelector('.tt-foot .pair [data-a="ttnq:open"]').remove());
    const one = await w(); assert.ok(Math.abs(one[0] - (two[0] + two[1] + 10)) <= 1, 'lone button spans the pair: ' + JSON.stringify({ one, two }));
    await close();
  });
  test('talk strings use the partner\'s first name even when the member name has two words; non-talk screens still show the full name', async () => {
    const members = [{ ...MEMBERS[0], name: 'Oliver Ullman' }, { ...MEMBERS[1], name: 'Esme Robinson' }];
    const { srv, o, e, close } = await atVerdict({ fight_notes: { n1: note('n1', ME, 'old note text') } }, members);
    const heard = Object.values(srv.t.talkthrough_events).find((x) => x.kind === 'heard' && x.author_id === ME);
    let t = await text(e.page, '.ttk');
    assert.match(t, /Oliver's side[\s\S]*Oliver heard/); assert.doesNotMatch(t, /Ullman/, 'no surname anywhere on the talk screen: ' + t);
    await shot(e.page, 'two-word-name-step2');
    await e.page.click('[data-a="ttnq:open"]'); assert.match(await text(e.page, '.ttk'), /What Oliver missed/);
    await e.page.click('[data-a="ttnq:cancel"]');
    // Oliver's own screen: Esme answers his heard with an empty Not quite, then "Esme said not quite" on his revise screen.
    await doHeard(e, 'You felt loud.', 'Late.'); await e.page.evaluate((h) => { CycleStore.insert('talkthrough_events', { id: crypto.randomUUID(), couple_id: 'c1', fight_marker_id: 'fp', author_id: 'u-her', kind: 'verdict', ref_id: h.id, verdict: 'not_quite', body: null, created_at: new Date().toISOString() }); }, heard);
    await sync(e.page); await sync(o.page);
    await until(o.page, () => /said not quite/.test(document.querySelector('.ttk')?.textContent || ''));
    t = await text(o.page, '.ttk'); assert.match(t, /Esme said not quite/); assert.doesNotMatch(t, /Robinson/);
    // The fight-card chip is a talk string too.
    await o.page.evaluate(() => cycleNative.route('fight/fp')); await o.page.waitForSelector('.tt-card');
    assert.doesNotMatch(await text(o.page, '.tt-card'), /Robinson/);
    await close();
  });
  test('step 1 label rows: both labels sit the same distance above their box, the ? stays centred on its label; hit areas are at least 32px', async () => {
    const { o, close } = await pair();
    await o.page.click('[data-a="ttstart:fp"]');
    const gaps = await o.page.evaluate(() => [...document.querySelectorAll('.ttk .tt-f')].map((s) => s.querySelector('.ta').getBoundingClientRect().top - s.querySelector('.lab').getBoundingClientRect().bottom));
    assert.equal(gaps.length, 2); assert.ok(Math.abs(gaps[0] - gaps[1]) <= 0.5, 'label to box gaps equal: ' + gaps);
    const c = await o.page.evaluate(() => { const l = document.querySelector('.tt-lh'), i = l.querySelector('.tt-q i').getBoundingClientRect(), t = document.createRange(); t.selectNodeContents(l.firstChild); const r = t.getBoundingClientRect(); return { i: i.top + i.height / 2, t: r.top + r.height / 2 }; });
    assert.ok(Math.abs(c.i - c.t) <= 2, '? centred on the label: ' + JSON.stringify(c));
    for (const q of await o.page.$$('.ttk .tt-q')) { const b = await q.boundingBox(); assert.ok(b.width >= 32 && b.height >= 32, '? hit area ' + JSON.stringify(b)); }
    await shot(o.page, 'step1-label-gaps');
    await close();
    const r = await pair(); await r.o.page.click('[data-a="ttstart:fp"]'); await side(r.o, 'a', 'b'); await sync(r.o.page);
    await sync(r.e.page); await r.e.page.reload(); await sync(r.e.page); await r.e.page.evaluate(() => cycleNative.route('fight/fp')); await r.e.page.click('[data-a="ttgo:fp"]'); await side(r.e, 'c', 'd');
    await until(r.o.page, () => !!document.querySelector('.tt-wl'));
    const wl = await r.o.page.locator('.tt-wl').boundingBox(), main = await r.o.page.locator('.ttk .ta').first().boundingBox();
    assert.ok(wl.height >= 44 && Math.abs(wl.width - main.width) <= 1, 'the whole Why can’t I argue row is the 44px target: ' + JSON.stringify({ wl, main }));
    await r.close();
  });
  test('Texts row: chevron down when collapsed, up when expanded; the last bubble sits ~32px above the next label', async () => {
    const { o, close } = await pair({ fight_markers: { fp: marker(SPAN) } });
    await o.page.click('[data-a="ttstart:fp"]');
    const rot = () => o.page.$eval('.tt-tx .chv', (c) => getComputedStyle(c).transform);
    const down = await rot(); assert.equal(down, 'matrix(0, 1, -1, 0, 0, 0)', 'collapsed = rotated 90deg (pointing down)');
    await o.page.click('[data-a="tttx"]');
    assert.equal(await rot(), 'matrix(0, -1, 1, 0, 0, 0)', 'expanded = rotated -90deg (pointing up)');
    const gap = await o.page.evaluate(() => { const b = [...document.querySelectorAll('.tt-tx .txm')].pop().getBoundingClientRect(); return document.querySelector('.tt-tx').nextElementSibling.querySelector('.lab').getBoundingClientRect().top - b.bottom; });
    assert.ok(Math.abs(gap - 32) <= 2, 'last bubble to next label: ' + gap);
    await close();
  });
  test('the pinned footer fade is 48px, solid for its last 16px', async () => {
    const { o, close } = await pair(); await o.page.click('[data-a="ttstart:fp"]');
    const f = await o.page.$eval('.tt-foot', (e) => ({ pt: getComputedStyle(e).paddingTop, bg: getComputedStyle(e).backgroundImage }));
    assert.equal(f.pt, '48px'); assert.match(f.bg, /rgb\(10, 10, 10\) 32px/);
    await close();
  });
});

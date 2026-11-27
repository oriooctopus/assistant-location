// Insights tab (Oliver-only private chat) on the real page: tab visibility per account, optimistic send with an in-place spinner,
// markdown answers, retry, the upset chip, drafts across reloads, offline, and chat list rename/delete.
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

describe('insights (webkit)', { skip: !haveWebkit }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  // box(req) -> {status, body}; held answers: return a promise to keep the request open. Every box call lands in `boxCalls`.
  async function open({ uid = OLIVER, box, convs, live, auto = [] } = {}) {
    const boxCalls = [];
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(NOW));
    await context.addInitScript(({ sd, auto }) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: 'https://box.test', insAutoDelays: auto };
      if (!sessionStorage.getItem('seeded')) { sessionStorage.setItem('seeded', '1'); for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k])); }
    }, { sd: seed(uid, convs), auto });
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
  const tabs = (page) => page.$$eval('.tabbar .tab', (els) => els.map((e) => e.getAttribute('data-a')));
  const posts = (o) => o.boxCalls.filter((c) => c.method === 'POST' && c.path === '/insights');
  const answer = (text, mode = 'normal', model = 'opus', extra = {}) => ({ sse: [{ t: 'start', mode, model }, { t: 'd', text }, { t: 'done', conversation_id: 'x', answer: text, mode, model, stopped: false, vers: 1, sel: 0, ...extra }] });

  test('tab: Oliver sees Insights between Fights and Progress; Esme never does and the route cannot be reached', async () => {
    const o = await open({ uid: OLIVER });
    assert.deepEqual(await tabs(o.page), ['tab:home', 'tab:todo', 'tab:fights', 'tab:insights', 'tab:progress']);
    await o.context.close();
    const e = await open({ uid: ESME });
    assert.deepEqual(await tabs(e.page), ['tab:home', 'tab:todo', 'tab:fights', 'tab:progress']);
    assert.equal(await e.page.$('[data-a="inschip:0"]'), null);
    assert.equal(e.boxCalls.filter((c) => c.path.startsWith('/insights')).length, 0);
    await e.context.close();
  });

  test('thinking view: header says what it is doing now, thoughts are one-line headlines that expand to their full text, and the log stays on the answer', async () => {
    const o = await open({ live: true, box: async () => ({ status: 200, body: { ok: true } }) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'why do we fight');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.st.ld .spin');
    assert.equal(await o.page.textContent('.thel'), 'Thinking');
    assert.match(await o.page.textContent('.thn'), /^\d+s$/);
    await feed(o.page, { t: 'step', k: 'tool', text: 'Reading your texts' });
    await o.page.waitForFunction(() => document.querySelector('.thel').textContent === 'Reading your texts');
    await feed(o.page, { t: 'step', k: 'think', text: 'Looking at Aug' });
    assert.equal(await o.page.textContent('.thel'), 'Reading your texts', 'an unfinished sentence is not a headline yet');
    await feed(o.page, { t: 'step', k: 'think', text: 'ust.\nThen the party.' });
    await o.page.waitForFunction(() => document.querySelector('.thel').textContent === 'Looking at August');
    await feed(o.page, { t: 'step', k: 'think', text: '\n\n**Weighing the money fights**\n\nMost of them' });
    await o.page.waitForFunction(() => document.querySelector('.thel').textContent === 'Weighing the money fights');
    await feed(o.page, { t: 'step', k: 'tool', text: 'Reading Personal/Granola/a.md' });
    await feed(o.page, { t: 'step', k: 'tool', text: 'Searching “money” in Personal/Esme' });
    await o.page.waitForFunction(() => document.querySelector('.thel').textContent === 'Searching “money” in Esme'); // the header drops the folders
    await feed(o.page, { t: 'step', k: 'note', text: 'Let me chec' });
    await feed(o.page, { t: 'step', k: 'note', text: 'Let me check more.' });
    await o.page.waitForFunction(() => document.querySelector('.thel').textContent === 'Let me check more.');
    await feed(o.page, { t: 'step', k: 'think', text: '\n\nThe pattern is clear. Rent.' });
    await o.page.waitForFunction(() => document.querySelector('.thel').textContent === 'The pattern is clear');
    assert.match(await o.page.textContent('.thn'), /^\d+s · 7 steps$/); // 3 tools... 1 note, 3 thoughts
    // Recent items sit under the header, thoughts as one-line headlines.
    assert.deepEqual(await o.page.$$eval('.thk .thl li', (l) => l.map((x) => x.querySelector('.thh1') ? x.querySelector('.thh1').textContent : x.textContent)), ['Reading Personal/Granola/a.md', 'Searching “money” in Personal/Esme', 'Let me check more.']);
    // The header opens the whole list; a thought opens its full text on that frame.
    await o.page.click('.thk .thh');
    assert.equal((await o.page.$$('.thk .thl li')).length, 7);
    assert.equal(await o.page.$eval('.thk .thh1', (e) => getComputedStyle(e).whiteSpace + '|' + getComputedStyle(e).textOverflow), 'nowrap|ellipsis');
    assert.equal(await o.page.$('.thk .thfull'), null);
    await o.page.click('.thk .thl li:nth-child(3) .thrh');
    assert.match(await o.page.textContent('.thk .thfull'), /^Most of them$/);
    await feed(o.page, { t: 'start', mode: 'normal', model: 'opus' });
    await feed(o.page, { t: 'd', text: 'Mostly money.' });
    await o.page.waitForSelector('.thc');
    assert.match(await o.page.textContent('.thc'), /^Thought \d+s · 7 steps$/);
    assert.equal(await o.page.textContent('.im.st'), 'Mostly money.'); // the toggle is outside the answer bubble
    await feed(o.page, { t: 'done', conversation_id: 'x', answer: 'Mostly money.', mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0 });
    await o.page.waitForFunction(() => !document.querySelector('.stw'));
    // After the answer the Thought row stays on the message, closed, and opens like before.
    assert.match(await o.page.textContent('.thw .thc'), /^Thought \d+s · 7 steps$/);
    assert.equal(await o.page.$('.thw .thx'), null);
    await o.page.click('.thw .thc');
    assert.equal((await o.page.$$('.thw .thx li')).length, 7);
    assert.equal(await o.page.textContent('.thw .thx li:nth-child(1)'), 'Reading your texts');
    assert.equal(await o.page.$('.thw .thfull'), null);
    await o.page.click('.thw .thx li:nth-child(2) .thrh');
    assert.match(await o.page.textContent('.thw .thfull'), /^Looking at August\.\nThen the party\.$/);
    assert.equal(await o.page.textContent('.thw .thx li:nth-child(2) .thh1'), 'Looking at August');
    await o.page.click('.thw .thx li:nth-child(2) .thrh');
    assert.equal(await o.page.$('.thw .thfull'), null);
    await o.context.close();
  });

  test('send: question shows at once, spinner in place while waiting, answer renders as markdown, body is right', async () => {
    let release;
    const gate = new Promise((r) => { release = r; });
    const o = await open({ box: async (req) => { if (req.method === 'POST' && req.path === '/insights') { await gate; return answer('Mostly **money**.\n- Aug 17: bill\n- Oct 25: party'); } } });
    await o.page.click('[data-a="tab:insights"]');
    assert.equal((await o.page.$$('[data-a^="inschip:"]')).length, 5);
    await o.page.fill('[data-d="ins_msg"]', 'what are our fights mostly about?');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.u');
    assert.equal(await o.page.textContent('.im.u'), 'what are our fights mostly about?');
    await o.page.waitForSelector('.im.ld .spin');
    assert.equal(await o.page.inputValue('[data-d="ins_msg"]'), ''); // box cleared on the tap
    release();
    await o.page.waitForSelector('.im.a b');
    assert.equal(await o.page.$('.im.ld'), null);
    assert.equal((await o.page.$$('.im.a li')).length, 2);
    const post = posts(o)[0];
    assert.deepEqual({ ...post.body, conversation_id: typeof post.body.conversation_id }, { conversation_id: 'string', message: 'what are our fights mostly about?', upset: false, retry: false, model: 'opus' });
    await o.context.close();
  });

  test('stream dies after the box saved the answer: the answer shows, "Not answered" never shows', async () => {
    let q = null;
    const o = await open({ box: async (req) => {
      if (req.method === 'POST' && req.path === '/insights') { q = req.body; return undefined; } // the connection drops: fetch rejects like iOS "Load failed"
      if (req.method === 'GET' && req.path.startsWith('/insights/conversations/') && q) return { status: 200, body: { id: q.conversation_id, title: 'q', created_at: NOW, updated_at: NOW, model: 'opus', busy: false, messages: [{ role: 'user', text: q.message, at: NOW }, { role: 'assistant', text: 'Mostly **money**.', mode: 'normal', model: 'opus', stopped: false, at: NOW }] } };
    } });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'what are our fights about?');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.ld .spin');
    await o.page.waitForSelector('.im.a b', { timeout: 10000 });
    assert.equal(await o.page.$('.im.err'), null);
    assert.ok(!/Not answered/.test(await o.page.textContent('body')));
    assert.equal(posts(o).length, 1);
    await o.context.close();
  });

  test('upset chip sends upset:true; a failed answer keeps the question with Retry, and Retry sends retry:true', async () => {
    let n = 0;
    const o = await open({ box: async (req) => { if (req.method === 'POST') return n++ ? answer('Leave the room.', 'upset') : { status: 502, body: { error: 'x' } }; } });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.click('[data-a="inschip:3"]');
    await o.page.waitForSelector('.im.err');
    assert.equal(await o.page.textContent('.im.u'), 'I’m upset');
    assert.equal(posts(o)[0].body.upset, true);
    await o.page.click('[data-a="insretry"]');
    await o.page.waitForSelector('.im.a.up');
    assert.equal(posts(o)[1].body.retry, true);
    assert.equal(posts(o)[1].body.upset, true);
    assert.equal((await o.page.$$('.im.u')).length, 1);
    await o.context.close();
  });

  test('a failed answer retries itself with no tap: spinner instead of Not answered, then the answer; after the last try Not answered returns', async () => {
    let n = 0;
    const o = await open({ auto: [1500, 100, 100], box: async (req) => { if (req.method === 'POST') return n++ ? answer('Mostly money.') : { status: 502, body: { error: 'x' } }; } });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'why do we fight');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForFunction(() => document.querySelector('.im.u'));
    while (posts(o).length < 1) await o.page.waitForTimeout(50);
    await o.page.waitForTimeout(500); // the 502 is back; the retry is 1.5s away
    assert.equal(posts(o).length, 1);
    assert.ok(await o.page.$('.im.ld .spin'), 'pending retry shows the spinner');
    assert.ok(!/Server error/.test(await o.page.textContent('body')), 'no 502 error bar while the retry is pending'); // (the harness refuses state-backup calls, so a sync "No connection" bar can show; that is not this failure)
    assert.equal(await o.page.$('.im.err'), null);
    assert.ok(!/Not answered/.test(await o.page.textContent('body')));
    if (process.env.INS_SHOT) await o.page.screenshot({ path: process.env.INS_SHOT });
    await o.page.waitForSelector('.im.a:not(.ld)', { timeout: 10000 });
    assert.equal(posts(o).length, 2);
    assert.equal(posts(o)[1].body.retry, true);
    assert.equal((await o.page.$$('.im.u')).length, 1);
    assert.equal(await o.page.$('.im.err'), null);
    await o.context.close();
  });

  test('automatic retries stop after three: Not answered with Retry shows and no fourth post goes out', async () => {
    const o = await open({ auto: [50, 50, 50], box: async (req) => { if (req.method === 'POST') return { status: 502, body: { error: 'x' } }; } });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'why do we fight');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.err', { timeout: 10000 });
    await o.page.waitForTimeout(600);
    assert.equal(posts(o).length, 4);
    assert.ok(/Not answered/.test(await o.page.textContent('.im.err')));
    await o.context.close();
  });

  test('Check the WhatsApp chip comes first and sends that question, not upset', async () => {
    const o = await open({ box: async (req) => { if (req.method === 'POST' && req.path === '/insights') return answer('Last text 3:10pm.'); } });
    await o.page.click('[data-a="tab:insights"]');
    assert.equal(await o.page.textContent('[data-a="inschip:0"]'), 'Check the WhatsApp');
    await o.page.click('[data-a="inschip:0"]');
    await o.page.waitForSelector('.im.a');
    assert.equal(posts(o)[0].body.message, 'Check the WhatsApp');
    assert.equal(posts(o)[0].body.upset, false);
    await o.context.close();
  });

  test('draft survives a reload; offline send keeps the draft and calls nothing', async () => {
    const o = await open();
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'half typed');
    await o.page.waitForTimeout(500);
    await o.page.reload(); await o.page.waitForSelector('.tabbar');
    await o.page.click('[data-a="tab:insights"]');
    assert.equal(await o.page.inputValue('[data-d="ins_msg"]'), 'half typed');
    await o.context.setOffline(true);
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.off');
    assert.equal(await o.page.inputValue('[data-d="ins_msg"]'), 'half typed');
    assert.equal(posts(o).length, 0);
    await o.context.close();
  });

  test('chats list: open, rename (optimistic, PATCH), delete (optimistic, DELETE)', async () => {
    const convs = { convs: [{ id: 'conv-0001-aaaa', title: 'Bills', updated_at: '2026-11-22T10:00:00Z' }, { id: 'conv-0002-bbbb', title: 'Party', updated_at: '2026-11-21T10:00:00Z' }],
      byId: { 'conv-0001-aaaa': { id: 'conv-0001-aaaa', title: 'Bills', updated_at: '2026-11-22T10:00:00Z', messages: [{ role: 'user', text: 'q1' }, { role: 'assistant', text: 'a1', mode: 'normal' }] }, 'conv-0002-bbbb': { id: 'conv-0002-bbbb', title: 'Party', updated_at: '2026-11-21T10:00:00Z', messages: [{ role: 'user', text: 'q2' }, { role: 'assistant', text: 'a2', mode: 'normal' }] } } };
    const o = await open({ convs, box: async (req) => {
      if (req.path === '/insights/conversations') return { status: 200, body: { conversations: convs.convs } };
      if (req.method === 'PATCH' || req.method === 'DELETE') return { status: 200, body: { ok: true } };
      if (req.method === 'GET') return { status: 200, body: convs.byId[req.path.split('/').pop()] };
    } });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.click('[data-a="go:inslist"]');
    await o.page.waitForSelector('[data-a="insopen:conv-0002-bbbb"]');
    await o.page.click('[data-a="insopen:conv-0002-bbbb"]');
    await o.page.waitForSelector('.im.a');
    assert.equal(await o.page.textContent('.im.a'), 'a2');
    await o.page.click('[data-a="go:inslist"]');
    await o.page.click('[data-a="insren:conv-0001-aaaa"]');
    await o.page.fill('[data-d="ins_ren"]', 'Money');
    await o.page.click('[data-a="inssaveren:conv-0001-aaaa"]');
    await o.page.waitForSelector('text=Money');
    await o.page.click('[data-a="insdel:conv-0002-bbbb"]');
    await o.page.waitForFunction(() => !document.querySelector('[data-a="insopen:conv-0002-bbbb"]'));
    await o.page.waitForTimeout(300);
    assert.deepEqual(o.boxCalls.filter((c) => c.method === 'PATCH' || c.method === 'DELETE').map((c) => `${c.method} ${c.path} ${JSON.stringify(c.body)}`),
      ['PATCH /insights/conversations/conv-0001-aaaa {"title":"Money"}', 'DELETE /insights/conversations/conv-0002-bbbb null']);
    await o.context.close();
  });

  const feed = (page, ev) => page.evaluate((e) => window.__sc.enqueue(new TextEncoder().encode('data: ' + JSON.stringify(e) + '\n\n')), ev);
  const conv1 = (extra = {}) => ({ id: 'conv-0001-aaaa', title: 'Bills', updated_at: '2026-11-23T14:00:00Z', ...extra });
  const full = (c, messages) => ({ ...c, messages });
  const A = (text, extra = {}) => ({ role: 'assistant', text, mode: 'normal', model: 'opus', stopped: false, ...extra });
  const seedOne = (messages, row = {}) => { const c = conv1(row); return { convs: [c], byId: { [c.id]: full(c, messages) } }; };
  const openOne = async (messages, box, row) => {
    const convs = seedOne(messages, row);
    const o = await open({ convs, box: box || (async (req) => { if (req.path === '/insights/conversations') return { status: 200, body: { conversations: convs.convs } }; if (req.method === 'PATCH') { if (req.body.model) { convs.convs[0].model = req.body.model; convs.byId['conv-0001-aaaa'].model = req.body.model; } return { status: 200, body: { ok: true } }; } if (req.method === 'GET') return { status: 200, body: convs.byId[req.path.split('/').pop()] }; }) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.click('[data-a="go:inslist"]');
    await o.page.click('[data-a="insopen:conv-0001-aaaa"]');
    await o.page.waitForSelector('.im.a');
    await o.page.waitForTimeout(300); // the once-per-open server re-read has finished
    return o;
  };

  test('stream: spinner until the first token, text grows in place without losing the keyboard, Stop replaces Send, Stopped keeps the partial', async () => {
    const o = await open({ live: true, box: async () => ({ status: 200, body: { ok: true } }) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.click('[data-a="insmenu"]');
    await o.page.click('[data-a="insmodel:sonnet"]');
    await o.page.fill('[data-d="ins_msg"]', 'why do we fight');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.st.ld .spin');
    assert.ok(await o.page.$('[data-a="insstop"]')); assert.ok(await o.page.$('[data-a="inssend"].dis')); // Send waits beside Stop, disabled until there is text
    assert.equal((await o.page.evaluate(() => window.__posts))[0].model, 'sonnet');
    await o.page.focus('[data-d="ins_msg"]');
    await feed(o.page, { t: 'start', mode: 'normal', model: 'sonnet' });
    await feed(o.page, { t: 'd', text: 'Mostly mon' });
    await o.page.waitForFunction(() => document.querySelector('.im.st') && !document.querySelector('.im.st.ld'));
    assert.equal(await o.page.textContent('.im.st'), 'Mostly mon');
    await feed(o.page, { t: 'd', text: 'ey.' });
    await o.page.waitForFunction(() => document.querySelector('.im.st').textContent === 'Mostly money.');
    assert.equal(await o.page.evaluate(() => document.activeElement.getAttribute('data-d')), 'ins_msg'); // focus survived the paints
    await o.page.click('[data-a="insstop"]');
    await o.page.waitForFunction(() => true);
    assert.ok(o.boxCalls.some((c) => c.path === '/insights/stop' && c.method === 'POST'));
    await feed(o.page, { t: 'done', conversation_id: 'x', answer: 'Mostly money.', mode: 'normal', model: 'sonnet', stopped: true, vers: 1, sel: 0 });
    await o.page.click('[data-a="insmore:1"]');
    await o.page.waitForSelector('.ia .stp');
    assert.equal(await o.page.textContent('.ia .stp'), 'Stopped');
    assert.equal(await o.page.textContent('.im.a'), 'Mostly money.');
    assert.equal(await o.page.textContent('.ia .ml'), 'Sonnet');
    assert.ok(await o.page.$('[data-a="inssend"]')); assert.equal(await o.page.$('[data-a="insstop"]'), null);
    await o.context.close();
  });

  test('stream: follows the bottom until the reader scrolls up, even 30px, then stays put; back at the bottom it follows again', async () => {
    const o = await open({ live: true, box: async () => ({ status: 200, body: { ok: true } }) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'why do we fight');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.st.ld .spin');
    await feed(o.page, { t: 'start', mode: 'normal', model: 'opus' });
    const para = 'A long paragraph that keeps going so the answer is taller than the screen. '.repeat(6) + '\n\n';
    const gap = () => o.page.evaluate(() => { const sc = document.querySelector('.scr'); return sc.scrollHeight - sc.scrollTop - sc.clientHeight; });
    const top = () => o.page.evaluate(() => document.querySelector('.scr').scrollTop);
    for (let i = 0; i < 6; i++) await feed(o.page, { t: 'd', text: para });
    await o.page.waitForFunction(() => document.querySelector('.scr').scrollHeight > document.querySelector('.scr').clientHeight + 300);
    assert.ok(await gap() < 2, 'pinned to the bottom while nobody touches it');
    // The bug: a small scroll up (under the old 80px zone) was yanked back down by the next token.
    await o.page.evaluate(() => { const sc = document.querySelector('.scr'); sc.scrollTop -= 30; });
    await o.page.waitForTimeout(50); // the scroll event has run
    const kept = await top();
    for (let i = 0; i < 3; i++) await feed(o.page, { t: 'd', text: para });
    await o.page.waitForTimeout(100);
    assert.equal(await top(), kept, 'tokens no longer move a reader who scrolled up');
    // A finger on the chat stops following at once, before it has moved at all.
    await o.page.evaluate(() => { const sc = document.querySelector('.scr'); sc.scrollTop = sc.scrollHeight; });
    await o.page.waitForTimeout(50);
    await o.page.evaluate(() => document.querySelector('.scr .stw').dispatchEvent(new Event('touchstart', { bubbles: true })));
    const held = await top();
    await feed(o.page, { t: 'd', text: para }); await o.page.waitForTimeout(100);
    assert.equal(await top(), held, 'no jump under a finger');
    await o.page.evaluate(() => document.dispatchEvent(new Event('touchend')));
    // Back at the bottom: following resumes.
    await o.page.evaluate(() => { const sc = document.querySelector('.scr'); sc.scrollTop = sc.scrollHeight; });
    await o.page.waitForTimeout(50);
    for (let i = 0; i < 2; i++) await feed(o.page, { t: 'd', text: para });
    await o.page.waitForTimeout(100);
    assert.ok(await gap() < 2, 'following again once back at the bottom');
    await o.context.close();
  });

  test('model picker: defaults to Opus, remembered per chat (PATCH on a saved chat), label on the answer', async () => {
    const o = await openOne([{ role: 'user', text: 'q' }, A('a')]);
    assert.equal(await o.page.textContent('.mdl'), 'Opus');
    await o.page.click('[data-a="insmenu"]');
    assert.deepEqual(await o.page.$$eval('.insmenu span', (e) => e.map((x) => x.textContent)), ['Fable', 'Opus', 'Sonnet', 'Haiku']);
    await o.page.click('[data-a="insmodel:haiku"]');
    assert.equal(await o.page.textContent('.mdl'), 'Haiku');
    await o.page.waitForTimeout(200);
    assert.deepEqual(o.boxCalls.filter((c) => c.method === 'PATCH').map((c) => c.body), [{ model: 'haiku' }]);
    await o.page.click('[data-a="go:inslist"]'); await o.page.click('[data-a="insopen:conv-0001-aaaa"]');
    assert.equal(await o.page.textContent('.mdl'), 'Haiku'); // the choice is kept with the chat
    await o.page.click('[data-a="insmore:1"]');
    assert.equal(await o.page.textContent('.ia .ml'), 'Opus'); // each answer names the model that wrote it
    await o.context.close();
  });

  test('regenerate: the old answer comes back as 1/2, the new one is 2/2, the switcher PATCHes the shown version', async () => {
    const o = await openOne([{ role: 'user', text: 'q' }, A('first')], async (req) => {
      if (req.path === '/insights/conversations') return { status: 200, body: { conversations: [conv1()] } };
      if (req.method === 'POST') return answer('second', 'normal', 'opus', { vers: 2, sel: 1 });
      if (req.method === 'PATCH') return { status: 200, body: { ok: true } };
      return { status: 200, body: full(conv1(), [{ role: 'user', text: 'q' }, A('first')]) };
    });
    await o.page.click('[data-a="insmore:1"]');
    assert.equal(await o.page.$('.vs'), null);
    await o.page.click('[data-a="insregen"]');
    await o.page.waitForSelector('.vs');
    assert.equal(await o.page.textContent('.im.a'), 'second');
    assert.match(await o.page.textContent('.vs'), /2\/2/);
    assert.deepEqual(posts(o)[0].body, { conversation_id: 'conv-0001-aaaa', regenerate: true, model: 'opus' });
    await o.page.click('[data-a="insver:1:0"]');
    await o.page.waitForFunction(() => document.querySelector('.im.a').textContent === 'first');
    assert.match(await o.page.textContent('.vs'), /1\/2/);
    await o.page.waitForTimeout(200);
    assert.deepEqual(o.boxCalls.filter((c) => c.method === 'PATCH').map((c) => c.body), [{ select: { index: 1, ver: 0 } }]);
    assert.equal(await o.page.$('[data-a="insregen"]') !== null, true);
    await o.context.close();
  });

  test('edit: own message only, everything after it goes at once, POST carries edit_index', async () => {
    const o = await openOne([{ role: 'user', text: 'q1' }, A('a1'), { role: 'user', text: 'q2' }, A('a2')], async (req) => {
      if (req.path === '/insights/conversations') return { status: 200, body: { conversations: [conv1()] } };
      if (req.method === 'POST') return answer('new a1');
      return { status: 200, body: full(conv1(), [{ role: 'user', text: 'q1' }, A('a1'), { role: 'user', text: 'q2' }, A('a2')]) };
    });
    assert.equal((await o.page.$$('[data-a^="insedit:"]')).length, 2);
    await o.page.click('[data-a="insedit:0"]');
    await o.page.fill('[data-d="ins_edit"]', 'q1 edited');
    await o.page.click('[data-a="inseditsend:0"]');
    await o.page.waitForFunction(() => document.querySelectorAll('.im.a').length === 1 && document.querySelector('.im.a').textContent === 'new a1');
    assert.deepEqual(await o.page.$$eval('.im.u', (e) => e.map((x) => x.textContent)), ['q1 edited']);
    assert.deepEqual(posts(o)[0].body, { conversation_id: 'conv-0001-aaaa', message: 'q1 edited', edit_index: 0, model: 'opus' });
    await o.context.close();
  });

  test('copy: answer text goes to the clipboard and the control says Copied', async () => {
    const o = await openOne([{ role: 'user', text: 'q' }, A('the answer')]);
    await o.page.evaluate(() => { Object.defineProperty(navigator, 'clipboard', { value: { writeText: async (t) => { window.__copied = t; } }, configurable: true }); });
    await o.page.click('[data-a="insmore:1"]');
    await o.page.click('[data-a="inscopy:1"]');
    await o.page.waitForFunction(() => window.__copied === 'the answer');
    assert.equal(await o.page.getAttribute('[data-a="inscopy:1"]', 'aria-label'), 'Copied');
    await o.context.close();
  });

  test('chat list: Pinned / Today / Yesterday / Earlier groups, pin is instant and PATCHes, search filters titles then asks the box', async () => {
    const rows = [{ id: 'conv-0001-aaaa', title: 'Bills', updated_at: '2026-11-23T14:00:00Z' }, { id: 'conv-0002-bbbb', title: 'Party', updated_at: '2026-11-22T14:00:00Z' }, { id: 'conv-0003-cccc', title: 'Chores', updated_at: '2026-11-10T14:00:00Z' }];
    const convs = { convs: rows, byId: {} };
    const o = await open({ convs, box: async (req) => {
      if (req.path === '/insights/conversations' && req.method === 'GET') return { status: 200, body: { conversations: new URL('https://x/' + (req.query || '')).searchParams.get('q') ? [{ ...rows[2], snippet: 'who does the dishes' }] : rows } };
      if (req.method === 'PATCH') return { status: 200, body: { ok: true } };
    } });
    await o.page.click('[data-a="tab:insights"]'); await o.page.click('[data-a="go:inslist"]');
    await o.page.waitForSelector('[data-a="insopen:conv-0003-cccc"]');
    assert.deepEqual(await o.page.$$eval('.insgh', (e) => e.map((x) => x.textContent)), ['Today', 'Yesterday', 'Earlier']);
    await o.page.click('[data-a="inspin:conv-0003-cccc"]');
    assert.deepEqual(await o.page.$$eval('.insgh', (e) => e.map((x) => x.textContent)), ['Pinned', 'Today', 'Yesterday']); // changed before the box answered
    assert.equal((await o.page.$$eval('.insrow .grow', (e) => e.map((x) => x.textContent)))[0], 'Chores');
    await o.page.waitForTimeout(200);
    assert.deepEqual(o.boxCalls.filter((c) => c.method === 'PATCH').map((c) => c.body), [{ pinned: true }]);
    await o.page.fill('[data-d="ins_q"]', 'dish');
    await o.page.waitForFunction(() => document.querySelector('.insrow small'));
    assert.equal(await o.page.textContent('.insrow small'), 'who does the dishes'); // content hit from the box
    assert.equal((await o.page.$$('.insrow')).length, 1);
    assert.equal(await o.page.evaluate(() => document.activeElement.getAttribute('data-d')), 'ins_q');
    assert.ok(o.boxCalls.some((c) => c.path === '/insights/conversations' && c.method === 'GET'));
    await o.context.close();
  });

  test('a failed pin keeps the change and shows Retry; Retry sends it again', async () => {
    let n = 0;
    const convs = seedOne([{ role: 'user', text: 'q' }, A('a')]);
    const o = await open({ convs, box: async (req) => {
      if (req.path === '/insights/conversations') return { status: 200, body: { conversations: convs.convs } };
      if (req.method === 'PATCH') return n++ ? { status: 200, body: { ok: true } } : { status: 500, body: { error: 'x' } };
    } });
    await o.page.click('[data-a="tab:insights"]'); await o.page.click('[data-a="go:inslist"]');
    await o.page.click('[data-a="inspin:conv-0001-aaaa"]');
    await o.page.waitForSelector('.im.err');
    assert.equal(await o.page.textContent('[data-a="inspin:conv-0001-aaaa"]'), 'Unpin');
    await o.page.click('[data-a="insredo"]');
    await o.page.waitForFunction(() => !document.querySelector('.im.err'));
    assert.equal(o.boxCalls.filter((c) => c.method === 'PATCH').length, 2);
    await o.context.close();
  });

  test('the box names the chat: a title event renames it in the list', async () => {
    const rows = [];
    const o = await open({ box: async (req) => {
      if (req.method === 'POST' && req.path === '/insights') { rows.push({ id: req.body.conversation_id, title: 'Money fights', updated_at: NOW }); const a = answer('ok'); a.sse.push({ t: 'title', title: 'Money fights' }); return a; }
      if (req.path === '/insights/conversations') return { status: 200, body: { conversations: rows } };
    } });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'hello');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.a');
    await o.page.waitForTimeout(300);
    await o.page.click('[data-a="go:inslist"]');
    await o.page.waitForSelector('.insrow');
    assert.equal(await o.page.textContent('.insrow .grow'), 'Money fights');
    assert.equal(await o.page.$('.im.err'), null);
    await o.context.close();
  });

  // Screenshots for review, only when SHOT is set: node SHOT=/tmp/x -> /tmp/x-empty.png, -chat.png (header region).
  test('shots', { skip: !process.env.SHOT }, async () => {
    const o = await openOne([{ role: 'user', text: 'what do we fight about' }, A('Mostly **money**.\n- bills\n- party')]);
    console.log('HDR', JSON.stringify(await o.page.evaluate(() => { const h = document.querySelector('.hd'), r = h.getBoundingClientRect(), b = getComputedStyle(h, '::before'); return { top: r.top, h: r.height, bh: b.height, bt: b.top, bb: b.bottom, mh: b.minHeight, pb: getComputedStyle(h).paddingBottom, mc: getComputedStyle(document.querySelector('.mdl')).color, ic: getComputedStyle(document.querySelector('.insib .ic')).stroke, icc: getComputedStyle(document.querySelector('.insib .ic')).color, op: getComputedStyle(document.querySelector('.mdl')).opacity, z: getComputedStyle(document.querySelector('.mdl')).zIndex, st: document.querySelector('.status').getBoundingClientRect().height }; })));
    await o.page.screenshot({ path: process.env.SHOT + '-chat.png' });
    await o.page.click('[data-a="insnew"]');
    await o.page.screenshot({ path: process.env.SHOT + '-empty.png' });
    await o.context.close();
  });

  // ---- deep research (box: research.mjs) ----
  const JOB = (status, extra = {}) => ({ id: 'job-1', conversation_id: 'conv-0001-aaaa', topic: 'Money', status, attempts: 1, ...extra });
  const researchBox = (state, conv) => async (req) => {
    if (req.path === '/insights/conversations') return { status: 200, body: { conversations: [conv1()] } };
    if (req.path === '/insights/research' && req.method === 'POST') return state.startFails ? { status: 500, body: { error: 'nope' } } : { status: 200, body: JOB('running') };
    if (req.path === '/insights/research') return { status: 200, body: { jobs: [JOB(state.status)] } };
    if (req.path === '/insights/research/job-1/cancel') { state.status = 'cancelled'; return { status: 200, body: JOB('cancelled') }; }
    if (req.path === '/insights/research/job-1/retry') { state.status = 'running'; return { status: 200, body: JOB('running') }; }
    return { status: 200, body: full(conv1(), conv()) };
  };

  test('go deeper: the chip shows the spinner on the tap, the box gets the answer index, and the job is Cancel-able', async () => {
    const state = { status: 'running' }, msgs = [{ role: 'user', text: 'q' }, A('thin answer')];
    const o = await openOne(msgs, researchBox(state, () => msgs));
    await o.page.click('[data-a="insmore:1"]');
    assert.equal(await o.page.$('.im.rj'), null);
    await o.page.click('[data-a="insdeeper:1"]');
    await o.page.waitForSelector('.im.rj .spin');
    await o.page.waitForFunction(() => document.querySelector('[data-a^="insjobx:job-1"]'));
    assert.deepEqual(o.boxCalls.find((c) => c.path === '/insights/research' && c.method === 'POST').body, { conversation_id: 'conv-0001-aaaa', index: 1 });
    assert.equal(await o.page.$('[data-a^="insdeeper"]'), null, 'no second Go deeper on a message that already has a job');
    await o.page.click('[data-a="insjobx:job-1"]');
    await o.page.waitForSelector('.im.err [data-a], .im.err .txtbtn');
    assert.match(await o.page.textContent('.im.err'), /Cancelled/);
    assert.ok(o.boxCalls.some((c) => c.path === '/insights/research/job-1/cancel' && c.method === 'POST'));
    await o.page.click('.im.err');
    await o.page.waitForSelector('.im.rj .spin');
    assert.ok(o.boxCalls.some((c) => c.path === '/insights/research/job-1/retry'));
    await o.context.close();
  });

  test('go deeper: a refused start leaves a visible Retry, not a spinner', async () => {
    const state = { status: 'running', startFails: true }, msgs = [{ role: 'user', text: 'q' }, A('thin answer')];
    const o = await openOne(msgs, researchBox(state, () => msgs));
    await o.page.click('[data-a="insmore:1"]');
    await o.page.click('[data-a="insdeeper:1"]');
    await o.page.waitForSelector('.im.err');
    assert.match(await o.page.textContent('.im.err'), /Research didn.t start/);
    assert.equal(await o.page.$('.im.rj'), null);
    await o.context.close();
  });

  test('a message whose job failed shows Retry; a push route insights/<id> opens that chat', async () => {
    const state = { status: 'failed' }, msgs = [{ role: 'user', text: 'q' }, A('thin answer', { research: 'job-1' })];
    const o = await openOne(msgs, researchBox(state, () => msgs));
    await o.page.waitForSelector('.im.err');
    assert.match(await o.page.textContent('.im.err'), /Research failed/);
    await o.page.evaluate(() => { document.querySelector('[data-a="tab:home"]').click(); });
    await o.page.waitForSelector('.tabbar');
    await o.page.evaluate(() => window.cycleNative.route('insights/conv-0001-aaaa'));
    await o.page.waitForSelector('.im.a');
    assert.equal(await o.page.textContent('.im.a >> nth=0'), 'thin answer');
    await o.context.close();
  });

  test('a research chip whose job id the box no longer has shows failed with Retry, never Researching forever', async () => {
    const msgs = [{ role: 'user', text: 'q' }, A('thin answer', { research: 'job-gone' })];
    const o = await openOne(msgs, async (req) => {
      if (req.path === '/insights/conversations') return { status: 200, body: { conversations: [conv1()] } };
      if (req.path === '/insights/research') return { status: 200, body: { jobs: [] } }; // the box has no such job
      return { status: 200, body: full(conv1(), msgs) };
    });
    await o.page.waitForSelector('.im.err');
    assert.match(await o.page.textContent('.im.err'), /Research failed/);
    assert.match(await o.page.textContent('.im.err'), /Retry/);
    assert.equal(await o.page.$('.im.rj'), null);
    await o.context.close();
  });

  test('the thinking log saved on an answer survives the box refreshing the chat (the box keeps no log)', async () => {
    const th = { secs: 18, items: [{ k: 'tool', text: 'Reading your texts' }, { k: 'think', text: '**Weighing money**\n\nMost of them' }] };
    const msgs = [{ role: 'user', text: 'q' }, A('Mostly money.')];
    const o = await open({ convs: seedOne([msgs[0], A('Mostly money.', { thought: th })]), box: async (req) => (req.path === '/insights/conversations' ? { status: 200, body: { conversations: [conv1()] } } : { status: 200, body: full(conv1(), msgs) }) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.click('[data-a="go:inslist"]');
    await o.page.click('[data-a="insopen:conv-0001-aaaa"]');
    for (let i = 0; i < 50 && !o.boxCalls.some((c) => c.path === '/insights/conversations/conv-0001-aaaa'); i++) await new Promise((r) => setTimeout(r, 100));
    await new Promise((r) => setTimeout(r, 400)); // the refreshed copy has been stored and painted
    await o.page.waitForSelector('.thw .thc');
    assert.match(await o.page.textContent('.thw .thc'), /^Thought 18s · 2 steps$/);
    assert.ok(o.boxCalls.some((c) => c.method === 'GET' && c.path === '/insights/conversations/conv-0001-aaaa'), 'the box copy was fetched');
    await o.context.close();
  });

  test('a chat listed by the box but not cached on this phone is fetched when opened (push tap, other device)', async () => {
    const msgs = [{ role: 'user', text: 'q' }, A('from the box')];
    const o = await open({ box: async (req) => {
      if (req.path === '/insights/conversations') return { status: 200, body: { conversations: [conv1()] } };
      return { status: 200, body: full(conv1(), msgs) };
    } });
    await o.page.click('[data-a="tab:insights"]'); await o.page.click('[data-a="go:inslist"]');
    await o.page.click('[data-a="insopen:conv-0001-aaaa"]');
    await o.page.waitForSelector('.im.a');
    assert.equal(await o.page.textContent('.im.a'), 'from the box');
    await o.context.close();
  });
});

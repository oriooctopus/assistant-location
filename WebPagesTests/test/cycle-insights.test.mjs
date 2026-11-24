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
  async function open({ uid = OLIVER, box, convs } = {}) {
    const boxCalls = [];
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(NOW));
    await context.addInitScript(({ sd }) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: 'https://box.test' };
      if (!sessionStorage.getItem('seeded')) { sessionStorage.setItem('seeded', '1'); for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k])); }
    }, { sd: seed(uid, convs) });
    await context.route('**/cycle.css', (r) => r.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(new URL(r.request().url()).pathname.endsWith('couples') ? [COUPLE] : new URL(r.request().url()).pathname.endsWith('members') ? MEMBERS : []) }));
    await context.route('https://box.test/**', async (route) => {
      const req = route.request(), u = new URL(req.url()), rec = { method: req.method(), path: u.pathname, body: req.postData() ? JSON.parse(req.postData()) : null };
      boxCalls.push(rec);
      const r = box ? await box(rec) : undefined;
      if (!r) return route.abort();
      return route.fulfill({ status: r.status, contentType: 'application/json', body: JSON.stringify(r.body) });
    });
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.tabbar');
    return { context, page, boxCalls };
  }
  const tabs = (page) => page.$$eval('.tabbar .tab', (els) => els.map((e) => e.getAttribute('data-a')));
  const posts = (o) => o.boxCalls.filter((c) => c.method === 'POST' && c.path === '/insights');
  const answer = (text, mode = 'normal') => ({ status: 200, body: { conversation_id: 'x', answer: text, mode } });

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

  test('send: question shows at once, spinner in place while waiting, answer renders as markdown, body is right', async () => {
    let release;
    const gate = new Promise((r) => { release = r; });
    const o = await open({ box: async (req) => { if (req.method === 'POST' && req.path === '/insights') { await gate; return answer('Mostly **money**.\n- Aug 17: bill\n- Oct 25: party'); } } });
    await o.page.click('[data-a="tab:insights"]');
    assert.equal((await o.page.$$('[data-a^="inschip:"]')).length, 4);
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
    assert.deepEqual({ ...post.body, conversation_id: typeof post.body.conversation_id }, { conversation_id: 'string', message: 'what are our fights mostly about?', upset: false, retry: false });
    await o.context.close();
  });

  test('upset chip sends upset:true; a failed answer keeps the question with Retry, and Retry sends retry:true', async () => {
    let n = 0;
    const o = await open({ box: async (req) => { if (req.method === 'POST') return n++ ? answer('Leave the room.', 'upset') : { status: 502, body: { error: 'x' } }; } });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.click('[data-a="inschip:2"]');
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
});

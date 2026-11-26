// Insights message queue on the real page: text typed while an answer streams waits as a Queued bubble and goes out after the answer;
// Stop turns the queue into Held and the next send posts held + new text as one message. WebKit only, as cycle-insights.test.mjs.
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
function seed(uid) {
  const rows = Object.fromEntries(EMPTY.map((t) => [t, {}]));
  return {
    session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: uid, email: 'x@x.test' } },
    ['shared.' + uid]: { couple: COUPLE, members: MEMBERS, rows, cursors: {}, outbox: [], deadLetters: [] },
    ['priv.' + uid]: { fights: [], nudges: [], nudge_sends: [], prefs: {}, queued: [], drafts: {} },
  };
}

describe('insights queue (webkit)', { skip: !haveWebkit }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  // Every POST /insights answers with a stream the test feeds by hand (window.__sc); window.__posts holds the bodies.
  async function open() {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(NOW));
    await context.addInitScript(({ sd }) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: 'https://box.test', insAutoDelays: [] };
      if (!sessionStorage.getItem('seeded')) { sessionStorage.setItem('seeded', '1'); for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k])); }
      const real = window.fetch; window.__posts = [];
      window.fetch = (u, o) => {
        if (String(u).endsWith('/insights') && o && o.method === 'POST') {
          window.__posts.push(JSON.parse(o.body));
          return Promise.resolve(new Response(new ReadableStream({ start(c) { window.__sc = c; } }), { status: 200, headers: { 'Content-Type': 'text/event-stream' } }));
        }
        return real.call(window, u, o);
      };
    }, { sd: seed(OLIVER) });
    await context.route('**/cycle.css', (r) => r.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(new URL(r.request().url()).pathname.endsWith('couples') ? [COUPLE] : new URL(r.request().url()).pathname.endsWith('members') ? MEMBERS : []) }));
    const stops = [];
    await context.route('https://box.test/**', (route) => {
      const u = new URL(route.request().url());
      if (u.pathname === '/insights/stop') { stops.push(1); return route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' }); }
      return route.abort();
    });
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.tabbar');
    await page.click('[data-a="tab:insights"]');
    return { context, page, stops };
  }
  const feed = (page, ev) => page.evaluate((e) => window.__sc.enqueue(new TextEncoder().encode('data: ' + JSON.stringify(e) + '\n\n')), ev);
  const done = (page, answer, stopped = false) => feed(page, { t: 'done', conversation_id: 'x', answer, mode: 'normal', model: 'opus', stopped, vers: 1, sel: 0 });
  const posts = (page) => page.evaluate(() => window.__posts);
  const queued = (page) => page.$$eval('.im.u.q', (els) => els.map((e) => ({ tag: e.querySelector('.qtag')?.textContent, text: e.querySelector('div')?.innerText })));
  async function busyChat(page) {
    await page.fill('[data-d="ins_msg"]', 'first');
    await page.click('[data-a="inssend"]');
    await page.waitForSelector('.im.st.ld .spin');
  }
  async function queue(page, text) {
    await page.fill('[data-d="ins_msg"]', text);
    await page.click('[data-a="inssend"]');
    await page.waitForFunction((t) => [...document.querySelectorAll('.im.u.q')].some((e) => e.innerText.includes(t)), text);
  }

  test('queue while busy: Send beside Stop, queued bubble, box cleared, auto-sends after done and the rest follow', async () => {
    const o = await open();
    await busyChat(o.page);
    assert.ok(await o.page.$('[data-a="insstop"]'));
    assert.ok(await o.page.$('[data-a="inssend"].dis'));
    await o.page.fill('[data-d="ins_msg"]', 'second');
    assert.equal(await o.page.$('[data-a="inssend"].dis'), null, 'typing enables Send while busy');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.u.q');
    await queue(o.page, 'third');
    assert.equal(await o.page.inputValue('[data-d="ins_msg"]'), '');
    assert.deepEqual(await queued(o.page), [{ tag: 'Queued', text: 'second' }, { tag: 'Queued', text: 'third' }].map((x) => ({ tag: x.tag, text: x.text })));
    assert.equal((await posts(o.page)).length, 1);
    await done(o.page, 'A1');
    await o.page.waitForFunction(() => window.__posts.length === 2);
    assert.equal((await posts(o.page))[1].message, 'second');
    await o.page.waitForFunction(() => document.querySelectorAll('.im.u.q').length === 1);
    assert.deepEqual((await queued(o.page)).map((x) => x.text), ['third']);
    await done(o.page, 'A2');
    await o.page.waitForFunction(() => window.__posts.length === 3);
    assert.equal((await posts(o.page))[2].message, 'third');
    await o.page.waitForFunction(() => !document.querySelector('.im.u.q'));
    await o.context.close();
  });

  test('edit, delete and combine the queued bubbles', async () => {
    const o = await open();
    await busyChat(o.page);
    await queue(o.page, 'one'); await queue(o.page, 'two'); await queue(o.page, 'three');
    await o.page.click('.im.u.q >> nth=0');
    await o.page.fill('[data-d="ins_qedit"]', 'one edited');
    await o.page.click('[data-a^="insqsave:"]');
    await o.page.waitForSelector('.im.u.q:not(.ed)');
    assert.deepEqual((await queued(o.page)).map((x) => x.text), ['one edited', 'two', 'three']);
    await o.page.click('.im.u.q >> nth=1 >> .qx');
    await o.page.waitForFunction(() => document.querySelectorAll('.im.u.q').length === 2);
    assert.deepEqual((await queued(o.page)).map((x) => x.text), ['one edited', 'three']);
    await o.page.click('[data-a="insqcombine"]');
    await o.page.waitForFunction(() => document.querySelectorAll('.im.u.q').length === 1);
    assert.equal(await o.page.$('[data-a="insqcombine"]'), null);
    await done(o.page, 'A1');
    await o.page.waitForFunction(() => window.__posts.length === 2);
    assert.equal((await posts(o.page))[1].message, 'one edited\n\nthree');
    await o.context.close();
  });

  test('Stop keeps typed text as Held; nothing auto-sends; next send posts held + new text as one message; empty box sends held alone', async () => {
    const o = await open();
    await busyChat(o.page);
    await queue(o.page, 'queued early');
    await o.page.fill('[data-d="ins_msg"]', 'half typed');
    await o.page.click('[data-a="insstop"]');
    await o.page.waitForFunction(() => document.querySelectorAll('.im.u.q').length === 2);
    assert.deepEqual(await queued(o.page), [{ tag: 'Held', text: 'queued early' }, { tag: 'Held', text: 'half typed' }]);
    assert.equal(await o.page.inputValue('[data-d="ins_msg"]'), '');
    assert.equal(o.stops.length, 1);
    await done(o.page, 'partial', true);
    await o.page.click('[data-a^="insmore:"] >> nth=-1');
    await o.page.waitForSelector('.ia .stp');
    assert.equal((await posts(o.page)).length, 1, 'held items do not auto-send');
    assert.equal(await o.page.$('[data-a="inssend"].dis'), null, 'Send is enabled with held items and an empty box');
    await o.page.fill('[data-d="ins_msg"]', 'and this');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForFunction(() => window.__posts.length === 2);
    assert.equal((await posts(o.page))[1].message, 'queued early\n\nhalf typed\n\nand this');
    assert.equal(await o.page.$('.im.u.q'), null);
    // empty box + held: sends the held alone
    await done(o.page, 'A2');
    await o.page.waitForFunction(() => !document.querySelector('.stw'));
    await busyChat2(o.page);
    await o.context.close();
  });
  async function busyChat2(page) {
    await page.fill('[data-d="ins_msg"]', 'next');
    await page.click('[data-a="inssend"]');
    await page.waitForSelector('.im.st.ld .spin');
    await page.fill('[data-d="ins_msg"]', 'only held');
    await page.click('[data-a="insstop"]');
    await page.waitForSelector('.im.u.q');
    await done(page, 'p', true);
    await page.click('[data-a^="insmore:"] >> nth=-1');
    await page.waitForSelector('.ia .stp >> nth=-1');
    await page.click('[data-a="inssend"]');
    await page.waitForFunction(() => window.__posts.length === 4);
    assert.equal((await posts(page))[3].message, 'only held');
  }

  test('queue survives a reload', async () => {
    const o = await open();
    await busyChat(o.page);
    await queue(o.page, 'kept across reload');
    await o.page.waitForTimeout(500);
    await o.page.reload(); await o.page.waitForSelector('.tabbar');
    await o.page.click('[data-a="tab:insights"]');
    await o.page.click('[data-a="go:inslist"]');
    await o.page.click('.insrow .grow');
    await o.page.waitForSelector('.im.u.q');
    assert.deepEqual(await queued(o.page), [{ tag: 'Queued', text: 'kept across reload' }]);
    await o.context.close();
  });
});

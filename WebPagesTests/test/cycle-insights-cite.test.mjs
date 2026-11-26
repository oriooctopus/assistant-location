// Insights footnotes: a [^n] marker renders as a tappable superscript; the tap opens a sheet from stored data (no network) with the excerpt marked.
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

  test('footnote: superscript opens a sheet with label, file and the marked excerpt; works offline; an orphan marker is not tappable; reload keeps it', async () => {
    const SRC = [{ n: 1, label: 'Rita, Aug 27', file: 'Rita’s advice.md', excerpt: 'Tell yourself I won’t carry yesterday into today', context: 'Before line\nTell yourself I won’t carry yesterday into today\nAfter line', verified: true }];
    const o = await open({ box: async (req) => { if (req.method === 'POST' && req.path === '/insights') return answer('Try the reset[^1] and the other thing[^2].', 'normal', 'opus', { sources: SRC }); } });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'what helps');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('sup.fn[data-a^="cite:"]');
    assert.equal((await o.page.$$('sup.fn')).length, 1, 'the marker with no source is cut');
    assert.equal(await o.page.textContent('.im.a'), 'Try the reset1 and the other thing.');
    const posts0 = posts(o).length;
    await o.context.setOffline(true);
    await o.page.tap('sup.fn');
    await o.page.waitForSelector('.bs.cite');
    assert.equal(await o.page.textContent('.bs.cite h3'), 'Rita, Aug 27');
    assert.equal(await o.page.textContent('.bs.cite .cf'), 'Rita’s advice.md');
    assert.equal(await o.page.textContent('.bs.cite .cq mark'), SRC[0].excerpt);
    assert.equal(await o.page.textContent('.bs.cite .cq'), SRC[0].context);
    assert.equal(posts(o).length, posts0);
    await o.page.tap('.bs.cite .x');
    assert.equal(await o.page.$('.bs.cite'), null);
    await o.context.setOffline(false);
    await o.page.reload({ waitUntil: 'domcontentloaded' });
    await o.page.waitForSelector('sup.fn[data-a^="cite:"]');
    await o.context.close();
  });

  test('footnote phrase: [phrase][^n] is a dotted-underline tappable span that opens the sheet; an unsourced one is plain; a streaming partial is hidden', async () => {
    const SRC = [{ n: 1, label: 'Rita, Aug 27', file: 'Rita.md', excerpt: 'carry yesterday', context: 'a\ncarry yesterday\nb', verified: true }];
    const o = await open({ live: true, box: async () => ({ status: 200, body: { ok: true } }) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'q');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.st.ld .spin');
    const feed = (e) => o.page.evaluate((x) => window.__sc.enqueue(new TextEncoder().encode('data: ' + JSON.stringify(x) + '\n\n')), e);
    await feed({ t: 'start', mode: 'normal', model: 'opus' });
    await feed({ t: 'd', text: 'Say [carry yesterday][^1] then [half' });
    await o.page.waitForFunction(() => /Say carry yesterday then/.test(document.querySelector('.im.st')?.textContent || ''));
    assert.equal(await o.page.textContent('.im.st'), 'Say carry yesterday then');
    await feed({ t: 'done', conversation_id: 'x', answer: 'Say [carry yesterday][^1] then [plain one][^2].', mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0, sources: SRC });
    await o.page.waitForSelector('.cp[data-a^="cite:"]');
    assert.equal(await o.page.textContent('.im.a'), 'Say carry yesterday then plain one.');
    assert.equal((await o.page.$$('.cp')).length, 1);
    assert.match(await o.page.$eval('.cp', (e) => getComputedStyle(e).textDecorationLine + ' ' + getComputedStyle(e).textDecorationStyle), /underline dotted/);
    assert.ok((await o.page.$eval('.cp', (e) => parseFloat(getComputedStyle(e).paddingTop) * 2 + e.getBoundingClientRect().height)) >= 28);
    await o.page.tap('.cp');
    await o.page.waitForSelector('.bs.cite');
    assert.equal(await o.page.textContent('.bs.cite .cq mark'), 'carry yesterday');
    await o.context.close();
  });
});

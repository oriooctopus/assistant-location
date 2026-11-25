// Insights batch A on the real page: gem tiles and reorder, gem edit, learned rules/changelog/Rita, techniques and trials, thumbs.
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

describe('insights batch A (webkit)', { skip: !haveWebkit }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  // box(req) -> {status, body}; held answers: return a promise to keep the request open. Every box call lands in `boxCalls`.
  async function open({ uid = OLIVER, box, convs, live } = {}) {
    const boxCalls = [];
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(NOW));
    await context.addInitScript(({ sd }) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: 'https://box.test' };
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
  const answer = (text, mode = 'normal', model = 'opus', extra = {}) => ({ sse: [{ t: 'start', mode, model }, { t: 'd', text }, { t: 'done', conversation_id: 'x', answer: text, mode, model, stopped: false, vers: 1, sel: 0, ...extra }] });

  const GEMS = [
    { id: 'g1', name: 'I’m upset', icon: 'i-fight', instructions: 'calm', files: [], model: null, history: [{ at: '2026-11-20T10:00:00Z', what: 'created' }] },
    { id: 'g2', name: 'Get my mind off it', icon: 'i-moon', instructions: 'distract', files: [], model: 'sonnet', history: [{ at: '2026-11-20T10:00:00Z', what: 'created' }] },
    { id: 'g3', name: 'Money talk', icon: 'bolt', instructions: 'money', files: [], model: null, history: [] },
  ];
  const TECHS = [
    { id: 't1', name: 'Time-out with a return time', how: 'Say when you will be back.', source: 'Rita, Apr 28', tags: ['mid-fight'], status: 'untried', trials: [], history: [{ at: '2026-11-20T10:00:00Z', what: 'created' }] },
    { id: 't2', name: 'Plain sorry', how: 'Sorry for my part.', source: 'Fight patterns', tags: ['after-fight'], status: 'works', trials: [{ at: '2026-11-21T10:00:00Z', verdict: 'works', note: 'calmer' }], history: [] },
  ];
  const RULES = { global: [{ id: 'r1', text: 'Keep answers short.' }], 'gem:g2': [{ id: 'r2', text: 'One thing to do, not a list.' }] };
  const LOG = [{ id: 'l1', at: '2026-11-22T10:00:00Z', scope: 'global', kind: 'review', reasoning: 'He asked for shorter.', ops: [{ op: 'add', id: 'r1', after: 'Keep answers short.' }], reverted: false }];
  const LESSONS = [{ id: 'x1', at: '2026-11-22T09:00:00Z', scope: 'global', polarity: '-', text: 'too long' }];
  const ALL = { gems: GEMS, techniques: TECHS, rules: RULES, changelog: LOG, lessons: LESSONS, text: '# Rita\nTake space.', followup: null };
  const seedX = () => ({ convs: [], byId: {}, x: JSON.parse(JSON.stringify({ gems: GEMS, techniques: TECHS, rules: RULES, changelog: LOG, lessons: LESSONS, text: 'Rita', followup: null })) });
  // Routes every GET to its list; `mut(req)` handles writes and records through boxCalls.
  const boxFor = (mut) => async (req) => {
    if (req.method === 'GET') {
      const k = { '/insights/gems': 'gems', '/insights/techniques': 'techniques', '/insights/rules': 'rules', '/insights/lessons': 'lessons', '/insights/changelog': 'changelog', '/insights/rita': 'text', '/insights/followup': 'followup' }[req.path];
      return k ? { status: 200, body: { [k]: ALL[k] } } : undefined;
    }
    return mut ? mut(req) : undefined;
  };
  const writes = (o, m) => o.boxCalls.filter((c) => c.method === m);

  test('empty state: gem tiles above the chips; a tile starts a chat in that gem (gem in the POST, name in the header)', async () => {
    const o = await open({ convs: seedX(), box: boxFor((req) => (req.path === '/insights' ? answer('ok') : undefined)) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.waitForSelector('.gems .gt');
    assert.equal((await o.page.$$('.gems .gt')).length, 3);
    assert.ok(await o.page.evaluate(() => document.querySelector('.gems').compareDocumentPosition(document.querySelector('.chips')) & Node.DOCUMENT_POSITION_FOLLOWING), 'tiles come before chips');
    await o.page.click('[data-a="insgem:g2"]');
    assert.equal(await o.page.textContent('.insp .hd h2'), 'Get my mind off it');
    await o.page.fill('[data-d="ins_msg"]', 'help');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.a');
    assert.equal(posts(o)[0].body.gem, 'g2');
    assert.equal(posts(o)[0].body.model, 'sonnet');
    await o.context.close();
  });

  test('gem edit: the new name shows before the box answers, PATCH carries it; hold-drag reorders and PUTs the new order', async () => {
    let release; const gate = new Promise((r) => { release = r; });
    const o = await open({ convs: seedX(), box: boxFor(async (req) => { if (req.method === 'PATCH') { await gate; return { status: 200, body: { gem: { ...GEMS[0], name: 'Calm down' } } }; } if (req.method === 'PUT') return { status: 200, body: { gems: [] } }; }) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.click('[data-a="insto:gems"]');
    await o.page.waitForSelector('.gems.ed .gt');
    await o.page.click('[data-a="gemedit:g1"]');
    await o.page.fill('[data-d="gem_name"]', 'Calm down');
    await o.page.click('[data-a="gemsave"]');
    await o.page.waitForFunction(() => document.querySelector('.gems.ed .gt b').textContent === 'Calm down');
    release();
    // hold the first tile, drag it over the third, release
    const box = async (sel) => (await (await o.page.$(sel)).boundingBox());
    await o.page.waitForTimeout(150); // let the PATCH answer finish its re-render before measuring
    const a = await box('[data-gem="g1"]'), c = await box('[data-gem="g3"]');
    await o.page.mouse.move(a.x + a.width / 2, a.y + a.height / 2 + 10); await o.page.mouse.down();
    await o.page.waitForTimeout(500);
    await o.page.mouse.move(c.x + c.width / 2, c.y + c.height / 2, { steps: 6 });
    await o.page.mouse.up();
    await o.page.waitForFunction(() => document.querySelectorAll('.gems.ed .gt').length === 3);
    await o.page.waitForTimeout(200);
    assert.deepEqual(writes(o, 'PUT')[0].body.ids, ['g2', 'g3', 'g1']);
    assert.deepEqual(await o.page.$$eval('.gems.ed .gt', (els) => els.map((e) => e.getAttribute('data-gem'))), ['g2', 'g3', 'g1']);
    assert.equal(writes(o, 'PATCH')[0].body.name, 'Calm down');
    await o.context.close();
  });

  test('a quick tap on a gem tile still starts the chat (no accidental drag)', async () => {
    const o = await open({ convs: seedX(), box: boxFor() });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.click('[data-a="insto:gems"]');
    await o.page.click('[data-a="insgem:g3"]');
    assert.equal(await o.page.textContent('.insp .hd h2'), 'Money talk');
    assert.equal(writes(o, 'PUT').length, 0);
    await o.context.close();
  });

  test('learned: Rita read-only, rules per scope, edit and delete show first, changelog revert, lessons', async () => {
    const o = await open({ convs: seedX(), box: boxFor((req) => ({ status: 200, body: { rules: RULES } })) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.click('[data-a="insto:learned"]');
    await o.page.waitForSelector('.rt');
    assert.equal(await o.page.$('[data-a^="rita"] ~ .rita'), null);
    await o.page.click('[data-a="ritatog"]');
    assert.match(await o.page.textContent('.rita'), /Rita/);
    assert.equal(await o.page.$('.rita [data-a]'), null, 'no edit controls on Rita');
    assert.deepEqual(await o.page.$$eval('.rt', (e) => e.map((x) => x.textContent)), ['Keep answers short.', 'One thing to do, not a list.']);
    await o.page.click('[data-a="ruleedit:r1"]');
    await o.page.fill('[data-d="rule_edit"]', 'Keep answers very short.');
    await o.page.click('[data-a="rulesave:global|r1"]');
    await o.page.waitForFunction(() => document.querySelector('.rt').textContent === 'Keep answers very short.');
    await o.page.click('[data-a="ruledel:gem:g2|r2"]');
    await o.page.waitForFunction(() => document.querySelectorAll('.rt').length === 1);
    await o.page.click('[data-a="logrev:l1"]');
    await o.page.waitForFunction(() => /reverted/.test(document.querySelector('.lg .meta').textContent));
    const w = o.boxCalls.filter((c) => c.method !== 'GET');
    assert.deepEqual(w.map((c) => c.method + ' ' + c.path + c.query), ['PATCH /insights/rules/r1?scope=global', 'DELETE /insights/rules/r2?scope=gem%3Ag2', 'POST /insights/changelog/l1/revert']);
    assert.equal(w[0].body.text, 'Keep answers very short.');
    assert.match(await o.page.textContent('.insp'), /too long/);
    await o.context.close();
  });

  test('techniques: status filter, detail, a trial verdict changes the status before the box answers and POSTs it with the note', async () => {
    let release; const gate = new Promise((r) => { release = r; });
    const o = await open({ convs: seedX(), box: boxFor(async (req) => { if (req.path === '/insights/techniques/t1/trial') { await gate; return { status: 200, body: { technique: { ...TECHS[0], status: 'doesnt' } } }; } }) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.click('[data-a="insto:techs"]');
    await o.page.waitForSelector('[data-a^="techopen:"]');
    assert.equal((await o.page.$$('[data-a^="techopen:"]')).length, 2);
    // Each filter set is one scrolling line, never wrapped chips (five wrapped lines read as cramped).
    const fh = await o.page.$$eval('.insmenu.techf', (e) => e.map((x) => x.getBoundingClientRect().height));
    assert.equal(fh.length, 2); assert.ok(fh.every((h) => h < 50), 'filter rows wrapped: ' + fh);
    await o.page.click('[data-a="techfs:works"]');
    assert.deepEqual(await o.page.$$eval('[data-a^="techopen:"]', (e) => e.map((x) => x.getAttribute('data-a'))), ['techopen:t2']);
    await o.page.click('[data-a="techfs:"]'); await o.page.click('[data-a="techft:mid-fight"]');
    assert.equal((await o.page.$$('[data-a^="techopen:"]')).length, 1);
    await o.page.click('[data-a="techopen:t1"]');
    await o.page.fill('[data-d="tech_note"]', 'she left the room');
    await o.page.click('[data-a="techtrial:doesnt"]');
    await o.page.waitForFunction(() => /Doesn.t work/.test(document.querySelector('.st').textContent));
    release();
    await o.page.waitForFunction(() => document.querySelectorAll('.insp .row.hist').length >= 2);
    const tr = writes(o, 'POST')[0];
    assert.equal(tr.path, '/insights/techniques/t1/trial');
    assert.deepEqual(tr.body, { verdict: 'doesnt', note: 'she left the room' });
    await o.context.close();
  });

  test('follow-up card for an open experiment: Worked clears it and posts the verdict', async () => {
    const x = seedX(); x.x.followup = { id: 't1', name: 'Time-out with a return time', since: '2026-11-20T10:00:00Z' }; x.x.techniques[0].status = 'trying';
    const o = await open({ convs: x, box: async (req) => { if (req.method === 'GET') return req.path === '/insights/followup' ? { status: 200, body: { followup: { id: 't1', name: 'Time-out with a return time', since: 'x' } } } : boxFor()(req); return { status: 200, body: { technique: { ...TECHS[0], status: 'works' } } }; } });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.waitForSelector('.fu');
    assert.match(await o.page.textContent('.fu'), /Time-out/);
    await o.page.click('[data-a="insfu:works"]');
    await o.page.waitForFunction(() => !document.querySelector('.fu'));
    assert.deepEqual(writes(o, 'POST')[0].body, { verdict: 'works', note: '' });
    await o.context.close();
  });

  test('thumbs: Bad plus a note posts the feedback with the note; the thumb shows at once', async () => {
    const conv = { id: 'cv1', title: 'hi', created_at: NOW, updated_at: NOW, model: 'opus', messages: [{ role: 'user', text: 'q', at: NOW }, { role: 'assistant', text: 'a long answer', model: 'opus', at: NOW }] };
    const x = seedX(); x.convs = [{ id: 'cv1', title: 'hi', updated_at: NOW, model: 'opus' }]; x.byId = { cv1: conv };
    const o = await open({ convs: x, box: boxFor((req) => (req.path === '/insights/feedback' ? { status: 200, body: { ok: true } } : undefined)) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.click('[data-a="go:inslist"]'); await o.page.click('[data-a="insopen:cv1"]');
    await o.page.waitForSelector('.im.a');
    await o.page.click('[data-a="insfb:1:-"]');
    await o.page.fill('[data-d="fb_note"]', 'too long, one thing');
    await o.page.click('[data-a="insfbsend"]');
    await o.page.waitForSelector('[data-a="insfb:1:-"].on');
    assert.deepEqual(writes(o, 'POST')[0].body, { conversation_id: 'cv1', index: 1, polarity: '-', note: 'too long, one thing' });
    await o.context.close();
  });
});

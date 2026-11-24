// Insights generative-UI blocks on the real page (WebKit): charts filled from the box's datasets, a checklist whose ticks persist, technique
// card buttons, error chips, and the Send tap surviving a re-render. Same harness as cycle-insights.test.mjs.
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

describe('insights blocks (webkit)', { skip: !haveWebkit }, () => {
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
  const tabs = (page) => page.$$eval('.tabbar .tab', (els) => els.map((e) => e.getAttribute('data-a')));
  const posts = (o) => o.boxCalls.filter((c) => c.method === 'POST' && c.path === '/insights');
  const answer = (text, mode = 'normal', model = 'opus', extra = {}) => ({ sse: [{ t: 'start', mode, model }, { t: 'd', text }, { t: 'done', conversation_id: 'x', answer: text, mode, model, stopped: false, vers: 1, sel: 0, ...extra }] });

  const fence = (o) => '```ui\n' + JSON.stringify(o) + '\n```';
  const DATASETS = { generated_at: NOW, errors: {}, datasets: {
    fights_by_month: { id: 'fights_by_month', title: 'Fights per month', shape: 'series', unit: 'fights', points: [{ x: '2026-09', label: "Sep '26", y: 4 }, { x: '2026-10', label: "Oct '26", y: 9 }, { x: '2026-11', label: "Nov '26", y: 2 }] },
    fights_by_day: { id: 'fights_by_day', title: 'Fights by day', shape: 'days', unit: 'fights', days: [{ day: '2026-11-20', y: 3 }] } } };
  const withData = (inner) => async (req) => (req.method === 'GET' && req.path === '/insights/datasets' ? { status: 200, body: DATASETS } : inner(req));

  test('"show me fights by month": a real chart whose bars equal the box dataset; tap reads a point; Table view lists the same numbers', async () => {
    const o = await open({ box: withData(async (req) => { if (req.method === 'POST' && req.path === '/insights') return answer('Here it is.\n' + fence({ type: 'chart', dataset: 'fights_by_month', kind: 'bar' }) + '\nBusiest in October.'); }) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'show me fights by month');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.bkbar');
    assert.deepEqual(await o.page.$$eval('.bkbar', (b) => b.map((x) => +x.dataset.v)), [4, 9, 2]);
    assert.match(await o.page.textContent('.bkro'), /Nov '26: 2 fights/);
    await o.page.click('.bkhit >> nth=1', { force: true });
    assert.match(await o.page.textContent('.bkro'), /Oct '26: 9 fights/);
    await o.page.click('[data-a^="bktab:"]');
    assert.match(await o.page.textContent('.bktbl, .bkchart table'), /Oct '26\s*9/);
    assert.equal(await o.page.$('.bkerr'), null);
    await o.context.close();
  });

  test('a block the schema rejects shows an error chip with the raw JSON (and no chart)', async () => {
    const o = await open({ box: withData(async (req) => { if (req.method === 'POST' && req.path === '/insights') return answer(fence({ type: 'chart', dataset: 'fights_by_month', values: [1, 2] })); }) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'chart');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.bkerr');
    assert.match(await o.page.textContent('.bkerr'), /unknown key "values"[\s\S]*"values":\[1,2\]/);
    assert.equal(await o.page.$('.bkbar'), null);
    await o.context.close();
  });

  test('checklist: a tick shows on the tap, is PATCHed as bstate, and is still ticked after a reload and when the box copy is loaded fresh', async () => {
    const cl = answer(fence({ type: 'checklist', title: 'Tonight', items: ['Phone away at 9', 'Ask once'] }));
    const o = await open({ box: withData(async (req) => { if (req.method === 'POST' && req.path === '/insights') return cl; if (req.method === 'PATCH') return { status: 200, body: {} }; }) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'give me a checklist for tonight');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.bkck');
    await o.page.click('.bkck >> nth=1');
    assert.equal(await o.page.getAttribute('.bkck >> nth=1', 'aria-checked'), 'true');
    await o.page.waitForFunction(() => true);
    await o.page.waitForTimeout(300);
    const patch = o.boxCalls.find((c) => c.method === 'PATCH');
    assert.deepEqual(patch.body, { bstate: { index: 1, ver: 0, block: 0, key: 'i1', value: true } });
    await o.page.reload(); await o.page.waitForSelector('.tabbar');
    await o.page.click('[data-a="tab:insights"]'); await o.page.click('[data-a="insnew"]').catch(() => {});
    await o.page.click('[data-a="go:inslist"]'); await o.page.click('.insrow .grow');
    await o.page.waitForSelector('.bkck');
    assert.equal(await o.page.getAttribute('.bkck >> nth=1', 'aria-checked'), 'true');
    assert.equal(await o.page.getAttribute('.bkck >> nth=0', 'aria-checked'), 'false');
    await o.context.close();
  });

  test('checklist: ticks stored on the box come back when the chat is opened fresh on another device', async () => {
    const id = 'conv-0001-aaaa', text = fence({ type: 'checklist', items: ['a', 'b'] });
    const convs = { convs: [{ id, title: 'Tonight', updated_at: '2026-11-23T14:00:00Z' }], byId: { [id]: { id, title: 'Tonight', updated_at: '2026-11-23T14:00:00Z', messages: [{ role: 'user', text: 'q' }, { role: 'assistant', text: text, mode: 'normal' }] } } };
    const server = { id, title: 'Tonight', updated_at: '2026-11-23T14:00:00Z', messages: [{ role: 'user', text: 'q' }, { role: 'assistant', text: text, mode: 'normal', bstate: { '0:0:i0': true } }] };
    const o = await open({ convs, box: withData(async (req) => { if (req.method === 'GET' && req.path === `/insights/conversations/${id}`) return { status: 200, body: server }; if (req.method === 'GET') return { status: 200, body: { conversations: convs.convs } }; }) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.click('[data-a="go:inslist"]'); await o.page.click('.insrow .grow');
    await o.page.waitForFunction(() => document.querySelector('.bkck') && document.querySelector('.bkck').getAttribute('aria-checked') === 'true');
    await o.context.close();
  });

  const techAnswer = answer(fence({ type: 'technique', id: 'time-out', name: 'Time-out', how: 'Leave for 20 minutes', status: 'untried' }));
  test('technique card: Worked posts the verdict to the trial endpoint and shows the status', async () => {
    const o = await open({ box: withData(async (req) => { if (req.method === 'POST' && req.path === '/insights') return techAnswer; if (req.method === 'POST' && req.path.endsWith('/trial')) return { status: 200, body: { technique: { id: 'time-out', status: 'works' } } }; if (req.method === 'PATCH') return { status: 200, body: {} }; }) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.fill('[data-d="ins_msg"]', 'a technique'); await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.bktc');
    await o.page.click('[data-a$=":works"]');
    await o.page.waitForSelector('.bkpill.s-works');
    const t = o.boxCalls.find((c) => c.path === '/insights/techniques/time-out/trial');
    assert.deepEqual(t.body, { verdict: 'works' });
    assert.ok(o.boxCalls.some((c) => c.method === 'PATCH' && c.body.bstate.key === 'status' && c.body.bstate.value === 'works'));
    await o.context.close();
  });
  test('technique card: when the box refuses the trial the status goes back and the error is on the card', async () => {
    const o = await open({ box: withData(async (req) => { if (req.method === 'POST' && req.path === '/insights') return techAnswer; if (req.path.endsWith('/trial')) return { status: 404, body: { error: 'nope' } }; }) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.fill('[data-d="ins_msg"]', 'a technique'); await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.bktc');
    await o.page.click('[data-a$=":doesnt"]');
    await o.page.waitForSelector('.bkfail');
    assert.match(await o.page.textContent('.bkfail'), /HTTP 404/);
    assert.ok(await o.page.$('.bkpill.s-untried'));
    assert.equal(o.boxCalls.some((c) => c.method === 'PATCH'), false);
    await o.context.close();
  });

  test('streaming: an open ui fence is a skeleton, the block appears when the fence closes', async () => {
    const o = await open({ live: true, box: withData(async () => undefined) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.fill('[data-d="ins_msg"]', 'chart'); await o.page.click('[data-a="inssend"]');
    await o.page.waitForFunction(() => window.__sc);
    const ev = (e) => o.page.evaluate((e) => window.__sc.enqueue(new TextEncoder().encode('data: ' + JSON.stringify(e) + '\n\n')), e);
    await ev({ t: 'start', mode: 'normal', model: 'opus' });
    await ev({ t: 'd', text: 'Look:\n```ui\n{"type":"chart","dataset":"fights_by_' });
    await o.page.waitForSelector('.im.st .bksk');
    assert.equal(await o.page.$('.bkerr'), null);
    await ev({ t: 'd', text: 'month"}\n```\n' });
    await o.page.waitForSelector('.im.st .bkbar');
    await o.context.close();
  });

  test('send survives a re-render between pointerdown and pointerup (the lost Send tap)', async () => {
    const o = await open({ box: withData(async (req) => { if (req.method === 'POST' && req.path === '/insights') return answer('ok'); }) });
    await o.page.click('[data-a="tab:insights"]');
    await o.page.fill('[data-d="ins_msg"]', 'hello there');
    const b = await o.page.locator('[data-a="inssend"]').boundingBox();
    await o.page.mouse.move(b.x + b.width / 2, b.y + b.height / 2);
    await o.page.mouse.down();
    await o.page.evaluate(() => window.dispatchEvent(new Event('online'))); // any render (the title event used to cause one): the pressed button is replaced under the finger
    await o.page.mouse.up();
    await o.page.waitForSelector('.im.a');
    assert.equal(posts(o).length, 1);
    assert.equal(posts(o)[0].body.message, 'hello there');
    await o.context.close();
  });

  test('a title event after the answer does not re-render the open chat', async () => {
    const o = await open({ live: true, box: withData(async () => undefined) });
    await o.page.click('[data-a="tab:insights"]'); await o.page.fill('[data-d="ins_msg"]', 'hi'); await o.page.click('[data-a="inssend"]');
    await o.page.waitForFunction(() => window.__sc);
    const ev = (e) => o.page.evaluate((e) => window.__sc.enqueue(new TextEncoder().encode('data: ' + JSON.stringify(e) + '\n\n')), e);
    await ev({ t: 'done', conversation_id: 'x', answer: 'ok', mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0 });
    await o.page.waitForSelector('.im.a');
    await o.page.evaluate(() => { document.querySelector('[data-a="inssend"]').__mark = 1; });
    await ev({ t: 'title', title: 'Named' });
    await o.page.waitForTimeout(400);
    assert.equal(await o.page.evaluate(() => document.querySelector('[data-a="inssend"]').__mark), 1);
    await o.context.close();
  });
});

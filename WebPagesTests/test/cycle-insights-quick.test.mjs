// Chat quick add (Oliver-only): the header Add opens a composer; Save queues {key,text,ts} before any network call, shows Added on the same frame,
// an offline note stays queued and drains on online, a failure shows Retry with the same key, and the unsent text survives a reload. The box (/insights/quick) is faked.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web');
const URL_ = 'https://app.test/index.html';
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' };
const CSS = fs.readFileSync(path.join(WEB, 'cycle.css'), 'utf8') + '\n#fx{display:none}';
const UID = '78b76b33-e11c-4491-baa4-28aa38bd17c6'; // Oliver: the only account with an Insights tab
const seed = () => ({
  session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } },
  ['shared.' + UID]: {
    couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [{ user_id: UID, name: 'Oliver', checkin_time: '21:00', hits_self: false }, { user_id: 'u-her', name: 'Esme', checkin_time: '21:00', hits_self: true }],
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, rewards: {}, redemptions: {}, fight_markers: {}, fight_notes: {} }, cursors: {}, outbox: [],
  },
  ['priv.' + UID]: { fights: [], affirmations: [], prefs: {} },
});

let browser;
before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { await browser.close(); });

// box state, reset per open(): said = what /transcribe returns ('' = 422), tstatus, delay, net (false = the request fails like offline), asks = POST /insights bodies,
// tts = texts sent for speech, ttsFail, jr = POST /insights/journal bodies, jrStatus
let box;
async function open(opts = {}) {
  box = { said: '', tstatus: 200, delay: 0, net: true, asks: [], tts: [], uploads: 0, ttsFail: false, answer: null, jr: [], jrStatus: 200, qk: [], qkStatus: 200 };
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript((sd) => {
    window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: 'https://box.test', insAutoDelays: [] };
    if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    Object.defineProperty(Navigator.prototype, 'onLine', { get() { return !window.__off; }, configurable: true });
    window.__bridge = []; window.__played = []; window.__paused = 0;
    // The recorded clip is the same bytes every time; the shell keeps it on disk under an id until speech.ack.
    window.webkit = { messageHandlers: { cycle: { postMessage: ({ id, cmd, args }) => {
      window.__bridge.push(cmd);
      setTimeout(() => {
        let r = null;
        if (cmd === 'store.get') r = localStorage.getItem('cycle:' + args.key);
        else if (cmd === 'store.set') localStorage.setItem('cycle:' + args.key, args.value);
        else if (cmd === 'store.keys') r = Object.keys(localStorage).filter((k) => k.startsWith('cycle:' + args.prefix)).map((k) => k.slice(6));
        else if (cmd === 'notify.status') r = 'granted';
        else if (cmd === 'lock.get') r = false;
        else if (cmd === 'speech.stop') { r = { audio: 'QVVESU8=', mime: 'audio/mp4', id: 'n-' + Math.random().toString(36).slice(2) }; localStorage.setItem('mock:disk', JSON.stringify([...JSON.parse(localStorage.getItem('mock:disk') || '[]'), r])); }
        else if (cmd === 'app.info') r = { shell: 4, native: 0 };
        else if (cmd === 'speech.ack') localStorage.setItem('mock:disk', JSON.stringify(JSON.parse(localStorage.getItem('mock:disk') || '[]').filter((c) => c.id !== args.id)));
        else if (cmd === 'speech.orphans') r = JSON.parse(localStorage.getItem('mock:disk') || '[]');
        window.__cycleReply(id, r, null);
      }, 0);
    } } } };
    // A fake Audio: "plays" for mock:playms, then ends. The silent unlock clip is not counted as speech.
    window.Audio = class { constructor() { this.src = ''; } play() { if (this.src.startsWith('data:')) return Promise.resolve(); window.__played.push(this.src); this.t = setTimeout(() => this.onended && this.onended(), +localStorage.getItem('mock:playms') || 30); return Promise.resolve(); } pause() { clearTimeout(this.t); window.__paused++; } };
    // POST /insights answers a stream the test feeds by hand (window.__feed), so a half-finished answer can be looked at.
    const real = window.fetch;
    window.fetch = (u, o) => {
      if (String(u).endsWith('/insights') && o && o.method === 'POST' && localStorage.getItem('mock:live')) {
        window.__posts = (window.__posts || []).concat(JSON.parse(o.body));
        return Promise.resolve(new Response(new ReadableStream({ start(c) { window.__sc = c; } }), { status: 200, headers: { 'Content-Type': 'text/event-stream' } }));
      }
      return real.call(window, u, o);
    };
    window.__feed = (ev) => { window.__sc.enqueue(new TextEncoder().encode('data: ' + JSON.stringify(ev) + '\n\n')); if (ev.t === 'done') window.__sc.close(); }; // the box ends the stream after done
  }, seed());
  if (opts.playms) await context.addInitScript((m) => localStorage.setItem('mock:playms', String(m)), opts.playms);
  if (opts.live) await context.addInitScript(() => localStorage.setItem('mock:live', '1'));
  await context.route('https://app.test/**', (route) => {
    const f = path.join(WEB, new URL(route.request().url()).pathname);
    if (!fs.existsSync(f)) return route.fulfill({ status: 404, body: '' });
    return route.fulfill({ contentType: MIME[path.extname(f)] || 'application/octet-stream', body: fs.readFileSync(f) });
  });
  await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
  await context.route('https://x.test/**', (route) => route.abort());
  await context.route('https://box.test/**', async (route) => {
    const req = route.request(), p = new URL(req.url()).pathname;
    if (p === '/transcribe') {
      box.uploads++;
      if (box.delay) await new Promise((r) => setTimeout(r, box.delay));
      if (!box.net) return route.abort();
      if (box.tstatus >= 500) return route.fulfill({ status: box.tstatus, contentType: 'application/json', body: '{"error":"down"}' });
      return box.said ? route.fulfill({ contentType: 'application/json', body: JSON.stringify({ text: box.said }) }) : route.fulfill({ status: 422, contentType: 'application/json', body: '{"error":"no speech"}' });
    }
    if (p === '/insights/journal') {
      if (!box.net) return route.abort();
      box.jr.push(JSON.parse(req.postData()));
      return route.fulfill({ status: box.jrStatus, contentType: 'application/json', body: '{"saved":"x.txt"}' });
    }
    if (p === '/insights/quick') {
      if (!box.net) return route.abort();
      box.qk.push(JSON.parse(req.postData()));
      return route.fulfill({ status: box.qkStatus, contentType: 'application/json', body: '{"saved":true}' });
    }
    if (p === '/insights/tts') {
      box.tts.push(JSON.parse(req.postData()).text);
      if (box.ttsFail) return route.fulfill({ status: 502, contentType: 'application/json', body: '{"error":"x"}' });
      return route.fulfill({ status: 200, contentType: 'audio/mpeg', body: Buffer.from('ID3fake') });
    }
    if (p === '/insights' && req.method() === 'POST') {
      box.asks.push(JSON.parse(req.postData()));
      const text = box.answer || 'Mostly money.';
      return route.fulfill({ status: 200, contentType: 'text/event-stream', body: [{ t: 'start', mode: 'normal', model: 'opus' }, { t: 'd', text }, { t: 'done', conversation_id: 'x', answer: text, mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0 }].map((e) => 'data: ' + JSON.stringify(e) + '\n\n').join('') });
    }
    if (p === '/insights/conversations') return route.fulfill({ contentType: 'application/json', body: '{"conversations":[]}' });
    return route.abort(); // the rest of /insights (gems, followup, lists) and /backup: refused as when offline
  });
  const page = await context.newPage();
  page.on('pageerror', (e) => { throw e; });
  await page.goto(URL_, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.tabbar');
  await page.click('[data-a="tab:insights"]');
  await page.waitForSelector('.insbar');
  return { context, page };
}
const bridge = (page, cmd) => page.evaluate((c) => window.__bridge.filter((x) => x === c).length, cmd);
const clips = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('cycle:voiceclips') || '[]').length);
const ask = (page) => page.inputValue('[data-d="ins_msg"]');
async function dictate(page) { // tap the Ask mic to start, tap again to stop
  await page.click('.insbar .mic');
  await page.waitForSelector('.insbar .mic.rec');
  await page.click('.insbar .mic');
}
// A relaunch on the same storage: the old page closes, a new one boots from what it saved.
async function relaunch(context, page) {
  const next = await context.newPage();
  next.on('pageerror', (e) => { throw e; });
  await page.close();
  await next.goto(URL_, { waitUntil: 'domcontentloaded' });
  return next;
}


async function send(page, text) {
  await page.fill('[data-d="ins_msg"]', text);
  await page.click('[data-a="inssend"]');
  await page.waitForSelector('.im.u');
  await page.waitForSelector('.im.a');
}


test('quick add: Save shows Added at once with the network blocked, the note is in the durable queue before any request, and it drains on online with {key,text,ts}', async () => {
  const { context, page } = await open();
  box.net = false; await page.evaluate(() => { window.__off = true; });
  await page.click('[data-a="insquick"]');
  await page.fill('[data-d="quick_note"]', 'went quiet after the call');
  if (process.env.QUICK_SHOT) await page.screenshot({ path: process.env.QUICK_SHOT + '-composer.png' });
  await page.click('[data-a="insquicksave"]');
  if (process.env.QUICK_SHOT) await page.screenshot({ path: process.env.QUICK_SHOT + '-added.png' });
  assert.equal(await page.$('[data-d="quick_note"]'), null, 'composer closed on the tap');
  assert.equal((await page.textContent('.ign-toast')).trim(), 'Added');
  const q = await page.evaluate(() => JSON.stringify(Object.keys(localStorage).filter((k) => k.startsWith('cycle:ins')).map((k) => localStorage.getItem(k))));
  assert.match(q, /went quiet after the call/, 'queued on disk');
  assert.equal(box.qk.length, 0, 'nothing sent while offline');
  box.net = true; await page.evaluate(() => { window.__off = false; window.dispatchEvent(new Event('online')); });
  await page.waitForFunction(() => true); await page.waitForTimeout(500);
  assert.equal(box.qk.length, 1);
  assert.equal(box.qk[0].text, 'went quiet after the call'); assert.match(box.qk[0].key, /^qk-[\w-]{8,}$/); assert.equal(typeof box.qk[0].ts, 'number');
  await page.click('[data-a="tab:todo"]'); await page.click('[data-a="tab:insights"]'); await page.waitForTimeout(400);
  assert.equal(box.qk.length, 1, 'drained: nothing replays');
  await context.close();
});

test('quick add: a failed send stays queued with Retry, Retry resends the same key, and an empty note saves nothing', async () => {
  const { context, page } = await open();
  await page.click('[data-a="insquick"]');
  await page.click('[data-a="insquicksave"]');
  assert.ok(await page.$('[data-d="quick_note"]'), 'empty Save leaves the composer open');
  assert.equal(box.qk.length, 0);
  box.qkStatus = 502;
  await page.fill('[data-d="quick_note"]', 'asked about my day');
  await page.click('[data-a="insquicksave"]');
  await page.waitForSelector('.im.err[data-a="insredo"]');
  const key = box.qk[0].key;
  box.qkStatus = 200;
  await page.click('[data-a="insredo"]');
  await page.waitForFunction(() => !document.querySelector('[data-a="insredo"]'));
  assert.equal(box.qk.length, 2); assert.equal(box.qk[1].key, key, 'same key on every resend');
  await context.close();
});

test('quick add: the unsent text survives a reload and reopens in the composer', async () => {
  const { context, page } = await open();
  await page.click('[data-a="insquick"]');
  await page.fill('[data-d="quick_note"]', 'half a thought');
  await page.waitForTimeout(300);
  const next = await relaunch(context, page);
  await next.waitForSelector('.tabbar'); await next.click('[data-a="tab:insights"]');
  await next.waitForSelector('[data-d="quick_note"]');
  assert.equal(await next.inputValue('[data-d="quick_note"]'), 'half a thought');
  assert.equal(box.qk.length, 0);
  await context.close();
});

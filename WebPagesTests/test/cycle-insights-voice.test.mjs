// Insights voice: the dictation mic in the Ask bar (clip kept until its words are placed, never auto-sent, spinner, the three loss windows) and
// voice mode (turn, spoken answer sentence by sentence while it streams, ui blocks skipped, tap interrupts, hands-free relisten, failure Retry).
// The shell (recording, bridge), the Audio element and the box (/transcribe, /insights, /insights/tts) are faked.
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
// tts = texts sent for speech, ttsFail
let box;
async function open(opts = {}) {
  box = { said: '', tstatus: 200, delay: 0, net: true, asks: [], tts: [], uploads: 0, ttsFail: false, answer: null };
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
  console.log('PROBE', JSON.stringify(await page.evaluate(() => [window.__h, document.querySelector('.scr').scrollTop, document.querySelector('.scr').scrollHeight, document.querySelector('.scr').clientHeight])));
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

test('dictation: the mic sits in the Ask bar, shows a spinner until the transcript lands, fills the box as a draft and sends nothing', async () => {
  const { context, page } = await open();
  box.said = 'why do we fight about money'; box.delay = 600;
  await dictate(page);
  await page.waitForSelector('.insbar .mic.busy .spin');
  assert.equal(await page.getAttribute('.insbar .mic', 'role'), 'progressbar');
  await page.waitForFunction(() => document.querySelector('[data-d="ins_msg"]').value.length > 0);
  assert.equal(await ask(page), 'why do we fight about money');
  assert.equal(await page.$('.insbar .mic.busy'), null);
  assert.equal(box.asks.length, 0, 'never auto-sent');
  assert.equal(await clips(page), 0, 'the clip is dropped once its words are placed');
  assert.equal(await bridge(page, 'speech.ack'), 1);
  await context.close();
});

test('loss window, reload mid-upload: the kept clip is transcribed on the next boot and its words wait in the Ask box', async () => {
  const { context, page } = await open();
  box.said = 'after the reload'; box.delay = 1500;
  await dictate(page);
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:voiceclips') || '[]').length === 1);
  box.delay = 0;
  const next = await relaunch(context, page);
  await next.waitForSelector('.tabbar');
  await next.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:voiceclips') || '[]').length === 0);
  await next.click('[data-a="tab:insights"]');
  await next.waitForFunction(() => document.querySelector('[data-d="ins_msg"]').value === 'after the reload');
  assert.equal(box.asks.length, 0);
  await context.close();
});

test('loss window, navigate away mid-upload: the words go into the Ask draft, not into the surface he is on', async () => {
  const { context, page } = await open();
  box.said = 'said while leaving'; box.delay = 700;
  await dictate(page);
  await page.waitForSelector('.insbar .mic.busy');
  await page.click('[data-a="tab:home"]');
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:voiceclips') || '[]').length === 0, null, { timeout: 8000 });
  await page.click('[data-a="tab:insights"]');
  await page.waitForFunction(() => document.querySelector('[data-d="ins_msg"]').value === 'said while leaving');
  assert.equal(box.asks.length, 0);
  await context.close();
});

test('loss window, 5xx and offline: the clip stays with a visible Retry; Retry places the words in the Ask box', async () => {
  const { context, page } = await open();
  box.said = 'second try'; box.tstatus = 503;
  await dictate(page);
  await page.waitForSelector('.vclip [data-a^="clipretry:"]');
  assert.equal(await clips(page), 1);
  assert.equal(await ask(page), '');
  box.tstatus = 200; box.net = false; // offline now: Retry fails, the clip is still there
  await page.click('[data-a^="clipretry:"]');
  await page.waitForFunction(() => document.querySelector('.err, .toast, [role=alert]') || true);
  await page.waitForSelector('.vclip [data-a^="clipretry:"]');
  assert.equal(await clips(page), 1);
  box.net = true;
  await page.click('[data-a^="clipretry:"]');
  await page.waitForFunction(() => document.querySelector('[data-d="ins_msg"]').value === 'second try');
  assert.equal(await page.$('.vclip'), null);
  assert.equal(await clips(page), 0);
  assert.equal(box.asks.length, 0);
  await context.close();
});

// Voice mode with a hand-fed stream.
const feed = (page, ev) => page.evaluate((e) => window.__feed(e), ev);
async function voiceTurn(page, said) {
  box.said = said;
  await page.click('[data-a="vmopen"]');
  await page.waitForSelector('.tkglow[data-state="listening"]');
  await page.evaluate(() => window.cycleNative.speechSilence()); // the shell hears him stop talking
}

test('voice mode: his words go out as a chat message, the answer is spoken sentence by sentence while it streams, ui blocks are never spoken, then the mic reopens', async () => {
  const { context, page } = await open({ live: true });
  await voiceTurn(page, 'what are our fights mostly about');
  await page.waitForFunction(() => (window.__posts || []).length === 1);
  assert.equal(await page.evaluate(() => window.__posts[0].message), 'what are our fights mostly about');
  assert.equal(await clips(page), 0, 'the clip goes once the question is saved in the chat');
  await feed(page, { t: 'start', mode: 'normal', model: 'opus' });
  await feed(page, { t: 'd', text: 'Mostly money and plans, honestly. Half the fights start with a bill. ' });
  await page.waitForFunction(() => window.__played.length >= 1); // spoken before the answer is complete
  assert.equal(await page.$('.tkglow[data-state="listening"]'), null);
  const mid = box.tts.length;
  await feed(page, { t: 'd', text: '\n```ui\n{"type":"chart","title":"Fights by topic"}\n```\nTry one thing first: ask before you fix.' });
  const full = 'Mostly money and plans, honestly. Half the fights start with a bill. \n```ui\n{"type":"chart","title":"Fights by topic"}\n```\nTry one thing first: ask before you fix.';
  await feed(page, { t: 'done', conversation_id: 'x', answer: full, mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0 });
  await page.waitForFunction(() => document.querySelector('.tkglow[data-state="listening"]')); // hands-free: listening again
  assert.ok(mid >= 1 && mid < box.tts.length, 'first sentence was sent for speech before the rest arrived');
  assert.ok(box.tts.length >= 2);
  for (const t of box.tts) assert.ok(!/```|"type"|chart/.test(t), 'no ui block in speech: ' + t);
  assert.match(box.tts.join(' '), /Try one thing first/);
  assert.equal(await page.evaluate(() => window.__played.length), box.tts.length);
  assert.equal(await bridge(page, 'speech.start'), 2);
  assert.equal(await ask(page).catch(() => ''), '');
  await page.click('[data-a="vmx"]');
  await page.waitForSelector('.insbar');
  console.log('PROBE', JSON.stringify(await page.evaluate(() => [window.__h, document.querySelector('.scr').scrollTop, document.querySelector('.scr').scrollHeight, document.querySelector('.scr').clientHeight])));
  assert.equal(await page.$$eval('.im.u', (e) => e.map((x) => x.textContent)).then((l) => l[0]), 'what are our fights mostly about');
  assert.match(await page.textContent('.im.a'), /Mostly money/);
  await context.close();
});

test('voice mode: a tap on the glow while he is being spoken to stops the voice and listens at once', async () => {
  const { context, page } = await open({ live: true, playms: 60000 });
  await voiceTurn(page, 'tell me');
  await page.waitForFunction(() => (window.__posts || []).length === 1);
  await feed(page, { t: 'd', text: 'First sentence here, nice and long enough. Second sentence follows right after it. ' });
  await page.waitForSelector('.tkglow[data-state="speaking"]');
  const playedBefore = await page.evaluate(() => window.__played.length);
  await feed(page, { t: 'done', conversation_id: 'x', answer: 'First sentence here, nice and long enough. Second sentence follows right after it. ', mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0 });
  await page.click('[data-a="vmglow"]', { force: true }); // the glow pulses while speaking, so it is never "stable"
  await page.waitForSelector('.tkglow[data-state="listening"]');
  assert.ok(await page.evaluate(() => window.__paused) >= 1, 'the audio was paused');
  await page.waitForTimeout(300);
  assert.equal(await page.evaluate(() => window.__played.length), playedBefore, 'nothing further was played');
  assert.equal(await bridge(page, 'speech.start'), 2);
  await context.close();
});

test('voice mode: a failed upload keeps the clip with Retry, nothing is sent, and Retry sends the question', async () => {
  const { context, page } = await open();
  box.tstatus = 503;
  await voiceTurn(page, 'retry me');
  await page.waitForSelector('[data-a="vmretry"]');
  assert.equal(await clips(page), 1);
  assert.equal(box.asks.length, 0);
  box.tstatus = 200;
  await page.click('[data-a="vmretry"]');
  await page.waitForFunction(() => document.querySelector('.tkglow[data-state="listening"]'));
  assert.equal(box.asks.length, 1);
  assert.equal(box.asks[0].message, 'retry me');
  assert.equal(await clips(page), 0);
  await context.close();
});

test('voice mode: a question that cannot be saved into the chat (offline at send) keeps the clip with Retry', async () => {
  const { context, page } = await open();
  await page.click('[data-a="vmopen"]');
  await page.waitForSelector('.tkglow[data-state="listening"]');
  box.said = 'keep me';
  await page.evaluate(() => { window.__off = true; });
  await page.evaluate(() => window.cycleNative.speechSilence());
  await page.waitForSelector('[data-a="vmretry"]');
  assert.equal(await clips(page), 1, 'the clip stays until the question is in the chat');
  assert.equal(box.asks.length, 0);
  await page.evaluate(() => { window.__off = false; });
  await page.click('[data-a="vmretry"]');
  await page.waitForFunction(() => document.querySelector('.tkglow[data-state="listening"]'));
  assert.equal(box.asks.length, 1);
  assert.equal(await clips(page), 0);
  await context.close();
});

test('voice mode: closing mid-recording turns the recording into a dictated draft in the Ask box, never sent', async () => {
  const { context, page } = await open();
  box.said = 'half a thought';
  await page.click('[data-a="vmopen"]');
  await page.waitForSelector('.tkglow[data-state="listening"]');
  await page.click('[data-a="vmx"]');
  await page.waitForFunction(() => document.querySelector('[data-d="ins_msg"]') && document.querySelector('[data-d="ins_msg"]').value === 'half a thought');
  assert.equal(box.asks.length, 0);
  await context.close();
});

test('voice mode: a failed speech request is shown, the text still reads, and the chat gets the message', async () => {
  const { context, page } = await open();
  box.ttsFail = true; box.answer = 'Short answer that is long enough to speak.';
  await voiceTurn(page, 'hello');
  await page.waitForFunction(() => document.body.textContent.includes('Couldn’t speak'));
  assert.match(await page.textContent('.tkrep'), /Short answer/);
  await context.close();
});

test('composer: two rows: full-width field, photo/mic/voice mode under it, Send right; Send is dimmed while empty and enables as he types, with no re-render', async () => {
  const { context, page } = await open();
  assert.equal(await page.locator('.insbar [data-a="vmopen"]').count(), 1);
  assert.equal(await page.locator('.insbar [data-a="inssend"].dis').count(), 1, 'Send is dimmed on an empty draft');
  await page.evaluate(() => { document.querySelector('.insbar').dataset.mark = '1'; });
  await page.fill('.insbar textarea', 'hello');
  assert.equal(await page.locator('.insbar [data-a="inssend"].dis').count(), 0, 'typing enables Send');
  assert.equal(await page.locator('.insbar [data-a="vmopen"]').count(), 1, 'voice mode stays');
  assert.equal(await page.getAttribute('.insbar', 'data-mark'), '1', 'same bar element: nothing re-rendered');
  const bb = await page.locator('.insbar textarea').boundingBox();
  const bar = await page.locator('.insbar').boundingBox();
  assert.ok(bb.width >= bar.width - 1, 'two-row composer: the field spans the whole bar: ' + bb.width + ' of ' + bar.width);
  const box = (sel) => page.locator(sel).boundingBox();
  const btns = await Promise.all(['.insbar [data-a="inspick"]', '.insbar .mic', '.insbar [data-a="vmopen"]', '.insbar [data-a="inssend"]'].map(box));
  for (const b of btns) assert.ok(b.y >= bb.y + bb.height - 1, 'buttons sit on the row under the field');
  assert.ok(btns[0].x < btns[1].x && btns[1].x < btns[2].x, 'photo, mic, voice mode left to right');
  assert.ok(btns[3].x + btns[3].width >= bar.x + bar.width - 1, 'Send sits at the right edge');
  await page.fill('.insbar textarea', '');
  assert.equal(await page.locator('.insbar [data-a="inssend"].dis').count(), 1, 'clearing dims Send again');
  await context.close();
});

test('a finished answer that stored clarifications shows them in the one action card', async () => {
  const { context, page } = await open({ live: true });
  await page.fill('.insbar textarea', 'the fight was on May 3, not May 4');
  await page.click('.insbar [data-a="inssend"]');
  await page.waitForFunction(() => window.__sc);
  await page.evaluate(() => window.__feed({ t: 'done', conversation_id: 'x', answer: 'Got it.', mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0, noted: ['The fight about the trip was on 2026-05-03, not 05-04.'] }));
  await page.waitForSelector('.inslog');
  assert.equal(await page.getAttribute('.inslog', 'aria-label'), 'Noted');
  assert.equal(await page.locator('.inslog .gl b.noted').count(), 1);
  assert.equal(await page.textContent('.inslog span.nt'), 'The fight about the trip was on 2026-05-03, not 05-04.');
  await context.close();
});

test('a finished answer that logged chat info to the review shows a Logged line per item', async () => {
  const { context, page } = await open({ live: true });
  await page.fill('.insbar textarea', 'she went quiet after the call and I felt shut out');
  await page.click('.insbar [data-a="inssend"]');
  await page.waitForFunction(() => window.__sc);
  await page.evaluate(() => window.__feed({ t: 'done', conversation_id: 'x', answer: 'That sounds hard.', mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0, logged: ['Esme went quiet after the call; Oliver felt shut out.'] }));
  await page.waitForSelector('.inslog');
  assert.equal(await page.getAttribute('.inslog', 'aria-label'), 'Logged');
  assert.equal(await page.locator('.inslog .gl b.logged').count(), 1);
  assert.equal(await page.textContent('.inslog span'), 'Esme went quiet after the call; Oliver felt shut out.');
  assert.equal(await page.locator('.im.u.lgd .lgbadge').count(), 1); // the user message it came from carries the check badge
  assert.equal(await page.locator('.inslog span.nt').count(), 0);
  const bubble = await page.locator('.im.a').last().boundingBox(), chip = await page.locator('.inslog').boundingBox();
  assert.ok(chip.y >= bubble.y + bubble.height - 1 && chip.y < bubble.y + bubble.height + 40); // directly under the reply
  await context.close();
});

// The chat's hidden <upset> block arrives as done.upsetStart: the phone makes a quick upset (check-ins on) once, and the reply shows it.
test('a finished answer that spotted him upset starts a quick upset with check-ins and shows an upset card', async () => {
  const { context, page } = await open({ live: true });
  await page.fill('.insbar textarea', 'she cancelled dinner again, I am so upset');
  await page.click('.insbar [data-a="inssend"]');
  await page.waitForFunction(() => window.__sc);
  const up = { id: '11111111-2222-3333-4444-555555555555', text: 'Esme cancelled dinner again and I feel brushed off' };
  await page.evaluate((up) => window.__feed({ t: 'done', conversation_id: 'x', answer: 'That stings.', mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0, logged: ['Esme cancelled dinner again.'], upsetStart: up, noted: ['Dinner plans were for Friday.'] }), up);
  await page.waitForSelector('.inslog');
  assert.equal(await page.locator('.inslog').count(), 1, 'logged and the follow-up share one card');
  assert.equal(await page.getAttribute('.inslog', 'aria-label'), 'Logged, Following up, Noted');
  assert.equal(await page.locator('.inslog .gl b.up').count(), 1);
  assert.deepEqual(await page.locator('.inslog span').allTextContents(), ['Esme cancelled dinner again.'], 'one text: the follow-up and note show only as badges');
  assert.equal(await page.locator('.im.u.lgd .lgbadge').count(), 1);
  const rec = await page.waitForFunction((id) => { const k = Object.keys(localStorage).filter((x) => x.startsWith('cycle:priv.'))[0]; const u = JSON.parse(localStorage.getItem(k)).upsets.filter((x) => x.id === id); return u.length && { n: u.length, quick: u[0].quick, dump: u[0].dump, done: !!u[0].done_at }; }, up.id).then((h) => h.jsonValue()); // the write is debounced (persist, 50ms)
  assert.deepEqual(rec, { n: 1, quick: true, dump: up.text, done: true });
  await page.click('.inslog[data-a^="updetail:"]'); // the card opens the upset
  await page.waitForSelector('[data-a="uppassed"]');
  // The detail names the chat it came from, and tapping that row opens the chat again.
  const from = page.locator('.upfrom');
  assert.match(await from.textContent(), /^Chat/);
  const cid = (await from.getAttribute('data-a')).replace('insopen:', '');
  assert.ok(cid, 'From row links to the chat');
  await from.click();
  await page.waitForSelector('.insbar textarea');
  assert.equal(await page.evaluate(() => document.body.textContent.includes('That stings.')), true, 'the chat with the reply is open');
  await context.close();
});

// Locking the phone hides the page, which closes voice mode; the redraw used to copy the voice screen's scroll (0) onto the chat.
test('locking the phone in voice mode drops back to the chat at its newest message, never the top', async () => {
  const { context, page } = await open();
  box.answer = Array.from({ length: 40 }, (_, i) => 'Paragraph ' + i + ' of a long answer about money and plans.').join('\n\n');
  await voiceTurn(page, 'tell me everything');
  await page.waitForFunction(() => document.querySelector('.tkglow[data-state="listening"]')); // answered, listening again
  await page.evaluate(() => { // the voice screen sits at its top (a new reply starts there on the phone); lock (hidden), then unlock
    document.querySelector('.scr').scrollTop = 0;
    const set = (v) => { Object.defineProperty(document, 'visibilityState', { value: v, configurable: true }); document.dispatchEvent(new Event('visibilitychange')); };
    set('hidden'); set('visible');
  });
  await page.waitForSelector('.insbar');
  // Read after two frames: a later stray scroll-to-bottom must not be what makes this pass.
  const s = await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => { const e = document.querySelector('.scr'); r({ top: e.scrollTop, h: e.scrollHeight, c: e.clientHeight }); }))));
  assert.ok(s.h > s.c * 2, 'chat long enough that top and bottom differ');
  assert.ok(s.h - s.top - s.c < 24, 'chat at its newest message: ' + JSON.stringify(s));
  await context.close();
});

test('the reply action row is hidden behind a ··· button: it reveals the model name and buttons, a second tap hides them', async () => {
  const { context, page } = await open({ live: true });
  await page.fill('.insbar textarea', 'hello');
  await page.click('.insbar [data-a="inssend"]');
  await page.waitForFunction(() => window.__sc);
  await page.evaluate(() => window.__feed({ t: 'done', conversation_id: 'x', answer: 'Hi there.', mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0 }));
  await page.waitForSelector('.im.a');
  assert.equal(await page.locator('.ia:not(.u)').count(), 0, 'row hidden by default');
  assert.equal(await page.locator('[data-a^="inscopy:"]').count(), 0);
  const bub = await page.locator('.aiw .im.a').boundingBox(), more = await page.locator('.aiw .more').boundingBox();
  assert.ok(more.x + more.width <= bub.x + bub.width && more.y > bub.y + bub.height - more.height, 'the ··· hangs off the bubble\'s bottom-right corner, taking no width');
  await page.click('[data-a^="insmore:"]');
  assert.equal(await page.textContent('.ia .ml'), 'Opus');
  assert.equal(await page.locator('.ia [data-a^="inscopy:"]').count(), 1);
  assert.equal(await page.locator('.ia [data-a^="insfb:"]').count(), 2);
  await page.click('[data-a^="insmore:"]');
  assert.equal(await page.locator('.ia:not(.u)').count(), 0, 'second tap hides it again');
  await context.close();
});

test('a fight described in the chat shows a Fight card that opens Log fight prefilled; saving turns it into Fight logged, which opens that fight', async () => {
  const { context, page } = await open({ live: true });
  await page.fill('.insbar textarea', 'she snapped at me and swore, I left the room');
  await page.click('.insbar [data-a="inssend"]');
  await page.waitForFunction(() => window.__sc);
  const TXT = 'She snapped about leaving my pax at a party, kept going, then swore again and I left the room';
  await page.evaluate((t) => window.__feed({ t: 'done', conversation_id: 'x', answer: 'That sounds rough. How intense was it, 1 to 5?', mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0, fightStart: { id: 'fs-1', text: t } }), TXT);
  await page.waitForSelector('[data-a="insfight:fs-1"]');
  assert.equal(await page.getAttribute('[data-a="insfight:fs-1"]', 'aria-label'), 'Fight');
  assert.match(await page.textContent('[data-a="insfight:fs-1"]'), /pax at a party/);
  await page.click('[data-a="insfight:fs-1"]');
  await page.waitForSelector('[data-a="fightsave"]');
  assert.equal(await page.inputValue('textarea[data-d="note"]'), TXT);
  await page.click('[data-a="fightsave"]');
  await page.waitForSelector('[data-a="fightsave"]', { state: 'detached' });
  await page.waitForFunction(() => /pax at a party/.test(document.body.textContent) && !!document.querySelector('[data-a="back"]'));
  await page.click('[data-a="back"]'); // saving opens the fight in place of Log fight, so Back returns straight to the chat
  await page.waitForSelector('[data-a="insfight:fs-1"]');
  assert.equal(await page.getAttribute('[data-a="insfight:fs-1"]', 'aria-label'), 'Fight logged');
  await page.click('[data-a="insfight:fs-1"]');
  await page.waitForFunction((t) => document.body.textContent.includes('pax at a party'), TXT);
  assert.equal(await page.locator('[data-a="fightsave"]').count(), 0, 'it opens the fight, not a second Log fight');
  await context.close();
});

// A second <upset> reply in the same chat within 3h of an open quick upset is the same feeling: its text becomes a note on that upset
// and its card opens it. Outside 3h, after the first passed, or in another chat, it is a new upset.
const UP1 = { id: 'aaaaaaaa-0000-0000-0000-000000000001', text: 'Esme does not work hard' }, UP2 = { id: 'aaaaaaaa-0000-0000-0000-000000000002', text: 'Same fight, again about the pax' };
const upDone = (page, up, n) => page.evaluate(([u, n]) => window.__feed({ t: 'done', conversation_id: 'x', answer: 'Reply ' + n, mode: 'normal', model: 'opus', stopped: false, vers: 1, sel: 0, upsetStart: u }), [up, n]);
async function say(page, txt) { // send a message and wait for its stream to open
  await page.evaluate(() => { window.__sc = null; });
  await page.fill('.insbar textarea', txt);
  await page.click('.insbar [data-a="inssend"]');
  await page.waitForFunction(() => window.__sc);
}
const privUps = (page) => page.waitForFunction(() => { const k = Object.keys(localStorage).filter((x) => x.startsWith('cycle:priv.'))[0]; return JSON.parse(localStorage.getItem(k)).upsets; }).then((h) => h.jsonValue());
async function firstUpset(page) {
  await say(page, 'I am upset');
  await upDone(page, UP1, 1);
  await page.waitForSelector('.inslog[data-a^="updetail:"]');
}

test('a second upset reply in the same chat within 3h merges into the open upset as a note, and its card opens that upset', async () => {
  const { context, page } = await open({ live: true });
  await firstUpset(page);
  await say(page, 'still upset');
  await upDone(page, UP2, 2);
  await page.waitForFunction(() => document.querySelectorAll('.inslog[data-a^="updetail:"]').length === 2);
  await page.waitForTimeout(300);
  const ups = await privUps(page);
  assert.equal(ups.length, 1, 'one upset, not two');
  assert.deepEqual(ups[0].notes.map((n) => n.text), [UP2.text]);
  assert.deepEqual(ups[0].log.map((e) => e.kind), ['created', 'done', 'note']);
  assert.ok(ups[0].conv, 'chat-made upsets carry their conversation id');
  assert.deepEqual(await page.$$eval('.inslog', (els) => els.map((e) => e.getAttribute('data-a'))), ['updetail:' + UP1.id, 'updetail:' + UP1.id], 'both cards open the same upset');
  await page.locator('.inslog').last().click();
  await page.waitForSelector('.upnote');
  assert.equal(await page.textContent('.upnote p:last-child'), UP2.text);
  await context.close();
});

for (const [name, tweak] of [
  ['after 3h', (u) => { u.created_at = new Date(Date.now() - 4 * 36e5).toISOString(); }],
  ['after the first passed', (u) => { u.checks = [{ at: new Date().toISOString(), ans: 'passed' }]; }],
  ['in a different chat', (u) => { u.conv = 'other-chat'; }],
]) test('a second upset reply ' + name + ' starts a new upset', async () => {
  const { context, page } = await open({ live: true });
  await firstUpset(page);
  await page.waitForTimeout(300);
  await page.evaluate((src) => { // age the stored upset, then reload: the page boots from it
    const k = Object.keys(localStorage).filter((x) => x.startsWith('cycle:priv.'))[0], p = JSON.parse(localStorage.getItem(k));
    new Function('u', src)(p.upsets[0]); localStorage.setItem(k, JSON.stringify(p));
  }, '(' + tweak.toString() + ')(u)');
  const p2 = await relaunch(context, page);
  await p2.click('[data-a="tab:insights"]');
  await p2.waitForSelector('.insbar');
  await say(p2, 'upset again');
  await upDone(p2, UP2, 2);
  await p2.waitForFunction((id) => document.querySelector('.inslog[data-a="updetail:' + id + '"]'), UP2.id);
  await p2.waitForTimeout(300);
  const ups = await privUps(p2);
  assert.deepEqual(ups.map((u) => u.id).sort(), [UP1.id, UP2.id]);
  assert.equal((ups.find((u) => u.id === UP1.id).notes || []).length, 0);
  await context.close();
});

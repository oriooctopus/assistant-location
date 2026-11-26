// Insights photos and the answer icon row on the real page: picking, draft persistence, POST body, bubble thumbs, lightbox, icon buttons, long-press labels.
// WebKit only (GL_WEBKIT_PW/GL_WEBKIT_EXEC, see ~/.claude/bin/cycle-webkit.sh); skipped without it.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
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
      if (r.raw) return route.fulfill({ status: 200, contentType: 'image/jpeg', body: r.raw });
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


  // A solid-colour PNG (the picker hands the page whatever the photo library has; the page re-encodes it as JPEG).
  const crcT = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (t, d) => { const b = Buffer.concat([Buffer.from(t), d]); const o = Buffer.alloc(4); o.writeUInt32BE(d.length); const c = Buffer.alloc(4); c.writeUInt32BE(crc(b)); return Buffer.concat([o, b, c]); };
  const png = (w, h, rgb) => {
    const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
    const row = Buffer.concat([Buffer.from([0]), Buffer.from(Array.from({ length: w }, () => rgb).flat())]);
    return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(Buffer.concat(Array(h).fill(row)))), chunk('IEND', Buffer.alloc(0))]);
  };
  const file = (name, w, h, rgb) => ({ name, mimeType: 'image/png', buffer: png(w, h, rgb) });
  // JPEG width/height from its SOF marker.
  const jpgSize = (b64) => { const b = Buffer.from(b64, 'base64'); let i = 2; while (i < b.length) { if (b[i] !== 0xff) throw new Error('bad jpeg'); const m = b[i + 1], len = b.readUInt16BE(i + 2); if (m >= 0xc0 && m <= 0xc3) return { h: b.readUInt16BE(i + 5), w: b.readUInt16BE(i + 7) }; i += 2 + len; } throw new Error('no SOF'); };
  const isJpeg = (b64) => Buffer.from(b64, 'base64').subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]));
  const openNew = async (box) => { const o = await open({ box }); await o.page.click('[data-a="tab:insights"]'); await o.page.waitForSelector('[data-d="ins_msg"]'); return o; };
  const sendDis = (o) => o.page.$eval('[data-a="inssend"]', (e) => e.classList.contains('dis'));

  test('photo: button opens a multi-image picker; a picked image shows as a thumb with a 44px remove; Send enables with no text', async () => {
    const o = await openNew();
    assert.equal(await o.page.getAttribute('[data-a="inspick"]', 'aria-label'), 'Add photo');
    assert.equal(await o.page.getAttribute('#insfile', 'accept'), 'image/*');
    assert.notEqual(await o.page.getAttribute('#insfile', 'multiple'), null);
    assert.equal(await sendDis(o), true);
    await o.page.setInputFiles('#insfile', [file('a.png', 2400, 1200, [200, 40, 40])]);
    await o.page.waitForSelector('.insph .th img');
    assert.equal((await o.page.$$('.insph .th img')).length, 1);
    assert.equal(await sendDis(o), false, 'images alone enable Send');
    const box = await o.page.$eval('[data-a="insimgx:0"]', (e) => { const r = e.getBoundingClientRect(); return [r.width, r.height]; });
    assert.ok(box[0] >= 44 && box[1] >= 44, 'remove target is at least 44px');
    const vis = await o.page.$eval('[data-a="insimgx:0"] .ic', (e) => { const r = e.getBoundingClientRect(), b = e.parentElement.getBoundingClientRect(); return { w: r.width, bg: getComputedStyle(e.parentElement).backgroundColor, bw: getComputedStyle(e.parentElement).borderTopWidth, pw: b.width }; });
    assert.ok(vis.w <= 24 && vis.bg === 'rgba(0, 0, 0, 0)' && vis.bw === '0px', 'the remove button shows only a small x chip, not the 44px target box: ' + JSON.stringify(vis));
    await o.page.click('[data-a="insimgx:0"]');
    assert.equal(await o.page.$('.insph'), null);
    assert.equal(await sendDis(o), true);
    await o.context.close();
  });

  test('photo: limit is 4 per message', async () => {
    const o = await openNew();
    await o.page.setInputFiles('#insfile', [1, 2, 3].map((n) => file(`a${n}.png`, 64, 64, [n * 50, 0, 0])));
    await o.page.waitForFunction(() => document.querySelectorAll('.insph .th img').length === 3);
    await o.page.setInputFiles('#insfile', [4, 5, 6].map((n) => file(`b${n}.png`, 64, 64, [0, n * 30, 0])));
    await o.page.waitForFunction(() => document.querySelectorAll('.insph .th img').length === 4);
    await o.page.waitForTimeout(300);
    assert.equal((await o.page.$$('.insph .th img')).length, 4);
    await o.context.close();
  });

  test('photo: picked images survive a reload with the draft, in the collapsed and the expanded composer', async () => {
    const o = await openNew();
    await o.page.fill('[data-d="ins_msg"]', 'look at this');
    await o.page.setInputFiles('#insfile', [file('a.png', 300, 200, [10, 90, 200]), file('b.png', 200, 300, [10, 200, 90])]);
    await o.page.waitForFunction(() => document.querySelectorAll('.insph .th img').length === 2);
    await o.page.waitForTimeout(500);
    const before = await o.page.$$eval('.insph .th img', (e) => e.map((x) => x.src));
    await o.page.reload(); await o.page.waitForSelector('.tabbar');
    await o.page.click('[data-a="tab:insights"]');
    await o.page.waitForFunction(() => document.querySelectorAll('.insph .th img').length === 2);
    assert.deepEqual(await o.page.$$eval('.insph .th img', (e) => e.map((x) => x.src)), before);
    await o.page.fill('[data-d="ins_msg"]', 'look at this\n1\n2\n3\n4\n5\n6\n7');
    await o.page.waitForSelector('.insta.xp');
    await o.page.click('[data-a="insexpand"]');
    await o.page.waitForTimeout(300);
    assert.equal((await o.page.$$('.insph .th img')).length, 2, 'expanded composer shows them too');
    assert.equal(await o.page.getAttribute('.insexp [data-a="inspick"], [data-a="inspick"].insib', 'aria-label'), 'Add photo');
    await o.page.click('[data-a="insimgx:0"]');
    await o.page.waitForTimeout(300);
    await o.page.reload(); await o.page.waitForSelector('.tabbar');
    await o.page.click('[data-a="tab:insights"]');
    await o.page.waitForSelector('.insph .th img');
    assert.equal((await o.page.$$('.insph .th img')).length, 1, 'a removed image stays removed after reload');
    await o.context.close();
  });

  test('photo: Send puts the bubble with thumbs up at once, POSTs images (1600px max + 256px thumb), clears the draft; the full photo opens from the box and closes on tap', async () => {
    let release; const gate = new Promise((r) => { release = r; });
    const o = await openNew(async (req) => {
      if (req.method === 'POST' && req.path === '/insights') { await gate; return answer('A rash.', 'normal', 'opus', { images: ['abcdef0123456789abcdef01'] }); }
      if (req.method === 'GET' && req.path.endsWith('/abcdef0123456789abcdef01')) return { raw: Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16]) };
    });
    await o.page.setInputFiles('#insfile', [file('a.png', 2400, 1200, [200, 40, 40])]);
    await o.page.waitForSelector('.insph .th img');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('.im.u .ths .th img');
    assert.equal(await o.page.$('.insph'), null, 'composer thumbs cleared on the tap');
    release();
    await o.page.waitForSelector('.im.a');
    const p = posts(o)[0].body;
    assert.equal(p.message, ''); assert.equal(p.images.length, 1);
    assert.ok(isJpeg(p.images[0].data) && isJpeg(p.images[0].thumb));
    assert.deepEqual(jpgSize(p.images[0].data), { w: 1600, h: 800 });
    assert.deepEqual(jpgSize(p.images[0].thumb), { w: 256, h: 128 });
    await o.page.click('.im.u .ths .th');
    await o.page.waitForSelector('.inslb');
    await o.page.waitForFunction(() => document.querySelector('.inslb img') && document.querySelector('.inslb img').src.startsWith('blob:'));
    assert.ok(o.boxCalls.some((c) => c.method === 'GET' && c.path.endsWith('/abcdef0123456789abcdef01')));
    await o.page.click('.inslb');
    assert.equal(await o.page.$('.inslb'), null);
    await o.context.close();
  });

  test('photo: a failed send keeps the question and photos; Retry resends the images and text', async () => {
    let n = 0;
    const o = await openNew(async (req) => { if (req.method === 'POST') return n++ ? answer('ok') : { status: 502, body: { error: 'x' } }; });
    await o.page.fill('[data-d="ins_msg"]', 'what is this');
    await o.page.setInputFiles('#insfile', [file('a.png', 300, 300, [1, 2, 3])]);
    await o.page.waitForSelector('.insph .th img');
    await o.page.click('[data-a="inssend"]');
    await o.page.waitForSelector('[data-a="insretry"]');
    assert.equal((await o.page.$$('.im.u .ths .th')).length, 1);
    await o.page.click('[data-a="insretry"]');
    await o.page.waitForSelector('.im.a');
    assert.equal(posts(o).length, 2);
    assert.equal(posts(o)[0].body.images.length, 1);
    assert.deepEqual(posts(o)[1].body.images, posts(o)[0].body.images);
    assert.equal(posts(o)[1].body.message, 'what is this');
    await o.context.close();
  });

  test('photo: a stored message shows its thumbs; editing it keeps them and sends no images', async () => {
    const th = Buffer.from([0xff, 0xd8, 0xff, 0xe0]).toString('base64');
    const msgs = [{ role: 'user', text: 'q', images: [{ id: 'abcdef0123456789abcdef01', thumb: th }] }, A('a')];
    const o = await openOne(msgs, async (req) => {
      if (req.path === '/insights/conversations') return { status: 200, body: { conversations: [conv1()] } };
      if (req.method === 'POST') return answer('new');
      return { status: 200, body: full(conv1(), msgs) };
    });
    assert.equal((await o.page.$$('.im.u .ths .th img')).length, 1);
    await o.page.click('[data-a="insedit:0"]');
    await o.page.fill('[data-d="ins_edit"]', 'q edited');
    await o.page.click('[data-a="inseditsend:0"]');
    await o.page.waitForFunction(() => document.querySelector('.im.a') && document.querySelector('.im.a').textContent === 'new');
    assert.equal((await o.page.$$('.im.u .ths .th img')).length, 1, 'photo still on the edited message');
    assert.equal(posts(o)[0].body.images, undefined);
    assert.equal(posts(o)[0].body.edit_index, 0);
    await o.context.close();
  });

  test('icon row: answer actions are named icon buttons, 44px targets, 12px gaps; Edit is an icon; model label stays', async () => {
    const o = await openOne([{ role: 'user', text: 'q' }, A('the answer', { fb: '+' })]);
    const row = await o.page.$$eval('.im.a ~ .ia .ibtn, .ia .ibtn', (els) => els.filter((e) => e.dataset.a !== 'insedit:0' && !e.dataset.a.startsWith('jrnl:')).map((e) => ({ a: e.dataset.a, label: e.getAttribute('aria-label'), tip: e.dataset.tip, txt: e.textContent.trim(), svg: !!e.querySelector('svg use'), r: (({ x, y, width, height }) => ({ x, y, width, height }))(e.getBoundingClientRect()) })));
    assert.deepEqual(row.map((x) => [x.a, x.label]), [['inscopy:1', 'Copy'], ['insregen', 'Regenerate'], ['insdeeper:1', 'Go deeper'], ['insfb:1:+', 'Good'], ['insfb:1:-', 'Bad']]);
    assert.ok(row.every((x) => x.txt === '' && x.svg && x.tip === x.label), 'icons only, tip = label');
    assert.ok(row.every((x) => x.r.width >= 44 && x.r.height >= 44), 'tap targets >= 44px');
    for (let i = 1; i < row.length; i++) if (Math.abs(row[i].r.y - row[i - 1].r.y) < 5) assert.ok(row[i].r.x - (row[i - 1].r.x + row[i - 1].r.width) >= 11.5, 'gap >= 12px');
    assert.equal(await o.page.getAttribute('[data-a="insedit:0"]', 'aria-label'), 'Edit');
    assert.equal(await o.page.$eval('[data-a="insfb:1:+"]', (e) => e.classList.contains('on')), true);
    assert.equal(await o.page.$eval('[data-a="insfb:1:-"]', (e) => e.classList.contains('on')), false);
    const col = (a) => o.page.$eval(`[data-a="${a}"]`, (e) => getComputedStyle(e).color);
    assert.notEqual(await col('insfb:1:+'), await col('insfb:1:-'), 'on is a different (pink) colour');
    await o.context.close();
  });

  test('icon row: tap on Copy fires and flips to the tick (aria-label Copied)', async () => {
    const o = await openOne([{ role: 'user', text: 'q' }, A('the answer')]);
    await o.page.evaluate(() => { Object.defineProperty(navigator, 'clipboard', { value: { writeText: async (t) => { window.__copied = t; } }, configurable: true }); });
    await o.page.click('[data-a="inscopy:1"]');
    await o.page.waitForFunction(() => window.__copied === 'the answer');
    assert.equal(await o.page.getAttribute('[data-a="inscopy:1"]', 'aria-label'), 'Copied');
    assert.equal(await o.page.$eval('[data-a="inscopy:1"] use', (u) => u.getAttribute('href')), '#tck');
    await o.context.close();
  });

  test('long press: ~450ms shows the label above the button inside the screen; release hides it and the action does NOT fire; a later tap still fires', async () => {
    const o = await openOne([{ role: 'user', text: 'q' }, A('the answer')]);
    await o.page.evaluate(() => { window.__copied = null; Object.defineProperty(navigator, 'clipboard', { value: { writeText: async (t) => { window.__copied = t; } }, configurable: true }); });
    for (const [a, name] of [['inscopy:1', 'Copy'], ['insfb:1:-', 'Bad'], ['insregen', 'Regenerate']]) {
      const bb = await (await o.page.$(`[data-a="${a}"]`)).boundingBox();
      await o.page.mouse.move(bb.x + bb.width / 2, bb.y + bb.height / 2);
      await o.page.mouse.down();
      await o.page.waitForTimeout(250);
      assert.equal(await o.page.$('.tipb'), null, 'not yet at 250ms');
      await o.page.waitForSelector('.tipb');
      assert.equal(await o.page.textContent('.tipb'), name);
      const r = await o.page.$eval('.tipb', (e) => { const b = e.getBoundingClientRect(); return { l: b.left, r: b.right, b: b.bottom, vw: innerWidth }; });
      assert.ok(r.l >= 7.5 && r.r <= r.vw - 7.5, 'bubble inside the screen horizontally ' + JSON.stringify(r));
      assert.ok(r.b <= bb.y, 'bubble above the button');
      await o.page.mouse.up();
      await o.page.waitForSelector('.tipb', { state: 'detached' });
    }
    await o.page.waitForTimeout(300);
    assert.equal(await o.page.evaluate(() => window.__copied), null, 'copy did not fire');
    assert.equal(await o.page.$('[data-a="insfbsend"]'), null, 'Bad did not fire');
    assert.equal(posts(o).length, 0, 'regenerate did not fire');
    await o.page.waitForTimeout(700);
    await o.page.click('[data-a="inscopy:1"]');
    await o.page.waitForFunction(() => window.__copied === 'the answer');
    await o.context.close();
  });

  test('long press by touch pointer events: label shows; pointercancel before 450ms shows none and does not swallow the next tap; callout/select off', async () => {
    const o = await openOne([{ role: 'user', text: 'q' }, A('the answer')]);
    await o.page.evaluate(() => { window.__copied = null; Object.defineProperty(navigator, 'clipboard', { value: { writeText: async (t) => { window.__copied = t; } }, configurable: true }); });
    // Desktop WebKit does not report -webkit-touch-callout through computed style, so the rule text is checked (the iOS-only property) plus the computed select.
    assert.match(CSS, /\[data-tip\]\{[^}]*-webkit-touch-callout:none/);
    assert.equal(await o.page.$eval('[data-a="inscopy:1"]', (e) => getComputedStyle(e).webkitUserSelect), 'none');
    const fire = (type) => o.page.$eval('[data-a="insfb:1:+"]', (e, t) => { const r = e.getBoundingClientRect(); e.dispatchEvent(new PointerEvent(t, { bubbles: true, pointerType: 'touch', isPrimary: true, clientX: r.x + 20, clientY: r.y + 20 })); }, type);
    await fire('pointerdown'); await o.page.waitForSelector('.tipb');
    assert.equal(await o.page.textContent('.tipb'), 'Good');
    await fire('pointerup');
    await o.page.waitForSelector('.tipb', { state: 'detached' });
    await o.page.waitForTimeout(700);
    await fire('pointerdown'); await o.page.waitForTimeout(200); await fire('pointercancel');
    await o.page.waitForTimeout(500);
    assert.equal(await o.page.$('.tipb'), null, 'cancelled before 450ms: no label');
    await o.page.click('[data-a="inscopy:1"]');
    await o.page.waitForFunction(() => window.__copied === 'the answer');
    await o.context.close();
  });
});

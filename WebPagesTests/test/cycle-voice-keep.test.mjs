// Dictation survives leaving the screen and a page death. The shared hold menu (voice-hold.js) on Cycle's dictation mics: hold a recording mic for Cancel / Insert. Native shell
// (bridge + recording) is faked and the box's /transcribe is stubbed; the field is the Log fight note.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

// Served over https (routed from disk): file:// pages do not share localStorage, so a relaunch would boot on an empty one.
const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web');
const URL_ = 'https://app.test/index.html';
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' };
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const SHOTS = process.env.VHOLD_SHOTS || '';
const UID = 'u-me';
const seed = () => ({
  session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } },
  ['shared.' + UID]: {
    couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [{ user_id: UID, name: 'Mia Park', checkin_time: '21:00', hits_self: false }, { user_id: 'u-her', name: 'Jo Lee', checkin_time: '21:00', hits_self: true }],
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, rewards: {}, redemptions: {}, fight_markers: { fp: { id: 'fp', couple_id: 'c1', logged_by: UID, at: '2026-11-01T12:00:00Z', repaired_at: null, hit_self: null, hit_related: null } }, fight_notes: {} },
    cursors: {}, outbox: [],
  },
  ['priv.' + UID]: { fights: [], affirmations: [], prefs: {} },
});

let browser;
before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { await browser.close(); });

let said = '', delay = 0, uploads = 0, status = 200; // what the box transcribes the next clip as ('' = 422), how long it takes, clips received, the status it answers with
async function open(opts = {}) { // opts: shell (the shell version app.info reports), disk (clips the native side already holds), clips (kv voiceclips)
  said = ''; delay = 0; status = opts.status || 200;
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript((sd) => {
    window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: 'https://box.test' };
    if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    window.__bridge = [];
    window.webkit = { messageHandlers: { cycle: { postMessage: ({ id, cmd, args }) => {
      window.__bridge.push(cmd);
      // mock:setdelay holds the voiceclips kv write back (its reply too), so the order of that write and speech.ack is observable
      const hold = cmd === 'store.set' && args.key === 'voiceclips' ? +localStorage.getItem('mock:setdelay') || 0 : 0;
      setTimeout(() => {
        let r = null;
        if (cmd === 'store.get') r = localStorage.getItem('cycle:' + args.key);
        else if (cmd === 'store.set') {
          localStorage.setItem('cycle:' + args.key, args.value);
          if (args.key === 'voiceclips' && JSON.parse(args.value).length) localStorage.setItem('mock:log', JSON.stringify([...JSON.parse(localStorage.getItem('mock:log') || '[]'), 'kvset']));
        }
        else if (cmd === 'store.keys') r = Object.keys(localStorage).filter((k) => k.startsWith('cycle:' + args.prefix)).map((k) => k.slice(6));
        else if (cmd === 'notify.status') r = 'granted';
        else if (cmd === 'lock.get') r = false;
        else if (cmd === 'speech.stop') { // base64 'AUDIO'; shell 4+ keeps the file on disk under an id until speech.ack
          r = { audio: 'QVVESU8=', mime: 'audio/mp4' };
          if (+localStorage.getItem('mock:shell') >= 4) {
            r.id = 'n-' + Math.random().toString(36).slice(2);
            localStorage.setItem('mock:disk', JSON.stringify([...JSON.parse(localStorage.getItem('mock:disk')), r]));
          }
        }
        else if (cmd === 'app.info') r = { shell: +localStorage.getItem('mock:shell'), native: 0 };
        else if (cmd === 'speech.ack') {
          localStorage.setItem('mock:log', JSON.stringify([...JSON.parse(localStorage.getItem('mock:log') || '[]'), 'ack']));
          localStorage.setItem('mock:disk', JSON.stringify(JSON.parse(localStorage.getItem('mock:disk')).filter((c) => c.id !== args.id)));
        }
        else if (cmd === 'speech.orphans') r = JSON.parse(localStorage.getItem('mock:disk'));
        window.__cycleReply(id, r, null);
      }, hold);
    } } } };
  }, seed());
  await context.addInitScript((o) => { // the native side's disk and version survive reloads like the real ones; seeded once
    if (localStorage.getItem('mock:init')) return;
    localStorage.setItem('mock:init', '1');
    localStorage.setItem('mock:shell', String(o.shell || 0));
    localStorage.setItem('mock:disk', JSON.stringify(o.disk || []));
    if (o.clips) localStorage.setItem('cycle:voiceclips', JSON.stringify(o.clips));
    if (o.setdelay) localStorage.setItem('mock:setdelay', String(o.setdelay));
  }, opts);
  await context.route('https://app.test/**', (route) => {
    const f = path.join(WEB, new URL(route.request().url()).pathname);
    if (!fs.existsSync(f)) return route.fulfill({ status: 404, body: '' }); // config.js is not shipped
    return route.fulfill({ contentType: MIME[path.extname(f)] || 'application/octet-stream', body: fs.readFileSync(f) });
  });
  await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
  await context.route('https://x.test/**', (route) => route.abort());
  await context.route('https://box.test/backup', (route) => route.fulfill({ status: 404, body: '' })); // an unrouted pull would race the boot and could replace the local priv
  uploads = 0;
  await context.route('https://box.test/transcribe', async (route) => {
    uploads++;
    if (delay) await new Promise((r) => setTimeout(r, delay));
    if (status >= 500) return route.fulfill({ status, contentType: 'application/json', body: '{"error":"down"}' });
    return said ? route.fulfill({ contentType: 'application/json', body: JSON.stringify({ text: said }) }) : route.fulfill({ status: 422, contentType: 'application/json', body: '{"error":"no speech"}' });
  });
  const page = await context.newPage();
  page.on('pageerror', (e) => { throw e; });
  await page.goto(URL_, { waitUntil: 'domcontentloaded' });
  return { context, page };
}

// An app relaunch on the same storage: the old page closes, a new one boots from what it saved.
async function relaunch(context, page) {
  const next = await context.newPage();
  next.on('pageerror', (e) => { throw e; });
  await page.close();
  await next.goto(URL_, { waitUntil: 'domcontentloaded' });
  return next;
}
const outbox = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')).outbox.filter((o) => o.table === 'fight_notes').length);
const more = (page) => page.inputValue('[data-d="more"]');
// Routes only once the app has booted and drawn its tab bar: a route taken earlier is overwritten by the boot render.
async function toFight(page) {
  await page.waitForSelector('[data-a="tab:progress"]');
  await page.evaluate(() => window.cycleNative.route('fight/fp'));
}
async function openFight(page) {
  await toFight(page);
  await page.waitForSelector('[data-a="mic:more"][data-go="notesave"]');
  await page.fill('[data-d="more"]', 'We argued');
}
async function recordAndStop(page) {
  await page.click('[data-a="mic:more"]');
  await page.waitForSelector('.mic.rec[data-a="mic:more"]');
  said = 'at dinner';
  await page.click('[data-a="mic:more"]');
  await page.waitForSelector('.mic.busy[data-a="mic:more"]');
}

test('leaving the fight while the clip uploads puts the words in that fight box and does not save it', async () => {
  const { context, page } = await open();
  await openFight(page);
  delay = 500;
  await recordAndStop(page);
  await page.click('[data-a="tab:progress"]');
  await page.waitForFunction(() => !document.querySelector('[data-d="more"]'));
  await page.waitForTimeout(900);
  assert.equal(await outbox(page), 0, 'nothing is submitted');
  await toFight(page);
  await page.waitForSelector('[data-d="more"]');
  assert.equal(await more(page), 'We argued at dinner');
  assert.equal(await outbox(page), 0);
  assert.equal(await page.evaluate(() => localStorage.getItem('cycle:voiceclips')), '[]', 'the kept clip is cleared once placed');
  await context.close();
});

test('words for a fight left mid-upload are persisted in its draft, so they survive a reload', async () => {
  const { context, page: first } = await open();
  let page = first;
  await openFight(page);
  delay = 300;
  await recordAndStop(page);
  await page.click('[data-a="tab:progress"]');
  await page.waitForFunction(() => !document.querySelector('[data-d="more"]'));
  await page.waitForFunction(() => localStorage.getItem('cycle:voiceclips') === '[]'); // placed
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:priv.u-me')).drafts?.['fightdetail:fp']?.d?.more === 'We argued at dinner');
  page = await relaunch(context, page);
  await toFight(page);
  await page.waitForSelector('[data-d="more"]');
  assert.equal(await more(page), 'We argued at dinner');
  await context.close();
});

test('a page that dies before /transcribe answers gets the words back from the kept clip after reload', async () => {
  const { context, page: first } = await open();
  let page = first;
  await openFight(page);
  delay = 3000;
  await recordAndStop(page);
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:voiceclips') || '[]').length === 1);
  delay = 0; said = 'at dinner';
  page = await relaunch(context, page);
  await page.waitForFunction(() => localStorage.getItem('cycle:voiceclips') === '[]');
  await toFight(page);
  await page.waitForSelector('[data-d="more"]');
  assert.equal(await more(page), 'We argued at dinner');
  assert.equal(await outbox(page), 0);
  await context.close();
});

const disk = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('mock:disk')).map((c) => c.id));
const kept = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('cycle:voiceclips') || '[]'));

test('shell 4: the native file is acked only after the clip is saved in kv, and kept while that has not happened', async () => {
  const { context, page } = await open({ shell: 4 });
  await openFight(page);
  delay = 1500;
  await recordAndStop(page);
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:voiceclips') || '[]').length === 1);
  assert.match((await kept(page))[0].nid, /^n-/, 'the kv copy records the native id');
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('mock:disk')).length === 0);
  assert.equal((await kept(page)).length, 1, 'the kv copy is what survives now');
  await page.waitForFunction(() => localStorage.getItem('cycle:voiceclips') === '[]');
  assert.deepEqual(await disk(page), []);
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')).outbox.some((o) => o.table === 'fight_notes'));
  await context.close();
});

test('shell 4: a clip the native side kept but the page never saved (page died at stop) is imported into the fight draft and acked', async () => {
  const { context, page } = await open({ shell: 4, disk: [{ id: 'o1', audio: 'QVVESU8=', mime: 'audio/mp4' }] });
  said = 'from the orphan';
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('mock:disk')).length === 0);
  await page.waitForFunction(() => localStorage.getItem('cycle:voiceclips') === '[]');
  assert.equal(uploads, 1);
  await toFight(page);
  await page.waitForSelector('[data-d="more"]');
  assert.equal(await more(page), 'from the orphan');
  await context.close();
});

test('shell 4: an orphan whose clip is already in kv is acked without being uploaded twice', async () => {
  const clip = { id: 'k1', nid: 'd1', audio: 'QVVESU8=', mime: 'audio/mp4', field: 'more', key: 'fight' };
  const { context, page } = await open({ shell: 4, disk: [{ id: 'd1', audio: 'QVVESU8=', mime: 'audio/mp4' }], clips: [clip] });
  said = 'once';
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('mock:disk')).length === 0);
  await page.waitForFunction(() => localStorage.getItem('cycle:voiceclips') === '[]');
  assert.equal(uploads, 1);
  await context.close();
});

test('an old shell (no speech.ack / speech.orphans) is never asked for them', async () => {
  const { context, page } = await open({ shell: 3, disk: [{ id: 'o1', audio: 'QVVESU8=', mime: 'audio/mp4' }] });
  await openFight(page);
  delay = 400;
  await recordAndStop(page);
  await page.waitForFunction(() => !document.querySelector('.mic.busy'));
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')).outbox.some((o) => o.table === 'fight_notes'));
  const calls = await page.evaluate(() => window.__bridge);
  assert.ok(!calls.includes('speech.orphans') && !calls.includes('speech.ack'), calls.join());
  assert.equal(uploads, 1);
  await context.close();
});

const log = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('mock:log') || '[]'));
const strand = { id: '1794334226134-a', audio: 'QVVESU8=', mime: 'audio/mp4', field: 'more', key: 'fightdetail:fp' };

test('shell 4: speech.ack waits for the kv write to finish', async () => {
  const { context, page } = await open({ shell: 4, setdelay: 600 });
  await openFight(page);
  delay = 1500;
  said = 'at dinner';
  await page.click('[data-a="mic:more"]');
  await page.waitForSelector('.mic.rec[data-a="mic:more"]');
  await page.click('[data-a="mic:more"]');
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('mock:log') || '[]').includes('ack'));
  assert.deepEqual(await log(page), ['kvset', 'ack'], 'the clip is in kv before the shell is told to delete its file');
  await context.close();
});

test('a failed /transcribe keeps the clip and the fight shows Retry; Retry puts the words in the box and clears it', async () => {
  const { context, page } = await open();
  await openFight(page);
  status = 500;
  await page.click('[data-a="mic:more"]');
  await page.waitForSelector('.mic.rec[data-a="mic:more"]');
  await page.click('[data-a="mic:more"]');
  await page.waitForSelector('.vclip [data-a^="clipretry"]');
  assert.equal((await kept(page)).length, 1, 'the clip is still kept');
  assert.equal(await outbox(page), 0);
  status = 200; said = 'at dinner';
  await page.click('[data-a^="clipretry"]');
  await page.waitForFunction(() => document.querySelector('[data-d="more"]')?.value === 'We argued at dinner');
  await page.waitForFunction(() => !document.querySelector('.vclip'));
  assert.deepEqual(await kept(page), []);
  await context.close();
});

test('Discard asks first: Keep leaves the clip, Discard drops it without uploading', async () => {
  const { context, page } = await open({ clips: [strand], status: 500 });
  await toFight(page);
  await page.click('[data-a="clipdrop:1794334226134-a"]');
  await page.waitForSelector('.bs.cf [data-a="clipdropgo:1794334226134-a"]');
  assert.equal((await kept(page)).length, 1, 'one tap deletes nothing');
  await page.click('.bs.cf .ghost');
  await page.waitForFunction(() => !document.querySelector('.bs.cf'));
  assert.equal((await kept(page)).length, 1, 'Keep leaves it');
  await page.click('[data-a="clipdrop:1794334226134-a"]');
  await page.click('[data-a="clipdropgo:1794334226134-a"]');
  await page.waitForFunction(() => !document.querySelector('.vclip') && !document.querySelector('.bs.cf'));
  assert.deepEqual(await kept(page), []);
  await context.close();
});

test('two stranded clips: each row is labelled and Retry spins only the tapped row', async () => {
  const two = { ...strand, id: '1794334326134-b', dur: 42 };
  const { context, page } = await open({ clips: [strand, two], status: 500 });
  await toFight(page);
  await page.waitForSelector('.vclip [data-a="clipretry:1794334326134-b"]');
  const labels = await page.$$eval('.vclip .cm', (els) => els.map((e) => e.textContent));
  assert.equal(labels.length, 2);
  assert.notEqual(labels[0], labels[1]);
  assert.match(labels[1], /^0:42 \u00b7 \d+:\d\d\s?(am|pm)$/);
  delay = 800;
  await page.click('[data-a="clipretry:1794334326134-b"]');
  await page.waitForSelector('.vclip .save.busy .spin');
  assert.equal(await page.$$eval('.vclip .spin', (e) => e.length), 1);
  assert.ok(await page.$('[data-a="clipretry:1794334326134-b"].busy'), 'the tapped row spins');
  assert.ok(await page.$('[data-a="clipretry:1794334226134-a"]:not(.busy)'), 'the other row does not');
  await context.close();
});

test('a clip whose recovery upload failed at boot stays kept and shows Retry', async () => {
  const { context, page } = await open({ clips: [strand], status: 500 });
  await toFight(page);
  await page.waitForSelector('.vclip [data-a^="clipretry"]');
  assert.equal((await kept(page)).length, 1);
  await context.close();
});

for (const how of ['foreground', 'online']) {
  test('a stranded clip is recovered when the app comes back (' + how + ')', async () => {
    const { context, page } = await open({ clips: [strand], status: 500 });
    await toFight(page);
    await page.waitForSelector('.vclip [data-a^="clipretry"]');
    status = 200; said = 'recovered words';
    await page.evaluate((h) => { if (h === 'online') window.dispatchEvent(new Event('online')); else window.cycleNative.foreground(); }, how);
    await page.waitForFunction(() => document.querySelector('[data-d="more"]')?.value === 'recovered words');
    await page.waitForFunction(() => localStorage.getItem('cycle:voiceclips') === '[]');
    await context.close();
  });
}

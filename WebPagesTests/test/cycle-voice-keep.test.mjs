// Dictation survives leaving the screen and a page death. The shared hold menu (voice-hold.js) on Cycle's dictation mics: hold a recording mic for Cancel / Insert. Native shell
// (bridge + recording) is faked and the box's /transcribe is stubbed; the field is the Log fight note.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
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

let said = '', delay = 0, uploads = 0; // what the box transcribes the next clip as ('' = 422), how long it takes, clips received
async function open() {
  said = ''; delay = 0;
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript((sd) => {
    window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: 'https://box.test' };
    if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    window.__bridge = [];
    window.webkit = { messageHandlers: { cycle: { postMessage: ({ id, cmd, args }) => {
      window.__bridge.push(cmd);
      setTimeout(() => {
        let r = null;
        if (cmd === 'store.get') r = localStorage.getItem('cycle:' + args.key);
        else if (cmd === 'store.set') localStorage.setItem('cycle:' + args.key, args.value);
        else if (cmd === 'store.keys') r = Object.keys(localStorage).filter((k) => k.startsWith('cycle:' + args.prefix)).map((k) => k.slice(6));
        else if (cmd === 'notify.status') r = 'granted';
        else if (cmd === 'lock.get') r = false;
        else if (cmd === 'speech.stop') r = { audio: 'QVVESU8=', mime: 'audio/mp4' }; // base64 'AUDIO'
        window.__cycleReply(id, r, null);
      }, 0);
    } } } };
  }, seed());
  await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
  await context.route('https://x.test/**', (route) => route.abort());
  uploads = 0;
  await context.route('https://box.test/transcribe', async (route) => {
    uploads++;
    if (delay) await new Promise((r) => setTimeout(r, delay));
    return said ? route.fulfill({ contentType: 'application/json', body: JSON.stringify({ text: said }) }) : route.fulfill({ status: 422, contentType: 'application/json', body: '{"error":"no speech"}' });
  });
  const page = await context.newPage();
  page.on('pageerror', (e) => { throw e; });
  await page.goto(URL_, { waitUntil: 'domcontentloaded' });
  return { context, page };
}

const outbox = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('cycle:shared.u-me')).outbox.filter((o) => o.table === 'fight_notes').length);
const more = (page) => page.inputValue('[data-d="more"]');
async function openFight(page) {
  await page.evaluate(() => window.cycleNative.route('fight/fp'));
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
  await page.evaluate(() => window.cycleNative.route('fight/fp'));
  await page.waitForSelector('[data-d="more"]');
  assert.equal(await more(page), 'We argued at dinner');
  assert.equal(await outbox(page), 0);
  assert.equal(await page.evaluate(() => localStorage.getItem('cycle:voiceclips')), '[]', 'the kept clip is cleared once placed');
  await context.close();
});

test('a page that dies before /transcribe answers gets the words back from the kept clip after reload', async () => {
  const { context, page } = await open();
  await openFight(page);
  delay = 3000;
  await recordAndStop(page);
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('cycle:voiceclips') || '[]').length === 1);
  delay = 0; said = 'at dinner';
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForFunction(() => localStorage.getItem('cycle:voiceclips') === '[]');
  await page.evaluate(() => window.cycleNative.route('fight/fp'));
  await page.waitForSelector('[data-d="more"]');
  assert.equal(await more(page), 'We argued at dinner');
  assert.equal(await outbox(page), 0);
  await context.close();
});

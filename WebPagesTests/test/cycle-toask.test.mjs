// Home's one pinned "To <partner>" row: it opens a composer with Do | Read (Do by default). Do makes the same to do the New to-do
// sheet makes for the partner; Read sends a reminder. WebKit only (set GL_WEBKIT_PW/GL_WEBKIT_EXEC); skipped without it.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const haveWebkit = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = haveWebkit ? await import(process.env.GL_WEBKIT_PW) : null;

const ME = 'u-me', HER = 'u-her';
const MORNING = '2026-10-26T15:00:00Z';

const seed = (who) => ({
  session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: who, email: who + '@x.test' } },
  ['shared.' + who]: {
    // hold_ask_min 0: an ordinary ask is delivered at once, so only the issue override can explain a hold.
    couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 0, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [{ user_id: ME, name: 'Me', checkin_time: '21:00' }, { user_id: HER, name: 'Alexandria Rae', checkin_time: '21:00' }],
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, fight_markers: {}, fight_notes: {}, rewards: {}, redemptions: {}, nudges: {}, nudge_sends: {}, nudge_replies: {}, nudge_awards: {}, acks: {}, challenges: {} },
    cursors: {}, outbox: [],
  },
  ['priv.' + who]: { fights: [], affirmations: [], prefs: {}, nudges: [], nudge_sends: [] },
});

describe('to partner', { skip: !haveWebkit }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  // sd: the localStorage dump to start from (a previous session's state, or a fresh seed).
  async function open({ sd, at = MORNING } = {}) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(at));
    await context.addInitScript(({ sd }) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
      window.__calls = [];
      window.webkit = { messageHandlers: { cycle: { postMessage: ({ id, cmd, args }) => {
        window.__calls.push({ cmd, args });
        let r = null;
        if (cmd === 'store.get') r = localStorage.getItem('cycle:' + args.key);
        else if (cmd === 'store.set') { if (args.value === null) localStorage.removeItem('cycle:' + args.key); else localStorage.setItem('cycle:' + args.key, args.value); }
        else if (cmd === 'store.keys') r = Object.keys(localStorage).filter((k) => k.indexOf('cycle:' + args.prefix) === 0).map((k) => k.slice(6));
        else if (cmd === 'notify.status') r = 'granted';
        else if (cmd === 'lock.get') r = false;
        else if (cmd === 'notify.permission') r = true;
        else if (!['ready', 'notify.schedule', 'notify.cancel', 'app.openSettings', 'haptic'].includes(cmd)) throw new Error('unexpected bridge cmd ' + cmd);
        setTimeout(() => window.__cycleReply(id, r, null), 0);
      } } } };
    }, { sd: sd || seed(ME) });
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (route) => route.abort());
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-a="go:fight"]');
    return { context, page };
  }
  const dump = async (page) => { await page.waitForTimeout(500); return page.evaluate(() => Object.fromEntries(Object.keys(localStorage).filter((k) => k.startsWith('cycle:')).map((k) => [k.slice(6), JSON.parse(localStorage.getItem(k))]))); };
  const rowsOf = async (page, who, t) => Object.values((await dump(page))['shared.' + who].rows[t]);
  const issues = async (page, who = ME) => (await rowsOf(page, who, 'items')).filter((i) => i.origin === 'issue');
  const shot = (page, name) => SHOTS && page.screenshot({ path: path.join(SHOTS, name) });


  test('Home pins Log fight and To <name> only; the composer opens on Do', async () => {
    const { context, page } = await open();
    const labels = await page.$$eval('.pin .row', (els) => els.map((e) => e.textContent.trim()));
    assert.deepEqual(labels, ['Log fight', 'To Alexandria Rae']);
    await page.click('.pin [data-a="toask"]');
    assert.equal(await page.textContent('.seg .on'), 'Do');
    assert.equal((await page.textContent('.dchip')).trim(), '+ Due', 'Do shows the ghost Due chip');
    const segW = () => page.$eval('.torow .seg', (e) => Math.round(e.getBoundingClientRect().width));
    const inRow = await page.evaluate(() => { const s = document.querySelector('.torow .seg').getBoundingClientRect(), c = document.querySelector('.dchip').getBoundingClientRect(); return [s.top, s.bottom, c.top, c.bottom]; });
    assert.deepEqual([inRow[0], inRow[1]], [inRow[2], inRow[3]], 'chip is as tall as the switch and on its row');
    const wDo = await segW();
    await page.click('[data-a="tokind:read"]');
    assert.equal(await page.isVisible('.dchip'), false, 'Read hides the Due chip');
    assert.equal(await segW(), wDo, 'the switch keeps its width in Read');
    await page.click('[data-a="back"]'); await page.click('.pin [data-a="toask"]');
    assert.equal(await page.textContent('.seg .on'), 'Do', 'Do again on every open');
    await context.close();
  });

  test('Due chip: a picked date shows in the chip, clear resets it, and the created task carries it', async () => {
    const { context, page } = await open();
    await page.click('.pin [data-a="toask"]');
    await page.fill('textarea[data-d="nbody"]', 'Book paintball');
    await page.fill('.dchip input[type=date]', '2026-11-14');
    await page.waitForFunction(() => document.querySelector('.dchip.on'));
    assert.equal((await page.textContent('.dchip .pv')).trim(), 'Due Sat 14 Nov');
    assert.equal(await page.inputValue('textarea[data-d="nbody"]'), 'Book paintball', 'text survives the date pick');
    await page.click('.dchip .dx');
    assert.equal((await page.textContent('.dchip')).trim(), '+ Due');
    await page.fill('.dchip input[type=date]', '2026-11-14');
    await page.waitForFunction(() => document.querySelector('.dchip.on'));
    await page.click('[data-a="toasksend"]');
    await page.waitForSelector('.pin');
    const todos = await rowsOf(page, ME, 'todos');
    assert.deepEqual([todos.length, todos[0].due_date, todos[0].owner_id], [1, '2026-11-14', HER]);
    await context.close();
  });

  test('the switch has one width in Do unset, Do set (longest label) and Read, at 375 and 430', async () => {
    for (const w of [375, 430]) {
      const { context, page } = await open();
      await page.setViewportSize({ width: w, height: 844 });
      await page.click('.pin [data-a="toask"]');
      const segW = () => page.$eval('.torow .seg', (e) => e.getBoundingClientRect().width);
      const chipFits = () => page.evaluate(() => { const c = document.querySelector('.dchip').getBoundingClientRect(), p = document.querySelector('.dcb .pv').getBoundingClientRect(), x = document.querySelector('.dx').getBoundingClientRect(); return p.left >= c.left && x.right <= c.right && p.right <= x.left; });
      const unset = await segW();
      await page.fill('.dchip input[type=date]', '2026-09-30');
      await page.waitForFunction(() => document.querySelector('.dchip.on'));
      assert.equal((await page.textContent('.dcb .pv')).trim(), 'Due Wed 30 Sep');
      assert.equal(await segW(), unset, w + ': set keeps the width');
      assert.ok(await chipFits(), w + ': longest label and cross fit the chip');
      await page.click('[data-a="tokind:read"]');
      assert.equal(await segW(), unset, w + ': Read keeps the width');
      await context.close();
    }
  });

  test('Send with Do creates a task for the partner', async () => {
    const { context, page } = await open();
    await page.click('.pin [data-a="toask"]');
    await page.fill('textarea[data-d="nbody"]', 'Book paintball');
    await page.click('[data-a="toasksend"]');
    await page.waitForSelector('.pin');
    const todos = await rowsOf(page, ME, 'todos'), items = await rowsOf(page, ME, 'items');
    assert.equal(todos.length, 1);
    assert.deepEqual([todos[0].title, todos[0].type, todos[0].owner_id, todos[0].created_by, todos[0].points_earn, todos[0].points_miss], ['Book paintball', 'task', HER, ME, 0, 0]);
    assert.deepEqual([items.length, items[0].kind, items[0].recipient_id], [1, 'ask', HER]);
    assert.equal((await rowsOf(page, ME, 'nudge_sends')).length, 0);
    await context.close();
  });

  test('Send with Read creates a reminder and sends it to the partner', async () => {
    const { context, page } = await open();
    await page.click('.pin [data-a="toask"]');
    await page.fill('textarea[data-d="nbody"]', 'Good day yesterday');
    await page.click('[data-a="tokind:read"]');
    assert.equal(await page.inputValue('textarea[data-d="nbody"]'), 'Good day yesterday');
    await page.click('[data-a="toasksend"]');
    await page.waitForSelector('.pin');
    const nudges = await rowsOf(page, ME, 'nudges'), sends = await rowsOf(page, ME, 'nudge_sends');
    assert.deepEqual([nudges.length, nudges[0].body], [1, 'Good day yesterday']);
    assert.deepEqual([sends.length, sends[0].nudge_id, sends[0].recipient_id, sends[0].sender_id], [1, nudges[0].id, HER, ME]);
    assert.equal((await rowsOf(page, ME, 'todos')).length, 0);
    await context.close();
  });
});

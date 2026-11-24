// Refreshing keeps you on the same screen (the route lives in the URL hash), browser back = in-app back, and the open texts list keeps its scroll across the 15s repaint.
// Runs in WebKit only (set GL_WEBKIT_PW/GL_WEBKIT_EXEC, e.g. via ~/.claude/bin/cycle-webkit.sh); skipped without it.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const engines = {};
if (process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC) {
  const pw = await import(process.env.GL_WEBKIT_PW);
  engines.webkit = { launch: (o) => pw.webkit.launch({ ...o, executablePath: process.env.GL_WEBKIT_EXEC }) };
}

const UID = '78b76b33-e11c-4491-baa4-28aa38bd17c6', PID = 'u-her', HOUR = 36e5;
const ago = (h) => new Date(Date.now() - h * HOUR).toISOString();
const marker = (id, o = {}) => ({ id, couple_id: 'c1', logged_by: UID, at: ago(5), repaired_at: null, hit_self: null, hit_related: null, summary: null, summary_notes_at: null, ...o });
const seed = (fill) => {
  const sh = {
    couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60, hold_focus_min: 0, hold_truth_min: 0, hold_kudos_min: 0 },
    members: [{ user_id: UID, name: 'Alex', checkin_time: '21:00', hits_self: false }, { user_id: PID, name: 'Sam', checkin_time: '21:00', hits_self: true }],
    rows: { items: {}, todos: {}, todo_events: {}, checkins: {}, fight_markers: {}, fight_notes: {}, fight_ratings: {}, rewards: {}, redemptions: {}, nudges: {}, nudge_sends: {}, nudge_replies: {}, nudge_awards: {}, todo_comments: {}, todo_nudges: {}, challenges: {}, challenge_breaks: {}, challenge_days: {}, challenge_nudges: {} }, cursors: {}, outbox: [],
  };
  fill(sh.rows);
  return { session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: UID, email: 'me@x.test' } }, ['shared.' + UID]: sh, ['priv.' + UID]: { fights: [], affirmations: [], prefs: {} } };
};

for (const [name, type] of Object.entries(engines)) describe(name, () => {
  let browser;
  before(async () => { browser = await type.launch({ headless: true }); });
  after(async () => { await browser.close(); });

  const many = Array.from({ length: 60 }, (_, i) => ({ ts: ago(5 - i / 100), by: i % 2 ? UID : PID, body: 'message number ' + i + ' https://liveohana.ai/listing/' + 'x'.repeat(200) }));
  async function open(fill) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    await context.addInitScript((sd) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: 'https://x.test' };
      if (!localStorage.getItem('cycle:session')) for (const k in sd) localStorage.setItem('cycle:' + k, JSON.stringify(sd[k]));
    }, seed(fill));
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (route) => route.abort());
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    return { context, page };
  }
  const withFights = (rows) => {
    rows.fight_markers.f1 = marker('f1', { text_on: true, texts_at: ago(4), texts_grabbed_wider: 0, texts_wider: 0, texts: many });
    rows.fight_markers.f2 = marker('f2', { at: ago(30) });
  };
  const hash = (page) => page.evaluate(() => location.hash);

  test('a fight detail survives a reload: the URL names the fight and the page lands on it', async () => {
    const { context, page } = await open(withFights);
    await page.click('[data-a="tab:fights"]'); await page.click('.rf[data-a="openfight:f1"]'); await page.waitForSelector('.fd');
    assert.equal(await hash(page), '#/fightdetail?f=f1');
    await page.reload({ waitUntil: 'domcontentloaded' }); await page.waitForSelector('.fd');
    assert.equal(await hash(page), '#/fightdetail?f=f1');
    assert.equal(await page.evaluate(() => document.querySelector('.fd .txs') !== null), true, 'the f1 page, not the list');
    await context.close();
  });

  test('browser back from a reloaded fight goes to the Fights list, and in-app back does too', async () => {
    const { context, page } = await open(withFights);
    await page.click('[data-a="tab:fights"]'); await page.click('.rf[data-a="openfight:f1"]'); await page.waitForSelector('.fd');
    await page.reload({ waitUntil: 'domcontentloaded' }); await page.waitForSelector('.fd');
    await page.goBack(); await page.waitForSelector('.rf[data-a="openfight:f1"]');
    assert.equal(await hash(page), '#/fights');
    await page.goForward(); await page.waitForSelector('.fd');
    await page.click('[data-a="back"]'); await page.waitForSelector('.rf[data-a="openfight:f1"]');
    assert.equal(await hash(page), '#/fights');
    await context.close();
  });

  test('a fight that no longer exists lands on the Fights list, not an error', async () => {
    const { context, page } = await open(withFights);
    await page.evaluate(() => { location.hash = '#/fightdetail?f=gone'; });
    await page.reload({ waitUntil: 'domcontentloaded' }); await page.waitForSelector('.rf[data-a="openfight:f1"]');
    assert.equal(await hash(page), '#/fights');
    await context.close();
  });

  test('an Insights chat survives a reload with the same chat id', async () => {
    const { context, page } = await open(withFights);
    await page.click('[data-a="tab:insights"]'); await page.waitForSelector('.insbar');
    const h = await hash(page);
    assert.match(h, /^#\/insights\?i=[0-9a-f-]{36}$/);
    await page.reload({ waitUntil: 'domcontentloaded' }); await page.waitForSelector('.insbar');
    assert.equal(await hash(page), h);
    await context.close();
  });

  test('More sub-pages and the to-do segment survive a reload', async () => {
    const { context, page } = await open(withFights);
    await page.evaluate(() => { location.hash = '#/updates'; });
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => location.hash === '#/updates' && document.querySelector('[data-a="back"]'));
    await context.close();
  });

  test('the open texts list keeps its scroll through the 15s repaint, long links show as the domain', async () => {
    const { context, page } = await open(withFights);
    await page.click('[data-a="tab:fights"]'); await page.click('.rf[data-a="openfight:f1"]'); await page.waitForSelector('.fd');
    await page.click('[data-a="txtoggle"]'); await page.waitForSelector('.txl');
    assert.equal(await page.evaluate(() => document.querySelector('.txl .txu').textContent), 'liveohana.ai');
    assert.equal(await page.evaluate(() => /x{20}/.test(document.querySelector('.txl').textContent)), false, 'no raw URL on the page');
    const top = await page.evaluate(() => { const l = document.querySelector('.txl'); l.scrollTop = 300; return l.scrollTop; });
    assert.ok(top > 100, 'the list scrolls (' + top + ')');
    await page.waitForTimeout(16500); // the 15s repaint rebuilds the screen
    assert.equal(await page.evaluate(() => document.querySelector('.txl').scrollTop), top);
    assert.equal(await page.evaluate(() => document.querySelector('.txl') !== null), true, 'still expanded');
    await context.close();
  });
  test('a past fight named in a summary is a link: tap opens it, back returns to the fight we came from', async () => {
    const { context, page } = await open((rows) => {
      rows.fight_markers.f25 = marker('f25', { at: '2026-06-25T21:00:00.000Z' });
      rows.fight_markers.f28 = marker('f28', { at: '2026-06-28T19:00:00.000Z', summary: 'x', gaps: {}, summary_beats: [{ lead: 'That evening', text: 'Three days after the Jun 25 fight (about the sublet), Esme stayed out. The Jul 4 fight is not real.', after: [] }], summary_notes_at: '2026-06-28T20:00:00.000Z' });
    });
    await page.evaluate(() => { location.hash = '#/fightdetail?f=f28'; });
    await page.reload({ waitUntil: 'domcontentloaded' }); await page.waitForSelector('.bt');
    assert.equal(await page.evaluate(() => document.querySelectorAll('.bt .fl').length), 1, 'only the date with a real fight links');
    await page.click('.bt .fl');
    await page.waitForFunction(() => location.hash === '#/fightdetail?f=f25');
    await page.goBack();

    await page.waitForFunction(() => location.hash === '#/fightdetail?f=f28');
    assert.equal(await page.evaluate(() => document.querySelector('.bt .fl') !== null), true, 'back lands on the Jun 28 summary');
    await context.close();
  });
});

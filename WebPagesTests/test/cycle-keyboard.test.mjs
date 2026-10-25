// Keyboard jerk: with a field focused, visualViewport 'scroll' events (iOS fires them while it reveals the
// caret) must not move anything; a visualViewport 'resize' (keyboard opening) must reveal the focused field
// by scrolling only .scr, never the window. Runs in Chromium, plus WebKit when GL_WEBKIT_PW/GL_WEBKIT_EXEC are set.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const engines = { chromium };
if (process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC) {
  const pw = await import(process.env.GL_WEBKIT_PW);
  engines.webkit = { launch: (o) => pw.webkit.launch({ ...o, executablePath: process.env.GL_WEBKIT_EXEC }) };
}

for (const [name, type] of Object.entries(engines)) describe(name, () => {
  let browser;
  before(async () => { browser = await type.launch({ headless: true }); });
  after(async () => { await browser.close(); });

  // Sign-in screen (no session, no native bridge) in a short phone viewport so .scr overflows.
  async function open() {
    const context = await browser.newContext({ viewport: { width: 390, height: 360 }, hasTouch: true });
    await context.addInitScript(() => { window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' }; });
    // The fixed full-screen #fx canvas crashes the software-GL WebKit build used on the dev box; it is irrelevant here.
    await context.route('**/cycle.css', (route) => route.fulfill({ contentType: 'text/css', body: CSS }));
    const page = await context.newPage();
    page.on('pageerror', (e) => { throw e; });
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('input[data-d=password]');
    await page.evaluate(() => {
      window.__sivCalls = 0;
      var orig = Element.prototype.scrollIntoView;
      Element.prototype.scrollIntoView = function () { window.__sivCalls++; return orig.apply(this, arguments); };
    });
    return { context, page };
  }
  const pos = (page) => page.evaluate(() => ({ scr: document.querySelector('.scr').scrollTop, win: window.scrollY, siv: window.__sivCalls }));

  test(`visualViewport scroll events with a focused field move nothing`, async () => {
    const { context, page } = await open();
    await page.focus('input[data-d=password]');
    await page.waitForTimeout(300); // let the browser's own focus-reveal scroll finish
    const max = await page.evaluate(() => { const s = document.querySelector('.scr'); return s.scrollHeight - s.clientHeight; });
    assert.ok(max > 20, 'precondition: .scr must overflow, got ' + max);
    await page.evaluate((y) => { document.querySelector('.scr').scrollTop = y; }, 5);
    await page.waitForTimeout(100);
    const before = await pos(page);
    for (let i = 0; i < 5; i++) {
      await page.evaluate(() => window.visualViewport.dispatchEvent(new Event('scroll')));
      await page.waitForTimeout(30);
    }
    assert.deepEqual(await pos(page), before);
    await context.close();
  });

  test(`visualViewport resize reveals a hidden focused field inside .scr only`, async () => {
    const { context, page } = await open();
    await page.focus('input[data-d=password]');
    await page.evaluate(() => { document.querySelector('.scr').scrollTop = 0; });
    // Keyboard opens: the visual viewport shrinks so the password field falls below the column.
    await page.evaluate(() => {
      Object.defineProperty(window.visualViewport, 'height', { configurable: true, get: () => 200 });
      window.visualViewport.dispatchEvent(new Event('resize'));
    });
    await page.waitForTimeout(50);
    const r = await page.evaluate(() => {
      const s = document.querySelector('.scr').getBoundingClientRect(), f = document.querySelector('input[data-d=password]').getBoundingClientRect();
      return { fTop: f.top, fBottom: f.bottom, sTop: s.top, sBottom: s.bottom, scr: document.querySelector('.scr').scrollTop, win: window.scrollY };
    });
    assert.ok(r.scr > 0, '.scr scrolled to reveal the field: ' + JSON.stringify(r));
    assert.ok(r.fTop >= r.sTop - 1 && r.fBottom <= r.sBottom + 1, 'field inside .scr visible rect: ' + JSON.stringify(r));
    assert.equal(r.win, 0);
    await context.close();
  });

  test(`visualViewport resize leaves an already visible field alone`, async () => {
    const { context, page } = await open();
    await page.focus('input[data-d=email]');
    await page.evaluate(() => { document.querySelector('.scr').scrollTop = 0; });
    await page.evaluate(() => window.visualViewport.dispatchEvent(new Event('resize')));
    await page.waitForTimeout(50);
    assert.deepEqual(await pos(page), { scr: 0, win: 0, siv: 0 });
    await context.close();
  });
});

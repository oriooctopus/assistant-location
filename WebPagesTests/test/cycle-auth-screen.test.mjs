// Sign-in screen (SCREEN.auth in CycleApp/web/cycle-ui.js), WebKit for WKWebView parity.
// 1. With the keyboard up the viewport shrinks; the Sign in / Create account stack used to be position:sticky and rode up
//    over the email and password fields. It must stay below the password field at any height.
// 2. The password field has a Show/Hide toggle that flips the input type and keeps what was typed.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const HAS_WK = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = HAS_WK ? await import(process.env.GL_WEBKIT_PW) : null;
const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';

describe('auth screen (webkit)', { skip: !HAS_WK && 'needs GL_WEBKIT_PW and GL_WEBKIT_EXEC' }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  // No seeded session, so the app boots to SCREEN.auth; every network call is aborted.
  async function open(height) {
    const ctx = await browser.newContext({ viewport: { width: 390, height }, hasTouch: true });
    await ctx.addInitScript(() => { window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' }; });
    await ctx.route('https://x.test/**', (r) => r.abort());
    // Same as the layout sweep: the animated #fx layer crashes headless WebKit's page process within seconds, so hide it.
    await ctx.clock.setFixedTime(new Date('2026-10-21T15:00:00Z'));
    await ctx.route('**/cycle.css', (r) => r.fulfill({ contentType: 'text/css', body: CSS }));
    const page = await ctx.newPage();
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-d="password"]');
    return { ctx, page };
  }
  const rect = (page, s) => page.$eval(s, (e) => { const r = e.getBoundingClientRect(); return { top: r.top, bottom: r.bottom }; });

  // 430px tall ~ an iPhone 14 with the keyboard and its accessory bar up.
  test('buttons never cover the fields when the keyboard shrinks the viewport', async () => {
    const { ctx, page } = await open(430);
    for (const field of ['email', 'password']) {
      await page.focus(`[data-d="${field}"]`);
      await page.waitForTimeout(200);
      const pr = await rect(page, '.au .pair'), pwd = await rect(page, '[data-d="password"]');
      assert.ok(pr.top >= pwd.bottom, `${field} focused: buttons top ${pr.top} is above password bottom ${pwd.bottom}`);
    }
    await ctx.close();
  });

  test('Show/Hide toggles the password visibility and keeps the text', async () => {
    const { ctx, page } = await open(844);
    await page.fill('[data-d="password"]', 'secret22');
    assert.equal(await page.getAttribute('[data-d="password"]', 'type'), 'password');
    await page.click('[data-a="pwshow"]');
    assert.equal(await page.getAttribute('[data-d="password"]', 'type'), 'text');
    assert.equal(await page.inputValue('[data-d="password"]'), 'secret22');
    assert.equal(await page.textContent('[data-a="pwshow"]'), 'Hide');
    await page.click('[data-a="pwshow"]');
    assert.equal(await page.getAttribute('[data-d="password"]', 'type'), 'password');
    await ctx.close();
  });
});

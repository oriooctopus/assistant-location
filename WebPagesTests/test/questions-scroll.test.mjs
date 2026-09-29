// questions.html on a scrolling page with a gradient theme (dusk): the
// background must be one continuous gradient, not the one-viewport gradient
// repeating down the page (Oliver: "when I scroll down enough the color
// changes in the background").
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { buildMockBridgeScript } from './mock-bridge.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PAGE_URL = 'file://' + path.join(HERE, '../../Modules/WebPages/questions.html');

let browser;
before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { await browser.close(); });

const DUSK_LIGHT = {
  bg: '#f6e8dc', surface: '#fbf5ef', text: '#382a52', 'text-dim': '#7d6f96', accent: '#7c4dcc', danger: '#c0392b',
  'bg-gradient': { angle: 165, stops: [{ color: '#fde5d0', position: 0 }, { color: '#ecd9f2', position: 0.48 }, { color: '#cfe3f6', position: 1 }] },
  'surface-translucent': 'rgba(255,255,255,0.55)', 'backdrop-blur': 'blur(12px)',
};

test('gradient background is continuous down a page taller than the viewport (no repeat seam)', async () => {
  const now = Date.now();
  const takeovers = Array.from({ length: 40 }, (_, i) => ({
    listing: 'L' + (i % 3), listingTitle: 'Listing ' + (i % 3), buyer: 'Buyer' + i, takenOverAt: null,
    lastMessageAt: new Date(now - i * 3600e3).toISOString(),
  }));
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript({
    boot: { palette: DUSK_LIGHT, mode: 'light', themeId: 'dusk', platform: 'ios', apiBase: 'http://x.test' },
    responses: { getApiToken: { token: 't' }, getPref: { value: true }, goBack: {} },
  }));
  const page = await context.newPage();
  await page.route('http://x.test/questions', (r) => r.fulfill({
    contentType: 'application/json', body: JSON.stringify({ questions: [], visits: [], pending: [], takeovers }),
  }));
  await page.goto(PAGE_URL);
  await page.waitForSelector('.t-row, .t-older, [data-buyer]', { timeout: 5000 }).catch(() => {});
  await page.waitForTimeout(300);
  const scrollH = await page.evaluate(() => document.documentElement.scrollHeight);
  assert.ok(scrollH > 844 * 2, 'fixture must scroll past two viewports, got ' + scrollH);
  const shot = await page.screenshot({ fullPage: true });
  // Sample the left gutter (2px in, clear of any row) down the whole page.
  const px = await page.evaluate(async (b64) => {
    const img = new Image(); img.src = 'data:image/png;base64,' + b64; await img.decode();
    const c = document.createElement('canvas'); c.width = img.width; c.height = img.height;
    const g = c.getContext('2d'); g.drawImage(img, 0, 0);
    const d = g.getImageData(2, 0, 1, img.height).data; const out = [];
    for (let y = 0; y < img.height; y++) out.push([d[y * 4], d[y * 4 + 1], d[y * 4 + 2]]);
    return out;
  }, shot.toString('base64'));
  let worst = 0, at = -1;
  for (let y = 1; y < px.length; y++) {
    const dlt = Math.max(...px[y].map((v, k) => Math.abs(v - px[y - 1][k])));
    if (dlt > worst) { worst = dlt; at = y; }
  }
  assert.ok(worst <= 3, `background jumps by ${worst} at y=${at} (${px[at - 1]} -> ${px[at]})`);
  await context.close();
});

// The page keeps itself fresh while open: /questions reloads every 30s while visible,
// on becoming visible, never two at once, and not at all while hidden.
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

async function open(handler) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript({
    boot: { mode: 'light', platform: 'ios', apiBase: 'http://x.test' },
    responses: { getApiToken: { token: 't' }, getPref: { value: true }, goBack: {} },
  }));
  const page = await context.newPage();
  await page.clock.install();
  const state = { count: 0 };
  await page.route('http://x.test/questions', (r) => { state.count++; return handler(r, state); });
  await page.goto(PAGE_URL);
  while (state.count < 1) await page.waitForTimeout(20);
  await page.waitForTimeout(100);
  return { page, state };
}
const ok = (r) => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ questions: [], visits: [], pending: [], takeovers: [] }) });
const setVisibility = (page, v) => page.evaluate((state) => {
  Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => state });
  document.dispatchEvent(new Event('visibilitychange'));
}, v);

test('reloads every 30s while visible, stops while hidden, reloads when visible again', async () => {
  const { page, state } = await open(ok);
  assert.equal(state.count, 1);
  await page.clock.runFor(30000);
  await page.waitForTimeout(100);
  assert.equal(state.count, 2);
  await setVisibility(page, 'hidden');
  await page.clock.runFor(90000);
  await page.waitForTimeout(100);
  assert.equal(state.count, 2);
  await setVisibility(page, 'visible');
  await page.waitForTimeout(100);
  assert.equal(state.count, 3);
});

test('a tick is skipped while a load is still in flight', async () => {
  const { page, state } = await open(() => new Promise(() => {}));
  assert.equal(state.count, 1);
  await page.clock.runFor(120000);
  await page.waitForTimeout(100);
  assert.equal(state.count, 1);
});

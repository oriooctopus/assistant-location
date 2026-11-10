// Back from a thread (button or left-edge swipe) restores the list's scroll
// offset; the edge swipe only fires from the left edge and only in a thread.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { buildMockBridgeScript } from './mock-bridge.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PAGE_URL = 'file://' + path.join(HERE, '../../Modules/WebPages/questions.html');
const SHOTS = process.env.GL_SHOTS; // optional dir for mid-swipe / restored screenshots

let browser;
before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { await browser.close(); });

const questions = Array.from({ length: 30 }, (_, i) => ({
  id: 'fb:' + i, source: 'facebook', title: 'Buyer' + i + ' · Item' + i, body: 'Message ' + i,
  createdAt: new Date(Date.now() - i * 3600e3).toISOString(),
  context: { listing: 'Item' + i, buyer: 'Buyer' + i, messages: ['Message ' + i] },
  answer: { endpoint: '/push/reply', payload: { category: 'FB_REPLY', data: { listing: 'Item' + i, buyer: 'Buyer' + i } } },
}));

async function open() {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  await context.addInitScript(buildMockBridgeScript({
    boot: { mode: 'dark', platform: 'ios', apiBase: 'http://x.test' },
    responses: { getApiToken: { token: 't' }, getPref: { value: true }, goBack: {} },
  }));
  const page = await context.newPage();
  await page.route('http://x.test/questions*', (r) => r.fulfill({
    contentType: 'application/json', body: JSON.stringify({ questions, visits: [], pending: [], takeovers: [] }),
  }));
  await page.goto(PAGE_URL);
  await page.waitForSelector('.q-item');
  return page;
}

// Scroll the list, open the row under y=300, return the saved offset.
async function openDeepThread(page) {
  await page.evaluate(() => window.scrollTo(0, 900));
  await page.waitForTimeout(100);
  const saved = await page.evaluate(() => window.scrollY);
  assert.ok(saved > 500, 'list must be scrolled, got ' + saved);
  await page.mouse.click(200, 300);
  await page.waitForSelector('#q-answer:not(.gl-hidden)');
  assert.equal(await page.evaluate(() => window.scrollY), 0, 'thread opens at top');
  return saved;
}

// Synthetic touch (the page reads only touches/changedTouches), same as questions-swipe.
const touch = (page, type, x, y) => page.evaluate(([type, x, y]) => {
  const target = document.elementFromPoint(Math.max(x, 1), y) || document.body;
  const ev = new Event(type, { bubbles: true, cancelable: true });
  const t = [{ identifier: 0, target, clientX: x, clientY: y }];
  ev.touches = type === 'touchend' ? [] : t; ev.changedTouches = t;
  return target.dispatchEvent(ev);
}, [type, x, y]);
async function swipe(page, x0, dx, y = 400) {
  await touch(page, 'touchstart', x0, y);
  for (let i = 1; i <= 6; i++) { await touch(page, 'touchmove', x0 + dx * i / 6, y); await page.waitForTimeout(16); }
  await touch(page, 'touchend', x0 + dx, y);
  await page.waitForTimeout(300);
}
const listShown = (page) => page.evaluate(() => !document.getElementById('q-list').classList.contains('gl-hidden'));
const near = (a, b) => Math.abs(a - b) <= 1;

test('A: Back button restores the list scroll offset', async () => {
  const page = await open();
  const saved = await openDeepThread(page);
  await page.click('#q-back');
  assert.ok(await listShown(page));
  const now = await page.evaluate(() => window.scrollY);
  assert.ok(near(now, saved), `expected ${saved}, got ${now}`);
  if (SHOTS) await page.screenshot({ path: SHOTS + '/list-restored.png' });
});

test('B: left-edge swipe goes back and restores the offset; mid-swipe the panel follows the finger', async () => {
  const page = await open();
  const saved = await openDeepThread(page);
  await touch(page, 'touchstart', 5, 400);
  for (let i = 1; i <= 4; i++) await touch(page, 'touchmove', 5 + i * 25, 400);
  const tx = await page.evaluate(() => new DOMMatrixReadOnly(getComputedStyle(document.getElementById('q-answer')).transform).m41);
  assert.ok(tx > 80, 'panel follows finger, got ' + tx);
  if (SHOTS) await page.screenshot({ path: SHOTS + '/swipe-mid.png' });
  await touch(page, 'touchend', 105, 400);
  await page.waitForTimeout(300);
  assert.ok(await listShown(page));
  const now = await page.evaluate(() => window.scrollY);
  assert.ok(near(now, saved), `expected ${saved}, got ${now}`);
});

test('B2: a short edge drag snaps back and stays in the thread', async () => {
  const page = await open();
  await openDeepThread(page);
  await touch(page, 'touchstart', 5, 400);
  await touch(page, 'touchmove', 25, 400);
  await touch(page, 'touchmove', 45, 400);
  await page.waitForTimeout(500); // past the flick window
  await touch(page, 'touchend', 45, 400);
  await page.waitForTimeout(300);
  assert.equal(await listShown(page), false);
  assert.equal(await page.evaluate(() => document.getElementById('q-answer').style.transform), '');
});

test('C: a swipe starting away from the edge does not go back; edge swipe on the list does nothing', async () => {
  const page = await open();
  await openDeepThread(page);
  await swipe(page, 200, 150);
  assert.equal(await listShown(page), false);
  await page.click('#q-back');
  assert.ok(await listShown(page));
  await swipe(page, 5, 200);
  assert.ok(await listShown(page));
  assert.equal(await page.locator('#q-answer.gl-hidden').count(), 1);
});

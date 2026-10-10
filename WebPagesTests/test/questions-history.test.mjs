// The Reply screen shows the whole chat (both sides), newest at the bottom,
// not only the unanswered buyer text.
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

const Q = {
  id: 'fb:1', source: 'facebook', title: 'Omari · Print', body: 'Friday works?', createdAt: new Date().toISOString(),
  context: { listing: 'Print', buyer: 'Omari', messages: ['Friday works?'] },
  messages: [
    { from: 'buyer', text: 'Is this available?', time: null },
    { from: 'you', text: 'Yes! When works?', time: null },
  ],
  approximate: false,
  answer: { endpoint: '/push/reply', payload: { category: 'FB_REPLY', data: { listing: 'Print', buyer: 'Omari' } } },
};

test('reply screen lists full history, adds the newest unrecorded message once', async () => {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript({
    boot: { mode: 'light', platform: 'ios', apiBase: 'http://x.test' },
    responses: { getApiToken: { token: 't' }, getPref: { value: true }, goBack: {} },
  }));
  const page = await context.newPage();
  await page.route('http://x.test/questions', (r) => r.fulfill({
    contentType: 'application/json', body: JSON.stringify({ questions: [Q], visits: [], pending: [], takeovers: [] }),
  }));
  await page.goto(PAGE_URL);
  await page.waitForSelector('.q-item');
  await page.click('.q-item');
  await page.waitForSelector('#q-answer:not(.gl-hidden)');
  const msgs = await page.$$eval('#q-a-earlier .t-msg', (els) => els.map((e) => [e.className.replace('t-msg ', ''), e.textContent]));
  assert.deepEqual(msgs, [['buyer', 'Is this available?'], ['you', 'Yes! When works?'], ['buyer', 'Friday works?']]);
  assert.equal(await page.isHidden('#q-a-body'), true);
});

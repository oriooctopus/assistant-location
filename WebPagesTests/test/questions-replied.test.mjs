// Sending a reply from the Facebook page shows it at once under "Replied"
// (Oliver: "it should optimistically update"), and takes it back if the
// server refuses it.
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
  id: 'fb:1', source: 'facebook', title: 'Omari · Print', body: 'Friday?', createdAt: new Date().toISOString(),
  context: { listing: 'Print', buyer: 'Omari', messages: ['Friday?'] },
  answer: { endpoint: '/push/reply', payload: { category: 'FB_REPLY', data: { listing: 'Print', buyer: 'Omari' } } },
};

async function open(replyStatus) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript({
    boot: { mode: 'light', platform: 'ios', apiBase: 'http://x.test' },
    responses: { getApiToken: { token: 't' }, getPref: { value: true }, goBack: {} },
  }));
  const page = await context.newPage();
  await page.route('http://x.test/questions', (r) => r.fulfill({
    contentType: 'application/json', body: JSON.stringify({ questions: [Q], visits: [], pending: [], takeovers: [] }),
  }));
  await page.route('http://x.test/push/reply', (r) => r.fulfill({ status: replyStatus, body: 'x' }));
  await page.goto(PAGE_URL);
  await page.waitForSelector('.q-item');
  return page;
}

const sections = (page) => page.$$eval('.q-section', (els) => els.map((e) => e.textContent));

test('a sent reply appears under Replied immediately', async () => {
  const page = await open(200);
  await page.click('.q-item');
  await page.fill('#q-text', 'All good, when Friday?');
  await page.click('#q-send');
  assert.ok((await sections(page)).includes('Replied'));
  assert.match(await page.textContent('.q-item'), /Omari · Print[\s\S]*You: All good, when Friday\?/);
  assert.equal((await sections(page)).includes('Questions'), false);
});

test('a reply the server rejects leaves Replied and returns to Questions', async () => {
  const page = await open(500);
  await page.click('.q-item');
  await page.fill('#q-text', 'nope');
  await page.click('#q-send');
  await page.waitForFunction(() => !document.body.textContent.includes('You: nope'));
  const s = await sections(page);
  assert.ok(s.includes('Questions') && !s.includes('Replied'), JSON.stringify(s));
});

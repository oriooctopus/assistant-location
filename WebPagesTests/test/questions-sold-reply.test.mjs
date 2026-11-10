// Reply screen Sold button.
// (header) the bot escalated and tappable instructions to it;
// a chip or typed instruction POSTs /questions/instruct and the question leaves the list.
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
  id: 'fb:diego', source: 'facebook', title: 'Diego · SIIPRO Smartwatch, Black', body: 'Hola, puedo recogerlo mañana lunes?', createdAt: new Date().toISOString(),
  context: { listing: 'SIIPRO Smartwatch, Black', buyer: 'Diego', messages: ['Hola, puedo recogerlo mañana lunes?'] },
  reason: 'Monday is already booked for this item (Daniel 11:00)',
  actions: ['Offer Wednesday', 'Book Monday 2pm anyway', 'Tell him it is spoken for'],
  messages: null, approximate: false,
  answer: { endpoint: '/push/reply', payload: { category: 'FB_REPLY', data: { listing: 'SIIPRO Smartwatch, Black', buyer: 'Diego' } } },
};

async function open(q, posts) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript({
    boot: { mode: 'light', platform: 'ios', apiBase: 'http://x.test' },
    responses: { getApiToken: { token: 't' }, getPref: { value: true }, goBack: {} },
  }));
  const page = await context.newPage();
  await page.route('http://x.test/listings/sold', (r) => { posts.push(JSON.parse(r.request().postData())); r.fulfill({ contentType: 'application/json', body: '{"ok":true}' }); });
  await page.route('http://x.test/questions/instruct', (r) => { posts.push(JSON.parse(r.request().postData())); r.fulfill({ contentType: 'application/json', body: '{"result":"ok"}' }); });
  await page.route('http://x.test/questions?*', (r) => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ questions: [q], visits: [], pending: [], takeovers: [] }) }));
  await page.route('http://x.test/questions', (r) => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ questions: [q], visits: [], pending: [], takeovers: [] }) }));
  await page.goto(PAGE_URL);
  await page.waitForSelector('.q-item');
  await page.click('.q-item');
  await page.waitForSelector('#q-answer:not(.gl-hidden)');
  return page;
}


test('Sold to <buyer>: first tap arms, second POSTs /listings/sold and returns to list', async () => {
  const posts = [];
  const page = await open(Q, posts);
  assert.equal(await page.textContent('#q-sold'), 'Sold to Diego');
  await page.click('#q-sold');
  assert.equal(posts.length, 0);
  assert.match(await page.textContent('#q-sold'), /Tap again/);
  if (process.env.SHOT) await page.screenshot({ path: process.env.SHOT });
  await page.click('#q-sold');
  await page.waitForFunction(() => document.getElementById('q-answer').classList.contains('gl-hidden'));
  assert.deepEqual(posts, [{ listing: Q.context.listing, buyer: 'Diego' }]);
});

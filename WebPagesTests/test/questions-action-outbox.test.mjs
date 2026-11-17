// instruct / send-back / dismiss go through the durable outbox: queued before the
// network call, replayed after a reload, timeout counts as 'network', HTTP rejection
// reverts, and a queue stuck for a minute says so.
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
  id: 'fb:diego', source: 'facebook', title: 'Diego · Watch', body: 'Manana?', createdAt: new Date().toISOString(),
  context: { listing: 'Watch', buyer: 'Diego', messages: ['Manana?'] },
  reason: null, actions: ['Offer Wednesday'], messages: null, approximate: false,
  answer: { endpoint: '/push/reply', payload: { category: 'FB_REPLY', data: { listing: 'Watch', buyer: 'Diego' } } },
};
const LIST = JSON.stringify({ questions: [Q], visits: [], pending: [], takeovers: [] });

// handler(route) decides what /questions/instruct does; the list always loads.
async function open(handler, opts = {}) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript({
    boot: { mode: 'light', platform: 'ios', apiBase: 'http://x.test' },
    responses: { getApiToken: { token: 't' }, getPref: { value: true }, goBack: {} },
  }));
  const page = await context.newPage();
  if (opts.clock) await page.clock.install();
  await page.route('http://x.test/questions/instruct', handler);
  await page.route('http://x.test/questions?*', (r) => r.fulfill({ contentType: 'application/json', body: LIST }));
  await page.route('http://x.test/questions', (r) => r.fulfill({ contentType: 'application/json', body: LIST }));
  await page.goto(PAGE_URL);
  await page.waitForSelector('.q-item');
  return { page, context };
}
const hangs = () => new Promise(() => {});
const ok = (r) => r.fulfill({ contentType: 'application/json', body: '{"result":"ok"}' });
const outboxLen = (page) => page.evaluate(() => JSON.parse(localStorage.getItem('gl.questions.outbox') || '[]').length);
async function chip(page) {
  await page.click('.q-item');
  await page.waitForSelector('#q-answer:not(.gl-hidden)');
  await page.click('#q-chips button');
}

test('a chip tap is in the outbox before the network answers, question hidden', async () => {
  const { page } = await open(hangs);
  await chip(page);
  assert.equal(await outboxLen(page), 1);
  assert.equal(await page.$$eval('.q-item', (e) => e.length), 0);
});

test('a hanging request is aborted after 15s, stays queued, and is replayed after a reload', async () => {
  const { page, context } = await open(hangs, { clock: true });
  await chip(page);
  await page.clock.fastForward(16000);
  assert.equal(await outboxLen(page), 1, 'timeout is network: still queued');
  const posts = [];
  await page.unroute('http://x.test/questions/instruct');
  await page.route('http://x.test/questions/instruct', (r) => { posts.push(JSON.parse(r.request().postData())); ok(r); });
  await page.reload();
  await page.waitForFunction(() => JSON.parse(localStorage.getItem('gl.questions.outbox') || '[]').length === 0);
  assert.deepEqual(posts, [{ listing: 'Watch', buyer: 'Diego', instruction: 'Offer Wednesday' }]);
  assert.equal(await page.$$eval('.q-item', (e) => e.length), 0, 'acted question stays hidden');
  await context.close();
});

test('a 4xx rejection removes it from the outbox, puts the question back and shows the error', async () => {
  const { page } = await open((r) => r.fulfill({ status: 404, body: 'no pending question' }));
  await chip(page);
  await page.waitForSelector('#q-error:not(.gl-hidden)');
  assert.match(await page.textContent('#q-error-text'), /Couldn't tell the AI: HTTP 404/);
  assert.equal(await outboxLen(page), 0);
  assert.equal(await page.$$eval('.q-item', (e) => e.length), 1);
});

test('still unsent after a minute shows the retrying banner', async () => {
  const { page } = await open(hangs, { clock: true });
  await chip(page);
  await page.clock.fastForward(61000);
  assert.match(await page.textContent('#q-error-text'), /Not sent yet, retrying/);
  assert.equal(await outboxLen(page), 1);
});

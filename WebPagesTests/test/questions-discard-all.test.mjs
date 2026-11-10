// "Discard all" on the Facebook page: two-tap confirm, one POST with exactly the
// shown items, and a stale /questions payload (fetched before the tap) must not
// bring a discarded question back.
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

const mk = (n, createdAt = '2026-11-01T10:00:00.000Z') => ({
  id: 'fb:' + n, source: 'facebook', title: 'Buyer' + n + ' · Lamp', body: 'still here?', createdAt,
  context: { listing: 'Lamp', buyer: 'Buyer' + n, messages: ['still here?'] },
  answer: { endpoint: '/push/reply', payload: { category: 'FB_REPLY', data: { listing: 'Lamp', buyer: 'Buyer' + n } } },
});
const payload = (questions) => ({ questions, visits: [], pending: [], takeovers: [] });

async function open(questions, dismissStatus = 200) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript({
    boot: { mode: 'light', platform: 'ios', apiBase: 'http://x.test' },
    responses: { getApiToken: { token: 't' }, getPref: { value: true }, goBack: {} },
  }));
  const page = await context.newPage();
  const posts = [];
  await page.route('http://x.test/questions/dismiss-all', (r) => {
    posts.push(JSON.parse(r.request().postData()));
    r.fulfill({ status: dismissStatus, contentType: 'application/json', body: '{"result":"ok","dismissed":2}' });
  });
  await page.route(/^http:\/\/x\.test\/questions(\?.*)?$/, (r) => r.fulfill({ contentType: 'application/json', body: JSON.stringify(payload(questions)) }));
  await page.goto(PAGE_URL);
  await page.waitForSelector('.q-item');
  return { page, posts };
}
const count = (page) => page.$$eval('.q-item[data-id]', (e) => e.length);

test('Discard all is hidden with one question', async () => {
  const { page } = await open([mk(1)]);
  assert.equal(await page.$('.q-disc-all'), null);
});

test('Discard all: first tap arms, second removes all, one POST with the shown items, stale payload does not restore them', async () => {
  const { page, posts } = await open([mk(1), mk(2)]);
  const box = await (await page.$('.q-disc-all')).boundingBox();
  assert.ok(box.height >= 44 && box.width >= 44, JSON.stringify(box));
  await page.click('.q-disc-all');
  assert.equal(await page.textContent('.q-disc-all'), 'Discard 2?');
  assert.equal(await count(page), 2);
  // A double-tap must not confirm: the second tap inside 400ms is ignored.
  await page.click('.q-disc-all');
  assert.equal(await count(page), 2);
  assert.equal(posts.length, 0);
  await page.waitForTimeout(450);
  await page.click('.q-disc-all');
  await page.waitForFunction(() => !document.querySelector('.q-item[data-id]'));
  assert.match(await page.textContent('#q-toast-msg'), /Discarded 2/);
  assert.deepEqual(posts, [{ items: [{ listing: 'Lamp', buyer: 'Buyer1' }, { listing: 'Lamp', buyer: 'Buyer2' }] }]);
  // A fetch that began before the tap returns the old list.
  await page.evaluate((p) => window.applyQuestions(p), payload([mk(1), mk(2)]));
  assert.equal(await count(page), 0, 'stale payload brought them back');
  // A newer buyer message (new createdAt) shows again.
  await page.evaluate((p) => window.applyQuestions(p), payload([mk(1, '2026-11-02T10:00:00.000Z')]));
  assert.equal(await count(page), 1);
  // Server caught up: entry pruned, so the same id with the old createdAt is shown again.
  await page.evaluate((p) => window.applyQuestions(p), payload([]));
  await page.evaluate((p) => window.applyQuestions(p), payload([mk(2)]));
  assert.equal(await count(page), 1);
});

test('an armed Discard all reverts after ~4s without a POST', async () => {
  const { page, posts } = await open([mk(1), mk(2)]);
  await page.click('.q-disc-all');
  await page.waitForFunction(() => document.querySelector('.q-disc-all').textContent === 'Discard all', null, { timeout: 6000 });
  assert.equal(posts.length, 0);
});

test('a rejected Discard all puts the questions back', async () => {
  const { page } = await open([mk(1), mk(2)], 500);
  await page.click('.q-disc-all');
  await page.waitForTimeout(450);
  await page.click('.q-disc-all');
  await page.waitForFunction(() => document.querySelectorAll('.q-item[data-id]').length === 2);
  assert.equal(await page.evaluate(() => localStorage.getItem('gl.questions.acted')), '{}');
});

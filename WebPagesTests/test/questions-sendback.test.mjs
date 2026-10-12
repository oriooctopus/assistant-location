// "Send back to AI" on the Facebook reply screen: the question leaves the list at
// once, POSTs {listing, buyer} to /questions/send-back with the bearer token, and
// comes back (with an error banner) when the server refuses or is unreachable.
// Also pins the redesigned list's layout: waiting-on-a-time slot chips, tap targets.
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
const tomorrow = new Date(Date.now() + 86400e3); tomorrow.setHours(9, 0, 0, 0);
const later = new Date(Date.now() + 3 * 86400e3); later.setHours(17, 30, 0, 0);

async function open(sendBackOutcome) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript({
    boot: { mode: 'light', platform: 'ios', apiBase: 'http://x.test' },
    responses: { getApiToken: { token: 'tok' }, goBack: {} },
  }));
  const page = await context.newPage();
  const posts = [];
  await page.route('http://x.test/questions', (r) => r.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ questions: [Q], visits: [], pending: [{ listing: 'Desk', buyer: 'Marcus', offered: [tomorrow.toISOString(), later.toISOString()] }], takeovers: [] }),
  }));
  await page.route('http://x.test/questions/send-back', (r) => {
    posts.push({ body: r.request().postData(), auth: r.request().headers()['authorization'] });
    if (sendBackOutcome === 'network') return r.abort('connectionrefused');
    return r.fulfill({ status: sendBackOutcome, contentType: 'application/json', body: JSON.stringify({ result: 'ok' }) });
  });
  await page.goto(PAGE_URL);
  await page.waitForSelector('.q-item');
  return { page, posts };
}

const heads = (page) => page.$$eval('.q-head', (els) => els.map((e) => e.textContent));

test('Send back to AI removes the question, toasts, and POSTs listing+buyer with auth', async () => {
  const { page, posts } = await open(200);
  await page.click('.q-tap');
  assert.equal(await page.textContent('.q-helper'), 'Tells the bot it should answer this itself');
  await page.click('#q-sendback');
  assert.equal(await page.isVisible('#q-list'), true);
  assert.equal((await heads(page)).some((h) => h.startsWith('Questions')), false);
  assert.equal(await page.textContent('#q-toast-msg'), 'Sent back to AI');
  assert.equal(await page.isHidden('#q-undo'), true);
  for (let i = 0; i < 100 && posts.length === 0; i++) await page.waitForTimeout(20);
  assert.equal(posts.length, 1, 'no POST to /questions/send-back');
  assert.deepEqual(JSON.parse(posts[0].body), { listing: 'Print', buyer: 'Omari' });
  assert.equal(posts[0].auth, 'Bearer tok');
});

for (const outcome of [500, 'network']) {
  test(`Send back to AI restores the question and shows an error on ${outcome}`, async () => {
    const { page } = await open(outcome);
    await page.click('.q-tap');
    await page.click('#q-sendback');
    await page.waitForFunction(() => !document.getElementById('q-error').classList.contains('gl-hidden'));
    assert.match(await page.textContent('#q-error-text'), /^Couldn't send back: /);
    assert.equal(await page.locator('.q-item.q-tap').count(), 1);
    assert.ok((await heads(page)).some((h) => h.startsWith('Questions')));
  });
}

test('waiting-on-a-time shows one chip per slot with Tomorrow wording, and tap targets are >= 44px', async () => {
  const { page } = await open(200);
  const chips = await page.$$eval('.o-chip', (els) => els.map((e) => e.textContent));
  assert.equal(chips.length, 2);
  assert.match(chips[0], /^Tomorrow 9:00\s?AM$/);
  assert.match(await page.textContent('.o-status'), /Offered 2 times, no reply yet/);
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), 'no horizontal overflow');
  await page.click('.q-tap');
  for (const sel of ['#q-send', '#q-sendback', '#q-back']) {
    const h = await page.$eval(sel, (e) => e.getBoundingClientRect().height);
    assert.ok(h >= 44, `${sel} is ${h}px tall`);
  }
});

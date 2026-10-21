// The standalone Marketplace app prefetches /questions on a background push and
// hands it to the page (window.applyQuestions) before openQuestion, so a tapped
// notification shows the buyer's thread even while the live fetch is slow or down.
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
  context: { listing: 'Print', buyer: 'Omari', messages: ['Is it still available?', 'Friday?'] },
  answer: { endpoint: '/push/reply', payload: { category: 'FB_REPLY', data: { listing: 'Print', buyer: 'Omari' } } },
};
const PAYLOAD = { questions: [Q], visits: [], pending: [], takeovers: [] };

async function open(liveFetch) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript({
    boot: { mode: 'light', platform: 'ios', apiBase: 'http://x.test' },
    responses: { getApiToken: { token: 't' }, getPref: { value: true }, goBack: {} },
  }));
  const page = await context.newPage();
  await page.route('http://x.test/questions*', liveFetch);
  await page.goto(PAGE_URL);
  return page;
}

for (const [name, liveFetch] of [
  ['hangs', () => new Promise(() => {})],
  ['fails', (r) => r.fulfill({ status: 500, body: 'x' })],
]) {
  test(`applyQuestions then openQuestion shows the thread while the live /questions ${name}`, async () => {
    const page = await open(liveFetch);
    await page.evaluate((p) => { window.applyQuestions(p); window.openQuestion({ listing: 'Print', buyer: 'Omari' }); }, PAYLOAD);
    assert.equal(await page.isVisible('#q-answer'), true);
    assert.match(await page.textContent('#q-a-earlier'), /Is it still available\?/);
    assert.equal(await page.textContent('#q-a-to'), 'Omari');
  });
}

test('applyQuestions writes the saved copy used by the next cold load', async () => {
  const page = await open(() => new Promise(() => {}));
  await page.evaluate((p) => window.applyQuestions(p), PAYLOAD);
  assert.equal(JSON.parse(await page.evaluate(() => localStorage.getItem('gl.questions.cache'))).questions[0].id, 'fb:1');
  await page.waitForSelector('.q-item');
});

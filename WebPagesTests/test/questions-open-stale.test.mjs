// A notification tap while the page is already loaded (app backgrounded, then
// foregrounded) arrives before the foreground refresh returns. The page's list is
// fresh but predates the tapped question; openQuestion must fetch and then open the
// thread, not fall back to the list.
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

const mk = (id, listing, buyer) => ({
  id, source: 'facebook', title: `${buyer} · ${listing}`, body: 'Can I come now?', createdAt: new Date().toISOString(),
  context: { listing, buyer, messages: ['Can I come now?'] },
  answer: { endpoint: '/push/reply', payload: { category: 'FB_REPLY', data: { listing, buyer } } },
});
const OLD = mk('fb:1', 'Print', 'Omari');
const TITLE = 'Sceptre P30 30" monitor';
const NEW = mk('fb:2', TITLE, 'Flossy');
const payload = (qs) => ({ questions: qs, visits: [], pending: [], takeovers: [] });

async function open(serve) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.addInitScript(buildMockBridgeScript({
    boot: { mode: 'light', platform: 'ios', apiBase: 'http://x.test' },
    responses: { getApiToken: { token: 't' }, getPref: { value: true }, goBack: {} },
  }));
  const page = await context.newPage();
  let served = 0;
  await page.route('http://x.test/questions*', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(serve(served++)) }));
  await page.goto(PAGE_URL);
  await page.waitForSelector('.q-item');
  return page;
}

test('tap for a question newer than the fresh list fetches and opens it', async () => {
  const page = await open((n) => payload(n === 0 ? [OLD] : [OLD, NEW]));
  await page.evaluate((t) => window.openQuestion({ listing: t, buyer: 'Flossy' }), TITLE);
  await page.waitForSelector('#q-answer:not(.gl-hidden)');
  assert.equal(await page.textContent('#q-a-to'), 'Flossy');
});

test('tap for a question the server no longer has falls back to the list', async () => {
  const page = await open(() => payload([OLD]));
  await page.evaluate(() => window.openQuestion({ listing: 'Gone', buyer: 'Nobody' }));
  await page.waitForFunction(() => document.getElementById('q-answer').classList.contains('gl-hidden'));
  assert.equal(await page.isVisible('.q-item'), true);
});

test('a thread opened by a tap survives a page reload (page-cache update)', async () => {
  const page = await open(() => payload([OLD, NEW]));
  await page.evaluate((t) => window.openQuestion({ listing: t, buyer: 'Flossy' }), TITLE);
  await page.waitForSelector('#q-answer:not(.gl-hidden)');
  await page.reload();
  await page.waitForSelector('#q-answer:not(.gl-hidden)');
  assert.equal(await page.textContent('#q-a-to'), 'Flossy');
});

test('a tap still waiting on its fetch survives a page reload', async () => {
  const page = await open((n) => payload(n === 0 ? [OLD] : [OLD, NEW]));
  let tapFetch;
  const seen = new Promise((resolve) => { tapFetch = resolve; });
  // The tap's fetch never answers, so the only record of the tap is what the reload can read back.
  await page.route('http://x.test/questions*', () => tapFetch(), { times: 1 });
  await page.evaluate((t) => window.openQuestion({ listing: t, buyer: 'Flossy' }), TITLE);
  await seen;
  await page.reload();
  await page.waitForSelector('#q-answer:not(.gl-hidden)');
  assert.equal(await page.textContent('#q-a-to'), 'Flossy');
});

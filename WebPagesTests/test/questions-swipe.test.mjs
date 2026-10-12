// Swipe-to-reveal actions on the Facebook page (iOS Mail style), plus the reply
// draft surviving a reload. Runs in Chromium always, and in WebKit too when
// GL_WEBKIT_PW (path to a playwright-core index.mjs whose protocol matches the
// installed WebKit build) and GL_WEBKIT_EXEC (its pw_run.sh) are set -- the
// phone's WKWebView is WebKit, and Chromium hides iOS-only issues.
// Touches are synthetic touchstart/move/end events dispatched on the element
// under the finger, which is all the page's handlers read.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { buildMockBridgeScript } from './mock-bridge.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PAGE_URL = 'file://' + path.join(HERE, '../../Modules/WebPages/questions.html');

const engines = { chromium };
if (process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC) {
  const pw = await import(process.env.GL_WEBKIT_PW);
  engines.webkit = { launch: (o) => pw.webkit.launch({ ...o, executablePath: process.env.GL_WEBKIT_EXEC }) };
}

const Q = {
  id: 'fb:1', source: 'facebook', title: 'Omari · Print', body: 'Friday?', createdAt: new Date().toISOString(),
  context: { listing: 'Print', buyer: 'Omari', messages: ['Friday?'] },
  answer: { endpoint: '/push/reply', payload: { category: 'FB_REPLY', data: { listing: 'Print', buyer: 'Omari' } } },
};
const soon = new Date(Date.now() + 86400e3).toISOString();
const was = new Date(Date.now() - 2 * 86400e3).toISOString();
const DATA = {
  questions: [Q],
  visits: [{ listing: 'Lamp', buyer: 'Dana', pickupAt: soon }, { listing: 'Chair', buyer: 'Rosa', pickupAt: was, past: true }],
  pending: [{ listing: 'Desk', buyer: 'Marcus', offered: [soon] }],
  takeovers: [],
};

for (const [name, type] of Object.entries(engines)) {
  let browser;
  before(async () => { browser = browser || await type.launch({ headless: true }); });
  after(async () => { await browser.close(); });

  async function open(routes = {}, data = DATA, ready = '.sw') {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
    await context.addInitScript(buildMockBridgeScript({
      boot: { mode: 'light', platform: 'ios', apiBase: 'http://x.test' },
      responses: { getApiToken: { token: 'tok' }, goBack: {} },
    }));
    const page = await context.newPage();
    const posts = [];
    await page.route('http://x.test/questions', (r) => r.fulfill({ contentType: 'application/json', body: JSON.stringify(data) }));
    for (const p of ['/questions/send-back', '/questions/dismiss', '/visits/delete', '/listings/sold']) {
      await page.route('http://x.test' + p, (r) => {
        posts.push({ url: p, body: JSON.parse(r.request().postData()), auth: r.request().headers()['authorization'] });
        const o = routes[p] || 200;
        if (o === 'network') return r.abort('connectionrefused');
        return r.fulfill({ status: o, contentType: 'application/json', body: JSON.stringify({ result: 'ok' }) });
      });
    }
    await page.goto(PAGE_URL);
    await page.waitForSelector(ready);
    return { page, posts };
  }

  // One touch gesture on the nth .sw row; returns whether any touchmove was preventDefault()ed.
  async function drag(page, nth, dx, dy = 0) {
    const box = await page.locator('.sw').nth(nth).boundingBox();
    return page.evaluate(async ([x0, y0, dx, dy]) => {
      const target = document.elementFromPoint(x0, y0);
      const fire = (type, x, y) => {
        const ev = new Event(type, { bubbles: true, cancelable: true });
        const t = [{ identifier: 0, target, clientX: x, clientY: y }];
        ev.touches = type === 'touchend' ? [] : t; ev.changedTouches = t;
        return target.dispatchEvent(ev);
      };
      let prevented = false;
      fire('touchstart', x0, y0);
      for (let i = 1; i <= 8; i++) { if (!fire('touchmove', x0 + dx * i / 8, y0 + dy * i / 8)) prevented = true; await new Promise((r) => setTimeout(r, 16)); }
      fire('touchend', x0 + dx, y0 + dy);
      await new Promise((r) => setTimeout(r, 300));
      return prevented;
    }, [box.x + box.width / 2, box.y + box.height / 2, dx, dy]);
  }
  const isOpen = (page, nth) => page.locator('.sw').nth(nth).evaluate((e) => e.classList.contains('open'));
  const action = (page, label) => page.locator('.sw.open .sw-btn', { hasText: label }).click();
  const until = async (fn, why) => { for (let i = 0; i < 100; i++) { if (await fn()) return; await new Promise((r) => setTimeout(r, 30)); } assert.fail(why); };
  const heads = (page) => page.$$eval('.q-section', (els) => els.map((e) => e.textContent));
  const T = (t) => `[${name}] ${t}`;

  test(T('there is no "Waiting on a time" section, even when offers are in the data'), async () => {
    const { page } = await open();
    assert.equal((await heads(page)).includes('Waiting on a time'), false);
    assert.equal(await page.locator('.o-chip').count(), 0);
    const only = await open({}, { questions: [], visits: [], pending: DATA.pending, takeovers: [] }, '#q-empty:not(.gl-hidden)');
    assert.equal(await only.page.locator('.sw').count(), 0);
  });

  test(T('a left drag past the threshold snaps open, a short one snaps closed, vertical drags never reveal'), async () => {
    const { page } = await open();
    const visit = 1; // row 0 is the question
    await drag(page, visit, -50);
    assert.equal(await isOpen(page, visit), false, 'short drag stays closed');
    assert.equal(await page.locator('.sw').nth(visit).locator('.sw-bar').evaluate((e) => e.getBoundingClientRect().width), 0);
    const prevented = await drag(page, visit, 4, -120);
    assert.equal(prevented, false, 'vertical gesture must not be preventDefault()ed (it has to scroll)');
    assert.equal(await isOpen(page, visit), false);
    await drag(page, visit, -120);
    assert.equal(await isOpen(page, visit), true, 'long drag opens');
    assert.equal(await page.locator('.sw').nth(visit).locator('.sw-bar').evaluate((e) => Math.round(e.getBoundingClientRect().width)), 176);
    await drag(page, visit, 150);
    assert.equal(await isOpen(page, visit), false, 'dragging back closes');
  });

  test(T('only one row is open; tapping the open row or elsewhere closes it without opening the reply'), async () => {
    const { page } = await open();
    await drag(page, 1, -150);
    await drag(page, 0, -150);
    assert.deepEqual([await isOpen(page, 0), await isOpen(page, 1)], [true, false]);
    await page.locator('.sw').nth(0).locator('.sw-fg').click({ position: { x: 250, y: 10 } }); // fg is shifted left while open
    assert.equal(await isOpen(page, 0), false);
    assert.equal(await page.isHidden('#q-answer'), true, 'tap on an open row only closes it');
    await drag(page, 2, -150);
    await page.locator('.q-section').first().click();
    assert.equal(await isOpen(page, 2), false, 'tap outside closes');
    await page.locator('.sw').nth(0).locator('.sw-fg').click({ position: { x: 10, y: 10 } });
    assert.equal(await page.isVisible('#q-answer'), true, 'an unswiped tap still opens the reply');
  });

  test(T('visit Delete: POSTs listing+buyer with auth, removes the row, toasts'), async () => {
    const { page, posts } = await open();
    await drag(page, 1, -150);
    await action(page, 'Delete');
    assert.equal(await page.locator('.sw').count(), 2);
    assert.equal(await page.textContent('#q-toast-msg'), 'Visit deleted');
    await until(() => posts.length === 1, 'no POST');
    assert.deepEqual(posts[0], { url: '/visits/delete', body: { listing: 'Lamp', buyer: 'Dana' }, auth: 'Bearer tok' });
  });

  for (const outcome of [500, 'network']) {
    test(T(`visit Delete restores the row and errors on ${outcome}`), async () => {
      const { page } = await open({ '/visits/delete': outcome });
      await drag(page, 2, -150); // the past visit gets the same actions
      await action(page, 'Delete');
      await until(() => page.locator('#q-error:not(.gl-hidden)').count(), 'no error');
      assert.match(await page.textContent('#q-error-text'), /^Couldn't delete visit: /);
      assert.equal(await page.locator('.sw').count(), 3);
    });
  }

  test(T('Sold inside the revealed row keeps the two-tap confirm'), async () => {
    const { page, posts } = await open();
    await drag(page, 1, -150);
    await action(page, 'Sold');
    assert.equal(await page.locator('.sw.open .sw-btn').first().textContent(), 'Tap again');
    assert.equal(posts.length, 0, 'first tap only arms');
    await action(page, 'Tap again');
    await until(() => posts.length === 1, 'no sold POST');
    assert.deepEqual(posts[0].body, { listing: 'Lamp', buyer: 'Dana' });
    assert.equal(posts[0].url, '/listings/sold');
  });

  for (const [label, path, toastMsg, err] of [['Discard', '/questions/dismiss', 'Discarded', "Couldn't discard: "], ['Send back to AI', '/questions/send-back', 'Sent back to AI', "Couldn't send back: "]]) {
    test(T(`question "${label}": optimistic removal + POST ${path}`), async () => {
      const { page, posts } = await open();
      await drag(page, 0, -200);
      await action(page, label);
      assert.equal((await heads(page)).includes('Needs reply'), false);
      assert.equal(await page.textContent('#q-toast-msg'), toastMsg);
      await until(() => posts.length === 1, 'no POST');
      assert.deepEqual(posts[0], { url: path, body: { listing: 'Print', buyer: 'Omari' }, auth: 'Bearer tok' });
    });
    for (const outcome of [500, 'network']) {
      test(T(`question "${label}" restores the question and errors on ${outcome}`), async () => {
        const { page } = await open({ [path]: outcome });
        await drag(page, 0, -200);
        await action(page, label);
        await until(() => page.locator('#q-error:not(.gl-hidden)').count(), 'no error');
        assert.ok((await page.textContent('#q-error-text')).startsWith(err));
        assert.ok((await heads(page)).includes('Needs reply'));
      });
    }
  }

  test(T('the reply draft survives a reload and is cleared once sent'), async () => {
    const { page } = await open();
    await page.locator('.sw').nth(0).locator('.sw-fg').click({ position: { x: 10, y: 10 } });
    await page.fill('#q-text', 'half typed rep');
    await page.reload();
    await page.waitForSelector('.sw');
    await page.locator('.sw').nth(0).locator('.sw-fg').click({ position: { x: 10, y: 10 } });
    assert.equal(await page.inputValue('#q-text'), 'half typed rep');
    assert.equal(await page.isDisabled('#q-send'), false);
    await page.click('#q-send');
    assert.equal(await page.evaluate(() => Object.keys(localStorage).some((k) => k.startsWith('gl.questions.draft.'))), false);
  });
}

// Lists back navigation: the nav chevron and a left-edge swipe both go back
// (one shared back path) and both restore the scroll offset of the screen being
// left. Real WebKit, the real lists.html served from ListsApp/web, localStorage
// mode (no bridge, no token, so no network). Skipped unless GL_WEBKIT_PW and
// GL_WEBKIT_EXEC are set, same convention as cycle-swipe-ignore.test.mjs.
import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HAS_WK = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = HAS_WK ? await import(process.env.GL_WEBKIT_PW) : null;
const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../ListsApp/web');
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };

// 80 unchecked items, all in Pantry, so the list is far taller than the viewport.
function seedState() {
  const items = [];
  for (let i = 0; i < 80; i++) {
    items.push({ id: 'i' + i, listId: 'list-groceries', name: 'item ' + String(i).padStart(2, '0'), note: '', categoryId: 'cat-pantry',
      checked: false, createdAt: 1000 + i, updatedAt: 1000 + i, deleted: false, history: [{ at: 1000 + i, what: 'Added' }] });
  }
  return {
    v: 1, widgetListId: null,
    lists: [{ id: 'list-groceries', name: 'Groceries', order: 0, updatedAt: 0, deleted: false }],
    categories: [{ id: 'cat-pantry', name: 'Pantry', color: '#a0693a', order: 0, updatedAt: 0, deleted: false },
      { id: 'cat-other', name: 'Other', color: '#808590', order: 1, updatedAt: 0, deleted: false }],
    items, learned: {}, sync: { cursor: 0, outbox: { lists: {}, categories: {}, items: {}, learned: {}, widget: false }, pending: {}, widgetAt: 0 }
  };
}

describe('lists back navigation (webkit)', { skip: !HAS_WK && 'needs GL_WEBKIT_PW and GL_WEBKIT_EXEC' }, () => {
  let server, base, browser, page;
  before(async () => {
    server = http.createServer((req, res) => {
      const f = path.join(WEB, req.url === '/' ? 'lists.html' : req.url.split('?')[0]);
      if (!f.startsWith(WEB) || !fs.existsSync(f)) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(f)] || 'text/plain' });
      res.end(fs.readFileSync(f));
    });
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    base = 'http://127.0.0.1:' + server.address().port;
    browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC });
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    page = await ctx.newPage();
    await page.addInitScript((s) => { if (!localStorage.getItem('lists.state.v1')) localStorage.setItem('lists.state.v1', s); }, JSON.stringify(seedState()));
    await page.goto(base + '/');
    await page.waitForSelector('.row');
  });
  after(async () => { await browser?.close(); await new Promise((r) => server?.close(r)); });

  const top = () => page.$eval('.scroll', (s) => s.scrollTop);
  const openList = async () => { await page.click('.row >> text=Groceries'); await page.waitForSelector('.row.item'); };
  // Scrolls the list, opens the detail of an item (via its info button), returns the saved offset.
  async function scrollAndOpen(y) {
    const saved = await page.$eval('.scroll', (s, y) => { s.scrollTop = y; return s.scrollTop; }, y);
    assert.ok(saved > 300, 'list is tall enough to scroll, got ' + saved);
    await page.evaluate(() => { document.querySelectorAll('.row.item .pcell')[30].click(); });
    await page.waitForSelector('.hist');
    assert.equal(await top(), 0, 'a freshly opened detail starts at the top');
    return saved;
  }
  // Edge swipe: pointerdown inside the 24px left edge, pointerup 160px right.
  const edgeSwipe = () => page.evaluate(() => {
    const ev = (t, x) => document.dispatchEvent(new PointerEvent(t, { clientX: x, clientY: 400, bubbles: true, pointerType: 'touch' }));
    ev('pointerdown', 6); ev('pointerup', 166);
  });

  it('lists: back by button restores the list scroll offset', async () => {
    await openList();
    const saved = await scrollAndOpen(900);
    await page.click('.cbtn[aria-label="Done"]');
    await page.waitForSelector('.row.item');
    assert.equal(await top(), saved);
  });

  it('lists: back by left-edge swipe restores the list scroll offset', async () => {
    const saved = await scrollAndOpen(600);
    await edgeSwipe();
    await page.waitForSelector('.row.item');
    assert.equal(await top(), saved);
  });

  it('lists: a swipe that does not start at the edge does not go back', async () => {
    await scrollAndOpen(400);
    await page.evaluate(() => {
      const ev = (t, x) => document.dispatchEvent(new PointerEvent(t, { clientX: x, clientY: 400, bubbles: true, pointerType: 'touch' }));
      ev('pointerdown', 120); ev('pointerup', 300);
    });
    assert.ok(await page.$('.hist'), 'still on the detail screen');
    await page.click('.cbtn[aria-label="Done"]');
  });

  it('lists: leaving to home and opening the list again starts at the top', async () => {
    await page.click('.rbtn[aria-label="Back"]');   // list -> home
    await page.waitForSelector('.lrow');
    await openList();
    assert.equal(await top(), 0);
  });
});

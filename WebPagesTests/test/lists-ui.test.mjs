// Lists UI behaviours reviewers could not see: two-step delete, typed text never
// dropped on navigation, keyboard-reduced visual viewport, centred nav titles,
// sync failure badge, undo chip, collapsed category picker, band contrast.
// Real WebKit + the real page in localStorage mode (no bridge). Skipped without
// GL_WEBKIT_PW / GL_WEBKIT_EXEC (same convention as lists-nav.test.mjs).
import { describe, it, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { richState } from './lists-seed.mjs';

const HAS_WK = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = HAS_WK ? await import(process.env.GL_WEBKIT_PW) : null;
const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../ListsApp/web');
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };

describe('lists UI (webkit)', { skip: !HAS_WK && 'needs GL_WEBKIT_PW and GL_WEBKIT_EXEC' }, () => {
  let server, base, browser, ctx, page;
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
  });
  after(async () => { await browser?.close(); await new Promise((r) => server?.close(r)); });

  // Fresh context per test: localStorage is reseeded, so tests cannot leak into each other.
  beforeEach(async () => {
    await ctx?.close();
    ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
    page = await ctx.newPage();
    await page.addInitScript((s) => { if (!localStorage.getItem('lists.state.v1')) localStorage.setItem('lists.state.v1', s); }, JSON.stringify(richState()));
    await page.goto(base + '/');
    await page.waitForSelector('.row');
  });
  const openList = async () => { await page.click('.row >> text=Groceries'); await page.waitForSelector('.row.item'); };
  const live = () => page.evaluate(() => window.ListsUI.state().items.filter((i) => !i.deleted).length);
  const edgeSwipe = () => page.evaluate(() => {
    const ev = (t, x) => document.dispatchEvent(new PointerEvent(t, { clientX: x, clientY: 400, bubbles: true, pointerType: 'touch' }));
    ev('pointerdown', 6); ev('pointerup', 166);
  });
  const itemName = (id) => page.evaluate((id) => window.ListsUI.state().items.find((i) => i.id === id).name, id);

  it('lists: Delete checked needs two taps, is dim at rest, red when armed, and disarms on a tap elsewhere', async () => {
    await openList();
    await page.click('.checked-hd button');                       // expand Checked
    const del = page.locator('.checked-hd .del');
    const rest = await del.evaluate((e) => getComputedStyle(e).color);
    await del.click();
    assert.equal(await del.textContent(), 'Delete 2?');
    assert.equal(await live(), 13, 'first tap deletes nothing');
    assert.notEqual(await del.evaluate((e) => getComputedStyle(e).color), rest, 'armed colour differs from rest');
    await page.click('.nav h1');                                  // tap elsewhere
    assert.equal(await del.textContent(), 'Delete checked');
    await del.click(); await del.click();
    assert.equal(await live(), 11, 'second tap deletes the 2 checked');
  });

  it('lists: list Delete (sheet) is two-step and names the item count; item Delete is two-step', async () => {
    await page.click('.nav-btn >> text=Edit');
    await page.click('.row >> text=Groceries');
    const del = page.locator('.sheet .danger');
    await del.click();
    assert.equal(await del.textContent(), 'Delete 12 items?');
    assert.equal(await page.evaluate(() => window.ListsUI.state().lists.filter((l) => !l.deleted).length), 2);
    await del.click();
    assert.equal(await page.evaluate(() => window.ListsUI.state().lists.filter((l) => !l.deleted).length), 1);
  });

  it('lists: item Delete is two-step', async () => {
    await openList();
    await page.evaluate(() => document.querySelectorAll('.row.item .icon-btn')[0].click());
    await page.waitForSelector('.hist');
    const del = page.locator('.btn-danger');
    await del.click();
    assert.equal(await live(), 13);
    await del.click();
    await page.waitForSelector('.row.item');
    assert.equal(await live(), 12);
  });

  // A delete must be persisted and queued for sync, not just applied in memory:
  // read localStorage itself (no reload, whose pagehide flush would mask a missing save).
  const reloaded = async () => {
    await page.waitForTimeout(400); // past the 250ms save debounce
    return page.evaluate(() => { const s = JSON.parse(localStorage.getItem('lists.state.v1')); return { items: s.items, lists: s.lists, outbox: s.sync.outbox }; });
  };
  it('lists: Delete checked, item Delete and list Delete are persisted to storage as tombstones in the outbox', async () => {
    await openList();
    await page.click('.checked-hd button');
    const del = page.locator('.checked-hd .del');
    await del.click(); await del.click();
    let r = await reloaded();
    const checked = r.items.filter((i) => i.listId === 'list-groceries' && i.checked);
    assert.equal(checked.length, 2);
    assert.ok(checked.every((i) => i.deleted && r.outbox.items[i.id]), 'checked items tombstoned and queued');
    await page.evaluate(() => document.querySelectorAll('.row.item .icon-btn')[0].click());
    await page.waitForSelector('.hist');
    const bdel = page.locator('.btn-danger');
    await bdel.click(); await bdel.click();
    r = await reloaded();
    assert.equal(r.items.filter((i) => i.deleted).length, 3, 'item delete persisted');
    await page.click('.nav-btn[aria-label="Back"]');
    await page.click('.nav-btn >> text=Edit');
    await page.click('.row >> text=Groceries');
    const ldel = page.locator('.sheet .danger');
    await ldel.click(); await ldel.click();
    r = await reloaded();
    assert.equal(r.lists.find((l) => l.id === 'list-groceries').deleted, true);
    assert.ok(r.outbox.lists['list-groceries'], 'list tombstone queued');
    const g = r.items.filter((i) => i.listId === 'list-groceries');
    assert.ok(g.every((i) => i.deleted && r.outbox.items[i.id]), 'every Groceries item tombstoned and queued');
    assert.equal(r.items.find((i) => i.listId !== 'list-groceries').deleted, false, 'other list untouched');
  });

  async function typeInName(text) {
    await openList();
    await page.evaluate(() => document.querySelectorAll('.row.item .icon-btn')[0].click());
    await page.waitForSelector('.hist');
    const f = page.locator('input[aria-label="Name"]');
    await f.click(); await f.fill(text);
    return f;
  }
  it('lists: typed item name survives the nav back button before the debounce fires', async () => {
    await typeInName('Bananas ripe');
    await page.click('.nav-btn[aria-label="Back"]');
    assert.equal(await itemName('i0'), 'Bananas ripe');
  });
  it('lists: typed item name survives an edge-swipe back', async () => {
    await typeInName('Bananas green');
    await edgeSwipe();
    assert.equal(await itemName('i0'), 'Bananas green');
  });
  it('lists: typed item name survives tapping a category row while the field is focused', async () => {
    await typeInName('Bananas yellow');
    await page.click('.row.pick');                // expands the picker -> repaint
    assert.equal(await itemName('i0'), 'Bananas yellow');
    assert.equal(await page.locator('input[aria-label="Name"]').inputValue(), 'Bananas yellow');
  });
  it('lists: typed note commits from the debounced input without any blur', async () => {
    await typeInName('x');
    const n = page.locator('input[aria-label="Note"]');
    await n.click(); await n.fill('ripe ones'); await page.waitForTimeout(1200);
    assert.equal(await page.evaluate(() => window.ListsUI.state().items.find((i) => i.id === 'i0').note), 'ripe ones');
  });
  it('lists: text typed in an open sheet is kept when navigation closes it', async () => {
    await page.click('.nav-btn[aria-label="Add list"]');
    await page.fill('.sheet .field', 'Hardware');
    await page.evaluate(() => window.ListsUI.go({ name: 'cats' }));
    assert.equal(await page.evaluate(() => window.ListsUI.state().lists.filter((l) => !l.deleted && l.name === 'Hardware').length), 1);
  });

  it('lists: with a keyboard-sized visual viewport the add bar and sheets stay inside it', async () => {
    await openList();
    // Headless WebKit has no on-screen keyboard: emulate what WKWebView does, shrink
    // visualViewport only (innerHeight stays full) and fire its resize event.
    const shrink = (h) => page.evaluate((h) => {
      Object.defineProperty(window.visualViewport, 'height', { configurable: true, get: () => h });
      window.visualViewport.dispatchEvent(new Event('resize'));
    }, h);
    await shrink(844 - 336);
    const vvH = 844 - 336;
    const bar = await page.$eval('.addwrap', (e) => e.getBoundingClientRect().toJSON());
    assert.ok(bar.bottom <= vvH + 0.5, 'add bar bottom ' + bar.bottom + ' <= ' + vvH);
    assert.ok(bar.height > 40);
    await page.click('.nav-btn[aria-label="Back"]');
    await page.click('.nav-btn[aria-label="Add list"]');
    const sh = await page.$eval('.sheet', (e) => e.getBoundingClientRect().toJSON());
    assert.ok(sh.bottom <= vvH + 0.5, 'sheet bottom ' + sh.bottom);
    const nav = await page.$eval('.nav', (e) => e.getBoundingClientRect().toJSON());
    assert.equal(nav.top, 0, 'nav stays on screen');
    await shrink(844);
    assert.equal(await page.evaluate(() => document.documentElement.classList.contains('kb')), false);
  });

  it('lists: nav titles are centred on the screen on Home, Categories and a list', async () => {
    const centre = () => page.$eval('.nav h1', (h) => { const r = h.getBoundingClientRect(); return r.left + r.width / 2; });
    assert.ok(Math.abs(await centre() - 195) <= 1, 'home ' + await centre());
    await page.click('.row >> text=Categories'); await page.waitForSelector('.nav h1 >> text=Categories');
    assert.ok(Math.abs(await centre() - 195) <= 1, 'categories ' + await centre());
    await page.click('.nav-btn[aria-label="Back"]'); await openList();
    assert.ok(Math.abs(await centre() - 195) <= 1, 'list ' + await centre());
  });

  it('lists: sync badge is hidden unless the last sync failed, and tapping it retries without throwing', async () => {
    const vis = () => page.$eval('.sync', (e) => getComputedStyle(e).display);
    // No token in localStorage mode -> credentials failed -> error state.
    assert.equal(await page.$eval('.sync', (e) => e.dataset.status), 'error');
    assert.notEqual(await vis(), 'none');
    for (const st of ['ok', 'pending']) {
      await page.$eval('.sync', (e, st) => e.setAttribute('data-status', st), st);
      assert.equal(await vis(), 'none', st);
    }
    assert.equal(await page.getAttribute('.sync', 'aria-label'), 'Sync');
    await page.$eval('.sync', (e) => e.setAttribute('data-status', 'error'));
    await page.click('.sync');
  });

  it('lists: checking an item shows an undo chip that reverses it and disappears after ~4s', async () => {
    await openList();
    await page.click('.row.item >> text=Bananas');
    assert.ok(await page.isVisible('.undo button'));
    await page.click('.undo button');
    assert.equal(await page.evaluate(() => window.ListsUI.state().items.find((i) => i.id === 'i0').checked), false);
    await page.click('.row.item >> text=Spinach');
    assert.ok(await page.isVisible('.undo button'));
    await page.waitForTimeout(4400);
    assert.equal(await page.isVisible('.undo button'), false);
  });

  it('lists: item detail picker is collapsed to one row, expands on tap, and a choice collapses it again', async () => {
    await openList();
    await page.evaluate(() => document.querySelectorAll('.row.item .icon-btn')[0].click());
    await page.waitForSelector('.hist');
    assert.equal(await page.locator('.row.pick').count(), 1);
    await page.click('.row.pick');
    assert.equal(await page.locator('.row.pick').count(), 11);
    await page.click('.row.pick >> text=Bakery');
    assert.equal(await page.locator('.row.pick').count(), 1);
    assert.equal(await page.textContent('.row.pick .nm'), 'Bakery');
    assert.ok(await page.isVisible('.hist'), 'history visible without scrolling');
  });

  it('lists: band text reaches 4.5:1 against every rendered band', async () => {
    await openList();
    const ratios = await page.$$eval('.band', (bs) => bs.map((b) => {
      const cs = getComputedStyle(b), p = (c) => c.match(/\d+/g).slice(0, 3).map(Number);
      const L = (rgb) => { const [r, g, bl] = rgb.map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * bl; };
      const a = L(p(cs.color)), c = L(p(cs.backgroundColor));
      return (Math.max(a, c) + 0.05) / (Math.min(a, c) + 0.05);
    }));
    assert.ok(ratios.length >= 8);
    ratios.forEach((r) => assert.ok(r >= 4.5, 'band contrast ' + r));
  });

  it('lists: Home rows show the unchecked count', async () => {
    const t = await page.$$eval('.row .count', (els) => els.map((e) => e.textContent));
    assert.deepEqual(t, ['10', '1']);
  });
});

// Lists UI behaviours reviewers could not see: two-step delete, typed text never
// dropped on navigation, keyboard-reduced visual viewport, centred nav titles,
// sync failure badge, crossed-off rows in place, Add Item mode, category picker, fixed bands.
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

  const menuItem = (label) => page.locator('.mi[data-label="' + label + '"]');
  const openMenu = () => page.click('.rbtn[aria-label="List menu"]');
  const homeDots = (name) => page.click('.row:has-text("' + name + '") .icon-btn');
  const openDetails = (n = 0) => page.evaluate((n) => document.querySelectorAll('.row.item .pcell')[n].click(), n);

  it('lists: Delete crossed off items (menu) needs two taps, is red when armed, and disarms on a tap elsewhere', async () => {
    await openList();
    await openMenu();
    const del = menuItem('Delete Crossed Off Items');
    const rest = await del.evaluate((e) => getComputedStyle(e).color);
    await del.click();
    assert.equal(await del.textContent(), 'Delete 2?');
    assert.equal(await live(), 13, 'first tap deletes nothing');
    assert.notEqual(await del.evaluate((e) => getComputedStyle(e).color), rest, 'armed colour differs from rest');
    await page.mouse.click(200, 700);                             // tap elsewhere: closes the menu and disarms
    assert.equal(await page.locator('.pop').count(), 0);
    assert.equal(await live(), 13);
    await openMenu();
    assert.equal(await menuItem('Delete Crossed Off Items').textContent(), 'Delete Crossed Off Items', 'disarmed');
    await menuItem('Delete Crossed Off Items').click();
    await menuItem('Delete Crossed Off Items').click();
    assert.equal(await live(), 11, 'second tap deletes the 2 crossed');
    await openMenu();
    assert.equal(await menuItem('Delete Crossed Off Items').count(), 0, 'no crossed items, no entry');
  });

  it('lists: list Delete (home sheet) is two-step and names the item count', async () => {
    await homeDots('Groceries');
    const del = page.locator('.sheet .danger');
    await del.click();
    assert.equal(await del.textContent(), 'Delete 12 items?');
    assert.equal(await page.evaluate(() => window.ListsUI.state().lists.filter((l) => !l.deleted).length), 2);
    await del.click();
    assert.equal(await page.evaluate(() => window.ListsUI.state().lists.filter((l) => !l.deleted).length), 1);
  });

  it('lists: Delete List in the list menu is two-step and returns to Home', async () => {
    await openList();
    await openMenu();
    const del = menuItem('Delete List');
    await del.click();
    assert.equal(await del.textContent(), 'Delete 12 items?');
    await del.click();
    await page.waitForSelector('.lrow');
    assert.equal(await page.evaluate(() => window.ListsUI.state().lists.filter((l) => !l.deleted).length), 1);
    assert.equal(await page.locator('.nav .ttl').textContent(), 'Lists');
  });

  it('lists: item Delete is two-step', async () => {
    await openList();
    await openDetails();
    await page.waitForSelector('.hist');
    const del = page.locator('.btn-danger');
    await del.click();
    assert.equal(await live(), 13);
    await del.click();
    await page.waitForSelector('.row.item');
    assert.equal(await live(), 12);
  });

  it('lists: tapping a row crosses the item off IN PLACE (struck, no Checked section) and tapping again uncrosses it', async () => {
    await openList();
    const order = () => page.$$eval('.row.item .nm', (e) => e.map((x) => x.textContent));
    const before = await order();
    await page.click('.row.item >> text=Bananas');
    assert.deepEqual(await order(), before, 'same order, nothing moved');
    assert.equal(await page.evaluate(() => window.ListsUI.state().items.find((i) => i.id === 'i0').checked), true);
    const row = page.locator('.row.item:has-text("Bananas")');
    assert.ok(await row.evaluate((e) => e.classList.contains('done')));
    assert.ok(await row.locator('.nm').evaluate((e) => getComputedStyle(e, '::after').content !== 'none'), 'strike line');
    assert.equal(await page.locator('.checked-hd').count(), 0, 'no separate Checked section');
    assert.equal(await page.locator('.undo').count(), 0, 'no undo chip');
    await page.click('.row.item >> text=Bananas');
    assert.equal(await page.evaluate(() => window.ListsUI.state().items.find((i) => i.id === 'i0').checked), false);
  });

  it('lists: a category holding only crossed items still shows its band', async () => {
    await openList();
    assert.ok(await page.locator('.band >> text=Household').count(), 'Household has only the crossed Dish soap');
    assert.equal(await page.locator('.band >> text=Pantry').count(), 1);
  });

  it('lists: subtitle counts remaining vs total', async () => {
    await openList();
    assert.equal(await page.textContent('.t2'), '10 of 12 items remaining');
    await page.click('.row.item >> text=Bananas');
    assert.equal(await page.textContent('.t2'), '9 of 12 items remaining');
  });

  it('lists: Add Item enters add mode with suggestions; Enter adds and keeps focus; Done leaves', async () => {
    await openList();
    await page.click('.toolbar input');
    assert.ok(await page.evaluate(() => document.querySelector('.screen').classList.contains('adding')));
    await page.fill('.toolbar input', 'mil');
    assert.ok(await page.locator('.row.sugg >> text=Add “mil”').count());
    await page.press('.toolbar input', 'Enter');
    assert.equal(await page.evaluate(() => window.ListsUI.state().items.filter((i) => !i.deleted && i.name === 'mil').length), 1);
    assert.equal(await page.evaluate(() => document.activeElement.tagName), 'INPUT', 'focus kept');
    await page.click('.tb-done');
    assert.equal(await page.evaluate(() => document.querySelector('.screen').classList.contains('adding')), false);
    assert.ok(await page.locator('.row.item >> text=mil').count());
  });

  // A delete must be persisted and queued for sync, not just applied in memory:
  // read localStorage itself (no reload, whose pagehide flush would mask a missing save).
  const reloaded = async () => {
    await page.waitForTimeout(400); // past the 250ms save debounce
    return page.evaluate(() => { const s = JSON.parse(localStorage.getItem('lists.state.v1')); return { items: s.items, lists: s.lists, outbox: s.sync.outbox }; });
  };
  it('lists: Delete crossed, item Delete and list Delete are persisted to storage as tombstones in the outbox', async () => {
    await openList();
    await openMenu();
    await menuItem('Delete Crossed Off Items').click(); await menuItem('Delete Crossed Off Items').click();
    let r = await reloaded();
    const checked = r.items.filter((i) => i.listId === 'list-groceries' && i.checked);
    assert.equal(checked.length, 2);
    assert.ok(checked.every((i) => i.deleted && r.outbox.items[i.id]), 'crossed items tombstoned and queued');
    await openDetails();
    await page.waitForSelector('.hist');
    const bdel = page.locator('.btn-danger');
    await bdel.click(); await bdel.click();
    r = await reloaded();
    assert.equal(r.items.filter((i) => i.deleted).length, 3, 'item delete persisted');
    await page.click('.rbtn[aria-label="Back"]');
    await homeDots('Groceries');
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
    await openDetails();
    await page.waitForSelector('.hist');
    const f = page.locator('input[aria-label="Name"]');
    await f.click(); await f.fill(text);
    return f;
  }
  it('lists: typed item name survives the nav back button before the debounce fires', async () => {
    await typeInName('Bananas ripe');
    await page.click('.cbtn[aria-label="Done"]');
    assert.equal(await itemName('i0'), 'Bananas ripe');
  });
  it('lists: typed item name survives an edge-swipe back', async () => {
    await typeInName('Bananas green');
    await edgeSwipe();
    assert.equal(await itemName('i0'), 'Bananas green');
  });
  it('lists: typed item name survives opening the category picker before the debounce fires', async () => {
    await typeInName('Bananas yellow');
    await page.click('.row >> text=Category');
    await page.waitForSelector('.row.pick');
    assert.equal(await itemName('i0'), 'Bananas yellow');
  });
  it('lists: typed note commits from the debounced input without any blur', async () => {
    await typeInName('x');
    const n = page.locator('input[aria-label="Note"]');
    await n.click(); await n.fill('ripe ones'); await page.waitForTimeout(1200);
    assert.equal(await page.evaluate(() => window.ListsUI.state().items.find((i) => i.id === 'i0').note), 'ripe ones');
  });
  it('lists: text typed in an open sheet is kept when navigation closes it', async () => {
    await page.click('.pb[aria-label="Add list"]');
    await page.fill('.sheet .field', 'Hardware');
    await page.evaluate(() => window.ListsUI.go({ name: 'cats' }));
    assert.equal(await page.evaluate(() => window.ListsUI.state().lists.filter((l) => !l.deleted && l.name === 'Hardware').length), 1);
  });

  it('lists: with a keyboard-sized visual viewport the add field and sheets stay inside it', async () => {
    await openList();
    // Headless WebKit has no on-screen keyboard: emulate what WKWebView does, shrink
    // visualViewport only (innerHeight stays full) and fire its resize event.
    const shrink = (h) => page.evaluate((h) => {
      Object.defineProperty(window.visualViewport, 'height', { configurable: true, get: () => h });
      window.visualViewport.dispatchEvent(new Event('resize'));
    }, h);
    await page.click('.toolbar input');
    await shrink(844 - 336);
    const vvH = 844 - 336;
    const bar = await page.$eval('.toolbar', (e) => e.getBoundingClientRect().toJSON());
    assert.ok(bar.top >= 0 && bar.bottom <= vvH, 'add field inside the shrunken viewport');
    const sc = await page.$eval('.scroll', (e) => e.getBoundingClientRect().toJSON());
    assert.ok(sc.bottom <= vvH + 0.5, 'suggestions area ends above the keyboard ' + sc.bottom);
    await page.click('.tb-done');
    await page.click('.rbtn[aria-label="Back"]');
    await page.click('.pb[aria-label="Add list"]');
    const sh = await page.$eval('.sheet', (e) => e.getBoundingClientRect().toJSON());
    assert.ok(sh.bottom <= vvH + 0.5, 'sheet bottom ' + sh.bottom);
    const nav = await page.$eval('.nav', (e) => e.getBoundingClientRect().toJSON());
    assert.equal(nav.top, 0, 'nav stays on screen');
    await shrink(844);
    assert.equal(await page.evaluate(() => document.documentElement.classList.contains('kb')), false);
  });

  it('lists: nav titles are centred on the screen on Home, Categories and a list', async () => {
    const centre = () => page.$eval('.nav .ttl', (h) => { const r = h.getBoundingClientRect(); return r.left + r.width / 2; });
    assert.ok(Math.abs(await centre() - 195) <= 1, 'home ' + await centre());
    await page.click('.pb[aria-label="More"]'); await page.click('.mi >> text=Categories'); await page.waitForSelector('.nav .ttl >> text=Categories');
    assert.ok(Math.abs(await centre() - 195) <= 1, 'categories ' + await centre());
    await page.click('.rbtn[aria-label="Back"]'); await openList();
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

  it('lists: the Category row opens a picker; choosing one sets it and returns to the details', async () => {
    await openList();
    await openDetails();
    await page.waitForSelector('.hist');
    await page.click('.row >> text=Category');
    await page.waitForSelector('.row.pick');
    assert.equal(await page.locator('.row.pick').count(), 11);
    assert.equal(await page.locator('.row.pick .check svg').count(), 1, 'one blue check on the current category');
    await page.click('.row.pick >> text=Bakery');
    await page.waitForSelector('.hist');
    assert.equal(await page.textContent('.val'), 'Bakery');
  });

  it('lists: every band is the same fixed blue with white text that is not uppercased', async () => {
    await openList();
    const bands = await page.$$eval('.band', (bs) => bs.map((b) => { const cs = getComputedStyle(b); return [cs.backgroundColor, cs.color, cs.textTransform, b.getBoundingClientRect().height]; }));
    assert.ok(bands.length >= 8);
    bands.forEach((b) => { assert.deepEqual(b, ['rgb(22, 162, 224)', 'rgb(255, 255, 255)', 'none', 28]); });
  });

  it('lists: Home rows show the remaining count as a subtitle', async () => {
    const t = await page.$$eval('.lrow .sub', (els) => els.map((e) => e.textContent));
    assert.deepEqual(t, ['10 items remaining', '1 item']);
  });

  it('category sheet: exactly one swatch is selected and the mark follows a tap', async () => {
    await page.click('.pb[aria-label="More"]'); await page.click('.mi >> text=Categories');
    await page.click('.row >> text=Pantry');
    const on = () => page.$$eval('.swatches button[aria-pressed="true"]', (b) => b.map((x) => x.getAttribute('aria-label')));
    const before = await on(); 
    assert.equal(before.length, 1);
    const other = await page.$$eval('.swatches button', (b, cur) => b.map((x) => x.getAttribute('aria-label')).find((c) => c !== cur), before[0]);
    await page.click('.swatches button[aria-label="' + other + '"]');
    assert.deepEqual(await on(), [other]);
    assert.equal(await page.locator('.swatches .on').count(), 1);
  });

  it('home: a row "..." opens the rename/delete sheet; Edit Lists (menu) shows move arrows', async () => {
    await homeDots('Groceries');
    assert.ok(await page.isVisible('.sheet .danger'));
    await page.click('.sheet-actions button >> text=Cancel');
    await page.click('.pb[aria-label="More"]'); await page.click('.mi >> text=Edit Lists');
    assert.equal(await page.locator('.lrow [aria-label="Move down"]').count(), 1);
    await page.click('.pill >> text=Done');
    assert.equal(await page.locator('.lrow [aria-label="Move down"]').count(), 0);
  });
});

// Pure-logic tests for ListsApp/web/lists-core.js (+ lists-dict.js). No DOM, no
// bridge. Test names start with "lists:" so `--test-name-pattern lists` finds them.
import test from 'node:test';
import assert from 'node:assert/strict';
import C, { Dict } from './lists-load.mjs';

let t = 1_000_000, n = 0;
C.setEnv({ now: () => (t += 10), uid: () => `id-${++n}` });
const L = 'list-groceries';
const catId = (name) => `cat-${name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')}`;
const reload = (s) => C.normalizeLoaded(JSON.parse(JSON.stringify(s)));
const it = (s, id) => C.find(s.items, id);

test('lists: dictionary has 500+ entries, resolves plurals/modifiers, and does not know gochujang or drain cleaner', () => {
  assert.ok(Dict.size() >= 500, `size ${Dict.size()}`);
  assert.equal(Dict.lookup('Bananas'), 'Produce');
  assert.equal(Dict.lookup('organic bananas'), 'Produce');
  assert.equal(Dict.lookup('cookie'), 'Bakery');
  assert.equal(Dict.lookup('toilet paper'), 'Household');
  assert.equal(Dict.lookup('gochujang'), null);
  assert.equal(Dict.lookup('drain cleaner'), null);
});

test('lists: add uses the dictionary instantly, history records it, nothing is pending', () => {
  const s = C.newState();
  const i = C.addItem(s, L, '  milk ');
  assert.equal(i.name, 'milk');
  assert.equal(i.categoryId, catId('Dairy'));
  assert.deepEqual(i.history.map((h) => h.what), ['Added', 'Categorized as Dairy']);
  assert.deepEqual(s.sync.pending, {});
  assert.ok(s.sync.outbox.items[i.id]);
});

test('lists: learned beats the dictionary, and a manual category teaches learned', () => {
  const s = C.newState();
  const a = C.addItem(s, L, 'milk');
  C.setCategory(s, a.id, catId('Beverages'));
  assert.equal(s.learned.milk.c, catId('Beverages'));
  const b = C.addItem(s, L, 'Milk ');
  // the first milk is still open on the list, so this is the same item, not a new one
  assert.equal(b.id, a.id);
  C.toggle(s, a.id);
  C.toggle(s, a.id);
  C.deleteItem(s, a.id);
  const c = C.addItem(s, L, 'MILK');
  assert.equal(c.categoryId, catId('Beverages'));
});

test('lists: unknown item lands in Other with the pending flag until the AI answers', () => {
  const s = C.newState();
  const i = C.addItem(s, L, 'gochujang');
  assert.equal(i.categoryId, C.OTHER_ID);
  assert.ok(s.sync.pending[i.id]);
  assert.equal(C.pendingItems(s).length, 1);
  assert.equal(C.applyAI(s, i.id, 'gochujang', catId('Pantry')), true);
  assert.equal(it(s, i.id).categoryId, catId('Pantry'));
  assert.deepEqual(s.sync.pending, {});
  assert.equal(it(s, i.id).history.at(-1).what, 'Categorized by AI as Pantry');
  assert.equal(s.learned.gochujang.c, catId('Pantry'));
});

test('lists: a late AI answer never overrides a manual category', () => {
  const s = C.newState();
  const i = C.addItem(s, L, 'gochujang');
  C.setCategory(s, i.id, catId('Frozen')); // user picks while the request is in flight
  assert.equal(C.applyAI(s, i.id, 'gochujang', catId('Pantry')), false);
  assert.equal(it(s, i.id).categoryId, catId('Frozen'));
  assert.equal(s.learned.gochujang.c, catId('Frozen'));
  assert.ok(!it(s, i.id).history.some((h) => /AI/.test(h.what)));
});

test('lists: an AI answer for a renamed or deleted item is dropped', () => {
  const s = C.newState();
  const a = C.addItem(s, L, 'gochujang');
  C.renameItem(s, a.id, 'zzz sauce');
  assert.equal(C.applyAI(s, a.id, 'gochujang', catId('Pantry')), false);
  const b = C.addItem(s, L, 'qqq');
  C.deleteItem(s, b.id);
  assert.equal(C.applyAI(s, b.id, 'qqq', catId('Pantry')), false);
});

test('lists: check and uncheck move items between groups and the Checked section, with history', () => {
  const s = C.newState();
  const a = C.addItem(s, L, 'apples');
  C.addItem(s, L, 'milk');
  C.addItem(s, L, 'bananas');
  let g = C.grouped(s, L);
  assert.deepEqual(g.groups.map((x) => x.category.name), ['Produce', 'Dairy']);
  assert.deepEqual(g.groups[0].items.map((x) => x.name), ['apples', 'bananas']);
  assert.equal(C.itemCounts(s)[L], 3);
  C.toggle(s, a.id);
  g = C.grouped(s, L);
  assert.deepEqual(g.checked.map((x) => x.name), ['apples']);
  assert.equal(C.itemCounts(s)[L], 2);
  C.toggle(s, a.id);
  assert.equal(C.grouped(s, L).checked.length, 0);
  assert.deepEqual(it(s, a.id).history.map((h) => h.what).slice(-2), ['Checked', 'Unchecked']);
  C.toggle(s, a.id);
  C.deleteChecked(s, L);
  assert.equal(C.grouped(s, L).checked.length, 0);
});

test('lists: deletes are tombstones that stay in state and in the push', () => {
  const s = C.newState();
  const a = C.addItem(s, L, 'apples');
  C.deleteItem(s, a.id);
  assert.equal(s.items.length, 1);
  assert.equal(it(s, a.id).deleted, true);
  assert.equal(C.grouped(s, L).groups.length, 0);
  assert.equal(C.itemCounts(s)[L], undefined);
  assert.equal(C.buildPush(s).body.changes.items[0].deleted, true);
  const list = C.addList(s, 'Hardware');
  C.addItem(s, list.id, 'screws');
  C.deleteList(s, list.id);
  assert.equal(C.liveLists(s).length, 1);
  assert.ok(s.items.filter((i) => i.listId === list.id).every((i) => i.deleted));
});

test('lists: deleting a category moves its items to Other and Other cannot be deleted', () => {
  const s = C.newState();
  const a = C.addItem(s, L, 'apples');
  const before = a.updatedAt;
  C.deleteCategory(s, catId('Produce'));
  assert.equal(it(s, a.id).categoryId, C.OTHER_ID);
  assert.ok(it(s, a.id).updatedAt > before);
  assert.equal(it(s, a.id).history.at(-1).what, 'Moved to Other (category deleted)');
  assert.deepEqual(C.grouped(s, L).groups.map((x) => x.category.name), ['Other']);
  assert.throws(() => C.deleteCategory(s, C.OTHER_ID), /Other cannot be deleted/);
  // a stale item pointing at a dead category (merge race) still shows under Other
  it(s, a.id).categoryId = catId('Produce');
  assert.deepEqual(C.grouped(s, L).groups.map((x) => x.category.name), ['Other']);
});

test('lists: reorder swaps order of two lists and categories', () => {
  const s = C.newState();
  const b = C.addList(s, 'B');
  C.moveList(s, b.id, -1);
  assert.deepEqual(C.liveLists(s).map((l) => l.name), ['B', 'Groceries']);
  C.moveCategory(s, catId('Dairy'), -1);
  assert.deepEqual(C.liveCategories(s).slice(0, 3).map((c) => c.name), ['Produce', 'Dairy', 'Bakery']);
});

test('lists: suggest ranks prefix first, uses past names incl. checked and deleted, skips names already on the list', () => {
  const s = C.newState();
  const a = C.addItem(s, L, 'oat milk');
  C.addItem(s, L, 'milk');
  C.addItem(s, L, 'almond milk');
  C.toggle(s, a.id);
  const d = C.addItem(s, L, 'milkshake mix');
  C.deleteItem(s, d.id);
  assert.deepEqual(C.suggest(s, 'mil', L), ['milkshake mix', 'oat milk']);
  assert.deepEqual(C.suggest(s, '', L), []);
});

// ---------- sync ----------
test('lists: LWW merge, remote newer replaces local and clears its outbox entry', () => {
  const s = C.newState();
  const i = C.addItem(s, L, 'apples');
  const push = C.buildPush(s);
  const remote = { ...JSON.parse(JSON.stringify(i)), name: 'pears', updatedAt: i.updatedAt + 1000 };
  C.applySync(s, push.sent, { now: 5, changes: { items: [remote] } });
  assert.equal(it(s, i.id).name, 'pears');
  assert.deepEqual(s.sync.outbox.items, {});
  assert.equal(s.sync.cursor, 5);
});

test('lists: LWW merge, local newer survives an older remote and stays queued', () => {
  const s = C.newState();
  const i = C.addItem(s, L, 'apples');
  C.applySync(s, C.buildPush(s).sent, { now: 1, changes: {} }); // acked
  C.renameItem(s, i.id, 'local edit');
  const stale = { ...JSON.parse(JSON.stringify(i)), name: 'remote edit', updatedAt: i.updatedAt - 5 };
  C.applySync(s, { lists: {}, categories: {}, items: {}, learned: {}, widget: null }, { now: 2, changes: { items: [stale] } });
  assert.equal(it(s, i.id).name, 'local edit');
  assert.ok(s.sync.outbox.items[i.id]);
});

test('lists: an edit made while a sync is in flight stays in the outbox', () => {
  const s = C.newState();
  const i = C.addItem(s, L, 'apples');
  const push = C.buildPush(s);
  C.toggle(s, i.id); // user taps during the request
  C.applySync(s, push.sent, { now: 3, changes: { items: [JSON.parse(JSON.stringify(push.body.changes.items[0]))] } });
  assert.equal(it(s, i.id).checked, true);
  assert.ok(s.sync.outbox.items[i.id]);
});

test('lists: the outbox survives a reload and still pushes everything', () => {
  const s = C.newState();
  const i = C.addItem(s, L, 'gochujang');
  C.addList(s, 'Hardware');
  C.setCategory(s, i.id, catId('Pantry'));
  C.setWidgetList(s, C.liveLists(s)[1].id);
  const r = reload(s);
  const push = C.buildPush(r);
  assert.equal(push.body.changes.items.length, 1);
  assert.equal(push.body.changes.lists.length, 1);
  assert.equal(push.body.changes.learned.gochujang.c, catId('Pantry'));
  assert.ok(push.body.changes.widgetListId);
  assert.deepEqual(reload(r).sync.pending, {}); // manual category cleared pending before the reload
  const p = C.newState();
  const q = C.addItem(p, L, 'zzz');
  assert.deepEqual(Object.keys(reload(p).sync.pending), [q.id]); // pending AI work survives too
});

test('lists: state version other than 1 throws, null seeds defaults once', () => {
  assert.throws(() => C.normalizeLoaded({ v: 2 }), /unsupported/);
  const s = C.normalizeLoaded(null);
  assert.deepEqual(s.categories.map((c) => c.name), C.DEFAULT_CATEGORIES.map((c) => c[0]));
  assert.equal(s.lists.length, 1);
  assert.equal(Object.keys(s.sync.outbox.items).length + Object.keys(s.sync.outbox.categories).length, 0);
});

// A minimal in-memory twin of the box's /api/sync (same LWW + server stamp cursor)
// so two ListsCore clients can be driven through the real syncOnce.
function fakeBox() {
  const db = { lists: {}, categories: {}, items: {}, learned: {}, widget: null }, stamp = { n: 0 };
  const fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    if (url.endsWith('/api/categorize')) return { ok: true, json: async () => ({ categoryId: catId('Pantry') }) };
    const s = ++stamp.n;
    for (const k of ['lists', 'categories', 'items']) {
      for (const r of body.changes[k]) if (!db[k][r.id] || r.updatedAt > db[k][r.id].updatedAt) db[k][r.id] = { ...r, _s: s };
    }
    for (const [key, r] of Object.entries(body.changes.learned)) if (!db.learned[key] || r.t > db.learned[key].t) db.learned[key] = { ...r, _s: s };
    const out = { lists: [], categories: [], items: [], learned: {} };
    for (const k of ['lists', 'categories', 'items']) out[k] = Object.values(db[k]).filter((r) => r._s > body.since);
    for (const [key, r] of Object.entries(db.learned)) if (r._s > body.since) out.learned[key] = r;
    return { ok: true, json: async () => ({ now: s, changes: out }) };
  };
  return { fetch, db };
}

test('lists: two clients converge A to B and B to A through sync', async () => {
  const box = fakeBox();
  const ctx = { fetch: box.fetch, baseUrl: '', token: 'x' };
  const A = C.newState(), B = C.newState();
  const a1 = C.addItem(A, L, 'apples');
  await C.syncOnce(A, ctx);
  await C.syncOnce(B, ctx);
  assert.equal(it(B, a1.id).name, 'apples');
  C.toggle(B, a1.id); // B -> A
  C.addItem(B, L, 'milk');
  await C.syncOnce(B, ctx);
  await C.syncOnce(A, ctx);
  assert.equal(it(A, a1.id).checked, true);
  assert.deepEqual(A.items.map((i) => i.name).sort(), ['apples', 'milk']);
  C.deleteItem(A, a1.id); // A's tombstone reaches B
  await C.syncOnce(A, ctx);
  await C.syncOnce(B, ctx);
  assert.equal(it(B, a1.id).deleted, true);
  assert.deepEqual(A.sync.outbox, { lists: {}, categories: {}, items: {}, learned: {}, widget: false });
});

test('lists: categorizePending applies the answer, and a failed request stays pending for retry', async () => {
  const s = C.newState();
  const i = C.addItem(s, L, 'gochujang');
  const ok = await C.categorizePending(s, { fetch: fakeBox().fetch, baseUrl: '', token: 'x' });
  assert.equal(ok.applied, 1);
  assert.equal(it(s, i.id).categoryId, catId('Pantry'));
  const j = C.addItem(s, L, 'qqq');
  const down = await C.categorizePending(s, { fetch: async () => { throw new Error('offline'); }, baseUrl: '', token: 'x' });
  assert.equal(down.failed.length, 1);
  assert.ok(s.sync.pending[j.id]);
  const again = await C.categorizePending(s, { fetch: fakeBox().fetch, baseUrl: '', token: 'x' });
  assert.equal(again.applied, 1);
});

test('lists: a manual pick made during an in-flight categorize wins over the answer', async () => {
  const s = C.newState();
  const i = C.addItem(s, L, 'gochujang');
  let release;
  const gate = new Promise((r) => { release = r; });
  const slow = async () => { await gate; return { ok: true, json: async () => ({ categoryId: catId('Pantry') }) }; };
  const p = C.categorizePending(s, { fetch: slow, baseUrl: '', token: 'x' });
  C.setCategory(s, i.id, catId('Snacks'));
  release();
  const r = await p;
  assert.equal(r.applied, 0);
  assert.equal(it(s, i.id).categoryId, catId('Snacks'));
});

test('lists: two-step confirm arms on first tap, fires on second, and re-arms or clears otherwise', () => {
  const c = C.makeConfirm();
  assert.equal(c.tap('a'), false);          // first tap arms
  assert.equal(c.armed(), 'a');
  assert.equal(c.tap('a'), true);           // second tap fires
  assert.equal(c.armed(), null);
  assert.equal(c.tap('a'), false);          // fired once; next tap arms again, never double-fires
  assert.equal(c.tap('b'), false);          // a different target re-arms to b
  assert.equal(c.tap('a'), false);          // a is not armed any more
  c.tap('a'); c.disarm();                   // tap elsewhere
  assert.equal(c.tap('a'), false);
});

test('lists: field commit flush writes a pending edit once and is a no-op when clean', async () => {
  let committed = 0;
  const f = C.makeFieldCommit(() => { committed++; }, 20);
  f.flush();
  assert.equal(committed, 0);               // nothing typed
  f.input();
  assert.equal(f.dirty(), true);
  f.flush();                                // navigation before the debounce fires
  assert.equal(committed, 1);
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(committed, 1);               // the timer must not commit a second time
  f.input();
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(committed, 2);               // debounce path commits by itself
});

test('lists: band text colour reaches 4.5:1 on every default colour and on arbitrary picks', () => {
  const colors = C.DEFAULT_CATEGORIES.map((c) => c[1]);
  for (let i = 0; i < 200; i++) colors.push('#' + Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, '0'));
  for (const col of colors) assert.ok(C.contrast(col, C.textOn(col)) >= 4.5, `${col} -> ${C.textOn(col)} ${C.contrast(col, C.textOn(col))}`);
});

test('lists: Bakery, Snacks and Pantry defaults differ clearly in hue/lightness, Dairy is far from the nav blue', () => {
  const col = Object.fromEntries(C.DEFAULT_CATEGORIES);
  const d = (a, b) => { const p = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16)); const x = p(a), y = p(b); return Math.hypot(x[0] - y[0], x[1] - y[1], x[2] - y[2]); };
  for (const [a, b] of [['Bakery', 'Snacks'], ['Bakery', 'Pantry'], ['Snacks', 'Pantry']]) assert.ok(d(col[a], col[b]) > 90, `${a}/${b} ${d(col[a], col[b])}`);
  assert.ok(d(col.Dairy, '#2b6cb0') > 120, `Dairy ${d(col.Dairy, '#2b6cb0')}`);
});

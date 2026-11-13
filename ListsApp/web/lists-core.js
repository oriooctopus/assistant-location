// Lists core: all state logic, no DOM and no bridge. Loaded as a classic script
// (window.ListsCore) and via vm in WebPagesTests. lists-dict.js loads first and
// is read lazily through the global ListsDict.
//
// The state blob is the contract with the iOS widget (see README in the task):
//   { v:1, widgetListId, lists[], categories[], items[], learned{}, sync{} }
// `learned` is {normalizedName: {c: categoryId, t: updatedAt}}; `sync` holds
// everything local-only: pull cursor, the outbox, and the AI-pending set.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(root);
  else root.ListsCore = factory(root);
})(this, function (root) {
  'use strict';

  var OTHER_ID = 'cat-other';
  var DEFAULT_LIST_ID = 'list-groceries';
  // Colors are dark enough for white band text (>= 3:1).
  var DEFAULT_CATEGORIES = [
    ['Produce', '#2e9e4f'], ['Bakery', '#b9803a'], ['Dairy', '#3f83c9'], ['Meat & Seafood', '#c8445a'],
    ['Frozen', '#2f9db5'], ['Pantry', '#a0693a'], ['Snacks', '#d9732a'], ['Beverages', '#7556c9'],
    ['Household', '#5a6f82'], ['Personal Care', '#c74b93'], ['Other', '#7b8089']
  ];
  var KINDS = ['lists', 'categories', 'items'];

  // Overridable so tests get deterministic times and ids.
  var env = { now: function () { return Date.now(); }, uid: uuid };
  function uuid() {
    var b = new Uint8Array(16);
    root.crypto.getRandomValues(b);
    b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
    var h = Array.prototype.map.call(b, function (x) { return ('0' + x.toString(16)).slice(-2); }).join('');
    return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
  }

  function normName(s) { return String(s).trim().toLowerCase().replace(/\s+/g, ' '); }
  function cleanName(s) { return String(s).trim().replace(/\s+/g, ' '); }
  function slug(s) { return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, ''); }
  function clone(o) { return JSON.parse(JSON.stringify(o)); }
  function find(arr, id) {
    for (var i = 0; i < arr.length; i++) if (arr[i].id === id) return arr[i];
    return null;
  }

  // ---------------- state ----------------
  function emptyOutbox() { return { lists: {}, categories: {}, items: {}, learned: {}, widget: false }; }

  // Seed records use fixed ids and updatedAt 0 and are NOT put in the outbox:
  // two devices seeding independently produce identical records that merge by
  // id, and any real edit (updatedAt > 0) beats the seed on every device.
  function newState() {
    return {
      v: 1, widgetListId: null,
      lists: [{ id: DEFAULT_LIST_ID, name: 'Groceries', order: 0, updatedAt: 0, deleted: false }],
      categories: DEFAULT_CATEGORIES.map(function (c, i) {
        return { id: 'cat-' + slug(c[0]), name: c[0], color: c[1], order: i, updatedAt: 0, deleted: false };
      }),
      items: [], learned: {},
      sync: { cursor: 0, outbox: emptyOutbox(), pending: {}, widgetAt: 0 }
    };
  }

  // State from loadState(): null means first run. Anything not v1 is a bug in
  // whoever wrote it, so it throws instead of being "migrated" silently.
  function normalizeLoaded(state) {
    if (state === null || state === undefined) return newState();
    if (state.v !== 1) throw new Error('unsupported state version ' + state.v);
    var s = state;
    s.lists = s.lists || []; s.categories = s.categories || []; s.items = s.items || [];
    s.learned = s.learned || {};
    s.sync = s.sync || {};
    if (typeof s.sync.cursor !== 'number') s.sync.cursor = 0;
    if (typeof s.sync.widgetAt !== 'number') s.sync.widgetAt = 0;
    s.sync.outbox = s.sync.outbox || emptyOutbox();
    ['lists', 'categories', 'items', 'learned'].forEach(function (k) { s.sync.outbox[k] = s.sync.outbox[k] || {}; });
    s.sync.pending = s.sync.pending || {};
    if (s.widgetListId === undefined) s.widgetListId = null;
    return s;
  }

  // Every write goes through touch(): updatedAt must be strictly newer than the
  // stored copy (two edits in the same ms, or a skewed clock, must still win
  // LWW on the server) and the record joins the outbox until a sync acks it.
  function touch(state, kind, rec) {
    rec.updatedAt = Math.max(env.now(), rec.updatedAt + 1);
    state.sync.outbox[kind][rec.id] = true;
  }
  function setLearned(state, key, categoryId) {
    var cur = state.learned[key];
    state.learned[key] = { c: categoryId, t: Math.max(env.now(), cur ? cur.t + 1 : 0) };
    state.sync.outbox.learned[key] = true;
  }
  function hist(item, what) { item.history.push({ at: env.now(), what: what }); }

  // ---------------- views ----------------
  function byOrder(a, b) { return (a.order - b.order) || (a.id < b.id ? -1 : 1); }
  function liveLists(state) { return state.lists.filter(function (l) { return !l.deleted; }).sort(byOrder); }
  function liveCategories(state) { return state.categories.filter(function (c) { return !c.deleted; }).sort(byOrder); }
  function liveCategory(state, id) {
    var c = find(state.categories, id);
    return c && !c.deleted ? c : null;
  }
  // Items whose category was deleted elsewhere (or never synced here) display as
  // Other, so a merge race can never hide an item.
  function categoryOf(state, item) {
    return liveCategory(state, item.categoryId) || liveCategory(state, OTHER_ID) || liveCategories(state)[0];
  }
  function itemCounts(state) {
    var counts = {};
    state.items.forEach(function (i) {
      if (!i.deleted && !i.checked) counts[i.listId] = (counts[i.listId] || 0) + 1;
    });
    return counts;
  }
  // {groups:[{category, items}], checked:[]} for one list. Groups follow category
  // order, empty ones are omitted; new items sort to the bottom of their group.
  function grouped(state, listId) {
    var cats = liveCategories(state), byCat = {}, checked = [];
    state.items.forEach(function (i) {
      if (i.deleted || i.listId !== listId) return;
      if (i.checked) { checked.push(i); return; }
      var cid = categoryOf(state, i).id;
      (byCat[cid] = byCat[cid] || []).push(i);
    });
    var groups = [];
    cats.forEach(function (c) {
      if (!byCat[c.id]) return;
      byCat[c.id].sort(function (a, b) { return (a.createdAt - b.createdAt) || (a.id < b.id ? -1 : 1); });
      groups.push({ category: c, items: byCat[c.id] });
    });
    checked.sort(function (a, b) { return b.updatedAt - a.updatedAt; });
    return { groups: groups, checked: checked };
  }
  // Autocomplete from every name ever used (including checked and deleted
  // items: deleting an item must not forget the name). Prefix matches first,
  // then by use count; names already unchecked on this list are left out.
  function suggest(state, text, listId, limit) {
    var q = normName(text);
    if (!q) return [];
    var onList = {}, stats = {};
    state.items.forEach(function (i) {
      var k = normName(i.name);
      if (i.listId === listId && !i.deleted && !i.checked) onList[k] = true;
      var s = stats[k] || (stats[k] = { name: i.name, count: 0, last: 0 });
      s.count++;
      if (i.createdAt >= s.last) { s.last = i.createdAt; s.name = i.name; }
    });
    return Object.keys(stats).filter(function (k) { return !onList[k] && k !== q && k.indexOf(q) !== -1; })
      .map(function (k) { return { k: k, s: stats[k], prefix: k.indexOf(q) === 0 }; })
      .sort(function (a, b) { return (b.prefix - a.prefix) || (b.s.count - a.s.count) || (b.s.last - a.s.last); })
      .slice(0, limit || 5).map(function (x) { return x.s.name; });
  }

  // ---------------- categorization ----------------
  // learned (the user's own past choice) beats the bundled dictionary; null means
  // unknown, which sends the item to Other and on to the AI.
  function resolveCategory(state, name) {
    var key = normName(name), l = state.learned[key];
    if (l && liveCategory(state, l.c)) return { id: l.c, how: 'learned' };
    var dict = root.ListsDict && root.ListsDict.lookup(name);
    if (dict) {
      var cat = liveCategories(state).filter(function (c) { return c.name.toLowerCase() === dict.toLowerCase(); })[0];
      return { id: cat ? cat.id : OTHER_ID, how: 'dict' };
    }
    return null;
  }
  function catName(state, id) { var c = find(state.categories, id); return c ? c.name : 'Other'; }

  // ---------------- items ----------------
  // Re-adding a name that is already checked unchecks it (what a shopper means);
  // re-adding one already on the list returns it unchanged.
  function addItem(state, listId, name) {
    name = cleanName(name);
    if (!name) return null;
    var key = normName(name), t = env.now();
    var dup = state.items.filter(function (i) { return !i.deleted && i.listId === listId && normName(i.name) === key; });
    var open = dup.filter(function (i) { return !i.checked; })[0];
    if (open) return open;
    if (dup.length) { toggle(state, dup[0].id); return dup[0]; }
    var r = resolveCategory(state, name);
    var item = {
      id: env.uid(), listId: listId, name: name, note: '', categoryId: r ? r.id : OTHER_ID, checked: false,
      createdAt: t, updatedAt: t, deleted: false, history: [{ at: t, what: 'Added' }]
    };
    if (r) hist(item, 'Categorized as ' + catName(state, r.id));
    else state.sync.pending[item.id] = true; // spinner until the AI answers (or offline retry)
    state.items.push(item);
    state.sync.outbox.items[item.id] = true;
    return item;
  }
  function toggle(state, id) {
    var i = find(state.items, id);
    if (!i || i.deleted) return null;
    i.checked = !i.checked;
    hist(i, i.checked ? 'Checked' : 'Unchecked');
    touch(state, 'items', i);
    return i;
  }
  function renameItem(state, id, name) {
    var i = find(state.items, id);
    name = cleanName(name);
    if (!i || !name || name === i.name) return i;
    hist(i, 'Renamed from "' + i.name + '" to "' + name + '"');
    i.name = name;
    touch(state, 'items', i);
    return i;
  }
  function setNote(state, id, note) {
    var i = find(state.items, id);
    if (!i || i.note === note) return i;
    i.note = note;
    hist(i, note ? 'Note set' : 'Note cleared');
    touch(state, 'items', i);
    return i;
  }
  function deleteItem(state, id) {
    var i = find(state.items, id);
    if (!i || i.deleted) return;
    i.deleted = true;
    delete state.sync.pending[id];
    hist(i, 'Deleted');
    touch(state, 'items', i);
  }
  function deleteChecked(state, listId) {
    state.items.forEach(function (i) { if (i.listId === listId && i.checked && !i.deleted) deleteItem(state, i.id); });
  }
  // A manual choice also clears the AI-pending flag, so a late AI answer for
  // this item is dropped by applyAI, and teaches `learned` for next time.
  function setCategory(state, id, categoryId) {
    var i = find(state.items, id);
    if (!i || i.deleted || !liveCategory(state, categoryId)) return null;
    delete state.sync.pending[id];
    setLearned(state, normName(i.name), categoryId);
    if (i.categoryId !== categoryId) {
      i.categoryId = categoryId;
      hist(i, 'Moved to ' + catName(state, categoryId) + ' by you');
    }
    touch(state, 'items', i);
    return i;
  }
  // The AI answer for an item. Dropped (false) if the item is gone, was already
  // categorized by hand, or was renamed since the request.
  function applyAI(state, id, key, categoryId) {
    var i = find(state.items, id);
    if (!i || i.deleted || !state.sync.pending[id] || normName(i.name) !== key) {
      delete state.sync.pending[id];
      return false;
    }
    delete state.sync.pending[id];
    if (!liveCategory(state, categoryId)) categoryId = OTHER_ID;
    if (!state.learned[key]) setLearned(state, key, categoryId);
    i.categoryId = categoryId;
    hist(i, 'Categorized by AI as ' + catName(state, categoryId));
    touch(state, 'items', i);
    return true;
  }
  function pendingItems(state) {
    return Object.keys(state.sync.pending).map(function (id) { return find(state.items, id); })
      .filter(function (i) { return i && !i.deleted; });
  }

  // ---------------- lists and categories ----------------
  function nextOrder(arr) { return arr.reduce(function (m, r) { return Math.max(m, r.order); }, -1) + 1; }
  function addList(state, name) {
    name = cleanName(name);
    if (!name) return null;
    var l = { id: env.uid(), name: name, order: nextOrder(state.lists), updatedAt: 0, deleted: false };
    state.lists.push(l);
    touch(state, 'lists', l);
    return l;
  }
  function renameList(state, id, name) {
    var l = find(state.lists, id);
    name = cleanName(name);
    if (!l || !name || l.name === name) return l;
    l.name = name;
    touch(state, 'lists', l);
    return l;
  }
  function deleteList(state, id) {
    var l = find(state.lists, id);
    if (!l || l.deleted) return;
    l.deleted = true;
    touch(state, 'lists', l);
    state.items.forEach(function (i) { if (i.listId === id) deleteItem(state, i.id); });
    if (state.widgetListId === id) setWidgetList(state, null);
  }
  // Move one step up (-1) or down (+1) among live records by swapping `order`
  // with the neighbour; only those two records change, so concurrent reorders
  // of other rows elsewhere still merge.
  function move(state, kind, id, dir) {
    var live = kind === 'lists' ? liveLists(state) : liveCategories(state);
    var idx = live.map(function (r) { return r.id; }).indexOf(id), other = live[idx + dir];
    if (idx < 0 || !other) return;
    var a = live[idx], tmp = a.order;
    // Orders can tie after a merge; renumber the pair so the swap always changes something.
    a.order = other.order === tmp ? tmp + dir : other.order;
    other.order = tmp;
    touch(state, kind, a);
    touch(state, kind, other);
  }
  function moveList(state, id, dir) { move(state, 'lists', id, dir); }
  function moveCategory(state, id, dir) { move(state, 'categories', id, dir); }

  function addCategory(state, name, color) {
    name = cleanName(name);
    if (!name) return null;
    var c = { id: env.uid(), name: name, color: color, order: nextOrder(state.categories), updatedAt: 0, deleted: false };
    state.categories.push(c);
    touch(state, 'categories', c);
    return c;
  }
  function editCategory(state, id, patch) {
    var c = find(state.categories, id);
    if (!c) return null;
    if (patch.name !== undefined && cleanName(patch.name)) c.name = cleanName(patch.name);
    if (patch.color !== undefined) c.color = patch.color;
    touch(state, 'categories', c);
    return c;
  }
  // Items of a deleted category fall to Other (each gets a history entry and
  // syncs). Other itself is the fall-back target, so it cannot be deleted.
  function deleteCategory(state, id) {
    if (id === OTHER_ID) throw new Error('Other cannot be deleted');
    var c = find(state.categories, id);
    if (!c || c.deleted) return;
    c.deleted = true;
    touch(state, 'categories', c);
    state.items.forEach(function (i) {
      if (i.categoryId !== id || i.deleted) return;
      i.categoryId = OTHER_ID;
      hist(i, 'Moved to Other (category deleted)');
      touch(state, 'items', i);
    });
  }
  function setWidgetList(state, id) {
    state.widgetListId = id;
    state.sync.widgetAt = Math.max(env.now(), state.sync.widgetAt + 1);
    state.sync.outbox.widget = true;
  }

  // ---------------- sync ----------------
  // The push is the outbox's current records; `sent` remembers the updatedAt of
  // each so an edit made while the request is in flight stays queued.
  function buildPush(state) {
    var sent = { lists: {}, categories: {}, items: {}, learned: {}, widget: null };
    var changes = { lists: [], categories: [], items: [], learned: {} };
    KINDS.forEach(function (k) {
      Object.keys(state.sync.outbox[k]).forEach(function (id) {
        var r = find(state[k], id);
        if (!r) return;
        changes[k].push(clone(r));
        sent[k][id] = r.updatedAt;
      });
    });
    Object.keys(state.sync.outbox.learned).forEach(function (key) {
      var l = state.learned[key];
      if (!l) return;
      changes.learned[key] = { c: l.c, t: l.t };
      sent.learned[key] = l.t;
    });
    if (state.sync.outbox.widget) {
      changes.widgetListId = state.widgetListId;
      changes.widgetListIdAt = state.sync.widgetAt;
      sent.widget = state.sync.widgetAt;
    }
    return { body: { since: state.sync.cursor, changes: changes }, sent: sent };
  }

  // Merge remote records into local, last-write-wins on updatedAt. Equal times
  // keep the local copy (it is either identical or the server's own echo).
  function mergeRecords(state, kind, remote) {
    var arr = state[kind], changed = false;
    remote.forEach(function (r) {
      var cur = find(arr, r.id);
      if (!cur) { arr.push(clone(r)); changed = true; }
      else if (r.updatedAt > cur.updatedAt) { arr[arr.indexOf(cur)] = clone(r); delete state.sync.outbox[kind][r.id]; changed = true; }
      else return;
      // Someone else already moved a pending item out of Other: the AI is not needed.
      if (kind === 'items' && state.sync.pending[r.id] && r.categoryId !== OTHER_ID) delete state.sync.pending[r.id];
    });
    return changed;
  }
  function applySync(state, sent, resp) {
    if (!resp || typeof resp.now !== 'number' || !resp.changes) throw new Error('bad sync response');
    var c = resp.changes, changed = false;
    KINDS.forEach(function (k) { changed = mergeRecords(state, k, c[k] || []) || changed; });
    Object.keys(c.learned || {}).forEach(function (key) {
      var r = c.learned[key], cur = state.learned[key];
      if (!cur || r.t > cur.t) { state.learned[key] = { c: r.c, t: r.t }; delete state.sync.outbox.learned[key]; changed = true; }
    });
    if (typeof c.widgetListIdAt === 'number' && c.widgetListIdAt > state.sync.widgetAt) {
      state.widgetListId = c.widgetListId; state.sync.widgetAt = c.widgetListIdAt; state.sync.outbox.widget = false; changed = true;
    }
    KINDS.forEach(function (k) {
      Object.keys(sent[k]).forEach(function (id) {
        var r = find(state[k], id);
        if (r && r.updatedAt === sent[k][id]) delete state.sync.outbox[k][id];
      });
    });
    Object.keys(sent.learned).forEach(function (key) {
      if (state.learned[key] && state.learned[key].t === sent.learned[key]) delete state.sync.outbox.learned[key];
    });
    if (sent.widget !== null && state.sync.widgetAt === sent.widget) state.sync.outbox.widget = false;
    state.sync.cursor = resp.now;
    return changed;
  }

  function apiFetch(ctx, path, body) {
    return ctx.fetch(ctx.baseUrl + path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + ctx.token },
      body: JSON.stringify(body)
    }).then(function (r) {
      if (!r.ok) throw new Error(path + ' ' + r.status);
      return r.json();
    });
  }
  // One push+pull round trip. ctx = {fetch, baseUrl, token}. Rejects on any
  // failure (offline, 401, 5xx); the caller shows it and retries later.
  function syncOnce(state, ctx) {
    var push = buildPush(state);
    return apiFetch(ctx, '/api/sync', push.body).then(function (resp) { return applySync(state, push.sent, resp); });
  }
  var inflight = {};
  // Ask the box for every still-pending item. Resolves {applied, failed} so the
  // caller can surface failures; failed items stay pending for the next retry.
  function categorizePending(state, ctx) {
    var cats = liveCategories(state).map(function (c) { return { id: c.id, name: c.name }; });
    var jobs = pendingItems(state).filter(function (i) { return !inflight[i.id]; }).map(function (i) {
      var key = normName(i.name);
      inflight[i.id] = true;
      return apiFetch(ctx, '/api/categorize', { name: i.name, categories: cats }).then(function (r) {
        return applyAI(state, i.id, key, r.categoryId) ? 'applied' : 'dropped';
      }).then(function (v) { delete inflight[i.id]; return { ok: v }; }, function (e) { delete inflight[i.id]; return { err: e }; });
    });
    return Promise.all(jobs).then(function (rs) {
      return {
        applied: rs.filter(function (r) { return r.ok === 'applied'; }).length,
        failed: rs.filter(function (r) { return r.err; }).map(function (r) { return r.err; })
      };
    });
  }

  function formatTime(t, now) {
    var d = new Date(t), n = new Date(now === undefined ? env.now() : now);
    var h = d.getHours() % 12 || 12, m = ('0' + d.getMinutes()).slice(-2), ap = d.getHours() < 12 ? 'AM' : 'PM';
    var clock = h + ':' + m + ' ' + ap;
    if (d.toDateString() === n.toDateString()) return 'Today ' + clock;
    var months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return months[d.getMonth()] + ' ' + d.getDate() + ', ' + clock;
  }

  return {
    OTHER_ID: OTHER_ID, DEFAULT_LIST_ID: DEFAULT_LIST_ID, DEFAULT_CATEGORIES: DEFAULT_CATEGORIES,
    setEnv: function (o) { if (o.now) env.now = o.now; if (o.uid) env.uid = o.uid; },
    normName: normName, find: find, newState: newState, normalizeLoaded: normalizeLoaded,
    liveLists: liveLists, liveCategories: liveCategories, categoryOf: categoryOf, itemCounts: itemCounts,
    grouped: grouped, suggest: suggest, resolveCategory: resolveCategory,
    addItem: addItem, toggle: toggle, renameItem: renameItem, setNote: setNote, deleteItem: deleteItem,
    deleteChecked: deleteChecked, setCategory: setCategory, applyAI: applyAI, pendingItems: pendingItems,
    addList: addList, renameList: renameList, deleteList: deleteList, moveList: moveList,
    addCategory: addCategory, editCategory: editCategory, deleteCategory: deleteCategory, moveCategory: moveCategory,
    setWidgetList: setWidgetList,
    buildPush: buildPush, applySync: applySync, syncOnce: syncOnce, categorizePending: categorizePending,
    formatTime: formatTime
  };
});

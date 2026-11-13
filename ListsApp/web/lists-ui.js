// Lists UI: screens, navigation, persistence and sync wiring. All list logic
// (categorizing, LWW merge, history) lives in lists-core.js (ListsCore); this
// file only renders state and calls the core, so every write is optimistic by
// construction: mutate state in memory, save, repaint, THEN let the network
// catch up in the background.
(function () {
  'use strict';
  var Core = window.ListsCore;

  // ------------------------------------------------------------------ bridge
  // Native handler `lists` speaks the gl-bridge protocol ({id,method,params} out,
  // window.__glReply(id,result,error) back). We do NOT load gl-bridge.js: its
  // call() targets the `gl` handler, so this page keeps its own tiny client.
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lists;
  var calls = {}, nextCall = 1;
  function bridgeCall(method, params) {
    return new Promise(function (resolve, reject) {
      var id = nextCall++;
      calls[id] = { resolve: resolve, reject: reject };
      handler.postMessage({ id: id, method: method, params: params || {} });
    });
  }
  window.__glReply = function (id, result, error) {
    var c = calls[id];
    if (!c) return;
    delete calls[id];
    if (error) c.reject(new Error(typeof error === 'string' ? error : (error.message || JSON.stringify(error))));
    else c.resolve(result);
  };

  // ------------------------------------------------------------------ state
  var LS_KEY = 'lists.state.v1';
  var state = null;          // the whole app state blob (see lists-core.js)
  var ctx = null;            // {fetch, baseUrl, token} once we have credentials
  var loaded = false;        // LOAD-BEARING: save() refuses to run before a successful load,
                             // otherwise a failed loadState would overwrite real data with a seed.

  // Reads state from native (bridge) or localStorage (plain browser). Resolves
  // the raw blob or null (first run). A rejection is shown as a Retry screen.
  function loadRaw() {
    if (handler) return bridgeCall('loadState').then(function (r) { return r ? r.state : null; });
    var s = localStorage.getItem(LS_KEY);
    return Promise.resolve(s ? JSON.parse(s) : null);
  }

  var saveTimer = null;
  // Debounced (<=300ms, per contract) persist. Called after EVERY mutation;
  // the visibilitychange handler flushes immediately so a backgrounded app
  // never loses the last 250ms of edits.
  function save() {
    if (!loaded) return;
    if (saveTimer) return;
    saveTimer = setTimeout(flushSave, 250);
  }
  function flushSave() {
    if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; }
    if (!loaded) return;
    if (handler) bridgeCall('saveState', { state: state }).catch(function (e) { console.error('saveState failed', e); setStatus('error'); });
    else localStorage.setItem(LS_KEY, JSON.stringify(state));
  }

  // ------------------------------------------------------------------ dom helpers
  // h('div', {class:'x', onclick:fn, text:'t'}, [children]) -> element. Text goes
  // through textContent only, so item names can never inject markup.
  function h(tag, props, kids) {
    var e = document.createElement(tag);
    Object.keys(props || {}).forEach(function (k) {
      var v = props[k];
      if (v === undefined || v === null || v === false) return;
      if (k === 'class') e.className = v;
      else if (k === 'text') e.textContent = v;
      else if (k === 'html') e.innerHTML = v;       // only ever our own icon strings
      else if (k === 'style') e.style.cssText = v;
      else if (k.indexOf('on') === 0) e.addEventListener(k.slice(2), v);
      else e.setAttribute(k, v === true ? '' : v);
    });
    (kids || []).forEach(function (c) { if (c) e.appendChild(c); });
    return e;
  }
  var ICONS = {
    back: '<path d="M15 5l-7 7 7 7"/>', fwd: '<path d="M9 5l7 7-7 7"/>', up: '<path d="M6 15l6-6 6 6"/>',
    down: '<path d="M6 9l6 6 6-6"/>', check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>', plus: '<path d="M12 5v14M5 12h14"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.01"/>', gear: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
    pencil: '<path d="M4 20l1-4L16 5l3 3L8 19l-4 1zM14 7l3 3"/>',
    tag: '<path d="M3 12V4h8l10 10-8 8L3 12z"/><circle cx="7.5" cy="8.5" r="1"/>'
  };
  function ico(name) { return '<svg viewBox="0 0 24 24" aria-hidden="true">' + ICONS[name] + '</svg>'; }
  function iconBtn(name, label, cls, fn) { return h('button', { class: cls, html: ico(name), 'aria-label': label, onclick: fn }); }

  // ------------------------------------------------------------------ navigation
  // stack of {route, scroll}. The last entry is the visible screen; `scroll` of
  // every OTHER entry is the offset of its .scroll element when we left it.
  var stack = [{ route: { name: 'home' }, scroll: 0 }];
  var ui = { edit: false, showChecked: false, pickOpen: false };   // transient, never persisted

  // ---- never drop typed text ----
  // fieldFlushers: detail-screen fields (rebuilt on every repaint). sheetFlushers:
  // open sheets (destroyed by any screen change). flushAll() runs before ANY
  // navigation or repaint so an edit still sitting in a debounce timer (or in a
  // sheet) is committed instead of being wiped by the rebuild.
  var fieldFlushers = [], sheetFlushers = [];
  function flushFields() { fieldFlushers.slice().forEach(function (f) { f(); }); }
  function flushAll() {
    flushFields();
    var sf = sheetFlushers; sheetFlushers = [];
    sf.forEach(function (f) { f(); });
  }
  // Commit without repainting: used while a field is focused, because a repaint
  // would rebuild the very input being typed in.
  function quiet(fn) { fn(state); save(); scheduleSync(); }

  // ---- two-step destructive confirm (state machine lives in the core) ----
  // First tap arms: the button turns red and says what will go. Second tap does
  // it. A tap anywhere else, or any repaint/navigation, disarms.
  var conf = Core.makeConfirm(), armedBtn = null;
  function disarm() { conf.disarm(); if (armedBtn) { armedBtn.reset(); armedBtn = null; } }
  function confirmBtn(key, label, armedLabel, cls, fn) {
    var b = h('button', { class: cls, text: label });
    b.reset = function () { b.classList.remove('armed'); b.textContent = label; };
    b.addEventListener('click', function (e) {
      e.stopPropagation();
      if (conf.tap(key)) { armedBtn = null; fn(); return; }
      if (armedBtn && armedBtn !== b) armedBtn.reset();
      b.classList.add('armed'); b.textContent = armedLabel; armedBtn = b;
    });
    return b;
  }
  document.addEventListener('pointerdown', function (e) { if (armedBtn && !armedBtn.contains(e.target)) disarm(); }, true);

  // ---- undo chip after checking an item ----
  var undoTimer = null;
  function hideUndo() { if (undoTimer) { clearTimeout(undoTimer); undoTimer = null; } var u = document.querySelector('.addwrap .undo'); if (u) u.innerHTML = ''; }
  function showUndo(it) {
    var u = document.querySelector('.addwrap .undo');
    if (!u) return;
    hideUndo();
    u.appendChild(h('span', { class: 'nm', text: it.name }));
    u.appendChild(h('button', { text: 'Undo', onclick: function () { hideUndo(); mutate(function (s) { Core.toggle(s, it.id); }); } }));
    undoTimer = setTimeout(hideUndo, 4000);
  }
  function cur() { return stack[stack.length - 1]; }
  function scroller() { return document.querySelector('.scroll'); }

  // Forward navigation. Saves the scroll offset of the screen being LEFT from
  // the element that actually scrolls (.scroll, not window), so back() can put
  // it back. The new screen starts at the top (fresh open).
  function go(route) {
    flushAll(); disarm(); hideUndo();
    var s = scroller();
    cur().scroll = s ? s.scrollTop : 0;
    stack.push({ route: route, scroll: 0 });
    ui.edit = ui.pickOpen = false;
    renderScreen();
  }
  // The ONE back path: nav chevron and left-edge swipe both call this.
  // The scroll offset is restored AFTER renderScreen() has rebuilt the content,
  // because setting scrollTop before the height exists gets clamped to 0.
  function back() {
    if (stack.length < 2) return;
    flushAll(); disarm(); hideUndo();
    stack.pop();
    ui.edit = ui.pickOpen = false;
    renderScreen();
    var s = scroller();
    if (s) s.scrollTop = cur().scroll;
  }
  // Native -> page: show a given list (widget tap). Starts at the top of it.
  window.__listsOpen = function (p) {
    if (!state || !p || !Core.find(state.lists, p.listId)) return;
    flushAll(); disarm(); hideUndo();
    stack = [{ route: { name: 'home' }, scroll: 0 }, { route: { name: 'list', id: p.listId }, scroll: 0 }];
    renderScreen();
  };
  window.__listsForeground = function () { syncNow(); kickCategorize(); };

  // JS edge-swipe back. The WKWebView has native back gestures off (single
  // page, no history entries), so we detect a touch/pointer that starts within
  // 24px of the left edge and travels right >70px, mostly horizontally.
  var swipe = null;
  document.addEventListener('pointerdown', function (e) {
    swipe = e.clientX <= 24 ? { x: e.clientX, y: e.clientY } : null;
  }, true);
  document.addEventListener('pointerup', function (e) {
    var s = swipe; swipe = null;
    if (s && e.clientX - s.x > 70 && Math.abs(e.clientY - s.y) < 60) back();
  }, true);
  document.addEventListener('pointercancel', function () { swipe = null; }, true);

  // ------------------------------------------------------------------ mutate + sync
  // The only way UI code changes state: apply, persist, repaint at once, then
  // schedule a background sync. Nothing here waits on the network.
  function mutate(fn) {
    flushFields();
    var r = fn(state);
    save();
    refresh(true);
    scheduleSync();
    return r;
  }

  var syncing = false, lastFailed = false, online = true, syncTimer = null;
  function outboxCount() {
    var o = state.sync.outbox, n = 0;
    ['lists', 'categories', 'items', 'learned'].forEach(function (k) { n += Object.keys(o[k]).length; });
    return n + (o.widget ? 1 : 0) + Object.keys(state.sync.pending).length;
  }
  // 'ok' | 'pending' (both hidden: pending edits are not worth a badge) | 'error' (red button, tap retries).
  function setStatus(forced) {
    var s = forced || (lastFailed ? 'error' : (state && (outboxCount() || syncing) ? 'pending' : 'ok'));
    var el = document.querySelector('.sync');
    if (el) el.setAttribute('data-status', s);
  }
  function scheduleSync() {
    setStatus();
    if (syncTimer) clearTimeout(syncTimer);
    syncTimer = setTimeout(function () { syncTimer = null; syncNow(); kickCategorize(); }, 400);
  }
  // One push+pull. Single-flight: a write made mid-flight stays in the outbox
  // (core keeps it by updatedAt) and the trailing scheduleSync() picks it up.
  function syncNow() {
    if (!ctx || syncing || !state) return Promise.resolve();
    syncing = true; setStatus();
    return Core.syncOnce(state, ctx).then(function (changed) {
      lastFailed = false;
      save();
      if (changed) refresh(false);
    }).catch(function (e) {
      lastFailed = true;
      console.warn('sync failed', e);
    }).then(function () {
      syncing = false; setStatus();
      if (!lastFailed && Object.keys(state.sync.outbox.items).length + Object.keys(state.sync.outbox.lists).length + Object.keys(state.sync.outbox.categories).length > 0) scheduleSync();
    });
  }
  // Ask the box to categorize items still in Other. Failures leave them
  // pending (spinner stays) and are retried on online/foreground/poll.
  function kickCategorize() {
    if (!ctx || !state || !Core.pendingItems(state).length) return;
    Core.categorizePending(state, ctx).then(function (r) {
      if (r.applied) { save(); refresh(false); scheduleSync(); }
      if (r.failed.length) { lastFailed = true; console.warn('categorize failed', r.failed[0]); }
      else lastFailed = false;
      setStatus();
    });
  }
  window.addEventListener('online', function () { online = true; syncNow(); kickCategorize(); });
  window.addEventListener('offline', function () { online = false; });
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') flushSave();
    else { syncNow(); kickCategorize(); }
  });
  // Light poll while visible so edits from another device show up without a tap.
  setInterval(function () {
    if (document.visibilityState === 'visible' && state) { syncNow(); kickCategorize(); }
  }, 15000);

  // ------------------------------------------------------------------ sheets
  // Modal bottom sheet (window.prompt/confirm are unavailable in WKWebView).
  // opts: {title, value, placeholder, okLabel, onOk(value), extra: node, danger:{label,onClick}}
  function sheet(opts) {
    var screen = document.querySelector('.screen');
    var input = opts.placeholder !== undefined || opts.value !== undefined
      ? h('input', { class: 'field', value: opts.value || '', placeholder: opts.placeholder || '', autocapitalize: 'words', enterkeyhint: 'done' }) : null;
    function close() { disarm(); sheetFlushers = sheetFlushers.filter(function (f) { return f !== flush; }); if (bd.parentNode) bd.parentNode.removeChild(bd); }
    // Navigation while the sheet is open: keep what was typed (a changed, non-empty value is saved).
    function flush() { if (input && input.value.trim() && input.value !== (opts.value || '')) ok(); else close(); }
    function ok() {
      var v = input ? input.value : '';
      if (input && !v.trim()) return;
      close();
      opts.onOk(v, opts);
    }
    var actions = [h('button', { text: 'Cancel', onclick: close })];
    if (opts.danger) actions.unshift(confirmBtn('sheet-del', opts.danger.label, opts.danger.armedLabel || 'Delete?', 'danger', function () { close(); opts.danger.onClick(); }));
    actions.push(h('button', { class: 'primary', text: opts.okLabel || 'Save', onclick: ok }));
    var bd = h('div', { class: 'backdrop', onclick: function (e) { if (e.target === bd) close(); } }, [
      h('div', { class: 'sheet' }, [h('h2', { text: opts.title }), input, opts.extra, h('div', { class: 'sheet-actions' }, actions)])
    ]);
    if (input) input.addEventListener('keydown', function (e) { if (e.key === 'Enter') ok(); });
    screen.appendChild(bd);
    sheetFlushers.push(flush);
    if (input) { input.focus(); input.select(); }
  }

  var PALETTE = ['#e53935', '#f4511e', '#fb8c00', '#c79100', '#7cb342', '#43a047', '#00897b', '#00acc1', '#1e88e5', '#3949ab', '#8e24aa', '#d81b60', '#6d4c41', '#757575'];
  // Swatch grid; `pick` holds the chosen color for the sheet's onOk to read.
  function swatches(pick) {
    var wrap = h('div', { class: 'swatches' });
    // A category's current colour may be outside the palette (seeded pastels): show it as its own swatch so the selection is always visible.
    var colors = PALETTE.indexOf(pick.color) < 0 ? [pick.color].concat(PALETTE) : PALETTE;
    wrap.style.gridTemplateColumns = 'repeat(' + Math.ceil(colors.length / 2) + ', 1fr)';
    function paint() {
      wrap.innerHTML = '';
      colors.forEach(function (c) {
        wrap.appendChild(h('button', { class: c === pick.color ? 'on' : '', 'aria-label': c, 'aria-pressed': c === pick.color ? 'true' : 'false', onclick: function () { pick.color = c; paint(); } }, [h('i', { style: 'background:' + c })]));
      });
    }
    paint();
    return wrap;
  }

  // ------------------------------------------------------------------ screens
  // Each screen returns {title, left, right, body(), add}. body() builds the
  // scroller's contents and is re-run on every refresh; nav/add are built once
  // per route change so the add input keeps focus while the list repaints.
  function syncDot() {
    return h('button', { class: 'sync', 'data-status': 'ok', 'aria-label': 'Sync', onclick: function () { lastFailed = false; syncNow(); kickCategorize(); } }, [h('i', { text: '!' })]);
  }
  function navBack() { return h('button', { class: 'nav-btn', html: ico('back'), 'aria-label': 'Back', onclick: back }); }

  function homeScreen() {
    return {
      title: 'Lists',
      left: [h('button', { class: 'nav-btn', html: ico('gear'), 'aria-label': 'Settings', onclick: function () { go({ name: 'settings' }); } })],
      right: function () {
        return [syncDot(),
          h('button', { class: 'nav-btn', text: ui.edit ? 'Done' : 'Edit', onclick: function () { ui.edit = !ui.edit; refresh(true); } }),
          iconBtn('plus', 'Add list', 'nav-btn', function () {
            sheet({ title: 'New list', value: '', placeholder: 'Name', okLabel: 'Add', onOk: function (v) { mutate(function (s) { Core.addList(s, v); }); } });
          })];
      },
      body: function () {
        var counts = Core.itemCounts(state), lists = Core.liveLists(state);
        var ul = h('div', { class: 'rows' });
        lists.forEach(function (l, i) {
          ul.appendChild(h('div', { class: 'row', onclick: function () {
            if (ui.edit) editList(l); else go({ name: 'list', id: l.id });
          } }, [
            h('div', { class: 'grow nm', text: l.name }),
            ui.edit ? h('div', { class: 'tail' }, [
              iconBtn('pencil', 'Rename or delete', 'icon-btn', function (e) { e.stopPropagation(); editList(l); }),
              i > 0 ? iconBtn('up', 'Move up', 'icon-btn', function (e) { e.stopPropagation(); mutate(function (s) { Core.moveList(s, l.id, -1); }); }) : null,
              i < lists.length - 1 ? iconBtn('down', 'Move down', 'icon-btn', function (e) { e.stopPropagation(); mutate(function (s) { Core.moveList(s, l.id, 1); }); }) : null
            ]) : h('div', { class: 'tail' }, [h('span', { class: 'count', text: counts[l.id] ? String(counts[l.id]) : '' }), h('span', { class: 'chev', html: ico('fwd') })])
          ]));
        });
        var cats = h('div', { class: 'rows section' }, [
          h('div', { class: 'row', onclick: function () { go({ name: 'cats' }); } }, [
            h('div', { class: 'grow nm', text: 'Categories' }), h('div', { class: 'tail' }, [h('span', { class: 'chev', html: ico('fwd') })])])
        ]);
        return [ul, cats];
      }
    };
  }
  function editList(l) {
    var n = state.items.filter(function (i) { return !i.deleted && i.listId === l.id; }).length;
    sheet({
      title: 'Rename list', value: l.name, placeholder: 'Name', okLabel: 'Save',
      onOk: function (v) { mutate(function (s) { Core.renameList(s, l.id, v); }); },
      danger: { label: 'Delete', armedLabel: n ? 'Delete ' + n + ' items?' : 'Delete?', onClick: function () { mutate(function (s) { Core.deleteList(s, l.id); }); } }
    });
  }

  function listScreen(id) {
    var list = Core.find(state.lists, id);
    // Add-field handler. Enter adds and keeps focus: the input element survives
    // because refresh() only rebuilds .scroll, never the add bar.
    var input, sugg;
    function add(name) {
      if (!name.trim()) return;
      mutate(function (s) { Core.addItem(s, id, name); });
      input.value = ''; sugg.innerHTML = '';
      kickCategorize();
    }
    function showSugg() {
      sugg.innerHTML = '';
      Core.suggest(state, input.value, id, 5).forEach(function (n) {
        // mousedown preventDefault keeps focus (and the on-screen keyboard) on the input.
        sugg.appendChild(h('button', { text: n, onmousedown: function (e) { e.preventDefault(); }, onclick: function () { add(n); } }));
      });
    }
    input = h('input', { type: 'text', placeholder: 'Add item', enterkeyhint: 'done', autocapitalize: 'sentences', autocomplete: 'off', autocorrect: 'off',
      oninput: showSugg, onkeydown: function (e) { if (e.key === 'Enter') { e.preventDefault(); add(input.value); } } });
    sugg = h('div', { class: 'sugg' });
    return {
      title: list ? list.name : '',
      left: [navBack()],
      right: function () { return [syncDot()]; },
      add: h('div', { class: 'addwrap' }, [h('div', { class: 'undo' }), sugg, h('div', { class: 'addbar' }, [input,
        h('button', { html: ico('plus'), 'aria-label': 'Add', onmousedown: function (e) { e.preventDefault(); }, onclick: function () { add(input.value); } })])]),
      body: function () {
        var g = Core.grouped(state, id), out = [];
        g.groups.forEach(function (grp) {
          var box = h('div', { class: 'group' }, [h('div', { class: 'band', style: 'background:' + grp.category.color + ';color:' + Core.textOn(grp.category.color), text: grp.category.name })]);
          var rows = h('div', { class: 'rows' });
          grp.items.forEach(function (it) { rows.appendChild(itemRow(it)); });
          box.appendChild(rows);
          out.push(box);
        });
        if (g.checked.length) {
          out.push(h('div', { class: 'checked-hd' + (ui.showChecked ? ' open' : '') }, [
            h('button', { html: ico('fwd') }, [h('span', { text: 'Checked (' + g.checked.length + ')' })]),
            ui.showChecked ? confirmBtn('chk:' + id, 'Delete checked', 'Delete ' + g.checked.length + '?', 'del', function () { mutate(function (s) { Core.deleteChecked(s, id); }); }) : null
          ]));
          out[out.length - 1].firstChild.addEventListener('click', function () { ui.showChecked = !ui.showChecked; refresh(true); });
          if (ui.showChecked) {
            var rows2 = h('div', { class: 'rows' });
            g.checked.forEach(function (it) { rows2.appendChild(itemRow(it)); });
            out.push(rows2);
          }
        }
        return out;
      }
    };
  }
  // One item row: tapping anywhere checks/unchecks; the (i) button opens detail.
  // A spinner replaces the info button's neighbour while the AI is categorizing.
  function itemRow(it) {
    var pending = !!state.sync.pending[it.id];
    return h('div', { class: 'row item' + (it.checked ? ' done' : ''), onclick: function () { var was = it.checked; mutate(function (s) { Core.toggle(s, it.id); }); if (!was) showUndo(it); } }, [
      h('div', { class: 'chk-col' }, [h('span', { class: 'chk' })]),
      h('div', { class: 'grow' }, [h('span', { class: 'nm', text: it.name }), it.note ? h('span', { class: 'note', text: it.note }) : null]),
      pending ? h('span', { class: 'spin', 'aria-label': 'Categorizing' }) : null,
      iconBtn('info', 'Details', 'icon-btn', function (e) { e.stopPropagation(); go({ name: 'item', id: it.id }); })
    ]);
  }

  function itemScreen(id) {
    var it = Core.find(state.items, id);
    return {
      title: 'Item',
      left: [navBack()],
      right: function () { return [syncDot()]; },
      body: function () {
        var out = [];
        // Name and note commit from a debounced `input` (and on blur/Enter), and
        // flushFields() commits any pending edit before every navigation or repaint.
        // quiet() = no repaint while the field is being typed in.
        var name = h('input', { class: 'field', value: it.name, 'aria-label': 'Name', enterkeyhint: 'done' });
        var note = h('input', { class: 'field', value: it.note, placeholder: 'Note', 'aria-label': 'Note', enterkeyhint: 'done' });
        var nameC = Core.makeFieldCommit(function () { quiet(function (s) { Core.renameItem(s, id, name.value); }); }, 800);
        var noteC = Core.makeFieldCommit(function () { quiet(function (s) { Core.setNote(s, id, note.value.trim()); }); }, 800);
        name.addEventListener('input', nameC.input); note.addEventListener('input', noteC.input);
        name.addEventListener('change', nameC.flush); note.addEventListener('change', noteC.flush);
        fieldFlushers.push(nameC.flush, noteC.flush);
        // Enter commits, closes the keyboard and repaints so History shows the edit.
        [name, note].forEach(function (i) { i.addEventListener('keydown', function (e) { if (e.key === 'Enter') { i.blur(); flushFields(); refresh(true); } }); });
        out.push(h('div', { class: 'rows section' }, [name, h('div', { class: 'fdiv' }), note]));
        out.push(h('div', { class: 'label', text: 'Category' }));
        // Collapsed to the current category; tap expands the full picker.
        var cats = h('div', { class: 'rows' });
        var curCat = Core.categoryOf(state, it).id;
        var pend = state.sync.pending[id];
        Core.liveCategories(state).forEach(function (c) {
          var on = c.id === curCat;
          if (!ui.pickOpen && !on) return;
          cats.appendChild(h('div', { class: 'row pick', onclick: function () {
            if (!ui.pickOpen) { ui.pickOpen = true; refresh(true); return; }
            ui.pickOpen = false;
            if (on) refresh(true); else mutate(function (s) { Core.setCategory(s, id, c.id); });
          } }, [
            h('span', { class: 'dot', style: 'background:' + c.color }), h('div', { class: 'grow nm', text: c.name }),
            pend && on ? h('span', { class: 'spin' }) : null,
            h('span', { class: 'check', html: ui.pickOpen ? (on ? ico('check') : '') : ico('down') })
          ]));
        });
        out.push(cats);
        out.push(h('div', { class: 'label', text: 'History' }));
        var hist = h('div', { class: 'rows hist' });
        it.history.slice().reverse().forEach(function (e) {
          hist.appendChild(h('div', { class: 'row' }, [h('div', { class: 'grow', text: e.what }), h('span', { class: 'when', text: Core.formatTime(e.at) })]));
        });
        out.push(hist);
        // Leave FIRST: mutate() repaints, and repainting a deleted item's detail
        // screen would hit renderScreen's "target vanished" pop and then our back() would pop twice.
        out.push(confirmBtn('item:' + id, 'Delete', 'Delete?', 'btn-danger', function () { back(); mutate(function (s) { Core.deleteItem(s, id); }); }));
        return out;
      }
    };
  }

  function catsScreen() {
    function editCat(c) {
      var pick = { color: c.color }, isOther = c.id === Core.OTHER_ID;
      sheet({
        title: 'Category', value: c.name, placeholder: 'Name', okLabel: 'Save', extra: swatches(pick),
        onOk: function (v) { mutate(function (s) { Core.editCategory(s, c.id, { name: v, color: pick.color }); }); },
        danger: isOther ? null : { label: 'Delete', armedLabel: 'Delete?', onClick: function () { mutate(function (s) { Core.deleteCategory(s, c.id); }); } }
      });
    }
    return {
      title: 'Categories',
      left: [navBack()],
      right: function () {
        return [syncDot(),
          h('button', { class: 'nav-btn', text: ui.edit ? 'Done' : 'Edit', onclick: function () { ui.edit = !ui.edit; refresh(true); } }),
          iconBtn('plus', 'Add category', 'nav-btn', function () {
            var pick = { color: PALETTE[8] };
            sheet({ title: 'New category', value: '', placeholder: 'Name', okLabel: 'Add', extra: swatches(pick),
              onOk: function (v) { mutate(function (s) { Core.addCategory(s, v, pick.color); }); } });
          })];
      },
      body: function () {
        var cats = Core.liveCategories(state), rows = h('div', { class: 'rows section' });
        cats.forEach(function (c, i) {
          rows.appendChild(h('div', { class: 'row', onclick: function () { editCat(c); } }, [
            h('span', { class: 'dot', style: 'background:' + c.color }), h('div', { class: 'grow nm', text: c.name }),
            ui.edit ? h('div', { class: 'tail' }, [
              i > 0 ? iconBtn('up', 'Move up', 'icon-btn', function (e) { e.stopPropagation(); mutate(function (s) { Core.moveCategory(s, c.id, -1); }); }) : null,
              i < cats.length - 1 ? iconBtn('down', 'Move down', 'icon-btn', function (e) { e.stopPropagation(); mutate(function (s) { Core.moveCategory(s, c.id, 1); }); }) : null
            ]) : h('div', { class: 'tail' }, [h('span', { class: 'chev', html: ico('fwd') })])
          ]));
        });
        return [rows];
      }
    };
  }

  function settingsScreen() {
    return {
      title: 'Settings',
      left: [navBack()],
      right: function () { return [syncDot()]; },
      body: function () {
        var rows = h('div', { class: 'rows' });
        Core.liveLists(state).forEach(function (l) {
          rows.appendChild(h('div', { class: 'row pick', onclick: function () { mutate(function (s) { Core.setWidgetList(s, l.id); }); } }, [
            h('div', { class: 'grow nm', text: l.name }),
            h('span', { class: 'check', html: state.widgetListId === l.id ? ico('check') : '' })
          ]));
        });
        return [h('div', { class: 'label', text: 'Widget list' }), rows];
      }
    };
  }

  // ------------------------------------------------------------------ render
  var view = null;   // the current screen object, so refresh() can re-run body()
  function build(route) {
    if (route.name === 'home') return homeScreen();
    if (route.name === 'list') return Core.find(state.lists, route.id) && !Core.find(state.lists, route.id).deleted ? listScreen(route.id) : null;
    if (route.name === 'item') { var i = Core.find(state.items, route.id); return i && !i.deleted ? itemScreen(route.id) : null; }
    if (route.name === 'cats') return catsScreen();
    if (route.name === 'settings') return settingsScreen();
    throw new Error('unknown route ' + route.name);
  }
  // Full render for a route change: nav, scroller and (list only) add bar.
  // If the target was deleted (e.g. by another device) we fall back one screen.
  function renderScreen() {
    var app = document.getElementById('app');
    flushAll();   // a sheet or field from the screen being replaced must not lose its text
    view = build(cur().route);
    if (!view) { stack.pop(); if (!stack.length) stack = [{ route: { name: 'home' }, scroll: 0 }]; renderScreen(); return; }
    app.innerHTML = '';
    var screen = h('div', { class: 'screen' + (view.add ? ' has-add' : '') }, [
      h('div', { class: 'nav' }, [
        h('div', { class: 'nav-slot', 'data-slot': 'left' }, view.left || []),
        h('h1', { text: view.title }),
        h('div', { class: 'nav-slot right', 'data-slot': 'right' }, [])
      ]),
      h('div', { class: 'scroll' }),
      view.add
    ]);
    app.appendChild(screen);
    paintRight(); paintBody();
    setStatus();
  }
  function paintRight() {
    var slot = document.querySelector('[data-slot="right"]');
    slot.innerHTML = '';
    (view.right ? view.right() : []).forEach(function (n) { slot.appendChild(n); });
  }
  function paintBody() {
    var s = scroller(), top = s.scrollTop;
    disarm(); fieldFlushers = [];   // fields were flushed by the caller; the new body builds new ones
    s.innerHTML = '';
    view.body().forEach(function (n) { s.appendChild(n); });
    s.scrollTop = top;   // content swap keeps the reader's place
  }
  // Repaint after a state change without touching the add bar or open sheets.
  // `force` = our own write; a remote/background repaint (force=false) is skipped
  // while a detail-screen field has focus so it cannot eat what's being typed.
  function refresh(force) {
    if (!view) return;
    var a = document.activeElement;
    if (!force && a && a.tagName === 'INPUT' && a.closest('.scroll')) return;
    flushFields();   // commit typed text BEFORE the rebuild replaces the input
    var r = cur().route;
    if (!build(r)) { renderScreen(); return; }       // target vanished
    if (r.name === 'item' || r.name === 'list') {
      var fresh = build(r);
      view.body = fresh.body; view.title = fresh.title;   // keep the live add bar, take new closures
      document.querySelector('.nav h1').textContent = view.title;
    } else { view = build(r); document.querySelector('.nav h1').textContent = view.title; }
    paintRight(); paintBody(); setStatus();
  }

  // ------------------------------------------------------------------ boot
  function fatal(msg) {
    var app = document.getElementById('app');
    app.innerHTML = '';
    app.appendChild(h('div', { class: 'fatal' }, [h('div', { class: 't', text: 'Couldn\u2019t load' }), h('div', { class: 'why', text: msg }), h('button', { text: 'Retry', onclick: boot })]));
  }
  // Load state, then show the UI immediately; credentials and the first sync
  // arrive afterwards so a slow/offline network never delays first paint.
  function boot() {
    loadRaw().then(function (raw) {
      state = Core.normalizeLoaded(raw);
      loaded = true;
      if (raw === null) flushSave();
      renderScreen();
      return credentials();
    }).then(function () { syncNow(); kickCategorize(); }, function (e) {
      if (!loaded) fatal(e.message);
      else console.error(e);
    });
  }
  function credentials() {
    var p = handler ? bridgeCall('getApiToken') : Promise.resolve(window.LISTS_CONFIG);
    return p.then(function (c) {
      if (c && c.token) ctx = { fetch: window.fetch.bind(window), baseUrl: c.baseUrl || '', token: c.token };
      else { lastFailed = true; setStatus(); }
    }, function (e) { lastFailed = true; console.error('getApiToken failed', e); setStatus(); });
  }

  // ------------------------------------------------------------------ keyboard
  // Same precedent as CycleApp: a WKWebView keyboard overlays the page (dvh and
  // innerHeight do not shrink) while visualViewport does. #app takes its height
  // from --vvh so the add bar and sheets ride above the keys; `kb` drops the
  // home-indicator padding (the keyboard covers that area). The input accessory
  // bar is already removed natively (ListsViewController hideInputAccessoryBar).
  if (window.visualViewport) {
    var vv = window.visualViewport;
    var fit = function () {
      var root = document.documentElement;
      root.style.setProperty('--vvh', vv.height + 'px');
      root.classList.toggle('kb', window.innerHeight - vv.height > 100);
      if (window.scrollY || vv.offsetTop) window.scrollTo(0, 0);   // iOS scrolls the page to reveal the caret; the page must stay put
      var a = document.activeElement, sc = scroller();
      if (a && sc && sc.contains(a)) { var r = a.getBoundingClientRect(), v = sc.getBoundingClientRect(); if (r.bottom > v.bottom) sc.scrollTop += r.bottom - v.bottom + 12; }
    };
    vv.addEventListener('resize', fit); vv.addEventListener('scroll', fit);
  }

  // Test/debug surface (read by the Playwright scroll+swipe checks).
  window.ListsUI = { go: go, back: back, stack: function () { return stack; }, state: function () { return state; }, syncNow: syncNow };
  boot();
})();

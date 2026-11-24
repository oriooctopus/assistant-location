// Insights generative-UI blocks: pure logic + HTML strings, no DOM, no network. Loaded as a classic script (global CycleBlocks) in the app
// and via vm in the unit tests (cycle-blocks.test.mjs).
//
// The model writes a fenced block whose info string is "ui" and whose body is one JSON object:
//   ```ui
//   {"type":"chart","dataset":"fights_by_month","kind":"bar"}
//   ```
// This file (1) splits an answer into markdown and block segments, (2) validates each block against a strict schema, (3) fills charts, stat
// tiles, tables and timelines from the box's precomputed datasets (server/datasets.mjs), and (4) renders them.
//
// Two invariants hold everything together:
//  - REAL NUMBERS ONLY. Chart/stats/table/timeline blocks cannot carry numbers of their own: the schemas reject any key outside the allowed
//    list, so a model that writes {"type":"chart","values":[3,9]} gets an error chip, never a chart. Every plotted number comes from a dataset.
//  - NEVER SILENT. A block that does not parse, fails the schema, names a missing dataset or has the wrong dataset shape renders as a visible
//    error chip with the reason and the raw JSON. A still-open fence while streaming renders as a skeleton, nothing else is hidden.
var CycleBlocks = (function () {
  'use strict';
  var STATUSES = ['untried', 'trying', 'works', 'doesnt', 'mixed'];
  var STATUS_LABEL = { untried: 'Untried', trying: 'Trying', works: 'Works', doesnt: 'Doesn’t work', mixed: 'Mixed' };
  // A card button -> the verdict POSTed to /insights/techniques/:id/trial (insights-tech.mjs) and the status it shows right away.
  var VERDICT_STATUS = { try: 'trying', works: 'works', doesnt: 'doesnt' };

  function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function isStr(v, max) { return typeof v === 'string' && v.length > 0 && v.length <= (max || 200); }
  function isObj(v) { return v && typeof v === 'object' && !Array.isArray(v); }
  function only(o, keys) { var bad = Object.keys(o).filter(function (k) { return keys.indexOf(k) < 0; }); return bad.length ? 'unknown key "' + bad[0] + '"' : null; }
  function strList(a, min, max, len) { return Array.isArray(a) && a.length >= min && a.length <= max && a.every(function (x) { return isStr(x, len || 160); }); }
  function limitOk(v) { return v == null || (Number.isInteger(v) && v >= 1 && v <= 30); }

  // ---- 1. split an answer into segments --------------------------------------------------------------------------------------------
  // -> [{k:'md', text}, {k:'block', raw, bi}, {k:'pending'}]. `bi` counts blocks in the message and is the stable id of a block for its
  // saved state (ticks), so it must not depend on whether earlier blocks are valid. An unclosed fence is 'pending' only while streaming;
  // in a finished message it is a block with the raw text so the error chip shows it.
  function split(text, streaming) {
    var lines = String(text).split('\n'), segs = [], buf = [], bi = 0, i = 0;
    function flush() { var t = buf.join('\n'); buf = []; if (t.trim()) segs.push({ k: 'md', text: t }); }
    while (i < lines.length) {
      var t = lines[i].trim(), one = t.match(/^```ui\s*(\{.*\})\s*```$/);
      if (one) { flush(); segs.push({ k: 'block', raw: one[1], bi: bi++ }); i++; continue; }
      if (/^```ui\s*$/.test(t)) {
        var j = i + 1; while (j < lines.length && lines[j].trim() !== '```') j++;
        flush();
        if (j >= lines.length) { if (streaming) segs.push({ k: 'pending' }); else segs.push({ k: 'block', raw: lines.slice(i + 1).join('\n'), bi: bi++, unclosed: true }); break; }
        segs.push({ k: 'block', raw: lines.slice(i + 1, j).join('\n'), bi: bi++ });
        i = j + 1; continue;
      }
      buf.push(lines[i]); i++;
    }
    flush();
    return segs;
  }

  // ---- 2. strict schemas -----------------------------------------------------------------------------------------------------------
  // validate(raw) -> {ok:true, block} | {ok:false, error}. JSON.parse of model output is a true boundary, so its failure is reported, not hidden.
  function validate(raw) {
    var b;
    try { b = JSON.parse(raw); } catch (e) { return { ok: false, error: 'not valid JSON (' + e.message + ')' }; }
    if (!isObj(b)) return { ok: false, error: 'block must be a JSON object' };
    var err = check(b);
    return err ? { ok: false, error: err } : { ok: true, block: b };
  }
  function check(b) {
    var e, t = b.type;
    if (t === 'chart') {
      return only(b, ['type', 'dataset', 'kind', 'title']) || (!isStr(b.dataset, 60) && 'chart needs a dataset id') || (b.kind != null && ['bar', 'line', 'heatmap'].indexOf(b.kind) < 0 && 'kind must be bar, line or heatmap') || (b.title != null && !isStr(b.title, 80) && 'bad title') || null;
    }
    if (t === 'stats') {
      if ((e = only(b, ['type', 'tiles']))) return e;
      if (!Array.isArray(b.tiles) || b.tiles.length < 1 || b.tiles.length > 6) return 'stats needs 1 to 6 tiles';
      for (var i = 0; i < b.tiles.length; i++) { var x = b.tiles[i]; if (!isObj(x) || only(x, ['dataset', 'key', 'label']) || !isStr(x.dataset, 60) || !isStr(x.key, 60) || (x.label != null && !isStr(x.label, 40))) return 'tile ' + (i + 1) + ' must be {dataset, key, label?}'; }
      return null;
    }
    if (t === 'checklist') return only(b, ['type', 'title', 'items']) || (b.title != null && !isStr(b.title, 80) && 'bad title') || (!strList(b.items, 1, 20) && 'checklist needs 1 to 20 text items') || null;
    if (t === 'table') {
      if (b.dataset != null) return only(b, ['type', 'dataset', 'limit']) || (!isStr(b.dataset, 60) && 'bad dataset id') || (!limitOk(b.limit) && 'limit must be 1 to 30') || null;
      if ((e = only(b, ['type', 'columns', 'rows']))) return e;
      if (!strList(b.columns, 1, 8, 40) || !Array.isArray(b.rows) || b.rows.length < 1 || b.rows.length > 30) return 'table needs a dataset, or columns and 1 to 30 rows';
      return b.rows.every(function (r) { return strList(r, b.columns.length, b.columns.length, 200); }) ? null : 'every row must be text cells, one per column';
    }
    if (t === 'timeline') {
      if (b.dataset != null) return only(b, ['type', 'dataset', 'limit']) || (!isStr(b.dataset, 60) && 'bad dataset id') || (!limitOk(b.limit) && 'limit must be 1 to 30') || null;
      if ((e = only(b, ['type', 'events']))) return e;
      if (!Array.isArray(b.events) || b.events.length < 1 || b.events.length > 30) return 'timeline needs a dataset, or 1 to 30 events';
      return b.events.every(function (v) { return isObj(v) && !only(v, ['date', 'title', 'detail']) && isStr(v.date, 30) && isStr(v.title, 80) && (v.detail == null || isStr(v.detail, 200)); }) ? null : 'each event must be {date, title, detail?} of text';
    }
    if (t === 'technique') return only(b, ['type', 'id', 'name', 'how', 'status']) || (!(isStr(b.id, 80) && isStr(b.name, 100) && isStr(b.how, 300)) && 'technique needs id, name and how') || (b.status != null && STATUSES.indexOf(b.status) < 0 && 'status must be ' + STATUSES.join(', ')) || null;
    if (t === 'comparison') return only(b, ['type', 'title', 'worked', 'didnt']) || (b.title != null && !isStr(b.title, 80) && 'bad title') || (!(strList(b.worked, 0, 8) && strList(b.didnt, 0, 8) && b.worked.length + b.didnt.length > 0) && 'comparison needs worked and didnt text lists') || null;
    return t == null ? 'block has no type' : 'unknown block type "' + String(t).slice(0, 40) + '"';
  }

  // ---- 3. fill from datasets -------------------------------------------------------------------------------------------------------
  // Dataset shapes (datasets.mjs): series {points:[{x,label,y}]}, days {days:[{day,y}]}, values {values:{key:{label,y,unit}}},
  // rows {columns,rows}, events {events:[{date,title,detail}]}. Each returns {error} for a missing dataset or a shape the block cannot use.
  function need(ds, id, shapes) {
    var d = ds && ds[id];
    if (!d) return { error: 'dataset "' + id + '" is not available' };
    if (shapes.indexOf(d.shape) < 0) return { error: 'dataset "' + id + '" is ' + d.shape + ', not ' + shapes.join(' or ') };
    return { d: d };
  }
  // -> {error} or a render model. Pure: the numbers in the result are read straight off the dataset.
  function fill(b, ds) {
    var r;
    if (b.type === 'chart') {
      r = need(ds, b.dataset, ['series', 'days']); if (r.error) return r;
      var kind = b.kind || (r.d.shape === 'days' ? 'heatmap' : 'bar');
      if (r.d.shape === 'days' !== (kind === 'heatmap')) return { error: 'kind "' + kind + '" does not fit dataset "' + b.dataset + '" (' + r.d.shape + ')' };
      return { kind: kind, title: b.title || r.d.title, unit: r.d.unit, points: r.d.points, days: r.d.days };
    }
    if (b.type === 'stats') {
      var tiles = [];
      for (var i = 0; i < b.tiles.length; i++) {
        var t = b.tiles[i]; r = need(ds, t.dataset, ['values']); if (r.error) return r;
        var v = r.d.values[t.key]; if (!v) return { error: 'dataset "' + t.dataset + '" has no key "' + t.key + '"' };
        tiles.push({ label: t.label || v.label, y: v.y, unit: v.unit });
      }
      return { tiles: tiles };
    }
    if (b.type === 'table') {
      if (!b.dataset) return { columns: b.columns, rows: b.rows };
      r = need(ds, b.dataset, ['rows', 'series']); if (r.error) return r;
      if (r.d.shape === 'series') return { columns: ['', r.d.unit || 'Value'], rows: r.d.points.slice(0, b.limit || 30).map(function (p) { return [p.label, String(p.y)]; }) };
      return { columns: r.d.columns, rows: r.d.rows.slice(0, b.limit || 30) };
    }
    if (b.type === 'timeline') {
      if (!b.dataset) return { events: b.events };
      r = need(ds, b.dataset, ['events']); if (r.error) return r;
      return { events: r.d.events.slice(-(b.limit || 30)) };
    }
    return {};
  }

  // ---- 4. render ---------------------------------------------------------------------------------------------------------------------
  // ctx: { md(text)->html, ds: datasets map | null while loading, dsError: text | null, today, mi (message index), ver (shown version),
  //        state: the message's bstate, sel: {key: picked index}, tab: {key: true when the table view is on}, err: {key: text}, streaming }
  function chip(msg, raw) { return '<div class="bk bkerr" role="alert"><b>Block error</b><span>' + esc(msg) + '</span><pre>' + esc(raw) + '</pre></div>'; }
  function skeleton() { return '<div class="bk bksk" aria-label="Loading"></div>'; }
  function head(title, extra) { return '<div class="bkh"><span>' + esc(title) + '</span>' + (extra || '') + '</div>'; }

  // Bar / line chart. One pink hue, thin marks, the max labelled directly, a tap readout (no hover on a phone), 44px-tall hit columns.
  function seriesSvg(m, key, sel, pt) {
    var W = 320, H = 150, L = 26, R = 18, T = 14, B = 22, pts = m.points, n = pts.length, mx = Math.max.apply(null, pts.map(function (p) { return p.y; })) || 1;
    var cw = (W - L - R) / n, bw = Math.max(3, Math.min(22, cw * 0.62)), out = [];
    function X(i) { return L + cw * (i + 0.5); } function Y(v) { return T + (H - T - B) * (1 - v / mx); }
    out.push('<line x1="' + L + '" y1="' + Y(0) + '" x2="' + (W - R) + '" y2="' + Y(0) + '" class="bkax"/>');
    out.push('<text x="' + (L - 4) + '" y="' + (T + 4) + '" class="bkt" text-anchor="end">' + mx + '</text><text x="' + (L - 4) + '" y="' + (Y(0) + 4) + '" class="bkt" text-anchor="end">0</text>');
    if (m.kind === 'line') {
      out.push('<polyline class="bkln" fill="none" points="' + pts.map(function (p, i) { return X(i).toFixed(1) + ',' + Y(p.y).toFixed(1); }).join(' ') + '"/>');
      out.push('<circle class="bkdot" cx="' + X(sel).toFixed(1) + '" cy="' + Y(pts[sel].y).toFixed(1) + '" r="4.5"/>');
    } else {
      pts.forEach(function (p, i) { var h = Math.max(p.y ? 2 : 0, Y(0) - Y(p.y)); out.push('<rect class="bkbar' + (i === sel ? ' on' : '') + '" data-v="' + p.y + '" x="' + (X(i) - bw / 2).toFixed(1) + '" y="' + (Y(0) - h).toFixed(1) + '" width="' + bw.toFixed(1) + '" height="' + h.toFixed(1) + '" rx="2"/>'); });
    }
    // x labels: first, last and a few between, never all (they collide); the picked one is read in the readout line.
    var step = Math.ceil(n / 5);
    pts.forEach(function (p, i) { if ((n - 1 - i) % step === 0) out.push('<text x="' + X(i).toFixed(1) + '" y="' + (H - 6) + '" class="bkt" text-anchor="middle">' + esc(p.label) + '</text>'); });
    // tap columns, full height
    pts.forEach(function (p, i) { out.push('<rect class="bkhit" data-a="bkpick:' + key + ':' + i + '" x="' + (X(i) - cw / 2).toFixed(1) + '" y="0" width="' + cw.toFixed(1) + '" height="' + H + '"/>'); });
    return '<svg viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="' + esc(pt) + '">' + out.join('') + '</svg>';
  }
  // Calendar heatmap: weeks as columns, Monday at the top, ending with the week of `today`. Intensity is the day's own count, four steps.
  function heatSvg(m, key, sel, today) {
    var WEEKS = 22, c = 13, g = 1.5, pitch = c + g, L = 24, byDay = {}, days = [], i;
    m.days.forEach(function (d) { byDay[d.day] = d.y; });
    var end = Date.parse(today + 'T00:00:00Z'), wd = (new Date(end).getUTCDay() + 6) % 7, start = end - ((WEEKS - 1) * 7 + wd) * 86400000;
    for (i = 0; i < WEEKS * 7; i++) { var ms = start + i * 86400000; if (ms > end) break; days.push(new Date(ms).toISOString().slice(0, 10)); }
    var mx = Math.max.apply(null, [1].concat(m.days.map(function (d) { return d.y; }))), out = [];
    ['M', 'W', 'F'].forEach(function (l, k) { out.push('<text x="0" y="' + (10 + k * 2 * pitch + 3) + '" class="bkt">' + l + '</text>'); });
    days.forEach(function (d, k) {
      var col = Math.floor(k / 7), row = k % 7, v = byDay[d] || 0, lv = v ? Math.min(4, Math.ceil(v / mx * 4)) : 0;
      out.push('<rect class="bkc l' + lv + (k === sel ? ' on' : '') + '" data-v="' + v + '" data-day="' + d + '" x="' + (L + col * pitch) + '" y="' + (row * pitch + 2) + '" width="' + c + '" height="' + c + '" rx="2.5" data-a="bkpick:' + key + ':' + k + '"/>');
    });
    return { svg: '<svg viewBox="0 0 ' + (L + WEEKS * pitch) + ' ' + (7 * pitch + 4) + '" role="img" aria-label="Fights per day, last ' + WEEKS + ' weeks">' + out.join('') + '</svg>', days: days, byDay: byDay };
  }
  function plural(y, unit) { return y + ' ' + (y === 1 && unit ? unit.replace(/s$/, '') : unit || ''); }

  function chartHtml(m, key, ctx) {
    var tab = ctx.tab && ctx.tab[key], p, readout, svg, rows;
    if (m.kind === 'heatmap') {
      var hm = heatSvg(m, key, 0, ctx.today), sel = ctx.sel && ctx.sel[key] != null ? ctx.sel[key] : hm.days.length - 1;
      sel = Math.min(sel, hm.days.length - 1); var d = hm.days[sel];
      svg = heatSvg(m, key, sel, ctx.today).svg; readout = d + ': ' + plural(hm.byDay[d] || 0, m.unit);
      rows = m.days.map(function (x) { return [x.day, String(x.y)]; });
    } else {
      var s = ctx.sel && ctx.sel[key] != null ? Math.min(ctx.sel[key], m.points.length - 1) : m.points.length - 1; p = m.points[s];
      readout = p.label + ': ' + plural(p.y, m.unit); svg = seriesSvg(m, key, s, readout);
      rows = m.points.map(function (x) { return [x.label, String(x.y)]; });
    }
    var toggle = '<span class="txtbtn" data-a="bktab:' + key + '" role="button">' + (tab ? 'Chart' : 'Table') + '</span>';
    return '<div class="bk bkchart">' + head(m.title, toggle) + (tab ? tableInner(['', m.unit || 'Value'], rows) : svg + '<div class="bkro">' + esc(readout) + '</div>') + '</div>';
  }
  function tableInner(cols, rows) {
    return '<div class="bkscroll"><table><thead><tr>' + cols.map(function (c) { return '<th>' + esc(c) + '</th>'; }).join('') + '</tr></thead><tbody>' +
      rows.map(function (r) { return '<tr>' + r.map(function (c) { return '<td>' + esc(c) + '</td>'; }).join('') + '</tr>'; }).join('') + '</tbody></table></div>';
  }
  function statsHtml(m) { return '<div class="bk bkstats">' + m.tiles.map(function (t) { return '<div class="bkst"><b data-v="' + t.y + '">' + t.y + '</b><span>' + esc(t.label) + '</span></div>'; }).join('') + '</div>'; }
  function timelineHtml(m) { return '<div class="bk bktl">' + m.events.map(function (e) { return '<div class="bke"><i></i><div><b>' + esc(e.date) + '</b> ' + esc(e.title) + (e.detail ? '<small>' + esc(e.detail) + '</small>' : '') + '</div></div>'; }).join('') + '</div>'; }
  function checklistHtml(b, bi, ctx) {
    return '<div class="bk bkcl">' + (b.title ? head(b.title) : '') + b.items.map(function (it, i) {
      var on = !!(ctx.state && ctx.state[ctx.ver + ':' + bi + ':i' + i]);
      return '<div class="bkck' + (on ? ' on' : '') + '" role="checkbox" aria-checked="' + on + '" data-a="bkchk:' + ctx.mi + ':' + bi + ':' + i + '"><i>' + (on ? '<svg viewBox="0 0 16 16" width="14" height="14"><polyline points="3,8.5 6.5,12 13,4.5" fill="none" stroke="#0a0a0a" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/></svg>' : '') + '</i><span>' + esc(it) + '</span></div>';
    }).join('') + '</div>';
  }
  function techniqueHtml(b, bi, ctx) {
    var st = (ctx.state && ctx.state[ctx.ver + ':' + bi + ':status']) || b.status || 'untried', key = ctx.mi + ':' + bi, er = ctx.err && ctx.err[key];
    function btn(v, label) { return '<span class="bkbtn' + (VERDICT_STATUS[v] === st ? ' on' : '') + '" role="button" data-a="bktech:' + key + ':' + v + '">' + label + '</span>'; }
    return '<div class="bk bktc" data-id="' + esc(b.id) + '">' + head(b.name, '<span class="bkpill s-' + esc(st) + '">' + esc(STATUS_LABEL[st]) + '</span>') + '<p>' + esc(b.how) + '</p>' +
      '<div class="bkbtns">' + btn('try', 'Try') + btn('works', 'Worked') + btn('doesnt', 'Didn’t') + '</div>' + (er ? '<div class="bkfail" role="alert">' + esc(er) + '</div>' : '') + '</div>';
  }
  function comparisonHtml(b) {
    function col(h, items, cls) { return '<div class="bkcol ' + cls + '"><h5>' + h + '</h5>' + (items.length ? items.map(function (x) { return '<div>' + esc(x) + '</div>'; }).join('') : '<div class="none">None</div>') + '</div>'; }
    return '<div class="bk bkcmp">' + (b.title ? head(b.title) : '') + '<div class="bkcols">' + col('Worked', b.worked, 'w') + col('Didn’t', b.didnt, 'd') + '</div></div>';
  }

  // One block segment -> html (a chip on any failure).
  function blockHtml(seg, ctx) {
    var v = validate(seg.raw);
    if (!v.ok) return chip(v.error + (seg.unclosed ? ' (fence never closed)' : ''), seg.raw);
    var b = v.block, key = ctx.mi + ':' + seg.bi;
    if (b.type === 'checklist') return checklistHtml(b, seg.bi, ctx);
    if (b.type === 'technique') return techniqueHtml(b, seg.bi, ctx);
    if (b.type === 'comparison') return comparisonHtml(b);
    var usesDs = b.type === 'chart' || b.type === 'stats' || b.dataset;
    if (usesDs && !ctx.ds) return ctx.dsError ? chip('datasets unavailable: ' + ctx.dsError, seg.raw) : skeleton();
    var m = fill(b, ctx.ds); if (m.error) return chip(m.error, seg.raw);
    if (b.type === 'chart') return chartHtml(m, key, ctx);
    if (b.type === 'stats') return statsHtml(m);
    if (b.type === 'table') return '<div class="bk bktbl">' + tableInner(m.columns, m.rows) + '</div>';
    return timelineHtml(m);
  }
  // A whole answer -> html. Markdown pieces go through ctx.md; blocks are siblings of the paragraphs.
  function html(text, ctx) {
    return split(text, ctx.streaming).map(function (s) { return s.k === 'md' ? ctx.md(s.text) : s.k === 'pending' ? skeleton() : blockHtml(s, ctx); }).join('');
  }
  function hasBlocks(text) { return /(^|\n)\s*```ui\b/.test(text); }
  // Does any block of this text need the datasets? (so the screen only fetches them when one is on screen)
  function needsDatasets(text) {
    return split(text, false).some(function (s) { if (s.k !== 'block') return false; var v = validate(s.raw); return v.ok && (v.block.type === 'chart' || v.block.type === 'stats' || !!v.block.dataset); });
  }

  return { split: split, validate: validate, fill: fill, html: html, hasBlocks: hasBlocks, needsDatasets: needsDatasets, STATUSES: STATUSES, VERDICT_STATUS: VERDICT_STATUS };
})();
if (typeof module !== 'undefined' && module.exports) module.exports = CycleBlocks;

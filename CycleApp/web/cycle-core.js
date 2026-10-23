// Cycle core: pure logic, no DOM, no network. Loaded as a classic script (global
// CycleCore) in the app and via vm in the unit tests.
var CycleCore = (function () {
  'use strict';
  var MIN = 60000, DAY = 86400000;

  // ---- time -------------------------------------------------------------
  var fmts = {};
  function localDay(ms, tz) {
    var f = fmts[tz] || (fmts[tz] = new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }));
    return f.format(new Date(ms));
  }
  function utc(day) { var p = day.split('-'); return Date.UTC(+p[0], +p[1] - 1, +p[2]); }
  function addDays(day, n) { return new Date(utc(day) + n * DAY).toISOString().slice(0, 10); }
  function dayDiff(a, b) { return Math.round((utc(b) - utc(a)) / DAY); }
  function dow(day) { return (new Date(utc(day)).getUTCDay() + 6) % 7; } // Mon = 0
  function weekStart(day) { return addDays(day, -dow(day)); }

  // ---- holds ------------------------------------------------------------
  var HOLD_FIELD = { focus: 'hold_focus_min', kudos: 'hold_kudos_min', truth: 'hold_truth_min', ask: 'hold_ask_min' };
  function holdMinutes(couple, kind) {
    var f = HOLD_FIELD[kind];
    if (!f) throw new Error('unknown item kind ' + kind);
    return couple[f];
  }
  function heldUntil(now, minutes) { return now + minutes * MIN; }
  function durText(minutes) {
    var h = Math.floor(minutes / 60), m = minutes % 60;
    return (h ? h + 'h' : '') + (h && m ? ' ' : '') + (m ? m + 'm' : '');
  }
  // "11h 42m", "52m", "Ready" once due. Minutes round up so it never reads 0m while held.
  function countdown(until, now) {
    var left = until - now;
    if (left <= 0) return 'Ready';
    var mins = Math.ceil(left / MIN);
    var h = Math.floor(mins / 60), m = mins % 60;
    if (!h) return m + 'm';
    return h + 'h ' + String(m).padStart(2, '0') + 'm';
  }
  // Label the recipient sees: how long the sender held it. null when it was not held.
  function heldLabel(item) {
    if (!item.held_until) return null;
    var mins = Math.round((ms(item.held_until) - ms(item.created_at)) / MIN);
    return mins > 0 ? 'Held ' + durText(mins) : null;
  }
  // Timestamps from Postgres are ISO strings; held_until is normalised to ms by the store.
  function ms(v) { return typeof v === 'number' ? v : Date.parse(v); }

  function buildItem(o) {
    var held = holdMinutes(o.couple, o.kind);
    var item = {
      id: o.id, couple_id: o.couple.id, sender_id: o.me, recipient_id: o.to, kind: o.kind, body: o.body,
      ask_type: o.kind === 'ask' ? (o.ask_type || 'task') : null,
      due_date: o.kind === 'ask' ? (o.due_date || null) : null,
      target: o.kind === 'ask' && o.ask_type === 'habit' ? (o.target || 10) : null,
      origin: o.origin || null, response_type: o.response_type || null,
      held_until: held > 0 ? new Date(heldUntil(o.now, held)).toISOString() : null,
      status: held > 0 ? 'held' : 'delivered',
      delivered_at: held > 0 ? null : new Date(o.now).toISOString(),
      opened_at: null, kept: null,
      created_at: new Date(o.now).toISOString(), updated_at: new Date(o.now).toISOString(), deleted_at: null
    };
    return item;
  }

  function askToTodo(item, id, now) {
    if (item.kind !== 'ask') throw new Error('askToTodo needs an ask item');
    return {
      id: id, couple_id: item.couple_id, owner_id: item.recipient_id, created_by: item.sender_id, item_id: item.id,
      fight_marker_id: null, title: item.body, type: item.ask_type, due_date: item.due_date, target: item.target,
      tally: 0, done_at: null, created_at: new Date(now).toISOString(), updated_at: new Date(now).toISOString(), deleted_at: null
    };
  }

  // ---- points ledger ----------------------------------------------------
  // rows: {members, items, todos, todo_events, checkins, fight_markers, redemptions}
  // opts: {tz, now, since (YYYY-MM-DD, first day calm days can accrue)}
  function computeLedger(rows, opts) {
    if (!opts || !opts.tz || opts.now == null || !opts.since) throw new Error('computeLedger needs tz, now, since');
    var tz = opts.tz, today = localDay(opts.now, tz);
    var nameOf = {};
    rows.members.forEach(function (m) { nameOf[m.user_id] = m.name; });
    var lines = []; // {day, pts, label, who}
    function add(day, pts, label, who) { lines.push({ day: day, pts: pts, label: label, who: who || null }); }
    var dayOf = function (v) { return localDay(ms(v), tz); };

    rows.checkins.forEach(function (c) { add(c.day, 2, 'Check-in', nameOf[c.user_id]); });

    // kudos: +1 each, max 3 per sender per local day
    var kudos = rows.items.filter(function (i) { return i.kind === 'kudos' && i.status === 'delivered' && !i.deleted_at; })
      .sort(function (a, b) { return ms(a.delivered_at || a.created_at) - ms(b.delivered_at || b.created_at); });
    var kcount = {};
    kudos.forEach(function (i) {
      var d = dayOf(i.delivered_at || i.created_at), k = i.sender_id + '|' + d;
      kcount[k] = (kcount[k] || 0) + 1;
      if (kcount[k] <= 3) add(d, 1, 'Kudos', nameOf[i.recipient_id]);
    });

    // focus: opened the day it was delivered +1, else unopened by local midnight -1 (day elapsed)
    rows.items.forEach(function (i) {
      if (i.kind !== 'focus' || i.status !== 'delivered' || i.deleted_at) return;
      var d = dayOf(i.delivered_at);
      if (i.opened_at && dayOf(i.opened_at) === d) add(d, 1, 'Focus opened');
      else if (d < today) add(d, -1, 'Focus unopened');
    });

    var todoById = {};
    rows.todos.forEach(function (t) { todoById[t.id] = t; });
    var markerById = {};
    rows.fight_markers.forEach(function (m) { markerById[m.id] = m; });

    rows.todos.forEach(function (t) {
      if (t.deleted_at) return;
      var doneDay = t.done_at ? dayOf(t.done_at) : null;
      if (t.type === 'response') {
        var mk = t.fight_marker_id && markerById[t.fight_marker_id];
        if (t.done_at && mk && ms(t.done_at) - ms(mk.at) <= 48 * 60 * MIN) add(doneDay, 5, 'Repair within 48h');
        return;
      }
      if (doneDay && (!t.due_date || doneDay <= t.due_date)) add(doneDay, 3, 'To do on time', t.title);
      if (t.due_date && t.due_date < today && (!doneDay || doneDay > t.due_date)) add(addDays(t.due_date, 1), -3, 'To do overdue', t.title);
    });

    rows.todo_events.forEach(function (e) {
      var t = todoById[e.todo_id];
      if (e.kind === 'tally' && t && !t.deleted_at) add(dayOf(e.at), 1, 'Habit tally', t.title);
    });

    var fightDays = {};
    rows.fight_markers.forEach(function (m) {
      var d = dayOf(m.at); fightDays[d] = true;
      add(d, 1, 'Fight logged');
      add(d, -5, 'Fight');
    });

    for (var d = opts.since; d < today; d = addDays(d, 1)) if (!fightDays[d]) add(d, 3, 'Calm day');

    // 7 of 7 check-ins by both people in a week
    var ci = {};
    rows.checkins.forEach(function (c) { (ci[weekStart(c.day)] = ci[weekStart(c.day)] || {})[c.user_id + '|' + c.day] = true; });
    Object.keys(ci).forEach(function (ws) {
      var ok = rows.members.length >= 2 && rows.members.every(function (m) {
        for (var i = 0; i < 7; i++) if (!ci[ws][m.user_id + '|' + addDays(ws, i)]) return false;
        return true;
      });
      if (ok) add(addDays(ws, 6), 10, '7 of 7 check-ins');
    });

    var weeks = {};
    function wk(day) {
      var s = weekStart(day);
      return weeks[s] || (weeks[s] = { start: s, earned: 0, lost: 0, net: 0, days: {} });
    }
    lines.forEach(function (l) {
      var w = wk(l.day), dd = w.days[l.day] || (w.days[l.day] = { day: l.day, net: 0, lines: [] });
      dd.lines.push(l); dd.net += l.pts; w.net += l.pts;
      if (l.pts > 0) w.earned += l.pts; else w.lost += l.pts;
    });
    var spent = 0, spends = [];
    rows.redemptions.forEach(function (r) {
      if (r.status !== 'approved') return;
      spent += r.price;
      spends.push({ day: dayOf(r.decided_at), pts: -r.price, id: r.id, reward_id: r.reward_id });
    });
    var total = 0;
    Object.keys(weeks).forEach(function (k) { total += weeks[k].net; });
    var cur = weeks[weekStart(today)] || { start: weekStart(today), earned: 0, lost: 0, net: 0, days: {} };
    return { balance: total - spent, spent: spent, spends: spends, weeks: weeks, current: cur, today: today };
  }

  // Week close card groups: label -> summed points, earned and lost separately.
  function groupWeek(week) {
    var earned = {}, lost = {};
    Object.keys(week.days).forEach(function (d) {
      week.days[d].lines.forEach(function (l) {
        var label = l.label === 'Check-in' ? 'Check-ins' : l.label;
        var tgt = l.pts > 0 ? earned : lost;
        tgt[label] = (tgt[label] || 0) + l.pts;
      });
    });
    function arr(o) { return Object.keys(o).map(function (k) { return { label: k, pts: o[k] }; }).sort(function (a, b) { return Math.abs(b.pts) - Math.abs(a.pts); }); }
    return { earned: arr(earned), lost: arr(lost) };
  }

  // ---- cycle phase (private fight log) -----------------------------------
  // fights: [{at (ms), intensity}]. Fight = day of fight, Cool = 1-2 days after,
  // Warm = day 3 until 60% of the average cycle length, Tension after that.
  function phase(fights, now, tz, defaultLen) {
    if (!fights.length) return null;
    var days = fights.map(function (f) { return localDay(f.at, tz); }).sort();
    var uniq = days.filter(function (d, i) { return i === 0 || d !== days[i - 1]; });
    var gaps = [];
    for (var i = 1; i < uniq.length; i++) gaps.push(dayDiff(uniq[i - 1], uniq[i]));
    var avg = gaps.length ? gaps.reduce(function (a, b) { return a + b; }, 0) / gaps.length : null;
    var len = avg == null ? (defaultLen || 14) : avg;
    var since = dayDiff(uniq[uniq.length - 1], localDay(now, tz));
    var warmEnd = Math.max(3, len * 0.6);
    var name = since === 0 ? 'Fight' : since <= 2 ? 'Cool' : since < warmEnd ? 'Warm' : 'Tension';
    return { name: name, day: since + 1, avg: avg, len: len, warmEnd: warmEnd, last: uniq[uniq.length - 1] };
  }

  // ---- needs you ---------------------------------------------------------
  // s: {me, now, tz, items, checkins, redemptions, members}
  function needsYou(s) {
    var out = [], today = localDay(s.now, s.tz);
    var ready = s.items.filter(function (i) {
      return i.sender_id === s.me && i.status === 'held' && !i.deleted_at && ms(i.held_until) <= s.now;
    }).sort(function (a, b) { return ms(a.held_until) - ms(b.held_until); });
    if (ready.length) out.push({ type: 'ready', count: ready.length, item: ready[0] });
    s.redemptions.filter(function (r) { return r.status === 'pending' && r.requested_by !== s.me; })
      .forEach(function (r) { out.push({ type: 'approve', redemption: r }); });
    if (!s.checkins.some(function (c) { return c.user_id === s.me && c.day === today; })) out.push({ type: 'checkin' });
    s.items.filter(function (i) {
      return i.recipient_id === s.me && i.status === 'delivered' && !i.opened_at && !i.deleted_at && (i.kind === 'focus' || i.kind === 'kudos');
    }).sort(function (a, b) { return ms(b.delivered_at) - ms(a.delivered_at); })
      .forEach(function (i) { out.push({ type: i.kind, item: i }); });
    return out;
  }

  // Month grid for the Cycle screen: leading blanks (Mon-first) and day strings.
  function monthGrid(year, month) { // month 1-12
    var first = year + '-' + String(month).padStart(2, '0') + '-01';
    var n = new Date(Date.UTC(year, month, 0)).getUTCDate();
    var days = [];
    for (var i = 0; i < n; i++) days.push(addDays(first, i));
    return { blanks: dow(first), days: days };
  }

  return {
    localDay: localDay, addDays: addDays, dayDiff: dayDiff, dow: dow, weekStart: weekStart,
    holdMinutes: holdMinutes, heldUntil: heldUntil, countdown: countdown, heldLabel: heldLabel, durText: durText, ms: ms,
    buildItem: buildItem, askToTodo: askToTodo,
    computeLedger: computeLedger, groupWeek: groupWeek, phase: phase, needsYou: needsYou, monthGrid: monthGrid,
    // Only a still-held item may offer Send / Edit / Drop; a stale notification can point at a delivered or dropped one.
    isStillHeld: function (i) { return !!i && i.status === 'held' && !i.deleted_at; }
  };
})();
if (typeof module !== 'undefined' && module.exports) module.exports = CycleCore;

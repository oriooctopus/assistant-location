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

  // Wall-clock HH:MM on a given YYYY-MM-DD in a tz -> epoch ms. Intl has no inverse, so start from the
  // UTC guess and correct by the difference the tz shows; two passes settle across a DST offset change.
  function zonedMs(day, h, mi, tz) {
    var want = Date.parse(day + 'T' + String(h).padStart(2, '0') + ':' + String(mi).padStart(2, '0') + ':00Z'), guess = want;
    for (var i = 0; i < 2; i++) {
      var f = new Intl.DateTimeFormat('en-CA', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).formatToParts(new Date(guess)), p = {};
      f.forEach(function (x) { p[x.type] = x.value; });
      guess += want - Date.parse(p.year + '-' + p.month + '-' + p.day + 'T' + p.hour + ':' + p.minute + ':00Z');
    }
    return guess;
  }
  function localHour(ms_, tz) {
    return +new Intl.DateTimeFormat('en-GB', { timeZone: tz, hourCycle: 'h23', hour: '2-digit' }).format(new Date(ms_));
  }

  // ---- nudges -----------------------------------------------------------------
  var NUDGE_CUTOFF_H = 20, NUDGE_MORNING_H = 8;
  // The 8 pm rule. A nudge sent at/after 20:00 on the sender's clock goes out at 08:00 the next day
  // (sender's calendar), read on the recipient's clock; earlier it is delivered at once.
  function deliverAt(now, senderTz, recipientTz) {
    if (localHour(now, senderTz) < NUDGE_CUTOFF_H) return now;
    return zonedMs(addDays(localDay(now, senderTz), 1), NUDGE_MORNING_H, 0, recipientTz);
  }
  // Raise issue: an issue the sender writes tonight reaches the partner no earlier than 08:00 the next calendar day
  // on the sender's clock, and only after the sender confirms it (the "Still send?" card). Pure so the DST days
  // (23 / 25 hour days) are testable; zonedMs resolves the wall time, not now + 24h.
  function issueHeldUntil(now, tz) {
    return zonedMs(addDays(localDay(now, tz), 1), NUDGE_MORNING_H, 0, tz);
  }
  // Library sections. Pinned and All keep the author's manual order (sort_order); Recent is the 4
  // most recently sent-or-added unpinned nudges. A nudge sits in exactly one section: All is what
  // Pinned and Recent leave behind.
  function sectionNudges(nudges, sends) {
    var lastSent = {};
    sends.forEach(function (s) { if (!s.deleted_at) lastSent[s.nudge_id] = Math.max(lastSent[s.nudge_id] || 0, ms(s.created_at)); });
    // A done nudge leaves Pinned / Recent / All and is listed (newest first) in Done instead.
    var live = nudges.filter(function (n) { return !n.deleted_at && !n.archived_at && !n.done_at; });
    var done = nudges.filter(function (n) { return !n.deleted_at && !n.archived_at && n.done_at; })
      .sort(function (a, b) { return ms(b.done_at) - ms(a.done_at) || (a.id < b.id ? -1 : 1); });
    var bySort = function (a, b) { return a.sort_order - b.sort_order || (a.id < b.id ? -1 : 1); };
    var pinned = live.filter(function (n) { return n.pinned; }).sort(bySort);
    var touch = function (n) { return Math.max(ms(n.created_at), lastSent[n.id] || 0); };
    var recent = live.filter(function (n) { return !n.pinned; })
      .sort(function (a, b) { return touch(b) - touch(a) || (a.id < b.id ? -1 : 1); }).slice(0, 4);
    var taken = {};
    recent.forEach(function (n) { taken[n.id] = true; });
    var all = live.filter(function (n) { return !n.pinned && !taken[n.id]; }).sort(bySort);
    return { pinned: pinned, recent: recent, all: all, done: done };
  }

  // ---- "Done, with points": payout schedule for a done nudge ------------------------------------------
  // Calendar-month step that clamps to the month's last day (31 Jan + 1 month = 28/29 Feb), never rolling into March.
  function addMonths(day, n) {
    var p = day.split('-'), y = +p[0], m = +p[1] - 1 + n, d = +p[2];
    y += Math.floor(m / 12); m = ((m % 12) + 12) % 12;
    var last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
    return y + '-' + ('0' + (m + 1)).slice(-2) + '-' + ('0' + Math.min(d, last)).slice(-2);
  }
  // [{day, points}] for an award done on doneDay (the sender's local day). 'now' pays everything that day;
  // '3mo' splits into three integer parts with the remainder on the earliest (20 -> 7,7,6; 10 -> 4,3,3), paid
  // on doneDay, +1 calendar month and +3. A part that rounds to 0 (1 or 2 points) is dropped.
  function splitPayout(points, payout, doneDay) {
    if (payout === 'now') return [{ day: doneDay, points: points }];
    if (payout !== '3mo') throw new Error('unknown payout ' + payout);
    var base = Math.floor(points / 3), rem = points % 3, days = [doneDay, addMonths(doneDay, 1), addMonths(doneDay, 3)];
    return days.map(function (d, i) { return { day: d, points: base + (i < rem ? 1 : 0) }; }).filter(function (x) { return x.points > 0; });
  }
  // Installments of one award that actually pay: due on or before `today`, and not cut off by Stop the rest
  // (an installment dated on or after the local day of stopped_at is never paid). Shared by the ledger and the
  // library row so the two cannot disagree.
  function awardInstallments(a, today, tz) {
    var doneDay = localDay(ms(a.done_at), tz), stopDay = a.stopped_at ? localDay(ms(a.stopped_at), tz) : null;
    return splitPayout(a.points, a.payout, doneDay).map(function (x) {
      var cut = stopDay !== null && x.day >= stopDay;
      return { day: x.day, points: x.points, cut: cut, paid: !cut && x.day <= today };
    });
  }
  // {paid, total, next, last, stopped, complete}: next = earliest unpaid, uncut installment day (null when none left);
  // last = day of the latest paid installment; stopped = Stop the rest actually cut something.
  function awardStatus(a, today, tz) {
    var ins = awardInstallments(a, today, tz), paid = 0, last = null, next = null, stopped = false;
    ins.forEach(function (x) {
      if (x.paid) { paid += x.points; last = x.day; }
      else if (x.cut) stopped = true;
      else if (next === null) next = x.day;
    });
    return { paid: paid, total: a.points, next: next, last: last, stopped: stopped, complete: !stopped && next === null };
  }

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
  // How a due date reads against today. fmt names a far-off day, since a bare weekday only identifies this coming week.
  function dueInfo(day, today, fmt) {
    var n = Math.round((Date.parse(day) - Date.parse(today)) / 864e5);
    if (n < 0) return { text: -n + (n === -1 ? ' day late' : ' days late'), state: 'late' };
    if (n === 0) return { text: 'Due today', state: 'soon' };
    if (n === 1) return { text: 'Due tomorrow', state: 'soon' };
    return { text: 'Due ' + fmt(day), state: '' };
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
  // appendSpeech(base, text): a transcript joined onto what was already typed, one space between, no stray ones.
  function appendSpeech(base, text) {
    var b = String(base || '').replace(/\s+$/, ''), t = String(text || '').trim();
    return b && t ? b + ' ' + t : b || t;
  }

  function ms(v) { return typeof v === 'number' ? v : Date.parse(v); }

  // ---- scheduled rows -----------------------------------------------------
  // A scheduled to do / ask is written at once but stamped with its future time T in its natural timestamp
  // (items: delivered_at, todos: created_at). Until T it is invisible to both partners: every reader of
  // those tables goes through this predicate.
  function isScheduled(row, now) { return ms(row.delivered_at || row.created_at) > now; }
  // A partner-bound schedule cannot beat the hold on that kind of item: T is at least now + hold.
  function scheduleAt(couple, kind, at, now) { return Math.max(at, heldUntil(now, holdMinutes(couple, kind))); }

  function buildItem(o) {
    // o.held_until (ms) is an absolute hold that replaces the couple's per-kind hold. Raise issue relies on it so the
    // Ask hold setting (even 0) can never shorten the next-morning delay. A scheduled item (o.at) is never an issue.
    if (o.held_until != null && o.at != null) throw new Error('held_until and at are exclusive');
    var held = o.held_until != null ? Math.max(1, Math.ceil((o.held_until - o.now) / MIN)) : o.at != null ? 0 : holdMinutes(o.couple, o.kind);
    // o.at (ms): scheduled, born delivered with delivered_at = o.at, no hold.
    var due = o.at != null ? o.at : o.now;
    var item = {
      id: o.id, couple_id: o.couple.id, sender_id: o.me, recipient_id: o.to, kind: o.kind, body: o.body,
      ask_type: o.kind === 'ask' ? (o.ask_type || 'task') : null,
      description: o.kind === 'ask' ? (o.description || null) : null,
      due_date: o.kind === 'ask' ? (o.due_date || null) : null,
      target: o.kind === 'ask' && o.ask_type === 'habit' ? o.target : null,
      period: o.kind === 'ask' && o.ask_type === 'habit' ? o.period : null,
      points_earn: o.kind === 'ask' && o.points_earn != null ? o.points_earn : null, points_miss: o.kind === 'ask' && o.points_miss != null ? o.points_miss : null, needs_note: o.kind === 'ask' && !!o.needs_note,
      origin: o.origin || null, response_type: o.response_type || null, fight_marker_id: o.fight_marker_id || null,
      held_until: o.held_until != null ? new Date(o.held_until).toISOString() : held > 0 ? new Date(heldUntil(o.now, held)).toISOString() : null,
      status: held > 0 ? 'held' : 'delivered',
      delivered_at: held > 0 ? null : new Date(due).toISOString(),
      opened_at: null, kept: null,
      created_at: new Date(o.now).toISOString(), updated_at: new Date(o.now).toISOString(), deleted_at: null
    };
    // Only kudos carry gift_points, so every other item still inserts without the column.
    if (o.kind === 'kudos' && o.gift_points != null) item.gift_points = o.gift_points;
    // A to-do for Both: set only when true, so every ordinary item still inserts without the column (a client that
    // ships before the migration keeps working) and old rows without it read as not shared.
    if (o.kind === 'ask' && o.shared) item.shared = true;
    return item;
  }

  // Is this to-do on my list? Mine when I own it, or when it is shared (ONE row for Both, so it is on both lists).
  // Rows without the field (old data / old clients) are not shared. Every owner_id === me site goes through this.
  function mineTodo(t, me) { return t.owner_id === me || !!t.shared; }

  function askToTodo(item, id, now) {
    if (item.kind !== 'ask') throw new Error('askToTodo needs an ask item');
    var todo = {
      id: id, couple_id: item.couple_id, owner_id: item.recipient_id, created_by: item.sender_id, item_id: item.id,
      // A fight ask becomes a 'response' todo on that marker, so finishing it repairs the fight (todoDone).
      fight_marker_id: item.fight_marker_id || null, title: item.body, description: item.description || null, type: item.origin === 'fight' ? 'response' : item.ask_type, due_date: item.due_date, target: item.target, period: item.period,
      points_earn: item.points_earn, points_miss: item.points_miss, needs_note: item.needs_note, edited_at: null,
      tally: 0, done_at: null, created_at: new Date(now).toISOString(), updated_at: new Date(now).toISOString(), deleted_at: null
    };
    if (item.shared) todo.shared = true; // same only-when-true rule as buildItem
    return todo;
  }

  // ---- points ledger ----------------------------------------------------
  // Log fight's "Did she hit herself?" answer, as the Fight line's detail. Both partners read the same
  // ledger, so the follow-up names whoever logged the fight rather than saying "me" / "you".
  function hitText(m, logger) {
    if (!m.hit_self) return null;
    return 'Hit herself' + (m.hit_related === true ? ', related to ' + logger : m.hit_related === false ? ', not related to ' + logger : '');
  }

  // ---- habit goals: N logs per day / week / month ---------------------------------------------------------------
  // Per-todo points; null = the rule default (task 3 earned / 3 lost, habit 1 / 0). An 'ownup' to do scores like a task;
  // a migrated one stores explicit 0 / 0, which `== null` keeps distinct from the default.
  var DEF_PTS = { task: [3, 3], habit: [1, 0], ownup: [3, 3] };
  function earnPts(t) { return t.points_earn == null ? DEF_PTS[t.type][0] : t.points_earn; }
  function missPts(t) { return t.points_miss == null ? DEF_PTS[t.type][1] : t.points_miss; }
  // {start, end} (inclusive local days) of the day / Mon-first week / calendar month containing `day`.
  function periodOf(period, day) {
    if (period === 'day') return { start: day, end: day };
    if (period === 'week') { var s = weekStart(day); return { start: s, end: addDays(s, 6) }; }
    if (period === 'month') { var m = day.slice(0, 7) + '-01'; return { start: m, end: addDays(addMonths(m, 1), -1) }; }
    throw new Error('unknown period ' + period);
  }
  // Habit logs inside p = {start, end} (local days in tz).
  function habitCount(t, events, p, tz) {
    return events.filter(function (e) {
      if (e.todo_id !== t.id || e.kind !== 'tally') return false;
      var d = localDay(ms(e.at), tz); return d >= p.start && d <= p.end;
    }).length;
  }
  // Closed periods under target. Counting starts at the first period that begins on or after the day the habit was
  // created (the partial period it was created in is skipped); the open period never counts. Same inputs, same answer
  // on both phones: only todo_events, created_at and the couple tz are read.
  function habitMisses(t, events, today, tz) {
    var out = [];
    if (t.type !== 'habit' || !t.target || !t.period) return out; // no goal (legacy row) = no misses
    var created = localDay(ms(t.created_at), tz), p = periodOf(t.period, created);
    if (p.start < created) p = periodOf(t.period, addDays(p.end, 1));
    for (; p.end < today; p = periodOf(t.period, addDays(p.end, 1))) if (habitCount(t, events, p, tz) < t.target) out.push(p);
    return out;
  }
  // A to do that needs a note refuses an empty one (the UI shows this message).
  function requireNote(t, note) { if (t.needs_note && !(note || '').trim()) throw new Error('Note needed'); }
  // Owner sees "Edited" on a to do their partner edited, until they next log it. An edit inside the author's edit window
  // still counts: the partner may already have read the old text, and rows edited before the window existed carry it too.
  function isEdited(t, events, me) {
    return mineTodo(t, me) && t.created_by !== me && !!t.edited_at && !events.some(function (e) { return e.todo_id === t.id && e.user_id === me && ms(e.at) > ms(t.edited_at); });
  }
  // From this local day (couple tz) a fight costs by shared intensity and a hit costs more; earlier days keep the old numbers.
  var RECAL_DAY = '2026-11-10';
  // From REBAL_DAY: a calm day pays CALM_PAY (3 before), every 7th fight-free day pays min(week * FREE_WEEK_STEP, FREE_WEEK_CAP),
  // and a streak challenge pays min(ceil(n / 7), 10) a day with no weekly bonus (the +100 every 30th day stays).
  var STREAK_CAP = 10, STREAK_WEEK_OLD = 10, STREAK_MONTH = 100, HIT_FIRST = 15, HIT_LATER = 10, REBAL_DAY = '2026-11-11', CALM_PAY = 2, FREE_WEEK_STEP = 20, FREE_WEEK_CAP = 80;
  var MONTH_MISS = 1.5; // repeating goal: each missed day costs this many days' share of goal_earn
  var FIGHT_COST = { 1: 5, 2: 10, 3: 20, 4: 35, 5: 40 };
  // The penalties a to-do ping carries: [{kind: 'open'|'done', pts, by (ms), state, at (ms of the open / done, else null)}].
  // state: 'avoided' (opened / done at or before the deadline), 'applied' (deadline passed without), 'pending',
  // 'void' (the to-do was deleted at or before the deadline). Declined / ignored to-dos still count.
  // opens: todo_nudge_opens rows (opened_at is the phone's clock).
  function pingPenalties(n, t, opens, nowMs) {
    if (n.deleted_at) return [];
    var out = [];
    function one(kind, by, pts, hitAt) {
      by = ms(by);
      var state = t.deleted_at && ms(t.deleted_at) <= by ? 'void' : hitAt != null && hitAt <= by ? 'avoided' : nowMs >= by ? 'applied' : 'pending';
      out.push({ kind: kind, pts: pts, by: by, state: state, at: state === 'avoided' ? hitAt : null });
    }
    if (n.open_by) {
      var o = opens.filter(function (x) { return x.nudge_id === n.id && !x.deleted_at; }).map(function (x) { return ms(x.opened_at); }).sort(function (a, b) { return a - b; })[0];
      one('open', n.open_by, n.open_pts, o == null ? null : o);
    }
    if (n.done_by) one('done', n.done_by, n.done_pts, t.done_at ? ms(t.done_at) : null);
    return out;
  }
  // rows: {members, items, todos, todo_events, fight_markers, fight_ratings: [{fight_marker_id, user_id, intensity}], redemptions, challenges: [{id, name, start, breaks_on}], challenge_breaks: [{challenge_id, day}], challenge_days: [{challenge_id, day}]}
  // A challenge's start is the first local day that can pay; no rows.challenges means no challenges.
  // opts: {tz, now, since (YYYY-MM-DD, first day calm days can accrue)}
  function computeLedger(rows, opts) {
    if (!opts || !opts.tz || opts.now == null || !opts.since) throw new Error('computeLedger needs tz, now, since');
    var tz = opts.tz, today = localDay(opts.now, tz);
    // An approved-deleted fight, an undone to-do event and an undone tapped break are soft-deleted rows: they leave
    // every line, streak and chart here, so both phones compute the same points once the delete has synced.
    rows = Object.assign({}, rows, { items: rows.items.filter(function (r) { return !isScheduled(r, opts.now); }), todos: rows.todos.filter(function (r) { return !isScheduled(r, opts.now); }),
      fight_markers: rows.fight_markers.filter(function (r) { return !r.deleted_at; }), todo_events: rows.todo_events.filter(function (r) { return !r.deleted_at; }),
      challenge_breaks: (rows.challenge_breaks || []).filter(function (r) { return !r.deleted_at; }) });
    var nameOf = {};
    rows.members.forEach(function (m) { nameOf[m.user_id] = m.name; });
    var lines = []; // {day, pts, label, who}
    function add(day, pts, label, who, fight) { if (!pts) return; lines.push({ day: day, pts: pts, label: label, who: who || null, fight: fight || null }); }
    var dayOf = function (v) { return localDay(ms(v), tz); };

    // kudos: gift_points scores exactly that, outside the daily cap. Legacy rows (gift_points null): +1 each unless points is false, max 3 per sender per local day.
    var kudos = rows.items.filter(function (i) { return i.kind === 'kudos' && i.status === 'delivered' && !i.deleted_at; })
      .sort(function (a, b) { return ms(a.delivered_at || a.created_at) - ms(b.delivered_at || b.created_at); });
    var kcount = {};
    kudos.forEach(function (i) {
      var d = dayOf(i.delivered_at || i.created_at), k = i.sender_id + '|' + d;
      if (i.gift_points != null) { add(d, i.gift_points, 'Kudos', nameOf[i.recipient_id]); return; }
      if (i.points === false) return;
      kcount[k] = (kcount[k] || 0) + 1;
      if (kcount[k] <= 3) add(d, 1, 'Kudos', nameOf[i.recipient_id]);
    });

    // Ping penalties: each applied one is a lose line dated at its deadline, from shared rows only.
    var todoById = {};
    rows.todos.forEach(function (t) { todoById[t.id] = t; });
    (rows.todo_nudges || []).forEach(function (n) {
      var t = todoById[n.todo_id];
      if (!t) return;
      pingPenalties(n, t, rows.todo_nudge_opens || [], opts.now).forEach(function (p) {
        if (p.state === 'applied') add(dayOf(p.by), -p.pts, t.title, p.kind === 'open' ? 'not opened' : 'not done');
      });
    });

    // nudges sent to the partner: opening one earns nothing (Oliver, 2026-11-10: opening is not an achievement).
    // While still unopened after its delivery day it costs -1, and that line goes away once it is opened, however
    // late. (Me nudges are private and never in rows.) Not-yet-delivered sends do not count yet.
    rows.nudge_sends.forEach(function (n) {
      if (n.deleted_at || n.opened_at || ms(n.deliver_at) > opts.now) return;
      var d = dayOf(n.deliver_at);
      if (d < today) add(d, -1, 'Reminder unopened');
    });

    // "Nudge done" installments from the author's awards to the recipient (see awardInstallments for the stop rule).
    rows.nudge_awards.forEach(function (a) {
      if (a.deleted_at) return;
      awardInstallments(a, today, tz).forEach(function (x) { if (x.paid) add(x.day, x.points, 'Reminder done', nameOf[a.recipient_id]); });
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
      if (t.type === 'habit') {
        habitMisses(t, rows.todo_events, today, tz).forEach(function (p) { add(addDays(p.end, 1), -missPts(t), 'Habit missed', t.title); });
        return;
      }
      if (doneDay && (!t.due_date || doneDay <= t.due_date)) add(doneDay, earnPts(t), 'To do on time', t.title);
      if (t.due_date && t.due_date < today && (!doneDay || doneDay > t.due_date)) add(addDays(t.due_date, 1), -missPts(t), 'To do overdue', t.title);
    });

    rows.todo_events.forEach(function (e) {
      var t = todoById[e.todo_id];
      if (e.kind === 'tally' && t && !t.deleted_at) add(dayOf(e.at), earnPts(t), 'Habit tally', t.title);
    });

    // Fight: -5 before RECAL_DAY. From RECAL_DAY it costs by shared intensity (1 -5, 2 -10, 3 -20, 4 -35, 5 -40): the mean of
    // the fight's ratings rounded up, unrated = 3. Never per viewer, so both phones show the same points.
    var ratingsByFight = {};
    (rows.fight_ratings || []).forEach(function (r) { (ratingsByFight[r.fight_marker_id] || (ratingsByFight[r.fight_marker_id] = [])).push(r.intensity); });
    function sharedIntensity(id) {
      var v = ratingsByFight[id];
      return v ? Math.ceil(v.reduce(function (a, b) { return a + b; }, 0) / v.length) : 3;
    }
    var fightDays = {};
    rows.fight_markers.forEach(function (m) {
      var d = dayOf(m.at); fightDays[d] = true;
      add(d, 1, 'Fight logged', null, m.id);
      add(d, d < RECAL_DAY ? -5 : -FIGHT_COST[sharedIntensity(m.id)], 'Fight', hitText(m, nameOf[m.logged_by]), m.id);
    });

    var free = 0;
    for (var d = opts.since; d < today; d = addDays(d, 1)) {
      if (fightDays[d]) { free = 0; continue; }
      free++;
      add(d, d < REBAL_DAY ? 3 : CALM_PAY, 'Calm day');
      if (d >= REBAL_DAY && free % 7 === 0) add(d, Math.min(free / 7 * FREE_WEEK_STEP, FREE_WEEK_CAP), 'Week without a fight');
    }

    // Hits: a fight logged with hit_self = yes counts hit_count hits (null = legacy row, one hit). The first hit of a
    // local day costs 10, each later one that day 5, whether in the same fight or a later one.
    // From RECAL_DAY: 15 first, 10 later (the first was 20 for a few hours on RECAL_DAY; Oliver lowered it the same day, so
    // there is no second date gate). hit_count 0.5 is one light hit at half that cost, rounded up (-5 first, -3 later;
    // from RECAL_DAY -8 and -5); it still breaks hit challenges.
    var hitsByDay = {};
    rows.fight_markers.filter(function (m) { return m.hit_self === true; }).sort(function (a, b) { return ms(a.at) - ms(b.at); }).forEach(function (m) {
      var d = dayOf(m.at);
      for (var i = 0; i < (m.hit_count || 1); i++) {
        hitsByDay[d] = (hitsByDay[d] || 0) + 1;
        var cost = d < RECAL_DAY ? (hitsByDay[d] === 1 ? 10 : 5) : (hitsByDay[d] === 1 ? HIT_FIRST : HIT_LATER);
        add(d, m.hit_count === 0.5 ? -Math.ceil(cost / 2) : -cost, 'Hit', m.hit_count === 0.5 ? 'Light' : null, m.id);
      }
    });

    // Streak challenges: each finished hit-free day pays its streak number capped at 10 (day 1 +1 ... day 10+ +10);
    // every 7th streak day adds +10 and every 30th +100. A hit day pays nothing and the next day is day 1 again.
    // `day` is today's streak number (0 on a hit day); `next` is the days until the next week / month bonus.
    // A challenge counts only once the person it is for accepts it: until then nothing pays and there are no days;
    // after, the streak begins on the local day of acceptance (day 1 unless that day has a hit).
    // A hit challenge breaks on a day with a logged hit; a tap challenge (breaks_on 'tap') breaks on a day with a
    // challenge_breaks row and carries no point penalty, the streak just resets.
    var tapBreaks = {};
    (rows.challenge_breaks || []).forEach(function (b) { (tapBreaks[b.challenge_id] || (tapBreaks[b.challenge_id] = {}))[b.day] = true; });
    // A goal challenge (breaks_on 'goal') is one-shot: log goal_days distinct days (note rows in challenge_days) within
    // goal_window_days of c.start, a fixed window (acceptance can come before it opens; a later one shortens it). Reaching the count pays goal_earn once, on that day; a window that ends short pays
    // -goal_miss on the day after the deadline. No streak pay, no bonuses; hits and fights do not touch it.
    var goalDays = {};
    (rows.challenge_days || []).forEach(function (b) { if (b.deleted_at) return; (goalDays[b.challenge_id] || (goalDays[b.challenge_id] = {}))[b.day] = true; });
    var challenges = (rows.challenges || []).map(function (c) {
      if (c.breaks_on === 'goal') return goalChallenge(c);
      var tap = c.breaks_on === 'tap', brokenOn = tap ? (tapBreaks[c.id] || {}) : hitsByDay;
      var n = 0, best = 0, earned = 0, days = [], accepted = !!c.accepted_at;
      if (!accepted) return { id: c.id, name: c.name, archived: !!c.archived_at, for_user: c.for_user, breaks_on: tap ? 'tap' : 'hit', broken_today: false, accepted: false, start: null, day: 0, best: 0, earned: 0, tonight: 0, days: [], next: { week: 7, month: 30 } };
      var start = dayOf(c.accepted_at) > c.start ? dayOf(c.accepted_at) : c.start;
      // An archived challenge stops accruing on its archive day (points already earned stay); unarchiving clears
      // archived_at, so the days in between then count again.
      var endDay = c.archived_at && dayOf(c.archived_at) < today ? dayOf(c.archived_at) : today;
      for (var d = start; d < endDay; d = addDays(d, 1)) {
        if (brokenOn[d]) { n = 0; days.push({ d: d, n: 0, bonus: false }); continue; }
        n++; best = Math.max(best, n);
        var old = d < REBAL_DAY;
        days.push({ d: d, n: n, bonus: (old && n % 7 === 0) || n % 30 === 0 });
        var pay = old ? Math.min(n, STREAK_CAP) : Math.min(Math.ceil(n / 7), STREAK_CAP); earned += pay;
        add(d, pay, c.name, 'Day ' + n);
        if (old && n % 7 === 0) { earned += STREAK_WEEK_OLD; add(d, STREAK_WEEK_OLD, tap ? c.name : 'Week without hitting', tap ? 'Week' : null); }
        if (n % 30 === 0) { earned += STREAK_MONTH; add(d, STREAK_MONTH, tap ? c.name : 'Month without hitting', tap ? 'Month' : null); }
      }
      // next = days from today until the day whose finish pays the bonus (0 = today's finish).
      var day = start > today || brokenOn[today] ? 0 : n + 1;
      // days: start..today, n = streak number that day (0 on a hit day); today's n is the day in progress.
      if (start <= today && endDay === today) days.push({ d: today, n: day, bonus: false });
      var tonight = !day ? 0 : today < REBAL_DAY ? Math.min(day, STREAK_CAP) + (day % 7 === 0 ? STREAK_WEEK_OLD : 0) + (day % 30 === 0 ? STREAK_MONTH : 0) : Math.min(Math.ceil(day / 7), STREAK_CAP) + (day % 30 === 0 ? STREAK_MONTH : 0);
      return { id: c.id, name: c.name, archived: !!c.archived_at, for_user: c.for_user, breaks_on: tap ? 'tap' : 'hit', broken_today: !!brokenOn[today], accepted: true, start: start, day: day, best: best, earned: earned, tonight: tonight, days: days,
        next: today < REBAL_DAY ? { week: Math.max(7, Math.ceil(day / 7) * 7) - day, month: Math.max(30, Math.ceil(day / 30) * 30) - day } : { month: Math.max(30, Math.ceil(day / 30) * 30) - day } };
    });

    function monthEnd(day) { var y = +day.slice(0, 4), m = +day.slice(5, 7); return addDays(m === 12 ? (y + 1) + '-01-01' : y + '-' + ('0' + (m + 1)).slice(-2) + '-01', -1); }
    // A repeating goal challenge (repeat 'month') runs per calendar month from the month of its start: reaching goal_days pays
    // goal_earn once, a finished month that ends short settles on the 1st with one prorated line (MONTH_MISS), goal_miss and
    // goal_window_days are ignored. Archiving ends it: no later months, no settlement for the month it was archived in.
    function repeatGoal(c, base) {
      if (!c.accepted_at) return base;
      var start = dayOf(c.accepted_at) > c.start ? dayOf(c.accepted_at) : c.start, ad = c.archived_at ? dayOf(c.archived_at) : null;
      var all = Object.keys(goalDays[c.id] || {}).sort(), months = [], first = start;
      while (first <= today && (!ad || first <= ad)) {
        var last = monthEnd(first), logged = all.filter(function (d) { return d >= first && d <= last; }), paid = 0, over = last < today && !(ad && ad <= last);
        logged.forEach(function (d, i) { if (i + 1 === c.goal_days) { paid = c.goal_earn; add(d, paid, c.name); } });
        if (over && logged.length < c.goal_days) { paid = Math.round(c.goal_earn * (1 - MONTH_MISS * (c.goal_days - logged.length) / c.goal_days)); add(addDays(last, 1), paid, c.name); }
        months.push({ month: first.slice(0, 7), deadline: last, logged: logged, count: logged.length, paid: paid,
          status: logged.length >= c.goal_days ? 'done' : !over ? 'active' : paid <= 0 ? 'failed' : 'partial' });
        first = addDays(last, 1);
      }
      var cur = months[months.length - 1];
      if (!cur) return Object.assign(base, { opens: start, deadline: monthEnd(start) });
      base.days = []; months.forEach(function (m) { m.logged.forEach(function (d, i) { base.days.push({ d: d, n: i + 1, bonus: false }); }); });
      return Object.assign(base, { start: start, deadline: cur.deadline, count: cur.count, logged_today: cur.logged.indexOf(today) >= 0, status: cur.status,
        earned: months.reduce(function (n, m) { return n + m.paid; }, 0),
        past: months.slice(0, -1).reverse().map(function (m) { return { month: m.month, count: m.count, goal: c.goal_days, paid: m.paid, status: m.status }; }) });
    }
    function goalChallenge(c) {
      var base = { id: c.id, name: c.name, archived: !!c.archived_at, for_user: c.for_user, breaks_on: 'goal', repeat: c.repeat || null, accepted: !!c.accepted_at, start: null, opens: c.start, deadline: c.repeat ? monthEnd(c.start) : addDays(c.start, c.goal_window_days - 1), count: 0, goal_days: c.goal_days, goal_earn: c.goal_earn, goal_miss: c.goal_miss, rule: c.rule,
        logged_today: false, status: 'active', broken_today: false, day: 0, best: 0, earned: 0, tonight: 0, days: [], past: [], next: { month: 30 } };
      if (c.repeat === 'month') return repeatGoal(c, base);
      if (!c.accepted_at) return base;
      var start = dayOf(c.accepted_at) > c.start ? dayOf(c.accepted_at) : c.start, deadline = base.deadline;
      var logged = Object.keys(goalDays[c.id] || {}).filter(function (d) { return d >= start && d <= deadline; }).sort();
      logged.forEach(function (d, i) {
        base.days.push({ d: d, n: i + 1, bonus: false });
        if (i + 1 === c.goal_days) { base.earned = c.goal_earn; add(d, c.goal_earn, c.name); }
      });
      var failed = today > deadline && logged.length < c.goal_days;
      if (failed) add(addDays(deadline, 1), -c.goal_miss, c.name);
      return Object.assign(base, { start: start, deadline: deadline, count: logged.length, logged_today: logged.indexOf(today) >= 0,
        status: logged.length >= c.goal_days ? 'done' : failed ? 'failed' : 'active' });
    }

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
    return { balance: total - spent, spent: spent, spends: spends, weeks: weeks, current: cur, today: today, challenges: challenges, freeStreak: free };
  }

  // Week close card groups: label -> summed points, earned and lost separately.
  function groupWeek(week) {
    var earned = {}, lost = {};
    Object.keys(week.days).forEach(function (d) {
      week.days[d].lines.forEach(function (l) {
        var tgt = l.pts > 0 ? earned : lost;
        tgt[l.label] = (tgt[l.label] || 0) + l.pts;
      });
    });
    function arr(o) { return Object.keys(o).map(function (k) { return { label: k, pts: o[k] }; }).sort(function (a, b) { return Math.abs(b.pts) - Math.abs(a.pts); }); }
    return { earned: arr(earned), lost: arr(lost) };
  }


  // ---- fight patterns (shared markers, both partners) ---------------------
  // days: local YYYY-MM-DD of every streak-breaking fight either partner logged (callers drop level-1 fights via
  // breaksStreak). Calm days are the days from `since` up to yesterday with none of them. computeLedger's Calm day +3
  // still needs a fight-free day, so a day with only a level-1 fight is calm here but pays no Calm day there.
  // streak = calm days in a row ending yesterday (today is not over yet), and 0 once today has a breaking fight
  // (Oliver, 2026-11-10: a fight logged this morning must end the streak now, not at midnight); best = longest such run; last28 = calm days
  // among the 28 days before today. A `since` after today yields zeros.
  // pips: one per streak day, the last 7 at most, oldest first; true where that day had a level-1 fight (smallDays, the
  // days of fights that do not break the streak). A day in the streak never has a breaking fight, so the two never overlap.
  function calmStats(days, today, since, smallDays) {
    var fought = {}; days.forEach(function (d) { fought[d] = true; });
    var run = 0, best = 0, last28 = 0;
    for (var d = since; d < today; d = addDays(d, 1)) {
      run = fought[d] ? 0 : run + 1;
      if (run > best) best = run;
      if (!fought[d] && dayDiff(d, today) <= 28) last28++;
    }
    if (fought[today]) run = 0;
    var small = {}; (smallDays || []).forEach(function (d) { small[d] = true; });
    var pips = [];
    for (var i = Math.min(run, 7); i >= 1; i--) pips.push(!!small[addDays(today, -i)]);
    return { streak: run, best: best, last28: last28, pips: pips };
  }
  // Does this fight end the viewer's calm streak? Every fight does except one whose chart value is a real rating of 1,
  // the bottom of the scale (Oliver, 2026-11-08: a level-1 fight should not break the streak). It goes through
  // chartValue, so each phone judges by its owner's own rating else the partner's, the same per-viewer rule the chart
  // uses, and a partner's hidden rating never shows through. An unrated fight counts as a break: chartValue plots it at 1
  // only so it shows, nobody said it was minor. Points are untouched: computeLedger's Calm day +3 needs a fight-free
  // day on both phones, so a level-1 fight day keeps the streak but earns no Calm day.
  function breaksStreak(fightId, me, ratings) {
    var v = chartValue(fightId, me, ratings);
    return v.unrated || v.value > 1;
  }
  // ---- fights chart: one number per fight, summed per day --------------------------------------------------------
  // What a fight counts as on the chart: my rating, else my partner's, else 1 and flagged unrated (a fight still has to
  // show, and 1 is the floor of the scale). ratings: [{fight_marker_id, user_id, intensity}]. The chart never shows whose.
  function chartValue(fightId, me, ratings) {
    var mine = null, theirs = null;
    ratings.forEach(function (r) {
      if (r.fight_marker_id !== fightId) return;
      if (r.user_id === me) mine = r.intensity; else theirs = r.intensity;
    });
    if (mine != null) return { value: mine, unrated: false };
    if (theirs != null) return { value: theirs, unrated: false };
    return { value: 1, unrated: true };
  }
  // Per local day: {sum, n, unrated} over the live fights. Days with no fight are absent (they plot as no dot, 0 in the average).
  function dailyTotals(fights, me, ratings, tz) {
    var out = {};
    fights.forEach(function (f) {
      var d = localDay(ms(f.at), tz), v = chartValue(f.id, me, ratings), t = out[d] || (out[d] = { sum: 0, n: 0, unrated: 0 });
      t.sum += v.value; t.n++; if (v.unrated) t.unrated++;
    });
    return out;
  }
  // Mean of the daily sums over the 7 days ending on `day`, zero days included.
  function rollingAvg(totals, day) {
    var t = 0;
    for (var k = 0; k < 7; k++) { var x = totals[addDays(day, -k)]; if (x) t += x.sum; }
    return t / 7;
  }
  // y-axis step and top for a max value: clean ticks starting at 0.
  function niceAxis(max) {
    var m = Math.max(max, 1), st = m <= 6 ? 1 : m <= 12 ? 2 : m <= 30 ? 5 : 10;
    return { step: st, top: Math.ceil(m / st) * st };
  }

  // May the author still change something they just submitted? True for `windowMin` minutes after `createdAtMs`.
  function inEditWindow(createdAtMs, nowMs, windowMin) { return nowMs - createdAtMs < windowMin * MIN; }

  // ---- cycle phase (private fight log) -----------------------------------
  // fights: [{at (ms), intensity}]. Fight = the first 6 hours after the last fight, Calming = from then through the
  // day after, Cool = 2 days after, Warm = day 3 until 60% of the average cycle length, Delicate after that.
  // Fight runs on hours, not days (Oliver, 2026-11-10): a fight should not hold the tile on "Fight" until midnight,
  // and it should not jump straight to Cool either.
  // Phase days roll over at 4 am, not midnight (NIGHT shifts both the fights and `now`): a fight at 1 am belongs to
  // the night before. With midnight days, a 1 am fight still read "Fight" at 3 pm the same date (2026-11-10).
  // 4 am is a guess at "everyone is asleep", not measured. Phase only; points and challenges keep calendar days.
  function phase(fights, now, tz, defaultLen) {
    if (!fights.length) return null;
    var NIGHT = 240 * MIN, FIGHT_HOURS = 6;
    var hrs = (now - Math.max.apply(null, fights.map(function (f) { return f.at; }))) / (60 * MIN);
    now -= NIGHT;
    var days = fights.map(function (f) { return localDay(f.at - NIGHT, tz); }).sort();
    var uniq = days.filter(function (d, i) { return i === 0 || d !== days[i - 1]; });
    var gaps = [];
    for (var i = 1; i < uniq.length; i++) gaps.push(dayDiff(uniq[i - 1], uniq[i]));
    var avg = gaps.length ? gaps.reduce(function (a, b) { return a + b; }, 0) / gaps.length : null;
    var len = avg == null ? (defaultLen || 14) : avg;
    var since = dayDiff(uniq[uniq.length - 1], localDay(now, tz));
    var warmEnd = Math.max(3, len * 0.6);
    var name = hrs < FIGHT_HOURS ? 'Fight' : since <= 1 ? 'Calming' : since === 2 ? 'Cool' : since < warmEnd ? 'Warm' : 'Delicate';
    return { name: name, day: since + 1, avg: avg, len: len, warmEnd: warmEnd, last: uniq[uniq.length - 1] };
  }
  // Home Phase tile sub-line: days since the last fight. Replaced "Day 3 of ~2" (day N of the average cycle), which read
  // as nonsense once the day passed the average; the average itself is dropped because "· avg 2d" wraps the half-width tile.
  function phaseLabel(ph) {
    var since = ph.day - 1;
    return since === 0 ? 'Fought today' : 'Fought ' + since + 'd ago';
  }

  // ---- needs you ---------------------------------------------------------
  // s: {me, now, tz, items, redemptions, nudge_sends, nudge_replies, fight_markers, fight_notes, todos, seen, since}
  function needsYou(s) {
    var out = [];
    var ready = s.items.filter(function (i) {
      return i.sender_id === s.me && i.status === 'held' && !i.deleted_at && ms(i.held_until) <= s.now;
    }).sort(function (a, b) { return ms(a.held_until) - ms(b.held_until); });
    if (ready.length) out.push({ type: 'ready', count: ready.length, item: ready[0] });
    s.redemptions.filter(function (r) { return r.status === 'pending' && r.requested_by !== s.me; })
      .forEach(function (r) { out.push({ type: 'approve', redemption: r }); });
    s.nudge_sends.filter(function (n) {
      return n.recipient_id === s.me && !n.opened_at && !n.deleted_at && ms(n.deliver_at) <= s.now;
    }).sort(function (a, b) { return ms(b.deliver_at) - ms(a.deliver_at); })
      .forEach(function (n) { out.push({ type: 'nudge', send: n }); });
    // unread replies from the other person, one card per nudge thread
    var seen = {};
    s.nudge_replies.filter(function (r) { return r.author_id !== s.me && !r.read_at && !r.deleted_at; })
      .sort(function (a, b) { return ms(b.created_at) - ms(a.created_at); })
      .forEach(function (r) { if (!seen[r.send_id]) { seen[r.send_id] = true; out.push({ type: 'reply', reply: r }); } });
    // a fight the other person logged that is unrepaired and where I have written nothing yet
    var mine = {};
    s.fight_notes.forEach(function (n) { if (n.author_id === s.me) mine[n.fight_marker_id] = true; });
    s.fight_markers.filter(function (m) { return m.logged_by !== s.me && !m.repaired_at && !m.deleted_at && !m.delete_requested_at && !mine[m.id]; })
      .sort(function (a, b) { return ms(b.at) - ms(a.at); })
      .forEach(function (m) { out.push({ type: 'fight', marker: m }); });
    // the other person asked to delete a fight they logged: approve or decline. Carries only the shared marker.
    s.fight_markers.filter(function (m) { return m.logged_by !== s.me && m.delete_requested_at && !m.deleted_at; })
      .sort(function (a, b) { return ms(b.delete_requested_at) - ms(a.delete_requested_at); })
      .forEach(function (m) { out.push({ type: 'fightdel', marker: m }); });
    // An owning-up the other person finished that I have not opened yet. `seen` (ids I opened) is private on-device;
    // `since` is when this install first ran, so rows finished before it (e.g. migrated acknowledgments) never pop up.
    s.todos.filter(function (t) {
      return t.type === 'ownup' && !mineTodo(t, s.me) && t.done_at && !t.deleted_at && !isScheduled(t, s.now) && ms(t.done_at) >= s.since && s.seen.indexOf(t.id) < 0;
    }).sort(function (a, b) { return ms(b.done_at) - ms(a.done_at); })
      .forEach(function (t) { out.push({ type: 'ownup', todo: t }); });
    return out;
  }

  // Home "To do" list: my open to-dos (due or not; never the partner's, done, deleted or not yet delivered), the needs-you cards and the
  // week-close card, in one order: overdue, due today, needs-you cards (their own order), other dated to-dos by date, undated.
  // s: {me, now, today, todos, cards, week, updates (count from updatesCount, 0 = none; its row goes first)}. Returns [{kind:'todo', todo} | {kind:'card', card}].
  // What's new row: how many entries are newer than the last time the page was opened (0 = no row). Hidden for 24h after an open.
  // s: {entries: [{at, text}], seen (ms, 0 = never), now (ms)}.
  function updatesCount(s) {
    var n = s.entries.filter(function (e) { return ms(e.at) > s.seen; }).length;
    return n && s.now - s.seen >= 864e5 ? n : 0;
  }

  function homeList(s) {
    var mine = s.todos.filter(function (t) { return mineTodo(t, s.me) && !t.deleted_at && !t.done_at && !t.declined_at && !isScheduled(t, s.now); })
      .sort(function (a, b) { return a.due_date && b.due_date ? (a.due_date < b.due_date ? -1 : a.due_date > b.due_date ? 1 : 0) : a.due_date ? -1 : b.due_date ? 1 : 0; });
    var tdo = function (t) { return { kind: 'todo', todo: t }; };
    var hot = mine.filter(function (t) { return t.due_date && t.due_date <= s.today; });
    var rest = mine.filter(function (t) { return !(t.due_date && t.due_date <= s.today); });
    var cards = s.cards.concat(s.week ? [s.week] : []).map(function (c) { return { kind: 'card', card: c }; });
    var upd = s.updates ? [{ kind: 'card', card: { type: 'updates', n: s.updates } }] : [];
    return upd.concat(hot.map(tdo), cards, rest.map(tdo));
  }

  // What the Opus evaluation says my account is missing ("" when nothing to show). o: {me, marker, notes (live)}.
  // Hidden once the fight is repaired or deleted, and while my newest note is newer than the evaluation (it has not seen it).
  function fightGap(o) {
    var m = o.marker, g = m.gaps && typeof m.gaps === 'object' ? m.gaps[o.me] : '';
    if (typeof g !== 'string' || !g || m.repaired_at || m.deleted_at) return '';
    // An analysis is interpretation, not an account, so only plain notes count as having written.
    var mine = o.notes.filter(function (n) { return n.fight_marker_id === m.id && n.author_id === o.me && n.kind !== 'analysis'; });
    if (!mine.length) return g;
    if (!m.summary_notes_at) return '';
    var newest = Math.max.apply(null, mine.map(function (n) { return Date.parse(n.updated_at || n.created_at); }));
    return newest > Date.parse(m.summary_notes_at) ? '' : g;
  }

  // Action chips for one fight, from the viewer's side. o: {me, partner: {user_id, name}, marker, notes, todos}.
  // -> [{kind: 'add'} | {kind: 'todo', id, title} | {kind: 'wait', name}]. Held asks have no todo yet, so they never show.
  // Once I have written my side there is no chip for more detail; the fight page shows what is missing.
  function fightActions(o) {
    var out = [], open = function (t) { return t.fight_marker_id === o.marker.id && !t.done_at && !t.declined_at && !t.deleted_at; };
    var wrote = function (uid) { return o.notes.some(function (n) { return n.fight_marker_id === o.marker.id && n.author_id === uid && n.kind !== 'analysis'; }); };
    var repaired = !!o.marker.repaired_at;
    if (!repaired && !wrote(o.me)) out.push({ kind: 'add' });
    o.todos.filter(function (t) { return open(t) && mineTodo(t, o.me); })
      .forEach(function (t) { out.push({ kind: 'todo', id: t.id, title: t.title }); });
    var askedHer = o.todos.some(function (t) { return open(t) && !t.shared && t.owner_id === o.partner.user_id && t.created_by === o.me; });
    if ((!repaired && !wrote(o.partner.user_id)) || askedHer) out.push({ kind: 'wait', name: o.partner.name });
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

  // ---- Talk it through ----------------------------------------------------
  // The state of one fight's four-step talk, derived from the append-only talkthrough_events rows the viewer can SEE (RLS withholds the
  // partner's side / own-up text until the viewer finishes that step, so `rows` is already filtered; this function never conceals).
  // Steps: 1 Side, 2 Heard, 3 Own up, 4 Requests; step 5 = complete. A step is finished only when BOTH people have finished it, and
  // step 2 only when each person's latest "heard" carries the author's latest verdict Got it.
  // Returns { step, done[1..4] = [me, partner], myTurn, partnerSideIn, myHeard, theirHeard, myVerdict, theirVerdict, started }.
  // myTurn is the step's pending action for ME (write / answer / revise); false when I am waiting on the partner.
  function ttLatest(rows, kind, author) {
    var best = null;
    rows.forEach(function (e) { if (e.kind === kind && e.author_id === author && (!best || ms(e.created_at) >= ms(best.created_at))) best = e; });
    return best;
  }
  function ttState(rows, me, partner) {
    var has = function (kind, who) { return rows.some(function (e) { return e.kind === kind && e.author_id === who; }); };
    var verdictOn = function (heard) { // the answer the author of the side gave to this reflection (latest wins)
      var best = null;
      rows.forEach(function (e) { if (e.kind === 'verdict' && e.ref_id === heard.id && (!best || ms(e.created_at) >= ms(best.created_at))) best = e; });
      return best;
    };
    var myHeard = ttLatest(rows, 'heard', me), theirHeard = ttLatest(rows, 'heard', partner);
    var myVerdict = theirHeard && verdictOn(theirHeard), theirVerdict = myHeard && verdictOn(myHeard);
    var done = { 1: [has('side_done', me), has('side_done', partner)], 3: [has('ownup_done', me), has('ownup_done', partner)], 4: [has('requests_done', me), has('requests_done', partner)] };
    // Step 2, per person: finished = that person's reflection got a Got it from the author of the side it reflects.
    done[2] = [!!(theirVerdict && theirVerdict.verdict === 'got_it'), !!(myVerdict && myVerdict.verdict === 'got_it')];
    var revise = !!theirVerdict && theirVerdict.verdict === 'not_quite';
    // skip / sorted / reopen: the newest of them decides (append-only, either person can write one). They never touch the step
    // derivation below, so a reopen returns the talk to exactly the step / turn the rows already say.
    var ctl = null, stepRows = false;
    rows.forEach(function (e) {
      if (e.kind === 'skip' || e.kind === 'sorted' || e.kind === 'reopen') { if (!ctl || ms(e.created_at) >= ms(ctl.created_at)) ctl = e; } else stepRows = true;
    });
    var step = 5;
    for (var i = 1; i <= 4; i++) if (!(done[i][0] && done[i][1])) { step = i; break; }
    var turn = false;
    if (step === 2) {
      // Write my reflection (first time, or after a Not quite on my latest one) or answer the partner's. A verdict answers one heard row by
      // id, so a newer heard row of mine has no verdict yet and no clock of the other phone is compared.
      turn = !myHeard || revise || (!!theirHeard && !myVerdict);
    } else if (step <= 4) turn = !done[step][0];
    return { step: step, done: done, myTurn: turn, partnerSideIn: has('side_done', partner) && !has('side_done', me), myHeard: myHeard, theirHeard: theirHeard, myVerdict: myVerdict, theirVerdict: theirVerdict, revise: revise,
      // A skip only means something before any step row exists; a reopen with no step rows is Start anyway, so the talk has started.
      ended: !!ctl && ctl.kind === 'sorted', skipped: !!ctl && ctl.kind === 'skip' && !stepRows,
      // the row that ended / skipped the talk (who, when, reason), null otherwise
      ctl: ctl && (ctl.kind === 'sorted' || (ctl.kind === 'skip' && !stepRows)) ? ctl : null,
      started: stepRows || (!!ctl && ctl.kind === 'reopen') };
  }

  // ---- To-do time: a set time when the two plan to do it (no penalty, unlike due_date). ----
  // One person proposes (time_at + time_by, time_ok_at null); the other agrees (time_ok_at) or proposes another. A to-do only
  // its creator+owner can act on is agreed at once. Rows from before the columns exist have time_at undefined and read as 'none'.
  // 'none' | 'mine' (I proposed, waiting) | 'theirs' (they proposed, my answer) | 'agreed'.
  function timeState(t, me) {
    if (!t.time_at) return 'none';
    if (t.time_ok_at) return 'agreed';
    return t.time_by === me ? 'mine' : 'theirs';
  }
  // A time can be set only on an open, live to-do (done / declined / deleted ones are over).
  function timeOpen(t) { return !t.deleted_at && !t.done_at && !t.declined_at; }
  // Alone = nobody else is involved, so there is nobody to agree with: my own, made by me, not for Both.
  function timeSolo(t, me) { return t.owner_id === me && t.created_by === me && !t.shared; }
  // The patch a Time-sheet confirm writes: Set (solo) is agreed now, Propose waits for the other person.
  function timeSave(t, me, atMs, nowIso) {
    return { time_at: new Date(atMs).toISOString(), time_by: me, time_ok_at: timeSolo(t, me) ? nowIso : null };
  }
  function timeAgreePatch(nowIso) { return { time_ok_at: nowIso }; }
  function timeClearPatch() { return { time_at: null, time_by: null, time_ok_at: null }; }
  // Only an agreed, future time on an open to-do notifies (a proposal never does, and a past time has nothing to wake).
  function timeNotify(t, now) { return timeState(t, '') === 'agreed' && ms(t.time_at) > now && timeOpen(t); }

  return {
    timeState: timeState, timeOpen: timeOpen, timeSolo: timeSolo, timeSave: timeSave, timeAgreePatch: timeAgreePatch, timeClearPatch: timeClearPatch, timeNotify: timeNotify,
    localDay: localDay, addDays: addDays, dayDiff: dayDiff, dow: dow, weekStart: weekStart,
    appendSpeech: appendSpeech, dueInfo: dueInfo, holdMinutes: holdMinutes, heldUntil: heldUntil, countdown: countdown, heldLabel: heldLabel, durText: durText, ms: ms,
    isScheduled: isScheduled, scheduleAt: scheduleAt, buildItem: buildItem, askToTodo: askToTodo, mineTodo: mineTodo,
    zonedMs: zonedMs, deliverAt: deliverAt, issueHeldUntil: issueHeldUntil, sectionNudges: sectionNudges,
    RULES: { STREAK_CAP: STREAK_CAP, STREAK_WEEK_OLD: STREAK_WEEK_OLD, STREAK_MONTH: STREAK_MONTH, REBAL_DAY: REBAL_DAY, CALM_PAY: CALM_PAY, FREE_WEEK_STEP: FREE_WEEK_STEP, FREE_WEEK_CAP: FREE_WEEK_CAP, MONTH_MISS: MONTH_MISS, FIGHT_COST: FIGHT_COST, HIT_FIRST: HIT_FIRST, HIT_LATER: HIT_LATER },
    addMonths: addMonths, splitPayout: splitPayout, awardStatus: awardStatus,
    earnPts: earnPts, missPts: missPts, periodOf: periodOf, habitCount: habitCount, habitMisses: habitMisses, requireNote: requireNote, isEdited: isEdited,
    pingPenalties: pingPenalties, computeLedger: computeLedger, hitText: hitText, groupWeek: groupWeek, phase: phase, phaseLabel: phaseLabel, needsYou: needsYou, homeList: homeList, updatesCount: updatesCount, calmStats: calmStats, breaksStreak: breaksStreak, inEditWindow: inEditWindow, monthGrid: monthGrid, chartValue: chartValue, dailyTotals: dailyTotals, rollingAvg: rollingAvg, niceAxis: niceAxis, fightActions: fightActions, fightGap: fightGap,
    // Only a still-held item may offer Send / Edit / Drop; a stale notification can point at a delivered or dropped one.
    ttState: ttState,
    isStillHeld: function (i) { return !!i && i.status === 'held' && !i.deleted_at; }
  };
})();
if (typeof module !== 'undefined' && module.exports) module.exports = CycleCore;

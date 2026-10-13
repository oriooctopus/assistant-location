// Gripes core: pure logic (no DOM, no bridge). Loaded as a classic script in
// the app (window.GripesCore) and via require() in WebPagesTests.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.GripesCore = factory();
})(this, function () {
  'use strict';

  var HOUR = 3600000, DAY = 86400000;
  var DURATION_KEYS = ['under_1h', 'few_hours', 'rest_of_day', 'few_days', 'week_plus'];
  var DURATION_LABELS = {
    under_1h: 'under an hour', few_hours: 'a few hours', rest_of_day: 'rest of today',
    few_days: 'a few days', week_plus: 'a week+'
  };
  var DEFAULT_LOCATIONS = ['Spine', 'Rhomboid', 'Jaw', 'Hand', 'Foot'];
  var WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  function uuid() {
    var b = new Uint8Array(16);
    crypto.getRandomValues(b);
    b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
    var h = Array.prototype.map.call(b, function (x) { return ('0' + x.toString(16)).slice(-2); }).join('');
    return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
  }
  function key(s) { return String(s).trim().toLowerCase().replace(/\s+/g, ' '); }
  function canon(s) {
    s = String(s).trim().replace(/\s+/g, ' ');
    return s.charAt(0).toUpperCase() + s.slice(1);
  }
  function ms(iso) { return new Date(iso).getTime(); }
  function startOfDay(t) { var d = new Date(t); d.setHours(0, 0, 0, 0); return d.getTime(); }
  function avg(a) { return a.length ? a.reduce(function (x, y) { return x + y; }, 0) / a.length : null; }

  function makeEntry(f, now) {
    var iso = new Date(now).toISOString();
    return {
      id: uuid(), kind: f.kind, issue: canon(f.issue), intensity: f.intensity,
      expectedDuration: f.kind === 'pain' ? (f.expectedDuration || null) : null,
      note: f.note || null, source: f.source || 'tap', createdAt: iso,
      rerates: [], goneAt: null, updatedAt: iso
    };
  }
  function latestRerate(e) {
    for (var i = e.rerates.length - 1; i >= 0; i--) if (typeof e.rerates[i].intensity === 'number') return e.rerates[i].intensity;
    return null;
  }

  // ---------------- autocomplete ----------------
  function issueStats(entries, kind) {
    var m = {};
    entries.forEach(function (e) {
      if (e.kind !== kind) return;
      var k = key(e.issue), t = ms(e.createdAt);
      var s = m[k] || (m[k] = { key: k, name: e.issue, count: 0, last: -Infinity });
      s.count++;
      if (t >= s.last) { s.last = t; s.name = e.issue; }
    });
    if (kind === 'pain') DEFAULT_LOCATIONS.forEach(function (n) {
      if (!m[key(n)]) m[key(n)] = { key: key(n), name: n, count: 0, last: -Infinity };
    });
    return Object.keys(m).map(function (k) { return m[k]; });
  }
  function byFreqRecency(a, b) {
    return (b.count - a.count) || (b.last - a.last) || a.name.localeCompare(b.name);
  }
  function lastSeenLabel(t, now) {
    if (t === -Infinity) return '';
    if (startOfDay(t) === startOfDay(now)) return 'today';
    var d = new Date(t);
    if (now - t < 6 * DAY) return WEEKDAYS[d.getDay()];
    return MONTHS[d.getMonth()] + ' ' + d.getDate();
  }
  // Starts-with (whole string) first, then word-start, then contains; each tier by frequency then recency.
  function suggest(query, entries, kind, now, limit) {
    var q = key(query);
    if (!q) return [];
    var out = [];
    issueStats(entries, kind).forEach(function (s) {
      var i = s.key.indexOf(q), tier;
      if (i === 0) tier = 0;
      else if (i > 0 && s.key.charAt(i - 1) === ' ') tier = 1;
      else if (i > 0) tier = 2;
      else return;
      out.push({ name: s.name, count: s.count, last: s.last, tier: tier, matchStart: i, matchLen: q.length,
                 meta: s.count ? (s.count + 'x · ' + lastSeenLabel(s.last, now)) : '' });
    });
    out.sort(function (a, b) { return (a.tier - b.tier) || byFreqRecency(a, b); });
    return out.slice(0, limit || 4);
  }
  function topChips(entries, kind, limit) {
    var all = issueStats(entries, kind).sort(byFreqRecency);
    var used = all.filter(function (s) { return s.count > 0; });
    var chips = used.slice(0, limit || 6);
    if (kind === 'pain') DEFAULT_LOCATIONS.forEach(function (n) {
      if (chips.length < (limit || 6) && !chips.some(function (c) { return c.key === key(n); })) chips.push(all.filter(function (s) { return s.key === key(n); })[0]);
    });
    return { chips: chips.map(function (c) { return c.name; }), more: Math.max(0, used.length - (limit || 6)) };
  }

  // ---------------- re-rate ----------------
  function rerateQueue(entries, now, opts) {
    opts = opts || {};
    var minComplaint = opts.minComplaintAgeMs != null ? opts.minComplaintAgeMs : 2 * HOUR;
    var minPain = opts.minPainAgeMs != null ? opts.minPainAgeMs : 30 * 60000;
    var cap = opts.cap || 10;
    var pain = [], comp = [];
    entries.forEach(function (e) {
      if (e.goneAt) return;
      var age = now - ms(e.createdAt);
      if (e.kind === 'pain' && age >= minPain) pain.push(e);
      else if (e.kind === 'complaint' && e.rerates.length === 0 && age >= minComplaint) comp.push(e);
    });
    var newest = function (a, b) { return ms(b.createdAt) - ms(a.createdAt); };
    return pain.sort(newest).concat(comp.sort(newest)).slice(0, cap);
  }
  function applyRerate(e, r, now) {
    var iso = new Date(now).toISOString(), c = JSON.parse(JSON.stringify(e));
    c.rerates.push({ at: iso, intensity: r.gone ? null : r.intensity, gone: !!r.gone });
    if (r.gone) c.goneAt = iso;
    c.updatedAt = iso;
    return c;
  }
  function rerateHint(e, entries) {
    var k = key(e.issue), best = null;
    entries.forEach(function (o) {
      if (o.id === e.id || o.kind !== e.kind || key(o.issue) !== k || latestRerate(o) == null) return;
      if (!best || ms(o.createdAt) > ms(best.createdAt)) best = o;
    });
    return best ? 'Last time this went ' + best.intensity + ' → ' + latestRerate(best) + '.' : null;
  }

  // ---------------- pain duration ----------------
  function rankOfMs(d) { return d < HOUR ? 0 : d < 6 * HOUR ? 1 : d < DAY ? 2 : d < 4 * DAY ? 3 : 4; }
  function fmtSpan(d) {
    if (d < HOUR) return Math.max(1, Math.round(d / 60000)) + ' min';
    if (d < DAY) { var h = d / HOUR; return (h < 10 ? Math.round(h * 10) / 10 : Math.round(h)) + ' h'; }
    var days = d / DAY; return (days < 10 ? Math.round(days * 10) / 10 : Math.round(days)) + ' d';
  }
  // verdict: shorter | asExpected | longer | pending | none
  function painDuration(e, now) {
    var exp = e.expectedDuration ? DURATION_KEYS.indexOf(e.expectedDuration) : -1;
    if (e.goneAt) {
      var act = ms(e.goneAt) - ms(e.createdAt), r = rankOfMs(act);
      return { actualMs: act, actualLabel: fmtSpan(act), resolved: true,
               verdict: exp < 0 ? 'none' : r < exp ? 'shorter' : r > exp ? 'longer' : 'asExpected' };
    }
    var el = now - ms(e.createdAt);
    return { actualMs: null, stillMs: el, stillLabel: '≥' + fmtSpan(el), resolved: false, verdict: exp < 0 ? 'none' : 'pending' };
  }

  // ---------------- review ----------------
  var BANDS = ['Morning', 'Midday', 'Evening', 'Night'];
  function bandOf(h) { return h >= 5 && h < 12 ? 0 : h >= 12 && h < 17 ? 1 : h >= 17 && h < 22 ? 2 : 3; }
  function heatmap(list) {
    var m = BANDS.map(function () { return [0, 0, 0, 0, 0, 0, 0]; }), max = 0;
    list.forEach(function (e) {
      var d = new Date(e.createdAt), col = (d.getDay() + 6) % 7;
      max = Math.max(max, ++m[bandOf(d.getHours())][col]);
    });
    return { rows: BANDS, cells: m, max: max };
  }
  function track(list, now, kind) {
    var weekStart = startOfDay(now) - 6 * DAY;
    var inWeek = list.filter(function (e) { return ms(e.createdAt) >= weekStart; });
    var trend = [];
    for (var w = 3; w >= 0; w--) {
      var hi = now - w * 7 * DAY, lo = hi - 7 * DAY;
      var blk = list.filter(function (e) { var t = ms(e.createdAt); return t > lo && t <= hi; });
      trend.push({ label: 'W' + (4 - w), logged: avg(blk.map(function (e) { return e.intensity; })),
                   rerated: avg(blk.map(latestRerate).filter(function (x) { return x != null; })) });
    }
    var groups = {};
    inWeek.forEach(function (e) { (groups[key(e.issue)] = groups[key(e.issue)] || []).push(e); });
    var top = Object.keys(groups).map(function (k) {
      var g = groups[k];
      return { name: g[g.length - 1].issue, count: g.length, logged: avg(g.map(function (e) { return e.intensity; })),
               rerated: avg(g.map(latestRerate).filter(function (x) { return x != null; })) };
    }).sort(function (a, b) { return (b.count - a.count) || a.name.localeCompare(b.name); }).slice(0, 4);
    return {
      kind: kind, count: inWeek.length,
      logged: avg(inWeek.map(function (e) { return e.intensity; })),
      rerated: avg(inWeek.map(latestRerate).filter(function (x) { return x != null; })),
      trend: trend, top: top, heat: heatmap(inWeek)
    };
  }
  function durationReport(entries, now) {
    var weekStart = startOfDay(now) - 6 * DAY;
    var rows = entries.filter(function (e) { return e.kind === 'pain' && ms(e.createdAt) >= weekStart; })
      .map(function (e) { var d = painDuration(e, now); d.id = e.id; d.issue = e.issue; d.expected = e.expectedDuration; return d; });
    var judged = rows.filter(function (r) { return r.resolved && r.verdict !== 'none'; });
    return {
      rows: rows, judged: judged.length,
      shorter: judged.filter(function (r) { return r.verdict === 'shorter'; }).length,
      asExpected: judged.filter(function (r) { return r.verdict === 'asExpected'; }).length,
      longer: judged.filter(function (r) { return r.verdict === 'longer'; }).length,
      stillGoing: rows.filter(function (r) { return !r.resolved; }).length
    };
  }
  function together(entries, now) {
    var today = startOfDay(now), days = [];
    for (var i = 6; i >= 0; i--) {
      var lo = today - i * DAY, hi = lo + DAY;
      var inDay = function (k) { return entries.filter(function (e) { var t = ms(e.createdAt); return e.kind === k && t >= lo && t < hi; }).map(function (e) { return e.intensity; }); };
      days.push({ day: new Date(lo).getDay(), complaint: avg(inDay('complaint')), pain: avg(inDay('pain')) });
    }
    var hiDays = days.filter(function (d) { return d.pain != null && d.pain > 4 && d.complaint != null; });
    var loDays = days.filter(function (d) { return d.pain != null && d.pain <= 4 && d.complaint != null; });
    var corr = null;
    if (hiDays.length && loDays.length) {
      var h = avg(hiDays.map(function (d) { return d.complaint; })), l = avg(loDays.map(function (d) { return d.complaint; }));
      corr = { highDays: hiDays.length, lowDays: loDays.length, highAvg: h, lowAvg: l, delta: h - l };
    }
    return { days: days, correlation: corr };
  }
  function retired(entries, now) {
    var out = [];
    ['complaint', 'pain'].forEach(function (kind) {
      issueStats(entries, kind).forEach(function (s) {
        var days = Math.floor((now - s.last) / DAY);
        if (s.count >= 3 && days >= 14 && days <= 28) out.push({ name: s.name, kind: kind, days: days });
      });
    });
    return out.sort(function (a, b) { return a.days - b.days; });
  }
  function weekReview(entries, now) {
    var start = startOfDay(now) - 6 * DAY;
    var s = new Date(start), e = new Date(now);
    return {
      label: MONTHS[s.getMonth()] + ' ' + s.getDate() + ' – ' + (s.getMonth() === e.getMonth() ? '' : MONTHS[e.getMonth()] + ' ') + e.getDate(),
      complaint: track(entries.filter(function (x) { return x.kind === 'complaint'; }), now, 'complaint'),
      pain: track(entries.filter(function (x) { return x.kind === 'pain'; }), now, 'pain'),
      durations: durationReport(entries, now),
      together: together(entries, now),
      retired: retired(entries, now)
    };
  }

  // ---------------- voice parsing ----------------
  var NUMWORDS = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10 };
  var UNIT_AFTER = /^(am|pm|o'?clock|oclock|minutes?|mins?|hours?|hrs?|days?|weeks?|times?|percent|years?|%)$/;
  var LOCATION_TABLE = [
    ['shoulder blades', 'Rhomboid'], ['shoulder blade', 'Rhomboid'], ['rhomboids', 'Rhomboid'], ['rhomboid', 'Rhomboid'],
    ['upper back', 'Spine'], ['mid back', 'Spine'], ['middle back', 'Spine'], ['spine', 'Spine'], ['back', 'Spine'],
    ['lower back', 'Lower back'],
    ['jaw', 'Jaw'], ['tmj', 'Jaw'],
    ['hands', 'Hand'], ['hand', 'Hand'], ['fingers', 'Hand'], ['finger', 'Hand'], ['wrists', 'Wrist'], ['wrist', 'Wrist'],
    ['feet', 'Foot'], ['foot', 'Foot'], ['heel', 'Foot'], ['toes', 'Foot'], ['toe', 'Foot'],
    ['neck', 'Neck'], ['head', 'Head'], ['shoulder', 'Shoulder'], ['elbow', 'Elbow'], ['knee', 'Knee'], ['hip', 'Hip'],
    ['ankle', 'Ankle'], ['arm', 'Arm'], ['leg', 'Leg'], ['stomach', 'Stomach'], ['chest', 'Chest'], ['eye', 'Eye']
  ];
  var CENTRAL = { Spine: 1, 'Lower back': 1, Neck: 1, Head: 1, Jaw: 1, Stomach: 1, Chest: 1 };
  var DURATION_PATTERNS = [
    ['week_plus', /\b(?:a|one|1) week\b|\bweeks\b|\blong time\b|\bmonths?\b|\bchronic\b|\ball week\b/],
    ['few_days', /\b(?:a )?(?:few|couple(?: of)?|several|two|three|four) days\b|\bthe weekend\b/],
    ['few_hours', /\b(?:a )?(?:few|couple(?: of)?|several|two|three|four) hours\b/],
    ['rest_of_day', /\brest of (?:the day|today|tonight|the evening)\b|\ball day\b|\b(?:until|till) tonight\b/],
    ['under_1h', /\b(?:less than|under|within) an hour\b|\ban hour or less\b|\b(?:a )?(?:few|couple(?: of)?) minutes\b|\bhalf an hour\b|\ban hour\b/]
  ];
  var STOP = {};
  ('i i\'m im my the a an is are was it it\'s its this that and but so um uh like just really very still again today yesterday ' +
   'probably maybe bugging bothering bothers bugs bothered me about with of on in at to for been being have has had kind sort ' +
   'lot little bit pretty quite actually honestly literally rating rate out').split(' ').forEach(function (w) { STOP[w] = 1; });
  var LEAD = { a: 1, an: 1, about: 1, around: 1, roughly: 1, maybe: 1, probably: 1, like: 1, at: 1, is: 1, "it's": 1, its: 1, it: 1,
               bothers: 1, bothering: 1, bothered: 1, me: 1, rating: 1, rate: 1, "that's": 1, say: 1 };

  function tokenize(text) {
    var re = /[A-Za-z0-9'’%]+/g, m, out = [];
    while ((m = re.exec(text))) out.push({ w: m[0].toLowerCase().replace(/’/g, "'"), start: m.index, end: m.index + m[0].length });
    return out;
  }
  function findIntensity(toks) {
    var cands = [];
    toks.forEach(function (t, i) {
      var n = /^\d+$/.test(t.w) ? parseInt(t.w, 10) : NUMWORDS[t.w];
      if (!n || n < 1 || n > 10) return;
      var next = toks[i + 1], prev = toks[i - 1];
      if (next && UNIT_AFTER.test(next.w)) return;
      if (prev && prev.w === 'at') return;
      if (prev && prev.w === 'of' && toks[i - 2] && toks[i - 2].w === 'out') return; // denominator
      var outOf = next && next.w === 'out' && toks[i + 2] && toks[i + 2].w === 'of' && toks[i + 3];
      cands.push({ i: i, n: n, outOf: !!outOf, endTok: outOf ? i + 3 : i });
    });
    if (!cands.length) return null;
    var pick = cands.filter(function (c) { return c.outOf; })[0] || cands[cands.length - 1];
    var first = pick.i;
    while (first > 0 && LEAD[toks[first - 1].w]) first--;
    return { value: pick.n, tokFrom: first, tokTo: pick.endTok, start: toks[first].start, end: toks[pick.endTok].end };
  }
  function findDuration(lower) {
    for (var i = 0; i < DURATION_PATTERNS.length; i++) {
      var m = DURATION_PATTERNS[i][1].exec(lower);
      if (m) return { key: DURATION_PATTERNS[i][0], start: m.index, end: m.index + m[0].length };
    }
    return null;
  }
  function esc(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
  function findLocation(lower, knownLocations) {
    var best = null;
    function consider(re, name, central) {
      var m = re.exec(lower);
      if (!m) return;
      var start = m.index, len = m[0].length;
      if (!best || len > best.len || (len === best.len && start < best.start)) best = { name: name, start: start, end: start + len, len: len, central: central };
    }
    (knownLocations || []).forEach(function (n) { consider(new RegExp('\\b' + esc(key(n)) + '\\b'), n); });
    var known = best;
    LOCATION_TABLE.forEach(function (row) {
      var side = CENTRAL[row[1]] ? '' : '(?:(left|right)\\s+)?';
      var re = new RegExp('\\b' + side + esc(row[0]) + '\\b'), m = re.exec(lower);
      if (!m) return;
      var name = (m[1] ? canon(m[1]) + ' ' + row[1].toLowerCase() : row[1]);
      if (!best || (best === known && m[0].length > best.len) || (best !== known && m[0].length > best.len)) {
        best = { name: name, start: m.index, end: m.index + m[0].length, len: m[0].length };
      }
    });
    return best ? { name: best.name, start: best.start, end: best.end } : null;
  }
  function stem(w) { return w.length > 3 ? w.replace(/s$/, '') : w; }
  function matchExistingIssue(words, issues) {
    var have = {};
    words.forEach(function (w) { have[stem(w)] = 1; });
    var best = null;
    issues.forEach(function (s) {
      var toks = key(s.name).split(' ').filter(function (w) { return !STOP[w]; }).map(stem);
      if (!toks.length) return;
      var hit = toks.filter(function (w) { return have[w]; }).length;
      var ok = hit === toks.length || (hit >= 1 && hit / toks.length >= 0.5 && toks.some(function (w) { return have[w] && w.length >= 4; }));
      if (!ok) return;
      var score = hit * 1000 + s.count;
      if (!best || score > best.score) best = { name: s.name, score: score };
    });
    return best && best.name;
  }

  // ctx: {mode: 'pain'|'complaint', entries}. Returns captured items with char spans into `text`.
  function parseTranscript(text, ctx) {
    var mode = ctx.mode, entries = ctx.entries || [];
    var lower = text.toLowerCase(), toks = tokenize(text), spans = [];
    var res = { mode: mode, issue: null, intensity: null, duration: null, spans: spans, complete: false };
    var inten = findIntensity(toks);
    if (inten) { res.intensity = { value: inten.value }; spans.push({ start: inten.start, end: inten.end, kind: 'intensity' }); }
    if (mode === 'pain') {
      var dur = findDuration(lower);
      if (dur) { res.duration = { key: dur.key }; spans.push({ start: dur.start, end: dur.end, kind: 'duration' }); }
      var known = issueStats(entries, 'pain').filter(function (s) { return s.count > 0; }).map(function (s) { return s.name; });
      var loc = findLocation(lower, known);
      if (!loc) {
        var words = toks.map(function (t) { return t.w; });
        var m = matchExistingIssue(words, issueStats(entries, 'pain').filter(function (s) { return s.count > 0; }));
        if (m) res.issue = { name: m, isNew: false };
      } else {
        res.issue = { name: loc.name, isNew: !issueStats(entries, 'pain').some(function (s) { return s.count > 0 && s.key === key(loc.name); }) };
        spans.push({ start: loc.start, end: loc.end, kind: 'issue' });
      }
      if (res.issue) res.issue.isNew = false; // locations are a closed-ish vocabulary: no NEW tag
    } else {
      var used = {};
      if (inten) for (var i = inten.tokFrom; i <= inten.tokTo; i++) used[i] = 1;
      var rest = [], restToks = [];
      toks.forEach(function (t, i) { if (!used[i] && !STOP[t.w]) { rest.push(t.w); restToks.push(t); } });
      var existing = matchExistingIssue(toks.filter(function (t, i) { return !used[i]; }).map(function (t) { return t.w; }),
                                        issueStats(entries, 'complaint').filter(function (s) { return s.count > 0; }));
      if (existing) {
        res.issue = { name: existing, isNew: false };
        var ek = key(existing).split(' ').map(stem);
        restToks.forEach(function (t) { if (ek.indexOf(stem(t.w)) >= 0) spans.push({ start: t.start, end: t.end, kind: 'issue' }); });
      } else if (rest.length) {
        var take = restToks.slice(0, 6);
        res.issue = { name: canon(take.map(function (t) { return t.w; }).join(' ')), isNew: true };
        take.forEach(function (t) { spans.push({ start: t.start, end: t.end, kind: 'issue' }); });
      }
    }
    spans.sort(function (a, b) { return a.start - b.start; });
    res.complete = !!(res.issue && res.intensity);
    return res;
  }

  return {
    DURATION_KEYS: DURATION_KEYS, DURATION_LABELS: DURATION_LABELS, DEFAULT_LOCATIONS: DEFAULT_LOCATIONS,
    uuid: uuid, key: key, canon: canon, makeEntry: makeEntry, latestRerate: latestRerate,
    issueStats: issueStats, suggest: suggest, topChips: topChips, lastSeenLabel: lastSeenLabel,
    rerateQueue: rerateQueue, applyRerate: applyRerate, rerateHint: rerateHint,
    painDuration: painDuration, weekReview: weekReview, durationReport: durationReport, together: together,
    retired: retired, heatmap: heatmap, parseTranscript: parseTranscript, fmtSpan: fmtSpan, startOfDay: startOfDay
  };
});

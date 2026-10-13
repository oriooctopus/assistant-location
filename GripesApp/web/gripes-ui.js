// Gripes UI: renders the four views (log, voice, re-rate, review) from one
// in-memory state object. All logic lives in gripes-core.js (unit tested);
// persistence is the native store behind the `gl` bridge (loadEntries /
// upsertEntry / deleteEntry). Nothing here touches the network: the native
// outbox syncs to the box on its own, so the UI never waits on it.
(function () {
  'use strict';
  var C = window.GripesCore;
  var app = document.getElementById('app');

  var S = {
    mode: 'pain',               // mode of the NEXT entry; kept after a save
    view: 'log',                // log | voice | rerate | review
    entries: [],
    draft: { issue: '', intensity: null, duration: null },
    typing: false,              // input focused with text: show autocomplete
    toast: null,                // {entry} after a save
    loggedCount: 0,
    voice: { text: '', parsed: null, error: null, countdown: null, active: false },
    queue: [], queuePos: 0, rerateTotal: 0,
    banner: null,
    persist: true               // false only for the DEBUG screenshot scenarios
  };
  var countdownTimer = null;

  function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function now() { return Date.now(); }
  function fail(what, err) {
    // Loud, not silent: a failed native write means the entry is NOT durable.
    console.error('[gripes] ' + what, err);
    S.banner = what + ': ' + (err && err.message ? err.message : err);
    render();
  }
  function bridge(method, params) { return window.GLBridge.call(method, params || {}); }

  // ---------- persistence ----------
  function save(entry) {
    var i = S.entries.findIndex(function (e) { return e.id === entry.id; });
    if (i >= 0) S.entries[i] = entry; else S.entries.push(entry);
    if (S.persist) bridge('upsertEntry', { entry: entry }).catch(function (e) { fail('Could not save entry', e); });
  }
  function remove(id) {
    S.entries = S.entries.filter(function (e) { return e.id !== id; });
    if (S.persist) bridge('deleteEntry', { id: id }).catch(function (e) { fail('Could not undo entry', e); });
  }
  function load() {
    return bridge('loadEntries').then(function (r) { S.entries = r.entries; });
  }

  // ---------- helpers ----------
  function highlight(name, start, len) {
    return esc(name.slice(0, start)) + '<b>' + esc(name.slice(start, start + len)) + '</b>' + esc(name.slice(start + len));
  }
  function setMode(m) { S.mode = m; document.documentElement.dataset.mode = m; }
  function whenLabel(iso) {
    var d = new Date(iso), h = d.getHours(), mm = ('0' + d.getMinutes()).slice(-2);
    return ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d.getDay()] + ' ' + ((h + 11) % 12 + 1) + ':' + mm + ' ' + (h < 12 ? 'AM' : 'PM');
  }
  function avgFmt(x) { return x == null ? '–' : (Math.round(x * 10) / 10).toString(); }
  var MIC = '<svg viewBox="0 0 24 24"><path d="M12 15a3 3 0 0 0 3-3V6a3 3 0 0 0-6 0v6a3 3 0 0 0 3 3zm5-3a5 5 0 0 1-10 0H5a7 7 0 0 0 6 6.92V22h2v-3.08A7 7 0 0 0 19 12z"/></svg>';

  // ---------- log view ----------
  function logView() {
    var pain = S.mode === 'pain', d = S.draft, q = d.issue.trim();
    var h = '<div class="top"><div class="tog">' +
      '<button data-act="mode" data-v="pain" class="' + (pain ? 'on' : '') + '">Pain</button>' +
      '<button data-act="mode" data-v="complaint" class="' + (!pain ? 'on' : '') + '">Complaint</button></div>' +
      '<button class="iconbtn" data-act="review" aria-label="Weekly review">▤</button></div>';
    h += '<div class="big ' + (S.typing ? 'focus' : '') + '"><input id="issue" autocomplete="off" autocapitalize="sentences" enterkeyhint="done" ' +
      'placeholder="' + (pain ? 'Where does it hurt?' : "What’s bugging you?") + '" value="' + esc(d.issue) + '">' +
      '<button class="mic" data-act="voice" aria-label="Speak">' + MIC + '</button></div>';
    var sug = q ? C.suggest(q, S.entries, S.mode, now(), 4) : [];
    var exact = sug.some(function (s) { return C.key(s.name) === C.key(q); });
    if (q && S.typing && !(S.draft.intensity != null && exact)) {
      sug.forEach(function (s) {
        h += '<button class="acr" data-act="pick" data-v="' + esc(s.name) + '"><span>' + highlight(s.name, s.matchStart, s.matchLen) + '</span><small>' + esc(s.meta) + '</small></button>';
      });
      if (!exact) h += '<button class="addnew" data-act="pick" data-v="' + esc(C.canon(q)) + '"><i>+</i><span>Add <b>“' + esc(q) + '”</b> as new</span></button>';
      return h + footer();
    }
    var chips = C.topChips(S.entries, S.mode, 6).chips;
    if (!q) {
      h += '<div class="lbl">Recent</div><div class="chips where">' + chips.map(function (c) {
        return '<button class="chip" data-act="pick" data-v="' + esc(c) + '">' + esc(c) + '</button>';
      }).join('') + '</div>';
    } else {
      h += '<div class="lbl">' + (pain ? 'Where' : 'Issue') + '</div><div class="chips where"><button class="chip on" data-act="clear">' + esc(q) + ' ✕</button></div>';
    }
    h += '<div class="lbl">' + (pain ? 'How bad is the pain?' : 'How much does it bother you?') + '</div><div class="grid">';
    for (var i = 1; i <= 10; i++) h += '<button class="n ' + (d.intensity === i ? 'on' : '') + '" data-act="num" data-v="' + i + '">' + i + '</button>';
    h += '</div><div class="ends"><span>1 ' + (pain ? 'faint ache' : 'barely') + '</span><span>10 ' + (pain ? 'worst pain' : 'unbearable') + '</span></div>';
    if (pain) {
      h += '<div class="lbl">How long do you expect it to last? <span style="text-transform:none;letter-spacing:0">(optional)</span></div><div class="chips">' +
        C.DURATION_KEYS.map(function (k) {
          return '<button class="chip sm ' + (d.duration === k ? 'on' : '') + '" data-act="dur" data-v="' + k + '">' + C.DURATION_LABELS[k] + '</button>';
        }).join('') + '</div>' +
        '<button class="savebtn" data-act="savedraft" ' + (q && d.intensity ? '' : 'disabled') + '>Save</button>';
    }
    return h + footer();
  }
  function footer() {
    var t = S.toast ? '<div class="toast"><span>Saved: ' + esc(S.toast.issue) + ' · ' + S.toast.intensity + '</span><button data-act="undo">Undo</button></div>' : '';
    var f = S.loggedCount ? '<div class="foot"><span>' + S.loggedCount + ' logged</span><button data-act="done">Done</button></div>' : '';
    return t + f;
  }

  // ---------- voice view ----------
  function voiceView() {
    var v = S.voice, pain = S.mode === 'pain', p = v.parsed;
    var done = p && p.complete;
    var h = '<div class="vh"><span>' + (done ? 'Got it' : 'Listening') + '</span><button class="iconbtn" data-act="voiceclose" aria-label="Close">✕</button></div>';
    h += '<div class="wave ' + (done ? 'still' : '') + '">' + [30, 55, 80, 45, 95, 60, 35, 70, 50, 85, 40, 65, 30].map(function (x, i) {
      return '<i style="animation-delay:' + (i * 0.08) + 's;height:' + Math.round(x * .5 + 8) + 'px"></i>';
    }).join('') + '</div>';
    h += '<div class="card tr">' + (v.text ? transcriptHtml(v.text, p) : '<span class="ph">' + (pain ? 'Try: “my back hurts, about a six, for a few days”' : 'Try: “work stress, a seven”') + '</span>') + '</div>';
    var row = function (ok, q, val, isNew) {
      return '<div class="cl ' + (ok ? 'done' : '') + '"><span class="dot">' + (ok ? '✓' : '') + '</span><span class="q">' + q + '</span>' +
        (ok ? '<span class="v">' + esc(val) + (isNew ? '<span class="new">NEW</span>' : '') + '</span>' : '') + '</div>';
    };
    h += '<div class="card" style="margin-top:14px">';
    h += row(p && p.issue, pain ? 'Where does it hurt' : "What’s bugging you", p && p.issue ? p.issue.name : '', p && p.issue && p.issue.isNew);
    h += row(p && p.intensity, pain ? 'How bad (1–10)' : 'How much (1–10)', p && p.intensity ? String(p.intensity.value) : '');
    if (pain) h += row(p && p.duration, 'How long (optional)', p && p.duration ? C.DURATION_LABELS[p.duration.key] : '');
    h += '</div>';
    if (v.error) h += '<div class="err">' + esc(v.error) + '</div>';
    if (v.countdown != null) h += '<div class="autosave"><span>Saving in ' + v.countdown + 's… then a fresh entry</span><button data-act="voiceedit">Edit</button></div>';
    else h += '<button class="stop" data-act="voicestop">Tap to stop</button>';
    return h;
  }
  function transcriptHtml(text, p) {
    if (!p) return esc(text);
    var out = '', pos = 0;
    p.spans.forEach(function (s) {
      if (s.start < pos) return;
      out += esc(text.slice(pos, s.start)) + '<mark>' + esc(text.slice(s.start, s.end)) + '</mark>';
      pos = s.end;
    });
    return out + esc(text.slice(pos));
  }

  // ---------- re-rate view ----------
  function rerateView() {
    var e = S.queue[S.queuePos], pain = e.kind === 'pain';
    document.documentElement.dataset.mode = e.kind;
    var h = '<div class="rrh"><span>Quick check-in</span><small>' + (S.queuePos + 1) + ' of ' + S.queue.length + '</small></div>' +
      '<div class="legend">Pain entries return until you mark them gone. Complaints are asked once.</div>';
    h += '<div class="rrc"><span class="tag">' + (pain ? 'PAIN' : 'COMPLAINT') + '</span>' +
      '<div class="when">' + whenLabel(e.createdAt) + ' · ' + (pain ? 'hurt ' : 'bothered you ') + e.intensity + '</div><h2>' + esc(e.issue) + '</h2>';
    var hint = C.rerateHint(e, S.entries);
    if (hint) h += '<div class="hint">' + esc(hint) + '</div>';
    h += '<div class="q">' + (pain ? 'HOW BAD IS IT NOW?' : 'HOW MUCH DOES IT BOTHER YOU NOW?') + '</div><div class="grid">';
    for (var i = 1; i <= 10; i++) h += '<button class="n" data-act="rrnum" data-v="' + i + '">' + i + '</button>';
    h += '</div><div class="acts"><button class="gone" data-act="rrgone">Gone</button><button data-act="rrskip">Skip</button></div></div>' +
      '<div class="swipe">Swipe the card away to skip</div>';
    return h;
  }

  // ---------- review view ----------
  function trackHtml(t, cls, title, now_) {
    var h = '<div class="card trk ' + cls + '"><h3>' + title + '</h3>';
    if (!t.count) return h + '<div class="empty">Nothing logged this week.</div></div>';
    h += '<div class="bignum">' + avgFmt(t.logged) + (t.rerated != null ? ' → ' + avgFmt(t.rerated) : '') +
      '<small>' + (t.rerated != null ? 'at log → re-rated' : 'average at log') + ' · ' + t.count + ' logged</small></div>';
    h += chart(t.trend);
    var max = Math.max.apply(null, t.top.map(function (x) { return x.count; }));
    h += '<div class="lbl" style="margin-top:6px">' + (cls === 'pain' ? 'By location' : 'Top complaints') + '</div><div class="bars">' +
      t.top.map(function (x) { return '<div class="row"><span>' + esc(x.name) + '</span><span class="bar"><i style="width:' + Math.round(x.count / max * 100) + '%"></i></span><em>' + x.count + '</em></div>'; }).join('') + '</div>';
    h += '<div class="lbl">Time of day</div><div class="heat"><div></div>' + ['M', 'T', 'W', 'T', 'F', 'S', 'S'].map(function (d) { return '<div style="text-align:center">' + d + '</div>'; }).join('');
    t.heat.rows.forEach(function (r, ri) {
      h += '<div>' + r + '</div>';
      t.heat.cells[ri].forEach(function (c) { h += '<div class="c" style="--a:' + (t.heat.max ? (c / t.heat.max).toFixed(2) : 0) + '"></div>'; });
    });
    return h + '</div></div>';
  }
  function chart(trend) {
    var W = 300, H = 90, pad = 10;
    function pt(i, v) { return [pad + i * (W - 2 * pad) / (trend.length - 1), H - pad - (v - 1) / 9 * (H - 2 * pad)]; }
    function line(key, dash, color) {
      var pts = trend.map(function (t, i) { return t[key] == null ? null : pt(i, t[key]); }).filter(Boolean);
      if (pts.length < 1) return '';
      return '<polyline fill="none" stroke="' + color + '" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" ' + (dash ? 'stroke-dasharray="6 5"' : '') +
        ' points="' + pts.map(function (p) { return p.join(','); }).join(' ') + '"/>' + pts.map(function (p) { return '<circle cx="' + p[0] + '" cy="' + p[1] + '" r="4" fill="' + color + '"/>'; }).join('');
    }
    return '<svg viewBox="0 0 ' + W + ' ' + H + '" style="width:100%;margin:10px 0 2px">' + line('logged', false, 'var(--mc)') + line('rerated', true, 'var(--ok)') + '</svg>' +
      '<div class="ends" style="margin:0 0 8px"><span>' + trend.map(function (t) { return t.label; }).join('  ') + '</span><span>solid: at log · dashed: re-rated</span></div>';
  }
  function reviewView() {
    var w = C.weekReview(S.entries, now()), d = w.durations, tg = w.together;
    var h = '<div class="top"><button class="iconbtn" data-act="back" aria-label="Back">←</button></div><div class="rv"><h1>Your week</h1><div class="sub">' + w.label + '</div>';
    h += trackHtml(w.complaint, 'comp', 'Dissatisfaction', now());
    h += trackHtml(w.pain, 'pain', 'Pain', now());
    if (d.rows.length) {
      h += '<div class="card" style="margin-top:16px"><h3 style="margin:0 0 6px;font-size:13px;letter-spacing:.09em;text-transform:uppercase;color:var(--pain)">Pain: expected vs actual</h3>';
      if (d.judged) h += '<div class="bignum" style="font-size:22px">Lasted shorter than expected ' + d.shorter + ' of ' + d.judged + '</div>';
      h += d.rows.map(function (r) {
        var exp = r.expected ? C.DURATION_LABELS[r.expected] : 'no guess';
        var act = r.resolved ? r.actualLabel : 'still going, ' + r.stillLabel;
        return '<div class="dur"><span>' + esc(r.issue) + ' <small style="color:var(--gl-text-dim)">expected ' + exp + '</small></span><span class="' + (r.verdict === 'shorter' ? 'ok' : '') + '">' + act + '</span></div>';
      }).join('') + '</div>';
    }
    if (tg.correlation) {
      var c = tg.correlation;
      h += '<div class="card together" style="margin-top:16px"><h3 style="margin:0;font-size:13px;letter-spacing:.09em;text-transform:uppercase;color:var(--gl-text-dim)">Together</h3><p>On ' + c.highDays + ' high-pain day' + (c.highDays > 1 ? 's' : '') +
        ' complaints averaged <b>' + avgFmt(c.highAvg) + '</b>; on ' + c.lowDays + ' lower-pain day' + (c.lowDays > 1 ? 's' : '') + ' they averaged <b>' + avgFmt(c.lowAvg) + '</b>.</p></div>';
    }
    if (w.retired.length) {
      h += '<div class="retired"><h3>🎉 Retired</h3>' + w.retired.map(function (r) {
        return '<div class="it">' + esc(r.name) + ' <small style="color:var(--gl-text-dim)">not seen in ' + r.days + ' days</small></div>';
      }).join('') + '</div>';
    }
    return h + '</div>';
  }

  // ---------- render ----------
  function render() {
    var keep = document.activeElement && document.activeElement.id === 'issue' ? document.activeElement.selectionStart : null;
    var body = S.view === 'voice' ? voiceView() : S.view === 'rerate' ? rerateView() : S.view === 'review' ? reviewView() : logView();
    if (S.view !== 'rerate') document.documentElement.dataset.mode = S.mode;
    app.innerHTML = (S.banner ? '<div class="banner">' + esc(S.banner) + '</div>' : '') + body;
    var input = document.getElementById('issue');
    if (input && S.typing) { input.focus(); if (keep != null) input.setSelectionRange(keep, keep); }
  }

  // ---------- actions ----------
  function freshDraft() { S.draft = { issue: '', intensity: null, duration: null }; S.typing = false; }
  function commit(f) {
    var e = C.makeEntry(f, now());
    save(e);
    S.toast = e; S.loggedCount++;
    freshDraft();
    return e;
  }
  function tryCompleteComplaint() {
    if (S.mode === 'complaint' && S.draft.issue.trim() && S.draft.intensity) {
      commit({ kind: 'complaint', issue: S.draft.issue, intensity: S.draft.intensity, source: 'tap' });
      S.typing = true; // fresh, focused field for the chained entry
    }
  }
  var actions = {
    mode: function (v) { setMode(v); freshDraft(); S.toast = null; S.typing = false; },
    pick: function (v) { S.draft.issue = v; S.typing = false; S.toast = null; document.activeElement && document.activeElement.blur(); tryCompleteComplaint(); },
    clear: function () { S.draft.issue = ''; S.typing = true; },
    num: function (v) { S.draft.intensity = +v; S.toast = null; tryCompleteComplaint(); },
    dur: function (v) { S.draft.duration = S.draft.duration === v ? null : v; },
    savedraft: function () {
      commit({ kind: 'pain', issue: S.draft.issue, intensity: S.draft.intensity, expectedDuration: S.draft.duration, source: 'tap' });
      S.typing = true;
    },
    undo: function () { var id = S.toast.id; remove(id); S.loggedCount--; S.toast = null; },
    done: function () { S.toast = null; S.loggedCount = 0; freshDraft(); },
    review: function () { S.view = 'review'; },
    back: function () { S.view = 'log'; },
    voice: function () { startVoice(); },
    voicestop: function () { stopVoice(true); },
    voiceclose: function () { stopVoice(false); },
    voiceedit: function () { stopVoice(true); },
    rrnum: function (v) { rerate({ intensity: +v }); },
    rrgone: function () { rerate({ gone: true }); },
    rrskip: function () { nextRerate(); }
  };
  app.addEventListener('click', function (ev) {
    var el = ev.target.closest('[data-act]');
    if (!el) return;
    actions[el.dataset.act](el.dataset.v);
    render();
  });
  app.addEventListener('input', function (ev) {
    if (ev.target.id !== 'issue') return;
    S.draft.issue = ev.target.value; S.typing = true; S.toast = null;
    render();
  });
  app.addEventListener('focusin', function (ev) { if (ev.target.id === 'issue' && !S.typing) { S.typing = true; render(); } });
  app.addEventListener('keydown', function (ev) {
    if (ev.target.id === 'issue' && ev.key === 'Enter' && S.draft.issue.trim()) { ev.preventDefault(); actions.pick(C.canon(S.draft.issue)); render(); }
  });

  // ---------- re-rate flow ----------
  function startRerate() {
    var q = C.rerateQueue(S.entries, now());
    if (!q.length) return;
    S.queue = q; S.queuePos = 0; S.view = 'rerate';
  }
  function rerate(r) {
    save(C.applyRerate(S.queue[S.queuePos], r, now()));
    nextRerate();
  }
  function nextRerate() {
    S.queuePos++;
    if (S.queuePos >= S.queue.length) { S.view = 'log'; setMode(S.mode); }
  }

  // ---------- voice flow ----------
  function startVoice() {
    S.view = 'voice'; S.voice = { text: '', parsed: null, error: null, countdown: null, active: true };
    S.toast = null;
    if (S.persist) bridge('startVoice', { onDevice: true }).catch(function (e) { S.voice.error = 'Could not start listening: ' + e.message; render(); });
  }
  function stopVoice(keepDraft) {
    clearInterval(countdownTimer); countdownTimer = null;
    var p = S.voice.parsed;
    if (S.persist && S.voice.active) bridge('stopVoice').catch(function (e) { console.error('[gripes] stopVoice', e); });
    S.voice.active = false; S.view = 'log';
    if (keepDraft && p) {
      if (p.issue) S.draft.issue = p.issue.name;
      if (p.intensity) S.draft.intensity = p.intensity.value;
      if (p.duration) S.draft.duration = p.duration.key;
    }
    render();
  }
  function onVoiceText(text) {
    S.voice.text = text;
    S.voice.parsed = C.parseTranscript(text, { mode: S.mode, entries: S.entries });
    if (S.voice.parsed.complete) {
      if (S.voice.countdown == null) {
        S.voice.countdown = 2;
        countdownTimer = setInterval(function () {
          S.voice.countdown--;
          if (S.voice.countdown <= 0) { finishVoice(); } else render();
        }, 1000);
      }
    } else if (S.voice.countdown != null) {
      // More words arrived and the capture is no longer complete: cancel the auto-save.
      clearInterval(countdownTimer); countdownTimer = null; S.voice.countdown = null;
    }
    render();
  }
  function finishVoice() {
    clearInterval(countdownTimer); countdownTimer = null;
    var p = S.voice.parsed;
    if (S.persist && S.voice.active) bridge('stopVoice').catch(function (e) { console.error('[gripes] stopVoice', e); });
    S.voice.active = false;
    commit({ kind: S.mode, issue: p.issue.name, intensity: p.intensity.value,
             expectedDuration: p.duration ? p.duration.key : null, note: S.voice.text, source: 'voice' });
    S.view = 'log'; S.typing = true;
    render();
  }
  // Native -> page: {type:'partial'|'final'|'error', text, message}
  window.gripesVoice = function (m) {
    if (S.view !== 'voice') return;
    if (m.type === 'error') { S.voice.error = m.message; render(); return; }
    onVoiceText(m.text);
  };
  window.gripesOpenLog = function () { // gripes://log
    S.view = 'log'; freshDraft(); setMode(S.mode); render();
  };
  window.gripesEntriesChanged = function () { load().then(render).catch(function (e) { fail('Could not reload entries', e); }); };

  // ---------- DEBUG screenshot scenarios (sim-test only; never persist) ----------
  function demo() {
    var D = 86400000, H = 3600000, t = now(), out = [];
    function add(kind, issue, inten, ago, extra) {
      var at = new Date(t - ago).toISOString();
      out.push(Object.assign({ id: C.uuid(), kind: kind, issue: issue, intensity: inten, expectedDuration: null, note: null, source: 'tap',
        createdAt: at, rerates: [], goneAt: null, updatedAt: at }, extra || {}));
    }
    var rr = function (v) { return [{ at: new Date(t - H).toISOString(), intensity: v, gone: false }]; };
    for (var i = 0; i < 6; i++) add('complaint', 'Work stress', 7 - (i % 3), (i + 1) * D + 3 * H, { rerates: rr(3 + (i % 2)) });
    for (i = 0; i < 4; i++) add('complaint', 'Weather', 4 + (i % 2), (i + 1) * D + 5 * H, { rerates: rr(2) });
    for (i = 0; i < 3; i++) add('complaint', 'Waking up early', 5, (i + 2) * D + 8 * H);
    add('complaint', 'Slow wifi', 4, 5 * D); add('complaint', 'Slow wifi', 5, 6 * D);
    add('complaint', 'Landlord', 6, 3 * H); add('complaint', 'Old noisy fridge', 5, 17 * D); add('complaint', 'Old noisy fridge', 6, 18 * D); add('complaint', 'Old noisy fridge', 5, 19 * D);
    add('pain', 'Spine', 6, 3 * H, { expectedDuration: 'rest_of_day' });
    add('pain', 'Spine', 7, 2 * D, { expectedDuration: 'rest_of_day', goneAt: new Date(t - 2 * D + 6 * H).toISOString() });
    add('pain', 'Spine', 5, 4 * D, { expectedDuration: 'few_days', goneAt: new Date(t - 4 * D + 20 * H).toISOString() });
    add('pain', 'Rhomboid', 6, 3 * D, { expectedDuration: 'few_hours', goneAt: new Date(t - 3 * D + 9 * H).toISOString() });
    add('pain', 'Jaw', 4, 1 * D, { expectedDuration: 'under_1h', goneAt: new Date(t - D + 2 * H).toISOString() });
    for (i = 1; i <= 3; i++) { add('complaint', 'Work stress', 8 - i * 0.0 - 0, (7 * i + 2) * D, { rerates: rr(6 - i) }); add('complaint', 'Weather', 7, (7 * i + 3) * D, { rerates: rr(5) }); add('pain', 'Spine', 8 - i, (7 * i + 2) * D + H, { expectedDuration: 'few_days', goneAt: new Date(t - (7 * i + 2) * D + 3 * D).toISOString() }); }
    add('pain', 'Hand', 5, 5 * D); add('pain', 'Foot', 3, 6 * D);
    return out;
  }
  window.__gripesShot = function (name) {
    S.persist = false; S.entries = demo(); S.banner = null; S.toast = null; S.loggedCount = 0; freshDraft(); S.view = 'log';
    if (name === 'log-pain') { setMode('pain'); S.draft = { issue: 'Spine', intensity: 5, duration: null }; }
    else if (name === 'autocomplete') { setMode('complaint'); S.draft.issue = 'w'; S.typing = true; }
    else if (name === 'next') { setMode('pain'); S.toast = { id: 'x', issue: 'Spine', intensity: 5 }; S.loggedCount = 3; S.typing = false; }
    else if (name === 'voice') { setMode('pain'); startVoice(); S.persist = false; onVoiceText('my back hurts'); }
    else if (name === 'rerate') { S.queue = C.rerateQueue(S.entries, now()); S.queuePos = 0; S.view = 'rerate'; }
    else if (name === 'review' || name === 'review-pain' || name === 'review-bottom') {
      S.view = 'review';
      render();
      // The review is taller than the screen: the extra scenarios scroll to the lower sections.
      window.scrollTo(0, name === 'review-pain' ? 640 : name === 'review-bottom' ? 99999 : 0);
      return;
    }
    else throw new Error('unknown shot ' + name);
    render();
  };

  // ---------- boot ----------
  setMode('pain');
  render();
  load().then(function () { if (!S.persist) return; /* a DEBUG shot scenario took over */ startRerate(); render(); }).catch(function (e) { fail('Could not load entries', e); });
})();

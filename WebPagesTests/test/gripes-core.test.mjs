// Pure-logic tests for GripesApp/web/gripes-core.js: voice parser, autocomplete
// ranking, re-rate queue, duration + review math. No DOM, no bridge.
import test from 'node:test';
import assert from 'node:assert/strict';
import C from './gripes-load.mjs';

const H = 3600000, D = 86400000;
const NOW = new Date('2026-10-14T15:00:00').getTime();
let n = 0;
function ent(kind, issue, intensity, agoMs, extra = {}) {
  const at = new Date(NOW - agoMs).toISOString();
  return Object.assign({ id: 'e' + (++n), kind, issue, intensity, expectedDuration: null, note: null, source: 'tap',
    createdAt: at, rerates: [], goneAt: null, updatedAt: at }, extra);
}

// ---------- parser ----------
const pain = (t, entries = []) => C.parseTranscript(t, { mode: 'pain', entries });
const comp = (t, entries = []) => C.parseTranscript(t, { mode: 'complaint', entries });

test('parser: number words and digits 1-10', () => {
  assert.equal(pain('my back is a six').intensity.value, 6);
  assert.equal(pain('my back is 9').intensity.value, 9);
  assert.equal(pain('my jaw is a ten').intensity.value, 10);
});
test('parser: numbers followed by units or after "at" are not the rating', () => {
  const r = pain('ten minutes at 3 pm my jaw is a 5');
  assert.equal(r.intensity.value, 5);
});
test('parser: "x out of ten" takes x', () => {
  assert.equal(pain('shoulder blade seven out of ten').intensity.value, 7);
});
test('parser: location synonyms map (back -> Spine, shoulder blade -> Rhomboid)', () => {
  assert.equal(pain('my back hurts a six').issue.name, 'Spine');
  assert.equal(pain('shoulder blade pain five').issue.name, 'Rhomboid');
  assert.equal(pain('my jaw is tight, four').issue.name, 'Jaw');
});
test('parser: side prefix is kept for non-central locations only', () => {
  assert.equal(pain('right hand aching three').issue.name, 'Right hand');
  assert.equal(pain('left back hurts three').issue.name, 'Spine');
});
test('parser: duration phrases', () => {
  assert.equal(pain('back six for a few days').duration.key, 'few_days');
  assert.equal(pain('back six for the rest of the day').duration.key, 'rest_of_day');
  assert.equal(pain('back six a couple of hours').duration.key, 'few_hours');
  assert.equal(pain('back six less than an hour').duration.key, 'under_1h');
  assert.equal(pain('back six about a week').duration.key, 'week_plus');
  assert.equal(pain('back six').duration, null);
});
test('parser: pain complete needs location + intensity, duration optional', () => {
  assert.equal(pain('back six').complete, true);
  assert.equal(pain('back hurts').complete, false);
  assert.equal(pain('it is a six').complete, false);
});
test('parser: complaint issue is remaining phrase, NEW when unseen', () => {
  const r = comp("the landlord still hasn't fixed the heater and it's a six");
  assert.equal(r.intensity.value, 6);
  assert.equal(r.issue.isNew, true);
  assert.match(r.issue.name, /heater/i);
  assert.equal(r.complete, true);
});
test('parser: complaint fuzzy-matches an existing issue', () => {
  const entries = [ent('complaint', 'Work stress', 6, D)];
  const r = comp('work stress is bugging me a 7', entries);
  assert.equal(r.issue.name, 'Work stress');
  assert.equal(r.issue.isNew, false);
  assert.equal(r.intensity.value, 7);
});
test('parser: spans point at the captured words', () => {
  const t = 'my back hurts about a six for a few days';
  const r = pain(t);
  const by = Object.fromEntries(r.spans.map(s => [s.kind, t.slice(s.start, s.end)]));
  assert.equal(by.issue, 'back');
  assert.match(by.intensity, /six$/);
  assert.equal(by.duration, 'a few days');
});

// ---------- autocomplete ----------
test('suggest: starts-with beats contains, then frequency, then recency', () => {
  const entries = [
    ent('complaint', 'Slow wifi', 5, 3 * D), ent('complaint', 'Slow wifi', 5, 2 * D), ent('complaint', 'Slow wifi', 4, 1 * D),
    ent('complaint', 'Work stress', 6, 5 * D),
    ent('complaint', 'Wasted time', 3, 1 * H), ent('complaint', 'Wasted time', 3, 2 * H),
    ent('complaint', 'Noisy neighbours who whine', 3, 1 * H)
  ];
  const names = C.suggest('w', entries, 'complaint', NOW).map(s => s.name);
  // word-start tier ("who whine"-style / "wifi" in "Slow wifi") comes after the three whole-string starts.
  assert.deepEqual(names.slice(0, 2), ['Wasted time', 'Work stress']);
  assert.ok(names.indexOf('Slow wifi') > 1);
});
test('suggest: empty query yields nothing; kinds are separate pools', () => {
  const entries = [ent('pain', 'Spine', 5, D), ent('complaint', 'Spiders', 3, D)];
  assert.deepEqual(C.suggest('', entries, 'pain', NOW), []);
  assert.deepEqual(C.suggest('sp', entries, 'complaint', NOW).map(s => s.name), ['Spiders']);
});
test('suggest: meta shows count and last seen', () => {
  const entries = [ent('complaint', 'Work stress', 6, 1 * H), ent('complaint', 'Work stress', 6, 2 * H)];
  assert.equal(C.suggest('w', entries, 'complaint', NOW)[0].meta, '2x · today');
});
test('topChips: most frequent first, capped, pain pads with default locations', () => {
  const entries = [];
  for (let i = 0; i < 9; i++) entries.push(ent('complaint', 'Issue ' + i, 3, D + i * H));
  entries.push(ent('complaint', 'Issue 3', 3, 5 * H));
  const t = C.topChips(entries, 'complaint', 6);
  assert.equal(t.chips.length, 6);
  assert.equal(t.chips[0], 'Issue 3');
  assert.equal(t.more, 3);
  assert.deepEqual(C.topChips([], 'pain', 6).chips.slice(0, 5), ['Spine', 'Rhomboid', 'Jaw', 'Hand', 'Foot']);
});

// ---------- re-rate queue ----------
test('rerateQueue: complaints need 2h+ and no prior rerate; pain every open until gone', () => {
  const young = ent('complaint', 'A', 5, 1 * H);
  const old = ent('complaint', 'B', 5, 3 * H);
  const done = ent('complaint', 'C', 5, 3 * H, { rerates: [{ at: 'x', intensity: 2, gone: false }] });
  const painRated = ent('pain', 'Spine', 6, 2 * D, { rerates: [{ at: 'x', intensity: 4, gone: false }] });
  const painGone = ent('pain', 'Jaw', 6, 2 * D, { goneAt: new Date(NOW - D).toISOString() });
  const q = C.rerateQueue([young, old, done, painRated, painGone], NOW).map(e => e.issue);
  assert.deepEqual(q, ['Spine', 'B']);
});
test('applyRerate: number records intensity, gone sets goneAt; input not mutated', () => {
  const e = ent('pain', 'Spine', 6, 2 * D);
  const a = C.applyRerate(e, { intensity: 3 }, NOW);
  assert.equal(a.rerates[0].intensity, 3);
  assert.equal(a.goneAt, null);
  assert.equal(e.rerates.length, 0);
  const g = C.applyRerate(e, { gone: true }, NOW);
  assert.equal(g.goneAt, new Date(NOW).toISOString());
  assert.equal(g.rerates[0].gone, true);
});

// ---------- durations ----------
test('painDuration: shorter / as expected / longer than expected', () => {
  const mk = (exp, hours) => ent('pain', 'Spine', 5, 10 * D, { expectedDuration: exp,
    goneAt: new Date(NOW - 10 * D + hours * H).toISOString() });
  assert.equal(C.painDuration(mk('rest_of_day', 2), NOW).verdict, 'shorter');
  assert.equal(C.painDuration(mk('few_hours', 3), NOW).verdict, 'asExpected');
  assert.equal(C.painDuration(mk('under_1h', 30 * 1), NOW).verdict, 'longer');
  assert.equal(C.painDuration(ent('pain', 'Jaw', 5, D, { goneAt: new Date(NOW).toISOString() }), NOW).verdict, 'none');
});
test('painDuration: unresolved reports still-going lower bound', () => {
  const d = C.painDuration(ent('pain', 'Spine', 5, 26 * H, { expectedDuration: 'few_hours' }), NOW);
  assert.equal(d.resolved, false);
  assert.equal(d.verdict, 'pending');
  assert.equal(d.stillLabel, '≥1.1 d');
});
test('durationReport: counts "shorter than expected N of M"', () => {
  const g = (exp, h) => ent('pain', 'Spine', 5, 3 * D, { expectedDuration: exp, goneAt: new Date(NOW - 3 * D + h * H).toISOString() });
  const entries = [g('rest_of_day', 1), g('rest_of_day', 2), g('under_1h', 5), ent('pain', 'Jaw', 4, D, { expectedDuration: 'few_days' })];
  const r = C.durationReport(entries, NOW);
  assert.equal(r.judged, 3);
  assert.equal(r.shorter, 2);
  assert.equal(r.longer, 1);
  assert.equal(r.stillGoing, 1);
});

// ---------- review ----------
test('weekReview: logged vs re-rated averages and top complaints', () => {
  const entries = [
    ent('complaint', 'Work stress', 8, 1 * D, { rerates: [{ at: 'x', intensity: 4, gone: false }] }),
    ent('complaint', 'Work stress', 6, 2 * D, { rerates: [{ at: 'x', intensity: 2, gone: false }] }),
    ent('complaint', 'Slow wifi', 4, 2 * D)
  ];
  const w = C.weekReview(entries, NOW);
  assert.equal(w.complaint.count, 3);
  assert.equal(w.complaint.logged, 6);
  assert.equal(w.complaint.rerated, 3);
  assert.equal(w.complaint.top[0].name, 'Work stress');
  assert.equal(w.complaint.top[0].count, 2);
  assert.equal(w.pain.count, 0);
});
test('heatmap: Monday morning entry lands in row Morning, column 0', () => {
  const mon = new Date('2026-10-12T08:30:00').toISOString();
  const h = C.heatmap([{ createdAt: mon }]);
  assert.equal(h.cells[0][0], 1);
  assert.equal(h.max, 1);
});
test('together: compares complaint avg on high-pain vs low-pain days', () => {
  const day = (back, kind, v) => ent(kind, kind === 'pain' ? 'Spine' : 'Stress', v, back * D + 2 * H);
  const entries = [day(1, 'pain', 8), day(1, 'complaint', 9), day(2, 'pain', 2), day(2, 'complaint', 3)];
  const t = C.together(entries, NOW).correlation;
  assert.equal(t.highAvg, 9);
  assert.equal(t.lowAvg, 3);
  assert.equal(t.delta, 6);
});
test('retired: frequent issue unseen 14+ days is celebrated, recent or rare ones are not', () => {
  const entries = [
    ent('complaint', 'Old gripe', 5, 15 * D), ent('complaint', 'Old gripe', 5, 16 * D), ent('complaint', 'Old gripe', 5, 17 * D),
    ent('complaint', 'Rare', 5, 15 * D),
    ent('complaint', 'Current', 5, 1 * D), ent('complaint', 'Current', 5, 20 * D), ent('complaint', 'Current', 5, 21 * D)
  ];
  assert.deepEqual(C.retired(entries, NOW).map(r => r.name), ['Old gripe']);
});

// ---------- tombstones (Undo) ----------
test('tombstone: keeps the full entry, sets deleted, bumps updatedAt strictly past the stored copy', () => {
  const e = ent('pain', 'Spine', 5, 0, { updatedAt: new Date(NOW + 5000).toISOString() });
  const t = C.tombstone(e, NOW); // "now" is BEFORE the stored updatedAt: must still be newer
  assert.equal(t.deleted, true);
  assert.equal(t.id, e.id);
  assert.equal(t.issue, 'Spine');
  assert.ok(new Date(t.updatedAt) > new Date(e.updatedAt));
  assert.equal(e.deleted, undefined, 'original must not be mutated');
});
test('tombstone: hidden from autocomplete, chips and voice issue matching', () => {
  const dead = C.tombstone(ent('complaint', 'Zebra noise', 6, H), NOW);
  assert.deepEqual(C.suggest('zeb', [dead], 'complaint', NOW, 4), []);
  assert.ok(!C.topChips([dead], 'complaint', 6).chips.includes('Zebra noise'));
  assert.equal(comp('zebra noise six', [dead]).issue.isNew, true);
  assert.equal(C.issueStats([dead], 'complaint').length, 0);
});
test('tombstone: hidden from the re-rate queue and its hint', () => {
  const dead = C.tombstone(ent('pain', 'Spine', 6, 3 * H), NOW);
  const alive = ent('complaint', 'Stress', 5, 3 * H);
  assert.deepEqual(C.rerateQueue([dead, alive], NOW).map(e => e.id), [alive.id]);
  const done = ent('pain', 'Jaw', 4, 5 * D, { rerates: [{ at: 'x', intensity: 2, gone: false }] });
  const cur = ent('pain', 'Jaw', 6, 3 * H);
  assert.equal(C.rerateHint(cur, [C.tombstone(done, NOW)]), null);
});
test('tombstone: hidden from weekly review counts, durations, together and retired', () => {
  const dead = [ent('complaint', 'Stress', 9, 1 * D), ent('pain', 'Spine', 9, 1 * D)].map(e => C.tombstone(e, NOW));
  const w = C.weekReview(dead, NOW);
  assert.equal(w.complaint.count, 0);
  assert.equal(w.pain.count, 0);
  assert.equal(w.durations.rows ? w.durations.rows.length : w.durations.length, 0);
  const old = [15, 16, 17].map(d => C.tombstone(ent('complaint', 'Old gripe', 5, d * D), NOW));
  assert.deepEqual(C.retired(old, NOW), []);
});
test('tombstone: live entries are unaffected next to tombstones', () => {
  const dead = C.tombstone(ent('complaint', 'Stress', 9, 1 * D), NOW);
  const keep = ent('complaint', 'Stress', 3, 1 * D);
  assert.equal(C.weekReview([dead, keep], NOW).complaint.count, 1);
  assert.deepEqual(C.live([dead, keep]).map(e => e.id), [keep.id]);
});

// ---------- slider + return key ----------
test('scale: taps map to the nearest rating, endpoints and overshoot clamp', () => {
  // track at x=100..400 (width 300): numerals sit every 300/9 = 33.33px
  assert.equal(C.scaleValue(100, 100, 300), 1);
  assert.equal(C.scaleValue(400, 100, 300), 10);
  assert.equal(C.scaleValue(250, 100, 300), 6);   // exact middle is 5.5, rounds up to 6
  assert.equal(C.scaleValue(100 + 33.33 * 4, 100, 300), 5);
  assert.equal(C.scaleValue(-50, 100, 300), 1);
  assert.equal(C.scaleValue(900, 100, 300), 10);
});
test('scale: snap boundary sits midway between two ratings', () => {
  const w = 270; // 30px per step
  assert.equal(C.scaleValue(14, 0, w), 1);   // just before the 1/2 midpoint (15)
  assert.equal(C.scaleValue(16, 0, w), 2);   // just after
  assert.equal(C.scaleValue(44, 0, w), 2);
  assert.equal(C.scaleValue(46, 0, w), 3);
});
test('scale: thumb percent is 0 at 1, 100 at 10, none chosen is 0', () => {
  assert.equal(C.scalePct(1), 0);
  assert.equal(C.scalePct(10), 100);
  assert.ok(Math.abs(C.scalePct(5) - 44.4444) < 0.001);
  assert.equal(C.scalePct(null), 0);
});
test('return key: complete draft saves, issue-only commits text, empty does nothing', () => {
  assert.equal(C.enterAction('Spine', 5), 'save');
  assert.equal(C.enterAction('Spine', null), 'pick');
  assert.equal(C.enterAction('  ', 5), 'none');
  assert.equal(C.enterAction('', null), 'none');
});

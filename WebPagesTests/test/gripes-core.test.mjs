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

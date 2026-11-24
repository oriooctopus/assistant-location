// Insights generative-UI blocks (cycle-blocks.js): schema validation, the error chip, dataset fill (numbers come only from the datasets),
// streaming skeleton, checklist / technique state in the markup.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const file = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/cycle-blocks.js');
vm.runInThisContext(fs.readFileSync(file, 'utf8'), { filename: file });
const B = globalThis.CycleBlocks;

const DS = {
  fights_by_month: { id: 'fights_by_month', title: 'Fights per month', shape: 'series', unit: 'fights', points: [{ x: '2026-08', label: "Aug '26", y: 3 }, { x: '2026-09', label: "Sep '26", y: 7 }, { x: '2026-10', label: "Oct '26", y: 0 }] },
  fights_by_day: { id: 'fights_by_day', title: 'Fights by day', shape: 'days', unit: 'fights', days: [{ day: '2026-11-20', y: 2 }, { day: '2026-11-22', y: 1 }] },
  summary: { id: 'summary', shape: 'values', values: { fights_30d: { label: 'Last 30 days', y: 11, unit: 'fights' } } },
  recent_fights: { id: 'recent_fights', shape: 'rows', columns: ['Date', 'Summary'], rows: [['2026-11-22', 'party'], ['2026-11-20', 'money']] },
  fights_timeline: { id: 'fights_timeline', shape: 'events', events: [{ date: '2026-11-20', title: 'Fight', detail: 'money' }] },
};
const ctx = (o = {}) => ({ md: (t) => `<p>${t}</p>`, ds: DS, today: '2026-11-23', mi: 1, ver: 0, state: null, ...o });
const fence = (o) => '```ui\n' + (typeof o === 'string' ? o : JSON.stringify(o)) + '\n```';

test('split: markdown around blocks, block numbers count every fence, one-line form works, unclosed fence streams as pending', () => {
  const t = `before\n${fence({ type: 'chart', dataset: 'fights_by_month' })}\nmiddle\n\`\`\`ui {"type":"checklist","items":["a"]}\`\`\`\nafter`;
  const s = B.split(t, false);
  assert.deepEqual(s.map((x) => x.k), ['md', 'block', 'md', 'block', 'md']);
  assert.deepEqual(s.filter((x) => x.k === 'block').map((x) => x.bi), [0, 1]);
  assert.deepEqual(B.split('hi\n```ui\n{"type":"cha', true).map((x) => x.k), ['md', 'pending']);
  const fin = B.split('hi\n```ui\n{"type":"cha', false);
  assert.equal(fin[1].k, 'block'); assert.equal(fin[1].unclosed, true);
  assert.equal(B.split('```js\ncode\n```', false).length, 1, 'other fences are untouched markdown');
});

test('schema: valid blocks pass; bad JSON, unknown type, unknown key and wrong shapes are rejected with a reason', () => {
  const ok = [{ type: 'chart', dataset: 'x', kind: 'line' }, { type: 'stats', tiles: [{ dataset: 'summary', key: 'a' }] }, { type: 'checklist', items: ['a'] },
    { type: 'table', dataset: 'recent_fights', limit: 5 }, { type: 'table', columns: ['A'], rows: [['x']] }, { type: 'timeline', events: [{ date: 'd', title: 't' }] },
    { type: 'technique', id: 'a', name: 'n', how: 'h', status: 'mixed' }, { type: 'comparison', worked: ['a'], didnt: [] }];
  ok.forEach((b) => assert.equal(B.validate(JSON.stringify(b)).ok, true, JSON.stringify(b)));
  const bad = ['{nope', '[1]', '{"type":"pie"}', '{}', '{"type":"chart","dataset":"x","values":[1,2,3]}', '{"type":"chart","dataset":"x","kind":"pie"}', '{"type":"stats","tiles":[{"dataset":"s","key":"k","value":5}]}',
    '{"type":"checklist","items":[]}', '{"type":"checklist","items":[1]}', '{"type":"table","columns":["A","B"],"rows":[["x"]]}', '{"type":"technique","id":"a","name":"n","how":"h","status":"doesnt_work"}',
    '{"type":"comparison","worked":[],"didnt":[]}', '{"type":"table","dataset":"x","limit":99}'];
  bad.forEach((b) => { const v = B.validate(b); assert.equal(v.ok, false, b); assert.ok(v.error.length > 3); });
});

test('invalid block renders as a visible error chip with the escaped raw JSON, never silently', () => {
  const h = B.html(fence('{"type":"chart","dataset":"fights_by_month","values":[1,2,3],"x":"<b>"}'), ctx());
  assert.match(h, /class="bk bkerr"/); assert.match(h, /unknown key &quot;values&quot;/); assert.match(h, /&lt;b&gt;/); assert.doesNotMatch(h, /<svg/);
  assert.match(B.html(fence('{"type":"chart","dataset":"nope"}'), ctx()), /dataset &quot;nope&quot; is not available/);
  assert.match(B.html(fence('{"type":"chart","dataset":"summary"}'), ctx()), /bkerr/, 'wrong dataset shape');
  assert.match(B.html(fence('{"type":"stats","tiles":[{"dataset":"summary","key":"zzz"}]}'), ctx()), /has no key/);
  assert.match(B.html('x\n```ui\n{"type":"checklist"', ctx()), /fence never closed/);
});

test('dataset fill: chart bars, stat tiles, tables and timelines carry exactly the dataset numbers', () => {
  const m = B.fill({ type: 'chart', dataset: 'fights_by_month' }, DS);
  assert.deepEqual(m.points.map((p) => p.y), [3, 7, 0]); assert.equal(m.kind, 'bar');
  const h = B.html(fence({ type: 'chart', dataset: 'fights_by_month' }), ctx());
  assert.deepEqual([...h.matchAll(/class="bkbar[^"]*" data-v="(\d+)"/g)].map((x) => +x[1]), [3, 7, 0]);
  assert.match(h, /Oct &#39;26: 0 fights|Oct '26: 0 fights/, 'readout names the last point');
  const st = B.html(fence({ type: 'stats', tiles: [{ dataset: 'summary', key: 'fights_30d' }] }), ctx());
  assert.match(st, /data-v="11">11<\/b><span>Last 30 days/);
  const tb = B.html(fence({ type: 'table', dataset: 'recent_fights', limit: 1 }), ctx());
  assert.match(tb, /2026-11-22/); assert.doesNotMatch(tb, /2026-11-20/);
  assert.match(B.html(fence({ type: 'timeline', dataset: 'fights_timeline' }), ctx()), /2026-11-20<\/b> Fight<small>money/);
  const hm = B.html(fence({ type: 'chart', dataset: 'fights_by_day' }), ctx());
  assert.equal(hm.match(/data-day="2026-11-20" x="\d+" y="\d+" width="13" height="13" rx="2.5" data-a/)[0].length > 0, true);
  assert.match(hm, /data-v="2" data-day="2026-11-20"/); assert.match(hm, /data-v="1" data-day="2026-11-22"/);
});

test('loading: a dataset block shows a skeleton until datasets arrive, a failed load shows the error; an open fence is a skeleton while streaming', () => {
  assert.match(B.html(fence({ type: 'chart', dataset: 'fights_by_month' }), ctx({ ds: null })), /bksk/);
  assert.match(B.html(fence({ type: 'chart', dataset: 'fights_by_month' }), ctx({ ds: null, dsError: 'HTTP 502' })), /datasets unavailable: HTTP 502/);
  assert.match(B.html('text\n```ui\n{"type":"cha', ctx({ streaming: true })), /bksk/);
  assert.equal(B.needsDatasets(fence({ type: 'checklist', items: ['a'] })), false);
  assert.equal(B.needsDatasets(fence({ type: 'chart', dataset: 'a' })), true);
});

test('checklist and technique cards: saved state is read from the message (per version + block), buttons carry their action', () => {
  const cl = fence({ type: 'checklist', title: 'Tonight', items: ['a', 'b'] });
  const on = B.html(`${cl}`, ctx({ state: { '0:0:i1': true, '1:0:i0': true } }));
  assert.match(on, /aria-checked="false" data-a="bkchk:1:0:0"/); assert.match(on, /aria-checked="true" data-a="bkchk:1:0:1"/);
  const v1 = B.html(cl, ctx({ ver: 1, state: { '0:0:i1': true, '1:0:i0': true } }));
  assert.match(v1, /aria-checked="true" data-a="bkchk:1:0:0"/); assert.match(v1, /aria-checked="false" data-a="bkchk:1:0:1"/);
  const tc = fence({ type: 'technique', id: 'time-out', name: 'Time-out', how: 'Leave', status: 'untried' });
  assert.match(B.html(tc, ctx()), /s-untried/);
  const h = B.html(tc, ctx({ state: { '0:0:status': 'works' }, err: { '1:0': 'Not saved: insights failed: HTTP 404' } }));
  assert.match(h, /s-works/); assert.match(h, /bkbtn on" role="button" data-a="bktech:1:0:works"/); assert.match(h, /data-a="bktech:1:0:doesnt"/); assert.match(h, /HTTP 404/);
});

test('chart x labels: long category names are shortened and thinned so they never overlap', () => {
  const names = ['plans and timing', 'money', 'texting and phones', 'family and friends', 'intimacy', 'chores', 'time', 'sleep', 'work', 'trust'];
  const ds = { cat: { id: 'cat', title: 'Cats', shape: 'series', unit: 'fights', points: names.map((l, i) => ({ x: l, label: l, y: 10 - i })) } };
  const h = B.html(fence({ type: 'chart', dataset: 'cat', kind: 'bar' }), ctx({ ds }));
  const labels = [...h.matchAll(/<text[^>]*y="144"[^>]*>([^<]*)<\/text>/g)].map((m) => m[1]);
  assert.ok(labels.length >= 1 && labels.length <= 4, 'few labels: ' + labels.join('|'));
  assert.ok(labels.every((l) => l.length <= 11), 'shortened: ' + labels.join('|'));
  assert.equal(B.html(fence({ type: 'chart', dataset: 'fights_by_month' }), ctx()).match(/y="144"/g).length >= 2, true, 'short date labels keep their spread');
});

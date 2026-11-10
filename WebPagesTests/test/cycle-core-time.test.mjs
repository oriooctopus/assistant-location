// To-do time, pure logic: state, what a save writes (solo vs two-person), and when it notifies.
import test from 'node:test';
import assert from 'node:assert/strict';
import C from './cycle-load.mjs';

const at = (day, h = 12) => Date.parse(`${day}T${String(h).padStart(2, '0')}:00:00-04:00`);
const iso = (day, h) => new Date(at(day, h)).toISOString();
const ME = 'u-me', YOU = 'u-you';
const NOW = at('2026-10-20', 12);
const tt = (o) => ({ id: 't1', type: 'task', title: 'Book flight', due_date: null, done_at: null, deleted_at: null, owner_id: ME, created_by: ME, shared: false, time_at: null, time_by: null, time_ok_at: null, ...o });
const FUT = iso('2026-10-22', 19);

test('timeState: none / proposed by me / proposed by them / agreed; a row from before the columns reads as none', () => {
  assert.equal(C.timeState(tt({}), ME), 'none');
  const old = tt({}); delete old.time_at; delete old.time_by; delete old.time_ok_at;
  assert.equal(C.timeState(old, ME), 'none');
  assert.equal(C.timeState(tt({ time_at: FUT, time_by: ME }), ME), 'mine');
  assert.equal(C.timeState(tt({ time_at: FUT, time_by: YOU }), ME), 'theirs');
  assert.equal(C.timeState(tt({ time_at: FUT, time_by: YOU, time_ok_at: iso('2026-10-20', 13) }), ME), 'agreed');
});

test('timeSave: only a to-do nobody else is involved in is agreed at once; for partner, from partner and Both propose', () => {
  const nowIso = new Date(NOW).toISOString(), when = at('2026-10-22', 19);
  assert.deepEqual(C.timeSave(tt({}), ME, when, nowIso), { time_at: FUT, time_by: ME, time_ok_at: nowIso });
  for (const [name, t] of [['for partner', tt({ owner_id: YOU })], ['from partner', tt({ created_by: YOU })], ['both', tt({ shared: true })]]) {
    assert.deepEqual(C.timeSave(t, ME, when, nowIso), { time_at: FUT, time_by: ME, time_ok_at: null }, name);
  }
  assert.deepEqual(C.timeAgreePatch(nowIso), { time_ok_at: nowIso });
  assert.deepEqual(C.timeClearPatch(), { time_at: null, time_by: null, time_ok_at: null });
});

test('timeNotify: agreed + future + open + live only', () => {
  const ok = tt({ time_at: FUT, time_by: ME, time_ok_at: iso('2026-10-20', 13) });
  assert.equal(C.timeNotify(ok, NOW), true);
  assert.equal(C.timeNotify({ ...ok, time_ok_at: null }, NOW), false, 'proposal');
  assert.equal(C.timeNotify({ ...ok, time_at: iso('2026-10-19', 19) }, NOW), false, 'past');
  assert.equal(C.timeNotify({ ...ok, done_at: iso('2026-10-20', 11) }, NOW), false, 'done');
  assert.equal(C.timeNotify({ ...ok, declined_at: iso('2026-10-20', 11) }, NOW), false, 'declined');
  assert.equal(C.timeNotify({ ...ok, deleted_at: iso('2026-10-20', 11) }, NOW), false, 'deleted');
  assert.equal(C.timeNotify(tt({}), NOW), false, 'no time');
});

// Session robustness: single-flight refresh, persist-before-proceed, Keychain password fallback.
// Loads cycle-store.js the way the browser does, with a fake native bridge for kv + creds.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import './cycle-load.mjs';

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web');
const user = { id: 'u1', email: 'a@b.test' };
const tokens = (n) => ({ access_token: 'at' + n, refresh_token: 'rt' + n, expires_in: 3600, user });

// opts.refresh: 'ok' | 'reject' | an HTTP status (transient error); opts.creds: stored {email,password} or null
function load({ refresh = 'ok', creds = null, pwd = 'ok' } = {}) {
  const posts = [], kvw = [], cancelled = [], native = { creds, kv: {} };
  globalThis.window = globalThis;
  globalThis.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k' };
  globalThis.webkit = { messageHandlers: { cycle: { postMessage: ({ id, cmd, args }) => {
    queueMicrotask(() => {
      let r = null;
      if (cmd === 'store.get') r = native.kv[args.key] ?? null;
      else if (cmd === 'store.set') { native.kv[args.key] = args.value; kvw.push(args.key); }
      else if (cmd === 'creds.get') r = native.creds;
      else if (cmd === 'creds.set') native.creds = { email: args.email, password: args.password };
      else if (cmd === 'creds.clear') native.creds = null;
      else if (cmd === 'notify.cancel') cancelled.push(args.id);
      else throw new Error('unexpected bridge cmd ' + cmd);
      globalThis.__cycleReply(id, r, null);
    });
  } } } };
  let n = 0;
  globalThis.fetch = async (url, o) => {
    if (url.includes('/auth/v1/token?grant_type=refresh_token')) {
      posts.push('refresh'); await new Promise(r => setTimeout(r, 20));
      if (refresh === 'race') { globalThis.__native.kv.session = JSON.stringify({ access_token: 'atWin', refresh_token: 'rtWin', expires_at: Date.now() / 1000 + 3600, user }); return { ok: false, status: 400, json: async () => ({ code: 400, error_code: 'refresh_token_already_used', msg: 'Invalid Refresh Token: Already Used' }) }; }
      if (refresh === 'reject') return { ok: false, status: 400, json: async () => ({ code: 400, error_code: 'refresh_token_not_found', msg: 'Invalid Refresh Token: Refresh Token Not Found' }) };
      // A gateway/rate-limit answer: JSON, but no GoTrue error_code.
      if (typeof refresh === 'number') return { ok: false, status: refresh, json: async () => ({ message: 'upstream ' + refresh }) };
      return { ok: true, status: 200, json: async () => tokens('R' + ++n) };
    }
    if (url.includes('/auth/v1/token?grant_type=password')) {
      posts.push('password');
      if (pwd === 'reject') return { ok: false, status: 400, json: async () => ({ code: 400, error_code: 'invalid_credentials', msg: 'Invalid login credentials' }) };
      return { ok: true, status: 200, json: async () => tokens('P' + ++n) }; }
    // api() now reads text() and requires a JSON content-type on a real answer, so the fake carries both.
    if (url.includes('/rest/v1/')) return { ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => '[]', json: async () => [] };
    throw new Error('unexpected fetch ' + url);
  };
  vm.runInThisContext(fs.readFileSync(path.join(dir, 'cycle-store.js'), 'utf8') + '\n;globalThis.__store = CycleStore;', { filename: 'cycle-store.js' });
  const st = globalThis.__store;
  st.S.session = { access_token: 'old', refresh_token: 'rtOld', expires_at: Date.now() / 1000 + 5, user };
  globalThis.__native = native;
  return { st, posts, kvw, native };
}
const native_set = (st, sess) => { globalThis.__native.kv.session = JSON.stringify(sess); };

test('N concurrent api() calls near expiry cause exactly one refresh POST', async () => {
  const { st, posts } = load();
  await Promise.all([1, 2, 3, 4, 5].map(() => st.api('GET', 'items?select=*')));
  assert.deepEqual(posts, ['refresh']);
  assert.equal(st.S.session.refresh_token, 'rtR1');
});

test('refresh is persisted before api() proceeds', async () => {
  const { st, native } = load();
  await st.api('GET', 'items?select=*');
  assert.equal(JSON.parse(native.kv.session).refresh_token, 'rtR1');
});

test('refresh rejected + stored creds: one password grant, session replaced and persisted', async () => {
  const { st, posts, native } = load({ refresh: 'reject', creds: { email: 'a@b.test', password: 'pw' } });
  await Promise.all([1, 2, 3].map(() => st.api('GET', 'items?select=*')));
  assert.deepEqual(posts, ['refresh', 'password']);
  assert.equal(st.S.session.refresh_token, 'rtP1');
  assert.equal(JSON.parse(native.kv.session).refresh_token, 'rtP1');
});

test('refresh rejected + no creds (web): the error surfaces and the dead session is signed out', async () => {
  const { st, posts, native } = load({ refresh: 'reject', creds: null });
  await assert.rejects(st.api('GET', 'items?select=*'), /Invalid Refresh Token/);
  assert.deepEqual(posts, ['refresh']);
  assert.equal(st.S.session, null);
  assert.equal(native.kv.session, null);
});

// Esme's phone, 2026-11-08: password changed elsewhere, so the Keychain copy was stale. The app stayed signed in and
// flashed "Wrong email or password" on every sync with no sign-in screen to type the new one.
test('refresh rejected + stale stored password: signed out, creds cleared, so the sign-in screen shows', async () => {
  const { st, posts, native } = load({ refresh: 'reject', creds: { email: 'a@b.test', password: 'old' }, pwd: 'reject' });
  await assert.rejects(st.api('GET', 'items?select=*'), /Invalid login credentials/);
  assert.deepEqual(posts, ['refresh', 'password']);
  assert.equal(st.S.session, null);
  assert.equal(native.kv.session, null);
  assert.equal(native.creds, null);
});

test('sync after a dead refresh on web leaves no stale sync error under the sign-in screen', async () => {
  const { st } = load({ refresh: 'reject', creds: null });
  await st.sync();
  assert.equal(st.S.session, null);
  assert.equal(st.S.syncError, null);
});

test('offline (fetch TypeError) does not fall back to the password', async () => {
  const { st, posts } = load({ creds: { email: 'a@b.test', password: 'pw' } });
  globalThis.fetch = async () => { posts.push('fetch'); throw new TypeError('Failed to fetch'); };
  await assert.rejects(st.api('GET', 'items?select=*'), TypeError);
  assert.deepEqual(posts, ['fetch']);
});

test('signIn stores creds, signOut clears them', async () => {
  const { st, native } = load();
  await st.signIn('a@b.test', 'pw').catch(() => {}); // post-login sync has no couple fixtures; only auth matters here
  assert.deepEqual(native.creds, { email: 'a@b.test', password: 'pw' });
  await st.signOut();
  assert.equal(native.creds, null);
});

test('pull fetches the shared tables in parallel, not one by one', async () => {
  const { st } = load();
  st.S.session.expires_at = Date.now() / 1000 + 3600; // no refresh in the way
  let inflight = 0, peak = 0;
  globalThis.fetch = async (url) => {
    inflight++; peak = Math.max(peak, inflight);
    await new Promise(r => setTimeout(r, 30));
    inflight--;
    const body = url.includes('/rest/v1/couples') ? '[{"id":"c1"}]' : '[]';
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => body, json: async () => JSON.parse(body) };
  };
  await st.sync();
  assert.equal(st.S.syncError, null);
  assert.equal(st.S.couple.id, 'c1');
  assert.ok(peak >= 10, 'peak concurrent requests ' + peak);
});

// GoTrue restarting (5xx), rate limiting (429) or a gateway 401 with no GoTrue error_code is a blip, not a verdict on the token: signing out over it was a cause of
// "we get logged out too often" (2026-11-26). The session and the Keychain password stay; the next sync retries.
for (const status of [503, 429, 401]) {
  test(`refresh answered ${status}: stays signed in, no password grant, error surfaces for a retry`, async () => {
    const { st, posts, native } = load({ refresh: status, creds: { email: 'a@b.test', password: 'pw' } });
    native.kv.session = JSON.stringify(st.S.session);
    await assert.rejects(st.api('GET', 'items?select=*'), new RegExp('upstream ' + status));
    assert.deepEqual(posts, ['refresh']);
    assert.equal(st.S.session.refresh_token, 'rtOld');
    assert.equal(JSON.parse(native.kv.session).refresh_token, 'rtOld');
    assert.deepEqual(native.creds, { email: 'a@b.test', password: 'pw' });
  });
}

// Another tab (or the page before a web-OTA reload) already rotated the token and stored the new one. Re-sending the
// spent token trips GoTrue's reuse detection (refresh_token_already_used, 2026-11-24) and, on web, signed out.
test('a newer session in storage from another page is adopted instead of re-sending the spent token', async () => {
  const { st, posts } = load({ refresh: 'reject', creds: null });
  const newer = { access_token: 'atOther', refresh_token: 'rtOther', expires_at: Date.now() / 1000 + 3600, user };
  native_set(st, newer);
  await st.api('GET', 'items?select=*');
  assert.deepEqual(posts, []);
  assert.equal(st.S.session.refresh_token, 'rtOther');
});

test('an older stored session never replaces the one in memory', async () => {
  const { st, posts } = load();
  native_set(st, { access_token: 'atStale', refresh_token: 'rtStale', expires_at: Date.now() / 1000 - 100, user });
  await st.api('GET', 'items?select=*');
  assert.deepEqual(posts, ['refresh']);
  assert.equal(st.S.session.refresh_token, 'rtR1');
});

// The stale tab's own persist used to write its spent token back over the other tab's fresh one, so adoption never
// happened in practice (code-skeptic, 2026-11-26). Newest wins in storage.
test('a stale page persisting does not overwrite a newer stored session, and then adopts it', async () => {
  const { st, posts, native } = load({ refresh: 'reject', creds: null });
  st.S.loaded = false;
  const newer = { access_token: 'atOther', refresh_token: 'rtOther', expires_at: Date.now() / 1000 + 3600, user };
  native_set(st, newer);
  await st.persistNow();
  assert.equal(JSON.parse(native.kv.session).refresh_token, 'rtOther');
  await st.api('GET', 'items?select=*');
  assert.deepEqual(posts, []);
  assert.equal(st.S.session.refresh_token, 'rtOther');
});

// Mac Chrome, 2026-11-25 21:26: two tabs refreshed the same token at once; the loser got refresh_token_already_used and,
// with no Keychain on web, signed out. The winner has stored its session by then, so the loser adopts it.
test('losing a simultaneous refresh to another tab adopts the winner instead of signing out', async () => {
  const { st, posts, native } = load({ refresh: 'race', creds: null });
  await st.api('GET', 'items?select=*');
  assert.deepEqual(posts, ['refresh']);
  assert.equal(st.S.session.refresh_token, 'rtWin');
  assert.equal(JSON.parse(native.kv.session).refresh_token, 'rtWin');
});

// Web Locks wiring: the refresh runs inside the 'cycle-refresh' lock, and a lock that never frees (a frozen tab holding
// it) times out into an unlocked refresh instead of stalling sync forever.
test('refresh runs inside the cycle-refresh lock', async () => {
  const names = [];
  globalThis.navigator = { locks: { request: (name, opts, fn) => { names.push(name); assert.ok(opts.signal); return fn(); } } };
  try {
    const { st, posts } = load();
    await st.api('GET', 'items?select=*');
    assert.deepEqual(names, ['cycle-refresh']);
    assert.deepEqual(posts, ['refresh']);
  } finally { delete globalThis.navigator; }
});

test('a lock held forever: the wait times out and the refresh still runs', async () => {
  globalThis.navigator = { locks: { request: (name, opts) => new Promise((_, rej) => { const e = new Error('timed out'); e.name = 'TimeoutError'; rej(e); }) } };
  try {
    const { st, posts } = load();
    await st.api('GET', 'items?select=*');
    assert.deepEqual(posts, ['refresh']);
    assert.equal(st.S.session.refresh_token, 'rtR1');
  } finally { delete globalThis.navigator; }
});

test('an error thrown inside the locked refresh is not retried unlocked', async () => {
  globalThis.navigator = { locks: { request: (name, opts, fn) => fn() } };
  try {
    const { st, posts } = load({ creds: null });
    globalThis.fetch = async () => { posts.push('fetch'); const e = new Error('aborted'); e.name = 'AbortError'; throw e; };
    await assert.rejects(st.api('GET', 'items?select=*'));
    assert.deepEqual(posts, ['fetch']);
  } finally { delete globalThis.navigator; }
});

// cycle-send-fixes regression: after a refresh, the old session left in storage must never be adopted back, even when its
// expires_at is later than the fresh one's (seeded far-future sessions, clock changes).
test('a spent session left in storage is never adopted back over the fresh one', async () => {
  const { st, native } = load();
  st.S.session.expires_at = 4102444800; st.S.session.access_token = 'old';
  native.kv.session = JSON.stringify(st.S.session);
  await st.api('GET', 'items?select=*'); // no refresh needed yet
  st.S.session.expires_at = Date.now() / 1000 + 5; // now due (stored copy still says 2100)
  native.kv.session = JSON.stringify({ ...st.S.session, expires_at: 4102444800 });
  await st.api('GET', 'items?select=*');
  assert.equal(st.S.session.refresh_token, 'rtR1');
  await st.persistNow();
  assert.equal(st.S.session.refresh_token, 'rtR1');
  assert.equal(JSON.parse(native.kv.session).refresh_token, 'rtR1');
});

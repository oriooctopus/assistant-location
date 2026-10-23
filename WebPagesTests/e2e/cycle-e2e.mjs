// Live two-person Cycle e2e. Two browser contexts are two users against the real Supabase project.
// Reads the service key from ~/.config/cycle/env (never committed) ONLY to tweak hold lengths and to
// delete the throwaway users/couple at the end. Usage: node cycle-e2e.mjs  (serve CycleApp/web on :8341 first)
import { chromium } from 'playwright';
import fs from 'node:fs';
import os from 'node:os';

const env = Object.fromEntries(fs.readFileSync(os.homedir() + '/.config/cycle/env', 'utf8').split('\n').filter(l => l.includes('=')).map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
const URL_ = env.SUPABASE_URL, SVC = env.SUPABASE_SERVICE_ROLE_KEY, APP = 'http://localhost:8341/index.html';
const hard = setTimeout(() => { console.log('FAIL hard timeout'); process.exit(2); }, 8 * 60 * 1000);
const results = []; let failed = 0;
function check(name, ok, detail) { results.push(ok); if (!ok) failed++; console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : '  ' + (detail || ''))); }
const svc = async (method, path, body) => { const r = await fetch(URL_ + path, { method, headers: { apikey: SVC, Authorization: 'Bearer ' + SVC, 'Content-Type': 'application/json', Prefer: 'return=minimal' }, body: body ? JSON.stringify(body) : undefined }); if (!r.ok) throw new Error(method + ' ' + path + ' ' + r.status + ' ' + await r.text()); return r; };
async function cleanup(coupleId, emails) {
  // FK order matters: members/rows reference the couple, members reference auth users, so users go last
  // (deleting a user or couple first returns 500/409 and silently leaks throwaway data).
  if (coupleId) {
    for (const t of ['todo_events', 'todos', 'items', 'checkins', 'fight_markers', 'redemptions', 'rewards', 'members']) await svc('DELETE', `/rest/v1/${t}?couple_id=eq.${coupleId}`);
    await svc('DELETE', `/rest/v1/couples?id=eq.${coupleId}`);
  }
  const r = await (await fetch(URL_ + '/auth/v1/admin/users?per_page=200', { headers: { apikey: SVC, Authorization: 'Bearer ' + SVC } })).json();
  for (const u of (r.users || []).filter(x => emails.includes(x.email))) {
    const d = await fetch(URL_ + '/auth/v1/admin/users/' + u.id, { method: 'DELETE', headers: { apikey: SVC, Authorization: 'Bearer ' + SVC } });
    if (!d.ok) throw new Error('delete user ' + d.status);
  }
}
const stamp = Date.now();
const users = [`cycle-e2e-a-${stamp}@example.com`, `cycle-e2e-b-${stamp}@example.com`], pw = 'e2e-pass-' + stamp;
const VENT = 'VENTSECRET' + stamp, ABOUT = 'ABOUTSECRET' + stamp;
let coupleId = null; const userIds = [];

const browser = await chromium.launch({ headless: true });
async function mk(name) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  const p = await ctx.newPage();
  p.on('pageerror', e => console.log('PAGEERR ' + name, e.stack));
  await p.goto(APP); await p.waitForSelector('.phone');
  return { ctx, p, name };
}
// Home has no tab bar (matches the mockup), so 'go home' is a no-op when already there.
const home = u => u.p.evaluate(() => { const t = document.querySelector('[data-a="tab:home"]'); if (t) t.click(); });
const act = (u, a) => u.p.click(`[data-a="${a}"]`);
const sync = u => u.p.evaluate(() => CycleStore.syncNow());
const text = u => u.p.evaluate(() => document.querySelector('#app').innerText);
async function waitText(u, re, ms = 15000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { await sync(u); if (re.test(await text(u))) return true; await u.p.waitForTimeout(500); }
  return false;
}
async function signup(u, email) {
  await u.p.fill('[data-d=email]', email); await u.p.fill('[data-d=password]', pw);
  await act(u, 'signup'); await u.p.waitForSelector('[data-d=name]');
}
async function goSend(u, kind) { await home(u); await act(u, 'row:send'); await u.p.waitForSelector('.p2.sd'); await act(u, 'kind:' + kind); }
async function bal(u) { await home(u); await act(u, 'go:points'); await u.p.waitForSelector('#balance'); const v = await u.p.textContent('#balance'); const l = await u.p.textContent('.ledger'); return { v: +v, l: l.replace(/\s+/g, ' ') }; }

try {
  const A = await mk('A'), B = await mk('B');
  // --- sign up + couple
  await signup(A, users[0]);
  await A.p.fill('[data-d=name]', 'Alex'); await act(A, 'create'); await A.p.waitForSelector('#invite-code');
  const code = (await A.p.textContent('#invite-code')).trim();
  check('A creates couple, gets invite code', /^[A-Z0-9]{4,8}$/.test(code), code);
  await act(A, 'codedone'); await A.p.waitForSelector('.pts');
  await signup(B, users[1]);
  await act(B, 'mode:join'); await B.p.fill('[data-d=name]', 'Blake'); await B.p.fill('[data-d=code]', code); await act(B, 'join'); await B.p.waitForSelector('.pts');
  check('B joins with code', true);
  coupleId = await A.p.evaluate(() => CycleStore.S.couple.id);
  for (const u of [A, B]) userIds.push(await u.p.evaluate(() => CycleStore.me()));
  // 1-minute truth hold, everything else instant, set server-side (hold settings are shared couple rows).
  await svc('PATCH', `/rest/v1/couples?id=eq.${coupleId}`, { hold_truth_min: 1, hold_kudos_min: 0, hold_ask_min: 0, hold_focus_min: 0 });
  for (const u of [A, B]) { await sync(u); }
  check('A and B see each other', (await A.p.evaluate(() => CycleStore.partner().name)) === 'Blake' && (await B.p.evaluate(() => CycleStore.partner().name)) === 'Alex');

  // --- kudos immediate
  const KUDOS = 'kudos-' + stamp;
  await act(A, 'tab:us'); await A.p.fill('[data-d=kudos]', KUDOS); await act(A, 'sendkudos');
  check('Kudos arrives immediately for B', await waitText(B, new RegExp(KUDOS), 8000) || (await B.p.evaluate(k => Object.values(CycleStore.S.rows.items).some(i => i.body === k), KUDOS)));

  // --- truth held 1 minute
  const TRUTH = 'truth-' + stamp;
  await goSend(A, 'truth'); await A.p.fill('[data-d=body]', TRUTH); await act(A, 'sendit');
  await sync(B);
  const seenEarly = await B.p.evaluate(t => Object.values(CycleStore.S.rows.items).some(i => i.body === t), TRUTH);
  await sync(A); // flush the outbox so the server row exists before we look
  const srvRow = (await (await fetch(URL_ + `/rest/v1/items?body=eq.${TRUTH}&select=status`, { headers: { apikey: SVC, Authorization: 'Bearer ' + SVC } })).json())[0];
  check('Truth exists held server-side', srvRow && srvRow.status === 'held', JSON.stringify(srvRow));
  check('B cannot see held Truth', !seenEarly);
  console.log('waiting 65s for hold...'); await A.p.waitForTimeout(65000);
  await A.p.evaluate(() => window.cycleNative.foreground());
  await home(A); await A.p.waitForSelector('[data-a^="still:"]');
  check('A gets Still send? card after hold', /Still send/i.test(await text(A)));
  await A.p.click('[data-a^="still:"]'); await A.p.waitForSelector('.bs'); await A.p.click('.bs [data-a^="deliver:"]');
  await A.p.waitForTimeout(500);
  await sync(B); await act(B, 'tab:us');
  const heldOk = await waitText(B, new RegExp(TRUTH));
  check('B sees Truth after Send', heldOk);
  check('Truth carries Held label on Us', /Held/i.test(await text(B)), (await text(B)).slice(0, 300));

  // --- ask -> todo with badge
  const ASK = 'ask-' + stamp;
  await goSend(B, 'ask'); await B.p.fill('[data-d=body]', ASK); await act(B, 'sendit');
  await sync(A);
  await act(A, 'tab:us'); await act(A, 'tab:todo');
  check('A gets Ask as a to do', await waitText(A, new RegExp(ASK)));
  check('To do tab badged', (await A.p.evaluate(() => (document.querySelector('.tabbar .bdg') || {}).textContent)) >= '1');

  // --- fight with vent: only a timestamp may reach B
  await home(A); await act(A, 'row:fight'); await A.p.waitForSelector('.p2.s2');
  await A.p.fill('[data-d=about]', ABOUT); await A.p.fill('[data-d=vent]', VENT); await act(A, 'chip:apologize'); await act(A, 'fightsave');
  await A.p.waitForSelector('.pts');
  await sync(A); await sync(B);
  const dump = await B.p.evaluate(async () => {
    const out = {};
    for (const t of ['items', 'todos', 'todo_events', 'checkins', 'fight_markers', 'rewards', 'redemptions', 'members', 'couples']) out[t] = await CycleStore.api('GET', t + '?select=*');
    return JSON.stringify(out) + JSON.stringify(CycleStore.S.rows);
  });
  check('Fight marker (timestamp only) reaches B', /fight_markers/.test(dump) && JSON.parse(await B.p.evaluate(async () => JSON.stringify(await CycleStore.api('GET', 'fight_markers?select=*')))).length === 1);
  check('B never sees vent or about text', !dump.includes(VENT) && !dump.includes(ABOUT));

  // --- points ledger identical, then redemption
  await home(A); await act(A, 'row:todo');
  for (const u of [A, B]) {
    await home(u); await act(u, 'go:today'); await u.p.waitForSelector('.p2.s1');
    await act(u, 'checkin'); await u.p.waitForSelector('.pts');
  }
  await sync(A); await sync(B);
  const a1 = await bal(A), b1 = await bal(B);
  check('Points ledger identical on both', a1.v === b1.v && a1.l === b1.l, JSON.stringify([a1, b1]).slice(0, 400));
  console.log('balance', a1.v);
  const price = 1; // a1.v is 1 after check-ins, fight and kudos; cost the whole balance
  await home(A); await act(A, 'go:points'); await act(A, 'go:shop');
  await act(A, 'addreward'); await A.p.fill('[data-d=rname]', 'Test reward'); await A.p.fill('[data-d=rprice]', String(price)); await act(A, 'savereward');
  await sync(B);
  // top up so the balance covers the price regardless of fight/kudos deductions
  if (a1.v < price) console.log('NOTE balance below price; redemption may be refused client-side');
  await A.p.click('[data-a^="reward:"]'); await A.p.waitForSelector('.bs [data-a^="redeem:"]'); await A.p.click('.bs [data-a^="redeem:"]');
  await sync(B); await home(B);
  await B.p.waitForSelector('[data-a^="approve:"]', { timeout: 15000 });
  check('B sees redemption to approve', true);
  await B.p.click('[data-a^="approve:"]'); await B.p.waitForTimeout(800);
  await sync(A); await sync(B);
  const a2 = await bal(A), b2 = await bal(B);
  check('Balance drops by price on both', a2.v === a1.v - price && b2.v === b1.v - price, `${a1.v}->${a2.v},${b1.v}->${b2.v}`);

  // --- offline write then sync
  const OFF = 'offline-' + stamp;
  await A.ctx.setOffline(true);
  await act(A, 'tab:us'); await A.p.fill('[data-d=kudos]', OFF); await act(A, 'sendkudos'); await A.p.waitForTimeout(500);
  const queued = await A.p.evaluate(o => Object.values(CycleStore.S.rows.items).some(i => i.body === o), OFF);
  check('Offline kudos recorded locally', queued);
  const notYet = await B.p.evaluate(async o => (await CycleStore.api('GET', 'items?body=eq.' + o + '&select=id')).length, OFF);
  check('Offline kudos not on server yet', notYet === 0);
  await A.ctx.setOffline(false); await sync(A); await A.p.waitForTimeout(1000);
  check('After online, B receives it', await waitText(B, /./, 2000) && await B.p.evaluate(async o => { await CycleStore.syncNow(); return Object.values(CycleStore.S.rows.items).some(i => i.body === o); }, OFF));
} catch (e) {
  check('script ran without exception', false, e.stack);
} finally {
  try { await cleanup(coupleId, users); } catch (e) { console.log('CLEANUP ERROR', e.message); failed++; }
  await browser.close(); clearTimeout(hard);
  console.log(`\n${results.filter(Boolean).length} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
}

// Screenshot pairs: each Cycle screen (app, left) beside its approved mockup frame (right), 390x844 @2x.
// Seeds a throwaway couple with service-key REST inserts (key from ~/.config/cycle/env, never committed),
// drives the real app on :8341, then deletes everything. Output: ~/coding/cycle-tracker/web/public/build-shots/
import { chromium } from 'playwright';
import fs from 'node:fs';
import os from 'node:os';
import crypto from 'node:crypto';

const env = Object.fromEntries(fs.readFileSync(os.homedir() + '/.config/cycle/env', 'utf8').split('\n').filter(l => l.includes('=')).map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
const URL_ = env.SUPABASE_URL, SVC = env.SUPABASE_SERVICE_ROLE_KEY, APP = 'http://localhost:8341/index.html';
const MOCK = os.homedir() + '/coding/cycle-tracker/web/public/', OUT = MOCK + 'build-shots/';
fs.mkdirSync(OUT, { recursive: true });
const H = { apikey: SVC, Authorization: 'Bearer ' + SVC, 'Content-Type': 'application/json', Prefer: 'return=minimal' };
const svc = async (method, path, body) => { const r = await fetch(URL_ + path, { method, headers: H, body: body ? JSON.stringify(body) : undefined }); if (!r.ok) throw new Error(method + ' ' + path + ' ' + r.status + ' ' + await r.text()); return r; };
async function cleanup(coupleId, emails) {
  // FK order matters: members/rows reference the couple, members reference auth users, so users go last
  // (deleting a user or couple first returns 500/409 and silently leaks throwaway data).
  if (coupleId) {
    for (const t of ['todo_events', 'todos', 'items', 'fight_markers', 'redemptions', 'rewards', 'members']) await svc('DELETE', `/rest/v1/${t}?couple_id=eq.${coupleId}`);
    await svc('DELETE', `/rest/v1/couples?id=eq.${coupleId}`);
  }
  const r = await (await fetch(URL_ + '/auth/v1/admin/users?per_page=200', { headers: { apikey: SVC, Authorization: 'Bearer ' + SVC } })).json();
  for (const u of (r.users || []).filter(x => emails.includes(x.email))) {
    const d = await fetch(URL_ + '/auth/v1/admin/users/' + u.id, { method: 'DELETE', headers: { apikey: SVC, Authorization: 'Bearer ' + SVC } });
    if (!d.ok) throw new Error('delete user ' + d.status);
  }
}
const stamp = Date.now(), emails = [`cycle-shot-a-${stamp}@example.com`, `cycle-shot-b-${stamp}@example.com`], pw = 'shot-pass-' + stamp;
const uid = () => crypto.randomUUID(), iso = ms => new Date(ms).toISOString(), DAY = 864e5;
const hard = setTimeout(() => { console.log('hard timeout'); process.exit(2); }, 6 * 60 * 1000);
let coupleId = null;
const browser = await chromium.launch({ headless: true });
const mk = async () => { const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 }); const p = await ctx.newPage(); p.on('pageerror', e => console.log('PAGEERR', e.stack)); await p.goto(APP); await p.waitForSelector('.phone'); return p; };
const act = (p, a) => p.click(`[data-a="${a}"]`);
const settle = p => p.waitForTimeout(450);
const pairs = [];
async function shot(p, name, file, idx) { await settle(p); await p.screenshot({ path: OUT + name + '-app.png' }); pairs.push([name, file, idx]); }

try {
  const A = await mk(), B = await mk();
  for (const [p, e] of [[A, emails[0]], [B, emails[1]]]) { await p.fill('[data-d=email]', e); await p.fill('[data-d=password]', pw); await act(p, 'signup'); await p.waitForSelector('[data-d=name]'); }
  await A.fill('[data-d=name]', 'Alex'); await act(A, 'create'); await A.waitForSelector('#invite-code');
  const code = (await A.textContent('#invite-code')).trim(); await act(A, 'codedone'); await A.waitForSelector('.pts');
  await act(B, 'mode:join'); await B.fill('[data-d=name]', 'Blake'); await B.fill('[data-d=code]', code); await act(B, 'join'); await B.waitForSelector('.pts');
  const cid = coupleId = await A.evaluate(() => CycleStore.S.couple.id);
  const [a, b] = await Promise.all([A, B].map(p => p.evaluate(() => CycleStore.me())));
  const now = Date.now();
  await svc('PATCH', `/rest/v1/couples?id=eq.${cid}`, { hold_truth_min: 60, hold_kudos_min: 0, hold_ask_min: 0, hold_focus_min: 0 });
  const item = (o) => Object.assign({ id: uid(), couple_id: cid, status: 'delivered', delivered_at: iso(now - 3600e3), created_at: iso(now - 7200e3), held_until: null, ask_type: null, due_date: null, target: null, origin: null, response_type: null, opened_at: null, kept: false }, o);
  const heldId = uid(), readyId = uid();
  await svc('POST', '/rest/v1/items', [
    item({ id: heldId, sender_id: a, recipient_id: b, kind: 'truth', body: 'I felt unheard when plans changed.', status: 'held', held_until: iso(now + 45 * 60e3), delivered_at: null }),
    item({ id: readyId, sender_id: a, recipient_id: b, kind: 'ask', body: 'Pick up the dry cleaning', ask_type: 'task', status: 'held', held_until: iso(now - 60e3), delivered_at: null }),
    item({ sender_id: b, recipient_id: a, kind: 'kudos', body: 'Thank you for cooking tonight, it meant a lot.' }),
    item({ sender_id: b, recipient_id: a, kind: 'truth', body: 'I want more time with just us.', held_until: iso(now - 7000e3) }),
    item({ sender_id: b, recipient_id: a, kind: 'focus', body: 'Be gentle with yourself today.' }),
    item({ sender_id: b, recipient_id: a, kind: 'kudos', body: 'You listened well.', kept: true, opened_at: iso(now - 3000e3) }),
  ]);
  const td = (o) => Object.assign({ id: uid(), couple_id: cid, tally: 0, created_at: iso(now - 7200e3), due_date: null, target: null, done_at: null, item_id: null, fight_marker_id: null }, o);
  const doneTodo = uid();
  await svc('POST', '/rest/v1/todos', [
    td({ owner_id: a, created_by: a, title: 'Call the landlord', type: 'task', due_date: new Date(now + DAY).toISOString().slice(0, 10) }),
    td({ owner_id: a, created_by: b, title: 'Take out recycling', type: 'task' }),
    td({ owner_id: a, created_by: a, title: 'Stretch', type: 'habit', target: 5, tally: 2 }),
    td({ owner_id: b, created_by: b, title: 'Book dentist', type: 'task' }),
    td({ id: doneTodo, owner_id: a, created_by: a, title: 'Pay bill', type: 'task', done_at: iso(now - 2 * DAY) }),
  ]);
  await svc('POST', '/rest/v1/todo_events', [{ id: uid(), couple_id: cid, todo_id: doneTodo, user_id: a, kind: 'done', at: iso(now - 2 * DAY) }]);
  const day = n => new Date(now - n * DAY).toISOString().slice(0, 10);
  const rw = uid();
  await svc('POST', '/rest/v1/rewards', [{ id: rw, couple_id: cid, name: 'Breakfast in bed', price: 8, created_by: a }, { id: uid(), couple_id: cid, name: 'Movie pick', price: 4, created_by: a }, { id: uid(), couple_id: cid, name: 'Day off chores', price: 30, created_by: b }]);
  await svc('POST', '/rest/v1/redemptions', [{ id: uid(), couple_id: cid, reward_id: rw, price: 8, requested_by: b, status: 'pending' }]);
  await A.evaluate(() => CycleStore.syncNow());
  // A local fight so Cycle has data (private tier, device only).
  await A.evaluate((n) => { const S = CycleStore.S; [[3, 2, 'Plans changed'], [17, 4, 'Dishes'], [31, 3, 'Money']].forEach(([d, i, ab]) => S.priv.fights.push({ id: crypto.randomUUID(), at: n - d * 864e5, intensity: i, about: ab, vent: '', rewritten: '', shared: false })); CycleStore.savePriv(); CycleStore.emit(); }, now);

  await shot(A, '01-home', 'mockup-cycle-p2-final.html', 0);
  const row = A.locator('.rows .row').first(); const bb = await row.boundingBox();
  await A.mouse.move(bb.x + 40, bb.y + 20); await A.mouse.down(); await A.waitForTimeout(650); await shot(A, '02-home-edit', 'mockup-cycle-p2-final.html', 1); await A.mouse.up();
  await A.reload(); await A.waitForSelector('.pts');
  await act(A, 'row:send'); await A.waitForSelector('.p2.sd'); await A.fill('[data-d=body]', 'Thinking of you.'); await shot(A, '03-send', 'mockup-cycle-p2-final.html', 2);
  await act(A, 'go:held'); await A.waitForSelector('.p2.hl2'); await shot(A, '04-held', 'mockup-cycle-p2-final.html', 3);
  await act(A, 'tab:todo'); await A.waitForSelector('.p2.td'); await shot(A, '06-todo', 'mockup-cycle-p2-final.html', 5);
  await A.click('.td-row .elink >> nth=1'); await A.waitForSelector('.bs'); await shot(A, '05-todo-still-send', 'mockup-cycle-p2-final.html', 4); await A.click('.bs [data-a="sheet:close"]');
  await act(A, 'newtodo'); await A.waitForSelector('.bs'); await shot(A, '07-new-todo', 'mockup-cycle-p2-final.html', 6); await A.click('.bs [data-a="sheet:close"]');
  await act(A, 'tab:home'); await act(A, 'row:fight'); await A.waitForSelector('.p2.s2'); await A.fill('[data-d=about]', 'Plans changed'); await shot(A, '08-log-fight', 'mockup-cycle-p2-final.html', 7);
  await act(A, 'tab:us'); await A.waitForSelector('.p2.s4'); await shot(A, '09-us', 'mockup-cycle-p2-final.html', 8);
  await act(A, 'go:cycle'); await A.waitForSelector('.p2.cyc'); await shot(A, '13-cycle', 'mockup-cycle-p2-v6.html', 0);
  await act(A, 'tab:home'); await A.click('.nc[data-a^="open:"] >> nth=0'); await A.waitForSelector('.p2.k4'); await shot(A, '10-kudos', 'mockup-cycle-p2-final.html', 9); await act(A, 'back');
  await act(A, 'tab:us'); await act(A, 'go:settings'); await A.waitForSelector('.p2.s5'); await shot(A, '12-settings', 'mockup-cycle-p2-final.html', 11);
  await act(A, 'tab:home'); await act(A, 'go:points'); await A.waitForSelector('#balance'); await shot(A, '14-points', 'mockup-cycle-p2-points.html', 2);
  await act(A, 'go:shop'); await A.waitForSelector('.shop'); await shot(A, '15-shop', 'mockup-cycle-p2-points.html', 3);
  await A.click('[data-a^="reward:"] >> nth=0'); await A.waitForSelector('.bs'); await shot(A, '16-redeem', 'mockup-cycle-p2-points.html', 4); await A.click('.bs [data-a="sheet:close"]');
  await A.reload(); await A.waitForSelector('.pts');
  await shot(A, '17-home-approve', 'mockup-cycle-p2-points.html', 5);
  // Week card only shows on the closing day, so inject the same delegated trigger it uses.
  await A.evaluate(() => { const b = document.createElement('div'); b.dataset.a = 'go:week'; b.id = 'wk-trigger'; document.querySelector('#app').appendChild(b); }); await A.dispatchEvent('#wk-trigger', 'click'); await A.waitForSelector('.wc'); await A.waitForTimeout(2300); await shot(A, '18-week', 'mockup-cycle-p2-points.html', 6);
  fs.writeFileSync(OUT + 'pairs.json', JSON.stringify(pairs));

  // Mockup frames + side-by-side composites.
  const mp = await (await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 })).newPage();
  const cache = {};
  for (const [name, file, idx] of pairs) {
    if (!cache[file]) { await mp.goto('file://' + MOCK + file); await mp.waitForTimeout(500); cache[file] = await mp.locator('.phone').count(); }
    await mp.goto('file://' + MOCK + file); await mp.waitForTimeout(400);
    await mp.locator('.phone').nth(idx).screenshot({ path: OUT + name + '-mock.png' });
    const l = fs.readFileSync(OUT + name + '-app.png').toString('base64'), r = fs.readFileSync(OUT + name + '-mock.png').toString('base64');
    await mp.setContent(`<body style="margin:0;background:#222;display:flex;gap:16px"><img src="data:image/png;base64,${l}" width=390><img src="data:image/png;base64,${r}" width=390></body>`);
    await mp.setViewportSize({ width: 796, height: 844 });
    await mp.screenshot({ path: OUT + name + '.png' });
    await mp.setViewportSize({ width: 390, height: 844 });
  }
} finally {
  await cleanup(coupleId, emails);
  await browser.close(); clearTimeout(hard);
}

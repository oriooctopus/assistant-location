// Offline fixture for Cycle web checks: boots CycleApp/web from file:// with a pre-seeded store and every Supabase
// request aborted (or handled by o.handler), so screens render deterministically without a live backend.
// Engine: Chromium (the `playwright` package) unless CYCLE_WEBKIT_EXEC points at a Playwright WebKit launcher, in which
// case playwright-core from CYCLE_WEBKIT_PW is used (WKWebView is WebKit; layout defects can differ).
import fs from 'node:fs';
export const WEB = new URL('../../CycleApp/web', import.meta.url).pathname;
const DAY = 864e5, uuid = (n) => '00000000-0000-4000-8000-' + String(n).padStart(12, '0');
export const ids = { me: uuid(1), partner: uuid(2), couple: uuid(3), uuid };
export function fixture(o = {}) {
  const now = o.now || Date.now(), me = uuid(1), pt = uuid(2), cid = uuid(3), iso = ms => new Date(ms).toISOString();
  const partner = o.partner || 'Bartholomew Featherstonehaugh-Smythe';
  const couple = { id: cid, tz: 'America/New_York', created_at: o.coupleAt || iso(now - 40 * DAY), invite_code: 'ABC234', hold_truth_min: 60, hold_kudos_min: 0, hold_ask_min: 0, hold_focus_min: 0 };
  const members = [{ user_id: me, couple_id: cid, name: 'Alex', checkin_time: '20:30' }, { user_id: pt, couple_id: cid, name: partner, checkin_time: '21:00' }];
  const item = (n, x) => Object.assign({ id: uuid(100 + n), couple_id: cid, status: 'delivered', delivered_at: iso(now - 3600e3), created_at: iso(now - 7200e3), updated_at: iso(now - 3600e3), held_until: null, ask_type: null, due_date: null, target: null, origin: null, response_type: null, deleted_at: null }, x);
  const LONG = 'I felt really unheard last Tuesday when the plans changed at the last minute and nobody told me.';
  const items = [
    item(1, { sender_id: me, recipient_id: pt, kind: 'truth', body: 'I felt unheard when plans changed.', status: 'held', held_until: iso(now + 45 * 60e3), delivered_at: null }),
    item(2, { sender_id: me, recipient_id: pt, kind: 'ask', body: 'Pick up the dry cleaning', ask_type: 'task', status: 'held', held_until: iso(now - 60e3), delivered_at: null }),
    item(3, { sender_id: pt, recipient_id: me, kind: 'kudos', body: 'Thank you for cooking tonight, it meant a lot.' }),
    item(4, { sender_id: pt, recipient_id: me, kind: 'truth', body: LONG, held_until: iso(now - 7000e3), delivered_at: iso(now - 3 * 3600e3) }),
    item(5, { sender_id: pt, recipient_id: me, kind: 'focus', body: 'Be gentle with yourself today.' }),
    item(6, { sender_id: pt, recipient_id: me, kind: 'kudos', body: 'You listened well.', kept: true, opened_at: iso(now - 3000e3) }),
  ];
  const td = (n, x) => Object.assign({ id: uuid(200 + n), couple_id: cid, tally: 0, created_at: iso(now - 7200e3), updated_at: iso(now - 7200e3), due_date: null, target: null, done_at: null, item_id: null, fight_marker_id: null, deleted_at: null }, x);
  const dd = n => new Date(now + n * DAY).toISOString().slice(0, 10);
  const todos = [
    td(1, { owner_id: me, created_by: me, title: 'Call the landlord', type: 'task', due_date: dd(1) }),
    td(2, { owner_id: me, created_by: pt, title: 'Take out recycling', type: 'task' }),
    td(3, { owner_id: me, created_by: me, title: 'Stretch', type: 'habit', target: 5, tally: 2 }),
    td(4, { owner_id: me, created_by: pt, title: 'Water the plants on the balcony', type: 'task', due_date: dd(0) }),
    td(5, { owner_id: me, created_by: me, title: 'Read', type: 'habit', target: null, tally: 3 }),
    td(6, { owner_id: pt, created_by: pt, title: 'Book dentist', type: 'task' }),
  ];
  const wk = n => new Date(now - n * DAY).toISOString().slice(0, 10);
  const checkins = [1, 2, 3].flatMap(n => [me, pt].map((u, i) => ({ id: uuid(300 + n * 2 + i), couple_id: cid, user_id: u, day: wk(n), created_at: iso(now), updated_at: iso(now) })));
  const rewards = [['Breakfast in bed', 8], ['Movie pick', 4], ['A whole weekend away somewhere warm with no phones allowed', 120]].map((r, i) => ({ id: uuid(400 + i), couple_id: cid, name: r[0], price: r[1], created_by: me, archived: false, created_at: iso(now), updated_at: iso(now) }));
  const by = a => Object.fromEntries(a.map(x => [x.id, x]));
  const x = o.extra || {};
  const rows = { items: by(items.concat(x.items || [])), todos: by(todos.concat(x.todos || [])), todo_events: {}, checkins: by(o.noCheckins ? (x.checkins || []) : checkins.concat(x.checkins || [])), fight_markers: by(x.fight_markers || []), rewards: by(rewards), redemptions: o.pending ? by([{ id: uuid(500), couple_id: cid, reward_id: rewards[0].id, price: 8, requested_by: pt, status: 'pending', created_at: iso(now), updated_at: iso(now) }]) : {} };
  const fights = [[3, 2, 'Plans changed'], [9, 5, 'A really long reason that goes on and on about nothing in particular'], [17, 4, 'Dishes'], [31, 3, 'Money']].map(([d, i, ab], k) => ({ id: uuid(600 + k), at: now - d * DAY, intensity: i, about: ab, vent: '', rewritten: '', shared: false }));
  const priv = { fights: o.fightsAt ? o.fightsAt.map((t, k) => ({ id: uuid(650 + k), at: t, intensity: 3, about: '', vent: '', rewritten: '', shared: false })) : o.noFights ? [] : fights, affirmations: ['I am patient and kind.'], prefs: {} };
  const session = { access_token: 'x', refresh_token: 'x', expires_at: Math.floor(now / 1000) + 99999, user: { id: me, email: 'me@example.com' } };
  return { LS: o.signedOut ? {} : { 'cycle:session': JSON.stringify(session), ['cycle:shared.' + me]: JSON.stringify({ couple: o.noCouple ? null : couple, members: o.noCouple ? [] : members, rows, cursors: {}, outbox: [] }), ['cycle:priv.' + me]: JSON.stringify(priv) } };
}
export async function launch() {
  if (!process.env.CYCLE_WEBKIT_EXEC) return (await import('playwright')).chromium.launch({ headless: true });
  return (await import(process.env.CYCLE_WEBKIT_PW)).webkit.launch({ executablePath: process.env.CYCLE_WEBKIT_EXEC, headless: true });
}
// Insets mimic the iPhone: 59px status area, 34px home indicator, set through the same CSS the page reads (env()) is not
// possible headless, so the overlay is drawn and the page's own 50/34 floors apply; setInset() overrides --st/--sb for the "device" case.
export async function open(b, web, o = {}) {
  web = web || WEB;
  const ctx = await b.newContext({ viewport: { width: o.w || 390, height: o.h || 844 }, deviceScaleFactor: o.dsf || 3, hasTouch: !!o.touch, isMobile: !!o.touch });
  const f = fixture(Object.assign({}, o.fx));
  await ctx.addInitScript((ls) => { for (const k in ls) if (localStorage.getItem(k) === null || !sessionStorage.getItem('__seeded')) localStorage.setItem(k, ls[k]); sessionStorage.setItem('__seeded', '1'); }, f.LS);
  const p = await ctx.newPage();
  if (o.clock) await p.clock.install({ time: o.clock });
  p.errs = [];
  p.on('pageerror', e => p.errs.push(e.message)); p.on('console', m => { if (m.type() === 'error' && !/ERR_INTERNET_DISCONNECTED/.test(m.text())) p.errs.push('console: ' + m.text()); });
  if (!o.noroute) await p.route(/\/(rest|auth)\/v1\//, r => o.handler ? o.handler(r) : r.abort('internetdisconnected'));
  await p.goto('file://' + web + '/index.html'); await p.waitForSelector('.phone'); await p.addStyleTag({ content: '.phone{--st:59px!important}' }); await p.waitForTimeout(350);
  return p;
}
export async function overlay(p, { bottom = true } = {}) {
  await p.evaluate((bottom) => {
    document.getElementById('__ov')?.remove();
    const d = document.createElement('div'); d.id = '__ov'; d.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:99999';
    d.innerHTML = `<div style="position:absolute;left:0;right:0;top:0;height:59px;background:rgba(0,200,255,.10);border-bottom:1px dashed #0cf"></div><div style="position:absolute;left:0;top:0;width:150px;height:59px;display:flex;align-items:flex-end;justify-content:center;padding-bottom:10px;color:#fff;font:600 17px -apple-system,Helvetica,sans-serif;text-shadow:0 0 3px #000">9:41</div><div style="position:absolute;right:26px;top:0;height:59px;display:flex;align-items:flex-end;padding-bottom:12px;gap:6px"><span style="width:18px;height:11px;background:#fff;border-radius:2px"></span><span style="width:26px;height:12px;background:#fff;border-radius:4px"></span></div>` +
      (bottom ? `<div style="position:absolute;left:0;right:0;bottom:0;height:34px;background:rgba(0,200,255,.10);border-top:1px dashed #0cf"></div><div style="position:absolute;left:50%;margin-left:-67px;bottom:8px;width:134px;height:5px;border-radius:3px;background:#fff"></div>` : '');
    document.body.appendChild(d);
  }, bottom);
}
// Screenshot with overlay. clip = {x,y,w,h} in CSS px (1:1 crop at dsf).
export async function shot(p, file, o = {}) {
  await p.waitForTimeout(o.wait ?? 300);
  await overlay(p, { bottom: !o.kb });
  const opt = { path: file }; if (o.clip) opt.clip = { x: o.clip.x, y: o.clip.y, width: o.clip.w, height: o.clip.h };
  await p.screenshot(opt);
  await p.evaluate(() => document.getElementById('__ov')?.remove());
}
export const act = (p, a) => p.click(`[data-a="${a}"]`);

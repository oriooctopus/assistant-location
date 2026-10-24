// Offline Cycle UI checks on the real page: layout invariants (band never over a label, nothing under the status strip,
// 44px tap targets, error bar never over a control), plus the behaviours fixed with them (Decline, one-gesture reorder,
// Today/Yesterday, Offline label, Reward label, no Quiet days, week close from the real flow on a faked clock).
// Usage: node cycle-visual.mjs   (set CYCLE_WEBKIT_EXEC + CYCLE_WEBKIT_PW to run on WebKit instead of Chromium)
// Run against another web dir for a before/after proof: CYCLE_WEB=/path/to/web node cycle-visual.mjs
import { launch, open, ids, WEB } from './cycle-fixture.mjs';

const web = process.env.CYCLE_WEB || WEB, DAY = 864e5;
let failed = 0, total = 0;
function check(name, ok, detail) { total++; if (!ok) failed++; console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : '  ' + (detail === undefined ? '' : JSON.stringify(detail)))); }
const clk = (p, a) => p.click(`[data-a="${a}"]`);
const text = p => p.evaluate(() => document.querySelector('#app').innerText);
const NAV = {
  auth: { fx: { signedOut: true } },
  setup_create: { fx: { noCouple: true } },
  setup_join: { fx: { noCouple: true }, run: p => clk(p, 'mode:join') },
  home: {},
  send: { run: p => clk(p, 'row:send') },
  fight: { run: p => clk(p, 'row:fight') },
  todo: { run: p => clk(p, 'row:todo') },
  newtodo: { run: async p => { await clk(p, 'row:todo'); await clk(p, 'newtodo'); } },
  us: { run: p => clk(p, 'tab:us') },
  settings: { run: async p => { await clk(p, 'tab:us'); await clk(p, 'go:settings'); } },
  cycle: { run: async p => { await clk(p, 'tab:us'); await clk(p, 'go:cycle'); } },
  points: { run: async p => { await clk(p, 'tab:us'); await clk(p, 'go:points'); } },
  shop: { run: async p => { await clk(p, 'tab:us'); await clk(p, 'go:points'); await clk(p, 'go:shop'); } },
  held: { run: async p => { await clk(p, 'row:send'); await clk(p, 'go:held'); } },
  // Check-in card only shows after the check-in time (20:30 NY), so pin the clock to a Wednesday 21:00 NY.
  today: { at: Date.UTC(2026, 9, 22, 1, 0), fx: { noCheckins: true }, run: p => clk(p, 'go:today') },
};
async function screen(b, name, extra = {}) {
  const c = NAV[name], p = await open(b, web, { w: extra.w || 428, h: 926, dsf: 2, fx: Object.assign({}, c.fx, extra.fx, c.at ? { now: c.at } : {}), clock: c.at ? new Date(c.at) : undefined, handler: extra.handler });
  if (c.run) await c.run(p);
  await p.waitForTimeout(250);
  return p;
}

const b = await launch();
try {
  // 1. Band-over-label: the first label of every auth/setup screen starts below the band's lowest edge (the bug the device showed).
  for (const w of [390, 428]) for (const n of ['auth', 'setup_create', 'setup_join']) {
    const p = await screen(b, n, { w });
    const r = await p.evaluate(() => {
      const band = document.querySelector('.band').getBoundingClientRect(), l = document.querySelector('main .lab, main label, main .l').getBoundingClientRect();
      return { first: document.querySelector('main .lab, main label, main .l').textContent, labelTop: Math.round(l.top), bandBottom: Math.round(band.bottom) };
    });
    check(`band clears first label: ${n} @${w}`, r.labelTop >= r.bandBottom, r);
    await p.context().close();
  }

  // 2. Every screen: no control starts under the status strip (59px) and every tap target is at least 44x44.
  for (const n of Object.keys(NAV)) {
    const p = await screen(b, n);
    const bad = await p.evaluate(() => [...document.querySelectorAll('[data-a],input,textarea,label.pick')]
      .filter(e => e.offsetParent !== null && !e.matches('label.pick input') && e.getAttribute('data-a') !== 'sheet:close')
      .map(e => { const r = e.getBoundingClientRect(); return { a: e.getAttribute('data-a') || e.id || e.tagName, top: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) }; })
      .filter(x => x.top < 59 || x.h < 44 || x.w < 44));
    check(`controls clear status strip, >=44px: ${n}`, bad.length === 0, bad);
    await p.context().close();
  }

  // 3. Error bar sits between content and tab bar, never over a control (sync error on Send, a screen with a pinned pill).
  {
    const p = await screen(b, 'send', { handler: r => r.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"boom"}' }) });
    await p.evaluate(() => CycleStore.syncNow().catch(() => {}));
    await p.waitForSelector('.errbar', { timeout: 5000 });
    const r = await p.evaluate(() => {
      const e = document.querySelector('.errbar').getBoundingClientRect();
      return [...document.querySelectorAll('[data-a]')].filter(x => x.offsetParent).map(x => ({ a: x.getAttribute('data-a'), r: x.getBoundingClientRect() }))
        .filter(x => x.r.left < e.right && x.r.right > e.left && x.r.top < e.bottom && x.r.bottom > e.top).map(x => x.a);
    });
    check('error bar overlaps no control', r.length === 0, r);
    await p.context().close();
  }

  // 4. Long partner name: truncated with an ellipsis in the For segment and the Us check-in row; nothing wraps to a second line.
  {
    const p = await screen(b, 'newtodo');
    const r = await p.evaluate(() => { const s = [...document.querySelectorAll('.seg span')].find(x => x.querySelector('.pn')), pn = s.querySelector('.pn'); const sr = s.getBoundingClientRect(), pr = pn.getBoundingClientRect(); return { fits: pr.left >= sr.left - 1 && pr.right <= sr.right + 1, ellipsis: getComputedStyle(pn).textOverflow, oneLine: pr.height < 24 }; });
    check('For segment truncates long partner name', r.fits && r.ellipsis === 'ellipsis' && r.oneLine, r);
    await p.context().close();
  }

  // 5. Removed: Quiet days toggle (wired to nothing).
  {
    const p = await screen(b, 'settings');
    check('settings has no Quiet days', !/quiet/i.test(await text(p)));
    await p.context().close();
  }

  // 6. Log fight row reads Today / Yesterday for recent fights (the row said "Last Fri" for a fight logged today).
  for (const [off, want] of [[0, /today/i], [1, /yesterday/i], [3, /last/i]]) {
    const p = await screen(b, 'home', { fx: { fightsAt: [Date.now() - off * DAY - 60e3] } });
    const t = await p.evaluate(() => document.querySelector('[data-a="row:fight"] .mt').textContent);
    check(`fight row for ${off}d ago -> ${want}`, want.test(t), t);
    await p.context().close();
  }

  // 7. Decline on a pending redemption: replaces "Not now", sends status=declined, and Shop shows the reward available again.
  {
    const posts = [];
    const c = NAV.home, p = await open(b, web, { w: 428, h: 926, dsf: 2, fx: { pending: true }, handler: r => { const q = r.request(); if (q.method() !== 'GET') posts.push({ m: q.method(), u: q.url(), d: q.postData() }); return r.abort('internetdisconnected'); } });
    const t0 = await text(p);
    check('pending card offers Decline, not Not now', /decline/i.test(t0) && !/not now/i.test(t0), t0.slice(0, 300));
    await p.locator('[data-a^="decline:"]').click(); await p.waitForTimeout(400);
    const status = await p.evaluate(id => CycleStore.S.rows.redemptions[id].status, ids.uuid(500));
    check('Decline sets redemption status=declined locally', status === 'declined', status);
    check('Decline card gone from Home', !/decline/i.test(await text(p)));
    await clk(p, 'tab:us'); await clk(p, 'go:points'); await clk(p, 'go:shop');
    const shop = await text(p);
    check('Shop shows declined reward with no pending state', /breakfast in bed/i.test(shop) && !/pending/i.test(shop), shop.slice(0, 200));
    await p.context().close();
  }

  // 8. Offline label: bare "Offline" in the band while the connection is down.
  {
    const p = await screen(b, 'home');
    check('no Offline label while online', (await p.locator('.off').count()) === 0);
    await p.context().setOffline(true); await p.evaluate(() => window.dispatchEvent(new Event('offline'))); await p.waitForTimeout(300);
    const o = await p.locator('.off').allInnerTexts();
    check('Offline label shows when offline', o.length === 1 && /offline/i.test(o[0]), o);
    await p.context().setOffline(false); await p.evaluate(() => window.dispatchEvent(new Event('online'))); await p.waitForTimeout(300);
    check('Offline label clears when back online', (await p.locator('.off').count()) === 0);
    await p.context().close();
  }

  // 9. Add Reward sheet has a visible "Reward" label above the name field.
  {
    const p = await screen(b, 'shop');
    await clk(p, 'addreward'); await p.waitForTimeout(250);
    const t = await p.evaluate(() => { const l = [...document.querySelectorAll('.lab')].find(x => /^reward$/i.test(x.textContent.trim())); const i = document.querySelector('#rname, [data-d=rname]'); return l && i ? l.getBoundingClientRect().bottom <= i.getBoundingClientRect().top + 1 : false; });
    check('Add Reward: "Reward" label above name field', t);
    await p.context().close();
  }

  // 10. Hold-to-reorder is one continuous pointer sequence: press, hold 500ms, drag, release (no lift and re-press).
  {
    const p = await screen(b, 'home');
    const order = () => p.evaluate(() => [...document.querySelectorAll('.rows .row')].map(r => r.dataset.id));
    const before = await order();
    const r0 = await p.locator('.rows .row').first().boundingBox(), r2 = await p.locator('.rows .row').nth(2).boundingBox();
    await p.mouse.move(r0.x + r0.width / 2, r0.y + r0.height / 2); await p.mouse.down(); await p.waitForTimeout(700);
    await p.mouse.move(r2.x + r2.width / 2, r2.y + r2.height * 0.8, { steps: 12 }); await p.mouse.up(); await p.waitForTimeout(300);
    const after = await order();
    check('hold + drag in one press reorders rows', JSON.stringify(after) !== JSON.stringify(before) && after[2] === before[0], { before, after });
    const saved = await p.evaluate(id => JSON.parse(localStorage.getItem('cycle:priv.' + id)).prefs.rows, ids.me);
    check('new order persisted', JSON.stringify(saved) === JSON.stringify(after), saved);
    await p.context().close();
  }

  // 11. Week close from the real flow on a faked Sunday: the card appears, shows each rule, Done plays the animation once.
  {
    const SUN = Date.UTC(2026, 9, 25, 16, 0), D = n => new Date(SUN + n * DAY).toISOString().slice(0, 10), iso = ms => new Date(ms).toISOString(), u = ids.uuid;
    const base = { created_at: iso(SUN - 6 * DAY), updated_at: iso(SUN - DAY), deleted_at: null };
    const checkins = [0, 1, 2, 3, 4, 5, 6].flatMap(n => [ids.me, ids.partner].map((uid, i) => ({ id: u(700 + n * 2 + i), couple_id: ids.couple, user_id: uid, day: D(n - 6), created_at: iso(SUN), updated_at: iso(SUN) })));
    const fightAt = iso(Date.UTC(2026, 9, 21, 16, 0));
    const extra = {
      checkins,
      fight_markers: [{ id: u(800), couple_id: ids.couple, at: fightAt, intensity: 3, created_at: fightAt, updated_at: fightAt }],
      todos: [
        Object.assign({ id: u(801), couple_id: ids.couple, owner_id: ids.me, created_by: ids.me, title: 'Apologize', type: 'response', tally: 0, due_date: null, target: null, item_id: null, fight_marker_id: u(800), done_at: iso(Date.UTC(2026, 9, 21, 20, 0)) }, base),
        Object.assign({ id: u(802), couple_id: ids.couple, owner_id: ids.me, created_by: ids.me, title: 'Overdue thing', type: 'task', tally: 0, due_date: D(-5), target: null, item_id: null, fight_marker_id: null, done_at: null }, base),
      ],
      items: [Object.assign({ id: u(803), couple_id: ids.couple, sender_id: ids.partner, recipient_id: ids.me, kind: 'focus', body: 'Unopened focus', status: 'delivered', delivered_at: iso(Date.UTC(2026, 9, 20, 16, 0)), opened_at: null, held_until: null, ask_type: null, due_date: null, target: null, origin: null, response_type: null }, base)],
    };
    const p = await open(b, web, { w: 428, h: 926, dsf: 2, clock: new Date(SUN), fx: { now: SUN, coupleAt: iso(Date.UTC(2026, 9, 19, 16, 0)), extra, noCheckins: true, noFights: true } });
    await p.evaluate(() => { window.__plays = []; const m = Motion, f = m.play; m.play = function (k) { window.__plays.push(k); return f.apply(this, arguments); }; });
    check('Sunday: week card on Home', /week/i.test(await p.locator('[data-a="go:week"]').innerText()));
    await clk(p, 'go:week'); await p.waitForTimeout(300);
    const t = (await text(p)).replace(/\s+/g, ' ');
    const has = (re, label) => check('week close: ' + label, re.test(t), t.slice(0, 400));
    has(/\+15\s*Calm day/i, 'calm days +15 (5 of 7, fight on Wednesday)');
    has(/\+10\s*7 of 7 check-ins/i, '7 of 7 check-ins +10');
    has(/\+5\s*Repair within 48h/i, 'repair within 48h +5');
    has(/-3\s*To do overdue|−3\s*To do overdue/i, 'overdue -3');
    has(/-1\s*Focus unopened|−1\s*Focus unopened/i, 'unopened Focus -1');
    await clk(p, 'weekdone'); await p.waitForTimeout(300);
    const plays = await p.evaluate(() => window.__plays);
    const inked = () => p.evaluate(() => { const c = document.getElementById('fx'), d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; for (let i = 3; i < d.length; i += 4) if (d[i]) return true; return false; });
    await p.waitForTimeout(500 - 300);
    check('week animation is drawing at 0.5s', await inked());
    await p.waitForTimeout(2100 - 500);
    check('week animation is finished by 2.1s', !(await inked()));
    check('Done plays the week animation once', plays.filter(k => k === 'week').length === 1, plays);
    check('week card gone after Done', (await p.locator('[data-a="go:week"]').count()) === 0);
    await p.context().close();
  }
} finally { await b.close(); }
console.log(`${total - failed}/${total} passed`);
process.exit(failed ? 1 : 0);

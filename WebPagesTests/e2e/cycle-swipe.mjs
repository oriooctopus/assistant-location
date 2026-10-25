// Left-edge back swipe on the real Cycle page (offline fixture). Chromium dispatches real touch input via CDP;
// WebKit (CYCLE_WEBKIT_EXEC + CYCLE_WEBKIT_PW) can only tap, so there the touch events are synthesized.
// Usage: node cycle-swipe.mjs
import { launch, open, WEB } from './cycle-fixture.mjs';

const web = process.env.CYCLE_WEB || WEB, webkit = !!process.env.CYCLE_WEBKIT_EXEC;
let failed = 0, total = 0;
function check(name, ok, detail) { total++; if (!ok) failed++; console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : '  ' + (detail === undefined ? '' : JSON.stringify(detail)))); }
const clk = (p, a) => p.click(`[data-a="${a}"]`);
const onHome = p => p.locator('[data-a="row:send"]').count().then(n => n > 0);
const NOW = Date.UTC(2026, 9, 22, 1, 0); // Wednesday 21:00 NY, so the check-in card shows

async function touch(p, type, x, y) {
  if (!webkit) {
    p.cdp ||= await p.context().newCDPSession(p);
    return p.cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y }] });
  }
  await p.evaluate(([type, x, y]) => {
    const name = { touchStart: 'touchstart', touchMove: 'touchmove', touchEnd: 'touchend' }[type];
    const e = new Event(name, { bubbles: true, cancelable: true }), t = { identifier: 1, clientX: x, clientY: y, target: document.elementFromPoint(x, y) };
    Object.defineProperty(e, 'touches', { value: name === 'touchend' ? [] : [t] }); Object.defineProperty(e, 'changedTouches', { value: [t] });
    (t.target || document.body).dispatchEvent(e);
  }, [type, x, y]);
}
// Drag from (x0,y0) by (dx,dy) in `steps` moves, `gap` ms apart (real time, so velocity is real).
async function swipe(p, x0, y0, dx, dy, { steps = 8, gap = 16 } = {}) {
  await touch(p, 'touchStart', x0, y0);
  for (let i = 1; i <= steps; i++) { await touch(p, 'touchMove', x0 + dx * i / steps, y0 + dy * i / steps); await p.waitForTimeout(gap); }
  await touch(p, 'touchEnd', x0 + dx, y0 + dy);
}
const inline = p => p.evaluate(() => { const s = document.querySelector('.phone').style; return { transform: s.transform, opacity: s.opacity, transition: s.transition }; });
// The faked clock (needed only for the check-in card) also skews Event.timeStamp, which the page's flick-velocity reads: use it only there.
const fresh = async (fx, run, clock) => { const p = await open(b, web, { w: 390, h: 844, dsf: 2, touch: true, fx: Object.assign(clock ? { now: NOW } : {}, fx), clock: clock ? new Date(NOW) : undefined }); if (run) await run(p); await p.waitForTimeout(250); return p; };
const FULL = { steps: 8, gap: 16 }; // 300px in ~130ms: far past 1/3 width

const b = await launch();
try {
  let p = await fresh({ noCheckins: true }, p => clk(p, 'go:today'), true);
  check('1 setup: on check-in screen without back button', await p.locator('.p2.s1').count() === 1 && await p.locator('[data-a="back"]').count() === 0);
  await swipe(p, 5, 400, 300, 0, FULL); await p.waitForTimeout(500);
  check('1 Today: edge swipe returns to Home', await onHome(p) && await p.locator('.p2.s1').count() === 0);
  check('1 Today: inline styles cleared after navigation', JSON.stringify(await inline(p)) === JSON.stringify({ transform: '', opacity: '', transition: '' }), await inline(p));
  await p.context().close();

  p = await fresh({}, p => clk(p, 'row:send'));
  check('2 setup: on Send', await p.locator('.p2.sd').count() === 1);
  await swipe(p, 5, 400, 300, 0, FULL); await p.waitForTimeout(500);
  check('2 Send: edge swipe returns to Home', await onHome(p) && await p.locator('.p2.sd').count() === 0);
  await p.context().close();

  p = await fresh({}, async p => { await clk(p, 'go:points'); await clk(p, 'go:shop'); });
  const shopHtml = await p.locator('#app').innerHTML();
  check('2 chain setup: shop is two deep (Home > Points > Shop)', !(await onHome(p)) && await p.locator('[data-a="go:shop"]').count() === 0);
  await swipe(p, 5, 400, 300, 0, FULL); await p.waitForTimeout(500);
  check('2 chain: one swipe goes up exactly one level (Points, not Home, not Shop)', (await p.locator('#app').innerHTML()) !== shopHtml && !(await onHome(p)) && await p.locator('[data-a="go:shop"]').count() === 1);
  await swipe(p, 5, 400, 300, 0, FULL); await p.waitForTimeout(500);
  check('2 chain: second swipe reaches Home', await onHome(p));
  await p.context().close();

  p = await fresh({}, p => clk(p, 'row:send'));
  await touch(p, 'touchStart', 5, 400);
  for (let i = 1; i <= 6; i++) { await touch(p, 'touchMove', 5 + 10 * i, 400); await p.waitForTimeout(60); }
  const mid = await inline(p);
  await touch(p, 'touchEnd', 65, 400); await p.waitForTimeout(400);
  check('3 short slow swipe: stays on Send', await p.locator('.p2.sd').count() === 1);
  check('3 short slow swipe: phone was displaced mid-gesture', mid.transform !== '', mid);
  check('3 short slow swipe: inline transform/opacity/transition cleared', JSON.stringify(await inline(p)) === JSON.stringify({ transform: '', opacity: '', transition: '' }), await inline(p));
  await p.context().close();

  p = await fresh({}, p => clk(p, 'row:send'));
  await swipe(p, 100, 400, 250, 0, FULL); await p.waitForTimeout(500);
  check('4 swipe from x=100: no navigation, no transform', await p.locator('.p2.sd').count() === 1 && (await inline(p)).transform === '');
  await p.context().close();

  p = await fresh({}, p => clk(p, 'row:send'));
  await swipe(p, 5, 300, 20, 250, FULL); await p.waitForTimeout(500);
  check('5 mostly-vertical drag from edge: no navigation, no transform', await p.locator('.p2.sd').count() === 1 && (await inline(p)).transform === '', await inline(p));
  await p.context().close();

  p = await fresh({});
  await swipe(p, 5, 400, 300, 0, FULL); await p.waitForTimeout(500);
  check('6 Home (tab root): edge swipe does nothing, no transform', await onHome(p) && JSON.stringify(await inline(p)) === JSON.stringify({ transform: '', opacity: '', transition: '' }), await inline(p));
  await p.context().close();

  p = await fresh({}, p => clk(p, 'row:send'));
  await swipe(p, 5, 400, 60, 0, { steps: 6, gap: 60 }); await p.waitForTimeout(400);
  await p.locator('[data-a="go:held"]').click(); await p.waitForTimeout(300);
  check('7 tap after a swipe still works (Send > Held)', await p.locator('.p2.sd').count() === 0 && !(await onHome(p)));
  await p.context().close();
} finally { await b.close(); }
console.log(`${total - failed}/${total} passed (${webkit ? 'webkit' : 'chromium'})`);
process.exit(failed ? 1 : 0);

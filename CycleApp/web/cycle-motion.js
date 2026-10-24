// Cycle motion: canvas particle effects ported from the approved motion mockup.
// The mockup drew into one canvas per card; the app draws into ONE fixed full-viewport
// overlay (#fx) and positions effects from the real elements' bounding rects.
// Each effect is <= 800ms (week close <= 2000ms). Under prefers-reduced-motion no effect
// runs at all: the UI has already switched to its end state, so "jump to end" is the default.
var Motion = (function () {
'use strict';

const RM = matchMedia('(prefers-reduced-motion: reduce)');
const $ = (r, s) => r.querySelector(s);
const NOW = () => performance.now();
const PK = '#ff2e88', COLS = ['#ff2e88', '#ffffff', '#ff7ab3', '#ffc4dd'];
const HPD = 'M24 40.5S8 31 8 19.6A8.6 8.6 0 0 1 24 15a8.6 8.6 0 0 1 16 4.6C40 31 24 40.5 24 40.5z';
const HP = new Path2D(HPD);
const FIGHT_HP = new Path2D('M20 41s-14-7.8-14-17.4A7 7 0 0 1 20 20.2a7 7 0 0 1 14 3.4C34 33.2 20 41 20 41z');
const rnd = (a, b) => a + Math.random() * (b - a), pick = a => a[Math.random() * a.length | 0];
const clamp = (v, a = 0, b = 1) => Math.max(a, Math.min(b, v));
const eIn = k => k * k * k, eOut = k => 1 - Math.pow(1 - k, 3), eIO = k => k < .5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2;
const eBack = k => { const c = 2.4; return 1 + (c + 1) * Math.pow(k - 1, 3) + c * Math.pow(k - 1, 2); };

/* ---------- drawing ---------- */
function heart(c, x, y, s, r, col, a, stroke) {
  if (a <= 0 || s <= .2) return;
  const k = s / 32;
  c.save(); c.globalAlpha = a; c.translate(x, y); c.rotate(r); c.scale(k, k); c.translate(-24, -27);
  c.fillStyle = col; c.fill(HP);
  if (stroke) { c.lineWidth = 2.2 / k; c.strokeStyle = stroke; c.stroke(HP); }
  c.restore();
}
function arrow(c, x, y, ang, len, a = 1, sc = 1) {
  if (a <= 0) return;
  c.save(); c.globalAlpha = a; c.translate(x, y); c.rotate(ang); c.scale(sc, sc); c.lineCap = 'round'; c.lineJoin = 'round';
  c.beginPath(); c.moveTo(-len, 0); c.lineTo(-10, 0);
  c.strokeStyle = '#0a0a0a'; c.lineWidth = 6.4; c.stroke(); c.strokeStyle = '#fff'; c.lineWidth = 2.8; c.stroke();
  c.beginPath(); c.moveTo(3, 0); c.lineTo(-15, -7); c.lineTo(-15, 7); c.closePath();
  c.fillStyle = '#fff'; c.fill(); c.lineWidth = 1.5; c.strokeStyle = '#0a0a0a'; c.stroke();
  c.beginPath(); c.moveTo(-len + 13, 0); c.lineTo(-len + 3, -7); c.lineTo(-len - 7, -7); c.lineTo(-len + 2, 0); c.lineTo(-len - 7, 7); c.lineTo(-len + 3, 7); c.closePath();
  c.fillStyle = PK; c.fill(); c.lineWidth = 1.3; c.stroke();
  c.restore();
}
function bow(c, x, y, H, pull, a, flex) {
  if (H <= 1 || a <= 0) return;
  c.save(); c.globalAlpha = a; c.lineCap = 'round';
  const tx = x - flex * 9, R = H * .5 + flex * 7;
  c.beginPath(); c.moveTo(tx, y - H); c.quadraticCurveTo(x + R * 2, y, tx, y + H);
  c.strokeStyle = '#0a0a0a'; c.lineWidth = 8; c.stroke(); c.strokeStyle = '#fff'; c.lineWidth = 4.2; c.stroke();
  c.beginPath(); c.moveTo(tx, y - H); c.lineTo(x - pull, y); c.lineTo(tx, y + H);
  c.strokeStyle = '#0a0a0a'; c.lineWidth = 1.8; c.stroke();
  c.restore();
  heart(c, (tx + x + 2 * R) / 2 + 2, y, 15, 0, PK, a, '#fff');
}
function hourglass(c, x, y, H, a) {
  if (H <= 1 || a <= 0) return;
  const W = H * .66, t = y - H / 2, b = y + H / 2;
  c.save(); c.globalAlpha = a; c.lineCap = 'round'; c.lineJoin = 'round';
  c.beginPath(); c.moveTo(x - W * .42, t + H * .07); c.lineTo(x + W * .42, t + H * .07); c.lineTo(x + W * .05, y); c.lineTo(x + W * .42, b - H * .07); c.lineTo(x - W * .42, b - H * .07); c.lineTo(x - W * .05, y); c.closePath();
  c.fillStyle = '#0a0a0a'; c.fill(); c.strokeStyle = '#fff'; c.lineWidth = Math.max(1.2, H * .045); c.stroke();
  c.beginPath(); c.moveTo(x - W / 2, t); c.lineTo(x + W / 2, t); c.moveTo(x - W / 2, b); c.lineTo(x + W / 2, b);
  c.strokeStyle = PK; c.lineWidth = Math.max(1.6, H * .08); c.stroke();
  c.restore();
}


/* ---------- overlay scene ---------- */
const cv = document.getElementById('fx');
const S = { cv, ctx: cv.getContext('2d'), A: [], P: [], raf: 0, last: 0, w: 0, h: 0, d: 1 };
function size() { S.d = devicePixelRatio || 1; S.w = innerWidth; S.h = innerHeight; cv.width = S.w * S.d; cv.height = S.h * S.d; }
addEventListener('resize', size); size();
const rect = el => { const r = el.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height, cx: r.left + r.width / 2, cy: r.top + r.height / 2 }; };
function actor(fn) { const a = { fn, t0: NOW() }; S.A.push(a); run(); return a; }
function emit(list) { list.forEach(p => { p.age = 0; p.a = 1; S.P.push(p); }); run(); }
function run() { if (RM.matches || S.raf) return; S.last = NOW(); S.raf = requestAnimationFrame(frame); }
function frame() {
  const now = NOW(), dt = Math.min(.034, (now - S.last) / 1000); S.last = now;
  step(S, dt, now); draw(S, now);
  S.raf = (S.A.length || S.P.length) ? requestAnimationFrame(frame) : 0;
}
function step(s, dt, now) {
  s.P = s.P.filter(p => {
    if (p.tw) {
      const k = clamp((now - p.tw.t0) / p.tw.d); if (k <= 0) return true;
      const e = eIO(k); p.x = p.tw.x0 + (p.tw.x1 - p.tw.x0) * e; p.y = p.tw.y0 + (p.tw.y1 - p.tw.y0) * e - Math.sin(Math.PI * e) * p.tw.lift;
      p.r = p.tw.r0 * (1 - e); p.s = p.tw.s0 + (p.tw.s1 - p.tw.s0) * e; return k < 1;
    }
    p.age += dt * 1000;
    if (!p.rest) {
      p.vy += (p.g || 0) * dt;
      if (p.drag) { const f = Math.exp(-p.drag * dt); p.vx *= f; p.vy *= f; }
      p.x += p.vx * dt; p.y += p.vy * dt; p.r += (p.vr || 0) * dt;
      if (p.walls) { if (p.x < p.walls[0]) { p.x = p.walls[0]; p.vx *= -.4; } if (p.x > p.walls[1]) { p.x = p.walls[1]; p.vx *= -.4; } }
      if (p.floor != null && p.y >= p.floor) {
        p.y = p.floor;
        if (p.vy > 140) { p.vy *= -.28; p.vx *= .6; p.vr *= .5; } else { p.rest = true; p.vy = p.vx = p.vr = 0; }
      }
    }
    if (p.life) { const f = p.fade || .4, k = p.age / p.life; p.a = k < 1 - f ? 1 : clamp((1 - k) / f); return k < 1; }
    return true;
  });
}
function draw(s, now) {
  const c = s.ctx; c.setTransform(s.d, 0, 0, s.d, 0, 0); c.clearRect(0, 0, s.w, s.h);
  s.A = s.A.filter(a => !a.dead && a.fn(c, now - a.t0) !== false);
  for (const p of s.P) {
    const g = p.pop ? eBack(clamp(p.age / p.pop)) : 1;
    heart(c, p.x, p.y, p.s * g, p.r, p.c, p.a, p.stroke);
  }
}
const hp = o => Object.assign({ x: 0, y: 0, vx: 0, vy: 0, g: 0, r: rnd(-.6, .6), vr: rnd(-9, 9), s: 8, c: pick(COLS) }, o);
function burst(x, y, n, o = {}) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const a = rnd(0, Math.PI * 2), sp = rnd(o.min ?? 150, o.max ?? 500);
    out.push(hp({ x, y, vx: Math.cos(a) * sp, vy: Math.sin(a) * sp - (o.up || 0), g: o.g ?? 1200, s: rnd(o.s0 || 5, o.s1 || 11), life: rnd(o.l0 || 400, o.l1 || 700), fade: .45, pop: o.pop, vr: rnd(-9, 9) }));
  }
  return out;
}
const restart = (el, cls) => { el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls); };

/* ---------- the effects ---------- */
const FX = {
  // Arrow released from the button, flies off the top-right, hearts pop where it left.
  send(btn) {
    restart(btn, 'press');
    const b = rect(btn), L = 70;
    actor((c, ms) => {
      if (ms > 360) return false;
      const k = clamp(ms / 300), x = b.cx + eIn(k) * (S.w - b.cx + L), y = b.cy - eIn(k) * (b.cy - 40);
      const g = c.createLinearGradient(x - L - 120 * k, y, x - L, y); g.addColorStop(0, 'rgba(255,46,136,0)'); g.addColorStop(1, PK);
      c.fillStyle = g; c.fillRect(x - L - 120 * k, y - 2, 120 * k, 4);
      arrow(c, x, y, -Math.atan2(b.cy - 40, S.w - b.cx) * eIn(k) * .5, L);
    });
    setTimeout(() => emit(Array.from({ length: 12 }, () => hp({ x: b.x + rnd(24, b.w - 24), y: b.cy + rnd(-12, 12), vx: rnd(-150, 150), vy: rnd(-420, -200), g: 2000, s: rnd(10, 15), life: rnd(400, 440), fade: .35, pop: 90 }))), 360);
  },
  // Arrow flies from the button into the hourglass, which flips and sparkles.
  hold(btn, glass) {
    restart(btn, 'press');
    const b = rect(btn), h = glass ? rect(glass) : { cx: b.cx, cy: b.cy - 80 }, L = 60;
    actor((c, ms) => {
      if (ms > 700) return false;
      if (ms < 220) { const k = eOut(ms / 220); arrow(c, b.cx + (h.cx - b.cx) * k, b.cy + (h.cy - b.cy) * k, Math.atan2(h.cy - b.cy, h.cx - b.cx), L, 1 - k * .6); return; }
      const k = clamp((ms - 220) / 360), th = eIO(k) * Math.PI;
      c.save(); c.translate(h.cx, h.cy); c.rotate(th); hourglass(c, 0, 0, 34 * (1 + .3 * Math.sin(Math.PI * k)), 1 - clamp((ms - 600) / 100)); c.restore();
    });
    setTimeout(() => emit(burst(h.cx, h.cy, 8, { min: 80, max: 240, g: 300, s0: 4, s1: 8, l0: 250, l1: 380 })), 480);
  },
  // Hearts rise from the button and a big one pops.
  kudos(btn) {
    restart(btn, 'press');
    const b = rect(btn);
    emit(Array.from({ length: 16 }, () => hp({ x: b.cx + rnd(-40, 40), y: b.cy, vx: rnd(-120, 120), vy: rnd(-520, -260), g: 900, s: rnd(10, 18), life: rnd(520, 760), fade: .4, pop: 120 })));
    actor((c, ms) => { if (ms > 620) return false; heart(c, b.cx, b.cy - 70 - ms * .05, 54 * eBack(clamp(ms / 220)), 0, PK, 1 - clamp((ms - 420) / 200), '#fff'); });
  },
  // Fight logged: a heart cracks down the middle and the halves fall apart.
  crack(btn) {
    const b = rect(btn), x = b.cx, y = b.cy - 90;
    actor((c, ms) => {
      if (ms > 760) return false;
      const a = 1 - clamp((ms - 520) / 240);
      if (ms < 300) { const s = 64 * eBack(clamp(ms / 160)); heart(c, x, y, s, 0, PK, 1, '#fff'); c.save(); c.globalAlpha = 1; c.strokeStyle = '#0a0a0a'; c.lineWidth = 3; c.lineJoin = 'round'; c.beginPath(); c.moveTo(x, y - s * .45); const n = clamp((ms - 120) / 150); const pts = [[x - 6, y - s * .2], [x + 5, y], [x - 5, y + s * .2], [x + 2, y + s * .45]]; pts.slice(0, Math.ceil(n * pts.length)).forEach(p => c.lineTo(p[0], p[1])); c.stroke(); c.restore(); return; }
      const k = eIn(clamp((ms - 300) / 460));
      [-1, 1].forEach(sd => { c.save(); c.beginPath(); c.rect(sd < 0 ? x - 80 : x, y - 80, 80, 200); c.clip(); heart(c, x + sd * 22 * k, y + 120 * k, 64, sd * .9 * k, PK, a, '#fff'); c.restore(); });
    });
  },
  // Task done: ring of hearts plus a drawn tick.
  todo(el) {
    const b = rect(el);
    emit(burst(b.cx, b.cy, 10, { min: 120, max: 330, g: 700, s0: 5, s1: 10, l0: 380, l1: 560 }));
    actor((c, ms) => {
      if (ms > 520) return false;
      const k = clamp(ms / 260); c.save(); c.globalAlpha = 1 - clamp((ms - 380) / 140); c.lineCap = 'round'; c.lineJoin = 'round';
      c.beginPath(); c.moveTo(b.cx - 11, b.cy + 1); const m = clamp(k * 2); c.lineTo(b.cx - 11 + 7 * Math.min(m, 1), b.cy + 1 + 8 * Math.min(m, 1));
      if (k > .5) { const q = (k - .5) * 2; c.lineTo(b.cx - 4 + 17 * q, b.cy + 9 - 21 * q); }
      c.strokeStyle = '#0a0a0a'; c.lineWidth = 8; c.stroke(); c.strokeStyle = '#fff'; c.lineWidth = 4; c.stroke(); c.restore();
    });
  },
  // Points earned: +N floats up with a few hearts.
  points(el, n) {
    const b = rect(el), txt = (n > 0 ? '+' : '\u2212') + Math.abs(n), col = n > 0 ? '#fff' : PK;
    if (n > 0) emit(burst(b.cx, b.cy, 6, { min: 80, max: 220, g: 500, s0: 4, s1: 8, l0: 300, l1: 480 }));
    actor((c, ms) => {
      if (ms > 700) return false;
      c.save(); c.globalAlpha = 1 - clamp((ms - 450) / 250); c.font = '26px "Archivo Black"'; c.textAlign = 'center'; c.lineWidth = 6; c.strokeStyle = '#0a0a0a'; c.fillStyle = col;
      const y = b.cy - eOut(clamp(ms / 700)) * 64; c.strokeText(txt, b.cx, y); c.fillText(txt, b.cx, y); c.restore();
    });
  },
  // Week close: hearts rain across the whole screen, <= 1.95s.
  week() {
    const t0 = NOW();
    actor((c, ms) => {
      if (ms > 1950) return false;
      if (ms < 1000 && Math.random() < .7) emit(Array.from({ length: 2 }, () => hp({ x: rnd(0, S.w), y: -20, vx: rnd(-40, 40), vy: rnd(120, 320), g: 500, s: rnd(10, 20), life: rnd(700, 900), fade: .3 })));
    });
  },
  // Rejected action: the element shakes.
  jiggle(el) { restart(el, 'jig'); }
};
function play(name, a, b) {
  if (!FX[name]) throw new Error('unknown motion ' + name);
  if (RM.matches) return;
  FX[name](a, b);
}
return { play: play, reduced: () => RM.matches };
})();

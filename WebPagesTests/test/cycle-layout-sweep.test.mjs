// Generic layout sweep: every Cycle screen and the main sheets, seeded with realistic content and a 14-char partner
// name ("Alexandria Rae"), at 375 and 430px. Each one is checked for the CLASS of bug that keeps shipping one at a time
// (see CycleApp/web/LAYOUT.md): glyphs spilling out of their control, overlapping sibling controls, horizontal overflow,
// content jammed under the pink band, undersized tap targets. Add every new screen or sheet to SCENARIOS below.
// WebKit only (WKWebView parity): needs GL_WEBKIT_PW / GL_WEBKIT_EXEC. LAYOUT_SHOTS=<dir> writes <screen>-<width>.png.
import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HAS_WK = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);
const pw = HAS_WK ? await import(process.env.GL_WEBKIT_PW) : null;
const URL_ = 'file://' + path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/index.html');
const CSS = fs.readFileSync(fileURLToPath(new URL('../../CycleApp/web/cycle.css', import.meta.url)), 'utf8') + '\n#fx{display:none}';
const SHOTS = process.env.LAYOUT_SHOTS;
if (SHOTS) fs.mkdirSync(SHOTS, { recursive: true });

// Minimum distance (px) from the bottom of the header (.hd) to the top of the first content under it.
// Measured on the existing screens at 375 and 430: Auth, Setup, Fight detail, Nudge screens, Acks use 22 (the .p2 main gap);
// Home and Points 28, Cycle 24. Tap-target height is deliberately not swept: tags, plus and points chips are small by design.
const BAND_GAP = 22;
const PILL_INSET = 4; // min px between a pill's glyphs and its left/right edge

const ME = 'u-me', HER = 'u-her', PARTNER = 'Alexandria Rae';
const NOW = '2026-10-21T15:00:00Z'; // Wed 11:00 New York
const iso = (hoursAgo) => new Date(Date.parse(NOW) - hoursAgo * 36e5).toISOString();
const base = { couple_id: 'c1', created_at: iso(72), updated_at: iso(72), deleted_at: null };
const td = (id, o) => ({ ...base, id, owner_id: ME, created_by: ME, item_id: null, fight_marker_id: null, title: id, description: null, type: 'task',
  due_date: null, target: null, period: null, points_earn: null, points_miss: null, needs_note: false, edited_at: null, tally: 0, done_at: null, ...o });
const item = (id, o) => ({ ...base, id, sender_id: ME, recipient_id: HER, kind: 'ask', body: id, ask_type: 'task', description: null, due_date: null, target: null,
  period: null, points_earn: null, points_miss: null, needs_note: false, origin: null, response_type: null, fight_marker_id: null,
  held_until: new Date(Date.parse(NOW) + 45 * 6e4).toISOString(), status: 'held', delivered_at: null, opened_at: null, kept: null, ...o });
const nudge = (id, body, o) => ({ ...base, id, author_id: ME, body, tag: 'Calm', pinned: false, sort_order: 0, archived_at: null, ...o });

const TODOS = [
  td('t-mine', { title: 'Book the dentist appointment', description: 'Ask about the Tuesday slot', due_date: '2026-10-23' }),
  td('t-habit', { title: 'Stretch for ten minutes every morning', type: 'habit', target: 3, period: 'week' }),
  td('t-month', { title: 'Call mum', type: 'habit', target: 20, period: 'month' }),
  td('t-from-her', { title: 'Take the bins out', created_by: HER }),
  td('t-resp', { title: 'Apologise', type: 'response', created_by: HER }),
  td('t-note', { title: 'Water the plants', needs_note: true }),
  td('t-hers', { title: 'Renew the car insurance', owner_id: HER, created_by: ME, due_date: '2026-10-25' }),
  td('t-hers-h', { title: 'Run', owner_id: HER, created_by: ME, type: 'habit', target: 2, period: 'day' }),
];
const SHARED = {
  couple: { id: 'c1', tz: 'America/New_York', created_at: '2026-01-01T00:00:00Z', hold_ask_min: 60 },
  members: [{ user_id: ME, name: 'Me', checkin_time: '21:00' }, { user_id: HER, name: PARTNER, checkin_time: '21:00' }],
  rows: {
    items: Object.fromEntries([item('i-held', { body: 'Clean the kitchen before Sunday dinner' }),
      item('i-ready', { body: 'Pick up the parcel', held_until: iso(1) })].map((r) => [r.id, r])),
    todos: Object.fromEntries(TODOS.map((r) => [r.id, r])),
    todo_events: { e1: { ...base, id: 'e1', todo_id: 't-habit', user_id: ME, kind: 'tally', at: iso(2), note: null } },
    checkins: {},
    fight_markers: { fm1: { ...base, id: 'fm1', logged_by: ME, at: iso(30), repaired_at: null, hit_self: false, hit_related: false, intensity: 3 },
      fm2: { ...base, id: 'fm2', logged_by: HER, at: iso(5), repaired_at: null, hit_self: null, hit_related: null, intensity: 2 } },
    fight_notes: { fn1: { ...base, id: 'fn1', fight_marker_id: 'fm1', author_id: ME, body: 'I raised my voice about the dishes' } },
    rewards: { r1: { ...base, id: 'r1', name: 'Breakfast in bed', price: 40, archived: false }, r2: { ...base, id: 'r2', name: 'Pick the next film', price: 120, archived: false } },
    redemptions: { rd1: { ...base, id: 'rd1', reward_id: 'r1', requested_by: HER, status: 'pending', price: 40, decided_by: null, decided_at: null } },
    nudges: { n1: nudge('n1', 'You are doing fine, take a breath'), n2: nudge('n2', 'Done one', { done_at: iso(20) }) },
    nudge_sends: { s1: { ...base, id: 's1', nudge_id: 'n1', sender_id: HER, recipient_id: ME, body: 'You are doing fine', deliver_at: iso(3), opened_at: null } },
    nudge_replies: {},
    nudge_awards: { aw1: { ...base, id: 'aw1', author_id: ME, recipient_id: HER, nudge_id: 'n2', body: 'Done one', points: 30, payout: '3mo', done_at: iso(20), stopped_at: null } },
    acks: { a1: { ...base, id: 'a1', author_id: HER, requested_by: null, item_id: null, title: 'I went quiet', description: null, status: 'done', done_at: iso(4), read_at: null },
      a2: { ...base, id: 'a2', author_id: HER, requested_by: ME, item_id: null, title: 'Ask me about Friday', description: null, status: 'open', done_at: null, read_at: null } },
  },
  cursors: {}, outbox: [],
};
const seed = (couple) => ({
  session: { access_token: 't', refresh_token: 'r', expires_at: 4102444800, user: { id: ME, email: 'me@x.test' } },
  ['shared.' + ME]: couple ? SHARED : { couple: null, members: [], rows: {}, cursors: {}, outbox: [] },
  ['priv.' + ME]: { fights: [{ id: 'f1', at: iso(30), intensity: 3 }, { id: 'f2', at: iso(24 * 20), intensity: 2 }], affirmations: [], prefs: {},
    queued: [{ body: 'Pick up milk on the way home' }], nudges: [], nudge_sends: [] },
});

// Each scenario is a sequence of data-a actions fired from the Today tab. `signedOut`/`setup` use their own seed.
const SCENARIOS = [
  ['auth', { seed: 'auth' }], ['setup', { seed: 'setup' }],
  ['home', []], ['todo', ['tab:todo']],
  ['todo-new-task', ['tab:todo', 'newtodo']], ['todo-new-task-me', ['tab:todo', 'newtodo', 'nfor:me']],
  ['todo-new-habit', ['tab:todo', 'newtodo', 'nkind:habit']], ['todo-new-habit-month', ['tab:todo', 'newtodo', 'nkind:habit', 'nper:month']],
  ['todo-edit', ['tab:todo', 'etodo:t-mine']], ['todo-edit-habit', ['tab:todo', 'etodo:t-habit']],
  ['todo-note', ['tab:todo', 'done:t-note']], ['todo-still', ['tab:todo', 'still:i-held']],
  ['fight', ['row:fight']], ['fight-custom', ['row:fight', 'chip:custom']], ['fight-detail', ['row:fight', 'openfight:fm1']],
  ['us', ['tab:us']], ['settings', ['tab:us', 'go:settings']], ['points', ['go:points']], ['shop', ['go:points', 'go:shop']],
  ['shop-redeem', ['go:points', 'go:shop', 'reward:r1']], ['shop-add', ['go:points', 'go:shop', 'addreward']],
  ['week', ['go:week']], ['cycle', ['tab:us', 'go:cycle']],
  ['nudges', ['row:nudges']], ['nudge', ['row:nudges', 'nudge:n1']], ['nudge-done', ['row:nudges', 'nudge:n1', 'nudgedone']],
  ['nudge-incoming', ['nudgein:s1']], ['nudge-new', ['row:nudges', 'nudgenew']],
  ['acks', ['row:ack']], ['ack-new', ['row:ack', 'acknew']], ['ack-request', ['row:ack', 'ackedit:a2']],
];

// Runs in the page. Returns violation strings: "<selector> <what> <numbers>".
function sweepInPage({ bandGap, pillInset: PILL_INSET, probe }) {
  const vw = window.innerWidth, out = [];
  const TEXT = 'button, .seg span, .chip, .pick, .save, .ghost, .tdrop, .done, .go, .pillb, .usb, .bal, .fight, .txtbtn, .back, .cd, .p1b, .hv, ' +
    '.tab b, .tab i, .lab, .lab0, h1, h2, h3, .dl, .tag, .eb, .it .nm, .it .pr, .nc .s, .nc .x, .stp b, .stp span, .tg, .ln .am, .big, .cl .t, small, .frow > span';
  const vis = (e) => { const r = e.getBoundingClientRect(), s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.opacity !== '0' && !e.closest('.band'); };
  const name = (e) => { let s = e.tagName.toLowerCase(); if (e.className && typeof e.className === 'string') s += '.' + e.className.trim().split(/\s+/).join('.'); const a = e.getAttribute('data-a'); if (a) s += `[data-a="${a}"]`;
    const t = (e.textContent || '').trim().slice(0, 18); return s + (t ? ` "${t}"` : ''); };
  const f = (n) => Math.round(n * 10) / 10;
  // A node inside an ellipsised ancestor (a truncated name) is deliberately cut, not overflowing.
  const clipped = (n) => { for (let p = n.parentElement; p && !p.classList.contains('phone'); p = p.parentElement) if (getComputedStyle(p).textOverflow === 'ellipsis') return true; return false; };
  const textRect = (e) => {
    const w = document.createTreeWalker(e, NodeFilter.SHOW_TEXT), rs = [];
    for (let n = w.nextNode(); n; n = w.nextNode()) { if (!n.textContent.trim() || clipped(n)) continue; const r = document.createRange(); r.selectNodeContents(n); for (const q of r.getClientRects()) if (q.width > 0) rs.push(q); }
    return rs.length ? { left: Math.min(...rs.map((q) => q.left)), right: Math.max(...rs.map((q) => q.right)), top: Math.min(...rs.map((q) => q.top)), bottom: Math.max(...rs.map((q) => q.bottom)) } : null;
  };
  // 1. glyphs inside their own element and inside the nearest rounded, bordered or filled ancestor control.
  const box = (e) => e.getBoundingClientRect();
  const frame = (e) => { for (let p = e.parentElement; p && !p.classList.contains('phone'); p = p.parentElement) {
    const s = getComputedStyle(p), bordered = ['Top', 'Right', 'Bottom', 'Left'].some((d) => parseFloat(s['border' + d + 'Width']) > 0 && s['border' + d + 'Style'] !== 'none');
    if (parseFloat(s.borderTopLeftRadius) > 0 && (bordered || s.backgroundColor !== 'rgba(0, 0, 0, 0)') && !p.classList.contains('bs') && !p.classList.contains('scr')) return p; } return null; };
  for (const e of document.querySelectorAll(TEXT)) {
    if (!vis(e)) continue;
    const s = getComputedStyle(e);
    if (s.overflow !== 'visible' || s.textOverflow === 'ellipsis') continue; // deliberate clipping / ellipsis
    const t = textRect(e); if (!t) continue;
    const b = box(e), fr = frame(e);
    // A pill (rounded and filled/bordered) needs breathing room: glyphs touching its left/right edge read as clipped (MONTH in a 52px cell).
    const bordered = ['Top', 'Right', 'Bottom', 'Left'].some((d) => parseFloat(s['border' + d + 'Width']) > 0 && s['border' + d + 'Style'] !== 'none');
    if (parseFloat(s.borderTopLeftRadius) > 0 && (bordered || s.backgroundColor !== 'rgba(0, 0, 0, 0)') && s.display !== 'block') {
      const inL = t.left - b.left, inR = b.right - t.right;
      if (Math.min(inL, inR) < PILL_INSET) out.push(`glyphs of ${name(e)} sit ${f(Math.min(inL, inR))}px from the edge of their own pill (needs >= ${PILL_INSET}px; text ${f(t.left)}..${f(t.right)}, box ${f(b.left)}..${f(b.right)})`);
    }
    for (const [who, r] of [['own box', b], ['ancestor ' + (fr ? name(fr) : ''), fr && box(fr)]]) {
      if (!r) continue;
      const over = { left: r.left - t.left, right: t.right - r.right, top: r.top - t.top, bottom: t.bottom - r.bottom };
      const bad = Object.entries(over).filter(([, v]) => v > 1);
      if (bad.length) out.push(`glyphs of ${name(e)} extend outside ${who} by ${bad.map(([k, v]) => `${k} ${f(v)}px`).join(', ')} (text ${f(t.left)}..${f(t.right)}, box ${f(r.left)}..${f(r.right)})`);
    }
  }
  // 2. sibling controls in a row do not overlap.
  const CTRL = '.seg span, .chip, .pick, .save, .ghost, .tdrop, .done, .go, .pillb, .usb, .bal, .fight, .txtbtn, .p1b, .tab, .stp span, .tg, .it, .hact > *';
  for (const parent of new Set([...document.querySelectorAll(CTRL)].map((e) => e.parentElement))) {
    const kids = [...parent.children].filter((k) => k.matches(CTRL) && vis(k) && getComputedStyle(k).position !== 'absolute');
    for (let i = 0; i < kids.length; i++) for (let j = i + 1; j < kids.length; j++) {
      const a = box(kids[i]), c = box(kids[j]), ox = Math.min(a.right, c.right) - Math.max(a.left, c.left), oy = Math.min(a.bottom, c.bottom) - Math.max(a.top, c.top);
      if (ox > 1 && oy > 1) out.push(`siblings ${name(kids[i])} and ${name(kids[j])} overlap by ${f(ox)}x${f(oy)}px`);
    }
  }
  // 3. no horizontal overflow (the page itself and every element, bar the rotated band and the sheet's dim layer).
  const de = document.documentElement;
  if (de.scrollWidth > vw) out.push(`page scrollWidth ${de.scrollWidth} > viewport ${vw}`);
  for (const e of document.querySelectorAll('.phone *')) {
    if (!vis(e) || clipped(e) || e.closest('.dim, svg, .errbar') || e.tagName === 'INPUT' && e.type === 'date') continue;
    const r = box(e); if (r.right > vw + 1 || r.left < -1) out.push(`${name(e)} spans x ${f(r.left)}..${f(r.right)}, viewport 0..${vw}`);
  }
  // 4. the first content under the header clears the pink band.
  const band = document.querySelector('.band'), hd = document.querySelector('main > .hd');
  if (band && hd && !document.querySelector('.bs')) {
    const first = [...hd.parentElement.children].filter((k) => k !== hd && vis(k))[0];
    if (first) { const gap = box(first).top - box(hd).bottom; if (probe) out.push('PROBE-GAP ' + f(gap) + ' ' + name(first)); if (gap < bandGap) out.push(`first content ${name(first)} is ${f(gap)}px under the header (needs >= ${bandGap}px)`); }
  }
  return out;
}

describe('layout sweep (webkit)', { skip: !HAS_WK && 'needs GL_WEBKIT_PW and GL_WEBKIT_EXEC' }, () => {
  let browser;
  before(async () => { browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC }); });
  after(async () => { await browser.close(); });

  async function open(w, kind) {
    const context = await browser.newContext({ viewport: { width: w, height: 844 }, hasTouch: true });
    await context.clock.setFixedTime(new Date(NOW));
    await context.addInitScript((s) => {
      window.CYCLE_CONFIG = { supabaseUrl: 'https://x.test', supabaseAnonKey: 'k', boxUrl: '' };
      if (!localStorage.getItem('cycle:session')) for (const k in s) localStorage.setItem('cycle:' + k, JSON.stringify(s[k]));
    }, kind === 'auth' ? {} : seed(kind !== 'setup'));
    await context.route('**/cycle.css', (r) => r.fulfill({ contentType: 'text/css', body: CSS }));
    await context.route('https://x.test/**', (r) => r.abort()); // offline: everything comes from the seed
    const page = await context.newPage();
    const errors = []; // a thrown render leaves the previous screen up, which would be swept as if it were the target
    page.on('pageerror', (e) => errors.push(String(e)));
    page.on('console', (m) => m.type() === 'error' && !/config\.js/.test(m.text()) && errors.push('console: ' + m.text()));
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector(kind === 'auth' ? '[data-a="signin"], input[type="email"]' : kind === 'setup' ? 'input[data-d="name"]' : '[data-a="row:fight"]');
    return { context, page, errors };
  }
  // Fires the action through the app's own delegated click handler from an injected [data-a] element (no tab bar needed,
  // and a sheet covering the page cannot intercept it).
  async function act(page, a) {
    await page.evaluate((a) => { const m = document.querySelector('main'); m.insertAdjacentHTML('beforeend', `<span id="sweep-nv" data-a="${a}">x</span>`); const el = document.getElementById('sweep-nv'); el.click(); el.remove(); }, a);
  }

  for (const w of [375, 430]) {
    describe(`${w}px`, () => {
      let main;
      before(async () => { main = await open(w, 'couple'); });
      after(async () => { await main.context.close(); });
      for (const [screen, spec] of SCENARIOS) test(`${screen} at ${w}px`, { timeout: 20000 }, async () => {
        const solo = !Array.isArray(spec);
        const { context, page, errors } = solo ? await open(w, spec.seed) : main;
        try {
          if (!solo) { await act(page, 'tab:home'); for (const a of spec) { await act(page, a); } }
          await page.waitForTimeout(60);
          if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `${screen}-${w}.png`) });
          assert.deepEqual(errors.splice(0), [], `${screen} @ ${w}px threw`);
          const v = await page.evaluate(sweepInPage, { bandGap: BAND_GAP, pillInset: PILL_INSET, probe: !!process.env.PROBE });
          assert.deepEqual(v, [], `${screen} @ ${w}px:\n  ` + v.join('\n  '));
        } finally { if (solo) await context.close(); }
      });
    });
  }
});

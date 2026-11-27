// Space Grotesk draws a straight " like a closing quote, so a typed "Can we talk" read backwards in the composer
// (2026-11-27). cycle.base.css keeps U+0022 out of the font's unicode-range so the system face draws it straight.
// WebKit only (GL_WEBKIT_PW/GL_WEBKIT_EXEC, see ~/.claude/bin/cycle-webkit.sh); skipped without it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../CycleApp/web/');
const haveWebkit = !!(process.env.GL_WEBKIT_PW && process.env.GL_WEBKIT_EXEC);

test('straight double quote is not drawn by Space Grotesk', { skip: !haveWebkit }, async () => {
  const pw = await import(process.env.GL_WEBKIT_PW);
  const browser = await pw.webkit.launch({ headless: true, executablePath: process.env.GL_WEBKIT_EXEC });
  try {
    const page = await browser.newPage();
    await page.goto('file://' + WEB + 'cycle.base.css'); // any same-dir URL so fonts/ resolves
    const w = await page.evaluate(async (base) => {
      document.documentElement.innerHTML = '<head><base href="' + base + '"><link rel="stylesheet" href="cycle.base.css"></head>' +
        '<body class="p2"><span id="a" style="font:500 40px \'Space Grotesk\',sans-serif">""""</span>' +
        '<span id="b" style="font:500 40px sans-serif">""""</span><span id="c" style="font:500 40px \'Space Grotesk\',sans-serif">Ab</span></body>';
      await new Promise((r) => setTimeout(r, 300));
      await document.fonts.load("500 40px 'Space Grotesk'", 'Ab');
      await document.fonts.ready;
      const loaded = [...document.fonts].some((f) => f.family.includes('Space Grotesk') && f.status === 'loaded');
      return { loaded, a: document.getElementById('a').getBoundingClientRect().width, b: document.getElementById('b').getBoundingClientRect().width };
    }, 'file://' + WEB);
    assert.ok(w.loaded, 'Space Grotesk loaded');
    assert.equal(w.a, w.b, 'quotes in a Space Grotesk run render with the fallback face');
  } finally { await browser.close(); }
});

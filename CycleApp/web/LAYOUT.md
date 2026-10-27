# Cycle layout rules

- Labelled list sections come from `section(labelHtml, bodyHtml, cls)` in cycle-ui.js. Never hand-write `<section class="list"><p class="lab">`.
- Spacing under the header comes from shared rules in cycle.css (`.p2 main > .hd + section`). No per-screen margin tweaks to nudge a first section.
- No fixed widths on text-bearing controls (seg cells, chips, pills, buttons). Size to content (`width:auto` plus padding) or flex.
- Truncate long names with the `.pn` ellipsis span (pnx()), never by letting text run past its box.
- Every new screen or sheet is registered in SCENARIOS in WebPagesTests/test/cycle-layout-sweep.test.mjs, with seed data that fills it (long partner name, every kind of row).
- One-off layout tests only for behavior the sweep cannot express (state changes, scroll, animation).

## Sweep

Checks every screen and main sheet at 375 and 430: glyphs inside their own box and rounded ancestor, glyphs at least 4px from a pill's edge, sibling controls not overlapping, nothing past the viewport, first content at least 22px under the header. Tap-target height is not swept (tags, plus and points chips are small by design).

```
cd WebPagesTests
LAYOUT_SHOTS=/tmp/cycle-shots <wrapper> node --test --test-concurrency=2 test/cycle-layout-sweep.test.mjs
```

`<wrapper>` is the WebKit env wrapper (without it the suite skips). Screenshots land as `<scenario>-<width>.png` in the LAYOUT_SHOTS dir. `PROBE=1` prints each screen's measured header gap.

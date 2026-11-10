# Cycle layout rules

- Labelled list sections come from `section(labelHtml, bodyHtml, cls)` in cycle-ui.js. Never hand-write `<section class="list"><p class="lab">`.
- Spacing under the header comes from shared rules in cycle.css (`.p2 main > .hd + section`). No per-screen margin tweaks to nudge a first section.
- No fixed widths on text-bearing controls (seg cells, chips, pills, buttons). Size to content (`width:auto` plus padding) or flex.
- Truncate long names with the `.pn` ellipsis span (pnx()), never by letting text run past its box.
- Every new screen or sheet is registered in SCENARIOS in WebPagesTests/test/cycle-layout-sweep.test.mjs, with seed data that fills it (long partner name, every kind of row).
- Spacing between stacked blocks comes from shared rules (`.p2 .frow` padding, field-gap rules in cycle.css), never per-screen nudges; when the sweep flags a gap, fix the shared rule.
- One-off layout tests only for behavior the sweep cannot express (state changes, scroll, animation).

## Sweep

Checks every screen and main sheet at 375 and 430: glyphs inside their own box and rounded ancestor, glyphs at least 4px from a pill's edge, sibling controls not overlapping, nothing past the viewport, first content at least 22px under the header, and vertical rhythm: stacked blocks measured ink to ink (glyphs, framed boxes, rule lines) with at least 10px between a framed control or a rule and whatever sits above or below it (field label onto its own control and repeated list rows excepted). Header text: every dark glyph in the header (h2, .dl, back label) must lie inside the pink band's rotated shape, else it reads dark on black (the band grows with the header via `.hd::before`; challenge seed title wraps to 4 lines at 375). Tap-target height is not swept (tags, plus and points chips are small by design).

```
cd WebPagesTests
LAYOUT_SHOTS=/tmp/cycle-shots <wrapper> node --test --test-concurrency=2 test/cycle-layout-sweep.test.mjs
```

`<wrapper>` is the WebKit env wrapper (without it the suite skips). Screenshots land as `<scenario>-<width>.png` in the LAYOUT_SHOTS dir. `PROBE=1` prints each screen's measured header gap.

## Talk it through (`.ttk` screen, `.tt-card` entry card on the fight page)
The screen root class is `ttk` (plain `tt` is the older to-do tag chip). Progress strip `.tt-prog`, one `.tt-f` section per field, 44px minimum tap targets (`.tt-q`, `.tt-x`, `.tt-ed .lnk`), 16px rhythm between sections, The primary button lives in `.tt-foot` (sticky bottom:0 above the tab bar, with a fade); the global `.save` rules are deliberately not used. `?` is `.tt-q` (44px target, 26px outlined circle). Step row `.tt-steps`: done steps get a pink bar and check, future steps a lock. The partner's side shows as a dashed pink `.tt-hid` block until revealed. Every text field has a mic and a "Draft saved" marker.

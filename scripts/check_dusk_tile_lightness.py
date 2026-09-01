#!/usr/bin/env python3
"""Assert a dusk More-screen screenshot's tile interior matches the ACTUAL
complaint Oliver filed, not just the translucency mechanism: "the square
items in the main view have this shitty white background."

check_dusk_tile_translucency.py (this directory) proves the tile is tracking
the page's background gradient -- i.e. that surface-translucent/backdrop-blur
reached the page and got applied at all. That check can PASS while the
complaint stays true: dusk-light's `color.surface` is 55% white, translucent
enough to visibly shift between rows (satisfying the gradient-tracking check)
while still measuring as a near-opaque white slab to the eye (~96% HSL
lightness, measured against a real sim-test screenshot -- see below). Two
rounds of this task shipped exactly that: a passing mechanism check next to
an unfixed visual complaint. This script measures the one thing the
complaint is actually about -- how LIGHT the tile reads -- so a regression
back toward "shitty white background" fails loudly even if the gradient
still tracks.

Sample point: same tile interior check_dusk_tile_translucency.py already
uses (that file's own header comment documents how these fractions were
measured against a real 1206x2622 capture) -- top-row, left-column tile,
clear of the icon chip/label/badge/rounded corners. Averaged over a small
patch (not a single pixel) to damp anti-aliasing/compression noise; the real
captures this was tuned against showed a flat, noise-free band at this
point (both the single-pixel and patch-averaged reads agreed to the decimal
place), so a patch average costs nothing here and is safer if a future
capture's compression does introduce some.

Thresholds, and where they came from
-------------------------------------
LIGHT: today's (pre-fix) committed code measured 96.27% HSL lightness at
this point (run 33521527914's more-dusk-light-screen.png, i.e. the exact
"shitty white background" Oliver flagged). The chosen fix -- design-tokens/
tokens.json's dusk-light fx.tile-fill override, "barely-there glass"
(rgba(255,255,255,0.14) fill + a faint edge, the mockup option Oliver
picked from todo-sorter's tile-options gallery) -- measured ~91-93.5%
across several sample points against a headless render of that same
mockup markup (tile-options/index.html, .opt-barely.light .tile). 93.5% is
the threshold: comfortably below today's failing 96.27% (a ~2.8-point
margin any real regression back toward the old opaque fill would blow
through), with a ~1-2 point margin of its own above the treatment's
measured range for render/compression noise.

DARK: Oliver explicitly chose "no change at all" for dusk dark -- he likes
it as-is. Today's committed code measures ~23.7% HSL lightness at this same
point (same run, more-dusk-dark-screen.png). Checked as a BAND, not a
one-sided max like light: dusk-dark carries no fx.tile-fill override at
all (tokens.json's $comment10), so its tile background is still driven by
the untouched surface-translucent path -- this check exists purely to catch
an accidental change creeping in (e.g. a future edit widening dusk-dark's
override by mistake), and a regression there could move the value in
EITHER direction, not just lighter. +/-2.5 points is a tight-but-not-flaky
band around the pinned value: comfortably wider than run-to-run render
noise (0 delta was observed between a single-pixel and patch-averaged read
of the same real capture) while catching any deliberate-or-accidental
change to the treatment.
"""
import sys
import colorsys

LEFT_TILE_X_FRAC = 0.1086
ROW1_Y_FRAC = 0.2403
PATCH_HALF = 4  # samples a (2*PATCH_HALF+1)^2 box, see header comment

LIGHT_MAX_LIGHTNESS = 93.5
DARK_EXPECTED_LIGHTNESS = 23.7
DARK_TOLERANCE = 2.5


def hsl_lightness(rgb):
    r, g, b = (c / 255.0 for c in rgb)
    _, l, _ = colorsys.rgb_to_hls(r, g, b)
    return l * 100.0


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in ("light", "dark"):
        print("ERROR:usage: check_dusk_tile_lightness.py <dusk-more-screen.png> <light|dark>")
        return 0
    try:
        from PIL import Image
    except ImportError as e:
        print(f"ERROR:Pillow not available: {e}")
        return 0

    path, variant = sys.argv[1], sys.argv[2]
    try:
        im = Image.open(path).convert("RGB")
    except Exception as e:
        print(f"ERROR:could not open {path}: {e}")
        return 0

    w, h = im.size
    cx = int(w * LEFT_TILE_X_FRAC)
    cy = int(h * ROW1_Y_FRAC)
    box = (
        max(0, cx - PATCH_HALF), max(0, cy - PATCH_HALF),
        min(w, cx + PATCH_HALF + 1), min(h, cy + PATCH_HALF + 1),
    )
    patch = im.crop(box)
    pixels = list(patch.getdata())
    n = len(pixels)
    avg = tuple(sum(p[i] for p in pixels) / n for i in range(3))
    lightness = hsl_lightness(avg)

    if variant == "light":
        if lightness > LIGHT_MAX_LIGHTNESS:
            print(
                f"MISS:{path} tile interior at ({cx},{cy}) measured {lightness:.2f}% "
                f"HSL lightness (avg colour {tuple(round(c) for c in avg)}) -- above the "
                f"{LIGHT_MAX_LIGHTNESS}% ceiling, i.e. reads as a near-opaque white slab "
                f"again (today's pre-fix code measures ~96.3% here; the barely-there-glass "
                f"fix should measure ~91-93.5%)"
            )
            return 1
    else:
        delta = abs(lightness - DARK_EXPECTED_LIGHTNESS)
        if delta > DARK_TOLERANCE:
            print(
                f"MISS:{path} tile interior at ({cx},{cy}) measured {lightness:.2f}% "
                f"HSL lightness (avg colour {tuple(round(c) for c in avg)}) -- "
                f"{delta:.2f} points away from the pinned dusk-dark value "
                f"({DARK_EXPECTED_LIGHTNESS}%, +/-{DARK_TOLERANCE}); dusk dark must render "
                f"pixel-identical to today, Oliver picked 'no change at all' for it"
            )
            return 1

    print(f"{lightness:.2f}% avg={tuple(round(c) for c in avg)} at ({cx},{cy})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

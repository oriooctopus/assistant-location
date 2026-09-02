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

Sample point: ROW 2, left column (NOT row 1)
------------------------------------------------
Commit e948780 (More grid reorder) made the first grid tile ("Settings")
occupy its own full-width, CENTRED row:
    #gl-grid > .gl-tile:first-child { grid-column: 1/-1; justify-self: center; ... }
Before that commit, row 1 was an ordinary left/right pair and this script
sampled its left tile. After it, row 1 has only one tile and it is centred
in the grid track, so the old row-1 sample x (0.1086 of image width) no
longer falls inside any tile -- it falls on bare page background to the
tile's left. Run 33684983479 measured 17.86% there and MISSED against the
then-pinned 23.7% dark band (see "Original pin, row 1" below): not because
the treatment changed, but because the probe was reading gradient, not
tile. Cross-checked against the previous PASSING run's capture
(33587998704, pre-reorder layout): the same fraction read 23.73% there,
i.e. dead on that original pin -- confirming the regression is in the
sample point, not the render. (The pin itself has since moved to a row-2
value, 25.94 -- see "Current pin, row 2" below; this paragraph is about the
row-1 fraction specifically, not the constant's current value.)

Row 2 (today: Tracker + Upload) is the fix: it is still an ordinary 2-column
row, so its LEFT_TILE_X_FRAC is unchanged and unaffected by whatever row 1's
special-cased first tile does next. Measured directly against real captures
of BOTH runs (1206x2622, both the old and new layout -- identical between
them, confirming row 2's geometry is untouched by the row-1 change):
    row 2 tile, vertical span   : y  930-1449px  (left column x 48-585px,
                                                    same span row 1 used)
    icon chip / label (avoid)   : x ~246-390px
Sample point, same in-tile relative offset the old row-1 point had within
ITS tile (0.4913 down from the tile's top edge -- old tile 375-894px, point
at y=630; new point keeps the same ~0.5 offset into row 2's 930-1449px
span): pixel (130, 1189) -> fractions (0.1086, 0.4538). This ROW2_Y_FRAC is
the same constant check_dusk_tile_translucency.py already used as its
"next-row" comparison point before this fix -- reusing it here (rather than
inventing a slightly different one) means both scripts agree on the single
canonical "row 2, left column, tile interior" coordinate.

Averaged over a small patch (not a single pixel) to damp anti-aliasing/
compression noise; real captures at this point are a flat, noise-free band
(patch stdev 0.0-0.5 per channel, measured below), so the average costs
nothing and is safer if a future capture's compression does introduce some.

The "wrong place, plausible number" guard
-------------------------------------------
The bug above is exactly the dangerous kind: the invalidated row-1 point
still returned a normal-looking float (17.86%), not an error, because the
page background gradient it landed on is ALSO smooth. Tried and rejected:
gating on the small sample patch's own internal variance/spread (this is
the obvious first idea and the one worth ruling out explicitly). Measured
against the real captures: a genuine tile-interior patch has per-channel
stdev ~0.0-0.5 (radius 4) rising only to ~0.2-0.5 at radius 50; the
INVALIDATED row-1 background point measures stdev ~0.5 at radius 4 rising to
~0.5-0.65 at radius 50 -- indistinguishable from the tile at any patch size
that's still small enough to stay inside one tile. The page's gradient is
just as locally smooth as a flat tile fill, so patch-internal variance alone
cannot tell "inside a tile" from "on the background between tiles" here.

What DOES distinguish them: a real tile is a bounded region of near-constant
colour roughly tile-sized (~519px tall); scanning away from a genuine
interior point, you hit a real edge (the tile's own boundary against the
inter-row gap) within about half that height. Scanning away from a point
that's drifted onto open background, there is no such nearby edge -- the
gradient just keeps drifting for hundreds more pixels. Measured on the real
captures:
    row 2 point (130,1189), true tile interior:
        nearest edge walking UP   : 259px  (row 2's top boundary, y=930)
        nearest edge walking DOWN : 260px  (row 2's bottom boundary, y=1449)
    old row-1 point (130,630), now background (the regression this guard
    exists to catch):
        nearest edge walking UP   : 444px  (row 1's real top edge, y=186)
        nearest edge walking DOWN : 300px  (row 2's top edge, y=930)
EDGE_SCAN_WINDOW=280 sits cleanly between the true-positive distances
(259-260px, ~20px of headroom) and the false-positive distances (300px and
444px, ~20px+ of margin on the other side) -- tight enough that a future
layout shift of more than ~20px re-trips this guard, loose enough not to
flake on the true point's exact measured distance. EDGE_DELTA_THRESHOLD=10
matches check_dusk_tile_translucency.py's SAME_COLOUR_TOL: real tile-vs-gap
edges measure 15-19 per channel at max delta (comfortably above it) while
same-tile noise measures 0-5 (comfortably below it).
Only ONE direction needs to find an edge within the window, not both --
translucency.py's row-3 comparison point sits deliberately close to one edge
and far from the other (see that file's header), so requiring both directions
would misfire there; requiring just one still cleanly separates every point
measured above.

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
measured range for render/compression noise. Re-measured at the row-2 point
against both the pre- and post-reorder captures: 90.98% in both -- still
comfortably under the ceiling.

DARK: Oliver explicitly chose "no change at all" for dusk dark -- he likes
it as-is. Checked as a BAND, not a one-sided max like light: dusk-dark
carries no fx.tile-fill override at all (tokens.json's $comment10), so its
tile background is still driven by the untouched surface-translucent path
-- this check exists purely to catch an accidental change creeping in
(e.g. a future edit widening dusk-dark's override by mistake), and a
regression there could move the value in EITHER direction, not just
lighter. +/-2.5 points is a tight-but-not-flaky band: comfortably wider
than run-to-run render noise (0 delta was observed between a single-pixel
and patch-averaged read of the same real capture) while catching any
deliberate-or-accidental change to the treatment. This tolerance is
unchanged by the re-pin below -- the point of re-pinning the centre value
is to restore the margin this band is supposed to have, not to loosen it.

Original pin, row 1 (retired, kept for history): today's (pre-reorder)
committed code measured ~23.7% HSL lightness at the OLD row-1 point (run
33521527914). That number was never a property of "dusk dark" in the
abstract -- it was the lightness of a translucent tile fill specifically
at ROW 1's position on the page's background gradient. The fill is
translucent over a gradient (that's the whole point of surface-
translucent), so the identical, unchanged treatment legitimately reads a
different lightness at a different row.

Current pin, row 2: moving the sample point to row 2 (see above) therefore
REQUIRES re-pinning the expected value -- keeping 23.7 would mean pinning
a row-1 number to a row-2 measurement, which is not "no change at all",
it's comparing two different things. Measured at the row-2 point: 25.94%
HSL lightness, IDENTICAL between run 33684983479 (the failing run, new
centred-first-tile layout) and run 33587998704 (the last passing run, old
layout) -- byte-for-byte the same pixels at (130,1189) in both. That
identity is the proof this re-pin does not hide a regression: dusk dark's
rendering did not change at all between those two runs, only WHERE this
script looks at it did. DARK_EXPECTED_LIGHTNESS is re-pinned to 25.94,
DARK_TOLERANCE stays 2.5 (see above), so this check now has the full
margin it's meant to have again, rather than the 0.26-point sliver left
over from comparing a row-2 read against a row-1 pin.
"""
import sys
import colorsys

LEFT_TILE_X_FRAC = 0.1086
ROW2_Y_FRAC = 0.4538  # row 2 (Tracker/Upload), left column -- see header
PATCH_HALF = 4  # samples a (2*PATCH_HALF+1)^2 box, see header comment

LIGHT_MAX_LIGHTNESS = 93.5
DARK_EXPECTED_LIGHTNESS = 25.94  # row-2 pin -- see header's "Current pin, row 2"
DARK_TOLERANCE = 2.5

# "Is this point actually inside a tile" guard -- see header's "wrong place,
# plausible number" section for how these two numbers were derived from real
# captures (true-edge distances 259-260px vs false-positive distances
# 300-444px; real edge deltas 15-19 vs same-tile noise 0-5).
EDGE_SCAN_WINDOW = 280
EDGE_DELTA_THRESHOLD = 10


def hsl_lightness(rgb):
    r, g, b = (c / 255.0 for c in rgb)
    _, l, _ = colorsys.rgb_to_hls(r, g, b)
    return l * 100.0


def find_nearby_edge(im, cx, cy, h, window=EDGE_SCAN_WINDOW, delta_threshold=EDGE_DELTA_THRESHOLD):
    """Scan up and down from (cx, cy) for a real tile-boundary edge within
    `window` pixels in EITHER direction (not necessarily both -- see header
    comment on why an OR, not an AND). Returns True if this point looks like
    it sits inside a bounded, tile-sized region of near-constant colour
    (i.e. a real tile interior), False if it's floating in open background
    with no boundary nearby (the regression this guard exists to catch).
    """
    anchor = im.getpixel((cx, cy))
    for direction in (-1, 1):
        for step in range(1, window + 1):
            y = cy + direction * step
            if y < 0 or y >= h:
                break
            px = im.getpixel((cx, y))
            if max(abs(a - b) for a, b in zip(px, anchor)) > delta_threshold:
                return True
    return False


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
    cy = int(h * ROW2_Y_FRAC)

    if not find_nearby_edge(im, cx, cy, h):
        print(
            f"MISS:{path} sample point ({cx},{cy}) has no tile-boundary edge "
            f"within {EDGE_SCAN_WINDOW}px in either direction -- it is "
            f"probably no longer inside a tile at all (the More-grid layout "
            f"likely changed again; re-measure the tile coordinates against "
            f"a real capture instead of trusting this fraction)"
        )
        return 1

    box = (
        max(0, cx - PATCH_HALF), max(0, cy - PATCH_HALF),
        min(w, cx + PATCH_HALF + 1), min(h, cy + PATCH_HALF + 1),
    )
    # getpixel() per coordinate, not crop()+getdata(): getdata() is
    # deprecated as of Pillow 12 (removed in 14, 2027-10-15) in favour of
    # get_flattened_data(), which doesn't exist on older Pillow -- pinning
    # to whichever name is right for the installed version isn't worth it
    # when getpixel() (already this repo's convention, see
    # check_dusk_tile_translucency.py) works unchanged on every version and
    # emits no warning either way.
    pixels = [im.getpixel((px, py)) for py in range(box[1], box[3]) for px in range(box[0], box[2])]
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

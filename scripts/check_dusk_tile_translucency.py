#!/usr/bin/env python3
"""Assert a dusk More-screen screenshot's tiles are actually translucent --
i.e. that `surface-translucent` + `backdrop-blur` reached the page AND got
applied, not just that the injected palette (or GL_BOOT.palette, see
sim-test.yml's UITEST_DUMP_PALETTE_KEYS check) *contained* those keys.

Samples one interior pixel from a row-2 tile and one from row 3 down and
requires they DIFFER: a translucent, blurred tile shows the page's own
background gradient through it, so its rendered colour tracks its row
position; an opaque tile (page.css's --gl-surface fallback instead of
--gl-surface-translucent -- see gl-bridge.js's documented fallback, and
more.html's own comment on the .gl-tile background rule) paints every tile
the identical flat colour regardless of row. This is the exact bug that
shipped invisibly: sim-test.yml's screenshots looked plausible (a real grid
of real tiles) while every tile was flat.

Sample points: ROW 2 and ROW 3, not row 1 vs row 2
-----------------------------------------------------
This script (and check_dusk_tile_lightness.py) used to compare row 1
against row 2. Commit e948780 (More grid reorder) made row 1's tile
("Settings") occupy its own full-width, CENTRED grid row:
    #gl-grid > .gl-tile:first-child { grid-column: 1/-1; justify-self: center; ... }
so the old row-1 sample x no longer falls inside any tile -- it falls on
bare page background beside the centred tile. Run 33684983479 proved this
concretely: the row-1 x/y fraction measured 17.86% HSL lightness there
(check_dusk_tile_lightness.py's own MISS) against a cross-check of the
previous PASSING run's capture reading 23.73% at the identical fraction --
same code, different geometry underneath the same hardcoded point.

Row 2 (today: Tracker + Upload) and row 3 (today: Journal + Events) are
still ordinary 2-column rows, unaffected by whatever row 1's special-cased
first tile does. Measured directly against real captures of both the old
(pre-reorder, run 33587998704) and new (post-reorder, run 33684983479)
layouts -- byte-identical between them, confirming rows 2 and 3's geometry
is untouched by the row-1 change:
    row 2 tile, vertical span : y  930-1449px  (left column x 48-585px)
    row 3 tile, vertical span : y 1485-2004px  (same left column x span)
    icon chip / label (avoid) : x ~246-390px, within either tile

    left-column interior x     : pixel 131  -> 131/1206  = 0.1086 (unchanged)
    row-2 interior y            : pixel 1189 -> 1189/2622 = 0.4538 (unchanged
                                   from before this fix -- this is the SAME
                                   point check_dusk_tile_lightness.py samples
                                   as its sole "tile interior" reference, so
                                   both scripts agree on where row 2's tile
                                   actually is)
    row-3 interior y (near the bottom of the tile, not centred): fraction
                                0.7570 -> pixel int(2622*0.7570) = 1984

Row 3's point is deliberately NOT at the same relative in-tile offset as
row 2's (that would be y=1744, the tile's vertical centre). Measured
against the real captures, the page's background gradient is real but
shallow between rows 2 and 3 -- two centred points 555px apart measured
only a 9-point max-channel delta on dusk-light, UNDER this file's own
SAME_COLOUR_TOL=10 and would have made this check flake on a correctly
translucent tile. Moving row 3's point down near its tile's own bottom
edge (20px clear of it -- comfortably inside the fill, see the "wrong
place" guard below) samples a point further down the same gradient and
recovers a 13-point delta on light -- the same margin above SAME_COLOUR_TOL
this file's original row-1/row-2 pairing had (13, see the pre-reorder
history this replaces). This is a case-by-case tuning call, not a general
rule: pick whichever real, in-fill point maximises the gradient signal for
the specific rows in play, and verify it against real captures rather than
assuming the "matching offset" choice (right for
check_dusk_tile_lightness.py's single-point pinned-value check) also
maximises delta here.

Only meaningful for a screenshot whose injected palette leaf actually HAS
surface-translucent (e.g. dusk) -- sim-test.yml only calls this for the
dusk "more" screenshots, not for themes/tabs that never carry that key.
sim-test.yml also only calls it for the LIGHT variant: dusk-dark's real
top/next-row delta is genuinely smaller than light's (see sim-test.yml's
own comment at the call site) and dark's "must stay pixel-identical"
requirement is already covered by check_dusk_tile_lightness.py's pinned
+/-2.5 band, not this file.

The "wrong place, plausible number" guard
-------------------------------------------
Same failure class check_dusk_tile_lightness.py guards against: the
invalidated row-1 point returned a normal-looking float, not an error,
because the page's background gradient is locally just as smooth as a real
tile's flat fill (measured: both read patch-internal stdev of ~0.5 per
channel at a small radius -- indistinguishable that way). What DOES
distinguish them is that a real tile interior sits within about half a
tile's height of a genuine edge (the tile's own boundary against the
inter-row gap), while a point that has drifted onto open background does
not have one nearby in either direction. Measured on real captures:
    row-2 point (130,1189): nearest edge UP 259px, DOWN 260px
    row-3 point (130,1984): nearest edge DOWN only 20px (deliberately close
        to its tile's bottom edge, see above -- UP is ~500px, no edge
        within the window, which is fine: only one direction needs to find
        one, see below)
    old row-1 point (130,630), now background: nearest edge UP 444px,
        DOWN 300px -- neither within the window
EDGE_SCAN_WINDOW=280 sits cleanly between the true-positive distances above
(259-260px, 20px) and the false-positive distances (300px, 444px).
EDGE_DELTA_THRESHOLD=10 reuses this file's own SAME_COLOUR_TOL magnitude:
real tile-vs-gap edges measure 15-19 per channel max delta, same-tile noise
measures 0-5. Only ONE direction needs to find an edge within the window --
row 3's point is deliberately near just one edge (see above), so requiring
both directions would misfire there while still letting genuinely
edge-less (background) points through in neither direction.

Prints the numeric per-channel max delta on success ("<delta> row2=... row3=..."),
"MISS:<reason>" if the two samples are indistinguishable (the bug) or if
either sample point no longer looks like it's inside a tile, or
"ERROR:<reason>" if it could not judge (missing file, no Pillow) -- same
couldn't-check-so-don't-fail contract as this repo's other screenshot
scripts (screenshot_diff_pct.py, check_no_more_header.py).

Third re-pin, row 2 + row 3 (commit d38cdf7 -- vertical centering, "More"
header removed)
-------------------------------------------------------------------------
d38cdf7 removed more.html's `.gl-header` markup and made `body` a
`display:flex; justify-content:center` column, so the grid (its own
markup/CSS untouched -- this diff is body-level layout only, see
`git show d38cdf7 -- Modules/WebPages/more.html`) now sits centred in the
viewport instead of pinned below a header, shifting every tile's absolute
position, row 2's and row 3's included.

Measured against a REAL Playwright capture this time (chromium headless,
402x874 CSS viewport, deviceScaleFactor 3 -> 1206x2622px, this file's own
documented resolution), real 5-module roster, no saved moreOrder pref
(same as check_dusk_tile_lightness.py's capture -- both files agree on one
canonical render). Edge-scanning column x=130 top to bottom found:
    row 2 tile, vertical span : y 1075-1591px  (was 930-1449px)
    row 3 tile, vertical span : y 1630-2146px  (was 1485-2004px)
both ~516px tall (was ~519px, unchanged within noise -- applyTileGeometry()'s
square-tile math is untouched by this diff). A ~145px downward shift
(~5.5% of image height), not the ~335px an earlier, explicitly-unverified
arithmetic-against-the-CSS estimate guessed -- see
check_dusk_tile_lightness.py's own header for the full account of why that
estimate was wrong by a factor of ~2.3 and why arithmetic isn't trusted
here a third time.

LEFT_TILE_X_FRAC is UNCHANGED (0.1086): confirmed empirically (a clean
tile-interior edge-scan read through all three rows of the new capture),
not assumed -- only the rows' vertical position moved, the grid's 2-column
horizontal geometry didn't.

New ROW2_Y_FRAC reuses the SAME derivation as check_dusk_tile_lightness.py
(both files are documented to share this one point): the old pin's
relative offset within its own tile (0.4991, i.e. essentially centred)
applied to the new row 2 span (1075-1591) gives y=1333 -> 0.5084.

New ROW3_Y_FRAC keeps this file's own deliberate choice of an ABSOLUTE
20px clearance from the tile's bottom edge (not a proportional offset --
see "Row 3's point is deliberately NOT at the same relative in-tile
offset" above, that rationale is unchanged by this re-pin): new row 3
bottom edge 2146 - 20 = 2126 -> 2126/2622 = 0.81083, rounded UP to 0.8109
so int(2622 * ROW3_Y_FRAC) truncates back to 2126, not 2125 (0.8108 itself
truncates one pixel short -- caught by re-running against the real
capture, see the measured deltas below). Swept the whole
plausible range (5-200px off the new bottom edge) against the new row-2
point to confirm 20px is still at or near the best achievable margin, not
just "the same number as before": light's per-channel delta stays a flat
11-12 from 5px to 40px off the edge, degrading past that (down to 9 at
200px) -- 20px is squarely in the flat, near-maximal part of that curve,
same as it was chosen to be originally.

The row-to-row RELATIONSHIP did NOT survive unchanged, though -- this is
the one place this file's re-pin differs in kind from row 1-to-row-2's
above. page.css's `html, body` background gradient is not `background-
attachment: fixed`, but doesn't need to be to behave like it here: it
paints once across the full `html`/`body` box (height:100% of the
viewport), which d38cdf7 never resizes -- only the CONTENT inside that box
moved, via flex centering. So a tile sitting lower in the same box now
reads a genuinely different point of the same unchanged gradient, not a
repaint of the old point. Measured: the new row2/row3 pair reads a max
per-channel delta of 12 on light (row2 (238,222,243) vs row3
(226,226,245)), against 11 at the OLD fractions re-measured on this SAME
new capture (i.e. barely changed -- the gradient's slope between roughly
these two y-separations, ~800px, happens to be similar whichever ~800px
stretch of it these two rows land on). Both clear SAME_COLOUR_TOL=10, so
it is left unchanged; this 11-12 margin is thinner than the ~13 this pair
had historically (see "Sample points" above) and worth watching if a
future layout shift narrows it further, but is not a knife-edge single-
pixel fluke -- it holds flat across a 35px sweep around the chosen point
(see above), so ordinary render/compression noise should not flip it.

Guard re-verification: find_nearby_edge with the OLD fractions (pixel
130,1189 / 130,1984) against the NEW capture does NOT flag either as
off-tile -- both still land inside their (now-shifted) tiles, 113px and
161px respectively from the nearest real edge, comfortably inside the
280px window. Unlike the row-1 incident this guard exists to catch, a
~145px shift is smaller than half a ~516px tile, so the old points drifted
to a less-centred spot WITHIN their tiles rather than off them entirely.
Concretely, running this file completely unmodified against the new
capture (old 0.4538/0.7570-equivalent fractions) reads delta=11 and PASSES
-- this particular layout change would not have shown up as a red CI run
even without this re-pin. That is a real, worth-knowing limit of a 280px-
wide guard (see check_dusk_tile_lightness.py's header for the fuller
account), not evidence the guard is broken: it is still correctly
answering "is this point on some real tile" for a point that, this time,
genuinely still is. The NEW points re-verified at 257-260px from the
nearest real edge (row 2) and 20px (row 3, deliberately near its one edge,
same as before) -- both inside the window, no change needed to
EDGE_SCAN_WINDOW/EDGE_DELTA_THRESHOLD.
"""
import sys

LEFT_TILE_X_FRAC = 0.1086  # unchanged by the d38cdf7 re-pin -- see header
ROW2_Y_FRAC = 0.5084  # row 2 (Tracker/Upload), left column -- see header's "Third re-pin, d38cdf7"
ROW3_Y_FRAC = 0.8109  # row 3 (Journal/Events), left column, near its bottom edge -- see header's "Third re-pin, d38cdf7"

# Two samples this close (per channel) count as "the same colour" -- i.e.
# the opaque-tile bug. In the buggy run (see above) both rows measured the
# EXACT same (251,245,239). Working translucent tiles must beat this by a
# wide margin (the page's own background gradient moves far more than
# 10/255 per channel between these two points -- see gl-bridge.js's dusk
# gradient stops). 10 leaves headroom for anti-aliasing/blur noise while
# still catching "identical flat colour".
SAME_COLOUR_TOL = 10

# "Is this point actually inside a tile" guard -- see header's "wrong
# place, plausible number" section for how these two numbers were derived
# from real captures (true-edge distances 20-260px vs false-positive
# distances 300-444px; real edge deltas 15-19 vs same-tile noise 0-5).
EDGE_SCAN_WINDOW = 280
EDGE_DELTA_THRESHOLD = 10


def find_nearby_edge(im, cx, cy, h, window=EDGE_SCAN_WINDOW, delta_threshold=EDGE_DELTA_THRESHOLD):
    """Scan up and down from (cx, cy) for a real tile-boundary edge within
    `window` pixels in EITHER direction (not necessarily both -- see header
    comment on why an OR, not an AND). Returns True if this point looks
    like it sits inside a bounded, tile-sized region of near-constant
    colour (a real tile interior), False if it's floating in open
    background with no boundary nearby (the regression this guard exists
    to catch).
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
    if len(sys.argv) != 2:
        print("ERROR:usage: check_dusk_tile_translucency.py <dusk-more-screen.png>")
        return 0
    try:
        from PIL import Image
    except ImportError as e:
        print(f"ERROR:Pillow not available: {e}")
        return 0

    path = sys.argv[1]
    try:
        im = Image.open(path).convert("RGB")
    except Exception as e:
        print(f"ERROR:could not open {path}: {e}")
        return 0

    w, h = im.size
    x = int(w * LEFT_TILE_X_FRAC)
    y2 = int(h * ROW2_Y_FRAC)
    y3 = int(h * ROW3_Y_FRAC)

    for label, y in (("row-2", y2), ("row-3", y3)):
        if not find_nearby_edge(im, x, y, h):
            print(
                f"MISS:{path} {label} sample point ({x},{y}) has no tile-boundary "
                f"edge within {EDGE_SCAN_WINDOW}px in either direction -- it is "
                f"probably no longer inside a tile at all (the More-grid layout "
                f"likely changed again; re-measure the tile coordinates against "
                f"a real capture instead of trusting this fraction)"
            )
            return 1

    row2 = im.getpixel((x, y2))
    row3 = im.getpixel((x, y3))
    delta = max(abs(a - b) for a, b in zip(row2, row3))

    if delta <= SAME_COLOUR_TOL:
        print(
            f"MISS:{path} row-2 tile interior {row2} at ({x},{y2}) and "
            f"row-3 tile interior {row3} at ({x},{y3}) are the same "
            f"colour (max channel delta {delta} <= {SAME_COLOUR_TOL}) -- "
            f"tiles look opaque, not tracking the page's background gradient"
        )
        return 1
    print(f"{delta} row2={row2}@({x},{y2}) row3={row3}@({x},{y3})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

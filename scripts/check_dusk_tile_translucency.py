#!/usr/bin/env python3
"""Assert a dusk More-screen screenshot's tiles are actually translucent --
i.e. that `surface-translucent` + `backdrop-blur` reached the page AND got
applied, not just that the injected palette (or GL_BOOT.palette, see
sim-test.yml's UITEST_DUMP_PALETTE_KEYS check) *contained* those keys.

Samples one interior pixel from a top-row tile and one from the next row
down and requires they DIFFER: a translucent, blurred tile shows the page's
own background gradient through it, so its rendered colour tracks its row
position; an opaque tile (page.css's --gl-surface fallback instead of
--gl-surface-translucent -- see gl-bridge.js's documented fallback, and
more.html's own comment on the .gl-tile background rule) paints every tile
the identical flat colour regardless of row. This is the exact bug that
shipped invisibly: sim-test.yml's screenshots looked plausible (a real grid
of real tiles) while every tile was flat.

Sample points, and the constants behind them
----------------------------------------------
more.html's #gl-grid lays out 2 columns with page padding/tile gutter
(GLTheme spacingM/spacingS -- see more.html's own CSS comments). This script
does not re-derive that arithmetic (the on-screen tile box measured 179pt
wide by 173pt tall against real captures below -- not a clean function of
the documented 16/12pt constants alone, most likely because of how
applyTileGeometry()'s JS-computed --gl-tile-side interacts with the CSS
fallback -- investigating that mismatch is out of scope here). Instead it
uses fixed fractions of image width/height, MEASURED (not guessed) directly
against a real 1206x2622 capture that reproduced the opaque-tile bug this
script exists to catch (more-dusk-light-screen.png, run 33521527914, before
this script's fix):

    left-column tile, row 1 (top) flat band   : y 375-894px  (x=100/200 clean)
    left-column tile, row 2 (next down)       : y 930-1449px
    left tile's own horizontal span           : x  48-585px
    icon chip / label centre (avoid)          : x ~238-394px

Sample points chosen well inside those bands, clear of the icon chip, the
title label, the "+" hero-toggle badge (top-right corner), and the tile's
own rounded corners / blur-softened edge:

    left-column interior x  : pixel 131  -> 131/1206  = 0.1086
    row-1 (top) interior y  : pixel 630  -> 630/2622   = 0.2403
    row-2 interior y        : pixel 1190 -> 1190/2622  = 0.4538

Fractions, not absolute pixels, so this survives sim-test picking a
different iPhone (same rationale as check_no_more_header.py). Row 2 -- not
whatever the LAST row happens to be -- is used deliberately: the More
screen's overflow roster (today: Events, Journal, Tracker, Settings,
Upload -- 3 rows) can change, and row 2 is guaranteed present whenever it
has 3+ overflow modules, true today. If the roster ever drops to a single
row this assertion has nothing to compare and should be skipped upstream
(sim-test.yml), not repointed at a row that may not exist.

Only meaningful for a screenshot whose injected palette leaf actually HAS
surface-translucent (e.g. dusk) -- sim-test.yml only calls this for the
dusk "more" screenshots, not for themes/tabs that never carry that key.

Prints the numeric per-channel max delta on success ("<delta> top=... bottom=..."),
"MISS:<reason>" if the two samples are indistinguishable (the bug), or
"ERROR:<reason>" if it could not judge (missing file, no Pillow) -- same
couldn't-check-so-don't-fail contract as this repo's other screenshot
scripts (screenshot_diff_pct.py, check_no_more_header.py).
"""
import sys

LEFT_TILE_X_FRAC = 0.1086
ROW1_Y_FRAC = 0.2403
ROW2_Y_FRAC = 0.4538

# Two samples this close (per channel) count as "the same colour" -- i.e.
# the opaque-tile bug. In the buggy run (see above) both rows measured the
# EXACT same (251,245,239). Working translucent tiles must beat this by a
# wide margin (the page's own background gradient moves far more than
# 10/255 per channel between these two rows -- see gl-bridge.js's dusk
# gradient stops). 10 leaves headroom for anti-aliasing/blur noise while
# still catching "identical flat colour".
SAME_COLOUR_TOL = 10


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
    y1 = int(h * ROW1_Y_FRAC)
    y2 = int(h * ROW2_Y_FRAC)
    top = im.getpixel((x, y1))
    bottom = im.getpixel((x, y2))
    delta = max(abs(a - b) for a, b in zip(top, bottom))

    if delta <= SAME_COLOUR_TOL:
        print(
            f"MISS:{path} top-row tile interior {top} at ({x},{y1}) and "
            f"next-row tile interior {bottom} at ({x},{y2}) are the same "
            f"colour (max channel delta {delta} <= {SAME_COLOUR_TOL}) -- "
            f"tiles look opaque, not tracking the page's background gradient"
        )
        return 1
    print(f"{delta} top={top}@({x},{y1}) bottom={bottom}@({x},{y2})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

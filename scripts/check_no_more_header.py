#!/usr/bin/env python3
"""Assert a module opened from the "More" list has no extra navigation bar.

A module in the first four tabs is installed as a bare view controller, so it
has no navigation bar at all. A module past the fourth is reached through the
system More list, and UIKit pushes it onto moreNavigationController -- which
gives it a navigation bar with a "< More" back button that no direct tab has.
Same module, same class, different chrome purely because of its +moduleOrder.
GLModuleRegistry's GLMoreListThemer hides that bar; this is the guard that
says so.

The test compares a horizontal STRIP of the screenshot -- the band just below
the status bar, exactly where that navigation bar sits -- against the same
strip of a known direct-tab screenshot. sim-test.yml calls this ONLY for the
todos/events pair, both HTTP-hosted GLWebModuleViewController pages (Events
is still reached through the system-More-bucket path this script guards, and
Todos is a direct tab running the exact same class as the reference). In CI
neither can reach the real server (sim-test bakes no GL_BAKED_HOST), so both
render the identical native "Couldn't reach ..." error view on the identical
background, and its centring depends only on how tall the content area is.
That makes the two strips pixel-identical when neither has a navigation bar,
and grossly different when one does -- a much sharper signal than eyeballing
a screenshot, and one that fails loudly if the bar ever comes back.

NOTE: this "every GLWebModuleViewController shows the identical error view in
CI" assumption does NOT extend to every web tab any more. Settings and the
More screen's root are now bundled (file://) GLWebModuleViewController pages
(Modules/WebPages/settings.html, more.html) that load successfully in CI
regardless of GL_BAKED_HOST and render real content, not the error view --
don't reuse settings-screen.png/more-screen.png as a reference or comparison
target for this script without re-deriving the strip's expected content
first.

Thresholds are measured, not guessed. Against run 33288060109's artifacts
(the last run before the fix), this strip differed from the todos strip by:

    growth      0.00%   finances  0.00%   football  0.00%   <- direct tabs
    more        2.60%                                       <- the More list
    events      3.43%   tracker   3.53%   settings  3.97%
    upload      3.64%   journal   4.25%                     <- pushed on More

Every direct tab measured an exact 0.00 (the strip is uniform white, luma
range (255,255)), and every screen carrying the bar measured at least 2.60.
A 1.0% ceiling therefore sits with wide margin on both sides of a gap that
is not close: there is no observed value between 0.00 and 2.60.

Prints "<pct>" on success or "MISS:<reason>", and exits non-zero only on a
real failure. On any problem it cannot judge (missing file, size mismatch,
no Pillow) it prints "ERROR:<reason>" and exits 0 -- the same
couldn't-check-so-don't-fail contract as screenshot_diff_pct.py, so a broken
runner never masquerades as a caught regression.
"""
import sys

# Fractions of the image height, not pixel counts, so this survives sim-test
# picking a different iPhone (it greps the first available device, whose
# resolution is not pinned). Measured on the 1206x2622 captures: the status
# bar ends around 0.057 and the navigation bar's hairline sits near 0.117,
# so this brackets the bar itself without ever reaching into either.
STRIP_TOP = 0.065
STRIP_BOTTOM = 0.120

# Per-pixel noise floor, same value screenshot_diff_pct.py uses.
PIXEL_THRESHOLD = 30

MAX_DIFF_PCT = 1.0


def strip(image):
    width, height = image.size
    return image.crop((0, int(height * STRIP_TOP), width, int(height * STRIP_BOTTOM)))


def main():
    if len(sys.argv) != 3:
        print("ERROR:usage: check_no_more_header.py <direct-tab.png> <more-module.png>")
        return 0
    try:
        from PIL import Image, ImageChops
    except ImportError as e:
        print(f"ERROR:Pillow not available: {e}")
        return 0

    reference_path, shot_path = sys.argv[1], sys.argv[2]
    try:
        reference = Image.open(reference_path).convert("RGB")
        shot = Image.open(shot_path).convert("RGB")
    except Exception as e:
        print(f"ERROR:could not open images: {e}")
        return 0
    if reference.size != shot.size:
        print(f"ERROR:size mismatch {reference.size} vs {shot.size}")
        return 0

    a, b = strip(reference), strip(shot)
    diff = ImageChops.difference(a, b).convert("L")
    changed = diff.point(lambda p: 255 if p > PIXEL_THRESHOLD else 0).histogram()[255]
    pct = 100.0 * changed / (a.size[0] * a.size[1])

    if pct > MAX_DIFF_PCT:
        print(
            f"MISS:{pct:.2f}% of the strip below the status bar differs from "
            f"{reference_path} (ceiling {MAX_DIFF_PCT}%) — the module opened "
            f"from More still has its own navigation bar"
        )
        return 1
    print(f"{pct:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

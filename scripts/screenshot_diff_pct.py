#!/usr/bin/env python3
"""Print the percentage of pixels that differ between two same-size PNG
screenshots, ignoring small per-pixel noise (anti-aliasing, the status-bar
clock). Used by sim-test.yml's check_not_home_screen guard to assert a
captured screenshot is not just the pre-launch home-screen reference with a
different clock reading.

On any problem (missing file, size mismatch, Pillow unavailable) prints
"ERROR:<reason>" and exits 0 — the caller treats that as "couldn't check",
not as "looks like the home screen".
"""
import sys


def main():
    if len(sys.argv) != 3:
        print("ERROR:usage: screenshot_diff_pct.py <ref.png> <shot.png>")
        return
    try:
        from PIL import Image, ImageChops
    except ImportError as e:
        print(f"ERROR:Pillow not available: {e}")
        return

    ref_path, shot_path = sys.argv[1], sys.argv[2]
    try:
        a = Image.open(ref_path).convert("RGB")
        b = Image.open(shot_path).convert("RGB")
    except Exception as e:
        print(f"ERROR:could not open images: {e}")
        return
    if a.size != b.size:
        print(f"ERROR:size mismatch {a.size} vs {b.size}")
        return

    diff = ImageChops.difference(a, b).convert("L")
    changed = diff.point(lambda p: 255 if p > 30 else 0).histogram()[255]
    total = a.size[0] * a.size[1]
    print(f"{100.0 * changed / total:.1f}")


if __name__ == "__main__":
    main()

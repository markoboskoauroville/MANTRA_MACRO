#!/usr/bin/env python3
"""
find.py, the eye of the macro recorder.

Marko's request, 5.9.2026: "load the screenshots of the buttons and parts, so
this app can click by optical recognition of the patterns on my screen.
Sometimes the buttons are changing: select the screenshot, load it, compare
the screen to find the button, click on it."

    python3 find.py SCREEN.png TEMPLATE.png [threshold]

Prints one line:  x y w h score SW SH   (top left corner and size, in the
pixels of SCREEN.png, then the screen image's own pixel size, which is how
Hammerspoon learns the Retina scale) when the best match scores at or above
the threshold (0.80 by default), or  none score  when nothing on the screen
looks like it.

Retina screens are captured at twice the point size, and a picture cut on
one screen may be tried on another, so the template is tried at its own
size and at half and double; the best score of the three wins. Nothing is
clicked here; Hammerspoon turns the pixels into points and does the click.
"""

import sys

try:
    import cv2
    import numpy as np
except ImportError:
    print("none 0 (opencv is not installed for this python3)")
    sys.exit(2)


def best_match(screen, template):
    th, tw = template.shape[:2]
    sh, sw = screen.shape[:2]
    if th < 4 or tw < 4 or th > sh or tw > sw:
        return None
    res = cv2.matchTemplate(screen, template, cv2.TM_CCOEFF_NORMED)
    _, score, _, loc = cv2.minMaxLoc(res)
    return score, loc[0], loc[1], tw, th


# A whole Retina screen is 5120x2880; matching a template against it at full
# resolution three times over is slow, and a search of every screen does it
# per screen. So the coarse pass runs on a downscaled copy (fast), and the one
# candidate it likes is then VERIFIED at full resolution (accurate). Downscaling
# alone makes a small template match generic regions at a high score; the
# verify pass throws those out, so speed does not cost a false click.
WORK_WIDTH = 1600


def verify(screen, template, fx, fy, fscale):
    # the real correlation at (fx, fy), template resized by fscale, in full-res pixels
    th, tw = template.shape[:2]
    nw, nh = max(3, int(tw * fscale)), max(3, int(th * fscale))
    tfull = cv2.resize(template, (nw, nh), interpolation=cv2.INTER_AREA if fscale < 1 else cv2.INTER_CUBIC)
    x, y = int(round(fx)), int(round(fy))
    sh, sw = screen.shape[:2]
    if x < 0 or y < 0 or x + nw > sw or y + nh > sh:
        return 0.0, nw, nh
    region = screen[y:y + nh, x:x + nw]
    res = cv2.matchTemplate(region, tfull, cv2.TM_CCOEFF_NORMED)
    return float(res[0][0]), nw, nh


def main():
    if len(sys.argv) < 3:
        print("none 0 (usage: find.py screen.png template.png [threshold])")
        return 2
    threshold = float(sys.argv[3]) if len(sys.argv) > 3 else 0.85
    screen = cv2.imread(sys.argv[1], cv2.IMREAD_COLOR)
    template = cv2.imread(sys.argv[2], cv2.IMREAD_COLOR)
    if screen is None:
        print("none 0 (cannot read the screen image)")
        return 2
    if template is None:
        print("none 0 (cannot read the template image)")
        return 2
    sh, sw = screen.shape[:2]
    work = min(1.0, WORK_WIDTH / float(sw)) if sw > 0 else 1.0
    small = cv2.resize(screen, (max(1, int(sw * work)), max(1, int(sh * work))), interpolation=cv2.INTER_AREA) if work < 1.0 else screen
    best = None   # (verified_score, x, y, w, h) in full-res pixels
    # 1.0 FIRST and preferred: a template cut on the same screen matches here at
    # its true place. The first scale whose verified score clears the bar is
    # taken, so a coincidental match at a wrong scale can never beat it. 0.5 and
    # 2.0 are the fall-back for a template cut on a screen of a different DPI.
    for scale in (1.0, 0.5, 2.0):
        f = work * scale
        h, w = template.shape[:2]
        nh, nw = max(3, int(h * f)), max(3, int(w * f))
        t = cv2.resize(template, (nw, nh), interpolation=cv2.INTER_AREA if f < 1 else cv2.INTER_CUBIC)
        m = best_match(small, t)
        if not m:
            continue
        coarse, cx, cy, ctw, cth = m
        if coarse < 0.55:
            continue      # not even coarsely there; verifying is a waste
        fx, fy = cx / work, cy / work
        vscore, fw, fh = verify(screen, template, fx, fy, scale)
        if best is None or vscore > best[0]:
            best = (vscore, fx, fy, fw, fh)
        if vscore >= threshold:
            break         # a real match at this scale; do not let another scale steal it
    if best is None:
        print("none 0")
        return 1
    score, x, y, w, h = best
    if score >= threshold:
        print("%d %d %d %d %.3f %d %d" % (round(x), round(y), round(w), round(h), score, sw, sh))
        return 0
    print("none %.3f" % score)
    return 1


if __name__ == "__main__":
    sys.exit(main())

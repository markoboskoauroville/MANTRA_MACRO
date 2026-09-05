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


def main():
    if len(sys.argv) < 3:
        print("none 0 (usage: find.py screen.png template.png [threshold])")
        return 2
    threshold = float(sys.argv[3]) if len(sys.argv) > 3 else 0.80
    screen = cv2.imread(sys.argv[1], cv2.IMREAD_COLOR)
    template = cv2.imread(sys.argv[2], cv2.IMREAD_COLOR)
    if screen is None:
        print("none 0 (cannot read the screen image)")
        return 2
    if template is None:
        print("none 0 (cannot read the template image)")
        return 2
    best = None
    for scale in (1.0, 0.5, 2.0):
        if scale == 1.0:
            t = template
        else:
            h, w = template.shape[:2]
            nh, nw = max(4, int(h * scale)), max(4, int(w * scale))
            t = cv2.resize(template, (nw, nh), interpolation=cv2.INTER_AREA if scale < 1 else cv2.INTER_CUBIC)
        m = best_match(screen, t)
        if m and (best is None or m[0] > best[0]):
            best = m
        if best and best[0] >= 0.97:
            break
    if best is None:
        print("none 0")
        return 1
    score, x, y, w, h = best
    sh, sw = screen.shape[:2]
    if score >= threshold:
        print("%d %d %d %d %.3f %d %d" % (x, y, w, h, score, sw, sh))
        return 0
    print("none %.3f" % score)
    return 1


if __name__ == "__main__":
    sys.exit(main())

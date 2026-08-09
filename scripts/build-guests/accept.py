#!/usr/bin/env python3
"""NSPTR-previous-patch acceptance sweep. Runs ON the lab box against the clone."""
import json
import subprocess
import sys
import time

import numpy as np

D = "/data/vms/soltest/NSPTR-previous-patch"
W, H = 1120, 832

TARGETS = [
    (8, 8), (1111, 8), (8, 823), (1111, 823),          # corners, inset 8
    (560, 8), (560, 823), (8, 416), (1111, 416),        # edge midpoints
    (560, 416),                                         # centre
    (137, 92), (642, 101), (318, 477), (905, 233), (74, 610),
    (511, 58), (860, 700), (229, 344), (703, 552), (401, 188),
    (58, 742), (996, 415), (167, 266), (588, 633), (777, 119),
]


def guest(cmd):
    return subprocess.run([D + "/g", cmd], capture_output=True, text=True, timeout=180).stdout


def nsc(*cmds):
    q = " ".join('"%s"' % c for c in cmds)
    return guest("python3 /root/nsc.py " + q).strip()


def shot(name):
    subprocess.run([D + "/shot", name], capture_output=True, text=True, timeout=60)
    return load(D + "/shots/%s.ppm" % name)


def load(path):
    with open(path, "rb") as f:
        d = f.read()
    i = d.index(b"255\n") + 4
    a = np.frombuffer(d[i:i + W * H * 3], dtype=np.uint8).reshape(H, W, 3)
    return a[:, :, 0].copy()


class Locator:
    def __init__(self, pts, hot=(0, 0)):
        self.pts = pts            # list of (dy, dx, value)
        self.hot = hot            # (hx, hy): hotspot offset from template origin
        self.th = max(p[0] for p in pts) + 1
        self.tw = max(p[1] for p in pts) + 1

    @staticmethod
    def build(a, b, box):
        x0, y0, x1, y1 = box
        sa = a[y0:y1, x0:x1]
        sb = b[y0:y1, x0:x1]
        diff = sa != sb
        ys, xs = np.nonzero(diff)
        if len(ys) == 0:
            raise RuntimeError("no cursor difference in box")
        ty0, tx0 = ys.min(), xs.min()
        pts = [(int(y - ty0), int(x - tx0), int(sa[y, x])) for y, x in zip(ys, xs)]
        return Locator(pts)

    def find(self, img):
        """Every origin at which the silhouette matches exactly, including
        origins partly off-screen (the arrow is clipped at every screen edge
        the cursor can clamp to). Template pixels that land outside the frame
        do not constrain the match; an origin with fewer than half its pixels
        on screen is rejected. The search is exhaustive over the whole frame
        every time, so the locator cannot return a remembered position."""
        oy, ox = self.th - 1, self.tw - 1
        res = np.ones((H + oy, W + ox), dtype=bool)
        inframe = np.zeros((H + oy, W + ox), dtype=np.int32)
        for dy, dx, v in self.pts:
            sy, sx = oy - dy, ox - dx
            src = np.full((H + oy, W + ox), v, dtype=np.uint8)
            src[sy:sy + H, sx:sx + W] = img
            inframe[sy:sy + H, sx:sx + W] += 1
            res &= src == v
        res &= inframe * 2 >= len(self.pts)
        ys, xs = np.nonzero(res)
        return [(int(x) - ox + self.hot[0], int(y) - oy + self.hot[1])
                for x, y in zip(xs, ys)]

    def locate(self, img):
        m = self.find(img)
        if len(m) == 1:
            return m[0]
        return None if not m else ("AMBIGUOUS", m)


def slam(dx, dy, n=40):
    nsc("slam %d %d %d" % (dx, dy, n))
    time.sleep(0.8)


def place(x, y):
    nsc("abs %d %d" % (x, y))
    time.sleep(0.25)


def main():
    tag = sys.argv[1] if len(sys.argv) > 1 else "run"
    out = {"tag": tag}

    # ---- build the silhouette from two frames over the empty desktop --------
    place(600, 650)
    a = shot(tag + "-tplA")
    place(300, 650)
    b = shot(tag + "-tplB")
    loc = Locator.build(a, b, (580, 630, 660, 700))
    print("template %dx%d, %d pixels" % (loc.tw, loc.th, len(loc.pts)))

    # ---- calibrate the hotspot against a clamp the driver owns --------------
    # The driver clamps the cursor to the screen rectangle, so a hard slam into
    # the top-left corner puts the hot spot on guest pixel (0,0) by definition
    # of the clamp -- nothing about this depends on the mechanism under test.
    slam(-63, -63, 40)
    t = shot(tag + "-cornerTL")
    m = loc.find(t)
    print("TL corner raw matches:", m)
    if len(m) != 1:
        print("FAIL: cursor not uniquely located at the top-left clamp")
        return 1
    loc.hot = (-m[0][0], -m[0][1])
    print("hotspot offset:", loc.hot)

    # ---- validate the locator against clamps it did not calibrate on --------
    checks = []
    slam(0, 63, 40)          # bottom edge, x still 0
    v = loc.locate(shot(tag + "-edgeBL"))
    checks.append(("bottom-left clamp -> (0,831)", v, v == (0, H - 1)))
    slam(63, 0, 40)          # right edge, y still at the bottom
    v = loc.locate(shot(tag + "-edgeBR"))
    checks.append(("bottom-right clamp -> (1119,831)", v, v == (W - 1, H - 1)))
    slam(0, -63, 40)
    v = loc.locate(shot(tag + "-edgeTR"))
    checks.append(("top-right clamp -> (1119,0)", v, v == (W - 1, 0)))
    # An entirely independent ground truth: the KMS relative path moves the
    # cursor exactly one guest pixel per unit delta (the acceleration curve is
    # 1:1 at magnitude 1), so 50 unit steps from the left clamp must land on 50.
    slam(-63, 0, 40)
    nsc("slam 1 0 50")
    time.sleep(1.2)
    v = loc.locate(shot(tag + "-unit50"))
    checks.append(("50 unit relative steps from x=0 -> x == 50", v,
                   v is not None and not isinstance(v[0], str) and v[0] == 50))
    for name, v, ok in checks:
        print("locator check: %-42s %-22s %s" % (name, v, "OK" if ok else "FAIL"))
    out["locator_checks"] = [(n, str(v), bool(o)) for n, v, o in checks]
    if not all(o for _, _, o in checks):
        print("FAIL: cursor locator did not validate")
        return 1

    # ---- the sweep ----------------------------------------------------------
    rows = []
    for i, (x, y) in enumerate(TARGETS):
        place(x, y)
        img = shot("%s-t%02d" % (tag, i))
        v = loc.locate(img)
        if v is None or isinstance(v[0], str):
            rows.append(((x, y), None, None))
            print("%2d commanded (%4d,%4d) -> NOT LOCATED %s" % (i, x, y, v))
        else:
            err = max(abs(v[0] - x), abs(v[1] - y))
            rows.append(((x, y), v, err))
            print("%2d commanded (%4d,%4d) landed (%4d,%4d) err %d" % (i, x, y, v[0], v[1], err))
    errs = [r[2] for r in rows if r[2] is not None]
    out["rows"] = [[list(r[0]), list(r[1]) if r[1] else None, r[2]] for r in rows]
    if len(errs) != len(rows):
        print("FAIL: %d/%d targets not located" % (len(rows) - len(errs), len(rows)))
        out["verdict"] = "FAIL"
    else:
        print("max error %d px, mean %.3f px over %d targets" %
              (max(errs), sum(errs) / len(errs), len(errs)))
        out["verdict"] = "PASS" if max(errs) <= 2 else "FAIL"
        out["max_err"] = max(errs)
        out["mean_err"] = sum(errs) / len(errs)
    print("VERDICT", out["verdict"])
    with open("%s/%s-result.json" % (D, tag), "w") as f:
        json.dump(out, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())

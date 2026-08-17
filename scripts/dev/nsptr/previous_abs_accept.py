#!/usr/bin/env python3
"""Acceptance harness for the `previous-patch` angle of the nextstep pointer work.

Runs ON the lab box against an isolated clone of the nextstep bridge tile; it
never touches the live tile. Two independent instruments are used for every
measurement:

  RAM   -- the NeXTSTEP event driver's own cursorLoc, read inside Previous
           through the abspointer control channel. Exact, microseconds, and
           readable at every screen position including the clamps.
  PIXEL -- an exhaustive, full-frame, exact-match search for the NeXT arrow
           silhouette in a QEMU screendump. Slower, and blind where the sprite
           is clipped by a screen edge, but it is the only instrument that sees
           actual photons, so it is the one that decides.

Usage:  previous_abs_accept.py <sweep|robust|latency|all> [tag]
"""

import json
import os
import subprocess
import sys
import time

import numpy as np

D = "/data/vms/sandbox/NSPTR-previous-patch"
W, H = 1120, 832
VRAM_STRIDE = W // 4  # 1120 px at 2 bpp = 280 bytes per scanline
VRAM_LEN = VRAM_STRIDE * H

TARGETS = [
    (8, 8),
    (1111, 8),
    (8, 823),
    (1111, 823),  # corners, inset 8 px
    (560, 8),
    (560, 823),
    (8, 416),
    (1111, 416),  # edge midpoints
    (560, 416),  # centre
    (137, 92),
    (642, 101),
    (318, 477),
    (905, 233),
    (74, 610),
    (511, 58),
    (860, 700),
    (229, 344),
    (703, 552),
    (401, 188),
    (58, 742),
    (996, 415),
    (167, 266),
    (588, 633),
    (777, 119),
]


# --------------------------------------------------------------------------
# plumbing


def guest(cmd, timeout=300):
    return subprocess.run([D + "/g", cmd], capture_output=True, text=True, timeout=timeout).stdout


def nsc(*cmds):
    q = " ".join('"%s"' % c for c in cmds)
    return guest("python3 /root/nsc.py " + q).strip().splitlines()


def shot(name):
    subprocess.run([D + "/shot", name], capture_output=True, text=True, timeout=120)
    return load(D + "/shots/%s.ppm" % name)


def load(path):
    with open(path, "rb") as f:
        d = f.read()
    i = d.index(b"255\n") + 4
    a = np.frombuffer(d[i : i + W * H * 3], dtype=np.uint8).reshape(H, W, 3)
    return a[:, :, 0].copy()


# --------------------------------------------------------------------------
# PIXEL instrument


class Locator:
    def __init__(self, pts, hot=(0, 0)):
        self.pts = pts
        self.hot = hot
        self.th = max(p[0] for p in pts) + 1
        self.tw = max(p[1] for p in pts) + 1

    @staticmethod
    def build(a, b, box):
        """Silhouette of the arrow, from two frames whose cursors differ inside
        `box` over identical uniform background."""
        x0, y0, x1, y1 = box
        sa, sb = a[y0:y1, x0:x1], b[y0:y1, x0:x1]
        ys, xs = np.nonzero(sa != sb)
        if not len(ys):
            raise RuntimeError("no cursor difference inside box")
        ty0, tx0 = ys.min(), xs.min()
        return Locator([(int(y - ty0), int(x - tx0), int(sa[y, x])) for y, x in zip(ys, xs)])

    def find(self, img):
        """Every origin at which the silhouette matches exactly, including
        origins partly off screen. Out-of-frame template pixels do not
        constrain the match; an origin with fewer than half its pixels on
        screen is rejected. The search is exhaustive over the whole frame every
        time, so this cannot return a remembered position."""
        oy, ox = self.th - 1, self.tw - 1
        res = np.ones((H + oy, W + ox), dtype=bool)
        seen = np.zeros((H + oy, W + ox), dtype=np.int32)
        for dy, dx, v in self.pts:
            sy, sx = oy - dy, ox - dx
            src = np.full((H + oy, W + ox), v, dtype=np.uint8)
            src[sy : sy + H, sx : sx + W] = img
            seen[sy : sy + H, sx : sx + W] += 1
            res &= src == v
        res &= seen * 2 >= len(self.pts)
        ys, xs = np.nonzero(res)
        return [(int(x) - ox + self.hot[0], int(y) - oy + self.hot[1]) for x, y in zip(xs, ys)]

    def locate(self, img):
        m = self.find(img)
        return m[0] if len(m) == 1 else None


# --------------------------------------------------------------------------
# RAM instrument + control


def ram_pos():
    r = nsc("get")[0].split()
    return (int(r[1]), int(r[2])) if r[0] == "ok" else None


def shadows():
    """All discovery survivors and their current values -- the stale-shadow
    check the closed-loop angle paid for."""
    r = nsc("cands")[0].split()
    out = []
    for f in r[2:]:
        off, xy = f.split(":")
        x, y = xy.split(",")
        out.append((off, int(x), int(y)))
    return out


def place(x, y, settle=0.25):
    nsc("abs %d %d" % (x, y))
    time.sleep(settle)


def slam(dx, dy, n=40, settle=0.9):
    nsc("slam %d %d %d" % (dx, dy, n))
    time.sleep(settle)


def discover():
    nsc("discover")
    for _ in range(30):
        time.sleep(1.0)
        st = dict(kv.split("=") for kv in nsc("status")[0].split()[1:])
        if st["state"] == "0":
            return st
    return None


def build_locator(tag):
    place(600, 650, 0.6)
    a = shot(tag + "-tplA")
    place(300, 650, 0.6)
    b = shot(tag + "-tplB")
    loc = Locator.build(a, b, (580, 630, 660, 700))
    # Hot spot from a clamp the driver owns: a hard slam into the top-left
    # corner puts the hot spot on guest pixel (0,0) by definition of the clamp.
    slam(-63, -63, 40)
    m = loc.find(shot(tag + "-cornerTL"))
    if len(m) != 1:
        raise SystemExit("locator: cursor not uniquely located at the TL clamp: %s" % m)
    loc.hot = (-m[0][0], -m[0][1])
    return loc


def validate_instruments(loc, tag):
    """Cross-validate PIXEL and RAM against each other and against clamps."""
    checks = []
    slam(-63, -63, 40)
    p, r = loc.locate(shot(tag + "-vTL")), ram_pos()
    checks.append(("top-left clamp", "pixel=%s ram=%s" % (p, r), p == (0, 0) and r == (0, 0)))
    slam(63, 63, 40)
    p, r = loc.locate(shot(tag + "-vBR")), ram_pos()
    checks.append(("bottom-right clamp (pixel blind here)", "pixel=%s ram=%s" % (p, r), r == (W - 1, H - 1)))
    slam(-63, -63, 40)
    nsc("slam 1 0 50")
    time.sleep(1.5)
    p, r = loc.locate(shot(tag + "-v50")), ram_pos()
    checks.append(("50 unit relative steps from the left clamp", "pixel=%s ram=%s" % (p, r), p is not None and p == r))
    for x, y in [(400, 300), (900, 700), (60, 60)]:
        place(x, y)
        p, r = loc.locate(shot(tag + "-v%d" % x)), ram_pos()
        checks.append(("pixel vs ram at (%d,%d)" % (x, y), "pixel=%s ram=%s" % (p, r), p is not None and p == r))
    return checks


# --------------------------------------------------------------------------
# criteria


def sweep(loc, tag):
    rows = []
    for i, (x, y) in enumerate(TARGETS):
        nsc("abs %d %d" % (x, y))
        time.sleep(0.25)
        img = shot("%s-t%02d" % (tag, i))
        r = ram_pos()
        p = loc.locate(img)
        rows.append(
            {
                "cmd": [x, y],
                "ram": list(r) if r else None,
                "pixel": list(p) if p else None,
                "err_ram": max(abs(r[0] - x), abs(r[1] - y)) if r else None,
                "err_pixel": max(abs(p[0] - x), abs(p[1] - y)) if p else None,
            }
        )
        print(
            "%2d cmd (%4d,%4d)  ram %-12s err %-4s  pixel %-12s err %s"
            % (i, x, y, r, rows[-1]["err_ram"], p, rows[-1]["err_pixel"])
        )
    return rows


def guest_moves_cursor(tag):
    """Make the GUEST change state and move the cursor by a path that is not
    the absolute write: click the Workspace menu's View item so its submenu
    opens, walk the cursor with accelerated RELATIVE deltas (the driver's own
    curve), then dismiss the submenu with a click on the desktop. Returns the
    framebuffer proof that the submenu really opened and really closed."""
    box = (0, 92, 160, 210)  # y0, x0, y1, x1 of the submenu
    place(60, 111, 0.4)
    before = shot(tag + "-menu-before")
    nsc("btn 1 1")
    time.sleep(0.35)
    nsc("btn 1 0")
    time.sleep(1.2)
    opened = shot(tag + "-menu-open")
    nsc("slam 5 5 6")  # the guest's own accelerated relative path
    time.sleep(1.2)
    place(60, 111, 0.4)  # click View again: the submenu toggles shut
    nsc("btn 1 1")
    time.sleep(0.35)
    nsc("btn 1 0")
    time.sleep(1.5)
    closed = shot(tag + "-menu-closed")
    y0, x0, y1, x1 = box
    return {
        "submenu_opened": bool((before[y0:y1, x0:x1] != opened[y0:y1, x0:x1]).sum() > 500),
        "submenu_closed": bool((closed[y0:y1, x0:x1] != opened[y0:y1, x0:x1]).sum() > 500),
    }


def latency(tag, n=24):
    """Added input->photon cost of the absolute mechanism.

    Both arms enter Previous through the SAME control channel, are drained on
    the SAME Main_EventHandler tick, call the SAME kms_mouse_move(), and move
    the cursor the SAME 200 px, so everything upstream of the emulator (browser
    -> streamhost -> QEMU -> X -> SDL) and everything downstream of the KMS is
    common and cancels. The only difference is the two int16 guest-RAM writes
    the absolute path adds.

      arm REL  rel(20,0)  -- the mechanism the tile ships today (warm gain 10)
      arm ABS  abs(x+200,y)

    'Photon' is the emulated NeXT framebuffer itself: the kiosk-side poller
    hashes all 232,960 bytes of NEXTVideo through the control channel until the
    hash changes. Interleaved arms, medians of the per-arm distributions.
    """
    out = guest("python3 /root/lat.py %d" % n, timeout=900)
    print(out)
    return out


# --------------------------------------------------------------------------


def summarise(rows, key="err_pixel"):
    errs = [r[key] for r in rows if r[key] is not None]
    miss = len(rows) - len(errs)
    return {
        "n": len(rows),
        "missing": miss,
        "max": max(errs) if errs else None,
        "mean": round(sum(errs) / len(errs), 3) if errs else None,
    }


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    tag = sys.argv[2] if len(sys.argv) > 2 else what
    res = {"tag": tag}

    if os.environ.get("NSPTR_NO_DISCOVER"):
        st = dict(kv.split("=") for kv in nsc("status")[0].split()[1:])
        print("discovery SKIPPED, restored state:", st)
        if st["result"] != "2":
            raise SystemExit("FAIL: no learned cursorLoc after restore: %s" % st)
    else:
        st = discover()
        print("discovery:", st)
        if not st or st["result"] != "2":
            raise SystemExit("FAIL: cursorLoc discovery did not converge: %s" % st)
    res["discovery"] = st

    loc = build_locator(tag)
    print("template %dx%d (%d px), hot spot %s" % (loc.tw, loc.th, len(loc.pts), loc.hot))
    res["template"] = {"w": loc.tw, "h": loc.th, "px": len(loc.pts), "hot": list(loc.hot)}

    checks = validate_instruments(loc, tag)
    for name, v, ok in checks:
        print("instrument check: %-40s %-34s %s" % (name, v, "OK" if ok else "FAIL"))
    res["instrument_checks"] = [[n, v, bool(o)] for n, v, o in checks]
    if not all(o for _, _, o in checks):
        raise SystemExit("FAIL: instruments did not validate")

    if what in ("sweep", "all"):
        print("\n--- criterion 1: accuracy ---")
        res["sweep"] = sweep(loc, tag + "-s1")
        res["sweep_summary"] = {
            "pixel": summarise(res["sweep"], "err_pixel"),
            "ram": summarise(res["sweep"], "err_ram"),
        }
        print(res["sweep_summary"])
        res["shadows_after_sweep"] = shadows()

    if what in ("robust", "all"):
        print("\n--- criterion 2: robustness after the guest moved the cursor ---")
        res["guest_move"] = guest_moves_cursor(tag)
        print("guest moved the cursor / changed state:", res["guest_move"])
        res["after_guest_move"] = {"ram": ram_pos(), "pixel": loc.locate(shot(tag + "-afterguest"))}
        print("cursor after the guest moved it:", res["after_guest_move"])
        res["sweep2"] = sweep(loc, tag + "-s2")
        res["sweep2_summary"] = {
            "pixel": summarise(res["sweep2"], "err_pixel"),
            "ram": summarise(res["sweep2"], "err_ram"),
        }
        print(res["sweep2_summary"])

    if what in ("latency", "all"):
        print("\n--- criterion 5: latency ---")
        res["latency"] = latency(tag)

    with open("%s/%s-result.json" % (D, tag), "w") as f:
        json.dump(res, f, indent=1)
    print("\nwrote %s/%s-result.json" % (D, tag))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""os213 ramabs address scan -- the two-stage derive that actually works here.

WHY NOT THE ONE-STAGE BIAS SEARCH. `os213-ramabs-derive.py` (and every other
`*-ramabs-derive.py`) locates the sprite in a screendump and then demands an
EXACT constant bias across every sample. On os213 that returns ZERO
candidates: the PM arrow is XOR-drawn, fast 1-unit motion leaves dashed
trails, and the naive "densest changed 22x14 window, then bbox min" locator
is off by up to 6 px in x and 14 px in y on some samples -- measured, see
docs/lab/OS213-WAVE.md. One bad sample kills the whole exact-match search.

THE TWO STAGES.
  1. SCAN: the guest's RAM barely changes while only the pointer moves --
     about 2000 of 8.4M int16 slots on os213. Enumerate the slots that change
     at all across the samples and read the pointer's OWN values out of them
     (the RAM is the truth; the locator is the noisy instrument). Two or three
     x,y structures fall out by inspection.
  2. FAMILIES: re-run the exact-bias search using those RAM-read positions as
     the ground truth. With a clean truth vector every layout family (x/y,
     y-then-x, inverted y, doubled y, int32) resolves cleanly.

Then, and only then, arm `-device kh-ramabs` against each candidate one QEMU
start at a time: its connect-time write probe is what separates the read-only
copies from the real variable, and on os213 three addresses PASS the probe
while only one of them actually moves the pointer. The probe is necessary,
not sufficient -- finish with a MOVEA sweep and look at STAT's converged /
gaveup counters.

Usage (on labhost, against a rig whose launch.sh takes $EXTRA):
    python3 os213-ramabs-scan.py scan   RIGDIR   # after a derive left gm*.bin
    python3 os213-ramabs-scan.py fams   RIGDIR X0,Y0 X1,Y1 ...
"""

import sys

import numpy as np


def load(rig, n):
    return np.stack([np.fromfile(f"{rig}/gm{i}.bin", dtype="<i2").astype(np.int64) for i in range(n)])


def scan(rig, n):
    d = load(rig, n)
    ii = np.nonzero(d.max(0) != d.min(0))[0]
    print(f"changing int16 slots: {len(ii)} of {d.shape[1]}")
    for i in ii:
        print(hex(int(i) * 2), [int(v) for v in d[:, i]])


def fams(rig, pts):
    n = len(pts)
    d16 = load(rig, n)
    d32 = np.stack([np.fromfile(f"{rig}/gm{i}.bin", dtype="<i4").astype(np.int64) for i in range(n)])
    X = np.array([p[0] for p in pts])
    Y = np.array([p[1] for p in pts])

    def fam(d, t, label, unit):
        b = d[0] - t[0]
        ok = np.ones(d.shape[1], bool)
        for i in range(1, n):
            ok &= (d[i] - t[i]) == b
        ok &= np.abs(b) < 8192
        idx = np.nonzero(ok)[0]
        if len(idx):
            print(label, f"stride={unit}", len(idx), [(hex(int(i) * unit), int(b[i])) for i in idx[:40]])

    for nm, t in (
        ("x", X),
        ("-x", -X),
        ("2x", 2 * X),
        ("-2x", -2 * X),
        ("y", Y),
        ("-y", -Y),
        ("2y", 2 * Y),
        ("-2y", -2 * Y),
    ):
        fam(d16, t, nm, 2)
    for nm, t in (("x32", X), ("y32", Y), ("-y32", -Y)):
        fam(d32, t, nm, 4)


if __name__ == "__main__":
    mode, rig = sys.argv[1], sys.argv[2]
    if mode == "scan":
        scan(rig, int(sys.argv[3]) if len(sys.argv) > 3 else 6)
    else:
        scan_pts = [tuple(int(v) for v in a.split(",")) for a in sys.argv[3:]]
        fams(rig, scan_pts)

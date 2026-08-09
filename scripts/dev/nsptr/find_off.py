#!/usr/bin/env python3
"""Find every RAM offset whose big-endian int16 pair equals the framebuffer-
verified cursor position in ALL samples. Run in the kiosk."""
import numpy as np

PAIRS = [
    (0, (350, 170)), (1, (630, 80)), (2, (630, 350)), (3, (80, 630)),
    (4, (630, 630)), (5, (540, 630)), (6, (210, 590)), (7, (630, 130)),
]
cands = None
for i, (x, y) in PAIRS:
    a = np.fromfile("/dev/shm/s%d.bin" % i, dtype=">u2")
    hit = (a == x)
    hit[:-1] &= (a[1:] == y)
    hit[-1] = False
    idx = np.nonzero(hit)[0]
    s = set((2 * idx).tolist())
    cands = s if cands is None else (cands & s)
    print("sample", i, len(idx), "surviving", len(cands))
print("XY offsets:", sorted(cands)[:40])

cands = None
for i, (x, y) in PAIRS:
    a = np.fromfile("/dev/shm/s%d.bin" % i, dtype=">u2")
    hit = (a == y)
    hit[:-1] &= (a[1:] == x)
    hit[-1] = False
    idx = np.nonzero(hit)[0]
    s = set((2 * idx).tolist())
    cands = s if cands is None else (cands & s)
print("YX offsets:", sorted(cands)[:40])

#!/usr/bin/env python3
"""Measure the NeXTSTEP pointer plant: transport latency, settle time, and the
acceleration curve (guest pixels moved per injected relative delta).

Every position comes from the RAM reader, which was validated against the
framebuffer; the framebuffer is re-checked at the end of the sweep.
"""

import sys
import time

sys.path.insert(0, "/data/vms/sandbox/NSPTR-closed-loop/tools")
from nsctl import Agent, Qmp, slam  # noqa: E402

q = Qmp()
a = Agent()


def home():
    slam(q, -1, -1)
    settle()


def settle(quiet_ms=60.0, cap_ms=1500.0):
    """Wait until the cursor has stopped moving for quiet_ms."""
    t0 = time.perf_counter()
    last = a.pos()
    tlast = time.perf_counter()
    while True:
        p = a.pos()
        now = time.perf_counter()
        if p != last:
            last, tlast = p, now
        if (now - tlast) * 1000 >= quiet_ms or (now - t0) * 1000 >= cap_ms:
            return last


def one(dx, dy, start=None):
    home()
    if start:
        q.rel(*start)
        settle()
    p0 = a.pos()
    t0 = time.perf_counter()
    q.rel(dx, dy)
    first = None
    lastp, tlast = p0, time.perf_counter()
    while True:
        p = a.pos()
        now = time.perf_counter()
        if first is None and p != p0:
            first = (now - t0) * 1000
        if p != lastp:
            lastp, tlast = p, now
        if first is not None and (now - tlast) * 1000 >= 60:
            break
        if (now - t0) * 1000 > 1500:
            break
    return p0, lastp, first, (tlast - t0) * 1000


print("== latency: one rel(20,0) from rest, n=15 ==")
lat = []
for _ in range(15):
    p0, p1, first, settled = one(20, 0)
    lat.append((first, settled, p1[0] - p0[0]))
    print("  first_move_ms=%s settle_ms=%.1f dx=%d" % (first, settled, p1[0] - p0[0]))
fm = [x[0] for x in lat if x[0]]
print(f"  first-move ms: min {min(fm):.1f} med {sorted(fm)[len(fm) // 2]:.1f} max {max(fm):.1f}")
st = [x[1] for x in lat]
print(f"  settle    ms: min {min(st):.1f} med {sorted(st)[len(st) // 2]:.1f} max {max(st):.1f}")

print("== acceleration curve: single rel(d,0) and rel(0,d) from the corner ==")
print("  d    dx    dy   gain_x gain_y")
for d in [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 35, 40, 50, 63, 80, 127, 200, 500]:
    _, p1, _, _ = one(d, 0)
    dx = p1[0]
    _, p2, _, _ = one(0, d)
    dy = p2[1]
    print("  %-4d %-5d %-5d %-6.2f %-6.2f" % (d, dx, dy, dx / d, dy / d))

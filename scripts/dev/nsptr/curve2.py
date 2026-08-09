#!/usr/bin/env python3
"""Full single-event displacement table (both signs, both axes) and the
event-merging behaviour that decides how fast a closed loop may iterate."""

import json
import sys
import time

sys.path.insert(0, "/data/vms/soltest/NSPTR-closed-loop/tools")
from nsctl import Agent, Qmp, slam  # noqa: E402

q = Qmp()
a = Agent()


def settle(quiet_ms=50.0, cap_ms=1200.0):
    t0 = time.perf_counter()
    last = a.pos()
    tlast = t0
    while True:
        p = a.pos()
        now = time.perf_counter()
        if p != last:
            last, tlast = p, now
        if (now - tlast) * 1000 >= quiet_ms or (now - t0) * 1000 >= cap_ms:
            return last


def home(sx, sy):
    slam(q, sx, sy)
    return settle()


tab = {"x+": {}, "x-": {}, "y+": {}, "y-": {}}
for d in range(1, 41):
    p0 = home(-1, -1)
    q.rel(d, 0)
    tab["x+"][d] = settle()[0] - p0[0]
    p0 = home(-1, -1)
    q.rel(0, d)
    tab["y+"][d] = settle()[1] - p0[1]
    p0 = home(1, 1)
    q.rel(-d, 0)
    tab["x-"][d] = p0[0] - settle()[0]
    p0 = home(1, 1)
    q.rel(0, -d)
    tab["y-"][d] = p0[1] - settle()[1]
    print(
        "d=%-3d x+=%-4d y+=%-4d x-=%-4d y-=%-4d" % (d, tab["x+"][d], tab["y+"][d], tab["x-"][d], tab["y-"][d]),
        flush=True,
    )

print(json.dumps(tab))

print("== event merging: two rel(20,0) separated by GAP ms (350 px each if separate) ==")
for gap in [0, 2, 4, 6, 8, 10, 15, 20, 30, 50]:
    tot = []
    for _ in range(3):
        p0 = home(-1, -1)
        q.rel(20, 0)
        time.sleep(gap / 1000.0)
        q.rel(20, 0)
        tot.append(settle()[0] - p0[0])
    print("  gap=%-4d dx=%s" % (gap, tot), flush=True)

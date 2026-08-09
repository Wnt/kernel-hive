#!/usr/bin/env python3
"""How long after a move must a CORRECTION be injected for the plant to treat
it as a fresh event? This sets the closed loop's minimum step period."""

import sys
import time

sys.path.insert(0, "/data/vms/soltest/NSPTR-closed-loop/tools")
from nsctl import Agent, Qmp, slam  # noqa: E402

q = Qmp()
a = Agent()


def settle(quiet_ms=60.0, cap_ms=1500.0):
    t0 = time.perf_counter()
    last, tlast = a.pos(), time.perf_counter()
    while True:
        p = a.pos()
        now = time.perf_counter()
        if p != last:
            last, tlast = p, now
        if (now - tlast) * 1000 >= quiet_ms or (now - t0) * 1000 >= cap_ms:
            return last


def trial(d2, gap):
    slam(q, -1, -1)
    settle()
    p0 = a.pos()
    q.rel(20, 0)
    time.sleep(gap / 1000.0)
    q.rel(d2, 0)
    return settle()[0] - p0[0]


for d2, want in ((2, 352), (20, 700), (5, 430)):
    print("second event d=%d (independent total would be %d)" % (d2, want))
    for gap in [25, 40, 60, 80, 100, 150, 200, 300, 500]:
        r = [trial(d2, gap) for _ in range(3)]
        print("   gap=%-4d %s" % (gap, r), flush=True)

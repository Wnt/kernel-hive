#!/usr/bin/env python3
"""Is the plant memoryless? Chain identical events and watch the per-event
displacement, from a corner slam and from a quiet mid-screen rest."""

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


def chain(d, n, gap_ms, axis=0, presleep=0.0):
    slam(q, -1, -1)
    settle()
    if presleep:
        time.sleep(presleep)
    steps = []
    p = a.pos()
    for _ in range(n):
        if axis == 0:
            q.rel(d, 0)
        else:
            q.rel(0, d)
        time.sleep(gap_ms / 1000.0)
        n2 = settle()
        steps.append(n2[axis] - p[axis])
        p = n2
    return steps


for d, gap in ((20, 100), (20, 40), (5, 100), (2, 100), (12, 100)):
    print("d=%-3d gap=%-4d steps=%s" % (d, gap, chain(d, 8, gap)), flush=True)
print("with a 1 s rest after the slam:")
for d in (20, 12, 5):
    print("d=%-3d gap=300 steps=%s" % (d, chain(d, 5, 300, presleep=1.0)), flush=True)

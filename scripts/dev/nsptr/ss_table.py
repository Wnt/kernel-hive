#!/usr/bin/env python3
"""STEADY-STATE displacement table.

The first event after a corner slam carries a much larger gain than the ones
that follow (the slam leaves the acceleration state hot), so the naive
"one event from the corner" table is not the map a controller operates in.
This measures the map in the regime a controller actually lives in: repeated
events at a fixed cadence, first two discarded, median of the rest, both
directions, edges avoided.
"""

import json
import sys
import time

sys.path.insert(0, "/data/vms/soltest/NSPTR-closed-loop/tools")
from nsctl import Agent, Qmp, slam  # noqa: E402

GAP = float(sys.argv[1]) if len(sys.argv) > 1 else 100.0
q = Qmp()
a = Agent()


def settle(quiet_ms=50.0, cap_ms=1200.0):
    t0 = time.perf_counter()
    last, tlast = a.pos(), time.perf_counter()
    while True:
        p = a.pos()
        now = time.perf_counter()
        if p != last:
            last, tlast = p, now
        if (now - tlast) * 1000 >= quiet_ms or (now - t0) * 1000 >= cap_ms:
            return last


def run(d, sign):
    slam(q, -sign, -1)
    settle()
    time.sleep(0.3)
    steps = []
    p = a.pos()
    for _i in range(9):
        q.rel(sign * d, 0)
        time.sleep(GAP / 1000.0)
        n = settle()
        steps.append(abs(n[0] - p[0]))
        p = n
        if p[0] < 40 or p[0] > 1080:
            break
    body = steps[2:]
    if not body:
        return 0, steps
    body = sorted(body)
    return body[len(body) // 2], steps


tab = {}
for d in list(range(1, 21)) + [22, 24, 26, 28, 30, 33, 36, 40, 50, 63]:
    mp, sp = run(d, 1)
    mn, sn = run(d, -1)
    tab[d] = (mp, mn)
    print("d=%-3d +%-5d -%-5d  raw+=%s raw-=%s" % (d, mp, mn, sp, sn), flush=True)
print("SSTABLE " + json.dumps(tab))

#!/usr/bin/env python3
"""The last-mile question: after a BIG move, how small a step can the plant
still make, and how long must the acceleration state cool before it can?"""

import sys
import time

sys.path.insert(0, "/data/vms/soltest/NSPTR-closed-loop/tools")
from nsctl import Agent, Qmp, slam  # noqa: E402

q = Qmp()
a = Agent()


def settle(p0, quiet=0.03, cap=0.4):
    t0 = time.perf_counter()
    last, tlast, moved = p0, t0, False
    while True:
        p = a.pos()
        now = time.perf_counter()
        if p != last:
            last, tlast, moved = p, now, True
        if moved and now - tlast >= quiet:
            return last
        if now - t0 >= cap:
            return last


print("warm ladder: rel(30,30), then wait T ms, then rel(d,d)")
print(" T\\d  " + "".join("%6d" % d for d in (1, 2, 3, 4, 5, 6, 8)))
for T in (20, 40, 80, 150, 300, 600, 1200):
    row = []
    for d in (1, 2, 3, 4, 5, 6, 8):
        slam(q, -1, -1)
        time.sleep(0.5)
        q.rel(30, 30)
        p = settle(a.pos())
        time.sleep(T / 1000.0)
        q.rel(d, d)
        n = settle(p)
        row.append(n[0] - p[0])
    print(" %-5d" % T + "".join("%6d" % v for v in row), flush=True)

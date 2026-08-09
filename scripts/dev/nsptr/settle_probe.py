#!/usr/bin/env python3
"""When is a move FINISHED? Poll the reader continuously for 300 ms after one
event and print every change, then check the framebuffer agrees."""

import sys
import time

sys.path.insert(0, "/data/vms/soltest/NSPTR-closed-loop/tools")
from nsctl import Agent, Qmp, locate_ppm, read_ppm, slam  # noqa: E402

q = Qmp()
a = Agent()
for d in (20, 12, 7, 5, 20, 12):
    slam(q, -1, -1)
    time.sleep(0.4)
    q.rel(30, 30)
    time.sleep(0.3)
    p0 = a.pos()
    t0 = time.perf_counter()
    q.rel(d, d)
    seq = []
    last = p0
    while (time.perf_counter() - t0) < 0.3:
        p = a.pos()
        if p != last:
            seq.append(((time.perf_counter() - t0) * 1000, p))
            last = p
    q.dump("/data/vms/soltest/NSPTR-closed-loop/sp.ppm")
    hits = locate_ppm(read_ppm("/data/vms/soltest/NSPTR-closed-loop/sp.ppm"))
    print("d=%-3d from %s -> %s" % (d, p0, last), "fb=", hits)
    print("     changes:", [f"{t:.1f}ms {p}" for t, p in seq], flush=True)

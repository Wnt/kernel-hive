#!/usr/bin/env python3
"""The 24-target acceptance sweep, verified on the framebuffer."""

import sys
import time

sys.path.insert(0, "/data/vms/sandbox/NSPTR-closed-loop/tools")
from ctrl import Loop  # noqa: E402
from nsctl import Agent, Qmp, locate_ppm, read_ppm  # noqa: E402

W, H = 1120, 832
TARGETS = [
    (8, 8),
    (W - 9, 8),
    (8, H - 9),
    (W - 9, H - 9),
    (W // 2, 8),
    (W // 2, H - 9),
    (8, H // 2),
    (W - 9, H // 2),
    (W // 2, H // 2),
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

q = Qmp()
a = Agent()
loop = Loop(q, a)

fb_checks = int(sys.argv[1]) if len(sys.argv) > 1 else 6
errs = []
print("  #  target        landed        err   steps  ms")
for i, (tx, ty) in enumerate(TARGETS):
    p, trace, ms = loop.goto(tx, ty)
    e = max(abs(p[0] - tx), abs(p[1] - ty))
    errs.append(e)
    extra = ""
    if i % max(1, len(TARGETS) // fb_checks) == 0:
        q.dump("/data/vms/sandbox/NSPTR-closed-loop/acc.ppm")
        hits = locate_ppm(read_ppm("/data/vms/sandbox/NSPTR-closed-loop/acc.ppm"))
        extra = "  fb={}{}".format(hits, "" if hits == [p] else "  <-- FB DISAGREES")
    print(
        "  %-2d (%4d,%4d)  (%4d,%4d)  %-4d  %-5d  %-6.1f%s" % (i, tx, ty, p[0], p[1], e, len(trace) - 1, ms, extra),
        flush=True,
    )
    time.sleep(0.15)
print("max err %d  mean err %.2f  n=%d" % (max(errs), sum(errs) / len(errs), len(errs)))
print("VERDICT", "PASS" if max(errs) <= 2 else "FAIL")

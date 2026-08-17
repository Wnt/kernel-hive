#!/usr/bin/env python3
"""Validate the RAM cursor reader against the framebuffer, at positions chosen
to include BUSY regions (icons, text, the Dock) where a template matcher is
most likely to go wrong, and after guest-driven cursor motion."""

import sys
import time

sys.path.insert(0, "/data/vms/sandbox/NSPTR-closed-loop/tools")
from nsctl import Agent, Qmp, shot_locate, slam  # noqa: E402

q = Qmp()
a = Agent()

# a scatter of single-event deltas, run from a corner slam each time so the
# landing spots are spread over plain desktop, icons, menu text and the Dock.
MOVES = [
    (0, 0),
    (20, 10),
    (63, 5),
    (5, 63),
    (40, 40),
    (63, 63),
    (30, 63),
    (63, 30),
    (10, 40),
    (55, 20),
    (25, 55),
    (63, 45),
]
bad = 0
for dx, dy in MOVES:
    slam(q, -1, -1)
    time.sleep(0.4)
    q.rel(dx, dy)
    time.sleep(0.5)
    ram = a.pos()
    hits = shot_locate(q)
    ok = hits == [ram]
    if not ok:
        bad += 1
    print("cmd(%2d,%2d) ram=%-12s fb=%-24s %s" % (dx, dy, ram, hits, "OK" if ok else "MISMATCH"))
print("mismatches:", bad, "/", len(MOVES))

#!/usr/bin/env python3
"""Collect (framebuffer-verified cursor position, full RAM snapshot) pairs so a
cursor-location offset can be required to match EVERY sample, not two."""

import subprocess
import sys
import time

sys.path.insert(0, "/data/vms/soltest/NSPTR-closed-loop/tools")
from nsctl import Qmp, shot_locate, slam  # noqa: E402

SSH = "/root/nsclone-ssh.sh"
MOVES = [(20, 10), (63, 5), (55, 20), (5, 63), (40, 40), (30, 63), (12, 33), (48, 8)]

q = Qmp()
out = []
for i, (dx, dy) in enumerate(MOVES):
    slam(q, -1, -1)
    time.sleep(0.4)
    q.rel(dx, dy)
    time.sleep(0.5)
    hits = shot_locate(q)
    if len(hits) != 1:
        print("skip", dx, dy, hits)
        continue
    subprocess.run([SSH, "SNAPOUT=/dev/shm/s%d.bin python3 /root/curscan.py" % i], check=True)
    out.append((i, hits[0]))
    print(i, (dx, dy), hits[0], flush=True)
print("PAIRS", out)

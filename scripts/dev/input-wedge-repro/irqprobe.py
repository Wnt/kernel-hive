#!/usr/bin/env python3
"""Detect the win311 wedge by reading CPU interrupt state, not the screen.

THE DEFINITIVE INSTRUMENT. Every earlier probe here inferred the wedge from
pixels — whole-frame hashes (ambiguous: a game can idle), HUD region hashes
(better), or an injected Ctrl+Esc (circular: it needs input to answer whether
input works). This one reads the fault itself:

    wedged  ->  EFLAGS.IF clear in EVERY sample, AND pic0 IRR non-zero
                (interrupts pending, unmasked, nothing in service, never taken)
    healthy ->  IF set in some samples, IRR settles to 0

No screen layout, no app, no injected key, no snapshot required — so it works
on a cold-booted guest, on any scene, and it cannot be fooled by an app that
merely stopped animating.

USE: --cold-test answers the operator's question of 2026-08-17 — is the fault
carried by the golden vmstate, or is it inherent to the guest? Cold-boot a clone
(`COLD=1 launch.sh`), run this, and compare with a loadvm'd one. A cold guest
that never wedges would implicate the snapshot and make "re-bake the golden" a
candidate fix; one that wedges identically rules the snapshot out.
"""

import argparse
import contextlib
import os
import random
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qmp_probe import Qmp, log  # noqa: E402

GAME_KEYS = ("kp_4", "kp_1", "kp_2", "kp_3", "kp_6")


def irq_state(q, samples=8, gap=0.25):
    """Return (if_set_count, samples, irr) — the wedge fingerprint."""
    n = 0
    for _ in range(samples):
        r = q.hmp("info registers") or ""
        m = re.search(r"EFL=([0-9a-f]{8})", r)
        if m and int(m.group(1), 16) & 0x200:
            n += 1
        time.sleep(gap)
    pic = q.hmp("info pic") or ""
    irr = 0
    for line in pic.splitlines():
        mm = re.search(r"pic0:\s*irr=([0-9a-f]{2})", line)
        if mm:
            irr = int(mm.group(1), 16)
    return n, samples, irr


def wedged(q):
    n, total, irr = irq_state(q)
    return (n == 0 and irr != 0), n, total, irr


def launch_skifree(q):
    """From the Program Manager scene: Minesweeper -> Ski, then Enter."""
    q.tap("right", 80)
    time.sleep(0.8)
    q.tap("ret", 80)
    time.sleep(6)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--rounds", type=int, default=8)
    ap.add_argument("--edges", type=int, default=60)
    ap.add_argument("--hold-lo", type=int, default=40)
    ap.add_argument("--hold-hi", type=int, default=350)
    ap.add_argument("--seed", type=int, default=5)
    ap.add_argument("--launch", action="store_true", help="start SkiFree first")
    ap.add_argument("--label", default="guest")
    a = ap.parse_args()

    q = Qmp(a.qmp)
    w, n, tot, irr = wedged(q)
    log(f"[{a.label}] baseline: IF set {n}/{tot}, pic0 irr={irr:02x}, wedged={w}")
    if w:
        log(f"[{a.label}] PRECONDITION FAILED: already wedged")
        return 1

    if a.launch:
        launch_skifree(q)
        q.tap("kp_2", 120)  # start the run
        time.sleep(2)

    rng = random.Random(a.seed)
    total_edges = 0
    held = None
    for r in range(1, a.rounds + 1):
        sent = 0
        while sent < a.edges:
            k = rng.choice(GAME_KEYS)
            if held:
                q.key(held, False)
                sent += 1
            q.key(k, True)
            sent += 1
            held = k
            time.sleep(rng.randint(a.hold_lo, a.hold_hi) / 1000.0)
        if held:
            with contextlib.suppress(RuntimeError):
                q.key(held, False)
            held = None
        total_edges += sent
        w, n, tot, irr = wedged(q)
        log(f"[{a.label}] round {r:2d}: {total_edges:4d} edges -> IF {n}/{tot}, irr={irr:02x}, wedged={w}")
        if w:
            log("=" * 60)
            log(
                f"[{a.label}] WEDGED after {total_edges} key edges "
                f"(IF clear in all {tot} samples, IRQs pending irr={irr:02x})"
            )
            log(f"[{a.label}] vm_running={q.running()}")
            return 0
    log(f"[{a.label}] survived {total_edges} key edges — NOT wedged")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(1)

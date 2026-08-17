#!/usr/bin/env python3
"""Reproduce the win311 guest input wedge, and its controls, in one tool.

THE FINDING (2026-08-17). On a win311 clone sitting on the SkiFree start screen,
driving ~40 key EDGES of any key SkiFree acts on (left / kp_4 / home) kills the
guest's keyboard in about six seconds: Ctrl+Esc stops repainting while the VM is
still `running`. `loadvm` brings it straight back, which is why the operator
found that "Restore to golden" fixes it.

WHAT THE CONTROLS ESTABLISH — run them, do not take this on faith:
  --key a --edges 200   stays ALIVE. Five times the volume of a key the game
                        IGNORES does nothing, so the wedge is not key VOLUME.
  --idle                stays ALIVE. Same wall-clock with zero keys does
                        nothing, so it is not elapsed time.
  --key kp_4            WEDGES, and kp_4 is NOT an extended scancode, while
                        --key home (extended, not an arrow) also wedges. So it
                        is not the 0xE0 extended-key path either.
  --key left            WEDGES. The positive control.
The surviving explanation is the app: keys SkiFree PROCESSES wedge it, keys it
ignores do not, and a wedged 16-bit app holds the shared Windows 3.x input
queue, which is what takes the mouse cursor and every other key down with it.

KNOWN SIGNATURE GAP. In the live incident Ctrl+Esc still recovered the desktop;
here it does not. So this is either the same fault at greater severity (start
screen vs mid-game) or a neighbouring one. Do not assume they are identical
until a mid-game snapshot reproduces it too.

Exit 0 = wedged (reproduced), 2 = survived, 1 = precondition failed.
"""

import argparse
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qmp_probe import Qmp, kbd_alive, log  # noqa: E402

DEFAULT_QMP = "/data/vms/sandbox/w311frz-a1/qmp.sock"


def drive(q, key, edges, rng, hold_lo, hold_hi, overlap):
    """Send `edges` key transitions. With `overlap`, the next direction goes
    DOWN before the current comes UP — what a real hand does mid-turn. Overlap
    is NOT required to reproduce; it is offered to characterise, not to trigger.
    """
    keys = ["left", "right"] if overlap else [key]
    sent = 0
    held = None
    while sent < edges:
        k = rng.choice(keys)
        hold = rng.randint(hold_lo, hold_hi) / 1000.0
        if overlap and held and held != k:
            q.key(k, True)
            sent += 1
            time.sleep(hold)
            q.key(held, False)
            sent += 1
            held = k
        else:
            if held:
                q.key(held, False)
                sent += 1
            q.key(k, True)
            sent += 1
            held = k
            time.sleep(hold)
    if held:
        q.key(held, False)
        sent += 1
    return sent


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--qmp", default=os.environ.get("QMP", DEFAULT_QMP))
    ap.add_argument("--snap", default="skifree")
    ap.add_argument("--key", default="left", help="key to drive (control: 'a')")
    ap.add_argument("--edges", type=int, default=42, help="key edges per round")
    ap.add_argument("--rounds", type=int, default=6)
    ap.add_argument("--hold-lo", type=int, default=40)
    ap.add_argument("--hold-hi", type=int, default=400)
    ap.add_argument("--overlap", action="store_true", help="interleave left/right instead of one key")
    ap.add_argument("--idle", action="store_true", help="CONTROL: send nothing, just wait --edges/4 seconds")
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()

    q = Qmp(a.qmp)
    q.loadvm(a.snap)
    if not kbd_alive(q):
        log("PRECONDITION FAILED: keyboard already dead right after loadvm")
        return 1
    log(
        f"baseline alive; key={a.key} edges/round={a.edges} "
        f"hold={a.hold_lo}-{a.hold_hi}ms overlap={a.overlap} idle={a.idle}"
    )

    rng = random.Random(a.seed)
    total = 0
    for r in range(1, a.rounds + 1):
        if a.idle:
            time.sleep(a.edges / 4.0)
        else:
            total += drive(q, a.key, a.edges, rng, a.hold_lo, a.hold_hi, a.overlap)
        alive = kbd_alive(q)
        log(f"round {r:2d}: {total:4d} edges cumulative -> keyboard {'alive' if alive else 'DEAD'}")
        if not alive:
            log("=" * 60)
            log(f"WEDGED after {total} edges of '{a.key}' (overlap={a.overlap} seed={a.seed})")
            log(f"VM still running: {q.running()}")
            q.loadvm(a.snap)
            log(f"recovered by loadvm: {kbd_alive(q)}")
            return 0
    log(f"survived {total} edges of '{a.key}'{' (idle)' if a.idle else ''}")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(1)

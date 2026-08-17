#!/usr/bin/env python3
"""Clock + SkiFree side by side: tell an app hang from an input-queue hang.

THE OPERATOR'S PROBE, AND IT IS STRICTLY BETTER THAN MINE. Every earlier
liveness test in this directory INJECTS a key (Ctrl+Esc) and asks whether the
screen reacts. That is circular when the thing under test is whether input
works: "input is dead" and "Windows is dead" produce an identical answer.

The Clock is PASSIVE. Its second hand advances with no input at all, so hashing
the clock face answers "is Windows still scheduling and painting?" completely
independently of "does the keyboard still arrive?". Read together with
SkiFree's own Dist/Speed counters, the two regions separate the three states:

    clock ticks + hud advances  -> healthy
    clock ticks + hud frozen    -> SkiFree wedged, Windows ALIVE   (LIVE_MATCH)
    clock frozen + hud frozen   -> input queue / Windows wedged     (HARD_WEDGE)

WHAT IT ACTUALLY FOUND (2026-08-17, on the LIVE station, operator's layout).
The bottom row, in 85 key edges of kp_4/kp_1/kp_2/kp_3/kp_6 -- about sixteen
seconds. The clock stops too, so this was never "SkiFree holds the input
queue"; the whole guest stops. That also retires the belief that the live
freeze was milder than the clone's: they are the same fault. The earlier
"Ctrl+Esc recovered it" reading came from a guest that was not in this state.

ROOT CAUSE, from the wedged guest:
    pic0: irr=03 imr=88 isr=00      timer+keyboard PENDING, unmasked, none in
                                    service -- so nothing is blocking them
    EFL: IF=0 in 10/10 samples      ...because the CPU has interrupts DISABLED
    healthy baseline: IF set 4/10, irr=00
The guest is left running with IF clear and never re-enables it, so the pending
timer and keyboard IRQs can never be delivered. That single fact explains every
symptom at once: clock frozen, game frozen, keyboard dead, mouse cursor dead,
VM still "running" with EIP advancing through varied code, and loadvm curing it
(the snapshot restores a state whose IF is set).

Layout is the one the operator built by hand: Clock top-left, SkiFree dragged
right to clear it. Regions are in guest pixels at 1024x768 — re-measure with
--calibrate if the windows move.
"""

import argparse
import contextlib
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qmp_probe import Qmp, log  # noqa: E402

LIVE_QMP = "/data/vms/streamhost/stations/win311/qmp.sock"
# Clock face (the "H:MM:SS PM" line) and SkiFree's Time/Dist/Speed/Style box.
CLOCK = (30, 118, 205, 50)
HUD = (866, 26, 150, 58)
# SkiFree's own controls, as the operator uses them.
GAME_KEYS = ("kp_4", "kp_1", "kp_2", "kp_3", "kp_6")


def changed(q, region, samples=4, gap=1.1):
    hs = []
    for _ in range(samples):
        hs.append(q.fb_region_hash(*region))
        time.sleep(gap)
    return len(set(hs)) > 1


def calibrate(q):
    log(f"clock region ticking : {changed(q, CLOCK)}")
    log(f"hud region advancing : {changed(q, HUD)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--qmp", default=os.environ.get("QMP", LIVE_QMP))
    ap.add_argument("--calibrate", action="store_true")
    ap.add_argument("--play-secs", type=float, default=180.0)
    ap.add_argument("--stall-secs", type=float, default=8.0)
    ap.add_argument("--hold-lo", type=int, default=40)
    ap.add_argument("--hold-hi", type=int, default=350)
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--no-start", action="store_true", help="assume the run is already going")
    a = ap.parse_args()

    q = Qmp(a.qmp)
    if a.calibrate:
        calibrate(q)
        return 0

    if not changed(q, CLOCK):
        log("PRECONDITION FAILED: clock is not ticking — wrong region, or the guest is already wedged")
        return 1
    log("baseline: clock ticking")

    if not a.no_start:
        q.tap("kp_2", 120)  # start the run
        time.sleep(2)
    if not changed(q, HUD):
        log("PRECONDITION FAILED: game not advancing after start")
        return 1
    log(f"baseline: game advancing — driving {', '.join(GAME_KEYS)}")

    rng = random.Random(a.seed)
    deadline = time.time() + a.play_secs
    last, last_change, edges = q.fb_region_hash(*HUD), time.time(), 0
    held = None
    try:
        while time.time() < deadline:
            k = rng.choice(GAME_KEYS)
            if held:
                q.key(held, False)
                edges += 1
            q.key(k, True)
            edges += 1
            held = k
            time.sleep(rng.randint(a.hold_lo, a.hold_hi) / 1000.0)
            h = q.fb_region_hash(*HUD)
            if h != last:
                last, last_change = h, time.time()
                continue
            if time.time() - last_change < a.stall_secs:
                continue

            # The game stopped advancing. Release everything, then ask the CLOCK
            # — passively — whether Windows itself is still alive.
            for kk in GAME_KEYS:
                with contextlib.suppress(RuntimeError):
                    q.key(kk, False)
            held = None
            time.sleep(0.5)
            clock_ok = changed(q, CLOCK)
            log(f"game stopped advancing after {edges} key edges ({a.stall_secs:.0f}s)")
            log(f"  vm_running={q.running()}  clock_still_ticking={clock_ok}")
            if clock_ok:
                log("=" * 60)
                log(
                    "LIVE_MATCH: SkiFree is wedged but Windows is ALIVE "
                    "(clock still ticking) — this is the operator's signature"
                )
                return 0
            log("=" * 60)
            log("HARD_WEDGE: clock stopped too — Windows/input queue is wedged, not just the app")
            return 3
    finally:
        if held:
            with contextlib.suppress(RuntimeError):
                q.key(held, False)
    log(f"no freeze in {a.play_secs:.0f}s ({edges} key edges)")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(1)

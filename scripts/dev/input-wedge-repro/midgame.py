#!/usr/bin/env python3
"""Reproduce the win311 freeze from a MID-GAME state, and test the signature.

WHY A SECOND MODE. `keywedge.py` probes a STATIC scene (the SkiFree start
screen), where "did the framebuffer change" answers "is input alive". Mid-game
that question inverts: a healthy game animates continuously, so a changing
framebuffer proves nothing and `kbd_alive` would report alive every time. Here
the freeze signal is animation STOPPING, and Ctrl+Esc is then used to classify
what kind of freeze it is.

THE CLASSIFICATION IS THE POINT. The live 2026-08-17 incident had a very
specific signature: animation stopped, the VM stayed `running`, and Ctrl+Esc
STILL repainted the desktop — i.e. Windows was alive and one wedged 16-bit app
was holding the shared input queue. `keywedge.py` on the start screen produces a
HARDER failure where Ctrl+Esc is dead too. This tool exists to find out whether
mid-game reproduces the live, softer signature — and therefore whether the two
are the same bug.

  verdict LIVE_MATCH   game logic stopped, VM running, Ctrl+Esc recovered
  verdict HARD_WEDGE   game logic stopped, VM running, Ctrl+Esc dead
  verdict VM_DEAD      VM not running (a different failure entirely)
  verdict CLEAN        the picture stalled but the HUD kept advancing, i.e. the
                       game was fine and only the skier had stopped

Exit 0 = LIVE_MATCH, 3 = HARD_WEDGE, 2 = CLEAN, 1 = error.
"""

import argparse
import contextlib
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qmp_probe import Qmp, log  # noqa: E402

DEFAULT_QMP = "/data/vms/soltest/w311frz-a1/qmp.sock"
START_SNAP = "skifree"
MID_SNAP = "skifree-mid"


def bake_mid(q, ski_secs):
    """From the start screen, start the run and bank a few seconds of skiing.

    Deliberately spends only a handful of key edges: the wedge needs ~44, and a
    start snapshot that is already half-wedged would poison every trial.
    """
    log(f"baking '{MID_SNAP}': starting the run, skiing {ski_secs}s")
    q.loadvm(START_SNAP)
    q.tap("down", 120)
    time.sleep(ski_secs)
    q.cmd("stop")
    with contextlib.suppress(RuntimeError):
        q.hmp(f"delvm {MID_SNAP}")
    q.hmp(f"savevm {MID_SNAP}")
    q.cmd("cont")
    log(f"snapshot '{MID_SNAP}' saved")


# SkiFree's HUD box (guest pixels, 1024x768): Time / Dist / Speed / Style.
HUD = (740, 20, 160, 70)


def hud_advancing(q, samples=4, gap=1.2):
    """Is the GAME'S OWN STATE still advancing?

    Better than hashing the whole frame, which conflates "the app is wedged"
    with "nothing happens to be moving" — a skier who has stopped or crashed
    freezes the picture while the game is perfectly healthy. SkiFree's Dist and
    Speed tick whenever its logic runs, so this reads the app's own counters.
    (Time stays 0:00:00.00 in free-style, so do not rely on the clock alone.)
    """
    hs = []
    for _ in range(samples):
        hs.append(q.fb_region_hash(*HUD))
        time.sleep(gap)
    return len(set(hs)) > 1


def animating(q, samples=3, gap=1.0):
    hs = []
    for _ in range(samples):
        hs.append(q.fb_hash())
        time.sleep(gap)
    return len(set(hs)) > 1


ALL_KEYS = ("left", "right", "up", "down", "ctrl", "shift", "alt", "home", "kp_4")


def release_all(q):
    """Release every key we might have left down.

    REQUIRED BEFORE CLASSIFYING. The stall is detected mid-stride, so a key is
    still held at that moment, and a held key can block the Ctrl+Esc probe on
    its own — which would misreport a recoverable freeze as a hard wedge. A held
    key does NOT by itself wedge the guest (verified: 6 s holding `left` mid-game
    kept animating), so releasing here cannot mask the fault we are hunting.
    """
    for k in ALL_KEYS:
        with contextlib.suppress(RuntimeError):
            q.key(k, False)
    time.sleep(0.5)


def classify(q, settle=2.5):
    """Animation has stopped. What KIND of stop is it?"""
    if not q.running():
        return "VM_DEAD", False
    release_all(q)
    if hud_advancing(q):
        return "CLEAN", True  # the picture stalled but the game is still running
    before = q.fb_hash()
    q.chord(["ctrl"], "esc")
    time.sleep(settle)
    recovered = q.fb_hash() != before
    if recovered:
        q.tap("esc")  # close the Task List so the scene is left as found
        time.sleep(0.8)
    return ("LIVE_MATCH" if recovered else "HARD_WEDGE"), recovered


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--qmp", default=os.environ.get("QMP", DEFAULT_QMP))
    ap.add_argument("--ski-secs", type=float, default=8.0)
    ap.add_argument("--play-secs", type=float, default=90.0)
    ap.add_argument("--stall-secs", type=float, default=8.0)
    ap.add_argument("--hold-lo", type=int, default=40)
    ap.add_argument("--hold-hi", type=int, default=400)
    ap.add_argument("--trials", type=int, default=3)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--rebake", action="store_true")
    a = ap.parse_args()

    q = Qmp(a.qmp)
    snaps = q.hmp("info snapshots") or ""
    if a.rebake or MID_SNAP not in snaps:
        bake_mid(q, a.ski_secs)

    for t in range(1, a.trials + 1):
        q.loadvm(MID_SNAP)
        if not animating(q):
            log(f"trial {t}: PRECONDITION — not animating after loadvm; rebake")
            return 1
        rng = random.Random(a.seed + t)
        log(f"trial {t}/{a.trials}: driving up to {a.play_secs:.0f}s")

        deadline = time.time() + a.play_secs
        last, last_change, edges = q.fb_hash(), time.time(), 0
        held = None
        verdict = None
        while time.time() < deadline:
            k = rng.choice(["left", "right"])
            if held:
                q.key(held, False)
                edges += 1
            q.key(k, True)
            edges += 1
            held = k
            time.sleep(rng.randint(a.hold_lo, a.hold_hi) / 1000.0)
            h = q.fb_hash()
            if h != last:
                last, last_change = h, time.time()
            elif time.time() - last_change >= a.stall_secs:
                verdict, recovered = classify(q)
                log(f"  animation stopped for {a.stall_secs:.0f}s after {edges} key edges")
                log(f"  VERDICT {verdict} (vm_running={q.running()} ctrl_esc_recovered={recovered})")
                break
        if held:
            with contextlib.suppress(RuntimeError):
                q.key(held, False)
        if verdict == "LIVE_MATCH":
            log("=" * 60)
            log("MID-GAME REPRODUCTION MATCHES THE LIVE SIGNATURE")
            return 0
        if verdict == "HARD_WEDGE":
            log("=" * 60)
            log(
                "mid-game wedges, but HARDER than the live incident "
                "(Ctrl+Esc dead) — treat as a possibly-different fault"
            )
            return 3
        if verdict == "VM_DEAD":
            return 1
        if verdict == "CLEAN":
            log(f"  trial {t}: picture stalled but HUD still advancing — not a wedge, game alive")
            continue
        log(f"  trial {t} clean after {edges} key edges")
    log("no mid-game freeze reproduced")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(1)

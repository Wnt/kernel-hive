#!/usr/bin/env python3
"""The broker's smoke check, run on the box, proved at the framebuffer.

Not a unit test and not a drill: it builds a real clone from a real station's
launcher, resumes it, WRECKS it, releases it, and shows that the next claim is
pristine — and that the reap left nothing behind. Every "it worked" here is a
PPM the operator can look at, because **the framebuffer is the only proof a
guest reacted** (rule 9); the log lines are navigation, not evidence.

    KH_SESSION=<yours> WALKIN_ROOT=/data/vms/sandbox/<yours>/clones \\
      python3 -m serve.walkin.smoke --spec <station.json> --repo <repo root>

It refuses to run without `WALKIN_ROOT` pointed somewhere that is not the
production walk-in tree, so a smoke run can never reap live pool members.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from . import broker as broker_mod
from . import naming
from .spec import load_spec

FRAME_DIR_NAME = "frames"


def _say(step: str, detail: str = "") -> None:
    print(f"[smoke] {step}{': ' + detail if detail else ''}", flush=True)


def frame_delta(left: Path, right: Path) -> float:
    """Fraction of differing bytes between two PPMs of the same geometry."""
    a, b = left.read_bytes(), right.read_bytes()
    if len(a) != len(b):
        return 1.0
    differing = sum(1 for x, y in zip(a, b) if x != y)
    return differing / max(1, len(a))


def station_pids() -> dict:
    """Every live station's QEMU pid, so 'the fleet is untouched' is a fact."""
    root = Path("/data/vms/streamhost/stations")
    out = {}
    for pidfile in sorted(root.glob("*/qemu.pid")):
        try:
            out[pidfile.parent.name] = int(pidfile.read_text().strip())
        except (OSError, ValueError):
            continue
    return out


def wreck(clone, frames: Path) -> Path:
    """Do something a visitor could do that leaves the machine visibly changed."""
    with clone.qmp() as conn:
        conn.execute("send-key", keys=[{"type": "qcode", "data": "ctrl"}, {"type": "qcode", "data": "esc"}])
    time.sleep(3)
    return clone.screenshot(frames / "3-wrecked.ppm")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, help="a walk-in station JSON (a sandbox fixture is fine)")
    parser.add_argument("--repo", default=".", help="repo root the launcher path is relative to")
    parser.add_argument("--settle", type=float, default=6.0, help="seconds to let a resumed guest run")
    parser.add_argument("--daemon", action="store_true", help="also start each clone's streamhost")
    args = parser.parse_args(argv)

    if str(naming.WALKIN_ROOT) == "/data/vms/walkin":
        _say("REFUSED", "set WALKIN_ROOT to your own sandbox before smoking the broker")
        return 2
    if not os.environ.get("KH_SESSION"):
        _say("REFUSED", "KH_SESSION is unset; every claim must name its owner")
        return 2

    spec = load_spec(Path(args.spec))
    frames = naming.WALKIN_ROOT / FRAME_DIR_NAME
    frames.mkdir(parents=True, exist_ok=True)
    fleet_before = station_pids()

    broker = broker_mod.Broker(Path(args.spec).parent, Path(args.repo), daemon=args.daemon)
    broker.specs = {spec.station: spec}
    results = {}
    try:
        _say("open the plane", f"pool size {spec.pool_size}")
        broker.set_access("open")
        _say("pool", json.dumps(broker.pools()))

        warm = next(iter(broker._members.values()))
        with warm.clone.qmp() as conn:
            results["warm_status"] = conn.status()
        _say("warm member", f"{warm.identity} is {results['warm_status']}")
        first_frame = warm.clone.screenshot(frames / "1-warm-paused.ppm")

        claim = broker.claim("smoke-visitor", spec.station)
        _say("claimed", json.dumps(claim))
        time.sleep(args.settle)
        playing = warm.clone.screenshot(frames / "2-playing.ppm")
        results["resume_delta"] = frame_delta(first_frame, playing)
        _say("resumed", f"frame moved {results['resume_delta']:.4%} vs the paused shot")

        wrecked = wreck(warm.clone, frames)
        results["wreck_delta"] = frame_delta(playing, wrecked)
        _say("wrecked", f"frame moved {results['wreck_delta']:.4%} vs playing")

        root_before = warm.clone.plan.root
        broker.release("smoke-visitor", claim["clone"])
        results["root_removed"] = not root_before.exists()
        _say("released", f"clone root gone: {results['root_removed']}")

        second = broker.claim("smoke-visitor-2", spec.station)
        results["second_clone"] = second["clone"]
        fresh = broker._members[second["clone"]]
        time.sleep(args.settle)
        pristine = fresh.clone.screenshot(frames / "4-next-visitor.ppm")
        results["pristine_vs_wrecked"] = frame_delta(wrecked, pristine)
        results["pristine_vs_playing"] = frame_delta(playing, pristine)
        _say(
            "next visitor",
            f"{second['clone']} differs from the wrecked machine by "
            f"{results['pristine_vs_wrecked']:.4%} and from the pristine one by "
            f"{results['pristine_vs_playing']:.4%}",
        )
    finally:
        disconnected = broker.close_all()
        _say("closed", f"{disconnected} session(s) disconnected, pool emptied")
        leftovers = [p.name for p in naming.WALKIN_ROOT.iterdir() if p.is_dir() and p.name.startswith("walkin-")]
        results["orphans"] = leftovers
        held = subprocess.run(["kh-claim", "ls", "--mine"], capture_output=True, text=True, check=False).stdout
        results["claims_left"] = [ln for ln in held.splitlines() if "walkin-slot" in ln or "port/541" in ln]
        results["fleet_unchanged"] = station_pids() == fleet_before

    print(json.dumps(results, indent=2))
    ok = (
        # `-S` at startup reports `prelaunch`; `paused` is the same machine after
        # it has been stopped again. Either means "restored and not running".
        results.get("warm_status") in ("paused", "prelaunch")
        and results.get("root_removed")
        and not results.get("orphans")
        and not results.get("claims_left")
        and results.get("fleet_unchanged")
        and results.get("pristine_vs_wrecked", 0) > results.get("pristine_vs_playing", 1)
    )
    _say("VERDICT", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

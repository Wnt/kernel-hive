#!/usr/bin/env python3
"""The hold's smoke check: switching keeps your machine, and the window ends it.

    KH_SESSION=<yours> WALKIN_ROOT=/data/vms/sandbox/<yours>/clones \\
      python3 -m serve.walkin.smoke_hold --spec <a.json> --spec <b.json> --repo <root>

`smoke.py` proves the pool's founding invariant at the framebuffer — a used
clone is never re-listed, the next visitor's machine is pristine. This proves
the thing that was added on top of it, and it needs the SAME kind of evidence,
because **the framebuffer is the only proof a guest reacted** (rule 9): a log
line saying "resumed walkin-os2warp-1" is equally true of a clone that came off
the golden five seconds ago, which is exactly the failure this feature exists to
prevent. So the claim under test is stated as an arithmetic fact about pixels:

    the machine you come back to differs from the one you WRECKED by far less
    than it differs from the one you were first handed

Nothing here waits on a guessed number of seconds (rule 14). `settle()` returns
the moment the screen has stopped changing and `moved()` the moment it has
moved, both against a deadline — the same contract as `scripts/dev/fb-wait.py`,
applied to a clone's own QMP screendump because these guests have no station
directory for fb-wait to watch.

THE CLOCK IS INJECTED, deliberately. The hold window is five minutes and the
reap is what enforces it; sitting out five real minutes would prove nothing the
offset does not, and would prove it more slowly. The guests are real, their QMP
is real, the claims are real — only `Broker._now` is moved, which is the one
thing the broker uses for bookkeeping and nothing else.

Two stations are required, because "switch" is meaningless with one. Both of
`smoke.py`'s refusals apply and are re-used: production `WALKIN_ROOT`, and a tap
name this run could pick that already exists in the kernel (`WALKIN_ROOT`
namespaces the TREE, not the TAP).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

from . import broker as broker_mod
from . import claims, naming
from .session import HOLD_SECONDS
from .smoke import FRAME_DIR_NAME, frame_delta, live_tap_names, station_pids
from .spec import load_spec

#: A frame that has not moved at all still moves a little: a blinking cursor, a
#: clock. Below this two shots are "the same screen" for the purposes above.
SAME = 0.01


def _say(step: str, detail: str = "") -> None:
    print(f"[hold] {step}{': ' + detail if detail else ''}", flush=True)


def _shot(clone, path: Path) -> Path:
    return clone.screenshot(path)


def settle(clone, path: Path, deadline: float, quiet: float = 1.5) -> Path:
    """Return once the screen has stopped changing, or at `deadline`.

    `quiet` consecutive seconds of a still frame, not a guessed sleep: a guest
    that finishes painting in 200 ms costs 200 ms here, and one that is still
    restoring is waited for rather than photographed mid-paint.
    """
    last = _shot(clone, path)
    still = 0.0
    while time.time() < deadline:
        time.sleep(0.25)
        nxt = _shot(clone, path.with_suffix(".probe.ppm"))
        if frame_delta(last, nxt) < SAME:
            still += 0.25
            if still >= quiet:
                break
        else:
            still = 0.0
        last = _shot(clone, path)
    path.with_suffix(".probe.ppm").unlink(missing_ok=True)
    return _shot(clone, path)


def moved(clone, was: Path, path: Path, deadline: float) -> bool:
    """Return True the moment the screen differs from `was`."""
    while time.time() < deadline:
        if frame_delta(was, _shot(clone, path)) >= SAME:
            return True
        time.sleep(0.25)
    return False


def warm_up(broker, stations: list, deadline: float) -> bool:
    """Poll `pools()` until every station has a free member, or give up.

    `set_access("open")` returns immediately — `warm.py` builds unlocked in a
    background thread and a restore is minutes — so reading `_members` on the
    next line raises `StopIteration`. A driver must poll, and this is that poll.
    """
    while time.time() < deadline:
        free = {p["os"]: p["free"] for p in broker.pools()}
        if all(free.get(s, 0) > 0 for s in stations):
            return True
        time.sleep(2.0)
    return False


def wreck(clone, frames: Path, deadline: float) -> Path:
    """Leave the machine VISIBLY changed, the way a visitor would.

    Ctrl+Esc is the task list on OS/2 and the Start menu on Windows: one key,
    no typing, a large opaque rectangle that no golden ever restores with. What
    matters is only that the screen afterwards is unmistakably not the screen
    before, which `moved()` checks rather than assumes.
    """
    before = _shot(clone, frames / "2-before-wreck.ppm")
    with clone.qmp() as conn:
        conn.execute("send-key", keys=[{"type": "qcode", "data": "ctrl"}, {"type": "qcode", "data": "esc"}])
    if not moved(clone, before, frames / "2-wreck-probe.ppm", deadline):
        _say("WARNING", "the guest did not react to ctrl+esc — the resume proof will be weak")
    return settle(clone, frames / "3-wrecked.ppm", deadline)


def run(broker, first: str, second: str, frames: Path, offset: list, budget: float) -> dict:
    """Claim A, wreck it, switch to B, come back to A, then let the hold lapse."""
    out: dict = {}
    visitor = "hold-visitor"

    pristine = None
    claim = broker.claim(visitor, first)
    _say("claimed", json.dumps(claim))
    member = broker._members[claim["clone"]]
    pristine = settle(member.clone, frames / "1-pristine.ppm", time.time() + budget)

    wrecked = wreck(member.clone, frames, time.time() + budget)
    out["wreck_delta"] = frame_delta(pristine, wrecked)
    _say("wrecked", f"the screen moved {out['wreck_delta']:.4%} from the machine they were handed")

    # --- the switch -------------------------------------------------------
    away = broker.claim(visitor, second)
    _say("switched", f"{claim['clone']} -> {away['clone']}")
    out["held_is_frozen"] = broker.is_frozen(claim["clone"])
    out["held_is_still_a_member"] = claim["clone"] in broker._members
    out["held_root_kept"] = member.clone.plan.root.exists()
    out["held_ticket_ttl"] = broker.ticket_ttl_for(claim["clone"], 300)
    out["holds_reported"] = broker.holds_of(visitor)
    frozen_shot = _shot(member.clone, frames / "4-frozen.ppm")
    out["frozen_vs_wrecked"] = frame_delta(wrecked, frozen_shot)
    _say("held", json.dumps(out["holds_reported"]))

    # --- and back ---------------------------------------------------------
    back = broker.claim(visitor, first)
    _say("returned", json.dumps(back))
    out["same_clone"] = back["clone"] == claim["clone"]
    out["marked_resumed"] = bool(back.get("resumed"))
    resumed = settle(member.clone, frames / "5-resumed.ppm", time.time() + budget)
    out["resumed_vs_wrecked"] = frame_delta(wrecked, resumed)
    out["resumed_vs_pristine"] = frame_delta(pristine, resumed)
    _say(
        "resumed",
        f"differs from the wrecked screen by {out['resumed_vs_wrecked']:.4%} and from "
        f"the one they were first handed by {out['resumed_vs_pristine']:.4%}",
    )

    # --- the window ends --------------------------------------------------
    away = broker.claim(visitor, second)  # leave it again, so it is a hold when it lapses
    # A visitor DRIVING a machine has sent `POST /walkin/engage`, which is what
    # keeps the 180-second idle window fresh and takes the session out of it
    # (`Holding.retime`). Without standing in for that here, the clock jump
    # below idle-reaps the machine they are on as well, and the proof that a
    # lapsing HOLD posts no session-end is measured against the wrong machine —
    # the first run of this tool failed on exactly that, and the code was right.
    broker.retime(visitor, away["clone"], broker_mod.TTL_SECONDS)
    out["claims_while_held"] = claims.walkin_claims_held()
    root = member.clone.plan.root
    tap = member.clone.plan.tap
    broker.warm = False  # do not spend minutes restoring a replacement mid-proof
    offset[0] += HOLD_SECONDS + 1
    reaped = broker.tick()
    out["reaped"] = [identity for identity, _ in reaped.get("ended", [])]
    out["hold_was_reaped"] = claim["clone"] in out["reaped"]
    out["hold_root_removed"] = not root.exists()
    out["hold_tap_removed"] = not Path("/sys/class/net", tap).exists()
    out["no_session_end_posted"] = broker.session_end(visitor) is None
    _say("lapsed", f"{claim['clone']} reaped: {out['hold_was_reaped']}, root gone: {out['hold_root_removed']}")
    return out


def verdict(out: dict) -> bool:
    """Every claim this tool makes, as one boolean. Ordered as the report reads."""
    return bool(
        out.get("wreck_delta", 0) > SAME
        and out.get("held_is_frozen")
        and out.get("held_is_still_a_member")
        and out.get("held_root_kept")
        and out.get("held_ticket_ttl") == 0
        and out.get("holds_reported")
        and out.get("frozen_vs_wrecked", 1) < SAME
        and out.get("same_clone")
        and out.get("marked_resumed")
        # THE PROOF: the screen they came back to is the one they left, not the
        # one they were handed. Stated as a comparison rather than a threshold
        # so it cannot be satisfied by a guest that simply renders very little.
        and out.get("resumed_vs_wrecked", 1) < out.get("resumed_vs_pristine", 0)
        and out.get("resumed_vs_wrecked", 1) < SAME
        and out.get("hold_was_reaped")
        and out.get("hold_root_removed")
        and out.get("hold_tap_removed")
        and out.get("no_session_end_posted")
        and not out.get("orphans")
        and not out.get("claims_left")
        and out.get("fleet_unchanged")
    )


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, action="append", help="walk-in station JSON; give it twice")
    parser.add_argument("--repo", default=".", help="repo root the launcher path is relative to")
    parser.add_argument("--budget", type=float, default=180.0, help="deadline for any single screen wait")
    parser.add_argument("--warm", type=float, default=900.0, help="deadline for the pool to come up")
    args = parser.parse_args(argv)

    if len(args.spec) < 2:
        _say("REFUSED", "two --spec arguments; 'switching' between one station is not a thing")
        return 2
    if str(naming.WALKIN_ROOT) == "/data/vms/walkin":
        _say("REFUSED", "set WALKIN_ROOT to your own sandbox before smoking the broker")
        return 2
    if not os.environ.get("KH_SESSION"):
        _say("REFUSED", "KH_SESSION is unset; every claim must name its owner")
        return 2

    specs = [load_spec(Path(p)) for p in args.spec]
    for spec in specs:
        taken = live_tap_names(spec)
        if taken:
            # Rule 7 in the one place WALKIN_ROOT does not reach: an interface
            # name is a single global namespace shared with the live pool.
            _say("REFUSED", f"{', '.join(taken)} already exist in the kernel — a live {spec.station} cell owns one")
            return 2

    frames = naming.WALKIN_ROOT / FRAME_DIR_NAME
    frames.mkdir(parents=True, exist_ok=True)
    fleet_before = station_pids()
    offset = [0.0]
    broker = broker_mod.Broker(
        Path(args.spec[0]).parent, Path(args.repo), now=lambda: time.time() + offset[0], daemon=False
    )
    broker.specs = {spec.station: spec for spec in specs}
    out: dict = {}
    try:
        _say("open the plane", ", ".join(f"{s.station} x{s.pool_size}" for s in specs))
        broker.set_access("open")
        if not warm_up(broker, [s.station for s in specs], time.time() + args.warm):
            _say("FAILED", f"the pool never came up: {json.dumps(broker.pools())}")
            return 1
        _say("pool", json.dumps(broker.pools()))
        out = run(broker, specs[0].station, specs[1].station, frames, offset, args.budget)
    finally:
        broker.close_all()
        out["orphans"] = [p.name for p in naming.WALKIN_ROOT.iterdir() if p.is_dir() and p.name.startswith("walkin-")]
        out["claims_left"] = claims.walkin_claims_held()
        out["fleet_unchanged"] = station_pids() == fleet_before
        print(json.dumps(out, indent=2, default=str))
    ok = verdict(out)
    _say("VERDICT", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

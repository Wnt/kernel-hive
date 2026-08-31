#!/usr/bin/env python3
"""fleet_rollout.py — restart the streamhost fleet in waves, never all at once.

    scripts/dev/fleet_rollout.py                 PLAN ONLY (the default). Prints
                                                 the wave order, every skip and
                                                 its reason, and the exact
                                                 command each wave will run.
    scripts/dev/fleet_rollout.py --apply         execute the plan
    scripts/dev/fleet_rollout.py --resume        continue an interrupted rollout
                                                 (add --apply to execute)

The operator's requirement, verbatim: "it's OK to restart all the stations, but
do avoid restarting them all at once."

WHAT THIS IS NOT. `scripts/dev/build-deploy.sh --canary <station>` then
`--promote` already rolls a NEW BINARY across the fleet in bounded waves, with
atomic pointer moves and per-wave rollback. That machinery is not duplicated
here: `--mode promote` drives it one wave at a time. What build-deploy.sh has no
room for (it sits at 599 lines against a 600-line hard cap) is the policy this
file adds — risk-ordered waves, a settle interval, a FRAMEBUFFER health gate,
claim-aware skips, and a resumable journal.

THE HEALTH GATE IS THE FRAMEBUFFER (AGENTS.md rule 9). Three tiers run per wave,
and a wave must clear all three before the next one starts:

  1. the unit is active AND the daemon logged its own `LISTENING udp/ tile=<t>`
     line from THIS invocation's MainPID — systemd goes green when the process
     execs, which is well before the UDP socket exists;
  2. a settle interval, so a guest that is going to fall over has time to;
  3. a real screendump per station, pulled through labctl's own capture
     dispatcher (QMP / x11spike / shm, whichever that station uses) with
     resume=False, and required to decode and to be non-black.

Tier 3 is the one that means anything. Tiers 1 and 2 are logs and clocks.

THE FLOOR IS RELATIVE, NOT FLAT. mpf2 (0.286% non-black, `ui: home-computer`,
same class as c64 at 61.8%) proved a class-based floor cannot work either, the
way alpine (0.372%, `text-console`) proved one flat percentage could not: no
class predicts a station's brightness, only the station itself does. So each
wave captures a BEFORE frame per station just ahead of its restart, and the
AFTER frame only has to clear half of it (fleet_rollout_policy.effective_floor)
— enough to catch a guest that comes back fully black or stops producing
frames, loose enough not to fire on a station that legitimately looks almost
black. `--min-nonblack` still works as the operator's explicit ceiling: no
computed floor, relative or class-based, is ever allowed to demand more than
that. See docs/lab/FLEET-ROLLOUT.md, "the frame gate's floor".

WHAT IS SKIPPED, AND WHY EACH:
  * a unit that is not `active` — stopping a station is how the fleet is parked
    on purpose, so a stopped or failed unit is left exactly as it is;
  * a station another session holds a kh-claim on (AGENTS.md rule 7) — read from
    the claim registry, never guessed; `stale`/`dead` claims do not skip;
  * a station with a visitor connected right now (`--include-busy` to override);
  * anything named with `--exclude`.

PAUSED IS NOT PARKED. 36 of 71 live stations were `paused` when this was
written, because the daemon idle-auto-pauses an unwatched exhibit after ~60 s.
Skipping paused stations would skip half the fleet and roll out nothing, so
paused is reported and NOT skipped. `--skip-paused` is available for the
operator who wants it and is off by default.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PROBE = REPO / "scripts" / "host" / "fleet-rollout-probe.sh"
LABRUN = REPO / "scripts" / "dev" / "labrun"
BUILD_DEPLOY = REPO / "scripts" / "dev" / "build-deploy.sh"
LAB = os.environ.get("LAB", "lab")

# fleet_rollout_policy.py is the pure half of this tool (registry, wave order,
# claim/skip rules, the frame-gate floor math) — split out because this file
# sits at the 600-line hard cap in scripts/check-file-size.mjs --strict, with
# no room left to grow. Importable from either layout: run directly (sys.path[0]
# is already this directory) or loaded by path from scripts/test_fleet_rollout.py
# (which is not), so the directory is added explicitly rather than assumed.
sys.path.insert(0, str(Path(__file__).resolve().parent))
# CONSOLE_FLOOR, REGISTRY, claim_owner, claim_token_match, min_nonblack_for and
# relative_floor are not called directly below — classify()/effective_floor()
# call them internally — but they stay imported here on purpose:
# scripts/test_fleet_rollout.py loads THIS file (not the policy module) and
# pins every one of them down as ROLLOUT.<name>.
from fleet_rollout_policy import (  # noqa: E402,F401
    CONSOLE_FLOOR,
    REGISTRY,
    SAFE_TILE,
    claim_owner,
    claim_token_match,
    classify,
    effective_floor,
    load_registry,
    make_waves,
    min_nonblack_for,
    order_stations,
    pending_after_resume,
    promotable,
    relative_floor,
    risk_score,
)

# build-deploy.sh's verified-canary gate: "<artifact> <tile>" on one line.
CANARY_GATE = "/usr/local/lib/streamhost/.canary-ready"

BOLD, RED, GRN, YLW, DIM, OFF = "\033[1m", "\033[31m", "\033[32m", "\033[33m", "\033[2m", "\033[0m"


def step(msg):
    print(f"\n{BOLD}==> {msg}{OFF}")


def ok(msg):
    print(f"    [{GRN}OK{OFF}] {msg}")


def warn(msg):
    print(f"    [{YLW}WARN{OFF}] {msg}")


def fail(msg):
    print(f"    [{RED}FAIL{OFF}] {msg}")


def die(msg):
    fail(msg)
    sys.exit(1)


# The pure policy that used to live here — registry loading, wave order,
# claim/skip rules, both non-black floors — is scripts/dev/fleet_rollout_policy.py
# now (imported above). scripts/test_fleet_rollout.py pins it down before any
# of it is allowed near a machine.

# ---- box side ------------------------------------------------------------


def ssh_lab(command, timeout=300):
    argv = ["ssh", "-n", "-o", "ConnectTimeout=15", LAB, command]
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)


def probe(*args, timeout=300):
    argv = [str(LABRUN), str(PROBE), *args]
    r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        die("probe failed ({}): {}".format(" ".join(args[:2]), (r.stderr or r.stdout).strip()[:400]))
    try:
        return json.loads(r.stdout)
    except ValueError:
        die(f"probe returned no JSON: {r.stdout[:300]}")


def read_canary_tile():
    """The tile named by build-deploy.sh's own verified-canary gate. Read, not
    assumed: the gate is `<artifact> <tile>`, and the tile is whoever
    was last canaried — not necessarily SAFE_TILE. Falling back to SAFE_TILE
    keeps a plan-only run working on a box with no gate at all.
    """
    r = ssh_lab(f"sed -n '1p' '{CANARY_GATE}' 2>/dev/null || true")
    parts = (r.stdout or "").split()
    return parts[1] if len(parts) >= 2 else SAFE_TILE


def restart_wave(wave):
    units = " ".join(f"streamhost@{s}.service" for s in wave)
    r = ssh_lab(f"systemctl restart {units}")
    if r.returncode != 0:
        fail(f"systemctl restart failed: {(r.stderr or r.stdout).strip()[:300]}")
        return False
    return True


def promote_wave(wave, live, canary_tile):
    """Move the binary for exactly this wave, through build-deploy.sh --promote.

    --exclude is build-deploy.sh's own supported way to hold stations back, and
    --promote skips anything already on the gated artifact, so handing it a
    one-wave-wide exclusion list reuses its atomic pointer moves and its
    per-wave restore instead of reimplementing them here.
    """
    movable = promotable(wave, canary_tile)
    if not movable:
        ok(f"{canary_tile}: already on the gated artifact as build-deploy.sh's canary — health-gating only")
        return True
    argv = [str(BUILD_DEPLOY), "--promote", "--wave-size", str(len(movable))]
    for station in live:
        if station not in wave:
            argv += ["--exclude", station]
    print("    {}{}{}".format(DIM, " ".join(argv), OFF))
    return subprocess.run(argv).returncode == 0


def await_readiness(wave, timeout_s):
    """Tier 1: unit active plus the daemon's own LISTENING line from its new PID."""
    deadline = time.time() + timeout_s
    waiting = list(wave)
    while waiting and time.time() < deadline:
        state = probe("state", *waiting)["tiles"]
        waiting = [
            s
            for s in waiting
            if not (state.get(s, {}).get("unit_active") == "active" and state.get(s, {}).get("listening"))
        ]
        if waiting:
            time.sleep(5)
    return waiting


def capture_frames(wave):
    """One screendump per station via the probe's own capture dispatcher.

    fleet-rollout-probe.sh handles the one known transient itself: a station
    idle-auto-paused between readiness and the settle sleep, whose shm
    framebuffer read fails deterministically (not flakily — see the probe
    script) against the normal untorn-read path. There is nothing left for
    this side to retry; a failure that reaches here is a real one.
    """
    return probe("frames", *wave)


def before_frames(wave, no_frame_gate):
    """Grab each station's OWN frame just ahead of restarting it, for the
    relative floor in frame_gate(). Best-effort: a station this fails for
    simply falls back to the class-based floor (fleet_rollout_policy.
    effective_floor), so a bad before-capture never makes a station
    un-gateable — only less precisely gated. Skipped entirely with
    --no-frame-gate, since nothing will read it."""
    if no_frame_gate:
        return {}
    return {row["tile"]: row for row in capture_frames(wave)}


def frame_gate(wave, min_nonblack, entries, before):
    """Tier 3: the only proof a guest actually came back.

    `before` is this same wave's own pre-restart frames (before_frames()),
    keyed by station. effective_floor() uses it to ask "did this station come
    back to what it was" instead of "is it above one flat percentage" — see
    fleet_rollout_policy.effective_floor for why a flat number cannot work.
    """
    bad = []
    for row in capture_frames(wave):
        station = row["tile"]
        floor = effective_floor(entries.get(station) or {}, before.get(station), min_nonblack)
        if not row.get("ok"):
            fail("{}: no framebuffer ({})".format(station, row.get("error")))
            bad.append(station)
        elif row["nonblack_pct"] < floor:
            was = before.get(station, {})
            was_txt = f", was {was['nonblack_pct']:.3f}% before restart" if was.get("ok") else ""
            fail(f"{station}: framebuffer is black ({row['nonblack_pct']:.3f}% non-black, need {floor:.3f}%{was_txt})")
            bad.append(station)
        else:
            ok(f"{station}: {row['width']}x{row['height']}, {row['nonblack_pct']:.1f}% non-black")
    return bad


# ---- state journal -------------------------------------------------------


def state_path(args):
    if args.state:
        return Path(args.state)
    return REPO / ".fleet-rollout" / (f"{args.tag}.json")


def save_state(path, doc):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(doc, indent=2, sort_keys=True))
    tmp.replace(path)


def resume_command(args, path):
    cmd = [
        "scripts/dev/fleet_rollout.py",
        "--resume",
        "--tag",
        args.tag,
        "--state",
        str(path),
        "--wave-size",
        str(args.wave_size),
        "--settle",
        str(args.settle),
    ]
    if args.mode != "restart":
        cmd += ["--mode", args.mode]
    return " ".join(cmd) + " --apply"


def report_state(doc, waves_remaining):
    step("fleet state")
    remaining = {s for wave in waves_remaining for s in wave}
    for station in doc["plan"]:
        status = doc["status"].get(station, "PENDING")
        colour = {"DONE": GRN, "FAILED": RED}.get(status, YLW)
        note = doc["skips"].get(station, "")
        print(f"    {colour}{status:<8}{OFF} {station:<14} {note}")
    done = sum(1 for v in doc["status"].values() if v == "DONE")
    failed = sum(1 for v in doc["status"].values() if v == "FAILED")
    print(f"    {done} done, {failed} failed, {len(remaining)} still pending")


# ---- main ----------------------------------------------------------------


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        prog="fleet_rollout.py",
        description="Restart the streamhost fleet in risk-ordered waves with a framebuffer health gate.",
        epilog="Run it with no flags first: that prints the plan and changes nothing.",
    )
    p.add_argument("--apply", action="store_true", help="execute the plan (default: plan only)")
    p.add_argument("--resume", action="store_true", help="continue the rollout recorded in the state file")
    p.add_argument(
        "--mode",
        choices=("restart", "promote"),
        default="restart",
        help="restart: systemctl restart only. promote: move the binary per wave via build-deploy.sh --promote",
    )
    p.add_argument("--wave-size", type=int, default=4, help="stations per wave (default 4)")
    p.add_argument(
        "--no-canary-first",
        action="store_true",
        help="do not make wave 1 a single station (default: it is, so a bad roll costs one exhibit)",
    )
    p.add_argument("--settle", type=int, default=45, help="seconds to settle after a wave is ready")
    p.add_argument("--readiness-timeout", type=int, default=180, help="seconds to wait for a wave's daemons to listen")
    p.add_argument("--min-nonblack", type=float, default=0.5, help="percent of non-black pixels a healthy frame needs")
    p.add_argument("--exclude", action="append", default=[], metavar="STATION")
    p.add_argument("--only", action="append", default=[], metavar="STATION", help="restrict the rollout to these")
    p.add_argument(
        "--skip-paused",
        action="store_true",
        help="also skip idle-paused guests (off: paused is the fleet's normal resting state)",
    )
    p.add_argument("--include-busy", action="store_true", help="restart a station even while a visitor is connected")
    p.add_argument(
        "--no-frame-gate",
        action="store_true",
        help="WEAKER: accept daemon readiness as health, with no framebuffer proof",
    )
    p.add_argument("--tag", default="rollout", help="name for this rollout's state file")
    p.add_argument("--state", help="path to the resumable state file")
    return p.parse_args(argv)


def build_plan(args, canary_tile):
    entries = load_registry()
    snapshot = probe("state")
    tiles_state, claims = snapshot["tiles"], snapshot["claims"]
    order = order_stations(entries, safe_tile=canary_tile)
    targets, skipped = classify(
        entries,
        order,
        tiles_state,
        claims,
        excludes=set(args.exclude),
        only=set(args.only),
        skip_paused=args.skip_paused,
        skip_busy=not args.include_busy,
    )
    return entries, tiles_state, targets, skipped


def main(argv=None):
    args = parse_args(argv)
    if args.wave_size < 1:
        die("--wave-size must be >= 1")
    path = state_path(args)
    # In promote mode the fleet moves onto ONE gated artifact, and which station
    # already carries it is a fact on the box, not a default in this file.
    canary_tile = read_canary_tile() if args.mode == "promote" else SAFE_TILE

    if args.resume:
        if not path.exists():
            die(f"no rollout state at {path}")
        doc = json.loads(path.read_text())
        step(f"resuming rollout '{doc['tag']}' from {path}")
        targets = doc["plan"]
        done = [s for s, v in doc["status"].items() if v == "DONE"]
        ok(f"{len(done)} of {len(targets)} stations already done")
        # The box has moved on since the rollout stopped — that is WHY it
        # stopped. A station that has since been claimed, stopped or opened by a
        # visitor must be re-skipped, so the remaining plan is re-classified
        # against a fresh snapshot rather than trusted from the journal.
        entries = load_registry()
        snapshot = probe("state")
        tiles_state = snapshot["tiles"]
        pending = [s for s in targets if s not in done]
        still, fresh_skips = classify(
            entries,
            pending,
            tiles_state,
            snapshot["claims"],
            excludes=set(args.exclude),
            only=set(args.only),
            skip_paused=args.skip_paused,
            skip_busy=not args.include_busy,
        )
        doc["skips"].update(dict(fresh_skips))
        skipped = list(doc["skips"].items())
        if fresh_skips:
            warn(f"{len(fresh_skips)} station(s) became untouchable since the rollout stopped")
    else:
        entries, tiles_state, targets, skipped = build_plan(args, canary_tile)
        still = None
        doc = {
            "tag": args.tag,
            "mode": args.mode,
            "wave_size": args.wave_size,
            "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "plan": targets,
            "status": {},
            "skips": dict(skipped),
        }
        done = []

    waves = pending_after_resume(make_waves(targets, args.wave_size, not args.no_canary_first), done)
    if still is not None:  # a resume keeps the original wave boundaries, minus the new skips
        allowed = set(still)
        waves = [w for w in ([s for s in wave if s in allowed] for wave in waves) if w]
    live = [s for s, v in tiles_state.items() if v.get("unit_active") == "active"]

    step(
        f"plan: {sum(len(w) for w in waves)} stations in {len(waves)} waves "
        f"of {args.wave_size}, {args.settle}s settle between waves"
    )
    for n, wave in enumerate(waves, 1):
        detail = [f"{s}({risk_score(entries[s])}{',SAFE' if s == canary_tile else ''})" for s in wave]
        print(f"    wave {n:<3} {' '.join(detail)}")
    print(f"    {DIM}(the number is the station's risk score; SAFE is build-deploy.sh's own canary tile.{OFF}")
    print(f"    {DIM} wave 1 is a single station on purpose — --no-canary-first turns that off){OFF}")

    if skipped:
        step(f"skipped: {len(skipped)} station(s)")
        for station, reason in skipped:
            print(f"    {station:<14} {reason}")

    step("each wave will run")
    if not args.no_frame_gate:
        print("    a screendump per station, BEFORE it restarts (best-effort — the wave's own baseline)")
    if args.mode == "promote":
        print("    scripts/dev/build-deploy.sh --promote --wave-size <n> --exclude <every other live station>")
        print(f"    {DIM}(not the canary wave: {canary_tile} runs the gated artifact already — health-gated only){OFF}")
    else:
        print(f"    ssh {LAB} 'systemctl restart streamhost@<a>.service streamhost@<b>.service ...'")
    print("    then: readiness (unit active + the daemon's own LISTENING line from its new MainPID)")
    print(f"    then: {args.settle}s settle")
    if args.no_frame_gate:
        print(f"    then: {YLW}NO FRAMEBUFFER GATE (--no-frame-gate): readiness is the only health signal{OFF}")
    else:
        print(
            f"    then: a screendump per station, required to decode and clear HALF its own before-frame "
            f"(floor >= {args.min_nonblack:.2f}% when there is no usable before-frame)"
        )

    if not args.apply:
        step("PLAN ONLY — nothing was restarted")
        ok("this is the recommended first invocation; re-run with --apply to execute")
        print(f"    state file will be {path}")
        return 0

    step("applying")
    for n, wave in enumerate(waves, 1):
        print(f"\n  {BOLD}wave {n}/{len(waves)}: {' '.join(wave)}{OFF}")
        before = before_frames(wave, args.no_frame_gate)
        started = restart_wave(wave) if args.mode == "restart" else promote_wave(wave, live, canary_tile)
        bad = list(wave) if not started else []
        if started:
            not_ready = await_readiness(wave, args.readiness_timeout)
            for station in not_ready:
                fail(f"{station}: never logged LISTENING within {args.readiness_timeout}s")
            bad = list(not_ready)
            if not bad and not args.no_frame_gate:
                print(f"    settling {args.settle}s ...")
                time.sleep(args.settle)
                bad = frame_gate(wave, args.min_nonblack, entries, before)
        for station in wave:
            doc["status"][station] = "FAILED" if station in bad else "DONE"
        save_state(path, doc)
        if bad:
            report_state(doc, waves[n - 1 :])
            step(f"ROLLOUT HALTED after wave {n}")
            fail(f"failed: {' '.join(bad)}")
            print("\n    resume once the failure is understood and fixed:")
            print(f"      {resume_command(args, path)}")
            print("\n    to put a failed station back on its previous binary (ONE station at a time,")
            print("    supervised — this tool never rolls the fleet back on its own):")
            for station in bad:
                print(f"      scripts/dev/build-deploy.sh --rollback {station}")
            print("\n    stations already restarted in earlier waves are NOT reverted by that.")
            return 2
        ok(f"wave {n} healthy")

    report_state(doc, [])
    step(f"rollout complete: {len(doc['status'])} station(s)")
    ok(f"state journal kept at {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

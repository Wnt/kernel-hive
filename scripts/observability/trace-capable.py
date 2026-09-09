#!/usr/bin/env python3
"""Which live stations run a daemon binary that can JOIN an input trace.

THE INCIDENT THIS EXISTS FOR (2026-09-01). A keystroke trace showed one span —
the browser's `input.edge` — and Instana labelled the call "To input.edge of
Unspecified". Over a six-hour window only 37% of sampled input edges had the
daemon's `input.dispatch` beside them, which reads like a sampling bug, a lost
spool or a broken propagation path. It was none of those. The browser samples
once and carries the decision on the wire; every station running a binary that
knows about the suffix joined **100%** of its edges. The 63% was ONE station —
win95 — running a binary from before the sampled-input code existed, doing
exactly what `input_trace.rs` documents an old daemon should do: read the
record's fixed fields off the front, ignore the 25-byte tail, land the click,
emit nothing. The join rate was a DEPLOYMENT-COVERAGE number wearing an
instrumentation bug's clothes.

That confusion is the thing worth preventing, and it is structural, not a
one-off: `docs/lab/TRACE-CONTEXT.md` §8 says version skew between browser and
daemon is the NORMAL state, because the fleet rolls in canaried waves and the
SPA deploys independently of it. So "some stations cannot join" will be true
again, on purpose, every time a wave is in flight. What was missing was a way
to SEE it — a station that cannot trace looked identical to a station that
would not.

    scripts/dev/labrun scripts/observability/trace-capable.py
    ssh lab 'scripts/dev/labrun scripts/observability/trace-capable.py --quiet'

RUN THIS ON THE BOX. It resolves each running daemon through `/proc/<pid>/exe`
— never a cmdline grep (AGENTS.md rule 5) — and looks for the marker string in
the mapped binary. It starts nothing, stops nothing and writes nothing.

WHY A STRING SEARCH AND NOT A VERSION FIELD. The daemon has no version
endpoint, and adding one would only move the question: a version number still
has to be mapped to "does this build carry the feature". The span NAME is the
feature — `input.dispatch` is a `&'static str` in `trace_session.rs`, so it is
in `.rodata` of every build that can emit it and in no build that cannot. That
is a direct test of the capability rather than a proxy for it.

Exit status is 0 when every live station can join and 1 when any cannot, so a
rollout script or a human can gate on it.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

#: The marker: the daemon span an old binary has no name for.
MARKER = b"input.dispatch"
BOLD, RED, GRN, YLW, DIM, OFF = "\033[1m", "\033[31m", "\033[32m", "\033[33m", "\033[2m", "\033[0m"


def live_stations() -> list[str]:
    """Active `streamhost@<station>` units, as systemd sees them."""
    out = subprocess.run(
        ["systemctl", "list-units", "streamhost@*", "--no-legend", "--state=active"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout
    names = []
    for line in out.splitlines():
        unit = line.split()[0] if line.split() else ""
        if unit.startswith("streamhost@") and unit.endswith(".service"):
            names.append(unit[len("streamhost@") : -len(".service")])
    return sorted(names)


def running_binary(station: str) -> Path | None:
    """The binary this station's daemon is ACTUALLY running, via /proc.

    Resolved from the unit's MainPID through `/proc/<pid>/exe` — the identity
    the kernel holds, not a path anyone typed. A station whose unit reports no
    main pid (starting, or just died) returns None and is reported as unknown
    rather than as a failure: this tool refuses to turn "I could not look" into
    "it is broken"."""
    pid = subprocess.run(
        ["systemctl", "show", "-p", "MainPID", "--value", f"streamhost@{station}.service"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    if not pid.isdigit() or pid == "0":
        return None
    try:
        return Path(f"/proc/{pid}/exe").resolve(strict=True)
    except OSError:
        return None


def can_join(binary: Path) -> bool | None:
    """True when this build can emit `input.dispatch`. None when unreadable."""
    try:
        return MARKER in binary.read_bytes()
    except OSError:
        return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--quiet", action="store_true", help="print only the stations that cannot join")
    a = ap.parse_args()

    stations = live_stations()
    if not stations:
        print("no live streamhost units — nothing to report")
        return 0

    joined, stale, unknown = [], [], []
    for s in stations:
        b = running_binary(s)
        verdict = can_join(b) if b else None
        (joined if verdict is True else stale if verdict is False else unknown).append((s, b))

    if not a.quiet:
        print(f"{BOLD}== input-trace capability of the live fleet =={OFF}")
        print(f"  {GRN}can join{OFF}     {len(joined)}")
    if stale:
        print(f"  {RED}CANNOT join{OFF}  {len(stale)}  {DIM}(old binary: an edge lands, no span){OFF}")
        for s, b in stale:
            print(f"      {RED}{s:<16}{OFF} {DIM}{b}{OFF}")
        print(
            f"  {DIM}fix: python3 scripts/dev/fleet_rollout.py --mode promote "
            f"{' '.join('--only ' + s for s, _ in stale)} --apply{OFF}"
        )
    if unknown:
        print(f"  {YLW}unknown{OFF}      {len(unknown)}  {DIM}(no main pid, or binary unreadable){OFF}")
        for s, _ in unknown:
            print(f"      {YLW}{s}{OFF}")
    if not stale and not a.quiet:
        print(f"  {GRN}every live station can join a sampled input trace{OFF}")
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())

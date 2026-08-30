"""Live-state drift: what the box's labctl roster says vs what the registry declares.

This is a REPORT, not a gate, and the distinction is the whole point of the file
existing. It used to run inside `stations-registry.py check` — i.e. inside the
pre-push gate — where it asked a question no commit can answer: "does the LIVE
box already agree with this declaration?" A push gate may only test properties of
the commit being pushed. Live divergence is a property of the box at this instant,
shared by every session, and unsatisfiable by the author of an unrelated change.

On 2026-08-30 that cost the lab a day: three stations' `pointer_mode` declarations
were committed ahead of their cutover, the cutover then failed acceptance and
correctly rolled back, and the stranded declarations made `main` unpushable for
every session in the lab — a one-file docs commit from an unrelated agent was
refused for it. The gate punished a rollback for working properly, and the lesson
everybody learned was `SKIP_GATE=1`. The wedge finally cleared by REVERTING the
declarations to match live, because live could not be advanced to match them.

So the same comparison now runs here, out of the push path:

    python3 scripts/stations-registry.py drift

A mismatch is the convergence loop's to-do list, not anybody's failure. Modelled
on `facts-live` (see facts_live.py): a box that cannot be read SKIPs loudly and
exits 0; only a box that can be read and DISAGREES exits 1.

Declaring ahead of a cutover is normal and expected. Read a FAIL here as "these
stations have not been cut over yet", and go look at why — never as "this branch
is broken".
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from .constants import LABCTL_KEYS
from .generate import generated

# Bind-mounted into CT950, so this is a plain read, not an ssh round trip.
LIVE_ROSTER = Path("/data/vms/streamhost/stations.json")

# labctl reports observed golden state inside `notes`; the registry cannot and
# must not declare it. Strip it before comparing, or every probe failure reads
# as a declaration mismatch.
_OBSERVED_GOLDEN = re.compile(r"; (?:no 'golden' snapshot found:.*|golden snapshot state unknown \(probe failed\))$")


def live_labctl_mismatches() -> list[str]:
    """Every declared-field disagreement between the live roster and the registry."""
    current = json.loads(LIVE_ROSTER.read_text()).get("tiles", {})
    declared = json.loads(generated()["registry/generated/labctl-declarations.json"])["tiles"]
    mismatches = []
    if set(current) != set(declared):
        mismatches.append(f"tile set current={sorted(current)} declared={sorted(declared)}")
    for tile in sorted(set(current) & set(declared)):
        for key in LABCTL_KEYS:
            actual = current[tile].get(key)
            if key == "notes" and isinstance(actual, str):
                actual = _OBSERVED_GOLDEN.sub("", actual)
            if actual != declared[tile].get(key):
                mismatches.append(f"{tile}.{key}: live={current[tile].get(key)!r} declared={declared[tile].get(key)!r}")
    return mismatches


def cmd_drift() -> int:
    """Report declared-vs-live station drift. Unreadable roster = SKIP, exit 0."""
    print("== station declaration drift (live labctl roster) ==")
    if not LIVE_ROSTER.exists():
        print(f"  SKIPPED: {LIVE_ROSTER} absent (public clone, offline, or CI)")
        return 0
    try:
        mismatches = live_labctl_mismatches()
    except (OSError, ValueError) as exc:
        print(f"  SKIPPED: could not read {LIVE_ROSTER}: {exc}")
        return 0
    if mismatches:
        print(f"  DRIFT — {len(mismatches)} declared field(s) the live box does not carry yet:")
        for line in mismatches:
            print(f"    - {line}")
        print("  These stations are declared ahead of their cutover. That is a convergence")
        print("  to-do, not a push failure — nothing here blocks anyone's commit.")
        return 1
    print("  ok — live labctl declarations match the registry (observed golden state excluded)")
    return 0


def main() -> int:
    return cmd_drift()


if __name__ == "__main__":
    raise SystemExit(main())

"""kh-reconciler — read-only convergence status (stage 3).

WHAT THIS REPLACES. "What does the box actually run?" is today answered by
forensics: ssh in, read a root-owned `.deployed-rev` an agent cannot open, run
box-install's dry run, and reason about the difference. This answers it per
UNIT, from the repo, and reports per-unit drift as the loop's to-do list rather
than as anybody's failure — the same code, opposite plumbing, that stage 1 moved
out of the push gate.

STAGE 3 IS READ-ONLY AND WRITES NOTHING, ANYWHERE. No service is installed, no
clone is created, no live path is touched. Every subcommand is a pure read, and
there is a test that runs them under an audit hook asserting zero writes — the
2026-08-24 dry-run-that-mutated incident is exactly why a read path gets a test
rather than a promise.

    kh-reconciler units      the release units and their members
    kh-reconciler plan       desired closure per unit at a commit
    kh-reconciler status     plan + live state + convergence liveness
    kh-reconciler denylist   the state-of-record paths, and the proof no unit
                             can contain one
    kh-reconciler rows       every deployed row vs unit membership — a row no
                             unit claims would be converged by nobody, forever
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

from .closure import unit_closures
from .denylist import NEVER_DERIVED, PROTECTED, ProtectedPathError, is_protected
from .units import build_units, station_ids, unclaimed_live_rows

# Written by the loop in stage 5; absent until then, and its absence is a
# LOUD, correct answer rather than an empty table.
JOURNAL = Path("/data/vms/streamhost/.kh-reconciler/journal.jsonl")
BACKSTOP_INTERVAL_S = 30 * 60


def git(*args: str, cwd=None) -> str:
    out = subprocess.run(["git", *args], cwd=str(cwd) if cwd else None, capture_output=True, text=True, timeout=120)
    return out.stdout if out.returncode == 0 else ""


def _units(repo: Path) -> dict[str, list[str]]:
    tracked = [line for line in git("ls-files", cwd=repo).splitlines() if line]
    return build_units(tracked)


def cmd_units(repo: Path, verbose: bool) -> int:
    units = _units(repo)
    stations = station_ids([line for line in git("ls-files", cwd=repo).splitlines() if line])
    print(f"== release units ({len(units)}; {len(stations)} station declarations) ==")
    for unit, members in units.items():
        print(f"  {unit:32s} {len(members):4d} member(s)")
        if verbose:
            for m in members:
                print(f"      {m}")
    return 0


def cmd_plan(repo: Path, commit: str) -> int:
    units = _units(repo)
    sha = git("rev-parse", commit, cwd=repo).strip()
    if not sha:
        print(f"kh-reconciler: unknown commit {commit!r}", file=sys.stderr)
        return 2
    print(f"== desired closures at {sha[:12]} ==")
    closures = unit_closures(git, sha, units, cwd=repo)
    for unit, info in closures.items():
        note = f"  MISSING {len(info['missing'])}" if info["missing"] else ""
        print(f"  {unit:32s} {info['hash'][:26]}  {info['count']:4d} member(s){note}")
    return 0


def _read_journal() -> list[dict]:
    if not JOURNAL.exists():
        return []
    rows = []
    try:
        for line in JOURNAL.read_text().splitlines():
            if line.strip():
                rows.append(json.loads(line))
    except (OSError, ValueError):
        return []
    return rows


def cmd_status(repo: Path, commit: str) -> int:
    rc = cmd_plan(repo, commit)
    if rc:
        return rc
    print()
    print("== convergence liveness ==")
    rows = _read_journal()
    if not rows:
        # The honest answer while stage 3 is all that exists. It must not read
        # as "converged" — silence is the failure mode this section exists for.
        print("  NO LOOP HAS EVER RUN — the reconciler is read-only at this stage, so nothing")
        print("  converges automatically yet. Deploys still go through the existing path.")
        print(f"  (a running loop would journal to {JOURNAL})")
        return 0
    last = rows[-1]
    age = int(time.time() - last.get("ts", 0))
    print(f"  last convergence   {last.get('commit', '?')[:12]} via {last.get('trigger', '?')}, {age}s ago")
    webhook = [r for r in rows if r.get("trigger") == "webhook"]
    if not webhook:
        print("  WEBHOOK HAS NEVER FIRED — every convergence so far came from the backstop or a")
        print("  manual poke. That is the trigger being silently broken, not the box being idle.")
    else:
        w_age = int(time.time() - webhook[-1].get("ts", 0))
        print(f"  last webhook-sourced {w_age}s ago")
        if w_age > 4 * BACKSTOP_INTERVAL_S:
            print("  RUNNING ON THE BACKSTOP — deliveries have stopped arriving while the timer")
            print("  keeps converging, so everything looks healthy at a coarser latency. That is")
            print("  the shape of every incident in this design: a true signal meaning nothing.")
    return 0


PAIR_READER = r"""
. scripts/lib/box-sync-pairs.sh || exit 1
tmp=$(mktemp -d)
box_sync_load_pairs "$PWD" "${BOX_SYNC_BOX_ROOT:-/data/vms/streamhost}" "${LAB:-lab}" "$tmp" >/dev/null 2>&1
for i in "${!BOX_SYNC_LABELS[@]}"; do
  printf '%s\t%s\t%s\n' "${BOX_SYNC_LABELS[$i]}" "${BOX_SYNC_REPO_FILES[$i]}" "${BOX_SYNC_AUTHORITY[$i]}"
done
rm -rf "$tmp"
"""


def read_pair_rows(repo: Path) -> list[tuple[str, str]] | None:
    """(label, repo path) for every REPO-AUTHORITATIVE row of the ONE pair table.

    Read through the pair table's own library rather than reimplemented, so a
    row can never be claimed by a unit here and installed differently there.
    """
    out = subprocess.run(["bash", "-c", PAIR_READER], cwd=str(repo), capture_output=True, text=True, timeout=180)
    if out.returncode != 0 or not out.stdout.strip():
        return None
    rows = []
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[2] == "repo" and parts[1]:
            rows.append((parts[0], parts[1]))
    return rows or None


def cmd_rows(repo: Path) -> int:
    """Is every DEPLOYED row claimed by exactly one unit?

    A row claimed by no unit would be converged by nobody, forever — the
    "deployed-invisible" class one level up from the gap the pair table's own
    tree loops exist to close. Stage 4 must not write anything until this is
    empty, which is why it is a command and not a comment.
    """
    print("== deployed rows vs unit membership ==")
    rows = read_pair_rows(repo)
    if rows is None:
        print("  SKIPPED: could not read the pair table (needs bash and a reachable box)")
        return 0
    tracked = [line for line in git("ls-files", cwd=repo).splitlines() if line]
    stations = frozenset(station_ids(tracked))
    unclaimed = unclaimed_live_rows(rows, stations)
    print(f"  {len(rows)} repo-authoritative row(s); {len(unclaimed)} claimed by no unit")
    for label, path in unclaimed:
        print(f"    UNCLAIMED  {label:34s} {path}")
    if unclaimed:
        print("  Each of these is deployed and would be converged by NOBODY. Stage 4 must not")
        print("  write anything while this list is non-empty.")
        return 1
    print("  ok — every deployed row belongs to exactly one release unit")
    return 0


def cmd_denylist(repo: Path) -> int:
    print("== live state of record — never a closure member, never rolled back, never GC'd ==")
    for pattern in PROTECTED:
        print(f"  {pattern}")
    print(f"  fields never derived from a commit: {', '.join(NEVER_DERIVED)}")
    print()
    units = _units(repo)
    total = sum(len(m) for m in units.values())
    offenders = [m for members in units.values() for m in members if is_protected(m)]
    if offenders:
        print(f"  BREACH — {len(offenders)} unit member(s) are state of record: {offenders}")
        return 1
    print(f"  ok — none of the {total} member(s) across {len(units)} unit(s) is state of record.")
    print("  This is structural, not a convention: build_units() runs every candidate through")
    print("  refuse_if_protected(), which RAISES. A widened glob that swallowed serve/ would")
    print("  fail loudly here rather than quietly deleting an account store.")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="kh-reconciler", description=__doc__)
    ap.add_argument("--repo", default=".", help="repo to read (default: cwd)")
    ap.add_argument("--commit", default="HEAD", help="commit whose desired state to compute")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("command", choices=("units", "plan", "status", "denylist", "rows"), nargs="?", default="status")
    ns = ap.parse_args(argv)
    repo = Path(ns.repo).resolve()
    try:
        if ns.command == "units":
            return cmd_units(repo, ns.verbose)
        if ns.command == "plan":
            return cmd_plan(repo, ns.commit)
        if ns.command == "denylist":
            return cmd_denylist(repo)
        if ns.command == "rows":
            return cmd_rows(repo)
        return cmd_status(repo, ns.commit)
    except ProtectedPathError as exc:
        print(f"kh-reconciler: {exc}", file=sys.stderr)
        return 1

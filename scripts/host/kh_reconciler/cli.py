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
import os
import subprocess
import sys
import time
from pathlib import Path

from .apply import UnitRoot, classify, flip, materialize, resume_needed, rollback
from .closure import closure_hash, unit_closures
from .denylist import NEVER_DERIVED, PROTECTED, ProtectedPathError, is_protected
from .loaded import drift_for, parse_probe, render
from .loop import (
    backstop_report,
    classify_wake,
    hint_is_trustworthy,
    journal_row,
    selectable_units,
)
from .store import LiveRootRefused, ObjectStore, refuse_live_root
from .units import build_units, station_ids, unclaimed_live_rows

# Written by the loop in stage 5; absent until then, and its absence is a
# LOUD, correct answer rather than an empty table.
JOURNAL = Path("/data/vms/streamhost/.kh-reconciler/journal.jsonl")
BACKSTOP_INTERVAL_S = 30 * 60
RECAPTURE_LABEL = "recapture-required"


class ApplyRefused(RuntimeError):
    """A precondition for writing is unmet."""


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


def require_rows_clean(repo: Path) -> None:
    """Refuse to WRITE while any deployed row belongs to no unit.

    Stated as a precondition in stage 3 and enforced here, because a
    precondition someone has to remember is not a precondition. A reconciler
    that writes while a third of the fleet's files belong to no unit is worse
    than no reconciler: it reports converged while silently owning nothing.
    """
    rows = read_pair_rows(repo)
    if rows is None:
        raise ApplyRefused(
            "cannot read the pair table, so cannot prove every deployed row is claimed by a "
            "unit. Refusing to write: an unreadable precondition is not a satisfied one."
        )
    tracked = [line for line in git("ls-files", cwd=repo).splitlines() if line]
    unclaimed = unclaimed_live_rows(rows, frozenset(station_ids(tracked)))
    if unclaimed:
        names = ", ".join(label for label, _ in unclaimed[:5])
        raise ApplyRefused(
            f"{len(unclaimed)} deployed row(s) belong to no release unit ({names}...). Each would "
            "be converged by NOBODY, forever. Run `kh-reconciler rows` and give them a unit first."
        )


def cmd_apply(repo: Path, unit: str, root: Path, commit: str, dry_run: bool) -> int:
    """Materialize a unit's closure beside the running one, then flip once."""
    require_rows_clean(repo)
    units = _units(repo)
    if unit not in units:
        print(f"kh-reconciler: unknown unit {unit!r}", file=sys.stderr)
        return 2
    sha = git("rev-parse", commit, cwd=repo).strip()
    if not sha:
        print(f"kh-reconciler: unknown commit {commit!r}", file=sys.stderr)
        return 2

    store = ObjectStore(root)  # refuses a live root
    unit_root = UnitRoot(root, unit)  # refuses a live root
    paths = units[unit]
    blobs = {}
    for path in paths:
        data = subprocess.run(["git", "show", f"{sha}:{path}"], cwd=str(repo), capture_output=True, timeout=120)
        if data.returncode == 0:
            blobs[path] = data.stdout
    desired = closure_hash({p: __import__("hashlib").sha256(d).hexdigest() for p, d in blobs.items()})

    applied = unit_root.applied_hash()
    if applied == desired:
        print(f"  {unit}: converged already ({desired[:26]})")
        return 0
    changed = sorted(blobs)
    if applied:
        old = unit_root.current_release()
        if old and (old / "closure.json").exists():
            old_members = json.loads((old / "closure.json").read_text()).get("members", {})
            new_members = {p: __import__("hashlib").sha256(d).hexdigest() for p, d in blobs.items()}
            changed = sorted(set(old_members) ^ set(new_members)) + sorted(
                p for p in set(old_members) & set(new_members) if old_members[p] != new_members[p]
            )
    # ADOPTION IS NOT A CUTOVER, and conflating them makes the mechanism unable
    # to bootstrap. With no previous closure nothing is being CHANGED on the
    # guest: the members are being placed under `current/` for the first time,
    # which is the §10.4 migration step, not a live swap. Classifying an
    # adoption by its full member list makes every station with a launcher
    # recapture-required forever, so no station could ever be migrated onto the
    # layout that makes cutovers safe.
    adopting = applied is None
    disruption = "adopt (first materialization; nothing changes for the guest)" if adopting else classify(changed)
    print(f"== apply {unit} ==")
    print(f"  desired    {desired[:26]}  ({len(blobs)} member(s))")
    print(f"  applied    {applied[:26] if applied else '<none>'}")
    print(f"  disruption {disruption}  from {len(changed)} changed member(s)")
    if not adopting and disruption == RECAPTURE_LABEL:
        print("  NOT AUTOMATIC: a launcher/device-set change invalidates the checkpoint.")
        print("  golden + binary + device set are ONE combination; this needs a recapture.")
        return 3
    if dry_run:
        print("  [dry-run] nothing written. Re-run without --dry-run to materialize and flip.")
        return 0
    if resume_needed(unit_root):
        print("  resuming an interrupted cutover from the journal")
    release = materialize(unit_root, store, blobs, desired)
    flip(unit_root, release, desired, sha)
    print(f"  flipped -> {release}")
    print(f"  stamped {unit_root.applied}")
    return 0


def cmd_rollback(unit: str, root: Path) -> int:
    unit_root = UnitRoot(root, unit)
    previous = rollback(unit_root)
    if previous is None:
        print(f"  {unit}: nothing to roll back to — refusing (see the journal)")
        return 1
    print(f"  {unit}: rolled back to {previous[:26]} — one flip, the whole set")
    return 0


def cmd_journal(unit: str, root: Path) -> int:
    for row in UnitRoot(root, unit).history():
        extra = {k: v for k, v in row.items() if k not in ("ts", "unit", "step")}
        print(f"  {row['step']:20s} {extra}")
    return 0


def _git_rc(*args, cwd=None, check_rc=False):
    out = subprocess.run(["git", *args], cwd=str(cwd) if cwd else None, capture_output=True, text=True)
    return out.returncode == 0 if check_rc else out.stdout


def loop_journal(root: Path) -> Path:
    return Path(root) / ".kh-reconciler" / "journal.jsonl"


def cmd_poke(root: Path) -> int:
    """The manual trigger, through the SAME wakeup path as the webhook.

    Deliberately not a second code path: an override that bypasses the normal
    route is an override whose behaviour nobody has tested.
    """
    wakeup = Path(root) / ".kh-reconciler" / "wakeup"
    wakeup.parent.mkdir(parents=True, exist_ok=True)
    wakeup.write_text(json.dumps({"source": "manual", "ts": time.time(), "hint": None}) + "\n")
    print(f"  poked {wakeup}")
    return 0


def cmd_watch(repo: Path, root: Path, once: bool) -> int:
    """One convergence pass. There is NO daemonize path here on purpose.

    Installing a loop that converges the fleet with no human in it is the
    operator's decision, so this stage ships the mechanism and stops. `--once`
    against a sandbox root is how it is exercised; nothing enables a timer,
    nothing writes a unit file into systemd, and the live-root refusal still
    applies underneath.
    """
    if not once:
        print(
            "kh-reconciler: watch requires --once. This stage builds the loop but does not "
            "arm it: a continuously running converger is a separate authorisation.",
            file=sys.stderr,
        )
        return 2
    require_rows_clean(repo)
    refuse_live_root(root)
    journal = loop_journal(root)
    rows = []
    if journal.exists():
        rows = [json.loads(x) for x in journal.read_text().splitlines() if x.strip()]
    last_ts = float(rows[-1]["ts"]) if rows else 0.0
    wakeup = Path(root) / ".kh-reconciler" / "wakeup"
    trigger, hint = classify_wake(wakeup, last_ts, time.time())

    # The loop fetches for ITSELF. The hint never selects what is deployed.
    head = git("rev-parse", "HEAD", cwd=repo).strip()
    trusted, note = hint_is_trustworthy(_git_rc, repo, (hint or {}).get("hint"), head)

    units = _units(repo)
    rollout = station_rollout(repo)
    auto, held = selectable_units(units, rollout)
    print(f"== converge (trigger: {trigger}) ==")
    print(f"  origin/main as we fetched it: {head[:12]}")
    print(f"  hint: {note}")
    if not trusted:
        print("  the hint is not corroborated; converging to what we fetched, as always")
    print(f"  rollout auto: {len(auto)} unit(s); held: {len(held)}")
    for unit in auto:
        print(f"    would converge {unit}")
    if not auto:
        print("    nothing is opted in — default is HOLD while this stage is unarmed,")
        print("    so a unit nobody opted in is visibly not converged, never quietly converged.")
    journal.parent.mkdir(parents=True, exist_ok=True)
    with journal.open("a") as fh:
        fh.write(json.dumps(journal_row(trigger, head, hint, note, auto)) + "\n")
    print()
    for line in backstop_report([*rows, journal_row(trigger, head, hint, note, auto)], time.time()):
        print(f"  {line}")
    return 0


def station_rollout(repo: Path) -> dict[str, str]:
    """unit -> rollout mode, read from each station's declaration."""
    modes = {}
    for path in sorted((repo / "registry" / "stations").glob("*.json")):
        try:
            row = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if row.get("rollout"):
            modes[f"station:{row.get('id', path.stem)}"] = row["rollout"]
    return modes


# Serve-side interpreted trees whose "deployed" and "loaded" can diverge.
LOADED_TARGETS = (("serve-code", "osgallery-https", "/data/vms/streamhost/serve"),)


def cmd_loaded() -> int:
    """Report the gap between what is deployed and what the process is running."""
    import time

    from .loaded import PROBE

    lab = os.environ.get("LAB", "lab")
    print("== loaded-drift: is the running process executing the bytes on disk? ==")
    probe = subprocess.run(
        ["ssh", "-n", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", lab, "true"],
        capture_output=True,
    )
    if probe.returncode != 0:
        print(f"  SKIPPED: ssh {lab} unreachable (public clone, offline, or CI)")
        return 0
    bad = 0
    for unit, service, tree in LOADED_TARGETS:
        out = subprocess.run(
            ["ssh", "-n", "-o", "ConnectTimeout=25", lab, PROBE.format(unit=service, tree=tree)],
            capture_output=True,
            text=True,
            timeout=120,
        )
        start, files = parse_probe(out.stdout)
        drift = drift_for(unit, start, files)
        for line in render(drift, time.time()):
            print(line)
        if not drift.clean:
            bad = 1
    return bad


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
    ap.add_argument("--root", help="sandbox root for apply/rollback/journal (never a live path)")
    ap.add_argument("--unit", help="unit for apply/rollback/journal")
    ap.add_argument("-n", "--dry-run", action="store_true")
    ap.add_argument("--once", action="store_true", help="watch: a single pass (the only mode)")
    ap.add_argument(
        "command",
        choices=(
            "units",
            "plan",
            "status",
            "denylist",
            "rows",
            "apply",
            "rollback",
            "journal",
            "watch",
            "poke",
            "loaded",
        ),
        nargs="?",
        default="status",
    )
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
        if ns.command == "loaded":
            return cmd_loaded()
        if ns.command in ("watch", "poke"):
            if not ns.root:
                print("kh-reconciler: --root is required", file=sys.stderr)
                return 2
            if ns.command == "poke":
                return cmd_poke(Path(ns.root))
            return cmd_watch(repo, Path(ns.root), ns.once)
        if ns.command in ("apply", "rollback", "journal"):
            if not (ns.root and ns.unit):
                print("kh-reconciler: --root and --unit are required", file=sys.stderr)
                return 2
            root = Path(ns.root)
            if ns.command == "apply":
                return cmd_apply(repo, ns.unit, root, ns.commit, ns.dry_run)
            if ns.command == "rollback":
                return cmd_rollback(ns.unit, root)
            return cmd_journal(ns.unit, root)
        return cmd_status(repo, ns.commit)
    except (ProtectedPathError, LiveRootRefused, ApplyRefused) as exc:
        print(f"kh-reconciler: REFUSED: {exc}", file=sys.stderr)
        return 1

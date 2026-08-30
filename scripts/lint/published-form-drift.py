#!/usr/bin/env python3
"""Does the PUBLISHED form of an artifact still match the RECIPE the repo holds?

THE GENERAL CLASS
-----------------
Some artifacts are kept in this repo as a *recipe* while the thing people
actually consume is a *result* produced from it and published somewhere else.
The QEMU fork is the live instance: `streamhost/qemu-patches/*.patch` is the
declared source of truth, and `github.com/Wnt/qemu@kernel-hive` is the published,
consumable form. Two representations of one artifact; nothing forces them equal.

That is the same shape as the two failures the continuous-deploy design already
answers -- registry declarations vs the live box, rendered manifests vs the
registry -- with one feature that makes it worse:

    THIS DRIFT IS INVISIBLE UNTIL SOMEONE TRIES TO BUILD.

`git apply` of a file-CREATING patch fails only when the file already exists, so
a fork that has moved under the patch series has no symptom at all until a build
attempt hits it. The registry and manifest cases at least render a diff you can
look at; this one renders nothing. On 2026-08-30 one agent pushed the fork from
the series and a second later regenerated a patch and found the fork had moved
underneath -- discovered by building, which is the expensive way to find out.

So this check exists to answer "does the published form still match the source
form?" WITHOUT a build attempt. Expect the class to recur: any time the repo
holds a recipe and something else holds the result, it needs a cheap comparison
that reports drift as drift.

WHAT IT CHECKS
--------------
1. POINTER FRESHNESS (cheap: one `git ls-remote`, no clone, no build). Every
   recorded pointer at the fork -- the `third_party/qemu-kernel-hive` gitlink and
   each station's `runtime.qemu.qemuBuild.forkCommit` -- names a commit on a
   MUTABLE branch. A recorded pointer to a mutable ref goes stale silently: after
   today's fork push, rhapsody's `forkCommit` still named the pre-push commit and
   nothing noticed. `ls-remote` is the whole cost of noticing.
2. PUBLISHED-FORM CONTAINMENT (needs a fork clone; SKIPs loudly without one).
   Each recorded `forkCommit` must be an ancestor of the published branch head,
   and every patch a station names must REVERSE-APPLY cleanly against that head's
   tree -- which is exactly "the published form carries this patch, byte for
   byte", proven without applying anything forward and without building.

WHAT IT IS NOT
--------------
It is NOT a push gate, and must never become one. Whether an external published
artifact currently matches is a property of the world at this instant, shared by
every session -- not a property of the commit being pushed. Wiring it into the
pre-push hook would recreate exactly the wedge that
docs/lab/CONTINUOUS-DEPLOY-PROPOSAL.md §2 removes. It is a report: run it on
demand, and let the reconciler run it and surface the result.

It also does not RESOLVE the two sources of truth. The station build script that
compares and fails loudly on divergence made a silent wrong-build into a stop --
safe, not resolved. Only one representation being generated from the other, or
the pointer being content-addressed, removes the class.

    python3 scripts/lint/published-form-drift.py [--fork PATH] [--offline]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SUBMODULE = "third_party/qemu-kernel-hive"
STATIONS = REPO / "registry" / "stations"


def _git(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=str(cwd or REPO), capture_output=True, text=True, timeout=120)


def qemu_build_blocks() -> list[tuple[str, dict]]:
    """(station id, qemuBuild block) for every station that names the fork."""
    out = []
    for path in sorted(STATIONS.glob("*.json")):
        try:
            row = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        block = (row.get("runtime") or {}).get("qemu", {}).get("qemuBuild")
        if block:
            out.append((row.get("id", path.stem), block))
    return out


def gitlink_commit() -> str | None:
    res = _git("ls-tree", "HEAD", SUBMODULE)
    parts = res.stdout.split()
    return parts[2] if res.returncode == 0 and len(parts) >= 3 else None


def fork_remote() -> tuple[str, str]:
    """(url, branch) for the fork, from .gitmodules — never hand-typed here."""
    url = _git("config", "-f", ".gitmodules", f"submodule.{SUBMODULE}.url").stdout.strip()
    branch = _git("config", "-f", ".gitmodules", f"submodule.{SUBMODULE}.branch").stdout.strip()
    return url, branch or "HEAD"


def resolve_fork_clone(explicit: str | None) -> Path | None:
    """A local clone of the fork we may read, or None (then: loud SKIP)."""
    for candidate in (explicit, os.environ.get("KH_QEMU_FORK"), str(REPO / SUBMODULE)):
        if not candidate:
            continue
        path = Path(candidate)
        if (path / ".git").exists() and _git("rev-parse", "--git-dir", cwd=path).returncode == 0:
            return path
    return None


def check_pointer_freshness(problems: list[str], unverified: list[str], offline: bool) -> str | None:
    """Has the published branch moved since anything in this repo recorded it?

    The two kinds of recorded pointer mean different things and are judged
    differently, which matters — a check that cries wolf gets ignored:

      * the `third_party/qemu-kernel-hive` GITLINK is a pin AT the published
        form, so it must EQUAL the branch head. A moved branch leaves it stale
        and silent: that is drift, reported here;
      * a station's `qemuBuild.forkCommit` is the commit its patches were
        verified to apply to — a BASE. The right relation is ancestry, not
        equality, and only the containment leg can decide it. So a difference
        here is recorded as UNVERIFIED, never as drift.
    """
    url, branch = fork_remote()
    link = gitlink_commit()
    bases = {}
    for station, block in qemu_build_blocks():
        commit = block.get("forkCommit")
        if commit:
            bases.setdefault(commit, []).append(f"{station}.qemuBuild.forkCommit")
    if not link and not bases:
        print("  no recorded pointers at the fork — nothing to compare")
        return None
    if offline:
        print(f"  SKIPPED freshness: --offline (would be `git ls-remote {url} {branch}`)")
        return None
    if not shutil.which("git"):
        print("  SKIPPED freshness: no git")
        return None
    res = _git("ls-remote", url, f"refs/heads/{branch}")
    if res.returncode != 0 or not res.stdout.strip():
        print(f"  SKIPPED freshness: could not reach {url} (offline, or no access)")
        return None
    head = res.stdout.split()[0]
    print(f"  published {url}@{branch} is at {head[:12]}")
    if link:
        print(f"    {'==' if link == head else '!='} {link[:12]}  {SUBMODULE} gitlink (pin: must equal)")
        if link != head:
            problems.append(
                f"the {SUBMODULE} gitlink pins {link[:12]} but the published branch is at "
                f"{head[:12]} — the branch moved and nothing in this repo changed. A pointer at a "
                "mutable ref goes stale in silence. Re-record it (saying what moved), or "
                "content-address it so staleness is detectable rather than assumed."
            )
    for commit, owners in sorted(bases.items()):
        same = commit == head
        print(f"    {'==' if same else '? '} {commit[:12]}  {', '.join(owners)} (base: must be an ancestor)")
        if not same:
            unverified.append(
                f"{', '.join(owners)} = {commit[:12]} is a BASE, not a pin: it must be an ancestor "
                f"of {head[:12]}, which needs a fork clone to decide. Nothing in this repo asserts it."
            )
    return head


def check_containment(problems: list[str], fork: Path | None, head: str | None) -> None:
    """Does the published tree actually carry the patches the recipe declares?"""
    if fork is None:
        print("  SKIPPED containment: no fork clone. Point at one with KH_QEMU_FORK=<path>,")
        print(f"    or `git submodule update --init {SUBMODULE}` in this checkout.")
        print("    (This is the leg that would have caught today's divergence offline.)")
        return
    ref = head or "HEAD"
    if _git("cat-file", "-e", f"{ref}^{{commit}}", cwd=fork).returncode != 0:
        print(f"  SKIPPED containment: {fork} does not have {ref[:12]} — fetch it first")
        return
    for station, block in sorted(qemu_build_blocks()):
        base = block.get("forkCommit")
        if base and _git("merge-base", "--is-ancestor", base, ref, cwd=fork).returncode != 0:
            problems.append(
                f"{station}.qemuBuild.forkCommit {base[:12]} is NOT an ancestor of the published "
                f"branch head {ref[:12]} — the recipe was verified against a commit the published "
                "form no longer descends from, so 'applies cleanly' was measured on a tree "
                "nobody consumes."
            )
        for rel in block.get("patches", []):
            patch = REPO / rel
            if not patch.exists():
                problems.append(f"{station} names {rel}, which is not in this tree")
                continue
            if not _published_carries(fork, ref, patch):
                problems.append(
                    f"{station}: {rel} does NOT reverse-apply against {ref[:12]} — the published "
                    "fork and the patch series have diverged for this patch. Nothing would have "
                    "reported this until a build attempt; a file-creating patch fails only once "
                    "the file exists."
                )
    if not problems:
        print(f"  ok — every declared patch is carried byte-for-byte by {ref[:12]}")


def _published_carries(fork: Path, ref: str, patch: Path) -> bool:
    """True iff the patch's post-image is exactly what the published tree holds.

    Reverse-apply --check does this without writing anything and without a base
    commit: it succeeds only if every post-image hunk is present verbatim.
    """
    with tempfile.TemporaryDirectory() as tmp:
        archive = subprocess.run(
            ["git", "archive", ref],
            cwd=str(fork),
            capture_output=True,
            timeout=600,
        )
        if archive.returncode != 0:
            return False
        untar = subprocess.run(["tar", "-x", "-C", tmp], input=archive.stdout, capture_output=True)
        if untar.returncode != 0:
            return False
        return (
            subprocess.run(
                ["git", "apply", "-p1", "--reverse", "--check", str(patch)],
                cwd=tmp,
                capture_output=True,
                timeout=120,
            ).returncode
            == 0
        )


def main() -> int:
    ap = argparse.ArgumentParser(description="recipe-vs-published-form drift (a report, never a gate)")
    ap.add_argument("--fork", help="path to a local clone of the fork")
    ap.add_argument("--offline", action="store_true", help="skip the network freshness leg")
    ns = ap.parse_args()

    print("== published-form drift: qemu-patches recipe vs the published fork ==")
    problems: list[str] = []
    unverified: list[str] = []
    head = check_pointer_freshness(problems, unverified, ns.offline)
    check_containment(problems, resolve_fork_clone(ns.fork), head)
    if unverified:
        print(f"  UNVERIFIED — {len(unverified)} claim(s) this run could not decide:")
        for line in unverified:
            print(f"    ? {line}")
    if problems:
        print(f"  DRIFT — {len(problems)} disagreement(s) between the recipe and the published form:")
        for line in problems:
            print(f"    - {line}")
        print("  This is a report. It blocks no push; it names work.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

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

KNOWN STATE (2026-08-30), so a reader does not re-derive it
-----------------------------------------------------------
* This check REPORTS REAL DRIFT right now and that is expected, not a bug to
  chase: the published branch is ahead of both the submodule gitlink and
  `rhapsody.qemuBuild.forkCommit`. Reconciling those pointers belongs to the
  deploy stream, as part of a fork reconciliation currently blocked on a device
  fix. Leave them alone; the report is doing its job by naming them.
* WHERE THE CONTAINMENT LEG CAN ACTUALLY DECIDE (measured, all three
  checkouts). The CT950 checkout `/home/wnt/kernel-hive` HAS the submodule
  initialised, so the leg decides there. The box checkout `/data/kernel-hive`
  does NOT: that path holds an unpacked tree with no `.git`. And a `wt.sh`
  worktree inherits the box clone as its superproject, so the leg SKIPs in a
  worktree — pass `--fork` or `KH_QEMU_FORK` there.
* This check REPORTS REAL DRIFT right now and that is expected, not a bug to
  chase: the published branch is ahead of the submodule gitlink. Reconciling
  the fork pointers belongs to the deploy stream, inside a fork reconciliation
  currently blocked on a device fix. Leave them alone; the report is doing its
  job by naming them.
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


def _real_git_dir(candidate: Path) -> Path | None:
    """A path usable as `git --git-dir=`, or None. NOT a work-tree question.

    THE TRAP THIS EXISTS TO AVOID (measured 2026-08-30, all three checkouts).
    `git rev-parse --is-inside-work-tree` returns **true** inside the box's
    UNPACKED copy of the submodule — a directory with no `.git` at all — because
    it sits inside the SUPERPROJECT's work tree. `git rev-parse --git-dir` is
    fooled the same way and confidently answers `/data/kernel-hive/.git`. Both
    probes return a true, plausible answer to a question nobody asked, which is
    the same family as an empty observer log reading as "not started yet": a
    confident signal produced by a mechanism unrelated to the thing being
    tested. The discriminators that actually answer it are the presence of
    `.git` and the leading `-` in `git submodule status`.
    """
    if candidate is None:
        return None
    dot = candidate / ".git"
    if dot.is_dir() and (dot / "HEAD").exists():
        return dot  # a plain clone
    if dot.is_file():  # a submodule's gitdir POINTER file
        text = dot.read_text().strip()
        if text.startswith("gitdir:"):
            target = (candidate / text.split(":", 1)[1].strip()).resolve()
            return target if (target / "HEAD").exists() else None
    if (candidate / "HEAD").exists() and (candidate / "objects").exists():
        return candidate  # already a bare/`modules/` git dir
    return None


def resolve_fork_gitdir(explicit: str | None) -> Path | None:
    """A git dir for the fork we may read. A CHECKOUT IS NOT REQUIRED.

    `git archive` and `git cat-file` work straight off a git dir, so an
    initialised submodule's `modules/` directory is enough — which matters,
    because agents work in `wt.sh` worktrees whose superproject is the box
    clone, where the submodule is NOT initialised.
    """
    for raw in (explicit, os.environ.get("KH_QEMU_FORK")):
        if raw:
            found = _real_git_dir(Path(raw))
            if found:
                return found
    found = _real_git_dir(REPO / SUBMODULE)
    if found:
        return found
    common = _git("rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    if common:
        return _real_git_dir(Path(common) / "modules" / SUBMODULE)
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


def _forkgit(gitdir: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", f"--git-dir={gitdir}", *args], capture_output=True, text=True, timeout=600)


def check_containment(problems: list[str], gitdir: Path | None, head: str | None) -> None:
    """Does the published tree actually carry the patches the recipe declares?

    WHICH REF IT VERIFIES AGAINST, AND WHY IT IS NOT ALWAYS THE BRANCH HEAD.
    The freshness leg learns the head over the network, but a local git dir need
    not contain it — and this check must NEVER fetch to close that gap, because
    the git dir it reads usually belongs to somebody else's checkout and a read
    path that writes is the defect this whole design exists to remove. So it
    verifies against every ref it can actually read, preferring the head when
    present and always including the **gitlink commit**, which is what this repo
    pins and therefore what a build here would use. That composes with the
    freshness leg into a precise statement: "the pinned form carries the recipe"
    plus "the pin is stale" is strictly more informative than one SKIP.
    """
    if gitdir is None:
        print("  SKIPPED containment: no readable fork git dir.")
        print(f"    `git submodule update --init {SUBMODULE}` here, or KH_QEMU_FORK=<path>.")
        print("    NOTE: a `wt.sh` worktree inherits the BOX clone as its superproject, and the")
        print("    box copy is an unpacked tree, not a repository — so this leg SKIPs in a")
        print("    worktree while deciding normally in the CT950 checkout.")
        return
    print(f"  reading the published form from {gitdir}")
    wanted = [(head, "published branch head")] if head else []
    link = gitlink_commit()
    if link and link != head:
        wanted.append((link, f"{SUBMODULE} gitlink"))
    readable = [
        (ref, why)
        for ref, why in wanted
        if ref and _forkgit(gitdir, "cat-file", "-e", f"{ref}^{{commit}}").returncode == 0
    ]
    for ref, why in wanted:
        if ref and (ref, why) not in readable:
            print(f"    SKIPPED {ref[:12]} ({why}): not in this git dir, and this check never fetches")
    if not readable:
        print("    SKIPPED containment: no recorded commit is readable here")
        return
    for ref, why in readable:
        _verify_against(problems, gitdir, ref, why)


def _verify_against(problems: list[str], gitdir: Path, ref: str, why: str) -> None:
    """Classify every declared patch against one readable form of the fork.

    THREE STATES, NOT TWO — getting this wrong is how a check cries wolf.
    A first cut reverse-applied every declared patch and called any failure
    drift. It reported five false positives on its first real run, because
    `qemuBuild.patches` is NOT "the published patch set": the fork branch
    publishes a subset (streamhost/qemu-patches/README.md), while a station's
    build is `forkCommit` plus its own patches on top. An unpublished
    per-station patch is SUPPOSED to be absent from the fork. So, per form:

      carried  — reverse-applies: this form already contains the patch verbatim.
      applies  — applies cleanly FORWARD instead: the form does not carry it and
                 is not meant to, and the recipe still fits. This also checks the
                 registry's prose claim ("verified to apply cleanly to that fork
                 commit"), which nothing verified before.
      DIVERGED — neither. The form moved such that the patch is neither present
                 nor applicable: the failure the incident describes, and the only
                 state reported as drift.

    AND THE SERIES IS CUMULATIVE, IN ORDER. The second cut still reported two
    false positives — beos's 0009 and 0010 patch `hw/misc/kh-ramabs.c`, a file
    that only EXISTS once 0007 has been applied. Testing each patch against the
    bare base asks a question the build never asks. So each patch is classified
    in the tree its predecessors leave behind, and one that `applies` is really
    applied before the next is judged. A diverged patch stops that station's
    chain, because everything after it is then unknowable rather than wrong.
    """
    for station, block in sorted(qemu_build_blocks()):
        base = block.get("forkCommit")
        base_here = base and _forkgit(gitdir, "cat-file", "-e", f"{base}^{{commit}}").returncode == 0
        if base_here and _forkgit(gitdir, "merge-base", "--is-ancestor", base, ref).returncode:
            problems.append(
                f"{station}.qemuBuild.forkCommit {base[:12]} is NOT an ancestor of {ref[:12]} "
                f"({why}) — the recipe was verified against a commit that form does not descend "
                "from, so 'applies cleanly' was measured on a tree nobody consumes."
            )
        _walk_series(problems, gitdir, ref, why, station, block.get("patches", []))


def _walk_series(problems: list[str], gitdir: Path, ref: str, why: str, station: str, series: list[str]) -> None:
    if not series:
        return
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp)
        if not _unpack(gitdir, ref, tree):
            print(f"    SKIPPED {station} against {ref[:12]} ({why}): could not unpack its tree")
            return
        states = []
        for rel in series:
            patch = REPO / rel
            if not patch.exists():
                problems.append(f"{station} names {rel}, which is not in this tree")
                return
            if _apply_check(tree, patch, reverse=True):
                states.append("carried")
                continue
            if _apply_check(tree, patch, reverse=False):
                _apply(tree, patch)  # the next patch must see this one applied
                states.append("applies")
                continue
            problems.append(
                f"{station}: {rel} against {ref[:12]} ({why}) is NEITHER carried nor applicable, "
                f"with its {len(states)} predecessor(s) already applied — that form and the patch "
                "series have diverged. Nothing would have reported this until a build attempt; a "
                "file-creating patch fails only once the file exists."
            )
            return
        print(
            f"    {station} vs {ref[:12]} ({why}): "
            f"{states.count('carried')} carried verbatim, {states.count('applies')} apply in order"
        )


def _unpack(gitdir: Path, ref: str, into: Path) -> bool:
    """Materialize a form's tree. Read-only: this never fetches and never writes
    into the git dir, which usually belongs to somebody else's checkout."""
    archive = subprocess.run(["git", f"--git-dir={gitdir}", "archive", ref], capture_output=True, timeout=900)
    if archive.returncode != 0:
        return False
    return subprocess.run(["tar", "-x", "-C", str(into)], input=archive.stdout, capture_output=True).returncode == 0


def _apply(tree: Path, patch: Path) -> None:
    subprocess.run(["git", "apply", "-p1", str(patch)], cwd=str(tree), capture_output=True, timeout=120)


def _apply_check(tree: Path, patch: Path, reverse: bool) -> bool:
    args = ["git", "apply", "-p1", "--check", *(["--reverse"] if reverse else []), str(patch)]
    return subprocess.run(args, cwd=str(tree), capture_output=True, timeout=120).returncode == 0


def _patch_state(tree: Path, patch: Path) -> str:
    """carried | applies | diverged — decided on an unpacked tree, with no build."""
    if _apply_check(tree, patch, reverse=True):
        return "carried"
    if _apply_check(tree, patch, reverse=False):
        return "applies"
    return "diverged"


def _published_carries(gitdir: Path, ref: str, patch: Path) -> bool:
    """True iff that form holds the patch's post-image verbatim.

    Reverse-apply --check decides it with no forward apply, no base commit and
    no build: it succeeds only if every post-image hunk is already present.
    """
    with tempfile.TemporaryDirectory() as tree:
        return _unpack(gitdir, ref, Path(tree)) and _apply_check(Path(tree), patch, reverse=True)


def main() -> int:
    ap = argparse.ArgumentParser(description="recipe-vs-published-form drift (a report, never a gate)")
    ap.add_argument("--fork", help="path to a clone OR a bare/modules git dir of the fork")
    ap.add_argument("--offline", action="store_true", help="skip the network freshness leg")
    ns = ap.parse_args()

    print("== published-form drift: qemu-patches recipe vs the published fork ==")
    problems: list[str] = []
    unverified: list[str] = []
    head = check_pointer_freshness(problems, unverified, ns.offline)
    check_containment(problems, resolve_fork_gitdir(ns.fork), head)
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

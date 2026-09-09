#!/usr/bin/env python3
"""`publish`: idempotent git tag + GitHub release sync for a closed week.

Split out of release-notes.py, which owns the week maths, the git-reading
primitives (`run_git`, the clamped author-date `_stamp`, `repo_epoch`) and the
render/check/status/brief commands. This module owns the one command that
CREATES something outside the repo tree — a tag, a GitHub release — and takes
those primitives as parameters rather than importing them, so it has no import
cycle with release-notes.py and stays a plain function of its inputs, the same
shape as release_notes_render.py.

TAG TARGET. `week-<N>` points at the last non-merge commit (by the same
clamped author-date bucketing `brief` buckets commits by) stamped before that
week's `end`. Week 0 predates this repository's git history entirely, so its
tag names the repo's own first public commit instead; a stub week 1 landing on
the same commit is not an error (see resolve_week_commit).

IDEMPOTENCE. An existing tag at the right commit, or an existing release with
the same title and body, is left untouched and reported as such. An existing
tag at the WRONG commit is refused loudly unless `--retag` is given — moving a
tag silently would change what every existing citation to `week-N` means.
"""

from __future__ import annotations

import json
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Callable

import release_notes_render as render_mod

StampFn = Callable[[str, str, datetime], datetime]
RunGitFn = Callable[[list[str]], str]
RepoEpochFn = Callable[[datetime], datetime]
LoadWeeksFn = Callable[[], list[dict]]


def _all_commits_with_sha(
    run_git: RunGitFn, git_format: str, stamp: StampFn, repo_epoch: RepoEpochFn, now: datetime
) -> list[tuple[datetime, str]]:
    """(clamped stamp, sha) for every non-merge commit — the same bucketing
    `read_commits` uses, plus the sha a tag needs to point at one."""
    floor = repo_epoch(now)
    out = []
    for line in run_git(["log", "--no-merges", f"--format=%H\x1f{git_format}"]).splitlines():
        if not line.strip():
            continue
        sha, authored, committed, _subject = line.split("\x1f", 3)
        out.append((max(stamp(authored, committed, now), floor), sha))
    return out


def _root_commit(run_git: RunGitFn, git_format: str, stamp: StampFn, now: datetime) -> str:
    """The repo's own first public commit — week 0's tag target, since week 0
    predates this repository's git history entirely."""
    shas = run_git(["rev-list", "--max-parents=0", "HEAD"]).split()
    if len(shas) == 1:
        return shas[0]

    def stamp_of(sha: str) -> datetime:
        authored, committed = run_git(["show", "-s", f"--format={git_format}", sha]).split("\x1f")[:2]
        return stamp(authored, committed, now)

    return min(shas, key=stamp_of)


def resolve_week_commit(
    now: datetime,
    week_number: int,
    end: datetime,
    *,
    run_git: RunGitFn,
    git_format: str,
    stamp: StampFn,
    repo_epoch: RepoEpochFn,
) -> str:
    """The commit a week's tag points at: the last non-merge commit stamped
    before the week's `end`. Week 0 has no such commit, so its tag names the
    repo's own first public commit instead; naming week 1's tag the same
    commit is fine (a stub week can genuinely close with nothing new
    committed since the repo opened)."""
    if week_number == 0:
        return _root_commit(run_git, git_format, stamp, now)
    eligible = [(s, sha) for s, sha in _all_commits_with_sha(run_git, git_format, stamp, repo_epoch, now) if s < end]
    if not eligible:
        raise SystemExit(f"release-notes: no commit found before week {week_number}'s end ({end.isoformat()})")
    eligible.sort(key=lambda pair: pair[0])
    return eligible[-1][1]


def _existing_tag_commit(repo_root: Path, tag: str) -> str | None:
    result = subprocess.run(["git", "-C", str(repo_root), "rev-list", "-n", "1", tag], capture_output=True, text=True)
    return result.stdout.strip() or None if result.returncode == 0 else None


def _existing_release(repo_root: Path, tag: str) -> dict | None:
    result = subprocess.run(
        ["gh", "release", "view", tag, "--json", "name,body"], capture_output=True, text=True, cwd=repo_root
    )
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def sync_tag(repo_root: Path, tag: str, commit: str, dry_run: bool, retag: bool) -> bool:
    """True on success; False when an existing tag conflicts and `--retag` was
    not given (the caller counts that as one failure, not a crash)."""
    current = _existing_tag_commit(repo_root, tag)
    if current == commit:
        print(f"release-notes: {tag} already at {commit[:12]} — kept")
        return True
    if current is not None and not retag:
        print(
            f"release-notes: REFUSED — {tag} exists at {current[:12]}, resolves to {commit[:12]} now; "
            "pass --retag to move it"
        )
        return False
    verb = "moves" if current else "creates"
    print(f"release-notes: {tag} {verb} -> {commit[:12]}" + (" (--retag)" if current else ""))
    if dry_run:
        return True
    tag_args = ["git", "-C", str(repo_root), "tag"]
    push_args = ["git", "-C", str(repo_root), "push", "origin", tag]
    if current is not None:
        tag_args.append("-f")
        push_args.insert(4, "-f")
    subprocess.run([*tag_args, tag, commit], check=True)
    subprocess.run(push_args, check=True)
    return True


def sync_release(repo_root: Path, tag: str, title: str, body: str, latest: bool, dry_run: bool) -> None:
    if dry_run:
        print(f"release-notes: [dry-run] release {tag}: title={title!r} latest={latest} body_len={len(body)}")
        return
    existing = _existing_release(repo_root, tag)
    if existing is None:
        print(f"release-notes: creating release {tag}")
        args = ["gh", "release", "create", tag, "--title", title, "--notes", body]
        args.append("--latest" if latest else "--latest=false")
        subprocess.run(args, check=True, cwd=repo_root)
        return
    if existing.get("name") == title and existing.get("body") == body:
        print(f"release-notes: release {tag} unchanged")
        return
    print(f"release-notes: updating release {tag} (title/body changed)")
    subprocess.run(["gh", "release", "edit", tag, "--title", title, "--notes", body], check=True, cwd=repo_root)


def cmd_publish(
    now: datetime,
    want: str | None,
    dry_run: bool,
    retag: bool,
    *,
    repo_root: Path,
    load_weeks: LoadWeeksFn,
    run_git: RunGitFn,
    git_format: str,
    stamp: StampFn,
    repo_epoch: RepoEpochFn,
) -> int:
    weeks = load_weeks()  # newest first
    closed_all = [w for w in weeks if datetime.fromisoformat(w["end"]) <= now]
    if not closed_all:
        print("release-notes: no closed, written weeks to publish")
        return 0
    newest_number = max(w["week"] for w in closed_all)
    targets = closed_all if not want else [w for w in closed_all if w["endDate"] == want]
    if want and not targets:
        print(f"release-notes: no closed, written week ends {want}")
        return 1
    exit_code = 0
    for week in sorted(targets, key=lambda w: w["week"]):
        number = week["week"]
        tag = f"week-{number}"
        end = datetime.fromisoformat(week["end"])
        commit = resolve_week_commit(
            now, number, end, run_git=run_git, git_format=git_format, stamp=stamp, repo_epoch=repo_epoch
        )
        if not sync_tag(repo_root, tag, commit, dry_run, retag):
            exit_code = 1
            continue
        title = render_mod.release_title(week)
        body = render_mod.release_body(week)
        sync_release(repo_root, tag, title, body, latest=(number == newest_number), dry_run=dry_run)
    return exit_code

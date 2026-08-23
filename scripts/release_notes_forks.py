#!/usr/bin/env python3
"""The emulator forks half of the release notes (scripts/release-notes.py).

WHY THIS EXISTS. Most of what a visitor actually notices in a given week is a
patch to an EMULATOR, and those patches do not live in this repository: they are
pushed to public forks (MAME, es40, VICE, QEMU) and consumed here as submodules
and build pins. A `brief` cut from `git log` alone therefore reports a week with
its most interesting half missing, silently — which is the one failure mode this
module exists to prevent. Every source it gathers is declared by hand in

    registry/release-notes/sources.json

one home per fact: who counts as us, which branch each build actually pins,
which branch is deliberately NOT shipped and why.

WHAT IS DELIBERATELY LEFT OUT, and never "helpfully" re-added:

  - Commits by anyone outside `ourAuthors`. The forks carry thousands of
    upstream commits this project merely rebases on; announcing them as this
    week's work would be a lie by omission of context.
  - Branches under a fork's `excludes`. They are real, published, working
    patches that the default stack does not run — a trial, not an exhibit. Each
    exclusion records its own reason in sources.json; read it before removing
    one.
  - Any commit whose own subject carries the `experimentalSubjectMarker`.

WHAT IS NEVER DROPPED, however little the API says about it. GitHub can only
attach an account LOGIN to a commit whose author email belongs to a GitHub
account, and work pushed straight from the lab box carries the box's own git
identity instead — so it arrives with `author.login == null` and the
`ourAuthors` rule cannot see it at all. Those commits are ours as often as not
(the VICE shared-memory framebuffer the whole headless capture path stands on
came in that way). Two mechanisms keep them out of the silent-drop bucket:
`ourCommitAuthors` declares the plain author names/emails that count as ours,
and anything still unattributed is printed under a DECIDE BY HAND block instead
of vanishing. A brief that is short a commit must say so.

NETWORK. `gh` is used, and only from `brief`. `render` and `check` never call in
here at all, which is what keeps them offline and byte-deterministic; the offline
half of the declaration — where sources.json lives, and the pin drift `check`
refuses in both directions — is release_notes_pins.py next door. When `gh` is
missing, unauthenticated or simply failing, gathering
does NOT fail the brief: it returns the sources it could not reach, with the
exact command that failed, so the caller can print a loud warning and name them.
A brief that is short a fork must say so; a brief that is short a fork in
silence is the original bug.

WHICH TIMESTAMP a fork commit is bucketed by: the same rule scripts/release-notes.py
uses locally — min(author date, committer date), compared against the week's
half-open [start, end) window in Europe/Helsinki. GitHub's own `since`/`until`
filter on the committer date only, so the fetch window is padded (FETCH_SLACK)
and the exact boundary is applied here, in one place, for local and fork commits
alike. A fork commit stamped BEFORE this repository's root commit belongs to the
pre-public era — week 0, which is hand-written and which `brief` never offers —
so it is simply outside every window `brief` can ask for, exactly like the local
history that predates the open-source release.
"""

from __future__ import annotations

import json
import shlex
import subprocess
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

# Sibling module, imported the way scripts/release-notes.py imports it: scripts/
# is sys.path[0] both as a script and under `unittest discover -s scripts`.
import release_notes_pins as pins_mod
import release_notes_render as render_mod

# The declaration file, and the offline tripwire that keeps it honest, both live
# next door: release_notes_pins owns where sources.json is and what on disk must
# still agree with it. This module owns what the declaration MEANS and what is
# fetched with it.
SOURCES_PATH = pins_mod.SOURCES_PATH
SOURCES_NAME = pins_mod.SOURCES_NAME
DEFAULT_MARKER = "[experimental, not shipped]"
# GitHub filters commits by COMMITTER date; a commit authored inside the week can
# be committed (rebased, cherry-picked) well after it. Fetch wide, cut exactly.
FETCH_SLACK = timedelta(days=30)
SHORT_SHA = 7
# sha, GitHub author LOGIN (empty when GitHub could not resolve one), the commit's
# own author NAME and EMAIL (the fallback identity `ourCommitAuthors` declares),
# both dates, and the subject line only.
GH_JQ = (
    '.[] | [.sha, (.author.login // ""), .commit.author.name, .commit.author.email, '
    '.commit.author.date, .commit.committer.date, (.commit.message | split("\\n")[0])] | @tsv'
)
GH_FIELDS = 7


@dataclass(frozen=True)
class Target:
    """One fork branch to gather, exactly as declared."""

    repo: str
    branch: str
    what: str


@dataclass(frozen=True)
class ForkCommit:
    repo: str
    branch: str
    sha: str
    login: str
    stamp: datetime
    subject: str
    # The commit's own author identity, which is all GitHub has when it cannot
    # resolve a login. The email is matched against `ourCommitAuthors` but never
    # printed: the lab box's own identity contains a real hostname, and this repo
    # is public.
    name: str = ""
    email: str = ""

    @property
    def short(self) -> str:
        return self.sha[:SHORT_SHA]


@dataclass(frozen=True)
class Sources:
    our_authors: tuple[str, ...]
    marker: str
    targets: tuple[Target, ...]
    # Author names/emails that count as ours when GitHub resolved no login.
    our_commit_authors: tuple[str, ...] = ()


@dataclass(frozen=True)
class Selection:
    """What a week's fetch resolved to. `unattributed` is never merged into
    `ours` and never thrown away — it is a human decision, printed as one."""

    ours: list[ForkCommit] = field(default_factory=list)
    unattributed: list[ForkCommit] = field(default_factory=list)


@dataclass(frozen=True)
class Unreached:
    """One declared source that could not be gathered, and the exact command
    that failed — so the recovery line in the warning cannot drift from it."""

    target: Target
    why: str
    argv: tuple[str, ...] = ()


class Unreachable(Exception):
    """One declared source could not be gathered. Never fatal, never silent."""


# ---------------------------------------------------------------- declaration


def _fail(path: Path, message: str) -> SystemExit:
    return SystemExit(f"release-notes: {path} is malformed — {message}")


def _string_list(value: object) -> bool:
    return isinstance(value, list) and all(isinstance(v, str) and v.strip() for v in value)


def parse_sources(doc: object, path: Path) -> Sources:
    """Validate the hand-written declaration into typed targets. Pure."""
    if not isinstance(doc, dict):
        raise _fail(path, "must be a JSON object")
    authors = doc.get("ourAuthors")
    if not _string_list(authors) or not authors:
        raise _fail(path, "`ourAuthors` must be a non-empty list of GitHub logins")
    identities = doc.get("ourCommitAuthors", [])
    if not _string_list(identities):
        raise _fail(path, "`ourCommitAuthors` must be a list of commit author names or emails")
    marker = doc.get("experimentalSubjectMarker", DEFAULT_MARKER)
    if not isinstance(marker, str) or not marker.strip():
        raise _fail(path, "`experimentalSubjectMarker` must be a non-empty string")
    forks = doc.get("forks")
    if not isinstance(forks, list) or not forks:
        raise _fail(path, "`forks` must be a non-empty list")
    targets: list[Target] = []
    for fork in forks:
        if not isinstance(fork, dict):
            raise _fail(path, "every entry in `forks` must be an object")
        repo, what = fork.get("repo"), fork.get("what")
        if not isinstance(repo, str) or repo.count("/") != 1:
            raise _fail(path, f"`repo` must be an owner/name slug, got {repo!r}")
        if not isinstance(what, str) or not what.strip():
            raise _fail(path, f"{repo}: `what` must say what this fork is for")
        branches = fork.get("branches")
        if not isinstance(branches, list) or not branches:
            raise _fail(path, f"{repo}: `branches` must be a non-empty list")
        for branch in branches:
            targets.append(_parse_branch(branch, repo, what, path))
        _check_excludes(fork.get("excludes", []), repo, path)
    return Sources(tuple(authors), marker, tuple(targets), tuple(identities))


def _parse_branch(branch: object, repo: str, fork_what: str, path: Path) -> Target:
    if not isinstance(branch, dict):
        raise _fail(path, f"{repo}: every entry in `branches` must be an object")
    name = branch.get("name")
    if not isinstance(name, str) or not name.strip():
        raise _fail(path, f"{repo}: a branch is missing its `name`")
    pinned = branch.get("pinnedBy")
    if not _string_list(pinned) or not pinned:
        raise _fail(
            path,
            f"{repo} {name}: `pinnedBy` must cite at least one file in this repo that pins the branch — "
            "the declaration and the build must not be able to drift apart in silence",
        )
    what = branch.get("what")
    return Target(repo, name, what if isinstance(what, str) and what.strip() else fork_what)


def _check_excludes(excludes: object, repo: str, path: Path) -> None:
    """An exclusion without a reason is an exclusion the next reader deletes."""
    if not isinstance(excludes, list):
        raise _fail(path, f"{repo}: `excludes` must be a list")
    for item in excludes:
        if not isinstance(item, dict) or not isinstance(item.get("branch"), str):
            raise _fail(path, f"{repo}: every entry in `excludes` needs a `branch`")
        why = item.get("why")
        if not isinstance(why, str) or len(why.split()) < 4:
            raise _fail(path, f"{repo} {item['branch']}: `excludes` needs a `why` — record WHY, or it gets re-added")


def load_sources(repo_root: Path) -> Sources:
    path = repo_root / SOURCES_PATH
    try:
        doc = json.loads(path.read_text())
    except FileNotFoundError as missing:
        raise _fail(SOURCES_PATH, "the file is missing; restore it from git") from missing
    except json.JSONDecodeError as bad:
        raise _fail(SOURCES_PATH, f"not valid JSON ({bad})") from bad
    return parse_sources(doc, SOURCES_PATH)


# -------------------------------------------------------------------- filters


def is_ours(login: str, our_authors: tuple[str, ...] | list[str]) -> bool:
    """GitHub logins are case-insensitive. An empty login means GitHub resolved
    no account at all, which is NOT the same as "not ours" — see
    `is_declared_identity` and the unattributed half of `select_commits`."""
    return bool(login) and login.casefold() in {a.casefold() for a in our_authors}


def is_declared_identity(commit: ForkCommit, identities: tuple[str, ...] | list[str]) -> bool:
    """The fallback for a commit GitHub could not attribute: its plain git author
    name or email, declared by hand in `ourCommitAuthors`."""
    wanted = {i.casefold() for i in identities}
    return bool(wanted & {commit.name.strip().casefold(), commit.email.strip().casefold()} - {""})


def select_commits(commits: list[ForkCommit], sources: Sources, start: datetime, end: datetime) -> Selection:
    """The rules, in one pure place: shipped, inside the week, and then ours /
    upstream / nobody-can-tell. Nothing is discarded except upstream work and
    the commits that opted out by marker or by date."""
    ours: list[ForkCommit] = []
    unknown: list[ForkCommit] = []
    for commit in commits:
        if sources.marker in commit.subject or not start <= commit.stamp < end:
            continue
        if is_ours(commit.login, sources.our_authors) or (
            not commit.login and is_declared_identity(commit, sources.our_commit_authors)
        ):
            ours.append(commit)
        elif not commit.login:
            unknown.append(commit)
    return Selection(ours, unknown)


def parse_rows(rows: str, target: Target, tz) -> list[ForkCommit]:
    """gh's TSV into ForkCommits. A subject may contain a tab; nothing else may."""
    out = []
    for line in rows.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t", GH_FIELDS - 1)
        if len(fields) != GH_FIELDS:
            continue
        sha, login, name, email, authored, committed, subject = fields
        stamp = min(
            datetime.fromisoformat(authored.replace("Z", "+00:00")).astimezone(tz),
            datetime.fromisoformat(committed.replace("Z", "+00:00")).astimezone(tz),
        )
        out.append(ForkCommit(target.repo, target.branch, sha, login, stamp, subject, name, email))
    return out


# --------------------------------------------------------------- gathering (gh)


def gh_argv(target: Target, start: datetime, end: datetime) -> list[str]:
    return [
        "gh",
        "api",
        "-X",
        "GET",
        f"repos/{target.repo}/commits",
        "--paginate",
        "-f",
        f"sha={target.branch}",
        "-f",
        f"since={start.isoformat()}",
        "-f",
        f"until={(end + FETCH_SLACK).isoformat()}",
        "--jq",
        GH_JQ,
    ]


def run_gh(argv: list[str]) -> str:
    """The one place a subprocess is spawned. Injectable, so tests never fetch."""
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    except FileNotFoundError as missing:
        raise Unreachable("`gh` is not installed on this machine") from missing
    except subprocess.TimeoutExpired as slow:
        raise Unreachable("`gh` timed out after 120s") from slow
    if done.returncode != 0:
        detail = (done.stderr or done.stdout).strip().splitlines()
        raise Unreachable(detail[0] if detail else f"gh exited {done.returncode}")
    return done.stdout


def gather(
    sources: Sources,
    start: datetime,
    end: datetime,
    tz,
    runner=run_gh,
) -> tuple[Selection, list[Unreached]]:
    """(what the week resolved to, sources that could not be reached). Never
    raises for a network or auth failure — an unreachable source is data, not an
    abort."""
    ours: list[ForkCommit] = []
    unknown: list[ForkCommit] = []
    missing: list[Unreached] = []
    for target in sources.targets:
        argv = gh_argv(target, start, end)
        try:
            rows = runner(argv)
        except Unreachable as why:
            missing.append(Unreached(target, str(why), tuple(argv)))
            continue
        picked = select_commits(parse_rows(rows, target, tz), sources, start, end)
        ours += picked.ours
        unknown += picked.unattributed
    ours.sort(key=lambda c: c.stamp, reverse=True)
    unknown.sort(key=lambda c: c.stamp, reverse=True)
    return Selection(ours, unknown), missing


# --------------------------------------------------------------------- output


def format_section(sources: Sources, picked: Selection, missing: list[Unreached]) -> list[str]:
    """The EMULATOR FORKS block, printed after this repo's own commit subjects."""
    flags = ""
    if missing:
        flags += " (INCOMPLETE — see the warning below)"
    if picked.unattributed:
        flags += f" (+{len(picked.unattributed)} unattributed — see DECIDE BY HAND below)"
    lines = [
        "",
        "=" * 72,
        f"EMULATOR FORKS — {render_mod.plural(len(picked.ours), 'commit', 'commits')} by "
        f"{', '.join(sources.our_authors)}{flags}",
        "=" * 72,
        f"Declared in {SOURCES_PATH}: only our commits, only on the branches the builds",
        "pin. Upstream commits, trial branches and anything marked",
        f'"{sources.marker}" are excluded on purpose — read the `why` there before widening it.',
        "These are CONTEXT for the prose; `commitCount` above stays this repository's own count.",
        "",
    ]
    if missing:
        lines += _warning(missing)
    if picked.unattributed:
        lines += _unattributed(picked.unattributed)
    if not picked.ours:
        # "nothing landed", "nothing could be fetched" and "everything that landed
        # needs a human call" are three different weeks, and only one of them is
        # safe to write up as an idle one.
        if missing:
            lines.append("  (nothing gathered — every declared source is in the warning above)")
        elif picked.unattributed:
            lines.append("  (nothing attributable — every commit in this window is in the block above)")
        else:
            lines.append("  (no commits of ours landed on the declared branches in this window)")
        return lines
    for repo in sorted({c.repo for c in picked.ours}):
        rows = [c for c in picked.ours if c.repo == repo]
        branches = ", ".join(sorted({c.branch for c in rows}))
        lines += [f"{repo} ({branches}) — {render_mod.plural(len(rows), 'commit', 'commits')}"]
        lines += [f"  {c.repo}  {c.short}  {c.subject}" for c in rows]
        lines.append("")
    return lines


def _warning(missing: list[Unreached]) -> list[str]:
    lines = [
        "!" * 72,
        f"WARNING — {len(missing)} declared fork source(s) COULD NOT BE REACHED.",
        "Their commits are MISSING from this brief. Do not write the week up as if",
        "these forks were idle; either fix `gh` and re-run, or gather them by hand",
        "with the exact command that failed:",
        "",
    ]
    for gap in missing:
        lines.append(f"  {gap.target.repo} {gap.target.branch} — {gap.why}")
        lines.append(f"    {shlex.join(gap.argv)}")
    lines += [
        "",
        "That is the command this brief ran, verbatim. Swap its --jq for '.[].commit.message'",
        "to read the full messages instead of the TSV.",
        "`gh auth login` fixes the usual case (installed but not authenticated).",
        "!" * 72,
        "",
    ]
    return lines


def _unattributed(commits: list[ForkCommit]) -> list[str]:
    """Commits GitHub could not tie to an account. Ours or upstream, a human has
    to say — but they are never dropped on the way past."""
    lines = [
        "?" * 72,
        f"DECIDE BY HAND — this window holds {render_mod.plural(len(commits), 'commit', 'commits')} "
        "with NO GitHub account.",
        "GitHub could not resolve the author email to a login, so the `ourAuthors` rule",
        "cannot see them and they are NOT counted above. Work pushed straight from the",
        "lab box lands exactly like this. Read each one. If it is ours, write it up and",
        "add its author name to `ourCommitAuthors` in",
        f"{SOURCES_PATH}, so it counts by itself next week; if it is upstream, ignore it.",
        "",
    ]
    for commit in commits:
        lines.append(f"  {commit.repo} {commit.branch}  {commit.short}  ({commit.name})  {commit.subject}")
    lines += ["", "?" * 72, ""]
    return lines

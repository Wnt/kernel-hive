#!/usr/bin/env python3
"""Render the Kernel Hive release notes from the hand-written weekly summaries.

WHO WRITES THE PROSE. Not this script. Every Sunday after 09:00 Helsinki the
operator runs a Claude Code pass (docs/lab/RELEASE-NOTES-PROMPT.md) that reads
the week's commits and writes ONE file:

    registry/release-notes/<end-date>.json      e.g. 2026-08-23.json

named after the Sunday the week CLOSED. That file is the only source of words.
`render` lays those files out into the three committed outputs and reads NO git
history for content, which is what makes `check` fully deterministic: the same
tree renders the same bytes on Sunday, on Monday, and mid-merge.

WEEK CUTOFF. A week ENDS at Sunday 09:00 Europe/Helsinki, and that boundary is
EXCLUSIVE: a commit stamped exactly 09:00:00 belongs to the week just starting.
Week 1 starts at the FIRST public commit (the open-source release, 2026-08-07)
and ends at the first Sunday 09:00 at-or-after it, so week 1 is a stub. Every
later week is the span between consecutive Sunday-09:00 boundaries, stepped on
the LOCAL wall clock through zoneinfo so 09:00 survives DST (the first
transition that matters here is 2026-10-25).

WEEK 0 IS NOT IN GIT. It covers the pre-public osgallery era, carries
`"source": "osgallery"`, and exists only as its summary file — git knows
nothing about it. render/status/check treat it as a first-class week; `brief`
never offers it, because there is no public history to cut it from.

ONLY CLOSED, SUMMARISED WEEKS ARE PUBLISHED. The in-progress week appears in no
output at all: it has no summary file, so there is nothing to render, and
`brief` only ever offers a week that has already closed. That is a convention
rather than an invariant — nothing stops a hand-written file dated next Sunday,
so `render` reads the clock once and WARNS about a week that has not closed.
`check` never looks at the clock, which is what keeps it deterministic.

WHERE A WEEK'S COMMITS COME FROM. `brief` reads this repo's git log AND the
public emulator forks the project's patches live on, declared by hand in
registry/release-notes/sources.json and gathered by release_notes_forks.py. The
forks are half the interesting work in a typical week; a brief cut from git log
alone under-reports it in silence, which is the one failure that module exists
to prevent. `gh` is shelled out to from `brief` ONLY — an unreachable fork is a
loud warning inside the brief, never a failed brief and never a quiet omission.

WHICH TIMESTAMP `brief` BUCKETS BY. The AUTHOR date -- stable across the
rebases this repo does constantly, where the committer date is not -- clamped
by the committer date (a clock that ran ahead), by `now` (a stamp that cannot
have happened yet), and from below by the repo's own root commit (a `git am` of
a 2019 patch must not invent 300 weeks). `git log` order is committer-date
order, so neither date is trustworthy alone.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

# Sibling module, imported the way scripts/stations_registry/* imports
# poster_registry: scripts/ is sys.path[0] both when this file is run as a
# script and under `unittest discover -s scripts`.
import release_notes_codelines as codelines_mod
import release_notes_forks as forks_mod
import release_notes_markup as markup_mod
import release_notes_pins as pins_mod
import release_notes_publish as publish_mod
import release_notes_render as render_mod
import release_notes_screenshots as screenshots_mod

REPO_ROOT = Path(__file__).resolve().parents[1]
TZ = ZoneInfo("Europe/Helsinki")
CUTOFF_LABEL = "Sunday 09:00 Europe/Helsinki"
SUMMARY_DIR = Path("registry") / "release-notes"
GIT_FORMAT = "%aI%x1f%cI%x1f%s"

# The locked schema. Anything outside ALLOWED_KEYS is a typo or an invented
# field; both must fail rather than be dropped on the floor by the renderer.
# The schema lives in its own module: it owns "is this authored file
# publishable?", and it is the half that grows with every new format rule.
from release_notes_schema import (  # noqa: E402  (after the sys.path preamble above)
    _check_continuity,
    _check_numbering,
    validate_week,
)


def run_git(args: list[str]) -> str:
    return subprocess.run(["git", "-C", str(REPO_ROOT), *args], check=True, capture_output=True, text=True).stdout


# ---------------------------------------------------------------- week maths


def first_boundary(epoch: datetime) -> datetime:
    """First Sunday 09:00 Helsinki after `epoch`, on a LATER date (exclusive end).

    Week 0's summary file is named after the epoch's own date — the public-release
    day — so a week 1 that closed on that same date would claim the same file
    name, and only one of the two could ever exist on disk. That happens whenever
    the root commit lands on a Sunday before 09:00; there, week 1 runs on to the
    FOLLOWING Sunday instead of closing a few hours after it opened. For any other
    epoch (this repo's is a Friday afternoon) the rule changes nothing.
    """
    local = epoch.astimezone(TZ)
    day = local.date() + timedelta(days=(6 - local.weekday()) % 7)
    candidate = datetime(day.year, day.month, day.day, 9, 0, tzinfo=TZ)
    if candidate <= local or candidate.date() == local.date():
        candidate += timedelta(days=7)
    return candidate


def next_boundary(boundary: datetime) -> datetime:
    """Step one week on the LOCAL wall clock, so 09:00 survives DST."""
    naive = boundary.replace(tzinfo=None) + timedelta(days=7)
    return naive.replace(tzinfo=TZ)


# Every comparison below is between aware datetimes sharing the SAME cached
# ZoneInfo, which Python compares by naive wall clock rather than by instant. At
# a 09:00 cutoff the two orderings agree everywhere, including both fold states
# of every DST Sunday; they diverge only if the cutoff moves into the repeated
# 03:00-04:00 hour. Keep the cutoff out of the fold.


def closed_spans(epoch: datetime, now: datetime) -> list[tuple[int, datetime, datetime]]:
    """(number, start, end) for every week that has already CLOSED.

    Numbering starts at 1 at the first public commit; week 0 is not in git and
    is never returned here.
    """
    spans = []
    number, start, end = 1, epoch, first_boundary(epoch)
    while end <= now:
        spans.append((number, start, end))
        number, start, end = number + 1, end, next_boundary(end)
    return spans


# ------------------------------------------------------------ git (brief only)


def _stamp(authored: str, committed: str, now: datetime) -> datetime:
    return min(
        datetime.fromisoformat(authored).astimezone(TZ),
        datetime.fromisoformat(committed).astimezone(TZ),
        now,
    )


def repo_epoch(now: datetime) -> datetime:
    """The root commit's stamp: the open-source release, and the floor for all
    the others."""
    stamps = []
    for sha in run_git(["rev-list", "--max-parents=0", "HEAD"]).split():
        authored, committed = run_git(["show", "-s", f"--format={GIT_FORMAT}", sha]).split("\x1f")[:2]
        stamps.append(_stamp(authored, committed, now))
    if not stamps:
        raise SystemExit("release-notes: no commits found")
    return min(stamps)


def read_commits(now: datetime) -> list[tuple[datetime, str]]:
    """(stamp, subject) for every non-merge commit, floored at the repo epoch."""
    floor = repo_epoch(now)
    commits = []
    for line in run_git(["log", "--no-merges", f"--format={GIT_FORMAT}"]).splitlines():
        if not line.strip():
            continue
        authored, committed, subject = line.split("\x1f", 2)
        commits.append((max(_stamp(authored, committed, now), floor), subject))
    return commits


# ----------------------------------------------------------------- validation


def summary_dir() -> Path:
    return REPO_ROOT / SUMMARY_DIR


def load_weeks() -> list[dict]:
    """Every summary file, validated, newest first. Absent files are not an
    error: a week nobody has written up yet simply does not publish."""
    errors: list[str] = []
    docs: list[dict] = []
    for path in sorted(summary_dir().glob("*.json")):
        # sources.json shares the directory but is not a week: it declares the
        # EXTRA commit sources `brief` gathers (the emulator forks). Skipped by
        # exact name, so a misnamed week file still fails validation loudly.
        if path.name == pins_mod.SOURCES_NAME:
            continue
        try:
            doc = json.loads(path.read_text())
        except json.JSONDecodeError as exc:
            errors.append(f"{path.name}: not valid JSON ({exc})")
            continue
        validate_week(doc, path, errors)
        if isinstance(doc, dict):
            docs.append(doc)
    _check_numbering(docs, errors)
    _check_continuity(docs, errors)
    if errors:
        raise SystemExit(
            "release-notes: the weekly summaries do not match the locked schema\n"
            + "\n".join(f"  - {line}" for line in errors)
            + f"\n  see {render_mod.PROMPT_PATH}"
        )
    docs.sort(key=lambda d: d["week"], reverse=True)
    names = markup_mod.station_names(REPO_ROOT)
    return [_decorate(doc, names) for doc in docs]


def _decorate(doc: dict, names: dict[str, str] | None = None) -> dict:
    """The published week document: the authored fields plus the two date-only
    convenience keys the SPA renders with, and the resolved screenshot tile row
    (an authored override, or the derived default — see
    release_notes_screenshots), as `[{"id", "name"}, ...]` so every renderer
    (both markdown outputs, the SPA, a GitHub release body) draws the same grid
    from one list without going back to the registry itself."""
    names = names or {}
    ids = screenshots_mod.resolve(doc)
    out = {
        "week": doc["week"],
        "title": doc["title"],
        "start": doc["start"],
        "end": doc["end"],
        "startDate": datetime.fromisoformat(doc["start"]).astimezone(TZ).date().isoformat(),
        "endDate": datetime.fromisoformat(doc["end"]).astimezone(TZ).date().isoformat(),
        "commitCount": doc["commitCount"],
        "codeLines": doc["codeLines"],
        "summary": list(doc["summary"]),
        "bullets": list(doc["bullets"]),
        "screenshots": [{"id": sid, "name": names.get(sid, sid)} for sid in ids],
    }
    if "source" in doc:
        out["source"] = doc["source"]
    return out


# -------------------------------------------------------------------- outputs


def outputs(weeks: list[dict]) -> dict[Path, str]:
    readme = REPO_ROOT / "README.md"
    try:
        # The README is spliced INTO, not written from scratch: everything
        # outside the two markers is hand-written and cannot be regenerated.
        readme_text = readme.read_text()
    except FileNotFoundError as missing:
        raise SystemExit(
            "release-notes: README.md is missing — the release-notes section is spliced into it and "
            "cannot be rebuilt from the summaries. Restore it (`git checkout README.md`), then re-render."
        ) from missing
    document = {"cutoff": CUTOFF_LABEL, "weeks": weeks}
    return {
        readme: render_mod.splice_readme(readme_text, render_mod.render_readme_section(weeks)),
        REPO_ROOT / "docs" / "RELEASE-NOTES.md": render_mod.render_archive(weeks, CUTOFF_LABEL),
        REPO_ROOT / "spa" / "public" / "release-notes.json": json.dumps(document, indent=2) + "\n",
    }


def cmd_render(now: datetime) -> int:
    weeks = load_weeks()
    for path, text in outputs(weeks).items():
        path.write_text(text)
        print(f"release-notes: wrote {path.relative_to(REPO_ROOT)}")
    if not weeks:
        print("release-notes: no weekly summaries yet — the outputs are placeholders")
    for week in reversed(weeks):
        print(f"  week {week['week']}: {week['startDate']}..{week['endDate']}  {week['title']}")
    # The only clock read in the whole render path, and it decides nothing: the
    # bytes written above are the same on any day. Publishing a week that has
    # not closed yet is a convention `check` cannot enforce without losing its
    # determinism, so say so here instead of letting it pass in silence.
    for week in weeks:
        if datetime.fromisoformat(week["end"]) > now:
            print(
                f"release-notes: WARNING — week {week['week']} ends {week['endDate']}, which has not "
                "happened yet; only CLOSED weeks should be published"
            )
    return 0


def _current(path: Path) -> str | None:
    """What is on disk, or None if a bad merge deleted the file outright."""
    try:
        return path.read_text()
    except FileNotFoundError:
        return None


def cmd_check() -> int:
    weeks = load_weeks()
    # Offline and deterministic: parse the fork declaration and re-read the build
    # scripts it cites, in BOTH directions — a cited file that stopped pinning its
    # branch, and a branch the tree pins that nobody declared. No network —
    # `check` never fetches, on any day.
    forks_mod.load_sources(REPO_ROOT)
    drift = pins_mod.drift_errors(REPO_ROOT)
    for line in drift:
        print(f"release-notes: {line}")
    if drift:
        print("release-notes: fix the pin citation or the build script — a brief must gather what the build ships")
        return 1
    stale = [str(path.relative_to(REPO_ROOT)) for path, text in outputs(weeks).items() if _current(path) != text]
    for path in stale:
        print(f"release-notes: STALE — {path}")
    if stale:
        print("release-notes: run `make release-notes` and commit the result")
        return 1
    print(f"release-notes: OK — {len(weeks)} weeks, three outputs match a fresh render")
    return 0


# ------------------------------------------------------------ status / brief


def week_path(end: datetime) -> Path:
    return summary_dir() / f"{end.astimezone(TZ).date().isoformat()}.json"


FACTS_DIRNAME = "facts"


def facts_dir(end: datetime) -> Path:
    """registry/release-notes/facts/<end-date>/ — the free-form inbox a
    station wave drops a note into (`<station-id>.md`) instead of touching the
    week's own JSON. `render`/`check` never read this directory: it holds raw
    material, not anything that has to match the locked schema."""
    return summary_dir() / FACTS_DIRNAME / end.astimezone(TZ).date().isoformat()


def facts_files(end: datetime) -> list[Path]:
    d = facts_dir(end)
    return sorted(d.glob("*.md")) if d.is_dir() else []


DRIFT_WARN_FRACTION = 0.10


def _commit_count_drift(
    start: datetime, end: datetime, recorded: object, all_commits: list[tuple[datetime, str]]
) -> str | None:
    """None when `recorded` is missing/unusable or within `DRIFT_WARN_FRACTION`
    of a fresh count; otherwise a one-line warning.

    A week authored mid-week (before its Sunday closed) records a commit count
    that a later, complete re-count will not match — that is exactly what
    happened to week 5, which was authored missing ~400 commits. `brief` for a
    week whose file already exists is a RE-authoring, and this is the check
    that notices someone skipped straight to it.
    """
    if not isinstance(recorded, int) or isinstance(recorded, bool) or recorded <= 0:
        return None
    fresh = sum(1 for stamp, _ in all_commits if start <= stamp < end)
    drift = abs(fresh - recorded) / recorded
    if drift <= DRIFT_WARN_FRACTION:
        return None
    return (
        f"WARNING: commitCount {recorded} recorded, {fresh} on a fresh count "
        f"({drift:.0%} drift — was this authored before the week closed?)"
    )


def _late_facts(path: Path, end: datetime) -> list[Path]:
    """Fact notes dropped into the inbox AFTER the week was authored — a
    station wave landed once the write-up already existed, so the write-up is
    missing whatever it says. Compared by mtime, offline, no git involved."""
    written_at = path.stat().st_mtime
    return [f for f in facts_files(end) if f.stat().st_mtime > written_at]


def cmd_status(now: datetime) -> int:
    epoch = repo_epoch(now)
    print(f"release-notes: weeks close {CUTOFF_LABEL}; the in-progress week is never published")
    rows = [(0, None, epoch)] + [(n, s, e) for n, s, e in closed_spans(epoch, now)]
    all_commits = read_commits(now)
    for number, start, end in rows:
        path = week_path(end)
        state = "written" if path.exists() else "MISSING"
        if path.exists() and start is not None:
            try:
                recorded = json.loads(path.read_text()).get("commitCount")
            except json.JSONDecodeError:
                recorded = None
            drift = _commit_count_drift(start, end, recorded, all_commits)
            if drift:
                state = f"written — {drift}"
        if path.exists():
            late_facts = _late_facts(path, end)
            if late_facts:
                names = ", ".join(f.stem for f in late_facts)
                state += f" — WARNING: facts arrived after authoring ({names}) — re-author this week"
        window = "pre-public era" if start is None else f"{start:%Y-%m-%d %H:%M}"
        print(f"  week {number:>2}  {window} – {end:%Y-%m-%d %H:%M}  {path.relative_to(REPO_ROOT)}  {state}")
    missing = [n for n, _, e in rows if not week_path(e).exists()]
    print(
        f"release-notes: {len(rows) - len(missing)}/{len(rows)} closed weeks written"
        + (f", missing {missing}" if missing else "")
    )
    return 0


CONTRACT = """\
Output contract
---------------
Write EXACTLY this file, and nothing else:

    {path}

    {{
      "week": {number},
      "title": "<2-6 words, specific, no week number in it>",
      "start": "{start}",
      "end":   "{end}",
      "commitCount": {count},
      "summary": ["<paragraph 1>", "<paragraph 2>", "<paragraph 3>"],
      "bullets": ["<highlight>", "..."]
    }}

  - summary: exactly 3 paragraphs, 300-400 words in total.
  - bullets: 1-20 entries, each ONE line of at most 160 characters, no leading
    dash, no trailing period required. Highlights worth reading on their own,
    not a changelog.
  - Never invent a fact, a number, a date or a capability: every claim traces to
    a commit above. If you cannot tell whether something landed or was only
    attempted, say what the commits say, or leave it out.
  - Never write a real IP, hostname, MAC, serial or domain — this repo is
    public. Placeholders only.
  - Voice and the full authoring brief: {prompt}

Then: python3 scripts/release-notes.py render && python3 scripts/release-notes.py check
"""


def _fork_lines(start: datetime, end: datetime) -> tuple[list[str], bool]:
    """The EMULATOR FORKS block, and whether the gather came back short.

    `brief` is the ONLY path that reaches the network. A fork that cannot be
    reached is reported, never dropped: gathering under-reports the week in
    exactly the way this section exists to prevent, so the failure is printed
    loudly inside the brief instead of failing the brief outright. The whole
    brief is still printed either way — the flag only decides the EXIT CODE, so
    a wrapper that reads nothing but `$?` cannot mistake a short week for a
    complete one.
    """
    sources = forks_mod.load_sources(REPO_ROOT)
    picked, missing = forks_mod.gather(sources, start, end, TZ)
    return forks_mod.format_section(sources, picked, missing), bool(missing)


def cmd_brief(now: datetime, want: str | None) -> int:
    epoch = repo_epoch(now)
    spans = closed_spans(epoch, now)
    if not spans:
        print("release-notes: no week has closed yet — the first one closes at the next Sunday 09:00 Helsinki")
        return 1
    if want:
        picked = [s for s in spans if s[2].astimezone(TZ).date().isoformat() == want]
        if not picked:
            ends = ", ".join(e.astimezone(TZ).date().isoformat() for _, _, e in spans)
            week0 = ""
            if want == week_path(epoch).stem:
                week0 = " — that is week 0, the pre-public era, which is hand-written and has no git history to cut"
            print(f"release-notes: no closed week ends {want}{week0}. Closed weeks end: {ends}")
            return 1
        number, start, end = picked[0]
    else:
        unwritten = [s for s in spans if not week_path(s[2]).exists()]
        if not unwritten:
            print("release-notes: every closed week already has a summary — nothing to write")
            return 0
        # OLDEST first. Week numbers must run contiguously from 0, so writing the
        # newest hole after a missed Sunday would leave a gap that `render`
        # refuses outright — the notes would be blocked by following the happy
        # path. Filling from the bottom can never do that.
        number, start, end = unwritten[0]
    subjects = [subject for stamp, subject in read_commits(now) if start <= stamp < end]
    path = (week_path(end)).relative_to(REPO_ROOT)
    older = ([] if week_path(epoch).exists() else [0]) + [
        n for n, _, e in spans if n < number and not week_path(e).exists()
    ]
    if older:
        print(
            f"release-notes: WARNING — week(s) {older} are still unwritten. Week numbers must run "
            "contiguously from 0, so `render` refuses the archive until they exist: write them first "
            "(`--week <end-date>`; week 0 predates this repo and is written by hand)."
        )
        print("")
    print(f"release-notes brief — week {number}")
    print(f"  window : {start:%Y-%m-%d %H:%M} – {end:%Y-%m-%d %H:%M} Europe/Helsinki (end exclusive)")
    print(f"  commits: {len(subjects)}")
    # Both numbers go into the file: `commitCount` as provenance, `codeLines` as
    # the one the pages actually print. Computed here rather than at render time
    # so `render` and `check` stay offline and deterministic.
    code_lines = codelines_mod.for_window(str(REPO_ROOT), start.isoformat(), end.isoformat())
    print(f"  codeLines: {code_lines}   (added lines of source, docs excluded — copy this verbatim)")
    print(f"  write  : {path}")
    print("")
    print(f"Commit subjects, newest first ({len(subjects)} non-merge commits):")
    for subject in subjects:
        print(f"  {subject}")
    fork_lines, incomplete = _fork_lines(start, end)
    for line in fork_lines:
        print(line)
    print("")
    fact_paths = facts_files(end)
    if fact_paths:
        print("FACTS FROM THE FLOOR")
        print(f"  (dropped by station waves at {facts_dir(end).relative_to(REPO_ROOT)}/ — raw material, not prose)")
        print("")
        for fact_path in fact_paths:
            print(f"--- {fact_path.relative_to(REPO_ROOT)} ---")
            print(fact_path.read_text().rstrip("\n"))
            print("")
    print(
        CONTRACT.format(
            path=path,
            number=number,
            start=start.isoformat(),
            end=end.isoformat(),
            count=len(subjects),
            prompt=render_mod.PROMPT_PATH,
        )
    )
    if incomplete:
        # The brief above is complete as prose and short as data. Exit non-zero
        # so a wrapper reading only `$?` sees the gap the banner describes.
        print("release-notes: EXIT 2 — the brief printed in full, but one or more fork sources are missing from it.")
        return 2
    return 0


# --------------------------------------------------------------------- publish


def resolve_week_commit(now: datetime, week_number: int, end: datetime) -> str:
    return publish_mod.resolve_week_commit(
        now, week_number, end, run_git=run_git, git_format=GIT_FORMAT, stamp=_stamp, repo_epoch=repo_epoch
    )


def cmd_publish(now: datetime, want: str | None, dry_run: bool, retag: bool) -> int:
    return publish_mod.cmd_publish(
        now,
        want,
        dry_run,
        retag,
        repo_root=REPO_ROOT,
        load_weeks=load_weeks,
        run_git=run_git,
        git_format=GIT_FORMAT,
        stamp=_stamp,
        repo_epoch=repo_epoch,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Render the release notes from the weekly summary files.")
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("render", help="write the three outputs from registry/release-notes/*.json (default)")
    sub.add_parser("check", help="validate the summaries and assert the outputs match a fresh render")
    sub.add_parser("status", help="list the closed weeks and whether each has been written up")
    brief = sub.add_parser("brief", help="print the authoring brief for the OLDEST week with no summary yet")
    brief.add_argument("--week", metavar="END-DATE", help="the Sunday a week closed, e.g. 2026-08-23")
    publish = sub.add_parser("publish", help="ensure a git tag + GitHub release for every closed, written week")
    publish.add_argument("--week", metavar="END-DATE", help="limit to the week that closed on this Sunday")
    publish.add_argument(
        "--dry-run", action="store_true", help="print every tag/release action and body length; touch nothing"
    )
    publish.add_argument("--retag", action="store_true", help="move a tag that already exists at a different commit")
    args = parser.parse_args(argv)
    now = datetime.now(TZ)
    if args.command == "check":
        return cmd_check()
    if args.command == "status":
        return cmd_status(now)
    if args.command == "brief":
        return cmd_brief(now, args.week)
    if args.command == "publish":
        return cmd_publish(now, args.week, args.dry_run, args.retag)
    return cmd_render(now)


if __name__ == "__main__":
    sys.exit(main())

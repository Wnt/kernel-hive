#!/usr/bin/env python3
"""The locked shape of a weekly summary file, and every way it can be wrong.

Split out of release-notes.py, which owns the WEEK MATHS (boundaries, git,
windows) and the commands. This module owns only the question "is this authored
file publishable?", which is the part that grows every time the format gains a
rule — themes, word budgets, the markup vocabulary, the one underline a week is
allowed. Keeping it here is what stops that growth from pushing the driver over
the repo's 600-line Python cap.

Every check APPENDS a message and returns; nothing here repairs, truncates or
rewrites an author's file. A summary that breaches the schema fails the gate
with a message naming the field, because the alternative — quietly publishing a
trimmed version of what somebody wrote — is worse than a red build.
"""

from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import release_notes_markup as markup_mod

REPO_ROOT = Path(__file__).resolve().parents[1]
# The cutoff's zone, needed here only to name a week file after its `end`.
TZ = ZoneInfo("Europe/Helsinki")

# `commitCount` is kept as provenance and cross-checks the brief, but it is NOT
# published: a raw commit count is a developer metric, and the 16-vs-713 swing
# made the week the project was open-sourced look like its quietest. The pages
# print `codeLines` instead — added lines of hand-written source, docs excluded.
REQUIRED_KEYS = {"week", "title", "start", "end", "commitCount", "codeLines", "summary", "bullets"}
ALLOWED_KEYS = REQUIRED_KEYS | {"source"}
WEEK0_SOURCE = "osgallery"
TITLE_WORDS = (2, 6)
# The three questions a visitor actually has, in the order they ask them: what
# is new to go and see, what can I now do, and what got better. The themes are
# FIXED and validated rather than left to each week's author, because the value
# of a series is that week 12 reads like week 3 — a reader who learned the shape
# once should never have to re-learn it. Week 0 gets a leading section because
# it is somebody's first contact with the project and has to say what this IS.
NORMAL_THEMES = ("New stations", "Major features", "Quality improvements")
WEEK0_THEMES = ("The story so far", *NORMAL_THEMES)
NORMAL_WORDS = (300, 400)
# Week 0 is the ONE week with a whole month of history behind it (the pre-public
# osgallery era, 713 non-merge commits), so it was written to a wider budget as a
# deliberate one-off. Normal weeks do not get it.
WEEK0_WORDS = (600, 700)
BULLETS = (1, 20)
BULLET_CHARS = 160
WEEK_IN_TITLE_RE = re.compile(r"\bweeks?\s*\d", re.I)


def _is_int(value: object) -> bool:
    # bool is an int in Python, and `"week": true` must not validate.
    return isinstance(value, int) and not isinstance(value, bool)


def _parse_stamp(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else None


def _check_title(title: object, fail) -> None:
    if not isinstance(title, str) or not title.strip():
        fail("`title` must be a non-empty string")
        return
    words = len(title.split())
    if not TITLE_WORDS[0] <= words <= TITLE_WORDS[1]:
        fail(f"`title` is {words} words, must be {TITLE_WORDS[0]}-{TITLE_WORDS[1]}")
    if WEEK_IN_TITLE_RE.search(title):
        fail("`title` must not contain the week number — the heading already prints it")


def _check_summary(summary: object, week: object, fail, stations: frozenset[str]) -> None:
    """`summary` is a fixed list of themed sections, not free paragraphs.

    Word budgets are counted on the PLAIN text (markup stripped): the reader's
    effort is the prose, and counting the raw string would let a section thick
    with links claim a third more words than it says.
    """
    themes = WEEK0_THEMES if week == 0 else NORMAL_THEMES
    if not isinstance(summary, list):
        fail("`summary` must be a list of themed sections")
        return
    if [s.get("theme") if isinstance(s, dict) else None for s in summary] != list(themes):
        fail(f"`summary` themes must be exactly {list(themes)}, in that order")
        return
    for index, section in enumerate(summary):
        if sorted(section.keys()) != ["text", "theme"]:
            fail(f"summary section {index + 1} must have exactly `theme` and `text`")
            continue
        if not isinstance(section["text"], str) or not section["text"].strip():
            fail(f"summary section `{section['theme']}` has no text")
            continue
        for error in markup_mod.markup_errors(section["text"], stations, f"summary `{section['theme']}`"):
            fail(error)
    budget = WEEK0_WORDS if week == 0 else NORMAL_WORDS
    words = sum(markup_mod.word_count(s["text"]) for s in summary if isinstance(s.get("text"), str))
    if not budget[0] <= words <= budget[1]:
        fail(f"`summary` is {words} words, must be {budget[0]}-{budget[1]}")


def _check_bullets(bullets: object, fail, stations: frozenset[str]) -> None:
    if not isinstance(bullets, list) or not all(isinstance(b, str) and b.strip() for b in bullets):
        fail("`bullets` must be a list of non-empty strings")
        return
    if not BULLETS[0] <= len(bullets) <= BULLETS[1]:
        fail(f"`bullets` has {len(bullets)} entries, must be {BULLETS[0]}-{BULLETS[1]}")
    for index, bullet in enumerate(bullets):
        if "\n" in bullet:
            fail(f"bullet {index + 1} spans more than one line")
        if len(markup_mod.plain_text(bullet)) > BULLET_CHARS:
            fail(
                f"bullet {index + 1} is {len(markup_mod.plain_text(bullet))} chars of prose, must be <= {BULLET_CHARS}"
            )
        for error in markup_mod.markup_errors(bullet, stations, f"bullet {index + 1}"):
            fail(error)
        # Checked on the PLAIN text: a bullet that opens with **bold** or
        # *italic* starts with `*` in the source but not in the prose, and
        # guarding the raw string rejects perfectly good emphasis.
        if markup_mod.plain_text(bullet).lstrip().startswith(("-", "*", "•")):
            fail(f"bullet {index + 1} carries its own list marker — the renderer adds it")


def _check_underline(doc: dict, fail) -> None:
    """Exactly one <u> per week — see release_notes_markup: underlined text that
    is not a link reads as a broken one, and in the About view the station names
    really are links. Rationing it keeps it meaning "this is the week's
    headline" instead of decaying into decoration."""
    texts = [s["text"] for s in doc.get("summary", []) if isinstance(s, dict) and isinstance(s.get("text"), str)]
    texts += [b for b in doc.get("bullets", []) if isinstance(b, str)]
    found = markup_mod.underline_count(texts)
    if found != markup_mod.UNDERLINES_PER_WEEK:
        fail(f"found {found} <u> passages, must be exactly {markup_mod.UNDERLINES_PER_WEEK} (the week's headline)")


def validate_week(doc: object, path: Path, errors: list[str]) -> None:
    """Append one message per breach. Never repairs, never truncates."""

    def fail(message: str) -> None:
        errors.append(f"{path.name}: {message}")

    if not isinstance(doc, dict):
        fail("must be a JSON object")
        return
    for key in sorted(REQUIRED_KEYS - doc.keys()):
        fail(f"missing `{key}`")
    for key in sorted(doc.keys() - ALLOWED_KEYS):
        fail(f"unknown key `{key}` — the schema is locked")
    week = doc.get("week")
    if not _is_int(week) or week < 0:
        fail("`week` must be a non-negative integer")
    if "title" in doc:
        _check_title(doc["title"], fail)
    if not _is_int(doc.get("commitCount")) or doc.get("commitCount", -1) < 0:
        fail("`commitCount` must be a non-negative integer")
    # Only when the key is PRESENT: a missing key already failed above, and
    # reporting it twice makes one mistake look like two.
    if "codeLines" in doc and (not _is_int(doc["codeLines"]) or doc["codeLines"] < 0):
        fail("`codeLines` must be a non-negative integer — the brief prints it")
    start, end = _parse_stamp(doc.get("start")), _parse_stamp(doc.get("end"))
    if start is None:
        fail("`start` must be an ISO 8601 timestamp with a UTC offset")
    if end is None:
        fail("`end` must be an ISO 8601 timestamp with a UTC offset")
    if start and end:
        if start >= end:
            fail("`start` must be earlier than `end`")
        stem = end.astimezone(TZ).date().isoformat()
        if path.stem != stem:
            fail(f"file name does not match `end` — this week's file is {stem}.json")
    stations = markup_mod.station_ids(REPO_ROOT)
    if "summary" in doc:
        _check_summary(doc["summary"], week, fail, stations)
    if "bullets" in doc:
        _check_bullets(doc["bullets"], fail, stations)
    _check_underline(doc, fail)
    if week == 0 and doc.get("source") != WEEK0_SOURCE:
        fail(f'week 0 must carry "source": "{WEEK0_SOURCE}" — it predates this repository')
    if week != 0 and "source" in doc:
        fail("`source` belongs to week 0 only")


def _check_numbering(docs: list[dict], errors: list[str]) -> None:
    numbers = sorted(d["week"] for d in docs if _is_int(d.get("week")))
    duplicates = sorted({n for n in numbers if numbers.count(n) > 1})
    if duplicates:
        errors.append(f"week numbers are not unique: {duplicates}")
    unique = sorted(set(numbers))
    if unique and unique != list(range(len(unique))):
        errors.append(
            f"week numbers must run contiguously from 0, got {unique} — write the missing week(s) "
            "with `release-notes.py brief --week <end-date>` (week 0 is hand-written)"
        )


def _check_continuity(docs: list[dict], errors: list[str]) -> None:
    """Consecutive weeks must ABUT: week N starts exactly where week N-1 ended.

    `start` is copied by hand from the brief, so it is the field a paste slip
    corrupts — and nothing else notices, because each file is internally
    consistent (`start < end`, the name matches `end`). Left unchecked, one
    wrong `start` publishes a timeline that swallows the weeks before it.
    """
    ordered = sorted((d for d in docs if _is_int(d.get("week"))), key=lambda d: d["week"])
    for previous, current in zip(ordered, ordered[1:]):
        if previous["week"] + 1 != current["week"]:
            continue  # a gap: _check_numbering already refused it
        before, after = _parse_stamp(previous.get("end")), _parse_stamp(current.get("start"))
        if before and after and before != after:
            errors.append(
                f"week {current['week']} starts {current['start']}, but week {previous['week']} ends "
                f"{previous['end']} — consecutive weeks must abut"
            )

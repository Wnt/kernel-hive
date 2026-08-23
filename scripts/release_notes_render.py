#!/usr/bin/env python3
"""Rendering half of the release-notes generator (scripts/release-notes.py).

scripts/release-notes.py owns the FACTS -- reading git, clamping the timestamps,
classifying a subject, cutting the weeks. This module owns how those facts are
WORDED: the two markdown documents, the README digest's bullet selection, and
the escaping/label rules that keep a commit subject readable once it is a
bullet. They are split because the generator was over the repo's 600-line
Python budget as one file, and this is the seam that does not tangle: nothing
here touches git or the clock, so every function is a pure transform of the
document that build() returns.
"""

from __future__ import annotations

import re
from collections import deque
from datetime import datetime

COMMIT_URL = "https://github.com/Wnt/kernel-hive/commit/"
README_START = "<!-- release-notes:start -->"
README_END = "<!-- release-notes:end -->"
README_WEEKS = 4
README_BULLETS = 6
# Throwaway subjects: real commits, kept in the archive, but never a headline.
PLACEHOLDER_RE = re.compile(r"^(wip|tmp|temp|fixup|squash|amend|stash)\b", re.I)


def plural(count: int, one: str, many: str) -> str:
    return f"{count} {one if count == 1 else many}"


def week_heading(week: dict) -> str:
    # Both endpoints carry their TIME because the span is half-open: week N ends
    # and week N+1 starts at the same Sunday 09:00, and printing bare dates made
    # two consecutive weeks both claim that day.
    start = datetime.fromisoformat(week["start"])
    end = datetime.fromisoformat(week["end"])
    span = f"{start:%Y-%m-%d %H:%M} – {end:%Y-%m-%d %H:%M}"
    suffix = " · in progress" if week["inProgress"] else ""
    return f"Week {week['number']} · {span}{suffix}"


def md(text: str) -> str:
    """Escape the one thing CommonMark eats here: `<session>` and friends parse
    as raw inline HTML, and GitHub's sanitizer then deletes them, so the
    placeholder disappears from the rendered bullet. Code spans are left alone —
    a backslash inside one renders as a backslash."""
    parts = re.split(r"(`+[^`]*`+)", text)
    return "".join(part if part.startswith("`") else part.replace("<", r"\<") for part in parts)


def label(entry: dict) -> str:
    """`**scope** — `, unless the text already opens with that scope: a bullet
    reading "**chokanji** — Chokanji joins the retronet web plane" says it
    twice."""
    scope = entry.get("scope")
    if not scope or entry["text"].lower().startswith(scope.lower()):
        return ""
    return f"**{scope}** — "


def _digest_order(entries: list[dict]) -> list[dict]:
    """A section's entries, best-first for a digest: one per distinct scope
    before any scope repeats, and placeholder subjects (wip/tmp) last."""
    seen: set[str] = set()
    first, repeat, noise = [], [], []
    for entry in entries:
        key = entry.get("scope") or entry["text"]
        if PLACEHOLDER_RE.match(entry.get("scope") or "") or PLACEHOLDER_RE.match(entry["text"]):
            noise.append(entry)
        else:
            (repeat if key in seen else first).append(entry)
        seen.add(key)
    return first + repeat + noise


def digest_entries(week: dict, limit: int) -> list[dict]:
    """The week's headline bullets: a round-robin ACROSS sections, not the top
    of the first one. `flat[:6]` meant "the six newest Stations commits", which
    put housekeeping commits on the README while a week's UI, retronet and docs
    work went unmentioned."""
    queues = [deque(_digest_order(s["entries"])) for s in week["sections"] if s["entries"]]
    picked: list[dict] = []
    seen: set[str] = set()
    while queues and len(picked) < limit:
        for queue in list(queues):
            while queue:
                entry = queue.popleft()
                if entry["text"] in seen:  # a rebase can land the same subject twice
                    continue
                seen.add(entry["text"])
                picked.append(entry)
                break
            if not queue:
                queues.remove(queue)
            if len(picked) >= limit:
                break
    return picked


def collapse_duplicates(entries: list[dict]) -> list[dict]:
    """One bullet per distinct subject, carrying every sha that wrote it.

    A rebase or cherry-pick lands the same subject twice; two byte-identical
    bullets in a row read as a rendering bug. Nothing is dropped -- each commit
    still contributes its own linked sha. The JSON keeps one entry per commit
    (the SPA lists them individually, where each row is its own commit link);
    this collapse is a property of the prose archive only.
    """
    merged: dict[tuple[str | None, str], dict] = {}
    for entry in entries:
        key = (entry.get("scope"), entry["text"])
        merged.setdefault(key, {"scope": entry.get("scope"), "text": entry["text"], "shas": []})
        merged[key]["shas"].append(entry["sha"])
    return list(merged.values())


def render_archive(data: dict) -> str:
    lines = [
        "# Release notes — full archive",
        "",
        f"Every non-merge commit, grouped into weeks. A week ends at **{data['cutoff']}**",
        "(exclusive: a commit stamped exactly 09:00 starts the next week, which is why every",
        "week below prints the time on both ends of its range). Week 1 begins at the open-source",
        f"release commit, {data['epoch']}. Weeks are newest-first; the newest one is still in",
        "progress. Generated by `make release-notes` — do not hand-edit.",
        "",
    ]
    for week in data["weeks"]:
        lines += [f"## {week_heading(week)}", "", f"{plural(week['commitCount'], 'commit', 'commits')}.", ""]
        for section in week["sections"]:
            lines.append(f"### {section['title']}")
            lines.append("")
            if section.get("collapsed"):
                lines += [f"{plural(section['count'], 'dependency bump', 'dependency bumps')}.", ""]
                continue
            for entry in collapse_duplicates(section["entries"]):
                links = ", ".join(f"[`{sha}`]({COMMIT_URL}{sha})" for sha in entry["shas"])
                lines.append(f"- {label(entry)}{md(entry['text'])} ({links})")
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_readme_section(data: dict) -> str:
    lines = ["## Release notes", ""]
    for week in data["weeks"][:README_WEEKS]:
        counts = ", ".join(f"{s['title']} {s['count']}" for s in week["sections"])
        headline = f"{plural(week['commitCount'], 'commit', 'commits')} — {counts}."
        lines += [f"### {week_heading(week)}", "", headline if counts else "No commits.", ""]
        picked = digest_entries(week, README_BULLETS)
        for entry in picked:
            lines.append(f"- {label(entry)}{md(entry['text'])}")
        remaining = week["commitCount"] - len(picked)
        if remaining > 0:
            lines.append(f"- …and {remaining} more")
        lines.append("")
    lines += [
        "Full archive, every commit: [`docs/RELEASE-NOTES.md`](docs/RELEASE-NOTES.md).",
        "",
        "Generated by `make release-notes` — do not hand-edit.",
    ]
    return "\n".join(lines).rstrip() + "\n"


def splice_readme(readme: str, section: str) -> str:
    block = f"{README_START}\n{section}{README_END}\n"
    has_start, has_end = README_START in readme, README_END in readme
    if has_start != has_end:
        # Falling through to the insert path here would append a SECOND
        # changelog under a second heading and say nothing about it.
        raise SystemExit(
            "release-notes: README.md has only one of the release-notes markers "
            f"({README_START if has_start else README_END} is missing) — restore both, "
            "then regenerate. A merge that eats one marker must not silently duplicate the section."
        )
    if has_start:
        head, rest = readme.split(README_START, 1)
        _, tail = rest.split(README_END, 1)
        return head + block + "\n" + tail.lstrip("\n")
    marker = "## Contributing"
    if marker not in readme:
        raise SystemExit("release-notes: README.md has no '## Contributing' heading")
    head, tail = readme.split(marker, 1)
    return head.rstrip("\n") + "\n\n" + block + "\n" + marker + tail

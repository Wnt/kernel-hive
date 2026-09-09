#!/usr/bin/env python3
"""Rendering half of the release notes (scripts/release-notes.py).

scripts/release-notes.py owns the FACTS -- the week maths, reading and
validating the hand-written summary files, and the git window a `brief` is cut
from. This module owns how those facts are WORDED: the two markdown documents
and the escaping that keeps an authored line readable once it is a bullet.
Nothing here touches git, the clock or the filesystem, so every function is a
pure transform of the week documents the loader returns.

The prose itself is NOT generated. A human-triggered Claude Code pass writes
one `registry/release-notes/<end-date>.json` per week (see
docs/lab/RELEASE-NOTES-PROMPT.md) and these renderers only lay it out, which is
why every output can be diffed byte-for-byte against a fresh render.
"""

from __future__ import annotations

from datetime import datetime
from typing import Callable

import release_notes_markup as markup
import release_notes_screenshots as screenshots_mod

README_START = "<!-- release-notes:start -->"
README_END = "<!-- release-notes:end -->"
ARCHIVE_PATH = "docs/RELEASE-NOTES.md"
PROMPT_PATH = "docs/lab/RELEASE-NOTES-PROMPT.md"
WEEK0_NOTE = "*Week 0 covers the month before this project's source was published.*"
# The reader-facing pages carry NO maintainer instructions. A visitor-perspective
# review found "edit those files, never this one", the Sunday-boundary rule and a
# link to the authoring prompt sitting at the top of the public archive — all of
# it addressed to whoever maintains the notes, none of it about old computers.
# The rules still live in docs/lab/RELEASE-NOTES-PROMPT.md, where their audience is.
GALLERY_INVITE = f"Every machine named here is live at [{markup.GALLERY.split('//')[1]}]({markup.GALLERY})."
NOTHING_YET = (
    "No week has been written up yet. Run `python3 scripts/release-notes.py brief` "
    f"and follow [`{PROMPT_PATH}`]({PROMPT_PATH})."
)


def plural(count: int, one: str, many: str) -> str:
    """Still used by the BRIEF (release_notes_forks) even though the rendered
    pages no longer print a commit count — the brief is for the author, where a
    commit count is exactly the right unit."""
    return f"{count:,} {one if count == 1 else many}"


def anchor(week: dict) -> str:
    """A stable in-document id, emitted as raw HTML above the heading.

    Deriving the link target from GitHub's own heading slug would couple every
    README link to the punctuation of a hand-written title; a title typo would
    then silently break the link instead of failing a render.
    """
    return f"week-{week['week']}"


def span(week: dict) -> str:
    # Both endpoints carry their TIME because the span is half-open: week N ends
    # and week N+1 starts at the same Sunday 09:00, and printing bare dates made
    # two consecutive weeks both claim that day.
    start = datetime.fromisoformat(week["start"])
    end = datetime.fromisoformat(week["end"])
    return f"{start:%Y-%m-%d %H:%M} – {end:%Y-%m-%d %H:%M}"


def heading(week: dict) -> str:
    return f"Week {week['week']} · {md(week['title'])} · {span(week)}"


def md(text: str) -> str:
    """Render authored prose for GitHub — see release_notes_markup.to_markdown:
    `[Windows 3.11](station:win311)` becomes an absolute gallery URL (a reader
    on GitHub is nowhere near the SPA's relative routes), `<u>` survives, and
    every other stray `<` is escaped so GitHub's sanitiser cannot eat it."""
    return markup.to_markdown(text)


def screenshots_section(week: dict, level: int, img: Callable[[str], str]) -> list[str]:
    """The "tiled screenshots" sub-section: a heading plus the `<table>` of
    thumbnails, or nothing at all when the week's tile list is empty (a
    fixture with no station links, in practice — every real week names at
    least one machine)."""
    items = week.get("screenshots") or []
    if not items:
        return []
    lines = ["#" * (level + 1) + " Screenshots", ""]
    lines += screenshots_mod.table(items, img)
    lines.append("")
    return lines


def _body(week: dict, level: int, img: Callable[[str], str]) -> list[str]:
    """The screenshot tiles, the themed sections, then the highlights, then
    the week's size.

    THE HIGHLIGHTS NEED THEIR OWN HEADING. Emitted straight after the last
    section, the bullet list renders *inside* "Quality improvements" — so a
    reader scanning that heading was handed "Sign into ICQ ..." as its first
    item. It was wrong in every week and invisible in the source, because the
    JSON has bullets as a sibling of the sections while markdown has no way to
    know that.

    `level` is the week's own heading depth, so the sub-headings sit one below
    it: the archive puts a week at `##` and the README puts the newest week at
    `###`, and a pinned depth would grow an `##` inside the README's own
    section.
    """
    lines: list[str] = []
    lines += screenshots_section(week, level, img)
    for section in week["summary"]:
        lines += ["#" * (level + 1) + f" {section['theme']}", "", md(section["text"]), ""]
    if week["bullets"]:
        lines += ["#" * (level + 1) + " Also this week", ""]
        for bullet in week["bullets"]:
            lines.append(f"- {md(bullet)}")
        lines.append("")
    if week["week"] == 0:
        lines += [WEEK0_NOTE, ""]
    lines += [f"*{week['codeLines']:,} lines of code.*", ""]
    return lines


def render_archive(weeks: list[dict], cutoff: str) -> str:
    lines = [
        "# Release notes — full archive",
        "",
        "Every week, newest first.",
        "",
        GALLERY_INVITE,
        "",
    ]
    if not weeks:
        return "\n".join(lines + [NOTHING_YET]).rstrip() + "\n"
    for week in weeks:
        lines += [f'<a id="{anchor(week)}"></a>', "", f"## {heading(week)}", ""]
        lines += _body(week, 2, lambda sid: screenshots_mod.IMG_ARCHIVE.format(id=sid))
    return "\n".join(lines).rstrip() + "\n"


def render_readme_section(weeks: list[dict]) -> str:
    """The SHORT form: only the most recent week, and only enough of it to make
    someone click through — its screenshot tiles and its "New stations"
    paragraph — then one line into the full week and the archive.

    The full weekly write-up (all three themed sections, the highlights, every
    earlier week) lives in docs/RELEASE-NOTES.md; a stranger's first look at
    the README should not have to scroll past a quality-improvements paragraph
    to find the repo's own description.
    """
    lines = ["## Release notes", ""]
    if not weeks:
        return "\n".join(lines + [NOTHING_YET]).rstrip() + "\n"
    newest = weeks[0]
    lines += [f"### {heading(newest)}", ""]
    lines += screenshots_section(newest, 3, lambda sid: screenshots_mod.IMG_README.format(id=sid))
    new_stations = next((s for s in newest["summary"] if s["theme"] == "New stations"), None)
    if new_stations is not None:
        lines += [md(new_stations["text"]), ""]
    lines += [
        f"Read [week {newest['week']} in full]({ARCHIVE_PATH}#{anchor(newest)}), and every earlier "
        f"week, in the [full archive]({ARCHIVE_PATH}).",
        "",
        GALLERY_INVITE,
    ]
    return "\n".join(lines).rstrip() + "\n"


def release_title(week: dict) -> str:
    """The GitHub release title: `Week N · <title>` — no dates, no code-line
    count; those belong to the body, not the tab a release list shows."""
    return f"Week {week['week']} · {week['title']}"


def release_body(week: dict) -> str:
    """A week's full write-up as a standalone GitHub release body: the tile
    row with ABSOLUTE image URLs (a release is read on GitHub's own domain,
    nowhere near this repo's raw files), the three themed sections, the
    highlights, the `codeLines` footer and the gallery invite — everything
    `_body` already renders for the archive, at heading depth 1 since a
    release has no surrounding page to nest under."""
    lines = _body(week, 1, lambda sid: screenshots_mod.IMG_ABSOLUTE.format(id=sid))
    lines += [GALLERY_INVITE]
    return "\n".join(lines).rstrip() + "\n"


def _marker_failure(problem: str) -> SystemExit:
    """Every marker corruption exits the same loud way, naming what to restore.

    Silence here is the expensive failure: a duplicated block renders a SECOND
    "## Release notes" section into the public README, and because `check`
    compares the README against splice_readme(README, …), a splice that only
    touched the first pair would call that drift OK forever.
    """
    return SystemExit(
        f"release-notes: README.md's release-notes markers are {problem} — restore exactly one "
        f"{README_START} … {README_END} pair, in that order, then re-render. A merge that eats, "
        "reverses or duplicates a marker must not silently duplicate the section."
    )


def splice_readme(readme: str, section: str) -> str:
    block = f"{README_START}\n{section}{README_END}\n"
    starts, ends = readme.count(README_START), readme.count(README_END)
    if starts != ends:
        raise _marker_failure(f"unbalanced ({starts} start, {ends} end)")
    if starts > 1:
        raise _marker_failure(f"duplicated ({starts} pairs — the section is in the README more than once)")
    if starts == 1:
        if readme.index(README_START) > readme.index(README_END):
            raise _marker_failure("reversed (the end marker comes before the start marker)")
        head, rest = readme.split(README_START, 1)
        _, tail = rest.split(README_END, 1)
        return head + block + "\n" + tail.lstrip("\n")
    marker = "## Contributing"
    if marker not in readme:
        raise SystemExit("release-notes: README.md has no '## Contributing' heading")
    head, tail = readme.split(marker, 1)
    return head.rstrip("\n") + "\n\n" + block + "\n" + marker + tail

#!/usr/bin/env python3
"""The inline markup release-note prose is allowed to use, and its two renderings.

WHY A RESTRICTED VOCABULARY. The weekly notes are written by a Claude Code pass
(docs/lab/RELEASE-NOTES-PROMPT.md) and land in three places at once: GitHub
markdown, a docs page, and the gallery's own About view. Free-form HTML would
render in one and be sanitised away or, worse, injected in another. So prose may
use exactly four constructs, every one of them validated before it is published:

    [Windows 3.11](station:win311)   a machine the reader can go and use
    **ICQ**                          a product or piece of software
    *AlphaServer ES40*               hardware, chips, eras
    <u>...</u>                       ONE per week, the headline of that week

STATION LINKS ARE WRITTEN AS IDS, NOT URLS, and that is the load-bearing choice
here. The id is checked against registry/stations/ at validation time, so a
machine that does not exist -- or one renamed in a later migration -- fails the
gate instead of publishing a dead link. The id then expands per destination:

    markdown  ->  https://kernelhive.madekivi.fi/os/win311   (absolute; a reader
                  on GitHub is nowhere near the gallery)
    the SPA   ->  /os/win311                                 (relative, so a
                  staged UI at /staging/<session>/ resolves its own copy)

The SPA is handed the RAW markup in release-notes.json and does its own
expansion -- see spa/src/ui/releaseNotesMarkup.ts. That is deliberate: one
source string, two destinations, and no HTML crosses the wire.

ON THE DOMAIN. AGENTS.md forbids committing a real address, hostname, MAC,
serial or domain. The gallery's public domain is the one carve-out, recorded in
that rule itself -- these links are meant to be here, and a scrub sweep must not
"fix" them back out. Everything else in that rule still holds.

UNDERLINE IS RATIONED ON PURPOSE. Underlined text that is not a link reads as a
broken link, and in the About view the station names really are links. One
underline per week keeps it meaning "this is the thing that happened this week"
instead of decaying into decoration, so the limit is enforced, not advised.
"""

from __future__ import annotations

import re
from pathlib import Path

GALLERY = "https://kernelhive.madekivi.fi"
STATION_LINK_RE = re.compile(r"\[([^\]\n]+)\]\(station:([a-z0-9]+)\)")
UNDERLINE_RE = re.compile(r"<u>(.+?)</u>", re.S)
# A `[text](...)` whose target is not a station: the only link form we publish is
# a station link, so anything else is a mistake we would otherwise ship silently.
FOREIGN_LINK_RE = re.compile(r"\[[^\]\n]+\]\((?!station:)[^)\n]*\)")
UNDERLINES_PER_WEEK = 1


def station_ids(repo: Path) -> frozenset[str]:
    """Every station id the gallery can actually serve, from the registry itself.

    Read live rather than hardcoded, so a station added next month is linkable
    the same day and one removed stops validating -- the same reason the rest of
    this repo derives station facts from registry/stations/ instead of a list.
    """
    return frozenset(path.stem for path in (repo / "registry" / "stations").glob("*.json"))


def plain_text(text: str) -> str:
    """The prose with every marker removed -- what a reader actually reads.

    Word budgets are about how much someone has to READ, so they are counted on
    this. Counting the raw string instead would let a paragraph thick with links
    and emphasis claim a third more words than it says, and the 300-400 band
    would stop meaning anything.
    """
    text = STATION_LINK_RE.sub(r"\1", text)
    text = UNDERLINE_RE.sub(r"\1", text)
    return text.replace("**", "").replace("*", "")


def word_count(text: str) -> int:
    return len(plain_text(text).split())


def markup_errors(text: str, stations: frozenset[str], where: str) -> list[str]:
    """One message per breach, naming `where` so a failure points at a field."""
    errors = []
    for _, station in STATION_LINK_RE.findall(text):
        if station not in stations:
            errors.append(f"{where}: no station `{station}` in registry/stations/ — the link would 404")
    for foreign in FOREIGN_LINK_RE.findall(text):
        errors.append(f"{where}: `{foreign}` is not a station link — the only link form is [text](station:<id>)")
    if text.count("<u>") != text.count("</u>"):
        errors.append(f"{where}: unbalanced <u> ... </u>")
    if text.count("**") % 2:
        errors.append(f"{where}: unbalanced ** ... **")
    # Any other tag would be sanitised away on GitHub and would have to be
    # escaped in the SPA, so it never reaches a reader either way: reject it
    # here, where the message can say so, rather than let it vanish downstream.
    for tag in re.findall(r"</?([a-zA-Z][a-zA-Z0-9]*)[^>]*>", text):
        if tag.lower() != "u":
            errors.append(f"{where}: <{tag}> is not allowed — the vocabulary is station links, **bold**, *italic*, <u>")
    return errors


def underline_count(texts: list[str]) -> int:
    return sum(len(UNDERLINE_RE.findall(text)) for text in texts)


def to_markdown(text: str) -> str:
    """Render for GitHub: absolute station URLs, `<u>` kept, stray `<` escaped.

    The escaping is the same problem the archive always had -- `<session>` and
    friends parse as raw inline HTML and GitHub's sanitiser then deletes them,
    so the placeholder silently disappears from the line. Our own `<u>` has to
    survive that, so it is lifted out first and put back afterwards rather than
    being matched around, which is what makes this safe on a line whose other
    angle brackets do not pair up.
    """
    text = STATION_LINK_RE.sub(lambda m: f"[{m.group(1)}]({GALLERY}/os/{m.group(2)})", text)
    kept: list[str] = []

    def park(match: re.Match[str]) -> str:
        kept.append(match.group(0))
        return f"\x00{len(kept) - 1}\x00"

    text = re.sub(r"</?u>", park, text)
    # Code spans are left alone: a backslash inside one renders as a backslash.
    parts = re.split(r"(`+[^`]*`+)", text)
    text = "".join(part if index % 2 else part.replace("<", r"\<") for index, part in enumerate(parts))
    return re.sub(r"\x00(\d+)\x00", lambda m: kept[int(m.group(1))], text)

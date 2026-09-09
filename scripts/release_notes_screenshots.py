#!/usr/bin/env python3
"""The per-week "tiled screenshots" section: which stations, and how the tile
grid renders in each of the three destinations.

WHICH STATIONS. By default the tile row is derived straight from the week's
own prose: every `[name](station:<id>)` link, in the order it first appears —
the summary sections in their fixed order (`New stations` first, since that is
already how the schema orders `summary`), then the bullets — de-duplicated and
capped at `CAP`. An author can override the whole thing with an explicit
`"screenshots": ["id", ...]` array in the week's JSON (validated the same way a
station link is: it must name a real station), which is useful when the prose
mentions more machines than are worth a tile, or when the best frame for the
week belongs to a station the prose never names.

THREE IMAGE PATHS, ONE ID. Every station's own capture lives at
`spa/public/posters/<id>/desktop.webp` (own captures only — never a `gallery/`
photo). Each destination needs that path spelled differently:

    README.md                  spa/public/posters/<id>/desktop.webp   (repo-root relative)
    docs/RELEASE-NOTES.md      ../spa/public/posters/<id>/desktop.webp (docs/-relative)
    a GitHub release body      https://raw.githubusercontent.com/Wnt/kernel-hive/main/spa/public/posters/<id>/desktop.webp

so the table renderer below takes the path as a function of the id rather than
hardcoding one.
"""

from __future__ import annotations

from typing import Callable

import release_notes_markup as markup_mod

CAP = 8
PER_ROW = 4

IMG_README = "spa/public/posters/{id}/desktop.webp"
IMG_ARCHIVE = "../spa/public/posters/{id}/desktop.webp"
IMG_ABSOLUTE = "https://raw.githubusercontent.com/Wnt/kernel-hive/main/spa/public/posters/{id}/desktop.webp"


def derive(doc: dict) -> list[str]:
    """The default tile list: station ids linked in the week's own prose, in
    order of first appearance, `summary` sections first (already ordered
    `New stations` first by the schema) and the bullets after, de-duplicated
    and capped at `CAP`."""
    texts = [s["text"] for s in doc.get("summary", []) if isinstance(s, dict) and isinstance(s.get("text"), str)]
    texts += [b for b in doc.get("bullets", []) if isinstance(b, str)]
    seen: list[str] = []
    for text in texts:
        for _, station in markup_mod.STATION_LINK_RE.findall(text):
            if station not in seen:
                seen.append(station)
    return seen[:CAP]


def resolve(doc: dict) -> list[str]:
    """The tile list that actually publishes: an authored override if the week
    gave one, otherwise the derived default."""
    override = doc.get("screenshots")
    if isinstance(override, list):
        return list(override)
    return derive(doc)


def table(items: list[dict], img: Callable[[str], str]) -> list[str]:
    """A raw-HTML `<table>` of thumbnails, `PER_ROW` per row.

    `items` is `[{"id": ..., "name": ...}, ...]` — the same shape the JSON
    output carries, so the SPA, the two markdown renderers and a GitHub release
    body all draw the grid from one list. Raw HTML rather than markdown image
    syntax because a `<table>` is the only way to lay four thumbnails per row
    in plain markdown, and GitHub, mkdocs-style renderers and the SPA's own
    `<Markup>` all leave inline HTML alone or ignore it (the SPA never sees
    this — see release_notes_screenshots's use in the SPA build path).
    """
    if not items:
        return []
    lines = ["<table>"]
    for start in range(0, len(items), PER_ROW):
        lines.append("<tr>")
        for item in items[start : start + PER_ROW]:
            station, name = item["id"], item["name"]
            lines.append(
                f'<td><a href="{markup_mod.GALLERY}/os/{station}">'
                f'<img src="{img(station)}" width="200" alt="{name}"></a>'
                f"<br><sub>{name}</sub></td>"
            )
        lines.append("</tr>")
    lines.append("</table>")
    return lines

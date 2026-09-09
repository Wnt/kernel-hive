"""Pure logic for scripts/readme-media.py: selection, grouping and the lineup
markdown/HTML — no Pillow, no filesystem writes, so it is unit-testable
without rendering an image.

The registry (`registry/stations/*.json`) is the ONLY source of truth for
names, years, families and lifecycle; nothing here is hand-maintained. A
station's screenshot always lives at `spa/public/posters/<id>/desktop.webp`
(own captures) — never anything under `.../gallery/` (third-party licensed
photos, AGENTS.md rule 1's neighbour concern).
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from stations_registry.loading import load  # noqa: E402  (after sys.path preamble)

README_START = "<!-- lineup:start -->"
README_END = "<!-- lineup:end -->"
GALLERY_BASE = "https://kernelhive.madekivi.fi/os"
POSTER_REL = "spa/public/posters/{id}/desktop.webp"

# Hero mosaic (20 tiles): a CURATED list, chosen by eye from a contact sheet
# of every desktop.webp — the frames that read as "computer museum" at
# thumbnail size (colour, a recognisable desktop, something on screen). An
# evenly-spaced-by-year pick was tried first and chose blank white and
# near-empty frames; visual weight cannot be derived from the registry. Every
# id here that exists in the registry is used, in this order; only if one is
# missing does an evenly-year-spaced fill top the count up. Re-curate when a
# station's poster is recaptured or a stronger machine lands.
HERO_REQUIRED_IDS = (
    "apple2",
    "amstradcpc",
    "vic20",
    "atari800xl",
    "msdoswin1",
    "win311",
    "os2warp",
    "win95",
    "nextstep",
    "irix",
    "hpuxvue",
    "aix432",
    "amix",
    "beos",
    "chokanji",
    "macos9",
    "winxp",
    "haiku",
    "openvms",
    "bootos",
)

# Social preview (18 tiles): the hero list minus the two text-mode 8-bit
# frames, which are illegible at the 1280x640 card size.
PREVIEW_OMIT_IDS = ("vic20", "atari800xl")

HERO_COUNT = 20
PREVIEW_COUNT = 18

DECADE_BUCKETS = (
    (1970, 1979, "1970s"),
    (1980, 1989, "1980s"),
    (1990, 1999, "1990s"),
    (2000, 2009, "2000s"),
    (2010, 2099, "2010s–2020s"),
)


def load_rows() -> list[dict[str, Any]]:
    _globals, rows = load()
    return rows


def station_name(row: dict[str, Any]) -> str:
    return row.get("museum", {}).get("displayName") or row["id"]


def station_year(row: dict[str, Any]) -> int | None:
    year = row.get("museum", {}).get("year")
    if year is None:
        year = row.get("era_year")
    return year


def station_family(row: dict[str, Any]) -> str:
    return row.get("emulator", {}).get("family") or ""


def is_poster(row: dict[str, Any]) -> bool:
    """A showcase entry: a retired backend kept as a static placard, per the
    registry's own `lifecycle` field (not a naming convention on the id)."""
    return row.get("lifecycle") == "showcase"


def is_live(row: dict[str, Any]) -> bool:
    """A streamed, currently-backed station — matches the "streamhost
    production tiles" figure `stations-registry.py count` prints."""
    if row.get("listing", {}).get("state") == "hidden":
        # Deactivated or dark-launched: the gallery does not list it, so a
        # README grid must not link it either (medley, 2026-09-09).
        return False
    return row.get("lifecycle") == "production" and row.get("stream", {}).get("transport") == "streamhost"


def poster_image_path(row: dict[str, Any]) -> Path:
    return REPO_ROOT / POSTER_REL.format(id=row["id"])


def gallery_url(row: dict[str, Any]) -> str:
    return f"{GALLERY_BASE}/{row['id']}"


def live_count(rows: list[dict[str, Any]]) -> int:
    return sum(1 for r in rows if is_live(r))


def year_span(rows: list[dict[str, Any]]) -> tuple[int, int]:
    """The registry's own min/max year, computed fresh every render — never
    hardcoded, so a new station at either edge moves the printed span for
    free instead of silently going stale."""
    years = [station_year(r) for r in rows if station_year(r) is not None]
    if not years:
        raise ValueError("no station in the registry carries a year")
    return min(years), max(years)


def _sort_key(row: dict[str, Any]) -> tuple[int, str]:
    year = station_year(row)
    return (year if year is not None else 0, row["id"])


def _pick_evenly(seq: list[dict[str, Any]], n: int) -> list[dict[str, Any]]:
    """Deterministic evenly-spaced sample of `n` items from `seq` (already
    sorted). Same idea as a reservoir over indices `0..len-1`, not random —
    the same registry always produces the same picks."""
    if n <= 0 or not seq:
        return []
    if n >= len(seq):
        return list(seq)
    step = len(seq) / n
    idxs: list[int] = []
    seen: set[int] = set()
    for i in range(n):
        idx = min(int(i * step), len(seq) - 1)
        while idx in seen and idx < len(seq) - 1:
            idx += 1
        seen.add(idx)
        idxs.append(idx)
    idxs = sorted(seen)
    # Rounding can leave the sample short by a handful of collisions — top up
    # from the front of whatever indices were never picked, in index order,
    # so the result stays deterministic.
    if len(idxs) < n:
        for i in range(len(seq)):
            if i not in seen:
                seen.add(i)
                idxs = sorted(seen)
            if len(idxs) >= n:
                break
    return [seq[i] for i in idxs[:n]]


def select_hero_rows(rows: list[dict[str, Any]], count: int = HERO_COUNT) -> list[dict[str, Any]]:
    """20 (default) rows for the hero mosaic: the hand-picked HERO_REQUIRED_IDS
    that exist in this registry, plus an evenly-year-spaced fill from the rest
    of the LIVE stations, sorted (year, id) for a stable, deterministic mosaic."""
    live = sorted((r for r in rows if is_live(r)), key=_sort_key)
    required = [r for r in live if r["id"] in HERO_REQUIRED_IDS]
    required_ids = {r["id"] for r in required}
    remaining = [r for r in live if r["id"] not in required_ids]
    fill = _pick_evenly(remaining, max(0, count - len(required)))
    chosen = required + fill
    return sorted(chosen, key=_sort_key)[:count]


def select_preview_rows(rows: list[dict[str, Any]], count: int = PREVIEW_COUNT) -> list[dict[str, Any]]:
    """18 (default) rows for the social-preview mosaic: the curated hero list
    minus PREVIEW_OMIT_IDS, topped up from the hero fill if short."""
    hero = select_hero_rows(rows, count=count + len(PREVIEW_OMIT_IDS))
    kept = [r for r in hero if r["id"] not in PREVIEW_OMIT_IDS]
    return kept[:count]


def decade_for(year: int) -> str:
    for lo, hi, label in DECADE_BUCKETS:
        if lo <= year <= hi:
            return label
    return DECADE_BUCKETS[-1][2]


def group_by_decade(rows: list[dict[str, Any]]) -> list[tuple[str, list[dict[str, Any]]]]:
    """Live stations only, grouped into the fixed DECADE_BUCKETS order (a
    decade with no station is simply absent), each group sorted by year then
    name for a stable render."""
    live = [r for r in rows if is_live(r) and station_year(r) is not None]
    buckets: dict[str, list[dict[str, Any]]] = {}
    for row in live:
        label = decade_for(station_year(row))
        buckets.setdefault(label, []).append(row)
    ordered: list[tuple[str, list[dict[str, Any]]]] = []
    for _lo, _hi, label in DECADE_BUCKETS:
        if label in buckets:
            ordered.append((label, sorted(buckets[label], key=_sort_key)))
    return ordered


def _thumb_cell(row: dict[str, Any]) -> str:
    name = station_name(row)
    year = station_year(row)
    caption = f"{name} · {year}" if year is not None else name
    img_src = POSTER_REL.format(id=row["id"])
    return (
        '<td align="center">'
        f'<a href="{gallery_url(row)}"><img src="{img_src}" width="150" alt="{name}"></a>'
        f"<br><sub>{caption}</sub>"
        "</td>"
    )


def _thumb_table(group_rows: list[dict[str, Any]], per_row: int = 6) -> str:
    lines = ["<table>"]
    for start in range(0, len(group_rows), per_row):
        chunk = group_rows[start : start + per_row]
        lines.append("<tr>")
        lines.extend(_thumb_cell(r) for r in chunk)
        lines.append("</tr>")
    lines.append("</table>")
    return "\n".join(lines)


def render_lineup_html(rows: list[dict[str, Any]]) -> str:
    """The full lineup grid body (between, not including, the markers): one
    section per decade, live stations only (showcase posters with retired
    backends are left out), 6 thumbnails per row."""
    parts: list[str] = []
    for label, group_rows in group_by_decade(rows):
        parts.append(f"### {label}\n")
        parts.append(_thumb_table(group_rows))
        parts.append("")
    # Showcase posters (retired backends) are deliberately NOT listed: the
    # operator wants the grid to show only machines a visitor can drive.
    return "\n".join(parts).rstrip("\n") + "\n"


def render_lineup_block(rows: list[dict[str, Any]]) -> str:
    return f"{README_START}\n{render_lineup_html(rows)}{README_END}\n"


class MarkerError(Exception):
    pass


def splice_readme(readme: str, block: str) -> str:
    """Replace the content between the lineup markers with `block` (which
    already includes the markers themselves). If the markers are absent,
    insert right after the first paragraph following the H1 — the "## ..."
    heading search that release_notes_render.py uses doesn't apply here
    because this repo's README structure around the lineup is still being
    written in parallel; inserting after paragraph 1 keeps this script from
    fighting that edit."""
    starts, ends = readme.count(README_START), readme.count(README_END)
    if starts != ends:
        raise MarkerError(f"lineup markers unbalanced ({starts} start, {ends} end)")
    if starts > 1:
        raise MarkerError(f"lineup markers duplicated ({starts} pairs)")
    if starts == 1:
        if readme.index(README_START) > readme.index(README_END):
            raise MarkerError("lineup markers reversed (end before start)")
        head, rest = readme.split(README_START, 1)
        _old, tail = rest.split(README_END, 1)
        return head + block + tail
    # No markers yet: insert after the first blank line that follows the H1's
    # first paragraph.
    lines = readme.splitlines(keepends=True)
    if not lines or not lines[0].startswith("# "):
        raise MarkerError("README.md has no H1 on line 1")
    # Skip the H1's own blank line(s), then the first paragraph's non-blank
    # lines, then insert after the blank line that ends that paragraph — i.e.
    # right after the first H1 *paragraph*, not right after the H1 itself.
    i = 1
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    while i < len(lines) and lines[i].strip() != "":
        i += 1
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    insert_at = i
    if insert_at >= len(lines):
        raise MarkerError("README.md has no content after the first H1 paragraph")
    return "".join(lines[:insert_at]) + block + "\n" + "".join(lines[insert_at:])


def extract_lineup_block(readme: str) -> str | None:
    starts, ends = readme.count(README_START), readme.count(README_END)
    if starts != 1 or ends != 1:
        return None
    if readme.index(README_START) > readme.index(README_END):
        return None
    _head, rest = readme.split(README_START, 1)
    body, _tail = rest.split(README_END, 1)
    return f"{README_START}{body}{README_END}\n"

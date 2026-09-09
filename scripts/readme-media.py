#!/usr/bin/env python3
"""Generate the GitHub README's hero images and lineup grid from the station
registry, in one place, so none of it can go stale by hand-editing.

WHY ONE SCRIPT. The three outputs below all read the exact same registry rows
(`registry/stations/*.json` via `scripts/stations_registry.loading.load`) and
the exact same screenshots (`spa/public/posters/<id>/desktop.webp` — own
captures; never anything under `.../gallery/`, which is third-party licensed
photography). A hand-maintained lineup table or a hand-picked hero mosaic
drifts the moment a station is added, renamed or retired; this script cannot,
because `render` is the only thing that ever writes these files.

    docs/media/hero.webp            20-tile mosaic, 5x4, 1600px wide
    docs/media/social-preview.png   1280x640 GitHub social-preview mosaic,
                                     with the live station count and the
                                     registry's own year span baked in
    README.md (lineup:start/end)    the full lineup grid, grouped by decade,
                                     with a trailing "Placards" row for the
                                     two showcase posters (retired backends)

`check` re-renders the markdown/HTML in memory and fails if README.md's
marked block differs, and fails if either image file is missing. It does NOT
demand byte-identical images — Pillow's webp/png encoders make no such
promise across versions, so pinning to that would gate on the wrong thing.

Usage:
    python3 scripts/readme-media.py render
    python3 scripts/readme-media.py check
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont

import readme_media_lib as lib

REPO_ROOT = Path(__file__).resolve().parents[1]
README_PATH = REPO_ROOT / "README.md"
MEDIA_DIR = REPO_ROOT / "docs" / "media"
HERO_PATH = MEDIA_DIR / "hero.webp"
PREVIEW_PATH = MEDIA_DIR / "social-preview.png"

GUTTER_COLOR = (12, 12, 15)
BAND_COLOR = (10, 10, 14)
TEXT_COLOR = (235, 235, 235)
SUB_TEXT_COLOR = (170, 170, 178)
CELL_ASPECT = 3 / 4  # height / width, i.e. a 4:3-ish landscape screenshot

ACCENT_COLOR = (255, 196, 120)
SAFE_MARGIN = 80  # GitHub's card template: nothing important inside this frame
SUPERSAMPLE = 3

# Inter (SIL OFL 1.1, docs/media/fonts/LICENSE.txt) — the sans GitHub's own
# card uses a cousin of; DejaVu is the fallback when the files are missing.
FONT_DIR = REPO_ROOT / "docs" / "media" / "fonts"
FONT_BOLD = str(FONT_DIR / "Inter-Bold.ttf")
FONT_SEMIBOLD = str(FONT_DIR / "Inter-SemiBold.ttf")
FONT_REGULAR = str(FONT_DIR / "Inter-Regular.ttf")
DEJAVU_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
DEJAVU_REGULAR = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def _font(path: str, size: int) -> ImageFont.FreeTypeFont:
    for candidate in (path, DEJAVU_BOLD if "Bold" in path else DEJAVU_REGULAR):
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            continue
    return ImageFont.load_default(size)


def _cover_crop(im: Image.Image, cell_w: int, cell_h: int) -> Image.Image:
    """Resize+center-crop `im` to fill exactly cell_w x cell_h (a "cover" fit,
    never letterboxed) so every mosaic tile is visually uniform regardless of
    the source screenshot's own aspect ratio (they range from 4:3 to
    portrait)."""
    src_w, src_h = im.size
    target_ratio = cell_w / cell_h
    src_ratio = src_w / src_h
    if src_ratio > target_ratio:
        # Source is wider than the cell: crop the sides.
        new_w = int(src_h * target_ratio)
        x0 = (src_w - new_w) // 2
        im = im.crop((x0, 0, x0 + new_w, src_h))
    else:
        new_h = int(src_w / target_ratio)
        y0 = (src_h - new_h) // 2
        im = im.crop((0, y0, src_w, y0 + new_h))
    return im.resize((cell_w, cell_h), Image.LANCZOS)


def build_mosaic(
    rows: list[dict[str, Any]],
    cols: int,
    grid_rows: int,
    width: int,
    height: int,
    gutter: int = 6,
) -> Image.Image:
    """A cols x grid_rows grid of cover-cropped screenshots on a dark gutter,
    exactly width x height pixels."""
    canvas = Image.new("RGB", (width, height), GUTTER_COLOR)
    cell_w = (width - gutter * (cols + 1)) // cols
    cell_h = (height - gutter * (grid_rows + 1)) // grid_rows
    n = cols * grid_rows
    tiles = rows[:n]
    for i, row in enumerate(tiles):
        r, c = divmod(i, cols)
        if r >= grid_rows:
            break
        x = gutter + c * (cell_w + gutter)
        y = gutter + r * (cell_h + gutter)
        with Image.open(lib.poster_image_path(row)) as src:
            tile = _cover_crop(src.convert("RGB"), cell_w, cell_h)
        canvas.paste(tile, (x, y))
    return canvas


def render_hero(rows: list[dict[str, Any]]) -> Image.Image:
    chosen = lib.select_hero_rows(rows, lib.HERO_COUNT)
    return build_mosaic(chosen, cols=5, grid_rows=4, width=1600, height=960, gutter=6)


def _band_text(width: int, height: int, title: str, subtitle: str, footer: str, x0: int) -> Image.Image:
    """The card's text band, rendered at SUPERSAMPLE x and downscaled once with
    LANCZOS: FreeType at 1x on a dark ground hints glyphs to the pixel grid and
    the result reads as jagged at card size; supersampling gives clean
    anti-aliased stems. Text sits at x0 = the template's safe margin."""
    ss = SUPERSAMPLE
    band = Image.new("RGB", (width * ss, height * ss), BAND_COLOR)
    draw = ImageDraw.Draw(band)
    title_font = _font(FONT_BOLD, 42 * ss)
    sub_font = _font(FONT_REGULAR, 23 * ss)
    foot_font = _font(FONT_SEMIBOLD, 18 * ss)
    # 440 + 14 .. 558: every glyph stays above the template's bottom safe line (560).
    y = 14 * ss
    draw.text((x0 * ss, y), title, font=title_font, fill=TEXT_COLOR)
    y += 54 * ss
    draw.text((x0 * ss, y), subtitle, font=sub_font, fill=SUB_TEXT_COLOR)
    y += 32 * ss
    draw.text((x0 * ss, y), footer, font=foot_font, fill=ACCENT_COLOR)
    return band.resize((width, height), Image.LANCZOS)


def render_social_preview(rows: list[dict[str, Any]]) -> Image.Image:
    """1280x640, GitHub's Open Graph card size (docs/media/
    repository-open-graph-template.png is GitHub's own template: an 80 px
    frame on every side is the crop-safe zone, so all text starts at x=80 and
    ends above y=560). The mosaic is built ONCE at final size — each tile is a
    single LANCZOS pass from the source screenshot, never resized twice — and
    only the text band is supersampled."""
    chosen = lib.select_preview_rows(rows, lib.PREVIEW_COUNT)
    width, height = 1280, 640
    band_h = 200
    grid_h = height - band_h
    mosaic = build_mosaic(chosen, cols=6, grid_rows=3, width=width, height=grid_h, gutter=4)

    live_n = lib.live_count(rows)
    lo, hi = lib.year_span(rows)
    title = "Kernel Hive"
    subtitle = f"Virtual computer museum streamed into your browser · {live_n} operating systems, {lo}–{hi}"
    footer = "kernelhive.madekivi.fi"

    canvas = Image.new("RGB", (width, height), BAND_COLOR)
    canvas.paste(mosaic, (0, 0))
    canvas.paste(_band_text(width, band_h, title, subtitle, footer, SAFE_MARGIN), (0, grid_h))
    return canvas


def render(rows: list[dict[str, Any]]) -> None:
    MEDIA_DIR.mkdir(parents=True, exist_ok=True)

    hero = render_hero(rows)
    hero.save(HERO_PATH, "WEBP", quality=80, method=6)

    preview = render_social_preview(rows)
    preview.save(PREVIEW_PATH, "PNG", optimize=True)

    block = lib.render_lineup_block(rows)
    readme = README_PATH.read_text()
    README_PATH.write_text(lib.splice_readme(readme, block))

    print(
        f"readme-media: rendered {HERO_PATH.relative_to(REPO_ROOT)} "
        f"({HERO_PATH.stat().st_size} bytes), {PREVIEW_PATH.relative_to(REPO_ROOT)} "
        f"({PREVIEW_PATH.stat().st_size} bytes), and the README lineup grid "
        f"({lib.live_count(rows)} live stations, {lo_hi_str(rows)})."
    )


def lo_hi_str(rows: list[dict[str, Any]]) -> str:
    lo, hi = lib.year_span(rows)
    return f"{lo}–{hi}"


def check(rows: list[dict[str, Any]]) -> int:
    problems: list[str] = []

    if not HERO_PATH.is_file():
        problems.append(f"missing {HERO_PATH.relative_to(REPO_ROOT)} — run `make readme-media`")
    if not PREVIEW_PATH.is_file():
        problems.append(f"missing {PREVIEW_PATH.relative_to(REPO_ROOT)} — run `make readme-media`")

    readme = README_PATH.read_text()
    current = lib.extract_lineup_block(readme)
    if current is None:
        problems.append("README.md lineup markers missing, duplicated or reversed — run `make readme-media`")
    else:
        expected = lib.render_lineup_block(rows)
        if current != expected:
            problems.append("README.md's lineup grid does not match the registry — run `make readme-media` and commit")

    if problems:
        for p in problems:
            print(f"readme-media check: {p}", file=sys.stderr)
        return 1

    print(f"readme-media check: OK ({lib.live_count(rows)} live stations, {lo_hi_str(rows)})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("command", choices=["render", "check"])
    ns = ap.parse_args()

    rows = lib.load_rows()

    if ns.command == "render":
        render(rows)
        return 0
    return check(rows)


if __name__ == "__main__":
    raise SystemExit(main())

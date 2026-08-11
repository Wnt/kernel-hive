"""Parse the registry's constrained poster frontmatter and Markdown subset."""

from __future__ import annotations

import json
import re
from collections import OrderedDict
from pathlib import Path
from typing import Any

POSTER_KEYS = frozenset(("title", "subtitle", "hero", "images"))
IMAGE_KEYS = frozenset(("src", "alt", "caption", "credit"))
SAFE_TARGET = re.compile(r"^(?:https?://|mailto:|/|#)")
HTTP_URL = re.compile(r"^https?://\S+$")

# Poster image gallery (docs/lab/POSTER-GALLERY-SPEC.md). Only the resolved
# file is read here -- candidates are authored/consumed by
# scripts/tools/fetch-poster-gallery.py and never touch this loader.
GALLERY_TOP_KEYS = frozenset(("schemaVersion", "id", "images", "adLinks"))
GALLERY_IMAGE_KEYS = frozenset(
    (
        "src",
        "alt",
        "caption",
        "author",
        "license",
        "licenseId",
        "licenseUrl",
        "shareAlike",
        "sourceUrl",
        "sourceName",
        "sha256",
        "width",
        "height",
    )
)
# PosterGalleryImage in spa/src/types.ts carries every field above minus
# sha256 -- that field is a build-time integrity check only.
# Explicit ORDER, not a set comprehension: this tuple fixes the key order of
# every gallery image emitted into the generated spa/src/data/posters.ts.
# Deriving it by iterating the GALLERY_IMAGE_KEYS frozenset made that order
# depend on the interpreter's per-process hash seed, so two runs of
# `make tile-registry-generate` produced byte-different output and the
# generated-file drift gate failed at random. sha256 is deliberately absent --
# it guards the shipped asset, and the UI type does not carry it.
GALLERY_IMAGE_TS_KEYS = (
    "src",
    "alt",
    "caption",
    "author",
    "license",
    "licenseId",
    "licenseUrl",
    "shareAlike",
    "sourceUrl",
    "sourceName",
    "width",
    "height",
)
GALLERY_IMAGE_STRING_KEYS = (
    "src",
    "alt",
    "caption",
    "author",
    "license",
    "licenseId",
    "licenseUrl",
    "sourceUrl",
    "sourceName",
    "sha256",
)
AD_LINK_KEYS = frozenset(("title", "url", "source"))

# docs/lab/POSTER-GALLERY-SPEC.md "Licensing policy": the mechanical allowlist.
# Anything else -- including any value containing nc/nd/fairuse/nonfree -- is a
# hard failure, never a warning.
ALLOWED_LICENSE_IDS = frozenset(
    (
        "pd",
        "cc0",
        "cc-by-2.0",
        "cc-by-2.5",
        "cc-by-3.0",
        "cc-by-4.0",
        "cc-by-sa-2.0",
        "cc-by-sa-2.5",
        "cc-by-sa-3.0",
        "cc-by-sa-4.0",
    )
)


class PosterError(Exception):
    """An authored poster does not conform to the locked format."""


def _scalar(raw: str, where: str) -> str:
    value = raw.strip()
    if not value:
        raise PosterError(f"{where}: value must not be empty")
    if value[:1] in {"'", '"'}:
        try:
            parsed = json.loads(value) if value.startswith('"') else value[1:-1]
        except json.JSONDecodeError as exc:
            raise PosterError(f"{where}: malformed quoted string") from exc
        if not isinstance(parsed, str):
            raise PosterError(f"{where}: expected a string")
        return parsed
    return value


def _field(line: str, where: str) -> tuple[str, str]:
    if ":" not in line:
        raise PosterError(f"{where}: expected key: value")
    key, raw = line.split(":", 1)
    return key.strip(), _scalar(raw, where)


def parse_frontmatter(text: str, path: Path) -> tuple[dict[str, Any], str]:
    """Read the deliberately small YAML subset used by poster documents."""
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        raise PosterError(f"{path}: first line must be ---")
    try:
        closing = lines.index("---", 1)
    except ValueError as exc:
        raise PosterError(f"{path}: missing closing ---") from exc

    front: OrderedDict[str, Any] = OrderedDict()
    images: list[OrderedDict[str, str]] = []
    index = 1
    while index < closing:
        line = lines[index]
        where = f"{path}:{index + 1}"
        if not line.strip():
            index += 1
            continue
        if line.startswith((" ", "\t")):
            raise PosterError(f"{where}: unexpected indentation")
        if line == "images:":
            index += 1
            while index < closing and (not lines[index].strip() or lines[index].startswith("  ")):
                item_line = lines[index]
                item_where = f"{path}:{index + 1}"
                if not item_line.strip():
                    index += 1
                    continue
                if not item_line.startswith("  - "):
                    raise PosterError(f"{item_where}: image entries must begin with two spaces and '- '")
                key, value = _field(item_line[4:], item_where)
                image: OrderedDict[str, str] = OrderedDict(((key, value),))
                index += 1
                while index < closing and lines[index].startswith("    "):
                    child_where = f"{path}:{index + 1}"
                    child_key, child_value = _field(lines[index].strip(), child_where)
                    if child_key in image:
                        raise PosterError(f"{child_where}: duplicate image field {child_key}")
                    image[child_key] = child_value
                    index += 1
                images.append(image)
            front["images"] = images
            continue
        key, value = _field(line, where)
        if key in front:
            raise PosterError(f"{where}: duplicate frontmatter field {key}")
        front[key] = value
        index += 1

    unknown = set(front) - POSTER_KEYS
    if unknown:
        raise PosterError(f"{path}: unsupported frontmatter fields: {sorted(unknown)}")
    for required in ("title", "subtitle"):
        if required not in front:
            raise PosterError(f"{path}: missing required frontmatter field {required}")
    front.setdefault("images", [])
    if "hero" in front:
        _validate_image_src(front["hero"], f"{path}:hero")
    for number, image in enumerate(front["images"], 1):
        unknown_image = set(image) - IMAGE_KEYS
        if unknown_image:
            raise PosterError(f"{path}: image {number} has unsupported fields: {sorted(unknown_image)}")
        missing = {"src", "alt", "caption"} - set(image)
        if missing:
            raise PosterError(f"{path}: image {number} missing fields: {sorted(missing)}")
        _validate_image_src(image["src"], f"{path}:image {number}")
    return front, "\n".join(lines[closing + 1 :]).strip()


def _validate_image_src(src: str, where: str) -> None:
    if not src.startswith("/posters/") or not re.fullmatch(r"/[A-Za-z0-9_./-]+", src):
        raise PosterError(f"{where}: image paths must be safe same-origin /posters/... paths")


def _validate_gallery_src(src: str, tile_id: str, where: str) -> None:
    prefix = f"/posters/{tile_id}/gallery/"
    if not src.startswith(prefix) or not re.fullmatch(r"/[A-Za-z0-9_./-]+", src):
        raise PosterError(f"{where}: image src must be a safe {prefix}... path")


def _validate_http_url(url: str, where: str, field: str) -> None:
    if not HTTP_URL.match(url):
        raise PosterError(f"{where}: {field} must be an http(s) URL")


def _gallery_image(raw: Any, number: int, tile_id: str, path: Path) -> OrderedDict[str, Any]:
    where = f"{path}: image {number}"
    if not isinstance(raw, dict):
        raise PosterError(f"{where}: must be an object")
    missing = GALLERY_IMAGE_KEYS - set(raw)
    if missing:
        raise PosterError(f"{where}: missing fields: {sorted(missing)}")
    unknown = set(raw) - GALLERY_IMAGE_KEYS
    if unknown:
        raise PosterError(f"{where}: unsupported fields: {sorted(unknown)}")
    for key in GALLERY_IMAGE_STRING_KEYS:
        if not isinstance(raw[key], str) or not raw[key].strip():
            raise PosterError(f"{where}: {key} must be a non-empty string")
    if not isinstance(raw["shareAlike"], bool):
        raise PosterError(f"{where}: shareAlike must be a boolean")
    for key in ("width", "height"):
        value = raw[key]
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise PosterError(f"{where}: {key} must be a positive integer")
    if raw["licenseId"] not in ALLOWED_LICENSE_IDS:
        raise PosterError(f"{where}: licenseId {raw['licenseId']!r} is not an allowed free license")
    _validate_gallery_src(raw["src"], tile_id, where)
    _validate_http_url(raw["licenseUrl"], where, "licenseUrl")
    _validate_http_url(raw["sourceUrl"], where, "sourceUrl")
    if not re.fullmatch(r"[0-9a-f]{64}", raw["sha256"]):
        raise PosterError(f"{where}: sha256 must be a 64-character lowercase hex digest")
    return OrderedDict((key, raw[key]) for key in GALLERY_IMAGE_TS_KEYS)


def _gallery_ad_link(raw: Any, number: int, path: Path) -> OrderedDict[str, Any]:
    where = f"{path}: adLinks[{number}]"
    if not isinstance(raw, dict):
        raise PosterError(f"{where}: must be an object")
    missing = AD_LINK_KEYS - set(raw)
    if missing:
        raise PosterError(f"{where}: missing fields: {sorted(missing)}")
    unknown = set(raw) - AD_LINK_KEYS
    if unknown:
        raise PosterError(f"{where}: unsupported fields: {sorted(unknown)}")
    for key in AD_LINK_KEYS:
        if not isinstance(raw[key], str) or not raw[key].strip():
            raise PosterError(f"{where}: {key} must be a non-empty string")
    _validate_http_url(raw["url"], where, "url")
    return OrderedDict((key, raw[key]) for key in ("title", "url", "source"))


def load_gallery(path: Path, tile_id: str) -> OrderedDict[str, Any] | None:
    """Load+validate `<id>.resolved.json`; absent file is the normal case.

    A malformed or non-free entry is a hard load error, never a warning --
    nothing else authors this file, so drift here means the generator that
    wrote it (or a hand edit) broke the contract.
    """
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise PosterError(f"{path}: invalid JSON") from exc
    if not isinstance(data, dict):
        raise PosterError(f"{path}: must be a JSON object")
    unknown = set(data) - GALLERY_TOP_KEYS
    if unknown:
        raise PosterError(f"{path}: unsupported fields: {sorted(unknown)}")
    if data.get("schemaVersion") != 1:
        raise PosterError(f"{path}: schemaVersion must be 1")
    if data.get("id") != tile_id:
        raise PosterError(f"{path}: id {data.get('id')!r} does not match tile {tile_id!r}")

    raw_images = data.get("images")
    if not isinstance(raw_images, list) or not raw_images:
        raise PosterError(f"{path}: images must be a non-empty list")
    images = [_gallery_image(image, number, tile_id, path) for number, image in enumerate(raw_images, 1)]

    gallery: OrderedDict[str, Any] = OrderedDict((("images", images),))
    if "adLinks" in data:
        raw_ads = data["adLinks"]
        if not isinstance(raw_ads, list):
            raise PosterError(f"{path}: adLinks must be a list")
        if len(raw_ads) > 2:
            raise PosterError(f"{path}: adLinks allows at most 2 entries")
        ad_links = [_gallery_ad_link(ad, number, path) for number, ad in enumerate(raw_ads, 1)]
        if ad_links:
            gallery["adLinks"] = ad_links
    return gallery


def parse_inline(text: str, where: str) -> list[dict[str, Any]]:
    """Parse text, emphasis, strong emphasis, and safe links into typed runs."""
    runs: list[dict[str, Any]] = []
    plain: list[str] = []

    def flush() -> None:
        if plain:
            runs.append({"kind": "text", "text": "".join(plain)})
            plain.clear()

    index = 0
    while index < len(text):
        link = re.match(r"\[([^\]]+)\]\(([^)]+)\)", text[index:])
        if link:
            target = link.group(2)
            if not SAFE_TARGET.match(target):
                raise PosterError(f"{where}: unsafe link target {target!r}")
            flush()
            runs.append({"kind": "link", "href": target, "children": parse_inline(link.group(1), where)})
            index += link.end()
            continue
        if text.startswith("**", index):
            end = text.find("**", index + 2)
            if end >= 0:
                flush()
                runs.append({"kind": "strong", "children": parse_inline(text[index + 2 : end], where)})
                index = end + 2
                continue
        if text[index] == "*":
            end = text.find("*", index + 1)
            if end >= 0:
                flush()
                runs.append({"kind": "emphasis", "children": parse_inline(text[index + 1 : end], where)})
                index = end + 1
                continue
        plain.append(text[index])
        index += 1
    flush()
    return runs


def parse_markdown(body: str, path: Path) -> list[dict[str, Any]]:
    """Turn the supported block Markdown subset into a renderer-safe union."""
    lines = body.splitlines()
    blocks: list[dict[str, Any]] = []
    paragraph: list[str] = []
    bullets: list[str] = []

    def flush_paragraph() -> None:
        if paragraph:
            text = " ".join(line.strip() for line in paragraph)
            blocks.append({"kind": "paragraph", "runs": parse_inline(text, str(path))})
            paragraph.clear()

    def flush_bullets() -> None:
        if bullets:
            blocks.append({"kind": "list", "items": [parse_inline(item, str(path)) for item in bullets]})
            bullets.clear()

    for number, line in enumerate(lines, 1):
        where = f"{path}:{number}"
        if not line.strip():
            flush_paragraph()
            flush_bullets()
            continue
        heading = re.fullmatch(r"(##|###) (.+)", line)
        if heading:
            flush_paragraph()
            flush_bullets()
            blocks.append(
                {
                    "kind": "heading",
                    "level": len(heading.group(1)),
                    "runs": parse_inline(heading.group(2), where),
                }
            )
            continue
        if line.startswith("- "):
            flush_paragraph()
            bullets.append(line[2:].strip())
            continue
        if line.startswith("> "):
            flush_paragraph()
            flush_bullets()
            blocks.append({"kind": "quote", "runs": parse_inline(line[2:].strip(), where)})
            continue
        image = re.fullmatch(r"!\[([^\]]*)\]\(([^)]+)\)", line)
        if image:
            flush_paragraph()
            flush_bullets()
            _validate_image_src(image.group(2), where)
            blocks.append({"kind": "image", "src": image.group(2), "alt": image.group(1)})
            continue
        # Reject stray Markdown this renderer does not implement -- but a
        # paragraph may legitimately OPEN with a bold run ("**Log in as root.**
        # ..."), which parse_inline already handles. Only a real list bullet
        # ("- ", "* ", "+ "), a blockquote (">") or a heading ("#") is an error,
        # so "**" is matched before the bullet rule.
        if line.startswith("#") or (not line.startswith("**") and re.match(r"\s*([-*+]|>)", line)):
            raise PosterError(f"{where}: unsupported Markdown syntax")
        paragraph.append(line)
    flush_paragraph()
    flush_bullets()
    if not blocks:
        raise PosterError(f"{path}: poster body must not be empty")
    return blocks


def load_posters(directory: Path, tile_ids: set[str]) -> tuple[OrderedDict[str, dict[str, Any]], list[str]]:
    """Load matching sibling documents and return non-fatal orphan warnings."""
    posters: OrderedDict[str, dict[str, Any]] = OrderedDict()
    warnings: list[str] = []
    for path in sorted(directory.glob("*.md")):
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", path.stem):
            raise PosterError(f"{path}: filename must be a valid tile id")
        if path.stem not in tile_ids:
            warnings.append(f"{path}: no matching tile id; skipped")
            continue
        front, body = parse_frontmatter(path.read_text(), path)
        poster = OrderedDict(
            (
                ("title", front["title"]),
                ("subtitle", front["subtitle"]),
            )
        )
        if "hero" in front:
            poster["hero"] = front["hero"]
        poster["images"] = front["images"]
        poster["blocks"] = parse_markdown(body, path)
        gallery = load_gallery(directory / "gallery" / f"{path.stem}.resolved.json", path.stem)
        if gallery is not None:
            poster["gallery"] = gallery
        posters[path.stem] = poster
    return posters, warnings

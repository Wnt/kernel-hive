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
        if line.startswith("#") or re.match(r"\s*[-*>]", line):
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
        posters[path.stem] = poster
    return posters, warnings

#!/usr/bin/env python3
# fetch-poster-gallery.py -- Phase 2 of docs/lab/POSTER-GALLERY-SPEC.md.
#
# Turns registry/posters/gallery/<id>.candidates.json (authored by research
# agents, Phase 3) into the GENERATED, committed pair:
#   registry/posters/gallery/<id>.resolved.json
#   spa/public/posters/<id>/gallery/NN-<slug>.webp
#
# Licensing policy (non-negotiable, see the spec's "Licensing policy"
# section): an image ships ONLY if the Wikimedia Commons API reports one of
# the allowed licenses below. This is a mechanical allowlist check -- never a
# judgement call, never a warning-and-continue. A missing Commons page or a
# license outside the allowlist is a hard failure and nothing is written for
# that station.
#
# Usage:
#   fetch-poster-gallery.py [--tile ID ...]        # fetch + write (default)
#   fetch-poster-gallery.py --verify [--tile ID]   # re-check licenses live,
#                                                   # confirm sha256 + existence
#   fetch-poster-gallery.py --verify --offline     # sha256/existence only,
#                                                   # no network (CI-safe)
#
# Exit status is non-zero on any hard error (fetch mode) or any drift
# (verify mode).
from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
CANDIDATES_DIR = REPO_ROOT / "registry" / "posters" / "gallery"
PUBLIC_POSTERS_DIR = REPO_ROOT / "spa" / "public" / "posters"

API_URL = "https://commons.wikimedia.org/w/api.php"
USER_AGENT = (
    "kernel-hive-poster-gallery/1.0 "
    "(https://github.com/Wnt/kernel-hive; museum poster asset fetcher; "
    "contact via repo issues) Python-urllib/3"
)

REQUEST_TIMEOUT_S = 20
RETRY_ATTEMPTS = 3
RETRY_BACKOFF_S = 1.5

MAX_LONG_EDGE = 1600
TARGET_MAX_BYTES = 200 * 1024
WEBP_QUALITY_STEPS = (82, 75, 68, 60, 50, 40, 30)

# extmetadata.License values allowed by the licensing policy. Every entry
# maps to a human label + a fallback license URL used only when the API
# response itself omits LicenseUrl (common for pd/cc0).
ALLOWED_LICENSES: dict[str, dict[str, str]] = {
    "pd": {
        "label": "Public domain",
        "url": "https://en.wikipedia.org/wiki/Public_domain",
    },
    "cc0": {
        "label": "CC0 1.0",
        "url": "https://creativecommons.org/publicdomain/zero/1.0/",
    },
    "cc-by-2.0": {"label": "CC BY 2.0", "url": "https://creativecommons.org/licenses/by/2.0/"},
    "cc-by-2.5": {"label": "CC BY 2.5", "url": "https://creativecommons.org/licenses/by/2.5/"},
    "cc-by-3.0": {"label": "CC BY 3.0", "url": "https://creativecommons.org/licenses/by/3.0/"},
    "cc-by-4.0": {"label": "CC BY 4.0", "url": "https://creativecommons.org/licenses/by/4.0/"},
    "cc-by-sa-2.0": {"label": "CC BY-SA 2.0", "url": "https://creativecommons.org/licenses/by-sa/2.0/"},
    "cc-by-sa-2.5": {"label": "CC BY-SA 2.5", "url": "https://creativecommons.org/licenses/by-sa/2.5/"},
    "cc-by-sa-3.0": {"label": "CC BY-SA 3.0", "url": "https://creativecommons.org/licenses/by-sa/3.0/"},
    "cc-by-sa-4.0": {"label": "CC BY-SA 4.0", "url": "https://creativecommons.org/licenses/by-sa/4.0/"},
}

SOURCE_URL_PREFIX = "https://commons.wikimedia.org/wiki/"

_HTML_TAG_RE = re.compile(r"<[^>]+>")


class FetchError(Exception):
    """A hard failure that should abort processing of the current tile."""


def eprint(*a: object) -> None:
    print(*a, file=sys.stderr)


def strip_html(value: str) -> str:
    """Collapse a Commons extmetadata HTML fragment to plain text."""
    text = _HTML_TAG_RE.sub("", value)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def slugify(value: str) -> str:
    value = value.lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    return value.strip("-") or "image"


def _urlopen_with_retry(request: urllib.request.Request, *, what: str) -> bytes:
    last_exc: Exception | None = None
    for attempt in range(1, RETRY_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_S) as resp:  # noqa: S310
                return resp.read()
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            last_exc = exc
            if attempt < RETRY_ATTEMPTS:
                eprint(f"  retry {attempt}/{RETRY_ATTEMPTS} for {what}: {exc}")
                time.sleep(RETRY_BACKOFF_S * attempt)
    raise FetchError(f"{what}: request failed after {RETRY_ATTEMPTS} attempts: {last_exc}")


def commons_imageinfo(commons_file: str) -> dict[str, Any]:
    """Query the Commons API for one File: title. Raises FetchError if the
    page does not exist. Returns the raw `pages` entry dict."""
    params = {
        "action": "query",
        "format": "json",
        "prop": "imageinfo",
        "iiprop": "url|size|extmetadata",
        "titles": commons_file,
    }
    url = f"{API_URL}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    body = _urlopen_with_retry(req, what=f"imageinfo for {commons_file}")
    try:
        data = json.loads(body)
    except json.JSONDecodeError as exc:
        raise FetchError(f"{commons_file}: malformed JSON from Commons API") from exc

    pages = data.get("query", {}).get("pages", {})
    if not pages:
        raise FetchError(f"{commons_file}: no page returned by Commons API")
    page = next(iter(pages.values()))
    if page.get("pageid", -1) == -1 or "missing" in page:
        raise FetchError(f"{commons_file}: Commons page does not exist (missing)")
    if "imageinfo" not in page or not page["imageinfo"]:
        raise FetchError(f"{commons_file}: no imageinfo in Commons API response")
    return page["imageinfo"][0]


def resolve_license(commons_file: str, extmetadata: dict[str, Any]) -> dict[str, Any]:
    """Enforce the licensing-policy allowlist. Hard-fails on anything else."""
    license_field = extmetadata.get("License", {}).get("value", "")
    license_id = str(license_field).strip().lower()
    if license_id not in ALLOWED_LICENSES:
        raise FetchError(
            f"{commons_file}: license '{license_id or '(none)'}' is not on the allowlist "
            "-- hard failure, nothing written"
        )
    allowed = ALLOWED_LICENSES[license_id]
    label = extmetadata.get("LicenseShortName", {}).get("value") or allowed["label"]
    license_url = extmetadata.get("LicenseUrl", {}).get("value") or allowed["url"]
    artist_raw = extmetadata.get("Artist", {}).get("value", "")
    artist = strip_html(artist_raw) if artist_raw else "Unknown"
    return {
        "licenseId": license_id,
        "license": label,
        "licenseUrl": license_url,
        "author": artist,
        "shareAlike": license_id.startswith("cc-by-sa-"),
    }


def download_bytes(url: str, *, what: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    return _urlopen_with_retry(req, what=what)


def to_webp(original: bytes, *, what: str, rotate: int = 0) -> tuple[bytes, int, int]:
    """Downscale to MAX_LONG_EDGE, strip metadata, encode WebP under the
    TARGET_MAX_BYTES budget (stepping quality down as needed). Returns
    (webp_bytes, width, height).

    Orientation is BAKED IN before the metadata is dropped. A camera stores a
    portrait shot as landscape pixels plus an EXIF orientation flag; stripping
    the EXIF without first applying that flag leaves the picture lying on its
    side in the browser, which is how several gallery images shipped sideways.
    `rotate` is the manual escape hatch, in degrees clockwise, for sources that
    are sideways on Commons with no EXIF flag to honour.
    """
    from io import BytesIO

    from PIL import Image, ImageOps

    with Image.open(BytesIO(original)) as im:
        im.load()
        im = ImageOps.exif_transpose(im)
        if rotate:
            # Pillow's rotate() is counter-clockwise; `rotate` is clockwise.
            im = im.rotate(-rotate, expand=True)
        if im.mode in ("P", "RGBA", "LA"):
            im = im.convert("RGBA") if "A" in im.mode or im.mode == "P" else im.convert("RGB")
        if im.mode not in ("RGB", "RGBA"):
            im = im.convert("RGB")

        long_edge = max(im.size)
        if long_edge > MAX_LONG_EDGE:
            scale = MAX_LONG_EDGE / long_edge
            new_size = (max(1, round(im.width * scale)), max(1, round(im.height * scale)))
            im = im.resize(new_size, Image.LANCZOS)

        width, height = im.size
        best: bytes | None = None
        for quality in WEBP_QUALITY_STEPS:
            buf = BytesIO()
            # No `exif=` kwarg passed -> EXIF is stripped by construction.
            im.save(buf, format="WEBP", quality=quality, method=6)
            data = buf.getvalue()
            best = data
            if len(data) <= TARGET_MAX_BYTES:
                return data, width, height
        eprint(f"  warning: {what}: could not reach {TARGET_MAX_BYTES} bytes (final size {len(best or b'')})")
        return best or b"", width, height


def load_candidates(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text())
    if data.get("schemaVersion") != 1:
        raise FetchError(f"{path}: schemaVersion must be 1")
    expected_id = path.name.removesuffix(".candidates.json")
    if data.get("id") != expected_id:
        raise FetchError(f"{path}: id '{data.get('id')}' does not match filename ({expected_id})")
    if "images" not in data or not isinstance(data["images"], list):
        raise FetchError(f"{path}: 'images' must be a list")
    return data


def fetch_tile(tile_id: str, candidates: dict[str, Any]) -> dict[str, Any]:
    """Process one tile's candidates into a resolved dict. Raises FetchError
    (nothing is written for the tile) on any license/page failure."""
    gallery_dir = PUBLIC_POSTERS_DIR / tile_id / "gallery"
    resolved_images: list[dict[str, Any]] = []
    kept_filenames: set[str] = set()

    for index, entry in enumerate(candidates["images"], start=1):
        commons_file = entry["commonsFile"]
        eprint(f"[{tile_id}] {index}: {commons_file}")
        imageinfo = commons_imageinfo(commons_file)
        extmetadata = imageinfo.get("extmetadata", {})
        license_info = resolve_license(commons_file, extmetadata)

        slug = slugify(commons_file.removeprefix("File:").rsplit(".", 1)[0])
        filename = f"{index:02d}-{slug}.webp"
        kept_filenames.add(filename)

        original_url = imageinfo["url"]
        original_bytes = download_bytes(original_url, what=f"original image for {commons_file}")
        rotate = entry.get("rotate", 0)
        if rotate not in (0, 90, 180, 270):
            raise FetchError(f"{tile_id}: {commons_file}: rotate must be one of 0, 90, 180, 270 (degrees clockwise)")
        webp_bytes, width, height = to_webp(original_bytes, what=commons_file, rotate=rotate)

        gallery_dir.mkdir(parents=True, exist_ok=True)
        out_path = gallery_dir / filename
        out_path.write_bytes(webp_bytes)
        sha256 = hashlib.sha256(webp_bytes).hexdigest()

        source_url = imageinfo.get("descriptionurl") or f"{SOURCE_URL_PREFIX}{urllib.parse.quote(commons_file)}"

        resolved_images.append(
            {
                "src": f"/posters/{tile_id}/gallery/{filename}",
                "alt": entry["alt"],
                "caption": entry["caption"],
                # A candidate may override the credited author: Commons'
                # machine-readable Artist field is often the uploader or a
                # "No machine-readable author provided" placeholder, not the
                # photographer named in the page's prose. The override is a
                # courtesy credit only — it never affects the license gate.
                "author": entry.get("author") or license_info["author"],
                "license": license_info["license"],
                "licenseId": license_info["licenseId"],
                "licenseUrl": license_info["licenseUrl"],
                "shareAlike": license_info["shareAlike"],
                "sourceUrl": source_url,
                "sourceName": "Wikimedia Commons",
                "sha256": sha256,
                "width": width,
                "height": height,
            }
        )

    # Idempotency + no orphans: drop any previously-shipped webp that is no
    # longer produced by the current candidates file.
    if gallery_dir.is_dir():
        for stale in gallery_dir.glob("*.webp"):
            if stale.name not in kept_filenames:
                eprint(f"[{tile_id}] removing stale asset {stale.name}")
                stale.unlink()

    resolved: dict[str, Any] = {
        "schemaVersion": 1,
        "id": tile_id,
        "images": resolved_images,
    }
    if "adLinks" in candidates:
        resolved["adLinks"] = candidates["adLinks"]
    return resolved


def write_resolved(tile_id: str, resolved: dict[str, Any]) -> Path:
    out_path = CANDIDATES_DIR / f"{tile_id}.resolved.json"
    out_path.write_text(json.dumps(resolved, indent=2, ensure_ascii=False) + "\n")
    return out_path


def discover_tiles(explicit: list[str] | None) -> list[str]:
    if explicit:
        return explicit
    return sorted(p.name.removesuffix(".candidates.json") for p in CANDIDATES_DIR.glob("*.candidates.json"))


def run_fetch(tiles: list[str]) -> int:
    if not tiles:
        eprint("no *.candidates.json files found")
        return 0
    failures = 0
    for tile_id in tiles:
        candidates_path = CANDIDATES_DIR / f"{tile_id}.candidates.json"
        if not candidates_path.is_file():
            eprint(f"error: {candidates_path} does not exist")
            failures += 1
            continue
        try:
            candidates = load_candidates(candidates_path)
            resolved = fetch_tile(tile_id, candidates)
        except FetchError as exc:
            eprint(f"error: {exc}")
            failures += 1
            continue
        out_path = write_resolved(tile_id, resolved)
        eprint(f"[{tile_id}] wrote {out_path} ({len(resolved['images'])} image(s))")
    return 1 if failures else 0


def run_verify(tiles: list[str], *, offline: bool) -> int:
    drift = 0
    checked_any = False
    for tile_id in tiles:
        resolved_path = CANDIDATES_DIR / f"{tile_id}.resolved.json"
        if not resolved_path.is_file():
            eprint(f"error: {resolved_path} does not exist")
            drift += 1
            continue
        try:
            resolved = json.loads(resolved_path.read_text())
        except json.JSONDecodeError as exc:
            eprint(f"error: {resolved_path}: malformed JSON: {exc}")
            drift += 1
            continue

        for entry in resolved.get("images", []):
            checked_any = True
            src = entry.get("src", "")
            rel = src.lstrip("/")  # "posters/<id>/gallery/NN-slug.webp"
            asset_path = REPO_ROOT / "spa" / "public" / rel
            if not asset_path.is_file():
                eprint(f"drift [{tile_id}]: missing asset {asset_path}")
                drift += 1
                continue
            actual_sha = hashlib.sha256(asset_path.read_bytes()).hexdigest()
            if actual_sha != entry.get("sha256"):
                eprint(f"drift [{tile_id}]: sha256 mismatch for {asset_path}")
                drift += 1

            if offline:
                continue

            source_url = entry.get("sourceUrl", "")
            commons_file = urllib.parse.unquote(source_url.removeprefix(SOURCE_URL_PREFIX))
            if not commons_file:
                eprint(f"drift [{tile_id}]: cannot derive Commons title from sourceUrl {source_url!r}")
                drift += 1
                continue
            try:
                imageinfo = commons_imageinfo(commons_file)
                license_info = resolve_license(commons_file, imageinfo.get("extmetadata", {}))
            except FetchError as exc:
                eprint(f"drift [{tile_id}]: {exc}")
                drift += 1
                continue
            if license_info["licenseId"] != entry.get("licenseId"):
                eprint(
                    f"drift [{tile_id}]: license changed for {commons_file}: "
                    f"recorded {entry.get('licenseId')!r}, now {license_info['licenseId']!r}"
                )
                drift += 1

    if not checked_any:
        eprint("no images to verify")
    return 1 if drift else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Fetch + verify Commons-sourced poster gallery images.")
    parser.add_argument("--tile", action="append", dest="tiles", help="Limit to this tile id (repeatable).")
    parser.add_argument("--verify", action="store_true", help="Re-check resolved entries instead of fetching.")
    parser.add_argument(
        "--offline",
        action="store_true",
        help="With --verify: skip network calls, check only sha256/existence (CI-safe).",
    )
    args = parser.parse_args(argv)

    if args.offline and not args.verify:
        parser.error("--offline is only valid with --verify")

    tiles = discover_tiles(args.tiles)
    if args.verify:
        return run_verify(tiles, offline=args.offline)
    return run_fetch(tiles)


if __name__ == "__main__":
    sys.exit(main())

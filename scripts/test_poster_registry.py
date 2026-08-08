#!/usr/bin/env python3
"""Focused tests for the poster gallery loader (docs/lab/POSTER-GALLERY-SPEC.md
Phase 1). Run directly: `python3 scripts/test_poster_registry.py`.

No `registry/posters/gallery/*.resolved.json` exists in the repo yet -- these
tests build their own fixtures under a temp directory rather than relying on
committed data, per the Phase 1 brief ("build against your own test
fixture").
"""

from __future__ import annotations

import importlib.machinery
import json
import tempfile
import unittest
from pathlib import Path

from poster_registry import PosterError, load_gallery, load_posters

REPO_ROOT = Path(__file__).resolve().parents[1]
TILES_REGISTRY = importlib.machinery.SourceFileLoader(
    "tiles_registry_under_test",
    str(REPO_ROOT / "scripts" / "tiles-registry.py"),
).load_module()

POSTER_MD = """---
title: Test Machine
subtitle: 1985 · Test Machine
---
## Origins

The test machine shipped in 1985 with a modest amount of memory.

Its follow-up model added a graphical shell two years later.

## Significance

It is remembered mainly as a fixture.
"""

POSTER_MD_NO_ORIGINS = """---
title: Test Machine
subtitle: 1985 · Test Machine
---
## History

No Origins heading here.
"""


def _valid_gallery_json(tile_id: str) -> dict:
    return {
        "schemaVersion": 1,
        "id": tile_id,
        "images": [
            {
                "src": f"/posters/{tile_id}/gallery/01-test-machine.webp",
                "alt": "A beige test machine on a plain background",
                "caption": "The test machine in its original case, 1985.",
                "author": "Evan-Amos",
                "license": "Public domain",
                "licenseId": "pd",
                "licenseUrl": "https://creativecommons.org/publicdomain/mark/1.0/",
                "shareAlike": False,
                "sourceUrl": f"https://commons.wikimedia.org/wiki/File:Test-{tile_id}.jpg",
                "sourceName": "Wikimedia Commons",
                "sha256": "a" * 64,
                "width": 1600,
                "height": 1067,
            },
            {
                "src": f"/posters/{tile_id}/gallery/02-test-machine-drive.webp",
                "alt": "The test machine's companion floppy drive",
                "caption": "The companion floppy drive, sold separately.",
                "author": "Jane Photographer",
                "license": "Creative Commons Attribution-ShareAlike 4.0",
                "licenseId": "cc-by-sa-4.0",
                "licenseUrl": "https://creativecommons.org/licenses/by-sa/4.0/",
                "shareAlike": True,
                "sourceUrl": f"https://commons.wikimedia.org/wiki/File:Test-{tile_id}-drive.jpg",
                "sourceName": "Wikimedia Commons",
                "sha256": "b" * 64,
                "width": 1200,
                "height": 900,
            },
        ],
        "adLinks": [
            {
                "title": '"Buy the test machine today" — 1985 magazine advertisement',
                "url": "https://example.org/scan",
                "source": "Internet Archive",
            }
        ],
    }


def _write_poster(root: Path, tile_id: str, body: str = POSTER_MD) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{tile_id}.md").write_text(body)


def _write_gallery(root: Path, tile_id: str, payload: dict) -> None:
    gallery_dir = root / "gallery"
    gallery_dir.mkdir(parents=True, exist_ok=True)
    (gallery_dir / f"{tile_id}.resolved.json").write_text(json.dumps(payload))


class AbsentGalleryTest(unittest.TestCase):
    """The normal case: no resolved.json, so no `gallery` key -- ever."""

    def test_missing_gallery_file_is_silent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_poster(root, "widget")
            posters, warnings = load_posters(root, {"widget"})
            self.assertEqual(warnings, [])
            self.assertNotIn("gallery", posters["widget"])
            # And the generator does not emit a null/absent key either.
            encoded = TILES_REGISTRY.render_posters(posters).decode()
            self.assertNotIn('"gallery"', encoded)

    def test_poster_without_tile_directory_untouched(self):
        # A tile with no gallery subdirectory at all behaves identically to
        # one with the subdirectory present but empty for this id.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_poster(root, "widget")
            (root / "gallery").mkdir()
            posters, _warnings = load_posters(root, {"widget"})
            self.assertNotIn("gallery", posters["widget"])


class GalleryIsIndependentOfProseStructureTest(unittest.TestCase):
    """Origins-section placement is an ExhibitPoster/UI concern (see
    spa/src/ui/posterGallerySection.ts) -- the Python loader only validates
    the gallery file's own schema and license, never the poster's prose."""

    def test_gallery_attaches_even_without_an_origins_heading(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_poster(root, "widget", body=POSTER_MD_NO_ORIGINS)
            _write_gallery(root, "widget", _valid_gallery_json("widget"))
            posters, warnings = load_posters(root, {"widget"})
            self.assertEqual(warnings, [])
            self.assertIn("gallery", posters["widget"])


class ValidGalleryRoundTripTest(unittest.TestCase):
    def test_gallery_attaches_and_round_trips_through_the_generator(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_poster(root, "widget")
            _write_gallery(root, "widget", _valid_gallery_json("widget"))

            posters, warnings = load_posters(root, {"widget"})
            self.assertEqual(warnings, [])
            gallery = posters["widget"]["gallery"]
            self.assertEqual(len(gallery["images"]), 2)
            self.assertEqual(set(gallery), {"images", "adLinks"})
            first = gallery["images"][0]
            # sha256 is stripped: PosterGalleryImage in spa/src/types.ts has
            # no such field, and posters.ts is `satisfies PosterDoc` so an
            # extra key there would be a TypeScript build error.
            self.assertNotIn("sha256", first)
            self.assertEqual(
                set(first),
                {
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
                },
            )
            self.assertEqual(gallery["adLinks"][0]["title"].startswith('"Buy'), True)

            # Round-trip through the actual generator step.
            encoded = TILES_REGISTRY.render_posters(posters).decode()
            self.assertIn("export const POSTERS", encoded)
            reparsed_src = encoded.split(" = ", 1)[1].rsplit(" as const", 1)[0]
            reparsed = json.loads(reparsed_src)
            self.assertEqual(reparsed["widget"]["gallery"]["images"][0]["licenseId"], "pd")
            self.assertNotIn("sha256", reparsed["widget"]["gallery"]["images"][0])

    def test_gallery_without_ad_links_omits_the_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_poster(root, "widget")
            payload = _valid_gallery_json("widget")
            del payload["adLinks"]
            _write_gallery(root, "widget", payload)
            posters, _warnings = load_posters(root, {"widget"})
            self.assertEqual(set(posters["widget"]["gallery"]), {"images"})


class MalformedGalleryIsAHardErrorTest(unittest.TestCase):
    def test_non_free_license_is_a_load_error_not_a_warning(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_poster(root, "widget")
            payload = _valid_gallery_json("widget")
            payload["images"][0]["licenseId"] = "cc-by-nc-4.0"
            _write_gallery(root, "widget", payload)
            with self.assertRaises(PosterError):
                load_posters(root, {"widget"})

    def test_missing_field_is_a_load_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_poster(root, "widget")
            payload = _valid_gallery_json("widget")
            del payload["images"][0]["author"]
            _write_gallery(root, "widget", payload)
            with self.assertRaises(PosterError):
                load_posters(root, {"widget"})

    def test_id_mismatch_is_a_load_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_poster(root, "widget")
            payload = _valid_gallery_json("widget")
            payload["id"] = "other-tile"
            _write_gallery(root, "widget", payload)
            with self.assertRaises(PosterError):
                load_posters(root, {"widget"})

    def test_too_many_ad_links_is_a_load_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_poster(root, "widget")
            payload = _valid_gallery_json("widget")
            payload["adLinks"] = payload["adLinks"] * 3
            _write_gallery(root, "widget", payload)
            with self.assertRaises(PosterError):
                load_posters(root, {"widget"})

    def test_src_outside_the_tiles_own_gallery_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_poster(root, "widget")
            payload = _valid_gallery_json("widget")
            payload["images"][0]["src"] = "/posters/other-tile/gallery/01-x.webp"
            _write_gallery(root, "widget", payload)
            with self.assertRaises(PosterError):
                load_posters(root, {"widget"})

    def test_invalid_json_is_a_load_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_poster(root, "widget")
            gallery_dir = root / "gallery"
            gallery_dir.mkdir()
            (gallery_dir / "widget.resolved.json").write_text("{not json")
            with self.assertRaises(PosterError):
                load_posters(root, {"widget"})


class LoadGalleryDirectTest(unittest.TestCase):
    """load_gallery() itself, independent of load_posters()."""

    def test_absent_file_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "gallery" / "widget.resolved.json"
            self.assertIsNone(load_gallery(missing, "widget"))


if __name__ == "__main__":
    unittest.main()

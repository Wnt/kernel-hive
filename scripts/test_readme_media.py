#!/usr/bin/env python3
"""Tests for scripts/readme_media_lib.py — the selection logic and the
lineup markdown/HTML that scripts/readme-media.py renders into README.md.

Runs against small synthetic registry rows (no Pillow, no real registry, no
network) so it stays fast and independent of the current lineup's size; run
directly or via `python3 -m unittest discover -s scripts -p 'test_*.py'`.
"""

from __future__ import annotations

import unittest

import readme_media_lib as lib


def _row(id_, year, family="TestEmu", lifecycle="production", transport="streamhost"):
    return {
        "id": id_,
        "museum": {"displayName": id_.upper(), "year": year},
        "emulator": {"family": family},
        "lifecycle": lifecycle,
        "stream": {"transport": transport},
    }


class LiveAndPosterTests(unittest.TestCase):
    def test_is_live_requires_production_and_streamhost(self):
        self.assertTrue(lib.is_live(_row("a", 1990)))
        self.assertFalse(lib.is_live(_row("a", 1990, lifecycle="showcase")))
        hidden = _row("a", 1990)
        hidden["listing"] = {"state": "hidden"}
        self.assertFalse(lib.is_live(hidden))
        self.assertFalse(lib.is_live(_row("a", 1990, transport="bridge")))

    def test_is_poster_is_the_showcase_lifecycle(self):
        self.assertTrue(lib.is_poster(_row("a", 1990, lifecycle="showcase")))
        self.assertFalse(lib.is_poster(_row("a", 1990)))

    def test_live_count_excludes_posters(self):
        rows = [_row("a", 1990), _row("b", 2000, lifecycle="showcase"), _row("c", 2010)]
        self.assertEqual(lib.live_count(rows), 2)


class YearSpanTests(unittest.TestCase):
    def test_min_max_computed_fresh_not_hardcoded(self):
        rows = [_row("a", 1970), _row("b", 2026), _row("c", 1999)]
        self.assertEqual(lib.year_span(rows), (1970, 2026))

    def test_ignores_rows_with_no_year(self):
        rows = [_row("a", 1980)]
        rows[0]["museum"]["year"] = None
        rows.append(_row("b", 1985))
        self.assertEqual(lib.year_span(rows), (1985, 1985))

    def test_empty_registry_raises(self):
        with self.assertRaises(ValueError):
            lib.year_span([])


class HeroSelectionTests(unittest.TestCase):
    def test_required_ids_always_included_when_present(self):
        rows = [_row(id_, 1980 + i) for i, id_ in enumerate(lib.HERO_REQUIRED_IDS)]
        rows += [_row(f"filler{i}", 2000 + i) for i in range(30)]
        chosen = lib.select_hero_rows(rows, count=lib.HERO_COUNT)
        chosen_ids = {r["id"] for r in chosen}
        self.assertTrue(set(lib.HERO_REQUIRED_IDS).issubset(chosen_ids))
        self.assertEqual(len(chosen), lib.HERO_COUNT)

    def test_deterministic_across_repeated_calls(self):
        rows = [_row(f"s{i}", 1970 + i) for i in range(50)]
        first = [r["id"] for r in lib.select_hero_rows(rows)]
        second = [r["id"] for r in lib.select_hero_rows(rows)]
        self.assertEqual(first, second)

    def test_excludes_posters(self):
        rows = [_row(f"s{i}", 1970 + i) for i in range(25)]
        rows.append(_row("poster1", 2020, lifecycle="showcase"))
        chosen = lib.select_hero_rows(rows, count=lib.HERO_COUNT)
        self.assertNotIn("poster1", {r["id"] for r in chosen})

    def test_fewer_live_rows_than_requested_returns_all(self):
        rows = [_row(f"s{i}", 1970 + i) for i in range(5)]
        chosen = lib.select_hero_rows(rows, count=lib.HERO_COUNT)
        self.assertEqual(len(chosen), 5)


class PreviewSelectionTests(unittest.TestCase):
    def test_count_and_determinism(self):
        rows = [_row(f"s{i}", 1970 + i) for i in range(40)]
        first = lib.select_preview_rows(rows, count=lib.PREVIEW_COUNT)
        second = lib.select_preview_rows(rows, count=lib.PREVIEW_COUNT)
        self.assertEqual(len(first), lib.PREVIEW_COUNT)
        self.assertEqual([r["id"] for r in first], [r["id"] for r in second])


class DecadeGroupingTests(unittest.TestCase):
    def test_buckets_by_decade(self):
        rows = [_row("a", 1975), _row("b", 1988), _row("c", 1999), _row("d", 2015), _row("e", 2023)]
        groups = lib.group_by_decade(rows)
        labels = [g[0] for g in groups]
        self.assertEqual(labels, ["1970s", "1980s", "1990s", "2010s–2020s"])

    def test_excludes_posters_and_yearless_rows(self):
        rows = [_row("a", 1980), _row("b", 1985, lifecycle="showcase")]
        rows[0]["museum"]["year"] = None
        groups = lib.group_by_decade(rows)
        self.assertEqual(groups, [])

    def test_group_sorted_by_year_then_id(self):
        rows = [_row("z", 1985), _row("a", 1980), _row("m", 1980)]
        groups = lib.group_by_decade(rows)
        self.assertEqual([r["id"] for r in groups[0][1]], ["a", "m", "z"])


class RenderLineupHtmlTests(unittest.TestCase):
    def test_contains_link_and_image_per_station(self):
        rows = [_row("winnt", 1993), _row("solaris", 1995)]
        html = lib.render_lineup_html(rows)
        self.assertIn("https://kernelhive.madekivi.fi/os/winnt", html)
        self.assertIn("spa/public/posters/winnt/desktop.webp", html)
        self.assertIn("WINNT · 1993", html)

    def test_placards_section_for_posters_only(self):
        rows = [_row("a", 1990), _row("macos", 2024, lifecycle="showcase")]
        html = lib.render_lineup_html(rows)
        self.assertIn("### Placards", html)
        self.assertIn("spa/public/posters/macos/desktop.webp", html)

    def test_no_placards_section_when_no_posters(self):
        rows = [_row("a", 1990)]
        html = lib.render_lineup_html(rows)
        self.assertNotIn("Placards", html)

    def test_six_per_row(self):
        rows = [_row(f"s{i}", 1980 + i) for i in range(7)]
        html = lib.render_lineup_html(rows)
        # 7 items -> two <tr> blocks (6 + 1).
        self.assertEqual(html.count("<tr>"), 2)


class SpliceReadmeTests(unittest.TestCase):
    def test_replaces_existing_marked_block(self):
        readme = "# T\n\npara.\n\n<!-- lineup:start -->\nold\n<!-- lineup:end -->\n\nrest\n"
        block = "<!-- lineup:start -->\nnew\n<!-- lineup:end -->\n"
        out = lib.splice_readme(readme, block)
        self.assertIn("new", out)
        self.assertNotIn("old", out)
        self.assertIn("rest", out)

    def test_inserts_after_first_h1_paragraph_when_absent(self):
        readme = "# T\n\nfirst paragraph\nstill first paragraph.\n\n> blockquote\n"
        block = "<!-- lineup:start -->\nnew\n<!-- lineup:end -->\n"
        out = lib.splice_readme(readme, block)
        self.assertIn("first paragraph\nstill first paragraph.\n\n<!-- lineup:start -->", out)
        self.assertIn("> blockquote", out)
        self.assertLess(out.index("lineup:start"), out.index("> blockquote"))

    def test_unbalanced_markers_raise(self):
        readme = "# T\n\n<!-- lineup:start -->\nno end\n"
        with self.assertRaises(lib.MarkerError):
            lib.splice_readme(readme, "<!-- lineup:start -->\nx\n<!-- lineup:end -->\n")

    def test_duplicated_markers_raise(self):
        readme = "# T\n\n<!-- lineup:start -->\na\n<!-- lineup:end -->\n<!-- lineup:start -->\nb\n<!-- lineup:end -->\n"
        with self.assertRaises(lib.MarkerError):
            lib.splice_readme(readme, "<!-- lineup:start -->\nx\n<!-- lineup:end -->\n")


class ExtractLineupBlockTests(unittest.TestCase):
    def test_roundtrip_with_splice(self):
        rows = [_row("a", 1990)]
        block = lib.render_lineup_block(rows)
        readme = lib.splice_readme("# T\n\npara.\n\n> rest\n", block)
        self.assertEqual(lib.extract_lineup_block(readme), block)

    def test_none_when_absent(self):
        self.assertIsNone(lib.extract_lineup_block("# T\n\nno markers here\n"))


if __name__ == "__main__":
    unittest.main()

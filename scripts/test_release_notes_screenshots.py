#!/usr/bin/env python3
"""Tile derivation and rendering for the weekly screenshot grid
(release_notes_screenshots.py)."""

from __future__ import annotations

import unittest

import release_notes_screenshots as SCREENSHOTS


def week(summary_texts: list[str], bullets: list[str] | None = None, **extra) -> dict:
    themes = ["New stations", "Major features", "Quality improvements"]
    doc = {
        "summary": [{"theme": t, "text": text} for t, text in zip(themes, summary_texts)],
        "bullets": bullets or [],
    }
    doc.update(extra)
    return doc


class DeriveTest(unittest.TestCase):
    def test_no_links_at_all_is_an_empty_list(self):
        self.assertEqual(SCREENSHOTS.derive(week(["plain text", "more text", "still more"])), [])

    def test_new_stations_links_come_first(self):
        doc = week(
            [
                "[Windows 3.11](station:win311) and [OS/2 Warp](station:os2warp) both landed",
                "unrelated feature text",
                "quality text",
            ]
        )
        self.assertEqual(SCREENSHOTS.derive(doc), ["win311", "os2warp"])

    def test_order_is_first_appearance_across_sections_then_bullets(self):
        doc = week(
            ["[A](station:win311) arrived", "[B](station:os2warp) improved", "quality text"],
            bullets=["a bullet about [C](station:win311) again", "and [D](station:os2warp) too"],
        )
        # win311 and os2warp both appear in the summary first; the bullets add
        # nothing new, so the order is exactly the summary's.
        self.assertEqual(SCREENSHOTS.derive(doc), ["win311", "os2warp"])

    def test_a_bullet_only_link_is_still_picked_up(self):
        doc = week(
            ["no links here", "none here either", "or here"],
            bullets=["[Windows 3.11](station:win311) got a fix"],
        )
        self.assertEqual(SCREENSHOTS.derive(doc), ["win311"])

    def test_duplicates_across_sections_are_collapsed_to_the_first(self):
        doc = week(
            ["[Windows 3.11](station:win311) arrived", "back to [Windows 3.11](station:win311)", "again"],
        )
        self.assertEqual(SCREENSHOTS.derive(doc), ["win311"])

    def test_capped_at_eight(self):
        ids = [f"s{i}" for i in range(12)]
        text = " ".join(f"[{i}](station:{i})" for i in ids)
        doc = week([text, "", ""])
        self.assertEqual(len(SCREENSHOTS.derive(doc)), SCREENSHOTS.CAP)
        self.assertEqual(SCREENSHOTS.derive(doc), ids[: SCREENSHOTS.CAP])


class ResolveTest(unittest.TestCase):
    def test_no_override_falls_back_to_derive(self):
        doc = week(["[Windows 3.11](station:win311) arrived", "", ""])
        self.assertEqual(SCREENSHOTS.resolve(doc), ["win311"])

    def test_an_override_replaces_the_derived_list_entirely(self):
        doc = week(["[Windows 3.11](station:win311) arrived", "", ""], screenshots=["os2warp"])
        self.assertEqual(SCREENSHOTS.resolve(doc), ["os2warp"])


class TableTest(unittest.TestCase):
    def test_an_empty_list_renders_nothing(self):
        self.assertEqual(SCREENSHOTS.table([], lambda sid: sid), [])

    def test_four_per_row(self):
        items = [{"id": f"s{i}", "name": f"Station {i}"} for i in range(5)]
        lines = SCREENSHOTS.table(items, lambda sid: f"img/{sid}.webp")
        text = "\n".join(lines)
        self.assertEqual(text.count("<tr>"), 2)
        self.assertEqual(text.count("<td>"), 5)
        self.assertIn('<img src="img/s0.webp" width="200" alt="Station 0">', text)
        self.assertIn('href="https://kernelhive.madekivi.fi/os/s0"', text)
        self.assertIn("<sub>Station 0</sub>", text)


if __name__ == "__main__":
    unittest.main()

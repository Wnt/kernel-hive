#!/usr/bin/env python3
"""The inline markup vocabulary: what it accepts, and what it must refuse.

These guard the two failure modes that reach a reader. A station id that does
not exist publishes a link straight to a 404, and it is invisible in review
because the prose around it looks fine. A tag outside the vocabulary is either
sanitised away by GitHub or has to be escaped in the SPA, so the words simply
vanish from the page — silently, in both destinations.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import release_notes_markup as markup

REPO_ROOT = Path(__file__).resolve().parents[1]
STATIONS = frozenset({"win311", "beos", "tru64"})


class PlainTextTest(unittest.TestCase):
    def test_markers_are_stripped_for_counting(self):
        text = "**ICQ** on [Windows 3.11](station:win311), an *8086* box, <u>at last</u>"
        self.assertEqual(markup.plain_text(text), "ICQ on Windows 3.11, an 8086 box, at last")

    def test_word_count_ignores_markup(self):
        # The budget is about how much a reader READS: counting the raw string
        # would let a link-dense paragraph claim words it never says.
        self.assertEqual(markup.word_count("[Windows 3.11](station:win311) is **fast**"), 4)


class MarkupErrorsTest(unittest.TestCase):
    def errors(self, text: str) -> list[str]:
        return markup.markup_errors(text, STATIONS, "bullet 1")

    def test_a_known_station_passes(self):
        self.assertEqual(self.errors("try [BeOS](station:beos)"), [])

    def test_an_unknown_station_is_refused(self):
        self.assertIn("no station `nope`", " ".join(self.errors("try [X](station:nope)")))

    def test_a_non_station_link_is_refused(self):
        self.assertIn("not a station link", " ".join(self.errors("see [docs](https://example.com)")))

    def test_unbalanced_emphasis_is_refused(self):
        self.assertIn("unbalanced **", " ".join(self.errors("**open and never closed")))
        self.assertIn("unbalanced <u>", " ".join(self.errors("<u>open")))

    def test_a_tag_outside_the_vocabulary_is_refused(self):
        self.assertIn("<script>", " ".join(self.errors("<script>alert(1)</script>")))
        self.assertIn("<b>", " ".join(self.errors("<b>bold</b>")))


class ToMarkdownTest(unittest.TestCase):
    def test_a_station_becomes_an_absolute_gallery_url(self):
        # Absolute on purpose: a reader on GitHub is nowhere near the SPA.
        self.assertEqual(
            markup.to_markdown("[Windows 3.11](station:win311)"),
            f"[Windows 3.11]({markup.GALLERY}/os/win311)",
        )

    def test_underline_survives_the_angle_bracket_escaping(self):
        self.assertEqual(markup.to_markdown("<u>headline</u>"), "<u>headline</u>")

    def test_a_stray_placeholder_is_still_escaped(self):
        # `<session>` parses as raw inline HTML and GitHub's sanitiser deletes
        # it, so the placeholder would disappear from the rendered line.
        self.assertEqual(markup.to_markdown("path /staging/<session>/"), r"path /staging/\<session>/")

    def test_underline_and_a_placeholder_on_one_line(self):
        rendered = markup.to_markdown("<u>a</u> then <session>")
        self.assertIn("<u>a</u>", rendered)
        self.assertIn(r"\<session>", rendered)


class StationIdsTest(unittest.TestCase):
    def test_ids_are_read_from_the_registry_itself(self):
        # Read live, so a station added next month is linkable the same day.
        ids = markup.station_ids(REPO_ROOT)
        self.assertIn("win311", ids)
        self.assertIn("tru64", ids)
        self.assertNotIn("sources", ids)


if __name__ == "__main__":
    unittest.main()

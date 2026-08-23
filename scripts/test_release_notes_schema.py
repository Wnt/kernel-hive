#!/usr/bin/env python3
"""The locked schema: every way an authored week file can be wrong.

Split from test_release_notes.py, which now covers the WEEK MATHS and the
rendering. The seam is the same one release_notes_schema.py draws, and the split
happened for the same reason: the schema is the half that gains a rule every
time the format changes — themes, word budgets, the markup vocabulary, the one
underline a week is allowed — so it is the half that grows past the file cap.
"""

from __future__ import annotations

import unittest
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import release_notes_schema as SCHEMA

# The realistic week fixtures and the temp-tree helper live in the sibling test
# module; importing them keeps ONE definition of what a plausible week looks
# like, so a schema change cannot pass here and fail there.
from test_release_notes import WEEK0, WEEK1, temp_tree  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[1]
# `release-notes.py` is not an importable module name (the dash), and
# load_module() is deprecated and errors under -W error, so build the module
# from its spec the supported way.
# RN comes from the sibling module, NOT a second importlib load. `release-notes.py`
# has a dash, so each test file that loads it by spec gets its OWN module object —
# and temp_tree patches REPO_ROOT on the instance it can see. Two instances means
# the fixture redirects one module while the assertion exercises the other, and the
# test passes or fails for reasons that have nothing to do with the code.
from test_release_notes import RN  # noqa: E402  (after the sys.path preamble above)

TZ = ZoneInfo("Europe/Helsinki")


def helsinki(text: str) -> datetime:
    return datetime.fromisoformat(text).replace(tzinfo=TZ)


# The themes live in the schema module, which owns the locked shape.
NORMAL_THEMES = SCHEMA.NORMAL_THEMES
WEEK0_THEMES = SCHEMA.WEEK0_THEMES


def paragraphs(count: int, words: int, themes: tuple[str, ...] | None = None) -> list[dict]:
    """`count` themed sections holding `words` words of prose in total.

    The themes default to the real ones for that section count, so a fixture
    that is not ABOUT the theme rule never trips it; a test that wants a wrong
    theme list passes its own.
    """
    if themes is None:
        themes = WEEK0_THEMES if count == len(WEEK0_THEMES) else NORMAL_THEMES
        themes = (
            themes[:count] if count <= len(themes) else themes + tuple(f"Extra {i}" for i in range(count - len(themes)))
        )
    each = [words // count] * count
    each[0] += words - sum(each)
    return [{"theme": theme, "text": " ".join(["word"] * n)} for theme, n in zip(themes, each)]


def week_doc(number: int = 3, **overrides) -> dict:
    doc = {
        "week": number,
        "title": "Retronet reaches the web",
        "start": "2026-08-16T09:00:00+03:00",
        "end": "2026-08-23T09:00:00+03:00",
        "commitCount": 336,
        "codeLines": 35569,
        "summary": paragraphs(3, 350),
        "bullets": ["A 1994 <u>SGI workstation</u> dialled out to a period web server"],
    }
    doc.update(overrides)
    return doc


# Later than every fixture week, so `render` never warns about an unclosed one.
NOW = datetime(2026, 9, 1, 12, 0, tzinfo=TZ)


class SchemaTest(unittest.TestCase):
    """One test per failure mode: the validator never repairs, it reports."""

    def errors(self, doc, stem: str = "2026-08-23") -> list[str]:
        found: list[str] = []
        RN.validate_week(doc, Path(f"/tmp/{stem}.json"), found)
        return found

    def assert_rejects(self, needle: str, doc, stem: str = "2026-08-23"):
        found = self.errors(doc, stem)
        self.assertTrue(any(needle in line for line in found), f"expected {needle!r} in {found}")

    def test_a_well_formed_week_passes(self):
        self.assertEqual(self.errors(week_doc()), [])

    def test_week_0_passes_on_its_own_wider_budget(self):
        doc = week_doc(
            0,
            title="The month the museum was built",
            start="2026-07-07T21:39:24+03:00",
            end="2026-08-07T14:37:08+03:00",
            summary=paragraphs(4, 650),
            source="osgallery",
        )
        self.assertEqual(self.errors(doc, "2026-08-07"), [])

    def test_a_missing_key_is_named(self):
        doc = week_doc()
        del doc["bullets"]
        self.assert_rejects("missing `bullets`", doc)

    def test_an_unknown_key_is_refused(self):
        self.assert_rejects("unknown key `sections`", week_doc(sections=[]))

    def test_a_non_object_is_refused(self):
        self.assert_rejects("must be a JSON object", ["week 3"])

    def test_a_boolean_is_not_an_integer(self):
        self.assert_rejects("`week` must be", week_doc(week=True))
        self.assert_rejects("`commitCount` must be", week_doc(commitCount=True))

    def test_a_negative_commit_count_is_refused(self):
        self.assert_rejects("`commitCount` must be", week_doc(commitCount=-1))
        self.assert_rejects("`codeLines` must be", week_doc(codeLines=-1))
        self.assert_rejects("`codeLines` must be", week_doc(codeLines="lots"))

    def test_a_title_carrying_its_own_week_number_is_refused(self):
        self.assert_rejects("must not contain the week number", week_doc(title="Week 3 retronet lands"))
        self.assert_rejects("must not contain the week number", week_doc(title="week3 retronet lands"))

    def test_title_length_is_bounded_at_both_ends(self):
        self.assert_rejects("must be 2-6", week_doc(title="Retronet"))
        self.assert_rejects("must be 2-6", week_doc(title="Retronet reaches the web and then some more"))

    def test_a_naive_timestamp_is_refused(self):
        self.assert_rejects("UTC offset", week_doc(start="2026-08-16T09:00:00"))
        self.assert_rejects("UTC offset", week_doc(end="not a date"))

    def test_start_must_precede_end(self):
        self.assert_rejects("earlier than `end`", week_doc(start="2026-08-30T09:00:00+03:00"))

    def test_the_file_name_must_match_the_end_date(self):
        self.assert_rejects("this week's file is 2026-08-23.json", week_doc(), stem="2026-08-16")

    def test_a_normal_week_gets_exactly_three_paragraphs(self):
        self.assert_rejects(
            "themes must be exactly", week_doc(summary=paragraphs(2, 350, ("New stations", "Major features")))
        )
        self.assert_rejects("themes must be exactly", week_doc(summary=paragraphs(4, 350, WEEK0_THEMES)))

    def test_a_normal_week_is_held_to_300_400_words(self):
        self.assert_rejects("must be 300-400", week_doc(summary=paragraphs(3, 299)))
        self.assert_rejects("must be 300-400", week_doc(summary=paragraphs(3, 401)))

    def test_week_0_is_held_to_its_own_budget_not_the_normal_one(self):
        base = dict(end="2026-08-07T14:37:08+03:00", start="2026-07-07T21:39:24+03:00", source="osgallery")
        # A 3-paragraph, 350-word week 0 is a normal week's budget, and wrong.
        self.assert_rejects("themes must be exactly", week_doc(0, summary=paragraphs(3, 650), **base), "2026-08-07")
        self.assert_rejects("must be 600-700", week_doc(0, summary=paragraphs(4, 350), **base), "2026-08-07")

    def test_week_0_must_declare_where_it_came_from(self):
        doc = week_doc(
            0, start="2026-07-07T21:39:24+03:00", end="2026-08-07T14:37:08+03:00", summary=paragraphs(4, 650)
        )
        self.assert_rejects('"source": "osgallery"', doc, "2026-08-07")

    def test_a_normal_week_may_not_claim_a_source(self):
        self.assert_rejects("belongs to week 0 only", week_doc(source="osgallery"))

    def test_bullets_are_bounded_in_count(self):
        self.assert_rejects("must be 1-20", week_doc(bullets=[]))
        self.assert_rejects("must be 1-20", week_doc(bullets=[f"highlight {i}" for i in range(21)]))

    def test_a_bullet_is_one_short_line(self):
        self.assert_rejects("spans more than one line", week_doc(bullets=["one\ntwo"]))
        self.assert_rejects("must be <= 160", week_doc(bullets=["x" * 161]))

    def test_a_bullet_may_not_carry_its_own_list_marker(self):
        self.assert_rejects("carries its own list marker", week_doc(bullets=["- already a bullet"]))

    def test_empty_strings_are_not_prose(self):
        self.assert_rejects("`summary` must be a list", week_doc(summary="not a list"))
        self.assert_rejects("`bullets` must be a list", week_doc(bullets=[""]))
        self.assert_rejects("`title` must be", week_doc(title="   "))


class NumberingTest(unittest.TestCase):
    def numbering_errors(self, numbers: list[int]) -> list[str]:
        found: list[str] = []
        RN._check_numbering([{"week": n} for n in numbers], found)
        return found

    def test_contiguous_from_zero_is_fine(self):
        self.assertEqual(self.numbering_errors([0, 1, 2, 3]), [])

    def test_a_partly_written_run_is_fine_while_the_wave_lands(self):
        self.assertEqual(self.numbering_errors([]), [])

    def test_a_gap_is_refused(self):
        self.assertTrue(self.numbering_errors([0, 1, 3]))

    def test_a_run_that_does_not_start_at_zero_is_refused(self):
        self.assertTrue(self.numbering_errors([1, 2, 3]))

    def test_a_duplicate_week_number_is_refused(self):
        self.assertTrue(any("not unique" in line for line in self.numbering_errors([0, 1, 1])))


class ContinuityTest(unittest.TestCase):
    """`start` is copied by hand from the brief, so it is the paste-slip field."""

    def continuity_errors(self, docs: list[dict]) -> list[str]:
        found: list[str] = []
        RN._check_continuity(docs, found)
        return found

    def test_weeks_that_abut_are_fine(self):
        self.assertEqual(self.continuity_errors([week_doc(0, **WEEK0), week_doc(1, **WEEK1)]), [])

    def test_a_week_that_swallows_the_ones_before_it_is_refused(self):
        swallower = week_doc(2, start="2026-06-01T09:00:00+03:00")
        found = self.continuity_errors([week_doc(0, **WEEK0), week_doc(1, **WEEK1), swallower])
        self.assertTrue(any("must abut" in line for line in found), found)

    def test_a_gap_is_left_to_the_numbering_check(self):
        self.assertEqual(self.continuity_errors([week_doc(0, **WEEK0), week_doc(2)]), [])

    def test_the_load_refuses_a_timeline_that_does_not_abut(self):
        docs = [week_doc(0, **WEEK0), week_doc(1, **WEEK1), week_doc(2, start="2026-06-01T09:00:00+03:00")]
        with temp_tree(docs), self.assertRaises(SystemExit) as caught:
            RN.load_weeks()
        self.assertIn("must abut", str(caught.exception))


if __name__ == "__main__":
    unittest.main()

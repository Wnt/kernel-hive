#!/usr/bin/env python3
"""Focused tests for the release-notes renderer (scripts/release-notes.py).

Run directly: `python3 scripts/test_release_notes.py`, or
`python3 -m unittest discover -s scripts -p 'test_release_notes.py'`.

The prose is hand-written now, so the expensive mistakes moved: a summary file
that quietly breaks the locked schema, week 0 (which git knows nothing about)
being treated as a git week, a README splice that duplicates itself, and a
render/check round-trip that is not byte-exact. Every test writes its own
summary files into a temp tree; none depends on this repo's git history or on
the committed summaries, which change every Sunday.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import release_notes_render as RENDER
import release_notes_schema as SCHEMA

REPO_ROOT = Path(__file__).resolve().parents[1]
# `release-notes.py` is not an importable module name (the dash), and
# load_module() is deprecated and errors under -W error, so build the module
# from its spec the supported way.
_SPEC = importlib.util.spec_from_file_location("release_notes_under_test", REPO_ROOT / "scripts" / "release-notes.py")
RN = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(RN)

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


@contextlib.contextmanager
def temp_tree(docs: list[dict], readme: str | None = None):
    """A throwaway repo tree holding only what render touches."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "registry" / "release-notes").mkdir(parents=True)
        (root / "docs").mkdir()
        (root / "spa" / "public").mkdir(parents=True)
        (root / "README.md").write_text(readme or "# Title\n\n## Contributing\n\nSee CONTRIBUTING.\n")
        (root / "docs" / "RELEASE-NOTES.md").write_text("")
        # `check` also asserts the fork declaration still matches the build files
        # it cites (release_notes_forks.pin_errors), so the tree needs both.
        (root / "registry" / "release-notes" / "sources.json").write_text(
            json.dumps(
                {
                    "ourAuthors": ["Wnt"],
                    "forks": [
                        {
                            "repo": "Wnt/vice",
                            "what": "VICE patches for the Commodore stations",
                            "branches": [{"name": "kernel-hive/integrated", "pinnedBy": ["build.sh"]}],
                        }
                    ],
                }
            )
        )
        # A real pin, in the format `check` parses — a comment naming the branch
        # is deliberately not one.
        (root / "build.sh").write_text(
            'VICE_FORK_URL="${VICE_FORK_URL:-https://github.com/Wnt/vice.git}"\nVICE_FORK_BRANCH=kernel-hive/integrated\n'
        )
        (root / "spa" / "public" / "release-notes.json").write_text("")
        for doc in docs:
            stem = datetime.fromisoformat(doc["end"]).astimezone(TZ).date().isoformat()
            (root / "registry" / "release-notes" / f"{stem}.json").write_text(json.dumps(doc, indent=2))
        original = RN.REPO_ROOT
        RN.REPO_ROOT = root
        # render/check narrate what they wrote; inside a test that chatter only
        # buries unittest's own OK/FAILED line.
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                yield root
        finally:
            RN.REPO_ROOT = original


class BoundaryMathTest(unittest.TestCase):
    def test_first_boundary_is_the_next_sunday_0900(self):
        # 2026-08-07 is a Friday; the release commit is at 14:37 Helsinki.
        self.assertEqual(RN.first_boundary(helsinki("2026-08-07T14:37:08")), helsinki("2026-08-09T09:00:00"))

    def test_epoch_on_a_sunday_before_0900_runs_on_to_the_next_sunday(self):
        # Week 0's file is named after the epoch's DATE, so a week 1 closing at
        # 09:00 that same morning would claim the same file name.
        epoch = helsinki("2026-08-09T08:59:59")
        self.assertEqual(RN.first_boundary(epoch), helsinki("2026-08-16T09:00:00"))
        self.assertNotEqual(RN.week_path(epoch), RN.week_path(RN.first_boundary(epoch)))

    def test_epoch_exactly_on_a_boundary_rolls_to_the_following_sunday(self):
        # The boundary is an EXCLUSIVE end, so a 09:00:00 commit starts the
        # next week rather than closing the one it landed in.
        self.assertEqual(RN.first_boundary(helsinki("2026-08-09T09:00:00")), helsinki("2026-08-16T09:00:00"))

    def test_boundaries_accept_a_non_helsinki_input_timezone(self):
        epoch = datetime.fromisoformat("2026-08-07T11:37:08+00:00")
        self.assertEqual(RN.first_boundary(epoch), helsinki("2026-08-09T09:00:00"))

    def test_closed_spans_stop_before_the_in_progress_week(self):
        spans = RN.closed_spans(helsinki("2026-08-07T14:37:08"), helsinki("2026-08-20T12:00:00"))
        self.assertEqual([n for n, _, _ in spans], [1, 2])
        self.assertEqual(spans[0][1], helsinki("2026-08-07T14:37:08"))
        self.assertEqual(spans[-1][2], helsinki("2026-08-16T09:00:00"))

    def test_a_week_that_closes_exactly_now_is_closed(self):
        spans = RN.closed_spans(helsinki("2026-08-07T14:37:08"), helsinki("2026-08-09T09:00:00"))
        self.assertEqual([n for n, _, _ in spans], [1])


class DaylightSavingTest(unittest.TestCase):
    def test_boundary_stays_at_0900_local_across_the_autumn_fallback(self):
        # EEST (+3) -> EET (+2) happens on 2026-10-25, itself a Sunday.
        before = helsinki("2026-10-18T09:00:00")
        self.assertEqual(before.utcoffset(), timedelta(hours=3))
        across = RN.next_boundary(before)
        self.assertEqual(across, helsinki("2026-10-25T09:00:00"))
        self.assertEqual(across.hour, 9)
        self.assertEqual(across.utcoffset(), timedelta(hours=2))

    def test_the_week_across_the_fallback_is_one_hour_longer_in_real_time(self):
        # Subtract in UTC on purpose: Python ignores a SHARED tzinfo when
        # subtracting two aware datetimes, which would hide the DST hour.
        before = helsinki("2026-10-18T09:00:00").astimezone(timezone.utc)
        across = RN.next_boundary(helsinki("2026-10-18T09:00:00")).astimezone(timezone.utc)
        self.assertEqual(across - before, timedelta(days=7, hours=1))

    def test_boundary_stays_at_0900_local_across_the_spring_forward(self):
        before = helsinki("2027-03-21T09:00:00")
        across = RN.next_boundary(before)
        self.assertEqual(across, helsinki("2027-03-28T09:00:00"))
        self.assertEqual(across.hour, 9)
        self.assertEqual(across.utcoffset(), timedelta(hours=3))


class LoadTest(unittest.TestCase):
    def test_no_summaries_is_not_an_error(self):
        with temp_tree([]):
            self.assertEqual(RN.load_weeks(), [])

    def test_weeks_come_back_newest_first_with_derived_dates(self):
        with temp_tree([week_doc(0, **WEEK0), week_doc(1, **WEEK1), week_doc(2, **WEEK2)]):
            weeks = RN.load_weeks()
        self.assertEqual([w["week"] for w in weeks], [2, 1, 0])
        self.assertEqual(weeks[0]["startDate"], "2026-08-09")
        self.assertEqual(weeks[0]["endDate"], "2026-08-16")
        self.assertEqual(weeks[-1]["source"], "osgallery")

    def test_a_bad_file_fails_the_load_loudly(self):
        with temp_tree([week_doc(0, **WEEK0)]) as root:
            (root / "registry" / "release-notes" / "2026-08-07.json").write_text("{ not json")
            with self.assertRaises(SystemExit) as caught:
                RN.load_weeks()
        self.assertIn("not valid JSON", str(caught.exception))


WEEK0 = dict(
    title="The month the museum was built",
    start="2026-07-07T21:39:24+03:00",
    end="2026-08-07T14:37:08+03:00",
    summary=paragraphs(4, 650),
    source="osgallery",
    commitCount=713,
    codeLines=227784,
)
WEEK1 = dict(
    title="The museum opens its source",
    start="2026-08-07T14:37:08+03:00",
    end="2026-08-09T09:00:00+03:00",
    summary=paragraphs(3, 350),
    commitCount=16,
    codeLines=4967,
)
# Weeks must ABUT, so a fixture tree holding 0, 1 and 2 needs week 2 to start
# where week 1 ended. week_doc()'s own defaults are week 3's real span.
WEEK2 = dict(
    title="Twenty-two new machines",
    start="2026-08-09T09:00:00+03:00",
    end="2026-08-16T09:00:00+03:00",
    summary=paragraphs(3, 350),
    commitCount=281,
    codeLines=46149,
)


class Week0Test(unittest.TestCase):
    """Week 0 predates the public repo, so nothing may ask git about it."""

    def test_it_renders_without_git_and_carries_its_note(self):
        with temp_tree([week_doc(0, **WEEK0), week_doc(1, **WEEK1)]):
            RN.run_git = lambda args: self.fail(f"render must not touch git, called with {args}")
            try:
                self.assertEqual(RN.cmd_render(NOW), 0)
                archive = (RN.REPO_ROOT / "docs" / "RELEASE-NOTES.md").read_text()
            finally:
                del RN.run_git
        self.assertIn(RENDER.WEEK0_NOTE, archive)
        self.assertIn("## Week 0 · The month the museum was built · 2026-07-07 21:39", archive)
        # ... and the note belongs to week 0 alone.
        self.assertEqual(archive.count(RENDER.WEEK0_NOTE), 1)

    def test_brief_never_offers_week_0(self):
        # closed_spans() numbers from 1 at the first PUBLIC commit; week 0 is
        # not a span it can produce.
        spans = RN.closed_spans(helsinki("2026-08-07T14:37:08"), helsinki("2026-08-24T12:00:00"))
        self.assertNotIn(0, [n for n, _, _ in spans])


class RenderTest(unittest.TestCase):
    def test_render_then_check_round_trips(self):
        with temp_tree([week_doc(0, **WEEK0), week_doc(1, **WEEK1), week_doc(2, **WEEK2)]):
            self.assertEqual(RN.cmd_render(NOW), 0)
            self.assertEqual(RN.cmd_check(), 0)

    def test_check_is_red_when_an_output_drifted(self):
        with temp_tree([week_doc(0, **WEEK0), week_doc(1, **WEEK1)]) as root:
            RN.cmd_render(NOW)
            (root / "docs" / "RELEASE-NOTES.md").write_text("hand-edited\n")
            self.assertEqual(RN.cmd_check(), 1)

    def test_rendering_twice_changes_nothing(self):
        with temp_tree([week_doc(0, **WEEK0), week_doc(1, **WEEK1)]) as root:
            RN.cmd_render(NOW)
            once = {p: p.read_text() for p in root.rglob("*") if p.is_file()}
            RN.cmd_render(NOW)
            self.assertEqual({p: p.read_text() for p in root.rglob("*") if p.is_file()}, once)

    def test_a_gap_in_the_weeks_stops_the_render(self):
        # 0 and 2 with no 1 is a hole in the archive; refuse it outright.
        with temp_tree([week_doc(0, **WEEK0), week_doc(2)]), self.assertRaises(SystemExit):
            RN.cmd_render(NOW)

    def test_the_json_carries_the_locked_shape_and_no_sections(self):
        with temp_tree([week_doc(0, **WEEK0), week_doc(1, **WEEK1), week_doc(2, **WEEK2)]) as root:
            RN.cmd_render(NOW)
            doc = json.loads((root / "spa" / "public" / "release-notes.json").read_text())
        self.assertEqual(doc["cutoff"], RN.CUTOFF_LABEL)
        self.assertEqual([w["week"] for w in doc["weeks"]], [2, 1, 0])
        self.assertNotIn("sections", doc["weeks"][0])
        self.assertNotIn("entries", doc["weeks"][0])
        self.assertEqual(
            set(doc["weeks"][0]),
            {"week", "title", "start", "end", "startDate", "endDate", "commitCount", "codeLines", "summary", "bullets"},
        )
        self.assertEqual(doc["weeks"][-1]["source"], "osgallery")

    def test_the_readme_shows_the_newest_week_in_full_and_links_the_rest(self):
        with temp_tree([week_doc(0, **WEEK0), week_doc(1, **WEEK1), week_doc(2, **WEEK2)]) as root:
            RN.cmd_render(NOW)
            readme = (root / "README.md").read_text()
        self.assertIn("### Week 2 · Twenty-two new machines · 2026-08-09 09:00 – 2026-08-16 09:00", readme)
        self.assertIn("A 1994 <u>SGI workstation</u> dialled out to a period web server", readme)
        self.assertIn(f"[Week 1 · The museum opens its source]({RENDER.ARCHIVE_PATH}#week-1)", readme)
        self.assertIn(f"[Week 0 · The month the museum was built]({RENDER.ARCHIVE_PATH}#week-0)", readme)
        # The reader-facing pages carry no maintainer scaffolding: no authoring
        # prompt, no `make release-notes`, no commit count. They point at the
        # gallery instead, which is the only thing a visitor can act on.
        self.assertNotIn(RENDER.PROMPT_PATH, readme)
        self.assertNotIn("make release-notes", readme)
        self.assertIn("kernelhive.madekivi.fi", readme)
        self.assertIn("46,149 lines of code", readme)
        # Highlights get their own heading — emitted bare they render INSIDE
        # "Quality improvements", which is what shipped in the first draft.
        self.assertIn("#### Also this week", readme)
        # An earlier week's prose stays in the archive, not the README.
        self.assertNotIn("### Week 1 ·", readme)

    def test_a_deleted_output_is_stale_not_a_traceback(self):
        # A bad merge that drops one rendered file must name it, not raise.
        for output in ("docs/RELEASE-NOTES.md", "spa/public/release-notes.json"):
            with temp_tree([week_doc(0, **WEEK0), week_doc(1, **WEEK1)]) as root:
                RN.cmd_render(NOW)
                (root / output).unlink()
                self.assertEqual(RN.cmd_check(), 1)

    def test_a_deleted_readme_says_what_to_restore(self):
        with temp_tree([week_doc(0, **WEEK0)]) as root:
            (root / "README.md").unlink()
            with self.assertRaises(SystemExit) as caught:
                RN.cmd_check()
        self.assertIn("README.md is missing", str(caught.exception))

    def test_a_week_that_has_not_closed_yet_is_called_out(self):
        # Only closed weeks are published; nothing stops a file dated forward,
        # so render says so rather than letting it pass in silence.
        with temp_tree([week_doc(0, **WEEK0), week_doc(1, **WEEK1), week_doc(2, **WEEK2)]) as root:
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                RN.cmd_render(helsinki("2026-08-12T12:00:00"))
            printed = printed.getvalue()
            # It is a warning, not a refusal: the outputs are still written.
            self.assertTrue((root / "docs" / "RELEASE-NOTES.md").read_text())
        self.assertIn("WARNING", printed)
        self.assertIn("week 2", printed)

    def test_an_empty_tree_renders_a_placeholder_instead_of_crashing(self):
        with temp_tree([]) as root:
            self.assertEqual(RN.cmd_render(NOW), 0)
            self.assertEqual(RN.cmd_check(), 0)
            readme = (root / "README.md").read_text()
        self.assertIn("No week has been written up yet", readme)


class ReadmeMarkerTest(unittest.TestCase):
    SECTION = "## Release notes\n\nBody line.\n"

    def test_insert_before_contributing_when_markers_are_absent(self):
        readme = "# Title\n\n## Building\n\nstuff\n\n## Contributing\n\nSee CONTRIBUTING.\n"
        out = RENDER.splice_readme(readme, self.SECTION)
        self.assertIn(RENDER.README_START, out)
        self.assertLess(out.index(RENDER.README_START), out.index("## Contributing"))
        self.assertGreater(out.index(RENDER.README_START), out.index("## Building"))
        self.assertIn("See CONTRIBUTING.", out)

    def test_splice_is_idempotent(self):
        readme = "# Title\n\n## Contributing\n\nSee CONTRIBUTING.\n"
        once = RENDER.splice_readme(readme, self.SECTION)
        self.assertEqual(RENDER.splice_readme(once, self.SECTION), once)

    def test_existing_block_is_replaced_not_appended(self):
        readme = "# Title\n\n## Contributing\n\nSee CONTRIBUTING.\n"
        once = RENDER.splice_readme(readme, self.SECTION)
        updated = RENDER.splice_readme(once, "## Release notes\n\nDifferent body.\n")
        self.assertEqual(updated.count(RENDER.README_START), 1)
        self.assertIn("Different body.", updated)
        self.assertNotIn("Body line.", updated)

    def test_a_half_eaten_marker_pair_is_a_loud_failure(self):
        # A merge conflict that eats one marker must not append a SECOND
        # release-notes block under a second heading.
        readme = "# Title\n\n## Contributing\n\nSee CONTRIBUTING.\n"
        once = RENDER.splice_readme(readme, self.SECTION)
        for lost in (RENDER.README_START, RENDER.README_END):
            with self.assertRaises(SystemExit):
                RENDER.splice_readme(once.replace(lost, ""), self.SECTION)

    def test_a_duplicated_block_is_a_loud_failure(self):
        # `check` compares the README against splice_readme(README, section), so
        # a splice that touched only the first pair would call this OK forever.
        readme = "# Title\n\n## Contributing\n\nSee CONTRIBUTING.\n"
        once = RENDER.splice_readme(readme, self.SECTION)
        block = RENDER.README_START + once.split(RENDER.README_START, 1)[1].split(RENDER.README_END, 1)[0]
        twice = once + "\n" + block + RENDER.README_END + "\n"
        with self.assertRaises(SystemExit) as caught:
            RENDER.splice_readme(twice, self.SECTION)
        self.assertIn("duplicated", str(caught.exception))

    def test_reversed_markers_are_a_loud_failure_not_a_traceback(self):
        readme = f"# Title\n\n{RENDER.README_END}\nbody\n{RENDER.README_START}\n\n## Contributing\n"
        with self.assertRaises(SystemExit) as caught:
            RENDER.splice_readme(readme, self.SECTION)
        self.assertIn("reversed", str(caught.exception))

    def test_missing_contributing_heading_is_a_loud_failure(self):
        with self.assertRaises(SystemExit):
            RENDER.splice_readme("# Title\n\nNothing to anchor to.\n", self.SECTION)

    def test_the_committed_readme_round_trips(self):
        readme = (REPO_ROOT / "README.md").read_text()
        self.assertIn(RENDER.README_START, readme)
        body = readme.split(RENDER.README_START, 1)[1].split(RENDER.README_END, 1)[0].lstrip("\n")
        self.assertEqual(RENDER.splice_readme(readme, body), readme)


class MarkdownEscapingTest(unittest.TestCase):
    def test_angle_bracket_placeholders_survive_githubs_sanitizer(self):
        # "<session>" is a valid CommonMark raw-HTML tag; unescaped, GitHub
        # deletes it and the line renders "/staging//".
        self.assertEqual(RENDER.md("staging (/staging/<session>/)"), r"staging (/staging/\<session>/)")

    def test_a_line_whose_backticks_do_not_pair_is_still_escaped(self):
        # An unmatched backtick matches no code span, so the whole line is prose.
        self.assertEqual(RENDER.md("` and then <session>"), r"` and then \<session>")

    def test_code_spans_are_left_alone(self):
        self.assertEqual(RENDER.md("run `a < b` now"), "run `a < b` now")

    def test_authored_prose_is_escaped_everywhere_it_is_placed(self):
        week = dict(week_doc(0, **WEEK0), bullets=["a <session> dir"], title="A <session> week")
        rendered = RENDER.render_archive([RN._decorate(week)], RN.CUTOFF_LABEL)
        self.assertIn(r"a \<session> dir", rendered)
        self.assertIn(r"A \<session> week", rendered)


class PluralTest(unittest.TestCase):
    def test_a_one_commit_week_does_not_say_commits(self):
        self.assertEqual(RENDER.plural(1, "commit", "commits"), "1 commit")
        self.assertEqual(RENDER.plural(0, "commit", "commits"), "0 commits")

    def test_week_heading_prints_both_boundary_times(self):
        self.assertEqual(
            RENDER.heading(week_doc(2, title="Twenty-two new machines")),
            "Week 2 · Twenty-two new machines · 2026-08-16 09:00 – 2026-08-23 09:00",
        )


if __name__ == "__main__":
    unittest.main()

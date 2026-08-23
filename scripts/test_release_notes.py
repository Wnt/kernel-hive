#!/usr/bin/env python3
"""Focused tests for the release-notes generator (scripts/release-notes.py).

Run directly: `python3 scripts/test_release_notes.py`, or
`python3 -m unittest discover -s scripts -p 'test_release_notes.py'`.

Covers the parts that are easy to get subtly wrong and expensive to notice: the
Sunday-09:00-Helsinki week boundary (exclusive end), DST correctness across the
October fallback, the scope -> section mapping, the Dependencies collapse,
README marker idempotency -- and the WINDOW, i.e. which commits the weeks are
cut from. That last one is tested against throwaway git repos built here in a
temp dir (GitWindowTest): the endpoints used to come from `git log` order, which
is COMMITTER-date order, while every bucketing decision uses the AUTHOR date, so
an ordinary rebase silently dropped commits out of the notes. No test depends on
this repo's actual git history, which changes with every commit.
"""

from __future__ import annotations

import contextlib
import importlib.machinery
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import release_notes_render as RENDER

REPO_ROOT = Path(__file__).resolve().parents[1]
RN = importlib.machinery.SourceFileLoader(
    "release_notes_under_test",
    str(REPO_ROOT / "scripts" / "release-notes.py"),
).load_module()

TZ = ZoneInfo("Europe/Helsinki")
STATIONS = {"tru64", "vic20", "w2kalpha", "hpuxvue", "chokanji", "c128", "mpf2"}


def helsinki(text: str) -> datetime:
    return datetime.fromisoformat(text).replace(tzinfo=TZ)


class BoundaryMathTest(unittest.TestCase):
    def test_first_boundary_is_the_next_sunday_0900(self):
        # 2026-08-07 is a Friday; the release commit is at 14:37 Helsinki.
        epoch = helsinki("2026-08-07T14:37:08")
        self.assertEqual(RN.first_boundary(epoch), helsinki("2026-08-09T09:00:00"))

    def test_epoch_on_a_sunday_before_0900_closes_that_same_morning(self):
        self.assertEqual(
            RN.first_boundary(helsinki("2026-08-09T08:59:59")),
            helsinki("2026-08-09T09:00:00"),
        )

    def test_epoch_exactly_on_a_boundary_rolls_to_the_following_sunday(self):
        # The boundary is an EXCLUSIVE end, so a 09:00:00 commit starts the
        # next week rather than closing the one it landed in.
        self.assertEqual(
            RN.first_boundary(helsinki("2026-08-09T09:00:00")),
            helsinki("2026-08-16T09:00:00"),
        )

    def test_commit_exactly_on_a_boundary_belongs_to_the_next_week(self):
        start, end = helsinki("2026-08-09T09:00:00"), helsinki("2026-08-16T09:00:00")
        on_boundary = helsinki("2026-08-16T09:00:00")
        self.assertFalse(start <= on_boundary < end)
        self.assertTrue(end <= on_boundary < RN.next_boundary(end))

    def test_boundaries_accept_a_non_helsinki_input_timezone(self):
        epoch = datetime.fromisoformat("2026-08-07T11:37:08+00:00")
        self.assertEqual(RN.first_boundary(epoch), helsinki("2026-08-09T09:00:00"))


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
        self.assertEqual(
            across.astimezone(timezone.utc) - before.astimezone(timezone.utc),
            timedelta(days=7) - timedelta(hours=1),
        )


class ClassificationTest(unittest.TestCase):
    def classify(self, subject: str, author: str = "Jonni Madekivi"):
        return RN.classify(subject, author, STATIONS)

    def test_registry_station_id_lands_in_stations(self):
        self.assertEqual(self.classify("tru64: web browser applied"), ("Stations", "tru64"))

    def test_locked_aliases(self):
        cases = {
            "spa: installable PWA": "Gallery UI",
            "streamhost: paced keyframes": "Streaming daemon",
            "retronet: bring up the web plane": "Retronet",
            "docs: rewrite the playbook": "Docs",
            "registry: one home per value": "Tooling & infrastructure",
            "scripts: tidy the dev CLIs": "Tooling & infrastructure",
        }
        for subject, section in cases.items():
            self.assertEqual(self.classify(subject)[0], section, subject)

    def test_multi_part_scopes_fold_onto_their_bucket(self):
        self.assertEqual(self.classify("docs/research: vom reference")[0], "Docs")
        self.assertEqual(self.classify("retronet-bot: reconnect")[0], "Retronet")
        self.assertEqual(self.classify("retronet/web: bare Content-Type")[0], "Retronet")
        self.assertEqual(self.classify("ctlsock+tools: reset path")[0], "Streaming daemon")
        self.assertEqual(self.classify("box-sync-push: pair table")[0], "Tooling & infrastructure")

    def test_station_alias_reports_the_current_station_id(self):
        self.assertEqual(self.classify("alpha-nt: idle profile"), ("Stations", "w2kalpha"))

    def test_unknown_scope_and_prefix_less_subjects_fall_to_other(self):
        self.assertEqual(self.classify("wibble: something new")[0], "Other")
        self.assertEqual(self.classify("we need pinball sites too"), ("Other", None))
        # An uppercase prefix is not a scope token under the locked regex.
        self.assertEqual(self.classify("HUD: show the tier"), ("Other", None))

    def test_dependabot_author_is_load_bearing(self):
        # Dependabot writes bare "bump ..." subjects too; only the author says
        # what they are.
        self.assertEqual(self.classify("bump @react-three/drei", "dependabot[bot]"), ("Dependencies", None))
        self.assertEqual(self.classify("bump @react-three/drei")[0], "Other")

    def test_a_deps_scope_is_a_dependency_bump_whoever_wrote_it(self):
        subject = "build(deps): bump the cargo group in /streamhost with 3 updates"
        self.assertEqual(self.classify(subject, "dependabot[bot]"), ("Dependencies", None))
        # A human holding a bump back is still dependency work, not Gallery UI.
        self.assertEqual(self.classify("deps(spa): hold typescript at 6.0.3"), ("Dependencies", None))

    def test_conventional_commit_type_decides_before_its_inner_scope(self):
        self.assertEqual(self.classify("docs(rel-pointer): file the brief")[0], "Docs")
        self.assertEqual(self.classify("feat(tru64): serial exec"), ("Stations", "tru64"))

    def test_bump_the_group_subject_also_counts(self):
        self.assertEqual(self.classify("Bump the actions group with 2 updates")[0], "Dependencies")

    def test_bullet_text_strips_the_scope_and_upper_cases(self):
        self.assertEqual(RN.bullet_text("tru64: web browser applied"), "Web browser applied")
        self.assertEqual(RN.bullet_text("tmp"), "Tmp")

    def test_a_scope_phrase_classifies_but_is_not_stripped(self):
        # "retronet web: ..." was 21% of the archive falling into Other.
        self.assertEqual(self.classify("retronet web: bare Content-Type")[0], "Retronet")
        self.assertEqual(self.classify("chokanji poster: real capture")[0], "Stations")
        self.assertEqual(self.classify("c128 + c64 fixtures: the four keys"), ("Stations", "c128"))
        # Stripping it would lose "poster" / "web", so the text stays whole.
        self.assertEqual(RN.bullet_text("chokanji poster: real capture", STATIONS), "chokanji poster: real capture")

    def test_prose_opening_with_a_station_id_is_station_work(self):
        self.assertEqual(self.classify("tru64 joins the retronet web plane: rtl8139, static ip"), ("Stations", "tru64"))
        self.assertEqual(self.classify("hpuxvue + tru64 keymaps from KEYDUMP")[0], "Stations")
        # ... but a common English word opening a sentence is NOT a scope.
        self.assertEqual(self.classify("make the gate green before done"), ("Other", None))

    def test_a_stations_label_is_always_a_registry_id(self):
        # The raw scope would render as an `mpf2/kc854` chip in the SPA, where
        # every other chip is a station id.
        self.assertEqual(self.classify("mpf2/kc854: keymaps from KEYDUMP"), ("Stations", "mpf2"))

    def test_recase_keeps_names_that_own_their_spelling(self):
        self.assertEqual(RN.bullet_text("workflow: stage.sh per-session staging"), "stage.sh per-session staging")
        self.assertEqual(RN.bullet_text("vice wave: one binary generation"), "VICE wave: one binary generation")
        self.assertEqual(RN.bullet_text("mame-native launcher: sta/"), "MAME-native launcher: sta/")
        self.assertEqual(RN.bullet_text("wip: vic20", STATIONS), "vic20")
        # Everything else still gets a capital.
        self.assertEqual(RN.bullet_text("docs: rewrite the playbook"), "Rewrite the playbook")


class RenderingTest(unittest.TestCase):
    def data(self) -> dict:
        week = {
            "number": 1,
            "start": "2026-08-07T14:37:08+03:00",
            "end": "2026-08-09T09:00:00+03:00",
            "startDate": "2026-08-07",
            "endDate": "2026-08-09",
            "inProgress": False,
            "commitCount": 5,
            "sections": [
                {
                    "title": "Stations",
                    "count": 1,
                    "entries": [
                        {"scope": "vic20", "text": "Add the Commodore VIC-20", "sha": "abcdef1", "date": "2026-08-08"}
                    ],
                },
                {"title": "Dependencies", "count": 4, "entries": [], "collapsed": True},
            ],
        }
        return {
            "cutoff": RN.CUTOFF_LABEL,
            "epoch": "2026-08-07T14:37:08+03:00",
            "generatedFrom": "abcdef1",
            "weeks": [week],
        }

    def test_dependencies_render_as_one_collapsed_line(self):
        archive = RENDER.render_archive(self.data())
        self.assertIn("4 dependency bumps.", archive)
        self.assertNotIn("Bump the", archive)
        self.assertEqual(archive.count("dependency bumps"), 1)

    def test_archive_links_each_bullet_to_its_commit(self):
        archive = RENDER.render_archive(self.data())
        self.assertIn(f"[`abcdef1`]({RENDER.COMMIT_URL}abcdef1)", archive)
        self.assertIn("**vic20** — Add the Commodore VIC-20", archive)

    def test_readme_digest_counts_collapsed_bumps_in_the_and_n_more_tail(self):
        readme = RENDER.render_readme_section(self.data())
        self.assertIn("Stations 1, Dependencies 4", readme)
        # One bullet is rendered; the four collapsed bumps stay in the tail.
        self.assertIn("…and 4 more", readme)


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
        twice = RENDER.splice_readme(once, self.SECTION)
        self.assertEqual(once, twice)

    def test_existing_block_is_replaced_not_appended(self):
        readme = "# Title\n\n## Contributing\n\nSee CONTRIBUTING.\n"
        once = RENDER.splice_readme(readme, self.SECTION)
        updated = RENDER.splice_readme(once, "## Release notes\n\nDifferent body.\n")
        self.assertEqual(updated.count(RENDER.README_START), 1)
        self.assertIn("Different body.", updated)
        self.assertNotIn("Body line.", updated)

    def test_a_half_eaten_marker_pair_is_a_loud_failure(self):
        # A merge conflict that eats one marker must not append a SECOND
        # changelog under a second heading.
        readme = "# Title\n\n## Contributing\n\nSee CONTRIBUTING.\n"
        once = RENDER.splice_readme(readme, self.SECTION)
        for lost in (RENDER.README_START, RENDER.README_END):
            with self.assertRaises(SystemExit):
                RENDER.splice_readme(once.replace(lost, ""), self.SECTION)

    def test_missing_contributing_heading_is_a_loud_failure(self):
        with self.assertRaises(SystemExit):
            RENDER.splice_readme("# Title\n\nNothing to anchor to.\n", self.SECTION)

    def test_the_committed_readme_round_trips(self):
        readme = (REPO_ROOT / "README.md").read_text()
        self.assertIn(RENDER.README_START, readme)
        body = readme.split(RENDER.README_START, 1)[1].split(RENDER.README_END, 1)[0].lstrip("\n")
        self.assertEqual(RENDER.splice_readme(readme, body), readme)


class DigestSelectionTest(unittest.TestCase):
    """The README digest is a WEEK'S HIGHLIGHTS, not the head of `git log`."""

    def week(self, sections: list[dict], count: int = 40) -> dict:
        return {"commitCount": count, "sections": sections}

    def section(self, title: str, entries: list[tuple[str | None, str]]) -> dict:
        return {
            "title": title,
            "count": len(entries),
            "entries": [
                {"scope": scope, "text": text, "sha": f"sha{i}", "date": "2026-08-23"}
                for i, (scope, text) in enumerate(entries)
            ],
        }

    def test_bullets_are_spread_across_sections_not_taken_from_the_first(self):
        week = self.week(
            [
                self.section("Stations", [("tru64", "One"), ("tru64", "Two"), ("vic20", "Three")]),
                self.section("Retronet", [("retronet", "Four")]),
                self.section("Docs", [("docs", "Five")]),
            ]
        )
        picked = RENDER.digest_entries(week, 3)
        self.assertEqual([e["text"] for e in picked], ["One", "Four", "Five"])

    def test_one_bullet_per_scope_before_a_scope_repeats(self):
        week = self.week([self.section("Stations", [("tru64", "One"), ("tru64", "Two"), ("vic20", "Three")])])
        picked = RENDER.digest_entries(week, 2)
        self.assertEqual([e["scope"] for e in picked], ["tru64", "vic20"])

    def test_a_rebased_duplicate_subject_is_shown_once(self):
        week = self.week([self.section("Docs", [("docs", "Same"), ("docs", "Same"), ("docs", "Other")])])
        self.assertEqual([e["text"] for e in RENDER.digest_entries(week, 3)], ["Same", "Other"])

    def test_placeholder_subjects_are_last_in_line(self):
        week = self.week([self.section("Other", [("wip", "Wip: indyr4400"), (None, "Real work")])])
        self.assertEqual([e["text"] for e in RENDER.digest_entries(week, 1)], ["Real work"])

    def test_the_tail_counts_every_commit_the_digest_did_not_show(self):
        week = self.week([self.section("Docs", [("docs", "One"), ("docs", "Two")])], count=40)
        rendered = RENDER.render_readme_section(
            {
                "weeks": [
                    dict(
                        week,
                        number=3,
                        start="2026-08-16T09:00:00+03:00",
                        end="2026-08-23T09:00:00+03:00",
                        startDate="2026-08-16",
                        endDate="2026-08-23",
                        inProgress=False,
                    )
                ]
            }
        )
        self.assertIn("…and 38 more", rendered)


class ArchiveDuplicateTest(unittest.TestCase):
    def test_the_same_subject_twice_is_one_bullet_with_both_shas(self):
        entries = [
            {"scope": "workflow", "text": "stage.sh staging", "sha": "acb1671", "date": "2026-08-15"},
            {"scope": "workflow", "text": "stage.sh staging", "sha": "7987a5d", "date": "2026-08-15"},
            {"scope": "workflow", "text": "Something else", "sha": "1111111", "date": "2026-08-15"},
        ]
        collapsed = RENDER.collapse_duplicates(entries)
        self.assertEqual([e["shas"] for e in collapsed], [["acb1671", "7987a5d"], ["1111111"]])


class MarkdownEscapingTest(unittest.TestCase):
    def test_angle_bracket_placeholders_survive_githubs_sanitizer(self):
        # "<session>" is a valid CommonMark raw-HTML tag; unescaped, GitHub
        # deletes it and the bullet renders "/staging//".
        self.assertEqual(RENDER.md("staging (/staging/<session>/)"), r"staging (/staging/\<session>/)")

    def test_code_spans_are_left_alone(self):
        self.assertEqual(RENDER.md("run `a < b` now"), "run `a < b` now")


class PluralTest(unittest.TestCase):
    def test_a_one_commit_week_does_not_say_commits(self):
        self.assertEqual(RENDER.plural(1, "commit", "commits"), "1 commit")
        self.assertEqual(RENDER.plural(0, "commit", "commits"), "0 commits")

    def test_week_heading_prints_both_boundary_times(self):
        week = {
            "number": 2,
            "start": "2026-08-09T09:00:00+03:00",
            "end": "2026-08-16T09:00:00+03:00",
            "inProgress": False,
        }
        self.assertEqual(RENDER.week_heading(week), "Week 2 · 2026-08-09 09:00 – 2026-08-16 09:00")


def _git(repo: Path, *args: str, **env: str) -> str:
    environ = dict(
        os.environ,
        GIT_AUTHOR_NAME="T",
        GIT_AUTHOR_EMAIL="t@example.com",
        GIT_COMMITTER_NAME="T",
        GIT_COMMITTER_EMAIL="t@example.com",
        **env,
    )
    done = subprocess.run(
        ["git", "-C", str(repo), "-c", "commit.gpgsign=false", *args],
        check=True,
        capture_output=True,
        text=True,
        env=environ,
    )
    return done.stdout


@contextlib.contextmanager
def temp_repo():
    """A throwaway git repo, with RN pointed at it for the duration."""
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        _git(repo, "init", "-q", "-b", "main")
        original = RN.REPO_ROOT
        RN.REPO_ROOT = repo
        try:
            yield repo
        finally:
            RN.REPO_ROOT = original


def add_commit(repo: Path, subject: str, authored: str, committed: str | None = None) -> None:
    (repo / "log.txt").write_text(subject)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", subject, GIT_AUTHOR_DATE=authored, GIT_COMMITTER_DATE=committed or authored)


class GitWindowTest(unittest.TestCase):
    """Every commit read must land in exactly one week.

    The window used to be `commits[-1]` .. `commits[0]` of `git log`, i.e.
    COMMITTER-date order, while bucketing uses the AUTHOR date. A rebase, a
    cherry-pick or a skewed clock then put a commit outside the window and it
    vanished from all three outputs with a clean exit code.
    """

    NOW = "2026-08-23T12:00:00+03:00"

    def build(self, repo: Path) -> dict:
        return RN.build(now=datetime.fromisoformat(self.NOW).astimezone(TZ))

    def bucketed(self, data: dict) -> int:
        return sum(week["commitCount"] for week in data["weeks"])

    def test_a_plain_rebase_reorder_keeps_every_commit(self):
        # No clock skew at all: `q` was committed after `p` but authored before
        # it, which is all `git log` needs to sort them the other way round.
        with temp_repo() as repo:
            add_commit(repo, "seed", "2026-08-13T10:00:00+03:00")
            add_commit(repo, "p: after the sunday boundary", "2026-08-16T09:30:00+03:00")
            add_commit(repo, "q: before it", "2026-08-16T08:50:00+03:00", "2026-08-16T10:00:00+03:00")
            data = self.build(repo)
        self.assertEqual(self.bucketed(data), 3)
        texts = [e["text"] for w in data["weeks"] for s in w["sections"] for e in s["entries"]]
        self.assertIn("After the sunday boundary", texts)
        self.assertEqual(len(data["weeks"]), 2)

    def test_an_am_of_an_older_patch_is_kept_and_invents_no_weeks(self):
        with temp_repo() as repo:
            add_commit(repo, "seed", "2026-08-13T10:00:00+03:00")
            add_commit(
                repo,
                "old: authored long before the repo existed",
                "2019-04-01T10:00:00+03:00",
                "2026-08-14T10:00:00+03:00",
            )
            data = self.build(repo)
        self.assertEqual(self.bucketed(data), 2)
        self.assertEqual(len(data["weeks"]), 1)
        self.assertEqual(data["epoch"], "2026-08-13T10:00:00+03:00")

    def test_a_future_author_date_does_not_manufacture_empty_weeks(self):
        with temp_repo() as repo:
            add_commit(repo, "seed", "2026-08-13T10:00:00+03:00")
            add_commit(repo, "skewed: authored months ahead", "2026-11-20T10:00:00+03:00", "2026-08-14T10:00:00+03:00")
            data = self.build(repo)
        self.assertEqual(self.bucketed(data), 2)
        self.assertEqual(len(data["weeks"]), 1)

    def test_a_wholly_skewed_clock_is_pulled_back_to_now(self):
        # Both stamps ahead: the box's clock is wrong, not just the author date.
        with temp_repo() as repo:
            add_commit(repo, "seed", "2026-08-13T10:00:00+03:00")
            add_commit(repo, "skewed: the whole commit is in the future", "2026-11-20T10:00:00+03:00")
            data = self.build(repo)
        self.assertEqual(self.bucketed(data), 2)
        # Three real weeks between the seed and `now`, and not one more: the
        # commit sits in the in-progress week, not in a November week of its own.
        self.assertEqual(len(data["weeks"]), 3)
        self.assertTrue(data["weeks"][0]["inProgress"])
        self.assertEqual(data["weeks"][0]["commitCount"], 1)

    def test_the_conservation_guard_fails_loudly(self):
        weeks = [{"commitCount": 2}, {"commitCount": 1}]
        RN.assert_conserved(weeks, [{}] * 3)  # conserved: no raise
        with self.assertRaises(SystemExit):
            RN.assert_conserved(weeks, [{}] * 4)


if __name__ == "__main__":
    unittest.main()

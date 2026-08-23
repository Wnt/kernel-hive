#!/usr/bin/env python3
"""Tests for the emulator-fork half of the release notes (release_notes_forks).

Run directly: `python3 scripts/test_release_notes_forks.py`, or
`python3 -m unittest discover -s scripts -p 'test_*.py'`.

NOTHING HERE TOUCHES THE NETWORK. `gather()` takes its subprocess runner as an
argument, so every test hands it a fake: canned TSV rows, or a runner that
raises the way a missing or unauthenticated `gh` does. The behaviour under test
is the filtering — ours vs upstream, shipped vs experimental, inside the week vs
outside — plus the two things that must never regress: an unreachable fork is
REPORTED, and a commit GitHub could not attribute is REPORTED rather than
dropped. The offline pin-drift half lives in test_release_notes_pins.py.
"""

from __future__ import annotations

import json
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import release_notes_forks as FORKS

TZ = ZoneInfo("Europe/Helsinki")
REPO_ROOT = Path(__file__).resolve().parents[1]
START = datetime(2026, 8, 16, 9, 0, tzinfo=TZ)
END = datetime(2026, 8, 23, 9, 0, tzinfo=TZ)
TARGET = FORKS.Target("Wnt/vice", "kernel-hive/integrated", "VICE patches")


def row(
    sha: str,
    login: str,
    when: str,
    subject: str,
    committed: str | None = None,
    name: str = "Jonni",
    email: str = "jonni@example.com",
) -> str:
    return "\t".join([sha, login, name, email, when, committed or when, subject])


def commit(
    sha="a" * 40,
    login="Wnt",
    when=START + timedelta(days=1),
    subject="shmfb: publish finished frames",
    name="Jonni",
    email="jonni@example.com",
):
    return FORKS.ForkCommit(TARGET.repo, TARGET.branch, sha, login, when, subject, name, email)


def sources(*, authors=("Wnt", "jonni-reaktor"), marker=FORKS.DEFAULT_MARKER, targets=(TARGET,), identities=()):
    return FORKS.Sources(authors, marker, targets, identities)


SOURCES_DOC = {
    "ourAuthors": ["Wnt"],
    "ourCommitAuthors": ["Kernel Hive lab"],
    "forks": [
        {
            "repo": "Wnt/vice",
            "what": "VICE patches for the Commodore stations",
            "branches": [{"name": "kernel-hive/integrated", "pinnedBy": ["build.sh"]}],
            "excludes": [{"branch": "trial", "why": "a trial branch no station ever ran"}],
        }
    ],
}


class SelectionTest(unittest.TestCase):
    def test_only_our_authors_survive(self):
        picked = FORKS.select_commits(
            [commit(login="Wnt"), commit(login="cuavas"), commit(login="", name="Nobody")],
            sources(),
            START,
            END,
        )
        self.assertEqual([c.login for c in picked.ours], ["Wnt"])
        self.assertEqual([c.name for c in picked.unattributed], ["Nobody"])

    def test_the_second_declared_author_counts_too(self):
        picked = FORKS.select_commits([commit(login="jonni-reaktor")], sources(), START, END)
        self.assertEqual(len(picked.ours), 1)

    def test_logins_are_matched_case_insensitively(self):
        # GitHub logins are case-insensitive, and the API has handed back both
        # spellings; a case slip must not silently drop a week's work.
        self.assertTrue(FORKS.is_ours("wNt", ("Wnt",)))
        self.assertFalse(FORKS.is_ours("", ("Wnt",)))
        self.assertFalse(FORKS.is_ours("Wnt-bot", ("Wnt",)))

    def test_a_commit_with_no_login_is_ours_when_its_author_is_declared(self):
        # The real regression: work pushed straight from the lab box reaches
        # GitHub with author.login == null, and used to vanish from the brief.
        lab = commit(login="", name="Kernel Hive lab", email="lab@example.com")
        picked = FORKS.select_commits([lab], sources(identities=("Kernel Hive lab",)), START, END)
        self.assertEqual([c.short for c in picked.ours], [lab.short])
        self.assertEqual(picked.unattributed, [])

    def test_a_declared_identity_matches_on_the_email_too_and_ignores_case(self):
        by_email = commit(login="", name="whoever", email="LAB@example.com")
        picked = FORKS.select_commits([by_email], sources(identities=("lab@example.com",)), START, END)
        self.assertEqual(len(picked.ours), 1)

    def test_a_resolved_login_that_is_not_ours_is_upstream_not_a_question(self):
        # Only a MISSING login is undecidable; a login GitHub resolved is an
        # answer, and it is "upstream".
        picked = FORKS.select_commits([commit(login="cuavas", name="Kernel Hive lab")], sources(), START, END)
        self.assertEqual((picked.ours, picked.unattributed), ([], []))

    def test_an_unattributed_commit_is_never_silently_dropped(self):
        picked = FORKS.select_commits([commit(login="", name="root")], sources(), START, END)
        self.assertEqual(picked.ours, [])
        self.assertEqual([c.name for c in picked.unattributed], ["root"])
        text = "\n".join(FORKS.format_section(sources(), picked, []))
        self.assertIn("DECIDE BY HAND", text)
        self.assertIn("(root)", text)
        self.assertIn("ourCommitAuthors", text)
        self.assertNotIn("no commits of ours landed", text)

    def test_experimental_subjects_are_dropped_whoever_wrote_them(self):
        picked = FORKS.select_commits(
            [
                commit(subject="tlb: hint cache [experimental, not shipped]"),
                commit(login="", subject="tlb: hint cache [experimental, not shipped]"),
                commit(subject="shmfb: publish finished frames"),
            ],
            sources(),
            START,
            END,
        )
        self.assertEqual([c.subject for c in picked.ours], ["shmfb: publish finished frames"])
        self.assertEqual(picked.unattributed, [])

    def test_the_window_is_half_open_at_both_ends(self):
        picked = FORKS.select_commits(
            [
                commit(sha="before", when=START - timedelta(seconds=1)),
                commit(sha="start", when=START),
                commit(sha="end", when=END),
            ],
            sources(),
            START,
            END,
        )
        self.assertEqual([c.sha for c in picked.ours], ["start"])

    def test_a_commit_is_bucketed_by_the_earlier_of_its_two_dates(self):
        # Same rule as the local log: a rebase moves the committer date forward,
        # and the week the work was done is the author date.
        rows = row("a" * 40, "Wnt", "2026-08-17T10:00:00Z", "vicectl: a unix control socket", "2026-09-01T10:00:00Z")
        parsed = FORKS.parse_rows(rows, TARGET, TZ)
        self.assertEqual(parsed[0].stamp, datetime(2026, 8, 17, 13, 0, tzinfo=TZ))
        self.assertEqual(len(FORKS.select_commits(parsed, sources(), START, END).ours), 1)


class ParseRowsTest(unittest.TestCase):
    def test_a_subject_containing_a_tab_is_not_truncated(self):
        parsed = FORKS.parse_rows(row("b" * 40, "Wnt", "2026-08-17T10:00:00Z", "crtc:\tno resize"), TARGET, TZ)
        self.assertEqual(parsed[0].subject, "crtc:\tno resize")
        self.assertEqual(parsed[0].short, "bbbbbbb")

    def test_the_author_identity_survives_the_tsv(self):
        parsed = FORKS.parse_rows(
            row("c" * 40, "", "2026-08-17T10:00:00Z", "shmfb", name="Kernel Hive lab", email="lab@example.com"),
            TARGET,
            TZ,
        )
        self.assertEqual((parsed[0].name, parsed[0].email), ("Kernel Hive lab", "lab@example.com"))

    def test_blank_and_short_lines_are_ignored_rather_than_crashing(self):
        self.assertEqual(FORKS.parse_rows("\n\nnot-a-row\n", TARGET, TZ), [])


class GatherTest(unittest.TestCase):
    def test_a_missing_gh_is_reported_and_never_fails_the_brief(self):
        def no_gh(argv):
            raise FORKS.Unreachable("`gh` is not installed on this machine")

        picked, missing = FORKS.gather(sources(), START, END, TZ, runner=no_gh)
        self.assertEqual(picked.ours, [])
        self.assertEqual([gap.target.repo for gap in missing], ["Wnt/vice"])
        text = "\n".join(FORKS.format_section(sources(), picked, missing))
        self.assertIn("WARNING", text)
        self.assertIn("COULD NOT BE REACHED", text)
        self.assertIn("Wnt/vice kernel-hive/integrated", text)
        self.assertIn("gh auth login", text)

    def test_the_recovery_line_is_the_command_that_actually_ran(self):
        # It used to be a hand-copied near-miss without `-X GET`, which makes gh
        # POST and answer 404 — the operator reads that as "the branch is gone".
        def no_gh(argv):
            raise FORKS.Unreachable("HTTP 401: Bad credentials")

        picked, missing = FORKS.gather(sources(), START, END, TZ, runner=no_gh)
        text = "\n".join(FORKS.format_section(sources(), picked, missing))
        self.assertEqual(list(missing[0].argv), FORKS.gh_argv(TARGET, START, END))
        self.assertIn("gh api -X GET repos/Wnt/vice/commits", text)

    def test_one_unreachable_fork_does_not_lose_the_reachable_one(self):
        good = FORKS.Target("Wnt/es40", "main", "es40 patches")
        rows = row("c" * 40, "Wnt", "2026-08-18T09:00:00Z", "ctlsock: per-guest pointer gain")

        def half_up(argv):
            if "repos/Wnt/es40/commits" in argv:
                return rows + "\n"
            raise FORKS.Unreachable("HTTP 401: Bad credentials")

        picked, missing = FORKS.gather(sources(targets=(TARGET, good)), START, END, TZ, runner=half_up)
        self.assertEqual([c.repo for c in picked.ours], ["Wnt/es40"])
        self.assertEqual([gap.target.repo for gap in missing], ["Wnt/vice"])
        self.assertIn("Bad credentials", "\n".join(FORKS.format_section(sources(), picked, missing)))

    def test_the_fetch_asks_for_the_declared_branch_and_pads_the_window(self):
        argv = FORKS.gh_argv(TARGET, START, END)
        self.assertIn("repos/Wnt/vice/commits", argv)
        self.assertIn("sha=kernel-hive/integrated", argv)
        self.assertIn(f"since={START.isoformat()}", argv)
        self.assertIn(f"until={(END + FORKS.FETCH_SLACK).isoformat()}", argv)
        self.assertEqual(argv[2:4], ["-X", "GET"])

    def test_commits_come_back_newest_first_and_grouped_by_repo(self):
        rows = "\n".join(
            [
                row("d" * 40, "Wnt", "2026-08-17T10:00:00Z", "older"),
                row("e" * 40, "Wnt", "2026-08-19T10:00:00Z", "newer"),
                row("f" * 40, "upstream", "2026-08-19T10:00:00Z", "not ours"),
            ]
        )
        picked, missing = FORKS.gather(sources(), START, END, TZ, runner=lambda argv: rows)
        self.assertEqual([c.subject for c in picked.ours], ["newer", "older"])
        self.assertEqual(missing, [])
        text = "\n".join(FORKS.format_section(sources(), picked, missing))
        self.assertIn("Wnt/vice (kernel-hive/integrated) — 2 commits", text)
        self.assertIn("Wnt/vice  eeeeeee  newer", text)
        self.assertNotIn("not ours", text)

    def test_an_unreachable_week_never_reads_as_an_idle_one(self):
        # "nothing landed" and "nothing could be fetched" are different weeks and
        # only one of them is safe to write up.
        argv = tuple(FORKS.gh_argv(TARGET, START, END))
        missing = [FORKS.Unreached(TARGET, "`gh` is not installed on this machine", argv)]
        text = "\n".join(FORKS.format_section(sources(), FORKS.Selection(), missing))
        self.assertIn("INCOMPLETE", text)
        self.assertIn("nothing gathered", text)
        self.assertNotIn("no commits of ours landed", text)

    def test_run_gh_turns_a_missing_binary_into_unreachable_not_a_traceback(self):
        with self.assertRaises(FORKS.Unreachable) as caught:
            FORKS.run_gh(["/nonexistent/gh", "api"])
        self.assertIn("not installed", str(caught.exception))

    def test_run_gh_reports_the_first_error_line_a_failing_gh_printed(self):
        # e.g. an installed but unauthenticated gh. A local shell stands in for
        # it: no network, no gh, same failure shape.
        with self.assertRaises(FORKS.Unreachable) as caught:
            FORKS.run_gh(["/bin/sh", "-c", "echo 'HTTP 401: Bad credentials' >&2; exit 1"])
        self.assertEqual(str(caught.exception), "HTTP 401: Bad credentials")

    def test_an_empty_week_says_so_instead_of_printing_nothing(self):
        text = "\n".join(FORKS.format_section(sources(), FORKS.Selection(), []))
        self.assertIn("EMULATOR FORKS — 0 commits", text)
        self.assertIn("no commits of ours landed", text)


class DeclarationTest(unittest.TestCase):
    def test_the_committed_declaration_parses_and_covers_the_four_forks(self):
        loaded = FORKS.load_sources(REPO_ROOT)
        self.assertEqual(sorted(loaded.our_authors), ["Wnt", "jonni-reaktor"])
        self.assertEqual(
            sorted({t.repo for t in loaded.targets}),
            ["Wnt/es40", "Wnt/mame", "Wnt/qemu", "Wnt/vice"],
        )
        self.assertIn(("Wnt/mame", "irix"), [(t.repo, t.branch) for t in loaded.targets])
        self.assertIn(("Wnt/mame", "mpf2"), [(t.repo, t.branch) for t in loaded.targets])

    def test_the_lab_box_identity_is_declared_so_its_commits_are_not_lost(self):
        self.assertTrue(FORKS.load_sources(REPO_ROOT).our_commit_authors)

    def test_no_excluded_trial_branch_is_ever_gathered(self):
        branches = {(t.repo, t.branch) for t in FORKS.load_sources(REPO_ROOT).targets}
        self.assertNotIn(("Wnt/mame", "irix-experimental"), branches)
        self.assertNotIn(("Wnt/es40", "tlb-hint-experimental"), branches)

    def test_an_exclusion_without_a_reason_is_refused(self):
        doc = json.loads(json.dumps(SOURCES_DOC))
        doc["forks"][0]["excludes"] = [{"branch": "trial"}]
        with self.assertRaises(SystemExit) as caught:
            FORKS.parse_sources(doc, Path("sources.json"))
        self.assertIn("why", str(caught.exception))

    def test_a_branch_without_a_pin_citation_is_refused(self):
        doc = json.loads(json.dumps(SOURCES_DOC))
        doc["forks"][0]["branches"] = [{"name": "kernel-hive/integrated"}]
        with self.assertRaises(SystemExit) as caught:
            FORKS.parse_sources(doc, Path("sources.json"))
        self.assertIn("pinnedBy", str(caught.exception))

    def test_an_empty_author_list_is_refused_rather_than_matching_everyone(self):
        doc = json.loads(json.dumps(SOURCES_DOC))
        doc["ourAuthors"] = []
        with self.assertRaises(SystemExit):
            FORKS.parse_sources(doc, Path("sources.json"))

    def test_a_malformed_identity_list_is_refused(self):
        doc = json.loads(json.dumps(SOURCES_DOC))
        doc["ourCommitAuthors"] = "Kernel Hive lab"
        with self.assertRaises(SystemExit) as caught:
            FORKS.parse_sources(doc, Path("sources.json"))
        self.assertIn("ourCommitAuthors", str(caught.exception))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Tests for `publish`'s tag-commit resolution (release-notes.py's
`resolve_week_commit`, backed by release_notes_publish.py).

Split from test_release_notes.py, which now covers the week maths and
rendering; this file's addition (the `publish` subcommand) would have pushed
that file over the repo's 600-line file-size cap. Proved against a fake `git
log`/`show`, never this repo's own history, so it stays fast and
deterministic regardless of how many commits this repo has by the time it
runs.
"""

from __future__ import annotations

import unittest

# RN and helsinki come from the sibling module, not a second importlib load —
# see its own comment on why that matters (two module objects patching
# different REPO_ROOTs would make this fail for reasons unrelated to the code).
from test_release_notes import RN, helsinki  # noqa: E402


def _fake_run_git(rows: list[tuple[str, str, str]]):
    """A stand-in for RN.run_git that answers only the calls `publish` makes:
    the root-commit lookup, a single commit's stamp, and the sha-carrying log.
    `rows` is `(sha, author-date-iso, subject)`, oldest first or not — order
    does not matter, the functions under test sort by stamp themselves."""
    by_sha = {sha: (stamp, subject) for sha, stamp, subject in rows}

    def run(args: list[str]) -> str:
        if args[:3] == ["rev-list", "--max-parents=0", "HEAD"]:
            return rows[0][0] + "\n"
        if args[0] == "show":
            sha = args[-1]
            stamp, subject = by_sha[sha]
            return f"{stamp}\x1f{stamp}\x1f{subject}\n"
        if args[0] == "log":
            fmt = args[-1]
            with_sha = fmt.startswith("--format=%H")
            lines = []
            for sha, stamp, subject in rows:
                if with_sha:
                    lines.append(f"{sha}\x1f{stamp}\x1f{stamp}\x1f{subject}")
                else:
                    lines.append(f"{stamp}\x1f{stamp}\x1f{subject}")
            return "\n".join(lines) + "\n"
        raise AssertionError(f"unexpected git call: {args}")

    return run


COMMIT_LOG = [
    ("root1", "2026-08-07T14:37:08+03:00", "the open-source release"),
    ("c1", "2026-08-08T10:00:00+03:00", "c1 subject"),
    ("c2", "2026-08-15T10:00:00+03:00", "c2 subject"),
    ("c3", "2026-08-20T10:00:00+03:00", "c3 subject"),
]


class TagCommitResolutionTest(unittest.TestCase):
    """`publish` points week-<N> at the last commit before that week's `end`,
    stamped the same clamped way `brief` buckets by — proved here against a
    fake `git log`/`show`, never this repo's real history."""

    def setUp(self):
        self._orig = RN.run_git
        RN.run_git = _fake_run_git(COMMIT_LOG)

    def tearDown(self):
        RN.run_git = self._orig

    def test_week_zero_resolves_to_the_repos_first_public_commit(self):
        now = helsinki("2026-09-01T12:00:00")
        self.assertEqual(RN.resolve_week_commit(now, 0, helsinki("2026-08-07T14:37:08")), "root1")

    def test_a_later_week_resolves_to_the_last_commit_before_its_end(self):
        now = helsinki("2026-09-01T12:00:00")
        self.assertEqual(RN.resolve_week_commit(now, 1, helsinki("2026-08-09T09:00:00")), "c1")
        self.assertEqual(RN.resolve_week_commit(now, 2, helsinki("2026-08-16T09:00:00")), "c2")

    def test_two_weeks_may_resolve_to_the_same_commit(self):
        # A stub week that closed with nothing new committed since the repo
        # opened is not an error — see week 0 vs week 1 in the real history.
        now = helsinki("2026-09-01T12:00:00")
        self.assertEqual(
            RN.resolve_week_commit(now, 0, helsinki("2026-08-07T14:37:08")),
            RN.resolve_week_commit(now, 1, helsinki("2026-08-08T09:00:00")),
        )

    def test_no_eligible_commit_is_a_loud_failure(self):
        now = helsinki("2026-09-01T12:00:00")
        with self.assertRaises(SystemExit):
            RN.resolve_week_commit(now, 1, helsinki("2026-08-01T00:00:00"))


if __name__ == "__main__":
    unittest.main()

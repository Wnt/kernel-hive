#!/usr/bin/env python3
"""Tests for the offline pin tripwire (release_notes_pins).

Run directly: `python3 scripts/test_release_notes_pins.py`, or
`python3 -m unittest discover -s scripts -p 'test_*.py'`.

NOTHING HERE TOUCHES THE NETWORK, and nothing reads git — that is the whole
point of this half: `scripts/release-notes.py check` runs it on every render, so
it must be a plain parse of the working tree and stay deterministic.

The behaviour under test is that a REPOINTED BUILD GOES RED. A branch name lives
on in comments and echo lines long after the build stopped using it, so the pin
is parsed rather than searched for, and both directions are walked: a cited file
that no longer pins its branch, and a branch the tree pins that nobody declared.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import release_notes_pins as PINS

REPO_ROOT = Path(__file__).resolve().parents[1]
# What the tree really pins, in the mechanical formats the sweep parses.
GITMODULES = (
    '[submodule "third_party/vice"]\n\tpath = third_party/vice\n'
    "\turl = https://github.com/Wnt/vice.git\n\tbranch = kernel-hive/integrated\n"
)
BUILD_SH = (
    'VICE_FORK_URL="${VICE_FORK_URL:-https://github.com/Wnt/vice.git}"\nVICE_FORK_BRANCH=kernel-hive/integrated\n'
)
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


def temp_declaration(tmp: str, build: str = BUILD_SH) -> Path:
    root = Path(tmp)
    (root / PINS.SOURCES_PATH.parent).mkdir(parents=True)
    (root / PINS.SOURCES_PATH).write_text(json.dumps(SOURCES_DOC))
    (root / "build.sh").write_text(build)
    return root


class PinFormatTest(unittest.TestCase):
    def test_a_gitmodules_pin_is_read_per_submodule_section(self):
        self.assertEqual(PINS.gitmodules_pins(GITMODULES), {("Wnt/vice", "kernel-hive/integrated")})

    def test_a_shell_pin_pairs_url_and_branch_by_their_prefix(self):
        self.assertEqual(PINS.shell_pins(BUILD_SH), {("Wnt/vice", "kernel-hive/integrated")})
        # The unprefixed spelling, and a ${VAR:-default} on both halves.
        text = 'FORK_URL="${FORK_URL:-https://github.com/Wnt/qemu.git}"\nFORK_BRANCH="${FORK_BRANCH:-kernel-hive}"\n'
        self.assertEqual(PINS.shell_pins(text), {("Wnt/qemu", "kernel-hive")})

    def test_a_station_entry_pins_through_its_emulator_source(self):
        doc = json.dumps({"emulator": {"source": "github.com/Wnt/es40 main — no commit pinned in the repo"}})
        self.assertEqual(PINS.json_pins(doc), {("Wnt/es40", "main")})

    def test_prose_that_merely_names_a_branch_is_not_a_pin(self):
        # The whole point: the old name lives on in comments and echo lines long
        # after the build was repointed, so a substring scan calls drift clean.
        self.assertEqual(PINS.shell_pins("# github.com/Wnt/mame, branch `irix`\necho irix\n"), set())


class DriftTest(unittest.TestCase):
    def test_the_committed_tree_and_declaration_agree_in_both_directions(self):
        self.assertEqual(PINS.drift_errors(REPO_ROOT), [])

    def test_a_build_repointed_at_another_branch_is_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = temp_declaration(tmp, build=BUILD_SH.replace("kernel-hive/integrated", "kernel-hive/shmfb"))
            drift = PINS.pin_errors(root)
            self.assertEqual(len(drift), 1)
            self.assertIn("drifted", drift[0])
            self.assertIn("kernel-hive/shmfb", drift[0])
            (root / "build.sh").write_text(BUILD_SH)
            self.assertEqual(PINS.pin_errors(root), [])

    def test_a_cited_file_that_names_the_branch_but_pins_nothing_is_drift(self):
        # The old check passed on any file that merely contained both strings.
        with tempfile.TemporaryDirectory() as tmp:
            root = temp_declaration(tmp, build="# github.com/Wnt/vice branch kernel-hive/integrated\n")
            self.assertIn("no fork branch at all", PINS.pin_errors(root)[0])

    def test_a_pin_citing_a_deleted_file_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / PINS.SOURCES_PATH.parent).mkdir(parents=True)
            (root / PINS.SOURCES_PATH).write_text(json.dumps(SOURCES_DOC))
            self.assertIn("does not exist", PINS.pin_errors(root)[0])

    def test_a_branch_the_tree_pins_but_nobody_declared_is_reported(self):
        # The other direction: declaration -> build alone never notices a new
        # fork branch, and every later week is quietly short of it.
        with tempfile.TemporaryDirectory() as tmp:
            root = temp_declaration(tmp)
            (root / ".gitmodules").write_text(GITMODULES.replace("kernel-hive/integrated", "kernel-hive/next"))
            errors = PINS.undeclared_pins(root)
            self.assertEqual(len(errors), 1)
            self.assertIn("does not declare", errors[0])
            self.assertIn("kernel-hive/next", errors[0])

    def test_a_build_repointed_at_an_EXCLUDED_branch_says_exactly_that(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = temp_declaration(tmp)
            (root / ".gitmodules").write_text(GITMODULES.replace("kernel-hive/integrated", "trial"))
            errors = PINS.undeclared_pins(root)
            self.assertEqual(len(errors), 1)
            self.assertIn("EXCLUDES", errors[0])

    def test_a_fork_that_is_not_ours_is_not_swept(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = temp_declaration(tmp)
            (root / ".gitmodules").write_text(GITMODULES.replace("Wnt/vice", "mamedev/mame"))
            self.assertEqual(PINS.undeclared_pins(root), [])

    def test_an_unreadable_declaration_is_an_error_not_a_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / PINS.SOURCES_PATH.parent).mkdir(parents=True)
            (root / PINS.SOURCES_PATH).write_text("{not json")
            self.assertIn("cannot be read", PINS.drift_errors(root)[0])


if __name__ == "__main__":
    unittest.main()

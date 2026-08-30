"""The recipe-vs-published-form check must actually decide, not just skip.

The failure class it exists for is the one that is INVISIBLE until a build:
`git apply` of a file-creating patch fails only once the file exists, so a
published fork that has moved under the patch series has no symptom at all.
A check for that is worthless if its own "ok" is really "I could not look", so
these tests drive the deciding leg against real git trees.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("pfd", REPO / "scripts" / "lint" / "published-form-drift.py")
pfd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pfd)


def _git(*args, cwd):
    return subprocess.run(["git", *args], cwd=str(cwd), capture_output=True, text=True, check=True)


class PublishedCarriesThePatch(unittest.TestCase):
    """`_published_carries` is the whole answer to 'without a build attempt'."""

    def _fork_with(self, files: dict[str, str]) -> Path:
        d = Path(self.tmp) / "fork"
        d.mkdir()
        _git("init", "-q", cwd=d)
        _git("config", "user.email", "t@t.t", cwd=d)
        _git("config", "user.name", "t", cwd=d)
        for name, body in files.items():
            (d / name).parent.mkdir(parents=True, exist_ok=True)
            (d / name).write_text(body)
        _git("add", "-A", cwd=d)
        _git("commit", "-qm", "published", cwd=d)
        return d

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        # A file-CREATING patch: the exact shape whose divergence is silent.
        self.patch = Path(self.tmp) / "0001-add.patch"
        self.patch.write_text(
            "Index: b/hw/misc/thing.c\n"
            "===================================================================\n"
            "--- /dev/null\n"
            "+++ b/hw/misc/thing.c\n"
            "@@ -0,0 +1,2 @@\n"
            "+int a(void) { return 1; }\n"
            "+/* kernel-hive */\n"
        )

    def tearDown(self):
        self._tmp.cleanup()

    def test_matching_published_tree_is_carried(self):
        fork = self._fork_with({"hw/misc/thing.c": "int a(void) { return 1; }\n/* kernel-hive */\n"})
        self.assertTrue(pfd._published_carries(fork, "HEAD", self.patch))

    def test_diverged_published_tree_is_detected_without_building(self):
        """The fork moved under the series — the incident, caught with no build."""
        fork = self._fork_with({"hw/misc/thing.c": "int a(void) { return 2; }\n/* moved on */\n"})
        self.assertFalse(pfd._published_carries(fork, "HEAD", self.patch))

    def test_missing_file_is_detected(self):
        fork = self._fork_with({"README": "nothing here\n"})
        self.assertFalse(pfd._published_carries(fork, "HEAD", self.patch))


class ItIsAReportNotAGate(unittest.TestCase):
    def test_offline_with_no_fork_exits_zero(self):
        """A check nobody can satisfy teaches SKIP_GATE=1. Unreadable input = 0."""
        argv = sys.argv
        cwd = os.getcwd()
        try:
            sys.argv = ["published-form-drift.py", "--offline", "--fork", "/nonexistent"]
            self.assertEqual(pfd.main(), 0)
        finally:
            sys.argv = argv
            os.chdir(cwd)

    def test_not_wired_into_the_push_gate(self):
        gate = (REPO / ".claude" / "hooks" / "pre-push-gate.sh").read_text()
        self.assertNotIn("published-form-drift", gate)


if __name__ == "__main__":
    unittest.main()

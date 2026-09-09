"""The offline box-sync pair self-check, and the validate hook that runs it.

`scripts/lib/box-sync-pairs.sh` is the one declaration of every repo→box mirror
pair, and until now nothing could read it without labhost — so a duplicate row,
a repo file that had moved, or a launcher-called helper nobody paired stayed
invisible until a deploy or a station that would not start. beos, w2kalpha and
rhapsody each lost a boot cycle to the last one.

The self-check runs the real loader against an EMPTY box root, so these tests
need no ssh and no /data.
"""

from __future__ import annotations

import os
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))

from stations_registry.validate_pairs import pairs_files_changed, validate_pairs  # noqa: E402

SELFCHECK = REPO / "scripts/dev/box-sync-pairs-selfcheck.sh"


def selfcheck(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(SELFCHECK), *args],
        cwd=REPO,
        capture_output=True,
        text=True,
        # Without this the check re-enters itself: box_sync_load_pairs renders
        # the registry, render() validates, and validate() runs this hook.
        env=dict(os.environ, KH_PAIRS_SELFCHECK="never"),
    )


class SelfcheckTest(unittest.TestCase):
    def test_the_committed_pair_table_is_clean(self) -> None:
        result = selfcheck()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no duplicate label or destination", result.stdout)

    def test_it_needs_no_box(self) -> None:
        """No ssh, and no /data path outside the temp box root it makes itself."""
        text = SELFCHECK.read_text()
        self.assertIn("local", text)
        self.assertNotIn("ssh ", text)
        self.assertNotIn("$LAB", text)

    def test_verbose_lists_every_pair_with_its_mode_and_authority(self) -> None:
        result = selfcheck("--verbose")
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [line for line in result.stdout.splitlines() if line.startswith("  ")]
        self.assertGreater(len(rows), 100)
        for row in rows:
            self.assertRegex(row, r"\b(exact|scrub)\b")
            self.assertRegex(row, r"\b(repo|box)\b")

    def test_a_launcher_helper_with_no_pair_is_a_breach(self) -> None:
        """The trap the coverage rule exists for, proved by making one.

        A network-link helper the launcher calls ships nowhere unless a pair row
        or a registry auxFiles entry names it, and the launcher then dies on
        start at `bash "$B/rn-tapnet.sh" up`.

        `wi-tapnet.sh`, not `rn-tapnet.sh`: the retronet helpers are covered by a
        GLOB over the station tree, so a new one is paired the moment it exists.
        The walk-in taps are still a hand-written id list, which is exactly the
        shape that goes stale — so that is the one worth proving.
        """
        planted = REPO / "streamhost/stations/zzpairtest/wi-tapnet.sh"
        planted.parent.mkdir(parents=True, exist_ok=True)
        planted.write_text("#!/usr/bin/env bash\n:\n")
        try:
            # git ls-files only sees tracked/staged paths, so stage it.
            subprocess.run(["git", "add", "-N", str(planted)], cwd=REPO, check=True)
            result = selfcheck()
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("zzpairtest", result.stdout)
            self.assertIn("reaches no station dir", result.stdout)
        finally:
            subprocess.run(["git", "reset", "-q", "--", str(planted)], cwd=REPO, check=False)
            planted.unlink(missing_ok=True)
            planted.parent.rmdir()


class ValidateHookTest(unittest.TestCase):
    def test_the_hook_is_off_unless_the_pair_table_changed(self) -> None:
        """Scoping, not laziness: a gate must be satisfiable by whoever it blocks."""
        errors: list[str] = []
        os.environ["KH_PAIRS_SELFCHECK"] = "never"
        try:
            validate_pairs([], errors)
        finally:
            del os.environ["KH_PAIRS_SELFCHECK"]
        self.assertEqual(errors, [])

    def test_forced_mode_runs_it_and_the_tree_is_green(self) -> None:
        errors: list[str] = []
        os.environ["KH_PAIRS_SELFCHECK"] = "always"
        try:
            validate_pairs([], errors)
        finally:
            del os.environ["KH_PAIRS_SELFCHECK"]
        self.assertEqual(errors, [])

    def test_changed_detection_looks_at_the_pair_table_only(self) -> None:
        for path in pairs_files_changed():
            self.assertRegex(path, r"^scripts/lib/box-sync-pairs.*\.sh$")


if __name__ == "__main__":
    unittest.main()

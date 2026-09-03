"""`station-land.sh --dry-run` must print the whole landing and touch nothing.

The dry run is not a convenience here, it is the only way to exercise this
script at all: every other mode pushes to main, deploys to labhost and swaps a
live station's disk. So the contract these tests hold it to is that --dry-run
reaches the last step, names every stage a wave hand-ran on 2026-09-03, and
issues no command — no ssh, no push, no write — along the way.
"""

from __future__ import annotations

import os
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/dev/station-land.sh"
#: a real, landed station: the script refuses an id with no registry row.
STATION = "suse64"


def land(*args: str, session: str = "testwave") -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        cwd=REPO,
        capture_output=True,
        text=True,
        env=dict(os.environ, KH_SESSION=session),
    )


class DryRunTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dirty_before = subprocess.run(
            ["git", "status", "--porcelain"], cwd=REPO, capture_output=True, text=True
        ).stdout

    def test_a_full_dry_run_reaches_the_end_and_changes_nothing(self) -> None:
        result = land(STATION, "--dry-run", "--golden", "/data/staged/x.qcow2", "--x11warp", "10.0.0.1:0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("14 release the landing window", result.stdout)
        after = subprocess.run(["git", "status", "--porcelain"], cwd=REPO, capture_output=True, text=True).stdout
        self.assertEqual(after, self.dirty_before, "a dry run modified the working tree")

    def test_every_hand_run_landing_stage_is_named(self) -> None:
        result = land(STATION, "--dry-run", "--golden", "/data/staged/x.qcow2")
        for stage in (
            "take the landing window",
            "fetch + merge origin/main",
            "rebuild the SPA scene rows",
            "regenerate, validate, vitest",
            "commit + push",
            "box-deploy",
            "golden disk",
            "smoke rig",
            "station-up",
            "re-home claims",
            "proofs",
            "SPA build + deploy",
            "dark-launch overlays",
        ):
            self.assertIn(stage, result.stdout, stage)

    def test_a_dry_run_issues_no_command_at_all(self) -> None:
        """`run()` prints `+ cmd` when it executes and `WOULD RUN:` when it does not."""
        result = land(STATION, "--dry-run", "--golden", "/data/staged/x.qcow2")
        executed = [line for line in result.stdout.splitlines() if line.startswith("   + ")]
        self.assertEqual(executed, [], "a dry run executed something")
        self.assertGreater(len([x for x in result.stdout.splitlines() if "WOULD RUN" in x]), 10)

    def test_the_golden_swap_parks_the_live_disk_before_copying(self) -> None:
        """Launcher and disk are ONE unit: the old disk must survive the swap."""
        result = land(STATION, "--dry-run", "--golden", "/data/staged/x.qcow2")
        park = next(line for line in result.stdout.splitlines() if "disk.qcow2.pre-" in line and "mv " in line)
        copy = next(line for line in result.stdout.splitlines() if "cp --reflink=auto" in line)
        self.assertLess(result.stdout.index(park), result.stdout.index(copy))
        self.assertIn("rollback", result.stdout.lower())

    def test_it_says_what_to_do_when_wave_sh_is_absent(self) -> None:
        if (REPO / "scripts/dev/wave.sh").exists():
            self.skipTest("wave.sh has landed; the fallback path is no longer reachable here")
        result = land(STATION, "--dry-run")
        self.assertIn("no wave.sh, serialise by hand", result.stdout)


class RefusalTest(unittest.TestCase):
    def test_it_refuses_an_unknown_station(self) -> None:
        result = land("zznosuchstation", "--dry-run")
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not exist", result.stderr)

    def test_an_unset_session_is_resolved_not_left_blank(self) -> None:
        """kh-session.sh always derives one (branch name here), so the guard is a backstop.

        Worth pinning anyway: the claim re-homing and the shot path are both
        built from $KH_SESSION, and a blank one would silently write to
        /data/vms/sandbox//<id>-landed.png and re-home nothing.
        """
        result = land(STATION, "--dry-run", session="")
        self.assertEqual(result.returncode, 0, result.stderr)
        session_line = next(line for line in result.stdout.splitlines() if "session " in line)
        self.assertNotIn("<unset>", session_line)
        self.assertIn(f"station-{STATION}", session_line)

    def test_it_refuses_a_relative_golden_path(self) -> None:
        """The path is resolved ON THE BOX, so a relative one would mean the wrong file."""
        result = land(STATION, "--dry-run", "--golden", "staged/x.qcow2")
        self.assertEqual(result.returncode, 1)
        self.assertIn("absolute path", result.stderr)


if __name__ == "__main__":
    unittest.main()

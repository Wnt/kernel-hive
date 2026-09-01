#!/usr/bin/env python3
"""checkpoint-guard's rollback must never report a rollback it did not perform.

THE INCIDENT THESE PIN. `cpg_journal_write` re-renders the whole journal from the
in-memory `CPG_BACKUPS`, and `cpg_resume` never runs `cpg_backup`. So a run that
was interrupted and finished with `resume` wrote `"backups": []` over the rows
the `recapture` had correctly recorded -- ERASING the only note of where the
rollback copy lives, while the copy itself sat on disk beside the station.

That alone would be an unavailable rollback. What made it dangerous is that every
loop in `cpg_rollback` is a `while read` over those rows, so with none of them it
verified nothing and said "Every recorded backup verified, so the rollback is
available", and under `CPG_ROLLBACK_CONFIRM=1` it restored nothing, deleted the
journal, and logged "ROLLED BACK to the pre-recapture disks." A false success on
the incident path ends the investigation instead of starting it.

Found on aix432, 2026-08-31, by the coordinator checking a reported rollback
against the tool instead of taking it on trust.

These tests drive the REAL bash functions against a temporary stations root
(`CPG_STATIONS_ROOT`), never a station.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

GUARD = Path(__file__).resolve().parent / "lib" / "checkpoint-guard.sh"


def sh(script: str, env: dict[str, str], cwd: str) -> subprocess.CompletedProcess:
    """Source the guard and run `script` against it."""
    return subprocess.run(
        ["bash", "-c", f'set +e; source "{GUARD}"\n{script}'],
        capture_output=True,
        text=True,
        env={**os.environ, **env},
        cwd=cwd,
    )


class GuardFixture:
    """A stations root holding one stopped, qcow2-backed fake station."""

    def __init__(self, tmp: str, backups: list[dict] | None):
        self.root = Path(tmp) / "stations"
        self.dir = self.root / "faketile"
        self.dir.mkdir(parents=True)
        self.disk = self.dir / "faketile-golden.qcow2"
        self.disk.write_bytes(b"CURRENT-DISK-CONTENT")
        (self.dir / "station.env").write_text("SH_RESET_MODE=loadvm\n")
        (self.dir / "qemu-streamhost.sh").write_text(f"#!/bin/bash\nqemu-system-x86_64 -drive file={self.disk} -m 64\n")
        self.journal = self.dir / ".checkpoint-guard.json"
        self.write_journal(backups)

    def write_journal(self, backups: list[dict] | None) -> None:
        """Emit the guard's OWN journal shape, not merely valid JSON.

        `_cpg_journal_backup_rows` reads the array with a line-oriented `sed`, so
        each row must sit whole on ONE line exactly as `cpg_journal_write` prints
        it. Pretty-printed JSON parses fine and reads as ZERO rows -- which is the
        same silent-empty state these tests exist to make impossible.
        """
        rows = ",".join(
            f'\n    {{"disk": "{b["disk"]}", "backup": "{b["backup"]}", "sha256": "{b["sha256"]}"}}'
            for b in (backups or [])
        )
        tail = "\n  " if rows else ""
        self.journal.write_text(
            '{\n  "state": "done",\n  "station": "faketile",\n'
            '  "label": "golden",\n  "staging_label": "cpg-staging",\n'
            '  "session": "test",\n  "ts": "2026-08-31T00:00:00Z",\n'
            f'  "backups": [{rows}{tail}]\n}}\n'
        )

    def add_backup(self, content: bytes = b"PRE-RECAPTURE-DISK") -> dict:
        bak = self.dir / "faketile-golden.qcow2.cpg-bak-20260101T000000Z"
        bak.write_bytes(content)
        return {
            "disk": str(self.disk),
            "backup": str(bak),
            "sha256": hashlib.sha256(content).hexdigest(),
        }

    def env(self) -> dict[str, str]:
        return {"CPG_STATIONS_ROOT": str(self.root)}


class RollbackRefusesWithoutRecordedBackups(unittest.TestCase):
    """Zero rows is a refusal, not an empty success."""

    def test_refuses_and_says_so(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            f = GuardFixture(tmp, backups=[])
            r = sh("cpg_rollback faketile", f.env(), tmp)
            self.assertNotEqual(r.returncode, 0, "zero recorded backups must be an ERROR")
            self.assertIn("REFUSED", r.stderr)
            self.assertIn("NO backups", r.stderr)
            # The two sentences that made the old behaviour dangerous.
            self.assertNotIn("rollback is available", r.stderr)
            self.assertNotIn("ROLLED BACK", r.stderr)
            self.assertTrue(f.journal.exists(), "a refusal must not delete the journal")

    def test_confirm_does_not_turn_it_into_a_false_success(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            f = GuardFixture(tmp, backups=[])
            env = {**f.env(), "CPG_ROLLBACK_CONFIRM": "1"}
            r = sh("cpg_rollback faketile", env, tmp)
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn("ROLLED BACK", r.stderr)
            self.assertTrue(f.journal.exists(), "nothing restored -> journal must survive")
            self.assertEqual(f.disk.read_bytes(), b"CURRENT-DISK-CONTENT", "nothing may be restored")

    def test_names_where_to_look_for_the_orphaned_copy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            f = GuardFixture(tmp, backups=[])
            f.add_backup()
            r = sh("cpg_rollback faketile", f.env(), tmp)
            self.assertIn("cpg-bak-", r.stderr, "must point at the files still on disk")
            self.assertIn("checkpoint-guard status", r.stderr)


class RollbackVerifiesRecordedBackups(unittest.TestCase):
    """A populated journal still behaves exactly as before."""

    def test_verifies_then_refuses_without_confirm(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            f = GuardFixture(tmp, backups=None)
            row = f.add_backup()
            f.write_journal([row])
            r = sh("cpg_rollback faketile", f.env(), tmp)
            self.assertNotEqual(r.returncode, 0, "no CPG_ROLLBACK_CONFIRM -> refuse")
            self.assertIn("backup still verifies", r.stderr)
            self.assertIn("rollback is available", r.stderr)

    def test_refuses_a_backup_whose_bytes_changed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            f = GuardFixture(tmp, backups=None)
            row = f.add_backup()
            f.write_journal([row])
            Path(row["backup"]).write_bytes(b"TAMPERED")
            r = sh("cpg_rollback faketile", f.env(), tmp)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("no longer hashes", r.stderr)

    def test_confirmed_rollback_restores_and_reports_the_count(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            f = GuardFixture(tmp, backups=None)
            row = f.add_backup()
            f.write_journal([row])
            env = {**f.env(), "CPG_ROLLBACK_CONFIRM": "1"}
            r = sh("cpg_rollback faketile", env, tmp)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("ROLLED BACK 1 disk", r.stderr)
            self.assertEqual(f.disk.read_bytes(), b"PRE-RECAPTURE-DISK")
            self.assertFalse(f.journal.exists(), "a real rollback consumes the journal")


class ResumeKeepsTheBackupRows(unittest.TestCase):
    """The erasure itself: a journal rewrite must not drop the recorded rows."""

    def test_journal_write_without_the_loader_erases(self) -> None:
        """Pin the mechanism, so the fix cannot be removed as 'defensive'."""
        with tempfile.TemporaryDirectory() as tmp:
            f = GuardFixture(tmp, backups=None)
            row = f.add_backup()
            f.write_journal([row])
            r = sh(
                'cpg_resolve faketile && CPG_BACKUPS="" cpg_journal_write done',
                f.env(),
                tmp,
            )
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(
                json.loads(f.journal.read_text())["backups"],
                [],
                "this is the bug being guarded against; if it ever stops "
                "erasing, cpg_journal_load_backups may be redundant",
            )

    def test_loader_round_trips_the_rows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            f = GuardFixture(tmp, backups=None)
            row = f.add_backup()
            f.write_journal([row])
            r = sh(
                "cpg_resolve faketile && cpg_journal_load_backups && cpg_journal_write done",
                f.env(),
                tmp,
            )
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(json.loads(f.journal.read_text())["backups"], [row])

    def test_resume_calls_the_loader(self) -> None:
        """cpg_resume must load the rows BEFORE its first journal write."""
        raw = subprocess.run(
            ["sed", "-n", "/^cpg_resume()/,/^}/p", str(GUARD)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        # Comments MENTION cpg_journal_write; only executable lines order it.
        body = "\n".join(ln for ln in raw.splitlines() if not ln.lstrip().startswith("#"))
        self.assertIn("cpg_journal_load_backups", body)
        self.assertLess(
            body.index("cpg_journal_load_backups"),
            body.index("cpg_journal_write"),
            "the load must precede any journal rewrite, or the rows are gone",
        )


if __name__ == "__main__":
    unittest.main()

"""loaded-drift — the check that did not exist for the gap it measures.

Incident I.13: a serve process running since 2026-08-26 against 42 files written
2026-08-30, on a publicly-open plane, with every other signal truthfully green
about a different question.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "host"))

from kh_reconciler.loaded import drift_for, parse_probe, render  # noqa: E402


class TheGap(unittest.TestCase):
    def test_files_written_after_the_process_started_are_stale(self):
        d = drift_for("serve-code", 1000.0, {"a.py": 900.0, "b.py": 1100.0, "c.py": 1200.0})
        self.assertFalse(d.clean)
        self.assertEqual([p for p, _ in d.stale], ["b.py", "c.py"])
        self.assertEqual(d.scanned, 3)

    def test_a_process_newer_than_every_file_is_clean(self):
        d = drift_for("serve-code", 2000.0, {"a.py": 900.0, "b.py": 1100.0})
        self.assertTrue(d.clean)

    def test_same_second_is_not_evidence(self):
        """A check that manufactures findings from clock granularity gets ignored."""
        self.assertTrue(drift_for("u", 1000.0, {"a.py": 1000.0}).clean)

    def test_FRACTIONAL_mtime_against_a_whole_second_process_start(self):
        """The real false positive, 2026-08-31: `find -printf %T@` is
        fractional, /proc/<pid> is whole seconds, and install-then-restart
        inside one second is the NORMAL deploy sequence."""
        self.assertTrue(drift_for("u", 1788152288.0, {"a.py": 1788152288.4231}).clean)

    def test_but_a_genuinely_later_second_is_still_caught(self):
        self.assertFalse(drift_for("u", 1788152288.0, {"a.py": 1788152289.0}).clean)

    def test_the_oldest_stale_write_drives_the_reported_age(self):
        d = drift_for("u", 100.0, {"a.py": 500.0, "b.py": 200.0})
        self.assertEqual(d.oldest_stale, 200.0)

    def test_an_unreadable_process_start_SKIPS_rather_than_claiming_clean(self):
        """Zero must not read as 'the process is newer than everything'."""
        d = drift_for("u", 0.0, {"a.py": 500.0})
        self.assertIn("SKIPPED", render(d, 1000.0)[0])

    def test_the_report_names_the_signal_that_is_green_and_useless(self):
        d = drift_for("serve-code", 100.0, {"a.py": 500.0})
        text = " ".join(render(d, 4000.0))
        self.assertIn("APPLIED-BUT-NOT-LOADED", text)
        self.assertIn("is-active", text)


class ProbeParsing(unittest.TestCase):
    def test_a_well_formed_probe(self):
        start, files = parse_probe("ts\n---\n1700000000\n---\n1699999000\n---\n1699999500.0 /s/a.py\n")
        self.assertEqual(start, 1699999000.0)
        self.assertEqual(files, {"/s/a.py": 1699999500.0})

    def test_a_truncated_probe_yields_no_start_and_no_files(self):
        start, files = parse_probe("garbage")
        self.assertEqual(start, 0.0)
        self.assertEqual(files, {})

    def test_unparseable_mtimes_are_dropped_not_guessed(self):
        _, files = parse_probe("x\n---\n1\n---\n100\n---\nNOPE /s/a.py\n200 /s/b.py\n")
        self.assertEqual(files, {"/s/b.py": 200.0})

    def test_the_real_incident_shape(self):
        """Process older than the files: 42 of them, on a live public plane."""
        start = 1756170612.0  # 2026-08-26 03:10
        files = {f"/serve/f{i}.py": 1756582975.0 for i in range(42)}  # 2026-08-30 21:42
        files.update({f"/serve/old{i}.py": 1756000000.0 for i in range(569)})
        d = drift_for("serve-code", start, files)
        self.assertEqual(len(d.stale), 42)
        self.assertEqual(d.scanned, 611)


if __name__ == "__main__":
    unittest.main()

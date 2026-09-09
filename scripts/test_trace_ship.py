#!/usr/bin/env python3
"""Tests for the daemon-span shipper.

Which files it picks up and in what order is a pure function of a directory,
so it is pinned here. The POST itself is not exercised: the collector is the
serving plane's own route and has its own tests in scripts/test_traces.py.
"""

import importlib.machinery
import json
import pathlib
import tempfile
import unittest
from unittest import mock

SHIP = importlib.machinery.SourceFileLoader(
    "trace_ship_under_test",
    str(pathlib.Path(__file__).resolve().parents[0] / "observability" / "trace-ship.py"),
).load_module()


def spool(root, station, name, spans=1):
    d = pathlib.Path(root) / station / "traces"
    d.mkdir(parents=True, exist_ok=True)
    body = {"resource": {"session.id": "unknown"}, "spans": [{"n": f"s{i}"} for i in range(spans)]}
    (d / name).write_text(json.dumps(body))
    return d / name


class BatchesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_every_station_spool_is_found(self):
        spool(self.root, "helenos", "1788200000932-1-000000.json")
        spool(self.root, "alpine", "1788200000001-2-000000.json")
        self.assertEqual({s for s, _ in SHIP.batches(self.root)}, {"alpine", "helenos"})

    def test_batches_of_one_station_come_out_oldest_first(self):
        spool(self.root, "helenos", "1788200000932-1-000001.json")
        spool(self.root, "helenos", "1788200000932-1-000000.json")
        names = [p.name for _, p in SHIP.batches(self.root)]
        self.assertEqual(names, sorted(names))

    def test_a_half_written_file_is_not_picked_up(self):
        d = self.root / "helenos" / "traces"
        d.mkdir(parents=True)
        (d / "1788200000932-1-000000.json.tmp.7").write_text("{partial")
        self.assertEqual(SHIP.batches(self.root), [])

    def test_a_station_with_no_spool_directory_is_simply_absent(self):
        (self.root / "helenos").mkdir()
        self.assertEqual(SHIP.batches(self.root), [])

    def test_record_count_reads_the_batch(self):
        # `span_count` became `record_count(path, key)` when the shipper gained
        # a second lane: the same spool carrier now moves log batches too.
        p = spool(self.root, "helenos", "a.json", spans=3)
        self.assertEqual(SHIP.record_count(p, "spans"), 3)

    def test_an_unreadable_batch_counts_zero_rather_than_raising(self):
        d = self.root / "helenos" / "traces"
        d.mkdir(parents=True)
        (d / "b.json").write_text("{not json")
        self.assertEqual(SHIP.record_count(d / "b.json", "spans"), 0)


class PlanTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_a_plan_run_sends_nothing_and_deletes_nothing(self):
        p = spool(self.root, "helenos", "a.json")
        self.assertEqual(SHIP.main(["--stations", str(self.root)]), 0)
        self.assertTrue(p.exists())

    def test_an_empty_tree_is_success_not_an_error(self):
        self.assertEqual(SHIP.main(["--stations", str(self.root)]), 0)

    def test_a_missing_station_tree_fails_loudly(self):
        self.assertEqual(SHIP.main(["--stations", str(self.root / "nope")]), 1)


class ShipTest(unittest.TestCase):
    """Exercises --apply with the network faked out: post() always says ok.

    These pin what happens AFTER the store has already accepted a batch, which
    is the part CT950 got wrong (see the module docstring) — the POST is not
    under test here, scripts/test_traces.py owns that.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        patcher = mock.patch.object(SHIP, "post", return_value=(True, "ok"))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_a_shipped_batch_that_cannot_be_deleted_is_reported_and_does_not_raise(self):
        spool(self.root, "alpine", "1788200322333-2787184-000000.json")
        with mock.patch.object(pathlib.Path, "unlink", side_effect=PermissionError):
            rc = SHIP.main(["--apply", "--stations", str(self.root)])
        # Reported as a failure (non-zero exit) rather than passing silently,
        # and rather than propagating the PermissionError past main().
        self.assertEqual(rc, 1)

    def test_keep_leaves_the_file_and_is_not_reported_as_a_failure(self):
        p = spool(self.root, "alpine", "a.json")
        rc = SHIP.main(["--apply", "--keep", "--stations", str(self.root)])
        self.assertEqual(rc, 0)
        self.assertTrue(p.exists())

    def test_a_normal_apply_run_ships_and_deletes(self):
        p = spool(self.root, "alpine", "a.json")
        rc = SHIP.main(["--apply", "--stations", str(self.root)])
        self.assertEqual(rc, 0)
        self.assertFalse(p.exists())


if __name__ == "__main__":
    unittest.main()

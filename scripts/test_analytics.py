"""Tests for the analytics sink (scripts/serve/analytics.py).

Everything here is about one property: a client-supplied batch must never be
able to make the report say something the aggregate is not entitled to claim.
The counts are the tab's own account of what it did, so validation is not
paranoia about attackers — it is what keeps a stale bundle, a fuzzed body or a
mis-typed probe id from silently becoming a row somebody makes a decision from.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "serve"))

import analytics  # noqa: E402


class AnalyticsStoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = analytics.AnalyticsStore(Path(self.tmp.name) / "analytics.db")

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def batch(self, **kw):
        body = {"class": "human"}
        body.update(kw)
        return self.store.record(body)

    # ---- intake ------------------------------------------------------------

    def test_probe_counts_accumulate_across_batches(self):
        self.batch(probes=[{"id": "fleet.usage.fetch", "grade": "auto", "n": 3}])
        self.batch(probes=[{"id": "fleet.usage.fetch", "grade": "auto", "n": 4}])
        report = self.store.report(days=1)
        self.assertEqual(report["probes"]["fleet.usage.fetch"]["auto"], 7)

    def test_grades_are_kept_apart(self):
        self.batch(
            probes=[
                {"id": "boot.video.played", "grade": "show", "n": 5},
                {"id": "boot.video.played", "grade": "act", "n": 1},
            ]
        )
        got = self.store.report(days=1)["probes"]["boot.video.played"]
        self.assertEqual(got, {"show": 5, "act": 1})

    def test_class_partitions_the_data(self):
        # The load-bearing one: the lab's own browser probes must not be able to
        # land in the human totals, or every keep/drop decision is a decision
        # about what the e2e fleet exercises.
        self.store.record({"class": "probe", "probes": [{"id": "fleet.sorted", "grade": "act", "n": 9}]})
        self.assertEqual(self.store.report(days=1, klass="human")["probes"], {})
        self.assertEqual(self.store.report(days=1, klass="probe")["probes"]["fleet.sorted"]["act"], 9)

    def test_unknown_class_is_not_silently_human(self):
        self.store.record({"class": "nonsense", "probes": [{"id": "fleet.sorted", "grade": "act", "n": 1}]})
        self.assertEqual(self.store.report(days=1, klass="human")["probes"], {})
        self.assertEqual(self.store.report(days=1, klass="unknown")["probes"]["fleet.sorted"]["act"], 1)

    # ---- validation --------------------------------------------------------

    def test_junk_rows_are_dropped_without_losing_the_good_ones(self):
        # A tab on an older bundle has valid counts for the probes that did not
        # change; refusing its whole batch to make a point about one would lose
        # them.
        taken = self.batch(
            probes=[
                {"id": "Fleet.Sorted", "grade": "act", "n": 1},  # bad id shape
                {"id": "fleet.sorted", "grade": "sideways", "n": 1},  # bad grade
                {"id": "fleet.sorted", "grade": "act", "n": 0},  # zero
                {"id": "fleet.sorted", "grade": "act", "n": -5},  # negative
                {"id": "fleet.sorted", "grade": "act", "n": True},  # bool, not int
                {"id": "fleet.sorted", "grade": "act", "n": 2},  # the only good one
            ]
        )
        self.assertEqual(taken, 1)
        self.assertEqual(self.store.report(days=1)["probes"], {"fleet.sorted": {"act": 2}})

    def test_counts_are_clamped(self):
        self.batch(probes=[{"id": "fleet.sorted", "grade": "act", "n": 10**9}])
        self.assertEqual(self.store.report(days=1)["probes"]["fleet.sorted"]["act"], analytics.MAX_COUNT)

    def test_row_count_is_bounded(self):
        rows = [{"id": f"fleet.p{i}", "grade": "act", "n": 1} for i in range(analytics.MAX_ROWS + 50)]
        self.assertEqual(self.batch(probes=rows), analytics.MAX_ROWS)

    def test_non_list_and_non_dict_payloads_are_survivable(self):
        self.assertEqual(self.batch(probes="not a list"), 0)
        self.assertEqual(self.batch(probes=[None, 3, "x"]), 0)
        self.assertEqual(self.store.record({}), 0)

    def test_camel_case_step_names_are_accepted(self):
        # `firstFrame` is a real declared step; rejecting it would silently
        # truncate the connect funnel at its most important row.
        self.batch(flows=[{"flow": "station.connect", "step": "firstFrame", "outcome": "ok", "n": 1}])
        self.assertEqual(self.store.report(days=1)["flows"]["station.connect"]["firstFrame"]["ok"], 1)

    # ---- flows and errors --------------------------------------------------

    def test_flow_funnel_shape(self):
        self.batch(
            flows=[
                {"flow": "station.connect", "step": "open", "outcome": "enter", "n": 10},
                {"flow": "station.connect", "step": "transport", "outcome": "enter", "n": 8},
                {"flow": "station.connect", "step": "firstFrame", "outcome": "ok", "n": 6},
                {"flow": "station.connect", "step": "nolive", "outcome": "fail", "n": 2},
            ]
        )
        funnel = self.store.report(days=1)["flows"]["station.connect"]
        self.assertEqual(funnel["open"]["enter"], 10)
        self.assertEqual(funnel["transport"]["enter"], 8)
        self.assertEqual(funnel["firstFrame"]["ok"], 6)
        self.assertEqual(funnel["nolive"]["fail"], 2)

    def test_errors_group_by_fingerprint_and_sort_by_count(self):
        self.batch(
            errors=[
                {"fp": "aaaaaaaa", "message": "rare", "source": "window", "n": 1},
                {
                    "fp": "bbbbbbbb",
                    "message": "common",
                    "source": "promise",
                    "flow": "station.connect",
                    "step": "transport",
                    "n": 40,
                },
            ]
        )
        errors = self.store.report(days=1)["errors"]
        self.assertEqual([e["fp"] for e in errors], ["bbbbbbbb", "aaaaaaaa"])
        self.assertEqual(errors[0]["flow"], "station.connect")
        self.assertEqual(errors[0]["n"], 40)

    def test_error_outside_every_flow_is_kept_not_dropped(self):
        # "Faults nobody's flow owns" is itself a finding — a crash on the
        # landing page has no flow and is exactly what must not vanish.
        self.batch(errors=[{"fp": "cccccccc", "message": "boom", "source": "window", "n": 1}])
        errors = self.store.report(days=1)["errors"]
        self.assertEqual(errors[0]["flow"], "")

    def test_bad_fingerprint_is_refused(self):
        self.assertEqual(self.batch(errors=[{"fp": "nope", "message": "x", "n": 1}]), 0)

    def test_error_message_is_truncated(self):
        self.batch(errors=[{"fp": "dddddddd", "message": "x" * 5000, "source": "window", "n": 1}])
        self.assertEqual(len(self.store.report(days=1)["errors"][0]["message"]), analytics.MESSAGE_MAX)

    # ---- housekeeping ------------------------------------------------------

    def test_no_identity_field_is_ever_stored(self):
        # The privacy guarantee is structural, so assert it structurally: there
        # is no column any future caller could put a person into.
        self.batch(probes=[{"id": "fleet.sorted", "grade": "act", "n": 1}])
        cols = {r[1] for t in ("probe", "flow", "error") for r in self.store._db.execute(f"PRAGMA table_info({t})")}
        self.assertEqual(cols & {"user", "userId", "sessionId", "ip"}, set())

    def test_prune_drops_old_days_and_keeps_todays(self):
        self.batch(probes=[{"id": "fleet.sorted", "grade": "act", "n": 1}])
        self.store._db.execute("INSERT INTO probe VALUES('2020-01-01','fleet.old','act','human',5)")
        self.store._db.commit()
        self.assertEqual(self.store.prune(keep_days=30), 1)
        self.assertIn("fleet.sorted", self.store.report(days=1)["probes"])

    def test_report_window_excludes_older_days(self):
        self.store._db.execute("INSERT INTO probe VALUES('2020-01-01','fleet.old','act','human',5)")
        self.store._db.commit()
        self.assertNotIn("fleet.old", self.store.report(days=7)["probes"])
        self.assertIn("fleet.old", self.store.report(days=100000)["probes"])


class CatalogueContractTest(unittest.TestCase):
    """The server validates ids by SHAPE; the catalogue is the thing that
    actually exists. If every declared id did not pass the server's own regex,
    a probe would be silently dropped at intake and read as a dead feature."""

    def test_every_declared_probe_and_step_survives_intake_validation(self):
        import json

        root = Path(__file__).resolve().parents[1]
        doc = json.loads((root / "registry" / "analytics-catalogue.json").read_text())
        for pid in doc["probes"]:
            self.assertIsNotNone(analytics._ident(pid), f"{pid} would be dropped at intake")
        for fid, flow in doc["flows"].items():
            self.assertIsNotNone(analytics._ident(fid), f"{fid} would be dropped at intake")
            for step in flow["steps"]:
                self.assertIsNotNone(analytics._ident(step), f"{fid}/{step} would be dropped")

    def test_every_declared_grade_is_one_the_server_accepts(self):
        import json

        root = Path(__file__).resolve().parents[1]
        doc = json.loads((root / "registry" / "analytics-catalogue.json").read_text())
        for pid, spec in doc["probes"].items():
            for grade in spec["grades"]:
                self.assertIn(grade, analytics.GRADES, f"{pid} declares an unknown grade")


if __name__ == "__main__":
    unittest.main()

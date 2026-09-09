#!/usr/bin/env python3
"""The vitals lane: store, migration, catalogue agreement and OTLP export.

The migration test is the one that matters most and it is first. `CREATE TABLE
IF NOT EXISTS` does not reshape a live table, so a wide metric store is exactly
the shape that crash-loops a serving plane on the next restart after somebody
adds a vital — which is what happened to the log lane on 2026-09-01, one file
over. This pins the behaviour rather than the intention.
"""

import json
import os
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "serve"))

import vitals  # noqa: E402
import vitals_otlp  # noqa: E402
import vitals_read  # noqa: E402
import vitals_schema  # noqa: E402


def _store(path):
    return vitals.VitalsStore(path)


class SchemaAndMigration(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = Path(self.dir) / "vitals.db"

    def test_schema_and_catalogue_cannot_drift(self):
        """SCHEMA is assembled from CATALOGUE, so a fresh store has exactly the
        catalogue's columns and no others. If this ever fails, somebody has
        hand-written a column list and the silent-drop failure is back."""
        s = _store(self.path)
        have = {r[1] for r in s._db.execute("PRAGMA table_info(vital)")}
        for col in vitals_schema.COLUMNS:
            self.assertIn(col, have)
        s.close()

    def test_catalogue_kinds_are_only_what_instana_accepts(self):
        """Gauge and Sum. Histogram is legal too (0307:90-94) and unused here;
        anything else — an exponential histogram in particular, which the docs
        are silent on — would be accepted by our store and dropped by the
        acceptor, which is the worst of both."""
        for _, name, unit, kind in vitals_schema.CATALOGUE:
            self.assertIn(kind, ("gauge", "sum"), name)
            self.assertTrue(unit, name)
            self.assertTrue(name.startswith("kh."), name)

    def test_a_store_written_before_a_vital_existed_gains_its_column(self):
        """THE CRASH-LOOP TEST. Build a store missing the last four catalogue
        columns — i.e. a plane deployed before those vitals were invented —
        then open it with today's code and require that opening SUCCEEDS and
        that the columns are there."""
        old = vitals_schema.COLUMNS[:-4]
        ddl = vitals_schema.SCHEMA.replace(
            "".join(f",\n  {c} REAL" for c in vitals_schema.COLUMNS),
            "".join(f",\n  {c} REAL" for c in old),
        )
        db = sqlite3.connect(self.path)
        db.executescript(ddl)
        db.execute(
            "INSERT INTO vital(ts_ms,observed_ms,station,session_id,source,build,day,fps) "
            "VALUES(1,1,'win311','s','spa','b','2026-09-01',30)"
        )
        db.commit()
        db.close()

        s = _store(self.path)  # must not raise
        have = {r[1] for r in s._db.execute("PRAGMA table_info(vital)")}
        for col in vitals_schema.COLUMNS[-4:]:
            self.assertIn(col, have)
        # And the row written before the migration is still there, unchanged.
        got = s.series(station="win311")
        self.assertEqual(got["total"], 1)
        self.assertEqual(got["samples"][0]["v"]["fps"], 30)
        s.close()

        # Opening again is a no-op, not a second ALTER.
        s2 = _store(self.path)
        s2.close()


class Intake(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.s = _store(Path(self.dir) / "v.db")
        self.now = int(time.time() * 1000)

    def tearDown(self):
        self.s.close()

    def _batch(self, samples, station="win311", batch_id=None):
        b = {
            "resource": {
                "service.instance.id": station,
                "session.id": "abcd1234",
                "kh.bundle": "build-1",
                "kh.source": "spa",
            },
            "samples": samples,
        }
        if batch_id:
            b["batchId"] = batch_id
        return b

    def test_records_and_reads_back_oldest_first(self):
        """A time series is read as a LINE. Every other store in the plane
        answers newest-first; this one must not, or a chart drawn straight off
        a page runs backwards."""
        self.s.record(self._batch([{"t": self.now - 5000, "v": {"fps": 29}}, {"t": self.now, "v": {"fps": 30}}]))
        got = self.s.series(station="win311")
        self.assertEqual([x["v"]["fps"] for x in got["samples"]], [29, 30])

    def test_an_unknown_vital_is_ignored_not_refused(self):
        """A client may ship a vital before the server deploys it. Losing the
        whole sample to punish one field is the wrong trade."""
        self.s.record(self._batch([{"t": self.now, "v": {"fps": 30, "not_a_vital": 7}}]))
        got = self.s.series()["samples"][0]["v"]
        self.assertEqual(got, {"fps": 30})

    def test_non_finite_values_are_dropped(self):
        self.s.record(self._batch([{"t": self.now, "v": {"fps": 30, "rtt_ms": float("inf")}}]))
        self.assertEqual(self.s.series()["samples"][0]["v"], {"fps": 30})

    def test_a_sample_with_no_readable_value_is_not_stored(self):
        self.s.record(self._batch([{"t": self.now, "v": {"not_a_vital": 1}}]))
        self.assertEqual(self.s.series()["total"], 0)

    def test_booleans_are_not_measurements(self):
        self.s.record(self._batch([{"t": self.now, "v": {"fps": 30, "audio_running": True}}]))
        self.assertEqual(self.s.series()["samples"][0]["v"], {"fps": 30})

    def test_a_named_batch_is_stored_once_however_often_it_is_offered(self):
        self.assertEqual(self.s.record(self._batch([{"t": self.now, "v": {"fps": 30}}], batch_id="b-1")), 1)
        self.assertEqual(self.s.record(self._batch([{"t": self.now, "v": {"fps": 30}}], batch_id="b-1")), 0)
        self.assertEqual(self.s.series()["total"], 1)

    def test_null_vitals_are_omitted_not_sent_as_null(self):
        """Most of every row is the other producer's columns. A wire that spelt
        them out would be mostly the word 'null'."""
        self.s.record(self._batch([{"t": self.now, "v": {"fps": 30}}]))
        self.assertEqual(list(self.s.series()["samples"][0]["v"]), ["fps"])

    def test_live_returns_the_newest_row_per_stream(self):
        self.s.record(self._batch([{"t": self.now - 5000, "v": {"fps": 29}}, {"t": self.now, "v": {"fps": 30}}]))
        self.s.record(self._batch([{"t": self.now, "v": {"fps": 12}}], station="beos"))
        live = self.s.live()["live"]
        self.assertEqual({r["station"]: r["v"]["fps"] for r in live}, {"win311": 30, "beos": 12})

    def test_live_forgets_a_stream_that_has_gone_quiet(self):
        """A station nobody is on must drop off the list rather than showing a
        stale line as though it were current."""
        self.s.record(self._batch([{"t": self.now - 600_000, "v": {"fps": 30}}]))
        self.assertEqual(self.s.live(120_000)["live"], [])

    def test_prune_drops_by_day_and_by_the_runaway_backstop(self):
        old = self.now - 10 * 86400 * 1000
        self.s.record(self._batch([{"t": old, "v": {"fps": 1}}, {"t": self.now, "v": {"fps": 2}}]))
        self.s.prune(keep_days=3)
        self.assertEqual([x["v"]["fps"] for x in self.s.series(since_ms=0)["samples"]], [2])
        self.s.record(self._batch([{"t": self.now, "v": {"fps": 3}}]))
        self.s.prune(keep_days=3, max_rows=1)
        self.assertEqual(self.s.series(since_ms=0)["total"], 1)

    def test_facets_report_coverage_not_just_counts(self):
        """A store holding a thousand rows from one 40-second session is not
        monitoring; it is a souvenir. Coverage is the number that says which."""
        self.s.record(self._batch([{"t": self.now - 60_000, "v": {"fps": 1}}, {"t": self.now, "v": {"fps": 2}}]))
        f = self.s.facets(self.now - 3600_000)
        self.assertEqual(f["total"], 2)
        self.assertEqual(f["sessions"], 1)
        self.assertEqual(f["lastMs"] - f["firstMs"], 60_000)
        self.assertTrue(any(c["column"] == "fps" for c in f["catalogue"]))


class OtlpExport(unittest.TestCase):
    def setUp(self):
        self.rows = [
            {
                "seq": 1,
                "tsMs": 1_700_000_000_000,
                "station": "win311",
                "sessionId": "abcd1234",
                "source": "spa",
                "build": "b1",
                "v": {"fps": 30.0, "frames_dropped": 4.0},
            },
            {
                "seq": 2,
                "tsMs": 1_700_000_005_000,
                "station": "beos",
                "sessionId": "efgh5678",
                "source": "spa",
                "build": "b1",
                "v": {"fps": 12.0},
            },
        ]

    def test_each_station_is_its_own_entity(self):
        """THE POINT OF THE WHOLE EXPORT. `service.instance.id` is what Instana
        builds an OpenTelemetry entity from (0311:236-248); one resource per
        station is one entity per exhibit."""
        doc = vitals_otlp.export(self.rows)
        ids = [
            {a["key"]: a["value"]["stringValue"] for a in rm["resource"]["attributes"] if "stringValue" in a["value"]}[
                "service.instance.id"
            ]
            for rm in doc["resourceMetrics"]
        ]
        self.assertEqual(sorted(ids), ["beos", "win311"])

    def test_session_is_a_point_attribute_and_never_part_of_the_resource(self):
        """A session id is unbounded over time. In the resource it would mint a
        new ENTITY for every tab that ever opened a station."""
        doc = vitals_otlp.export(self.rows)
        for rm in doc["resourceMetrics"]:
            keys = {a["key"] for a in rm["resource"]["attributes"]}
            self.assertNotIn("session.id", keys)
        pt = doc["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]["gauge"]["dataPoints"][0]
        self.assertIn("session.id", {a["key"] for a in pt["attributes"]})

    def test_a_cumulative_counter_is_a_monotonic_cumulative_sum(self):
        """Exported as a gauge, '4 frames dropped so far' renders as a level
        and means nothing. Only the axis lies, which is why this is pinned."""
        doc = vitals_otlp.export(self.rows)
        by_name = {m["name"]: m for rm in doc["resourceMetrics"] for sm in rm["scopeMetrics"] for m in sm["metrics"]}
        drops = by_name["kh.stream.video.frames_dropped"]
        self.assertTrue(drops["sum"]["isMonotonic"])
        self.assertEqual(drops["sum"]["aggregationTemporality"], 2)
        self.assertIn("gauge", by_name["kh.stream.video.fps"])

    def test_an_unmeasured_vital_contributes_no_point(self):
        """Not a zero. Half of every browser row is a column some other
        producer fills, and a zero there is a measurement we did not make."""
        doc = vitals_otlp.export(self.rows)
        names = {m["name"] for rm in doc["resourceMetrics"] for sm in rm["scopeMetrics"] for m in sm["metrics"]}
        self.assertNotIn("kh.stream.audio.underruns", names)

    def test_host_id_is_stamped_only_when_asked(self):
        with_host = vitals_otlp.export(self.rows, host_id="labhost")
        keys = {a["key"] for a in with_host["resourceMetrics"][0]["resource"]["attributes"]}
        self.assertIn("host.id", keys)
        without = vitals_otlp.export(self.rows)
        self.assertNotIn("host.id", {a["key"] for a in without["resourceMetrics"][0]["resource"]["attributes"]})

    def test_export_is_json_serialisable(self):
        json.dumps(vitals_otlp.export(self.rows))


class ReadSurface(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.s = _store(Path(self.dir) / "v.db")
        self.now = int(time.time() * 1000)
        self.s.record(
            {
                "resource": {"service.instance.id": "win311", "session.id": "s1", "kh.bundle": "b"},
                "samples": [{"t": self.now, "v": {"fps": 30}}],
            }
        )
        self.seen = []

    def tearDown(self):
        self.s.close()

    def _reply(self, code, obj):
        self.seen.append((code, obj))

    def test_every_leaf_answers(self):
        for leaf in vitals_read.LEAVES:
            vitals_read.route(self.s, leaf, {}, self._reply)
        self.assertEqual([c for c, _ in self.seen], [200] * len(vitals_read.LEAVES))

    def test_an_unknown_leaf_is_a_404(self):
        vitals_read.route(self.s, "nope", {}, self._reply)
        self.assertEqual(self.seen[0][0], 404)

    def test_filters_are_bounded_and_whitelisted(self):
        f = vitals_read.filters({"station": "x" * 500, "sinceMs": "not-an-int", "limit": True, "junk": 1})
        self.assertEqual(len(f["station"]), 64)
        self.assertIsNone(f["since_ms"])
        # A bool is not an int here: `limit=True` would become LIMIT 1.
        self.assertIsNone(f["limit"])
        self.assertNotIn("junk", f)

    def test_series_defaults_to_a_window_rather_than_to_everything(self):
        vitals_read.route(self.s, "series", {}, self._reply)
        self.assertEqual(self.seen[0][1]["total"], 1)

    def test_otlp_leaf_renders_what_the_series_leaf_returned(self):
        vitals_read.route(self.s, "otlp", {"station": "win311"}, self._reply)
        doc = self.seen[0][1]
        self.assertEqual(len(doc["resourceMetrics"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2 if os.environ.get("V") else 1)

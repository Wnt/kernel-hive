"""Tests for the trace store and the OTLP export.

Two themes. First, the store must never accept something that makes a trace
LOOK complete when it is not — a half-trace is worse than an absent one because
nobody doubts it. Second, the OTLP export must be exactly OTLP: a field spelled
almost right is the failure that survives review and dies in somebody else's
collector months later.
"""

from __future__ import annotations

import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "serve"))

import traces  # noqa: E402
import traces_otlp  # noqa: E402

T1 = "0af7651916cd43dd8448eb211c80319c"
T2 = "1bf7651916cd43dd8448eb211c80319d"
S1, S2, S3 = "b7ad6b7169203331", "b7ad6b7169203332", "b7ad6b7169203333"


def span(sid, parent=None, name="station.connect", start=1_700_000_000_000, dur=100, **kw):
    s = {
        "t": kw.pop("trace", T1),
        "s": sid,
        "p": parent,
        "n": name,
        "kd": kw.pop("kind", "internal"),
        "st": start,
        "d": dur,
        "h": kw.pop("hidden", 0),
        "k": kw.pop("status", "unset"),
    }
    s.update(kw)
    return s


def batch(spans, session="sess-abc", klass="human", build=None):
    resource = {"session.id": session, "kh.class": klass}
    if build is not None:
        resource["kh.bundle"] = build
    return {"resource": resource, "spans": spans}


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = traces.TraceStore(Path(self.tmp.name) / "traces.db")

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    # ---- intake ------------------------------------------------------------

    def test_a_trace_becomes_listable_and_readable(self):
        self.assertEqual(self.store.record(batch([span(S1), span(S2, parent=S1, name="step")])), 2)
        found = self.store.search()
        self.assertEqual(found["total"], 1)
        row = found["traces"][0]
        self.assertEqual((row["traceId"], row["spanCount"], row["name"]), (T1, 2, "station.connect"))
        self.assertEqual(len(self.store.trace(T1)["spans"]), 2)

    def test_spans_of_one_trace_may_arrive_in_separate_batches(self):
        # A journey outlives a 20-second flush, so this is the common case and
        # not an edge one. The summary has to be rebuilt, not written once.
        self.store.record(batch([span(S1, dur=50)]))
        self.store.record(batch([span(S2, parent=S1, start=1_700_000_000_100, dur=400)]))
        row = self.store.search()["traces"][0]
        self.assertEqual(row["spanCount"], 2)
        self.assertEqual(row["durMs"], 500)  # earliest start to latest end

    def test_a_duplicate_span_is_ignored_not_double_counted(self):
        self.store.record(batch([span(S1)]))
        self.assertEqual(self.store.record(batch([span(S1)])), 0)
        self.assertEqual(self.store.search()["traces"][0]["spanCount"], 1)

    def test_an_orphan_child_still_makes_the_trace_listable(self):
        # The root can be in a batch that has not landed yet. A trace you cannot
        # see until it finishes is a trace you cannot use to watch something
        # happening, so the earliest span stands in as root.
        self.store.record(batch([span(S2, parent=S1, name="step")]))
        self.assertEqual(self.store.search()["total"], 1)
        self.assertEqual(self.store.search()["traces"][0]["name"], "step")

    def test_error_spans_are_counted_on_the_trace(self):
        self.store.record(batch([span(S1), span(S2, parent=S1, name="step", status="error")]))
        self.assertEqual(self.store.search()["traces"][0]["errorCount"], 1)
        self.assertEqual(self.store.search(errors_only=True)["total"], 1)

    # ---- validation --------------------------------------------------------

    def test_malformed_ids_are_refused(self):
        for bad in ("", "xyz", "0AF7651916CD43DD8448EB211C80319C", "0af765"):
            self.assertEqual(self.store.record(batch([span(S1, trace=bad)])), 0, bad)
        for bad in ("", "zz", "b7ad6b716920333"):
            self.assertEqual(self.store.record(batch([{**span(S1), "s": bad}])), 0, bad)

    def test_the_backend_trace_id_attribute_survives_intake_intact(self):
        """`kh.backend.trace_id` is how a client span points at the server
        trace that answered it (khFetch.ts reads `traceresponse` /
        `Server-Timing: intid` off the response). Intake drops a key over 64
        chars or in BANNED_ATTRS and TRUNCATES a value over ATTR_STR_MAX — all
        three silently, and a truncated trace id joins nothing while still
        looking like an id. So assert the round trip, byte for byte, rather
        than the rules it happens to satisfy today."""
        backend = "abcdefabcdefabcdefabcdefabcdefab"
        key = "kh.backend.trace_id"
        self.assertLessEqual(len(key), 64)
        self.assertNotIn(key, traces.BANNED_ATTRS)
        self.assertLessEqual(len(backend), traces.ATTR_STR_MAX)
        self.store.record(batch([span(S1, a={key: backend})]))
        attrs = self.store.trace(T1)["spans"][0]["attributes"]
        self.assertEqual(attrs[key], backend)

    def test_attributes_are_capped_and_narrowed(self):
        big = {f"k{i}": "v" for i in range(200)}
        big["long"] = "x" * (traces.ATTR_STR_MAX + 500)
        big["obj"] = {"nested": 1}
        self.store.record(batch([span(S1, a=big)]))
        attrs = self.store.trace(T1)["spans"][0]["attributes"]
        self.assertLessEqual(len(attrs), traces.ATTR_MAX)
        self.assertNotIn("obj", attrs)
        for k, v in attrs.items():
            cap = traces.ATTR_STR_MAX_LONG if k in traces.LONG_ATTRS else traces.ATTR_STR_MAX
            self.assertLessEqual(len(str(v)), cap)

    def test_batch_size_is_bounded(self):
        many = [span(f"{i:016x}", parent=S1) for i in range(traces.MAX_SPANS_PER_BATCH + 40)]
        self.assertEqual(self.store.record(batch(many)), traces.MAX_SPANS_PER_BATCH)

    def test_junk_payloads_are_survivable(self):
        self.assertEqual(self.store.record({}), 0)
        self.assertEqual(self.store.record({"spans": "nope"}), 0)
        self.assertEqual(self.store.record(batch([None, 3, "x"])), 0)

    def test_a_batch_that_knows_the_session_upgrades_one_that_did_not(self):
        # The serving plane (serve/tracing.py) contributes spans to the SAME
        # trace as the tab and never learns the tab's session id — `traceparent`
        # carries a trace, not an identity — so its batches land as `unknown`,
        # and they land FIRST because a server span ends in milliseconds while a
        # tab flushes every twenty seconds. Without the upgrade the server would
        # win the race and every browser trace would list as session `unknown`.
        self.store.record({"resource": {}, "spans": [span(S1, name="serve.signal")]})
        self.assertEqual(self.store.search()["traces"][0]["sessionId"], "unknown")
        self.store.record(batch([span(S2, parent=S1)], session="sess-real", klass="human"))
        row = self.store.search()["traces"][0]
        self.assertEqual((row["sessionId"], row["class"]), ("sess-real", "human"))

    def test_a_later_unknown_batch_never_erases_a_known_session(self):
        self.store.record(batch([span(S1)], session="sess-real"))
        self.store.record({"resource": {}, "spans": [span(S2, parent=S1, name="serve.signal")]})
        self.assertEqual(self.store.search()["traces"][0]["sessionId"], "sess-real")

    def test_an_unknown_session_is_labelled_not_dropped(self):
        self.store.record({"resource": {}, "spans": [span(S1)]})
        self.assertEqual(self.store.search()["traces"][0]["sessionId"], "unknown")

    # ---- search ------------------------------------------------------------

    def test_filters(self):
        self.store.record(batch([span(S1, name="station.connect", status="ok")], session="s1"))
        self.store.record(
            batch([span(S1, trace=T2, name="walkin.register", status="error")], session="s2", klass="probe")
        )
        self.assertEqual(self.store.search(session="s1")["total"], 1)
        self.assertEqual(self.store.search(name="walkin.register")["total"], 1)
        self.assertEqual(self.store.search(klass="probe")["total"], 1)
        self.assertEqual(self.store.search(status="error")["total"], 1)
        self.assertEqual(self.store.search(session="nobody")["total"], 0)

    def test_search_is_paged_and_newest_first(self):
        for i in range(5):
            self.store.record(batch([span(S1, trace=f"{i:032x}", start=1_700_000_000_000 + i * 1000)]))
        page = self.store.search(limit=2)
        self.assertEqual(len(page["traces"]), 2)
        self.assertEqual(page["total"], 5)
        self.assertGreater(page["traces"][0]["startedMs"], page["traces"][1]["startedMs"])

    def test_min_duration_filter_finds_the_slow_ones(self):
        self.store.record(batch([span(S1, dur=10)]))
        self.store.record(batch([span(S1, trace=T2, dur=9000)]))
        self.assertEqual(self.store.search(min_dur_ms=1000)["total"], 1)

    def test_unknown_trace_reads_as_none_not_an_empty_trace(self):
        self.assertIsNone(self.store.trace(T1))
        self.assertIsNone(self.store.trace("not-an-id"))

    # ---- retention ---------------------------------------------------------

    def test_prune_drops_whole_traces_never_half_of_one(self):
        self.store.record(batch([span(S1), span(S2, parent=S1)]))
        self.store._db.execute("UPDATE trace SET day='2020-01-01'")
        self.store._db.commit()
        self.assertEqual(self.store.prune(keep_days=14), 1)
        self.assertEqual(self.store.search()["total"], 0)
        left = self.store._db.execute("SELECT count(*) FROM span WHERE trace_id=?", (T1,)).fetchone()
        self.assertEqual(left[0], 0, "spans outlived their trace summary")


class OrphanReportTest(unittest.TestCase):
    """`orphans()` — the regression detector for the no-orphan invariant
    (docs/lab/TRACE-CONTEXT.md §8). Its whole reason to exist is that a span
    naming a parent nobody stored looks perfect from every other angle: the
    request succeeded, the span is well formed, and only the JOIN is missing.
    An operator had to hand-write this query to discover a 42.9% rate."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = traces.TraceStore(Path(self.tmp.name) / "traces.db")
        self.now = int(time.time() * 1000)
        self.old = self.now - 6 * 3600 * 1000  # inside the window, outside the settle gap

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def test_a_parent_that_was_stored_is_not_an_orphan(self):
        self.store.record(batch([span(S1, start=self.old), span(S2, parent=S1, start=self.old)]))
        rep = self.store.orphans(self.old - 1000)
        self.assertEqual(rep["withParent"], 1)
        self.assertEqual(rep["orphaned"], 0)
        self.assertEqual(rep["rate"], 0.0)

    def test_a_parent_that_was_never_stored_is_counted_and_named(self):
        self.store.record(batch([span(S2, parent=S3, name="serve.clientcmd", start=self.old)]))
        rep = self.store.orphans(self.old - 1000)
        self.assertEqual(rep["orphaned"], 1)
        self.assertEqual(rep["rate"], 1.0)
        self.assertEqual(rep["byName"], [{"name": "serve.clientcmd", "n": 1}])

    def test_a_still_open_parent_at_the_recent_edge_is_not_counted(self):
        # A flow the visitor has not finished yet is a TRANSIENT orphan: the
        # root lands the moment it ends. Counting it would make the number a
        # measure of how busy the box is, not of whether the contract holds.
        self.store.record(batch([span(S2, parent=S3, name="serve.signal", start=self.now)]))
        self.assertEqual(self.store.orphans(self.now - 3600_000)["orphaned"], 0)

    def test_a_read_only_store_reports_without_touching_the_file(self):
        # The report must never migrate the file the serving plane is writing.
        self.store.record(batch([span(S2, parent=S3, start=self.old)]))
        self.store.close()
        path = Path(self.tmp.name) / "traces.db"
        before = path.stat().st_mtime_ns
        ro = traces.TraceStore(path, read_only=True)
        try:
            self.assertEqual(ro.orphans(self.old - 1000)["orphaned"], 1)
            with self.assertRaises(sqlite3.OperationalError):
                ro.record(batch([span(S1, start=self.old)]))
        finally:
            ro.close()
        self.assertEqual(path.stat().st_mtime_ns, before)
        self.store = traces.TraceStore(path)  # so tearDown has something to close


class OtlpTest(unittest.TestCase):
    """The export must be OTLP, not almost-OTLP."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = traces.TraceStore(Path(self.tmp.name) / "traces.db")
        self.store.record(
            batch(
                [
                    span(
                        S1,
                        name="station.connect",
                        status="ok",
                        dur=250,
                        a={"kh.flow": "station.connect", "count": 3, "flag": True},
                    ),
                    span(
                        S2,
                        parent=S1,
                        name="step",
                        kind="client",
                        hidden=40,
                        status="error",
                        m="gave up",
                        e=[{"n": "exception", "t": 1_700_000_000_050, "a": {"exception.type": "TypeError"}}],
                    ),
                ]
            )
        )
        self.doc = traces_otlp.export([self.store.trace(T1)])

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def spans(self):
        return self.doc["resourceSpans"][0]["scopeSpans"][0]["spans"]

    def test_shape_is_resource_scope_spans(self):
        self.assertIn("resourceSpans", self.doc)
        rs = self.doc["resourceSpans"][0]
        self.assertIn("resource", rs)
        self.assertIn("scopeSpans", rs)

    def test_resource_carries_the_session_as_a_semantic_convention_key(self):
        keys = {a["key"]: a["value"] for a in self.doc["resourceSpans"][0]["resource"]["attributes"]}
        self.assertEqual(keys["session.id"]["stringValue"], "sess-abc")
        self.assertEqual(keys["service.name"]["stringValue"], "kernel-hive-spa")

    def test_timestamps_are_nanoseconds_as_strings(self):
        s = self.spans()[0]
        self.assertIsInstance(s["startTimeUnixNano"], str)
        self.assertEqual(int(s["startTimeUnixNano"]), 1_700_000_000_000 * 1_000_000)
        self.assertEqual(int(s["endTimeUnixNano"]) - int(s["startTimeUnixNano"]), 250 * 1_000_000)

    def test_a_span_with_kh_service_gets_its_own_resource_not_the_default(self):
        """The daemon (`streamhost/src/trace/mod.rs`'s `render()`) stamps
        `kh.service: "kernel-hive-daemon"` on every span it emits, the same
        pattern `scripts/serve/tracing.py` uses for `kernel-hive-serve`. Before
        that daemon-side fix landed, a daemon span with no `kh.service`
        attribute fell through to this function's default `service` argument
        (`"kernel-hive-spa"`) and was silently filed under the BROWSER's
        service — verified live against Instana 2026-08-31: an `input.edge`
        trace's daemon-origin spans (`input.dispatch`, `guest.frame.next`,
        `transport.frame.next`) all carried `service.name: kernel-hive-spa`.
        This locks the grouping half of that fix in place: a span that DOES
        carry `kh.service` gets its OWN resource, under its own name, never
        merged into the caller's default."""
        tmp = tempfile.TemporaryDirectory()
        try:
            store = traces.TraceStore(Path(tmp.name) / "traces.db")
            store.record(
                batch(
                    [
                        span(S1, name="input.edge", kind="client"),
                        span(
                            S2,
                            parent=S1,
                            name="input.dispatch",
                            kind="internal",
                            a={"kh.service": "kernel-hive-daemon", "kh.station": "solaris"},
                        ),
                    ]
                )
            )
            doc = traces_otlp.export([store.trace(T1)])
            by_service = {}
            for rs in doc["resourceSpans"]:
                keys = {a["key"]: a["value"]["stringValue"] for a in rs["resource"]["attributes"]}
                names = {s["name"] for s in rs["scopeSpans"][0]["spans"]}
                by_service[keys["service.name"]] = names
            self.assertEqual(by_service.get("kernel-hive-spa"), {"input.edge"})
            self.assertEqual(by_service.get("kernel-hive-daemon"), {"input.dispatch"})
        finally:
            store.close()
            tmp.cleanup()

    def test_kind_and_status_are_the_protobuf_enums(self):
        by_name = {s["name"]: s for s in self.spans()}
        self.assertEqual(by_name["station.connect"]["kind"], 1)  # INTERNAL
        self.assertEqual(by_name["step"]["kind"], 3)  # CLIENT
        self.assertEqual(by_name["station.connect"]["status"]["code"], 1)  # OK
        self.assertEqual(by_name["step"]["status"]["code"], 2)  # ERROR
        self.assertEqual(by_name["step"]["status"]["message"], "gave up")

    def test_attribute_values_are_typed_anyvalues(self):
        a = {x["key"]: x["value"] for x in self.spans()[0]["attributes"]}
        self.assertEqual(a["kh.flow"], {"stringValue": "station.connect"})
        self.assertEqual(a["count"], {"intValue": "3"})
        # bool must not degrade to an int: Python's bool IS an int, and a
        # collector that received 1 where it expected true would type the field
        # wrong forever after.
        self.assertEqual(a["flag"], {"boolValue": True})

    def test_a_root_span_omits_parentSpanId_rather_than_sending_null(self):
        root = [s for s in self.spans() if s["name"] == "station.connect"][0]
        self.assertNotIn("parentSpanId", root)
        child = [s for s in self.spans() if s["name"] == "step"][0]
        self.assertEqual(child["parentSpanId"], S1)

    def test_events_survive_with_their_attributes(self):
        child = [s for s in self.spans() if s["name"] == "step"][0]
        ev = child["events"][0]
        self.assertEqual(ev["name"], "exception")
        self.assertEqual(int(ev["timeUnixNano"]), 1_700_000_000_050 * 1_000_000)
        self.assertEqual(ev["attributes"][0]["value"]["stringValue"], "TypeError")

    def test_hidden_time_is_exported_as_a_namespaced_attribute(self):
        # Not an OTel concept, so it must not be dropped AND must not pretend to
        # be a convention field.
        child = [s for s in self.spans() if s["name"] == "step"][0]
        a = {x["key"]: x["value"] for x in child["attributes"]}
        self.assertEqual(a["kh.hidden_ms"], {"intValue": "40"})

    def test_traceid_and_spanid_are_unchanged_hex(self):
        s = self.spans()[0]
        self.assertEqual(s["traceId"], T1)
        self.assertEqual(s["spanId"], S1)


if __name__ == "__main__":
    unittest.main()


class PreMigrationStoreTest(unittest.TestCase):
    """Opening a store whose db predates ingest ordering.

    This is the case that took the serving plane down: every test built a
    FRESH db, where `CREATE TABLE` makes the new columns and nothing notices
    that `SCHEMA` also indexes one of them. On a db that already had a `trace`
    table, `CREATE TABLE IF NOT EXISTS` is a no-op, so the index in SCHEMA ran
    against a column the migration had not added yet and the process exited 1
    on startup, in a restart loop, with the gallery serving 502.
    """

    OLD_TRACE_TABLE = """
    CREATE TABLE trace (
      trace_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL, class TEXT NOT NULL,
      root_name TEXT NOT NULL,
      started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL, dur_ms INTEGER NOT NULL,
      span_count INTEGER NOT NULL, error_count INTEGER NOT NULL,
      status TEXT NOT NULL, day TEXT NOT NULL) WITHOUT ROWID;
    """

    def _old_db(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / "traces.db"
        db = sqlite3.connect(str(path))
        db.executescript(self.OLD_TRACE_TABLE)
        db.execute(
            "INSERT INTO trace VALUES(?,'s','human','r',100,200,100,1,0,'ok','2026-09-01')",
            ("a" * 32,),
        )
        db.commit()
        db.close()
        return path

    def test_a_store_written_before_ingest_ordering_opens(self):
        store = traces.TraceStore(self._old_db())
        self.assertEqual(len(store.search(limit=10)["traces"]), 1)

    def test_the_existing_rows_are_sequenced_not_left_at_zero(self):
        path = self._old_db()
        traces.TraceStore(path)
        db = sqlite3.connect(str(path))
        self.assertEqual(db.execute("SELECT COUNT(*) FROM trace WHERE ingest_seq=0").fetchone()[0], 0)

    def test_opening_twice_is_stable(self):
        path = self._old_db()
        traces.TraceStore(path)
        traces.TraceStore(path)  # the index already exists; must not raise

    def test_a_store_written_before_build_identity_gets_the_column(self):
        """Same shape as the ingest-order migration, same reason: a live
        traces.db keeps its old columns forever unless somebody says otherwise,
        and the FIRST batch to arrive after the deploy would otherwise fail its
        INSERT against a column that is not there — with the gallery in a
        restart loop, which is exactly how this class was born."""
        path = self._old_db()
        store = traces.TraceStore(path)
        self.addCleanup(store.close)
        # The pre-existing row reads `unknown`, which is the truth about it.
        self.assertEqual(store.search(limit=10)["traces"][0]["build"], "unknown")
        self.assertEqual(store.record(batch([span(S1)], build="main@abc1234")), 1)
        self.assertEqual(store.trace(T1)["build"], "main@abc1234")


class BuildIdentityTest(unittest.TestCase):
    """WHICH BUNDLE THE CLIENT WAS RUNNING, on our own plane, end to end.

    The bug behind these tests was not in any of this code: on 2026-09-01 a
    phone's visit was recorded in full here and not at all by the vendor, and
    the only place a client's build id was ever written down was a vendor beacon
    meta — so the first question ("was that client on the shell we deployed?")
    could not be asked of our own data at all. It rides the RESOURCE envelope
    now, because it is one fact about the producer rather than a fact about a
    moment in the journey, and these tests pin it from intake to OTLP.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = traces.TraceStore(Path(self.tmp.name) / "traces.db")

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def test_the_build_survives_intake_and_is_readable_from_the_trace(self):
        self.store.record(batch([span(S1)], build="main@3e6c81c4"))
        self.assertEqual(self.store.trace(T1)["build"], "main@3e6c81c4")
        self.assertEqual(self.store.search(limit=10)["traces"][0]["build"], "main@3e6c81c4")

    def test_a_batch_that_names_no_build_is_labelled_unknown_not_dropped(self):
        self.assertEqual(self.store.record(batch([span(S1)])), 1)
        self.assertEqual(self.store.trace(T1)["build"], "unknown")

    def test_a_build_id_outside_the_character_class_is_refused(self):
        for bad in ["main@abc 1234", "<script>", "x" * 65, 7, None, "sha\nmain@1"]:
            with self.subTest(bad=bad):
                store = traces.TraceStore(Path(self.tmp.name) / f"b{abs(hash(str(bad)))}.db")
                store.record(batch([span(S1)], build=bad))
                self.assertEqual(store.trace(T1)["build"], "unknown")
                store.close()

    def test_a_dirty_working_tree_build_is_accepted_verbatim(self):
        """`computeBuildId()` appends `-dirty`, and a slash is legal in a branch
        name. Both are exactly the cases where knowing the build matters most —
        somebody is running something that is not a commit anybody can fetch."""
        self.store.record(batch([span(S1)], build="feat/walkin@3e6c81c4-dirty"))
        self.assertEqual(self.store.trace(T1)["build"], "feat/walkin@3e6c81c4-dirty")

    def test_the_serving_planes_own_batch_never_erases_the_browsers_answer(self):
        """The same race `session_id` and `class` already survive: a Python
        request handler has no bundle, its spans land FIRST (a server span ends
        in milliseconds; a tab flushes every twenty seconds), and without the
        rule it would overwrite the one column this exists for."""
        self.store.record(batch([span(S1)], build="main@3e6c81c4"))
        self.store.record(batch([span(S2, parent=S1, name="serve.page")], build=None))
        self.assertEqual(self.store.trace(T1)["build"], "main@3e6c81c4")

    def test_a_later_batch_from_a_reloaded_tab_updates_the_build(self):
        self.store.record(batch([span(S1)], build="main@aaaaaaa"))
        self.store.record(batch([span(S2, parent=S1, name="step")], build="main@bbbbbbb"))
        self.assertEqual(self.store.trace(T1)["build"], "main@bbbbbbb")

    def test_traces_can_be_filtered_by_build(self):
        """The query the diagnosis needs: which clients are on a build the box
        no longer serves."""
        self.store.record(batch([span(S1)], build="main@aaaaaaa"))
        self.store.record(batch([span(S1, trace=T2)], session="sess-two", build="main@bbbbbbb"))
        found = self.store.search(build="main@bbbbbbb", limit=10)
        self.assertEqual([t["traceId"] for t in found["traces"]], [T2])

    def test_the_facets_name_every_build_in_the_window(self):
        self.store.record(batch([span(S1)], build="main@aaaaaaa"))
        self.store.record(batch([span(S1, trace=T2)], session="sess-two", build="main@bbbbbbb"))
        builds = {f["value"]: f["n"] for f in self.store.facets(0)["builds"]}
        self.assertEqual(builds, {"main@aaaaaaa": 1, "main@bbbbbbb": 1})

    # ---- the OTLP boundary -------------------------------------------------

    def test_the_build_is_exported_as_the_service_version_resource_attribute(self):
        self.store.record(batch([span(S1)], build="main@3e6c81c4"))
        doc = traces_otlp.export([self.store.trace(T1)])
        keys = {a["key"]: a["value"] for a in doc["resourceSpans"][0]["resource"]["attributes"]}
        self.assertEqual(keys["service.version"]["stringValue"], "main@3e6c81c4")
        # …and the session/service keys it sits beside are untouched.
        self.assertEqual(keys["session.id"]["stringValue"], "sess-abc")
        self.assertEqual(keys["service.name"]["stringValue"], "kernel-hive-spa")

    def test_an_unknown_build_is_omitted_rather_than_exported_as_a_version(self):
        """A consumer grouping by version must not be handed the string
        "unknown" and be unable to tell it from a real release name."""
        self.store.record(batch([span(S1)]))
        doc = traces_otlp.export([self.store.trace(T1)])
        keys = {a["key"] for a in doc["resourceSpans"][0]["resource"]["attributes"]}
        self.assertNotIn("service.version", keys)

    def test_the_browsers_build_is_never_stamped_on_the_daemons_resource(self):
        """`service.version` describes the producer. The daemon and the serving
        plane ship on their own cadence, and asserting the SPA's bundle id about
        them would be a lie a service map would happily draw."""
        self.store.record(
            batch(
                [
                    span(S1, name="input.edge", kind="client"),
                    span(S2, parent=S1, name="input.dispatch", a={"kh.service": "kernel-hive-daemon"}),
                ],
                build="main@3e6c81c4",
            )
        )
        doc = traces_otlp.export([self.store.trace(T1)])
        by_service = {}
        for rs in doc["resourceSpans"]:
            keys = {a["key"]: a["value"]["stringValue"] for a in rs["resource"]["attributes"]}
            by_service[keys["service.name"]] = keys
        self.assertEqual(by_service["kernel-hive-spa"]["service.version"], "main@3e6c81c4")
        self.assertNotIn("service.version", by_service["kernel-hive-daemon"])

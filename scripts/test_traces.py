"""Tests for the trace store and the OTLP export.

Two themes. First, the store must never accept something that makes a trace
LOOK complete when it is not — a half-trace is worse than an absent one because
nobody doubts it. Second, the OTLP export must be exactly OTLP: a field spelled
almost right is the failure that survives review and dies in somebody else's
collector months later.
"""

from __future__ import annotations

import sys
import tempfile
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


def batch(spans, session="sess-abc", klass="human"):
    return {"resource": {"session.id": session, "kh.class": klass}, "spans": spans}


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

    def test_a_stacktrace_attribute_is_refused_even_though_otel_defines_it(self):
        # The one content rule the trace lane kept. Stacks live in clientlog.
        self.store.record(batch([span(S1, a={"exception.stacktrace": "at foo()", "kh.flow": "x"})]))
        attrs = self.store.trace(T1)["spans"][0]["attributes"]
        self.assertNotIn("exception.stacktrace", attrs)
        self.assertEqual(attrs["kh.flow"], "x")

    def test_attributes_are_capped_and_narrowed(self):
        big = {f"k{i}": "v" for i in range(100)}
        big["long"] = "x" * 500
        big["obj"] = {"nested": 1}
        self.store.record(batch([span(S1, a=big)]))
        attrs = self.store.trace(T1)["spans"][0]["attributes"]
        self.assertLessEqual(len(attrs), traces.ATTR_MAX)
        self.assertNotIn("obj", attrs)
        for v in attrs.values():
            self.assertLessEqual(len(str(v)), traces.ATTR_STR_MAX)

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

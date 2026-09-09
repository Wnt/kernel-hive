"""The log plane: severity, correlation, idempotency, retention, OTLP shape.

WHAT THESE PIN, in one sentence each, because a log store that merely stores is
not what was asked for:

  * A record carries the trace context THAT WAS OPEN WHEN IT WAS WRITTEN, and
    a record with no span in scope carries none rather than a plausible-looking
    id that joins to nothing.
  * `for_trace` answers the pivot — every producer's records under one trace id,
    in time order — which is the acceptance test for the whole feature.
  * A shipped batch offered twice is stored once. The span store gets this free
    from `ON CONFLICT(trace_id,span_id)`; this one has to be given it, and
    `trace-ship.py` leans on it in exactly the documented off-box case.
  * SCHEMA never names a column a migration adds (the 2026-09-01 crash loop) —
    pinned by opening the same file twice, which is what a restart does.
"""

from __future__ import annotations

import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "serve"))
sys.path.insert(0, str(Path(__file__).resolve().parent / "observability"))

import logs  # noqa: E402
import logs_otlp  # noqa: E402
import logs_read  # noqa: E402
import logsink  # noqa: E402
import tracing  # noqa: E402
from instana_batch import log_requests_for  # noqa: E402

TRACE = "a" * 32
SPAN = "b" * 16


def _batch(records, **res):
    resource = {"service.name": "kernel-hive-serve", "service.instance.id": "labhost"}
    resource.update(res)
    return {"resource": resource, "logs": records}


class LogPlane(unittest.TestCase):
    """One case per property; `self.tmp` is a fresh directory for each."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.tmp = Path(self._dir.name)

    def tearDown(self):
        self._dir.cleanup()
        logsink.reset_for_tests()
        tracing.reset_for_tests()

    def _store(self, name="logs.db"):
        return logs.LogStore(self.tmp / name)

    # ---- severity ---------------------------------------------------------------

    def test_severity_accepts_every_dialect_a_producer_speaks(self):
        # python logging, the browser console, our own names, and a bare OTel
        # SeverityNumber. A record with an unrecognised level is still evidence, so
        # it reads as the default rather than being refused.
        assert logs.severity_of("WARNING") == ("WARN", 13)
        assert logs.severity_of("critical") == ("FATAL", 21)
        assert logs.severity_of("warn") == ("WARN", 13)
        assert logs.severity_of(17) == ("ERROR", 17)
        assert logs.severity_of(20) == ("ERROR", 20)  # inside the ERROR band, number kept
        assert logs.severity_of("nonsense") == ("INFO", 9)
        assert logs.severity_of(None) == ("INFO", 9)

    # ---- correlation ------------------------------------------------------------

    def test_a_record_keeps_the_trace_and_span_it_was_given(self):
        store = self._store()
        assert store.record(_batch([{"b": "boom", "sv": "ERROR", "tr": TRACE, "sp": SPAN}])) == 1
        row = store.search()["logs"][0]
        assert (row["traceId"], row["spanId"]) == (TRACE, SPAN)

    def test_a_span_id_without_a_trace_id_is_dropped_not_stored(self):
        # It would join to nothing, and would read as correlated in any UI that
        # checks only one of the two columns.
        store = self._store()
        store.record(_batch([{"b": "orphan", "sp": SPAN}]))
        row = store.search()["logs"][0]
        assert row["traceId"] is None and row["spanId"] is None

    def test_a_malformed_id_is_refused_rather_than_stored(self):
        store = self._store()
        store.record(_batch([{"b": "x", "tr": "NOT-HEX", "sp": SPAN}]))
        assert store.search()["logs"][0]["traceId"] is None

    def test_for_trace_is_the_pivot_and_is_time_ordered(self):
        store = self._store()
        store.record(
            _batch(
                [
                    {"b": "second", "t": 2000, "tr": TRACE, "sp": SPAN},
                    {"b": "first", "t": 1000, "tr": TRACE, "sp": SPAN},
                    {"b": "other trace", "t": 1500, "tr": "c" * 32},
                    {"b": "uncorrelated", "t": 1200},
                ]
            )
        )
        got = store.for_trace(TRACE)
        assert [r["body"] for r in got["logs"]] == ["first", "second"]

    def test_the_sink_stamps_the_open_span_and_nothing_when_there_is_none(self):
        store = self._store()
        logsink.reset_for_tests()
        logsink.bind(store, "labhost")
        tracing.reset_for_tests()
        tracing.bind(logs.LogStore(self.tmp / "unused.db"))  # any store: we read ids only
        span = tracing.start_trace("http.request")
        tracing.push(span)
        logsink.write("during the request", severity="ERROR")
        tracing.pop(span)
        logsink.write("after the request", severity="INFO")
        logsink.flush()
        by_body = {r["body"]: r for r in store.search()["logs"]}
        assert by_body["during the request"]["traceId"] == span.trace_id
        assert by_body["during the request"]["spanId"] == span.span_id
        assert by_body["after the request"]["traceId"] is None
        logsink.reset_for_tests()
        tracing.reset_for_tests()

    def test_the_sink_stores_a_stack_which_is_why_clientlog_had_to_exist(self):
        store = self._store()
        logsink.reset_for_tests()
        logsink.bind(store, "labhost")
        try:
            raise ValueError("boom")
        except ValueError as err:
            logsink.exception("handler blew up", err)
        logsink.flush()
        attrs = store.search()["logs"][0]["attributes"]
        assert attrs["exception.type"] == "ValueError"
        assert "ValueError: boom" in attrs["exception.stacktrace"]
        logsink.reset_for_tests()

    # ---- idempotency ------------------------------------------------------------

    def test_a_named_batch_offered_twice_is_stored_once(self):
        store = self._store()
        batch = _batch([{"b": "one"}, {"b": "two"}])
        batch["batchId"] = "0001-77-000001.json"
        assert store.record(batch) == 2
        assert store.record(batch) == 0
        assert store.search()["total"] == 2

    def test_an_unnamed_batch_is_still_accepted(self):
        # The browser posts no batch id — it is not retried from a spool — and must
        # not be refused for the absence.
        store = self._store()
        assert store.record(_batch([{"b": "from a tab"}])) == 1

    # ---- intake hygiene ---------------------------------------------------------

    def test_an_empty_body_is_not_a_record(self):
        store = self._store()
        assert store.record(_batch([{"b": ""}, {"sv": "ERROR"}, {"b": "real"}])) == 1

    def test_a_missing_producer_clock_falls_back_to_ours(self):
        store = self._store()
        before = int(time.time() * 1000)
        store.record(_batch([{"b": "no clock"}]))
        row = store.search()["logs"][0]
        assert row["tsMs"] >= before
        assert row["observedMs"] >= before

    def test_bodies_and_attributes_are_capped(self):
        store = self._store()
        store.record(_batch([{"b": "x" * 99_999, "a": {"k": "y" * 9_999}}]))
        row = store.search()["logs"][0]
        assert len(row["body"]) == logs.BODY_STR_MAX
        assert len(row["attributes"]["k"]) == logs.ATTR_STR_MAX

    # ---- schema and retention ---------------------------------------------------

    def test_reopening_the_same_store_runs_no_migration_that_names_a_missing_column(self):
        # A restart runs `executescript(SCHEMA)` against a store that already
        # exists. Doing that twice is exactly what took the serving plane down on
        # 2026-09-01, so it is pinned rather than assumed.
        path = self.tmp / "logs.db"
        first = logs.LogStore(path)
        first.record(_batch([{"b": "before the restart"}]))
        first.close()
        second = logs.LogStore(path)
        assert second.search()["total"] == 1
        second.close()

    def test_prune_drops_the_old_and_keeps_the_window(self):
        store = self._store()
        old = int((time.time() - 30 * 86400) * 1000)
        store.record(_batch([{"b": "ancient", "t": old}, {"b": "today"}]))
        assert store.prune(keep_days=7) == 1
        assert [r["body"] for r in store.search()["logs"]] == ["today"]

    def test_a_read_only_store_runs_no_ddl(self):
        path = self.tmp / "logs.db"
        logs.LogStore(path).close()
        reader = logs.LogStore(path, read_only=True)
        assert reader.search()["total"] == 0
        reader.close()

    # ---- reads ------------------------------------------------------------------

    def test_search_filters_are_whitelisted_and_bounded(self):
        got = logs_read.filters({"service": "x" * 999, "minSeverity": "ERROR", "limit": True, "nope": "dropped"})
        assert len(got["service"]) == 64
        assert "nope" not in got
        assert got["limit"] is None  # a bool is not an int here

    def test_min_severity_is_a_range_not_a_list(self):
        store = self._store()
        store.record(_batch([{"b": "d", "sv": "DEBUG"}, {"b": "w", "sv": "WARN"}, {"b": "e", "sv": "ERROR"}]))
        bodies = {r["body"] for r in store.search(min_sev="WARN")["logs"]}
        assert bodies == {"w", "e"}

    def test_facets_report_how_much_is_actually_correlated(self):
        # The health number for this whole feature: a plane that ships logs and
        # correlates none of them has shipped files.
        store = self._store()
        store.record(_batch([{"b": "joined", "tr": TRACE}, {"b": "loose"}]))
        assert store.facets(0)["correlated"] == {"withTrace": 1, "total": 2}

    # ---- OTLP export ------------------------------------------------------------

    def test_otlp_carries_the_fields_instana_correlates_on(self):
        store = self._store()
        store.record(
            _batch(
                [{"b": "boom", "sv": "ERROR", "tr": TRACE, "sp": SPAN, "a": {"exception.stacktrace": "at x"}}],
                **{"kh.bundle": "main@abc"},
            )
        )
        doc = logs_otlp.export(store.search()["logs"], host_id="labhost")
        res = {a["key"]: a["value"]["stringValue"] for a in doc["resourceLogs"][0]["resource"]["attributes"]}
        # "Host or entity identification is REQUIRED for Instana to accept
        # OpenTelemetry logs" — 0307-opentelemetry-signals.md:338-352.
        assert res["host.id"] == "labhost"
        assert res["service.instance.id"] == "labhost"
        assert res["service.name"] == "kernel-hive-serve"
        assert res["service.version"] == "main@abc"
        rec = doc["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]
        # "The TraceId, SpanId, and Body fields are incorporated without any
        # alterations." — 0307:331.
        assert rec["traceId"] == TRACE and rec["spanId"] == SPAN
        assert rec["body"]["stringValue"] == "boom"
        # "The log level is determined primarily by the SeverityText field and the
        # SeverityNumber field as a fallback." — 0307:333-334. Both are sent.
        assert rec["severityText"] == "ERROR" and rec["severityNumber"] == 17
        assert rec["flags"] == 1
        assert json.dumps(doc)  # serialisable, which is what actually ships

    def test_otlp_omits_the_ids_when_there_are_none(self):
        store = self._store()
        store.record(_batch([{"b": "loose"}]))
        rec = logs_otlp.export(store.search()["logs"])["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]
        assert "traceId" not in rec and "spanId" not in rec and "flags" not in rec

    # ---- batching ---------------------------------------------------------------

    def test_the_log_planner_pages_by_bytes_and_carries_a_watermark(self):
        rows = [{"seq": i, "body": "x" * 100} for i in range(1, 21)]
        plan, dropped = log_requests_for(rows, max_records=1000, max_bytes=600)
        assert not dropped
        assert sum(len(chunk) for chunk, _ in plan) == 20
        # Every request carries the seq of its LAST record, so a run that dies part
        # way resumes exactly where it stopped.
        assert [w for _, w in plan][-1] == 20
        for chunk, watermark in plan:
            assert watermark == chunk[-1]["seq"]

    def test_one_oversized_record_is_dropped_and_the_watermark_still_moves(self):
        # Without this the lane wedges on one bad record and every later record
        # behind it — the failure the trace lane already paid for once.
        rows = [{"seq": 1, "body": "x" * 10_000}, {"seq": 2, "body": "small"}]
        plan, dropped = log_requests_for(rows, max_bytes=1000)
        assert len(dropped) == 1
        assert ([], 1) in plan
        assert any(chunk and chunk[0]["seq"] == 2 for chunk, _ in plan)


if __name__ == "__main__":
    unittest.main()

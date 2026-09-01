"""Tests for the Instana forwarder's watermark — the bug that lost half a trace.

THE RACE THIS FILE EXISTS FOR. A trace's server span is written within
milliseconds; the same trace's browser spans flush on a 20-second interval or on
pagehide, so they land AFTER the forwarder may already have shipped the server
half. The old watermark was `max(started_ms)` of the batch just sent, and a
trace's start time never moves — so the late browser spans, stamped EARLIER than
a watermark that had already passed them, were never selected by any later run.
Nothing rescanned. They were lost, and what Instana showed was a call with no
parent.

`test_late_browser_spans_are_forwarded_exactly_once` is that sequence, in order,
with the assertion the old code could not pass.

THE SECOND THING THIS FILE EXISTS FOR, added 2026-09-01: THROUGHPUT AND SIZE.
One run shipped exactly one batch of 100 TRACES and exited, so on a five-minute
timer the pipeline moved 20 traces/minute against a store taking 23/minute and
sat 991 traces behind — Instana permanently ~25 minutes stale. And because
trace size on this box spans four orders of magnitude, "100 traces" was once
16,226 spans and 9.6 MB, which the agent's OTLP receiver refused by closing the
connection; the same doomed payload was re-sent every five minutes. `DrainTest`
and `BatchSizeTest` are those two defects, each with the assertion the old code
could not pass, and `WatermarkTest` is unchanged so the exactly-once property
they are built on cannot be traded away for throughput.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "serve"))
sys.path.insert(0, str(ROOT / "scripts" / "observability"))

import instana_backlog  # noqa: E402
import instana_batch  # noqa: E402
import traces  # noqa: E402


def _load(name: str, path: Path):
    """Import a dashed script by path — `instana-forward` is not an identifier."""
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fwd = _load("instana_forward", ROOT / "scripts" / "observability" / "instana-forward.py")

T_RACE = "0af7651916cd43dd8448eb211c80319c"
SERVER, BROWSER1, BROWSER2 = "b7ad6b7169203331", "b7ad6b7169203332", "b7ad6b7169203333"
DEST = fwd.Destination(name="agent", endpoint="http://127.0.0.1:4318", send_key=False, stamp_host_id=False)


def span(sid, name, parent=None, start=1_700_000_000_000, kind="internal", trace=T_RACE):
    """A span as the store INTAKES it (compact keys) — what `record()` takes."""
    return {"t": trace, "s": sid, "p": parent, "n": name, "kd": kind, "st": start, "d": 5, "h": 0, "k": "unset"}


def out_span(sid, name):
    """A span as the store RETURNS it from `trace()` — what the exporter and
    the batcher see. The two shapes are different and mixing them up is a
    KeyError, not a wrong answer, which is the only reason this comment is
    short."""
    return {
        "spanId": sid,
        "parentId": None,
        "name": name,
        "kind": "internal",
        "startedMs": 1_700_000_000_000,
        "durMs": 5,
        "hiddenMs": 0,
        "status": "unset",
        "statusMessage": None,
        "attributes": {},
        "events": [],
    }


class WatermarkTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "traces.db"
        self.state = Path(self.tmp.name) / "state.json"
        self.store = traces.TraceStore(self.db)
        self.cfg = fwd.Config({"TRACES_DB": str(self.db), "INSTANA_STATE": str(self.state)})
        self.sent: list[dict] = []
        self.real_post = fwd.post
        fwd.post = lambda cfg, dest, path, doc, dry_run: (self.sent.append(doc), (True, "200 OK"))[1]
        # The quiet window is a duplicate-avoidance optimisation, not the
        # correctness property, so the race test turns it off and asserts the
        # sequence watermark alone is enough. `test_quiet_window_defers` covers
        # the window itself.
        self.real_quiet = instana_backlog.QUIET_MS
        instana_backlog.QUIET_MS = 0

    def tearDown(self):
        fwd.post = self.real_post
        instana_backlog.QUIET_MS = self.real_quiet
        self.store.close()
        self.tmp.cleanup()

    def run_forwarder(self) -> None:
        self.assertEqual(fwd.forward_traces(self.cfg, DEST, dry_run=False, verbose=False), 0)

    def span_names(self) -> list[str]:
        """Every span name in everything that has left, in send order."""
        out = []
        for doc in self.sent:
            for rs in doc.get("resourceSpans", []):
                for ss in rs.get("scopeSpans", []):
                    out += [s["name"] for s in ss.get("spans", [])]
        return out

    # ---- the race ----------------------------------------------------------

    def test_late_browser_spans_are_forwarded_exactly_once(self):
        # 1. The serving plane writes its span. Class `unknown`: a server batch
        #    never learns the tab's session id, exactly as in production.
        self.store.record(
            {
                "resource": {"session.id": "unknown", "kh.class": "unknown"},
                "spans": [span(SERVER, "serve.page", kind="server")],
            }
        )
        # 2. The forwarder runs INSIDE the 20-second flush window.
        self.run_forwarder()
        self.assertEqual(self.span_names(), ["serve.page"])

        # 3. The tab flushes. Same trace, EARLIER start time than the watermark
        #    the old code had already advanced past.
        self.store.record(
            {
                "resource": {"session.id": "sess-abc", "kh.class": "human"},
                "spans": [
                    span(BROWSER1, "page.load", start=1_699_999_999_000),
                    span(BROWSER2, "station.open", parent=BROWSER1, start=1_699_999_999_500),
                ],
            }
        )

        # 4. The next run must pick them up. This is the assertion the
        #    started_ms watermark failed: it selected nothing at all.
        self.run_forwarder()
        self.assertEqual(sorted(self.span_names()[-3:]), ["page.load", "serve.page", "station.open"])

        # 5. EXACTLY once: a third run with nothing new ships nothing, so the
        #    fix cannot be "resend everything every time".
        before = len(self.sent)
        self.run_forwarder()
        self.assertEqual(len(self.sent), before)

    def test_watermark_survives_a_restart(self):
        self.store.record({"resource": {}, "spans": [span(SERVER, "serve.page", kind="server")]})
        self.run_forwarder()
        # A fresh Config over the same state file is what the next timer tick is.
        cold = fwd.Config({"TRACES_DB": str(self.db), "INSTANA_STATE": str(self.state)})
        self.assertEqual(fwd.forward_traces(cold, DEST, dry_run=False, verbose=False), 0)
        self.assertEqual(self.span_names(), ["serve.page"])

    def test_a_legacy_state_file_converts_instead_of_replaying(self):
        """An upgrade must not re-ship a fortnight of history into the tenant."""
        self.store.record({"resource": {}, "spans": [span(SERVER, "serve.page", start=1_700_000_000_000)]})
        self.store.record(
            {"resource": {}, "spans": [span(BROWSER1, "page.load", start=1_700_000_500_000, trace="1" * 32)]}
        )
        # Only `lastTraceStartedMs`, as every state file written before the fix.
        instana_backlog.write_state(self.state, {"lastTraceStartedMs": 1_700_000_000_000})
        self.assertEqual(instana_backlog.resume_seq(self.cfg, instana_backlog.read_state(self.state)), 1)
        self.run_forwarder()
        self.assertEqual(self.span_names(), ["page.load"])

    def test_quiet_window_defers_a_trace_that_is_still_taking_spans(self):
        instana_backlog.QUIET_MS = self.real_quiet
        self.store.record({"resource": {}, "spans": [span(SERVER, "serve.page", kind="server")]})
        self.run_forwarder()
        self.assertEqual(self.sent, [])


class DrainTest(unittest.TestCase):
    """A run must catch up, not tick along one batch at a time.

    Everything here drives `instana_batch.drain()` through its three injected
    callbacks: no sqlite, no socket, no tenant. The loop's contract is the whole
    subject, so testing it against fakes is not a compromise — it is the only
    way to state "with 7 pages pending, a run ships all 7" without also
    asserting how fast sqlite is.
    """

    def drain(self, pages, **kw):
        """`pages` is a list of trace-lists, handed out in order as the backlog."""
        self.shipped, self.marks = [], []
        remaining = list(pages)

        def fetch(seq):
            if not remaining:
                return [], seq
            page = remaining.pop(0)
            return page, max(t["ingestSeq"] for t in page)

        def ship(chunk):
            self.shipped.append(chunk)
            return self.ship_result(chunk)

        return instana_batch.drain(0, fetch, ship, self.marks.append, sizer=lambda spans: 10 * len(spans), **kw)

    def ship_result(self, chunk):
        return (True, "200 OK")

    @staticmethod
    def trace(seq, nspans=1):
        return {
            "traceId": f"{seq:032x}",
            "sessionId": "s",
            "ingestSeq": seq,
            "spans": [out_span(f"{seq * 1000 + i:016x}", f"n{i}") for i in range(nspans)],
        }

    def test_a_run_drains_a_multi_batch_backlog_instead_of_shipping_one_batch(self):
        """THE THROUGHPUT DEFECT. Seven pages are pending; the old code shipped
        the first and exited, leaving six for the next five-minute tick."""
        pages = [[self.trace(p * 10 + i) for i in range(10)] for p in range(7)]
        stat = self.drain(pages)
        self.assertEqual(stat["stop"], "caught up")
        self.assertEqual(stat["traces"], 70, "a run must ship every pending page, not the first one")
        self.assertEqual(stat["seq"], 69)
        self.assertGreater(len(self.shipped), 1)

    def test_the_run_budget_bounds_a_bottomless_backlog(self):
        """Draining must not mean running past the timer interval: an overrun
        run is killed by TimeoutStartSec AND costs the next tick."""
        # A clock that jumps past the budget on its third reading: two pages go
        # out, then the run stops of its own accord with pages still pending.
        ticks = iter([0, 0, 1, 2, 130])
        clock = lambda: next(ticks, 130)  # noqa: E731
        pages = [[self.trace(p * 2 + i) for i in range(2)] for p in range(50)]
        stat = self.drain(pages, budget_s=120, clock=clock)
        self.assertIn("time budget", stat["stop"])
        self.assertTrue(stat["ok"], "hitting the budget is a normal stop, not a failure")
        self.assertLess(stat["traces"], 100)
        # And it stopped on a watermark it had actually shipped, so the next
        # run resumes there rather than replaying or skipping.
        self.assertEqual(stat["seq"], self.marks[-1])

    def test_a_failed_request_stops_the_run_without_advancing_past_it(self):
        """No-loss survives draining: the watermark may only cover successes."""
        pages = [[self.trace(i) for i in range(1, 6)], [self.trace(i) for i in range(6, 11)]]
        self.ship_result = lambda chunk: (False, "unreachable: connection refused")
        stat = self.drain(pages, max_spans=1)
        self.assertFalse(stat["ok"])
        self.assertEqual(stat["seq"], 0, "nothing succeeded, so the watermark must not move")
        self.assertEqual(self.marks, [])


class BatchSizeTest(unittest.TestCase):
    """THE SIZE DEFECT. Batching by trace count cannot bound a request."""

    @staticmethod
    def trace(seq, nspans):
        return {
            "traceId": f"{seq:032x}",
            "sessionId": "s",
            "ingestSeq": seq,
            "spans": [out_span(f"{seq * 100000 + i:016x}", f"n{i}") for i in range(nspans)],
        }

    def plan(self, traces, max_spans=100, max_bytes=1000):
        return instana_batch.requests_for(traces, max_spans, max_bytes, sizer=lambda s: 10 * len(s))

    def test_batches_split_on_span_count_not_trace_count(self):
        """One fat trace among ninety-nine thin ones is what put 16,226 spans in
        a '100 trace' request and broke the pipe. Every request must be bounded
        in SPANS however the traces are shaped."""
        traces = [self.trace(1, 90)] + [self.trace(i, 1) for i in range(2, 40)]
        plan, dropped = self.plan(traces, max_spans=50, max_bytes=10**9)
        self.assertEqual(dropped, [])
        for chunk, _ in plan:
            self.assertLessEqual(sum(len(t["spans"]) for t in chunk), 50)
        # Nothing lost in the split: every span still goes exactly once.
        shipped = [s["spanId"] for chunk, _ in plan for t in chunk for s in t["spans"]]
        self.assertEqual(len(shipped), len(set(shipped)))
        self.assertEqual(len(shipped), sum(len(t["spans"]) for t in traces))

    def test_batches_split_on_body_bytes_too(self):
        plan, _ = self.plan([self.trace(i, 10) for i in range(1, 20)], max_spans=10**9, max_bytes=200)
        for chunk, _ in plan:
            self.assertLessEqual(10 * sum(len(t["spans"]) for t in chunk), 200)

    def test_one_oversized_trace_is_split_rather_than_retried_forever(self):
        """A single trace bigger than any allowed request used to be selected,
        refused and re-selected every five minutes, for good."""
        big = self.trace(7, 500)
        plan, dropped = self.plan([big], max_spans=100, max_bytes=10**9)
        self.assertEqual(dropped, [])
        self.assertEqual(len(plan), 5)
        for chunk, _ in plan:
            self.assertLessEqual(len(chunk[0]["spans"]), 100)
        # Only the LAST piece carries the watermark: a failure part-way through
        # one trace must leave the mark behind the whole trace.
        self.assertEqual([wm for _, wm in plan], [None, None, None, None, 7])

    def test_a_single_span_too_large_to_ship_is_dropped_loudly_not_retried(self):
        """The end of the line. If even one span exceeds the request budget,
        something must give — and losing that one span is strictly better than
        losing every trace behind it, forever, in silence."""
        t = {
            "traceId": "a" * 32,
            "sessionId": "s",
            "ingestSeq": 9,
            "spans": [out_span("b" * 16, "huge"), out_span("c" * 16, "ok")],
        }

        def sizer(spans):
            return sum(10_000 if s["name"] == "huge" else 10 for s in spans)

        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            plan, dropped = instana_batch.requests_for([t], 100, 1000, sizer=sizer)
        self.assertEqual(len(dropped), 1)
        self.assertIn("DROPPING span", err.getvalue())
        # The watermark still advances past it, which is the whole point.
        self.assertEqual([wm for _, wm in plan], [9])
        self.assertEqual([s["name"] for c, _ in plan for t2 in c for s in t2["spans"]], ["ok"])

    def test_a_size_shaped_refusal_retries_smaller_and_terminates(self):
        """The agent's 5 MiB wall is measured; the SaaS acceptor's is
        undocumented. An endpoint with a smaller limit than our budget must make
        the run shrink, not wedge."""
        seen = []
        pages = [[self.trace(1, 8)]]

        def fetch(seq):
            return (list(pages[0]), 1) if seq == 0 else ([], seq)

        def ship(chunk):
            n = sum(len(t["spans"]) for t in chunk)
            seen.append(n)
            return (False, "unreachable: <urlopen error [Errno 32] Broken pipe>") if n > 1 else (True, "200 OK")

        marks = []
        stat = instana_batch.drain(0, fetch, ship, marks.append, max_spans=8, max_bytes=10**9, sizer=lambda s: len(s))
        self.assertTrue(stat["ok"], f"the run must recover by shrinking, not fail: {stat}")
        self.assertEqual(seen[0], 8)
        self.assertEqual(seen[-1], 1)
        self.assertEqual(marks[-1], 1)

    def test_the_shrink_is_bounded_so_a_doomed_payload_cannot_loop(self):
        """MAX_HALVINGS. If shrinking never helps, the run must give up rather
        than halve forever."""
        calls = []

        def fetch(seq):
            return ([self.trace(1, 64)], 1) if not calls or len(calls) < 99 else ([], seq)

        def ship(chunk):
            calls.append(1)
            return False, "unreachable: <urlopen error [Errno 32] Broken pipe>"

        stat = instana_batch.drain(
            0, fetch, ship, lambda s: None, max_spans=64, max_bytes=10**9, sizer=lambda s: len(s)
        )
        self.assertFalse(stat["ok"])
        self.assertEqual(len(calls), instana_batch.MAX_HALVINGS + 1)


class ConstantTieTest(unittest.TestCase):
    """QUIET_MS is a function of the browser's flush interval, and the two live
    in different languages. Nothing but this test stops them drifting apart."""

    def test_quiet_window_is_safely_longer_than_the_browser_flush(self):
        src = (ROOT / "spa" / "src" / "analytics" / "sink.ts").read_text()
        m = re.search(r"const FLUSH_MS = ([\d_]+);", src)
        self.assertIsNotNone(m, "FLUSH_MS moved or was renamed in spa/src/analytics/sink.ts")
        flush_ms = int(m.group(1).replace("_", ""))
        self.assertGreaterEqual(
            instana_backlog.QUIET_MS,
            2 * flush_ms,
            "QUIET_MS must stay comfortably above sink.ts's FLUSH_MS — a flush that is slow, "
            "retried, or from a backgrounded tab arrives later than one interval",
        )


if __name__ == "__main__":
    unittest.main()

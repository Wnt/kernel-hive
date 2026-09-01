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
"""

from __future__ import annotations

import importlib.util
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "serve"))
sys.path.insert(0, str(ROOT / "scripts" / "observability"))

import instana_backlog  # noqa: E402
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
    return {"t": trace, "s": sid, "p": parent, "n": name, "kd": kind, "st": start, "d": 5, "h": 0, "k": "unset"}


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

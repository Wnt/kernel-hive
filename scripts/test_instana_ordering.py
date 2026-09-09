"""Forwarding ORDER, and the telemetry filter — the 2026-09-01 pair.

BESIDE `test_instana_forward.py` RATHER THAN IN IT, for the reason that file's
own subjects were split out of `instana-forward.py`: it reached its line budget
(scripts/check-file-size.mjs, 600 for Python). The harness is imported from it
rather than rebuilt, so there is exactly one definition of "a span as the store
intakes it" and one loader for the dashed script.

WHAT THESE TWO DEFECTS HAVE IN COMMON is that neither is about losing data —
`WatermarkTest` next door owns that property and neither of these may weaken it.
They are about a trace arriving in ONE PIECE and about a call list a person can
read. Both are stated here as assertions the code before 2026-09-01 could not
pass.
"""

from __future__ import annotations

import re
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "serve"))
sys.path.insert(0, str(ROOT / "scripts" / "observability"))

import instana_backlog  # noqa: E402
import traces  # noqa: E402

from test_instana_forward import BROWSER1, BROWSER2, DEST, SERVER, T_RACE, fwd, span  # noqa: E402


class CarrierOrderingTest(unittest.TestCase):
    """A trace's daemon half and its browser half must leave in the SAME send.

    Time is moved by backdating the store's own `updated_ms` rather than by
    freezing the clock: `updated_ms` IS the wall clock of the last span landing,
    it is the only thing the quiet window compares against, and rewriting it is
    both smaller and more honest than patching `time.time` under three modules.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "traces.db"
        self.state = Path(self.tmp.name) / "state.json"
        self.store = traces.TraceStore(self.db)
        self.cfg = fwd.Config({"TRACES_DB": str(self.db), "INSTANA_STATE": str(self.state)})
        self.sent: list[dict] = []
        self.real_post = fwd.post
        fwd.post = lambda cfg, dest, path, doc, dry_run: (self.sent.append(doc), (True, "200 OK"))[1]

    def tearDown(self):
        fwd.post = self.real_post
        self.store.close()
        self.tmp.cleanup()

    def quiet_for(self, ms: int) -> None:
        """Pretend the trace has taken nothing new for `ms` milliseconds."""
        db = sqlite3.connect(self.db)
        try:
            db.execute("UPDATE trace SET updated_ms=?", (int(time.time() * 1000) - ms,))
            db.commit()
        finally:
            db.close()

    def run_forwarder(self) -> None:
        self.assertEqual(fwd.forward_traces(self.cfg, DEST, dry_run=False, verbose=False), 0)

    def names(self) -> list[list[str]]:
        """Span names per SEND — the shape of the question, since "shipped
        together" is a statement about which request they were in."""
        out = []
        for doc in self.sent:
            names = []
            for rs in doc.get("resourceSpans", []):
                for ss in rs.get("scopeSpans", []):
                    names += [s["name"] for s in ss.get("spans", [])]
            out.append(sorted(names))
        return out

    def record_browser_half(self):
        self.store.record(
            {
                "resource": {"session.id": "sess-abc", "kh.class": "human"},
                "spans": [
                    span(SERVER, "serve.signal", kind="server"),
                    span(BROWSER1, "input.edge", parent=SERVER, kind="client"),
                ],
            }
        )

    def record_daemon_half(self):
        """What `trace-ship.py` carries in, up to two minutes later."""
        self.store.record(
            {
                "resource": {"session.id": "unknown", "kh.class": "unknown"},
                "spans": [
                    dict(
                        span(BROWSER2, "input.dispatch", parent=BROWSER1, kind="server"),
                        a={"kh.service": "kernel-hive-daemon", "kh.station": "solaris"},
                    )
                ],
            }
        )

    def test_a_trace_is_not_shipped_before_its_daemon_half_can_have_arrived(self):
        """100 seconds of quiet is past the OLD 90-second window and short of
        the carrier period. Under the old constant this shipped the browser half
        alone; it must now ship nothing at all."""
        self.record_browser_half()
        self.quiet_for(100_000)
        self.run_forwarder()
        self.assertEqual(self.sent, [])

    def test_both_halves_leave_in_one_send_and_only_once(self):
        self.record_browser_half()
        self.quiet_for(100_000)
        self.run_forwarder()  # too soon — the carrier has not run yet
        self.record_daemon_half()  # kh-trace-ship, at +2 min
        self.quiet_for(instana_backlog.QUIET_MS + 10_000)
        self.run_forwarder()
        self.assertEqual(self.names(), [["input.dispatch", "input.edge", "serve.signal"]])
        # …and nothing is re-sent afterwards: the ordering fix must not have
        # been bought by giving up exactly-once.
        self.run_forwarder()
        self.assertEqual(len(self.sent), 1)


class TelemetryFilterTest(unittest.TestCase):
    """The FALLBACK, because Instana's own `synthetic` mark is not honoured over
    OTLP ingest (measured — telemetry_paths.py documents the five-spelling
    experiment). A trace made entirely of our own polling does not leave the
    box; anything with real work in it does, whole."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "traces.db"
        self.state = Path(self.tmp.name) / "state.json"
        self.store = traces.TraceStore(self.db)
        self.env = {"TRACES_DB": str(self.db), "INSTANA_STATE": str(self.state)}
        self.cfg = fwd.Config(dict(self.env))
        self.sent: list[dict] = []
        self.real_post = fwd.post
        fwd.post = lambda cfg, dest, path, doc, dry_run: (self.sent.append(doc), (True, "200 OK"))[1]
        self.real_quiet = instana_backlog.QUIET_MS
        instana_backlog.QUIET_MS = 0

    def tearDown(self):
        fwd.post = self.real_post
        instana_backlog.QUIET_MS = self.real_quiet
        self.store.close()
        self.tmp.cleanup()

    def poll(self, sid, trace, route="/clientcmd", name="serve.clientcmd"):
        return dict(
            span(sid, name, kind="server", trace=trace),
            a={"kh.service": "kernel-hive-serve", "http.route": route},
        )

    def ship_all(self, cfg=None):
        self.assertEqual(fwd.forward_traces(cfg or self.cfg, DEST, dry_run=False, verbose=False), 0)
        out = []
        for doc in self.sent:
            for rs in doc.get("resourceSpans", []):
                for ss in rs.get("scopeSpans", []):
                    out += [s["name"] for s in ss.get("spans", [])]
        return sorted(out)

    def test_a_poll_only_trace_is_held_back(self):
        self.store.record({"resource": {}, "spans": [self.poll(SERVER, T_RACE)]})
        self.assertEqual(self.ship_all(), [])

    def test_a_trace_with_real_work_in_it_is_never_dropped(self):
        """The whole-trace test, not a per-span trim: a trace that somehow held
        both must ship intact rather than ship with a hole."""
        self.store.record(
            {
                "resource": {},
                "spans": [
                    self.poll(SERVER, T_RACE),
                    span(BROWSER1, "station.open", parent=SERVER, trace=T_RACE),
                ],
            }
        )
        self.assertEqual(self.ship_all(), ["serve.clientcmd", "station.open"])

    def test_serve_signal_still_ships(self):
        self.store.record(
            {
                "resource": {},
                "spans": [self.poll(SERVER, T_RACE, route="/signal/{station}.json", name="serve.signal")],
            }
        )
        self.assertEqual(self.ship_all(), ["serve.signal"])

    def test_the_watermark_still_advances_past_what_was_dropped(self):
        """`drain()` stops on an empty page, so a filter upstream of it would
        stall the run and re-fetch the same page forever. This is that
        regression: after a run of nothing but polls, a later real trace must
        still ship and the dropped ones must not come back."""
        for i in range(3):
            self.store.record({"resource": {}, "spans": [self.poll(f"b7ad6b716920400{i}", f"{i}" * 32)]})
        self.assertEqual(self.ship_all(), [])
        self.store.record({"resource": {}, "spans": [span(BROWSER2, "station.open", trace=T_RACE)]})
        self.assertEqual(self.ship_all(), ["station.open"])

    def test_the_switch_puts_them_back(self):
        """Easily reversible was the requirement, so it is one variable."""
        self.store.record({"resource": {}, "spans": [self.poll(SERVER, T_RACE)]})
        cfg = fwd.Config(dict(self.env, INSTANA_FORWARD_TELEMETRY="1"))
        self.assertEqual(self.ship_all(cfg), ["serve.clientcmd"])


class ConstantTieTest(unittest.TestCase):
    """QUIET_MS is a function of the browser's flush interval AND of the daemon
    carrier's period. All three live in different languages and file formats;
    nothing but this test stops them drifting apart."""

    def test_the_carrier_period_matches_the_unit_that_actually_runs_it(self):
        unit = (ROOT / "scripts" / "observability" / "kh-trace-ship.timer").read_text()
        m = re.search(r"OnUnitActiveSec=(\d+)min", unit)
        self.assertIsNotNone(m, "OnUnitActiveSec moved or changed units in kh-trace-ship.timer")
        self.assertEqual(
            instana_backlog.DAEMON_CARRIER_MS,
            int(m.group(1)) * 60_000,
            "DAEMON_CARRIER_MS must equal kh-trace-ship.timer's period — it is the whole "
            "reason the quiet window is as long as it is",
        )

    def test_quiet_window_clears_the_daemon_carrier_period(self):
        """The 2026-09-01 defect in one assertion: a window shorter than the
        carrier ships a trace before its daemon spans can exist in the store,
        and then ships it again when they arrive."""
        self.assertGreater(
            instana_backlog.QUIET_MS,
            instana_backlog.DAEMON_CARRIER_MS,
            "QUIET_MS must exceed the daemon carrier period or a trace with a daemon half "
            "is forwarded in two pieces, which mis-correlates inside Instana's ~2s window",
        )

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

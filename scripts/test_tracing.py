"""Tests for the serving plane's tracer.

Two rules carry almost all of these, and both are the contract's
(docs/lab/TRACE-CONTEXT.md):

  * TELEMETRY MAY NEVER BREAK THE THING IT MEASURES. A malformed header, a
    store that raises on every call, a handler that throws — none of them may
    change what a request answers. `RaisingStoreTest` is the strong form: it
    binds a store whose every method raises and drives a whole request through
    the instrumented handler.
  * NEVER INVENT A PARENT, AND NEVER OVERRULE THE SAMPLER. An unknown context
    starts a new trace; an inbound `sampled=0` produces no spans at all, because
    a layer that sampled for itself puts holes in other people's flame graphs.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "serve"))

import traces  # noqa: E402
import tracing  # noqa: E402
import tracing_http  # noqa: E402

TRACE = "0af7651916cd43dd8448eb211c80319c"
SPAN = "b7ad6b7169203331"


class FakeHandler:
    """The narrowest thing `tracing_http.instrument` needs: a path, headers, a
    `send_response`, and a verb. Standing in for BaseHTTPRequestHandler keeps
    these tests free of sockets and TLS, which is what lets them assert the
    NEVER-RAISES property against a handler that deliberately throws."""

    public = False

    def __init__(self, path="/signal/beos.json", headers=None, status=200, boom=None, hook=None):
        self.path = path
        self.command = "GET"
        self.headers = headers or {}
        self.replied = None
        self._status = status
        self._boom = boom
        #: Run INSIDE the traced verb, so a test can open children the way a
        #: route body does — under the request span the wrapper just opened.
        self._hook = hook
        #: Everything `send_header` was given, in order — the return-leg
        #: headers are asserted off this rather than off a socket.
        self.sent_headers = []
        self.ended = False

    def send_response(self, code, message=None):
        self.replied = code

    def send_header(self, key, value):
        self.sent_headers.append((key, value))

    def end_headers(self):
        self.ended = True

    def do_GET(self):
        if self._hook:
            self._hook()
        if self._boom:
            raise self._boom
        self.send_response(self._status)
        self.end_headers()
        return "answered"

    def do_POST(self):
        return self.do_GET()


tracing_http.instrument(FakeHandler)


class RaisingStore:
    """Every door into it fails. Nothing may escape."""

    def record(self, batch):
        raise RuntimeError("store is on fire")

    def prune(self, *a, **kw):
        raise RuntimeError("store is on fire")


class Base(unittest.TestCase):
    def setUp(self):
        tracing.reset_for_tests()
        self.tmp = tempfile.TemporaryDirectory()
        self.store = traces.TraceStore(Path(self.tmp.name) / "traces.db")
        tracing.bind(self.store)

    def tearDown(self):
        tracing.reset_for_tests()
        self.store.close()
        self.tmp.cleanup()

    def stored(self, trace_id):
        tracing.flush()
        return self.store.trace(trace_id)


# ---------------------------------------------------------------------------
# trace context
# ---------------------------------------------------------------------------


class ContextTest(Base):
    def test_an_inbound_traceparent_makes_the_root_span_its_child(self):
        h = FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-01"})
        h.do_GET()
        doc = self.stored(TRACE)
        self.assertIsNotNone(doc)
        self.assertEqual(doc["spans"][0]["parentId"], SPAN)
        self.assertEqual(doc["spans"][0]["kind"], "server")

    def test_no_header_starts_a_new_trace_with_no_parent(self):
        FakeHandler().do_GET()
        tracing.flush()
        found = self.store.search()["traces"]
        self.assertEqual(len(found), 1)
        self.assertNotEqual(found[0]["traceId"], TRACE)
        self.assertIsNone(self.store.trace(found[0]["traceId"])["spans"][0]["parentId"])

    def test_a_malformed_header_starts_a_new_trace_and_never_fails_the_request(self):
        # Every one of these is something a stranger can put on the wire. The
        # request must answer normally and the span must NOT claim the bad id.
        for bad in ["", "garbage", f"00-{TRACE}-{SPAN}", f"ff-{TRACE}-{SPAN}-01", f"00-{'0' * 32}-{SPAN}-01"]:
            with self.subTest(bad=bad):
                h = FakeHandler(headers={"traceparent": bad})
                self.assertEqual(h.do_GET(), "answered")
        tracing.flush()
        rows = self.store.search()["traces"]
        self.assertEqual(len(rows), 5)
        self.assertNotIn(TRACE, [r["traceId"] for r in rows])

    def test_an_unsampled_parent_produces_no_spans_at_all(self):
        # Contract §4: the browser decides. A layer that traced anyway would
        # leave a fragment of a trace nobody else contributed to.
        h = FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-00"})
        self.assertEqual(h.do_GET(), "answered")
        tracing.flush()
        self.assertEqual(self.store.search()["total"], 0)

    def test_a_child_with_no_open_request_span_is_dropped_not_orphaned(self):
        with tracing.child("serve.ticket.mint"):
            pass
        tracing.flush()
        self.assertEqual(self.store.search()["total"], 0)


# ---------------------------------------------------------------------------
# routing — the allowlist, and what it deliberately excludes
# ---------------------------------------------------------------------------


class RouteTest(unittest.TestCase):
    def test_static_assets_and_the_spa_fallback_are_not_traced(self):
        # THE decision in tracing_http: a span per PNG buries every span
        # anybody wants, and the volume is already in the access log.
        for path in [
            "/",
            "/index.html",
            "/assets/index-a1b2c3.js",
            "/posters/beos.png",
            "/os/win95",
            "/favicon.ico",
            "/healthz",
            "/traces",
            "/coverage",
        ]:
            with self.subTest(path=path):
                self.assertIsNone(tracing_http.route_of(path))

    def test_a_station_path_becomes_a_template_plus_an_attribute(self):
        # `http.route` is low-cardinality by definition; the station goes in
        # kh.station, which is a public exhibit id.
        self.assertEqual(tracing_http.route_of("/signal/beos.json"), ("/signal/{station}.json", "serve.signal", "beos"))
        self.assertEqual(tracing_http.route_of("/restore/win95"), ("/restore/{station}", "serve.restore", "win95"))
        self.assertEqual(
            tracing_http.route_of("/webrtc/irix/offer"), ("/webrtc/{station}/offer", "serve.webrtc.offer", "irix")
        )

    def test_literal_routes_derive_their_span_name_from_the_path(self):
        self.assertEqual(tracing_http.route_of("/walkin/claim")[1], "serve.walkin.claim")
        self.assertEqual(tracing_http.route_of("/auth/login/begin")[1], "serve.auth.login.begin")

    def test_every_derived_name_is_one_the_store_will_accept(self):
        # A name traces.NAME_RE refuses is a span silently dropped at intake.
        for path in sorted(tracing_http._LITERAL):
            with self.subTest(path=path):
                self.assertRegex(tracing_http.route_of(path)[1], traces.NAME_RE)

    def test_a_signal_path_with_a_nested_segment_is_not_a_station(self):
        self.assertIsNone(tracing_http.route_of("/signal/a/b.json"))


# ---------------------------------------------------------------------------
# span shape
# ---------------------------------------------------------------------------


class ShapeTest(Base):
    def test_the_request_span_carries_the_semantic_convention_attributes(self):
        h = FakeHandler(path="/restore/win95", headers={"traceparent": f"00-{TRACE}-{SPAN}-01", "Host": "labhost:8443"})
        h.command = "POST"
        h.do_POST()
        span = self.stored(TRACE)["spans"][0]
        self.assertEqual(span["attributes"]["http.request.method"], "POST")
        self.assertEqual(span["attributes"]["http.route"], "/restore/{station}")
        self.assertEqual(span["attributes"]["http.response.status_code"], 200)
        self.assertEqual(span["attributes"]["server.address"], "labhost")
        self.assertEqual(span["attributes"]["kh.station"], "win95")
        self.assertEqual(span["attributes"]["kh.listener"], "lan")
        self.assertEqual(span["status"], "ok")

    def test_hidden_ms_is_zero_because_a_server_has_no_tab(self):
        FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-01"}).do_GET()
        self.assertEqual(self.stored(TRACE)["spans"][0]["hiddenMs"], 0)

    def test_a_5xx_is_an_error_span_and_a_4xx_is_not(self):
        FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-01"}, status=503).do_GET()
        self.assertEqual(self.stored(TRACE)["spans"][0]["status"], "error")
        other = "1bf7651916cd43dd8448eb211c80319d"
        FakeHandler(headers={"traceparent": f"00-{other}-{SPAN}-01"}, status=404).do_GET()
        self.assertEqual(self.stored(other)["spans"][0]["status"], "ok")

    def test_a_thrown_handler_marks_the_span_and_re_raises_unchanged(self):
        h = FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-01"}, boom=ValueError("kaboom"))
        with self.assertRaises(ValueError):
            h.do_GET()
        span = self.stored(TRACE)["spans"][0]
        self.assertEqual(span["status"], "error")
        self.assertEqual(span["attributes"]["error.type"], "ValueError")

    def test_an_exception_event_carries_no_message_and_no_stack(self):
        # The type is a policy fact; the message is arbitrary server text that
        # can quote a path, a header or a body. traces.py refuses the stack at
        # intake and this refuses the message at the source.
        h = FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-01"}, boom=ValueError("secret ticket abc123"))
        with self.assertRaises(ValueError):
            h.do_GET()
        events = self.stored(TRACE)["spans"][0]["events"]
        self.assertEqual([e["n"] for e in events], ["exception"])
        self.assertEqual(events[0]["a"], {"exception.type": "ValueError"})

    def test_nested_children_nest(self):
        def body():
            with tracing.child("serve.signal.load"), tracing.child("serve.ticket.mint", {"kh.ticket.kind": "station"}):
                pass

        FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-01"}, hook=body).do_GET()
        by_name = {s["name"]: s for s in self.stored(TRACE)["spans"]}
        self.assertEqual(by_name["serve.signal.load"]["parentId"], by_name["serve.signal"]["spanId"])
        self.assertEqual(by_name["serve.ticket.mint"]["parentId"], by_name["serve.signal.load"]["spanId"])
        self.assertEqual(by_name["serve.ticket.mint"]["kind"], "internal")
        # Subset, not equality: every span this module emits also carries
        # `kh.service`, so that the OTLP export can tell a Python handler from
        # browser JavaScript instead of labelling both `kernel-hive-spa`.
        self.assertEqual(by_name["serve.ticket.mint"]["attributes"].get("kh.ticket.kind"), "station")
        self.assertEqual(by_name["serve.ticket.mint"]["attributes"].get("kh.service"), tracing.SERVICE_NAME)


# ---------------------------------------------------------------------------
# the buffer
# ---------------------------------------------------------------------------


class BufferTest(Base):
    def test_ending_a_span_does_no_io_until_the_throttle_expires(self):
        tracing._next_flush = float("inf")
        FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-01"}).do_GET()
        self.assertEqual(tracing.stats()["buffered"], 1)
        self.assertIsNone(self.store.trace(TRACE))
        self.assertEqual(tracing.flush(), 1)
        self.assertIsNotNone(self.store.trace(TRACE))

    def test_the_buffer_is_bounded_and_overflow_is_counted_not_raised(self):
        tracing._next_flush = float("inf")
        for _ in range(tracing.MAX_BUFFERED + 5):
            tracing.Span(TRACE, None, "serve.request").end()
        self.assertEqual(tracing.stats()["buffered"], tracing.MAX_BUFFERED)
        self.assertGreaterEqual(tracing.stats()["dropped"], 5)

    def test_unbound_spans_cost_nothing_and_go_nowhere(self):
        tracing.reset_for_tests()
        self.assertIs(tracing.start_trace("walkin.reap"), tracing.NOOP)
        self.assertEqual(FakeHandler().do_GET(), "answered")
        self.assertEqual(tracing.stats()["buffered"], 0)


# ---------------------------------------------------------------------------
# the property everything else rests on
# ---------------------------------------------------------------------------


class RaisingStoreTest(unittest.TestCase):
    """A store that fails on every call may not fail a single request."""

    def setUp(self):
        tracing.reset_for_tests()
        tracing.bind(RaisingStore())

    def tearDown(self):
        tracing.reset_for_tests()

    def test_a_request_still_answers_when_every_store_call_raises(self):
        for _i in range(50):
            h = FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-01"})
            tracing._next_flush = 0.0  # force a flush attempt on every request
            self.assertEqual(h.do_GET(), "answered")
            self.assertEqual(h.replied, 200)
        self.assertGreater(tracing.stats()["dropped"], 0)

    def test_nested_instrumentation_still_raises_nothing(self):
        with tracing.child("serve.signal.load") as span:
            span.attr("kh.station", "beos")
            span.event("something")
            span.record_exception(RuntimeError("x"))
        self.assertEqual(tracing.flush(), 0)

    def test_a_handler_s_own_exception_is_not_swallowed_by_a_broken_store(self):
        h = FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-01"}, boom=KeyError("k"))
        with self.assertRaises(KeyError):
            h.do_GET()


# ---------------------------------------------------------------------------
# the return leg: traceresponse + Server-Timing
# ---------------------------------------------------------------------------


class ResponseHeaderTest(Base):
    """A response has to name the span that answered it, or the browser can
    only ever guess whether the id it SENT was the id the server used (it is
    not, whenever the inbound header was malformed or absent). Two headers,
    one span: `traceresponse` is ours, `Server-Timing: intid` is what Instana's
    EUM agent parses into `backendTraceId`."""

    def headers_of(self, handler):
        return {k.lower(): v for k, v in handler.sent_headers}

    def test_a_traced_response_names_its_own_span_in_both_headers(self):
        h = FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-01"})
        h.do_GET()
        doc = self.stored(TRACE)
        root = doc["spans"][0]
        sent = self.headers_of(h)
        self.assertEqual(sent["traceresponse"], f"00-{TRACE}-{root['spanId']}-01")
        self.assertEqual(sent["server-timing"], f"intid;desc={TRACE}")

    def test_the_ids_are_the_response_span_not_the_inbound_parent(self):
        """The whole point: the caller learns the id of the span the SERVER
        opened. Echoing the inbound span id back would be indistinguishable
        from working, and useless."""
        h = FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-01"})
        h.do_GET()
        sent = self.headers_of(h)
        self.assertNotIn(SPAN, sent["traceresponse"])

    def test_an_untraced_route_emits_neither_header(self):
        h = FakeHandler(path="/assets/app-abcdef01.js")
        h.do_GET()
        self.assertEqual(self.headers_of(h), {})

    def test_an_unsampled_parent_emits_neither_header(self):
        """Unsampled in means nothing out, headers included — there is no span
        to name, and naming one anyway would advertise a trace the store will
        never hold."""
        h = FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-00"})
        h.do_GET()
        self.assertEqual(self.headers_of(h), {})

    def test_tracing_unbound_emits_neither_header(self):
        tracing.reset_for_tests()  # no store: every span is NOOP
        h = FakeHandler()
        h.do_GET()
        self.assertEqual(self.headers_of(h), {})

    def test_a_keepalive_connection_does_not_leak_ids_onto_the_next_response(self):
        """One handler instance serves many requests. The stash is per
        response, so an untraced second request on the same connection must
        come back bare."""
        h = FakeHandler(headers={"traceparent": f"00-{TRACE}-{SPAN}-01"})
        h.do_GET()
        self.assertIn("traceresponse", self.headers_of(h))
        h.sent_headers = []
        h.path = "/assets/app-abcdef01.js"
        h.do_GET()
        self.assertEqual(self.headers_of(h), {})

    def test_a_response_still_closes_its_headers_when_the_stash_is_garbage(self):
        """`end_headers` is on the path of every reply this server makes. It
        may never fail because of a telemetry header."""
        h = FakeHandler()
        h._kh_trace_response = "not a dict"
        h.end_headers()
        self.assertTrue(h.ended)

    def test_the_ids_are_well_formed_for_a_freshly_minted_trace(self):
        h = FakeHandler()
        h.do_GET()
        sent = self.headers_of(h)
        self.assertRegex(sent["traceresponse"], r"^00-[0-9a-f]{32}-[0-9a-f]{16}-01$")
        self.assertRegex(sent["server-timing"], r"^intid;desc=[0-9a-f]{32}$")
        # Instana silently DROPS a backendTraceId that is not 16 or 32 hex, so
        # the length is the feature, not an incidental property of the format.
        self.assertEqual(len(sent["server-timing"].split("=", 1)[1]), 32)


if __name__ == "__main__":
    unittest.main()

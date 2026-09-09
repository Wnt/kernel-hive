"""One response, one pair of return-leg headers; one request, one server span.

THE BUG THESE PIN, measured live on 2026-09-01 against the ungated LAN
listener:

    $ curl -sk --http1.1 -D- -o /dev/null "https://<lan>:8443/auth/state"
    Content-Type: text/html; charset=utf-8
    traceresponse: 00-1d3cdf6c...f8f9-4cb5d81e83892474-01
    Server-Timing: intid;desc=1d3cdf6c...f8f9
    traceresponse: 00-12e6e93e...c877-3ce4fc70a19cf4fc-01
    Server-Timing: intid;desc=12e6e93e...c877

Two pairs, two UNRELATED trace ids, one request. The `text/html` is the tell:
`auth_routes.dispatch` runs only when `self.public`, so on the LAN listener
every `/auth/*` and `/walkin/*` path falls through to the SPA fallback and is
answered with index.html. That single request therefore hit BOTH span-opening
sites — `tracing_http`'s route allowlist (`serve.auth.state`) and
`static_files`' index.html injection (`serve.page`) — and both wrote their own
copy of the two headers, one via the `end_headers` stash and one via the reply's
`extra` dict. It also put both spans under the browser's ONE client span, so
`/admin/observability` showed a document navigation and an in-page fetch sharing
a parent they could not possibly share.

The invariants, and each is stated so it cannot be satisfied by luck:

  * a traced response carries EXACTLY ONE `traceresponse` and ONE
    `Server-Timing`, whichever code paths ran;
  * one request opens exactly ONE server span, so the meta tag, the headers and
    the recorded span all name the same id;
  * instrumenting a class twice — or a base and then a subclass — cannot double
    anything.

The listener shapes are modelled with the real modules, not mocked: a handler
class whose `do_GET` routes the way `osgallery-https-server.H.do_GET` does
(public -> a JSON auth reply, LAN -> `static_files.serve_static`), instrumented
by the real `tracing_http.instrument`, with `send_header`/`end_headers`
recording what would go on the wire.
"""

from __future__ import annotations

import os
import re
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "serve"))

# `config.py` reads these at import and never again. The webroot this module
# actually serves from is NOT the env one: `Base.setUp` points
# `static_files.WEBROOT` at this module's own directory, because `WEBROOT` is
# one process-wide env var and two test modules that both `setdefault` it serve
# each other's fixtures depending on discovery order.
_WEBROOT_TMP = tempfile.TemporaryDirectory()
WEBROOT = Path(_WEBROOT_TMP.name).resolve()
INDEX_HTML = b"<!doctype html>\n<html>\n  <head>\n    <title>Kernel Hive</title>\n  </head>\n  <body></body>\n</html>\n"
(WEBROOT / "index.html").write_bytes(INDEX_HTML)
(WEBROOT / "signal.json").write_text("{}")

os.environ.setdefault("WEBROOT", str(WEBROOT))
os.environ.setdefault("SIGNAL_CONFIG", str(WEBROOT / "signal.json"))
os.environ.setdefault("CERT", "unused-in-tests")
os.environ.setdefault("KEY", "unused-in-tests")

import static_files  # noqa: E402
import traces  # noqa: E402
import tracing  # noqa: E402
import tracing_http  # noqa: E402

TAG_RE = re.compile(rb'<meta name="traceparent" content="([0-9a-f-]+)">')


class RecordingHandler:
    """`osgallery-https-server.H`'s response framing, minus the socket.

    `_send` mirrors H._send exactly where it matters: `send_response`, then the
    per-response headers, then `extra`, then `end_headers`. That ordering is
    what makes "how many `traceresponse` reach the wire" a real question here.
    """

    public = False

    def __init__(self, path="/", headers=None):
        self.path = path
        self.headers = headers or {}
        self.command = "GET"
        self.sent = []  # (name, value), in wire order
        self.status = None
        self.body = None

    # --- framing primitives the routes call back into -------------------
    def send_response(self, code, *a):
        self.status = code

    def send_header(self, name, value):
        self.sent.append((name, value))

    def end_headers(self):
        pass

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")

    def _send(self, code, body, ctype, cache=True, extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.body = body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()

    # --- the listener's routing, as H.do_GET has it ---------------------
    def do_GET(self):
        path = self.path
        if self.public and path.startswith("/auth/"):
            # The public listener answers the auth ceremonies itself.
            return self._send(200, '{"ok":true}', "application/json")
        # LAN: no auth plane at all, so the SPA fallback answers.
        return static_files.serve_static(self, path)

    def header_values(self, name):
        return [v for k, v in self.sent if k.lower() == name.lower()]


def _handler_class(public=False):
    """A FRESH instrumented class per test: instrumentation mutates a class."""
    cls = type("H", (RecordingHandler,), {"public": public})
    return tracing_http.instrument(cls)


class Base(unittest.TestCase):
    def setUp(self):
        self._webroot = static_files.WEBROOT
        static_files.WEBROOT = WEBROOT
        tracing.reset_for_tests()
        self.tmp = tempfile.TemporaryDirectory()
        self.store = traces.TraceStore(Path(self.tmp.name) / "traces.db")
        tracing.bind(self.store)

    def tearDown(self):
        static_files.WEBROOT = self._webroot
        tracing.reset_for_tests()
        self.store.close()
        self.tmp.cleanup()

    def recorded_spans(self):
        """Every span this store holds, by name. Counted across the WHOLE store
        rather than within one trace, because double instrumentation puts its
        second span in a DIFFERENT trace — a per-trace count would miss it."""
        tracing.flush()
        con = sqlite3.connect(str(self.store.path))
        try:
            return sorted(r[0] for r in con.execute("select name from span"))
        finally:
            con.close()

    def get(self, path, public=False, headers=None, cls=None):
        h = (cls or _handler_class(public))(path, headers)
        h.do_GET()
        return h


class OnePairPerResponseTest(Base):
    """The header count, on every shape of response that can carry them."""

    def assert_one_pair(self, h):
        tr = h.header_values("traceresponse")
        st = [v for v in h.header_values("Server-Timing") if v.startswith("intid;")]
        self.assertEqual(len(tr), 1, f"traceresponse x{len(tr)}: {h.sent}")
        self.assertEqual(len(st), 1, f"Server-Timing x{len(st)}: {h.sent}")
        return tr[0], st[0]

    def test_lan_auth_state_falls_through_to_the_spa_and_still_sends_one_pair(self):
        """THE regression. Allowlisted route + SPA fallback = both span sites."""
        h = self.get("/auth/state")
        self.assertEqual(h.header_values("Content-Type"), ["text/html; charset=utf-8"])
        self.assert_one_pair(h)

    def test_lan_walkin_state_too(self):
        self.assert_one_pair(self.get("/walkin/state"))

    def test_public_auth_state_is_answered_by_the_auth_plane_and_sends_one_pair(self):
        h = self.get("/auth/state", public=True)
        self.assertEqual(h.header_values("Content-Type"), ["application/json"])
        self.assert_one_pair(h)

    def test_an_untraced_page_load_sends_one_pair(self):
        """`/os/win95` is NOT in the allowlist: only `serve.page` exists."""
        self.assert_one_pair(self.get("/os/win95"))

    def test_the_headers_agree_with_each_other_and_with_the_meta_tag(self):
        h = self.get("/auth/state")
        tr, st = self.assert_one_pair(h)
        tag = TAG_RE.search(h.body).group(1).decode("ascii")
        self.assertEqual(tr, tag)
        self.assertEqual(st, f"intid;desc={tag.split('-')[1]}")


class OneSpanPerRequestTest(Base):
    """The header count is the symptom; this is the disease."""

    def test_one_lan_request_records_exactly_one_server_span(self):
        h = self.get("/auth/state")
        tag = TAG_RE.search(h.body).group(1).decode("ascii")
        self.assertEqual(self.recorded_spans(), ["serve.auth.state"])
        # And the meta tag names THAT span, not a second one minted for the tag.
        doc = self.store.trace(tag.split("-")[1])
        self.assertEqual([sp["spanId"] for sp in doc["spans"]], [tag.split("-")[2]])

    def test_two_server_spans_never_share_one_client_parent(self):
        """The `/admin/observability` symptom, pinned at its source.

        A browser sends ONE `traceparent` per HTTP request. If one request
        opened two server spans they would both name that client span as their
        parent — which is what made a `serve.page` and a `serve.auth.state`
        appear as siblings under one `http.client.request`.
        """
        client_span = "80e629dcb1386309"
        trace_id = "3e36bf974bd1b3d0bbddc8c7d7a245ba"
        h = self.get("/auth/state", headers={"traceparent": f"00-{trace_id}-{client_span}-01"})
        self.assertIsNotNone(h)
        tracing.flush()
        doc = self.store.trace(trace_id)
        kids = [s for s in doc["spans"] if s.get("parentId") == client_span]
        self.assertEqual(len(kids), 1, f"{len(kids)} server spans under one client span: {kids}")


class InstrumentIsIdempotentTest(Base):
    """Double instrumentation must be IMPOSSIBLE, not merely absent."""

    def test_instrumenting_the_same_class_twice_changes_nothing(self):
        cls = _handler_class()
        again = tracing_http.instrument(cls)
        self.assertIs(again, cls)
        h = cls("/auth/state")
        h.do_GET()
        self.assertEqual(len(h.header_values("traceresponse")), 1)

    def test_instrumenting_a_base_and_then_a_subclass_does_not_double(self):
        """The shape `H` / `PublicH` has, and the reason idempotence must be
        per METHOD: a class-level flag lives in ONE class's `__dict__`, so the
        subclass looks uninstrumented and every INHERITED method gets wrapped a
        second time.

        Asserted on the PUBLIC path, where the reply is JSON and `static_files`
        never runs — so the only thing that can produce a second span here is
        the double wrap itself. The headers alone would not show it (the inner
        wrapper's stash simply overwrites the outer's), which is exactly why
        this counts recorded SPANS."""
        base = _handler_class()
        sub = tracing_http.instrument(type("PublicH", (base,), {"public": True}))
        h = sub("/auth/state")
        h.do_GET()
        self.assertEqual(len(h.header_values("traceresponse")), 1)
        self.assertEqual(self.recorded_spans(), ["serve.auth.state"])

    def test_a_subclass_that_overrides_and_calls_super_opens_one_span(self):
        """The case no wrapping-time check can see, caught at request time."""
        base = _handler_class()

        def do_GET(self):
            return base.do_GET(self)

        sub = tracing_http.instrument(type("SubH", (base,), {"do_GET": do_GET, "public": True}))
        h = sub("/auth/state")
        h.do_GET()
        self.assertEqual(len(h.header_values("traceresponse")), 1, h.sent)
        self.assertEqual(self.recorded_spans(), ["serve.auth.state"])

    def test_a_subclass_with_its_own_verb_is_still_instrumented(self):
        """Idempotence must not become "never wrap a subclass": an override
        that does NOT call super() is a genuinely new, untraced entry point."""
        base = _handler_class()

        def do_GET(self):
            return self._send(200, "{}", "application/json")

        sub = tracing_http.instrument(type("OwnH", (base,), {"do_GET": do_GET, "public": True}))
        h = sub("/auth/state")
        h.do_GET()
        self.assertEqual(len(h.header_values("traceresponse")), 1, h.sent)
        self.assertEqual(self.recorded_spans(), ["serve.auth.state"])


if __name__ == "__main__":
    unittest.main()

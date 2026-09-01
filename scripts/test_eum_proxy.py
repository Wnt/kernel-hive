"""The EUM beacon proxy's fences (scripts/serve/eum_proxy.py).

WHAT IS WORTH TESTING HERE is not "does it forward" — one urlopen call is not
where this goes wrong. It is every REFUSAL, because each one is a security
property stated in that module's docstring, and a refusal that silently stops
refusing looks exactly like a working proxy. The forward itself is covered at
the boundary that matters: what gets ENQUEUED, which is the whole of what
reaches Instana.

Two of these are regression tests for named landmines:

  * `/vendor/` once 401'd for signed-out visitors and took every browser
    beacon with it. The gate assertions below pin `/eum` to exactly the fence
    `/traces` already has — no wider, and not open.
  * A traced beacon route would flush a span to /traces, which would produce
    another beacon, forever. `tracing_http.route_of()` is an allowlist, so the
    property holds by construction; it is pinned anyway, because "by
    construction" is a claim about a file somebody else can edit.
"""

from __future__ import annotations

import io
import os
import sys
import tempfile
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.error import HTTPError

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts" / "serve"))
sys.path.insert(0, str(REPO / "scripts" / "serve" / "auth"))

# `serve/config.py` reads the runtime's required paths at import; the same four
# stubs scripts/test_serve_return_leg.py uses, for the same reason. None of
# them is touched by anything under test here.
os.environ.setdefault("WEBROOT", str(REPO / "spa" / "dist"))
os.environ.setdefault("SIGNAL_CONFIG", str(REPO / "spa" / "dist" / "signal.json"))
os.environ.setdefault("CERT", "unused-in-tests")
os.environ.setdefault("KEY", "unused-in-tests")

import eum_proxy  # noqa: E402
import gate  # noqa: E402
import tracing_http  # noqa: E402

ORIGIN = "https://gallery.example.com"
BEACON = b"ty\tpl\nk\tkey123\n\nty\txhr\nk\tkey123\n"


class FakeHandler:
    """The three things eum_proxy touches on a handler: headers, rfile, _send."""

    def __init__(self, body=BEACON, headers=None, public=True, peer="127.0.0.1"):
        base = {
            "Content-Type": "text/plain;charset=UTF-8",
            "Content-Length": str(len(body)),
            "Origin": ORIGIN,
            "User-Agent": "Mozilla/5.0 (probe)",
        }
        base.update(headers or {})
        self.headers = {k: v for k, v in base.items() if v is not None}
        self.rfile = io.BytesIO(body)
        self.public = public
        self.client_address = (peer, 40000)
        self.sent = None

    def _send(self, code, body, ctype, cache=True, extra=None):
        self.sent = (code, body, ctype)


class EumProxyTestCase(unittest.TestCase):
    def setUp(self):
        # The module caches its upstream and its queue in module globals; each
        # test gets a clean pair rather than inheriting the last one's.
        eum_proxy._upstream = "https://eum.example.test/beacon"
        eum_proxy._queue = None
        eum_proxy._worker = None
        self.enqueued = []
        self._real_enqueue = eum_proxy._enqueue
        eum_proxy._enqueue = self.enqueued.append

    def tearDown(self):
        eum_proxy._enqueue = self._real_enqueue
        eum_proxy._upstream = None
        eum_proxy._queue = None
        eum_proxy._worker = None

    def post(self, **kw):
        h = FakeHandler(**kw)
        eum_proxy.dispatch(h, kw.pop("method", "POST"), ORIGIN)
        return h


class TheHappyPath(EumProxyTestCase):
    def test_a_beacon_is_accepted_and_enqueued_verbatim(self):
        h = self.post()
        self.assertEqual(h.sent[0], 200)
        self.assertEqual(len(self.enqueued), 1)
        body, ctype, ua, ip = self.enqueued[0]
        # VERBATIM. The tab-separated escape encoding is the vendor's; any
        # re-encoding on our side would corrupt a stack trace's escaped
        # newlines and the beacon would be silently useless.
        self.assertEqual(body, BEACON)
        self.assertEqual(ctype, "text/plain;charset=UTF-8")
        self.assertEqual(ua, "Mozilla/5.0 (probe)")

    def test_the_urlencoded_fallback_content_type_is_accepted_too(self):
        h = self.post(headers={"Content-Type": "application/x-www-form-urlencoded;charset=UTF-8"})
        self.assertEqual(h.sent[0], 200)
        self.assertEqual(self.enqueued[0][1], "application/x-www-form-urlencoded;charset=UTF-8")

    def test_an_absent_origin_is_allowed(self):
        """THE LANDMINE. `sendBeacon` lives in a vendor bundle we do not
        control and engines have differed on whether a same-origin POST
        carries Origin at all. Refusing an absent one would delete an entire
        engine's telemetry the way /vendor/'s 401 once did."""
        h = self.post(headers={"Origin": None})
        self.assertEqual(h.sent[0], 200)


class EveryRefusal(EumProxyTestCase):
    def test_an_unconfigured_upstream_is_indistinguishable_from_no_route(self):
        eum_proxy._upstream = ""
        h = self.post()
        self.assertEqual(h.sent[0], 404)
        self.assertEqual(self.enqueued, [])

    def test_anything_but_post_is_refused(self):
        for method in ("GET", "PUT", "DELETE", "OPTIONS"):
            h = FakeHandler()
            eum_proxy.dispatch(h, method, ORIGIN)
            self.assertEqual(h.sent[0], 405, method)
        self.assertEqual(self.enqueued, [])

    def test_a_present_but_wrong_origin_is_refused_on_the_public_listener(self):
        h = self.post(headers={"Origin": "https://evil.example"})
        self.assertEqual(h.sent[0], 403)
        self.assertEqual(self.enqueued, [])

    def test_the_lan_listener_has_no_origin_notion(self):
        h = self.post(public=False, headers={"Origin": "https://evil.example"})
        self.assertEqual(h.sent[0], 200)

    def test_an_oversized_body_is_refused_without_reading_it(self):
        h = FakeHandler(headers={"Content-Length": str(eum_proxy.BODY_MAX + 1)})
        eum_proxy.dispatch(h, "POST", ORIGIN)
        self.assertEqual(h.sent[0], 413)
        self.assertEqual(self.enqueued, [])

    def test_chunked_framing_is_refused(self):
        h = self.post(headers={"Transfer-Encoding": "chunked"})
        self.assertEqual(h.sent[0], 411)

    def test_a_missing_content_length_is_refused(self):
        h = self.post(headers={"Content-Length": None})
        self.assertEqual(h.sent[0], 411)

    def test_an_unexpected_content_type_is_refused(self):
        for ctype in ("application/json", "multipart/form-data; boundary=x", "text/html"):
            h = self.post(headers={"Content-Type": ctype})
            self.assertEqual(h.sent[0], 415, ctype)
        self.assertEqual(self.enqueued, [])


class TheClientIpAssertion(EumProxyTestCase):
    """Geography survives the proxy only because of this header, and the
    header is only safe because of which entry it takes."""

    def test_the_rightmost_forwarded_for_entry_wins(self):
        # A client may set its own X-Forwarded-For and our edge APPENDS. The
        # leftmost entry is therefore attacker-chosen; taking it would let any
        # visitor place themselves anywhere on Instana's map. `auth/routes.
        # _client_ip` takes the leftmost on purpose — it is a rate-limit key,
        # never an assertion to a third party.
        h = self.post(headers={"X-Forwarded-For": "198.51.100.9, 203.0.113.7"})
        self.assertEqual(h.sent[0], 200)
        self.assertEqual(self.enqueued[0][3], "203.0.113.7")

    def test_a_single_entry_is_used_as_is(self):
        self.post(headers={"X-Forwarded-For": "203.0.113.7"})
        self.assertEqual(self.enqueued[0][3], "203.0.113.7")

    def test_the_socket_peer_answers_on_the_lan_listener(self):
        self.post(public=False, headers={"X-Forwarded-For": None}, peer="198.51.100.55")
        self.assertEqual(self.enqueued[0][3], "198.51.100.55")

    def test_an_unparseable_address_asserts_nothing_rather_than_guessing(self):
        for value in ("not-an-ip", "203.0.113.7:8080", "<script>", ""):
            self.enqueued.clear()
            self.post(headers={"X-Forwarded-For": f"198.51.100.1, {value}"})
            self.assertEqual(self.enqueued[0][3], "" if value else "198.51.100.1", value)

    def test_a_non_global_address_asserts_nothing(self):
        """THE MEASURED CASE. The live edge hands this process
        `X-Forwarded-For: 127.0.0.1` for every visitor — the real peer is lost
        one hop earlier — and a beacon sent with it came back from Instana
        geolocated to `127.0.0.0` with country, city and coordinates EMPTY.
        Asserting nothing at least lets the box's egress address resolve."""
        for value in ("127.0.0.1", "10.1.2.3", "192.168.1.10", "169.254.1.1", "100.64.0.1", "::1", "fd00::1"):
            self.enqueued.clear()
            self.post(headers={"X-Forwarded-For": value})
            self.assertEqual(self.enqueued[0][3], "", value)

    def test_a_routable_ipv6_survives(self):
        # 2001:db8::/32 is RFC3849 documentation space — a placeholder, which
        # is the only shape of address this public repo may carry.
        self.post(headers={"X-Forwarded-For": "2001:db8::1"})
        self.assertEqual(self.enqueued[0][3], "2001:db8::1")


class HeaderForgeryIsImpossible(EumProxyTestCase):
    def test_control_characters_are_stripped_from_the_user_agent(self):
        self.post(headers={"User-Agent": "ok\r\nX-Injected: yes"})
        self.assertNotIn("\r", self.enqueued[0][2])
        self.assertNotIn("\n", self.enqueued[0][2])

    def test_the_user_agent_is_length_capped(self):
        self.post(headers={"User-Agent": "A" * (eum_proxy.UA_MAX * 4)})
        self.assertLessEqual(len(self.enqueued[0][2]), eum_proxy.UA_MAX)


class TheUpstreamCall(unittest.TestCase):
    """Driven against a REAL local server, because both properties under test
    are properties of `urllib`'s handler chain rather than of our code, and a
    chain assembled slightly wrong fails in a way no assertion about its
    contents would have caught — the live log said `KeyError` where it should
    have said the status IBM sent."""

    @classmethod
    def setUpClass(cls):
        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "http://example.invalid/elsewhere")
                else:
                    self.send_response(503)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *a):
                pass

        cls.srv = HTTPServer(("127.0.0.1", 0), H)
        cls.base = f"http://127.0.0.1:{cls.srv.server_port}"
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def _open(self, path):
        req = urllib.request.Request(
            self.base + path, data=b"ty\tpl\n", headers={"Content-Type": "text/plain"}, method="POST"
        )
        return eum_proxy._OPENER.open(req, timeout=5)

    def test_a_non_2xx_surfaces_as_an_HTTPError_not_a_KeyError(self):
        with self.assertRaises(HTTPError) as caught:
            self._open("/anything")
        self.assertEqual(caught.exception.code, 503)

    def test_a_redirect_is_not_followed(self):
        """One legal destination means "follow the Location header" must not
        be a behaviour this code has at all."""
        with self.assertRaises(HTTPError) as caught:
            self._open("/redirect")
        self.assertEqual(caught.exception.code, 302)

    def test_the_worker_swallows_an_upstream_failure(self):
        """`_forward` is the whole body of a daemon thread: if it can raise,
        one bad beacon ends beacon delivery for the life of the process."""
        before = eum_proxy._fail_count
        eum_proxy._upstream = self.base + "/anything"
        try:
            eum_proxy._forward(b"ty\tpl\n", "text/plain", "probe", "")
        finally:
            eum_proxy._upstream = None
        self.assertGreater(eum_proxy._fail_count, before)


class TheDestinationIsFixed(unittest.TestCase):
    def test_no_redirect_handler_is_installed(self):
        """A forwarder with ONE legal destination must not have "follow the
        Location header" as a behaviour at all."""
        handlers = eum_proxy._OPENER.handlers
        self.assertFalse(
            any(isinstance(h, urllib.request.HTTPRedirectHandler) for h in handlers),
            [type(h).__name__ for h in handlers],
        )

    def _upstream_from(self, text: str) -> str:
        original = eum_proxy.INSTANA_EUM_UPSTREAM_FILE
        eum_proxy._upstream = None
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "instana-eum-upstream.txt"
            path.write_text(text)
            eum_proxy.INSTANA_EUM_UPSTREAM_FILE = path
            try:
                return eum_proxy.upstream()
            finally:
                eum_proxy.INSTANA_EUM_UPSTREAM_FILE = original
                eum_proxy._upstream = None

    def test_a_plaintext_upstream_is_refused(self):
        """Beacons carry the visitor's session id; a misconfigured http://
        destination is a leak, not something to half-honour."""
        self.assertEqual(self._upstream_from("http://eum.example.test/beacon\n"), "")

    def test_an_https_upstream_is_taken_stripped(self):
        self.assertEqual(
            self._upstream_from("  https://eum.example.test/beacon\n"),
            "https://eum.example.test/beacon",
        )

    def test_an_absent_file_disables_the_route(self):
        original = eum_proxy.INSTANA_EUM_UPSTREAM_FILE
        eum_proxy._upstream = None
        eum_proxy.INSTANA_EUM_UPSTREAM_FILE = Path("/nonexistent/instana-eum-upstream.txt")
        try:
            self.assertEqual(eum_proxy.upstream(), "")
        finally:
            eum_proxy.INSTANA_EUM_UPSTREAM_FILE = original
            eum_proxy._upstream = None


class TheFenceMatchesTheOtherTelemetryIngests(unittest.TestCase):
    def test_a_walk_in_may_report_a_beacon(self):
        self.assertTrue(gate.walkin_allows(eum_proxy.PATH))

    def test_it_is_not_open_to_a_signed_out_stranger(self):
        self.assertFalse(gate.is_open(eum_proxy.PATH))

    def test_it_has_exactly_the_traces_fence(self):
        for probe in (gate.is_open, gate.walkin_allows, gate.is_blocked):
            self.assertEqual(probe(eum_proxy.PATH), probe("/traces"), probe.__name__)


class TheRouteIsNotTraced(unittest.TestCase):
    def test_no_span_is_opened_for_a_beacon(self):
        """Otherwise the span flushes to /traces, which beacons, forever."""
        self.assertIsNone(tracing_http.route_of(eum_proxy.PATH))


if __name__ == "__main__":
    unittest.main()

"""The walk-in SEAMS, driven over real HTTP: the integration smoke check.

    cd scripts/serve && /data/vms/streamhost/serve/.venv/bin/python \\
        -m unittest test_walkin_wiring

Eleven lanes built the walk-in plane and none of them could write the code that
joins it up (`docs/lab/walkin/CONTRACT-LEDGER.md` §1: no lane writes outside its
territory, and the joins live outside every territory). This file exercises
those joins the only way that proves anything — a real `PublicH` listener, the
real gate, the real broker, the real signaling route — and fakes exactly one
thing, the hypervisor, because a unit test has no business spawning QEMU.

What it is here to catch, in the order the bar was set:

  1. an invited account still reaches everything it reached before — the one
     regression that must not happen;
  2. a walk-in is refused `/fleet` and is sent to `/walkin`, not `/login`;
  3. `/walkin/state` answers from the BROKER, not from a fixture;
  4. a claim returns a `signalEndpoint` that `signal_route` actually serves,
     and an ended clone's endpoint answers 410 with the reason it ended.

Requires `fido2` (the auth plane's dependency), so it skips where the box venv
is not the interpreter — which is also why it is not in the repo-wide discover.
"""

from __future__ import annotations

import http.client
import importlib
import importlib.util
import json
import os
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

try:  # the auth plane's dependency; present in the serving venv only
    import fido2  # noqa: F401

    HAVE_FIDO2 = True
except Exception:  # pragma: no cover - depends on the interpreter
    HAVE_FIDO2 = False

ORIGIN = "https://gallery.example.com"


def _load_server():
    """Import the server by path — systemd starts it as a script, not a module."""
    spec = importlib.util.spec_from_file_location("osgallery_server_under_test", HERE / "osgallery-https-server.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@unittest.skipUnless(HAVE_FIDO2, "needs the serving venv (fido2)")
class WalkinWiring(unittest.TestCase):
    """One listener, one broker, one pool member, shared by the whole story."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        tmp = Path(cls._tmp.name)
        webroot = tmp / "webroot"
        webroot.mkdir()
        (webroot / "index.html").write_text("<!doctype html><title>SPA</title>")
        (webroot / "gallery-manifest.json").write_text(json.dumps({"entries": [{"id": "os2warp"}]}))
        station_root = tmp / "station"
        station_root.mkdir()
        (station_root / "cert_hash_b64.txt").write_text("STATIONHASH\n")
        (tmp / "tiles.json").write_text(
            json.dumps({"os2warp": {"udpPort": 54091, "hashFile": str(station_root / "cert_hash_b64.txt")}})
        )
        os.environ.update(
            {
                "WEBROOT": str(webroot),
                "SIGNAL_CONFIG": str(tmp / "tiles.json"),
                "CERT": str(tmp / "leaf.crt"),
                "KEY": str(tmp / "leaf.key"),
                "AUTH_STATE": str(tmp / "auth-state.json"),
                "USAGE_STATS": str(tmp / "usage.json"),
                "PUBLIC_HOST": "gallery.example.com",
                "PUBLIC_ORIGIN": ORIGIN,
                # The real registry: this is also the check that every landed
                # registry/walkin/*.json parses in the SERVER's import path.
                "WALKIN_REGISTRY": str(REPO / "registry" / "walkin"),
                "WALKIN_REPO": str(REPO),
                "WALKIN_OPEN": "open",
                "WALKIN_ROOT": str(tmp / "clones"),
                "KH_SESSION": "walkin-integrate-test",
            }
        )
        (tmp / "clones").mkdir()

        cls.server_mod = _load_server()
        from auth.service import AuthService  # noqa: PLC0415 — after the env above

        cls.auth = AuthService(
            Path(os.environ["AUTH_STATE"]),
            rp_id="gallery.example.com",
            rp_name="OS gallery",
            origin=ORIGIN,
            usage=cls.server_mod.USAGE,
        )
        cls.server_mod.AUTH = cls.auth
        cls.server_mod.STREAM_KEY = b"a-test-stream-ticket-key"

        store = cls.auth.store
        cls.tokens = {}
        for uid, role in (("v1", "viewer"), ("a1", "admin"), ("w1", "walkin")):
            store.add_user_with_id(uid, uid, role)
            cls.tokens[role] = store.new_session(uid, "127.0.0.1", "pytest")
        with store.mutate() as doc:
            # Closed while the plane starts, so `start()` does not try to build
            # a REAL clone out of a real seed. The fake factory goes in below,
            # and `setUp` opens the switch for every test.
            doc["walkin"]["access"] = "closed"

        # The plane, started exactly the way the serving process starts it.
        import walkin_plane  # noqa: PLC0415

        cls.plane = walkin_plane
        # `start()` returns None and always has since the plane's bring-up moved
        # off the startup path (a slow constructor there was the whole museum
        # refusing connections on :8443). So the test waits for the watchdog
        # thread to publish the broker, exactly as the serving process does.
        # Reading its return value instead is why this file had been erroring in
        # setUpClass — and an integration test nobody can run is how three files
        # that had to agree about `/walkin/engage` got away with two.
        walkin_plane.start(cls.auth)
        deadline = time.time() + 30
        while walkin_plane.BROKER is None and time.time() < deadline:
            time.sleep(0.05)
        cls.broker = walkin_plane.BROKER
        assert cls.broker is not None, "the broker did not start against the real registry"

        # The one fake: a pool member with no hypervisor behind it. Everything
        # from here down — routes, gate, tickets, signaling — is the real thing.
        from walkin.test_broker import FakeClone  # noqa: PLC0415

        def factory(spec, index):
            clone = FakeClone(spec, index)
            clone.plan.root.mkdir(parents=True, exist_ok=True)
            (clone.plan.root / "cert_hash_b64.txt").write_text("CLONEHASH\n")
            return clone

        cls.broker.factory = factory
        # No hypervisor and no daemon behind the fake member: the seams under
        # test are HTTP-shaped, and spawning QEMU from a unit test is exactly
        # what the sandbox rule exists to prevent.
        cls.broker._spawn = False
        cls.broker._daemon = False
        cls.broker.specs = {k: v for k, v in cls.broker.specs.items() if k == "os2warp"}
        assert cls.broker.specs, "registry/walkin has no os2warp spec to smoke against"

        from http.server import ThreadingHTTPServer  # noqa: PLC0415

        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), cls.server_mod.PublicH)
        cls.port = cls.httpd.server_address[1]
        import threading  # noqa: PLC0415

        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        cls.broker.kill_all_clones()
        cls._tmp.cleanup()

    def setUp(self):
        """Every test starts from an OPEN switch and a warm pool — the claim
        test deliberately ends with the plane torn down."""
        with self.auth.store.mutate() as doc:
            doc["walkin"]["access"] = "open"
        self.broker.set_access("open")
        self.broker.refill()
        # Dropping the switch to Closed also drops every walk-in BROWSER
        # session — that is step 3 of the teardown, and it is why each test
        # gets its own fresh cookies rather than sharing one set.
        for uid, role in (("v1", "viewer"), ("a1", "admin"), ("w1", "walkin")):
            self.tokens[role] = self.auth.store.new_session(uid, "127.0.0.1", "pytest")

    # ---- the driver --------------------------------------------------------

    def get(self, path, role=None, method="GET", body=None, accept="application/json", cookie=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        headers = {"Accept": accept, "Origin": ORIGIN}
        if role:
            headers["Cookie"] = f"osg_session={self.tokens[role]}"
        elif cookie:
            # A STRANGER. `osg_anon` is Secure, so nothing that stores cookies
            # by the rules will keep it over plain HTTP to a loopback port —
            # it is carried by hand here for the same reason it has to be
            # carried by hand in curl against the box.
            headers["Cookie"] = cookie
        payload = None
        if body is not None:
            payload = json.dumps(body)
            headers["Content-Type"] = "application/json"
        conn.request(method, path, body=payload, headers=headers)
        resp = conn.getresponse()
        raw = resp.read().decode("utf-8", "replace")
        conn.close()
        try:
            return resp.status, json.loads(raw), resp
        except ValueError:
            return resp.status, raw, resp

    # ---- 1. the invited plane is unchanged --------------------------------

    def test_an_invited_session_still_reaches_the_gallery(self):
        for path in ("/fleet", "/gallery-manifest.json", "/signal/os2warp.json"):
            status, _, _ = self.get(path, role="viewer", accept="text/html")
            self.assertEqual(status, 200, path)
        status, doc, _ = self.get("/signal/os2warp.json", role="viewer")
        self.assertEqual(doc["certHashB64"], "STATIONHASH")
        self.assertTrue(doc["path"].startswith("/wt/"), "a station's ticket is still minted")

    def test_a_signed_out_browser_still_lands_on_login(self):
        _, _, resp = self.get("/fleet", accept="text/html")
        self.assertEqual(resp.status, 302)
        self.assertEqual(resp.getheader("Location"), "/login")

    # ---- 2. the walk-in fence ---------------------------------------------

    def test_a_walk_in_is_sent_to_the_walk_in_landing_not_the_login(self):
        _, _, resp = self.get("/fleet", role="walkin", accept="text/html")
        self.assertEqual(resp.status, 302)
        self.assertEqual(resp.getheader("Location"), "/walkin")

    def test_a_walk_in_may_not_read_a_stations_signaling(self):
        status, _, _ = self.get("/signal/os2warp.json", role="walkin")
        self.assertEqual(status, 403)

    def test_the_spa_routes_under_walkin_are_not_swallowed_by_the_api(self):
        # /walkin/play/<os> and /walkin/exhibits are CLIENT-side routes: they
        # must reach the SPA index, not the broker's 405.
        for path in ("/walkin", "/walkin/play/os2warp", "/walkin/exhibits"):
            status, body, _ = self.get(path, role="walkin", accept="text/html")
            self.assertEqual(status, 200, path)
            self.assertIn("<title>SPA</title>", body, path)

    # ---- 3. /walkin/state is the broker's answer --------------------------

    def test_state_answers_from_the_broker(self):
        status, doc, _ = self.get("/walkin/state")
        self.assertEqual(status, 200)
        self.assertEqual(doc["access"], "open")
        self.assertEqual(doc["pools"], self.broker.pools())
        self.assertTrue(doc["pools"], "the pool is the broker's, and it is not empty")

    # ---- 4. claim -> signaling -> 410 -------------------------------------

    def test_a_claim_is_served_by_signal_route_and_ends_with_a_410(self):
        status, claim, _ = self.get("/walkin/claim", role="viewer", method="POST", body={"os": "os2warp"})
        self.assertEqual(status, 200, claim)
        endpoint = claim["signalEndpoint"]
        self.assertEqual(endpoint, f"/signal/{claim['clone']}.json")

        status, doc, _ = self.get(endpoint, role="viewer")
        self.assertEqual(status, 200, doc)
        self.assertEqual(doc["certHashB64"], "CLONEHASH")
        self.assertTrue(doc["path"].startswith("/wt/"))
        self.assertTrue(
            self.auth.walkin_tickets.is_live(doc["path"]),
            "a clone's ticket is minted through the registry that can revoke it",
        )
        self.assertIn(claim["clone"], self.auth.walkin_tickets.outstanding())

        # The admin drops the switch to Closed: sessions end, clones die.
        status, moved, _ = self.get("/auth/walkin/access", role="admin", method="POST", body={"access": "closed"})
        self.assertEqual(status, 200, moved)
        self.assertEqual(moved["access"], "closed")

        status, gone, _ = self.get(endpoint, role="viewer")
        self.assertEqual(status, 410, gone)
        self.assertEqual(gone["type"], "session-end")
        self.assertEqual(gone["reason"], "WALKIN_CLOSED")

        # And a claim while Closed is the ledger's one specified error body.
        status, refused, _ = self.get("/walkin/claim", role="viewer", method="POST", body={"os": "os2warp"})
        self.assertEqual(status, 403)
        self.assertEqual(refused["error"], "walkin_closed")

        # The state route tells the same story to the client that was in it.
        status, state, _ = self.get("/walkin/state", role="viewer")
        self.assertEqual(state["access"], "closed")
        self.assertEqual(state["closeReason"], "WALKIN_CLOSED")

    # ---- 5. the visitor's first touch -------------------------------------
    #
    # `/walkin/engage` is the route that starts an anonymous visitor's intro
    # time, and it is the reason this file was repaired: the handler existed
    # (walkin/routes.py), the gate admitted it (auth/gate.py) and the
    # DISPATCHER did not list it (walkin_plane.API), so every call 404ed on the
    # live box. Three files had to agree and two of them did. Every test below
    # therefore goes over real HTTP, through walkin_plane.dispatch, because
    # that is the layer the unit tests entered underneath.

    def anon_cookie(self):
        """A stranger's identity, minted the way a browser gets one."""
        _, _, resp = self.get("/walkin/state")
        raw = resp.getheader("Set-Cookie") or ""
        self.assertIn("osg_anon=", raw, "the state route plants a stranger's cookie")
        return raw.split(";")[0]

    def test_engage_reaches_the_broker_at_all(self):
        # The regression, at its plainest: not a 404. A path the dispatcher
        # does not list falls through to the SPA catch-all, which answers the
        # index with a 200 for a browser and a 404 for a JSON fetch — either
        # way the broker never sees it.
        status, body, _ = self.get(
            "/walkin/engage", role="viewer", method="POST", body={"clone": "walkin-os2warp-nope"}
        )
        self.assertNotEqual(status, 404, f"/walkin/engage is not routed to the broker at all: {body}")
        self.assertEqual(status, 403, body)
        self.assertEqual(body["error"], "walkin_not_yours")

    def test_a_stranger_engages_their_own_clone(self):
        cookie = self.anon_cookie()
        status, claim, _ = self.get("/walkin/claim", method="POST", body={}, cookie=cookie)
        self.assertEqual(status, 200, claim)
        status, out, _ = self.get("/walkin/engage", method="POST", body={"clone": claim["clone"]}, cookie=cookie)
        self.assertEqual(status, 200, out)
        self.assertTrue(out["ok"])
        # The clock the server keeps, and the only proof it started.
        self.assertTrue(out["anon"]["engaged"], out)
        status, state, _ = self.get("/walkin/state", cookie=cookie)
        self.assertTrue(state["anon"]["engaged"], state)

    def test_a_stranger_may_not_engage_somebody_elses_clone(self):
        mine = self.anon_cookie()
        theirs = self.anon_cookie()
        self.assertNotEqual(mine, theirs, "two strangers, two identities")
        status, claim, _ = self.get("/walkin/claim", method="POST", body={}, cookie=theirs)
        self.assertEqual(status, 200, claim)
        status, refused, _ = self.get("/walkin/engage", method="POST", body={"clone": claim["clone"]}, cookie=mine)
        self.assertEqual(status, 403, refused)
        self.assertEqual(refused["error"], "walkin_not_yours")
        # And the victim's own clock did not start on a stranger's say-so.
        status, state, _ = self.get("/walkin/state", cookie=theirs)
        self.assertFalse(state["anon"]["engaged"], state)

    def test_engaging_nothing_is_refused_rather_than_ignored(self):
        cookie = self.anon_cookie()
        self.get("/walkin/claim", method="POST", body={}, cookie=cookie)
        status, refused, _ = self.get("/walkin/engage", method="POST", body={}, cookie=cookie)
        self.assertEqual(status, 403, refused)

    def test_every_broker_path_is_actually_routed(self):
        # The class of bug, not the instance. Each of these must reach the
        # broker — proved by getting the broker's OWN refusal rather than the
        # SPA catch-all's 404.
        for path in self.plane.API:
            method = "GET" if path.endswith("/state") else "POST"
            status, body, _ = self.get(path, role="viewer", method=method, body={} if method == "POST" else None)
            self.assertNotEqual(status, 404, f"{path} never reaches walkin.routes.dispatch: {body}")


if __name__ == "__main__":
    unittest.main()

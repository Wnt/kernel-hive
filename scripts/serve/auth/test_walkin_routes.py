"""The walk-in surface: the role fence, the projection, and the HTTP routes.

Split out of test_walkin.py, which carries the switch and self-registration.
The seam here is what a walk-in's browser can actually REACH and what comes
back when it does — the allowlist in gate.py and the routes in routes.py.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from . import gate
from .test_walkin import FakeBroker, WalkinCase

# ---- the role fence --------------------------------------------------------


class TestFence(unittest.TestCase):
    WALKIN = {"id": "w1", "role": "walkin"}
    VIEWER = {"id": "v1", "role": "viewer"}

    def test_a_walk_in_reaches_its_own_plane(self):
        for path in ("/walkin", "/walkin/state", "/walkin/claim", "/walkin/manifest.json", "/poster-docs.json"):
            self.assertTrue(gate.allows(path, self.WALKIN), path)

    def test_the_operator_surfaces_stay_invisible(self):
        for path in ("/fleet", "/fleet-table.json", "/admin", "/clientcmd", "/clientcmd/admin", "/museum"):
            self.assertFalse(gate.allows(path, self.WALKIN), path)

    def test_the_fleets_interactive_surface_is_refused_except_its_own_clone(self):
        own = "/signal/walkin-os2warp-3.json"
        self.assertTrue(gate.allows(own, self.WALKIN, own_signal=own))
        self.assertTrue(gate.allows("/webrtc/walkin-os2warp-3/offer", self.WALKIN, own_signal=own))
        for path in ("/signal/os2warp.json", "/signal/index.json", "/webrtc/os2warp/offer", own):
            self.assertFalse(gate.allows(path, self.WALKIN), path)

    def test_the_gallery_manifest_itself_is_not_reachable(self):
        self.assertFalse(gate.allows("/gallery-manifest.json", self.WALKIN))
        self.assertFalse(gate.allows("/tiles.json", self.WALKIN))

    def test_invited_sessions_keep_the_behaviour_they_had(self):
        for path in ("/fleet", "/gallery-manifest.json", "/signal/os2warp.json"):
            self.assertTrue(gate.allows(path, self.VIEWER), path)
        self.assertFalse(gate.allows("/clientcmd/admin", self.VIEWER))

    def test_a_refused_page_sends_a_walk_in_to_the_walk_in_landing(self):
        self.assertEqual(gate.landing_for(self.WALKIN), "/walkin")
        self.assertEqual(gate.landing_for(self.VIEWER), "/login")
        self.assertEqual(gate.landing_for(None), "/login")


# ---- the allowlist projection ----------------------------------------------


ENTRY = {
    "id": "os2warp",
    "era_year": 1996,
    "displayName": "OS/2 Warp 4",
    "year": 1996,
    "era": "the nineties",
    "eraLabel": "1996 · desktop wars",
    "lineage": "OS/2",
    "arch": "x86",
    "ramMB": 64,
    "ramKB": 65536,
    "accent": "#2255aa",
    "notes": "Merlin, with speech.",
    "blurb": "IBM's last desktop stand.",
    "eraSoftware": ["Netscape 2"],
    "iconicApps": ["WebExplorer"],
    "periodBrowser": "WebExplorer",
    "archetypeId": "tower",
    "transport": "streamhost",
    "order": 4,
    "signalEndpoint": "/signal/os2warp.json",
    "relativePointerOnly": True,
}


class TestProjection(unittest.TestCase):
    def test_only_the_named_exhibition_fields_survive(self):
        rows = gate.walkin_manifest([ENTRY])["entries"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(set(rows[0]), set(gate.WALKIN_MANIFEST_FIELDS))

    def test_the_interactive_surface_is_withheld(self):
        row = gate.walkin_manifest([ENTRY])["entries"][0]
        for withheld in ("signalEndpoint", "transport", "archetypeId", "relativePointerOnly", "era_year", "order"):
            self.assertNotIn(withheld, row)

    def test_a_field_added_to_the_registry_later_is_invisible_until_named(self):
        # The whole point of naming what to KEEP rather than what to hide.
        rows = gate.walkin_manifest([{**ENTRY, "wedgedSince": "2026-08-01", "poolFree": 2}])["entries"]
        self.assertNotIn("wedgedSince", rows[0])
        self.assertNotIn("poolFree", rows[0])

    def test_the_visitors_own_clone_is_the_one_endpoint_it_gets(self):
        own = {
            "station": "os2warp",
            "clone": "walkin-os2warp-3",
            "signalEndpoint": "/signal/walkin-os2warp-3.json",
            "transport": "streamhost",
        }
        rows = gate.walkin_manifest([ENTRY, {**ENTRY, "id": "win311"}], own=own)["entries"]
        self.assertEqual(rows[0]["signalEndpoint"], "/signal/walkin-os2warp-3.json")
        self.assertTrue(rows[0]["playable"])
        self.assertNotIn("signalEndpoint", rows[1])

    def test_a_hidden_station_is_dropped_entirely(self):
        rows = gate.walkin_manifest([ENTRY, {**ENTRY, "id": "tru64", "listed": False}])["entries"]
        self.assertEqual([r["id"] for r in rows], ["os2warp"])


class TestManifestSource(WalkinCase):
    def test_the_projection_reads_the_published_gallery_manifest(self):
        webroot = Path(self.dir.name)
        (webroot / "gallery-manifest.json").write_text(json.dumps({"entries": [ENTRY]}))
        svc = self.service(env={"WALKIN_OPEN": "open", "WEBROOT": str(webroot)})
        svc.walkin.manifest_path = webroot / "gallery-manifest.json"
        self.assertEqual([r["id"] for r in svc.walkin.manifest()["entries"]], ["os2warp"])

    def test_an_unreadable_manifest_is_an_empty_museum_not_the_whole_one(self):
        svc = self.service()
        svc.walkin.manifest_path = Path(self.dir.name) / "nope.json"
        self.assertEqual(svc.walkin.manifest()["entries"], [])


# ---- the HTTP surface ------------------------------------------------------


class FakeHandler:
    """Just enough of the stdlib request handler for routes.dispatch."""

    def __init__(self, body=None, origin="https://example.test", cookie=""):
        self.headers = {"Origin": origin, "User-Agent": "smoke", "X-Forwarded-For": "203.0.113.7"}
        if cookie:
            self.headers["Cookie"] = f"osg_session={cookie}"
        self._body = body
        self.command = "GET"
        self.client_address = ("127.0.0.1", 1)
        self.status = None
        self.sent = b""
        self.wfile = self

    def read_json_body(self, cap):
        return (self._body, None) if self._body is not None else (None, (411, "Content-Length required"))

    def send_response(self, code):
        self.status = code

    def send_header(self, *_):
        pass

    def end_headers(self):
        pass

    def write(self, data):
        self.sent += data

    @property
    def json(self):
        return json.loads(self.sent)


class TestRoutes(WalkinCase):
    def post(self, svc, path, body, cookie=""):
        from . import routes

        handler = FakeHandler(body=body, cookie=cookie)
        handler.command = "POST"
        routes.dispatch(handler, path, "POST", svc, "https://example.test")
        return handler

    def get(self, svc, path, cookie=""):
        from . import routes

        handler = FakeHandler(cookie=cookie)
        routes.dispatch(handler, path, "GET", svc, "https://example.test")
        return handler

    def admin_cookie(self, svc):
        self.admin(svc)
        return svc.store.new_session("adm", "203.0.113.7", "smoke")

    def test_an_admin_moves_the_switch_and_is_told_who_it_disconnected(self):
        svc = self.service()
        svc.walkin.bind_broker(FakeBroker(sessions=2, clones=3))
        cookie = self.admin_cookie(svc)
        opened = self.post(svc, "/auth/walkin/access", {"access": "open"}, cookie)
        self.assertEqual(opened.json["access"], "open")
        closed = self.post(svc, "/auth/walkin/access", {"access": "closed"}, cookie)
        self.assertEqual((closed.status, closed.json), (200, {"access": "closed", "disconnected": 2}))

    def test_the_switch_is_admins_only(self):
        svc = self.service()
        self.admin(svc)
        viewer = svc.store.add_user_with_id("v1", "viewer", "viewer")
        cookie = svc.store.new_session(viewer["id"], "203.0.113.7", "smoke")
        for handler in (
            self.get(svc, "/auth/walkin/status", cookie),
            self.post(svc, "/auth/walkin/access", {"access": "open"}, cookie),
            self.get(svc, "/auth/walkin/status"),
        ):
            self.assertEqual(handler.status, 403)
        self.assertEqual(svc.walkin.stored_access(), "closed")

    def test_status_and_purge_answer_the_shapes_the_ledger_names(self):
        svc = self.service()
        cookie = self.admin_cookie(svc)
        svc.walkin._allocate_account("w1")
        status = self.get(svc, "/auth/walkin/status", cookie).json
        self.assertEqual({"access", "envFloor", "sessions", "pools", "accounts"} - set(status), set())
        self.assertEqual(self.post(svc, "/auth/walkin/purge", {"olderThanDays": 90}, cookie).json, {"purged": 0})
        self.assertEqual(self.post(svc, "/auth/walkin/drain", {"drain": True}, cookie).json["drain"], True)

    def test_the_manifest_is_refused_while_the_plane_is_closed(self):
        from . import routes

        svc = self.service()
        webroot = Path(self.dir.name)
        (webroot / "gallery-manifest.json").write_text(json.dumps({"entries": [ENTRY]}))
        svc.walkin.manifest_path = webroot / "gallery-manifest.json"
        _, token, _ = self.walkin_user(svc)

        handler = FakeHandler(cookie=token)
        self.assertTrue(routes.dispatch_walkin(handler, "/walkin/manifest.json", "GET", svc, "https://example.test"))
        self.assertEqual((handler.status, handler.json), (403, {"error": "walkin_closed"}))

        svc.walkin.set_access(self.admin(svc), "open")
        handler = FakeHandler(cookie=token)
        routes.dispatch_walkin(handler, "/walkin/manifest.json", "GET", svc, "https://example.test")
        self.assertEqual(handler.status, 200)
        self.assertEqual(set(handler.json["entries"][0]), set(gate.WALKIN_MANIFEST_FIELDS))

    def test_signup_is_refused_with_the_ledgers_error_body_while_closed(self):
        from . import routes

        svc = self.service()
        handler = FakeHandler(body={})
        handler.command = "POST"
        routes.dispatch_walkin(handler, "/walkin/signup", "POST", svc, "https://example.test")
        self.assertEqual((handler.status, handler.json), (403, {"error": "walkin_closed"}))

    def test_a_cross_site_signup_is_refused_on_origin(self):
        from . import routes

        svc = self.service()
        handler = FakeHandler(body={}, origin="https://evil.example")
        handler.command = "POST"
        routes.dispatch_walkin(handler, "/walkin/signup", "POST", svc, "https://example.test")
        self.assertEqual((handler.status, handler.json), (403, {"error": "bad origin"}))

    def test_the_walkin_dispatcher_declines_the_brokers_routes(self):
        from . import routes

        svc = self.service()
        for path in ("/walkin/state", "/walkin/claim", "/walkin/release", "/walkin/reset"):
            handler = FakeHandler()
            self.assertFalse(routes.dispatch_walkin(handler, path, "GET", svc, "https://example.test"), path)


if __name__ == "__main__":
    unittest.main()

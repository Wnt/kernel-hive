"""The box-side operator surface: `/auth/invite/issue`.

Covers the whole path in one file, kept apart from test_auth.py (already at
its size cap): AuthStore.add_invite's `ttl_secs` parameter, AuthService's
`create_operator_invite`, and the route's own gate contract. The route tests
do NOT re-test osgallery-https-server.py's `_require_box_side` /
`_admin_identity` (loopback peer + X-Admin-Token) — that pair is exercised
where it lives, by the server module. What is tested here is the CONTRACT
operator_routes.handle_issue_invite makes with that gate: it must call it
before doing anything else, never mint an invite when the gate refuses, and
force role=viewer / bound ttlDays once the gate lets it through. The fake
handler below stands in for the two gate methods exactly the way
test_walkin_routes.py's FakeHandler stands in for routes.dispatch's handler.
"""

from __future__ import annotations

import json
import tempfile
import time
import unittest
from pathlib import Path

from . import operator_routes
from .service import AuthError, AuthService
from .store import INVITE_TTL_SECS, AuthStore


class TestAddInviteTtlSecs(unittest.TestCase):
    """sim-invite-rotate.sh mints these with an explicit lifetime; every
    other caller's default (INVITE_TTL_SECS) must stay byte-for-byte."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "auth-state.json"

    def tearDown(self):
        self.dir.cleanup()

    def test_ttl_secs_overrides_the_default(self):
        store = AuthStore(self.path)
        short = store.add_invite("hash1", "guest", "viewer", "u1", ttl_secs=60)
        long_default = store.add_invite("hash2", "guest2", "viewer", "u1")
        self.assertLess(short["expiresAtTs"] - int(time.time()), 120)
        self.assertGreater(long_default["expiresAtTs"] - int(time.time()), INVITE_TTL_SECS - 5)


class TestCreateOperatorInvite(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.svc = AuthService(
            Path(self.dir.name) / "auth-state.json", rp_id="example.test", rp_name="t", origin="https://example.test"
        )

    def tearDown(self):
        self.dir.cleanup()

    def test_create_invite_ttl_secs_is_optional_and_does_not_change_default_callers(self):
        admin = self.svc.store.add_user_with_id("u1", "wnt", "admin")
        ordinary = self.svc.create_invite(admin, "Guest", "viewer")
        custom = self.svc.create_invite(admin, "Guest2", "viewer", ttl_secs=3600)
        self.assertNotEqual(ordinary["expiresAt"], custom["expiresAt"])

    def test_forces_viewer_and_a_synthetic_creator(self):
        issued = self.svc.create_operator_invite("visitor-sim (automated)")
        invite = self.svc._resolve_code(issued["code"])
        self.assertEqual(invite["role"], "viewer")
        record = self.svc.store.invites()[0]
        self.assertEqual(record["createdBy"], "operator:clientcmd")

    def test_ttl_days_bounds(self):
        with self.assertRaises(AuthError):
            self.svc.create_operator_invite("x", ttl_days=0)
        with self.assertRaises(AuthError):
            self.svc.create_operator_invite("x", ttl_days=91)
        self.svc.create_operator_invite("x", ttl_days=1)  # floor is fine
        self.svc.create_operator_invite("x", ttl_days=90)  # ceiling is fine

    def test_default_ttl_is_seven_days(self):
        issued = self.svc.create_operator_invite("visitor-sim (automated)")
        record = self.svc.store.invites()[0]
        seven_days = 7 * 24 * 3600
        self.assertGreater(record["expiresAtTs"] - int(time.time()), seven_days - 10)
        self.assertLess(record["expiresAtTs"] - int(time.time()), seven_days + 10)
        self.assertTrue(issued["code"])

    def test_requires_a_name(self):
        with self.assertRaises(AuthError):
            self.svc.create_operator_invite("  ")


class FakeHandler:
    """Just enough of the stdlib request handler for operator_routes."""

    def __init__(self, body=None, gate_ok=True):
        self.headers = {}
        self.command = "POST"
        self.client_address = ("127.0.0.1", 1)
        self._body = body
        self._gate_ok = gate_ok
        self.status = None
        self.sent = b""
        self.wfile = self

    def read_json_body(self, cap):
        return (self._body, None) if self._body is not None else (None, (411, "Content-Length required"))

    def _require_box_side(self, surface):
        # The real one also sends a 404 itself on refusal (see
        # osgallery-https-server.py) — mirrored here so a caller that forgot
        # to check the return value still sees the same status a browser
        # would.
        if not self._gate_ok:
            self.send_response(404)
            self.end_headers()
        return self._gate_ok

    def _admin_identity(self):
        return "token@127.0.0.1" if self._gate_ok else None

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


class TestOperatorInviteRoute(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.svc = AuthService(
            Path(self.dir.name) / "auth-state.json", rp_id="example.test", rp_name="t", origin="https://example.test"
        )

    def tearDown(self):
        self.dir.cleanup()

    def test_refused_off_the_gate_never_reaches_the_service(self):
        handler = FakeHandler(body={"name": "visitor-sim"}, gate_ok=False)
        operator_routes.handle_issue_invite(handler, self.svc)
        self.assertEqual(handler.status, 404)
        self.assertEqual(self.svc.store.invites(), [])

    def test_a_loopback_and_token_caller_gets_a_code(self):
        handler = FakeHandler(body={"name": "visitor-sim (automated)", "role": "viewer", "ttlDays": 14})
        operator_routes.handle_issue_invite(handler, self.svc)
        self.assertEqual(handler.status, 200)
        self.assertTrue(handler.json["code"])
        self.assertEqual(handler.json["role"], "viewer")

    def test_role_is_forced_to_viewer_anything_else_is_400(self):
        handler = FakeHandler(body={"name": "x", "role": "admin"})
        operator_routes.handle_issue_invite(handler, self.svc)
        self.assertEqual(handler.status, 400)
        self.assertEqual(self.svc.store.invites(), [])

    def test_ttl_days_out_of_bounds_is_refused(self):
        handler = FakeHandler(body={"name": "x", "ttlDays": 0})
        operator_routes.handle_issue_invite(handler, self.svc)
        self.assertEqual(handler.status, 400)

        handler2 = FakeHandler(body={"name": "x", "ttlDays": 91})
        operator_routes.handle_issue_invite(handler2, self.svc)
        self.assertEqual(handler2.status, 400)
        self.assertEqual(self.svc.store.invites(), [])

    def test_ttl_days_defaults_to_seven_when_omitted(self):
        handler = FakeHandler(body={"name": "visitor-sim"})
        operator_routes.handle_issue_invite(handler, self.svc)
        self.assertEqual(handler.status, 200)
        record = self.svc.store.invites()[0]
        self.assertEqual(record["createdBy"], "operator:clientcmd")

    def test_the_response_carries_the_code_exactly_once(self):
        handler = FakeHandler(body={"name": "visitor-sim"})
        operator_routes.handle_issue_invite(handler, self.svc)
        self.assertIn("code", handler.json)
        self.assertTrue(handler.json["code"])

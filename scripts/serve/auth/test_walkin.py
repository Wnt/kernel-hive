"""The walk-in plane's auth half: the switch, the role fence, the projection.

Run with the rest: python3 -m unittest discover -s scripts -p 'test_*.py'

The WebAuthn ceremony itself is not exercised here (no authenticator), so
signup is tested at the seam below it — the account row, the handle allocated
under the store lock, the throttles, and the re-check at completion. What IS
exercised end to end is the thing a kill switch may not get wrong: the order of
the teardown, and that it survives a restart.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from . import walkin
from .service import AuthError, AuthService
from .store import AuthStore
from .tickets import WalkinTickets


class FakeBroker:
    """Lane 1's pool broker, stubbed to the contract in ledger §3/§5."""

    def __init__(self, sessions=0, clones=0):
        self.calls: list[str] = []
        self._sessions = sessions
        self.clones = clones
        self.reason = ""
        self.drain = False

    def live_sessions(self):
        return self._sessions

    def pools(self):
        return [{"os": "os2warp", "free": self.clones, "size": 2}]

    def close_sessions(self, reason):
        self.calls.append("close_sessions")
        self.reason = reason
        closed, self._sessions = self._sessions, 0
        return closed

    def kill_all_clones(self):
        self.calls.append("kill_all_clones")
        killed, self.clones = self.clones, 0
        return killed

    def refill(self):
        self.calls.append("refill")

    def set_drain(self, value):
        self.drain = value


class WalkinCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "auth-state.json"
        self._real_handle = walkin._generate_handle
        self._handles = iter([f"bold-turing-{n}" if n else "bold-turing" for n in range(50)])
        walkin._generate_handle = lambda taken: next(h for h in self._handles if h not in taken)

    def tearDown(self):
        walkin._generate_handle = self._real_handle
        self.dir.cleanup()

    def service(self, env=None):
        svc = AuthService(self.path, "example.test", "Gallery", "https://example.test")
        svc.walkin._env = {"WALKIN_OPEN": "open"} if env is None else env
        return svc

    def admin(self, svc):
        return svc.store.add_user_with_id("adm", "operator", "admin")

    def walkin_user(self, svc):
        """A signed-up walk-in with a live session, without a real ceremony."""
        handle = svc.walkin._allocate_account("w1")
        return svc.store.user("w1"), svc.store.new_session("w1", "203.0.113.5", "ua"), handle


# ---- migration -------------------------------------------------------------


class TestMigration(WalkinCase):
    def test_a_live_file_without_the_keys_gains_them_in_place(self):
        legacy = {"version": 1, "users": [{"id": "u1", "name": "wnt", "role": "admin"}], "bootstrap": None}
        self.path.write_text(json.dumps(legacy))
        store = AuthStore(self.path)
        self.assertEqual(store.snapshot()["walkin"]["access"], "closed")
        # Nothing is written at read time; the defaults land on the first write.
        self.assertNotIn("walkin", json.loads(self.path.read_text()))
        store.add_user_with_id("u2", "second", "viewer")
        on_disk = json.loads(self.path.read_text())
        self.assertEqual(on_disk["walkin"], {"access": "closed", "drain": False, "accounts": {}, "audit": []})
        # The accounts it already had are untouched.
        self.assertEqual([u["id"] for u in on_disk["users"]], ["u1", "u2"])

    def test_a_key_of_the_wrong_type_is_replaced_not_crashed_on(self):
        self.path.write_text(json.dumps({"walkin": {"access": "open", "accounts": [], "drain": "yes"}}))
        block = AuthStore(self.path).snapshot()["walkin"]
        self.assertEqual(block["access"], "open")
        self.assertEqual(block["accounts"], {})
        self.assertIs(block["drain"], False)


# ---- the switch ------------------------------------------------------------


class TestSwitch(WalkinCase):
    def test_default_is_closed_and_the_env_floor_can_only_lower(self):
        svc = self.service(env={})
        self.assertEqual(svc.walkin.access(), "closed")
        svc.walkin.set_access(self.admin(svc), "open")
        # Stored says open; the floor is unset, so the plane is still closed.
        self.assertEqual(svc.walkin.stored_access(), "open")
        self.assertEqual(svc.walkin.access(), "closed")
        svc.walkin._env = {"WALKIN_OPEN": "invited"}
        self.assertEqual(svc.walkin.access(), "invited")
        svc.walkin._env = {"WALKIN_OPEN": "1"}
        self.assertEqual(svc.walkin.access(), "open")

    def test_the_floor_never_raises_a_switch_that_is_below_it(self):
        svc = self.service(env={"WALKIN_OPEN": "open"})
        svc.walkin.set_access(self.admin(svc), "invited")
        self.assertEqual(svc.walkin.access(), "invited")

    def test_a_restart_does_not_re_open_the_plane(self):
        svc = self.service()
        svc.walkin.set_access(self.admin(svc), "open")
        svc.walkin.set_access(self.admin(svc), "closed")
        again = self.service()
        self.assertEqual(again.walkin.access(), "closed")
        self.assertEqual(again.walkin.stored_access(), "closed")

    def test_every_transition_is_audit_logged_with_who_and_when(self):
        svc = self.service()
        svc.walkin.set_access(self.admin(svc), "invited")
        svc.walkin.set_access(self.admin(svc), "open")
        audit = svc.store.snapshot()["walkin"]["audit"]
        self.assertEqual([(a["from"], a["to"]) for a in audit], [("closed", "invited"), ("invited", "open")])
        self.assertTrue(all(a["admin"] == "adm" and a["at"].endswith("Z") for a in audit))

    def test_dropping_to_closed_runs_the_teardown_in_order(self):
        svc = self.service()
        broker = FakeBroker(sessions=3, clones=4)
        svc.walkin.bind_broker(broker)
        svc.walkin.set_access(self.admin(svc), "open")
        self.walkin_user(svc)
        svc.walkin_tickets.mint(b"k" * 32, "walkin-os2warp-3")
        broker.calls.clear()  # the refill that opening it triggered

        result = svc.walkin.set_access(self.admin(svc), "closed")

        # 1. inflow refused, and refused BEFORE anything was torn down
        self.assertEqual(svc.walkin.access(), "closed")
        # 2. tickets revoked, so no re-handshake into the clone
        self.assertEqual(svc.walkin_tickets.outstanding(), [])
        # 3. live sessions closed with the distinct reason code
        self.assertEqual(broker.reason, "WALKIN_CLOSED")
        self.assertEqual(result["disconnected"], 3)
        # 4. and only then the pool emptied
        self.assertEqual(broker.calls, ["close_sessions", "kill_all_clones"])
        self.assertEqual(broker.clones, 0)

    def test_closing_kills_the_browser_sessions_too(self):
        svc = self.service()
        svc.walkin.set_access(self.admin(svc), "open")
        _, token, _ = self.walkin_user(svc)
        self.assertIsNotNone(svc.user_for_token(token))
        svc.walkin.set_access(self.admin(svc), "closed")
        self.assertIsNone(svc.user_for_token(token))

    def test_a_broker_that_fails_is_reported_after_the_teardown_finishes(self):
        class Broken(FakeBroker):
            def kill_all_clones(self):
                self.calls.append("kill_all_clones")
                raise RuntimeError("clone-guard refused")

        svc = self.service()
        broker = Broken(sessions=1, clones=2)
        svc.walkin.bind_broker(broker)
        svc.walkin.set_access(self.admin(svc), "open")
        broker.calls.clear()
        with self.assertRaises(AuthError) as caught:
            svc.walkin.set_access(self.admin(svc), "closed")
        self.assertEqual(caught.exception.status, 500)
        # Loud, but the access change stuck and the earlier steps still ran.
        self.assertEqual(svc.walkin.access(), "closed")
        self.assertEqual(broker.calls, ["close_sessions", "kill_all_clones"])

    def test_moving_back_up_refills_and_disconnects_nobody(self):
        svc = self.service()
        broker = FakeBroker()
        svc.walkin.bind_broker(broker)
        result = svc.walkin.set_access(self.admin(svc), "open")
        self.assertEqual(result, {"access": "open", "disconnected": 0})
        self.assertEqual(broker.calls, ["refill"])

    def test_drain_is_not_the_kill_switch(self):
        svc = self.service()
        broker = FakeBroker(sessions=2, clones=2)
        svc.walkin.bind_broker(broker)
        svc.walkin.set_access(self.admin(svc), "open")
        svc.walkin.set_drain(self.admin(svc), True)
        self.assertTrue(svc.walkin.draining())
        self.assertTrue(broker.drain)
        self.assertEqual(broker.clones, 2)
        self.assertEqual(svc.walkin.access(), "open")

    def test_an_unknown_position_is_refused(self):
        svc = self.service()
        with self.assertRaises(AuthError):
            svc.walkin.set_access(self.admin(svc), "ajar")

    def test_status_reports_the_switch_the_floor_and_the_pool(self):
        svc = self.service()
        svc.walkin.bind_broker(FakeBroker(sessions=2, clones=1))
        svc.walkin.set_access(self.admin(svc), "open")
        status = svc.walkin.status()
        self.assertEqual(status["access"], "open")
        self.assertEqual(status["envFloor"], "open")
        self.assertEqual(status["sessions"], 2)
        self.assertEqual(status["pools"], [{"os": "os2warp", "free": 1, "size": 2}])
        self.assertEqual(status["accounts"], 0)


# ---- who may reach the plane -----------------------------------------------


class TestReachability(WalkinCase):
    def test_invited_only_admits_invited_accounts_and_no_walk_in(self):
        svc = self.service()
        svc.walkin.set_access(self.admin(svc), "invited")
        viewer = svc.store.add_user_with_id("v1", "viewer", "viewer")
        self.assertTrue(svc.walkin.is_open_to(viewer))
        self.assertTrue(svc.walkin.is_open_to(self.admin(svc)))
        self.assertFalse(svc.walkin.is_open_to(None))
        stranger = {"id": "w1", "name": "bold-turing", "role": "walkin"}
        self.assertFalse(svc.walkin.is_open_to(stranger))

    def test_closed_admits_nobody(self):
        svc = self.service()
        for who in (None, {"id": "a", "role": "admin"}, {"id": "w", "role": "walkin"}):
            self.assertFalse(svc.walkin.is_open_to(who))

    def test_a_walk_in_cannot_sign_in_while_the_plane_is_shut(self):
        svc = self.service()
        with self.assertRaises(AuthError) as caught:
            svc.walkin.require_signin({"id": "w1", "role": "walkin"})
        self.assertEqual(str(caught.exception), "walkin_closed")
        self.assertEqual(caught.exception.status, 403)
        # An invited account is untouched by the switch.
        svc.walkin.require_signin({"id": "v1", "role": "viewer"})

    def test_walkin_is_not_a_role_an_admin_can_assign(self):
        svc = self.service()
        svc.store.add_user_with_id("v1", "viewer", "viewer")
        with self.assertRaises(AuthError):
            svc.set_role(self.admin(svc), "v1", "walkin")
        # ...and it is not an invitable one either.
        with self.assertRaises(AuthError):
            svc.create_invite(self.admin(svc), "someone", "walkin")


# ---- self-registration -----------------------------------------------------


class TestSignup(WalkinCase):
    def test_an_account_is_a_role_a_handle_and_nothing_else(self):
        svc = self.service()
        svc.walkin.set_access(self.admin(svc), "open")
        handle = svc.walkin._allocate_account("w1")
        self.assertEqual(handle, "bold-turing")
        user = svc.store.user("w1")
        self.assertEqual(user["role"], "walkin")
        self.assertEqual(user["name"], handle)
        account = svc.store.snapshot()["walkin"]["accounts"]["w1"]
        self.assertEqual(set(account), {"handle", "createdAt", "lastSeenAt"})

    def test_handles_are_unique_across_concurrent_signups(self):
        svc = self.service()
        handles = {svc.walkin._allocate_account(f"w{n}") for n in range(5)}
        self.assertEqual(len(handles), 5)

    def test_signup_is_refused_unless_the_switch_is_open(self):
        svc = self.service()
        for position in ("closed", "invited"):
            svc.walkin.set_access(self.admin(svc), position)
            with self.assertRaises(AuthError) as caught:
                svc.walkin.begin_signup("203.0.113.9")
            self.assertEqual(caught.exception.status, 403)

    def test_registration_is_rate_limited_per_ip(self):
        svc = self.service()
        svc.walkin.set_access(self.admin(svc), "open")
        for _ in range(walkin.SIGNUP_PER_IP):
            svc.walkin.begin_signup("203.0.113.9")
        with self.assertRaises(AuthError) as caught:
            svc.walkin.begin_signup("203.0.113.9")
        self.assertEqual(caught.exception.status, 429)
        # A different visitor is not punished for it.
        svc.walkin.begin_signup("203.0.113.10")

    def test_the_global_account_cap_holds(self):
        svc = self.service()
        svc.walkin.set_access(self.admin(svc), "open")
        original = walkin.ACCOUNT_CAP
        walkin.ACCOUNT_CAP = 2
        try:
            svc.walkin._allocate_account("w1")
            svc.walkin._allocate_account("w2")
            with self.assertRaises(AuthError) as caught:
                svc.walkin._allocate_account("w3")
            self.assertEqual(caught.exception.status, 429)
        finally:
            walkin.ACCOUNT_CAP = original
        self.assertIsNone(svc.store.user("w3"))

    def test_purge_reaps_idle_walk_ins_and_leaves_invited_accounts_alone(self):
        svc = self.service()
        svc.walkin._allocate_account("w1")
        svc.store.add_user_with_id("v1", "viewer", "viewer")
        with svc.store.mutate() as doc:
            doc["walkin"]["accounts"]["w1"]["lastSeenAt"] = "2020-01-01T00:00:00Z"
        self.assertEqual(svc.walkin.purge(90), {"purged": 1})
        self.assertIsNone(svc.store.user("w1"))
        self.assertIsNotNone(svc.store.user("v1"))
        self.assertEqual(svc.store.snapshot()["walkin"]["accounts"], {})

    def test_purge_keeps_an_account_that_was_here_recently(self):
        svc = self.service()
        svc.walkin._allocate_account("w1")
        self.assertEqual(svc.walkin.purge(90), {"purged": 0})
        self.assertIsNotNone(svc.store.user("w1"))


# ---- ticket revocation -----------------------------------------------------


class TestTickets(unittest.TestCase):
    def test_a_minted_ticket_is_live_until_it_is_revoked(self):
        reg = WalkinTickets()
        path = reg.mint(b"k" * 32, "walkin-os2warp-3")
        self.assertTrue(reg.is_live(path))
        self.assertEqual(reg.outstanding(), ["walkin-os2warp-3"])
        self.assertEqual(reg.revoke_all(), 1)
        self.assertFalse(reg.is_live(path))
        self.assertEqual(reg.outstanding(), [])

    def test_one_clone_can_be_revoked_without_touching_the_others(self):
        reg = WalkinTickets()
        a = reg.mint(b"k" * 32, "walkin-os2warp-1")
        b = reg.mint(b"k" * 32, "walkin-win311-2")
        self.assertEqual(reg.revoke_clone("walkin-os2warp-1"), 1)
        self.assertFalse(reg.is_live(a))
        self.assertTrue(reg.is_live(b))


class TestLaneThreeHandles(unittest.TestCase):
    def test_the_generator_lane_three_owns_produces_the_agreed_shape(self):
        try:
            from .handles import generate_handle
        except ImportError:
            self.skipTest("auth/handles/ is lane 3's and has not landed yet")
        handle = generate_handle(set())
        adjective, _, surname = handle.partition("-")
        self.assertTrue(handle and surname, handle)
        self.assertLessEqual(len(adjective), 5, handle)
        self.assertLessEqual(len(surname), 7, handle)
        self.assertNotEqual(generate_handle({handle}), handle)


if __name__ == "__main__":
    unittest.main()

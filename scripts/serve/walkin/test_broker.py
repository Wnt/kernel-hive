"""Unit tests for the walk-in POOL: python3 -m unittest serve.walkin.test_broker

The half of the broker that decides things — who gets a machine, for how long,
what happens when they stop typing, and what the kill switch does. No hypervisor:
`FakeClone` stands in for one, because the pool's rules are not about QEMU.

The rule every test here circles: **a clone is never handed to a second
visitor.** Its counterpart, that the machine really is pristine, is not provable
from Python and is proved at the framebuffer by `smoke.py`.

The derivation half — schema, launcher parsing, the device-set refusal — is
`test_walkin.py`.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from . import broker as broker_mod
from . import derive, naming
from .test_walkin import REPO, a_spec


class FakeClone:
    """A pool member with no hypervisor behind it."""

    def __init__(self, spec, index):
        self.spec = spec
        self.plan = derive.plan_for(spec, index, naming.SLOT_MIN + index - 1)
        self.destroyed = False
        self._alive = True

    @property
    def identity(self):
        return self.plan.identity

    def destroy(self):
        self.destroyed = True
        self._alive = False

    def alive(self):
        return self._alive

    def resume(self):
        pass


class BrokerTests(unittest.TestCase):
    def setUp(self):
        # Point the clone tree at a temp dir: a unit test has no business
        # reading, let alone reaping, the production walk-in root.
        self._tmp = tempfile.TemporaryDirectory()
        self._real_root = naming.WALKIN_ROOT
        naming.WALKIN_ROOT = Path(self._tmp.name)
        self.addCleanup(self._restore_root)
        self.clock = [1000.0]
        self.made = []

        def factory(spec, index):
            made = FakeClone(spec, index)
            self.made.append(made)
            return made

        self.broker = broker_mod.Broker(
            REPO / "does-not-exist", REPO, now=lambda: self.clock[0], spawn=False, factory=factory
        )
        self.broker.specs = {"os2warp": a_spec()}
        self.broker.set_access("open")

    def _restore_root(self):
        naming.WALKIN_ROOT = self._real_root
        self._tmp.cleanup()

    def test_pool_is_warm(self):
        self.assertEqual(self.broker.state()["pools"], [{"os": "os2warp", "free": 2, "size": 2}])

    def test_claim_takes_a_member_out_of_the_pool(self):
        got = self.broker.claim("u1", "os2warp")
        self.assertTrue(got["clone"].startswith("walkin-os2warp-"))
        self.assertEqual(got["signalEndpoint"], f"/signal/{got['clone']}.json")
        self.assertEqual(got["ttlSeconds"], broker_mod.TTL_SECONDS)
        self.assertEqual(self.broker.state()["pools"][0]["free"], 1)

    def test_a_clone_is_never_handed_to_a_second_visitor(self):
        first = self.broker.claim("u1", "os2warp")["clone"]
        self.broker.release("u1", first)
        seen = {first}
        for user in ("u2", "u3", "u4"):
            got = self.broker.claim(user, "os2warp")["clone"]
            self.assertNotIn(got, seen)
            seen.add(got)
            self.broker.release(user, got)
        self.assertTrue(all(c.destroyed for c in self.made if c.identity in seen))

    def test_release_refuses_someone_elses_clone(self):
        mine = self.broker.claim("u1", "os2warp")["clone"]
        with self.assertRaises(broker_mod.BrokerError):
            self.broker.release("u2", mine)

    def test_ttl_ends_the_session_with_its_reason_code(self):
        self.broker.claim("u1", "os2warp")
        self.clock[0] += broker_mod.TTL_SECONDS + 1
        report = self.broker.tick()
        self.assertEqual([code for _, code in report["ended"]], [broker_mod.CLOSE_REASON_TTL])
        self.assertEqual(self.broker.close_reason("u1"), "WALKIN_TTL")

    def test_idle_ends_the_session_early(self):
        clone = self.broker.claim("u1", "os2warp")["clone"]
        self.clock[0] += broker_mod.IDLE_SECONDS - 1
        self.broker.note_input(clone)
        self.clock[0] += broker_mod.IDLE_SECONDS - 1
        self.assertEqual(self.broker.tick()["ended"], [])
        self.clock[0] += 2
        self.assertEqual(self.broker.close_reason("u1"), "")
        self.broker.tick()
        self.assertEqual(self.broker.close_reason("u1"), "WALKIN_IDLE")

    def test_closing_disconnects_everyone_and_empties_the_pool(self):
        self.broker.claim("u1", "os2warp")
        disconnected = self.broker.set_access("closed")
        self.assertEqual(disconnected, 1)
        self.assertEqual(self.broker.state()["pools"], [{"os": "os2warp", "free": 0, "size": 2}])
        self.assertEqual(self.broker.close_reason("u1"), "WALKIN_CLOSED")
        self.assertTrue(all(c.destroyed for c in self.made))

    def test_claim_while_closed_is_refused(self):
        self.broker.set_access("closed")
        with self.assertRaises(broker_mod.BrokerError) as caught:
            self.broker.claim("u9", "os2warp")
        self.assertEqual(str(caught.exception), "walkin_closed")

    def test_reopening_refills_the_pool(self):
        self.broker.set_access("closed")
        self.broker.set_access("invited")
        self.assertEqual(self.broker.state()["pools"][0]["free"], 2)

    def test_a_queued_visitor_gets_a_position(self):
        self.broker.claim("u1", "os2warp")
        self.broker.claim("u2", "os2warp")
        queued = self.broker.claim("u3", "os2warp")
        self.assertEqual(queued, {"queued": True, "position": 1})

    def test_one_session_per_account(self):
        self.broker.claim("u1", "os2warp")
        with self.assertRaises(broker_mod.BrokerError):
            self.broker.claim("u1", "os2warp")

    def test_reset_gives_a_different_machine(self):
        first = self.broker.claim("u1", "os2warp")["clone"]
        second = self.broker.reset("u1", first)["clone"]
        self.assertNotEqual(first, second)

    def test_extension_is_refused_while_someone_waits(self):
        first = self.broker.claim("u1", "os2warp")["clone"]
        self.broker.claim("u2", "os2warp")
        self.broker.claim("u3", "os2warp")  # queues
        self.assertEqual(self.broker.extend("u1", first), broker_mod.TTL_SECONDS)

    def test_a_dead_pool_member_is_reaped(self):
        victim = self.made[0]
        victim._alive = False
        self.assertIn(victim.identity, self.broker.tick()["died"])

    def test_the_frozen_interface_lane_2_calls_exists(self):
        for name in ("live_sessions", "pools", "close_sessions", "kill_all_clones", "refill", "set_drain"):
            self.assertTrue(callable(getattr(self.broker, name, None)), name)

    def test_close_sessions_leaves_the_warm_pool_standing(self):
        self.broker.claim("u1", "os2warp")
        self.assertEqual(self.broker.close_sessions("WALKIN_CLOSED"), 1)
        self.assertEqual(self.broker.live_sessions(), 0)
        # One member is gone with its session; the other is still warm, because
        # emptying the pool is a separate call that lane 2 makes AFTER revoking
        # the tickets.
        self.assertEqual(self.broker.state()["pools"][0]["free"], 1)

    def test_kill_all_clones_stays_empty_under_the_watchdog(self):
        self.broker.kill_all_clones()
        self.broker.tick()
        self.assertEqual(self.broker.state()["pools"][0]["free"], 0)
        self.broker.refill()
        self.assertEqual(self.broker.state()["pools"][0]["free"], 2)

    def test_drain_refuses_new_claims_without_ending_the_old_ones(self):
        first = self.broker.claim("u1", "os2warp")["clone"]
        self.broker.set_drain(True)
        with self.assertRaises(broker_mod.BrokerError):
            self.broker.claim("u2", "os2warp")
        self.assertEqual(self.broker.live_sessions(), 1)
        self.broker.set_drain(False)
        self.assertNotEqual(self.broker.claim("u2", "os2warp")["clone"], first)

    def test_session_end_carries_the_ledger_message(self):
        clone = self.broker.claim("u1", "os2warp")["clone"]
        self.clock[0] += broker_mod.TTL_SECONDS + 1
        self.broker.tick()
        self.assertEqual(self.broker.session_end("u1"), {"type": "session-end", "reason": "WALKIN_TTL"})
        # And the same fact by clone identity, for the reconnect that asks the
        # signaling document for a machine that no longer exists.
        self.assertEqual(self.broker.session_end_for_clone(clone), {"type": "session-end", "reason": "WALKIN_TTL"})

    def test_a_visitor_who_simply_left_gets_no_reason(self):
        clone = self.broker.claim("u1", "os2warp")["clone"]
        self.broker.release("u1", clone)
        self.assertIsNone(self.broker.session_end("u1"))
        self.assertIsNone(self.broker.session_end_for_clone(clone))

    def test_signal_entries_describe_the_pool(self):
        entries = self.broker.signal_entries()
        self.assertEqual(len(entries), 2)
        for name, row in entries.items():
            self.assertTrue(name.startswith("walkin-os2warp-"))
            self.assertGreaterEqual(row["udpPort"], 54152)


if __name__ == "__main__":
    unittest.main()

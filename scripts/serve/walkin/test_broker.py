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

import json
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path

from . import broker as broker_mod
from . import claims, derive, naming
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
        self._claims = tempfile.TemporaryDirectory()
        self.addCleanup(self._claims.cleanup)
        self._saved = {k: os.environ.get(k) for k in ("KH_CLAIMS_ROOT", "KH_SESSION")}
        os.environ.update(KH_CLAIMS_ROOT=self._claims.name, KH_SESSION="test-broker")
        self.addCleanup(self._restore_env)
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

    def _restore_env(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

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


class OrphanTapTests(unittest.TestCase):
    """An orphaned tap fails the next clone at that pool index, not just tidiness."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._real_root = naming.WALKIN_ROOT
        naming.WALKIN_ROOT = Path(self.tmp.name)
        self.addCleanup(self._restore)
        self.broker = broker_mod.Broker(REPO / "does-not-exist", REPO, spawn=False)
        self.downed = []

    def _restore(self):
        naming.WALKIN_ROOT = self._real_root

    def _patch(self, taps, cells=()):
        from . import cell as cell_mod
        from . import claims as claims_mod

        # The sweeps consult the box-wide claim registry; none exists here.
        real_everyone = claims_mod.everyone
        claims_mod.everyone = lambda klass="": []
        self.addCleanup(lambda: setattr(claims_mod, "everyone", real_everyone))

        real_live, real_down = cell_mod.live_taps, cell_mod.tapnet_down  # noqa: F841
        real_cells, real_cell_down = cell_mod.live_cells, cell_mod.cell_down  # noqa: F841
        cell_mod.live_taps = lambda: taps
        cell_mod.tapnet_down = lambda station, tap, bridge="": (self.downed.append((station, tap)), True)[1]
        cell_mod.live_cells = lambda: list(cells)
        cell_mod.cell_down = lambda slot: (self.downed.append(("cell", slot)), True)[1]
        self.addCleanup(lambda: setattr(cell_mod, "live_taps", real_live))
        self.addCleanup(lambda: setattr(cell_mod, "tapnet_down", real_down))
        self.addCleanup(lambda: setattr(cell_mod, "live_cells", real_cells))
        self.addCleanup(lambda: setattr(cell_mod, "cell_down", real_cell_down))

    def test_a_tap_with_no_clone_behind_it_is_taken_down(self):
        self._patch(["wi-os2warp-2", "wi-os2warp-3"])
        self.assertEqual(self.broker.reap_orphan_taps(), ["wi-os2warp-2", "wi-os2warp-3"])
        self.assertEqual(self.downed, [("os2warp", "wi-os2warp-2"), ("os2warp", "wi-os2warp-3")])

    def test_a_tap_recorded_in_a_clone_crumb_is_left_alone(self):
        root = naming.WALKIN_ROOT / "walkin-os2warp-1"
        root.mkdir()
        (root / "clone.json").write_text(json.dumps({"identity": "walkin-os2warp-1", "tap": "wi-os2warp-1"}))
        self._patch(["wi-os2warp-1", "wi-os2warp-2"])
        self.assertEqual(self.broker.reap_orphan_taps(), ["wi-os2warp-2"])

    def test_a_tap_name_recognises_only_the_walk_in_shape(self):
        from . import cell as cell_mod

        self.assertTrue(cell_mod.TAP_RE.match("wi-os2warp-16"))
        for other in ("os2rn0", "win311rn0", "veth952i0", "wi-", "vmbr-wi"):
            self.assertIsNone(cell_mod.TAP_RE.match(other), other)

    def test_a_cell_with_no_clone_behind_it_is_taken_down(self):
        # A leaked cell blocks its SLOT the way a leaked tap blocks its pool
        # index: `ip link add wibr<slot>` fails and the watchdog re-fails.
        self._patch([], cells=[171, 172])
        self.assertEqual(self.broker.reap_orphan_cells(), [171, 172])
        self.assertEqual(self.downed, [("cell", 171), ("cell", 172)])

    def test_a_cell_recorded_in_a_clone_crumb_is_left_alone(self):
        root = naming.WALKIN_ROOT / "walkin-os2warp-1"
        root.mkdir()
        (root / "clone.json").write_text(json.dumps({"identity": "walkin-os2warp-1", "slot": 171}))
        self._patch([], cells=[171, 172])
        self.assertEqual(self.broker.reap_orphan_cells(), [172])


class StrayClaimTests(unittest.TestCase):
    """A restarted broker must hand back its own previous incarnation's claims.

    `/run` survives a service restart, so those claims come back under the same
    session name with no clone behind them. Under the exclusive-take rule they
    are refusals, and kh-claim's own staleness rule would only clear them after
    twelve hours — a pool wedged at "no free slot" against an idle range.
    """

    def setUp(self):
        kh = Path(__file__).resolve().parents[2] / "lib" / "kh-claim.sh"
        if not kh.exists():
            self.skipTest("kh-claim.sh is not in this tree")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.claims_root = tempfile.TemporaryDirectory()
        self.addCleanup(self.claims_root.cleanup)
        self._env = {k: os.environ.get(k) for k in ("KH_CLAIMS_ROOT", "KH_SESSION", "KH_CLAIM_BIN")}
        self.addCleanup(self._restore)
        os.environ.update(KH_CLAIMS_ROOT=self.claims_root.name, KH_SESSION="test-broker", KH_CLAIM_BIN=str(kh))
        self._real_root = naming.WALKIN_ROOT
        naming.WALKIN_ROOT = Path(self.tmp.name)
        self.addCleanup(self._restore_root)
        self.broker = broker_mod.Broker(REPO / "does-not-exist", REPO, spawn=False)

    def _restore(self):
        for key, value in self._env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _restore_root(self):
        naming.WALKIN_ROOT = self._real_root

    def test_a_claim_with_no_clone_behind_it_is_handed_back(self):
        claims.claim_slot("walkin-os2warp-1")
        released = self.broker.release_stray_claims()
        self.assertEqual(sorted(released), ["port/54152", "walkin-slot/152"])
        self.assertEqual(claims.mine(claims.SLOT_CLASS), [])

    def test_a_claim_whose_clone_is_still_on_disk_is_left_alone(self):
        claims.claim_slot("walkin-os2warp-1")
        (naming.WALKIN_ROOT / "walkin-os2warp-1").mkdir()
        self.assertEqual(self.broker.release_stray_claims(), [])
        self.assertEqual(len(claims.mine(claims.SLOT_CLASS)), 1)

    def test_another_broker_s_clone_tree_is_never_touched(self):
        """A dev sandbox and production can share a session name.

        Then each one's `ls --mine` lists the other's claims, and an identity
        this broker has never heard of is NOT a stray — it belongs to a clone
        tree somewhere else, quite possibly with a visitor on it.
        """
        claims.take(claims.SLOT_CLASS, 160, "walkin clone walkin-os2warp-9 @ /data/vms/walkin", exclusive=True)
        self.assertEqual(self.broker.release_stray_claims(), [])
        self.assertEqual(len(claims.mine(claims.SLOT_CLASS)), 1)

    def test_a_legacy_claim_with_no_root_is_still_reclaimable(self):
        claims.take(claims.SLOT_CLASS, 161, "walkin clone walkin-os2warp-9", exclusive=True)
        self.assertEqual(self.broker.release_stray_claims(), ["walkin-slot/161"])

    def test_another_tool_s_claims_are_never_touched(self):
        claims.take("port", "8091", "someone else's server")
        claims.take("sandbox", "somebody", "a rig")
        self.assertEqual(self.broker.release_stray_claims(), [])
        self.assertEqual(len(claims.mine("sandbox")), 1)
        self.assertEqual(len(claims.mine("port")), 1)


class WarmingBlocksNothingTests(unittest.TestCase):
    """A pool that is FILLING must not stop the landing page answering.

    Measured on the live plane at poolSize 3: `refill()` built nine clones
    serially while holding the broker's lock, each one a TCG restore of about
    two minutes, and `/walkin/state` — which needs the same lock for `pools()` —
    timed out for twenty minutes after every restart. The visitor sat on
    "Checking what is free…" the whole time.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._claims = tempfile.TemporaryDirectory()
        self.addCleanup(self._claims.cleanup)
        self._saved = {k: os.environ.get(k) for k in ("KH_CLAIMS_ROOT", "KH_SESSION")}
        os.environ.update(KH_CLAIMS_ROOT=self._claims.name, KH_SESSION="test-warming")
        self.addCleanup(self._restore)
        self._real_root = naming.WALKIN_ROOT
        naming.WALKIN_ROOT = Path(self._tmp.name)

    def _restore(self):
        naming.WALKIN_ROOT = self._real_root
        self._tmp.cleanup()
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _broker(self, factory):
        pool = broker_mod.Broker(REPO / "does-not-exist", REPO, spawn=False, factory=factory)
        pool.specs = {"os2warp": a_spec()}
        pool.access = "open"
        return pool

    def test_the_read_paths_answer_while_a_clone_is_being_built(self):
        gate, started = threading.Event(), threading.Event()

        def slow(spec, index):
            started.set()
            self.assertTrue(gate.wait(20), "the test never released the build")
            return FakeClone(spec, index)

        pool = self._broker(slow)
        builder = threading.Thread(target=pool.refill, daemon=True)
        builder.start()
        self.addCleanup(gate.set)
        self.assertTrue(started.wait(10), "the build never started")
        for _ in range(20):
            began = time.monotonic()
            pool.state()
            pool.live_sessions()
            pool.own_of("nobody")
            pool.signal_entries()
            waited = time.monotonic() - began
            self.assertLess(waited, 0.5, f"a read path waited {waited:.2f}s on the build")
        gate.set()
        builder.join(20)
        self.assertEqual(pool.state()["pools"], [{"os": "os2warp", "free": 2, "size": 2}])

    def test_a_second_refill_does_not_queue_behind_the_first(self):
        gate, started = threading.Event(), threading.Event()

        def slow(spec, index):
            started.set()
            self.assertTrue(gate.wait(20), "the test never released the build")
            return FakeClone(spec, index)

        pool = self._broker(slow)
        builder = threading.Thread(target=pool.refill, daemon=True)
        builder.start()
        self.addCleanup(gate.set)
        self.assertTrue(started.wait(10), "the build never started")
        began = time.monotonic()
        pool.refill()  # a release, an admin reopening the switch — anything
        self.assertLess(time.monotonic() - began, 0.5, "a second refill queued behind a restore")
        gate.set()
        builder.join(20)

    def test_concurrent_refills_never_hand_out_the_same_pool_index(self):
        made = []
        guard = threading.Lock()

        def slow(spec, index):
            time.sleep(0.02)  # a build is never instant; give the race room
            clone = FakeClone(spec, index)
            with guard:
                made.append(clone.identity)
            return clone

        pool = self._broker(slow)
        threads = [threading.Thread(target=pool.refill) for _ in range(6)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(20)
        self.assertEqual(len(made), len(set(made)), f"an index was built twice: {made}")
        # And exactly the pool size, not one per racing caller: the deficit
        # counts what is already in flight.
        self.assertEqual(len(made), 2)
        self.assertEqual(pool.state()["pools"], [{"os": "os2warp", "free": 2, "size": 2}])


if __name__ == "__main__":
    unittest.main()

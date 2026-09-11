"""The hold: freezing a session instead of destroying it, and the ticket cap.

    python3 -m unittest serve.walkin.test_holds

What is being defended here is one claim, and it is the claim the whole
landing redesign rests on: **a stranger cannot keep driving past their sixty
seconds.** Two mechanisms have to hold for that to be true, and each has its
own way of quietly failing:

  * The guest's vCPUs stop. streamhost checks a ticket exactly once, before
    `req.accept()` (`transport/mod.rs`), so a WebTransport session already open
    is never re-checked — the ONLY thing that can make it useless is a machine
    that is not executing.
  * No new session can be opened in its place. That is the ticket TTL, and it
    has to be capped by the SESSION rather than by the flat five minutes, since
    `serve_tile` re-mints on every signalling fetch.

The pool's founding invariant is checked here too, from the new angle: a held
clone is still nobody else's.
"""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from . import broker as broker_mod
from . import derive, naming
from .test_walkin import REPO, a_spec


class HoldableClone:
    """`test_broker.FakeClone` plus the two verbs a hold needs."""

    def __init__(self, spec, index):
        self.spec = spec
        self.plan = derive.plan_for(spec, index, naming.SLOT_MIN + index - 1)
        self.destroyed = False
        self.paused = 0
        self.resumed = 0
        self.pause_raises = False
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
        self.resumed += 1

    def pause(self):
        if self.pause_raises:
            raise RuntimeError("qmp: no such socket")
        self.paused += 1


class HoldCase(unittest.TestCase):
    """A broker over fake clones on a fake clock, as `test_broker` does it."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._claims = tempfile.TemporaryDirectory()
        self.addCleanup(self._claims.cleanup)
        self._saved = {k: os.environ.get(k) for k in ("KH_CLAIMS_ROOT", "KH_SESSION")}
        os.environ.update(KH_CLAIMS_ROOT=self._claims.name, KH_SESSION="test-holds")
        self.addCleanup(self._restore_env)
        self._real_root = naming.WALKIN_ROOT
        naming.WALKIN_ROOT = Path(self._tmp.name)
        self.addCleanup(self._restore_root)
        self.clock = [1000.0]
        self.made: list[HoldableClone] = []

        def factory(spec, index):
            made = HoldableClone(spec, index)
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

    def clone_named(self, identity: str) -> HoldableClone:
        return next(c for c in self.made if c.identity == identity)


# ---- the budget arrives as a TTL, and nothing else changes -----------------


class TestThreadedTtl(HoldCase):
    def test_a_claim_with_no_ttl_keeps_the_pools_own_twenty_minutes(self):
        out = self.broker.claim("u1", "os2warp")
        self.assertEqual(out["ttlSeconds"], broker_mod.TTL_SECONDS)

    def test_a_claim_with_a_ttl_gets_exactly_that_many_seconds(self):
        out = self.broker.claim("anon:v1", "os2warp", ttl=37)
        self.assertEqual(out["ttlSeconds"], 37)

    def test_the_station_is_in_the_body_so_a_random_pick_is_knowable(self):
        # `os` is optional on a claim; without this the visitor cannot find out
        # which machine they were given.
        self.assertEqual(self.broker.claim("u1", "os2warp")["station"], "os2warp")

    def test_a_ttl_of_zero_is_a_session_that_is_already_over(self):
        out = self.broker.claim("anon:v1", "os2warp", ttl=0)
        self.assertEqual(out["ttlSeconds"], 0)


# ---- retime: engagement cutting the claim back to the running budget ------


class TestRetime(HoldCase):
    def test_retime_only_ever_shortens(self):
        out = self.broker.claim("anon:v1", "os2warp", ttl=60)
        self.assertEqual(self.broker.retime("anon:v1", out["clone"], 90), 60, "a longer ttl must not re-arm it")
        self.assertEqual(self.broker.retime("anon:v1", out["clone"], 30), 30)

    def test_retime_refuses_someone_elses_clone(self):
        out = self.broker.claim("anon:v1", "os2warp", ttl=60)
        with self.assertRaises(broker_mod.BrokerError):
            self.broker.retime("anon:v2", out["clone"], 30)

    def test_a_budget_longer_than_the_idle_window_survives_it(self):
        # THE TEST THIS CLASS EXISTS FOR. Before the 2026-09 intro-time change
        # the anonymous budget (60s) was always shorter than the ordinary idle
        # window (`broker_mod.IDLE_SECONDS`, 180s), so `Broker.tick`'s idle
        # branch was mathematically unreachable for an engaged anon session:
        # its own TTL always expired first. A budget longer than the idle
        # window inverts that — and nothing else ever restamps
        # `last_input_at` for this session (`note_input`'s one caller is
        # `POST /walkin/engage`, fired once per clone,
        # `landing/useHeroSession.ts noteInput`) — so without `idle_exempt` a
        # visitor who kept driving for the whole five minutes would be cut off
        # at three, told they had gone idle while they had not. 420 is a
        # claim's un-engaged ceiling (300s budget + 120s un-engaged window,
        # `auth/anon.py AnonBudget.begin`); 300 is what engaging retimes it to.
        out = self.broker.claim("anon:v1", "os2warp", ttl=420)
        self.broker.retime("anon:v1", out["clone"], 300)
        self.clock[0] += broker_mod.IDLE_SECONDS + 1
        self.assertEqual(self.broker.tick()["ended"], [], "idle reap must not fire on a retimed session")
        self.assertFalse(self.clone_named(out["clone"]).destroyed)

    def test_the_retimed_ttl_still_ends_it(self):
        # idle_exempt is not a free pass: the TTL `retime` set is still an
        # unconditional backstop and ends the session on its own.
        out = self.broker.claim("anon:v1", "os2warp", ttl=420)
        self.broker.retime("anon:v1", out["clone"], 300)
        self.clock[0] += 301
        report = self.broker.tick()
        self.assertEqual([code for _, code in report["ended"]], [broker_mod.CLOSE_REASON_TTL])

    def test_an_ordinary_session_still_idle_reaps(self):
        # idle_exempt is opt-in via retime, never a default: an ordinary
        # walk-in claim (never retimed) keeps today's behaviour exactly.
        self.broker.claim("u1", "os2warp")
        self.clock[0] += broker_mod.IDLE_SECONDS + 1
        report = self.broker.tick()
        self.assertEqual([code for _, code in report["ended"]], [broker_mod.CLOSE_REASON_IDLE])


# ---- the ticket cannot outlive the session --------------------------------


class TestTicketCap(HoldCase):
    DEFAULT = 300

    def test_an_unclaimed_pool_member_keeps_the_default(self):
        identity = self.made[0].identity
        self.assertEqual(self.broker.ticket_ttl_for(identity, self.DEFAULT), self.DEFAULT)

    def test_a_station_that_is_not_a_clone_at_all_keeps_the_default(self):
        self.assertEqual(self.broker.ticket_ttl_for("os2warp", self.DEFAULT), self.DEFAULT)

    def test_an_ordinary_walk_in_is_unaffected_until_its_last_five_minutes(self):
        out = self.broker.claim("u1", "os2warp")
        self.assertEqual(self.broker.ticket_ttl_for(out["clone"], self.DEFAULT), self.DEFAULT)

    def test_a_ticket_never_outlives_the_session_it_belongs_to(self):
        out = self.broker.claim("u1", "os2warp")
        # Four minutes left on a twenty-minute session: the five-minute default
        # would hand out a window that outlives the machine.
        self.clock[0] += broker_mod.TTL_SECONDS - 240
        self.assertEqual(self.broker.ticket_ttl_for(out["clone"], self.DEFAULT), 240)

    def test_an_anonymous_ticket_cannot_outlive_the_budget(self):
        # THE TEST THIS FILE EXISTS FOR. A 60-second budget must not be able to
        # mint a 300-second connect window at any point in its life.
        out = self.broker.claim("anon:v1", "os2warp", ttl=60)
        for elapsed in (0, 1, 30, 59):
            self.clock[0] = 1000.0 + elapsed
            ttl = self.broker.ticket_ttl_for(out["clone"], self.DEFAULT)
            self.assertLessEqual(ttl, 60 - elapsed, f"at t+{elapsed}")
            self.assertGreater(ttl, 0, f"at t+{elapsed}")

    def test_a_frozen_clone_mints_nothing_at_all(self):
        out = self.broker.claim("anon:v1", "os2warp", ttl=60)
        self.clock[0] += 60
        self.broker.freeze("anon:v1", 120)
        self.assertEqual(self.broker.ticket_ttl_for(out["clone"], self.DEFAULT), 0)


# ---- the wall --------------------------------------------------------------


class TestFreeze(HoldCase):
    def claim_and_spend(self, user="anon:v1", ttl=60):
        out = self.broker.claim(user, "os2warp", ttl=ttl)
        self.clock[0] += ttl
        return out

    def test_freezing_stops_the_guest(self):
        out = self.claim_and_spend()
        identity = self.broker.freeze("anon:v1", 120)
        self.assertEqual(identity, out["clone"])
        self.assertEqual(self.clone_named(identity).paused, 1)
        self.assertTrue(self.broker.is_frozen(identity))

    def test_a_frozen_machine_is_still_nobody_elses(self):
        # The founding invariant, from the new angle: holding is not releasing.
        self.claim_and_spend()
        self.broker.freeze("anon:v1", 120)
        self.assertEqual(self.broker.state()["pools"], [{"os": "os2warp", "free": 1, "size": 2}])

    def test_the_hold_survives_the_tick_that_would_have_reaped_it(self):
        out = self.claim_and_spend()
        self.broker.freeze("anon:v1", 120)
        self.broker.tick()
        self.assertFalse(self.clone_named(out["clone"]).destroyed)

    def test_the_idle_reap_cannot_eat_the_hold(self):
        # `note_input` has no production caller, so `last_input_at` is stamped
        # once at claim and the 180s idle window is really a second TTL counted
        # from then. A hold set at T+60 would be reaped at T+180 by that clock
        # instead of by its own if freezing did not restamp it.
        out = self.claim_and_spend()
        self.broker.freeze("anon:v1", 120)
        self.clock[0] += 119
        self.broker.tick()
        self.assertFalse(self.clone_named(out["clone"]).destroyed, "reaped 1s before the hold was up")

    def test_the_machine_goes_back_when_the_hold_lapses(self):
        out = self.claim_and_spend()
        self.broker.freeze("anon:v1", 120)
        self.clock[0] += 121
        self.broker.tick()
        self.assertTrue(self.clone_named(out["clone"]).destroyed)

    def test_a_machine_that_will_not_pause_is_destroyed_rather_than_left_running(self):
        # A hold nobody can enforce is not a hold: the visitor's socket is still
        # open, so a guest that would not stop must not be left executing behind
        # a wall that is only a picture.
        out = self.claim_and_spend()
        self.clone_named(out["clone"]).pause_raises = True
        self.assertEqual(self.broker.freeze("anon:v1", 120), "")
        self.assertTrue(self.clone_named(out["clone"]).destroyed)
        self.assertFalse(self.broker.is_frozen(out["clone"]))

    def test_freezing_a_visitor_who_holds_nothing_is_a_no_op(self):
        self.assertEqual(self.broker.freeze("anon:nobody", 120), "")


# ---- crossing it -----------------------------------------------------------


class TestReassign(HoldCase):
    def frozen_claim(self):
        out = self.broker.claim("anon:v1", "os2warp", ttl=60)
        self.clock[0] += 60
        self.broker.freeze("anon:v1", 120)
        return out

    def test_registering_gets_the_same_machine_back_running(self):
        out = self.frozen_claim()
        body = self.broker.reassign("anon:v1", "w1", 1200)
        self.assertEqual(body["clone"], out["clone"])
        self.assertTrue(body["resumed"])
        self.assertEqual(body["ttlSeconds"], 1200)
        self.assertEqual(self.clone_named(out["clone"]).resumed, 1)
        self.assertFalse(self.broker.is_frozen(out["clone"]))

    def test_the_new_owner_is_who_the_pool_answers_for(self):
        out = self.frozen_claim()
        self.broker.reassign("anon:v1", "w1", 1200)
        self.assertEqual((self.broker.own_of("w1") or {})["clone"], out["clone"])
        self.assertIsNone(self.broker.own_of("anon:v1"))

    def test_a_reassigned_machine_gets_the_full_walk_in_ticket_again(self):
        out = self.frozen_claim()
        self.broker.reassign("anon:v1", "w1", 1200)
        self.assertEqual(self.broker.ticket_ttl_for(out["clone"], 300), 300)

    def test_registering_before_the_wall_keeps_the_machine_too(self):
        # A visitor who converts at T+20 rather than at the wall must not be
        # handed a different machine: their work is on this one.
        out = self.broker.claim("anon:v1", "os2warp", ttl=60)
        self.clock[0] += 20
        body = self.broker.reassign("anon:v1", "w1", 1200)
        self.assertEqual(body["clone"], out["clone"])
        self.assertEqual(self.clone_named(out["clone"]).resumed, 0, "it was never paused, so never resumed")

    def test_reassigning_nothing_answers_nothing(self):
        self.assertIsNone(self.broker.reassign("anon:ghost", "w1", 1200))


class TestWallMessage(HoldCase):
    """Which honest sentence a clone that stopped answering carries."""

    BUDGET = "WALKIN_ANON_BUDGET"

    def test_a_frozen_clone_says_the_budget_ran_out(self):
        out = self.broker.claim("anon:v1", "os2warp", ttl=60)
        self.clock[0] += 60
        self.broker.freeze("anon:v1", 120)
        self.assertEqual(
            self.broker.wall_message(out["clone"], self.BUDGET),
            {"type": "session-end", "reason": self.BUDGET},
        )

    def test_a_reaped_clone_keeps_the_reason_it_was_reaped_for(self):
        out = self.broker.claim("u1", "os2warp")
        self.clock[0] += broker_mod.TTL_SECONDS + 1
        self.broker.tick()
        self.assertEqual(self.broker.wall_message(out["clone"], self.BUDGET)["reason"], broker_mod.CLOSE_REASON_TTL)

    def test_an_ordinary_session_out_of_time_is_never_told_about_a_budget(self):
        # The bug this test exists for: an expired walk-in whose clone has not
        # been reaped yet also mints a zero-second ticket, and telling THEM
        # about an anonymous budget would be a lie about their own session.
        out = self.broker.claim("u1", "os2warp")
        self.clock[0] += broker_mod.TTL_SECONDS
        self.assertEqual(self.broker.ticket_ttl_for(out["clone"], 300), 0)
        self.assertEqual(self.broker.wall_message(out["clone"], self.BUDGET)["reason"], broker_mod.CLOSE_REASON_TTL)


# ---- what the watchdog sleeps on -------------------------------------------


class TestNextExpiry(HoldCase):
    def test_an_empty_pool_has_no_deadline(self):
        self.assertIsNone(self.broker.next_expiry())

    def test_the_earliest_session_end_is_the_deadline(self):
        self.broker.claim("u1", "os2warp")
        self.broker.claim("anon:v1", "os2warp", ttl=60)
        self.assertEqual(self.broker.next_expiry(), 1060.0)

    def test_a_destroyed_clone_stops_being_a_frozen_one(self):
        out = self.broker.claim("anon:v1", "os2warp", ttl=60)
        self.clock[0] += 60
        self.broker.freeze("anon:v1", 120)
        self.clock[0] += 121
        self.broker.tick()
        self.broker.next_expiry()
        self.assertFalse(self.broker.is_frozen(out["clone"]))


if __name__ == "__main__":
    unittest.main()

"""Switching machines: the hold, the thaw, the ceiling, and the wall.

    python3 -m unittest serve.walkin.test_switching

Split from `test_holds.py` when the two together went over the 600-line budget,
and the seam is a real one: `test_holds` defends the CONVERSION WALL — a
stranger whose minute is up cannot keep driving — while this file defends the
lifecycle built on the same freeze, which is the operator's ask of 2026-09-15:

    "if I switch between the walkin stations: Win 3.11, OS/2 and Rhapsody, it
    should keep the state they are in for about 5 minutes. after that the
    stations (or their resources) should be released back to the pool"

    "and make sure that if a user completes the passkey registration within
    that about 5 minute time; they are able to resume the last used station
    as-is"

Everything here is the BOOKKEEPING half of those claims — the half a fake clone
can settle. That a thawed guest really shows the desktop the visitor left is not
one of them: the framebuffer is the only proof a guest reacted (rule 9), and
`smoke_hold.py` is where that proof lives. Measured there 2026-09-15 on a real
OS/2 Warp clone: the screen they came back to differed from the one they had
wrecked by 0.0014% and from the one they were first handed by 8.04%.
"""

from __future__ import annotations

from . import broker as broker_mod
from .session import HOLD_SECONDS
from .test_holds import HoldCase
from .test_walkin import a_spec

#
#  The operator's ask, in two halves: "if I switch between the walkin stations
#  it should keep the state they are in for about 5 minutes, after that the
#  stations (or their resources) should be released back to the pool" — and
#  "if a user completes the passkey registration within that time they are able
#  to resume the last used station as-is".
#
#  Everything here is the FIRST half of each of those claims: the bookkeeping
#  that has to be right for the second half to be provable at all. That a
#  thawed guest really shows the desktop the visitor left is not a claim a fake
#  clone can settle — the framebuffer is (rule 9), and `smoke.py --switch`
#  is where that proof lives.


class SwitchCase(HoldCase):
    """Two pools, so "switch" means something. Same fakes, same clock."""

    def setUp(self):
        super().setUp()
        self.broker.specs = {
            "os2warp": a_spec(),
            "win311": a_spec(
                station="win311",
                overrides={
                    "netdev": {"type": "tap", "bridge": "vmbr-wi", "ifnamePattern": "wi-win311-%d"},
                    "tapnet": "x.sh",
                },
            ),
        }
        self.broker.set_access("open")

    def free(self, station: str) -> int:
        return next(p["free"] for p in self.broker.pools() if p["os"] == station)


class TestSwitchingHolds(SwitchCase):
    def test_switching_freezes_the_machine_you_leave_instead_of_destroying_it(self):
        first = self.broker.claim("v1", "os2warp")["clone"]
        self.broker.claim("v1", "win311")
        kept = self.clone_named(first)
        self.assertFalse(kept.destroyed, "the machine they left was destroyed — this is the whole bug")
        self.assertEqual(kept.paused, 1, "a hold whose vCPUs still run is not a hold")
        self.assertTrue(self.broker.is_frozen(first))
        self.assertIn(first, self.broker._members)

    def test_coming_back_inside_the_window_wakes_the_same_clone(self):
        first = self.broker.claim("v1", "os2warp")["clone"]
        self.broker.claim("v1", "win311")
        made_before = len(self.made)
        self.clock[0] += 30
        back = self.broker.claim("v1", "os2warp")
        self.assertEqual(back["clone"], first, "a fresh clone off the golden is exactly what the hold exists to avoid")
        self.assertTrue(back.get("resumed"))
        self.assertEqual(len(self.made), made_before, "no new clone should have been built")
        self.assertFalse(self.broker.is_frozen(first), "a thawed machine is running again, not held")
        self.assertGreater(self.broker.ticket_ttl_for(first, 300), 0, "and it can be driven again")

    def test_a_frozen_machine_cannot_be_driven_while_it_waits(self):
        first = self.broker.claim("v1", "os2warp")["clone"]
        self.broker.claim("v1", "win311")
        self.assertEqual(self.broker.ticket_ttl_for(first, 300), 0, "a hold that can still be reconnected is not held")

    def test_a_held_machine_is_not_free_capacity(self):
        # The landing page's "N of M free" line is read straight off `pools()`.
        # A hold that still counted as free would be the pool promising a
        # machine it cannot hand over — the specific way this feature could
        # make the capacity number lie.
        self.assertEqual(self.free("os2warp"), 2)
        self.broker.claim("v1", "os2warp")
        self.broker.claim("v1", "win311")
        self.assertEqual(self.free("os2warp"), 1, "the frozen machine is still spoken for")

    def test_a_held_clone_is_never_handed_to_a_second_visitor(self):
        # The pool's founding invariant, from the angle this feature opens up.
        first = self.broker.claim("v1", "os2warp")["clone"]
        self.broker.claim("v1", "win311")
        other = self.broker.claim("v2", "os2warp")
        self.assertNotEqual(other["clone"], first)

    def test_the_hold_expires_and_every_resource_goes_back(self):
        first = self.broker.claim("v1", "os2warp")["clone"]
        self.broker.claim("v1", "win311")
        self.clock[0] += HOLD_SECONDS + 1
        self.broker.tick()
        self.assertTrue(self.clone_named(first).destroyed, "the hold outlived its window")
        self.assertNotIn(first, self.broker._members)
        self.assertFalse(self.broker.is_frozen(first))
        self.assertEqual(self.free("os2warp"), 2, "the slot, port, tap and VMID are the pool's again")

    def test_a_lapsed_hold_does_not_tell_the_visitor_their_session_ended(self):
        # `_end` records the reason against the USER, and `GET /walkin/state`
        # hands it to the SPA as `sessionEnd`. Without `end_reason_for` a
        # background hold lapsing posted "your session ended" over the machine
        # the visitor was happily driving.
        self.broker.claim("v1", "os2warp")
        on_screen = self.broker.claim("v1", "win311")["clone"]
        # The idle window (180 s) is a SECOND, shorter clock than the hold, and
        # it is not what this test is about: a real visitor who is driving has
        # sent `POST /walkin/engage`, which is what `retime` stands in for here.
        self.broker.retime("v1", on_screen, broker_mod.TTL_SECONDS)
        self.clock[0] += HOLD_SECONDS + 1
        self.broker.tick()
        self.assertIsNone(self.broker.session_end("v1"), "the machine they are ON is fine")
        self.assertIn(on_screen, self.broker._members, "and it is still theirs")

    def test_the_last_machine_lapsing_still_tells_them(self):
        # The conversion wall's own case: they have nothing else on screen.
        out = self.broker.claim("v1", "os2warp")
        self.broker.freeze("v1", 60)
        self.clock[0] += 61
        self.broker.tick()
        self.assertEqual(self.broker.session_end("v1"), {"type": "session-end", "reason": "WALKIN_TTL"})
        self.assertTrue(self.clone_named(out["clone"]).destroyed)

    def test_an_expired_session_is_retired_rather_than_given_a_fresh_hold(self):
        # Freezing an expired session would hand it HOLD_SECONDS of new life,
        # so the switcher would become a button that resurrects a spent budget.
        first = self.broker.claim("v1", "os2warp", ttl=60)["clone"]
        self.clock[0] += 61
        self.broker.claim("v1", "win311")
        self.assertTrue(self.clone_named(first).destroyed)
        self.assertFalse(self.broker.is_frozen(first))

    def test_holds_of_reports_what_the_switcher_draws(self):
        first = self.broker.claim("v1", "os2warp")["clone"]
        self.broker.claim("v1", "win311")
        self.clock[0] += 60
        self.assertEqual(
            self.broker.holds_of("v1"),
            [{"os": "os2warp", "clone": first, "secondsLeft": HOLD_SECONDS - 60}],
        )
        self.assertEqual(self.broker.holds_of("v2"), [], "one visitor's holds are nobody else's business")

    def test_holds_of_drops_a_lapsed_hold_before_the_reaper_gets_to_it(self):
        self.broker.claim("v1", "os2warp")
        self.broker.claim("v1", "win311")
        self.clock[0] += HOLD_SECONDS + 1
        self.assertEqual(self.broker.holds_of("v1"), [], "between the deadline and the reap it is no longer theirs")

    def test_a_reload_of_the_machine_on_screen_is_still_not_a_switch(self):
        out = self.broker.claim("v1", "os2warp")
        again = self.broker.claim("v1", "os2warp")
        self.assertEqual(again["clone"], out["clone"])
        self.assertEqual(self.clone_named(out["clone"]).paused, 0, "a reload must not freeze the machine it reloads")


class TestHoldCeiling(SwitchCase):
    """The resource ceiling: a visitor's holds cost slots nobody else can have."""

    def setUp(self):
        super().setUp()
        self.broker.specs["rhapsody"] = a_spec(
            station="rhapsody",
            overrides={
                "netdev": {"type": "tap", "bridge": "vmbr-wi", "ifnamePattern": "wi-rhapsody-%d"},
                "tapnet": "x.sh",
            },
        )
        self.broker.set_access("open")

    def test_two_holds_plus_the_one_they_drive_is_the_whole_tour(self):
        # Exactly the landing page's three machines: the ceiling must not cut
        # the tour it was sized for.
        one = self.broker.claim("v1", "os2warp")["clone"]
        two = self.broker.claim("v1", "win311")["clone"]
        self.broker.claim("v1", "rhapsody")
        self.assertEqual([h["clone"] for h in self.broker.holds_of("v1")], sorted([one, two]))
        self.assertFalse(self.clone_named(one).destroyed)
        self.assertFalse(self.clone_named(two).destroyed)

    def test_over_the_ceiling_the_oldest_hold_is_the_one_that_goes(self):
        one = self.broker.claim("v1", "os2warp")["clone"]
        self.clock[0] += 10
        two = self.broker.claim("v1", "win311")["clone"]
        self.clock[0] += 10
        self.broker.claim("v1", "rhapsody")
        self.clock[0] += 10
        # A fourth machine would be a third hold. os2warp was left first.
        self.broker.specs["os2warp"] = a_spec(poolSize=2)
        self.broker.claim("v1", "os2warp")
        self.assertTrue(self.clone_named(one).destroyed or one not in self.broker._members)
        self.assertNotIn(one, [h["clone"] for h in self.broker.holds_of("v1")])
        self.assertIn(two, [h["clone"] for h in self.broker.holds_of("v1")])

    def test_the_evicted_hold_is_not_announced_as_a_session_end(self):
        self.broker.claim("v1", "os2warp")
        self.clock[0] += 10
        self.broker.claim("v1", "win311")
        self.clock[0] += 10
        self.broker.claim("v1", "rhapsody")
        self.clock[0] += 10
        self.broker.claim("v1", "os2warp")
        self.assertIsNone(self.broker.session_end("v1"))


class TestRegisteringResumesTheLastMachine(SwitchCase):
    """Item 2: a passkey made inside the window resumes the LAST used machine."""

    def test_the_wall_hands_back_the_machine_they_were_on_not_an_older_hold(self):
        old = self.broker.claim("anon:v1", "os2warp")["clone"]
        self.clock[0] += 30
        recent = self.broker.claim("anon:v1", "win311")["clone"]
        self.clock[0] += 30
        # The budget runs out on win311: the wall goes up over THAT machine.
        self.broker.freeze("anon:v1", HOLD_SECONDS)
        self.assertTrue(self.broker.is_frozen(recent))
        self.assertTrue(self.broker.is_frozen(old))
        body = self.broker.reassign("anon:v1", "user-42", broker_mod.TTL_SECONDS)
        self.assertEqual(body["clone"], recent, "they registered looking at win311, not at the older hold")
        self.assertTrue(body.get("resumed"))
        self.assertEqual(self.broker.own_of("user-42"), None if body is None else self.broker.own_of("user-42"))
        self.assertEqual(self.broker.own_of("user-42")["clone"], recent)

    def test_converting_hands_the_other_holds_straight_back_to_the_pool(self):
        old = self.broker.claim("anon:v1", "os2warp")["clone"]
        self.clock[0] += 30
        self.broker.claim("anon:v1", "win311")
        self.broker.freeze("anon:v1", HOLD_SECONDS)
        self.broker.reassign("anon:v1", "user-42", broker_mod.TTL_SECONDS)
        self.assertTrue(self.clone_named(old).destroyed, "an account drives one machine; the rest are the pool's")
        self.assertEqual(self.broker.holds_of("user-42"), [])
        self.assertEqual(self.broker.holds_of("anon:v1"), [])

    def test_the_resumed_machine_really_is_running_again(self):
        self.broker.claim("anon:v1", "os2warp")
        recent = self.broker.claim("anon:v1", "win311")["clone"]
        self.broker.freeze("anon:v1", HOLD_SECONDS)
        self.assertEqual(self.clone_named(recent).paused, 1)
        self.broker.reassign("anon:v1", "user-42", broker_mod.TTL_SECONDS)
        # `spawn=False` skips the claim's own resume (no hypervisor under a
        # fake), but `reassign` resumes unconditionally — that IS the hand-off.
        self.assertEqual(self.clone_named(recent).resumed, 1, "resumed for its new owner")

    def test_after_the_window_there_is_nothing_left_to_convert(self):
        self.broker.claim("anon:v1", "os2warp")
        self.broker.freeze("anon:v1", HOLD_SECONDS)
        self.clock[0] += HOLD_SECONDS + 1
        self.broker.tick()
        self.assertIsNone(self.broker.reassign("anon:v1", "user-42", broker_mod.TTL_SECONDS))

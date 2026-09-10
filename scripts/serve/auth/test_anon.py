"""The anonymous visitor: the budget, the wall, the hand-off, and the fence.

    python3 -m unittest serve.auth.test_anon

The funnel used to demand a passkey before a stranger could touch anything.
Inverted, the museum makes a promise it now has to keep in both directions:
sixty seconds really are free, and sixty seconds are really all there is. Both
halves are load-bearing and both are easy to get wrong in a way that looks fine
in a browser —

  * a budget that resets when you switch machines is an infinite budget, and a
    stranger hopping three stations would never be asked to convert;
  * a budget that resets on reload is the same bug reached by pressing F5;
  * a wall that only stops the CLIENT is decorative, because the client is the
    one participant we do not control.

So the arithmetic is tested against a fake clock rather than against a UI, and
the fence is tested by asserting the whole open set, not by spot checks.
"""

from __future__ import annotations

import unittest

from . import anon, gate
from .anon import AnonBudget
from .test_walkin import WalkinCase


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t

    def tick(self, secs):
        self.t += secs


# ---- the arithmetic --------------------------------------------------------


class TestBudget(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.budget = AnonBudget(budget=60, hold=120, unengaged=120, now=self.clock)

    def drive(self, visitor: str, clone: str) -> int:
        """Take a machine AND touch it — which together is what spends a minute.

        Every test in this class is about what DRIVING costs, and since the
        clock moved to first touch (`TestEngagement`) a claim on its own costs
        nothing. Folding the two calls into one helper keeps that rule in the
        one class that tests it, instead of sprinkling an `engage()` through
        arithmetic that is not about engagement at all.
        """
        granted = self.budget.begin(visitor, clone)
        self.budget.engage(visitor)
        return granted

    def test_a_new_visitor_has_the_whole_minute(self):
        self.assertEqual(self.budget.remaining("v1"), 60)
        self.assertFalse(self.budget.expired("v1"))

    def test_the_clock_only_runs_while_they_hold_a_machine(self):
        self.clock.tick(3600)  # an hour of looking at the landing page
        self.assertEqual(self.budget.remaining("v1"), 60)
        self.drive("v1", "walkin-os2warp-1")
        self.clock.tick(10)
        self.assertEqual(self.budget.remaining("v1"), 50)

    def test_a_release_stops_the_clock(self):
        self.drive("v1", "walkin-os2warp-1")
        self.clock.tick(10)
        self.budget.settle("v1")
        self.clock.tick(600)
        self.assertEqual(self.budget.remaining("v1"), 50)

    def test_the_budget_carries_across_a_station_switch(self):
        # THE HEADLINE. Trying all three machines has to cost the same minute as
        # staying on one, or a stranger hops the pool forever and never converts.
        self.drive("v1", "walkin-os2warp-1")
        self.clock.tick(20)
        self.budget.settle("v1")  # release
        granted = self.drive("v1", "walkin-win311-1")  # claim another
        self.assertEqual(granted, 40)
        self.clock.tick(20)
        self.budget.settle("v1")
        self.assertEqual(self.drive("v1", "walkin-rhapsody-1"), 20)

    def test_the_budget_carries_across_a_reload(self):
        # A reload re-claims without releasing; the clock must not restart.
        self.drive("v1", "walkin-os2warp-1")
        self.clock.tick(25)
        self.assertEqual(self.drive("v1", "walkin-os2warp-1"), 35)
        self.clock.tick(5)
        self.assertEqual(self.budget.remaining("v1"), 30)

    def test_two_visitors_do_not_share_a_clock(self):
        self.drive("v1", "walkin-os2warp-1")
        self.clock.tick(40)
        self.assertEqual(self.budget.remaining("v1"), 20)
        self.assertEqual(self.budget.remaining("v2"), 60)

    def test_it_runs_out_at_exactly_sixty(self):
        self.drive("v1", "walkin-os2warp-1")
        self.clock.tick(59)
        self.assertFalse(self.budget.expired("v1"))
        self.clock.tick(1)
        self.assertTrue(self.budget.expired("v1"))
        self.assertEqual(self.budget.remaining("v1"), 0)

    def test_it_never_goes_negative_or_hands_back_a_fresh_minute(self):
        self.drive("v1", "walkin-os2warp-1")
        self.clock.tick(6000)
        self.assertEqual(self.budget.remaining("v1"), 0)
        self.assertEqual(self.drive("v1", "walkin-win311-1"), 0)

    def test_the_deadline_is_what_the_watchdog_sleeps_on(self):
        self.assertIsNone(self.budget.next_deadline())
        self.drive("v1", "walkin-os2warp-1")
        self.assertEqual(self.budget.next_deadline(), 1060.0)
        self.clock.tick(30)
        self.drive("v2", "walkin-win311-1")
        self.assertEqual(self.budget.next_deadline(), 1060.0, "the earlier of the two")

    def test_an_untouched_claim_is_due_on_its_own_clock(self):
        # A visitor who has not touched anything has no wall coming — there is
        # no minute running to end. What they DO have is a cell, and the sweep
        # that takes it back is the deadline the watchdog has to wake for.
        self.budget.begin("v1", "walkin-os2warp-1")
        self.assertIsNone(self.budget.next_deadline(), "no clock, no wall")
        self.assertEqual(self.budget.next_unengaged(), 1120.0)
        self.budget.engage("v1")
        self.assertEqual(self.budget.next_deadline(), 1060.0)
        self.assertIsNone(self.budget.next_unengaged(), "a touched machine is never swept")


class TestEngagement(unittest.TestCase):
    """The minute starts when the visitor touches the machine — not when the
    page takes one.

    This is the rule an operator reported as a bug in the plainest possible
    terms: "the 1 minute should only start after I have interacted with the
    machine in a meaningful way like first click or keyboard entry. just moving
    the mouse over the display canvas should not start it." The landing page
    auto-claims on load, so under the old rule a stranger reading the headline
    had already spent a quarter of their minute — measured, on the live site:
    a claim at 0.9s and a page that had burned 17 seconds before anybody
    touched anything.

    What the browser may say is "somebody touched it", never "and it has been
    N seconds" — so every number here is still the server's.
    """

    def setUp(self):
        self.clock = Clock()
        self.budget = AnonBudget(budget=60, hold=120, unengaged=120, now=self.clock)

    def test_claiming_a_machine_spends_nothing(self):
        self.budget.begin("v1", "walkin-os2warp-1")
        self.clock.tick(300)  # five minutes of reading the page
        self.assertEqual(self.budget.remaining("v1"), 60)
        self.assertFalse(self.budget.expired("v1"))

    def test_the_first_touch_starts_it(self):
        self.budget.begin("v1", "walkin-os2warp-1")
        self.clock.tick(30)
        self.budget.engage("v1")
        self.clock.tick(10)
        self.assertEqual(self.budget.remaining("v1"), 50, "ten seconds of driving, not forty")

    def test_touching_it_again_does_not_restart_anything(self):
        self.budget.begin("v1", "walkin-os2warp-1")
        self.budget.engage("v1")
        self.clock.tick(20)
        self.budget.engage("v1")
        self.budget.engage("v1")
        self.clock.tick(10)
        self.assertEqual(self.budget.remaining("v1"), 30)

    def test_engagement_is_a_fact_about_the_person_not_the_machine(self):
        # Otherwise switching stations would buy a fresh un-touched window
        # every time, and a visitor could hold the pool for as long as they
        # kept pressing chips.
        self.budget.begin("v1", "walkin-os2warp-1")
        self.budget.engage("v1")
        self.clock.tick(20)
        self.budget.settle("v1")  # release
        self.budget.begin("v1", "walkin-win311-1")  # claim another
        self.clock.tick(10)
        self.assertEqual(self.budget.remaining("v1"), 30, "the new machine spends from the first second")
        self.assertEqual(self.budget.unengaged(), [], "and is never swept as untouched")

    def test_an_untouched_machine_goes_back_to_the_pool(self):
        self.budget.begin("v1", "walkin-os2warp-1")
        self.clock.tick(119)
        self.assertEqual(self.budget.unengaged(), [])
        self.clock.tick(1)
        self.assertEqual(self.budget.unengaged(), [("v1", "walkin-os2warp-1")])

    def test_a_touched_machine_is_never_swept(self):
        self.budget.begin("v1", "walkin-os2warp-1")
        self.budget.engage("v1")
        self.clock.tick(6000)
        self.assertEqual(self.budget.unengaged(), [], "the wall ends this visit, not the sweep")

    def test_a_visitor_holding_nothing_is_not_swept(self):
        self.budget.begin("v1", "walkin-os2warp-1")
        self.budget.settle("v1")
        self.clock.tick(600)
        self.assertEqual(self.budget.unengaged(), [])

    def test_the_claim_ttl_covers_the_whole_visit_and_no_more(self):
        # The session is built with this number, so it has to outlast both
        # bounds enforced ahead of it — the un-touched sweep and the wall.
        self.assertEqual(self.budget.claim_ttl("v1"), 180, "two minutes to touch it, plus the minute")
        self.budget.begin("v1", "walkin-os2warp-1")
        self.budget.engage("v1")
        self.clock.tick(20)
        self.assertEqual(self.budget.claim_ttl("v1"), 40, "once spending, exactly what is left")

    def test_the_state_block_says_whether_the_clock_is_running(self):
        self.assertFalse(self.budget.block("v1")["engaged"])
        self.budget.begin("v1", "walkin-os2warp-1")
        self.assertFalse(self.budget.block("v1")["engaged"], "claimed is not touched")
        self.budget.engage("v1")
        self.assertTrue(self.budget.block("v1")["engaged"])


class TestHold(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.budget = AnonBudget(budget=60, hold=120, unengaged=120, now=self.clock)
        self.budget.begin("v1", "walkin-os2warp-1")
        self.budget.engage("v1")
        self.clock.tick(60)

    def test_exhaustion_reserves_the_machine_they_were_driving(self):
        self.budget.reserve("v1", "walkin-os2warp-1", "os2warp")
        self.assertEqual(self.budget.held("v1")["clone"], "walkin-os2warp-1")
        self.assertEqual(self.budget.held("v1")["station"], "os2warp")

    def test_the_hold_lapses_after_two_minutes(self):
        self.budget.reserve("v1", "walkin-os2warp-1", "os2warp")
        self.clock.tick(119)
        self.assertTrue(self.budget.held("v1"))
        self.assertEqual(self.budget.lapsed_holds(), [])
        self.clock.tick(2)
        self.assertEqual(self.budget.held("v1"), {})
        self.assertEqual(self.budget.lapsed_holds(), ["v1"])

    def test_a_reserved_visitor_is_still_spent(self):
        self.budget.reserve("v1", "walkin-os2warp-1", "os2warp")
        self.assertTrue(self.budget.expired("v1"))
        self.clock.tick(300)
        self.assertTrue(self.budget.expired("v1"), "waiting out the hold buys nothing")

    def test_the_state_block_mirrors_the_server(self):
        block = self.budget.block("v1")
        self.assertEqual(block["budgetSeconds"], 60)
        self.assertEqual(block["remainingSeconds"], 0)
        self.assertTrue(block["expired"])
        self.assertNotIn("heldClone", block)
        self.budget.reserve("v1", "walkin-os2warp-1", "os2warp")
        self.assertEqual(self.budget.block("v1")["heldClone"], "walkin-os2warp-1")

    def test_the_kill_switch_forgets_everyone(self):
        self.budget.reserve("v1", "walkin-os2warp-1", "os2warp")
        self.assertEqual(self.budget.drop_all(), 1)
        self.assertEqual(self.budget.held("v1"), {})


# ---- the fence -------------------------------------------------------------


class TestAnonFence(unittest.TestCase):
    STRANGER = anon.user_for("v1")
    WALKIN = {"id": "w1", "role": "walkin"}
    VIEWER = {"id": "v1", "role": "viewer"}

    def test_the_front_door_is_open_to_a_browser_with_no_session_at_all(self):
        self.assertTrue(gate.is_open("/"))

    def test_the_open_set_gained_exactly_one_path(self):
        # A frozen assertion, on purpose. The one thing the landing redesign is
        # allowed to publish is the app shell at `/`; anything else appearing
        # here is a widening somebody has to argue for in review, not a diff
        # nobody reads.
        self.assertEqual(
            gate.OPEN_PATHS,
            frozenset(
                {
                    "/",
                    "/healthz",
                    "/login",
                    "/link",
                    "/favicon.ico",
                    "/manifest.webmanifest",
                    "/sw.js",
                    "/walkin",
                    "/walkin/exhibits",
                    "/walkin/manifest.json",
                    "/poster-docs.json",
                    "/walkin/state",
                    "/walkin/signup",
                    "/walkin/signup/begin",
                    "/walkin/signup/finish",
                }
            ),
        )

    def test_the_open_prefixes_are_untouched(self):
        self.assertEqual(gate.OPEN_PREFIXES, ("/auth/", "/ui/", "/assets/", "/posters/", "/vendor/"))

    def test_the_command_enqueue_is_still_unreachable_from_anywhere(self):
        self.assertEqual(gate.BLOCKED_PREFIXES, ("/clientcmd/admin",))
        for user in (None, self.STRANGER, self.WALKIN, self.VIEWER):
            self.assertFalse(gate.allows("/clientcmd/admin", user), user)
            self.assertFalse(gate.allows("/clientcmd/admin/queue", user), user)

    def test_a_stranger_reaches_the_landing_page_and_what_it_needs(self):
        for path in ("/", "/walkin", "/walkin/state", "/walkin/claim", "/walkin/release", "/walkin/manifest.json"):
            self.assertTrue(gate.allows(path, self.STRANGER), path)
        for path in ("/assets/index-abc12345.js", "/posters/os2warp-hero.webp", "/poster-docs.json"):
            self.assertTrue(gate.allows(path, self.STRANGER), path)

    def test_a_stranger_reaches_no_operator_surface(self):
        for path in (
            "/admin",
            "/fleet",
            "/fleet-table.json",
            "/museum",
            "/gallery-manifest.json",
            "/tiles.json",
            "/usage/stations.json",
            "/clientcmd/admin",
        ):
            self.assertFalse(gate.allows(path, self.STRANGER), path)

    def test_the_auth_api_is_gate_open_for_everyone_and_always_was(self):
        # `/auth/` is in OPEN_PREFIXES and has been since the fence was built:
        # the sign-in API has to be reachable BEFORE anyone is signed in. The
        # gate therefore says yes to `/auth/*` for a stranger exactly as it
        # already did for a signed-out browser and for a walk-in — the fence
        # was not widened, and the authorisation for these routes has never
        # lived here. `TestAdminRoutesStayLocked` below is where it does live.
        for path in ("/auth/state", "/auth/walkin/status", "/auth/vitals/summary"):
            self.assertTrue(gate.is_open(path), path)
            self.assertEqual(gate.allows(path, self.STRANGER), gate.allows(path, self.WALKIN), path)

    def test_a_stranger_gets_less_than_a_walk_in_never_more(self):
        # The proof that the anonymous role is a SUBSET. Anything a stranger may
        # reach, somebody who registered may reach too — so opening this door
        # cannot have opened one the walk-in fence had shut.
        own = "/signal/walkin-os2warp-3.json"
        probe = sorted(gate.ANON_PATHS | gate.WALKIN_PATHS | {"/", "/admin", "/fleet", "/eum", "/staging/x/", own})
        for path in probe:
            if gate.allows(path, self.STRANGER, own_signal=own):
                self.assertTrue(gate.allows(path, self.WALKIN, own_signal=own), f"stranger > walk-in at {path}")

    def test_the_surfaces_a_walk_in_earned_by_registering_stay_earned(self):
        for path in ("/account", "/clientcmd", "/usage", "/analytics", "/traces", "/eum", "/walkin/reset"):
            self.assertTrue(gate.allows(path, self.WALKIN), path)
            self.assertFalse(gate.allows(path, self.STRANGER), path)

    def test_a_stranger_may_report_on_their_own_broken_stream_and_read_nothing(self):
        # Both are write-only ingests; every READ of what they collect lives
        # under /auth/, behind an admin check in the auth routes themselves.
        for path in ("/clientlog", "/vitals"):
            self.assertTrue(gate.allows(path, self.STRANGER), path)
        self.assertFalse(gate.allows("/vitals/summary", self.STRANGER))
        self.assertFalse(gate.allows("/usage/stations.json", self.STRANGER))

    def test_the_only_machine_a_stranger_can_reach_is_their_own(self):
        own = "/signal/walkin-os2warp-3.json"
        self.assertTrue(gate.allows(own, self.STRANGER, own_signal=own))
        self.assertTrue(gate.allows("/webrtc/walkin-os2warp-3/offer", self.STRANGER, own_signal=own))
        for path in ("/signal/os2warp.json", "/signal/index.json", "/webrtc/os2warp/offer", own):
            self.assertFalse(gate.allows(path, self.STRANGER), path)

    def test_invited_and_walk_in_sessions_keep_the_behaviour_they_had(self):
        for path in ("/fleet", "/gallery-manifest.json", "/signal/os2warp.json"):
            self.assertTrue(gate.allows(path, self.VIEWER), path)
        self.assertTrue(gate.allows("/walkin/claim", self.WALKIN))
        self.assertFalse(gate.allows("/gallery-manifest.json", self.WALKIN))

    def test_a_refused_page_still_sends_a_signed_out_browser_to_login(self):
        self.assertEqual(gate.landing_for(None), "/login")
        self.assertEqual(gate.landing_for(self.WALKIN), "/walkin")


# ---- the switch ------------------------------------------------------------


class TestSwitchReachesStrangers(WalkinCase):
    def test_a_stranger_is_refused_at_invited_and_at_closed(self):
        svc = self.service()
        stranger = anon.user_for("v1")
        for access, reachable in (("open", True), ("invited", False), ("closed", False)):
            svc.walkin.set_access(self.admin(svc), access)
            svc.walkin._env = {"WALKIN_OPEN": "open"}
            self.assertEqual(svc.walkin.is_open_to(stranger), reachable, access)

    def test_dropping_to_closed_forgets_every_anonymous_budget(self):
        # The one class of visitor the kill switch must not fail to reach: they
        # have no session row to delete, so the ledger IS their session.
        svc = self.service()
        svc.anon.budget.begin("v1", "walkin-os2warp-1")
        svc.anon.budget.begin("v2", "walkin-win311-1")
        out = svc.walkin.set_access(self.admin(svc), "closed")
        self.assertGreaterEqual(out["disconnected"], 2)
        self.assertEqual(svc.anon.budget.remaining("v1"), 60, "forgotten, not merely stopped")

    def test_the_env_floor_lowers_a_stranger_too(self):
        svc = self.service(env={"WALKIN_OPEN": "0"})
        svc.walkin.set_access(self.admin(svc), "open")
        self.assertFalse(svc.walkin.is_open_to(anon.user_for("v1")))


if __name__ == "__main__":
    unittest.main()

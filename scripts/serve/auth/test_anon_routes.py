"""The anonymous visitor over HTTP: claiming, the wall, and the hand-off.

    python3 -m unittest serve.auth.test_anon_routes

`test_anon.py` proves the budget arithmetic against a fake clock. This proves
the same rules through `walkin.routes.dispatch`, which is where they are
actually spent: a claim with no `os`, a countdown that survives a switch and a
reload, a refusal with its own code, and a machine handed back to the account a
stranger has just made. Split from `test_anon.py` at the file-size cap, along
the seam between "the ledger is right" and "the route spends it correctly".
"""

from __future__ import annotations

import json
import unittest

from . import anon, gate
from .anon import AnonBudget
from .anon_plane import AnonPlane
from .test_anon import Clock
from .test_walkin import WalkinCase

# ---- a pool that answers like the real one ---------------------------------


class PoolDouble:
    """The broker's claim/release surface, faithful to `walkin/broker.py`.

    Deliberately a double rather than the real `Broker`: these tests are about
    the AUTH half, and a sibling stream is rewriting the pool's slot allocation
    underneath. The pool's own half is proved against the real broker in
    `walkin/test_holds.py`.
    """

    TTL = 1200

    def __init__(self, clock, stations=("os2warp", "win311", "rhapsody"), size=2):
        self.clock = clock
        self.access = "open"
        self.size = size
        self.free = {s: size for s in stations}
        self.sessions: dict[str, dict] = {}  # user -> {clone, station, expires}
        self.frozen: set[str] = set()
        self.paused: list[str] = []
        self.inputs: list[str] = []
        self.serial = 0

    # -- the surface the routes use ---------------------------------------
    def state(self):
        return {"access": self.access, "pools": self.pools()}

    def pools(self):
        return [{"os": s, "free": self.free[s], "size": self.size} for s in sorted(self.free)]

    def session_end(self, user_id):
        return None

    def claim(self, user_id, station, ttl=None):
        if station not in self.free:
            raise RuntimeError(f"no walk-in pool for {station!r}")
        held = self.sessions.get(user_id)
        ttl = self.TTL if ttl is None else float(ttl)
        if held and held["station"] == station and held["expires"] > self.clock():
            return self._body(held, resumed=True)
        if held:
            self._retire(user_id)
        if self.free[station] <= 0:
            return {"queued": True, "position": 1}
        self.serial += 1
        self.free[station] -= 1
        self.sessions[user_id] = {
            "clone": f"walkin-{station}-{self.serial}",
            "station": station,
            "expires": self.clock() + ttl,
        }
        return self._body(self.sessions[user_id])

    def release(self, user_id, clone):
        held = self.sessions.get(user_id)
        if not held or held["clone"] != clone:
            raise RuntimeError(f"{clone} is not yours")
        self._retire(user_id)
        return {"ok": True}

    def reset(self, user_id, clone):
        station = self.sessions[user_id]["station"]
        self.release(user_id, clone)
        return self.claim(user_id, station)

    def own_of(self, user_id):
        held = self.sessions.get(user_id)
        return None if not held else {"station": held["station"], "clone": held["clone"]}

    def retime(self, user_id, identity, ttl):
        held = self.sessions.get(user_id)
        if not held or held["clone"] != identity:
            raise RuntimeError(f"{identity} is not yours")
        held["expires"] = min(held["expires"], self.clock() + max(0.0, float(ttl)))
        return int(max(0, held["expires"] - self.clock()))

    def note_input(self, clone):
        # The real broker restamps `last_input_at`, which is what keeps a
        # driven session out of the 180-second idle reap. Recorded rather than
        # simulated: what these tests care about is that the route calls it at
        # all, since until `/walkin/engage` existed nothing in production did.
        self.inputs.append(clone)

    def freeze(self, user_id, hold_secs):
        held = self.sessions.get(user_id)
        if not held:
            return ""
        self.frozen.add(held["clone"])
        self.paused.append(held["clone"])
        held["expires"] = self.clock() + hold_secs
        return held["clone"]

    def reassign(self, from_user, to_user, ttl):
        held = self.sessions.pop(from_user, None)
        if held is None:
            return None
        self.frozen.discard(held["clone"])
        held["expires"] = self.clock() + ttl
        self.sessions[to_user] = held
        return self._body(held, resumed=True)

    # -- internals ---------------------------------------------------------
    def _retire(self, user_id):
        held = self.sessions.pop(user_id)
        self.free[held["station"]] += 1
        self.frozen.discard(held["clone"])

    def _body(self, held, resumed=False):
        out = {
            "clone": held["clone"],
            "station": held["station"],
            "signalEndpoint": f"/signal/{held['clone']}.json",
            "ttlSeconds": int(max(0, held["expires"] - self.clock())),
        }
        if resumed:
            out["resumed"] = True
        return out


class RecordingHandler:
    """A request handler that remembers its response headers."""

    def __init__(self, body=None, cookies=""):
        self.headers = {"Origin": "https://example.test", "User-Agent": "smoke"}
        if cookies:
            self.headers["Cookie"] = cookies
        self._body = body
        self.command = "POST" if body is not None else "GET"
        self.client_address = ("127.0.0.1", 1)
        self.status = None
        self.out: list[tuple[str, str]] = []
        self.sent = b""
        self.wfile = self

    def read_json_body(self, cap):
        return (self._body, None) if self._body is not None else ({}, None)

    def send_response(self, code):
        self.status = code

    def send_header(self, key, value):
        self.out.append((key, value))

    def end_headers(self):
        pass

    def write(self, data):
        self.sent += data

    @property
    def json(self):
        return json.loads(self.sent)

    @property
    def set_cookie(self) -> str:
        return next((v for k, v in self.out if k == "Set-Cookie"), "")


# ---- the plane, end to end over the routes ---------------------------------


class AnonRouteCase(unittest.TestCase):
    def setUp(self):
        # The same dual import the serving plane uses: `scripts/serve` is on
        # sys.path in the unit, and `serve.` is the prefix under the runner.
        try:
            from walkin import routes as walkin_routes
        except ImportError:
            from serve.walkin import routes as walkin_routes

        self.routes = walkin_routes
        self.clock = Clock()
        self.pool = PoolDouble(self.clock)
        self.plane = AnonPlane(budget=AnonBudget(budget=60, hold=120, now=self.clock), walkin_ttl=1200, now=self.clock)

    def call(self, path, method="GET", body=None, cookies="", user=None):
        handler = RecordingHandler(body=body, cookies=cookies)
        visitor = self.plane.visitor(handler, user)
        handled = self.routes.dispatch(handler, path, method, self.pool, visitor, "open", self.plane)
        self.assertTrue(handled, path)
        return handler

    def stranger(self, vid="v1"):
        return f"{anon.COOKIE_NAME}={vid}"

    def touch(self, clone, vid="v1"):
        """What the browser sends on the visitor's first real press or key.

        Every test below that ticks the clock expecting it to cost something
        goes through here, because since 2026-09-10 a claim on its own spends
        nothing — the minute starts at the first touch (`test_anon.py
        TestEngagement`, and `TestEngageRoute` at the bottom of this file).
        """
        return self.call("/walkin/engage", "POST", {"clone": clone}, self.stranger(vid))


class TestAnonClaim(AnonRouteCase):
    def test_a_stranger_claims_with_no_passkey_at_all(self):
        out = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger()).json
        self.assertEqual(out["station"], "os2warp")
        # The session TTL, not the countdown: the visitor's minute has not
        # started (nothing has been touched), so this is the longest the visit
        # could possibly last — two minutes to touch it plus the minute itself.
        # `/walkin/state` is where the visitor's actual clock is read, and it
        # still says sixty.
        self.assertEqual(out["ttlSeconds"], 180)
        self.assertEqual(self.call("/walkin/state", cookies=self.stranger()).json["anon"]["remainingSeconds"], 60)
        self.assertTrue(out["clone"].startswith("walkin-os2warp-"))

    def test_os_is_optional_and_the_station_comes_back(self):
        out = self.call("/walkin/claim", "POST", {}, self.stranger()).json
        self.assertIn(out["station"], ("os2warp", "win311", "rhapsody"))
        self.assertEqual(out["signalEndpoint"], f"/signal/{out['clone']}.json")

    def test_the_random_pick_is_spread_across_the_enabled_pools(self):
        seen = {self.routes.random_station(self.pool) for _ in range(200)}
        self.assertEqual(seen, {"os2warp", "win311", "rhapsody"})

    def test_the_random_pick_prefers_a_pool_with_a_free_machine(self):
        self.pool.free = {"os2warp": 0, "win311": 0, "rhapsody": 1}
        self.assertEqual({self.routes.random_station(self.pool) for _ in range(50)}, {"rhapsody"})

    def test_a_first_visit_plants_the_cookie_once(self):
        first = self.call("/walkin/claim", "POST", {"os": "os2warp"})
        self.assertIn(f"{anon.COOKIE_NAME}=", first.set_cookie)
        for attr in ("HttpOnly", "Secure", "SameSite=Lax", "Path=/"):
            self.assertIn(attr, first.set_cookie)
        again = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger())
        self.assertEqual(again.set_cookie, "", "a visitor who already has one is not re-stamped")

    def test_a_read_only_poll_never_mints_an_identity(self):
        """The cold-jar race behind the 401s of 2026-09-11 04:23:36.

        The landing page fires two `GET /walkin/state` polls concurrently
        before any cookie exists. While a read planted one, each minted its own
        id and the last response to land won the jar — orphaning the identity
        the claim had just bound the clone to, which `gate.anon_allows` then
        refused, answering 401 on the visitor's OWN signalling document.
        """
        self.assertEqual(self.call("/walkin/state").set_cookie, "")
        self.assertEqual(self.call("/walkin/state").set_cookie, "")
        # The write still plants exactly one, and it is the one that holds the
        # clone: a claim and its signalling fetch can no longer disagree.
        claim = self.call("/walkin/claim", "POST", {"os": "os2warp"})
        self.assertIn(f"{anon.COOKIE_NAME}=", claim.set_cookie)

    def test_a_cookie_from_a_hostile_client_is_not_taken_as_an_identity(self):
        handler = RecordingHandler(cookies=f"{anon.COOKIE_NAME}=../../etc/passwd")
        visitor = self.plane.visitor(handler, None)
        self.assertNotIn("/", visitor["id"])
        self.assertTrue(visitor.get("anonFresh"), "a junk id is replaced, never adopted")


class TestBudgetOverTheWire(AnonRouteCase):
    def drive(self, secs, os_name="os2warp", vid="v1"):
        out = self.call("/walkin/claim", "POST", {"os": os_name}, self.stranger(vid)).json
        self.touch(out["clone"], vid)
        self.clock.tick(secs)
        return out

    def test_switching_stations_continues_the_countdown(self):
        # The contract's rationale, over HTTP: trying all three costs your minute.
        first = self.drive(20, "os2warp")
        self.call("/walkin/release", "POST", {"clone": first["clone"]}, self.stranger())
        second = self.call("/walkin/claim", "POST", {"os": "win311"}, self.stranger()).json
        self.assertEqual(second["ttlSeconds"], 40)
        self.clock.tick(20)
        self.call("/walkin/release", "POST", {"clone": second["clone"]}, self.stranger())
        third = self.call("/walkin/claim", "POST", {"os": "rhapsody"}, self.stranger()).json
        self.assertEqual(third["ttlSeconds"], 20)

    def test_a_reload_re_attaches_without_restarting_the_clock(self):
        self.drive(25)
        again = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger()).json
        self.assertTrue(again["resumed"])
        self.assertEqual(again["ttlSeconds"], 35)

    def test_back_navigation_to_another_station_does_not_buy_a_fresh_minute(self):
        # No release at all: a claim for a DIFFERENT station retires the old
        # clone. The budget must not care which road was taken.
        self.drive(30, "os2warp")
        other = self.call("/walkin/claim", "POST", {"os": "win311"}, self.stranger()).json
        self.assertEqual(other["ttlSeconds"], 30)

    def test_the_state_doc_carries_the_countdown_for_a_stranger(self):
        self.drive(15)
        block = self.call("/walkin/state", cookies=self.stranger()).json["anon"]
        self.assertEqual(block, {"budgetSeconds": 60, "remainingSeconds": 45, "expired": False, "engaged": True})

    def test_the_state_doc_has_no_anon_block_for_an_account(self):
        doc = self.call("/walkin/state", user={"id": "w1", "role": "walkin"}).json
        self.assertNotIn("anon", doc)

    def test_a_walk_in_account_still_gets_the_full_twenty_minutes(self):
        out = self.call("/walkin/claim", "POST", {"os": "os2warp"}, user={"id": "w1", "role": "walkin"}).json
        self.assertEqual(out["ttlSeconds"], 1200)


class TestEngageRoute(AnonRouteCase):
    """`POST /walkin/engage` — the one signal that starts a stranger's minute.

    Reported by the operator as two bugs with one cause: "the 1 minute should
    only start after I have interacted with the machine in a meaningful way
    like first click or keyboard entry", and a station that changed underneath
    them. Both came of counting from the CLAIM, which the landing page makes on
    load. The browser half decides what counts as a touch
    (`landing/heroPolicy.ts MEANINGFUL_EVENTS`); this half decides what a touch
    is worth, and refuses to take the browser's word for anything else.
    """

    def test_the_minute_does_not_start_until_the_visitor_touches_it(self):
        self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger())
        self.clock.tick(45)
        block = self.call("/walkin/state", cookies=self.stranger()).json["anon"]
        self.assertEqual(block["remainingSeconds"], 60, "reading the page costs nothing")
        self.assertFalse(block["engaged"])

    def test_a_touch_starts_it_and_the_reply_carries_the_clock(self):
        out = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger()).json
        self.clock.tick(45)
        answer = self.touch(out["clone"]).json
        self.assertTrue(answer["ok"])
        self.assertEqual(
            answer["anon"], {"budgetSeconds": 60, "remainingSeconds": 60, "expired": False, "engaged": True}
        )
        self.clock.tick(10)
        self.assertEqual(self.call("/walkin/state", cookies=self.stranger()).json["anon"]["remainingSeconds"], 50)

    def test_the_session_is_cut_back_to_the_minute_that_just_started(self):
        # Otherwise a reconnect ticket outlives the wall: `ticket_ttl_for` caps
        # at the session's remaining seconds, and the session was built long
        # enough to survive a visit nobody ever touched.
        out = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger()).json
        self.assertEqual(out["ttlSeconds"], 180)
        self.touch(out["clone"])
        again = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger()).json
        self.assertTrue(again["resumed"])
        self.assertEqual(again["ttlSeconds"], 60)

    def test_it_is_the_first_production_writer_of_the_idle_clock(self):
        out = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger()).json
        self.touch(out["clone"])
        self.assertEqual(self.pool.inputs, [out["clone"]])

    def test_a_clone_that_is_not_yours_is_refused(self):
        mine = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger("v1")).json
        theirs = self.call("/walkin/claim", "POST", {"os": "win311"}, self.stranger("v2")).json
        handler = self.call("/walkin/engage", "POST", {"clone": theirs["clone"]}, self.stranger("v1"))
        self.assertEqual(handler.status, 403)
        self.assertEqual(self.pool.inputs, [], "nobody's idle clock was restamped")
        self.assertFalse(self.call("/walkin/state", cookies=self.stranger("v1")).json["anon"]["engaged"])
        self.assertTrue(mine["clone"] and theirs["clone"])

    def test_engaging_with_no_clone_at_all_is_refused(self):
        self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger())
        self.assertEqual(self.call("/walkin/engage", "POST", {}, self.stranger()).status, 403)

    def test_an_untouched_cell_goes_back_to_the_pool(self):
        # The price of starting the clock at first touch: nothing else would
        # ever end the hold of a crawler, and there are 24 cells in the museum.
        before = dict(self.pool.free)
        out = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger()).json
        self.assertEqual(self.pool.free["os2warp"], before["os2warp"] - 1)
        self.clock.tick(119)
        self.plane.enforce(self.pool)
        self.assertEqual(self.pool.free["os2warp"], before["os2warp"] - 1, "not yet")
        self.clock.tick(2)
        self.plane.enforce(self.pool)
        self.assertEqual(self.pool.free, before, "the cell is back")
        self.assertNotIn(out["clone"], self.pool.frozen, "nothing to freeze: nothing happened")
        self.assertEqual(
            self.call("/walkin/state", cookies=self.stranger()).json["anon"]["remainingSeconds"],
            60,
            "and they keep their whole minute",
        )

    def test_a_touched_cell_is_never_swept(self):
        out = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger()).json
        self.touch(out["clone"])
        self.clock.tick(59)
        self.plane.enforce(self.pool)
        self.assertEqual(self.pool.own_of(anon.user_for("v1")["id"])["clone"], out["clone"], "still theirs")
        self.assertNotIn(out["clone"], self.pool.frozen)

    def test_the_watchdog_wakes_for_the_sweep(self):
        self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger())
        self.assertEqual(self.plane.next_deadline(), self.clock() + 120)


class TestExhaustion(AnonRouteCase):
    def spend(self, vid="v1"):
        out = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger(vid)).json
        self.touch(out["clone"], vid)
        self.clock.tick(60)
        self.plane.enforce(self.pool)
        return out

    def test_the_wall_lands_at_the_deadline_and_not_before(self):
        out = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger()).json
        self.touch(out["clone"])
        self.clock.tick(59)
        self.assertEqual(self.plane.enforce(self.pool), [])
        self.clock.tick(1)
        self.assertEqual(len(self.plane.enforce(self.pool)), 1)

    def test_a_spent_visitor_is_refused_with_its_own_code(self):
        self.spend()
        handler = self.call("/walkin/claim", "POST", {"os": "win311"}, self.stranger())
        self.assertEqual(handler.status, 403)
        self.assertEqual(handler.json["error"], anon.REASON_BUDGET)
        self.assertEqual(handler.json["reason"], anon.REASON_BUDGET)
        self.assertTrue(handler.json["anon"]["expired"])

    def test_the_refusal_is_not_a_way_to_get_another_machine(self):
        self.spend()
        before = dict(self.pool.free)
        self.call("/walkin/claim", "POST", {}, self.stranger())
        self.assertEqual(self.pool.free, before)

    def test_the_wall_stops_the_guest(self):
        out = self.spend()
        self.assertEqual(self.pool.paused, [out["clone"]])
        self.assertIn(out["clone"], self.pool.frozen)

    def test_the_held_clone_is_on_the_state_doc(self):
        out = self.spend()
        block = self.call("/walkin/state", cookies=self.stranger()).json["anon"]
        self.assertEqual(block["heldClone"], out["clone"])
        self.assertEqual(block["remainingSeconds"], 0)
        self.assertTrue(block["expired"])

    def test_the_hold_is_released_after_two_minutes(self):
        self.spend()
        self.clock.tick(121)
        self.plane.enforce(self.pool)
        self.assertNotIn("heldClone", self.call("/walkin/state", cookies=self.stranger()).json["anon"])

    def test_one_visitors_wall_does_not_touch_another(self):
        first = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger("v1")).json
        self.touch(first["clone"], "v1")
        self.clock.tick(30)
        second = self.call("/walkin/claim", "POST", {"os": "win311"}, self.stranger("v2")).json
        self.touch(second["clone"], "v2")
        self.clock.tick(30)
        self.assertEqual(len(self.plane.enforce(self.pool)), 1, "only v1 is out of time")
        self.assertEqual(self.call("/walkin/state", cookies=self.stranger("v2")).json["anon"]["remainingSeconds"], 30)


class TestConversion(AnonRouteCase):
    ACCOUNT = {"id": "w1", "role": "walkin"}

    def wall(self, vid="v1"):
        out = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger(vid)).json
        self.touch(out["clone"], vid)
        self.clock.tick(60)
        self.plane.enforce(self.pool)
        return out

    def test_registering_resumes_the_same_machine(self):
        held = self.wall()
        # After the ceremony the browser carries BOTH cookies.
        out = self.call("/walkin/claim", "POST", {}, self.stranger(), user=self.ACCOUNT).json
        self.assertEqual(out["clone"], held["clone"])
        self.assertTrue(out["resumed"])
        self.assertEqual(out["ttlSeconds"], 1200)

    def test_the_machine_is_running_again(self):
        held = self.wall()
        self.call("/walkin/claim", "POST", {}, self.stranger(), user=self.ACCOUNT)
        self.assertNotIn(held["clone"], self.pool.frozen)

    def test_an_account_that_already_holds_one_is_not_given_a_second(self):
        self.wall()
        self.pool.claim("w1", "rhapsody")
        out = self.call("/walkin/claim", "POST", {"os": "rhapsody"}, self.stranger(), user=self.ACCOUNT).json
        self.assertEqual(out["station"], "rhapsody", "their own clone, not the held one")

    def test_an_account_with_no_anonymous_past_claims_normally(self):
        out = self.call("/walkin/claim", "POST", {"os": "win311"}, user=self.ACCOUNT).json
        self.assertEqual(out["station"], "win311")
        self.assertNotIn("resumed", out)

    def test_converting_before_the_wall_keeps_the_machine_too(self):
        first = self.call("/walkin/claim", "POST", {"os": "os2warp"}, self.stranger()).json
        self.clock.tick(20)
        out = self.call("/walkin/claim", "POST", {}, self.stranger(), user=self.ACCOUNT).json
        self.assertEqual(out["clone"], first["clone"])
        self.assertEqual(out["ttlSeconds"], 1200)


class TestAdminRoutesStayLocked(WalkinCase):
    """The other half of the fence proof, at the layer that actually decides.

    `auth.routes.dispatch` resolves its caller from the SESSION COOKIE and from
    nothing else. The anonymous identity is a different cookie and a synthetic
    user that this module never sees, so opening the front door could not have
    reached these routes even in principle — and this is what says so out loud.
    """

    def call(self, path, method="GET", body=None, cookie=""):
        from . import routes as auth_routes

        jar = f"{anon.COOKIE_NAME}=v1" + (f"; {auth_routes.COOKIE_NAME}={cookie}" if cookie else "")
        handler = RecordingHandler(body=body, cookies=jar)
        handler.command = method
        svc = self.service()
        self.assertTrue(auth_routes.dispatch(handler, path, method, svc, "https://example.test"), path)
        return handler

    def test_an_anonymous_cookie_is_not_an_admin_session(self):
        handler = self.call("/auth/walkin/status")
        self.assertEqual(handler.status, 403)
        self.assertEqual(handler.json["error"], "admins only")

    def test_moving_the_switch_is_refused_to_a_stranger(self):
        # 401 rather than 403 — an anonymous cookie is not a session at all, and
        # what matters is that the switch did not move.
        handler = self.call("/auth/walkin/access", "POST", {"access": "open"})
        self.assertIn(handler.status, (401, 403))
        self.assertEqual(self.service().walkin.stored_access(), "closed")

    def test_the_command_enqueue_is_not_an_auth_route_at_all(self):
        # It is refused before any handler sees it, on every role.
        self.assertTrue(gate.is_blocked("/clientcmd/admin"))


if __name__ == "__main__":
    unittest.main()

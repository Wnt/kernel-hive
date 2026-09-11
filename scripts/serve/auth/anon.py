"""The anonymous visitor: a cookie, a 5-minute budget, and one held machine.

The funnel used to run backwards. A stranger reaching the museum was asked for a
passkey BEFORE they were allowed to touch anything, which is the wrong order for
the one thing this lab has that nothing else does: a real machine from 1994,
already running, one click away. So the order is inverted — drive first, convert
at the wall — and this module is the half of that inversion which has to be
server-authoritative, because a countdown the browser owns is a countdown the
browser can edit.

Three facts hold the design up.

  * **The budget belongs to the VISITOR, not to the session.** Five minutes of
    connected time, carried across station switches, reloads and
    back-navigation. If switching machines reset the clock, a stranger could hop
    the pool forever and never convert; trying all three has to cost the same
    budget as staying on one, and the wall says so.
  * **The clock starts when the visitor TOUCHES the machine, not when the page
    takes one.** A stranger who is still reading the headline is not spending
    anything, and a budget that began before they knew there was one is time
    they never got. `engage()` is the only thing that starts it, and the
    only thing that may call `engage()` is a real pointer press, tap or key on
    the guest (`POST /walkin/engage`, `landing/heroPolicy.ts MEANINGFUL_EVENTS`)
    — never a mouse merely crossing the picture. Once a visitor has engaged the
    fact is theirs for good, so switching stations resumes the clock at once
    rather than buying a second free look.
  * **The identity is a cookie and nothing else.** No account, no PII, no store
    row — an anonymous visitor is a random id in `osg_anon` and a record in RAM.
    Losing it (a private window, a cleared jar) buys another full budget, and
    that is an accepted cost: the alternative is fingerprinting a museum
    visitor, which this lab will not do. Rate limits and the pool's own size
    are what bound abuse, exactly as they do for signup.
  * **Exhaustion RESERVES rather than recycles.** The wall is worth crossing
    only if what is behind it is still there: the machine the visitor was just
    driving, with their work on it. So the last clone is held for two minutes
    and handed back on registration — see `holds.py` for the broker half.

The ledger is deliberately in memory. A restart of the serving unit forgets
every anonymous budget, which hands a handful of strangers a fresh minute and
loses nobody's work — the opposite trade from `auth-state.json`, where a
forgotten passkey is an account that cannot be recovered.
"""

from __future__ import annotations

import secrets
import threading
import time

#: The anonymous visitor cookie. Same conventions as the session cookie
#: (`routes.COOKIE_NAME`): HttpOnly so no script can read it, Secure because the
#: browser's view of this connection is the edge's HTTPS, SameSite=Lax so a link
#: into the museum arrives with the visitor's clock intact rather than reset.
COOKIE_NAME = "osg_anon"

#: How long a stranger may drive before the wall. Connected time, not wall
#: clock: a visitor who claims, leaves the tab and comes back an hour later
#: still has whatever they had left.
BUDGET_SECONDS = 300

#: How long a claimed machine may sit UN-ENGAGED before the pool takes it back.
#:
#: This is the price of moving the clock to first touch. The budget used to be
#: the thing that bounded a claim — sixty seconds after the page took a cell it
#: was spent, whoever was or was not there — and with the clock no longer
#: running for a visitor who has not touched anything, nothing else would ever
#: end the hold of a crawler, a preloaded link or a tab opened and forgotten.
#: Twenty-four cells, one per page load, is not a pool that survives that.
#:
#: Two minutes is chosen against the two populations it has to separate. A
#: person reading everything above the fold — headline, lede, the caption under
#: the machine, the three switcher chips — spends well under a minute doing it,
#: so this is a slow reader's whole visit plus margin before their machine is
#: ever at risk. Anything that is NOT a person never touches the guest at all,
#: and gets its cell recycled inside two minutes rather than holding it until
#: the 20-minute session TTL. It is deliberately LONGER than the browser's own
#: un-engaged release (`landing/heroPolicy.ts UNENGAGED_GRACE_MS`, 100s): the
#: page hands its own cell back first, and this is the backstop for a client
#: that will not, which is exactly the client that cannot be trusted to.
UNENGAGED_SECONDS = 120

#: How long their last machine stays reserved after the budget is spent, so
#: that registering a passkey resumes THAT machine rather than a fresh one.
#: Long enough for a passkey ceremony (Touch ID, a phone hand-off), short
#: enough that a walked-away visitor does not hold a cell hostage.
HOLD_SECONDS = 120

#: The refusal a spent visitor gets, distinct from every other walk-in code so
#: the SPA can render the conversion wall rather than a generic error
#: (`spa/src/walkin/reasons.ts`, ledger §3.3).
REASON_BUDGET = "WALKIN_ANON_BUDGET"

#: The role an anonymous caller carries. Never stored, never granted by an
#: admin, never written to `auth-state.json`: it is synthesized per request from
#: the cookie and exists only for the length of one call.
ROLE = "anon"

#: How long a record with nothing left to say is kept before it is swept. Only
#: has to outlive the hold; a spent visitor's record is what refuses their next
#: claim, so sweeping it early is what would hand them a second minute.
_FORGET_AFTER = 3600

_ID_PREFIX = "anon:"


def new_visitor_id() -> str:
    """A fresh anonymous identity. Unguessable on purpose: the id is the only
    thing standing between one stranger's budget and another's."""
    return secrets.token_urlsafe(18)


def cookie_header(visitor: str) -> str:
    """`Set-Cookie` for the anonymous identity, matching the session cookie's
    conventions (docs/PUBLIC-GALLERY.md). Secure even though this listener
    speaks plaintext — it is loopback-only behind the edge's TLS, so the
    browser's view of the connection is HTTPS."""
    return f"{COOKIE_NAME}={visitor}; Path=/; Max-Age={30 * 24 * 3600}; HttpOnly; Secure; SameSite=Lax"


def visitor_id(handler) -> str:
    """The anonymous id this request carries, or "" for a first-time caller."""
    from http.cookies import SimpleCookie

    raw = handler.headers.get("Cookie") if getattr(handler, "headers", None) else None
    if not raw:
        return ""
    try:
        jar = SimpleCookie()
        jar.load(raw)
    except Exception:  # noqa: BLE001 — a malformed jar is a visitor with no id
        return ""
    morsel = jar.get(COOKIE_NAME)
    return _clean(morsel.value) if morsel else ""


def _clean(value: str) -> str:
    """Cookies are attacker-controlled. The id is used as a dict key and as the
    tail of a broker user id, so it is constrained to what `new_visitor_id`
    actually emits rather than trusted."""
    value = (value or "").strip()
    if not value or len(value) > 64:
        return ""
    ok = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    return value if set(value) <= ok else ""


def user_for(visitor: str) -> dict:
    """The synthetic caller an anonymous visitor presents to the rest of the
    plane. It is shaped like a store user because every fence downstream reads
    `role` and `id` — and it is NOT one: nothing persists it."""
    return {"id": _ID_PREFIX + visitor, "role": ROLE, "anonId": visitor}


def is_anon(user) -> bool:
    return bool(user) and user.get("role") == ROLE


def anon_id_of(user) -> str:
    """The anonymous visitor behind this caller, whoever they are now.

    The load-bearing case is the one AFTER registration: a visitor who has just
    made a passkey is `role='walkin'` with a real account, and their anonymous
    cookie is still in the jar. That cookie is the only thing that can connect
    the account to the machine being held for them, so it is read for every
    role, not only for strangers.
    """
    if not user:
        return ""
    if is_anon(user):
        return _clean(str(user.get("id", ""))[len(_ID_PREFIX) :])
    return _clean(str(user.get("anonId", "") or ""))


class _Visit:
    """One anonymous visitor's ledger row."""

    __slots__ = (
        "spent",
        "since",
        "clone",
        "claimed_at",
        "engaged",
        "held_clone",
        "held_station",
        "held_until",
        "touched",
    )

    def __init__(self, now: float):
        # Connected seconds already banked, and the start of the interval that
        # is running right now (None when the clock is not running — which is
        # either "holds nothing" or "holds one and has not touched it yet").
        self.spent = 0.0
        self.since: float | None = None
        self.clone = ""
        # When the clone they hold was handed over, and whether this visitor
        # has ever touched a machine. `engaged` is sticky for the life of the
        # record: it is a fact about the PERSON, so a switch does not buy a
        # second un-touched grace, and the clock resumes on the next claim.
        self.claimed_at = 0.0
        self.engaged = False
        # What is being kept for them after the wall.
        self.held_clone = ""
        self.held_station = ""
        self.held_until = 0.0
        self.touched = now


class AnonBudget:
    """Every anonymous visitor's remaining seconds. Safe from any thread.

    The arithmetic is deliberately two numbers rather than a deadline: `spent`
    is banked connected time and `since` is the interval in flight. A deadline
    alone cannot survive a release — the visitor stops the clock when they hand
    a machine back, and starts it again on the next claim with what is left.

    `since` is also the answer to "is this visitor spending anything?", and
    since the clock now starts at `engage()` rather than at the claim, a held
    machine with `since is None` is the ordinary state of somebody who has just
    arrived. That state has its own bound — `claimed_at + unengaged_secs`,
    swept by `unengaged()` — because it is the only one the budget no longer
    ends by itself.
    """

    def __init__(
        self,
        budget: int = BUDGET_SECONDS,
        hold: int = HOLD_SECONDS,
        unengaged: int = UNENGAGED_SECONDS,
        now=time.time,
    ):
        self.budget = int(budget)
        self.hold_secs = int(hold)
        self.unengaged_secs = int(unengaged)
        self._now = now
        self._lock = threading.Lock()
        self._visits: dict[str, _Visit] = {}

    # ---- the clock ---------------------------------------------------------

    def remaining(self, visitor: str, now: float | None = None) -> int:
        """Seconds left, rounded DOWN so the wall never arrives a second late."""
        if not visitor:
            return self.budget
        now = self._now() if now is None else now
        with self._lock:
            visit = self._visits.get(visitor)
            return self.budget if visit is None else int(max(0, self.budget - self._used(visit, now)))

    def _used(self, visit: _Visit, now: float) -> float:
        running = max(0.0, now - visit.since) if visit.since is not None else 0.0
        return visit.spent + running

    def begin(self, visitor: str, clone: str = "", now: float | None = None) -> int:
        """Record a claim, and answer the TTL that claim should be made with.

        Called on every granted claim. A visitor who switches stations settles
        the interval they were running and opens a new one against the SAME
        remainder — which is the whole reason the clock is here and not on the
        session.

        **It does not start the clock for a visitor who has never touched a
        machine.** That is the whole engagement rule: arriving costs nothing,
        and `engage()` is what starts the minute. A visitor who HAS engaged
        before is spending from the instant they are handed the next machine —
        otherwise switching stations would be a way to hold cells for free.

        The number it returns is therefore not the budget. It is the longest
        this visit can honestly last, and it is what the session is built with:
        the remaining minute for somebody already spending it, and the
        un-engaged window PLUS that minute for somebody who has not started.
        Both bounds are enforced ahead of it — `AnonPlane.enforce` freezes at
        the wall and releases an un-engaged hold at `unengaged_secs` — so this
        TTL is the backstop under both, never the thing that ends a visit.
        """
        now = self._now() if now is None else now
        with self._lock:
            visit = self._visits.setdefault(visitor, _Visit(now))
            self._settle(visit, now)
            left = int(max(0, self.budget - visit.spent))
            visit.touched = now
            if left <= 0:
                visit.since = None
                visit.clone = ""
                visit.claimed_at = 0.0
                return 0
            visit.clone = clone
            visit.claimed_at = now
            visit.since = now if visit.engaged else None
            return self._claim_ttl(visit, left)

    def _claim_ttl(self, visit: _Visit, left: int) -> int:
        """The rule in `begin`'s docstring, in one place so `claim_ttl` cannot
        drift from what a claim was actually built with."""
        return left if visit.engaged else left + self.unengaged_secs

    def claim_ttl(self, visitor: str, now: float | None = None) -> int:
        """What `begin` would grant, without recording anything."""
        now = self._now() if now is None else now
        with self._lock:
            visit = self._visits.get(visitor)
            if visit is None:
                return self.budget + self.unengaged_secs
            left = int(max(0, self.budget - self._used(visit, now)))
            return self._claim_ttl(visit, left) if left > 0 else 0

    def engage(self, visitor: str, now: float | None = None) -> int:
        """The visitor touched the machine. Start the minute; answer what is left.

        Idempotent, and cheap enough to call on every input if a caller ever
        wants to: the second call finds the clock already running and changes
        nothing. It is the ONE writer of `engaged`, and `engaged` is what the
        un-engaged sweep reads, so a client that never sends this signal is a
        client whose cell goes back — which is the correct answer for a client
        that is not a person.

        Engaging while holding nothing is still recorded. A visitor who pressed
        a key a moment before the page handed its cell back has demonstrably
        arrived, and their next claim should start spending immediately rather
        than opening a fresh two-minute window.
        """
        now = self._now() if now is None else now
        with self._lock:
            visit = self._visits.setdefault(visitor, _Visit(now))
            visit.engaged = True
            visit.touched = now
            left = int(max(0, self.budget - self._used(visit, now)))
            if left > 0 and visit.clone and visit.since is None:
                visit.since = now
            return left

    def engaged(self, visitor: str) -> bool:
        """Has this visitor ever touched a machine? The `anon` block's own word."""
        if not visitor:
            return False
        with self._lock:
            visit = self._visits.get(visitor)
            return bool(visit and visit.engaged)

    def unengaged(self, now: float | None = None) -> list[tuple[str, str]]:
        """`(visitor, clone)` for every hold that has never been touched and is
        past its window — the cells the pool is owed back."""
        now = self._now() if now is None else now
        with self._lock:
            return [
                (vid, v.clone)
                for vid, v in self._visits.items()
                if v.clone and not v.engaged and now - v.claimed_at >= self.unengaged_secs
            ]

    def next_unengaged(self, now: float | None = None) -> float | None:
        """When the earliest un-engaged hold falls due, or None if there is none."""
        now = self._now() if now is None else now
        with self._lock:
            due = [v.claimed_at + self.unengaged_secs for v in self._visits.values() if v.clone and not v.engaged]
        return min(due) if due else None

    def settle(self, visitor: str, now: float | None = None) -> None:
        """Stop the clock — a release, a switch, or the wall. Idempotent."""
        if not visitor:
            return
        now = self._now() if now is None else now
        with self._lock:
            visit = self._visits.get(visitor)
            if visit is not None:
                self._settle(visit, now)
                visit.touched = now

    def _settle(self, visit: _Visit, now: float) -> None:
        if visit.since is not None:
            visit.spent += max(0.0, now - visit.since)
            visit.since = None
        # The claim goes with the clone: `unengaged()` sweeps holds, and a
        # visitor holding nothing has nothing for it to take. `engaged` does
        # NOT go — it is the person, not the machine.
        visit.clone = ""
        visit.claimed_at = 0.0

    def expired(self, visitor: str, now: float | None = None) -> bool:
        return bool(visitor) and self.remaining(visitor, now) <= 0

    def deadline(self, visitor: str) -> float | None:
        """When this visitor's budget runs out, or None if their clock is not
        running. The watchdog sleeps on the earliest of these, which is what
        turns a 15-second reap into a cut you can put a number on."""
        with self._lock:
            visit = self._visits.get(visitor)
            if visit is None or visit.since is None:
                return None
            return visit.since + max(0.0, self.budget - visit.spent)

    def running(self) -> list[tuple[str, str, float]]:
        """`(visitor, clone, deadline)` for every clock currently running."""
        with self._lock:
            return [
                (vid, v.clone, v.since + max(0.0, self.budget - v.spent))
                for vid, v in self._visits.items()
                if v.since is not None and v.clone
            ]

    def next_deadline(self, now: float | None = None) -> float | None:
        deadlines = [d for _, _, d in self.running()]
        return min(deadlines) if deadlines else None

    # ---- the wall, and what is kept behind it ------------------------------

    def reserve(self, visitor: str, clone: str, station: str = "", now: float | None = None) -> float:
        """The budget is spent: bank the time and hold their machine.

        Returns the instant the hold lapses. The clone itself is frozen by the
        broker (`walkin/holds.py`); what is recorded here is only WHOSE it is
        and for how long, because the thing that has to survive the visitor
        becoming an account is the association, not the machine.
        """
        now = self._now() if now is None else now
        with self._lock:
            visit = self._visits.setdefault(visitor, _Visit(now))
            self._settle(visit, now)
            visit.spent = max(visit.spent, float(self.budget))
            visit.held_clone = clone
            visit.held_station = station
            visit.held_until = now + self.hold_secs
            visit.touched = now
            return visit.held_until

    def held(self, visitor: str, now: float | None = None) -> dict:
        """`{clone, station, secondsLeft}` for a live hold, or `{}`."""
        if not visitor:
            return {}
        now = self._now() if now is None else now
        with self._lock:
            visit = self._visits.get(visitor)
            if visit is None or not visit.held_clone or now >= visit.held_until:
                return {}
            return {
                "clone": visit.held_clone,
                "station": visit.held_station,
                "secondsLeft": int(max(0, visit.held_until - now)),
            }

    def drop_hold(self, visitor: str) -> None:
        with self._lock:
            visit = self._visits.get(visitor)
            if visit is not None:
                visit.held_clone = visit.held_station = ""
                visit.held_until = 0.0

    def lapsed_holds(self, now: float | None = None) -> list[str]:
        """Visitors whose hold has run out — their machine may go back."""
        now = self._now() if now is None else now
        with self._lock:
            return [v for v, r in self._visits.items() if r.held_clone and now >= r.held_until]

    # ---- what the SPA is told ----------------------------------------------

    def block(self, visitor: str, now: float | None = None) -> dict:
        """The `anon` block of `GET /walkin/state` (LANDING-REDESIGN-CONTRACT).

        The client countdown MIRRORS this; it is never the source of truth.
        """
        now = self._now() if now is None else now
        left = self.remaining(visitor, now)
        out = {
            "budgetSeconds": self.budget,
            "remainingSeconds": left,
            "expired": left <= 0,
            # Whether the minute has STARTED. The page needs this to know
            # whether to tick its mirror down or hold it at the full budget and
            # say the minute starts on first touch — and it has to come from here,
            # because the server is the authority on the clock and the client
            # would otherwise be guessing from its own input handlers.
            "engaged": self.engaged(visitor),
        }
        hold = self.held(visitor, now)
        if hold:
            out["heldClone"] = hold["clone"]
            out["heldSeconds"] = hold["secondsLeft"]
        return out

    # ---- housekeeping ------------------------------------------------------

    def forget(self, visitor: str) -> None:
        with self._lock:
            self._visits.pop(visitor, None)

    def drop_all(self) -> int:
        """The operator dropped the switch to Closed. An anonymous visitor has
        no session row to delete and no cookie we can reach into, so their
        budget record IS their session — clearing it is what stops a stranger
        from surviving the kill switch that just took every walk-in down."""
        with self._lock:
            # A visitor holding a cell counts whether or not their clock is
            # running: since the minute starts at first touch, "claimed but not
            # yet touched" is the ordinary state of somebody who is on the page
            # right now, and the kill switch is exactly what has to reach them.
            count = sum(1 for v in self._visits.values() if v.since is not None or v.clone or v.held_clone)
            self._visits.clear()
            return count

    def sweep(self, now: float | None = None) -> int:
        """Forget records that can no longer refuse or resume anything."""
        now = self._now() if now is None else now
        with self._lock:
            stale = [
                v
                for v, r in self._visits.items()
                if r.since is None and not r.clone and not r.held_clone and now - r.touched > _FORGET_AFTER
            ]
            for visitor in stale:
                del self._visits[visitor]
            return len(stale)

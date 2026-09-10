"""The anonymous visitor: a cookie, a 60-second budget, and one held machine.

The funnel used to run backwards. A stranger reaching the museum was asked for a
passkey BEFORE they were allowed to touch anything, which is the wrong order for
the one thing this lab has that nothing else does: a real machine from 1994,
already running, one click away. So the order is inverted — drive first, convert
at the wall — and this module is the half of that inversion which has to be
server-authoritative, because a countdown the browser owns is a countdown the
browser can edit.

Three facts hold the design up.

  * **The budget belongs to the VISITOR, not to the session.** Sixty seconds of
    connected time, carried across station switches, reloads and
    back-navigation. If switching machines reset the clock, a stranger could hop
    the pool forever and never convert; trying all three has to cost the same
    minute as staying on one, and the wall says so.
  * **The identity is a cookie and nothing else.** No account, no PII, no store
    row — an anonymous visitor is a random id in `osg_anon` and a record in RAM.
    Losing it (a private window, a cleared jar) buys another minute, and that is
    an accepted cost: the alternative is fingerprinting a museum visitor, which
    this lab will not do. Rate limits and the pool's own size are what bound
    abuse, exactly as they do for signup.
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
BUDGET_SECONDS = 60

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

    __slots__ = ("spent", "since", "clone", "held_clone", "held_station", "held_until", "touched")

    def __init__(self, now: float):
        # Connected seconds already banked, and the start of the interval that
        # is running right now (None when they hold nothing).
        self.spent = 0.0
        self.since: float | None = None
        self.clone = ""
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
    """

    def __init__(self, budget: int = BUDGET_SECONDS, hold: int = HOLD_SECONDS, now=time.time):
        self.budget = int(budget)
        self.hold_secs = int(hold)
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
        """Start (or continue) burning budget, and answer what was granted.

        Called on every granted claim. A visitor who switches stations settles
        the interval they were running and opens a new one against the SAME
        remainder — which is the whole reason the clock is here and not on the
        session.
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
                return 0
            visit.since = now
            visit.clone = clone
            return left

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
        visit.clone = ""

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
        out = {"budgetSeconds": self.budget, "remainingSeconds": left, "expired": left <= 0}
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
            count = sum(1 for v in self._visits.values() if v.since is not None or v.held_clone)
            self._visits.clear()
            return count

    def sweep(self, now: float | None = None) -> int:
        """Forget records that can no longer refuse or resume anything."""
        now = self._now() if now is None else now
        with self._lock:
            stale = [
                v
                for v, r in self._visits.items()
                if r.since is None and not r.held_clone and now - r.touched > _FORGET_AFTER
            ]
            for visitor in stale:
                del self._visits[visitor]
            return len(stale)

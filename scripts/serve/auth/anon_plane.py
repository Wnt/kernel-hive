"""The seam between an anonymous visitor and the pool.

`scripts/serve/walkin/` deliberately knows nothing about roles: `broker.claim`
takes a user id string and a station, and that separation is worth keeping. So
the walk-in routes are handed ONE duck-typed object — this — exactly the way
they are handed the broker (ledger §3.1), and every question they need to ask
about a stranger goes through it:

    ttl_for(user)          -> float | None   how long this caller may hold a clone
    refuse(user)           -> str            "" or WALKIN_ANON_BUDGET
    grant(user, station)   -> float | None   record the claim; the TTL to claim with
    granted(user, body)    -> None           a clone was handed over
    engage(user)           -> dict | None    the visitor TOUCHED it; the clock starts
    stopped(user)          -> None           the clock stops (release, queue, failure)
    adopt(broker, user)    -> dict | None    reattach the machine held for a new account
    block(user)            -> dict | None    the `anon` doc for GET /walkin/state
    cookie(user)           -> str            a Set-Cookie, once, for a new visitor

Two orderings in here are load-bearing and neither is obvious.

**The clock starts at the visitor's FIRST TOUCH, not at the claim.** A minute
that began while a stranger was still reading the headline is a minute they
never had, so `grant()` only records the claim and `engage()` — the one verb
`POST /walkin/engage` calls, and only for a real press, tap or key on the guest
— is what sets it running. Everything below about ordering still holds, because
a visitor who HAS engaged starts spending the moment they are handed their next
machine; for one who has not, there is no deadline to race yet.

The cost of that move is that the budget no longer bounds a claim, so
`enforce()` gained a second job: releasing a hold nobody ever touched
(`anon.UNENGAGED_SECONDS`). Without it a crawler holds one of twenty-four cells
until the 20-minute session TTL, which is the pool gone.

**The clock starts BEFORE the claim, not after.** `broker._claim` stamps
`expires_at` under its lock and only then resumes the guest, which can take
seconds. If the ledger started counting when the HTTP handler got its answer,
the ledger's deadline would land AFTER the session's, the watchdog would never
freeze the visitor in time, and `Broker.tick()` would DESTROY the clone that was
supposed to be held for them — the conversion wall would open onto nothing. So
`grant()` runs first and its number is what the claim is made with. The ledger's
deadline is then never LATER than the session's: both are `start + granted`, and
the ledger's start is the earlier of the two reads of the clock. Landing on the
same instant is fine, because the watchdog runs `enforce()` before `tick()`
(`walkin_plane._watchdog`) — the freeze is always applied first.

**The wall is driven by a deadline, not by a poll.** `enforce()` is called by
the walk-in watchdog, which sleeps until the earliest budget runs out rather
than on the flat 15-second tick — see `walkin_plane._watchdog`. A minute
enforced by a quarter-minute tick is a minute plus up to fifteen seconds, which
on a sixty-second budget is a quarter of the feature given away.
"""

from __future__ import annotations

import sys
import time

# Server-side feature reach (serve/probes.py). Two names for one module, and a
# no-op last resort — see the identical block in auth/gate.py.
try:
    from probes import hit
except ImportError:  # pragma: no cover - import shape only
    try:
        from serve.probes import hit
    except ImportError:

        def hit(_probe: str) -> None:
            """No probes module in this deployment; the budget still works."""


from . import anon
from .anon import REASON_BUDGET, AnonBudget  # noqa: F401 -- re-exported for the routes


class AnonPlane:
    """The budget, bound to the broker-facing verbs the walk-in routes call."""

    def __init__(self, budget: AnonBudget | None = None, tickets=None, walkin_ttl: float | None = None, now=time.time):
        self.budget = budget if budget is not None else AnonBudget(now=now)
        # The revocable walk-in ticket registry. Bookkeeping rather than a
        # second gate — nothing consults `is_live` today — but a frozen clone
        # must not still be listed as holding a live ticket by
        # `check-stream-tickets.py`.
        self.tickets = tickets
        self._walkin_ttl = walkin_ttl
        self._now = now

    def bind_tickets(self, tickets) -> None:
        self.tickets = tickets

    @property
    def walkin_ttl(self) -> float:
        """The ordinary walk-in session length a promoted visitor inherits.
        Read from the broker package late so this module carries no copy of a
        number another lane owns."""
        if self._walkin_ttl is not None:
            return float(self._walkin_ttl)
        try:
            from walkin.session import TTL_SECONDS
        except ImportError:  # pragma: no cover - import shape only
            from serve.walkin.session import TTL_SECONDS
        return float(TTL_SECONDS)

    # ---- resolving the caller ---------------------------------------------

    def visitor(self, handler, user: dict | None) -> dict | None:
        """Who this request is, once anonymity is a legitimate answer.

        A signed-in caller keeps their own identity and merely carries their
        anonymous cookie along (`anonId`) — that cookie is the only thread
        connecting the account they have just made to the machine being held for
        them. A caller with no session becomes a synthetic `role='anon'` user,
        minting an id if the jar had none.
        """
        vid = anon.visitor_id(handler)
        if user:
            return {**user, "anonId": vid} if vid else user
        fresh = not vid
        if fresh:
            vid = anon.new_visitor_id()
        out = anon.user_for(vid)
        if fresh:
            # The reply that carries this user is the one that plants the
            # cookie; `cookie()` below reads the flag back.
            out["anonFresh"] = True
        return out

    def cookie(self, user) -> str:
        return anon.cookie_header(anon.anon_id_of(user)) if user and user.get("anonFresh") else ""

    # ---- the budget, as the routes see it ----------------------------------

    def ttl_for(self, user) -> float | None:
        """None means "no cap" — an ordinary walk-in keeps the 1200s TTL."""
        if not anon.is_anon(user):
            return None
        return float(self.budget.claim_ttl(anon.anon_id_of(user), self._now()))

    def refuse(self, user) -> str:
        """The reason to turn this caller away, or "". Only ever the budget:
        the access switch, drain and the pool's own limits are decided
        upstream and downstream of here, unchanged."""
        if not anon.is_anon(user):
            return ""
        return REASON_BUDGET if self.budget.expired(anon.anon_id_of(user)) else ""

    def grant(self, user, station: str = "") -> float | None:
        """Record the claim and answer the TTL it should be made with.

        For a visitor already spending, that is their remaining minute, exactly
        as before. For one who has not touched a machine yet it is the
        un-engaged window on top of it — the longest this visit can last —
        because their minute has not started and nothing else would bound the
        hold (`anon.begin`).
        """
        if not anon.is_anon(user):
            return None
        return float(self.budget.begin(anon.anon_id_of(user), now=self._now()))

    def engage(self, broker, user) -> dict | None:
        """The visitor touched the machine: start their minute, and say so.

        Two things move, and the second is what keeps the contract's promise
        that a browser cannot outlive the budget by holding a socket open. The
        clock starts; and the session, which was built long enough to survive
        an un-touched visit, is cut back to the minute that is now running
        (`walkin/holds.py retime`). From here the ledger's deadline and the
        session's are the same instant, which is the ordering this module's
        header requires — `enforce()` runs before `tick()`, so the freeze
        always lands first.

        Answers the fresh `anon` block rather than nothing, so the page that
        reports the first press learns its own remaining seconds in that reply
        instead of waiting up to a poll interval to find out whether the clock
        it has started is the clock the server is keeping.
        """
        if not anon.is_anon(user):
            return None
        vid = anon.anon_id_of(user)
        left = self.budget.engage(vid, self._now())
        hit("walkin.anon.engaged")
        own = None
        try:
            own = broker.own_of(str(user.get("id", ""))) or {}
            clone = str(own.get("clone", "") or "")
            if clone:
                broker.retime(str(user.get("id", "")), clone, left)
        except Exception as exc:  # noqa: BLE001 — the clock started; the TTL is a backstop
            sys.stderr.write(f"[auth] could not retime {own or vid} at first touch: {type(exc).__name__}: {exc}\n")
        return self.budget.block(vid, self._now())

    def granted(self, user, body: dict) -> None:
        """A claim came back. A queue position is not a machine, so the clock
        stops again; a granted clone is recorded so the watchdog knows which
        machine to freeze when the minute runs out."""
        if not anon.is_anon(user):
            return
        vid = anon.anon_id_of(user)
        clone = str((body or {}).get("clone", "") or "")
        if not clone:
            self.budget.settle(vid, self._now())
            return
        self.budget.begin(vid, clone, now=self._now())

    def stopped(self, user) -> None:
        """The visitor let go — a release, a switch, or a claim that failed."""
        if anon.is_anon(user):
            self.budget.settle(anon.anon_id_of(user), self._now())

    def block(self, user) -> dict | None:
        """The `anon` block of `GET /walkin/state`, or None for a caller the
        contract says must not see one (anyone with a real account)."""
        if not anon.is_anon(user):
            return None
        return self.budget.block(anon.anon_id_of(user), self._now())

    # ---- crossing the wall -------------------------------------------------

    def adopt(self, broker, user) -> dict | None:
        """Give a freshly registered visitor their own machine back.

        Called on a claim from an account (`role='walkin'`) that is carrying an
        anonymous cookie. Deliberately indifferent to which `os` was asked for:
        the visitor just made a passkey while looking at a specific screen, and
        handing them that screen is the entire reason the hold exists. If they
        want a different machine, release and claim — which cleans up properly.
        """
        if not user or anon.is_anon(user):
            return None
        vid = anon.anon_id_of(user)
        if not vid:
            return None
        user_id = str(user.get("id", ""))
        try:
            if broker.own_of(user_id):
                # The account already holds a clone; reattaching a second one
                # would break "one clone per account" (brief §4).
                return None
            body = broker.reassign(anon.user_for(vid)["id"], user_id, self.walkin_ttl)
        except Exception as exc:  # noqa: BLE001 — a broken hold must not 500 a claim
            sys.stderr.write(f"[auth] anon hand-off failed for a new account: {type(exc).__name__}: {exc}\n")
            return None
        if body is None:
            return None
        hit("walkin.anon.converted")
        self.budget.drop_hold(vid)
        self.budget.settle(vid, self._now())
        return body

    # ---- the watchdog's pass ----------------------------------------------

    def enforce(self, broker) -> list[str]:
        """Freeze every stranger whose minute is up. Returns what it froze.

        This is the enforcement, and it is worth being precise about what does
        the work. Stopping the guest's vCPUs is what makes an already-open
        WebTransport session useless — streamhost verifies a ticket once, at
        `req.accept()`, and never again — and `Holding.ticket_ttl_for` going to
        zero is what stops a NEW session being opened in its place.
        """
        now = self._now()
        frozen: list[str] = []
        for vid, clone, deadline in self.budget.running():
            if now < deadline:
                continue
            uid = anon.user_for(vid)["id"]
            station = ""
            try:
                own = broker.own_of(uid) or {}
                station = str(own.get("station", "") or "")
                identity = broker.freeze(uid, self.budget.hold_secs)
            except Exception as exc:  # noqa: BLE001 — a watchdog that dies stops enforcing
                sys.stderr.write(f"[auth] could not freeze {clone or uid} at the wall: {type(exc).__name__}: {exc}\n")
                identity = ""
            # Banked either way: a visitor whose machine could not be frozen has
            # still spent their minute, and must not be handed another one.
            self.budget.reserve(vid, identity, station, now)
            if identity:
                hit("walkin.anon.wall")
                frozen.append(identity)
                if self.tickets is not None:
                    self.tickets.revoke_clone(identity)
        for vid, clone in self.budget.unengaged(now):
            # NOT a freeze and NOT a reserve: nothing happened on this machine,
            # so there is no work to keep and no wall to put in front of it.
            # The cell goes back to the pool and the visitor keeps their whole
            # minute — if they turn out to be there after all, the page asks
            # for the SAME station again (landing/heroSession.ts resumeTarget)
            # and they get a fresh copy of it, which is the honest answer.
            try:
                broker.release(anon.user_for(vid)["id"], clone)
                hit("walkin.anon.unengaged")
            except Exception as exc:  # noqa: BLE001 — a stuck cell must not stop the pass
                sys.stderr.write(f"[auth] could not release un-engaged {clone}: {type(exc).__name__}: {exc}\n")
            self.budget.settle(vid, now)
        for vid in self.budget.lapsed_holds(now):
            # The broker's own TTL destroys the clone; all this forgets is the
            # association, so a later claim does not chase a machine that is gone.
            self.budget.drop_hold(vid)
        self.budget.sweep(now)
        return frozen

    def next_deadline(self) -> float | None:
        """The earliest instant `enforce` will have work to do.

        Both of its jobs count: a minute running out and an un-engaged hold
        falling due. The walk-in watchdog sleeps on this number, so a deadline
        left out of it is a deadline enforced up to a flat fifteen-second tick
        late — which for the wall would be a quarter of the budget given away,
        and for the pool a cell held past the window that exists to recycle it.
        """
        now = self._now()
        due = [d for d in (self.budget.next_deadline(now), self.budget.next_unengaged(now)) if d is not None]
        return min(due) if due else None

    def drop_all(self) -> int:
        """The switch went to Closed. See `AnonBudget.drop_all`."""
        return self.budget.drop_all()

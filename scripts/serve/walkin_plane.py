"""Wiring the walk-in plane into the serving process — the seams no lane owned.

The pool (`scripts/serve/walkin/`), the role fence and the switch
(`scripts/serve/auth/`) were each built to a frozen contract
([`CONTRACT-LEDGER.md`](../../docs/lab/walkin/CONTRACT-LEDGER.md) §3) and
deliberately left unconnected: neither lane may write in the other's tree, and
the connecting code lives in neither. This module is that connection, and
nothing else — no policy of its own.

Three things it holds that the server should not have to know:

  * **The pool's lifetime.** It is started once, bound to the auth plane
    (`bind_broker`) and to the signaling path (`signal_route.bind_walkin`), and
    watched by the one thread that calls `tick()`. Nothing else does, so that
    thread is what makes a TTL a TTL.
  * **The API, by exact path.** `walkin.routes.dispatch` claims the whole
    `/walkin/` prefix, but `/walkin`, `/walkin/play/<os>` and `/walkin/exhibits`
    are CLIENT-side routes that must fall through to the SPA index — PREFLIGHT
    §B4 warns against reserving the prefix for exactly this reason: it would 404
    the visitor's own landing page. The set of API paths is READ FROM
    `walkin.routes.PATHS` and is not restated here; see the comment on `API`
    for the day that distinction cost.
  * **Whose clone is whose.** A walk-in's one interactive surface is their own
    clone's signaling document, so the fence has to be told which one that is.

A missing broker is tolerated everywhere (ledger §3.1) and a broken one must
never take the LAN gallery down with it: this plane is an addition to the
museum, not a dependency of it.
"""

from __future__ import annotations

import sys
import threading
import time

import signal_route
from auth import routes as auth_routes
from config import WALKIN_REGISTRY, WALKIN_REPO, WALKIN_TICK_SECS
from walkin import Broker
from walkin import routes as walkin_routes

# The pool, or None on a box with no walk-in registry.
BROKER = None
# The broker's routes, TAKEN FROM the module that answers them — never a second
# copy. This was a hand-kept tuple of four until 2026-09-11, when `/walkin/engage`
# landed with a handler and a gate entry and no line here, and 404ed on the live
# box for every visitor. A list that must agree with another list eventually
# does not; this one cannot disagree, because there is only one.
# Everything else under /walkin/ is the SPA's.
API = walkin_routes.PATHS


def start(auth):
    """Wire the pool to the two planes that need it — WITHOUT doing any of its
    slow work on this thread.

    Everything expensive happens in the watchdog: constructing the Broker reaps
    the clones a previous incarnation left behind (nine QEMUs and their network
    cells), and warming builds nine TCG restores. `main()` binds the LAN listener
    only AFTER this returns, so anything slow here is the WHOLE MUSEUM refusing
    connections on :8443 — which is what happened on 2026-08-26 when poolSize
    went from 1 to 3 and a few seconds of reaping became minutes.

    Failure is NOT fatal either way: a bad registry must not stop the museum
    from serving. It is loud, and the plane is absent.
    """
    if auth is None:
        return None  # no public listener, no visitors, no pool
    if not WALKIN_REGISTRY.is_dir():
        sys.stderr.write(f"[serve] walk-in: no registry at {WALKIN_REGISTRY} — pool disabled\n")
        return None
    threading.Thread(target=_bring_up, args=(auth,), daemon=True, name="walkin-watchdog").start()
    sys.stderr.write(f"[serve] walk-in plane: bringing up in the background, registry={WALKIN_REGISTRY}\n")
    return None


def _bring_up(auth):
    """Construct, wire, warm, then tick forever. Off the startup path."""
    global BROKER
    try:
        BROKER = Broker(WALKIN_REGISTRY, WALKIN_REPO)
    except Exception as exc:  # noqa: BLE001 — reported, never fatal
        sys.stderr.write(f"[serve] walk-in: broker NOT started ({type(exc).__name__}: {exc})\n")
        return
    auth.walkin.bind_broker(BROKER)
    signal_route.bind_walkin(BROKER, auth.walkin_tickets)
    # The anonymous plane revokes a frozen clone's outstanding ticket, so it
    # needs the same registry the switch's teardown uses. Bound here rather than
    # at construction because `AuthService` builds both and neither may depend
    # on the other's order.
    #
    # Tolerated when absent, like the broker itself (ledger §3.1): this file is
    # a box-sync PAIR and `auth/` ships wholesale from a different script, so a
    # half-deploy can put a new walkin_plane.py in front of an auth package that
    # has never heard of the anonymous budget. Raising here would kill the
    # watchdog thread — and with it every TTL, every reap and the whole pool —
    # over a feature that simply is not installed yet.
    if getattr(auth, "anon", None) is not None:
        auth.anon.bind_tickets(auth.walkin_tickets)
    else:
        sys.stderr.write("[serve] walk-in: no anonymous plane in this auth package — strangers are not served\n")
    # The switch survives a restart (it is in auth-state.json); the pool does
    # not. Restore both from the stored position, so a restart at Invited comes
    # back with a WARM pool rather than one that only fills after the next admin
    # click — a visitor who waits for a boot is the thing the pool exists to
    # prevent.
    BROKER.access = auth.walkin.access()
    BROKER.set_drain(auth.walkin.draining())
    sys.stderr.write(
        f"[serve] walk-in plane: access={BROKER.access} floor={auth.walkin.env_floor} "
        f"pools={BROKER.pools()} registry={WALKIN_REGISTRY}\n"
    )
    _watchdog(auth)


def _watchdog(auth):
    """Expire, reap, refill — forever. Nothing else calls tick(), and nothing
    else warms the pool: the call below is the cold start.

    `refill()` returns as soon as the intent is recorded and warms on its own
    thread, so this loop starts ticking — expiring, reaping — while the pool is
    still filling. `tick()`'s own refill finds the build already in progress and
    does not queue behind it.

    **It sleeps to the next DEADLINE, not to a flat tick**, and that is the
    difference between a sixty-second budget and a sixty-to-seventy-five-second
    one. `WALKIN_TICK_SECS` is 15: a twenty-minute walk-in TTL does not care, but
    a stranger's minute enforced on that grid gives away a quarter of itself. So
    the sleep is `min(tick, whatever is due soonest)` and the anonymous wall
    lands within one pass of the instant it is owed.

    The order inside the loop matters as much as the sleep. `enforce` runs
    FIRST: it freezes an expired stranger's machine and pushes the session's own
    expiry out to the end of the hold, so the `tick()` immediately behind it
    finds nothing to reap. Reversed, `tick()` would destroy the very clone the
    conversion wall was about to offer back.
    """
    if BROKER is not None and BROKER.access != "closed":
        try:
            BROKER.refill()
        except Exception as exc:  # noqa: BLE001 — reported, never fatal
            sys.stderr.write(
                f"[serve] walk-in: pool did not warm ({type(exc).__name__}: {exc}) — "
                "the plane is up and empty; the next tick retries\n"
            )
    while True:
        time.sleep(_sleep_secs(auth))
        try:
            auth.anon.enforce(BROKER)
        except Exception as exc:  # noqa: BLE001 — the wall must not stop the reaper
            sys.stderr.write(f"[serve] walk-in anon wall: {type(exc).__name__}: {exc}\n")
        try:
            BROKER.tick()
        except Exception as exc:  # noqa: BLE001 — a watchdog that dies stops reaping
            sys.stderr.write(f"[serve] walk-in watchdog: {type(exc).__name__}: {exc}\n")


#: Never spin: the floor a computed sleep is clamped to.
_MIN_SLEEP = 0.25


def _sleep_secs(auth) -> float:
    """How long until the loop has work, capped at the ordinary tick.

    Two clocks can be due: an anonymous budget running out (the wall) and a
    session expiring (the reap, including the end of a 120-second hold). The
    earlier of the two wins; with neither running this is exactly the flat tick
    the loop has always used.
    """
    due = []
    try:
        deadline = auth.anon.next_deadline()
        if deadline is not None:
            due.append(deadline)
    except Exception:  # noqa: BLE001 — a broken clock must not stop the loop
        pass
    try:
        if BROKER is not None:
            expiry = BROKER.next_expiry()
            if expiry is not None:
                due.append(expiry)
    except Exception:  # noqa: BLE001 — ditto
        pass
    if not due:
        return WALKIN_TICK_SECS
    return max(_MIN_SLEEP, min(float(WALKIN_TICK_SECS), min(due) - time.time()))


def own_for(user) -> dict | None:
    """The clone this session holds — `station`, `clone`, `signalEndpoint`."""
    if BROKER is None or not user:
        return None
    try:
        return BROKER.own_of(str(user.get("id", "")))
    except Exception as exc:  # noqa: BLE001 — a broken pool must not 500 the gate
        sys.stderr.write(f"[serve] walk-in own_of failed: {type(exc).__name__}: {exc}\n")
        return None


def own_signal(user) -> str | None:
    """The one signaling document a walk-in — or a stranger — may read, for
    `gate.allows`. Both roles get exactly one interactive surface and it is
    the same surface: the clone they are holding right now."""
    if not user or user.get("role") not in ("walkin", "anon"):
        return None
    own = own_for(user)
    return own["signalEndpoint"] if own else None


def visitor_for(auth, handler, user):
    """Who this request is, once "nobody yet" is a legitimate answer.

    A signed-in caller comes back unchanged except for the anonymous cookie
    carried alongside them; a caller with no session becomes a synthetic
    `role='anon'` user. Kept HERE rather than in the gate because it is wiring —
    a cookie read and a dict — and because the server and this module's own
    dispatch must not answer the question two different ways.
    """
    plane = getattr(auth, "anon", None) if auth is not None else None
    return plane.visitor(handler, user) if plane is not None else user


def dispatch(handler, path: str, method: str, auth, origin: str) -> bool:
    """The walk-in plane in two halves: WHO may see what (auth's — signup and
    the manifest projection), then the clones themselves (the broker's).

    Public listener only: the LAN listener has no sessions to decide anything
    with, and no visitor on it.
    """
    if auth is None or not path.startswith(walkin_routes.PREFIX):
        return False
    user = visitor_for(auth, handler, auth.user_for_token(auth_routes.session_token(handler)))
    if auth_routes.dispatch_walkin(handler, path, method, auth, origin, own_for(user)):
        return True
    if BROKER is None or path not in API:
        return False
    # The effective switch position FOR THIS CALLER. `invited` means the plane
    # is reachable by invited accounts only, so a walk-in account still holding
    # a cookie from an Open window is told what a stranger is told when the
    # switch is Closed — which is exactly what it is, for them.
    #
    # A STRANGER IS GATED BY THE SAME SWITCH, and `is_open_to` already does it:
    # `open` admits everyone, `invited` admits only admin/viewer — which is the
    # position where a walk-in account is locked out too — and `closed` admits
    # nobody. The anonymous role needed no exception, and must never get one:
    # a class of visitor that survives the operator's kill switch is exactly
    # what the switch exists to make impossible.
    access = auth.walkin.access()
    if method != "GET" and not auth.walkin.is_open_to(user):
        access = "closed"
    return walkin_routes.dispatch(handler, path, method, BROKER, user, access, getattr(auth, "anon", None))

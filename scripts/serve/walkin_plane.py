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
    the visitor's own landing page.
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
# The broker's four routes. Everything else under /walkin/ is the SPA's.
API = ("/walkin/state", "/walkin/claim", "/walkin/release", "/walkin/reset")


def start(auth):
    """Bring the pool up and wire it to the two planes that need it.

    Failure here is NOT fatal, unlike the public listener's: a bad registry file
    must not stop the museum from serving. It is loud, and the plane is absent.
    """
    global BROKER
    if auth is None:
        return None  # no public listener, no visitors, no pool
    if not WALKIN_REGISTRY.is_dir():
        sys.stderr.write(f"[serve] walk-in: no registry at {WALKIN_REGISTRY} — pool disabled\n")
        return None
    try:
        BROKER = Broker(WALKIN_REGISTRY, WALKIN_REPO)
    except Exception as exc:  # noqa: BLE001 — reported, never fatal
        sys.stderr.write(f"[serve] walk-in: broker NOT started ({type(exc).__name__}: {exc})\n")
        return None
    auth.walkin.bind_broker(BROKER)
    signal_route.bind_walkin(BROKER, auth.walkin_tickets)
    # The switch survives a restart (it is in auth-state.json); the pool does
    # not. Restore both from the stored position, so a restart at Invited comes
    # back with a WARM pool rather than one that only fills after the next admin
    # click — a visitor who waits for a boot is the thing the pool exists to
    # prevent.
    BROKER.access = auth.walkin.access()
    BROKER.set_drain(auth.walkin.draining())
    if BROKER.access != "closed":
        # Warming is best-effort and MUST NOT be fatal. A clone that cannot be
        # built — an undeployed tap script, a missing seed, a full slot range —
        # is a walk-in outage; an exception here is a MUSEUM outage, because
        # this runs inside the process that serves the whole gallery. On
        # 2026-08-25 an undeployed wi-tapnet.sh took the gallery down exactly
        # this way, three lines below a docstring promising it could not.
        try:
            BROKER.refill()
        except Exception as exc:  # noqa: BLE001 — reported, never fatal
            sys.stderr.write(
                f"[serve] walk-in: pool did not warm ({type(exc).__name__}: {exc}) — "
                "the plane is up and empty; the watchdog will retry\n"
            )
    threading.Thread(target=_watchdog, daemon=True, name="walkin-watchdog").start()
    sys.stderr.write(
        f"[serve] walk-in plane: access={BROKER.access} floor={auth.walkin.env_floor} "
        f"pools={BROKER.pools()} registry={WALKIN_REGISTRY}\n"
    )
    return BROKER


def _watchdog():
    """Expire, reap, refill — forever. Nothing else calls tick()."""
    while True:
        time.sleep(WALKIN_TICK_SECS)
        try:
            BROKER.tick()
        except Exception as exc:  # noqa: BLE001 — a watchdog that dies stops reaping
            sys.stderr.write(f"[serve] walk-in watchdog: {type(exc).__name__}: {exc}\n")


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
    """The one signaling document a walk-in may read, for `gate.allows`."""
    if not user or user.get("role") != "walkin":
        return None
    own = own_for(user)
    return own["signalEndpoint"] if own else None


def dispatch(handler, path: str, method: str, auth, origin: str) -> bool:
    """The walk-in plane in two halves: WHO may see what (auth's — signup and
    the manifest projection), then the clones themselves (the broker's).

    Public listener only: the LAN listener has no sessions to decide anything
    with, and no visitor on it.
    """
    if auth is None or not path.startswith(walkin_routes.PREFIX):
        return False
    user = auth.user_for_token(auth_routes.session_token(handler))
    if auth_routes.dispatch_walkin(handler, path, method, auth, origin, own_for(user)):
        return True
    if BROKER is None or path not in API:
        return False
    # The effective switch position FOR THIS CALLER. `invited` means the plane
    # is reachable by invited accounts only, so a walk-in account still holding
    # a cookie from an Open window is told what a stranger is told when the
    # switch is Closed — which is exactly what it is, for them.
    access = auth.walkin.access()
    if method != "GET" and not auth.walkin.is_open_to(user):
        access = "closed"
    return walkin_routes.dispatch(handler, path, method, BROKER, user, access)

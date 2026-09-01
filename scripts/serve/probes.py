"""Server-side feature reach: which BRANCHES of the serving plane are alive.

WHAT THIS IS NOT. It is not a request counter. journald and the access log
already say how much traffic a route gets, and a fourth place to read the same
number would be worse than none. The question here is the one no log answers:
of the branches INSIDE a route, which have ever been taken? A refusal that has
never fired, a fallback that has never been reached, a reap reason that has
never been the reason — those are the rows worth having, and they are all rows
that read ZERO. You cannot count code that did not run, so the instrumented set
is DECLARED below and the report is a LEFT JOIN onto it, exactly as the SPA's
catalogue works (spa/src/analytics/catalogue.ts).

THE CALL-SITE GATE IS THE LOAD-BEARING HALF. `scripts/analytics/catalogue.mjs
check` fails if a probe declared here has no call site in the file it names as
`owner`. Without it a zero has two meanings that look identical and are
opposite — "this branch is dead" and "I declared a probe and never called it" —
and the second kind is what gets working code deleted.

THREE PROPERTIES THE REQUEST PATH DEPENDS ON, and all three are why this module
imports nothing but the standard library and knows nothing about SQLite:

  1. `hit()` NEVER RAISES. It is called from inside `except` handlers, from the
     walk-in watchdog, and from the auth fence that stands in front of every
     gated request. A probe that can raise is a probe that turns an observation
     into an outage. The body is wrapped, and `test_probes.py` proves it against
     a store that raises on every call.
  2. `hit()` NEVER WRITES TO DISK. It folds into an in-memory dict. The dict is
     bounded by the CATALOGUE, not by traffic: an undeclared id is dropped, so
     twelve keys is the whole memory cost however many requests arrive.
  3. The flush is THROTTLED and lazy. There is no thread and no timer — the
     first `hit()` after FLUSH_SECS have passed folds the accumulated counts
     into the store, so the write amortises to at most one small SQLite commit a
     minute regardless of load, and a box with no traffic does no work at all.

NO IDENTITIES, SAME AS THE CLIENT PLANE. A probe id and a count. There is no
field for a path, a station, a user or an address, which is what keeps the
aggregate safe to keep for two years beside the client's.

WHY class='server' RATHER THAN A SECOND TABLE: see docs/ANALYTICS.md §7.
"""

from __future__ import annotations

import sys
import threading
import time

#: How long counts may sit in memory before a flush folds them in. One minute
#: is chosen against the failure it bounds: a serving-plane restart loses at
#: most a minute of branch counts, and this plane's question is asked across
#: seasons.
FLUSH_SECS = 60.0


class ServerProbe:
    """One declared branch. `what` finishes 'this fired, therefore we know…'."""

    __slots__ = ("area", "owner", "what", "consumes")

    def __init__(self, area: str, owner: str, what: str, consumes: str = ""):
        self.area = area
        self.owner = owner
        self.what = what
        #: The probe whose reach this one is a fraction of. Same idea as the
        #: SPA catalogue's `consumes`: the PAIR is where the insight lives,
        #: because a fallback's zero only means something beside the count of
        #: times its precondition was evaluated at all.
        self.consumes = consumes


#: The declared catalogue — the report's denominator. Every id here must have a
#: literal call site in its `owner`, and `make analytics-catalogue-check`
#: enforces it. Add a probe in the SAME commit that calls it, or not at all.
#:
#: Ids follow the client plane's grammar (analytics.ID_RE) because they land in
#: the same table; the `class` column, not the name, is what keeps the two
#: populations apart.
PROBES: dict[str, ServerProbe] = {
    # ---- the public fence ---------------------------------------------------
    # WHICH AUTH PATHS ARE ACTUALLY EXERCISED. The gate has three outcomes that
    # cost real complexity and the box cannot currently tell you whether any of
    # them happens: the invited default, the walk-in allowlist, and the one
    # branch inside that allowlist which makes the walk-in plane interactive.
    #
    # Deliberately NOT probed: the LAN listener's anonymous traffic. It is the
    # highest-frequency path in the server, its volume is exactly what the
    # access log already reports, and "the LAN gate is open" is a constant, not
    # an observation. Every probe below fires only for a GATED request on the
    # public listener, which is a rounding error of the box's request volume.
    "auth.gate.invited": ServerProbe(
        area="auth",
        owner="scripts/serve/auth/gate.py",
        what="a signed-in NON-walk-in session was allowed through the public fence — the invited plane is in use",
    ),
    "auth.gate.walkin": ServerProbe(
        area="auth",
        owner="scripts/serve/auth/gate.py",
        what="the walk-in allowlist was consulted for a real request — a stranger with an account is browsing",
    ),
    "auth.gate.walkinOwn": ServerProbe(
        area="auth",
        owner="scripts/serve/auth/gate.py",
        what="a walk-in was allowed at their OWN clone's signaling or webrtc path — the one interactive surface the "
        "plane grants, so this is the plane being USED rather than merely reachable",
        consumes="auth.gate.walkin",
    ),
    "auth.gate.blocked": ServerProbe(
        area="auth",
        owner="scripts/serve/auth/gate.py",
        what="something browser-reachable asked for the command ENQUEUE and was refused; a zero says the block is "
        "theoretical, and anything else is worth reading the access log over",
    ),
    # ---- the walk-in broker -------------------------------------------------
    # The pool's rules cost more code than anything else in the serving plane,
    # and several of them may never have been reached on a 63-station museum
    # with a pool of three. Each of these is a branch somebody would have to
    # keep working forever on the strength of a comment.
    "walkin.claim.queued": ServerProbe(
        area="walkin",
        owner="scripts/serve/walkin/broker.py",
        what="a claim found no free clone (or hit the active-session cap) and went into the QUEUE — a zero means the "
        "whole queue-and-position machinery has never once been needed",
    ),
    "walkin.claim.resumeFailed": ServerProbe(
        area="walkin",
        owner="scripts/serve/walkin/broker.py",
        what="a clone was handed to a visitor and then would not resume, so `_abandon` ran; this is the path that "
        "keeps the 'a used clone is never re-listed' guarantee true under a failure",
    ),
    "walkin.reap.ttl": ServerProbe(
        area="walkin",
        owner="scripts/serve/walkin/broker.py",
        what="a session was ended by the 20-minute clock",
    ),
    "walkin.reap.idle": ServerProbe(
        area="walkin",
        owner="scripts/serve/walkin/broker.py",
        what="a session was ended by the 3-minute idle window — the reason code that decides whether the idle timer "
        "earns its keep, or is only ever beaten to it by the TTL",
    ),
    "walkin.reap.died": ServerProbe(
        area="walkin",
        owner="scripts/serve/walkin/broker.py",
        what="the watchdog found a pool member whose QEMU had died and retired it; a non-zero here is a fleet health "
        "fact nothing else on the box reports",
    ),
    # ---- the rolling log ----------------------------------------------------
    # A DECLARED PAIR, and the reason the pair is declared: the generational
    # rotate is reachable only when an age-prune has already run AND left the
    # file oversized. Its count alone cannot distinguish "unreachable" from
    # "the log never got big"; divided by the prune it can.
    "clientlog.prune.age": ServerProbe(
        area="clientlog",
        owner="scripts/serve/clientlog.py",
        what="the clientlog crossed its size backstop and the rolling age-prune actually dropped rows",
    ),
    "clientlog.rotate.generational": ServerProbe(
        area="clientlog",
        owner="scripts/serve/clientlog.py",
        what="the age-prune left the file STILL oversized and the single .1 generation rotate fired — i.e. the "
        "retention window is too wide for the disk budget. Suspected dead code; this is how that gets settled",
        consumes="clientlog.prune.age",
    ),
    # ---- signalling ---------------------------------------------------------
    "signal.ticket.identityDiffers": ServerProbe(
        area="signal",
        owner="scripts/serve/signal_route.py",
        what="a station's own signaling.json named an identity DIFFERENT from the endpoint key the document was "
        "fetched under, so the ticket was signed over the daemon's name and not the key. This exact divergence "
        "locked `solaris` and `aros` out of every session for four hours on 2026-08-05; a non-zero here means a "
        "station is mis-named RIGHT NOW and the fallback is the only thing hiding it",
    ),
}


# ---------------------------------------------------------------------------
# The fold. One lock, one dict, one store reference.
# ---------------------------------------------------------------------------

_lock = threading.Lock()
_pending: dict[str, int] = {}
_store = None
_next_flush = 0.0
#: Flush failures are counted, not raised and not logged per occurrence: a
#: store that has gone bad would otherwise write one stderr line per request.
#: The count is visible to `stats()`, which is what the test reads.
_dropped_flushes = 0


def bind(store) -> None:
    """Attach the AnalyticsStore. Until this is called `hit()` folds in memory
    and nothing is ever written — which is exactly what a unit test wants."""
    global _store, _next_flush
    with _lock:
        _store = store
        _next_flush = time.monotonic() + FLUSH_SECS


def hit(probe: str) -> None:
    """Record that a declared branch was taken. Never raises. Never writes.

    An UNDECLARED id is dropped rather than counted. That is not tidiness: the
    denominator is the catalogue, so a count under a name the catalogue does not
    carry could never appear in the report anyway, and dropping it here is what
    keeps the in-memory dict bounded by the declaration instead of by whatever a
    future call site passes in.
    """
    try:
        if probe not in PROBES:
            return
        due = None
        with _lock:
            _pending[probe] = _pending.get(probe, 0) + 1
            now = time.monotonic()
            if _store is not None and now >= _next_flush:
                due = _drain_locked(now)
        if due:
            _write(due)
    except Exception:  # noqa: BLE001 — a probe may never raise into a handler
        pass


def _drain_locked(now: float) -> dict[str, int]:
    """Take the pending counts and re-arm the throttle. Caller holds the lock.

    The throttle is re-armed BEFORE the write, not after, so a slow or failing
    store cannot turn every subsequent request into another attempt.
    """
    global _pending, _next_flush
    due, _pending = _pending, {}
    _next_flush = now + FLUSH_SECS
    return due


def _write(counts: dict[str, int]) -> None:
    global _dropped_flushes
    store = _store
    if store is None or not counts:
        return
    try:
        store.record_server(counts)
    except Exception:  # noqa: BLE001 — see the module docstring, property 1
        with _lock:
            _dropped_flushes += 1


def flush() -> int:
    """Fold whatever is pending in now. Returns the number of probe ids folded.

    Called on the report path and by the tests. Nothing on the request path
    needs it — that is what the throttle is for.
    """
    try:
        with _lock:
            due = _drain_locked(time.monotonic())
        _write(due)
        return len(due)
    except Exception:  # noqa: BLE001
        return 0


def stats() -> dict:
    """What the fold is holding right now. For tests and for a human at a REPL."""
    with _lock:
        return {"pending": dict(_pending), "bound": _store is not None, "droppedFlushes": _dropped_flushes}


def reset_for_tests() -> None:
    """Forget the store and every pending count. Tests only."""
    global _store, _pending, _next_flush, _dropped_flushes
    with _lock:
        _store = None
        _pending = {}
        _next_flush = 0.0
        _dropped_flushes = 0


def catalogue() -> dict:
    """The declaration as plain data, for the renderer and the gate."""
    return {
        pid: {
            "area": spec.area,
            "owner": spec.owner,
            "what": spec.what,
            **({"consumes": spec.consumes} if spec.consumes else {}),
        }
        for pid, spec in sorted(PROBES.items())
    }


# The serving process puts `scripts/serve` on sys.path and imports this as
# `probes`; the unit-test runner works from `scripts/` and reaches it as
# `serve.probes`. Both names must be the SAME module object or the counters
# split in two and the fold silently loses half of them.
sys.modules.setdefault("probes", sys.modules[__name__])
sys.modules.setdefault("serve.probes", sys.modules[__name__])


if __name__ == "__main__":
    import json

    json.dump(catalogue(), sys.stdout, indent=2, sort_keys=True)

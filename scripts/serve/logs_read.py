"""The admin-only READS of the log lane, and the filter whitelist that gates them.

WHY NOT IN `auth/routes.py`, where the trace reads live. Two reasons, and the
second is the one that matters. It keeps that file — the single busiest merge
surface in the plane — to a six-line call site for a whole new pillar. And it
puts the filter whitelist next to the store it filters, so the day somebody
adds a column, the SQL, the whitelist and the test are one file apart rather
than three.

ACCESS. Nothing here checks a role: `auth/routes.py` has already refused a
non-admin by position before it calls in, exactly as it does for
`/auth/traces/*`. A log record names a session and can carry a stack, so it
leaves the box through these routes and no other. The INGEST is open, like
`/traces` and `/analytics` — a tab must be able to report the error that just
broke its visit without holding an admin session.
"""

from __future__ import annotations

import time

LEAVES = ("search", "trace", "facets", "otlp")


def _int(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def filters(body: dict) -> dict:
    """Whitelist the filters. A query object straight from a browser reaching a
    SQL builder is how a filter becomes an injection, even an admin-only one.
    Every value below is bounded here and bound as a parameter there."""
    return {
        "service": str(body["service"])[:64] if body.get("service") else None,
        "instance": str(body["instance"])[:64] if body.get("instance") else None,
        "session": str(body["session"])[:64] if body.get("session") else None,
        "build": str(body["build"])[:64] if body.get("build") else None,
        "trace_id": str(body["traceId"])[:32] if body.get("traceId") else None,
        "span_id": str(body["spanId"])[:16] if body.get("spanId") else None,
        "min_sev": str(body["minSeverity"])[:16] if body.get("minSeverity") else None,
        # A substring of the BODY. Escaped for LIKE in the store, capped here.
        "contains": str(body["contains"])[:120] if body.get("contains") else None,
        "since_ms": _int(body.get("sinceMs")),
        "until_ms": _int(body.get("untilMs")),
        "limit": _int(body.get("limit")),
        "offset": _int(body.get("offset")),
    }


def route(store, leaf: str, body: dict, reply) -> None:
    """The four log reads, mirroring the four trace reads leaf for leaf so an
    operator who knows one surface knows the other. `reply(code, obj)` is
    injected so this module needs nothing from the auth package."""
    if leaf == "search":
        reply(200, store.search(**filters(body)))
        return
    if leaf == "trace":
        # THE PIVOT. Given a trace id — the one an operator just copied out of
        # a slow span, or off a `traceresponse` header — every log record any
        # of the three producers emitted under it, in time order. This is the
        # read the whole pillar exists to make answerable.
        reply(200, store.for_trace(str(body.get("id", ""))))
        return
    if leaf == "facets":
        since = _int(body.get("sinceMs")) or int((time.time() - 7 * 86400) * 1000)
        reply(200, store.facets(since))
        return
    if leaf == "otlp":
        # The export boundary, same contract as the trace lane's: run the SAME
        # search the UI ran and render the matches as OTLP/JSON, so what you
        # hand another system is exactly the set you were looking at.
        import logs_otlp

        found = store.search(**{**filters(body), "limit": 500})
        reply(200, logs_otlp.export(found["logs"]))
        return
    reply(404, {"error": "not found"})

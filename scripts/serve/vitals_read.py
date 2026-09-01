"""The admin-only READS of the vitals lane, and the filter whitelist gating them.

WHY THIS FILE EXISTS AND NOT A BLOCK IN `auth/routes.py`: the same two reasons
`logs_read.py` gives, and the second is still the one that matters. It keeps
that file — the busiest merge surface in the plane — to a six-line call site for
a whole new pillar, and it puts the filter whitelist next to the store it
filters, so the day somebody adds a vital, the SQL, the whitelist and the test
are one file apart rather than three.

ACCESS. Nothing here checks a role: `auth/routes.py` has already refused a
non-admin by position before it calls in, exactly as it does for `/auth/traces/*`
and `/auth/logs/*`. A sample names a station and a session, so it leaves the box
through these routes and no other. The INGEST is open, like `/traces`, `/logs`
and `/analytics` — a tab whose stream is bad must be able to say so without
holding an admin session, and that is precisely the tab whose numbers matter.

FOUR LEAVES, mirroring the log lane's four so an operator who knows one surface
knows the other:

    series   the chart read — a filtered page of samples, OLDEST FIRST
    live     the triage read — newest sample per station streaming right now
    facets   what is in the window, plus the catalogue, plus COVERAGE
    otlp     the export boundary: the same page, as OTLP/JSON
"""

from __future__ import annotations

import time

LEAVES = ("series", "live", "facets", "otlp")


def _int(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def filters(body: dict) -> dict:
    """Whitelist the filters. A query object straight from a browser reaching a
    SQL builder is how a filter becomes an injection, even an admin-only one.
    Every value below is bounded here and bound as a parameter there."""
    return {
        "station": str(body["station"])[:64] if body.get("station") else None,
        "session": str(body["session"])[:64] if body.get("session") else None,
        "source": str(body["source"])[:16] if body.get("source") else None,
        "build": str(body["build"])[:64] if body.get("build") else None,
        "since_ms": _int(body.get("sinceMs")),
        "until_ms": _int(body.get("untilMs")),
        "limit": _int(body.get("limit")),
        "offset": _int(body.get("offset")),
    }


def route(store, leaf: str, body: dict, reply) -> None:
    """The four vitals reads. `reply(code, obj)` is injected so this module
    needs nothing from the auth package."""
    if leaf == "series":
        # THE CHART READ. Defaults to the last hour rather than to everything:
        # this store's rows are dense by construction, and an unbounded default
        # would page 5,000 samples of history to answer "how is it doing".
        f = filters(body)
        if f["since_ms"] is None and f["until_ms"] is None:
            f["since_ms"] = int((time.time() - 3600) * 1000)
        reply(200, store.series(**f))
        return
    if leaf == "live":
        # THE TRIAGE READ: one row per stream that has reported recently. This
        # is what "is anything streaming right now, and is it healthy" costs —
        # a single indexed query, not a series per station.
        reply(200, store.live(_int(body.get("withinMs")) or 120_000))
        return
    if leaf == "facets":
        since = _int(body.get("sinceMs")) or int((time.time() - 24 * 3600) * 1000)
        reply(200, store.facets(since))
        return
    if leaf == "otlp":
        # The export boundary, same contract as the trace and log lanes': run
        # the SAME query the UI ran and render the matches as OTLP/JSON, so
        # what you hand another system is exactly the set you were looking at.
        # It is also how an operator answers "are the numbers Instana is
        # showing the numbers we sent" without reading the forwarder's logs.
        import vitals_otlp

        found = store.series(**{**filters(body), "limit": 5000})
        reply(200, vitals_otlp.export(found["samples"]))
        return
    reply(404, {"error": "not found"})

"""THE TELEMETRY PLANE'S OWN ENDPOINTS: the server-side counterpart of
`KH_TELEMETRY_PATHS` in spa/src/analytics/telemetryPaths.ts.

WHY THIS FILE EXISTS AT ALL. The browser knows which paths are "us measuring
ourselves" rather than "a visitor doing something": `khFetch.ts` opens no client
span and sends no `traceparent` for any of them, because a span about sending a
span is a feedback loop. That exclusion only holds if the list is complete, and
the list lives in the tab while the routes live here. This is the server-side
declaration of the same set, and `scripts/test_telemetry_paths_complete.py`
pins it two ways: equal to the TypeScript list, and covering every INGEST route
`telemetry_routes.py` dispatches — so a new ingest route fails a test on the
commit that adds it instead of quietly tracing its own uploads.

`tracing_http.route_of()` answers a different question — which paths the
serving plane TRACES — and deliberately so; this list does not feed it.

WHAT IS IN IT, AND WHAT IS NOT:

    /analytics             INGEST. A tab posting counters on a timer. Nobody
    /clientlog             waits, nobody reads the latency, and in an
    /clientcmd             operator's last-hour view these three plus /usage
    /usage                 were essentially the entire call list.
    /traces /logs /vitals  Same.
    /coverage              Same.

    /analytics/report.json READS, and NOT listed. Somebody has /admin open and
    /coverage/report.json  is waiting for a page to render; their latency is
    /usage/stations.json   worth seeing. The browser's matchers are prefix
                           tests, so the tab does not trace these either — but
                           the serving plane does, and the completeness test
                           exempts them by name.

    /signal/{station}.json NOT telemetry. It is the first thing that happens
                           when a visitor opens a station, and if it is slow the
                           gallery is slow.
    /kh/deploy-hint        NOT telemetry. It is GitHub's webhook / the Actions
                           ping, not a tab polling: no visitor is behind it, but
                           it is the TRIGGER of a deploy, so "did the hint
                           arrive and how long did it take" is worth seeing.
"""

from __future__ import annotations

#: Mirrors `KH_TELEMETRY_PATHS` (spa/src/analytics/telemetryPaths.ts) exactly.
#: Keep the two equal — a test fails if they diverge — rather than "close
#: enough": the whole value of a mirrored list is that a reader can trust it is
#: the same list.
TELEMETRY_PATHS = frozenset(
    {
        "/traces",
        "/logs",
        "/vitals",
        "/analytics",
        "/coverage",
        "/clientlog",
        "/usage",
        "/clientcmd",
    }
)

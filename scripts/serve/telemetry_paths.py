"""THE TELEMETRY PLANE'S OWN ENDPOINTS: the server-side counterpart of
`KH_TELEMETRY_PATHS` in spa/src/analytics/instana.ts.

WHY THIS FILE EXISTS AT ALL. The browser has known for a long time which paths
are "us measuring ourselves" rather than "a visitor doing something" — one list,
two mechanically derived matchers, so adding an endpoint is one edit
(instana.ts's own header makes that argument). The SERVER had no such notion:
`tracing_http.route_of()` says which paths are TRACED, which is a different
question and deliberately so. Anything that needed to distinguish plumbing from
visitor behaviour on this side had to hardcode a second list, and a second list
drifts. This is that one server-side source, and
`scripts/test_otlp_fidelity.py` pins it byte-for-byte against the TypeScript so
it cannot silently fall behind.

WHAT IT IS USED FOR, AND WHY THERE ARE TWO USERS. The first is Instana's own
`synthetic` mark, applied on the way out in `traces_otlp.py` — the documented
mechanism for "machine chatter, hidden by default, still queryable on demand".
It was tried first because it preserves the data. IT IS NOT HONOURED OVER OTLP
INGEST: measured 2026-09-01 by sending five otherwise-identical entry spans to
the agent's receiver, one control and four spellings (`synthetic` as a boolean,
`synthetic` as the string "true", `instana.synthetic`, `sdk.custom.tags.
synthetic`), and finding ALL FIVE — control included — in the default Analytics
-> Calls view. IBM's wording is "which can be achieved with any of the Instana
tracing SDKs", and OTLP is not one of their SDKs.

So the second user is the FALLBACK the brief asked for: `instana-forward.py`
drops a trace made ENTIRELY of these calls before it leaves the box, prints how
many it dropped, and is switched off with one environment variable
(`INSTANA_FORWARD_TELEMETRY=1`). The mark is still exported, because it is the
correct annotation and costs one attribute — the day IBM honours it, unsetting
the variable is the whole change. Nothing here changes what THIS box records;
see docs/lab/INSTANA-VIEW-INVENTORY.md §4.8.

WHY THE MATCH IS EXACT AND NOT A PREFIX. The browser's matchers are prefix
tests (`^/analytics\\b`), which is right for "should this fetch open a client
span" — the whole subtree is our own plumbing from the tab's point of view. It
is NOT right for the vendor's default view, because two of those subtrees
contain something a person is waiting for:

    /analytics             INGEST. A tab posting counters on a timer. Nobody
    /clientlog             waits, nobody reads the latency, and in the
    /clientcmd             operator's last-hour view these three plus /usage
    /usage                 were essentially the entire call list.
    /traces                Same, and not traced server-side today anyway.
    /coverage              Same.
    /eum                   The vendor's OWN beacons, proxied first-party by
                           eum_proxy.py. Plumbing by the same argument, and
                           doubly so: it is the delivery of a measurement, not
                           a thing measured. Listed for the day it is traced.

    /analytics/report.json READS. Somebody has /admin open and is waiting for
    /coverage/report.json  a page to render; the report query is one of the
    /usage/stations.json   heaviest things this server does, and the fleet
                           table's station usage merge is on a visitor's path.
                           Their latency is exactly what Analytics is for, so
                           they stay VISIBLE. An exact match is what keeps them
                           so while their parents are hidden.

TWO MORE BOUNDARY CASES, DECIDED AND WRITTEN DOWN SO THEY ARE NOT RE-ARGUED:

    /signal/{station}.json NOT telemetry. It is the first thing that happens
                           when a visitor opens a station, and if it is slow the
                           gallery is slow. It must stay visible, and the exact
                           match plus its absence from this list is what
                           guarantees that.
    /kh/deploy-hint        NOT telemetry, and not in the browser's list either.
                           It is GitHub's webhook / the Actions ping, not a tab
                           polling: no visitor is behind it, but it is the
                           TRIGGER of a deploy, so "did the hint arrive and how
                           long did it take" is worth seeing. It appears in
                           bursts around a push (seven rows in fifteen minutes,
                           observed 2026-09-01) and never otherwise, which is
                           the opposite of the steady per-tab chatter this list
                           is about.
"""

from __future__ import annotations

#: Mirrors `KH_TELEMETRY_PATHS` (spa/src/analytics/instana.ts) exactly. Keep the
#: two equal — a test fails if they diverge — rather than "close enough": the
#: whole value of a mirrored list is that a reader can trust it is the same list.
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
        "/eum",
    }
)


def is_telemetry_entry_span(span: dict) -> bool:
    """Is this stored span an ENTRY span for the telemetry plane?

    Entry spans only, because that is what a "call" is in Instana and what the
    volume is made of. `span` is the shape `traces.TraceStore.trace()` returns.
    """
    return span.get("kind") == "server" and is_telemetry_route((span.get("attributes") or {}).get("http.route"))


def is_telemetry_only_trace(trace: dict) -> bool:
    """Is this WHOLE trace nothing but the telemetry plane talking to itself?

    THE WHOLE-TRACE TEST IS THE SAFE ONE, and it is why the filter can drop
    rather than merely trim. These polls are one-span traces by construction:
    `khFetch.ts` sends no `traceparent` on an excluded telemetry path, so the
    serving plane roots its own trace and nothing else ever joins it. Asking
    the question of the whole trace means a span that somehow DID share a trace
    with real work keeps that trace — and the real work with it. Trimming spans
    out of a mixed trace would do the opposite: ship a trace with a hole in it,
    which is the one thing this pipeline has spent two fixes not doing.
    """
    spans = trace.get("spans") or []
    return bool(spans) and all(is_telemetry_entry_span(s) for s in spans)


def is_telemetry_route(route) -> bool:
    """Is this `http.route` the telemetry plane talking to itself?

    Exact match, for the reason in the module docstring: the read side of these
    same subtrees is somebody waiting for a page and must not be swept up.
    """
    return isinstance(route, str) and route in TELEMETRY_PATHS

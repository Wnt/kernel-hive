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

WHAT IT IS USED FOR TODAY: marking those calls `synthetic` on the way out to
Instana (`traces_otlp.py`), which is Instana's own documented mechanism for
"machine chatter, hidden by default, still queryable on demand" — not a filter
and not a deletion. Nothing here changes what this box records; see
docs/lab/INSTANA-VIEW-INVENTORY.md.

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
                           It is a deliberate one-shot check, not a per-tab
                           poll, so it contributes no volume and hiding it would
                           buy nothing.
"""

from __future__ import annotations

#: Mirrors `KH_TELEMETRY_PATHS` (spa/src/analytics/instana.ts) exactly. Keep the
#: two equal — a test fails if they diverge — rather than "close enough": the
#: whole value of a mirrored list is that a reader can trust it is the same list.
TELEMETRY_PATHS = frozenset(
    {
        "/traces",
        "/analytics",
        "/coverage",
        "/clientlog",
        "/usage",
        "/clientcmd",
        "/eum",
    }
)


def is_telemetry_route(route) -> bool:
    """Is this `http.route` the telemetry plane talking to itself?

    Exact match, for the reason in the module docstring: the read side of these
    same subtrees is somebody waiting for a page and must not be swept up.
    """
    return isinstance(route, str) and route in TELEMETRY_PATHS

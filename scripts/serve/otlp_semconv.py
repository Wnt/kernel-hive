"""The vendor bridge: OUR attribute names, spelled the way Instana reads them.

WHY THIS IS A BRIDGE AND NOT A RENAME. This repo instruments with the CURRENT
OpenTelemetry HTTP semantic conventions — `http.request.method`, `url.path`,
`http.response.status_code`, `server.address` — which have been the stable names
since the HTTP conventions were declared stable, and are what
`scripts/serve/tracing_http.py`, `spa/src/analytics/khFetch.ts` and
`/admin/observability` all speak. Instana's published list of consumed span
attributes (instana-docs/0307-opentelemetry-signals.md) is the PREVIOUS
generation: `http.method`, `http.target`, `http.status_code`, `http.host`,
`net.peer.*`. One later page (0311, service mapping) does name `url.path`, so
support for the newer spelling is partial and undocumented rather than absent —
which is exactly the situation in which guessing is expensive and hedging is
cheap.

THE DECISION: ADD, NEVER REPLACE, AND ONLY AT THE EXPORT BOUNDARY. Our plane is
the product and Instana is a temporary consumer being evaluated against it, so
renaming our attributes to suit it would be the tail wagging the dog — and would
break our own UI, our own facets and every doc that names them. Instead the
old-generation names are DERIVED here, in the same file that already translates
the compact store form into OTLP/JSON spelling, and both spellings go out. A
consumer that reads the new names sees them; one that reads only the old ones
sees those; neither is told anything untrue. The cost is a handful of duplicated
attributes on the wire, which is the cheapest thing in this pipeline.

WHAT THE `url.full` / `url.query` BAN COSTS, STATED PLAINLY. `scripts/serve/
traces.py` refuses both at intake so a query string — a station id, a
ticket-shaped value, worse — can never be in the store to be forwarded. Instana
renders `http.url` in its call-detail pane, and the honest thing we can hand it
is a query-free reconstruction: scheme + host + path, assembled below from three
attributes we do hold. So the pane is populated, and what is missing from it is
precisely the query string, deliberately. Anyone reading a call in Instana and
wanting to know which parameters were sent will not find them there and must go
to the route and `kh.station` instead; that is the trade, and it is the right
one for a public gallery.

WHAT IS DELIBERATELY NOT BRIDGED. `db.*`, `messaging.*` and `rpc.*` have no
counterpart in this system — there is no database call, queue or RPC framework
in a trace here — and inventing one to light up a pane would be a fabricated
fact. `http.user_agent` is not stored (the serving plane does not put it on a
span) so it cannot be derived; that is a gap owned by `tracing_http.py`, not
something this file can close.
"""

from __future__ import annotations

#: One-for-one renames that hold regardless of span kind.
_ALWAYS = {
    "http.request.method": "http.method",
    "url.path": "http.target",
    "http.response.status_code": "http.status_code",
    "url.scheme": "http.scheme",
    # The authority this request was addressed to. Instana's `http.host` means
    # the same thing for both an entry and an exit span, so it needs no kind
    # test; `net.peer.*` below does, because "the peer" is only the address we
    # hold on the calling side.
    "server.address": "http.host",
}

#: Renames that are only TRUE on an exit (client) span, where the address we
#: recorded is the REMOTE end. On a server span `server.address` is our own
#: authority, and calling it `net.peer.name` would name the wrong machine.
_CLIENT_ONLY = {
    "server.address": "net.peer.name",
    "server.port": "net.peer.port",
}

#: `peer.service` is what draws the EDGE on a service map, and it is the one
#: attribute here that is not a rename of something we store — it is a fact
#: about the callee, which the caller knows only because these two exit spans
#: are same-origin by construction:
#:
#:   http.client.request  khFetch patches `window.fetch` and refuses anything
#:                        that is not `window.location.origin`, so the callee is
#:                        always this box's serving plane.
#:   input.edge           the browser's WebTransport leg to the station daemon
#:                        (docs/lab/TRACE-CONTEXT.md §3.2); its receiving half
#:                        IS `input.dispatch` in streamhost.
#:
#: Keyed on the span NAME rather than inferred, so a third exit span added later
#: gets no edge until somebody decides what it talks to.
_PEER_SERVICE = {
    "http.client.request": "kernel-hive-serve",
    "input.edge": "kernel-hive-daemon",
}


def instana_aliases(name: str, kind: str, attrs: dict) -> dict:
    """The old-generation spellings implied by `attrs`, as a dict to merge in.

    Never overwrites an attribute that is already present: if a span carries a
    real `http.method` of its own, that is the producer's statement and this is
    only a fallback for the ones that do not.
    """
    out: dict = {}
    table = dict(_ALWAYS)
    if kind == "client":
        table.update(_CLIENT_ONLY)
    for ours, theirs in table.items():
        if ours in attrs and theirs not in attrs:
            out[theirs] = attrs[ours]
    # `net.peer.name` and `http.host` both come from `server.address` on a
    # client span; the loop above only assigns one of the two because a dict
    # cannot hold the same key twice. Put the other one back.
    if kind == "client" and "server.address" in attrs and "http.host" not in attrs:
        out["http.host"] = attrs["server.address"]
    peer = _PEER_SERVICE.get(name)
    if kind == "client" and peer and "peer.service" not in attrs:
        out["peer.service"] = peer
    url = _query_free_url(attrs)
    if url and "http.url" not in attrs:
        out["http.url"] = url
    return out


def _query_free_url(attrs: dict) -> str | None:
    """`http.url` rebuilt from parts, or None when a part is missing.

    Query-free BY CONSTRUCTION and not by stripping: the pieces this assembles
    from are a scheme, an authority and a path, and the store has never held a
    query string to leave in (`traces.py` BANNED_ATTRS). There is no code path
    here that could reintroduce one, which is a stronger guarantee than a
    sanitiser.
    """
    scheme = attrs.get("url.scheme")
    host = attrs.get("server.address")
    path = attrs.get("url.path")
    if not (isinstance(scheme, str) and isinstance(host, str) and isinstance(path, str)):
        return None
    port = attrs.get("server.port")
    authority = f"{host}:{port}" if isinstance(port, int) and port not in (80, 443) else host
    return f"{scheme}://{authority}{path}"

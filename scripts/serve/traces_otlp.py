"""OTLP/JSON export: the boundary where these traces become somebody else's.

WHY THIS EXISTS SEPARATELY FROM THE STORE. The span MODEL is already
OpenTelemetry's — ids, kinds, status codes, events, semantic-convention
attribute names — so nothing here is a translation of meaning. What it is is a
translation of SPELLING: OTLP/JSON writes an attribute as
`{"key":"x","value":{"stringValue":"y"}}` and a timestamp as a stringified
nanosecond int64, which is three to five times the bytes of the compact form the
browser uploads and the store keeps. Paying that on every upload from every tab
would buy nothing; paying it once, on demand, at the point where another system
reads, buys full compatibility. That is the whole design in one sentence.

THE MAPPING, FIELD BY FIELD, so nobody has to reverse-engineer it:

    store                     OTLP/JSON
    ------------------------  -------------------------------------------
    trace.build               resource attr `service.version` (browser
                              service only; the serving plane's and the
                              daemon's come from otlp_resource.py, and every
                              one of the three is omitted when unknown)
    trace_id (32 hex)         traceId                     (hex, unchanged)
    span_id  (16 hex)         spanId                      (hex, unchanged)
    parent_id or NULL         parentSpanId, omitted when null
    name                      name
    kind                      kind          (enum int, see KIND_ENUM)
    started_ms                startTimeUnixNano   (ms * 1e6, as a STRING —
                              protobuf JSON renders int64 as a string, and a
                              float would lose precision above 2^53)
    started_ms + dur_ms       endTimeUnixNano             (same rule)
    status                    status.code   (enum int, see STATUS_ENUM)
    status_msg                status.message, omitted when null
    attrs   {k: v}            attributes  [{key, value:{<typed>}}]
    events  [{n,t,a}]         events      [{name, timeUnixNano, attributes}]
    hidden_ms                 attribute `kh.hidden_ms`

The last row is the only thing here that is NOT an OTel concept. Hidden time —
how much of a span's wall duration the tab was not visible for — has no
convention because it is a browser-plane concern, so it is exported as a
namespaced attribute rather than dropped. Dropping it would make the exported
trace disagree with our own metrics, which count visible time only.

TWO NEIGHBOURS DO THE PARTS THAT ARE NOT SPELLING. `otlp_resource.py` answers
WHO produced a span — the explicit service table and each plane's build id —
and `otlp_semconv.py` adds the previous-generation attribute spellings Instana
consumes alongside our own. Both are additive and neither renames anything this
plane emits.

A NOTE ON WHAT ISN'T HERE. No stacktraces: `exception.stacktrace` is refused at
intake (see traces.py) and so can never appear on the way out. An exporter that
quietly reintroduced it would undo the one content rule the trace lane kept.
"""

from __future__ import annotations

import json

import otlp_resource
import otlp_semconv
import telemetry_paths

# OTel SpanKind enum, from the protobuf definition.
KIND_ENUM = {"internal": 1, "server": 2, "client": 3, "producer": 4, "consumer": 5}
# OTel StatusCode enum: UNSET / OK / ERROR.
STATUS_ENUM = {"unset": 0, "ok": 1, "error": 2}


def _any_value(v) -> dict:
    """One OTLP AnyValue. bool BEFORE int, because bool is an int in Python and
    exporting `true` as `1` would silently change a field's type downstream."""
    if isinstance(v, bool):
        return {"boolValue": v}
    if isinstance(v, int):
        return {"intValue": str(v)}
    if isinstance(v, float):
        return {"doubleValue": v}
    return {"stringValue": str(v)}


def _attrs(d: dict) -> list:
    return [{"key": k, "value": _any_value(v)} for k, v in sorted((d or {}).items())]


def _nanos(ms: int) -> str:
    # int64 as a STRING: that is what the protobuf JSON mapping requires, and a
    # JSON number would lose precision past 2^53 nanoseconds (~104 days of epoch
    # is fine, but the rule is the rule and collectors validate it).
    return str(int(ms) * 1_000_000)


def _is_synthetic(kind: str, attrs: dict) -> bool:
    """Is this an entry span for our OWN telemetry plane, rather than for
    something a visitor did?

    `synthetic` IS INSTANA'S VOCABULARY AND LIVES ONLY HERE. Instana marks a
    call Synthetic when a span is "annotated with `synthetic` with the value
    true" (instana-docs/0251-monitoring-applications.md, "Synthetic call
    rules"), and hides Synthetic calls from Unbounded Analytics BY DEFAULT while
    keeping them one switch away (Hidden calls -> Synthetic calls). That is
    exactly the behaviour wanted — hidden, not deleted — so it is used rather
    than worked around. It is applied at the EXPORT boundary and never written
    to the store: `traces.db` and /admin/observability keep these spans
    first-class, because a vendor's presentation default has no business
    changing what this box records. The same rule as otlp_semconv.py, for the
    same reason.

    WHY THIS GOT WORSE BEFORE IT GOT BETTER, stated plainly because the next
    reader will otherwise think the noise is new. These polls used to propagate
    a `traceparent` from whatever span happened to be active, so each one hid
    inside somebody else's trace and never appeared as a call of its own. Fixing
    that (khFetch.ts's `outboundTraceparent`: an excluded telemetry path names
    no parent, and the server roots its own trace) made each poll a correct
    one-span root trace — more honest data, and a call list where
    `serve.clientcmd`, `serve.clientlog` and `serve.analytics` crowded out
    everything else. The mark below is the presentation half of that fix, not a
    retreat from it.

    ENTRY SPANS ONLY. A `client` span is the tab's side and is never created for
    these paths anyway (khFetch's `IGNORE_URL_PATTERNS`), and marking an
    internal span synthetic would say something about work, not about a call.
    """
    return kind == "server" and telemetry_paths.is_telemetry_route(attrs.get("http.route"))


def span_to_otlp(s: dict) -> dict:
    """One stored span row (as traces.py `trace()` returns it) to OTLP."""
    attrs = dict(s.get("attributes") or {})
    if s.get("hiddenMs"):
        attrs["kh.hidden_ms"] = int(s["hiddenMs"])
    kind = s.get("kind", "internal")
    name = s.get("name", "")
    # The vendor bridge, applied HERE rather than in the store: what we keep is
    # our own naming, what leaves also carries Instana's. See otlp_semconv.py.
    attrs.update(otlp_semconv.instana_aliases(name, kind, attrs))
    if _is_synthetic(kind, attrs):
        attrs["synthetic"] = True
    out = {
        "traceId": s["traceId"],
        "spanId": s["spanId"],
        "name": s["name"],
        "kind": KIND_ENUM.get(kind, 1),
        "startTimeUnixNano": _nanos(s["startedMs"]),
        "endTimeUnixNano": _nanos(s["startedMs"] + s["durMs"]),
        "attributes": _attrs(attrs),
        "status": {"code": STATUS_ENUM.get(s.get("status", "unset"), 0)},
    }
    if s.get("parentId"):
        out["parentSpanId"] = s["parentId"]
    if s.get("statusMessage"):
        out["status"]["message"] = s["statusMessage"]
    events = [
        {
            "name": e.get("n", ""),
            "timeUnixNano": _nanos(e.get("t", s["startedMs"])),
            "attributes": _attrs(e.get("a") or {}),
        }
        for e in (s.get("events") or [])
    ]
    if events:
        out["events"] = events
    return out


def export(
    traces: list[dict],
    service: str = "kernel-hive-spa",
    host_id: str | None = None,
    host_name: str | None = None,
    builds: otlp_resource.BuildIds | None = None,
) -> dict:
    """Full OTLP/JSON `resourceSpans`, grouped by RESOURCE — the producer.

    Grouping by the producing entity rather than emitting one Resource per trace
    is the faithful reading of the spec: a Resource is "the entity producing
    telemetry", which for a browser plane is one tab, for the serving plane is
    the one process on the box, and for the daemon is ONE OF SIXTY-ONE
    STATIONS. It also keeps the export small — resource attributes are written
    once per producer instead of once per trace.

    THE KEY IS (session, service, instance, version), and every part of it earns
    its place:

    * SERVICE, because one store holds spans from three processes. Labelling a
      Python request handler `kernel-hive-spa` merges two services into one node
      on any service map built from this export.
    * INSTANCE, because sixty-one daemons under one service name is a map that
      cannot say which machine was asleep. `otlp_resource.SERVICES` says which
      identity distinguishes two instances of each service: the tab's session,
      the box, or the station.
    * VERSION, because `service.version` is a RESOURCE attribute — it describes
      the producer, not the moment — and the three planes ship on three
      cadences. Each service's build id comes from its OWN source of truth
      (otlp_resource.py); the SPA's bundle id is never stamped on the other two,
      which would assert something false about their builds.

    Every one of the three is OMITTED rather than defaulted when it is not
    known. A consumer grouping by version must not be handed a placeholder it
    cannot tell from a real value.
    """
    builds = builds if builds is not None else otlp_resource.BuildIds()
    by_key: dict[tuple, list] = {}
    for t in traces:
        build = t.get("build") or ""
        session = t.get("sessionId", "unknown")
        for s in t.get("spans", []):
            attrs = s.get("attributes") or {}
            svc = attrs.get("kh.service") or service
            key = (
                session,
                svc,
                _instance_id(svc, session, attrs, host_name),
                _version(svc, build, attrs, s, builds),
            )
            by_key.setdefault(key, []).append(span_to_otlp({**s, "traceId": t["traceId"]}))
    return {
        "resourceSpans": [
            {
                "resource": {
                    "attributes": _attrs(
                        {
                            "service.name": svc,
                            "session.id": session,
                            # Instana links OpenTelemetry entities to a host by
                            # `host.id` and refuses or orphans data without one
                            # (or the x-instana-host header). Harmless to any
                            # other consumer: it is a standard semantic
                            # convention attribute.
                            **({"host.id": host_id} if host_id else {}),
                            **({"host.name": host_name} if host_name else {}),
                            **({"service.instance.id": instance} if instance else {}),
                            **({"service.version": version} if version else {}),
                            "telemetry.sdk.name": "kernel-hive",
                            # The language of the thing that PRODUCED the span,
                            # from an explicit table — never guessed off the
                            # service name, and absent for a service nobody has
                            # declared. See otlp_resource.py.
                            **({"telemetry.sdk.language": lang} if (lang := otlp_resource.language_of(svc)) else {}),
                        }
                    )
                },
                "scopeSpans": [{"scope": {"name": "kernel-hive-spa"}, "spans": spans}],
            }
            for (session, svc, instance, version), spans in sorted(by_key.items())
        ]
    }


def _instance_id(svc: str, session: str, attrs: dict, host_name: str | None) -> str | None:
    """`service.instance.id`: WHICH producer of this service, or None."""
    kind = otlp_resource.instance_kind_of(svc)
    if kind == "session":
        return session or None
    if kind == "host":
        return host_name or None
    if kind == "station":
        station = attrs.get("kh.station")
        return station if isinstance(station, str) and station else None
    return None


def _version(svc: str, build: str, attrs: dict, span: dict, builds: otlp_resource.BuildIds) -> str | None:
    """`service.version` from this service's own source of truth, or None.

    The daemon's is looked up per STATION and per SPAN TIME on purpose: a canary
    means two stations legitimately run different binaries, and an artifact
    installed after a span cannot be what produced it.
    """
    if svc == "kernel-hive-spa":
        # The tab told us, on its batch envelope. "unknown" is the store's
        # default for a batch that named none and is not a version.
        return build if build and build != "unknown" else None
    if svc == "kernel-hive-serve":
        return builds.serve()
    if svc == "kernel-hive-daemon":
        return builds.daemon(attrs.get("kh.station"), span.get("startedMs"))
    return None


def export_json(traces: list[dict]) -> str:
    return json.dumps(export(traces), separators=(",", ":"))

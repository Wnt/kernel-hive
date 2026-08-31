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

A NOTE ON WHAT ISN'T HERE. No stacktraces: `exception.stacktrace` is refused at
intake (see traces.py) and so can never appear on the way out. An exporter that
quietly reintroduced it would undo the one content rule the trace lane kept.
"""

from __future__ import annotations

import json

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


def span_to_otlp(s: dict) -> dict:
    """One stored span row (as traces.py `trace()` returns it) to OTLP."""
    attrs = dict(s.get("attributes") or {})
    if s.get("hiddenMs"):
        attrs["kh.hidden_ms"] = int(s["hiddenMs"])
    out = {
        "traceId": s["traceId"],
        "spanId": s["spanId"],
        "name": s["name"],
        "kind": KIND_ENUM.get(s.get("kind", "internal"), 1),
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


def export(traces: list[dict], service: str = "kernel-hive-spa") -> dict:
    """Full OTLP/JSON `resourceSpans`, grouped by SESSION.

    Grouping by session rather than emitting one Resource per trace is the
    faithful reading of the spec — a Resource is "the entity producing
    telemetry", and for a browser plane that is one tab, not one journey. It
    also keeps the export small: the resource attributes are written once per
    session instead of once per trace.
    """
    by_session: dict[str, list] = {}
    for t in traces:
        for s in t.get("spans", []):
            by_session.setdefault(t.get("sessionId", "unknown"), []).append(
                span_to_otlp({**s, "traceId": t["traceId"]})
            )
    return {
        "resourceSpans": [
            {
                "resource": {
                    "attributes": _attrs(
                        {
                            "service.name": service,
                            "session.id": session,
                            "telemetry.sdk.name": "kernel-hive",
                            "telemetry.sdk.language": "webjs",
                        }
                    )
                },
                "scopeSpans": [{"scope": {"name": "kernel-hive-spa"}, "spans": spans}],
            }
            for session, spans in sorted(by_session.items())
        ]
    }


def export_json(traces: list[dict]) -> str:
    return json.dumps(export(traces), separators=(",", ":"))

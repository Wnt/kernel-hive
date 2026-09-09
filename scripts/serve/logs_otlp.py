"""Stored log rows -> OTLP/JSON `resourceLogs`, for the Instana logs leg.

THE SIBLING OF `traces_otlp.py`, deliberately: same hand-rolled OTLP/JSON, same
no-dependency posture, same `export(rows, host_id=...)` signature shape. It
reuses that module's value/attribute/nanosecond encoders rather than growing a
second set — an OTLP `KeyValue` is an OTLP `KeyValue` whichever signal carries
it, and two encoders would drift.

    COUPLING, stated for the merge: this module imports `_any_value`, `_attrs`
    and `_nanos` from `traces_otlp`. They are the only names it takes, none of
    them are touched here, and a rename on that side is a one-line fix here.

FIELD MAPPING — store column -> OTLP LogRecord field:

    ts_ms        -> timeUnixNano            (producer clock)
    observed_ms  -> observedTimeUnixNano    (ours; Instana timestamps on
                                             ingest anyway — 0307:332)
    severity     -> severityText            (Instana's PRIMARY level source)
    sev_num      -> severityNumber          (its documented fallback, 0307:333)
    body         -> body.stringValue        ("incorporated without any
                                             alterations" — 0307:331)
    trace_id     -> traceId  }  the join. Instana takes both unaltered
    span_id      -> spanId   }  (0307:331); so does every OTel backend.
    attrs        -> attributes             ("supported as key-value pairs
                                             through the Custom Tags", 0307:336)
    service      -> resource service.name  (what Instana correlates a log to a
                                            SERVICE with — 0307:1693)
    instance     -> resource service.instance.id (one of the identifiers
                                            Instana accepts as the required
                                            host/entity identity — 0307:338-352)

`flags` is set to 1 (SAMPLED) on any record that carries a trace id, because a
LogRecord whose TraceFlags say "not sampled" invites a backend to treat the
correlation as best-effort.
"""

from __future__ import annotations

import json

from traces_otlp import _any_value, _attrs, _nanos

SERVICE_DEFAULT = "kernel-hive-serve"
SCOPE_NAME = "kernel-hive"

#: `service.name` suffix -> `telemetry.sdk.language`. Same table as the trace
#: exporter's, kept explicit because a wrong language tag sends an Instana
#: operator looking for a Python stack in a browser's log.
_LANG = {"kernel-hive-serve": "python", "kernel-hive-daemon": "rust", "kernel-hive-spa": "webjs"}


def record_to_otlp(r: dict) -> dict:
    """One stored row (as `LogStore._row` returns it) -> one OTLP LogRecord."""
    out = {
        "timeUnixNano": _nanos(r["tsMs"]),
        "observedTimeUnixNano": _nanos(r.get("observedMs") or r["tsMs"]),
        "severityNumber": r.get("severityNumber") or 0,
        "severityText": r.get("severity") or "",
        "body": _any_value(r.get("body") or ""),
    }
    attrs = dict(r.get("attributes") or {})
    # The session is a resource fact for the browser and a per-record fact for
    # the daemon (one process serves many sessions), so it rides as an
    # attribute too. Cheap, and it is the id every existing dashboard filters
    # on today.
    if r.get("sessionId") and r["sessionId"] != "unknown":
        attrs.setdefault("session.id", r["sessionId"])
    if attrs:
        out["attributes"] = _attrs(attrs)
    if r.get("traceId"):
        out["traceId"] = r["traceId"]
        out["flags"] = 1
        if r.get("spanId"):
            out["spanId"] = r["spanId"]
    return out


def export(rows: list[dict], host_id: str | None = None) -> dict:
    """`{"resourceLogs": [...]}` for a page of stored rows.

    Grouped by (service, instance, build) — the tuple that defines a resource.
    Ungrouped, every record would repeat its whole resource envelope, which at
    our record sizes is most of the body.
    """
    groups: dict[tuple, list] = {}
    for r in rows:
        key = (r.get("service") or SERVICE_DEFAULT, r.get("instance") or "unknown", r.get("build") or "unknown")
        groups.setdefault(key, []).append(record_to_otlp(r))
    out = []
    for (service, instance, build), recs in groups.items():
        res = {
            "service.name": service,
            "telemetry.sdk.name": "kernel-hive",
            "telemetry.sdk.language": _LANG.get(service, "python"),
        }
        if instance != "unknown":
            # REQUIRED, not decorative: "Host or entity identification is
            # required for Instana to accept OpenTelemetry logs"
            # (0307:338-352), and `service.instance.id` is on its accepted
            # list. `host.id` below is the other half, for the direct-to-SaaS
            # leg whose accepted set is narrower (0308:205).
            res["service.instance.id"] = instance
        if build != "unknown":
            res["service.version"] = build
        if host_id:
            res["host.id"] = host_id
        out.append(
            {
                "resource": {"attributes": _attrs(res)},
                "scopeLogs": [{"scope": {"name": SCOPE_NAME}, "logRecords": recs}],
            }
        )
    return {"resourceLogs": out}


def export_json(rows: list[dict]) -> str:
    return json.dumps(export(rows), separators=(",", ":"))

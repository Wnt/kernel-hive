"""Stored log rows -> OTLP/JSON `resourceLogs`, the logs export boundary.

THE SIBLING OF `traces_otlp.py`, deliberately: same hand-rolled OTLP/JSON, same
no-dependency posture, same `export(rows)` signature shape. It reuses that
module's value/attribute/nanosecond encoders rather than growing a second set —
an OTLP `KeyValue` is an OTLP `KeyValue` whichever signal carries it, and two
encoders would drift.

    COUPLING, stated for the merge: this module imports `_any_value`, `_attrs`
    and `_nanos` from `traces_otlp`. They are the only names it takes, none of
    them are touched here, and a rename on that side is a one-line fix here.

FIELD MAPPING — store column -> OTLP LogRecord field:

    ts_ms        -> timeUnixNano            (producer clock)
    observed_ms  -> observedTimeUnixNano    (ours: when the store took it)
    severity     -> severityText
    sev_num      -> severityNumber          (what sorts, and the fallback
                                             when the text is unrecognised)
    body         -> body.stringValue        (unaltered)
    trace_id     -> traceId  }  the join, unaltered; every OTel backend
    span_id      -> spanId   }  correlates a log to its span on these two.
    attrs        -> attributes
    service      -> resource service.name  (what a log is correlated to a
                                            SERVICE with)
    instance     -> resource service.instance.id (WHICH producer of that
                                            service — a tab, the box, a station)

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
#: exporter's, kept explicit because a wrong language tag sends an operator
#: looking for a Python stack in a browser's log.
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


def export(rows: list[dict]) -> dict:
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
            res["service.instance.id"] = instance
        if build != "unknown":
            res["service.version"] = build
        out.append(
            {
                "resource": {"attributes": _attrs(res)},
                "scopeLogs": [{"scope": {"name": SCOPE_NAME}, "logRecords": recs}],
            }
        )
    return {"resourceLogs": out}


def export_json(rows: list[dict]) -> str:
    return json.dumps(export(rows), separators=(",", ":"))

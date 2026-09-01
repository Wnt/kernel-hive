"""Stored vitals rows -> OTLP/JSON `resourceMetrics`, one entity per station.

THE SIBLING OF `logs_otlp.py` and `traces_otlp.py`: same hand-rolled OTLP/JSON,
same no-dependency posture, same `export(rows, host_id=...)` shape. It reuses
`traces_otlp`'s value/attribute/nanosecond encoders rather than growing a second
set — an OTLP `KeyValue` is an OTLP `KeyValue` whichever signal carries it.

    COUPLING, stated for the merge: this module imports `_attrs` and `_nanos`
    from `traces_otlp`. They are the only names it takes, neither is touched
    here, and a rename on that side is a one-line fix here.

WHY THIS MAKES EACH STATION AN ENTITY, which is the whole reason the export
exists in this shape. Instana builds a first-class monitored entity out of OTLP
METRICS ALONE — no spans required:

    "Instana creates an OpenTelemetry entity from the metrics data.
     OpenTelemetry spans automatically link to this entity by using the
     `service.name` and `service.instance.id` resource attributes... Correlation
     chain: OpenTelemetry span > OpenTelemetry entity > Host entity"
        — 0311-...-infrastructure-correlation.md:236-248

So the resource envelope below puts THE STATION ID in `service.instance.id`, and
that one choice is what turns 71 exhibits into 71 entities rather than one
service with a station label. They are reachable at Infrastructure > Analyze
infrastructure > OpenTelemetry, or by Dynamic Focus `entity.type:opentelemetry`
(0307-opentelemetry-signals.md:87-89).

SESSION IS A DATA-POINT ATTRIBUTE, NOT PART OF THE RESOURCE, and that is a
cardinality decision rather than a stylistic one. A session id is unbounded over
time; putting it in the resource would mint a new OpenTelemetry ENTITY for every
tab that ever opened a station, and entities are the thing an infrastructure
backend keeps forever. As an attribute it is a dimension on a point, which is
what it actually is.

THE INSTRUMENT KINDS ARE THE CATALOGUE'S, not this file's. Instana's acceptor
takes Gauge, Sum and Histogram (0307:90-94), and `vitals_schema.CATALOGUE` says
which each vital is. A cumulative counter exported as a gauge would render as a
line that only goes up and mean nothing; the catalogue is where that is decided
and this file only obeys it.

TEMPORALITY: `aggregationTemporality: 2` (CUMULATIVE) on every Sum, with
`isMonotonic: true`. That is the truth about these counters — the browser adds
to them from session start and never resets — and it is what lets a backend
compute a rate from two points. DELTA temporality would require this file to
diff consecutive samples, which it cannot do correctly across the page
boundaries the forwarder ships in.

ONE TIMESTAMP CAVEAT THAT IS NOT OURS TO FIX. "The metric timestamp that is
recorded for OpenTelemetry metrics is the timestamp of ingestion into Instana"
(0307:98) — our `timeUnixNano` is sent, correctly, and Instana replaces it with
its own. That is why the forward CADENCE matters more than this file does, and
why the vitals leg runs on its own short timer instead of riding the five-minute
trace forwarder; see `scripts/observability/instana_vitals.py`. Our own store
keeps the honest producer clock either way, which is the point of having one.
"""

from __future__ import annotations

import json

from traces_otlp import _attrs, _nanos
from vitals_schema import CATALOGUE

SERVICE_NAME = "kernel-hive-stream"
SCOPE_NAME = "kernel-hive"


def _points(rows: list[dict], column: str) -> list[dict]:
    """Every reading of ONE vital in this page, as OTLP NumberDataPoints.

    A row that has no value for this column contributes NO POINT — it is not
    zero. Half of every browser row is a column some other producer fills, and
    a zero there would be a measurement we did not make.
    """
    out = []
    for r in rows:
        v = (r.get("v") or {}).get(column)
        if v is None:
            continue
        attrs = {"kh.station.id": r.get("station") or "unknown", "kh.source": r.get("source") or "spa"}
        if r.get("sessionId") and r["sessionId"] != "unknown":
            attrs["session.id"] = r["sessionId"]
        out.append(
            {
                # startTimeUnixNano equals timeUnixNano for a gauge and is the
                # SESSION's start for a cumulative sum in a strict reading of
                # the spec. We do not know the session start from a row, and a
                # wrong start time makes a backend compute a wrong first rate,
                # so both are the sample time: a consumer that needs a rate
                # takes it from consecutive points, which is what Instana does.
                "startTimeUnixNano": _nanos(r["tsMs"]),
                "timeUnixNano": _nanos(r["tsMs"]),
                "asDouble": float(v),
                "attributes": _attrs(attrs),
            }
        )
    return out


def export(rows: list[dict], host_id: str | None = None) -> dict:
    """`{"resourceMetrics": [...]}` for a page of stored samples.

    Grouped by (station, build) — the tuple that defines the RESOURCE, i.e. the
    entity. Ungrouped, every point would repeat its whole resource envelope,
    which at our point sizes is most of the body; worse, a backend would have to
    reconcile several resources that mean the same entity.
    """
    groups: dict[tuple, list] = {}
    for r in rows:
        groups.setdefault((r.get("station") or "unknown", r.get("build") or "unknown"), []).append(r)
    out = []
    for (station, build), page in sorted(groups.items()):
        metrics = []
        for column, name, unit, kind in CATALOGUE:
            pts = _points(page, column)
            if not pts:
                continue
            body = {"dataPoints": pts}
            if kind == "sum":
                body["aggregationTemporality"] = 2  # CUMULATIVE
                body["isMonotonic"] = True
            metrics.append({"name": name, "unit": unit, kind: body})
        if not metrics:
            continue
        res = {
            "service.name": SERVICE_NAME,
            # THE LINE THAT MAKES A STATION AN ENTITY. See the module docstring.
            "service.instance.id": station,
            "telemetry.sdk.name": "kernel-hive",
            "telemetry.sdk.language": "webjs",
        }
        if build != "unknown":
            res["service.version"] = build
        if host_id:
            # The other half of the identity Instana requires. Gated by the
            # caller on the DESTINATION: the local host agent supplies host
            # identity itself, and a second, differently-derived one would be a
            # claim we cannot back. Same rule as the trace and log legs.
            res["host.id"] = host_id
        out.append(
            {
                "resource": {"attributes": _attrs(res)},
                "scopeMetrics": [{"scope": {"name": SCOPE_NAME}, "metrics": metrics}],
            }
        )
    return {"resourceMetrics": out}


def export_json(rows: list[dict]) -> str:
    return json.dumps(export(rows), separators=(",", ":"))

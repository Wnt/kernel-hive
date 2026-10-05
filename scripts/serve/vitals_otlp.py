"""Stored vitals rows -> OTLP/JSON `resourceMetrics`, one resource per station.

THE SIBLING OF `logs_otlp.py` and `traces_otlp.py`: same hand-rolled OTLP/JSON,
same no-dependency posture, same `export(rows)` shape. It reuses `traces_otlp`'s
value/attribute/nanosecond encoders rather than growing a second set — an OTLP
`KeyValue` is an OTLP `KeyValue` whichever signal carries it.

    COUPLING, stated for the merge: this module imports `_attrs` and `_nanos`
    from `traces_otlp`. They are the only names it takes, neither is touched
    here, and a rename on that side is a one-line fix here.

WHY EACH STATION IS ITS OWN RESOURCE, which is the whole reason the export
exists in this shape. The resource envelope below puts THE STATION ID in
`service.instance.id`, and that one choice is what turns 71 exhibits into 71
producers rather than one service with a station label — the same identity the
daemon's spans carry (`traces_otlp.py`), so a consumer that joins spans to
metrics by `service.instance.id` lands on the right machine.

SESSION IS A DATA-POINT ATTRIBUTE, NOT PART OF THE RESOURCE, and that is a
cardinality decision rather than a stylistic one. A session id is unbounded over
time; putting it in the resource would mint a new resource for every tab that
ever opened a station, and resources are the thing an infrastructure backend
keeps forever. As an attribute it is a dimension on a point, which is what it
actually is.

THE INSTRUMENT KINDS ARE THE CATALOGUE'S, not this file's. OTLP has Gauge, Sum
and Histogram, and `vitals_schema.CATALOGUE` says which each vital is. A
cumulative counter exported as a gauge would render as a line that only goes up
and mean nothing; the catalogue is where that is decided and this file only
obeys it.

TEMPORALITY: `aggregationTemporality: 2` (CUMULATIVE) on every Sum, with
`isMonotonic: true`. That is the truth about these counters — the browser adds
to them from session start and never resets — and it is what lets a backend
compute a rate from two points. DELTA temporality would require this file to
diff consecutive samples, which it cannot do correctly across the page
boundaries an export is cut at.
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
                # takes it from consecutive points.
                "startTimeUnixNano": _nanos(r["tsMs"]),
                "timeUnixNano": _nanos(r["tsMs"]),
                "asDouble": float(v),
                "attributes": _attrs(attrs),
            }
        )
    return out


def export(rows: list[dict]) -> dict:
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
            # THE LINE THAT MAKES A STATION ITS OWN RESOURCE. See the module
            # docstring.
            "service.instance.id": station,
            "telemetry.sdk.name": "kernel-hive",
            "telemetry.sdk.language": "webjs",
        }
        if build != "unknown":
            res["service.version"] = build
        out.append(
            {
                "resource": {"attributes": _attrs(res)},
                "scopeMetrics": [{"scope": {"name": SCOPE_NAME}, "metrics": metrics}],
            }
        )
    return {"resourceMetrics": out}


def export_json(rows: list[dict]) -> str:
    return json.dumps(export(rows), separators=(",", ":"))

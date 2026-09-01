"""The metric half of the forward: our bucketed counters as OTLP histograms.

Split out of `instana-forward.py` when that file hit its size cap. It is a pure
function of `analytics.db` and carries no destination, credential or watermark —
which is the seam: the trace half has a correctness argument
(`instana_backlog.py`), this half is a projection.
"""

from __future__ import annotations

import json
import sqlite3
import time

import traces_otlp


def metric_histograms(cfg, since_day: str) -> dict:
    """Our bucketed metrics as OTLP histograms.

    The bucket BOUNDARIES are our ladder, unchanged. Re-bucketing to something
    prettier would make Instana's histogram disagree with our own report, and
    the entire reason this exists is to compare the two on identical data.

    A caveat worth carrying: the counters have no per-sample timestamps, only a
    day bucket. So each day's histogram is emitted with that day's end as its
    time, which is honest at day resolution and would be a lie at any finer one.
    """
    db = sqlite3.connect(f"file:{cfg.analytics_db}?mode=ro", uri=True)
    try:
        rows = db.execute(
            "SELECT day,metric,bucket,class,SUM(n) FROM metric WHERE day>=? AND class IN "
            f"({','.join('?' * len(cfg.classes))}) GROUP BY day,metric,bucket,class",
            (since_day, *cfg.classes),
        ).fetchall()
    finally:
        db.close()

    by_key: dict[tuple, dict] = {}
    for day, metric, bucket, klass, n in rows:
        by_key.setdefault((day, metric, klass), {})[bucket] = n

    points = []
    for (day, metric, klass), buckets in sorted(by_key.items()):
        edges = sorted((b for b in buckets if b != "inf"), key=int)
        counts = [buckets.get(e, 0) for e in edges] + [buckets.get("inf", 0)]
        total = sum(counts)
        end_ns = str(int(time.mktime(time.strptime(day, "%Y-%m-%d")) + 86400) * 1_000_000_000)
        points.append(
            {
                "metric": metric,
                "point": {
                    "startTimeUnixNano": str(int(time.mktime(time.strptime(day, "%Y-%m-%d"))) * 1_000_000_000),
                    "timeUnixNano": end_ns,
                    "count": str(total),
                    "explicitBounds": [float(e) for e in edges],
                    "bucketCounts": [str(c) for c in counts],
                    "attributes": traces_otlp._attrs({"kh.class": klass}),
                },
            }
        )

    grouped: dict[str, list] = {}
    for p in points:
        grouped.setdefault(p["metric"], []).append(p["point"])
    return (
        {
            "resourceMetrics": [
                {
                    "resource": {"attributes": traces_otlp._attrs({"service.name": "kernel-hive-spa"})},
                    "scopeMetrics": [
                        {
                            "scope": {"name": "kernel-hive"},
                            "metrics": [
                                {
                                    "name": name,
                                    "unit": "ms" if name.endswith("Ms") else ("%" if name.endswith("Pct") else "1"),
                                    "histogram": {"aggregationTemporality": 2, "dataPoints": pts},
                                }
                                for name, pts in sorted(grouped.items())
                            ],
                        }
                    ],
                }
            ]
        }
        if grouped
        else {}
    )


def forward_metrics(cfg, dest, post, dry_run: bool, verbose: bool, days: int) -> int:
    """Ship the day-resolution histograms to `/v1/metrics`.

    MOVED HERE FROM `instana-forward.py` when the vitals leg landed, for the
    reason `forward_logs` lives in `instana_logs.py`: that file is at its line
    budget, and a leg's shipping function belongs beside the projection it
    ships. `cfg`, `dest` and `post` are injected rather than imported, so this
    module still has no cycle with the script that owns them.

    THIS IS THE DAY-RESOLUTION LANE, and it shares a URL with the vitals leg
    and nothing else. The counters behind it carry no per-sample timestamp, so
    one point per day is the finest thing it can honestly say. Continuous
    stream health is the OTHER lane (`instana_vitals.py`), which samples at
    seconds and forwards on its own timer; do not merge them, and do not
    "improve" this one's resolution — there is no finer data underneath it.
    """
    since = time.strftime("%Y-%m-%d", time.gmtime(time.time() - days * 86400))
    doc = metric_histograms(cfg, since)
    if not doc:
        print(f"metrics [{dest.name}]: nothing to send")
        return 0
    n = sum(len(m["histogram"]["dataPoints"]) for m in doc["resourceMetrics"][0]["scopeMetrics"][0]["metrics"])
    if verbose or dry_run:
        print(json.dumps(doc, indent=2)[:4000])
    ok, detail = post(cfg, dest, "/v1/metrics", doc, dry_run)
    print(f"metrics [{dest.name}]: {n} data point(s) -> {detail}")
    return 0 if ok else 1

#!/usr/bin/env python3
"""Summarize Stage-D JSONL cells with explicit nearest-rank percentiles."""

import argparse
import csv
import json
import math
import statistics
from collections import Counter
from pathlib import Path


def nearest_rank(values, percentile):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percentile * len(ordered)) - 1)]


def summarize(path):
    rows = [json.loads(line) for line in Path(path).read_text().splitlines() if line]
    if not rows:
        raise ValueError(f"empty input: {path}")
    ok = [row["latency_us"] for row in rows if row["status"] == "ok"]
    status = Counter(row["status"] for row in rows)
    result = {
        "path": rows[0]["path"],
        "condition": rows[0]["condition"],
        "attempts": len(rows),
        "successes": len(ok),
        "misses": len(rows) - len(ok),
        "miss_rate": (len(rows) - len(ok)) / len(rows),
        "status_counts": dict(sorted(status.items())),
        "stable_before_false": sum(not row["stable_before"] for row in rows),
        "directions": dict(sorted(Counter(row["direction"] for row in rows).items())),
    }
    if ok:
        p50 = nearest_rank(ok, 0.50)
        p95 = nearest_rank(ok, 0.95)
        p99 = nearest_rank(ok, 0.99)
        result.update({
            "p50_us": p50,
            "p95_us": p95,
            "p99_us": p99,
            "p99_minus_p50_us": p99 - p50,
            "max_us": max(ok),
            "mad_us": statistics.median(abs(value - statistics.median(ok)) for value in ok),
            "stddev_us": statistics.pstdev(ok),
        })
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+")
    parser.add_argument("--json", required=True)
    parser.add_argument("--csv", required=True)
    args = parser.parse_args()
    cells = [summarize(path) for path in args.inputs]
    by_key = {(cell["path"], cell["condition"]): cell for cell in cells}
    ratios = {}
    for condition in sorted({cell["condition"] for cell in cells}):
        warpd = by_key[("warpd", condition)]
        ghid = by_key[("ghid", condition)]
        ratios[condition] = {
            "ghid_over_warpd_p95": ghid["p95_us"] / warpd["p95_us"],
            "ghid_over_warpd_p99": ghid["p99_us"] / warpd["p99_us"],
            "p95_reduction_percent": 100 * (1 - ghid["p95_us"] / warpd["p95_us"]),
            "p99_reduction_percent": 100 * (1 - ghid["p99_us"] / warpd["p99_us"]),
        }
    document = {
        "percentile_method": "nearest-rank over successful latency_us values; misses separately rank as failures",
        "cells": cells,
        "ratios": ratios,
    }
    Path(args.json).write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    fields = [
        "path", "condition", "attempts", "successes", "misses", "miss_rate",
        "p50_us", "p95_us", "p99_us", "p99_minus_p50_us", "max_us",
        "mad_us", "stddev_us", "stable_before_false",
    ]
    with Path(args.csv).open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(cells)
    print(json.dumps(document, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

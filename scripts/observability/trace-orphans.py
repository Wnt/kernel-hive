#!/usr/bin/env python3
"""trace-orphans — how many stored spans name a parent that does not exist.

    scripts/observability/trace-orphans.py                  # last 6 h, live store
    scripts/observability/trace-orphans.py --hours 24
    scripts/observability/trace-orphans.py --max-rate 0.02  # exit 1 above 2%
    scripts/observability/trace-orphans.py --json

WHY THIS IS A TOOL AND NOT A ONE-OFF QUERY. A span whose `parent_id` names
nothing renders in Instana as "the root call of the trace is missing or has
not yet arrived in the processing pipeline", and NOTHING ELSE SHOWS IT. Every
individual span looks perfect, every request it describes succeeded, and only
the join between them is broken — so the failure is invisible in the access
log, invisible in the span list, and invisible in any latency number. It went
unmeasured until an operator wrote this query by hand on 2026-09-01 and found
**42.9%** of a six-hour window in that state: 2,839 spans of 6,620, under 577
distinct parent ids that had never been stored.

Both producers were in the browser and both are fixed (docs/lab/TRACE-CONTEXT.md
§8, `spa/src/analytics/trace.ts`). This exists so the next regression is a
number somebody sees, not an afternoon of SQL.

WHAT IT DOES NOT COUNT: the recent edge. A parent that is merely still OPEN —
a flow the visitor has not finished — is a transient orphan that resolves the
moment the root span ends, so counting it would measure how busy the box is
rather than whether the contract holds. `--settle-hours` (default 1) is the
gap; the store's own `orphans()` owns the rule, so this script and any other
reader cannot disagree about it.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

DEFAULT_DB = Path("/data/vms/streamhost/serve/traces.db")

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "serve"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", type=Path, default=DEFAULT_DB, help=f"trace store (default {DEFAULT_DB})")
    ap.add_argument("--hours", type=float, default=6.0, help="window, in hours (default 6)")
    ap.add_argument("--settle-hours", type=float, default=1.0, help="ignore spans newer than this (default 1)")
    ap.add_argument("--max-rate", type=float, default=None, help="exit 1 when the rate exceeds this (0..1)")
    ap.add_argument("--json", action="store_true", help="emit the report as JSON")
    args = ap.parse_args(argv)

    if not args.db.exists():
        print(f"trace-orphans: no store at {args.db}", file=sys.stderr)
        return 2

    import traces  # noqa: PLC0415 - the sys.path above has to be set first

    # READ-ONLY: a report must never migrate the file the serving plane is
    # writing (an untested sqlite migration crash-looped it once already).
    store = traces.TraceStore(args.db, read_only=True)
    try:
        since = int((time.time() - args.hours * 3600) * 1000)
        report = store.orphans(since, settle_ms=int(args.settle_hours * 3600 * 1000))
    finally:
        store.close()

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        pct = report["rate"] * 100
        print(f"window    last {args.hours:g} h, ignoring the last {args.settle_hours:g} h")
        print(f"spans     {report['withParent']} declaring a parent")
        print(f"ORPHANED  {report['orphaned']}  ({pct:.1f}%)")
        if report["byName"]:
            print("\nby span name:")
            for row in report["byName"]:
                print(f"  {row['n']:6d}  {row['name']}")
        else:
            print("\nevery declared parent is in the store.")

    if args.max_rate is not None and report["rate"] > args.max_rate:
        print(
            f"\ntrace-orphans: FAIL — {report['rate'] * 100:.1f}% exceeds the "
            f"{args.max_rate * 100:.1f}% budget. Something is emitting a "
            f"traceparent naming a span it never records (TRACE-CONTEXT.md §8).",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

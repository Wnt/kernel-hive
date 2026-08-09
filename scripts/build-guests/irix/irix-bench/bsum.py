#!/usr/bin/env python3
"""Aggregate irixbench runs: median, CI, and the checks a result has to pass.

Means are not reported. The distribution here is skewed and a single perturbed
run has previously moved an arm mean by >10% on this workload; the median and a
percentile bootstrap interval survive that, an average does not.

Three guards run before anything is summarised, because each one has produced a
retracted result on this project:

  * GHz family     -- cycnorm INVERTS a clock change. Runs whose achieved GHz is
                      more than GHZ_TOL from the cohort median are DISCARDED.
  * foreign CPU    -- a busy SMT sibling costs MAME ~39%. Windows over
                      FOREIGN_MAX percent foreign occupancy are DISCARDED.
  * sample size    -- fewer than 5 surviving runs is reported as such, not
                      quietly summarised.

  bsum.py <run-dir> [<run-dir> ...]
"""

import json
import os
import random
import statistics
import sys

GHZ_TOL = 0.03  # fraction
FOREIGN_MAX = 15.0  # percent of the claimed pair
MIN_N = 5


def bootstrap_ci(xs, n=2000, lo=2.5, hi=97.5):
    if len(xs) < 2:
        return (float("nan"), float("nan"))
    rng = random.Random(20260803)
    meds = sorted(statistics.median(rng.choices(xs, k=len(xs))) for _ in range(n))
    return (meds[int(len(meds) * lo / 100)], meds[int(len(meds) * hi / 100)])


def main() -> int:
    rows = []
    for d in sys.argv[1:]:
        p = os.path.join(d, "result.json")
        if not os.path.exists(p):
            print(f"{d}: no result.json - run bwin.py --json first")
            continue
        with open(p, encoding="utf-8") as fh:
            for r in json.load(fh):
                r["run"] = os.path.basename(d.rstrip("/"))
                rows.append(r)
    if not rows:
        return 1

    ghz_med = statistics.median(r["ghz"] for r in rows)
    kept, dropped = [], []
    for r in rows:
        if abs(r["ghz"] - ghz_med) / ghz_med > GHZ_TOL:
            dropped.append((r, f"clock {r['ghz']:.3f} GHz out of family (median {ghz_med:.3f})"))
        elif r.get("foreign_pct") is not None and r["foreign_pct"] > FOREIGN_MAX:
            dropped.append((r, f"foreign CPU {r['foreign_pct']:.1f}% on the claimed pair"))
        else:
            kept.append(r)
    for r, why in dropped:
        print(f"DISCARDED {r['run']} {r['window']}: {why}")

    print(f"\n{'window':<12}{'n':>3}{'median%':>10}{'CI95':>18}{'IQR':>8}{'GHz':>8}{'IPC':>7}{'foreign%':>10}")
    for w in sorted({r["window"] for r in kept}):
        rs = [r for r in kept if r["window"] == w]
        xs = sorted(r["cycnorm"] for r in rs)
        lo, hi = bootstrap_ci(xs)
        q = statistics.quantiles(xs, n=4) if len(xs) >= 4 else [xs[0], xs[0], xs[-1]]
        flag = "" if len(rs) >= MIN_N else f"  <-- n<{MIN_N}, do not believe a delta under 10%"
        print(
            f"{w:<12}{len(rs):>3}{statistics.median(xs):>10.2f}"
            f"{f'[{lo:.2f}, {hi:.2f}]':>18}{q[2] - q[0]:>8.2f}"
            f"{statistics.median(r['ghz'] for r in rs):>8.3f}"
            f"{statistics.median(r['ipc'] for r in rs):>7.3f}"
            f"{statistics.median(r['foreign_pct'] or 0 for r in rs):>10.1f}{flag}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

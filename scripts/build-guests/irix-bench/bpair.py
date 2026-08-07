#!/usr/bin/env python3
"""Paired A/B for irixbench runs: median of PAIRED within-round ratios.

Why paired and not two cohort medians: the box is shared and its speed drifts
over a measurement session (siblings come and go, the package clock moves).
Comparing arm A's runs against arm B's runs made an hour later has produced
retracted results on this project. A round runs both arms under the same box
conditions, the ratio is formed WITHIN the round, and only the ratios are
pooled.

Run directories are named <arm><round>, e.g. ctl1/fr1, ctl2/fr2. Each must
already carry a result.json (bwin.py --json), and each window is compared only
against the same window of its own round.

The same three guards bsum.py applies run first, and they apply to the PAIR: if
either side of a round is discarded, the round is dropped whole -- a ratio
against a perturbed control is worse than no ratio.

  bpair.py --a=ctl --b=fr <run-dir> [<run-dir> ...]
"""

import json
import os
import random
import re
import statistics
import sys

GHZ_TOL = 0.03  # fraction, vs the cohort median
FOREIGN_MAX = 15.0  # percent of the claimed pair
MIN_N = 5


def bootstrap_ci(xs, n=20000, lo=2.5, hi=97.5):
    if len(xs) < 2:
        return (float("nan"), float("nan"))
    rng = random.Random(20260803)
    meds = sorted(statistics.median(rng.choices(xs, k=len(xs))) for _ in range(n))
    return (meds[int(len(meds) * lo / 100)], meds[int(len(meds) * hi / 100)])


def load(dirs, arm_a, arm_b):
    """{(round, window): {arm: row}} plus the reasons anything was dropped."""
    rows = []
    for d in dirs:
        p = os.path.join(d, "result.json")
        if not os.path.exists(p):
            print(f"{d}: no result.json - run bwin.py --json first")
            continue
        name = os.path.basename(d.rstrip("/"))
        m = re.match(rf"^({re.escape(arm_a)}|{re.escape(arm_b)})(.+)$", name)
        if not m:
            print(f"{d}: name is not <arm><round> for arms {arm_a}/{arm_b} - skipped")
            continue
        with open(p, encoding="utf-8") as fh:
            for r in json.load(fh):
                r["arm"], r["round"], r["run"] = m.group(1), m.group(2), name
                rows.append(r)
    return rows


def main() -> int:
    arm_a, arm_b, dirs = "ctl", "fr", []
    for arg in sys.argv[1:]:
        if arg.startswith("--a="):
            arm_a = arg[4:]
        elif arg.startswith("--b="):
            arm_b = arg[4:]
        else:
            dirs.append(arg)
    rows = load(dirs, arm_a, arm_b)
    if not rows:
        return 1

    ghz_med = statistics.median(r["ghz"] for r in rows)
    bad = set()
    for r in rows:
        why = None
        if abs(r["ghz"] - ghz_med) / ghz_med > GHZ_TOL:
            why = f"clock {r['ghz']:.3f} GHz out of family (median {ghz_med:.3f})"
        elif r.get("foreign_pct") is not None and r["foreign_pct"] > FOREIGN_MAX:
            why = f"foreign CPU {r['foreign_pct']:.1f}% on the claimed pair"
        if why:
            print(f"DISCARDED round {r['round']} window {r['window']} ({r['run']}): {why}")
            bad.add((r["round"], r["window"]))

    pairs = {}
    for r in rows:
        if (r["round"], r["window"]) in bad:
            continue
        pairs.setdefault((r["round"], r["window"]), {})[r["arm"]] = r

    print(
        f"\n{'window':<12}{'n':>3}{'A median%':>11}{'B median%':>11}"
        f"{'paired':>9}{'CI95':>20}{'pos':>7}{'GHz A':>8}{'GHz B':>8}"
    )
    for w in sorted({w for (_, w) in pairs}):
        ratios, a_vals, b_vals, ga, gb = [], [], [], [], []
        for (_rnd, win), d in sorted(pairs.items()):
            if win != w or arm_a not in d or arm_b not in d:
                continue
            ratios.append(100.0 * (d[arm_b]["cycnorm"] / d[arm_a]["cycnorm"] - 1.0))
            a_vals.append(d[arm_a]["cycnorm"])
            b_vals.append(d[arm_b]["cycnorm"])
            ga.append(d[arm_a]["ghz"])
            gb.append(d[arm_b]["ghz"])
        if not ratios:
            continue
        lo, hi = bootstrap_ci(ratios)
        flag = "" if len(ratios) >= MIN_N else f"  <-- n<{MIN_N}, do not believe a delta under 10%"
        print(
            f"{w:<12}{len(ratios):>3}{statistics.median(a_vals):>11.2f}"
            f"{statistics.median(b_vals):>11.2f}{statistics.median(ratios):>+8.1f}%"
            f"{f'[{lo:+.1f}, {hi:+.1f}]':>20}"
            f"{f'{sum(1 for x in ratios if x > 0)}/{len(ratios)}':>7}"
            f"{statistics.median(ga):>8.3f}{statistics.median(gb):>8.3f}{flag}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

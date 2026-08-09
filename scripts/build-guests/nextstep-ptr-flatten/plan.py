#!/usr/bin/env python3
"""Feed-forward event planner for the NeXT relative pointer.

Emits `relmove` lines that move the NeXT cursor by exactly (dx, dy) guest
pixels, given the measured guest-side scaling table.

  usage: plan.py DX DY [gap_us] [--flat]

The default table is the one MEASURED on the shipped tile (NeXTSTEP
`MouseScaling` level 3): out = delta * factor, factor chosen by the LAST
threshold the delta is strictly greater than.
    thresholds 2 3 4 5 6 -> factors 2 4 6 8 10, else 1
`--flat` assumes the flattened table (factor 1 everywhere), where the only
constraint left is the NeXT KMS register's signed 6-bit delta limit of 63.
"""
import sys

THRESH = [(6, 10), (5, 8), (4, 6), (3, 4), (2, 2)]


def factor(d):
    for t, f in THRESH:
        if d > t:
            return f
    return 1


def outputs(flat):
    """Reachable single-event cursor displacements, largest first."""
    if flat:
        return [(d, d) for d in range(63, 0, -1)]
    seen = {}
    for d in range(1, 64):
        seen.setdefault(d * factor(d), d)
    return sorted(((o, d) for o, d in seen.items()), reverse=True)


def plan_axis(delta, flat):
    """Greedy decomposition of one axis into single events."""
    tbl = outputs(flat)
    out = []
    rem = abs(delta)
    sign = 1 if delta >= 0 else -1
    while rem > 0:
        for o, d in tbl:
            if o <= rem:
                out.append(sign * d)
                rem -= o
                break
        else:
            break
    return out


def main():
    dx, dy = int(sys.argv[1]), int(sys.argv[2])
    gap = int(sys.argv[3]) if len(sys.argv) > 3 else 30000
    flat = "--flat" in sys.argv
    ev = [(e, 0) for e in plan_axis(dx, flat)] + [(0, e) for e in plan_axis(dy, flat)]
    for a, b in ev:
        print(f"{a} {b} {gap}")


if __name__ == "__main__":
    main()

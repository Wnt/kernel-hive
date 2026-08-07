#!/usr/bin/env python3
"""Per-phase emulation speed for an irixbench.sh run.

Reports, for every window measured WITHIN one run:

  cycnorm%   emulated_secs / (cycles / 2.5e9) -- the only speed metric used on
             this exhibit. MAME's own "Average speed %" is wall-clock based and
             is not comparable across a shared box.
  GHz        cycles / task-clock. Reported ALWAYS and next to cycnorm, because
             cycnorm does not ignore a clock change, it INVERTS it: a 1.5 GHz
             run once scored +20% cycnorm while running 28% slower in real time.
             A run whose GHz is out of family with its siblings is discarded.
  foreign%   CPU burnt on the claimed core pair by anything that is not this
             MAME process. A busy SMT sibling costs MAME ~39%, so a window with
             meaningful foreign occupancy is not a valid sample.

  bwin.py <run-dir> [--emuwin=40-110,110-180] [--json]
"""

import json
import os
import sys

REF_HZ = 2.5e9
USER_HZ = 100.0
WRAPPERS = ("perf", "taskset")


def read_lines(path):
    with open(path, encoding="utf-8") as fh:
        return fh.readlines()


def read_perf(path, epoch):
    """perf stat -I 1000 -x, rows: <t>,<count>,<unit>,<event>,<runtime>,<pct>.

    `t` is seconds since perf started, so the recorded launch epoch turns it
    into the same host clock the phase markers are written in.
    """
    rows = []
    for line in read_lines(path):
        parts = line.strip().split(",")
        if len(parts) < 4:
            continue
        try:
            rows.append((epoch + float(parts[0]), parts[3], float(parts[1])))
        except ValueError:
            continue
    return rows


def sum_between(rows, event, lo, hi):
    return sum(c for (t, e, c) in rows if e == event and lo < t <= hi)


def emu_at(trace, wall):
    """Emulated time at a host instant, linearly interpolated in the trace."""
    prev = None
    for w, e in trace:
        if w >= wall:
            if prev is None or w == prev[0]:
                return e
            pw, pe = prev
            return pe + (e - pe) * (wall - pw) / (w - pw)
        prev = (w, e)
    return trace[-1][1] if trace else None


def wall_at(trace, emu):
    """Host instant at an emulated time -- the inverse of emu_at."""
    prev = None
    for w, e in trace:
        if e >= emu:
            if prev is None or e == prev[1]:
                return w
            pw, pe = prev
            return pw + (w - pw) * (emu - pe) / (e - pe)
        prev = (w, e)
    return None


def read_cpustat(path):
    """Cumulative busy seconds across the claimed pair, sampled once a second."""
    out = []
    for line in read_lines(path):
        ts, _, rest = line.partition(" ")
        try:
            t = float(ts)
        except ValueError:
            continue
        busy = 0.0
        for chunk in rest.split("|"):
            f = chunk.split()
            if len(f) < 8 or not f[0].startswith("cpu"):
                continue
            vals = [float(v) for v in f[1:8]]
            busy += sum(vals) - vals[3] - vals[4]  # total minus idle and iowait
        out.append((t, busy / USER_HZ))
    return out


def busy_between(cs, lo, hi):
    a = b = None
    for t, v in cs:
        if t <= lo:
            a = v
        if b is None and t >= hi:
            b = v
    return None if a is None or b is None else b - a


def load_marks(d, trace, emuwins):
    marks = {}
    for ln in read_lines(os.path.join(d, "phases.txt")):
        name, kind, t = ln.split()
        marks.setdefault(name, {})[kind] = float(t)
    # Fixed EMULATED-time windows. The boot and early-desktop regimes have no
    # host-side marker to hang a phase off, but they are perfectly well defined
    # in emulated time -- and converting them through THIS run's own trace keeps
    # the windowing within the run, which is the only valid way here.
    for w in emuwins:
        a, b = (float(v) for v in w.split("-"))
        wa, wb = wall_at(trace, a), wall_at(trace, b)
        if wa is None or wb is None:
            print(f"emu {w} - not reached in this run, discarded")
            continue
        marks[f"emu{w}"] = {"start": wa, "end": wb}
    return marks


def main() -> int:
    d = sys.argv[1]
    emuwins = []
    for arg in sys.argv[2:]:
        if arg.startswith("--emuwin="):
            emuwins += arg[len("--emuwin=") :].split(",")

    with open(os.path.join(d, "perf.epoch"), encoding="utf-8") as fh:
        epoch = float(fh.read().strip())
    perf = read_perf(os.path.join(d, "perf.csv"), epoch)
    trace = [tuple(float(x) for x in ln.split()) for ln in read_lines(os.path.join(d, "trace.txt")) if ln.strip()]
    cpath = os.path.join(d, "cpustat.txt")
    cs = read_cpustat(cpath) if os.path.exists(cpath) else []

    results = []
    head = ("window", "wall_s", "emu_s", "cycnorm%", "GHz", "IPC", "foreign%")
    print("{:<12}{:>9}{:>10}{:>11}{:>9}{:>8}{:>10}".format(*head))
    for name, m in load_marks(d, trace, emuwins).items():
        if "start" not in m or "end" not in m:
            print(f"{name:<12}INCOMPLETE - discarded")
            continue
        # Drop a second at each edge: the markers are host epochs and perf's 1 s
        # buckets do not align with them, so the edge buckets straddle the edge.
        lo, hi = m["start"] + 1.0, m["end"] - 1.0
        cyc = sum_between(perf, "cycles", lo, hi)
        ins = sum_between(perf, "instructions", lo, hi)
        tc = sum_between(perf, "task-clock", lo, hi) / 1000.0  # msec -> s
        emu_lo, emu_hi = emu_at(trace, lo), emu_at(trace, hi)
        if not cyc or not tc or emu_lo is None or emu_hi is None:
            print(f"{name:<12}NO DATA - discarded")
            continue
        emu = emu_hi - emu_lo
        row = {
            "window": name,
            "wall_s": hi - lo,
            "emu_s": emu,
            "cycnorm": 100.0 * emu / (cyc / REF_HZ),
            "ghz": cyc / tc / 1e9,
            "ipc": ins / cyc,
        }
        fb = busy_between(cs, lo, hi)
        row["foreign_pct"] = None if fb is None else 100.0 * max(0.0, fb - tc) / (hi - lo)
        foreign = "-" if row["foreign_pct"] is None else f"{row['foreign_pct']:.1f}"
        print(
            f"{name:<12}{row['wall_s']:>9.1f}{emu:>10.2f}{row['cycnorm']:>11.2f}"
            f"{row['ghz']:>9.3f}{row['ipc']:>8.3f}{foreign:>10}"
        )
        results.append(row)
    if "--json" in sys.argv:
        with open(os.path.join(d, "result.json"), "w", encoding="utf-8") as fh:
            json.dump(results, fh, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())

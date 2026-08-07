#!/usr/bin/env python3
"""Timeline report for a slowrig.sh run: speed and guest event rates per window.

Each window of the run produced two sub-windows -- a SPEED one with nothing
attached, and a CENSUS one (`<label>-c`) with kernel uprobes counting the
guest's ASID changes and TLB writes. This joins them:

  cycnorm%   emulated_secs / (cycles / 2.5e9), from the speed sub-window only.
  GHz        cycles / task-clock, reported always: cycnorm INVERTS a clock
             change rather than ignoring it.
  asid/s     ASID-change and TLB-write events per EMULATED second, from the
             census sub-window. Per emulated second, not per wall second: a wall
             rate falls when the emulator slows down even if the guest is doing
             exactly the same thing, which is the opposite of what is being
             asked here.

The point of the report is the COLUMN OF post* ROWS against the pre* rows: same
run, same guest, same core pair, nothing running in either.

  swin.py <run-dir> [--json]
"""

import json
import os
import sys

REF_HZ = 2.5e9
EVENTS = ("asid", "tlbwi", "tlbwr", "cmpint")
BENCH_RIG = os.environ.get("IRIX_BENCH_RIG", "/data/vms/soltest/irix-baseline-b7f2/rig")
sys.path.insert(0, BENCH_RIG)

import bwin  # noqa: E402  (path has to be set before the import)


def read_census(path):
    """perf stat -x, rows: <count>,<unit>,<event>,<runtime>,<pct>."""
    out = {}
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            parts = line.strip().split(",")
            if len(parts) < 3:
                continue
            ev = parts[2].split(":")[-1]
            try:
                out[ev] = float(parts[0])
            except ValueError:
                continue
    return out


def main() -> int:
    d = sys.argv[1]
    with open(os.path.join(d, "perf.epoch"), encoding="utf-8") as fh:
        epoch = float(fh.read().strip())
    perf = bwin.read_perf(os.path.join(d, "perf.csv"), epoch)
    trace = [tuple(float(x) for x in ln.split()) for ln in bwin.read_lines(os.path.join(d, "trace.txt")) if ln.strip()]
    cpath = os.path.join(d, "cpustat.txt")
    cs = bwin.read_cpustat(cpath) if os.path.exists(cpath) else []
    marks = bwin.load_marks(d, trace, [])

    rows = []
    print(
        "{:<10}{:>9}{:>10}{:>9}{:>8}{:>9}{:>10}{:>10}{:>9}".format(
            "window", "emu_s", "cycnorm%", "GHz", "IPC", "foreign%", "asid/emus", "tlbwi/emus", "cmpint/s"
        )
    )
    for name, m in marks.items():
        if name.endswith("-c") or "start" not in m or "end" not in m:
            continue
        lo, hi = m["start"] + 1.0, m["end"] - 1.0
        cyc = bwin.sum_between(perf, "cycles", lo, hi)
        ins = bwin.sum_between(perf, "instructions", lo, hi)
        tc = bwin.sum_between(perf, "task-clock", lo, hi) / 1000.0
        emu_lo, emu_hi = bwin.emu_at(trace, lo), bwin.emu_at(trace, hi)
        if not cyc or not tc or emu_lo is None or emu_hi is None:
            print(f"{name:<10}NO DATA - discarded")
            continue
        emu = emu_hi - emu_lo
        row = {
            "window": name,
            "emu_s": emu,
            "cycnorm": 100.0 * emu / (cyc / REF_HZ),
            "ghz": cyc / tc / 1e9,
            "ipc": ins / cyc,
        }
        fb = bwin.busy_between(cs, lo, hi)
        row["foreign_pct"] = None if fb is None else 100.0 * max(0.0, fb - tc) / (hi - lo)

        cm = marks.get(name + "-c", {})
        cev = read_census(os.path.join(d, f"census-{name}.csv"))
        cemu = None
        if "start" in cm and "end" in cm:
            a, b = bwin.emu_at(trace, cm["start"]), bwin.emu_at(trace, cm["end"])
            if a is not None and b is not None and b > a:
                cemu = b - a
        row["census_emu_s"] = cemu
        for ev in EVENTS:
            row[ev + "_per_emus"] = None if not cemu else cev.get(ev, 0.0) / cemu

        def fmt(key, digits=0, row=row):
            v = row.get(key)
            return "-" if v is None else f"{v:.{digits}f}"

        print(
            f"{name:<10}{emu:>9.2f}{row['cycnorm']:>10.2f}{row['ghz']:>9.3f}"
            f"{row['ipc']:>8.3f}{fmt('foreign_pct', 1):>9}"
            f"{fmt('asid_per_emus'):>10}{fmt('tlbwi_per_emus'):>10}{fmt('cmpint_per_emus'):>9}"
        )
        rows.append(row)
    if "--json" in sys.argv:
        with open(os.path.join(d, "timeline.json"), "w", encoding="utf-8") as fh:
            json.dump(rows, fh, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""De-bridging spike: per-arm CPU cost, sampled from /proc, interleaved.

Answers the cheap question the latency campaign cannot answer quickly: does
de-bridging remove REAL WORK at all? If the two arms cost the same CPU for the
same published surface, no latency campaign is going to find a bridge delta
either.

Interleaved A/B/A/B blocks, like the latency campaign and for the same reason:
the box is shared, and a paired delta measured inside one block survives drift
that sequential blocks would bake in.

Processes are resolved through /proc/<pid>/exe, never by cmdline -- a cmdline
scan from an ssh session matches the scanning shell itself.
"""

import json
import os
import sys
import time

RIG = "/data/vms/soltest/debridge-7f3a"
HZ = os.sysconf("SC_CLK_TCK")

ARMS = {
    "armA": [
        ("qemu", RIG + "/armA/qemu.pid"),
        ("streamhost", RIG + "/armA/streamhost.pid"),
    ],
    "armB": [
        ("mame", RIG + "/armB/mame.pid"),
        ("streamhost", RIG + "/armB/streamhost.pid"),
    ],
}


def pid_of(pidfile):
    with open(pidfile) as fh:
        return int(fh.read().strip())


def exe(pid):
    try:
        return os.readlink(f"/proc/{pid}/exe")
    except OSError:
        return None


def cputime(pid):
    """utime+stime+children, in seconds."""
    with open(f"/proc/{pid}/stat") as fh:
        fields = fh.read().rsplit(") ", 1)[1].split()
    # after the comm field: state is [0]; utime is index 11, stime 12
    return (int(fields[11]) + int(fields[12])) / HZ


def loadavg():
    with open("/proc/loadavg") as fh:
        return float(fh.read().split()[0])


def mhz():
    total = n = 0
    with open("/proc/cpuinfo") as fh:
        for line in fh:
            if line.startswith("cpu MHz"):
                total += float(line.split(":")[1])
                n += 1
    return round(total / n, 1) if n else None


def sample(arm, secs):
    procs = []
    for name, pidfile in ARMS[arm]:
        pid = pid_of(pidfile)
        procs.append((name, pid, exe(pid), cputime(pid)))
    t0 = time.time()
    load0 = loadavg()
    time.sleep(secs)
    wall = time.time() - t0
    out = {"arm": arm, "wall_s": round(wall, 2), "load": [load0, loadavg()], "mhz": mhz()}
    total = 0.0
    for name, pid, path, t_before in procs:
        pct = 100.0 * (cputime(pid) - t_before) / wall
        total += pct
        out[name] = {"pid": pid, "exe": path, "cpu_pct": round(pct, 1)}
    out["total_cpu_pct"] = round(total, 1)
    return out


def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
    rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    rows = []
    for r in range(rounds):
        for arm in ("armA", "armB"):
            s = sample(arm, secs)
            s["round"] = r + 1
            rows.append(s)
            print(json.dumps(s))
    print()
    for arm in ("armA", "armB"):
        vals = [r["total_cpu_pct"] for r in rows if r["arm"] == arm]
        print(f"{arm} total cpu% per round: {vals}   median {sorted(vals)[len(vals) // 2]:.1f}")
    paired = [rows[2 * i]["total_cpu_pct"] - rows[2 * i + 1]["total_cpu_pct"] for i in range(rounds)]
    print("within-round paired delta (A - B), cpu%%: %s" % [round(v, 1) for v in paired])


if __name__ == "__main__":
    main()

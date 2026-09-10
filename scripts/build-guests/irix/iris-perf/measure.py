#!/usr/bin/env python3
"""measure.py --tag T --qmp SOCK --ssh PORT [--skip-cpu] — one measurement pass on
an indyr4400 clone. Prints a JSON line. Runs ON labhost.
  cpu   : host wall-clock of a fixed awk loop inside IRIX (via iexec.py over the
          kiosk's telnet SCC channel), guest-clock ratio over the same window
  load  : iris %CPU inside the kiosk (ps) at the idle desktop
  mouse : (a) single QMP rel move -> first framebuffer change (latency, ms)
          (b) 60 rel moves at 20 ms -> cursor track: settle time after the last
              event, distinct positions seen, total displacement
Cursor position = centroid of the diff vs the pre-move frame (static desktop:
only the sprite moves)."""

import argparse
import json
import os
import socket
import subprocess
import time

import numpy as np
from PIL import Image

KEY = "/data/vms/bridge/bridge_key"


class QMP:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.f = self.s.makefile("rwb", buffering=0)
        self._recv()
        self.cmd("qmp_capabilities")

    def _recv(self):
        while True:
            line = self.f.readline()
            if not line:
                raise EOFError
            m = json.loads(line)
            if "event" in m:
                continue
            return m

    def cmd(self, name, **args):
        self.f.write((json.dumps({"execute": name, "arguments": args}) + "\n").encode())
        r = self._recv()
        if "error" in r:
            raise RuntimeError(r["error"])
        return r.get("return")

    def shot(self, path):
        self.cmd("screendump", filename=path)
        return np.asarray(Image.open(path).convert("RGB"))

    def rel(self, dx, dy):
        ev = []
        if dx:
            ev.append({"type": "rel", "data": {"axis": "x", "value": dx}})
        if dy:
            ev.append({"type": "rel", "data": {"axis": "y", "value": dy}})
        self.cmd("input-send-event", events=ev)

    def click(self):
        self.cmd("input-send-event", events=[{"type": "btn", "data": {"down": True, "button": "left"}}])
        time.sleep(0.05)
        self.cmd("input-send-event", events=[{"type": "btn", "data": {"down": False, "button": "left"}}])


def locate(cur):
    """IRIX's arrow cursor is the only saturated-red thing on the desktop left of
    the icon column (the fsn icon at x>1190 is red too, hence the x<1150 cut)."""
    a = cur[:, :1150, :].astype(int)
    m = (a[:, :, 0] > 200) & (a[:, :, 1] < 80) & (a[:, :, 2] < 80)
    ys, xs = np.nonzero(m)
    if len(xs) < 10:
        return None
    return (int(xs.min()), int(ys.min()), int(len(xs)))


def centroid(base, cur):
    return locate(cur)


def ssh(port, cmd, timeout=600):
    r = subprocess.run(
        [
            "ssh",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "LogLevel=ERROR",
            "-i",
            KEY,
            "-p",
            str(port),
            "root@127.0.0.1",
            cmd,
        ],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--ssh", type=int, required=True)
    ap.add_argument("--skip-cpu", action="store_true")
    ap.add_argument("--loop", type=int, default=400000)
    a = ap.parse_args()
    out = {"tag": a.tag, "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    tmp = f"/data/vms/sandbox/irisbuild/m-{a.tag}"
    os.makedirs(tmp, exist_ok=True)

    # ---- kiosk-side: iris process load + binary identity
    rc, o, e = ssh(a.ssh, "md5sum /usr/local/bin/iris | cut -c1-8; ps -C iris -o %cpu=,rss=,etimes= | head -1; nproc")
    out["kiosk"] = o.split("\n") if rc == 0 else f"ssh failed: {e}"

    # ---- mouse
    q = QMP(a.qmp)
    q.click()
    time.sleep(0.5)  # make sure Iris has the pointer
    for _ in range(60):
        q.rel(-50, -50)
        time.sleep(0.02)  # paced slam to the top-left corner
    for _ in range(6):
        q.rel(20, 20)
        time.sleep(0.02)  # then out into the open desktop
    time.sleep(1.0)
    base = q.shot(f"{tmp}/base.ppm")
    out["park"] = locate(base)
    # (a) single move latency, 5 trials
    lats = []
    for i in range(5):
        pre = locate(q.shot(f"{tmp}/pre.ppm"))
        t0 = time.monotonic()
        q.rel(30 if i % 2 == 0 else -30, 0)
        while True:
            cur = locate(q.shot(f"{tmp}/cur.ppm"))
            t = time.monotonic() - t0
            if cur and pre and cur[:2] != pre[:2]:
                lats.append(round(t * 1000))
                break
            if t > 3:
                lats.append(None)
                break
        time.sleep(0.4)
    out["mouse_single_latency_ms"] = lats
    # (b) paced stream: 60 x (dx=4,dy=4) at 20 ms = 1.2 s, track for 3 s
    base = q.shot(f"{tmp}/base2.ppm")
    track = []
    t0 = time.monotonic()

    def sample():
        cur = q.shot(f"{tmp}/cur.ppm")
        c = centroid(base, cur)
        track.append((round(time.monotonic() - t0, 3), c))

    n = 60
    for i in range(n):
        q.rel(1, 0)
        time.sleep(0.02)
        if i % 5 == 4:
            sample()
    t_last = time.monotonic() - t0
    while time.monotonic() - t0 < t_last + 3.0:
        sample()
        time.sleep(0.03)
    pos = [(t, c) for t, c in track if c]
    settle = None
    if pos:
        fx, fy = pos[-1][1][0], pos[-1][1][1]
        for t, c in pos:
            if abs(c[0] - fx) < 1.5 and abs(c[1] - fy) < 1.5:
                settle = t
                break
    distinct = len({(round(c[0]), round(c[1])) for _, c in pos})
    out["mouse_stream"] = {
        "events": n,
        "last_event_s": round(t_last, 3),
        "settled_s": settle,
        "lag_after_last_ms": None if settle is None else round((settle - t_last) * 1000),
        "distinct_positions": distinct,
        "samples": len(track),
        "final_centroid": pos[-1][1][:2] if pos else None,
        "first_centroid": pos[0][1][:2] if pos else None,
    }
    out["mouse_track"] = [(t, None if c is None else (round(c[0]), round(c[1]))) for t, c in track]

    # ---- cpu (fixed work in IRIX through the SCC telnet channel)
    if not a.skip_cpu:
        subprocess.run(
            [
                "scp",
                "-o",
                "StrictHostKeyChecking=no",
                "-o",
                "UserKnownHostsFile=/dev/null",
                "-o",
                "LogLevel=ERROR",
                "-i",
                KEY,
                "-P",
                str(a.ssh),
                "/data/vms/sandbox/irisbuild/iexec.py",
                "root@127.0.0.1:/root/iexec.py",
            ],
            check=True,
        )
        rc, o, e = ssh(a.ssh, "python3 /root/iexec.py --login", timeout=120)
        out["iexec_login"] = (rc, o[-200:], e[-200:])
        loop = a.loop
        cmd = (
            f"echo T0=`awk 'BEGIN{{srand();print srand()}}'`; "
            f"awk 'BEGIN{{s=0;for(i=0;i<{loop};i++){{s+=(i*i)%7; if(i%100000==0)print i}}print \\\"S=\\\" s}}'; "
            f"echo T1=`awk 'BEGIN{{srand();print srand()}}'`"
        )
        t0 = time.monotonic()
        ssh(a.ssh, 'python3 /root/iexec.py "echo hi" 120', timeout=200)
        noop_s = time.monotonic() - t0
        t0 = time.monotonic()
        rc, o, e = ssh(a.ssh, f'python3 /root/iexec.py "{cmd}" 900', timeout=1000)
        host_s = time.monotonic() - t0
        out["iexec_noop_s"] = round(noop_s, 1)
        g = {k: v for k, v in (l.split("=", 1) for l in o.split("\n") if "=" in l)}
        try:
            guest_s = int(g["T1"]) - int(g["T0"])
        except Exception:
            guest_s = None
        out["cpu"] = {
            "loop": loop,
            "host_s_total": round(host_s, 1),
            "host_s_loop": round(host_s - noop_s, 1),
            "guest_s": guest_s,
            "rc": rc,
            "out": o[-300:],
            "err": e[-200:],
        }
        rc, o, e = ssh(a.ssh, "ps -C iris -o %cpu=,rss= | head -1")
        out["kiosk_after"] = o
    print(json.dumps(out))


if __name__ == "__main__":
    main()

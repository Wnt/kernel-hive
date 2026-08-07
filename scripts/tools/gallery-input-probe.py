#!/usr/bin/env python3
# gallery-input-probe.py -- GUEST-SIDE input->photon latency probe for a neko tile.
#
# Runs INSIDE the neko container (pushed via `docker exec -i <svc> python3 -`), so
# the whole inject->detect loop lives behind ONE monotonic clock -- no SSH round
# trip and no Mac<->host clock skew in the numbers. It is the guest-processing
# half of the perceived-lag budget:   perceived ~= guest-processing + transport-RTT
# (transport RTT/jitter is reported separately by gallery-perf-probe.mjs getStats).
#
# Mechanism (exactly the path neko drives):
#   * inject on the container X display :99 with xdotool (XTEST -> the focused
#     QEMU/FreeRDP window -> the guest), the same device neko's own input driver
#     pokes;
#   * detect the photon from neko's OWN capture by polling the admin screenshot
#     API on localhost:8080 (POST /api/login admin/admin -> GET
#     /api/room/screen/shot.jpg) and watching for the encoded JPEG bytes to change.
#     neko emits byte-identical JPEGs for an unchanged screen, so a whole-frame
#     byte-diff is a clean, decode-free photon detector (no JPEG decoder needed).
#
# MOUSE  probe: park cursor at A, move to B -> the guest re-renders the cursor at B.
#               Universal + non-destructive (works on any guest whose cursor neko
#               captures).
# KBD    probe: per-OS keystroke that makes a deterministic visible change
#               (Windows GUI: Super/Ctrl+Esc opens the Start/Task menu; console/DOS:
#               a printable char echoes at the prompt). Reset returns the screen to
#               baseline so the tile is left clean.
#
# Output: one JSON object on stdout.  All timing in milliseconds.
#
# This is a companion to gallery-perf-probe.mjs (WebRTC video/audio getStats +
# orchestration) and gallery-perf-cpu.sh (host/guest CPU + KVM check). The .mjs
# pushes and runs this automatically; it can also be run standalone for debugging:
#   docker exec -i osgallery-win95-1 python3 - --do-mouse --do-kbd \
#       --mouse-a 150,450 --mouse-b 600,180 --kbd super --kbd-reset Escape < gallery-input-probe.py
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request


def eprint(*a):
    print(*a, file=sys.stderr)


def sh(args, timeout=8):
    # run a one-shot command on DISPLAY=:99; return elapsed_ms
    env = dict(os.environ)
    env["DISPLAY"] = env.get("DISPLAY", ":99")
    t = time.monotonic()
    try:
        subprocess.run(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)
    except Exception as e:
        eprint("sh fail", args, e)
    return (time.monotonic() - t) * 1000.0


class Xdo:
    """Persistent `xdotool -` process: connect to X once, inject via stdin.

    A fresh `xdotool` per event costs a fork + X-connect that, under host
    contention, balloons to 150-250ms and swamps the guest-processing signal.
    Holding one connected process makes each inject a sub-ms pipe write, so the
    measured photon latency is (near) pure guest-processing + capture delay.
    """

    def __init__(self):
        env = dict(os.environ)
        env["DISPLAY"] = env.get("DISPLAY", ":99")
        self.p = subprocess.Popen(
            ["xdotool", "-"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env
        )
        self.cmd("getmouselocation")  # warm the X connection

    def cmd(self, line):
        self.p.stdin.write((line + "\n").encode())
        self.p.stdin.flush()

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=3)
        except Exception:
            pass


class Neko:
    def __init__(self, port, user, pw):
        self.base = f"http://127.0.0.1:{port}"
        self.tok = None
        body = json.dumps({"username": user, "password": pw}).encode()
        req = urllib.request.Request(self.base + "/api/login", data=body, headers={"Content-Type": "application/json"})
        self.tok = json.load(urllib.request.urlopen(req, timeout=8))["token"]

    def shot(self):
        req = urllib.request.Request(
            self.base + "/api/room/screen/shot.jpg", headers={"Authorization": "Bearer " + self.tok}
        )
        return urllib.request.urlopen(req, timeout=8).read()


def diffpct(a, b):
    if not a or not b:
        return 100.0
    n = min(len(a), len(b))
    dl = abs(len(a) - len(b))
    d = sum(1 for i in range(n) if a[i] != b[i])
    return (d + dl) / max(len(a), len(b)) * 100.0


def find_window(match):
    # match: "qemu" (class) or "name:FreeRDP"
    try:
        if match.startswith("name:"):
            out = subprocess.run(
                ["xdotool", "search", "--name", match[5:]],
                env={**os.environ, "DISPLAY": os.environ.get("DISPLAY", ":99")},
                capture_output=True,
                text=True,
                timeout=8,
            ).stdout
        else:
            out = subprocess.run(
                ["xdotool", "search", "--class", match],
                env={**os.environ, "DISPLAY": os.environ.get("DISPLAY", ":99")},
                capture_output=True,
                text=True,
                timeout=8,
            ).stdout
        ids = [l for l in out.split() if l.strip()]
        return ids[-1] if ids else None  # last = the mapped top-level
    except Exception as e:
        eprint("find_window", e)
        return None


def wait_change(neko, base, thresh, poll, timeout):
    """poll screenshots until bytes differ from base by >thresh%; return (ms, hitpct) or (None,maxpct)."""
    t0 = time.monotonic()
    best = 0.0
    while (time.monotonic() - t0) < timeout:
        try:
            cur = neko.shot()
        except Exception:
            cur = None
        p = diffpct(base, cur)
        best = max(best, p)
        if p > thresh:
            return (time.monotonic() - t0) * 1000.0, p
        time.sleep(poll)
    return None, best


def parse_xy(s):
    x, y = s.split(",")
    return int(x), int(y)


def run_trial_mouse(xd, neko, a, b, args, use_a):
    dst = a if use_a else b
    src = b if use_a else a
    xd.cmd(f"mousemove {src[0]} {src[1]}")
    time.sleep(args.settle)
    base = neko.shot()
    xd.cmd(f"mousemove {dst[0]} {dst[1]}")  # inject via warm connection
    ms, hit = wait_change(neko, base, args.thresh, args.poll, args.timeout)
    return ms, hit


def run_trial_kbd(xd, neko, args):
    # ensure clean baseline (undo any prior menu/char)
    if args.kbd_reset:
        for k in args.kbd_reset.split("+space+"):
            xd.cmd("key --clearmodifiers " + k)
    time.sleep(args.settle)
    base = neko.shot()
    if args.kbd.startswith("type:"):
        xd.cmd("type --clearmodifiers " + args.kbd[5:])
    else:
        xd.cmd("key --clearmodifiers " + args.kbd)
    ms, hit = wait_change(neko, base, args.thresh, args.poll, args.timeout)
    # reset back to baseline so the tile is left clean
    if args.kbd_reset:
        for k in args.kbd_reset.split("+space+"):
            xd.cmd("key --clearmodifiers " + k)
            time.sleep(0.05)
    time.sleep(args.settle)
    return ms, hit


def stats(vals):
    ok = sorted(v for v in vals if v is not None)
    med = ok[len(ok) // 2] if ok else None
    return {
        "trials_ms": [None if v is None else round(v, 1) for v in vals],
        "hits": len(ok),
        "misses": sum(1 for v in vals if v is None),
        "min_ms": round(ok[0], 1) if ok else None,
        "median_ms": round(med, 1) if med is not None else None,
        "max_ms": round(ok[-1], 1) if ok else None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="8080")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--pass", dest="pw", default="admin")
    ap.add_argument("--win", default="qemu", help='window match: "qemu" or "name:FreeRDP"')
    ap.add_argument("--trials", type=int, default=5)
    ap.add_argument("--mouse-a", default="150,450")
    ap.add_argument("--mouse-b", default="600,180")
    ap.add_argument("--kbd", default="super")
    ap.add_argument("--kbd-reset", default="Escape")
    ap.add_argument("--do-mouse", action="store_true")
    ap.add_argument("--do-kbd", action="store_true")
    ap.add_argument("--settle", type=float, default=0.5)
    ap.add_argument("--poll", type=float, default=0.006)
    ap.add_argument("--timeout", type=float, default=6.0)
    ap.add_argument("--thresh", type=float, default=2.0)
    args = ap.parse_args()
    os.environ.setdefault("DISPLAY", ":99")
    out = {"ok": False, "win": args.win, "thresh_pct": args.thresh}
    try:
        neko = Neko(args.port, args.user, args.pw)
    except Exception as e:
        out["error"] = "neko login failed: " + str(e)
        print(json.dumps(out))
        return
    win = find_window(args.win)
    out["win_id"] = win
    try:
        out["screen_bytes"] = len(neko.shot())
    except Exception as e:
        out["error"] = "shot failed: " + str(e)
        print(json.dumps(out))
        return
    # one-shot fork cost (reported so the raw contention penalty is visible; the
    # actual probe injects via a persistent connection so this is NOT in the numbers)
    out["oneshot_fork_ms"] = round(sh(["xdotool", "getmouselocation"]), 1)
    out["poll_floor_note"] = "detection floor ~= 1 capture frame (~33ms at 30fps) + shot fetch (~1-5ms in-container)"
    xd = Xdo()
    if win:
        xd.cmd(f"windowactivate --sync {win}")
        time.sleep(0.2)
    if args.do_mouse:
        a = parse_xy(args.mouse_a)
        b = parse_xy(args.mouse_b)
        mv = []
        for i in range(args.trials):
            ms, hit = run_trial_mouse(xd, neko, a, b, args, use_a=(i % 2 == 1))
            mv.append(ms)
            time.sleep(0.2)
        out["mouse"] = stats(mv)
        out["mouse"]["method"] = (
            f"cursor move {args.mouse_a}<->{args.mouse_b} -> framebuffer byte-change (persistent xdotool)"
        )
    if args.do_kbd:
        kv = []
        for _i in range(args.trials):
            ms, hit = run_trial_kbd(xd, neko, args)
            kv.append(ms)
            time.sleep(0.2)
        out["keyboard"] = stats(kv)
        out["keyboard"]["method"] = (
            f"xdotool {args.kbd} -> framebuffer byte-change (persistent xdotool, reset:{args.kbd_reset})"
        )
    xd.close()
    out["ok"] = True
    print(json.dumps(out))


if __name__ == "__main__":
    main()

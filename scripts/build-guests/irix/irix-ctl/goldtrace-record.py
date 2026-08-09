#!/usr/bin/env python3
"""Record one arm of the golden-trace differential harness (issue #45 Stage 1).

Executes the corpus (goldtrace-corpus.txt; directive grammar documented there)
against ONE arm on an already-running clone and writes the guest-visible
effect sequence as a JSONL trace:

  arm "lua": verbs are appended to the clone's irix_cmd file, the channel the
      autoboot irixagent.lua consumes. Needs NO mamectl module in the binary,
      so the corpus is recordable (and the corpus itself validated) before the
      module ever builds.
  arm "ctl": verbs are sent seq-stamped over the mamectl/1 socket via
      mctl-probe.py's client; acks and EV lines land in the trace.

Effects recorded are host-OBSERVED (framebuffer, never disk/log inference):
  * cursor trajectory: red-mask centroid over fb.shm with the y>=YMIN
    exclusion crop (Stage-0: the EZsetup icon at y 214..306 pollutes the mask
    at the chooser; the CENTROID is the stable signature — the pixel count is
    not (54 vs 116 px) and is recorded but never compared);
  * settle points + converged/gaveup classification per MOVEA target
    (bug-for-bug: the corpus's (300,500) chooser give-up must land at
    ~(186,386) — reproduced, not fixed);
  * framebuffer mean/sd signature probes around button edges / keys / POST;
  * per-arm counters for the giveups-delta gate: the Lua agent's periodic
    `stats` log line, or the module's STAT reply.

The two arms run on identically prepared clones — same patched binary, same
golden, same cold-boot-or-restore recipe — launched by the OPERATOR, never by
this tool (clone-guard rules bind whoever launches). Diff two traces with
goldtrace-compare.py.

Exit codes: 0 recorded clean; 3 = one or more !expect failures (trace still
written — the corpus or the arm needs looking at); 2 = usage/preflight.
"""

import argparse
import hashlib
import importlib.util
import json
import math
import mmap
import os
import struct
import sys
import time

import numpy as np

MAGIC = 0x31424649  # 'IFB1'
HEADER = 64
SURF_W, SURF_H = 1288, 1024  # the visarea MOVEA targets are clamped to


def die(msg):
    """Usage/preflight failure: exit 2 per the module docstring's contract."""
    print(f"goldtrace-record: {msg}", file=sys.stderr)
    raise SystemExit(2)


def load_mctl():
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mctl-probe.py")
    spec = importlib.util.spec_from_file_location("mctl_probe", p)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def parse_kv_ints(text):
    """Opportunistic k=v harvest ('giveups=3 res=-114,-114 ...') -> dict."""
    out = {}
    for tok in text.split():
        k, eq, v = tok.partition("=")
        if eq:
            try:
                out[k] = int(v)
            except ValueError:
                out[k] = v
    return out


def parse_crop(spec):
    wh, _, xy = spec.partition("+")
    cw, ch = (int(v) for v in wh.split("x"))
    cx, cy = (int(v) for v in xy.split("+"))
    return cw, ch, cx, cy


class Fb:
    """Read-only mmap of the streamhost shm framebuffer (capture/shm.rs)."""

    def __init__(self, path, ymin):
        fd = os.open(path, os.O_RDONLY)
        size = os.fstat(fd).st_size
        self.mm = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ)
        os.close(fd)
        magic, _ver, self.w, self.h = struct.unpack_from("<IIII", self.mm, 0)
        if magic != MAGIC:
            die(f"bad shm magic in {path}")
        if size < HEADER + self.w * self.h * 4:
            die(f"shm mapping truncated: {path}")
        self.ymin = ymin

    def _frame(self):
        n = self.w * self.h * 4
        return np.frombuffer(self.mm, dtype=np.uint8, count=n, offset=HEADER).reshape(self.h, self.w, 4)

    def cursor(self):
        sub = self._frame()[self.ymin :]  # BGRA: [:, :, 2] is red
        m = (sub[:, :, 2] > 150) & (sub[:, :, 1] < 100) & (sub[:, :, 0] < 100)
        ys, xs = np.nonzero(m)
        if len(xs) == 0:
            return None
        return (float(xs.mean()), float(ys.mean()) + self.ymin, int(len(xs)))

    def sig(self, crop=None):
        # mean/sd over the color channels; invariant under the BGR<->RGB
        # reorder, so these numbers match shmpng.py's.
        f = self._frame().astype(np.float32)[:, :, :3] / 255.0
        if crop:
            cw, ch, cx, cy = crop
            f = f[cy : cy + ch, cx : cx + cw]
        return float(f.mean()), float(f.std())


class LuaArm:
    """Inject via the irix_cmd file; counters from the agent's stats log line."""

    name = "lua"

    def __init__(self, cmd_path):
        self.log_path = cmd_path + ".agent.log"
        # os-level append fd: unbuffered by nature, lives for the recording
        self.fd = os.open(cmd_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            self.log_off = os.path.getsize(self.log_path)
        except OSError:
            self.log_off = 0
        self.baseline = self._last_stats_in_log()

    def _last_stats_in_log(self):
        try:
            with open(self.log_path, "rb") as f:
                tail = f.read()
        except OSError:
            return None
        last = None
        for ln in tail.decode("utf-8", "replace").splitlines():
            if " stats " in ln:
                last = ln
        return last

    def hello(self):
        return None

    def send(self, line):
        os.write(self.fd, (line + "\n").encode())
        return {}

    def drain_events(self):
        return []

    def stats(self, wait_s):
        """Wait for a FRESH periodic stats line (IRIX_STAT_PERIOD, default 15 s)."""
        deadline = time.monotonic() + wait_s
        while time.monotonic() < deadline:
            try:
                size = os.path.getsize(self.log_path)
            except OSError:
                size = 0
            if size > self.log_off:
                with open(self.log_path, "rb") as f:
                    f.seek(self.log_off)
                    new = f.read().decode("utf-8", "replace")
                self.log_off = size
                for ln in new.splitlines():
                    if " stats " in ln:
                        return ln
            time.sleep(0.5)
        return None

    @staticmethod
    def giveups(stats_line):
        if not stats_line:
            return None
        v = parse_kv_ints(stats_line).get("giveups")
        return v if isinstance(v, int) else None


class CtlArm:
    """Inject over the mamectl/1 socket; counters from the STAT verb."""

    name = "ctl"

    def __init__(self, sock_path, timeout):
        mod = load_mctl()
        self.err = mod.MctlError
        self.cli = mod.MctlClient(sock_path, timeout=timeout)
        self.baseline = self._stat()

    def _stat(self):
        try:
            rep = self.cli.request("STAT")
        except self.err:
            return None
        return " ".join([rep.text] + rep.data)

    def hello(self):
        return self.cli.hello

    def send(self, line):
        t0 = time.monotonic()
        rep = self.cli.request(line)
        out = {"ack_ms": round((time.monotonic() - t0) * 1e3, 3), "ok": rep.ok}
        if not rep.ok:
            out["err"] = f"{rep.code} {rep.text}"
        return out

    def drain_events(self):
        self.cli.pump(0.0)
        evs, self.cli.events = self.cli.events[:], []
        return evs

    def stats(self, _wait_s):
        return self._stat()

    @staticmethod
    def giveups(stat_text):
        if not stat_text:
            return None
        v = parse_kv_ints(stat_text).get("giveups")
        return v if isinstance(v, int) else None


class Recorder:
    def __init__(self, args, fb, arm, out_fh):
        self.args = args
        self.fb = fb
        self.arm = arm
        self.out = out_fh
        self.step = 0
        self.label = ""
        self.last_target = None
        self.last_settle = None
        self.expect_fails = 0
        self.t0 = time.monotonic()

    def rel(self, t):
        return round(t - self.t0, 4)

    def emit(self, rec):
        if self.label:
            rec.setdefault("label", self.label)
        self.out.write(json.dumps(rec, separators=(",", ":")) + "\n")

    def flush_events(self):
        for ev in self.arm.drain_events():
            self.emit({"type": "ev", "i": self.step, "t": self.rel(time.monotonic()), "line": ev})

    def verb(self, line):
        t = time.monotonic()
        info = self.arm.send(line)
        rec = {"type": "cmd", "i": self.step, "t": self.rel(t), "line": line}
        rec.update(info)
        if line.split()[0] == "MOVEA":
            try:
                x, y = (int(v) for v in line.split()[1:3])
                # the agent clamps to the surface; classify against the same target
                self.last_target = (max(0, min(SURF_W - 1, x)), max(0, min(SURF_H - 1, y)))
                rec["target"] = list(self.last_target)
            except ValueError:
                pass
        self.emit(rec)
        self.flush_events()

    def do_settle(self, timeout_s):
        period = 1.0 / self.args.hz
        start = time.monotonic()
        history = []  # (t, x, y) within the stability window
        stable = False
        c = None
        while time.monotonic() - start < timeout_s:
            c = self.fb.cursor()
            now = time.monotonic()
            if c is not None:
                self.emit(
                    {
                        "type": "sample",
                        "i": self.step,
                        "t": self.rel(now),
                        "x": round(c[0], 1),
                        "y": round(c[1], 1),
                        "n": c[2],
                    }
                )
                history.append((now, c[0], c[1]))
                history = [h for h in history if now - h[0] <= self.args.stable_s]
                if now - history[0][0] >= self.args.stable_s * 0.9:
                    span = max(math.hypot(c[0] - h[1], c[1] - h[2]) for h in history)
                    if span <= self.args.stable_px:
                        stable = True
                        break
            else:
                history = []  # hidden cursor: stability starts over
            time.sleep(period)
        rec = {"type": "settle", "i": self.step, "t": self.rel(time.monotonic()), "stable": stable}
        if c is not None:
            rec.update({"x": round(c[0], 1), "y": round(c[1], 1), "n": c[2]})
            self.last_settle = (c[0], c[1])
        else:
            self.last_settle = None
        self.emit(rec)
        self.flush_events()

    def do_expect(self, toks):
        verdict_want = toks[1] if len(toks) > 1 else "any"
        if verdict_want not in ("converged", "gaveup", "any"):
            die(f"bad !expect verdict {verdict_want!r}")
        rec = {"type": "expect", "i": self.step, "want": verdict_want}
        tgt, st = self.last_target, self.last_settle
        rec["target"] = list(tgt) if tgt else None
        rec["settle"] = [round(st[0], 1), round(st[1], 1)] if st else None
        if tgt and st:
            d = math.hypot(tgt[0] - st[0], tgt[1] - st[1])
            rec["residual"] = [round(tgt[0] - st[0], 1), round(tgt[1] - st[1], 1)]
            measured = "converged" if d <= self.args.conv_tol else "gaveup"
        else:
            measured = "unknown"
        rec["verdict"] = measured
        ok = measured != "unknown" and (verdict_want == "any" or measured == verdict_want)
        if len(toks) >= 4 and st:
            ex, ey = float(toks[2]), float(toks[3])
            rec["expect_pos"] = [ex, ey]
            ok = ok and math.hypot(st[0] - ex, st[1] - ey) <= self.args.expect_tol
        rec["pass"] = ok
        if not ok:
            self.expect_fails += 1
        self.emit(rec)

    def directive(self, line):
        toks = line.split()
        name = toks[0]
        if name == "!label":
            self.label = toks[1] if len(toks) > 1 else ""
        elif name == "!wait":
            ms = int(toks[1])
            self.emit({"type": "wait", "i": self.step, "t": self.rel(time.monotonic()), "ms": ms})
            time.sleep(ms / 1000.0)
        elif name == "!settle":
            self.do_settle(float(toks[1]) if len(toks) > 1 else self.args.settle_timeout)
        elif name == "!expect":
            self.do_expect(toks)
        elif name == "!sig":
            crop = parse_crop(toks[2]) if len(toks) > 2 else None
            mean, sd = self.fb.sig(crop)
            self.emit(
                {
                    "type": "sig",
                    "i": self.step,
                    "t": self.rel(time.monotonic()),
                    "sig_label": toks[1] if len(toks) > 1 else "",
                    "mean": round(mean, 6),
                    "sd": round(sd, 6),
                }
            )
        else:
            die(f"unknown directive {name!r}")

    def run(self, corpus_text):
        for raw in corpus_text.splitlines():
            # Full-line comments only: verb payloads (POST text) may contain '#'.
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            self.step += 1
            if line.startswith("!"):
                self.directive(line)
            else:
                self.verb(line)
        self.flush_events()
        final = self.arm.stats(self.args.stats_wait)
        base = self.arm.baseline
        gb, gf = self.arm.giveups(base), self.arm.giveups(final)
        delta = (gf - gb) if (gb is not None and gf is not None) else None
        self.emit(
            {
                "type": "footer",
                "stats_baseline": base,
                "stats_final": final,
                "giveups_delta": delta,
                "expect_fails": self.expect_fails,
            }
        )


def main():
    ap = argparse.ArgumentParser(description="record one golden-trace arm (see module docstring)")
    ap.add_argument("--arm", required=True, choices=("lua", "ctl"))
    ap.add_argument("--dir", required=True, help="clone dir (fb.shm + irix_cmd / ctl.sock)")
    ap.add_argument("--out", required=True, help="JSONL trace to write")
    ap.add_argument("--corpus", required=True, help="corpus file (see goldtrace-corpus.txt)")
    ap.add_argument("--cmd-file", help="override <dir>/irix_cmd (lua arm)")
    ap.add_argument("--sock", help="override <dir>/ctl.sock (ctl arm)")
    ap.add_argument("--ymin", type=int, default=340, help="cursor-mask exclusion crop (EZsetup icon)")
    ap.add_argument("--hz", type=float, default=50.0, help="trajectory sample rate during !settle")
    ap.add_argument("--stable-px", type=float, default=1.5, help="max centroid drift to call stable")
    ap.add_argument("--stable-s", type=float, default=0.4, help="stability window length, s")
    ap.add_argument("--settle-timeout", type=float, default=8.0, help="default !settle timeout, s")
    ap.add_argument("--conv-tol", type=float, default=25.0, help="settle-to-target px = converged")
    ap.add_argument("--expect-tol", type=float, default=15.0, help="px tolerance for !expect X Y")
    ap.add_argument("--ack-timeout", type=float, default=10.0, help="ctl arm per-verb ack timeout, s")
    ap.add_argument("--stats-wait", type=float, default=40.0, help="footer stats wait, s (> stat period)")
    ap.add_argument("--require-fresh", action="store_true", help="lua arm: fail if irix_cmd is nonempty")
    args = ap.parse_args()

    fb = Fb(os.path.join(args.dir, "fb.shm"), args.ymin)
    with open(args.corpus, encoding="utf-8") as f:
        corpus_text = f.read()

    if args.arm == "lua":
        cmd_path = args.cmd_file or os.path.join(args.dir, "irix_cmd")
        if args.require_fresh and os.path.exists(cmd_path) and os.path.getsize(cmd_path) > 0:
            die(f"{cmd_path} nonempty — not a fresh session (--require-fresh)")
        arm = LuaArm(cmd_path)
    else:
        arm = CtlArm(args.sock or os.path.join(args.dir, "ctl.sock"), args.ack_timeout)

    with open(args.out, "w", encoding="utf-8") as out:
        rec = Recorder(args, fb, arm, out)
        rec.emit(
            {
                "type": "meta",
                "arm": args.arm,
                "dir": os.path.abspath(args.dir),
                "corpus_sha256": hashlib.sha256(corpus_text.encode()).hexdigest(),
                "ymin": args.ymin,
                "conv_tol": args.conv_tol,
                "expect_tol": args.expect_tol,
                "hz": args.hz,
                "t0_unix": round(time.time(), 3),
                "fb": {"w": fb.w, "h": fb.h},
                "hello": arm.hello(),
            }
        )
        rec.run(corpus_text)

    if rec.expect_fails:
        print(f"goldtrace-record: {rec.expect_fails} expectation failure(s) — see {args.out}", file=sys.stderr)
        return 3
    print(f"goldtrace-record: {args.arm} arm recorded clean -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

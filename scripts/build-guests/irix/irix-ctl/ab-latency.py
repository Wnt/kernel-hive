#!/usr/bin/env python3
"""A/B pointer-latency rig for issue #45 (Stage 1): Lua agent vs mamectl.

Port of the Stage-0 spike rig (lab:/data/vms/soltest/irix-ss44/mv1files/v1b.py)
with every Stage-0 verdict correction applied — the corrections are BINDING:

  * DELTAS, never absolutes: the fb.shm publish gap under production settings
    is ~33-43 ms and dominates any command->first-motion observable. Arms are
    interleaved in the SAME boot, hops come in same-geometry pairs, and the
    rig's headline number is the paired per-hop delta (lua - ctl).
  * Small analysis crop: full-frame red-mask polling achieved only ~12.8 ms
    cadence; restricting the mask to the (start, target) bounding box + pad
    buys the <=5 ms poll cadence the gate math assumed.
  * Settle gate between hops: false starts (<~5.1 ms "first motion" that was
    actually the previous hop's tail) were harvested out of the Stage-0 data;
    here every hop starts only after the cursor has been stable, and a
    first-motion below --min-valid-ms is retried once, then discarded.
  * Pre-seed slam + stability gate after every restore: a restored session's
    hle_ps2_mouse state vs a zero-seeded injector accumulator rings for
    seconds (queued=4700, spurious giveups). The slam pins the cursor against
    the edge clamp and the rig waits for stability before measuring. (The
    module re-seeds from restored save-item state at LOADST/init — Stage-1
    build order — but the rig must not depend on it.)
  * Convergence-validated targets: (300,500) at the chooser gives up
    deterministically at (186,386); (1050,850) converges res=1,0. Every
    target is validated with a real hop before measurement; a target that
    cannot converge aborts the rig (exit 4).
  * STAT receipt->apply histogram from the module arm is the PRIMARY A2
    evidence (the capture path cannot see inside the module); the rig
    collects raw STAT replies at start/end plus per-hop ack RTTs.

Same-boot interleave configuration (measurement-only): production interlocks
ban two live injectors, and they stay banned. For this rig the operator
launches ONE clone with the Lua agent autobooted AND `MAME_CTL_SOCK` set, with
the module's legacy-file tail pointed away from (or disabled for) the rig's
irix_cmd file, so the file feeds ONLY the Lua agent and the socket ONLY the
module. Hops are strictly serialized behind settle gates, so the two engines'
pacing budgets never contend. `--mode lua` (or `ctl`) runs one arm alone —
`lua` needs no module in the binary at all.

This rig never launches or stops clones; quiesce + core pinning per
docs/lab/MEASUREMENT-METHODOLOGY.md are the operator's contract.

Exit: 0 clean; 1 timeouts/nonconverged hops occurred; 4 target validation
failed; 2 usage/preflight.
"""

import argparse
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
MOTION_PX = 3.0
CONV_TOL_PX = 25.0


def die(msg):
    """Usage/preflight failure: exit 2 per the module docstring's contract."""
    print(f"ab-latency: {msg}", file=sys.stderr)
    raise SystemExit(2)


def load_mctl():
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mctl-probe.py")
    spec = importlib.util.spec_from_file_location("mctl_probe", p)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def pct(v, p):
    s = sorted(v)
    if not s:
        return float("nan")
    return s[min(len(s) - 1, max(0, int(round(p / 100.0 * (len(s) - 1)))))]


def dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


class Fb:
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

    def seq(self):
        return struct.unpack_from("<Q", self.mm, 24)[0]

    def _frame(self):
        n = self.w * self.h * 4
        return np.frombuffer(self.mm, dtype=np.uint8, count=n, offset=HEADER).reshape(self.h, self.w, 4)

    def cursor(self, bbox=None):
        """Red-mask centroid; bbox=(x0,y0,x1,y1) restricts the mask (fast path)."""
        x0, y0, x1, y1 = bbox if bbox else (0, self.ymin, self.w, self.h)
        y0 = max(y0, self.ymin)
        sub = self._frame()[y0:y1, x0:x1]
        m = (sub[:, :, 2] > 150) & (sub[:, :, 1] < 100) & (sub[:, :, 0] < 100)
        ys, xs = np.nonzero(m)
        if len(xs) == 0:
            return None
        return (float(xs.mean()) + x0, float(ys.mean()) + y0, int(len(xs)))

    def bbox_for(self, a, b, pad):
        x0 = int(max(0, min(a[0], b[0]) - pad))
        x1 = int(min(self.w, max(a[0], b[0]) + pad + 1))
        y0 = int(max(self.ymin, min(a[1], b[1]) - pad))
        y1 = int(min(self.h, max(a[1], b[1]) + pad + 1))
        return (x0, y0, x1, y1)


class LuaInj:
    """Arm A: append to the irix_cmd file the autoboot Lua agent consumes."""

    name = "lua"

    def __init__(self, cmd_path):
        # os-level append fd: unbuffered by nature, lives for the rig's lifetime
        self.fd = os.open(cmd_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)

    def send(self, line):
        os.write(self.fd, (line + "\n").encode())
        return None  # no ack channel

    def poll_ack(self, _handle):
        return None

    def stat(self):
        return None


class CtlInj:
    """Arm B: seq-stamped verbs over the mamectl/1 socket, acks drained non-blocking."""

    name = "ctl"

    def __init__(self, sock_path, timeout):
        mod = load_mctl()
        self.err = mod.MctlError
        self.cli = mod.MctlClient(sock_path, timeout=timeout)

    def send(self, line):
        return (self.cli.send_async(line), time.monotonic())

    def poll_ack(self, handle):
        """Non-blocking: ack RTT in ms once the reply has arrived, else None."""
        if handle is None:
            return None
        seq, t0 = handle
        self.cli.pump(0.0)
        rep = self.cli.poll_reply(seq)
        if rep is None:
            return None
        return {"ack_ms": round((time.monotonic() - t0) * 1e3, 3), "ok": rep.ok}

    def stat(self):
        try:
            rep = self.cli.request("STAT")
        except self.err:
            return None
        return " ".join([rep.text] + rep.data)


def stable_wait(fb, around, args, timeout_s, stable_s=None):
    """Wait until the centroid holds still; returns the settled centroid or None."""
    stable_s = args.stable_s if stable_s is None else stable_s
    bbox = fb.bbox_for(around, around, args.pad) if around else None
    t_end = time.monotonic() + timeout_s
    history = []
    while time.monotonic() < t_end:
        c = fb.cursor(bbox)
        now = time.monotonic()
        if c is None:
            history = []
            bbox = None  # cursor left the box (or hidden): fall back to full band
        else:
            history.append((now, c[0], c[1]))
            history = [h for h in history if now - h[0] <= stable_s]
            span_ok = now - history[0][0] >= stable_s * 0.9
            if span_ok and max(math.hypot(c[0] - h[1], c[1] - h[2]) for h in history) <= args.stable_px:
                return (c[0], c[1])
            bbox = fb.bbox_for((c[0], c[1]), (c[0], c[1]), args.pad)
        time.sleep(0.01)
    return None


def hop(fb, inj, tgt, c0, args):
    """One measured hop: t0 = injection, first-motion from the cropped mask."""
    bbox = fb.bbox_for(c0, tgt, args.pad)
    rec = {"arm": inj.name, "from": [round(c0[0], 1), round(c0[1], 1)], "to": list(tgt)}
    poll_gaps, frame_gaps = [], []
    seq0 = fb.seq()
    t0 = time.monotonic()
    handle = inj.send(f"MOVEA {tgt[0]} {tgt[1]}")
    last_poll, last_seq, last_seq_t = t0, seq0, t0
    t_move = None
    while time.monotonic() - t0 < args.motion_timeout:
        c = fb.cursor(bbox)
        now = time.monotonic()
        poll_gaps.append(now - last_poll)
        last_poll = now
        s = fb.seq()
        if s != last_seq and s % 2 == 0:
            frame_gaps.append(now - last_seq_t)
            last_seq, last_seq_t = s, now
        if "ack_ms" not in rec:
            ack = inj.poll_ack(handle)
            if ack:
                rec.update(ack)
        if c and dist(c, c0) > MOTION_PX:
            t_move = now
            break
        time.sleep(args.poll_ms / 1e3)
    if t_move is None:
        rec["timeout"] = True
        return rec, poll_gaps, frame_gaps
    lat = (t_move - t0) * 1e3
    rec["lat_ms"] = round(lat, 2)
    rec["false_start"] = lat < args.min_valid_ms
    settle = stable_wait(fb, tgt, args, args.settle_timeout)
    if settle:
        rec["settle"] = [round(settle[0], 1), round(settle[1], 1)]
        rec["converged"] = dist(settle, tgt) <= CONV_TOL_PX
    else:
        rec["converged"] = False
    return rec, poll_gaps, frame_gaps


def summarize(tag, ms):
    if not ms:
        return f"{tag}: (no data)"
    return (
        f"{tag}: n={len(ms)} min={min(ms):.1f} p10={pct(ms, 10):.1f} p50={pct(ms, 50):.1f} "
        f"mean={sum(ms) / len(ms):.1f} p90={pct(ms, 90):.1f} p95={pct(ms, 95):.1f} max={max(ms):.1f}"
    )


def run_hop(fb, inj, tgt, cur, args, out):
    """Settle-gated hop with one false-start retry; returns (rec, new_cur)."""
    for attempt in (1, 2):
        c0 = stable_wait(fb, cur, args, args.settle_timeout) or cur
        rec, pg, fg = hop(fb, inj, tgt, c0, args)
        rec["attempt"] = attempt
        out["hops"].append(rec)
        out["poll_gaps"].extend(pg)
        out.setdefault("frame_gaps", {}).setdefault(inj.name, []).extend(fg)
        if not rec.get("false_start"):
            break
    new_cur = tuple(rec["settle"]) if rec.get("settle") else tgt
    return rec, new_cur


def main():
    ap = argparse.ArgumentParser(description="A/B MOVEA latency rig (see module docstring)")
    ap.add_argument("dir", help="clone dir (fb.shm + irix_cmd / ctl.sock)")
    ap.add_argument("--mode", choices=("both", "lua", "ctl"), default="both")
    ap.add_argument("--pairs", type=int, default=100, help="A/B pairs (or hops in single-arm mode)")
    ap.add_argument("--targets", default="1050,850 400,700", help="exactly two 'x,y' targets, y>=ymin")
    ap.add_argument("--cmd-file", help="override <dir>/irix_cmd")
    ap.add_argument("--sock", help="override <dir>/ctl.sock")
    ap.add_argument("--json", help="write full per-hop records here")
    ap.add_argument("--ymin", type=int, default=340, help="cursor-mask exclusion crop (EZsetup icon)")
    ap.add_argument("--pad", type=int, default=130, help="analysis-crop pad around start/target, px")
    ap.add_argument("--poll-ms", type=float, default=4.0, help="target poll cadence")
    ap.add_argument("--min-valid-ms", type=float, default=6.0, help="first-motion below this = false start")
    ap.add_argument("--motion-timeout", type=float, default=4.0)
    ap.add_argument("--settle-timeout", type=float, default=6.0)
    ap.add_argument("--stable-px", type=float, default=1.5)
    ap.add_argument("--stable-s", type=float, default=0.35)
    ap.add_argument("--no-preseed", action="store_true", help="skip the post-restore pre-seed slam")
    ap.add_argument("--preseed-timeout", type=float, default=30.0)
    args = ap.parse_args()

    fb = Fb(os.path.join(args.dir, "fb.shm"), args.ymin)
    targets = []
    for tok in args.targets.split():
        x, y = (int(v) for v in tok.split(","))
        if y < args.ymin:
            die(f"target {tok} is above --ymin {args.ymin} (mask cannot see it)")
        targets.append((x, y))
    if len(targets) != 2:
        die("exactly two targets required (same-geometry pairing)")

    arms = []
    if args.mode in ("both", "lua"):
        arms.append(LuaInj(args.cmd_file or os.path.join(args.dir, "irix_cmd")))
    if args.mode in ("both", "ctl"):
        arms.append(CtlInj(args.sock or os.path.join(args.dir, "ctl.sock"), timeout=10.0))
    out = {"meta": vars(args).copy(), "hops": [], "poll_gaps": [], "stat": {}}

    for inj in arms:
        s = inj.stat()
        if s:
            out["stat"][f"{inj.name}_start"] = s

    # Pre-seed slam + stability gate (post-restore transient rings for seconds).
    if not args.no_preseed:
        arms[0].send("MOVEP -4000 -4000")
        c = stable_wait(fb, None, args, args.preseed_timeout, stable_s=1.5)
        if c is None:
            die("cursor never stabilized after pre-seed slam (restore transient?)")
        cur = c
    else:
        cur = stable_wait(fb, None, args, args.settle_timeout) or (fb.w // 2, fb.h // 2)

    # Convergence-validate every target with a real hop before measuring.
    for tgt in targets:
        rec, cur = run_hop(fb, arms[0], tgt, cur, args, out)
        rec["validation"] = True
        if not rec.get("converged"):
            print(f"ab-latency: target {tgt} failed convergence validation: {rec}", file=sys.stderr)
            return 4

    lat = {a.name: [] for a in arms}
    deltas = []
    bad = 0
    for k in range(args.pairs):
        order = arms if (k % 2 == 0) else arms[::-1]  # alternate order to cancel drift
        pair = {}
        for inj in order:
            tgt = max(targets, key=lambda t: dist(cur, t))  # always the far target
            rec, cur = run_hop(fb, inj, tgt, cur, args, out)
            rec["pair"] = k
            if rec.get("timeout") or not rec.get("converged") or rec.get("false_start"):
                bad += 1
            else:
                lat[inj.name].append(rec["lat_ms"])
                pair[inj.name] = rec["lat_ms"]
        if len(arms) == 2 and len(pair) == 2:
            deltas.append(pair["lua"] - pair["ctl"])

    for inj in arms:
        s = inj.stat()
        if s:
            out["stat"][f"{inj.name}_end"] = s
    out["deltas"] = deltas

    print(f"\n== ab-latency summary (mode={args.mode}, {args.pairs} pairs) ==")
    for name, ms in lat.items():
        print(summarize(f"{name} cmd->first-motion ms [capture-bound]", ms))
    if deltas:
        pos = sum(1 for d in deltas if d > 0)
        print(summarize("paired delta (lua - ctl) ms  <-- THE evidence", deltas))
        print(f"pairs with lua slower: {pos}/{len(deltas)}")
    print(
        "absolutes are capture-bound (fb.shm publish gap ~33-43 ms under production frameskip);"
        " evaluate the paired deltas, and take A2 from the module's STAT receipt->apply histogram."
    )
    if out["poll_gaps"]:
        print(f"poll cadence ms: p50={pct(out['poll_gaps'], 50) * 1e3:.1f} p95={pct(out['poll_gaps'], 95) * 1e3:.1f}")
    for name, fg in out.get("frame_gaps", {}).items():
        if fg:
            print(f"{name} shm frame-publish gap ms: p50={pct(fg, 50) * 1e3:.1f} p95={pct(fg, 95) * 1e3:.1f}")
    acks = [h["ack_ms"] for h in out["hops"] if "ack_ms" in h]
    if acks:
        print(summarize("ctl ack RTT ms (poll-granular; module histogram is primary)", acks))
    if bad:
        print(f"discarded hops (timeout/nonconverged/false-start): {bad}")
    for k, v in out["stat"].items():
        print(f"STAT {k}: {v}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=1)
        print(f"full records -> {args.json}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

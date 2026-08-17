#!/usr/bin/env python3
"""Replay a recorded browser typing burst against a ctlsock/vicectl module.

The other half of the keyboard-lag evidence chain: key-trace.py --replay turns
a visitor's real, browser-timed key edges (spa/src/input/keyRecorder.ts) into a
JSONL file; this fires that file — SAME edges, SAME timing — at a soltest
clone's control socket and measures what the module's pacing engine does with
it. Ack latency per edge IS the visitor's keyboard lag: the module acks a KEY
when it is APPLIED to the matrix, past the hold/gap dwells and the
exclusive-scan gate (scripts/build-guests/patches/mame-ctlsock.patch).

    # record on the gallery, then on labhost:
    python3 serve/key-trace.py --session ab12cd34 --replay burst.jsonl
    python3 key-replay.py --sock /data/vms/soltest/<rig>/ctl.sock \\
        --keymap .../sinclairql.keymap burst.jsonl

    # no recording yet? synthesize a realistic rollover burst:
    python3 key-replay.py --sock ... --keymap ... \\
        --type 'print 12+34' --cps 7 --hold-ms 110

Overlap matters: a fast typist presses B before releasing A, which is exactly
what the exclusive-scan gate serializes hardest and what slow one-key-at-a-time
tests can never reproduce (the two audited key-order defects both hid there).
--type therefore synthesizes ROLLOVER bursts: hold-ms > the inter-press period
overlaps consecutive keys just like real typing.

Modes:
  mamectl (default): needs --keymap <station>.keymap (code -> port/field);
      wire verb `KEY <0|1> <port> <field>`.
  --vice: needs --keymap us-layout.keysyms (code -> plain/shifted keysym);
      wire verb `KEY <0|1> <keysym>`, shift level resolved like vice_sock.rs
      (a release repeats its press's keysym).

The framebuffer is still the only proof the GUEST reacted — this measures the
pacing queue, then you screenshot the clone to prove the line landed intact.
"""

from __future__ import annotations

import argparse
import json
import selectors
import socket
import sys
import time
from pathlib import Path

LSHIFT, RSHIFT = 0x2A, 0x36

# ASCII -> (XT set-1 scancode, needs-shift) for the synthesizer, US layout.
XT: dict[str, tuple[int, bool]] = {}
for i, ch in enumerate("1234567890"):
    XT[ch] = (0x02 + i, False)
for row, base in (("qwertyuiop", 0x10), ("asdfghjkl", 0x1E), ("zxcvbnm", 0x2C)):
    for i, ch in enumerate(row):
        XT[ch] = (base + i, False)
for plain, shifted in zip("1234567890", "!@#$%^&*()"):
    XT[shifted] = (XT[plain][0], True)
XT.update(
    {
        " ": (0x39, False),
        "\n": (0x1C, False),
        "-": (0x0C, False),
        "=": (0x0D, False),
        "+": (0x0D, True),
        "_": (0x0C, True),
        ";": (0x27, False),
        ":": (0x27, True),
        ",": (0x33, False),
        ".": (0x34, False),
        "/": (0x35, False),
        "?": (0x35, True),
        "'": (0x28, False),
        '"': (0x28, True),
    }
)
for ch in "abcdefghijklmnopqrstuvwxyz":
    XT[ch.upper()] = (XT[ch][0], True)


def load_mame_keymap(path: Path) -> dict[int, tuple[str, str]]:
    """`0xNN<TAB>:PORT<TAB>FIELD` rows (field keeps its internal spaces)."""
    out: dict[int, tuple[str, str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t", 2)
        if len(cols) != 3:
            continue
        out[int(cols[0], 16)] = (cols[1], cols[2])
    return out


def load_vice_keymap(path: Path) -> dict[int, tuple[int, int]]:
    """`code-hex<TAB>plain-keysym-hex<TAB>shifted-keysym-hex` rows."""
    out: dict[int, tuple[int, int]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        cols = line.split("\t")
        if len(cols) < 3:
            continue
        out[int(cols[0], 16)] = (int(cols[1], 16), int(cols[2], 16))
    return out


def synth(text: str, cps: float, hold_ms: float) -> list[dict]:
    """Rollover burst: presses every 1000/cps ms, each key held hold_ms."""
    period = 1000.0 / cps
    edges: list[dict] = []
    at = 0.0
    for ch in text:
        if ch not in XT:
            raise SystemExit(f"--type: no XT mapping for {ch!r}")
        code, shift = XT[ch]
        if shift:
            edges.append({"off_ms": at - period / 3, "code": LSHIFT, "down": 1})
        edges.append({"off_ms": at, "code": code, "down": 1})
        edges.append({"off_ms": at + hold_ms, "code": code, "down": 0})
        if shift:
            edges.append({"off_ms": at + hold_ms + period / 3, "code": LSHIFT, "down": 0})
        at += period
    edges.sort(key=lambda e: e["off_ms"])
    base = edges[0]["off_ms"]  # a leading Shift press can sit before t=0
    for e in edges:
        e["off_ms"] -= base
    return edges


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("replay", nargs="?", type=Path, help="JSONL from key-trace.py --replay")
    ap.add_argument("--sock", required=True, help="control socket of a SOLTEST clone, never a live station")
    ap.add_argument("--keymap", required=True, type=Path)
    ap.add_argument("--vice", action="store_true", help="vicectl keysym wire instead of mamectl port/field")
    ap.add_argument("--speed", type=float, default=1.0, help="time scale (2.0 = twice as fast)")
    ap.add_argument("--type", dest="text", help="synthesize a burst instead of replaying a file")
    ap.add_argument("--cps", type=float, default=7.0, help="synth presses per second (default 7)")
    ap.add_argument("--hold-ms", type=float, default=110.0, help="synth per-key hold (default 110, overlaps at 7 cps)")
    ap.add_argument("--timeout", type=float, default=30.0, help="drain wait after the last send (default 30 s)")
    args = ap.parse_args()

    if bool(args.text) == bool(args.replay):
        ap.error("exactly one of <replay file> or --type")
    edges = (
        synth(args.text, args.cps, args.hold_ms)
        if args.text
        else [json.loads(ln) for ln in args.replay.read_text(encoding="utf-8").splitlines() if ln.strip()]
    )
    if not edges:
        raise SystemExit("no edges to replay")

    mame_map = None if args.vice else load_mame_keymap(args.keymap)
    vice_map = load_vice_keymap(args.keymap) if args.vice else None

    sk = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sk.connect(args.sock)
    sk.settimeout(2.0)
    banner = b""
    while not banner.endswith(b"\n"):
        banner += sk.recv(256)
    print(f"banner: {banner.decode().strip()}")
    sk.setblocking(False)
    sel = selectors.DefaultSelector()
    sel.register(sk, selectors.EVENT_READ)

    # vice shift level: resolved at PRESS time, releases repeat their press's
    # keysym — the same rule vice_sock.rs enforces.
    shift_down = 0
    pressed_sym: dict[int, int] = {}
    seq = 0
    sent: dict[int, tuple[float, float, str]] = {}  # seq -> (sched_off, tx_time, line)
    acked: list[tuple[str, float, float]] = []  # (line, queue_lag_ms, ack_at_ms)
    rxbuf = b""

    def pump(deadline: float) -> None:
        nonlocal rxbuf
        while True:
            budget = deadline - time.monotonic()
            if budget <= 0 or not sel.select(budget):
                return
            try:
                chunk = sk.recv(4096)
            except BlockingIOError:
                continue
            if not chunk:
                raise SystemExit("module closed the socket")
            rxbuf += chunk
            while b"\n" in rxbuf:
                line, rxbuf = rxbuf.split(b"\n", 1)
                tok = line.decode(errors="replace").split(" ", 2)
                if len(tok) >= 2 and tok[1] in ("OK", "ERR") and tok[0].isdigit():
                    s = int(tok[0])
                    if s in sent:
                        sched, _tx, cmd = sent.pop(s)
                        now_ms = time.monotonic() * 1000
                        acked.append((cmd, now_ms - sched, now_ms))
                        if tok[1] == "ERR":
                            print(f"  ERR {cmd}: {line.decode(errors='replace')}")

    t0 = time.monotonic() * 1000
    skipped = 0
    for e in edges:
        code, down = int(e["code"]), int(e["down"])
        sched = t0 + float(e["off_ms"]) / args.speed
        pump(deadline=sched / 1000)  # read acks while waiting for this edge's slot
        while time.monotonic() * 1000 < sched:
            pump(deadline=sched / 1000)
        if args.vice:
            if down:
                if code in (LSHIFT, RSHIFT):
                    shift_down += 1
                row = vice_map.get(code)
                if row is None:
                    skipped += 1
                    continue
                sym = row[1] if shift_down and code not in (LSHIFT, RSHIFT) else row[0]
                pressed_sym[code] = sym
            else:
                if code in (LSHIFT, RSHIFT):
                    shift_down = max(0, shift_down - 1)
                sym = pressed_sym.pop(code, None)
                if sym is None:
                    skipped += 1
                    continue
            wire = f"KEY {down} {sym}"
        else:
            row = mame_map.get(code)
            if row is None:
                skipped += 1
                continue
            wire = f"KEY {down} {row[0]} {row[1]}"
        seq += 1
        sk.sendall(f"{seq} {wire}\n".encode())
        sent[seq] = (sched, time.monotonic() * 1000, wire)

    drain_end = time.monotonic() + args.timeout
    while sent and time.monotonic() < drain_end:
        pump(deadline=min(drain_end, time.monotonic() + 0.5))
    sel.close()
    sk.close()

    if skipped:
        print(f"{skipped} edges skipped (no keymap row)")
    if not acked:
        raise SystemExit("nothing acked — wrong socket, or the module is paused")
    burst_ms = edges[-1]["off_ms"] / args.speed
    worst = max(acked, key=lambda a: a[1])
    print(f"\n{len(acked)} edges acked, {len(sent)} still UNACKED after {args.timeout:g}s drain")
    print(f"burst duration {burst_ms:.0f} ms, last ack at +{max(a[2] for a in acked) - t0:.0f} ms")
    print(
        f"queue lag (ack - scheduled send): "
        f"max {worst[1]:.0f} ms on `{worst[0]}`, "
        f"p50 {sorted(a[1] for a in acked)[len(acked) // 2]:.0f} ms"
    )
    if sent:
        for s, (_sched, _tx, cmd) in sorted(sent.items()):
            print(f"  UNACKED seq={s} {cmd}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

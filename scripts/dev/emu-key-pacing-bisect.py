#!/usr/bin/env python3
"""Measure a bridge tile's key-drop rate against SH_KEY_MIN_HOLD_MS/GAP_MS.

Runs ONLY against a clone under /data/vms/soltest (never the live tile). For
each (hold, gap) pair it restores the clone's golden snapshot, types one fixed
40-character line with that pacing, screendumps, and compares the framebuffer
with a reference captured at a deliberately generous pacing. A differing frame
means at least one character was dropped or merged.

THE CURSOR BLINKS, so a raw frame compare reports every trial as corrupt. The
reference is therefore captured several times and the pixels that differ
between those captures — the cursor cell and nothing else — are masked out of
every later comparison.

Usage: emu-key-pacing-bisect.py <clone-qmp-sock> <out-dir> [trials] [line]

Written for the vic20 add (2026-08-08), where the shipped two-frame pacing lost
a character every few hundred; the defaults below are that tile's. Point it at
any bridge clone whose guest echoes typed characters.
"""

import json
import os
import socket
import sys
import time

# 40 characters: the shifted set the registry demo listing actually uses
# ($ ( ) * +) mixed with unshifted letters and digits.
LINE = os.environ.get("PACE_LINE", "print chr$(147)+int(rnd(1)*8)-abcdefghij")

# The pacings to try, as "hold:gap" pairs. The default is the three the vic20
# bisect used. Override it to measure a machine whose frame period puts the
# two-frame floor somewhere else -- and, at least once per tile, to run a
# NEGATIVE CONTROL: a frame compare that never reports a mismatch is
# indistinguishable from a tile that never drops a key, so prove the instrument
# can fail by including a pacing that is obviously too fast (PACE_PAIRS=0:0).
PAIRS = tuple(
    tuple(int(part) for part in pair.split(":"))
    for pair in os.environ.get("PACE_PAIRS", "40:40,60:60,80:80").split(",")
)

PLAIN = {" ": "spc", "-": "minus", ".": "dot", ",": "comma"}
SHIFT = {"$": "4", "(": "9", ")": "0", "*": "8", "+": "equal"}


def chords(text):
    out = []
    for ch in text:
        if ch.isdigit() or (ch.isalpha() and ch.isascii()):
            out.append([ch.lower()])
        elif ch in PLAIN:
            out.append([PLAIN[ch]])
        elif ch in SHIFT:
            out.append(["shift", SHIFT[ch]])
        else:
            raise SystemExit(f"unmappable character {ch!r}")
    return out


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(30)
        self.s.connect(path)
        self.f = self.s.makefile("rwb")
        self.f.readline()
        self.cmd("qmp_capabilities")

    def cmd(self, execute, **args):
        payload = {"execute": execute}
        if args:
            payload["arguments"] = args
        self.f.write((json.dumps(payload) + "\n").encode())
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP closed")
            msg = json.loads(line)
            if "return" in msg or "error" in msg:
                return msg

    def hmp(self, line):
        return self.cmd("human-monitor-command", **{"command-line": line})

    def close(self):
        self.f.close()
        self.s.close()


def key_event(q, qcode, down):
    q.cmd(
        "input-send-event",
        events=[{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}],
    )


def type_line(q, hold_ms, gap_ms):
    """Type LINE with the DAEMON's pacing semantics (streamhost input.rs):
    press -> hold_ms -> release -> gap_ms -> next press.

    Explicit `input-send-event` press/release pairs, NOT `send-key hold-time`.
    QEMU's send-key returns as soon as the press is queued and releases on its
    own timer, and back-to-back calls overlap on that timer: at 250 ms hold and
    250 ms sleep this harness still lost 6 of 40 characters, i.e. the instrument
    was lossier than the thing being measured. (labctl's send_chords_paced has
    the same shape, and additionally sleeps only `gap` after the call, so the
    true release->press gap it leaves is gap-hold = 0 ms at this tile's 40/40.)
    """
    hold, gap = hold_ms / 1000.0, gap_ms / 1000.0
    for chord in chords(LINE):
        for k in chord:
            key_event(q, k, True)
        time.sleep(hold)
        for k in reversed(chord):
            key_event(q, k, False)
        time.sleep(gap)


def shot(q, out_dir, tag):
    ppm = os.path.join(out_dir, f"{tag}.ppm")
    if os.path.exists(ppm):
        os.unlink(ppm)
    q.hmp(f"screendump {ppm}")
    for _ in range(40):
        if os.path.exists(ppm) and os.path.getsize(ppm) > 1_000_000:
            break
        time.sleep(0.25)
    time.sleep(0.2)
    with open(ppm, "rb") as fh:
        return fh.read()


def trial(q, out_dir, tag, hold_ms, gap_ms, shots=1):
    q.hmp("loadvm golden")
    time.sleep(2.5)
    type_line(q, hold_ms, gap_ms)
    time.sleep(1.5)
    return [shot(q, out_dir, f"{tag}-{n}") for n in range(shots)]


def differing(a, b):
    return {i for i, (x, y) in enumerate(zip(a, b)) if x != y}


def main():
    qmp_path, out_dir = sys.argv[1], sys.argv[2]
    trials = int(sys.argv[3]) if len(sys.argv) > 3 else 10
    os.makedirs(out_dir, exist_ok=True)
    q = Qmp(qmp_path)

    # Reference at a pacing nobody disputes (6+ PAL frames each way), captured
    # 6 times ~0.5 s apart so the blinking cursor's pixels can be masked out.
    refs = trial(q, out_dir, "reference", 250, 250, shots=6)
    mask = set()
    for other in refs[1:]:
        mask |= differing(refs[0], other)
    ref = refs[0]
    print(f"reference captured; cursor mask = {len(mask)} bytes", flush=True)

    for hold, gap in PAIRS:
        bad = 0
        for i in range(trials):
            got = trial(q, out_dir, f"h{hold}g{gap}-{i:02d}", hold, gap)[0]
            delta = differing(ref, got) - mask
            if delta:
                bad += 1
                print(
                    f"  MISMATCH hold={hold} gap={gap} trial={i} ({len(delta)} unmasked bytes)",
                    flush=True,
                )
        print(
            f"hold={hold:3d} gap={gap:3d} -> {bad}/{trials} lines corrupted ({len(LINE)} chars each)",
            flush=True,
        )
    q.close()


if __name__ == "__main__":
    main()

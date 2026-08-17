#!/usr/bin/env python3
"""Decode pushed key-edge telemetry into a typing timeline (and a replay file).

The SPA's key recorder (spa/src/input/keyRecorder.ts) packs every key edge —
exactly as it went on the wire — into `key` telemetry rows and pushes them to
/clientlog every ~2 s. This turns that back into a readable burst, so a
keyboard-lag reproduction can be measured, and exports it as a replay file for
scripts/dev/key-replay.py so the SAME browser-timed burst can be fired at a
soltest clone under candidate pacing knobs.

    ssh lab 'python3 /data/vms/streamhost/serve/key-trace.py'
    ssh lab 'python3 .../key-trace.py --since-min 5 --session ab12cd34'
    ssh lab 'python3 .../key-trace.py --session ab12cd34 --replay burst.jsonl'

WHAT TO READ, for the pacing-queue bug this exists for:

  * `+83ms` — the browser-side gap since the previous edge. A fast typist's
    press-to-press gaps sit at 100-160 ms; the station's pacing floor
    (hold+gap, see the station.env.fixture) must sit BELOW that or edges queue.
  * `cps=…` in the summary — the burst's actual characters per second. Compare
    against the station's ceiling: 1000 / (SH_KEY_MIN_HOLD_MS + SH_KEY_MIN_GAP_MS).
  * overlap flags — a `d` for key B before the `u` of key A is REAL rollover
    typing; it is what the exclusive-scan gate serializes hardest.

Correlate with the server side (all on labhost's clock, unlike the browser's):
daemon `[key-tel] recv/tx/ack` lines (SH_INPUT_TELEMETRY=1, journald) and the
module's `CTLTRACE <wall_ms> <emu_s> verb KEY … applied` lines
(MAME_CTL_TRACE=1, mame.log).
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

CLIENTLOG = Path(os.environ.get("CLIENTLOG", str(Path(__file__).resolve().parent / "clientlog.jsonl")))


def rows(path: Path, since_ms: float, session: str | None):
    """Every packed key row, oldest first, as (session, tile, t, now, ep, code)."""
    if not path.exists():
        return
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("event") != "key":
                continue
            if rec.get("srvTs", 0) * 1000 < since_ms:
                continue
            sid = rec.get("sessionId", "")
            if session and not sid.startswith(session):
                continue
            for packed in (rec.get("detail") or "").split(";"):
                f = packed.split(",")
                if len(f) != 4 or f[0] not in ("d", "u"):
                    continue
                try:
                    yield sid, rec.get("tile", ""), f[0], int(f[1]), int(f[2]), int(f[3], 16)
                except ValueError:
                    continue


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since-min", type=float, default=15, help="how far back to read (default 15)")
    ap.add_argument("--session", help="only this session id (prefix match)")
    ap.add_argument("--replay", type=Path, help="write the burst as a key-replay.py JSONL file")
    ap.add_argument("--log", type=Path, default=CLIENTLOG)
    args = ap.parse_args()

    since_ms = (time.time() - args.since_min * 60) * 1000
    data = sorted(rows(args.log, since_ms, args.session), key=lambda r: (r[0], r[3]))
    if not data:
        print(f"no key telemetry in the last {args.since_min:g} min of {args.log}")
        print("(the recorder is armed by default; a client older than this bundle does not push)")
        return 1

    if args.replay and len({sid for sid, *_ in data}) > 1:
        print("--replay needs ONE session; pass --session to pick it. Sessions seen:")
        for sid in sorted({sid for sid, *_ in data}):
            print(f"  {sid}")
        return 1

    prev_now: int | None = None
    held: set[int] = set()
    presses = 0
    first_now = last_now = None
    cur = None
    for sid, tile, t, now, _ep, code in data:
        if (sid, tile) != cur:
            cur = (sid, tile)
            print(f"\n== session {sid}  station {tile or '?'} ==")
            prev_now, held, presses, first_now = None, set(), 0, None
        gap = f"+{now - prev_now}ms" if prev_now is not None else "start"
        overlap = " OVERLAP" if t == "d" and held else ""
        print(f"  {t} 0x{code:04x} {gap}{overlap}")
        if t == "d":
            held.add(code)
            presses += 1
            first_now = now if first_now is None else first_now
            last_now = now
        else:
            held.discard(code)
        prev_now = now
    if presses > 1 and first_now is not None and last_now and last_now > first_now:
        cps = (presses - 1) * 1000 / (last_now - first_now)
        print(f"\n{presses} presses, cps={cps:.1f} (station ceiling = 1000 / (SH_KEY_MIN_HOLD_MS + SH_KEY_MIN_GAP_MS))")

    if args.replay:
        base = data[0][3]
        with args.replay.open("w", encoding="utf-8") as out:
            for _sid, _tile, t, now, _ep, code in data:
                out.write(json.dumps({"off_ms": now - base, "code": code, "down": int(t == "d")}) + "\n")
        print(f"replay file: {args.replay} ({len(data)} edges)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

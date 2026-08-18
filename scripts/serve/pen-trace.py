#!/usr/bin/env python3
"""Decode pushed pointer telemetry into a readable gesture timeline.

The SPA's pointer recorder (spa/src/input/pointerRecorder.ts) packs every raw
pointer event into `ptr` telemetry rows and pushes them to /clientlog every ~2 s.
This turns that back into gestures, so a reproduction can be read without asking
anyone to hold their phone awake for an operator eval round-trip.

    ssh lab 'python3 /data/vms/streamhost/serve/pen-trace.py'
    ssh lab 'python3 .../pen-trace.py --since-min 5 --session ab12cd34'
    ssh lab 'python3 .../pen-trace.py --moves'      # include the motion samples

WHAT TO READ, for the pen bugs this exists for (docs/lab/INPUT-DEBUGGING.md):

  * `ctxmenu +873ms` — how long after its contact a contextmenu arrived, on the
    HANDLER clock. Near 0 is an S-Pen barrel press; ~600 ms is Android's own
    long-press gesture. The event's own timeStamp cannot tell them apart: Chrome
    copies the originating pointerdown's stamp onto the synthesized event.
  * `ORPHAN` — motion carrying a button with no pointerdown. Android ate the
    press, which on a Samsung S-Pen means it claimed the barrel gesture.
  * `no-lift` — a contact with no matching release in the capture. The stuck
    button in the guest starts here.
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

CLIENTLOG = Path(os.environ.get("CLIENTLOG", str(Path(__file__).resolve().parent / "clientlog.jsonl")))

TAGS = {"d": "down", "u": "up", "c": "cancel", "m": "move", "X": "ctxmenu", "A": "auxclick", "w": "wire"}


def rows(path: Path, since_ms: float, session: str | None):
    """Every packed row, oldest first, as (srv_ts, session, tile, fields)."""
    if not path.exists():
        return
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("event") != "ptr":
                continue
            if rec.get("srvTs", 0) * 1000 < since_ms:
                continue
            sid = rec.get("sessionId", "")
            if session and not sid.startswith(session):
                continue
            for packed in (rec.get("detail") or "").split(";"):
                f = packed.split(",")
                if len(f) != 6:
                    continue
                try:
                    yield sid, rec.get("tile", ""), f[0], int(f[1]), f[2], int(f[3]), int(f[4]), int(f[5])
                except ValueError:
                    continue


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since-min", type=float, default=15, help="how far back to read (default 15)")
    ap.add_argument("--session", help="only this session id (prefix match)")
    ap.add_argument("--moves", action="store_true", help="print motion samples too")
    ap.add_argument("--log", type=Path, default=CLIENTLOG)
    args = ap.parse_args()

    since_ms = (time.time() - args.since_min * 60) * 1000
    data = list(rows(args.log, since_ms, args.session))
    if not data:
        print(f"no pointer telemetry in the last {args.since_min:g} min of {args.log}")
        print("(the recorder is armed by default; a client older than 2026-08-05 does not push)")
        return 1

    # Contact state per pointer, so a contextmenu can be timed against the
    # contact it interrupts and an unreleased press can be called out.
    down_at: dict[str, int] = {}
    last_sid = None
    moves_since = 0
    for sid, tile, tag, now, pt, btn, x, y in data:
        if sid != last_sid:
            print(f"\n=== session {sid[:8]}  tile {tile} ===")
            last_sid, down_at, moves_since = sid, {}, 0

        if tag == "w":
            # ?ptrrec=1 wire row: mapped GUEST point + the datagram's cseq (the
            # join key with the daemon's `[input-tel rel] cseq=` lines).
            if args.moves:
                print(f"  {now:>9}  wire      cseq={btn} guest=({x},{y})")
            continue
        if tag == "m":
            moves_since += 1
            if args.moves:
                print(f"  {now:>9}  move      btn={btn} ({x},{y})")
            elif btn and pt not in down_at and down_at.get("_flag") != "ORPHAN":
                # Motion under a button with no press on record: the press was
                # eaten before it reached the page. Report the run once.
                print(f"  {now:>9}  ORPHAN    motion with btn={btn} and no pointerdown")
                down_at["_flag"] = "ORPHAN"
            continue

        label = TAGS.get(tag, tag)
        extra = ""
        if tag == "d":
            down_at[pt] = now
            moves_since = 0
        elif tag in ("u", "c"):
            t0 = down_at.pop(pt, None)
            if t0 is not None:
                extra = f"  held {now - t0} ms, {moves_since} moves"
            moves_since = 0
        elif tag in ("X", "A"):
            live = [t0 for k, t0 in down_at.items() if not k.startswith("_")]
            extra = f"  +{now - max(live)} ms into a live contact" if live else "  (no live contact)"
        print(f"  {now:>9}  {label:<9} btn={btn} pt={pt} ({x},{y}){extra}")

    stuck = [k for k in down_at if not k.startswith("_")]
    if stuck:
        print(f"\n  !! no-lift: {len(stuck)} contact(s) never released in this window")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

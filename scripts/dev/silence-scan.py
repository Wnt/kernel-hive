#!/usr/bin/env python3
"""silence-scan — when did the server go silent, for whom, and was it one station or the path?

    scripts/dev/silence-scan.py                        # labhost stores, last 36 h
    scripts/dev/silence-scan.py --since 2026-10-05T07:00 --station armeval
    scripts/dev/silence-scan.py --min 4 --vitals /tmp/vitals.db --logs /tmp/logs.db

WHAT IT ANSWERS. "Station X froze and the session dropped" has two very
different causes that look identical from one tab: the station (daemon, guest,
encoder) stopped talking, or the network between the visitor and the box lost
its packets. The SPA's vitals tell them apart without a repro. Every live
session writes one row a second (`vitals.db`), and three of its fields are fed
by the SERVER: `send_kbps` (reported by the daemon), `rtt_ms` and
`path_rtt_ms` (from the ping echoes). While nothing arrives from the server
those three stop changing. With `fps 0` as well, that row is a second of total
server silence, as the browser saw it.

One session going silent says nothing about where. Several sessions on
DIFFERENT stations going silent in the same second can only be something
they share, and they share no daemon and no guest: they share the path (the
uplink, the edge, the tunnel) or the box. The armeval stall of 2026-10-05
read exactly like that: symbos and armeval, two daemons and two browsers, both
silent from 08:03:53.8. The box's own pings to the edge, through the tunnel
and outside it, lost the same five seconds
(docs/lab/STREAM-DEBUGGING.md, "Every public session goes silent at once").

Each event prints its window, every session it hit, and whether a session
ended in a `ping-timeout` (logs.db, the SPA's `tile silent` close). A
single-session event is marked as UNDECIDED. Check the same client's
`/clientlog` cadence: if its HTTPS stalled too, it was the path.
"""

from __future__ import annotations

import argparse
import datetime as dt
import sqlite3
import sys

SERVE = "/data/vms/streamhost/serve"


def utc(ms: float) -> str:
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def parse_since(s: str | None, hours: float) -> int:
    if not s:
        return int((dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=hours)).timestamp() * 1000)
    t = dt.datetime.fromisoformat(s)
    if t.tzinfo is None:
        t = t.replace(tzinfo=dt.timezone.utc)
    return int(t.timestamp() * 1000)


def silent_runs(db: sqlite3.Connection, since: int, min_s: float) -> list[dict]:
    """Per session: windows in which the server-fed fields froze with fps 0."""
    q = (
        "select session_id, station, ts_ms, fps, send_kbps, rtt_ms, path_rtt_ms "
        "from vital where ts_ms >= ? and source = 'spa'"
    )
    args: list = [since]
    q += " order by session_id, ts_ms"
    runs: list[dict] = []
    cur: dict | None = None
    prev = None  # (session, server-fed fields, ts of the last fresh sample)
    for sid, st, ts, fps, send, rtt, prtt in db.execute(q, args):
        fed = (send, rtt, prtt)
        frozen = prev is not None and prev[0] == sid and send is not None and fed == prev[1] and not fps
        if frozen:
            if cur is None:
                cur = {"session": sid, "station": st, "start": prev[2], "end": ts}
            cur["end"] = ts
        else:
            if cur and (cur["end"] - cur["start"]) / 1000 >= min_s:
                runs.append(cur)
            cur = None
        if not frozen:
            prev = (sid, fed, ts)
    if cur and (cur["end"] - cur["start"]) / 1000 >= min_s:
        runs.append(cur)
    return runs


def ping_timeouts(logs: sqlite3.Connection | None, since: int) -> dict[str, list[int]]:
    if logs is None:
        return {}
    out: dict[str, list[int]] = {}
    for sid, ts in logs.execute(
        "select session_id, ts_ms from log where ts_ms >= ? and body like 'ping-timeout: tile silent%'", (since,)
    ):
        out.setdefault(sid, []).append(ts)
    return out


def events(runs: list[dict]) -> list[list[dict]]:
    """Group per-session windows that overlap in time (1 s slack for the 1 Hz rows)."""
    groups: list[list[dict]] = []
    for r in sorted(runs, key=lambda r: r["start"]):
        if groups and r["start"] <= max(x["end"] for x in groups[-1]) + 1000:
            groups[-1].append(r)
        else:
            groups.append([r])
    return groups


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--since", help="ISO time (UTC unless it carries an offset); default: --hours back")
    ap.add_argument("--hours", type=float, default=36.0)
    ap.add_argument("--station", help="only events that touched this station")
    ap.add_argument("--min", type=float, default=2.0, help="shortest silence reported, seconds (default 2)")
    ap.add_argument("--vitals", default=f"{SERVE}/vitals.db")
    ap.add_argument("--logs", default=f"{SERVE}/logs.db", help="'' to skip the ping-timeout join")
    a = ap.parse_args()

    since = parse_since(a.since, a.hours)
    vit = sqlite3.connect(f"file:{a.vitals}?mode=ro", uri=True)
    logs = sqlite3.connect(f"file:{a.logs}?mode=ro", uri=True) if a.logs else None
    runs = silent_runs(vit, since, a.min)
    closes = ping_timeouts(logs, since)

    shown = 0
    for ev in events(runs):
        if a.station and not any(r["station"] == a.station for r in ev):
            continue
        shown += 1
        start, end = min(r["start"] for r in ev), max(r["end"] for r in ev)
        stations = {r["station"] for r in ev}
        if len(stations) > 1:
            verdict = f"PATH/BOX-WIDE: {len(stations)} stations at once"
        else:
            verdict = "UNDECIDED: one station — check the client's /clientlog cadence and box->edge pings"
        print(f"{utc(start)}  ~{(end - start) / 1000:4.1f} s  {verdict}")
        for r in ev:
            died = any(r["start"] <= t <= r["end"] + 6000 for t in closes.get(r["session"], []))
            print(
                f"    {r['station']:<12} {r['session']}  {utc(r['start'])[11:]} -> {utc(r['end'])[11:]}"
                f"{'  -> ping-timeout (session dropped)' if died else ''}"
            )
    if not shown:
        print(f"no server silence >= {a.min:g} s since {utc(since)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

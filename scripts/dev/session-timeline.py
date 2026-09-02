#!/usr/bin/env python3
"""Where did a Claude Code session's wall-clock go?  Model time vs tool time vs agent waits.

The pcgeos speedrun (2026-09-02) was reported from memory as 15/25/35 minutes and
measured from timestamps as 6/14/18 — and two thirds of it turned out to be the
coordinator's own model time, not the box or the agents. Measure, never estimate:

    scripts/dev/session-timeline.py ~/.claude/projects/<repo-slug>/<session-id>.jsonl \
        [--end 2026-09-02T21:52:00] [--top 12] [--min-step 25]

Every transcript line that is a `user` or `assistant` message carries an ISO
`timestamp`; tool_use blocks carry ids that pair with their tool_result. Each gap
between consecutive messages is attributed to what was running during it:

  TOOL        an assistant tool_use → its result (box, git, gate, agent launch)
  MODEL       anything else that ends in an assistant message (reading output,
              thinking, writing the next tool input)
  WAIT-AGENT  an assistant text turn followed by a task-notification (idle)

Parallel tool calls overlap, so the per-call table (`--calls`) sums higher than
the TOOL wall-clock. The newest transcript is `ls -t ~/.claude/projects/<slug>/*.jsonl`.
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
from pathlib import Path


def parse_ts(s: str) -> dt.datetime:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def describe(content) -> tuple[set[str], str, bool]:
    if isinstance(content, str):
        return {"text"}, content[:60].replace("\n", " "), "task-notification" in content
    kinds = {b.get("type") for b in content}
    notif = False
    desc = ""
    for b in content:
        t = b.get("type")
        if t == "tool_use":
            inp = b.get("input", {})
            label = inp.get("description") or inp.get("file_path") or inp.get("prompt", "")[:40] or ""
            desc += f"{b['name']}:{str(label)[:55]} | "
        elif t == "text":
            txt = b.get("text", "")
            notif = notif or "task-notification" in txt[:200]
            desc += "TEXT " + txt[:45].replace("\n", " ") + " | "
    return kinds, desc, notif


def load(path: Path) -> list[dict]:
    events = []
    for line in path.read_text().splitlines():
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get("type") not in ("user", "assistant") or "timestamp" not in d:
            continue
        kinds, desc, notif = describe(d.get("message", {}).get("content"))
        events.append(
            {
                "t": parse_ts(d["timestamp"]),
                "role": d["type"],
                "kinds": kinds,
                "desc": desc,
                "notif": notif,
                "content": d.get("message", {}).get("content"),
            }
        )
    events.sort(key=lambda e: e["t"])
    return events


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("transcript", type=Path)
    ap.add_argument("--end", help="ISO time to stop attributing at (default: last message)")
    ap.add_argument("--top", type=int, default=12, help="rows per table")
    ap.add_argument("--min-step", type=float, default=25, help="chronological list threshold (s)")
    ap.add_argument("--calls", action="store_true", help="also list the longest individual tool calls")
    a = ap.parse_args()

    ev = load(a.transcript)
    if len(ev) < 2:
        print("no timestamped messages")
        return 1
    t0 = ev[0]["t"]
    end = parse_ts(a.end) if a.end else ev[-1]["t"]
    if end.tzinfo is None:
        end = end.replace(tzinfo=dt.timezone.utc)

    totals: collections.Counter[str] = collections.Counter()
    rows = []
    for cur, nxt in zip(ev, ev[1:]):
        if cur["t"] > end:
            break
        gap = (min(nxt["t"], end) - cur["t"]).total_seconds()
        if cur["role"] == "assistant" and "tool_use" in cur["kinds"]:
            kind = "TOOL"
        elif cur["role"] == "assistant":
            kind = "WAIT-AGENT" if nxt["notif"] else "MODEL"
        else:
            kind = "MODEL"
        totals[kind] += gap
        rows.append((cur["t"], gap, kind, cur["desc"]))

    span = (end - t0).total_seconds()
    print(f"start {t0:%Y-%m-%d %H:%M:%S}Z  span {span / 60:.1f} min")
    for k in ("MODEL", "TOOL", "WAIT-AGENT"):
        print(f"  {k:<11}{totals[k]:6.0f}s  {100 * totals[k] / span:4.0f}%")

    def minute(t: dt.datetime) -> str:
        return f"m{int((t - t0).total_seconds() // 60):2d}"

    for k in ("MODEL", "TOOL"):
        print(f"\n== longest {k} steps ==")
        for t, gap, _, desc in sorted((r for r in rows if r[2] == k), key=lambda r: -r[1])[: a.top]:
            print(f"{minute(t)} +{gap:4.0f}s {desc[:110]}")
    print("\n== agent waits ==")
    for t, gap, kind, desc in rows:
        if kind == "WAIT-AGENT":
            print(f"{minute(t)} +{gap:4.0f}s {desc[:100]}")
    print(f"\n== every step >= {a.min_step:.0f}s, in order ==")
    for t, gap, kind, desc in rows:
        if gap >= a.min_step:
            print(f"{minute(t)} +{gap:4.0f}s {kind:<10} {desc[:100]}")

    if a.calls:
        by_id: dict[str, list] = {}
        for e in ev:
            if not isinstance(e["content"], list):
                continue
            for b in e["content"]:
                if b.get("type") == "tool_use":
                    inp = b.get("input", {})
                    by_id[b["id"]] = [e["t"], inp.get("description") or b["name"]]
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in by_id:
                    by_id[b["tool_use_id"]].append(e["t"])
        calls = [(v[2] - v[0]).total_seconds() for v in by_id.values() if len(v) > 2]
        print(f"\n== tool calls: {len(calls)}, summed {sum(calls):.0f}s (parallel calls overlap) ==")
        for v in sorted((v for v in by_id.values() if len(v) > 2), key=lambda v: -(v[2] - v[0]).total_seconds())[
            : a.top
        ]:
            print(f"{(v[2] - v[0]).total_seconds():5.0f}s {str(v[1])[:80]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

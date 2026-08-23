#!/usr/bin/env python3
"""era_state -- era-press's two OUTPUT snapshots, split out of the crawl driver.

sites.json is what the /dir directory renders (one row per servable site: title, blurb, category, the
ORIGINAL capture date and the corpus metrics); state.json is the observable progress snapshot (per site,
which depths are covered, plus pages/bytes). Both are derived from the same in-memory `states` list the
driver maintains, and neither is the resume checkpoint -- the ON-DISK CORPUS is. Kept here so era_crawl
stays the driver; the dependency runs one way (era_crawl imports this). See docs/lab/retronet/ERA-PRESS.md.
"""

from __future__ import annotations

import json
import os
import time

import era_index
import era_press_core as core


def publish_sites(states, staging):
    """Upsert a sites.json row for every site with at least a home page -- so a newly-crawled site
    appears in the search directory as soon as its home lands. Merge, never replace: rows from other
    streams (and the synthetic proxy fixture) are kept untouched.

    Each row carries what /dir shows: the ORIGINAL capture date (`captured` -- the chosen home capture's
    14-digit Wayback stamp, from home_ts; the era date is the fallback for a home mirrored before this
    was recorded), and the three corpus metrics `pages` (HTML pages held), `depth` (the deepest level
    actually reached) and `bytes` (total size held). These replace the old `added` (OUR download date),
    which said nothing about the archived site."""
    existing = {s.get("host"): s for s in core._read_local_sites(staging)}
    ours = {}
    for st in states:
        if st["pages"] <= 0:
            continue
        captured = st["home_ts"] or era_index.index_ts(st["home"], st["date"])  # chosen stamp; era-date fallback
        depth_reached = max((int(lvl) for lvl, n in st["done"].items() if n), default=0)
        row = {
            "host": st["host"],
            "title": st["title"] or st["host"],
            "blurb": st["blurb"],
            "captured": captured,  # 14- or 8-digit stamp; /dir renders it as month-year
            "pages": st["pages"],
            "depth": depth_reached,
            "bytes": st["bytes"],
        }
        if st["category"]:
            row["category"] = st["category"]
        ours[st["host"]] = row
    merged = [s for s in existing.values() if s.get("host") not in ours] + list(ours.values())
    merged.sort(key=lambda s: s.get("host", ""))
    os.makedirs(staging, exist_ok=True)
    with open(os.path.join(staging, "sites.json"), "wb") as f:
        f.write(json.dumps(merged, indent=2, ensure_ascii=False).encode("utf-8"))


def flush_state(path, states, level, used):
    """Persist the global breadth-first frontier: the current depth level, and per site the per-level
    done/pending counts (which depths are covered) + pages/bytes. The on-disk corpus is the
    authoritative resume checkpoint; this snapshot makes the even-widening progress observable."""
    snap = {
        "mode": "breadth-first",
        "level": level,
        "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "corpus_gb": round(used / 1e9, 3),
        "sites": {},
    }
    for st in states:
        snap["sites"][st["host"]] = {
            "depth": st["depth"],
            "max_pages": st["max_pages"],
            "max_mb": st["max_mb"],
            "pages": st["pages"],
            "bytes": st["bytes"],
            "title": st["title"],
            "done": st["done"],  # pages mirrored, by depth level
            "pending": {lvl: len(urls) for lvl, urls in st["frontier"].items() if urls},
            "fetched": st["fetched"],
            "assets": st["assets"],
            "misses": st["misses"],
            "skipped": st["skipped"],
            "home_ts": st["home_ts"],  # chosen home capture stamp -> /dir's original date; survives resume
        }
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(snap, f, indent=2, sort_keys=True)
    os.replace(tmp, path)

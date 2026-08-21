#!/usr/bin/env python3
"""era_crawl -- the breadth-first, parallel, resumable corpus crawl behind `era-press.py crawl`.

Drives era-sites.json toward the global size budget by WIDENING EVERY SITE TOGETHER, one depth level
at a time: pass 0 mirrors every site's home, pass 1 every site's depth-1 links, pass 2 every site's
depth-2 links, … -- so an interrupted or budget-stopped crawl covers EVERY site to the same depth
(all homes, then all first levels, …), never a few sites deep and the rest empty.

Each pass is fetched ~CONCURRENCY-wide with a stdlib thread pool (urllib is blocking, so threads are
the right primitive; a browser on the Wayback Machine fetches ~10 at once, which is polite). All
workers share ONE archive.org pacing gate in era_press_core: a 429/503 seen by any worker opens a
GLOBAL backoff every worker waits out, so the whole pool slows/pauses together.

Resume is from the ON-DISK CORPUS, not a state file: _reconstruct re-walks each site's link graph from
disk to rebuild the per-level frontier, so a restart -- or a deepened era-sites.json -- continues the
even widening exactly where it left off and reaches new levels. state.json is written for observability
only. See docs/lab/retronet/ERA-PRESS.md.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from datetime import date
from itertools import zip_longest
from pathlib import Path

import era_press_core as core

SHARED_CORPUS = "/data/vms/retronet-corpus"  # big corpus volume (CT950/labhost path); CT 951 bind-mounts at CORPUS
CRAWL_ROOT = "/data/vms/retronet-crawl"  # crawl state + log live here (OUTSIDE the corpus; survives a worktree GC)
BUDGET_GB = 25.0  # default global size budget: the crawl stops cleanly near this (ZFS quota 50 GB backstop)
SITE_MB = 200  # default per-site byte cap so one big site (GeoCities) cannot eat the whole budget
CONCURRENCY = 10  # default parallel fetches: ~a browser's worth, throttled by the shared backoff gate


# --- crawl utilities --------------------------------------------------------

_log_lock = threading.Lock()


def _corpus_bytes(path):
    """Total bytes under the corpus via `du -sb` (fast C walk). 0 if absent -- the du-aware budget."""
    r = subprocess.run(["du", "-sb", path], capture_output=True, text=True)
    try:
        return int(r.stdout.split()[0])
    except (ValueError, IndexError):
        return 0


def _load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return default


def _log(path, msg):
    """Append one timestamped line to the progress log (thread-safe: concurrent workers may log)."""
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    with _log_lock, open(path, "a") as f:
        f.write(line + "\n")


def _extract_page_links(body, base, seed_host):
    """Same-site <a>/<frame> links in a raw HTML body, absolute and read-only (nothing rewritten)."""
    return [
        u
        for kind, u in core.extract_urls(body, base)
        if kind in ("link", "frame") and core.bare(core.host_of(u)) == core.bare(seed_host)
    ]


def _site_state(s, default_mb):
    """The per-site crawl record (JSON-serialisable) seeded from one era-sites.json entry."""
    host = core.norm_host(s["host"])
    return {
        "host": host,
        "date": s.get("date", "19970101"),
        "depth": int(s.get("depth", 1)),
        "max_pages": int(s.get("max_pages", 16)),
        "max_mb": int(s.get("max_mb", default_mb)),
        "title": s.get("title") or "",
        "blurb": s.get("blurb", ""),
        "category": s.get("category", ""),
        "home": "http://" + host + "/",
        "seen": [],  # every page URL discovered (a set at run time, a sorted list on disk)
        "frontier": {},  # "level" -> [page URLs discovered but not yet mirrored]
        "pages": 0,
        "bytes": 0,
        "fetched": 0,
        "assets": 0,
        "misses": 0,
        "skipped": 0,
        "done": {},  # "level" -> count of pages already mirrored at that depth (observability)
    }


def _reconstruct(st, staging):
    """Rebuild one site's breadth-first frontier from the on-disk corpus + link graph.

    Walks home -> its links -> ...: a page ON DISK is DONE and re-scanned (read-only) for the links
    that seed the next level; a discovered page NOT on disk becomes pending frontier at its level,
    capped at max_pages. Resources are NOT re-fetched here (they were mirrored when their page was).
    This IS the resume: the corpus is the authoritative record, so a restart -- or a deepened
    era-sites.json -- continues the even widening exactly where it left off and reaches new levels."""
    host, depth, max_pages = st["host"], st["depth"], st["max_pages"]
    seen, frontier, done = {st["home"]}, {}, {}
    cur, level, planned = [st["home"]], 0, 1
    while cur and level <= depth:
        nxt = []
        for url in cur:
            cached = core._have(staging, core.host_of(url), core.store_rel(url, True))
            if cached:
                done[level] = done.get(level, 0) + 1
                if level < depth and planned < max_pages:
                    try:
                        links = _extract_page_links(Path(cached).read_bytes(), url, host)
                    except OSError:
                        links = []
                    for u in links:
                        if u not in seen and planned < max_pages:
                            seen.add(u)
                            planned += 1
                            nxt.append(u)
            else:
                frontier.setdefault(level, []).append(url)
        cur, level = nxt, level + 1
    st["seen"] = sorted(seen)
    st["frontier"] = {str(k): v for k, v in frontier.items() if v}
    st["done"] = {str(k): v for k, v in done.items()}
    st["pages"] = sum(done.values())
    hp = os.path.join(staging, host)
    st["bytes"] = _corpus_bytes(hp) if os.path.isdir(hp) else 0
    return st


# --- one page / one resource, thread-safe -----------------------------------
#
# Network I/O (the slow part) runs LOCKLESS so ~CONCURRENCY pages are in flight at once; the shared
# mutable state (per-site counters, the global resource-dedup set, the running byte total, and the
# next-level frontier) is touched only under `lock`. Parallel writes land in distinct host/path files,
# so there is never a write conflict.


def _mirror_resource_mt(url, target, staging, res_seen, st, lock, budget):
    """Mirror one referenced resource (any host) raw + date-capped, concurrency-safe."""
    host = core.host_of(url)
    if not host:
        return
    with lock:
        if url in res_seen:
            return
        res_seen.add(url)
    rel = core.store_rel(url, False)
    dest = core._have(staging, host, rel)
    if dest:  # resume: already on disk -> no fetch
        with lock:
            st["skipped"] += 1
            st["bytes"] += os.path.getsize(dest)
        return
    ts = core.cdx_pick(url, target)  # network (paced) -- lockless
    if not ts:
        with lock:
            st["misses"] += 1  # only-post-2000 or uncaptured -> authentic miss
        return
    got = core.wayback_raw(url, ts)  # network (paced) -- lockless
    if not got or len(got[2]) > core.MAX_FETCH:
        with lock:
            st["misses"] += 1
        return
    core._write(staging, host, rel, got[2])
    with lock:
        st["assets"] += 1
        st["bytes"] += len(got[2])
        budget["written"] += len(got[2])


def _crawl_page(st, url, level, staging, res_seen, seen_set, lock, budget):
    """Mirror ONE page (or reuse it from disk), mirror its resources on a fresh fetch only, and file
    its same-site links under the NEXT depth level. Thread-safe: fetch is lockless, state under `lock`."""
    host = core.host_of(url)
    cached = core._have(staging, host, core.store_rel(url, True))
    if cached:
        body = Path(cached).read_bytes()
        page = core.is_html("", body)
        with lock:
            st["skipped"] += 1
    else:
        ts = core.cdx_pick(url, st["date"])  # network (paced) -- lockless
        if not ts:
            with lock:
                st["misses"] += 1  # only-post-2000 or uncaptured -> authentic miss
            return
        got = core.wayback_raw(url, ts)  # network (paced) -- lockless
        if not got or len(got[2]) > core.MAX_FETCH:
            with lock:
                st["misses"] += 1
            return
        _, ctype, body = got
        page = core.is_html(ctype, body)
        core._write(staging, host, core.store_rel(url, page), body)  # distinct file -> lockless
        with lock:
            st["fetched"] += 1
            st["bytes"] += len(body)
            budget["written"] += len(body)
        if page:
            for kind, u in core.extract_urls(body, url):
                if kind == "res":
                    _mirror_resource_mt(u, st["date"], staging, res_seen, st, lock, budget)
    if not page:
        return
    with lock:
        st["pages"] += 1
        st["done"][str(level)] = st["done"].get(str(level), 0) + 1
        if url == st["home"] and not st["title"]:
            mt = re.search(rb"<title[^>]*>(.*?)</title>", body, re.I | re.S)
            if mt:
                st["title"] = re.sub(r"\s+", " ", mt.group(1).decode("latin-1", "replace")).strip()
        if level < st["depth"]:
            for u in _extract_page_links(body, url, st["host"]):
                if u not in seen_set:
                    seen_set.add(u)
                    st["frontier"].setdefault(str(level + 1), []).append(u)


# --- manifest + state snapshots ---------------------------------------------


def _publish_sites(states, staging):
    """Upsert a sites.json row for every site with at least a home page -- so a newly-crawled site
    appears in the search directory as soon as its home lands. Merge, never replace: keep other
    streams' rows and each site's original `added` date."""
    existing = {s.get("host"): s for s in core._read_local_sites(staging)}
    ours = {}
    for st in states:
        if st["pages"] <= 0:
            continue
        row = {"host": st["host"], "title": st["title"] or st["host"], "blurb": st["blurb"]}
        row["added"] = existing.get(st["host"], {}).get("added") or date.today().isoformat()
        if st["category"]:
            row["category"] = st["category"]
        ours[st["host"]] = row
    merged = [s for s in existing.values() if s.get("host") not in ours] + list(ours.values())
    merged.sort(key=lambda s: s.get("host", ""))
    os.makedirs(staging, exist_ok=True)
    with open(os.path.join(staging, "sites.json"), "wb") as f:
        f.write(json.dumps(merged, indent=2, ensure_ascii=False).encode("utf-8"))


def _flush_state(path, states, level, used):
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
        }
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(snap, f, indent=2, sort_keys=True)
    os.replace(tmp, path)


# --- the parallel breadth-first driver --------------------------------------


def _interleave(per_site):
    """Round-robin flatten the per-site work lists so a mid-level budget stop still spreads coverage
    evenly across sites (site A's 1st page, site B's 1st, … then everyone's 2nd, …)."""
    return [item for row in zip_longest(*per_site) for item in row if item is not None]


def _run_level(items, concurrency, worker, on_done, should_stop):
    """Bounded parallel map over `items`: keep ~concurrency*2 fetches in flight, run worker(item) on the
    pool, call on_done(n) in THIS (driver) thread after the n-th completes. Stops feeding new work once
    should_stop() is true -- the in-flight tasks drain and a worker that sees the stop flag returns at
    once, so the pool empties fast. on_done runs while other workers are still live -> it must lock."""
    it = iter(items)
    n = 0
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        inflight = set()

        def fill():
            while len(inflight) < concurrency * 2 and not should_stop():
                try:
                    inflight.add(pool.submit(worker, next(it)))
                except StopIteration:
                    break

        fill()
        while inflight:
            done, _ = wait(inflight, return_when=FIRST_COMPLETED)
            for f in done:
                inflight.discard(f)
                f.result()  # worker swallows its own fetch errors; this surfaces only real bugs
                n += 1
                on_done(n)
            fill()
    return n


def cmd_crawl(a):
    """BREADTH-FIRST + PARALLEL global crawl over era-sites.json: widen every site together, one depth
    level at a time, ~CONCURRENCY fetches wide, sharing a global 429/503 backoff. Resumable from the
    on-disk corpus (the frontier is reconstructed), per-site max_mb-capped, stops cleanly at the global
    budget. Progress + per-level frontier are logged and in state.json."""
    core.RATE["min_interval"] = a.min_interval  # 0 for the wide crawl -> concurrency + backoff pace it
    concurrency = max(1, a.concurrency)
    os.umask(0o022)  # world-readable: CT 951's unprivileged proxy must read what CT 950 writes
    os.makedirs(a.staging, exist_ok=True)
    os.makedirs(os.path.dirname(a.state) or ".", exist_ok=True)
    cfg = _load_json(a.sites, [])
    if not cfg:
        raise SystemExit(f"era-press crawl: no sites in {a.sites}")
    states = [_reconstruct(_site_state(s, a.max_mb), a.staging) for s in cfg]
    seen_sets = {st["host"]: set(st["seen"]) for st in states}
    res_seen = set()  # global: a shared resource is mirrored once per run
    lock = threading.Lock()
    maxdepth = max((st["depth"] for st in states), default=0)
    base = _corpus_bytes(a.staging)
    budget = {"budget": int(a.budget_gb * 1_000_000_000), "base": base, "written": 0, "fetches": 0, "stop": False}
    pend = sum(len(v) for st in states for v in st["frontier"].values())
    resumed = sum(st["pages"] for st in states)
    _log(
        a.log,
        f"=== crawl start (breadth-first, {concurrency}-wide): {len(states)} sites, budget {a.budget_gb} GB, "
        f"maxdepth {maxdepth}; resumed {resumed} pages on disk, {pend} pending, corpus {base / 1e9:.2f} GB",
    )

    def used_est():
        return budget["base"] + budget["written"]

    def worker(item):
        """Fetch ONE page end-to-end (this runs on a pool thread; ~CONCURRENCY run at once). Network I/O
        is lockless; the per-site counters, dedup set and next-level frontier move under `lock`."""
        st, url, lvl = item
        with lock:
            if budget["stop"] or st["pages"] >= st["max_pages"] or st["bytes"] >= st["max_mb"] * 1_000_000:
                return  # capped or stopped -> skip; the page stays un-mirrored, resume re-discovers it
            seen_sets[st["host"]].add(url)
        try:
            _crawl_page(st, url, lvl, a.staging, res_seen, seen_sets[st["host"]], lock, budget)
        except (OSError, subprocess.SubprocessError, ValueError) as e:
            with lock:
                st["misses"] += 1  # one page must never abort the crawl
            _log(a.log, f"ERROR {st['host']} {url}: {e}")
        with lock:
            budget["fetches"] += 1
            if used_est() >= budget["budget"]:
                budget["stop"] = True

    def on_done(n):
        """Driver-thread callback after each completed fetch; every 50, reconcile the running byte
        estimate against the real corpus size and flush the observable state (locked: workers are live)."""
        if n % 50:
            return
        used = _corpus_bytes(a.staging)
        with lock:
            if used >= budget["budget"]:
                budget["stop"] = True
            _flush_state(a.state, states, level, used)
        _log(a.log, f"    … {budget['fetches']} fetches, corpus {used / 1e9:.2f} GB (est {used_est() / 1e9:.2f})")

    level = 0
    for level in range(maxdepth + 1):
        with lock:
            per_site = [[(st, u, level) for u in st["frontier"].pop(str(level), [])] for st in states]
        items = _interleave(per_site)
        active = sum(1 for p in per_site if p)
        _log(
            a.log,
            f"--- PASS {level}: {active} site(s), {len(items)} depth-{level} pages queued "
            f"(corpus {used_est() / 1e9:.2f} GB, {concurrency}-wide)",
        )
        _run_level(items, concurrency, worker, on_done, lambda: budget["stop"])
        used = _corpus_bytes(a.staging)
        _publish_sites(states, a.staging)  # newly-crawled sites appear in the directory as homes land
        _flush_state(a.state, states, level, used)
        covered = sum(1 for st in states if st["pages"] > 0)
        _log(a.log, f"--- PASS {level} done: {covered}/{len(states)} sites have >=1 page, corpus {used / 1e9:.2f} GB")
        if budget["stop"]:
            _log(a.log, f"BUDGET reached: {used / 1e9:.2f} GB -- stopping")
            break
    _publish_sites(states, a.staging)
    used = _corpus_bytes(a.staging)
    _flush_state(a.state, states, level, used)
    tot = sum(st["pages"] for st in states)
    end = "stopped at budget" if budget["stop"] else "complete"
    _log(a.log, f"=== crawl {end}: corpus {used / 1e9:.2f} GB, {tot} pages across {len(states)} sites")

#!/usr/bin/env python3
"""era_crawl -- the breadth-first, parallel, resumable corpus crawl behind `era-press.py crawl`.

Drives era-sites.json toward the global size budget by WIDENING EVERY SITE TOGETHER, one depth level
at a time: pass 0 mirrors every site's home, pass 1 every site's depth-1 links, pass 2 every site's
depth-2 links, … -- so an interrupted or budget-stopped crawl covers EVERY site to the same depth
(all homes, then all first levels, …), never a few sites deep and the rest empty.

Each pass runs on a stdlib thread pool (the fetch layer is blocking, so threads are the right
primitive). How many of those threads are actually in flight is NOT --concurrency: it is the adaptive
AIMD limiter in era_press_core, which climbs while archive.org answers cleanly and halves the moment it
signals (429/502/503, or a refused connection). So --concurrency is only the pool's upper bound; the
limiter finds the real ceiling, which moves hour to hour.

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
from itertools import zip_longest
from pathlib import Path

import era_fetch as fetch
import era_index
import era_press_core as core
import era_requests
import era_state
import era_sweep

SHARED_CORPUS = "/data/vms/retronet-corpus"  # big corpus volume (CT950/labhost path); CT 951 bind-mounts at CORPUS
# The miss-journal spool: the proxy in CT 951 writes here (mounted there as /var/spool/retronet), this
# side reads and rotates. Small, and OUTSIDE the corpus so the proxy never needs write access to what
# it serves. See scripts/retronet/web/install-requests-volume.sh.
# The absent/swept ledger: what archive.org has already refused, and which pages are fully walked.
# Set by cmd_crawl; None means "no memory", which is exactly the old behaviour.
ABSENT: era_sweep.Ledger | None = None

REQUESTS_DIR = "/data/vms/retronet-requests"
CRAWL_ROOT = "/data/vms/retronet-crawl"  # crawl state + log live here (OUTSIDE the corpus; survives a worktree GC)
VIP_DEFAULT_CEILING = "20091231"  # a VIP entry with no explicit ceiling still needs one
VIP_FIRST_DEPTH = 3  # VIPs are crawled this deep FIRST, then out to their full depth in the normal passes
REQUEST_INTERVAL = 300  # how often the daemon folds in what stations asked for and could not get
# A requested URL on a host we do not otherwise crawl has no era date of its own; this is the corpus's
# centre of gravity, and the id_ redirect resolves the nearest capture to it anyway.
REQUEST_DEFAULT_DATE = "19990101"
BUDGET_GB = 5.0  # default global size budget: the crawl stops cleanly near this (ZFS quota 50 GB backstop)
SITE_MB = 200  # default per-site byte cap so one big site (GeoCities) cannot eat the whole budget
CONCURRENCY = 12  # thread-pool UPPER bound; era_press_core's AIMD limiter decides how many really fly


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
    """Same-site <a>/<frame> links in a raw HTML body, absolute and read-only (nothing rewritten).
    Delegates to core.same_site_links -- ONE implementation shared with the serial mirror and _reconstruct,
    so the fresh-crawl frontier and the resume-reconstructed frontier are guaranteed identical URL sets."""
    return core.same_site_links(body, base, seed_host)


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
        # Per-site capture ceiling. None = the museum's hard 2000-12-31 rule; a VIP entry overrides it
        # because the site matters to this collection and did not exist before 2001 (see era-vips.json).
        "ceiling": s.get("ceiling"),
        "vip": bool(s.get("vip")),
        # VIPs are crawled to `first_depth` ahead of everything else, then extended to `depth` in the
        # ordinary passes -- high priority early, the long tail lazily.
        "first_depth": int(s.get("first_depth", s.get("depth", 1))),
        # Extra depth-0 start URLs. A site's home page is where a *visitor* starts, but it is not
        # where a 1990s OS starts: browsers, help viewers and desktop shortcuts point at deep,
        # specific paths (home.netscape.com/home/first.html, www.austin.ibm.com/pspinfo/os2.html)
        # that ordinary link-following from the home page may never reach. Seeding them as level-0
        # starts crawls them to the site's full depth like any other entry point.
        "seeds": [u for u in s.get("seeds", []) if u],
        "seen": [],  # every page URL discovered (a set at run time, a sorted list on disk)
        "mirrored": [],  # pages found ON DISK by _reconstruct -- what the resource sweep revisits
        "frontier": {},  # "level" -> [page URLs discovered but not yet mirrored]
        "pages": 0,
        "bytes": 0,
        "fetched": 0,
        "assets": 0,
        "misses": 0,
        "skipped": 0,
        "done": {},  # "level" -> count of pages already mirrored at that depth (observability)
        # The 14-digit stamp of the home capture actually chosen (landing completeness selection). This is
        # the ORIGINAL capture date /dir shows; persisted so it survives a resume (the corpus keeps only
        # raw bytes, not the stamp). Recovered from the previous state.json in cmd_crawl; empty until the
        # home is first fetched.
        "home_ts": "",
    }


def _reconstruct(st, staging):
    """Rebuild one site's breadth-first frontier from the on-disk corpus + link graph.

    Walks home -> its links -> ...: a page ON DISK is DONE and re-scanned (read-only) for the links
    that seed the next level; a discovered page NOT on disk becomes pending frontier at its level,
    capped at max_pages. Resources are NOT re-fetched here (they were mirrored when their page was).
    This IS the resume: the corpus is the authoritative record, so a restart -- or a deepened
    era-sites.json -- continues the even widening exactly where it left off and reaches new levels."""
    host, depth, max_pages = st["host"], st["depth"], st["max_pages"]
    starts = [st["home"]] + [u for u in st["seeds"] if u != st["home"]]
    seen, frontier, done, mirrored = set(starts), {}, {}, []
    cur, level, planned = list(starts), 0, len(starts)
    while cur and level <= depth:
        nxt = []
        for url in cur:
            cached = core._have(staging, core.host_of(url), core.store_rel(url, True))
            if cached:
                done[level] = done.get(level, 0) + 1
                mirrored.append(url)  # the resource sweep revisits every page already on disk
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
    st["mirrored"] = mirrored  # run-local (never persisted): input to the resource sweep
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


def _mirror_resource_mt(url, ts, staging, res_seen, st, lock, budget):
    """Mirror one referenced resource (any host) raw, concurrency-safe. `ts` is the resource's EXACT
    capture stamp from its host index -- a DIRECT id_ hit, no search. For a host with no index (a
    third-party image server) it is the site's era DATE and the id_ redirect resolves the capture; the
    RESOLVED stamp is re-checked below. A ts past the 2000-12-31 ceiling => skip (authentic miss)."""
    host = core.host_of(url)
    if not host:
        return
    with lock:
        if url in res_seen:
            return
        res_seen.add(url)
    if fetch._past_ceiling(ts, st["ceiling"]):
        with lock:
            st["misses"] += 1  # discovered ts already after the ceiling -> skip the fetch entirely
        return
    rel = core.store_rel(url, False)
    dest = core._have(staging, host, rel)
    if dest:  # resume: already on disk -> no fetch
        with lock:
            st["skipped"] += 1
            st["bytes"] += os.path.getsize(dest)
        return
    # Already asked, and the archive had nothing. Not for another 30 days: without this the sweep
    # re-requests every never-captured resource on every pass and every restart, forever.
    if ABSENT is not None and ABSENT.is_absent(url):
        with lock:
            st["misses"] += 1
        return
    got = fetch.wayback_raw(url, ts)  # id_ at the discovered ts (paced, lockless) -- but may resolve nearer
    # Re-check the RESOLVED ts: a resource the rewritten page rewrote to the PAGE's ts (because it wasn't
    # captured then) can resolve via id_ to its real, possibly post-2000, capture -- which must NOT store.
    if not got or fetch._past_ceiling(got[0], st["ceiling"]) or len(got[2]) > core.MAX_FETCH:
        with lock:
            st["misses"] += 1  # resolved capture past the ceiling (or a miss / oversize) -> skip
        if ABSENT is not None:
            ABSENT.mark_absent(url)  # an ARCHIVE verdict -- do not ask again for a month
        return
    if not core._write(staging, host, rel, got[2]):
        with lock:
            st["misses"] += 1  # URL/filesystem namespace collision -> cannot be mirrored
        return
    with lock:
        st["assets"] += 1
        st["bytes"] += len(got[2])
        budget["written"] += len(got[2])


def _crawl_page(st, url, level, staging, res_seen, seen_set, lock, budget):
    """Mirror ONE page (or reuse it from disk), mirror every resource it references that is not already
    on disk, and file its same-site links under the NEXT depth level. Thread-safe: fetch is lockless,
    state under `lock`. fetch_page pulls the raw id_ bytes at the exact capture stamp the site's host
    index gives, and discovers resources/links from the RAW body -- so a page and each of its resources
    is ONE fast fetch and no per-URL search. Links come from that same raw body, identical to
    _reconstruct, so resume rebuilds the same frontier.

    The resource sweep runs for a CACHED page too, and that is not an optimisation detail -- it is the
    difference between a usable exhibit and a broken one. Resources used to be mirrored only on a FRESH
    page fetch, so any page stored during a spell of failing fetches kept its missing images forever:
    the page was on disk, so the crawl never looked at it again. www.sun.com had 4 of 15 images and
    www.ibm.com 10 of 24 for exactly that reason. Re-sweeping costs a body read and a stat per
    reference; only a genuinely absent resource costs a request."""
    host = core.host_of(url)
    cached = core._have(staging, host, core.store_rel(url, True))
    if cached:
        body = Path(cached).read_bytes()
        page = core.is_html("", body)
        discovered = core.discover(body, url, st["date"]) if page else []
        with lock:
            st["skipped"] += 1
    else:
        # A landing page (home + section indexes) picks the most COMPLETE capture in the ceiling; a leaf
        # keeps the fast nearest-date pick. `level` is the page's depth, so the driver decides which it is.
        got = core.fetch_page(url, st["date"], st["ceiling"], landing=core._is_landing(url, level))
        if not got:
            with lock:
                st["misses"] += 1  # uncaptured, oversize, or past the ceiling -> authentic miss
            return
        _page_ts, page, body, discovered = got
        if not core._write(staging, host, core.store_rel(url, page), body):  # distinct file -> lockless
            with lock:
                st["misses"] += 1  # URL/filesystem namespace collision -> cannot be mirrored
            return
        with lock:
            st["fetched"] += 1
            st["bytes"] += len(body)
            budget["written"] += len(body)
            if url == st["home"] and page:
                st["home_ts"] = _page_ts  # the ORIGINAL capture date /dir shows (the chosen landing stamp)
    if page:  # each resource at its indexed exact ts -- one direct id_ hit, no search -- lockless
        for kind, res_ts, orig in discovered:
            if kind == "res":
                _mirror_resource_mt(orig, res_ts, staging, res_seen, st, lock, budget)
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


def load_sites(sites_path, vips_path):
    """The crawl's site list: era-sites.json, plus era-vips.json merged on top.

    The VIP list is a small, separate, hand-edited file on purpose -- it is the one place to add a site
    that matters to this collection regardless of the era rule, and keeping it separate is what makes
    it obvious what has been let past the ceiling. A VIP entry gets, unless it says otherwise: the
    VIP ceiling (so it can hold post-2000 captures), depth 5, and a `first_depth` of 3, which is the
    priority pass. A VIP whose host is already in era-sites.json REPLACES that entry, so a site can be
    promoted by adding it to the VIP list and nothing else."""
    sites = _load_json(sites_path, [])
    vips = _load_json(vips_path, []) if vips_path else []
    for v in vips:
        v = dict(v)
        v["vip"] = True
        v.setdefault("ceiling", VIP_DEFAULT_CEILING)
        v.setdefault("depth", 5)
        v.setdefault("first_depth", VIP_FIRST_DEPTH)
        v.setdefault("max_pages", 900)
        v.setdefault("max_mb", 900)
        sites = [s for s in sites if core.norm_host(s["host"]) != core.norm_host(v["host"])] + [v]
    return sites


def cmd_index(a):
    """Build every site's host index up front, SERIALLY and patiently -- the crawl's bootstrap.

    The crawl builds indexes in the background as it goes, which is right once it is warm but hopeless
    from cold: an index query is the heaviest request era-press makes, and 60 of them competing with
    the fetches means the crawl spends its first hour in the SLOW (redirect) regime, which is exactly
    the regime that provokes the throttling that stops the indexes landing. One serial pass breaks that
    loop -- one heavy query at a time is the shape archive.org tolerates best -- and after it the whole
    crawl runs on the fast exact-stamp path. Idempotent: an index already on disk is left alone."""
    era_index.INDEX_DIR = a.index_dir
    cfg = load_sites(a.sites, getattr(a, "vips", None))
    if not cfg:
        raise SystemExit(f"era-press index: no sites in {a.sites}")
    os.makedirs(a.index_dir, exist_ok=True)
    built = cached = failed = 0
    for i, s in enumerate(cfg, 1):
        host, since = core.bare(s["host"]), s.get("date", "19970101")
        era_index.register_site(s["host"], since, s.get("ceiling"))
        path = era_index._index_path(host, since)
        if os.path.exists(path):
            cached += 1
            continue
        t0 = time.time()
        era_index._build_index(host, since, core.norm_host(s["host"]), s.get("ceiling"))  # + disk cache
        rows = len(era_index._index.get(host) or {})
        built += bool(rows)
        failed += not rows
        note = "" if rows else "  (archive.org will not scan this host -> redirect route)"
        print(f"  [{i}/{len(cfg)}] {host:28} {rows:6d} urls  {time.time() - t0:5.1f}s{note}", flush=True)
    print(f"era-press index: {built} built, {cached} cached, {failed} un-indexable -> {a.index_dir}")


def cmd_crawl(a):
    """BREADTH-FIRST + PARALLEL global crawl over era-sites.json: widen every site together, one depth
    level at a time, as wide as the adaptive in-flight limiter allows. Resumable from the
    on-disk corpus (the frontier is reconstructed), per-site max_mb-capped, stops cleanly at the global
    budget. Progress + per-level frontier are logged and in state.json."""
    fetch.RATE["min_interval"] = a.min_interval  # 0 for the wide crawl -> concurrency + backoff pace it
    concurrency = max(1, a.concurrency)
    os.umask(0o022)  # world-readable: CT 951's unprivileged proxy must read what CT 950 writes
    os.makedirs(a.staging, exist_ok=True)
    os.makedirs(os.path.dirname(a.state) or ".", exist_ok=True)
    cfg = load_sites(a.sites, getattr(a, "vips", None))
    if not cfg:
        raise SystemExit(f"era-press crawl: no sites in {a.sites}")
    era_index.INDEX_DIR = os.path.join(os.path.dirname(a.state) or ".", "cdx")  # host indexes survive restarts
    global ABSENT  # what the archive has already refused, and which pages are fully walked
    ABSENT = era_sweep.Ledger(os.path.join(os.path.dirname(a.state) or ".", "absent.json"))
    for s in cfg:  # every crawled host earns ONE bulk CDX index; resource-only hosts take the redirect
        era_index.register_site(s["host"], s.get("date", "19970101"), s.get("ceiling"))
    states = [_reconstruct(_site_state(s, a.max_mb), a.staging) for s in cfg]
    # Recover each site's chosen home capture stamp from the previous run: a home already on disk is NOT
    # re-fetched (the corpus is the checkpoint), so without this its original date would be lost on resume.
    prev_sites = _load_json(a.state, {}).get("sites", {})
    for st in states:
        if not st["home_ts"]:
            st["home_ts"] = prev_sites.get(st["host"], {}).get("home_ts", "")
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
        """Driver-thread callback after each completed fetch; every 25, reconcile the running byte
        estimate against the real corpus size and flush the observable state (locked: workers are live)."""
        if n % 25:
            return
        used = _corpus_bytes(a.staging)
        with lock:
            if used >= budget["budget"]:
                budget["stop"] = True
            era_state.flush_state(a.state, states, level, used)
        _log(
            a.log,
            f"    … {budget['fetches']} fetches, corpus {used / 1e9:.2f} GB (est {used_est() / 1e9:.2f}), "
            f"in-flight limit {fetch._GATE.limit()}",  # AIMD: where archive.org's knee is right now
        )

    # --- station requests: what the retronet was asked for and could not answer ---------------------
    #
    # The disk scan behind era-sites.json can only find URLs that sit in a guest image as readable
    # text, and it can never know which of them anyone actually walks to. A miss knows. So the proxy
    # journals every miss and this thread folds the journal in every REQUEST_INTERVAL, mirroring
    # whatever has been asked for twice at least 15 minutes apart, most-asked first. It runs for the
    # whole life of the crawl, alongside the passes, sharing the same paced fetch layer -- so a page a
    # station wanted five minutes ago does not wait for a multi-hour pass to end.
    states_by_host = {core.bare(st["host"]): st for st in states}
    stop_requests = threading.Event()
    if a.requests:
        servicer = era_requests.Servicer(states_by_host, a.staging, res_seen, lock, budget, _mirror_resource_mt)
        threading.Thread(
            target=era_requests.watch,
            args=(a.requests_dir, a.requests_state, a.requests_interval, stop_requests, servicer),
            kwargs={"log": lambda m: _log(a.log, m), "halted": lambda: budget["stop"]},
            name="requests",
            daemon=True,
        ).start()
        _log(a.log, f"--- REQUESTS: watching for station requests every {a.requests_interval}s")

    level = 0  # bound BEFORE the sweep/priority passes: on_done closes over it, firing every 25 items

    def run_pass(label, items, active):
        """One pass of the driver: log it, run it wide, reconcile and log the result."""
        _log(
            a.log,
            f"--- {label}: {active} site(s), {len(items)} page(s) queued "
            f"(corpus {used_est() / 1e9:.2f} GB, {concurrency}-wide)",
        )
        _run_level(items, concurrency, worker, on_done, lambda: budget["stop"])
        era_state.publish_sites(states, a.staging)
        era_state.flush_state(a.state, states, level, _corpus_bytes(a.staging))

    vips = [st for st in states if st["vip"]]
    if vips:
        # High priority means FIRST -- ahead of the resource sweep as well as the ordinary passes.
        # The sweep re-checks thousands of pages already on disk and can run for an hour; a VIP added
        # five minutes ago should not wait behind it. The VIPs' remaining levels stay in the frontier
        # and the ordinary passes take them out to full depth -- deep early, long tail lazily.
        for level in range(max(st["first_depth"] for st in vips) + 1):
            due = [st for st in vips if level <= st["first_depth"]]
            items = _interleave([[(st, u, level) for u in st["frontier"].pop(str(level), [])] for st in due])
            if not items:
                continue
            run_pass(f"VIP PASS {level}", items, len(due))
            if budget["stop"]:
                break
        done = {st["host"]: st["pages"] for st in vips}
        _log(a.log, f"--- VIP priority done (to depth {VIP_FIRST_DEPTH}): {done}")

    if a.sweep:
        items = _interleave([[(st, u) for u in st["mirrored"]] for st in states])
        known = ABSENT.stats()
        _log(
            a.log,
            f"--- SWEEP: {len(items)} page(s) on disk; {known['swept']} already walked and unchanged "
            f"(skipped), {known['absent']} resource(s) the archive does not have (not re-asked)",
        )

        def sweep_worker(item):
            st, url = item
            try:
                era_sweep.sweep_page(st, url, a.staging, res_seen, lock, budget, ABSENT, _mirror_resource_mt)
            except (OSError, ValueError) as e:
                _log(a.log, f"ERROR sweep {st['host']} {url}: {e}")
            with lock:
                budget["fetches"] += 1

        _run_level(items, concurrency, sweep_worker, on_done, lambda: budget["stop"])
        ABSENT.save()  # batched during the pass; make the whole pass durable before the next one
        used = _corpus_bytes(a.staging)
        now = ABSENT.stats()
        _log(
            a.log,
            f"--- SWEEP done: corpus {used / 1e9:.2f} GB; ledger now {now['swept']} swept page(s), "
            f"{now['absent']} absent resource(s)",
        )

    for level in range(maxdepth + 1):
        with lock:
            per_site = [[(st, u, level) for u in st["frontier"].pop(str(level), [])] for st in states]
        items = _interleave(per_site)
        run_pass(f"PASS {level}", items, sum(1 for p in per_site if p))
        used = _corpus_bytes(a.staging)
        covered = sum(1 for st in states if st["pages"] > 0)
        _log(a.log, f"--- PASS {level} done: {covered}/{len(states)} sites have >=1 page, corpus {used / 1e9:.2f} GB")
        if budget["stop"]:
            _log(a.log, f"BUDGET reached: {used / 1e9:.2f} GB -- stopping")
            break
    stop_requests.set()
    if ABSENT is not None:
        ABSENT.save()
    era_state.publish_sites(states, a.staging)
    used = _corpus_bytes(a.staging)
    era_state.flush_state(a.state, states, level, used)
    tot = sum(st["pages"] for st in states)
    end = "stopped at budget" if budget["stop"] else "complete"
    _log(a.log, f"=== crawl {end}: corpus {used / 1e9:.2f} GB, {tot} pages across {len(states)} sites")

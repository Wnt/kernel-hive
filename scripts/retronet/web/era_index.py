#!/usr/bin/env python3
"""era_index -- the per-host capture index: which archived copy of a URL to fetch.

Choosing a capture is half of era-press's work, and every per-URL way to do it is
one of archive.org's slow endpoints. This module does it per HOST instead: one CDX
prefix query returns that host's whole capture index, after which pricing a URL is
a dict lookup and no network at all. The measured case for that is in the comments
below; the fetch layer it rides on is `era_fetch`.

An index is an OPTIMISATION, never a precondition -- ask for one and you get it if
it is ready, never a wait. A URL with no index is simply fetched at the era date
and Wayback's redirect resolves the capture.
"""

from __future__ import annotations

import contextlib
import json
import os
import threading
import urllib.parse

import era_fetch
from era_fetch import CEILING, INDEX_WORKERS, WB, _past_ceiling, bare, host_of, norm_host

# --- the host index: ONE CDX query per HOST, then only exact-ts raw fetches -------------------------
#
# Choosing a capture for a URL is the crawl's other half, and every cheap-looking way to do it per-URL
# is a slow archive.org endpoint. Measured on cold URLs, 8 in flight, same box, 2026-08-21:
#
#     id_ at an EXACT 14-digit stamp   ->  5.0 s median, 138 MB/hr, no errors      <- what we want
#     id_ at an 8-digit DATE (302)     ->  9.5 s median,  58 MB/hr, tarpit + 503s
#     the REWRITTEN page for discovery -> 15.7 s median,  36 MB/hr, heavy tarpit
#     CDX, one query per URL           ->  4-40 s each
#
# So neither per-URL route is affordable -- but the SAME CDX query, asked once for a whole host with
# `matchType=prefix`, returns that host's entire capture index in one response (measured: 27-40k URLs
# with exact stamps, ~3 MB, 70-130 s). Amortised over the thousands of objects the crawl pulls from that
# host, choosing a capture costs a DICT LOOKUP and no network at all, and every fetch is then the fast
# exact-stamp path. One query per host is also ~60 CDX calls for the whole 60-site corpus, against the
# tens of thousands the per-URL routes needed -- the endpoint's throttle stops mattering.
#
# Only hosts we are actually crawling get an index (`register_site`). A third-party resource host --
# one image from an ad server -- is not worth a 70 s query, so it falls back to the id_ redirect, which
# resolves the nearest capture itself; `mirror_resource` re-checks the RESOLVED stamp against the
# ceiling either way.

CDX = WB + "/cdx/search/cdx"
CDX_ROWS = 40000  # per-host index cap; a bigger site simply falls back to the redirect for the tail
# Index window widths to try, in order: the whole era-date-to-ceiling range, then a 6-month one. Just
# two, because narrowing does NOT rescue the true giants -- amazon.com 504s at every width down to one
# month (measured), since the CDX prefix scan is priced by how many captures the host has, not by the
# date filter. So the ladder is there for hosts that are merely large, and the giants fail fast and
# take the redirect route instead. See _fetch_index.
_INDEX_WINDOWS = (None, 6)
INDEX_DIR = None  # set by the crawl to a directory, so host indexes survive a restart

_index_lock = threading.Lock()
_index = {}  # bare host -> {index key: exact 14-digit ts}; {} means "indexed, nothing in the window"
_index_building = set()  # bare hosts whose query is in flight, so N workers trigger ONE of them
_index_pool_ref = []  # the background query pool (a list so it can be created lazily under the lock)
# bare host -> (era date, the EXACT host to query). The key is bare so `www.x.com` and `x.com` share
# one index, but the QUERY must use the configured host: `url=ibm.com&matchType=prefix` asks
# archive.org to scan every subdomain of ibm.com and 504s, where `url=www.ibm.com` answers in ~39 s.
_index_since = {}


def _index_pool():
    """The background pool that runs host-index queries. Deliberately tiny: an index query is a big,
    slow request and must never crowd the page fetches out of the in-flight budget it shares."""
    with _index_lock:
        if not _index_pool_ref:
            from concurrent.futures import ThreadPoolExecutor

            _index_pool_ref.append(ThreadPoolExecutor(max_workers=INDEX_WORKERS, thread_name_prefix="cdx-index"))
        return _index_pool_ref[0]


def register_site(host, since):
    """Declare a host as one we are crawling, so it earns a bulk index (see above). `since` is the
    site's era date: the index holds each URL's first capture on/after it, never past the ceiling."""
    with _index_lock:
        _index_since[bare(host)] = (since, norm_host(host))


def _index_key(url):
    """Index key for a URL: bare host + path, scheme-, port- and query-agnostic. CDX reports originals
    as `http://www.ibm.com:80/p`, pages reference `http://ibm.com/p`, and the corpus stores by path
    only -- so all three have to land on one key."""
    p = urllib.parse.urlsplit(url)
    return bare(p.hostname or "") + (p.path or "/")


def _index_path(host, since):
    return os.path.join(INDEX_DIR, f"{host}-{since}.json") if INDEX_DIR else None


def _window_end(since, months):
    """`since` (YYYYMMDD) advanced by whole months, clamped to the ceiling. Plain arithmetic on the
    date parts -- day-of-month is not preserved and does not need to be, this only bounds a scan."""
    y, m = int(since[:4]), int(since[4:6])
    m += months
    y, m = y + (m - 1) // 12, (m - 1) % 12 + 1
    return min(f"{y:04d}{m:02d}{since[6:8]}", CEILING)


def _fetch_index(query_host, since):
    """One CDX prefix query -> {index key: exact ts} for every URL on `query_host` in a window starting
    at `since`. `collapse=urlkey` keeps one row per URL (the first in the window, i.e. the closest to the
    era date from above). Returns {} if every attempt fails -- an absent index is not an error, it just
    means those URLs take the redirect route.

    The window NARROWS on failure, because on the biggest hosts the whole-window scan is more than
    archive.org's own gateway will sit through: amazon.com and ebay.com answer a two-year prefix query
    with a **504 at exactly 60 s**, every time, so no amount of client patience can win it -- the fix
    has to be asking for less. Halving the window in turn buys those hosts a real index covering the
    months nearest their era date, which is the part the crawl actually wants."""
    for months in _INDEX_WINDOWS:
        to = CEILING if months is None else _window_end(since, months)
        q = (
            f"url={urllib.parse.quote(query_host, '')}&matchType=prefix&collapse=urlkey"
            f"&filter=statuscode:200"
            f"&from={since}&to={to}&fl=original,timestamp&limit={CDX_ROWS}&output=json"
        )
        got = era_fetch.http_get(CDX + "?" + q, retries=2, index=True)
        if not got or not got[2].strip():
            continue  # timed out / refused at this width -> try a narrower window
        try:
            rows = json.loads(got[2])
        except json.JSONDecodeError:
            continue
        idx = {}
        for row in rows[1:]:  # row 0 is the field-name header
            if len(row) >= 2 and len(row[1]) == 14 and not _past_ceiling(row[1]):
                idx.setdefault(_index_key(row[0]), row[1])
        if idx:
            return idx
    return {}


def _read_cached_index(host, since):
    """The host's index from disk, or None. Cheap enough to do inline on the calling worker."""
    cache = _index_path(host, since)
    if not cache or not os.path.exists(cache):
        return None
    with contextlib.suppress(OSError, json.JSONDecodeError), open(cache) as f:
        return json.load(f)
    return None


def _build_index(host, since, query_host=None):
    """Query + cache one host's index. Runs on the index pool, NEVER on a fetch worker. `host` is the
    bare key the index is filed under; `query_host` is the exact host asked of CDX."""
    idx = _fetch_index(query_host or host, since)
    cache = _index_path(host, since)
    # An EMPTY index is cached too, on purpose: a host archive.org will not scan for us is a fact about
    # that host, not a transient error, and re-discovering it costs minutes of 504s on every run.
    # Delete the file to force a retry.
    if cache is not None:
        with contextlib.suppress(OSError):
            os.makedirs(os.path.dirname(cache), exist_ok=True)
            tmp = cache + ".tmp"
            with open(tmp, "w") as f:
                json.dump(idx, f)
            os.replace(tmp, cache)
    with _index_lock:
        _index[host] = idx


def host_index(host):
    """The bulk index for `host` IF it is ready, else None -- never a wait.

    A host index is an optimisation, not a precondition: without one a URL is simply fetched at the era
    date and Wayback's redirect resolves the capture. So asking for one must never block. It did, at
    first, and that alone stalled the crawl: 52 hosts each needing a 70-130 s prefix query, run on the
    fetch workers themselves and holding in-flight permits, meant the crawl spent its first quarter-hour
    building indexes at 2 connections instead of mirroring anything. Now the disk cache is read inline
    (cheap) and only the QUERY goes to a tiny background pool, so the crawl runs at full speed the whole
    time and simply gets faster as each index lands."""
    host = bare(host)
    with _index_lock:
        if host in _index:
            return _index[host]
        entry = _index_since.get(host)
        if entry is None or host in _index_building:
            return None  # unregistered host, or its query is already in flight -> redirect route
        since, query_host = entry
        _index_building.add(host)
    cached = _read_cached_index(host, since)
    if cached is not None:
        with _index_lock:
            _index[host] = cached
        return cached
    _index_pool().submit(_build_index, host, since, query_host)
    return None


def index_ts(url, target):
    """The exact capture stamp to fetch `url` at: its host index's entry, else `target` (a date, which
    the id_ redirect resolves for us). Never a per-URL search."""
    idx = host_index(host_of(url))
    return (idx or {}).get(_index_key(url)) or target

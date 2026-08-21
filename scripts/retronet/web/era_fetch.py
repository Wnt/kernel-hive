#!/usr/bin/env python3
"""era_fetch -- everything era-press knows about talking to archive.org.

One module, one job: get the raw bytes of an archived capture out of the Wayback
Machine as fast as archive.org will allow and no faster. That means the browser
header set, a reused HTTP/1.1 connection pool, an ADAPTIVE in-flight limiter that
finds archive.org's current knee instead of a hand-set rate, error handling that
tells a keep-alive race apart from a rate-limit signal, and the HOST INDEX -- one
bulk CDX query per host, so choosing which capture to fetch costs a dict lookup
rather than a per-URL search. The measured numbers behind each of those choices
are in the comments; they are the difference between ~6 MB/hr and ~250 MB/hr.

It knows nothing about the corpus: no paths, no files, no sites.json. That is
era_press_core's half, and it imports this one. See docs/lab/retronet/ERA-PRESS.md.
"""

from __future__ import annotations

import contextlib
import json
import os
import random
import re
import threading
import time
import urllib.parse

# NOTE: httpx is imported LAZILY (inside _get_client / http_get), never at module load. The offline
# self-test imports this module under the system python where httpx is NOT installed, so a top-level
# import would break it; deferring the import also guarantees no socket opens at import time.

WB = "https://web.archive.org"
# CDX is asked ONCE PER HOST, never per URL: it is archive.org's throttled endpoint (30-40 s/call), and
# a per-URL search -- or the rewritten-page discovery that replaced it -- is the whole bottleneck. See
# "the host index" below and docs/lab/retronet/ERA-PRESS.md.
# The crawler presents to web.archive.org as EXACTLY the box's real Chrome. These headers were captured
# from that Chrome over CDP (Network.requestWillBeSentExtraInfo) hitting web.archive.org: archive.org
# soft-throttles requests that don't look like a browser, and browsing it in Chrome stays fast. HTTP/2
# Host/cookie headers are added by httpx/the cookie jar. To refresh after a Chrome upgrade,
# re-read the on-wire headers over CDP (see docs/lab/retronet/ERA-PRESS.md § The fetch transport).
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
BROWSER_HEADERS = {
    "User-Agent": UA,
    # httpx decodes gzip/deflate natively and br/zstd via brotli+zstandard (in the venv), so whatever
    # archive.org sends is stored as the raw, decoded original (id_ actually comes back identity anyway).
    "Accept": (
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,"
        "image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"
    ),
    "Accept-Language": "en-US,en;q=0.9",
    "Accept-Encoding": "gzip, deflate, br, zstd",
    "sec-ch-ua": '"Not;A=Brand";v="8", "Chromium";v="150", "Google Chrome";v="150"',
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": '"Linux"',
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "same-origin",
    "Sec-Fetch-User": "?1",
    "Upgrade-Insecure-Requests": "1",
    "Referer": "https://web.archive.org/",
    "Priority": "u=0, i",
}
CEILING = "20001231"  # hard date ceiling: never mirror a capture past 2000-12-31
# Pacing: `crawl` runs ~CONCURRENCY fetches wide (a browser on the Wayback Machine does the same), so
# the throttle is NOT a serial gap -- it is the ADAPTIVE in-flight limiter below (`_GATE`) plus the
# shared throttle backoff, plus a little per-request jitter. `min_interval` is an optional global floor
# (0 for the wide crawl; press/seed keep a polite serial gap). RATE is a dict so a mutation is seen
# across modules.
RATE = {"min_interval": 0.8}
BACKOFF_MAX = 30.0  # cap for a single shared throttle backoff sleep
JITTER = 0.3  # per-request random spread so N concurrent workers do not fire in lockstep
# The edge's per-IP burst tarpit RSTs every NEW connection for a while once we cross its threshold.
# Measured 2026-08-21 on this box: refusal starts within seconds of a burst and clears in ~20 s. That
# is a fixed shared pause, NOT a per-thread exponential ramp -- see `_tarpit`.
TARPIT_PAUSE = 20.0
# A keep-alive reuse race (the edge closed a pooled connection between our checkout and our write) is
# not a signal about our rate: a browser silently opens a new connection and retries at once. So do we,
# this many times, without spending the real retry budget -- see `http_get`.
PROTOCOL_RACE_RETRIES = 3


# --- URL helpers (the fetch layer's own; the corpus path model builds on them) ------


def norm_host(h):
    return h.strip().lower().rstrip(".").split("/")[0]


def bare(h):
    h = norm_host(h)
    return h[4:] if h.startswith("www.") else h


def host_of(u):
    return (urllib.parse.urlsplit(u).hostname or "").lower()


_CEILING_TS = CEILING + "235959"  # 14-digit inclusive upper bound for a full capture stamp (2000-12-31)


def _past_ceiling(ts):
    """True if a capture stamp is after the hard 2000-12-31 ceiling. Takes either a 14-digit stamp or an
    8-digit YYYYMMDD date target (an un-indexed URL is fetched at a date), so pad before comparing --
    zero-padded numerals of equal width compare correctly as strings."""
    return ts.ljust(14, "0") > _CEILING_TS


def _is_archive_host(h):
    """archive.org itself (archive.org, web.archive.org, web-static.archive.org, …) -- Wayback's own
    infrastructure, never part of the mirrored 1990s site."""
    h = (h or "").lower()
    return h == "archive.org" or h.endswith(".archive.org")


# --- HTTP / Wayback: a shared, thread-safe pacing gate ----------------------
#
# EVERY archive.org request (a serial press/seed, or one of the crawl's ~10 concurrent workers) passes
# through _pace() before it fires and reports the outcome via _relax()/_penalize(). A 429/503 seen by
# ONE worker pushes a SHARED backoff_until deadline that ALL workers observe -- so the whole pool
# slows/pauses together (exponential if archive.org keeps signalling), which is what keeps 10-wide
# polite. The lock is held only for the bookkeeping, never across the sleep, so workers stay concurrent.

_pace_lock = threading.Lock()
_last_req = 0.0  # monotonic: last request start (the optional min-interval floor)
_backoff_until = 0.0  # monotonic: shared deadline every worker waits out after a rate-limit signal
_backoff_streak = 0  # consecutive rate-limit signals -> exponential escalation
# The CDX index API is a DIFFERENT backend from the replay path, with its own (much smaller) tolerance,
# and its queries are the heaviest requests the crawl makes. A 503 from one says "that index scan was
# too big for me", not "your IP is going too fast" -- so it must NOT halve the concurrency of the page
# fetches. Index queries therefore back off in their own lane. They still observe the SHARED window,
# because a refused connection or a replay-path 503 is a real IP-wide signal that stops everything.
_index_backoff_until = 0.0


class _InFlightGate:
    """AIMD limiter on CONCURRENT archive.org requests -- the crawl's real throttle.

    archive.org's tolerance is not a constant: it moves hour to hour with the edge's load, and the
    knee is narrow (measured 2026-08-21: ~2-4 clean req/s; past ~8 concurrent, replay latency balloons
    from ~3 s to ~30 s and 502/503s start). A hand-set rate is therefore always wrong soon after it is
    set -- either it leaves most of the ceiling unused, or it trips the tarpit and the crawl spends its
    life asleep. So the limiter FINDS the knee instead: additive increase (+1 permit per
    `_CLEAN_PER_STEP` clean responses) while archive.org is happy, multiplicative decrease (halve) the
    moment it signals -- a 429/503/502, or a refused connection. Worker threads park here, so the pool
    can stay wide while the number actually in flight tracks what archive.org will take right now.
    """

    _CLEAN_PER_STEP = 10  # +1 permit per this many clean responses...
    _QUIET_SECONDS = 20.0  # ...or after this long with no push-back, whichever comes first

    def __init__(self, start, lo, hi):
        self._cv = threading.Condition()
        self._limit, self._lo, self._hi = float(start), float(lo), float(hi)
        self._inflight = 0
        self._clean = 0
        self._last_step = time.monotonic()

    def __enter__(self):
        with self._cv:
            while self._inflight >= self._limit:
                self._cv.wait(1.0)
            self._inflight += 1
        return self

    def __exit__(self, *_exc):
        with self._cv:
            self._inflight -= 1
            self._cv.notify()
        return False

    def clean(self):
        """A clean response: additive increase, up to the ceiling.

        The step is granted on a clean-response COUNT *or* on quiet TIME, whichever comes first, and
        the time rule is not decoration -- it is what stops the limiter deadlocking itself. A
        count-only rule couples the climb to throughput, so a halved limit means fewer responses means
        a slower climb: the crawl sat at 2 permits for 15 minutes against a completely healthy IP
        (measured, 2026-08-21) because each 70-130 s host-index query returned so rarely that ten clean
        responses never accumulated. Quiet time recovers 2 -> 10 in about three minutes regardless."""
        with self._cv:
            self._clean += 1
            if self._limit >= self._hi:
                return
            now = time.monotonic()
            if self._clean >= self._CLEAN_PER_STEP or now - self._last_step >= self._QUIET_SECONDS:
                self._clean, self._last_step = 0, now
                self._limit = min(self._hi, self._limit + 1)
                self._cv.notify()

    def throttled(self):
        """archive.org pushed back: multiplicative decrease, down to the floor."""
        with self._cv:
            self._clean, self._last_step = 0, time.monotonic()
            self._limit = max(self._lo, self._limit / 2)

    def limit(self):
        with self._cv:
            return round(self._limit, 2)

    def ceiling(self):
        return int(self._hi)


# Starts at 4 (a browser's rough parallelism), ceiling 10 -- the measured knee for HTTP/1.1 connections
# to web.archive.org from one IP is ~10 connections (see the transport note below), and the 2-thread
# index pool sits outside this gate -- so the ceiling is 8, and 8 + 2 is the knee. Past it the edge
# refuses connections outright, so more permits buy refusals, not throughput. The floor is 2, not 1,
# so one slow request can never stall every worker behind it.
_GATE = _InFlightGate(4, 2, 8)


def _pace(index=False):
    """Block until it is polite to fire the next request, then jitter. Observed by every worker:
    (1) wait out the shared backoff window a tarpit or replay 503 opened -- plus, for a CDX index
    query, its own lane's window, (2) honor the optional min-interval floor, (3) sleep a small random
    jitter so concurrent workers spread out."""
    global _last_req
    while True:
        with _pace_lock:
            now = time.monotonic()
            until = max(_backoff_until, _last_req + RATE["min_interval"])
            if index:
                until = max(until, _index_backoff_until)
            wait = until - now
            if wait <= 0:
                _last_req = now  # claim this slot before releasing the lock
                break
        time.sleep(min(wait, BACKOFF_MAX))
    if JITTER:
        time.sleep(random.uniform(0, JITTER))


def _penalize(retry_after=None):
    """A 429/502/503 from archive.org: halve the in-flight limit AND push the SHARED backoff deadline
    out so the WHOLE pool pauses together -- honor a numeric Retry-After, else exponential 2,4,8… over
    the streak (capped at BACKOFF_MAX)."""
    global _backoff_until, _backoff_streak
    _GATE.throttled()
    with _pace_lock:
        _backoff_streak += 1
        secs = float(retry_after) if (retry_after or "").isdigit() else 2.0**_backoff_streak
        secs = min(secs, BACKOFF_MAX)
        _backoff_until = max(_backoff_until, time.monotonic() + secs)
    return secs


def _index_penalize(retry_after=None):
    """A 429/502/503 on a CDX index query: back off the INDEX lane only. The page fetches are talking
    to a different backend and keep their concurrency; the index simply lands later, and until it does
    its host takes the id_ redirect route."""
    global _index_backoff_until
    with _pace_lock:
        secs = float(retry_after) if (retry_after or "").isdigit() else 30.0
        _index_backoff_until = max(_index_backoff_until, time.monotonic() + min(secs, 120.0))


def _tarpit():
    """The edge REFUSED a new connection -- its per-IP burst tarpit, which RSTs every new connection
    for ~TARPIT_PAUSE seconds and then clears on its own.

    This is one outage shared by every worker, so it gets ONE shared pause. The old per-thread
    exponential ramp was the single worst thing the crawl did to itself: each worker independently
    slept 2,4,8,16 s on an outage that had already cleared, then gave the page up as a permanent miss.
    Halve the in-flight limit too, so we come back UNDER the threshold rather than straight into it."""
    global _backoff_until
    _GATE.throttled()
    with _pace_lock:
        _backoff_until = max(_backoff_until, time.monotonic() + TARPIT_PAUSE)


def _relax():
    """A clean (non-rate-limited) response: relax the exponential streak one notch (so a transient 429
    does not keep the whole pool slow forever) and credit the in-flight limiter's additive increase."""
    global _backoff_streak
    if _backoff_streak:
        with _pace_lock:
            _backoff_streak = max(0, _backoff_streak - 1)
    _GATE.clean()


def _backoff(attempt, retry_after=None):
    """Local per-thread sleep for a transient (non-rate-limit) error: honor a numeric Retry-After,
    else exponential (2,4,8… capped)."""
    secs = float(retry_after) if (retry_after or "").isdigit() else 2.0**attempt
    time.sleep(min(secs, BACKOFF_MAX))


# --- persistent connection reuse: the cure for self-inflicted NAT/conntrack exhaustion -------------
#
# The crawl fires thousands of archive.org requests. Opening a BRAND-NEW TCP+TLS connection per request
# (the old urllib.urlopen-per-call transport), ~10 workers wide, saturated the LAN router's NAT/conntrack
# table for CT950's flow to the archive edge and got ~5 of every 6 new connections RST'd -- the crawl
# throttled itself to ~MB/hr and knocked other hosts off web.archive.org. The cure is ONE shared
# httpx.Client over a small, bounded pool of PERSISTENT keep-alive connections: a handful total, not
# thousands, and not even one per thread. httpx's sync Client is thread-safe, so every worker shares
# this one client. It is built LAZILY on first use (double-checked lock), so importing this module opens
# NO socket AND needs NO httpx installed -- the offline self-test, run under the system python without
# httpx, still imports and passes.
#
# **HTTP/1.1, not HTTP/2, and that is measured.** Chrome negotiates h2 to web.archive.org, so the first
# cut did too -- but a browser opens a handful of streams on it, and a crawl opens a flood, and
# archive.org's h2 edge answers a flood by queueing it and then shedding it. Same box, same cold URLs,
# 90 s each (2026-08-21):
#
#     h2, 4 connections, 6 in flight   ->  0.44 req/s,  58 MB/hr, median 6.0 s, p90 60 s
#     h1, 6 connections, 6 in flight   ->  1.71 req/s, 204 MB/hr, median 2.8 s, p90  6.0 s, 0 errors
#     h1, 10 connections, 10 in flight ->  2.27 req/s, 256 MB/hr, median 2.4 s, p90  6.0 s  <- the knee
#     h1, 16 connections, 16 in flight ->  2.13 req/s, 226 MB/hr, 55% of connections REFUSED (tarpit)
#
# Under h2 half of all requests also came back RemoteProtocolError (the edge resetting multiplexed
# streams); under h1 that failure mode disappears entirely. So: one request per connection, and let the
# AIMD gate above size the pool -- because the thing archive.org actually limits IS the number of
# concurrent connections from one IP, and with h1 the gate's permits ARE connections.

_client = None  # the one shared httpx.Client (HTTP/1.1, small bounded pool); created on first http_get
_client_lock = threading.Lock()


def _get_client():
    """The process-wide shared httpx.Client, created on first use. HTTP/1.1 keep-alive over a pool capped
    at the in-flight gate's ceiling: established connections track that cap, never the request count,
    which is the NAT fix. Do not raise the cap past the measured knee (see above) -- beyond it the edge
    refuses connections and throughput falls. Sends the full browser header set (BROWSER_HEADERS) and
    keeps a cookie jar, so archive.org sees a real Chrome. Import is lazy so the offline self-test
    (system python, no httpx) still imports this."""
    global _client
    if _client is None:
        with _client_lock:
            if _client is None:
                import httpx

                pool = _GATE.ceiling() + INDEX_WORKERS  # fetch permits + the index pool's own lane
                c = httpx.Client(
                    http2=False,  # measured: h2 multiplexing is 4x SLOWER here and resets streams
                    http1=True,
                    follow_redirects=True,  # the id_ 302 -> nearest-snapshot redirect must still be followed
                    headers=BROWSER_HEADERS,  # byte-for-byte the box's Chrome (captured over CDP)
                    timeout=httpx.Timeout(60.0, connect=15.0),  # 60s read timeout, preserved from before
                    limits=httpx.Limits(max_connections=pool, max_keepalive_connections=pool, keepalive_expiry=90),
                )
                # Prime the cookie jar like a browser's first visit: archive.org's homepage sets the
                # server-affinity + donation-identifier cookies, and httpx (which keeps a jar by default)
                # then resends them on every request -- so even the first id_ fetch carries cookies,
                # exactly like the Chrome the operator watched browse archive.org fast. Best-effort.
                with contextlib.suppress(httpx.HTTPError):
                    c.get("https://web.archive.org/")
                _client = c
    return _client


def http_get(url, retries=5, index=False):
    """GET url, following redirects, over the shared HTTP/1.1 client (a handful of reused connections carry
    the whole crawl -- no new TCP+TLS connection, and no new NAT entry, per request). Return
    (final_url, content_type, body) or None. Contract unchanged -- callers are too.

    What a failure MEANS decides what it costs, and getting that wrong is what made the crawl slow.
    Measured on the deployed crawl 2026-08-21 (3 workers, 360 s): 115 requests, 13 of them successful,
    and 482 of ~1080 thread-seconds spent asleep -- because every failure, whatever it was, drew the
    same per-thread exponential 2,4,8,16 s sleep and then gave the URL up as a permanent miss. The
    three failures are three different things:

    * a **keep-alive reuse race** (the edge closed a pooled connection under us) says nothing about our
      rate -- retry AT ONCE on a fresh connection, as a browser does, and don't spend the retry budget;
    * a **refused connection** is the per-IP burst tarpit, one outage shared by every worker -- ONE
      shared ~20 s pause and halve the in-flight limit (`_tarpit`), not N independent ramps;
    * a **429/502/503** is archive.org asking for less -- shared backoff and halve the limit
      (`_penalize`).
    """
    import httpx

    client = _get_client()
    attempt = 0
    races = 0
    while attempt < retries:
        _pace(index)
        try:
            if index:  # an index query is capped by its own 2-thread pool, not the fetch budget
                resp = client.get(url)
            else:
                with _GATE:
                    resp = client.get(url)
        except (httpx.RemoteProtocolError, httpx.LocalProtocolError, httpx.ReadError, httpx.WriteError):
            races += 1  # connection-reuse race -> new connection, immediately, off the retry budget
            if races > PROTOCOL_RACE_RETRIES:
                return None
            continue
        except (httpx.ConnectError, httpx.ConnectTimeout):
            _tarpit()  # the shared per-IP burst tarpit: one pause for the whole pool, then resume
            attempt += 1
            continue
        except httpx.HTTPError:
            # what is left of httpx.HTTPError: read/write timeouts, TooManyRedirects, pool timeouts.
            attempt += 1
            if attempt >= retries:
                return None
            _backoff(attempt)
            continue
        except (httpx.InvalidURL, ValueError, UnicodeError):
            return None  # a malformed URL is not transient -> authentic miss (as the old urllib path did)
        status = resp.status_code
        if status in (429, 502, 503):
            retry_after = resp.headers.get("Retry-After")
            _index_penalize(retry_after) if index else _penalize(retry_after)
            attempt += 1
            if attempt >= retries:
                return None
            continue
        if status in (404, 403):
            return None
        if 200 <= status < 300:
            _relax()
            return str(resp.url), (resp.headers.get("content-type") or ""), resp.content
        # any other HTTP status (a 4xx/5xx not special-cased above): treat as transient -> backoff + retry
        attempt += 1
        if attempt >= retries:
            return None
        _backoff(attempt)
    return None


def wayback_raw(url, timestamp):
    """Fetch the raw (id_) archived bytes of url at timestamp. `timestamp` may be a generic 8-digit
    YYYYMMDD (the id_ redirect resolves the nearest capture cheaply for a single URL, ~1s) OR an EXACT
    14-digit stamp (a direct hit, no search). Returns (resolved_14-digit_ts, ctype, body) -- the ts is
    read back from the redirected final URL, so a generic request still tells us the exact capture."""
    got = http_get(f"{WB}/web/{timestamp}id_/{url}")
    if not got:
        return None
    final, ctype, body = got
    m = re.search(r"/web/(\d{14})", final)
    return (m.group(1) if m else timestamp), ctype, body


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
INDEX_DIR = None  # set by the crawl to a directory, so host indexes survive a restart

_index_lock = threading.Lock()
_index = {}  # bare host -> {index key: exact 14-digit ts}; {} means "indexed, nothing in the window"
_index_building = set()  # bare hosts whose query is in flight, so N workers trigger ONE of them
_index_pool_ref = []  # the background query pool (a list so it can be created lazily under the lock)
INDEX_WORKERS = 2  # concurrent host-index queries: tiny, and OUTSIDE the fetch gate
_index_since = {}  # bare host -> the site's era date; only registered hosts get an index


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
        _index_since[bare(host)] = since


def _index_key(url):
    """Index key for a URL: bare host + path, scheme-, port- and query-agnostic. CDX reports originals
    as `http://www.ibm.com:80/p`, pages reference `http://ibm.com/p`, and the corpus stores by path
    only -- so all three have to land on one key."""
    p = urllib.parse.urlsplit(url)
    return bare(p.hostname or "") + (p.path or "/")


def _index_path(host, since):
    return os.path.join(INDEX_DIR, f"{host}-{since}.json") if INDEX_DIR else None


def _fetch_index(host, since):
    """One CDX prefix query -> {index key: exact ts} for every URL on `host` captured in
    [since, CEILING]. `collapse=urlkey` keeps one row per URL (the first in the window, i.e. the
    closest to the era date from above). Returns {} on any failure -- an absent index is not an error,
    it just means those URLs take the redirect route."""
    q = (
        f"url={urllib.parse.quote(host, '')}&matchType=prefix&collapse=urlkey&filter=statuscode:200"
        f"&from={since}&to={CEILING}&fl=original,timestamp&limit={CDX_ROWS}&output=json"
    )
    got = http_get(CDX + "?" + q, retries=3, index=True)
    if not got or not got[2].strip():
        return {}
    try:
        rows = json.loads(got[2])
    except json.JSONDecodeError:
        return {}
    idx = {}
    for row in rows[1:]:  # row 0 is the field-name header
        if len(row) >= 2 and len(row[1]) == 14 and not _past_ceiling(row[1]):
            idx.setdefault(_index_key(row[0]), row[1])
    return idx


def _read_cached_index(host, since):
    """The host's index from disk, or None. Cheap enough to do inline on the calling worker."""
    cache = _index_path(host, since)
    if not cache or not os.path.exists(cache):
        return None
    with contextlib.suppress(OSError, json.JSONDecodeError), open(cache) as f:
        return json.load(f)
    return None


def _build_index(host, since):
    """Query + cache one host's index. Runs on the index pool, NEVER on a fetch worker."""
    idx = _fetch_index(host, since)
    cache = _index_path(host, since)
    if cache and idx:
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
        since = _index_since.get(host)
        if since is None or host in _index_building:
            return None  # unregistered host, or its query is already in flight -> redirect route
        _index_building.add(host)
    cached = _read_cached_index(host, since)
    if cached is not None:
        with _index_lock:
            _index[host] = cached
        return cached
    _index_pool().submit(_build_index, host, since)
    return None


def index_ts(url, target):
    """The exact capture stamp to fetch `url` at: its host index's entry, else `target` (a date, which
    the id_ redirect resolves for us). Never a per-URL search."""
    idx = host_index(host_of(url))
    return (idx or {}).get(_index_key(url)) or target

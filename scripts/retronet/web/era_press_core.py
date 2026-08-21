#!/usr/bin/env python3
"""era-press core -- the shared, importable library behind era-press.py + era_crawl.py.

The reusable primitives for the date-capped `id_` archival mirror: the polite
archive.org fetch layer (a shared pacing gate + Wayback CDX/`id_` fetch), the
URL->file path model, read-only URL discovery, the raw mirror, and the
stage->`pct push` transport. No transformation happens anywhere here -- original
bytes, Content-Type and charset are kept as-is. See docs/lab/retronet/ERA-PRESS.md.

It is a plain underscore-named module so era_crawl.py, era-press.py and the
offline self-test can all `import era_press_core` (the CLI entry keeps its
`era-press.py` hyphen; only this library needs to be importable).
"""

from __future__ import annotations

import json
import os
import random
import re
import subprocess
import threading
import time
import urllib.parse
from collections import deque
from pathlib import Path
from shutil import which

# NOTE: httpx is imported LAZILY (inside _get_client / http_get), never at module load. The offline
# self-test imports this module under the system python where httpx is NOT installed, so a top-level
# import would break it; deferring the import also guarantees no socket opens at import time.

WB = "https://web.archive.org"
CDX = WB + "/cdx/search/cdx"
# A real Chrome UA -- archive.org negotiates HTTP/2 to it exactly as it does to a live browser, and it
# reads as a browser rather than a bot. The old era-press/1.0 UA is dropped.
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
CORPUS = "/data/retronet/corpus"  # in CT 951 AND the local staging default
CT_DEFAULT, SSH_DEFAULT = "951", "lab"
CEILING = "20001231"  # hard date ceiling: never mirror a capture past 2000-12-31
MAX_FETCH = 8 * 1024 * 1024  # guardrail: skip (do not truncate) a resource bigger than this
# Pacing: `crawl` runs ~CONCURRENCY fetches wide (a browser on the Wayback Machine does the same), so
# the throttle is NOT a serial gap -- it is the concurrency cap + the shared 429/503 backoff below,
# plus a little per-request jitter. `min_interval` is an optional global floor (0 for the wide crawl;
# press/seed keep a polite serial gap). RATE is a dict so a mutation is seen across modules.
RATE = {"min_interval": 0.8}
BACKOFF_MAX = 120.0  # cap for a single 429/503 backoff sleep
JITTER = 0.3  # per-request random spread so N concurrent workers do not fire in lockstep

# read-only URL discovery: which (tag, attr) pairs carry which kind of URL
_RES = (
    "img.src img.lowsrc script.src input.src embed.src bgsound.src object.data source.src "
    "link.href body.background table.background td.background th.background tr.background"
)
ATTR_KIND = {
    tuple(p.split(".")): k
    for pairs, k in ((_RES, "res"), ("a.href area.href", "link"), ("frame.src iframe.src", "frame"))
    for p in pairs.split()
}


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


def _pace():
    """Block until it is polite to fire the next request, then jitter. Observed by every worker:
    (1) wait out any shared backoff window a 429/503 opened, (2) honor the optional min-interval
    floor, (3) sleep a small random jitter so concurrent workers spread out."""
    global _last_req
    while True:
        with _pace_lock:
            now = time.monotonic()
            until = max(_backoff_until, _last_req + RATE["min_interval"])
            wait = until - now
            if wait <= 0:
                _last_req = now  # claim this slot before releasing the lock
                break
        time.sleep(min(wait, BACKOFF_MAX))
    if JITTER:
        time.sleep(random.uniform(0, JITTER))


def _penalize(retry_after=None):
    """A 429/503 from archive.org: push the SHARED backoff deadline out so the WHOLE pool pauses
    together -- honor a numeric Retry-After, else exponential 2,4,8… over the streak (capped)."""
    global _backoff_until, _backoff_streak
    with _pace_lock:
        _backoff_streak += 1
        secs = float(retry_after) if (retry_after or "").isdigit() else 2.0**_backoff_streak
        secs = min(secs, BACKOFF_MAX)
        _backoff_until = max(_backoff_until, time.monotonic() + secs)
    return secs


def _relax():
    """A clean (non-rate-limited) response relaxes the exponential streak one notch, so a transient
    429 does not keep the whole pool slow forever."""
    global _backoff_streak
    if _backoff_streak:
        with _pace_lock:
            _backoff_streak = max(0, _backoff_streak - 1)


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
# throttled itself to ~MB/hr and knocked other hosts off web.archive.org. The cure is the fullest browser
# route: ONE shared httpx.Client speaking HTTP/2 to web.archive.org (exactly what Chrome negotiates), so
# every worker's request is MULTIPLEXED over a tiny, bounded pool of persistent connections -- a handful
# total, not thousands, and not even one-per-thread. httpx's sync Client is thread-safe, so all
# ~CONCURRENCY workers share this single client. It is built LAZILY on first use (double-checked lock),
# so importing this module opens NO socket AND needs NO httpx installed -- the offline self-test, run
# under the system python without httpx, still imports and passes.

_client = None  # the one shared httpx.Client (HTTP/2, small bounded pool); created on first http_get
_client_lock = threading.Lock()


def _get_client():
    """The process-wide shared httpx.Client, created on first use. HTTP/2 multiplexing lets a SMALL pool
    (max_connections=4) carry the whole ~10-wide crawl, which is the entire NAT fix: established
    connections track the pool cap (~4), never the request count. Kept small on purpose -- do not raise
    it. Import is lazy so the offline self-test (system python, no httpx) still imports this module."""
    global _client
    if _client is None:
        with _client_lock:
            if _client is None:
                import httpx

                _client = httpx.Client(
                    http2=True,
                    follow_redirects=True,  # the id_ 302 -> nearest-snapshot redirect must still be followed
                    headers={"User-Agent": UA},
                    timeout=httpx.Timeout(60.0, connect=15.0),  # 60s read timeout, preserved from before
                    limits=httpx.Limits(max_connections=4, max_keepalive_connections=4, keepalive_expiry=30),
                )
    return _client


def http_get(url, retries=5):
    """GET url, following redirects, over the shared HTTP/2 client (a handful of reused connections carry
    the whole crawl -- no new TCP+TLS connection, and no new NAT entry, per request). Return
    (final_url, content_type, body) or None. Passes through the shared pacing gate; a 429/503 backs off
    the WHOLE crawl pool (globally), other errors retry locally. Contract unchanged -- callers are too."""
    import httpx

    client = _get_client()
    for attempt in range(retries):
        _pace()
        try:
            resp = client.get(url)
        except httpx.HTTPError:
            # httpx.HTTPError subsumes TimeoutException + TransportError (the transient transport/timeout/
            # protocol errors) + TooManyRedirects -> local backoff + retry, exactly as urllib's URLError did.
            if attempt >= retries - 1:
                return None
            _backoff(attempt + 1)
            continue
        except (httpx.InvalidURL, ValueError, UnicodeError):
            return None  # a malformed URL is not transient -> authentic miss (as the old urllib path did)
        status = resp.status_code
        if status in (429, 503):
            _penalize(resp.headers.get("Retry-After"))  # shared, whole-pool backoff
            if attempt >= retries - 1:
                return None
            continue
        if status in (404, 403):
            return None
        if 200 <= status < 300:
            _relax()
            return str(resp.url), (resp.headers.get("content-type") or ""), resp.content
        # any other HTTP status (a 4xx/5xx not special-cased above): treat as transient -> backoff + retry
        if attempt >= retries - 1:
            return None
        _backoff(attempt + 1)
    return None


def cdx_pick(url, target):
    """Enumerate 200-status captures of url on/before the ceiling via CDX; return the
    timestamp closest to target (YYYYMMDD). None => only-post-2000 or uncaptured => skip."""
    q = f"output=json&filter=statuscode:200&collapse=digest&limit=400&to={CEILING}&url={urllib.parse.quote(url, '')}"
    got = http_get(CDX + "?" + q)
    if not got or not got[2].strip():
        return None
    try:
        rows = json.loads(got[2])
    except json.JSONDecodeError:
        return None
    if len(rows) < 2:
        return None
    # Compare on the FULL 14-digit timestamp: an 8-digit YYYYMMDD target (int 1.9e7) next to
    # 14-digit capture stamps (int 1.9e13) would otherwise always resolve to the EARLIEST capture,
    # not the one nearest the era-date. Pad the target to 14 digits so "closest" is truly temporal.
    t = int(target.ljust(14, "0"))
    return min(rows[1:], key=lambda r: abs(int(r[1]) - t))[1]


def wayback_raw(url, timestamp):
    """Fetch the raw (id_) archived bytes of url at timestamp. Return (ts, ctype, body)."""
    got = http_get(f"{WB}/web/{timestamp}id_/{url}")
    if not got:
        return None
    final, ctype, body = got
    m = re.search(r"/web/(\d{14})", final)
    return (m.group(1) if m else timestamp), ctype, body


# --- URL / path model -------------------------------------------------------


def norm_host(h):
    return h.strip().lower().rstrip(".").split("/")[0]


def bare(h):
    h = norm_host(h)
    return h[4:] if h.startswith("www.") else h


def host_of(u):
    return (urllib.parse.urlsplit(u).hostname or "").lower()


def is_html(ctype, body):
    if "html" in ctype.lower():
        return True
    if "image" in ctype.lower() or "javascript" in ctype.lower() or "css" in ctype.lower():
        return False
    return body.lstrip()[:200].lower().startswith((b"<!doct", b"<html", b"<head", b"<title", b"<frameset"))


def store_rel(url, page):
    """Corpus file path (under the host dir) for url. dir/'' -> index.html; an
    extensionless PAGE path -> its own dir's index.html. Query is dropped."""
    path = urllib.parse.urlsplit(url).path or "/"
    if path.endswith("/") or path == "":
        return path.lstrip("/") + "index.html"
    seg = path.rsplit("/", 1)[-1]
    if page and "." not in seg:
        return path.lstrip("/") + "/index.html"
    return path.lstrip("/")


# --- discovery (read-only) --------------------------------------------------

_ATTR = re.compile(r'([a-zA-Z_:][\w:.-]*)(?:\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+))?')
_TAG = re.compile(r"<(/?)([a-zA-Z][\w:-]*)((?:[^<>])*)>")
_JUNK = ("#", "javascript:", "mailto:", "data:", "news:", "tel:", "about:", "ftp:")


def extract_urls(body, base):
    """Return [(kind, abs_url)] of resources/links/frames referenced by the raw HTML.
    Read-only: nothing is rewritten. Decoded leniently as latin-1 just to scan tags."""
    text = body.decode("latin-1", "replace")
    out = []
    for m in _TAG.finditer(text):
        if m.group(1):
            continue
        tag, attrs = m.group(2).lower(), m.group(3)
        ad = {}
        for am in _ATTR.finditer(attrs):
            if am.group(2) is not None:
                v = am.group(2)
                ad[am.group(1).lower()] = v[1:-1] if v[:1] in "\"'" else v
        if tag == "meta" and ad.get("http-equiv", "").lower() == "refresh":
            mm = re.search(r"url\s*=\s*(\S+)", ad.get("content", ""), re.I)
            if mm:
                out.append(("link", urllib.parse.urljoin(base, mm.group(1))))
            continue
        for attr, val in ad.items():
            kind = ATTR_KIND.get((tag, attr))
            u = val.strip()
            if kind and u and not u.lower().startswith(_JUNK):
                out.append((kind, urllib.parse.urljoin(base, u)))
    return out


# --- mirror -----------------------------------------------------------------


def _dest(staging, host, rel):
    """Absolute corpus path for (host, rel), or None if it would escape the host dir."""
    rel = rel.replace("..", "_").lstrip("/")
    dest = os.path.normpath(os.path.join(staging, host, rel))
    return dest if dest.startswith(os.path.normpath(os.path.join(staging, host))) else None


def _have(staging, host, rel):
    """RESUME: is this resource/page already mirrored (non-empty on disk)? The corpus IS the checkpoint."""
    dest = _dest(staging, host, rel)
    return dest if (dest and os.path.isfile(dest) and os.path.getsize(dest)) else None


def _write(staging, host, rel, body):
    dest = _dest(staging, host, rel)
    if not dest:
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "wb") as f:
        f.write(body)


def mirror_resource(url, target, staging, seen, hosts, stats):
    """Mirror one referenced resource (any host) at its own host/path, raw and date-capped."""
    host = host_of(url)
    if not host or url in seen:
        return
    seen.add(url)
    rel = store_rel(url, False)
    dest = _have(staging, host, rel)
    if dest:  # resume: already on disk -> no fetch
        hosts.add(host)
        stats["skipped"] += 1
        stats["bytes"] += os.path.getsize(dest)
        return
    ts = cdx_pick(url, target)
    if not ts:
        stats["misses"] += 1  # only-post-2000 or uncaptured -> authentic miss
        return
    got = wayback_raw(url, ts)
    if not got or len(got[2]) > MAX_FETCH:
        stats["misses"] += 1
        return
    _write(staging, host, rel, got[2])
    hosts.add(host)
    stats["assets"] += 1
    stats["bytes"] += len(got[2])


def mirror_site(seed_host, target, depth, max_pages, staging, max_bytes=None):
    """Crawl+mirror a site into staging. Return (title, stats, hosts_written). RESUMABLE (skips
    pages/assets already on disk, reusing cached pages to keep traversing) and byte-capped (max_bytes)."""
    seed_host = norm_host(seed_host)
    seed_url = "http://" + seed_host + "/"
    seen_pages, seen_res, hosts, title = {seed_url}, set(), set(), ""
    stats = dict(pages=0, fetched=0, assets=0, misses=0, skipped=0, bytes=0)
    q = deque([(seed_url, 0)])
    while q and stats["pages"] < max_pages and (max_bytes is None or stats["bytes"] < max_bytes):
        url, d = q.popleft()
        host = host_of(url)
        cached = _have(staging, host, store_rel(url, True))
        if cached:  # resume: reuse the archived page from disk, still walk its links
            body = Path(cached).read_bytes()
            page = is_html("", body)
            stats["skipped"] += 1
        else:
            ts = cdx_pick(url, target)
            if not ts:
                stats["misses"] += 1
                continue
            got = wayback_raw(url, ts)
            if not got or len(got[2]) > MAX_FETCH:
                stats["misses"] += 1
                continue
            _, ctype, body = got
            page = is_html(ctype, body)
            _write(staging, host, store_rel(url, page), body)
            stats["fetched"] += 1
        hosts.add(host)
        stats["bytes"] += len(body)
        if not page:
            stats["assets"] += not cached
            continue
        stats["pages"] += 1
        if url == seed_url and not title:
            mt = re.search(rb"<title[^>]*>(.*?)</title>", body, re.I | re.S)
            if mt:
                title = re.sub(r"\s+", " ", mt.group(1).decode("latin-1", "replace")).strip()
        for kind, u in extract_urls(body, url):
            if kind == "res":
                mirror_resource(u, target, staging, seen_res, hosts, stats)
            elif bare(host_of(u)) == bare(seed_host) and u not in seen_pages and d < depth:
                seen_pages.add(u)  # same-site link/frame -> follow, bounded depth
                q.append((u, d + 1))
    return title or seed_host, stats, hosts


# --- stage / push -----------------------------------------------------------


def _run_remote(cmd, ssh_host, stdin=None):
    if which("pct"):  # already on labhost
        return subprocess.run(["bash", "-c", cmd], input=stdin, capture_output=True)
    args = ["ssh", ssh_host, cmd] if stdin is not None else ["ssh", "-n", ssh_host, cmd]
    return subprocess.run(args, input=stdin, capture_output=True)


def push_hosts(staging, hosts, ct, ssh_host):
    """Tar the given host dirs and extract them into the CT's corpus via `pct push`."""
    hosts = [h for h in sorted(hosts) if os.path.isdir(os.path.join(staging, h))]
    if not hosts:
        return
    tar = subprocess.run(["tar", "-C", staging, "-cf", "-", *hosts], capture_output=True).stdout
    remote = "/tmp/erapress-corpus.tar"
    r = _run_remote(f"cat > {remote}", ssh_host, stdin=tar)
    if r.returncode:
        raise SystemExit(f"era-press: staging tar to {ssh_host} failed: {r.stderr.decode()[:200]}")
    push = (
        f"pct push {ct} {remote} {remote} && pct exec {ct} -- sh -c "
        f"'mkdir -p {CORPUS} && tar -C {CORPUS} -xf {remote} && rm -f {remote}' && rm -f {remote}"
    )
    r = _run_remote(push, ssh_host)
    if r.returncode:
        raise SystemExit(f"era-press: pct push failed: {r.stderr.decode()[:300]}")


def _read_local_sites(staging):
    p = os.path.join(staging, "sites.json")
    if os.path.exists(p):
        with open(p) as f:
            return json.load(f)
    return []


def upsert_sites(staging, entry, ct, ssh_host, push):
    """Merge one entry into sites.json (CT copy is authoritative when pushing) and write."""
    if push:
        r = _run_remote(f"pct exec {ct} -- cat {CORPUS}/sites.json", ssh_host)
        try:
            sites = json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else []
        except json.JSONDecodeError:
            sites = []
    else:
        sites = _read_local_sites(staging)
    sites = [s for s in sites if s.get("host") != entry["host"]]
    sites.append(entry)
    sites.sort(key=lambda s: s["host"])
    blob = json.dumps(sites, indent=2, ensure_ascii=False).encode("utf-8")
    os.makedirs(staging, exist_ok=True)
    with open(os.path.join(staging, "sites.json"), "wb") as f:
        f.write(blob)
    if push:
        remote = "/tmp/erapress-sites.json"
        _run_remote(f"cat > {remote}", ssh_host, stdin=blob)
        r = _run_remote(f"pct push {ct} {remote} {CORPUS}/sites.json && rm -f {remote}", ssh_host)
        if r.returncode:
            raise SystemExit(f"era-press: sites.json push failed: {r.stderr.decode()[:200]}")

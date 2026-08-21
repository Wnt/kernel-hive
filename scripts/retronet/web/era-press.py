#!/usr/bin/env python3
"""era-press -- mirror real archived 1990s sites into an offline, period-correct corpus.

A date-capped `id_` archival mirror, NOT a rewriter. Runs on CT950/labhost (which has
internet); the gateway CT 951 never fetches.

  1. FETCH RAW. The Wayback CDX API enumerates a URL's captures; each is then pulled
     with the `id_` (identity) modifier -- https://web.archive.org/web/<ts>id_/<url> --
     which returns the ORIGINAL stored bytes: no Wayback toolbar, no URL rewriting.
  2. NO TRANSFORMATION. Original bytes, original Content-Type/charset. Period scripts,
     PNGs and CSS work exactly as they did in 1998 -- or fail exactly as they did.
  3. HARD DATE CEILING: nothing past 2000-12-31. For every capture -- the page and each
     referenced resource -- we pick the capture closest to the target era-date but on or
     before the ceiling. A URL whose only captures are post-2000 (or absent) is SKIPPED;
     it misses -> the museum miss page -> authentic period breakage. We never chase,
     fake or rewrite it.
  4. MIRROR the page + its referenced resources (images, css, js) + same-site links to a
     bounded depth, each under its OWN host at /data/retronet/corpus/<host>/<path> (dir
     -> index.html). The proxy maps by host, so the original absolute URLs resolve.
  5. STAGE locally, then `pct push` a tar into CT 951, and upsert sites.json -- the
     manifest this tool OWNS; the proxy (W1) and search (W3) read it.

Corpus bytes are copyright and NEVER committed -- only this tool and the wave's synthetic
fixtures live in the repo. See docs/lab/retronet/ERA-PRESS.md.

usage:
  era-press.py press <host> [--date YYYYMMDD] [--depth N] [--max-pages N] [--title T]
                            [--category C] [--blurb B] [--staging DIR]
                            [--no-push] [--ct VMID] [--ssh-host H]
  era-press.py seed [--staging DIR] [--no-push] [--only HOST]
  era-press.py crawl [--sites era-sites.json] [--staging DIR] [--budget-gb G] [--max-mb M]
                     [--min-interval S] [--state FILE] [--log FILE]   # big resumable corpus build
  era-press.py list [--staging DIR]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque, namedtuple
from datetime import date
from pathlib import Path
from shutil import which

WB = "https://web.archive.org"
CDX = WB + "/cdx/search/cdx"
UA = "era-press/1.0 (kernel-hive retronet; offline museum corpus)"
CORPUS = "/data/retronet/corpus"  # in CT 951 AND the local staging default
CT_DEFAULT, SSH_DEFAULT = "951", "lab"
CEILING = "20001231"  # hard date ceiling: never mirror a capture past 2000-12-31
MAX_FETCH = 8 * 1024 * 1024  # guardrail: skip (do not truncate) a resource bigger than this
REQ_PAUSE = 0.4  # legacy floor; live pacing now flows through _throttle()/RATE below
SHARED_CORPUS = "/data/vms/retronet-corpus"  # big corpus volume (CT950/labhost path); CT 951 bind-mounts at CORPUS
CRAWL_ROOT = "/data/vms/retronet-crawl"  # crawl state + log live here (OUTSIDE the corpus; survives a worktree GC)
BUDGET_GB = 10.0  # default global size budget: the crawl stops cleanly near this
SITE_MB = 200  # default per-site byte cap so one big site (GeoCities) cannot eat the whole budget
RATE = {"min_interval": 0.8}  # seconds between archive.org requests; `crawl` raises it for a long polite run
BACKOFF_MAX = 120.0  # cap for a single 429/503 backoff sleep

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

Site = namedtuple("Site", "host date depth max_pages title category blurb")

# the starter corpus: iconic, era-defining, well-archived 1996-2000 sites. `category` is
# the Yahoo-style bucket W3's directory groups by; blurbs are the seed defaults for that
# directory. The operator can enrich either in sites.json.
STARTER = [
    Site(
        "spacejam.com",
        "19961227",
        2,
        16,
        "Space Jam (1996)",
        "Entertainment",
        "The web's most famous untouched 1996 home page.",
    ),
    Site(
        "www.yahoo.com",
        "19961017",
        1,
        12,
        "Yahoo! (1996)",
        "Computers and Internet",
        "The early web's hand-built directory of links.",
    ),
    Site(
        "home.netscape.com",
        "19961223",
        1,
        12,
        "Netscape (1996)",
        "Computers and Internet",
        "Home page of the browser that built the web.",
    ),
    Site(
        "www.hamsterdance.com",
        "19990420",
        1,
        6,
        "The Hampster Dance (1999)",
        "Entertainment",
        "Rows of dancing hamster GIFs.",
    ),
]


# --- HTTP / Wayback ---------------------------------------------------------


_last_req = 0.0


def _throttle():
    """Pace archive.org: keep at least RATE['min_interval'] s between requests (polite citizen)."""
    global _last_req
    wait = _last_req + RATE["min_interval"] - time.monotonic()
    if wait > 0:
        time.sleep(wait)
    _last_req = time.monotonic()


def _backoff(attempt, retry_after=None):
    """Sleep for a rate-limited response: honor a numeric Retry-After, else exponential (2,4,8… capped)."""
    secs = float(retry_after) if (retry_after or "").isdigit() else 2.0**attempt
    time.sleep(min(secs, BACKOFF_MAX))


def http_get(url, retries=5):
    """GET url, following redirects; return (final_url, content_type, body) or None. Throttled between
    calls; exponential backoff that HONORS HTTP 429/503 (archive.org's rate-limit signals)."""
    for attempt in range(retries):
        _throttle()
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.geturl(), (r.headers.get("Content-Type") or ""), r.read()
        except urllib.error.HTTPError as e:
            if e.code in (404, 403) or attempt >= retries - 1:
                return None
            _backoff(attempt + 1, e.headers.get("Retry-After") if e.code in (429, 503) else None)
        except (urllib.error.URLError, TimeoutError, ConnectionError):
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


# --- commands ---------------------------------------------------------------


def _do(host, target, depth, max_pages, title, category, blurb, a):
    os.makedirs(a.staging, exist_ok=True)
    ttl, stats, hosts = mirror_site(host, target, depth, max_pages, a.staging)
    print(
        f"  {stats['pages']} pages, {stats['assets']} assets, {stats['misses']} misses, "
        f"{len(hosts)} host(s), {stats['bytes']} bytes  <= {CEILING}"
    )
    entry = dict(host=norm_host(host), title=title or ttl, blurb=blurb, added=date.today().isoformat())
    if category:
        entry["category"] = category  # W3's directory groups by this; absent -> "Web Sites"
    if a.no_push:
        upsert_sites(a.staging, entry, a.ct, a.ssh_host, False)
        print(f"  staged only under {a.staging} (no --push)")
    else:
        push_hosts(a.staging, hosts, a.ct, a.ssh_host)
        upsert_sites(a.staging, entry, a.ct, a.ssh_host, True)
        print(f"  pushed {len(hosts)} host dir(s) to CT {a.ct}:{CORPUS} + sites.json")


def cmd_press(a):
    print(f"era-press: mirroring {a.host} @ {a.date} (depth {a.depth}, <= {a.max_pages} pages, ceiling {CEILING})")
    _do(a.host, a.date, a.depth, a.max_pages, a.title, a.category, a.blurb, a)


def cmd_seed(a):
    for s in STARTER:
        if a.only and norm_host(a.only) != norm_host(s.host):
            continue
        print(f"\n=== {s.host} @ {s.date} ===")
        try:
            _do(s.host, s.date, s.depth, s.max_pages, s.title, s.category, s.blurb, a)
        except (SystemExit, OSError, subprocess.SubprocessError) as e:
            print(f"  SKIP {s.host}: {e}")  # one site's failure must not abort the rest


def cmd_list(a):
    for s in _read_local_sites(a.staging):
        print(f"  {s['host']:24} {s.get('title', ''):26} added {s.get('added', '?')}")


# --- crawl: the resumable, budgeted, rate-limited driver over era-sites.json ------


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
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    with open(path, "a") as f:
        f.write(line + "\n")


def cmd_crawl(a):
    """Drive era-sites.json most-visited-first: rate-limited, resumable (skips done sites + on-disk
    pages), stops cleanly near the global budget, per-site byte-capped, progress logged to a file."""
    RATE["min_interval"] = a.min_interval
    os.umask(0o022)  # world-readable: CT 951's unprivileged proxy must read what CT 950 writes
    os.makedirs(a.staging, exist_ok=True)
    os.makedirs(os.path.dirname(a.state) or ".", exist_ok=True)
    sites = _load_json(a.sites, [])
    if not sites:
        raise SystemExit(f"era-press crawl: no sites in {a.sites}")
    done = set(_load_json(a.state, {}).get("done", []))
    budget = int(a.budget_gb * 1_000_000_000)
    _log(a.log, f"=== crawl start: {len(sites)} sites, budget {a.budget_gb} GB, gap {a.min_interval}s")
    for s in sites:
        host = norm_host(s["host"])
        used = _corpus_bytes(a.staging)
        if used >= budget:
            _log(a.log, f"BUDGET reached: {used / 1e9:.2f} GB -- stopping")
            break
        if host in done:
            _log(a.log, f"SKIP {host} (done)")
            continue
        depth, maxp, dt = int(s.get("depth", 1)), int(s.get("max_pages", 16)), s.get("date", "19970101")
        cap = min(int(s.get("max_mb", a.max_mb)) * 1_000_000, budget - used)  # never exceed the global budget
        _log(a.log, f"START {host} @ {dt} d={depth} maxp={maxp} cap={cap // 1_000_000}MB corpus={used / 1e9:.2f}GB")
        try:
            ttl, st, _hosts = mirror_site(host, dt, depth, maxp, a.staging, max_bytes=cap)
            entry = dict(host=host, title=s.get("title") or ttl, blurb=s.get("blurb", ""))
            entry["added"] = date.today().isoformat()
            if s.get("category"):
                entry["category"] = s["category"]
            upsert_sites(a.staging, entry, a.ct, a.ssh_host, False)  # direct write; CT 951 reads the shared volume live
            done.add(host)
            with open(a.state, "w") as f:
                json.dump({"done": sorted(done)}, f, indent=2)
            mb = st["bytes"] // 1_000_000
            _log(a.log, f"DONE {host}: {st['fetched']}f {st['assets']}a {st['skipped']}c {st['misses']}miss {mb}MB")
        except (OSError, subprocess.SubprocessError, ValueError) as e:
            _log(a.log, f"ERROR {host}: {e}")  # one site must not abort the crawl
    _log(a.log, f"=== crawl complete: corpus {_corpus_bytes(a.staging) / 1e9:.2f} GB")


def main():
    p = argparse.ArgumentParser(prog="era-press", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--staging", default=CORPUS)
        sp.add_argument("--ct", default=CT_DEFAULT)
        sp.add_argument("--ssh-host", default=SSH_DEFAULT)
        sp.add_argument("--no-push", action="store_true")

    pr = sub.add_parser("press", help="mirror one host into the corpus")
    pr.add_argument("host")
    pr.add_argument("--date", default="19970101")
    pr.add_argument("--depth", type=int, default=1)
    pr.add_argument("--max-pages", type=int, default=16)
    pr.add_argument("--title", default="")
    pr.add_argument("--category", default="")
    pr.add_argument("--blurb", default="")
    common(pr)
    pr.set_defaults(fn=cmd_press)

    sd = sub.add_parser("seed", help="mirror the starter landmark set")
    sd.add_argument("--only", default="")
    common(sd)
    sd.set_defaults(fn=cmd_seed)

    ls = sub.add_parser("list", help="show sites.json")
    ls.add_argument("--staging", default=CORPUS)
    ls.set_defaults(fn=cmd_list)

    _here = os.path.dirname(os.path.abspath(__file__))
    cr = sub.add_parser("crawl", help="drive era-sites.json toward the budget: rate-limited + resumable")
    cr.add_argument("--sites", default=os.path.join(_here, "era-sites.json"))
    cr.add_argument("--staging", default=SHARED_CORPUS)  # the big shared volume; CT 951 bind-mounts it live
    cr.add_argument("--budget-gb", type=float, default=BUDGET_GB, dest="budget_gb")
    cr.add_argument("--max-mb", type=int, default=SITE_MB, dest="max_mb")
    cr.add_argument("--min-interval", type=float, default=1.0, dest="min_interval")
    cr.add_argument("--state", default=os.path.join(CRAWL_ROOT, "state.json"))
    cr.add_argument("--log", default=os.path.join(CRAWL_ROOT, "progress.log"))
    cr.add_argument("--ct", default=CT_DEFAULT)
    cr.add_argument("--ssh-host", default=SSH_DEFAULT)
    cr.set_defaults(fn=cmd_crawl)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()

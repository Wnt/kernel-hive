#!/usr/bin/env python3
"""era-press core -- the shared, importable library behind era-press.py + era_crawl.py.

The CORPUS half of era-press: the URL->file path model, read-only URL discovery,
the raw mirror, and the stage->`pct push` transport. No transformation happens
anywhere here -- original bytes, Content-Type and charset are kept as-is.

Talking to archive.org is the other half: `era_fetch` (the connection pool and the
adaptive in-flight limiter) and `era_index` (the per-host capture index). The
dependency runs one way: this module imports those, never the reverse.
See docs/lab/retronet/ERA-PRESS.md.

It is a plain underscore-named module so era_crawl.py, era-press.py and the
offline self-test can all `import era_press_core` (the CLI entry keeps its
`era-press.py` hyphen; only this library needs to be importable).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import urllib.parse
from collections import deque
from pathlib import Path
from shutil import which

import era_fetch as fetch
import era_index
from era_fetch import bare, host_of, norm_host  # the URL helpers the path model is built on

CORPUS = "/data/retronet/corpus"  # in CT 951 AND the local staging default
CT_DEFAULT, SSH_DEFAULT = "951", "lab"
MAX_FETCH = 8 * 1024 * 1024  # guardrail: skip (do not truncate) a resource bigger than this

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


def fetch_page(url, target):
    """Fetch ONE page: exactly ONE archive.org request, at the exact capture stamp the host index gives.

    Returns (page_ts, is_page, raw_body, discovered=[(kind, ts, original_url)]), or None on an authentic
    miss (uncaptured, oversize, or a capture past the 2000-12-31 ceiling). Discovery reads the RAW
    archived HTML -- the original 1990s URLs, relative refs resolved against the page -- and prices each
    one from the index, so a page costs one fetch and its resources cost one fetch each. Callers store
    raw_body, mirror the `res` items, and follow same-site links: the serial mirror and the parallel
    crawl share ONE strategy."""
    got = fetch.wayback_raw(url, era_index.index_ts(url, target))
    if not got:
        return None
    page_ts, ctype, body = got
    if fetch._past_ceiling(page_ts) or len(body) > MAX_FETCH:
        return None  # post-ceiling capture or oversize -> authentic miss
    page = is_html(ctype, body)
    if not page:
        return page_ts, False, body, []  # a non-HTML "page" (a link to a PDF/image): store as an asset
    return page_ts, True, body, discover(body, url, target)


def discover(body, base, target):
    """Everything a page references, priced for fetching: [(kind, ts, original_url)].

    Read-only over the RAW archived HTML -- the original 1990s URLs, relative refs resolved against the
    page -- with each URL's capture stamp taken from its host index (or the era date, which the id_
    redirect resolves). archive.org's own hosts are dropped: none of Wayback's infrastructure is part
    of the site. Split out of fetch_page because a page ALREADY on disk needs exactly this too -- see
    the resource sweep in era_crawl."""
    return [
        (kind, era_index.index_ts(u, target), u)
        for kind, u in extract_urls(body, base)
        if not fetch._is_archive_host(host_of(u))
    ]


# --- URL / path model -------------------------------------------------------


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


def same_site_links(body, base, seed_host):
    """Same-site <a>/<frame> links in a RAW archived HTML body (original URLs, read-only). Used on the
    RESUME path, where only the stored raw id_ bytes exist (no rewritten page) -- so a restart rebuilds
    the exact same frontier the fresh crawl seeded from the raw body. Bare-host match folds www."""
    return [
        u for kind, u in extract_urls(body, base) if kind in ("link", "frame") and bare(host_of(u)) == bare(seed_host)
    ]


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
    """Write one mirrored file. True if it landed, False if this URL cannot be represented on disk.

    A URL namespace is not a filesystem namespace: a site can serve BOTH `/image/44000043/icq` and
    `/image/44000043/icq/banner.gif`, and a static mirror cannot hold both -- the first makes `icq` a
    file, the second needs it to be a directory. ads.icq.com does exactly that. It is an authentic
    limit of mirroring, not a failure, so it is skipped and counted as a miss; raising aborted the rest
    of that page's resources."""
    dest = _dest(staging, host, rel)
    if not dest:
        return False
    try:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(body)
    except OSError:
        return False
    return True


def mirror_resource(url, ts, staging, seen, hosts, stats):
    """Mirror one referenced resource (any host) at its own host/path, raw. `ts` is the resource's EXACT
    capture timestamp, already discovered from the page's REWRITTEN HTML -- so this is a DIRECT id_ hit,
    NOT a CDX search. A ts past the 2000-12-31 ceiling => skip (authentic miss)."""
    host = host_of(url)
    if not host or url in seen:
        return
    seen.add(url)
    if fetch._past_ceiling(ts):
        stats["misses"] += 1  # discovered ts already after the ceiling -> skip the fetch entirely
        return
    rel = store_rel(url, False)
    dest = _have(staging, host, rel)
    if dest:  # resume: already on disk -> no fetch
        hosts.add(host)
        stats["skipped"] += 1
        stats["bytes"] += os.path.getsize(dest)
        return
    got = fetch.wayback_raw(url, ts)  # id_ at the discovered ts -> direct hit, BUT may still resolve nearer
    # Re-check the RESOLVED ts (got[0]): the rewritten page rewrites a resource it didn't capture to the
    # PAGE's ts, so an id_ at that ts can resolve to the resource's real (possibly post-2000) capture.
    if not got or fetch._past_ceiling(got[0]) or len(got[2]) > MAX_FETCH:
        stats["misses"] += 1  # resolved capture past the ceiling (or a miss / oversize) -> skip
        return
    if not _write(staging, host, rel, got[2]):
        stats["misses"] += 1  # URL/filesystem namespace collision -> cannot be mirrored
        return
    hosts.add(host)
    stats["assets"] += 1
    stats["bytes"] += len(got[2])


def mirror_site(seed_host, target, depth, max_pages, staging, max_bytes=None):
    """Crawl+mirror a site into staging the BROWSER way. Return (title, stats, hosts_written). Each page:
    fetch its raw id_ bytes + discover its resources' EXACT timestamps from its rewritten page (ZERO
    CDX), mirror those resources at their exact ts, follow same-site links (from the RAW body, so resume
    rebuilds the same frontier). RESUMABLE (skips pages/assets already on disk, reusing cached pages to
    keep traversing) and byte-capped (max_bytes)."""
    seed_host = norm_host(seed_host)
    seed_url = "http://" + seed_host + "/"
    seen_pages, seen_res, hosts, title = {seed_url}, set(), set(), ""
    stats = dict(pages=0, fetched=0, assets=0, misses=0, skipped=0, bytes=0)
    q = deque([(seed_url, 0)])
    while q and stats["pages"] < max_pages and (max_bytes is None or stats["bytes"] < max_bytes):
        url, d = q.popleft()
        host = host_of(url)
        cached = _have(staging, host, store_rel(url, True))
        if cached:  # resume: reuse the archived page from disk, still walk its links AND its resources
            body = Path(cached).read_bytes()
            page = is_html("", body)
            discovered = discover(body, url, target) if page else []
            stats["skipped"] += 1
        else:
            got = fetch_page(url, target)  # raw id_ bytes + exact page ts + rewritten resource discovery
            if not got:
                stats["misses"] += 1
                continue
            _ts, page, body, discovered = got
            if not _write(staging, host, store_rel(url, page), body):
                stats["misses"] += 1
                continue
            stats["fetched"] += 1
        if page:  # mirror each discovered resource at its EXACT ts -- no per-resource search. Runs for
            for kind, res_ts, orig in discovered:  # a CACHED page too: see the note in era_crawl
                if kind == "res":
                    mirror_resource(orig, res_ts, staging, seen_res, hosts, stats)
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
        if d < depth:  # same-site links from the RAW body (original URLs) -> resume-consistent frontier
            for u in same_site_links(body, url, seed_host):
                if u not in seen_pages:
                    seen_pages.add(u)
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

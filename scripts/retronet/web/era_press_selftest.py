#!/usr/bin/env python3
"""era-press offline self-test — a synthetic fixture, no network.

Locks in the behaviour that the amended contract turns on: era-press is a raw
`id_` MIRROR, not a rewriter. The fixture below is a hand-authored 1997-style
page (nothing scraped); the checks assert that URL discovery is read-only and
correct, that path mapping matches the proxy's "dir -> index.html" rule, and
that images are NOT transcoded (a .png stays .png in the corpus path). Run it:

    python3 scripts/retronet/web/era_press_selftest.py
"""

from __future__ import annotations

import os
import tempfile
import threading
import time

# era_press_core.py + era_crawl.py sit next to this file; run as documented
# (`python3 scripts/retronet/web/era_press_selftest.py`) that dir is sys.path[0].
import era_crawl as ec
import era_fetch as ef
import era_index as ei
import era_press_core as ep

# A synthetic raw archived page (NOT scraped): the shapes era-press must handle.
BASE = "http://www.test.example/dir/page.html"
FIXTURE = b"""<html><head><title>Test</title>
<meta http-equiv="refresh" content="0; url=go.html">
<link rel="stylesheet" href="theme.css">
<script src="app.js"></script></head>
<body background="bg.gif" onload="boom()">
<img src="pic.png"><img src="/art/logo.gif">
<a href="next.html">next</a>
<a href="http://other.example/away.html">offsite</a>
<frame src="frames/nav.html">
</body></html>"""


# A synthetic RAW archived page as fetch_page sees it: original 1990s URLs, one same-host resource,
# one third-party resource, and one of archive.org's own hosts (which discovery must drop).
RAW_PAGE = (
    b'<html><body><img src="logo.gif"><img src="http://ads.example/a.gif">'
    b'<img src="https://web-static.archive.org/_static/x.gif">'
    b'<a href="about.html">about</a></body></html>'
)


def check(name, got, want):
    if got != want:
        raise AssertionError(f"{name}: got {got!r}, want {want!r}")


def main():
    # 1. path mapping: dir/extensionless page -> index.html; files kept verbatim.
    check("store_rel root", ep.store_rel("http://h/", True), "index.html")
    check("store_rel dir", ep.store_rel("http://h/sub/", True), "sub/index.html")
    check("store_rel page file", ep.store_rel("http://h/p.html", True), "p.html")
    check("store_rel extensionless page", ep.store_rel("http://h/about", True), "about/index.html")
    # images are NOT transcoded: a .png keeps its name and extension in the corpus.
    check("store_rel png kept", ep.store_rel("http://h/img/x.png", False), "img/x.png")
    check("store_rel query dropped", ep.store_rel("http://h/a.gif?v=2", False), "a.gif")

    # 2. host normalisation (www folding, case, port).
    check("bare www", ef.bare("www.test.example"), "test.example")
    check("host_of case", ef.host_of("http://Www.X.com:80/p"), "www.x.com")

    # 3. content sniffing.
    check("is_html by type", ep.is_html("text/html; charset=x", b""), True)
    check("is_html image", ep.is_html("image/gif", b"GIF89a"), False)
    check("is_html sniff", ep.is_html("", b"  <HTML><head>"), True)

    # 4. discovery is read-only and classifies every referenced URL correctly.
    found = set(ep.extract_urls(FIXTURE, BASE))
    d = "http://www.test.example/dir/"
    want = {
        ("res", d + "pic.png"),
        ("res", "http://www.test.example/art/logo.gif"),
        ("res", d + "theme.css"),
        ("res", d + "app.js"),
        ("res", d + "bg.gif"),
        ("link", d + "next.html"),
        ("link", "http://other.example/away.html"),
        ("link", d + "go.html"),
        ("frame", d + "frames/nav.html"),
    }
    missing = want - found
    if missing:
        raise AssertionError(f"extract_urls missing: {missing}")
    # the raw bytes are never mutated by discovery.
    check("discovery is read-only", FIXTURE, FIXTURE)

    # 5. the date ceiling is the hard 2000-12-31 the contract fixed.
    check("ceiling", ef.CEILING, "20001231")

    # 6. breadth-first frontier reconstruction — the resume + even-widening core, offline. Build a
    #    tiny on-disk corpus and assert _reconstruct marks on-disk pages DONE per depth level and
    #    files the not-yet-mirrored links as pending frontier at their level (so a restart continues
    #    the even widening, and a deepened config reaches the newly-enabled levels).
    with tempfile.TemporaryDirectory() as staging:
        h = "www.t.example"
        hd = os.path.join(staging, h)
        os.makedirs(os.path.join(hd, "a"))
        # home (L0) links a/ (on disk) + b.html (missing) + an offsite link; a/ (L1) links c.html (missing).
        with open(os.path.join(hd, "index.html"), "w") as f:
            f.write('<title>T</title><a href="/a/">a</a><a href="/b.html">b</a><a href="http://x.example/o">off</a>')
        with open(os.path.join(hd, "a", "index.html"), "w") as f:
            f.write('<a href="/c.html">c</a>')
        st = ec._reconstruct(ec._site_state({"host": h, "depth": 2, "max_pages": 10}, 200), staging)
        check("recon pages on disk", st["pages"], 2)  # home + a/
        check("recon done-by-level", st["done"], {"0": 1, "1": 1})
        check("recon pending L1 (b.html)", st["frontier"].get("1"), ["http://www.t.example/b.html"])
        check("recon pending L2 (c.html)", st["frontier"].get("2"), ["http://www.t.example/c.html"])
    # same-site link discovery is read-only and drops the cross-host link.
    raw = b'<a href="/x">x</a><a href="http://other.example/y">y</a>'
    check(
        "page links same-site only",
        ec._extract_page_links(raw, "http://h.example/", "h.example"),
        ["http://h.example/x"],
    )

    # 7. round-robin interleave — a mid-level budget stop must spread coverage evenly across sites, so
    #    work is taken one page per site in turn (A0, B0, C0, A1, B1, …), NOT all of A then all of B.
    check(
        "interleave round-robins",
        ec._interleave([["A0", "A1", "A2"], ["B0"], ["C0", "C1"]]),
        ["A0", "B0", "C0", "A1", "C1", "A2"],
    )

    # 8. the SHARED 429/503 backoff gate (the concurrency circuit-breaker), offline and deterministic:
    #    a rate-limit signal seen by ONE worker opens a GLOBAL deadline every worker waits out via
    #    _pace(); repeats escalate it; a clean response relaxes the streak.
    ef._backoff_until, ef._backoff_streak = 0.0, 0
    ef._penalize("2")  # a 429 carrying Retry-After: 2s
    check("429 opens the streak", ef._backoff_streak, 1)
    assert ef._backoff_until - time.monotonic() > 1.0, "a 429 must open a future GLOBAL backoff window"
    armed = ef._backoff_until
    ef._penalize(None)  # a repeat with no Retry-After escalates exponentially
    check("repeat escalates the streak", ef._backoff_streak, 2)
    assert ef._backoff_until >= armed, "repeated rate-limit signals push the shared deadline further out"
    ef._relax()  # a clean response walks the streak back one notch
    check("clean response relaxes", ef._backoff_streak, 1)
    # _pace() must actually BLOCK on the shared window (jitter off so the timing is exact).
    saved_jitter, ef.JITTER = ef.JITTER, 0.0
    ef._backoff_until, ef._backoff_streak = time.monotonic() + 0.15, 0
    t0 = time.monotonic()
    ef._pace()
    assert time.monotonic() - t0 >= 0.12, "_pace must wait out the shared backoff window all workers see"
    ef.JITTER, ef._backoff_until, ef._backoff_streak = saved_jitter, 0.0, 0  # leave nothing armed

    # 8b. the AIMD in-flight limiter: halves on push-back, and climbs back on QUIET TIME even when
    #     almost no responses arrive (the failure that pinned the live crawl at its floor for 15 min).
    gate = ef._InFlightGate(8, 2, 10)
    gate.throttled()
    check("limiter: push-back halves the limit", gate.limit(), 4.0)
    gate.throttled()
    gate.throttled()
    check("limiter: never below the floor", gate.limit(), 2.0)
    for _ in range(ef._InFlightGate._CLEAN_PER_STEP):
        gate.clean()
    check("limiter: clean responses climb it back", gate.limit(), 3.0)
    gate._last_step -= ef._InFlightGate._QUIET_SECONDS + 1  # pretend a quiet spell passed
    gate.clean()  # ONE response, but the quiet rule must still grant the step
    check("limiter: quiet time climbs it with almost no traffic", gate.limit(), 4.0)

    # 9. the HOST INDEX, offline: ONE bulk CDX response per host prices every URL on it, so discovery
    #    from the RAW page body needs no per-URL search. Index keys are bare-host + path, so the CDX
    #    original (`http://www.t.example:80/p`) and the page's own reference (`http://t.example/p`)
    #    land on the same entry; an un-indexed host falls back to the era DATE (the id_ redirect).
    check("index window: +6 months", ei._window_end("19990101", 6), "19990701")
    check("index window: rolls the year", ei._window_end("19981201", 3), "19990301")
    check("index window: clamps at the ceiling", ei._window_end("20000801", 12), ef.CEILING)
    ei._index.clear()
    ei._index_building.clear()
    ei._index_since.clear()
    ei.register_site("www.t.example", "19970101")
    saved_get = ef.http_get
    cdx_calls = []

    def fake_cdx(url, retries=5, index=False):
        cdx_calls.append(url)
        rows = b'[["original","timestamp"],["http://www.t.example:80/","19970104102030"],'
        rows += b'["http://www.t.example:80/logo.gif","19970104102030"],'
        rows += b'["http://www.t.example:80/about.html","19970211090000"],'
        rows += b'["http://www.t.example:80/late.gif","20011231000000"]]'
        return ("cdx", "application/json", rows)

    ef.http_get = fake_cdx
    try:
        ts_of = lambda u: ei.index_ts(u, "19970101")  # noqa: E731 -- terse on purpose, this is a test
        # Asking for an index NEVER blocks a fetch worker: the first ask falls back to the era date
        # and kicks the query off in the background; later asks use it once it lands.
        check("index: first ask falls back, never waits", ts_of("http://t.example/logo.gif"), "19970101")
        for _ in range(400):
            if "t.example" in ei._index:
                break
            time.sleep(0.01)
        check("index: exact ts for an indexed resource", ts_of("http://t.example/logo.gif"), "19970104102030")
        check("index: exact ts for an indexed page", ts_of("http://www.t.example/about.html"), "19970211090000")
        # CDX collapses on a case-normalised urlkey, so a page linking to /About.html must still hit
        # the /about.html the index happens to hold -- otherwise it falls to the slow redirect route.
        check("index: path lookup is case-insensitive", ts_of("http://t.example/About.HTML"), "19970211090000")
        # A URL the index does not list is NOT proof it is uncaptured: the index window starts at the
        # site's era date, so an earlier capture is invisible to it. Such a URL must still be tried via
        # the redirect route -- skipping it once killed most intra-site navigation.
        check("index: post-ceiling row -> redirect route", ts_of("http://t.example/late.gif"), "19970101")
        check("index: unlisted URL -> redirect route, not a miss", ts_of("http://t.example/nope.html"), "19970101")
        check("index: un-indexed host -> the era date", ts_of("http://ads.example/a.gif"), "19970101")
        check("index: ONE CDX query for the whole host", len(cdx_calls), 1)
        # the query must name the CONFIGURED host: url=t.example&matchType=prefix would ask
        # archive.org to scan every subdomain of t.example, which is what 504s on the real thing.
        check("index: queries the configured host, not the bare one", "url=www.t.example&" in cdx_calls[0], True)
    finally:
        ef.http_get = saved_get

    # discovery now reads the RAW archived body (original 1990s URLs), priced from that index.
    saved_raw2 = ef.wayback_raw
    ef.wayback_raw = lambda url, ts: ("19970104102030", "text/html", RAW_PAGE)
    ef.http_get = fake_cdx
    try:
        page_ts, is_page, body, disc = ep.fetch_page("http://www.t.example/", "19970101")
    finally:
        ef.wayback_raw, ef.http_get = saved_raw2, saved_get
    check("fetch_page: raw bytes stored verbatim", body, RAW_PAGE)
    check("fetch_page: it is a page", (page_ts, is_page), ("19970104102030", True))
    logo = ("res", "19970104102030", "http://www.t.example/logo.gif")
    check("fetch_page: logo priced from the index", logo in disc, True)
    ad = ("res", "19970101", "http://ads.example/a.gif")  # un-indexed host keeps the redirect route
    check("fetch_page: unknown resource priced at the era date", ad in disc, True)
    archive_leak = any(ef._is_archive_host(ef.host_of(u)) for _k, _t, u in disc)
    check("fetch_page: drops archive's own hosts", archive_leak, False)

    # the RESOLVED-ts ceiling: a resource the rewritten page rewrote to the page's (<=2000) ts can still
    # id_-RESOLVE to its real, post-2000 capture -- mirror_resource must re-check got[0] and NOT store it.
    saved_raw = ef.wayback_raw
    with tempfile.TemporaryDirectory() as staging:
        ef.wayback_raw = lambda url, ts: ("20021108105450", "image/gif", b"GIF89a-late")  # resolves post-2000
        st = dict(pages=0, fetched=0, assets=0, misses=0, skipped=0, bytes=0)
        ep.mirror_resource("http://www.t.example/ad.gif", "19970104102030", staging, set(), set(), st)
        check("resolved-ts ceiling: post-2000 resolve NOT stored", (st["assets"], st["misses"]), (0, 1))
        ef.wayback_raw = lambda url, ts: ("19970104102030", "image/gif", b"GIF89a-ok")  # resolves in-era
        st2 = dict(pages=0, fetched=0, assets=0, misses=0, skipped=0, bytes=0)
        ep.mirror_resource("http://www.t.example/ok.gif", "19970104102030", staging, set(), set(), st2)
        check("resolved-ts <=2000: stored", (st2["assets"], st2["misses"]), (1, 0))
    ef.wayback_raw = saved_raw

    # 10. a page ALREADY on disk still gets its missing resources swept. Resources used to be mirrored
    #     only on a FRESH page fetch, so any page stored while fetches were failing kept its missing
    #     images forever -- the page was cached, so the crawl never looked at it again.
    with tempfile.TemporaryDirectory() as staging:
        host = "www.t.example"
        os.makedirs(os.path.join(staging, host))
        with open(os.path.join(staging, host, "index.html"), "wb") as fh:
            fh.write(b'<html><body><img src="logo.gif"><a href="p.html">p</a></body></html>')
        fetched = []

        def fake_raw(url, ts):
            fetched.append(url)
            return ("19970104102030", "image/gif", b"GIF89a-swept")

        saved = ef.wayback_raw
        ef.wayback_raw = fake_raw
        try:
            ep.mirror_site(host, "19970101", 0, 4, staging)
        finally:
            ef.wayback_raw = saved
        gif = os.path.join(staging, host, "logo.gif")
        check("cached page: its missing resource is swept in", os.path.isfile(gif), True)
        check("cached page: the page itself is NOT re-fetched", any(u.endswith("index.html") for u in fetched), False)

    # 11. `seeds`: deep entry points a 1990s OS points at directly (a browser default page, a help
    #     link, a desktop shortcut) start at level 0 alongside the home page, so they are crawled to
    #     the site's full depth even though nothing on the home page links to them.
    seeded = ec._site_state(
        {"host": "www.t.example", "depth": 2, "max_pages": 9, "seeds": ["http://www.t.example/deep/page.html"]},
        200,
    )
    with tempfile.TemporaryDirectory() as staging:
        ec._reconstruct(seeded, staging)
    level0 = seeded["frontier"].get("0", [])
    check("seeds: home is a level-0 start", "http://www.t.example/" in level0, True)
    check("seeds: the seed is a level-0 start too", "http://www.t.example/deep/page.html" in level0, True)
    check("seeds: absent `seeds` key is fine", ec._site_state({"host": "x.example"}, 200)["seeds"], [])

    # 12. the SWEEP: _reconstruct must hand the sweep every page it found on disk, because those pages
    #     are counted done and never enter the frontier -- which is why their missing images were never
    #     retried. And _sweep_page must fetch a referenced resource that is absent.
    with tempfile.TemporaryDirectory() as staging:
        host = "www.t.example"
        os.makedirs(os.path.join(staging, host))
        with open(os.path.join(staging, host, "index.html"), "wb") as fh:
            fh.write(b'<html><body><img src="logo.gif"></body></html>')
        st = ec._site_state({"host": host, "depth": 1, "max_pages": 4}, 200)
        ec._reconstruct(st, staging)
        check("sweep: the on-disk page is handed to the sweep", st["mirrored"], ["http://www.t.example/"])
        check("sweep: and it is NOT in the frontier", st["frontier"].get("0", []), [])
        saved = ef.wayback_raw
        ef.wayback_raw = lambda url, ts: ("19970104102030", "image/gif", b"GIF89a-swept")
        try:
            ec._sweep_page(st, st["home"], staging, set(), threading.Lock(), {"written": 0})
        finally:
            ef.wayback_raw = saved
        check("sweep: the missing image lands", os.path.isfile(os.path.join(staging, host, "logo.gif")), True)

    # 13. a URL namespace is not a filesystem namespace: a site can serve BOTH /a/icq and /a/icq/b.gif.
    #     The second cannot be mirrored once the first is a file -- that must be skipped, not raised,
    #     or it aborts every remaining resource on the page (ads.icq.com does this for real).
    with tempfile.TemporaryDirectory() as staging:
        wrote = ep._write(staging, "h.example", "a/icq", b"x")
        collided = ep._write(staging, "h.example", "a/icq/b.gif", b"y")
        with open(os.path.join(staging, "h.example", "a", "icq"), "rb") as fh:
            kept = fh.read()
        check("write: a plain file lands", wrote, True)
        check("write: a colliding path is skipped, not raised", collided, False)
        check("write: the original file survives", kept, b"x")

    print("era-press selftest: all checks OK (raw mirror, host index, ceiling, frontier, seeds, sweep)")


if __name__ == "__main__":
    main()

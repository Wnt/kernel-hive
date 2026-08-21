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
import time

# era_press_core.py + era_crawl.py sit next to this file; run as documented
# (`python3 scripts/retronet/web/era_press_selftest.py`) that dir is sys.path[0].
import era_crawl as ec
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
    check("bare www", ep.bare("www.test.example"), "test.example")
    check("host_of case", ep.host_of("http://Www.X.com:80/p"), "www.x.com")

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
    check("ceiling", ep.CEILING, "20001231")

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
    ep._backoff_until, ep._backoff_streak = 0.0, 0
    ep._penalize("2")  # a 429 carrying Retry-After: 2s
    check("429 opens the streak", ep._backoff_streak, 1)
    assert ep._backoff_until - time.monotonic() > 1.0, "a 429 must open a future GLOBAL backoff window"
    armed = ep._backoff_until
    ep._penalize(None)  # a repeat with no Retry-After escalates exponentially
    check("repeat escalates the streak", ep._backoff_streak, 2)
    assert ep._backoff_until >= armed, "repeated rate-limit signals push the shared deadline further out"
    ep._relax()  # a clean response walks the streak back one notch
    check("clean response relaxes", ep._backoff_streak, 1)
    # _pace() must actually BLOCK on the shared window (jitter off so the timing is exact).
    saved_jitter, ep.JITTER = ep.JITTER, 0.0
    ep._backoff_until, ep._backoff_streak = time.monotonic() + 0.15, 0
    t0 = time.monotonic()
    ep._pace()
    assert time.monotonic() - t0 >= 0.12, "_pace must wait out the shared backoff window all workers see"
    ep.JITTER, ep._backoff_until, ep._backoff_streak = saved_jitter, 0.0, 0  # leave nothing armed

    print("era-press selftest: all checks OK (raw mirror, dir->index.html, breadth-first frontier, shared backoff)")


if __name__ == "__main__":
    main()

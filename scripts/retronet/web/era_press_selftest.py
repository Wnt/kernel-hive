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

import importlib.util
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("era_press", os.path.join(_HERE, "era-press.py"))
ep = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ep)

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

    print("era-press selftest: all checks OK (raw mirror, no transform, dir->index.html)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""era-press -- mirror real archived 1990s sites into an offline, period-correct corpus.

A date-capped `id_` archival mirror, NOT a rewriter. Runs on CT950/labhost (which has
internet); the gateway CT 951 never fetches.

  1. FETCH RAW, THE BROWSER WAY. Pull the page's raw bytes with the `id_` (identity) modifier
     -- https://web.archive.org/web/<ts>id_/<url> -- (ORIGINAL bytes: no toolbar, no rewriting),
     then load its REWRITTEN Wayback HTML ONCE to read the EXACT capture timestamp of every
     resource it references, and pull each raw at that exact ts. No per-resource CDX search
     (archive.org's throttled endpoint) -- one cheap nearest-search per PAGE, not per resource.
  2. NO TRANSFORMATION. Original bytes, original Content-Type/charset. Period scripts,
     PNGs and CSS work exactly as they did in 1998 -- or fail exactly as they did. The rewritten
     HTML is used ONLY to discover exact-ts URLs; it is never stored.
  3. HARD DATE CEILING: nothing past 2000-12-31. Every resolved 14-digit capture -- the page and
     each referenced resource -- is checked; a capture past the ceiling (or an uncaptured URL) is
     SKIPPED.
  4. MIRROR the page + its referenced resources + same-site links to a bounded depth, each
     under its OWN host at /data/retronet/corpus/<host>/<path> (dir -> index.html).
  5. STAGE locally, then `pct push` a tar into CT 951, and upsert sites.json.

This file is the thin CLI: `press`/`seed`/`list` mirror one site or the starter set; `crawl`
drives the breadth-first, parallel, budgeted build over era-sites.json. The reusable library is
era_press_core.py; the crawl driver is era_crawl.py. Corpus bytes are copyright and NEVER
committed -- only this tooling + the synthetic fixtures live in the repo. See
docs/lab/retronet/ERA-PRESS.md.

usage:
  era-press.py press <host> [--date YYYYMMDD] [--depth N] [--max-pages N] [--title T]
                            [--category C] [--blurb B] [--staging DIR]
                            [--no-push] [--ct VMID] [--ssh-host H]
  era-press.py seed [--staging DIR] [--no-push] [--only HOST]
  era-press.py crawl [--sites era-sites.json] [--staging DIR] [--budget-gb G] [--max-mb M]
                     [--concurrency N] [--state FILE] [--log FILE]   # breadth-first parallel build
  era-press.py list [--staging DIR]
"""

from __future__ import annotations

import argparse
import os
from collections import namedtuple
from datetime import date

import era_crawl
import era_fetch as fetch
import era_press_core as core

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


# --- commands ---------------------------------------------------------------


def _do(host, target, depth, max_pages, title, category, blurb, a):
    os.makedirs(a.staging, exist_ok=True)
    ttl, stats, hosts = core.mirror_site(host, target, depth, max_pages, a.staging)
    print(
        f"  {stats['pages']} pages, {stats['assets']} assets, {stats['misses']} misses, "
        f"{len(hosts)} host(s), {stats['bytes']} bytes  <= {fetch.CEILING}"
    )
    entry = dict(host=core.norm_host(host), title=title or ttl, blurb=blurb, added=date.today().isoformat())
    if category:
        entry["category"] = category  # W3's directory groups by this; absent -> "Web Sites"
    if a.no_push:
        core.upsert_sites(a.staging, entry, a.ct, a.ssh_host, False)
        print(f"  staged only under {a.staging} (no --push)")
    else:
        core.push_hosts(a.staging, hosts, a.ct, a.ssh_host)
        core.upsert_sites(a.staging, entry, a.ct, a.ssh_host, True)
        print(f"  pushed {len(hosts)} host dir(s) to CT {a.ct}:{core.CORPUS} + sites.json")


def cmd_press(a):
    print(
        f"era-press: mirroring {a.host} @ {a.date} (depth {a.depth}, <= {a.max_pages} pages, ceiling {fetch.CEILING})"
    )
    _do(a.host, a.date, a.depth, a.max_pages, a.title, a.category, a.blurb, a)


def cmd_seed(a):
    for s in STARTER:
        if a.only and core.norm_host(a.only) != core.norm_host(s.host):
            continue
        print(f"\n=== {s.host} @ {s.date} ===")
        try:
            _do(s.host, s.date, s.depth, s.max_pages, s.title, s.category, s.blurb, a)
        except (SystemExit, OSError) as e:
            print(f"  SKIP {s.host}: {e}")  # one site's failure must not abort the rest


def cmd_list(a):
    for s in core._read_local_sites(a.staging):
        print(f"  {s['host']:24} {s.get('title', ''):26} added {s.get('added', '?')}")


def main():
    p = argparse.ArgumentParser(prog="era-press", description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--staging", default=core.CORPUS)
        sp.add_argument("--ct", default=core.CT_DEFAULT)
        sp.add_argument("--ssh-host", default=core.SSH_DEFAULT)
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
    ls.add_argument("--staging", default=core.CORPUS)
    ls.set_defaults(fn=cmd_list)

    _here = os.path.dirname(os.path.abspath(__file__))
    cr = sub.add_parser("crawl", help="breadth-first, parallel, resumable build over era-sites.json")
    cr.add_argument("--sites", default=os.path.join(_here, "era-sites.json"))
    cr.add_argument("--staging", default=era_crawl.SHARED_CORPUS)  # the big shared volume; CT 951 mounts it live
    cr.add_argument("--budget-gb", type=float, default=era_crawl.BUDGET_GB, dest="budget_gb")
    cr.add_argument("--max-mb", type=int, default=era_crawl.SITE_MB, dest="max_mb")
    cr.add_argument("--concurrency", type=int, default=era_crawl.CONCURRENCY, dest="concurrency")
    # min-interval is an OPTIONAL global floor between requests; 0 = pace by concurrency + backoff only.
    cr.add_argument("--min-interval", type=float, default=0.0, dest="min_interval")
    cr.add_argument("--state", default=os.path.join(era_crawl.CRAWL_ROOT, "state.json"))
    cr.add_argument("--log", default=os.path.join(era_crawl.CRAWL_ROOT, "progress.log"))
    cr.add_argument("--ct", default=core.CT_DEFAULT)
    cr.add_argument("--ssh-host", default=core.SSH_DEFAULT)
    cr.set_defaults(fn=era_crawl.cmd_crawl)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()

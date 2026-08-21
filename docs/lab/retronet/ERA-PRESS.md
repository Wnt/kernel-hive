# era-press — the corpus acquisition tool, as built

**Status: LIVE.** Stream **W2** of the [web plane](WEB-PLANE-PLAN.md). era-press
turns real archived 1990s web pages into the local, period-correct corpus the
[proxy](WEB-PROXY.md) serves and the [search engine](WEB-SEARCH.md) indexes. It
runs on **CT950 / labhost** (which has internet); the gateway CT 951 never
fetches anything — it only ever receives files by `pct push`.

```bash
# build the big ~10 GB corpus: most-visited-first, resumable, rate-limited, budgeted
python3 scripts/retronet/web/era-press.py crawl

# mirror the four landmark starter sites into CT 951's corpus
python3 scripts/retronet/web/era-press.py seed

# mirror one more, at a chosen era-date
python3 scripts/retronet/web/era-press.py press www.mcdonalds.com --date 19961223 \
    --title "McDonald's (1996)" --category "Entertainment" --blurb "..."

# what's in the manifest
python3 scripts/retronet/web/era-press.py list
```

## What it is: a date-capped `id_` mirror, not a rewriter

The single design decision, and the one that was got wrong first: **era-press
does not transform anything.** It is an archival *mirror*. It fetches the
original stored bytes and writes them to the corpus unchanged — original HTML,
original `<script>`, original PNGs, original Content-Type and charset. Period
pages work exactly as they did in 1998, or fail exactly as they did.

The one and only lever is **time**. Everything mirrored is a real Wayback
capture on or before a **hard ceiling of 2000-12-31**, chosen closest to a
per-site target era-date. A URL whose only captures are after the ceiling (or
that was never archived) is simply skipped — it becomes a corpus *miss*, which
the proxy answers with the museum's period "not in our internet" page. That is
authentic period breakage and it is intended; era-press never chases, fakes or
rewrites a missing resource.

### Why `id_`

Every fetch goes through the Wayback **identity** modifier:

```
https://web.archive.org/web/<timestamp>id_/<original-url>
```

Without `id_`, Wayback returns the page wrapped in its modern toolbar and with
**every URL in the markup rewritten to point back into web.archive.org** — the
exact noise an earlier downgrade-everything approach was flailing against. With
`id_` you get the raw archived original: no toolbar, no rewriting, the real 1996
links. So there is nothing to undo, and no reason to rewrite: the original
absolute/relative URLs are already what we want.

## The pipeline

1. **Enumerate.** For each URL, the Wayback **CDX API** lists its `200`-status
   captures with `to=20001231`. The capture whose timestamp is closest to the
   target date wins; no rows ⇒ skip (an authentic miss).
2. **Fetch raw.** That exact capture is pulled with `id_`. Bytes and
   Content-Type are kept as-is. Every fetch (CDX and `id_` alike) rides one
   **shared `httpx` HTTP/2 client** — a handful of reused, multiplexed
   connections for the whole crawl (see *The fetch transport* below).
3. **Discover, read-only.** The raw HTML is scanned (never rewritten) for the
   URLs it references — images, scripts, stylesheets, backgrounds, embeds,
   frames, and `<a>`/`<area>` links, plus `<meta refresh>`.
4. **Mirror by host.** Every resource is written under **its own host** at
   `/data/retronet/corpus/<host>/<path>`. Because the markup is untouched and
   the proxy maps requests by host, the original absolute URLs resolve for free.
   Same-site **links** are followed to a bounded `--depth`; cross-host links are
   left alone (they miss unless that host is pressed separately). Referenced
   **resources** are mirrored whatever their host — a captured-≤2000 one lands,
   an uncaptured or post-2000 one misses.
5. **Stage → push.** Files are staged locally in the same
   `<host>/<path>` shape, then a tar of the touched host dirs is streamed over
   `ssh lab` and extracted into CT 951 with `pct push`. No raw host mounts are
   ever used.
6. **Manifest.** `sites.json` is upserted (see below).

### The fetch transport — one shared HTTP/2 client

Every archive.org request — the CDX enumerate and the `id_` pull — goes through
`era_press_core.http_get`, over a **single process-wide `httpx.Client`** built
lazily on first use: `http2=True`, `follow_redirects=True` (the `id_` 302 →
nearest-snapshot redirect is still followed), a real-Chrome User-Agent, a 60 s
read timeout, and a deliberately **small** pool — `max_connections=4`. It is
shared by every one of the crawl's ~10 worker threads; HTTP/2 stream-multiplexing
carries the whole concurrency over that handful of reused connections (measured:
6 concurrent `id_` fetches complete **4.7× faster** than serial, over ~1
established connection).

**Why it is built this way.** The first cut opened a brand-new TCP+TLS connection
per request (stdlib `urlopen`), ~10 workers wide, plus a CDX query before every
`id_` fetch. Thousands of new connections per hour **exhausted the LAN router's
NAT/conntrack table** for this box's flow to the archive edge: ~5 of every 6 new
connections were RST'd before TLS, the crawl throttled itself to ~MB/hr, and it
knocked other hosts off `web.archive.org` — while archive.org itself was never the
limiter (a second box behind the same NAT got HTTP 200 at the same instant).
Reusing a bounded pool of keep-alive HTTP/2 connections is the cure: the
established-connection count now tracks the pool cap (~1–4), **not** the request
count, so the NAT table never fills. `http2=True` matches what Chrome negotiates
to `web.archive.org`. The pool cap is intentionally small — **do not raise it.**

`httpx` is a real dependency (not stdlib), so on the PEP-668 box it lives in a
**venv** beside the deployed code (`install-crawl.sh` builds it; the unit runs
`venv/bin/python`). The import is **lazy** — `era_press_core` imports with no
socket and with no `httpx` installed, so `era_press_selftest.py` still runs
offline under the system python. The pacing gate is unchanged: a `429`/`503` from
any worker opens a **global** backoff every worker waits out (archive.org's own
soft per-IP rate-limit is handled here, separately from the connection pool);
`MAX_FETCH` and the hard `≤2000-12-31` ceiling are unchanged.

### Path mapping (URL → file)

The proxy contract is *"static files mirroring each site; a directory falls
through to `index.html`."* era-press writes to match:

| URL path | corpus file |
|---|---|
| `/` or any `…/` | `…/index.html` |
| `…/page.html`, `…/logo.gif` (has an extension) | stored verbatim |
| `…/about` (a **page**, no extension) | `…/about/index.html` |

Query strings are dropped (a static mirror cannot answer them). Bytes are never
altered, so a page served from a server-script URL keeps that name — see the
content-type note below.

## The manifest — `sites.json` (era-press OWNS it)

`/data/retronet/corpus/sites.json` is an array of one object per **known site**
(not per resource host). era-press is the only writer; the proxy reads it for
its known-host list and the search engine reads it for the directory.

```json
{
  "host": "spacejam.com",
  "title": "Space Jam (1996)",
  "blurb": "The web's most famous untouched 1996 home page.",
  "added": "2026-08-20",
  "category": "Entertainment"
}
```

`category` is optional; W3's directory groups by it and defaults absent entries
to *"Web Sites"*. Upsert is **merge, not replace**: era-press reads the CT's
current `sites.json` (the authoritative copy), replaces only the row for the
host it just pressed, sorts by host, and pushes it back — so it never clobbers
another stream's fixture rows or a hand-edited blurb.

## The starter corpus

Four iconic, era-defining, well-archived sites of 1996–1999 (`seed`). The exact
list is an operator-taste decision and easy to expand.

| Host | Era-date | Depth | Why it's here |
|---|---|---|---|
| `spacejam.com` | 1996-12-27 | 2 | The definitive untouched 1996 promo site — frames, an image map, GIF/JPEG, `<font>`. |
| `www.yahoo.com` | 1996-10-17 | 1 | The web's front door: a hand-built directory in one plain table. |
| `home.netscape.com` | 1996-12-23 | 1 | Home of the browser that built the web. |
| `www.hamsterdance.com` | 1999-04-20 | 1 | Rows of dancing hamster GIFs — HamsterDance-class ephemera. |

## Adding a site

```bash
python3 scripts/retronet/web/era-press.py press <host> \
    --date YYYYMMDD          # target era-date; captures are still capped at 2000-12-31
    --depth N                # how many same-site link hops to follow (default 1)
    --max-pages N            # ceiling on pages mirrored (default 16)
    --title "…" --category "…" --blurb "…"
```

To make it part of the permanent starter set, add a `Site(...)` row to `STARTER`
in `era-press.py` and re-run `seed`. Handy flags: `--no-push` stages locally
without touching the CT (inspect the tree first); `--only <host>` restricts
`seed` to one site; `--staging DIR` relocates the local tree.

## The big corpus — the resumable, breadth-first ~25 GB crawl

The starter set is four sites; the production corpus is **~25 GB**, built by
`era-press crawl` **breadth-first** over a committed 60-site list — widening
every site together, one depth level at a time (all homes first, then all
depth-1 links, then all depth-2, …). Because that cannot live on CT 951's 8 GB
rootfs, the corpus lives in a **dedicated ZFS volume** that is bind-mounted into
the CT.

### Storage — one volume, both containers see it

`scripts/retronet/web/install-corpus-volume.sh` (run on labhost, idempotent)
creates it:

| Thing | Value |
|---|---|
| ZFS dataset | `data/vms/retronet-corpus` — **50 GB quota**, zstd-compressed (headroom over the 25 GB budget), on the `data` pool |
| labhost / CT 950 path | `/data/vms/retronet-corpus` — CT 950 already bind-mounts `/data/vms` *recursively*, so the crawl writes here **directly, with no CT 950 restart** |
| CT 951 path | `/data/retronet/corpus` — a `pct set 951 -mp0` bind-mount of the same volume; the proxy reads it **live** |

Why under `/data/vms` rather than a tidier `/data/retronet-corpus`: CT 950 (this
session's dev container, and the only box with internet) sees a new host path
only if it falls under one of its existing bind-mounts — and remaking those needs
a CT 950 restart, which would kill the session. `/data/vms` is already mounted
recursively, so a dataset created under it appears in CT 950 instantly.

Setup copies the existing corpus into the volume **before** the bind-mount
shadows the old rootfs copy (the proxy must never blink to an empty corpus), then
restarts **CT 951 only** to apply the mount. Thereafter every host dir the crawl
writes on CT 950 appears instantly on CT 951's read side — no `pct push`, no proxy
restart. (`press`/`seed` still `pct push`; the crawl writes direct because its
staging *is* the shared volume, so it runs with push disabled.)

### The site list — `era-sites.json`

A committed array of `{host, date, depth, max_pages, max_mb, title, category,
blurb}`. Because the crawl is **breadth-first across all sites**, every site's
home is mirrored in the first pass regardless of list order — a budget stop
leaves all 60 sites present and evenly deep, not the first few complete and the
rest missing. The **station browser default home pages** lead the list —
`home.microsoft.com` (the IE default on win98se/win2000/nt4), `www.msn.com`, and
`home.netscape.com` (the tru64 Netscape default) — then the top web properties of
1996–2000: AOL, Yahoo, Microsoft, GeoCities, Excite, Lycos, Amazon, eBay,
AltaVista, CNN, the community hosts (Angelfire, Tripod), search engines, news,
tech vendors, and era-defining novelty (Space Jam, the Hampster Dance). 60 sites
at the time of writing, each crawled to `depth` 4–5.

### The crawl — `era-press crawl`

Built to be a **polite archive.org citizen** and to run for hours, unattended:

- **Breadth-first, even widening.** It widens **every site together, one depth
  level at a time**: pass 0 mirrors every site's home, pass 1 every site's
  depth-1 links, pass 2 every site's depth-2 links, … round-robining across all
  sites at each level. So an interrupted or budget-stopped crawl covers **every**
  site to the same depth — never a few deep and the rest empty.
- **Parallel, politely throttled.** Each pass fetches `--concurrency` (default
  **10**) pages at once with a thread pool; every worker shares **one `httpx`
  HTTP/2 client**, so the ~10-wide concurrency is multiplexed over a tiny pool of
  reused connections (a browser on the Wayback Machine fetches ~10 at once the
  same way) — see *The fetch transport*.
  All workers share **one** pacing gate: an HTTP **429/503** seen by any worker
  opens a **global** backoff every worker waits out (`Retry-After` when present,
  else exponential — the whole pool slows/pauses together), plus a little
  per-request jitter. `--min-interval` (default 0) is an optional global floor.
- **Resumable from the corpus.** The on-disk corpus **is** the checkpoint: on
  (re)start each site's per-level frontier is **reconstructed by re-walking its
  on-disk link graph**, so a stop, a crash, a reboot — or a **deepened
  `era-sites.json`** — continues the even widening exactly where it left off and
  reaches new levels. A page/asset already on disk is never re-fetched.
  `state.json` is an observability snapshot only.
- **Budgeted.** A global `--budget-gb` ceiling (default **25**), `du`-reconciled
  as it runs; the crawl stops cleanly when the corpus reaches it.
- **Per-site capped.** Each site has a `max_mb` byte cap (default 200 MB) and a
  `max_pages` cap, so one huge site (GeoCities) cannot swallow the corpus.
- **Directory kept fresh.** As each site's home lands, its `sites.json` row is
  auto-published, so a newly-crawled site appears in the search directory within
  one reindex cycle.
- **Logged.** Timestamped `PASS` / `BUDGET` lines to `progress.log` (and stdout):
  each pass logs how many sites and pages it queued at that depth and the running
  corpus size.

### Running it as a service

`scripts/retronet/web/install-crawl.sh` (run on **CT 950**) deploys a copy of
`era-press.py` **+ its modules (`era_press_core.py`, `era_crawl.py`)** +
`era-sites.json` into `/data/vms/retronet-crawl/` — so a worktree GC never pulls
the code out from under a multi-hour run — builds a dedicated **venv**
(`/data/vms/retronet-crawl/venv`, pinned `httpx[http2]`) beside it (Ubuntu 24.04
is PEP-668 externally-managed, so no system pip), and installs
`retronet-crawl.service` — whose `ExecStart` runs `venv/bin/python` — enabled and
started. The unit runs one long resumable process that stops itself at the
budget; `Restart=on-failure` plus resume covers a crash.

```bash
ssh lab 'pct exec 950 -- systemctl status retronet-crawl'   # is it running
tail -f /data/vms/retronet-crawl/progress.log               # progress
du -sh /data/vms/retronet-corpus                            # bytes so far
```

## Notes for the other streams

- **`.cgi`/`.asp` home pages need a content-type map.** era-press faithfully
  stores a page at its real URL, so Space Jam's frame home lands as `index.cgi`
  (the root `/` meta-refreshes to it). The proxy assigns Content-Type **by
  extension**, and `.cgi` is not HTML by extension → it would be served
  `application/octet-stream` and download instead of render. The fix belongs in
  the proxy's content-type map (map the era's server-script extensions —
  `.cgi .shtml .asp .phtml .pl .cfm` — to `text/html`), not in a rewrite here.
  Flagged to W1.
- **Corpus size.** The production corpus lives in a dedicated **50 GB** ZFS
  volume (zstd-compressed), **not** on CT 951's 8 GB rootfs. Fetches are bounded
  by per-site `depth` / `max_pages` / `max_mb` and the global **25 GB**
  `--budget-gb`, plus a per-resource 8 MB skip guardrail (oversize resources are
  skipped whole, never truncated — truncation would corrupt).
- **Never committed.** Mirrored bytes are copyright and are a box-only bit, the
  same stance as the [private gallery](../PUBLIC-GALLERY.md). Only this tool and
  the wave's tiny **synthetic** fixtures (`scripts/retronet/web/fixtures/`,
  `…/sample-corpus/`) live in the public repo. A fresh box re-presses.

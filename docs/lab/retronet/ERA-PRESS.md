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

era-press uses **both** representations of a page, for two different jobs: the
`id_` bytes are what it **stores** (the raw original), and that same rewritten page
it never stores is read **once** to harvest the **exact capture timestamp of every
resource** — which is what makes the fetch fast. The rewriting is the noise for the
bytes but the signal for the timestamps.

## The pipeline — the browser fetch strategy

era-press fetches a page **the way a browser loads it from the Wayback Machine**,
which is the whole reason it is fast (see *Why one nearest-search per page* below).

1. **Fetch the page raw.** For each page URL, pull its raw bytes with `id_` at the
   target era-date. The `id_` redirect resolves the nearest capture cheaply — a
   single-URL lookup, ~1 s — and its **final URL gives the exact 14-digit capture
   timestamp**. Bytes and Content-Type are kept as-is. A resolved capture past the
   2000-12-31 ceiling, or an uncaptured URL, is skipped (an authentic miss).
2. **Discover exact timestamps.** If the page is HTML, load its **rewritten**
   Wayback page once (`/web/<page-ts>/http://<url>`, *not* `id_`). Wayback rewrites
   every same-page resource URL to carry that resource's **exact** capture
   timestamp — `/web/<ts>im_/…gif`, `/web/<ts>cs_/…css`, `/web/<ts>js_/…js` — and
   leaves links to resolve (relative, or `/web/<ts>/…`) to the page's own ts. So
   **one page fetch yields the exact timestamp of every resource it references**,
   replacing a per-resource CDX nearest-search. The rewritten HTML is used **only**
   to discover those exact-timestamp URLs; it is **never stored**. Wayback's own
   injected chrome (toolbar, `wombat.js`, `bundle-playback.js`, `/_static/…` on
   `web-static.archive.org`, `//archive.org/…` analytics/donation) carries no such
   wrapper and is dropped — so none of it is ever crawled or stored.
3. **Fetch each resource raw, direct.** Every discovered resource is pulled with
   `id_` **at its exact ts** — a direct hit, **no search** — over the shared HTTP/2
   pool, and written under **its own host** at `/data/retronet/corpus/<host>/<path>`
   (any host, so a media/CDN host's images land too). The ceiling is checked **twice**:
   on the discovered ts (skip the fetch outright if already post-2000), and again on
   the **id_-resolved** ts — because Wayback rewrites a resource it *didn't* capture at
   the page's date to the **page's** ts, so an `id_` at that ts can resolve to the
   resource's real, possibly post-2000, capture, which must not be stored. Because the
   stored markup is the untouched original and the proxy maps by host, the original
   absolute URLs resolve for free.
4. **Follow links.** Same-site `<a>`/`<frame>` links — read from the **raw** stored
   body (original 1996 URLs), so a resume rebuilds the identical frontier — are
   followed to a bounded `--depth`; cross-host links are left alone (they miss
   unless that host is crawled separately).
5. **Stage → push.** Files are staged locally in the same
   `<host>/<path>` shape, then a tar of the touched host dirs is streamed over
   `ssh lab` and extracted into CT 951 with `pct push`. No raw host mounts are
   ever used.
6. **Manifest.** `sites.json` is upserted (see below).

### Why one nearest-search per page — the CDX bottleneck, removed

The first cut enumerated captures through archive.org's **CDX API**
(`/cdx/search/cdx`) — **once per resource**. That endpoint is archive.org's
**throttled** one: measured **30–40 s per call**. A single page references dozens of
resources, so mirroring it meant dozens of 30–40 s nearest-searches back to back —
the entire **~1 MB/hr** bottleneck. (The `id_` content fetch was never the problem:
it is ~1 s whether the timestamp is exact or generic, because the redirect resolves
the nearest capture cheaply for one URL.)

A browser loading that same archived page from the Wayback Machine never calls CDX.
The **rewritten** page it fetches already carries the **exact capture timestamp of
every resource**, so the browser pulls each resource directly. era-press now does
the same. The cost per HTML page goes from

| | per page (R resources) | of which throttled CDX |
|---|---|---|
| **old** | `(1+R)` CDX + `(1+R)` id_ | **`1+R` × 30–40 s** |
| **now** | 1 id_ (page) + 1 rewritten + `R` id_ | **0** |

For a 30-resource page that is ~31 CDX nearest-searches (≈ **15–20 min** of throttled
stalls) versus **zero** — replaced by one cheap id_ redirect for the page plus one
rewritten-page fetch. **Measured** (bounded real crawl over three landmark sites,
`--concurrency 3 --min-interval 0.5`): **~4.6 MB/hr vs the old ~1 MB/hr (≈4–5×), with
ZERO CDX calls and zero 429/503 signals** — every request in the fetch log is an
`id_` pull or a rewritten-page discovery; grep it for `cdx` and nothing matches.

That ~4–5× was measured while the shared IP was **transiently throttled** by the
back-to-back test runs themselves (per-request replay latency ~4–8 s, vs a ~2 s cold
baseline). The bottleneck is now **archive.org's per-IP replay throttle, not CDX**:
at low concurrency the crawl is *latency-bound* (≈0.25 req/s at ~8 s/req), and the
throttle *creeps latency upward under sustained load* — a wide burst is far worse
(**~10 concurrent fetches pushed per-request latency from ~2 s to ~17 s here**). So
the crawl stays a **polite slow-drip**: concurrency **moderate** (3), a
`--min-interval 0.5` floor (which only binds when the IP is fast, so it self-adapts —
faster when archive allows, latency-throttled when it doesn't), and the shared
429/503 backoff. On a **rested** IP the same polite config runs faster (the ~2 s
baseline latency implies low-teens MB/hr at conc 3); do **not** widen concurrency to
chase more — a burst tarpits the shared IP and slows every host behind it.

### The fetch transport — one shared HTTP/2 client

Every archive.org request — the `id_` raw pull and the once-per-page rewritten-page
discovery — goes through
`era_press_core.http_get`, over a **single process-wide `httpx.Client`** built
lazily on first use: `http2=True`, `follow_redirects=True` (the `id_` 302 →
nearest-snapshot redirect is still followed), the **full browser header set +
cookie jar** (below), a 60 s read timeout, and a deliberately **small** pool —
`max_connections=4`. It is shared by every one of the crawl's ~10 worker threads;
HTTP/2 stream-multiplexing carries the whole concurrency over that handful of
reused connections (measured: 6 concurrent `id_` fetches complete **4.7× faster**
than serial, over ~1 established connection).

**Why it is built this way.** The first cut opened a brand-new TCP+TLS connection
per request (stdlib `urlopen`), ~10 workers wide, plus a CDX query before every
`id_` fetch (that per-resource CDX call is **gone** now — see *Why one
nearest-search per page* — but the connection pool it motivated stays). Thousands
of new connections per hour **exhausted the LAN router's
NAT/conntrack table** for this box's flow to the archive edge: ~5 of every 6 new
connections were RST'd before TLS, the crawl throttled itself to ~MB/hr, and it
knocked other hosts off `web.archive.org` — while archive.org itself was never the
limiter (a second box behind the same NAT got HTTP 200 at the same instant).
Reusing a bounded pool of keep-alive HTTP/2 connections is the cure: the
established-connection count now tracks the pool cap (~1–4), **not** the request
count, so the NAT table never fills. `http2=True` matches what Chrome negotiates
to `web.archive.org`. The pool cap is intentionally small — **do not raise it.**

**Looking like a browser.** archive.org **soft-throttles** requests that don't
look like a browser (a separate, per-IP signal from the NAT problem — browsing it
in a real Chrome stays fast). So the client sends **byte-for-byte the box's
Chrome headers** — `User-Agent`, the full `Accept`, `Accept-Language`,
`Accept-Encoding`, the `sec-ch-ua*` client hints, the `sec-fetch-*` set,
`Upgrade-Insecure-Requests`, `Referer`, `Priority` — captured from that Chrome
over **CDP** (`Network.requestWillBeSentExtraInfo`) and pinned in
`BROWSER_HEADERS`. It also keeps a **cookie jar**: on first use it primes cookies
with a GET to `web.archive.org`'s homepage (the server-affinity + donation
cookies), and httpx resends them on every request — so even the first `id_`
fetch carries cookies, exactly like a returning browser. To **refresh** the
header set after a Chrome upgrade: launch Chrome with `--remote-debugging-port`,
open a `web.archive.org` tab, attach over CDP and re-read
`Network.requestWillBeSentExtraInfo` (drop the `cache-control`/`pragma` a reload
adds), then update `BROWSER_HEADERS`.

`httpx` is a real dependency (not stdlib), so on the PEP-668 box it lives in a
**venv** beside the deployed code (`install-crawl.sh` builds it, pinned:
`httpx[http2]`, plus `brotli`+`zstandard` so httpx can decode the `br`/`zstd`
encodings the browser `Accept-Encoding` advertises — whatever archive.org sends
is stored as the raw decoded original; the `id_` endpoint returns identity
anyway; the unit runs `venv/bin/python`). The import is **lazy** —
`era_press_core` imports with no socket and with no `httpx` installed, so
`era_press_selftest.py` still runs
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
- **Parallel, but deliberately MODERATE.** Each pass fetches `--concurrency`
  pages at once with a thread pool sharing **one `httpx` HTTP/2 client** (a tiny
  pool of reused connections — see *The fetch transport*). The code default is 10,
  but **the service runs `--concurrency 3 --min-interval 0.5`** on purpose: this
  box's replay latency to archive is multi-second and a **wide burst tarpits the
  shared per-IP** (measured: ~10 concurrent pushed per-request latency ~2 s → ~17 s),
  which slows every host behind that IP. Three-wide, latency-throttled, is the polite
  sweet spot; **do not widen it to chase throughput.** All workers share **one**
  pacing gate: an HTTP **429/503** seen by any worker opens a **global** backoff
  every worker waits out (`Retry-After` when present, else exponential — the whole
  pool slows/pauses together), plus per-request jitter. `--min-interval` is a global
  floor that only binds when the IP is fast (so it self-adapts).
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

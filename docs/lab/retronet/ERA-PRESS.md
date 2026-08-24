# era-press — the corpus acquisition tool, as built

**Status: LIVE.** Stream **W2** of the [web plane](WEB-PLANE-PLAN.md). era-press
turns real archived 1990s web pages into the local, period-correct corpus the
[proxy](WEB-PROXY.md) serves and the [search engine](WEB-SEARCH.md) indexes. It
runs on **CT950 / labhost** (which has internet); the gateway CT 951 never
fetches anything — it only ever receives files by `pct push`.

```bash
# build the big ~5 GB corpus: breadth-first over ~200 sites, resumable, rate-limited, budgeted
python3 scripts/retronet/web/era-press.py crawl

# mirror the four landmark starter sites into CT 951's corpus
python3 scripts/retronet/web/era-press.py seed

# mirror one more, at a chosen era-date
python3 scripts/retronet/web/era-press.py press www.mcdonalds.com --date 19961223 \
    --title "McDonald's (1996)" --category "Entertainment" --blurb "..."

# build every site's capture index first (the crawl's bootstrap; idempotent)
python3 scripts/retronet/web/era-press.py index

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

1. **Price the URL.** Which capture to fetch comes from the site's **host index** — a
   dict lookup, no network (see *One CDX query per host* below). A URL on a host with
   no index (a third-party image server) is priced at the site's era-**date** instead,
   and Wayback's `id_` redirect resolves the nearest capture itself. A **landing page**
   (the home, and section-index pages near it) is priced differently — the *most complete*
   capture within the ceiling, not the nearest-date one, because the nearest-date front
   page is so often a broken one. See *The landing-page exception* below.
2. **Fetch it raw.** Pull the bytes with `id_` at that exact stamp — a direct hit, no
   search. Bytes and Content-Type are kept as-is. The final URL gives the **resolved**
   14-digit capture stamp; a resolved capture past the 2000-12-31 ceiling, or an
   uncaptured URL, is skipped (an authentic miss). The ceiling is therefore checked
   **twice** — on the priced stamp and again on the resolved one — because a URL priced
   at a date can resolve to a post-2000 capture, which must not be stored.
3. **Discover, read-only.** If the page is HTML, its **raw archived body** is scanned
   (never rewritten) for the URLs it references — images, scripts, stylesheets,
   backgrounds, embeds, frames, and `<a>`/`<area>` links, plus `<meta refresh>`. These
   are the real 1990s URLs; each is priced from the index exactly as in step 1.
   archive.org's own hosts are dropped, so none of Wayback's infrastructure is crawled.
4. **Mirror by host.** Every resource is written under **its own host** at
   `/data/retronet/corpus/<host>/<path>` (any host, so a media/CDN host's images land
   too). Because the markup is untouched and the proxy maps requests by host, the
   original absolute URLs resolve for free. Same-site links are followed to a bounded
   `--depth` — read from the **raw** stored body, so a resume rebuilds the identical
   frontier; cross-host links are left alone (they miss unless that host is crawled
   separately).
5. **Stage → push.** Files are staged locally in the same `<host>/<path>` shape, then a
   tar of the touched host dirs is streamed over `ssh lab` and extracted into CT 951
   with `pct push`. No raw host mounts are ever used.
6. **Manifest.** `sites.json` is upserted (see below).

### One CDX query per host — why the crawl was slow, three times over

Picking a capture for a URL is half the work, and **every cheap-looking way to do it
per-URL is a slow archive.org endpoint.** Measured on this box on 2026-08-21, on cold
URLs, 8 fetches in flight, HTTP/1.1:

| Route | Median latency | Throughput | Health |
|---|---|---|---|
| `id_` at an **exact 14-digit stamp** | **5.0 s** | **138 MB/hr** | no errors |
| `id_` at an 8-digit **date** (the 302 resolves it) | 9.5 s | 58 MB/hr | tarpit + 503s |
| the **rewritten** page, fetched for discovery | 15.7 s | 36 MB/hr | heavy tarpit |
| **CDX, one query per URL** | 4–40 s | — | the original bottleneck |

Both earlier designs picked a route from the bottom three. The first cut called CDX
**once per resource**; replacing that with the browser's trick — fetch the page's
**rewritten** HTML, which carries every resource's exact capture stamp — removed
thousands of CDX calls but bought archive.org's *other* expensive endpoint, one per
page. Neither is affordable.

The way out is that **the same CDX query, asked once for a whole host, answers it for
every URL on that host.** With `matchType=prefix` one request returns the host's entire
capture index — measured: **27–40k URLs with exact stamps, ~3 MB, 70–130 s**. Amortised
over the thousands of objects the crawl pulls from that host, pricing a URL costs a
**dict lookup and no network at all**, and every fetch is then the top row of that
table. One query per host is also ~200 CDX calls for the whole ~200-site corpus, against
the tens of thousands the per-URL routes needed — the endpoint's throttle stops
mattering. Indexes are cached on disk (`<state-dir>/cdx/<host>-<date>.json`), so the
cost is paid once, not once per restart.

Only hosts we actually crawl earn an index; a third-party host serving one image is not
worth a 70 s query and takes the redirect route instead. Several of the biggest sites (amazon,
ebay, apple, imdb, wired, …) are **un-indexable**: archive.org 504s on their prefix scan at
every window width, at every row limit, and with `collapse` removed — the scan is priced by
how many captures the host has. They take the redirect route too, which is correct, just
slower, and `era-press index` records that so it is not rediscovered every run.

**Lookups are case-folded.** `collapse=urlkey` collapses on Wayback's case-normalised urlkey,
so which casing survives into the `original` field is arbitrary — ibm.com's index holds
`/ibm/` and `/legal/` while its own home page links to `/IBM/` and `/Legal/`. 3593 of that
host's 18852 keys carry uppercase, and case-sensitive lookup missed every one, pushing each
onto the slow redirect route. Keys are lowercased on both sides; the handful of collisions
(45 there) cost only a possibly-suboptimal timestamp, since the fetch uses the URL as written.

**An index cannot answer "no", and assuming it could was a real regression.** The window
starts at the site's **era date**, so absence means only *"no capture on or after the era
date"* — not *"not archived"*. `http://www.ibm.com/Global/` is archived, with 200s through
1996–97, but ibm.com's era date is 1998-02-01, so it is absent from that host's index.
Treating that as a miss saved 27% of requests and killed most intra-site navigation with it:
home pages served, and nearly every link off them 404'd. So an unindexed URL still takes the
redirect route. It costs a request; it is the only thing that can actually answer the
question.

**Bootstrap the indexes before a cold crawl:**

```bash
python3 scripts/retronet/web/era-press.py index      # one serial pass, idempotent, ~1 min/host
```

The crawl builds indexes in the background as it goes, which is right once it is warm but
hopeless from cold: 60 heavy queries competing with the fetches leaves the crawl in the slow
redirect regime, which is exactly the regime that provokes the throttling that stops the
indexes landing. One serial pass — one heavy query at a time, the shape archive.org tolerates
best — breaks that loop, and afterwards the whole crawl runs on the fast exact-stamp path.

**An index is an optimisation, never a precondition**, so asking for one never blocks: the
disk cache is read inline, and a missing index is *started in a tiny background pool* while
the URL is fetched at the era date right now. That matters — when index queries ran on the
fetch workers themselves, 52 hosts × a 70–130 s query held the in-flight permits and the
crawl spent its first quarter-hour building indexes at two connections instead of mirroring
anything. Now the crawl runs at full speed throughout and simply gets faster as each index
lands.

### The landing-page exception — most complete, not nearest

The default pick for any URL is the capture *nearest the era date* (the first in the index
window). For most pages that is right, but for a **landing page** it is often wrong in a
visible way: `www.sgi.com`'s capture nearest its 1997 era date is missing seven of its eleven
images, and `support.sgi.com`'s nearest-1998 front page has **none** of its four — they render
as broken boxes, which is the first thing a visitor to that station sees.

So the home page, and section-index pages within one level of it (directory URLs, `.../news/`),
are selected by **completeness** instead. `era_index.page_captures` runs one per-URL CDX query
(affordable — landing pages are few, unlike the tens of thousands of leaves and resources) to
list that page's own distinct-content captures across `[era date, ceiling]`, spread-sampled and
capped. Each candidate's HTML is fetched and scored by `landing_completeness`: the fraction of
the image/script/style resources IT references that have a status-200 capture in the host index
— **pure index lookups, no downloads for the scoring**. The highest score wins; the era date
only breaks near-ties. On SGI that moves the home from **4/11 → 51/54** images present, and
support from **0/4 → 15/15**, by choosing 2000 captures over the era-date ones.

This is the **capture-date policy** in one place: a landing page may hold *any* capture on or
before 2000-12-31, preferring the most complete, and using the era date only as a mild
tie-break — so a 1997 site legitimately ends up showing a far more complete 2000 front page.
Leaves are unchanged (nearest-date). The chosen home stamp is remembered (`home_ts`, persisted
in `state.json`) as the site's **original capture date** for the directory.

### What it adds up to — measured end to end

The tables below are per-route benchmarks. The number that matters is the whole crawl, same
box, same 60-site list, before and after (2026-08-21):

| | pages/min | corpus growth | requests that succeeded | thread-time asleep |
|---|---|---|---|---|
| **before** | ~2 | ~6 MB/hr | **11%** | **45%** |
| **after** | **~92** | **~46 MB/hr** | ~73% | <1% |

(The "after" row was measured with a since-reverted optimisation that skipped unindexed URLs;
restoring correctness costs some of that request rate back — see *An index cannot answer
"no"* below.)

The in-flight limiter sits at its ceiling of 8 with no push-back, which is the sign that the
crawl is now bounded by archive.org rather than by itself. Corpus growth rises by less than
page rate does because the pages are 1990s pages — a few KB each; the crawl is
request-bound, which is why every change above is about spending fewer requests per stored
byte.

### The fetch transport — HTTP/1.1, and an adaptive limiter

Every archive.org request goes through `era_fetch.http_get`, over a **single
process-wide `httpx.Client`** built lazily on first use: `follow_redirects=True` (the
`id_` 302 → nearest-snapshot redirect must still be followed), the **full browser
header set + cookie jar** (below), a 60 s read timeout, and a bounded pool of
persistent keep-alive connections.

**HTTP/1.1, not HTTP/2 — and that is measured.** Chrome negotiates h2 to
`web.archive.org`, so the first cut did too. But a browser opens a handful of streams
on that connection and a crawl opens a flood, and archive.org's h2 edge answers a flood
by queueing it and then shedding it. Same box, same cold URLs, 90 s each:

| Transport | Throughput | Latency | Health |
|---|---|---|---|
| h2, 4 connections, 6 in flight | 0.44 req/s, 58 MB/hr | median 6.0 s, **p90 60 s** | ~50% `RemoteProtocolError` |
| h1, 6 connections, 6 in flight | 1.71 req/s, 204 MB/hr | median 2.8 s, p90 6.0 s | **0 errors** |
| **h1, 10 connections, 10 in flight** | **2.27 req/s, 256 MB/hr** | median 2.4 s, p90 6.0 s | **the knee** |
| h1, 16 connections, 16 in flight | 2.13 req/s, 226 MB/hr | median 2.8 s | **55% of connections refused** |

Under h2, half of all requests came back `RemoteProtocolError` (the edge resetting
multiplexed streams); under h1 that failure mode disappears entirely. So: one request
per connection, and **the thing archive.org actually limits is the number of concurrent
connections from one IP** — which is exactly what the limiter below controls.

**The adaptive in-flight limiter (AIMD).** archive.org's tolerance is not a constant:
it moves hour to hour, and the knee is narrow. A hand-set rate is therefore always
wrong soon after it is set — either it leaves most of the ceiling unused, or it trips
the tarpit and the crawl spends its life asleep. (Three commits in one morning
re-tuning `--min-interval` are the evidence.) So `_InFlightGate` **finds** the knee:
**+1 permit per 25 clean responses, halve on any push-back**, bounded [1, 10]. Worker
threads park on it, so `--concurrency` is only the pool's upper bound. The current
limit is printed in every progress line (`in-flight limit 6.0`).

**What a failure MEANS decides what it costs**, and getting that wrong is what made the
crawl slow. Measured on the deployed crawl (3 workers, 360 s): **115 requests, 13 of
them successful, and 482 of ~1080 thread-seconds spent asleep** — because every failure,
whatever it was, drew the same per-thread exponential 2,4,8,16 s sleep and then gave the
URL up as a permanent miss. They are three different things:

- a **keep-alive reuse race** (`RemoteProtocolError` — the edge closed a pooled
  connection between our checkout and our write) says nothing about our rate. A browser
  silently opens a new connection and retries at once; so do we, off the retry budget.
- a **refused connection** is the edge's per-IP **burst tarpit**: it RSTs every *new*
  connection for a while, then clears on its own (measured: ~20 s). That is **one outage
  shared by every worker**, so it gets **one** shared pause plus a halving of the
  in-flight limit — not N independent exponential ramps.
- a **429/502/503** is archive.org asking for less: shared backoff, and halve the limit.

**Why a bounded pool at all.** The first cut opened a brand-new TCP+TLS connection per
request (stdlib `urlopen`), ~10 workers wide. Thousands of new connections per hour
**exhausted the LAN router's NAT/conntrack table** for this box's flow to the archive
edge: ~5 of every 6 new connections were RST'd before TLS, and it knocked other hosts
off `web.archive.org` — while archive.org itself was not the limiter at the time (a
second box behind the same NAT got HTTP 200 at the same instant). A bounded pool of
reused keep-alive connections is the cure: the established-connection count tracks the
pool cap, **not** the request count. The cap is the limiter's ceiling — **do not raise
it past the measured knee**, where the edge starts refusing connections outright.

**Looking like a browser.** archive.org **soft-throttles** requests that don't look like
a browser. So the client sends **byte-for-byte the box's Chrome headers** —
`User-Agent`, the full `Accept`, `Accept-Language`, `Accept-Encoding`, the `sec-ch-ua*`
client hints, the `sec-fetch-*` set, `Upgrade-Insecure-Requests`, `Referer`, `Priority`
— captured from that Chrome over **CDP**
(`Network.requestWillBeSentExtraInfo`) and pinned in `BROWSER_HEADERS`. It also keeps a
**cookie jar**: on first use it primes cookies with a GET to `web.archive.org`'s
homepage (the server-affinity + donation cookies), and httpx resends them on every
request. To **refresh** the header set after a Chrome upgrade: launch Chrome with
`--remote-debugging-port`, open a `web.archive.org` tab, attach over CDP and re-read
`Network.requestWillBeSentExtraInfo` (drop the `cache-control`/`pragma` a reload adds),
then update `BROWSER_HEADERS`.

`httpx` is a real dependency (not stdlib), so on the PEP-668 box it lives in a **venv**
beside the deployed code (`install-crawl.sh` builds it, plus `brotli`+`zstandard` so
httpx can decode the `br`/`zstd` encodings the browser `Accept-Encoding` advertises —
whatever archive.org sends is stored as the raw decoded original; the `id_` endpoint
returns identity anyway; the unit runs `venv/bin/python`). The import is **lazy** —
`era_fetch` imports with no socket and with no `httpx` installed, so
`era_press_selftest.py` still runs offline under the system python. `MAX_FETCH` and the
hard `≤2000-12-31` ceiling are unchanged.

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
(not per resource host). era-press is the only writer (`era_state.publish_sites`);
the proxy reads it for its known-host list and the search engine reads it for the
directory.

```json
{
  "host": "www.sgi.com",
  "title": "Silicon Graphics",
  "blurb": "SGI's own web -- the vendor estate behind the irix and indyr4400 stations.",
  "captured": "20000511091920",
  "pages": 214,
  "depth": 4,
  "bytes": 17039360,
  "category": "Computers and Internet"
}
```

`category` is optional; W3's directory groups by it and defaults absent entries
to *"Web Sites"*. The other four describe **what we actually hold**, and the
directory renders them (see [WEB-SEARCH](WEB-SEARCH.md)):

- **`captured`** — the **original capture date**: the Wayback stamp of the home
  capture the crawl actually chose (the completeness pick above), 14- or 8-digit,
  rendered month-year (*"May 2000"*). This **replaces the old `added`** field,
  which was merely *our* download date and told a visitor nothing.
- **`pages`** / **`depth`** / **`bytes`** — the HTML page count, the deepest link
  level reached, and the total size held, straight from the crawl's `state.json`.

Upsert is **merge, not replace**: era-press reads the CT's current `sites.json`
(the authoritative copy), rewrites only the rows for sites it crawled, sorts by
host, and pushes it back — so it never clobbers another stream's fixture rows
(the synthetic `example.museum`, which keeps its legacy `added`) or a hand-edited
blurb. The directory falls back to `added` for any such legacy row.

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

## The big corpus — the resumable, breadth-first ~5 GB crawl

The starter set is four sites; the production corpus targets **~5 GB**, built by
`era-press crawl` **breadth-first** over a committed ~200-site list — widening
every site together, one depth level at a time (all homes first, then all
depth-1 links, then all depth-2, …), and stopping cleanly at the `--budget-gb`
ceiling. Because that cannot live on CT 951's 8 GB rootfs, the corpus lives in a
**dedicated ZFS volume** that is bind-mounted into the CT.

### Storage — one volume, both containers see it

`scripts/retronet/web/install-corpus-volume.sh` (run on labhost, idempotent)
creates it:

| Thing | Value |
|---|---|
| ZFS dataset | `data/vms/retronet-corpus` — **50 GB quota**, zstd-compressed (generous headroom over the ~5 GB budget), on the `data` pool |
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

### Station requests — the retronet fills its own gaps

The disk scan behind `era-sites.json` can only find URLs that sit in a guest image as readable text,
and it can never know which of them anyone actually walks to. **A miss knows**: a station asked, and
the museum had nothing. So the loop closes:

1. the proxy journals **every miss** to `/var/spool/retronet/_requests.jsonl` (`proxy.record_miss` —
   one `open`/`write`/`close` per miss). The spool is a **small shared volume, not the corpus**: the
   proxy unit sets `ReadOnlyPaths` on the corpus it serves and that stays true. Errors are still
   swallowed — a hint channel must never break serving — but the **first** failure logs one `WARN`
   line, because this channel was dead for three days and nothing said so (see below);
2. **`retronet-requests.service`** (CT 950) folds that journal in **every 5 minutes**
   (`--requests-interval`), sharing the same AIMD-paced fetch layer as the crawl — so a page a station
   wanted five minutes ago does not wait for a multi-hour crawl pass to end;
3. a URL that clears the rule is crawled — page, or asset, plus every resource it references.
   **More requests, higher priority**: the queue is ordered by total count.

**One rule decides eligibility, and it reads the same at every point in a URL's life:**

> **Two asks, fifteen minutes apart, since the last decision.**

Two asks, not one, because a single request is a typo in the address bar, a probe, or a broken image on
a page nobody will revisit. Fifteen minutes apart, because a burst is one visit and a real gap is
someone coming *back*. And *since the last decision* is what the per-URL **`gate`** records: every
outcome moves it, and only asks after it count.

| Outcome | What it means | `gate` moves to |
|---|---|---|
| `mirrored` / `already-had-it` | we have it now | `now` — two fresh asks to come back |
| **`not-archived` / `bad-url`** | **archive.org has no in-ceiling capture** | **`now + 30 days`** |
| `cannot-store` | *our* disk failed, not the archive | `now` |

The 30-day cooldown is the part worth being precise about. "The Wayback Machine has no pre-2001 capture
of this" does not change week to week, and every retry is a request made of someone else's
infrastructure for a thing we already know is not there. So asks that arrive **during** the window are
*pruned, not banked*: they raise `count` (they are real demand, and they will order the queue later) but
they cannot shorten the window they arrived in. And when the 30 days elapse **nothing fires by itself** —
the URL must earn the retry from scratch, with two fresh asks fifteen minutes apart on the far side of
the gate. `cannot-store` is pointedly excluded: burying our own full disk for a month would turn a
storage fault into thirty days of silence.

Two kinds of traffic never reach the queue at all. Requests a *client* makes on a timer —
`favicon.ico`, `wpad.dat`, `robots.txt`, IE's `.CAB` Authenticode refresh — clear the two-and-spread
bar on their own without a person ever being involved, so `record_miss` drops them at the door.

A request for a host we already crawl is fetched with **that site's** era date and ceiling, so it
lands exactly as the site's own pages do. A request for an unknown host gets the **default** ceiling:
a station asking for a post-2000 page does not by itself justify letting the corpus past the era rule.
If a host should be allowed past it, that is a deliberate decision and its name goes in the VIP list.

The journal is **rotated before reading**, so the proxy keeps appending to a fresh file while a batch
is processed; state lives in `<crawl-root>/requests.json` and is saved **per URL**, not per batch — a
cooldown that lives only in memory is no cooldown. Watch it in `requests.log`:

```
--- REQUESTS (station request): 3 URL(s) due, 47 new miss(es) journalled
    request mirrored: http://www.sgi.com/products/index.html
    request not-archived (quiet for 30d): http://intranet.local/foo
```

#### Why this is two units and not one thread

The watcher used to be a thread inside `cmd_crawl`, which made its lifetime the crawl's lifetime. A
corpus crawl is a **finite job** — it stops at the budget or when the site list is exhausted, exits 0,
and stays stopped (`Restart=on-failure` does not restart a success). Demand-servicing is the opposite:
it must be listening whenever a station is browsing. So the crawl runs with `--no-requests` and the
watcher runs under its own `Restart=always` unit. `era-press.py requests` is deliberately cheap to
start — it needs only each site's era date and ceiling, so it skips `_reconstruct`, the per-site disk
walk that rebuilds a crawl frontier this loop never uses.

#### The three-day silence, and what now prevents it

Between 2026-08-21 and 2026-08-24 this entire mechanism was dead, and every symptom looked like "nobody
asked for anything". Three independent faults, each individually silent:

- the proxy unit's `ReadOnlyPaths=/data/retronet/corpus` made the journal path **read-only to the only
  process that writes it**, and the corpus bind-mount is owned by a host uid outside CT 951's idmap, so
  no in-CT user could have owned it anyway. `record_miss` swallowed the `OSError` on every miss;
- the crawl — and with it the watcher thread — had exited cleanly and stayed stopped;
- the selftest exercised the whole queue in a `tmp` directory, where writes obviously succeed, so CI was
  green the entire time.

The repairs are structural, not vigilance: the spool is a **separate writable volume**
(`install-requests-volume.sh`, which fails loudly unless `rnproxy` can actually write it), the watcher
has its **own always-on unit**, `record_miss` **WARNs once** on its first failure, and
`install-proxy.sh verify` now asserts that a probe miss was **recorded**, not merely that the 404 page
rendered. That last check is the one that would have caught all of this on day one.

### The VIP list — `era-vips.json`

A handful of sites belong in this museum whatever the era rule says, because they matter to *this*
collection and simply did not exist before 2001. They live in their own small file,
`scripts/retronet/web/era-vips.json`, merged over `era-sites.json` at load time:

```json
{
  "host": "irc-galleria.net",
  "date": "20031225",
  "ceiling": "20091231",
  "title": "IRC-Galleria",
  "category": "Community",
  "blurb": "Finland's IRC photo gallery — the social network before social networks.",
  "seeds": ["http://irc-galleria.net/some/deep/page"]
}
```

**Adding one is: edit that file, run one command.**

```bash
scripts/retronet/web/install-crawl.sh      # deploys the lists + code and restarts the daemon
```

The crawl is resumable from the on-disk corpus, so the restart re-plans against the new list and
re-fetches nothing. (For a brand-new host, `era-press index` builds its capture index; the crawl also
builds it in the background on first use.)

Defaults an entry gets unless it says otherwise: `ceiling` = **2009-12-31** (`VIP_DEFAULT_CEILING`),
`depth` 5, `first_depth` 3, and 900-page/900 MB caps. A VIP whose host is already in `era-sites.json`
**replaces** that entry, so a site is promoted by adding it to the VIP list and nothing else.

**Priority.** VIPs are crawled to `first_depth` (3) in dedicated `VIP PASS` rounds *first* — ahead of
the resource sweep as well as the ordinary passes, because the sweep re-checks thousands of pages
already on disk and can run for an hour, and a VIP added five minutes ago should not wait behind it; whatever they discovered below that stays in the frontier and is picked up by
the normal level loop out to depth 5. Deep early where it counts, the long tail lazily.

**The ceiling is per-site and explicit, never global drift.** `_past_ceiling` still defaults to
2000-12-31 for every other site, the index window for a VIP host is widened to *its* ceiling, and both
the priced stamp and the id_-resolved stamp are checked against it.

### Depth, `max_pages`, and which one actually binds

`depth` counts **link hops from the site's home page**: level 0 is the home page, level 1 the pages it
links to, level 2 the pages those link to. `seeds` add extra level-0 entry points for the deep paths a
1990s OS opens directly — a browser default page, a help-viewer target, a desktop shortcut — which
ordinary link-following may never reach.

But `depth` is rarely the limit. **`max_pages` is**, and it was set far too tight against its own byte
cap: the corpus held 110 MB against the 16 GB the per-site byte caps allowed (0.7%), and
`www.sun.com` stopped at 69 pages of 70 having reached only **depth 2 of 4** — so a press release
linked off the home page was mirrored while the page *it* linked to never was. Pages average 39 KB, so
a page cap in the tens is a byte cap in the low megabytes whatever `max_mb` says. The caps are now
900 pages for the sites a station points at and 400 for the rest, which leaves `max_mb` as the real
guard — which is what it was always meant to be.

### The site list — `era-sites.json`

A committed array of `{host, date, depth, max_pages, max_mb, title, category,
blurb}` — adding a row is all it takes to widen the corpus. Because the crawl is
**breadth-first across all sites**, every site's home is mirrored in the first
pass regardless of list order — a budget stop leaves all ~200 sites present and
evenly deep, not the first few complete and the rest missing. The **station
browser default home pages** lead the intent — `home.microsoft.com` (the IE
default on win98se/win2000/nt4), `www.msn.com`, `home.netscape.com` (the tru64
Netscape default) — alongside each station's **vendor** (SGI, Sun, Be, Apple,
IBM, DEC/`digital.com`, HP, Sony, Xerox, Acorn/RISC OS…) and the top web
properties of 1996–2000: AOL, Yahoo, Microsoft, GeoCities, Excite, Lycos, Amazon,
eBay, AltaVista, Google, CNN, the community hosts (Angelfire, Tripod, WebRing),
search/portals, tech media, dot-com shopping, and era-defining novelty (Space
Jam, the Hampster Dance, Zombo.com). **~200 sites**, each crawled to `depth` 3–5;
the richest ~15 marquee anchors are **deepened** (depth 6, higher `max_pages`/
`max_mb`) so breadth-first carries them further before the budget stops it —
roughly a 60/40 split of effort between new breadth and deepened anchors.

### The crawl — `era-press crawl`

Built to be a **polite archive.org citizen** and to run for hours, unattended:

- **Breadth-first, even widening.** It widens **every site together, one depth
  level at a time**: pass 0 mirrors every site's home, pass 1 every site's
  depth-1 links, pass 2 every site's depth-2 links, … round-robining across all
  sites at each level. So an interrupted or budget-stopped crawl covers **every**
  site to the same depth — never a few deep and the rest empty.
- **Parallel, and self-pacing.** Each pass runs on a thread pool of `--concurrency`
  workers sharing **one `httpx` HTTP/1.1 client** (a bounded pool of reused
  connections — see *The fetch transport*). `--concurrency` is only the pool's
  **upper bound**: how many requests are really in flight is decided by the **adaptive
  AIMD limiter**, which climbs while archive.org answers cleanly and halves the moment
  it pushes back (429/502/503, or a refused connection). That is why there is no
  hand-set `--min-interval` any more — archive.org's tolerance moves hour to hour, so
  a fixed rate is always either wasteful or self-tarpitting. The limiter's current
  value is in every progress line (`in-flight limit 6.0`).
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
`era-press.py` **+ its modules (`era_fetch.py`, `era_index.py`, `era_press_core.py`,
`era_crawl.py`)** +
`era-sites.json` into `/data/vms/retronet-crawl/` — so a worktree GC never pulls
the code out from under a multi-hour run — builds a dedicated **venv**
(`/data/vms/retronet-crawl/venv`, pinned `httpx`) beside it (Ubuntu 24.04
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
  by per-site `depth` / `max_pages` / `max_mb` and the global **~5 GB**
  `--budget-gb`, plus a per-resource 8 MB skip guardrail (oversize resources are
  skipped whole, never truncated — truncation would corrupt).
- **Never committed.** Mirrored bytes are copyright and are a box-only bit, the
  same stance as the [private gallery](../PUBLIC-GALLERY.md). Only this tool and
  the wave's tiny **synthetic** fixtures (`scripts/retronet/web/fixtures/`,
  `…/sample-corpus/`) live in the public repo. A fresh box re-presses.

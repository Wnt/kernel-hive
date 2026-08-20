# era-press — the corpus acquisition tool, as built

**Status: LIVE.** Stream **W2** of the [web plane](WEB-PLANE-PLAN.md). era-press
turns real archived 1990s web pages into the local, period-correct corpus the
[proxy](WEB-PROXY.md) serves and the [search engine](WEB-SEARCH.md) indexes. It
runs on **CT950 / labhost** (which has internet); the gateway CT 951 never
fetches anything — it only ever receives files by `pct push`.

```bash
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
   Content-Type are kept as-is.
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

## Notes for the other streams

- **`.cgi`/`.asp` home pages need a content-type map.** era-press faithfully
  stores a page at its real URL, so Space Jam's frame home lands as `index.cgi`
  (the root `/` meta-refreshes to it). The proxy assigns Content-Type **by
  extension**, and `.cgi` is not HTML by extension → it would be served
  `application/octet-stream` and download instead of render. The fix belongs in
  the proxy's content-type map (map the era's server-script extensions —
  `.cgi .shtml .asp .phtml .pl .cfm` — to `text/html`), not in a rewrite here.
  Flagged to W1.
- **Corpus size.** CT 951's rootfs is 8 GB. Crawls are bounded by `--depth` /
  `--max-pages` and a per-resource 8 MB skip guardrail (oversize resources are
  skipped whole, never truncated — truncation would corrupt).
- **Never committed.** Mirrored bytes are copyright and are a box-only bit, the
  same stance as the [private gallery](../PUBLIC-GALLERY.md). Only this tool and
  the wave's tiny **synthetic** fixtures (`scripts/retronet/web/fixtures/`,
  `…/sample-corpus/`) live in the public repo. A fresh box re-presses.

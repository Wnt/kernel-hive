# Which corpus sites actually DRAW — pick a home page from this, not from memory

**Read this before choosing any station's home page, browser bookmark or demo URL.**
A site being in the corpus does not mean it renders. The mirror can hold the HTML and
none of the bitmaps that make it look like a web page, and every layer below the
framebuffer will call that success: the request is `200`, the host directory exists,
the proxy logs no miss for the page itself.

The scorer is [`scripts/retronet/web/corpus_completeness.py`](../../../scripts/retronet/web/corpus_completeness.py).
The corpus is mounted only inside CT 951:

```sh
scp scripts/retronet/web/corpus_completeness.py lab:/tmp/cc.py
ssh lab 'pct push 951 /tmp/cc.py /tmp/cc.py && pct exec 951 -- python3 /tmp/cc.py --top 40'
ssh lab 'pct exec 951 -- python3 /tmp/cc.py --host www.ibm.com'   # one site, with its missing list
```

It counts every bitmap the landing page asks for — `<img src>`, `<input type=image>`,
`background=` on the body and on table cells, CSS `url(...)`, `<embed>`, and the same
across every document of a `<frameset>` — and resolves each against the corpus.
**Ad-server misses are counted separately and never held against a site**: a dead
doubleclick slot is what that page looked like in 1998 anyway.

## The incident this exists for

`os2warp` and `rhapsody` both homed to `spacejam.com`. Its `index.html` is a 470-byte
splash that meta-refreshes to `index.cgi`, and that page's *entire* navigation — the
planet map `img/nf-planets.gif` — was never mirrored, nor was the `bin/index.map`
server-side imagemap behind it. The whole site is 20 files. Two walk-in stations, the
ones anonymous visitors land on first, opened on a black page with a credits icon.
Nobody noticed for weeks, because nothing below the framebuffer could tell.

Rule 9 is the general form of this: **the framebuffer is the only proof**. This scorer
is the cheap pre-filter that stops you spending a bring-up on a hollow site — it is not
a substitute for looking.

## What the survey found (809 hosts, 2026-09-14)

Iconic and hollow — do not use without re-pressing first:

| Site | Bitmaps present | |
|---|---|---|
| `www.winamp.com` | 10% | 65 of 72 gone |
| `www.mtv.com` | 11% | |
| `espn.go.com` | 17% | |
| `www.ebay.com` | 20% | |
| `slashdot.org` | 37% | its images live on `slashdot.wolfe.net`, unmirrored |
| `home.microsoft.com` | 43% | was `win311`'s IE3 home page |
| `www.altavista.com` | 57% | assets are under a bare-IP host |
| `www.ibm.com` | 61% | the natural `os2warp` home page |
| `www.sega.com` | 0% | its one image |

Whole, and rich enough to look like a real page (`--top` reports the current list;
these were the standouts):

| Site | Bitmaps | Demands of the browser |
|---|---|---|
| `www.anandtech.com` | 181 | js, css, tables 5 deep |
| `www.sternpinball.com` | 130 | js |
| `www.novell.com` | 110 | **docwrite** |
| `web.icq.com` | 100 | js, css |
| `www.salon.com` | 96 | js, css |
| `www.fortunecity.com` | 92 | js |
| `www.weather.com` | 79 | **plain HTML**, tables 4 deep |
| `www.mrshowbiz.com` | 76 | js, css |
| `www.cnn.com` | 65 | **docwrite**, tables 5 deep |
| `www.xerox.com` | 45 | **plain HTML** |
| `www.gateway.com` | 37 | frames |
| `www.idsoftware.com` | 30 | js, imagemap |
| `www.connectix.com` | 25 | **plain HTML** |
| `www.sony.com` | 20 | plain HTML |
| `home.netscape.com` | 19 | js, imagemap |
| `www.disney.com` | 18 | frames |
| `www.apple.com` | 14 | imagemap |

## Completeness is only half the question — the other half is the browser

The corpus is served to browsers that predate most of what a 1999 page assumes, so the
scorer also reports what each page **demands**. The one that silently guts a page:

- **`docwrite`** — navigation emitted by `document.write`. **IBM WebExplorer
  (`os2warp`) and OmniWeb 3.0 (`rhapsody`) have no JavaScript at all**, so that nav is
  not slow or ugly, it is *absent*, on a site the scorer calls 100% complete. `cnn.com`,
  `www.novell.com`, `www.corel.com` and `www.iomega.com` are all in this trap.
- **`frames`** — fine for Netscape 4 and OmniWeb 3; WebExplorer cannot.
- **deep tables** — nesting past 3 is where pre-1997 layout engines start drifting.
- **`css`, `layer`** — decoration; these degrade rather than break.

Which door a station uses is a separate axis again, decided by the `Host:` header —
[`WEB-PLANE-PLAN.md`](WEB-PLANE-PLAN.md) has that table.

## When the site you want is hollow

Re-press it rather than settling: `scripts/retronet/web/era-press.py press <host>
--date YYYYMMDD --depth N` re-mirrors the raw Wayback `id_` bytes from CT 950 and
pushes them into CT 951. Most hollow sites here are a capture-date mismatch between the
page and its assets, or a crawl that hit its budget. [`ERA-PRESS.md`](ERA-PRESS.md) is
the tool; corpus bytes are copyright and are never committed.

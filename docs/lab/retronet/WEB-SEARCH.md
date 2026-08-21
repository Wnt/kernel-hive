# The retronet search engine — W3, as built

**Status: BUILDING.** The period search engine over the offline retronet web:
an AltaVista-styled results page and a Yahoo!-styled directory, both rendered as
HTML an era browser (Netscape 4, IE5) draws without complaint, served from the
gateway CT so the corpus-only proxy can route `search.retronet` to it. Stream
**W3** of the [web-plane plan](WEB-PLANE-PLAN.md); it reads the corpus that
[era-press (W2)](WEB-PLANE-PLAN.md) writes and is routed to by
[the proxy (W1)](WEB-PLANE-PLAN.md).

Everything is reproducible from one command run on labhost:

```bash
ssh lab '/data/kernel-hive/scripts/retronet/web/install-search.sh --apply'
```

Idempotent: re-running is the repair path too. It pushes three Python files and
three unit files into CT 951 with `pct push`, renders `/etc/retronet/search.env`,
enables the service + reindex timer, and proves the index builds and the three
routes answer with period HTML — all without the CT ever touching the network
(it has no route to one).

## The contract it builds to

| Thing | Value |
|---|---|
| Listen address | **`127.0.0.1:8090`** inside CT 951 — loopback only; the proxy is the sole client |
| Reserved hostname | `search.retronet` (the proxy routes it here; W1 owns the routing line) |
| Corpus root | `/data/retronet/corpus/<host>/<path>` — read-only to this service; W2 fills it |
| Corpus manifest | `/data/retronet/corpus/sites.json` — `[{host, title, blurb, added}]`; W2 writes it |

The service **only reads** the corpus and **only binds loopback**. Its systemd
unit makes both facts enforceable: `DynamicUser` + `ProtectSystem=strict`
(nothing writable) and `IPAddressAllow=localhost` / `IPAddressDeny=any` (it
cannot reach anything but the co-located proxy). It gets the CT's "no path to
the internet" guarantee by cgroup, not by promise.

## What it serves

| Route | Style | What |
|---|---|---|
| `/` | AltaVista | Front page: a query box and search tips |
| `/search?q=<term>` | AltaVista | Ranked hits — title link, snippet, the `http://<host>/<path>` corpus URL — paginated (`&pg=N`) |
| `/dir` | Yahoo! | The directory built from the corpus, grouped by an optional `category` |
| `/reindex` | — | Rebuild the index now; returns a period confirmation page |
| `/health` | — | `text/plain` `OK <n> docs` — the install-time probe |

Every HTML response is `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">`,
`Content-Type: text/html; charset=iso-8859-1`, tables + `<font>` layout, **no
JavaScript and no CSS**. The byte stream is Latin-1 (`xmlcharrefreplace`, so a
stray UTF-8 character in a title becomes a numeric entity, never mojibake). The
server speaks HTTP/1.0 with `Connection: close`, and normalises both origin-form
(`GET /search?...`) and the absolute-form request line a proxy may forward
(`GET http://search.retronet/search?...`).

### The query language

AltaVista-ish, parsed in `rn_index.parse_query`:

- bare words — **OR**, and each match adds to the score;
- `+word` — **required** (a document without it is dropped);
- `-word` — **excluded**;
- `"a phrase"` — the phrase must appear as a substring (title + text).

Ranking (`rn_index._score`): body term-frequency, **+5** per query word that
also hits the title, **+3** per distinct query word matched (so a document
matching more of the query beats one matching a single word many times), **+10**
per phrase present. Ties break by URL, so results are deterministic.

## How the index is (re)built

The index is a plain in-memory inverted index (`token -> {doc_id: freq}` plus a
title index and, per document, a lower-cased haystack for phrase matching). It
is built **once at startup**, walking `/data/retronet/corpus`, extracting the
`<title>` and visible text of every `*.htm(l)` with the stdlib
`html.parser` (scripts/styles dropped, tag boundaries treated as word
boundaries, a directory's `index.html` mapped to `http://<host>/`).

It is rebuilt — a fresh index swapped in atomically under a lock — three ways,
so a corpus push by W2 is picked up without a restart:

| Trigger | Mechanism |
|---|---|
| **On a schedule (conditional)** | `retronet-search-reindex.timer` (**every 15 min**) → `search.py reindex`: fingerprint the corpus (file count + total bytes + newest mtime, `sites.json` included) and `systemctl try-reload-or-restart` **only if it changed** → SIGHUP; an unchanged corpus is a no-op, so an idle box never churns |
| **On demand** | `systemctl reload retronet-search` (`ExecReload=/bin/kill -HUP $MAINPID`) |
| **On demand (HTTP)** | `GET /reindex` on the loopback service |

The SIGHUP rebuilds the in-memory index **and** re-renders the Yahoo directory,
so a crawl that adds a site shows up in both search and the directory within one
15-minute cycle.

**The corpus, not the manifest, decides what the directory lists.** Every host with
a home page on disk gets a row — `sites.json` supplies the title, blurb and
category where it has them, but it is not a gate: a host mirrored only because
something linked to it is just as browsable as a curated one, and hiding it would
advertise less of the retronet than exists. Conversely a manifest row with nothing
on disk is dropped, because a directory link that cannot be opened is worse than no
link. The conditional gate's fingerprint persists in the
reindex unit's `StateDirectory`, so a change is seen across timer runs and
re-fires until the reload actually happens.

An absent or empty corpus is tolerated at every layer: the index simply has no
documents, `/search` returns a period "No documents match" page, and `/dir`
renders "the directory is empty" when nothing is mirrored yet.

## Files

| Path in CT 951 | What |
|---|---|
| `/opt/retronet-search/search.py` | HTTP service + CLI (`serve` / `index` / `reindex` / `selftest`) |
| `/opt/retronet-search/rn_index.py` | corpus walk, extraction, inverted index, query + ranking |
| `/opt/retronet-search/rn_render.py` | period HTML (AltaVista results, Yahoo directory), Latin-1 |
| `/etc/retronet/search.env` | rendered knobs (host, port, corpus, sites, per-page, snippet) |
| `/etc/systemd/system/retronet-search.service` | the service, enabled |
| `/etc/systemd/system/retronet-search-reindex.{service,timer}` | scheduled reindex, enabled |

Config lives only in `search.env` (systemd `EnvironmentFile`); the unit carries
no defaults of its own. Re-running the installer re-renders it — a hand-edit
there is overwritten, on purpose.

## Develop and test without the box

The engine is developed against a **tiny synthetic corpus fixture** in the repo
(`scripts/retronet/web/fixtures/corpus/`, three authored 1990s-style sites +
`sites.json`) — never scraped content. The bundled self-test asserts the whole
acceptance surface offline:

```bash
cd scripts/retronet/web && python3 search.py selftest
# selftest OK: index, ranking, +/-/phrase, Latin-1, directory, empty-corpus
```

It checks: the fixture indexes, a query returns hits carrying `http://` corpus
URLs, `+`/`-`/`"phrase"` behave, results and directory are valid Latin-1 with no
`<script>`, and an absent corpus is tolerated. Run the service against the
fixture to eyeball it:

```bash
cd scripts/retronet/web
RN_SEARCH_CORPUS="$PWD/fixtures/corpus" python3 search.py serve   # 127.0.0.1:8090
```

## Operating it

The CT has **no curl** (it is offline), so live checks use stdlib `urllib`
through `pct exec`:

```bash
# is it up, and how many docs are indexed
ssh lab 'pct exec 951 -- systemctl status retronet-search --no-pager'
ssh lab 'pct exec 951 -- python3 -c "import urllib.request as u; print(u.urlopen(\"http://127.0.0.1:8090/health\").read().decode())"'

# a real query (period HTML)
ssh lab 'pct exec 951 -- python3 -c "import urllib.request as u; print(u.urlopen(\"http://127.0.0.1:8090/search?q=modem\").read().decode())"' | head

# rebuild the index after a corpus push (either works)
ssh lab 'pct exec 951 -- systemctl reload retronet-search'
ssh lab 'pct exec 951 -- python3 -c "import urllib.request as u; print(u.urlopen(\"http://127.0.0.1:8090/reindex\").read().decode())" >/dev/null'

# build the index once and print stats, no server
ssh lab 'pct exec 951 -- python3 /opt/retronet-search/search.py index'
```

## Seams for the other streams

- **W1 (proxy).** Route the reserved hostname(s) — default `search.retronet` —
  to `127.0.0.1:8090`. One config line; nothing else here depends on the proxy.
- **W2 (era-press).** Write pages under `/data/retronet/corpus/<host>/…` (a
  directory served by its `index.html`); a home page there is all it takes to
  appear in the directory. `sites.json` rows — `{host, title, blurb, added}`, with
  an optional `category` that groups them — supply the presentation for the
  curated set. A push is picked up by the next reindex (≤15 min, and only if the
  corpus fingerprint moved) or immediately with `systemctl reload retronet-search`.

## Known limits

- **In-memory index, rebuilt whole.** No incremental update and no persistence:
  a restart re-walks the corpus. At one CT's worth of static pages this is
  milliseconds; it is not built for a million-page crawl.
- **Snippets are rough.** Tag boundaries insert spaces, so a snippet can show a
  space before punctuation. Period search snippets looked no better; correctness
  (never gluing two words) is worth the cosmetic seam.
- **The reindex is time-based (15 min) and conditional, not push-triggered.** It
  rebuilds only when the corpus fingerprint changed, so an idle box never churns;
  W2 can still force it immediately with `systemctl reload`, and new corpus pages
  otherwise appear within the timer window.

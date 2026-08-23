# Retronet web plane — coordinator contract

**Status: BUILDING.** The second retronet plane: an offline, period-correct web
that era browsers can actually render, plus a local search engine — all served
from the existing gateway CT. The main session coordinates; parallel worker
agents build the pieces. Parent: [`RETRONET-BRIEF.md`](../RETRONET-BRIEF.md) §4;
sibling: the messaging plane in [`POC-PLAN.md`](POC-PLAN.md).

**Goal.** An era browser on a joined station sets one thing — HTTP proxy = the
gateway — and browses a 1990s web served entirely from a local corpus, with an
AltaVista/Yahoo-styled search over it. **No guest ever reaches the real
internet; the proxy has no upstream and never makes one.**

**Update — the seamless, no-proxy web is built and proven (Lane B).** Beyond the
forward proxy, the gateway now runs a `:80` **origin** door, a **wildcard DNS**
(`retronet-dns`, every name → the gateway), and a **DHCP** server (`retronet-dhcp`,
hands out an IP + DNS = the gateway and **no default gateway**). A bridged station
on DHCP sets *nothing* — it types a URL, the name resolves to the gateway, and
`:80` serves the corpus by `Host`. **Proven on win98se: IE5 renders `spacejam.com`
and reaches `search.retronet` with no proxy configured.** As-built + the DHCP
onboarding recipe: [`WEB-PROXY.md`](WEB-PROXY.md) (now the web **+ addressing**
plane) and [`ICQ-STATION.md`](ICQ-STATION.md). The proxy `:3128` door stays; both
serve the same corpus.

## Principles

- **Corpus-only, offline by construction.** The proxy answers every request
  from the local corpus or serves a period miss page. It never opens an upstream
  connection — there is nothing to open one to (the CT has no WAN route). A miss
  is a museum "page not in our internet," never a fetch.
- **Additive, never regressive.** The web plane rides the existing gateway CT
  (951) and its offline bridge. It must not weaken the no-WAN locks or the OSCAR
  service already there.
- **The framebuffer is the only proof** a page *rendered*. Infra agents prove
  their logic with proxy clients / validators; the era-browser render shot is
  the follow-up (below), not skippable hand-waving.
- **Corpus content is never committed.** Mirrored period pages are copyright and
  are a gitignored/box-only bit — same stance as [the private gallery](../PUBLIC-GALLERY.md).
  The repo holds the *tooling* and a tiny synthetic fixture for tests, nothing
  scraped.

## The contract — build to these, don't renegotiate mid-wave

The gateway CT is **951** at **10.99.0.2** on `vmbr-rn` (offline; see
[GATEWAY.md](GATEWAY.md)). All web-plane services live in that CT.

| Thing | Value | Owner |
|---|---|---|
| Corpus root (in CT 951) | `/data/retronet/corpus/<host>/<path>` — static files mirroring each site; dir → `index.html` | W2 writes; W1/W3 read |
| Corpus manifest | `/data/retronet/corpus/sites.json` — array of `{host, title, blurb, category, captured, pages, depth, bytes}` for known hosts | W2 writes; W1 (known-host list) + W3 (directory) read |
| **Proxy** | HTTP/1.0 forward proxy, **`10.99.0.2:3128`**. `GET http://<host>/<path>` → the corpus file; miss → period 404 page. NEVER contacts upstream | W1 |
| Search service | CT-local `127.0.0.1:8090`; the proxy routes reserved hostname(s) (default `search.retronet`) to it | W3 serves; W1 routes |
| era-press | `scripts/retronet/web/era-press.py` on CT950/labhost: fetch **`id_` raw bytes (≤ 2000-12-31)** → mirror **as-is** (page + referenced assets/links, bounded depth) → stage → `pct push` into CT 951's corpus | W2 |

**Fidelity, not downgrade** (era-press output). Fetch the **raw original bytes**
via archive.org's `id_` (identity) modifier — `web.archive.org/web/<ts>id_/<url>`,
which returns the stored response with **no Wayback toolbar and no URL
rewriting** — and serve them **as-is**: original HTML, scripts, images, charset.
**No transformation** (no script-stripping, HTML flattening, PNG→GIF or
re-encoding). **Hard ceiling: nothing past 2000-12-31** — every capture (page and
asset) is the one closest to the site's target era-date but ≤ 2000; a URL whose
only captures are post-2000 is skipped. Period JS and images therefore work
exactly as they did, or **fail exactly as they did** (a resource on a host we
don't mirror hits the museum miss page — authentic). The proxy's host-mapping
resolves same-host links for free.

**Why this decouples the streams:** the corpus *format* is fixed here, so W1
(serve it), W2 (produce it) and W3 (index it) each build to the format against
their own sample fixtures and converge — nobody waits on another's output. The
proxy↔search seam is one config line (hostname → `127.0.0.1:8090`).

## Streams (parallel)

| Stream | Owner | Deliverable | Acceptance |
|---|---|---|---|
| **W1 — proxy** | opus | Corpus-only HTTP proxy on `10.99.0.2:3128` + period miss page + routing reserved hostnames to the search service; systemd unit in the CT; `install-proxy.sh`; reproducible | A proxy client (`curl -x 10.99.0.2:3128 http://<host>/`) serves a corpus page and a period 404 for a miss; **no upstream socket ever opened** (prove it: a request for an uncached host does not touch the network) |
| **W2 — era-press + starter corpus** | opus | `era-press.py` (fetch raw `id_` captures ≤ 2000-12-31 → mirror page + referenced assets/links as-is, no transform → push into CT corpus) + a starter set of ~4 landmark ~1996–2000 sites + `sites.json` | era-press mirrors a real archived site untransformed (raw `id_` bytes, all captures ≤ 2000) into the corpus; `sites.json` lists them; same-host assets resolve through the proxy and no post-2000 content appears |
| **W3 — search engine** | opus | Text index over the corpus + AltaVista-styled results + Yahoo-styled directory (from `sites.json`), served at `127.0.0.1:8090`; systemd unit; `install-search.sh` | A query returns corpus hits linking to pages the proxy serves; the directory lists the known sites; period-styled |

Each stream lands its **own** files under `scripts/retronet/web/` + its own doc
section; **do not edit `provision-gateway-ct.sh`** (add your own `install-*.sh`)
and **do not edit `docs/README.md`** (coordinator indexes). Land a **tiny
synthetic corpus fixture** for tests; never commit scraped content.

## Validation follow-up (not this wave)

True proof is an **era browser rendering a corpus page via the proxy** — the
brief's P0 criterion. Its client is a joined station, and win98se is mid
network-swap. So this wave proves *infra* (proxy client + HTML validator +
search hits); the era-browser render shot happens next, on win98se (IE5, once
it's on the bridge) or tru64 (Netscape 4.76, pointed at the proxy instead of its
NAT). The coordinator wires that after the messaging swap lands.

## Guardrails (every stream)

- Own worktree: `scripts/dev/wt.sh new <name>`; land on `main` yourself
  (commit → push → ff-merge → push); `box-deploy.sh --apply` only if you touch
  deployed streamhost files (web-plane services deploy via your own
  `install-*.sh` run over `ssh lab 'pct exec 951 …'`).
- The gateway CT is offline by design — your service must not add a WAN route or
  reach outside the corpus. era-press's fetch runs on **CT950/labhost** (which
  has internet), never inside the CT.
- **No raw host mounts.** If you must move files into the CT, use `pct push` or
  in-CT writes — never a raw `mount`/`umount` in labhost's namespace (the
  mount-guard blocks it). `chroot-guard run-private` is the sanctioned path if
  you truly need one.
- Green-before-done for the languages you touch, or report **BLOCKED** with the
  failing command + output. Report concisely; detail goes in your doc.

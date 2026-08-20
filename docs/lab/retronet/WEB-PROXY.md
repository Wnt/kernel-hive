# The retronet web proxy — as built

**Status: LIVE** in the gateway CT (951). Stream **W1** of the
[web plane](WEB-PLANE-PLAN.md). An era browser on a joined station sets one
thing — its HTTP proxy to `10.99.0.2:3128` — and browses a 1990s web served
entirely from a local corpus. There is no upstream and there never will be.

Everything here is reproducible from one command, run on labhost:

```bash
ssh lab '/data/kernel-hive/scripts/retronet/web/install-proxy.sh --apply'
```

Named steps (`install`, `seed`, `verify`) can each be run on their own and every
one is idempotent, so re-running is the repair path as well as the build path.
Without `--apply` the mutating steps only print what they would do.

## The one property that matters: no upstream

This proxy **never opens a connection to the real internet.** There is no
upstream fetch, no DNS lookup, no fallback. A request for a host that is not in
the corpus returns a period *"not in the museum's internet"* 404 page — it does
not touch the network. This is the whole security posture of the web plane, and
it is guaranteed three ways, in order of strength:

1. **The code.** `proxy.py` opens an outbound socket in exactly one function,
   `forward_to_search`, and only ever to the fixed CT-local search backend from
   config (`127.0.0.1:8090`) — never to a host named in a request. Every other
   path is local file I/O. A miss reads no file and opens no socket; it returns
   a canned page.
2. **The CT.** The gateway container has no default route (see
   [GATEWAY.md](GATEWAY.md)), so even a bug here has nowhere to send a packet,
   and no resolver to turn a name into an address.
3. **The unit.** `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX` bars raw and
   packet sockets. (The address-level cage the labhost units use — `IPAddress*`
   — is deliberately **not** set here: its eBPF/cgroup filter is not reliably
   enforceable inside an unprivileged LXC, so relying on it would be false
   comfort. `retronet-oscar.service`, the proven in-CT unit, omits it for the
   same reason.)

**Proven, two ways, reproducibly:**

```bash
# 1. Under strace, on labhost — the code makes zero non-loopback connect()s
#    across a corpus hit, a miss, and a search:
scripts/retronet/web/prove-no-upstream.sh
#    -> "PASS: zero non-loopback connects; the only egress was the loopback
#        search backend."

# 2. On the LIVE CT instance — hammer it with misses for uncached hosts and
#    watch its socket table: only ever the listener, never an outbound dial.
ssh lab 'pct exec 951 -- bash -c '\''PID=$(systemctl show -p MainPID --value retronet-proxy);
  ss -tanp | grep "pid=$PID,"'\'''
#    -> a single LISTEN 10.99.0.2:3128 line, nothing else.
```

The second was run against 2473 abort-mid-response misses: the proxy showed only
its listener the whole time, and logged not one traceback.

## The service

An HTTP/1.0 **forward** proxy in Python stdlib (no third-party packages — the CT
could never `pip install` one). It parses the absolute-form request line an era
browser sends a proxy (`GET http://host/path HTTP/1.0`), and:

- **corpus host** → serves `/data/retronet/corpus/<host>/<path>`, a directory
  falling through to `index.html`, with a Content-Type from the extension. Miss
  → the period 404.
- **reserved search host** (default `search.retronet`) → proxies to the search
  service at `127.0.0.1:8090` (Stream W3). W3 down → a clean period **502**, not
  a hang.

Every response is **HTTP/1.0 with an explicit `Content-Length` and
`Connection: close` — no chunked transfer, no gzip** — which is what Netscape 4
and IE5 expect from a proxy. Corpus files are served **untouched**: a
Content-Type by extension and **no imposed charset**. The amended contract is
*fidelity, not downgrade* — the corpus is the raw `id_` archival bytes — so an
era page's own `<meta>` (or the browser's default) decides the encoding, exactly
as it did in period. (Only the proxy's own miss/error pages are Latin-1, and
they are pure ASCII with numeric entities.) The known-vs-unknown host distinction tailors the 404
copy: a host with a corpus dir or a `sites.json` entry gets *"this page isn't in
our copy of X"*; anything else gets *"X isn't part of the museum's internet"*.
`sites.json` is read best-effort with an mtime cache; its absence is valid (an
empty corpus is a valid corpus — everything is then a 404).

| Path in the CT | What |
|---|---|
| `/opt/retronet-proxy/proxy.py` | the proxy (read-only to the service) |
| `/etc/retronet/proxy.env` | rendered config (`0644`; no secrets) |
| `/data/retronet/corpus/<host>/<path>` | the corpus — W2 (era-press) writes, the proxy only reads |
| `/data/retronet/corpus/sites.json` | the manifest — W2 writes; used here for the 404 copy |
| `/etc/systemd/system/retronet-proxy.service` | the unit, enabled, `User=rnproxy` |

### Ports

| Port | Bind | Who dials it |
|---|---|---|
| **3128** | `10.99.0.2` | **The web door.** An era browser's HTTP proxy setting. Reached from labhost over the bridge and from stations via a slirp `guestfwd` (labhost-initiated, so the return path passes `retronet-fw`, exactly like OSCAR's) |
| 8090 | `127.0.0.1` (outbound) | The search service (W3), CT-local. The **only** address the proxy will ever open an outbound socket to |

## Config knobs

Rendered from `scripts/retronet/web/proxy.env.tmpl` into `/etc/retronet/proxy.env`
by the installer — **rendered, not authored**; hand-edit it in the CT and the
next install overwrites you. Override by exporting the matching `RN_PROXY_*`
before running `install-proxy.sh`.

| Knob | Default | Meaning |
|---|---|---|
| `RN_PROXY_LISTEN` | `10.99.0.2:3128` | bind address `host:port` |
| `RN_PROXY_CORPUS` | `/data/retronet/corpus` | corpus root |
| `RN_PROXY_SEARCH_HOSTS` | `search.retronet` | reserved hostname(s) routed to the search service (comma/space separated) |
| `RN_PROXY_SEARCH_BACKEND` | `127.0.0.1:8090` | the search service — the sole outbound target |

## The synthetic sample corpus

`scripts/retronet/web/sample-corpus/example.museum/` is a tiny **hand-written**
fixture (an HTML 3.2 landing page + an about page + a one-entry `sites.json`) so
the proxy can be proven end-to-end without waiting on W2. It is **not scraped
content** and never counts toward the collection. `install-proxy.sh seed` pushes
it into the CT corpus; it is opt-in, so a real W2-populated corpus is never
touched, and it will not clobber an existing `sites.json`. Remove
`example.museum/` from the corpus once real sites land.

## Operating it

```bash
# is it alive
ssh lab 'nc -z 10.99.0.2 3128 && echo up'
ssh lab 'pct exec 951 -- systemctl status retronet-proxy --no-pager'
ssh lab 'pct exec 951 -- journalctl -u retronet-proxy -n 50 --no-pager'

# does it actually serve? (from labhost, through the proxy)
ssh lab 'curl -x 10.99.0.2:3128 http://example.museum/'      # a corpus page
ssh lab 'curl -x 10.99.0.2:3128 http://nope.invalid/'        # the period 404

# the whole acceptance suite (functional + the no-upstream proof)
ssh lab '/data/kernel-hive/scripts/retronet/web/install-proxy.sh verify'
```

Config or code changes go in `scripts/retronet/web/` and land via
`install-proxy.sh --apply install`.

## Known limits

- **One station's worth of scale.** A `ThreadingHTTPServer` with `TasksMax=64`
  and `MemoryMax=192M`. Fine for the exhibit; not a load balancer. No rate
  limiting yet — the brief wants it before the fleet joins.
- **HTTP only.** No HTTPS, no `CONNECT` tunnels (a `CONNECT` gets a period 501).
  The era web the corpus mirrors is http, and a tunnel would by definition need
  an upstream we refuse to have.
- **The corpus lives on the CT's 8 GB rootfs.** No bind mount — W2's `era-press`
  pushes files in with `pct push`. A large corpus is a rootfs-sizing decision
  for later, not this stream's.
- **The render proof is still pending.** A green `verify` proves the *infra*: a
  proxy client gets a corpus page and a period miss, and the code opens no
  upstream socket. The web plane's P0 — an **era browser rendering a corpus page
  via the proxy** — is the follow-up wave, on win98se (IE5) or tru64 (Netscape
  4.76), wired in after the messaging swap lands. The framebuffer is the only
  proof of *that*.

# The retronet web + addressing plane — as built

**Status: LIVE** in the gateway CT (951). Stream **W1** of the
[web plane](WEB-PLANE-PLAN.md), plus the **seamless, no-proxy web** (Lane B) and
its addressing. Two ways to browse the same local corpus, and no upstream, ever:

- **Forward proxy on `10.99.0.2:3128`** — a browser sets its HTTP proxy to it and
  sends absolute-form requests. The original web door.
- **`:80` origin + wildcard DNS + DHCP — set nothing.** A bridged station on DHCP
  gets an IP, a DNS server (the gateway), and **no default gateway**; every name
  it types resolves to the gateway (`retronet-dns`), lands on the gateway's `:80`
  origin (`proxy.py`), and is served from the corpus by `Host`. Type a URL, it
  renders — no proxy configured. An un-mirrored site still resolves to the gateway
  and gets the period miss page (authentic). **Proven on win98se: `spacejam.com`
  renders in IE5 with no proxy** ([ICQ-STATION.md](ICQ-STATION.md) §seamless web).

Three CT-local services, each a small stdlib-Python systemd unit, each installed
from one idempotent command on labhost:

```bash
ssh lab '/data/kernel-hive/scripts/retronet/web/install-proxy.sh --apply'  # :3128 + :80
ssh lab '/data/kernel-hive/scripts/retronet/web/install-dns.sh   --apply'  # wildcard :53
ssh lab '/data/kernel-hive/scripts/retronet/web/install-dhcp.sh  --apply'  # leases + DNS, no router
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

## The service — two doors, one handler

An HTTP/1.0 proxy in Python stdlib (no third-party packages — the CT could never
`pip install` one). The **same handler** serves the same corpus on **two
listeners**, differing only in the request-line form each accepts:

- **`:3128` forward proxy** — the absolute-form line an era browser sends a proxy:
  `GET http://host/path HTTP/1.0`.
- **`:80` origin (vhost)** — the ordinary origin-form a browser with **no proxy**
  sends: `GET /path HTTP/1.0` + `Host: host`. `resolve_target()` already reads the
  host from either form, so the `:80` door needed only a second listener.

Either door then splits the request the same way:

- **corpus host** → serves `/data/retronet/corpus/<host>/<path>`, a directory
  falling through to `index.html`, with a Content-Type from the extension. Miss
  → the period 404.
- **reserved search host** (default `search.retronet`) → proxies to the search
  service at `127.0.0.1:8090` (Stream W3). W3 down → a clean period **502**, not
  a hang.

The `:80` door is what the wildcard DNS points at: a guest resolves every name to
the gateway, connects to `10.99.0.2:80`, and the `Host` header picks the corpus
site. Blank `RN_PROXY_ORIGIN_LISTEN` disables the origin door and leaves the
forward proxy alone.

Every response is **HTTP/1.0 with an explicit `Content-Length` and
`Connection: close` — no chunked transfer, no gzip** — which is what Netscape 4
and IE5 expect from a proxy. Corpus files are served **untouched**: a
Content-Type by extension and **no imposed charset**. The amended contract is
*fidelity, not downgrade* — the corpus is the raw `id_` archival bytes — so an
era page's own `<meta>` (or the browser's default) decides the encoding, exactly
as it did in period. (Only the proxy's own miss/error pages are Latin-1, and
they are pure ASCII with numeric entities.) Because era-press stores each page at
its real URL, an archived HTML **response** can land under a server-script
extension — Space Jam's frame home is `index.cgi` (its `/` meta-refreshes to it).
Those are the HTML the server emitted, not scripts, so `.cgi .shtml .asp .phtml
.pl .cfm` are mapped to `text/html` (otherwise they download instead of render),
and a bytes-level sniff catches any archived HTML whose extension names nothing
(a bare `/cmp/pressbox`, a `.php`/`.dll` home): an octet-stream file that opens
with HTML markup is relabelled `text/html`. Only the header is corrected — the
bytes are still served raw. The known-vs-unknown host distinction tailors the 404
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
| **3128** | `10.99.0.2` | **The proxy door.** A browser's HTTP proxy setting. Reached from labhost over the bridge and from a bridged station directly |
| **80** | `10.99.0.2` | **The origin door.** A no-proxy browser whose DNS is the gateway lands here; served by `Host`. Privileged port — the unit grants `CAP_NET_BIND_SERVICE` |
| 8090 | `127.0.0.1` (outbound) | The search service (W3), CT-local. The **only** address the proxy will ever open an outbound socket to |

## Config knobs

Rendered from `scripts/retronet/web/proxy.env.tmpl` into `/etc/retronet/proxy.env`
by the installer — **rendered, not authored**; hand-edit it in the CT and the
next install overwrites you. Override by exporting the matching `RN_PROXY_*`
before running `install-proxy.sh`.

| Knob | Default | Meaning |
|---|---|---|
| `RN_PROXY_LISTEN` | `10.99.0.2:3128` | forward-proxy bind `host:port` |
| `RN_PROXY_ORIGIN_LISTEN` | `10.99.0.2:80` | `:80` origin (vhost) bind; **blank disables** the origin door |
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

## The addressing plane — wildcard DNS + DHCP

Two more CT-local stdlib-Python units make the `:80` origin door usable with
**zero in-guest config**: a station joins on the Windows DHCP defaults ("obtain an
IP automatically", "obtain DNS automatically") and everything else follows.

### `retronet-dns` — every A answers with the gateway

`dns.py` on **`10.99.0.2:53`, UDP + TCP**. It answers **every A query with one
constant** (default `10.99.0.2`); AAAA (and any non-A) get **NOERROR + no answer
(NODATA)**, so an IPv4-only client falls back to A instead of failing; a malformed
packet is dropped. So any name a guest types resolves to the gateway → `:80` →
the corpus or the period miss page. This also **reinforces containment**: the
resolver holds a constant and opens **no outbound socket at all** — no name can
ever resolve to a real external IP. (It is even safer than the proxy, whose one
egress is the loopback search backend; the DNS `serve` path has none.) Port 53 is
privileged, so the unit grants `CAP_NET_BIND_SERVICE` (works in the unprivileged
CT — the capability is in the container's own bounding set).

| Knob (`RN_DNS_*`) | Default | Meaning |
|---|---|---|
| `RN_DNS_LISTEN` | `10.99.0.2:53` | bind `host:port` (UDP+TCP) |
| `RN_DNS_ANSWER` | `10.99.0.2` | the A record every name resolves to |
| `RN_DNS_TTL` | `300` | answer TTL, seconds |

The CT points its own resolver at itself (`nameserver 10.99.0.2`), so the CT now
resolves names too — `localhost` still comes from `/etc/hosts` (`nsswitch: files
dns`), so nothing CT-local breaks, and `wan-probe` stays green (it dials by IP).

### `retronet-dhcp` — an IP, DNS, and *no* default gateway

`dhcp.py` on **`0.0.0.0:67`** (binds `0.0.0.0` to catch the limited-broadcast
DISCOVER). It hands a client: an IP, the subnet mask, **DNS = the gateway**, an
optional domain — and **deliberately no option 3 (router)**. Withholding the
router is the containment: a guest that gets no default route can reach only the
on-subnet gateway, so *the addressing itself* keeps the no-WAN posture, not just
in-guest config. Addresses come from **per-MAC reservations** first (a known
station keeps a **stable** IP — exec-over-bridge targets `<ip>:7788`), else a
**pool** (`10.99.0.100–200`). Reservations are box-local (real MACs) rendered
from `registry/local.env` `RETRONET_DHCP_RESERVATIONS="mac=ip …"`.

| Knob (`RN_DHCP_*`) | Default | Meaning |
|---|---|---|
| `RN_DHCP_LISTEN` | `0.0.0.0:67` | bind `host:port` |
| `RN_DHCP_SERVER_ID` | `10.99.0.2` | this server's address |
| `RN_DHCP_SUBNET_MASK` | `255.255.255.0` | handed to clients |
| `RN_DHCP_DNS` | `10.99.0.2` | DNS server(s) handed out |
| `RN_DHCP_DOMAIN` | `retronet.lab` | domain suffix (option 15; blank=off) |
| `RN_DHCP_POOL` | `10.99.0.100-10.99.0.200` | general pool |
| `RN_DHCP_LEASE` | `3600` | lease seconds |
| `RN_DHCP_RESERVATIONS` | *(from local.env)* | `mac=ip` pairs |

**The broadcast-route gotcha (cost an afternoon).** A DHCP reply to an IP-less
client is a **limited broadcast** (`255.255.255.255:68`). On a box with **no
default route** (this CT, by design) the kernel has no route for
`255.255.255.255` and the send fails `ENETUNREACH`. So the unit's
`ExecStartPre=+/sbin/ip route replace 255.255.255.255/32 dev eth0` adds a
link-local host route (as root) before the server starts — never a WAN path,
`wan-probe` stays clean. If DHCP OFFERs but never ACKs and the client never gets
an address, this route is the first thing to check. (The server logs a send
failure **loudly** now — a silent `except` once hid exactly this.)

**The fleet-shared-MAC caveat.** Reservations key on the guest MAC, and the
Windows/Unix fleet currently all boot QEMU's **default** `52:54:00:12:34:56` (no
`mac=` in the launcher). So today **only win98se may DHCP** — a second station on
that MAC would collide (both on the bridge → FDB flaps → CT→guest unicast
misroutes) *and* would match the same reservation. Giving each station a **unique**
MAC is the fix, but the MAC lives in the golden's device vmstate (a `loadvm`
restores it regardless of any launcher `mac=`), so a unique MAC needs a **cold
re-bake** per station — a coordinator follow-up before the DHCP fleet retrofit.

## Operating it

```bash
# is it alive
ssh lab 'nc -z 10.99.0.2 3128 && echo up'           # proxy
ssh lab 'nc -z 10.99.0.2 80 && echo up'             # :80 origin
ssh lab 'pct exec 951 -- systemctl status retronet-proxy retronet-dns retronet-dhcp --no-pager'
ssh lab 'pct exec 951 -- journalctl -u retronet-proxy -n 50 --no-pager'

# addressing plane, end to end from labhost:
ssh lab 'python3 /data/kernel-hive/scripts/retronet/web/dns.py query anything.example --server 10.99.0.2:53'  # -> 10.99.0.2
ssh lab 'curl -s http://10.99.0.2/ -H "Host: spacejam.com" | head'   # :80 origin serves the corpus
ssh lab '/data/kernel-hive/scripts/retronet/web/install-dns.sh  verify'
ssh lab '/data/kernel-hive/scripts/retronet/web/install-dhcp.sh verify'

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
- **The render proof landed (win98se, no proxy).** The web plane's P0 — an era
  browser rendering a corpus page — is **done**: IE5 on win98se, on DHCP with **no
  proxy**, renders `http://spacejam.com/` from the corpus and reaches
  `http://search.retronet/`, the address resolved by `retronet-dns` and served by
  the `:80` origin. Baked into win98se's golden ([ICQ-STATION.md](ICQ-STATION.md)).
- **Rate limiting still absent** on all four ports — the brief wants it before the
  fleet joins (era TCP stacks + a flood = broadcast-storm nostalgia nobody
  ordered).

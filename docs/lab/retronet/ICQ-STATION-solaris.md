# solaris ICQ station (climm / OSCAR) — the bridge as-built

**Status: LIVE.** `solaris` (Solaris 10 x86, CDE) is the **first non-Windows**
station on the retronet OSCAR gateway. It runs **climm 0.6.4** (the Unix OSCAR
client, formerly micq) in a CDE `dtterm` titled **ICQ**, auto-signed-in as UIN
`30000` over a real bridged NIC on `vmbr-rn`. Open the station and — after
climm's own reconnect fires on wake — the greeter bot (UIN `10000`, **HiveBot**)
messages it. Parents: [`ICQ-ONBOARDING-PLAN.md`](ICQ-ONBOARDING-PLAN.md) (Tier C),
[`ICQ-STATION.md`](ICQ-STATION.md) (the win98se pathfinder — the host-side
tap/containment wiring is shared), [`GATEWAY.md`](GATEWAY.md), [`BOT.md`](BOT.md).

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device e1000,netdev=net0` (**unchanged** — what `savevm`/`loadvm` bind to), backend went `user`(slirp)→`tap`: `-netdev tap,id=net0,ifname=solrn0,script=no,downscript=no` |
| MAC | **unique** per-station MAC (the fleet otherwise shares QEMU's default `52:54:00:12:34:56` → one FDB entry, unicast flaps between taps, DHCP-reservation collisions). Real value box-local in `registry/local.env` `RETRONET_ICQ_SOLARIS_MAC` (launcher reads it, scrubbed-placeholder fallback committed). It lives in the golden's device vmstate, so it needed a **cold re-bake** — `loadvm` restores the saved MAC regardless of the launcher `mac=`; verified after `loadvm`, and the bridge FDB maps it to `solrn0`. See `WEB-PROXY.md`. |
| Tap | `solrn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/solaris/rn-tapnet.sh up` from the launcher on every start |
| Guest IP | **static `10.99.0.14/24`, NO default route, DNS none** — the Solaris way: `/etc/hostname.e1000g1` = `10.99.0.14 netmask 255.255.255.0 up`, no `/etc/defaultrouter` |
| OSCAR server | gateway CT `10.99.0.2:5190` (the labhost door; advertises BOS `10.99.0.2:5190`, routable from the guest over the bridge) |
| Persona / bot | UIN `30000` (solaris) / UIN `10000` (HiveBot); passwords in `registry/local.env` `RETRONET_ICQ_*` |
| ICQ client | **climm 0.6.4** (`/usr/local/bin/climm`), config `/.climm/climmrc` (`type icq8 auto`, `host "10.99.0.2"`, `port 5190`, `screen "30000"`) + `/.climm/status` (`[Contacts]` → `entry "10000" "HiveBot"`) |
| Exec | `labctl exec solaris "<cmd>"` → in-guest warpd agent (`/opt/warpd/warpd.py`) at **`10.99.0.14:7777` directly over the bridge** (`exec_kind warpd_e`, `exec_host` → `GEXEC_HOST`, host client `/root/gexec.py`); no hostfwd. Pointer stays on `gallery-hid-pci`; warpd is rollback/exec only |

## climm — built on the guest, two source corrections

The media agent sourced climm 0.6.4 (GPLv2, SourceForge tarball, sha256
`c87f17bf…587b`, in the media archive) and confirmed it *should* build with the
box's bundled **gcc 3.4.3** (`/usr/sfw/bin/gcc`). Building it for real turned up
**two facts the writeup's recipe did not have** (it was never run):

1. **Drop `--disable-peer2peer`.** `src/oscar_base.c` references
   `ConnectionInitPeer` unconditionally, but that symbol is only compiled when
   peer-to-peer is enabled — so `--disable-peer2peer` builds all 45 objects and
   then **fails at link** (`ld: fatal: symbol referencing errors … ConnectionInitPeer`).
   The gateway has direct connections off server-side, so p2p is inert in the
   client; just leave it in. Working recipe:
   ```
   PATH=/usr/sfw/bin:/usr/ccs/bin:$PATH CC=/usr/sfw/bin/gcc \
     ./configure --disable-ssl --disable-tcl --disable-otr && make && make install
   ```
   (`/usr/ccs/bin/make`, the SysV make, handles the automake tree fine; no gmake
   on the box. The default install prefix is `/usr/local`.)

2. **Patch the SSI sign-on** (`climm-0.6.4-ssi-login.patch`, in the station dir).
   climm connects, authenticates, and runs the whole post-auth SNAC handshake
   (rates → location → buddy → ICBM → self-info → BOS → the SSI/feedbag roster),
   then **stalls after SNAC (13,6) SRV_REPLYROSTER and times out** — the gateway
   never logs it "signed on". Cause: `SnacSrvReplyroster` only calls
   `CliFinishLogin()` (which sends CLI_READY and completes sign-on) when the SSI
   roster's trailing last-modified timestamp is **non-zero**; a fresh account on
   Retro AIM Server / Open OSCAR Server comes back with a single-packet roster
   whose timestamp is **0**, which stock climm treats as "more packets follow"
   and waits forever. The one-line fix finishes login on the roster reply during
   sign-on regardless of the timestamp (multi-packet post-login refreshes keep
   the original behaviour). This is baked into the built binary, which lives in
   the golden's disk; the patch + the archived tarball reproduce it.

The build runs directly on the live guest over the bridge exec channel; **never
run climm itself through the warpd `E` verb** — it is a long-lived TUI and wedges
the fire-and-forget exec channel. climm runs in the CDE `dtterm` instead.

## The fixture: climm in a CDE terminal

`Xsession.d/9999.golden-fixture` opens a `dtterm -title ICQ -e /usr/local/bin/climm`
after disabling the screensaver/DPMS and the animated front-panel bits. climm
reads `/.climm/climmrc` (`type icq8 auto` → auto-login) and `/.climm/status`
(the contact list). The golden RAM snapshot holds it already connected with
HiveBot online — the authentic "Unix ICQ" look. (climm prints a harmless
`Deprecated syntax … FIXME: dep 22` line for the remote-control default; it is
cosmetic and scrolls off.)

## Containment — proven from inside the guest (`10.99.0.14`)

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2:5190` (OSCAR) | **OPEN** + `ping` reply + UDP egress | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` (ICMP) | **100% loss** | the per-station guard chain `SOLRN-IN` |
| gallery `10.99.0.1:8443` | **BLOCKED (timeout)** | `SOLRN-IN` |
| labhost `10.99.0.1:22` | **BLOCKED (timeout)** | `SOLRN-IN` |
| internet `1.1.1.1:443` / `8.8.8.8:53` | **BLOCKED (network unreachable)** | no default route (Lock 1) |

Same three-layer model as win98se (topology → no-default-route → the
fail-closed `SOLRN-IN` INPUT chain scoped to the guest IP). The exec channel is
**labhost-initiated** (daemon/labctl dials the guest), so its replies pass as
ESTABLISHED while every NEW flow the guest starts toward labhost is dropped;
`rn-tapnet.sh` aborts (QEMU never starts) if the chain does not verify.

## The reconnect mechanism — how "open the station" greets you

climm differs from ICQ 2000b: it **sends its own keepalive every 30 s and has a
built-in reconnect** (`Scheduling v8 reconnect in N seconds`). The golden holds
climm connected on an **ephemeral** BOS source port (not a fixed port like
win98se's 1032). On a fresh launch / `labctl reset` (`loadvm golden`) the golden
port is **stale** — the gateway session that owned it belonged to a QEMU process
that has since exited — so climm's first (overdue) keepalive draws an RST from
the gateway, the socket dies, and climm reconnects on a new port with a fresh
sign-on. The bot sees the fresh presence and greets ~30 s later.

**Measured (proven twice), `labctl reset solaris`:** the guest running, climm
re-signs-on ~18–23 s after the reset (climm's own reconnect backoff is
`10 << attempts` seconds — the first retry is ~10–20 s; `oscar_base.c`), and the
bot's greeting lands ~30 s after that sign-on (`RN_BOT_GREET_DELAY`). So the
bot-side "≤~30 s" is met from the reconnect; end-to-end from the reset it is
~50 s (slower than win98se's ~32 s because climm's backoff dominates, not a
nudge). **No nudge is used or needed** — unlike ICQ 2000b, climm heals itself.
Shortening the reconnect base in the patch (`10 <<` → e.g. `3 <<`) would make it
snappier if wanted, at the cost of a rebuild + re-bake. The wake must find the
guest **running** (a visitor's resume, or the operator watching during a reset);
a guest still idle-paused stays frozen and climm cannot fire its keepalive.

> Measured on the bring-up rig, a bare `loadvm golden` where the gateway *still*
> held the golden's exact session did NOT reconnect (both sides agreed, as with
> win98se) — that only happens when the golden's own port is still live, i.e.
> before climm has ever reconnected away from it. In production it always has.

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (~999 MiB, 2026-08-21) in
  `/data/vms/streamhost/stations/solaris/solariscde-golden.qcow2`. **Tap-native**
  (saved with the `tap` netdev), captured with climm signed in + HiveBot in the
  contact list + a clean frame. `labctl reset solaris` = `loadvm golden`.
- **Pre-swap backup** (QEMU stopped, SHA256-verified) with the old **slirp**
  golden: `/data/gallery-guests/SolarisCDE/golden-backup-rn-netswap-20260820/`
  (`solariscde-golden.qcow2` sha256 `e1fd8d2e…9132c`, `SHA256SUMS` in the dir).
  The pristine gallery image `/data/gallery-guests/SolarisCDE/solaris.qcow2` is
  a separate, older backstop.

Rollback = `systemctl stop streamhost@solaris`, copy the backup qcow2 back,
`systemctl start`.

## Gotchas that cost real time

- **`loadvm` does NOT cross netdev backends.** The pre-swap `golden` was saved
  with a `user` (slirp) netdev; on the `tap` backend `loadvm` fails. The tile
  was **cold-booted on the tap** and a fresh tap-native golden baked (as win98se
  did). Do not try to `loadvm` the pre-bridge snapshot on the tap.
- **Two config files, or the wizard hijacks you.** climm's `format 3` config is
  `climmrc` **plus** a `status` file; with only `climmrc` present, `PrefLoad`
  fails to open the status file, decides "no valid user account", and runs the
  interactive setup wizard. Ship both.
- **`type icq8`, `version 8`, `status online`.** The `[Server]` section's type
  token is literally `icq8` (OSCAR); `auto` on that line is what makes climm
  auto-login. `host`/`port` override the compiled-in `login.icq.com:5190`.
- **root's `$HOME` is `/`**, so the base dir is `/.climm/`, not `/root/.climm/`.
- **Solaris userland surprises:** no `wget`/`curl` (fetch with the bundled
  `/usr/bin/python` `urllib` from the CT over the bridge), no `sed -i`, and
  `/usr/bin/grep` has no `-e`/`-E` (use `/usr/xpg4/bin/grep` or python).

## Operating it

```bash
# is the persona online?
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;d=json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read());print([s[\"screen_name\"] for s in d[\"sessions\"]])"'
# exec over the bridge
ssh lab 'labctl exec solaris "uname -a"'
# the tap + guard chain
ssh lab 'bash /data/vms/streamhost/stations/solaris/rn-tapnet.sh show'
# re-capture the golden (from a CLEAN, connected frame only): delvm golden; savevm golden via drive.py
```

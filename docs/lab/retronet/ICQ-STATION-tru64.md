# tru64 ICQ station (climm / OSCAR) — the es40 bridge as-built

**Status: LIVE.** `tru64` (Tru64 UNIX 5.1B on the **es40** AlphaServer ES40
emulator, CDE) is the **second non-Windows** station on the retronet OSCAR
gateway and the **first es40** one — so its networking differs from every other
ICQ station. It runs **climm 0.6.4** (the Unix OSCAR client, formerly micq) in a
CDE `dtterm` titled **ICQ**, auto-signed-in as UIN `64000` over the guest's
`dec21143` NIC, now homed on the retronet bridge `vmbr-rn`. Open the station and
— after climm's own reconnect fires on wake — the greeter bot (UIN `10000`,
**HiveBot**) messages it. Parents:
[`ICQ-ONBOARDING-PLAN.md`](ICQ-ONBOARDING-PLAN.md) (Tier C),
[`ICQ-STATION-solaris.md`](ICQ-STATION-solaris.md) (the climm recipe this reuses),
[`ICQ-STATION.md`](ICQ-STATION.md) (the win98se pathfinder — the containment model
is shared), [`GATEWAY.md`](GATEWAY.md), [`BOT.md`](BOT.md), and the guest itself,
[`docs/guests/tru64.md`](../../guests/tru64.md).

## What is different here: es40, not QEMU

Every other ICQ station is a QEMU guest whose NIC is a **tap** attached straight
to `vmbr-rn`. tru64 runs on es40, which has **no tap backend** — it captures a
host interface with **libpcap** (`es40.cfg`:
`dec21143 { type = "pcap"; adapter = "tru64-g"; ... }`). So the host side is a
**veth PAIR**, not a tap:

    guest  <- es40 pcap ->  tru64-g  <== veth ==>  tru64-h  -> vmbr-rn (bridge)

es40 opens the **guest end** `tru64-g` with pcap; `rn-tapnet.sh` enslaves the
**host end** `tru64-h` to `vmbr-rn`. Frames the guest sends egress `tru64-g` ->
ingress `tru64-h` -> the bridge forwards them to the gateway CT's `veth951i0`;
frames for the guest's MAC leave the bridge on `tru64-h` -> `tru64-g` -> es40's
pcap -> the guest. That is the same real L2-to-the-gateway a tap gives the QEMU
guests (working UDP + ICMP + multi-connection TCP for OSCAR), reached by a
different backend. veth TX/RX checksum offload is disabled on **both** ends
(`ethtool -K`), or es40's pcap reads locally-originated frames as corrupt.

**This station used to be the one with real internet.** Before the swap the same
`dec21143` was NAT'd outbound (`172.31.66.0/30` MASQUERADE, the exhibit was a
2003 UNIX browsing the live web). The retronet swap **dropped the WAN path**:
`rn-tapnet.sh up` tears down the `/30` address on `tru64-h` and the MASQUERADE
rule, re-homes `tru64-h` onto `vmbr-rn`, and installs the fail-closed guard
chain. There is no route off the retronet any more.

## The wiring, at a glance

| | |
|---|---|
| NIC | `pci0.4 = dec21143 { type = "pcap"; adapter = "tru64-g"; mac = "52:54:00:52:4e:0f"; ... }` in `assets/tru64/es40.cfg` — **unchanged device**; only the `mac` was added and the host end re-homed |
| Host link | veth `tru64-g` (pcap/guest end) `<==>` `tru64-h` (bridge-port end, enslaved to `vmbr-rn`), created + guarded by `streamhost/stations/tru64/rn-tapnet.sh up` from the launcher on every start |
| Guest IP | **DHCP — reserved `10.99.0.15/24`, DNS `10.99.0.2`, NO default route** — `rcmgr set IFCONFIG_0 DYNAMIC` makes `/sbin/init.d/inet` run the Tru64 DHCP client (`joinc` + `dhcpconf`); `retronet-dhcp` reserves `10.99.0.15` on MAC `52:54:00:52:4e:0f` and hands out DNS `10.99.0.2` + domain `retronet.lab` with **no option-3 router** (containment Lock 1). `/etc/hosts` maps `10.99.0.15 tru64`, `/etc/svc.conf` = `hosts=local,bind`. See §DHCP below |
| MAC | **`52:54:00:52:4e:0f`** — the fleet scheme (`52:54:00:52:4e:<last-IP-octet>`, `.15` -> `0f`). Set in `es40.cfg` and **baked by a cold boot** (see below) |
| OSCAR server | gateway CT `10.99.0.2:5190` (the labhost door; advertises BOS `10.99.0.2:5190`, routable from the guest over the bridge) |
| Persona / bot | UIN `64000` (tru64) / UIN `10000` (HiveBot); passwords in `registry/local.env` `RETRONET_ICQ_TRU64_PASS` / `RETRONET_ICQ_BOT_PASS` |
| ICQ client | **climm 0.6.4** (`/usr/local/bin/climm`), config `/home/guest/.climm/climmrc` (`type icq8 auto`, `host "10.99.0.2"`, `port 5190`, `screen "64000"`, `status online`) + `/home/guest/.climm/status`. **The contact list is the server-side SSI/feedbag roster** (`rn-tool.py ssi-seed 64000 ...`), which climm — being SSI-aware — downloads at sign-on: the full list (HiveBot + win98se/win2000/solaris/nt4) renders by name, no local aliasing. See §SSI contacts |
| Exec | `labctl exec tru64 "<cmd>"` rides the emulated **com2 serial line** (`serial-exec.sock`), **not** the NIC (docs/guests/tru64.md). Rehoming the network never touches the exec channel — the whole reconfigure + build was driven over serial |

## The MAC — configurable in es40, baked by a cold boot

es40 is NOT the fleet-scheme exception. The fork's `DEC21143.cpp` reads a `mac`
config knob (`myCfg->get_text_value("mac")`, `xx:xx:xx:xx:xx:xx`; a malformed
value is a hard `FAILURE`), defaulting to `08-00-2B-E5-40-<nic#>` if absent. So
`mac = "52:54:00:52:4e:0f"` in the `dec21143` block is all it takes to assign
one.

But the MAC lives in the es40 **savestate**: `struct SNIC_state` carries
`u8 mac[6]`, and `SaveState`/`RestoreState` `fwrite`/`fread` the whole struct —
so restoring the checkpoint restores the **old** MAC regardless of `es40.cfg`,
exactly like `loadvm` on the QEMU stations. The new MAC therefore had to be
**baked by a cold boot** (the launcher's cold-boot fallback, forced with
`TRU64_SEED=checkpoint/tru64.img` + an empty `TRU64_CHECKPOINT`), then
re-captured. Proven in-guest: `netstat -in` shows `tu0 <Link> 52:54:0:52:4e:f`
(Tru64 prints octets without leading zeros = `52:54:00:52:4e:0f`).

## DHCP — a reserved lease, DNS from the lease, no default route

The guest joins the retronet on **DHCP**, not a hand-set static address.
`rcmgr set IFCONFIG_0 DYNAMIC` makes `/sbin/init.d/inet` run the Tru64 DHCP
client on `tu0`: it brings the device up on `0.0.0.0 broadcast
255.255.255.255`, starts `joinc`, and `dhcpconf -w 60 tu0 start` requests the
lease. The gateway's `retronet-dhcp` answers from a **per-MAC reservation**
(`registry/local.env` `RETRONET_DHCP_RESERVATIONS`, `52:54:00:52:4e:0f=10.99.0.15`),
so the guest keeps the SAME `10.99.0.15` the guard chain (`TRU64RN-IN`) and the
serial exec channel already assume. The reply carries the mask, DNS `10.99.0.2`,
domain `retronet.lab`, and — deliberately — **no option 3 (router)**, so the
guest gets no default route (containment Lock 1, now enforced by the *addressing*).

- **The resolver.** Tru64's `joinc` does NOT rewrite `/etc/resolv.conf` from the
  lease here (proven: a wrong `nameserver` re-leased stayed wrong;
  `.resolv.conf.dhcp.saved`/`.dynamic` never appear). The lease DOES carry the
  DNS + domain (`dhcpparm -i tu0 dn` -> `retronet.lab`; the OFFER carries
  option 6 = `10.99.0.2`), so the resolver is pinned to the DHCP-supplied
  values: `/etc/resolv.conf` = `nameserver 10.99.0.2` + `domain retronet.lab`,
  with `hosts=local,bind` in `/etc/svc.conf` (Tru64 will not consult DNS without
  that switch). This is what makes the **seamless web** work: `httpget
  spacejam.com` resolves to `10.99.0.2` and the `:80` origin serves the corpus
  (**HTTP/1.0 200 OK**, verified). Full addressing plane: [`WEB-PROXY.md`](WEB-PROXY.md).
- **The two `default default` route artifacts.** Tru64's DHCP bootstrap
  (`ifconfig tu0 0.0.0.0 broadcast 255.255.255.255`) leaves two link-scope
  `default`/`default` entries on `tu0` (a net + a host route, **no gateway**),
  even on a clean boot. They are not a path off-subnet — internet `1.1.1.1` and
  labhost `10.99.0.1` are both **100% packet loss** from the guest with them
  present — but they are deleted before the golden is baked so the exhibit shows
  a clean "no default route" table: `route -n delete -net 0.0.0.0 -netmask
  0.0.0.0` then `route -n delete -host 0.0.0.0`. **Do NOT** use `ifconfig tu0
  0.0.0.0 delete` to drop the bootstrap address — it deletes BOTH `0.0.0.0` and
  the leased `10.99.0.15`; the boot path itself removes it with `ifconfig tu0
  -alias 0.0.0.0`.
- **Restore vs boot.** The exhibit **restores** the checkpoint (a RAM snapshot)
  that already holds `tu0 = 10.99.0.15` + the clean route table — restore does
  NOT re-run DHCP, so it stays instant and the artifacts never reappear on the
  hot path. Only a **cold boot** (checkpoint deleted -> seed) re-runs the DHCP
  client, and the seed still carries its pre-retronet config — a stale fallback,
  as it was before this change.

## climm — built on the guest, the solaris recipe minus one flag

climm 0.6.4 (media-archive blob `c87f17bf…587b`, `docs/lab/ASSETS-MANIFEST.md`)
is built on the guest with the **native Compaq C** compiler (`/usr/bin/cc`,
V6.5-011) under **ksh** — the same two-part recipe that built Lynx here:

```
CONFIG_SHELL=/bin/ksh CC=/usr/bin/cc /bin/ksh ./configure \
  --disable-ssl --disable-tcl --disable-otr && make && make install
```

Two corrections carried over from the solaris build, both mandatory:

1. **Do NOT `--disable-peer2peer`.** `src/oscar_base.c` references
   `ConnectionInitPeer` unconditionally; disabling p2p builds every object and
   then **fails at link**. The gateway has direct connections off server-side,
   so p2p is inert — just leave it in.
2. **Apply `climm-0.6.4-ssi-login.patch`** (`streamhost/stations/solaris/`). A
   fresh account's SSI roster comes back in one packet with a last-modified
   timestamp of **0**; stock climm treats 0 as "more packets follow" and never
   calls `CliFinishLogin()`, so sign-on stalls after SNAC (13,6) and times out.
   The one-line fix finishes login on the roster reply during sign-on regardless
   of the timestamp. **Applied to the source before it reached the guest** (on
   labhost, so the guest needs no `patch`), then served pre-patched.

`/bin/sh` on Tru64 is the legacy Bourne shell and dies on modern `configure`
(`syntax error … '(' unexpected`), hence `CONFIG_SHELL=/bin/ksh`. Configure runs
~35 min and `make` ~45 min on the emulated Alpha; both were run **detached with
a log and polled** (a `labctl exec` that outlives its timeout strands the serial
line). The default install prefix is `/usr/local`.

The build ran directly on the guest over the serial exec channel; **climm itself
runs in the CDE `dtterm`, never through the exec channel** — it is a long-lived
TUI and would wedge the fire-and-forget serial relay.

## The fixture: climm in a CDE terminal

The exhibit autologs in the unprivileged `guest` (uid 300); climm runs in that
session, config under `/home/guest/.climm/`. climm's `format 3` config is **two
files** — `climmrc` (`type icq8 auto` -> auto-login, `host`/`port` override the
compiled-in `login.icq.com:5190`, `password` stored in plaintext) **plus**
`status` (the contact list). Ship BOTH: with only `climmrc`, `PrefLoad` fails to
open the status file, decides "no valid user account", and runs the interactive
setup wizard. The golden RAM snapshot holds climm already connected in a `dtterm`
titled **ICQ**, with HiveBot online — the authentic "Unix ICQ" look.

For the **cold-boot fallback** (checkpoint deleted), `/etc/dt/config/Xsession.d/9999.icq-fixture`
(reference copy `streamhost/stations/tru64/9999.icq-fixture`) launches the same
`dtterm -e climm` at CDE session start — the Tru64 sibling of solaris's
`9999.golden-fixture`. It never fires on the restore path (Xsession.d does not
run when es40 loads a savestate), so it cannot double-launch climm.

## SSI contacts — the full roster comes from the server, synced on login

climm is **SSI-aware**: on sign-on it downloads the account's server-side
**SSI/feedbag** roster (SNAC `0x13`) and renders every contact by its directory
nickname. So tru64's contact list is not shipped in the local `status` file — it
is seeded **server-side**, once, with the gateway's tool (the retronet
SSI-fabric pass does this for every station):

    pct exec 951 -- python3 /opt/ras/rn-tool.py ssi-seed 64000 \
      10000=HiveBot 98980=win98se 20000=win2000 30000=solaris 40000=nt4

`rn-tool.py buddies 64000` reads the roster back — **`10000 20000 30000 40000
98980`**, HiveBot + the other four stations. On login climm reconciles its local
list against the server's and downloads what it is missing, which the ICQ
`dtterm` logs verbatim:

    Contact 98980/win98se exists only on the server (#4).
    Contact 40000/nt4     exists only on the server (#3).
    Contact 30000/solaris exists only on the server (#2).
    Contact 20000/win2000 exists only on the server (#1).

— the four render **by name**, HiveBot online alongside, no client-local
aliasing. This is the SSI leg the contact seeder always intended for the Unix
(`unix-oscar`) clients: an ICQ client fetches the nickname from the same
directory the server holds, so a bare UIN never shows. Baked into the golden, so
`open tru64` lands on the full five-contact list. (`rn-tool.py buddies` reads the
SSI roster; `client-buddies` reads the legacy `clientSideBuddyList` the ICQ 2000b
Windows stations push — a different structure, empty for the climm accounts.)

## Containment — proven from inside the guest (`10.99.0.15`)

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2:5190` (OSCAR) / `:8099` (build) | **OPEN** + `ping` reply + HTTP 200 | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` (ICMP) | **100% loss** | the per-station guard chain `TRU64RN-IN` |
| gallery `10.99.0.1:8443` (TCP) | **no response / blocked** | `TRU64RN-IN` |
| internet `1.1.1.1` (ICMP) | **100% loss (unreachable)** | no default route (Lock 1) |

Same three-layer model as solaris/win98se (topology -> no-default-route -> the
fail-closed `TRU64RN-IN` INPUT chain scoped to the guest IP, inserted above
`RETRONET-IN`). tru64's exec channel is **serial**, not IP, so the guest never
legitimately initiates a flow toward labhost at all — the guard's
`ESTABLISHED,RELATED RETURN` is there only to match the proven pattern; every
NEW flow the guest starts is dropped. `rn-tapnet.sh` reads the chain back out of
the kernel and the launcher aborts (es40 never starts) if it does not verify.

## The reconnect mechanism — how "open the station" greets you

Same as solaris: climm **sends its own keepalive every 30 s and reconnects on
its own** (`Scheduling v8 reconnect in N seconds`, `oscar_base.c` backoff
`10 << attempts`). The golden holds climm connected on an **ephemeral** BOS
source port; on a fresh launch / reset the golden's gateway session is stale
(its es40 process is long gone), so climm's first overdue keepalive draws an RST,
the socket dies, and climm reconnects on a new port with a fresh sign-on. The bot
sees the fresh presence and greets. **No nudge is used or needed** — unlike ICQ
2000b, climm heals itself. The wake must find the guest **running** (a visitor's
resume, or the operator watching during a reset); a still-idle-paused guest stays
frozen and climm cannot fire its keepalive.

**Measured (production restore path, 2026-08-21):** `systemctl start streamhost@tru64` at 07:34:16 -> es40 restored the CDE desktop (fb 1280x1024) in ~4 s -> climm's overdue keepalive drew the gateway's RST and it **re-signed-on at 07:34:19 (~3 s)** -> the bot's greeting landed at **07:34:49** (`RN_BOT_GREET_DELAY=30`), i.e. **~33 s end-to-end**, and rendered in the ICQ dtterm: `HiveBot <<< hey, are you the one on the Alpha? :)`. climm self-reconnected — **no nudge** (unlike ICQ 2000b). The reconnect is quicker than solaris's ~18-23 s because the frozen RAM state leaves the keepalive maximally overdue, so it fires the instant the guest resumes. The wake must find the guest **running** (a visitor's resume, or the operator watching a reset); a still-idle-paused guest stays frozen and climm cannot fire its keepalive.

## Golden lineage & rollback (FULL paths)

This station's "golden" is an es40 **checkpoint** (savestate + the disk it was
baked from + `rom/`), not a QEMU snapshot. See
[`docs/guests/tru64.md`](../../guests/tru64.md#checkpoint-restore).

- **LIVE checkpoint:** `assets/tru64/checkpoint/{tru64.axp,tru64.img,rom/}` —
  re-baked 2026-08-21 for **DHCP + the full SSI contact list**: a guest reboot
  ran the boot-time DHCP client (`IFCONFIG_0=DYNAMIC`), climm re-signed-on and
  downloaded the five-contact SSI roster, the two `default default` route
  artifacts were deleted, and the state was captured with climm **online** +
  contacts synced via the serial-menu save-and-exit (option 5, so state and disk
  are an atomic pair). Prior lineage: a cold boot baked the unique `mac` and the
  retronet rehoming + climm build. A `labctl reset tru64` restores it. The bake
  is safe on the live station because a `Restart=no` drop-in was set first, so
  the daemon could not relaunch and `rm -rf work/` between the save and the copy.
- **Pre-DHCP backup** (the retronet static-IP checkpoint, the rollback for this
  change): `assets/tru64/checkpoint.bak-predhcp-20260821/{tru64.axp,tru64.img,rom/}`.
  Rollback = stop `streamhost@tru64`, restore that dir over `checkpoint/`, start.
- **Pre-swap backup** (the WAN/internet checkpoint):
  `assets/tru64/checkpoint.bak-prern-20260821/` — the outbound-NAT golden.
  Rollback = stop `streamhost@tru64`, restore that dir over `checkpoint/`,
  restore `es40.cfg.bak-prern-20260821`, restore
  `x11-runtime.sh.bak-prern-20260821`, `rn-tapnet.sh down`, start.

## Gotchas that cost real time

- **The MAC is in the savestate** — a `mac=` change needs a **cold boot** to
  bake, not just a launcher edit; a checkpoint restore brings the old MAC back.
- **`ifconfig tu0 <new>` then `ifconfig tu0 <old> delete` can drop BOTH
  addresses.** Set the address once (`ifconfig tu0 inet 10.99.0.15 netmask
  255.255.255.0 up`) and delete the default route separately; don't chain a
  delete of the old address.
- **The serial exec line dislikes long, quote-heavy commands** — the persistence
  edits (rcmgr / sed / mv) had to be split into small separate calls or the
  exchange lost its sentinels. Keep each `labctl exec` short.
- **Serve build inputs from the CT `10.99.0.2`, not labhost `10.99.0.1`.** The
  guard chain drops guest->labhost, so the old `httpfetch 172.31.66.1` path is
  gone; a throwaway `python3 -m http.server` on the CT (`10.99.0.2:8099`,
  reachable intra-bridge) delivers the pre-patched climm tar.
- **Baking on the live station must block the daemon's relaunch.** Option 5 makes
  es40 exit; the unit's `Restart=on-failure` would then relaunch it and
  `rm -rf work/` (fresh reflink copy) **before** you stage `work/autosave.axp`.
  Set a `Restart=no` systemd drop-in (`+ daemon-reload`) BEFORE the bake, `stop`
  the unit, copy `work/{autosave.axp,img/tru64.img,rom/}` into `checkpoint/`
  (temp name + `mv`), then remove the drop-in and `start`.
- **climm auto-aways after ~10 min idle.** During a long bake-prep session
  (idle-pause off, no client keyboard) climm sets itself **away**, and the bot
  does not greet an away persona. Type `online` in the ICQ `dtterm`
  (`es40-gtype.py`) and confirm `status is online` on the framebuffer before
  triggering the bake. Also disable the daemon's idle-pause for the working
  session (`SH_IDLE_PAUSE_SECS=0` in the live `station.env`; restore to `60`
  after) so the guest does not freeze mid-reconfigure — a paused guest fights the
  serial exec and corrupts its login flow.

## Operating it

```bash
# is the persona online?
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;d=json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read());print([s[\"screen_name\"] for s in d[\"sessions\"]])"'
# exec over the serial line (NOT the NIC)
ssh lab 'labctl exec tru64 "netstat -in | grep tu0"'
# DHCP state in the guest (leased IP + resolver)
ssh lab 'labctl exec tru64 "ifconfig tu0 | grep inet; cat /etc/resolv.conf"'
# the server-side SSI contact roster climm downloads (HiveBot + 4 stations)
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 64000'
# the veth link + guard chain
ssh lab 'bash /data/vms/streamhost/stations/tru64/rn-tapnet.sh show'
# re-bake the checkpoint: see docs/guests/tru64.md (serial IAC BREAK -> option 5)
```

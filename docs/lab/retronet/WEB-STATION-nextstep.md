# nextstep on the retronet — the web plane, and the first station in a netns

**Status: LIVE since 2026-08-25 — in the golden, on the station, cut over.**
`nextstep` — NeXTSTEP 3.3 for m68k on an emulated NeXTcube, in **Previous** —
reaches the retronet bridge `vmbr-rn` at **10.99.0.25**, statically addressed,
browsing the museum's corpus with **OmniWeb 2.7b3** through the gateway's `:80`
origin door with **no proxy configured**. The framebuffer proof is the 8 May
1998 `www.apple.com` home page, images and all, on the grey NeXTSTEP Workspace
— the company that bought NeXT, rendered on the machine NeXT built.

Web plane only. **No ICQ:** no OSCAR client is built for NeXTSTEP/m68k, so there
is no roster row and no persona — the registry declares `planes: ["web"]`.

Parents: [`../RETRONET-BRIEF.md`](../RETRONET-BRIEF.md) §4 (the web plane),
[`GATEWAY.md`](GATEWAY.md) (the CT and its containment locks),
[`WEB-PROXY.md`](WEB-PROXY.md) (the two doors and the reservation ledger). The
guest itself is [`../../guests/nextstep.md`](../../guests/nextstep.md) — read
that first: the live station today is still the **captured-Debian-kiosk** shape,
and this work is for the **host-native** Previous shape that replaces it
(AGENTS.md rule 12). Sibling browser work on the only other NeXT-lineage guest:
[`WEB-BROWSER-rhapsody.md`](WEB-BROWSER-rhapsody.md).

## What made this one different

Every other station on this bridge is an emulator in the host network namespace
holding a **tap**. This one is host-native Previous, and it must be
**CRIU-checkpointable**, and those two facts change the plumbing:

| | |
|---|---|
| **The link** | A **veth pair**, not a tap. `criu` can dump a netns containing a veth if told `--external veth[nextrn1]:nextrn0`; it **cannot** dump a tap whose fd lives outside the dump set (`criu/tun.c: No fd info for non persistent tun device`), which is exactly the shape every other bridged station uses. slirp4netns and pasta are documented dead ends for the same problem — [`irix-criu/README.md`](../../../scripts/build-guests/irix/irix-criu/README.md). So the emulator runs **inside** a private netns and the veth's outer end is the bridge port. |
| **The NIC** | The NeXT's on-board ethernet, driven through Previous's own **libpcap** backend (`src/enet_pcap.c`). `[Ethernet] nHostInterface = 1` selects `ENET_PCAP` over `ENET_SLIRP`; `szInterfaceName` names the interface, and it must be the **inner** veth end. |
| **The MAC** | Stays NeXT's OUI: **`00:00:0f:52:4e:19`**, not the fleet's `52:54:00:52:4e:<octet>`. NeXTSTEP takes the station address from the machine's **ROM**, so the guest owns it — the same exception `irix` (SGI's OUI) and `macos753` (Apple's) have, for the same reason. Previous's `[ROM] bUseCustomMac` + `nRomCustomMac3..5` rewrite only the low three bytes of the ROM image **and recompute the ROM's checksum**, which is what makes this safe; the OUI and the stock ROM's `00:00:0f:00:f3:02` low bytes are not otherwise negotiable. **Every Previous instance ships that same stock address**, so a second host-native NeXT on this bridge without a custom MAC is a guaranteed L2 collision. |
| **The addressing** | Static, hand-configured. NeXTSTEP 3.3 predates DHCP entirely — `-AUTOMATIC-` in `/etc/hostconfig` means **BOOTP**, which the retronet does not answer. Same class as `chokanji`, `rhapsody` and `macos753` ([`WEB-PLANE-PLAN.md`](WEB-PLANE-PLAN.md) §pre-DHCP). |

## The wiring, at a glance

| | |
|---|---|
| Link | veth **`nextrn0`** (host end, enslaved to `vmbr-rn`) ↔ **`nextrn1`** (inside netns `nextstep-rn`, where Previous binds libpcap). Created + guarded by [`streamhost/stations/nextstep/rn-tapnet.sh`](../../../streamhost/stations/nextstep/rn-tapnet.sh) `up`, which is **idempotent by requirement**: criu deletes and re-creates the pair on every restore, so `up` is the post-restore hook as well as first-time setup |
| Guest IP | **static 10.99.0.25/24**, from `/etc/hostconfig` `INETADDR`. A `RETRONET_DHCP_RESERVATIONS` row keeps the address unique fleet-wide without ever leasing it |
| Default route | **NONE.** `/etc/hostconfig` `ROUTER=-NO-`, so the guest's own stack cannot form a packet to anything off `10.99.0.0/24` |
| Seamless web | `/etc/resolv.conf` = `10.99.0.2` + **no proxy in OmniWeb** → any name resolves to the gateway, where the `:80` origin serves the corpus or the museum's miss page |
| Browser | **OmniWeb 2.7b3** (Omni Group, 5 Sep 1997), home page `http://www.apple.com/` |
| Guard | `NEXTSTEPRN-IN`, scoped to `10.99.0.25`, inserted at INPUT position 1 |
| Exec | telnet, `me` → `su`, both passwordless, driven by [`nextstep-nstel.py`](../../../scripts/build-guests/nextstep-nstel.py) with `NSTEL_HOST`/`NSTEL_PORT` pointed at `10.99.0.25:23` |

## The trap that cost the most: TX checksum offload

**A guest that pings perfectly, answers an `nmap` SYN scan with eight open
ports, and refuses every ordinary connection from labhost is not firewalled and
its inetd is not dead. Its emulator is reading unfilled checksums off a veth.**

Linux hands a locally-generated TCP segment to a veth with the TCP checksum
field **not computed** (`CHECKSUM_PARTIAL`): a real NIC would fill it in, and a
peer inside the same kernel understands the flag and never looks. **libpcap does
not.** Previous reads the raw frame, NeXTSTEP's 1994 TCP validates the checksum,
finds garbage, and drops it **silently** — no RST, no ICMP, nothing on the wire
but the host retransmitting SYNs forever.

Three things make this hard to see, and all three happened here:

- **ICMP is fine.** The kernel checksums ICMP in software, so `ping` — the first
  thing anyone reaches for — says the guest is healthy. It is the one probe that
  lies on this link.
- **`nmap -sS` is fine.** It builds its SYN on a raw socket (checksum in
  software) *and* reads the reply through libpcap, below the host stack. So a
  scan reports every port open at the same moment `bash`'s `/dev/tcp` times out
  against those same ports. That contradiction is the diagnostic.
- **Guest→gateway is fine**, because the guest checksums its own traffic
  properly. So the corpus fetch that the whole station exists for cannot be used
  to detect the fault.

The fix is one line per end, and `rn-tapnet.sh` now applies it on every `up`:

```sh
ethtool -K nextrn0 tx off gso off tso off gro off        # host end
nsenter --net=… ethtool -K nextrn1 tx off gso off tso off gro off
```

GSO/TSO go with it for a related reason: an over-MTU segment the NIC would have
split arrives as one oversized frame the guest cannot parse.

Two hours went into `tcp_timestamps`, `tcp_sack` and `tcp_window_scaling` first
— every combination toggled and re-tested — because "1994 stack, modern TCP
options" is the obvious hypothesis and it is **wrong**. The `tcpdump -vv` line
that ends it says `cksum 0x150e (incorrect -> 0x62da)` on the outgoing SYN, and
that annotation is easy to dismiss as normal offload noise on a local capture.
On a pcap-backed emulator it is the whole bug.

**This applies to every pcap emulator on a veth, not just this one.**

## The other trap: NeXTSTEP will not finish booting on a real bridge

A stock NeXTSTEP 3.3 has `/machines/broadcasthost` in its local NetInfo domain
carrying `serves = ../network`, which tells `netinfod` to **broadcast for a
parent NetInfo domain**. Under SLIRP that fails fast and boot continues. On
`vmbr-rn`, with fourteen other stations on the segment, it never resolves and
the boot **stops** at a full-screen console panel:

```
Still searching for parent network administration (NetInfo) server.
Please wait, or press 'c' to continue without network user accounts.
```

`inetd` starts *after* that point, so there is no exec channel to fix it from —
and **pressing `c` does not rescue the boot**: rc skips the rest of the network
start and the station comes up to a perfectly normal-looking desktop with **no
listeners at all**. Measured twice, once per hypothesis.

So `niutil -destroyprop . /machines/broadcasthost serves` has to be done
**before** the guest is ever booted on the bridge, from a SLIRP session. It also
stops the guest broadcasting RPC portmap onto the retronet forever, which is a
containment win in its own right. This is the same shape as irix's "a cold boot
with a MISMATCHED address wedges" ([`WEB-STATION-irix.md`](WEB-STATION-irix.md)):
**bake the guest's network config off the bridge, then boot it on the bridge.**

## Which gateway door, and why — measured

**The `:80` origin door, seamlessly, with no proxy configured.**

OmniWeb 2.7b3 sends a `Host:` header even on HTTP/1.0. Measured, not assumed —
from the gateway's own access log, whose `Host` field is explicit:

```
retronet-proxy 10.99.0.25 www.apple.com - "GET / HTTP/1.0" 200 -
retronet-proxy 10.99.0.25 www.apple.com - "GET /main/elements/apple.gif HTTP/1.0" 200 -
retronet-proxy 10.99.0.25 www.apple.com - "GET /home/images/promos/pro.jpg HTTP/1.0" 200 -
```

Origin-form request line, populated `Host`, `200` on the page and on every GIF
and JPEG it references. This puts nextstep with `rhapsody` (OmniWeb 3.0, same
lineage, same answer) and **against** `macos753`/MacWeb 2.0 and
`os2warp`/WebExplorer 1.2, which send no `Host:` and can only use the `:3128`
proxy door ([`WEB-PLANE-PLAN.md`](WEB-PLANE-PLAN.md)). Do not copy a proxy
configuration here; it is not needed and would only add a failure mode.

If a proxy is ever genuinely wanted, OmniWeb 2.x reads `ProxyServers` in the
`OmniWeb` defaults domain (`OWProxyServer.m`, `proxyServersFromDefaults`). That
format was not reverse engineered; the supported route is the GUI.

## The browser

| | |
|---|---|
| Browser | **OmniWeb 2.7b3**, Omni Group, `2.7-beta-3`, `Fri Sep 05 1997` |
| Source | `https://files.omnigroup.com/software/Archive/NEXTSTEP/OmniWeb/OmniWeb-2.7b3-N.tar.gz` — **the Omni Group's own archive**, still online |
| File | `1,144,357 B`, md5 `0801c5155a2a8d8b7085114da58171b6`, sha256 `47bb92f4105e9176d347c05abae39c8a847c6f3d66f282800f993f165b9d5cdc` |
| Arch | the archive's **`-N` slice is the NeXT/m68k** one (`-I` Intel, `-H` HP PA-RISC, `-S` SPARC, `-NIHS` all four). Guest `file` reports `Mach-O executable (for architecture m68k)` |
| Self-contained | OmniFoundation/OWF/OmniImage are **statically linked in**; the only shared libraries it needs are NeXTSTEP's own (`libFoundation_s`, `libNeXT_s`, `libsys_s`, …). Nothing else to install |
| Plugins | gif, jpeg, png, xbm, xpm, inflate, Gopher — all inside the bundle; the JPEG and GIF ones are exercised by the acceptance page |

### The browser that should have been here, and why it is not

The first web browser in the world was written on a machine exactly like this
one — Tim Berners-Lee's **WorldWideWeb**, NeXTSTEP 0.9/1.0, 1990 — and a
NeXTcube exhibit running it would be the single most on-the-nose thing in this
museum. It is not what ships, for two reasons that are worth stating rather than
quietly dropping.

It is a **0.x-era application**: the surviving builds target NeXTSTEP 0.9–1.0
and do not run unmodified on 3.3, whose AppKit and Objective-C runtime moved
under it. And it renders the web *it* knew — no inline images, no tables, no
forms — so on a corpus of 1996–2000 pages it would show a station that looks
broken rather than a station that looks 1990. The exhibit's job is to make the
period web legible; OmniWeb does that and WorldWideWeb would not.

The right home for the poetry is a **second, deliberately-labelled exhibit**
(CERN's line-mode browser and the WorldWideWeb reconstruction both exist), not
the station's only browser. Noted here so the next agent does not re-derive it.

**Why 2.7b3 and not 2.5 final.** Both are on the same archive page and both
contain the Lighthouse licence framework's string *"Your demonstration copy of
OmniWeb has expired"* — so the beta/final distinction does **not** separate a
time bomb from a safe build here, the way it does for OmniWeb 3.0b8b on
[rhapsody](WEB-BROWSER-rhapsody.md). Unregistered, 2.7b3 says *"This program is
not registered. Printing and saving are disabled"* and browses normally, which
is all a museum exhibit needs. 2.7b3 is the last NEXTSTEP OmniWeb and renders
the corpus better; `OmniWeb-2.5-N.tar.gz` (md5 `ede79ef0237818e80a63119ea0d7dc6a`)
is the fallback if an expiry ever bites.

### How the bits get in: TFTP, not FTP and not a payload disk

`rhapsody` used a raw second IDE disk. That is not wanted here — Previous's disk
set is part of what a `loadvm`/CRIU checkpoint pins, and an extra disk also
provokes a modal "unreadable disk" panel that has to be dismissed by hand.

The network routes were tried in order:

- **FTP is out.** NeXTSTEP 3.3's `/usr/ucb/ftp` has **no `passive` command**
  (`help` lists 60 commands and passive is not among them). Active mode needs
  the *server* to dial the *guest*, and Previous's SLIRP only forwards a fixed
  list of low ports inbound, so the data channel can never be established.
- **TFTP works**, because the guest is the client and guest→host UDP is plain
  NAT. One catch: a normal TFTP server answers from a **fresh** ephemeral TID,
  and SLIRP's UDP NAT keys on `(guest port, host addr, host port)`, so that
  reply is unsolicited and dropped. BSD `tftp` adopts whatever source port the
  first DATA packet arrives from, so a server that answers **from its own
  listening port** is legal and is the only shape that survives the NAT. That is
  `tinytftpd.py` on the rig; 1,144,357 B moved in 7.2 s, byte-exact.

## The exec channel, and one trap inside it

`labctl exec nextstep` reaches the kiosk, not the NeXT
([`../../guests/nextstep.md`](../../guests/nextstep.md) §10). The NeXT's own
channel is telnet — `me` (no password) then `su` (no password) — driven by
`nextstep-nstel.py`, which now takes `NSTEL_HOST`/`NSTEL_PORT` from the
environment so the same client reaches the guest through Previous's SLIRP
redirect during bring-up and directly on `10.99.0.25:23` afterwards.

Three things about that channel are worth knowing before using it:

- **Root's shell is `csh`.** Every command must be one line, and `2>&1` is a
  syntax error there — it silently produces nothing, which reads like a command
  that found nothing rather than one that never ran.
- **`dwrite` under `su` writes ROOT's defaults.** The NeXTSTEP defaults database
  is per-effective-user, so an OmniWeb home page set from a su'd session is
  invisible to the console user `me` — and `dread` in the same session reads it
  straight back, so everything looks correct. Identical trap, identical cost, on
  [rhapsody](WEB-BROWSER-rhapsody.md).
- **`ping` takes no `-c`.** It is `ping host [datasize] [npackets]`, so
  `ping -c 3 10.99.0.2` treats `-c` as the hostname and prints
  `sendto: Network is unreachable` forever — on a station whose routing is
  precisely the thing under test.

**GUI apps cannot be launched from it.** `open` and OmniWeb's own `openURL` both
die (`DPS client library error: Could not form connection` /
`open: can't open connection to Workspace on local host`) — a telnet login is
not in the console session's window-server namespace. Same as rhapsody.

## Driving the desktop headless — and the keyboard shortcut that made it easy

The rig drives the guest through Previous's `mamectl/1` control socket
(`PREVIOUS_CTL_SOCK`), so there is no X server and no window anywhere.

The **pointer is the weak leg on a stock disk.** `MOVEA` is exact only when the
guest's SummaGraphics tablet driver is attached, and a fresh `NS33.dd` has never
run `/NextAdmin/InstallTablet.app`. Without it the emulator dead-reckons through
the relative KMS path, and NeXTSTEP applies **its own** mouse-acceleration curve
on top, so commanded pixels and landed pixels do not agree and a closed loop
over the framebuffer converges slowly or not at all. A `MOVEA 655 258` landed at
`(882, 780)`.

**The keyboard does not have that problem, and the Workspace is fully
type-selectable.** With the File Viewer frontmost, typing `omni` selects
`OmniWeb.app` in the browser column and `Return` opens it. That is how the
acceptance shot was taken, and it is the reliable way to drive this desktop
until the tablet driver is in the golden:

```python
nstype.typestr(c, "omni")   # selects OmniWeb.app in the File Viewer
nstype.tap(c, 0x2A)         # Return — launches it
```

## Discoverability

The visitor sees the browser three ways, and none of them needed the Dock:

1. **`/me/OmniWeb.app`** — a real bundle in the home directory, so OmniWeb's own
   globe icon sits in the File Viewer window NeXTSTEP opens for itself at login.
   This is the AGENTS-rule minimum and it is met on a plain boot.
2. **`/LocalApps/OmniWeb.app`** — the canonical install, which is also what
   registers OmniWeb as the handler for `.html`.
3. **The browser window itself, open on the corpus home page**, carried by the
   checkpoint. The golden is a RAM image, so one launch before the bake is what
   every visitor sees forever after — the same delivery rhapsody uses.

**The Dock is NOT done.** NeXTSTEP 3.3 keeps it in `~/.NeXT/apps3_0.wmd` under a
`Dock = "…"` key whose value is a NUL-separated string table plus a packed token
stream (`19 2 0 1 2 3 5 0 4 2 3 5 6 7 4 8 9 …`) that was not reverse engineered.
Unlike rhapsody's Dock it is at least *in a file* rather than behind a
Distributed Objects call, so it is probably scriptable by someone who wants to
decode it. The supported route today is to **drag the icon into the Dock by
hand**, which needs the tablet driver first.

## Acceptance

Framebuffer, which is the only proof that counts
([AGENTS.md](../../../AGENTS.md) rule 9):

| what | where |
|---|---|
| **OmniWeb 2.7b3 rendering `http://www.apple.com/` from the corpus, on the NeXTSTEP Workspace, over veth+pcap** | `/data/vms/sandbox/prev-rn/evidence/omniweb-open.png` |
| the same desktop before launch, OmniWeb discoverable in the File Viewer | `/data/vms/sandbox/prev-rn/evidence/B-desktop.png` |
| containment transcript + guard readback + counters | `/data/vms/sandbox/prev-rn/evidence/containment.txt` |

From inside the guest, on the bridge:

```
hostname                     nextstep
ifconfig en0                 inet 10.99.0.25 netmask ffffff00 broadcast 10.99.0.255
netstat -rn                  10.99  10.99.0.25  U  en0        <- and NO default route
ping 10.99.0.2 56 3          3 transmitted, 3 received, 0% loss
ping www.apple.com 56 2      -> 10.99.0.2      <- wildcard DNS: any name is the gateway
ping search.retronet 56 2    -> 10.99.0.2
```

### Containment — the guest reaches the gateway and nothing else

Layered exactly as on irix, so no single failure opens anything:

1. **Topology.** `nextrn0` is enslaved only to `vmbr-rn`, which has
   `bridge-ports none` and no uplink. The netns holds `lo` and the inner veth
   and nothing else, so even a compromised emulator process has no second path.
2. **Routing.** No default route in the guest; labhost's `retronet-fw`
   `RETRONET-FWD` drops anything trying to route *through* the box regardless.
3. **Filter.** `NEXTSTEPRN-IN`, scoped to `10.99.0.25`, above `RETRONET-IN`.
   Read back out of the kernel by `verify_rules`, which refuses to report the
   link up if the rules are not there.

Measured adversarially, probes run detached inside the guest so a hung `telnet`
cannot wedge the exec channel:

```
ping 10.99.0.1 56 3        3 transmitted, 0 received, 100% packet loss
telnet 10.99.0.1 8443      (the gallery)   no output — never connected
telnet 10.99.0.1 22        (labhost sshd)  no output — never connected
telnet 10.99.0.2 80        POSITIVE CONTROL -> "Connected to 10.99.0.2."
NEXTSTEPRN-IN counters     RETURN 29 pkts (replies to labhost-initiated flows)
                           DROP    8 pkts (everything the guest STARTED)
```

The positive control is the part that matters: the guest's TCP demonstrably
works on this bridge, so the two refusals are the filter and not a broken stack.

**What this link does expose, stated plainly:** the other guests on `vmbr-rn`
can address `10.99.0.25`, and what they would find is NeXTSTEP 3.3's telnetd,
ftpd, rshd, rlogind and rexecd, behind a **passwordless `me` and a passwordless
`root`**. That is a wider surface than irix's telnetd-plus-two-Apaches. The
plane is the invited museum's, not the LAN's, and every bridged station makes
this trade — but this one should trim `/etc/inetd.conf` to telnet only before it
ships. See [Not done](#not-done).

## Replaying it

The whole in-guest half is one idempotent script,
[`scripts/build-guests/nextstep/nextstep-retronet-setup.sh`](../../../scripts/build-guests/nextstep/nextstep-retronet-setup.sh),
and the order is not a preference — steps 1 and 2 must happen while the guest is
still on SLIRP, because after step 3 it can only be reached on the bridge:

```bash
S=/data/vms/sandbox/<yours>; R=$S/repo

# 0. the link (outer end enslaved to vmbr-rn only while actively testing)
RN_NS=… RN_VETH_OUT=… RN_VETH_INN=… bash $R/streamhost/stations/nextstep/rn-tapnet.sh up

# 1-2. on SLIRP, through the fixed 127.0.0.1:42323 redirect
NSTEL_HOST=127.0.0.1 NSTEL_PORT=42323 \
  $R/scripts/build-guests/nextstep/nextstep-retronet-setup.sh netinfo   # the boot wedge
NSTEL_HOST=127.0.0.1 NSTEL_PORT=42323 \
  $R/scripts/build-guests/nextstep/nextstep-retronet-setup.sh browser   # needs tinytftpd
NSTEL_HOST=127.0.0.1 NSTEL_PORT=42323 \
  $R/scripts/build-guests/nextstep/nextstep-retronet-setup.sh defaults  # runs as 'me'
NSTEL_HOST=127.0.0.1 NSTEL_PORT=42323 \
  $R/scripts/build-guests/nextstep/nextstep-retronet-setup.sh net       # LAST: static addressing

# 3. halt, flip previous.cfg to pcap, boot on the bridge, verify
NSTEL_HOST=10.99.0.25 NSTEL_PORT=23 \
  $R/scripts/build-guests/nextstep/nextstep-retronet-setup.sh verify
```

`previous.cfg`, the emulator half:

```
[Ethernet]  bEthernetConnected = TRUE   nHostInterface = 1   szInterfaceName = <inner veth>
[ROM]       bUseCustomMac = TRUE   nRomCustomMac2 = 15   nRomCustomMac3 = 82
            nRomCustomMac4 = 78    nRomCustomMac5 = 25          -> 00:00:0f:52:4e:19
```

Disk lineage: a reflink copy of the pristine `NS33.dd`, md5
`b0bd761c09a09d02291bc7f98d3125bd`, with exactly the steps above applied and
nothing else.

## Closed by the host-native cutover (2026-08-25)

Everything the bring-up left open is now done on the LIVE station; the detail
lives in [`../../guests/nextstep.md`](../../guests/nextstep.md).

- **The golden is baked and the station is cut over.** Reset is a CRIU restore,
  ~3 s, framebuffer md5-identical, with the veth dumped as `--external` and the
  pcap socket closed for the freeze (criu cannot dump an `AF_PACKET` fd).
- **The Dock icon is done.** With the tablet driver attached, OmniWeb was
  dragged into the Dock by hand — a paced absolute drag over the control
  socket — and `~/.NeXT/apps3_0.wmd` kept it across a cold boot. The packed
  token stream still has not been reverse engineered and did not need to be.
- **`/NextAdmin/InstallTablet.app` has been run**, and the golden carries the
  driver ATTACHED AND STREAMING. It has to: loading the kernel server from
  `/etc/rc.local` is necessary and not sufficient, so a cold boot still comes up
  dead reckoned.
- **`/etc/inetd.conf` is trimmed to telnet only.** `printer` (lpd) and `smtp`
  (sendmail) start from `/etc/rc`, not inetd, and survive the trim by decision.
- **`www.next.com` (1996-11-12) is in the corpus** and is NOT the home page:
  NeXT's own page of that date is a single image map whose hero JPEG was never
  archived, and it renders empty in OmniWeb. `http://www.apple.com/` (8 May
  1998) renders in full and stays. The NeXT pages one hop down do have their
  images and are reachable by typing.

## Still not done
- **The `RETRONET_DHCP_RESERVATIONS` ledger is missing irix's `10.99.0.24`.**
  This wave added `00:00:0f:52:4e:19=10.99.0.25`; the row before it is
  `…=10.99.0.23`. That is exactly the one-directional drift
  [`WEB-PROXY.md`](WEB-PROXY.md) warns about — an address in a committed
  registry block that the box-side uniqueness ledger cannot see. irix's owner
  should add it.
- **CRIU is now exercised, and the inference from irix was incomplete.**
  `--external veth[nextrn1]:nextrn0` and the `up`-after-restore hook are both
  required and both now measured — but so are two things irix never needed: the
  libpcap `AF_PACKET` socket has to be CLOSED across the freeze (criu answers
  `Can't get 1:16 opt: Operation not supported` on it and aborts), and the shm
  publisher has to be told to republish one whole frame afterwards or the reader
  streams the pre-reset picture forever. Both are fork verbs now — `NETDOWN`/
  `NETUP` and `FBSYNC` — and the launcher sends them on every restore.

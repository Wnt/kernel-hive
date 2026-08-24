# os2warp on the retronet web plane — the bridge as-built

**Status: LIVE.** `os2warp` (IBM OS/2 Warp 4.52 / MCP2, kernel 14.089) is on the
retronet over a **real bridged NIC** on `vmbr-rn`, on **DHCP**, with a **unique
MAC**, and browses the local web corpus in **IBM WebExplorer** — the station's
declared `periodBrowser`, and the only browser actually installed on the image.

This station was the hard one. Unlike win98se/nt4/win2000/win95, os2warp had **no
working TCP/IP stack at all**: the Warp 4.52 upgrade's networking install died
with error 1608 and an earlier gallery pass cleared the wreckage by *removing*
things. Read [`ICQ-STATION.md`](ICQ-STATION.md) for the shared bridge/DHCP/
containment design that this station copies; this doc records what is specific to
os2warp, and it is mostly about the stack repair. The station's **ICQ** half —
ICQ/2 1.503i as UIN `23000` on the legacy v5 door — is
[`ICQ-STATION-os2warp.md`](ICQ-STATION-os2warp.md), which also records why the
full FAT16 root directory noted below now constrains where software can be
installed at all.

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device pcnet,netdev=n0,mac="$RN_OS2WARP_MAC"` (**unchanged device** — `loadvm golden` requires the same device set), backend `-netdev tap,id=n0,ifname=os2rn0,script=no,downscript=no` |
| **MAC** | unique, fleet scheme `52:54:00:52:4e:13`. Real value in gitignored `registry/local.env` as `RN_OS2WARP_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:13` and reads the one line at boot. **Baked by a COLD boot** — `loadvm` restores the MAC from the vmstate regardless of `mac=` |
| Tap | `os2rn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/os2warp/rn-tapnet.sh up`, called from the launcher on every start (chain `OS2RN-IN`, scoped to the guest IP) |
| Guest IP | **DHCP** — `retronet-dhcp` reserves `RN_OS2WARP_MAC -> 10.99.0.19/24`, DNS `10.99.0.2`, **and NO router option**, so the guest never forms a default route |
| Stack | IBM **MPTS/NDIS** (`PROTMAN.OS2` + `MACS\PCNTND.OS2`) + **MPTN TCP/IP** (`SOCKETS.SYS`, `AFOS2.SYS`, `AFINET.SYS`, `IFNDIS.SYS`), DHCP client `DHCPSTRT`/`DHCPCD` |
| Browser | **IBM WebExplorer** `C:\TCPIP\BIN\EXPLORE.EXE`, via the gateway's **proxy door `10.99.0.2:3128`** (it has no `Host:` header — see below). Home page `http://spacejam.com/index.html`, `AutoLoad=Yes` |
| Pointer / exec | warpd agent on a **COM1 unix-socket serial chardev** — *not* on the netdev, so the slirp->tap swap cost nothing on the pointer path. There is no exec channel |
| Launcher | `streamhost/stations/os2warp/qemu-streamhost.sh` (TCG, `-cpu pentium`, `pc-i440fx-11.0,acpi=off,usb=off`, `-vga std -global VGA.vgamem_mb=2`, sb16, 1024x768x64k via IBM GENGRADD) |

## The stack repair — nothing was installed, everything was already there

The headline finding: **no MPTS or TCP/IP media was needed.** The failed 1608
install had already copied every binary onto `C:`; it died before *configuring*
any of it. `C:\TMPT\` and `C:\TMPCOM\` are still on the image — the installer's
own staging dirs, holding the very `SOCKETSK.SYS` / `AFINETK.SYS` that CONFIG.SYS
referenced and that a previous pass concluded "the failed install never
delivered". They were delivered; they were just never moved into place.

`scripts/dev/os2-retronet-stack.sh prep <disk.qcow2>` does the whole repair
offline against the FAT16 `C:` through `qemu-nbd`, inside `chroot-guard
run-private`. It is idempotent and self-verifying (19 checks). What it fixes:

1. **`\IBMCOM\PROTOCOL.INI` bound TCP/IP to the NULL adapter.** `[TCPIP_nif]`
   had `Bindings = NONETADP_nif` — `NULLNDS$`, the "no network adapter"
   placeholder. **This is the actual root cause**; every other symptom is
   downstream. The file is now rewritten wholesale binding `TCPIP_nif ->
   PCNTND_nif` (`DriverName = PCNTND$`, from the CD's `pcntnd.nif`).
2. **CONFIG.SYS pointed at the WSeB "kernel" driver variants** (`SOCKETSK.SYS`,
   `AFINETK.SYS`) which live only in `C:\TMPT\PROTOCOL`. The ordinary client
   variants were in `\MPTN\PROTOCOL` the whole time; the `DEVICE=` lines now
   point at those.
3. **The MAC driver was never in CONFIG.SYS at all** — no
   `DEVICE=C:\IBMCOM\MACS\PCNTND.OS2`, so even a correct PROTOCOL.INI would have
   had nothing to bind to.
4. **The NDIS load order was wrong** — `CALL=NETBIND.EXE` ran ~11 lines *before*
   the MAC and protocol `DEVICE=` lines it is supposed to bind. The whole network
   block is rebuilt in order: MAC, protocols, then NETBIND, then `CNTRL.EXE`,
   then `MPTSTART.CMD`.
5. **`\MPTN\BIN\SETUP.CMD` did not exist** — only the zero-byte template
   `SETUP.$T$`. `MPTSTART.CMD` (already `CALL`ed from CONFIG.SYS) runs `SETUP.CMD`
   when present, and that is where the interface is configured. It now reads
   `ifconfig lo 127.0.0.1` + `dhcpstrt -i lan0 -d 45`.
6. **The search paths were never extended**, so the TCP/IP applications could not
   find their own DLLs. `LIBPATH` gains `C:\TCPIP\DLL` and `C:\IBMI18N\DLL`;
   `NLSPATH` gains `C:\TCPIP\MSG\ENUS850\%N`. See the WebExplorer section.

`\MPTN\ETC\DHCPCD.CFG` needed no change — the stock IBM client config already
requests option 6 (DNS) and 15 (domain) on `interface lan0` with `clientid MAC`.
On lease, `DHCPCD.EXE` writes `%ETC%\RESOLV2` itself.

### IFNDIS.SYS is required here, and that contradicts IBM's documentation

MPTS 6.01's own `readme.mpt` 1.11 says this level *"no longer uses IFNDIS.SYS and
the installation process removes this file"*, and the MCP2 CD ships no copy of
it. **Ignore that here.** This image's `\MPTN\PROTOCOL` carries one and it is
load-bearing: measured both ways on the bring-up rig, dropping the `DEVICE=` line
makes `DHCPCD.EXE` trap at boot with *"DHCPSTRT: DHCP client did not get
parameters"* (there is no `lan0` for `dhcpstrt -i lan0` to bind), while the
otherwise identical config **with** the line leases `10.99.0.19` and writes
`RESOLV2`. Framebuffer and DHCP-server log confirm both directions. Do not "fix"
this line back out on the strength of the readme.

### What is deliberately NOT configured

NetBEUI, NetBIOS and ODI2NDI are **not** loaded and not in PROTOCOL.INI. The
retronet carries IP only, and keeping NetBIOS off the wire is a real containment
win on a bridged 2001-vintage guest. Dropping `ODI2NDI.OS2` (the NetWare
ODI<->NDIS shim) also removed a cold-boot stop: it made the boot halt on
`SYS1718: The system cannot find the file NWCONFIG ... Press Enter to continue`.

## WebExplorer — two independent faults, both needed fixing

### 1. No `Host:` header, so the `:80` origin door can only answer 400

The seamless design the Windows stations use — no proxy, wildcard DNS, the
gateway's `:80` origin picks the site by `Host` — is **structurally unreachable
for this browser**. Captured on the wire with `tcpdump -i os2rn0`:

```
GET /index.html HTTP/1.0
User-Agent: IBM-WebExplorer-DLL/v1.2
-> HTTP/1.0 400 Bad Request
```

WebExplorer 1.2 is a 1996 browser that predates HTTP/1.1 virtual hosting: it
sends **no `Host:` header at all**, so the origin door has nothing to select a
corpus site with. The fix is the gateway's **classic proxy door on
`10.99.0.2:3128`**, where the browser sends absolute-form
`GET http://host/path HTTP/1.0` and the host travels in the request line — what
[`WEB-PROXY.md`](WEB-PROXY.md) calls *"the original web door"*. A proxy-configured
OS/2 desktop is period-correct anyway.

> **This is the one intended deviation from the web-plane brief**, which asked for
> "no proxy configured". It is not a shortcut: the no-proxy path cannot work for
> a browser with no `Host:` header, and the evidence is the 400 above. Note the
> `:80` origin *also* accepts absolute-form requests (verified, 200 OK), so
> `10.99.0.2:80` would work as a proxy address too; `:3128` is used because it is
> the door meant for this.

### 2. No `[viewers]` section, so even `text/html` had no viewer

The `EXPLORE.INI` the failed install left was a 68-byte stub with only an
`[advanced]` section. With no `[viewers]` block, **every** response — including
`text/html` — opened *"There is no viewer registered for this type of file"*
instead of rendering. Both faults had to be fixed; either alone still leaves a
blank browser.

`os2-retronet-stack.sh` now writes the complete `EXPLORE.INI` — `[viewers]`
reproduced verbatim as WebExplorer itself writes it on a clean exit, plus
`Proxy=http://10.99.0.2:3128/`, `EnableProxy=Yes`,
`HomePage=http://spacejam.com/index.html`, `AutoLoad=Yes`, and a 944x700 window
so the desktop stays visible around it. A rebuilt image needs no GUI pass.

Earlier failures worth not re-deriving: `EXPLORE.EXE` first died with
`SYS1804: The system cannot find the file SETLOC1` (it is `C:\IBMI18N\DLL\SETLOC1.DLL`,
simply absent from `LIBPATH`), then with *"Message catalog not found. Check that
'explore.cat' is in NLSPATH"* (it is `C:\TCPIP\MSG\ENUS850\EXPLORE.CAT`). Both are
now path entries, not missing files.

### Why WebExplorer and not Netscape

Because the other two are not actually installed, contrary to what
`docs/guests/os2warp.md` claimed:

- `C:\NETSCAPE` contains **only** a `JAVA11` directory — MCP2's Netscape
  Communicator 4.61 never landed, because it was part of the same failed
  networking install.
- `C:\NSC` is **not** Netscape Navigator. It is IBM's **Network SignOn
  Coordinator** (`NSCPM.EXE`, `NSCNDMN.EXE`, `NSCRSIGN.*`). The "Get Netscape
  Navigator" desktop object is a `WPUrl` promo shadow, not an installed browser.

So WebExplorer is both the period-correct choice for Warp 4 and the only real
one. It is also what `registry/stations/os2warp.json` already declared.

## The desktop icon

The `WebExplorer` shadow was at `ICONPOS=8,22`, which lands **on top of the
system `Programs` folder** in the desktop's left-hand column — clicking there
opened Programs, not the browser. Both web objects moved to the clear band just
under the gallery row (`8,78` and `20,78`), where they read as one obvious
cluster. Changed at the single source,
`scripts/build-guests/assets/os2warp/create-desktop-objects.cmd`, which
`os2-retronet-stack.sh` reinstalls as `C:\STARTUP.CMD` (CRLF-ified) exactly like
the two builders do.

## Containment — the guest reaches the retronet and nothing else

Measured **from inside the guest** on the bring-up rig, on the same disk image
that became the live golden, with the same MAC and reservation:

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (DNS + web) | **3/3 replies, 0% loss** | intra-bridge L2 (the point) |
| `www.spacejam.com` | **resolves to `10.99.0.2`, 2/2 replies** | wildcard DNS via DHCP-supplied resolver |
| labhost bridge `10.99.0.1` | **2 sent, 0 received, 100% loss** | the `OS2RN-IN` guard chain |
| internet `1.1.1.1` (by IP) | **`sendto: Network is unreachable`** | no default route (Lock 1) |

`netstat -r` in the guest shows a single on-link route
(`10.99.0.0 / 255.255.255.0 / lan0`) and **no default entry** — the DHCP
reservation withholds option 3, so the addressing itself keeps the no-WAN
posture. `\MPTN\ETC\RESOLV2` reads `domain retronet.lab` / `nameserver 10.99.0.2`,
written by `DHCPCD.EXE` from the lease, not by hand.

`retronet-fw` runs with `bridge-nf-call-iptables=0`, so guest<->CT traffic is pure
L2 and never touches these chains — the retronet reaching the retronet.

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (ID 1, 247 MiB, 2026-08-23
  14:04) in `/data/gallery-guests/OS2Warp/os2.qcow2`
  (sha256 `ac409758fdcd5eaa5d0bc5daa2980da0394f20f27188b314245b4f73cf5691f7`).
  Tap-native + DHCP + MAC `52:54:00:52:4e:13`, baked by a **cold** boot, captured
  with WebExplorer open on `http://spacejam.com/index.html` and warpd live.
  `labctl reset os2warp` = `loadvm golden`.
- **Full-disk byte-copy backup of the pre-retronet golden** (QEMU stopped,
  SHA256-verified): `/data/gallery-guests/OS2Warp/golden-backup-prern-20260823/`
  — `os2.qcow2` `8696845e21b8b34870a6b6107c70bc2d9c4ca93ce4bdc913766df5b645efad49`,
  with `SHA256SUMS` beside it. This is the rollback for the whole retronet swap.
- Pre-change launcher kept on the box at
  `/data/vms/streamhost/stations/os2warp/qemu-streamhost.sh.pre-retronet-bak`.
- Older backups (`os2.qcow2.GA-640x480-*`, `*.shortcuts-bak-*`, `*.pre-coa.bak`,
  `*.pre-mouse-*`) predate the bridge and are **not** `loadvm`-able on the tap.

**Full rollback**, one block:

```bash
ssh lab 'systemctl stop streamhost@os2warp && \
  cp /data/gallery-guests/OS2Warp/golden-backup-prern-20260823/os2.qcow2 \
     /data/gallery-guests/OS2Warp/os2.qcow2 && \
  cp /data/vms/streamhost/stations/os2warp/qemu-streamhost.sh.pre-retronet-bak \
     /data/vms/streamhost/stations/os2warp/qemu-streamhost.sh && \
  bash /data/vms/streamhost/stations/os2warp/rn-tapnet.sh down && \
  systemctl start streamhost@os2warp'
```

Then revert `registry/stations/os2warp.json`'s `network` block and drop the
`RN_OS2WARP_MAC` reservation from `RETRONET_DHCP_RESERVATIONS` in
`registry/local.env` + `install-dhcp.sh --apply`.

## Gotchas specific to os2warp

- **CONFIG.SYS must stay CRLF.** Writing it LF-only from Linux makes OS/2
  mis-parse every line -> `SYS02068` "unable to operate your hard disk". Every
  write in `os2-retronet-stack.sh` goes through a `crlf()` helper and is asserted
  afterwards.
- **`C:` is FAT16 and its root directory is FULL.** 431 `EA*.CHK` chkdsk husks
  from earlier passes occupy the fixed-size root table, so creating **any** new
  file in `C:\` fails with `ENOSPC` even though the volume has ~1.5 GB free —
  which is why the prep script keeps its backups in `C:\GALLERY\RNBAK\` and never
  beside the original. Pre-existing debt; nothing here adds to it.
- **Do not disturb the video config.** The guest is pinned to IBM **GENGRADD** at
  1024x768x64k (`SET C1=GENGRADD,SBFILTER,VGAGRADD`, `-vga std -global
  VGA.vgamem_mb=2`). Any PMI-based alternative traps `c0000005`. The prep script
  never writes a video line and asserts the GENGRADD line survived.
- **Cold boots re-raise the IBM Software Registration wizard** and open a stray
  EPM `.Untitled` window. Both must be cleared by hand before the recapture
  (`checkpoint-guard recapture` captures the scene exactly as it stands);
  a `loadvm` wake never sees them. (The EPM window's source was not chased — it
  costs one Alt+F4 during a bake. Noted as open.)
- **The golden was captured on a bring-up rig, then promoted**, the same way the
  hi-res and desktop-shortcut passes did it. This is necessary, not preference:
  on the live station the **streamhost daemon holds the warpd COM1 socket**, so
  `warpc.py` cannot connect and there is no `labctl` mouse verb — the live
  station has no agent-driven pointer path. The rig launcher
  (`scripts/dev/os2-retronet-rig.sh`) uses the identical device set; only the
  `-display`/`-audiodev` backends differ, and those are backends, not devices.
- **Idle-pause stalls a hand-driven cold boot.** The station pauses when no
  visitor is connected, freezing the vCPU mid-boot. Hold it awake with a
  momentary connect->`cont`->close loop; **never hold the QMP socket open** —
  this build serves a limited number of concurrent QMP clients and the daemon
  already holds one, so a persistent extra connection makes `labctl shot` and
  input calls fail with `EAGAIN` (`BlockingIOError: Resource temporarily
  unavailable`).
- **Absolute pointer, two transports.** `warpc.py`'s own `C`/`D`/`U` button verbs
  (the agent's fallback path) did not register clicks on the WPS desktop. What
  works is production's own split: warp the position with warpd `M x y`, then
  send the **button** through QMP — `SH_WARPD_BUTTONS=qemu`. Double-click is
  unreliable either way; single-click then Enter opens a WPS object.

## Operating it

```bash
ssh lab 'bash /data/vms/streamhost/stations/os2warp/rn-tapnet.sh show'   # tap + guard chain
ssh lab 'bridge fdb show dev os2rn0'                                     # the baked MAC
ssh lab 'pct exec 951 -- journalctl -u retronet-dhcp | grep 4e:13'       # the lease
ssh lab 'pct exec 951 -- ping -c3 10.99.0.19'                            # guest alive on the retronet
ssh lab 'labctl reset os2warp && sleep 25 && labctl shot os2warp'        # golden restores, browser renders
ssh lab 'bash /data/vms/sandbox/.../repo/scripts/dev/os2-retronet-stack.sh show \
           /data/gallery-guests/OS2Warp/os2.qcow2'                       # current in-guest net config
```

## Open

- The stray EPM `.Untitled` window on cold boot is unexplained (one Alt+F4 during
  a bake). Likely an object in the WPS Startup folder.
- `mailcap` / `extmap` still carry only the single `application/rsu` entry the
  failed install left. Harmless — WebExplorer's `[viewers]` handles the corpus's
  `text/html`, GIF and JPEG internally — but a richer corpus type would need them.
- `spacejam.com/` (no path) serves `index.cgi` first, which WebExplorer has no
  viewer for; the home page is therefore the explicit `/index.html`. That is a
  corpus/proxy content-type quirk, not a station fault.

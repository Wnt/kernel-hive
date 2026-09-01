# win95 web station — the bridge as-built

**Status: LIVE.** `win95` (Windows 95 **OSR2.5**, 4.00.1111) is on the retronet
**web plane** over a real bridged NIC on `vmbr-rn`, on **DHCP**, with the
**warpnet pointer agent re-homed onto the bridge**. Open the station, double-click
**Internet Explorer** on the desktop, and the guest's own **Internet Explorer
4.01** renders the museum corpus — no proxy configured, no live internet
reachable.

This is the win98se pathfinder ([`ICQ-STATION.md`](ICQ-STATION.md)) replicated on
Windows 95 for the web plane ([`WEB-PLANE-PLAN.md`](WEB-PLANE-PLAN.md),
[`WEB-PROXY.md`](WEB-PROXY.md)); read those for the shared design. This doc
records what is **specific to win95**. Messaging is a separate question and is
deferred — [`ICQ-STATION-win95.md`](ICQ-STATION-win95.md).

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device pcnet,netdev=n0,mac="$RN_WIN95_MAC"` (**unchanged device** — `loadvm` requires it; unique MAC, see below), backend `-netdev tap,id=n0,ifname=win95rn0,script=no,downscript=no` |
| **MAC** | unique, per the retronet fleet scheme `52:54:00:52:4e:<last-IP-octet>` (`52:4e`=RN, so `.13`). The real value lives only in gitignored `registry/local.env` `RN_WIN95_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:0d` and reads the one line at boot |
| Tap | `win95rn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/win95/rn-tapnet.sh up` from the launcher on every start (chain `WIN95RN-IN`, scoped to the guest IP) |
| Guest IP | **DHCP** — the guest's TCP/IP was already set to obtain IP *and* DNS automatically, so the swap needed **no in-guest network configuration at all**. `retronet-dhcp` reserves `RN_WIN95_MAC → 10.99.0.13/24`, DNS `10.99.0.2`, **and NO router option** |
| Seamless web | DNS = `10.99.0.2` (via DHCP) + **no proxy anywhere in IE's registry** → any URL resolves to the gateway and its `:80` origin serves the corpus by `Host` |
| Browser | **Internet Explorer 4.01 (4.72.2106.8)**, installed Browser Only from the OEM's own `C:\WIN95\` CAB set — the browser this OSR2.5 image was built to carry. Desktop icon **Internet Explorer** |
| Pointer | **warpd agent `C:\WARPNET.EXE` (guest :7777) reached DIRECTLY over the bridge at `10.99.0.13:7777`** (`SH_WARPD_ADDR`) — was the slirp hostfwd `127.0.0.1:57791`. Motion absolute (`SetCursorPos`), buttons on the PS/2 device (`SH_WARPD_BUTTONS=qemu`) |
| Exec | `C:\WARPX.EXE` (warpnet built `-DWARP_PORT=7788`) at **`10.99.0.13:7788`** (`exec_kind warpd_e`). `labctl exec win95 "<cmd>"` — this station had **no exec channel at all** before |

## The browser: Internet Explorer 4.01, the OEM's own

This is an **OSR2.5** machine — Windows 95 C, registry `VersionNumber`
`4.00.1111` with `SubVersionNumber` `" C"` — and the browser it runs is the one
its own OEM distribution was built to carry: **Internet Explorer 4.01**
(`4.72.2106.8`, files dated 1997-11-18), installed **Browser Only, with no
Windows Desktop Update**.

**The media was already on the disk; nothing was sourced.** `C:\WIN95\`, the
OEM's Windows 95 distribution folder, holds the complete Microsoft IE 4.01 CAB
set — `IE4SETUP.EXE`, `IE4_S1..S6.CAB`, `IE4SHL95.CAB`, `IE4DATA.CAB`,
`IE40CIF.CAB`, `IE4MFC40.CAB`, `IE4SOUND.CAB`, plus `IEJAVA`, `JAVI386`,
`MAILNEWS`, `IR50_32`, `MINI` and the NT-side variants — and the desktop's
*Internet Explorer 4.0 Setup* shortcut points straight at `C:\WIN95\IE4SETUP.EXE`.
It is a **local, offline, vendor-original full install**, not the ~450 KB online
stub, and it needs no internet. That bundle is also the best corroboration that
this image really is 950 C: shipping the Win95 CABs and the IE 4.01 CABs side by
side in one OEM folder is what OSR2.5 *is*.

**Browser Only, and the INI knob that makes it available.** The OEM's
`IE4SETUP.INI` ships `ModeRelation=12` and `Shell_Integration=1`, so the wizard
offers only *Standard* and *Full* and would bring the Windows Desktop Update with
it. Setting `ModeRelation=012` and `Shell_Integration=0` makes the wizard offer
**Browser Only Installation** ("Internet Explorer 4.0 Web browser, and multimedia
enhancements") and drops the Windows Desktop Update page entirely. The OEM INI
was **restored afterwards** and is byte-identical to the original again.

What that bought, and what it cost:

- **The Win95 shell is untouched.** No Active Desktop, no web-view folders, and
  no Quick Launch toolbar — the taskbar is still Start plus the tray, which is
  the visible proof the Desktop Update never landed.
- **`COMCTL32.DLL` stays at 5.80** (577,808 bytes, 1999-04-30). IE 4.01 setup did
  **not** put 4.71 back, so no `50comupd.exe` re-apply was needed. Check it
  before assuming otherwise.
- IE 4.01 installs a **Channel Bar** on the desktop and leaves a resident
  `Iexplore` process running from boot. Both are authentic 1997 furniture and are
  left in place. The resident process is also why an open browser window will not
  close from its own X button or Alt+F4 on this guest.
- The install ends in a reboot it drives itself, and the long file-copy phase
  wedges the S3/VBE display into a striped band — cosmetic, cleared with the
  warpnet **`V`** verb.

**The start page — deliberately pointed back into the corpus.** IE 4.01 setup
repoints the home page at its own `www.microsoft.com/IE/IE401/DOWNLOAD/...`
page, which is **not** archived, so it lands on the museum's *Not in the
Museum's Internet* miss. It was set back to **`http://home.microsoft.com/`**,
which **is** in the corpus (300 pages) and renders as the January 27 1998
*Microsoft Internet Start* — headlines, Lycos search box, Dow/Nasdaq quotes, and
a banner reading *"Internet Explorer 4.0 Is Here"*. So the browser's own **Home**
button lands on a real archived page with nothing else configured, and the page
happens to advertise the very browser now rendering it. The value lives in
`HKCU\...\Internet Explorer\Main\Start Page` (`USER.DAT`), so it survives a
cold boot.

**The desktop icon.** IE 4.01 replaces the old *The Internet* icon with a plain
**Internet Explorer** icon that launches the browser directly. The Internet
Connection Wizard — a dial-up dead end for a visitor — is out of the path
entirely; there is no longer a wizard to complete.

**No proxy, and none needed.** `HKCU\…\Internet Settings` carries no
`ProxyEnable`/`ProxyServer` value. The wildcard DNS at `10.99.0.2` does the work:
any hostname resolves to the gateway and its `:80` origin serves the corpus by
`Host`.

> **Do NOT install Internet Explorer 5.5 SP2 on this station.** It makes the
> golden unfit as an exhibit: a multi-minute first-boot finalization, a
> **network-login prompt on every boot** (the shell and `WIN.INI load=` — hence
> both warpnet agents — only start *after* it), and a modernised desktop. The
> prohibition is absolute and unaffected by the IE 4.01 install. The leftover
> *Internet Explorer 5.5 SP2 Setup* desktop shortcut and `C:\IE55SP2\` are
> inert and are left alone; a visitor who runs one changes nothing durable,
> because the exhibit is `loadvm`-restored.

## The warpnet pointer re-home — the win95-specific complication

Unlike win98se/win2000/nt4 (absolute pointer via usb-tablet/vmmouse), **win95's
pointer is the in-guest warpnet agent** (`streamhost/guest-agents/win9x/warpnet.c`,
`SH_POINTER=warpd`): `usb=off` leaves only a PS/2 *relative* mouse, and Win9x
pointer acceleration makes the daemon's abs→rel homing drift, so an in-guest
Win32 agent `SetCursorPos()`s absolutely over Winsock TCP `:7777`. On slirp it was
reached via a `hostfwd 127.0.0.1:57791 → :7777` **on the same `n0` netdev** the
bridge swap replaces.

Swapping `n0` slirp→tap **removes that hostfwd**, so the pointer path moved onto
the bridge: the daemon dials the agent **directly at `10.99.0.13:7777`**
(`SH_WARPD_ADDR`, `--warpd-addr`, `stream.pointer.agentAddress`,
`operator.labctl.warpd_addr`).

**Two agents, because a client owns the agent exclusively.** `WIN.INI` carries
`load=C:\WARPNET.EXE C:\WARPX.EXE`: the `:7777` **pointer** agent and a second
`-DWARP_PORT=7788` build for **exec**. The `:7777` agent serves ONE connection at
a time and the daemon holds its pointer connection persistently, so anything else
— exec, and any hand-driven bring-up click — must use `:7788`.

**Do not hand-dial `:7777` on a live station.** Since the 2026-08-31 takeover fix
(below) a new connection there does not queue politely in the backlog — it
*evicts the daemon* and the visitor's pointer becomes yours until the daemon's
next write fails and it re-dials. Use `:7788`.

### The serial accept loop was a permanent pointer outage (fixed 2026-08-31)

The agent used to `accept()` one client, `recv()` it until the peer closed, then
accept the next. The daemon (`warpd.rs`) reconnects on ANY write error, and when
the host end of a TCP connection vanishes mid-flight across the tap, **no FIN or
RST reaches the guest**: Winsock keeps the dead socket ESTABLISHED and the agent
blocks in `recv()` on it forever, while the daemon's new connection completes into
the listen backlog and is never accepted. Every `M x y` lands in the guest's
receive buffer and is read by nobody.

The symptom is **pointer MOTION dying alone**. Buttons ride the QEMU PS/2 device
(`SH_WARPD_BUTTONS=qemu`) and keys ride QMP, so both keep working and the station
looks half-alive — the operator reports "the mouse is broken" on a machine that
still types. It is not a drift, an anchor loss, or a wrong-place pointer: the
cursor **never moves at all**, because the bytes are never read.

**The fingerprint, and it is unambiguous.** Compare the two ends of the same link:

```
ssh lab 'ss -tanp | grep ":7777"'          # host: ONE ESTAB
ssh lab 'labctl exec win95 "netstat -an"'  # guest: TWO ESTAB on :7777
```

A guest socket the host has no counterpart for is the orphan wedging the loop.

**The fix** (`streamhost/guest-agents/win9x/warpnet.c`) is a listener takeover:
`serve()` now `select()`s on the listening socket as well as the current client.
The daemon is the only client and holds at most one connection at a time (it
drops the old `TcpStream` before dialling), so a new inbound connection *proves*
the current peer is dead — the agent closes the old socket and serves the new
one. Last writer wins, and a wedge heals on the daemon's next reconnect instead
of lasting until someone reboots the guest. Accepted sockets also get
`SO_KEEPALIVE`, which on Win95's ~2 h default is far too slow to rescue a
visitor but does stop an orphan outliving the station.

Because the agent lives in the golden's RAM image, shipping a new build is an
offline inject plus a **cold** boot plus `checkpoint-guard recapture win95` —
never `loadvm`, which would resurrect the old agent from pre-inject RAM.

## Containment — the guest reaches the retronet and nothing else

Layered locks (topology / no-default-route / per-station `WIN95RN-IN` guard
chain, scoped to `-s 10.99.0.13`, ESTABLISHED-only toward labhost).
`rn-tapnet.sh` is the win98se/nt4 recipe renamed, fail-closed: if it cannot
verify containment it dies and QEMU never starts. Re-proven from inside the guest
on the DHCP lease (`labctl exec win95 "…"`):

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (the `:80` corpus origin + DNS) | **Reply, 0% loss** | intra-bridge L2 (the point) |
| `www.spacejam.com` → `10.99.0.2` | **Resolves + reply** | wildcard DNS (`retronet-dns`), no proxy |
| a corpus miss (`www.microsoft.com/ie/…`) | **the museum's "Not in the Museum's Internet" page** | corpus-only origin; there is no upstream to fall through to |
| labhost bridge `10.99.0.1` | **Request timed out** | the `WIN95RN-IN` guard chain |
| internet `1.1.1.1` (by IP) | **Destination host unreachable** | no default route (Lock 1) |

`route print` in the guest shows **no `0.0.0.0` entry** — the DHCP reservation
withholds option 3, so the addressing itself keeps the no-WAN posture.
`retronet-fw` runs with `bridge-nf-call-iptables=0`, so guest↔CT traffic is pure
L2 and never touches these chains.

## Acceptance — measured through the production `labctl reset` path

`labctl reset win95` (= `loadvm golden`), then, with no other intervention:

- the guest is back on `10.99.0.13`, CT→guest ping **0% loss**;
- **both** agents answer (`:7777` pointer, `:7788` exec), and the daemon holds an
  ESTAB connection to `10.99.0.13:7777`;
- `labctl exec win95 "ver"` → `Windows 95. [Version 4.00.1111]`;
- a **click sent over the bridge** lands on **Internet Explorer**, and **IE 4.01
  renders `home.microsoft.com` from the corpus**.

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (72 MiB, 2026-08-24 05:25) in
  `/data/vms/streamhost/stations/win95/win95-golden.qcow2`. Tap-native + DHCP +
  the `RN_WIN95_MAC` NIC address, both warpnet agents running, **IE 4.01 Browser
  Only installed with the home page pointed at `home.microsoft.com`**, and ICQ
  2002a signed in as UIN `95000` (see [`ICQ-STATION-win95.md`](ICQ-STATION-win95.md)
  for what that does and does not yet do), captured on a clean 1280×1024 frame.
  `labctl reset win95` = `loadvm golden`.
- **Byte-copy backup of that golden** (QEMU stopped, SHA256-verified):
  `/data/gallery-guests/Win95/golden-backup-ie401-icq2002a-20260824/win95-golden.qcow2`
  (`0c9f7c5532abaaa1c7dede54325b2ae4d54cb5c18e57b5ba43747c90a454339a`, +
  `SHA256SUMS` in the dir).
- **Rollback to the pre-IE-4.01 web-only golden** (QEMU stopped, SHA256-verified):
  `/data/gallery-guests/Win95/golden-backup-preicq2001b-20260823/win95-golden.qcow2`
  (`0d86c84431a5faba228f03c9a7af4fb83666ee22860e40190797c3a0eea440a5`). That is
  the IE 3.01, no-ICQ image; restoring it undoes everything on this page's
  browser section in one copy.
- The pristine gallery image `/data/gallery-guests/Win95/win95-osr2-kvm.qcow2` is
  untouched.

**Full rollback** (one command block):

```bash
ssh lab 'systemctl stop streamhost@win95 &&
  cp -a /data/gallery-guests/Win95/golden-backup-preicq2001b-20260823/win95-golden.qcow2 \
        /data/vms/streamhost/stations/win95/win95-golden.qcow2 &&
  bash /data/vms/streamhost/stations/win95/rn-tapnet.sh down'
# then revert the launcher/registry/station.env to the slirp hostfwd form
# (git revert the landing commit) and re-deploy, then: systemctl start streamhost@win95
```

## Gotchas that are win95-specific

- **The MAC is baked by a COLD boot, not `loadvm`.** To change it: back the
  golden up, apply the DHCP reservation for the NEW mac first, revert to golden
  (`qemu-img snapshot -a golden`), **delete** it (`qemu-img snapshot -d golden`)
  so the launcher cold-boots, boot with the new `mac=`, do the in-guest work,
  recapture. Verify in the bridge FDB (`bridge fdb show dev win95rn0`), in QMP
  `info network`, **and** in the DHCP log (`journalctl -u retronet-dhcp` in CT 951
  → an `ACK 10.99.0.13` for `RN_WIN95_MAC`).
- **Rebuild the golden via COLD QEMU boots only.** A Windows-initiated *warm*
  restart wedges the display on this station.
- **The shutdown screen is garbled and the next boot runs ScanDisk.** Win95's
  "It's now safe to turn off" leaves the S3/VBE miniport in a wrong short mode, so
  the final frame is a striped mess and the shutdown is not recorded clean. It is
  cosmetic: ScanDisk completes and boots through. The exhibit golden is
  `loadvm`-restored and never cold-boots, so visitors never see it.
- **Recover a wedged display over the wire** with the warpnet **`V`** verb →
  `ChangeDisplaySettings(CDS_RESET)`. Always `labctl shot` a clean, full-resolution
  frame **before** any `savevm`.
- **The station idle-pauses (vCPU frozen) with no visitor connected**, which makes
  a bring-up look hung and stalls long unattended steps. Hold it awake with a
  **momentary** QMP connect→`cont`→close loop; never hold the QMP socket open —
  this build serves a limited number of concurrent QMP clients and the daemon
  already holds one, so a persistent extra connection makes `labctl shot` fail.
- **`labctl key` chords do not reach this guest**; single keys do. Send chords
  (`ctrl-esc`, `alt-f4`, `alt-f`, `shift-end`) through QMP `sendkey` instead.
- **Deliver a file in-guest over the bridge.** The guest reaches only the gateway
  CT, so serve the blob from CT 951 (`pct push`, then `systemd-run --unit=… python3
  -m http.server <port> --directory /tmp`) and fetch it with **Start ▸ Run ▸
  `iexplore http://10.99.0.2:<port>/<file>`** ▸ *Save it to disk* ▸ type the full
  target path in the Save As **File name** box. Remove the CT server and the blob
  afterwards.

## Operating it

```bash
ssh lab 'labctl exec win95 "ver"'                                        # exec over the bridge (WARPX :7788)
ssh lab 'labctl exec win95 "route print"'                                # no default route == contained
ssh lab 'bash /data/vms/streamhost/stations/win95/rn-tapnet.sh show'     # tap + guard chain
ssh lab 'printf "V\n" | nc 10.99.0.13 7788'                              # un-wedge the display over the bridge
ssh lab 'labctl reset win95'                                             # loadvm golden
```

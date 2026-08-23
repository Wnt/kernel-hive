# win95 web station — the bridge as-built

**Status: LIVE.** `win95` (Windows 95 OSR2.5, 4.00.1111) is on the retronet
**web plane** over a real bridged NIC on `vmbr-rn`, on **DHCP**, with the
**warpnet pointer agent re-homed onto the bridge**. Open the station, double-click
**The Internet** on the desktop, and the guest's own **Internet Explorer 3.01**
renders the museum corpus — no proxy configured, no live internet reachable.

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
| Browser | **Internet Explorer 3.01 (build 1158)**, the stock OSR2 browser already in the golden. Desktop icon **The Internet** |
| Pointer | **warpd agent `C:\WARPNET.EXE` (guest :7777) reached DIRECTLY over the bridge at `10.99.0.13:7777`** (`SH_WARPD_ADDR`) — was the slirp hostfwd `127.0.0.1:57791`. Motion absolute (`SetCursorPos`), buttons on the PS/2 device (`SH_WARPD_BUTTONS=qemu`) |
| Exec | `C:\WARPX.EXE` (warpnet built `-DWARP_PORT=7788`) at **`10.99.0.13:7788`** (`exec_kind warpd_e`). `labctl exec win95 "<cmd>"` — this station had **no exec channel at all** before |

## The browser: IE 3.01, installed nothing

The one open decision on this station was *which browser*. The answer is that the
clean golden already has one, and it is enough.

- `C:\Program Files\Internet Explorer\IEXPLORE.EXE` is dated **1996-08-24**;
  `HKLM\Software\Microsoft\Internet Explorer` reads `IVer`=`103`, `Build`=`1158`
  — **IE 3.01**. Its UA is `Mozilla/2.0 (compatible; MSIE 3.01; Windows 95)`.
- **No proxy is configured and none is needed.** `HKCU\…\Internet Settings` has
  no `ProxyEnable`/`ProxyServer` value at all. The wildcard DNS does the work.
- IE 3.01's shipped start page is `http://home.microsoft.com/`, and that host
  **is in the corpus** (300 pages). So the browser's own default lands on a real
  archived page with nothing configured — the Home button works too.
- **Nothing was installed.** No IE 4.01, and emphatically **no IE 5.5 SP2** — the
  earlier ICQ pass proved IE5.5 compromises the golden (multi-minute first-boot
  finalization, a network-login prompt every boot, a modernised desktop). Winsock 2
  and comctl32 5.80 were not needed either: IE 3.01 runs on stock Winsock 1.1.

**The one real trap, and the fix.** Out of the box the **The Internet** desktop
icon does *not* open the browser — it opens the **Internet Connection Wizard**
("Get Connected!"), which is a dial-up setup wizard and a dead end for a visitor.
The wizard was completed once, choosing **Setup Options → Current** ("uses your
current Internet settings … if you already have a connection to the Internet"),
which is the truthful answer for a guest already on the bridge. That choice is
baked into the golden: **the icon now launches IE straight onto the corpus.**
This is the authentic 1996 fix — the wizard is a once-per-machine step, not
something to route around with an extra shortcut, so the desktop keeps its
period-correct icon set.

Two installer shortcuts (`Internet Explorer 4.0 Setup`, `Internet Explorer 5.5
SP2 Setup`) and `C:\IE55SP2\` were already on the golden before this pass and are
left alone. A visitor who runs one changes nothing durable — the exhibit is
`loadvm`-restored — but the operator may want them tidied some day.

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

**Two agents, because the accept loop is serial.** `WIN.INI` carries
`load=C:\WARPNET.EXE C:\WARPX.EXE`: the `:7777` **pointer** agent (the golden's
existing one, untouched) and a second `-DWARP_PORT=7788` build for **exec**. The
`:7777` agent accepts one connection at a time and the daemon holds its pointer
connection persistently, so anything else — exec, and any hand-driven bring-up
click — must use `:7788`. Expect a hand-rolled `nc 10.99.0.13 7777` to connect
and then do nothing: it is sitting in the backlog behind the daemon.

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
- a **click sent over the bridge** lands on **The Internet**, and **IE 3.01
  renders `home.microsoft.com` from the corpus**.

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (57.7 MiB, 2026-08-23 13:01) in
  `/data/vms/streamhost/stations/win95/win95-golden.qcow2`. Tap-native + DHCP +
  the `RN_WIN95_MAC` NIC address, both warpnet agents running, the Connection Wizard
  already completed, captured on a clean 1280×1024 frame. `labctl reset win95` =
  `loadvm golden`.
- **Pre-swap byte-copy backup** (QEMU stopped, SHA256-verified):
  `/data/gallery-guests/Win95/golden-backup-rnweb-win95-20260823/win95-golden.qcow2`
  (`4eb97bac2b36cf05fce009300915304588ee95be74ea9460c7da7cd0dbffa478`, +
  `SHA256SUMS` in the dir). It hashes **identical** to the earlier
  `golden-backup-retronet-win95-20260821/` copy, which confirms the live golden
  really was the clean pre-retronet one.
- The pristine gallery image `/data/gallery-guests/Win95/win95-osr2-kvm.qcow2` is
  untouched.

**Full rollback** (one command block):

```bash
ssh lab 'systemctl stop streamhost@win95 &&
  cp -a /data/gallery-guests/Win95/golden-backup-rnweb-win95-20260823/win95-golden.qcow2 \
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

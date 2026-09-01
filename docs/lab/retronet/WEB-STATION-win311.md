# win311 web station — the bridge as-built

**Status: LIVE.** `win311` (Windows for Workgroups 3.11, VMID 90) is on the
retronet **web plane** over a real bridged NIC on `vmbr-rn`, on **DHCP**, with a
**unique MAC**, and browses the museum corpus in **Netscape Navigator 4.08
(16-bit)** — no proxy configured, no live internet reachable. Open the station,
run Netscape from the Internet group, and `home.netscape.com` (July 9 1997)
renders from the corpus.

This is the win98se/win95 pattern ([`ICQ-STATION.md`](ICQ-STATION.md),
[`WEB-STATION-win95.md`](WEB-STATION-win95.md)) replicated on WfW 3.11; read
[`WEB-PROXY.md`](WEB-PROXY.md) for the shared addressing plane. This doc records
what is specific to win311. The station's freeze-fix history —
[`docs/lab/win311-interrupts-disabled-freeze.md`](../win311-interrupts-disabled-freeze.md)
— matters here, because the fix's ROM bytes live in the vmstate and the join
required a cold re-bake (see §The golden).

## The headline finding: everything was already on the disk

The task brief assumed win311 had no network device and no stack. Neither was
true, and **no install media was sourced**:

- The launcher already carried `-nic user,ipv6=off,model=ne2k_pci` — the NIC was
  in the golden's device set all along, leasing a slirp `10.0.2.15` it had
  nothing to talk to.
- The guest (an image with a donor-PC history on a `192.168.178.0/24` home LAN —
  `[Network] Comment=Jaap & Jol`) already runs **Microsoft TCP/IP-32** bound to
  the **RTL8029 NDIS3 driver** (`PROTOCOL.INI`: `netcard=RTL8029` /
  `DriverName=PCIND$`, `transport=tcpip-32r`; SYSTEM.INI `[386Enh]`
  `netcard=PCIND.386`, `transport=…vdhcp.386,vtcp.386,vnbt.386`). QEMU's
  `ne2k_pci` **is** an RTL8029 — the in-guest driver matches the emulated card
  exactly, which decided the NIC-model question by evidence: nothing to install,
  nothing to rebind.
- **DHCP was already enabled** (`[RTL80290] IPAddress=0.0.0.0`, `vdhcp.386`
  loaded).
- The browser shelf was preloaded: Netscape Communicator/Navigator **4.08
  16-bit** (`C:\Netscape\Comm`), Navigator Gold 3 (`C:\NETSCAPE`), IE3
  (`C:\IEXPLORE`), IE5 for 3.1x (`C:\IE5`), NCSA Mosaic 2.1 (`C:\MOSAIC`),
  WS_FTP, Forte Agent, AIM.

So the join was: backend swap (slirp→tap) + unique MAC + three offline INI edits
+ a cold re-bake. `scripts/dev/win311-retronet-stack.sh` (idempotent,
self-verifying, CRLF-preserving) is the whole in-guest prep:

1. `SYSTEM.INI [RTL80290] DefaultGateway=192.168.178.1` → empty (Lock 1 belt).
2. `SYSTEM.INI [DNS] DNSServers=` → `10.99.0.2`, `DomainName=` → `retronet.lab`
   (TCP/IP-32 prefers static `[DNS]` entries over the lease).
3. Home pages onto corpus-archived sites: Netscape 4.08 `prefs.js`
   `browser.startup.homepage` → `http://home.netscape.com/`; Navigator Gold's
   `NETSCAPE.INI` the same; IE3's `IEXPLORE.INI` → `http://home.microsoft.com/`.

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device ne2k_pci,netdev=n0,mac="$RN_WIN311_MAC"` — same RTL8029-class device the golden always had; backend `-netdev tap,id=n0,ifname=win311rn0,script=no,downscript=no` (was `-nic user`) |
| **MAC** | unique, fleet scheme `52:54:00:52:4e:1b` (`.27`). Real value in gitignored `registry/local.env` `RN_WIN311_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:1b` and reads the one line at boot. **Baked by the cold re-bake** — `loadvm` restores the MAC from the vmstate regardless of `mac=` |
| Tap | `win311rn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/win311/rn-tapnet.sh up` from the launcher on every start (chain `WIN311RN-IN`, scoped to the guest IP) |
| Guest IP | **DHCP** — `retronet-dhcp` reserves `RN_WIN311_MAC → 10.99.0.27/24`, DNS `10.99.0.2`, **NO router option**. Proven in-guest: `ipconfig /all` shows the MAC, the lease, DNS `10.99.0.2` and an **empty Default Gateway** |
| Stack | MS TCP/IP-32 (wolverine) over RTL8029 NDIS3 (`PCIND$`), DHCP client `vdhcp.386` — all pre-existing |
| Browser | **Netscape Navigator 4.08 (16-bit)**, `C:\Netscape\Comm\Program\netscape.exe`, home `http://home.netscape.com/`, **no proxy** — the wildcard DNS + `:80` origin serve the corpus by `Host` |
| Pointer / exec | warpd agent (`AGENT.EXE`) on the **COM1 unix-socket serial chardev** — *not* on the netdev, so the swap cost the pointer nothing. Verified live after restore (warpd `M` verbs move the cursor). There is no exec channel |
| Launcher | `streamhost/stations/win311/qemu-streamhost.sh` (TCG, `-cpu pentium`, `pc-i440fx-11.0`, patched SeaBIOS, `-vga std`, sb16, two golden qcow2s) |

## The golden — cold re-bake, and how the SeaBIOS fix was kept

The MAC lives in the ne2k vmstate, and the old golden's lease was slirp's
`10.0.2.15`, so the join required a **cold boot on the bridge** and a fresh
`savevm golden` — which is exactly the operation that can silently lose the
INT16h freeze fix, because the patched ROM's bytes live in the vmstate too.

Kept, and proven, three ways:

1. The launcher (and the rig, `scripts/dev/win311-retronet-rig.sh`, same device
   set, `-display none`) passes `-bios
   /data/vms/streamhost/firmware/bios-256k-int16if.bin` **unconditionally** and
   refuses to start without the file — a cold boot cannot boot the stock ROM.
2. The bake boot's `/proc/<pid>/cmdline` was read back:
   `-bios /data/vms/streamhost/firmware/bios-256k-int16if.bin`.
3. The functional probe from the freeze doc ran on the very boot that was baked:
   `input-wedge-repro/irqprobe.py --launch` — **survived 366 SkiFree key edges,
   `wedged=False` every round** (stock ROM wedged at 61).

Bake recipe (reproducible): copy the live goldens to the rig dir, `qemu-img
snapshot -a golden && -d golden` both disks, `win311-retronet-stack.sh prep` the
boot disk, `COLD=1 win311-retronet-rig.sh`, wait for the desktop, verify (lease,
containment, browser, probe), re-create the scene (Gallery Games group front,
Minesweeper selected — the registry note about a maximized Notepad fixture
predates the live scene), `savevm golden` over QMP.

**Restore-proven twice** before promotion: two kill/relaunch cycles on
`-loadvm golden`; after each the guest answered at `10.99.0.27` in seconds with
**no re-DHCP**, the warpd cursor moved, and (cycle 2) Netscape rendered
`home.netscape.com` to *Document: Done*.

## Containment — proven from inside the guest (`10.99.0.27`)

| From the guest to… | Result | Lock |
|---|---|---|
| gateway CT `10.99.0.2` | **4/4 replies, TTL=64** | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` | **4/4 `Request timed out`** | the `WIN311RN-IN` guard chain |
| internet `1.1.1.1` | **`Destination host unreachable`** | no default route (Lock 1) |

`route print` in the guest shows loopback, on-link `10.99.0.0/24`, broadcast and
multicast — **no `0.0.0.0` default entry**. The DHCP reservation withholds
option 3 and the static `DefaultGateway` was cleared, so the addressing itself
keeps the no-WAN posture.

Note the guest still runs WfW file/print sharing (`vserver.386`) and NBT on the
bridge. That is period furniture visible only to the retronet (the bridge has no
uplink and the guard chain screens labhost); NetBEUI is not loaded — only
`ms$ndishlp` and TCP/IP are bound.

## The IM plane — DONE, and it is AIM, not ICQ

**Superseded 2026-09-01.** This section used to record ICQ as assessed-and-
deferred, and guessed that the preinstalled AIM client would want the gateway's
TOC door (`:9898`). Both guesses are now retired by measurement:

- The preinstalled client is **Netscape AOL Instant Messenger 1.0.414**, a plain
  **OSCAR** client (`OSCARUI.DLL`, `OSCORE.DLL`, `OSCLOGIN.OCM`), talking to
  `10.99.0.2:5190` like everything else. TOC is not used.
- Its `AIM.INI` shipped pointing at `login.oscar.aol.com`, which the retronet's
  wildcard DNS already resolves to the gateway — so it could reach our OSCAR
  service with **no configuration at all**, which is how this started.
- No Win16 ICQ client was needed or sourced.

What it did need was a bridge, because AIM and ICQ clients cannot name each
other: AIM refuses an all-numeric screen name and ICQ 2001b silently drops a
message from a non-numeric sender. The full account, the design, and the
acceptance evidence are in
[`ICQ-STATION-win311.md`](ICQ-STATION-win311.md). The transport described in
this document was sufficient as-built and **nothing about it changed**.

## Golden lineage & rollback (FULL paths)

- **LIVE golden (2026-08-25):** internal snapshot `golden` in
  `/data/vms/streamhost/stations/win311/{win311-golden.qcow2,games-golden.qcow2}`
  — tap-native, MAC `52:54:00:52:4e:1b` baked, lease `10.99.0.27` baked,
  Netscape homepage set, patched-BIOS vmstate, probe-clean.
- **Pre-retronet backup (the rollback for this whole change):**
  `/data/vms/streamhost/stations/win311/{win311-golden.qcow2,games-golden.qcow2,qemu-streamhost.sh}.bak-prern-20260825`
  + `SHA256SUMS.prern-20260825` beside them. Rollback = stop
  `streamhost@win311`, restore those three over the live files,
  `rn-tapnet.sh down`, drop the `52:54:00:52:4e:1b` reservation from
  `RETRONET_DHCP_RESERVATIONS` in `registry/local.env` +
  `install-dhcp.sh --apply`, revert the registry entry, start.
- Older backups (`*.bak-stockbios-20260817T161217Z`, `*.bak-cirrus-20260727*`)
  predate the INT16h fix and/or the vbesvga display and are **not** rollback
  targets for this change.

## Gotchas specific to win311

- **NCSA Mosaic cannot use the seamless web** — it predates the `Host:` header
  (same class of fault as os2warp's WebExplorer). It is left as period
  furniture; its home page is un-archived NCSA. A proxy-form fix would need
  Mosaic's proxy INI keys — deliberately not done, Netscape is the exhibit.
- **IE5's own start page was not touched** (it keeps its registry-style config);
  IE3's `IEXPLORE.INI` points at the corpus. Any URL a visitor types still
  resolves — un-archived hosts get the period miss page.
- **The `qmp-type.py` text path eats bare backslashes** (`unicode_escape`);
  type guest paths as `C:\\\\dir\\\\file` when driving installs.
- The savevm scene note in `station.env.fixture` used to describe a maximized
  Notepad; the live scene since the 2026-08-17 re-bake is the Program Manager +
  Gallery Games desktop, and this bake reproduces that.

## Operating it

```bash
ssh lab 'bash /data/vms/streamhost/stations/win311/rn-tapnet.sh show'   # tap + guard chain
ssh lab 'bridge fdb show dev win311rn0'                                 # the baked MAC
ssh lab 'pct exec 951 -- journalctl -u retronet-dhcp | grep 4e:1b'      # the lease
ssh lab 'ping -c3 10.99.0.27'                                           # guest alive on the bridge
ssh lab 'labctl reset win311 && sleep 10 && labctl shot win311'         # golden restores to the desktop
bash scripts/dev/win311-retronet-stack.sh show /data/vms/sandbox/<ns>/rig/win311-golden.qcow2   # in-guest net config (offline copy)
```

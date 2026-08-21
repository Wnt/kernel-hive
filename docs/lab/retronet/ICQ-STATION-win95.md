# win95 ICQ station — the bridge as-built

**Status: BRING-UP (client-blocked).** `win95` (Windows 95 OSR2.5, 4.00.950 C)
is wired onto the retronet OSCAR gateway over a **real bridged NIC** on
`vmbr-rn`, with the **warpnet pointer agent re-homed onto the bridge** — the
win95-specific complication this station exists to solve. The bridge swap, unique
MAC bake, containment, exec channel and pointer re-home are **done and proven**;
the ICQ 2000b **client login is blocked** by a deep Win95 runtime-dependency gap
(see [§The ICQ client blocker](#the-icq-client-blocker)). This is the win98se
pathfinder ([`ICQ-STATION.md`](ICQ-STATION.md)) replicated on Windows 95; read
that first for the shared design. This doc records only what is **different** on
win95, and the blocker.

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device pcnet,netdev=n0,mac=$RN_WIN95_MAC` (**unchanged device**; unique MAC — see below), backend `-netdev tap,id=n0,ifname=win95rn0,script=no,downscript=no` |
| Tap | `win95rn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/win95/rn-tapnet.sh up` from the launcher on every start (chain `WIN95RN-IN`) |
| Guest IP | **static `10.99.0.13/24`, NO default route, DNS `10.99.0.2`** — contained by design (Lock 1). DNS points at the gateway's `retronet-dns` (Win9x resolver needs a server configured; matches win98se) |
| OSCAR server | gateway CT `10.99.0.2:5190` (the one `RN` door) |
| Persona / bot | UIN `95000` (win95) / UIN `10000` (**HiveBot**); passwords in `registry/local.env` `RETRONET_ICQ_WIN95_PASS` / `_BOT_PASS` |
| ICQ client | ICQ 2000b (`C:\Program Files\ICQ\Icq.exe`), `DefaultPrefs` **`Default Server Host`**=`10.99.0.2` (REG_SZ) **`Default Server Port`**=`dword:00001446` (=5190) |
| Pointer | **warpd agent `C:\WARPNET.EXE` (guest :7777) reached DIRECTLY over the bridge at `10.99.0.13:7777`** (`SH_WARPD_ADDR`) — was the slirp hostfwd `127.0.0.1:57791`. Motion absolute (SetCursorPos), buttons on the PS/2 device (`SH_WARPD_BUTTONS=qemu`) |
| Exec | `C:\WARPX.EXE` (warpnet built `-DWARP_PORT=7788`) at **`10.99.0.13:7788` over the bridge** (`exec_kind warpd_e`). A SECOND warpnet build because the :7777 pointer agent's serial accept loop is monopolised by the daemon's persistent pointer connection |
| RAM | **256 MB** (already the golden's size) |

## The warpnet pointer re-home — the win95-specific complication (PROVEN)

Unlike win98se/win2000/nt4 (absolute pointer via usb-tablet/vmmouse), **win95's
pointer is the in-guest warpnet agent** (`streamhost/guest-agents/win9x/warpnet.c`,
`SH_POINTER=warpd`): `usb=off` leaves only a PS/2 *relative* mouse, and Win9x
pointer acceleration makes the daemon's abs→rel homing drift, so an in-guest
Win32 agent `SetCursorPos()`s absolutely over Winsock TCP `:7777`. On slirp it was
reached via a `hostfwd 127.0.0.1:57791 → :7777` **on the same `n0` netdev** that
carried nothing else.

Swapping `n0` slirp→tap **removes that hostfwd**, so the pointer path had to move
onto the bridge exactly like win98se/win2000 moved the *exec* channel: the daemon
now dials the agent **directly at the guest's bridge IP `10.99.0.13:7777`**
(`SH_WARPD_ADDR`, `--warpd-addr`, `stream.pointer.agentAddress`, `operator.labctl.warpd_addr`).

**Proven:** cold-booted tap-native, the pointer agent answers at `10.99.0.13:7777`
over the bridge, and a click lands where expected on the framebuffer — clicking
Notepad's `Search` menu opened it precisely at the click point. Motion snaps 1:1;
buttons ride the real PS/2 device (`SH_WARPD_BUTTONS=qemu`, unchanged).

Two warpnet agents run in the guest, both autostarted from `WIN.INI` `load=`
(`load=C:\WARPNET.EXE C:\WARPX.EXE`): the `:7777` **pointer** agent (the golden's
existing one, untouched) and a second `-DWARP_PORT=7788` build `C:\WARPX.EXE` for
the **exec** channel. Exec needs its own port because the pointer agent's accept
loop is serial and the daemon holds its connection persistently.

## Unique MAC — baked cold (PROVEN)

`RN_WIN95_MAC = 52:54:00:52:4e:0d` (fleet scheme `52:54:00:52:4e:<last-IP-octet>`,
`.13`→`…0d`; real value in gitignored `registry/local.env`, placeholder
`02:00:00:00:00:0d` in the launcher). The MAC lives in the golden vmstate, so it
is baked by a **cold boot** on the tap. Verified: `info network` shows
`pcnet.0 macaddr=52:54:00:52:4e:0d`, and the vmbr-rn FDB learns it on `win95rn0`.

## Containment — proven the win98se way

Layered locks (topology / no-default-route / per-station `WIN95RN-IN` guard chain,
scoped to `-s 10.99.0.13`, ESTABLISHED-only toward labhost). `rn-tapnet.sh` is a
byte-for-byte adaptation of win98se/nt4's (renamed `win95rn0`, `10.99.0.13`,
`WIN95RN-IN`), fail-closed. Proven: gateway `10.99.0.2` ↔ guest is pure L2
(bridge-nf-call-iptables=0), ping both ways 0% loss; the guest has **no default
route** (winipcfg shows an empty gateway), so off-subnet is unreachable; the guard
chain drops NEW guest→labhost (gallery `10.99.0.1:8443` closed).

## win95 needed the modern ICQ-2000b runtime that Win98SE ships built-in

This is the load-bearing win95 finding. **Bare Win95 OSR2.5 lacks the runtime ICQ
2000b (a 2000-era client) assumes.** win98se/win2000/nt4 ship it; Win95 does not.
Each prerequisite was sourced from the lab's archival sources, verified, and
installed offline (media in [`ASSETS-MANIFEST.md`](../ASSETS-MANIFEST.md)):

1. **Common Controls 5.80 — `50comupd.exe`** (`e70f9945…`, MS Wayback capture of
   `download.microsoft.com/…/platformsdk/Comctl32/5.80.2614.3600/W9XNT4/EN-US/`).
   Without it the ICQ installer aborts: *"The operating file 50comupd.exe (x86) is
   required to install ICQ."* After it, ICQ 2000b installs cleanly.
2. **Winsock 2 — `w95ws2setup.exe`** (`48c82825…` / sha1 `79912f04…`,
   `archive.org/details/w95ws2setup`). Base Win95 has only Winsock 1.1 (wsock32.dll);
   ICQ 2000b needs `ws2_32.dll`. Silent install, adds ws2_32/mswsock/ws2help/ws2thk.
3. **DCOM95 1.3 — `C:\IE55SP2\DCOM95.EXE`** (staged on the golden).
4. **Internet Explorer 5.5 SP2** (the full offline installer staged at
   `C:\IE55SP2\`, 78 CABs) — for the WinInet/urlmon runtime ICQ's startup pulls in.

Recovery of the display after any `COMMAND.COM` VDM / mode-change wedge: the
warpnet `V` verb (`ChangeDisplaySettings(NULL, CDS_RESET)`); a Windows-initiated
*warm* restart tends to wedge the display, so bring-up rebuilds the golden via
**cold** QEMU boots (a clean guest shutdown then a fresh `qemu-system-x86_64`),
never a warm reboot.

## The ICQ client blocker

**The ICQ 2000b client never initiates its OSCAR connection on this bare Win95.**
Driven to *Existing User → UIN 95000 → Next* (and, separately, *New ICQ#*), the
client sits at "**Registering User**" and emits **zero** packets toward the
gateway — no SYN to `10.99.0.2:5190`, no DNS query, no ARP beyond the ambient OS
NetBIOS. `tcpdump -ni win95rn0 ether host 52:54:00:52:4e:0d and host 10.99.0.2`
captures nothing; the gateway's `/session` never shows `95000`.

This is **not** network, config, or credentials — all independently proven:

- **L2 works both ways:** gateway `10.99.0.2` ↔ guest `10.99.0.13` ping, 0% loss.
- **Guest outbound TCP works:** IE reaches the gateway's `:80` corpus (the
  "retronet proxy — Not in the Museum's Internet" page renders) directly by IP.
- **DefaultPrefs is right:** regedit confirms
  `HKCU\Software\Mirabilis\ICQ\DefaultPrefs` "Default Server Host"=`10.99.0.2`,
  "Default Server Port"=`dword:00001446` (5190).
- **The persona authenticates:** `rn-tool.py login 10.99.0.2 5190 95000 <pass>`
  succeeds, BOS advertised `10.99.0.2:5190`, 256-byte auth cookie.

So the failure is **inside the client's connection thread** — it never reaches
`connect()`. The obvious cause was the modern runtime a 2000-era client assumes,
so the FULL win98se-equivalent stack was installed: **comctl32 5.80 → Winsock 2 →
DCOM95 → IE5.5 SP2**. The `0-packet` symptom was identical after each (the OSCAR
socket is raw Winsock2, architecturally independent of IE's WinInet). The runtime
theory is **exhausted**.

**Compounding it, the full IE5.5 SP2 install compromises the museum golden**: a
multi-minute first-boot finalization ("setting up Browsing Services / Internet
Tools / Security / System Services"), a network-**login prompt on every boot**
(the shell/`WIN.INI load=` — hence both warpnet agents — only start after it), and
a modernised desktop (IE5.5 shell, Outlook Express, Media Player). Even a working
ICQ would leave a golden unfit as an instant-restore museum exhibit.

**State left:** the live win95 exhibit was **rolled back** to its pre-retronet
golden (below). The bring-up disk with every prerequisite installed is preserved
at `/data/gallery-guests/Win95/win95-golden-retronet-wip-20260821.qcow2` so a
retry need not repeat the installs. The repo infra (launcher tap-swap, pointer
re-home, `rn-tapnet.sh`, `win95-icq-nudge`, registry, box-sync, this doc) is
committed on branch `rn-win95` but **not merged/deployed** — it goes live only
once the client blocker is resolved.

**Recommended next steps (operator's call):** (a) build the win95 golden the
win98se way — a base with IE + ICQ **pre-installed and pre-configured** (not a
bare OSR2.5 golden retrofitted), so ICQ's runtime is native and the desktop stays
period-clean; or (b) further **client-side** debugging on the preserved WIP disk —
ICQ 2000b's own Preferences → Connections proxy/firewall setting, a clean ICQ
reinstall, or diffing the working **win98se** ICQ registry against win95's; or
(c) defer win95 (the pointer re-home + MAC + containment + infra are done and
reusable). The pointer re-home — the win95-specific complication this station was
about — is **proven**.

## Golden lineage & rollback (FULL paths)

- **Pre-retronet golden backup** (byte-copy, SHA256-verified, QEMU stopped):
  `/data/gallery-guests/Win95/golden-backup-retronet-win95-20260821/win95-golden.qcow2`
  (`4eb97bac…`, holds the slirp-era internal snapshot `golden`) — restored over
  the tile-local `win95-golden.qcow2` to bring the live exhibit back. The pristine
  gallery image `/data/gallery-guests/Win95/win95-osr2-kvm.qcow2` is untouched.
- **Bring-up WIP** (comctl32 5.80 + Winsock 2 + DCOM95 + IE5.5 SP2 + ICQ 2000b
  installed, static `10.99.0.13`/DNS, warpnet pointer+exec agents baked, NO golden
  snapshot): `/data/gallery-guests/Win95/win95-golden-retronet-wip-20260821.qcow2`.
- Live golden: `/data/vms/streamhost/stations/win95/win95-golden.qcow2`.

## Operating it

```bash
ssh lab 'bash /data/vms/streamhost/stations/win95/rn-tapnet.sh show'   # tap + guard chain
ssh lab 'printf "V\n" | nc 10.99.0.13 7777'                            # un-wedge the display over the bridge
ssh lab 'labctl exec win95 "ver"'                                      # exec over the bridge (WARPX :7788)
```

# Kernel Hive — verified install-media & boot-recipe catalog

A **verified installation-media + boot-recipe catalog** for candidate operating
systems that could join the OS gallery. The current roster is registry-derived;
`python3 scripts/stations-registry.py count` currently reports **39 lineup entries:
37 production streamhost tiles and 2 showcase posters**. For each candidate OS it records
**where the install media lives**, its **licensing posture**, the **format**,
whether a **ROM** is needed, an approximate **size**, an **effort/feasibility/
museum-value** score, the exact **boot recipe** (QEMU flags or emulator command),
and the **gotchas** — the URLs and boot commands are the point of this document.

## How it was produced

Research done **2026-07-08** by a fan-out of 11 parallel agents (10 OS-family
researchers + 1 synthesis) that **WebFetched and verified download URLs** and
install writeups, cross-checked against the two earlier fork drafts, and returned
structured per-OS entries. This doc folds all 10 family returns (69 OS entries)
into one reference.

- **`mediaVerified: true`** means the agent actually fetched the download page /
  file / API and confirmed it resolves to the claimed media. **`false`** means the
  source was confirmed to *exist* via search snippets or is gated (dev-account,
  Anubis/anti-bot, TLS bug) but the exact file was not opened this pass —
  re-verify before building. Both states are called out per row (`✓` / `~`).
- Availability is current as of the July 2026 assessment; **re-verify the media
  links before building.** Preservation-archive links are for genuinely
  discontinued software.

### The constraint that drives every difficulty score

<!-- folded in from gallery-os-expansion-candidates.md (2026-07 restructure) -->

streamhost captures a **QEMU framebuffer over dbus**, on an **x86-64, no-GPU** host
(KVM for x86 guests, TCG for other architectures). That yields three regimes:

- **x86 + a VGA framebuffer** → drops straight into the existing pipeline.
- **Non-x86 but a QEMU target with a framebuffer** (m68k, PPC, SPARC, HPPA, MIPS, ARM,
  RISC-V) → works, but TCG-slow and finickier.
- **Serial/3270-only, or needs a non-QEMU emulator** (SIMH, Hercules, Previous, VICE,
  gxemul, POSE, vendor SDK emulators) → the emulator runs **host-native** on
  labhost with its own video backend disabled, and streamhost captures its
  framebuffer directly (the Tier-3 path proven by `irix` and the nine converted
  MAME stations). This unlocks entire wings (teletype UNIX, mainframes, 8-bit
  home computers, most mobile/watch OSes) at roughly **69% of the cost** of the
  kiosk it replaces.

> **Policy update, 2026-08-17 — "needs-bridge" is now a PoC label, not a plan.**
> Every row below that this catalog scored as `needs-bridge` was written when a
> captured-Linux kiosk was the delivery form. It no longer is. A kiosk is
> allowed only as a throwaway step to prove an emulator reaches a desktop; the
> shipped station is always **direct framebuffer capture + input forwarding**.
> Read `needs-bridge` as "needs a non-QEMU emulator, therefore Tier 3
> host-native", and add the host-native work to the effort score. See
> [`../GUEST-TIERS.md`](../GUEST-TIERS.md) and
> [`../lab/DEBRIDGE-CONVERSION-BRIEF.md`](../lab/DEBRIDGE-CONVERSION-BRIEF.md).

> **Where media comes from.** This catalog's URLs are the supply. Pre-built
> collections are **reference only** — notably the Virtual OS Museum image under
> `~/virtualosmuseum`, whose 1546 ready-to-run installations are a good place to
> learn *which* emulator and settings solve a given install (and to discover
> candidates), but from which **no image, ROM or media file is ever taken**. We
> source and hash our own.

**Difficulty scale:** 🟢 Easy · 🟡 Medium · 🟠 Hard · 🔴 Very Hard / impractical.

### Legal posture buckets (prefer the top two)

1. **officially-free** — vendor/successor released it open or free (BSDs, Minix,
   Oberon/A2, Genode/Sculpt, Inferno, Syllable, OpenVMS x86 via VSI Community
   License, CP/M, PC-GEOS, DR-GEM, EmuTOS/AltirraOS, LibreELEC, AsteroidOS,
   webOS-OSE, C64/Apple-II GEOS freeware, Amstrad ROMs by permission).
2. **public-domain / preservation-with-a-real-license** — MVS 3.8j (IBM public
   domain), Research UNIX v6/v7 + 2.11BSD (Caldera/TUHS letter), Multics (Bull/MIT
   2007), ITS (community reconstruction).
3. **preservation-archive (abandonware)** — proprietary but discontinued, hosted
   by preservation projects (WinWorld, Internet Archive, Macintosh Garden, PalmDB,
   fsck.technology).
4. **contested-commercial** — owner still sells/supports it (HP-UX→HPE, AIX→IBM,
   Solaris/Sun→Oracle, IRIX→HPE, KaiOS, LG/Samsung/Google mobile). Archived copies
   exist.

### Major hubs (bookmark)

| Hub | Covers | URL |
|---|---|---|
| WinWorld | Windows/DOS/OS-2/NeXTSTEP/BeOS/Xenix/SCO/Sun-x86 | https://winworldpc.com/library/operating-systems |
| Internet Archive | nearly everything (ISOs, emulator images, TUHS) | https://archive.org |
| Macintosh Garden / Repository | Classic Mac OS install CDs **+ Mac ROMs** | https://macintoshgarden.org · https://www.macintoshrepository.org/ |
| TUHS | PDP-11 Research UNIX v5/6/7, early BSD (Caldera-licensed) | https://www.tuhs.org/ |
| PalmDB | Palm OS emulators + ROMs | https://palmdb.net/ |
| fsck.technology | SCO / Sun / vintage UNIX media | https://fsck.technology/software/ |

---

## How to use this with the emulator bridge

Two delivery regimes, decided by whether QEMU can natively scan out the guest's
framebuffer:

- **Native QEMU (no bridge)** — x86 guests run under KVM; m68k / PPC / SPARC /
  HPPA run under TCG (slow but fine for a museum tile). All present a
  framebuffer QEMU scans out; drop straight into the existing pipeline with
  `-display dbus,p2p=on` (swap this for any `-display cocoa/sdl/gtk` in a
  guide's recipe). Everything the tables mark **`native`** is here.
- **Emulator-in-a-captured-guest bridge** — for machines QEMU can't emulate
  (6502/Z80/PDP-11/S-370/PDP-10, Atari ST, NeXTcube, MIPS-SGI) or emulators that
  are non-stock QEMU forks (qemu-pebble, Tizen `maru`, Android `ranchu`, EKA2L1,
  MAME, SIMH, Hercules, dps8m, KLH10): run the emulator **full-screen inside a
  captured x86 Linux kiosk guest**, and streamhost captures *that* Linux guest's
  framebuffer + audio like any other tile. Full reusable recipe:
  **`streamhost/docs/BRIDGE.md`**. Rows marked **`needs-bridge`** are here.

**The bridge is proven.** The **C64 + GEOS** tile is the live reference
implementation (`/data/vms/streamhost/stations/c64/`, udp/54114, GEOS deskTop +
non-silent SID confirmed 2026-07-08 — see `docs/guests/c64.md`). The
shared base `/data/vms/bridge/bridge-base.qcow2` already ships VICE `x64sc` +
`hatari` + `cap32` — **Atari ST and Apple II are now LIVE** on that same base
(plus the `amiga` bridge tile); **Amstrad CPC remains the next drop-in**. One bridge build amortizes across the whole
8-bit wing plus the heritage-serial, CP/M-80, IRIX, mobile-SDK and TV/watch wings.

> Note the "bridge" comes in weights: *lightweight* (run one x86 ELF binary
> full-screen in a Linux tile we already capture — Inferno `emu`, KaiOS `kaiosrt`,
> B2G desktop, EKA2L1, CloudpilotEmu) vs *heavy* (build a decade-old QEMU fork, or
> nest a full captured **Windows** guest — Openmoko, Windows Mobile/Phone,
> BlackBerry pre-10, Symbian UIQ).

---

## Ranked build order — what to build next

Synthesized from the family `topPicks` + `feasibility`/`effort`/`museumValue`.
MV = museum value (1–5).

### Wave 1 — Native-QEMU-x86 easy wins (no bridge, works-known, small effort, cleanest licensing)

Ship these first; they reuse existing tile recipes and fill glaring gaps.

| OS | license | why | MV |
|---|---|---|---|
| **FreeBSD 15.1** (+ NetBSD 10.1, OpenBSD 7.9) | officially-free | fills the gallery's total **BSD gap**; KVM-fast; OpenBSD ships fvwm in base | 5/4/4 |
| **A2 / Bluebottle Oberon** | officially-free | **live-boots** Wirth's zooming-tile GUI from ISO, no install | 5 |
| **Sculpt OS 26.04** (Genode) | officially-free | the "museum isn't only retro" tile; 35 MiB image, capability microkernel GUI | 4 |
| **Minix 3.3.0** | officially-free | Tanenbaum, "the OS that provoked Linus"; console-only but trivial | 5 |
| **Syllable Desktop** (Live CD) | officially-free | independent BeOS-like desktop, boots straight to GUI | 4 |
| **PC/GEOS Ensemble** (bluewaysw) | officially-free (Apache-2.0) | true multitasking GUI on a 286; unzip onto a FreeDOS disk | 5 |
| **OpenGEM 7** (DR GEM) | officially-free (GPL-2.0) | the Atari-ST-look GUI Apple sued DRI over; pairs with GEOS | 4 |
| **CP/M-86 1.1** | permissive (2022 CP/M license) | "the OS before DOS" on real PC hardware; boots as a floppy | 4 |
| **LibreELEC / Kodi** | officially-free (GPL) | easiest whole "TV OS" tile; instantly recognizable 10-foot UI | 4 |
| **OpenVMS x86 9.2-3** | officially-free (VSI Community) | DEC/VMS lineage; **text** Guest Console works-known (CDE needs bridge) | 5 |
| **Windows NT 4.0 SP6a** | preservation | classic Explorer shell on the NT kernel; prebuilt VM = near-trivial | 4 |
| **BeOS R5 PE** | preservation (PE was freeware) | "the original behind Haiku" | 5 |
| **MeeGo 1.2 Netbook** | preservation (LF/Intel/Nokia) | Sailfish's ancestor; one 864 MB x86 image boots to the Netbook UX | 5 |

### Wave 1b — Native, works-known, a bit more choreography (medium effort)

| OS | regime | note | MV |
|---|---|---|---|
| **Classic Mac OS 7.5.3 / 7.1 / 8.1** | native m68k (TCG) | top-3 museum draw; needs a Quadra 800 ROM | 5/5/4 |
| **Mac OS 9.2.2** | native PPC (TCG) | **no external ROM** (OpenBIOS); platinum-era Mac | 4 |
| **HP-UX 11i v1 (11.11)** | native HPPA (TCG) | boots to a **full CDE desktop** over the Artist framebuffer, no bridge | 5 |
| **SunOS 4.1.4 / Solaris 1.1.2** | native SPARC (TCG) | pre-CDE OpenWindows/OpenLook; complements the Solaris 10 tile (`-vga cg3`!) | 5 |
| **UnixWare 7.1.4 / SCO OpenServer 5.0.7** | native x86 | "literally AT&T System V" with a Motif/CDE desktop; UnixWare has a free eval | 4 |
| **Windows NT 3.51** | native x86 (isapc) | the museum jewel: last Program-Manager-shell OS | 4 |
| **NeXTSTEP 3.3 (x86)** | native x86 | birthplace of the Web; fussy install choreography | 5 |
| **Palm/HP webOS** | native x86 (vmdk→qcow2) | the SDK "emulator" is an x86 webOS VM; boots the Luna cards UI | 5 |
| **BlackBerry 10 sim** | native x86 (vmdk→qcow2) | QNX-based → pairs with the existing QNX 6.5 tile | 4 |
| **Android TV x86** | native x86 (software GL) | reuse the existing Android tile's GL recipe | 3 |
| **webOS TV / webOS OSE** | native x86 (vmdk→qcow2) | LG card UI; use OSE (Apache-2.0) for a clean license | 4 |
| **Windows CE CEPC** (CE5/6/WEC7) | native x86 | only Windows-mobile-family tile that boots as a plain x86 guest | 3 |

### Wave 2 — Needs the bridge (build the bridge, then these unlock)

**8-bit wing (bridge seed already has the emulators):**
- **C64 + GEOS 2.0** — ✅ **LIVE** (reference tile).
- **Atari ST + GEM (EmuTOS)** — ✅ **LIVE** (`atarist` tile). 100% GPLv2, zero proprietary ROM; `hatari` in base.
- **Apple IIe + GEOS** — ✅ **LIVE** (`apple2` tile, LinApple). Apple II GEOS is official freeware.
- **Atari 8-bit + Atari BASIC (AltirraOS)** — trivial, no ROM, no disk; the iconic blue READY screen.
- **Amstrad CPC + Locomotive BASIC** — `cap32` in base; ROMs redistributable by permission.

**Heritage / serial (one SIMH/Hercules/dps8m/KLH10+x3270 bridge unlocks all seven — all MV 5):**
- **2.11BSD** on SIMH pdp11 — ready RP06 kit, boots to login in one command (easiest).
- **Multics MR12.8** on dps8m — pre-cold-booted QuickStart, `telnet 6180`.
- **IBM MVS 3.8j / TK5** on Hercules — public-domain turnkey; the **only 3270 tile** (green ISPF); needs x3270.
- **TOPS-20 Panda** on KLH10 — prebuilt Linux binaries, runs out of the box.
- **Research UNIX v6 / v7** on SIMH — install-from-tape (the two medium-effort ones).
- **ITS** on SIMH/KLH10 — must build from source; the EMACS/Lisp-Machine ancestor.

**Other bridge wins:**
- **IRIX 6.5.22 via MAME** (MV 5) — **headline correction: no longer a dead-end.** MAME's Indy/Indigo2 driver now reaches a full graphical **4Dwm** desktop with `xl24` graphics. Long install; MAME-in-a-Linux-tile.
- **NeXTcube (m68k)** via **Previous** (MV 5) — the actual magnesium cube Berners-Lee wrote the Web on; QEMU has no NeXT machine.
- **CP/M-80** via z80pack **Altair 8800 front panel** (MV 5) — the blinking-lights money shot.
- **Inferno** hosted `emu` (MV 4) — the *cheapest* bridge (one ELF binary); complements 9front.
- **Pebble OS** via qemu-pebble fork (MV 5) — on-brand (already QEMU); boots real Rebble firmware to a watchface.
- **Symbian S60** via EKA2L1 (MV 5) — modern open native emulator, light Linux bridge.
- **KaiOS** (`kaiosrt`) / **Firefox OS** (B2G desktop) (MV 4) — light "app-in-a-tile" runtimes; caption honestly (not a kernel boot).
- **Palm OS 4/5** via CloudpilotEmu/uARM (MV 4) — clean open emulators; ROMs on PalmDB.
- **AsteroidOS** (MV 4) — stock qemu but hard-requires GL (software llvmpipe); bridge as fallback.
- **AIX 7.2** (MV 4) — boots, but pseries has **no framebuffer** AIX can drive → serial-only; CDE effectively unreachable.
- **OpenVMS CDE** (MV 5) — DECwindows/CDE must be pushed over X11 to an X server in a captured Linux guest.
- **Maemo 5** (Xephyr+scratchbox, heavy), **Wear OS** (ranchu+SwiftShader), **Tizen TV/Wear** (maru fork), **BlackBerry pre-10** (fledge-in-Windows), **Windows Mobile 6.x** (MS Device Emulator-in-Windows), **Fire OS** (Android emulator, redundant).

### Parked / dead-ends (poor effort:payoff, or can't build on free tooling)

- **Windows Me** — same 9x/Explorer story as the existing Win98 tile, worst KVM stability. Skip.
- **Windows Vista / Windows 7** — signature **Aero Glass is GPU/WDDM-gated** so it renders as Aero Basic on this no-GPU host; media contested-commercial. Lean skip (Win7 only if you want the XP→7→11 progression).
- **Tru64 / Digital UNIX (Alpha)** — **dead-end**: qemu-system-alpha `clipper` has no SRM firmware, so nothing boots; only commercial serial/headless emulators run it.
- **Symbian UIQ** — **dead-end**: EKA2L1 refuses UIQ; only the fragile legacy Windows SDK emulator, nested in a Windows guest.
- **Windows Phone 7/8** — **dead-end**: WP8 is Hyper-V/XDE-locked (video over an RDP-like channel, no plain framebuffer); WP7 marginally more tractable.
- **Openmoko** — borderline dead-end: mainline QEMU has no neo/gta machine; only the un-buildable ~2008 fork. postmarketOS-on-FreeRunner is the modern stand-in.
- **Maemo 5 device boot (N900)** — not in mainline QEMU (dead-end); the SDK-under-Xephyr route shows the real Hildon UI but is the dev image.
- **Roku OS** — no image exists; 2026 cloud emulator is SaaS; brs-engine is an app simulator. Skip.
- **watchOS / Fitbit OS / Garmin Connect IQ** — no bootable firmware; app-level simulators only (watchOS additionally macOS-locked). Skip.
- **Fire OS** — no clean redistributable image; duplicates the Android tile. Skip.

---

# Per-family catalogs

Media-verified column: `✓` = fetched & confirmed this pass, `~` = exists but not
opened / gated / re-verify.

## 1. BSD / microkernel / independent x86 desktops

| OS | media URL (verified?) | license | format | ROM | size | effort | feasibility | MV |
|---|---|---|---|---|---|---|---|---|
| FreeBSD 15.1-RELEASE amd64 | https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/15.1/ (✓) | officially-free (BSD-2) | ISO / qcow2 | none | ~1.2 GB ISO | small | works-known | 5 |
| NetBSD 10.1 amd64 | https://cdn.netbsd.org/pub/NetBSD/NetBSD-10.1/amd64/installation/cdrom/ (✓) | officially-free (BSD-2) | ISO | none | ~500 MB | small | works-known | 4 |
| OpenBSD 7.9 amd64 | https://cdn.openbsd.org/pub/OpenBSD/7.9/amd64/install79.iso (✓) | officially-free (ISC/BSD) | ISO | none | ~800 MB | small | works-known | 4 |
| Minix 3.3.0 i386 | http://iso.linuxquestions.org/minix/minix-3.3.0/ (~ — official minix3.org has a TLS altname bug) | officially-free (BSD-3) | ISO (bz2) | none | ~280 MB | trivial | works-known | 5 |
| Oberon A2 / Bluebottle | https://sourceforge.net/projects/a2oberon/files/ (✓ `A2_Rev-6498_serial-trace.iso`) | officially-free (ETH) | live ISO | none | ~120–165 MB | trivial | works-known | 5 |
| Genode / Sculpt OS 26.04 | https://genode.org/files/sculpt/sculpt-26-04.img (✓, sha256 listed) | officially-free (AGPLv3+) | raw img | none | 35 MiB | trivial | works-known | 4 |
| Inferno | https://github.com/inferno-os/inferno-os (✓) | officially-free (GPLv2/MIT) | source → hosted `emu` | none | ~200 MB tree | small | needs-bridge (light) | 4 |
| Syllable Desktop (AtheOS) | https://archive.org/details/SyllableDesktop0.6.6LiveCD.i586 (✓) | officially-free (GPL) | Live CD ISO | none | ~65–97 MB | small | works-known | 4 |

**bridgeNeeded:** only **Inferno**, and it is the lightest kind — build/run the
hosted `emu` binary full-screen inside a normal captured x86 Linux tile
(`./emu -g1024x768 wm/wm` → Tk/acme desktop); NOT a nested VM. Everything else is
native x86 `-display dbus,p2p=on`.

Notable recipes / gotchas:
- **FreeBSD**: `qemu-system-x86_64 -enable-kvm -M q35 -cpu host -smp 2 -m 4096 -drive if=virtio,format=qcow2,file=freebsd.qcow2 -cdrom FreeBSD-15.1-...-disc1.iso -boot d -vga std -netdev user,id=n0 -device virtio-net,netdev=n0 -display dbus,p2p=on`. No live GUI — `bsdinstall` is text; reach X post-install (`pkg install xorg twm xterm`, `.xinitrc`+`startx`). With `-vga std` use the Xorg `scfb`/`vesa` path.
- **OpenBSD** is best-in-family for a light-WM tile: **fvwm ships in base Xenocara**, so `startx` needs zero extra packages. NetBSD: select the **X sets** at install (easy to miss) → `startx` gives ctwm.
- **A2 Oberon** and **Syllable Live CD** boot straight to a desktop (no install). A2 needs a **3-button mouse** (middle-click "interclick" is core). Do NOT confuse A2 with the *book* Project Oberon (RISC5 CPU → separate emulator bridge).
- **Sculpt**: `-M q35 -cpu Skylake-Client` matters; boots to the "Leitzentrale" config GUI (looks most alive after a couple of clicks).
- Minix is **console-only** (text VGA still scans out); its value is historical. Minix/Syllable/A2/Inferno projects are all dormant but still boot. Licensing is 100% clean across this family.

## 2. DOS-hosted GUIs + CP/M

| OS | media URL (verified?) | license | format | ROM | size | effort | feasibility | MV |
|---|---|---|---|---|---|---|---|---|
| PC/GEOS Ensemble (bluewaysw) | https://github.com/bluewaysw/pcgeos/releases/download/CI-latest/pcgeos-ensemble_nc.zip (✓) | officially-free (Apache-2.0) | DOS app folder (zip) | none | 10.9 MB | small | works-known | 5 |
| DR GEM — OpenGEM 7 RC3 | https://archive.org/download/opengem7-rc-3/OPENGEM7-RC3.zip (✓) | officially-free (GPL-2.0) | DOS installer (zip) | none | 2.2 MB | small | works-known | 4 |
| CP/M-86 1.1 | https://github.com/tsupplis/cpm86-kernel (✓); hubs cpm.z80.de, seasip.info/Cpm | permissive (2022 CP/M) | bootable floppy IMG | none | ~1.44 MB | small | works-known | 4 |
| CP/M-80 2.2 (Z80/8080) | z80pack https://github.com/udo-munk/z80pack (✓); RunCPM https://github.com/MockbaTheBorg/RunCPM (✓) | officially-free | emulator + .dsk | none | <5 MB | medium | needs-bridge | 5 |

**bridgeNeeded:** only **CP/M-80** (no QEMU Z80 target). Preferred: **z80pack**
`altairsim`/`imsaisim` full-screen in a Linux tile — its X11/SDL **blinking-lights
front panel** is a real framebuffer, `cpmsim` boots CP/M 2.2 behind it. Lighter
fallback: **RunCPM** in a full-screen VT100 terminal. GEOS/GEM/CP/M-86 need no bridge.

Notable recipes / gotchas:
- **PC/GEOS**: no installer — make a small FreeDOS hard-disk qcow2 (reuse the freedos tile), unzip the `ENSEMBLE\` folder onto C:, wire `C:\ENSEMBLE\LOADER.EXE` into `AUTOEXEC.BAT`, then `qemu-system-i386 -machine pc -cpu pentium -m 32 -hda freedos-geos.qcow2 -vga std -display dbus,p2p=on -enable-kvm`. Boots to a full graphical desktop (GeoManager/GeoWrite/GeoDraw) — distinct from the FreeDOS prompt tile. Use `-vga cirrus` if SVGA misbehaves.
- **OpenGEM**: same FreeDOS pipeline; run `SETUP`/`M.BAT` once, append `GEM` to AUTOEXEC. If RC3's setup fails on FreeDOS, use the **Commander-Zal fork's fixed Setup.BAT**.
- **CP/M-86**: `qemu-system-i386 -machine pc -fda cpm86.img -boot a -no-fd-bootchk -m 4 -vga std -display dbus,p2p=on`. `-no-fd-bootchk` is **essential** (no boot-sector signature). Character UI (`A>` prompt). **Dead link flagged:** the old `claunia.com/qemu` CP/M-86 image 404s — use tsupplis or cpm.z80.de/seasip.
- **CP/M-80**: z80pack needs X11/OpenGL/SDL+JPEG baked into the bridge image; the Altair front panel is the standout visual of the family. This is the genuine Kildall 1974 CP/M. Park behind the bridge; CP/M-86 covers the CP/M story on x86 meanwhile.

## 3. Classic Mac + Be + NeXT

| OS | media URL (verified?) | license | format | ROM | size | effort | feasibility | MV |
|---|---|---|---|---|---|---|---|---|
| Classic Mac OS 7.1 | https://macintoshgarden.org/apps/mac-os-install-cd-library (✓, entry #1) | preservation | CD ISO + ROM | **Quadra 800 ROM** | ~80 MB | small | works-known | 5 |
| Classic Mac OS 7.5.3 | https://macintoshgarden.org/apps/mac-os-install-cd-library (✓, `SYSTEM_7-5-3-RETAIL`) | preservation | CD ISO + ROM | **Quadra 800 ROM** | ~255 MB | small | works-known | 5 |
| Classic Mac OS 8.1 | https://macintoshgarden.org/apps/mac-os-install-cd-library (✓, `MAC_OS_8-1_RETAIL`) | preservation | CD ISO + ROM | **Quadra 800 ROM** | ~401 MB | small | works-known | 4 |
| Mac OS 9.2.2 Universal | https://macintoshgarden.org/apps/mac-os-922-universal (✓); mirror https://archive.org/details/MacOS9.2.2-Drag_and_install_Universal | preservation | bootable CD ISO (zip) | **none** (OpenBIOS) | ~500 MB | small | works-known | 4 |
| BeOS R5 (PE/Pro 5.0.3) | https://archive.org/details/beos-professional-edition-5.0.3 (✓) | preservation (PE was freeware) | bin/cue ISOs | none | ~641 MB | small | works-known | 5 |
| NeXTSTEP 3.3 (x86) | https://winworldpc.com/product/nextstep/3x (✓); https://archive.org/details/NeXTSTEP33CISC | preservation | ISO (BSD/FFS) + floppies | none | ~373 MB | medium | promising | 5 |
| NeXTSTEP 3.3 on NeXTcube (m68k) | Previous https://github.com/probonopd/previous (✓); ROM https://www.macintoshrepository.org/52628-next-hardware-roms (✓) | preservation | Previous + ROM + media | **Rev_2-5_v66.bin** (54 KiB) | media ~300–400 MB | medium | needs-bridge | 5 |

**bridgeNeeded:** only the **NeXTcube (m68k)** — QEMU has no NeXT machine; run
**Previous** (Hatari+WinUAE-m68k+i860 core) full-screen in a captured x86 Linux
tile. All 6 others are native QEMU framebuffer tiles (m68k `q800` / ppc `mac99` /
i386, under TCG or KVM).

Notable recipes / gotchas:
- **q800 ROM**: Macintosh Garden ROM archive **DL#6** ("ROM dumped from a Quadra 800, courtesy of Mac84") or `Quadra800.rom` from `mac-rom-archive-20110819.zip`, ~1 MB, MD5 on page.
- **Mac OS 7.x recipe**: `qemu-system-m68k -M q800 -m 128 -bios Quadra800.rom -display dbus,p2p=on -drive file=pram.img,format=raw,if=mtd -device scsi-hd,scsi-id=0,drive=hd0 -drive file=disk.img,format=raw,if=none,id=hd0 -device scsi-cd,scsi-id=3,drive=cd0 -drive file=macos.iso,format=raw,if=none,id=cd0 -boot d`. **First HDD partition must be ≤2 GB** or it won't boot post-install; **Mac OS ≤7.6.1 must init the disk with "Apple HD SC Setup"**, not Drive Setup. 7.5.3 is the sweet spot (E-Maculation + `matthewdeaves/QemuMac` automate it).
- **Mac OS 9.2.2**: `qemu-system-ppc -M mac99,via=pmu -cpu g4 -m 512 -display dbus,p2p=on -g 1024x768x32 -drive file=macos9.img,format=raw -drive file=macos922.iso,format=raw,media=cdrom -boot d -device usb-kbd -device usb-mouse`. **Must use `via=pmu`** (not default `via=cuda`) for USB kbd/mouse. **No external ROM** — biggest advantage over the m68k tiles. Audio needs the community "screamer" patch (optional).
- **BeOS R5**: extract ISOs from bin/cue with `bchunk`; at the boot menu **"disable BIOS calls"** before first install completes; cap **RAM ≤768 MB**; set VESA mode `1024 768 16` (defaults to 640×480 greyscale); NIC = `ne2k_pci`. The deliberate "original behind Haiku" pairing.
- **NeXTSTEP 3.3 x86** is genuinely **fussy**: SCSI driver **option #2** to dodge a corrupt beta driver disk; ne2000 networking effectively broken (use a small extra partition for file transfer); keyboard remap after update #3; TCG or a plain `-cpu` can be more stable than aggressive KVM. Boot floppies `3.3_Boot_Disk.floppyimage` / `3.3_Core_Drivers.floppyimage`; walkthrough at gunkies.org.
- **NeXTcube (Previous)**: set Machine type = **"NeXTcube"** (not the default "NeXT Computer"), load `Rev_2-5_v66.bin`, SCSI0=HD, SCSI1=boot floppy, SCSI2=CD. Turbo vs non-Turbo ROM must match the machine or it won't POST. Easiest path: attach a community pre-installed HD image. Pre-made images + guide: WinWorld forum #6503.

## 4. Windows NT rungs (+ Me/Vista/7 assessment)

| OS | media URL (verified?) | license | format | ROM | size | effort | feasibility | MV |
|---|---|---|---|---|---|---|---|---|
| Windows NT 4.0 Workstation SP6a | https://winworldpc.com/download/4162c2ba-c3b7-18c3-9a11-c3a4e284a2ef (✓); prebuilt VM https://archive.org/details/Microsoft_Windows_NT_4_0_Workstation_Service_Pack_6_Virtual_Machine_VMware_WinWorld (✓) | preservation | CD ISO (~312 MB) or prebuilt VMware VM | none | ISO ~312 MB | small | works-known | 4 |
| Windows NT 3.51 Workstation | https://winworldpc.com/product/windows-nt-3x/351 (✓); bootable SP5 ISO https://archive.org/details/ntwks-351-upd (✓) | preservation | CD ISO (~142 MB) + floppies | none | ISO ~142 MB | medium | works-known | 4 |
| Windows Me | https://winworldpc.com/product/windows-me/me (~); guide https://computernewb.com/wiki/QEMU/Guests/Windows_ME | preservation | bootable CD ISO | none | ~350–500 MB | small | promising | 2 (skip) |
| Windows Vista | no clean preservation source (~, contested) | contested-commercial | DVD ISO | none | ~3–4 GB | small | works-known | 2 (skip) |
| Windows 7 | no clean preservation source (~, contested) | contested-commercial | DVD ISO | none | ~3–4 GB | small | works-known | 3 (lean skip) |

**bridgeNeeded:** none — all native x86 `-display dbus,p2p=on`. The NT 4.0 SP6
VMware image is just a disk-format convenience (convert the `.vmdk` to qcow2).

Notable recipes / gotchas:
- **NT 4.0**: `qemu-system-i386 -M pc,hpet=off -cpu pentium3 -m 128 -hda nt4.qcow2 -cdrom nt4ws.iso -device VGA -netdev user,id=n0 -device pcnet,netdev=n0 -accel kvm -rtc base=localtime -boot d`. **Must** use `-cpu pentium3` (host CPU → setup BSOD), `hpet=off`, **uniprocessor HAL only** (`-smp 1`; MP HAL crashes under KVM), system partition **≤4 GB**. Shortcut: convert the prebuilt SP6 `.vmdk` to qcow2 and skip install entirely. Ctrl-Alt-Del via monitor `sendkey ctrl-alt-delete`.
- **NT 3.51**: `qemu-system-i386 -M isapc -cpu 486 -m 64 -hda nt351.qcow2 -cdrom ntwks-351-sp5.iso -device VGA -net nic,model=ne2k_isa -net user -boot d`. Retail CD is **not bootable** — use the community **SP5 bootable ISO** or the 3 setup floppies. ISA machine (`-M isapc`), NE2000 ISA NIC, disk ≤1 GB. The last Program-Manager-shell OS — visually distinct from every Explorer NT tile.
- **Assessment trio — skip:** Me (same 9x/Explorer story as Win98, worst KVM stability, broken tablet pointer); Vista (Aero Glass is GPU/WDDM-gated → renders as Aero Basic, contested media); Win7 (most iconic of the three, gives XP→7→11, but same GPU-gated Aero + contested media — only add deliberately).

## 5. Enterprise / legacy UNIX

| OS | media URL (verified?) | license | format | ROM | size | effort | feasibility | MV |
|---|---|---|---|---|---|---|---|---|
| OpenVMS x86-64 9.2-3 | https://vmssoftware.com/community/community-license/ (✓, register first) | officially-free (VSI Community) | install ISO + PAK | none (OVMF) | ~2–3 GB | small | works-known (text); CDE needs-bridge | 5 |
| HP-UX 11i v1 (11.11) PA-RISC | http://tenox.pdp-11.ru/ + archive.org `hpux1100`; depots http://hpux.connect.org.uk/ (✓ install writeup) | contested-commercial | install ISO set | **none** (built-in PDC) | ~1.5–2 GB | medium | works-known | 5 |
| AIX 7.2 (POWER8 pseries) | archive.org `AIX_CD-ROM_Collection`; prebuilt https://worthdoingbadly.com/aixqemu/ (✓) | contested-commercial | install DVD ISOs / qcow2 | **none** (SLOF) | ~4–6 GB | large | needs-bridge (serial) | 4 |
| UnixWare 7.1.4 / SCO OpenServer 5.0.7 | https://archive.org/details/UnixWare71 ; https://archive.org/details/OpenServer5.0.7Hw10Jun051800 (✓) | mixed (UW has free eval) | install ISO | none | UW ~3.5 GB / OSR ~277 MB | medium | works-known | 4 |
| SunOS 4.1.4 / Solaris 1.1.2 (SPARC) | https://winworldpc.com/product/sun-solaris/1x ; https://fsck.technology/software/Sun%20Microsystems/SunOS%20Install%20Media/ (✓) | contested-commercial | install CD ISO | none (OpenBIOS) | ~500 MB–1 GB | medium | works-known | 5 |
| Tru64 UNIX / Digital UNIX (Alpha) | no boot path on free tooling (✓ verdict) | contested-commercial | — | SRM (the blocker) | n/a | impractical | **dead-end** | 4 |
| IRIX 6.5.22 (SGI/MIPS) | https://winworldpc.com/product/irix/65 + /6522 (✓); guide https://sgi.neocities.org/installguide | contested-commercial | 6–8 CD ISOs → MAME CHD | **Indy PROM** (MAME romset) | ~3–4 GB | large | needs-bridge | 5 |

**bridgeNeeded:** three — **IRIX** (MAME `indy_4610`/`indigo2_4415` in a Linux
tile), **OpenVMS CDE** (DECwindows pushed over X11 to an X server in a captured
Linux guest; the text Guest Console itself needs no bridge), **AIX** (pseries has
no usable framebuffer → SLOF serial VTY only → serial-terminal bridge). HP-UX,
SunOS, UnixWare/SCO produce a graphical tile with **no bridge**. Tru64 needs no
bridge because it can't boot at all.

Notable recipes / gotchas:
- **HP-UX** (best value/effort, MV 5): `qemu-system-hppa -machine B160L -smp cpus=4 -accel tcg,thread=multi -boot d -drive if=scsi,bus=0,index=6,file=hpux.qcow2,format=qcow2 -m 512 -d nochain -cdrom mcoe.1_5.iso -net nic,model=tulip -net user`. Reaches a **full CDE desktop** over the built-in Artist framebuffer. Gotchas: copy `/etc/nsswitch.files`→`/etc/nsswitch.conf` or CDE login hangs; **do NOT exceed 1280×1024** (crash / dtwm mouse can't reach y≥1146); grow filesystems with `lvextend`+`extendfs`; no OpenGL; PA-RISC 1.1 (32-bit) media only, max 11.11. Verified writeup: virtuallyfun.com (Oct 2025, qemu 10.1).
- **SunOS 4.1.4** (MV 5): `qemu-system-sparc -M SS-5 -m 256 -vga cg3 -drive file=sunos414.qcow2,if=scsi,bus=0,unit=0,media=disk -drive file=sunos_4.1.4_install.iso,if=scsi,bus=0,unit=2,media=cdrom -net nic,model=lance -net user`. **CRITICAL: `-vga cg3`** — SunOS/OpenWindows has no driver for QEMU's default TCX. Run OpenWindows from `/usr/openwin/bin/openwin` (not on PATH). Pre-CDE OpenLook desktop; complements the Solaris 10 CDE tile.
- **UnixWare/SCO**: `-M pc -cpu pentium3` (modern CPU features confuse the installers), IDE HDD before CDROM, `pcnet` NIC (GUI DHCP broken — `dhcpc -i <iface>` manually), `kbm.wheel=no` in DEFBOOTSTR. Genuine x86 VGA Motif/CDE tile. UnixWare 7.1.4 has an official free 90-day eval.
- **OpenVMS**: `qemu-system-x86_64 -machine q35 -accel kvm -cpu host -m 8G -smp 2 -bios OVMF.fd ...`; at the EFI shell `MAP FS*` then `FS0:\efi\vms\vms_bootmgr`. 9.2-3's VGA Guest Console is **text-only**; CDE runs but has no local-VGA path (VSI won't add one). Download links appear only **after** registering/approval.
- **AIX**: `qemu-system-ppc64 -cpu POWER8 -machine pseries -m 4096 -serial mon:stdio ... -nographic`. **AIX 7.1 will NOT boot** (no virtio) — must be 7.2 TL3 SP1+. `fsck64` can hang boot (workaround: replace `/sbin/helpers/jfs2/fsck64` with `exit 0`). CDE **not achievable** under QEMU.
- **Tru64 DEAD-END** (well-sourced): qemu-system-alpha `clipper` uses `palcode-clipper`, which implements neither SRM firmware callbacks nor the SRM CLI → no bootloader can load a kernel. Only commercial Windows-hosted AlphaVM/es40 boot it, serial/headless. Park.
- **IRIX headline correction**: the old "no working GUI emulation" verdict held for QEMU (incomplete SGI) and gxemul (console only) — but **MAME now installs and runs IRIX 5.3/6.5.22 to a real 4Dwm desktop** with `xl24` 24-bit graphics + TUN/TAP net. `./mame64 indy_4610 -gio64_gfx xl24 -hard1 irix65.chd` (Indigo2: `indigo2_4415 -gio64_gfx xl24 -gio64_exp0 xl24`). Long, choreographed install (fx partitioning, PROM vars); MIPS-in-MAME is slow. Upgraded **dead-end → needs-bridge**.

## 6. Open / x86-bootable mobile OSes

| OS | media URL (verified?) | license | format | ROM | size | effort | feasibility | MV |
|---|---|---|---|---|---|---|---|---|
| MeeGo 1.2.0 Netbook UX | https://archive.org/details/meego-netbook-ia32-1.2.0 (✓) | preservation (LF/Intel/Nokia) | raw disk img | none | 864 MB | small | works-known | 5 |
| Palm / HP webOS (1.4.5 / 2.1 / 3.0.5) | https://archive.org/details/webOSLegacySDK (~); OVA https://sdk.webosarchive.org; x86-native https://archive.org/details/openwebos-desktop-1005 | preservation (OSE build = Apache-2.0) | VirtualBox vmdk → qcow2 | none | ~150–400 MB | medium | works-known | 5 |
| KaiOS 2.5 (kaiosrt) | https://s3.amazonaws.com/kaicloudsimulatordl/developer-portal/simulator/Kaiosrt_ubuntu.tar.bz2 (✓) | contested-commercial | Gecko runtime (tar.bz2) | none | ~200–300 MB | small | needs-bridge (light) | 4 |
| Firefox OS / B2G 2.x | https://archive.org/details/b2g-44.0a1.en-US.win32 (✓, win32); Linux = build from https://github.com/mozilla-b2g/B2G | officially-free (MPL-2.0) | desktop client binary | none | ~100–120 MB | medium | promising | 4 |
| Ubuntu Touch (UBports/Lomiri) | tooling https://github.com/ubports/utqemu ; https://github.com/ubports/ubports-pdk (~, image pulled by tool) | officially-free (GPL/various) | raw.xz | none | ~2–4 GB | medium | promising | 3 |
| Maemo 5 Fremantle (N900) + Maemo 4 (N810) | Maemo5 SDK https://wiki.maemo.org/Documentation/Maemo_5_Developer_Guide/... ; N810 https://qemu.readthedocs.io/en/v9.0.4/system/arm/nseries.html (~) | mixed (closed Hildon + N810 bootloader) | scratchbox rootfs / zImage+mtd | **N810 mtd/NOLO dump** (blocker) | ~1–3 GB SDK | large | needs-bridge | 5 |
| Openmoko (Neo FreeRunner/1973) | recipe https://wiki.openmoko.org/wiki/Openmoko_under_QEMU (~); QtMoko images on archive.org | officially-free (GPL) | rootfs jffs2 + uImage | none (open u-boot/Qi) | ~60–200 MB | large | needs-bridge (heavy) | 5 |

**bridgeNeeded:** **light** — Firefox OS (B2G desktop client), KaiOS (`kaiosrt`
Gecko runtime), Maemo 5 (x86 Fremantle scratchbox under Xephyr). **heavy** —
Openmoko (build the ~2008 `qemu-neo1973` fork). **No bridge** — MeeGo (native
x86+KVM), Ubuntu Touch (native, GL-software caveat), Palm/HP webOS (x86 vmdk→qcow2).

Notable recipes / gotchas:
- **Sharpest correction to prior fork research**: only MeeGo is a true drop-in x86 image. The rest split three ways.
- **MeeGo**: `qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -drive file=meego-netbook-ia32-1.2.0.img,format=raw,if=ide -vga std -device AC97 -netdev user,id=n0 -device e1000,netdev=n0 -display dbus,p2p=on`. Pre-installed live image, boots straight to the Mutter/Clutter Netbook UX; the compositor wants GLX → let Mesa fall back to **llvmpipe** software GL.
- **Palm/HP webOS**: the key insight — the SDK "emulator" is a **full x86 build of webOS in a VirtualBox VM**, not an ARM device emulator. `qemu-img convert -O qcow2 'Palm SDK vmdk' webos.qcow2` then boot with `-vga std`; self-boots to the Luna cards UI (2.1 = phone, 3.0.5 = TouchPad tablet). `novacom` only needed to side-load apps, not to boot. Cleanest license: the x86-native **Open webOS Desktop 1005** (Apache-2.0).
- **KaiOS / Firefox OS** are **runtimes, not booting OSes** — caption honestly. KaiOS: inside a captured **Ubuntu 18.04+** tile (needs glibc, not Alpine/musl), `tar -axvf Kaiosrt_ubuntu.tar.bz2 && ./kaiosrt`. Firefox OS: run the `b2g` desktop build (win32 archive works today; Linux path = build "desktop" target from source — Mozilla FTP purged). Avoid `emulator-x86` (Mozilla marked it unstable).
- **Maemo trap**: Maemo 5/N900 (OMAP3) is NOT in mainline QEMU. Honest routes: (a) x86 Fremantle SDK under Xephyr (real Hildon UI, dev image); (b) drop to **Maemo 4 Diablo on `-M n810`** (mainline QEMU, real framebuffer) — but that needs a **device mtd1/NOLO bootloader dump** Nokia never freely released (the blocker is media, not the emulator).
- **Openmoko**: prior research's `-M gta01` example is from the **fork**, not upstream (mainline can't emulate the Smedia Glamo LCD). Building the decade-old fork is the entire job → borderline dead-end. postmarketOS-on-FreeRunner is the modern shortcut but loses the authentic Om2008/QtMoko UX.
- **GL note**: MeeGo (Clutter), Ubuntu Touch (Mir/Lomiri), webOS all want GL → force **llvmpipe/softpipe** software rendering on the no-GPU host. Redundancy: Ubuntu Touch overlaps postmarketOS/Sailfish (Lomiri is the draw).

## 7. 8-bit home computers (all need the bridge)

| OS | media URL (verified?) | license | format | ROM | size | effort | feasibility | MV |
|---|---|---|---|---|---|---|---|---|
| Commodore 64 + GEOS 2.0 | VICE https://sourceforge.net/projects/vice-emu/files/releases/ (✓); GEOS https://archive.org/details/geos64_J1AD (✓); source https://github.com/mist64/geos | VICE GPLv2; **GEOS = official freeware (Feb 2004)** | D64 disk images | C64 KERNAL/BASIC/CHARGEN (bundled in VICE) | D64 ~1 MB | small | needs-bridge | 5 |
| Apple IIe + ProDOS / Apple GEOS 2.1 | LinApple https://github.com/linappleii/linapple ; sa2 https://github.com/audetto/AppleWin ; media https://archive.org/details/apple-ii-disk-collection (✓) | emulators GPL; **Apple GEOS = official freeware (Aug 2003)** | .dsk/.woz/.po floppy | Apple //e ROM (bundled in LinApple/sa2; MAME `apple2e.zip`) | ~800 KB | small | needs-bridge | 5 |
| Atari 800/XL + Atari BASIC | https://atari800.github.io/ + https://github.com/atari800/atari800/releases (✓) | atari800 GPLv2; **AltirraOS+BASIC bundled, free** | none (boots to BASIC) | **none** (AltirraOS built in) | ~2–5 MB emu | trivial | needs-bridge | 4 |
| Atari 520/1040 ST + GEM (TOS) | Hatari https://www.hatari-emu.org/download.html (✓); EmuTOS https://github.com/emutos/emutos/releases (✓) | Hatari GPLv2; **EmuTOS GPLv2** | EmuTOS `etos1024k.img` (free) | none (EmuTOS replaces TOS) | ROM ~256 KB–1 MB | small | needs-bridge | 5 |
| Amstrad CPC 6128 + Locomotive BASIC | Caprice32 https://github.com/ColinPitrat/caprice32 (✓) | Caprice32 GPLv2; **CPC ROMs redistributable by Amstrad permission** | CPC ROM set (bundled) | ~48 KB | small | needs-bridge | 4 |

**bridgeNeeded:** **ALL FIVE** — no QEMU machine for 6502/6510 (C64, Apple II,
Atari 8-bit), Z80 (CPC), or the m68k **Atari ST** (QEMU has no ST machine, only
q800/next-cube/virt). Native SDL emulator mandatory each time, full-screen in an
x86-64 KVM Linux tile. Build the bridge ONCE (medium) → each is a small
near-identical drop-in. **The bridge seed already ships VICE/hatari/cap32** — C64,
Atari ST and Apple II are LIVE; CPC is the direct next drop.

Notable recipes / gotchas (inside the Linux tile; outer QEMU = `-device virtio-vga -display dbus,p2p=on`):
- **C64** (LIVE reference): see `docs/guests/c64.md` for the hard-won VICE 3.9/3.10 SDL2 flags. **`-drive8truedrive` is REQUIRED** or the GEOS deskTop hangs; `-autostart-handle-tde` keeps true-drive on; use a **double-size window (`-VICIIdsize`)** not `-VICIIfull` (real fullscreen renders BLACK in the captured std-VGA fb); AC97 card must be present or VICE pops a modal sound-init dialog; don't redirect stdout (x64sc segfaults if stdout isn't a tty). Same VICE binary also yields C128/VIC20/PET/Plus4 for near-zero extra effort.
- **Apple IIe**: `sa2 --d1 /media/GEOS.po --fullscreen` (AppleWin-sa2 better-maintained than LinApple, which failed to build in the base — needs ImageMagick + a Video.o g++ fix). Apple GEOS needs a mouse card in slot 4. Simpler fallback: boot plain ProDOS/DOS 3.3 to the Applesoft `]` prompt.
- **Atari 8-bit**: lowest-friction in the whole gallery — `atari800 -fullscreen -xl` lands on the iconic **blue READY** BASIC screen; **no ROM, no disk, no licensing**. `-nobasic` for the Memo Pad.
- **Atari ST**: `hatari --tos /media/etos1024k.img --fullscreen` → the GEM desktop. **Hatari mandatory — do NOT attempt qemu-system-m68k** (no ST machine). EmuTOS is clean-room GPLv2 (plainer than Atari's TOS; source a real TOS 2.06 from preservation for exact cosmetics). This is the real-Atari lineage of the DR-GEM tile.
- **Multitech Microprofessor II**: MAME `mpf2` is required; neither an Apple II
  emulator nor Apple II software will run its incompatible map and keyboard
  matrix. Stage only `mpf_ii.rom` (16 384 bytes; CRC32 `8780189f`, SHA1
  `92378b0db561632b58a9b36a85f8fb00796198bb`) at
  `/data/assets-staging/mpf2/mpf_ii.rom`; the thin-overlay builder installs
  MAME and verifies `mame -rompath /opt/mpf2/roms -verifyroms mpf2`. In merged
  MAME sets the ROM is in `tk2000.zip`, while split sets use `mpf2.zip`.
- **Amstrad CPC**: `cap32 --fullscreen` → the yellow-on-blue Locomotive BASIC `Ready` prompt. Keep the unaltered Amstrad copyright string to stay within the granted permission.
- **Licensing is unusually clean**: C64 and Apple II GEOS are **official freeware** (not abandonware; source at github.com/mist64/geos); Atari needs zero proprietary ROMs; only the small Apple //e ROM is copyrighted-and-unlicensed (bundled/preservation-hosted). VICE 3.10 (2025-12-24) is current.

## 8. Heritage / serial-console (all need the bridge)

| OS | media URL (verified?) | license | format | ROM | size | effort | feasibility | MV |
|---|---|---|---|---|---|---|---|---|
| 2.11BSD | https://www.retro11.de/data/oc_w11/oskits/211bsd_rpset.tgz (✓); index https://wfjm.github.io/home/211bsd/ | public-domain (Caldera/TUHS) | SIMH disk kit (.tgz) | none | ~28 MB gz | small | needs-bridge | 5 |
| Research UNIX V6 | https://www.tuhs.org/Archive/Distributions/Research/ (~) | public-domain (Caldera/TUHS) | SIMH tape + RK05 | none | a few MB | medium | needs-bridge | 5 |
| Research UNIX V7 | https://www.tuhs.org/Archive/Distributions/Research/Keith_Bostic_v7/ (~) | public-domain (Caldera/TUHS) | SIMH tape + RP06 | none | RP06 ~176 MB | medium | needs-bridge | 5 |
| IBM MVS 3.8j / TK5 Update 5 | https://www.prince-webdesign.nl/tk5 (✓, `mvs-tk5.zip` 2026/02/18) | **public domain** | Hercules DASD + bundled emu (zip) | none | few hundred MB | small | needs-bridge (3270) | 5 |
| Multics MR12.8 | QuickStart https://multics-wiki.swenson.org/mr12-8 ; binary https://dps8m.gitlab.io/dps8m/Releases/ (✓, R3.1.0) | MIT-style (Bull/MIT 2007) | dps8m + QuickStart disks | none | ZIP tens of MB | small | needs-bridge | 5 |
| TOPS-20 (PANDA) | http://panda.trailing-edge.com (✓, `panda-dist.tar.gz` ~221 MB) | preservation (DEC hobbyist) | KLH10 + ready system (tar) | none | ~221 MB | small | needs-bridge | 5 |
| ITS | https://github.com/PDP-10/its (✓, build from source) | preservation (community reconstruction) | make-driven disk image | none | tens of MB built | medium | needs-bridge | 5 |

**bridgeNeeded:** **ALL SEVEN** — none present a QEMU framebuffer. Two terminal
flavors the bridge must render in a full-screen terminal inside a captured Linux
tile: **Flavor A — serial VT100/teletype** (V6, V7, 2.11BSD via SIMH pdp11;
Multics via dps8m `telnet 6180`; TOPS-20 via KLH10; ITS via SIMH/KLH10). **Flavor
B — IBM 3270 block-mode** (MVS 3.8j only) — Hercules listens on TCP 3270; render
**x3270** (X11, not curses) full-screen; the green formatted TSO/ISPF panel is the
draw. Reusable bridge = a minimal Alpine/Debian tile bundling
`{open-simh, hercules, dps8m R3.1.0, klh10, x3270, a kiosk terminal}` + per-OS
autostart. Build once; then 6 of 7 are trivial-to-small.

Notable recipes / gotchas:
- **2.11BSD** (easiest — prebuilt disk): SIMH pdp11 `set cpu 11/70; set rp0 rp06; att rp0 211bsd.dsk; boot rp0` → straight to a multiuser login. Pick the no-net kit unless you want emulated Ethernet.
- **Multics**: drop the `dps8` binary into the QuickStart folder, `./dps8 MR12.8_boot.ini` (cold-boots headless — the multi-hour cold boot is already done), then `telnet localhost 6180` in the tile's fullscreen terminal. Surface the **telnet 6180** session as the tile (not the emulator console).
- **MVS 3.8j / TK5**: unzip, `./mvs` (Linux) starts bundled Hercules and IPLs MVS 3.8j (JES2/TSO/ISPF 2.2); then `x3270 localhost:3270` fullscreen, TSO LOGON (default userids in the bundled manual). The only entry needing the **3270 render path**, not a serial terminal — highest visual wow.
- **TOPS-20**: unpack `panda-dist`, run the included KLH10 `klt20` config (**prebuilt Linux/Intel binaries — no build**), boots TOPS-20 7.1. Plain SIMH KS10 only runs old 4.x — need KLH10 or SIMH pdp10-KL for 7.1.
- **V6 / V7**: genuine multi-step install-from-tape (mkfs/restor each filesystem); the two medium-effort entries. V6/V7 console echoes UPPERCASE (confuses newcomers).
- **ITS**: only entry with **no prebuilt download** — `make EMULATOR=simh` (or klh10). The DSKDMP → type `its` → `ESCG` → wait → Ctrl-Z login dance is unusual; script it in the bridge autostart.
- Standardize on **OPEN-SIMH** (opensimh.org) for pdp11; **KLH10** or Cornwell's SIMH pdp10-kl for PDP-10; TK5 bundles its own tested Hercules.

## 9. Smart-TV + Smartwatch OSes

| OS | media URL (verified?) | license | format | ROM | size | effort | feasibility | MV |
|---|---|---|---|---|---|---|---|---|
| LibreELEC / Kodi (Generic x86_64) | https://releases.libreelec.tv/LibreELEC-Generic.x86_64-12.2.1.img.gz (✓) | officially-free (GPL) | img.gz / OVA | none | ~180 MB gz | trivial | works-known | 4 |
| Android TV / Google TV (x86) | https://archive.org/details/androidtv-x86 (✓) | preservation / AOSP (no-GApps ISOs cleanest) | bootable ISO | none | 0.3–1.4 GB | small | works-known | 3 |
| webOS TV (LG) | https://webostv.developer.lge.com/develop/tools/emulator-installation (✓, deprecated after v22, last=6.0, dev-account) | contested-commercial (OSE = Apache-2.0) | VirtualBox vmdk → qcow2 | none | ~1.3 GB | medium | promising | 4 |
| Tizen TV (Samsung) | http://download.tizen.org/snapshots/tizen/ + Tizen Studio TV Extension (~) | officially-free base + proprietary ext | maru emulator image (i586) | none | ~0.3–0.9 GB | medium | needs-bridge | 3 |
| Tizen Wear (Galaxy Watch) | Tizen Studio + Wearable Extension https://developer.samsung.com/galaxy-watch/develop/tools (~) | officially-free base + proprietary ext | maru wearable image (i586) | none | ~0.3–0.9 GB | medium | needs-bridge | 3 |
| Pebble OS | qemu https://github.com/pebble/qemu (+ qemu-binaries); firmware via Rebble SDK https://developer.rebble.io/... (✓) | preservation (fork GPL; firmware Rebble-redistributed) | ARM Cortex-M firmware blobs | **tintin_boot.bin + tintin_fw.bin** | few MB each | medium | needs-bridge | 5 |
| Wear OS / Android Wear | Android Studio SDK `system-images;...;android-wear;x86` (✓) | contested-commercial (Google) | AVD system image | none | ~0.6–1.5 GB | medium | needs-bridge | 3 |
| AsteroidOS | https://release.asteroidos.org/nightlies/emulator/ (✓, bzImage + rootfs.ext4) | officially-free | kernel + ext4 rootfs | none | ~200–400 MB | large | promising | 4 |
| Roku OS | no image exists (✓) | contested-commercial | — | — | n/a | impractical | **dead-end** | 2 |
| watchOS / Fitbit OS / Garmin | app-simulators only (✓) | contested-commercial | — | — | n/a | impractical | **dead-end** | 1 |

**bridgeNeeded:** five of the eight buildable — their emulator is a non-stock
QEMU fork/GL-pipe that can't take `-display dbus,p2p=on`: **Pebble** (qemu-pebble,
pre-dbus), **Tizen TV** + **Tizen Wear** (`maru` fork), **Wear OS** (ranchu +
SwiftShader). **AsteroidOS** is borderline (stock qemu but hard-requires GL → run
with `gl=on` + software Mesa, bridge as fallback). **No bridge**: LibreELEC,
Android TV x86, webOS TV/OSE (vmdk→qcow2).

Notable recipes / gotchas:
- **Recurring unlock = SOFTWARE GL** (Mesa llvmpipe via `virtio-vga-gl`; SwiftShader for Android). Every modern TV/watch UI here needs OpenGL/GLES — the existing Android tile already proves the known-good kernel+Mesa combo works; treat it as a reusable asset.
- **LibreELEC**: `qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -drive file=LibreELEC-...img,format=raw,if=virtio -device virtio-vga-gl -display dbus,p2p=on -usb -device usb-tablet`. `-vga std` alone gives a black/garbled Kodi. First boot auto-resizes STORAGE then lands on the Kodi 10-foot UI. Current stable 12.2.1 = Kodi 21.3.
- **Android TV**: reuse the phone tile's software-GL recipe; Leanback launcher is **D-pad driven** (arrow keys). Match the current Android tile's kernel/Mesa to skip a fresh GL debug cycle.
- **webOS TV**: emulator deprecated after webOS TV 22 (last = 6.0 on VirtualBox 6.1, LG dev-account gated). `qemu-img convert -O qcow2 webos.vmdk webos.qcow2` then `-device virtio-vga-gl`. **Clean open alternative: webOS OSE** (Apache-2.0) ships a `qemux86-64` `.wic.vmdk.gz` you build yourself.
- **Pebble** (on-brand, MV 5): assemble flash — `truncate -s 64k tintin_boot.bin; cat tintin_boot.bin tintin_fw.bin > micro_flash.bin; truncate -s 512k micro_flash.bin`. Per platform (from pebble-tool `emulator.py`): basalt/color `-machine pebble-snowy-bb -cpu cortex-m4 -pflash qemu_spi_flash.bin`; chalk/round `-machine pebble-s4-bb`. The fork predates dbus → **must be bridged**. Boots to a watchface standalone; upscale the tiny screen.
- **Wear OS**: install Android Studio in a captured Linux tile, `emulator @WearRound -gpu swiftshader_indirect -no-snapshot` full-screen. ranchu isn't stock QEMU → bridge. Use an **older API level** for a self-contained watchface (newer wants Play sign-in).
- **Tizen**: the `maru` fork has a custom display/skin → won't accept dbus → host it inside a captured Linux tile; needs **nested KVM** or it drops to slow TCG. **One Tizen Studio install serves both the TV and Wear tiles.** Re-verify the exact TV/Wear image path (wiki.tizen.org refused direct fetch).
- **AsteroidOS**: `qemu-system-x86_64 -enable-kvm -kernel bzImage-emulator.bin -device virtio-vga-gl -drive format=raw,file=asteroid-...rootfs.ext4 -m 512 -usb -device usb-tablet --append 'root=/dev/sda rw video=800x800' -display dbus,p2p=on,gl=on`. Boots the Lipstick/Nemo Qt-Wayland round watch face. Hard requirement: GL-capable virtio-gpu → software Mesa on this host (the whole effort).
- **Dead-ends** (note only): Roku (no image; 2026 cloud emulator is SaaS; brs-engine is an app simulator), watchOS (macOS-locked UIKit sim), Fitbit/Garmin (app-level simulators).

## 10. Vendor-SDK mobile OSes

| OS | media URL (verified?) | license | format | ROM | size | effort | feasibility | MV |
|---|---|---|---|---|---|---|---|---|
| BlackBerry 10 (QNX) | https://archive.org/details/blackberry10-device-simulator (✓) | preservation | x86-64 VMware vmdk → qcow2 | none | ~507 MB–1.3 GB | small | promising | 4 |
| Symbian S60 (v3/v5/S^3) | EKA2L1 https://github.com/EKA2L1/EKA2L1/releases (✓); Dumber https://github.com/EKA2L1/Dumber | emulator GPL; ROMs contested/preservation | EKA2L1 + device ROM dump | **device ROM dump** (per phone) | ROM ~50–250 MB | medium | needs-bridge (light) | 5 |
| Palm OS 4 (68k) & 5 (ARM) | ROMs https://palmdb.net/app/palm-roms-complete ; CloudpilotEmu https://cloudpilot-emu.github.io/ ; uARM https://github.com/uARM-Palm/uARM (~) | emulators open; ROMs preservation | emulator + Palm ROM | **Palm ROM** (.rom) | ROM ~2–16 MB | small | needs-bridge (light) | 4 |
| Windows CE / CEPC (CE5/6/WEC7/2013) | https://github.com/WindowsNT351/CE-Collections (✓); https://archive.org/details/win-ce-6-emulator_202201 | preservation | x86 CEPC (nk.bin + loadcepc) | none | nk.bin ~10–40 MB | medium | promising | 3 |
| Windows Mobile 6.x / Pocket PC | https://archive.org/details/WM6LocalizedEmulatorImages + https://archive.org/details/WMSDK (~) | preservation (free MS download) | MS Device Emulator + .bin images | .bin IS the OS | ~30–60 MB/img | medium | needs-bridge (Windows) | 4 |
| BlackBerry OS pre-10 (5/6/7) | https://archive.org/details/blackberryos-smartphone-simulator (~) | preservation (free RIM download) | fledge.exe Win32 sim | none (fledge bundles OS) | ~50–150 MB | medium | needs-bridge (Windows) | 4 |
| Symbian UIQ (P800/P900) | archive.org UIQ/Symbian SDK collections (~, scarce) | preservation | legacy Win32 epoc.exe | none | ~200–600 MB | large | **dead-end** | 4 |
| Windows Phone 7 / 8 | archive.org WP SDK emulator collections (~) | preservation (free MS SDK) | Virtual PC / Hyper-V VHD | none | WP7 ~0.5–1 GB / WP8 ~1.5–3 GB | large | **dead-end** | 4 |
| Fire OS | https://github.com/worthdoingbadly/fireos-android-emulator-repack (✓, scripts only) | contested (needs Amazon OTA) | Android system.img | OTA-extracted image | ~1.5–4 GB | medium | needs-bridge | 2 |

**bridgeNeeded:** most of the family. **Light Linux bridge**: Symbian S60
(EKA2L1 native), Palm OS (CloudpilotEmu WASM / uARM), Fire OS (Android emulator).
**Heavy — nested captured Windows guest**: BlackBerry pre-10 (`fledge.exe`),
Windows Mobile 6.x (MS Device Emulator), Symbian UIQ (legacy `epoc.exe`), Windows
Phone (XDE/Hyper-V). **No bridge**: BlackBerry 10 (x86-64 vmdk→qcow2) and Windows
CE CEPC (native `qemu-system-i386`). Highest-leverage single build = the reusable
**captured-Windows-guest bridge** (unlocks UIQ, BB pre-10, WinMo 6.x, WP).

Notable recipes / gotchas:
- **BlackBerry 10** (best effort:payoff): extract the `.vmdk`, `qemu-img convert -O qcow2 BlackBerry10Simulator.vmdk bb10.qcow2`, then `qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 -drive file=bb10.qcow2,format=qcow2 -vga vmware -net nic,model=e1000 -net user -usbdevice tablet`. **`-vga vmware`** (image expects VMware SVGA). QNX guest → thematically pairs with the existing QNX 6.5 tile. Full Windows set ~9.3 GB, versions BB10 0.09–10.3.2 (stable 10.3.1.2558).
- **Symbian S60** via **EKA2L1** (MV 5, light bridge): full-screen in a captured Linux tile, one-time `File > Install > Device` pointing at a ROM (+RPKG via the "Dumber" tool or preservation RPKG packs). Supports S60v1/v2/v3/v5, S^3, S80 — **NOT** S^2/S90/**UIQ**. No qemu-system-arm involved (high-level emulator). No official Linux maintainer (CI builds).
- **Palm OS**: easiest = **CloudpilotEmu** in a kiosk-Chromium full-screen inside a Linux tile — handles both 68k (OS≤4, POSE core) and **ARM Tungsten E2 (OS5, uARM core; CloudpilotEmu 2.0 added OS5 late 2025)**. POSE alone is **68k-only** — don't expect it to run OS5. ROMs on PalmDB. Graffiti via mouse.
- **Windows CE CEPC** (only Windows-mobile tile that boots as a plain x86 guest): `qemu-system-i386 -m 128 -fda loadcepc-boot.img -hda ce6.img -vga std -net nic,model=pcnet -net user` (loadcepc chainloads `nk.bin`). **pre-CE5 (CE2.x/3.x, PPC2000/02/03) will NOT boot cleanly on QEMU** — 86Box for those; realistic QEMU targets are CE5/CE6/WEC7/WEC2013.
- **Windows Mobile 6.x** / **BlackBerry pre-10**: Win32 apps → run `DeviceEmulator.exe` / `fledge.exe` full-screen inside a captured **Windows** guest (both run standalone, no Visual Studio). WinMo networking needs the Virtual PC 2007 NIC.
- **Dead-ends**: **Symbian UIQ** — EKA2L1 refuses UIQ (checks a version file UIQ stores elsewhere; issue #492 unresolved) → only the fragile legacy Windows SDK emulator. **Windows Phone** — WP8 is Hyper-V/XDE-locked (video over an RDP-like channel, no plain framebuffer); WP7 marginally tractable via raw-VHD extraction. **Fire OS** — no clean prebuilt image (repo is scripts targeting Apple-Silicon arm64), duplicates the Android tile.
- **Corrections to prior fork notes**: CEPC is NOT a clean easy win for *old* CE (only CE5+); POSE covers Palm ≤4 only; EKA2L1 does not support UIQ.

---

## Coverage vs the current registry lineup

Current streamhost tiles: Windows 1.0/3.11/95/98/2000/XP, MS-DOS (Win 1.0 and
MS-DOS share the one `msdoswin1` tile), FreeDOS,
OS/2 Warp 4, Solaris 10 x86 (CDE), 9front, Haiku, AROS, ReactOS, QNX 6.5, Alpine,
TinyCore, Android (phone), postmarketOS, Sailfish, KolibriOS, SerenityOS, ToaruOS,
TempleOS, HelenOS — plus the four bridge tiles **C64+GEOS, Atari ST, Apple IIe,
Amiga** (all live). Non-streamhost exhibits: RISC OS + Windows 11 (both currently
dead) and macOS (showcase poster; guest deleted 2026-07-14).

Biggest gaps this catalog fills:
- **Zero BSD** today → FreeBSD/NetBSD/OpenBSD (Wave 1).
- **No non-Windows DOS GUI** → PC/GEOS + DR-GEM (Wave 1).
- **No pre-CDE / non-Solaris commercial UNIX** → HP-UX (CDE!), SunOS/OpenLook, UnixWare (SysV), IRIX (4Dwm, now reachable).
- **No classic Mac / Be / NeXT** → Mac OS 7.5.3/9.2.2, BeOS R5, NeXTSTEP.
- **Missing NT rungs** → NT 3.51 (Program Manager) + NT 4.0.
- **No TV/watch OS** → LibreELEC, Pebble, Android TV.
- **No pre-iPhone smartphone era** → Symbian S60, BlackBerry 10/pre-10, Palm OS, Windows Mobile/CE, webOS, MeeGo/Maemo.
- **No mainframe / minicomputer / teletype wing** → MVS 3.8j (3270), Multics, TOPS-20, ITS, PDP-11 UNIX v6/v7/2.11BSD, CP/M-80 (Altair).

Deliberate "original vs recreation" pairings (add only intentionally): BeOS↔Haiku,
Inferno/serial-UNIX↔9front, A2↔(book Project Oberon RISC5), BB10↔QNX,
Maemo/Openmoko↔postmarketOS, Fire OS↔Android.

## Dead-ends (can't build on free tooling)

- **Tru64 / Digital UNIX (Alpha)** — qemu-system-alpha `clipper` has no SRM firmware; nothing boots. Commercial emulators are serial/headless only.
- **Symbian UIQ** — EKA2L1 refuses UIQ; only the fragile legacy Windows SDK emulator nested in Windows.
- **Windows Phone 7/8** — WP8 is Hyper-V/XDE-locked (no plain framebuffer); WP7 barely tractable.
- **Openmoko** — mainline QEMU has no neo/gta machine; only the un-buildable ~2008 fork.
- **Maemo 5 device boot (N900)** — not in mainline QEMU (the SDK-under-Xephyr route is the dev image, not a device boot).
- **Roku OS** — no bootable image exists (2026 cloud emulator is SaaS).
- **watchOS / Fitbit OS / Garmin Connect IQ** — no bootable firmware; app-level simulators only (watchOS macOS-locked).

Effort/payoff skips (buildable but not worth it): **Windows Me** (redundant with
Win98, worst stability), **Windows Vista / 7** (Aero GPU-gated → renders as Aero
Basic, contested media), **Fire OS** (redundant with Android, no clean image).

---

*Supersedes the earlier fork drafts `gallery-os-expansion-candidates.md` and
`gallery-os-media-sourcing.md` (both deleted in the 2026-07 restructure) — their
content is folded in and verified here.
Research produced 2026-07-08 by 10 parallel OS-family research agents +
synthesis; see `streamhost/docs/BRIDGE.md` and `docs/guests/c64.md` for the
proven bridge implementation.*

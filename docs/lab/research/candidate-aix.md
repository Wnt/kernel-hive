# Candidate: AIX on an emulated PowerPC RS/6000

**Target: IBM AIX 4.3 on `qemu-system-ppc -M 40p`, with a native framebuffer.**
Tier 1, direct framebuffer capture, firmware ROM required. The station id is
`aix432`.

**Status (2026-08-26): CDE, Netscape and Quake render natively.** AIX 4.3.3 is
installed with X11/CDE, Ultimedia Services, Netscape, Quake, Abuse and
CorelDRAW 3.5. A QEMU model for the Matrox behind IBM's GXT130P was written for
this station, and under the **genuine IBM 40p boot ROM** AIX brings up `gxme0`,
`rcm0`, `mg21`, `lft0` and `paud0` from authentic PReP residual data with **no
guest patching**. A full CDE desktop, Netscape Communicator 4.08 and Quake 1.07
all draw on the emulated card (§4.5). Outstanding: the hardware cursor, and
CorelDRAW, which needs an AIX 3.2-era library AIX 4.3 does not ship.

## 1. Why this station is not "AIX 4.3.2", as originally scoped

The ask was AIX **4.3.2**. The media exists and was sourced (§5), but **AIX
4.3.2 cannot boot on QEMU's emulated 40p** and 4.3.3 can. This was measured, not
assumed:

- Both discs carry a **type 0x41 PReP boot partition** and Open Firmware loads
  it happily. The 4.3.2 disc's partition is at LBA 1203108, 2.9 MB.
- The bootstrap monitor inside both is **the same build** — identical
  `src/rspc/usr/lib/boot/softros/aixmon/*.c` version strings, identical
  hardcoded device paths (`/pci@80000000/pci1000,1@c,0/cdrom@`). So the
  bootstrap is not the difference.
- Tracing `scsi_req_parsed_lba` shows where they diverge. Both issue the same
  unit-reset cycle (`START STOP UNIT`, `REQUEST SENSE`, `READ CAPACITY` ×2).
  **4.3.3 then streams ~1100 `READ(6)`s and reaches the console prompt; 4.3.2
  does one retry cycle, issues a single `READ(6)`, and never issues another.**
  394 requests, then silence at 100% CPU forever.

So the failure is in the **AIX 4.3.2 kernel's** handling of the emulated LSI
53c810, not in the firmware, the media, the disc layout or our patches. It is
not fixable from the QEMU side without reverse-engineering IBM's driver.

**Two things that look like the cause and are not:**

- `invalid/unsupported opcode: 00 00 00 00 @ 07ea6390` in the QEMU log is a **red
  herring** — the successful 4.3.3 boot logs exactly the same line.
- The SCSI controller's BARs read back unmapped at the `ok` prompt. That is
  normal: Open Firmware maps the BAR only while it holds the device open, and
  working AIX 4.3.3 assigns `BAR0: I/O at 0x1000000` itself once it boots.
  Pre-assigning the BAR from `ibm_40p_init`, or re-asserting it on every reset,
  does **not** help — OF clears it again during its own PCI probe. Both patches
  were tried and reverted; do not re-derive them.

The operator's call was to build the station on 4.3.3 and keep the **4.3.2 Bonus
Packs** on top, which is what the media set below reflects.

## 2. The QEMU work: a graphical 40p

Upstream QEMU's 40p has **no display AIX can use**. `-vga` offers only
`std`/`cirrus`, and a PReP RS/6000 has neither. Every published AIX-on-QEMU
recipe therefore runs `-vga none -nographic` and drives the machine over a
serial line.

Hervé Poussineau wrote an **S3 Trio** card for QEMU in 2017 that was never
merged upstream. It lives on `repo.or.cz/qemu/hpoussin.git` branch `40p`, seven
commits: the card itself (`hw/display/s3_vga.c`, ~1100 lines), the wiring into
the 40p machine, and fixes for planar mode, bitblt, sequencer registers 0x14 and
0x17, and *"colors in RS/6000 System Management Services"* — i.e. he tested it
against real RS/6000 firmware.

Those commits are forward-ported onto our QEMU 11.0.2 in the lab fork, branch
`aix432-s3`. The port is mostly wiring that moved house upstream:

| 2017 | QEMU 11.0.2 |
|---|---|
| `hw/display/Makefile.objs` | `hw/display/meson.build` + `hw/display/Kconfig` |
| `include/sysemu/sysemu.h` (`VGAInterfaceType`) | `include/system/system.h` |
| `vl.c` | `system/vl.c` |
| `#include "vga.h"` | `#include "hw/display/vga.h"` |
| `k->init`, `dc->reset`, `dc->props` | `k->realize`, `device_class_set_legacy_reset()`, `device_class_set_props()` |
| `vga_common_init(s, o, true)` | `bool vga_common_init(s, o, Error **errp)` |

Plus three commits cherry-picked from **artyom-tarasenko/qemu** branch
`40p-20260308-aix-boots`, which exists precisely because AIX needs them:
`lsi53c895a: hide 53c895a registers in 53c810`, `40p and prep: implement PCI bus
mastering` (only the PCI I/O decoding half is still missing upstream — our
raven.c already has the bus-master address space), and the lsi reentrancy fix.

**Proven:** `-vga s3` gives a real 640×480 framebuffer with Open Firmware's
console painted into it, and a reference AIX 4.3.3 boots to `Console login:` on
the same binary.

## 3. Machine facts that will bite

- **`-M 40p` has no IDE.** `block_default_type = IF_SCSI`, so `-hda` and
  `-cdrom` both land on the **LSI 53c810** at `PCI_DEVFN(1, 0)`. The
  `/pci/ide/...` devaliases in the ROM are stale and `dev /pci ls` shows no IDE
  node at all. Booting an explicit `/pci/ide/disk@2,0:2` path just fails.
- **Two `cdrom` aliases exist** and the SCSI one wins: `boot cdrom:2` resolves
  to `/scsi/disk@2`. That is the correct one.
- **RAM is capped.** `-m 512` is refused outright ("try 192 MB"); OF reports
  128 MiB regardless, matching `default_ram_size`.
- **Do not move the SCSI controller.** AIX's bootstrap has
  `pci1000,1@c,0` (device 12) baked into its strings, and the ISA bridge really
  is at `@b` = `PCI_DEVFN(11, 0)`, which makes slot 12 look like the right
  answer. It is not: Open Firmware only enumerates a fixed set of slots and
  moving the LSI to 12 makes it vanish from the device tree entirely, breaking
  boot outright. 4.3.3 boots fine from slot 1.
- The 40p firmware is **Artyom Tarasenko's Open Firmware build**, not OpenBIOS.
  `q40pofw-serial.rom` and `q40pofw-vga.rom` (the graphical variant).

## 4. The blocker: AIX supports no adapter that QEMU emulates

A framebuffer Open Firmware can paint is **not** proof AIX can paint it. AIX 4.3
drives graphics only through adapter-specific filesets, and the GXT130P is
**not** S3-based as first assumed — AIX fileset names are byte-swapped
vendor+device, so `devices.pci.2b102005` decodes as **0x102B:0x0520 = Matrox
Millennium II**.

Enumerating every graphics fileset on both media sets gives the complete list of
adapters AIX 4.3 can drive:

| fileset | adapter | chip |
|---|---|---|
| `devices.pci.2b102005` | GXT130P | Matrox Millennium II (0x102B:0x0520) |
| `devices.pci.2b101a05` | GXT120P | Matrox Mystique (0x102B:0x051A) |
| `devices.pci.0e100091` | H10/S15 | Weitek P9100 (0x100E:0x9100) |
| `devices.pci.1410****` | GXT135P/150P/250P/300P/500P/800P/2000P/2200P/3000P/4000P/4500P/6000P/6500P | IBM proprietary (vendor 0x1014) |
| `devices.mca.*` / `devices.buc.*` | Gt3/Gt4, GXT800M, GXT1000, GXT100/150/150L/155L | MCA / on-board |

**QEMU emulates none of them.** There is no `devices.pci.3353*` fileset, i.e. no
S3 driver of any kind, and nothing for Bochs VGA or Cirrus either. The two
filesets that grep as "trio"/"S3" are false positives (`devices.isa.IBM0010` is
an Ethernet adapter, `devices.isa_sio.PNP0E00` is the PCMCIA bus).

So the ported S3 card gives **Open Firmware** a console — genuinely useful, and
proven — but AIX itself can never bind to it.

### 4.1 The Matrox model: AIX paints its own console

A QEMU device model for the **Matrox MGA** behind the GXT130P was written for
this station (`hw/display/mga.c` on branch `aix432-s3`, selected with
`-vga mga`), and it works:

```
mg20  Available  04-02  GXT130P Graphics Adapter
```

AIX claims the card and **renders its native LFT console into the emulated
framebuffer** — the `AIX Version 4 … login:` banner, drawn by AIX's own font
engine, no serial console and no remote X. That is the first native graphical
AIX under emulation we know of.

Two findings from that work worth keeping:

- **The ODM keys on vendor+device only.** `PdDv devid = 0x2b102005` is just the
  byte-swapped `102b:0520`; the model advertises subsystem `102b:ff03` and
  matched anyway. No IBM subvendor and no particular BAR layout is needed. Note
  a PCI adapter lands in ODM class `adapter/pci`, so it appears in
  `lsdev -Cc adapter`, **not** `lsdev -C -c graphics` (that class holds the
  logical lft/rcm/gxme stack).
- **A genuine QEMU bug was blocking `/dev/lft0` entirely.** AIX's `kbddd`
  selects PS/2 scancode set 3 and programs per-key make/break with `0xFC`
  followed by a *list* of key numbers. QEMU ACKed only the first and RESENT the
  rest, so the keyboard watchdog failed, `lftKiInit` failed (errpt LFTDD/KBDDD)
  and every `/dev/lft0` open failed. Fixed in `hw/input/ps2.c` by continuing to
  ACK key ids until the next command byte.

### 4.2 Why X still does not start — and it is not the display

The X server is blocked one layer *below* the adapter, in AIX's graphics kernel
subsystem, and the failure touches **zero MGA registers**:

- The shared GXT120P/130P GAI module `/usr/lpp/gai/pci2b101a05/loadddx` imports
  exactly **one** kernel symbol and does no direct MMIO: `dump -Tv loadddx`
  shows a single `/unix` import, **`aixgsc`** — the graphics syscall gateway.
- `dump -Tv /unix | grep aixgsc` → **absent**.
- `aixgsc` is exported only when the **RCM** kernel extension initialises, and
  after `mkdev -l rcm0` no rcm/ccm graphics kernext appears in `genkex`;
  `rcm0` and `gxme0` stay `Defined`.
- `gxme0` (Graphics Data Transfer Assist) fails inside `cfggxme_rspc`, which
  enumerates **PReP residual-data** device packets (`get_resid_dev` /
  `get_io_packets`, confirmed by disassembly).

**QEMU has no PReP residual-data code at all** — that structure is built inside
Artyom's Open Firmware ROM, for which there is no source.

### 4.3 X *does* start once the gate is bypassed

Patching a single instruction in the guest's `/usr/lib/drivers/rcm_load`
(forcing the gxme-open check to succeed with a NULL device pointer) proves the
residual-data dependency lives **only** in the config method's device
detection, not in the kernext itself. With that patch:

- `mkdev -l rcm0` → `rcm0 Available` (previously stuck `Defined`)
- `aixgsc` registers — as a dynamically added **syscall gateway**, so
  `dump -Tv /unix | grep aixgsc` still reports 0; the proof it is live is that
  the DDX, which imports exactly that one symbol, now loads instead of dying
- AIX's X server sets **1024×768×8 on the MGA** and paints the X root, and
  CDE's `dtlogin` reaches the same state. Independently verified: the captured
  framebuffer goes from 640×480 to 1024×768 filled with the root colour.

**Client windows still do not render.** `xinit` reports `ioctl: Device busy`,
X spins ~44% CPU, and across an entire X + CDE session the MGA logs **exactly
two register accesses, both mode switches, and zero drawing traffic**. AIX's
GXT130P DDX routes all client rendering through `aixgsc` → the RCM/**gxme**
graphics-DMA subsystem; with gxme stubbed to a NULL device the root fill still
reaches the linear framebuffer through BAR0, but accelerated client blits go
into the stub and vanish.

The conclusion that matters: **that DMA engine does not need writing — AIX
already ships it.** It is inert only because `gxme0` never configured against a
real device, which is the residual-data gate again. So the route to a rendering
desktop is authentic residual data, i.e. **the genuine IBM firmware**
(`rs6k40p.BIN`, archive.org `rs6k40pROM`), which runs under QEMU and paints its
real PowerPC splash on the S3 but currently stalls before boot — ~50% CPU, no
serial. Suspects: the blank `isa-m48t59` NVRAM (real SMS wants a valid layout
and checksum to resolve its console/boot config) or the 8042 keyboard
self-test handshake.

### 4.4 The real IBM ROM boots — and that is what fixes rendering

The genuine firmware (`rs6k40p.BIN`) was **not** stalling on NVRAM or the 8042;
both were traced and behave. It was **panicking**: an infinite LED-flash loop at
0x358c0 displaying the classic RS/6000 crash code **888-102-700-0A5** on an
operator panel QEMU does not have — hence a frozen splash, zero serial output
and ~50% CPU (timebase delay spins).

The assert is *"time went negative"*. During POST the firmware calls
settimeofday; its **604 fallback path** stores the clock offset at 0x3600 as
**negated packed {sec,nsec}**, while get-time adds that value to the timebase
**as ticks**. The real 7020-40P shipped a **601**, whose RTCU/RTCL count
{sec,nsec} natively, and modern QEMU has no 601 model. The firmware also assumes
a **15 MHz** timebase (66.67 ns/tick constants) where QEMU offers 100 MHz.

Two changes make it boot, in about five minutes:

- `PREP_TB_FREQ=15000000` — a new environment override; the default is untouched
  so other rigs are unaffected.
- skipping the single POST `settimeofday` call (`bl` at 0x74da8), currently via
  a small GDB-RSP helper. **This should become a QEMU-side option** rather than a
  gdbstub babysitter; seeding NVRAM with a valid date/config is an untested
  alternative.

With the real ROM in place, its authentic residual data brings up
**`gxme0` (Graphics Data Transfer Assist), `rcm0`, `mg21` and `lft0`** — with
`rcm_load` `cmp`-verified pristine, i.e. the §4.3 guest patch is no longer
needed — and **`paud0` as well**, which also removes the audio re-define chore
in §6. Reproduced across two boots.

One more bug fell here: X spun at 82% CPU polling MGA `FIFOSTATUS` through a
**little-endian** aperture (reading 0x40020000, fifocount mask 0x7F → 0 forever).
The GXT130P presents the G200 registers **big-endian**; BAR1/BAR2 were flipped
to match.

**Result: CDE renders.** The dtgreet login panel draws with the full-colour AIX
diamond, and after login a live session paints dtwm window frames, the backdrop
and the front panel — against the previous state of exactly two register
accesses and zero drawing traffic.

### 4.5 The 2D engine, and what the applications do

`hw/display/mga.c` now implements the drawing path the GXT130P DDX actually
uses: **ILOAD** (mono BMONOWF/BMONOLEF colour-expansion with transparency, plus
BFCOL pixel upload, fed through BAR2/pseudo-DMA — this is how every glyph and
icon arrives), **BITBLT** (overlap-safe, SGN/AR3/AR5), **LINE/AUTOLINE**, TRAP
with rop and planemask, and per-op clipping from CXLEFT/CXRIGHT + YTOP/YBOT.
DWGCTL opcode bits were read off the driver's own disassembly: solid=11,
arzero=12, sgnzero=13, shftzero=14.

Screendump-verified running on the emulated card:

| application | result |
|---|---|
| CDE (dtgreet, dtwm, dtsession, dtfile) | full desktop — text, icons, menus, front panel |
| `aixterm`, `xclock` | live prompt; clean draw/erase |
| **Netscape Communicator 4.08** | fully rendered — toolbar icons, logos, text |
| **Quake 1.07** | **renders and plays its demo loop** — textured geometry, weapon model, HUD |
| Abuse | loads and runs; its `aix_sdrv` sound daemon holds `/dev/paud0`, but the window stays black |
| CorelDRAW 3.5 | **will not load** — see below |

Quake tints the whole screen olive: it installs its own colormap on the 8-bit
PseudoColor visual, which is period-correct colormap flashing, not a defect. It
needs `LIBPATH=/usr/lpp/som/lib:/usr/lib` because it links `som.dll` and
`UMSobj.dll`.

**CorelDRAW is blocked on a library that AIX 4.3 does not ship.** Its bundled
`libwix_sh.a` imports from `libX11.a(shr.o)` — the AIX **3.2**-era member — and
every libX11 on 4.3.3 (`/usr/lib`, and the R4/R5 compat trees from
`X11.compat.lib.X11R3/R4/R5`) contains only `shr4.o`/`shr4net.o`. Presenting
`shr4.o` under the name `shr.o` in a private archive gets further but then fails
on `Symbol readv (number 345) is not exported`, because the 3.2 libX11
re-exported the socket helpers and the R6 one does not. Synthesising a shim
needs a C compiler, and AIX's is a separately licensed product that is not
installed. Recorded as a dead end rather than re-derived later.

**Audio is proven at the device level.** `paud0` now configures itself from the
real firmware's residual data — no `odmadd`/`mkdev` dance — and Abuse's own
`aix_sdrv` daemon holds `/dev/paud0` open with real CPU time against it.
Capturing the waveform (`-audiodev wav,id=snd0,path=…`) has not been done, since
it costs a full reboot.

Remaining device-model gaps, all cosmetic or small: the **hardware cursor**
(XCURCTRL mode 3 — the pointer is invisible), strict `CXRIGHT==0` clip semantics
(stale spokes when a window maps), ILOAD BFCOL implemented for 8bpp only, and
TRAP pattern fills drawn solid.

This is also **why** the Virtual OS Museum resorted to XDMCP — not laziness, but
the same wall:

> **VOM's "graphical AIX" is not graphical.** Their AIX 4.3.3 runs
> `-bios q40pofw-serial.rom -vga none -nographic`; the CDE screenshot in their
> metadata comes from `run-xephyr.sh`, which is `run_nested_x11 -query
> 172.16.0.14 :1` — an XDMCP session into the guest from a host-side Xephyr,
> with host-supplied fonts. That is rendering to a remote X server, which this
> lab has ruled out for this station. Tellingly they ship `q40pofw-vga.rom` and
> never use it.

Also known, from IBM's own release notes: **Quake2 for AIX is supported only on
the GXT3000P**, a 3D accelerator nothing emulates. Quake 1.07 and Abuse need
X11 with MIT-SHM plus Ultimedia Services for audio.

## 5. Media

All agent-sourced, staged `/data/assets-staging/aix432/` with a
`MANIFEST.sha256`. Preservation class throughout — IBM commercial software, no
redistribution grant. Private exhibit only: never committed, never served.

| what | where from |
|---|---|
| AIX 4.3.2 CD1-3, **Bonus Pack CD1+CD2**, base + extended docs | archive.org item `ibm-aix-4.3.2` |
| AIX 4.3.3 Volumes 1-4 (the base that boots) | fsck.technology `IBM/AIX Install Media/RS6000/IBM AIX 4.3.3/LCD4_0286_07 (ISO)` |
| **AIX 4.3.2 Support Software for GXT130P** `[03N4022]` | archive.org item `AIX4.3.2SupportSoftwareForGXT130P03N4022` (MDF/MDS) |
| CorelDRAW 3.5 for UNIX (Sept 1995; AIX/POWER build) | fsck.technology `IBM/AIX Applications/Corel Draw 3.5 UNIX/coreldraw35unix.iso` |
| Quake 1.07, Quake2 3.17 demo, Abuse — AIX/PowerPC builds | **IBM's own public server**, `public.dhe.ibm.com/aix/freeSoftware/games/` |
| `q40pofw-serial.rom`, `q40pofw-vga.rom` | 40p Open Firmware (Artyom Tarasenko builds) |

The games are the one clean-licence item: IBM published them itself, Quake
"distributed by IBM with permission from id Software", shareware `pak0.pak`
included.

## 6. What is built, and the audio result

Disk images under `/data/vms/sandbox/aix432/base/`:

- `aix433-base.qcow2` — bare AIX 4.3.3, boots to `Console login:`
- `aix433-x11-ums-games.qcow2` — plus X11/CDE, Ultimedia Services, Quake, Abuse
- `aix433-full.qcow2` — plus CorelDRAW 3.5

Installed on top of the base: **X11 R6 + Motif 2.1 + CDE** (38 filesets),
**Ultimedia Services** (`UMS.objects` 2.2.1.2, `UMS.samples`) from the 4.3.2
Bonus Pack, plus the SOM runtime it drags in. Applications: **Quake 1.07** in
`/apps/quake`, **CorelDRAW 3.5** in `/apps/corel3.5` (the whole suite —
`coreldraw`, `corelchart`, `corelpaint`, `corelshow`, `coreltrace`,
`corelmosaic`), **Abuse** in `/usr/lpp/abuse`. A 1 GB `/apps` JFS was created and
`/usr` grown, because the default BOS install leaves `/usr` with ~25 MB free.

All three applications are X11 clients, so all three are gated on §4:

| binary | links against |
|---|---|
| `quake.sw` | `libX11.a`, `libXext.a`, **`UMSobj.dll`**, `som.dll` |
| `xabuse` | X11, ships its own `aix_sdrv` sound driver |
| `coreldraw` | `libX11.a` + its bundled `libwix_sh.a` (WiX toolkit, not Motif) |

**Audio works at the driver level, and the resource match is exact.** AIX's
`devices.isa_sio.IBM000E` is *"AIX Ultimedia Services RISC PC Audio Device
(CS4231)"*, ODM prefix `paud`, and its predefined attributes are:

```
bus_io_addr    0x830      bus_intr_level 10
play_dma_level 6          cap_dma_level  7
```

QEMU's 40p instantiates a `cs4231a` at **iobase 0x830, IRQ 10** — exactly those
values. Install the fileset, and `paud0` goes **Available** with `/dev/paud0`
live. QEMU defaults that codec to DMA 3, so the launcher must pass
`-global cs4231a.dma=6` to match what AIX expects; `-M 40p,audiodev=<id>` binds
the backend.

Two caveats, both measured:

- **`paud0` does not survive a reboot.** QEMU's `cs4231a` is a plain ISA device,
  not ISA-PnP, so it is absent from the firmware PnP data `cfgmgr` rebuilds the
  ISA device list from, and `define_rspc` refuses `mkdev` outright
  ("the specified connection is not valid"). The device has to be re-created
  each boot by adding a `CuDv` stanza with `connwhere = "IBM000E"` via `odmadd`
  and then `mkdev -l paud0` — fine from a boot script, and the honest long-term
  fix is teaching QEMU's `cs4231a` to answer ISA PnP as `IBM000E`.
- **UMS's own `audio_play` cannot instantiate its file object** ("Error code=9")
  for `.WAV` or `.snd`, with or without `SOMIR` pointing at
  `/usr/lpp/UMS/etc/UMS.ir`. Since Quake links `UMSobj.dll` directly and Abuse
  ships its own `aix_sdrv`, the applications are the real audio test, not this
  tool.

**There is no boot chime.** With QEMU capturing all codec output
(`-audiodev wav,...`), a full firmware boot produces no capture file at all —
Artyom's Open Firmware never drives the CS4231. An `isa-pcspk` does exist in the
machine (from the super-I/O, not `prep.c`), but nothing sounds it during POST.

## 7. Sources

- Artyom Tarasenko, *AIX/PReP under QEMU How-To* and the `40p-*-aix-boots`
  branches — <https://github.com/artyom-tarasenko/qemu>
- Hervé Poussineau's S3 Trio work — <https://repo.or.cz/qemu/hpoussin.git> `40p`
- *Installing AIX on Qemu!* / *Revisiting AIX 4.3 on Qemu*, Virtually Fun
- IBM Quake for AIX FAQ —
  <https://public.dhe.ibm.com/aix/freeSoftware/games/Quake/quakefaq.html>
- Virtual OS Museum — read as reference only, per
  [`vom-reference.md`](vom-reference.md)

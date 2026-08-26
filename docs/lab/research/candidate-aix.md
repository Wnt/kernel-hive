# Candidate: AIX on an emulated PowerPC RS/6000

**Target: IBM AIX 4.3 on `qemu-system-ppc -M 40p`, with a native framebuffer.**
Tier 1, direct framebuffer capture, firmware ROM required. The station id is
`aix432`.

**Status (2026-08-26): OS and applications built; blocked on a display adapter.**
AIX 4.3.3 is installed with X11/CDE, Ultimedia Services, Quake, Abuse and
CorelDRAW 3.5, and AIX's own audio driver binds to the emulated CS4231. The one
thing missing is a graphics adapter AIX can drive — see §4, which is the whole
ballgame and is **not** solvable by installing something.

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
Artyom's Open Firmware ROM, for which there is no source. So reaching X means
firmware work, not device work, and is out of reach by this route. The exhibit
that *is* reachable today is AIX's native LFT console on the MGA.

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

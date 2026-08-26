# Candidate: AIX on an emulated PowerPC RS/6000

**Target: IBM AIX 4.3 on `qemu-system-ppc -M 40p`, with a native framebuffer.**
Tier 1, direct framebuffer capture, firmware ROM required. The station id is
`aix432`.

**Status (2026-08-26): emulator proven, base OS installing.** The QEMU work is
done and verified against the framebuffer; the base install runs. What is *not*
yet proven is the piece the whole exhibit rests on — whether AIX's own X server
will drive the emulated S3 (see §4).

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

## 4. The open risk: AIX's X server on an emulated S3

A framebuffer that Open Firmware can paint is **not** proof that AIX can. AIX
4.3 drives graphics through adapter-specific filesets, and the only emulated
card is an S3 Trio. The bet is IBM's **GXT130P** support software (a 2D S3-based
PCI adapter for the RS/6000, driver disc sourced in §5) binding to it.

If that bet fails, the exhibit has no native desktop, because the alternative —
what the Virtual OS Museum does — is not one:

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

## 6. Sources

- Artyom Tarasenko, *AIX/PReP under QEMU How-To* and the `40p-*-aix-boots`
  branches — <https://github.com/artyom-tarasenko/qemu>
- Hervé Poussineau's S3 Trio work — <https://repo.or.cz/qemu/hpoussin.git> `40p`
- *Installing AIX on Qemu!* / *Revisiting AIX 4.3 on Qemu*, Virtually Fun
- IBM Quake for AIX FAQ —
  <https://public.dhe.ibm.com/aix/freeSoftware/games/Quake/quakefaq.html>
- Virtual OS Museum — read as reference only, per
  [`vom-reference.md`](vom-reference.md)

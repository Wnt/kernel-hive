# NeXTSTEP 3.3 (Intel) gallery tile (:8109) — integration notes + findings

**Status: NOT LIVE. GUI not reached. Do NOT wire into the :8080 index.**

Reproducible build script: `scripts/build-guests/nextstep.sh` (bash -n clean).
Assigned: VMID **1040**, tile port **:8109**. Host work dir used during R&D:
`/data/gallery-guests/NeXTSTEP` (media) + `/data/nextstep-build-1040` (scratch).

---

## TL;DR

NeXTSTEP 3.3 for Intel **installs and runs only on QEMU ≤ 0.9.x** (the
busmouse-patched Michael Engel build) or under the **Previous** emulator (m68k
cube, needs a copyrighted NeXT ROM). On this host's **QEMU 10.0.8** the install
gets as far as the NeXT Mach kernel booting + **detecting both drives** (the CD
labelled `NEXTSTEP_3.3` + the IDE hard disk), then dies the moment it starts
real bulk I/O:

```
sd0: Bus Reset Detected; FATAL            <- SCSI CD  (lsi53c810)
hc0: interrupt timeout, cmd: 0xc4 ...     <- IDE disk (PIIX3)
hc0: ATA command c4 failed. Retrying..
Load of /etc/mach_init failed, errno 5    <- EIO; installer aborts
Load of /etc/init failed, errno 5
```

Root cause: NeXTSTEP 3.3's 1994-era SCSI/IDE drivers do not get reliable
completion **interrupts / DMA** from QEMU 10 once sustained transfers begin.
Reproduced under **both TCG and KVM**. This matches the public record
(gunkies, emaculation, 86Box #356, PCem, QEMU LP#1471904): "install fails right
after the floppies are read in."

No pre-built NeXTSTEP/OPENSTEP Intel disk image exists on archive.org (only the
install media), and a pre-built image would hit the same runtime I/O wall on
QEMU 10 anyway.

---

## Media (Internet Archive — copyrighted media, free to use in this private collection)

Item **`NeXTSTEP33CISC`** (https://archive.org/details/NeXTSTEP33CISC):
- `NeXTSTEP_3.3_User_(i386_m68k).iso` (~356 MB, a 4.3BSD-FFS disc, **not**
  ISO-9660 — label reads `NEXTSTEP_3.3`, 2048-byte blocks).
- Floppies: `3.3_Boot_Disk.img`, `3.3_Core_Drivers.img`, `3.3_Beta_Drivers.img`,
  `3.3_Addl_Drivers.img` (1.44 MB each). No NeXT ROM used/needed on Intel.

The script re-fetches all of the above from scratch.

---

## The one QEMU-10 recipe that reaches hardware detection

```
qemu-system-i386 -machine pc,acpi=off -cpu pentium -m 64 \
  -rtc base=1995-06-15T12:00:00,clock=vm \
  -drive file=ns33.qcow2,format=qcow2,if=ide,index=0,media=disk \      # HD on IDE
  -device lsi53c810,id=scsi,romfile= \                                 # CD on SCSI
  -drive file=NeXTSTEP_3.3_User.iso,format=raw,if=none,id=cd0,readonly=on \
  -device scsi-cd,bus=scsi.0,scsi-id=0,drive=cd0 \
  -fda 3.3_Boot_Disk.img -boot a -vga std -net none
```

Installer driver-selection (framebuffer-validated `sendkey` macro — see script):
English(1) → prepare(1) → insert **Core**(blank list) → insert **Additional
Drivers** → CD-ROM = **Symbios Logic 53C8xx** (page 3, opt 3) → HARD DISK =
**IDE Disk Controller** (page 3, opt 5) → continue(1). The Mach kernel then
prints `sd0: ... NEXTSTEP_3.3` + `hd0: ... 499 MB`, and — fatally — the I/O
death above.

Key gotcha discovered: the installer's **CD-ROM** driver menu lists *only* SCSI
adapters; the EIDE/IDE "hard-disk controllers" are hidden there and appear only
on the **HARD-DISK** menu. That's why the CD must go on SCSI and the disk on IDE.

---

## Every controller/driver permutation tried (and why each fails on QEMU 10)

| CD-ROM bus / NS driver            | Hard disk bus / NS driver        | Result on QEMU 10 |
|-----------------------------------|----------------------------------|-------------------|
| am53c974 (both devices, 1 target) | am53c974                         | phantom 8-LUN scan; **READ CAPACITY = 0 KB** (NS AMD driver ≠ QEMU am53c974); also QEMU option-ROM exec bug LP#1471904 (dodge with `romfile=`) |
| lsi53c810 (both devices)          | lsi53c810                       | correct sizes; **reads ~35k blocks then `Bus Reset Detected` → FATAL** (QEMU LSI SCRIPTS/disconnect) |
| lsi53c895a                        | —                               | NS **`SYM53C8: Can't find this PCI device; ABORTING`** — 53C895A PCI id 0x0012 too new for NS driver v3.33 |
| IDE ATAPI (CD) + IDE (disk)       | "EIDE and ATAPI Device Ctrl"    | detects both, then **hangs forever at `hc0: Resetting drives..`** (ATAPI soft-reset never completes) |
| **lsi53c810 (CD)**                | **IDE "IDE Disk Controller"**   | **furthest**: both detected + IDE reset OK, then **IDE `interrupt timeout` + SCSI `Bus Reset FATAL`** → `errno 5` |

Also tried, no effect on the I/O wall: TCG vs `-enable-kvm`; `-rtc` fixed 1995
date (the `preposterous time in Real Time Clock` warning is cosmetic — reads
still progressed with it). Disk kept <504 MB to avoid NS large-disk CHS traps.

---

## Proposed tile row (for the orchestrator) — **DISABLED / placeholder only**

If/when a faithful runtime exists (QEMU 0.9 sidecar, or a Previous+ROM tile),
this is the intended standalone compose service, mirroring the Sailfish/TempleOS
isolation pattern (its OWN compose project; do not touch the shared
`docker-compose.gallery-guests.yml`). **Left commented until GUI is confirmed.**

```yaml
# scripts/... docker-compose.nextstep.yml  (NOT DEPLOYED — GUI unconfirmed)
# services:
#   nextstep:
#     image: neko-qemu:latest
#     restart: unless-stopped
#     shm_size: 1gb
#     ports: ["8109:8080","53320-53339:53320-53339/udp"]   # next free EPR block
#     volumes: ["./gallery-guests:/guests:ro"]
#     devices: ["/dev/kvm:/dev/kvm"]
#     environment:
#       NEKO_SCREEN: "1280x720@30"
#       NEKO_PASSWORD: "neko"
#       NEKO_PASSWORD_ADMIN: "admin"
#       NEKO_EPR: "53320-53339"
#       NEKO_ICELITE: "true"
#       NEKO_NAT1TO1: "192.0.2.12"
#       NEKO_SESSION_IMPLICIT_HOSTING: "true"
#       OS_NAME: "NeXTSTEP 3.3"
#       QEMU_MEM: "64"
#       QEMU_MACHINE: "pc,acpi=off"
#       QEMU_VGA: "std"
#       GUEST_DISK: "/guests/NeXTSTEP/ns33.qcow2"   # would need a WORKING image
#       GUEST_FMT: "qcow2"; GUEST_IF: "ide"; GUEST_BOOT: "c"
#       QEMU_EXTRA: "-cpu pentium -device lsi53c810,id=scsi,romfile="
```
Manifest-array row shape (same schema as sibling notes), for reference:
`"qemu|nextstep|NeXTSTEP 3.3|64|1|pc,acpi=off|std|-device AC97,audiodev=snd|GUEST_DISK=/guests/NeXTSTEP/ns33.qcow2 GUEST_FMT=qcow2 GUEST_IF=ide GUEST_BOOT=c|-cpu pentium -device lsi53c810,id=scsi,romfile=|advanced"`

Port 8109 fixed-port line: `declare -A FIXED_PORT=( [nextstep]=8109 )`.
`launch-qemu.sh` change required: **none** (uses only stock env vars).

---

## What a future integrator should do to make this tile real

1. **Best faithful Intel path:** stand up a **QEMU 0.9.0** sidecar (Engel's
   busmouse-patched build; sources archived at archive.org item
   `qemuwin32-nextstep-mingw32`). Complete the interactive install once under
   0.9 (mouse works there), snapshot the resulting `ns33` disk, then serve that
   golden disk. Whether the *installed* disk then boots under QEMU 10 for the
   live tile needs testing — if it hits the same I/O wall, run the tile itself
   on the 0.9 sidecar behind neko (neko can stream any X app / any QEMU).
2. **Authentic cube path:** the **Previous** emulator (m68k) + a NeXT ROM
   (`Rev_2.5_v66.BIN`, copyrighted — free to use in this private collection, just
   don't re-distribute the ROM binary via the GitHub repo) gives the real NeXTcube
   experience; neko can stream Previous's window like any X app.
3. Either way: framebuffer-verify the **grey workspace + right-hand Dock**
   before wiring into `/opt/osgallery/gallery/index.html` and the standalone
   compose service.

---

## SPA / placard metadata

- Year **1995**; NeXT (Steve Jobs) lineage; Mach 2.5 + 4.3BSD + Display
  PostScript; direct ancestor of macOS/iOS (Cocoa = the NeXT `NS*` API).
- Iconic software: Workspace Manager, Dock, Interface Builder, Mail.app,
  Digital Librarian, Edit; the OS Tim Berners-Lee wrote the first web browser on.
- **Ideal SPA model: a matte-black NeXT cube** (or the NeXTstation "slab" +
  MegaPixel mono monitor). Closest existing archetype: `mono-terminal` /
  `apple-studio`. A bespoke black-cube model is the right long-term asset.

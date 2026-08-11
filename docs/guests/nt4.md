# nt4 guest — Windows NT 4.0 Workstation SP6a

Status: **LIVE** (production streamhost station, VMID 89 / UDP 54089). The curated
checkpoint auto-logs on as Administrator to a clean accelerated
1024x768x65,536-color (16bpp) Explorer desktop, uses true absolute vmmouse
input, and resets with `loadvm golden`.

GH issue #23. Catalog: `docs/catalog/os-media-catalog.md` §4 "Windows NT rungs".

## Identity and source

- Public ID / station directory: `nt4`
- Reserved slot / UDP port: `89` / `54089`
- Archetype: `putty-lcd`
- OS: **Windows NT 4.0 Workstation, Service Pack 6a** (i386),
  preservation-licensed. NT4 still reports "Service Pack 6"; installed hotfix
  `Q246009` is the offline registry proof that this is the SP6a level.
- Media (skip-install path used): archive.org **preinstalled VMDK** —
  item `windows-nt-4.0-workstation-vmdk`, file `Windows NT Workstation 4.0.zip`
  (121 MB zip → single 458 MB monolithicSparse `.vmdk`, 8 GiB virtual, NTFS).
  URL: <https://archive.org/download/windows-nt-4.0-workstation-vmdk/Windows%20NT%20Workstation%204.0.zip>
  `qemu-img convert -O qcow2` the `.vmdk` → `nt4-golden.qcow2` (skips the installer).
  Fallback: WinWorldPC NT4 Workstation ISO (~312 MB) + full setup.

## Build and device set

- Builder: `scripts/build-guests/tiles/nt4.sh` (download → convert → offline boot.ini
  fix → framebuffer-verify).
- Canonical output: `/data/gallery-guests/Nt4/nt4-golden.qcow2`.
- Device set (catalog §4 recipe; pins matter — see gotchas):

  ```
  -enable-kvm -m 128 -smp 1
  -machine pc-i440fx-11.0,hpet=off,vmport=on -cpu pentium3
  -rtc base=localtime
  -device isa-cirrus-vga,global-vmstate=on
  -drive file=nt4-golden.qcow2,format=qcow2,if=ide
  -netdev user,id=n0 -device pcnet,netdev=n0
  -display dbus,p2p=on
  ```

### Hard gotchas (verified 2026-07-27)

1. **`-cpu pentium3`** — the host CPU model BSODs NT4. pentium3 is the newest
   model NT4's kernel tolerates.
2. **`-smp 1` (uniprocessor HAL only)** — the image ships the UP HAL; SMP → hang/STOP.
3. **`hpet=off`** — HPET disturbs NT4's HAL timer bring-up.
4. **`vmport=on`** — QEMU 11 automatically instantiates its built-in `vmmouse`
   on i8042. The preserved NT4 VMware mouse driver consumes that device as true
   absolute input. Do not add a second explicit `-device vmmouse`: QEMU 11
   rejects the duplicate because it has no second i8042 link.
5. **Pinned ISA Cirrus QEMU** — the accelerated SP6a Cirrus display driver
   requires `/opt/qemu-cirrusfix2/bin/qemu-system-i386 -L /usr/share/kvm`.
   That build contains patch 0004 for ROP1 fills and patch 0005 for ISA Cirrus
   vmstate substructure restore. Stock QEMU corrupts accelerated redraws, and a
   0004-only binary restores `loadvm golden` as blue/lavender. Rebuild and
   framebuffer-reverify the dedicated binary whenever the packaged QEMU
   version changes. Do not replace `/opt/qemu-cirrusfix`, which remains the
   separately versioned NT 3.51 dependency.
6. **`-device pcnet`** — retained as part of the Stage-1 pinned hardware
   contract. The archive's AMDPCN driver does not bind to this QEMU instance and
   is disabled in the curated checkpoint; the gallery surface needs no guest network.
7. **System partition ≤ 4 GB** — matters only for a *fresh install*; the
   preinstalled image already boots, so it is moot for the skip-install path.
8. **boot.ini ARC path — THE blocker for the prebuilt VMware image.** The image
   was built on a BusLogic **SCSI** controller, so `boot.ini` uses
   `scsi(0)disk(0)rdisk(0)partition(1)\WINNT` and expects `ntbootdd.sys` (a copy
   of the SCSI miniport). Under QEMU we present an **IDE** disk and `ntbootdd.sys`
   is absent, so NTLDR ("OS Loader V4.01") prints *"Could not read from the
   selected boot disk"*. Fix: rewrite the ARC path `scsi(0)` → `multi(0)` (both
   lines in `boot.ini`) so NTLDR reads the disk via INT13h/IDE. Applied offline
   (ntfs-3g mount of the qcow2 over qemu-nbd). The NTFS BPB geometry (63 spt /
   255 heads / hidden 63) and MBR start-CHS (`01 01 00` = LBA 63) already match
   SeaBIOS's 8 GB translation, so no MBR/VBR byte surgery is needed (unlike the
   win2000 image). `atapi.sys` is already a boot-start driver in the hive, so no
   MergeIDE / STOP 0x7B fix is required either.

## First-light (2026-07-27)

On a namespaced clone under `/data/vms/soltest/` with the recipe above:

1. Cold boot → NTLDR "OS Loader V4.01" (proves the NT boot chain executes).
2. After the boot.ini `scsi→multi` fix → the "Microsoft Windows NT Workstation
   4.0" GUI boot splash, then the **full Explorer desktop** via Administrator
   auto-logon (My Computer / Network Neighborhood / Recycle Bin, Start bar, clock).
3. Cosmetic: a `Dr. Watson` dialog for `VMwareService.exe` (privileged-instruction
   `0xc0000096`) — the leftover VMware Tools service faulting on the VMware
   backdoor I/O port outside VMware. Harmless; Stage 2 removes VMware Tools.

## Stage-2 curation, input, and checkpoint

- Cleanup preserves `WINNT/system32/drivers/vmmouse.sys` and its `i8042prt`
  binding, but disables the crashing VMware Tools service and user programs.
  Unused archive drivers that produced the startup warning (`BusLogic`,
  `ctpcint4`, and `AMDPCN`) are disabled. Administrator auto-logon is enabled
  and the Administrator/Default/legacy profile screen savers are off.
- The SP6a `cirrus.sys` and `cirrus.dll` payloads are installed, and Display
  Properties selects adapter `Cirrus Logic ... CL 5430`, `65536 Colors`,
  `1024 by 768 pixels`, and `70 Hertz`. The production device is
  `isa-cirrus-vga,global-vmstate=on`; the PCI Cirrus device does not bind this
  NT4 miniport.
- **True absolute pointer:** `vmport=on` exposes QEMU's built-in vmmouse and the
  existing NT4 VMware driver consumes the absolute coordinates directly.
  Streamhost therefore uses `--pointer abs`, scale `1.0`, offset `(0,0)`.
  A five-position raw framebuffer grid landed within one pixel at 10/10,
  50/10, 90/10, 25/75, and 75/75 percent. The genuine UI path landed within
  two pixels at the same targets; browser Ctrl+Esc visibly opened Start.
- Reset mode is `loadvm`; checkpoint `golden` lives inside the standalone
  `nt4-golden.qcow2`. The final gate saved once, then launched three independent
  QEMU processes plus a final fresh process with `-loadvm golden`. All pre-save,
  post-save, and fresh-load idle PPMs are byte-identical at SHA-256
  `4f35ac3b50ee031543781740209f21bc9d5f30ca9ac978ca01c10b2d2c30db42`.
- Promotion proof root:
  `/data/vms/soltest/nt4-cirrus-promote-20260728T-SAP4aj/`.
  `acceptance/` contains the three full adversarial raw-QMP runs:
  ten Notepad Page Downs, a window drag across the desktop icons, an icon move,
  the five-position pointer grid, the visible mode panel, and every fresh-load
  idle frame. `live-proof/` contains the deployed `labctl`/QMP frames and the
  decoded UI screenshots.
- The pre-promotion production disk is
  `/data/vms/streamhost/stations/nt4/nt4-golden.qcow2.bak-preHiRes-20260728T110112Z`
  (SHA-256
  `76f1fb0e11aee51ded7b8b75e203984f7a0b97d2fad5c2d3addd7b660684b487`).
- Credentials reference only (never values): `guest/nt4`.
- Rebuild/rollback source remains `scripts/build-guests/tiles/nt4.sh`; production
  always boots the station-local copy under `/data/vms/streamhost/stations/nt4/`.

## Patched-QEMU maintenance

Production pins:

```text
/opt/qemu-cirrusfix2/bin/qemu-system-i386 -L /usr/share/kvm
```

The binary is pve-qemu 11.0.2 with
`streamhost/qemu-patches/0004-cirrus-blt-rop1-fill.patch` and
`streamhost/qemu-patches/0005-cirrus-isa-vmstate-descend-substruct.patch`.
Patch 0004 is required for clean accelerated scroll and window redraw. Patch
0005 descends the ISA Cirrus vmstate substructure so a fresh process restores
the same framebuffer bytes saved by `savevm golden`. On a QEMU version change,
rebuild this dedicated path and repeat the raw framebuffer gate before updating
the station. NT4 does not need gallery-hid patch 0003 because input is vmmouse.

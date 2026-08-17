# beos guest — BeOS R5 Professional 5.0.3

Status: **bring-up in progress** (Tier 2, disabled candidate; dark-launched for
review, not yet in the public lineup). Booted, installed, and interactive on a
`/data/vms/sandbox/beos-r5` rig; the two real R5-under-QEMU blockers are
diagnosed and fixed. What remains open is listed at the bottom.

The deliberate pairing this exhibit exists for: `haiku` is the open-source
recreation, already live; `beos` is the original it recreates. See
[`docs/guests/haiku.md`](haiku.md).

## Identity and source

- Public ID / tile directory: `beos`
- Reserved slot / UDP port: `143` / `54143`
- Archetype: `beige-tower-crt`
- OS: **BeOS R5 Professional 5.0.3** (2000, Be Inc.), x86.
- Media: archive.org item **`beos-5.0.3-professional-gobe`**
  (preservation-class — Pro edition media; the freeware Personal Edition is a
  different, smaller item and is NOT what this station runs).
  - `beos-5.0.3-professional-gobe.bin` — 772,302,720 bytes,
    SHA-256 `1889fd6cf5af4259b01c9d1925e62f664effdf9dd88f924dc9b4da41ce1f0106`,
    SHA-1 `a4bfd56ca3ada6b33ba74951bd10cce2589afaf3`
  - `beos-5.0.3-professional-gobe.cue` — 186 bytes,
    SHA-256 `a57d9552cdadbbdbe6f608e8dbe9ac2bec2a010da1ad801fc0176e4d66bb234c`
  - archive.org's download redirector returns HTTP 500 for this item; fetch by
    resolving the item's metadata JSON (`server`/`dir` fields) to the direct
    storage-node URL `https://<server>/<dir>/<file>` instead of the redirector.
  - Staged on the box at `/data/assets-staging/beos/` with a `MANIFEST.sha256`.
- Three MODE1/2352 tracks on the disc, split into per-track 2048-byte images
  with a small Python script (no `bchunk` on the box):
  1. bootable ISO 9660 volume `BeOS_Tools` (the Intel BIOS-bootable
     installer/rescue CD)
  2. the raw BFS **`BeOS 5 Pro Edition`** system volume (325 MB) — this is what
     gets copied onto the station's disk
  3. other/PPC content, unused by this station

## Install method

QEMU cannot present a multi-track CD image, so the disc's own installer is not
usable directly. The station's system volume was built by copying files, not
by running BeOS's Installer:

1. `sfdisk` an MBR partition table on a fresh disk image: one partition, type
   `0xEB` (BFS), starting at sector 63, marked bootable. MBR boot code is
   Haiku's `writembr` (BeOS and Haiku share the same MBR loader convention).
2. Create a fresh BFS filesystem in that partition and copy the track-2 BFS
   volume's files onto it **with attributes** (BFS attributes carry file
   type/icon/index metadata BeOS depends on) using a Haiku R1/beta5 helper VM
   — a sandbox clone of the `haiku` station's persistent disk, reached over
   ssh, since Haiku's BFS driver and attribute-copy tools are the only
   readily-available BFS-aware tooling on the box.
3. Write R5's own stage-1 boot sector (the first 512 bytes of the track-2 BFS
   volume) into the partition's first sector. On its own it says "Error
   loading OS": BeOS's `makebootable` embeds zbeos's block location in that
   sector and the fresh volume has zbeos elsewhere — so the *first* boot goes
   through the CD loader (track 1 as CD-ROM, `-boot d`), which lists the
   partition as "BeOS 5 Pro Edition" and boots it as the boot volume.
4. In that first boot, `/boot/home/config/boot/UserBootscript` runs BeOS's own
   `makebootable /boot` (and opens a Terminal); after `sync` the disk boots
   directly (`-boot c`, no CD). Only disk boot honours the volume's
   `home/config/settings/kernel/drivers/{vesa,kernel}` files — the CD loader
   reads the CD's — so the station always boots the disk.

Reproducible as a builder script: `scripts/build-guests/tiles/beos.sh`
(written from this recipe; not yet run end-to-end — see its PROOF STATUS).

## The two real blockers

Both are R5-under-modern-QEMU problems, not media problems. Neither is fixed
by the BeOS boot menu's "Don't call the BIOS" toggle, which does not cover
either.

### Blocker 1 — ISA config manager calls the PnP BIOS; SeaBIOS doesn't answer it

R5's ISA bus config manager
(`beos/system/add-ons/kernel/busses/config_manager/isa`) calls the legacy
16-bit PnP BIOS entry point during driver enumeration. SeaBIOS does not
implement it. The call faults: a kernel page fault (`eip 8`) inside the
`input_server` team during its devfs driver scan. `input_server` never starts,
`Bootscript` hangs forever at `waitfor _input_server_event_loop_`, and
`app_server` paints only the flat desktop colour — no cursor, no Tracker, no
Deskbar. The desktop looks "on" but is completely uncontrollable.

Diagnosed from the kernel debugger (KDL)'s output on COM1 — KDL always mirrors
to serial regardless of video state, which is the only way to see anything
once `app_server` is stuck. `serial_debug_output` was enabled precisely to get
this trace (see Settings below).

**Fix**: remove the add-on from the boot path — move
`config_manager/isa` to `config_manager_off/isa` on the installed volume. R5
does not require the ISA config manager to enumerate the PCI devices this
station's device set uses.

### Blocker 2 — KVM traps the idle thread with modern CPU models; TCG doesn't

Under KVM with `-cpu pentium2` or `-cpu pentium3`, the R5 kernel general-
protection-faults (trap `0d`) in the idle thread almost immediately after
boot. With `-cpu qemu32` it gets further but still hangs later. Under **TCG**
with `-cpu pentium3` the same kernel runs cleanly through boot, install-file
copy, and interactive desktop use. The pattern (works under an interpreter,
faults under KVM, only on models advertising extra CPUID features) is
consistent with R5 reading an MSR that KVM does not implement — KVM injects a
real `#GP` on an unhandled MSR access, while TCG's MSR read path returns 0
instead of faulting, which is exactly what a kernel written years before KVM
existed assumes.

**Fix**: TCG only, same posture as `os2warp`. Not investigated further because
TCG is fast enough for a museum station and does not risk a fleet-wide "which
MSR" hunt for one exhibit; left as an open question below in case KVM is
worth revisiting later.

## Device set

```
qemu-system-x86_64 -accel tcg -M pc-i440fx-11.0 -cpu pentium3 \
  -m 512 -smp 1 -rtc base=localtime \
  <one IDE raw/qcow2 disk> \
  -vga std \
  -device ne2k_pci,netdev=n0 -netdev user,id=n0 \
  <PS/2 keyboard + PS/2 mouse> \
  <no audio device — see Open items>
```

- `-smp 1`: R5 is single-CPU era; matches the `os2warp` TCG posture.
- `-m 512`: R5's kernel caps usable RAM below 1 GB; 512 MB is comfortably
  under that ceiling and enough for a responsive desktop.
- `-vga std` (Bochs VBE): R5 treats plain/std VGA as the **"stub/unsupported"**
  graphics driver and shows a "graphics card not supported" nag on first
  login — dismissed with **Don't nag** (writes
  `home/config/settings/stop_vga_nagging`). This is cosmetic; the framebuffer
  itself works fine at the configured VESA mode.
- NIC: `ne2k_pci`. R5 also ships an `rtl8139` driver if a different NIC model
  is ever needed.
- Pointer: **PS/2, relative**. R5 predates broad USB HID/absolute-pointer
  support in its driver stack (unlike Haiku, which has a full USB stack and
  uses `usb-tablet`). BeOS applies its own mouse acceleration on top of the
  relative PS/2 stream; `usb-tablet` (absolute) is **not supported** by R5 and
  was not attempted as the pointer path.
- Audio: none (see Open items — both R5-supported QEMU codecs stall the guest).
- Pointer path: `--pointer rel` with the UI's `pointerRel: true` (browser
  pointer-lock, the qnx pattern) — raw PS/2 deltas, BeOS's own acceleration.

## Settings applied on the volume

- `/boot/home/config/settings/kernel/drivers/vesa`: `mode 1024 768 16`
  (R5 defaults to 640×480 greyscale without this).
- `/boot/home/config/settings/kernel/drivers/kernel`:
  `serial_debug_output true`, `serial_debug_port 0x3f8`,
  `bochs_debug_output true`, `load_symbols enabled` — kept in place rather
  than reverted; harmless at runtime and is what made Blocker 1 diagnosable
  over COM1. Any future diagnosis on this station should start with the
  serial log, same as the KDL trace that found Blocker 1.

These only take effect when the volume is booted as the actual boot disk
(`-boot c`) — see "Install method" step 3 above.

## Ready scene

1024×768×16 blue R5 desktop, Deskbar top-right, Tracker, and a Terminal
opened automatically by `UserBootscript`. Framebuffer-verified.

## Golden / reset

`resetMode: loadvm`, snapshot `golden` inside the standalone
`/data/vms/streamhost/stations/beos/beos-golden.qcow2` (a copy of the pristine
`/data/gallery-guests/Beos/beos-r5.qcow2`). Baked 2026-08-18 on the production
launcher after a zero-input cold boot to the fixture; the launcher then boots
`-loadvm golden -S` and the restored frame is byte-identical to the running
one. Same device set required — do not add/remove devices (audio!) without a
re-bake. Clone-only proof (`checkpoint-verify.sh beos`) still to run.

## Rollback

Standard shape (`/data/vms/streamhost/stations/beos/ROLLBACK.md`): stop only
`streamhost@beos`, stop its QEMU by the station pidfile, restore the qcow2 —
the pristine, never-booted-by-the-station copy is
`/data/gallery-guests/Beos/beos-r5.qcow2` (re-bake golden after restoring it),
the raw bring-up disk is `/data/vms/sandbox/beos-r5/exp/beos-hd.raw` — and
restart only the BeOS service.

## Dark launch

During bring-up the station streamed from the sandbox rig
(`/data/vms/sandbox/beos-r5/exp/F`) as `/os/beos` through
`scripts/dev/darklaunch-station.py`; that overlay was withdrawn when the
production `streamhost@beos` unit took over on 2026-08-18. The registry row is
`listing: hidden` (deep link only) until the operator has eyeballed pointer
and keyboard.

## Open items

- **Audio**: shipped OFF. Both QEMU `AC97` (R5 `i801` driver, "Codec is not
  tested") and `ES1370` (R5 `es137x`) attach, but the guest stalls the moment
  the media_server opens the device (Deskbar clock stops, Terminal never
  paints) — with MP-table routing and in PIC mode alike. Untested next steps:
  `sb16` (ISA, needs the removed ISA config manager? — check `awe64`/`sb16`
  drivers), or a KDL dump at the stall.
- **Builder automation**: `scripts/build-guests/tiles/beos.sh` encodes the
  recipe above but has not been run end-to-end; its first-boot completion
  signal is a fixed wait (TODO: serial marker).
- **Registry/labctl declarations vs live**: `mouse`/`keyboard` in `reset` are
  UNVERIFIED — the visitor input path (pointerRel + Terminal echo) awaits the
  operator's eyeball at `/os/beos`; then flip `listing`.
- **KVM MSR question**: which MSR R5's idle-thread path reads that KVM leaves
  unhandled is not identified; TCG sidesteps it but a fix would let this
  station run accelerated like the rest of the fleet.
- **Golden**: baked 2026-08-18 by hand (QMP `savevm golden` on the production
  launcher; relaunch with `-loadvm golden -S` restores a byte-identical frame).
  The clone-only proof `scripts/lib/checkpoint-verify.sh beos` (bootrec arm
  present) has not been run yet.
- **Second/Pro-disc driver coverage**: not investigated — this station uses
  only the one archive.org item; no evidence yet that anything is missing.

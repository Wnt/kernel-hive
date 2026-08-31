# beos guest — BeOS R5 Professional 5.0.3

Status: **LIVE, listed** (production tile since 2026-08-18). Booted, installed, and interactive on a
`/data/vms/sandbox/beos-r5` rig; the two real R5-under-QEMU blockers are
diagnosed and fixed. What remains open is listed at the bottom.

Since **2026-08-23** the station is also **on the retronet**: a real bridged NIC
on `vmbr-rn`, DHCP-reserved `10.99.0.16`, no default route, browsing the museum
corpus in **NetPositive** (R5's own browser), and it has a real **exec channel**
for the first time — R5's own **telnetd**. The network/browser/exec story is its
own document: [`docs/lab/retronet/STATION-beos.md`](../lab/retronet/STATION-beos.md).

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
  -device rtl8139,netdev=n0,mac=<unique> \
    -netdev tap,id=n0,ifname=beosrn0,script=no,downscript=no \
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
- NIC: **`rtl8139`**, on a tap on `vmbr-rn`. It was `ne2k_pci` on slirp until
  2026-08-23, and `ne2k_pci` had to go: R5's `etherpci` driver is fine on an idle
  link but loses the NE2000 receive ring under real traffic — one corpus page
  full of images produced **144,683** `etherpci_read: bad next packet!` lines on
  the serial console, after which the NIC was dead, the guest's MAC had aged out
  of the bridge FDB and QEMU sat pegged at 100% CPU. It is load-dependent: the
  same page loaded cleanly on a rig started with `-display none` (more CPU for
  the guest) and killed the link every time under the production capture path.
  R5's own `rtl8139` driver carries the same page with **zero** errors. Switching
  the model is a device-set change and needed a cold re-bake, which the retronet
  MAC change required anyway.
- Pointer: **absolute, by writing the guest's own coordinate** (since
  2026-08-30; was PS/2 relative). R5 predates broad USB HID/absolute-pointer
  support — `usb-tablet` is not supported — and it has no hardware cursor to
  close a loop over, because it drives `-vga std` as its "unsupported card"
  stub driver and none of its real accelerated drivers claims anything QEMU
  emulates. But `app_server` keeps its own pointer coordinate in RAM as two
  little-endian `int32`, so `-device kh-ramabs` writes the commanded pixel
  there and injects one 1-unit PS/2 nudge to make `app_server` republish it.
  No control law, no gain, and the hotspot (`(1,0)` on R5's arrow, measured)
  never enters the path. The guest-physical address is bound to the golden and
  is re-derived after every re-bake; the device verifies it at connect and
  refuses every write otherwise, so a stale address degrades the station to its
  relative path rather than corrupting guest memory.
  Full derivation, the disproof of both adapter routes, and the framebuffer
  proof: [`docs/lab/BEOS-ABSOLUTE-POINTER.md`](../lab/BEOS-ABSOLUTE-POINTER.md).
- Audio: none (see Open items — both R5-supported QEMU codecs stall the guest).
- Pointer path: `--pointer abs --input-backend ramabs`, UI `pointerRel: false`.
  Station binary `/opt/qemu-beos` (qemu-patches 0001 + 0007 + 0010) — beos moved
  off the host `pve-qemu-kvm` package so the pointer would not require rebuilding
  the package every other guest on this box runs. That move costs ONE cold golden
  re-bake, because the 2026-08-23 golden carries pve-qemu's `pbs-state` vmstate
  section and a standalone binary refuses it.

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

1024×768×16 blue R5 desktop, Deskbar top-right, Tracker, a Terminal, **and
NetPositive showing the museum corpus page `http://spacejam.com/`** — both
windows opened automatically by `UserBootscript`, which is tracked at
`streamhost/stations/beos/UserBootscript`. Framebuffer-verified.

Keeping the scene in a boot script rather than hand-arranging windows before a
bake is what makes the fixture reproducible from a **cold** boot, not only from
`loadvm` — which is what made the 2026-08-23 MAC/NIC re-bake repeatable. The
script waits for a **name** to resolve before opening the browser; waiting only
for the gateway's IP to answer is not enough, and a NetPositive started too
early caches the failed lookup and bakes a "Web site not found" page into the
fixture.

## Golden / reset

`resetMode: loadvm`, snapshot `golden` inside the standalone
`/data/vms/streamhost/stations/beos/beos-golden.qcow2` (a copy of the pristine
`/data/gallery-guests/Beos/beos-r5.qcow2`). **Cold-baked 2026-08-23** on the
production launcher with the retronet device set (tap on `vmbr-rn`, unique MAC,
`rtl8139`) after a zero-input cold boot to the fixture; the launcher then boots
`-loadvm golden -S` and the restored frame matches the pre-bake frame
everywhere except the Deskbar clock (183 px, x 974–1015 / y 30–36 — the clock
ticked between the two captures). Same device set required — do not add/remove
devices (audio!) without a re-bake. Clone-only proof
(`checkpoint-verify.sh beos`) still to run.

The **MAC lives in the vmstate**, so `loadvm` restores the saved MAC whatever
the launcher's `mac=` says; changing it is always a cold re-bake. The full
dance, and the byte-verified backup of the previous golden, are in
[`STATION-beos.md`](../lab/retronet/STATION-beos.md).

## Rollback

The **byte-verified backup of the pre-retronet (2026-08-18, hand-baked) golden**
is `/data/gallery-guests/Beos/golden-backup-rn-netswap-20260822/beos-golden.qcow2`
(sha256 `f39ae8d6fca8d9071d7818b0a3dcb91f97e9d447fbdd14136f163fdb62d13b0d`,
`SHA256SUMS` beside it). It still carries its own internal `golden` snapshot, so
restoring it restores instant-resume with no re-bake. Full sequence:
[`STATION-beos.md` §Golden lineage & rollback](../lab/retronet/STATION-beos.md).

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
production `streamhost@beos` unit took over on 2026-08-18. The row is listed in the
lineup (operator decision 2026-08-18: no clone-only proof gate for stations).

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
- ~~**Registry/labctl declarations vs live**: `mouse`/`keyboard` UNVERIFIED.~~
  **Closed 2026-08-23.** Both are now `OK` in `reset`. Keyboard: every command in
  the retronet bring-up before the exec channel existed was typed into the
  Terminal through QMP `input-send-event` and read back off the framebuffer,
  including a password into a masked field. Pointer: R5's Network preferences
  panel was driven entirely by relative PS/2 deltas — tab switches, radio
  buttons, checkboxes, text fields and buttons all hit their targets. Two
  caveats came with it, both recorded in
  [`STATION-beos.md`](../lab/retronet/STATION-beos.md) §Gotchas: the pointer's
  gain is **not** a constant (it varies with event rate, so scripted targeting
  has to be closed-loop), and after a long framebuffer-driven session the **GUI
  can wedge while the kernel stays healthy** (Deskbar clock frozen 19 minutes
  behind the guest's own `date`, cursor gone, keys ignored — with `bash`,
  `net_server` and `ps` all answering normally over the exec channel). A reboot
  clears it.
- **KVM MSR question**: which MSR R5's idle-thread path reads that KVM leaves
  unhandled is not identified; TCG sidesteps it but a fix would let this
  station run accelerated like the rest of the fleet.
- **Golden**: baked 2026-08-18 by hand (QMP `savevm golden` on the production
  launcher; relaunch with `-loadvm golden -S` restores a byte-identical frame).
  The clone-only proof `scripts/lib/checkpoint-verify.sh beos` (bootrec arm
  present) has not been run yet.
- **`exec_kind` is no longer null.** `labctl exec beos "<cmd>"` runs over R5's
  own telnetd at `10.99.0.16:23`; `ftpd` on `:21` is the file-transfer door. No
  agent, no build, no download — the daemons were already in R5's `Netscript`,
  gated on a settings file the station simply never had. See
  [`STATION-beos.md` §The exec channel](../lab/retronet/STATION-beos.md).
- **No development tools on the volume, but they are one mount away.**
  `/boot/develop` is empty on the shipped golden — the file-copy install brought
  across the Pro CD's runtime system volume but not its development tree, so
  there is no `gcc` and no Be headers out of the box (`make` is present). This
  is **not** the blocker it looks like: the Pro CD carries the toolchain as a
  ready-made install package at `_packages_/Development` on its track-2 BFS
  volume, that volume mounts read-only on labhost with the in-tree `befs`
  module, and delivering it over the station's ftpd gives a working
  **gcc 2.9-beos-991026** that has been proven to compile and link a real
  `libbe` GUI application in the guest. Full recipe, including the exec-timeout
  trap that silently truncates the extraction:
  [`STATION-beos.md` §Restoring the compiler](../lab/retronet/STATION-beos.md#restoring-the-compiler--the-reusable-recipe).
  Note it is transient — `loadvm golden` reverts the disk, so bake it or copy
  the build output back out.
- **Second/Pro-disc driver coverage**: not investigated — this station uses
  only the one archive.org item; no evidence yet that anything is missing.

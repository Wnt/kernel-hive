# chokanji guest — 超漢字 / B-right/V (BTRON3)

Status: **LIVE (host-native QEMU-x86), dark-launched for eyeball.** Slot 149,
UDP 54149, archetype `beige-tower-crt`, `ui: desktop`, relative pointer.

超漢字 (Chokanji) / B-right/V is the commercial **BTRON3** desktop from Ken
Sakamura's TRON project. The exhibit hook is the TRON story: the operating system
Japan planned for its schools — and, in ambition, for the world — until the US
Trade Representative named TRON under the 1989 **Super-301** trade action and the
school-computer adoption collapsed. It survived commercially through Personal
Media Corporation. The visual star is the "real object / virtual object"
(実身/仮身) desktop and a colossal kanji character set.

## Identity and source

- Public id / stationDir / SH_STATION: `chokanji` (one name).
- Emulator: **QEMU 11.0.2** (`pve-qemu-kvm 11.0.2-1`), machine `pc-i440fx-11.0`,
  KVM. Host-native: `-display dbus,p2p=on`, no kiosk.
- Media set (operator-provided): Internet Archive item
  [`chokanji`](https://archive.org/details/chokanji), file `chokanji.zip`
  — sha256 `b8fd99a928d5564e53b58d2b8853b05f799a3fc32ba09cee0714a66c675039df`,
  850 274 156 bytes (archive.org MD5 `6d68e525…`, SHA1 `35b928a4…` and size all
  match). Archived in the lab media cache (`media_cache_put`) at
  `/data/media-archive/blobs/b8/b8fd99a9…`. **Never committed** (preservation,
  Personal Media proprietary; the set also carries a product key). Full
  provenance: `docs/lab/ASSETS-MANIFEST.md`.
- Inside `chokanji.zip`:
  - `qemuckj.7z` → a QEMU-0.14-for-Windows port + **`mc.img`**, a *pre-installed,
    bootable* raw disk (MBR: FAT16 boot partition + a BTRON system partition),
    **B-right/V Kernel Ver 4.202**. This is the runnable exhibit.
  - `CKV4540.iso` → **超漢字V 4.540**, the consumer edition: a Windows/VMware
    installer (`ckv-setup.exe`, a Delphi self-extractor that deploys a VMware VM;
    `VMware-player-3.1.4-…exe`; `.bpk` update packages). **Its disk image is not
    host-extractable without Windows** — see Known limitations.
  - `BRIGHTV4500.iso` → B-right/V 4.500 OEM component files (fonts, dictionaries,
    kernel modules) — not a bootable image.
  - `cygwin-brightv.7z` → CygWin/B-right/V host-side components.

The Virtual OS Museum catalogues "Chokanji 4 (B-right/V) 4.104" on x86 PC under
QEMU 5.2 (read for facts only, CC BY-NC-SA — nothing copied): it confirmed the
family runs on stock QEMU `pc`/x86_64 and, via its `-M pc,vmport=off`, pointed at
the vmmouse trap below.

## Build and device set

- Builder: `scripts/build-guests/tiles/chokanji.sh` — no install to automate; it
  resolves `chokanji.zip` from the media cache by sha256, extracts `qemuckj/mc.img`,
  and repacks it to the canonical qcow2, then framebuffer-smoke-tests the boot.
- Canonical output: `/data/gallery-guests/Chokanji/chokanji.qcow2` (qcow2 from the
  raw `mc.img`; **convert with `qemu-img convert -S 0`** — plain zero-run detection
  produced an empty qcow2 on the ZFS store, though `qemu-img compare` still reads
  the source back byte-identical).
- Verbatim launcher: `streamhost/stations/chokanji/qemu-streamhost.sh`. Device set:
  `qemu-system-x86_64 -enable-kvm -m 256 -smp 1 -machine pc-i440fx-11.0,vmport=off
  -cpu host -rtc base=localtime -boot c -vga cirrus -display dbus,p2p=on -drive
  file=…/chokanji.qcow2,format=qcow2,if=ide` (default i8042 PS/2 keyboard+mouse;
  no NIC; no audio device). `SH_DBUS_UPDATE_MS=4` fast-poll capture.
- **`vmport=off` is load-bearing.** `mc.img` is an ex-VMware guest, so QEMU's
  default VMware I/O port makes the `vmmouse` device the current pointer
  (`query-mice`: vmmouse current, `absolute=false`), and it **swallows all injected
  motion** — the BTRON hand cursor never moves. BTRON does not poll the VMware
  port, so vmmouse never reaches absolute mode either. `vmport=off` removes it and
  the default PS/2 mouse becomes the live pointer.
- **Pointer = relative (PS/2).** With vmmouse gone, PS/2 relative motion reaches
  BTRON (cursor tracked to the corners under QMP `input-send-event rel`). BTRON has
  no absolute/tablet driver — `-device usb-tablet` (absolute) does **not** move the
  cursor — so `SH_POINTER=rel`, UI `pointerRel=true`; browser Pointer Lock feeds
  1:1 deltas. `-device usb-mouse` also works but PS/2 is cleaner (a valid
  `qemu-ps2-relative` transport, no extra device).
- **Display = Cirrus GD5446 @ 800×600.** BTRON's screen driver in this disk is
  Cirrus-specific; `-vga std` renders black. 800×600 is the disk's configured mode.
- RAM 256 MB (what this B-right/V build is tuned for; boots in ~40 s).

## Golden, input, and rollback

- Reset: `resetMode=loadvm`, snapshot `golden`, inside `chokanji.qcow2`. The disk
  runs WITHOUT `-snapshot` so `savevm golden` persists; the launcher boots straight
  into `-loadvm golden -S` (frozen at the fixture, ~0 CPU) once the tag exists.
- Bake on the box (the launcher writes the runtime dir):
  `bash streamhost/stations/chokanji/qemu-streamhost.sh` (cold boot, no tag),
  wait for the desktop, then via QMP `stop; savevm golden; cont`; relaunch and
  confirm it comes up `-loadvm golden -S`. (Operator policy: a restoring golden is
  proof enough; no separate checkpoint-verify ceremony.)
- Fixture: clean idle BTRON3 desktop — the 超漢字 real-object window and the
  原紙箱：B-right/V virtual-object box open on the blue kanji-watermark wallpaper,
  hand cursor at rest.
- Input proof: **pointer (relative) PASS** (framebuffer-verified cursor motion).
  Keyboard **UNVERIFIED** — the exhibit is mouse-driven; BTRON keyboard entry is
  Japanese-IME/menu-driven, virtual-keyboard profile `generic`.
- Credentials: none — BTRON boots straight to the desktop, no login. `credentialsRef`
  `guest/chokanji` is a placeholder reference (no values).
- Rollback: keep the pre-change launcher+golden pair; the disk is reproducible from
  the archived media via the builder. No live station is touched during bring-up
  (all work namespaced under `/data/vms/sandbox/chokanji/`).

## Dark launch

`/os/chokanji` on the live origin, via `scripts/dev/darklaunch-station.py publish`
(listed:false overlay, grid + 3D hall unaffected) — for the operator to eyeball
before promotion to the grid (publish `gallery-manifest.json`). Re-arm the overlay
after any `serve-https-spa.sh` manifests deploy (it republishes from the registry).

## Known limitations

- **Version.** The runnable exhibit is B-right/V **4.202** (the 超漢字4-era kernel
  in `mc.img`), not the consumer **超漢字V 4.540** the operator's set also contains.
  4.540's `ckv-setup.exe` is a Windows-only Delphi self-extractor that deploys a
  VMware VM; its disk is not extractable on the host without running Windows, and
  the in-system `.bpk` upgrade path from 4.202 is not supported/attempted. The
  museum value (the BTRON3 real/virtual-object desktop and the kanji set) is
  identical. A future upgrade to 4.540 would need a Windows/wine pass to unpack
  `ckv-setup.exe`, or a separately-sourced 4.540 disk image.
- **Resolution.** 800×600 (the disk's configured Cirrus mode); higher res would
  need reconfiguring BTRON's screen driver in-OS.
- **Audio.** None wired (the desktop is effectively silent). QEMU-CKJ's `q.bat`
  used SB16+AdLib — a possible future add.

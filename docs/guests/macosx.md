# macosx guest

Status: **paused mid-bring-up, disabled candidate, not in the lineup.** The
release choice, the media and the pointer transport are measured; the OS is not
installed and no golden exists. The full, resumable account — with the panic
text, the timings and the exact next step — is
[`docs/lab/MACOSX-WAVE.md`](../lab/MACOSX-WAVE.md). This file carries only the
facts that are settled.

## Identity and source

- Public ID / tile directory: `macosx`
- Reserved slot / UDP port: `212` / `54212`
- Archetype: `apple-studio`
- Release: **Mac OS X 10.3.0 Panther**, PowerPC, retail install disc 1 of 3
- Media: `panther-10.3-cd1.iso`, 679,043,072 bytes,
  SHA-256 `5383331ad0850f03859be5a79101d6ebc1e9fe4d7379328c46362d5620aa45cb`,
  from the Internet Archive item `cheetah-to-tahoe-mac.os.x`
- Discs 2 and 3 (bundled applications, extra printer/language packages) are
  **not** staged; whether disc 1 alone reaches the intended scene is untested.

## Why Panther and not Jaguar

Mac OS X 10.2 Jaguar (`jaguar-10.2-cd1.iso`, 655,364,096 bytes, SHA-256
`e0891480aa027069fafb94f8a951a2c115e52551efdd2b6b6e7e3212139d25d2`) was the
first target and **panics reproducibly** on this machine ~50 s into a CD boot,
inside `com.apple.iokit.IOSCSIMultimediaCommandsDevice` /
`IODVDStorageFamily` with a 0x300 data-access exception — its ATAPI optical
stack cannot drive QEMU's emulated CD. Panther boots the identical device set
to a painted Aqua installer in ~7 minutes. Do not switch this station back to
Jaguar without new evidence; the panic is in the CD driver, so `-cpu`, `-m` and
`via=` are the wrong knobs to bisect.

The non-verbose failure is only the four-language "You need to restart your
computer" panel, which names nothing. `-prom-env 'boot-args=-v'` is what made
this diagnosable in one boot instead of a bisect.

## Build and device set

- Builder: `scripts/build-guests/tiles/macosx.sh` (still the scaffold stub)
- Launcher: `streamhost/stations/macosx/qemu-streamhost.sh` — carries the
  complete frozen device set and the reasoning
- Binary: `/opt/qemu-ppc/bin/qemu-system-ppc` (QEMU 11.0.2, the standalone
  kernel-hive fork build, the same one `macos9` and `macos753` use). Its
  `cpu/tb_env` vmstate patch is required for any PowerPC checkpoint.
- Machine: `mac99,via=pmu`, `-cpu g4`, `-accel tcg` (no KVM path: ppc on x86)
- RAM: **1024 MB** (not macos9's 512 — Mac OS X has a real VM subsystem and a
  guest that swaps under TCG never finishes)
- Display: `-g 1024x768x32`, `-display dbus,p2p=on`
- Storage: single qcow2, 12 GB, partitioned APM with one non-journaled
  `Mac OS Extended` volume named `Macintosh HD`
- NIC: **none**, deliberately (operator scope: ordinary station, no retronet).
  QEMU would otherwise auto-create a user-mode `sungem` on mac99. Any NIC must
  be added BEFORE the first `savevm golden` or the checkpoint needs a re-bake.
- Audio: none (this fork's mac99 has no sound device)
- Input: **`-device usb-tablet`**, plus the machine's own `via=pmu` USB
  keyboard. Do not add `-device usb-kbd`/`usb-mouse`.

## Pointer — true absolute, and the first mac99 station that gets one

`macos9` is a relative-pointer station because Mac OS 9 has no driver for
QEMU's `usb-tablet`; it pays for that with the daemon's abs->rel bridge at
`SH_CURSOR_SCALE=5.5556` and a re-home-on-reset hack, and its launcher warns
that a second USB HID behind `via=pmu` splits QEMU's input routing.

**Mac OS X 10.3 drives the tablet natively and that warning does not carry
over.** Measured on the Panther installer's framebuffer:

- QMP `abs` to (200,150) → guest arrow rendered at (200,150)
- QMP `abs` to (800,600) → guest arrow rendered at (800,600)
- Clicks at control coordinates activated those controls: Continue, the license
  sheet's Agree, the Installer menu, "Open Disk Utility…", Disk Utility's
  Partition tab, two popup menus and the Partition confirmation sheet
- `Cmd-A` + typed text replaced a text field, and `Cmd-Q` quit an application,
  so the built-in keyboard works alongside the tablet

Hence `SH_CURSOR_SCALE=1.0`, offsets 0, no bridge, no reset teleport.

**OPEN:** the formal five-target accuracy sweep and the exact hotspot offset are
not measured. They belong on the installed Aqua desktop, not the installer. The
two points above agree with 1:1 at offset 0 to within the arrow glyph, so the
fixture ships unity scale as a hypothesis to verify, not as a constant.

## Install throughput

Measured, because the playbook requires the first disk write to be timed before
an install-heavy station is allowed to just run:

- Disk Utility partition + HFS+ format of the 12 GB qcow2: **32 s wall,
  19,464,192 bytes materialised.**

That is a healthy write path. This guest is **CPU-bound under TCG, not
I/O-bound** — do not spend an agent racing disk transports here.

## Golden, input, and rollback

- Reset mode: `loadvm` with snapshot `golden` (warm `system_reset` is not
  trusted on `-M mac99`; see `macos9`)
- Fixture: `streamhost/stations/macosx/station.env.fixture` — its
  `SH_FIXTURE_DESC` is the INTENDED scene and is marked TODO until a golden
  exists
- Golden: **does not exist.** Bake it only with the complete device set above.
- Pointer/click/drag/keyboard proof: partially done (see above); the desktop
  sweep is OPEN
- Cold-boot zero-input state and optional clip: TODO
- Credentials reference only (never values): `guest/macosx`
- Rollback plan: the station is a disabled candidate and is in no lineup, so
  there is nothing deployed to roll back.

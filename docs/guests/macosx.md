# macosx guest

Status: **LIVE, listed, golden baked and restore-proven (2026-09-20).** The
bring-up account — including the install wall that cost this station its longest
hour and the three theories that were killed before the real cause was found —
is [`docs/lab/MACOSX-WAVE.md`](../lab/MACOSX-WAVE.md). This file carries the
settled facts.

## Identity and source

- Public ID / tile directory: `macosx`
- Slot / UDP port / VMID: `218` / `54218` / `218`
- Archetype: `apple-studio`
- Release: **Mac OS X 10.3.0 Panther**, PowerPC, retail install disc 1 of 3 —
  **disc 1 alone is enough** for this exhibit (see "Install" below)
- Media: `panther-10.3-cd1.iso`, 679,043,072 bytes,
  SHA-256 `5383331ad0850f03859be5a79101d6ebc1e9fe4d7379328c46362d5620aa45cb`,
  from the Internet Archive item `cheetah-to-tahoe-mac.os.x`

## Why Panther and not Jaguar

Mac OS X 10.2 Jaguar (`jaguar-10.2-cd1.iso`, 655,364,096 bytes, SHA-256
`e0891480aa027069fafb94f8a951a2c115e52551efdd2b6b6e7e3212139d25d2`) was the
first target and **panics reproducibly** on this machine ~50 s into a CD boot,
inside `com.apple.iokit.IOSCSIMultimediaCommandsDevice` /
`IODVDStorageFamily` with a 0x300 data-access exception — its ATAPI optical
stack cannot drive QEMU's emulated CD. Panther boots the identical device set
to a painted Aqua installer in ~3.5 minutes. Do not switch this station back to
Jaguar without new evidence; the panic is in the CD driver, so `-cpu`, `-m` and
`via=` are the wrong knobs to bisect.

The non-verbose failure is only the four-language "You need to restart your
computer" panel, which names nothing. `-prom-env 'boot-args=-v'` is what made
this diagnosable in one boot instead of a bisect.

## Install — and the two-boot rule that is the whole trap

**The Panther installer will refuse a volume that did not exist when the
installer booted.** At *Select a Destination* it shows the freshly partitioned
`Macintosh HD` with a red badge and "You cannot install Mac OS X on this volume.
You cannot start up your computer using this volume." Restart QEMU, boot the CD
again, and the same volume is accepted with a green arrow. So:

1. **First CD boot** — Installer menu -> Open Disk Utility -> Partition tab:
   1 Partition, format **Mac OS Extended** (non-journaled, to cut write
   amplification under TCG), name `Macintosh HD`, leave *Install Mac OS 9 Disk
   Drivers* ticked. Quit Disk Utility.
2. **Kill QEMU and boot the CD again.** Walk to Select a Destination; the volume
   is now installable.
3. At *Installation Type* click **Customize** and leave only the forced
   *Essential System Software* (925 MB) and *BSD Subsystem* (225 MB). That drops
   Space Required from 3.0 GB to **1.1 GB** and, with it, the installer's demand
   for *Mac OS X Install Disc 2*. Trap: *Printer Drivers* and *Fonts* start as
   PARTIAL ticks, so the first click SELECTS them — click each twice.
4. **Skip** the "Checking your installation disc" pass; it reads the whole
   679 MB ISO under TCG for nothing.

Three theories were killed on the framebuffer before the restart was found, and
none of them is the cause: disk size (reproduced on 12 GB and on 6 GB), the
*Install Mac OS 9 Disk Drivers* checkbox (reproduced ticked and unticked), and a
malformed partition map (dumped off the qcow2 with `qemu-img dd` and decoded —
`Apple_partition_map`, two `Apple_Driver43`, two `Apple_Driver_ATA`,
`Apple_FWDriver`, `Apple_Driver_IOKit`, `Apple_Patches`, then `Apple_HFS`;
nothing missing).

Measured timings on a loaded box (1-min load 50-80):

| Step | Wall |
|---|---|
| CD boot to the Select Language sheet | ~3.2 min |
| Disk Utility partition + non-journaled HFS+ format of the 6 GB qcow2 | ~6 min |
| Package copy, 1.1 GB customised set | **66 min** (18:54Z -> 20:00Z) |
| First boot from the HD to Setup Assistant | ~5.3 min |
| Setup Assistant to the Aqua desktop | ~24 min |

This guest is **CPU-bound under TCG, not I/O-bound** — do not spend an agent
racing disk transports here.

## Build and device set

- Launcher: `streamhost/stations/macosx/qemu-streamhost.sh` — carries the
  complete device set and the reasoning
- Binary: `/opt/qemu-ppc/bin/qemu-system-ppc` (QEMU 11.0.2, the standalone
  kernel-hive fork build, the same one `macos9` and `macos753` use). Its
  `cpu/tb_env` vmstate patch is required for any PowerPC checkpoint.
- Machine: `mac99,via=pmu`, `-cpu g4`, `-accel tcg` (no KVM path: ppc on x86)
- RAM: **1024 MB** (not macos9's 512 — Mac OS X has a real VM subsystem and a
  guest that swaps under TCG never finishes)
- Display: `-g 1024x768x32`, `-display dbus,p2p=on`
- Storage: single **6 GB** qcow2, APM, one non-journaled `Mac OS Extended`
  volume named `Macintosh HD` (~1.3 GB used)
- NIC: **none**, deliberately (operator scope: ordinary station, no retronet).
  QEMU would otherwise auto-create a user-mode `sungem` on mac99. Any NIC must
  be added BEFORE a re-bake of the golden.
- Audio: none (this fork's mac99 has no sound device)
- Input: **`-device usb-tablet`**, plus the machine's own `via=pmu` USB
  keyboard. Do not add `-device usb-kbd`/`usb-mouse`.

## Pointer — true absolute, and the first mac99 station that gets one

`macos9` is a relative-pointer station because Mac OS 9 has no driver for
QEMU's `usb-tablet`; it pays for that with the daemon's abs->rel bridge at
`SH_CURSOR_SCALE=5.5556` and a re-home-on-reset hack, and its launcher warns
that a second USB HID behind `via=pmu` splits QEMU's input routing.

**Mac OS X 10.3 drives the tablet natively and that warning does not carry
over.** Five-target sweep on the installed Aqua desktop, located with
`scripts/dev/cursor-locate.py` (exact-match, not correlation):

| Aimed | Arrow sprite origin found | Error |
|---|---|---|
| (120,120) | (120,120) | 0 px |
| (900,140) | (900,140) | 0 px |
| (512,384) | (512,384) | 0 px |
| (140,640) | (140,640) | 0 px |
| (900,660) | (900,660) | 0 px |

The Aqua arrow's hotspot is its own top-left tip, so sprite origin == pointer:
**unity scale, zero offset, 0 px error at all five targets.** Clicks activated
the controls under them (Apple menu, System Preferences panes, Finder sidebar,
Dock), a press-move-release drag moved two System Preferences sliders, and a
drag-and-drop carried Terminal from a Finder list row into the Dock — so the
button is genuinely released, not held (the riscos3 failure mode).

Keyboard: the built-in `via=pmu` board types text and takes `Cmd-Q`, `Cmd-A`
and `Shift-Cmd-U`. Note for drivers: QMP `send-key` wants the modifier as a
SEPARATE qcode (`meta_l q`), not a `meta_l-q` string.

## Golden, reset, and the exhibit scene

- Reset mode: `loadvm` with snapshot `golden` (warm `system_reset` is not
  trusted on `-M mac99`; see `macos9`)
- Golden: **baked 2026-09-20**, 234 MiB vmstate, entirely inside the single main
  disk — `qemu-img snapshot -l` shows one snapshot, so no `--golden-extra`
- Restore proof, strict protocol: a FRESH QEMU process with
  `-loadvm golden -S`, then `cont`; the guest's own menu-bar clock advanced
  across 70 s, and pointer motion was then consumed to two new targets
  ((800,200) and (300,560), both located exactly). SSIM alone would have passed
  on a wedged guest and proves nothing.
- Scene: one brushed-metal Finder window on the `visitor` home folder in icon
  view, `Macintosh HD` on the desktop, the Dock along the bottom **with Terminal
  added to it**, cursor parked at (512,384), nothing selected
- The exhibit cannot blank itself: Energy Saver computer sleep dragged to Never,
  display sleep and hard-disk sleep unticked, screen-saver delay dragged to
  Never
- Account: `Visitor` / short name `visitor`, **no password**, registration
  skipped (Cmd-Q at the Registration Information pane offers *Skip*, which
  creates the account and ends setup). Credentials reference only:
  `guest/macosx`
- Rollback: launcher and disk are one unit — put the parked disk back AND leave
  the launcher at the commit that matches it.

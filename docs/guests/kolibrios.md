# KolibriOS gallery tile — absolute-pointer notes

**Status: LIVE + framebuffer-verified (2026-07-13).** Tile `kolibrios` (VMID 97,
udp/54097) now runs **`SH_POINTER=abs` (Pattern A: usb-tablet + dbus
`Mouse.SetAbsPosition`)**. Cursor tracks the client pointer 1:1 and clicks land
at the requested pixel — no in-guest agent needed.

## Resolution 1280×1024 (bumped 2026-07-26 from 1024×768)

Selected at the KolibriOS boot menu, not in any config file: at the blue
`Press [abcde] to change settings` screen, press `a`, pick `1280x1024@32` from
the videomode list (one Down from the default `1024x768@32`), Enter to confirm,
Enter to boot. The `golden` savevm snapshot captures the 1280×1024 desktop, so
`loadvm golden` (= `labctl reset kolibrios`) restores it live; abs pointer maps
1:1 across the full surface (verified: the Menu button at the bottom-left corner
opens the start menu). A cold boot with no snapshot yet defaults to 1024×768 —
re-select the mode at the boot menu to re-bake. NOTE: the live golden fixture is
a **clean auto-booted desktop** (taskbar clock on), not a TINYPAD-open surface
as older notes below imply.

## Clean rebuild trial (2026-07-14)

`scripts/build-guests/kolibrios.sh` was run from an empty, namespaced box
directory with both live-path overrides exercised:

```sh
OUT_DIR=/data/vms/soltest/repro-kolibrios-1784058917/out \\
WORK_DIR=/data/vms/soltest/repro-kolibrios-1784058917/work \\
  ./kolibrios.sh --force
```

The upstream `en_US/latest-iso.7z` download, extraction, and built-in headless
boot check completed in **53.36 s**. The resulting `kolibri.iso` was
**99,358,720 bytes**, with trial SHA-256
`90b0fcfae1e9661fa428099bd82a1a839291deaa3c4c13c13d209a10cf7a169a`.
This is a moving upstream nightly, so the digest records this trial rather than
acting as a permanent pin. The captured 1024×768 framebuffer showed the ready
desktop with its application and game icons.

The tile's box-only `live-rebake.sh`, `absdrv.py`, `kolmouse.py`, and empty state
disk were copied read-only into the trial and used as the recipe; none is
vendored by the guest builder. A fresh `state.qcow2` was baked using the emitted
launcher's device set: `pc`, host CPU, 256 MiB, 2 vCPUs, `std` VGA, USB tablet,
AC97, and the virtio state disk. TINYPAD was open and focused in the inspected
golden framebuffer. Three idle frames were identical, typing made the frame
different, and `loadvm golden` restored the exact baseline:

```text
baseline/idle: 876d1d1d806732594f7b979c4f906271
dirty:         add5106ae0aedf4d0a6fe66b25135e26
reset:         876d1d1d806732594f7b979c4f906271
cold -loadvm:  876d1d1d806732594f7b979c4f906271
```

The persisted trial state disk was 20,185,088 bytes. A separate cold QEMU start
with `-loadvm golden` also reproduced the baseline byte-for-byte, proving both
the interactive reset and launcher startup paths.

The run exposed an off-by-five ISO signature check: the old code never sampled
the `CD001` bytes at offset 32,769. The builder now checks the exact field and
supports direct `OUT_DIR`/`WORK_DIR` overrides. No licensed asset is required.

## Why usb-tablet works here
KolibriOS (asm-written, GPLv2 LiveCD, r0.7.7.0 nightly) ships a native **USB HID
stack** and consumes **usb-tablet absolute coordinates** directly. That makes it
a Pattern-A tile exactly like win2000/winxp: QEMU `-usb -device usb-tablet`, the
guest reads the tablet's absolute axis, and the streamhost daemon injects
positions via the QEMU dbus display `org.qemu.Display1 Mouse.SetAbsPosition`.
No pointer acceleration is applied, so the mapping is exact across the whole
1024x768 surface.

### Verification (real framebuffer screendumps)
- **Clone probe** (`/data/vms/soltest/kolibrios-c1`, LiveCD + usb-tablet, QMP
  `input-send-event` abs axis 0..32767): cursor landed at the requested pixels at
  (150,120), (820,620), (512,384); a click at the Menu button (33,753) opened the
  KolibriOS start menu — abs move **and** click both correct.
- **Live production golden** (dbus display + usb-tablet + `loadvm golden`): fixture
  restored byte-identical, and QMP abs injection at (200,160)/(850,640)/(512,384)
  tracked 1:1.
- **Live daemon**: `streamhost@kolibrios` active, `labctl shot kolibrios` renders
  the clean golden fixture; `labctl ls` shows `PTR=abs`.

## Device-set change → golden re-baked
Adding `-usb -device usb-tablet` changes the QEMU device set, so the golden
fixture (which resets via `loadvm golden`) was re-baked **with the tablet
present** — otherwise `loadvm golden` would refuse (device mismatch). The fixture
content is unchanged from the pre-tablet golden: clean desktop, taskbar Clock +
Cpu-Usage meter OFF, TINYPAD 4.1 open & keyboard-focused on an empty doc, caret
steady at 1,1.

- New golden framebuffer md5: **`f6c588427992a2bafaacce321075a1bf`** (was
  `ac1509e1…` pre-tablet). 3 idle shots over 6 s are byte-identical; `loadvm
  golden` round-trips byte-identical (dirty → reset verified).
- Re-bake recipe: `state.qcow2.base-empty` → boot the setup launcher (usb-tablet,
  `-display none`) → **wait ~30 s for the transient "connected to network" popup
  to fully fade** (QEMU's default user NIC triggers it; it auto-dismisses) →
  System Panel ▸ Panels: uncheck Clock + Cpu Usage → open+focus TINYPAD → `savevm
  golden`. Automated in the tile's `live-rebake.sh` (abs driver `absdrv.py`).

## Files / knobs
- Launchers `qemu-streamhost.sh` (production, dbus) and `qemu-setup.sh` (bake,
  `-display none`) both carry `-usb -device usb-tablet` after `-vga std`. Pre-change
  copies saved as `*.pre-tablet`.
- `tile.env`: `SH_POINTER=abs` (was `rel`); golden md5 comment updated. Pre-change
  copy `tile.env.pre-tablet`.
- Golden disk backup before re-bake: `state.qcow2.bak-pre-tablet-20260713`.
- Manifest: `streamhost/tiles-manifest.sh` emits `--pointer abs --input-dev usb`.
  Run `labctl gen` after any launcher/tile.env change (done).

## Rollback
Restore `qemu-streamhost.sh.pre-tablet`, `qemu-setup.sh.pre-tablet`,
`tile.env.pre-tablet`, and `state.qcow2.bak-pre-tablet-20260713` → `state.qcow2`;
`labctl gen`; restart `streamhost@kolibrios`. That returns the tile to
`SH_POINTER=rel` with the original `ac1509e1…` golden.

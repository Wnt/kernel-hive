# HelenOS station — absolute pointer (USB HID tablet)

HelenOS 0.14.1 "Aladar" (ia32 LiveCD, VMID 99, `-cpu qemu32`, intel-hda audio).

## Pointer: absolute via QEMU `usb-tablet` (Pattern A)

**Status: LIVE, verified 2026-07-13.** `SH_POINTER=abs`, launcher carries
`-usb -device usb-tablet`.

HelenOS ships an upstream USB HID stack. Attaching the QEMU `usb-tablet` to the
default PIIX3 **UHCI** controller (what plain `-usb` on `-machine pc` gives)
makes HelenOS enumerate it and consume **absolute** coordinates 1:1 — no agent,
no calibration offset, no cursor scaling. This is the same daemon path as
win2000/winxp: legacy `SH_POINTER=abs` → `InputBackend::DbusAbs` → D-Bus
`org.qemu.Display1 Mouse.SetAbsPosition(x,y)`, which lands in the QEMU input core
and routes to the tablet.

### How it was proven

1. **Clone probe** — `/data/vms/sandbox/helenos-c1` (`run.sh`, `-display none`,
   cold-boot from the ISO with `-usb -device usb-tablet` on UHCI). Injected
   `input-send-event` abs via `cdrv.py abs`:
   - abs(25599,25599) → cursor at pixel (800,600). ✅
   - abs(6400,29866) → cursor at pixel (200,700). ✅
   Perfect 1:1, both axes. UHCI is the mature path in the HelenOS stack; EHCI/
   xHCI were not needed.
2. **Live** — same result on the daemon-managed station: abs(20800,21333) →
   cursor (650,500), captured with `labctl shot`.

## Checkpoint recapture (device-set change)

Adding `usb-tablet` changes the migration device set, so the `golden` snapshot
was recaptured with the tablet present:

- Backed up the pre-tablet checkpoint → `golden.qcow2.bak-pretablet`.
- Cold-booted the (edited) live launcher from the ISO, let the compositor +
  Terminal scene come up, parked the cursor on the Terminal title bar via the
  tablet (abs(9600,597)), then recaptured. Any recapture of this station today is
  `ssh lab 'checkpoint-guard recapture helenos'` — never hand-typed snapshot verbs
  ([`../lab/checkpoint-guard.md`](../lab/checkpoint-guard.md)).
- Verified `loadvm golden` restores cleanly (STOP/RESUME, `return ""`) — device
  set matches — and snaps the cursor back to the parked title-bar position.

The daemon issues `loadvm golden` on attach (`SH_RESET_MODE=loadvm`); the scene
(focused Bdsh Terminal at prompt, cursor parked on the title bar, taskbar clock
masked) is unchanged apart from the parked-cursor pose.

## Launcher device line (live)

```
-usb -device usb-tablet \
```
inserted between the intel-hda audio devices and the `-drive` line. Everything
else (machine `pc`, `qemu32`, `-vga std`, dbus display/audio, IDE checkpoint disk,
ISO `-boot d`) is unchanged.

## Rollback

`cp golden.qcow2.bak-pretablet golden.qcow2`, remove the `-usb -device usb-tablet`
line from the launcher, set `SH_POINTER=rel` in `station.env`, `labctl gen`,
restart QEMU (launcher) + `streamhost@helenos`.

## Fresh builder trial (2026-07-14)

`scripts/build-guests/tiles/helenos.sh` was run with `OUT_DIR` pointing at an empty
`/data/vms/sandbox/repro-helenos-*` directory. The build took 70 seconds and
produced the 25,792,512-byte HelenOS 0.14.1 ISO. A real QMP framebuffer capture
showed the blue compositor, taskbar, and focused Terminal at the `/ #` prompt.

Acceptance used the authoritative streamhost device set (`pc`, `qemu32`, 64 MiB,
`std`, USB tablet, intel-hda). `savevm golden` produced a 93,126,656-byte state
qcow2; a fresh QEMU process with `-loadvm golden` returned to the same ready
Terminal framebuffer and remained running. Builder plus acceptance took 370
seconds. The 35 MiB trial directory was reported with `du` and deleted.

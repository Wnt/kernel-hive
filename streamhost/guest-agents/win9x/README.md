# win9x guest agents — absolute pointer for Windows 95 / 98 SE

`warpnet.c` is the in-guest absolute-cursor agent used by the **win95** tile
(win98se solved absolute pointing differently — usb-tablet, see below). It
positions the Win32 system cursor with `SetCursorPos(x,y)` and injects
clicks/wheel with `mouse_event()`, listening on Winsock TCP `:7777` and speaking
the same newline `M/P/R/B` warpd protocol as the Solaris agent — the streamhost
daemon (`InputBackend::Warpd`, `warpd.rs`) drives it unchanged over a QEMU hostfwd.

Why an agent at all (win95): the tile runs `usb=off` (part of the validated
anti-protection-error KVM combo, see `docs/guests/win9x.md`), so the only
pointing hardware is the PS/2 *relative* mouse, and Win9x pointer acceleration
makes the daemon's abs→rel homing bridge drift. A usb-tablet would require a
machine-string change = full golden re-bake and risks the fragile
`acpi=off,kernel-irqchip=off` recipe. (win98se escaped this: its golden is an
ACPI-HAL install, so `acpi=on` enumerates the full PCI/USB bus and a usb-tablet
works — that tile needs no agent at all.)

## Build (cross, on the lab box)

```
i686-w64-mingw32-gcc -O2 -s -mwindows -Wl,--no-insert-timestamp -o warpnet.exe warpnet.c -lwsock32
```

`-mwindows` = GUI subsystem (no DOS box in the guest).
`-Wl,--no-insert-timestamp` removes the PE link timestamp so repeated builds are
byte-identical. Winsock 1.1 only, so the same binary runs on base Win95 and 98SE
(98SE ships Winsock2, a superset).

## Deployed wiring (live tiles)

| tile    | pointer | transport                            | tile.env                                           |
|---------|---------|--------------------------------------|----------------------------------------------------|
| win95   | warpd   | hostfwd `127.0.0.1:57791` → `:7777`  | `SH_POINTER=warpd` `SH_WARPD_ADDR=127.0.0.1:57791`  |
| win98se | abs     | usb-tablet (no agent; `acpi=on`)     | `SH_POINTER=abs`                                    |

On win95 the hostfwd is appended to the tile's EXISTING `-netdev user,id=n0` — a
netdev backend property, NOT a `-device`, so the golden snapshot's device set still
matches (`loadvm golden` keeps working).

### win98se: no agent — usb-tablet BAKED + LIVE (2026-07-12)

win98se gets a true absolute pointer from a **usb-tablet** under `acpi=on`
(golden re-baked 2026-07-12, 1:1 tracking verified on the restored golden; see
`docs/guests/win9x.md` and the `win98se` entry in `streamhost/tiles-manifest.sh`).

<details><summary>superseded finding (2026-07-12): "warpnet-TCP BLOCKED, serial is the path" — kept for history</summary>

Same binary as win95, builds/injects fine, but Win98SE under the then-assumed
machine combo (`pc,acpi=off,usb=off,kernel-irqchip=off`, `-cpu pentium3,-apic`) boots
on the **fail-safe PnP BIOS** (Device Manager Code 28) and never enumerates the PCI
bus → the PCnet NIC never starts → no IP (`winipcfg`: "Cannot read IP configuration")
→ the SLIRP hostfwd has no in-guest listener. The `M/P/R/B` commands moved no cursor
across two clones, while the identical driver tracks 1:1 on the live win95 tile.

**Superseded**: the dead PCI bus was caused by `acpi=off` alone (a HAL mismatch —
the golden is an ACPI-HAL install), NOT by the whole combo. With `acpi=on` the
full PCI/USB bus enumerates, so the live tile now runs `SH_POINTER=abs` with a
usb-tablet and neither warpnet-TCP nor the once-planned serial transport is
needed. Full correction record: `docs/guests/win9x.md`.

</details>

## Bake recipe (TCP path — proven on win95; win98se does not use warpnet, see above)

1. Stop the tile service + QEMU (pidfile only), back up the system qcow2.
2. Offline inject: `qemu-nbd -c /dev/nbdX <sys.qcow2>` → mount vfat p1 →
   copy `warpnet.exe` to `C:\WARPNET.EXE` → add `load=C:\WARPNET.EXE` under
   `[windows]` in `C:\WINDOWS\WIN.INI` (CRLF line endings!) → umount, detach.
3. Add the hostfwd to the launcher's `-netdev user` string.
4. COLD boot (never `loadvm` — it would resurrect pre-inject RAM), let the
   fixture settle, verify the agent moves the cursor (framebuffer screendumps).
5. `delvm golden` + `savevm golden` via QMP, flip `tile.env` to warpd, update
   `streamhost/tiles-manifest.sh`, run `labctl gen`, restart `streamhost@<tile>`.

98SE gotcha: after an unclean power-off the next cold boot may pop the
"Display adapter is not configured properly" wizard and/or run scandisk before
the shell loads — dismiss and re-verify from screendumps before `savevm golden`.

Other files: `warpwin-serial-altbuild.c` (serial-transport variant kept for
reference; the TCP hostfwd path is what is deployed).

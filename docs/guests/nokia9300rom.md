# nokia9300rom guest

Status: **HIDDEN comparison station** (dark-launched 2026-09-25 by agent D5). It is
not a museum exhibit. It sits beside [`nokia9300`](nokia9300.md) so the operator can
compare the two window-server tracks by eye at `/os/nokia9300rom` and `/os/nokia9300`.

## What differs from nokia9300

Everything not listed here is nokia9300's; read [nokia9300.md](nokia9300.md).

| | nokia9300 | nokia9300rom |
|---|---|---|
| EKA2L1 fork branch | `s80-integration` (HLE window server) | `s80-rom-station` @ ac7c1e126 = `s80-rom-boot` @ f7ca695c4 (`s80-integration` @ b1fec4a28 + the ROM window-server boot) + `s80-rom-input` @ 1d7801eca + `s80-rom-apps` @ 93961ef8e |
| Emulator env | none | `EKA2L1_ROM_WSERV=1` (fixture `NOKIA_EMU_ENV`): the firmware's own `ewsrv.exe` owns the screen; HLE FBS stays |
| Golden | v3.1 | v3.1 + `C:\System\Programs\SysState.exe`, the resident state publisher that the ROM window server's `STARTUP` directive launches. It also feeds the ROM window bridge; this is Z4 worker D's build, sha256 77a7d8c1…98d2. The fork overlays that directive at runtime, and no ROM file changes. The overlay is staged at `/data/assets-staging/symbian-s80/nokia9300rom-overlay` with its `MANIFEST.sha256` |
| Slot / UDP / VMID / display | 219 / 54219 / 219 / :119 | 220 / 54220 / 220 / :120 |
| Container uid base | 2621440 | 2686976 (41 x 65536) |
| Assets | `assets/nokia9300` | `assets/nokia9300rom` (own `eka2l1/`, and an own `rootfs/` shifted to its uid base) |
| Network | retronet web plane (netns cage) | off (`--private-network`, lo only) |

The launcher, the inner script and the keymap are nokia9300's files. They are emitted
from `streamhost/stations/nokia9300/`. The station owns only its
`station.env.fixture`.

## Known limits of the ROM track at ac7c1e126

- **Pointer.** Desk ignores icon clicks, in the HLE build as well. The 9300 has no
  pointer anyway, so the station publishes none.
- **Kiosk verbs.** `ekactl list`, `focus` and `switch` read the ROM window server
  through worker D's bridge. The bridge answers `ERR ROM window bridge not ready`
  until the SysState helper publishes its first snapshot. `quit` does not depend on
  the bridge, so Restore and the daemon's auto-reset (quit, then relaunch from the
  golden) work.
- Full phone-side Starter boot is not supported. The controlled service set replaces
  it; see the fork's Z4 A report.
- ROM FBS (`s80-rom-fbs`) is not in this build; HLE FBS draws the bitmaps.

## Re-pin

```bash
# merge the new branch into fork s80-rom-station and push; set EKA2L1_FORK_PIN in
# scripts/build-guests/tiles/nokia9300rom.sh and emulator.source in the registry row; land; then
scripts/dev/labrun -c 'bash /data/kernel-hive/scripts/build-guests/tiles/nokia9300rom.sh --build'
ssh lab 'systemctl restart streamhost@nokia9300rom'
```

The build tree is `/data/vms/sandbox/BUILD-eka2l1-rom`. The build root is nokia9300's.
The previous install is kept as `assets/nokia9300rom/eka2l1.prev`.

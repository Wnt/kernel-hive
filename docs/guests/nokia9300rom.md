# nokia9300rom guest

Status: **HIDDEN comparison station** (dark-launched 2026-09-25 by agent D5). It is
not a museum exhibit. It sits beside [`nokia9300`](nokia9300.md) so the operator can
compare the HLE track with the full ROM stack by eye at `/os/nokia9300rom` and `/os/nokia9300`.

## What differs from nokia9300

Everything not listed here is nokia9300's; read [nokia9300.md](nokia9300.md).

| | nokia9300 | nokia9300rom |
|---|---|---|
| EKA2L1 fork branch | `s80-integration` (HLE window server) | `s80-rom-full` @ 20ee52b11 (Z4 worker F) = ROM boot (A) + ROM input (B) + the ROM window bridge (D) + ROM FBS (E) + the HLE font-size fix, on `s80-integration` @ b1fec4a28 |
| Emulator env | none | `EKA2L1_ROM_WSERV=1 EKA2L1_ROM_FBS=1` (fixture `NOKIA_EMU_ENV`): the firmware's own window server (`ewsrv.exe`, which also selects ROM Eikon) and font and bitmap server (`fbserv.exe`) run. The switches are presence-tested: remove one to disable it, never assign 0. Never set `EKA2L1_ROM_STARTER` or `EKA2L1_PRESTART` |
| Golden | v3.1 | v3.1 + `C:\System\Programs\SysState.exe`, the resident state publisher that the ROM window server's `STARTUP` directive launches. It also feeds the ROM window bridge. This is Z4 worker F's rebuild of `tools/s80-sysstate` at 20ee52b11, sha256 6e8b2068…fac0; an older helper boots but cannot serve `list`/`focus`/`switch`. The fork overlays that directive at runtime, and no ROM file changes. The overlay is staged at `/data/assets-staging/symbian-s80/nokia9300rom-overlay` with its `MANIFEST.sha256` |
| Slot / UDP / VMID / display | 219 / 54219 / 219 / :119 | 220 / 54220 / 220 / :120 |
| Container uid base | 2621440 | 2686976 (41 x 65536) |
| Assets | `assets/nokia9300` | `assets/nokia9300rom` (own `eka2l1/`, and an own `rootfs/` shifted to its uid base) |
| Network | retronet web plane: netns `rn-nokia9300`, 10.99.0.43 | retronet web plane in its own netns cage: `rn-nokia9300rom`, veth `nokia9300romrn0`, static 10.99.0.44, guard `NOKIA9300ROMRN-IN` ([WEB-STATION-nokia9300rom.md](../lab/retronet/WEB-STATION-nokia9300rom.md)) |

The launcher, the inner script, the retronet helper `rn-netns.sh` and the keymap are nokia9300's files. They are emitted
from `streamhost/stations/nokia9300/`. The station owns only its
`station.env.fixture`.

## Known limits of the ROM track at 20ee52b11

- **Pointer.** Desk ignores icon clicks, in the HLE build as well. The 9300 has no
  pointer anyway, so the station publishes none.
- **Kiosk verbs.** `ekactl list`, `focus` and `switch` read the ROM window server
  through worker D's bridge. The bridge answers `ERR ROM window bridge not ready`
  until the SysState helper publishes its first snapshot. `quit` does not depend on
  the bridge, so Restore and the daemon's auto-reset (quit, then relaunch from the
  golden) work.
- Full phone-side Starter boot is not supported. The controlled service set replaces
  it; see the fork's Z4 A report.
- Fonts are not device-identical; worker F's DIFF lists the remaining visual differences.

## Re-pin

```bash
# set EKA2L1_FORK_BRANCH/EKA2L1_FORK_PIN in scripts/build-guests/tiles/nokia9300rom.sh and
# emulator.source in the registry row; land; box-deploy --apply; then
scripts/dev/labrun -c 'bash /data/kernel-hive/scripts/build-guests/tiles/nokia9300rom.sh --build'
ssh lab 'systemctl restart streamhost@nokia9300rom'
```

The build tree is `/data/vms/sandbox/BUILD-eka2l1-rom`. The build root is nokia9300's.
The previous install is kept as `assets/nokia9300rom/eka2l1.prev`.

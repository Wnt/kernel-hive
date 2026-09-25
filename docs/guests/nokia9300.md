# Nokia 9300 Communicator — Series 80 v2 — gallery station notes

Status: **DARK-LAUNCHED, baked** (2026-09-25, agent D2) — registry entry
`listing.state: hidden` (listing is the operator's call), host-native EKA2L1 in a
systemd-nspawn sandbox, the daemon capturing a pinned 1280x400 Xvfb whose root
is the 640x200 inner screen at exactly 2x. Measured facts only; the museum's
prose comes later. Research record: `docs/lab/research/candidate-symbian-s80.md`
(branch `worktree-symbian-s80-research`).

**Guest:** an emulated **Nokia 9300 Communicator** (type RAE-6; TI OMAP1510,
ARM925T at 150 MHz, 64 MiB RAM, 640x200 inner display in 65,536 colours, full
QWERTY keyboard, clamshell) running its **own firmware 5.22 of 2005-11-16** —
Symbian OS 7.0s (EKA1 kernel) with the Series 80 v2 interface. The station
opens at **Desk**, the Series 80 shell: date header, the Personal / Office /
Media / Tools groups, Clock and Nokia.com, and the status pane at the lower
left (skin, no-network and battery indicators). No pointer and no touchscreen: Series
80 is driven by four command buttons beside the screen, eight application
buttons below it, a joystick and the keyboard.

## Identity

- Public ID / station dir: `nokia9300` (registry id == `stationDir` == `SH_STATION`)
- Slot / UDP port / VMID: `219` / `54219` / `219`; Xvfb display `:119`;
  container uid base `2621440` (40 x 65536) — all `kh-claim`ed by session `nokia9300`
- SPA: archetype `putty-lcd` (early-2000s flat LCD; `touch-phone` would put a
  keyboard-only exhibit on the touch recognizer), ui kind `mobile`, keyboard
  family `nokia9300`. Scene tuple `modernMini,lcdA,keyboardH,none` is
  PROVISIONAL — the hall has no clamshell Communicator mesh.

## Emulator

**EKA2L1**, the Symbian HLE emulator, from our fork `github.com/Wnt/EKA2L1`,
branch **`s80-integration` @ `fa385d47a`** (GPL-3; pinned in
`tiles/nokia9300.sh`). Agents I2/I3 merged every Series 80 branch of the
2026-09-24 wave onto upstream master `39858137e`: the 7.0s window-server
tables (F1), application buttons in the window server (B1), the ROM's own
keyboard tables (K1), the museum kiosk frontend and `ekactl/1` control socket
(B2), Desk content (B6), the third-app fix (B4), an HLE DOS server (B5), Opera's
home page (N7), icon masks (A1), clock faces (A2), Messaging folders (M1) and
the Telephone directory (T1: SecurityServer pre-started + a Phone Server stub),
and the Series 80 status pane painted under the HLE Eikon server (S1). Built on labhost by
`scripts/build-guests/emulators/build-eka2l1.sh` (agent D1's branch
`eka2l1-builder`: pinned fork commit, trixie build root under nspawn, shared
ccache, mold; the configure stamp is gated, so the binary logs
`EKA2L1 v0.0.1 (s80-integration-fa385d47a)`); 94 s incremental from the
previous pin, sha256 `d7cf295d…0b1b`.

Run protocol: `eka2l1_qt --device RAE-6 --run 0x101f8e4f` (Desk) with
`XDG_DATA_HOME` on a private data dir — EKA2L1 copies `compat/ patch/
resources/ scripts/` from its binary directory into `$XDG_DATA_HOME/EKA2L1` at
every start, so two instances must never share one — plus B2's kiosk flags
(`NOKIA_EMU_ARGS` in the fixture): `--kiosk --kiosk-scale 2 --kiosk-geometry
1280x400+0+0 --kiosk-home 0x101f8e4f --control-socket /work/run/ekactl.sock
--log-file /work/eka2l1.log --log-filter *:warn --no-console-log`. `--device`
must precede `--run`; `--run` swallows the next token unless it starts with
`--`. EKA2L1 ignores SIGTERM. `EKA2L1_ROM_EIKSRV` stays unset (the ROM shell is
not proven). It needs an X server with GLX; Xvfb + Mesa llvmpipe works.

## Golden (never in git — Nokia firmware, SDK fonts)

An EKA2L1 XDG data root: `EKA2L1/config.yml` and
`EKA2L1/data/{devices.yml, roms/rae-6/SYM.ROM, drives/{c,d,e,z}}`.

- Base: agent I2's proof golden — agent F1's working data dir `xdg-9300` of
  2026-09-24 (agent S's registration of the 9300 dump staged under
  `/data/assets-staging/symbian-s80/eka2l1-dumps/`) plus
  `C:\System\SharedData\10000865.ini`: the ROM's own default (UTF-16LE with
  BOM, CR-separated) with `LanguageSelectionDone=1`, so Startup's first-boot
  language wizard (which captures the application keys and Menu) never runs.
- The four Series 80 UI TrueType fonts in `Z:\system\fonts`
  (`swabiu/swabru/swariu/swarru.ttf`, 136 716 / 117 256 / 117 012 / 117 140 B,
  sha256 prefixes `d736f2ff` / `84f22b39` / `d2ae12fa` / `85a65da2`) from the
  S80 DP2.0 SDK's Z: drive: both dumps lack them (the ROM's own `missing.txt`
  names them) and the UI otherwise falls back to a serif.
- `devices.yml` `machine-uid: 270503387` = 0x101F8DDB, the 9300's own value.
- `config.yml`: `keyboard-layout-index: 0` (UK EKDATA), `enable-upnp: false`.
- Agent B6's Desk first-boot state (`apply-desk-state.sh`):
  `C:\System\Data\Shortcuts.dat`, `C:\System\Apps\desk\desk.ini`,
  `C:\System\SharedData\101f8e4f.ini`.
- Ledger: 3256 files, 68 635 694 B; tree manifest sha256
  `ef30659b75718e859a8ed58585385f6667c63a4925c04843e79cf62a5ef15469` (sha256 of
  `find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum` inside the
  root). `SYM.ROM` 17 825 792 B, sha256
  `ca4b0bc929519b046994c8501b0135b688d8d7910d6669f4791805e3ab373596`.
- Staged on labhost at `/data/assets-staging/symbian-s80/nokia9300-golden/xdg`
  (+ `MANIFEST.sha256`; `xdg.v1` = the previous golden);
  `tiles/nokia9300.sh --golden` hash-gates it and installs `$STATION/golden`,
  keeping the previous as `golden.prev`.
- Time zone: the container runs `TZ=Europe/Helsinki` (`NOKIA_TZ`); EKA2L1 seeds
  the guest's UTC offset from the host's local time (`kernel.cpp`), so the guest
  clock is Helsinki time. The Clock's HOME CITY stays "New York, NY": selecting
  Helsinki in Clock → Change city finds it but never commits — the Clock thread
  hits `Unimplemented system call: 0xC00049` (`euser.dll` ord 107). Fork item.
- No `hosts:` map yet: there is no network plane to name (see Network).

## Sandbox

`streamhost/stations/nokia9300/x11-runtime.sh` starts `systemd-nspawn`
(`--as-pid2`, private PID/mount/net/user namespaces, host uids 2621440+, the
rootfs `--volatile=overlay`, capabilities dropped, `~@mount` filtered, no new
privileges, `--private-network`): the EKA2L1 build dir bound read-only at its
own host path, the golden read-only at `/golden`, `work/` and the X socket dir
the only writable binds; `/tmp/.X11-unix/X119` on the host is a symlink to the
sandbox's socket. The runtime root is D1's trixie tree (Qt 6.8.2 + Mesa +
Xvfb, version-matched to the build root), shifted to 2621440.

- Reaper: scoped by DESCENT from this launch's nspawn pid (perq measured a rig
  and the live station reaping each other by exe path alone). It SIGKILLs the
  container's init (nspawn's direct child) and lets nspawn exit and clean up:
  measured, a SIGTERM to nspawn never reached the inner script, and SIGKILLing
  nspawn itself orphaned the container and left
  `/run/systemd/nspawn/unix-export/<machine>` ("Mount point … exists already").
- `nokia9300-inner.sh` is PID 2: Xvfb, then EKA2L1 in a supervised loop — a
  fresh golden copy per launch, relaunch whenever it exits (with
  `--kiosk-home` EKA2L1 itself restarts Desk when the last app exits, so this
  catches crashes), three exits inside 20 s back off 60 s. The launcher keeps
  `mame.pid` on the current emulator for the daemon's idle freezer.
- Control socket: `ekactl/1` at `$BASE/work/run/ekactl.sock` on the host.

## Geometry

- With B2's kiosk frontend the window IS the 1280x400 root (`--kiosk-scale 2`,
  nearest filtering): the guest's 640x200 at exactly 2x, 0 of 128 000 2x2
  blocks non-uniform in a captured Desk frame. The inner script only waits for
  the window at `0 0 1280 400` and pins X focus to it.
- Without `--kiosk` (a plain `eka2l1_qt`), the inner script falls back to
  placing the Qt window itself: it finds the display widget (the parent of the
  unnamed GL child), resizes the top-level by the difference and moves it so
  the widget sits at (0,0) — offsets measured, never assumed (menubar 22 px on
  CT950, 19 px in the trixie root) — and a keeper re-places it after EKA2L1's
  own Ctrl+F fullscreen toggle. The GL surface resizes lazily, so placement
  must happen before the first guest frame.

## Input — keys only, over XTEST (keymap contract v3, agent K1)

The fork runs the ROM's own `EKDATA.DLL` tables (EKTRAN's algorithm), so Shift,
Ctrl, Chr and Caps behave as on the device; printable characters are injected
as their own keysyms and the fork types the 9300 key that produces them.

| Key | Keysym | Key | Keysym |
|---|---|---|---|
| command buttons 1–4 (top to bottom) | `F1`–`F4` | Menu | `Menu` |
| Desk, Telephone, Messaging, Web | `F5`–`F8` | Chr | `ISO_Level3_Shift` (Alt_L/Alt_R aliases) |
| Contacts, Documents, Calendar, My own | `F9`–`F12` | joystick centre/up/down/left/right | `F13`–`F17` |

- SPA: family `nokia9300` (`spa/src/ui/keyboard/keyboardProfiles.data.handheld.ts`)
  — base rows = the eight application buttons, then the four command buttons,
  Menu, Esc, Enter, Backspace, the Chr (sends `Alt_R`), Ctrl and Shift latches
  and the arrows (agent D3's QA: landscape hides `moreRows`); more rows = Tab,
  Space and the joystick. `KEYSYM_TO_SCANCODE` gained F13–F17 = set1
  `0x64`–`0x68`.
- Daemon: `SH_X11TEST_KEYMAP=x11test.keysyms` — the fleet's US table plus
  F13–F17 and `0xe038` → `ISO_Level3_Shift`; all 108 scancodes resolve.
- Xvfb: a runtime remap does NOT stick on Xvfb 21.1 (measured on trixie 21.1.16
  and Ubuntu 21.1.12: `xmodmap` and an `xkbcomp` upload exit 0 and change
  nothing, even for a plain letter), so K1's `station-xmodmap.txt` is realised
  at server start instead: Xvfb runs `-xkbdir` on a copy of the XKB data whose
  `symbols/inet` binds F13–F17 and the contract's `EuroSign`, `sterling`,
  `adiaeresis`, `odiaeresis`, `aring`, `ae`, `oslash` (only the keysyms matter;
  the daemon and xdotool resolve keycodes from the live map). `-ardelay 65000`
  is the `xset r off` (no xset in the root); EKA2L1 makes the Series 80 repeats
  itself.
- Pacing 150/150 ms (contract v3: EKA2L1's key FIFO drops events under load at
  faster rates).
- PROVEN through the real SPA (Chrome on the shared desktop → `/os/nokia9300` →
  streamhost x11test → XTEST), frames read out of the SPA's own `<video>`: F7
  opened Messaging (Inbox/Outbox/Drafts/Sent; a one-time "Cannot find message
  storage" note closes with Enter), F6 the Telephone directory, F10 Documents
  with `Nokia 9300 test 123` typed in correct case, F8 Web on the Nokia home
  page ("Complete"), F5 Desk — five apps alive at once.

## Boot and reset

`resetMode: relaunch` — kill the container, a fresh golden copy, cold start of
Desk: 6 s from launcher start to a placed Desk on the box (2026-09-25). Right
after a relaunch the live C: equals the golden except what the ROM writes in its
first second (ECom plugin cache, `sms_settings.dat`); B2's in-process `reset`
does not restore C:, so the station never uses it. EKA2L1 has no save state on
this path and the nspawn CRIU route is blocked by the sandbox's seccomp filter.
`bootrec-tiles.conf` is not armed.

## Period software

- Web = **Opera 6.0 for Symbian OS, build 543**: the about page inside
  `Z:\System\Libs\oprmodel.dll` (2 170 140 B, sha256
  `73b75dacc41b8ccb6290f4aa60dc35609aa359e23cb4af5437a2e1885e16f0f7`) reads
  "Opera 6.0 for Symbian OS - Alpha (543)", © 1995-2003 Opera Software ASA.
  It opens on the ROM's own local home page (the Nokia page), so it has a first
  screen without any network.
- Apps proven on s80-integration by agent I2: Desk, Documents, Web, File
  manager, Contacts, Clock (both faces), Sync, Write note, three at once.
  Since 3f8b52782 Messaging shows its folders and Telephone its directory.

## Network

None yet: the container runs `--private-network` (lo only). Opera's plane is
agents N1–N7's — through a netns on retronet (the amigaos35/nextstep precedent)
and/or EKA2L1's own `hosts:` map in `config.yml` for the names. No retronet
reservation is held and no `rn-tapnet.sh` is committed until the plane is
proven (AGENTS.md rule 15).

## Dark launch (before the branch lands)

`/os/nokia9300` is a sandbox rig published with
`scripts/dev/darklaunch-station.py publish nokia9300 --rig
/data/vms/sandbox/nokia9300/smoke --entry <entry.json>` (the entry rendered
from this registry row by `emit_gallery_manifest`, order 900, `listed: false`).
Not `smoke-rig.sh --like`: its stream.env step starts a daemon on the sibling's
LIVE display before it can be patched for an x11 rig.

- Launcher: this branch's `x11-runtime.sh`, unmodified, in a transient
  `kh-nokia9300-rig*.scope` with `NOKIA_BASE=/data/vms/sandbox/nokia9300/smoke`,
  the emulator and runtime root from `/data/vms/sandbox/s80-eka2l1/`
  (`out/eka2l1` = the s80-integration build, `out/eka2l1.prev` the previous),
  `NOKIA_MACHINE=kh-nokia9300-rig`, `NOKIA_X11_SOCKDIR=/run/streamhost/x11/nokia9300-rig`.
- Daemon: lisa's released binary, `<rig>/run-daemon.sh` + `<rig>/stream.env`
  (x11 capture of `:119`, x11test keys with the station keymap, 150/150 pacing,
  `SH_IDLE_PAUSE_SECS=0`). Restart it after every relaunch.
- Withdraw: `darklaunch-station.py withdraw nokia9300`, `systemctl stop` the
  rig scope, kill `<rig>/daemon.pid`.
- A host reboot takes the rig down and wipes `/run/kh-claims` (tmpfs): re-take
  the claims, relaunch, restart the daemon. The `darklaunch.d` declaration
  survives on `/data`.

## Known gaps / OPEN

- Clock home city: Change city → Helsinki does not commit (SVC `0xC00049`
  unimplemented); the guest clock is Helsinki time through `TZ`, the label says
  New York.
- The status pane (lower left) shows the skin and the no-network and battery
  indicators but no clock yet (S1 may add it).
- Messaging opens with a one-time "Cannot find message storage. Try restoring
  from a backup." note (Enter closes it); baking the message store into the
  golden would remove it. Menu hold (task list): `CaptureLongKey` unhandled.
- Command-button acceptance per app (agent X1, the real platform): Desk = Open /
  Write note / Note list; Documents = Insert object / Font / Style / Exit; Web =
  Open Web address / Back / Bookmarks / Exit; Sheet = Edit / Insert function /
  Clear / Exit — I2 proved Desk F2 (Write note) and Web F1; the rest are not
  pressed on the station yet.
- `£` (Shift+3) cannot be typed from the on-screen keyboard (no sterling
  scancode on the SPA wire); `€` is Chr+4.
- Hall scene: no clamshell mesh (provisional tuple); poster prose is a
  placeholder.

# fmtowns — Fujitsu FM TOWNS, Towns OS V2.1 L51 (TownsMENU)

Status: **native, keyboard, golden restore, pointer (click/drag/motion) and
`/os/fmtowns` publish all proven on the framebuffer** (2026-09-13); the
station is landed and listed. Command Mode / MS-DOS prompt and the other
TOWNSSYSTEM icons are still not opened (no keyboard-only launch path found for
them). See [`docs/lab/FMTOWNS-WAVE.md`](../lab/FMTOWNS-WAVE.md) for the
ledger, the race and every proof frame. This file is the station's operating
manual; every number in it is measured or marked OPEN.

## Identity and source

- Public ID / station dir: `fmtowns`; slot / UDP / VMID `196` / `54196` / `196`;
  x11warp display `:96` (allocated, inert while `SH_CAPTURE=shm`).
- Guest: Towns System Software V2.1 L51 (Fujitsu, 1995) — Towns OS, whose
  desktop is TownsMENU over an MS-DOS kernel. It boots **from the CD**; no
  hard disk is installed (the richer MS-DOS 6.2 + Towns OS on a 512 MB disk
  is a later golden, OPEN).
- Media: five Fujitsu system ROMs (MAME 0.272 merged `fmtowns.7z`) and the
  System Software CD (CloneCD image from the Neo Kobe FM Towns set) — URL,
  size and sha256 pinned in `scripts/build-guests/tiles/fmtowns.sh`; bits under
  `/data/assets-staging/fmtowns/` and `/data/vms/streamhost/assets/fmtowns/`,
  never committed.
- Retronet: none — Towns OS V2.1 ships no TCP/IP stack, so the station was
  allocated without `--retronet` on purpose.

## Emulator and device set

- Host-native MAME (fleet pin 0.289) via
  `scripts/build-guests/emulators/native.d/fmtowns.sh` and the shared
  `streamhost/stations/mame-native/x11-runtime.sh` launcher: drawshm frames,
  ctlsock keys through `streamhost/stations/fmtowns/fmtowns.keymap`, FIFO
  audio. Machine and exact device set: see the wave doc's race table (the
  machine is the one whose romset the staged ROMs boot the CD on).
- `-pad1 townspad -pad2 mouse` (driver defaults, set explicitly), `-cdrom
  <townsos-v21l51.chd>` composed by `tiles/fmtowns.sh` with `chdman createcd`.
- Every fmtowns-family machine is `MACHINE_NOT_WORKING`; the binary carries
  `mame-irix-skip-warnings.patch` and the fixture sets
  `MAME_NATIVE_SKIP_WARNINGS=1`, otherwise the warning panel pauses the
  headless kiosk forever (atari800xl/domainos finding).

## Golden, input, reset

- Reset = relaunch restoring the golden save state (`MAME_NATIVE_CHECKPOINT=1`).
  Measured: `SAVEST` at the settled TownsMENU desktop took 334 ms and wrote
  797 714 bytes to `sta/fmtownsftv/golden.sta`; a FRESH process relaunched with
  `-state golden` against the real station dir settled in 5.2 s (CD mount
  included) to a frame pixel-identical to the capture except a 1×9 px sliver
  at the on-screen clock glyph (the guest reads real wall-clock time). Proof
  frames: `docs/lab/FMTOWNS-WAVE.md` §Proofs.
- Keyboard: real ctlsock `KEY` path through the generated
  `fmtowns.keymap` (79 of 146 dumped fields matched; `mame-keymap.py` against
  the live rig). Proven: `Ctrl`+`Esc` (`:key3 Ctrl` + `:key1 ESC`) opens the
  guest's own タスクリスト (Task List) dialog; pressed again from there it opens
  a DIFFERENT dialog (サイドワークリスト), proving each keypress is read live,
  not a cached/looping frame. Fleet floor pacing (80/80 ms hold/gap) inherited
  from the samcoupe fixture; no dropped/duplicated characters observed in this
  station's limited test (no full sentence typed yet — the desktop has no
  reachable text field without a working pointer).
- Pointer: the Towns mouse is `-pad2 mouse`, an MSX-protocol mouse
  (`bus/msx/ctrl/mouse.cpp`) — genuinely RELATIVE, tagged
  `:pad2:mouse:BUTTONS`/`MOUSE_X`/`MOUSE_Y`, NOT the SGI Indy's
  `hle_ps2_mouse` the fleet ctlsock module hardcodes. **PROVEN 2026-09-13**:
  `mame-ctlsock-ptr-tags.patch` (with a type-based Mouse-X/Y binding fix
  layered on top — pad2's fields are named `Mouse X 2`/`Mouse Y 2`, not the
  module's hardcoded `Mouse X`/`Mouse Y`) binds the fields; ctlsock setup now
  reads `btns=1 axes=1 movea=0 devxy=0 swap=0 sig=1ebe131a entries=3330` —
  `sig=`/`entries=` unchanged from the pre-patch binary, so the golden `.sta`
  is not orphaned (rule 6). `mame-ctlsock-btn-active-low.patch` is
  DELIBERATELY not applied and `MAME_CTL_BTN_ACTIVE_LOW` must stay unset: MAME
  already applies the MSX BUTTONS port's `IP_ACTIVE_LOW` itself, so setting
  the env inverts an already-inverted polarity and turns every click into a
  no-op (measured with `kh-fmtowns-padport-debug.patch`: `DOWN1` takes the
  guest-read byte from `raw=f0` to `raw=e0`, bit 4 low = pressed, with the env
  UNSET). Motion measured ~6 px/count on both axes, positive sign, truncated
  to a signed byte per poll so a single `MOVE` must stay under 127 counts
  (`SH_REL_MAX_STEP=100` in the fixture). Click: a plain click on a desktop
  icon draws NOTHING by TownsMENU's own design (no hover/selection feedback);
  clicking inside an inactive window's client area activates/raises it —
  proven 8/8 alternating clicks between two windows (>31 000 changed px,
  `fb-react.py` masked diff, 100 ms hold already lands). Drag proven too (a
  held button + `MOVE` steps dragged a window 191×79 px). See
  `docs/lab/FMTOWNS-WAVE.md` §Pointer, "Pointer stream 2026-09-13 #2".
- Credentials: none (`guest/fmtowns` is a placeholder reference).
- Rollback: `/os/fmtowns` is dark-launched and then landed via
  `scripts/dev/darklaunch-station.py` (`smoke-rig.sh` does not fit a
  MAME-native/shm-capture rig — see the wave doc's §Publish for why); the
  station is `listing.state`-free (listed) since 2026-09-13.

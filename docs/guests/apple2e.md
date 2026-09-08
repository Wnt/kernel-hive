# Apple //e (enhanced, 1985) — ProDOS boot menu station (:54185)

**Guest:** a **host-native** MAME 0.289 station — the daemon runs the emulator
directly on the host (drawshm frames, ctlsock keys, FIFO audio), no bridge VM,
no guest OS, no QMP. MAME's **`apple2ee`** driver (`src/mame/apple/apple2e.cpp`)
emulates an **Apple //e (enhanced), 1985**, 65C02 @ 1 MHz with 128 KB, drawn at
560×192 with aspect correction on the published 1024×768 surface. See
**`docs/guests/mpf2.md`** for the closest sibling recipe (same `apple/` driver
family) and `streamhost/docs/BRIDGE.md` is NOT applicable here — this station
has no bridge kiosk at all.

**The Machine:** the Apple II most people actually used, not the 1988 GEOS
desktop the sibling `apple2` station shows. This station boots **ProDOS 8**
into a one-keypress Applesoft **STARTUP** menu — the Apple II's own
`AUTOEXEC.BAT` — reaching **AppleWorks 3.0** (the 80-column productivity
suite) and **Dazzle Draw 1.2** (double hi-res paint), the two period-typical
programs the 8-Bit Guy's *"How the Apple ][ Works!"* names as the machine's
signature use cases. `apple2e` and `apple2` are siblings that show the same
hardware two ways: as it was used, and as it was later persuaded to look.

**Build scripts:** `scripts/build-guests/emulators/native.d/apple2e.sh` builds
the host-native `apple2ee` MAME binary (device set, ROM staging, boot gate);
`scripts/build-guests/tiles/apple2e.sh` composes the `/HIVE` ProDOS hard-disk
volume (`hive.hdv`) that the emulator boots from, fetching pinned media with
`a2kit` and writing the tokenized `STARTUP.bas` menu onto it.

**Station dir (host):** `/data/vms/streamhost/stations/apple2e/` —
`ctl.sock`, `apple2e.keymap`, `station.env.fixture`, `audio.fifo`,
`sta/apple2ee/golden.sta` (the savestate reset restores).

## License / provenance
- **MAME `apple2ee`** — emulation driver in `src/mame/apple/apple2e.cpp`,
  GPLv2 licensed, `MACHINE_SUPPORTS_SAVE` (unlike `mpf2`, no skip-warnings
  patch or checkpoint workaround is needed — the shared launcher's checkpoint
  restore applies unmodified).
- **Apple //e ROMs** — `342-0265-a.chr`, `342-0304-a.e10`, `342-0303-a.e8`,
  `341-0132-d.e12` (main driver), plus sub-device ROMs the Disk II controller
  (`341-0027-a.p5`, `d2fdc`) and the Mouse Card's MC68705 sub-CPU
  (`m68705p3` bootstrap) need — the latter two are not folded into
  `apple2ee`/`a2diskiing`/`a2mouse`'s own `-listxml` `<rom>` lists; found only
  by running the staging gate and reading its "NOT FOUND" lines (2026-09-08).
  ROM staging lives under `/data/assets-staging/apple2e/roms/`; the built
  binary installs to `/data/vms/streamhost/assets/apple2e/mame-native/`.

## Device set
- **Slot 4:** Apple II Mouse Card (`-sl4 mouse`) — the mouse ioports (below).
- **Slot 6:** Disk II NG controller (`-sl6 diskiing`, the driver's own
  default, set explicitly so a future MAME default change can never silently
  drop it).
- **Slot 7:** CFFA 2.0 (`-sl7 cffa2`, 65C02 firmware) — the ProDOS hard-disk
  volume boots from here (`-hard1 hive.hdv`); the //e scans slots 7→1, so a
  slot-7 hard disk wins over the empty slot-6 floppy.
- **Aux slot:** `ext80` (default, 128 KB) — 80-column card, required for
  AppleWorks' 80-column display.

## Boot volume (media stream)
`hive.hdv` is a 32 MB ProDOS-order raw-block image, composed by
`scripts/build-guests/tiles/apple2e.sh` with `a2kit` from pinned Asimov-mirror
media:

| Content | Source image | SHA-256 |
|---|---|---|
| ProDOS 2.4.2 kernel + BASIC.SYSTEM | `masters/prodos/ProDOS_2_4_2.dsk` | `d1e6fab8d9a25acf6e10ffa15e4120a616898c0…` (full hash in the builder / `docs/lab/ASSETS-MANIFEST.md`) |
| AppleWorks 3.0 (`/HIVE/AW`) | `Appleworks30.2mg` | see `docs/lab/ASSETS-MANIFEST.md` |
| Dazzle Draw 1.2 (`/HIVE/DAZZLE`) | `Dazzle Draw v1.2 (Broderbund-1988).dsk` | see `docs/lab/ASSETS-MANIFEST.md` |

ProDOS 2.4.2 (John Brooks) was picked over Apple's own 2.0.3 because it
already carries `BASIC.SYSTEM`, the program ProDOS auto-boots into, which in
turn auto-runs a root-level Applesoft program named `STARTUP` — the Apple
II's `AUTOEXEC.BAT`. Exact file lists and every sha256/size are in
`scripts/build-guests/tiles/apple2e.sh` and `docs/lab/ASSETS-MANIFEST.md`.

**Angry Birds is NOT staged.** 8-Bit Shack's free 2023 download is gone (the
site now sells it for $35); the builder carries `ANGRYBIRDS_DSK_URL` /
`ANGRYBIRDS_DSK_SHA256` hooks and a `@BIRDS@` token in `STARTUP.bas` that the
build substitutes with `1`/`0` — at `0` the `[3]` menu line, key and prompt
digit all disappear rather than advertise a missing entry. See
`docs/lab/APPLE2E-WAVE.md` for the open item.

## The STARTUP menu (`scripts/build-guests/assets/apple2e/STARTUP.bas`)
A tokenized Applesoft program (loads at $0801), the Apple II's version of the
FreeDOS station's `MENU.BAT`: `HOME`, a boxed 40-column list, `GET K$`, and
per choice `PRINT CHR$(4);"PREFIX /HIVE/AW"` then
`PRINT CHR$(4);"-APLWORKS.SYSTEM"` (the `-` command runs SYS/BIN/BAS files).
Choices: **[1]** AppleWorks 3.0, **[2]** Dazzle Draw 1.2, **[B]** BASIC
prompt (`RUN STARTUP` returns to the menu). Reset (relaunch) always lands
back on the menu.

## Curated metadata (for the UI placard)
- **Year:** **1985** (Apple //e enhanced).
- **Lineage:** Apple II / ProDOS. MOS 65C02 @ 1 MHz, 128 KB.
- **One line:** *"The Apple II most people actually used: ProDOS, a
  40-column boot menu, AppleWorks in 80 columns and Dazzle Draw in double
  hi-res on a 128 KB //e — plus a 2023 Angry Birds for the same machine."*
- **Iconic era software:** AppleWorks, Dazzle Draw, Applesoft BASIC, Angry
  Birds (8-Bit Shack, 2023 — not yet staged, see above).
- **Current archetype:** `beige-tower-crt`.

## Ports (assigned)
- streamhost UDP (WebTransport): **54185** (slot 185).
- No SSH/exec port and no QMP — host-native, no guest OS to reach.
- UI web port / VMID: **185**.

## Keyboard
The //e's keyboard is its own hardware encoder chip, **not** a CPU-scanned
matrix like `mpf2`'s — so unlike `mpf2`, `MAME_CTL_KEY_EXCL` is not expected
to be required, and the live proof agrees. Pacing is the fleet default:

- **`SH_KEY_MIN_HOLD_MS=40`**, **`SH_KEY_MIN_GAP_MS=40`** — not `mpf2`'s
  bisected 32/32; this driver's own hardware key encoder tolerates the
  fleet-floor pacing.

MEASURED on a live rig 2026-09-08 (golden stream): 40/40 ms with no
`MAME_CTL_KEY_EXCL` drives the entire visitor path with no dropped or
duplicated character — the menu selector, AppleWorks' one-time
`GETTING STARTED` date prompt (`Type today's date or press Return:`,
pre-filled `4/08/11`; Return reaches the Main Menu), and Dazzle Draw's title
screen (Space) and launcher panel (`Input Device: Mouse` / `File System:
Professional File`; Return reaches the canvas with the File/Tools/Edit/
Goodies/Undo bar). Rollover/overlap is not stress-tested.

## Pointer — OPEN item, ships keyboard-only
The Apple II Mouse Card is wired at the emulator layer (slot 4) but the
station's registry `stream.pointer.transport` is `"none"` and it ships
**keyboard-only**. MEASURED on the live rig 2026-09-08 (golden stream): the
ctlsock module's counts do reach the card's fields
(`MAME_CTL_PTR_TAGS=:sl4:mouse:a2mse_button,:sl4:mouse:a2mse_x,:sl4:mouse:a2mse_y`,
`STAT applied=4070,3740`) and Dazzle Draw's launcher panel already reports
`Input Device: Mouse`, but the arrow does not track: of four `MOVEA` targets
on the canvas only `MOVEA 500 300` moved it at all (tip landed at 400,260 —
0.80x/0.87x of target), the rest left it parked top-left, and plain
`MOVE 200 0` / `MOVE 0 200` moved it zero screen pixels. No
`MAME_CTL_CAL_X/Y` was set — the loss isn't a linear scale or a slow drift,
so calibration would only paper over an unknown cause. `MAME_CTL_PTR_MOD=256`
is set (the card's ioports are 8-bit fields, sensitivity 40 — NOT the
module's 65536 SGI default, which would saturate the axis on the first
slam). The registry also notes a separate, daemon-level blocker: MAME-sock
pointer mode is hardcoded to absolute in
`InputBackend::MameSock::pointer_mode()`, and the mouse card is
dead-reckoning relative-only (unlike newsos's Newport VC2 absolute
registers) — so this station cannot honestly claim an SPA pointer contract
even after the tracking bug is fixed. Both are open items for whoever owns
the pointer/backends plane next.

## Reset / checkpoint
`SH_RESET_MODE=relaunch`, restoring the MAME savestate at
`sta/apple2ee/golden.sta`. `apple2ee` has `MACHINE_SUPPORTS_SAVE`
(`MAME_NATIVE_CHECKPOINT=1` kept — the shared launcher's checkpoint restore
needs no per-station patching here, unlike `mpf2`). MEASURED 2026-09-08:
cold boot reaches the menu in **2.53–2.64 s** (5 runs); the golden savestate
restore lands in **0.52 s**; `SAVEST` itself takes **9 ms** and produces a
**26,800-byte** file. The restore was proven frame-identical to the cold-boot
menu twice: in-process (`LOADST` after dirtying the screen with `[B]`) and
across a relaunch with `-state golden`. The menu's Applesoft `GET` cursor
blinks, so a frame-settle rule watching this scene must accept a set of two
signatures, not a single still frame.

## Standby
Same contract as every converted station: the launcher freezes MAME once the
scene has painted; the daemon sends `SIGSTOP` after an idle grace and
`SIGCONT` unconditionally on the first session. `SH_IDLE_PAUSE_SECS=60`,
scoped by `SH_IDLE_PAUSE_PROC_MATCH=assets/apple2e/mame-native` so a deploy
never signals the wrong MAME process.

## Build status (2026-09-08)
- Live: registered VMID 185, UDP 54185, slot 185; `lifecycle: production`,
  `enabled: true`. Host-native from day one (Rule 13) — no bridge kiosk was
  ever built for this station.
- Keyboard: verified on the live rig, fleet-floor 40/40 ms pacing, whole
  visitor path (menu → AppleWorks → Dazzle Draw → BASIC → reset), no
  dropped/duplicated characters.
- Pointer: OPEN — wired but not tracking (see above); ships keyboard-only,
  `pointer.transport: "none"`.
- Angry Birds: gated out of the menu pending a reachable disk-image source
  (see `docs/lab/APPLE2E-WAVE.md`).

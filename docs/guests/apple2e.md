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

## Pointer — scale and origin fixed, residual drift still open; ships keyboard-only
`stream.pointer.transport` stays `"none"`. Three real mechanisms were found and
fixed in the station's binary (all wired in via
`scripts/build-guests/emulators/native.d/apple2e.sh`); what is left is not a
mechanism but an accumulation:

**1. A differencing window, not a lost write.** `src/devices/bus/a2bus/mouse.cpp`,
`a2bus_mouse_device::update_axis()`, differences successive reads of the 8-bit
`a2mse_x`/`a2mse_y` field and folds the result into ±0x80. So ONE field write
larger than 127 counts is read as motion *the other way*. Measured from the
left clamp on the Dazzle Draw canvas: `MOVE 10 → 36 px`, `MOVE 100 → 171 px`,
`MOVE 127 → 217 px` — perfectly linear — then `MOVE 130`, `160`, `200`, `255`
→ **no movement at all**, because the arrow ran left into the clamp.
`mame-ctlsock-move-step-cap.patch` caps the module's pacing budget at
`m_ptr_mod/2 - 1` whenever the accumulator is narrow and routes an oversized
`MOVE` through the paced queue; paced writes ≤ 127 track linearly with no loss.

**2. An open loop cannot learn a gain.** `MAME_CTL_CURSOR_ITEMS` is unset —
this machine has no readable cursor register — so `MOVEA` runs in the module's
open-loop mode. The gain learner (`learn_gain()`) is called only from
`observe()`, which runs only in the *closed* loop, so `m_gx`/`m_gy` stayed at
their hardcoded `1.0` forever and open-loop `MOVEA` issued Δpx straight out as
counts. The Apple //e's measured ratio is **1.547 px per count on X and 1.674
on Y**, so a 1.0 gain under-issues by about 40% — and because an open loop's
only origin is its own belief, every later relative target inherits the error.
`mame-ctlsock-open-loop-gain.patch` adds `MAME_CTL_GAIN_X` / `MAME_CTL_GAIN_Y`
(guest px per count, float, default 1.0) which seed the gain at setup and after
a state reload; open-loop `MOVEA` then issues `Δpx / gain` and the belief
integrates `counts × gain`, so both sides live in published pixels. It also
fixes the same branch's queued-remainder clamp simulation, which was adding
queue entries' *counts* to a *pixel* belief.

`MAME_CTL_CAL_X/Y` is **not** set and would be inert here: it calibrates a
cursor-*register* reading, and there is no register to read.
`MAME_CTL_SCREEN=1024x768` is set so the belief and every `MOVEA` target clamp
against this station's published surface rather than the module's 1288x1024
SGI default. `MAME_CTL_PTR_MOD=256` (the card's ioports are 8-bit fields,
sensitivity 40) — an unset MOD would saturate the axis on the first homing slam
exactly like the Atari ST's uncorrected case.

The fixture knobs, in full:

```
MAME_CTL_PTR_TAGS=:sl4:mouse:a2mse_button,:sl4:mouse:a2mse_x,:sl4:mouse:a2mse_y
MAME_CTL_BTN_NAMES=Mouse Button,,
MAME_CTL_PTR_MOD=256
MAME_CTL_SCREEN=1024x768
MAME_CTL_GAIN_X=1.547
MAME_CTL_GAIN_Y=1.674
MAME_CTL_HOME_SETTLE=750
```

**3. The homing slam does not die at the guest's clamp.** The open-loop branch
opened a session with `move_paced(-(18*m_move_step), …)` — 2160 counts — and
enqueued the first target's travel immediately behind it, on the standing belief
that "the overshoot must die against the guest's edge clamp before the real move
starts". It does not. The clamp that stops the **arrow** lives in the mouse
card's firmware, several stages downstream of the accumulator that nets our
counts: `update_axis()` does `m_count += diff` into a *signed, unbounded* total
and drains **one unit per MCU port-B read**. A 2160-count slam therefore parks
`m_count` near −2000, and the travel appended microseconds later is added to
*that number*, not to the arrow. The arrow moves by the net, the net is still
leftward, and the whole of the first target's travel is spent unwinding a slam
that had already reached the corner. An open loop's only origin is its belief,
so the deficit never cleared. `mame-ctlsock-home-drain.patch` sizes the slam in
pixels through the gain (`ceil(surface/gain) + m_move_step` per axis) and holds
the travel in a pending-home slot that `drain_move()` releases only once the
move queue is empty **and** the guest has had `MAME_CTL_HOME_SETTLE` ms of
quiet. It also clears `m_fl_valid` on a state load, so a restore re-homes
instead of stating a delta from a belief the restored arrow never shared.

### Measured, before the fix

MEASURED on a live rig 2026-09-08 (pointer stream), arrow tip located in the
framebuffer on the Dazzle Draw canvas (`x≥10`, `72≤y<640` — the canvas' left
border column is lit and is not the arrow):

| target | arrow tip | error px |
|---|---|---|
| (300,200) | off the canvas band | — |
| (700,500) | (411,320) | (−289,−180) |
| (150,600) | (10,424) — at the left clamp | (−140,−176) |
| (900,100) | off the canvas band | — |
| (300,200) | (152,112) | (−148,−88) |

Two *interior* targets 600 px apart (no clamp between them) landed at **0.988×**
of commanded on X and **0.940×** on Y: the scale was right all along, and the
origin was wrong by precisely the first target's travel.

### Measured, with the fix (`MAME_CTL_HOME_SETTLE=750`)

Same rig, same locator, a fresh session whose first `MOVEA` takes the homing
branch:

| target | issued counts | arrow tip | error px |
|---|---|---|---|
| (300,200) | 976, 698 | (302,196) | (+2,−4) |
| (700,500) | 259, 180 | (706,496) | (+6,−4) |
| (150,600) | 356, 60 | (150,600) | (0,0) |
| (850,150) | 452, 269 | (852,148) | (+2,−2) |
| (300,200) | 356, 30 | (293,200) | (−7,0) |

The origin deficit is gone: the first `MOVEA`'s 976/698 counts are the sized
slam *plus* the travel, issued in two breaths instead of one, and the arrow ends
up where it was asked to.

**The button works.** `MOVEA 293 22` onto the **Tools** menu followed by `DOWN1`
drops the menu open — Paint Brush / Spray Paint / Flood Fill / Zoom / Text /
Shapes / Lines, with the arrow sitting on the highlighted title. That is the
first framebuffer proof of a *click* on this station.

**A restore behaves.** `LOADST` of a copy of the golden mid-session leaves
`bel=0,0` in `STAT` (the open-loop belief is invalidated, `reseeds=2`), and the
next `MOVEA 300 200` re-issues the full slam — 976, 698, the same counts as the
session's first — and lands at (305,204), (+5,+4). The homing branch is paid
once per session *and* once per state load, exactly as intended.

### Why the pointer is still an open item

A **second lap** of the same five targets inside one session — no re-home, every
target taken by the belief branch — drifts:

| target | error px |
|---|---|
| (300,200) | (+5,+4) |
| (700,500) | (+13,+8) |
| (150,600) | (+4,+12) |
| (850,150) | (+6,+14) |
| (300,200) | (−4,+12) |

Worst 13 px on X and 14 on Y. This is not the origin bug returning: the
landings track the belief and the belief tracks the targets. It is per-move
quantization — `round(Δpx / gain)` counts issued, `counts × gain` integrated —
accumulating in an open loop that has no reading to correct against and never
re-anchors. Outside the ±6 px a published pointer contract needs, so
`stream.pointer.transport` stays `"none"`.

**Next step:** a periodic re-home on a quiet timer (the same branch, re-armed),
or a fractional-count carry in the open-loop branch so the rounding error does
not accumulate — measured over several laps, not one.

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
- Pointer: OPEN — the differencing window and the missing open-loop gain are
  fixed and the scale now tracks (1.529/1.573 px per count), but the homing
  origin is still ~147/85 px off; ships keyboard-only, `pointer.transport:
  "none"`.
- Angry Birds: gated out of the menu pending a reachable disk-image source
  (see `docs/lab/APPLE2E-WAVE.md`).

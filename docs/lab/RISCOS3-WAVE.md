# RISC OS 3.11 integration wave — 2026-09-20

RISC OS **3.11** (29 Sep 1992) on the **Acorn Archimedes 310** (1987), Tier 1,
host-native under a per-station MAME build (`SUBTARGET=aa310`, driver
`aa310`, `src/mame/acorn/aa310.cpp`, status **preliminary**). Tracking:
issue #47, prep branch `riscos3`. Scaffolded `--like apple2gs` for the
registry row shape and the shared host-native
`stations/mame-native/x11-runtime.sh` launcher convention only — the two
machines share nothing else (different driver, different keyboard/mouse
device model, a different pointer sensor).

**LIVE 2026-09-20.** Cold boot to Desktop 21 s; golden savestate restores the
Apps-window scene byte-identically; pointer 1:1 absolute, worst error 8 px X /
4 px Y over twenty spread landings (median within 2); all three Archimedes
buttons react with their own Select/Menu/Adjust semantics.

## Ledger — from `scripts/dev/wave.sh alloc riscos3`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 213 / 54213 / 213 |
| x11warp display | — (not allocated: host-native MAME, no in-guest X) |
| retronet address / MAC / tap / chain / UIN | — (none this wave — seed says "do not let networking block the desktop exhibit") |
| sibling (`--like`) | `apple2gs` |
| hardware tuple | `pizzaBoxF\|crtD\|keyboardA\|paramMouseD` — an A310 is a low beige base unit with a separate keyboard and the three-button Acorn mouse, not a tower |
| render orders | as scaffolded by `stations-registry.py new --like` — never hand-edited |
| device set | no extra devices: RISC OS 3.11 is ROM-resident on the `aa310`/bios=311 romset, no disk attached |
| media | staged under labhost `/data/assets-staging/riscos3/` — see Media below |

**Retronet: intentionally absent** — the integration seed calls for "no
networking blocking the desktop exhibit" in the first wave. No
`rn-tapnet.sh` is committed for this station (rule 15).

## Media — staged, hashed, pinned

Source: archive.org `mame-0.264-roms-non-merged` (a mirror of MAME's own
released romsets, matching the fleet-pinned MAME family exactly by member
sha1 — verified below, not trusted by filename).

| File | Bytes | SHA-256 |
|---|---|---|
| `aa310.zip` | 5211558 | `04d17d96963816721219691857af17e6439ae30088ebf2e89fac9d8b12d7194b` |
| `archimedes_keyboard.zip` | 1323 | `1d02b14cd4d2ff80a343c3afb1ba43de0bd77815952816fc19d0736f8644664e` |

Extracted to loose files (34 members) under `/data/assets-staging/riscos3/`
for `stage-romset.py`'s per-member sha1 match against the pinned binary's own
`-listxml`; `MANIFEST.sha256` (zips) and `MANIFEST-members.sha256` (loose
files) both live there. Verified with the system MAME 0.264 package
(`/usr/games/mame`, whose driver/romset metadata matches the fleet's pinned
0.289 for this driver): `mame -verifyroms aa310` → `romset aa310 is good`.

`bios=311` selects RISC OS 3.11 (`0296,041-02.rom`..`0296,044-02.rom`, four
524288-byte halves) plus `cmos_riscos3.bin` (the CMOS/RTC seed byte) and the
shared `archimedes_keyboard` MCU romset
(`acorn_0280,022-01_philips_8051ah-2.bin`).

## Smoke proof — MEASURED 2026-09-20 08:56 UTC

Command (system MAME 0.264, Xvfb `:1` on CT950, `import`-captured window):

```
mame aa310 -bios 311 -rompath roms -skip_gameinfo -sound none -window \
  -nomax -resolution 1024x768
```

`aa310` is `status="preliminary"` in `-listxml`, so the driver's own "known
problems" nag panel shows regardless of `-skip_gameinfo` (that flag only
skips the ordinary game-info screen); one keypress past it, and ~6 s later
the machine reaches the **RISC OS 3.11 Desktop**: mid-grey backdrop, icon
bar along the bottom (floppy icon at `:0`, an Apps directory viewer icon,
palette + Acorn icons at the right), pointer visible mid-screen. Frame
captured at `/data/vms/sandbox/riscos3-work/smoke/poll-6.png` (not
committed — binary artifact; the registry poster hero at
`spa/public/posters/riscos3/desktop.webp` still carries the copied
apple2gs placeholder and needs replacing from a real riscos3 rig frame).

The `mame-irix-skip-warnings.patch` (already in the tree, applied to every
`preliminary`/`imperfect` MAME native build via `NATIVE_SKIP_WARNINGS=1`)
removes that keypress for the exhibit itself.

## Native build

`scripts/build-guests/emulators/native.d/riscos3.sh` — driver `aa310`,
`NATIVE_SOURCES=src/mame/acorn/aa310.cpp`, `NATIVE_GEOM=1024x768`,
`NATIVE_MAME_ARGS=(-bios 311)`, `NATIVE_SKIP_WARNINGS=1`. Media staging is
`scripts/build-guests/tiles/riscos3.sh` (fetch + hash-gate + unpack; there is
no disk to compose).

```
scripts/build-guests/tiles/riscos3.sh          # ON THE BOX — see the trap below
scripts/build-guests/emulators/build-mame-native.sh riscos3
```

Patches, in order:

| Patch | Why riscos3 needs it |
|---|---|
| `mame-ctlsock` / `mame-drawshm` / `mame-kiosk-no-ui` | the fleet base trio |
| `mame-irix-skip-warnings` | `aa310` is `status="preliminary"`, so the red nag panel would BE the exhibit |
| `mame-ctlsock-ptr-tags` | the base module binds the SGI Indy's `hle_ps2_mouse` by hardcoded tag; the Archimedes mouse is `:keyboard:MOUSE.0/1/2` |
| `mame-ctlsock-btn-active-low` | in the chain because `ram-cursor` applies after it — but the KNOB IS NOT SET, see §Pointer (g) |
| `mame-ctlsock-ram-cursor` | supplies the `item@offset:width` cursor window and the `CAL_SX/SY` scale |
| **`mame-ctlsock-item-window-sized`** (new, authored here) | that window only accepted a BYTE array; the VIDC cursor register is an element of a `u32[16]` |
| **`mame-archimedes-kbd-mouse-carry`** (new, authored here) | upstream threw away the mouse's movement magnitude — see §Pointer (a) |

**A TRAP THAT COST THE FIRST BUILD.** `/data/assets-staging` is NOT the same
filesystem in CT950 as it is on labhost. ROMs staged inside the container are
invisible to the build, which fails with `FileNotFoundError:
'/data/assets-staging/riscos3'` *after* a full compile. Stage on the box.

Binary: `/data/vms/streamhost/assets/riscos3/mame-native/aa310`
(`sha256 543678a737748099f306b861644e0c70c47675d1597f815fd797b8a3a2e7b31c`,
MAME `mame0289`). Boot gate: 777760 lit pixels on the published surface.

## Framebuffer proof — 2026-09-20 10:42 UTC

First real frame from the pinned binary, `-video shm`, headless: the RISC OS
3.11 Desktop — mid-grey (`#777777`) Pinboard backdrop, the icon bar along the
bottom with the floppy at `:0`, the Apps directory viewer, the palette and the
Acorn task-manager icons, and the pointer mid-screen. 18 distinct colours;
the guest raster is 640x256 letterboxed into the published 1024x768 surface.

**A FALSE NEGATIVE WORTH KNOWING.** The first two captures came back as a
solid `(255,0,0)` 1024x768 raster and `fb-wait.py --settle` returned "settled,
last change at 0.0s". That is not a failure mode — it is MAME's red warning
panel plus a settle window that expired *before* the machine had finished
booting. **The RISC OS desktop is not "settled" at any useful moment early on;
wait for the ARROW SPRITE** (cyan `(0,255,255)` + dark blue `(0,0,153)`), which
is what every measurement script in this wave does.

## Pointer — 1:1 ABSOLUTE, closed loop, MEASURED 2026-09-20

The hard part of this station, and it failed twice before it worked.

**(a) The magnitude was discarded on the wire.**
`src/devices/machine/archimedes_keyb.cpp`'s `update_mouse` runs at 4 kHz and,
on ANY non-zero delta, advances the quadrature phase by exactly ONE step and
then assigns `m_mouse_x = x`. MEASURED: a 600-count `MOVE` advanced the
device's own `m_mouse_x` from 0 to 900 and moved the guest pointer **zero
pixels**. `mame-archimedes-kbd-mouse-carry.patch` advances the recorded
position by one unit per tick and keeps the remainder — the same correction,
for the same reason, as the fleet's `mame-hle-ps2-mouse-carry.patch`.

**(b) Unpaced `MOVE` is not a measurement tool here.** `MOVE` is latest-wins
and slams the whole delta into the analog field in one write; `MOVEP`/`MOVEA`
pace it. Before (a) was found, pacing one count per emulated millisecond
(`MOVE_STEP=1 MOVE_WINDOW=1`) DID deliver motion — 1.493 cursor-register units
per count — which is how the register mapping below was measured at all. But
a MOVEA round is clamped to `MOVE_STEP`, so the closed loop gave up long
before crossing the screen: **ten targets, ten `giveups`, worst error 332 px.**
Every "the pointer does not move" reading taken during this bring-up was a
bare `MOVE`.

**(c) The sensor is the VIDC1a's own hardware cursor.**
`src/devices/machine/acorn_vidc.cpp` draws the sprite at
`m_crtc_regs[CRTC_HCSR] - m_crtc_regs[CRTC_HBSR]` /
`m_crtc_regs[CRTC_VCSR] - m_crtc_regs[CRTC_VBSR]`. `CRTC_HCSR` is index 6 and
`CRTC_VCSR` index 14 of `save_pointer(NAME(m_crtc_regs), CRTC_VCER+1)` — a
`u32[16]` — so the loop reads BYTE offsets 24 and 56, width 4. The ram-cursor
window refused the item for having `size=4`; relaxing that bound to the item's
byte capacity is all `mame-ctlsock-item-window-sized.patch` does. This is the
fleet's third hardware-cursor closed loop, after irix's VC2 and hpuxvue's
Artist — and the first where the register had to be addressed by index.

**(d) Calibration.** Fitted over 8 spread points, max residual **0.29 px X /
0.54 px Y**:

```
published_x = -177.309 + reg_x * 1.23127
published_y =  -58.056 + reg_y * 2.65502
```

The 640x256 raster is LETTERBOXED inside the 1024x768 surface, so the
reachable published rectangle is roughly **x 118..905, y 43..722**. The
fleet's usual corner targets (20,20)/(1000,740) are outside the guest raster
and no pointer can occupy them — pick targets inside the raster.

**(e) What it lands.** Five targets spread across the raster, two laps, arrow
tip located on the framebuffer (one representative run of the two taken):

| Target | Lap 1 | err | Lap 2 | err |
|---|---|---|---|---|
| (180,120) | (177,120) | (-3,+0) | (181,120) | (+1,+0) |
| (840,120) | (842,120) | (+2,+0) | (837,120) | (-3,+0) |
| (180,660) | (181,662) | (+1,+2) | (181,659) | (+1,-1) |
| (840,660) | (837,662) | (-3,+2) | (842,659) | (+2,-1) |
| (512,390) | (513,388) | (+1,-2) | (510,391) | (-2,+1) |

`giveups=0` throughout. Across BOTH runs — 20 landings — the worst was
**8 px X / 4 px Y** (one outlier, (180,660) → (188,659)); the median landing
is within 2 px. Learned gain 2.2–2.5 published px per count. RESOLUTION
BOUND: one quadrature count is 1.493 register units = 1.84 px across and
3.96 px down, so the loop lands on count boundaries and cannot do better than
about ±1 px X / ±2 px Y. For scale, an icon-bar icon is ~60 px wide on the
published surface.

**(f) All three buttons react, with their own semantics** — RISC OS is a
Select/Menu/Adjust desktop and a one-button proof would not be one. Five
spread clickable targets, each with its own reaction:

| Target | Button | Reaction |
|---|---|---|
| icon bar Apps (218,685) | Select | opens `Resources:$.Apps` (77287 px) |
| icon bar palette (822,678) | Select | opens the palette window (44120 px) |
| icon bar Acorn (875,680) | Select | opens the Task Manager (229739 px) |
| backdrop (780,150) | Menu | Pinboard menu at 570..894 x 114..464 (51403 px) |
| backdrop (220,560) | Menu | Pinboard menu at 177..605 x 420..719 (54076 px) |
| Filer close icon (155,57) | Select | closes the window (47996 px) |
| Filer close icon (155,57) | **Adjust** | opens the PARENT `Resources:$` (61204 px) |

The two Menu rows are the important ones for a closed loop: the menu is drawn
AT THE POINTER, so its bounding box is itself a pointer-position measurement,
independent of the arrow-sprite locator.

**(g) `MAME_CTL_BTN_ACTIVE_LOW` MUST NOT BE SET HERE, and the first live frame
is why.** The Archimedes buttons really are `IP_ACTIVE_LOW` — but MAME already
handles that: `m_digital_value` means "pressed" in both polarities and
`ioport_port::read()` XORs the ACTIVE_LOW bits in from `m_live->defvalue`.
Setting the knob INVERTS the module's own press/release, so `DOWN` releases,
`UP` presses, and a `CLICK` ends with the button HELD. The station's very
first live frame after landing showed the Filer window with a dashed
rubber-band selection being dragged across it — a stuck Select button on a
station nobody had touched. Every click proof above was re-taken with the
knob unset; moving 200 px after a click now changes **451** pixels (the
pointer sprite, and nothing else). The `btn-active-low` patch stays in the
build only because `ram-cursor` applies on top of its hunks.

**This is the rule-9 case in miniature.** With the knob set, every ack was
`OK`, every diff was large, and the menus really did open — four separate
"proofs" passed. Only the framebuffer of the *landed* station showed that the
button had never been let go.

## Keyboard — MEASURED 2026-09-20

Two layers of scanning sit between a ctlsock field write and RISC OS: the
`:keyboard:ROW.0..ROW.15` matrix, and the Archimedes keyboard MCU
(`acorn_0280,022-01_philips_8051ah-2.bin`, a Philips 8051AH-2 running its own
ROM) that scans it and talks to the host over a serial link. So this station
takes the scanned-matrix floor — `SH_KEY_MIN_HOLD_MS=80`,
`SH_KEY_MIN_GAP_MS=80`, `MAME_CTL_KEY_EXCL=:keyboard:ROW` — not the fleet's
40/40.

PROOF: `KEY 1 :keyboard:ROW.11 F12`, held 0.4 s, then released, opens the RISC
OS command line — **45987 changed pixels**. Press and release issued
back-to-back instead come back `OK coalesced` and the guest sees NOTHING; the
edges have to be separated.

`riscos3.keymap` is generated from the live ctlsock, never hand-written:

```
scripts/dev/mame-keymap.py <rig>/ctl.sock --tags ':keyboard:' --out riscos3.keymap
```

96 of 139 dumped fields mapped; the unmapped remainder are the two
keyboard-ID `IPT_OTHER` bits per row, `IPT_UNUSED` padding, and the UK-layout
`#` and `£` keys, which have no XT scancode to bind to.

**`KEYDUMP` defaults to the tag substring `:kbd:`** — the SGI's naming. On
this machine that returns `OK 0`, which looks exactly like "the keyboard is
not bound" and is not. Pass `:keyboard:`.

## Golden checkpoint — baked, and the driver's own metadata is wrong

`-listxml` reports `savestate="unsupported"` for `aa310`, which on `bbcb` and
`kc85_4` meant "restores garbage" — so this was PROVEN rather than assumed:

1. cold boot → Desktop (21.2 s), `SAVEST golden` → 137197 B in 1.0 s;
2. perturb: `MOVEA 700 200` + `CLICK3` → 55384 changed pixels;
3. `LOADST golden` → **0 changed pixels** against the pre-perturbation frame;
4. liveness after the restore: a Menu click still drops the Pinboard menu
   (55039 changed pixels). A restored-but-wedged machine would fail here.

So `MAME_NATIVE_CHECKPOINT=1`, and reset is the launcher's relaunch-with-
`-state golden`. The 21 s cold boot remains the fallback: delete
`sta/aa310/golden.sta` and the same launcher reaches the bare Desktop.

**Golden scene** (also the poster hero, `spa/public/posters/riscos3/desktop.webp`,
captured from this exact frame): the Desktop with the **Resources:$.Apps**
Filer window open in the top left — `!Alarm`, `!Calc`, `!Chars`, `!Configure`,
`!Draw`, `!Edit`, `!Help`, `!Paint` — icon bar along the bottom, pointer parked
on open backdrop.

## Live proofs — on the deployed station, 2026-09-20 12:01 UTC

Taken against `/data/vms/streamhost/stations/riscos3/` itself, not the rig.

- **Rest scene**: `labctl shot riscos3` shows the golden Apps-window scene,
  pointer parked on open backdrop, no rubber band.
- **Pointer + Menu, live**: `MOVEA 650 480` then `CLICK3` dropped the Pinboard
  menu at 513..795 x 420..719 — 54828 changed pixels, the menu's own bounding
  box confirming the pointer position a second time. Moving away afterwards
  changed 4919 px (menu-entry highlight tracking plus the sprite), not a
  desktop repaint.
- **Reset**, through the production path `POST /restore/riscos3`:
  **0.92 s warm** (the daemon's in-process `LOADST`) and **12 s from standby**
  (the launcher relaunch after the freezer). A visitor always gets the warm
  path: an idle station is `SIGSTOP`ped, the daemon `SIGCONT`s it on connect,
  and the reset button then runs in-process.
- **Deterministic**: two consecutive resets are **byte-identical outside the
  arrow sprite** (0 px).

**A STANDBY STATION CANNOT ANSWER `ctl.sock` AT ALL.** `SH_IDLE_PAUSE_SECS=60`
`SIGSTOP`s the emulator, and a stopped process never runs to ack — `mctl-probe`
just reports `timeout waiting for line`, which reads exactly like a dead
socket. Every direct-ctlsock probe of a live station in this wave hit it.
`kill -CONT` the pidfile's process first, or go through the daemon.

## Sandbox verdict

**No container.** `riscos3` is an EMULATED MACHINE under a per-station MAME
binary; the visitor's reach ends at the emulated Archimedes 310. The launcher
is the shared host-native one:

```
streamhost/stations/mame-native/x11-runtime.sh
  MAME_NATIVE_BIN=/data/vms/streamhost/assets/riscos3/mame-native/aa310
  MAME_NATIVE_DRIVER=aa310
  MAME_NATIVE_ARGS=-bios 311
  MAME_NATIVE_CHECKPOINT=1
```

## Open

- [ ] **Audio.** The Archimedes has VIDC sound and MAME emulates it; this wave
      ships silent (`SH_AUDIO=off`, no FIFO). Wiring it is the apple2gs
      `SDL_DISKAUDIOFILE` shape, unchanged.
- [ ] **Retronet.** Intentionally absent (the seed: "do not let networking
      block the desktop exhibit"). No `rn-tapnet.sh` is committed for this
      station — rule 15.
- [ ] **A demo.** No `demoPrograms` row yet. `!Draw` one Select-click from the
      golden scene is the obvious one.
- [ ] **The relaunch reset parks the arrow in the corner.** After the
      LAUNCHER path (service start, or a reset taken while the emulator is
      frozen) the arrow ends at the raster's top-left (118,43) instead of the
      golden's (513,420); the rest of the scene is byte-identical. The ioport
      analog fields carry no save entries, so they revert to 0 across a
      restore while the device's `m_mouse_x/y` hold the restored counter — the
      post-restore transient the ctlsock module's `reseed_after_restore`
      exists to absorb, now VISIBLE because the carry patch delivers the whole
      delta instead of dropping it. Harmless (the closed loop corrects on the
      first visitor move, and the warm reset a visitor actually gets is
      exact), but it should be seeded rather than walked.
- [ ] **Upstream the two patches.** Both
      `mame-archimedes-kbd-mouse-carry` and the `item-window-sized` relaxation
      are general corrections, not station hacks; the carry one is arguably an
      upstream MAME bug fix.

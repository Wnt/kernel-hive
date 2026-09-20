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
Apps-window scene byte-identically; pointer 1:1 absolute, worst error 3 px X /
2 px Y over ten spread targets; all three Archimedes buttons react.

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
| `mame-ctlsock-btn-active-low` | all three Archimedes buttons are `IP_ACTIVE_LOW` |
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
tip located on the framebuffer:

| Target | Lap 1 | err | Lap 2 | err |
|---|---|---|---|---|
| (180,120) | (177,120) | (-3,+0) | (181,120) | (+1,+0) |
| (840,120) | (842,120) | (+2,+0) | (837,120) | (-3,+0) |
| (180,660) | (181,662) | (+1,+2) | (181,659) | (+1,-1) |
| (840,660) | (837,662) | (-3,+2) | (842,659) | (+2,-1) |
| (512,390) | (513,388) | (+1,-2) | (510,391) | (-2,+1) |

**WORST |err| = 3 px X, 2 px Y. `giveups=0`.** Learned gain 2.25 / 2.47
published px per count. RESOLUTION BOUND: one quadrature count is 1.493
register units = 1.84 px across and 3.96 px down, so the loop lands on count
boundaries and cannot do better than about ±1 px X / ±2 px Y.

**(f) All three buttons react** — RISC OS is a Select/Menu/Adjust desktop and
a one-button proof would not be one. `CLICK3` (Menu, middle) on open backdrop
drops the **Pinboard** menu at the pointer (54944 changed pixels, bbox
460,274..646,568). `CLICK1` (Select, left) on the icon bar's Apps icon opens
the **Resources:$.Apps** Filer window (100743 changed pixels). Adjust is
`CLICK2`.

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
- [ ] **Upstream the two patches.** Both
      `mame-archimedes-kbd-mouse-carry` and the `item-window-sized` relaxation
      are general corrections, not station hacks; the carry one is arguably an
      upstream MAME bug fix.

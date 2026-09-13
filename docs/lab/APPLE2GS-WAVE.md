# Apple IIGS integration wave — 2026-09-13

GS/OS **System 6.0.1** (1992) with the Finder, on the **Apple IIGS** (ROM 3,
1986), Tier 1, host-native under the fleet MAME 0.289 (`SUBTARGET=apple2gs`,
driver `apple2gs`, `src/mame/apple/apple2gs.cpp`). Scaffolded
`--like apple2e` — the same `apple/` family, the same host-native
`stations/mame-native/x11-runtime.sh` launcher, the same CFFA 2.0-in-slot-7
ProDOS hard disk. Runs beside four other stations tonight
(`macsys1`, `minix2`, `xenix`, `os213`); coordination contract in
`WAVE-COORDINATION.md`, landing through `scripts/dev/station-land.sh` which
takes the landing lock.

## Ledger — from `scripts/dev/wave.sh alloc apple2gs`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 204 / 54204 / 204 |
| x11warp display | — (not allocated: host-native MAME, no in-guest X) |
| retronet address / MAC / tap / chain / UIN | — (none this wave, see below) |
| sibling (`--like`) | `apple2e` |
| hardware tuple | `pizzaBoxB\|homeCrtD\|none\|paramMouseD` (the //e's `eightBitWedgeA` body is the wedge case; the IIGS is a pizza box) |
| render orders | as scaffolded by `stations-registry.py new --like` — never hand-edited |
| device set | `-sl7 cffa2 -hard1 <hive.hdv>`; ADB keyboard + ADB mouse are on the motherboard (`macadb` HLE), 3.5"/5.25" drives on the built-in IWM. NO `-sl4 mouse`, NO `-sl6 diskiing` (those are //e cards the GS does not need) |
| media | staged by `apple2gs-media` under labhost `/data/assets-staging/apple2gs/`; URL + sha256 + byte size in that dir's `SOURCES.md` and in `scripts/build-guests/tiles/apple2gs.sh` |

**Retronet: OPEN, deliberately.** No in-guest TCP/IP + browser + IM client on
GS/OS 6.0.1 is worth an install-floppy hour tonight (Marinetti + a GS IM client
is a wave of its own). No `rn-tapnet.sh` is committed for this station — rule 15.

## Sandbox verdict

**No container.** `apple2gs` is an EMULATED MACHINE under the fleet MAME
binary; the visitor's reach ends at the emulated Apple IIGS. The launcher line
is the shared host-native one:

```
streamhost/stations/mame-native/x11-runtime.sh
  MAME_NATIVE_BIN=/data/vms/streamhost/assets/apple2gs/mame-native/apple2gs
  MAME_NATIVE_DRIVER=apple2gs
  MAME_NATIVE_ARGS=-sl7 cffa2 -hard1 /data/vms/streamhost/assets/apple2gs/media/hive.hdv
```

No 9p/virtfs/smb/`fat:` host drive, no `-netdev user` hostfwd, no
guest-reachable QMP/monitor, no virtio-serial host channel. Same verdict and
same reasoning as `apple2e`, which needs no nspawn either.

## Facts measured in the spine (coordinator, alone)

Read off **stock MAME 0.276 on labhost** (`/usr/games/mame -listxml apple2gs`)
and confirmed against the pinned 0.289 tree at
`/data/vms/sandbox/apple2gs/build/work/mame`:

- **ROM set `apple2gs` (ROM 3)** is four files:
  `341-0728` (128 KiB, sha1 `c0f4704233ead14cb8e1e8a68fbd7063c56afd27`),
  `341-0748` (128 KiB, sha1 `c70576869deec92ca82c78438b1d5c686eac7480`) — both
  `maincpu`; `341s0632-2.bin` (4 KiB, `adbmicro`, the M50741 ADB controller);
  `megaii.chr` (16 KiB, `gfx1`, flagged `baddump` upstream — it is still the
  set MAME expects).
- **The GS's input is the `macadb` HLE device, not the //e's cards.** Ports:
  `:macadb:MOUSE0` (buttons, `PORT_NAME("Mouse Button 0")` / `("Mouse Button 1")`
  — the GS mouse reports TWO buttons, unlike the //e card's one),
  `:macadb:MOUSE1` = X, `:macadb:MOUSE2` = Y, both 8-bit analog (`mask="255"`,
  `PORT_SENSITIVITY(100)`), and `:macadb:KEY0..KEY7` for the Apple Extended
  ADB keyboard. **`MAME_CTL_PTR_MOD=256`** follows from the 8-bit axes, exactly
  as on `apple2e`.
- `apple2gs` carries `MACHINE_SUPPORTS_SAVE`, so no skip-warnings patch and the
  shared launcher's checkpoint restore applies unmodified (to be confirmed by
  the restore proof).
- CFFA 2.0 is available in every GS slot (`-listslots apple2gs` lists `cffa2`
  under `sl1`..`sl7`), so the //e's `-sl7 cffa2 -hard1 <image>` trick carries
  over unchanged.

## Two `stations-registry.py new --like` bugs fixed in this wave

Both cost the scaffold a failed run, both are in
`scripts/stations_registry/scaffold_like.py`, and both bite ANY host-native
sibling — this is the second wave in two days to hit this class
(`win98se --like magiccap`, 2026-09-13):

1. **Only `runtime.qemu.auxFiles` was copied.** A host-native x11-runtime
   station keeps its keymap under `runtime.x11.auxFiles`, and `validate`
   checks BOTH lists — so the scaffold wrote a row referencing a keymap it
   never copied and rolled itself back. Fixed: aux files are gathered from
   both runtime nodes.
2. **Aux files named after the sibling were not renamed**, and the fixture
   still pointed at the SIBLING's asset tree and binary. `stations/{sib}/`
   rewrote only the directory, so the row asked for
   `stations/apple2gs/apple2e.keymap`, and `MAME_NATIVE_BIN` still read
   `assets/apple2e/mame-native/apple2e` — the scaffolded station would have run
   the //e's binary, ROMs and disk image. Fixed with three new rewrite
   patterns (`{sib}.keymap|env|ini|cfg`, `assets/{sib}/`,
   `mame-native/{sib}`) and by taking destination basenames from the REWRITTEN
   row instead of the sibling's.

## Streams

| Stream | Owns | Model | Status |
|---|---|---|---|
| `apple2gs-media` | `/data/assets-staging/apple2gs/` + `SOURCES.md` + `MANIFEST.sha256` | — | running (coordinator-spawned) |
| `apple2gs-spa` | poster, hero, scene prose | — | running (coordinator-spawned) |
| `golden` (lead) | native build, smoke boot, dark launch, golden bake + framebuffer proofs | Opus | in progress |
| `docs` (after golden) | `docs/guests/apple2gs.md`, `GUEST-TIERS.md`, release-notes facts | `sonnet-low` | queued |

## Proven on the framebuffer

All frames on labhost, all at the published 1024x768:

| Proof | Frame | Measured |
|---|---|---|
| build boot gate (no media) | `/data/vms/sandbox/apple2gs/build/work/gate/fb.shm` | 786432 lit pixels — the GS's power-on raster fills the WHOLE surface, so the copied `native_gate_nonblack` floor of 1000 is meaningless here; the floor that means something is "the full raster", and the scene proof is the rig capture below, not this gate |
| GS/OS 6.0.1 boots | `/data/vms/sandbox/apple2gs/rig1/frame.png` | "Welcome to the IIGs / System 6.0.1" splash at 30 emulated s |
| **Finder desktop, cold boot** | `/data/vms/sandbox/apple2gs/rig3/finder.png` | HARDDISK volume + Trash + the full Finder menu bar, settled **33.8 s** after power-on (throttled, real time) |
| **golden restore** | `/data/vms/sandbox/apple2gs/rig3/restored.png` | `SAVEST golden` = 474700 B in **152 ms**; relaunch with `-state golden` gives a framebuffer **byte-identical** to `finder.png` (`ImageChops.difference` bbox `None`) — `apple2gs`'s `MACHINE_SUPPORTS_SAVE` is real |
| keymap | `streamhost/stations/apple2gs/apple2gs.keymap` | 96 keys dumped from the running machine's own `KEYDUMP` over `:macadb:` (125 fields seen). NOT apple2e's — the scaffold's copy was the //e's `:X0..` matrix |

The hero `spa/public/posters/apple2gs/desktop.webp` is the restored Finder
frame, not a placeholder.

## Walls hit

**The splash stall that did not reproduce.** The first ctlsock rig (`rig2`:
throttled, `-sound none`, ctlsock armed) stopped dead on the "Welcome to the
IIGs" splash with its progress bar half filled and did not move for 88 emulated
seconds — `fb-wait.py --tolerance 5 --settle 20` reported `last change at 0.0s`,
so this was a real freeze and not the default tolerance hiding a crawling
progress bar (checking that was worth the one command: a 400-pixel tolerance
does hide a progress-bar tick).

Four theories were raced on their own rigs (`theory.sh`, one MAME per theory,
90 emulated seconds each, all four in parallel at load 29):

| Theory | Result |
|---|---|
| `base` — a straight repeat, sound on | **Finder desktop** |
| `raw` — 2mg header stripped to a raw `.hdv` (`dd bs=64 skip=1`) | **Finder desktop** — so MAME's `cffa2` parses the `.2mg` header itself; the strip is unnecessary |
| `ram8` — `-ramsize 8M` (default is 2M) | **Finder desktop** — RAM was not it |
| `sl2` — CFFA 2.0 in slot 2 instead of 7 | **"Check startup device!"** — the GS boots slot 7; keep `-sl7 cffa2` |
| `ctrlnosnd` — control: `-sound none`, the one flag `rig2` had | **Finder desktop** — so `-sound none` was not it either |

So the stall is **NOT reproduced in five subsequent boots**, including one with
the exact flag suspected. The shipping configuration (throttled, sound on,
ctlsock armed — `rig3`) reached the Finder in 33.8 s on the first try and its
golden restores byte-identically. Recorded as an unexplained one-off rather
than a fix, because nothing was fixed: if a station ever hangs on that splash,
the first thing to know is that it is intermittent and a relaunch clears it.

**`-hard1` must come AFTER the slot option.** `apple2gs -hard1 x -sl7 cffa2`
dies with `Error: unknown option: -hard1` — MAME only learns the option once
the slot device is on the command line. Cost one whole 4-way race round.

**`stage-romset.py` hashes LOOSE FILES.** A romset staged as a `.zip` stages
ZERO members and the boot gate then dies `Required files are missing`. Unzip
`-j` into the staging dir. (Relayed to the `macsys1` lead mid-wave.)

## Open items

- **Retronet**: OPEN (above).
- **Pointer**: still OPEN. Position sensor FOUND (`$E1/00E9`), write path REFUTED, read-loop patch is the next step — see §Pointer and §7-§10 below.

## Pointer — measured 2026-09-13 (pointer stream, Opus)

Rig: `/data/vms/sandbox/apple2gs-ptr/rig1`, the deployed station binary and
ROMs, the station's own `golden.sta`, ctlsock armed, `-video shm`. The station
still **ships keyboard-only** and `stream.pointer.transport` stays `none`. What
changed is that the four things that were guesses are now numbers, and one of
them was actively wrong in the fixture.

### 1. `setup btns=1 axes=1` was never a problem

Those two fields are C++ **bools** in the module's setup printf:

```
(m_btn_field[0] != nullptr), (m_x_field && m_y_field)
```

`btns=1 axes=1` therefore reads "button 0 is bound AND both axes are bound" —
exactly the wanted state. The wave's open question is closed; there was never
a half-bound axis. (`movea=0` on the same line IS meaningful: no
`MAME_CTL_CURSOR_ITEMS`, so MOVEA is open-loop.)

### 2. The ADB wire is 7-bit signed — the fixture's step was three times too big

`macadb_device::adb_talk()`, register 0:

```c
m_buffer[0] = (BIT(~m_lastbutton, 0) << 7) | (mouseY & 0x7f);
m_buffer[1] = (BIT(~m_lastbutton, 1) << 7) | (mouseX & 0x7f);
```

The accumulated delta is masked to **7 bits, signed**. Any per-poll delta
outside `-64..+63` arrives at the guest with the wrong sign and the wrong
magnitude. `adb_accummouse()`'s own wrap guard is the upstream sign-flip bug
(`if (diff > 0x80) diff = 0x100-diff;`) and does not rescue it.

Measured: `MOVE 100 0` from the golden arrow at published (84,105) moved the
arrow **LEFT** to the raster's left clamp — 100 as a 7-bit signed value is
−28. With `MAME_CTL_MOVE_STEP=32` the same axis moves right, linearly.

The module's inherited default is `MAME_CTL_MOVE_STEP=120`, so **every** step
this station issued before today was sign-flipped. The fixture now carries
`MAME_CTL_MOVE_STEP=48` with the 40 ms window (the GS polls ADB faster than
one window, so one step is one poll's delta).

This is the concrete reason a //e pointer configuration cannot be copied onto
the GS: it is not a different sensitivity, it is a different wire.

### 3. Gain: one ADB count is exactly one SHR pixel

With the step inside the wire the response is dead linear. `MOVE 32 0` steps
on the Finder desktop moved the arrow 47 published px per step (1.47 px per
count). The 640-px-wide SHR raster occupies published columns **47..976**
(930 px), and 930/640 = **1.4531** published px per guest px. Y: published
rows **53..717** (665 px) over 200 lines = **3.325**. So the guest itself
moves the cursor 1:1 with the ADB count and the only scale is MAME's aspect
correction. The fixture now ships `MAME_CTL_GAIN_X=1.4531`,
`MAME_CTL_GAIN_Y=3.325` (was the neutral 1.0/1.0).

### 4. Why 1:1 is still NOT claimable: the published surface is not the guest surface

The published 1024x768 carries the aspect-corrected 640x200 raster **inset by
~47 px on X and ~53 px on Y** — the blue SHR border. The guest cursor cannot
enter that border, so the phase-2 contract's corner targets (20,20) and
(1000,740) are physically unreachable, and an open loop anchored on the
module's own (0,0) belief starts 47/53 px out before any gain error. This is
the same class of finding `macsys1` reported (published cursor origin offset
from belief origin) and it is a **geometry** decision, not a gain one: either
the belief carries the origin (an open-loop analogue of `MAME_CTL_CAL_X/Y`,
which today only offsets a closed-loop *reading*), or the station publishes
only the active raster. Neither was changed in this pass.

### 5. The closed loop is one small module patch away — and needs no new device

`ITEM m_megaii_ram` resolves: **size=1 count=131072**. That is the whole of
the Mega II "slow RAM", banks **$E0/$E1**, which is where GS/OS keeps its
toolbox globals — and `save_item_handle` already has `read_at(i)`. So the
closed-loop sensor the MOVEA V7 engine wants is reachable by widening
`MAME_CTL_CURSOR_ITEMS` from a bare save-item suffix to
`suffix@offset[:width]` (plus a multiplicative scale next to `CAL_X/Y`, since
a guest-pixel reading has to be scaled by 1.4531/3.325 to become a published
pixel). `macadb/0/m_lastmousex` also resolves, if the device's own last
sample is ever wanted.

Finding the offset is a two-position RAM diff. **MAME's `-autoboot_script`
silently does nothing in this build** — no Lua output, no error, tried with
both `emu.add_machine_frame_notifier` and `emu.register_frame_done` — so that
diff has to come from a module verb (a `MEMDUMP <suffix> <off> <len> <path>`
diagnostic), not from Lua. That is the next commit on this branch.

### 6. Two traps for whoever picks this up

- **Raw `MOVE` is not a measurement tool here.** The home-drain branch walks
  the accumulator back to zero once the queue is quiet; macadb consumes each
  delta once and does not net like the //e's a2bus mouse card, so that drain
  physically walks the arrow back to where it started. A step table taken with
  plain `MOVE` and `MAME_CTL_HOME_SETTLE=750` reads "moves, moves, snaps back,
  then never moves again". Measure with MOVEA, or with `HOME_SETTLE=0` and one
  step at a time.
- **The arrow flickers in the shm capture.** GS/OS erases and redraws the
  software cursor every VBL, so single frames legitimately show the arrow at
  the new position, at a stale position, or not at all. Any locator on this
  station must sample several frames and take the stable cluster — a one-shot
  `screendump` diff will report motion that did not happen and stillness that
  did.

## Pointer, second pass — 2026-09-13 evening (abs-ram, Opus)

Binary: the fleet chain **plus** `mame-ctlsock-abs-ram.patch` (authored on the
macsys1 stream, landed on main in 655a8f11), added as the last link of
`native.d/apple2gs.sh`. Chain order, verified applying cleanly:
`ptr-tags -> move-step-cap -> open-loop-gain -> home-drain -> count-carry ->
abs-ram`. Built to `/data/vms/sandbox/apple2gs-ptr/build/apple2gs` (the live
station binary was not touched); the builder's smoke gate passed at 786432 lit
pixels. The patch brings `PEEK` / `POKEW` / `POKEB` on a named CPU's program
space, which is what everything below is measured with.

### 7. The GS cursor position IS in guest RAM — at `$E1/00E9`

Derived by two-position RAM diff (`scripts/dev/apple2gs-ramprobe.py snap` over
a whole bank, 1024 `PEEK`s, **1.6 s per bank**; positions read back with
`scripts/dev/apple2gs-cursor-readback.py`):

| address | meaning |
|---|---|
| `$E1/00E9` | cursor **X**, 16-bit little-endian, in GUEST px (0..639) |
| `$E1/00EB` | cursor **Y**, 16-bit little-endian, in GUEST px (0..199) |

and four `{v,h}` Point copies in bank `$00` that track it exactly:
`$00/085A`, `$00/1956`, `$00/195A`, and `$00/1962` (the last one lags by one
count — a "previous position" record). Nothing else in banks `$00`, `$01`,
`$E0`, `$E1` tracks the pointer; the sweep covered 16-bit LE **and** BE and
raw bytes, matching on both absolute value and delta.

`$E1/00E9` is an exact, live, guest-pixel readback of where the arrow is. Two
independent checks agreed with the framebuffer locator to within the locator's
own rounding (±2 px published, i.e. well under one guest pixel).

### 8. …but WRITING it does not move the arrow: the accumulator is elsewhere

MEASURED, in this order:

1. `POKEW $E1/00E9` (and `$00EB`): the values **stick**, and the arrow does
   **not** move. No redraw is triggered by the position alone.
2. Poke, then nudge one ADB count (`MOVEP 1 0`): the arrow **does** move — and
   `$E1/00E9` comes back holding *old position + 1*, not *poked position + 1*.
   Every one of the five copies above was overwritten the same way.
3. The ADB microcontroller is not hiding it either. `MAME_CTL_ABS_RAM=cpu=adbmicro`
   (no `pts=`, so `PEEK` retargets without arming the abs path) and a diff of
   its whole 256-byte internal RAM across a large move changes exactly three
   bytes — `$12`, `$FA`, `$FB` — none of them a 16-bit coordinate.

So on this machine the five RAM copies are **outputs**, published each poll
from an accumulator that is neither in banks `$00/$01/$E0/$E1` nor in the ADB
micro's RAM. The macsys1 write route therefore does **not** transfer to the
GS as-is, and `stream.pointer.transport` stays `none`.

### 9. The exact next step

The READ loop, not the write loop. `$E1/00E9` is the sensor the MOVEA V7
engine has been missing, and it is addressable as a save item today:
`m_megaii_ram` is `size=1 count=131072` covering `$E0/$E1`, so
`$E1/00E9` is **byte offset `0x100E9`** inside it. Implement §5's
`MAME_CTL_CURSOR_ITEMS=suffix@offset[:width]` (little-endian, width 2) plus a
scale beside `CAL_X/Y`, then bind:

```
MAME_CTL_CURSOR_ITEMS=m_megaii_ram@0x100E9:2,m_megaii_ram@0x100EB:2
MAME_CTL_CAL_X=47   MAME_CTL_CAL_SX=1.4531
MAME_CTL_CAL_Y=53   MAME_CTL_CAL_SY=3.325
```

Resolution bound, stated up front so nobody calls it a failure: one ADB count
is one guest pixel, so the loop can only land on guest-pixel centres —
**±0.73 px on X and ±1.66 px on Y** in published pixels. That is inside the
phase-2 ≤2 px bar, but only just on Y, and no amount of tuning beats it.

### 10. The five-target contract has to be clamped on this station

The raster lives at published x 47..976, y 53..717. The contract's
(20,20) (1000,20) (20,740) (1000,740) are all in the SHR **border** and are
physically unreachable by the guest cursor. The set to prove here is
**(50,56) (973,56) (50,714) (973,714) (512,384)**, and `reset.mouse` must say
so rather than quietly reporting a corner the guest can never occupy.

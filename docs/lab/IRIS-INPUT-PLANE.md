# The Iris `mamectl/1` input plane (`indyr4400`, host-native)

Stream C of the Iris de-bridging wave (`IRIS-DEBRIDGE-BRIEF.md`, landing with
stream E). Fork branch
[`Wnt/iris@kh-native-input`](https://github.com/Wnt/iris/tree/kh-native-input),
one new module `src/ctlsock.rs` plus four wiring lines. Written 2026-09-09/10 and
measured on a rig that boots the station's own IRIX 6.5 asset.

**What it is.** A unix `SOCK_STREAM` control channel inside Iris serving
**`mamectl/1`** — the same wire streamhost's `mamesock` backend already speaks
to MAME's ctlsock OSD module and to the `Wnt/previous` fork on `nextstep`. The
station therefore needs **no new streamhost code**, only env.

**What it is gated on.** `IRIS_CTL_SOCK`. Unset, no thread is spawned, nothing
is bound, and the binary is byte-behaviourally identical to stock Iris — so the
live bridge keeps running off the same source until cutover, and the rollback is
"unset the variable".

## Station env (for stream B)

```sh
SH_INPUT_BACKEND=mamesock
SH_MAMECTL_SOCK=/data/vms/streamhost/stations/indyr4400/ctl.sock
SH_MAMESOCK_KEYMAP=/data/vms/streamhost/stations/indyr4400/indy.keymap
# Leave SH_MAMESOCK_PTR_GRID UNSET: this server states targets in screen pixels,
# as nextstep does. The grid mode is for guests with no hardware cursor.
SH_KEY_MIN_HOLD_MS=40
SH_KEY_MIN_GAP_MS=40
```

and on the launcher's side of the emulator:

```sh
IRIS_CTL_SOCK=/data/vms/streamhost/stations/indyr4400/ctl.sock
IRIS_CTL_SCREEN=1280x1024      # clamp surface + the HELLO banner's screen=
IRIS_CTL_KEY_HOLD=40
IRIS_CTL_KEY_GAP=40
```

**Single-injector rule is BINDING** (`streamhost/src/mame_sock.rs:31`): a station
with `IRIS_CTL_SOCK` set must not also arm a second motion path. There is no
`x11warp` option here — that sink carries motion only and declares
`EdgeDischarge::VerifiedWarp`, while buttons and keys ride a different channel
that a host-native station does not have. That composition is why `amix` was
rolled back on 2026-09-09; do not re-litigate it mid-wave. If the pointer loop
ever fails to converge, the fallback is **stay `rel`**, today's shipped
behaviour, which the browser already drives through Pointer Lock.

## Every knob

| knob | default | meaning |
|---|---|---|
| `IRIS_CTL_SOCK` | *(unset)* | listener path; unset => the module is never constructed |
| `IRIS_CTL_SCREEN` | *(from VC2)* | `WxH` clamp surface + `screen=` in HELLO |
| `IRIS_CTL_CAL_X` / `_Y` | `-31` | cursor register -> pixel calibration |
| `IRIS_CTL_DEADBAND` | `1` | MOVEA convergence deadband, px |
| `IRIS_CTL_MOVE_STEP` | `96` | pacing budget, counts per window per axis |
| `IRIS_CTL_MOVE_WINDOW` | `10` | pacing window, wall ms |
| `IRIS_CTL_SETTLE` | `40` | ms a MOVEA round waits for its counts to reach the registers |
| `IRIS_CTL_ACCEL_THRESHOLD` | `4` | px at/below which IRIX is 1:1 |
| `IRIS_CTL_MOVEA_ROUNDS` | `80` | give-up cap for one flight |
| `IRIS_CTL_GAIN_MARGIN` | `1.10` | never extrapolate the cursor ahead of real movement |
| `IRIS_CTL_KEY_HOLD` / `_GAP` | `40` / `40` | key edge pacing, wall ms |
| `IRIS_CTL_KEY_EXCL` | `0` | 1 => one key held at a time |
| `IRIS_CTL_STAT_PERIOD` | `15` | `EV STATS` heartbeat period, wall s |
| `IRIS_CTL_TRACE` | `0` | 1 => per-verb engine trace on stderr |

## Verbs

`MOVE dx dy` · `MOVEP dx dy` · `MOVEA x y` · `DOWN1..3`/`UP1..3` ·
`CLICK1..3`/`DCLICK1` · `KEY <0|1> kbd <name>` · `KEYDUMP` · `PING` · `CUR` ·
`STAT` · `SYNC`.

`PAUSE RESUME RESET SAVEST LOADST FBSYNC EXIT` answer **`ERR badverb` on
purpose**: they belong to the reset plane (`kh-native-reset`, stream D), and a
half-wired station should be loud rather than silently `OK`.

Wire details the daemon holds the module to, all satisfied:
the first line begins `HELLO mamectl/1 ` within 1 s; `MOVEA` acks on **accept**
and reports completion asynchronously as `EV MOVEA seq=… x=… y=… rounds=… ms=…`;
button edges ack when the edge **applies**, and are deferred behind an in-flight
MOVEA so a click can never fire at the pointer's old position; `EV ` lines are
never acks; buttons are `DOWN1`=left, `DOWN2`=right, `DOWN3`=middle. `MOVEP`
acks when its delta is fully **drained**, which is what makes it the verb you
calibrate counts->pixels with — paired with `CUR`, which reads the cursor with
no engine side effect at all (every `MOVEA` runs a convergence, so `MOVEA` can
never be its own reader).

Nothing the engine thread does blocks on someone else's pace: it is the single
applier for keys, buttons and the pointer, so `MOVEP` bleeds from a queue rather
than sleeping inside the verb, and every reply write carries a 2 s timeout — a
client that stops reading gets a dropped ack, not a stalled emulator.

## The pointer: closed loop against VC2

`MOVEA x y` reads the Newport VC2 hardware-cursor registers, computes the
residual in pixels, emits a bounded burst of relative PS/2 counts through
`Ps2::push_mouse_input`, waits a settle window, re-reads, and repeats until the
residual is inside the deadband. Three things had to be right, each of which was
wrong first and was found on the framebuffer:

1. **Read `CURSOR_Y_LOC` (0x03), not `WORKING_CURSOR_Y` (0x0d).** The working
   register is *raster* state: the REX3 refresh loop re-latches it from `Y_LOC`
   at every VBLANK (`rex3.rs:4081`) and it drifts in between. Steering by it,
   targets took **49–80 rounds and landed up to 60 px out**; by `Y_LOC` the same
   targets land in **0–7 rounds**. X has no such twin — `CURRENT_CURSOR_X` is the
   position register, and it was exact from the first run.
2. **One round per settle window, not per engine tick.** The emulated mouse
   samples at the guest-programmed 100 Hz and the cursor Y latches at VBLANK, so
   a loop that re-reads faster than that reads its own past, keeps correcting an
   error it has already fixed, and integrator-winds the pointer into a screen
   edge. Measured at a 5 ms round: **every target ran away to a corner** and gave
   up at 80 rounds, on both axes, with the signs perfectly correct.
3. **IRIX accelerates only ABOVE a ~4 px threshold.** So the final approach
   states the residual as counts directly (1:1) while the long haul divides by a
   learned per-axis gain. That is why a 1 px deadband is reachable on a desktop
   measured running **1.93x** acceleration: the loop never has to undo the
   acceleration, only to stop using it. (The `irix` sibling gets 1:1 the other
   way, with `xset m 1/1 0` in its checkpoint's `/.sgisession`; that would help
   here too and is not required.)

`cursor_x_adjust` — the VT-timing X correction the compositor adds when it draws
the glyph (`compositor.rs:128`), **5** on the Indy's 1280x1024 timings — is part
of the answer and is **cached**, never re-read as 0: a `try_lock` lost to a
compose pass must not quietly move the pointer 5 px.

## Traps

- **A verb that returns `OK` can still do nothing.** `push_kb` and
  `push_mouse_input` return early — silently, with no error — unless the
  controller is running, the device is enabled and the matching i8042 CTR
  disable bit is clear (`ps2.rs:413-417,814-817`); Linux and IRIX both toggle
  those bits while probing. The module checks `Ps2Controller::input_ready()`
  before every injection and answers **`ERR kbdoff` / `ERR mouseoff`**. Without
  that check an acking rig looks perfectly healthy while the guest ignores
  everything.
- **Never test typing with an acking client.** An acking rig paces the edges for
  you and hides the exact loss a browser produces. Use a **pipelined sender at
  zero spacing** (`scripts/dev/key-replay.py`, or the rig's `typetest.py`).
- **A PS/2 keyboard is not a matrix.** This module never synthesises a release;
  the client's own `KEY 0` is the release and every edge acks the moment it is
  applied. `IRIS_CTL_KEY_EXCL` exists but is **off** by default here — unlike the
  MAME stations, where it is mandatory because those guests scan their own
  matrix and a browser burst becomes a chord.
- **`systemctl restart` does not kill the previous emulator**, and
  `readlink -f /proc/<pid>/exe` on a replaced binary yields `"<path> (deleted)"`
  — seen on this rig at every restart. Resolve processes through `/proc/<pid>/exe`
  and never a cmdline grep.

## The keymap

`streamhost/stations/indyr4400/indy.keymap`, 102 rows, generated by
[`scripts/dev/iris-keymap.py`](../../scripts/dev/iris-keymap.py) — never
hand-edited.

Iris's keyboard is a PS/2 controller, so there is exactly **one** port (`kbd`)
and the field is a `winit::keyboard::KeyCode` variant name — which is also the
W3C `KeyboardEvent.code` the SPA already sends, so the file is very nearly an
identity map. `Ps2::push_kb` encodes the scancode itself and the guest applies
its own `keybd=` layout on top; nothing in the file is IRIX-specific, which is
why it is `indy.keymap` and not `irix.keymap`.

The module's `NAMES` table is the single source of truth: the generator verifies
every row against a running binary's `KEYDUMP`, which prints that same table, so
the map and the binary cannot drift. A name the binary does not know is a hard
error in the generator, not a silently dropped key.

Verified 2026-09-10 against the built fork binary: all 102 names resolve through
`KEYDUMP`, and the committed file is byte-identical to what the generator
produces against that binary. The check needs no guest — the control socket is
up before the machine starts — so it costs about five seconds and belongs in
every rebuild.

Caps Lock (XT `0x3A`) is **deliberately absent**: `map_keycode_set1` has no
`CapsLock` arm and would drop the byte silently. Case comes from a real Shift,
which every SPA burst already sends.

## Measured

Rig: the fork's binary built on the host (`lightning,rex-jit,chd,jitv2`), run
windowed under an Xvfb the rig owns, against a **read-only loop mount** of the
station's own `irix65-r4400-disk.ext4` with every write in a sandbox overlay.
Frames read off that Xvfb, because stream A's IFB1 shm publisher did not exist
yet — under `--ci` the REX3 renderer is never installed and screenshots are
black.

| | this rig |
|---|---|
| command -> the guest's own VC2 cursor registers move | **median 10.2 ms** (n=8, 10–27) |
| command -> first framebuffer reaction | median 112 ms (n=10, 69–144) |
| command -> cursor at the target in the frame | median 287 ms (n=10, 205–441) |
| MOVEA convergence | 0–7 rounds, 4–306 ms |
| learned pointer gain at the 4Dwm desktop | 1.93x / 1.93x |
| a 6-character line, pipelined at zero spacing | 12 edges, all acked, 462 ms (= 6 x 40/40) |
| that line at the IRIX login box | `demos` + Enter logged in; the desktop came up |
| keymap rows resolving through `KEYDUMP` | 102 / 102 |

For scale, the bridge measured 285–383 ms and the MAME `irix` station 68 ms for
the same "single pointer move -> framebuffer"
([`indyr4400.md`](../guests/indyr4400.md) §*Upstream bump*).

**Read the split, not the total.** The input plane's own contribution is the
10.2 ms line. The rest is this rig's frame path — Iris's SwCompositor plus a GL
upload and an X blit under llvmpipe — which is precisely what stream A's IFB1
publisher removes (no GL, no X, one memcpy into shm). A 96x96 `XGetImage` costs
0.20 ms and a full-window one 36.7 ms, so the reader is not the number; the
compositor present is.

### Still to confirm

The `cursor_x_adjust` term reached its shipped default *after* the measurement
run. On the running binary of the day the loop steered `reg + cal_x` alone and
the glyph landed 5 px right of every commanded pixel; commanding `x - 5` put the
glyph **exactly on the pixel at 5 of 7 targets**, which is what fixes the
constant at 5 and is why the module now adds it. The equivalent run on the
shipped default — same seven targets, no hand offset — has not been taken: the
box allows one Iris at a time and the slot went to streams A and B. It is one
15-minute run, and `finalproof.py` in the `iris-c` rig is written and waiting.

## Open, and handed to stream A

The composited frame places the cursor **glyph** on the commanded pixel exactly
(0 px) at 5 of 7 targets, and 10–14 px low in **Y** at the other two — while the
VC2 registers read the commanded pixel exactly at all seven, verified through
Iris's own monitor console, a channel the input plane does not write. That is a
frame-plane placement question, not an input one: `compose_pixels` derives
`cursor_y_hot` from `WORKING_CURSOR_Y` — the raster-drifting twin of the
register the guest actually programs — and `Rex3::refresh` snapshots the VC2
registers *before* the VBLANK re-latch. Stream A should read `CURSOR_Y_LOC`
there too, or latch before the snapshot.

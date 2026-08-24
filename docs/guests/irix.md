# SGI IRIX 6.5 (irix station) — issue #20

Before touching performance on this station, read three companion files:
[`lab/MEASUREMENT-METHODOLOGY.md`](../lab/MEASUREMENT-METHODOLOGY.md) (how to
measure it, and the four retracted conclusions behind each rule),
[`lab/irix-closed-register.md`](../lab/irix-closed-register.md) (every angle
already measured and closed, with mechanism and ceiling — plus the one that was
closed in error and reopened), and
[`lab/irix-baseline-2026-08-03.md`](../lab/irix-baseline-2026-08-03.md) (the
numbers everything is judged against). The rig is
[`scripts/build-guests/irix/irix-bench/`](../../scripts/build-guests/irix/irix-bench/README.md);
the unshipped ~1.2 s CRIU reset procedure is
[`scripts/build-guests/irix/irix-criu/`](../../scripts/build-guests/irix/irix-criu/README.md).

The gallery's first **non-QEMU** streamhost station. SGI's IRIX 6.5 runs inside
**MAME** (the `indy_4610` SGI Indy driver) with **`-video none`** — no Xvfb and
no window at all — publishing each finished frame into a shared-memory mapping
that streamhost reads via **`SH_CAPTURE=shm`**, with pointer and keys going back
through **`SH_INPUT_BACKEND=mamesock`**. It is an x11 station
(`SH_STATION_RUNTIME=x11`), not a QEMU VM, because MAME's SGI Indy emulation
kernel-panics under a KVM vCPU and must run
on the bare-metal host CPU.

- Machine: SGI Indy, MIPS R4600 @ 100 MHz, **256 MB RAM**, XL 24-bit graphics,
  1280x1024. MAME's `indy_4610` ships 16 MB (bank A `4x4M`, bank B empty), which
  makes IRIX 6.5 + 4Dwm page continuously; the station's MAME carries
  `scripts/build-guests/patches/mame-indy-256mb-ram.patch` (banks A+B at `4x32M` = a real
  Indy's 256 MB maximum). It CANNOT be done from a `cfg/` file — `ioport.cpp`
  applies `DEVICE_INPUT_DEFAULTS` only on an exact mask match, so the patch uses
  two per-field entries (`0x000f`/`0x00f0`). Verify a binary offline with
  `sgi -listxml indy_4610` → `4x32M` must be `default="yes"` for banks A and B.
- OS: IRIX 6.5 (4Dwm Indigo Magic desktop). Login `root`, empty password.
- Launcher: `streamhost/stations/irix/x11-runtime.sh` (Xvfb :40 + MAME) — installed
  as the station launcher by `scripts/streamhost-station.sh --x11`.
- Input: the mamectl control socket (`SH_INPUT_BACKEND=mamesock`, issue #45 —
  see "mamectl control plane" below). The Lua agent below is the `IRIX_CTL=off`
  deep-rollback arm only; its description is kept as the design record.
- Input agent (ROLLBACK ARM): `streamhost/stations/irix/irixagent.lua` (natkeyboard + PS/2 buttons
  **and pointer axes** from the `SH_X11_CMD_FILE` command file; streamhost's own
  motion path is still XTEST). The `MOVE <dx> <dy>` verb drives
  `:ioc2:aux:hle_ps2_mouse:mouse_x_axis` / `mouse_y_axis` directly, exactly as
  the buttons already did, so guest pointer input does **not** depend on SDL
  mouse capture — capture needs an `SDL_WINDOWEVENT_ENTER` the pointer can never
  generate on a WM-less Xvfb the MAME window exactly fills, and when it fails to
  engage nothing reaches the guest at all (which takes the keyboard with it,
  because 4Dwm is pointer-focus). `IPT_MOUSE_X/Y` are relative, so the agent
  keeps its own accumulators. Verified on the live station: 60x `MOVE -40 -40` pins
  the cursor at `0,34`, then 8x `MOVE 32 24` (raw 256,192) lands it at
  `704,374` — i.e. IRIX applies ~2.75x horizontal / ~1.77x vertical
  acceleration, so absolute positioning still needs the documented closed loop
  (slam to a corner, locate the red cursor in a grab, correct). It holds ONE read
  handle open on the command file and tracks its own offset — `seek("end")` is a
  bare `lseek`, and streamhost only ever appends (`x11_input.rs` opens with
  `.append(true)`). It used to `io.open`/read/close (plus a second open to
  truncate) on **every periodic tick**, which cost ~13 percentage points of a
  core forever: MAME at an idle 4Dwm desktop measured **114.3/114.6/114.0% CPU
  before, 99.7/101.0/101.3% after** (same station, same `2,10` pin, same desktop),
  and `strace` counts zero `openat` on the command file over 5 s where it
  previously did dozens a second.
- Reset: `relaunch` — a service restart kills MAME+Xvfb by pidfile and
  relaunches. Since the savestate work (issue #44, `mame-indy-savestate.patch`)
  a relaunch with `IRIX_STATE=golden` set in `station.env` **restores the captured
  MAME savestate + its paired disk in seconds** instead of the ~390 s cold
  boot; see "Instant restore" below. With `IRIX_STATE` empty the launch is the
  historical pristine cold boot, unchanged.
- Render rate: `-frameskip 6` (render 6 of 12 frames, ~36 Hz instead of
  Newport's ~72 Hz). The station streams at `SH_FPS=30`, so the skipped frames were
  discarded anyway; Newport scan-out is ~31% of runtime and is costed per frame
  generated, so this buys ~+18% emulation speed with no guest-visible timing
  change. Do not raise it — fs7 has zero margin and fs8 drops 34% of frames.
- CPU pin: `IRIX_CPUS` in `station.env` (currently `2,10` = one physical core plus
  its SMT sibling). MAME saturates whatever core it lands on and labhost is
  shared with build/benchmark agents.

## Shared-memory capture (`SH_CAPTURE=shm`) — LIVE since 2026-08-02

The station **used to** stream through `SH_CAPTURE=x11`: MAME rendered into an Xvfb
and streamhost grabbed the root window. That path was profiled at **~226-257 Gcyc
(~1.5-1.7 Gcyc per emulated second, 32-43% of host time)**, and it is all raw
pixel movement: MAME rasterises the Newport framebuffer into an RGB32 bitmap,
uploads it to an SDL texture, `SDL_RenderCopy`s it through Mesa llvmpipe into an
X window, and streamhost reads those same pixels back out. One 1280x1024x4 frame
is software-rasterised twice and pushed through X in between.
`SDL_RENDER_DRIVER=software` changes nothing (llvmpipe was never the cost),
`-nofilter` is worth ~1.8%, a bigger unscaled Xvfb is worse.

`SH_CAPTURE=shm` deletes the whole detour. MAME runs **`-video none`** — no
window, no X server — and its Newport device publishes each finished frame into a
file-backed mapping (`IRIX_SHM_PATH`), which streamhost maps and hands straight
to the encoder's existing BGRA copy-path. It is also a **fidelity fix**: MAME's X
window was 1272x954 on a 1280x1024 Xvfb and auto-scaled with the display, so the
exhibit has been streaming a *resampled* picture; the mapping carries the exact
emulated framebuffer, which is **1288x1024** (IRIX programs the VC2 with eight
columns of overscan a real monitor never showed — the UI pins the station to 5:4 in
`spa/src/ui/grid/presentAspect.ts` so those columns do not stretch the desktop).

### Cutover record (2026-08-02)

Verified on the live station, in this order, so that each step's evidence stands on
its own:

1. **QEMU fleet first.** The 35 QEMU stations share this binary, so `helenos` was
   canaried and driven through the REAL UI in a real Chrome before IRIX was
   touched: decode PASS 1024x768, and `help` typed into the Bdsh prompt echoed
   and executed (whole-frame change 4.1e-2, ~200x the reaction floor). The
   shared-path edits are inert for QEMU stations by construction, but 35 exhibits
   is not where that is worth trusting to reasoning alone.
2. **MAME binary promoted**, previous kept as `mame/sgi.prev-a33944d3`.
3. **Registry flip + emit.** The emitted `station.env` was diffed against live
   before installing: every changed line was an intended part of the cutover.
4. **Live station switched.** No Xvfb process at all any more, MAME running
   `-video none` with no `DISPLAY` in its environment, `fb.shm` 5,275,712 bytes
   (= 64 + 1288x1024x4), daemon `[shmcap] first frame 1288x1024`, encoder
   opened at 1288x1024.
5. **Browser end to end.** The station streams in the deployed UI at
   **1288x1024** — the exact emulated framebuffer now reaches the visitor —
   presented at 5:4, with the control channel green.
6. **Pointer 1:1 through the real UI**, measured against the published
   framebuffer (browser mouse → StreamView → WebTransport → the mamecmd sink →
   the Lua agent → the emulated PS/2 ioport → IRIX):

   | commanded (u,v) | expected guest px | measured guest px | error |
   |---|---|---|---|
   | 0.50, 0.50 | 644, 512 | 642, 510 | −2, −2 |
   | 0.25, 0.75 | 322, 767 | 322, 765 | 0, −2 |
   | 0.75, 0.25 | 965, 256 | 961, 254 | −4, −2 |
   | 0.50, 0.50 | 644, 512 | 642, 510 | −2, −2 |

   Worst error 4 px across a 1288x1024 surface (0.3%), and the constant −2 is
   the measurement's own cursor-hotspot constant. That run also **proves the
   30 s re-home**: the pointer had deliberately been driven out of band first
   (the desktop-park sequence), and the browser session recovered a correct
   origin by itself.

Live cost at an idle desktop after the cutover: **streamhost 3% of a core**
(capture + encode + transport, no viewer) and **MAME 81% of a core** — against
the ~100-114% the same idle desktop measured on the x11 path.

**`SH_SHM_DAMAGE` stays ON.** The producer's dirty flag means an unchanged frame
is skipped without copying a byte, so the host-side diff only ever runs on frames
that actually changed; the whole daemon costs 3% of a core at idle. Turning it
off would force a full 1288x1024 BGRA→I420 conversion on every changed frame —
strictly more work, on the same core. `SH_SHM_DAMAGE=0` remains the one-variable
control if the diff ever shows up in encoder latency.

### Keyboard: the key MATRIX, not natkeyboard (issue #42, LIVE 2026-08-02)

Browser keys had never reached this guest on either capture backend — not a
cutover regression, and not something that was lost in a refactor either.
`input::key()` injects over the QEMU D-Bus connection and `Capture.main_conn` is
`None` for every non-QEMU backend, so every type=3 record died on that
function's first statement. The x11 sink shipped saying so out loud: *"Keyboard
(`try_key`) is intentionally not wired: the wire carries XT set1 scancodes and
Xvfb's evdev keymap needs an XT->X-keycode translation table"* (`6dda418`).
There has never been a browser key path to this station.

**`natkeyboard` is not the fix, and wiring `POST` would have looked like one.**
`indy_4610`'s keyboard is a PC "Microsoft Natural" behind an SGI keymap, and
every SHIFTED character is silently dropped: uppercase arrives lowercase and
`_ | ~ " < > ? :` never arrive at all. Plain lowercase types convincingly — so
`uname` works and `/usr/demos/General_Demos` does not.

So the browser drives the **key matrix** directly, one `:ioc2:kbd:ms_naturl`
ioport field per physical key, exactly as the pointer drives the PS/2 axes.
This is the proven route from `scripts/build-guests/irix/irix-apps/keys.py`, ported.

- **Wire**: `KEY <0|1> <port> <field>` in the agent command file, e.g.
  `KEY 1 P1.7 Left Shift`. The field name is the rest of the line because MAME's
  names contain spaces. `KEYDUMP` logs every keyboard port/field the machine
  exposes — the host-side table was read off the running machine with it, not
  guessed (`keys.py`'s hand-dumped table is missing the whole keypad, Menu,
  right Meta and Print Screen).
- **Shift/Ctrl/Alt are not special-cased anywhere.** The UI already sends a
  real modifier make/break around a shifted character, so the sink just presses
  the modifier's field like any other key. That is what makes both `_` and
  **Ctrl-C** work, without a chord table.
- **Timing lives in the guest.** A burst of command lines is consumed inside ONE
  periodic tick, and a field set down and up in the same tick is invisible to a
  keyboard that polls the matrix on its own clock. So key events are a FIFO
  drained at most one per tick and never faster than `IRIX_KEY_HOLD` (0.10) /
  `IRIX_KEY_GAP` (0.05) of **emulated** seconds — the same per-emulated-time
  rule the pointer pacing needs, since the callback fires far more often than
  the devices sample.
- **Auto-repeat**: a press of an already-pressed field is coalesced away, so
  browser key-repeat becomes IRIX's own repeat from the held matrix bit.
  Measured: holding a key for 3 s produces a normal IRIX repeat stream and the
  single release ends it.
- Unmapped scancodes (Pause/Break, IME keys) are **rejected**, never folded onto
  a neighbouring field.

Host side: `MameCmdSink::try_key` (`mame_input.rs`) emits the verb — today
`MameSockSink` (`mame_sock.rs`) puts the identical line on the control socket
instead — and `input.rs::handle()` routes type=3 to the router **only** for the
`mamecmd`/`mamesock` backends. Every other backend — the QEMU fleet, and gallery-hid, which has no
keyboard minor — keeps the D-Bus path byte for byte.

**4Dwm is pointer-focus**: keystrokes go to whatever window the pointer is over,
and with the pointer over the root they go nowhere. A visitor who opens a
Console and then moves the mouse away stops typing into it. Nothing host-side
can fix that without changing the guest's focus policy (`4Dwm *keyboardFocusPolicy:
explicit` in the app-defaults, which would need a seed recapture and would change
the exhibit's period-correct behaviour) — so it is documented, not worked around.

Verified through the real UI in a browser: typed `root` + Enter at the
`iconlogin` chooser to log in, opened a Console from the Toolchest with the
UI's mouse, and typed `ls /usr/demos/General_Demos | head -3` verbatim
(capitals, `_`, `/`, `|`, `-`) — executed correctly — then Ctrl-C interrupting
`sleep 300`.

### Rollback

The previous capture path is not deleted, only unselected — the Xvfb, the XTEST
pointer route and the ImageMagick boot watchdog are all still in
`x11-runtime.sh` and still work. Reverting is three variables and a restart:

```sh
# in /data/vms/streamhost/stations/irix/station.env
SH_CAPTURE=x11
SH_INPUT_BACKEND=x11test
IRIX_CAPTURE=x11        # (station.env.fixture stanza)
systemctl restart streamhost@irix
```

The MAME binary does not need reverting with it: the producer is env-gated on
`IRIX_SHM_PATH`, which `x11-runtime.sh` only exports in shm mode, so the same
binary runs the old path unchanged. If the BINARY itself is suspect, the
previous one is kept beside it as `mame/sgi.prev-<md5>` — swap it back and
restart. Reverting in the repo is the same three values in
`registry/stations/irix.json` (`runtime.x11.capture`, `stream.pointer.backend`)
plus `make station-registry-generate`.

### Measured win

Interleaved A/B on a clone, both arms off ONE binary (the shm publisher is
env-gated on `IRIX_SHM_PATH`, so the only difference between arms is the display
path — the confound that invalidated an earlier VC2 A/B cannot happen here).
Cycle-normalised `emulated_seconds / (cycles/2.5e9)` over the emulated 150-300 s
window, attributed WITHIN each run by `mark.lua` (MAME's own "Average speed %"
swings ±8% with turbo wander and is unusable).

| arm | round 1 | round 2 | mean |
|---|---|---|---|
| `-video soft` on Xvfb (today) | 754.8 Gcyc / 49.7% | 780.4 / 48.1% | 767.6 / 48.9% |
| **`shm`** | **535.0 / 70.1%** | **547.1 / 68.5%** | **541.1 / 69.3%** |
| `-video none`, publisher off (ceiling) | 509.0 / 73.7% | 520.9 / 72.0% | 515.0 / 72.9% |

Within-round paired ratios: shm is **+41.0% / +42.4%** faster than the live path,
and the publisher costs a consistent **4.9%** against the no-display ceiling — so
the path captures ~85% of the maximum available win. The 226 Gcyc saved over a
150 s emulated window is 1.51 Gcyc per emulated second, which matches the
independently profiled 1.5-1.7 Gcyc/s cost of the display path exactly.

- Wire format, seqlock and damage handling: `streamhost/streamhost/src/capture/shm.rs`.
  Knobs (`SH_SHM_PATH`, `SH_SHM_POLL_MS`, `SH_SHM_DAMAGE`): `streamhost/docs/CONFIG.md`.
- The producer is a MAME-side patch to `src/devices/bus/gio64/newport.cpp`,
  env-gated on `IRIX_SHM_PATH` so it is inert for every other MAME use.
- `x11-runtime.sh` takes `IRIX_CAPTURE=shm`: it starts no Xvfb, passes
  `-video none`, and the boot watchdog samples the mapping through
  `fbstat.py` instead of `import -window root` (same normalised
  max-channel-mean number, so `IRIX_BLACK_EPS` keeps its meaning).

### Pointer: `SH_INPUT_BACKEND=mamecmd`, and why MOVE had to become MOVEP

(Since 2026-08-04 `mamecmd` is the ROLLBACK arm — production input rides the
mamectl socket, see "mamectl control plane". The device constraints below bind
either way; the module's file tail replays exactly this contract.)

With no window there is nothing for XTEST to inject into, so **every** input event
moves onto the channel that never depended on a display: the command file
`irixagent.lua` consumes. `MameCmdSink` (`streamhost/streamhost/src/mame_input.rs`)
keeps the XTest sink's dead reckoning — home once with an over-large negative
delta to clamp the guest cursor into the corner, then emit deltas from the last
absolute target — and only changes the transport.

The transport change is not free, and the reason is a hard device constraint.
`hle_ps2_mouse::sample()` runs at the guest-programmed sample rate (100 Hz by
default), reads the axis ioports, and transmits the difference as a **single
8-bit value**: any delta outside -256..255 between two samples is truncated on
the wire. Splitting a big move into several `MOVE` lines does *not* help — the
agent consumes every pending line inside one periodic tick and the device only
ever sees the final field value.

Two things were measured the hard way:

- A single oversized delta **wedges the guest mouse permanently**. A `-8192`
  homing slam applied in one shot moved the cursor +208 px (an 8-bit wrap) and
  then IRIX stopped responding to pointer input entirely for the rest of the
  session — no later `MOVE`, of any size, moved it again. Reproduced twice.
- A per-*tick* budget is not pacing. MAME's Lua periodic callback fires at 60 Hz
  of **emulated** time, faster than the mouse samples, so per-tick steps merge
  into one oversized device delta and you are back to the wedge.

- A single accumulator is not enough either. The guest clamps the cursor at the
  screen edge, so the counts a homing slam spends past the corner are *meant* to
  be discarded — but summed into one accumulator the next real move cancels part
  of that overshoot instead of moving the cursor. A 4-px walk started while a
  `-8192` home was still draining landed 13 px short.

Hence `MOVEP <dx> <dy>`: the agent QUEUES the delta and drains the queue
head-first at most `MOVE_STEP` (120) counts per axis per `MOVE_WINDOW`
(0.04 emulated s), leaving room for two windows to merge into one sample and
still stay inside the 8-bit field. An ordinary small move still lands on the tick
it arrives, with no added latency; only a jump larger than the budget spans
windows, and a queued move can never cancel the tail of the one before it.
`MOVE` keeps its original apply-immediately semantics for the ops scripts that
use it. `HOME_DELTA` is -2048 (enough to clamp from anywhere on a 1288x1024
surface) rather than -8192, so the one-time homing drain is ~0.7 emulated s.

Verified by instrumenting the agent: a `-8192` slam drained as 68 steps of -120
plus one of -32 = exactly -8192 with zero over-large `move_rel` calls, and 50
consecutive `MOVEP 4 4` commands moved the real cursor exactly +200,+200
(50/50 steps applied, none merged, none lost).

### The silent input death — a ±32768 delta on the first pointer move (2026-08-03)

The exhibit lost **all** input a second time: the cursor stopped moving and
typing had no effect, while the picture stayed live, MAME kept rendering and
`streamhost@irix` was `active` with `NRestarts=0`. It is not the `bad istack`
panic — the guest never died, the `iconlogin` chooser was drawing normally
throughout.

**Root cause: the Lua agent seeded its pointer accumulators at 32768 while the
emulated mouse's differencing state starts at 0, so the FIRST pointer motion of
every MAME session handed the device a delta of ~32768 counts.** The PS/2 wire
field is 9 bits (sign + 8), so that delta is truncated and the overflow flags
set, and IRIX then applies a garbage jump and ignores pointer motion for a
while afterwards.

The chain, each link measured on a namespaced clone with an instrumented
`hle_ps2_mouse`:

- `hle_ps2_mouse::sample()` differentiates the axis ioports against
  `m_mouse_x/m_mouse_y`, which it seeds from those same ioports in `update()` —
  at device reset and after **every command the guest sends**. The guest's last
  mouse command lands during boot (emulated t≈52 s on a v3 boot), long before a
  visitor arrives, and the ioports' MAME default is **0**. So `m_mouse_x` is 0
  and frozen until the agent's first write.
- The agent's first write was `32768 ± the move`. Logged on a clean boot, on the
  very first `MOVEP 100 60`: `OVERFLOW dx=-32668 dy=32708`.
- **Reproduced deliberately, on the browser-realistic first-contact sequence**
  (`MOVEP -2048 -2048` home, then a move to the screen centre, then ordinary
  moves), two clones booted from the same seed, differing only in the
  accumulator seed:

  | arm | first-contact trace (red-cursor centroid) |
  |---|---|
  | **32768 (shipped)** | `OVERFLOW dx=32648 dy=-32648`; the home slam lands in the **wrong corner** (1276, 28) and the next **three** commands move the cursor not at all, before it recovers |
  | **0 (fixed)** | no overflow at all; the home lands at (2, 4) as designed and every following move tracks |

- **That also explains the dead keyboard, with no keyboard fault.** The
  corrupted home parks the pointer at the top-right corner — *off* the
  `iconlogin` panel, over the root window — and X/4Dwm here is
  **pointer-focus**, so keystrokes go nowhere visible. Verified by typing into
  the login field through the matrix while the pointer was wedged *over* the
  panel: the characters appear. The keyboard was never broken.
- Why the exhibit nevertheless worked most of the time: the dead window is a
  handful of packets, and a visitor sweeping a mouse produces hundreds a second,
  so it is invisible. It becomes a dead exhibit when the first pointer traffic is
  **sparse** — a session that sends a few samples and then loses its transport
  (the client log for the incident shows `WebTransportError: Opening handshake
  failed` and a reconnect), or a liveness probe that sends exactly two.

**Fix, in two independent layers.**

1. `irixagent.lua` seeds `mx, my = 0, 0`, matching the device. One line, and it
   removes a guaranteed over-range delta from every session.
2. `scripts/build-guests/patches/mame-hle-ps2-mouse-carry.patch` makes the device
   **carry instead of truncate**: `sample()` clamps the reported delta to
   ±255 and advances `m_mouse_x/m_mouse_y` by only what it actually sent, so the
   remainder goes out on the following samples. The overflow flags can never be
   set again, by any producer. Verified on a third clone (carry patch, *unfixed*
   agent): the 32648-count slam drains over ~128 samples and the pointer never
   wedges — where the same agent on the stock binary wedged.

   This is not a fidelity regression. A real mouse cannot produce 255 counts in
   one 10 ms sample, so the overflow path is untested territory in every guest
   driver; the accurate-looking behaviour is the dangerous one.

The agent's `MOVEP` pacing is still worth having — it keeps the *emulated*
device fed at a sane rate — but it is no longer load-bearing for correctness,
which is the point: pacing could only ever bound what the agent emits, never
what the guest's own stalls let accumulate.

#### What the logs will show next time

`MOVEP` and `KEY` were never logged (per-event logging in this hot path costs
~13 points of a core), so a quiet agent log meant nothing at all — and the first
investigation read it as a dead agent. They are **counted** now, and the agent
emits one `stats` line every `IRIX_STAT_PERIOD` (15 s) **whether or not anything
happened**:

```
stats movep=41 move=0 key=6 queued=3120,1180 applied=3120,1180 mq=0 kq=0 emu=812
```

`queued` vs `applied` separates "commands are arriving" from "counts are
reaching the ioports", `mq`/`kq` show a stuck drain, and the line's mere
existence proves the periodic callback is still running. A silent log now means
a dead agent and nothing else. The tick is also held in an explicit
module-local + global reference, because MAME's Lua notifier subscriptions are
GC'd when nothing holds them (`emu.add_machine_frame_notifier` was seen firing
once here and stopping).

#### The liveness watchdog DID fire — and its log was in the wrong file

`livewatch.pid` existed and there was no `livewatch.log`, which was read as "it
never started". It had in fact detected the failure and relaunched MAME
(`00:43:05` probe fail 1/2, `00:45:11` fail 2/2, relaunch) — it just logged into
`bootwatch.log`. It now has its **own** `livewatch.log`, logs **every** probe
result rather than only failures, and emits a heartbeat line, so the question
"was the watchdog running" is answerable from that one file.

Two real weaknesses were fixed with it:

- **The probe compared `fbstat.py --sig`**, which samples every 64th pixel. A
  ~50-pixel cursor can cross the whole screen without changing one sampled byte,
  so the probe could call a healthy guest dead — and a blinking caret changes
  the signature and hides a dead one. `fbstat.py --cursor` now locates the red
  pointer over the whole frame (it is the only saturated red on an SGI-blue
  desktop) and the probe asks the question it means: *did the pointer I nudged
  move*.
- **The probe only ever armed on a frozen frame**, so anything animating on
  screen — the login field's caret, which is exactly what was on screen during
  the incident — could suppress it indefinitely. There is now a cadence probe
  (`IRIX_LIVE_PROBE_EVERY`, 600 s) that runs regardless, but only while nothing
  is being written to the command file, so a visitor is never nudged mid-drag.

And one weakness the new watchdog introduced and then had to fix, caught by
watching it run on the live station: **it relaunched a perfectly healthy guest
during a login.** xdm resets the X server at login, which re-opens and
re-initialises the PS/2 mouse, and for a couple of minutes afterwards (the bare
X root sits there for minutes before 4Dwm draws the Toolchest) an injected nudge
legitimately does not move the cursor. `LIVE_GRACE` cannot cover that — a
visitor logs in whenever they like. So a verdict now needs
`IRIX_LIVE_PROBE_FAILS` (3) failures **spanning at least `IRIX_LIVE_DEAD_MIN`
(300 s)**: a transition is over well inside five minutes, a real death lasts
forever, and the evidence for killing a live exhibit should be cheap to require.

Time to self-heal is ~7 minutes rather than the ~18 the old settings took, and
every uncertainty still resolves to "leave it alone".

### 1:1 and losslessness, measured on seed v3

Dead reckoning requires the guest to apply deltas 1:1. Seed
`irix65-apps-v3.chd` captures `/.sgisession` running **`xset m 1/1 0`** — not
`xset m 0 0`, which sets a zero numerator. Verified on the real framebuffer by
opening the desktop Console through this very pointer route and running
`xset q`: `Pointer Control: acceleration: 1/1  threshold: 0`.

Measured through the production input router (`SH_INPUT_BENCH_ADDR` → the same
`InputRouter` a browser session uses), at the 4Dwm desktop, in 100-event sweeps
across the full screen width:

| condition | commanded | applied to the ioport | pixels the cursor moved |
|---|---|---|---|
| 60 events/s, 10 px steps | 1000 px | 1000 (1.000) | 1000 (1.000) |
| 200 events/s, 5 px steps | 1000 px | 1000 (1.000) | 1000 (1.000) |
| 60 events/s under guest load (`find /`) | 1000 px | 1000 (1.000) | 1000 (1.000) |

From a cold home, commanding (600,600) open-loop put the hotspot at (598,598) —
2 px, which is the measurement's own cursor-hotspot constant — and one
closed-loop correction landed exactly on a 40x40 desktop icon.

**The route is lossless by construction, and that is a reason to prefer it
beyond the capture win.** Every count streamhost writes reaches the ioport (the
agent queues, it does not sample), and the emulated device merges rather than
drops when busy: `hle_ps2_mouse::sample()` leaves `m_mouse_x` untouched when it
skips a report, so the delta is simply delivered later. The XTest path it
replaces was measured losing 12-16% of motion under demo load, and any
dead-reckoning scheme accumulates that error without bound.

### Buttons: 4Dwm menus are spring-loaded, so every button needs real edges

Right-clicking the desktop posted the 4Dwm root menu ("Desktop / Log Out / Open
/ Make Copy / …") for a few frames and then it vanished. Both sinks fired a
synthetic `CLICK2`/`CLICK3` on the **press** edge and threw the visitor's
release away — only the left button carried real `DOWN1`/`UP1`. 4Dwm's root and
Toolchest menus stay posted only while the button is held and select the item
under the pointer on **release**, so a synthetic click opens the menu and closes
it again immediately.

`irixagent.lua` gained `DOWN2`/`UP2` and `DOWN3`/`UP3` (additively —
`CLICK2`/`CLICK3` stay for the ops scripts that use them) and both
`mame_input.rs` and `x11_input.rs` now emit real press/release edges for all
three buttons. Discarding a release was a correctness hazard beyond the menus:
the guest's button state could drift from the browser's and leave the guest
holding a phantom button.

### Edge resync — the one place dead reckoning cannot self-correct

A clamping guest and a dead-reckoned model disagree the moment the cursor is
driven into a screen edge: the guest stops at the edge, the model keeps the
commanded value, and commanding the edge again produces a *zero* delta — so
nothing can ever push them back into agreement. Measured: after one clamp at the
top the guest sat 127 px below the model, and a closed-loop corrector could not
recover it because the correction it wanted to send was a negative coordinate.

Both sinks therefore add a one-shot full-surface slam whenever the target ENTERS
an edge (never while parked on it, or holding the pointer against an edge would
queue slams faster than the agent drains them). The guest clamps, the two agree
again, and the overshoot costs nothing because the cursor is already pinned
there. The logic lives in `streamhost/streamhost/src/ptr_reckon.rs` and is shared
by `mamecmd` and `x11test` — this was a live defect on the exhibit under the
XTest path too, hit by any visitor who ran the pointer into a screen edge, and it
matters independently of the capture cutover because `x11test` remains the
rollback path.

### Boot watchdog — the black-screen cold-boot hang

A cold boot does not always reach the login chooser. Some fraction of boots
wedge on a **permanently black framebuffer** shortly after the console prints
`The system is coming up.`, at exactly the moment IRIX hands the display from
the boot console over to `iconlogin`. MAME stays alive at ~120% CPU and the
emulated MIPS kernel keeps executing (varied kernel PCs, emulated clock still
advancing) — it is the *display* that never comes back, and it never recovers
on its own. Reproduced with both the 256 MB and the stock 16 MB MAME builds
from a byte-identical fresh `disk.chd`, so it is neither the RAM patch nor disk
corruption.

Because reset mode is `relaunch`, an unlucky reset used to leave a visitor
staring at a black station forever. `x11-runtime.sh` therefore arms a **boot
watchdog** (`x11-runtime.sh --bootwatch`, backgrounded at launch, pidfile
`bootwatch.pid`, log `bootwatch.log`):

- It samples the **real framebuffer** every `IRIX_WATCH_INTERVAL` (15 s) with
  `import -window root` and calls a frame black when the largest channel mean is
  below `IRIX_BLACK_EPS` (0.004). A healthy boot is never black after the PROM
  splash paints at ~10 s, except for a **single ~10 s transient** at the
  console→`iconlogin` handover — hence `IRIX_WATCH_BLACK_HITS` (6 samples =
  90 s of continuous black) before it acts, and `IRIX_WATCH_GRACE` (60 s) before
  it looks at all.
- On a confirmed hang it kills MAME **by pidfile only** and relaunches it on the
  existing Xvfb from a fresh copy of the seed, up to `IRIX_WATCH_ATTEMPTS` (5)
  boots in total. Every attempt is logged.
- It cannot fight the service: `x11-runtime.sh` stamps a `bootwatch.gen` token
  at each full launch and the watchdog aborts if that token changes, it refuses
  to relaunch unless `streamhost@irix` is active, and `stop-station-x11.sh` kills
  `bootwatch.pid` *before* `mame.pid`.
- `IRIX_WATCH_DEADLINE` (1800 s) caps how long one attempt is watched; after
  that the watchdog exits and leaves whatever is on screen.

Detection is deliberately narrow (only the observed all-black signature) so it
can never mistake a legitimate boot for a failure.

## Exec channel — `labctl exec irix "<cmd>"` (serial, BUILT — NOT CUT OVER)

The station *can* have a REAL exec channel: captured stdout+stderr and the guest's
own exit code, like the ssh and bridge kiosks.

> **Status.** Built, and verified end to end on a clone. The LIVE station is
> untouched: it runs the seed without the agent, `x11-runtime.sh` on labhost
> has no `-ioc2:rs232a pty`, and `registry/stations/irix.json` keeps
> `exec_kind: null` on purpose — so `labctl exec irix` errors out exactly as it
> did before, rather than advertising a channel that cannot work. The cutover
> below is a deliberate human step, and the registry flip is the LAST part of it.

```
$ ssh lab 'labctl exec irix "hinv | head -3"'     # after the cutover
CPU: MIPS R4600 Processor Chip Rev 2.0
FPU: MIPS R4600 Floating Point Cop Rev 2.0
1 100 MHZ IP22 Processor
$ ssh lab 'labctl exec irix "false"'; echo $?
1
```

Full design, protocol and traps: `streamhost/guest-agents/irix/README.md`. The
short version:

- The guest has no networking, so the transport is the emulated second serial
  port. `-ioc2:rs232a pty` in `x11-runtime.sh` == IRIX `/dev/ttyd2`, a port
  `/etc/inittab` leaves free (`t2` ships `off`). `ioc2:rs232b` is `/dev/ttyd1`,
  the console getty from `t1`, and production still leaves it unpopulated.
- `irixagent.pl` (Perl 5.004 + POSIX::Termios) is captured into the seed at
  `/usr/local/bin/` and started by an `/etc/inittab` **respawn** entry, so init
  supervises it and it survives a relaunch. Idle it blocks in `sysread()` —
  zero emulated CPU, which matters on a station that is CPU-bound.
- `/root/irixexec.py` is the host client; `labctl`'s `exec_kind: "serial_e"`
  shells out to it with the station dir. There is **no port**: MAME never prints
  the pty slave's name, so the client scrapes it out of `/proc/<mame>/fd` (and
  checks the pid really is MAME before writing into it). `x11-runtime.sh` also
  publishes it in `<tile>/serial.pts` for convenience, but that file goes stale
  on relaunch and is only a fallback.
- Protocol `irixser/2` (agent 2.0): escaped ASCII lines, `<id> <verb> <sum>
  <payload>` in BOTH directions with the framing inside the checksum, `X
  <status>` for the exit code, `RESULT <id>` to replay a reply whose checksum
  failed (re-fetch, never re-run) under the requester's id, `N` to reject a
  request that did not verify (not run — resend it), host-side timeout via
  `ABORT` which is honoured mid-transmission, `--detach`, and an output cap that
  leaves the remainder in the guest.
- `IRIXEXEC_TRACE=<file>` records every byte in both directions — the first
  thing to reach for when something on this wire looks wrong.

### Acceptance suite

```
scripts/build-guests/irix/irix-serial-selftest.py     # ~25 s, needs only perl
```

Runs the real agent and the real client against each other over a pair of ptys
with a relay in the middle that corrupts one chosen line on demand — so the
corruption cases are produced, not waited for. It does not need MAME, IRIX or
labhost. Run it before every recapture; it is the reason a protocol change is
minutes rather than a day of 4.5-minute cold boots. What it cannot cover is
IRIX's perl 5.004 and MAME's SCC itself — those still need a booted clone.

### Five things that will bite whoever touches this next

1. **MAME's SCC drops transmitted bytes.** `SCC85230` signals "transmitter
   empty" before the byte has left, so `sduart` overruns the emulated 4-byte TX
   FIFO. Measured on 1200-byte patterns: 4 bytes per write is lossless, 8 loses
   25%, 16 loses 37% — the write SIZE matters, not the byte rate. Hence the
   agent's pacer. Throughput is **~140 B/s** (`p=idle`, the agent sleeps) or
   **~270 B/s** (`--fast`, a busy-loop at 100% guest CPU) — the spread across
   runs is roughly ±15%, host load being the variable. The real fix is in
   `src/devices/machine/z80scc.cpp` and would need its own binary cutover.
2. **`socket.` endpoints are single-shot.** MAME closes its listener after the
   first accept and never re-accepts, so a socket-backed exec client works
   exactly once per MAME run. Use `pty`.
3. **Two agents on one serial line look exactly like wire corruption.** Their
   4-byte paced writes interleave; an `X 265` came back as `X 3,5`. An install
   that killed the wrapper but not the perl left init respawning a second one.
   The agent holds an `flock` on `/var/tmp/irixagent.lock` for its whole life
   and a second instance declines to start; the installer stops the old one
   through init (`telinit q` with the entry removed) and asserts a single
   process. Never `/sbin/killall` in a guest — on SysV it is the shutdown helper
   and signals everything.
4. **This perl mis-renders integers, about one run in five.** The historic
   `X 265` arriving as `X 3,5` was blamed on two interleaved agents. It came
   back on a clone with exactly ONE agent, and the line's checksum was correct
   *for the garbled text* — which only the agent can produce. So IRIX 6.5's perl
   5.004 (n32) sometimes stringifies 265 as `3,5`, and no wire integrity check
   can see it. The status is now forced through `sprintf("%d", ...)` once in
   `do_run` (8/10 before, 20/20 and 10/10 after) and the client replays a
   checksum-clean reply it cannot parse. Do not remove either.
5. **Whitespace-collapsing parsers corrupt payloads.** A `.strip()` on a
   received protocol line ate four bytes out of an otherwise byte-exact
   `/etc/inittab` transfer, because a 512-byte chunk boundary landed inside an
   indent. Split on a single space; strip only CR/LF. Same family: the client
   writes guest output as BYTES, because decoding it to `str` and letting stdout
   re-encode turned every byte >= 0x80 into two.

### X11 / launching demos

The agent exports `DISPLAY=:0` and `XAUTHORITY=/.Xauthority`. That works once
somebody is logged in. At the `iconlogin` chooser the station boots to, xdm holds
the server grabbed and X clients **block indefinitely** — verified: `xdpyinfo`
never returned in 10 minutes. Always pass `--timeout` (the client kills the
process group and returns 124), and log in before launching anything graphical.

### Recapturing the agent into a seed

```
scripts/build-guests/irix/irix-serial-selftest.py            # protocol first, on any box
irix-serial-rig.sh boot bake1 --console --display 171   # ~5 min cold boot
irix-serial-install.sh bake1                            # ~90 s, cksum-verified
irix-serial-rig.sh ping bake1 --agent-src streamhost/guest-agents/irix/irixagent.pl
irix-serial-rig.sh halt bake1                           # clean shutdown -i0
# -> /data/vms/sandbox/irix-serial/bake1/disk.chd
```

The installer types the agent in through the console getty's own here-document.
It needs a **virgin `login:` prompt**: `login(1)` flushes typeahead before
reading a password and asks for one after any failed attempt, and `/etc/profile`
asks `TERM = (vt100)` and eats the next line. Root's shell is csh, so it
`exec /bin/sh` first (csh does history expansion on `!`), and turns echo off
before any bulk transfer — while the guest is echoing it is transmitting, and
MAME's SCC drops RECEIVED bytes while it does.

**Editing `streamhost/guest-agents/irix/irixagent.pl` does NOT change the
exhibit.** Only a recapture does, and no gate in this repo can see inside a
seed. The agent therefore checksums its own source at startup and reports it
in every PING reply, so which version the guest is running is one command:

```
ssh lab 'python3 /root/irixexec.py /data/vms/streamhost/stations/irix --ping'
# irixser/2 2.0 <src-sum>            (exit 126 with --agent-src on a mismatch)
```

Record the `src-sum` of every captured seed in the table below.

### `irix65-apps-v3-serial.chd` — the agent seed

Built from v3 (`368fcfb9b56fb4165a4e456238dc1a18`, which stays the LIVE seed
until the cutover). Delta versus v3, and nothing else:

- `/usr/local/bin/irixagent.pl`, `/usr/local/bin/irixagent.sh` (mode 755),
  both `cksum`-verified against the repo copies on the guest itself
- one `/etc/inittab` line, `ia:23:respawn:/usr/local/bin/irixagent.sh …`;
  the pre-agent file is kept as `/etc/inittab.preagent`

| seed | md5 | agent | src-sum |
|---|---|---|---|
| `irix65-apps-v4.chd` | `0a2118af48852b74df546afb235ab305` | irixser/1, 1.2 | — (superseded) |
| `irix65-apps-v3-serial.chd` | `f8c67f03ccb19ee979d7aadbd60499d7` | irixser/2, 2.0 | `076e` |

`v4` is kept only as the record of the first capture; it speaks `irixser/1`, which
the current client cannot talk to, and it must not be cut over to.

**The name is not `v5` on purpose.** `irix65-apps-v5.chd` was taken, on the same
labhost and on the same day, by the concurrent host-only-networking work
(`irix-network`, commit `1cab84c`). Two branches numbering the same lineage in
parallel is how a seed gets silently swapped underneath a station, so this one
says what it is: v3 plus the serial agent, and nothing else. Whoever merges the
two lines of work owns recapturing a single combined seed.

### Cutover (human step, in this order)

```
# 0. labhost's x11-runtime.sh must be byte-identical to main's before step 1 —
#    the live copy carries livewatch fixes that a stale scp would revert.
ssh lab 'md5sum /data/vms/streamhost/stations/irix/x11-runtime.sh'
git show origin/main:streamhost/stations/irix/x11-runtime.sh | md5sum
#    if they differ, harvest the labhost copy FIRST; do not overwrite it.
# 1. deploy the launcher (adds -ioc2:rs232a pty + serial.pts). /root/irixexec.py
#    and /usr/local/bin/labctl were ALREADY put in sync when this landed (both
#    are inert while exec_kind is null); re-scp only if the repo has moved on.
scp streamhost/stations/irix/x11-runtime.sh lab:/data/vms/streamhost/stations/irix/
scripts/dev/verify-box-sync.sh | grep -E 'labctl|irixexec'   # both MATCH
# 2. point the station at the new seed and relaunch
ssh lab "sed -i 's/irix65-apps-v3.chd/irix65-apps-v3-serial.chd/' \
         /data/vms/streamhost/stations/irix/x11-runtime.sh"   # or set IRIX_GOLDEN
ssh lab 'systemctl restart streamhost@irix'
ssh lab 'python3 /root/irixexec.py /data/vms/streamhost/stations/irix --ping'
# 3. LAST: publish the capability and prove it
#    registry/stations/irix.json -> "exec_kind": "serial_e"  (+ make station-registry-generate,
#    commit, sync the repo to labhost)
ssh lab 'labctl gen && labctl ls | grep irix'
ssh lab 'labctl exec irix "hinv | head -3"'
```

Rollback is one `IRIX_GOLDEN` back to v3, a restart, and `exec_kind` back to
`null`; the agent is inert without the launcher's `-ioc2:rs232a pty`, so the
serial image is safe to boot on the old launcher too.

## Assets (large binaries, NOT in the repo)

Stage / verify with `streamhost/stations/irix/fetch-assets.sh` (run on labhost).
They live in the **production** tree `/data/vms/streamhost/assets/irix/`
(overridable via `IRIX_ASSETS` / `IRIX_MAME`). They used to be
read straight out of `/data/vms/sandbox/` — the clone/experiment scratch area —
which meant a live exhibit resting on paths other agents rebuild underneath it;
promoted 2026-07-31. The sandbox copies stay as the build/experiment stage.

- `/data/vms/streamhost/assets/irix/` — **`irix65-apps.chd`** (the exhibit
  seed the station actually boots: md5 `09e51dbc…`, 444 **and `chattr +i`**),
  `irix65.chd` (the bare base install it was built from, md5 `430bf0ba…`, also
  444 + immutable), `roms/indy_4610/` (PROM bios b10), `nvram/` (eaddr +
  `monitor=h` captured), `uicfg/ui.ini` (`skip_warnings 1`).
  The launcher picks the image via `IRIX_GOLDEN`, so every roll forward and
  roll back along the lineage is a one-variable change. **The live value is set
  in `station.env`, and that file is the only authority on which seed is
  serving** — `x11-runtime.sh`'s own default is a fallback, not the answer.
  Today `station.env` names **`irix65-apps-v8.chd`** (see the FSN section at the
  end of this file); the lineage behind it is v3 (deterministically bare
  desktop — two cold boots from independent clones gave md5-identical
  framebuffers — plus `/.sgisession` running `xset m 1/1 0` for a 1:1 pointer
  from login), v5 (host-only networking, both root web servers off,
  md5 `b8a20bbe27593889995ab57978ca75ae`), v6 (egress guest config), v7
  (v6 merged with the serial exec agent) and v8 (FSN).
- `/data/vms/streamhost/assets/irix/mame/sgi` — MAME 0.288+ (upstream commit
  `8f21e978`) built with the station's whole adopted patch stack.

  **The ordered stack lives in exactly one place:
  [`scripts/build-guests/irix/irix-mame-stack.sh`](../../scripts/build-guests/irix/irix-mame-stack.sh).**
  Do not copy the list into a second script or into this table — a stale second
  copy is what left `mame-taptun-ifname-env.patch` documented here as adopted
  while the shipped binary did not carry it, and that failure is silent (MAME
  ignores `MAME_TAP_IFNAME`, opens upstream's global `tap-mess-<uid>-0`, finds
  nothing, and runs on with no networking while everything else looks healthy).
  That wrong line cost a campaign its interactive measurements. Believe the
  `carrier` check `start_mame()` prints, not prose.

  Rebuild it with [`scripts/build-guests/emulators/build-mame-irix.sh`](../../scripts/build-guests/emulators/build-mame-irix.sh)
  (labhost, Linux/x86-64) or `build-mame-macos.sh` (dev Mac); both source the same
  stack file, so they cannot drift.

  | patch | what it buys |
  |---|---|
  | `mame-irix-skip-warnings.patch` | `-skip_warnings` skips the startup warning unconditionally (dismissing it with a click trips the GIO2 panic) |
  | `mame-indy-256mb-ram.patch` | 256 MB instead of 16 MB — IRIX 6.5 + 4Dwm pages continuously otherwise |
  | `mame-mc-dma-ptbase-mask.patch` | stops `PANIC: bad istack` — the MC truncated DMA page-table addresses above 128 MB. Required partner of the RAM patch, never one without the other |
  | `mame-indy-drc-cache-256mb.patch` | +15% at an idle desktop (the stock 32 MB DRC cache thrashes). x86-64 only — on arm64 a 256 MB code cache outruns the reach of a `B` and MAME dies with `asmjit error 48: InvalidDisplacement` |
  | `mame-newport-dirty-frame-cache.patch` | +74% at a static screen (don't re-render an unchanged frame) |
  | `mame-newport-shm-framebuffer.patch` | the `SH_CAPTURE=shm` producer; +41% by deleting the display path. **Must come after the dirty-frame cache** — its hunks quote `m_cache_bitmap`/`m_cache_valid`, which do not exist before it |
  | `mame-ds1386-date-from-day.patch` | day-of-month came from the seconds field — the boot nondeterminism. Diff paths are relative to `src/devices/machine`, so it is the one applied with `patch -p1` from inside that directory |
  | `mame-hle-ps2-mouse-carry.patch` | the PS/2 mouse carries an over-range delta instead of truncating it — an over-range report kills IRIX pointer input |
  | `mame-taptun-ifname-env.patch` | `MAME_TAP_IFNAME` picks the tap device; upstream hardcodes one global `tap-mess-<uid>-0` per host. Linux only |
  | `mame-osd-cache-line-size-memo.patch` | −2.6% of all cycles across a boot (−4.05% while the DRC is compiling hardest): the recompiler was re-reading the cache line size from sysfs once per compiled block. Nothing at an idle desktop. Upstreamable — see [`docs/lab/irix-cache-line-size-memo.md`](../lab/irix-cache-line-size-memo.md) |
  | `mame-pit8253-idle-strobe-rearm.patch` | deletes an upstream defect: an idle 8254 counter in mode 4/5 re-arms its update timer twice per input clock forever — 1.67 M dead callbacks per emulated second, because IRIX parks IOC2 counter 2 in mode 4 during boot and never takes it out |
  | `mame-indy-scheduling-quantum.patch` | `set_maximum_quantum(8 us)` in `ip24_base()`. **Required partner of the PIT patch**: that storm was the only thing interleaving the CPU with its own keyboard controller, so the PIT fix alone boots IRIX to a desktop with no keyboard and no mouse ("PC keyboard/mouse controller diagnostic *FAILED*") |

  **Excluded on purpose**, and both exclusions are load-bearing:

  | patch | why it is out |
  |---|---|
  | `mame-indy-mips3-fastram.patch` | BLOCKED — with the station's `-ioc2:rs232a pty` the guest stops at "Memory diagnostic *FAILED* / Check or replace: SIMM S7" and never reaches the chooser. Diagnosis and the bisect table that is its acceptance test are further down this file |
  | `mame-newport-vc2-restale-timing.patch` | a real MAME inaccuracy, but disproven as the cause of the black-screen boot hang; it buys nothing |

  **Why 8 us for the quantum.** Cold boots fail outright from 32 us up (0/6
  reached a desktop) while every boot at ≤16 us succeeded (8/8); Fisher exact
  p ≈ 3e-4, and the background rate of the unrelated black-screen cold-boot hang
  on this image is 2-in-10, so the failures above 32 us are not that. 8 us is the
  largest value with more than one octave of margin under a measured cliff whose
  failure mode is a guest that never boots. What is still unmeasured is whether 4,
  8 or 16 us is *faster* — the sweep ran on labhost carrying 47-82% foreign CPU. See
  [`docs/lab/irix-pit-quantum-2026-08-03.md`](../lab/irix-pit-quantum-2026-08-03.md).

  Build: `make SUBTARGET=sgi SOURCES=src/mame/sgi/indy_indigo2.cpp USE_QTDEBUG=0 -j"$(nproc)"`.
  `USE_QTDEBUG=0` is not optional on labhost — the Qt debugger front end wants
  `qmake6`, which is not installed, and genie fails the build before compiling
  anything. (`REGENIE=1` only if you changed compiler flags; it forces a full
  regen and invalidates the PCH.)

  **The previous binary is kept beside it** for one-variable rollback, exactly
  as the seeds are: `sgi.prev-<md5>`.
- `/data/vms/streamhost/assets/irix/glibc/` — **retired 2026-08-07, nothing
  reads it.** It existed only to run the trixie-built `sgi` binary on a bookworm
  rootfs. labhost is trixie (glibc 2.41 / libstdc++ 3.4.33) and the binary needs
  at most `GLIBC_2.38` / `GLIBCXX_3.4.32`, so MAME is exec'd directly and the
  `ld-linux … --library-path` indirection is gone from every launcher and rig.
  The directory is kept on labhost, unreferenced, for one rollback cycle.

### The seed CHD is copied, not overlaid — and must be immutable

`irix65.chd` is an **uncompressed** CHD, and MAME opens such an image `O_RDWR`
and never creates a `-diff_directory` overlay. MAME runs as root, so `chmod 444`
does not stop it: the seed was silently mutated in place for days (three
distinct md5s on 2026-07-31 before it was caught, exactly the corruption the
444 was meant to prevent). Locking it with `chattr +i` does stop the writes, but
MAME has no read-only fallback — it dies with
`Unable to load image ...: Operation not permitted`.

So the station keeps the seed **immutable** and `x11-runtime.sh` re-copies it to
a throwaway per-launch `disk.chd` in the station dir. Use `cp --reflink=always`,
not `auto`: as a ZFS block clone the 2.24 GB copy takes **0.13 s** instead of
the ~2 s `auto` costs when it silently falls back to a real copy. Every launch —
and therefore every reset, which is a relaunch — boots from a pristine image.

This is load-bearing for *measurement* as well as image integrity: the perf
agent traced a 4.5% run-to-run instruction-count σ to the same write-through
(at one point three MAME instances were writing one CHD), and the immutable
master + per-run clone cut it to 0.5%.

Full design + hard-won findings: `docs/history/irix-tile-issue20-handoff.md` and the
labhost recipe `/data/vms/sandbox/irix-mame/RECIPE.txt`.

## Track A — apps + demos install rig (`scripts/build-guests/irix/irix-apps/`)

Issue #20 follow-on: install everything the official guide
(https://sgi.neocities.org/installguide) recommends, so the exhibit is a
lived-in IRIX desktop rather than a bare install. Phase 1 (inventory,
acquisition, harness) landed 2026-07-31; the ordered plan with per-step
checkpoints and risks is `scripts/build-guests/irix/irix-apps/INSTALL-PLAN.txt`.

Findings that shape the work:

- The prebuilt `irix65.chd` was itself built from that guide, so its base
  install and every extra `inst` line it lists (`eoe.sw.fonttools/uucp/xlv/
  spell`, `ftn_eoe`, `inventor_eoe.sw64`, `ifl_eoe.sw64`, `dmedia_eoe.sw64`)
  are already present. The remaining delta is the **SGI General Demos**,
  **ONC3/NFS v3**, and a handful of Applications-CD leftovers (`gnu`,
  `accessx`, `impr_*` Impressario).
- **Disk headroom was the blocker.** The seed is 128x16x2000x512 = 2.0 GB;
  its XFS root is 1870 MiB with only 704 MiB free. `make-work-chd.sh` builds a
  writable `work.chd` at 128x16x6000 (6.29 GB) by rewriting the SGI volume
  header (`sgi-relabel.py`); the filesystem itself is grown **in-guest** with
  `xfs_growfs /`, because Linux cannot replay IRIX's XFS log.
- SGI install CDs are **EFS volumes behind an SGI disk label**, not ISO9660
  (`mount -t efs -o loop,ro,offset=32768`). MAME still accepts them directly.
- MAME media options for `indy_4610`: `-hard1` (scsibus:1 harddisk),
  **`-cdrm1`** (scsibus:6 SCSI CD-ROM). `-cdrm6`/`-cdrom6` are rejected.
  CDs can also be hot-swapped from the Lua agent without restarting MAME.

Media (9 SGI CDs, ~3.6 GB) is fetched by `fetch-media.sh` from jrra.zone into
`/data/vms/sandbox/irix-apps/media/` with a `SHA256SUMS` manifest. All install
work happens on the writable copy in that namespaced directory — the seed
CHD stays `chmod 444` and is only ever read.

### Track A phase 2 — the apps/demos seed (2026-07-31)

`irix65-apps.chd` (md5 `09e51dbc9080e90785149bbec7a0dd64`) is built and verified:
root XFS grown in-guest to 5.87 GiB, the **SGI General Demos 6.5.12 (28 demos)**
installed and proven running on the real framebuffer (Seahaven Towers and the
GL `ideas` demo), `accessx` added, and boot time cut from ~6 min to ~4.5 min by
`chkconfig esp off` (+ `chkconfig sysevent off`; the boot noise that survived it
is a stray file, not a live service — see below). NFS, Impressario and `gnu`
were deliberately skipped —
the CD builds conflict with 6.5.22 `eoe.sw.base`, and `gnu` is only pointers into
the Freeware CDs. Full record in `scripts/build-guests/irix/irix-apps/INSTALL-PLAN.txt`.

#### `S77sysevent.989` is an orphan TEMP FILE, not a service that refused to stop

`chkconfig sysevent off` **did** take. Two earlier readings of the boot console
were both wrong, and the disk says so: on `irix65-apps.chd`,
`/etc/config/sysevent` is `off` and the in-guest `chkconfig | grep sysevent`
prints `sysevent  off`.

What actually prints the wall of `/etc/rc2.d/S77sysevent.989[131]: unix:  not
found` is a **leftover file with an `S`-prefixed name sitting in `/etc/rc2.d`**:

- `/etc/init.d/Sysevent` (= `/etc/rc2.d/S77sysevent`) builds its merged
  notifier config in `KMSG_TMP=$0.$$`. One boot, long before this station existed,
  ran it as PID 989 and left `/etc/rc2.d/S77sysevent.989` behind — a 12551-byte
  **data** file of `unix irix 4194320 KERN_NONE ".*"` notifier rules, mode 644.
- `rc2` runs *every* `/etc/rc2.d/S*`, so it feeds that data file to the shell.
  Each non-comment line is a failed command lookup (`unix:  not found`,
  `midisynth:  not found`). The `989` is the file's own name, not an iteration
  count; the bracketed number is the shell's line number and climbs `130 → 168`
  once. Turning the *service* off can never stop it.
- The orphan is inherited: it is present in the base `irix65.chd` too.

Fix = `rm /etc/rc2.d/S77sysevent.989`. Done in the recapture below.
`chkconfig esp off` was always fine and is what actually bought the boot time:
`S95availmon: esp chkconfig flag is off. No action.`

#### Reading a CHD's filesystem WITHOUT booting it

Bisecting build stages or auditing a shipped seed does not need a 4.5-minute
boot. The IRIX root is plain XFS (big-endian on-disk, which Linux reads
natively), behind an SGI volume header:

```sh
cp --reflink=always <golden>.chd /data/vms/sandbox/<yours>/x.chd   # never open the seed
chdman extractraw -i x.chd -o x.raw                                # ~6 s, 6.29 GB sparse
# partition 0 (XFS root) starts at LBA 266240 => byte offset 136314880
mount -t xfs -o ro,norecovery,nouuid,loop,offset=136314880 x.raw mnt
```

`norecovery` and `nouuid` are both required: IRIX's XFS log is "written in
incompatible format" for Linux (so a **read-write** mount is impossible unless
the guest was cleanly halted), and every image descends from one install so
they all share a filesystem UUID. Parse the partition table yourself if an
image was relabelled — `struct partition_table pt[16]` lives at byte 312 of
sector 0, three big-endian `int`s each (`nblks`, `first_lbn`, `type`).

Verification on an intermediate `work.chd` is what let the last round ship an
unverified claim. Verify on the exact artifact you intend to promote.

**The seed must never be given to MAME directly.** MAME opens `-hard1`
read-write and the runtime is root, so `chmod 444` does not protect it — a single
verification boot changed the file's md5 and size. `chattr +i` does protect it but
makes MAME refuse to start. Use a ZFS copy-on-write clone per launch instead
(`cp --reflink=always`, 2.24 GB in ~0.13 s) — that is what `run-golden.sh` does.
`x11-runtime.sh` does the same, and both seeds in the production asset tree
are 444 + `chattr +i`, so the live station is not exposed. **Promoted to the live
station 2026-07-31**: the exhibit boots `irix65-apps.chd` and reaches the
`iconlogin` chooser in ~4.5 min (was ~6).

### Demos audit + `irix65-apps-v2.chd` (2026-07-31)

A perf agent reported the demos missing from the live image. **They are not.**
The shipped `irix65-apps.chd` (md5 `09e51dbc…`) carries all 28 General Demos,
confirmed both offline (XFS mount, `/usr/demos/General_Demos`) and on the real
framebuffer (`ls /usr/demos`, `versions demos` all `I = Installed`, plus
Seahaven Towers and the GL `ideas` demo rendering side by side).

The report came from booting the **wrong image**: `/data/vms/sandbox/irix-perf/
run-clone.sh` clones `master.chd`, which is the *base* `irix65.chd`
(md5 `430bf0ba…`). That image has exactly the symptoms reported —
`/usr/demos` → `Performer` only, and the only `atlantis` is the screensaver
`/usr/lib/X11/savers/defaults/atlantis`. The perf tree's copy of the apps
seed is the separate `master-apps.chd`, used only by `drc-trial.sh`. **When a
station has two seeds, name the one you booted in the finding.**

The audit did produce a corrected seed, for the `S77sysevent.989` orphan:

- `/data/vms/sandbox/irix-demos-audit/irix65-apps-v2.chd`,
  md5 `7ef955e262bcd31cd9f7062ef975697e`, 2,241,540,096 bytes, 444 + `chattr +i`.
- Diff vs `irix65-apps.chd`: `/etc/rc2.d/S77sysevent.989` deleted, and IRIX was
  shut down cleanly (`/etc/shutdown -y -g0 -i0`) instead of having MAME yanked
  out from under it. Boot console is now free of the ~40-line
  `unix:  not found` wall; `chkconfig | grep sysevent` → `sysevent  off`;
  all 28 demos present and two of them (`seahaven`, `ideas`) proven running on
  the framebuffer **on this exact artifact**.
- v2's one flaw: the clean shutdown let 4Dwm write a *valid*
  `/.desktop-IRIS/0.0/4Dwmsession`, so logging in also restored a `winterm`.
  (The shipped seed's copy of that file is torn binary garbage from its
  unclean exit — which is the only reason it restored nothing. Session restore
  had never been *decided*, only accidental.) Fixed properly in v3 below.
- Evidence PNGs: `/data/vms/sandbox/irix-demos-audit/evidence/`.

### `irix65-apps-v3.chd` — bare desktop + 1:1 pointer (2026-08-02)

**LIVE since 2026-08-02:** `/data/vms/streamhost/assets/irix/irix65-apps-v3.chd`,
md5 `368fcfb9b56fb4165a4e456238dc1a18`, 2,241,560,576 bytes, 444 + `chattr +i`.
`IRIX_GOLDEN` defaults to it; `irix65-apps.chd` and `irix65.chd` stay in place
for one-variable rollback. Cutover verified on the exhibit: the per-launch clone
came up at the v3 size (2,241,560,576 vs the previous 2,241,540,096), the station
reached the iconlogin chooser without watchdog intervention, and logging in gave
the bare Toolchest-and-icons desktop (Toolchest-crop sd 0.257, screenshot-confirmed).

Diff vs `irix65-apps.chd` — every item deliberate:

| change | why |
| --- | --- |
| `/etc/rc2.d/S77sysevent.989` deleted | kills the boot-console `unix:  not found` wall |
| `4DWm` app-defaults: `*SG_autoSave: false` | 4Dwm no longer saves the session at logout |
| `4Dwmsession` reduced to the ToolChest block | nothing left with a `command` to relaunch |
| `/.sgisession` = `/usr/bin/X11/xset m 1/1 0` | pointer acceleration off at every login |
| IRIX halted with `/etc/shutdown -y -g0 -i0` | no torn files from a yanked emulator |

#### How the Indigo Magic session actually starts (read `/var/X11/xdm/Xsession.dt`)

This is the load-bearing mechanism, and two details are traps:

- The **Toolchest and the desktop icons are started unconditionally** by
  `Xsession.dt` (`toolchest` is launched explicitly precisely *because* it sets
  no `WM_COMMAND` and session management would never restore it; `fm -b` draws
  the background). Emptying the session file cannot cost you them.
- `4Dwm -launch` relaunches only entries in `4Dwmsession` that carry a
  `command`. So a session file holding just the command-less ToolChest stanza
  launches **nothing** — that is the bare desktop.
- **The session file must stay NON-EMPTY.** The gate is
  `if [ -r $wmsession -a -s $wmsession ]`, and the `else` branch runs
  `/usr/sbin/startconsole -iconic`. Deleting `4Dwmsession` therefore does *not*
  give a bare desktop — it gives you an iconified console instead.
- **`SG_autoSave` is read at 4Dwm startup.** Editing the resource and logging
  out in the *same* session still auto-saves, because that 4Dwm was started
  with the old value. The capture needs two logins: one to install the resource,
  a second (where 4Dwm starts with `autoSave: false`) to fix the session file
  and shut down. This cost a full capture cycle to discover.
- `4Dwmdesks` is rewritten by 4Dwm continuously and is *not* worth fighting —
  it records window placement only and launches nothing.

#### Pointer: `xset m 1/1 0`, not `xset m 0 0`

`xset m 0 0` reports `acceleration: 0/1` — a zero numerator, which is ambiguous
rather than unity. `xset m 1/1 0` reports `acceleration: 1/1  threshold: 0`.
Measured pointer gain is identical either way, so prefer the unambiguous form.
`/.sgisession` is left **mode 644 on purpose**: `Xsession.dt` runs it through
`/bin/sh` when it is readable-but-not-executable, so it needs no shebang.

Measured on v3 with XTest relative motion (`relmove 200,150`):

- idle bare desktop: **gain 0.995 / 0.993** — 1:1.
- same image with two demos running: 0.880 / 0.840. The shortfall is *dropped
  motion events* in the XTest→emulated-PS/2 path under load, **not**
  acceleration. Do not chase it in `xset`.
- IRIX's default (before this change) is ~2.75x horizontal, ~1.77x vertical.

#### Verified on the exact artifact, twice

Two cold boots from independent `cp --reflink` clones of the staged file:

- **bare desktop both times** — Toolchest + `UnixRoot`/`blender1.0`/`dumpster`
  icons, no windows. The two framebuffer captures are **md5-identical**
  (`a714c1e3…`), which is the determinism claim in its strongest form.
- boot console free of the `S77sysevent.989` wall; `esp` still reports off.
- `xset q` → `acceleration: 1/1  threshold: 0`, applied automatically at login.
- 28 demos in `/usr/demos/General_Demos`; `seahaven` (2D) and the GL `ideas`
  demo both launched and rendering.
- Evidence: `/data/vms/sandbox/irix-demos-audit/evidence/v3-*.png`.

One of the boots hit the known black-screen cold-boot hang at the
console→`iconlogin` handover (X root painted, then black, MAME alive at 109%);
relaunching cleared it. That is the documented ~8% hang the station's boot watchdog
exists for, not a property of this image.

#### Driving the guest: read coordinates from MAME snapshots only

`import -window root` on the Xvfb and MAME's own snapshot **do not share an
origin** (and MAME's frame is 1288x1024, not 1280x1024 — the VC2 reprograms the
screen ~85 frames into boot). Coordinates read off an `import` capture land
tens of pixels out; `point.py` closes its loop on MAME snapshots, so feed it
coordinates measured on those. Also: dragging from the Toolchest straight to a
menu item slides down the Toolchest column and switches menus — go **right into
the menu first, then down**.

### VC2 stale timing table — a real MAME bug, but NOT the black-screen hang

**Two separate claims, and only the first survived contact with the data.**

**Proven (2026-07-31): MAME's VC2 decode goes stale.** It decodes the Newport
VC2's video-timing table *once*, only when VC2 register 0x00 (video entry
pointer) is written. An instrumented cold boot logging every 0x00 write together
with the count of timing-RAM words since the last one shows IRIX writing its
**last** 0x00 at emulated t=57.8 s and then ~4,500 further RAM words with no
further 0x00 write ever:

```
57.830  REG0 vid=0400 ramw=4066 readout=386,41..1674,1065 size=1288x1024
59.510  RAMW n=7408 addr=1000
61.940  RAMW n=8564 addr=0500
```

Real VC2 hardware re-reads that table every frame. So this is a genuine
emulation inaccuracy, and `scripts/build-guests/patches/mame-newport-vc2-restale-timing.patch`
corrects it (dirty-mark on RAM writes, re-derive at vblank, throttled 1-in-8
frames, signal a timing change only when the rectangle actually moves).

**Disproven (2026-08-02): it is not what causes the black-screen hang.** The
predicted consequence was that `update_screen_size()` would derive a degenerate
rectangle and `screen_update()` would then draw nothing. Two independent results
kill that:

- **A captured hang shows the geometry never degenerating.** `probe.lua` logs
  the emulated screen size once a second; across a hung boot it reads
  `1288x1024` for all 180 samples, straight through the blackout and to the end.
  The screen is black while `set_size()` is perfectly healthy.
- **The patched binary hangs too.** In a 60-trial controlled A/B (control and
  treatment built from one tree, differing only in this patch) the treatment
  cell produced a hang with the identical signature — black at emulated t=59,
  geometry constant, emulated clock still advancing.

So the blackness is somewhere else in the pixel path (framebuffer contents, CMAP
palette, or XMAP mode entries) or in the guest's X server itself, and the
`REG0`/`RAMW` evidence — while real — does not explain it. **The patch is NOT
promoted to the production MAME build.** The boot watchdog remains the
mitigation, and it is what actually keeps a visitor from seeing a black station.

What a hung boot does look like, consistently: the blackout lands in a very tight
emulated window (t=59–62 across all four captured hangs, i.e. the console→X
handover), the emulated clock keeps advancing afterwards, and the geometry stays
correct. A healthy boot passes through the same blackout as a ~10 s transient.

### `PANIC: bad istack` — the MC's DMA page-table mask (issue #43, FIXED 2026-08-02)

```
PANIC: bad istack sp:8835afa8
Dumping to /hw/node/io/gio/hpc/scsi_ctlr/0/target/1/lun/0/disk/partition/1/block
```

This killed the live exhibit: a visitor opening Toolchest → Help → "Welcome to
SGI" (which launches Netscape) got a dead guest ~40 s later, and the station stayed
dead until someone restarted it. The stack pointer is byte-identical across every
sighting, days apart, on different images.

**Root cause: `sgi_mc_device::dma_translate()` masks the DMA page-table base to
16 bits where the PTE two lines below uses 20.** `(entry_lo & 0x003fffc0) << 6`
spans address bits 12..27, so the page-table base saturates at `0x0fffffff`.
IP24 main memory starts at physical `0x0800'0000`, which makes the mask a no-op
for any machine with **≤ 128 MB** — and wrong for the upper half of a 256 MB one.

Instrumented on a live boot: IRIX put a DMA page table at physical **`0x17de7000`**
(`entry_lo 0x005f79c2`) and MAME read it from **`0x07de7000`** — *below the start
of RAM*, i.e. unmapped. The garbage PTEs that come back send the DMA engine's
reads and writes to arbitrary physical addresses, scribbling on kernel memory
until something structural gives. Same code path every time ⇒ same `sp` every
time.

**So the trigger was our own `mame-indy-256mb-ram.patch`** exposing a latent
upstream bug that nobody upstream would ever meet: stock MAME ships this machine
with 16 MB. The bug is in MAME 0.288 and unchanged in 0.289 and on master.

A run that does *not* panic is not healthy either — it just corrupted something
less load-bearing. Both surviving 256 MB controls rendered a visibly **garbled
Netscape window** (missing toolbars, shredded text); with the fix the same page
renders pixel-perfect. Evidence PNGs: `/data/vms/sandbox/irix-panic/results/`
(`ctl4.final.png`, `ctl6.final.png` vs `mcfix1.final.png`).

Reading the panic message pays off, and two numbers in it are traps:

- `0x8835afa8` is kseg0 ⇒ **physical `0x0835afa8`**, and IP24 main memory starts
  at physical `0x0800'0000` — so it is 3.35 MiB into RAM, an ordinary kernel
  address that exists in the stock 16 MB machine too. It is **not** evidence
  against the 256 MB patch.
- The kernel's interrupt stack is `intstack` at `0x882ee3b0`, 8 KiB
  (`intstacksize`), and the panic string lives in `exception_exit.s`. All of that
  is readable straight out of `/unix` on a mounted CHD with
  `nm`/`objdump -m mips` (install `binutils-multiarch`) — no boot required.

**Fix**: `scripts/build-guests/patches/mame-mc-dma-ptbase-mask.patch` — one mask,
`0x003fffc0` → `0x03ffffc0`, making the page-table base decode identically to the
PTE field beside it. Worth upstreaming.

**Evidence** (namespaced clones of seed v3, cold boot + scripted login + the
same Toolchest → Help → "Welcome to SGI" trigger, classified from real
framebuffer grabs):

| arm | result |
|---|---|
| 256 MB, the shipped binary | **PANIC 9/11**; the 2 survivors rendered a corrupted window |
| 256 MB + this patch | **no panic, correct rendering** |
| 192 MB / 128 MB / 64 MB / 16 MB | no panic |
| `-nodrc`, 256 MB | inconclusive — the interpreter never reached the panic point in the window |

**Ruled out by experiment, not by argument**: the DRC code-cache patch and the
whole newer patch stack (`sgi.prev-a33944d3`, which predates shm/dirty-frame/
ds1386, panics identically), `MIPS3DRC_STRICT_VERIFY`,
`MIPS3DRC_COMPATIBLE_OPTIONS`, and MAME 0.289 (only 13 commits after our base,
none of them touching `cpu/mips`, `bus/gio64` or `mame/sgi` — checked by git
ancestry, so the upgrade is irrelevant to this bug).

One **genuine, unrelated MAME bug** was found on the way and is worth reporting
upstream: the software-interrupt check in `mips3drc.cpp`'s
`generate_update_cycles()` omits the `Status.IE` / `EXL` / `ERL` guards that both
the interpreter (`set_cop0_reg(COP0_Cause)`) and the DRC's own full-interrupt
check apply. Adding them was built and tested here and changed nothing, so it is
**not** carried in the station's patch stack.

Reproduction rig (kept, and cheap — ~10 min per trial):
`/data/vms/sandbox/irix-panic/` — `trial2.sh` (boot → login → trigger →
classify), `retrig.sh` (re-trigger an already-parked desktop), `pt.py`
(closed-loop MOVEP pointer on MAME snapshots). Two harness lessons are baked in:
a mis-aimed press must never score as a survival (hence `pt.py menuopen`
confirming the menu is posted before the release), and "no panic within N
seconds" is not a survival either — an arm can sit on the busy cursor the whole
window and never reach the panic point, so the pass condition is the **Netscape
window actually rendering** (`mean > 0.65 && sd > 0.22`), and anything else is
reported as `SLOW`.

`irix-park-desktop.sh` also waits for **both** a readiness check (the login
signature holding still for 3 consecutive samples) **and** a `--settle` floor
(`IRIX_PARK_SETTLE`, default 120 s) before typing, because the other observed
sighting was during login. That is cheap insurance and it stays.

### Liveness watchdog — the safety net behind the fix

`x11-runtime.sh --livewatch` (own pidfile `livewatch.pid`, same log and
generation token as the boot watchdog) exists so that no *future* guest-side
death needs a human to notice it. It is deliberately **not** a picture
classifier: frame statistics cannot separate "dead" from "idle" (a bare 4Dwm
desktop with no visitor is byte-static too, and this exhibit has already been
burned once by a mean/stddev classifier calling healthy logins panics).

Instead it is an **active probe**. When the framebuffer signature has not changed
for `IRIX_LIVE_STATIC_HITS` samples — i.e. nobody is interacting — it nudges the
pointer `IRIX_LIVE_NUDGE` counts and back through the *same command file a
visitor's mouse uses*, and looks again. A live guest redraws the cursor; a dead
one does not. That covers the input path end to end (streamhost → command file →
Lua agent → emulated PS/2), so a dead agent trips it too. Anything ambiguous —
including a failed sample — counts as alive. Two consecutive failed probes
relaunch MAME, bounded by `IRIX_LIVE_ATTEMPTS` (3) and gated on the same
`bootwatch.gen` token and `systemctl is-active` check as the boot watchdog, so it
can never fight a teardown. `stop-station-x11.sh` kills it before MAME.

`fbstat.py --sig` prints the frame signature the shm path uses for this;
`identify -format '%#'` is the x11 equivalent.

**But a reported "5 panics out of 5 boots" against that script was not panics at
all — it was a bug in the script's own detector**, and the lesson generalises.
After a successful login the X root paints SGI blue and sits there for
**minutes** before 4Dwm draws the Toolchest, and across that transition the
full-frame statistics barely move:

| state | full mean | full sd | Toolchest-crop sd |
|---|---|---|---|
| boot console | 0.515–0.526 | 0.211–0.219 | 0.079 |
| PROM / early | 0.595 | 0.202 | 0.079 |
| iconlogin chooser | 0.654–0.662 | 0.222–0.231 | 0.095 |
| **bare X root** (logged in, session starting) | **0.578** | **0.157** | **0.095** |
| **4Dwm desktop** (ready) | **0.580** | **0.163** | **0.257** |

Full-frame mean and stddev cannot separate the last two. The old detector called
anything with `sd > 0.15` a console/panic screen — which matches the bare root —
and it tested that *before* the desktop check. So every healthy login was
reported as a guest panic, with a screenshot of a perfectly good session offered
as the evidence, and the script killed working boots. It blocked two other
workstreams for a day.

Fixes: the desktop test is now **content-based** — crop the Toolchest region
(`130x230+0+30`) and require real contrast there, 0.095 vs 0.257 being a 2.7x
separation — and desktop is checked *before* console. The console/panic test is
bounded (`mean < 0.62 && sd > 0.19`) so it cannot overlap the bare root, the
desktop, or the login panel. Validated against real captured frames of every
state above: each gets exactly one label, and the bare root correctly gets none
(i.e. "keep waiting").

**Standing lesson for this exhibit:** a whole-frame mean/stddev is good for "is
it black" and nothing else. Anything that has to tell two *populated* screens
apart must look at a region that actually differs. The same caution applies to
the boot watchdog — which is why that one only ever tests for pure black.

Telling the failure modes apart from a framebuffer grab:

| mode | framebuffer | emulated clock |
|---|---|---|
| black-screen hang | pure black, mean 0 | still advancing |
| `bad istack` panic | console text, mean < 0.62, sd > 0.19 | still advancing |
| MAME DRC segfault | MAME process is gone | stopped |

**The production station does not auto-login at all** — `x11-runtime.sh` boots to
the chooser and stops, so the exhibit cannot panic itself this way. The
boot-trial rig (`trial.sh` + `probe.lua`) contains zero input code, so the
hang-rate measurements are unaffected by either the panic or this bug.

## Guest networking — a host-only /30, and what it opened up (2026-08-03)

The exhibit had no guest networking: `hinv` saw the Indy's Ethernet
(*"Integral Ethernet: ec0, version 1"*) but MAME bound no host interface to it,
so IRIX booted saying *"IRIS's Internet address is the default. Using standalone
network mode."*  It now has a **host-only point-to-point link** — and nothing
else, deliberately.

### MAME's SEEQ 80C03 really does pass packets

This was the first thing to establish, because imperfect emulation is the norm.
It is not a stub: `seeq8003_device` inherits `device_network_interface` and
`edlc.cpp` implements `recv_start_cb`/`send_complete_cb`.

Measured, on `indy_4610` with `-networkprovider taptun`:

- **Guest → host, unprompted, during boot.** The very first frame on the tap is
  IRIX's own gratuitous ARP for its unconfigured default address:
  `08:00:69:12:34:56 > ff:ff:ff:ff:ff:ff, ARP Request who-has 192.0.2.1 tell
  192.0.2.1`. The source MAC is the PROM `eaddr`, i.e. the guest's own stack put
  it there. Nothing host-side was configured yet.
- **Host → guest and back**: `ping -c 4 172.31.20.2` from the host → 4/4,
  `ttl=255`, 1.1–3.1 ms after the first (30 ms) packet, and
  `ip neigh` resolved `172.31.20.2 lladdr 08:00:69:12:34:56 REACHABLE`.
- **Guest → host**, from a winterm on the real framebuffer: `ping -c 4
  172.31.20.1` → *"4 packets transmitted, 4 packets received, 0.0% packet loss"*,
  0.365–0.831 ms.
- **TCP carries a full session.** A telnet login as `root` (empty password) gives
  a shell; `uname -aR; id` returned `IRIX IRIS 6.5 6.5.22f 10070055 IP22` /
  `uid=0(root) gid=0(sys)` with a real exit code, **in 5.4 s end to end**. A
  multi-kilobyte here-document (the capture script) was pushed over the same
  session without corruption.

So the emulation is good enough for real work, not just for link-up.

### How the host interface is selected with NO UI

`-networkprovider taptun` only enables the provider. The **binding** —
which host device a given emulated NIC opens — normally lives in MAME's internal
"Network Devices" UI, and this station runs `-video none`: there is no UI at all.

The binding is persisted in the machine cfg file, and the load path is a **real
apply**, not a round-trip:

```
network_manager::config_load()            # src/emu/network.cpp
  -> for each <device> under <system><network>
       network.set_interface(node->get_attribute_int("interface", 0))
       network.set_mac(...)
```

`set_interface()` calls `osd().open_network_device(id, *this)` and starts the
device. That is worth stating explicitly because the obvious analogy is the trap
this station already hit once: `DEVICE_INPUT_DEFAULTS` in a cfg silently
round-trips its values back into the file and applies nothing unless the mask
matches exactly (see the 256 MB RAM patch). The network path is not like that —
but it was still verified from inside the guest (`ifconfig ec0` UP/RUNNING,
packets on the wire), never by reading the cfg back.

So `x11-runtime.sh` **seeds** the cfg before every launch, exactly as it re-seeds
the nvram directory and for the same reason (MAME rewrites it on a clean exit,
and this is deliberate state that must not drift):

```xml
<?xml version="1.0"?>
<mameconfig version="10">
    <system name="indy_4610">
        <network>
            <device tag=":edlc" interface="0" mac="08:00:69:12:34:56" />
        </network>
    </system>
</mameconfig>
```

- `version="10"` must equal `CONFIG_VERSION` (`src/emu/config.h`) or the whole
  file is discarded with a warning.
- `tag=":edlc"` is the device tag from `indy_indigo2.cpp` (`SEEQ80C03(config,
  m_edlc)` with the finder `m_edlc(*this, "edlc")` on the machine root).
- `interface="0"` is the index into the provider's device list. On Linux MAME's
  taptun module publishes exactly **one** device (`m_devices.emplace_back({"tap",
  "TUN/TAP Device"})`), so 0 is the only valid value and `-listnetwork` showing
  one entry is not a coincidence.

### `mame-taptun-ifname-env.patch` — because upstream has one global tap

The Linux taptun device does **not** use the name it is handed; it hardcodes

```c
sprintf(ifr.ifr_name, "tap-mess-%d-0", getuid());
```

MAME runs as root here, so every MAME process on labhost would compete for the
single interface `tap-mess-0-0` — the live station and any clone experiment beside
it. `scripts/build-guests/patches/mame-taptun-ifname-env.patch` adds
`MAME_TAP_IFNAME`; unset, upstream behaviour is unchanged, so it is inert for
every other MAME use. The station passes `irixtap0`.

⚠ **The patch has to be IN the binary you run.** The shipped asset
`/data/vms/streamhost/assets/irix/mame/sgi` was built without it for several
generations, and the symptom is not an error: MAME opens `tap-mess-0-0`, finds
nothing there, logs `Network interface 0 not found` in its own log and runs on
with no networking. That silence is what cost a measurement campaign its
concurrent workloads — three agents' MAMEs all wanted the one interface.
Check a binary offline with `strings -a sgi | grep MAME_TAP_IFNAME`, and check a
running one with the carrier test `x11-runtime.sh` already prints (a tap has no
carrier until a process opens it).

### Slot allocation — `tapnet.sh claim`, and why `mkdir` is the allocator

A per-clone tap is only useful if two agents starting at the same instant cannot
choose the same one. `tapnet.sh claim <tag>` allocates a **slot**, and the
allocation is a single `mkdir` under `/run/irix-taps/<slot>`: it either creates
the directory or fails, atomically, for exactly one caller. A check-then-create
("is `irixtap3` free? then make it") has a window between the check and the
create, and that window is the whole bug.

Slot N is `irixtapN` on the /30 at `172.31.20.(4N)` — host `.(4N+1)`, guest
`.(4N+2)` — so slot 0 *is* the production station's historical `irixtap0` /
`172.31.20.1` / `172.31.20.2`, and `claim` never hands slot 0 out. Nothing about
the station's own path changes: it still calls `tapnet.sh up irixtap0 …` with fixed
arguments and never claims anything.

```
eval "$(tapnet.sh claim myrig)"   # -> IRIX_TAP_SLOT/_IF/_HOST_CIDR/_GUEST_IP, tap up
tapnet.sh slots                   # what is claimed, and whether the owner still lives
tapnet.sh release "$IRIX_TAP_SLOT"   # tap down, rules removed, slot free
tapnet.sh gc                      # reap slots whose owner process is gone
```

Two properties worth keeping when this is touched:

- **The iptables chains are named per INTERFACE** (`IRIXNET-FWD-irixtap3`). The
  older shared `IRIXNET-FWD`/`IRIXNET-IN` pair was rebuilt from empty on every
  `up`, so a second clone coming up **deleted the first clone's FORWARD drops** —
  a concurrency bug that quietly weakened the isolation rather than breaking
  anything visible.
- **Every iptables call waits for the xtables lock (`-w`) and the result is read
  back** (`verify_rules`). Without the wait, concurrent `up`s lose the lock and
  the individual rule commands fail; the tap then came up with **no** fail-closed
  rules while the script still printed `up: … (host-only …)`. Measured, not
  theoretical: 8 simultaneous claims produced exactly that. `up` now refuses —
  it puts the link back DOWN and exits non-zero — unless the kernel agrees the
  isolation is in place.

`tests/tapnet-claim-selftest.sh` (root, on labhost) proves all of it — the
distinct-slot property, the complete-ruleset property, slot-0 protection,
release and `gc` — in its own `tnst*` / `172.31.29.0` range, so it is safe to run
beside live clones.

A guest renumbered onto a slot's /30 has to be told: the seeds capture
`172.31.20.2`. Bootstrap a clone on the `.0/30`, telnet in, and
`ifconfig ec0 inet <slot guest> netmask 0xfffffffc up` (detached — the address
change drops the session that asked for it), then re-run `tapnet.sh up` with the
slot's addresses. Bind that telnet **to the interface** (`SO_BINDTODEVICE`): if
another rig is holding the bootstrap /30 at the same moment, a route-chosen
socket lands in the wrong guest.

### Isolation — what is and is not reachable

The guest is IRIX 6.5 from 2003. `netstat -an` on it lists **30+ listeners**,
all bound to `*`: telnet, ftp, finger, `exec`/`login`/`shell` (512-514),
portmapper, printer, `echo`/`discard`/`daytime`/`chargen`/`time`, PCP on 4321,
X11 on 6000 — and an httpd on 80. Its own `/etc/hosts` says, in a shipped SGI
comment, that `root, lp, nuucp, EZsetup, demos, OutOfBox, guest` have **no
passwords**. Anything that can reach this machine owns it. The containment is
therefore not a formality, and it is built in three independent layers so that
any one of them failing is not sufficient.

`streamhost/stations/irix/tapnet.sh` (run by `x11-runtime.sh` on **every** launch,
which is what makes it survive a relaunch and a host reboot with no extra unit):

1. **Topology.** A persistent tap `irixtap0`, host `172.31.20.1/30`, guest
   `172.31.20.2`. Not enslaved to `vmbr0` — and `tapnet.sh` refuses to run at all
   if it ever finds the interface with a bridge master, rather than silently
   fixing it. The guest is given **no default route and no gateway**: the /30 is
   the entire network it can see.
2. **Routing.** `net.ipv4.conf.irixtap0.forwarding=0`, so the kernel will not
   route a packet that arrives on the tap even if the guest invents a route.
   Redirects off, `rp_filter` on, IPv6 disabled on the interface.
3. **Filter.** Fail-closed rules in the station's own chains, so nothing here can be
   confused with another agent's rules:

   ```
   -A IRIXNET-FWD-irixtap0 -i irixtap0 -j DROP      # hooked first in FORWARD
   -A IRIXNET-FWD-irixtap0 -o irixtap0 -j DROP
   -A IRIXNET-IN-irixtap0 -s 172.31.20.2 -d 172.31.20.1 -j RETURN  # in INPUT
   -A IRIXNET-IN-irixtap0 -j DROP
   ```

   The INPUT pair is the one that is easy to leave out: without it the guest
   could address the host's **own LAN IP** (192.0.2.10) the moment anything
   gave it a route, and that is host-local traffic, not forwarded traffic, so no
   FORWARD rule would ever see it.

**Reachable:** guest ⇄ `172.31.20.1` (this host), any protocol.
**Not reachable:** the LAN (192.0.2.0/24, including this host's own LAN
address), the internet, any other guest, and any IPv6 at all. There is no NAT
anywhere, and labhost's global `ip_forward=1` (Proxmox sets it) is deliberately
*not* relied on being 0 — that is what layers 2 and 3 are for.

### The `chkconfig` audit — two root web servers, not one

The boot warning in issue terms was one line:

```
Warning:  Internet Gateway web server running as root.
          Use "chkconfig webface_apache off" to disable.
```

`chkconfig` showed a second one beside it. **Turned off in the seed:**

| service | why |
|---|---|
| `webface_apache` | the warning itself: an httpd running **as root** on :80 for nobody |
| `sgi_apache` | the *other* root web server on the same machine — same finding, and it would have survived a fix aimed only at the warning |
| `routed` | RIP: it would both advertise and, worse, **accept** routes on a link whose entire purpose is to be a dead end |

**Found and deliberately left alone** (listed, not disabled — each is a
behaviour change on a live exhibit and none is load-bearing for the isolation):

| service | what it costs |
|---|---|
| `sendmail` + `sendmail_cf` | a 2003 MTA running at boot; historically the worst remote surface on this OS. Nothing sends mail here. Off would save a daemon and some boot time. |
| `timed` | time daemon; elects a master by broadcast. Useless on a /30 with one peer. |
| `pmcd` (+ `pmie` off) | Performance Co-Pilot collector, listening on 4321. |
| `tfxd`, `sdpd`, `snetd`, `rtmond` | SGI desktop/graphics side daemons. Cheap, and some are wired into the Indigo Magic session — not worth risking the desktop for. |
| `lp`, `mediad`, `savecore`, `soundscheme`, `xlv`, `nsd`, `privileges`, `ipaliases` | ordinary IRIX plumbing; `nsd` in particular is what resolves the hostname the network script needs. |
| inetd's `echo`/`discard`/`daytime`/`chargen`/`time`, `finger`, `rexec`/`rlogin`/`rsh`, `ftp` | pure attack surface, but only from the tap — and `telnet` from that same inetd is the exec channel below. Trimming `/etc/inetd.conf` is the obvious next step if the channel moves to something narrower. |

Not touched, and worth naming: **the empty passwords stay**. The exhibit is a
museum piece where a visitor logs in as `root` with no password, and that is the
period-correct behaviour the station exists to show. It is only safe because of the
isolation above, which is the whole argument for building the isolation first.

### An exec channel over TCP — and how it compares to the serial one

`telnet` + the already-running inetd gives **captured stdout and a real exit
code in ~5 s**, plus file push, with no in-guest agent to build, capture or keep
alive:

```
$ python3 gtel.py 172.31.20.2 root "uname -aR; id"
IRIX IRIS 6.5 6.5.22f 10070055 IP22
uid=0(root) gid=0(sys)
XX_DONE_0
```

Against the serial agent being built in parallel, on the evidence here:

- **Nothing has to be installed in the guest.** inetd, telnetd and ftpd are
  already running on the shipped seed; the only guest-side change networking
  needed was three lines of config.
- **Bandwidth and latency are not a consideration** — a 3 KB script pushed as a
  here-document arrived intact and the round trip is milliseconds, where a
  9600-baud console is ~1 KB/s and shares the console with boot messages.
- **It survives a seed recapture trivially** (it is config, not a binary), and it
  does not consume the emulated serial port.
- **What it does not do**: it is dead until IRIX has finished booting and
  `rc2` has started inetd, whereas a serial console is attached from the PROM
  prompt onward and can see and drive a boot, a single-user shell, and a panic.
  That is a real capability gap, not a small one.

So they are complementary rather than competing: **serial for boot/PROM/recovery,
TCP for everything after `The system is coming up.`** If only one gets built out,
TCP is the one that answers `labctl exec irix "<cmd>"` today.

Two IRIX-specific traps for anything scripting that channel:

- root's login shell is **csh**, so `RC=$?` is a syntax error (*"Variable
  syntax"*). Drop into `/bin/sh` first.
- `ftpd` refuses root (`/etc/ftpusers`), so file push goes over the telnet
  session as a quoted here-document, not over FTP.

### The guest-side configuration, and why it is only three lines

`/etc/init.d/network` decides everything from **one lookup**: `netif.options`
leaves `if1addr=$HOSTNAME` at its default, so the primary interface's address is
whatever `/etc/hosts` says the hostname is. As shipped that is SGI's placeholder
`192.0.2.1  IRIS`, and the script's `netstate=loopback` branch then prints the
standalone-mode line and `ifconfig`s the interface **down** again. So:

| change | effect |
|---|---|
| `/etc/hosts`: `192.0.2.1 IRIS` → `172.31.20.2 IRIS` (+ a `172.31.20.1 labhost` entry) | the interface configures itself at boot; the standalone message is gone |
| `/etc/config/ifconfig-1.options`: `netmask 0xfffffffc` | without it the address is treated as classful (`0xffff0000`) and the guest ARPs for 172.31.x.x hosts that do not exist |
| `chkconfig network on` (already on), `routed off`, no `static-route.options` | no default route, no route daemon |

No `ifconfig` anywhere in a startup script, and nothing host-side pokes the
guest: on a verification boot the guest answers a ping with no manual step at
all.

### Verified on the exact artifact, and the cutover that is still owed

`irix65-apps-v5.chd`, md5 `b8a20bbe27593889995ab57978ca75ae`,
2,241,568,768 bytes — v3 plus the three config lines above and the three
`chkconfig` changes. Built by booting a v3 clone, bringing `ec0` up by hand once
through the GUI console, pushing `scripts/build-guests/irix/irix-net-bake.sh` over
telnet, and halting with `/etc/shutdown -y -g0 -i0` (framebuffer confirmed at
*"Okay to power off the system now"*, so no torn files).

**Three cold boots from independent `cp --reflink` clones of the staged file**,
each proving the whole chain with nothing configured by hand:

| boot | ping answered at | evidence |
|---|---|---|
| v5a | t=52 s | `ifconfig ec0` UP/RUNNING 172.31.20.2/0xfffffffc; `netstat -rn` shows the /30 and **no default route**; `chkconfig` shows both apaches and `routed` off; `ps -ef` matches no `httpd` and no `routed` |
| v5b | t=33 s | identical, on a different core pair |
| v5c | t=51 s | run after `tapnet.sh down` had deleted the tap *and* the iptables chains — the launcher rebuilt all of it, which is the host-reboot case |

The boot console frame (`v5a/frames/f006.png`) reads `IRIX Release 6.5 … The
system is coming up.` followed only by the `esp chkconfig flag is off` line:
**no Apache warning and no standalone-network line.**

Isolation was tested adversarially on a live clone, not argued:

| from the guest | result |
|---|---|
| `ping 192.0.2.1` / `192.0.2.10` / `8.8.8.8` | `sendto: Network is unreachable` — no route exists |
| **after `route add default 172.31.20.1`** | still 100% loss to all three, and the host's `IRIXNET-IN` chain counted the drops (`3 packets`) — the packets aimed at the host's own LAN address are the ones only that chain stops |
| `ping 172.31.20.1` throughout | 0.0% loss |

**Not switched on the live station.** `IRIX_GOLDEN` still defaults to v3 and the
production MAME binary is unchanged. The cutover is three coordinated moves,
and doing fewer than all three is the failure mode to avoid:

1. **MAME binary** — staged as
   `/data/vms/streamhost/assets/irix/mame/sgi.taptun-e513fbb6` (md5
   `e513fbb69299ae56a0db70ad2adba636`; the live stack + `mame-taptun-ifname-env
   .patch`). Promote it to `mame/sgi`, keeping the current one as
   `sgi.prev-0db27300`.
2. **Seed** — `IRIX_GOLDEN=/data/vms/streamhost/assets/irix/irix65-apps-v5.chd`
   (already staged, 444 + `chattr +i`).
3. **Station files** — re-emit so `tapnet.sh` and the `IRIX_NET=on` fixture reach
   the station dir, then restart `streamhost@irix`.

Getting (3) without (1) is not dangerous but is silent-ish: an unpatched MAME
ignores `MAME_TAP_IFNAME`, opens upstream's `tap-mess-0-0`, finds nothing and
runs on with no networking. That is exactly why `start_mame()` checks
`/sys/class/net/<tap>/carrier` after launch and says so out loud — verified by
launching the staged seed against the *unpatched live binary* and watching the
warning fire.

Rollback at any point is `IRIX_NET=off` in `station.env`: not one MAME argument
changes and the tap is never created.

## Outbound networking — the guest dials out, nothing dials in (2026-08-03)

> **SUPERSEDED 2026-08-24 — this chapter is the ROLLBACK, not what ships.**
> The station now runs `IRIX_NET_MODE=retronet`: its NIC is a bridge port on
> `vmbr-rn`, the offline retronet, where the guest is `10.99.0.24/24` with no
> default route and reaches the gateway `10.99.0.2` — and nothing else, in
> either direction. **There is no path to the LAN or the internet any more**,
> so every "guest → internet" row below describes the *other* mode.
> Everything here still applies verbatim under `IRIX_NET_MODE=sandbox`, which
> is why it is kept: golden and mode are one combination, and rolling back to
> the internet exhibit means this chapter plus the v9 seed.
> See [`../lab/retronet/WEB-STATION-irix.md`](../lab/retronet/WEB-STATION-irix.md).


The section above ends with a guest that can reach exactly one address. The user
then asked for the rest of it, explicitly: **telnet to a remote box, ping other
hosts, and browse HTTP sites.** All three now work, and the isolation that
mattered is still there, because the two are not the same property.

The risk this exhibit carries has never been the guest reaching outward. It is
the guest **being reachable**: IRIX 6.5 with 30+ listeners bound to `*`, root-owned
daemons, and seven accounts with no passwords. So the design is
**outbound-only NAT**: the guest may OPEN a connection to anything; nothing may
open one to it. That gives the user everything asked for and gives up nothing
worth keeping — "ping out, telnet out, browse out" needs no inbound
reachability at all.

### The switch, and what each side of it does

`IRIX_NET_EGRESS` (default `off`) in `station.env`, passed through
`x11-runtime.sh` to `tapnet.sh`, which is where the rules live:

| | `off` — sandbox (unchanged) | `on` — egress |
|---|---|---|
| guest → host end `172.31.20.1` | yes | yes |
| guest → LAN, internet | **no** (`Network is unreachable`, and dropped even if a route is invented) | **yes**, masqueraded out of the host's default-route interface |
| guest → the host's own LAN address `192.0.2.10` | **no** | **no** — `IRIXNET-IN` still drops it |
| anything → guest | **no** | **no** — no DNAT, no port forward, no inbound `NEW` |
| forwarding | `net.ipv4.conf.<tap>.forwarding=0` | `=1` on the tap and the uplink **only**; labhost's global `ip_forward` is neither read nor written |

The rules, in this station's own chains so nothing here collides with another
agent's (`iptables -S` on labhost, egress mode):

```
-A IRIXNET-FWD -s 172.31.20.2/32 -i irixtap0 -o vmbr0 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT
-A IRIXNET-FWD -d 172.31.20.2/32 -i vmbr0 -o irixtap0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A IRIXNET-FWD -i irixtap0 -j DROP
-A IRIXNET-FWD -o irixtap0 -j DROP
-A IRIXNET-IN  -s 172.31.20.2 -d 172.31.20.1 -j RETURN
-A IRIXNET-IN  -j DROP
-A IRIXNET-NAT -s 172.31.20.2/32 -o vmbr0 -j MASQUERADE     # nat/POSTROUTING
```

**The asymmetry between the first two lines IS the security property.** `NEW` is
accepted only in the guest→uplink direction, so a TCP connection or a UDP flow
can only ever be *started* by the guest. Add to that: the guest's address is
RFC1918 space behind a masquerade with no inbound rule, so there is no packet a
LAN host can send that arrives at it; and the host's own LAN address stays
unreachable from the guest, which is host-local traffic that no FORWARD rule
would ever see. `$WAN` is resolved from the routing table rather than hardcoded,
so the masquerade follows the host's default route if it ever moves.

**What is exposed now, in one sentence:** the guest can talk to your LAN and the
internet, so treat it as an untrusted machine *on* your LAN for the purposes of
what it might do outward (it is a 2003 OS a visitor has root on); nothing can
connect *to* it, which is the exposure that would actually matter.

### The guest side — three files, all in the seed

Captured by `scripts/build-guests/irix/irix-net-egress-bake.sh` on top of v5, because
a runtime hack would not survive a recapture:

| file | why |
|---|---|
| `/etc/config/static-route.options` — `${ROUTE:-/usr/etc/route} ${QUIET:--q} add default 172.31.20.1` | `/etc/init.d/network` **sources** this file after the interface is up and before any routing daemon; `routed` stays off |
| `/etc/resolv.conf` — `1.1.1.1`, `9.9.9.9`, `retrans 1000`, `retry 1` | see below: the timeouts are the load-bearing part, not the servers |
| `/etc/nsswitch.conf` — `hosts: files dns` (was `nis dns files`) | nsd's shipped order consults **NIS first** on a machine with no NIS domain. It happens to fail fast, but "ask a service we do not use, first, on a live network" is not a thing to leave in |

A seed carrying a default route is **not** a seed that has been opened up:
with the host in sandbox mode the route exists and the packets still die in the
host's chains — that exact case was tested adversarially (see the table in the
previous section). Keeping the guest identical across both host modes is what
makes `IRIX_NET_EGRESS` the single reviewable switch.

### DNS, and the failure mode that presents as a frozen application

Tested explicitly, because a guest that **blocks** on a dead resolver looks to a
visitor like a hung machine, and that is a worse exhibit bug than one that fails:

| case | result |
|---|---|
| forward lookup, egress on | `nslookup example.com` → `104.20.23.154, 172.66.147.243` |
| reverse lookup, egress on | `ping 1.1.1.1` prints `PING one.one.one.one` |
| **NXDOMAIN** | `Non-recoverable failure in name resolution` — **same second**, no stall |
| no resolver at all (the pre-capture v5 state) | also instant; the `netstate=loopback` guest never gets as far as a query |
| `retrans 1000 retry 1` | bounds a doomed lookup at ~2 s (2 servers × 1 try) — this is what the sandbox-mode case costs |

**One thing does hang, and it is worth knowing:** `nslookup` with no
`/etc/resolv.conf` picks server `0.0.0.0`, retries, and then drops into its
**interactive prompt** and sits there forever. It is the only stall found in the
whole sweep. It cannot bite the exhibit now (v6 ships a resolv.conf), but a
script that shells out to `nslookup` on a guest without one will wedge.

### The web — the proxy was built, and then dropped

Netscape Communicator **4.8a** (shipped in the seed, `versions -b`) speaks
SSL 2/3 and TLS 1.0 with 1990s ciphers and a root store that expired last
decade. Point it at the 2026 web with perfect connectivity and it reaches every
site and opens none of them. A host-side TLS-terminating proxy (`irixproxy.py`
on 172.31.20.1:8080, HTML de-modernised on the way through) solved that, was
verified on the framebuffer against live example.com and Wikipedia — and was
then **dropped by user decision on 2026-08-03.** It is not in the repo, not in
the launcher and not in `station.env`.

**What that means for the exhibit, stated plainly:** Netscape connects
directly. Plain `http://` works. `https://` fails at the handshake. That is the
accepted consequence, not a defect to file.

**The prefs had to move with it.** A seed left carrying
`network.proxy.type 1` pointing at a proxy nobody runs is strictly worse than
no proxy at all: every page load fails, including ones the browser could serve
itself. So `irix-net-egress-bake.sh` now writes `network.proxy.type 0` and
`browser.startup.page 0`, and the merged seed (below) was recaptured with them.
Anything still referencing 172.31.20.1:8080 is stale.

### Measured from inside the guest, on the exact staged artifact

`irix65-apps-v6.chd`, md5 `e5777f6e2a48edf5831e13ca0233075a`, 2,241,626,112
bytes — v5 plus the three guest files above. All captured stdout over the telnet
exec channel, with a framebuffer screendump beside it:

| from the guest | result |
|---|---|
| `ping 172.31.20.1` | 0.0% loss, ~0.6 ms (both modes) |
| `ping 1.1.1.1` | 0.0% loss, 2.6–4.7 ms, `ttl=57` |
| `ping 192.0.2.1` (LAN gateway) | 0.0% loss, 0.3–1.3 ms, `ttl=63` |
| `ping 192.0.2.10` (the host's own LAN address) | **100% loss** — `IRIXNET-IN` drops it, in both modes |
| `telnet telehack.com` | full interactive session: banner, command list, `help`, `exit` |
| `telnet 172.31.20.1 2323` (host-side test service) | prompted, answered per line, `QUIT` closed it |
| `ftp -n ftp.gnu.org` | anonymous login + `226 Directory send OK` full listing, via extended passive; `ftp` also prints one harmless `socket: Address family not supported` (its IPv6 attempt) |
| `nslookup example.com 1.1.1.1` | resolved, non-authoritative |
| Netscape → example.com, Wikipedia | rendered (framebuffer) |

Two IRIX quirks for anyone scripting this: `ftp` uses **EPSV**, so no
`nf_conntrack_ftp` helper is needed on the host; and root's shell is csh, so the
exec channel drops into `/bin/sh` first (as the previous section says).

### v7 — the merged seed, and what the station now ships (2026-08-03)

Two seeds had diverged from v3 and neither contained the other: **v4** carried
the serial exec agent, **v6** carried the egress guest config. `irix65-apps-v7.chd`
is the merge, **md5 `4f36d0b8d88e48ae02e40668b55d9a74`**, 2,241,626,112 bytes,
staged 444 + `chattr +i` beside the others.

How it was built (all of it reproducible from the repo, no hand editing):

1. `irix-serial-rig.sh boot v7bake --chd irix65-apps-v6.chd --console` — cold
   boot of **v6**, so every egress file is inherited rather than re-derived.
2. `irix-serial-install.sh v7bake` — pushes `irixagent.pl` + `irixagent.sh` down
   the console getty, adds the `ia:23:respawn:` inittab line, and proves it:
   agent banner **`irixser/2 2.0 076e`**, `cksum` matched on both files, exactly
   one agent process, guest `perl` flock OK.
3. The proxy prefs removed over the exec channel the install had just created —
   `/.netscape/preferences.js` rewritten to `network.proxy.type 0`,
   `browser.startup.page 0`. A `find / -name preferences.js` sweep confirms no
   other copy (`/.mozilla/…`, `/usr/demos/…`) mentions a proxy at all.
4. `irix-serial-rig.sh halt` — a real `shutdown -i0`, not a kill, so the
   filesystem is clean in the image.

**Verified by cold boot on a clone running the PRODUCTION launcher** — repo
`x11-runtime.sh`, `IRIX_CAPTURE=shm`, `-video none`, v7, `IRIX_NET=on`,
`IRIX_NET_EGRESS=on`, the `sgi.taptun-e513fbb6` binary, pinned to one core pair —
never the station service, which stayed stopped throughout:

| check | result |
|---|---|
| tap attach | `irixtap0` **carrier 1**, launcher printed `MAME is attached (guest 172.31.20.2)` |
| exec channel | `labctl`-equivalent `irixexec.py … "uname -a"` → `IRIX IRIS 6.5 10070055 IP22`, exit 0 |
| default route | `netstat -rn` → `default 172.31.20.1 UGS ec0`; `ec0` UP/RUNNING 172.31.20.2/0xfffffffc |
| host end of the /30 | `ping 172.31.20.1` 0.0% loss, 0.24–0.92 ms |
| LAN | `ping 192.0.2.1` 0.0% loss, ttl=63 |
| internet | `ping 1.1.1.1` 0.0% loss, 2.3–5.0 ms, ttl=57 |
| **the host's own LAN address** | `ping 192.0.2.10` **100% loss** — `IRIXNET-IN-irixtap0` drops it |
| DNS | `nslookup example.com` → `172.66.147.243, 104.20.23.154` |
| **doomed lookup** | NXDOMAIN answered in **2.33 s wall including exec overhead** — fails, does not hang |
| outbound telnet | `telnet telehack.com` — real session: banner, host count, command list |
| Netscape prefs | `network.proxy.type 0` — nothing points at 172.31.20.1:8080 |
| desktop | 4Dwm reached from the iconlogin chooser; framebuffer screendump, not log inference |

**Inbound stayed refused, re-tested adversarially** rather than argued from the
rule text — with the guest deliberately holding a default route and the host in
**egress** mode, from a real LAN machine (CT950, 192.0.2.11) TCP connects to
`172.31.20.2` on **23, 80, 111 and 7 all time out**, and the kernel's own
`ip route get` shows the packets leaving via the LAN gateway, which has no route
back. The forward chain is the reason it is structural rather than lucky: `NEW`
is accepted only `-i irixtap0 -o vmbr0`, the return direction is
`ESTABLISHED,RELATED` only, and both chains end in `DROP`.

### Cutover — what is installed, and the one move left

`tapnet.sh` was **absent from the station dir entirely** — networking was not wired
into the live station at all — and the station-dir `x11-runtime.sh` was behind the
repo. Both are now installed, along with `station.env` carrying `IRIX_NET=on`,
`IRIX_NET_EGRESS=on`, `IRIX_GOLDEN=…v7.chd` and `IRIX_MAME=…sgi.taptun-e513fbb6`.
The service stays **stopped**; nothing here starts it.

The one move deliberately NOT made at the time: **`mame/sgi` was not
overwritten.** The integration phase was building a single binary carrying the
PIT + cacheline patches, and promoting a binary it would immediately replace is
how two changes become one confusing rollback. `IRIX_MAME` pinned the station to
the staged taptun build until then.

**Closed the same day** — see
[the integration section](#the-integrated-binary-2026-08-03) below. `mame/sgi`
is now the combined build (which does carry `mame-taptun-ifname-env.patch`) and
the `IRIX_MAME` pin has been deleted from `station.env`.

### The chain names had to become per-interface, and that is a real bug fix

Mid-verification the adversarial test flipped: `ping 192.0.2.10` from the
guest, which had been 100% loss all afternoon, started answering in 0.4 ms. The
cause was not the egress design. `IRIXNET-IN` was a **shared** chain name, and a
second agent's rig on a second tap had run `tapnet.sh`, whose `install_rules`
FLUSHES its chains and whose `remove_rules` DELETES them. One rig's teardown
emptied the other rig's INPUT filter, packets fell through to `-P INPUT ACCEPT`,
and the guest could reach the host's LAN address.

Chains are now `IRIXNET-{FWD,IN,NAT}-<ifname>`, one set per tap, and the old
shared hook is removed on sight. Two lessons worth keeping: **a fail-closed rule
set that another process can flush is not fail-closed**, and the only reason
this was caught is that the adversarial test was re-run after an unrelated
change rather than trusted from the first pass. Re-running it restored 100%
loss immediately.

Two other multi-agent hazards seen the same afternoon: a sibling rig assigned
`172.31.20.1/30` as a **secondary address on its own tap**, so two interfaces
held the same host address (the guest kept working, but the routing is
ambiguous and this is worth checking with `ip -o addr | grep 172.31.20.1/30`
before trusting a result); and the guest address itself is captured into the seed
(`/etc/hosts`), so concurrent IRIX network rigs cannot simply pick different
/30s without a recapture.


### Compiler flags — measured, not adopted (2026-07-31)

After the 256 MB RAM patch and the Newport dirty-frame cache, **compiler flags
were the last unmeasured performance lever.** They were built and benchmarked
properly, and the answer is **no: neither `-march=native` nor LTO is worth
adopting.** The station keeps stock MAME flags. This question is closed — do not
re-open it without a new hypothesis about *why* the flags would help.

Build gotchas that cost real time to rediscover (all four are load-bearing):

- **`ARCHOPTS=…` is a silent no-op without `REGENIE=1`.** Genie does not
  regenerate the makefiles, make sees every `.o` as current, and the build
  "succeeds" in 20 seconds having compiled nothing.
- **`REGENIE=1` then fails on `qmake6: not found`** (Qt debugger) — add
  `USE_QTDEBUG=0`.
- **Deleting only `*.o` leaves a stale precompiled header** that hard-fails the
  build (`one or more PCH files were found, but they were invalid`).
  `build/linux_gcc` must be removed *entirely*.
- **MAME already builds at `-O3`**, so `-O3` is not the experiment.

Flags were verified to have actually reached the compiler, not merely been
passed to make: the native binary contains **12,968 AVX-512 instructions and
104,749 `%ymm` operands, versus 0 and 13 in the control** (`-march=native`
resolves to `-march=skylake-avx512` on this Xeon D-2146NT). Both flag builds
also produce a **byte-identical framebuffer** to the control at emulated
t=260 s (the `iconlogin` chooser), so they are functionally correct.

Method: interleaved A/B, 6 rounds per arm, all arms carrying identical source
patches so the only difference is flags. Speed is the cycle-normalised
`emulated_seconds / (cycles/2.5e9)` metric — MAME's own "Average speed %" swings
±8% with turbo wander and is unusable. `perf stat -I 1000` plus a Lua agent that
records the wall time at each emulated-time mark attributes **boot and idle
windows separately from within a single run**; differencing separate runs is
invalid because IRIX boot diverges from ~t=120 s (the RTC is seeded from the
host clock). The two regimes behave very differently — boot ~44% of real time,
idle ~159% — so a flag effect could easily have differed between them. It did
not.

Result, as within-round paired ratios against the generic-flags control (n=6;
median is the headline because a single perturbed round on this shared labhost moves
an arm's mean by >10%):

| arm | boot (emu 40–120 s) | transition (120–200 s) | idle (200–300 s) |
|---|---|---|---|
| control absolute | 44.3% ±2.2 | 108.6% ±3.1 | 158.7% ±3.5 |
| `-march=native` | −2.2% (mean −1.2 ±5.7) | −0.8% (mean +0.3 ±3.6) | −0.9% (mean −0.9 ±3.1) |
| `LTO=1` | +1.6% (mean +4.9 ±6.1) | −0.7% (mean −1.2 ±4.6) | −3.8% (mean −9.1 ±14.1) |

A second independent 6-round control-vs-native dataset agrees and the sign of
the idle delta flips between the two (−0.9% vs +0.2%), which is the signature of
a true zero. **Every measured effect is smaller than the run-to-run spread.**

This is the expected answer: the profile is **memory-bound, not
instruction-bound** — the dominant cost is Newport framebuffer scan-out
streaming ~15.7 MB/frame, which wider vector registers and cross-module
inlining cannot speed up. Note the IPC is ~1.5–1.65 in all three arms; the flags
changed the code substantially without changing how fast it retires.

LTO additionally costs a 191 MB binary (vs 80 MB) and a 48-minute build, so even
its statistically-indistinguishable boot-window result does not pay for itself.
A combined `-march=native` + LTO arm was deliberately **not** built: with both
individual effects measuring zero and the bottleneck off-core, there is no
mechanism by which the combination would win.

### Hugepages — measured, not adopted (2026-08-03)

The process has ~530 MB of extremely hot memory: 256 MB of emulated main memory
(two 128 MB SIMM banks, `mame-indy-256mb-ram.patch`) plus a 264 MB MIPS3 DRC
code cache (`mame-indy-drc-cache-256mb.patch`). Through 4 KiB pages that is
~131,000 pages, which looks like heavy dTLB and iTLB pressure. Backing both with
2 MiB transparent hugepages **works exactly as intended and is still not worth
adopting**: it halves TLB walks, but TLB walks are only ~2–3% of cycles on this
workload, so there is at most ~1% to recover. The station keeps 4 KiB pages.

**Baseline state matters and was established before claiming any delta.**
labhost is `transparent_hugepage/enabled = madvise`, `defrag = madvise`,
`shmem_enabled = never`. `/proc/<mame>/smaps` for the stock binary shows
`AnonHugePages: 0 kB` and `THPeligible: 0` on **every** hot mapping, so MAME
gets zero hugepages today. No host-wide setting was changed at any point during
the experiment — the arms are per-process `madvise()`, precisely so concurrent
work on labhost is not corrupted.

Two mechanism findings, both non-obvious:

- **The DRC code cache can never get a hugepage as MAME ships it.**
  `virtual_memory_allocation::do_alloc` (`src/osd/modules/lib/osdlib_unix.cpp`)
  maps the cache `MAP_ANON | MAP_SHARED`, which on Linux is a *shmem* mapping
  governed by `transparent_hugepage/shmem_enabled` — default `never`. It shows
  up in `smaps` as `/dev/zero (deleted) rwxs`. `MADV_HUGEPAGE` on it is ignored.
  Making it huge requires `MAP_PRIVATE` (semantically identical for a
  single-process code cache) plus 2 MiB alignment.
- **`MADV_HUGEPAGE` alone does nothing to guest RAM.** `sgi_mc_device` allocates
  each bank with `std::make_unique<u8[]>`, which value-initialises, so every page
  is already present as a 4 KiB page before any `madvise` can run, and
  `MADV_HUGEPAGE` only steers *future* faults. Following it with `MADV_DONTNEED`
  is the fix: private anonymous pages re-fault as zeroes — exactly the state
  value-initialisation left behind — and the re-faults arrive as 2 MiB pages.

With both applied, `smaps` confirms the mechanism took: DRC cache **262 MB of
264 MB** `AnonHugePages`, guest RAM **100% of resident pages** huge.

Method: one binary for all arms, selected at runtime by `IRIX_HUGEPAGE=off|ram|
drc|both`, so there is no code-layout confound between control and treatment.
Same within-run windowing harness as the compiler-flag experiment. Headline
figures are from a **12-round interleaved A/B on a quiesced labhost** (4 disjoint
core pairs; the only other emulator-class process was the standing
another co-located VM). An earlier 16-round dataset taken while labhost carried
~20 load average agrees on sign and mechanism but has 4× the spread, and its
first round — taken while the station shutdown was still draining — is discarded.

| window | control | `both` (paired median, n=12) | 95% CI | Wilcoxon p |
|---|---|---|---|---|
| boot/active (emu 40–120 s) | 64.9% | **+1.71%** | −1.5% … +4.2% | 0.117 |
| transition (120–200 s) | 132.2% | **+3.29%** | +0.8% … +5.9% | 0.013 |
| idle (200–300 s) | 156.0% | **+1.22%** | −0.7% … +2.2% | 0.062 |

The TLB counters are the reason this is a "no" rather than a "maybe", because
they bound the prize independently of the noisy wall-clock number:

| window | arm | dTLB walk % of cycles | iTLB walk % of cycles | walks/Kinstr (d / i) |
|---|---|---|---|---|
| boot | off | 1.78 | 1.15 | 0.080 / 0.105 |
| boot | both | 1.37 | 0.50 | 0.040 / 0.040 |
| idle | off | 1.93 | 0.25 | 0.050 / 0.020 |
| idle | both | 1.89 | 0.24 | 0.050 / 0.020 |

So hugepages **halve** the walk rate at boot — the mechanism is real and
confirmed — but total page-walk cycles only fall 2.93% → 1.87%, i.e. **1.06
points of cycles, worth ~+1.1% speed.** The measured boot delta (+1.71%) matches
that. At idle the walk cycles barely move (2.18% → 2.13%, ~0.05 points) and the
speed delta is correspondingly indistinguishable from zero. **Idle is the station's
actual operating regime, so the answer for the exhibit is: no effect.**

Attribution between the two allocations is clean and matches the hypothesis that
the code cache is the more interesting one: the `drc` arm alone takes iTLB walk
cycles 1.15% → 0.64% (the `ram` arm leaves them at 1.08%), while the `ram` arm
alone takes dTLB walk cycles 1.78% → 1.51%. The DRC cache is also read and
written as *data* during compilation, so it contributes to both.

Honest caveats, both flagged rather than buried: the transition and idle windows
show small positive deltas **larger than their TLB accounting explains** (+3.3%
measured vs +0.2% accounted; +1.2% vs +0.05%). That is either a second mechanism
(less page-table memory traffic, better DRAM row locality) or residual noise —
each of those two windows contains one outlier pair from an anomalously slow
control run. It is not evidence for hugepages beyond what the counters support.
And the `drc` arm changes `MAP_SHARED` → `MAP_PRIVATE`, so its delta strictly
mixes "private vs shmem mapping" with "2 MiB vs 4 KiB pages"; in steady state
both are just PTEs, so the page size is the plausible part.

Correctness was verified, not assumed: all four arms render a **byte-identical
framebuffer** (md5 `0086feee…`) at emulated t=100 s, inside the region where the
boot is still deterministic.

The experiment tree, the runtime-gated patch
(`mame-indy-hugepage-EXPERIMENT.diff` — note it also carries the shipped
`dma_translate` hunk), the harness and all raw results are kept on labhost under
`/data/vms/sandbox/irix-hugepage/`. **Do not re-open this without a new
hypothesis about where the cycles would come from** — the TLB-walk budget on
this workload is ~2–3% of cycles total, which is the whole prize even if every
walk were eliminated.

### MIPS3 fastram — big and real in the rig, BLOCKED in production (2026-08-03)

**The Indy driver never registered any fastram, so every guest load and store
paid a full MAME memory-system dispatch.** `mips3_device::add_fastram()` maps a
guest *physical* range to a flat host pointer and makes
`static_generate_fastram_accessor` emit an inline `cmp/ja; cmp/jb; load; ret`
ahead of the generic `UML_READ/UML_WRITE` in every read\*/write\* stub. Nothing
in `src/mame/sgi` ever called it.

Read out of the running machine's own `-drc_log_native` dump, the mode-2 read32
stub was 10 instructions of vtlb translation and then **22 instructions of
dispatch** — `ldmxcsr`, address swizzle, a rip-relative dispatch-table base, a
dependent table load, a vtable load, an **indirect virtual call** into
`handler_entry_read_memory<3,0>::read`, and a second `ldmxcsr` to restore FP
mode — before the `ret`. With the region registered the same stub becomes

```
cmp ebx,0Bffffffh / ja / cmp ebx,8000000h / jb / xor ebx,4 / movsxd / mov / ret
```

**Two upstream bugs had to be fixed before it was even correct.**
`static_generate_fastram_accessor` hardcodes the *32-bit-space* byte swizzles
while the buffer behind a fastram region is laid out by the memory system for
the CPU's actual space — 64-bit big-endian on every IP22/IP24 machine, where a
byte is at `A^7` not `A^3`, a dword at `A^4` not `A`, and a guest qword already
occupies one host qword and must not be half-rotated. And `MIPS3_MAX_FASTRAM`
was 3 while a 256 MB Indy configures four 64 MB ranks, with `add_fastram()`
silently dropping the overflow — a quarter of RAM would have kept falling
through. Both are fixed in `scripts/build-guests/patches/mame-indy-mips3-fastram.patch`
(the fix is a strict generalisation: 32-bit fastram users emit identical code),
and `sgi_mc_device::remap_fastram()` coalesces the contiguous ranks so 256 MB
costs two entries, not four.

Measured `-video none -nothrottle`, one binary with the registration behind an
env gate so both arms share the build, six interleaved rounds on one pinned core
pair, within-run windowing, median of paired within-round ratios (bootstrap CI):

| window (emulated) | control | fastram | paired median | 95% CI |
|---|---|---|---|---|
| 40–120 s boot/active | 58.5% | 65.5% | **+8.9%** | +3.7…+22.6 |
| 120–200 s transition | 115.1% | 139.5% | **+15.7%** | +7.4…+36.0 |
| 200–300 s idle/chooser | 140.3% | 166.9% | **+19.1%** | +4.7…+23.5 |

All 18 paired comparisons are positive. Correctness is framebuffer evidence, not
inference: emulated t=100 s renders **byte-identically to control**
(md5 `0086feee…`) and a t=600 s soak lands on a pixel-correct iconlogin chooser
(md5 `5bbf4cbe…`, a frame a control boot is already known to produce).

**Not adopted — it is BLOCKED on a correctness defect found while landing it
(2026-08-03, below).** Experiment tree, harness and raw results are on labhost
under `/data/vms/sandbox/v100-fastram-for-indy-ram/`.

### …and why it is NOT installed: it fails IRIX's own memory diagnostic

Landing the patch meant running it under the station's **exact** production
configuration rather than the measurement rig's. It does not survive that.

With `-ioc2:rs232a pty` — a flag the station passes on every launch — the fastram
binary boots to

> Memory diagnostic **\*FAILED\*** / Check or replace: **SIMM S7** /
> Diagnostics failed. \[Press any key to continue.\]

and stops there forever. The exhibit never reaches the login chooser. The
control binary, in the same clone, on the same seed, at the same instant,
reaches the chooser normally.

The bisect, all on production-config clones, all read off the real framebuffer
(`shmpng.py` on the shm mapping) and never inferred from a log:

| binary | seed | `-ioc2:rs232a pty` | result |
|---|---|---|---|
| control (`0db27300…`, = the shipped binary) | v7 | yes | chooser ✔ (2 runs) |
| fastram | v7 | yes | **memory diagnostic FAILED** (3 runs) |
| fastram | v7 | no | chooser ✔ |
| fastram | v3 | yes | **memory diagnostic FAILED** |
| fastram | v3 | no | chooser ✔ (throttled and unthrottled) |
| fastram | v7 | no, but `-networkprovider taptun` | chooser ✔ |
| fastram | v7 | no, but `-cfg_directory` | chooser ✔ |

So it is the serial port, and only in combination with fastram — not the
seed, not the network, not the throttle, and not the specific build (the
earlier env-gated binary `sgi.fr` with `IRIX_FASTRAM=1` fails identically,
which is also what proves the two builds implement the same thing).

**Leading hypothesis, not yet proven: the registration is DEFERRED and the
guest does not wait for it.** `add_fastram`/`clear_fastram` only set
`m_drc_cache_dirty`; the generated accessor stubs still carry the OLD map until
the DRC resets at the next execute-loop boundary (`mips3.cpp:5355`). That is
harmless when RAM is mapped once at PROM sizing — which is all that happens
without a serial console. Give IRIX a serial console and its **memory
diagnostic** runs, and that test *remaps memcfg while it executes* and reads
back patterns immediately; in the window before the DRC resets, those reads go
through stubs built for the previous mapping. A wrong bank is exactly what
"check or replace SIMM S7" means. Consistent with this, the `IRIX_FASTRAM_LOG`
trace with the serial port present ends with **only bank A registered**
(`0x08000000-0x0fffffff`), where without it both banks are registered.

Note for whoever picks this up: the note that used to circulate as "you must
force a DRC cache flush when registering fastram or you measure a false null"
is wrong *as stated* — the dirty flag does get set and the flush does happen.
But the flush being **deferred** is not harmless, and this defect is the first
evidence of that. Do not delete the concern, restate it: fastram must not be
(re)registered while the guest is running code that depends on the new map
taking effect immediately.

Next steps for a fix, cheapest first: (1) do not register during PROM memory
sizing at all — register once, when the map has settled; (2) failing that, force
the DRC reset synchronously at the memcfg write; (3) re-run the bisect table
above, which is the acceptance test.

### The landing attempt's own numbers (2026-08-03) — n=1, do not believe them

The A/B was re-run on the production binary/seed/flags with a new
**`sweep`** phase in `scripts/build-guests/irix/irix-bench/irixbench.sh`: the pointer
is dragged continuously across the 4Dwm root for the whole hold, so the guest is
doing Newport register traffic rather than sitting in the kernel idle loop. That
is the MMIO-heavy regime the coverage hazard (every extra fastram entry adds a
`cmp/jcc` pair to EVERY accessor stub) would show up in as a loss.

Five interleaved rounds ran, and the guards in
`scripts/build-guests/irix/irix-bench/bpair.py` threw nearly all of it away: five
sibling agents were measuring at the same time, and windows came back at 16-22%
foreign occupancy on the claimed core pair, with several runs at 2.57-2.59 GHz
against a 2.493 GHz cohort median. One paired round survived per window:
boot/active +2.0%, transition +12.5%, idle +8.4%, sweep +11.8%, all positive but
**n=1 in every window** — which is not a result, and is recorded here only so
the next attempt knows the sweep phase works and what the contention cost.

## The integrated binary (2026-08-03)

Three campaigns patched MAME in the same week — the cache-line-size memo, the
PIT idle-strobe fix + scheduling quantum pair, and MIPS3 fastram — while a
fourth needed `mame-taptun-ifname-env.patch` promoted so the station's tap works at
all. The station runs exactly one binary, so they had to become one build.

**Result:** `/data/vms/streamhost/assets/irix/mame/sgi`, md5
`de4eb969f8ff3d72fc5b23ae23a40056`, built by
`scripts/build-guests/emulators/build-mame-irix.sh` from a pristine `8f21e978` plus the
twelve patches in `scripts/build-guests/irix/irix-mame-stack.sh`, in that order,
nothing else. The outgoing binary is kept as `sgi.prev-0db27300`. `IRIX_MAME` is
gone from `station.env`, so the station takes the default again.

Relative to the binary it replaces, this one adds: the taptun interface patch
(the station's networking did not work without it), the cache-line-size memo, and
the PIT/quantum pair. `mame-indy-mips3-fastram.patch` is **not** in it — see the
fastram section above; under the station's real command line it fails IRIX's memory
diagnostic and never reaches the chooser.

### What combining them turned up that no single campaign saw

**The documented stack did not apply to a pristine tree, and the reason was an
undeclared dependency.** `mame-newport-shm-framebuffer.patch` quotes
`m_cache_bitmap` and `m_cache_valid` in its context — symbols that only exist
after `mame-newport-dirty-frame-cache.patch`. The order was right by accident in
the table, but nothing said the dependency was real, and nothing tested it.

**A dry-run-all-then-apply-all loop is wrong for a dependent stack**, and it
fails in the direction that looks like a broken patch. Dry-running all twelve
against the unpatched tree reports failures that are not real (the shm patch
"fails" because the cache patch has not landed yet) and would equally pass a
patch that only applies because a later one is missing. `irix_mame_apply()`
dry-runs each patch **immediately before** applying it, which is the only
ordering that means anything.

**The stack existed in two places and they had already diverged.**
`build-mame-macos.sh` carried its own list, which was missing the Newport
dirty-frame cache, the shm producer and the ds1386 fix — three patches that have
been in the shipped binary for days. It now sources the same
`irix-mame-stack.sh` the labhost build does, with the arch gate (256 MB DRC cache,
x86-64 only) and an OS gate (taptun, Linux only) expressed in the stack itself
rather than duplicated per script.

**`USE_QTDEBUG=0` is not optional on labhost.** Without it genie looks for
`qmake6`, does not find it, and the build dies before compiling a line — a
detail that lived only in per-campaign scratch scripts.

### Smoke test — production configuration, station service stopped

`smoke.sh` copies the station's own `x11-runtime.sh`, `irixagent.lua`, `fbstat.py`
and `tapnet.sh` into a namespaced clone dir, reads `station.env` the way systemd
does, and runs the launcher there — same seed (v7), same `SH_CAPTURE=shm`,
same `-video none -sound none -frameskip 6`, same `IRIX_NET=on` +
`IRIX_NET_EGRESS=on`, both watchdogs armed, throttled exactly as shipped.
`streamhost@irix` was `inactive` throughout and was never started.

What it checked, and what each check is for:

| check | result |
|---|---|
| tap carrier after launch | `irixtap0` carrier **1** — `mame-taptun-ifname-env.patch` is in the binary. This is the check that catches the silent failure |
| cold boot to the iconlogin chooser | frame mean 0.702353 sd 0.166836 at t=120 s, i.e. the byte-identical known-good chooser. The keyboard/mouse-diagnostic panel that the PIT patch *without* the quantum produces would have shown here instead |
| login typed (**keyboard**) | `POST r/o/o/t` + `CODE {ENTER}` → 4Dwm desktop, frame mean 0.618576 sd 0.123478, the known-good desktop signature |
| Toolchest menu drag (**pointer**) | cursor confirmed at (41.6, 55.4) by closed-loop read-back, then button-down → move → button-up on Desktop ▸ "Open Unix Shell" → a real `winterm` with an `IRIS 1#` prompt, frame mean 0.479140. Screendumped |
| serial exec channel | `uname -a` → `IRIX IRIS 6.5 10070055 IP22`, exit 0 |
| RAM patch still took | `hinv` → `Main memory size: 256 Mbytes` |
| guest egress | `ping -c 3 1.1.1.1` 0.0% loss (2.283/6.516/14.200 ms), `nslookup example.com` → 172.66.147.243 |

The keyboard and pointer checks are not ceremony: the PIT patch without the
scheduling quantum boots to a desktop where **neither** works, and the frame
statistics of that desktop are indistinguishable from a healthy one. Only
driving input end to end tells the two apart.

After promotion the same clone was launched a third time from the station's
**installed** configuration verbatim — no `IRIX_MAME`, no binary argument — and
came up on `/data/vms/streamhost/assets/irix/mame/sgi` = `de4eb969…` with the
tap carrier up. `streamhost@irix` was `inactive` for all three runs.

## FSN — SGI's 3D file browser, and seed v8 (2026-08-03)

`fsn` is the File System Navigator from *Jurassic Park* ("It's a Unix system!
I know this!"). It lays a directory tree out as pedestals on a landscape —
pedestal height ∝ directory size, a box per file, box colour by age — and you
fly through it. **It is not part of IRIX 6.5.** The base install carries no
`fsn` subsystem, and neither do the nine SGI CDs staged in
`/data/vms/sandbox/irix-apps/media/` (checked by mounting each EFS volume and
searching its `dist`/`install` trees and every `.idb` file list — zero hits).
SGI distributed it separately, for free, from `ftp.sgi.com:/sgi/fsn/`.

### Where it came from, and what it is

The staged artifact is `/data/vms/streamhost/assets/irix/fsn/fsn.tar.Z`
(215 881 bytes, sha256 `53ad2649c787…`, md5 `7437bf5b…`, 444 + `SHA256SUMS`),
fetched from the Internet Archive item
[`fsn.tar_202201`](https://archive.org/details/fsn.tar_202201) — a copy of SGI's
own FTP directory. Full provenance and the licence stance are in
[`lab/ASSETS-MANIFEST.md`](../lab/ASSETS-MANIFEST.md) §0. It is **not
redistributed with this repo**: SGI-copyright freeware with no redistribution
grant, from a company that no longer exists to give one. That is a statement
about **redistribution**, not about sourcing: the artifact was agent-fetched
from the archival item above, as preservation media normally is (playbook §3.1)
— it simply is not carried in git, and a fresh box re-fetches it.

The tarball is five files and no installer — SGI shipped a `Makefile`, not an
`inst` subsystem, so there is nothing for `inst`/`swmgr` to do and no dependency
resolution to lean on:

| file | installed to |
|---|---|
| `fsn` (340 856 bytes, built 1996-12-13) | `/usr/sbin/fsn`, 0755 root:sys |
| `Fsn` (X app-defaults) | `/usr/lib/X11/app-defaults/Fsn` |
| `Fsn.icon` | `/usr/lib/images/Fsn.icon` |
| `fsn.z` (packed `fsn(1)`) | `/usr/share/catman/a_man/cat1/fsn.z` |
| `Makefile` | not installed — its `BIN` is `/usr/local/bin`, an IRIX 4/5-era path |

**The binary is o32.** `ELF 32-bit MSB executable, MIPS, MIPS-I (SYSV),
interpreter /usr/lib/libc.so.1` — the oldest of IRIX 6.5's three ABIs, which
6.5 still runs. Version 1.2, the ELF rebuild of the 1992 original; the 1992
COFF build (`fsn.COFF.tar.Z`, IRIX 4.0.1) would not have run here at all.

**It is IRIS GL, not OpenGL**, and that turns out to cost nothing: all eleven
`DT_NEEDED` entries resolve on the shipped seed with no additions.

```
libgl.so libSgm.so.1 libXm.so.1 libXt.so libXi.so libXext.so
libX11.so.1 libm.so libgen.so libC.so libc.so.1
```

`/usr/lib/libgl.so` is a symlink to `/usr/gfx/arch/IP22NG1/libgl.so`, and `ldd`
shows it delay-loading `libGL.so`, `libGLU.so` and `libGLcore.so`: IRIX 6.5's
IRIS GL is a shim over its OpenGL, so a 1996 IRIS GL binary reaches REX3 through
the same rasteriser everything else does. `libSgm` (SGI Motif extensions),
`libXm` (Motif 1.2) and `libC` (the C++ runtime) all ship in the base install
too. **Nothing had to be added to the guest — no subsystem, no library, no
`inst` run.** `fsn(1)` also asks for FAM (`desktop_eoe.sw.fam`), which is
already installed and running.

### How it was installed, and how it was proved

On a namespaced clone of seed v7 (`/data/vms/sandbox/fsn-<tag>/`) running the
**production launcher** — the station's own `x11-runtime.sh`, `SH_CAPTURE=shm`,
`-video none`, throttled, both watchdogs, its own `tapnet.sh claim` slot and its
own core pair. `streamhost@irix` was never touched.

The guest has no `wget`, no `curl` and no `/usr/bin/ftp`, so the payload came
over the clone's own `/30`: a one-shot `python3 -m http.server` bound to the
host end, and a ~20-line Perl 5.004 `Socket` GET pushed into the guest through
the serial exec channel — server and fetch in ONE invocation, because a
backgrounded server does not outlive the ssh session. `cksum` matched host and
guest byte for byte (`2628306922 399360`).

Two things about driving this guest that cost time and are worth keeping:

- **Root's shell is csh**, so `VAR=val cmd` is a "Variable syntax" error and
  `$(…)` is not command substitution. Use `env VAR=val cmd`; the exec agent's
  own `/bin/sh` takes backticks.
- **`shmpng.py --cursor` is invalid while fsn is on screen.** It finds the red
  pointer by looking for the only saturated red on an SGI-blue desktop; fsn's
  file boxes are magenta and its overview window draws a large red camera
  crosshair, so the locator tracks *that* and reports a pointer that never
  moves. Two apparent "the pointer is dead" findings were this. `point_to`
  (`irix-bench/workloads.sh`) inherits the weakness — position open-loop from
  the screen corner once fsn is mapped.

`fsn` needs a logged-in session (at the `iconlogin` chooser xdm holds the server
grabbed and X clients block forever), and then:

```sh
env DISPLAY=:0 XAUTHORITY=/.Xauthority /usr/sbin/fsn /usr &
```

Proof is a framebuffer screendump, not a process listing: fsn's splash
(`FSN / the 3D / File System Navigator … Version 1.2`), then the landscape, then
— after a left-click on a pedestal — the camera flying down onto `/usr/lib32/`
with its 271 files standing as magenta boxes, path and `13 directories, 271
files` in the header, the age legend along the bottom and the overview map
docked below. That is the *Jurassic Park* view, rendered by an emulated Indy.
The screendumps are kept beside the asset, in
`/data/vms/streamhost/assets/irix/fsn/proof/` — off-repo, because they are FSN's
own rendered output and carry the same publish blocker the binary does.

**Navigation is not a drag**, which is the first thing that will look like
broken input. A left-button *drag* over the 3D view does nothing at all. A
left-button *click* is the whole navigation model: it selects whatever is under
the pointer and flies the camera to it. `fsn(1)` also documents a middle-button
crosshair whose offset is a velocity — pressing it and moving once flew for a
second or two and then stopped, so sustained flight needs the pointer moved
continuously, not parked at an offset.

### Scanning is the visitor-facing cost, and it is captured

The first run walks the whole tree and writes a database in the home directory
(`/.FSN__usr`, 327 011 bytes) that later runs read in seconds. On `/usr` that
first walk took **~18 minutes of guest clock** — process start 17:58:24, the
database on disk at 18:16. A visitor must never pay that, so seed **v8 ships the
scanned database**, saved through fsn's own `Session ▸ Save database` and then a
clean `Session ▸ Quit` before the guest was halted with `shutdown -y -i0 -g0`
(a real halt to "Okay to power off", so the XFS log is clean in the image).

### `irix65-apps-v8.chd` — LIVE since 2026-08-04

| seed | md5 | size | contents |
|---|---|---|---|
| `irix65-apps-v7.chd` | `4f36d0b8d88e48ae02e40668b55d9a74` | 2 241 626 112 | v7 — serial agent + egress config; the rollback target |
| `irix65-apps-v8.chd` | `5c0c3b37382e47ff75880a5988a89be2` | 2 241 679 360 | **the live seed** — v7 + FSN 1.2 + the `/usr` scan database |

Verified on the promoted artifact itself, without booting it — reflink-copy,
`chdman extractraw`, `mount -t xfs -o ro,norecovery,nouuid,offset=136314880`:
`/usr/sbin/fsn`, `/usr/lib/X11/app-defaults/Fsn` and `/usr/lib/images/Fsn.icon`
all `cksum` byte-identical to the tarball's copies (`2643466609 340856`,
`3118233767 17010`, `1630591695 13806`), with `fsn.z` and the 327 011-byte
`/.FSN__usr` beside them.

Staged 444 + `chattr +i` beside the others. Delta versus v7 and nothing else:
the four installed files above, `/.FSN__usr`, and fsn's saved window state.

**Cut over 2026-08-04 02:09:51** — `IRIX_GOLDEN` in `station.env` now names v8 and
`streamhost@irix` was restarted onto it. Rollback is that one variable back to
v7 and a restart; the station re-copies the seed per launch, so v8 itself stayed
444 + immutable (md5 unchanged after the cutover boot). Verified on the live
station after the restart: cold boot to the byte-identical `iconlogin` chooser
(frame mean 0.702353 sd 0.166836), the shm mapping being written at
5 275 712 bytes, `labctl exec irix` answering, and `/usr/sbin/fsn` (340 856) +
`/.FSN__usr` (327 011) present in the running guest.

### Should a visitor be able to find it? — a proposal, not a change

Right now fsn is only reachable by opening a Console and typing the path, which
no visitor will do. Two period-correct ways to surface it, neither applied:

1. **A Toolchest entry** — `/usr/lib/X11/system.chestrc`, a line under `Desktop`
   or `Demos` reading `"File System Navigator" f.exec "/usr/sbin/fsn /usr &"`.
   Cheapest, most discoverable, and the Toolchest is already the exhibit's
   entry point for everything else.
2. **A desktop icon** — the tarball ships `Fsn.icon` precisely for this, so the
   icon is authentic rather than invented. It costs an ftr/`.desktop` type rule
   and it changes the deterministically bare desktop that v3 was built to
   guarantee, which is load-bearing for the boot-comparison harness.

Both need a seed recapture, and both change what the exhibit looks like on
arrival — a curatorial call. The **desktop icon** was made; see below.

### The desktop icon, and seed v9 (2026-08-04)

`demos` — the account a visitor logs in as — now has an `fsn` icon on the
Indigo Magic desktop that starts FSN on `/usr` when double-clicked.

Three files inside the guest, and nothing else:

| path | what |
|---|---|
| `/usr/demos/Desktop/fsn` | symlink → `/usr/sbin/fsn`, root:sys, beside the shipped `buttonfly` / `Start.Demos` entries. `$HOME/Desktop` **is** the desktop |
| `/usr/lib/filetype/local/Fsn.ftr` | the file-type rule: `MATCH glob("fsn")`, `SUPERTYPE Executable`, `CMD OPEN /usr/sbin/fsn /usr &` |
| `/usr/lib/filetype/local/iconlib/Fsn.fti` | the icon picture |

plus a copy of the captured scan database at `/usr/demos/.FSN__usr` (the seed's
lives in root's home; without it `demos` pays the ~18-minute first-run walk of
`/usr` the seed exists to avoid). `local/` is the vendor-neutral directory the
Makefile documents for root-written rules; `/usr/lib/filetype/local/local.otr`
and `desktop.otr` were rebuilt with `cd /usr/lib/filetype && make`.

The check that says it worked is **`filetype(1)`**, not a screenshot:

```
/usr/demos/Desktop/fsn  FsnExecutable
/usr/sbin/fsn           FsnExecutable
/usr/demos/Desktop/buttonfly  Buttonfly
```

`GenericExecutable` there means no rule matched and the desktop draws the
generic page icon.

**The icon could not be FSN's own `Fsn.icon`, and that is a property of IRIX,
not a shortcut.** The icon language has no raster primitive — an `ICON` block is
a GL-like program of filled polygons — and the desktop draws an icon into
**50x50 screen pixels** from a **16-colour table in which every other entry is a
screen-aligned 2x2 dither of two of those sixteen**. That table is documented
nowhere on the guest, so it was measured: 17 probe icons, one colour per cell,
rendered on the guest and read back off the framebuffer
(`scripts/build-guests/irix/irix-fsn-icon/icon-colour-table.json`; indices 0..15 are
pure, negatives are dithers; the desktop **drops an icon program's first
`color()` call**, which is why the generator emits its opening quad twice).
Transcribing the 85x67 `Fsn.icon` into 838 quads at that scale was built,
rendered and rejected on the framebuffer: at one screen pixel per cell the
dithers become per-pixel speckle. What survives at 50 px is FSN's
*composition*, so `drawfsn.py` draws that — light sky, dark green field, the
ranked colour bars, the white pedestal slab — in 32 polygons.

Repo copies: `scripts/build-guests/irix/irix-fsn-icon/` (`Fsn.ftr`,
`iconlib/Fsn.fti`, the generator, the measured colour table).

| seed | md5 | size | contents |
|---|---|---|---|
| `irix65-apps-v9.chd` | `10f6071c71170639243af8fbd523decd` | 2 241 859 584 | v8 + the FSN desktop icon (staged; **`IRIX_GOLDEN` still names v8**) |

Captured on a namespaced clone of v8 running the production launcher, halted with
`shutdown -y -i0 -g0` to "Okay to power off" so the XFS log is clean, then
promoted 444 + `chattr +i`. Everything the login touched (`.Sgiresources`,
`.desktop-IRIS`, the `Desktop/` entries the desktop auto-creates) was restored or
removed before the halt, so the delta against v8 is the three files above, the
scan-database copy, and the regenerated `.otr`/`mime.types`/`mailcap`.
Cutover to v9 was done 2026-08-04 (`IRIX_GOLDEN` in `station.env`, harvested into
`station.env.fixture` with the savestate work below).

## Instant restore — MAME savestate (issue #44, 2026-08-04)

The station boots by **restoring a captured MAME savestate in ~5 s** instead of the
~390 s cold boot. `indy_4610` now carries `MACHINE_SUPPORTS_SAVE`, provided by
`scripts/build-guests/patches/mame-indy-savestate.patch` (last in the stack): the
`sgi_mc` 256 MB RAM banks are allocated at `device_start` and registered with
indexed `save_pointer`s, a `device_post_load` replays `memcfg_w` from the
restored registers to rebuild the runtime RAM mapping, `mips3` re-derives its
mode/compare arming and flushes the DRC translation cache on load, and a dozen
smaller registrations close the audit's remaining gaps (newport in-flight
host-port state + full-frame shm republish, edlc `util::fifo` shadow
serialization, hal2 clock-rate cache — an unsaved one is a scheduler livelock
if audio DMA was in flight — hle_mouse host-accumulator re-baseline, ds1386
time shadows, nscsi cd/hd odds and ends, vino channel scan state, z80scc
init-list hygiene). Devices verified savestate-complete upstream and left
untouched: hpc3, wd33c9x + nscsi bus, ioc2, pit8253, eeprom/eepromser, z80scc,
pc_kbdc chain (I8042AH/I8051 MCU cores), diexec input lines, divtlb.

**Disk pairing is the invariant.** A savestate is only valid against the CHD
image captured in the same instant; a mismatched (memory, disk) pair loads,
renders a plausible frame and serves stale data behind a healthy desktop —
invisible to criu-style checks and to `xfs_repair -n` alike (see
`irix-criu/README.md`). The capture therefore PAUSES emulation, saves the state
(MAME processes a scheduled save while paused), reflink-copies `disk.chd`
inside the same pause window, and only then resumes. Restore is the reverse:
reflink the paired disk over `disk.chd` and launch with `-state <name>` — no
Lua, no QMP.

- **Capture**: `scripts/build-guests/irix/irix-savestate/capture-checkpoint.sh` (station
  stopped): boots the PRODUCTION config (launcher, station.env, tap) in a
  namespaced clone, waits for the chooser + settle, captures the pair, installs
  `$ASSETS/state/{sta/indy_4610/golden.sta, disk-golden.chd,
  provenance-golden.md5}`. The provenance file binds the state to the exact
  MAME binary md5 — **any MAME rebuild orphans every state** (registration
  signature), and the launcher's guard turns that into a loud cold-boot
  fallback instead of silent garbage. Recapture after every promotion.
- **Restore**: `IRIX_STATE=golden` in `station.env`; every start and every
  `labctl reset irix` / UI "Restore to golden" (both = service restart,
  `SH_RESET_MODE=relaunch`) restores instead of cold-booting. Two restore
  launches without a healthy guest fall back to cold boot; livewatch's first
  successful pointer probe re-opens the budget. `IRIX_STATE=` (empty) is the
  full rollback.
- **Measured** (rig, pinned core pair, canonical binary `00976c04`): state
  file 47 MB; capture pause+save+pair 19 s; restore 4.4 s to first published
  frame, **5.6 s to demonstrably interactive** (launch → serial exec answer)
  vs ~390 s cold boot (~70x). Verified: FS-intact marker across restore, two
  consecutive restores of one state, a save taken FROM a restored instance
  restored again (both generation markers intact), 6-sample framebuffer trace
  with live pointer activity, 15 min post-restore soak.
- **The trap this exhibit already met once**: a state that RENDERS is not a
  state that WORKS. The pre-fix binary produced a 368 KB state that painted a
  pixel-perfect login chooser with a dead CPU behind it (Newport VRAM was
  saved upstream; RAM was not). Never accept a restore on a screenshot —
  verify interactivity (pointer probe) and the guest itself (serial exec).

### True start-paused (2026-08-11)

`systemctl start streamhost@irix` now **ends with the guest paused AT the
restored checkpoint**: with `IRIX_START_PAUSED=on` (station.env), the full launch
restores, waits for the restored frame to be visible in shm (the framebuffer
is the proof, ~4.4 s), settles 2 s, and SIGSTOPs the emulator. The first
visitor session's unconditional `cont` (idle.rs) wakes it — the QEMU fleet's
`-loadvm golden -S` ([instant-ready](../lab/research/instant-ready-bringup.md)),
translated to MAME. The pause is synchronous inside the launcher, which runs
under `ExecStartPre`, so the daemon is not yet serving and no session can race
it — the race that matters, because the idle reconciler only heals a pause
**it** created (idle.rs pause belief), so a guest paused under a live session
would stay paused until the next session.

The instant-restore budget moved with the exposure. A paused launch charges
nothing (`.state-tries` untouched — a paused guest exposes nothing to vet);
`freeze_at_state` leaves a one-shot `.state-unvetted` marker, and livewatch
converts it into the charge at the first wake it observes ("MAME resumed —
watching again" edge). The pointer probe clears the charge exactly as before,
and also consumes an unconsumed marker (a wake livewatch slept through still
gets vetted). Watchdog relaunches and `--mame-only` keep charge-at-launch and
launch RUNNING — a relaunch can happen under a live visitor. Consequences:

- **Unvisited restarts can never ratchet the budget** into the 390 s
  cold-boot fallback — the decay `SH_IDLE_PAUSE_WARMUP_SECS=780` existed to
  prevent. Warmup is now `0`.
- A dead restore is still caught at first exposure: wake charges, probes
  fail, livewatch relaunches (that launch charges at launch), second failure
  crosses the `>= 2` threshold, next launch cold-boots. One extra restore
  attempt is possible when livewatch misses the first wake edge inside its
  grace sleep; bounded by `LIVE_ATTEMPTS` regardless.
- A **cold-boot fallback** now pauses ~60 s in when unvisited (warmup 0) —
  the same mid-boot pause every QEMU station accepts; the first visitor watches
  the rest of the boot live. Loud, rare, accepted.
- `labctl reset irix` is unchanged: mamectl-first (`LOADST golden`, guest
  ends running, the pauser re-pauses it after 60 s idle); its fallback arm is
  a service restart, which lands paused-at-checkpoint like any start.

Rollback: `IRIX_START_PAUSED=off` restores the run-then-pause launch —
restore `SH_IDLE_PAUSE_WARMUP_SECS=780` with it, or an unvisited launch is
paused before livewatch's probe can vet it. `IRIX_STATE=` (empty) still rolls
back all of instant restore.

## Closed-loop 1:1 pointer — MOVEA (2026-08-04)

The mamecmd input path is ABSOLUTE: streamhost emits surface-clamped
`MOVEA x y` (SH_MAMECMD_ABS, default on; `=0` restores the old dead-reckoning
`MOVEP` path) and `irixagent.lua` closes the loop against the Newport VC2
hardware-cursor registers — read each periodic tick via MAME's save-item Lua
API (`:gio64_gfx:xl24:vc2`, items `0/m_cursor_x|y`; position = register −31 per
the sprite draw math, tunable via `IRIX_CURS_CAL_X/Y`) — bleeding paced
relative PS/2 counts until the error is zero. Drift is structurally
impossible; the edge-hugging that dead reckoning produced (accumulated count
loss parking the guest cursor on screen edges, worst on mobile touch) cannot
occur. Verified pixel-exact at opposite screen corners (constant glyph-center
offset, `res=0,0` after 30-target scribbles). `MOVEP`/`MOVE` still work for
the watchdogs and ops scripts. Known follow-up (A3 track, issue #45): a
deterministic give-up on certain chooser targets, e.g. (300,500) landing at
(186,386) — reproduce-not-fix is the porting contract.

## mamectl control plane — the socket is the input path (issue #45, 2026-08-04)

The Lua agent is out of the input path. The `ctlsock` OSD module
(`scripts/build-guests/patches/mame-ctlsock.patch`, last in the stack) serves
mamectl/1 on `MAME_CTL_SOCK` = `<tile>/ctl.sock`, and streamhost's
`mamesock` backend (`mame_sock.rs`, `SH_INPUT_BACKEND=mamesock` +
`SH_MAMECTL_SOCK`) speaks it directly: seq-stamped `MOVEA`/edge/`KEY`
lines, acked, with a latest-wins motion slot and an ordered edge queue
that preserves restate-before-click. The launcher (`IRIX_CTL=on`,
default) arms the socket and drops `-autoboot_script` — MAME_CTL_SOCK
set means NO Lua agent (single-injector rule; two injectors fight over
pacing budgets). `labctl mctl irix "<verb>"` is raw passthrough via
`/root/mctl.py`; `labctl type/sh` ride the socket, and `labctl reset
irix` is an acked `LOADST golden`. The capture
(`irix-savestate/capture-checkpoint.sh`) drives acked `PAUSE`/`SAVEST` —
`ss-agent.lua` and its log-grep side channel are gone. The launcher's
own probes moved too: `probe_alive` nudges over the socket and
livewatch's mid-drag guard reads `STAT last_in_ms` (the cmd file no
longer carries visitor input; `MAME_CTL_CMD_FILE` — the module's 1 kHz
file tail, ~0.8% of a core — arms only under rollback).

Rollback ladder, one knob per tier: `SH_INPUT_BACKEND=mamecmd` (daemon
writes the cmd file, module tails it — still one injector);
`IRIX_CTL=off` (byte-for-byte the Lua-agent launch; must be paired with
`mamecmd` or input is dead); previous binaries kept as
`assets/irix/mame/sgi.prev-<md5>`.

### MOVEA engine — closed loop over the reading (2026-08-04)

Two things had to be right and they are independent: WHERE the pointer is
going (the control law) and WHERE IT ACTUALLY IS (the cursor hotspot). The
engine went through the whole design space of both in one day. The dead
ends are kept because every one of them looked right until it ran.

**v1 (Lua)** recomputed the residual against the VC2 reading every window.
Correct control law, two field defects: issued counts take time to appear
in the reading, so fast sweeps over-issued and rubber-banded at the stop
point; and the reading holds `pointer − glyph_hotspot`, calibrated on the
arrow, so a resize cursor stepped it ~(16,19) px while the pointer stood
still and the loop chased the phantom in and out of the hot zone forever —
the "repelling magnet", with give-up storms pinned at `res=-19,-16`.

**v2–v6** answered that by going OPEN LOOP: dead-reckon a belief
`B += counts × gain`, bleed `T − B`, and consult the reading only at a
settle. It killed the magnet (static target + idle flight ⇒ zero issuance,
whatever the reading does) and it converged well on isolated jumps — the
whole gain-learning apparatus (v5 adaptive per-axis gain, v6 clean-round
learning, hot-target hold-off, one-shot exact close) was built to make it
accurate. It could not work, and the reason is structural: **a settle never
runs during a real mouse sweep**, because the target changes every frame,
so gain error accumulated with no bound. Measured live: belief `1228,997`
with the pointer physically at `649,516`, the engine issuing NOTHING
because `B` said it had already arrived. A steady 200 px host sweep landed
100 px; a 500 px sweep landed 250 px. The learner had been taught ~1.9 by
the chooser's small accelerated corrections, and the sweep gain is nothing
like it.

**The landed engine** goes back to v1's control law and keeps the gain as a STEP SIZER
only. Every window: `err = target − reading − in-flight`, step counts
`= trunc(err / (gain × margin))` capped at `MOVE_STEP`, one step per
window, never while the previous chunk is still on the wire. A wrong gain
now costs convergence SPEED, never accuracy — which is exactly why v1
tracked well with no gain model at all. Three rules keep the two v1
defects dead:

- **in-flight** (`m_infl`, `MAME_CTL_INFL_DECAY` 0.5/window) holds px
  issued but not yet observed, so a lagging reading cannot make the loop
  re-issue counts already in the pipe — that was v1's rubber-band. It
  decays geometrically so a gain OVER-estimate self-clears instead of
  parking a phantom balance in front of the loop;
- **no opposing step**: a step may never contradict the sign of the
  measured error (binding user rule — never extrapolate the cursor ahead
  of real movement; undershoot and trim);
- **the latch**: once a target value converges (or trips the oscillation
  detector, `OSC_FLIPS` 3 sign reversals within one target), that target
  is finished — a later reading, or a RESTATEMENT of the same target,
  issues nothing. That is what kills the magnet without giving up the
  closed loop: streamhost restates the target before every button edge,
  and a hotspot flip can no longer re-open the chase.

Three residual defects the field then found, all diagnosed from the trace:

- **cursor hotspot, READ.** `reading = pointer − hotspot`, and the CAL
  constants calibrate exactly one glyph (the arrow, hotspot 0,0). Every
  other cursor IRIX installs reads a hotspot away from the true pointer:
  the mirrored menu arrow measured 13 px on X alone, and the showcase
  pencil — tip at the bottom of its sprite — put the pointer ~30 px low, so
  it hit the guest's screen clamp while the visitor still had 30 px of
  travel left. The hotspot is X server SOFTWARE state: no register holds
  it, and the VC2 has only cursor x/y, the sprite pointer and the table
  pointer.

  But swapping the glyph FORCES a compensating write to the cursor register
  with the pointer standing still, and that write IS the hotspot delta,
  exactly. `mame-vc2-cursor-swap.patch` records it AT THE WRITE, where no
  motion can be interleaved with it, accumulating `m_cs_dx/dy` behind
  `m_cs_seq`; the module reads what happened since it last looked. Adding
  those three save items moved the signature `2236991a`/3897 →
  `3f091a26`/3900 and cost one checkpoint recapture.

  **Four earlier attempts inferred it instead, and every one failed in the
  field** — the record is kept because each failure looks reasonable until
  you see it run:
  1. a motion BOUND (in-flight px + last step × gain). The in-flight
     estimate decays faster than the guest absorbs, so late-arriving motion
     was booked as hotspot and walked the offset off zero;
  2. per-glyph sprite fingerprinting with a learned table. First sightings
     happen mid-motion, so the stored values were contaminated — 9,9 /
     13,13 / 6,6, diagonal values that are motion, not hotspots — and under
     "measure once" they stuck for the session;
  3. re-measuring on every transition instead. That random-walks: hot_y
     drifted +3 → −18 over six flips at a window edge and put the pointer
     18 px below the visitor's cursor;
  4. calibrating off the guest's screen clamp. Absolute and correct when it
     fires, but it needs the visitor to shove the pointer into an edge, it
     misfired on a merely-stalled loop (booking the arrow at hot=12 and
     stranding the pointer 12 px short of the right edge), and it cannot
     reach a cursor that never visits an edge.

  All four reconstructed, from samples and statistics, one number the guest
  writes down. Do not reintroduce an estimate where the device reports a
  fact.

- **no target-value latch.** v7 finished a target whose coordinates equalled
  the last accepted one without issuing anything — meant to stop a
  hotspot-shifted reading re-opening the chase. It is wrong: the pointer
  LEAVES a position, so a target converged on earlier completed instantly
  from 237 px away (measured live, seq 130). A target is finished when the
  READING says so, never because its coordinates look familiar. Measuring
  the hotspot removed the reason the latch existed; the per-target
  oscillation detector remains as the limit-cycle backstop.
- **a button edge owns the pointer until it lands.** Edges deferred behind
  a converging target release into the click pacer, but `movea_done` starts
  the next queued target in the same drain — so the pointer moved before
  the edge applied and a drag-release landed wherever the user had swept to
  since. Measured: a 120,120-count step (~230 px) between an UP being
  deferred and the UP applying. `movea_step` now returns while a click is
  queued or active.

Measured after landing: four large targets in a row converge at
`res` ≤ 1 px with zero give-ups, against v6's 10–12 px. `MAME_CTL_DEADBAND`
(module default 2, station runs 1) sets the convergence residual;
`MAME_CTL_GAIN_MARGIN` (1.10) is the undershoot margin. Retired with v6:
`MAME_CTL_SETTLE_WINDOWS`, `MAME_CTL_HOT_MS`, `MAME_CTL_CLOSE_MAX`.

**An OSD-module change does not need a checkpoint recapture.** MAME validates a
savestate against its registration signature (`STAT sig=`/`entries=`), and
the engine's state is deliberately not save-registered (COVENANT 1), so
the signature is invariant across engine versions — verified `2236991a`
/`3897` from v1 through v7. `x11-runtime.sh` guards on the BINARY md5,
which is a conservative belt on top of that: for an engine iteration,
append the new md5 to `state/provenance-golden.md5` and swap the binary
(~20 s). A recapture is mandatory only when the signature actually moves —
adding a persistent timer, renaming the module class, or any device/
machine-config change.

## Audio (2026-08-04) — pipeline live; guest playback tracked in #51

MAME runs `-sound sdl -audiodriver disk` with `SDL_DISKAUDIODELAY=0`, writing
S16LE 2ch 48 kHz into the station's `audio.fifo`; the daemon
(`SH_AUDIO_SOURCE=fifo`) is the CLOCK — it reads exactly 192,000 B/s on a
20 ms deadline grid, and the pipe's backpressure paces SDL (an unpaced reader
lets SDL freewheel hold-fill ~166x realtime — 14.9 GB from one 470 s run).
Opus-encoded in-process into the standard audio track; idle desktop is
silence-gated to zero packets (real HAL2 idle output is digital zeros). The
launcher arms SIGPIPE-ignore plus a persistent O_RDWR reader-of-last-resort
fd, so a dead daemon can only block SDL's audio thread, never kill MAME.
Rollback: `IRIX_AUDIO=off` + `SH_AUDIO=off`.

What plays today (refined 2026-08-04, issue #51): the PROM boot chime
(genuine SGI PROM code through the emulated HAL2 — in the boot video with an
exact savestate seam) AND all DEFAULT-OUTPUT-RATE guest playback — the 4Dwm
soundscheme interaction sounds (window opens etc.) verified end-to-end with
measured PCM through hal2 -> SDL-disk -> the daemon's paced fifo. What breaks:
the FIRST client that REPROGRAMS the hardware output rate (playaiff/sfplay,
demos given a 44.1 kHz file) emits one ~0.07 s blip and then kills the output
clock globally and irreversibly for the session — subsequent UI sounds go
silent too, and the player wedges (interruptible sginap poll loop, traced
in-guest with `par`). This reproduces on EVERY host/engine/build combination
tried, including Apple-silicon macOS, so it is a MAME hal2 emulation defect,
not a labhost regression; the exhibit accepts it because every instant-restore
reset (~5 s) restores audio, and the repro brief in #51 is ready if the hal2
fix is ever wanted. A wedged CLI player also blocks its shell and, when run
over the serial exec channel, wedges the agent until reset — keep exec
timeouts short and never use playaiff as a health probe.

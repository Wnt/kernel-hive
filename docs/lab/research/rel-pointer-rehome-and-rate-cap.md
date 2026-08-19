# Relative-pointer stations: auto re-home + paced sends

**Status: BUILT, LANDED, fleet-wide; `macos753` validated PASS.** The
per-station rollout to the other relative stations is the remaining work —
**[`rel-pointer-rollout-status.md`](rel-pointer-rollout-status.md) is the
executable continuation checklist** (state, harness run recipe, per-station
order, aux re-bake). This doc is the design rationale behind it.

Landed (branch `relptr` → main): `streamhost/streamhost/src/rel_bridge.rs`
(model, triggers, pacer, tests), `input.rs` (bridge drives the model),
`config/rel_home.rs` (`SH_REL_HOME_ON`), daemon-wide `MouseState` (survives
browser reload), SPA type-7 re-home hint + `?ptrrec=1` mouse/wire rows,
`scripts/serve/reset-tile.sh` SIGUSR2 + `cont` after a `loadvm`, and the QEMU
fork (ADB button-barrier FIFO + 5 ms autopoll, `github.com/Wnt/qemu`
`kernel-hive @ 70c62de`). **Defaults keep every station byte-identical.**

Operator direction: work on the **live stations** directly (canary daemon +
`POST /restore/<id>` to put the scene back), no clones. Scope: the eleven
`dbus-rel` homing-bridge stations (`aux macos753 hpuxvue sunos414 rhapsody
freedos msdoswin1 star indyr4400 c64 amstradcpc`) plus `beos` for its
absolute-fallback path. **`nt351` is dropped from this plan**: it is a Win32
guest with TCP/IP, so it gets the win95/win311 route instead — a warpd hybrid
agent (`SetCursorPos` motion, real PS/2 buttons; port of
`guest-agents/win9x/warpnet.c` built for the 3.51 subsystem) — which is
absolute by the guest's own API and needs no bridge. `qnx` (pointer-lock) is
out of scope. Goal: the
guest cursor sits under the visitor's browser pointer **without the visitor
ever chasing it to a corner**, and stays there through fast sweeps, app
switches and resets — with the guest untouched (no agents, drivers, HW
cursors or framebuffer readback; those were researched and rejected as too
much work, see [`candidate-aux.md`](candidate-aux.md) discussion 2026-08-18).

## The knobs (station.env.fixture)

| Knob | Meaning | Default |
|---|---|---|
| `SH_REL_HOME_ON` | comma list of re-home triggers beyond the per-session seed: `reset,resume,focus,idle,edge` (`all`) | none |
| `SH_REL_HOME_IDLE_S` | rest seconds before the `idle` trigger (once per rest, never under a held button; the cursor visibly flicks corner-and-back) | 15 |
| `SH_REL_PACED` | `1` = the session's pacer task owns every send: one bounded step per tick across all samples, latest target wins; buttons that carry a point wait (≤600 ms) for the walk | off (legacy inline chunking) |
| `SH_REL_MAX_STEP` / `SH_REL_STEP_PACE_MS` | the step (≤ one guest report: ADB 63, PS/2 255) and the tick (≥ the guest's own sampling period) — pre-existing knobs, now also the pacer's | 256 / 16 |
| `SH_REL_QUANTUM` | pre-existing; the pacer's steps are quantized the same way | 0 |
| `SH_INPUT_TELEMETRY=2` | adds `[input-tel rel] cseq= step= sent= pending=` per step and `rehome`/`idle re-home` lines | 0 |

`macos753` canary: `SH_REL_HOME_ON=reset,resume,focus,idle,edge`,
`SH_REL_HOME_IDLE_S=15`, `SH_REL_PACED=1`, `SH_REL_MAX_STEP=63`,
`SH_REL_STEP_PACE_MS=12`.

## What the operator observed

1. Tracking is good **after** the visitor manually chases the cursor into a
   corner (an edge clamp re-syncs model and guest), as long as guest
   acceleration is off. The initial homing is annoying.
2. **macos753 never drifts** once homed — but its cursor's top speed feels too
   slow: on medium and fast moves it is always catching up with the real
   pointer.
3. **beos** is fast (which is the desired feel) but **drifts** after very fast
   sweeps and after switching apps and Cmd-Tabbing back to the browser.

## Why it happens (read from the daemon, `streamhost/streamhost/src/input.rs`)

- **The bridge homed exactly once per session.** `MouseState` is created per
  WebTransport session in `transport/mod.rs`; the corner pin (FIX 4) fired on
  the session's first sample and never again. Everything that moves the guest
  cursor behind the model's back within a session therefore left a permanent
  offset until an edge clamp fixed it:
  - `loadvm golden` (the reset endpoint, and the launcher's `-loadvm golden -S`
    on daemon restart) teleports the guest cursor to the checkpoint's position;
  - idle-pause / resume, a new visitor arriving after another left, the client
    reconnecting;
  - anything the guest does on its own (a boot cursor, a dialog that warps).
- **A big jump is sent as fast as it arrives.** A sample's delta is chunked to
  ≤256 units per send, 16 ms apart, but *consecutive samples* are handled
  concurrently and back-to-back sends re-merge in QEMU's PS/2 accumulator and
  clamp (`-1024 moves ~500 px` measured on QNX; ADB packets are 7-bit and
  QEMU splits them). Fast sweeps and the single giant delta of a Cmd-Tab
  return (browser pointer re-enters far from where it left) push more counts
  per frame than the guest applies; the model advances to the target anyway
  (`st.lx = tx`) and believes motion the guest never made. That is the drift.
- Guest acceleration compounds both, which is why the observation "works when
  acceleration is off" holds; A/UX additionally truncates per event
  (`trunc(0.75·units)`), handled by the existing `SH_REL_QUANTUM` knob.
- **macos753 (no drift, slow):** QEMU's `adb-mouse` *queues* every count and
  delivers ±63 per report at the ADB poll rate (~11 ms), so nothing is ever
  lost — the guest just lags. The lag is guest-side bandwidth × the linear but
  slow gain we chose ("Very Slow", 0.36 px/count: 1152 px ≈ 3200 counts ≈ 50
  reports ≈ 0.5 s). Faster Mac tracking settings are accelerated, so they stay off:
  the ceiling is the link, see §2 "Speed ceiling".
- **beos (fast, drifts):** a pointer-lock (type-4) station: raw deltas with
  BeOS's own acceleration on — that is the speed. Under lock there is no
  browser cursor to disagree with; when the lock drops (Cmd-Tab away and back)
  the SPA falls back to absolute samples → the homing bridge, whose dead
  reckoning was never calibrated for an accelerating guest and drifts at once;
  fast sweeps additionally outrun the PS/2 accumulator/clamp.

The visitor's manual corner chase works because an edge clamp is the one
event where guest and model agree by construction. The plan below makes the
daemon do that itself, and stops sending what the guest cannot take.

## Precondition: guest acceleration OFF, baked into every checkpoint

Every station on this path pins its guest to a linear tracking setting in the
golden (macos753 "Very Slow", aux "Very Slow", hpuxvue `xset m 1 1`, beos —
acceleration disabled by the operator 2026-08-18, **not yet persisted in its
golden: re-bake**). With that, px per count is one constant
(`SH_CURSOR_SCALE` = 1/gain, plus `SH_REL_QUANTUM` where the guest truncates)
and no acceleration-aware modelling is needed anywhere.

## Design (two small mechanisms, one shared model)

The model tracks **what was actually sent**, never the target: `lx/ly`
advance by the counts injected (this is how the aux quantum already works),
and any un-sent motion stays *pending* against the newest target ("latest
target wins" — pending motion is re-aimed at every new sample, never queued
as stale waypoints, so the cursor lags and converges monotonically; it never
overshoots or rubber-bands).

### 1. Auto re-home

Re-home = the existing corner pin (over-clamp into 0,0, `HOME_SETTLE_MS`), then
walk to the **current** client target through the paced sender. Triggers, all
per-station toggleable (`SH_REL_HOME_ON=session,reset,resume,focus,idle,edge`):

| Trigger | Source | Notes |
|---|---|---|
| `session` | a client session's first pointer sample | replaces the once-per-daemon seed; also covers reconnect |
| `reset` | the daemon's own reset path (`loadvm`/`restart`) | after the restore completes |
| `resume` | idle-pause `cont` | guest may have been paused mid-motion |
| `focus` | new client hint record (SPA sends it on `visibilitychange`→visible, window focus, `pointerenter` of the surface) | the Cmd-Tab case; cheap: one datagram |
| `idle` | no visitor pointer input for N s and no button held | catches anything else; invisible if the pointer is idle |
| `edge` | client target on a screen edge (x==0 / x==W-1 / y==0 / y==H-1) | send an **over-clamp on that axis** — the daemon does the visitor's corner trick automatically, one axis at a time, whenever the pointer touches an edge |

Sequencing rule (the Xerox Star lesson in the code): pin, settle, walk are one
serialised sequence under the mouse lock, and the walk goes through the
rate-capped sender — never a bare burst.

As built: every trigger only raises `RelModel::home_pending`; the next motion
(legacy path: `input.rs` `apply_move_abs`; paced path: the pacer task) runs
`rel_bridge::pin_home` and walks from 0,0. `reset` = daemon-wide
`RESET_EPOCH` bumped by SIGUSR2 (`reset-tile.sh` sends it to `dbus-rel`
stations after a successful `loadvm`; the listener is installed only when the
trigger is on); `resume` = `RESUME_EPOCH` bumped by `idle.rs` on every `cont`;
`focus` = wire record type 7 (no payload) from
`spa/src/three/streamClient/inputWire.ts` on `visibilitychange`→visible,
`window` focus and `pointerenter` of the surface; `idle` = the pacer's timer
(paced mode fires immediately while the pointer rests; legacy mode is
`session`-style: it flags and the next sample pins); `edge` = `edge_of()` on
the client target (x==0 / x≥W-2 / y==0 / y≥H-2) → one over-clamp per axis per
edge visit, sent once the target is reached. `session` is always on and is
not listed.

### 2. Paced sends: one step per pace tick, never faster

Motion goes out as **one bounded step per pace tick** (`SH_REL_STEP_PACE_MS`
and `SH_REL_MAX_STEP` — both exist since 2026-08-18; the pace must be ≥ the
guest's own sampling period, e.g. ≥ 17 ms where the guest applies motion per
VBL, and the step ≤ one report: ADB 63, PS/2 255), across *all* samples of a
session — not per sample as today. Motion beyond that stays pending against
the newest target and drains over the next ticks. Nothing is ever pushed into
the PS/2/ADB accumulator faster than the guest consumes it, so nothing is
lost — that is the whole anti-drift guarantee, and it is what macos753 gets
today by accident of ADB queueing. Feel: ordinary sweeps are unchanged; a
pathological jump (Cmd-Tab return) becomes a fast slide of a few ticks.
Springiness is bounded to `step × latency`, one-directional (latest target
wins, no rebound), and measured in the acceptance below.

**Speed ceiling is a guest property, not ours.** With acceleration off, top
speed = (counts the guest link accepts per second) × (px per count). For
macos753 that is the emulated ADB link — ±63 counts per report at the guest's
poll rate — × 0.36 px/count, which is why its cursor "catches up" on fast
moves even though it never drifts; A/UX at the same setting is 0.75 px/count,
PS/2 guests carry ±255 per packet at 100 Hz. The daemon cannot raise a guest's
ceiling; the one cheap avenue for the q800 pair is the ADB poll interval in
our QEMU fork (`mac_via` autopoll) — a follow-up to measure, outside this
plan.

## Spike first (measurement only, on the LIVE stations, no daemon change)

1. **macos753** (live station; the sweeps are QMP `mouse_move`s + screendumps, and `POST /restore` puts the scene back): the loss knee — send N counts per tick for k ticks
   (N ∈ {16, 32, 63, 128, 256}, pace ∈ {8, 16, 20 ms}), read the framebuffer;
   the largest N/pace applied losslessly is the station's `SH_REL_MAX_STEP` /
   `SH_REL_STEP_PACE_MS`. Also the resulting px/s ceiling, to state the
   "catching up" number.
2. **beos** (live, acceleration off — persist it in the golden first): gain (expect 1.0), then the same knee for
   PS/2 steps {32, 64, 128, 255}; reproduce "lock dropped → abs fallback" drift
   and confirm it vanishes with the bridge re-homed and paced.
3. Result: per-station pace/step values, in the fixtures with the measurement.

## PoC station: **macos753** — then beos, nt351 / rhapsody, then aux

Why macos753 first: the framebuffer measurement tool exists and was built for
it (`scripts/install-vision/adb_pointer.py`: goto/where/gain), reset is an
instant `loadvm` so the "cursor teleported by reset" symptom is reproducible
on demand, and it is the same machine as aux (its slowness is a guest-side
ceiling, see §2 — not what this plan fixes). Then **beos** (the drift complaint; PS/2, acceleration off, KVM),
`rhapsody` (plain x86 PS/2 shape), `aux`, then the rest by measurement.

## Steps

1. **Daemon — DONE 2026-08-18**: reset/resume/focus/idle/edge re-home; `focus`
   hint record (type 7, no payload) from the SPA; a session-wide paced sender
   (one bounded step per tick across all samples) with a pending-motion model
   (`sent` vs `target`, latest-target-wins). Unit tests for the model, the
   step/quantum arithmetic, the edge detector and the trigger parser
   (`rel_bridge.rs` tests). Defaults keep every station byte-identical (new
   triggers off; pacing off unless `SH_REL_PACED=1` — an explicit switch
   rather than "when the step knobs are set", because aux and rhapsody
   already set `SH_REL_MAX_STEP` and must not change under this landing).
2. **Calibration recipe** (documented, per station, ~10 min): gain (existing)
   + the loss knee sweep at the tracking setting baked in the checkpoint;
   record both in the fixture with the measurement. beos: re-bake the golden
   with acceleration off first.
3. **PoC on macos753** (live station, canary daemon): (a) reset → first sample lands on target without
   an edge visit (framebuffer proof); (b) 2000 px jump lands within one quantum
   of the target after ≤ N frames, no residual; (c) fast scribble of 30 random
   targets ends with `res = 0,0` (the irix acceptance); (d) edge trigger: drag
   to the top edge then back — model/guest agree afterwards.
4. **Feel + evidence, on the operator's Mac browser** (not a probe): with
   pointer telemetry ON at both ends —
   - client — DONE: `?ptrrec=1` (or `window.__osgPtrRec = true`) keeps mouse
     rows in `spa/src/input/pointerRecorder.ts` and adds one `w` row per
     absolute move datagram (`w,now,g,<cseq>,<guest x>,<guest y>`; the `tile`
     field of the clientlog record is the station id); `pen-trace.py --moves`
     prints them. Pen default untouched.
   - daemon — DONE: `SH_INPUT_TELEMETRY=2` on a paced station prints
     `[input-tel rel] cseq=<applied> step=(dx,dy) sent=(x,y) pending=(px,py)`
     per step plus `rehome pin=… target=…` and `idle re-home` lines.
   Sessions to record: human sweeps at several speeds, Cmd-Tab away and back,
   window drags, edge touches, a reset mid-session. Verdict from the joined
   logs (target vs sent vs framebuffer spot checks) + eyeball on the live
   station after the canary.
   **The same captures become the test harness**: a replay tool feeds recorded
   `ptr` rows as type-1/type-2 records into the daemon (extend the input-bench
   loopback, `SH_INPUT_BENCH_ADDR`, to the dbus backends — today it only serves
   router backends) against the live station, then reads the framebuffer
   residual; the recorded traces are the fixtures, replayed with the recorded
   timings.

5. Roll out by measurement to the remaining stations; `docs/IO-PATHS.md`
   homing-bridge row updated.

## Acceptance

- No manual corner chase needed after: fresh session, reset, idle resume,
  focus return.
- 30-target scribble at ≥ 3000 px/s: final residual 0 (framebuffer).
- Ordinary motion (≤ 1500 px/s) unchanged frame-for-frame vs today (the cap
  never engages: assert from daemon telemetry).
- Every station's checkpoint has acceleration off (documented per station);
  beos re-baked.

## Risks / open

- Edge trigger on guests whose cursor cannot reach the last pixel (some X
  servers clamp at W-2): use `>= W-2`.
- Client hint needs a wire-protocol bump (record type 7): SPA + daemon land
  together, old clients simply never send it.
- Telemetry volume: mouse rows at 60–120 Hz for a few minutes is fine for the
  rotating `clientlog.jsonl` (~36 h retention), but keep it opt-in per tab.
- Idle re-home must never fire during a held button (drag) — check
  `last_abs`/button state.
- TCG stations: the settle after a pin is longer under load; make
  `HOME_SETTLE_MS` per-station if measurements say so.
- Effort: daemon ~1 day incl. tests, SPA hint ~1 h, per-station calibration
  ~10 min each + eyeball.

---

# Rollout to the remaining relative-cursor stations (plan, 2026-08-19)

**Status: macos753 shipped, this is the plan for the rest.** The hard, one-time
pieces are already fleet-wide; what remains is a uniform, low-risk per-station
**calibration**. This section supersedes the "Steps 5 / roll out by measurement"
line above with a concrete, device-family-aware sequence.

## What every rel station already has (fleet-wide, no per-station work)

1. **Daemon-wide abs→rel model** (`transport::serve`, promoted 2026-08-19,
   `streamhost-5c9da37`). A browser reload keeps its anchor — the tracked guest
   position survives across sessions; only `reset_for_session` per-connection
   fields re-arm. This alone fixes the "reload → corner-chase" symptom on **every**
   dbus-rel station.
2. **`reset-tile.sh` `cont` after `loadvm`** (`973e5c9`). A mid-session Restore no
   longer freezes the guest. Fleet-wide (every QMP loadvm station).

So the remaining work is **not** code — it is turning on the re-home trigger and
measuring one constant per station.

## The uniform per-station step (the bulk of the rollout, ~10 min each)

For each in-scope dbus-rel bridge station, set two fixture knobs:

    SH_REL_HOME_ON=reset
    SH_REL_HOME_TO=<gx>,<gy>        # the guest-pixel hotspot of the cursor in the golden

`HOME_TO` is the cursor's baked position in the golden checkpoint. On a reset the
bridge seeds the model straight there with **no corner pin**, so the guest snaps
under the visitor's pointer on the first move. It is correct because a `loadvm`
puts the cursor at exactly that position; between resets the daemon-wide model
carries the position across reloads.

**Measuring `HOME_TO` is OS-agnostic** — do NOT shape-match the cursor (it differs
per guest). Use nudge-diff against a live clone (or the live station off-hours):
screendump, inject a small relative nudge, screendump, diff the two frames; the
changed pixels bound the cursor, its top-left is the hotspot. This is exactly the
method that measured macos753 (599,500). Proposed helper:
`scripts/install-vision/measure-golden-cursor.py <station>` — reset to golden via
`POST /restore`, nudge-diff, print `gx,gy`; a ~40-line generalisation of the
throwaway script used for macos753. **Build this first**; it turns each station
into a two-minute job.

Keep each station's existing device knobs (they solve a different problem, see
below): aux's `QUANTUM`/`MAX_STEP`, the PS/2 stations' `MAX_STEP`/`STEP_PACE`.

## Why the device-level work does NOT need to be repeated

The ADB button-barrier FIFO + 5 ms autopoll (fork `70c62de`) was needed because
**ADB rate-limits**: `adb_mouse_poll` delivers ≤63 counts per autopoll and reports
the current button state each time, so a button-up raced the still-draining motion.
**PS/2 does not have this race**: `ps2_mouse_sync` (`hw/input/ps2.c`) drains *all*
accumulated motion in one burst (`while (ps2_mouse_send_packet(s))`) before the next
button state is reported, so a drag already releases where it ends. PS/2's opposite
problem — a 16-byte queue that *overflows* on a big fast move — is what the existing
`SH_REL_MAX_STEP`/`STEP_PACE` chunking already handles. **So no PS/2 device change
is required**; keep the chunking, add the two knobs above.

## By device family

### (a) ADB — `aux` (do first; the binary is already there)

`aux` runs the *same* `/opt/qemu-m68k` binary as macos753, so it **already has the
FIFO + 5 ms autopoll**. Remaining:
- Measure `HOME_TO` for the A/UX golden; set `SH_REL_HOME_ON=reset` + `SH_REL_HOME_TO`.
- **Keep** `SH_REL_MAX_STEP=32` + `SH_REL_QUANTUM=4` (A/UX truncates `trunc(0.75·units)`
  per event; the quantum keeps sends on the model — a real drift guard, not pacing).
  Send raw otherwise (no `SH_REL_PACED`).
- Acceptance: reload keeps anchor; reset snaps; drag releases at the end; no drift.

**FINDING 2026-08-19 (cursor-track.mjs + gain measurement):** with HOME_TO applied,
aux's reset/reload anchor is correct, BUT tracking DRIFTS on fast moves (browser
harness: right-side targets overshoot ~90 px, drag off 89 px; macos753 is 4 px on the
same harness). Gain is exactly right (a clean 100-unit inject → 75 px = 0.75, so
`SH_CURSOR_SCALE=1.3333` stands). Root cause: the global **5 ms autopoll delivers
reports 4× faster, which trips A/UX's X-server pointer acceleration** on rapid moves
— macos753's Mac OS is linear ("Very Slow") so it is immune. aux's "accel off" was
only the Mac Finder side; its **X server still accelerates**.
FIX (the plan's own "acceleration OFF, baked into every checkpoint" precondition,
which aux never met for X): bake `xset m 0 0` (or a high threshold) into the golden's
A/UX X session, then 5 ms is both fast and linear. aux has no exec channel and X
keyboard is broken, so this needs a `.xinitrc`/`.Xdefaults` bake or a blind
`labctl sh` — a golden re-bake, same shape as beos below.
ALTERNATIVE if the re-bake is deferred: make the ADB autopoll rate per-station
(read `SH_ADB_POLL_MS` in `adb_bus` init/post_load, default 5) so aux keeps 20 ms
and its pre-existing exact tracking, trading the speed boost it did not need (gain
0.75 already makes it 2× macos753's speed at any poll).

### (b) PS/2 dbus-rel — `rhapsody` (PoC), then `hpuxvue`, `freedos`, `msdoswin1`

No device change. For each: `SH_REL_HOME_ON=reset` + measured `SH_REL_HOME_TO`,
**keep** the existing `MAX_STEP`/`STEP_PACE` (rhapsody 24/16; set a conservative
`MAX_STEP` for the others if a fast sweep overflows the PS/2 queue — the
`−1024→~500px` / `−8192→no-op` measurements are on qnx). Notes:
- `rhapsody` (`/opt/qemu-rhapsody`, scale 2.09) — the "plain x86 PS/2 shape" PoC.
- `hpuxvue` (`/opt/qemu-hppa`, `lasi-ps2-mouse`) — accel already off via `xset m 1 1`.
- `freedos`, `msdoswin1` — dual-path: Pointer-Lock (type-4) is the primary feel and
  bypasses the bridge; `HOME_TO` only improves the non-locked / lock-drop path. Lower
  priority, but cheap once the helper exists. `msdoswin1` has **no fixture** — create
  one from the registry `stationEnv` first.

### (c) PS/2 needing a golden re-bake first — `beos`

`beos` is the drift case, and its acceleration is ON in the golden (the operator
disabled it 2026-08-18 but it is **not yet persisted**). Order:
1. Re-bake the golden with BeOS mouse acceleration OFF (linear), so `cursor_scale`
   is one constant. 2. `SH_REL_HOME_ON=reset` + measured `HOME_TO` for the fallback
   path. With accel off + daemon-wide model + reset re-home, the lock-drop drift that
   started this whole investigation should be gone. Validate the Cmd-Tab-away-and-back
   case explicitly.

### (d) Sun serial — `sunos414` (needs two measurements + a device check)

`sunos414` (`/opt/qemu-sparc` SS-5, `sun-serial-mouse`, `SH_CURSOR_SCALE=1.0`
placeholder). Before the two knobs:
1. **Measure the gain** (px per delta unit) with a `mouse_move` sweep vs framebuffer,
   set the real `SH_CURSOR_SCALE` (macos753's `adb_pointer.py gain` is the template).
2. **Analyse `sun-serial-mouse`** in the sparc fork the way ADB/PS/2 were analysed:
   does it rate-limit like ADB (→ needs a FIFO) or drain-per-sync like PS/2 (→ nothing
   to do)? Don't assume; read the device's event/poll path first.
3. Then `SH_REL_HOME_ON=reset` + measured `HOME_TO`. `exec` (telnet_unix_e) gives a
   closed loop for validation here — read the X pointer, don't just eyeball.

### (e) Out of scope / deferred

- **`qnx`** — explicitly out (pointer-lock is its intended feel).
- **`c64`** — host-native VICE, pointer not wired (`method=none`); nothing to calibrate.
- **`amstradcpc`** — the CPC has no mouse hardware; motion is inert by design.
- **`nt351`** — leaving the bridge regime for the warpd-hybrid route (SetCursorPos +
  real PS/2 buttons); do not calibrate as a bridge station.
- **`indyr4400` (Iris)`, `star` (Darkstar)** — Debian **kiosk bridges** being
  de-bridged; Iris/Darkstar grab the pointer internally and Pointer-Lock is the real
  feel. `HOME_TO` only helps the non-locked bridge path — defer to their host-native
  conversion (`DEBRIDGE-CONVERSION-BRIEF.md`) rather than calibrating a throwaway.

## Suggested order

1. **Helper**: `measure-golden-cursor.py` (unblocks everything, ~1 h).
2. **aux** (ADB, binary ready — parity with macos753).
3. **rhapsody** (PS/2 PoC — proves the "no device change, two knobs" path).
4. **hpuxvue** (PS/2, accel already off).
5. **beos** (after the accel-off re-bake).
6. **sunos414** (after gain measurement + device check).
7. **freedos / msdoswin1** (dual-path, low priority; msdoswin1 needs a fixture).

## Acceptance (every station)

- Reload the browser → cursor keeps tracking, no corner chase.
- Reset to golden → cursor snaps under the pointer on the first move.
- Fast window-drag → releases where it ends (ADB via FIFO; PS/2 via immediate drain).
- Fast scribble → no residual drift (accel off + daemon-wide model).
- Ordinary motion unchanged frame-for-frame vs today.

## Risks / open

- `HOME_TO` assumes the guest is at golden at session start. The daemon-wide model
  covers reloads; `reset` covers restores. The residual edge — first session after an
  idle-resume that left the cursor moved — degrades gracefully to one manual corner
  chase, no worse than today.
- Keep PS/2 `MAX_STEP` chunking; a raw send can still overflow the 16-byte PS/2 queue
  on a pathological sweep.
- `beos` re-bake must land before its `HOME_TO`, or the constant is measured against
  the wrong (accelerated) golden.
- `sun-serial-mouse` is unanalysed; treat the "PS/2 needs no device change" conclusion
  as PS/2-only until its event/poll path is read.

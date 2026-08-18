# Relative-pointer stations: auto re-home + paced sends

**Status: daemon + SPA + reset hook IMPLEMENTED 2026-08-18** (branch `relptr`
→ main): `streamhost/streamhost/src/rel_bridge.rs` (model, triggers, pacer,
tests), `input.rs` (bridge now drives the model), `config/rel_home.rs`
(`SH_REL_HOME_ON`), SPA type-7 re-home hint + `?ptrrec=1` mouse/wire rows,
`scripts/serve/reset-tile.sh` SIGUSR2 after a `loadvm`. **Defaults keep every
station byte-identical**; `macos753` is the canary with the knobs below.
Still open: the per-station calibration sweep (§Spike), the framebuffer PoC
(§Steps 3) and the human feel session (§Steps 4) — the operator's eyeball on
`macos753`, then rollout by measurement.

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

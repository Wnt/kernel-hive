# Relative-pointer stations: auto re-home + paced sends (plan)

**Status: plan, 2026-08-18. Nothing implemented.** Operator direction: work on
the **live stations** directly (canary daemon + `POST /restore/<id>` to put the
scene back), no clones. Scope: the eleven
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

- **The bridge homes exactly once per daemon lifetime.** `MouseState`
  (`lx, ly, seeded`) is created once in `transport/mod.rs` and shared by every
  client session. The corner pin (FIX 4) fires on the first-ever sample and
  never again. Everything that moves the guest cursor behind the model's back
  therefore leaves a permanent offset until an edge clamp fixes it:
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

1. **Daemon**: per-session/reset/resume/idle/edge re-home; `focus` hint
   record (type 7, no payload) from the SPA; a session-wide paced sender (one
   bounded step per tick across all samples) with a pending-motion model
   (`lx/ly` = sent, latest-target-wins). Unit tests for the pacer and the
   pending model. Defaults keep every station byte-identical (new triggers off
   except `session`; pacing off unless `SH_REL_MAX_STEP`/pace are set).
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
   - client: `spa/src/input/pointerRecorder.ts` already rings every
     pointerdown/up/cancel/move with two clocks and pushes `ptr` rows to
     `POST /clientlog` every ~2 s (`scripts/serve/pen-trace.py` decodes it);
     it currently **drops mouse events** (built for the S-Pen investigation).
     Change: a `?ptrrec=1` switch (and `window.__osgPtrRec`) that keeps mouse
     rows, and stamp each row with the station id, the mapped guest coordinates
     and the wire `cseq` so rows join exactly with the daemon side; keep the
     pen default untouched.
   - daemon: `SH_INPUT_TELEMETRY=2` on the station (exists: per-inject lines
     with move sequence, batch length, inject RTT, button transitions) — add
     the client `cseq` and the bridge's pending/sent model values to the
     level-2 line.
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

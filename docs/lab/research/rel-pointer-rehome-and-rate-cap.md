# Relative-pointer stations: auto re-home, paced steps and step tables (plan)

**Status: plan, 2026-08-18. Nothing implemented.** Scope: the twelve
`dbus-rel` homing-bridge stations (`aux macos753 hpuxvue sunos414 rhapsody
nt351 freedos msdoswin1 star indyr4400 c64 amstradcpc`; the pointer-lock
type-4 stations `qnx beos` are a different path and out of scope). Goal: the
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
  reports ≈ 0.5 s). Faster Mac tracking settings are accelerated, which the
  open-loop model could not follow — until §3 below.
- **beos (fast, drifts):** a pointer-lock (type-4) station: raw deltas with
  BeOS's own acceleration on — that is the speed. Under lock there is no
  browser cursor to disagree with; when the lock drops (Cmd-Tab away and back)
  the SPA falls back to absolute samples → the homing bridge, whose dead
  reckoning was never calibrated for an accelerating guest and drifts at once;
  fast sweeps additionally outrun the PS/2 accumulator/clamp.

The visitor's manual corner chase works because an edge clamp is the one
event where guest and model agree by construction. The plan below makes the
daemon do that itself, and stops sending what the guest cannot take.

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

### 2. Rate cap = one step per pace tick

Motion is sent as **one step per pace tick** (`SH_REL_STEP_PACE_MS`, exists;
≥ the guest's own sampling period — Mac OS applies its curve per VBL, so
≥ 17 ms there), never faster; motion beyond that stays pending against the
newest target and drains over the next ticks. Nothing is ever pushed into the
PS/2/ADB accumulator faster than the guest consumes it, so nothing is lost:
that is the whole anti-drift guarantee, and it is what macos753 gets today by
accident of ADB queueing. Feel: ordinary sweeps are unchanged; a pathological
jump (Cmd-Tab return) becomes a fast slide of a few ticks to the pointer.
Springiness is bounded to `step × latency`, one-directional (latest target
wins, no rebound), and measured in the acceptance below.

### 3. Step table — speed WITH acceleration on, still exact

The classic accelerators are all functions of the **per-report delta**: Mac OS
`mcky` tracking tables, A/UX's Toolbox (`trunc(0.75·u)` at Very Slow, more
above), DOS mouse drivers' mickey thresholds, Windows/OS-2 acceleration
thresholds, X `xset m N T`, BeOS's speed/acceleration. If the daemon only ever
sends a small **fixed set of step sizes**, one per tick, the px moved per step
is a constant per size — a per-station table `SH_REL_STEP_TABLE=1:0.36,4:1.4,
16:6,63:40` (units → px), measured with the framebuffer sweep — and the model
(kept in px, pending motion in px) is exact **with acceleration on**. Big
distances go as the largest step (fast, accelerated — the BeOS feel), the last
few px as small steps (precise). Constraints to honour: one guest report per
step (ADB ≤ 63 units, PS/2 ≤ 255), one step per guest sampling period. Where
the guest is linear the table has one row and this degenerates to
`SH_CURSOR_SCALE`; where it truncates (A/UX) it subsumes `SH_REL_QUANTUM`.
Determinism is the thing to **verify by measurement** first (repeat sweeps
identical?), which is the spike below.

This resolves the operator's two contradictory wishes: macos753 can move to a
fast tracking setting (re-bake) and stop lagging; beos can keep its speed and
stop drifting (it would run this bridge for its absolute-fallback path, and
arguably instead of pointer lock — same table).

## Spike first (measurement only, clones, no daemon change)

1. **macos753 clone**: step tables at Very Slow *and* at a fast tracking
   setting — for steps {1,2,4,8,16,32,63}, 20 repeats each, one step per 20 ms:
   px per step and its variance. Determinism = variance 0. Also the knee: how
   many px/s the fast table reaches (does it end the "catching up"?).
2. **beos clone**: same for PS/2 steps {1,4,16,64,128,255} with BeOS
   acceleration as baked; plus the "lock dropped → abs fallback" reproduction.
3. Result decides: table-driven bridge (§3) if deterministic; plain cap (§2)
   + acceleration off if not.

## PoC station: **macos753** — then beos, nt351 / rhapsody, then aux

Why macos753 first: the framebuffer measurement tool exists and was built for
it (`scripts/install-vision/adb_pointer.py`: goto/where/gain), reset is an
instant `loadvm` so the "cursor teleported by reset" symptom is reproducible
on demand, its slowness is the operator's concrete complaint, and it is the
same machine as aux. Then **beos** (the drift complaint; PS/2 + accel, KVM),
`nt351`/`rhapsody` (plain x86 shapes), `aux`, then the rest by measurement.

## Steps

1. **Daemon**: per-session/reset/resume/idle/edge re-home; `focus` hint
   record (type 7, no payload) from the SPA; one-step-per-tick sender with a
   step table (single-row table == today's scale) and a pending-motion model in
   px (`lx/ly` = sent, latest-target-wins). Unit tests for the step chooser and
   the pending model. Defaults keep every station byte-identical (new triggers
   off except `session`; no table = current behaviour).
2. **Calibration recipe** (documented, per station, ~10 min): the step sweep
   at the tracking setting baked in the checkpoint; record the table in the
   fixture with the measurement. macos753: re-bake at a fast tracking setting
   once its table is proven.
3. **PoC on macos753 clone**: (a) reset → first sample lands on target without
   an edge visit (framebuffer proof); (b) 2000 px jump lands within one quantum
   of the target after ≤ N frames, no residual; (c) fast scribble of 30 random
   targets ends with `res = 0,0` (the irix acceptance); (d) edge trigger: drag
   to the top edge then back — model/guest agree afterwards.
4. **Feel** via the CT950 headed-Chrome browser probe
   ([`browser-probe`](../research/) memory): human sweeps, Cmd-Tab away and
   back, window drag; operator eyeball on the live station after canary.
5. Roll out by measurement to the remaining stations; `docs/IO-PATHS.md`
   homing-bridge row updated.

## Acceptance

- No manual corner chase needed after: fresh session, reset, idle resume,
  focus return.
- 30-target scribble at ≥ 3000 px/s: final residual 0 (framebuffer).
- Ordinary motion (≤ 1500 px/s) unchanged frame-for-frame vs today (the cap
  never engages: assert from daemon telemetry).
- Guests with acceleration on stay out of scope until it is turned off in the
  checkpoint (documented per station).

## Risks / open

- Edge trigger on guests whose cursor cannot reach the last pixel (some X
  servers clamp at W-2): use `>= W-2`.
- Client hint needs a wire-protocol bump (record type 7): SPA + daemon land
  together, old clients simply never send it.
- Idle re-home must never fire during a held button (drag) — check
  `last_abs`/button state.
- TCG stations: the settle after a pin is longer under load; make
  `HOME_SETTLE_MS` per-station if measurements say so.
- Effort: daemon ~1 day incl. tests, SPA hint ~1 h, per-station calibration
  ~10 min each + eyeball.

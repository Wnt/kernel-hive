# Relative-pointer stations: auto re-home + rate cap (plan)

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
   acceleration is off.
2. The initial homing is annoying.
3. Tracking is lost / drifts after **very fast browser sweeps** and after
   **switching apps and Cmd-Tabbing back** to the browser.

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

### 2. Rate cap (calibrated per OS)

`SH_REL_MAX_RATE=<units per 16 ms tick per axis>`: a token bucket in front of
`rel_motion_bounded`. Motion beyond the cap stays pending against the newest
target and drains over the next ticks. Calibration: the same framebuffer sweep
used for aux — send N units per tick for k ticks, read the displacement, find
the largest N the guest applies losslessly; set the cap just under the knee.
Expected order of magnitude: PS/2 guests hundreds of units per tick; ADB
guests tens (A/UX accelerates above 32/event, so its cap is 32 with
`SH_REL_MAX_STEP=32` already doing that job).

Feel: a cap only clips motion faster than the guest can follow, so ordinary
sweeps are unchanged; the pathological jump (Cmd-Tab return) becomes a fast
slide of a few frames to the pointer instead of a lost cursor. Springiness is
bounded to `cap × latency` and one-directional (no rebound), and it is
measured, not guessed, in the acceptance below.

## PoC station: **macos753** — then nt351 / rhapsody, then aux

Why macos753 first: tracking is measured linear (0.36 px/unit, chunk-size
invariant), the framebuffer measurement tool exists and was built for it
(`scripts/install-vision/adb_pointer.py`: goto/where/gain), reset is an
instant `loadvm` so the "cursor teleported by reset" symptom is reproducible
on demand, and it is the same machine as aux so the aux/quantum path is
covered by the same code. Second wave: `nt351` (gain 1.0, PS/2, the plain
x86 shape) and `rhapsody` (0.478 px/unit, KVM-fast, fresh measurements exist).
Then `aux` (quantum + cap together), then the rest by measurement.

## Steps

1. **Daemon**: per-session/reset/resume/idle/edge re-home; `focus` hint
   record (type 7, no payload) from the SPA; token-bucket rate cap;
   pending-motion model (`lx/ly` = sent, latest-target-wins). Unit tests for
   the bucket and the pending model. Defaults keep every station byte-identical
   (`SH_REL_HOME_ON=session` only? — no: default **off** for the new triggers
   except `session`, which is strictly better than once-per-daemon; rate cap
   default = unlimited).
2. **Calibration recipe** (documented, per station, ~10 min): gain (existing),
   then rate knee via the sweep; record both in the fixture with the
   measurement.
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

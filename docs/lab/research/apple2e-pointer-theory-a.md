# apple2e pointer: theory A (8-bit axis / MCU differencing wall) — REFUTED

Rig: `/data/vms/sandbox/apple2e-ptra/rig` (golden restored, station dir untouched).
Measured 2026-09-08 on the apple2e golden checkpoint, Dazzle Draw canvas.

## Verdict

**Refuted.** There is no wall. Every count reaches the guest and the arrow
follows, linearly, at a constant gain. `MAME_CTL_PTR_MOD=256` is correct and is
doing its job (`DUMP accum` stays inside 0..255).

The "arrow moved 0 px" evidence in the golden stream was a **broken arrow
locator**, not a guest behaviour: `ptr2.py:arrow()` scans `x` from 0, and the
frame's left border column is lit, so it returned the constant `(0, 62)` for
every frame. Restricting the scan to `x >= 10`, `72 <= y < 640` finds the arrow.

## Ladder (shm 1024x768, arrow tip = topmost-leftmost white pixel in the canvas)

| step | command | tip before | tip after | dpx | px/count |
|---|---|---|---|---|---|
| home | `MOVE -1200 -1200` | — | (141,156) | — | (clamped) |
| x1_0 | `MOVE 1 0` | (141,156) | (143,156) | +2 | 2.0 |
| x1_1 | `MOVE 1 0` | (143,156) | (144,156) | +1 | 1.0 |
| x1_2 | `MOVE 1 0` | (144,156) | (146,156) | +2 | 2.0 |
| x1_3 | `MOVE 1 0` | (146,156) | (148,156) | +2 | 2.0 |
| x5   | `MOVE 5 0` | (148,156) | (154,156) | +6 | 1.20 |
| x20  | `MOVE 20 0` | (154,156) | (187,156) | +33 | 1.65 |
| x60  | `MOVE 60 0` | (187,156) | (282,156) | +95 | 1.58 |
| x120 | `MOVE 120 0` | (282,156) | (479,156) | +197 | 1.64 |
| y60  | `MOVE 0 60` | (479,156) | (479,264) | +108 | 1.80 |

Totals: 209 x counts -> 338 px = **1.617 px/count**; 60 y counts -> 108 px =
**1.80 px/count**. No saturation, no wrap, no drop at any step size up to 120.
`STAT bel=209,60` equals the issued counts exactly; `skipped=0,0`.

Frames: `A_home.png` (arrow at 141,156), `A_x120.png`, `A_y60.png` (arrow at
479,264) in the rig dir. Scripts: `thA.py`, `loc.py`, `dif.py`.

## Why the card cannot be the wall

`src/devices/bus/a2bus/mouse.cpp` `update_axis()` differences the 8-bit ioport
(`diff > 0x80 => diff -= 0x100`) into an **unbounded backlog** `m_count`, then
emits one quadrature edge per `mcu_port_b_r()`. Nothing is discarded: the
backlog only delays counts, it never loses them. The only genuine hazard is a
single *observed* accumulator delta above 127, which the pacing
(`MAME_CTL_MOVE_STEP=120` per 40 emulated ms) already stays under. Measured
behaviour matches: 120 in one command lands whole.

`ioport.cpp:3822` does clamp `set_value` (`m_adjoverride = clamp(value,
m_adjmin, m_adjmax)`), which is exactly what `PTR_MOD=256` exists to avoid —
and it is set, so the clamp never bites.

## What the real defect is

Open-loop MOVEA assumes **1 count = 1 px** (`ctlsock.cpp` `m_gx = m_gy = 1.0`,
learned only in the CLOSED loop, which is off here because the Apple II has no
hardware-cursor save items — `setup ... movea=0`, `movea_mode=open`). The truth
is ~1.62 px/count on X and ~1.80 on Y, so MOVEA under-issues by ~40% and its
belief diverges from the screen after the first target. That is the whole
"only one MOVEA of six landed" symptom.

Two fixture defects follow:

1. No open-loop gain seed exists. `MAME_CTL_CAL_X/Y` is a *cursor-register*
   calibration and is inert in open loop; there is no `MAME_CTL_GAIN_X/Y`.
   The module needs one (or the station needs an SPA-side scale of 1/1.62,
   1/1.80).
2. `MAME_CTL_SCREEN` is unset, so the clamp surface defaults to **1288x1024**
   while the apple2e shm is **1024x768**. The belief clamps against the wrong
   rectangle. Set `MAME_CTL_SCREEN=1024x768`.

## Proposed fixture diff (NOT applied — belongs to the apple2e branch)

`streamhost/stations/apple2e/station.env.fixture`: replace the "NOT YET USABLE"
paragraph with the measured gain above, add `MAME_CTL_SCREEN=1024x768`, and
keep `MAME_CTL_PTR_MOD=256` (proven correct, not merely assumed).

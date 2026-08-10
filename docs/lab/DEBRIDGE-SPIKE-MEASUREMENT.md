# De-bridging spike — the measurement

How we compare a bridge-wrapped emulator against the same emulator running
host-native, and what the resulting number is and is not a claim about.

Companion: [`GUEST-TIERS.md`](../GUEST-TIERS.md) for what the two tiers are,
[`OVERHEAD.md`](../OVERHEAD.md) for the figures this is measured against.

## The three arms

Same OS, same emulator, three backends — the `irix`/`indyr4400` contrast-pair
pattern, with one more arm.

| Arm | What runs | Tier | Purpose |
|---|---|---|---|
| **A** | MAME Atari ST + EmuTOS **inside the Debian bridge kiosk** | 2 | the status quo |
| **B** | MAME Atari ST + EmuTOS **host-native**, frames via `drawshm` | 3 | the candidate |
| **C** | the live `atarist` tile — **hatari** in the kiosk | 2 | reference, **untouched** |

A and B differ in **exactly one thing: the display path.** Same binary (host and
guest are both trixie, so one build runs in both), same ROM, same fixture, same
resolution. C is a different emulator and is not part of the A/B — it is there
so the numbers can be sanity-checked against a tile that already works, and it
is never modified.

## Why a curve, not a number

The bridge costs two things that both scale with **damage area**: QEMU's v1 copy
path moves changed pixels out of a 32bpp kiosk surface, and x264 encode is
pixel-count bound. A single fixture would answer for one damage size and mislead
about the others — which is exactly the flaw in measuring on a 2-colour 8-bit
machine that flips its whole screen.

So three fixtures, spanning the range a real visitor produces:

| # | Fixture | Damage | Trigger | Why this one |
|---|---|---|---|---|
| **1** | **Cursor motion** across empty desktop | ~16×16 px | pointer move, no button | Minimum damage, and the thing a user perceives most sharply. Pure `type-1` datagram path. |
| **2** | **Click an icon → black highlight** | ~one icon cell | button edge | A single GEM blit, so **no render ramp** — the cleanest edge available. Black on dithered grey = maximum per-pixel delta in a tiny box. Takes the reliable-stream path, not the datagram path. |
| **3** | **Open the Options menu** | ~750×750 px | pointer (GEM drops menus on hover) | Exceeds `SH_DAMAGE_FULL_PCT=35`, forcing the **full-frame** encode path — the honest worst case. |

If the A→B delta is roughly constant across all three, the bridge penalty is a
fixed compositing term. If it **grows with damage area**, the copy path
dominates and de-bridging is worth much more for the graphical tiles than for
the 8-bit ones. That distinction is the whole point of the spike and a single
fixture cannot produce it.

## Fixture discipline

- **Both arms start from the same restored golden state**: the plain desktop,
  no menu open, no icon selected. Icon positions must match between arms or the
  click coordinates differ — verify with a framebuffer shot, not by assumption.
- **Alternate within each fixture** so a stale frame can never satisfy the next
  trial: cursor moves between two distant points; clicks alternate between two
  icons (AIM 3.1 ↔ BALLERBURG); the menu opens and closes.
- **Fixture 3 has a render ramp.** The menu box appears before its text is
  fully drawn. Clock **first change** — it is consistent and comparable across
  arms — and record time-to-fully-rendered *separately*, as its own number. Do
  not average the two or pick whichever is convenient per arm.
- Validate every fixture on the MAME arm with a real screenshot before a single
  timed trial. EmuTOS under MAME is not guaranteed to lay the desktop out
  identically to EmuTOS under hatari.

## What is clocked

Clock starts in the browser at `performance.now()` immediately before the
WebTransport write of the input record. It stops at the first decoded
`VideoFrame` whose diff against the pre-trial baseline exceeds the fixture's
threshold. That spans browser pack → QUIC up → input router → sink → emulator →
guest repaint → capture → BGRA→I420 → x264 → QUIC down → WebCodecs decode. It
excludes only physical monitor scan-out.

**This is the same contract that produced the published 25.6 / 34.9 / 39.8 ms
tier table**, which is why we extend the existing harness rather than write a
new one — the numbers have to be comparable to what is already recorded.

## Confounds that must be pinned, or the result is worthless

- **Resolution.** The kiosk root and the host-native surface must publish the
  **same pixel count**. This is why `drawshm` must accept an arbitrary output
  size. Unequal arms measure resolution, not the bridge.
- **Frameskip.** Fixed and identical in both arms. Any adaptive frameskip is
  load-dependent, and arm B is by construction less loaded — leaving it in
  measures the frameskip controller.
- **Idle auto-pause OFF in both arms.** A QMP-paused guest cannot be timed. It
  stays ON for the live gallery; this is a spike-only setting.
- **Exactly one viewer**, the probe. A second viewer on either arm doubles that
  arm's encode work and is a real confound.
- **No migration builds, and no other sustained CPU campaign.** This is the one
  ambient-load rule that matters: a MAME compile or a golden re-bake is minutes
  of saturated cores and will swamp a ~9 ms effect.

  **A full fleet quiesce is NOT required** (operator, 2026-08-10). The tiles are
  idle-paused when unwatched, the hourly `vms-snapshot` timer is `nice 10` /
  `idle` I/O and does not register, and — the real reason — the **interleaved
  A/B/A/B paired delta is what cancels ambient drift**. Both arms meet the same
  conditions within each round, so a quiet-but-not-silent box costs a little
  precision in the *absolute* numbers and nothing in the *delta*, which is the
  number being claimed. Report the observed load range rather than asserting
  quiescence.
- **Turbo bin.** x264 smears ~1.07 cores over 8 physical cores and pins the
  package at ~2.47–2.50 GHz while streaming. Both arms inherit it; sample and
  report the achieved clock per arm and show they match.
- **Emulator throttling** identical in both arms. MAME throttled means the
  guest advances at the same rate regardless of host headroom — otherwise part
  of any "win" is just the emulator running faster, which is a different claim.

## Reporting

Interleaved A/B/A/B in blocks, never all of A then all of B — that is what
survives turbo wander and fleet drift. Report **p50 / p95 / min / max and the
within-round paired delta**, per fixture. Never a mean.

Publish alongside: emulated speed per arm, MAME and streamhost CPU per arm, and
the `SH_ENC_PROFILE` hop split, so a delta can be attributed to capture-wait vs
encode vs the rest rather than asserted.

## Status, and the CPU ceiling (2026-08-10)

Both arms are up and re-runnable — rig and bring-up commands in
[`scripts/debridge-spike/README.md`](../../scripts/debridge-spike/README.md).
**The latency campaign has NOT been run.** What follows is everything measured
before it.

**Both arms publish a pixel-identical frame.** Same GEM desktop, same 1024x768,
`frame-compare.py` verdict `UNCHANGED — not one pixel differs` (0 of 786,432).
The one binary is literally one binary: sha256 `0f08379e…` on the host and
inside the kiosk guest at the time of that capture.

**A `drawshm` frame reaches the browser through streamhost.** `direct-stream-proof.mjs`
in Chrome on CT950 against arm B: `1024x768`, three decoded frames, 98.57%
non-black, `decodeError: ""`. So the Rust consumer's seqlock retry, damage diff
and geometry remap all work against this producer, which was the spike's biggest
unknown.

**CPU at matched resolution — the cheap ceiling.** Idle GEM desktop, both arms
throttled, `-frameskip 0`, one streamhost each, no viewer. Interleaved A/B/A/B,
3 rounds x 20 s, sampled from `/proc/<pid>/stat` with each pid resolved through
`/proc/<pid>/exe`. Load 4.79–6.34 throughout; package 2326–2425 MHz.

| | arm A (bridge) | arm B (host-native) |
|---|---:|---:|
| emulator | QEMU+kiosk+MAME **120.0 / 120.0 / 120.6** | MAME **92.9 / 92.5 / 92.1** |
| streamhost | **26.7 / 26.1 / 25.9** | **9.1 / 9.1 / 9.0** |
| total, % of one core | **146.8 / 146.2 / 146.6** | **102.0 / 101.6 / 101.1** |

Within-round paired delta (A − B): **44.8 / 44.6 / 45.5** points of a core.
Arm B costs **69%** of arm A for the same published surface. The saving splits
roughly two-to-one: ~28 points on the emulator side (the bridge's own QEMU/X
overhead) and ~17 points on the capture side (`shm` versus the dbus/QEMU path,
which is streamhost at about a third of its cost). **So the conversion does
remove real work** — the latency campaign is worth a window.

**Fixture readiness is NOT complete, and this is the gate on the campaign.**

| fixture | arm B | arm A |
|---|---|---|
| 1 cursor motion | **validated** — 1,143 px changed (0.145%), cursor only | **not validated** — the two captures are byte-identical |
| 3 Options menu on hover | **validated** — 71,016 px (9.03%), title inverted, menu drawn | **partly** — a hover menu (Desk) is open in its capture, so motion does reach the emulated pointer, but the closed loop did not converge on Options and its two captures are identical |
| 2 click icon → black | **not validated** — the click produced no change, so it did not land on the cell | **not validated** |

Arm A's pointer is the open item: the closed loop drives it through QMP
`input-send-event` to the usb-tablet, and at that step size the motion is not
reliably reaching MAME through the kiosk's SDL. Fix that before timing anything
— an arm whose fixtures cannot be placed cannot be measured.

Three things the campaign will have to carry, all of them properties of the
MACHINE and therefore present in both arms:

- MAME's ST mouse is a **quadrature encoder** (`src/mame/atari/stkbd.cpp`): a
  500 Hz tick latches the axis ioport every fourth tick, keeps only the
  DIRECTION and emits one step per latch. A burst is discarded rather than
  carried, the ceiling is ~125 counts per emulated second per axis, and TOS
  accelerates on top. Open-loop dead reckoning cannot place this pointer;
  `fixtures.py` closes the loop against the published framebuffer, identically
  for both arms.
- The **Options menu drops on hover** and costs ~6% of the frame, not the
  >35% the fixture table assumed — so fixture 3 will NOT force the full-frame
  encode path on this machine at this resolution. Report the measured damage
  fraction; do not assert the threshold.
- Arm A's **bare-X root cursor** moves with the tablet without the emulator
  being involved, and would satisfy a damage detector before the GEM cursor
  moved. It is blanked in the kiosk launcher; leaving it visible would bias the
  bridge arm faster.

## What the number does not claim

It is a claim about the **video** half of the path plus one input sink. It does
**not** transfer to pointer *feel* on other tiles: `dbus-abs` through a
usb-tablet into a kiosk Xorg is a genuinely different mechanism from `mamesock`
with hardware-cursor readback. A keyboard or cursor number here must not be
quoted as a mouse-feel number elsewhere.

It also says nothing about what de-bridging **costs**: the kiosk supplies a
uniform X environment, ALSA→dbus audio, a golden qcow2 snapshot for instant
reset, an ssh exec channel and cgroup memory capping. Tier 3 has to replace
each of those or do without.

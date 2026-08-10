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
- **Exactly one viewer**, the probe. Quiesce to CT950 plus the arm under test,
  assert occupancy on the arm's own core pair, and record it.
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

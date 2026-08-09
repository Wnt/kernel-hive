# nextstep pointer — the CLOSED-LOOP angle (paused mid-flight, 2026-08-09)

Sandbox: `/data/vms/soltest/NSPTR-closed-loop/` (torn down). Everything below was
measured on a reflink clone of the live tile's `overlay.qcow2`, booted from its
own `golden` snapshot, driven on the production wire (QMP `input-send-event`
rel -> QEMU PS/2 -> kiosk X -> SDL xrel -> Previous -> NeXT KMS), and verified
against QEMU `screendump` framebuffers.

## 1. Reading the cursor position — SOLVED, exact, ~20 us

Previous keeps the emulated NeXT RAM in a host buffer reachable through its
`NEXTRam` pointer symbol (the binary is PIE, unstripped, `nm -S` resolves it;
`NEXTRom` / `NEXTVideo` / `NEXTIo` are there too). The NeXTSTEP cursor location
is a big-endian int16 pair inside that buffer. A differential scan against
corner slams produced candidates; requiring agreement with EIGHT
framebuffer-verified positions cut them to three RAM offsets:

    32660712, 33136672, 33139950   (guest physical = 0x04000000 + offset)

The first single-offset cut (32660672) looked right on 2 samples and was WRONG
on 4 of 12 — the shadows go stale independently — so `nsagent.py` reads all
three and serves the MAJORITY. Validated: 11/11 exact agreement with an exact
arrow-template match on the framebuffer (the 12th point is the top-left corner,
where the sprite is clipped and the template cannot match at all — a limit of
the ground-truth instrument, not of the reader).

Costs: RAM read 17-40 us (Python, in-kiosk). Host->kiosk round trip over a
`hostfwd_add`ed loopback port 0.5 ms. Whole-frame arrow template match in pure
Python 970 ms — i.e. option (a) is a validation instrument, not a control-loop
sensor. The offsets are physical-RAM offsets, so they survive `loadvm golden`
by construction but would move if WindowServer restarted; a re-acquire routine
(corner slam + verify) was designed and not built.

## 2. The measured acceleration curve — the headline

Per-axis independent (one event carries both axes; `(20,10)` lands exactly
`(D(20), D(10))`). One injected event produces ONE atomic cursor jump, 10-22 ms
later (median 19 ms, tail 75 ms). Displacement saturates at 630 px per event
(the NeXT KMS delta register is 6-bit signed).

The gain is HISTORY dependent — this is the trap. A "cold" plant (first event
after a burst of corner-slam events) has gain ~17.5; the warm state a
controller actually operates in has gain exactly 10.

COLD / hot-branch, single event from a corner slam (guest px per commanded d):

    d      1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
    px     0   2  16  48  80 100 110 130 150 170 190 210 220 240 260
    d     16  17  18  19  20  21  22  23  24  25  26  27  28  29  30
    px   280 300 320 330 350 370 390 410 430 450 470 490 500 530 550
    d     31  32  33  34  35+
    px   570 580 610 620 630 (saturated)

WARM / steady state (repeated events, first two discarded, both directions,
both axes, medians):

    displacement = 10 * d   exactly, for d = 5..63, capped at 630
    d = 1 -> 0 px,  2 -> 2 px,  3 -> 12 px,  4 -> ~26 px

So the plant is quantised: the smallest possible move is 2 px, the next is
12 px, and above that the grid is 10 px. Cooling makes the sub-5 rungs slightly
smaller (d=4 falls 30 -> 12 px after ~600 ms of silence); d=1..3 are
cooling-invariant. A chain of small events keeps the plant in a low-gain state
(d=5 gives 6 px per event when every preceding event was also d=5), which is
what makes the naive "one event from the corner" table misleading.

Two events closer together than ~20 ms MERGE inside Previous (their deltas sum
before the KMS reads them), and a merged sum saturates: two rel(20,0) 6-15 ms
apart move 630 px, not 700.

## 3. Where the controller got to — FAIL, but close, and the failure is legible

`ctrl.py` is an adaptive closed loop: pick the ladder rung whose predicted
displacement is nearest the remaining error, never command a step that would
slam an edge, re-estimate the d>=5 gain from what each step actually produced,
never adapt the fixed sub-5 rungs, confirm once more after the loop in case a
jump is still in flight.

Best 24-target sweep (all framebuffer-verified): **max error 9 px, mean 2.17 px,
15/24 within the 2 px tolerance**, 3-10 steps, 81-246 ms. That is a FAIL on the
acceptance test (max err <= 2 px on all 24) and it is at the 250 ms wall.

The binding constraint is arithmetic, not engineering: each corrective step
costs one plant latency (10-22 ms), the coarse grid is 10 px and the finest
step is 2 px, so a worst-case residual of 5 px needs three more 2 px steps on
top of the coarse step and one gain-correction step. 5-6 steps is ~130 ms when
everything goes right, and the loop only has ~11 steps of budget.

NEXT CONCRETE STEP if resumed: cut steps, not milliseconds. Choose the coarse d
so the residual is deliberately even (the 10 px grid leaves that free), which
makes the 2 px walk terminate at 0 rather than 1, and stop the loop re-reading
after each fine step — a 2 px step is unconditionally 2 px, so it can be
open-loop-batched and confirmed once. That should bring the worst case to
~4 steps / ~90 ms. Also unbuilt: the re-acquire routine for the RAM offsets,
the robustness sweep after guest-driven cursor motion (criterion 2), the
`loadvm golden` re-check (criterion 3), the compiled artifact (criterion 4),
and the input->photon latency measurement (criterion 5).

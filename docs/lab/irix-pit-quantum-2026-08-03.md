# The 8254 idle re-arm storm, and the scheduling quantum that has to replace it

**Status: the MAME fix is proven, the repo carries it, and a candidate binary
is staged on labhost — but it is NOT promoted to the station.** The blocker is stated in
"What is not finished" at the end — it is a margin question, not a doubt about
the defect or the fix.

Box: `labhost`, 16 logical CPUs, Debian trixie. Target: MAME `indy_4610`,
one R4600, 256 MB, IRIX 6.5.22 + 4Dwm, seed `irix65-apps-v3.chd`
(`368fcfb9b56fb4165a4e456238dc1a18`). Production binary
`0db273009ecd1d41634b5527c8fa6be8`. The live `streamhost@irix` service was
STOPPED for the whole of this work and every measurement is a clone under
`/data/vms/sandbox/irix-pit-4c8e/`.

## The defect

`pit_counter_device::simulate()` picks the number of input clocks until the next
OUTPUT transition in `cycles_to_output`, which starts at 0 and is only assigned
inside a per-mode `switch (m_phase)`. Modes 4 and 5 reach phase 0 in normal
operation — after the strobe, the output goes high and the counter free-runs
until a new count is written, which MAME's own phase table records as
"infinity". The mode 4/5 switch has cases 1, 2 and 3 only, so phase 0 falls
through it with `cycles_to_output` still 0. The caller reads 0 as "the output
changes right now" and arms the update timer at `m_last_updated + 0`; `update()`
then sees zero elapsed cycles and re-arms one clock later; that lands back in
phase 0. The counter re-arms twice per input clock, forever, and none of those
re-arms ever moves an output or raises an interrupt.

Modes 0 and 1 do not have the bug (mode 0 tests phase 0 explicitly, mode 1's
switch ends in `default: CYCLES_NEVER`). Modes 2 and 3 cannot reach phase 0 in
the branch that runs the switch. **Modes 4 and 5 are the whole of it** — the
earlier note in this project that called it "modes 3/4/5" was over-broad.

IRIX programs IOC2 counter 2 to mode 4 (control byte `0xb8`) about two emulated
seconds into the boot and never takes it out. Captured in the guest-programming
trace at `v100-pit-8254-tick-storm/pitlog/pit.txt`:

    2.000091 CTRL ctr=2 rw=3 mode=4 bcd=0 raw=0xb8

### Measured directly on the production binary, with no instrumented build

Kernel uprobes placed by raw ELF `st_value` on a byte-identical copy of the
shipped `sgi` (`perf probe`'s own resolver fails on C++ `::`, so the events were
written into `/sys/kernel/tracing/uprobe_events` by hand). Control arm, IRIX at a
scrolling `winterm`, 30 s wall = 5.00 emulated seconds:

| uprobe | count | per emulated second |
|---|---|---|
| `pit_counter_device::update_tick` | 8,361,028 | **1,672,206** |
| `hpc3_device::do_pbus_dma` | 0 | **0** |
| `wd33c9x_base_device::update_step` | 266 | 53 |

And the same probe on the TREATMENT arm (`IRIX_PIT_IDLE_FIX=1`, quantum 8 us),
60 s of wall clock across a boot:

| uprobe | control (60 s) | fix (60 s) |
|---|---|---|
| `pit_counter_device::update_tick` | 16,766,438 | **0** |
| `hpc3_device::do_pbus_dma` | 0 | 0 |
| `wd33c9x_base_device::update_step` | — | 320,517 |

The storm does not shrink, it disappears. What is left as the busiest timer in
the machine is the WD33C93 SCSI controller stepping through disk I/O during the
boot — not audio, and not the PIT.

1.672M/emu-s reproduces the earlier campaign's 1.68M exactly, from a completely
independent measurement path.

**The probes were placed on a PRIVATE COPY of the binary, not on
`assets/irix/mame/sgi` itself.** A uprobe is keyed by inode: probing the shipped
file would have added trap overhead to every sibling agent's clone running the
same binary.

## Audio DMA: the two earlier results reconciled

Two prior conclusions were in conflict — an early analysis predicted audio DMA
would become the dominant timer source once the PIT storm was removed, and a
later campaign measured that the HPC3 audio-DMA storm does not exist.

**The later campaign is right.** `hpc3_device::do_pbus_dma` fired **zero** times
in five emulated seconds of terminal scrolling. It cannot become dominant after
the PIT fix because it is not firing at all: nothing on an idle-or-scrolling
4Dwm desktop programs an HPC3 PBUS DMA channel. The earlier prediction was
reasoning from the device's existence rather than from its expiry count.

The one thing worth stating precisely, because it was the source of the
confusion: `-sound none` is an **OSD-SINK** option. It selects MAME's host audio
module and does not disable the emulated HAL2/HPC3 audio path, so "we run with
sound off" was never a reason the DMA count would be zero. The count is zero
because the guest never starts a transfer.

## The fix alone is not shippable: it takes the scheduler's quantum with it

MAME breaks a timeslice at the earlier of the next timer expiry and the
scheduling quantum. `indy_4610` sets no quantum of its own, so it inherits
MAME's 1/60 s default — and the only thing that was actually interleaving the
CPU with the rest of the machine was the storm, firing every half microsecond.

Remove the storm and leave the quantum at the default and IRIX comes up with **no
input at all**. Framebuffer screendump, `evidence/kbd-diag-FAILED-fix-without-quantum.png`:

    PC keyboard/mouse controller diagnostic    *FAILED*
            Check or replace:  CPU base board
    Cannot connect to keyboard -- check the cable.
    Cannot open keyboard() for input

That is the whole argument for the companion patch, and it is a CORRECTNESS
argument, not a tuning one: the quantum is not a performance knob here, it is
what keeps the IOC2 keyboard controller interleaved finely enough for IRIX's
PS/2 diagnostic to complete. Note the direction — 16-64 us is far FINER than
MAME's 16.67 ms default, so an explicit quantum on this driver tightens
interleaving relative to stock MAME rather than loosening it.

## Speed

Metric is `emulated_secs / (cycles / 2.5e9)`, never MAME's own average-speed %.
Achieved GHz (`cycles / task-clock`) is reported beside every figure. Windows are
cut WITHIN one run from the emulated-time trace. One binary (`sgi.ab`) with both
changes behind environment gates, so control and treatment differ only by the
knob.

Idle 4Dwm desktop, 95 s hold, `-nothrottle`, production seed/flags/agent:

| arm | knobs | cycnorm% | GHz | IPC | foreign% |
|---|---|---|---|---|---|
| ctl | none | 105.86 | 2.491 | 1.316 | 19.8 |
| qonly16 | quantum 16 us only | 116.36 | 2.490 | 1.296 | 20.6 |
| q16 | PIT fix + quantum 16 us | **244.18** | 2.488 | 1.570 | 15.3 |

**These are single runs on heavily loaded labhost** — foreign occupancy on the
claimed core pair was 15-21%, against the ~0% the baseline campaign enjoyed, and
the absolute numbers are correspondingly far below the 152.67% that campaign
measured for a control idle desktop. They are reported as the shape of the
effect, not as the effect size. The n>=10 paired campaign that would fix that is
listed as unfinished below.

## Boot reliability, and what still blocks promotion

### The cliff IS settled; the value below it is not

Cold boots scored "reached the 4Dwm desktop" from framebuffer signatures, one
binary with the quantum set from the environment:

| quantum | boots OK |
|---|---|
| 4 us | 2 / 2 |
| 8 us | 2 / 2 |
| 16 us | 4 / 4 |
| 32 us | 0 / 4 |
| 64 us | 0 / 1 |
| 128 us | 0 / 1 |
| MAME default (16.67 ms) | 0 / 1 — keyboard diagnostic FAILED |

8 of 8 below the boundary, 0 of 6 above it; Fisher exact p ~ 3e-4. The known
background rate of the black cold-boot hang on this image is 2 in 10, so the
failures at and above 32 us are not that. The shipped value is therefore 8 us:
the largest with more than one octave of margin under a measured cliff.

### What still blocks promotion

1. **The speed difference between 4, 8 and 16 us is not separable on labhost.**
   Foreign CPU on the claimed core pair ran 8-87% across the campaign, and the
   apparent per-quantum ordering tracks the contention rather than the knob:

   | arm | cycnorm% | GHz | IPC | foreign% |
   |---|---|---|---|---|
   | q4 | 142.52 / 157.54 | 2.490 / 2.494 | 1.095 / 1.081 | 81.9 / 86.6 |
   | q8 | 189.55 / 211.61 | 2.486 / 2.491 | 1.251 / 1.386 | 51.5 / 43.4 |
   | q16 | 238.13 / 246.99 / 273.34 | 2.493 / 2.490 / 2.493 | 1.528 / 1.588 / 1.764 | 47.3 / 16.2 / 8.1 |

   Every arm's score rises monotonically as its foreign occupancy falls, and no
   arm was ever measured at the same occupancy as another, so these rows cannot
   be differenced. The cleanest single window in the whole campaign — q16 at
   8.1% foreign, **273.34% cycnorm @ 2.493 GHz** — is roughly 1.8x the baseline
   campaign's control idle desktop (152.67% at quiet labhost), which is the right
   order for the effect but is one run against another run and is NOT offered as
   the effect size.
2. **W1/W2 at n>=10, and W3, are not measured.** The rig drives all three now
   (see below) and the SHIPPED binary was measured in both regimes, but the
   PAIRED campaign against the production binary could not be completed: the two
   arms were launched six seconds apart on two claimed core pairs and both were
   swamped.

   The shipped binary `sgi.ship` (`4a45fbc433197572e0857e8c5ce522b9`, PIT fix +
   8 us quantum), five w1/w2 cycles in one run at 13% foreign:

   | window | cycnorm% | GHz | IPC | foreign% |
   |---|---|---|---|---|
   | W1 terminal scroll | 52.97 | 2.490 | 1.260 | 13.2 |
   | W2 window drag | 51.02 | 2.489 | 1.301 | 13.0 |

   The project's reference control figures are 45.6-49% for terminal scroll, so
   this is the right side of them — but that reference was taken on quiet labhost
   and this was not, and comparing them is exactly the cross-run differencing
   this project has retracted results for. It is offered as "the shipped binary
   works and is in the right range", NOT as a delta.

   The paired control arm launched alongside it read W1 32.14% and W2 29.65% at
   **117.5% and 123.9% foreign occupancy** — i.e. both logical CPUs of the
   claimed pair were fully occupied by other agents' unpinned emulators — and
   the treatment arm's windows were discarded outright by the analyser's guards.
   Both are reported here only so nobody mistakes them for data.

   Note for whoever repeats this: sibling agents on labhost run their MAME
   instances UNPINNED. Claiming a core pair protects nothing against that, and
   the +39%/+31% W1/W2 figures this workstream was asked to confirm at n>=10
   remain unconfirmed for that reason alone.
3. ~~The 600 s clock-drift check~~ **— DONE, and it passes.** On the shipped
   binary (PIT fix + 8 us quantum), `date` read off the framebuffer at both ends
   of a long unthrottled hold:

   | | guest clock | emulated seconds |
   |---|---|---|
   | a | Sat Aug 3 14:35:43 PDT 1996 | 474.000 |
   | b | Sat Aug 3 14:46:14 PDT 1996 | 1106.000 |
   | elapsed | **631 s** | **632 s** |

   One second out of 632, which is inside the +/-1 s each end of reading a
   whole-second `date` through a typed command. The guest clock tracks EMULATED
   time; over the same span the host clock advanced 237 s, i.e. the machine was
   running at 2.67x real time and its clock correctly ignored that. A timer
   change that made the emulated clock drift would be unshippable however fast
   it was; this one does not.

   Getting this took a fail-closed guard. The first attempt ran `drift` after
   `w1`, so `date` was typed into a shell still running `repeat 400 find` and
   never executed — the screendumps showed scrolling paths where the clock
   should have been. The dispatcher now refuses drift-after-w1 outright rather
   than producing an unreadable answer.

## What the rig gained, and one bug it was hiding

`scripts/build-guests/irix/irix-bench/` now drives the interactive workloads the
baseline campaign recorded as impossible on seed v3. They were never
impossible; the rig was driving the guest with the **wrong agent**.

`irixbench.sh` defaulted to `$ASSETS/irixagent.lua`, but the live station runs
`$D/irixagent.lua` from its own directory, and the two had drifted: the assets
copy still seeded the pointer accumulators at 32768, so the first `MOVEP` of a
session presented a ~32768-count delta to a 9-bit PS/2 wire field, overflowed,
and the cursor never moved again for the life of the run. The repo copy and the
station copy (`566edbbd22e03488141a168ea1fd40ad`) have the fix; only the staged
asset was stale. The rig now defaults to the station's copy, and the stale asset
was refreshed on labhost (previous kept as `irixagent.lua.stale-401b6077`).

With the right agent the workloads are straightforward:

- **Anchored open-loop gestures.** `MOVEP -2000 -2000` saturates the pointer
  into the top-left corner, which is an absolute reference; every gesture is a
  delta from there.
- **Closed-loop confirmation.** `shmpng.py --cursor` finds the pointer by red
  mask in the emulated framebuffer, and `point_to` waits for it to ARRIVE before
  pressing. Without that the agent's paced motion drain races the button verb,
  which is what made a Toolchest pick miss and abort a run.
- **W1** terminal scroll: Toolchest -> Desktop -> Open Unix Shell (a spring-loaded
  menu drag: press at (40,48), release at (180,228)), then `repeat 400 find /usr
  -print`. **W2** window drag: grab the title bar at (120,14) and zigzag it; 4Dwm
  drags a wireframe, so W2 measures rubber-band redraw, not window blitting.
  **W3** Netscape: launched from the winterm and scrolled with Page Down.
- The winterm is confirmed on the WHOLE-FRAME mean (0.619 bare desktop -> 0.479
  with the window open), not on a crop's standard deviation: the Toolchest sits
  inside any crop large enough to hold the window and clears an sd threshold on
  its own. An earlier revision of this rig "confirmed" a winterm that had never
  opened exactly that way.
- Boots that go black now fail fast instead of burning the full boot deadline,
  because when the failure RATE is the measurement, ten minutes per failure is
  most of the experiment.
- A multi-sample framebuffer trace (`fbtrace-samples.txt`, emulated time +
  mean/sd every 10 s) runs for the whole of every run. This is the correctness
  comparison for a timing change; the single md5-at-emu-t=100 checkpoint is not,
  because under `-frameskip 6` the control arm snapshots black as often as the
  treatment does.

# Measurement methodology

How this lab measures emulator performance, and why each rule exists. **Four
conclusions have been retracted to method errors**; every rule below carries the
incident that produced it, because a rule without its scar tissue does not get
followed.

Scope: the IRIX/MAME work drove all of it, but nothing here is IRIX-specific
except the framebuffer signature table. Any A/B on a shared box owes these rules.

The rig that implements them is `scripts/build-guests/irix/irix-bench/` (see its
[README](../../scripts/build-guests/irix/irix-bench/README.md)); the reference
numbers are in [irix-baseline-2026-08-03.md](irix-baseline-2026-08-03.md); the
things already measured and closed are in
[irix-closed-register.md](irix-closed-register.md).

---

## 1. The metric

**`cycnorm% = emulated_secs / (cycles / 2.5e9)`** — how much of a guest second
this host delivers per 2.5 GHz-second of CPU.

**Never MAME's own "Average speed %".** It is wall-clock based and swings ±8%
with turbo wander alone, which is larger than most effects being chased.

## 2. Achieved GHz must accompany every cycle-normalised figure

The cycle-normalised metric does not merely *ignore* a clock change. **It
inverts it.**

> Demonstrated: at 1.5 GHz an active window read **66.39% cycnorm** against a
> control's **55.49%** — scored as a "+20% win" while running **28% slower in
> real time**.

So every reported figure carries **achieved GHz (`cycles / task-clock`)** beside
it, and a run whose clock is out of family with its cohort is **discarded, not
averaged in**. In the 2026-08-03 baseline the one run that read 2.514 GHz among
a 2.493–2.494 GHz cohort is exactly the run that scored lowest on cycnorm.

Anything that perturbs thread count, spin-waiting or C-states is otherwise
scored **backwards**.

Related, for clock reasoning generally: on this box speed converts at
**alpha = 0.78**, not 1.0 — a 1% clock change buys 0.78% of cycnorm.

## 3. Within-run windowing only. Cross-run differencing is invalid.

IRIX boot **diverges from t ≈ 120 s** (the RTC is seeded from the host clock and
X/session startup branches on it), so two runs did different work even in the
shared 0–150 s prefix.

Windows come from an emulated-time/wall-time trace written *inside the run being
measured* (`bench-agent.lua` records `<host_epoch> <emulated_seconds>` twice a
second; `perf stat -I 1000` supplies cycles per wall-second; `bwin.py` joins
them).

> Cross-run differencing manufactured **three** retracted results: a "171.3%
> idle" figure, a "+23.2% active" per-row prototype win, and that prototype's
> "−25% idle regression". Re-measured within-run, the prototype is +0.4% active
> and −1.5% idle — a null. Two bogus numbers from one bad method pointed a whole
> work item in the wrong direction.

This is not a style preference.

## 4. Pin a full CORE PAIR, never a single logical CPU

`taskset -c 1` pins the **whole process** — emulation thread and workers — onto
one logical CPU, where it fights itself. Results go bimodal (IPC 2.05 vs 2.65).

Always `taskset -c 1,9`: both logical CPUs of one physical core.

Everything measured before this was understood (the 53% / 63% / 75% figures) was
hyperthread-contended and is **unusable**.

## 5. `foreign%` and the SMT rule — assert sibling occupancy or the A/B is void

**A busy SMT sibling costs MAME 39%** (n=3, spread <1%). An unpinned competitor
manufactures a **~1.6× effect** — the same retraction class this project has hit
three times.

So both logical CPUs of the claimed pair are sampled from `/proc/stat` once a
second, and `bwin.py` reports **`foreign%`**: CPU burnt on the pair by anything
that is not the process under test. **It is a gate, not a decoration.** A window
with meaningful foreign occupancy is not a sample; discard it.

In the 2026-08-03 baseline three idle windows were discarded at 17.4 / 18.1 /
19.5% foreign. The load was not a sibling agent — it was **the harness itself**:
five concurrent runs plus unpinned `ssh`/`python3` pollers landing on the pairs.
**Poll less, or pin the poller**, when the deltas being chased are small.

Note that pinning is itself an aggravator: a pinned MAME cannot migrate away
from a collision.

## 6. Interleave arms; swap pairs between rounds; median of paired ratios

- **Interleave** the arms. Runs taken hours apart under different load produced
  a "frameskip 6 amplifies boot hangs" artefact that vanished the moment the
  cells were interleaved.
- **Swap core pairs between rounds.** Pairs differ by ~10% (2,10 measured ~10%
  slower than 3,11); alternating cancels it.
- **n ≥ 5**, report the **median of within-round paired ratios** with a CI —
  never raw means. Round-level outliers dominate the noise: one perturbed run
  moved an arm's mean by >10%.
- On a busy box, prefer **sequential arms taking turns on ONE claimed pair**,
  with the arm order alternating by round, over concurrent arms on two pairs.
  You can only assert occupancy on the pair you are actually running on.

## 7. Rank by SPEED, never by profile SHARE

A profile share is too noisy to attribute anything.

> The same configuration profiled **3 minutes apart** swung
> `code_compile_block`'s share from **61.2% to 75.9%** — 15 points — and the
> share was non-monotonic across DRC cache sizes.

The DRC-invalidation lead was pursued on a **23.5% share** that turned out to be
2–4% of host time in the active regime, and could not be reproduced in any
regime. Rank candidates by measured speed delta; use shares only to generate
hypotheses.

Corollary: **rank by TIME, not by instruction count.** Xsgi is 4.3% of guest
instructions and ~16% of host time (3.7× average); `bcopy`/`bzero`/`strcpy` are
3.84% of instructions and ~1.2% of host time, because they are kseg0, sequential
and DRC-cached — *cheaper* per instruction than average, the opposite of what an
HLE proposal needs.

## 8. `md5-at-a-fixed-emulated-timestamp` is INVALID for scheduler/timing changes

It is a good acceptance test for a change that must be bit-exact and does not
move emulated time (fastram, compiler flags, hugepages — all verified
byte-identical this way at t = 100–260 s).

It is **useless for anything touching the scheduler, timers or frameskip**:
under `-frameskip 6` the unmodified **control also snapshots black**, so the
test passes trivially, and a PIT-floor sweep produced non-monotonic md5s.

Use a **multi-sample framebuffer trace** instead. The PIT work's 78-sample,
3-boot trace is the model.

And verify pixel-identity only at **t ≤ 110 s**, inside the deterministic prefix
(see §3).

## 9. Verify on the framebuffer, and know what a full-frame statistic can say

> **A whole-frame mean/stddev is good for "is it black" and nothing else.**

Five "panics" were the park script misclassifying **healthy logins**: after
login the X root paints SGI blue and sits for minutes before 4Dwm draws the
Toolchest, and whole-frame statistics barely move across that (bare root mean
.578 / sd .157 vs desktop .580 / sd .163). The fix is a **content-based** test —
crop the Toolchest region, where sd separates 0.095 from 0.257, a 2.7× margin.

Known shm-mapping signatures (1288×1024, no borders, no resample):

| state | mean | sd |
| --- | --- | --- |
| `iconlogin` chooser (golden v7) | 0.702353 | 0.166836 |
| memory-diagnostic failure | 0.589366 | 0.188070 |
| black (VC2 hang, or nothing published yet) | 0.000000 | 0.000000 |

**These are shm numbers and are not interchangeable with X11-grab numbers.** The
x11 path scales the emulated frame into a 1272×954 window inside a 1280×1024
root with black borders; the chooser reads 0.658 / 0.226 there. Reusing the x11
thresholds on the shm path silently never detects the chooser.

Failure-mode discrimination, when a run goes wrong:

| symptom | verdict |
| --- | --- |
| pure black, mean 0, emulated clock advancing | VC2 black-screen boot hang |
| console text, mean ~0.40–0.58, sd > 0.15, clock advancing | `bad istack` panic |
| process gone, clock stopped | DRC segfault |

## 10. `perf stat -I` can stop emitting mid-run — detect truncation

Observed once in 12 runs: samples simply stopped. A partially-covered window
reads as **inflated speed**, silently. Check that the sample series spans the
window before trusting it.

## 11. Prefer uprobes on the shipped binary over an instrumented build

The shipped MAME binary is **unstripped with `debug_info`**, so kernel uprobes
count exact events on the *production* binary — no rebuild, no patch, no source
tree, and no code-layout confound between control and treatment.

`perf probe`'s own symbol resolution **fails** on this binary: it parses a C++
`::` as a line number. Write the probe by **raw ELF offset** instead:

```
p:group/name <path>:0x<st_value>   >  /sys/kernel/tracing/uprobe_events
```

> An instrumented MAME cost a **2.35× slowdown** and distorted every host-time
> number in that campaign.

Where a runtime switch is unavoidable, build **one** binary with all arms
selected at runtime (`IRIX_HUGEPAGE=off|ram|drc|both`) so control and treatment
share a code layout.

## 12. 100% reproducibility is a tell for a harness bug, not a finding

A "5/5 panic" that reproduced perfectly was the classifier, not the guest. A
real race does not reproduce 5 times out of 5. When a result is *too* clean,
audit the harness before writing it up.

Two more in the same family:

- **Something that "cannot be contaminated" usually can.** The 60-trial VC2 A/B
  was proven uncontaminated by grepping the rig for every input verb
  (`POST|CODE|IRIX_CMD|natkeyboard|set_value|ioport`) and finding none. Prove
  it; do not assert it.
- **When two agents disagree about what an image contains, check which image
  each one booted.** A "the demos are missing" regression report was one rig
  cloning the base CHD instead of the apps CHD.

## 13. Traps in the surrounding tooling

- **`git fetch --depth=N` makes the repo shallow**, after which `A..B` ranges
  and `merge-base --is-ancestor` are meaningless — a range reported exactly 50
  commits, which was the depth, and that should have been the tell. Always
  `git fetch --unshallow` before trusting ancestry. A shallow fetch also
  *degrades* a previously-full tree.
- **An uncompressed CHD is opened `O_RDWR` and `-diff_directory` is ignored**,
  and MAME runs as root so mode bits do not stop it. This was the dominant noise
  source in an entire campaign: boot-workload instruction σ fell from 25 G
  (4.5%) to **3.1 G (0.5%)** once the master was made immutable (`chattr +i`)
  and each run got a `cp --reflink` copy. At one point three MAME instances were
  writing the same CHD concurrently.
- **Everything must be per-clone**: `disk.chd`, `diff/`, `nvram/`, the command
  file, the agent log. Clones sharing a write overlay and a command channel
  cross-destroyed each other, one `rm -rf`-ing another's overlay into a fake
  `vfs_mountroot` panic.
- **Confirm the flag reached the compiler, not just `make`.** `ARCHOPTS` is a
  silent no-op without `REGENIE=1`; the null result for `-march=native` is only
  trustworthy because the native binary was shown to contain 12,968 AVX-512
  instructions against the control's 0.
- **Check Lua return values** — a call to a non-existent method is silent here.
  `manager.machine:pause()` does not exist in this MAME's Lua API, and the
  unchecked nil return produced an entire "the cache may serve stale frames"
  scare: the machine was never paused, so two "paused" snapshots differing by
  1.3 M pixels were just a guest booting between them.

## 14. Say which regime you are claiming

The exhibit runs **throttled** (`x11-runtime.sh` passes no `-nothrottle`), which
clamps every regime at 100% of real time. **A gain in any regime already at or
above 100% buys host-CPU headroom, not visitor-visible speed.**

The bench rig adds `-nothrottle` on purpose — a throttled run cannot measure a
speed at all in the regimes that matter — and offers `--throttle` when the
shipped behaviour is what is wanted. State which one you measured, and which one
you are claiming.

Note also that the worst case is W1 (terminal scroll), not W2 (drag): **dragging
makes the emulator faster** (median paired W2/W1 = 1.47×, n=10) because the
window manager's grab stalls the scrolling client. Never count W2 as headroom.

## 15. Stack, never sum

Sub-additive effects are the norm here — the DRC-churn lead and the PIT fix
attack overlapping cycles, P3 idle-loop elision competes with DRC fastram (both
attack the idle spin's `lw`), and P1 competes with GFIFO back-pressure. Measure
the **stacked** configuration; never add two independently measured percentages.

---

## Checklist for a performance claim

A result that does not carry all of these is not comparable to anything in this
repo:

- [ ] cycnorm%, **and achieved GHz beside it**
- [ ] `foreign%` on the claimed core pair, for every window
- [ ] within-run windows, with the emu-time trace they came from
- [ ] full core pair, pairs swapped between rounds
- [ ] interleaved arms, n ≥ 5, median of paired ratios + CI
- [ ] which regime, and whether the tile is throttled there
- [ ] a framebuffer verification appropriate to the change (multi-sample trace
      if it touches timing)
- [ ] discarded runs listed with the reason (clock out of family, foreign
      occupancy, boot hang), not silently dropped

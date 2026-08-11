# IRIX station — the closed register

Every performance angle that has been **measured and closed**, with its
mechanism and its ceiling. The point of this file is that nothing here gets
re-tried: each entry cost real time to settle, and several of them look
attractive right up until the mechanism is understood.

Re-opening an entry needs a **new hypothesis about where the cycles would come
from**, not a new attempt at the same idea.

Measurement rules and the metric: [MEASUREMENT-METHODOLOGY.md](MEASUREMENT-METHODOLOGY.md).
Baseline numbers: [irix-baseline-2026-08-03.md](irix-baseline-2026-08-03.md).
Full build/station record: [../guests/irix.md](../guests/irix.md).

---

## Reopened — read this first

**The REX3 rasteriser was closed in error, and it is the biggest single item in
the project.**

The earlier closure — "rasterisation ceiling ~1.4%, 86.7% of frames already
cached" — was about **scan-out** (`newport::screen_update`, 3.2% at the time)
and was wrongly generalised to the **rasteriser** (`do_rex3_command`). They are
different code paths with different costs.

Measured causally afterwards:

- **stubbing `do_rex3_command` gives a 4.16× within-run speedup** (n=3)
- **REX3 is 73.1% of host cycles** in a saturated terminal scroll
- `screen_update` is separately 29.9% under pointer motion

The work item is a span fast path batching the per-pixel loop in
`do_rex3_command` / `logic_pixel` / `write_pixel`: ceiling 34% on scroll, 17% on
Netscape; realistic +20% / +10%; ~8 days, most of it the **bit-exactness
matrix** (4 masks × 16 logic ops × 4 depths × blend/fastclear/shade/pattern).
Zero fidelity cost *if* bit-exact; the risk is silent divergence in a mode the
fast path wrongly claims.

Two things already disproven about it, so nobody re-derives them: the guest
submits **738–823 px per REX3 command, not 32-px spans** (there is nothing to
batch on the submission side), and MMIO dispatch is <0.2%. GIO64 double dispatch
is real but only ~0.18%.

**Lesson worth carrying beyond IRIX:** a closure is only as wide as the thing
that was actually measured. Name the function.

---

## The guest side contributes ~0 — structurally, not by profile

**The exchange rate is 0:1, not 1:1.** Deleting guest work converts a work
instruction into an idle-spin instruction one for one, and the only prize is the
*cost difference* between them (~0.5–1.2% of host time).

Mechanism, and it is structural:

- IRIX has no halt instruction.
- `mips3fe.cpp:71-73` charges ~1 cycle to nearly every instruction.
- MAME's MIPS3 core **no-ops `WAIT`** (`mips3.cpp:2156`, `mips3drc.cpp:2834`) —
  there is no `spin_until_interrupt` / `eat_cycles` / suspend path.

So the guest executes a **constant 1.11–1.20e8 instructions per emulated
second in every regime** (7.4% spread) while host cost per emulated second
varies 2.26×.

| angle | verdict |
| --- | --- |
| HLE of `bcopy`/`bzero`/`strcpy` | 3.84% of instructions, ~1.2% of host TIME — kseg0, sequential, DRC-cached, so *cheaper* per instruction than average. The opposite of what an HLE proposal needs. |
| syscall / exception / poll HLE | ~7–10%, but only by patching IRIX exception vectors |
| `fasthz` (guest tick rate) | ≤1.35%; point estimate 0, measured at 5× amplification |
| `tlbdrop` | 0 |
| guest scheduler tunables | ~0 by construction — the machine is a uniprocessor |
| rc2/inetd trimming, daemon removal, kernel/XFS/swap tuning | ~0 in every regime. The idle IRIX guest does literally nothing: 100% idle, 2 ctx-sw/s, zero measurable process CPU over 90 s, ~200 MB of 256 MB free, swap untouched. |

**Concentration turned out to be the wrong question.** Idle and Netscape are
89–99% concentrated in six kernel idle-loop routines — maximally concentrated,
and HLE has nothing to replace them with.

---

## Host-side: closed with mechanism

### Build and memory

| angle | ceiling | mechanism |
| --- | --- | --- |
| **`-march=native`**, **`LTO=1`** | **null** | Paired within-round ratios, n=6/arm, two independent datasets; the sign of the idle delta flips between them. The native binary really does contain 12,968 AVX-512 instructions (control: 0) and renders a byte-identical framebuffer — the code changed a lot without retiring faster, exactly what a memory-bound profile predicts. Rules out effects >±3%. |
| **Hugepages** (`madvise`, per-process) | **~1%** | Boot +1.71%, transition +3.29%, **idle +1.22% (CI −0.7…+2.2)** — and idle is the station's operating regime. The counters close the door independently: hugepages *halve* the walk rate at boot (dTLB 0.080→0.040, iTLB 0.105→0.040 walks/Kinstr) yet total page-walk cycles only fall **2.93%→1.87%**. The whole prize is ~2–3% of cycles even if every walk were eliminated. |
| **DRC cache beyond 256 MB** | **negative** | 256 MB is a **knee, not a ramp**: 1 GB measured 126.7% against 256 MB's 130.4%. |

Two hugepage mechanism traps, both of which block the naive attempt: MAME maps
the DRC cache `MAP_ANON|MAP_SHARED` (`osdlib_unix.cpp do_alloc`) — a shmem
mapping, so `MADV_HUGEPAGE` is **silently ignored** under the default
`shmem_enabled=never`; and guest RAM is `std::make_unique<u8[]>`, i.e.
value-initialised, so every 4 KiB page already exists before any `madvise` and
you need `MADV_DONTNEED` after it to force a re-fault.

### DRC

| angle | ceiling | mechanism |
| --- | --- | --- |
| **Parallel DRC compilation** (front/back-end split) | **<1%** | Compilation is **synchronous on the critical path** (`mips3.cpp:5360-5372` compiles where the guest faulted). There is nothing to overlap with. |
| **Speculative compilation** | 1–3% | The front end is a 640-byte window sweep (`drcfe.ipp:88-89`) terminating at every indirect branch — and every MIPS return is `jr $ra`. There is no CFG to walk ahead. |
| **Persistent cross-boot code cache** | 0–2% | Needs `MAP_FIXED` + non-PIE + pinned allocations + a relocation scheme, and every user-space block fails its vtlb guard on a fresh boot anyway. |
| **ASID in the DRC hash key** | **0.1%** | 98.7% of re-compiles are the same virtual PC on the same physical page, 97% at the same guest ASID, and the vtlb word at recompile is **bit-identical to the one baked into the failing guard in 14,748/14,748 cases**. |
| **"Just widen the DRC mode field to carry an ASID"** | TRAP | `drc_hash_table` allocates a 2^15-pointer (256 KB) L1 per populated mode (`drcbeut.cpp:68-73`). A full 8-bit ASID is **64 MB of L1 tables** before any generated code, inside a 256 MB cache already at its knee. |
| **Memoising (mode, pc, vtlb word) → codeptr** | subsumed | The vtlb word *is* `pfn\|flags`; if the churn lead lands, this is worth ~0. |
| **Bounding the `override` re-emit cascade** | **correctness hazard** | Refuted on a false premise. The vtlb guard is gated (`mips3drc.cpp:1390`) and `validate_tlb` is set only for the window head and page-crossing targets, so non-head sequences carry no guard and cannot fault themselves. Removing the blanket override lets a fresh head fall into code translated from another process's PFN with a checksum that still passes — **silent wrong-code execution**. |
| **Sweeping the compile-window constants** | inverts its own goal | The backward window is not swept (`drcfe.ipp:83-85,111`); zeroing `COMPILE_BACKWARDS_BYTES` makes every backward branch fail the `targetpc >= minpc` guard, converting every hot-loop back-edge from `UML_JMP` to `UML_HASHJMP`. |
| **MIPS3DRC option flags** | already fastest | `m_drcoptions = 0` (`mips3.cpp:182`) and the Indy driver's only `mips3drc_set_options` call is commented out (`indy_indigo2.cpp:278`). Every flag can only slow it down. Do not bench them. |
| **QEMU victim TLB / dynamic TLB resizing** | **zero transfer** | mips3 calls only `set_vtlb_fixed_entries` (`mips3.cpp:216-221`) ⇒ `m_dynamic == 0`. The structure is a flat 2^20-entry, 4 MB eager shadow page table: no misses, no associativity, no sizing policy to tune. |
| **Host-MMU / shadow-page-table schemes** (ESPT/HSPT/Captive, up to 5.88× in the literature) | **zero transfer** | They remove a software page walk MAME does not perform. Ours is one load, a test and a `rolins` (`mips3drc.cpp:1017-1021`). |
| **Indirect-branch dispatch re-engineering, on prediction grounds** | closed by literature | Rohou/Swamy/Seznec CGO'15: ITTAGE makes indirect-branch prediction non-critical. MAME emits one hashjmp per exit *site* and the immediate-PC case is a monomorphic `jmp [const-slot]`. The variable-PC cost is a dependent **load chain** (`drcbex64.cpp:2128-2135`) — latency, not prediction. |
| **Context/direct threading, superinstructions** | not applicable | They fix a bytecode interpreter's dispatch loop. MAME JITs; there is no dispatch loop. |

Already good, stop re-proposing: flag liveness (`drcuml.cpp:401-450`, moot —
MIPS has no flags), direct block chaining (`drcbex64.cpp:2117-2124`), intrablock
loop linking (`drcfe.ipp:132-137`), delay-slot IR inlining
(`mips3drc.cpp:1444-1495`, better than QEMU's runtime scheme), lazy device
evaluation, code alignment, near/transient cache split, interrupt-check density
(steady-state guest code contains **zero** interrupt checks), W^X (rwx is the
default). The emitted ALU code is fine; there is no peephole pass worth writing.

**Caveat on every compile-side number:** the 23.5% `code_compile_block` share is
an **idle** measurement, and idle runs at 130–156% where the share means little.
The compile share in the active regime has never been measured.

### Timers, scheduler, devices

| angle | verdict |
| --- | --- |
| **Scheduler quantum** | Cannot be raised. Already 16.67 ms (`schedule.cpp:796-808`), `add_quantum` can only *lengthen* (`:582`), and `ts_calls == inner_iters` exactly (18,694,128 == 18,694,128) — every timeslice ends on a timer expiry, never on the quantum. |
| **Timer wheels** | ~10 active timers. O(n) over 10 is dwarfed by the DRC exit each event costs. **Attack the event RATE, never the per-event cost.** |
| **MC DMA "33 MHz timer pump"** | False alarm. `perform_dma` runs the whole transfer in one callback then sets `attotime::never` (`mc.cpp:311-318`). |
| **The HPC3 audio-DMA storm** | **Does not exist.** 0 expiries/emu-s at idle and during scroll; 614/s across a boot only. `-sound none` has nothing to fix here. Sound overall is <1% of host time and is not where the problem is. |
| **`generate_update_cycles` per-memory-op icount RMW** | Ranked out, not missed: ~3 host instructions of the ~30 the memory path costs, and it cannot move — a memory access can raise an exception needing an accurate icount. |
| **`-ioc2:kbd ""`** | **INVALID.** IRIX refuses to boot the desktop without a keyboard — framebuffer-proven, *"Cannot connect to keyboard -- check the cable"*. The 1.5× it appears to buy is the two arms doing different guest work. The two emulated MCUs (I8042AH at 800k cycles/s, plus a real I8051 inside the Microsoft Natural keyboard at 500k) **are** worth 2.2–3.0%, but the fix is HLE behind `pc_kbdc` — the PS/2 mouse on this machine already is one — not deleting the device. |

### Display path

| angle | verdict |
| --- | --- |
| **Guest display-path / Newport dirty-rectangle tracking** | **CLOSED. Do not reopen.** The per-row/hybrid cache was built, proven correct over 51,000 consecutive frames with 0 stale, and measured **worthless end-to-end**: active +0.4%, idle −1.5% (n=6 interleaved rounds, pairs swapped). Branch `irix-newport-per-row`, patch `scripts/build-guests/patches/mame-newport-per-row-dirty-cache.patch`. Not promoted. |
| **`-frameskip` beyond fs6** | Ceiling **0**. fs6 is shipped and its +18% is already inside the baseline; the MAME-side present path does not exist under `-video none` with `DISPLAY` unset. (Also: `newport.cpp:4505`'s 60 Hz is only the power-on default — VC2 re-derives ~72 Hz at `:1743-1744`, so any 60 Hz frame arithmetic is 20% off.) |
| **Micro-optimising Newport's inner loop** | Proven dead: cursor-hoist and RAMDAC-identity fast paths cut instructions 10.6% for **0.0% time**. Newport is MEMORY-bound — ~15.7 MB/frame at ~72 Hz, ~1.1 GB/s. |
| **Terminal-window size as a lever** | Cost scales as **area^0.18, not linearly** — the scroll self-throttles, so shrinking the window makes the guest immediately draw 18.5% more lines. Reaching 100% this way needs a ~10-cell terminal. Scrollback (`-sl 0`) is a measured null (+2.4%, CI spans zero). |

The premise the display work was built on was false, and that is the durable
part: the standing model said the whole-frame cache collapses to fs6-only during
interaction, so the active regime is where the headroom is. `IRIX_CACHE_STATS=1`
on a live desktop says otherwise — during a terminal scrolling `find /usr
-print`, 1,500 frames were **86.7% served from cache**; a continuous pointer
sweep, 1,000 frames, **92.8%**. The emulated Indy simply cannot repaint at
36 Hz. Optimising the remaining 13% was arithmetically incapable of mattering.

### Host platform

| angle | verdict |
| --- | --- |
| **Turbo bins** | Real physics, unreachable prize. MSR 0x1AD = 3.0 / 2.8 / 2.5 GHz at 1 / 2 / 3+ active physical cores; labhost never leaves the bottom bin (2.471–2.502 GHz in all 24 windows) because **streamhost's own x264 encoder smears 1.07 cores over all 8 physical cores at 30 Hz** — pinning the package in the 3+-core bin exactly when a visitor is watching. Fragility worth a health-check assertion: MSR 0xCE max non-turbo is 2.3 GHz, so if turbo is ever disabled the station loses ~7% for free. |
| **Speculative-execution mitigations** | ≤0.9%, and ≤0.15% after the sysfs fix. SSBD/STIBP are prctl-gated and off for MAME. C-states, uncore frequency, NUMA, PVE/cgroup placement, `nohz_full`/IRQ steering — all bounded near zero. |

### Alternative vehicles — closed permanently

**IRIS** (techomancer/iris) boots our unmodified seed to the X root and
delivers **1/9 of MAME's cycle-normalised rate while burning 2.2–2.9× more host
CPU**; its Cranelift MIPS JIT engaged on 0.6% of instructions.

**QEMU has no SGI IP22/IP24 machine and never has.**

And the arithmetic bounds any future vehicle: only ~46% of host time is
guest-CPU work, so even a magic 3× CPU gives 1.44× overall.

### Networking — slirp4netns and pasta

Both are dead ends for the CRIU work, on a criu rule about tun/tap fds, and both
are *slower* than kernel veth + NAT (pasta by 50%). Full mechanism and the
measured throughput table:
[`scripts/build-guests/irix/irix-criu/README.md`](../../scripts/build-guests/irix/irix-criu/README.md).

---

## The ceiling, and what is left

**100% real time is unreachable by emulator optimisation.** Reaching it from a
45.6% terminal-scroll baseline needs +119%; the full stackable host-side program
is worth roughly +18–22% relative, and the guest side contributes ~0.

The AT-100 campaign found three real, orthogonal wins that do not contend:

| win | W1 terminal scroll | note |
| --- | --- | --- |
| PIT 8254 idle-mode fix + explicit 16 µs quantum | **+39%** (W2 +31%, idle +67%) | biggest single win; see [irix-pit-quantum-2026-08-03.md](irix-pit-quantum-2026-08-03.md) |
| MIPS3 fastram for Indy RAM | ~+9% | **BLOCKED** in production — fails IRIX's own memory diagnostic with the station's serial port present |
| terminal default 80×40 → 80×24 | +8.0% (CI +5.3…+12.2, n=10) | a default, and it evaporates if a visitor resizes |

Stacked W1: central ~74.5%, honest floor ~61%, ~83% if every remaining small
lever lands. W4 (idle) stacks past 250%. **W3 (Netscape) probably already
passes** — two independent results say Netscape on a rendered local page costs
zero over idle (5.05 vs 5.05 Ginstr/emu-s); it is the cheapest open measurement
left.

Remaining candidates at realistic, not ceiling, values: the REX3 span fast path
above, lazy/ASID-filtered vtlb remap (~4.7%), sysfs memoization 3–5%, upstream
DRC reuse cache + `VTLB_MAPPING_MASK` 2–4%, PGO+BOLT 3–6%, mapvar memoize 2–4%.

**Sound is not solved by reaching 100%** — audio decoupling was dropped by user
decision on 2026-08-03; do not propose it again.

---

## Open leads, recorded so they are not lost

- **A persistent post-visitor slow state.** After a visitor uses a terminal the
  guest enters a state with 147–166k ASID+`tlbwi` events/emu-s — *higher* than
  during the scroll itself — while IRIX's own `sar` reports the machine idle,
  cutting speed from ~85% to ~42% for at least 10 minutes. Never appears on a
  freshly parked desktop (35–80/s). It did not reproduce in a dedicated rig
  ([irix-post-terminal-slow-state.md](irix-post-terminal-slow-state.md)). If it
  is real, **every benchmark in this project may be measuring a state visitors
  never experience.**
- **MAME emits no perf jitdump / `/tmp/perf-<pid>.map`.** 71.7% of active-regime
  time is one anonymous blob. `mips3drc` knows `seqhead->pc` and
  `drcbe_x64::emit` knows base+size (`drcbex64.cpp:1246-1283`). Speed ceiling
  0% — **build it anyway.** A flat unsymbolised profile is exactly the condition
  under which this project invented three false causes.
- **An exhibit-facing freeze.** A parked, idle, logged-in 4Dwm desktop on a
  clone of the shipped checkpoint with the shipped agent **froze after ~7 minutes**:
  emulation still advancing, framebuffer byte-identical across samples, pointer
  dead. Distinct from the black-screen boot hang, and it is exactly what a
  visitor sees as a dead exhibit.

# Server capture cadence, frame pacing, and loaded-tail research

**Status:** brainstorm/research only; no production change was made. This note
deliberately excludes BGRA-to-I420 SIMD and damage/ROI encoding, which are separate
workstreams.  Measurements and code paths refer to the Solaris latency profile unless
stated otherwise.

## Conclusion

Idle is already good.  The 4 ms QEMU display scan contributes about 2 ms on average
and at most one scan period to an isolated change; lowering it can recover only about
1 ms more.  The real-session problem is the loaded tail: full-fleet contention turns
an approximately 6 ms quiesced x264 wall span into roughly 96 ms at p95 even though
the calling encode thread consumes only a few milliseconds of CPU.

The first experiment should therefore be the already-prototyped **short EEVDF request
slice** for the encode thread and its x264 sliced-worker pool.  It stays in
`SCHED_OTHER`, directly targets wake-to-run delay, and has synthetic A/B evidence.
The second should be a **viewer-aware fleet encode budget**: retain 60 fps for the
foreground tile, cap gallery thumbnails at 10--15 fps, and stagger their refresh
IDRs.  Scheduler policy cannot manufacture CPU capacity when 28 full-frame encoders
are runnable at once.

## What the current gates actually do

1. QEMU's D-Bus display listener is timer-driven. `SH_DBUS_UPDATE_MS=4` calls
   `graphic_hw_update()` at about 250 Hz while the guest is running. A completed guest
   redraw therefore waits 0--4 ms, about 2 ms on average, before `UpdateMap`/`Update`
   reaches streamhost. Paused guests fall back to the stock 30 ms tick.
2. Each D-Bus update increments `FrameState.gen` and notifies the capture-to-encode
   task. Damage rectangles are not retained by this path.
3. streamhost enforces `min_interval = 1 / SH_FPS` between feeds. At `SH_FPS=60`
   that is 16.67 ms. If damage arrives sooner, the task sleeps to the boundary and
   snapshots the newest full frame. The observed approximately 48 fps is an effective
   result of damage cadence plus work, not a separate hard-coded 48 fps setting.
4. The dedicated encoder has a depth-one, latest-wins handoff. A pending frame can be
   replaced and a forced-IDR bit is sticky, but an x264 call already in progress
   cannot be cancelled. This bounds queue depth; it does not prevent CPU saturation.
5. While watched, a heartbeat wakes the feed at least every 500 ms. The worker forces
   an IDR 2.5 seconds after the last emitted IDR. Joins and large scene changes can
   force extra IDRs.

This resolves an important regime distinction in the profile. The 4.1/7.8 ms
`capwait` p50/p95 was measured during continuous drag. After a long quiet interval,
the rate cap is already expired, so an isolated move normally pays only the next D-Bus
scan (about 2 ms mean, 4 ms worst) plus dispatch. A rate-cap bypass mostly helps
sustained interaction, not the first isolated event.

## Why loaded tail outranks another idle millisecond

The quiesced 1920x1200 component profile was snapshot 2.05 ms, scene detection
0.24 ms, conversion 6.56 ms, and x264 5.20 ms wall (about 2.4 ms on the calling
thread). As an engineering service-demand estimate, treat the quiesced single-thread
snapshot/scene/conversion spans as CPU and add only that observed x264 caller CPU:
about **11.25 CPU-ms per frame**. This omits x264 pool-thread CPU, although any
unobserved preemption inside the wall spans pushes the estimate in the other direction;
the next profile must measure both explicitly.

At the observed 48 fps, one Solaris-class active tile is therefore roughly
`11.25 ms * 48 = 0.54` logical CPU by this proxy. Twenty-eight such streams are
**15.1 CPU equivalents on a 16-logical-CPU host**, before x264 pool work, QEMU vCPUs,
D-Bus, network, or the rest of the daemon. Saturation and a long run queue are the
expected result, not an anomaly. At 15 fps, the same estimate is **4.7 CPUs
fleet-wide**, a 69% reduction or roughly 10.4 CPU equivalents released. Real tiles
have mixed resolutions, so this is a Solaris-class stress model rather than a fleet
forecast; the exact core count needs aggregate thread-CPU measurement.

Historical loaded A/B data reinforces the diagnosis:

- `SH_ENC_NICE=5`, `0`, and `-10` all left the tail in place. Baseline snap-to-AU
  p95 subwindows ranged from 49--287 ms; nice 0 ranged 68--331 ms; nice -10 ranged
  110--183 ms. CPU per frame stayed essentially unchanged.
- Main's `config.rs` records loaded x264 p95 reaching about 96 ms while caller CPU
  remains about 1 ms in that older canary. The reclaimable scheduler-wall ceiling is
  therefore roughly **90 ms** versus the quiesced x264 p95 near 6 ms. That is a
  ceiling, not a promise: percentile populations and IDRs must be separated in the
  next run.
- The handoff queue was only 16/23 microseconds p50/p95 in the quiesced profile. The
  tail is not an application queue waiting behind old frames; it is wake-to-run and
  sliced-worker fan-out/join delay inside the encode span.

### Current host facts (read-only inspection, 2026-07-16)

The box is an 8-core/16-thread Xeon D-2146NT running `7.0.14-4-pve`. EEVDF features
`RUN_TO_PARITY` and `PREEMPT_SHORT` are enabled and the base fair-class slice is
2.8 ms. The host uses cgroup v2. `streamhost@solariscde` has `Nice=5`,
`CPUWeight=100`, no CPU affinity or quota, `LimitRTPRIO=0`, and QEMU plus streamhost
live in the **same service cgroup**. Consequently:

- another nice value is not worth pursuing; the direct experiment already failed;
- `ionice` does not target this memory/CPU hot path;
- changing the current unit's `CPUWeight` or `AllowedCPUs` affects QEMU and streamhost
  together, not the encode thread in isolation;
- a useful cpuset design must first split QEMU and streamhost into sibling cgroups, or
  set thread affinity inside streamhost and separately constrain QEMU.

Linux documents that EEVDF gives shorter requested slices earlier virtual deadlines
and permits applications to request a slice with `sched_setattr()`
([EEVDF scheduler](https://docs.kernel.org/scheduler/sched-eevdf.html)). The current
kernel's `PREEMPT_SHORT` feature makes this a better first move than real-time policy.

## Ranked ideas

Sorted by expected saving divided by implementation/operational effort. "Idle" means
one interactive tile on a quiesced host; "loaded" means a gallery/full-fleet run
queue. Savings are server-side wall time and must be validated A/B/A.

| Rank | Idea | Idle perceived impact | Loaded-tail impact | Effort | Confidence / principal trade-off |
|---:|---|---|---|---|---|
| **1** | Port the 600 us fair-class EEVDF slice prototype to current main; apply before `x264_encoder_open` so the sliced pool inherits it | ~0--3 ms; little reason to alter the already-good idle path | **Expected tens of ms; ceiling ~90 ms at x264 p95.** Directly attacks wake/fan-out/join queuing | Low--medium: focused code already exists in commits `131d6b6` and `71998d9` | Medium. Synthetic same-core A/B improved wake delay p50 2167→600 us and p99 5611→3154 us at a 600 us slice; it has not had a clean full-fleet x264 A/B |
| **2** | Viewer-aware encode budget: foreground 60 fps; grid/background 10--15 fps; aggregate the maximum requested role per tile | Foreground unchanged; thumbnails trade cadence for capacity | **69% less per-frame work at 15 vs 48 fps; Solaris-class demand proxy 15.1→4.7 CPUs for 28 streams** | Medium: add session role/desired fps and dynamic feed interval | High on work reduction, medium on exact p95. This fixes overload rather than merely prioritizing through it |
| **3** | Demand-driven IDRs plus tile-hashed staggering; retain a longer safety heartbeat | Median unchanged; removes the visible ~90 ms 2.5 s hitch from sparse interaction | Prevents simultaneous multi-tile IDR storms; a 10 s safety interval cuts heartbeat IDRs 75% | Medium: add client keyframe request and preserve recovery watchdog semantics | High that work/spikes fall; recovery behavior is the risk. Do not simply lengthen the interval without client feedback |
| **4** | Split QEMU/streamhost cgroups and reserve 1--2 physical cores (both SMT siblings) for latency-critical capture/encode work | Small; quiesced cores were already available | Can bound cross-QEMU run-queue delay if the reserved set is sized for active encoders | High operational effort; costs 12.5--25% of the host's physical cores | Medium-high. Start with runtime cgroup-v2 cpuset partitions, not a boot-time `isolcpus` change; capacity/admission is still required |
| **5** | Bounded `SCHED_RR` priority 1 canary, or `SCHED_DEADLINE` with explicit runtime/period, only after fair-slice/cpuset tests | Near zero | Potentially removes most fair-class queuing | Medium code, high safety/ops burden | Low as a fleet default. Twenty-eight RT x264 pools can starve the QEMU class; the host's global 95% RT throttle is far too permissive to be the safety case |
| **6** | Event-driven QEMU dirty emit with a coalesced bottom-half and a 1--2 ms minimum interval | About **1--2 ms p50**, at most ~4 ms worst-case capture wait | Neutral only with a budget; otherwise extra wakeups can worsen the 96 ms tail | High: shared QEMU display/dirty path | Medium. Correct trigger is framebuffer dirtiness, not the input event itself |
| **7** | Input-coupled short fast-poll window, then let the first post-input generation consume one urgent feed token | About 1--2 ms for input-caused changes; safe fallback remains 4 ms | Neutral/negative without foreground-only gating | Medium | Medium-low. More contained than a global dirty hook, but an immediate snapshot can precede guest paint |
| **8** | Allow one foreground urgency token to reset the streamhost rate-cap phase | Isolated event: approximately zero (cap already expired); continuous drag: perhaps 2--4 ms | Can increase work and worsen scheduler tail | Low--medium | Medium. Enforce a token bucket and never create a second in-flight encode |
| **9** | `SH_DBUS_UPDATE_MS=4→2` on the foreground tile only | Direct poll mean ~2.2→1.1 ms; prior FreeDOS inject-to-wire p50 11.4→8.4 ms | Likely negative: doubles scans to ~448/s; prior p95 worsened 24.5→29.0 ms | Trivial knob, nontrivial fleet cost | High that the median gain is small and diminishing. Do not deploy fleet-wide before loaded-tail work |
| **10** | x264 periodic intra refresh / reference invalidation instead of heartbeat IDR | Can spread a 90 ms spike over several frames | May smooth bursts but not reduce full-frame conversion and complicates multi-client recovery | Medium--high, server+wire+client validation | Low-medium. Useful only after feedback-driven refresh; not a clean fresh-join replacement |

### Ideas to reject or demote

- **Nice/CPUWeight:** nice -10 was already inert. `CPUWeight` changes long-run share,
  while the measured failure is wake latency; the current unit also contains QEMU.
- **ionice:** no disk I/O sits between snapshot and AU.
- **CPUQuota on the interactive service:** periodic cgroup throttling creates another
  tail. Budget work by fps/resolution/admission instead.
- **Raise `SH_FPS`:** it may reduce continuous-drag phase wait when idle, but increases
  scan/snapshot/encode pressure exactly where loaded p95 is broken. Keep 60 for the
  selected tile and lower background work instead.
- **Permanent `SCHED_FIFO`:** a blocked healthy encoder looks safe, but one spin or a
  large set of simultaneously runnable pools can monopolize CPUs. Linux explicitly
  warns that unbounded FIFO/RR/deadline threads can block normal threads and describes
  `RLIMIT_RTTIME`/RT throttling as safeguards, not latency guarantees
  ([sched(7)](https://man7.org/linux/man-pages/man7/sched.7.html)).

## Recommended first two

### 1. Re-canary the short EEVDF slice under the real fleet load

Do not resurrect the combined cold-boot branch wholesale. Port only its `SchedAttr`
and scheduler-mode plumbing from `131d6b6`/`71998d9` onto current main, default off.
Test `off`, 600 us, `off` in interleaved windows, with the current kernel and a
Solaris-class foreground workload. Apply the attribute to `sh-encode` before the
first x264 open so all sliced workers inherit it.

Separate ordinary P frames from IDRs in the report. Record capture snapshot, handoff
queue, conversion, x264 wall, x264 caller CPU, snap-to-AU, coalesced frames, guest
vCPU latency, and host CPU pressure. A useful promotion gate is at least a 3x loaded
x264-p95 reduction (approximately 96→32 ms or better), under 1 ms idle-p95
regression, and no material guest p99 or frame-delivery regression. If 600 us moves
the median but not p95, try 200 us only as a canary; retain fair class throughout.

This is the best saving/effort bet because the host already exposes custom slices and
`PREEMPT_SHORT`, and the abandoned prototype proved the attribute was inherited and
read back on all nine encode/pool threads. It is still research evidence, not a fleet
result.

### 2. Put a hard budget on simultaneous full-frame encoders

Use a session role or desired-fps control: selected/fullscreen viewers request 60,
grid tiles request 10--15, hidden tiles request zero, and the one shared per-tile
encoder uses the maximum requested role across its sessions. Receiver gating already
makes zero-session cost nearly zero; the missing state is *low-priority visible
thumbnail* versus *interactive foreground*.

Start at 15 fps for grid tiles. The Solaris-class service-demand estimate releases
roughly 10.4 logical CPU equivalents when 28 streams are active, while a selected
tile retains today's idle latency. Report foreground p50/p95/p99 while opening 1, 7,
14, and 28 grid streams; the success condition is that foreground p95 stays near its
quiesced floor rather than scaling with tile count. Add admission or step grid fps
down further when host CPU pressure says the budget is exceeded.

This change should also own IDR concurrency: cached IDRs can paint thumbnails
immediately, while fresh join IDRs are released through a small tile-hashed/tokenized
window. That prevents the load-control system from undoing itself with a burst of
simultaneous keyframes.

## Capture-cadence design

"Capture immediately on input" is unsafe as written: injection completes before the
guest necessarily redraws its software cursor, so the immediate snapshot may encode
the old pixels. Couple input to the **first later framebuffer generation** instead:

1. At input injection, record generation `G` and set one foreground urgency intent.
2. QEMU either emits directly from the actual dirty path, or temporarily scans at
   1 ms until damage is found or the normal 4 ms deadline expires.
3. Only an update with `gen > G` consumes the urgency intent.
4. It may reset feed phase once, subject to a minimum urgent interval and an idle
   handoff; otherwise latest-wins coalescing proceeds normally.
5. Coalesce to one outstanding bottom-half/timer per console. A busy guest never
   schedules one callback per write or one encode per input event.

The QEMU dirty-driven version is cleaner because it fires when pixels exist and also
helps non-input UI changes. Its rate limiter is mandatory: `CAPTURE-FASTPOLL.md`
already showed that even a cheap unchanged scan becomes meaningful fleet work, and
an event storm can starve encode/QEMU main-loop progress. Pursue this only after the
loaded CPU budget is working; its approximately 1--2 ms median opportunity is much
smaller than the loaded scheduler tail.

For CPU isolation, prefer runtime cgroup-v2 isolated partitions, which the kernel
recommends over the less flexible boot-time `isolcpus` interface
([CPU isolation](https://docs.kernel.org/admin-guide/cpu-isolation.html),
[cgroup v2 cpuset partitions](https://docs.kernel.org/admin-guide/cgroup-v2.html)).
Because capture currently runs on the Tokio pool, precise pinning would require a
dedicated capture/snapshot thread; pinning the whole daemon also pins transport and
control tasks. The encoder thread can set its affinity before x264 open so the pool
inherits it.

## IDR policy

The current heartbeat is expensive for a damage-gated desktop. At low activity the
500 ms feed heartbeat produces about two frames/s and a 2.5 s IDR is roughly one of
every five frames, even though under a 48 fps drag it is under 1% of frames. Thus IDRs
barely move the continuous-drag p95 but cause a visible approximately 90 ms periodic
hitch during sparse real use.

At the Solaris measured 1--2 MB per IDR, 28 synchronized IDRs are 28--56 MB. Merely
serializing that burst on 1 GbE takes roughly 224--448 ms, before encode scheduling.
If every watched tile emitted a Solaris-class heartbeat independently, 0.4 IDR/s per
tile is 11.2 IDR/s fleet-wide. Mixed resolutions lower the actual bytes, but the
reason to stagger remains.

Recommended transition:

1. Preserve immediate on-connect and scene-change IDRs. The cached IDR already gives a
   joiner an instant primer.
2. Use the reserved reliable urgent-control input class for a PLI-like keyframe
   request on WebCodecs error, detected frame-id gap, or silent decoder rebuild.
3. After that feedback path is proven, increase the safety heartbeat to 10 s (the
   current clamp maximum) or make it health-driven. Ten seconds cuts periodic IDR
   work 75% while retaining a bounded fallback.
4. Hash the safety phase by tile and rate-limit fresh background join IDRs globally.
   Foreground joins remain immediate.

x264 does support `b_intra_refresh`, `x264_encoder_intra_refresh()`, a larger DPB, and
`x264_encoder_invalidate_reference()`. These are designed for interactive loss
feedback. H.264 gradual recovery also requires parameter sets and recovery-point
signaling, and a decoder may need several frames before it is fully recovered
([RFC 6184 section 8.5.2](https://datatracker.ietf.org/doc/html/rfc6184#section-8.5.2)).
That does not fit the current WebCodecs contract, which configures on an SPS/PPS IDR
marked as a key chunk, without client changes. It also has little benefit for the
reliable per-AU QUIC path. Treat gradual refresh/longer-lived references as a later
A/B, not the first IDR fix.

## Solaris ISR confound

The original loaded Stage-D comparison is confounded: its diagnostic driver called
`cmn_err(CE_NOTE)` for every record from interrupt context at `galleryhid.c`
913/921/927. It reported loaded p99 30.556 ms for warpd and 36.967 ms for gallery-hid,
so the 21% gap cannot be attributed to transport with confidence.

Current source now compiles per-record and control-IRQ diagnostics out by default with
`GHID_DEBUG_LOG=0`; fault warnings remain. A later no-log native run still produced
p95/p99 56.978/86.638 ms under a two-vCPU-saturating guest load, so logging was **a
confound, not a complete explanation**. Preserve the default-off compile gate, add a
runtime sampled/counter-only diagnostic mode if operational observability is needed,
and record the installed module/source hash plus log-gate state in every loaded
latency result. Never compare a logging-on block with a logging-off block.

## Validation cautions

- Never add independent p95 values. Report end-to-end percentiles from matched frames
  and component distributions from those same frames.
- Split IDR and P-frame populations; otherwise the 2.5 s 90 ms IDR can masquerade as
  scheduler tail in a sparse stream.
- Report wall and CPU for the caller **and** x264 pool threads. Caller thread CPU alone
  understates aggregate encode demand.
- Measure foreground latency at fixed active-tile counts. "Load average" alone does
  not say whether the relevant CPU set was saturated.
- Keep live-tile changes out of the research phase; validate future scheduler/cadence
  work on an isolated clone or a specifically approved canary.

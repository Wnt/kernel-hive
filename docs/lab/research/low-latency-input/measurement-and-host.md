# Low-latency input — measurement harness and streamhost integration

Status: **RESEARCH / BUILD PLAN (2026-07-15)**  
Scope: cross-cutting workstream T2 from `00-generic-plan.md`; no guest driver, QEMU patch, checkpoint,
or live-labhost change is made by this plan.

> **Historical client-path note (2026-07-28).** `ScreenSurface.tsx` references
> below describe the deleted v1 museum input surface. StreamView now owns the
> browser input path; the host-side measurement plan remains historical research.

## Verdict

**GO for the Rust measurement harness and streamhost integration; conditional GO per station for the
new device path.** The current capture stack already exposes the framebuffer updates needed for a
repeatable host-enqueue-to-first-observable-frame measurement, and streamhost has a single input
dispatch point at which a T1 backend can be selected. The benchmark must timestamp QEMU D-Bus
callback receipt itself: QEMU's display listener sends `Scanout`, `Update`, and `UpdateMap` calls but
does not put a presentation timestamp in those calls. QMP `screendump`/`labctl shot` is therefore an
audit mechanism, not a sufficiently precise clock.

The per-station device decision remains empirical. Ship a station only if its loadable guest driver passes
correctness and materially beats that station's **deployed** warpd path, especially loaded p95/p99 and
tail spread. A driver that merely moves work into a deferred user task, loses cursor pixels in the
capture path, or cannot outperform warpd is a no-go; leave that station on warpd.

Languages are deliberately narrow: **Rust 2021** for the harness and streamhost adapter because that
is the existing host implementation; **C** for any QEMU-facing device work selected by T1 because
that is QEMU's established device-model interface; and only the OS-supported C/assembly/HolyC
choices established by the per-OS plans for guest drivers. T2 makes no claim that Rust is a loadable
guest-kernel target on these old systems.

This cross-cutting plan does not select a guest driver model, DDK, PCI/IRQ binding, or OS input API,
and relies on no example guest driver. Those are feasibility gates owned by the six sibling per-OS
plans, which must cite the exact guest-version sources and toolchains. T2's PCI boundary is only the
host endpoint finalized by T1; treating a modern MSI/MSI-X example as proof for these guests would be
unsafe.

## What exists now

### Browser to guest path

The actual production origin is the gallery UI, not `labctl`:

1. `spa/src/three/ScreenSurface.tsx` listens for `pointerrawupdate` where available and otherwise
   consumes coalesced pointer events.
2. `spa/src/three/useStreamControl.ts` maps the browser position to absolute guest pixels.
3. `spa/src/three/streamClient.ts` sends a five-byte type-1 WebTransport datagram
   (`type, x:u16, y:u16`). WebTransport datagrams are intentionally unreliable and unordered, which
   is appropriate for supersedable pointer motion but means the receiver must define its own
   backpressure policy ([W3C WebTransport specification](https://www.w3.org/TR/webtransport/)).
4. `streamhost/streamhost/src/transport.rs` receives the record. Absolute/relative QEMU paths use a
   drain-and-coalesce task; warpd has its own motion coalescer.
5. `streamhost/streamhost/src/input.rs` dispatches according to the tile's pointer mode. For
   `InputBackend::Warpd`, a move becomes ASCII `M x y\n`. For `DbusAbs`/`DbusRel`, streamhost calls the QEMU
   console D-Bus mouse interface.
6. `streamhost/streamhost/src/warpd.rs` owns a persistent TCP or Unix-socket-to-serial connection,
   enables `TCP_NODELAY` on TCP, coalesces consecutive `M` records, batches writes, and applies the
   configured/default 8 ms pacing. Reconnect delay is one second.
7. The guest usermode agent reads ASCII and calls its current cursor API: XTest on Solaris,
   `/dev/mousein` on 9front, `SetCursorPos` on Windows, `WinSetPointerPos` on OS/2, or writes
   `ms.pos` in TempleOS.

Keyboard, buttons, and wheel use reliable per-class WebTransport streams. Win95 and Win3.11 already
have a hybrid configuration in which warpd moves the cursor while QEMU supplies buttons; Win3.11
also carries an 80 ms button delay to preserve ordering. That is an important warning: splitting
one gesture across independently queued backends is observable and should not become the steady
state of the new path.

`labctl` does **not** currently originate ordinary pointer movement. `labctl shot` asks the guest
control helper to dump a PPM and converts it to PNG; `scripts/coldboot/br_screendump` similarly uses
HMP `screendump` and waits for a file. Those are useful for calibration and evidence but include
command, file, and conversion latency. QMP specifies `screendump` as writing the display to a file,
with no frame timestamp in its result
([QEMU QMP reference](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html)).

### Current capture path

`streamhost/streamhost/src/capture.rs` passes a D-Bus display socket into QEMU through QMP and
registers a QEMU display listener. It already maintains a mapped/copy framebuffer and increments a
generation for `Scanout`, `Update`, and `UpdateMap`. `SH_DBUS_UPDATE_MS=4` is present in the six
launchers, so a 4 ms capture/update floor may be visible in the measurements. The deployed QEMU
package should be recorded from the host rather than assumed; the current repository rebuild ledger
records `pve-qemu-kvm 11.0.2-1`.

QEMU permits multiple listeners on a display console, so an observer can coexist with normal
capture, and its `Update`/`UpdateMap` calls carry damage rectangles
([QEMU D-Bus display API](https://www.qemu.org/docs/master/interop/dbus-display)). The API carries no
QEMU render timestamp. The harness will take a Rust `Instant` at callback entry. `Instant` is a
monotonic, nondecreasing process clock, so T0 and Tfb are comparable without cross-machine clock
synchronization ([Rust `Instant`](https://doc.rust-lang.org/std/time/struct.Instant.html)).

### Pinned baseline matrix

“Current warpd” means the path actually selected by the checked-in manifest and launcher, not a
synthetic transport cross-product:

| Tile | Current warpd transport | Guest/launcher facts that must remain fixed in baseline |
|---|---|---|
| `solariscde` | TCP via SLIRP host-forward `57790→7777` | KVM, 2 vCPU, std VGA, e1000; Python/XTest agent; `usb-tablet` remains pinned but is not the selected pointer path |
| `ninefront` | TCP via SLIRP host-forward `57793→7777` | KVM, 2 vCPU, q35, std VGA, virtio-net; C agent writes `/dev/mousein` |
| `win95` | TCP via SLIRP host-forward `57791→7777` | KVM, 1 vCPU, std VGA, PCnet, kernel irqchip off; QEMU buttons, warpd motion |
| `win311` | Unix socket to emulated COM1 | TCG, 1 vCPU, Cirrus, NE2K; Win16 serial agent; 8 ms pace and 80 ms QEMU-button delay |
| `os2warp` | Unix socket to emulated COM1 | TCG, 1 vCPU, Cirrus, PCnet; usermode OS/2 agent polls `DosRead` and sleeps 15 ms when empty |
| `templeos` | Unix socket to emulated COM1 | KVM, 1 vCPU, std VGA; HolyC task polls the 16550 and writes `ms.pos` |

The full fleet therefore supplies both requested baseline families—three TCP and three serial
tiles—but each tile has exactly one authoritative current baseline. Do not run an alternate,
undeployed transport and label it “current.” The TempleOS agent is already privileged/global-address
space code; its likely gain is removal of UART polling and task scheduling, not a user-to-kernel
transition, so it may improve less than the other serial tiles.

## Benchmark contract

### Primary quantity

The primary metric is deliberately named **host-enqueue-to-first-QEMU-frame latency**, not
glass-to-glass latency:

```text
T0  = monotonic time immediately before a pointer record is successfully offered to
      the selected production sink (WarpdClient or T1 backend)
Tfb = monotonic time on entry to the first QEMU D-Bus display callback whose applied
      framebuffer data passes the armed cursor-change predicate
L   = Tfb - T0
```

This includes streamhost queueing/coalescing after T0, TCP/SLIRP or UART or the T1 backend, guest
scheduling/ISR and injection, guest UI/cursor drawing, QEMU display update batching, and D-Bus
delivery. It excludes browser-to-streamhost transport, video encoding, network delivery, browser
decode, and physical display scanout. Keep the existing browser “move-to-photon” prototype as a
separate system test; never combine its `performance.now()` with the monotonic host measurement.

T0 is taken at sink-call entry and is retained only when the sink accepts the sample. A bounded
candidate queue rejection is an explicit failed sample and counter, not a delayed retry. The
baseline must call the real `WarpdClient::send` using its normal persistent connection, coalescer,
and configured pacing. A sidecar that opens the warpd socket and writes directly would bypass the
queue/pacing and is not a valid baseline.

### Why D-Bus is primary and screendump is secondary

The framebuffer callback is the earliest interface already present in streamhost that can associate
damage with a monotonic host time. The callback receipt time is not an estimate of monitor scanout;
it is the first frame observable to QEMU's registered client. D-Bus scheduling delay remains inside
the measured product, equally for warpd and the candidate.

For every calibration and periodically during a run, issue a QMP `screendump` **after** the D-Bus
hit and verify the destination template. Record request/reply times only as a loose upper-bound
diagnostic. QMP is asynchronous message transport with request IDs, not a framebuffer clock
([QMP protocol specification](https://www.qemu.org/docs/master/interop/qmp-spec.html)). `labctl shot`
is a convenient operator wrapper for this evidence lane, never the percentile source.

### Cursor-change predicate

“Any changed pixel” is too weak: clocks, animation, text cursors, and guest-load indicators can all
produce false early hits. Build a station-specific calibration artifact as follows:

1. Choose two unoccluded, flat-background points A and B, far enough apart that their cursor boxes
   do not overlap. Keep cursor shape/theme, display mode, palette, and scaling fixed.
2. From a restored checkpoint, settle the desktop, move through the **path under test** to A and B, and
   collect QEMU frame buffers plus QMP screenshots. Derive source and destination cursor masks and
   a small ROI around each cursor bounding box (bounding box plus four pixels).
3. Before each trial, alternate direction A→B or B→A, require both ROIs and framebuffer generation
   to remain stable for at least 50 ms, arm the observer, then enqueue one absolute move.
4. In the D-Bus handler, timestamp callback entry before expensive work, apply the update, and inspect
   only the two ROIs synchronously. The requested endpoint is the **first cursor-pixel change**, so a
   hit is the first generation in which either the calibrated source cursor measurably disappears
   toward its background template or the calibrated destination cursor measurably appears. Merely
   receiving damage that intersects an ROI is not a hit. Preserve callback generation and damage
   rectangle in the sample.
5. Continue observing after Tfb and require the final state—source gone and destination cursor matched—
   within 100 ms. This causally validates an early erase/draw update without incorrectly moving Tfb
   to a later complete frame. A move that changes source pixels but fails to reach B is a wrong-target
   failure, not a latency success.
6. Default timeout is 1 s and is configurable only for a documented station reason. A timeout,
   wrong destination, or ambiguous template is reported as a failure. Rank timeouts as +∞ for gate
   decisions; do not fabricate a latency equal to the timeout threshold. If failures occupy a
   requested percentile rank, that percentile fails.

`UpdateMap` currently discards useful rectangle arguments; the harness work must retain them. ROI
inspection must happen in the callback path (under the existing framebuffer synchronization), not
after waking a Tokio task, or executor delay becomes an avoidable addition to Tfb. Full-frame copying
on every update is unnecessary and itself perturbs the tail.

Calibration has a hard feasibility test: if the guest/QEMU combination uses a hardware cursor plane
that is absent from the D-Bus framebuffer and `screendump`, this metric cannot be measured as stated.
Do not silently substitute `Mouse.SetAbsPosition` acknowledgement or guest API completion. Either
force a documented software cursor in the test checkpoint without changing the production injection
path, add a deterministic guest-rendered cursor witness whose cost is reported, or mark that station's
framebuffer-latency result unavailable/no-go.

### Trial protocol and sample size

For each station, path, and load condition:

1. Restore the named checkpoint and verify launcher/device set, resolution, cursor template, agent or
   driver health, backend version, and stable framebuffer.
2. Warm the QEMU display listener, streamhost sink, warpd connection/backend, and cursor path with
   50 unreported A/B moves.
3. Run at least **1,000 measured, single-in-flight trials** per condition and repeat from a fresh
   restore three times (minimum 3,000 values). Randomize balanced A→B/B→A directions.
4. Allow the cursor/framebuffer to settle between trials. The stability gate, rather than a fixed
   sleep alone, ensures the 8 ms warpd pacer cannot merge adjacent trials.
5. Run candidate/warpd in randomized ABBA blocks in the same candidate checkpoint where possible. Never
   send one logical trial down both paths.
6. Perform a screenshot audit at calibration, at each run boundary, and on every failure; sampling
   one additional successful trial per 20 is enough to detect template drift without putting file
   I/O in the timed callback.

This is a closed-loop response test, so it does not suffer coordinated omission from a fixed offered
arrival process; do not apply coordinated-omission correction to the primary values. As a separate
backpressure test, offer motion at 250 Hz for 10 s and report accepted/coalesced/dropped records,
sequence gaps, maximum cursor age, and final-position convergence. Do not mix those samples with the
single-event latency distribution.

### Results and statistics

Write one JSONL object per attempt plus a machine-readable summary (JSON and CSV). At minimum record:

- repository commit; station manifest and launcher hashes; agent/driver hash; checkpoint/snapshot identity;
- QEMU package/query-version, accelerator, machine, VGA, vCPU count, full pinned device arguments,
  and `SH_DBUS_UPDATE_MS`;
- backend/protocol version, warpd TCP/serial and pacing/button-delay values, connection generation,
  display mode, and cursor-template hash;
- host kernel/CPU governor, QEMU vCPU-thread placement if controlled, and guest-load helper/version;
- run/trial, direction, path, load condition, sequence, enqueue acceptance, T0, Tfb, latency in µs,
  framebuffer generation/damage rectangle, predicate scores, timeout/wrong-target status, and queue,
  coalescing, overflow, reconnect, and sequence-gap counters.

Serialize T0 and Tfb as microseconds from streamhost's existing process monotonic epoch, plus their
delta; a raw `Instant` has no portable serialized representation.

Use an integer-microsecond HDR histogram, retaining raw values. HDR Histogram supports quantiles over
a configurable integer range while bounding precision
([Rust `hdrhistogram` crate](https://docs.rs/hdrhistogram/latest/hdrhistogram/struct.Histogram.html)).
Report p50, p95, p99, maximum, miss/wrong-target rate, and these jitter measures:

- primary tail spread: **p99 − p50**;
- p95 − p50, median absolute deviation, and standard deviation as secondary diagnostics.

Compute a bootstrap 95% confidence interval over run-stratified resamples for each percentile and for
candidate/baseline ratios. Show per-run values as well as the pooled summary; a good pooled result
must not hide one unstable restore.

## Jitter under pinned guest load

The loaded variant changes only one factor: a preinstalled, normal-priority guest worker consumes
CPU continuously while interrupts remain enabled. It must not use realtime priority or deliberately
mask interrupts. Start/stop it outside the timed window through the existing control channel or a
baked helper, never over the same serial stream carrying measured pointer events.

- On `solariscde` and `ninefront`, start one worker per each of the two guest vCPUs and bind/wire each
  worker to a distinct vCPU. Solaris provides `pbind` for binding processes or LWPs to processors
  ([Oracle Solaris 10 `pbind`/`psrset` enhancements](https://docs.oracle.com/cd/E19253-01/817-0547/fapdx/index.html)).
  The exact 9front `proc` control spelling must be taken from the installed kernel/manual and proven
  in the load-helper spike; Plan 9's scheduler has explicit wired-process support in its source
  ([Plan 9 `proc.c`](https://9p.io/sources/plan9/sys/src/9/port/proc.c)).
- `win95`, `win311`, `os2warp`, and `templeos` each have one guest vCPU, so placement is inherently
  pinned. Do not cite or depend on modern Windows affinity APIs for Win95; Microsoft's current API
  requirements start at Windows XP
  ([`SetProcessAffinityMask`](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setprocessaffinitymask)).

Confirm ≥90% guest CPU occupancy independently (guest counter if trustworthy, otherwise the QEMU
vCPU thread plus a guest heartbeat). Also require that a low-rate UI heartbeat continues to repaint.
On cooperative or weakly preemptive guests, a non-yielding loop may prevent **painting** even though
an ISR injects successfully. If necessary, use a calibrated high-duty-cycle worker that yields just
enough to sustain ≥90% occupancy and document the duty cycle. If the tile cannot simultaneously
hold ≥90% load and render an observable cursor, the loaded framebuffer benchmark is invalid; report
that limitation instead of claiming either a win or a driver failure.

Run idle and loaded conditions in alternating order to expose thermal/host drift. Host load should be
quiet and recorded, not artificially pinned unless the production launcher also pins it; otherwise
the result describes a laboratory scheduler configuration rather than the deployed station.

## Baseline and comparison controls

The most defensible comparison uses two levels:

1. **B0, current image:** measure the checked-in checkpoint and launcher exactly as deployed, idle and
   loaded, using the matrix above.
2. **B1, candidate image control:** after adding the pinned PCI device and captured driver, leave the
   device/backend quiescent and select warpd. Repeat the same measurements. For p50/p95/p99, the
   bootstrap confidence interval of B1−B0 must fit wholly inside an equivalence margin of the larger
   of ±2 ms or ±10% of B0. Otherwise the recapture/device/QEMU change confounds the comparison and must
   be investigated.
3. **C, candidate:** in the candidate image, select only the new backend and compare randomized B1/C
   blocks. The dormant warpd agent may remain listening for rollback, but it must receive no duplicate
   events.

Warm persistent connections in every condition. Record reconnects and invalidate the block (while
retaining its raw data) if a reconnect or snapshot transition occurs mid-block. Do not subtract the
4 ms D-Bus update interval or any estimated display floor: it is part of the current production
response and common to both paths.

## Concrete success gates

A station advances only if all gates pass. These are program targets, not promises that a 1990s guest
can meet them.

### Correctness and robustness

- ≥99.9% valid destination hits in each 1,000-trial condition, no wrong-target samples, and all
  timeouts reported;
- zero candidate ring overflow, out-of-order sequence, or unexplained sequence gap in the closed-loop
  test; burst-test coalescing/drops must follow the documented policy and converge to the final point;
- pointer bounds/corners, all buttons, wheel where supported, key up/down, focus changes, reconnect,
  snapshot restore, and backend restart pass separate functional tests;
- no stuck button/key after any failure or explicit rollback.

### Absolute latency targets

| Condition | p50 | p95 | p99 | p99−p50 |
|---|---:|---:|---:|---:|
| Idle | ≤8 ms | ≤12 ms | ≤20 ms | ≤12 ms |
| Guest ≥90% busy | ≤10 ms | ≤15 ms | ≤25 ms | ≤15 ms |

Also require loaded candidate p99 ≤2× its idle p99. A station may still demonstrate a strong relative
device win while missing an absolute display-limited target; report that honestly and do not erase
the miss.

### Relative gate against warpd

When B1 exceeds the corresponding absolute target, require:

- idle p95 and p99 each at least **40% lower** than B1;
- loaded p95, loaded p99, and loaded `(p99−p50)` each at least **60% lower** than B1;
- p50 at least 25% lower when baseline p50 is above 8 ms.

Use the conservative end of the 95% bootstrap interval: the upper confidence bound of the
candidate/baseline ratio must remain at or below 0.60 for the 40% gate and 0.40 for the 60% gate.
If B1 already meets an absolute target, the candidate passes that statistic with no regression larger
than the greater of 2 ms or 10%, again at the conservative confidence bound. A median-only win is
not sufficient. Failure of the loaded tail gate is a per-station no-go even if idle numbers improve.

## Harness build plan

Create a Rust `lli-bench` binary in the `streamhost` workspace and share production components rather
than reimplementing transports. Today the binary crate keeps `input`, `transport`, and `warpd`
private while the library exports only a subset including capture; the spike should move the minimum
wire/sink pieces behind library modules with no behavioral rewrite.

### Interfaces

Introduce these conceptual interfaces; exact names are implementation choices:

```rust
trait RealtimeInputSink {
    // Nonblocking. T0 is captured immediately before this call.
    fn try_pointer_abs(&self, event: PointerAbs) -> Result<AcceptedSeq, Reject>;
    fn health(&self) -> SinkHealth;
}

struct ArmedCursorProbe {
    seq: u64,
    source_roi: CursorTemplate,
    destination_roi: CursorTemplate,
    t0: Instant,
}
```

- `WarpdSink` wraps the real `WarpdClient::new_paced`; it does not speak directly to a socket.
- `GalleryHidSink` serializes the finalized T1 record and offers it to T1's dedicated Unix socket or
  other selected backend. It must not wait for a QEMU/guest reply on the WebTransport receive task.
- One process-wide `InputRouter` owns the selected sink and a monotonic sequence. The current
  per-session `WarpdClient` makes multiple browser sessions create multiple queues/connections; do
  not reproduce that ambiguity in the device backend.
- Pointer motion gets a bounded latest-wins slot/queue. Ordered button/key/wheel events get a small
  bounded ordered queue plus explicit overflow failure. Tokio documents that its unbounded MPSC can
  buffer arbitrarily and terminate the process on exhaustion, so it is unsuitable as the new
  realtime contract
  ([Tokio `unbounded_channel`](https://docs.rs/tokio/latest/tokio/sync/mpsc/fn.unbounded_channel.html)).
- Add an armed-probe hook to `capture.rs`. The handler timestamps before copying, retains UpdateMap
  rectangles, applies the update, evaluates ROIs synchronously, and sends a compact completed sample
  to the benchmark writer.

Benchmark input is generated by the harness, but it enters the same router and sink as production.
An optional “browser ingress” mode may drive the UI for regression coverage; it is not used for the
primary T0 definition.

### Verification of the harness itself

- Unit-test binary decoding, pixel formats/stride, clipped ROIs, template scoring, A/B state machine,
  timeout accounting, and percentile summaries with synthetic frames and timestamps.
- Add a fake sink with known 1/5/20 ms delays and injected unrelated damage; assert the first valid
  cursor-pixel generation, not the first callback or later final-state generation, wins.
- Cross-check Rust monotonic deltas against a temporary `clock_gettime(CLOCK_MONOTONIC)` probe on the
  host; Linux defines that clock as unaffected by discontinuous wall-clock jumps
  ([`clock_gettime(2)`](https://www.man7.org/linux/man-pages/man2/clock_gettime.2.html)).
- Run the existing real-UI input/screendump tests to protect functional behavior, then do a
  read-only labhost calibration. No benchmark code should install or change a checkpoint implicitly.
- Quantify observer overhead by replaying a fixed D-Bus update workload with probe disarmed/armed;
  target <100 µs p99 handler overhead and no dropped capture generations.

## Rust streamhost integration with T1

T2 depends on T1 for the device/backend ABI. QEMU's upstream `ivshmem` protocol provides shared
memory and doorbells, but its interrupt revisions and MSI-X assumptions must not be projected onto
ancient guests without T1/per-OS proof
([QEMU ivshmem specification](https://www.qemu.org/docs/master/specs/ivshmem-spec.html)). If T1 chooses
a custom device, implement it in QEMU's normal QOM/qdev model rather than putting PCI mechanics in
streamhost ([QEMU QOM](https://www.qemu.org/docs/master/devel/qom.html),
[qdev API](https://www.qemu.org/docs/master/devel/qdev-api.html)). T2 consumes a stable host endpoint
and reports its health; it does not choose INTx/MSI or map guest BARs.

### Event mapping

Keep browser capture and its five-byte absolute-pixel record unchanged initially. At the current
`input::handle` dispatch point:

1. Apply tile geometry, clipping, rotation if any, and normalize pixels to T1's 0…32767 absolute
   range exactly once. QEMU uses this range for absolute input coordinates as well
   ([QMP `input-send-event`](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html)).
2. Create the finalized fixed-size T1 record with a process-global sequence and current button state.
3. Offer it nonblockingly to `GalleryHidSink`; expose accepted/coalesced/dropped/overflow/backend-down
   counters to logs and the benchmark.
4. Let the T1 backend perform its QEMU communication and ring/doorbell operation. Do not make the
   WebTransport receiver wait for a guest acknowledgement.

The lowest-latency host injection point is therefore the production datagram coalescer's output
directly into the T1 binary-ring backend, followed by a guest doorbell/ISR and that OS plan's lowest
kernel cursor-input point. ASCII, SLIRP/TCP, emulated UART, and a guest usermode reader disappear
from the realtime path.

### Configuration and failure behavior

- Add an explicit, per-tile `SH_INPUT_BACKEND=warpd|gallery-hid` (or the repository's equivalent
  typed manifest field). Do not infer the backend merely from presence of a PCI device.
- Backend startup is fail-closed for input: report unhealthy and leave the tile out of rotation.
  Production fallback is an explicit manifest change/service restart to warpd.
- Do not promise automatic mid-gesture fallback. Without an acknowledged state snapshot, switching
  transports can reorder a move/button pair or leave a key/button stuck. Automatic fallback is
  acceptable only if T1 later defines health acknowledgements, an atomic full input-state replay,
  and a safe release-all transition.
- Keep the warpd executable, guest autostart, TCP host-forward or COM1 socket, and streamhost adapter
  captured and tested until the station has completed its capture/measurement/soak gate. The inactive path
  receives no duplicate input.
- Land pointer motion first. Move buttons/wheel/keys to the same device only after their functional
  suites pass; avoid extending the present Win95/Win3.11 mixed-backend ordering workaround.

Adding the device changes the launcher's pinned device set and therefore requires a cloned checkpoint,
driver install/autoload, cold boot/recapture, and proof that `loadvm golden` returns with the same device
and an armed driver. The launcher remains the device-set ledger. Never test a candidate driver by
mutating `/mnt/poc` or a live production checkpoint.

## Phased delivery and rollout

### Phase 0 — measurement spike (3–5 engineer-days)

- Factor the minimum capture/warpd code for reuse and build `lli-bench`.
- Implement callback-entry timestamps, damage-aware ROI predicates, JSONL output, calibration, and
  QMP screenshot audit.
- Prove repeatability on one TCP station and one serial station using only current warpd; measure observer
  overhead and run-to-run confidence intervals.
- Exit: raw/replayable data, no false hit under unrelated damage, and B0 repeatability within the
  larger of 2 ms or 10% at p50/p95/p99.

### Phase 1 — T1 adapter (3–5 engineer-days after the T1 ABI freezes)

- Add the process-wide router, bounded queue policy, `GalleryHidSink`, health/counters, config, and
  fake-backend tests.
- Measure streamhost enqueue-to-backend acceptance locally and verify no blocking on the receive task.
- Exit: bit-exact T1 records and sequence/overflow behavior pass interop tests; warpd behavior remains
  unchanged when selected.

### Phase 2 — per-station driver spike and capture (roughly 1–4 weeks + 1–2 days per station)

This work belongs to T1/per-OS plans and varies sharply. In an isolated clone, enumerate/map the
device, prove the IRQ, inject one absolute move at the chosen kernel point, then implement robust
state/ordering. Install/autoload and recapture only after the spike. Win16/Win9x may exceed four weeks or
be infeasible; do not hide that variance behind a fleet average.

### Phase 3 — measure and decide (2–3 engineer-days per station)

- Calibrate templates and load helper; collect B0, B1, and C idle/loaded data plus functional and
  burst tests.
- Publish raw data, environment metadata, percentile confidence intervals, and an explicit gate table.
- Exit per station: GO only on all correctness and tail gates; otherwise record NO-GO and select warpd.

### Phase 4 — controlled rollout and capture (about 1 week elapsed soak per passing station)

- Enable one station/canary through the manifest, monitor backend health/overflow/reconnect and input
  complaints, and repeat a short sentinel benchmark after QEMU/streamhost/checkpoint changes.
- After seven clean days, make `gallery-hid` the default for that station. Keep warpd tested as fallback
  for at least one subsequent checkpoint/release cycle; removal is a separate decision.
- Roll out station by station. Never make fleet success depend on the hardest guest.

Expected first passing station: approximately **2–6 weeks elapsed** from spike through measured capture,
depending almost entirely on its guest driver. A six-station fleet is roughly **8–16+ engineer-weeks**
and may legitimately finish with some stations on warpd.

## Risks and stop conditions

| Risk | Consequence | Mitigation / stop condition |
|---|---|---|
| Cursor is not in the captured framebuffer | Requested endpoint cannot be detected | Calibration feasibility test; documented software witness or no-go, never substitute an acknowledgement |
| Guest load prevents UI repaint | Measures scheduler/paint starvation after a successful ISR | Normal-priority ≥90% load plus heartbeat; calibrated yields; declare loaded test invalid if both conditions cannot hold |
| D-Bus 4 ms batching/host scheduling dominates | Quantized distribution can hide a small transport gain | Same launcher and randomized B1/C blocks; report raw quantization; require large tail win, do not subtract floor |
| Recapture/new PCI device changes timing | False candidate improvement/regression | B0 versus quiescent-device B1 equivalence gate |
| Unbounded queues or dual coalescers | Old events and misleading T0 | One process router, explicit bounded semantics/counters, one event path per trial |
| Split move/button paths reorder gestures | Stuck or misplaced click | Converge realtime classes on one backend; explicit fallback restart, no blind mid-gesture failover |
| Ancient guest cannot take device IRQ/map BAR/inject cursor | No loadable kernel path | Per-OS spike first; T1 must support proven INTx where MSI is unavailable; keep warpd |
| TCG/host noise inflates tails | Irreproducible Win3.11/OS2 results | Run-stratified repeats, environment ledger, alternating conditions, conservative confidence gate |
| Template drift/animations cause false first hit | Artificially low latency | Two-ROI semantic predicate, stable precondition, screenshot audits, failure evidence |
| ISR injection does not itself cause painting | Small or no framebuffer win despite fast interrupt | Treat framebuffer response as product outcome; optionally add driver trace as diagnosis, not replacement metric |

The biggest program risk is the last combination: an ancient guest driver can be loadable and service
an interrupt yet still depend on a deferred scheduler/UI path to move the visible cursor. The
framebuffer benchmark is intentionally unforgiving because users experience the visible result.

## Repository evidence used

The current-path claims above were checked against these sources rather than inferred from the
generic architecture:

- `streamhost/streamhost/src/{main,transport,input,warpd,capture,clock}.rs` and
  `streamhost/streamhost/Cargo.toml`;
- `spa/src/three/{ScreenSurface,useStreamControl,streamClient}.tsx` and the existing browser photon
  prototype in `streamhost/web/client.html`;
- `streamhost/guest-agents/{solaris,ninefront,win9x,win311,os2,templeos}/`;
- the checked-in `streamhost/stations/<tile>/qemu-streamhost.sh` launchers, plus
  `streamhost/stations-manifest.sh`/its generation path where a station (notably ninefront) has no checked-in
  launcher;
- `labctl`, `scripts/coldboot/`, `tests/e2e-live/e2e/streamhostInput.*`, and
  `scripts/tools/gallery-input-probe.py`;
- `streamhost/qemu-patches/harness/`, `streamhost/docs/CAPTURE-FASTPOLL.md`, and
  `docs/history/REBUILD-DELTAS-2026-07-15.md`.

Any implementation should repeat this inventory at its own commit because generated launchers,
checkpoints, agent behavior, and QEMU package versions are part of the experimental treatment.

## Primary external references

- [QEMU D-Bus display API](https://www.qemu.org/docs/master/interop/dbus-display) — listener
  registration, framebuffer updates, and mouse interface.
- [QEMU QMP reference](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html) and
  [QMP protocol specification](https://www.qemu.org/docs/master/interop/qmp-spec.html) — screendump,
  absolute input encoding, and request/reply semantics.
- [QEMU ivshmem specification](https://www.qemu.org/docs/master/specs/ivshmem-spec.html) — shared
  memory/doorbell model and revision-specific interrupt constraints consumed from T1.
- [QEMU QOM](https://www.qemu.org/docs/master/devel/qom.html) and
  [qdev API](https://www.qemu.org/docs/master/devel/qdev-api.html) — custom-device integration boundary.
- [Rust `Instant`](https://doc.rust-lang.org/std/time/struct.Instant.html) and
  [Linux `clock_gettime(2)`](https://www.man7.org/linux/man-pages/man2/clock_gettime.2.html) — monotonic
  timing basis.
- [Rust HDR Histogram](https://docs.rs/hdrhistogram/latest/hdrhistogram/struct.Histogram.html) —
  percentile aggregation.
- [W3C WebTransport](https://www.w3.org/TR/webtransport/) — current browser-to-streamhost datagram
  and stream semantics.
- [Oracle Solaris 10 `pbind`/`psrset` enhancements](https://docs.oracle.com/cd/E19253-01/817-0547/fapdx/index.html)
  and [Plan 9 scheduler source](https://9p.io/sources/plan9/sys/src/9/port/proc.c) — load-worker
  placement basis, subject to proof on the installed guest versions.

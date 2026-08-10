# Overhead — what each tier and path costs

Latency, CPU and memory per [tier](GUEST-TIERS.md) and per
[I/O path](IO-PATHS.md).

**Every number here is already written down somewhere in this repo and is cited
to the file that holds it.** Nothing was measured for this page and nothing is
interpolated: where a tier has no figure, it says **not measured** rather than
guessing from a neighbour. Citations are to files rather than line numbers on
purpose — line references rot within days, and a confident wrong line is worse
than a file you have to search.

## Read these four caveats first

1. **Some encode numbers predate the current encoder.** The 2026-07-16 Solaris
   profile was taken before damage-scoped conversion and libyuv, at
   `preset=veryfast`; the fleet now runs `ultrafast`. Those rows are marked
   **superseded** below and must not be quoted as current cost.
2. **Quiesced numbers are contradicted by the loaded tail.** x264 *wall* time
   inflates to ~7.7–14.6 ms p50 and ~96 ms p95 under load while x264 *CPU* stays
   ~1 ms. That is scheduler queuing, not work.
3. **Fleet-scale figures were taken at 24–28 tiles.** The lineup is now 59
   production tiles, so host-percentage totals do not scale forward.
4. **`SH_FPS`, resolution and viewer count dominate everything.** A tile with no
   viewer encodes nothing at all — receiver gating means most of this page
   describes the watched case only.

## Latency, per tier

| Tier | End-to-end | Source |
|---|---|---|
| **1 — direct QEMU** | LAN click-to-photon **~20–25 ms**; fixed pipeline excluding guest reaction **~16–17 ms**. Browser-to-browser on KolibriOS + usb-tablet: **25.6 p50 / 36.7 p95 / 16.1 min / 70.2 max** | `docs/INPUT-LATENCY.md`, `streamhost/docs/GRAPHICAL-BRIDGE.md` |
| **2 — emulator bridge** | Graphical template: **34.9 p50 / 55.4 p95 = +9.3 ms p50** over native. With an inner emulator (FS-UAE): **39.8 / 58.9 = +4.9 ms p50** on top of the template | `streamhost/docs/GRAPHICAL-BRIDGE.md` |
| **3 — host-native shm** | **Not measured.** No glass-to-glass or browser-to-browser figure exists for this path anywhere in the repo | — |
| **4 — two-QEMU X bridge** | **Not measured** | — |
| **5 — poster** | n/a | — |

Conditions for the tier comparison: CT950, LAN Chrome, one clone active at a
time, 1024×768, 60 fps, `SH_DBUS_UPDATE_MS=4`, ultrafast/zerolatency CQP, 30
alternating trials after a seed. **That is a clone, not the live tile.**

So a bridge tile costs roughly **+9 ms**, and a bridge tile with a busy inner
emulator roughly **+14 ms**, against a direct QEMU guest. That is consistent
with an analysis estimate of an ~8 ms Linux composition term added by the
kiosk compositing at 60 Hz before QEMU ever polls — but note that ~8 ms sits in
a section explicitly headed *"analysis (NOT run)"*. It is an estimate that
happens to agree with a measurement, not a second measurement.

Tier-3 component statements, deliberately **not** assembled into an end-to-end
number:

| Component | Value |
|---|---|
| shm poll interval, bounding added capture latency | `SH_SHM_POLL_MS` default **2 ms** |
| MAME `-frameskip 6` | buys ~+18% emulation speed; costs a change **~7 ms longer** to reach capture |
| stream rate | `SH_FPS=30` |

## Latency, per pipeline stage (Tier 1)

| # | Stage | ~ms | Status |
|---|---|---:|---|
| 1 | Event capture + pack, client JS | ~0.5 | current |
| 1→2 | Input on the wire, one-way LAN | **0.3 p50 / 0.7 p95** | supersedes the older ~1.5 ms budget |
| 2 | Inject into guest | ~0.5 | current |
| 3 | Guest reacts and repaints | variable | the guest's problem, not ours |
| 4 | Capture wait (display poll) | **~2** | was ~15 at the stock 30 ms poll |
| 5 | H.264 encode, snap→AU | **1.8–3.2 p50** across live tiles | supersedes the ~8 ms row |
| 6→7 | AU on the wire, one-way LAN | **0.3 p50 / 0.7 p95** | current |
| 7 | WebCodecs decode | ~1.3 | current |
| 8 | Present / paint | ~1.4 | current |

The **~16–17 ms fixed pipeline** total in `docs/INPUT-LATENCY.md` is written as
stated, but it is arithmetically built from the two superseded rows. Treat it as
the older budget, not as a sum of the current values.

**The shape of the budget is the point: input is ~2% of the round trip and
video is >85%.** Optimising the input path further is close to pointless; every
material win left is in capture cadence, encode, or the client's presentation
interval.

Fast-poll A/B (`freedos`, 36 matched trials per config):

| Config | poll ticks/s | avg capture-wait | cut | inject→wire p50 | p95 |
|---|---:|---:|---:|---:|---:|
| baseline, 30 ms | 31.5 | 15.9 ms | — | 19.9 ms | 39.1 ms |
| `SH_DBUS_UPDATE_MS=8` | 112.9 | 4.4 ms | 72% | — | — |
| **`=4` (deployed)** | 229.5 | **2.2 ms** | **86%** | **11.4 ms** | **24.5 ms** |
| `=2` | 448.3 | 1.1 ms | 93% | 8.4 ms | 29.0 ms — **worse p95** |

`=4` is the knee: `=2` halves the median again but the tail regresses. Source
`streamhost/docs/CAPTURE-FASTPOLL.md`.

Solaris hop decomposition (gallery-hid, 1920×1200, quiesced clone). Per-hop p95
values are **not additive**:

| Hop | p50 / p95 | Status |
|---|---|---|
| streamhost → gallery-hid ring write | 0.015 / 0.025 ms | current |
| guest round trip, inject → framebuffer | 2.5 / 4.4 ms | current |
| Xorg software cursor render | ~0.6 / ~0.75 ms | current |
| capwait (poll + rate-cap dispatch) | 4.1 / 7.8 ms | continuous-drag regime only |
| full-frame H.264 encode | 14.0 / 17.9 ms | **superseded** |
| ↳ BGRA→I420 conversion | 6.6 / 9.2 ms | **superseded** — pre-libyuv |
| ↳ x264 wall | 5.2 / 6.0 ms, ~2.4 ms of it CPU | **superseded** |
| publish AU to broadcast | 0.013 / 0.018 ms | current |
| browser paint/present | ~8 / ~16 ms | **software-inflated upper bound** on a GPU-less box |

A separate client-side floor nobody can optimise away: a frame waits a median
**half refresh interval** just to reach the next presentation opportunity —
8.3 ms at 60 Hz, 4.2 at 120 Hz, 3.5 at 144 Hz.

## Latency, per input path

| Path | Measured | Configured pacing |
|---|---|---|
| **gallery-hid** (`solaris`) | ring write 0.015 / 0.025 ms; inject→framebuffer 2.5 / 4.4 ms | latest-wins move slot, 64-entry ordered transition queue |
| **warpd vs gallery-hid**, inject→cursor-visible | idle: warpd **2.688 / 4.817** vs gallery-hid **2.716 / 4.751** — statistically indistinguishable. Loaded: gallery-hid **21% worse at pooled p99** | `SH_WARPD_PACE_MS` 8 ms |
| **warpd hybrid** (`win311`, `os2warp`) | not measured end-to-end | `SH_WARPD_BUTTON_DELAY_MS` **80 ms**, re-armed by every reposition |
| **dbus-rel homing** | not measured end-to-end | 250 ms settle once per session; 256 px chunks at 16 ms |
| **mamesock** (`irix`) | not measured end-to-end | ack deadline 5 s + 200 ms per outstanding verb |
| **dbus-abs** | not measured per-tile | `SH_ABS_PACE_MS` 0 everywhere except `win11` = 30 |

The warpd-vs-gallery-hid campaign is marked **PARTIAL** in its own document and
ran on a clone with **one vCPU onlined**, with the diagnostic driver's logging a
likely tail confound. The honest summary is that the exotic path did **not**
demonstrate a latency win over the simple agent at idle.

## Keyboard: no latency figure exists, only a delivery threshold

**No end-to-end keyboard-to-echo latency is measured anywhere in the repo.**
What is measured is the release→press gap an emulator needs to observe distinct
keys — the table is in [`IO-PATHS.md`](IO-PATHS.md#2-keyboard). The headline:
`mpf2` lands **0 of 16** keys at a 0 ms gap and **16 of 16** at one frame
(16 ms), because an emulator samples its key matrix once per emulated frame.

## Audio: bounds, not measurements

**No end-to-end audio latency (guest sound → speaker) is measured.** The only
written terms are configured bounds:

| Term | Value |
|---|---|
| Opus frame | 20 ms (50 packets/s) |
| FIFO standing latency bound (`irix`) | ≤ ~85 ms (16 KiB pipe at 192 000 B/s) |
| SPA play-head lead | 20 ms |
| Egress backlog bound (video) | ~250 ms + RTT |

QEMU-side audiodev buffering on the dbus path is **not documented**, and the
Opus encode's CPU cost is **not measured**.

## CPU

**Fleet level.** The box's no-visitor load went from **~83% of the host** to low
single digits after idle auto-pause landed. The measured idle offenders, all
since superseded by receiver gating and auto-pause:

| Offender | Cost |
|---|---|
| bridge-tile QEMUs (`apple2 atarist amiga c64`) | ~31% of the host |
| streamhost zero-client encode | ~23% of the host |
| other busy-at-idle tile QEMUs | ~12% of the host |
| the 2 ms encode poll × 28 daemons | ~2% of the host |

**Per tier.**

| Tier | Measured |
|---|---|
| **1** | watched tile on the patched binary **~4% of a core** at 250 polls/s; **paused: 0%**. Fleet idle after the run-state gate: **9.9% of a core = 0.62% of host** across 26 tiles, a **6.4× cut** |
| **2** | the v1 copy path carries **60–110 MB/s** of `Update` calls; the borrowed-bytes listener drains >110 MB/s at **~5% of one core**. Inner emulators: Iris (`indyr4400`) **~310–320%** in-guest with its QEMU at ~150%; ContrAlto (`alto`) **~170–190% of a core**; Dwarf JVM (`daybreak`) 9–15% of a core, whole tile ~18% |
| **3** | after the shm cutover, idle IRIX desktop with **no viewer**: streamhost **3% of a core** + MAME **81% of a core**, against ~100–114% on the old x11 path. The x11 display detour cost **32–43% of host time**; paired A/B showed shm **+41–42% faster** |
| **4** | **not measured** |

**Encoder.** `x264_encoder_encode` costs **~1 ms CPU** at tile resolutions but
**~11–13 ms wall** when run synchronously on the shared runtime — which is why
it has its own OS thread. Conversion is **~1.3 ms/frame** with a native build,
against ~12.6–16 ms for the old scalar loop: a **15×** difference.

`SH_ENC_NICE` ships **off** because nice measurably cannot move the contended
tail on this kernel — x264 CPU stayed ~1 ms in every nice condition while the
tail moved randomly.

Isolated x264 encode-only scaling (a synthetic ceiling, not a live pipeline
number):

| Resolution | static, 4 threads | full-change, 4 threads | full-change, 1 thread |
|---|---:|---:|---:|
| 640×480 | 0.81 ms | 2.67 ms | 4.33 ms |
| 1280×1024 | 2.98 ms | 8.03 ms | 16.27 ms |
| 1600×1200 | 4.37 ms | 13.38 ms | 31.16 ms |
| 1920×1200 | 5.22 ms | 15.58 ms | 31.46 ms |

At one thread, the two largest resolutions sit at the ~31 ms edge of a 30 fps
budget — which is the real argument against raising a tile's resolution.

**A host-level side effect worth knowing**, because it silently taxes every
other measurement: the x264 encoder smears **1.07 cores over all 8 physical
cores at 30 Hz**, pinning the package in the bottom turbo bin at ~2.47–2.50 GHz
exactly when a visitor is watching, against 3.0 GHz available at one active
core. Any benchmark taken while a tile streams inherits that.

**Transport arithmetic.** An IDR at CQP q10/1920×1200 is a 1–2 MB frame whose
encode alone spikes to ~90–100 ms p95 — which is why `SH_KEYFRAME_MS` went from
1000 to 2500. Twenty-eight synchronised IDRs would be 28–56 MB and **224–448 ms
of pure serialization on 1 GbE**. Raw uncompressed video is arithmetically
impossible: 9.2 MB per 1920×1200 frame is ~4.4 Gbps at 60 fps.

## Memory

**Tier 2 is the memory-bound class**, and it is the constraint that limits the
lineup. Live RSS measured 2026-08-08:

| Tile | RSS |
|---|---:|
| `mpf2` | 1.66 GB |
| `c64` | 1.65 GB |
| `amiga` | 1.61 GB |
| `apple2` | 1.00 GB |
| `atarist` | 0.78 GB |
| `amstradcpc` | 0.70 GB |

Mean ≈ **1.2 GB per bridge tile** against ~40 GB available of the box's 128 GB.
Thirty more at that mean would be ~36 GB and **does not fit** — so the lineup is
memory-bound long before it is effort-bound.

Spot values elsewhere: `bbcmicro` 1.06 GB, `gt40` 758 MB, `kc854` 739 MB,
`cbm8032` ~715 MB, `pet2001` ~707 MB, `zx81` ~695 MB, `c128` 688 MiB, `cbm2`
~660 MB. Inner runtimes: Dwarf JVM 226–229 MB, Iris 528 MB, ContrAlto ~180 MB.

**Caps and guards.**

| Mechanism | Value | Applies to |
|---|---|---|
| transient `qcap` scope, `BindsTo=` its unit | `MemoryMax=3G` | `c64 atarist apple2 amiga` and `irix` |
| graphical-bridge template scope | 6 GiB | the template only — **not** a fleet default |
| `SH_QEMU_RSS_GUARD_MB` | default **2048 MB** (0 = off) | all QEMU tiles; verified freeing **4.6 GB → 1.7 GB** on listener recycle |
| broadcast ring | 256 AUs ≈ 12.8 s at 20 fps | every tier |
| golden `savevm` vmstate | 424–1442 MiB | Tier 2 |

The `irix` shm mapping is 64 B + 1288×1024×4 = **5 275 712 bytes**. There is no
RSS guard on that tier because there is no QEMU to guard.

**No fleet aggregate exists for the daemon's own memory** — only scattered spot
values.

## Reset and restore

| Class | Mechanism | Cost |
|---|---|---|
| most tiles | `loadvm` of the internal `golden` snapshot | not measured |
| `openvms`, `toaruos` | cold service `restart` | `openvms` forbids a warm `loadvm` — VMState revives dead X sockets and stale SLIRP state |
| `irix` | `relaunch` | **4.4 s to first frame, 5.6 s to interactive**, against a ~390 s cold boot — a **~70×** win from a 47 MB savestate |
| `serenityos toaruos sailfishos` | none | no golden snapshot; `labctl reset` refuses |

## The one change that dominates everything above

Moving from an ffmpeg child process to the in-process libx264 encoder on a
dedicated thread took glass-to-glass isolated-input p50 from **390–564 ms to
22–44 ms** — because the child's stdout pipe only flushed an access unit when
the *next* frame's bytes arrived. Box-side quiesced snap→AU merely halved,
5.7 → 2.9 ms.

That gap between "halved" and "17× better" is the lesson worth carrying: the
box-side metric barely moved while the user-visible number transformed, because
the defect was a **buffering boundary**, not compute. Measure where the user is.

For scale, the pre-project neko/WebRTC stack measured **~200 ms** input-to-photon
median against streamhost's ~33 ms at the time.

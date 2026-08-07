> **Historical snapshot.** This document describes the system as it stood around 2026-07-08 to 2026-07-09. It is kept for historical context and is not a description of the current system.

# In-process libx264 — root-cause + staged fix (encode latency)

Handoff for the deferred LATENCY-NOTES item 4 (replace the ffmpeg child with
in-process libx264). Investigated 2026-07-08 (workflow + follow-up agents,
canaried on the low-traffic `helenos` tile only, box-side `snap->AU` metric —
the user was on VPN so glass-to-glass could not be measured).

**STATUS 2026-07-09: IMPLEMENTED + VALIDATED + DEPLOYED FLEET-WIDE** — the
dedicated-encode-thread step below shipped; see "Deployed" at the end. Rollback
binary: `/data/vms/streamhost/streamhost.pre-encthread.bak` (ffmpeg-child,
md5 `b994a4bf876fc6a0bd087b6b6b86c698`).

## What we tried
Composed a binary bundling worker-B's two encode changes: (1) in-process libx264
via the `x264-sys` FFI (removes the ffmpeg subprocess, its stdin pipe memcpy, and
the ~2ms stdout "quiet-window" AU-boundary heuristic); (2) sliced-threads
(`i_threads=N`, `b_sliced_threads=1`) replacing `-threads 1`. First canary:
box-side `snap->AU` p50 **7.7ms (ffmpeg) -> ~35ms (in-process)**. Rolled back.

## Root cause — TWO independent terms, only ONE is a real regression
1. **REAL (fixed): `bgra_to_i420` was scalar (~20ms CPU / 1024x768 frame).**
   ffmpeg did the same BGRA->I420 conversion with libswscale SIMD in <1ms inside
   its own process; going in-process exposed the slow scalar convert on the
   capture thread. **Fixed** — `bgra_to_i420` rewritten (chunks_exact luma +
   unchecked interior 2x2 chroma kernel + scalar odd-edge fallback), **bit-
   identical** to the old BT.601 integer matrix (unit test
   `bgra_to_i420_bit_identical` vs a naive oracle, even+odd geometries).
   Microbench: scalar 12.6-16ms -> opt 3.7-4.2ms portable (3.3x) / **1.1ms with
   `RUSTFLAGS=-C target-cpu=native`** (15x; the box is a Xeon D-2146NT, AVX2/512).
2. **ARTIFACT (not fixable by codegen): the ~12ms "x264" term is not CPU.**
   x264 uses ~1ms CPU; it is inflated to ~11-13ms **wall** by OS scheduling —
   the synchronous encode competing on the shared `Nice=5` tokio worker among 24
   live VMs. The separate ffmpeg **process** got its own scheduling entity, so it
   never showed this. Confirmed threading-mode independent (sliced-4, sliced-1,
   AND true-serial `b_sliced_threads=0` all ~12ms wall / ~1ms CPU) -> **sliced-
   threads is NOT the culprit; drop it (neutral at tile resolutions).**

## Numbers after the conv fix (box-side snap->AU p50, idle 1024x768 helenos)
- baseline ffmpeg child: **7.7ms**
- original in-process: ~35ms
- conv-fix portable: ~19-21ms
- conv-fix **native**: ~14.5-16.7ms (conv ~1.3ms, x264 wall ~12ms, total real CPU/frame **~2.9ms**)

Still above 7.7ms box-side **because the residual IS the scheduling artifact**,
not real work. Post-fix real per-frame CPU (~2.9ms native) is LESS than the
ffmpeg path's work, and in-process also drops the pipe memcpy + the 2ms
quiet-window + a whole subprocess -> **end-to-end it is likely neutral-to-
better; the box-side metric overstates it.** Needs glass-to-glass (LAN) to prove.

## Staged artifacts (on the box, NOT deployed)
- `/data/vms/streamhost/staging-enclat-fix/streamhost-inproc-convfix-portable` (md5 `cf5bd961`)
- `/data/vms/streamhost/staging-enclat-fix/streamhost-inproc-convfix-native`   (md5 `cc7252ae`, `-C target-cpu=native`)
- `/data/vms/streamhost/staging-enclat-fix/README.txt`
- Source: the conv-fix + `SH_ENC_PROFILE`-gated per-component/CPU-vs-wall
  instrumentation live in the `wf_5815c08c-e90-2` / `wt-compose-5815c08c`
  worktrees' `encode.rs` (`bgra_to_i420` ~L454, test ~L1222, prof ~L723/1000).
  `b_sliced_threads` left =1 (proven irrelevant; no unmotivated change).

## Recommended next step (do on LAN, glass-to-glass verified)
1. **Move the x264 encode onto a dedicated one-in-one-out OS thread** that sleeps
   between frames — re-creating the old ffmpeg child's separate scheduling
   entity. This is where the ~10ms wall artifact lives; codegen cannot touch it.
   Preserve AU ordering, zerolatency, and the exact CQP/CRF/IDR/keyframe
   semantics. **DONE** — implemented as a dedicated encode thread with a
   latest-wins frame handoff (branch `enc-thread`, merged to main), built
   native, canaried, and deployed fleet-wide (see "Deployed" below).
2. Build the fleet with `target-cpu=native` (free 5ms->1.3ms on the convert).
   **DONE** — the fleet binary is a native build.
3. Then re-canary on `helenos` AND measure glass-to-glass before any fleet cutover.
   **DONE** — canary + glass-to-glass numbers below.

## Deployed (2026-07-09) — dedicated encode thread, fleet-wide

- **Canary, box-side `snap->AU`**: quiesced p50 **5.7ms -> 2.9ms** (2x).
  Contended p50 is at parity — the residual is the x264 sliced-pool scheduler
  wall, not the daemon; next lever = encode-thread priority.
- **Glass-to-glass, isolated input** (the headline win): p50 **390-564ms
  (ffmpeg child) -> 22-44ms (enc-thread)**. Root cause of the old number: the
  ffmpeg-child stdout pipe only flushed an AU when the NEXT frame's bytes
  arrived, so every isolated input waited for the next damage event (up to
  ~1s). Verified pixel-exact in 64/64 trials; evidence at
  `/data/vms/streamhost/staging-encthread/glass-evidence/` (measurement rig at
  `/data/vms/streamhost/staging-encthread/rig`).
- **Bridge-tile QEMU OOM mechanism found**: dbus-display V1 copy-path payloads
  queue unboundedly INSIDE QEMU when the zbus consumer is starved by the
  synchronous encoder — the protocol has no flow control. Mitigations: the
  dedicated encode thread (the consumer now always drains) + permanent qcap
  scopes on the bridge tiles as insurance (6 GiB at the time, since tightened
  to **3 GiB**).
- **Bridge soak (c64, 40+ min on the new encoder)**: RSS oscillates
  1.7-3.9GiB and RECOVERS (the leak self-drains; previously monotonic to the
  cgroup-cap OOM — then 6 GiB — in minutes). enc p50 settles ~4.7ms / p95
  27ms, vs 60-160ms / seconds before.
- **Cutover history + provenance lesson**: first cutover 2026-07-08 23:32
  (native md5 `e9773ec9`) — **superseded**: that build predated main commit
  `5d22986` (win311 warpd button-delay), caught by an md5 provenance check of
  the build-dir sources vs the repo. Rebuilt from merged main `5faf6b5` (all
  12 `src/*.rs` md5-verified against main BEFORE the build) and re-cut over
  2026-07-09 ~09:25: live fleet binary native md5
  `ee6a219c4bc0c745bdd899a1e74930b1` (portable sibling `9980173a`), 25/25
  daemons active, 8/8 tests passed. **Rule going forward: fleet binaries
  build only from merged main, with a mandatory md5 provenance check.**
- **Rollback**: `/data/vms/streamhost/streamhost.pre-encthread.bak`
  (md5 `b994a4bf`).

## RESOLVED 2026-07-12 — bridge-tile attach-burst / copy-path backlog OOM

(Was "KNOWN OPEN ISSUE — shm-mode bridge tiles: attach-burst OOM". Root-caused
and fixed on branch `shm-attach-fix`; validated on atarist/apple2/amiga.)

The "shm=true" in the 07-09 incident was a red herring. Measured mechanism:

1. Bridge kiosks are 32bpp KMS → QEMU's `-vga std` surface is guest-VRAM-backed
   and **not memfd-shareable** → QEMU always uses the v1 **copy path** for the
   real frames (~30 full 1024x768 BGRA frames/s ≈ 60-110 MB/s of `Update`
   calls), regardless of the advertised `Unix.Map`.
2. The lone `ScanoutMap 640x480` at first attach is a **stale pre-guest-init
   placeholder** (a daemon-less QEMU console never refreshes its surface; the
   placeholder is memfd-shareable so the map path fires once). It made
   `snapshot_bgra()` encode dead 640x480 pixels forever ("first frame 1024x768
   (shm=true)" while `[encode] geometry 640x480`).
3. The old v1 handlers took `data: Vec<u8>` — zvariant deserializes that via
   serde's per-element seq visitor, i.e. ~3 MB per message through a per-byte
   loop. Drain capped at ~10-15 msgs/s at ~190% daemon CPU → listener socket
   backpressured → QEMU's fire-and-forget GDBusWorker output queue grew
   **unboundedly in QEMU anon heap** (~55 MB/s measured; instantly freed on
   daemon disconnect: 4.65 GB → 1.69 GB) → guest cgroup OOM at the cap
   (6 GiB at the time; the bridge qcap scopes are 3 GiB today).
   Fast variant: first attach (dcl registration starts the gui timer at full
   rate). Slow variant: the same arithmetic killed **c64** on 07-11 23:43
   after ~20 min of sustained pointer-wiggle streaming (encoder degraded to
   1.9 fps, p50 134 ms while QEMU crept to the cap) — one mechanism, two rates.

Fixes (all in `capture.rs`, branch `shm-attach-fix`, canary md5 `01524b61`):
- v1 `Scanout`/`Update` args are now `&[u8]` (zvariant borrowed-bytes fast
  path). Measured post-fix: drains 25-85 updates/s (up to 110 MB/s) with
  ~50-150 ms handler time per 2 s window; QEMU RSS flat at ~1.03 GB under the
  exact flood that previously grew 55 MB/s; encoder does the real 1024x768 at
  18-27 fps.
- v1 `Scanout` invalidates (munmaps) any stale shm map — copy path becomes
  authoritative ("v1 Scanout WxH supersedes shm map" in the journal).
- **Guest-RSS guard**: `SH_QEMU_RSS_GUARD_MB` (default 2048, 0=off) polls the
  guest QEMU's `RssAnon` (pidfile next to the QMP socket); on growth beyond
  the threshold above its low-water mark it drops + re-registers the listener
  connection — QEMU frees the entire queued backlog on peer disconnect and
  re-sends a full scanout. Validated with a 48 MB test threshold: trip →
  recycle → fresh `Scanout` → streaming resumed in ~1 s. This hard-bounds
  guest growth for ANY future producer>consumer regression on any tile.
- `SH_CAP_TRACE=1` prints per-2s listener dispatch counters (`[capstat]`).

Strategic follow-up (per-OS phase, optional): run the bridge kiosks' X at
16bpp so QEMU allocates a memfd-shareable conversion surface → true shm
(`UpdateMap`) capture, near-zero socket traffic. See BRIDGE.md §5.

## Encode-thread priority (SH_ENC_NICE) — MEASURED, NO EFFECT (2026-07-12)

The "next lever = encode-thread priority" idea above was implemented (branch
`enc-priority`: the `sh-encode` thread setpriority()s itself before the first
`x264_encoder_open`, so the x264 sliced pool inherits — inheritance VERIFIED
via `/proc/<pid>/task/*/stat`: sh-encode + 8 pool threads at the target nice,
tokio workers stay at the service Nice=5) and A/B-canaried on helenos under
real fleet load (load avg 45-77, 6 interleaved ~3.5 min windows,
SH_ENC_PROFILE=1, ~2.6 fps typing activity):

- baseline Nice=5 (12 sub-windows): snap->AU p50 median ~13.6 ms, p95 49-287 ms
- SH_ENC_NICE=0  (8 sub-windows): p50 median ~13.9 ms, p95 68-331 ms
- SH_ENC_NICE=-10 (4 sub-windows): p50 14-17 ms, p95 110-183 ms
- x264_wall p50 7.6-15 ms / x264_cpu ~1 ms in ALL conditions; enc-thread CPU
  identical (~2.3-2.5 ms/frame); stream healthy, no inversion artifacts.

**Nice is inert for this tail — including nice -10.** Explanation: the box
kernel (7.0.2-pve) runs EEVDF with `RUN_TO_PARITY`; a waking thread — whatever
its nice weight — does not preempt the current task until that task's slice
parity, so each wakeup hop (encode-thread dequeue, sliced-pool fan-out, join)
still eats up to a scheduler slice when all 16 CPUs are busy with nice-0 QEMU
vCPUs. Nice buys long-run CPU share (irrelevant: encode uses <1% CPU), not
wakeup latency. Levers that WOULD move it on this kernel, in escalating order:
1. `PREEMPT_SHORT` honors a SHORTER slice: `sched_setattr` with a small
   `sched_runtime` (custom slice, still SCHED_OTHER) lets the encode threads
   preempt on wake. Cheapest real option; not implemented.
2. `SCHED_RR` (instant preemption of all CFS/EEVDF tasks). Bounded risk: the
   encode threads are tiny (~2.5 ms CPU/frame) but RT starvation of vCPUs on a
   saturated box must be throttle-capped (RLIMIT_RTTIME / cgroup rt budget).
   Documented only — NOT enabled, per the no-RT-by-default rule.

The knob ships in the code (default **`off`** = inherit — no setpriority
syscall; nice measured inert on EEVDF) and is harmless either way; there is no
latency reason to deploy it.

## Related, independent — since DONE
- **Per-type QUIC input streams** (worker A, LATENCY-NOTES item 3) — the actual
  *input*-latency win. **DONE: shipped fleet-wide + the SPA cutover**
  (`spa/src/three/streamClient.ts` per-class uni streams); the per-type router
  is always on since 2026-07-14 (the `SH_INPUT_STREAMS` knob was removed — it
  only ever disabled the server half). The server keeps the legacy bidi loop
  for old-client compat.

See also [LATENCY-NOTES.md](LATENCY-NOTES.md) for the original ranked plan.

# es40 PGO re-measurement — 2026-08-11 (recommend: don't integrate)

**Question:** integrate PGO (profile-guided optimization) into the production
es40 build? An earlier A/B (this repo, before the JIT work landed) measured
**+10%** on the Computer Management launch metric and left PGO flagged as a
"measured but not-yet-integrated" win.

**Finding:** on the current codebase — after the JIT campaign (`0e22e9f`:
deliverability-gated interrupt kicks, chain-granular IRQ drains,
compile-on-second-encounter) that delivered the 2.37× desktop-interaction
win — **PGO now buys only ~1–2%.** The compiler headroom PGO exploited is
mostly gone: the big wins came from the JIT/algorithmic changes, not from
better instruction scheduling of the hot loop.

## Method

Isolated from the live station: a private es40src clone
(`/data/vms/sandbox/ALPHA-nt-pgo/es40src`), private serial ports
(25964/25965), private shm/ctl paths, **no Xvfb** (headless shm capture),
and a reflink copy of the production seed per boot. Metric =
**boot-to-settled-desktop** (process start → the Start/quick-launch taskbar
region renders in the shm framebuffer), plus es40 CPU time (utime+stime at
desktop, a host-scheduling-free throughput proxy). Bench:
`ALPHA-nt-pgo/bench/pgobench.sh`.

- **Control**: clean `-O3 -mavx2 -mfma` build (`es40.o3ctrl`, `5ac1faa7`).
- **PGO**: `-fprofile-generate` build → headless boot-to-desktop profiling
  run → graceful exit flushes 48 `.gcda` → clean `-fprofile-use
  -fprofile-correction` rebuild (`es40.pgo`, `7da9ad4d`).
- Arms **interleaved** (ctrl, pgo, …) to cancel drift from the live station's
  shared-labhost load.

## Results

| metric | -O3 control | PGO | delta |
|---|---|---|---|
| boot wall (7 pairs, mean; drop 1 cold-cache outlier) | 116.9 s | 115.1 s | **−1.5%** |
| es40 CPU time (3 pairs, mean) | 127.2 s | 125.8 s | **−1.1%** |

PGO was faster in **6 of 7** interleaved pairs (1 tie); zero timeouts. The
signal is real and consistent but small.

## Recommendation: keep -O3, do NOT make PGO the default build

- **Gain is marginal (~1–2%)** on a station that already meets its performance
  goal (2.37×). Boot is ~117 s dominated by firmware + guest boot; the
  emulator hot loop is already ~98% compiled / ~300 MIPS.
- **Packaging cost is real and ongoing.** PGO turns one `make` into a
  three-step pipeline (generate → representative-workload run → use) that
  needs a seed and a headless workload runner, and the profile goes
  **stale on every future hot-code change** (`-Wmissing-profile`, benefit
  decays) — fragile overhead for ~1% on an actively-developed fork.
- Net: the maintenance burden outweighs ~1–2% for this exhibit.

**Optional recipe** (if a one-off "release build" is ever wanted), reproduced
from this measurement — run in the es40 `src/` dir with the labhost lib tree on
`-L`/rpath:

```
BASE="-g -O3 -mavx2 -mfma <the configured -I/-D flags>"
LD="-L.../root/usr/lib/x86_64-linux-gnu -Wl,-rpath,.../root/usr/lib/x86_64-linux-gnu"
make clean && make -j6 CXXFLAGS="$BASE -fprofile-generate" LDFLAGS="$LD -fprofile-generate"
# boot the instrumented es40 headless (SDL_VIDEODRIVER=dummy, ES40_SHM_PATH=…)
# from a seed copy, wait for the 1280x1024 desktop, then SIGTERM (graceful
# exit flushes .gcda next to the .o files)
make clean && make -j6 CXXFLAGS="$BASE -fprofile-use -fprofile-correction -Wno-missing-profile" LDFLAGS="$LD"
```

**LTO** remains a measured **null** (earlier A/B); PGO+LTO combined was not
retested since PGO alone is already marginal.

Scratch env `/data/vms/sandbox/ALPHA-nt-pgo/` can be removed once this is
recorded (it holds the private es40src clone + control/pgo binaries + bench).

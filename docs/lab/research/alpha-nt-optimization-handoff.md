# w2kalpha emulator-optimization — session handoff

**2026-08-11 ~08:00 — THE 2× DESKTOP-INTERACTION GOAL IS ACHIEVED AND
PROVEN: Computer Management launch 24.4 s → 10.30 s ± 0.25 (2.37×, n=8),
fork `0e22e9f` (+ savestate work `ab75e70`/`d73e4dc`, docs `d019b15`).
The canonical box build == the benchmarked binary (`362cf057…`); the rig
runs it. Read alpha-nt-add.md §10 "The 24h mission" for the full story.
Remaining queue: post-restore-under-load wedge (timer-baseline suspect),
guest telnet channel, guest de-bloat, idle_nap probe, LTO/PGO packaging
pass, TB_ENTRIES experiment. Older content below.**

**(Superseded status paragraph:)** Updated 2026-08-11 (late session). Done: §1 fast-flag (−24.7%), §4 partial
(-O3 adopted, +2.4%; LTO/PGO open), §3 closed NULL (patch parked on fork
branch `tlb-hint-experimental`), AlphaBIOS NVRAM fix (kernel 118.7→82.8s
cold-boot), host quiesced, tuning research digested in
[`es40-tuning-research.md`](es40-tuning-research.md). Next: savestate smoke
test, then guest telnet channel, then §2 (dispatch) sized by a fresh
JIT_STATS profile.** Full background: [`alpha-nt-add.md` §10](alpha-nt-add.md).

**Priority reframe (operator, 2026-08-11):** the tile ships in instant-resume
(desktop visible, golden restore < 5 s) — visitors never watch it boot.
Boot-time wins are operator/bench velocity; the visitor-facing metric is
**responsiveness at the desktop**, i.e. the idle profile (§2 dispatch, §3
TLB), not time-to-desktop.

## The mission

The installed `w2kalpha` guest works but the emulator is slow (75-min install,
one host core saturated even at idle). Goal: **profile-guided optimization of
the es40 emulator**, not the guest OS. Measure → change one thing → A/B on the
bench → keep or revert. Source changes go on the fork **github.com/Wnt/es40** as
commits (operator rule: **no .patch files**).

## State at handoff (all committed + pushed)

- **Repo `main` @ `ab440cd`** (pushed): `alpha-nt-add.md` §10, two `tiles.json`
  harvests. Working tree clean. Box-sync 233/233 MATCH, pre-push gate green.
- **Fork `Wnt/es40` main @ `69022e4`** (pushed): `652f7c2` mouse.absolute,
  `6a525d1` media-mailbox fast-flag, `e4a96e3`/`69022e4` fork docs
  (KERNEL-HIVE-FORK.md). Branch `tlb-hint-experimental` = the measured-null
  TLB patch. Box checkout synced (push via temp branch + `git merge
  --ff-only` — the box can't auth to github). Canonical binary `688428…`
  (-O3, .text-identical to benched `es40.O3` `ade17cfa…`); controls:
  `es40.O3`, `es40.652f7c2` (`a2a21bde…`), `es40.baseline` (`29ecb300…`).
  **The fast-flag commit added a virtual to CDisk — always clean-rebuild
  across it (stale objects are vtable-broken).**
- **Live rig** `/data/vms/soltest/ALPHA-nt/run/`: on the canonical -O3
  binary since 2026-08-11 (clean NTFS shutdown → `start.sh`), at the
  desktop. **Its `flash.rom` (persisted 02:47:51) carries the new NVRAM:
  Auto Start Count 5 s + Power-up Memory Test Disabled — the bench copies
  this file, so all future runs inherit it; the `m2-desktop` milestone
  flash.rom is now doubly stale (no autoboot script, old settings).**
  Operator VNC at `vnc://<box>:5964` (pw `alpha2000`, unit
  `alpha-nt-vnc64.service` on Xvfb `:64`); drive it from the host with
  `DISPLAY=:64 xdotool key …` + `import -window root` screenshots (the
  AlphaBIOS setup session used exactly this).
- **Bench harness** `/data/vms/soltest/ALPHA-nt/bench/` — built, validated,
  slots clear. See "How to measure".
- **Mouse verified post-restart** (operator, 2026-08-11): pointer moves fine
  over VNC. Note it is still tracking *relative* — "OK for testing." The
  `mouse.absolute` path is in the config but the operator's VNC client is
  evidently feeding relative motion, which the unpatched path already handles;
  `mouse.absolute` matters for an absolute-injection transport (the future tile
  capture pipeline, MAME-IRIX style), not this hand-driven VNC.

## Where the time goes (the actual findings)

Two perf profiles on the box (400 Hz, dwarf call-graphs), saved at
`/tmp/es40-idle.perf.data` and `/tmp/es40-boot.perf.data`:

- **Boot phase** (`es40-boot.perf.data`): **~30% of samples in media-hotswap
  polling.** `CFloppyController::check_state()` runs every main-loop iteration
  and, per drive, takes a recursive mutex then constructs+destroys a
  `std::deque` inside `CDiskFile::service_pending_media_actions` →
  `take_pending_actions` — just to find the mailbox empty. The self-time smear:
  `pthread_mutex_lock` 9% + `cfree` 9% + `malloc` 6.7% + deque
  `_M_initialize_map` 3.3%. **This is target #1 — cheap and large.**
- **Idle at desktop** (`es40-idle.perf.data`): CPU thread pinned at 100%
  emulating NT's idle loop. Self-time: ~35% dispatch (`CAlphaCPU::execute` +
  `jit_run`), ~21% JIT-emitted code, 9% `jit_hw_mtpr` (PAL traffic), ~15%
  software TLB (`FindTBEntry`+`virt2phys`+`get_icache`), ~3% VGA. **JIT codegen
  is NOT the bottleneck — the C++ dispatch/helpers around it are.**
  (Idle-sleep/WTINT is explicitly a **non-goal**: the tile pauses when unwatched.
  Operator, 2026-08-10.)

## Optimization queue — do these in order, A/B each

1. ~~**Media-mailbox fast-flag**~~ **DONE 2026-08-11, fork `6a525d1`.**
   Kernel checkpoint 198.7 s → 149.6 s wall (−24.7%), es40 CPU 206.3 s →
   155.6 s (−24.6%), 3×3 interleaved runs, binary.sha256-verified. Details in
   `alpha-nt-add.md` §10 "A/B №1". New control binary for future A/Bs:
   `es40src/src/es40.652f7c2` (`a2a21bde…`); the fast-flag build is
   `3745cfb2…`. **The commit adds a virtual to `CDisk` — clean-rebuild after
   pulling it; stale objects are vtable-broken.** Live rig still runs
   `a2a21bde…` (boot-phase delta only — adopt on next natural restart).
2. **Dispatch overhead (the big open item)** — fresh 60 s idle-at-desktop
   profile on the -O3 build (quiet host, 2026-08-11): `execute()` ~21%,
   `jit_run` ~14%, `jit_hw_mtpr` ~9%, `jit_read` ~8–10%, `virt2phys` 3.7%.
   Levers: interpreter round-trips per JIT block, poly-successor chaining,
   block-JIT register allocation. **Don't revisit the trace tier**:
   `config_debug.h` (~line 205) records it as a measured NET LOSS (2026-06,
   92 vs 120 VUPS) and names chaining+regalloc as the real lever. A
   `-DJIT_STATS` build (JIT_VERIFY off) prints compiled-vs-interpreted
   coverage — size the candidates with it before designing anything.
3. ~~**Software TLB fast path**~~ **CLOSED NULL 2026-08-11.** Verified
   per-page hint cache in front of `FindTBEntry` measured zero on boot A/B
   (3 concurrent pairs, paired CPU deltas ±0.6 s) and the paired idle
   profiles show FindTBEntry < 1% on -O3 — the scan is no longer a cost.
   Patch preserved on fork branch `tlb-hint-experimental` (null result in
   the commit message).
4. **Build flags — -O3 ADOPTED** (+2.4% kernel wall, +2.8% CPU, zero-overlap
   3×3). `./configure` on the box now bakes it in (`CXXFLAGS="-g -O3"` at
   configure time; the macro appends `-mavx2 -mfma`); plain `make` in
   `es40src/src` reproduces the adopted binary. Controls kept alongside:
   `es40.O3` (=adopted, `ade17cfa…`, .text-identical to the canonical
   `688428…`), `es40.652f7c2`, `es40.baseline`. **LTO and PGO still open**
   as separate one-change A/Bs.
5. ~~**VGA/llvmpipe**~~ **DEAD (operator, 2026-08-11)** — the tile will drop
   the SDL+X11 layer entirely and wire es40 straight into the video capture
   pipeline, MAME-IRIX style (shm framebuffer export + injected input; the
   `mouse.absolute` patch was written for exactly that transport). Do not
   optimize SDL/X11/llvmpipe paths — dev/bench-only.

**Tile roadmap constraints (operator, 2026-08-11)** — these order the work:

- **No golden savestate exists yet** — only the `m2-desktop` disk+ROM cold
  snapshot. es40's native SaveState/RestoreState (format 2.1; a trigger
  exists at `Serial.cpp:795` → `autosave.axp`) is UNVALIDATED with the JIT
  build. The tile's instant-resume goal (< 5 s restore) depends on it —
  smoke-test save→kill→restore→framebuffer-verify early; it's the riskiest
  unknown in the tile plan.
- **State-layout-changing optimizations are compatibility-free until the
  first golden savestate is baked** (e.g. TB_ENTRIES 16→128, if profiling
  justifies it). Land them BEFORE baking; afterwards each one forces a
  re-bake.
- **Headless capture backend** (shm framebuffer export + socket input,
  replacing SDL/X11) is a required feature item for the tile — build it
  before the golden bake so the restored device environment matches the
  shipping wiring.

Note for #2: dispatch is an *idle/desktop-profile* cost — the bench's
`--until kernel` wall-clock is the wrong metric. Measure steady-state with
paired holds + perf (`bench/idle-profile-pair.sh`), plus a guest-side
workload once the telnet channel exists.

## Savestate: FIXED and shipped (2026-08-11, 24h-mission phase 1)

The smoke test found and fixed four restore-blocking bugs (fork commits
`ab75e70`, `d73e4dc`, all validated on the rig by full save→kill→relaunch→
restore cycles with framebuffer proof):

1. `get_primes(0)` infinite loop hung every restore (empty CD-ROM drive).
2. PCI BAR mappings were never re-registered after the config-space fread
   (S3 framebuffer BAR unmapped → guest ran fine but invisible).
3. S3 saved only a vestigial struct — with a raw VRAM pointer in it. Added
   a magic-guarded video section (vga + s3 register files + real VRAM at
   `vga.memory`/`vga.svga_intf.vram_size`), pointer-preserving restore,
   full derived-state recompute.
4. `stop_threads()` destroyed the S3 thread; the recreated thread re-ran
   `bx_gui->init()`, dropping the SDL texture that only a *resize*
   recreates — every frame upload silently discarded (root-caused by
   dumping correct desktop pixels at the upload call). S3 now pauses
   across stop/start; only the destructor stops it.

New primitives: serial-menu option **5 = save-and-exit** (threads are
stopped in the menu, so state+disk exit as an atomic coherent pair — a
state saved with option 3 while the guest keeps writing NTFS bugchecks
STOP 0x7B on restore) and **`ES40_RESTORE=<file>`** (restore before the
main loop: no SRM/AlphaBIOS/boot — interactive desktop in seconds).

**Golden pair: `milestones/m4-warm/`** = {nt.img, autosave.axp, flash.rom,
es40.cfg} baked via option 5 from a settled desktop.

**KNOWN REMAINING BUG — post-restore guest damage under load:** an
instant-resumed guest looks fine (desktop, Start menu) but Computer
Management freezes mid-load, while a cold-booted guest loads it fine.
Prime suspect: CAlphaCPU's wall-clock RPCC/interval-timer baselines
(`cc_last_sync`, `next_timer_fire`, `tick_last_fire` — std::chrono members
OUTSIDE `state`) are not reset to the restored `state.cc`, so the guest
sees a violent clock discontinuity. Fix candidate: re-anchor those in
CAlphaCPU::RestoreState. Until fixed, restore-based benching is parked.

## The 24h-mission metric (operator-defined, 2026-08-11 ~03:15)

**Goal: 2× desktop-interaction throughput** = a scripted UI sequence —
launch Computer Management (MMC + snap-ins: disk IO + CPU, deliberately
heavy) — completes in half the baseline time. Harness:
`/data/vms/soltest/ALPHA-nt/uibench/uibench.sh <name> <binary> <iters>
[--cold|--ref]` — private Xvfb `:93`, fresh disk copy from m4-warm per
iteration, xdotool injection (`windowfocus` first — a bare Xvfb never
focuses the SDL window on its own), ImageMagick RMSE against
`refs/compmgmt-ref.png` for completion, `refs/desktop-ref.png` for
readiness. `--cold` = full SRM boot per iteration (~3 min, the reliable
mode today); restore mode is the fast path once the post-restore bug is
fixed. Results append to `uibench/results.log`. Detection is CROP-based
(taskbar strip for readiness, populated MMC tree pane for completion) —
whole-screen RMSE broke on the guest's "Active Desktop Recovery"
background (cosmetic guest damage from tonight's hard kills; consistent
across iterations so A/Bs stay valid; clean up when re-baking).

**BASELINE (canonical -O3 `63ae339f`, quiesced host, 2026-08-11 05:25):
Computer Management launch = 28.28 / 23.03 / 23.62 s (mean 25.0 s).
The 2× goal: ≤ 12.5 s under the identical protocol.**

## Gallery integration (2026-08-11, operator directive)

Directive: wire w2kalpha into the gallery, remove the X11 wrapper (direct
capture, MAME-IRIX style), and raise the guest to 1280x1024.

**DONE + VERIFIED:**
- **Resolution 1280x1024 / High Color 16-bit** set in the guest (Display
  Properties; the S3's 4MB VRAM caps 32-bit here, so W2K auto-selected
  16-bit). Persisted in the guest registry; survives cold boot.
- **Direct shm capture, no X11** — fork `66c5b2f`: es40 publishes its S3
  framebuffer to a POSIX-mmap file in the streamhost IFB1 format
  (`src/gui/shmfb.h`), gated on `ES40_SHM_PATH`; `dimension_update`
  skips all SDL window calls in that mode so es40 runs under
  `SDL_VIDEODRIVER=dummy` with NO X server and NO window. Verified two
  ways: (1) pixel-exact 1280x1024 desktop read from shm vs the SDL window;
  (2) fully headless (no DISPLAY, dummy driver) cold boot AND instant-
  resume from the golden, both publishing correct frames. Reader:
  `uibench/shmread.py`.
- **New golden `milestones/m5-1280/`** {nt.img, autosave.axp, flash.rom,
  es40.cfg} baked at 1280x1024 via menu-5 save-and-exit. Headless
  `ES40_RESTORE` from it → 1280x1024 desktop in shm in seconds.

**REMAINING — the input socket (clearly scoped, NO streamhost changes):**
es40 needs a unix-socket input server speaking mamectl/1 so the existing
streamhost `mamesock` backend drives it (as it drives IRIX). Verified
viable: the streamhost KEY verb carries (port, field-NAME), and the 104
field-names are UNIQUE (an earlier worry about Newport-matrix collisions
was wrong — checked), so es40 maps each field name → BX_KEY and injects via
`theKeyboard->gen_scancode`. Design:
- `src/gui/ctlsock.h`: listen on `ES40_CTL_SOCK`, accept one client, send
  `HELLO mamectl/1 1 w2kalpha caps=natkbd,savest screen=1280x1024`, poll
  from `handle_events()` (non-blocking), ack every verb `<seq> OK`.
- Keyboard: field-name → BX_KEY table (104 entries), gen_scancode make/break.
- Pointer: `MOVEA x y` absolute via CLOSED-LOOP homing on the S3 hardware
  cursor (`s3.cursor_x/cursor_y` exist) — emit corrective PS/2 deltas via
  `mouse_motion` until the S3 cursor reaches the target; this is the
  standard fix for the guest's 2x PS/2 acceleration (no open-loop drift).
  `DOWN1/UP1..DOWN3/UP3` → button state. Mirrors streamhost `mame_sock.rs`.
Then the gallery tile: scaffold `scripts/tiles-registry.py new w2kalpha
--tier 3`, tile dir mirroring `tiles/irix` (SH_CAPTURE=shm, SH_SHM_PATH,
SH_INPUT_BACKEND=mamesock, SH_MAMECTL_SOCK, SH_RESET_MODE via ES40_RESTORE
from m5-1280), launch script runs es40 headless. Keep DISABLED until
framebuffer+input+reset pass (playbook gate).

## Still queued

- **Guest telnet channel** (operator): dec21143 networking + W2K Telnet
  Server for text-driven load scenarios; then the guest de-bloat list.
- **Config experiments**: remove `ali_usb` (issues #114/#169); test
  `idle_nap`. Device-set changes before any further golden bakes.

## How to measure (the bench harness)

```
ssh lab '/data/vms/soltest/ALPHA-nt/bench/bench.sh <name> [--until kernel] \
         [--binary PATH] [--timeout S] [--record-all] [--hold-secs S] [--keep]'
```

- Boots a **throwaway ZFS clone** of `milestones/m2-desktop/{nt.img,flash.rom}`
  under a private Xvfb (`:80`+slot). Never touches the live rig. Up to 4
  concurrent (atomic slot claim). Teardown via `clone-guard kill-pidfile`.
- **Checkpoints** (framebuffer RMSE vs `bench/refs/`): `serial srm arc osloader
  kernel desktop`. `--until kernel` = ~3.5-min A/B loop; full desktop ~5 min.
  Result JSON per run + appended to `bench/results.log`.
- **Baselines are EPOCH-BOUND — never compare across epochs** (host load and
  turbo shift the clock base; the NVRAM change shifted the firmware phase):
  - loaded host, O2 fast-flag (`3745cfb2…`): kernel ≈ 150s, desktop ≈ 250s
  - quiesced host, -O3, old NVRAM: arc 76.5 / kernel 118.7 / desktop 179.5
  - **CURRENT (quiesced, -O3, 5s countdown + no ARC memtest, 2026-08-11):
    serial 0.1 / arc 65.9 / kernel 82.8 / desktop 140.4** — a desktop run
    is ~3 min with teardown, `--until kernel` ~1.5 min.
- **Run A/B arms as CONCURRENT PAIRS** (two slots, same instant) — identical
  host/turbo conditions per pair, half the wall time; see
  `bench/ab-tlb.sh` for the pattern, `bench/idle-profile-pair.sh` for the
  paired-perf variant. Host is 8 cores + SMT: cap concurrent measurement
  runs at 2 (plus the rig) and `taskset` precision runs to distinct
  physical cores (CPU N and N+8 are siblings).
- Host quiesce state: 52 `streamhost@*` tile units stopped 2026-08-11
  (restore list `/data/vms/soltest/ALPHA-nt/quiesced-units-20260811.txt`);
  debridge-7f3a experiment + openvms killed on operator's order. k3s and
  non-streamhost guests untouched.

**The A/B recipe for target #1:**
```
# control (pre-patch): note the baseline binary
bench.sh ctrl --until kernel --binary /data/vms/soltest/ALPHA-nt/es40src/src/es40.baseline
# build your change, then:
bench.sh flagfix --until kernel     # uses the freshly built es40
```
Compare `kernel` checkpoint seconds across 2–3 runs each. **Host is loaded
(load 8–13): relative % in perf is trustworthy; wall-clock A/B needs back-to-
back runs, ideally a quiesced host.** For CPU-cost that survives host noise,
also `perf stat -e task-clock` the es40 pid over a fixed boot window rather than
trusting wall-time alone.

## Build / commit / verify loop

- Edit locally → `scp` the file to `es40src/src/...` on the box → build **on the
  box**: `cd /data/vms/soltest/ALPHA-nt/es40src/src && touch <file> && make -j6`
  (top-level `make` says "nothing to do" — build in `src/`). Needs the extracted
  deb tree already on RUNPATH; binary self-links fine.
- Commit on the fork with a descriptive body; **push via SSH remote**:
  the box's git can't auth to github over https, so push from the workstation —
  `git clone lab:.../es40src …` then a `git@github.com:Wnt/es40` remote, or cherry
  the commit over. (Baseline preserved at `es40src/src/es40.baseline` — don't
  overwrite it; it's the control.)
- Update `alpha-nt-add.md` with each result. Repo push runs the **pre-push
  gate**: it fails on repo↔box drift. If `serve/tiles.json` drifts, re-harvest
  on a branch: `git switch -c h && scripts/dev/harvest.sh --apply --commit --tree
  tiles-json --tree serve && git switch main && git merge h`. Harvest **refuses
  to run on main directly** (use a branch). `gallery-manifest.json` overrides are
  a live overlay — leave them to the operator.

## Traps that already bit (don't relearn these)

- **Milestone `flash.rom` has no autoboot script** (saved 22:52, script
  persisted 23:00). A guest restored from the milestone pair parks at `P00>>>`
  forever. The bench copies the **live rig's** `run/rom/flash.rom` instead. Any
  new restore path must too.
- **`clone-guard kill-pidfile` only** for killing bench/clone es40 — never
  `pkill -f es40` (matches your own ssh). Resolve procs via `/proc/<pid>/exe`.
- **Never kill the live rig by name.** Its es40 pid is in `run/es40.pid`.
- **es40 blocks on startup until BOTH serial ports have a client** — pumps.py
  handles it; don't launch es40 without its pump.
- **macOS VNC**: refuses passwordless VNC (hence `-rfbauth`); composes
  Option+letter into a glyph so Alt-combos never reach the guest (use TigerVNC).
  Ctrl-combos and Ctrl+Alt+End (=C+A+Del) work.
- **Relay channel**: if the operator says chat replies are going missing, mirror
  key updates into their `screen` session (`screen -ls` for the id;
  `screen -S <id> -p 0 -X stuff "cat <file>\n"`). Keep replying normally too.

## First actions for the next session

1. Read the boot-poll output / VNC the live rig: confirm mouse reacts, note
   whether pointer speed is ~1:1 (patch working) or needs the guest accel redo.
2. `perf report -i /tmp/es40-boot.perf.data` to re-anchor on the media-poll
   hotspot, then implement target #1 (atomic fast-flag).
3. `bench.sh ctrl --until kernel --binary …/es40.baseline` ×3, then
   `bench.sh flagfix --until kernel` ×3; record the delta in `alpha-nt-add.md`;
   commit the fork patch; push.

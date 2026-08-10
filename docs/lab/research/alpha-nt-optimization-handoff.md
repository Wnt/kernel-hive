# w2kalpha emulator-optimization — session handoff

**Written 2026-08-11, end of the profiling/harness session. Next session: pick
up at "Optimization queue" §1 and start making es40 faster.** Full background is
[`alpha-nt-add.md` §10](alpha-nt-add.md); this file is the working handoff —
what's done, what's next, and the traps that will bite.

## The mission

The installed `w2kalpha` guest works but the emulator is slow (75-min install,
one host core saturated even at idle). Goal: **profile-guided optimization of
the es40 emulator**, not the guest OS. Measure → change one thing → A/B on the
bench → keep or revert. Source changes go on the fork **github.com/Wnt/es40** as
commits (operator rule: **no .patch files**).

## State at handoff (all committed + pushed)

- **Repo `main` @ `ab440cd`** (pushed): `alpha-nt-add.md` §10, two `tiles.json`
  harvests. Working tree clean. Box-sync 233/233 MATCH, pre-push gate green.
- **Fork `Wnt/es40` main @ `652f7c2`** (pushed): the one source patch so far —
  `gui { mouse.absolute }` (the VNC mouse fix). Built binary on the box is
  `sha256 a2a21bde…`; the pre-patch baseline is preserved at
  `es40src/src/es40.baseline` (`29ecb300…`) — **this is the A/B control binary.**
- **Live rig** `/data/vms/soltest/ALPHA-nt/run/`: restarted onto the patched
  binary + `mouse.absolute = true`, cold-booting to desktop as this was written.
  Serves operator VNC at `vnc://<box>:5964` (pw `alpha2000`, unit
  `alpha-nt-vnc64.service` on Xvfb `:64`). Clean NTFS shutdown was done before
  the restart.
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

1. **Media-mailbox fast-flag (START HERE).** Add a `std::atomic<bool>` set when
   an action is enqueued, checked *before* any lock/alloc in
   `service_pending_media_actions` (and the floppy `_if_idle` caller). Empty
   mailbox = one relaxed atomic load, no mutex, no deque. Files:
   `es40src/src/DiskFile.cpp` (`service_pending_media_actions` ~816,
   `take_pending_actions` ~213, mailbox class), `Disk.cpp:217`,
   `FloppyController.cpp:120`. Expected: erase most of that ~30% boot smear.
2. **Dispatch overhead** — why is `execute()` still ~35% with ASMJIT on? Look at
   block chaining / trace length / interpreter round-trips per JIT block.
3. **Software TLB fast path** — small direct-mapped host-side cache in front of
   `FindTBEntry`.
4. **Build flags** — configure default is `-g -O2 -mavx2 -mfma`. Try `-O3`, LTO,
   PGO (profile a boot, rebuild with it). Cheap, possibly free 10–30%.
5. **VGA/llvmpipe** — only ~3%, do last.

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
- **Validated baseline** (loaded host): arc 159s / kernel 202s / desktop 307s.
  ~189s of that is firmware (SRM memtest + 30s AlphaBIOS countdown) — Windows is
  ~105s, so **`--until kernel` is where boot-phase CPU wins will show**.

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

# irix: prove/fix savestate-restore trust, then true start-paused — handover

> **STATUS 2026-08-11 (same day, later session): phase 2 IMPLEMENTED; phase 1
> SKIPPED by operator decision** — the operator validates start-paused (and
> restore behaviour generally) by eye in the browser, which is cheaper than an
> automated soak. Implementation: `IRIX_START_PAUSED` in
> `streamhost/tiles/irix/x11-runtime.sh` (freeze_at_state; charge-at-first-wake
> via `.state-unvetted`; `charge_state_budget`), fixture flips it on with
> `SH_IDLE_PAUSE_WARMUP_SECS=0`. Design record:
> `docs/guests/irix.md` §"True start-paused (2026-08-11)". The budget stays as
> defense in depth (charge persists until a probe window clears it — the
> simpler of the brief's two options, chosen because restore is treated as
> trustworthy-until-proven-otherwise).

**Written 2026-08-11 (session cleared right after; this doc is the whole
brief).** Operator's decision, in order:

1. **Phase 1 — the "emulator bug" first.** Establish whether MAME
   savestate restore for `indy_4610` still has a residual
   renders-fine-but-dead failure mode; fix what surfaces. Evidence either way
   is the deliverable — the restore-trust question gates phase 2's design.
2. **Phase 2 — true start-paused.** `systemctl start streamhost@irix` should
   end with the guest AT the checkpoint state, SIGSTOPped, ~0 CPU, waking on the
   first visitor session — like the QEMU fleet since 2026-08-11
   ([`instant-ready-bringup.md`](instant-ready-bringup.md)).

## What today already landed (context you build on)

- **w2kalpha idle auto-pause ON** — es40 fork `fc82f05` `host_freeze_reanchor`
  absorbs host-side pauses (zero cc billed; interval timer, TOY/RTC, ACPI PM
  timer re-anchored). Proven by 6-min and 25-min SIGSTOP soaks with apps open.
  Repo `8ba52b6`; `docs/guests/w2kalpha.md` §idle-pause.
- **Fleet instant-ready** (`cbff4cb`, `d64456e`): 55 QEMU loadvm stations launch
  `-loadvm golden -S` → restored-but-paused; first session's unconditional
  `cont` (idle.rs) wakes them. Census: 53 paused, only amiga/daybreak/
  nextstep/star run (never-pause: `SH_IDLE_PAUSE_SECS=0` ⇒ NO IdlePauser ⇒
  `-S` would leave them permanently dead — that exclusion is load-bearing).
  irix + w2kalpha SIGSTOPped. sailfishos found broken independently (guest
  image AND `/usr/local/lib/streamhost/tiles/sailfishos/` missing; unit
  crash-loops; left stopped + disabled).

## Phase 1 — restore trust

**Read first:** `docs/guests/irix.md` §"Instant restore — MAME savestate
(issue #44, 2026-08-04)" — the audit, the patch, the capture/restore flow, the
measurements. Get the nuance right:

- The historical trap ("a state that RENDERS is not a state that WORKS") was
  the PRE-#44 binary: Newport VRAM saved upstream, RAM not — pixel-perfect
  chooser, dead CPU. `mame-indy-savestate.patch` closed the audited gaps
  (sgi_mc RAM banks + memcfg replay, mips3 mode/compare re-arm + DRC flush,
  newport host-port + shm republish, edlc fifo shadows, hal2 clock cache,
  hle_mouse accumulator re-baseline, ds1386, vino, z80scc…).
- Post-fix verification was substantial (restore 4.4 s to frame, 5.6 s to
  interactive; consecutive restores; save-from-restored; 15-min soak). The
  `.state-tries` budget + livewatch pointer probe are **defense in depth**,
  not a tracker for a known live bug. No post-#44 dead restore is documented.

**So phase 1 is evidence-first:**

1. **Soak the restore path adversarially** on a namespaced clone (or the
   production station stopped — operator prefers the least-work rig; clones only
   when cheaper). N× restore cycles (dozens), each verified for
   INTERACTIVITY, not pixels: pointer probe (`MOVEA`/VC2 closed loop) +
   serial exec answer. Vary conditions: host load, long SIGSTOP before/after
   restore (the w2kalpha-style clock gap), restore-under-input, audio DMA in
   flight (hal2 was a livelock class), uptime before save.
2. If a failure reproduces: fix in the MAME fork. Suspect-pattern from the
   es40 sibling fix: wall-clock/host-anchored members OUTSIDE the registered
   save state that are not re-baselined on load (es40's were `cc_last_sync`,
   `next_timer_fire`, `tick_last_fire`, `toy_offset`, PM-timer anchor).
   The #44 patch already re-baselines several such members — a residual one
   would look exactly like that.
3. If ~0 failures over a meaningful soak: document the measured rate and
   declare restore trustworthy; phase 2 then simplifies (budget becomes a
   formality).

**Fork/build/capture mechanics (the rebuild-orphans-states trap):**

- Fork `github.com/Wnt/mame` branch `irix`; patch stack under
  `scripts/build-guests/patches/mame-*.patch` (savestate patch is LAST in the
  stack); builders `scripts/build-guests/emulators/build-mame-irix.sh` (labhost)
  / `build-mame-macos.sh`. Production binary
  `/data/vms/streamhost/assets/irix/mame/sgi`.
- `provenance-golden.md5` binds the checkpoint state to the exact binary md5 —
  **ANY rebuild orphans every state** (registration signature) and the
  launcher then cold-boots loudly. After a MAME fix: rebuild → RECAPTURE
  (`scripts/build-guests/irix/irix-savestate/capture-checkpoint.sh`, station stopped;
  it pauses emulation, saves state + reflinks the disk INSIDE the same pause
  window — the (memory, disk) pairing is the invariant) → verify → promote.
- Measurement rules: `docs/lab/MEASUREMENT-METHODOLOGY.md`; bench numbers are
  epoch-bound; the station is core-pinned (`IRIX_CPUS`); `-frameskip 6` is
  load-bearing, do not touch.
- Probe pitfalls that produced FALSE "pointer dead" findings before:
  `shmpng.py --cursor` is invalid while fsn is on screen (red-crosshair
  lock-on); root's shell is csh (`env VAR=val cmd`). See `docs/guests/irix.md`
  §gotchas and `docs/lab/INPUT-DEBUGGING.md`.

## Phase 2 — true start-paused

Current blocker chain (all in `streamhost/tiles/irix/{x11-runtime.sh,
tile.env.fixture}`):

- Launch restores (`IRIX_STATE=golden`) and RUNS; `SH_IDLE_PAUSE_WARMUP_SECS=780`
  holds the first pause because **livewatch's pointer probe is the only
  budget-clearer** (`.state-tries`: ++ per restore launch at x11-runtime.sh
  ~L327-338; `rm` on passing probe ~L738; ≥2 ⇒ 390 s cold-boot fallback) and
  it cannot probe a paused guest. Pause-at-start today ⇒ budget silently
  expires ⇒ every launch becomes a running 390 s cold boot.
- Watchdog interplay is already solved: `mame_stopped()` — both watchdogs
  stand down while SIGSTOPped; labctl resumes before driving; the daemon
  reconciler re-pauses within grace+heal.

**Design agreed with the operator (option "charge at first wake"):**

- Launcher: restore → SIGSTOP immediately (do NOT increment `.state-tries` at
  launch — a paused guest exposes nothing, so there is nothing to vet yet).
- The budget increment moves to FIRST WAKE (livewatch observes the
  SIGCONT/resume — it already logs "MAME resumed — watching again"); the
  existing post-wake probe/relaunch machinery vets at the moment exposure
  begins and clears the budget as today.
- Mind the timing conflict: the idle pauser re-pauses 60 s after the visitor
  leaves, but the probe needs ~90 s of static frames to arm. Either let the
  charge persist until a probe eventually gets a window (correct but slow to
  clear) or give livewatch one deferred-pause window after first wake.
  If phase 1 ends with "restore trustworthy", this whole knot shrinks: keep
  the budget as a formality, pause at launch, warmup → 0.
- `SH_IDLE_PAUSE_WARMUP_SECS` drops to ~0 in the same change; fixture comment
  must be rewritten (it currently explains the 780 s in detail).
- Daemon side needs NOTHING: `session_started` already conts unconditionally;
  a start-paused guest converges the same way the QEMU `-S` stations do
  (pilot-proven on alpine).

**Acceptance (framebuffer is the only proof):** start → MAME state `T` at ~0
CPU with the restored desktop in shm; wake (session or SIGCONT) → pointer
probe passes + serial exec answers; budget bookkeeping observed correct
across: clean wake, dead-restore simulation (if reproducible), two
consecutive unvisited restarts (must NOT degrade to cold boot); reset path
(`labctl reset irix` = service restart) still lands paused-at-checkpoint;
`check-stream-tickets.py` green.

## Rules refresher (the ones this work will actually hit)

- Kill/stop clones only via `clone-guard`; resolve pids via `/proc/<pid>/exe`;
  never `pkill -f` from `ssh lab`.
- Namespace every scratch dir/socket/port under `/data/vms/soltest/`; the
  production station owns its tap/core-pin/ports.
- Gates before done: bash (`shfmt`+`shellcheck` via `scripts/lint/
  shell-sources.sh`), `node scripts/check-file-size.mjs --strict`,
  `make station-registry-check`; C++ (MAME fork) has no repo gate — the station's
  verification IS the gate.
- Deploy: mirrored files go through `scripts/dev/box-sync-push.sh` (the
  pre-push gate blocks on drift); launcher/fixture changes for irix are
  repo-tracked verbatim files; `scripts/dev/box-repo.sh --fetch sync` after
  pushing main.
- A parallel agent was active on labhost today (soltest rigs `debridge-7f3a`,
  `NSTAB-coldboot`, a host atarist MAME) — check `labctl ls` + running
  processes before claiming resources; leave their rigs alone.

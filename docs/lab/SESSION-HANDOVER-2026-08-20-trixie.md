# Session handover 2026-08-20 — trixie wave: nextstep + apple2

Continuation of the bookworm→trixie kiosk conversions. Read
[`MIGRATION-WAVE-BRIEF.md`](MIGRATION-WAVE-BRIEF.md) first — it is still the
brief, and its §2 rows for `nextstep` and `apple2` are still the acceptance
contract. This file records the state after the 2026-08-20 paused wave (two
worker attempts, both cleanly torn down; operator paused the wave mid-flight).

Both stations are **ACTIVE on bookworm**, operator-authorized to migrate, and
the ledger (`registry/bridge-suites.json`) correctly says `bookworm` for both.
Nothing is half-migrated; both rollbacks/teardowns were verified.

## nextstep — rolled back with a DIAGNOSED builder regression (not trixie)

Attempt 2 (2026-08-20 ~02:38) passed **every** trixie step — deps, the pinned
SDL3 3.4.14 source build, Previous r1847 + sdlscreen.c patch, and media staging
(attempt 1's curl SSL flake did not recur) — then failed at first light:

- **Root cause:** commit `085c074` (2026-08-11 tablet promotion) moved the
  `previous.cfg` write to *after* the first-light sequence (`3fbdf86` wrote it
  *before*). Any `NEW_OVERLAY=1` build since then boots Previous with no cfg —
  Main menu, then a "ROM file not found!" dialog (default `Rev_1.0_v41.BIN`).
  The live station never hit it because its overlay already carries the cfg.
- **Fix first, then rerun:** 2–3 lines in
  `scripts/build-guests/tiles/nextstep.sh` — write the cfg inside the
  new-overlay install step, before first light, as `3fbdf86` did. Land the fix
  on `main` alone (it is a builder fix, not a wave edit), then a plain
  `migrate-tile.sh nextstep --suite trixie` rerun from the worktree is expected
  to be green. Keep the SDL3 3.4.14 pin; change nothing else.
- **Settled side-question:** the build log's non-fatal `ERROR: Could not
  initialize the SDL library:` is the builder's headless probe
  (`previous --version … || true`, `nextstep.sh:495`, no DISPLAY) —
  headless-by-design, harmless, but it verifies nothing; the real gates are the
  `ns_ready` pixel predicates and `tile-accept.sh`.

State: station active, frame-verified byte-identical to the bookworm golden;
box-sync clean (258 MATCH); postmortem paragraph in `_notes.nextstep`.
Evidence: `/data/vms/sandbox/nextstep-trixie-rerun/evidence/attempt-2/`
(before/after PNGs, the two failure frames `first-light.png` +
`cold-boot-workspace.png`, build log). The aborted overlay is kept on the box
as `stations/nextstep/overlay.qcow2.trixie-failed`; delete it when the rerun
lands.

## apple2 — clone proof mostly green, two pointer anomalies open

Proof rig ran on a sandbox clone only; the live station was never touched. Full
detail + resume recipe:
[`research/apple2-trixie-proof-state.md`](research/apple2-trixie-proof-state.md).

- **(a) LinApple under g++ 14: PASS.** Clean compile including `Video.cpp`
  (the historic failure), against trixie's sdl12-compat (`libsdl1.2-dev
  1.2.68-3` over SDL 2.32.4). No builder change was needed.
- **(b) motion + buttons, no grab: PASS with one anomaly.** Probes
  `abs 16000 16000` → (501,376) and `abs 8192 8192` → (256,193) are exact 1:1;
  menu opens/closes by click; no grab/vanish. But the *first move after ~5 min
  idle* (`abs 16000 12000`) landed at the top-left menu-bar corner instead of
  the target.
- **(c) 1:1 + slot map: PARTIAL.** Slot map (mouse 4 / clock 5) asserted, no
  "No mouse card found" dialogs. 1:1 is **not proven** until the idle-first-move
  anomaly and one 47 px-off post-click position are explained. Prime suspects
  (unverified): pin-sync re-handshake after idle, and the in-guest
  pointer-watchdog racing the QMP abs.

The clone overlay (with full GEOS state) survives at
`/data/vms/sandbox/apple2-trixie-proof/clone/overlay.qcow2`; relaunch with
`clone/clone.sh` after re-taking port claims (the previous `port/15817` +
`port/5917` claims were released at teardown). Evidence PPM/PNGs under
`/data/vms/sandbox/apple2-trixie-proof/evidence/`.

## Worktrees and claims

- `/data/vms/sandbox/nextstep-trixie-rerun/` — branch merged to main; sandbox
  **held** (it holds the attempt-2 evidence). gc after the rerun lands.
- `/data/vms/sandbox/apple2-trixie-proof/` — branch merged to main; sandbox
  **held** (it holds the clone overlay + evidence). gc after apple2 lands.
- `/data/vms/sandbox/qwen-{nextstep,apple2}-trixie/` — previous session's
  worktrees, fully merged/empty; `wt.sh gc` candidates, but check gc will not
  touch the two sandboxes above first.
- `/data/vms/sandbox/migrate-nextstep-trixie/` — attempt-1 evidence; archived
  copy exists in the nextstep-trixie-rerun evidence dir, so removable.

## Order of work

1. Fix the `previous.cfg` ordering in `nextstep.sh` (small, lands on `main`
   alone — do not bundle it into a wave branch).
2. Rerun the nextstep migration; accept per brief §2, flip the ledger, delete
   `overlay.qcow2.trixie-failed`.
3. apple2: resolve the two pointer anomalies on the surviving clone per the
   state note's resume steps; that completes proofs (b)(c).
4. apple2 migration + manual bake (`info status` = running assertion, settle by
   frame, not timer); accept per brief §2, flip the ledger.
5. Report per brief §5; resolve `bridge-suites.json` merges as a per-key union
   (brief §6).

# Session handover 2026-08-20 — trixie wave: nextstep + apple2

Continuation of the bookworm→trixie kiosk conversions. Read
[`MIGRATION-WAVE-BRIEF.md`](MIGRATION-WAVE-BRIEF.md) first — it is still the
brief, and its §2 rows for `nextstep` and `apple2` are still the acceptance
contract. This file only records what this session changed about the world.

## Corrections to the wave brief's picture

- **`nextstep` and `apple2` are both ACTIVE.** The brief's "operator-stopped"
  note for nextstep is stale (2026-08-10). Both stations are running with
  GOLDEN=yes; the operator has authorized migrating both.
- Ledger (`registry/bridge-suites.json` `tiles`): both still `"bookworm"`.
  Correct — neither migration has landed.

## nextstep — one attempt made, failed on a transient, rolled back clean

The 2026-08-20 ~01:26 attempt (driver: `migrate-tile.sh` flow) got through
every trixie-specific step — build deps into the overlay, **SDL3 3.4.14 source
build, Previous r1847 checkout + sdlscreen.c patch all succeeded** — then died
at media staging: `curl: (56) OpenSSL ... unexpected eof` from the archival
source, rc=1. A network flake, not a trixie problem. The station stays
classed **mechanical**; a plain rerun is expected to just work. Keep the
SDL3 3.4.14 pin (brief §1).

The driver had been abandoned mid-run, so the rollback was performed by hand,
exactly per the driver's own recipe: surviving builder QEMU (held the overlay)
killed by pidfile-verified `/proc/<pid>/exe`, bookworm overlay restored from
`.bookworm-bak`, unit restarted, **frame-verified** against the golden scene
(full 1120×832 grey Workspace, Dock right, no black margins).

State on the box now:

- `stations/nextstep/overlay.qcow2` — the restored bookworm overlay (live).
- `stations/nextstep/overlay.qcow2.trixie-failed` — the aborted attempt, kept
  for the postmortem; delete once this handover is acted on.
- `/data/vms/sandbox/migrate-nextstep-trixie/` — `build.log` (full trace of
  the successful build steps + the failure) and `before-bookworm.png`.

One check owed on the rerun: the build log shows a non-fatal
`ERROR: Could not initialize the SDL library:` right after the sdlscreen.c
patch. Confirm that step's smoke check is headless-by-design before trusting
it; if it is real, the builder would have shipped a Previous that never ran.

The postmortem paragraph is already in `_notes.nextstep` of
`registry/bridge-suites.json` (this branch).

## apple2 — untouched, clone proof still owed

No attempt was made. Station, overlay and ledger are exactly as the wave brief
describes. The **risky** classification stands in full: prove on a sandbox
clone first — (a) LinApple compiles under g++ 14 (`Video.o`), (b) patched
`Frame.cpp` gets motion + buttons with no grab, (c) MouseInterface tracks 1:1
— re-assert clock slot 5 / mouse slot 4, and remember apple2 does **not**
self-capture: assert `info status` = running at bake time yourself (brief §2
cross-cutting facts).

## Worktrees and claims left for the next session

- `/data/vms/sandbox/qwen-nextstep-trixie/repo` — branch
  `qwen-nextstep-trixie`, carries the ledger postmortem + this handover.
  Land it (or continue the rerun on it), then `wt.sh gc`.
- `/data/vms/sandbox/qwen-apple2-trixie/repo` — branch
  `qwen-apple2-trixie`, clean, no commits. Reuse for the apple2 attempt or
  `wt.sh rm` it.
- Both `kh-claim` sandbox claims are still held under those names.

## Order of work

1. Rerun the nextstep migration (mechanical; the media fetch was the only
   failure). Accept/reject per brief §2, land, flip the ledger to `trixie`.
2. apple2: clone proof (a)(b)(c), then migrate, manual bake with the
   `info status` running assertion, accept per brief §2.
3. Report per brief §5; resolve `bridge-suites.json` merges as a per-key
   union (brief §6).

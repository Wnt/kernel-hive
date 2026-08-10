# Agent CI exit rule — green before done

Reusable brief snippet for any agent (Jules session **or** Claude subagent)
whose branch is intended to merge to `main`.

## The rule

**Make the full CI quality gate green before you report "done".** An agent that
cannot get the gate green reports **BLOCKED** (with the failing command and its
output) — never "done". "It builds on my machine" and "the change is small" do
not exempt a branch; red is not done.

You only owe the gate for the languages your branch **touches**, plus the two
cross-cutting gates, which every branch owes:

- **file-size budget** — `node scripts/check-file-size.mjs --strict`
- **generated-file drift** — `make tile-registry-check`

Plus one gate CI cannot run, enforced by the pre-push hook whenever the box is
reachable: **box-sync drift** — `scripts/dev/verify-box-sync.sh` (see below).

The gate is strict on hygiene and debt (unused
code/deps, file growth, stale generated artifacts), pragmatic on style,
runtime-aware (Python-2.6 in-guest agents are held to their own reality, not the
modern budget).

## Canonical gate commands

Run from the repo root. These are exactly what `.github/workflows/quality.yml`
(`static` job) runs, in order.

```sh
# 1. per-language lint — only for the languages you touched
#    TS/JS (spa/):
( cd spa && npx eslint . --max-warnings=0 && npx knip )
#    Rust (streamhost/):
( cd streamhost && cargo fmt --all --check && cargo clippy --all-targets -- -D warnings )
#    Python (scripts/):
ruff check scripts && ruff format --check scripts
#    Bash (*.sh + scripts/labctl):
shfmt -d $(bash scripts/lint/shell-sources.sh) && shellcheck $(bash scripts/lint/shell-sources.sh)

# 2. cross-cutting file-size budget (every branch)
node scripts/check-file-size.mjs --strict

# 3. generated-file drift (every branch)
make tile-registry-check          # byte-parity, non-mutating
#   or the regenerate-and-diff form CI runs on a clean checkout:
scripts/check-generated-drift.sh --regen

# 4. tests for the language(s) you touched
( cd streamhost && cargo test --workspace )   # rust.yml
( cd spa && npm run build )                   # spa.yml (tsc + vite)
```

## Box-sync drift — the one gate CI cannot run

`scripts/dev/verify-box-sync.sh` MD5-gates every documented repo↔box mirror pair
(see the "Box-sync pairs" table in [`scripts/README.md`](../../scripts/README.md)).
It needs `ssh lab`, which GitHub Actions does not have, so it is **deliberately
NOT in `.github/workflows/quality.yml`** — a job that can never reach the box
would be permanently red, and a permanently-red job is worse than none.

Instead it runs from `.claude/hooks/pre-push-gate.sh`, probe-gated:

| Environment | Behaviour |
|---|---|
| Box reachable (`ssh lab` answers within 4 s) | Runs the check. **Any drift hard-fails the push.** |
| Box unreachable (public clone, offline laptop, cloud VM without the door) | Prints `skip (ssh lab unreachable)`; never fails. |
| GitHub Actions | Never runs it at all — the workflow has no box-sync job. |

The check itself is placeholder-aware: pairs marked `scrub` are deployed with
the operator's real address substituted in, so their box-side hash is taken
**after** reversing the substitution, on the box, inside the one batched SSH
session. Without `registry/local.env` those pairs report `UNCHECKED`, which does
not fail the gate — they never silently pass and never spuriously fail.

```sh
scripts/dev/verify-box-sync.sh            # only rows needing attention, grouped
scripts/dev/verify-box-sync.sh --all      # every row, including MATCH
scripts/dev/verify-box-sync.sh --table    # TSV for scripting
```

Fix drift **per row**: the repo is authoritative for source; the box is
authoritative for generated/live artifacts (`tiles.json`, the golden manifest's
live reset allow-list). `MISSING_ON_BOX` means "never deployed"; `MISSING_IN_REPO`
means "stale or scratch on the box" — delete it there rather than adopting it.

Run them all locally in one shot with the pre-push hook
(`.claude/hooks/pre-push-gate.sh`) — see below.

## File-size budget

`scripts/check-file-size.mjs` enforces per-dialect line-count caps. Soft cap = a
`~` warning that still passes; hard cap = fails under `--strict` (CI).

| Dialect | Scope | soft | hard |
|---|---|---|---|
| TS/JS source | `spa/src/**` (not `*.test.*`) | 400 | 600 |
| TS/JS test | `**/*.test.*`, `spa/scripts/**`, `tests/**` | 800 | 1200 |
| Rust | `streamhost/**/src/**/*.rs` | 500 | 800 |
| Python | `scripts/**/*.py` (py2.6 guest agents excluded) | 400 | 600 |
| Bash | `**/*.sh` + `scripts/labctl` | 400 | 600 |

Generated artifacts and vendored trees are never budgeted.

`size-exclusions.json` (repo root) is a **bidirectional** ledger — `path` →
one-line reason. Rules:

- An excluded file **must still be over its hard cap.** If your change drops an
  excluded file to/under the cap, its exclusion goes **STALE** and `--strict`
  fails — delete the stale entry so the budget re-arms. (This is deliberate: it
  forces the cleanup to be recorded, not left rotting.)
- Do **not** add a file to the ledger just to dodge a split. Add it only with a
  real reason and a plan (usually a tech-debt inventory item).
- Splitting an over-cap file below its hard cap? Remove its exclusion in the
  same change.

## Generated-file drift

Every file emitted by `generated()` in `scripts/tiles-registry.py` (the manifest,
bring-up list, `registry/index.json`, the SPA catalog/registry, the serve JSONs,
…) must be byte-identical to what the typed registry + templates produce now.
Edit the **source** (`registry/tiles/*`, templates) and run
`make tile-registry-generate`, then commit the regenerated artifacts. Never hand-
edit a generated file. `make tile-registry-check` (and the CI `static` job) fail
on any drift.

**Regenerate after every MERGE, not just after every edit.** Generated artifacts
are the worst case for a three-way merge: they auto-merge *cleanly* and are then
*wrong*, because git resolves them line-by-line with no idea they are a
projection of the sources. Observed 2026-08-10 merging a tile branch —
`registry/generated/labctl-declarations.json` came out carrying
`nextstep.pointer_mode: "rel"` while `registry/tiles/nextstep.json` said `abs`,
a hybrid neither branch ever contained. No conflict was reported; only
`make tile-registry-check` caught it.

So in a multi-branch wave, run `make tile-registry-generate` **after each branch
lands**, not once at the end — otherwise a later merge resolves against
already-wrong generated content and the mess compounds.

## Pre-push hook

`.claude/hooks/pre-push-gate.sh` runs this whole suite locally and blocks a push
that carries the repo's Claude-session commit trailer while the gate is red.
Enable it once per clone (git allows a single `pre-push` hook):

```sh
ln -sf ../../.claude/hooks/pre-push-gate.sh .git/hooks/pre-push
#  or:  git config core.hooksPath .claude/hooks   (name the file 'pre-push')
```

Overrides: `GATE_ALL=1` gates every push (not only Claude-session ones);
`SKIP_GATE=1` bypasses in an emergency — **never** for a push to `main`.

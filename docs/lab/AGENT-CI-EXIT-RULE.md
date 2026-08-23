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
- **generated-file drift** — `make station-registry-check`

Plus one gate CI cannot run, enforced by the pre-push hook whenever labhost is
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
make station-registry-check          # byte-parity, non-mutating
#   or the regenerate-and-diff form CI runs on a clean checkout:
scripts/check-generated-drift.sh --regen

# 4. tests for the language(s) you touched
( cd streamhost && cargo test --workspace )   # rust.yml
( cd spa && npm test && npm run build )       # spa.yml (vitest, then tsc + vite)
python3 -m unittest discover -s scripts -p 'test_*.py'   # quality.yml, beside ruff
```

## Box-sync drift — the one gate CI cannot run

`scripts/dev/verify-box-sync.sh` MD5-gates every documented repo↔box mirror pair
(see the "Box-sync pairs" table in [`scripts/README.md`](../../scripts/README.md)).
It needs `ssh lab`, which GitHub Actions does not have, so it is **deliberately
NOT in `.github/workflows/quality.yml`** — a job that can never reach labhost
would be permanently red, and a permanently-red job is worse than none.

Instead it runs from `.claude/hooks/pre-push-gate.sh`, probe-gated:

| Environment | Behaviour |
|---|---|
| labhost reachable (`ssh lab` answers within 4 s) | Runs the check. **Any drift hard-fails the push.** |
| labhost unreachable (public clone, offline laptop, cloud VM without the door) | Prints `skip (ssh lab unreachable)`; never fails. |
| GitHub Actions | Never runs it at all — the workflow has no box-sync job. |

The check itself is placeholder-aware: pairs marked `scrub` are deployed with
the operator's real address substituted in, so their labhost-side hash is taken
**after** reversing the substitution, on labhost, inside the one batched SSH
session. Without `registry/local.env` those pairs report `UNCHECKED`, which does
not fail the gate — they never silently pass and never spuriously fail.

```sh
scripts/dev/verify-box-sync.sh            # only rows needing attention, grouped
scripts/dev/verify-box-sync.sh --all      # every row, including MATCH
scripts/dev/verify-box-sync.sh --table    # TSV for scripting
```

Fix drift **per row**: the repo is authoritative for source; labhost is
authoritative for generated/live artifacts (`tiles.json`, the golden manifest's
live reset allow-list). `MISSING_ON_BOX` means "never deployed"; `MISSING_IN_REPO`
means "stale or scratch on labhost" — delete it there rather than adopting it.

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

### Which files a gate sees — it depends on when it runs

`check-file-size.mjs` and `scripts/lint/shell-sources.sh` (the shfmt/shellcheck
file list) share one rule and one flag. Do **not** substitute a bare
`git ls-files '*.sh'` for `shell-sources.sh`.

| context | file set | how |
|---|---|---|
| pre-commit, direct invocation, CI | tracked ∪ staged ∪ (untracked ∧ not-ignored) | `git ls-files --cached --others --exclude-standard` |
| pre-push hook | tracked ∪ staged (shell narrowed to the pushed range) | `--committed` → `git ls-files --cached` |

**Why the default includes untracked files.** Scanning only tracked files meant
*a brand-new file always passed its own pre-commit check*. On 2026-08-10 a
606-line bash script was gated green while untracked, committed, and pushed a
red `main` the instant it became tracked — the same silent-success class as a
`|| true` fetch. `--exclude-standard` honours `.gitignore`, `.git/info/exclude`
and the global excludes, so `node_modules/`, build output and scratch dirs stay
invisible; on a clean CI checkout the union is exactly the tracked set, so CI
behaviour is unchanged.

**Why pre-push excludes them.** A pre-push hook validates the commits being
pushed, not the working tree. With untracked files in scope it failed `shfmt` on
a file another agent was actively writing — a failure the pusher could not fix.
An unfixable gate teaches `SKIP_GATE=1`, and then it protects nothing. By push
time your own new file is tracked, so a genuine breach still blocks (verified:
staged 621-line script → `--committed` exits 1).

### The pre-push hook runs only what you owe

`.claude/hooks/pre-push-gate.sh` derives the pushed range from git's own ref
list (`<remote_sha>..<local_sha>`; by hand it falls back to `@{push}..HEAD`,
`@{upstream}..HEAD`, `origin/main..HEAD`, then `HEAD`) and runs a language stage
only when that language changed in it — the same "you owe the gate only for the
language(s) your branch touches" rule stated above. The two cross-cutting gates
always run. `GATE_FULL=1` forces the full-tree, every-language run.

**Every skip is loud.** In particular the Rust stage: `streamhost/.cargo/config.toml`
pins `target-dir` to `/data/vms/streamhost/build/target`, labhost's shared
target tree, so on a workstation cargo dies with `failed to create directory …
Permission denied` before compiling anything. The hook detects the unwritable
target dir and prints `SKIPPED: target-dir unavailable locally (CI covers this)`
rather than failing a push nobody can make green — or, worse, skipping quietly.
Run it locally with `CARGO_TARGET_DIR=/tmp/kh-target GATE_FULL=1`.

### Gates that still read the working tree

Known and accepted, listed so nobody rediscovers them as bugs:
`check-generated-drift.sh` / `make station-registry-check` renders from
`registry/` on disk (so an *uncommitted* registry edit is what gets checked —
self-consistent, and a stale generated file is worth surfacing either way), and
`scripts/dev/verify-box-sync.sh` hashes worktree files against labhost and
enumerates its source/registry/launcher unions with plain `git ls-files` (so a
brand-new untracked launcher has no mirror row yet). Both would need the pushed
tree materialised to fix properly; neither is safe to change blind.

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

Every file emitted by `generated()` in `scripts/stations-registry.py` (the manifest,
bring-up list, the UI registry data, the serve JSONs, …) must be byte-identical
to what the typed registry + templates produce now. Edit the **source**
(`registry/stations/*`, templates) and run `make station-registry-generate`, then
commit the regenerated artifacts. Never hand-edit a generated file. `make
station-registry-check` (and the CI `static` job) fail on any drift.

What `rendered()` emits — `gallery-manifest.json` and `index.json` — has no
committed copy to drift, by design; the check proves those still RENDER, and
`stations-registry.py render` / `emit` produces them where they are needed.

**Regenerate after every MERGE, not just after every edit.** Generated artifacts
are the worst case for a three-way merge: they auto-merge *cleanly* and are then
*wrong*, because git resolves them line-by-line with no idea they are a
projection of the sources. Observed 2026-08-10 merging a tile branch —
`registry/generated/labctl-declarations.json` came out carrying
`nextstep.pointer_mode: "rel"` while `registry/stations/nextstep.json` said `abs`,
a hybrid neither branch ever contained. No conflict was reported; only
`make station-registry-check` caught it.

So in a multi-branch wave, run `make station-registry-generate` **after each branch
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

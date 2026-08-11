# Terminology migration — full rename, staged (2026-08)

**The vocabulary is in [`docs/GLOSSARY.md`](../../GLOSSARY.md); this file is
the execution plan.** Operator selected the terms and FULL depth on
2026-08-11: prose, filenames, code identifiers, env vars, registry keys, and
the live paths on labhost all migrate. Full depth cannot be a single sed —
`SH_TILE` is read by the running daemon, `/data/vms/streamhost/tiles/` is a
live path under 60+ running units, and ~60 artifacts answer to the stored
label `golden`. Each stage below is independently shippable, gate-green, and
leaves the fleet fully operational.

## Invariants (hold at every stage)

- A literal in docs (code fence, backtick) names the thing **as it exists on
  labhost at that moment** — prose leads, literals follow their stage.
- `docs/history/**` and `third_party/**` are records: never re-worded.
- Generated files are never hand-edited (`tiles-manifest.sh`,
  `registry/index.json`, `catalog.ts`, …) — their vocabulary changes when
  their **generator** does.
- Stored artifact labels (`loadvm golden`, `golden.sta`,
  `provenance-golden.md5`, `IRIX_STATE=golden`) rename only at natural
  recapture moments or in stage 5 — never sed a label an artifact answers to.
- `verify-emit.sh` byte-parity and the language gates stay green after every
  stage; fleet health (`check-stream-tickets.py`) after every deploy stage.

## Stage 1 — prose and comments (no behavior, no filenames)

Docs (except history/), AGENTS.md, README, and **comments** in
scripts/rust/TS. No string literals in code (log lines are grepped by
recipes — stage 2 verifies each before touching). Mapping per the glossary;
judgment cases: "golden" resolves to seed (disk) or checkpoint (state) by
context; idle-mechanism freeze/frozen/thaw/quiesce → pause/paused/resume;
machine-sense "the box"/"the lab" → labhost. Sweep in partitions (docs/lab,
docs/guests, root+scripts, streamhost+spa comments), one commit per
partition, pushed promptly (three parallel-agent merge races today alone).

## Stage 2 — repo file renames + log strings

`git mv` + update every caller + gates, one rename per commit:
`bake-golden.sh` → `capture-checkpoint.sh`; `tiles-manifest.sh` →
`stations-manifest.sh` (generator output name — change in
`tiles-registry.py` → `stations-registry.py` the same commit);
`ADD-NEW-OS-PLAYBOOK` internal wording; box-sync pair labels/paths in
`box-sync-pairs.sh` (mirror rows move with their files). Log/echo strings
rename only after `grep -r "<string>"` proves nothing parses them. Deploy:
renamed box-side scripts re-synced; `box-repo.sh sync` + re-emit.

## Stage 3 — code identifiers, env vars, registry keys, UI dir

- **Rust daemon**: `SH_TILE` → `SH_STATION`, `SH_TILE_RUNTIME` →
  `SH_STATION_RUNTIME`, internal `tile` idents (~230 sites). The daemon reads
  the NEW var first and falls back to the old with a deprecation log line —
  both vocabularies work during the fleet flip. Canary-deploy per the normal
  per-station rule before promoting.
- **Registry**: `tileDir`/`tileEnv`/`tilesManifest*` → `stationDir`/… in
  `stations-registry.py` + all station JSONs (one mechanical commit,
  regenerate everything; labctl reads the generated declarations — update its
  keys in the same commit).
- **Emitter**: emits the new SH_* names once the fallback-reading daemon is
  fleet-promoted; fleet re-emit flips every station env in one pass
  (verify-emit stays green because emit and live move together).
- **UI**: `spa/` → `ui/` (dir, package refs, build/deploy scripts), `tile`
  identifiers (~680 sites) → `station`; visitor-facing strings ("Restore to
  golden" → "Restore to checkpoint"). Gates: eslint --max-warnings=0, knip,
  build; bundle redeploy.

## Stage 4 — live paths and unit template (maintenance window)

`/data/vms/streamhost/tiles/` → `…/stations/`, `tile.env` → `station.env`,
`/usr/local/lib/streamhost/tiles/` → `…/stations/`. Order: create
`stations` → move station dirs → compat symlink `tiles` → `stations` →
update unit template (EnvironmentFile/ExecStartPre/ExecStop paths) +
ensure/stop scripts + labctl + clone-guard + check-stream-tickets +
fetch-assets in one commit → `daemon-reload` → rolling restarts
(instant-ready makes each a few seconds; irix/w2kalpha/tru64 land paused at
their checkpoint). Symlink stays one epoch for muscle memory and stray
scripts.

## Stage 5 — labels and cleanup

Optional relabel of stored checkpoint labels (`golden` → `checkpoint`) at
recapture moments — never as a standalone fleet rebake. Drop the daemon's
old-env-var fallback, remove the `tiles` symlink, retire this plan into
`docs/history/`, and grep-zero the retired words outside history/ +
artifact labels.

## Status

- [x] Stage 0 — glossary + this plan (2026-08-11)
- [ ] Stage 1 — sample: AGENTS.md converted for operator review; sweep pending
- [ ] Stage 2
- [ ] Stage 3
- [ ] Stage 4
- [ ] Stage 5

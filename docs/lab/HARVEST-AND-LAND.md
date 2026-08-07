# Box harvest and drift gate

The two directions are intentionally separate. `build-deploy.sh` mirrors repo
source to the box; `harvest.sh` is the reviewable box-to-repo path for the small
set of files that may be authored or reconciled live.

## Harvest box changes

Always start with the non-writing pass:

```bash
git switch -c harvest/<topic> origin/main
scripts/dev/harvest.sh --dry-run
scripts/dev/harvest.sh --apply --commit -m "chore: harvest <topic>"
```

The tree allowlist is printed by `harvest.sh --list-trees`; repeat `--tree` to
review a subset. The default set is the deployed Rust source and Cargo
manifests, tracked verbatim tile launchers, `labctl`, the live `tiles.json`
reference, seven declared `serve/` mirrors, and the box checkout's registry.
The script starts an apply only from a clean non-main branch, checks every
changed/staged path, and commits only that allowlist.

Token files, credentials documents, `credentials.ts`, the complete `pki/`
tree, and private keys are rsync-excluded and rejected again before commit.
An apply without `--commit` deliberately leaves
`/data/vms/streamhost/build/streamhost/.last-harvest` unchanged. A committed
harvest that includes `src` atomically refreshes that marker with the commit,
UTC stamp, and aggregate MD5 of the box source tree. Deploy tooling uses the
digest to refuse a destructive source mirror after an unharvested live edit.

## Check drift

```bash
scripts/dev/verify-box-sync.sh
```

This is read-only on the box. It prints one row per concrete mirror with the
repo MD5, box MD5, and `MATCH`/`DRIFT`, then exits non-zero if any row drifts.
The registry uses the union of allowed files so a file present on only one side
cannot disappear from the report. Generated (non-verbatim) tile launchers remain
the responsibility of `scripts/dev/verify-emit.sh`.

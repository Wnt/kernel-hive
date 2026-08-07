# Versioned streamhost builds and fleet rollout

The live fleet initially executes the release binary in place from
`/data/vms/streamhost/build/target/release/streamhost`. The checked-in systemd
template now describes the safer destination model, but **merging this file does
not authorize copying it over the live unit**. The one-time change is performed
only by `scripts/dev/migrate-to-versioned.sh` in a supervised window.

## Build loop

`scripts/dev/build-deploy.sh` uses the absolute shared target directory
`/data/vms/streamhost/build/target`. The same path is also in
`.cargo/config.toml`, so builds from box-side Git worktrees reuse one dependency
cache. The box must have `mold` (and the `ld.mold` entry point) on `PATH`.
The current box was installed from upstream mold 2.41.0's x86_64 release on
2026-07-16 after verifying GitHub's published SHA-256
`a3696680d99e692970590a178bc3a33d78d60d1c6dc9db7a11b557b02b751f5d`;
`/usr/local/bin/ld.mold` resolves to that binary.

- `build-deploy.sh --fast` selects Cargo's `dev-fast` profile. It is deliberately
  build-only and can never restart a daemon or install a fleet artifact.
- A release build remains the default. Before the one-time unit migration, a
  bare invocation restarts only `helenos`; positional tiles are explicit and
  only `--all` authorizes the full fleet.
- `--changed-only` no longer exists because Rust source changes do not map to a
  meaningful subset of tiles.
- One remote `flock` covers the mirror, build, install, symlink, and restart
  transaction. A second invocation waits briefly and then fails cleanly.
- The `rsync --delete-after` source mirror requires
  `/data/vms/streamhost/build/streamhost/.last-harvest`. The harvest workflow
  owns this marker and atomically writes it only after a successful committed
  box-to-repository source harvest. Its aggregate `src_tree_md5` must exactly
  match the box source tree before the destructive mirror can proceed.
- Startup smoke checks use the daemon's post-bind
  `LISTENING udp/<port> tile=<tile>` line from the new process PID. This works on
  an idle tile without a client or framebuffer damage.

## Filesystem model

For Git commit `$SHA`:

```text
/usr/local/lib/streamhost/
├── streamhost-$SHA
└── tiles/
    └── helenos/
        ├── current  -> ../../streamhost-$SHA
        └── previous -> ../../streamhost-$OLD_SHA
```

The binary is installed immutably as `streamhost-<full-git-sha>`. `current` and
`previous` are replaced with same-filesystem atomic renames. Every tile retains
its own N-1 target, so rollback does not depend on the rest of the fleet.
Systemd expands the instance in:

```ini
ExecStart=/usr/local/lib/streamhost/tiles/%i/current
```

Old artifacts must not be removed while any `current` or `previous` symlink
references them. The deployment tooling intentionally does not auto-delete
versions.

## One-time supervised migration

First rehearse without touching systemd or a running process:

```bash
scripts/dev/migrate-to-versioned.sh
scripts/dev/migrate-to-versioned.sh --stage-only /tmp/streamhost-versioned-rehearsal
```

The stage-only tree is isolated under `/tmp`; inspect its artifact and both
symlink targets, then remove it when the review is complete.

After the branch has been landed and the release binary has been built from that
exact clean commit, the orchestrator runs:

```bash
scripts/dev/build-deploy.sh --no-restart
scripts/dev/migrate-to-versioned.sh --apply
```

The migration requires the expected 28 live units and the legacy `ExecStart` on
every one. It copies the existing release binary, stages every per-tile link,
backs up the legacy unit, installs the versioned template, and restarts
`helenos` only. It then pauses. The operator must inspect a fresh QMP framebuffer
and a real helenos stream and type `PROMOTE` before bounded rollout waves begin.
Any failed readiness gate restores the legacy unit and restarts already-touched
tiles on the legacy path. `--yes-after-canary` exists for an already-supervised
automation layer, but should not be used for the first migration.

## Normal canary, promotion, and rollback

After migration, all new releases use the explicit gate:

```bash
# Build release, install streamhost-$SHA, switch/restart helenos, require readiness.
scripts/dev/build-deploy.sh --canary helenos

# Operator framebuffer- and stream-verifies helenos here.

# Uses the recorded, verified artifact; does not rebuild. Default wave size is 4.
scripts/dev/build-deploy.sh --promote
```

Promotion refuses to run without the canary gate, confirms the canary still
points at that artifact, atomically switches each wave, and requires every new
process to emit its startup readiness line. A failed wave is returned to its
saved per-tile targets; earlier successful waves remain on the verified
artifact for explicit operator disposition.

Rollback is per tile and swaps the two retained targets:

```bash
scripts/dev/build-deploy.sh --rollback helenos
```

The rollback restart must also pass startup readiness. If it does not, the
original `current` target is restored. Because `previous` becomes the displaced
target, the same command provides an immediate roll-forward.

## Dry-run review

All deployment modes support a no-write review. In particular:

```bash
scripts/dev/build-deploy.sh --dry-run
scripts/dev/build-deploy.sh --canary helenos --dry-run
scripts/dev/build-deploy.sh --promote --dry-run --wave-size 4
scripts/dev/build-deploy.sh --rollback helenos --dry-run
```

The first command must show exactly one target (`helenos`). The canary dry-run
shows immutable artifact installation and atomic link selection. Promotion
shows each fleet wave and its readiness gates. None of these dry-runs alters the
live `ExecStart`, symlinks, binary, or process state.

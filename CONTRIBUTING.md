# Contributing

This is a personal home-lab project (see the [README](README.md)'s status
note). Most of the repository — tile launchers, golden-image builders,
`labctl`, the live e2e suite under `tests/e2e-live/` — only runs against
the owner's Proxmox lab box, so most changes cannot be verified end to end
without that hardware. Issues, questions and PRs against the buildable
parts (`spa/`, `streamhost/`, general tooling) are welcome; changes that
touch tile launchers or golden images should say plainly what was and
wasn't tested, since a reviewer without the box can't run them either.

## Placeholders, not real values

Every IP/hostname/domain in the docs (`192.0.2.10`, `labhost`, `example.com`,
etc.) is a scrubbed stand-in for the operator's lab box — see the README's
"Addresses and hostnames" note and `registry/README.md`. Never commit a real
address, hostname, MAC, serial or domain back into the repo; operator-local
values belong only in the gitignored files (`registry/local.env` and similar).

## Never hand-edit a generated file

`registry/index.json`, the `streamhost` manifest, and the SPA poster data
are all generated from `registry/tiles/*.json` by
`scripts/tiles-registry.py generate`. Edit the registry source and
regenerate — `make tile-registry-check` fails the build if a generated
file has drifted from its source. The same rule applies to any other
generated artifact you find a comment marking as such.

## The quality gate — green before done

Every change that's intended to merge is expected to pass the full CI
quality gate for the language(s) it touches, plus the two checks that apply
to every change. Red is not done; "it's a small change" isn't an exemption.
Canonical commands, mirrored by `.github/workflows/quality.yml`:

- **TS/JS** (`spa/`) — `cd spa && npx eslint . --max-warnings=0 && npx knip`
  (+ `npm run build`)
- **Rust** (`streamhost/`) — `cd streamhost && cargo fmt --all --check &&
  cargo clippy --all-targets -- -D warnings` (+ `cargo test --workspace`)
- **Python** (`scripts/`) — `ruff check scripts && ruff format --check
  scripts`
- **Bash** (`*.sh`) — `shfmt -d $(git ls-files '*.sh') && shellcheck
  $(git ls-files '*.sh')`
- **File-size budget** (all languages) — `node scripts/check-file-size.mjs
  --strict`. Per-dialect line caps; `size-exclusions.json` is a
  bidirectional ledger, so a file that drops back under its cap must have
  its stale exclusion removed too, or the check fails the other way.
- **Generated-file drift** (all languages) — `make tile-registry-check`.

You only owe the gate for the languages your change actually touches, plus
the file-size and generated-file checks, which apply to everything.

## What you can build and check without the lab box

**SPA** (`spa/`) — any machine with Node 22+:

```sh
cd spa
npm ci
npx eslint . --max-warnings=0
npx knip
npm run build     # a placeholder credentials.ts is auto-created
                  # from credentials.example.ts
```

**streamhost** (`streamhost/`) — Linux with the system codec libraries:

```sh
sudo apt-get install libx264-dev libopus-dev libclang-dev pkg-config cmake
cd streamhost
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo test --workspace
```

**Shell / Python tooling** (`scripts/`):

```sh
ruff check scripts
ruff format --check scripts
shfmt -d $(git ls-files '*.sh')
shellcheck $(git ls-files '*.sh')
```

What you generally cannot verify without the box: whether a tile launcher
still boots its guest, whether a golden-image rebuild still produces a
working snapshot, whether a registry change behaves correctly once emitted
to a running `streamhost@<tile>` unit, or anything in `tests/e2e-live/`
(explicitly excluded from CI for this reason).

## PR expectations

- Small, focused commits with imperative subjects.
- The relevant parts of the quality gate above are green.
- Never commit secrets or credentials — see the `SECRETS` section of
  `.gitignore`; `spa/src/data/credentials.ts` stays local, only the
  `.example` file is tracked.
- Match the local style of the code you touch; `.editorconfig` covers the
  basics.
- If your change touches a generated file's source
  (`registry/tiles/*.json` and similar), run the corresponding `generate`
  step and commit the regenerated output in the same PR.

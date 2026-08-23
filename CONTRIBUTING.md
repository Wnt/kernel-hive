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

The `streamhost` manifest, the serve JSONs and the SPA poster data are all
generated from `registry/stations/*.json` by
`scripts/stations-registry.py generate`. Edit the registry source and
regenerate — `make station-registry-check` fails the build if a generated
file has drifted from its source. The runtime JSON documents are not committed
at all — the public `gallery-manifest.json`, `poster-docs.json`, the serve
`tiles.json` / `golden-manifest.json`, `gallery-action-map.json` and the
whole-registry `index.json`: `stations-registry.py render` / `emit` resolves them
on demand, so a gallery-visible string has exactly ONE hit in the tree. The same rule applies to any other
generated artifact you find a comment marking as such.

## Commit messages become the release notes

`docs/RELEASE-NOTES.md`, the README's "Release notes" section and
`spa/public/release-notes.json` are **generated from git history** by
`scripts/release-notes.py` — run `make release-notes` after a merge, never
hand-edit the output (`make release-notes-check` verifies it). Notes are cut
into weeks that end **Sunday 09:00 Europe/Helsinki**; the still-open current
week is deliberately left unverified, so only closed weeks can go stale.

That makes a well-formed `scope: subject` commit message the single thing
that decides whether a week reads well: the scope picks the section, the
subject is the bullet. Write the subject as a short statement of what
changed, not "fix stuff". A scope that is a station id (any
`registry/stations/*.json` id — `win95`, `irix`, `tru64`, …) files the commit
under **Stations**; otherwise these scopes are recognised:

- **Gallery UI** — `spa`, `ui`, `gallery`, `posters`, `grid`
- **Streaming daemon** — `streamhost`, `rust`, `encoder`, `transport`,
  `ctlsock`, `input`, `keyboard`, `telemetry`, `idle`, …
- **Retronet** — `retronet`
- **Tooling & infrastructure** — `registry`, `scripts`, `build`, `ci`,
  `make`, `dev`, `lint`, `host`, `labctl`, `serve`, `tools`, …
- **Docs** — `docs`, `readme`, `research`, `playbook`, `terminology`
- **Dependencies** — Dependabot's own `Bump …` subjects, automatically

Multi-part scopes work (`docs/research`, `retronet-bot`) — the head decides
the section — and so do `type(scope):` messages (`docs(rel-pointer): …`).

Three subject shapes are read, and only the first one is stripped from the
bullet:

1. `tru64: fix the Gaim colormap` — a real prefix. The bullet becomes "Fix
   the Gaim colormap" under **Stations**, labelled `tru64`.
2. `retronet web: drop the charset parameter` — the scope is the first word
   of a short phrase. The section comes from `retronet`; the text is kept
   whole, because "web" is part of what changed.
3. `chokanji joins the retronet web plane: …` — prose opening with a station
   id. Recognised for **Stations only**: a station id is distinctive, while
   "make", "build" and "docs" open ordinary sentences.

**Other** means none of the three matched. Before reaching for
`_ALIAS_GROUPS` in `scripts/release-notes.py`, check *why*: an alias only
helps when a scope was parsed and is simply unknown (`accept: …`,
`commodore: …`). A subject that never named a scope at all — `we need
pinball sites too`, `tmp` — cannot be reached by any alias, and the fix is
the next commit message, not the generator. Placeholder subjects (`wip`,
`tmp`, `fixup`) are kept in the archive but are never chosen as a week's
README highlights.

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
- **Generated-file drift** (all languages) — `make station-registry-check`.

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
  (`registry/stations/*.json` and similar), run the corresponding `generate`
  step and commit the regenerated output in the same PR.

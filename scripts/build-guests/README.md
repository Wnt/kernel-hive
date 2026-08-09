# `scripts/build-guests/` — the from-source guest builders

This tree is the MASTER-REPRODUCE Phase-4 path: every gallery exhibit is
rebuilt END TO END from upstream or explicitly supplied source media, no image
backups. It was a flat pile of 112 files; it is now one layer deep, plus the
IRIX subsystem's own second layer.

## The two entry points stay at the top

| Path | What it is |
|---|---|
| `build-all.sh` | The orchestrator. **GENERATED** — `python3 scripts/tiles-registry.py generate` renders it from `registry/templates/build-all.sh.in` + the `build.rows` of `registry/tiles/*.json`. Never hand-edit it; edit the registry entry and run `make tile-registry-generate`. |
| `check-assets.sh` | The staged-media/env preflight, also reachable as `build-all.sh --check-assets`. Reads `assets/`. |

Both are pinned at the top on purpose: `build-all.sh` is hardcoded in
`scripts/check-file-size.mjs`, `scripts/lint/shell-sources.sh` and
`scripts/check-generated-drift.sh` as a generated artifact, and
`check-assets.sh` is the other name operators and docs already type.

## The directories

| Directory | What belongs there | Why |
|---|---|---|
| `assets/` | Repo-shipped payloads injected into a guest: icons, `.reg` files, kiosk patches, Python-2-era helper scripts. | Stays at the top: `scripts/check-file-size.mjs` hardcodes it as `PY2_ASSET_PREFIX` (its Python-2 in-guest helpers are exempt from the modern line budget). Builders reach it as `$SCRIPT_DIR/../assets/<os>/`. |
| `tiles/` | The ~56 per-tile golden builders an operator runs, one per exhibit. | Membership is not a judgement call: a script is here **iff** some registry entry names it in `build.rows[].value.script` (plus `riscos.sh`, see below). `build-all.sh` resolves that column as `"$SCRIPT_DIR/$SCRIPT"`, so the registry value now carries the `tiles/` prefix and the two cannot drift. |
| `stages/` | Helpers that a `tiles/` builder calls, never the operator: `haiku.sh` (← `tiles/haiku-install.sh`), `postmarketos.sh` (← `tiles/postmarketos-fixture.sh`), `winxp-vbemp-hires.sh` (← `tiles/winxp.sh`, `tiles/win98.sh`), `nextstep-kiosk-frame.sh` (← `tiles/nextstep.sh`), `redstar3-offline-apply.sh` (← `tiles/redstar3.sh`), `openvms-decwindows-bridge.sh` (← `tiles/openvms.sh`). | These look like tile builders and are not. Each is one phase of exactly one tile's build, invoked by that tile's script. Splitting them out is what makes `tiles/` a trustworthy 1:1 list. |
| `emulators/` | Toolchain builds that produce an emulator binary rather than a guest image: `build-mame-*.sh` and `mamectl/`. | A MAME binary is not a golden image, is built once and shared, and its build is pinned to an upstream commit. It has a different lifecycle from every tile. |
| `patches/` | The loose emulator patches: `mame-*.patch`, `previous-*.patch`. | Data, not code — consumed by `emulators/` and by `tiles/nextstep.sh`. See the rule below before touching one. |
| `irix/` | The whole IRIX subsystem: the `irix-*` scripts and the `irix-apps/ irix-bench/ irix-criu/ irix-ctl/ irix-fsn-icon/ irix-savestate/ irix-slowstate/` rigs. | IRIX is a *subsystem*, not a tile — a MAME patch stack, a serial agent installer, a savestate baker, a speed rig, a CRIU restore rig. It was ~25 of the 112 flat entries and dominated the listing. **Filenames keep their `irix-` prefix** (`irix/irix-bench/`, not `irix/bench/`): the prefix is redundant in the path but every existing doc, box-side note and `grep irix-savestate` still matches. |
| `lib/` | Shared infrastructure that is neither a tile, a stage, nor a toolchain build: `bridge-base.sh`, `graphical-bridge.sh`, `bbcmicro-type-qmp.py`. | Each is used by MANY builders. `bridge-base.sh` builds the one frozen read-only base image that ~20 emulator-bridge tiles overlay — it *is* a `build-all.sh` manifest row, but it produces shared infrastructure, not an exhibit, and putting it in `tiles/` would make that directory lie. `graphical-bridge.sh` is a parameterized scaffold (`--tile/--install-script/--launch-script`) that any new graphical bridge instantiates; `irix/irix-bridge-install.sh` + `irix/irix-bridge-launch.sh` are its IRIX arguments. `bbcmicro-type-qmp.py` is the BBC-layout QMP typist shared by `tiles/bbcmicro.sh` and `tiles/armeval.sh`. |

Note there are now two `lib/` directories in play. From a builder,
`$SCRIPT_DIR/../lib/` is **this** tree's shared infrastructure and
`$SCRIPT_DIR/../../lib/` is the repo-wide `scripts/lib/` (`labqmp.py`,
`xvfb-alloc.sh`, `clone-guard.sh`). Both spellings appear; check the depth.

## Loose patch vs. fork submodule — which one do I edit?

`patches/mame-*.patch` and the published fork `third_party/mame-irix` (branch
`irix`, `github.com/Wnt/mame`) are **two forms of the same change, and both are
live.** Do not delete either.

- `emulators/build-mame-irix.sh` prefers the submodule when it is checked out
  and falls back to `clone upstream + apply the loose patches` when it is not.
  Both paths produce the same tree; the submodule is the published, reviewable
  form. Deleting the loose patches would delete the no-submodule path.
- Six newer builders — `emulators/build-mame-{kc854,mpf2,bbcb,dragon32,zx81,oricatmos}.sh`
  — apply `patches/mame-irix-skip-warnings.patch` directly with `patch -p1`.
  Those machine families have **no fork branch at all**, so for them the loose
  patch is the only source.

So: **change the loose `.patch` file, and land the same change as a commit on
the fork's `irix` branch.** `irix/irix-mame-stack.sh` is the single
authoritative ordered stack (the order is load-bearing) and is sourced by both
`emulators/build-mame-irix.sh` (lab box) and `emulators/build-mame-macos.sh`
(dev Mac). Never copy the list into a second script.

## Adding a new OS

`python3 scripts/tiles-registry.py new-os …` scaffolds
`scripts/build-guests/tiles/<id>.sh` and writes the matching registry entry, so
the manifest row and the file land together. The full procedure — sourcing
media through to the acceptance matrix — is
[`docs/lab/ADD-NEW-OS-PLAYBOOK.md`](../../docs/lab/ADD-NEW-OS-PLAYBOOK.md).

## Retained but unreferenced

`tiles/riscos.sh` is called by nothing and named by no registry entry. It is
**not** dead: riscos is a Tier-3 recovery candidate in the playbook and its
builder is deliberately kept for a future re-entry. Do not delete it.

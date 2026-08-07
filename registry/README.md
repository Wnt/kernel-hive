# Canonical tile registry

`registry/tiles/<osId>.json` is the typed source of truth for the gallery lineup.
Do not copy a fleet total into a new source of truth; derive the current total:

```bash
python3 scripts/tiles-registry.py count
# 39 lineup entries: 37 streamhost production tiles, 2 showcase posters
```

The schema is `registry/schema/tile-v1.schema.json`.

## Deployment-local values (the `registry/local.env` mechanism)

The public repo was scrubbed for release: the operator's real LAN IP, box
hostname, and public domains were replaced with RFC 5737 / documentation
placeholders (`192.0.2.10`, `labhost`, `example.com`, `gallery.example.com`,
`tunnel.example.com`). Every tool keeps its placeholder as the DEFAULT so a
fresh public clone works out of the box and `make tile-registry-check` stays
deterministic across machines — `registry/index.json` and every other
generated artifact keep the placeholder regardless of local configuration.

The real values are supplied at *run/deploy* time, not at *generate* time: copy
`registry/local.env.example` to `registry/local.env` (gitignored) on the box and
fill in the keys documented there (`SH_HOST_IP`, `SH_TUNNEL_HOST`,
`SH_GALLERY_HOST`). The shared helper `scripts/lib/local-env.sh` locates and
sources that file for every consumer, and is a no-op when the file is absent —
see the header comment in that file for the exact precedence rule (explicit CLI
flag / pre-set environment variable > `registry/local.env` > repo placeholder).
`streamhost/scripts/streamhost-tile.sh` was the first, tile.env-emitting
consumer (`SH_HOST_IP`, overridden by an explicit `--host-ip` flag); the same
mechanism now also backs `scripts/serve-https-spa.sh`,
`scripts/serve/restart-https.sh`, `scripts/serve/gen-local-ca.sh`,
`scripts/dev/verify-tile.sh`, `scripts/dev/mobile-netem.sh`,
`streamhost/run/serve_client.sh`, `streamhost/bring-up-all.sh` (generated from
`registry/templates/bring-up-all.sh.in` — edit the template, not the generated
file), and the `scripts/cloud-agents/` tunnel-endpoint tooling.
`registry/local.env` never affects `scripts/tiles-registry.py generate` output.

## Exhibit posters

A tile's optional long-form poster is the sibling Markdown document
`registry/posters/<id>.md`. The filename match is the association: there is no
second id or hand-maintained lookup. The JSON Schema records this convention in
`x-posterAssociation`, and `scripts/tiles-registry.py` validates and compiles
matching documents into `spa/src/data/posters.ts`. A tile may have no document.
An unmatched document is intentionally warned about and skipped so posters may
land before their tile entry on another branch.

Poster frontmatter requires `title` and `subtitle`, accepts an optional `hero`,
and accepts `images` entries with required `src`, `alt`, and `caption` plus an
optional `credit`. Image paths must be same-origin `/posters/...` paths. The body
supports `##`/`###` headings, paragraphs, `-` lists, `>` quotes, standalone
Markdown images, and inline strong/emphasis/safe links. This constrained format
is parsed at generation time into typed blocks; the browser does not parse or
inject Markdown.

The operational files are deterministic products of the registry:

```bash
python3 scripts/tiles-registry.py validate
python3 scripts/tiles-registry.py count
python3 scripts/tiles-registry.py generate
python3 scripts/tiles-registry.py --check
python3 scripts/tiles-registry.py explain solaris
```

`generate` validates everything before atomically replacing outputs. `--check`
renders in memory and byte-compares every committed output; on the lab box it
also compares the declared labctl fields with `/data/vms/streamhost/tiles.json`.
`scripts/gen_tiles_json.py` consumes the generated declaration seed, verifies it
against live env/launcher facts, and then adds only its read-only golden-snapshot
probe. Observed service/socket/snapshot state remains owned by `labctl gen` and
is not written back into this registry.

The `render` keys preserve the old files' byte layout during this migration.
Validation parses those legacy Bash/TypeScript rows and rejects disagreement
with the typed fields. New entries may use the default renderers once the
legacy formatting shims are normalized in a later, separately reviewed change.
Verbatim QEMU launchers remain authoritative device ledgers and are referenced,
never rewritten, by this generator.

For an ordinary new OS, author one registry entry, its builder, and its guest
documentation; add a bespoke launcher only when the generic runtime is not
sufficient. Do not hand-edit generated artifacts.

## Generated artifacts and their gate lists

`generated()` in `scripts/tiles-registry.py` is the single authoritative list of
generated output paths. Three lint/CI gates carry their own copies of that list
and MUST stay in lockstep with it:

- `scripts/check-generated-drift.sh` (`GENERATED_PATHS`)
- `scripts/check-file-size.mjs` (`GENERATED` set — the size-budget exemption)
- `scripts/lint/shell-sources.sh` (the `:(exclude)` list — the generated `.sh`
  subset that shfmt/shellcheck skip)

`python3 scripts/tiles-registry.py paths` prints the authoritative list, and
`make tile-registry-check` fails if any gate list drifts from it, so the copies
cannot silently rot when outputs are added or renamed.

## Schema rules the homegrown validator does NOT enforce

`registry/schema/tile-v1.schema.json` is Draft-2020-12, but the repo does not run
a standards validator. `validate_json_schema()` in `scripts/tiles-registry.py` is
a dependency-free evaluator that implements only `type` / `const` / `enum` /
`pattern` / `minimum` / `required` / `properties` / `items`. It SILENTLY IGNORES
`allOf` / `if` / `then` and does not honour `additionalProperties`. Consequences a
tile author must know:

- The `runtime.allOf` pve conditional in the schema (`mode == pve` ⇒ require
  `runtime.pve`, forbid `runtime.qemu.launcher`) is **decorative to the shipped
  validator**. It is actually enforced only by the hand-written business rules in
  `validate_schema_shape()` / `validate()`. Do not trust the schema conditional
  alone.
- Because no `additionalProperties: false` is honoured, a typo'd key (e.g.
  `backned` for `backend`) passes the schema silently. It is caught only by the
  Python `expected_env` cross-checks — and only where such a cross-check exists.

### pve mode (schema-ready, 0 tiles today)

A `runtime.qemu.mode: "pve"` tile is enforced by Python, not the schema. Its
author must satisfy, or `validate` fails:

- `runtime.pve.vmid` present, integer ≥ 1.
- `runtime.qemu.emitArgs` contains `["--pve-vmid", str(vmid)]`.
- `runtime.tileEnv` emits `SH_QEMU_MODE=pve`, `SH_PVE_VMID=<vmid>`,
  `SH_QEMU_PIDFILE=/var/run/qemu-server/<vmid>.pid`.
- `runtime.qemu` has NO `launcher` (pve tiles are not launcher-driven).
- If `reset.resetMode == "pve-rollback"`, then `runtime.qemu.mode` must be `pve`
  and `reset.snapshot` must be `"golden"`.

### gallery-hid / unified input backend

`stream.pointer.backend` (enum `dbus-abs` / `dbus-rel` / `warpd` / `gallery-hid`)
is an OPTIONAL sibling of the legacy required `stream.pointer.transport` (enum
`abs` / `rel` / `warpd`). This mirrors the Rust `config.rs` `InputBackend` +
`parse_input_backend` (an explicit `backend` wins; an absent one derives from
`transport`). gallery-hid tiles carry a redundant `transport: "abs"` by design
(`config.rs` `GalleryHid → abs`). Business rule (Python, not schema): when
`backend` is present the tileEnv MUST emit `SH_INPUT_BACKEND=<backend>` and MUST
NOT also emit the legacy `SH_POINTER`. solaris is the only backend user today;
qnx is a latent second user (enum already accommodates it).

### Three hand-synced enforcement copies

The input-backend and pve rules live in THREE places that are kept in sync by
hand — there is no generator binding them: (1) the schema enums here, (2) the
Python evaluator + business rules in `scripts/tiles-registry.py`, and (3) the
Rust `streamhost/streamhost/src/config.rs` (`InputBackend`, mode parsing). A
future hardening — swapping in a real Draft-2020-12 validator so `allOf`/`if`/
`then`/`additionalProperties` actually run — WOULD change validation behaviour
and must be a separate, reviewed change, out of scope for output-preserving work.

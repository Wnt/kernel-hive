# New-OS integration architecture

Status (2026-07-16): the canonical per-tile registry, generator, generated
streamhost/serve/SPA/labctl artifacts, and drift CI described by the core of
this proposal are implemented. See `registry/stations/`,
`scripts/stations-registry.py`, the `station-registry-generate`,
`station-registry-check`, and `station-registry-validate` Make targets, and
`.github/workflows/tile-registry.yml`. The later runtime-driven SPA design is
not yet implemented; bindings and catalog rows are generated but remain
bundle-time data, so an SPA rebuild is still required.

## Executive recommendation

Introduce a versioned, JSON-Schema-validated canonical registry at
`registry/stations/<osId>.json`, then generate the operational registries consumed
today. Serve the public subset of that registry to the SPA at runtime. Keep
guest builders, bespoke launchers, golden-bake logic, boot-video detection
recipes, and private credentials as referenced sidecars rather than trying to
turn arbitrary OS installation into data.

The target add-OS transaction is:

```text
one canonical tile entry
+ one guest builder
+ one guest doc
+ optional bespoke launcher/bake sidecar
+ built golden artifact
```

For a straightforward guest this reduces hand-edited integration surfaces from
roughly 15 files to 3–4 and removes the SPA rebuild/deploy requirement. A legacy
guest may still need several implementation files in its one tile directory,
but it should not need repeated ID, port, pointer, reset, and placard edits.

## 1. Current architecture and measured drift

There are three independent lineup authorities:

1. **Runtime/build authority:** `streamhost/stations-manifest.sh`, plus the separate
   order in `streamhost/bring-up-all.sh` and builder registration in
   `scripts/build-guests/build-all.sh`.
2. **Serve/reset authority:** `scripts/serve/tiles.json` for signal routing and
   `scripts/serve/golden-manifest.json` for reset behavior.
3. **SPA authority:** bundled `OS_BINDINGS` in
   `spa/src/three/archetypeRegistry.ts`, with exhibit metadata split across
   `mock/manifest.json`, `data/museumCatalog.ts`, `data/catalog.ts`,
   `data/useManifest.ts`, `types.ts`, and the gitignored credentials map.

Other consumers add more repeated facts: the labctl runtime matrix, action
probe map, coldboot arms, per-guest docs, and boot order.

The sets do not mean the same thing and already have different sizes:

| Source | Rows | Meaning |
|---|---:|---|
| `streamhost/stations-manifest.sh` | 28 | production tiles which can be emitted |
| `scripts/serve/golden-manifest.json` | 28 | production reset fixtures |
| `scripts/serve/tiles.json` | 30 | 28 production signals plus two `soltest-*` experiments |
| SPA `OS_BINDINGS` | 33 | 30 signal-visible rows plus three showcase posters |

Different sizes are legitimate only when lifecycle is explicit. Today the
distinction is encoded in comments and omission. The `soltest-warpd` and
`soltest-ghid` case illustrates the cost: tile directories, signal rows,
bundled SPA bindings, `labctl gen`, and an SPA rebuild/deploy all had to be
coordinated, while the production tile manifest and golden manifest remained
separate.

Duplicated fields include `osId`, `stationDir`, display name, UDP port, certificate
hash path, pointer mode, touch behavior, reset mode/snapshot, machine type,
display/input device, transport, accent, era label, boot-video state, fixture
description, and startup order. The alias pairs of the day
(`solaris`/`solariscde` and `aros`/`amigaos`) amplified the problem; both were
renamed on 2026-08-10 and the registry now refuses an id that differs from its
`stationDir`.

There is concrete semantic drift to audit. Comparing the manifest's current
`--pointer` with the golden manifest's `pointer` finds different values for nine
tiles (`helenos`, `kolibrios`, `ninefront`, `solaris`, `win311`, `win95`,
`win98se`, `os2warp`, and `templeos`). Some may be historical descriptions of
the physical device rather than current streamhost routing, which is itself the
problem: the field has no single enforced meaning. A typed registry must split
physical input device from host-to-guest transport.

The SPA is particularly expensive:

- `OS_BINDINGS` determines which exhibits exist and is compiled into the JS
  bundle;
- `museumCatalog.ts` has most placards, while three base rows live in
  `mock/manifest.json` and are enriched again by `catalog.ts`;
- `useManifest.ts` calls that static merge and only fetches boot-video metadata;
- `types.ts` manually describes the catalog shape;
- credentials are a separate gitignored TypeScript module.

Consequently, a correct new signal row still cannot appear until the SPA is
rebuilt and deployed. Conversely, a bundled SPA row can appear with no signal
backend.

## 2. Design principles

1. **One owner per fact.** A generated file must say which canonical field
   produced it; it must not be a second editable authority.
2. **Separate desired state from observed state.** The registry declares a tile;
   `labctl gen` observes sockets, current snapshot availability, and service
   state. Do not write observations back into source control.
3. **Separate public from private data.** A registry may contain
   `credentialsRef`, never a login secret, key, token, or password.
4. **Keep arbitrary logic in code.** Installation state machines, emulator
   setup, bespoke QEMU launchers, and golden proofs are scripts referenced by
   the registry. A giant declarative installer DSL would be harder to debug.
5. **Preserve device-set parity.** A generator may render a launcher, but the
   generated result remains a reviewable device ledger. Machine/device changes
   require a matching golden.
6. **Allow lifecycle differences explicitly.** `production`, `showcase`,
   `candidate`, and `experiment` are schema values, not inferred from which
   registry happens to omit an ID.
7. **Migration must be byte/effect preserving.** Import today's 28 production
   values first; do not normalize ports, aliases, or device sets during the same
   change that introduces generation.

## 3. Canonical registry

### 3.1 Format and location

Use one JSON document per public `osId`:

```text
registry/
  schema/tile-v1.schema.json
  tiles/alpine.json
  tiles/aros.json
  tiles/macos.json
  tiles/soltest-ghid.json
```

JSON is recommended over YAML/TOML here because Python, Node/TypeScript, the
serve plane, and existing tooling already consume JSON without adding a parser.
JSON Schema supplies types, enums, conditional requirements, and editor/CI
validation. Per-tile files reduce merge conflicts and make one-OS review easy.
A generated `registry/index.json` can concatenate them for consumers that need
one file.

Comments belong in `notes` fields or the per-guest doc; JSON's lack of comments
is preferable to maintaining a custom comment-preserving generator.

### 3.2 Proposed v1 shape

This example is illustrative, not a frozen schema:

```json
{
  "schemaVersion": 1,
  "id": "exampleos",
  "stationDir": "exampleos",
  "lifecycle": "production",
  "enabled": true,

  "build": {
    "key": "exampleos",
    "script": "scripts/build-guests/tiles/exampleos.sh",
    "class": "heavy",
    "automation": "full",
    "estimatedMinutes": [20, 40],
    "orderAfter": ["tinycore"],
    "mediaGate": "none",
    "artifact": "/data/gallery-guests/ExampleOS/example.qcow2"
  },

  "museum": {
    "displayName": "Example OS",
    "year": 1999,
    "lineage": "Example lineage",
    "arch": "i386",
    "ramMB": 256,
    "era": "1990s",
    "accent": "#336699",
    "eraLabel": "1999 · Example OS",
    "eraSoftware": ["Example Shell"],
    "periodBrowser": "Example Browser",
    "iconicApps": ["Example App"],
    "blurb": "One-line museum description.",
    "archetype": "beige-tower-crt"
  },

  "stream": {
    "transport": "streamhost",
    "slot": 123,
    "udpPort": 54123,
    "fps": 30,
    "audio": true,
    "touch": false,
    "pointer": {
      "transport": "abs",
      "device": "usb-tablet",
      "scale": 1.0,
      "offset": [0, 0]
    }
  },

  "runtime": {
    "vmidLabel": 123,
    "bringUpOrder": 123,
    "qemu": {
      "mode": "generic",
      "machine": "pc-i440fx-11.0",
      "accel": "kvm",
      "cpu": "host",
      "memoryMB": 512,
      "smp": 1,
      "vga": "cirrus",
      "audioDevice": "ac97",
      "inputDevice": "usb",
      "mediaArgs": "-drive file=/data/gallery-guests/ExampleOS/example.qcow2,format=qcow2,if=ide",
      "boot": "c",
      "extraArgs": ""
    },
    "deviceSetId": "exampleos-v1"
  },

  "reset": {
    "mode": "loadvm",
    "snapshot": "golden",
    "fixture": "Example desktop with editor focused.",
    "mouseEvidence": "PASS",
    "keyboardEvidence": "PASS"
  },

  "operator": {
    "exec": null,
    "actionProfile": "default-gui"
  },

  "credentialsRef": "guest/exampleos",
  "bootVideo": {"enabled": false},
  "guestDoc": "docs/guests/exampleos.md"
}
```

For a bespoke launcher, replace the generic QEMU object with:

```json
"qemu": {
  "mode": "verbatim",
  "launcher": "streamhost/stations/exampleos/qemu-streamhost.sh",
  "envFixture": "streamhost/stations/exampleos/station.env.fixture",
  "auxFiles": [],
  "machine": "pc-i440fx-11.0",
  "deviceSetSummary": ["ide:golden.qcow2", "cirrus", "sb16", "ps2", "com1"]
}
```

The launcher remains authoritative for the exact command in verbatim mode, but
the registry owns its selection, public metadata, machine pin, and declared
device summary. CI can hash a normalized guest-visible command into
`deviceSetId` or require an explicit version bump when it changes. Do not put a
raw hash in the source until normalization is reliable; a false parity signal
is worse than a reviewed version string.

Showcase and candidate entries use the same museum schema but conditional
requirements:

- `transport: "showcase"` requires no port, tile directory, QEMU, reset, or
  builder registration;
- `lifecycle: "candidate"` may reference a research builder and blocker, but is
  excluded from generated production artifacts;
- `lifecycle: "experiment"` requires an expiry/owner note and can be emitted to
  signal/SPA without entering production reset or bring-up lists.

### 3.3 What the registry must not contain

- media hashes and licensing detail already owned by the assets manifest;
- product keys, passwords, private-key material, or gated URLs;
- hundreds of machine-vision steps or guest provisioning commands;
- mutable service status, QMP socket presence, PID, current cert hash, or the
  observed existence of `golden`;
- boot-video reference crops and timing heuristics that are unique to a tile.

Those remain in the asset manifest, secret store, builder, runtime probe, or
coldboot sidecar respectively. The canonical entry should reference them and
validate that the path exists.

## 4. Generators and validation

Add one tool, for example `scripts/stations-registry.py`, with four modes:

```text
validate   schema + cross-entry uniqueness + referenced-path checks
generate   write every derived artifact deterministically
check      generate into a temp dir and diff committed derived artifacts
explain ID show every output row derived for one tile
```

Generation must be deterministic: sorted keys, stable formatting, no timestamps,
and atomic replacement only after every output succeeds. Every generated file
starts with a comment or `_generated` marker instructing maintainers not to edit
it. `check` belongs in CI and in the pre-deploy path.

### 4.1 Output mapping

| Canonical fields | Generated output | Hand edits removed |
|---|---|---|
| `build.*` for enabled production tiles | a sourced/generated manifest consumed by `scripts/build-guests/build-all.sh` | `MANIFEST` and `DEFAULT_ORDER` registration |
| `runtime.qemu`, `stream.*`, `stationDir` | `streamhost/stations-manifest.generated.sh` emit stanzas, still invoking `streamhost-station.sh` and referenced verbatim launchers | hand-written emit args and repeated port/pointer/device metadata |
| `runtime.bringUpOrder` plus explicit dependencies | generated `TILES=(...)` include consumed by `bring-up-all.sh` | separate boot-order list |
| `id`, `stationDir`, `stream.udpPort` | `scripts/serve/tiles.json` | signal registry row and hash path |
| `reset.*`, pointer/touch evidence | `scripts/serve/golden-manifest.json` | reset map row |
| public `museum`, stream transport/pointer, boot-video flag | `scripts/serve/gallery-manifest.json` | bundled OS binding + manifest/catalog row |
| declared operator capabilities | seed input for `/data/vms/streamhost/stations.json`; `labctl gen` then adds observed sockets/snapshots | duplicated static capability parsing |
| common action profile | generated default `gallery-action-map` row, with an optional per-tile override sidecar | boilerplate probe metadata |
| boot-video enabled/basic canvas metadata | a coldboot inventory/index | repeated enabled flags; detailed detection arm remains hand-authored |

`bring-up-all.sh`, `build-all.sh`, and the SPA should include/consume generated
data rather than themselves becoming generated monoliths. Their control flow and
special cases remain reviewable code.

The current `stations-manifest.sh` can be preserved as a thin wrapper:

```bash
source "$HERE/generated/tiles-emits.sh"
```

The generated file can call the existing `emit` function. Generic and verbatim
launcher behavior therefore stays unchanged during migration.

### 4.2 Cross-field rules

Validation should reject:

- duplicate `id`, `stationDir`, slot, UDP port, host-forward, or bring-up order;
- a streamhost binding without an enabled signal row, QEMU description, reset
  policy, or guest doc;
- a showcase/candidate with a production signal row;
- `pointer.transport=rel` without the SPA relative-pointer flag derived true;
- `pointer.transport=warpd-tcp` without a unique host forward and agent address;
- `warpd-serial` without a serial socket/backend declaration;
- `gallery-hid` without patched-QEMU/device/driver capability and a new
  `deviceSetId`;
- `reset.mode=loadvm` with no snapshot name or writable snapshot store;
- `reset.mode=restart` with a non-null snapshot;
- unversioned `pc`/`q35` machines in production;
- a `stream.udpPort` inconsistent with deterministic slot policy unless marked
  as a migrated legacy exception;
- a private credentials value rather than an allowed opaque reference;
- public `id`/`stationDir` aliasing without an explicit mapping.

Validation cannot prove that a guest boots or a golden matches. Keep
`verify-emit`, builder framebuffer gates, golden dirty→restore proof, browser
acceptance, and runtime `labctl` probes.

### 4.3 Generated labctl data versus observed state

The requested canonical registry can generate the **declared** labctl matrix,
but it should not pretend to generate live facts. Split the current output:

```text
registry declaration: stationDir, qmp path convention, pointer transport,
                      declared exec kind/user/key reference, udp port
runtime observation:  socket present, service active, actual hostfwd parsed,
                      live `info snapshots` result
```

`labctl gen` merges the two and fails or warns on disagreement. The generated
declaration removes `EXEC_CHANNELS` as another hand registry; the live probe
retains its value. `/data/vms/streamhost/stations.json` remains a generated box
artifact, not a committed source.

## 5. Runtime-driven SPA

### 5.1 Collapse the bundled lineup

Serve `gallery-manifest.json` from the same HTTPS origin, generated from the
public registry subset. The SPA's `useManifest` should fetch it at startup with
`cache: "no-cache"`, validate `schemaVersion`, and populate the museum. A
minimal response entry is:

```json
{
  "id": "exampleos",
  "displayName": "Example OS",
  "year": 1999,
  "lineage": "Example lineage",
  "arch": "i386",
  "ramMB": 256,
  "accent": "#336699",
  "era": "1990s",
  "eraLabel": "1999 · Example OS",
  "eraSoftware": ["Example Shell"],
  "periodBrowser": "Example Browser",
  "iconicApps": ["Example App"],
  "blurb": "One-line museum description.",
  "archetypeId": "beige-tower-crt",
  "transport": "streamhost",
  "pointerRel": false,
  "signalEndpoint": "/signal/exampleos.json",
  "bootVideo": null,
  "credentialPolicy": "operator"
}
```

This collapses current responsibilities as follows:

- `archetypeRegistry.ts` becomes only a compiled mapping from known
  `ArchetypeId` to React component. `OS_BINDINGS` moves to runtime data.
- `mock/manifest.json`, the three-row `catalog.ts`, and the lineup-producing
  portion of `museumCatalog.ts` are retired after migration.
- `useManifest.ts` becomes one public-manifest fetch plus the existing optional
  boot index overlay. Ultimately boot metadata can be included in the generated
  manifest or retained as its independently updated overlay.
- `types.ts` remains the SPA interface, preferably generated from the same
  JSON Schema or checked against it. A type definition is not a registry.

A runtime registry avoids a Vite rebuild for new entries which use an existing
archetype and UI schema. A new React archetype or a new UI feature still needs a
normal SPA build, as it should.

### 5.2 Failure and compatibility behavior

Do not make the gallery blank when the new endpoint is unavailable. Ship a
generated, embedded last-known-good manifest in the SPA bundle and use it only
when the runtime request fails validation/network. Emit visible telemetry when
fallback is used. During migration, compare runtime and bundled IDs in the
client log.

For an unknown `archetypeId`, either use the existing beige-tower fallback with
a warning or reject only that row. For an unknown `transport`, reject the row;
silently attempting the wrong connection is unsafe.

The signal map and gallery manifest should be published atomically or versioned
with the same registry digest. A client that loads between two file moves must
either see the old coherent pair or the new coherent pair.

### 5.3 Credentials

Do not fold private credentials into a served public manifest. The canonical
entry contains only an opaque `credentialsRef` and public policy:

```text
none      no login / autologin; safe public hint
pending   not yet documented
operator  look up through a separate authenticated operator-only mechanism
```

Short term, keep `credentials.ts` gitignored and map `credentialsRef` locally;
the new OS need not edit tracked SPA sources. Longer term, replace bundled
private values with an authenticated LAN/operator endpoint or a password
manager integration. Anything embedded in Vite output is retrievable by every
gallery visitor and must not be treated as secret.

## 6. Deterministic port allocation

Hand-picked ports create collision risk and repeat the same number in manifest,
serve JSON, launchers, and comments. Use an immutable numeric `slot` as the
allocation input:

```text
production WebTransport UDP = 54000 + slot
experiment WebTransport UDP = 54900 + experimentSlot
```

The exact ranges are configurable, but the rule should preserve the dominant
current pattern (`slot` 81 → UDP 54081, 118 → 54118). The allocator chooses the
lowest free slot in the canonical registry, writes it into the new entry once,
and never recalculates from list order. Do not hash `osId`: collision resolution
would make allocation order-dependent, and renaming an ID would move the port.

Migration rules:

- import every existing port unchanged;
- mark nonconforming ports such as ReactOS UDP 4433 as
  `legacyPortException: true`;
- never renumber an existing production tile merely to make the table pretty;
- derive hash-file paths from `stationDir`, not another free-form field;
- allocate host forwards from separate named pools (`ssh`, `warpd`, test) because
  they have different consumers and cannot safely share the UDP slot formula.

**What it removes:** per-add port selection and repeated serve/manifest edits.
**Effort:** 1–2 engineer-days after the registry exists. **Risk:** low for new
tiles, high if applied retroactively; therefore legacy ports remain fixed.

## 7. Proposal-by-proposal ROI

Estimates assume familiarity with the current Python/Bash/TypeScript stack and
include tests but not rebuilding guest goldens.

| Rank | Proposal | Hand work removed | Effort | Main risk / regression surface | Safe migration |
|---:|---|---|---:|---|---|
| **1** | Canonical per-tile JSON + schema + generator/check tool | Repeated rows in build registration, emit manifest, bring-up order, signal JSON, golden JSON, common action metadata, and declared labctl capabilities; roughly 7–9 hand-edited files per tile | **5–8 days** | A generator error can affect the whole fleet; schema may overfit QEMU's easy cases | Import all 28 production rows and 3 showcases, generate to temp, require byte/semantic parity, then switch one consumer at a time |
| **2** | Runtime-served public SPA manifest | `OS_BINDINGS` lineup rows, `mock/manifest.json`, catalog split, most per-row TS edits, and the rebuild/deploy for an existing archetype; roughly 3–6 SPA surfaces per tile | **4–6 days** | Startup/fallback behavior, schema skew, unknown archetype/transport, atomic publish | Serve beside current bundle, compare IDs/fields, add embedded fallback, canary, then remove static lineup |
| **3** | Generator `check` mode + CI cross-registry invariant tests | Does not remove as many edits initially, but immediately eliminates silent ID/port/reset/pointer skew and makes later generator adoption safe | **1–2 days** | False positives from current ambiguous fields; brittle textual diffs | Begin with set/port/alias checks and an allowlist, clarify semantics, ratchet to zero exceptions |
| **4** | Immutable slot + deterministic port/host-forward allocators | Manual port search, duplicate port edits, collision debugging | **1–2 days** | Renumbering breaks URLs/firewalls and live daemons | Grandfather every current port; apply deterministic allocation only to new IDs |
| **5** | Declared/observed labctl split | Hand `EXEC_CHANNELS` registration and ambiguous launcher parsing for static facts | **2–3 days** | Operator tools rely on current generated shape | Keep output schema; change only its input merge, compare old/new JSON on 28 tiles |
| **6** | Credentials reference + operator-only retrieval | Tracked-source audit and future per-OS local TS coupling; improves secret handling more than file count | **2–5 days**, depending on auth | Access control and operator UX; accidental public exposure | First emit only `none/pending/operator`, retain gitignored lookup; add authenticated backend later |
| **7** | Generate the whole QEMU launcher from the schema | Could remove bespoke launchers | **High/ongoing** | Very high: overlays, conditional loadvm, QMP forwards, serial agents, firmware, bridge cgroups, and reset helpers do not fit one safe template | **Do not pursue fleet-wide.** Generate generic launchers; reference verbatim ledgers for exceptions |
| **8** | Declarative installer/golden/boot-video DSL | Could theoretically remove builder and coldboot scripts | **Very high** | Arbitrary installers and framebuffer state machines become an opaque second programming language | **Not worth it.** Keep tested scripts and sidecars referenced by typed metadata |

The quickest useful first change is Rank 3, because it can land without changing
runtime behavior. The highest-value refactor is Rank 1. Rank 2 supplies the most
visible operational win by removing the SPA rebuild for ordinary additions.

## 8. Detailed migration plan for the existing fleet

### Phase 0 — freeze meanings and tests (1–2 days)

1. Document precise semantics for public ID, runtime directory, physical input
   device, input transport, touch, reset mode, and observed golden state.
2. Add a read-only inventory test which reports the four existing sets and
   alias mappings. Do not fail on known differences yet.
3. Capture current generated artifacts and pass `verify-emit`, JSON parsing, SPA
   build, signal smoke tests, and labctl generation.
4. Resolve or explicitly grandfather the nine pointer-field disagreements.

### Phase 1 — schema and import (2–3 days)

1. Define JSON Schema v1 with lifecycle conditionals.
2. Import the 28 manifest rows without changing any value, plus `win11`,
   `riscos`, and `macos` as showcases and the two soltests as experiments.
3. Use explicit aliases and legacy port exceptions. Do not rename directories,
   change machine types, or rebake goldens here.
4. Add candidate entries such as NeXTSTEP only if `enabled: false`; they must not
   appear in production outputs.

### Phase 2 — shadow generation (2–3 days)

Generate every output beneath a temporary/shadow directory. Compare:

- emit arguments and emitted `station.env`/launchers against `verify-emit`;
- `serve/tiles.json` and golden manifest structurally with `jq -S`;
- bring-up order exactly;
- build-all `--list` rows and default ordering;
- declared labctl fields against the current 28 runtime rows;
- SPA public data against all 33 current bindings.

No production consumer changes until unexplained differences are zero.

### Phase 3 — adopt operational outputs one at a time (2–4 days)

Recommended order:

1. signal JSON and golden manifest (simple JSON, read-fresh behavior);
2. generated bring-up list include;
3. generated build manifest include;
4. generated streamhost emit include;
5. declared labctl seed and action-map defaults.

Each switch is a separate reviewable change with the old hand-written data
available for rollback. Do not combine it with a QEMU/golden change.

### Phase 4 — runtime SPA canary (2–3 days)

1. Serve generated `gallery-manifest.json` without changing the SPA.
2. Teach the SPA to fetch/validate it while retaining an embedded generated
   fallback.
3. Compare runtime versus current bundled entries in telemetry.
4. Canary an existing showcase and an existing live tile; then switch the full
   lineup.
5. Retire `OS_BINDINGS` rows and the catalog/base-manifest split only after the
   fallback and all 33 current exhibits pass.

### Phase 5 — prove the new-OS workflow

Use one low-risk Tier-1 OS or a disposable experiment:

1. allocate an immutable slot;
2. add one registry JSON, builder, guest doc, and optional launcher sidecar;
3. run `validate`, `generate --check`, builder/golden proof, and SPA/runtime
   smoke tests;
4. demonstrate that no serve JSON, golden JSON, bring-up array, build array, SPA
   catalog/binding, or labctl static registry was hand-edited;
5. retain the prior generated bundle for atomic rollback.

The migration keeps all current ports, IDs, tile directories, machine types,
launchers, goldens, exhibit order, and reset behavior. Its first purpose is to
centralize existing truth; normalization comes only after parity.

## 9. Expected steady-state workflow

For a normal new guest using an existing archetype:

```bash
# Author these:
$EDITOR registry/stations/<osId>.json
$EDITOR scripts/build-guests/tiles/<osId>.sh
$EDITOR docs/guests/<osId>.md
# Optional only for a non-generic runtime:
$EDITOR streamhost/stations/<stationDir>/qemu-streamhost.sh
$EDITOR streamhost/stations/<stationDir>/station.env.fixture
$EDITOR streamhost/stations/<stationDir>/golden-bake.sh

scripts/stations-registry.py validate
scripts/stations-registry.py check
scripts/build-guests/build-all.sh --check-assets --only <builderKey>
scripts/build-guests/build-all.sh --only <builderKey>
# prove framebuffer/input/reset, then deploy generated artifacts atomically
```

No Vite build is needed unless the OS needs a new React archetype or UI schema.
No port is selected by hand. No public ID is copied into multiple registries.
The hard work that legitimately varies by OS—media, drivers, install automation,
device compatibility, and the golden—remains explicit and testable.

## 10. Decision summary

- Adopt per-tile JSON plus JSON Schema, not a single giant hand-edited JSON and
  not YAML with a new parser dependency.
- Generate today's artifacts first; rewrite consumers incrementally.
- Move the public SPA lineup to a runtime-served manifest with an embedded
  generated fallback.
- Allocate immutable slots deterministically, grandfathering all current ports.
- Split physical input device from input transport and declared capability from
  observed state.
- Keep secrets out, keep bespoke launchers/builders where they earn their keep,
  and do not invent a declarative installer language.

The headline result is a reduction from about 15 touched files for one tile to
3–5 authored files, with common metadata changed once and no SPA rebuild for an
existing archetype.

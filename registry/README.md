# Canonical tile registry

`registry/stations/<osId>.json` is the typed source of truth for the gallery lineup.
Do not copy a fleet total into a new source of truth; derive the current total:

```bash
python3 scripts/stations-registry.py count
# 39 lineup entries: 37 streamhost production tiles, 2 showcase posters
```

The schema is `registry/schema/tile-v1.schema.json`.

## Deployment-local values (the `registry/local.env` mechanism)

The public repo was scrubbed for release: the operator's real LAN IP, box
hostname, and public domains were replaced with RFC 5737 / documentation
placeholders (`192.0.2.10`, `labhost`, `example.com`, `gallery.example.com`,
`tunnel.example.com`). Every tool keeps its placeholder as the DEFAULT so a
fresh public clone works out of the box and `make station-registry-check` stays
deterministic across machines — every generated and rendered artifact keeps
the placeholder regardless of local configuration.

The real values are supplied at *run/deploy* time, not at *generate* time: copy
`registry/local.env.example` to `registry/local.env` (gitignored) on the box and
fill in the keys documented there (`SH_HOST_IP`, `SH_TUNNEL_HOST`,
`SH_GALLERY_HOST`). The shared helper `scripts/lib/local-env.sh` locates and
sources that file for every consumer, and is a no-op when the file is absent —
see the header comment in that file for the exact precedence rule (explicit CLI
flag / pre-set environment variable > `registry/local.env` > repo placeholder).
`streamhost/scripts/streamhost-station.sh` was the first, station.env-emitting
consumer (`SH_HOST_IP`, overridden by an explicit `--host-ip` flag); the same
mechanism now also backs `scripts/serve-https-spa.sh`,
`scripts/serve/restart-https.sh`, `scripts/serve/gen-local-ca.sh`,
`scripts/dev/verify-tile.sh`, `scripts/dev/mobile-netem.sh`,
`streamhost/run/serve_client.sh`, `streamhost/bring-up-all.sh` (generated from
`registry/templates/bring-up-all.sh.in` — edit the template, not the generated
file), and the `scripts/cloud-agents/` tunnel-endpoint tooling.
`registry/local.env` never affects `scripts/stations-registry.py generate` output.

## Exhibit posters

A tile's optional long-form poster is the sibling Markdown document
`registry/posters/<id>.md`. The filename match is the association: there is no
second id or hand-maintained lookup. The JSON Schema records this convention in
`x-posterAssociation`, and `scripts/stations-registry.py` validates and compiles
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
python3 scripts/stations-registry.py validate
python3 scripts/stations-registry.py count
python3 scripts/stations-registry.py generate
python3 scripts/stations-registry.py --check
python3 scripts/stations-registry.py explain solaris
```

`generate` validates everything before atomically replacing outputs. `--check`
renders in memory and byte-compares every committed output; on the lab box it
also compares the declared labctl fields with `/data/vms/streamhost/stations.json`.
`scripts/gen_tiles_json.py` consumes the generated declaration seed, verifies it
against live env/launcher facts, and then adds only its read-only golden-snapshot
probe. Observed service/socket/snapshot state remains owned by `labctl gen` and
is not written back into this registry.

The rendered artifacts (OS binding lines, emit invocations, build-manifest
rows) are serialized from the typed fields; the legacy pre-rendered `render.*`
string mirrors were removed once semantic parity was proven, so `render` now
carries only ordering, preludes, and comments. A tile's `station.env.fixture` is
the single source for the env keys it defines — the generator merges it into
the env view the validators and the rendered `index.json` see, and validation
fails any key that appears in both places. Verbatim QEMU launchers remain
authoritative device ledgers and are referenced, never rewritten, by this
generator.

### Generated vs rendered

Two classes of output, and the difference is where they live:

- **Generated** (`generate`): written into the tree and committed — the three
  shell manifests (`streamhost/stations-manifest.sh`, `bring-up-all.sh`,
  `build-guests/build-all.sh`), the four SPA-compiled TS modules
  (`archetypeRegistry.ts`, `posterIndex.ts`, `demoPrograms.ts`,
  `keyboards.ts`), and `registry/generated/labctl-declarations.json`. Each has
  a consumer that opens it as a file with no generator available: a shell that
  runs it, the Vite build that compiles it, the box's `gen_tiles_json.py` that
  reads it. `make station-registry-check` proves each is byte-identical to what
  the registry produces now.
- **Rendered** (`render` / `emit`): never committed, never in the tree — every
  JSON document that is *served or published* rather than compiled:
  `gallery-manifest.json`, `poster-docs.json`, `tiles.json`,
  `golden-manifest.json`, `gallery-action-map.json`, `mock-manifest.json`,
  `fleet-table.json` (the SPA's `/fleet` operator table: derived tier, the
  declared `emulator` block, the declared `ui` kind, screen geometry
  (display block > x11 geometry > fixture prose), kiosk suite, I/O paths, labctl exec channel,
  guest networking (device ledger, or the optional declared `network` block),
  memory, idle-pause, golden scene — `scripts/stations_registry/fleet_table.py` holds every
  derivation rule), and `index.json` (the whole-registry aggregate). Every consumer can ask: the
  publish path renders then ships, the SPA fetches over HTTP, the tests render
  into memory, the Vite dev server answers a request by rendering, the box-sync
  gate renders the repo side before comparing. `render` drops them in the
  gitignored `build/registry/`; `emit <name>` writes one to stdout. Nothing can
  go stale, and a gallery string searched in the repo has exactly one hit — the
  registry entry that owns it.

For a live-edit loop, `devwatch` (Rust, `streamhost/devwatch`) watches the
hand-written sources, runs `generate` + `render` on every save, and — only when
the change validates — publishes the runtime manifests (gallery manifest,
poster docs) to the box via `scripts/serve-https-spa.sh manifests`:

```bash
make devwatch          # deploys need registry/local.env; --help for flags
```

For an ordinary new OS, author one registry entry, its builder, and its guest
documentation; add a bespoke launcher only when the generic runtime is not
sufficient. Do not hand-edit generated artifacts.

## Weekly release notes (`registry/release-notes/`)

`registry/release-notes/<end-date>.json` is the other hand-authored thing under
`registry/`, and it has nothing to do with a station: one file per closed week,
named after the Sunday the week ended, holding that week's **prose**. It is
written by a Claude Code pass the operator triggers by hand
([`docs/lab/RELEASE-NOTES-PROMPT.md`](../docs/lab/RELEASE-NOTES-PROMPT.md)), not
by any generator, and the schema is locked and validated:
`week`/`title`/`start`/`end`/`commitCount`/`summary`/`bullets` (plus `source`
for week 0, which predates this repository), 3 paragraphs of 300-400 words —
week 0 alone is 4-5 paragraphs of 600-700, a deliberate one-off for the month
of pre-public history behind it — at most 20 single-line bullets, week numbers
unique and **contiguous from 0**, and consecutive weeks must abut.

`registry/release-notes/sources.json` sits beside them and is **not** a week:
it is the hand-written declaration of the commit sources `brief` gathers
*besides* this repository's git log — the four public emulator forks
(`Wnt/mame`, `Wnt/es40`, `Wnt/vice`, `Wnt/qemu`), which branch of each the
builds actually pin, who counts as us (`ourAuthors`), and which branches are
excluded **with the reason recorded**, so a later reader cannot helpfully
re-add a trial branch, plus `ourCommitAuthors` — the plain git author names for
work pushed from the lab box, which reaches GitHub with no account login at
all. Every branch cites the file that pins it (`pinnedBy`); `check` **parses**
the pin out of each cited file (a `.gitmodules` `branch =`, a `*FORK_BRANCH=`,
a station's `emulator.source`) rather than searching it for the branch name,
and sweeps the same formats across the tree in the other direction, so both a
repointed build and an undeclared branch go red. Only `brief` reads it for
commits, and only `brief` touches the network — `render` and `check` stay
offline. A commit `brief` cannot attribute is never dropped: it is printed
under a DECIDE BY HAND block.

`scripts/release-notes.py render` (`make release-notes`) lays those files out
into three generated outputs — README.md's "Release notes" section,
`docs/RELEASE-NOTES.md` and `spa/public/release-notes.json` — which are never
hand-edited; `check` re-validates and asserts they match a fresh render. No git
history is read for content, so the check is deterministic.

## Taking an exhibit off the floor — the `listing` soft hide

`listing` is the supported way to keep a live exhibit out of the gallery's
listings without touching anything else about it:

```json
"listing": {
  "state": "hidden",
  "since": "2026-08-10",
  "reason": "Off the floor for the de-bridging spike: atarist is the measured tile ..."
}
```

The block is optional and absent means listed, so every entry without it behaves
exactly as before. `hidden` removes the tile from the 2D grid, the 3D museum hall
and their era/total counts — and from nothing else. It stays a full lineup
entry: it still ships in the rendered `gallery-manifest.json` (flagged `"listed": false`,
row intact), still streams, still keeps its scene bindings, keyboard profile and
poster, so the SPA parity tests pass untouched and nothing has to be deleted and
restored.

**This is discoverability, not access control.** `/os/<id>` still resolves and
streams exactly as before — that is deliberate, it is what makes a dark launch
useful — so anyone holding or guessing the URL gets in. Carrying the manifest row
is what keeps that working; dropping it is the bug this field exists to stop.

**`listing` is not `enabled`.** `enabled: false` retires the tile from the
lineup: it leaves the manifest entirely, the deep link dies, and the SPA's
hand-maintained per-tile files (`machineIdentity.ts`, the assembly and tint in
`machines.ts`, `presentAspect.ts`, `keyboardProfiles.ts`) have to be edited and
edited back. Reach for it when an exhibit is gone, not when it is resting.

**One state, not two.** A never-announced *dark launch* and a temporarily
withdrawn *off the floor* exhibit render identically on every surface, so a
second enum value would be a distinction no consumer could branch on — and the
two are not even disjoint, since a dark-launched tile that gets listed and later
withdrawn would have to rewrite the field anyway. What actually differs is the
prose, so `reason` carries it and is required (with `since`, `YYYY-MM-DD`)
whenever `state` is `hidden`, and forbidden when it is `listed`. `git log --
registry/stations/<id>.json` answers "who took it off"; a field would only be able
to go stale about it.

`validate_listing()` in `scripts/stations-registry.py` enforces the shape (the
schema's `additionalProperties` and conditionals are decorative — see below) and
rejects a hide on an entry that is not in the public lineup anyway, so a
declared hide can never be a no-op that a later session believes.

## Generated artifacts and their gate lists

`generated()` in `scripts/stations-registry.py` is the single authoritative list of
generated output paths. Three lint/CI gates carry their own copies of that list
and MUST stay in lockstep with it:

- `scripts/check-generated-drift.sh` (`GENERATED_PATHS`)
- `scripts/check-file-size.mjs` (`GENERATED` set — the size-budget exemption)
- `scripts/lint/shell-sources.sh` (the `:(exclude)` list — the generated `.sh`
  subset that shfmt/shellcheck skip)

`python3 scripts/stations-registry.py paths` prints the authoritative list, and
`make station-registry-check` fails if any gate list drifts from it, so the copies
cannot silently rot when outputs are added or renamed.

## Schema rules the homegrown validator does NOT enforce

`registry/schema/tile-v1.schema.json` is Draft-2020-12, but the repo does not run
a standards validator. `validate_json_schema()` in `scripts/stations-registry.py` is
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
- `runtime.stationEnv` emits `SH_QEMU_MODE=pve`, `SH_PVE_VMID=<vmid>`,
  `SH_QEMU_PIDFILE=/var/run/qemu-server/<vmid>.pid`.
- `runtime.qemu` has NO `launcher` (pve tiles are not launcher-driven).
- If `reset.resetMode == "pve-rollback"`, then `runtime.qemu.mode` must be `pve`
  and `reset.snapshot` must be `"golden"`.

### gallery-hid / unified input backend

`stream.pointer.backend` (enum `disabled` / `dbus-abs` / `dbus-rel` / `warpd` /
`gallery-hid` / `x11test` / `mamecmd` / `mamesock` / `vicesock` / `mgactl` /
`artistctl` / `ramabs`) is an OPTIONAL sibling of the legacy required
`stream.pointer.transport` (enum `abs` / `rel` / `warpd`). This mirrors the Rust `config.rs` `InputBackend` +
`parse_input_backend` (an explicit `backend` wins; an absent one derives from
`transport`). gallery-hid tiles carry a redundant `transport: "abs"` by design
(`config.rs` `GalleryHid → abs`). Business rule (Python, not schema): when
`backend` is present the stationEnv MUST emit `SH_INPUT_BACKEND=<backend>` and MUST
NOT also emit the legacy `SH_POINTER`. A backend is now the normal
declaration rather than the exception: every host-native (Tier 3) station carries
one, since none of them has a QEMU dbus display to fall back to.

### Pointer method, absolutivity and presence

`stream.pointer.transport` / `.backend` say how the DAEMON delivers a pointer.
Three further fields — required on **every** entry, posters included — say what
the GUEST ends up with, which is the question a visitor, a poster author and a
tile author all actually ask:

- **`present`** — any pointer input at all reaches the guest. `false` is the
  keyboard-only exhibit (`SH_INPUT_BACKEND=disabled`: the Commodore 8-bits,
  mpf2, the Sinclair/Acorn/Dragon/Oric machines, pdp11, decos, kc854) and the
  showcase poster.
- **`absolute`** — the guest receives the visitor's POSITION, not motion deltas.
  Mirrors `InputBackend::pointer_mode()` in `streamhost/streamhost/src/config/
  backends.rs`: true for every backend except `dbus-rel` and `disabled`.
- **`method`** — the mechanism that puts the pointer where the visitor pointed:

| `method` | how it works | example |
|---|---|---|
| `none` | nothing is delivered: a keyboard-only exhibit, or a poster with no machine behind it | `pet2001`, `macos` |
| `qemu-usb-tablet` | QEMU `-device usb-tablet` reports absolute HID coordinates and the guest's own USB HID driver consumes them — the ordinary x86 case | `winxp` |
| `qemu-vmmouse` | QEMU's VMware-backdoor absolute aux mouse on the i8042, consumed by a VMware mouse driver inside the guest; no USB involved | `nt4` (explicit `vmport=on`), `serenityos` (implicit q35 default) |
| `qemu-ps2-relative` | no absolute path exists: paced, bounded relative deltas into the emulated PS/2 mouse | `nextstep`, `qnx` |
| `qemu-mga-closedloop` | still relative on the wire — but the guest drives the emulated Matrox HARDWARE cursor, so QEMU reads its pointer back out of the DAC's CURPOSX/Y registers and a loop inside `hw/display/mga.c` converges on the commanded pixel. `absolute: true` is earned by measurement, not by a device | `aix432` |
| `gallery-hid` | a bespoke `gallery-hid-pci` device in the locally patched QEMU plus its matching in-guest driver, taking absolute coordinates natively | `solaris` |
| `warpd-agent` | an in-guest agent warps the guest's own cursor to the requested coordinate | `win95` |
| `mame-ioport` | streamhost writes the EMULATOR's input ports, never the guest: closed-loop `MOVEA` targets to MAME's in-emulator control module | `irix` |
| `x11-xtest` | XTEST fake-input into the captured X server itself — `XTestFakeMotionEvent` to an absolute root coordinate, and (with `SH_X11TEST_BUTTONS=xtest`) `XTestFakeButtonEvent` for the edges. The only method that never touches an emulated device: it moves the HOST's pointer, and the emulator picks that up as its own input | `amigaos35`, `amix` |
| `simh-light-pen` | the absolute tablet position plus button 1 IS Open SIMH's VT11 light pen — no cursor, and no keyboard input of any kind | `gt40` |

**`x11-xtest` is absolute on the HOST, which is not the same as absolute in the
GUEST**, and `amigaos35` vs `amix` is the pair that shows it. Both declare
`backend: x11test` / `absolute: true`, because that is the DAEMON's injection
contract — `InputBackend::pointer_mode()` in
`streamhost/streamhost/src/config/backends.rs` makes `x11test` absolute and
`validate_pointer_method()` enforces the agreement. What the guest then does with
the host pointer is a property of the guest, not of the declaration:

- `amigaos35` is genuinely 1:1, because the UAE **mousehack** is an AmigaOS-level
  trap — the guest OS registers a block and UAE writes host coordinates straight
  into it (`device: mousehack`).
- `amix` is **not** 1:1 (open at the time of writing). AMIX is a Unix that drives
  the emulated Amiga **mouse hardware** directly and never registers a mousehack
  block (`device: amiga-mouse`), so an absolute host warp reaches it as relative,
  accelerated deltas and the guest cursor's position depends on history. Closing
  it needs either a relative XTEST backend in the daemon
  (`XTestFakeRelativeMotionEvent`) or FS-UAE grab-mode calibration —
  [`docs/guests/amix.md`](../docs/guests/amix.md).

So on an x11test station the `device` field is the one that says what the guest
sees, and `reset.mouse` is where the measured verdict belongs. Read
`absolute: true` here as "the daemon injects a position", never as "the guest
receives one".

Finer wire detail stays in the sibling fields rather than multiplying the enum:
`backend` already separates `mamecmd` (Lua command file) from `mamesock`
(ctlsock), `agentAddress` already separates a warpd agent on a hostfwd TCP
port (`win95`, `ninefront`) from one on a serial chardev (`win311`, `os2warp`,
`templeos`), and `SH_X11TEST_BUTTONS` separates the two `x11test` button routes
(the historical command file vs `XTestFakeButtonEvent`).

Nothing at runtime reads these three fields, so `validate_pointer_method()` in
`scripts/stations-registry.py` DERIVES all three from the places that do decide and
fails on any disagreement: the effective `SH_INPUT_BACKEND` (or the legacy
`SH_POINTER` it comes from), the tile's device ledger (launcher command lines,
`deviceSetSummary`, `emitArgs`) and `operator.labctl.pointer_mode`. A tile
declaring `absolute: true` while running `dbus-rel`, or the tablet method with
no `usb-tablet` wired up, is a failed `validate`. The one exception token is
`pointer-vmmouse-implicit` in `migrationExceptions`, for a guest whose absolute
aux mouse comes from a machine-type default that no device ledger names
(`serenityos`).

The fields are not added to `registry/generated/labctl-declarations.json`:
`LABCTL_KEYS` must stay in lockstep with the box's `tiles.json`, whose
`pointer_mode` already carries the abs/rel/warpd/none projection labctl needs —
so it is cross-checked here rather than duplicated. They ride into the rendered
`index.json` with the rest of each row, and are deliberately kept out of the
SPA bundle, which renders none of them.

### Three hand-synced enforcement copies

The input-backend and pve rules live in THREE places that are kept in sync by
hand — there is no generator binding them: (1) the schema enums here, (2) the
Python evaluator + business rules in `scripts/stations-registry.py`, and (3) the
Rust `streamhost/streamhost/src/config.rs` (`InputBackend`, mode parsing). A
future hardening — swapping in a real Draft-2020-12 validator so `allOf`/`if`/
`then`/`additionalProperties` actually run — WOULD change validation behaviour
and must be a separate, reviewed change, out of scope for output-preserving work.

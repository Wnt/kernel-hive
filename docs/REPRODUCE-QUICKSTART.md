# Reproduce quickstart from a fresh clone

This is the entry point for a checkout that contains only tracked files. There
are two different reproducibility claims:

- The UI installs and builds locally without private credentials.
- The complete gallery is a hardware-specific Proxmox rebuild, not a local demo
  and not a single-command appliance. It needs external media, operator secrets,
  network downloads, and several interactive or still-manual steps.

The authoritative full procedure remains
[`lab/MASTER-REPRODUCE.md`](lab/MASTER-REPRODUCE.md). This page tells a new
operator what must exist before entering it and where the known gaps are.

## 1. Clone and choose a path

```bash
git clone <repository-url> kernel-hive
cd kernel-hive
```

Use the UI path on a normal development machine. Use the full-labhost path only
when rebuilding the intended x86-64 Proxmox environment; run labhost-side phases
as root and workstation-side phases where the master runbook says to. labhost
needs enough storage for the guest media and generated disks. The builder and
launcher scripts assume QEMU/KVM, Proxmox utilities, ZFS paths under `/data`,
internet access, and labhost's layout; a successful local `--dry-run` does
not prove those prerequisites.

## 2. Build or run the UI locally

Prerequisite: Node.js with npm. The repository does not declare a Node `engines`
range; this tracked-only path was verified with Node 22 and npm 10.

```bash
cd spa
npm ci
npm run build
npm run dev
```

`prebuild` and `predev` run `scripts/ensure-credentials.mjs`. When the private
`src/data/credentials.ts` is absent, the shim copies the tracked
`src/data/credentials.example.ts` placeholder and never overwrites a real local
file. `node_modules/`, `dist/`, `tsconfig.tsbuildinfo`, and the generated
placeholder are ignored.

The build uses the bundled mock manifest when no live manifest is available.
It therefore needs neither labhost nor guest credentials. Live station
streaming still requires the HTTPS serve plane and streamhost instances from the
full-labhost path.

## 3. Prepare for a full labhost rebuild

Read these in this order; do not start with an individual guest builder:

1. [`lab/ASSETS-MANIFEST.md`](lab/ASSETS-MANIFEST.md) — inventory, staging
   paths, input classes, pins, and known source-rot or publication risks.
2. [`lab/MASTER-REPRODUCE.md`](lab/MASTER-REPRODUCE.md) — the ordered host,
   guest, streamhost, and gallery procedure. Run its phases top to bottom and
   read its "Gaps / still-manual" section before committing to a rebuild.
3. [`../streamhost/bring-up-all.sh`](../streamhost/bring-up-all.sh) together
   with the per-station deploy section of
   [`../streamhost/README.md`](../streamhost/README.md) — Phase 5 cold-boots the
   built guests and starts streamhost and the serve plane. Also read
   [`../scripts/serve/README.md`](../scripts/serve/README.md) before generating
   its local CA or deploying the UI bundle.

For the bare-metal bootstrap details referenced by Phase 1, read
[`lab/REMOTE-PROVISIONING-NOTES.md`](lab/REMOTE-PROVISIONING-NOTES.md). The
Range-capable HTTP server, iPXE session files, and Proxmox answer file used in
the original build were not vendored; that document is the reconstruction
recipe.

On the target labhost, inspect the build plan and preflight before building:

```bash
./scripts/build-guests/build-all.sh --list
./scripts/build-guests/build-all.sh --dry-run
./scripts/build-guests/check-assets.sh
```

The plain dry run only proves manifest selection and script paths. It does not
check packages, storage, downloads, media, secrets, or guest bootability. The
standalone asset checker intentionally fails in a fresh clone until all
full-fleet inputs below are staged. `build-all.sh --check-assets --dry-run`
checks only the selected/default build set; on a fresh labhost that default set
still fails until the Sailfish source is available.

## 4. External inputs: names and locations

Do not place media or secret values in Git. The definitive inventory, hashes,
licensing notes, and override semantics are in
[`lab/ASSETS-MANIFEST.md`](lab/ASSETS-MANIFEST.md); this table intentionally
lists only input names, paths, and environment-variable names.

| Required for a complete fleet rebuild | Default staging path or input name | Manifest reference |
|---|---|---|
| Solaris 10 U11 x86 DVD ISO | `/data/gallery-guests/SolarisCDE/sol10.iso`; overrides `SOL10_ISO`, `SOL10_ISO_URL` | ASSETS-MANIFEST §1 |
| Windows XP Pro SP3 ISO | `/data/gallery-guests/WinXPpro/winxp-sp3.iso`; overrides `XP_ISO_LOCAL`, `XP_ISO_URL` | ASSETS-MANIFEST §1 |
| Windows XP product key | environment variable `WINXP_PRODUCT_KEY` | ASSETS-MANIFEST §1 and "Env vars" |
| Sailfish SDK emulator VDI | environment variable `SFOS_VDI`; alternative `SFOS_EMULATOR_URL`, or `/data/gallery-guests/SailfishOS/sailfishos.qcow2` with `SFOS_SKIP_DOWNLOAD` | ASSETS-MANIFEST §1 |

The Solaris and WinXP builders are in the `licensed` class and are skipped by
the default `build-all.sh`; use `--include-licensed` only after supplying their
inputs. Sailfish is in the default build order even though its source comes
through the SDK account/EULA flow, so it is also an external prerequisite on a
genuinely empty labhost.

All other base media and software inputs are network-fetched by the builders.
They are still external dependencies: see ASSETS-MANIFEST §2
(`abandonware-URL`), §3 (`freely-fetchable-pinned`), and §5 (known missing or
rot-prone sources). A URL being scripted does not guarantee that the upstream
will remain available or unchanged.

Secrets and private operator state are names/paths only:

- `WINXP_PRODUCT_KEY`; optional private override `XP_ADMIN_PW`.
- BMC/IPMI credentials required by the remote-provisioning runbook.
- SSH identity selected by `SSH_KEY` or `LAB_KEY`, commonly
  `~/.ssh/lab_key`; the `ssh lab` alias used by operational scripts must resolve
  to the intended labhost.
- `docs/gallery-credentials.md` and `spa/src/data/credentials.ts` for private
  guest-login hints. Neither is required for the placeholder UI build.
- `scripts/serve/pki/` must carry the matched `rootCA.key` (CA private key, mode
  600) + `rootCA.pem` pair to preserve trust in browsers that already installed that
  root. Leaf files can be reissued with `gen-local-ca.sh`; `clientcmd.token` may be
  carried for command continuity or regenerated per `scripts/serve/README.md`.

## 5. Build, wire, and bring up

After the hardware and asset preflight, follow MASTER-REPRODUCE Phases 0–4.
The guest orchestrator is the Phase 4 entry point:

```bash
./scripts/build-guests/build-all.sh
```

For all classes, first export the input variables named above, then run:

```bash
./scripts/build-guests/build-all.sh --include-licensed --check-assets
```

Do not append shell environment assignments after the command; export them or
put assignments before the command. Keep machine-type pinning enabled for a
fresh rebuild as directed by MASTER-REPRODUCE Phase 5.

Phase 5 then copies the tracked streamhost and serve-plane trees into their
documented labhost locations, emits the station files, and runs
`streamhost/bring-up-all.sh`. `scripts/dev/verify-emit.sh` is not a clone-local
test: it requires `ssh lab`, `rsync`, and the existing live
`/data/vms/streamhost/stations/` tree for byte comparison. Read it, but do not run
it on a replacement labhost until there is an intentional live reference to
compare.

For streamhost itself, the Linux native packages are documented in
[`../streamhost/README.md`](../streamhost/README.md): `libx264-dev`,
`libopus-dev`, `libclang-dev`, and `pkg-config`, plus a Rust toolchain.

## 6. What is not in Git by design

- Licensed/source media and generated disk images: ISO, IMG, qcow2, VDI, VMDK,
  ROM, and ADF files are ignored or fetched/staged outside the repository.
- Real credentials, tokens, SSH private keys, guest-login tables, and serving
  PKI. The UI carries only a placeholder credential example.
- Dependency and build output: `node_modules/`, UI `dist/`, Rust `target/`,
  caches, logs, and test artifacts.
- The built `/data/gallery-guests/` images, `/data/vms/streamhost/stations/` live
  state, checkpoints, runtime cert hashes, service state, and the deployed
  UI webroot.
- The original session's Range HTTP server, iPXE/answer-file scratch files, and
  BMC secrets. Recreate them from the remote-provisioning notes.
- The optional prebuilt-image migration source. MASTER-REPRODUCE Phase 4′ is a
  shortcut that depends on the old dry-run labhost, not part of from-source
  reproducibility.

## 7. Known limits a fresh operator will hit

- The bare-metal install, BMC/KVM checks, and some guest first boots require a
  person. Win95, Win98, and Android have documented one-time interaction;
  Solaris and WinXP require supplied media.
- A fully curated fleet still has golden-fixture gaps. MASTER-REPRODUCE's
  "Gaps / still-manual" section identifies station-local seed disk copies and
  capture helpers that are not yet fully reconstructed from tracked files.
  Android, FreeDOS, and 9front need a first launch without their unconditional
  `-loadvm golden` before a new checkpoint can be captured.
- Several auto-fetched historical inputs are weakly pinned, moving, or depend
  on preservation mirrors. Preserve legally obtained inputs outside Git and
  verify them against ASSETS-MANIFEST.
- A successful orchestrator dry run reports the planned jobs as `DRY` but ends
  with an "all requested guests built" message. Treat that as a dry-run summary,
  not build evidence.
- `scripts/dev/verify-emit.sh` proves parity with one existing lab inventory;
  it does not prove that a brand-new labhost has complete guest artifacts.

The program-level gap tracker is
[`history/REPRO-GAP-CLOSURE.md`](history/REPRO-GAP-CLOSURE.md). It is historical status
and planning context; MASTER-REPRODUCE remains the operational source of truth.

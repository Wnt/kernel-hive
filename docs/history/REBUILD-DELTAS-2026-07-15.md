> **Historical snapshot.** This document describes the system as it stood around 2026-07-15. It is kept for historical context and is not a description of the current system.

# NVMe rebuild deltas — 2026-07-15

This is the de-duplicated pitfall ledger from `host-base`, `spa-serve`,
`pki-finalize`, `pve-qemu`, `streamhost-emit`, `canary`, guest groups A–G,
`win2000-fix`, the HelenOS/ReactOS/AmigaOS rebakes, and `harvest-wave1`.
`[applied]` means the source or documentation fix was made during the rebuild and
is represented in the harvested union. `[proposed]` means follow-up work remains.
Paths are repository-relative. Values measured or recovered during the rebuild
are intentionally retained even where a later fix superseded the original delta.

## Host / pve-qemu / toolchain

Recovered host baseline (operational fact, not a separate delta): Debian trixie
provided `libx264-dev` `2:0.164.3108+git31e19f9-2+b1`, `x264_encoder_open_164`,
Rust/Cargo 1.97.0, and OpenWatcom 1.9 at `/root/watcom`. The OpenWatcom installer
needed `TERM=vt100`, a pseudo-terminal, and explicit Linux-host DOS/Win16/OS2
components. Its working environment was `WATCOM=/root/watcom`,
`PATH=/root/watcom/binl:$PATH`, `INCLUDE=/root/watcom/h:/root/watcom/h/os2`, and
`EDPATH=/root/watcom/eddat`. The complete observed package set was `git rsync curl
ca-certificates build-essential pkg-config libx264-dev libopus-dev libclang-dev
clang gcc-mingw-w64-i686 nvme-cli smartmontools jq python3 python3-venv ffmpeg`.

- [applied] · `docs/lab/MASTER-REPRODUCE.md` · Rust 1.97 was installed without its matching formatter · add `source /root/.cargo/env && rustup component add rustfmt` to setup · concrete values: Rust/Cargo 1.97.0 and `/root/.cargo/env` · doc-to-update: Phase 3 toolchain prerequisites.
- [applied] · `scripts/provision/build-pve-qemu-fastpoll.sh` · the recipe hard-coded PVE QEMU 11.0.0-3, patch slot 0047, omitted build dependencies/Meson downloads, did not actually apply the quilt series, and did not enforce the requested nice level · resolve the installed version via `debian/changelog`, dynamically allocate slots, use `apt-get build-dep ./`, log `quilt push -a`, fetch Meson subprojects, verify both fast-poll paths, record metadata, and run build work at `nice -n15` · concrete values: installed `pve-qemu-kvm 11.0.2-1`; PVE commit `f17b668feb67097891a5f7012a99bcc1687c2584`; QEMU submodule `e545d8bb9d63e9dd61542b88463183314cff9482`; prior last PVE patch `pve/0046`, fast-poll `pve/0047`, Sphinx `pve/0048`; installed machine types `pc-i440fx-11.0` and `pc-q35-11.0`; patched package SHA-256 `b491dc845b56e5bc30d825044aa7f81f301106ba63c0ade4fd5e25cc2593a0a1` · doc-to-update: `docs/lab/MASTER-REPRODUCE.md` Phase 5.
- [applied] · `scripts/provision/build-pve-qemu-fastpoll.sh` · installed Ceph runtime libraries were newer than the development packages in the configured channel, and `apt-cache show` could succeed with empty output · require actual package metadata, add the Ceph Squid trixie no-subscription channel, and pin development packages to installed runtime versions · concrete values: runtime `19.2.3-pve4`, stale dev channel `19.2.3-pve1`, repository `http://download.proxmox.com/debian/ceph-squid`, suite/component `trixie/no-subscription`, pinned packages `librados-dev` and `librbd-dev` · doc-to-update: `docs/lab/MASTER-REPRODUCE.md` Phase 5.
- [applied] · `streamhost/qemu-patches/0002-sphinx-serial-doc-build.patch` · Sphinx 8.1.3 under Python 3.13 failed in parallel with worker `EOFError` despite ample RAM · serialize only Sphinx with `-j 1`, leaving Ninja compilation parallel · concrete values: Sphinx 8.1.3, Python 3.13, patch slot `pve/0048` in this build · doc-to-update: `streamhost/qemu-patches/README.md` Production rollout.
- [applied] · `streamhost/qemu-patches/rollout-fastpoll.sh` · a fixed MD5 recognized only the old 11.0.0-3 binary · verify `SH_DBUS_UPDATE_MS` in the installed binary and derive its SHA-256 dynamically · concrete values: rollback stock DEB `/data/backups/pve-qemu-rollback/pve-qemu-kvm_11.0.2-1_amd64.deb`, SHA-256 `47e09ae7ff7b6fcc5ea1b4498924af842b05d3a0565108ab65d9399213c9167f` · doc-to-update: `streamhost/qemu-patches/README.md` Production rollout.
- [applied] · `streamhost/qemu-patches/README.md` · rollout text retained stale 11.0.0-3 pins, fixed patch/hash assumptions, and a version-specific rollback URL · document 11.0.2-1 provenance, automatic patch allocation, the serial-Sphinx rationale, dynamic marker/hash verification, and `apt-get download` rollback staging · concrete values: installed binary reports `QEMU emulator version 11.0.2 (pve-qemu-kvm_11.0.2-1)`, contains `pbs-state` and `SH_DBUS_UPDATE_MS` · doc-to-update: Production rollout.
- [proposed] · `docs/lab/MASTER-REPRODUCE.md` · PVE-QEMU and emit agents received `/data/vms/streamhost/build` without `.git`, so claimed HEAD `73419e0` and box-side diffs/history could not be verified at the time · preserve `.git` when staging or write and verify an explicit source-revision provenance file · concrete values: expected full revision `73419e0005fbe70c6135ac68bd772ab5b3be0080`; the checkout had `.git` only by the final harvest · doc-to-update: Phase 3 and Phase 5 source staging.
- [proposed] · `docs/lab/MASTER-REPRODUCE.md` · the fresh host lacked the shared guest SSH identity used by Haiku, Alpine, and TinyCore · generate it before guest builds · concrete values: `ssh-keygen -q -t ed25519 -N "" -C streamhost-gallery-guest -f /root/.ssh/gallery_guest_key`, private/public modes 600/644 · doc-to-update: Phase 5 prerequisites.

## streamhost daemon / launchers / emit / helpers / service lifecycle

- [applied] · `docs/lab/MASTER-REPRODUCE.md` · Phase 3 described a flattened Cargo tree · build from `/data/vms/streamhost/build/streamhost/streamhost` and install `../target/release/streamhost` at the unit’s `/data/vms/streamhost/build/target/release/streamhost` path · concrete values: release binary built during emit had SHA-256 `26bd663c9554228e2b6514c72f1d8ac1af36e726b1472adb17b018c4b741502c` and 42 tests passed · doc-to-update: Phase 3. **Clobber warning:** this correction was present in `harvest-wave1` commit `9ba90e5f279f39071a67fc92f7275e32a3f44641` but is absent from the final box copy harvested here; the orchestrator must restore it.
- [applied] · `streamhost/deploy/relfix/install-relfix.sh` · the installer required unavailable historical base `c7138573`, ignored that HEAD already contained `rel_motion_bounded`, built without the Rust environment/nice constraint, and always restarted three services · detect merged source, retain the historical fallback, source `/root/.cargo/env`, build at `nice -n15`, and support `RESTART_UNITS=0` · concrete values: source revision expected `73419e0`; relfix units are FreeDOS, MS-DOS/Win1, and QNX · doc-to-update: `streamhost/deploy/relfix/README.md`.
- [applied] · `streamhost/deploy/relfix/install-relfix.sh` · README required direct execution but the file mode was 0644 · install executable mode · concrete values: mode 0755 · doc-to-update: script header and `streamhost/deploy/relfix/README.md`.
- [applied] · `scripts/dev/verify-emit.sh` · verification assumed an unavailable second SSH hop and compared unpinned scratch launchers against pinned live launchers · add `--local` and `--pin-machine` · concrete values: byte parity passed both compared files for all 28 tiles; emitted launchers were 24 `pc-i440fx-11.0`, four `pc-q35-11.0`, zero floating aliases · doc-to-update: `docs/lab/MASTER-REPRODUCE.md` Phase 5.
- [applied] · `streamhost/streamhost/src/main.rs` · `--help` and `--version` fell through to a default QMP connection · add side-effect-free `-h/--help` and `-V/--version` handling · concrete values: bad fallback socket `/data/vms/streamhost/run951/qmp951.sock`; both CLI smokes now exit successfully · doc-to-update: `streamhost/README.md` Build.
- [applied] · `streamhost/deploy/streamhost@.service` and `streamhost/scripts/ensure-tile-qemu.sh` · `systemctl start` assumed a separately launched QEMU and the old scripts mirror was absent · add idempotent pidfile/QMP-aware `ExecStartPre`, use `KillMode=process` for pidfile-owned QEMU, and protect qcap on bridge tiles · concrete values: canary stop/start preserved QEMU PID 99986; service set installed/emitted 28 launchers and left all disabled/inactive before canary · doc-to-update: `docs/lab/MASTER-REPRODUCE.md` Phase 5 Tile lifecycle and `streamhost/README.md`.
- [applied] · `scripts/labctl` · absent Pillow and `pnmtopng` caused `labctl shot` to raise even though ffmpeg was installed · test converter availability safely and fall back to ffmpeg · concrete values: canary captures were 1024×768; `labctl ls` returned 28 rows · doc-to-update: script header and `docs/lab/MASTER-REPRODUCE.md` Phase 5 tooling.
- [applied] · `streamhost/tiles-manifest.sh` · emitted Win95/Win98 tile directories omitted tracked bake and QMP auxiliaries · add Win95 `drive.py`/`golden-bake.sh` and Win98 `golden-bake.sh`/`qmp.py`/`shot.sh`/`sk.py` as `--aux-file` entries · concrete values: all 28 emitted tiles subsequently passed parity · doc-to-update: `docs/lab/MASTER-REPRODUCE.md` Phase 5 tile emission.
- [proposed] · `scripts/build-guests/build-all.sh` · `--check-assets` reports preflight status and then continues directly into builds, so the documented later `nice -n15` build is redundant and the first build is unniced · add `--check-assets-only`/check-only exit, or have runbooks call `check-assets.sh` directly · concrete values: reproduced with `--only` for QNX-group tiles, Win95/98, Win2000, Android/postmarketOS/SerenityOS, and Solaris CDE · doc-to-update: script `--help`, `docs/lab/MASTER-REPRODUCE.md`, and `docs/lab/NVME-MIGRATION-PLAN.md` Phase 5.
- [proposed] · `streamhost/deploy/streamhost@.service` · `KillMode=process` stops streamhost but deliberately leaves its child QEMU and pidfile alive; five task agents independently hit the gap while replacing or validating goldens · add a reusable `ExecStop`/`ExecStopPost` helper that records the tile pid, sends TERM, waits boundedly, uses the same PID for KILL fallback, and removes only that tile’s pidfile/QMP socket · concrete values: leaked Win2000 PIDs 217312 and 535476; AmigaOS PID 119335; HelenOS and ReactOS also retained their QEMU/pidfiles; `systemctl stop` still returned 0 · doc-to-update: `docs/lab/MASTER-REPRODUCE.md` and `docs/lab/NVME-MIGRATION-PLAN.md` Phase 5 service-stop procedures plus `CLAUDE.md` launcher ownership.
- [proposed] · `scripts/labctl` · runbooks advertise `labctl click`, but the CLI returns `unknown subcommand`, and pointer modes differ · implement absolute, relative, and warpd-aware click dispatch · concrete values: QNX needed relative motion and its tile helper; Win95 fallback clicked Network Password OK at `(514,126)` with `drive.py`, while its first restart used focused Yes/Enter; relative coordinate `(272,324)` missed under acceleration · doc-to-update: `CLAUDE.md` Driving a guest and `docs/lab/MASTER-REPRODUCE.md` framebuffer-input helpers.
- [proposed] · `scripts/labctl` · `loadvm` returns before DBus framebuffer repaint settles, so first-frame tests produce false black/incomplete failures · add polling/stability gates rather than judging the first frame · concrete values: HelenOS ~15s, 9front ~20s, ReactOS 15s, AmigaOS ~30s, MS-DOS/Win1 ~22s, Win95 ≤5s, Win98 ~11s, Atari ST 15s, Apple II 30s, Amiga 30s; KolibriOS acceptance used 3s · doc-to-update: `docs/lab/MASTER-REPRODUCE.md` Phase 5 framebuffer reset verification and the affected guest docs.

## Serve / PKI

Recovered serve facts: the SPA build completed `tsc -b && vite build` with 734
modules, 44 MiB/53 files, and main JS 1,363.71 kB (417.39 kB gzip). The deploy
helper was bypassed because discovery of `~/.ssh/lab_key` skipped the required
`ssh lab` alias; equivalent deployment preserved `/boot/`. HTTPS `:8443` and
`signal/index.json` returned 200 with 28 entries. The temporary seven-day
self-signed leaf was replaced after recovering the CA key.

- [applied] · `docs/lab/NVME-MIGRATION-PLAN.md` · root PKI regeneration and trust-preserving carry were described as interchangeable · make matching `rootCA.key` plus `rootCA.pem` mandatory inventory/continuity items before leaf generation · concrete values: key recovered from `/mnt/poc/pocdata/vms/streamhost/serve/pki/rootCA.key`; CA SHA-256 fingerprint `FB:3C:D8:9F:DD:B1:A5:94:69:ED:BE:3B:7B:5C:3A:9A:5A:9B:44:A6:28:4F:B5:BC:7F:7A:CC:79:3D:8B:DA:0A` · doc-to-update: sections 3, 5, and Phase 5 Serve.
- [applied] · `docs/lab/MIGRATION-MAC-RUNBOOK.md` · secrets sync did not prove the CA private key survived · require `rootCA.key` mode 600 and public-key match to `rootCA.pem` before shutdown · concrete values: PEM mode 644; derived public-key SHA-256 values matched · doc-to-update: Preconditions step 3.
- [applied] · `docs/REPRODUCE-QUICKSTART.md` · PKI was called regenerable without separating root trust from replaceable leaf/token material · require carrying the root pair; allow only leaf and token regeneration · concrete values: `clientcmd.token` was reminted but not printed · doc-to-update: secrets inventory.
- [applied] · `docs/lab/MASTER-REPRODUCE.md` · Phase 5 omitted private-key restoration · restore and verify the pair before signing a new leaf · concrete values: issued leaf issuer `O=KernelHive Local CA, CN=KernelHive Local CA`, expiry `Jul 15 00:46:23 2027 GMT`, served verification `ssl_verify_result=0` · doc-to-update: Phase 5 Serve plane.
- [applied] · `scripts/serve/README.md` · README recommended regenerating all PKI after a rebuild · document secure gitignored root-pair carry, key mode 600, digest verification, and leaf-only regeneration · concrete values: webroot `/data/vms/streamhost/serve/webroot`, HTTPS port 8443 · doc-to-update: Secrets.
- [applied] · `CLAUDE.md` · guardrails named only the PKI directory, not the trust-continuity pair · explicitly identify `rootCA.key` and `rootCA.pem` · concrete values: both are gitignored secrets/carry items; key mode 600 · doc-to-update: Hard guardrails/secrets list.
- [applied] · `scripts/serve/gen-local-ca.sh` · header incorrectly claimed the CA key never leaves the host PKI and defaulted leaves to 825 days despite the one-year target · document secure carry and change `DAYS_LEAF` default to 365 · concrete values: old 825 days, new 365 days; recovered leaf was valid through 2027-07-15 · doc-to-update: script header.

## Per-guest deltas (build order)

### 1. KolibriOS (`kolibrios`)

- [applied] · `scripts/build-guests/kolibrios.sh` · `FORCE=1` was overwritten and success was reported without `state.qcow2`/`golden` · honor `FORCE`, stage/run the vendored bake, require `golden`, and refresh labctl state · concrete values: source `https://builds.kolibrios.org/en_US/latest-iso.7z`; rebuilt ISO SHA-256 `90b0fcfae1e9661fa428099bd82a1a839291deaa3c4c13c13d209a10cf7a169a`; runtime `pc-i440fx-11.0`; signal UDP port 54097 · doc-to-update: `docs/guests/kolibrios.md` Build and `docs/lab/MASTER-REPRODUCE.md` Phase 4/5.
- [applied] · `streamhost/tiles/kolibrios/golden-bake.sh` · fixed four-second timing and stale GUI calibration captured a 720×400 boot screen and opened stray KFM windows · poll up to 30s for 1024×768, at least eight sampled colors and mean brightness >8, settle 2s, dirty through KFM2, prove reset deltas, and stop by pidfile; related setup/launcher changes pin the machine · concrete values: KFM2 click `(33,26)`, dirty delta ≥5%, restored delta ≤2%, `pc-i440fx-11.0` · doc-to-update: `docs/guests/kolibrios.md` Golden fixture/reset proof.
- [proposed] · `docs/guests/kolibrios.md` · reset screenshots can race repaint · specify a three-second post-`labctl reset kolibrios` delay · concrete values: 3s · doc-to-update: Reset verification.
- [proposed] · `docs/lab/MASTER-REPRODUCE.md` · fresh host lacked a 7z extractor · document the builder’s automatic `p7zip-full` install · concrete values: upstream media is `.7z` · doc-to-update: Phase 4 prerequisites.

### 2. ToaruOS (`toaruos`)

No tile-specific DELTA was reported; the rebuilt live ISO reached a 1920×1080 desktop.

### 3. HelenOS (`helenos`)

- [applied] · `scripts/build-guests/helenos.sh` · the old builder emitted only an ISO and used a generic verification profile, leaving a missing-golden failure that previously required rollback recovery · automate a fresh 128 MiB qcow2 bake, framebuffer gate, `savevm golden` verification, and atomic replacement with the exact production device set · concrete values: `pc-i440fx-11.0`, `qemu32`, 512 MiB, USB tablet, `intel-hda`/`hda-output`, 120s gate, desktop observed at VM clock 18.438s; historical recovered golden `/mnt/poc/pocdata/vms/streamhost/tiles/helenos/golden.qcow2` SHA-256 `b9a8947560c43d51c99f55a85314672c02d6f22a0b65f38f2d097e054cb5da1e` · doc-to-update: `docs/guests/helenos.md` Golden rebuild and `docs/lab/MASTER-REPRODUCE.md` Phase 5.
- [applied] · `streamhost/tiles/helenos/tile.env.fixture` · fixture described the idle prompt incorrectly · record the exact prompt · concrete values: `/ #`, not `/ # helenos` · doc-to-update: fixture header/golden description.

### 4. 9front (`9front`)

- [applied] · `scripts/build-guests/9front.sh` · fresh Debian lacked `mcopy` · make the preflight name/install the correct dependency · concrete values: Debian `mtools` 4.0.48-1 · doc-to-update: `docs/guests/ninefront.md` build-host dependencies.
- [proposed] · `scripts/build-guests/9front.sh` · builder creates the base qcow2 but not the production warpd agent or internal snapshot · automate agent injection and `savevm golden` with the production profile · concrete values: recovered source `/mnt/poc/pocdata/gallery-guests/9front/9front-11554.amd64.qcow2`, pre-launch SHA-256 `217ac139dd13c487943437fd8771f03e36eb64d7447c7e914181e24607b5c2f2`, `pc-q35-11.0`, two vCPUs · doc-to-update: `docs/guests/ninefront.md` Golden rebuild and `docs/lab/MASTER-REPRODUCE.md` Phase 5.

### 5. ReactOS (`reactos`)

- [applied] · `scripts/build-guests/reactos.sh` · `FORCE=1` was overwritten, the ISO-only path skipped fixture bake, and validation stopped before ISO-9660 `CD001` · honor `FORCE`/`VERIFY`, invoke the bake, and read through the complete signature · concrete values: `CD001` offsets 32769–32773 (`0x8001` start), `head -c 32774` · doc-to-update: script header and `docs/lab/MASTER-REPRODUCE.md` Phase 5 ReactOS.
- [applied] · `streamhost/tiles/reactos/golden-bake.sh` · no from-scratch fixture automation existed and an early 800×600 device-install frame could be mistaken for the wizard · add wizard/desktop gates, settings-floppy generation/ejection, customization, save/load/dirty proof with production devices · concrete values: Enter, wait 6s, Enter, wait 18s; Start `(30,587)` → Run `(80,484)`; taskbar `(500,587)` → End → Enter → five Tabs → Space → Enter; `pc-i440fx-11.0`, host CPU, 512 MiB, AC97, USB tablet · doc-to-update: `docs/guests/reactos.md` Golden bake.
- [applied] · `streamhost/tiles/reactos/drive.py` · bundled pointer down/up events were ignored · issue separate QMP absolute button requests with a held press · concrete values: 80 ms hold · doc-to-update: `docs/guests/reactos.md` GUI automation.
- [applied] · `streamhost/tiles/reactos/qemu-streamhost.sh` · runtime floated on `pc` and cold-booted instead of restoring the curated fixture · pin and start from `golden` · concrete values: `pc-i440fx-11.0`; fresh golden SHA-256 `534c6ba1cf27e362bb1f4412e06f10a455300b0b5c4fa233e7fbf4d33c8b0147`; old recovered reference `c625782254837817aa97c8d5ff392349320c949a446351f1f73abb1b393dd9e7`; dirty ROI `0.023877`, restored `0.000000` · doc-to-update: `docs/lab/MASTER-REPRODUCE.md` Runtime device parity.

### 6. Haiku (`haiku`)

No tile-specific source delta was reported. Its build depends on the shared guest
SSH key proposed in the host prerequisites; the live fixture was 1280×720.

### 7. TempleOS (`templeos`)

- [applied] · `streamhost/tiles/templeos/golden-bake.sh` · helper searched the runtime tile directory for `qmp.py`/`sk.py`, but the manifest did not deploy them · resolve safely quoted helper paths relative to the tracked script while retaining the runtime socket target · concrete values: `/data/vms/streamhost/tiles/templeos/qmp.sock`, 640×480 golden · doc-to-update: `docs/guests/templeos.md` Golden bake.

### 8. AmigaOS / AROS (`amigaos`)

- [applied] · `scripts/build-guests/amigaos.sh` · `FORCE=1` was overwritten, inputs followed `latest`, game failures were silent, and interrupted 429 MiB contrib downloads were discarded/unreliable · honor flags; persist validated/resumable `.cache`; retry from byte zero; pin both 20260701 inputs and fail unless the remaster hash matches · concrete values: boot URL `https://sourceforge.net/projects/aros/files/nightly2/20260701/Binaries/AROS-20260701-pc-i386-boot-iso.zip/download`, SHA-256 `b3b607580f14e6c58ad796fe7c96768c04c4542da3a9c2f19386781e7015a3ce`; contrib URL `https://sourceforge.net/projects/aros/files/nightly2/20260701/Binaries/AROS-20260701-pc-i386-contrib.tar.bz2/download`, SHA-256 `f574087ff62d9bb52024cee891f4e774aa6cefcd0ca805a63764a8dd4321e2c5`; final ISO SHA-256 `5aff10ed5ff1aec62ed9336db984725c31c61b20d3d4c285857dfc021d2b2488` · doc-to-update: `docs/lab/ASSETS-MANIFEST.md` AROS and `docs/guests/aros.md` inputs/cache.
- [applied] · `scripts/build-guests/amigaos.sh` · xorriso 1.5.6 copied checkout-time Rock Ridge timestamps and variable path lists were unterminated, preventing byte reproduction · normalize all recorded timestamps, terminate lists with `--`, and retain the xorriso error log · concrete values: assets `2026-07-06 16:41:57 +0300`, Games `16:54:28 +0300`, contrib atimes `13:19:52/56/57 UTC`, Games ctime `13:54:28 UTC` · doc-to-update: script header and `docs/lab/MASTER-REPRODUCE.md` Phase 4 AmigaOS.
- [applied] · `streamhost/tiles/amigaos/golden-bake.sh` · the normal path could not reproduce `golden-scratch.qcow2` and depended on rollback · create a fresh no-backing disk, gate Wanderer/Shell, save and self-test `golden` · concrete values: 1 GiB disk; 512 MiB RAM; one CPU; std VGA; IDE index 0; AC97; `pc-i440fx-11.0`; Wanderer gate ≤120s; Right-Amiga+E, type `newshell`, Enter, Shell gate 20s; new SHA-256 `3a3bdd014e4be4eb6710f3fb975533ac1161b72840702da8efc73c2fb4a503e4`; old recovered scratch `fe8488013913047ccaed83218a8d485d91dc31bd32aa70f8afc9d4ac6916d14b` · doc-to-update: `docs/guests/aros.md` Golden bake and `docs/lab/MASTER-REPRODUCE.md` Phase 5.
- [applied] · `streamhost/tiles/amigaos/qemu-streamhost.sh` · runtime used moving alias `pc` · pin the snapshot-compatible device set · concrete values: `pc-i440fx-11.0`; reset restored the 1024×768 Shell at `6.RAM Disk:>` · doc-to-update: `docs/guests/aros.md` Runtime/device set.

### 9. QNX (`qnx`)

- [applied] · `scripts/build-guests/qnx.sh` · a successful verify returned the status of `[ "$KEEP" = 1 ]`, producing a false “verify skipped” message · replace the `&&`/`||` chain with explicit `if` control flow · concrete values: QNX 6.5 Photon live image, 640×480 · doc-to-update: script header/verify flow.
- [applied] · `streamhost/tiles/qnx/qemu-streamhost.sh` and `streamhost/tiles/qnx/golden-bake.sh` · launcher required a nonexistent golden disk, never created it, and lacked a production-device bake helper · create a 2 GiB IDE scratch disk, conditionally `-loadvm golden`, and add the proven cold-bake sequence · concrete values: wait 75s, F2 once, wait 50s, move from top-left PS/2 origin in 10 px steps, click Exit `(487,361)`, wait 7s, enter `root` with empty password, wait 18s, save; `pc-i440fx-11.0` · doc-to-update: `docs/guests/qnx.md` Cold production golden and `docs/lab/MASTER-REPRODUCE.md` Phase 5.

### 10. Alpine (`alpine`)

- [applied] · `streamhost/tiles/alpine/qemu-streamhost.sh` · launcher created an empty runtime state disk instead of consuming the builder’s tested golden · seed a missing runtime disk once from the builder output and then preserve it · concrete values: source `https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-standard-3.24.1-x86_64.iso`, SHA-256 `f4dd613206676c62949144c8ad75fc64582099f444dd1485bae104a60f51dd26`, seed `/data/gallery-guests/Alpine/state.qcow2`, desktop 1280×800 · doc-to-update: `docs/guests/alpine.md` Production wiring.

### 11. Tiny Core (`tinycore`)

- [applied] · `streamhost/tiles/tinycore/qemu-streamhost.sh` · launcher created empty state and still described release 15.x · seed once from the builder’s golden and update to 17.x · concrete values: `https://distro.ibiblio.org/tinycorelinux/17.x/x86/release/TinyCore-17.0.iso`, MD5 `6f6eec3518c70b394ef3c41711b1fe6d`, seed `/data/gallery-guests/TinyCore/state.qcow2`, desktop 1024×768 · doc-to-update: `docs/guests/tinycore.md` Release and production wiring.

### 12. FreeDOS (`freedos`)

- [applied] · `scripts/build-guests/freedos.sh` · Wolf3D extraction failed after downloads because `id-shr-extract` was undeclared · check the tool before work and name its Debian provider · concrete values: `dynamite` 0.1.1-2+b4 · doc-to-update: `docs/lab/MASTER-REPRODUCE.md` host dependencies.
- [applied] · `streamhost/tiles/freedos/qemu-streamhost.sh` · unconditional `-loadvm golden` made a fresh artifact exit before its pidfile · cold-boot when no tag exists, then load after bake · concrete values: FreeDOS 1.3 “RETRO GAMES” fixture · doc-to-update: `docs/guests/freedos.md` Rebuild/golden bake.
- [proposed] · `scripts/build-guests/freedos.sh` · documented Arachne mouse moves were unreliable with pinned QEMU · encode the recovered relative/HMP sequence · concrete values: QMP relative `(100,100)` toward lower right, HMP `mouse_move -40 -16` to about `(508,434)`, LMB down, 200 ms, LMB up; `Alt+X` returns to menu · doc-to-update: `docs/guests/freedos.md` One-time Arachne runtime click.

### 13. MS-DOS / Windows 1.01 (`msdos-win1`)

- [applied] · `scripts/build-guests/msdos-win1.sh` · assignment to Bash readonly `PPID` aborted provisioning · rename it consistently · concrete values: new variable `PROV_PIDFILE` · doc-to-update: script header/PITFALLS.
- [applied] · `scripts/build-guests/msdos-win1.sh` · the damaged single-floppy WIN10 tree omitted promoted SETVER/mouse fixes · validate and graft the genuine setup result, fixed `SETVER.EXE`, config entry, and launcher · concrete values: staged `disk_install2.qcow2` SHA-256 `cf7a75f0d61223ad594e33b6c55b7f457a1880f67f2c5699634440aa2a18071e`, size 8,716,288 bytes; write `DEVICE=C:\DOS\SETVER.EXE`; repoint `WIN.BAT` · doc-to-update: `docs/guests/msdos-win1.md` Rebuild Option B.
- [applied] · `scripts/build-guests/check-assets.sh` · shared preflight omitted the promoted licensed Windows 1.01 input · add a mandatory SHA-pinned row · concrete values: same SHA-256 and path `/data/gallery-guests/MSDOSWin1/.build-work/dl/disk_install2.qcow2` · doc-to-update: `docs/lab/ASSETS-MANIFEST.md` section 2.
- [proposed] · `scripts/build-guests/msdos-win1.sh` · build still consumes a derived SETUP result rather than automating all five Windows floppies · automate five-floppy SETUP and the Windows 2.03 mouse-driver graft · concrete values: recovered media hashes `e359f958…`, `c27d869a…`, `7aed3a1e…`, `81f7569d…`, `0d3d2024…`; Win2.03 `D2_Build.img` `f5f859e2…` · doc-to-update: `docs/lab/ASSETS-MANIFEST.md` and `docs/guests/msdos-win1.md`.
- [proposed] · `streamhost/tiles/msdoswin1/golden-bake.sh` · HMP showed an in-memory snapshot before it was durable; pidfile shutdown exposed it as absent · save, QMP quit, wait for the exact pidfile process, and require `qemu-img snapshot -l` to contain `golden` · concrete values: reset repaint ~22s · doc-to-update: `docs/guests/msdos-win1.md` Golden procedure.

### 14. Windows 3.11 (`win311`)

- [applied] · `scripts/build-guests/win311.sh` · builder emitted raw disks while the launcher required missing tile-local qcow2 fixtures · create both standalone fixture qcow2s under `nice -n15` and refuse overwrite while the pidfile owner lives · concrete values: two fixture disks; 640×480 Program Manager · doc-to-update: `docs/guests/win311.md` Rebuild.
- [applied] · `streamhost/tiles/win311/qemu-streamhost.sh` · KVM/x86_64 stalled at CPUIdle and TCG/x86_64 remained black · pin the verified i386/TCG profile and conditional golden load · concrete values: `qemu-system-i386 -accel tcg -machine pc-i440fx-11.0 -cpu pentium -vga cirrus` · doc-to-update: `docs/guests/win311.md` Launcher profile and `docs/lab/MASTER-REPRODUCE.md` Wave 2.

### 15. Windows 95 (`win95`)

- [applied] · `scripts/build-guests/win95.sh` · normal builds omitted the KVM artifact, verification dirtied persistent state, repeated blind Enter paused ScanDisk, and shutdown was unreliable · default `KVM_READY=1`, verify with `-snapshot`, delay wizard input, and use the proven keyboard shutdown · concrete values: waits 150/45/30/30s; shutdown `Ctrl+Esc`, Up, Enter, wait 3s, Enter, wait 45s; repaint ≤5s · doc-to-update: `docs/guests/win9x.md` Win95 KVM build and `docs/lab/MASTER-REPRODUCE.md` Phase 5.

### 16. Windows 98 SE (`win98` / `win98se`)

- [applied] · `scripts/build-guests/win98.sh` · builder produced `win98se.qcow2` while runtime required `win98se-kvm.qcow2`, and verification mislabeled a modal PnP frame as desktop success · create/preserve a reflink-capable production copy and report unsettled PnP honestly · concrete values: `/data/gallery-guests/Win98SE/win98se-kvm.qcow2`, 640×480 · doc-to-update: `docs/guests/win9x.md` Win98 paths.
- [applied] · `streamhost/tiles/win98se/golden-bake.sh` · four Tabs skipped past Show clock because focus began on Always on top · use three Tabs, Space, Enter · concrete values: final golden has no clock · doc-to-update: `docs/guests/win9x.md` Golden fixture.
- [applied] · `streamhost/tiles/win98se/shot.sh` · absent `pnmtopng` produced zero-byte checkpoints · use native QMP PNG `screendump` · concrete values: validated output 13,846 bytes · doc-to-update: script header and `docs/lab/MASTER-REPRODUCE.md` dependencies.
- [proposed] · `streamhost/tiles/win98se/pnp-settle.sh` · fresh Win98 requires a long PCI/IDE/VGA/USB/HID cascade rather than one click · encode the observed keyboard transcript with framebuffer checkpoints · concrete values: repeatedly search `C:\WINDOWS\OPTIONS\CABS`, perform two restarts, network-logon conversion, and Safe Mode cleanup · doc-to-update: `docs/guests/win9x.md` Exact one-time interaction transcript.
- [proposed] · `docs/guests/win9x.md` · immediate reset frames can contain a black/incompletely repainted Notepad region · document settled-screen timing · concrete values: Win98 about 11s; Win95 within 5s · doc-to-update: Golden reset verification notes.

### 17. Windows 2000 (`win2000`)

- [applied] · `scripts/build-guests/win2000.sh` · the VMware source used BusLogic SCSI and premature synthetic `Enum\ACPI\QEMU0002` creation regressed the correct MergeIDE image to STOP 0x7B · apply MBR/VBR/MergeIDE changes, perform one pinned IDE priming boot, verify natural QEMU0002 enumeration, then set `ConfigFlags=2` offline · concrete values: BusLogic PCI `104b:1040`; PIIX IDE `8086:7010`; MBR CHS `01 01 00 → 00 39 00`; NTFS sectors/track `56 → 63`; boot-start `pciide`, `atapi`, `intelide`; source/pristine SYSTEM and MBR matched recovered backups · doc-to-update: `docs/guests/win2000.md` SCSI-to-IDE transition.
- [applied] · `scripts/build-guests/win2000.sh` · builder ignored canonical staged cache names · align destinations · concrete values: `duke3d_sw.zip`, `quake_msdos.zip` · doc-to-update: `docs/lab/ASSETS-MANIFEST.md` Win2000 caches.
- [applied] · `scripts/build-guests/win2000.sh` · verifier floated on `pc`, used Pentium III/std VGA, did not reliably honor `FORCE`, and could save a bad snapshot before validation · honor controls, use the exact live profile, validate framebuffer before save, and require the tag · concrete values: `pc-i440fx-11.0`, host CPU, Cirrus, AC97; forced build 277s; golden 214 MiB; clean framebuffer SHA-256 `2ea5c67a…5b5dd87`; reset repaint 15s · doc-to-update: script header and `docs/guests/win2000.md` Verifier.
- [applied] · `scripts/build-guests/win2000.sh` · `find … | head -n1` failed under `set -o pipefail` after priming · use `find … -print -quit` · concrete values: failure occurred after the required IDE priming boot · doc-to-update: script header/rebuild pitfalls.
- [applied] · `scripts/build-guests/win2000.sh` · final QMP quit left a dirty active NTFS layer · automate Windows shutdown with a pidfile-scoped timeout fallback · concrete values: `Ctrl+Esc`, `U`, wait 3s, Enter · doc-to-update: `docs/guests/win2000.md` Golden bake.
- [proposed] · `scripts/build-guests/win2000.sh` · era-software URLs failed/rotted and lack validated SHA-256 pins · replace or restage each with verified mirrors and hashes · concrete values: `https://archive.org/download/winamp2.95/winamp295.exe`, `https://archive.org/download/grandtheftauto1997rockstargames/GTAINSTALLER.exe`, `https://archive.org/download/DoomsharewareEpisode/doom19s.zip`, and `https://archive.org/download/QuakeShareware_201802/quake106.zip`; later fixup reconfirmed the first three as rotted · doc-to-update: `docs/lab/ASSETS-MANIFEST.md` Win2000 optional software.
- [proposed] · `scripts/build-guests/win2000.sh` · checker requires `wolf3dsw.zip`, but the builder consumes no such row · add a hash-checked injection or remove the stale requirement · concrete values: staged name `wolf3dsw.zip` · doc-to-update: `docs/lab/ASSETS-MANIFEST.md` Win2000 cache.
- [proposed] · `streamhost/tiles/win2000/qemu-streamhost.sh` · cold start performs lengthy WinWorld NTFS index cleanup and can be paused by the 60-second idle gate · conditionally start with `-loadvm golden` while retaining an explicit recording cold path · concrete values: 60s idle gate; proven golden immediately restores the 640×480 desktop · doc-to-update: `docs/guests/win2000.md` Startup semantics.

### 18. OS/2 Warp (`os2warp`)

- [applied] · `streamhost/guest-agents/os2/warpd_os2.c` and OS/2 registry runtime · `P` posted an immediate down+up, `R` was ignored, held motion/capture and client coordinates were absent, and `WinSetPointerPos` left the native PS/2 button position stale · keep corrected synthetic P/R/double-click fallback, mirror every warp with `MouSetPtrPos`, route buttons through QEMU PS/2 with an 80ms ordering guard, and route wheel separately to agent `B 4/5` · concrete values: `SH_WARPD_BUTTONS=qemu`, `SH_WARPD_BUTTON_DELAY_MS=80`, `SH_WARPD_WHEEL=agent`; exact agent SHA-256 `3e5378db27b68bfaaf3fde1f4f5a20b0937b9078cd8d31d9b044768209920f33`; clone and live framebuffer passed Game/View menus, Mahjongg tile selection, and bottom-border resize · doc-to-update: `docs/guests/os2warp.md` Full mouse.
- [applied] · `scripts/build-guests/os2warp.sh` · re-baking directly from the qcow2 active layer cold-booted into `CLOCK01.SYS failed to install` even though the internal `golden` disk state was valid · apply the existing internal snapshot's disk state before offline agent injection and cold boot · concrete values: `qemu-img snapshot -a golden /data/gallery-guests/OS2Warp/os2.qcow2`; recovered desktop at 108s; new snapshot timestamp `2026-07-16 03:00:09 EEST`; rollback `/data/gallery-guests/OS2Warp/os2.qcow2.pre-mouse-20260716T2352Z`, SHA-256 `4a6385ee84e2b672a086fc438dc12289dfda68639f3dcfb2b347ba6e2c266cdc` · doc-to-update: OS/2 rebuild pitfalls.
- [applied] · `scripts/build-guests/os2warp.sh` · Pillow-less verification wrote PPM but reported a nonexistent PNG · retain and report the actual fallback path · concrete values: production desktop repainted ~15s after `loadvm golden` · doc-to-update: script header/verification output.
- [proposed] · `docs/lab/ASSETS-MANIFEST.md` · checker did not document the recovered OS/2 staging input · add its source, size, digest, and snapshot · concrete values: `/data/assets-staging/OS2Warp/os2.qcow2`, 501,809,152 bytes, SHA-256 `2b166b8d75912feb189945ee77480b2889f3c2554ca16fdf39e432e6656653bc`, internal snapshot `golden` · doc-to-update: OS/2 Warp row.
- [applied] · `streamhost/tiles/os2warp/qemu-streamhost.sh` · the formerly premature `WARPD.EXE` bake claim is now verified · retain it and point the guest documentation at the full-mouse proof and rollback · concrete values: new internal `golden` saved `2026-07-16 03:00:09 EEST`; live `loadvm golden` framebuffer clean and `streamhost@os2warp` active · doc-to-update: `docs/guests/os2warp.md` Golden/rollback.

### 19. Android-x86 (`android-x86` / service `android`)

- [applied] · `scripts/build-guests/android-x86.sh` · fresh host lacked `pnmtopng`, and the script did not preflight `flock` · install/check the right packages and identify them in errors · concrete values: Debian package `netpbm`; exclusive lock `/run/gallery-android.lock` · doc-to-update: `docs/guests/android-x86.md` prerequisites and `docs/lab/MASTER-REPRODUCE.md` Phase 5 packages.
- [applied] · `scripts/build-guests/android-x86.sh` · installer keystrokes no longer matched Android-x86 9.0-r2 · encode the observed GRUB/MBR/cfdisk/ext4 flow and remove the nonexistent EFI prompt · concrete values: GRUB `down down ret`; MBR `ret`; cfdisk 2.14 `right ret`, `ret`, `ret`, `ret`, `left ret`, type `yes`, five rights, `ret`; partition `ret`; ext4 `down ret` · doc-to-update: `docs/guests/android-x86.md` Installation automation.
- [applied] · `scripts/build-guests/android-x86.sh` · SetupWizard coordinates were stale and its flow repeats · encode both passes and Quickstep selection · concrete values: START `(630,432)`; Wi-Fi SKIP `(231,617)`; CONTINUE `(696,486)`; date NEXT `(768,616)`; services MORE `(784,616)`; ACCEPT `(784,616)`; Not now `(512,502)`; SKIP ANYWAY `(716,423)`; wait 150s; repeat seven post-START actions; Quickstep `(512,573)`, ALWAYS `(703,688)` · doc-to-update: `docs/guests/android-x86.md` One-time GUI calibration.
- [applied] · `scripts/build-guests/android-x86.sh` · disconnected builders could share/overwrite QEMU runtime files · serialize with `flock` · concrete values: `/run/gallery-android.lock` · doc-to-update: script header and rebuild safety.
- [applied] · `streamhost/tiles/android/qemu-streamhost.sh` · a fresh disk lacked `golden`, so unconditional restore blocked cold boot; machine type floated on `q35` · load conditionally and pin · concrete values: `pc-q35-11.0`, 8 GiB disk · doc-to-update: `docs/guests/android-x86.md` Fixture creation/device set.
- [proposed] · `docs/guests/android-x86.md` · source/runtime mapping is implicit · record the exact source, digest, disk, and differing keys · concrete values: `https://sourceforge.net/projects/android-x86/files/Release%209.0/android-x86-9.0-r2.iso/download`, SHA-256 `91cedb534ba095a0c9b3eceede4147967fd27beea9bba640776f787dc3555021`, 8 GiB, build key `android-x86`, service key `android` · doc-to-update: Source media/runtime mapping.

### 20. postmarketOS (`postmarketos`)

- [applied] · `scripts/build-guests/postmarketos-fixture.sh` · idempotent rebuild inherited stale disk and OVMF `golden` tags, causing PIN `147147` to be typed into Console · delete both tags before declared cold boot, then save a coordinated fresh snapshot after unlock · concrete values: PIN `147147`; coordinated data/OVMF snapshots · doc-to-update: `docs/guests/postmarketos.md` Golden fixture/idempotency.
- [applied] · `streamhost/tiles/postmarketos/qemu-streamhost.sh` · repo launcher floated on `q35` while production was pinned · pin it · concrete values: `pc-q35-11.0` · doc-to-update: `docs/guests/postmarketos.md` Device set.
- [proposed] · `docs/guests/postmarketos.md` · exact image and timing were not pinned in prose · record them and the idle-blanking wakeup · concrete values: `https://images.postmarketos.org/bpo/v26.06/generic-x86_64/phosh/20260703-0246/20260703-0246-postmarketOS-v26.06-phosh-29.1-generic-x86_64-lts.img.xz`, SHA-256 `d309146674f9a2979eb54c5f8090192beb021fa00d7b9487938b583e00e23243`, PIN `147147`, first boot 120s, settle 30s, `labctl key postmarketos ctrl` before screenshots · doc-to-update: Image provenance/framebuffer verification.

### 21. SailfishOS (`sailfishos`; two build stages)

No tile-specific DELTA was reported in this wave. The emit task installed
`seriald-sailfishos.service`; SDK emulator media remains the staged prerequisite.

### 22. SerenityOS (`serenityos`)

- [applied] · `scripts/build-guests/serenityos.sh` · pinned Proxmox template 13.1-2 disappeared · select the available trixie template · concrete values: old `debian-13-standard_13.1-2_amd64.tar.zst`, new `debian-13-standard_13.6-1_amd64.tar.zst` · doc-to-update: `docs/guests/serenityos.md` and `docs/lab/MASTER-REPRODUCE.md` Phase 5.
- [applied] · `streamhost/tiles/serenityos/qemu-streamhost.sh` · launcher floated on `q35` · pin production shape · concrete values: `pc-q35-11.0` · doc-to-update: `docs/guests/serenityos.md` Runtime device set.
- [proposed] · `docs/guests/serenityos.md` · reproducible build facts and benign failures were absent · record the exact toolchain/container/run · concrete values: source `55c5f6336d074a8fa2402fc897e859a9b7458ceb`; Debian 13.6-1 CT112; 16 cores, 32,768 MiB, 25 GiB; GCC 16.1; binutils 2.46; `nice -n15`; 2,248s; benign Jakt `Operation not permitted (errno=1)`; `https://uefi.org/uefi-pnp-export` returned 403 and built-in Web Archive fallback succeeded · doc-to-update: Build expectations/troubleshooting.

### 23. Bridge base prerequisite (`bridge-base`)

- [applied] · `scripts/build-guests/bridge-base.sh` · backticks in an unquoted cloud-init heredoc executed comment text on the host · escape the backticked phrases · concrete values: accidentally executed words were `cloud` and `mame apple2e` · doc-to-update: script header/bridge-base provisioning notes.

### 24. Commodore 64 (`c64`)

No tile-specific DELTA was reported; GEOS 2.0 had an internal `golden` and reset cleanly.

### 25. Atari ST (`atarist`)

- [proposed] · `docs/guests/atarist.md` · immediate post-load frames can be black while repainting · document the observed settle · concrete values: 15s · doc-to-update: Reset verification.

### 26. Apple II (`apple2`)

- [proposed] · `docs/guests/apple2.md` · bridge-base provisioning reported `linapple=no` without explaining the recovery path · document that the overlay’s scripted source-build fallback repairs LinApple and that bridge-base must precede it · concrete values: build order `bridge-base` then `apple2` · doc-to-update: Build prerequisites/fallback.
- [proposed] · `docs/guests/apple2.md` · immediate post-load frames can be black · document repaint time · concrete values: 30s · doc-to-update: Reset verification.

### 27. Amiga bridge tile (`amiga`)

- [proposed] · `docs/guests/amiga.md` · immediate post-load frames can be black · document repaint time · concrete values: 30s · doc-to-update: Reset verification.

### 28. Windows XP (`winxp`)

No tile-specific DELTA was reported; licensed source media remains required.

### 29. Solaris 10 CDE (`solaris-cde`)

- [applied] · `scripts/build-guests/solaris-cde.sh` · old automation stopped after one key and never attached nominal JumpStart answers · encode the complete Solaris 10 U11 install with framebuffer-gated completion · concrete values: Space-select radio buttons; Networked=No; manual reboot; UFS; End User System Support; full-disk Solaris fdisk; `INSTALL_TIMEOUT=3600`; `INSTALL_DARK_SAMPLES=20` at 30s each · doc-to-update: `docs/guests/solaris.md` From-scratch installation.
- [applied] · `scripts/build-guests/solaris-cde.sh` · first root login showed undocumented JDS/CDE chooser and CDE deprecation dialog · persist CDE and suppress the notice with idempotence stamps · concrete values: chooser `Tab Down Space Tab Enter`; notice `Shift-Tab Space Tab Enter`; `DTLOGIN_WAIT=150`; `CDE_WAIT=120` · doc-to-update: `docs/guests/solaris.md` First-login calibration.
- [applied] · `scripts/build-guests/solaris-cde.sh` · a 30s ACPI wait interrupted boot-archive refresh and produced maintenance mode · repair/update archive during bake and wait longer for shutdown · concrete values: `bootadm update-archive`; `SHUTDOWN_WAIT=180` · doc-to-update: `docs/guests/solaris.md` Writable bake/clean shutdown.
- [applied] · `scripts/build-guests/solaris-cde.sh` and `streamhost/tiles/solariscde/qemu-streamhost.sh` · builder/runtime used moving `pc` · pin both sides · concrete values: `pc-i440fx-11.0` · doc-to-update: `docs/guests/solaris.md` QEMU device shape.
- [proposed] · `docs/lab/ASSETS-MANIFEST.md` · canonical media was absent from the documented staging flow · record the recovered copy · concrete values: `/data/assets-staging/SolarisCDE/sol10.iso` → `/data/gallery-guests/SolarisCDE/sol10.iso`, 2,254,110,720 bytes, SHA-256 `e8b86de15de374f93d356a6cc4c73952a365294fe82aa0f278cd028054ad57ea` · doc-to-update: Solaris CDE row.
- [proposed] · `docs/lab/MASTER-REPRODUCE.md` · emitted tile lacked the Solaris golden disk/helper/fixture set, causing QMP refusal · document distribution and the calibrated bake · concrete values: `solariscde-golden.qcow2`, `golden-bake.sh`, `drive.py`, fixture files; run `nice -n15 golden-bake.sh`; Start Over `(1104,747)`, username `(960,651)`, terminal `(500,400)`, park `(1350,650)`; snapshot 693 MiB and byte-identical after `loadvm` · doc-to-update: Phase 5 Solaris golden.

## Still open / proposed

The remaining action list, de-duplicated from the entries above, is:

1. Preserve box-checkout Git provenance (or an explicit verified revision record), and restore the clobbered Phase 3 nested Cargo path from `harvest-wave1`.
2. Generate/document the shared Haiku/Alpine/TinyCore SSH identity.
3. Give `build-all.sh --check-assets` a check-only mode or change the runbooks to call `check-assets.sh` directly.
4. Close the recurring `KillMode=process` service-stop gap with a pidfile-owned bounded `ExecStop` helper.
5. Add pointer-mode-aware `labctl click` and repaint-stability polling with the recorded per-guest waits.
6. Document KolibriOS’s 3s reset settle and automatic `p7zip-full` prerequisite.
7. Automate 9front warpd injection and its internal golden.
8. Encode the recovered FreeDOS/Arachne mouse sequence.
9. Replace MS-DOS/Win1’s derived input with five-floppy SETUP and make snapshot durability explicit.
10. Encode Win98’s PnP cascade and document Win95/98 repaint timing.
11. Replace/hash-pin the rotted Win2000 URLs, reconcile the unused Wolf3D asset, and decide cold-start versus golden-start semantics.
12. Document OS/2 recovered staging provenance.
13. Add exact Android, postmarketOS, and SerenityOS provenance/timing/toolchain facts to their guest docs.
14. Document Atari/Apple/Amiga repaint waits and Apple II’s LinApple fallback.
15. Add recovered Solaris media and golden-helper/calibration facts to the manifest/runbook.

## Concurrent-clobber audit

`docs/lab/MASTER-REPRODUCE.md` in the final box union retained the Phase 5 PKI,
rustfmt, and emit-verifier edits, but lost the expected Phase 3 nested
`streamhost/streamhost` build/install correction previously reconciled by
`harvest-wave1`. `CLAUDE.md` retained its expected root-CA trust-continuity edit;
no CLAUDE.md clobber was detected.

## Atari ST curated applications follow-up (2026-07-15/16)

- [applied] · `scripts/build-guests/atarist.sh` · the launcher attached no Atari
  storage, leaving a bare GEM desktop, and the application payload was not
  reproducible · download five pinned original archives, verify their SHA-256,
  assemble a GEMDOS C: folder, write CRLF `EMUDESK.INF` shortcuts/F1-F4 bindings,
  transfer it to `/opt/bridge/media/atarist-apps`, and add Hatari
  `--harddrive ... --gemdos-drive C --protect-hd off` · concrete values and
  provenance: `docs/guests/atarist.md` License and GEMDOS application-drive sections.
- [applied] · `docs/guests/atarist.md` · the old note explicitly said no HDD/apps
  and lacked redistributability evidence, clone/live framebuffer proof, and a
  rollback · record AIM 3.1 (PD package), Ballerburg (author-released PD), Pacman
  for GEM 0.2.5 (freeware), GEMBench 4.03 (shareware), URLs/hashes, proof paths,
  new 583 MiB golden, and backup
  `/data/vms/streamhost/backups/atarist-apps-20260715T234437Z/overlay.qcow2` ·
  doc-to-update: this guest document (completed).
- [applied] · `/data/vms/streamhost/tiles/atarist/ROLLBACK.md` · the generic
  stop/start instructions did not identify a last-known-good overlay · add the
  exact pre-change backup path, SHA-256, former golden metadata, pidfile-safe
  restore commands, and framebuffer verification · doc-to-update: tile-local
  rollback document.
- [applied] · Atari ST acceptance procedure · Hatari's absolute tablet coordinates
  were not a reliable way to exercise EmuDesk shortcuts, while immediate Pacman
  frames can be mid-repaint · bind F1-F4 in `EMUDESK.INF`, use F3 for acceptance,
  and wait 6s before the final app screendump · concrete values: desktop SHA-256
  `106006ef99488c0a8983631094f74b24ac559ca83b736ff06e124cf6db6c2297`;
  final live Pacman framebuffer SHA-256
  `ee9ae8e8d7bed716aa02c8c4575ec3036c8114802371502155bbbc8d62590dd9` ·
  doc-to-update: `docs/guests/atarist.md` proof and launcher sections.
- [applied] · `scripts/build-guests/atarist.sh` · Bash expanded `dst` before
  same-statement `local name=$2` made `name` visible, producing `cache/.part` and
  an invalid same-file `mv` on an empty-cache test · declare URL/name/hash first,
  then derive `dst`/cookie in a second `local` statement · concrete value:
  failing path `/data/vms/soltest/atarist-apps-codex-0715/builder-repro/cache/.part` ·
  doc-to-update: builder implementation (completed).
- [applied] · Atari ST golden bake procedure · saving immediately after a guest
  `system_reset` captured a Linux boot-console state while the QMP display still
  exposed the previous stale GEM frame; an earlier bake made QEMU user-network
  SSH accept TCP but stall before its banner · require a fresh guest boot, confirm
  both live `hatari` process and newly rendered desktop, close guest SSH, wait 3s,
  then `savevm golden`; verify a service restart, guest SSH, F3 launch, and final
  `loadvm golden` · concrete values: final golden 583 MiB, dated 2026-07-16
  02:58:49; final desktop/app hashes
  `106006ef99488c0a8983631094f74b24ac559ca83b736ff06e124cf6db6c2297` and
  `ee9ae8e8d7bed716aa02c8c4575ec3036c8114802371502155bbbc8d62590dd9` ·
  doc-to-update: `docs/guests/atarist.md` live fixture/proof sections.
- [proposed] · `labctl reset` / QEMU slirp snapshot handling · direct in-process
  `loadvm golden` restores Atari ST framebuffer state correctly but can make the
  existing hostfwd TCP/5816 accept connections without completing an SSH banner;
  restarting `streamhost@atarist` creates fresh user networking, loads the same
  golden, retains desktop hash
  `106006ef99488c0a8983631094f74b24ac559ca83b736ff06e124cf6db6c2297`, and restores
  SSH · consider a bridge-tile reset path that restarts the pidfile-owned QEMU or
  explicitly reinitializes slirp · doc-to-update: `labctl` reset semantics and
  `docs/guests/atarist.md` caveat.

## Tile registry/source reconciliation follow-up (2026-07-16)

- [applied] · `registry/tiles/{aros,c64}.json` · canonical pointer declarations
  had crossed the promoted live device sets and blocked strict `labctl gen` ·
  declare AROS as absolute QEMU USB tablet and C64 as browser-absolute translated
  to tablet-free PS/2 relative motion, then regenerate without a live-value
  overlay · concrete values: AROS `SH_POINTER=abs`; C64 `SH_POINTER=rel`,
  `pc-i440fx-11.0,vmport=off`, COMM 1351 · doc-to-update:
  `docs/guests/{aros,c64}.md`.
- [applied] · 16 registry launcher-parity entries and their owned launcher
  sources · registry metadata still described the QEMU 11 versioned machine
  while the source device set used a floating or implicit alias · pin the source
  machine to the already-running/golden-compatible resolved type and remove the
  cutover exception · concrete values: 14 i440FX variants, C64 i440FX with
  `vmport=off`, and 9front `pc-q35-11.0`; zero entries remain
  `launcherParity.status=hand-managed` · doc-to-update: registry index
  (generated).
- [applied] · retained box build edits for OS/2, C64, Atari ST, AROS, 9front,
  QNX, and the Win311 failed high-resolution trial · the re-bake work had landed
  in the running goldens/build checkout but not current main · harvest the
  guest-agent, builder, cold-boot, launcher, registry, and guest-document source;
  keep Win311 at the proven 640×480 VGA fallback and QNX at 1024×768 Cirrus with
  relative PS/2 input · doc-to-update: the corresponding guest documents.
- [recorded] · Win2000 Ctrl+A report · the shared SPA/streamhost positional
  keyboard path already delivered ordered modifier press/release events and the
  box/source copies matched · no new product edit; this is fleet-wide behavior,
  not a Win2000-only patch · concrete proof from the isolated task: QEMU observed
  Ctrl press, A press/release, Ctrl release and Notepad selected all text ·
  doc-to-update: none.
- [recorded] · `scripts/build-guests/check-assets.sh` · no new mandatory staged
  input was introduced by this reconciliation · Atari ST applications are
  freely redistributable, SHA-256-pinned downloads retained by the tile builder,
  so the shared licensed/rot-prone staging checker remains unchanged ·
  doc-to-update: `docs/guests/atarist.md` provenance table.
- [overlap] · unpushed `codex/harvest-wave2` migration-reproducibility branch ·
  reconcile its older-base versions separately after this current-main tile
  harvest · overlapping files:
  `docs/lab/REBUILD-DELTAS-2026-07-15.md`,
  `scripts/build-guests/{9front,amigaos,os2warp,qnx,win311}.sh`,
  `streamhost/tiles-manifest.sh`,
  `streamhost/tiles/amigaos/{golden-bake.sh,qemu-streamhost.sh}`,
  `streamhost/tiles/freedos/qemu-streamhost.sh`,
  `streamhost/tiles/helenos/tile.env.fixture`, and
  `streamhost/tiles/qnx/{golden-bake.sh,qemu-streamhost.sh}`.

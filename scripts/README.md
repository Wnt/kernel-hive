# scripts/ — ops tooling index

Everything here drives the single-box Proxmox lab ("the box",
`ssh lab` → root@192.0.2.10). Most scripts are env-parameterized
(`LAB_HOST`, `LAB_SSH`, `GALLERY_URL`, …) with the lab defaults baked in.
For a tracked-files-only checkout, read
[`docs/REPRODUCE-QUICKSTART.md`](../docs/REPRODUCE-QUICKSTART.md) before running
these box-oriented tools.

## Box-sync pairs (byte-identical mandates)

These repo files have live copies on the box. **Edit the repo copy, then sync
in the same change** — never let them drift. Run `scripts/dev/verify-box-sync.sh`
to MD5-gate every expanded row plus the source, launcher, labctl-matrix, and
registry tree mirrors.

**This is a hard pre-push gate.** `.claude/hooks/pre-push-gate.sh` probes
`ssh lab` (4 s `ConnectTimeout`); if the box answers, any drift **blocks the
push**, and if it does not, the check skips with a message and never fails. It
is intentionally absent from `.github/workflows/quality.yml` — CI cannot reach
the box. See [`docs/lab/AGENT-CI-EXIT-RULE.md`](../docs/lab/AGENT-CI-EXIT-RULE.md).

Output and flags:

```sh
scripts/dev/verify-box-sync.sh            # only rows needing attention, grouped by kind
scripts/dev/verify-box-sync.sh --all      # every row, including MATCH
scripts/dev/verify-box-sync.sh --table    # TSV: status<TAB>label<TAB>repo_md5<TAB>box_md5
```

Rows are classified so the fix is obvious: `DIFFERS` (content), `MISSING_ON_BOX`
(in the repo, never deployed), `MISSING_IN_REPO` (box-only — stale or scratch;
delete it there, do not silently adopt it), `MISSING_BOTH` (the pair definition
itself is wrong). Direction of truth is **per row**: the repo is authoritative
for source, the box for generated/live artifacts.

**Placeholder awareness.** A few box copies are deployed with the operator's
real LAN address / public hostnames substituted in for the repo's scrubbed
placeholders (AGENTS.md, [`registry/README.md`](../registry/README.md)). Those
pairs are marked `scrub`: their box-side hash is computed **after** reversing
the substitution, with a `sed` program built from gitignored `registry/local.env`
and run **on the box** inside the same batched SSH session — real values never
reach a local file, an argv, or the output. Both sides are then canonicalised so
a bare `192.0.2.10` and the local.env-aware `${SH_HOST_IP:-192.0.2.10}` compare
equal. With no `registry/local.env` (a fresh public clone) those rows report
`UNCHECKED`, which does not fail the gate.

Not mirrored, by design: `registry/posters/**` (poster prose and image-candidate
research — SPA build inputs only), `registry/local.env` (operator-local), and the
tracked `streamhost/tiles/soltest-*/` launchers (clone scaffolds that run out of
`/data/vms/soltest/`, never out of `/data/vms/streamhost/tiles/`).

| repo file | box copy | sync note |
|-----------|----------|-----------|
| `scripts/labctl` | `/usr/local/bin/labctl` | scp + `chmod +x`; verify with md5sum |
| `scripts/lib/clone-guard.sh` | `/usr/local/bin/clone-guard` | **HARD clone safety guard** — every clone kill/stop/destructive-QMP MUST route through it; scp + `chmod +x`; verify with md5sum. See `docs/lab/clone-guard.md` |
| `scripts/lib/chroot-guard.sh` | `/usr/local/bin/chroot-guard` | **HARD chroot mount guard** — chroot/rootfs API mounts (`/proc`, `/sys`, `/dev`) are made recursively PRIVATE on creation and torn down only through it, so a teardown can never propagate out and unmount the host's `/dev/pts` (the 2026-08-10 "PTY allocation failed" incident). Repo scripts source it by relative path; the box copy serves ad-hoc use (`chroot-guard run-private bash`) and box-side script copies. scp + `chmod +x`; verify with md5sum. Proof: `tests/chroot-guard-selftest.sh` (root, on the box) |
| `scripts/lib/xvfb-alloc.sh` | `/usr/local/bin/xvfb-alloc` | **display allocator** — every rig that needs an Xvfb claims it through this (atomic, loud on collision, self-releasing); scp + `chmod +x`; verify with md5sum |
| `scripts/gen_tiles_json.py` | `/root/gen_tiles_json.py` | `labctl gen` execs the box copy; run `ssh lab 'labctl gen'` after sync |
| `scripts/tiles.json.sample` | `/data/vms/streamhost/tiles.json` | committed reference of the generated live labctl matrix |
| `scripts/serve/*` five code files¹ | `/data/vms/streamhost/serve/*` | `restart-https.sh` hardcodes the box path; after server/auth changes sync every changed file, verify byte identity, then restart HTTPS. Branch-only work is **NOT DEPLOYED** until that handoff is completed; `test-clientlog.sh` + `README.md` are repo-only. |
| `scripts/serve/*` two JSONs² | `/data/vms/streamhost/serve/*.json` | committed reference copies (signaling registry + golden manifest) |
| `scripts/vm-idle-watch.sh` | `/data/vms/streamhost/serve/vm-idle-watch.sh` | idle auto-pause watcher; installed 2026-08-09 (the pair had never been deployed) |
| `streamhost/guest-agents/solaris/cdrv.py`, `gexec.py` | `/root/cdrv.py`, `/root/gexec.py` | labctl shells out to the box copies |
| `streamhost/guest-agents/irix/irixexec.py` | `/root/irixexec.py` | `labctl exec irix` (`exec_kind: serial_e`) shells out to the box copy; speaks irixser/2 to `irixagent.pl` inside the guest over MAME's emulated serial line |
| `streamhost/guest-agents/irix/mctl.py` | `/root/mctl.py` | mamectl/1 line client for the MAME ctlsock module's `SH_MAMECTL_SOCK` unix socket (issue #45); `labctl mctl` and the socket-routed `type`/`sh`/`reset` shell out to the box copy |
| `scripts/qmp_hmp.py` | `/root/qmp_hmp.py` | HMP-via-QMP one-liner; labctl + build-guests + guest-agent docs shell out to the box copy |
| `scripts/shmshot.py` | `/root/shmshot.py` | screendump for `SH_CAPTURE=shm` tiles (irix): reads the framebuffer the emulator publishes into `SH_SHM_PATH` -> PPM; `labctl shot`/`assert` shell out to the box copy |
| `scripts/dev/mobile-netem.sh` | `/usr/local/bin/mobile-netem` | mobile-5G network emulation for streamhost traffic to CT950; scp + `chmod +x`; verify with md5sum |
| `scripts/coldboot/amiga-coldboot-watch.sh` | `/usr/local/bin/amiga-coldboot-watch.sh` | amiga cold-boot-on-visit watcher (unit: `streamhost/deploy/amiga-coldboot-watch.service`); in-kiosk halves `amiga-emu` + `amiga-launch-coldboot.sh` live in the amiga guest — installer `scripts/coldboot/install-amiga-coldboot.sh` |
| `streamhost/deploy/{streamhost@,amiga-coldboot-watch,seriald-sailfishos}.service` | `/etc/systemd/system/…` | the box's complete custom-unit set |
| `streamhost/tiles/sailfishos/seriald.py` | `/data/vms/streamhost/tiles/sailfishos/seriald.py` | serial mux the `seriald-sailfishos.service` unit runs |
| `streamhost/{Cargo.toml,Cargo.lock}` + `streamhost/streamhost/{Cargo.toml,src/}` | `/data/vms/streamhost/build/{Cargo.toml,Cargo.lock,streamhost/{Cargo.toml,src/}}` | exact workspace mirror used by `build-deploy.sh`; harvested as tree `src` |
| tracked `streamhost/tiles/*/qemu-streamhost.sh` | `/data/vms/streamhost/tiles/*/qemu-streamhost.sh` | verbatim launcher mirrors; generated launchers are gated separately by `verify-emit.sh` |
| `registry/` allowed source files (`README.md`, `*.json`, `*.in`; **not** `posters/`) | `/data/vms/streamhost/build/registry/` | registry tree union is checked with the same filter on both sides, so one-sided files report drift |

¹ `clientcmd.sh`, `gen-local-ca.sh`, `osgallery-https-server.py`, `reset-tile.sh`, `restart-https.sh`.
² `tiles.json`, `golden-manifest.json`.

## Top-level scripts

| script | purpose | runs on |
|--------|---------|---------|
| `labctl` | Unified box CLI for streamhost tiles: read-only `ls` / `health` / framebuffer `assert`, plus `exec` / `sh` / `shot` / `type` / `key` / `mctl` / `reset` / `clone` / `gen` (capability matrix `/data/vms/streamhost/tiles.json`). `type` / `key` / `sh` pace their QMP keystrokes with the tile's own `SH_KEY_MIN_HOLD_MS` / `SH_KEY_MIN_GAP_MS` (emulator tiles sample the keyboard once per emulated frame, so an unpaced burst is silently dropped), warn on stderr for an emulator-bridge tile that declares neither, and honour an optional per-tile `SH_KEY_MAP` guest-char→host-char remap; `type --verify` screendumps afterwards | box (**sync pair**) |
| `gen_tiles_json.py` | Builds the tiles.json capability matrix from `tile.env` + launchers + live HMP golden probe; invoked by `labctl gen` | box (**sync pair**) |
| `tiles.json.sample` | Committed reference of the live labctl capability matrix; harvested from `/data/vms/streamhost/tiles.json` | box (**sync pair**) |
| `shmshot.py` | Screendump a `SH_CAPTURE=shm` tile by reading the seqlocked framebuffer its emulator publishes (no QMP, no X server) -> PPM. Fails loudly where the old x11 path returned a valid all-black image | box (**sync pair**) |
| `serve-https-spa.sh` | One-shot HTTPS serving-plane bring-up: build SPA (`spa/`), deploy without replacing unrelated webroot content, mint local-CA cert, start HTTPS server. **`manifests` is NOT concurrency-safe — see below.** | workstation → box |

> **It is not only the `manifests` subcommand — `deploy` publishes implicitly.**
> `deploy` calls `publish_manifests` as part of its normal run, and it *also*
> replaces the live SPA **bundle** with the publishing worktree's build, so a
> sibling's compiled scene rows disappear from the deployed bundle until the
> next post-merge rebuild. Both clobbers happened on 2026-08-10 from a plain
> `deploy`, by an agent that had been told not to run `manifests`. **With
> parallel tile work in flight, treat `deploy` as equally forbidden.**
>
> **`serve-https-spa.sh manifests` wholesale-replaces all three serve manifests**
> (`tiles.json`, `gallery-manifest.json`, `golden-manifest.json`) from the
> publishing worktree, atomically. It therefore **deletes every tile another
> worktree published since yours was branched** — silently, and the tile simply
> vanishes from the gallery while its service stays `active`, which reads as a
> tile bug rather than a publish bug.
>
> Observed 2026-08-10: one agent published at 02:45, a second at 02:47, and the
> first agent's live tile disappeared from all three documents.
>
> **With parallel tile work in flight, do not run it.** Either write an additive
> merge that inserts/replaces only your own tile's row, or leave publishing to
> the integrator, who runs `make tile-registry-generate && serve-https-spa.sh
> manifests` **once** after the branches are merged. Related: `labctl gen` fails
> closed on a declared/live tile-set mismatch, so it cannot succeed until every
> in-flight tile's registry entry has landed — that is a merge-time step, not a
> per-agent one.
| `vm-idle-watch.sh` | Idle auto-pause/resume watcher for the tile QEMUs (the idle-CPU 80%→~1.4% fix) | box (**sync pair**) |
| `qmp_hmp.py` | Run one HMP command through a tile's QMP socket (savevm/loadvm/hostfwd_add …) | box (**sync pair**) |
| `tiles-registry.py new <id> --tier … --archetype … --slot auto` | Creates an inert candidate registry row plus tier builder, guest-doc, and coldboot-arm stubs; reserves UDP `54000+slot` and regenerates canonical outputs | workstation |
| `../streamhost/scripts/streamhost-tile.sh` | Emits one tile's `tile.env` / launcher / `ROLLBACK.md`. `SH_HOST_IP` defaults to the repo placeholder `192.0.2.10`; an operator's real address goes in gitignored `registry/local.env` (see `registry/local.env.example` and `registry/README.md`), never in a tracked file | box |

Bare-metal/Proxmox host provisioning one-shots live under [`provision/`](#directories) below (`provision/hw-acceptance.sh`, `provision/pve-zfs-pool.sh`, `provision/pve-macos-vm.sh`, `provision/pve-win11-vm.sh`, `provision/preserve-guest-images.sh`, `provision/build-pve-qemu-fastpoll.sh`, `provision/provision-dev-ct.sh`).

## Scene-v2 agent toolbox

Future scene-v2 briefs should use these wrappers instead of rebuilding raw
server, screenshot, Blender, crop, and montage command chains:

| tool | purpose |
|------|---------|
| `scripts/dev/scene-v2-server.sh start\|stop\|status <port>` | Task-owned Vite lifecycle with dependency/credentials bootstrap, health polling, pidfile-only process-group cleanup, and reserved-port protection. |
| `scripts/dev/scene-v2-shot.mjs <url> <out.png> [--w W --h H --patient]` | Retrying system-Chrome canvas capture with bounded load/app waits. |
| `scripts/dev/blender-review.sh <generator> <variant> [--textured] [--h H] [--port P]` | One-call generator export, dev-lineup capture, and centered crop. |
| `scripts/dev/tile-lifecycle-check.sh <tile>` | Asserts `systemctl stop streamhost@<tile>` leaves NOTHING behind — no process, no `qcap-*` scope — over five rounds incl. a stop landing mid-watchdog-probe and a `systemctl restart`. Point it at a throwaway instance of the template, never an exhibit. See [`docs/lab/tile-teardown-cgroups.md`](../docs/lab/tile-teardown-cgroups.md). |
| `scripts/dev/image-sheet.sh <out.png> <img...> [--labels]` | Validated, optionally labeled ImageMagick contact sheet. |

### Standing SceneV2 QA lap

Run the optional, box-capable polish gate after scene composition or model
placement changes:

```bash
npm --prefix tests/e2e-live run qa:lap
# Optional artifact location and denser rail sweep:
npm --prefix tests/e2e-live run qa:lap -- --out /tmp/my-qa-lap --samples 16
```

`tests/e2e-live/qa-lap.mjs` owns port 5238 through `scene-v2-server.sh`,
captures labeled rail contact sheets at 1600x1000 and 390x844, and captures
every registry decade plus a fixed five-model lineup sweep for human review.
Each timestamped run defaults under `/tmp/osgallery-qa-lap/` and emits
`qa-lap-verdict.json`; exit 0 means the lap completed and produced contact
sheets, any nonzero value means an incomplete lap.

## Directories

| dir | purpose |
|-----|---------|
| `build-guests/` | Per-guest golden-image builders (`tiles/<os>.sh`), the `build-all.sh` orchestrator (coverage follows the production entries in `registry/tiles/`; derive the current count with `python3 scripts/tiles-registry.py count`), `lib/bridge-base.sh` (shared emulator-bridge base for c64/atarist/apple2/amiga) and `assets/` payloads. The tree is one layer deep — `tiles/` (operator-facing per-tile builders, the names the registry's `build.rows[].value.script` carries), `stages/` (helpers a tile builder calls), `emulators/` (MAME/toolchain builds), `patches/` (the loose emulator patches), `irix/` (the IRIX subsystem), `lib/` (shared infrastructure) — documented in [`build-guests/README.md`](build-guests/README.md). Canonical MASTER-REPRODUCE Phase-4 path. The default run skips the WinXP and Solaris `licensed` class; a fresh default run still needs the external Sailfish SDK image. Note: `tiles/amiga.sh` = real Amiga 500 via FS-UAE bridge, `tiles/amigaos.sh` = native AROS x86 — two different tiles, not duplicates. Sailfish is a two-stage chain: `tiles/sailfishos.sh` (base golden) then `tiles/sailfishos-gui.sh` (bochs-drm KMS GUI patch — the live tile). `tiles/winxp.sh` requires `WINXP_PRODUCT_KEY` in the env. External-media preflight: `check-assets.sh` (or `build-all.sh --check-assets`) vs `docs/lab/ASSETS-MANIFEST.md`. **The IRIX tile's MAME binary is not a golden image and is built separately:** `irix/irix-mame-stack.sh` is the single authoritative ordered patch stack (order is load-bearing — the shm framebuffer patch does not apply before the Newport dirty-frame cache, and the RAM/DMA and PIT/quantum pairs are required pairs), sourced by both `emulators/build-mame-irix.sh` (lab box, Linux/x86-64, the reproducer for the shipped `sgi`) and `emulators/build-mame-macos.sh` (dev Mac). Never copy the list into a second script. |
| `dev/` | Scene-v2 agent toolbox (indexed above). `box-repo.sh [status\|sync\|init\|path] [--strict] [--fetch]` — **the canonical kernel-hive checkout ON the box, `/data/kernel-hive`**, and the gate that keeps it honest. Host-side builders (`scripts/build-guests/tiles/<os>.sh` and everything they source) must run from it, because CT950 has no `/data` mount and a hand-copy into a scratch dir has no version and goes stale in silence — `/data/vms/soltest/BUILD-gt40/gt40.sh` outlived the bookworm→trixie flip still pinned to the bookworm base. `/data` (473 G, ~451 G free) not `/` (32 G, ~15 G free); auth reuses the GitHub key already on the box, read in place, so no key material is generated or copied; updated only by an explicit `sync` (fast-forward `main`, **refused** if the tree is dirty — no timer, so a fetch cannot swap `build-guests/` out mid-bake). `status` prints path/branch/commit/dirty/behind-ahead; `--strict` fails on dirty, behind or ahead. Exits 3 when the box is unreachable. `build-deploy.sh` — repo→box Rust build/deploy with check/dry-run/restart controls. `harvest.sh` — dry-run-first, allowlisted box→repo source/launcher/labctl/serve/registry harvest with hard secret exclusions and a guarded commit. `verify-box-sync.sh` — read-only MD5 drift table/gate for documented live mirrors. `verify-emit.sh` — emits the registry-derived production roster into box `/tmp` and byte-diffs it against live tiles using an explicit justification whitelist. `tile-doctor.sh <osId> [--live]` — the "am I done?" check for one tile: registry validity, generated-file drift, poster prose + hero image, visitor-facing copy (no rig vocabulary, lineage a heritage, blurb present, memory in a unit it can express), the three hand-maintained SPA scene bindings the generator does not write, declared key pacing/keyboard map, and with `--live` the box side (service, labctl matrix, golden snapshot, and whether the knobs the registry declares are actually in the running process). Exits with the failure count. `mame-keymap.py <machine>` — derive a guest's keyboard translation from a MAME driver's PORT_CODE/PORT_CHAR pairs instead of inferring it from a mangled screenshot; emits a paste-ready registry `keyboard.charMap`. `verify-tile.sh <osId> [--restore]` — mechanical live acceptance (read-only unless restore is explicitly selected), with PASS/FAIL checks and an explicit human-residual list. See [`docs/lab/HARVEST-AND-LAND.md`](../docs/lab/HARVEST-AND-LAND.md). `bridge-suite-status.sh [--tile <id>] [--json] [--strict]` — audits the bookworm→trixie bridge migration: compares each tile's declared suite in `registry/bridge-suites.json` against the backing file its live disk actually records on the box (one batched read-only `ssh lab`), reporting OK/DRIFT/DETACHED/MISSING plus migration progress; exits 1 on drift, 3 when the box is unreachable. `migrate-tile.sh <tile> [--flip] [--dry-run] [--no-restart]` — the other half of that pair: it *performs* one tile's bookworm→trixie migration over `ssh lab`, end to end, so the 25 remaining tiles cost one invocation each instead of one agent each re-deriving [`docs/lab/BRIDGE-TRIXIE-MIGRATION.md`](../docs/lab/BRIDGE-TRIXIE-MIGRATION.md) §2. Preflight (refuses an already-`trixie` tile, a non-ledger tile, and `c64` — whose overlay is detached, so it needs a rebuild, not a rebase), a `labctl reset`+`shot` **golden** baseline, `mv` of the overlay to `overlay.qcow2.bookworm-bak` (never deleted — it is the rollback), both wave-1 traps handled (the stale `[127.0.0.1]:<port>` host key cleared from the builder's own derived `SSH_PORT`; the golden baked under the tile's own `qemu-streamhost.sh` when the builder only printed the commands), the staged `BRIDGE_SUITE=trixie <builder> --force` build polled with progress, then mechanical acceptance (backing file = trixie base, in-guest `/etc/bridge/suite`, AFTER shot) with **automatic rollback** on any failure. It never claims visual acceptance: it prints both PNGs and says a human must compare them. `--dry-run` prints every command against real box facts; `--flip` is the only thing it writes in the repo, and it prints the prose/regenerate work it deliberately leaves manual. Exits 1 rolled-back, 2 refusal, 3 box unreachable. `migrate-wave.sh [TILE…] | --wave <N> | --remaining [-j N] [--max-load F] [--allow-stopped] [--evidence DIR] [-n] [--json]` — runs `migrate-tile.sh` over a WAVE, which is what three parallel agents each hand-rolled on 2026-08-10: a concurrency cap, a box-load ceiling re-checked before every launch (four parallel builds once took the box from load 9 to 34 and starved a measurement), SERIALIZATION GROUPS so the MAME tiles never chroot into `/data/vms/soltest/trixie-chroot` two at a time (the failure that took the host's `/dev/pts` down) — declared in `registry/bridge-waves.json`, **re-derived from the builders**, and held by one `mkdir` claim under `/run/kh-claims/` ON THE BOX so it serializes across agents, never adopting a claim it did not create — and the per-tile verdict table (MIGRATED / ROLLED-BACK / REFUSED / NOT-ATTEMPTED, with the reason and the evidence paths) that used to be typed into the plan doc by hand. Preflight names the tiles it will not start rather than discovering them late: already-`trixie`, `c64`, a missing builder, and a tile whose `streamhost@` unit is **inactive** (four of the thirteen remaining are). A failed tile does not abort the wave — `migrate-tile.sh` already rolled it back — and the report says which tiles were never attempted and why. Like `migrate-tile.sh` it never claims visual acceptance; it collects both PNGs per tile and ends by naming who owes the compare. Exits 1 if any tile did not migrate, 2 if nothing was started, 3 box unreachable. `mobile-netem.sh` — box-side tc/netem rig emulating the user's mobile 5G+WireGuard path (+90 ms RTT, 40/29 Mbit, deep bufferbloat queue) for streamhost traffic to CT950 only (`ssh lab 'mobile-netem on|off|status'`, 4 h fail-safe auto-off). `os2-gengradd-hires.sh <prep|run|shot> <soltest-clone-dir>` — box-side reproduction of the os2warp 1024x768 fix: restores IBM's GRADD DLLs over a failed SNAP install, moves SNAP's `SVGADATA.PMI` stub aside, rewrites CONFIG.SYS to the GENGRADD chain (CRLF-safe), and launches the clone on `-vga std -global VGA.vgamem_mb=2` (the mode-count cap that stops GENPMI's 64-entry buffers overflowing). See [`docs/guests/os2warp.md`](../docs/guests/os2warp.md). |
| `build-guests/irix/irix-bench/` | The IRIX-tile speed rig. `irixbench.sh` boots a clone on the PRODUCTION binary/golden/flags (`-video none` + shm, `-sound none`, `-frameskip 6`, the shipped `irixagent.lua`), drives the login, and measures WITHIN-RUN windows under `perf stat`; `bench-agent.lua` loads the production agent verbatim and adds the emulated-time/wall-clock trace those windows are cut from; `bwin.py` reports `cycnorm%` with achieved GHz and foreign-CPU occupancy on the claimed core pair; `shmpng.py` renders the shm mapping to PNG (the shm path's screendump — there is no X server to grab); `blockrate.sh` reads the DRC's blocks-per-second off a running MAME with a tracepoint counter (never `strace -c`). On the correctness side, `verify-prodclone.sh` boots a candidate binary under the tile's EXACT production configuration (its launcher, its `tile.env`, both watchdogs, throttled) — the check that caught fastram being green in the rig and broken on the exhibit — and `rawrun.sh` bisects a production-only failure by adding or removing one MAME flag at a time. Rules: [`docs/lab/MEASUREMENT-METHODOLOGY.md`](../docs/lab/MEASUREMENT-METHODOLOGY.md); baseline: [`docs/lab/irix-baseline-2026-08-03.md`](../docs/lab/irix-baseline-2026-08-03.md); rig overview: [`build-guests/irix/irix-bench/README.md`](build-guests/irix/irix-bench/README.md). |
| `build-guests/irix/irix-criu/` | **CRIU instant restore for the IRIX tile — a working ~1.2 s reset (vs a 258–275 s cold boot), preserved but NOT shipped.** `ckpt.sh` is the bake/restore pair with every measured invariant written into it (the ZFS snapshot is taken inside criu's own freeze window; `fb.shm` and the image dir must live outside the rolled-back dataset; the watchdogs write to the command file and a one-byte size change fails the restore). `nsnet.sh` is the private-netns + veth network the procedure needs, re-appliable because criu re-creates the veth pair on every restore. `patchns.py` applies the four launcher deltas to a **copy** of the production `x11-runtime.sh`, asserting each anchor. `curs.py` is the cursor probe the restore clock stops on. Evidence, the required criu flags, three traps that pass a smoke test while broken, and why slirp4netns/pasta are dead ends: [`build-guests/irix/irix-criu/README.md`](build-guests/irix/irix-criu/README.md). |
| `build-guests/irix/irix-slowstate/` | Does the IRIX exhibit stay slow after a visitor has used a terminal? `slowrig.sh` boots a clone on the production binary/golden/flags plus one console getty line (`-ioc2:rs232b pty`), opens and closes a real `xwsh` scroll, and measures a WITHIN-RUN timeline of idle windows before and after it — each window twice, once for speed with nothing attached and once for a uprobe census of the guest's ASID changes and TLB writes (raw ELF offsets on the shipped binary; `perf probe` cannot resolve the C++ `::`). `swin.py` joins the two into one table, `pcrank.py` names the guest code behind a window from the guest symbol table, `slow-agent.lua` adds the gated guest-PC sampler on top of the irix-bench agent. Findings: [`docs/lab/irix-post-terminal-slow-state.md`](../docs/lab/irix-post-terminal-slow-state.md). |
| `provision/` | Bare-metal/Proxmox host provisioning, one-shot: `hw-acceptance.sh` (Supermicro CPU/RAM/NVMe/NIC acceptance battery), `pve-zfs-pool.sh` (ZFS pool + datasets + PVE storage), `pve-macos-vm.sh` / `pve-win11-vm.sh` (optional standalone guest recreation), `preserve-guest-images.sh` (zfs-send images to another box), `build-pve-qemu-fastpoll.sh` (rebuilds the patched `pve-qemu-kvm` .deb with the streamhost quilt series), `provision-dev-ct.sh` (recreate CT950, AUTHORED-FROM-DOCS/UNTESTED), plus the Phase-1 PXE/answer-file kit (`isoserver.py`, `mac-preflight.sh`, `*.tmpl`, `README.md`) and `pve-tiles/linux.sh` (proof-of-concept PVE-owned Linux tile). See `provision/README.md`. |
| `cloud-agents/` | **How an agent running outside the LAN gets `ssh lab`.** `install-box-endpoint.sh` (workstation → box: ships the `forwarder-agent` binary, reads the forwarder token off the VPS, runs the box-side installer), `box-endpoint-setup.sh` (box-side, idempotent: a loopback-only, key-only second sshd on `:2222` plus the dial-out tunnel unit that publishes it as `tunnel.example.com:10022` — no inbound port on the home WAN, and the LAN sshd is never touched), `jules-setup.sh` (the script Google Jules runs in its VM: `LAB_SSH_*` → `~/.ssh` + `Host lab`, then the quality-gate tooling), `check-tunnel.sh` (proves the whole path from outside, ending in a real `labctl ls`). Design, env-var list and revocation: [`docs/lab/CLOUD-AGENTS.md`](../docs/lab/CLOUD-AGENTS.md). |
| `serve/` | **Canonical** HTTPS SPA origin + signaling: `osgallery-https-server.py` (:8443), `gen-local-ca.sh` (local CA/leaf, `pki/` stays out of the repo), `restart-https.sh`, `reset-tile.sh` (golden reset used by e2e), `golden-manifest.json`, `tiles.json` (reference copy). See `serve/README.md`. **Box-sync dir.** |
| `coldboot/` | Boot-video record/trim/postprocess toolkit (`record-boot.sh`, `trim-boot.sh`, `postprocess-boot.sh`, `gen-boot-manifest.sh`, per-tile zero-input prep notes) — feeds the SPA's boot-replay plane, live since 2026-07-13 (8 tiles published). Also the amiga cold-boot-on-visit lifecycle (`amiga-coldboot-watch.sh` + in-kiosk `amiga-emu`/`amiga-launch-coldboot.sh` + installer) and the `win95-clean/` golden re-bake pipeline. See `coldboot/README.md` (incl. the per-tile regeneration table). |
| `lib/` | Shared safety/build helpers: `clone-guard.sh`; chroot mount-propagation guard `chroot-guard.sh` (source it, or `chroot-guard assert-root|assert-under|mount-api|umount-all|run-private`) — the ONE way a chroot gets its `/proc`,`/sys`,`/dev` and the ONLY sanctioned teardown, proven by `tests/chroot-guard-selftest.sh`; X-display allocator `xvfb-alloc.sh` (source it, or `xvfb-alloc alloc|release|list|reap`) — the ONE way a rig gets an Xvfb, proven by `tests/xvfb-alloc-selftest.sh`; build-time QMP console/input library `labqmp.py`; clone-only `golden-verify.sh <tileDir> [--bake]` dirty/restore/fresh-process proof. `labqmp.py` complements rather than replaces box-side `/root/cdrv.py`. |
| `e2e/` | Node/Playwright live-gallery probes (`fd-check`, `input-smoke-*`, `tile-diag`, `capture-aus.mjs`, plus the `ff-*` Firefox diagnosis kit) — run against the real box, not CI. `GALLERY_URL`/`LAB_HOST` env. See `e2e/README.md`. |
| `tools/` | Generated `gallery-action-map.json` plus the historical guest-side `gallery-input-probe.py`. The deleted `gallery-perf-probe.mjs` / `gallery-perf-cpu.sh` targeted the retired neko Docker/WebRTC plane and must not be revived for streamhost measurements; live-plane checks belong in `labctl health`, `labctl assert`, `dev/verify-tile.sh`, and `tests/e2e-live/`. |

Per-guest documentation lives in `docs/guests/<os>.md`; the full rebuild
runbook is `docs/lab/MASTER-REPRODUCE.md`.

Deleted generations (recoverable from git history, 2026-07 restructure): the
neko/docker-compose integrators (`gallery-integrate-all.sh` and friends), neko
compose overrides, `pve-osgallery-*.sh` LXC deploys, and the losing Sailfish
VirtualBox builder. `public-gate/` (neko-era museum public gate, broken) was
removed 2026-07-14 — git history.

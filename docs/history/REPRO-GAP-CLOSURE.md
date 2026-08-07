> **Historical snapshot.** This document describes the system as it stood around 2026-07-14. It is kept for historical context and is not a description of the current system.

# Repo-reproducibility gap closure — worklist & status

Started 2026-07-14. Direction (user): **the repo must contain everything needed to
recreate the whole system from scratch** — the only externals are (a) licensed
installers/ROMs, staged per `docs/lab/ASSETS-MANIFEST.md`, and (b) secrets
(gitignored; PKI regenerable via `gen-local-ca.sh`, credentials documented in the
gitignored credential files / env vars). Consequently the NVMe migration
(`docs/lab/NVME-MIGRATION-PLAN.md`) transfers **no derived artifacts**: no guest
images, no goldens, no boot videos — everything rebuilds from this repo.

## Definition of done (acceptance test)

On a fresh host with only: this repo + staged licensed assets + secrets —

1. `scripts/build-guests/check-assets.sh` passes (all required externals present).
2. `scripts/build-guests/build-all.sh` builds **all 28 tiles'** guest images + goldens
   (one-time-click steps documented and agent-drivable; licensed-ISO tiles included).
3. Warpd/agent bakes reproduce on the six baked tiles; boot videos regenerate from
   the vendored recorder.
4. `streamhost/tiles-manifest.sh` emits all 28 launchers with **zero unexplained
   diff** vs the known-good set (`scripts/dev/verify-emit.sh` green).
5. `streamhost/bring-up-all.sh` → 28/28 tiles live → `tests/e2e-live` suites pass.

Levels: **L1** emit-parity green (current box, repo-only proof) → **L2** representative
builder trials pass on the current box → **L3** the full rebuild on the NVMe box
(the migration itself is the final validation).

## Gap register

| # | Gap | Work | Status 2026-07-14 |
|---|-----|------|-------------------|
| G1 | `build-all.sh` orchestrates only 19/28 tiles | Wire reactos, haiku, qnx, templeos, os2warp, sailfishos, msdos-win1, amigaos + alpine/tinycore entries | **DONE 2026-07-14** (`96001eb`) — 28/28 rows (sailfish 2-stage chain; alpine/tinycore soft-SKIP until G2 lands) |
| G2 | alpine + tinycore have **no builders** (boot ISOs from stray paths; alpine's ISO lives inside retired CT110's rootfs) | Write + prove `alpine.sh`/`tinycore.sh`; canonical paths `/data/gallery-guests/<OS>/` + `/data/isos/`; golden + gallery-key SSH contract | **DONE 2026-07-14** via codex `g2-alpine-tinycore` — both builders PROVEN end-to-end on the box (Alpine 3.24.1, TinyCore 17.0; sha-verified media, golden round-trips + framebuffer-equality checks, ssh probes, screendump evidence); OUT_DIR/WORK_DIR/ISO_DIR overrides; build-all rows now required (soft-SKIP removed); emit parity re-verified green |
| G3 | ~~8~~ **ALL 28** launchers had drifted from the manifest (ground truth found during closure; 22 carry bespoke logic, every tile.env had a hand-appended fixture stanza) | Extend `streamhost-tile.sh`/manifest until all 28 emit correctly | **DONE 2026-07-14** (`96001eb`) — 22 verbatim launchers + fixture stanzas vendored under `streamhost/tiles/`; manifest rewritten, no more "reference only"; postmarketos OVMF_VARS.qcow2 pre-seed folded in |
| G4 | No launcher-parity checker | `scripts/dev/verify-emit.sh` + whitelist of justified deltas — the L1 gate | **DONE 2026-07-14** — gate run green vs live box: 16 tiles byte-identical, 12 PASS* via 5 whitelisted delta classes (comment drift, alpine/tinycore/reactos canonical paths, apple2+win98se fast-poll restore). **L1 achieved** |
| G5 | Box-local live code not fully vendored (cdrv/qmp_hmp/gexec/gen_tiles_json, relfix drop-ins, amiga-coldboot-watch, seriald-sailfishos, serve helpers, warpd bake scripts) | Diff live vs repo; vendor/reconcile all | **DONE 2026-07-14** (`cfeadb8`) — most were already byte-matched; vendored-new: `qmp_hmp.py`, **the relfix daemon itself** (was box-only! now base `c7138573` + byte-exact patch under `streamhost/deploy/relfix/`), amiga-coldboot set, seriald unit, win95-clean set; ~100 /root one-offs flagged experiments, not vendored |
| G6 | Fast-poll pve-qemu patch: live `0047-new.patch` vs repo `qemu-patches/`; **no vendored .deb build recipe**; package not apt-held | Reconcile patch, vendor build script/recipe; hold lands with the new box | **DONE 2026-07-14** — repo patch is byte-identical to what built the live deb (box 0047-new.patch = stale scratch); recipe `scripts/provision/build-pve-qemu-fastpoll.sh` + `rollout-fastpoll.sh` vendored |
| G7 | Boot-video recorder tooling not (fully) vendored | Locate, vendor, document per-tile regeneration | **DONE 2026-07-14** — tooling was already fully in-repo (`scripts/coldboot/` + `bootrec-tap`); live artifacts verified as its outputs. **Coverage completed 2026-07-14 (late)** via codex `bootvideo-arms`: arms for all 28 tiles (9 existing + 3 proven-new alpine/c64/freedos w/ SSIM+encode-property evidence + 16 authored-untested, all dry-run-validated); content caveats: sailfishos/serenityos arms safe but not publish-ready, reactos non-promote. Incident note: cleanup killed a stray July-4 helper PID from `/root/qemu.pid` — independent fleet audit clean (28/28 + bridge scopes verified; stale July-9 failed scopes reset) |
| G8 | No licensed-assets manifest / preflight | `docs/lab/ASSETS-MANIFEST.md` (sha256, staging paths, license class) + `check-assets.sh` | **DONE 2026-07-14** — manifest + checker landed (`build-all.sh --check-assets`); checker run on box: all staged hashes pass, XP inputs correctly flagged missing → spawned G16/G17 |
| G9 | Builders unproven end-to-end | Trials on current box: helenos (hands-off), templeos (agent bake), freedos (one-time click); fix builders as found | **DONE 2026-07-14** via codex `g9-trials` — 3/3 PASS w/ golden round-trips + screendump evidence; templeos serial-agent pointer probe proven; freedos Arachne click documented exactly (relative moves to (494,428) + LMB); freedos sources re-pinned (wolf3d/quake/arachne) + zero-byte-extraction guard. Systemic risks recorded: URL rot, plausible-empty archives, undeclared host deps → remaining builders stay at-risk until exercised (more trials running) |
| G10 | SPA macos tile dialed a now-dead VNC bridge (VM 925 destroyed 2026-07-14) | Convert to win11/riscos-style showcase poster; drop dead noVNC path if unreferenced | **DONE 2026-07-14** — merged `b42fd20` (@novnc/novnc dropped, ~250 lines dead code removed), deployed to live webroot (boot/ preserved), bundle verified clean; follow-up DONE 2026-07-14 via codex `g10fu-macos-purge`: bridge refs purged repo-wide, macos-vnc-bridge.sh deleted, serve-https-spa.sh deploy now preserves non-SPA webroot (boot/), ensure_tiles seeds from canonical registry; box-sync pairs re-synced |
| G11 | CT950 dev box has no provisioning script (docs only) | `scripts/provision/provision-dev-ct.sh` from dev-box-notes (authored-from-docs, untested) | **DONE 2026-07-14** (`cfeadb8`; marked UNTESTED by design — CT950 *moves* in the migration, script is the recreate path) |
| G12 | Machine types unpinned (`-machine pc`/`q35`) → goldens welded to the baking QEMU's defaults | Opt-in `--pin-machine` emit (pc-i440fx-11.0/q35-11.0); rebuild bakes with pin ON | **DONE 2026-07-14** — implemented + resolution-verified on box QEMU 11.0 across all 28 (incl. the 5 no-`-machine` launchers); default OFF, rebuild uses `SH_PIN_MACHINE=1` |
| G13 | MASTER-REPRODUCE claims Phase-4′ (zfs-send transfer) parity it doesn't have; coverage table stale | Truth-up: Phase 4 = the plan, 28/28 table, 4′ demoted to legacy shortcut | **DONE 2026-07-14** (`96001eb`) |
| G14 | Six warpd bakes: scripts exist but reproducibility unproven | Vendored via G5; templeos (g9) + **win95 warpnet (trials-win9x) PROVEN** — cross-compiled + baked + moved cursor to exact coords post-golden-restore; os2warp/win311/ninefront/solariscde bakes still unproven → L3 | PARTIAL (2/6 proven) |
| G18 | **9 golden-bake helpers exist only on the box** (`golden-bake.sh` for alpine/kolibrios/solariscde/templeos/tinycore/win95/win98se; `golden-fixture{,-provision}.sh` for postmarketos) + haiku install→`haiku-persist.qcow2`+bake unscripted (haiku.sh stops at the ISO) + postmarketos `.img`→qcow2 conversion unscripted + android/freedos/ninefront launchers hard-require an existing golden (first-boot bootstrap step) | Vendor + audit the 9 helpers; script haiku install/bake + pmOS conversion; document golden-bootstrap order | **DONE 2026-07-14** via codex `g18-golden-bakes` — all 9 vendored byte-faithful (+QMP/setup auxiliaries, 1 flagged path fix in tinycore aux); `haiku-install.sh` **PROVEN on box** (install→sshd/key→golden round-trip, byte-exact fixture restore); `postmarketos-fixture.sh` wired into build-all (static-validated); android/freedos/ninefront bootstrap order documented in MASTER-REPRODUCE |
| G15 | One-time-click/calibration steps (win95/98 PnP, android coords, freedos/win2000 clicks) partially "best-effort" | freedos documented via G9; others remain flagged in MASTER-REPRODUCE — drive visually at L3 | OPEN |
| G16 | **WinXP SP3 ISO missing from the box, no recorded hash** + `WINXP_PRODUCT_KEY` env — worst repro hole; winxp tile currently NOT rebuildable | **USER: supply the XP SP3 ISO + product key**; stage per ASSETS-MANIFEST, record sha256 | OPEN — needs user |
| G17 | Irreplaceable / rot-prone staged inputs: OS/2 installer **evolved in place** (pristine download gone — the on-box file IS the input now), win95 zip md5-pin only, win311 base from unpinned third-party (rtts.eu), win98/win2000 caches purged (re-fetch = rot risk), Sailfish VDI not retained | Stage the **licensed + abandonware-URL classes** (not just licensed) into the Phase-0 assets bundle; first restic offsite set includes them | **DONE 2026-07-14** via codex `assets-staging` — `/data/assets-staging/` (2.5 G, 14 files, all sha256 OK, MANIFEST.sha256 + README) incl. sol10.iso, OS/2 evolved image, win311 base, DOS/Win1.01 floppies, QNX iso, purged-cache game zips; `check-assets.sh --root/--class` added; still MISSING by design: XP ISO+key (G16), Sailfish VDI. Offsite copy = migration Phase 7 restic set |

## Operating rules for trials (standing lab rules apply)

Never touch live tiles or `/data/gallery-guests` (read-only reference). Namespace
everything under `/data/vms/soltest/repro-<name>-<ts>/` (own QMP sockets, ports,
pidfiles); kill QEMU only by pidfile; `nice -n15`; delete work dirs after each trial
(headroom came from deleting VM 925 — don't burn it); verify guest state only via
real framebuffer screenshots.

## L2 builder-proof evidence (end-to-end runs on the current box)

**11 builders PROVEN** across every difficulty class (2026-07-14, codex):
alpine + tinycore (g2), haiku-install (g18), helenos + templeos + freedos (g9),
kolibrios + toaruos + serenityos (trials-small), **win95 + win98se (trials-win9x)**.
Covers hands-off, golden-fixture, one-time-click, serial-agent-bake, no-golden-overlay,
and (win95) **warpnet-agent-bake** reset modes — win95 warpnet moved the cursor to exact
coords after a fresh-process golden restore. All trial batches complete. Systemic
builder-rot patterns found + fixed: optimistic file-size validation, shared/fixed VNC
ports, stale proof artifacts, launcher/manifest device drift, silent-success tools,
rotted download URLs, plausible-empty archives, non-isolated output/log paths.

## Install-automation research (G19, spike)

Two research spikes exploring higher-reliability install automation (findings →
`docs/lab/research/`). Both use aggressive internal-savevm checkpointing so failed
experiments loadvm-retry instead of reinstalling.

- **win2000 unattended (winnt.sif) — DONE, verdict: shelved.** From-ISO unattended
  install is **blocked**: no authorized Win2000 ISO or product key in repo/lab (agent
  respected the key boundary, did not scavenge). NOT a repro blocker, though — the
  win2000 tile's real builder uses the freely-downloadable WinWorld **pre-built VM**
  (no key), which stays the reproducible path. Byproduct win: root-caused the G15
  "Found New Hardware" click to QEMU's `ACPI\QEMU0002` VM-Generation-ID device and
  added an offline registry suppression (fix D) to `win2000.sh` + a secret-free
  `WINNT.SIF.in` template for future use. **Caveats:** fix (D) proven in the research
  trial but not yet through a full `win2000.sh` run; the "zero clicks remaining" claim
  needs re-verification at L3 (AC97/rtl8139 wizards may still appear).
- **android-cv (local OCR+template vision) — DONE, verdict: feasible.** CPU-only
  toolkit `scripts/install-vision/` (OCR `find_text.py`, multi-scale template
  `find_template.py`, `settle.py` frame-diff watchdog, `driver.py` QMP click w/
  transition-gated retries + pre-click snapshots) reached the real Android home
  screen. **Legacy hardcoded coords were 0/8** (and the wizard is actually 10 steps,
  not 8) — a concrete case for content-aware targeting. OCR alone: 4/10 screens;
  templates: 30/30. Gated behind `INSTALL_VISION=1` in `android-x86.sh` (old coord
  path stays default). Snapshot discipline worked: 14-deep pre-click checkpoint tree,
  every experiment loadvm-retried. Separate finding: android's text-mode installer
  keystrokes are independently stale → production repair still needed.
- **Takeaway**: the answer-file path (win2000) is the cleaner win where an OS supports
  it; local CV is the right tool where it doesn't (android). `scripts/install-vision/`
  generalizes to other graphical-installer tiles. Both remain opt-in research — not
  wired into default builders — pending a decision to productionize.

## Status log

- **2026-07-14 (late evening)** — codexit wave 2 (5 more Sol sessions): `trials-small` (kolibrios/toaruos/serenityos), `trials-win9x` (win95+win98se fixtures — chips G14/G15), `repro-quickstart` (fresh-clone audit + docs/REPRODUCE-QUICKSTART.md for outside users), `bootvideo-arms` (the 19 missing recording arms), `assets-staging` (G17 bundle). Still user-gated: G16 XP ISO+key.
- **2026-07-14 (evening, codexit)** — remaining work relaunched as 4 headless Codex
  sessions (Sol 5.6/high, `scripts/dev/codex-task.sh`): `g2-alpine-tinycore` (resumes
  the paused G2 worktree), `g9-trials` (resumes paused G9), `g18-golden-bakes` (new),
  `g10fu-macos-purge` (G10 follow-up + serve-https-spa deploy fixes). Canonical
  `/data/isos/{Alpine,TinyCore}.iso` staged on the box. Claude = orchestrator only.

- **2026-07-14** — Program started (5 parallel agent workstreams on isolated
  branches). Headroom made: **VM 925 (macOS) destroyed** (user-authorized; pool
  86 % → 66 %, 28 G free), its VNC-bridge helpers killed; **CT 110 stopped +
  onboot=0** (retired — dataset stays until SSD wipe; live alpine tile still reads
  its ISO from there, canonical fix lands with G2/G3); stray QEMUs (`w2kwrite2`,
  `serenity-vgastd`), 3 stray http.servers and 2 leftover loop mounts cleaned.

## Follow-ups queued (from codex repro-quickstart audit, 2026-07-14)

- **F1 — DONE 2026-07-14** via codex `f1-reproduce-truthup` (merged): all items below fixed; `scripts/provision/` vendored w/ curl 206/416 Range proof; build-all media gating (`--with-media`, bare run = 26 cmds/4 honest skips). Original scope: MASTER-REPRODUCE
  truth-up batch — Phase-1 Range-server/iPXE/answer-file still not vendored;
  licensed-build example puts env after the command (script rejects); Sailfish
  default build needs SDK media/account flow (document or gate); stale Win11/macOS
  bridge language; plus `build-all.sh` polish (misleading "all requested guests
  built" wording on dry-run; default selection pulls Sailfish media → exit 3 —
  make media-less default selection sane).

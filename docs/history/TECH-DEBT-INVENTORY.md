> **Historical snapshot.** This document describes the system as it stood around 2026-07-16. It is kept for historical context and is not a description of the current system.

# Kernel Hive — tech-debt & tooling-gap inventory (2026-07-16)

Synthesis of **six parallel read-only audits** (streamhost Rust core, SPA frontend,
data-model/registry, scripts/ops, cross-cutting architecture, tooling/OS-onboarding/PVE).
Nothing was modified during the audits. Findings below are **deduped** across audits — an
item flagged by N audits is marked `(×N)` and ranked up for corroboration. Effort: **S** =
hours, **M** = a day or a few, **L** = a week-plus. Ranking is weighted by the user's stated
priorities: *make future OS onboarding efficient, support Proxmox-level VMs, improve dev
velocity, then reduce structural debt.*

## Honest top-level framing

- **The Rust core is in good shape.** The daemon input layer is a clean `InputRouter` +
  `RealtimeInputSink` trait; the WebRTC path **shares the single H.264 encoder** (no duplicate
  encode); streamhost **attaches** to QEMU via QMP rather than owning it. The debt is
  concentrated in the **workflow/operational plane** (harvest, shared binary, box↔repo drift)
  and the **guest-facing** halves of the input & config systems — not the hot path.
- **"Wrong language selections": none egregious.** The Go/pion WebRTC bridge is a *deliberate*
  out-of-process design, not an accident; the 8 warpd parsers in 5 languages are *forced* by
  per-guest toolchains (you cannot run Rust inside TempleOS). The one real language-adjacent
  debt is the redundant `streamhost.relfix` **fork binary** (now that bounded-rel is merged
  into `input.rs`) — delete it, don't port it.
- **The registry + generator + drift-CI already solved lineup metadata well.** Everything
  recommended here sits *on top of* those tested scripts; don't rebuild them.

## The single highest-leverage unlock

**streamhost attaches to an externally-launched QEMU via its QMP socket — it never launches
QEMU.** (`capture::connect` → `getfd`/SCM_RIGHTS → `add_client protocol=@dbus-display`;
`ensure-tile-qemu.sh` only starts QEMU if not already running; `SH_QMP` is the *sole* coupling.)
This means **Proxmox-managed tiles are an S–M feature, not a new pipeline** — see item **1**.

---

## Ranked, deduped inventory

| # | Item | Audits | Effort | Track |
|---|------|--------|--------|-------|
| 1 | **PVE-VM-backed tiles** (`runtime.qemu.mode:"pve"`) — heavy/UEFI/TPM/accel guests; readmits macOS+Win11 | tooling | **S–M** | Onboarding |
| 2 | **Runtime-served `gallery-manifest.json`** — kill the mandatory SPA rebuild per new tile | tooling, data-model | **M** | Onboarding |
| 3 | **Rust build loop** — dev-fast profile + mold + shared cache + safe default target + `flock` | tooling | **S–M** | Velocity |
| 4 | **Harvest / box↔repo drift** — `harvest.sh` + `verify-box-sync.sh` + gate destructive deploy + `codex land` | architecture ×, scripts, tooling | **S–M** | Velocity |
| 5 | **Fleet binary model** — versioned install + per-tile symlink + N-1 rollback + canary gate | architecture | **M** | Velocity |
| 6 | **Registry migration finish** — drop render-block inversion, fold parallel registries, `DO NOT EDIT` banners | data-model, architecture, scripts | **M** | Structure |
| 7 | **Declarative install-vision state machine** (`run <flow.yaml>`) — stop rewriting bespoke Python per graphical install | tooling | **M** | Onboarding |
| 8 | **`new-os` scaffold + shared `labqmp.py` + `golden-verify`** trio (16 hand-rolled QMP drivers; 9 dup keymaps; 10/31 golden proofs) | tooling | **S–M each** | Onboarding |
| 9 | **Live-plane verify/health surface** — `labctl health`/`assert` + `verify-tile.sh`; retire dead neko probes | tooling | **M** | Velocity |
| 10 | **clientcmd eval security (closed)** — default-off eval, strong-token admin plane, no peer-IP trust behind the tunnel | scripts, architecture | **DONE** | Structure |
| 11 | **Dead-neko purge + de-neko naming** (~900 LOC) + canonical tile count + DESIGN.md "historical" banner | SPA, streamhost, architecture | **S–M** | Structure |
| 12 | **Input consolidation** — collapse `Pointer`+`InputBackend` enums, delete `relfix` fork + dead fail-closed arms, freeze warpd core | streamhost, architecture | **M** | Structure |
| 13 | **God-file decomposition** — `streamClient.ts` (1824), `StreamView.tsx` (2645), `encode::run` (310) | SPA, streamhost | **M–L** | Structure |
| 14 | **Test coverage where bugs live** — `abr.rs`/`audio.rs`/`warpd.rs` 0 tests, `transport.rs` 2; add vitest for the FF race | tooling | **M–L** | Structure |
| 15 | **WebRTC decision** — first-class (TURN/coturn + input + bring-up wiring) vs explicit shim; prune 4 merged branches | architecture, streamhost | **M / L** | Gated |
| 16 | **Reproducibility holes** G14 (4 warpd bakes unproven), G15 (click-installs), G16 (winxp not rebuildable), L3 never run | architecture | **L** | Gated |
| 17 | **Paved-road clone** `clone-tile.sh` (route all kills through clone-guard) + `pointer-probe.sh` | tooling | **S–M** | Onboarding |
| 18 | **`codex-task.sh harvest`/`land`** + `clientcmd eval-sync` ergonomics (103 stale `codex/*` branches today) | tooling | **S** | Velocity |

---

## Detail

### 1 — PVE-VM-backed tiles (`runtime.qemu.mode: "pve"`)  · S–M · Onboarding
**Need:** No streamhost-native path for a Proxmox-managed VM (heavy/UEFI/TPM/accelerated
guests — the class you said is coming). **Because streamhost already attaches by QMP**, the
change is small and touches **nothing in the hot path**:
- PVE launches & owns the VM; streamhost attaches to a **dedicated second QMP** it injects via
  `qm set <vmid> --args "-display dbus,p2p=on -qmp unix:<tiledir>/qmp.sock,server=on,wait=off …"`
  (the verbatim-`args` mechanism `pve-macos-vm.sh` already proves; PVE emits no `-display` for a
  normal VGA guest, so this is the sole one and coexists with the PVE web console).
- Registry: new `runtime.qemu.mode:"pve"` + `runtime.pve.vmid`; pve tiles generate **no**
  `qemu-streamhost.sh` (device ledger = `qm config`), emit `SH_QEMU_MODE=pve`/`SH_PVE_VMID`.
- `ensure-tile-qemu.sh` pve branch: `qm status … || qm start`; wait for the QMP socket; keep
  "daemon restart never restarts the guest". `stop-tile-qemu.sh` = no-op (PVE owns lifecycle).
- New `pve-rollback` reset: golden = a PVE RAM snapshot (`qm snapshot … --vmstate 1`); reset =
  `qm rollback` + `systemctl restart streamhost@<tile>` to re-attach.
- `SH_QEMU_PIDFILE` override (~5 lines) so the RSS guard finds `/var/run/qemu-server/<vmid>.pid`.
- **Reject** a VNC/SPICE capture bridge (that's the deleted neko path). **Keep** "heavy guest
  under streamhost's own launcher with OVMF/TPM args" only as a documented fallback.

Verified on-box: pve-qemu-kvm 11.0.2 is the *same* binary the tiles use and lists `dbus` in
`-display help`; `QemuServer.pm:3383-3386,3806-3809`.

### 2 — Runtime-served `gallery-manifest.json`  · M · Onboarding
Adding **any** tile today still needs `npm ci && npm run build` + webroot deploy + a
"no-secret-in-bundle" re-verify, because `OS_BINDINGS`/catalog are bundle-time data. Fully
designed, unimplemented: generator emits `gallery-manifest.json` (public registry subset) into
the webroot beside `/signal/*.json`; `useManifest` fetches+validates (`cache:"no-cache"`) with
an embedded last-known-good fallback. After this, **generate + copy two JSONs = new OS appears,
no Vite build.** Also collapses the SPA 5-file OS data model (museumCatalog/catalog/mock/
useManifest/archetypeRegistry) that currently carries the **confirmed c64 drift** (era "1986"
vs year 1982) into one served source.

### 3 — Rust build loop  · S–M · Velocity
`build-deploy.sh` always `cargo build --release` on a 245-crate graph, no incremental/mold/
sccache; bare invocation restarts **all 28 tiles**; `--changed-only` is a no-op alias for
`--all`; the smoke gate **false-FAILs on idle tiles** (needs a client+damage line); concurrent
invocations share one `--delete-after` build dir with **no lock**. Four independent fixes:
`[profile.dev-fast]` + `--fast`; install **mold** + `.cargo/config.toml`; shared
`CARGO_TARGET_DIR`/sccache so worktrees build warm; make the default target **one safe tile**
(require `--all` to fan out); replace the damage smoke with the startup-readiness line; add
`flock`.

### 4 — Harvest / box↔repo drift  · S–M · Velocity  *(most corroborated)*
Repo→box (`build-deploy.sh`) is scripted **and destructive** (`--delete-after` silently erases
un-harvested box edits); box→repo has **no tooling** — hand-prose + a 112-entry manual
reconciliation ledger. ~15–18 hand-synced "reference-in-repo + live-on-box" mirror pairs, only
the registry-generated set has an automated gate. **103 stale `codex/*` branches** and orphaned
`codex/harvest-wave1` (a MASTER-REPRODUCE fix exists *only* there) prove the missing `land`
step. Fixes: `harvest.sh` (box→repo targeted rsync + diff-review + commit); make
`build-deploy.sh` **refuse `--delete-after` when the box tree is dirty** vs its last-harvested
marker; `verify-box-sync.sh` md5-checks all pairs; `codex-task.sh harvest`/`land`
(rebase→ff-merge→push→clean). *(Caveat: the specific "6 un-harvested edits" the architecture
audit cited come from a pre-compaction HANDOFF; most were since harvested — but the workflow gap
and the branch graveyard are real.)*

### 5 — Fleet binary model  · M · Velocity
Every `streamhost@<tile>` runs the single release artifact **in place** from the box build tree
— no install step, no versioning, no atomic swap, no canary lane. Blast radius of any daemon
regression = the whole fleet. Fix: version the binary (`streamhost-<gitsha>`), install to
`/usr/local/lib/streamhost/`, point `ExecStart` at a per-tile symlink, keep N-1 for instant
rollback, add a one-tile canary gate to `build-deploy.sh`. (Composes with item 3's "safe default
target".)

### 6 — Registry migration finish  · M · Structure  *(corroborated)*
The typed registry generates operational files, but the migration is **half-done**:
`registry/index.json` preserves the old files' **byte layout** and the generator *parses legacy
Bash/TS rows and rejects disagreement* (two-way coupling, not replacement); the `render` block
**caches pre-rendered TS/shell validated by a hand-rolled parser** — an inversion of
generate-from-data. Parallel registries persist (`serve/tiles.json`, `golden-manifest.json`,
box `tiles.json` labctl matrix). Generated files carry **no `DO NOT EDIT` banner** despite the
README forbidding hand-edits (a real foot-gun during re-bakes). Schema can't even express
`gallery-hid` (`enum:["abs","rel","warpd"]`). Fix: drop byte-layout preservation, fold
serve/tiles.json + golden-manifest into registry outputs, stamp every generated file, extend the
schema.

### 7 — Declarative install-vision state machine  · M · Onboarding
`scripts/install-vision/` has excellent reusable *primitives* (Tesseract `find_text`,
multi-scale `find_template`, `settle`, `qmp`, `rel:` ROIs) but `driver.py step` only expresses
"detect one button → tap → settle". Any installer with text entry / branching / optional dialogs
falls back to a fresh ~250-line bespoke driver (`redstar3.py` = 260 lines), while android already
uses a clean declarative shell table. Promote that into `install-vision run <flow.yaml>` (ordered
mixed actions tap/type/key, `optional:` branch dialogs, per-step checkpoints, env-injected
secrets never logged) over the existing primitives + `install-vision capture <state>` to harvest
template crops. **This is the single biggest per-OS time sink for the Tier-2/3 heavy guests
you're about to add.**

### 8 — `new-os` scaffold + shared `labqmp.py` + `golden-verify`  · S–M each · Onboarding
No `new-os <id>` generator exists — every add copy-pastes ~6 file types and renames IDs by hand.
A QMP console/input driver is hand-rolled **16 times** (the shift-keymap dict duplicated verbatim
in **9** files). The golden dirty→restore proof exists for only **10 of 31** tiles (a
rebuild-from-repo gap). Trio: `tiles-registry.py new <osId> --tier --archetype --slot auto`;
a single tracked `scripts/lib/labqmp.py` builders `import`; `scripts/lib/golden-verify.sh`
standardizing cold-launch→ready→determinism→savevm→dirty→loadvm→SSIM→fresh-process re-verify.

### 9 — Live-plane verify/health surface  · M · Velocity
The QoE/latency probes (`gallery-perf-probe.mjs`, `gallery-perf-cpu.sh`) still target the
**deleted** neko/Docker/WebRTC plane. `labctl ls` shows only systemd active/failed. Every e2e
probe re-implements the same stream-liveness check; §7 acceptance is a fully manual runbook. Add
`labctl health` (per-tile service + sessions + encoder-up + last-damage age + RSS vs guard +
paused), `labctl assert <tile> --text|--template|--settle` (reuse the install-vision harness
against a **live** tile — satisfies the AGENTS.md framebuffer-assert mandate reusably), and
`scripts/dev/verify-tile.sh <osId>` (the mechanical two-thirds of §7.3). Retire the neko probes;
extract one shared stream-probe lib.

### 10 — clientcmd eval security  · S · Structure
**Closed 2026-07-16.** The defeated `_is_lan(client_address[0])` gate was removed.
`/clientlog`, `/clientcmd`, `/clientcmd/admin`, and `/restore` now require the
file-backed `X-Admin-Token` regardless of socket peer address. Eval additionally
requires explicit `OSG_ADMIN_EVAL=1` and is filtered from polling while off. See
`docs/lab/clientcmd-admin-security.md`.

### 11 — Dead-neko purge + naming + counts  · S–M · Structure  *(corroborated)*
~900 LOC dead neko WebRTC runtime (`useNekoTexture.ts`, `useNekoControl.ts`) with live symbols
still named `Neko*` (misleading); systemd unit still documents rollback "back to remote-neko"
though the backends are gone; DESIGN.md describes the **pre-migration** world. The fleet count is
stated as **24 / 26 / 28 / 30 / 33** across docs — no single source agrees. Fix: delete dead
neko + de-neko the vocabulary; make the registry the **single count authority** and have docs
cite it; banner DESIGN.md "historical, pre-cutover"; purge neko rollback language; fix the stale
`guest-agents/legacy/…` doc path.

### 12 — Input consolidation  · M · Structure  *(corroborated)*
Five live pointer paradigms; the daemon config plane carries **two overlapping enums**
(`Pointer{Abs,Rel,Warpd}` + `InputBackend{Dbus,Warpd,GalleryHid}` — the fixture itself admits
"the naming is now a lie"); the `streamhost.relfix` **fork binary** is redundant now that
bounded-rel is merged; `input.rs` still has dead fail-closed warpd arms (337-342, 395-402); the
`warpd-to-ghid-bridge.py` shim is pure transitional debt. Treat the router+sink trait as the
seam: collapse the two enums into one backend enum, delete the relfix fork + dead arms, declare
warpd **frozen** (M/P/R/B core only), scope gallery-hid explicitly as **Solaris-only** (it can't
absorb a 120-line warpd agent with a 1299-line kernel driver).

### 13 — God-file decomposition  · M–L · Structure
`spa/src/three/streamClient.ts` (1824-line god-class) + `spa/src/ui/grid/StreamView.tsx`
(2645-line component) are the biggest SPA structural pain; `encode::run` is a 310-line god-loop
(mod.rs 487-799). Decompose along the obvious seams (transport/decode/present in the client;
capture/convert/encode/emit in the loop). Lower urgency than the onboarding/velocity items.

### 14 — Test coverage  · M–L · Structure
Test distribution is inverted vs risk: **0** `#[test]` in `abr.rs` (392 lines pure logic),
`audio.rs`, `webrtc_bridge.rs`, `signaling.rs`, `warpd.rs`; `transport.rs` (846) has 2; no crate
`tests/`. SPA CI is eslint+tsc+build only — the Firefox uni-stream race fix has no test though AU
fixtures exist. Add pure-logic units for abr/audio first; a `tests/loopback.rs` for AU-framing +
the incoming-uni-stream race; **vitest** to `spa.yml` with a committed AU fixture; a CI job
asserting `tiles-registry.py generate` is a no-op.

### 15 — WebRTC decision  · M / L · Gated
Shared encoder (good), but downstream everything doubles: a second transport (pion), a second
process/language, a **second SPA render stack** (`webRtcFallbackClient.ts` → `<video>` vs
`streamClient.ts` → WebCodecs), plus a dormant third neko `RTCPeerConnection`. Two gaps: fallback
is **view-only** (no input) and **LAN-only** (no TURN); the bridge isn't wired into
`bring-up-all.sh`. **Decision needed:** fund it as a real second path (coturn + input + fleet
wiring) or keep it an explicitly-minimal Firefox-Android shim. Prune the 4 merged `codex/webrtc-*`
branches either way.

### 16 — Reproducibility holes  · L · Gated
G14 (only 2/6 warpd bakes proven reproducible), G15 (click/calibration installs best-effort),
**G16 (WinXP SP3 ISO+key missing → winxp not rebuildable — user-gated)**, G17 (evolved-in-place
inputs), and **L3 (the end-to-end NVMe rebuild) has never run**. Close G14/G15 before the
migration; the install-vision CV toolkit (item 7) is the lever; G16 needs a user decision.

### 17 — Paved-road clone + pointer-probe  · S–M · Onboarding
`clone-guard.sh` (incident-born, excellent) has only 2 consumers; `labctl clone` supports only
`solariscde`. `scripts/dev/clone-tile.sh <tile> <ns>` (copy golden + reproduce device set,
namespace qmp/pid/hostfwd, route every kill/launch through clone-guard) + `pointer-probe.sh`
(generalize `redstar3.py:proof()` → evidence dir). Do **not** auto-select the transport.

### 18 — codex harvest/land + eval-sync  · S · Velocity
(Folded into item 4's `codex land`.) Plus `clientcmd.sh eval-sync <target> '<js>'` — enqueue,
poll, print the reassembled result — to end the manual `[i/n]` chunk-reassembly dance.

---

## Recommended parallel starting tracks

Given the standing "deploy-immediately / more parallelism the better" mode and the near-term goal
of **adding more OSes (some Proxmox-level)**, three tracks compose cleanly and can run at once:

- **Track A — Onboarding & Proxmox** (items **1, 2, 7, 8**): PVE-backed tiles + runtime manifest
  + declarative install-vision + the `new-os`/`labqmp`/`golden-verify` trio. This is the direct
  answer to "add more OSes soon"; each subsequent add gets dramatically cheaper.
- **Track B — Velocity & safety** (items **3, 4, 5, 9**): fast build loop, script+gate the
  harvest/box-sync, version the fleet binary with a canary, and stand up `labctl health`/
  `verify-tile.sh`. Ends the two biggest recurring taxes (slow rebuilds, per-task measurement
  reinvention) and closes the "lose work on next destructive deploy" risk.
- **Track C — Quick structural wins** (items **10, 11**, then **6, 12**): the eval-security
  hardening and dead-neko/count cleanup are low-risk, high-clarity; then finish the registry
  migration and consolidate the input enums.

God-files (13), full test coverage (14), the WebRTC funding decision (15), and the repro holes
(16) are real but lower-urgency / gated — schedule after the above.

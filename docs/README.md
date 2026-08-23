# docs/ — documentation index

Crate-local streamhost docs (design, bridge pattern, latency, encoder findings,
SH_* config reference) live in `streamhost/docs/`. The UI has its own
`spa/README.md`. Everything else is here.

For a new checkout, start with [REPRODUCE-QUICKSTART.md](REPRODUCE-QUICKSTART.md).
It separates the clone-local UI build from the Proxmox-only full-labhost rebuild,
lists the external inputs, and points into the authoritative runbooks in order.

`docs/gallery-credentials.md` (guest login table) is **gitignored on purpose**
and exists only on private working copies — keep it that way.

## lab/ — labhost and its platform

| Doc | What it is |
|---|---|
| [lab/MIGRATION-MAC-RUNBOOK.md](lab/MIGRATION-MAC-RUNBOOK.md) | Historical: the Mac-session bootstrap runbook that drove the completed (2026-07-15) NVMe migration — dev-seat handoff, preconditions to sync while CT950 is alive, first actions. |
| [lab/MASTER-REPRODUCE.md](lab/MASTER-REPRODUCE.md) | Single ordered runbook to rebuild the whole lab (host + all guests + gallery) on the NVMe labhost from source. |
| [lab/BRIDGE-TRIXIE-MIGRATION.md](lab/BRIDGE-TRIXIE-MIGRATION.md) | **IN FLIGHT: the guest half of bookworm → trixie.** The host finished 2026-07-15; the shared emulator-bridge seed is still Debian 12 with 28 overlays backing onto it byte-for-byte, so the migration is per-station. The two-base design (why the pinned bookworm base keeps its original path), the ledger `registry/bridge-suites.json` declaring intent vs labhost holding reality and how `bridge-suite-status.sh` catches drift, the per-station procedure (work → overlay rebuild → checkpoint recapture → `labctl shot` acceptance → registry prose in all four places → ledger flip in the same commit), the verified per-station verdicts (`star` loses `nuget`, `sinclairql`/`zxspectrum` lose their pinned MAME 0.251 and need romsets re-derived against 0.276, `daybreak` loses openjdk-17, `apple2` gets SDL 1.2 emulated over SDL2, `amiga` loses its Mesa Recommends and renders black), the wave order, and what "done" deletes. **15 of 28 stations are on trixie as of 2026-08-10** — several per-station verdicts above are now superseded (amiga's Mesa gap is already closed in the trixie base); ask `scripts/dev/bridge-suite-status.sh`, not this row. |
| [lab/MIGRATION-WAVE-BRIEF.md](lab/MIGRATION-WAVE-BRIEF.md) | **Read this before running a kiosk migration wave.** The short operational brief that sits on top of BRIDGE-TRIXIE-MIGRATION.md: what changed on 2026-08-10 (the three `migrate-tile.sh` bugs that are FIXED and must not be re-diagnosed, the wave driver / acceptance bundle / box-sync push tools), the per-station table for the 13 remaining stations with each machine's **acceptance signal** — the specific banner text, colours and pixel counts a correct AFTER screenshot shows, and the plausible wrong frame it must not be — the non-negotiable rules with the incident each one bought, the roll-back-and-move-on failure protocol, the report format, and how a wave branch's merge conflicts must be resolved (the ledger is a union; generated files are regenerated). |
| [lab/WALKIN-BRIEF.md](lab/WALKIN-BRIEF.md) | **PLANNING: the walk-in epic** — let anyone on the web self-register (passkey, no invite) and play three low-cost open-licensed stations on private per-visitor clones. The clone-pool/broker shape, the recommended trio (kolibrios/reactos/haiku), quotas, the threat model, phases, and the operator decisions still open. |
| [lab/RETRONET-BRIEF.md](lab/RETRONET-BRIEF.md) | **PLANNING: the retronet epic** — an offline in-lab 90s internet: era-pressed web corpus behind a corpus-only proxy (no upstream, ever), ICQ/AIM/MSN/IRC servers for station-to-station chat, and per-station personas captured signed-in so a bot greets each visitor ~30 s after the station wakes. The two attachment lanes (slirp pinholes vs museum bridge), the win95 warpnet trap, enablement waves, phases, and open decisions. |
| [lab/REMOTE-PROVISIONING-NOTES.md](lab/REMOTE-PROVISIONING-NOTES.md) | Bare-metal remote-provisioning gotchas: Redfish virtual media + Range, iPXE netboot, IPMI quirks. |
| [lab/Supermicro-storage-upgrade.md](lab/Supermicro-storage-upgrade.md) | Hardware/order record for the Supermicro chassis and its storage. |
| [lab/dev-box-notes.md](lab/dev-box-notes.md) | CT950 osgallery-dev workstation: ssh/mosh access + shared VNC headed-browser desktop for E2E. |
| [lab/CLOUD-AGENTS.md](lab/CLOUD-AGENTS.md) | **How a cloud coding agent (Google Jules, Claude cloud sessions) gets `ssh lab`**: dial-out reverse tunnel over the forwarder VPS (no inbound port on the home WAN) into a loopback-only, key-only second sshd; Jules env-var + setup-script config, one-command revocation, and an honest account of what the stored root key means. |
| [lab/PEN-TAP-PLAN.md](lab/PEN-TAP-PLAN.md) | **DONE (shipped and verified in the deployed bundle 2026-08-10)**: the record of the pen-tap quantisation change, with the measurements behind it — thresholds are in guest pixels while a hand wobbles in physical space, so effective sensitivity changes with each station's resolution. Also lists the live instrumentation to tear down. |
| [lab/LABCTL.md](lab/LABCTL.md) | **Driving a guest**: why to start every station task with `labctl facts`, the channels in order of preference and what each one PROVES, and the traps — `labctl sh` captures nothing, `labctl type` bypasses key pacing and drops characters while printing ok, `assert --settle` is a tautology on an idle-paused station, `shot` on a stopped station exits 2. The sub-commands are deliberately not duplicated: `labctl` is self-documenting. |
| [lab/STREAM-DEBUGGING.md](lab/STREAM-DEBUGGING.md) | **Start here for any STREAMING complaint — froze, blurry, laggy, stopped, dropped quality.** You almost never need a repro: every live session ships its full Ctrl+N overlay state to `clientlog.jsonl` every 5 s, and flushes on pagehide, so the seconds before a session dies survive it. Decodes the `stats` line field by field (including the `!` untrustworthy-loss flag and the tier-history `path`), says what the server does NOT know (its T_STATS feed is 29 bytes), lists the journald grep strings including `[abr] DOWN why=`, and carries the known signatures: quality flapping on a healthy link, `rx0.0M fps0` after a tier change, and a guest paused because the session died first. Ends with the deploy/promotion traps (darklaunch overlays, readiness timeouts, deliberately-off stations). |
| [lab/win311-interrupts-disabled-freeze.md](lab/win311-interrupts-disabled-freeze.md) | **Root-caused, not fixed: win311 freezes because the guest ends up running with the CPU interrupt flag clear.** Opens with steps to reproduce (~16s, ~60-110 key edges of SkiFree's numpad keys) and what should happen vs what happens instead. Timer and keyboard IRQs sit pending forever (`pic0 irr=03 isr=00 imr=88`, IF clear in 10/10 samples) while QEMU keeps executing — so the clock stops, every app freezes at once, and only a reset recovers it. A COLD-BOOTED guest wedges identically, so the golden vmstate is not the carrier and re-baking it would not help. Tools in `scripts/dev/input-wedge-repro/`, including `irqprobe.py` (reads CPU interrupt state, needs no scene) and the Clock-beside-SkiFree passive probe that separated "input is dead" from "Windows is dead". Carries the twelve hypotheses this killed and the evidence for each. |
| [lab/INPUT-DEBUGGING.md](lab/INPUT-DEBUGGING.md) | **Start here for any pointer/tap/drag/double-click bug.** Which of the three input paths a press actually takes (a stylus is `pointerType: 'pen'` and does NOT reach the touch recognizer — two fixes were shipped to the wrong path before this was written), the three telemetry sources cheapest-first, the warpd button-guard that reshapes click timing on win311/os2warp/templeos, why QMP `abs` is useless on those stations, the synthetic-pen probe, and what every threshold in `TAP` is for. |
| [lab/xvfb-alloc.md](lab/xvfb-alloc.md) | **X-display allocator for rigs** (`xvfb-alloc`): atomic claim via `-displayfd`, loud failure instead of the silent attach that contaminated a campaign's screenshots, orphan reap, and the converted callers. |
| [lab/tile-teardown-cgroups.md](lab/tile-teardown-cgroups.md) | **Why `systemctl stop streamhost@<tile>` did not stop the station**, and the systemd-level fix: guests launched into an unbound `systemd-run --scope` plus `KillMode=process` left orphaned watchdogs alive (a measurement-integrity bug, not just an ops one). Scopes are now `BindsTo=` their service and the unit runs `KillMode=mixed`; regression check `scripts/dev/tile-lifecycle-check.sh`. |
| [lab/clone-guard.md](lab/clone-guard.md) | **HARD safety guard for VM-clone tooling** (`clone-guard`): fail-closed refusal to kill/stop/QMP any live station; the Solaris-station breach root cause + how every clone helper must route through it. |
| [lab/ASSETS-MANIFEST.md](lab/ASSETS-MANIFEST.md) | Licensed/external build inputs: per-builder media, hashes, staging paths, license class, publish blockers. Preflight: `scripts/build-guests/check-assets.sh`. |
| [lab/AGENT-CI-EXIT-RULE.md](lab/AGENT-CI-EXIT-RULE.md) | **Green-before-done gate** every branch owes before merging to `main`: canonical per-language lint/test commands + the cross-cutting file-size budget (`scripts/check-file-size.mjs`, `size-exclusions.json`) and generated-file drift gate; the pre-push hook. |
| [lab/MEASUREMENT-METHODOLOGY.md](lab/MEASUREMENT-METHODOLOGY.md) | **How this lab measures emulator performance, and the incident behind each rule.** The metric (`emulated_secs / (cycles/2.5e9)`), achieved GHz beside every figure because the metric *inverts* clock changes, within-run windowing only, full-core-pair pinning, `foreign%` as a gate rather than a decoration, rank by speed not profile share, uprobes on the shipped binary instead of an instrumented build, and the framebuffer signatures. Four retracted conclusions are cited where they apply. Rig: `scripts/build-guests/irix/irix-bench/`. |
| [lab/irix-closed-register.md](lab/irix-closed-register.md) | **Every IRIX performance angle measured and CLOSED, with mechanism and ceiling** — so nothing is re-tried. Compiler flags, hugepages, DRC cache sizing and parallelisation, the guest display path, frameskip, alternative vehicles, turbo bins, scheduler quantum, the guest side's 0:1 exchange rate. Also records what was **reopened**: the REX3 rasteriser was closed in error and is the largest single item in the project. |
| [lab/HARD-PROBLEM-METHODOLOGY.md](lab/HARD-PROBLEM-METHODOLOGY.md) | **How we attack hard/uncertain problems**: acceptance-test-first, diverge→gate→converge→verify, and the **parallel-bounded-agents-from-different-angles** pattern — many sandboxed agents at default caps, first clean solution wins, kill + salvage the rest. Contrast with `ADD-NEW-OS-PLAYBOOK.md` (known path). |
- [`lab/simultaneous-OS-install.md`](lab/simultaneous-OS-install.md) — running two OS integrations at once: publish the stream first, claim ports/slots, drive via QMP, land without collisions, checklist
| [lab/tile-resolution-responsiveness.md](lab/tile-resolution-responsiveness.md) | Does raising a station's resolution on the unaccelerated `-vga std` path hurt responsiveness? Measured A/B: guest packed-framebuffer blit keeps up 1:1; cost is capture+encode+egress+decode (pixel-count-bound), which guest 2D accel cannot reduce. Per-station KEEP/CAP verdicts + the "max responsive resolution per class" rule + win311 hi-res options. |
| [lab/research/workflow-friction-2026-08.md](lab/research/workflow-friction-2026-08.md) | **IMPLEMENTED 2026-08-17: workflow friction audit of ten days of agent transcripts, and the plan that shipped the same day** — box-sync drift, manifest clobbering, duplicate sessions, no staging, SSH tax — closed by deploy-from-commit (`box-deploy.sh`/`box-install.sh`), UI staging (`stage.sh`), `/data` visible in CT950 + `labrun`, session identity/claim registry (`kh-session.sh`/`kh-claim.sh`/`labctl who`), full-stack-per-worker (`wt.sh`), `here.sh`. §5 maps each proposal to its commits and what was deliberately left undone. |
| [lab/research/webgl-gallery-scene/](lab/research/webgl-gallery-scene/README.md) | **Promoted WebGL museum / SceneV2 research and delivery record** (2026-07-27–28): the registry-driven parametric hall now serves `/museum`; the former box-primitive scene was removed. Includes art direction, hardware matrix, model roadmap, live-screen architecture, QA-lap tooling, and the six-angle research synthesis. |
| [lab/research/low-latency-input/](lab/research/low-latency-input/README.md) | Per-OS input-latency spike/plan notes (9front, OS/2, QEMU transport, QNX, Solaris, TempleOS, Win16/9x) plus the cross-OS measurement-and-host methodology. |
| [lab/research/pdp11-add.md](lab/research/pdp11-add.md) | **Candidate study (research only): a DEC PDP-11 exhibit.** Why SIMH is the only viable backend (QEMU has no target; MAME has only the T-11), the three streaming paths with the kiosk recommended, the OS/licensing matrix (Unix V6 free, 2.11BSD, Mentec-licensed RT-11/RSX/RSTS, GT40 vector Lunar Lander), and the integration sketch. |
| [lab/research/alpha-nt-add.md](lab/research/alpha-nt-add.md) | **Candidate study (research only): Windows NT / 2000 on DEC Alpha.** FEASIBLE, Tier 3 — ES40-Emu/es40 built on labhost, ARC/AlphaBIOS flashed, and Windows 2000 RC2 for Alpha driven into its file-copy phase, framebuffer-proven at every step. QEMU's Alpha target is closed (a stub `>>>` that answers `got: <cmd>`); AlphaVM has no VGA. Recommends ONE station with the checkpoint captured at the AlphaBIOS screen, since the exhibit lives in the boot path, not the desktop. Records the RC2 timebomb, the corrupt-ISO trap, and a permanently saturated core.
| [lab/research/alpha-second-os-candidates.md](lab/research/alpha-second-os-candidates.md) | **Candidate survey (desk research only): a SECOND OS on the `w2kalpha` ES40 machine.** What "the same emulated machine" fixes (Tsunami/21264, S3 Trio64, sym53c810, PS/2, SRM+AlphaBIOS in one flash), upstream es40's graphics-capable guest list, and per-candidate media/licensing for Tru64 5.1B, OpenVMS Alpha 8.4-2L1 (VSI Alpha licences ended March 2025), NetBSD/alpha 10.1, NT 4.0 Alpha, Win2000 AXP64 2210, OpenBSD and Red Hat 7.2 alpha. Recommends NetBSD first as runtime proof, Tru64 as the exhibit — and one more saturated core as the ceiling. |
| [lab/SESSION-HANDOVER-2026-08-10-evening.md](lab/SESSION-HANDOVER-2026-08-10-evening.md) | **CURRENT HANDOVER.** Live labhost state (five stations stopped on purpose, two de-bridging spike arms running, a serve-manifest overlay that blocks `git push` until withdrawn), the migration at 15/28 and why it is paused, the de-bridging CPU ceiling that passed the decision gate (147% -> 102% of a core), the four `migrate-tile.sh` bugs and the three live stations they damaged, what is known-broken with diagnosis, and the rules the day bought. |
| [lab/SESSION-HANDOVER-2026-08-10-trixie.md](lab/SESSION-HANDOVER-2026-08-10-trixie.md) | **Current session handover — the bookworm → trixie GUEST migration.** 3 of 28 kiosks migrated; the two-base suite system, `migrate-tile.sh`, coldboot snapshots, the media archive, MAME ccache (3.35× on the second build) and the labhost checkout. Carries the traps that cost the most: a builder that reported success while installing nothing, a chroot that unmounted the host's `/dev/pts`, a qcow2 image lock `pve-qemu-kvm` does not enforce, and three gates that passed by not looking. |
| [lab/SESSION-HANDOVER-2026-08-10.md](lab/SESSION-HANDOVER-2026-08-10.md) | Session handover (Xerox wave). 59 production stations; the Xerox wave (Alto, Star, Daybreak) plus the Iris SGI Indy R4400 and the NeXTSTEP absolute-pointer promotion. Carries the integration hazards a parallel station wave hits — wholesale manifest publishing, generated files that auto-merge cleanly and are wrong, ordering collisions — and the labhost state (cgroup outage, the stopped `amiga` station and why its watcher must not be enabled yet). |
| [lab/research/longhorn-add.md](lab/research/longhorn-add.md) | **Candidate study (research only): pre-reset Windows Longhorn and the WinFS question.** WinFS was never a filesystem and never bootable — it was a SQL-Server-derived storage service on NTFS, proven by mounting a real 4074 install. Tier 3: boots under plain KVM first try and takes a stock `usb-tablet`, but costs 1.09 GB RSS and a full core at idle (3.1× `winxp`) and WinFS is invisible to a visitor. Records the per-build WinFS matrix, the `-vga cirrus`/`-smp 1`/IDE-only constraints, and why the prebuilt 4074 VDI cannot hold a session. |
| [lab/research/vom-reference.md](lab/research/vom-reference.md) | **The Virtual OS Museum as a research reference** — 1703 OS installations over 922 families and 295 platforms, each with a working emulator config, plus an attribution index of 148 emulators and 116 pre-installed images with upstream URLs. **First stop for any new candidate's media gate.** Read the licence boundary first: their scripts/metadata are CC BY-NC-SA and this repo is MIT + public, so it is a reference to read, never a source to copy. |
| [lab/research/xerox-add.md](lab/research/xerox-add.md) | **Candidate study (research only): Alto, Star (8010 "Dandelion") / Pilot, and Daybreak (6085) / ViewPoint / GlobalView.** All three feasible, none blocked on media; ship `gvwin` first (Tier 2, 0.19 GB, no new emulator), then `alto`. The Star is gated on one 30-minute speed measurement. Records that MAME's `alto2` verifies clean but never boots, that Draco was misread as stalled when MP 8000 is Pilot's normal run state, and that ViewPoint is unusable without a Xerox Level-V macro row (`Tab` is not NEXT). |
| [lab/research/home-computer-candidates.md](lab/research/home-computer-candidates.md) | **Candidate study (research only): the Commodore line (KIM-1 → PET → VIC-20 → C64/128 → 264 → Amiga 1000-4000), the British machines (Dragon, Oric, BBC/Acorn/ARM, Sinclair ZX80→QL) and the GDR machines (KC 85, KC 87, Z1013, LC 80, A5105).** Driver names verified against labhost's MAME 0.276; the variant policy for cosmetic vs regional-ROM machines; one parameterised builder instead of thirty scripts; and the measured finding that the lineup is memory-bound (1.2 GB mean RSS per kiosk, ~40 GB available) long before it is effort-bound. |

## guests/ — one merged note per guest OS

Each file is the consolidated build/station/automation record for one guest
(station notes + install notes + recipes; merge points marked with HTML comments).
Reproducible builders live in `scripts/build-guests/tiles/<os>.sh`.

| Doc | Guest |
|---|---|
| [guests/amiga500.md](guests/amiga500.md) | Real 68000 Amiga 500 via the FS-UAE kiosk. |
| [guests/apple2.md](guests/apple2.md) | Apple II kiosk. |
| [guests/aros.md](guests/aros.md) | AROS x86 (AmigaOS re-implementation) under QEMU — distinct from amiga500. |
| [guests/atarist.md](guests/atarist.md) | Atari ST kiosk. |
| [guests/c64.md](guests/c64.md) | Commodore 64 (VICE) — the reference kiosk implementation. |
| [guests/daybreak.md](guests/daybreak.md) | Xerox 6085 "Daybreak" running ViewPoint 2.0.5, via the Dwarf/Draco Mesa emulator in a bare-X kiosk. |
| [guests/haiku.md](guests/haiku.md) | Haiku station (ssh exec channel wired). |
| [guests/helenos.md](guests/helenos.md) | HelenOS 0.14.1 LiveCD station — absolute pointer via usb-tablet. |
| [guests/kolibrios.md](guests/kolibrios.md) | KolibriOS station — absolute-pointer notes (live 2026-07-13). |
| [guests/macos.md](guests/macos.md) | Historical macOS OpenCore/Sequoia recipe; current station is a showcase poster. |
| [guests/msdos-win1.md](guests/msdos-win1.md) | MS-DOS + Windows 1.0 station. |
| [guests/nextstep.md](guests/nextstep.md) | NeXTSTEP R&D notes — NOT LIVE, install blocked. |
| [guests/ninefront.md](guests/ninefront.md) | 9front (Plan 9 fork) station — warpd agent on :57793. |
| [guests/os2warp.md](guests/os2warp.md) | OS/2 Warp 4 station (TCG-only; KVM triple-faults). |
| [guests/qnx.md](guests/qnx.md) | QNX 6.5 station. |
| [guests/reactos.md](guests/reactos.md) | ReactOS station. |
| [guests/riscos.md](guests/riscos.md) | RISC OS station. |
| [guests/sailfish.md](guests/sailfish.md) | Sailfish OS — bochs-drm KMS GUI recipe (authoritative) + earlier console/VirtualBox routes as appendices. |
| [guests/solaris.md](guests/solaris.md) | Solaris 10 x86 with real CDE; in-guest warpd agent documented in `streamhost/guest-agents/solaris/README.md`. |
| [guests/templeos.md](guests/templeos.md) | TempleOS station. |
| [guests/win11.md](guests/win11.md) | Windows 11 unattended install + the RDP-bridge exhibit (VM 900 since deleted — showcase-only). |
| [guests/win9x.md](guests/win9x.md) | Windows 95/98 (+ the Win 3.11 material) — KVM recipe & root-cause, perf tuning, as-built image manifests. |
| [guests/winxp.md](guests/winxp.md) | Windows XP Pro SP3 seed build. |
| [guests/UNDOCUMENTED.md](guests/UNDOCUMENTED.md) | Stub index for the stations without a dedicated doc (build-script + manifest pointers). |

## catalog/ — what the museum holds and could hold

| Doc | What it is |
|---|---|
| [catalog/os-media-catalog.md](catalog/os-media-catalog.md) | Verified install-media + boot-recipe catalog (69 OS entries, licensing posture, difficulty scoring, ranked build order). |
| [catalog/software-catalog.md](catalog/software-catalog.md) | In-guest era software/games roster per guest. |

System-level architecture docs are crate-local: streamhost's design docs live in
`streamhost/docs/`, the UI's in `spa/` (there is no separate `docs/architecture/`
directory).

## history/ — historical snapshots

Point-in-time status docs and finished handoffs, retired from the live tree
once the work they describe was done. Kept for context, not authoritative —
each carries a header noting the date it describes. See also the other
agents' snapshots moved from `docs/guests/`, `docs/catalog/`,
`streamhost/docs/`, and `scripts/`.

| Doc | What it was |
|---|---|
| [history/migration-reference.md](history/migration-reference.md) | Pre-wipe known-good config of the old SATA box — baseline the NVMe migration diffed against. |
| [history/hw-validation-log.md](history/hw-validation-log.md) | Acceptance/burn-in log of the used SYS-5019D chassis (SEL audit, ECC, soak). |
| [history/ARTIFACT-CI-CD-PLAN.md](history/ARTIFACT-CI-CD-PLAN.md) | Plan to put the MAME binary, patch stack and goldens under real CI/CD — written as a gap analysis, not yet executed when archived. |
| [history/REBUILD-DELTAS-2026-07-15.md](history/REBUILD-DELTAS-2026-07-15.md) | De-duplicated pitfall ledger from the NVMe rebuild-from-repo campaign. |
| [history/REPRO-GAP-CLOSURE.md](history/REPRO-GAP-CLOSURE.md) | Worklist tracking the repo-reproducibility gap to green through L2. |
| [history/TECH-DEBT-INVENTORY.md](history/TECH-DEBT-INVENTORY.md) | Synthesis of a six-audit tech-debt/tooling-gap campaign. |
| [history/irix-tile-issue20-handoff.md](history/irix-tile-issue20-handoff.md) | Long-running IRIX station (issue #20) investigation handoff/resume doc. |
| [history/ENCODER-INPROCESS-FINDINGS.md](history/ENCODER-INPROCESS-FINDINGS.md) | In-process libx264 encoder latency root-cause findings (moved from `streamhost/docs/`). |
| [history/os2warp-promote-notes.md](history/os2warp-promote-notes.md) | OS/2 Warp promotion session log (moved from `scripts/coldboot/`). |

## Top level

| Doc | What it is |
|---|---|
| [REPRODUCE-QUICKSTART.md](REPRODUCE-QUICKSTART.md) | Fresh-clone entry point: UI build, full-labhost reading order, external inputs, and known limits. |
| [ARCHITECTURE.md](ARCHITECTURE.md) | **Start here for how the system works.** The streaming path end to end, the daemon's responsibilities, the station/registry model, and a map into every deeper doc. |
| [GUEST-TIERS.md](GUEST-TIERS.md) | **The five structurally different kinds of guest** — direct QEMU (29), emulator bridge (28), host-native MAME with no QEMU at all (`irix`), the two-sibling-VM X bridge (`openvms`), and the posters. Tier is *derived*, not declared, so this gives the derivation, the membership lists, the inner emulator per kiosk, and a per-guest table generated from the registry. |
| [IO-PATHS.md](IO-PATHS.md) | **Pointer, keyboard, video and sound, per tier, as tables.** Video and audio converge on one path; input diverges into eight sinks — which is why nearly every "it feels wrong" report is an input report. Includes the frame-quantisation rule that makes keyboard pacing a *gap* problem rather than a rate problem, and the 17 stations that are unpointable by design. |
| [OVERHEAD.md](OVERHEAD.md) | **What each tier and path costs** — latency, CPU, memory — assembled from figures already written down elsewhere in the repo, each cited to its file. Says "not measured" instead of interpolating, and marks the encode numbers that predate libyuv and damage-scoped conversion. The headline: input is ~2% of the round trip, video is >85%. |
| [PUBLIC-GALLERY.md](PUBLIC-GALLERY.md) | **The gallery on the public internet** (`gallery.example.com`): why a TCP tunnel could not carry the QUIC video and what the UDP relay does instead, the three gates a visitor meets (session, passkey, media-plane ticket), invites and roles, secret rotation, and how to reproduce and test the whole path. The LAN origin is untouched by all of it. |
| [INPUT-LATENCY.md](INPUT-LATENCY.md) | Input→visual-feedback latency: current LAN budget (tables + graphs) and the architectural levers to push it lower. |
| [NAMING.md](NAMING.md) | Why the project is Kernel Hive but `streamhost` and `labctl` keep their own names in the code and on labhost. |
| [RELEASE-NOTES.md](RELEASE-NOTES.md) | **Generated, never hand-edited.** Week-by-week changelog derived from git history by `scripts/release-notes.py` (`make release-notes`); weeks end Sunday 09:00 Europe/Helsinki, grouped by commit scope into stations, UI, daemon, retronet, tooling and docs. |

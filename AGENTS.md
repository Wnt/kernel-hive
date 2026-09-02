# Kernel Hive lab — operating rules

Single-box Proxmox home-lab ("living computer museum"): 63 registry entries — 61
`streamhost` stations + 2 posters. Rust daemon → React SPA. Repo
https://github.com/Wnt/kernel-hive is **public**; this dir is the git root.

**Run `scripts/dev/here.sh` first, every session** — where you are, what is
deployed, who else is here, what is staged, what is stopped, what to run next.

This file is loaded into every agent's context, so it carries only the rules that
prevent damage, in one line each. **The reasoning, exceptions and the incident
behind each rule are in [`docs/lab/OPERATING-RULES.md`](docs/lab/OPERATING-RULES.md)
— read it before your first write to the box**, and whenever a rule below looks
arbitrary. Do not re-expand this file; put the detail there.

## The rules

1. **Addresses are scrubbed placeholders** (`192.0.2.10`, `labhost`, `example.com`,
   MAC `02:00:00:00:00:01`). Never "fix" one; never commit a real IP, host, MAC,
   serial or domain. Sole exception: the gallery domain `kernelhive.madekivi.fi`,
   committed on purpose — do not scrub those links. Real values live in gitignored
   `registry/local.env`.
2. **`ssh lab '<cmd>'` is the one door** to the box, as root. `/data/*` is
   bind-mounted into CT950 — read/Edit/grep those files directly. Only process
   control (`systemctl`, `qm`, `pct`, guards, kills) goes through the door.
   Multi-line remote work → `scripts/dev/labrun <<'EOF' … EOF`; never nest
   `ssh lab`; loops call `ssh -n`. Other guests on this hardware belong to other
   projects — leave them alone.
3. **Every task gets its own full stack**: `scripts/dev/wt.sh new <name>` (worktree
   + sandbox + build + staging slot + claim). Fix problems in your own stack, never
   as a workaround in someone else's. The shared clone holds no uncommitted edits,
   ever — a hook refuses writes there. Operator's "use shared clone" lifts it
   (`touch .claude/shared-clone-ok`); "back to sandboxes" and `/clear` remove it.
4. **Never experiment on a live station.** Clone under `/data/vms/sandbox/`, keep
   the SAME device set (`loadvm golden` requires it), namespace every dir, VMID,
   socket and port.
5. **Kill and mount through the guards** — `clone-guard`, `chroot-guard`. Never
   `pkill -f` from `ssh lab`: it matches your own ssh and kills your session.
   Resolve processes via `/proc/<pid>/exe`, never a cmdline grep.
6. **Recapture a golden only via `ssh lab 'checkpoint-guard recapture <station>'`.**
   Never hand-roll it, and never retire a golden before its replacement is
   restore-proven — checkpoint + binary + device set are ONE combination.
7. **Claim shared things atomically** (displays, taps, IPs, chains, cores, ports,
   VMIDs) with `kh-claim`/`$KH_SESSION`. Never check-then-create; fail loudly
   instead of falling back — "it exists" is not "it is mine".
   `ssh lab 'labctl who'` answers whose it is.
8. **Teardown is part of "done"** — report what you released and the check that
   proved it.
9. **The framebuffer is the only proof** a guest reacted. Never infer from logs.
10. **Green before done** — the quality gate for every language you touched, or
    report **BLOCKED** with the failing command and output. Never hand-edit a
    generated file; never silence your own breach with a `size-exclusions.json`
    entry. Commands: [`docs/lab/AGENT-CI-EXIT-RULE.md`](docs/lab/AGENT-CI-EXIT-RULE.md).
11. **A push is not a deploy.** `git push origin main`, then
    `scripts/dev/box-deploy.sh --apply`; restarts are a separate decision.
12. **New work lands host-native** — direct framebuffer capture + input forwarding.
    A trixie kiosk bridge is a throwaway PoC, never what ships; the 28 surviving
    bridges are legacy to convert, not a template. Source your own install media
    and ROMs; the operator supplies Windows licensing only.

## Where to look

| I need to… | Go to |
|---|---|
| Start a session | `scripts/dev/here.sh` — first, every time |
| The reasoning behind a rule above | [`docs/lab/OPERATING-RULES.md`](docs/lab/OPERATING-RULES.md) |
| Whose rig/claim is this | `ssh lab 'labctl who'` |
| Preview a UI/registry change before it is live | `scripts/dev/stage.sh` → `/staging/<session>/` |
| Deploy a pushed commit / see what the box runs | `scripts/dev/box-deploy.sh` (plan) / `--apply` / `--status` |
| Restart the fleet without taking the gallery down | [`docs/lab/FLEET-ROLLOUT.md`](docs/lab/FLEET-ROLLOUT.md) — `scripts/dev/fleet_rollout.py` (plan) / `--apply` |
| What a word means (station, seed, checkpoint, scene…) | [`docs/GLOSSARY.md`](docs/GLOSSARY.md) |
| Understand how any of this works | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — tiers, I/O paths, costs |
| Drive a guest / run a command in one | [`docs/lab/LABCTL.md`](docs/lab/LABCTL.md); start with `labctl facts <tile>` |
| Debug pointer, tap, drag, double-click | [`docs/lab/INPUT-DEBUGGING.md`](docs/lab/INPUT-DEBUGGING.md) |
| Debug keys vanishing or scrambling | [`ADD-NEW-OS-PLAYBOOK.md` §5.1](docs/lab/ADD-NEW-OS-PLAYBOOK.md#51-keyboard-only-exhibits--pacing-layout-and-the-type-in-demo) |
| Debug ANY streaming complaint | [`docs/lab/STREAM-DEBUGGING.md`](docs/lab/STREAM-DEBUGGING.md) — start with the log plane, not a repro |
| Recapture a checkpoint | [`docs/lab/checkpoint-guard.md`](docs/lab/checkpoint-guard.md) |
| Fix a station that freezes or will not connect | `ssh lab 'python3 /data/vms/streamhost/serve/check-stream-tickets.py'` |
| Which emulator runs a given OS, with what settings | [`docs/lab/research/vom-reference.md`](docs/lab/research/vom-reference.md) — BEFORE spending an agent on recon |
| Add a new OS station FAST (10-minute path) | [`docs/lab/ADD-NEW-OS-FASTPATH.md`](docs/lab/ADD-NEW-OS-FASTPATH.md) |
| Add a new OS station | [`docs/lab/ADD-NEW-OS-PLAYBOOK.md`](docs/lab/ADD-NEW-OS-PLAYBOOK.md) |
| Migrate a kiosk to trixie | [`docs/lab/MIGRATION-WAVE-BRIEF.md`](docs/lab/MIGRATION-WAVE-BRIEF.md) |
| Build the daemon, a guest, or the UI | [`scripts/README.md`](scripts/README.md) |
| Work on the public gallery or passkeys | [`docs/PUBLIC-GALLERY.md`](docs/PUBLIC-GALLERY.md). **Never `rm auth-state.json`** |
| Know whether a feature is used, or where a flow breaks | [`docs/ANALYTICS.md`](docs/ANALYTICS.md); `scripts/dev/reach-report.py` |
| Drill into ONE session's journey, or read a flame graph | `/admin/observability` (admin-only); [`docs/lab/TRACE-CONTEXT.md`](docs/lab/TRACE-CONTEXT.md) for how a trace crosses processes |
| Measure performance | [`docs/lab/MEASUREMENT-METHODOLOGY.md`](docs/lab/MEASUREMENT-METHODOLOGY.md) |
| Get a cloud agent onto labhost | [`docs/lab/CLOUD-AGENTS.md`](docs/lab/CLOUD-AGENTS.md) |
| Find anything else | [`docs/README.md`](docs/README.md) |

## Three facts that mislead if you don't know them

- **A station has ONE name**: registry id == `stationDir` == `SH_STATION`, enforced
  by `stations-registry.py`. The serving plane still reads identity from the
  station's own `signaling.json` — the daemon is the authority on the name it
  verifies a ticket against.
- **A station that looks broken may just be stopped or paused** —
  `ssh lab 'labctl ls'`. The fleet is routinely stopped or paused; check for
  in-flight work before starting anything.
- **A fix may not have taken effect**: streamhost deploys are per-station canaries
  and the fleet is not auto-promoted; UI edits need the bundle redeployed; a
  launcher or geometry change needs the checkpoint **recaptured**; and a push is
  not a deploy — check `scripts/dev/box-deploy.sh --status`.

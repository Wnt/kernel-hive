# Kernel Hive lab — access map & operating rules

**The canonical brief for every coding agent on this repo.** `CLAUDE.md` is a
one-line pointer here.

This file is loaded into *every* agent's context, so it is deliberately a
**router, not a handbook**: the rule and the pointer live here, the reasoning and
the incident live in the linked doc. Keep it that way — prose added here is paid
for once per agent, forever.

Single-box Proxmox home-lab ("living computer museum"): the registry derives
**61 lineup entries — 59 production streamhost tiles and 2 showcase posters**
(`python3 scripts/tiles-registry.py count`; run it, this line has been stale
before). Those 59 fall into five execution tiers —
[`docs/GUEST-TIERS.md`](docs/GUEST-TIERS.md). Streamed by the Rust `streamhost`
daemon to a React SPA. Repo: https://github.com/Wnt/kernel-hive (private; this
dir is the git root).

## Placeholders — read before trusting any address here

Every IP, hostname and domain in this repo's docs and committed config is a
**scrubbed placeholder**: `192.0.2.10`/`192.0.2.11` (the box + CT950),
`198.51.100.x`, `203.0.113.x` (forwarder VPS), `labhost`/`labhost.lan`,
`example.com`/`gallery.example.com`/`tunnel.example.com`, MAC
`02:00:00:00:00:01`, disk serial `EXAMPLE0000000000`. Do not `ssh`/`curl` one
expecting it to resolve, and **do not "fix" one** — it is not wrong.

Real values live only in gitignored operator files, never in the repo:
`registry/local.env` (template `registry/local.env.example`), loaded by
`scripts/lib/local-env.sh`. Precedence: explicit flag / env var >
`registry/local.env` > repo placeholder. See
[`registry/README.md`](registry/README.md).

**Never commit real addresses, hostnames, MACs, serials or domains.** Other
gitignored operator-local categories: SSH keys, PKI material, `uptoken`,
`unifitoken`, `spa/src/data/credentials.ts`, `docs/gallery-credentials.md`.

## Reaching the lab box

`ssh lab` is **the one door**, from a LAN workstation and a cloud agent VM
alike. It is a plain SSH command channel: stdout and stderr stay separate, the
guest's exit code is your exit code, and complex one-liners, pipelines,
heredocs and multi-megabyte output all work verbatim.

Running in a cloud VM? Same `ssh lab`, different plumbing (dial-out reverse
tunnel; no inbound port on the home WAN). If it fails, read
[`docs/lab/CLOUD-AGENTS.md`](docs/lab/CLOUD-AGENTS.md) before working around it
— there is no second route in.

SPA: `https://192.0.2.10:8443` (LAN-only; from a cloud VM go through the box or
an `ssh -L` forward). The same server runs a session-gated public listener —
[`docs/PUBLIC-GALLERY.md`](docs/PUBLIC-GALLERY.md). **Consequence for tile
work:** every tile runs with `SH_SESSION_KEY`, so use the `path` from
`/signal/<tile>.json` verbatim; a hardcoded `/wt` is refused
(`SESSION_REJECTED`).

| Machine | What it is | How to run a command |
|---|---|---|
| **`labhost`** — the box | Proxmox host. Owns the tiles, the daemon, the HTTPS origin, `/data`. | `ssh lab '<cmd>'` as root — the only door |
| **Tiles** (~59) | Raw QEMU/MAME/emulator processes under `streamhost@<tile>`, **not** Proxmox VMs — they never appear in `qm list` | `ssh lab 'labctl exec <tile> "<cmd>"'` |
| **CT 950 `osgallery-dev`** | LAN dev container (node/npm, Playwright, VNC browser). **No `/data` mount** — host-side checks must run on the host | `ssh lab 'pct exec 950 -- <cmd>'` |
| **Other guests** | Unrelated projects share this hardware. **Leave them alone.** | — |

Before assuming a tile is broken, check whether it is simply **stopped**:
`ssh lab 'labctl ls'`. The fleet is routinely quiesced; check for in-flight work
(`ps -eo pcpu,comm --sort=-pcpu | head`) before starting anything.

## Tiles

Live tiles: `/data/vms/streamhost/tiles/<tile>/` — `qemu-streamhost.sh`
(launcher, documents the exact device set), `qmp.sock`, `tile.env`, golden qcow2
with an internal `golden` snapshot (`loadvm golden` = reset; `savevm golden` =
re-bake; **device set must match**). One `streamhost@<tile>` unit per tile;
source in `streamhost/`, built ON the box. Manifest generated from
`registry/tiles/`; emit via `streamhost/tiles-manifest.sh`, ordered boot via
`streamhost/bring-up-all.sh`.

**Start every tile task with `ssh lab 'labctl facts <tile>'`.** Channels,
what each proves, and the traps: [`docs/lab/LABCTL.md`](docs/lab/LABCTL.md).
`labctl` is self-documenting — run it for the command list.

### Clones, shared resources, teardown

- **NEVER experiment on a live tile.** Clone under `/data/vms/soltest/`, keep
  the SAME device set (`loadvm golden` requires it), and namespace everything
  (dirs, VMIDs, sockets, ports) so concurrent agents cannot collide.
- **Every clone kill/stop goes through `clone-guard`** (`scripts/lib/clone-guard.sh`
  == box `/usr/local/bin/clone-guard`, byte-identical). It fail-closes on any
  production target. [`docs/lab/clone-guard.md`](docs/lab/clone-guard.md)
- **Chroot mounts go through `chroot-guard`** — never `mount --rbind /dev` by
  hand. The host's `/dev` is `shared:2`, so a hand-rolled teardown propagates
  outward and unmounts the host's `/dev/pts`.
- **Shared things must be claimed atomically, and the claim must be the proof.**
  Displays, taps, host IPs, iptables chains, core pairs, ports, VMIDs: claim via
  the resource itself (`xvfb-alloc` binds the X socket, `tapnet.sh` uses
  `mkdir`, `iptables -w`), never check-then-create. Namespace per rig. **Fail
  loudly instead of falling back — "it exists" is not "it is mine".**
- **Teardown is part of "done" and must be stated in the report**: what you
  released, and the check that proved it. Resolve processes through
  `/proc/<pid>/exe`, never a cmdline grep — a `grep` over `/proc/*/cmdline`
  matches the shell running it and once reported 9 strays when the answer was 0.
- **`pkill -f <pattern>` from `ssh lab` can kill your own session** (the remote
  shell's command line contains the pattern; exit 144 looks like a network
  fault). Kill by pidfile or resolve the PID first.

## Debugging playbooks — reach for these BEFORE iterating blind

Each exists because a session burned hours re-deriving it.

| Symptom | Read |
|---|---|
| Pointer/tap/drag/double-click feels wrong | [`INPUT-DEBUGGING.md`](docs/lab/INPUT-DEBUGGING.md) — which of three paths a press takes (a stylus is NOT the touch path) |
| Pen/touch: what did the browser actually see? | `ssh lab 'python3 /data/vms/streamhost/serve/pen-trace.py --since-min 15'` |
| A tile streams then freezes, or refuses to connect | `ssh lab 'python3 /data/vms/streamhost/serve/check-stream-tickets.py'` — catches SPA-id vs `SH_TILE` divergence |
| Public gallery, passkeys, invites | [`PUBLIC-GALLERY.md`](docs/PUBLIC-GALLERY.md). **Never `rm auth-state.json`** — passkeys cannot be regenerated; `scripts/serve/reset-auth.sh` is the guarded path |
| Guest did or did not react | `labctl shot <tile>` — the framebuffer is the only proof. Never infer from logs |
| Adding a new OS tile | [`ADD-NEW-OS-PLAYBOOK.md`](docs/lab/ADD-NEW-OS-PLAYBOOK.md) |
| Typed characters vanish or scramble | Playbook [§5.1](docs/lab/ADD-NEW-OS-PLAYBOOK.md#51-keyboard-only-exhibits--pacing-layout-and-the-type-in-demo) — an emulator samples input once per emulated FRAME, so the release→press GAP is what must survive (mpf2: 0 ms → 0/16 keys, 16 ms → 16/16). Set `SH_KEY_MIN_HOLD_MS`/`SH_KEY_MIN_GAP_MS` from the frame period |
| `PTY allocation failed` on new logins | `devpts` is gone: `ssh lab 'mount -t devpts devpts /dev/pts -o rw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000'`. Cause and prevention: `chroot-guard` |
| A fix appears not to have taken effect | The tile may run an OLD binary — streamhost deploys are per-tile canaries and the fleet is not auto-promoted. SPA edits need the bundle rsynced; a launcher or X-geometry change needs the golden RE-BAKED |
| Migrating a bridge tile to trixie | [`MIGRATION-WAVE-BRIEF.md`](docs/lab/MIGRATION-WAVE-BRIEF.md) first, then [`BRIDGE-TRIXIE-MIGRATION.md`](docs/lab/BRIDGE-TRIXIE-MIGRATION.md) |

## Hard guardrails

- **`riscos`/`macos`** are the showcase-only posters. `win11` is a **live tile**,
  not a poster. `lifecycle` in the registry is the authority.
- During measurement-quiesce windows the only essential guests are CT950 and the
  tile(s) under test.
- **Integrate continuously**: merge to `main` early and **always
  `git push origin main`** after landing commits.
- Never echo or log `~/Downloads/humanify-token`.
- Always use the latest STABLE release of tools/ISOs/images.

## Code quality gate — green before done

**Every agent whose branch is intended to merge MUST make the gate green before
reporting "done".** Cannot get it green → report **BLOCKED** with the failing
command and output. Red is not done; "it's a small change" is not an exemption.
You owe the gate for the language(s) you touched, plus the two cross-cutting
gates. Full reference: [`AGENT-CI-EXIT-RULE.md`](docs/lab/AGENT-CI-EXIT-RULE.md).

- **TS/JS** — `cd spa && npx eslint . --max-warnings=0 && npx knip` (+ `npm run build`)
- **Rust** — `cd streamhost && cargo fmt --all --check && cargo clippy --all-targets -- -D warnings` (+ `cargo test --workspace`)
- **Python** — `ruff check scripts && ruff format --check scripts`
- **Bash** — `shfmt -d $(scripts/lint/shell-sources.sh) && shellcheck $(scripts/lint/shell-sources.sh)` — use that helper, never a bare `git ls-files`
- **file-size budget (all)** — `node scripts/check-file-size.mjs --strict`
- **generated-file drift (all)** — `make tile-registry-check`. Never hand-edit a
  generated file; edit the registry source and `make tile-registry-generate`

`size-exclusions.json` is a **bidirectional ledger**: a file that drops under its
hard cap FAILS until its stale exclusion is deleted. **Do not add an exclusion to
silence a breach you caused** — fix the breach.

The two file-list gates take `--committed` (pre-push: tracked ∪ staged) versus
the default (tracked ∪ staged ∪ untracked-not-ignored). Both halves are
load-bearing; the reasoning is in the full reference.

Mirror it locally before pushing with `.claude/hooks/pre-push-gate.sh` —
**enable it in every clone/worktree, it is not on by default**:
`ln -sf ../../.claude/hooks/pre-push-gate.sh .git/hooks/pre-push`. It runs a
language stage only when that language changed, and says out loud when a stage
is skipped. `GATE_FULL=1` forces the full run.

## Building

- **The box's own checkout — `/data/kernel-hive`.** The only place a host-side
  builder should run from. Manage with `scripts/dev/box-repo.sh`
  (`status`/`sync`/`init`/`path`). It is a **clean mirror, never edited in
  place**, advanced only by an explicit `sync` — so a fetch cannot swap
  `build-guests/` out from under a 40-minute bake. Quote the commit `status`
  prints in any build report. **Never hand-copy a builder into a scratch dir**:
  a copy has no version and goes stale in silence.
- **Rust daemon**: edit locally → rsync to box → `cargo build --release` there →
  install → restart affected units. One-shot: `scripts/dev/build-deploy.sh
  [tile…|--all|--changed-only]`. The release binary is SHARED by all production
  tiles, so a bare run restarts EVERY tile — pass an explicit low-traffic tile
  when verifying.
- **Guest agents**: cross-toolchains live ON the box — `i686-w64-mingw32-gcc`,
  OpenWatcom **1.9** (`/root/watcom`; V2 crashes on Warp 4 GA), Solaris agents
  are in-guest Python 2.6.
- **SPA**: `spa/` (Vite/React), bundle deployed to the box webroot via
  `scripts/serve/`. Live-box e2e suite `tests/e2e-live/` — never in CI.

## Docs

[`docs/README.md`](docs/README.md) indexes the tree. Start points:
[`ARCHITECTURE.md`](docs/ARCHITECTURE.md) (how the system works),
[`GUEST-TIERS.md`](docs/GUEST-TIERS.md) (the five kinds of guest),
[`IO-PATHS.md`](docs/IO-PATHS.md) (pointer/keyboard/video/sound per tier),
[`OVERHEAD.md`](docs/OVERHEAD.md) (what each tier costs),
[`streamhost/docs/`](streamhost/docs/) (daemon design, bridge protocol, `SH_*`
reference), [`scripts/README.md`](scripts/README.md) (ops tooling),
`docs/guests/<os>.md` (per-guest notes),
[`MEASUREMENT-METHODOLOGY.md`](docs/lab/MEASUREMENT-METHODOLOGY.md) (how this lab
measures, and the incident behind each rule).

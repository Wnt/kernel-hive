# Kernel Hive lab — operating rules

**The canonical brief for every coding agent on this repo.** `CLAUDE.md` points
here.

This file is loaded into **every** agent's context, so it carries only two
things: **rules that prevent damage**, and **pointers to where the detail is**.
Anything else added here is paid for once per agent, forever — put it in the
linked doc instead.

Single-box Proxmox home-lab ("living computer museum"). 61 registry entries —
59 production streamhost tiles + 2 posters (`python3 scripts/tiles-registry.py
count`). Rust `streamhost` daemon → React SPA. Repo:
https://github.com/Wnt/kernel-hive (private; this dir is the git root).

---

## The rules

**Addresses.** Every IP, hostname and domain in this repo is a **scrubbed
placeholder** (`192.0.2.10`, `labhost`, `example.com`, MAC `02:00:00:00:00:01`,
serial `EXAMPLE0000000000`). Do not `ssh`/`curl` one expecting it to resolve and
**do not "fix" one**. Real values live only in gitignored `registry/local.env`.
**Never commit a real address, hostname, MAC, serial or domain.** Also
gitignored: SSH keys, PKI, `uptoken`, `unifitoken`,
`spa/src/data/credentials.ts`, `docs/gallery-credentials.md`.

**The box.** `ssh lab '<cmd>'` is the one door, as root, from a LAN workstation
and a cloud VM alike. stdout/stderr stay separate and the guest's exit code is
yours. CT950 (`ssh lab 'pct exec 950 -- <cmd>'`) is the dev container and has
**no `/data` mount**, so host-side checks run on the host. Other guests on this
hardware belong to unrelated projects — **leave them alone**.

**Never experiment on a live tile.** Clone under `/data/vms/soltest/`, keep the
SAME device set (`loadvm golden` requires it), and namespace every dir, VMID,
socket and port so concurrent agents cannot collide.

**Kill and mount through the guards.** Every clone kill/stop goes through
`clone-guard`; every chroot mount through `chroot-guard` (the host's `/dev` is
`shared:2`, so a hand-rolled teardown unmounts the host's `/dev/pts`). Never
`pkill -f` from `ssh lab` — it matches your own ssh command line and kills your
session. Resolve processes through `/proc/<pid>/exe`, never a cmdline grep,
which matches the shell running it.

**Claim shared things atomically, and make the claim the proof.** Displays,
taps, host IPs, iptables chains, core pairs, ports, VMIDs. Never
check-then-create; namespace per rig; **fail loudly instead of falling back —
"it exists" is not "it is mine".**

**Teardown is part of "done"** and must be stated in the report: what you
released and the check that proved it.

**The framebuffer is the only proof** a guest reacted. Never infer from logs.

**Green before done.** Make the quality gate green for the language(s) you
touched, or report **BLOCKED** with the failing command and output. Red is not
done. Never hand-edit a generated file. Never add a `size-exclusions.json` entry
to silence a breach you caused — it is a bidirectional ledger and a stale entry
fails too.

- TS/JS `cd spa && npx eslint . --max-warnings=0 && npx knip` (+ `npm run build`)
- Rust `cd streamhost && cargo fmt --all --check && cargo clippy --all-targets -- -D warnings`
- Python `ruff check scripts && ruff format --check scripts`
- Bash `shfmt -d $(scripts/lint/shell-sources.sh) && shellcheck $(scripts/lint/shell-sources.sh)`
- All `node scripts/check-file-size.mjs --strict` and `make tile-registry-check`

**Integrate continuously** — merge to `main` early and always `git push origin
main`. Never echo or log `~/Downloads/humanify-token`.

---

## Where to look

| I need to… | Go to |
|---|---|
| Understand how any of this works | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) → tiers, I/O paths, costs |
| Drive a guest / run a command in one | [`docs/lab/LABCTL.md`](docs/lab/LABCTL.md). Start with `labctl facts <tile>`; `labctl` prints its own usage |
| Debug pointer, tap, drag, double-click | [`docs/lab/INPUT-DEBUGGING.md`](docs/lab/INPUT-DEBUGGING.md) |
| Debug keys vanishing or scrambling | [`ADD-NEW-OS-PLAYBOOK.md` §5.1](docs/lab/ADD-NEW-OS-PLAYBOOK.md#51-keyboard-only-exhibits--pacing-layout-and-the-type-in-demo) |
| Fix a tile that freezes or won't connect | `ssh lab 'python3 /data/vms/streamhost/serve/check-stream-tickets.py'` |
| Add a new OS tile | [`docs/lab/ADD-NEW-OS-PLAYBOOK.md`](docs/lab/ADD-NEW-OS-PLAYBOOK.md) |
| Migrate a bridge tile to trixie | [`docs/lab/MIGRATION-WAVE-BRIEF.md`](docs/lab/MIGRATION-WAVE-BRIEF.md) |
| Build the daemon, a guest, or the SPA | [`scripts/README.md`](scripts/README.md); host-side builders run only from `/data/kernel-hive` (`scripts/dev/box-repo.sh`) |
| Work on the public gallery or passkeys | [`docs/PUBLIC-GALLERY.md`](docs/PUBLIC-GALLERY.md). **Never `rm auth-state.json`** — passkeys cannot be regenerated |
| Measure performance | [`docs/lab/MEASUREMENT-METHODOLOGY.md`](docs/lab/MEASUREMENT-METHODOLOGY.md) |
| Get a cloud agent onto the box | [`docs/lab/CLOUD-AGENTS.md`](docs/lab/CLOUD-AGENTS.md) |
| Know why the gate is shaped this way | [`docs/lab/AGENT-CI-EXIT-RULE.md`](docs/lab/AGENT-CI-EXIT-RULE.md) |
| Find anything else | [`docs/README.md`](docs/README.md) |

## Three facts that mislead if you don't know them

- **A tile has ONE name**: registry id == `tileDir` == `SH_TILE`, enforced by
  `tiles-registry.py`. The last two exceptions were renamed 2026-08-10. The
  serving plane still reads identity from the tile's own `signaling.json` — the
  daemon is the authority on the name it verifies a ticket against.
- **A tile that looks broken may just be stopped** — `ssh lab 'labctl ls'`. The
  fleet is routinely quiesced; check for in-flight work before starting
  anything.
- **A fix may not have taken effect**: streamhost deploys are per-tile canaries
  and the fleet is not auto-promoted; SPA edits need the bundle redeployed; a
  launcher or geometry change needs the golden **re-baked**.

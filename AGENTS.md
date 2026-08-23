# Kernel Hive lab — operating rules

**The canonical brief for every coding agent on this repo.** `CLAUDE.md` points
here.

This file is loaded into **every** agent's context, so it carries only two
things: **rules that prevent damage**, and **pointers to where the detail is**.
Anything else added here is paid for once per agent, forever — put it in the
linked doc instead.

Single-box Proxmox home-lab ("living computer museum"). 63 registry entries —
61 production streamhost stations + 2 posters (`python3 scripts/stations-registry.py
count`). Rust `streamhost` daemon → React UI. Repo:
https://github.com/Wnt/kernel-hive (**public**; this dir is the git root).

---

## The rules

**Addresses.** Every IP, hostname and domain in this repo is a **scrubbed
placeholder** (`192.0.2.10`, `labhost`, `example.com`, MAC `02:00:00:00:00:01`,
serial `EXAMPLE0000000000`). Do not `ssh`/`curl` one expecting it to resolve and
**do not "fix" one**. Real values live only in gitignored `registry/local.env`.
**Never commit a real address, hostname, MAC, serial or domain — with ONE
exception: the public gallery domain `kernelhive.madekivi.fi`,** which is not a
secret and is committed on purpose (the release notes link every machine to
`https://kernelhive.madekivi.fi/os/<id>`; inside the SPA the same link is the
relative `/os/<id>`). Do not "scrub" those links. Everything else in this rule
still holds. Also gitignored: SSH keys, PKI, `uptoken`, `unifitoken`,
`spa/src/data/credentials.ts`, `docs/gallery-credentials.md`.

**Labhost.** `ssh lab '<cmd>'` is the one door, as root, from a LAN workstation
and a cloud VM alike. stdout/stderr stay separate and the guest's exit code is
yours. CT950 (`ssh lab 'pct exec 950 -- <cmd>'`) is the dev container this
session runs in and, since 2026-08-17, has `/data/vms`, `/data/kernel-hive`,
`/data/gallery-guests`, `/data/isos` and `/data/media-archive` bind-mounted —
read/Edit/grep files on the box directly. **Process control still goes
through `ssh lab` / `scripts/dev/labrun`**: `systemctl`, `qm`, `pct`, guards
and kills act on guests only over that door. Multi-line remote work goes
through `scripts/dev/labrun <<'EOF' … EOF` (no quoting, `ssh -n`, forwards
`KH_SESSION`); never nest `ssh lab` inside `ssh lab`, and loops call `ssh -n`.
Other guests on this hardware belong to unrelated projects — **leave them
alone**.

**Start a session with `scripts/dev/here.sh`** — one screen: where you are,
what is deployed on the box, who else is here, what is staged, what is
stopped/paused, what to run next.

**Every task runs in its own full stack; the shared clone is land-only.**
`scripts/dev/wt.sh new <name>` makes a worktree of `/data/kernel-hive` on
branch `<name>` at `/data/vms/sandbox/<name>/repo` (same path on CT950 and
labhost) plus its own sandbox dir, build dir, staging slot and claim. Do ALL
edits, builds and tests there — fix problems at the right location in **your
own stack**, never a workaround on someone else's. **Every new task starts
with `wt.sh new`, including a follow-up after `wt.sh rm`** — the shared clone
(`/home/wnt/kernel-hive`, or wherever `here.sh` says "shared clone") holds
NO uncommitted edits, ever: it is where merges land and nothing else (an
Edit/Write there is refused by the harness hook). The operator's phrase
**"use shared clone"** lifts that for this clone: `touch .claude/shared-clone-ok`
and work in place; **"back to sandboxes"** = `rm` it. `here.sh` shows it while set. Land from the sandbox: commit,
`git push origin <name>`, then either the orchestrator merges, or you do
`git fetch origin && git merge --ff-only origin/main` (or a `--no-ff` merge)
in the sandbox and `git push origin HEAD:main`, then
`scripts/dev/box-deploy.sh --apply`. `wt.sh gc` prunes merged sandboxes.
`scripts/dev/stage.sh` previews a UI/registry change at `/staging/<session>/`
on the live origin before it goes live.

**Never experiment on a live station.** Clone under `/data/vms/sandbox/`
(`wt.sh new` does this for you), keep the SAME device set (`loadvm golden`
requires it), and namespace every dir, VMID, socket and port so concurrent
agents cannot collide.

**A new station: source your own media, land it host-native.** Fetch install
media and ROMs yourself from the lab's archival sources (see
[`docs/catalog/os-media-catalog.md`](docs/catalog/os-media-catalog.md)); the
operator supplies only Windows licensing. Before any recon, read
[`docs/lab/research/vom-reference.md`](docs/lab/research/vom-reference.md) —
the Virtual OS Museum's 1703 installations already answer "which emulator,
which settings" for most candidates, and it is **CC BY-NC-SA against our MIT
public repo: read the facts, never copy its files, configs or argument
strings**. The end state of every station is **host-native: direct
framebuffer capture + input forwarding, no kiosk**. A Debian/trixie kiosk
bridge is allowed only as a throwaway proof-of-concept while an emulator is
still being proven; it is never what ships. The 28 surviving Tier-2 bridges
are legacy to be converted, not a template to copy —
[`docs/GUEST-TIERS.md`](docs/GUEST-TIERS.md),
[`docs/lab/DEBRIDGE-CONVERSION-BRIEF.md`](docs/lab/DEBRIDGE-CONVERSION-BRIEF.md).

**Kill and mount through the guards.** Every clone kill/stop goes through
`clone-guard`; every chroot mount through `chroot-guard`, and ad-hoc chroot
work inside `chroot-guard run-private bash` (the host's `/dev` is `shared:2`,
so a hand-rolled teardown unmounts the host's own mounts — it has broken ssh
logins once and `pct start` fleet-wide once). Never
`pkill -f` from `ssh lab` — it matches your own ssh command line and kills your
session. Resolve processes through `/proc/<pid>/exe`, never a cmdline grep,
which matches the shell running it.

**Claim shared things atomically, and make the claim the proof.** Displays,
taps, labhost IPs, iptables chains, core pairs, ports, VMIDs. Never
check-then-create; namespace per rig; **fail loudly instead of falling back —
"it exists" is not "it is mine".** `$KH_SESSION` (`scripts/lib/kh-session.sh`)
tags every rig and claim; claims live under `/run/kh-claims/` via `kh-claim` /
`labctl claims`; `ssh lab 'labctl who'` answers "whose is this?" instead of
`/proc` forensics.

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
- All `node scripts/check-file-size.mjs --strict` and `make station-registry-check`

**Integrate continuously** — merge to `main` early and always `git push origin
main`. After any push that touches deployed files, put it on the box:
`scripts/dev/box-deploy.sh --apply` (installs from the commit; restarts are a
separate decision — `build-deploy.sh`/`systemctl restart streamhost@<x>`/
`serve-https-spa.sh deploy`). Never echo or log
`~/Downloads/humanify-token`.

---

## Where to look

| I need to… | Go to |
|---|---|
| Start a session | `scripts/dev/here.sh` — run it first, every time |
| Whose rig/claim is this | `ssh lab 'labctl who'` |
| Preview a UI/registry change before it's live | `scripts/dev/stage.sh` — `/staging/<session>/` on the live origin |
| Deploy a pushed commit to the box | `scripts/dev/box-deploy.sh` (plan) / `--apply`; `--status` for deployed rev vs `main` |
| What a word means (station, seed, checkpoint, scene…) | [`docs/GLOSSARY.md`](docs/GLOSSARY.md); identifiers/paths still carry old names until [the migration](docs/lab/research/terminology-migration-2026-08.md) lands |
| Understand how any of this works | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) → tiers, I/O paths, costs |
| Drive a guest / run a command in one | [`docs/lab/LABCTL.md`](docs/lab/LABCTL.md). Start with `labctl facts <tile>`; `labctl` prints its own usage |
| Debug pointer, tap, drag, double-click | [`docs/lab/INPUT-DEBUGGING.md`](docs/lab/INPUT-DEBUGGING.md) |
| Debug keys vanishing or scrambling | [`ADD-NEW-OS-PLAYBOOK.md` §5.1](docs/lab/ADD-NEW-OS-PLAYBOOK.md#51-keyboard-only-exhibits--pacing-layout-and-the-type-in-demo) |
| Debug ANY streaming complaint (froze, blurry, laggy, stopped, dropped quality) | [`docs/lab/STREAM-DEBUGGING.md`](docs/lab/STREAM-DEBUGGING.md) — the client already recorded it; start with `clientlog.jsonl`, not a repro |
| Fix a station that freezes or won't connect | `ssh lab 'python3 /data/vms/streamhost/serve/check-stream-tickets.py'` |
| Which emulator runs a given OS, and with what settings | [`docs/lab/research/vom-reference.md`](docs/lab/research/vom-reference.md) — read it BEFORE spending an agent on recon |
| Add a new OS station | [`docs/lab/ADD-NEW-OS-PLAYBOOK.md`](docs/lab/ADD-NEW-OS-PLAYBOOK.md) |
| Migrate a kiosk to trixie | [`docs/lab/MIGRATION-WAVE-BRIEF.md`](docs/lab/MIGRATION-WAVE-BRIEF.md) |
| Build the daemon, a guest, or the UI | [`scripts/README.md`](scripts/README.md); host-side builders run only from `/data/kernel-hive` (`scripts/dev/box-repo.sh`) |
| Work on the public gallery or passkeys | [`docs/PUBLIC-GALLERY.md`](docs/PUBLIC-GALLERY.md). **Never `rm auth-state.json`** — passkeys cannot be regenerated |
| Measure performance | [`docs/lab/MEASUREMENT-METHODOLOGY.md`](docs/lab/MEASUREMENT-METHODOLOGY.md) |
| Get a cloud agent onto labhost | [`docs/lab/CLOUD-AGENTS.md`](docs/lab/CLOUD-AGENTS.md) |
| Know why the gate is shaped this way | [`docs/lab/AGENT-CI-EXIT-RULE.md`](docs/lab/AGENT-CI-EXIT-RULE.md) |
| Find anything else | [`docs/README.md`](docs/README.md) |

## Three facts that mislead if you don't know them

- **A station has ONE name**: registry id == `stationDir` == `SH_STATION`, enforced by
  `stations-registry.py`. The last two exceptions were renamed 2026-08-10. The
  serving plane still reads identity from the station's own `signaling.json` — the
  daemon is the authority on the name it verifies a ticket against.
- **A station that looks broken may just be stopped or paused** — `ssh lab 'labctl ls'`. The
  fleet is routinely stopped or paused; check for in-flight work before starting
  anything.
- **A fix may not have taken effect**: streamhost deploys are per-station canaries
  and the fleet is not auto-promoted; UI edits need the bundle redeployed; a
  launcher or geometry change needs the checkpoint **recaptured**; and a push
  is not a deploy — check `scripts/dev/box-deploy.sh --status` (or
  `/data/vms/streamhost/.deployed-rev`) for what commit the box is actually
  running.

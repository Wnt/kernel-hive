# Operating rules — the long form

[`AGENTS.md`](../../AGENTS.md) at the repo root is the summary every agent loads
into context. It is deliberately terse: each rule there costs tokens once per
agent, forever. **This file is where the same rules keep their reasoning, their
exceptions and the incident that bought each one.** Read it before your first
write to the box; re-read a section when a rule in `AGENTS.md` looks arbitrary.

---

## 1. Addresses are scrubbed placeholders

Every IP, hostname and domain in this repo is a **placeholder**: `192.0.2.10`,
`labhost`, `example.com`, MAC `02:00:00:00:00:01`, serial `EXAMPLE0000000000`.
Do not `ssh`/`curl` one expecting it to resolve, and **do not "fix" one** — an
agent that "corrects" a placeholder to the real value commits a leak to a public
repo. Real values live only in gitignored `registry/local.env`.

**The one exception** is the public gallery domain `kernelhive.madekivi.fi`,
which is not a secret and is committed on purpose: the release notes link every
machine to `https://kernelhive.madekivi.fi/os/<id>`, and inside the SPA the same
link is the relative `/os/<id>`. Do not "scrub" those links.

Also gitignored, for the same reason: SSH keys, PKI, `uptoken`, `unifitoken`,
`spa/src/data/credentials.ts`, `docs/gallery-credentials.md`. Never echo or log
`~/Downloads/humanify-token`.

## 2. Labhost: one door

`ssh lab '<cmd>'` is the one door, as root, from a LAN workstation and a cloud VM
alike. stdout/stderr stay separate and the guest's exit code is yours.

CT950 (`ssh lab 'pct exec 950 -- <cmd>'`) is the dev container this session runs
in. Since 2026-08-17 it has `/data/vms`, `/data/kernel-hive`, `/data/gallery-guests`,
`/data/isos` and `/data/media-archive` bind-mounted — **read, Edit and grep those
files directly**, do not tunnel file access through ssh.

**Process control still goes through `ssh lab` / `scripts/dev/labrun`**:
`systemctl`, `qm`, `pct`, the guards and any kill act on guests only over that
door. Multi-line remote work goes through `scripts/dev/labrun <<'EOF' … EOF` —
no quoting to get wrong, `ssh -n`, and it forwards `KH_SESSION`. Never nest
`ssh lab` inside `ssh lab`, and loops call `ssh -n` (otherwise the loop body eats
the loop's own stdin).

Other guests on this hardware belong to unrelated projects — **leave them alone**.

## 3. Every task runs in its own full stack

`scripts/dev/wt.sh new <name>` makes a worktree of `/data/kernel-hive` on branch
`<name>` at `/data/vms/sandbox/<name>/repo` (the same path on CT950 and on
labhost) plus its own sandbox dir, build dir, staging slot and claim. Do ALL
edits, builds and tests there — and fix problems at the right location **in your
own stack**, never as a workaround on someone else's.

**Every new task starts with `wt.sh new`, including a follow-up after `wt.sh rm`.**
The shared clone (`/home/wnt/kernel-hive`, or wherever `here.sh` says "shared
clone") holds NO uncommitted edits, ever: it is where merges land and nothing
else. An Edit/Write there is refused by a harness hook.

The operator's phrase **"use shared clone"** lifts that for this clone —
`touch .claude/shared-clone-ok` and work in place; **"back to sandboxes"** removes
it. `here.sh` shows the flag while it is set.

Land from the sandbox: commit, `git push origin <name>`, then either the
orchestrator merges, or you do `git fetch origin && git merge --ff-only origin/main`
(or a `--no-ff` merge) in the sandbox and `git push origin HEAD:main`, then
`scripts/dev/box-deploy.sh --apply`. `wt.sh gc` prunes merged sandboxes.
`scripts/dev/stage.sh` previews a UI/registry change at `/staging/<session>/` on
the live origin before it goes live.

## 4. Never experiment on a live station

Clone under `/data/vms/sandbox/` (`wt.sh new` does this for you), keep the SAME
device set (`loadvm golden` requires it), and namespace every dir, VMID, socket
and port so concurrent agents cannot collide.

## 5. A new station: source your own media, land it host-native

Fetch install media and ROMs yourself from the lab's archival sources — see
[`docs/catalog/os-media-catalog.md`](../catalog/os-media-catalog.md). The
operator supplies only Windows licensing.

Before any recon, read [`research/vom-reference.md`](research/vom-reference.md):
the Virtual OS Museum's 1703 installations already answer "which emulator, which
settings" for most candidates. It is **CC BY-NC-SA against our MIT public repo —
read the facts, never copy its files, configs or argument strings.**

The end state of every station is **host-native**: direct framebuffer capture and
input forwarding, no kiosk. A Debian/trixie kiosk bridge is allowed only as a
throwaway proof-of-concept while an emulator is still being proven; it is never
what ships. The 28 surviving Tier-2 bridges are legacy to be converted, not a
template to copy — [`../GUEST-TIERS.md`](../GUEST-TIERS.md),
[`DEBRIDGE-CONVERSION-BRIEF.md`](DEBRIDGE-CONVERSION-BRIEF.md).

## 6. Kill and mount through the guards

Every clone kill/stop goes through `clone-guard`; every chroot mount through
`chroot-guard`, and ad-hoc chroot work inside `chroot-guard run-private bash`.
The host's `/dev` is `shared:2`, so a hand-rolled teardown unmounts the host's own
mounts — it has broken ssh logins once and `pct start` fleet-wide once.

Never `pkill -f` from `ssh lab`: the pattern matches your own ssh command line and
kills your session. Resolve processes through `/proc/<pid>/exe`, never a cmdline
grep, which also matches the shell running it.

## 7. Recapture a golden through `checkpoint-guard`

**Never retire a golden before its replacement is proven.** A checkpoint, the
emulator binary that reads it and the device set it was captured on are ONE
combination: the new one must be **fully captured and restore-verified** before
anything of the old one is deleted or overwritten.

`ssh lab 'checkpoint-guard recapture <station>'` is the whole safe sequence as one
crash-safe operation — byte-copy backup SHA256-verified with the guest STOPPED,
capture under a different label, **restore-proven on the framebuffer**, and only
then the old one retired. A failed run deletes nothing, and `checkpoint-guard
resume` finishes an interrupted one
([`checkpoint-guard.md`](checkpoint-guard.md)).

Do NOT hand-roll it. `delvm golden` before its replacement `savevm` succeeds is
the exact window that has already left a live station with **no golden at all**
when the agent died inside it — and a hand-written `savevm golden-new` makes it
worse: every launcher probes with `grep -qw golden`, which matches `golden-new`,
so the station then refuses to start instead of cold-booting.

The guard refuses the runtimes it cannot cover safely (es40 `.axp`, MAME `.sta`)
rather than half-covering them. The same rule governs a binary or device-set
change: prove the combination on a clone, keep the old binary for rollback, and
re-prove the restore per station rather than carrying a clone's result across.

## 8. Claim shared things atomically, and make the claim the proof

Displays, taps, labhost IPs, iptables chains, core pairs, ports, VMIDs. Never
check-then-create; namespace per rig; **fail loudly instead of falling back —
"it exists" is not "it is mine".**

`$KH_SESSION` (`scripts/lib/kh-session.sh`) tags every rig and claim; claims live
under `/run/kh-claims/` via `kh-claim` / `labctl claims`; `ssh lab 'labctl who'`
answers "whose is this?" instead of `/proc` forensics.

## 9. Teardown is part of "done"

State it in the report: what you released, and the check that proved it.

## 10. The framebuffer is the only proof

It is the only evidence a guest reacted. Never infer from logs.

## 11. Green before done

Make the quality gate green for the language(s) you touched, or report **BLOCKED**
with the failing command and its output. Red is not done. Never hand-edit a
generated file. Never add a `size-exclusions.json` entry to silence a breach you
caused — it is a bidirectional ledger and a stale entry fails too.

- TS/JS — `cd spa && npx eslint . --max-warnings=0 && npx knip` (+ `npm run build`)
- Rust — `cd streamhost && cargo fmt --all --check && cargo clippy --all-targets -- -D warnings`
- Python — `ruff check scripts && ruff format --check scripts`
- Bash — `shfmt -d $(scripts/lint/shell-sources.sh) && shellcheck $(scripts/lint/shell-sources.sh)`
- All — `node scripts/check-file-size.mjs --strict` and `make station-registry-check`

Why the gate is shaped this way: [`AGENT-CI-EXIT-RULE.md`](AGENT-CI-EXIT-RULE.md).

## 12. Integrate continuously; a push is not a deploy

Merge to `main` early and always `git push origin main`. After any push that
touches deployed files, put it on the box: `scripts/dev/box-deploy.sh --apply`
installs from the commit. Restarts are a separate decision —
`build-deploy.sh` / `systemctl restart streamhost@<x>` /
`serve-https-spa.sh deploy`.

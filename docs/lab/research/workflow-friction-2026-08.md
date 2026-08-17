# Workflow friction audit, 2026-08-07 → 08-17 — and the plan to fix it

**Status: PROPOSAL** (nothing here is implemented yet). Source: all 23 Claude
Code transcripts of this project from the last ten days (~228 MB, mined by
four parallel readers), cross-checked against the scripts they name.

The question asked: *why do box sync and parallel-agent sessions keep costing
tokens and wall time, and what would let the next sessions iterate faster and
cheaper?* — including whether to add staging tiers and whether to run Claude
on labhost itself.

---

## 1. What the transcripts actually show

Ten days, ranked by cost. Every item recurred at least twice.

| # | Failure class | Evidence (dates) | What it cost |
|---|---|---|---|
| 1 | **Rendered manifests clobbered by whichever worktree publishes last.** `serve-https-spa.sh manifests` *and* `deploy` wholesale-replace `gallery-manifest.json` / `poster-docs.json` / `tiles.json`, silently deleting tiles other worktrees published (daybreak knocked off the wall twice) and stripping darklaunch overlays. | 08-09 23:52, 08-10 00:05, 08-11 23:13, 08-17 08:52, 08-17 11:41 | ≥5 diagnose-and-republish cycles; a "phantom fault" hunt each time (victim's `/signal/<tile>.json` 404s while the tile runs fine). A stale overlay from a spike session blocked another session's push a week later and needed the operator to relay between two agents. |
| 2 | **Push blocked on box-sync drift, resolved by hand-chaining tools.** Every session rediscovers `box-repo.sh` → `verify-box-sync.sh` → `box-sync-push.sh` → `harvest.sh` in a different order, usually reactively after `git push` is rejected. Two round trips to land one logical change is normal (launcher, then registry JSON). | 08-10 08:12, 08-11 07:07, 08-11 13:59, 08-16 23:28, 08-17 10:04, 08-17 11:33, 08-17 12:27, 08-17 16:21 | 10–15 min and 15+ tool calls per incident; the gate itself had two bugs on first contact; `.last-harvest` not re-stamped blocked `build-deploy.sh` outright once. Drift from a *sibling agent's* in-flight tile is indistinguishable from real drift and has to be triaged by hand every time. |
| 3 | **Two sessions doing the same work, unaware of each other.** es40 bench: parent + fork ran the *same* multi-hour A/B campaign twice. sinclairql lag: two sessions traced the same code for 20 min, discovered only when one's files got swept into the other's commit. A runaway session auto-restarted a station and photobombed bisect trials; the cross-session "stop" message sat behind an approval gate and never arrived. | 08-11 (es40), 08-17 12:xx–14:35 | Two full sessions of tokens; ~9 min / 20 tool calls of forensics (grepping other sessions' `.jsonl`, `/proc/<pid>/cwd`) just to answer "whose is this?". |
| 4 | **Box-side singletons, not files, are the collision surface.** Worktrees fixed git conflicts (merges are mostly clean now). What still collides: shared trixie chroot (serialised a build wave), leaked Xvfb `:93`, another session's soltest rigs found by PID triage, "fleet stopped for a bench" while another agent was live, unidentified `claude` process left running for hours. | 08-10 09:17, 08-11 03:11–04:30, 08-11 23:07, 08-11 17:16 | Hours of unaccounted noise/downtime, repeated reclaim boilerplate. |
| 5 | **"Fix didn't take effect" — three traps that are documented and still bite.** (a) `station.env` re-emit drops live-only hand-tuned knobs (29/60 tiles on encoder preset, 23 on bufsize, …); (b) SPA deploy strips darklaunch overlays; (c) golden vmstate carries ROM/BIOS bytes, so a file fix + restart restores the bug. | 08-11 18:35–19:30, 08-17 12:34, 08-17 16:16 | 1.5 h fleet audit + 85 restarts; a full cold re-bake; and a false alarm ("I still don't see it in the grid" → it sorted last) that cost a five-layer investigation. |
| 6 | **No staging for anything user-visible.** Poster copy went live, got feedback, went round twice. Fleet promotion withheld because the operator was using a station. New station's binary had to be hand-bootstrapped because `--canary` refuses a station that isn't live. Registry changes deferred as "risks breaking the live gallery". | 08-11 14:36, 08-16 22:54, 08-17 11:37 | 2–3× redeploy loops for wording; every "is it deployed?" answered by live labhost inspection. |
| 7 | **SSH ergonomics.** Not one escaping failure that broke a session — but 20–60-line `ssh lab 'bash -s' <<'EOF'` heredocs are re-sent per iteration, ad-hoc probes are `scp`'d before each run, QMP JSON is hand-quoted 6–8× per session although `scripts/qmp_hmp.py` exists, and three real bugs came from the transport (`echo`-expanded `\n` corrupted a pushed C file; a loop of `ssh lab` ate the outer stdin — needed `ssh -n`; a login loop tripped a guest getty throttle). | throughout | Verbosity tax on every remote step; three debugging detours. |
| 8 | **Token waste = re-derivation, not depth.** Fixed ~6-command situational-awareness tax on every resume; agents re-reading big docs (fixed once by trimming AGENTS.md); gate failure line found on the 3rd grep; blocking `sleep 1500` inside a turn; cheap-model offload burning $2.47/96 min on a task it couldn't self-diagnose. | 08-10 06:58, 08-11 23:32, 08-17 08:33–11:27 | The operator now pre-empts it manually every session ("be as token efficient as possible"). |
| 9 | **Destructive shortcuts on shared state.** `git checkout -- registry/` wiped the operator's uncommitted hand-edits (recovered from VS Code history, not git/ZFS); `--theirs` merge dropped 184 lines of promoted work (caught only by the size ledger); `qemu-img dd` clobbered a live qcow2 header; `.claude/worktrees` at 41 GB / 40 stale worktrees. | 08-09 20:13, 08-11 21:13, 08-16 20:23 | Near data loss; a rebuild. |

The single most important observation: **items 1, 2, 5b and half of 6 are the
same disease** — the box runs a hand-mirrored *copy* of the repo (232 md5
pairs, plus rendered documents pushed from whichever checkout ran the
publisher last) instead of a *deployment of a known commit*. Every tool
around it (`verify-box-sync`, `box-sync-push`, `harvest`, darklaunch ledger,
pre-push gate) is compensating for that.

---

## 2. Proposals, in the order I'd do them

### P1 — Deploy from a commit, not from a mirror  *(largest win; ~1–2 sessions)*

Today: repo file → (`scp` | `box-sync-push`) → live path; drift detector
compares 232 hashes; pre-push blocks. `/data/kernel-hive` already exists as
the clean checkout on labhost — but it is only used by builders.

Proposed: **`/data/kernel-hive` is the only source of bytes on the box.**

- `scripts/dev/box-deploy.sh [--all | <label>…]` (runs from anywhere): `box-repo.sh sync` to `origin/main` (or a named branch/sha for staging, see P2), then on labhost run `scripts/host/install.sh` **from the checkout**, which copies each declared row into its live path, applying the forward scrub from `registry/local.env` for `scrub` rows, and stamps `/data/vms/streamhost/.deployed-rev` (`sha`, `who`, `when`, rows). Post-actions (`daemon-reload`, restart) stay per row. Same pair table (`box-sync-pairs.sh`), same library — the pair table becomes the *install manifest*, and `box-sync-push.sh` becomes a thin wrapper that refuses anything except "install from checkout".
- **Rendered documents are rendered on labhost from the checkout**, never pushed from a workstation: `install.sh` runs `stations-registry.py rendered` and `merge-serve-manifests.py` itself. Item 1 dies structurally: there is no longer a "whichever worktree ran it last". Darklaunch overlays become P2 staging entries instead of a ledger.
- **`verify-box-sync.sh` collapses** to two questions: does `.deployed-rev` equal (or fast-forward to) `origin/main` for the deploy-relevant paths, and does every installed row hash to the checkout's rendered form at that sha. `box`-authority rows (`tiles.json`, `golden-manifest.json`) stay harvested, but by a cron on labhost committing to a `harvest/auto` branch you merge — not by a tool an agent has to remember.
- **The pre-push gate stops talking to labhost.** A push cannot cause drift any more (only a deploy can, and a deploy is from a commit). The gate keeps the local checks (lint, size ledger, registry). Drift becomes a *status* — `box-deploy.sh --status` prints "box is at abc123, main is at def456, 3 rows behind" — not a push blocker. This alone removes item 2 wholesale.
- Rust: `build-deploy.sh` already builds from the mirror in `build/`; point it at `/data/kernel-hive/streamhost` (or a worktree of that checkout) and drop `.last-harvest` and the `src/*` mirror pairs (43 rows).

Guard preserved: `install.sh` refuses to run from a dirty checkout and refuses
to install if a station capture is in flight (P4's claim registry answers that).

### P2 — Staging tiers that reuse what exists  *(~1 session each; do UI first)*

**UI/serving plane.** One HTTPS origin, two webroots:
`serve/releases/<sha>/` + `serve/webroot -> releases/<sha>` (atomic symlink
swap, rollback = re-point) and `serve/staging/` served under
`https://host:8443/staging/` by the same `osgallery-https-server.py`.
`box-deploy.sh --stage` deploys the current worktree's *committed* HEAD there
(any branch); manifests are rendered from that same tree, so a dark launch is
just "it's in staging". Passkeys already work origin-wide. Promotion is
`box-deploy.sh --promote` = install main to `releases/`, swap symlink. Poster
copy, gallery ordering, SPA changes all get an operator eyeball before they
are live — and the operator can eyeball from their phone.

**Stations.** The pieces exist (`soltest` clones, `loadvm golden`,
`build-deploy.sh --canary`, per-station `station.env`); what is missing is one
verb. `labctl stage <station> [--from <worktree-or-sha>]` = clone under
`/data/vms/staging/<station>/` with the same device set, launcher/env/binary
from the staged checkout, own signaling `/signal-staging/<station>.json`,
registered in the staging manifest so it appears in `/staging/` UI. `labctl
promote <station>` swaps launcher+env+binary+checkpoint into the live dir with
a `.previous` sidecar; `labctl rollback <station>`. Fixes item 6 and item 5a
(the emit runs against staging first and diffs the live env — the drop of a
hand-tuned knob becomes visible before it lands), and lets `--canary` accept a
not-yet-live station.

Speed stays: staging is on the same box, same golden, same tooling — an
`stage` is a clone + start (seconds for instant-restore stations); a promote is
a file swap + restart.

### P3 — Run the session where the files are  *(cheap; do first, actually)*

Facts: this session already runs in CT950 **on labhost** — `ssh lab` is a
0.4 s local hop, not a network round trip. labhost has no `node`/`claude`, and
running the agent as root on the Proxmox host is the wrong trade (see the
2026-08-10 analysis: it removes the last speed bump before 61 live exhibits).
The friction is not latency; it is that **CT950 cannot see `/data`**, so every
file on the box costs an `scp` or a heredoc, and every screenshot a
`ssh … | scp` pair.

Recommended, in this order:

1. **Bind-mount into CT950**: `pct set 950 -mp0 /data/kernel-hive,mp=/data/kernel-hive` and `-mp1 /data/vms,mp=/data/vms` (RW; ZFS snapshots stay the safety net). Read/Edit/grep then work directly on box files, `shmshot` outputs are readable in place, no `scp` for probes. Process control (`systemctl`, `qm`, `pct`, guards) stays behind `ssh lab` — that boundary is the useful one. AGENTS.md's "CT950 has no /data mount" line becomes "CT950 sees /data read-write; *act* on guests only via `ssh lab`". *Operator decision — it widens what a mistake in CT950 can touch. If you want a softer step: mount `/data/kernel-hive` and `/data/vms/soltest` RW, `/data/vms/streamhost` RO.*
2. **`scripts/dev/labrun`**: `labrun <<'EOF' … EOF` and `labrun file.sh args` — ships the script by stdin to `ssh -n lab bash -s`, sets `KH_SESSION` (P4), forces `set -euo pipefail`, no quoting at all. Add `ControlMaster auto`/`ControlPersist 10m` for `Host lab` in `~/.ssh/config` (0.4 s → ~30 ms). One paragraph in AGENTS.md: "multi-line remote work goes through `labrun`; never nest `ssh lab` inside `ssh lab`; loops call `ssh -n`".
3. Point AGENTS.md at the helpers that already exist and keep being re-invented inline: `scripts/qmp_hmp.py`, `scripts/shmshot.py`, `labctl facts`.

### P4 — Make claims and identity visible  *(~half a session)*

- **Session identity everywhere.** Every session exports `KH_SESSION=<job-id-or-worktree-name>`; `labrun`/`ssh lab` forward it (`SendEnv`/`AcceptEnv`); every rig dir, Xvfb display, VMID, socket and systemd scope is tagged with it. `labctl who` lists live claims by session with age and pid, and whether that pid is alive.
- **Claim registry** `/run/kh-claims/<class>/<name>` created by `mkdir` (atomic) holding `KH_SESSION pid purpose ts`; `clone-guard`, `xvfb-alloc` and the staging verbs go through it; `labctl claims gc` frees dead-pid claims. "Is this mine?" becomes a one-liner instead of `/proc` forensics; "fleet stopped while another session is live" becomes a refusal.
- **Merge-only main checkout.** `scripts/dev/wt.sh new <name>` creates the worktree, exports `KH_SESSION`, prints the P2 staging URL; `wt.sh gc` prunes worktrees whose branch is merged (there are 40 on disk right now, ~41 GB). Sessions never edit `/home/wnt/kernel-hive` directly when another worktree exists.
- **Cross-session messages must not depend on the other side's approval gate**: use `screen` mirroring (already the fallback) or a `KH_SESSION`-addressed file inbox `labctl msg <session>` that `here.sh` (P5) prints on start.

### P5 — Cut the fixed per-session tax  *(hours, high leverage)*

- `scripts/dev/here.sh`: one screen — `git log -3`, worktree + branch, box deployed rev vs main (P1), staging contents (P2), `labctl who` (P4), `labctl ls` one-line summary, unread messages, memory pointers. Replaces the ~6-command bootstrap every resume pays.
- Every gate failure prints **the remedy command on its first line** (`FAIL box drift → run: scripts/dev/box-deploy.sh --all`); the third-grep pattern goes away.
- Long waits leave the turn: `labctl wait-for <cond>` runs on labhost and the session polls with `run_in_background`, not `sleep 1500` inline.
- Keep the offload rule honest: qwenit only for bounded mechanical tasks with a machine-checkable done-condition; not for anything where "my code vs the platform" has to be judged (documented in `docs/lab/QWENIT.md`).

### P6 — Small guards for item 9

`git checkout -- <dir>` / `git add -A` banned in sweep briefs (already a rule —
make the wt.sh hook refuse when the main worktree is dirty); size ledger
already catches shrinkage — keep. `qemu-img` writes go through the guard that
refuses a live qcow2 target.

---

## 3. What this buys

| After | Item(s) closed |
|---|---|
| P1 | 1, 2, 5b, most of 8's gate hunting; ~200 of 232 sync rows become "installed from sha X" |
| P2 | 6, 5a; poster/UI review before live; canary for new stations |
| P3 | 7; scp/heredoc tax; screenshot round trips |
| P4 | 3, 4; "whose is this?" and stale worktrees |
| P5 | 8; resume tax; gate output |

Iteration speed does not go down: deploy is `box-deploy.sh` (one command,
seconds), staging is on-box, promote is a symlink/file swap. What goes away is
the *reactive* work — a rejected push, a phantom 404, a forensic PID hunt.

## 4. Suggested first session

1. P3.2 + P3.3 (`labrun`, ControlMaster, AGENTS pointers) — 30 min, zero risk.
2. Decide P3.1 (bind mount) — operator call; one `pct set` if yes.
3. P1 `box-deploy.sh` + `install.sh` reading the existing pair table; move
   manifest rendering onto labhost; flip the pre-push gate to local-only once
   `--status` is green fleet-wide.
4. P2 UI staging (`releases/<sha>` + `/staging/`), then station `stage/promote`.
5. P4/P5 as they come up — `here.sh` first.

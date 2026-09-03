# Nine-station wave retro — 2026-09-03

Measured facts only, drawn from the nine wave docs
(`docs/lab/{PCBSD,UBUNTU,SLACKWARE,NETBSD14,REDHAT62,SUSE64,FREEBSD411,DEBIAN22,
OPENBSD}-WAVE.md`), each with its own `session-timeline.py` run, and from the
coordinator's own landing-queue log (memory
`station-waves-2026-09-03-coordination`). No number here is estimated or
copied from a different run than the one it describes. This doc is the input
the tooling wave (`docs/lab/ADD-NEW-OS-PLAYBOOK.md` §0 "Several waves at
once", `scripts/dev/wave.sh`, `scripts/dev/station-land.sh`) was built to act
on — it does not restate that tooling's design, only the numbers behind it.

## What happened

Nine station integrations ran as nine parallel sessions (pcbsd, ubuntu,
slackware, netbsd14, redhat62, openbsd, freebsd411, debian22, suse64) behind
one coordinator session that held the shared allocation state and the landing
queue. All nine landed on `main` (final commit `21383ec2`), the box deployed
to it, all nine `streamhost@` units active, `labctl gen` green, load 3.75 at
close. Landing order: pcbsd, ubuntu, slackware, netbsd14, redhat62, openbsd,
freebsd411, debian22, suse64.

## Landing timeline (coordinator's queue log, wall clock)

| Station | "ready" | "go" | landed | main commit |
|---|---|---|---|---|
| pcbsd | 02:26 | 02:26 | 02:46 | `7ace57e8` |
| ubuntu | 02:26 (queued) | 02:46 | 03:02 | `b1a13d57` |
| slackware | 03:12 | 03:12 | 03:40 | `c079b76e` |
| netbsd14 | 04:08 | 04:08 | 04:30 | `4910a97d` |
| — | — | — | **usage-limit pause, all ten sessions** | 03:24–06:24 |
| redhat62 | 06:30 | 06:30 | 06:40 | `a8dabc52` |
| openbsd | 06:30 (queued) | 06:40 | 06:58 | `93eb70bc` |
| freebsd411 | ready 06:58 | 06:58 | 07:14 | `2e94505f` |
| debian22 | 07:26 | 07:26 | 07:44 | `bd37f69f` |
| suse64 | 08:06 | 08:06 | 08:25 | `21383ec2` |

Landing-window length (go → landed): pcbsd 20 min, ubuntu 16 min, slackware 28
min, netbsd14 22 min, redhat62 10 min, openbsd 18 min, freebsd411 16 min,
debian22 18 min, suse64 19 min. The brief's "5–25 min" range is this column;
the long ones were the pre-push gate re-run and shared-file conflicts
(slackware: 10 of its window's minutes were the gate, measured in its own wave
doc), not the deploy/station-up/proof steps themselves.

## The 3-hour usage-limit pause

03:24–06:24, all ten sessions (nine waves + coordinator) paused together and
resumed together. Nothing landed during the pause; the coordinator's log shows
zero queue transitions in that window. Per-wave active-time figures below
already exclude it where a wave doc states both a wall-clock and an
"active"/"without the pause" figure.

Resume worked because the coordinator kept three independent things: state in
this memory file, an in-session heartbeat cron, and an *outside*-the-harness
watchdog — a crontab entry that, when a session's transcript goes stale, types
a Resume prompt plus Enter into a detached GNU screen running `claude attach
<job>` (text and Enter as two separate `screen -X stuff` calls; one burst
reads as a paste and is dropped). The watchdog had one defect during this run:
it looked for the transcript under the pre-worktree project directory and
never fired, because the transcript path moves once a session enters a
worktree; fixed by globbing across `~/.claude/projects/*/<sid>.jsonl` instead
of a fixed path.

## Where coordination time went

The coordinator's own accounting (tooling-wave-brief.md, written by that
session): ~150 messages over ~9 hours for allocation (slot/UDP/VMID, x11warp
display, retronet IP+MAC+ICQ UIN), landing serialisation ("ready to land" →
"go" → "landed", one window at a time), status sweeps, and relaying traps
between waves. Per-wave session splits (coordinator model time / tool time /
waiting on agents), each from that wave's own `session-timeline.py` run:

| Wave | Coordinator model | Tools | Waiting on agents | Span measured |
|---|---|---|---|---|
| pcbsd | 60% | 19% | 21% | 37 min |
| ubuntu | 48% | 28% | 24% (two idle waits, 3+6 min) | 38 min |
| slackware | 58% | 35% | 6% | 50 min |
| suse64 | 78% (10 834 s of it the pause itself) | 9% | 13% | 308 min |
| freebsd411 | 86% (most of it the pause) | not broken out | not broken out | 283 min |
| pcgeos (prior wave, cited for contrast in the playbook) | 67% | 24% | 10% | 21 min |

Coordinator model time dominates every wave that reports a split, pause or
no pause — reading and writing, not waiting on tools or agents, is the
recurring cost. openbsd's own wave doc left its timeline section
`TODO(coordinator)` — not filled in, so no split is reported for it here.

## Per-station measured cost (from each wave's own timeline)

Wall-clock minutes from that wave's own start (its operator message or
`wave.sh`-equivalent first command), NOT from the coordinator's 02:05 broadcast:

| Station | Viewable | Golden baked | Featured/landed | Notes |
|---|---|---|---|---|
| pcbsd | 4 min | 26 min (with usb-tablet; rebaked without it) | — | golden agent (Fable) 22 min + 4.5 min rebake |
| ubuntu | — | — | 38 min (SPA deployed) | golden stream was the long pole; two idle waits (3+6 min) |
| slackware | 21 min | — | 48 min (fully featured) | phase-1; a separate ~35 min phase-2 pass added the abs pointer |
| netbsd14 | 5 min | ~185 min (X + golden + restore proof) | 215 min (landed; queued behind 3 sibling waves) | pacing fix +235 min; ~40 of ~2 h post-tooling were 7 losing theories |
| redhat62 | 8 min | 78 min | 91 min (featured) | plus the 3 h pause, on top |
| suse64 | CD1 staged 3 min | golden #1 (twm) 286 min wall / 106 active; golden #2 (KDE) 301 min wall / 121 active | 308 min wall / 128 active | two guest walls neither sibling had met |
| freebsd411 | 5 min | 275 min wall / 96 active | 283 min wall / 104 active | pause cost 179 of the 278 wall minutes between viewable and golden |
| debian22 | 5 min | 93 min active (excl. pause) | — | a second racing golden agent (`debian22-golden2`) found no golden inside its own 25-minute stop |
| openbsd | — | VM_SIZE 904 MiB, VM_CLOCK 0000:03:04 | — | this wave's own Timeline section is unfilled (`TODO(coordinator)`) — could not be sourced |

## What the tooling removes

Each line ties a measured cost above to the tool built to remove it
(`docs/lab/ADD-NEW-OS-PLAYBOOK.md` §0 "Several waves at once" has the current
interfaces):

- **Allocation bookkeeping** (slot/UDP/VMID, x11warp display, retronet
  address/MAC/UIN — a recurring share of the coordinator's ~150 messages) →
  `scripts/dev/wave.sh alloc <id> [--retronet] [--x11warp]`, one atomic claim
  instead of a person handing out numbers per wave.
- **Landing serialisation** ("ready to land" → "go" → "landed", relayed by a
  person for every one of the ten landings above) → `scripts/dev/wave.sh land
  begin/end/status`, a `kh-claim` FIFO queue a wave polls itself.
- **The landing window's hand-run steps** (fetch+merge, validate+generate,
  push, box-deploy, golden swap, station-up, claim re-homing, proofs, SPA
  deploy, re-arming other waves' darklaunch overlays — the 10–28 minute
  windows above) → `scripts/dev/station-land.sh <id>`.
- **Doing absolute pointer and retronet in a second and third bake** (netbsd14
  and slackware both took a separate pass after their first landing — the
  playbook estimates ~2 h per station saved by doing it once) → the device set
  is complete at the FIRST `savevm golden` when a wave uses
  `rn-onboard.sh`/`wave.sh alloc --retronet --x11warp` from the start.
- **Resume after a usage-limit pause** (worked this run, but needed a hand-run
  crontab + screen + heartbeat cron, and had one bug that cost real time
  chasing) → `scripts/dev/session-watchdog.sh install/remove`, the same
  mechanism generalised into the repo.
- **Three per-wave copies of the same X-warp probe** (`xwarp.py`, `x11ptr.py`,
  `x11warp-check` — each independently written and each held by ruff) →
  `scripts/dev/x11warp-probe.py`, one tool.

## What the tooling does not remove

The load rule and cross-wave relay of a finding both stayed operator/human
judgment calls in the tooling-wave brief (see `OPERATING-RULES.md` §14) —
neither is claimed as automated here, and this retro does not have measured
data on how much of the coordinator's time either one cost specifically
(the ~150-message/~9-hour figure above is not broken down by category).

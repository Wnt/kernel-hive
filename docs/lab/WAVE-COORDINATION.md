# Running station waves in parallel

**How several new-station waves share one box without a human in the middle.**
The procedure for a single station is
[`ADD-NEW-OS-PLAYBOOK.md` §0](ADD-NEW-OS-PLAYBOOK.md); this document is only
what changes when five or ten of them run at once.

It exists because of a measurement. On 2026-09-03 nine waves (pcbsd, ubuntu,
slackware, netbsd14, redhat62, openbsd, freebsd411, debian22, suse64) ran
together through three phases. One coordinator session sent **~150 messages in
~9 hours**, and almost all of them were two mechanical jobs: handing each wave
its shared numbers, and serialising the main-push windows
("ready to land `<id>`" → "go `<id>`" → "landed `<id>`"). Both are a lock with
a queue. A lock with a queue is a tool.

## Roles

| Role | Owns | Tools |
|---|---|---|
| **Wave session** | one station, end to end: media, golden, registry row, docs, poster, and its own landing | `wave.sh`, `smoke-rig.sh`, `rig-clone.sh`, `station-up.sh`, `station-land.sh` |
| **Coordinator** (optional) | only what a tool cannot do | relaying findings between waves; the two single-run fleet steps |
| **Operator** | validating what shipped | the framebuffer, `/os/<id>`, the gallery |

A coordinator is now **optional**, and when there is one it is deliberately
small. It does three things:

1. **Relays findings between waves.** Two waves installing KDE 3, three
   installing XFree86 3.3.6 on cirrus — one of them hits the wall first and the
   others must not pay for it again. A finding goes into the wave doc *and* to
   the sibling sessions by name. No tool does this.
2. **Runs the two single-run fleet steps**, once, after the last wave lands:
   `python3 scripts/retronet/icq/seed_contacts.py ssi --apply`
   ([CONTACT-SEEDER.md](retronet/CONTACT-SEEDER.md)) so every station carries
   every other station plus HiveBot on its roster, and then the final
   verification sweep.
3. **Watches the load** (see the load rule below).

Everything else the coordinator used to do — allocation, "go", status sweeps —
is `wave.sh`.

## The two commands a wave needs

### `wave.sh alloc <id> [--retronet] [--x11warp]`

ONE atomic allocation of everything the wave shares with every other wave,
claimed through `kh-claim` under `$KH_SESSION`:

| Allocated | Value | Claim |
|---|---|---|
| slot | next free above every registry slot **and** every slot claim | `slot/<n>` |
| streamhost UDP | `54000 + slot` | `port/<n>` |
| VMID label | `slot` | `vmid/<n>` |
| x11warp display (`--x11warp`) | `:<slot-100>` | `display/:<n>` |
| x11warp loopback door | `127.0.0.1:6<slot-100>` | `port/<n>` |
| retronet address (`--retronet`) | next free `10.99.0.N`, N < 100 | `rnip/<addr>` |
| retronet MAC | `52:54:00:52:4e:<N in hex>` | (in `local.env`, never in git) |
| retronet tap | `<id>rn0` | `tap/<id>rn0` |
| guard chain | `<ID>RN-IN` | `chain/<ID>RN-IN` |
| ICQ UIN | `<slot>00` | `uin/<n>` |

It prints a **markdown ledger row** to paste into the wave brief, and writes
**`.wave.env`** at the repo root — a `KEY=VALUE` fragment (`WAVE_SLOT`,
`WAVE_UDP_PORT`, `WAVE_X11_HOSTFWD`, `WAVE_RN_ADDRESS`, `WAVE_RN_MAC`, …) that
the launcher, the fixture and `scripts/retronet/rn-onboard.sh`
source. `.wave.env` is **gitignored**: it carries the box's real MAC, and rule
1 says a real MAC never reaches git. The ledger row deliberately omits it.

With `--retronet` it also writes the reservation into the **box-side**
`registry/local.env` and re-renders DHCP in CT 951. Three facts make that one
command instead of three:

- **A `local.env` edit alone is not live.** `retronet-dhcp` reads
  `/etc/retronet/dhcp.env` *inside CT 951*, rendered by
  `scripts/retronet/web/install-dhcp.sh`. Skip the re-render and the guest
  leases a pool address instead of its reservation (freebsd411 took `.101`).
- **The reservation is edited in place, not appended.**
  `scripts/lib/local-env.sh` parses `KEY=VALUE` literally — it does **not**
  expand `$VAR`, and it keeps the **first** assignment of a key. A second,
  self-referencing `RETRONET_DHCP_RESERVATIONS=` line would be read as that
  literal string and then ignored. A timestamped backup is kept beside it.
- **The launcher reads `RN_<ID>_MAC` from the BOX-side `local.env`**, not from
  a CT-side or worktree copy. pcbsd's first launch died on exactly this.

**A value another session holds is a hard failure that names the holder**
(rule 7). Never bump a number by hand because a claim was refused —
`ssh lab 'labctl who'` answers whose it is, and the answer is the point.
Re-running `alloc` in the same session is idempotent: it reuses the slot and
address that session already holds and does not touch `local.env` twice.

**Pre-DHCP guests still get a reservation.** A guest that predates DHCP is
addressed statically in the guest and declares `"addressing": "static"` — but
the reservation stays, because `RETRONET_DHCP_RESERVATIONS` is the plane's
uniqueness ledger. See [WEB-PLANE-PLAN.md](retronet/WEB-PLANE-PLAN.md).

### `wave.sh land begin|end|status <id>`

The landing window — one wave at a time pushing main, deploying the box and
publishing the SPA — is a lock with a FIFO queue on the box. No coordinator
issues "go".

```bash
scripts/dev/wave.sh land begin <id>     # blocks (polling) until it is yours
#   ... the landing: station-land.sh <id> does the whole window ...
scripts/dev/wave.sh land end <id>
```

`begin` **polls**; it never sleeps on a guess (rule 14). Each poll prints where
you stand, and only when that changes:

```
HELD    session=slackware id=slackware since=… held_min=7 pos=2
WAITING pos=2 ahead=redhat62/redhat62
```

- **FIFO.** Position is arrival order, not who retried most recently.
- **A timeout leaves the queue** (default 45 min, `--timeout-min`). A waiter
  that gave up must never sit at the head. Re-run to rejoin at the back.
- **A stale window is flagged, not stolen.** Past 25 minutes the poll line says
  `STALE`. **Message that session.** `land end --force` exists for a window
  whose session is provably gone, and it prints who it took it from.
- **Re-running `begin` as the holder succeeds**, so a resumed session cannot
  deadlock against itself.
- **The lock** is an atomic `mkdir` of `/run/kh-wave/holder` — the same
  primitive `kh-claim` is built on, chosen because the FIFO file that decides
  who may take it lives in the same directory and must move under the same
  mutex. It is mirrored into `kh-claim landing/window`, so `labctl who` and
  `here.sh` answer "who is landing?"; the mirror never gates, and a mirror that
  disagrees prints a warning naming both. `/run` is tmpfs: a reboot clears
  every window and every claim together.

The semantics above are proved off-box by
[`tests/wave-queue-selftest.sh`](../../tests/wave-queue-selftest.sh), which
points `KH_WAVE_STATE_DIR` at a temp dir and runs the same bytes that run on
labhost.

### `wave.sh status`

The landing window and its queue, every claim grouped by session, and every
branch pushed to origin in the last three days with whether that station
already has a registry row on main. One call, no coordinator.

## What still has to be a message

The tool removed allocation and serialisation. These remain:

- **A finding another wave needs now** — a wall, its cause and its fix.
- **Load, when it goes over.** Saturating the cores is fine; a **1-minute load
  above 50** means scale down, and whoever sees it says so. Each wave holds at
  most **three** guests; a race is three runners and the **losers die on the
  first frame** (`rig-clone.sh keep`); nothing hung is left spinning. The
  measured load was fleet baseline (~8 cores) plus roughly one full vCPU per
  running install — QEMU *counts* were never the problem, stale burners were.
- **"I am not landing this wave."** openbsd reached the end of the night with
  no browser proof and no golden. Saying so, releasing its claims and pushing
  a docs-only branch is a result. Do not commit an unproven station's
  `rn-tapnet.sh` — the box-sync glob deploys every committed one.

## Fleet-wide side effects of a landing

Every landing does these to everybody else. Know them before you take a window.

- **The SPA deploy wipes every other wave's dark-launch overlay**
  (`serve/darklaunch.d`). Owners re-arm with `darklaunch-station.py publish`
  when the operator needs `/os/<id>` visible again; the rig's `entry.json`
  survives.
- **`box-deploy --apply` reverts other waves' uncommitted live edits.** That is
  why the window is exclusive, and why a doc-only commit pushes bare without
  taking one.
- **The two append-only SPA tables are re-inserted, never unioned.**
  `spa/src/scene/assembliesByTile.ts` and `spa/src/scene/machineIdentity.ts`
  conflict on every merge. Take main's table and put only your row back at its
  lineup position; a union doubled a row twice in one night. The scene test
  also wants a **distinct** `body|monitor|keyboard|mouse` tuple, and a
  `--like` copy keeps the sibling's — change one part.
- **Run the gate before you ask for the window, not inside it.** Ten of
  slackware's fifteen window minutes were the pre-push gate.

## Resuming after a usage limit

A five-hour usage limit paused all ten sessions of the 2026-09-03 run
**together**, for three hours. Nothing inside the harness could restart
anything: the in-session heartbeat cron and the queued peer messages were
paused with the sessions. Three things made the resume work, and only the third
is outside the harness:

1. **State in a memory file, not in context.** The roster, the allocations, the
   landing queue log and a written Resume procedure. A resumed session reads it
   and knows the job.
2. **An in-harness heartbeat cron** (every ~20 min: read the memory file, drain
   queued messages, advance the queue, update the log). Session-only — it dies
   with the process and a new session must recreate it.
3. **An outside watchdog**:

```bash
scripts/dev/session-watchdog.sh install <job-id> <memory-file>
scripts/dev/session-watchdog.sh status  <job-id>
scripts/dev/session-watchdog.sh remove  <job-id>
```

It installs a crontab entry that watches the session **transcript's mtime**
(an idle-but-alive session still refreshes it) and, when it goes stale, types a
Resume prompt into a detached GNU `screen` running `claude attach <job>` — so
the live process, its cron and its queued peer messages all survive. Only when
the job **process** is gone does it fall back to `claude stop` +
`claude --bg --resume <sid>`. A line starting `STATUS: DONE` at the top of the
memory file makes it uninstall itself.

Two details that are the whole difference between working and not:

- **The prompt text and the Enter must be two separate `screen -X stuff`
  calls**, with a pause between. Sent as one burst the terminal reads it as a
  paste and the Enter lands as a literal newline in the composer.
- **Transcript paths move.** A session that enters a worktree gets a new
  project directory, so the transcript is found by glob across
  `~/.claude/projects/*/<sid>.jsonl`. The original watchdog remembered the
  pre-worktree path and never fired once during the three-hour pause it was
  installed for.

If the usage limit is still in force the typed turn simply fails, the
transcript stays stale, and the next tick types it again. That is why this is a
cron and not a retry loop. Install it **before** you need it —
`session-watchdog.sh tick <job>` with `DRY_RUN=1` proves the route without
typing anything.

## Related

- [`ADD-NEW-OS-PLAYBOOK.md` §0](ADD-NEW-OS-PLAYBOOK.md) — the per-station procedure
- [`OPERATING-RULES.md`](OPERATING-RULES.md) — the reasoning behind rules 3, 7, 8, 14
- [`retronet/WEB-PLANE-PLAN.md`](retronet/WEB-PLANE-PLAN.md) — the reservation ledger
- [`FLEET-ROLLOUT.md`](FLEET-ROLLOUT.md) — restarting the fleet without taking the gallery down

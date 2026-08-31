# Rolling the fleet without taking the gallery down

The operator's rule, verbatim: **"it's OK to restart all the stations, but do
avoid restarting them all at once."**

`scripts/dev/fleet_rollout.py` is that rule made executable. Its box side is
`scripts/host/fleet-rollout-probe.sh`, which is read-only and is shipped per call
by `scripts/dev/labrun`.

```
scripts/dev/fleet_rollout.py                 # plan only — ALWAYS run this first
scripts/dev/fleet_rollout.py --apply         # execute
scripts/dev/fleet_rollout.py --resume --apply
```

Plan-only is the default. There is no flag that restarts anything without
`--apply` on the command line.

## What it is not

`scripts/dev/build-deploy.sh --canary <station>` followed by `--promote` already
rolls a **new binary** across the fleet in bounded waves, with atomic pointer
moves (`current`/`previous` symlink renames), a promotion gate, `--exclude`, and
a per-wave restore when a wave fails. **None of that is reimplemented here.**

What `--promote` does not have, and structurally cannot grow, is the policy
around those waves: it is 599 lines against the 600-line hard cap in
`scripts/check-file-size.mjs`. So this tool holds the policy and delegates the
mechanism:

| | `build-deploy.sh --promote` | `fleet_rollout.py` |
|---|---|---|
| moves the binary pointer | yes, atomically | no — calls the left column |
| wave size | `--wave-size`, default 4 | `--wave-size`, default 4 |
| wave **order** | alphabetical | risk-ordered, cheapest mistake first |
| settle between waves | none | `--settle`, default 45 s |
| health gate | daemon `LISTENING` line | that **plus the framebuffer** |
| skips | `--exclude` only | claims, stopped units, visitors, `--exclude` |
| resumable | idempotent re-run | a state journal + `--resume` |

`--mode promote` runs `build-deploy.sh --promote --wave-size <n>` once per wave
with every other live station held back by `--exclude`, then applies this tool's
settle and framebuffer gate to that wave. `--mode restart` (the default) is a
plain staggered `systemctl restart`, for a launcher, `station.env` or
configuration roll where no binary moves.

**Wave 1 is the canary, and in promote mode it moves no pointer.**
`build-deploy.sh --promote` promotes every live tile *except* the canary — that
station was already switched by `--canary` and is what the gate certifies — so
handing it a wave containing only the canary makes it die with "no non-canary
tiles to promote". Wave 1 is exactly that wave, which deadlocked the tool's
first real run. It now health-gates the canary (settle + framebuffer, because
the binary really did move under it) and skips the promote call. The canary is
read from `/usr/local/lib/streamhost/.canary-ready`, not assumed to be
`SAFE_TILE`, since the gate names whoever was canaried last.

## The health gate is the framebuffer

AGENTS.md rule 9: the framebuffer is the only proof a guest reacted. Three tiers
run per wave and all three must pass before the next wave starts.

1. **Readiness.** The unit is `active` *and* the daemon logged its own
   `LISTENING udp/ ... tile=<t>` line **from the new MainPID**. `systemctl
   is-active` goes green the moment the process execs, long before it has
   reopened its UDP socket; scoping the journal read to the current MainPID is
   what stops a stale line from the previous run satisfying the gate. Same
   invariant `scripts/lib/streamhost-artifacts.sh` states for `build-deploy.sh`.
2. **Settle** (`--settle`, default 45 s), so a guest that is going to fall over
   has time to.
3. **A real screendump per station.** Pulled through labctl's own capture
   dispatcher, so a QMP tile, an x11-capture tile and an shm tile each get the
   backend they actually use, and required to decode and to be at least
   `--min-nonblack` percent non-black (default 0.5 %) — or, for a station the
   registry declares `ui: text-console`, merely non-blank (see below).

Tier 3 is the one that means anything. Tiers 1 and 2 are logs and clocks.

`--no-frame-gate` drops tier 3 to readiness only. It prints a warning in the
plan when it is set, because a rollout gated on logs alone is the failure mode
this tool exists to prevent.

**The capture passes `resume=False`.** `labctl shot` passes `resume=True`, which
issues `cont` on a paused guest — a rollout must never thaw a guest somebody
parked, and a frozen guest's last frame *is* its current screen.

### The frame gate's floor, and why one number could not carry it

Measured read-only across every capture backend on 2026-08-31 — QMP, x11spike,
shm, es40 and SIMH all returned a decodable frame:

| station | backend | frame | non-black |
|---|---|---|---|
| `gt40` | SIMH | 1280×1024 | **1.06 %** |
| `pdp11` | SIMH | 1024×768 | 3.98 % |
| `tru64` | es40 | 1280×1024 | 43.7 % |
| `c64` | x11spike | 768×544 | 61.8 % |
| `nextstep` | Previous | 1120×832 | 96.0 % |
| `irix`, `aix432`, `helenos`, `alto`, `zxspectrum`, `amigaos35`, `w2kalpha` | mixed | — | 97–99.8 % |

`gt40` is the floor of that sample: a vector display draws almost nothing. The
0.5 % default sits deliberately below it, and a dead station reads ~0 %.

**That sample was not the fleet, and the first real rollout found the gap.**
Wave 2 halted on `alpine` at **0.372 %** — a perfectly healthy Alpine login
prompt, white text on a black 1920×1200 console. Nothing was wrong with the
station: at that resolution a shell prompt simply *is* almost black, and the
sample above happened to contain no dark text console.

Averaging the two shapes into one number cannot work — any floor low enough for
a console is too low to catch a broken desktop. So the floor is per-station and
read from the registry, which already declares the distinction:

| `ui` | stations | floor | what the gate is asking |
|---|---|---|---|
| `text-console` | 5 (`alpine`, `alto`, `decos`, `freedos`, `pdp11`) | `CONSOLE_FLOOR` = 0.05 % | is there a frame here at all |
| everything else | 62 | `--min-nonblack` (0.5 %) | did this screen come back |

`min_nonblack_for()` only ever *lowers* the floor, so an operator who passes a
stricter-than-console `--min-nonblack` for a specific run still gets it. A
declared console that returns 0 % still fails, which is the case that matters:
a dead station is blank, not dim. If a new mostly-dark exhibit lands under the
desktop floor, fix its registry `ui` or lower `--min-nonblack` for that run —
never drop the gate. The failure message always prints the measured value and
the floor it was held to, so the number to use is in the output.

## What gets skipped, and why each

* **A unit that is not `active`.** Stopping a station is how the fleet is parked
  on purpose, so a stopped, failed or masked unit is left exactly as it is.
* **A station another session holds a `kh-claim` on** (rule 7), read from the
  claim registry rather than guessed. Only `held` and `live` claims skip; a
  `stale` or `dead` claim is the registry's own record that nobody is there.
  Matching is deliberately generous — the station's own UDP slot, or its id as a
  whole token in a claim's name, session or purpose — because the two errors are
  not symmetric: over-skipping costs a deferred restart, under-skipping costs
  somebody's work.
* **A station with a visitor connected right now.** `--include-busy` overrides.
* **Anything named with `--exclude`**, or not named by `--only`.

### Paused is not parked

**36 of the 71 live stations were `paused` when this was written.** The daemon
idle-auto-pauses an unwatched exhibit after ~60 s; that is the fleet's normal
resting state, not a park signal. Skipping paused stations would skip half the
fleet and roll out almost nothing (measured: 38 skipped, 34 rolled). So paused is
reported and **not** skipped. `--skip-paused` exists for the operator who wants
it and is off by default.

### Walk-in clones are not their stations

A walk-in pool clone is `walkin-<os>-<n>` — an ephemeral daemon identity, not the
registry station whose name it borrows. The six live walk-in port claims were
skipping `os2warp` and `win311` from every rollout by name collision alone, so
clone identities are masked out before a claim is matched.

## Wave order: a mistake should be cheap

Wave 1 is a single station — `SAFE_TILE` (`helenos`), which is already
`build-deploy.sh`'s own canary. A full first wave of four means a bad binary
takes four exhibits down before anything notices; one station first costs one
extra settle interval. `--no-canary-first` turns it off.

After that, stations are ordered by a risk score computed from registry fields
the fleet already maintains — no new hand-kept list to rot:

| term | weight | argument |
|---|---|---|
| `reset.resetMode` | `loadvm` 0, `relaunch` 2, `restart`/unknown 4 | how the exhibit comes back. A golden restores in seconds; a cold boot walks a full POST — aix432's alone is 15–25 minutes. |
| forked emulator binary (`/opt/…`, or a fork named in `emulator.source`) | +3 | binary + golden + device set are ONE combination (rule 6), and the hardest thing on the box to put back. |
| `retronet` present | +2 | a second network plane to re-establish. |
| `ui: desktop` | +2 | the flagship exhibits a visitor comes for, against a home computer or a text console. |
| bespoke pointer backend | +1 | closed-loop and warp pointers are per-station work a bad binary breaks silently. |

Ties break alphabetically, so the plan is deterministic. In practice this puts
`alpine`, `alto`, `amstradcpc`, `android`, `freedos`, `gt40` early, and
`tru64`, `w2kalpha`, `aix432`, `macos753`, `rhapsody`, `irix`, `nextstep` last.

## When a wave fails

The rollout **halts**. It prints every station as DONE / FAILED / PENDING with
the skip reasons, writes the state journal, and prints:

* the exact `--resume` command to continue from that point;
* the per-station rollback command, `build-deploy.sh --rollback <station>`, one
  station at a time.

**It never rolls the fleet back on its own.** An unattended fleet-wide rollback
is a second unsupervised mass restart, which is the thing being avoided. It also
says plainly that stations restarted in earlier waves are *not* reverted by a
per-station rollback.

## Resuming

Every wave writes `.fleet-rollout/<tag>.json` (gitignored): the plan, per-station
status, and the skip reasons. `--resume` reloads it, **re-probes the box**, and
re-classifies the stations that have not run yet — a station claimed, stopped or
opened by a visitor since the rollout stopped is dropped from the remainder
rather than trusted from the journal. Original wave boundaries are kept.

## Cost

The box-side probe is why this is cheap enough to run per wave. `labctl health
--json` fleet-wide reads each tile's whole boot journal (`journalctl -b -o
json`, ~21k lines, ~4 s per station) and **took over ten minutes without
finishing**. The same facts come out of `query-status` (0.16 s for all 49 QMP
tiles) plus a bounded 400-line journal tail (0.065 s per station): the whole
fleet snapshot takes **4 seconds**, and a three-station framebuffer grab takes
0.7 s.

A default rollout is 67 stations in 18 waves; at ~90 s per wave that is roughly
25–30 minutes of supervised time.

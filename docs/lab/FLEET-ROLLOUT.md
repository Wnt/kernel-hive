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

## Running a rollout, end to end

This is the sequence that took the fleet from "the tool has never been run"
to "rolled twice, cleanly" on 2026-08-31. Skip a step and the mistakes below
are the ones that happen.

1. **Land and push the code.** Then `scripts/dev/box-deploy.sh --apply`
   **before** building or rolling any binary — never after, even when your
   change looks Rust-only. Ordering here is not arbitrary: on
   2026-08-31 a `signal_route.py` fix (it appends `?traceparent=` to the
   signaling URL) had to be live on the box *before* a daemon binary that
   reads that query parameter (`trace/context.rs`) went out, or the new
   binary would go looking for something the still-old server was not
   sending yet. See docs/lab/TRACE-CONTEXT.md §8: an old daemon must keep
   working against a new server and vice versa, so this ordering is not a
   one-time fix — the SPA, the Python serving plane and the streamhost binary
   all deploy on separate schedules, permanently.
2. **`scripts/dev/build-deploy.sh --canary <safe tile>`** — mirrors your
   checkout's `streamhost/` source to the box and builds it there, then
   switches exactly one station. This is the way to build the daemon
   regardless of which checkout you run it from: CT950 itself has no working
   Rust toolchain for this crate, so `cargo build` in a local `wt.sh`
   sandbox is not an option — the box's warm `target/` is.
3. **Framebuffer-verify the canary by hand** before promoting anything else.
   The canary gate (`.canary-ready`) records that build-deploy.sh's own
   readiness check passed; it does not prove the exhibit looks right, only
   that its daemon came up. Look at the frame yourself.
4. **`scripts/dev/fleet_rollout.py --mode promote`, no `--apply`, every
   time**, even on a rollout you have run before. Read the full skip list
   before moving — see "What gets skipped, and why each" below — and
   understand every entry, not just the count.
5. **`--apply`.**
6. **Verify by census, not by trusting the run's own journal.** The state
   file says what the tool *believes* happened; what matters is what the box
   actually has live. Read each rolled station's own pointer back:
   `ssh lab 'readlink -f /usr/local/lib/streamhost/stations/<tile>/current'`
   for a sample, or loop it (`ssh -n`, never nested `ssh lab`, per AGENTS.md
   rule 2) over every station the plan claimed and count how many resolve to
   the artifact you expected.
7. **Report what was skipped and why**, and treat finishing those as a
   separate, deliberate act — not a leftover to sweep up in the same
   session. See "What gets skipped, and why each" below for which skips are
   normal and which mean something is actually stuck.

`--mode restart` (no binary movement — a launcher, `station.env` or
configuration roll) follows the same shape minus steps 1–3.

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
3. **A real screendump per station, before AND after.** Pulled through
   labctl's own capture dispatcher, so a QMP tile, an x11-capture tile and an
   shm tile each get the backend they actually use. The wave captures every
   station's frame once **before** restarting it (its own baseline) and once
   **after** the settle, and the after-frame must decode and clear the floor
   `effective_floor()` computes from that station's own before-frame (see
   below) — or, when no usable before-frame exists, `--min-nonblack` (default
   0.5 %) as a fallback, tightened to a mere non-blank check for a station the
   registry declares `ui: text-console`.

Tier 3 is the one that means anything. Tiers 1 and 2 are logs and clocks.

`--no-frame-gate` drops tier 3 to readiness only (and skips the before-capture
too, since nothing will read it). It prints a warning in the plan when it is
set, because a rollout gated on logs alone is the failure mode this tool
exists to prevent.

**The capture passes `resume=False`.** `labctl shot` passes `resume=True`, which
issues `cont` on a paused guest — a rollout must never thaw a guest somebody
parked, and a frozen guest's last frame *is* its current screen. Both the
before- and after-capture honour this; the before-capture in particular reads
whatever the station happens to be showing right now, not a freshly woken one.

### The frame gate's floor: relative to the station's own baseline, not one number

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

`gt40` is the floor of that sample: a vector display draws almost nothing. A
flat 0.5 % default sits deliberately below it, and a dead station reads ~0 %.

**That sample was not the fleet, and two real rollouts found the gap twice.**
Wave 2 of the first run halted on `alpine` at **0.372 %** — a perfectly
healthy Alpine login prompt, white text on a black 1920×1200 console. The
first fix classified the gate's floor by the registry's `ui` field: a declared
`text-console` only had to clear a much lower `CONSOLE_FLOOR` (0.05 %).

That held for exactly one more rollout. It then halted on `mpf2` at
**0.286 %** — the MPF-II trainer board's boot screen, a title, a prompt and a
cursor on black — and `mpf2` is registered `ui: home-computer`, the *same*
class as `c64` (61.8 % non-black above) and `zxspectrum` (~99 %). No `ui`
class predicts brightness; a home-computer exhibit can be a bright desktop clone
or a dim trainer board, and the registry has no field that says which.

**A healthy screen's brightness is a property of the station, not its class.**
So the gate stopped asking "how bright should a healthy frame of this kind
be" and started asking the only question that is actually true for every
station: **did this one come back to what it was?** `effective_floor()`
(`scripts/dev/fleet_rollout_policy.py`) computes the after-frame's floor as
half of that same station's own frame captured just before its wave restarted
it (`RELATIVE_FLOOR_RATIO = 0.5`) — loose enough that ordinary frame-to-frame
noise (a blinking cursor, one more line of boot text, a trainer board's
changing digit) never trips it, tight enough that a guest coming back fully
black (0 %) or producing no frame at all still fails outright, since nothing
is ever half of a positive number and still zero.

The class floor (`min_nonblack_for()`, keyed on `ui: text-console`) is not
gone — it is the fallback for the station that has no usable before-frame to
be relative to: the before-capture itself failed, or (a `--resume` run) it
predates this check. A missing before-frame must never make a station
un-gateable, only less precisely gated, so `effective_floor()` falls back to
`min_nonblack_for(entry, --min-nonblack)` alone in that case. A before-frame
that itself read a flat 0 % is treated the same as "missing" — it is
indistinguishable from a bad capture and would let a still-dead after-frame
pass by "matching its own baseline".

Both floors — class and relative — only ever *lower* what `--min-nonblack`
was passed as, never raise it: an operator's explicit floor is a ceiling
neither computation can exceed. A dead station is blank, not dim, so a
station that comes back black still fails regardless of how dim it was
before. The failure message prints the measured value, the floor it was held
to, and the before-restart reading when there was one, so the numbers to use
are in the output. If a new station's brightness swings by more than half
between two ordinary frames (rare — nothing observed does), lower
`--min-nonblack` for that run rather than dropping the gate.

### A halt is usually the gate being wrong — but never assume it

The two `text-console`/floor stories above (`alpine`, `mpf2`) both had the
same shape: a real, healthy screen tripped a bad floor, and overriding the
gate to let the wave through was correct. That pattern is real and it
repeats — but it is a pattern about symptoms, not a license to skip the
check. On the same rollout day, `c128` failed with the identical symptom
(a near-black frame, gate says unhealthy) on the strength of that exact
analogy — and this time the override was **wrong**: `c128`'s VICE guest was
genuinely dead. Two identical-looking failures had opposite causes.

**The discipline this earns:** before overriding a gate failure, look at the
actual frame yourself and confirm the station is showing something a visitor
would recognize as that exhibit — every time, even the tenth time this
session, even when the last five overrides were all correct. A `nonblack_pct`
number below a floor tells you the frame is dark. It does not tell you why.

`c128` was also a reminder of why AGENTS.md rule 9 exists in the first
place: its unit was `active`, its daemon had logged a clean `LISTENING` line
from the current MainPID, and it was still serving nothing. The guest
process had died, and the daemon does not relaunch a dead guest on its own —
it retries a resume against the now-nonexistent pid forever
(`[idle] resume retry failed (pid … No such file or directory)`,
`streamhost/streamhost/src/idle.rs`). Tiers 1 and 2 of the gate (readiness,
settle) were green throughout. Only the framebuffer showed the station was
dead. `systemctl restart` fixed it.

**Reproduce a gate failure with the gate's own probe, not a different
tool.** `labctl shot` captures with `resume=True`, which thaws a paused
guest; the rollout gate always captures with `resume=False` (above). Using
`labctl shot` to "double-check" a gate failure answers a different question
than the one the gate asked, and it cost real time on 2026-08-31: comparing
the two tools' readings produced a confident, wrong diagnosis ("transient
torn read") that stood until a controlled re-test with the gate's own
capture path. To reproduce a failure the way the gate saw it, run:

```
scripts/dev/labrun scripts/host/fleet-rollout-probe.sh frames <tile>
```

### The settle interval races the daemon's own idle-pause

The daemon idle-auto-pauses an unwatched exhibit ~60 s after it starts
("paused is not parked", below) — and the frame gate captures its after-frame
at readiness + `--settle` (default 45 s), close enough to that boundary that a
slow wave can land the capture right as the guest is going idle. For a
QMP-backed station this is harmless: the guest freezes, and its last frame is
still its current screen. For a **shm-capture** station (host-native MAME,
e.g. `mpf2`, `zxspectrum`) it used to be a hard failure: the emulator is
SIGSTOPped by pidfile, which can freeze it mid-write to its shm framebuffer —
the wire format is a seqlock (`scripts/shmshot.py`), and a sequence frozen ODD
stays odd *forever* once there is no live writer left to flip it back.
`shmshot.py`'s own untorn-read wait is built to wait out a *moving* writer;
against one that is confirmed (via `/proc`, not guessed) never going to move
again, that wait is not just unneeded, it is unsatisfiable, and fails
**deterministically** — every retry, every time. That is what halted a
67-station rollout on `mpf2` and, separately, on `zxspectrum`: not a flaky
read, a race between the settle window and the idle-pause.

`scripts/host/fleet-rollout-probe.sh` now detects this specific case: a shm
tile independently proven SIGSTOPped (via `proc_stopped()`, a kernel fact) is
read once with no seqlock wait (`read_frozen_shm_frame`) — the mmap cannot
change under a frozen process, so a second read now would return
byte-identical content to the first, and there is nothing left to wait for.
This never resumes anything; it duplicates `shmshot.py`'s header parsing
rather than adding a relaxed-read mode to the shared file, since that file is
also `labctl shot`/`assert`'s and loosening its read discipline for every
caller is a decision bigger than this tool.

The race itself is not eliminated, only its shm-side failure mode: a wave
whose settle interval reliably straddles the 60 s idle-pause boundary is still
worth shortening. `--settle 20` (well under 60 s) captures every station
comfortably before idle-pause has a chance to land, at the cost of a shorter
"is this guest going to fall over" window for a station that does not use shm
capture.

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
rather than trusted from the journal. Original wave boundaries are kept. A
station marked `FAILED` (as against `DONE`) is not "done" for this purpose —
it stays pending and is retried on the next `--resume --apply`.

Resuming is safe to lean on, including a resume that only ends up touching a
single wave: the fresh re-probe means a station that became claimed, busy or
stopped in the meantime is correctly re-skipped rather than restarted anyway.

**In `--mode promote`, a resumed promote-wave for a station already sitting
on the target artifact is a no-op at the pointer-move layer** —
`build-deploy.sh --promote` skips anything already on the gated artifact
(`promote_canary`'s `tile_on_artifact` check) — but that station still runs
the full settle-and-frame gate for its wave. If the gate then fails on it,
that is the gate failing to see a healthy station (see "verify with the
gate's own probe" above), not a promotion that silently broke something.

## Cost, and the rough shape of a run

For planning: at default settings (`--wave-size 4`, `--settle 45`) a full
fleet is on the order of 18 waves — one canary station, then the rest in
fours — each wave taking roughly a couple of minutes including its settle
and per-station frame captures. A full-fleet rollout is well under an hour
of supervised time; see the measured 25–30 minutes below.

The box-side probe is why this is cheap enough to run per wave. `labctl health
--json` fleet-wide reads each tile's whole boot journal (`journalctl -b -o
json`, ~21k lines, ~4 s per station) and **took over ten minutes without
finishing**. The same facts come out of `query-status` (0.16 s for all 49 QMP
tiles) plus a bounded 400-line journal tail (0.065 s per station): the whole
fleet snapshot takes **4 seconds**, and a three-station framebuffer grab takes
0.7 s. The before/after floor doubles the framebuffer grabs per wave (one
before the restart, one after the settle) — still under a second per wave at
that rate, well inside the noise of the 45 s settle it sits next to.

A default rollout is 67 stations in 18 waves; at ~90 s per wave that is roughly
25–30 minutes of supervised time.

# Instant-ready bring-up — launch the fleet restored-but-paused

**Goal.** `systemctl start streamhost@<tile>` (and therefore a labhost reboot)
should leave each loadvm station sitting AT its checkpoint state, vCPUs stopped, ~0
CPU, waking sub-second on the first visitor session — instead of today's
behavior where every restored guest runs free for ≥ 60 s until the idle
pauser's grace expires. The 2026-08-11 full-fleet bring-up put the 1-minute
load at 67 almost entirely from that window (55 restored guests executing
concurrently, stacked on the few true cold-booters).

**Mechanism.** QEMU `-S` next to the existing conditional `-loadvm golden`:
the guest restores the snapshot at startup and stays paused. No daemon change:
`idle.rs session_started` already issues an unconditional `cont` before
priming video, so the first visitor wakes a start-paused guest exactly like an
idle-paused one; the reconciler's first post-grace `stop` is an idempotent
no-op that converges its pause belief. The `-S` rides the SAME conditional as
`-loadvm golden` — a first-ever capture (no snapshot yet) must still cold-boot
RUNNING for golden-bake.sh to drive.

**Pilot (cohort 1): alpine** — bring-up station #1, checkpoint-scene LiveCD,
launcher tail is guest-independent (QMP hostfwd only). Pilot answers the two
real unknowns ON the production station (operator waived the clone rule here —
the one-line change deployed for real is less work than a rig):

1. `-S -loadvm golden` = restored AND paused (query-status), ~0 CPU.
2. The daemon against a paused guest: dbus handshake, first frame from the
   restored surface, cert publish, LISTENING, ticket accepted. If no frame
   arrives until `cont`, this plan pivots to the daemon-side fallback (an
   initial pause issued right after first frame instead of after grace) —
   smaller win, zero launcher churn.
3. Wake: QMP `cont` → framebuffer live; the reconciler re-pauses within
   grace+heal on its own (that re-pause is part of the proof).
4. `reset-tile.sh alpine` still works against a paused guest.

**Cohort 2 — the uniform verbatim loadvm launchers (~48 stations).** String-form
`LOADVM="-loadvm golden"` conditionals (~40), array form `LOADVM=(-loadvm
golden)` (4: check each), inline unconditional `-loadvm golden \` (redstar2,
solaris, reactos), postmarketos' branch-set var. Same one-line pattern each.
Deploy = ship tracked launcher byte-for-byte (what verbatim emit does), roll
by bring-up group, per-cohort acceptance below.

**Cohort 3 — the bespoke tail:**
- 6 generic-mode loadvm stations (haiku, helenos, ninefront, win2000, redstar3,
  sailfishos): their GENERATED launchers never `-loadvm` at launch (cold boot
  every bring-up; loadvm only on live reset). Needs a generator flag (e.g.
  `--loadvm-launch`) emitting the same conditional block, then re-emit; also
  fixes their bring-up cold boots outright.
- msdoswin1: restores via a bespoke path (no `-loadvm` in args) — read and
  adapt individually.
- win11: only launcher whose tail waits on the GUEST (ssh) — either guard the
  wait or leave win11 running-at-start; decide when reached.

**Explicitly out of scope:** openvms/serenityos/toaruos (restart-mode: cold
boot is the design; idle pause already bounds them), irix (livewatch needs the
guest running through its 780 s warmup; has its own instant-restore machinery),
w2kalpha (es40 restore-under-load unverified — pause path fixed 2026-08-11,
restore path is a separate re-verify), the four never-pause stations (amiga,
daybreak, nextstep, star; SH_IDLE_PAUSE_SECS=0 — separate policy item).

**Acceptance per cohort** (framebuffer is the only proof of guest state):
started station reports paused at ~0 CPU; one station per cohort woken (cont) to a
live framebuffer and left to the reconciler to re-pause; reset path exercised
once per cohort; `check-stream-tickets.py` all-green after each group; final
full-fleet restart drill with the load ceiling recorded.

**Rollback:** per station, revert the launcher line and restart the unit; the
snapshot, overlay, and daemon are untouched throughout.

## Results (2026-08-11, all cohorts SHIPPED)

- **Pilot (alpine):** `-S -loadvm golden` = runstate `prelaunch` at 0.0% CPU;
  the daemon received a first frame FROM THE RESTORED SURFACE, published its
  cert and LISTENed; QMP `cont` → keystroke echoed on the framebuffer; the
  reconciler re-paused it unaided; `reset-tile.sh` on a paused guest lands AT
  the checkpoint, still paused (with a visitor connected the guest is running, and
  loadvm keeps it running). Ticket accepted throughout.
- **Cohort 2 (42 verbatim launchers):** rolling restart in bring-up order —
  all 42 paused at start, 0 failures, 1-min load stayed ~13 (the 2026-08-11
  morning bring-up with running restores had hit 67).
- **Cohort 3:** generator `--loadvm-launch <qcow2>` (byte-parity proven: an
  unflagged generic station emits byte-identical output). Six generic stations
  emitted + restarted — ninefront/win2000/redstar3 had loadvm'd
  unconditionally via `--extra` (a missing snapshot failed the launch); the
  flag supersedes that inline arg with the tolerant conditional. msdoswin1's
  bespoke QMP path now does stop→loadvm, cont only when loadvm did not
  restore (`qmpc` always exits 0 — success is matched on `{"return": ""}`).
  win11's feared guest-wait was a grep false positive (its qga chardev line);
  it took the standard one-liner. All paused after restart.
- **Fleet census after rollout:** 53 QEMU stations paused (prelaunch/paused),
  the only runners the four never-pause stations, irix + w2kalpha SIGSTOPped
  (state T). All 60 stations accept their tickets.
- **The never-pause exclusion is load-bearing:** a station with
  `SH_IDLE_PAUSE_SECS=0` has NO IdlePauser, so nothing would ever `cont` a
  start-paused guest — `-S` there produces a permanently dead exhibit. Any
  future pause-arm for amiga/daybreak/nextstep/star must land BEFORE their
  launchers gain `-S`.
- **sailfishos is broken independently of this work**: its guest image
  (`/data/gallery-guests/SailfishOS/…`) does not exist on labhost and the
  per-station daemon dir `/usr/local/lib/streamhost/stations/sailfishos/` was never
  installed — the unit crash-loops if started. Stopped, left disabled
  (operator's enablement exclusion). Needs media restore + daemon symlinks
  before it can ever run.

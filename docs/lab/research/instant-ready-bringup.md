# Instant-ready bring-up — launch the fleet restored-but-frozen

**Goal.** `systemctl start streamhost@<tile>` (and therefore a host reboot)
should leave each loadvm tile sitting AT its golden state, vCPUs stopped, ~0
CPU, waking sub-second on the first visitor session — instead of today's
behavior where every restored guest runs free for ≥ 60 s until the idle
pauser's grace expires. The 2026-08-11 full-fleet bring-up put the 1-minute
load at 67 almost entirely from that window (55 restored guests executing
concurrently, stacked on the few true cold-booters).

**Mechanism.** QEMU `-S` next to the existing conditional `-loadvm golden`:
the guest restores the snapshot at startup and stays paused. No daemon change:
`idle.rs session_started` already issues an unconditional `cont` before
priming video, so the first visitor wakes a start-frozen guest exactly like an
idle-paused one; the reconciler's first post-grace `stop` is an idempotent
no-op that converges its pause belief. The `-S` rides the SAME conditional as
`-loadvm golden` — a first-ever bake (no snapshot yet) must still cold-boot
RUNNING for golden-bake.sh to drive.

**Pilot (cohort 1): alpine** — bring-up tile #1, golden-fixture LiveCD,
launcher tail is guest-independent (QMP hostfwd only). Pilot answers the two
real unknowns ON the production tile (operator waived the clone rule here —
the one-line change deployed for real is less work than a rig):

1. `-S -loadvm golden` = restored AND paused (query-status), ~0 CPU.
2. The daemon against a paused guest: dbus handshake, first frame from the
   restored surface, cert publish, LISTENING, ticket accepted. If no frame
   arrives until `cont`, this plan pivots to the daemon-side fallback (an
   initial freeze issued right after first frame instead of after grace) —
   smaller win, zero launcher churn.
3. Wake: QMP `cont` → framebuffer live; the reconciler re-freezes within
   grace+heal on its own (that re-freeze is part of the proof).
4. `reset-tile.sh alpine` still works against a paused guest.

**Cohort 2 — the uniform verbatim loadvm launchers (~48 tiles).** String-form
`LOADVM="-loadvm golden"` conditionals (~40), array form `LOADVM=(-loadvm
golden)` (4: check each), inline unconditional `-loadvm golden \` (redstar2,
solaris, reactos), postmarketos' branch-set var. Same one-line pattern each.
Deploy = ship tracked launcher byte-for-byte (what verbatim emit does), roll
by bring-up group, per-cohort acceptance below.

**Cohort 3 — the bespoke tail:**
- 6 generic-mode loadvm tiles (haiku, helenos, ninefront, win2000, redstar3,
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
restore path is a separate re-verify), the four never-pause tiles (amiga,
daybreak, nextstep, star; SH_IDLE_PAUSE_SECS=0 — separate policy item).

**Acceptance per cohort** (framebuffer is the only proof of guest state):
started tile reports paused at ~0 CPU; one tile per cohort woken (cont) to a
live framebuffer and left to the reconciler to re-freeze; reset path exercised
once per cohort; `check-stream-tickets.py` all-green after each group; final
full-fleet restart drill with the load ceiling recorded.

**Rollback:** per tile, revert the launcher line and restart the unit; the
snapshot, overlay, and daemon are untouched throughout.

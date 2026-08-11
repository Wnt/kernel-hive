# "The station is stopped" — making it true

**Status: fixed and installed 2026-08-03.** Reproducer and regression check:
`scripts/dev/tile-lifecycle-check.sh <tile>`.

## The bug

After `systemctl stop streamhost@irix`, an orphaned
`bash /data/vms/streamhost/stations/irix/x11-runtime.sh --livewatch` was still
running. It kept its relaunch budget, so the *stopped* exhibit could have
restarted its own guest. It had to be killed by hand, by PID.

That is not only an ops bug. Most of this project's performance work is done
"with the stations stopped", and until now that sentence was not reliably true —
an unaccounted MAME could have been competing for the same cores as a
measurement.

## Root cause — two independent defects, each sufficient

**1. The guest ran in a cgroup systemd never associated with the service.**
`ensure-station-x11.sh` (IRIX) and `ensure-station-qemu.sh` (the four bridge kiosks)
launched via `exec systemd-run --scope --unit qcap-<tile>-<ts> -p MemoryMax=3G`.
That is a *transient scope*: a sibling unit in `system.slice`, with no
dependency on `streamhost@<tile>.service` whatsoever. Observed directly on a
clone of the production configuration:

```
CGroup /system.slice/system-streamhost.slice/streamhost@wdtest.service:
└─1619681 /usr/local/lib/streamhost/stations/wdtest/current      <- the daemon, alone

CGroup /system.slice/qcap-wdtest-1785775501.scope:            <- everything real
├─1619481 …/mame/sgi indy_4610 …
├─1619675 bash …/x11-runtime.sh --bootwatch
└─1619677 bash …/x11-runtime.sh --livewatch
```

No `KillMode=` on the service can reach that second cgroup. Teardown therefore
rested *entirely* on `ExecStop` → `stop-station-x11.sh` finding every pidfile.

**2. `KillMode=process` leaked the service's own cgroup too.** For the 25 plain
QEMU tiles there is no scope: the launcher backgrounds QEMU straight into the
service cgroup. Under `process`, systemd signals only the main process, so any
descendant `ExecStop`'s pidfile pass did not know about simply survived.

**And the pidfile pass had in fact drifted.** The labhost copy of
`stop-station-x11.sh` was an older revision that killed `bootwatch.pid` and
`mame.pid` but not `livewatch.pid` — the repo already had that line. A teardown
that depends on one script being in sync is a teardown that will eventually
fail; the whole point of the fix below is that it no longer has to be right.

## The fix

- **`streamhost@.service`: `KillMode=process` → `KillMode=mixed`.** SIGTERM
  still goes only to the daemon, and `ExecStop` still owns the graceful, ordered
  teardown (watchdogs first, then the guest) — but whatever is left in the
  cgroup afterwards is now SIGKILLed instead of orphaned.
- **The qcap scopes are `BindsTo=` their service** (`ensure-station-x11.sh`,
  `ensure-station-qemu.sh`). When the service leaves the active state for any
  reason — stop, restart, crash, failure — systemd stops the scope, and a
  scope's default `KillMode=control-group` takes the whole tree with it.
- **`bring-up-all.sh` no longer creates those scopes itself.** A scope started
  before `systemctl start` cannot be bound to a service that is still inactive,
  so it would reintroduce exactly the unbound cgroup. The unit's own idempotent
  `ExecStartPre` creates the bound scope instead.

### Why not `After=`

`-p BindsTo=… -p After=…` **deadlocks the start transaction**: the scope's start
job waits on the service's start job, which is blocked in the `ExecStartPre`
that is trying to create the scope. Observed as
`Job for wdprobe.service failed because a timeout was exceeded`. `BindsTo=`
implies no ordering, which is what is wanted here — `ExecStop` runs first as
part of the service's own stop, so the graceful pidfile teardown still precedes
the cgroup sweep.

## Proof

Run against a throwaway instance of the same template (own `station.env`,
`SH_PORT`, station dir) rather than an exhibit:

```
ssh lab '/path/to/tile-lifecycle-check.sh <tile>'
```

Five rounds, all PASS after the fix: three plain start→stop cycles, one stop
issued while the liveness watchdog was inside its 3-second probe sleeps, and one
`systemctl restart` (new scope, exactly one bootwatch and one livewatch, old
tree gone). Counterfactual control: reverting only `KillMode` to `process` puts
an untracked descendant back in the service cgroup after the stop.

**The watchdog still heals** — that is the regression that matters, since a
watchdog which dies with its service but no longer self-heals a wedged guest is
worse than the bug. With the fix installed, SIGKILLing MAME by its pidfile was
detected and repaired in ~45 s (`livewatch: guest unresponsive; relaunching MAME
(attempt 2/3)`), and the relaunched MAME landed *inside the bound scope*
(`0::/system.slice/qcap-<tile>-<ts>.scope`), so it dies with the service too.
Verified on the real framebuffer, not the log: the shm screendump showed the
guest re-running its "Starting up the system…" boot.

# Idle auto-pause — tiles sleep when nobody watches, resume live on visit

Since 2026-07-12 (branch `perf/idle-cpu`) streamhost freezes its guest when no
browser session has been connected for a grace period, and resumes it the
instant a new session arrives. Combined with receiver-gated encoding this takes
the box's no-visitor load from ~83% of the host to the low single digits.

## Two mechanisms, one policy

The session lease, the grace clock, the reconciler and its self-heal are shared;
only the verb differs, chosen per tile at daemon start (`idle.rs::Freezer`):

| Tile kind | Freeze / thaw | Selected by |
|---|---|---|
| QEMU (the fleet) | QMP `stop` / `cont` on the tile's monitor | `SH_CAPTURE=qemu` |
| x11/shm emulator (`irix`) | `SIGSTOP` / `SIGCONT` on the emulator process | `SH_IDLE_PAUSE_PIDFILE` |

An x11/shm tile has no QMP socket at all, so it had no auto-pause until
2026-08-05 and its MAME ran flat out around the clock (~55% of a core,
unwatched). Signalling the process is the same bargain as freezing vCPUs: ~0%
CPU while paused, RAM/disk state untouched, sub-second thaw.

## Why

Measured 2026-07-12 with zero clients connected (per-cgroup 20 s sampling):

| Idle offender | Host CPU | Mechanism |
|---|---|---|
| Bridge-tile QEMUs (apple2/atarist/amiga/c64) | ~31% | in-guest emulators (linapple, VICE) run full-speed 24/7 |
| streamhost zero-client encode | ~23% | guest damage fed x264 even with 0 receivers |
| Other tile QEMUs busy at idle | ~12% | sailfishos churn, templeos busy-loop, CDE clock, … |
| 2 ms encode poll ×28 daemons | ~2% | 500 wakeups/s/tile even unwatched+static |

The auto-pause covers the two QEMU rows with ONE mechanism — no per-OS idle
driver work (HLT TSRs etc.) needed.

## Behavior

* **Zero sessions for `SH_IDLE_PAUSE_SECS` (default 60 s) → freeze.**
  The guest stops executing and its CPU goes to ~0. Pause ≠ `loadvm`: guest RAM
  and device state are untouched, so the tiles without a golden snapshot
  (serenityos, toaruos, sailfishos — see the `labctl` matrix) are safe.
* **Session accepted → thaw + forced keyframe** (before video priming),
  so the visitor sees the live screen sub-second. A tile that was paused
  mid-boot visibly finishes booting in front of the visitor — this is the
  intended UX ("load a snapshot, start the video signal and let the visitor
  see the rest of the process live").
* **Daemon start counts as idle**: an unvisited tile pauses one grace period
  after boot — unless a warmup is configured (below).
* **Reconciler (5 s tick)** keeps the invariants:
  - a guest is never left paused while a session is active (`cont` retried);
  - a believed pause is re-asserted every 60 s, so an external `cont`
    (labctl, manual QMP) self-heals — the guest re-freezes within
    ≤ grace + 60 s of the last visitor.
* **QMP discipline**: streamhost never holds the QMP socket; every stop/cont
  is a fresh transient connection with 2 s timeouts (same pattern as
  cdrv.py/labctl), so box tooling and the daemon can't deadlock each other.
* **Signal discipline** (pidfile arm): the pidfile is re-read on every
  stop/cont, so a watchdog that relaunched the emulator under the daemon is
  followed rather than signalled at a dead pid; and `SH_IDLE_PAUSE_PROC_MATCH`
  must still appear in that pid's `/proc/<pid>/cmdline`, so a stale pidfile
  whose pid the kernel recycled can never SIGSTOP an unrelated process. Any
  failed check is a skipped tick, never a signal sent elsewhere.

## Warmup — when freezing too early starves a tile's own health machinery

`SH_IDLE_PAUSE_WARMUP_SECS` withholds the **first** freeze for that long after
daemon start (resumes are never withheld). Default `0`; only `irix` sets it.

The case it exists for is not a comfort margin, it is a starvation deadlock. A
tile's watchdogs can only vet a guest that is *running*:

* `irix`'s `livewatch` waits `IRIX_LIVE_GRACE=600 s` before its first pointer
  probe — deliberately, because probing during a boot or an xdm login restart
  produces false deaths.
* That passing probe is the **only** thing that clears `.state-tries`, the
  instant-restore budget (issue #44). Two restore launches without a proven-
  healthy guest fall back to the ~390 s cold boot instead of the ~5 s restore.

Freeze at 60 s and the probe never happens on an unvisited tile, so the budget
only ever ratchets up: after two unvisited restarts every launch cold-boots, and
nothing says so — the fastest-visible symptom is an operator wondering why
instant restore "stopped working". `780 s` covers the grace, the three static
samples that arm a probe, and the probe itself, so every launch is vetted once
and then sleeps for good.

**Setting this on a new tile is a judgement about that tile's watchdogs**, not a
default to copy: if a tile has no health machinery that needs a running guest,
leave it at `0`.

## Interactions

* **labctl** (`scripts/labctl` == `/usr/local/bin/labctl`): every driving verb
  (`shot`/`type`/`key`/`sh`/`exec`/`reset`) thaws the guest first — screendumps,
  console typing and in-guest ssh hang on a frozen guest — using whichever
  mechanism that tile uses (HMP `cont`, or `SIGCONT` when the tile declares
  `SH_IDLE_PAUSE_PIDFILE`). `reset` conts before `loadvm golden` so the restored
  state is running. `labctl health` reports the paused state on both arms and
  never thaws anything. No cleanup needed; the daemon re-freezes the guest on
  its heal tick.
* **Emulator-tile watchdogs** (`tiles/irix/x11-runtime.sh`): a deliberately
  frozen emulator wears the exact costume of a dead one — the framebuffer stops
  changing and an injected pointer nudge moves nothing, which is verbatim what
  `bootwatch`/`livewatch` are built to detect. Both consult `mame_stopped()`
  (the kernel's `/proc` state, not a flag either side sets) and stand down while
  MAME is stopped. Without that check the pauser and the watchdog fight: the
  daemon freezes an idle exhibit, the watchdog calls it dead and relaunches it,
  and the tile reboots itself on a timer forever while nobody is watching. **Any
  new watchdog over a signal-paused tile owes the same check.**
* **Guest clocks freeze while paused.** Clock-set is a tile-load-time concern
  by design. Long-idle in-guest TCP/ssh sessions may drop after a long pause.
* **RSS guard** (capture.rs): unaffected — a paused guest emits no display
  updates and its RSS is static; the guard keeps polling harmlessly.
* **Receiver-gated encode** (encode/mod.rs `should_feed`): with zero receivers
  nothing feeds x264 — this covers the grace window while the guest still runs,
  and any tile with auto-pause disabled.
* **Measurement tooling**: anything that expects a guest to make progress with
  no viewer attached (in-guest timers, soak scripts driven via hostfwd without
  labctl) must either connect a WebTransport session, use `labctl`'s
  auto-cont verbs, or set `SH_IDLE_PAUSE_SECS=0` for that tile.

## Bridge-fronted Proxmox VMs (not streamhost tiles)

Any future VM reached through a TCP bridge instead of streamhost can get the
same idle management from the outside via `scripts/vm-idle-watch.sh` (deploy on
the Proxmox host):

```
systemd-run --unit=vm-idle-watch-940 \
  /data/vms/streamhost/serve/vm-idle-watch.sh 940 60 8120,8121
```

* Polls the configured bridge listen ports every 2 s
  for ESTABLISHED client connections; zero viewers past the grace →
  `qm suspend <vmid>` (pause — vCPUs freeze, RAM/state kept, NOT `--todisk`,
  NOT shutdown); any viewer → `qm resume <vmid>` within one poll. QEMU's VNC
  server answers on a paused VM, so the visitor connects to a frozen frame
  that comes alive ≤2 s later.
* **Historical canary (2026-07-12):** a now-deleted bridge-fronted guest dropped
  from 138% of a core idle to 0.5% paused, resumed ≈1–2 s after a viewer's TCP
  connect, and re-suspended after grace.
* No managed gallery VMs are live today. If one is recreated, run a watcher
  instance against its bridge port(s).

## Knobs

* `SH_IDLE_PAUSE_SECS` / `--idle-pause-secs` — grace seconds; `0` disables;
  nonzero clamped to ≥ 5. Default **60**, on for every tile. Per-tile opt-out:
  add `SH_IDLE_PAUSE_SECS=0` to `/data/vms/streamhost/tiles/<tile>/tile.env`
  and restart `streamhost@<tile>`.
* `SH_IDLE_PAUSE_PIDFILE` (env-only) — pidfile of the process to freeze on a
  NON-QEMU tile. Unset on a non-QEMU tile means no auto-pause at all: signalling
  a process is not something the daemon will infer. Ignored on QEMU tiles, which
  always use their monitor.
* `SH_IDLE_PAUSE_PROC_MATCH` (env-only) — substring that must appear in the
  pid's cmdline before it is signalled. Unset = no check; set it. `irix` uses
  `indy_4610`, MAME's machine name.
* `SH_IDLE_PAUSE_WARMUP_SECS` (env-only) — withhold the FIRST freeze this long
  after daemon start. Default `0`. See "Warmup" below. `irix` uses `780`.

The daemon prints which mechanism it resolved at start:

```
[streamhost] idle auto-pause ON (grace 60s; all platform transports; \
  SIGSTOP/SIGCONT on pid from /data/vms/streamhost/tiles/irix/mame.pid)
```

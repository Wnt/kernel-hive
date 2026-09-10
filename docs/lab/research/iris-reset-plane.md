# Iris reset plane — measured record (stream D, 2026-09-10)

What a host-native `indyr4400` reset costs, what it needed, and the two defects
that had to be fixed before it worked. Written for stream E to fold into
[`docs/guests/indyr4400.md`](../../guests/indyr4400.md); the mechanism itself is
documented in the fork (`Wnt/iris`, branch `kh-native-reset`, `src/kh_ctl.rs`)
and the tooling in [`scripts/build-guests/irix/iris-golden/`](../../../scripts/build-guests/irix/iris-golden/).

Everything below was measured on a rig under `/data/vms/sandbox/iris-d/rig/`,
never on the live station: IRIX 6.5 on the station's own asset
(`irix65-r4400-disk.ext4`, loop-mounted read-only, COW overlay in the rig dir),
Iris at `kh-native-reset`, features `chd,jitv2,lightning,opcodefusion,rex-jit,tlbvmap`.

## The numbers

| | |
|---|---|
| cold boot to a settled screen | **375 s** (the doc's "~7 minutes", confirmed) |
| launch → restored guest (`IRIS_STATE=golden`) | **4.1–5.9 s** = 2.6–4.3 s warmup + 1.5–1.7 s restore |
| `LOADST <name>` from disk | **1.4–1.6 s** |
| `LOADST`/`RESET` via the in-memory rollback checkpoint | **0.19–0.25 s** |
| `SAVEST <name>` (256 MB RAM + COW overlay) | **0.9–2.6 s** |
| checkpoint on disk | 8.2 MB per snapshot + a 115 MB shared CAS chunk store |

For scale: the station's reset today is a QEMU `loadvm golden`; the MAME-native
stations reset in 0.4 s through the same `mamectl/1` verb this plane implements.
A reset that misses the in-memory path still beats the 16 s a service restart
costs, and the cold boot it replaces by two orders of magnitude.

## The verbs, and where they live

`SAVEST` / `LOADST` / `RESET` / `FBSYNC` / `CKPT` on a `mamectl/1` unix socket
(`IRIS_KH_CTL_SOCK`), spoken verbatim, so `/root/mctl.py`, `mame_sock.rs` and
`scripts/serve/reset-tile.sh`'s `relaunch` branch all drive it unchanged — the
production box client was used for every verb in this record.

**They ride the station's ONE socket** since the 2026-09-10 integration: stream
C's `src/ctlsock.rs` owns `IRIS_CTL_SOCK` and routes these verbs here through
the two-function merge hook at the top of `src/kh_ctl.rs`, applying them on its
engine thread. `IRIS_KH_CTL_SOCK` and this module's standalone listener are
gone — they existed only so this plane could be proven before the input plane
landed. It has to be one socket because `mame_sock.rs` gives a station exactly
one `SH_MAMECTL_SOCK` and `reset-tile.sh` sends `LOADST golden` down it.

The ledger's warning about `IRIS_CI_SOCK` survived the integration and got
worse: arming Iris's ci socket costs the FRAME plane outright (measured
2026-09-10 — ten minutes, ~200 % CPU, no frame published; empty, first frame in
19 s), so the station ships with it empty and this plane never needed it.

`LOADST <name>` prefers Iris's in-memory rollback checkpoint when it describes
the same snapshot and the disk otherwise, so the station's existing
`LOADST golden` gets the 0.2 s path for free.

## The two defects that had to be fixed

Both made a restored guest look healthy in every check a station runs.

**1. A restore reinstates an interrupt LEVEL; the guest is waiting for an
EDGE.** `Ps2Controller::load_state` restores the i8042 receive queue with bytes
still in it, and the IOC restores KBD_MOUSE already asserted — it was asserted
when the snapshot was taken. The guest kernel in the *restored* process never
acknowledged that interrupt and is waiting for the next edge, which never
comes, because `update_interrupt` only states a level and the level is already
true.

The symptom is a guest that is alive by every measure — CPU running, X
repainting, `ps2 status` reporting `running=true scanning_enabled=true
mouse_enabled=true`, the i8042 config byte's disable bits clear — with
`rx_queue_len` climbing and never draining, and a desktop that takes no input
for the life of the process.

The discriminating measurement: restoring **in the same process that captured
the snapshot** was fine every time (that process's live interrupt line happened
to be deasserted, so the first key made a real edge); restoring in a **fresh
process** was dead every time. A station restores in a fresh process on every
launch, so this would have shipped as "the exhibit is frozen" with clean logs.
Fixed by deasserting and reasserting after every restore
(`resync_interrupt_after_restore`) — the analogue of MAME's
`reseed_after_restore`.

**2. A restore into a machine that has never executed is not safe.** Iris has
no `--restore` CLI flag, so the fork restores from `IRIS_STATE` at startup.
Restoring immediately, into a machine whose CPU has not run an instruction,
reproduces the same dead-input state. The launcher now starts the CPU and waits
for the guest to reach a real milestone — VC2 having decoded a display mode,
which is zero until the PROM programs the video timing generator — and only
then restores. It is a fact about guest execution, not a guessed duration
(rule 14), and `KH_WARMUP_DEADLINE_MS` bounds it.

## Traps for whoever works on this next

- **`saves/<name>` is relative to the process CWD, and the CWD is wiped.**
  `Machine::save_snapshot` and `load_snapshot` both resolve it that way, so the
  launcher `cd`s to the station's work directory — and that directory is
  destroyed and recreated on every launch, because wiping it IS the reset. A
  golden written there would be deleted by the next relaunch, i.e. by the thing
  meant to restore it. The station therefore keeps its snapshots in a separate
  persistent directory bound at `/state`, with `/work/saves` a symlink to it.
  `CKPT` reports the cwd it is using for exactly this reason.
- **`--ci` redirects a `overlay = true` disk to `/tmp/iris-ci-<pid>-scsiN.overlay`.**
  For a station that throws away every guest write on restart and puts
  multi-GB of dirty sectors on the host's tmpfs. `IRIS_CI_OVERLAY_DIR` (fork)
  makes the overlay station-local; the 6.3 GB base image stays read-only either
  way.
- **The COW overlay's `.dirty` sidecar is not written on SIGTERM either**, not
  only on SIGKILL — measured: no sidecar exists after a clean-looking `TERM`.
  So the live overlay is never a reliable carrier of guest filesystem state.
  The checkpoint does not depend on it: `save_snapshot` copies the overlay and
  its dirty-sector set INTO the snapshot, and a cold start after `kill -9`
  restored a byte-identical framebuffer.
- **The monitor console has no `SO_REUSEADDR`.** Restarting the emulator inside
  the TCP `TIME_WAIT` window silently loses the console — the bind fails and
  the process carries on without it. Allow ~60 s between a stop and a start, or
  expect no console. (Upstream also hardcodes `127.0.0.1:8888`, which is a
  process-wide singleton; the fork adds `IRIS_MONITOR_ADDR`.)
- **`rex fbdump`'s `rgb.bin` is VRAM, not the composited picture.** It is the
  right thing to hash — it is the machine's own memory, with no publisher or
  capture path in between — but CI-mode windows (the IRIX visual login panel,
  the Console) only intermittently appear in it, so it is not a reliable answer
  to "what is on screen". That answer needs stream A's compositing renderer;
  under `--ci` at HEAD `rex3.renderer` is `None` and `disp status` says
  `no renderer`.
- **The emulated width is 1282x1024**, decoded by VC2 — two overscan columns
  over the nominal 1280. Stream A has to decide once whether the publisher
  crops them or the registry's geometry moves.
- ~~`Ps2::push_mouse_input` reaches the guest but IRIX does not move the
  pointer for it.~~ **REFUTED 2026-09-10.** It does, and the difference was this
  rig, not the guest: `push_mouse_input` returns early and silently unless the
  controller is running and the i8042 AUX disable bit is clear, and this rig had
  no `input_ready()` check to notice. Stream C's plane converges on the VC2
  registers from the same function.

## What is proven, and what is not

Proven on the framebuffer, on the rig, with `prove-reset.py`:
two restores byte-identical (`f8f907a41463bf5ec0759a6217004e12`) with a dirtied
frame between them (`8e115fcfb19eb4e2995131545680c3da`); input live immediately
after a restore and after a startup restore; `RESET` landing the same frame;
`kill -9` followed by a cold start restoring that same frame with no `.dirty`
sidecar in sight; and a forged provenance sidecar refused with the rule-6
message, then restoring again once repaired.

**Re-proven on the integrated build, 2026-09-10**, with the input plane merged
in and every verb on the one socket: three restores byte-identical to the
captured scene with a dirtied frame between them, input acked 5 ms after a
restore, `RESET` landing the same frame, and a `kill -9` followed by a cold
start restoring that frame with **zero** differing pixels and no `.dirty`
sidecar anywhere. Measured there: `SAVEST` 2 035 ms, `LOADST` 1 274 ms from disk
and 536 ms via the rollback checkpoint, `RESET` 387 ms, `kill -9` to a live
restored station 10.9 s, checkpoint 9.2 MB + a 124 MB shared CAS store.

**`Ps2::push_mouse_input` DOES move the VC2 cursor** — the trap below said the
opposite, and it was this rig's missing `input_ready()` gate rather than the
guest: with stream C's plane merged, `MOVEA` converges on eight of eight targets
at 0 px. The trap as written is retired.

**Still not proven: the checkpoint's CONTENT.** The bridge-era golden is the
Indigo Magic desktop of the `demos` session, and a cold boot on the integration
rig reaches the Toolchest and a console window and stops there, with no icon
column, unchanged over ten minutes. The golden must be baked from a real desktop
at cutover. That is a scene, not a redesign: every mechanism above is
content-agnostic.

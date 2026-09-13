# perq guest

Status: **LIVE** (slot 198). Three Rivers PERQ 1A running **POS G.7** under
PERQemu 0.9.5 (Mono) inside a systemd-nspawn sandbox. The wave record, the
sandbox audit and the builder are in
[`docs/lab/PERQ-WAVE.md`](../lab/PERQ-WAVE.md); this file carries the guest
facts.

## Identity and source

- Public ID / tile directory: `perq`
- Reserved slot / UDP port: `198` / `54198`
- Archetype: `beige-tower-crt`
- Emulator: PERQemu 0.9.5, upstream release zip
  (`github.com/skeezicsb/PERQemu`, GPLv3), `perqemu0.95.zip`, 44 605 339 B,
  sha256 `0df4f0c481712741a15ddde48fa3e5fa2eab134d78771bc17969b70c082460de`
- Disk: `Disks/g7.prqm`, bundled in the same release zip

## Build and device set

- Builder: `scripts/build-guests/tiles/perq.sh` (`--fetch`, `--rootfs`, `--prove`)
- Machine: PERQ-1A, 16K CPU, 2 MB, CIO + OIO (Link/Ether/Tape), Portrait
  display, **Kriz tablet**, floppy + 14-inch Shugart + QIC tape
- X display `:98`, Xvfb root **768x1048x24** inside the container; the PERQ's
  768x1024 portrait screen is the top 1024 lines at `+0+12`, the bottom 24 stay
  black (PERQemu sizes its window to SDL's usable bounds minus 24 lines, so a
  root exactly 1024 tall pans)
- Container uid base 2359296; no network (`--private-network`, and POS G.7 has
  no TCP/IP stack)

## Pointer — 1:1 absolute, PROVEN

`SH_INPUT_BACKEND=x11test`, `SH_X11TEST_ABS=1`, `SH_X11TEST_MOTION=xtest`,
`SH_X11TEST_BUTTONS=xtest`. PERQemu maps the host pointer onto the Kriz tablet
absolutely, and X delivers window-relative motion from a root-absolute XTEST
warp by itself, so **no offset and no scale compensation is needed** despite
the window sitting at `+0+12` inside the taller root.
`stream.pointer.offset = [0, 0]`, `stream.pointer.scale = 1.0`.

**Five targets, two laps, on the real 768x1048 geometry** (rig
`/data/vms/sandbox/perq-ptr`, display `:2198`, same rootfs/release tree and
uid base as the station; `scripts/dev/cursor-locate.py` exact-match readback of
the POS arrow sprite, frames under `/data/vms/sandbox/perq-ptr/frames/`):

| target (root px) | lap 1 sprite origin | lap 2 sprite origin | offset |
|---|---|---|---|
| (20, 40)     | (20, 40)     | (20, 40)     | 0 px |
| (740, 40)    | (740, 40)    | (740, 40)    | 0 px |
| (20, 1000)   | (20, 1000)   | (20, 1000)   | 0 px |
| (740, 1000)  | (740, 1000)  | (740, 1000)  | 0 px |
| (384, 524)   | (384, 524)   | (384, 524)   | 0 px |

10 of 10 exact. The pointer was moved to (384, 300) between every target, so
lap 2 is a genuine second approach, not a re-read of a resting sprite.

**Two traps, both measured, both of which manufacture false misses:**

1. **Never a fixed sleep after the warp.** PERQemu's SDL window is clocked by
   the CLI's `GetLine()` poll loop, so the sprite repaints on the emulator's
   own cadence (~12 fps, and slower on a loaded box). With `sleep 2` after each
   `xdotool mousemove`, 2 of 10 readbacks caught the frame mid-repaint and
   `cursor-locate` matched a shifted origin — (740,1000) read as (736,991) and
   (20,1000) as (23,993) in two different laps, never the same way twice. With
   `scripts/dev/fb-wait.py --x11 :98 --change --settle 2` instead, all ten are
   exact. This is rule 14 in one measurement.
2. **Crop the black bands before `cursor-locate find`.** The POS arrow's opaque
   pixels are all black, so the template also matches inside the solid black
   status bar at the top of the POS screen and the 24 dead root lines at the
   bottom — ~1800 spurious hits, reported honestly as `AMBIGUOUS`. Cropping the
   frame to rows 32..1035 (`-crop 768x1004+0+32`) and adding the offset back
   leaves exactly one match. The rig's driver is
   `/data/vms/sandbox/perq-ptr/ptr-table.sh`.

**Buttons: no reactive target on the shell scene.** All three buttons clicked
at (384, 524) on the POS shell produce `changed=0` from
`scripts/dev/fb-react.py` (status bar and cursor masked). This is not a broken
button path — POS's shell prompt simply has nothing to click. A click proof
needs a mouse-driven POS program on the framebuffer; **OPEN**.

## Golden, reset, and rollback

- `SH_RESET_MODE=relaunch`. PERQemu 0.9.5 has **no save state** (`Settings`
  offers autosave of media only; there is no `loadvm` equivalent), so the
  golden IS the pristine `g7.prqm` plus the boot script, and a reset is a cold
  boot of a fresh copy.
- **A relaunch now lands on the golden SCENE, not a login prompt.** POS G.7
  comes up at `Enter time as HH:MM or full date:` and then `Please enter your
  name:`, and before `bring_to_scene` in
  [`streamhost/stations/perq/x11-runtime.sh`](../../streamhost/stations/perq/x11-runtime.sh)
  nothing answered either, so every reset handed the next visitor a half-booted
  login rather than the exhibit. The launcher now moves the pointer into the
  window (XTEST delivers to the FOCUSED window and there is no window manager,
  so focus is PointerRoot — a Return sent with the pointer over the root
  vanishes), sends the two Returns, and waits on the framebuffer between each.
  An empty name logs in as **Guest** with no password prompt; `user` is not an
  account.
- **Login, measured by hand on the rig:** disk-mount screen at ~20 s from
  power-on, `>` shell prompt at ~50 s from power-on (`Reading profile file
  >Default.Profile` to prompt is ~20 s of that).
- **CRIU cannot checkpoint this station, and the reason is the sandbox.**
  Attempted 2026-09-13 against the container's PID 1 (criu 4.1.1,
  `criu dump -t <pid> --shell-job --file-locks --manage-cgroups=ignore
  --leave-running --ext-mount-map auto --enable-external-sharing
  --enable-external-masters`):

  ```
  (00.053339) net: Lock network
  (00.089857) id_map: 0 2359296 65536
  (00.090936) Error (criu/namespaces.c:235): Can't open 2635260/ns/net on procfs: Permission denied
  (00.096368) Error (criu/namespaces.c:997): One or more namespaces doesn't belong to the target user namespace
  (00.145517) Error (criu/cr-dump.c:2111): Dumping FAILED.
  ```

  criu reads the container's `id_map`, drops into the mapped credentials and
  then cannot reopen the task's own namespace files. All six namespaces DO
  belong to the container's user namespace — checked directly with
  `NS_GET_USERNS`: `net`, `pid` and `mnt` all report owner `user:[4026537058]`,
  which is the container's — so the message is criu's own privilege loss during
  the userns switch, not a real ownership split. Clearing it would mean running
  criu inside the container, which needs `CAP_SYS_ADMIN` and the `mount`
  syscalls that this station's sandbox deliberately drops
  (`--drop-capability=CAP_SYS_ADMIN…`, `--system-call-filter='~@mount'`). The
  nextstep route (docs/guests/nextstep.md §2) works precisely because Previous
  is a plain unprivileged host process, not a contained one. **A <2 s reset for
  `perq` therefore needs either a save state in PERQemu or a sandbox weakened
  in exactly the way the medley incident forbids — OPEN, and not a tuning
  problem.**
- Credentials reference only (never values): guest login is the name `Guest`
  with an empty password.
- Rollback: the station is env + launcher only; `git revert` the launcher
  commit and `box-deploy --apply` restores the previous behaviour. No golden
  image and no binary change is involved.

## Cost

PERQemu idles at **~200% of a core** (the CPU/microcode loop plus the CLI's
`HighResolutionTimer` spin) and never settles, so the daemon's idle freezer is
mandatory: `SH_IDLE_PAUSE_SECS=60`, `SH_IDLE_PAUSE_PIDFILE=…/mame.pid`,
`SH_IDLE_PAUSE_PROC_MATCH=/work/perq/PERQemu.exe` (the IN-container cmdline —
a host rootfs path never appears there). The launcher additionally SIGSTOPs the
emulator once the scene is reached. **Never run two PERQemu instances.**

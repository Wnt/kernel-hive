# ITS wave — MIT Incompatible Timesharing System on a SIMH PDP-10

Issue #61 · Lane B (record wave 2026-09-21) · branch `its-work` (from `origin/its`)

**STATUS 2026-09-20T09:35Z: STOOD DOWN mid-build by the coordinator (labhost
1-min load 116-139 against the documented cap of 50). Nothing was proven on a
framebuffer; no guest ever ran. This file is the resume point.**

## Allocation ledger (atomic, `wave.sh alloc its`, 2026-09-20T08:56Z)

| Station | Session | Slot / UDP / VMID | X display | retronet |
|---|---|---|---|---|
| its | its-work | 210 / 54210 / 210 | `:110` (claim `display/:110`) | — (none: terminal-only exhibit) |

Claims were **released** at stand-down (see "Teardown" below); re-run
`scripts/dev/wave.sh alloc its` on resume — it will re-take the same numbers if
they are still free, and refuse loudly if not.

Container uid base `2424832` (37*65536) — clear of medley 1966080, indyr4400
2031616, vision 2162688, perq 2359296, lisa 200000.

Scaffold: `stations-registry.py new its --like medley --production --slot 210
--tuple towerE,crtC,keyboardA,paramMouseA`. Sibling is medley because the
containment shape (nspawn + inner Xvfb + X11 capture + relaunch reset) is
identical; ITS itself is an emulated PDP-10, not a host Lisp VM.

## Measured facts (real, from this run)

| Fact | Value | How measured |
|---|---|---|
| upstream | `https://github.com/PDP-10/its.git` | clone on labhost 2026-09-20T08:57Z |
| pinned commit | `0f7d67997f9f5d30208e117e73272031e74f16b9` | `git rev-parse HEAD` after `--recursive` clone (master at fetch time; identical to the prep-branch draft pin) |
| SIMH inside it | commit `4d38373206cd7c0ce8b94f5e16bd4429cb96430f`, 2025-10-12 | printed by the SIMH makefile during the build |
| emulator binary | `tools/simh/BIN/pdp10` (KS10, `VM_PDP10 USE_INT64`) | build log |
| visitor terminal | DZ11 line 0 → TCP **10004**, from `out/simh/boot`: `set dz 8b lines=8` / `at -u dz0 10004` / `set rp0 rp06` / `at rp0 out/simh/rp0.dsk` / `b rp0` | read from the generated config |
| writable medium | `out/simh/rp0.dsk`, RP06, 317132800 bytes while being written | `ls -la` at 09:08Z (the build was killed before the disk was final — **this is not a pin**) |
| other build output | `minsys.tape` 799724 B, `minsrc.tape` 5016834 B, `reboot.tape` 6827116 B, `sources.tape` 92237900 B, `salv.tape` 113004 B, `dskdmp.tape` 64212 B | `ls -la out/simh` |
| build deps missing on labhost | `expect`, `autoconf`, `automake`, `libncurses-dev`, `libsdl2-dev`, `pkg-config` | installed at 09:02Z; `gawk`/`tcsh`/`xterm` are still absent from labhost and are not needed (xterm lives in the container root) |
| container root | `/data/vms/streamhost/assets/its/rootfs`, **364 MB**, uid 2424832 | `debootstrap --variant=minbase trixie` + xvfb, xterm, xauth, x11-utils, xdotool, telnet, netcat-openbsd, procps, iproute2, util-linux, libbsd0, ncurses-term, xfonts-base, fontconfig, fonts-dejavu-core; finished 09:07Z (**4 min**) and is ON DISK, ready to reuse |
| `./start` | symlink to `build/simh/start`; its last line is `tools/simh/BIN/pdp10 out/simh/boot` | read from the tree |
| DSKDMP dance | **not needed for `EMULATOR=simh`** — the generated config ends in `b rp0`, booting the installed disk directly. The `its` / ESC-G dialogue in the upstream README applies to the KLH10/KA10 paths | read from `out/simh/boot` |

## Measured timeline (`date -u`)

| T | Event |
|---|---|
| 08:55Z | session start, `here.sh` |
| 08:56Z | `wt.sh new its-work`; `wave.sh alloc its` (first attempt lost slot 208 to multics mid-flight, retried → 210) |
| 08:57Z | ITS clone+build started on labhost; container rootfs debootstrap started in parallel |
| 09:02Z | build deps installed (the build had already started without `expect`; it did not need it before that point) |
| 09:07Z | container rootfs **done** (364 MB) |
| 09:08Z | SIMH `pdp10` built; ITS self-assembly running (the build boots ITS inside the simulator and assembles the sources there) |
| 09:19Z | station runtime scripts written (outer launcher + inner script) |
| 09:26Z | stand-down message; build killed at ~29 min, mid `rp0.dsk` (make deleted the partial disk) |
| 09:35Z | committed, pushed, claims released |

## Runtime as written (committed, UNPROVEN)

`streamhost/stations/its/x11-runtime.sh` (outer) + `nspawn-inner.sh` (inner)
follow the medley/vision containment shape and the record-wave contract:

- outer: reap-by-`/proc/<pid>/exe` scoped to `$ITS_TREE/tools/*`, refuse a
  second survivor, recreate the host X socket dir + symlink, wipe `work/`,
  `cp --reflink=auto` the pristine `rp0.dsk` in, then `systemd-nspawn
  --as-pid2 --volatile=overlay --private-users --private-network`, tree bound
  read-only, `work/` the only writable bind, caps dropped, `~@mount` filtered;
  it returns only when the simulator pid, the X socket and a window titled
  `MIT ITS` are all real. Standby SIGSTOPs the simulator after 30 s.
- inner: Xvfb on `:110` → writes its OWN simh config in `/work` (so the
  simulator attaches `/work/rp0.dsk`, never the read-only seed; Chaosnet/GT40/
  VT52 lines dropped) → starts `pdp10` with the console going to
  `/work/console.log` → **real TCP probe of 10004** → `exec xterm -e telnet`.

This is also the answer to three of the five shared lane questions
(Xvfb socket exposure, nspawn containment, process supervision) in the shape
the medley station already proves in production; it is **not** yet committed to
`docs/lab/record-wave/shared-terminal-runtime.sh` because the ITS run never got
a frame to prove it with. mvs38 remains the pathfinder.

## The wall (for the record: it is a load wall, not a technical one)

No technical wall was hit. The build was progressing normally — SIMH compiled,
ITS was assembling itself — when the coordinator stood the station down because
labhost's 1-min load was 116 (cap 50; `uptime` at 09:27Z read
`138.98, 134.20, 111.96`). The ITS build is CPU-heavy for ~30 min by design: it
boots a PDP-10 in a simulator and assembles the whole operating system inside
it.

## Next concrete step on resume

1. `scripts/dev/wave.sh alloc its` (re-take 210 / 54210 / 210 and `display/:110`).
2. `scripts/build-guests/tiles/its.sh` on a quiet box — the container root is
   already built and the tile is idempotent, so this is the ~30 min ITS build
   only. Record `rp0.dsk` size+SHA-256 from `assets/its/MANIFEST.sha256` into
   the table above; that is the real media pin.
3. Smoke boot in the sandbox (not as a station): run the inner script's
   simulator line by hand against a copy of `rp0.dsk`, `nc -z` 10004, then the
   xterm, and take the first frame. **This frame is the first proof.**
4. `scripts/dev/smoke-rig.sh its --like medley` → `/os/its` for the operator.
5. Then, in order: xterm geometry/font that fills 1024x768 (measure with
   `xwininfo`, do not guess); Ctrl-Z login from the REAL browser; ESC/altmode
   and Ctrl-\ through the on-screen keyboard; the rest scene (a logged-in DDT
   session); reset proof (visible change → relaunch → scene returns, repeated
   from a fresh process) plus `sha256sum` of the seed `rp0.dsk` before and
   after to prove the seed is uncorrupted.

## Teardown at stand-down

- Build process tree killed by session id resolved from `/proc/<pid>/stat`
  (never a cmdline `pkill`); proof: a scan of every `/proc/<pid>/exe` for paths
  under `/data/vms/sandbox/its-work/` or `/data/vms/streamhost/assets/its/`
  returned `leftover=0`.
- No guest, no smoke rig and no station service was ever started, so there was
  nothing else to stop.
- Claims released; see the report for the `kh-claim ls` check.
- Left on disk on purpose (cheap to keep, expensive to rebuild): the container
  root `/data/vms/streamhost/assets/its/rootfs` and the partial build tree
  `/data/vms/sandbox/its-work/build/its` (submodules checked out at the pin).

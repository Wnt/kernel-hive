# ITS wave — MIT Incompatible Timesharing System on a SIMH PDP-10

Issue #61 · Lane B (record wave 2026-09-21) · branch `its-work` (from `origin/its`)

## Allocation ledger (atomic, `wave.sh alloc its`, 2026-09-20T08:56Z)

| Station | Session | Slot / UDP / VMID | X display | retronet |
|---|---|---|---|---|
| its | its-work | 210 / 54210 / 210 | `:110` (claimed `display/:110`) | — (none: terminal-only exhibit) |

Container uid base `2424832` (37*65536) — clear of medley 1966080, indyr4400
2031616, vision 2162688, perq 2359296, lisa 200000.

Scaffold: `stations-registry.py new its --like medley --production --slot 210
--tuple towerE,crtC,keyboardA,paramMouseA`. Sibling is medley because the
containment shape (nspawn + inner Xvfb + X11 capture + relaunch reset) is
identical; ITS itself is an emulated PDP-10, not a host Lisp VM.

## Device / runtime set (frozen before the reset scene)

- emulator: SIMH KA10, built by the upstream PDP-10/its tree (`make EMULATOR=simh`)
- visitor surface: `xterm` on the container's Xvfb `:110`, telnet to the ITS
  user terminal on `127.0.0.1:10004` inside the container
- operator/simulator console: logfile only, never captured
- pointer: none
- reset: relaunch from the pristine built tree (mutable disk images copied into
  `work/` on every launch)

## Media / source pin

(filled by the builder run — see `assets/its/MANIFEST.sha256`)

## Measured milestones

(filled from `date -u` as they happen)

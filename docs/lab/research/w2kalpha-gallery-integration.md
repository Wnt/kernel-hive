# w2kalpha gallery integration — state and remaining steps

Written 2026-08-11. The w2kalpha station (Windows 2000 RC2 for Alpha, es40) is a
non-QEMU streamhost station modelled on IRIX: es40 runs headless (no X server, no
window) publishing its framebuffer to shared memory (`SH_CAPTURE=shm`) and
taking input over es40's mamectl/1 socket (`SH_INPUT_BACKEND=mamesock`).

## DONE + VERIFIED

- **es40 headless capture + input** (fork `Wnt/es40`): shm framebuffer export
  (`66c5b2f`), mamectl/1 input socket (`849039a`, `6986997`). Runs under
  `SDL_VIDEODRIVER=dummy` — no X server.
- **Clean 1280x1024 checkpoint** at `/data/vms/streamhost/assets/w2kalpha/nt.img`
  (from `milestones/m5-1280`). Cold-boots to a clean desktop in ~80 s.
- **Production assets staged** `/data/vms/streamhost/assets/w2kalpha/`:
  `es40` (build `fde680f2`), `nt.img`, `rom/` (flash.rom + S3/SRM/dpr roms),
  `es40.cfg`, `w2k.iso` (CD the cfg references), `root/` (es40's shared-lib
  tree, so the station does NOT depend on the retired soltest scratch area).
- **Station launcher** `/data/vms/streamhost/stations/w2kalpha/`: `w2kalpha-runtime.sh`
  (reflink-copies the checkpoint per launch → cold-boots es40 headless + serial
  pumps), `station.env` (SH_CAPTURE=shm, SH_INPUT_BACKEND=mamesock,
  SH_SHM_PATH, SH_MAMECTL_SOCK, SH_PORT=54199, SH_RESET_MODE=relaunch),
  `pumps.py`. **Verified end to end**: the launcher cold-booted es40 from the
  staged checkpoint to a 1280x1024 desktop published on shm, and a keyboard verb
  over the socket reached the guest (Start highlighted).

The dev rig `/data/vms/soltest/ALPHA-nt/run/` is RETIRED — its working disk
was corrupted (STOP 0x7B) by repeated restore-onto-mutated-disk cycles during
input testing. The checkpoint (m5-1280 / the staged assets) is a separate clean
snapshot, unaffected.

## REMAINING

> **UPDATE 2026-08-11 (later the same day): items 2 and 3 are DONE — the station
> is REGISTERED and LIVE** as the 60th production exhibit (slot 140, udp
> 54140, `streamhost@w2kalpha` active; ticket/framebuffer/reset verified;
> repo `main` 97ce80b+4d79d21, docs/guests/w2kalpha.md is now the canonical
> station doc). Item 1 (checkpoint polish) was deferred by the operator and is the
> only remainder — until it lands, EVERY cold boot (so every reset) shows the
> Active Desktop Recovery page (observed 3/3 that day), and the pointer stays
> open-loop-inexact. The keyboard-only fix sequence is proven and recorded in
> docs/guests/w2kalpha.md §Golden. Also learned: es40's ctlsock is
> single-client — with the daemon attached, direct socket probes time out.

1. **Checkpoint guest polish, then re-capture.** On a cold-booted checkpoint, over the
   working socket keyboard (or a VNC to a windowed run):
   - **Turn OFF Active Desktop** — it intermittently drops to "Active Desktop
     Recovery", which a museum exhibit must never show. desk.cpl → Web tab →
     uncheck "Show Web Content on my Active Desktop".
   - **Set 1:1 pointer motion** (no acceleration) — the ctlsock pointer is
     open-loop and needs the guest at 1:1 for pixel-exact clicks (keyboard is
     already exact). main.cpl → Motion → Acceleration None (or
     `HKCU\Control Panel\Mouse` MouseSpeed=0, MouseThreshold1/2=0).
   - Confirm autologon-to-desktop still holds, then **clean OS shutdown** and
     re-capture `nt.img` → restage as the checkpoint. A cleanly-shutdown disk also
     avoids the NTFS-dirty cold-boot pause.
   - Re-verify pointer: MOVEA to known coordinates lands pixel-exact; a
     DOWN1/UP1 at an icon selects it.
2. **Registry entry + streamhost/UI integration.** `scripts/stations-registry.py
   new` rolls back unless the entry is complete (it needs `stream.pointer`,
   the ordering fields, binding/museum blocks). Author `registry/stations/
   w2kalpha.json` modelled on `registry/stations/irix.json` (the other non-QEMU
   shm/mamesock station): id/stationDir=w2kalpha, lifecycle candidate→production,
   stream.pointer {transport abs, backend mamesock, absolute true},
   runtime.stationEnv mirroring the station.env above, render.* binding +
   museumBlock (archetype `putty-lcd` like nt4/winxp, a 2000/Alpha blurb),
   guestDoc `docs/guests/w2kalpha.md`. Then wire the systemd unit /
   ensure-tile-x11 path as IRIX does (`stations-manifest.sh` emit line with
   `--x11-runtime-file .../w2kalpha-runtime.sh --capture shm --input-backend
   mamesock`), `make station-registry-check` green, signaling.json generated.
3. **Enable + live-verify** through the streamhost daemon: framebuffer, input,
   and the relaunch reset path, per the playbook gate, before making visible.

## Notes

- **Reset mode = relaunch (cold boot), not instant-resume.** A restored guest
  renders the desktop but paints new dialogs only partially (post-restore
  repaint fragility); cold boot renders everything. Instant-resume via
  `ES40_RESTORE` is the future fast path once that is fixed.
- Port 54199 is a placeholder; the registry `slot` assigns the real
  `54000+slot`. Align station.env `SH_PORT` to it.

# apple2 bookworm→trixie clone proof — state note (2026-08-20)

Worker session `apple2-trixie-proof` (branch `apple2-trixie-proof`) was
force-stopped by the coordinator mid-analysis of the proof-(c) anomaly.
The rig was torn down by the coordinator (clone QEMU killed via
`clone-guard kill-pidfile`, /proc scan clean). **Do not treat this as a
verdict yet — the verdict is NO-GO *pending* the anomaly below.**

## Sandbox layout (still on disk, untouched by the teardown)

- Worktree/repo: `/data/vms/sandbox/apple2-trixie-proof/repo` (branch `apple2-trixie-proof`)
- Clone overlay: `/data/vms/sandbox/apple2-trixie-proof/clone/overlay.qcow2` —
  trixie-backed (`bridge-base-trixie.qcow2`), full GEOS state preserved
  (linapple built + installed, kiosk patch applied, conf staged, GEOS deskTop
  booted, /BIGWON File window open as in the master image)
- Clone launcher: `/data/vms/sandbox/apple2-trixie-proof/clone/clone.sh`
  (VNC 127.0.0.1:5917, ssh hostfwd 127.0.0.1:15817, QMP
  `/data/vms/sandbox/apple2-trixie-proof/clone/qmp.sock`;
  relaunch = `ssh lab 'bash /data/vms/sandbox/apple2-trixie-proof/clone/clone.sh'`)
- Port claims `port/15817` + `port/5917` were taken by this session — re-check
  `/run/kh-claims/` after the teardown; re-take under `KH_SESSION` if released.
- Evidence: `/data/vms/sandbox/apple2-trixie-proof/evidence/` (paths below)

## Proof (a): LinApple compiles under g++ 14 — PASS

Full clean build of LinApple 2.3.0 inside the trixie overlay, g++ 14.2.0,
headers from `libsdl1.2-dev 1.2.68-3` (sdl12-compat wrapping SDL 2.32.4).
`src/Video.cpp` — the historic failure point — compiled first and clean;
zero errors; `build/bin/linapple` linked and installed. `ldd` shows
`libSDL-1.2.so.0` resolving to `libsdl1.2debian` (sdl12-compat), i.e. the
binary runs through SDL2. No builder change was needed.

Evidence: `evidence/build.log` (line 1 `CXX src/Video.cpp`),
`evidence/deps-sdl.txt`, `evidence/link.txt`.

## Proof (b): pointer motion + buttons, no grab — PASS with one unresolved anomaly

Verified on the framebuffer (QMP `screendump`, 1024×768 guest root;
LinApple window 1008×691 at origin (8,38); GEOS fills the window so
arrow PNG position == X-root position; tablet→root mapping
`x/32767*1024, y/32767*768`):

- Motion 1: `abs 16000 16000` → arrow glyph top-left at **(501,376)**,
  expected (500,375). Exact.
- Motion 2: `abs 8192 8192` → arrow at **(256,193)**, expected (256,192). Exact.
- Button: `click` on the GEOS `view` menu (frame (265,65) = tablet
  (8460,2783)) **opened the dropdown menu** (frame 05, changed region
  x 188..324, y 42..239 ≈ 11.8k px). A second `click` on empty desktop
  closed it again (frame 06). The arrow kept tracking after both clicks —
  no cursor-vanish, no persistent grab symptom.

Unresolved anomalies (this is what the session was analysing when stopped):

1. **Probe 02**: `abs 16000 12000` (first pointer move after ~5 min idle,
   arrow previously parked ≈(30,72)) did NOT land at the expected (500,282).
   The 01→02 diff shows changes ONLY in the top-left corner
   (bbox (8,38)-(48,95), new-dark centroid (23.7,60.3)); frame 02 shows the
   GEOS arrow sitting in the top-left corner of the menu bar (tip ≈ frame
   (8,42)) and the (500,282) area empty. (4× crops of the corner are
   `topleft-01.png` / `topleft-02.png` in the session scratchpad.)
2. **Probe 06**: the menu-closing desktop `click 8192 20480` (expected
   (256,480)) left the arrow at **(247,527)** — off by (-9,+47).

Neither looks like one of the three classic sdl12-compat regressions
(wedged / fly-to-corner / vanish-after-click) in the clean form — 03 and 04
prove the steady-state path is 1:1. Prime suspects (UNVERIFIED): the
pin-sync handshake (A2_SYNC_NEED_PIN → WAIT_HOME → SYNCED in
MouseInterface.cpp) re-triggering after idle, and/or the in-guest
`pointer-watchdog` service injecting/warping pointer events racing with the
QMP `abs`. See "Resume" below.

Also resolved during the session: the blue `FDD1 FDD2 HDD` panel visible in
the early boot frame is the transient `Show Leds = 1` drive-light status
surface (Video.cpp status blit gated on `g_iStatusCycle`/`g_ShowLeds`,
fed by `DrawStatusArea(DRAW_LEDS)` on disk activity) — idle frame 01 shows
0 panel pixels, same code and conf on both bases. State difference vs the
live golden, not a regression. The open /BIGWON File window matches the live
bookworm calibration frame content-for-content — it is the master image's
persistent state.

## Proof (c): 1:1 tracking + slot map — PARTIAL / NO-GO pending anomaly

- Slot map re-asserted by the staged conf (`Mouse in slot 4=1`,
  `Clock Enable=5`) — boot produced NO `No mouse card found` /
  `No interrupt source` dialogs (frames 00/01 clean) → slot 4 not clobbered.
- 1:1: 2 of 4 verified absolute moves (03, 04) landed within 1 px, but the
  brief's own acceptance probe `abs 16000 12000` failed (anomaly 1 above)
  and one post-button move was off by 47 px (anomaly 2). **The 1:1 claim is
  NOT proven on trixie until these two anomalies are explained.**

## Evidence (absolute paths)

```
/data/vms/sandbox/apple2-trixie-proof/evidence/build.log          # proof (a)
/data/vms/sandbox/apple2-trixie-proof/evidence/deps-sdl.txt       # sdl12-compat provenance
/data/vms/sandbox/apple2-trixie-proof/evidence/link.txt           # ldd: libsdl1.2debian
/data/vms/sandbox/apple2-trixie-proof/evidence/00-desktop.ppm     # boot, no slot dialogs (+ .png)
/data/vms/sandbox/apple2-trixie-proof/evidence/01-idle.ppm        # idle GEOS, no LED panel
/data/vms/sandbox/apple2-trixie-proof/evidence/02-abs-16000x12000.ppm  # ANOMALY 1
/data/vms/sandbox/apple2-trixie-proof/evidence/03-abs-16000x16000.ppm  # exact
/data/vms/sandbox/apple2-trixie-proof/evidence/04-abs-8192x8192.ppm    # exact
/data/vms/sandbox/apple2-trixie-proof/evidence/05-view-menu-open.ppm   # menu opened
/data/vms/sandbox/apple2-trixie-proof/evidence/06-menu-closed.ppm      # ANOMALY 2
```

Frame-to-frame arrow detection = byte-diff (dark-in-new AND light-in-base),
arrow glyph ≈ 21×20 px with the hotspot at its top-left corner.

## Resume (fresh session)

1. Relaunch the clone (overlay already at GEOS deskTop, ~instant):
   `ssh lab 'bash /data/vms/sandbox/apple2-trixie-proof/clone/clone.sh'`
   (re-take port claims first if `labctl claims` shows them gone).
2. Decouple the chain: after each `cdrv.py <qmp> abs …`, read the X pointer
   position FROM INSIDE the guest (ssh -p 15817, `xdotool getmouselocation`
   or `xwininfo -root -stats`) to tell `tablet→X` breakage from
   `X→GEOS-arrow` breakage.
3. Prime suspect for anomaly 1: the pin-sync re-handshake — check the
   linapple log in the guest for A2_SYNC_NEED_PIN/WAIT_HOME/SYNCED lines
   around the moment of the corner jump; also inspect the
   `pointer-watchdog` (asset `scripts/build-guests/assets/apple2/`) for
   injected pointer warps and disable it in the overlay for a control run.
4. For anomaly 2: re-run the view-menu click/close; try closing the menu
   with `cdrv.py <qmp> key esc` instead of a desktop click to see if the
   offset is menu-mode specific; then re-run `abs 16000 12000` from a known
   arrow position (not from idle) to see if "first move after idle" is the
   trigger.
5. Verdict: if both anomalies reproduce and get a one-line explanation that
   is trixie/sdl12-compat specific, a small kiosk-patch/builder fix goes on
   branch `apple2-trixie-proof` (no merge, no `bridge-suites.json` flip
   until the coordinator lands it).

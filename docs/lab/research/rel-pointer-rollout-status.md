# Open-loop cursor rollout — continuation brief

**Pick this up in a fresh session.** The re-home + rate-cap system
([`rel-pointer-rehome-and-rate-cap.md`](rel-pointer-rehome-and-rate-cap.md)) is
**built, landed and fleet-wide**; `macos753` is the proven canary. What remains
is rolling the per-station config out to the other relative-pointer stations,
measuring each one, and validating with the harness. This file is the
executable checklist. Start each station in its own sandbox
(`scripts/dev/wt.sh new <name>`), never on the live golden.

## What is already done (do NOT redo)

- **Daemon**: `rel_bridge.rs` re-home model + paced sender, daemon-wide
  `MouseState` (survives browser reload), `reset-tile.sh` sends SIGUSR2 after
  `loadvm` + a `cont` so Restore no longer freezes the guest. Promoted
  fleet-wide (streamhost `5c9da37`, 67 active).
- **QEMU fork** `github.com/Wnt/qemu` branch `kernel-hive @ 70c62de`, submodule
  bumped in main (`02f314c`): ADB button-barrier FIFO (drag-release lands where
  the drag ended) + autopoll 20→5 ms (≈5× cursor speed ceiling). Built into
  `/opt/qemu-m68k` (shared by macos753 + aux). Rollback binaries:
  `/opt/qemu-m68k/bin/qemu-system-m68k.pre-adbfifo-bak` (pristine) and
  `.pre-fastpoll-bak` (FIFO only).
- **macos753 — VALIDATED PASS** (tracking 4 px, reload 3 px, drag 4 px). Config:
  `SH_REL_HOME_ON=reset`, `SH_REL_HOME_TO=599,500`, RAW sends (no `SH_REL_PACED`
  — the FIFO owns ordering).
- **Tooling landed** (main `a64784c`), see next section.

## The validation harness (run it for every station)

Two tools, both OS-agnostic (guest-cursor located by QMP screendump + PIL
nudge-diff, no per-guest assumptions):

- `scripts/dev/measure-golden-cursor.py` — prints `<station> HOME_TO=<gx>,<gy>`
  from a golden screendump (arrow-tip hotspot). `--no-reset` locates the current
  cursor without restoring; `--nudge N` / `--settle MS` tune the diff.
- `scripts/e2e/cursor-track.mjs` — drives the **real SPA** in headed Chrome on
  the CT950 VNC desktop (`DISPLAY=:1`), opens `/os/<station>`, waits for live
  video, and scores tracking (5 grid points), the reload anchor, and
  drag-release. Letterbox-aware (`object-fit: contain` mapping).

Run recipe (from CT950):

```
# stage the measurement tool onto the box
scp scripts/dev/measure-golden-cursor.py lab:/tmp/mgc.py
cp scripts/e2e/cursor-track.mjs ~/e2e/           # ~/e2e has node_modules (playwright)
# GALLERY_URL must be the REAL lab origin (kept out of the repo — use the
# gitignored value from registry/local.env or the operator; default placeholder
# 192.0.2.10 will not resolve).
GALLERY_URL=https://<lab-origin>:8443 node ~/e2e/cursor-track.mjs <id> "<Card title>" <gw> <gh>
```

Pass bar (macos753 reference): track / reload / drag all **< ~5 px**.

## Per-station remaining work, in order

Each station: `wt.sh new <name>` → measure `HOME_TO` → set the two fixture
knobs → deploy the fixture (see [[streamhost-tile-env-redeploy-path]] recipe in
memory / `docs/…`) → run the harness → record the numbers here. Add
`SH_REL_HOME_ON=reset` and the measured `SH_REL_HOME_TO=<gx>,<gy>` to
`streamhost/stations/<id>/station.env.fixture`. Only add `SH_REL_PACED`/
`SH_REL_MAX_STEP`/`SH_REL_STEP_PACE_MS` if the harness shows drift the re-home
alone does not fix.

| # | Station | Device / gain | Expected work | Status |
|---|---|---|---|---|
| 1 | **aux** | ADB m68k, gain 0.75, `SH_CURSOR_SCALE=1.3333` | golden re-bake, accel-off (below) | HOME_TO=899,649 applied; fast-move drift; re-bake pending |
| 2 | **rhapsody** | x86 PS/2, drains per-sync | measure HOME_TO + `HOME_ON=reset`; no device change | not started |
| 3 | **hpuxvue** | X11, `xset m 1 1` already baked | measure HOME_TO + `HOME_ON=reset` | not started |
| 4 | **beos** | PS/2 / pointer-lock fallback | **re-bake golden accel-off first** (still not persisted), then measure | not started |
| 5 | **sunos414** | sun-serial-mouse | verify device drains per-sync; measure gain + HOME_TO | not started |
| 6 | **freedos / msdoswin1** | PS/2 DOS | measure HOME_TO + `HOME_ON=reset` | not started |
| 7 | **nt351** | Win32 PS/2 | operator's call: **try the bridge here** before building the warpd agent; measure + validate | not started |

Other relative stations named in the plan (`star`, `indyr4400`, `c64`,
`amstradcpc`) come after these by the same measure-and-validate loop; `qnx`
(pointer-lock only) is out of scope.

## aux golden re-bake (operator chose "accel OFF") — DO ON A CLONE

aux's golden is the **A/UX Finder desktop (Mac Toolbox, NOT X)** with an open
root CommandShell (`localhost.root #`). Single inject is linear (0.75); a rapid
5 ms-poll report stream trips the **Mac Toolbox Mouse control panel**
acceleration (macos753's "Very Slow" is immune; aux's is evidently not truly
linear). Fix:

1. `wt.sh new auxrebake`; clone `aux-golden.qcow2` under the sandbox; `loadvm
   golden` on the clone (same device set).
2. Via the **pointer** (X keyboard is broken but the Mouse control panel is
   pointer-only): Apple menu → Control Panels → Mouse → tracking to the
   **slowest** setting; close.
3. Run `cursor-track.mjs` against the clone — expect track/reload/drag < ~5 px.
4. If still accelerated at the slowest setting, A/UX has no true-linear Mouse:
   fall back to a **per-station ADB poll knob** (add `SH_ADB_POLL_MS` read in
   the fork's `adb_bus`, keep aux at 20 ms while the fleet stays at 5 ms).
5. `savevm golden` on the clone; swap in as `aux-golden.qcow2` (keep a `.bak`);
   reset; re-validate. Keep `SH_REL_HOME_ON=reset` + `SH_REL_HOME_TO=899,649`.

The open root shell means aux DOES take Toolbox keyboard even though X does not
— usable for scripted checks if the pointer nav is fiddly.

## Notes / gotchas carried from the canary

- Never hammer QMP `input-send-event`/`loadvm` on a **stopped** guest — it
  crashes QEMU (single-client `qmp.sock` contends with the idle-pauser).
  `query-status` first; the golden is saved `-S` (prelaunch) so a fresh restore
  needs the `cont` that `reset-tile.sh` now sends.
- The SPA type-7 focus hint bundle is **built but not deployed** (a darklaunch
  overlay was armed when it was ready — [[spa-deploy-clobbers-darklaunch-overlays]]).
  Deploy + re-arm the overlay when clear; not required for `HOME_ON=reset`.
- `GALLERY_URL` / real lab origin must never land in a committed file — the repo
  address is the `192.0.2.10` placeholder.
- Full canary history + telemetry findings live in memory
  `rel-bridge-rehome-paced.md` (updates 1–6).

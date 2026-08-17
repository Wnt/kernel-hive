# QNX Neutrino 6.5.0 — gallery station notes (:8112)

**Guest:** QNX Neutrino RTOS **6.5.0** self-hosting **LiveCD** → **Photon microGUI** desktop.
**Build script:** `scripts/build-guests/tiles/qnx.sh` (fetches ISO + drives to desktop + framebuffer-proves it).
**Image (labhost):** `/data/gallery-guests/QNX/QNX650Live.iso` (in CT 110 as `/guests/QNX/QNX650Live.iso`).
**Proof:** `/data/gallery-guests/QNX/qnx-photon-desktop.png` (blue Photon desktop) + `qnx-photon-login.png`.
**Live-station proof (2026-07-04):** `/opt/osgallery/gallery-guests/QNX/qnx-photon-desktop-live.jpg` — the blue Photon
desktop captured **from the running :8112 neko station** via the neko admin screenshot API.

> **Historical (neko-era) wiring below.** QNX runs today as the streamhost station
> **`qnx`** — see its stanza in `streamhost/stations-manifest.sh` (`streamhost@qnx`;
> the HMP monitor channel survives as `-monitor tcp:127.0.0.1:7112` in the station's
> `--extra`). The neko compose/:8112 wiring and the `gallery-integrate-all.sh`
> manifest row below are neko-era; that integrator was deleted in the 2026-07
> restructure — git history. Build script, licensing, the keyboard boot-driver
> sequence and guest quirks still apply.

## License
QNX Neutrino 6.5.0 self-hosting LiveCD = QNX's **freely-distributable evaluation / DEMO** image
(non-commercial eval, widely mirrored; sourced from **archive.org** item `qnx-650-live`). **Not** open
source. It is a **demo / freely-distributable** image, free to use in this private home-lab collection
(same stance as the OS/2, NeXTSTEP, Win9x/XP stations) — the only rule is not re-distributing the binary
media via the GitHub repo.

## Curated metadata (for the UI placard)
- **Year:** 2010 (6.5.0); Photon/QNX lineage late-1990s → 2010.
- **Lineage:** QNX Software Systems (Quantum → QSSL → BlackBerry). POSIX hard-real-time **microkernel**
  (Neutrino) + **Photon microGUI** window system. Famous for the 1.44 MB "QNX Demo Disk" (Photon +
  Voyager browser on one floppy). Ships **Voyager** browser, **pterm**, media players, games.
- **One line:** *"A hard-real-time microkernel OS whose Photon microGUI once fit a web browser and a
  desktop onto a single floppy."*
- **Iconic era software:** Photon desktop, Voyager web browser, `pterm`, pheditor, the blue-nautilus
  wallpaper.
- **archetypeHint:** **beige-tower-crt** (late-90s/2000s embedded/industrial PC). A QNX-flavoured
  variant — an industrial/automotive panel-PC or a beige mini-tower with a CRT — would be ideal.

## LIVE STATION STATUS (2026-07-04) — ✅ LIVE at :8112, Photon DESKTOP CONFIRMED, wired into :8080
- **The live neko station at :8112 is UP (healthy) and renders the QNX Photon microGUI DESKTOP.**
  Verified via the neko admin screenshot API (POST `/api/login` admin/admin → GET
  `/api/room/screen/shot.jpg`): blue nautilus wallpaper + **Launch** bar + app shelf
  (Internet/Utilities/Games/Configure) + **System Monitor** + QNX clock. Proof:
  `/opt/osgallery/gallery-guests/QNX/qnx-photon-desktop-live.jpg`. `http://192.0.2.12:8112/` → 200.
  Station is **wired into the :8080 index**.
- **KEY FINDING — QNX ignores SYNTHETIC MOUSE-BUTTON injection entirely.** Empirically, QNX 6.5's
  pointer accepts *motion* but **not synthetic button presses**, via **every** tested path: monitor
  `mouse_button`, VNC/RFB `PointerEvent` (both single- **and** dual-console), and `xdotool` XTest into
  the neko GTK X display `:99` — including window-focused / press-hold clicks. So the phgrafx **Exit**
  button and the login **GO** button **cannot be clicked** synthetically. (End-user clicks via a real
  browser through neko/GTK likely hit the same wall — treat pointer *clicking* on this station as
  unreliable; keyboard works.)
- **WHAT ACTUALLY LANDS IT — keyboard via the QEMU monitor (`-monitor tcp:0.0.0.0:7112`), which QNX
  honours at every stage.** Reproducible landing sequence (all `sendkey` over monitor :7112, no clicks):
  1. Boot to the **stable `Select?` menu** (~35 s), then `sendkey f2` (Run from CD). Waiting for the
     final stable menu (not the earlier boot-scan prompt) avoids the racy double-720x400 problem.
  2. `device_add usb-tablet,id=tab0` (gives absolute pointer + a rendered cursor; harmless even though
     buttons still don't inject).
  3. Dismiss the phgrafx *Display Setup* wizard with its **keyboard mnemonic**: the Exit button shows an
     underlined **x** → `sendkey alt-x`. Wizard closes → QNX Neutrino Photon **login** screen.
  4. Login field has focus on load: `sendkey r o o t`, then `sendkey ret` (advance to Password),
     `sendkey ret` again (empty password submit) → **Photon desktop**.
- **Config change made for the live station:** the station now runs **single display console — `-display gtk`
  only (the `-vnc :12` secondary was REMOVED)**. The dual GTK+VNC console setup split the absolute-tablet
  input and was pointless once we learned buttons don't inject on any path; single-console matches every
  other gallery station. The **HMP monitor `-monitor tcp:0.0.0.0:7112` is kept** — it is the whole driving
  mechanism (keyboard + `device_add`). No VNC port is published anymore.
- **Not hands-off across container restarts:** neko keeps the QEMU alive between browser sessions, so the
  desktop persists once landed; but a container restart returns to the boot menu and the 4-step monitor
  sequence above must be re-run.
- **Recommended follow-up for a truly self-landing station:** **install QNX 6.5 to a small qcow2** (F3
  installer) with **Photon autologin + a saved graphics mode** → boots straight from HDD to the desktop
  (no menu, wizard, login, or driver) as a plain `GUEST_DISK=` station. Sidesteps the boot-menu + wizard +
  login entirely and needs no monitor keystrokes.

## THE CATCH — the LiveCD does NOT self-land on the desktop
Reaching the Photon desktop in QEMU needs a precise driven sequence (all encoded in `qnx.sh`), and the
station therefore needs a **boot-driver** (a one-shot input sequence run against the station's QEMU right
after `compose up`). The non-obvious findings:

1. **Boot menu:** the CD stops at a **`Select?`** menu → press **F2** = *Run from CD* (live; writes
   nothing to disk). F3 = install-to-disk. **F2 must be sent exactly once, after the menu is STABLE** —
   the boot-scan phase before it is the same 720x400 text mode and eats an early keypress (or navigates
   a sub-menu). `qnx.sh` detects the menu by frame **stability** (two identical 720x400 frames).
2. **VGA = `cirrus`, not `std`.** Under `-vga std` the QEMU hardware-cursor position **diverges** from
   Photon's logical pointer, so clicks miss every widget. Cirrus fixes it.
3. **Pointer:** QNX 6.5's **PS/2 mouse reports motion but not synthetic button presses**, and a
   **cold-plugged USB tablet enumerates only intermittently**. Reliable fix: boot with a bare **UHCI**
   controller (`-usb`, no device) and **hot-add** the tablet **after** Photon is up
   (`device_add usb-tablet`) — a clean attach event QNX enumerates every time → absolute motion +
   working clicks. **xHCI/USB3 is unsupported by 6.5 — must be UHCI.**
4. **phgrafx wizard:** first Photon start shows a *"phgrafx: Display Setup"* dialog → click **Exit**
   (≈ 487,361 in 640x480) → QNX Neutrino **login** screen.
5. **Login:** user **`root`**, **EMPTY** password → the **Photon desktop**.

Verified end-to-end on the dry-run labhost (QEMU 11.0.0 + KVM): reaches the blue Photon desktop (Launch bar,
Internet/Utilities/Games/Configure shelf, System Monitor, QNX clock).

## Ports (assigned — CONFIRMED live 2026-07-04)
- neko web station: **:8112** (→ 8080 in-container). Live, healthy, HTTP 200.
- neko UDP EPR: **53500-53519** — FIXED, confirmed free against all live compose files (siblings occupy
  52000-52059, 53000-53419 gallery-guests/haiku/reactos/msdoswin1, 53900-53919 os2warp; 53420-53499 and
  53500-53519 are unused → 53500-53519 taken, no collision).
- QEMU HMP monitor: **:7112** (kept — drives the keyboard landing sequence). **No VNC port** (removed).

## Proven raw QEMU profile (reached the desktop)
```
qemu-system-x86_64 -machine pc -enable-kvm -cpu host -m 512 \
  -cdrom QNX650Live.iso -boot d \
  -vga cirrus -rtc base=localtime -usb \
  -netdev user,id=n0 -device e1000,netdev=n0 \
  -audiodev pa,id=snd -device ac97,audiodev=snd
# then: sendkey f2 (at stable menu) → wait Photon → device_add usb-tablet →
#       click Exit → login root/<empty>
```

## Standalone compose service (isolated project — mirrors templeos/sailfish pattern) — LIVE CONFIG
Written as its **own** project (`osgallery-qnx`) so it never touches the concurrently-edited
`docker-compose.gallery-guests.yml`. File: `/opt/osgallery/docker-compose.qnx.yml` in CT 110.
Brought up with: `docker compose -p osgallery-qnx -f docker-compose.qnx.yml up -d`.
`QEMU_EXTRA` adds the UHCI controller **plus a TCP HMP monitor** on :7112, which is how the guest is
driven to the desktop **by keyboard** (`sendkey` + `device_add`) after `up`. **Single display console
(`-display gtk` only)** — the earlier `-vnc :12` secondary console was removed (it split the tablet
input and, since QNX ignores synthetic button injection on every path, bought nothing).

```yaml
# Standalone QNX Neutrino 6.5.0 station (:8112) — isolated compose project (osgallery-qnx).
# The LiveCD does NOT self-land; after `up`, drive it to the Photon desktop via the HMP monitor :7112
# with the KEYBOARD sequence (F2 -> device_add usb-tablet -> alt-x to Exit wizard -> root/<empty> login).
# QNX ignores synthetic mouse BUTTONS on every path, so landing is keyboard-only.
services:
  qnx:
    image: neko-qemu:latest
    restart: unless-stopped
    shm_size: 1gb
    ports:
      - "8112:8080"
      - "53500-53519:53500-53519/udp"
      - "7112:7112"                # QEMU HMP monitor (driver: sendkey F2 / device_add / login keys)
    volumes: ["./gallery-guests:/guests:ro"]
    devices: ["/dev/kvm:/dev/kvm"]
    environment:
      NEKO_SCREEN: "1280x720@30"
      NEKO_PASSWORD: "neko"
      NEKO_PASSWORD_ADMIN: "admin"
      NEKO_EPR: "53500-53519"
      NEKO_ICELITE: "true"
      NEKO_NAT1TO1: "192.0.2.12"
      NEKO_SESSION_IMPLICIT_HOSTING: "true"
      OS_NAME: "QNX Neutrino 6.5"
      QEMU_MEM: "512"
      QEMU_SMP: "1"
      QEMU_MACHINE: "pc"
      QEMU_VGA: "cirrus"
      GUEST_CDROM: "/guests/QNX/QNX650Live.iso"
      GUEST_BOOT: "d"
      QEMU_SOUND: "-device AC97,audiodev=snd"
      # UHCI controller (tablet hot-added post-boot) + TCP HMP monitor (the keyboard-driving channel).
      QEMU_EXTRA: "-enable-kvm -cpu host -usb -monitor tcp:0.0.0.0:7112,server,nowait"
```

Manifest row for `gallery-integrate-all.sh` (historical — the reconciliation never ran; neko-era, deleted;
type|key|label|mem|smp|machine|vga|sound|guestenv|extra|tier):
```
qemu|qnx|QNX Neutrino 6.5|512|1|pc|cirrus|-device AC97,audiodev=snd|GUEST_CDROM=/guests/QNX/QNX650Live.iso GUEST_BOOT=d|-enable-kvm -cpu host -usb -monitor tcp:0.0.0.0:7112,server,nowait|advanced
```
Tier = **advanced**: needs the keyboard boot-driver post-`up` (does not self-land like a plain live-CD station).

## Boot-driver — KEYBOARD-ONLY via HMP monitor :7112 (no VNC, no clicks)
The live station was landed with a monitor-only keyboard sequence (QNX ignores synthetic mouse buttons on
every path — see LIVE STATION STATUS). Run once after `up`, and again after any container restart:
  1. wait ~35 s for the **stable `Select?` menu** → `sendkey f2`  (Run from CD)
  2. wait ~30 s for Photon (phgrafx wizard, 640x480) → `device_add usb-tablet,id=tab0`
  3. `sendkey alt-x`  (Exit mnemonic — the underlined **x**) → dismisses the phgrafx wizard → login screen
  4. `sendkey r` `o` `o` `t`, then `sendkey ret`, `sendkey ret`  (root / empty password) → **Photon desktop**
Verify with the neko admin screenshot API (POST `/api/login` admin/admin → GET `/api/room/screen/shot.jpg`).
NOTE: `scripts/qnx-tile-driver.sh` (VNC-click based) never worked on QNX — its clicks never register;
the keyboard sequence above is the working method. (Driver script was never used and is neko-era,
deleted — git history.)

## Caveats for the orchestrator / UI
- **Not hands-off across restarts.** neko restarting the container returns to the boot menu; the driver
  must be re-run (or wrapped in a small watch-loop on CT 110). A **cleaner long-term station** would be an
  **install-to-disk** QNX qcow2 with autologin (boots straight to the desktop via the standard
  launcher, no driver) — recommended follow-up; not done here to stay within a live-CD footprint.
- **End-user input:** neko injects PS/2 via the QEMU GTK window. The hot-added usb-tablet gives the
  driver reliable absolute clicks; end-user pointer quality via neko/GTK should be re-checked per the
  gallery perf pass.

## 1024x768 resolution + pointer findings (2026-07-08, workflow wxxwmkzuw)

**Resolution — FIXED, captured into live checkpoint (1024x768).** The launcher uses `--vga std`
(Bochs VGA). On a cold boot std VGA does NOT auto-match, so QNX presents the interactive
`phgrafx: Display Setup` dialog offering 640/800/1024x768/1152 @ 32K colour. Verified capture
sequence (fresh phgrafx, no text-caret state):
- `Tab Tab Tab` → Resolution combobox
- `Down Down` → cycles 640→800→**1024x768** (verify the field shows it)
- `Tab ×5` → Apply (Refresh is greyed so it's 1 tab to Cursor + 4 to Apply)
- `Space` → Apply; screen switches to 1024x768 + a **"Restore.../Accept"** dialog (10s countdown)
- **MOUSE-CLICK "Accept"** (~373,154) within 10s — keyboard CANNOT reach Accept (Space/Enter/Tab all hit Restore). Miss it → reverts to 640x480 and the combo enters edit-mode; cold-reboot to retry.
- `Alt+X` exit phgrafx → login (root/root) → Photon desktop @1024x768 → clean screendump → `savevm golden`.
Solitaire (Launch→Games→Solitaire, Ctrl+N deals) is fully visible at 1024x768. `--vga std` also
makes the HW cursor visible in QMP screendumps (cirrus hid it). login = **root / root**.
CAVEAT: do NOT hand-write `/etc/system/config/display.conf` with a minimal block — wrong
driver/format hangs io-graphics at "Waiting for the window manager". Use phgrafx.

**Pointer — BLOCKED (re-investigated 2026-07-13 through the REAL streamhost browser path).**
The live station stays on the frozen baseline (`golden.qcow2.bak-preMouseFix`, tablet present).
The earlier "devi-accel" fix on this branch was **disproven** by a live browser-drag test; the
real root cause is different and 1:1 absolute tracking is a genuine dead-end. Full findings:

- **TRUE root cause of the frozen cursor: the `usb-tablet` puts QEMU in ABSOLUTE mode, and
  QEMU's dbus `Mouse.RelMotion` REFUSES to inject while a console is absolute** (returns "Mouse
  is not relative" — see QEMU `ui/dbus-console.c`). `info mice` on the live station shows
  `* QEMU HID Tablet (absolute)` as the active device. Because SH_POINTER=rel drives RelMotion,
  every move is a silent no-op → **frozen cursor**. Buttons/keys work because `Press`/`Release`/
  `SetAbsPosition` are NOT gated on abs-mode; HMP `mouse_move` works because it bypasses the dbus
  gate. (The prior "Photon speed-doubling accel" theory was wrong: with the tablet removed a
  single mid-screen `mouse_move 150` lands exactly 150 px — devi is already linear/1:1.)
- **Removing `-device usb-tablet` unblocks motion** (PS/2 becomes the active *relative* device,
  RelMotion injects). Verified live: after `device_del`, the browser-drag cursor MOVES and tracks
  the drag **direction** 1:1 for small/mid moves. This half is a real, clean fix.
- **But reliable 1:1 ABSOLUTE positioning is INFEASIBLE on QNX 6.5 via rel injection**, so the
  abs→rel homing bridge cannot land the cursor on target:
  * QEMU CLAMPS/DROPS large single rel deltas — a lone `RelMotion(-8192)` is a complete no-op,
    `-1024` moves only ~500 px. So the bridge's `-8192` corner-pin never established the origin,
    AND the first seed jump to the target (e.g. 465 px) was itself truncated (~a third short),
    fixing the whole session at a ~130 px offset.
  * Splitting into bounded (≤256 px) steps still fails: back-to-back deltas re-merge in QEMU's
    PS/2 accumulator and re-clamp; and near the screen edge the guest EATS motion (after a
    corner-pin + 2 s settle, a `+400` move produced only ~85 px). Pacing helped but landing
    became non-deterministic (same drag landed y=760 one run, y=475 the next). No pin size /
    pacing reliably homes the cursor.
- **Net:** motion can be un-frozen (tablet removal) but the cursor tracks with a variable
  absolute offset, not 1:1 — so the browser-drag success gate cannot pass. Live station rolled back
  to the clean frozen baseline rather than ship a half-tracking state.
- **usb-tablet ABSOLUTE = still a dead-end** (Photon ignores tablet abs; devi `abs`/`touch`
  clamps + needs a calib file + is contact-only/no-hover). And **in-guest agent = dead-end**
  (QNX 6.5 demo image ships no C compiler).
- **Only viable path to true (relative) 1:1 = pointer-lock direct-rel in the UI.** The small
  per-event rel deltas that pointer-lock (`movementX/Y`) produces ARE applied 1:1 and reliably by
  QNX — they never hit the large-delta clamp and need no corner-pin. The daemon already handles
  wire type=4 (`input.rs` case 4 → `RelMotion`, no homing); the UI has `sendMoveRel` but never
  calls it. Wiring `requestPointerLock` on the stream canvas + sending type=4 is the recommended
  next step (it's a capture-model UX change, not an absolute-position model).
- **Live-station input caveat:** the station runs `-display dbus,p2p=on`; the only input path that
  reaches the guest is the dbus peer (streamhost) — so QMP `input-send-event` on a `-display none`
  CLONE is NOT representative (it bypasses the abs-mode RelMotion gate that blocks the live path).
  This is why the earlier clone "proof" was misleading. Verify on the LIVE station via a browser drag.

## 2026-07-13 — clean rel-pointer fix (branch `feat/pointer-fix`)

The pointer-lock direct-rel path recommended above is now assembled cleanly and
clone-validated. Three pieces (all since promoted live — see the 2026-07-14
section below):

1. **Daemon** (`streamhost/streamhost/src/input.rs`): the bounded type=4
   rel-motion was extracted from `feat/streamhost-coldboot-latency@71998d9`
   WITHOUT that branch's dead scheduler (`SH_ENC_SCHED`) or inert `cold_boot`
   (`cap.conn()` Option-slot) — `rel_motion_bounded` calls the existing
   `rel_motion(cap.main_conn, …)` directly, so every non-rel path is byte-
   unchanged. `rel_chunks` splits a delta into ≤256 px/axis chunks paced ~16 ms
   that sum EXACTLY to the original (unit-tested; 5/5 input tests pass). Small
   deltas = one un-paced send == the old `rel_motion` (pointer-lock 1:1).
2. **UI** (`spa/src/three/archetypeRegistry.ts`): `pointerRel: true` restored
   for `qnx` and `freedos` (at the time NOT `msdoswin1` — another owner; since
   `25e27b3` all three stations carry `pointerRel`). The type=4 wiring
   already exists in `StreamView`/`useStreamControl`.
3. **QNX device set** — see runbook below.

### Clone validation (framebuffer proof, not live)

Clone `/data/vms/sandbox/qnx-pfix` = QNX launcher with `-usb -device usb-tablet`
REMOVED, cold-booted from the live CD (`-boot d`, no loadvm) to the 800×600
Photon desktop via `qnx-photon-drive.sh` (MON_PORT=7212), `-display dbus,p2p=on`.

- **Root cause, both sides captured via `query-mice`:** LIVE qnx shows
  `QEMU HID Tablet (current, absolute=true)` → `qemu_input_is_absolute()` true →
  dbus `Mouse.RelMotion` refuses ("Mouse is not relative") → frozen. The
  no-tablet CLONE shows only `QEMU PS/2 Mouse (current, absolute=false)` → the
  RelMotion precondition passes.
- **Cursor tracks 1:1:** small rel(-250,+140) moved the Photon arrow (405,307)→
  (152,447) (≈−253,+140). A ≤256-chunked rel(500,−300) landed (152,447)→
  (648,150) (≈+496,−297). A single UN-chunked rel(−450) mangled to ≈(−338,+103)
  — the exact PS/2 accumulator clamp `rel_motion_bounded` defeats.
- Injection used QMP `input-send-event rel`, which shares QEMU's input core
  (`qemu_input_queue_rel`) with dbus RelMotion; the dbus gate itself was proven
  open via `query-mice`. FINAL confirmation is still a live browser drag (the
  prior live `device_del` test already saw small/mid moves track 1:1).

### Promoting to the LIVE qnx station — go/no-go for a human

Removing `-device usb-tablet` is a **device-set change**, so it BREAKS
`loadvm golden` (device set must match the savevm). QNX's launcher already cold-
boots the live CD (`-boot d`, no `-loadvm` in the launcher), but `labctl reset`
and any captured `golden` checkpoint assume the tablet. Promotion therefore needs a
**full checkpoint recapture**, not a `savevm`:

1. Back up: `cp golden.qcow2 golden.qcow2.pre-reltablet` (existing `.pre-qnxfix`,
   `.bak-preMouseFix` already there). Back up `qemu-streamhost.sh`.
2. Edit the launcher: delete the `-usb -device usb-tablet` line (keep everything
   else; `-machine pc` already provides the PS/2 mouse). station.env keeps
   `SH_POINTER=rel`.
3. Cold-boot + drive to the Photon desktop (`qnx-photon-drive.sh`), then
   `savevm golden` over the NEW (no-tablet) device set so `labctl reset` matches.
4. `labctl gen` to refresh the matrix.
5. Deploy the `feat/pointer-fix` daemon binary + restart `streamhost@qnx`, ship
   the UI bundle, then VERIFY 1:1 with a real browser pointer-lock drag.

Risk: low and reversible — the change is confined to this station; the pre-change
checkpoint + launcher are backed up. The only behavioural change is pointer mode
(abs tablet → PS/2 rel), which is the intended fix. Cost: one interactive checkpoint
recapture. **Recommendation: GO**, gated on the human running step 5's live drag.

## 2026-07-14 — LIVE PROMOTION DONE (branch `integ/pointer-live`)

The bounded-rel daemon + QNX no-tablet checkpoint are now DEPLOYED to the live labhost.
Everything below was framebuffer-verified on the running stations (screendumps).

### Part A — bounded relative input (historical isolated rollout)

The initial 2026-07-14 rollout used a separate binary and three systemd
drop-ins while the change was canaried. That operational fork is now deleted
from source: `rel_motion_bounded` and its exact-sum chunking tests live in the
shared `streamhost/streamhost/src/input.rs`. On the next consolidated daemon
rollout, qnx/freedos/msdoswin1 all select `InputBackend::DbusRel` through their
legacy-compatible `SH_POINTER=rel` settings and run the shared binary.

- Built the `feat/pointer-fix` daemon in a temporary isolated labhost directory
  (clone of the fleet build dir with ONLY
  `src/input.rs` overlaid from `feat/pointer-fix`; `Cargo.toml`/`Cargo.lock`
  byte-identical to the fleet build → the non-rel path is provably unchanged).
  Seeded the target from the fleet target so bindgen/x264-sys stayed cached;
  built with `LIBCLANG_PATH=/data/llvm19/usr/lib/llvm-19/lib` +
  `BINDGEN_EXTRA_CLANG_ARGS=-I/data/llvm19/usr/lib/llvm-19/lib/clang/19/include`.
- The isolated binary's md5 was `b7a107c68d3befa5c7488aecbca618e2`;
  input tests 5/5 passed.
- **Shared fleet binary UNTOUCHED** (`/data/vms/streamhost/build/target/release/streamhost`
  still md5 `68e78d320c149dc87e7788ecd0ceda39`, == pre-change).
- Installed the temporary binary to an isolated path and used per-station systemd
  drop-ins for ONLY the 3 rel stations. `daemon-reload` + restarted those 3; each
  active + running the canary
  + serving (framebuffer confirmed: qnx=Photon desktop, freedos=retro-games
  menu, msdoswin1=MS-DOS Executive).
- That temporary install/drop-in path is retired; the orchestrated shared-binary
  rollout owns removal of any labhost-local historical drop-ins.

### Part B — QNX checkpoint recaptured WITHOUT usb-tablet (PS/2 relative)

- Validated on a namespaced clone (`/data/vms/sandbox/qnx-relbake`, now removed):
  tablet-free launcher cold-booted to the 800x600 Photon desktop via
  `qnx-photon-drive.sh` (MON_PORT=7212). `query-mice` = **only `QEMU PS/2 Mouse`,
  current, absolute=false** (the RelMotion precondition). rel(-250,+140) tracked
  1:1; a ≤256-chunked rel(500,-300) landed full; a lone unchunked rel mangled
  (the clamp the fix defeats). `savevm golden`; `loadvm golden` → desktop +
  rel(-200,-150) tracked 1:1.
- **Live swap** (backups timestamped `1783989096`):
  - `golden.qcow2.bak-preReltablet-1783989096`
  - `qemu-streamhost.sh.bak-preReltablet-1783989096`
  Swapped in the validated no-tablet checkpoint + a launcher with the
  `-usb -device usb-tablet` line removed (PS/2 relative via `-machine pc`
  default). Started QEMU, `loadvm golden`, restarted `streamhost@qnx`.
- **Live framebuffer gate PASSED:** `labctl shot qnx` → Photon desktop (no
  error); `query-mice` on live = only PS/2, absolute=false.
- **Live daemon-path proof (the real gate):** an aioquic WebTransport client
  (`/data/vms/streamhost/shm-lab/wtenv/bin/python`) connected to the live daemon
  (`udp/54112`, resuming the idle-paused guest) and sent **real type=4 rel
  datagrams** through the production path
  (transport.rs coalescer → `input::handle` case 4 → `rel_motion_bounded`).
  Cursor tracked **1:1**: origin (648,250) → after type=4 (-220,+150) →
  (428,400) = exactly Δ(-220,+150). Large flicks traverse fully (chunked, no
  truncation-collapse). `labctl reset qnx` (loadvm golden) verified — device set
  matches, desktop restored. `labctl gen` refreshed tiles.json (qnx pointer=rel,
  golden=true). Note: the recapture is **800x600** (keyboard-drivable Accept); the
  1024x768 path needs a mouse-click Accept, infeasible without the tablet.
- **Rollback (Part B):**
  `systemctl stop streamhost@qnx` → `kill $(cat /data/vms/streamhost/stations/qnx/qemu.pid)`
  → `cp golden.qcow2.bak-preReltablet-1783989096 golden.qcow2`
  → `cp qemu-streamhost.sh.bak-preReltablet-1783989096 qemu-streamhost.sh`
  → `bash qemu-streamhost.sh` → `loadvm golden` (QMP) → `systemctl start streamhost@qnx`
  → `labctl gen`.

### Remaining for the human
- **Deploy the UI bundle** carrying `pointerRel: true` for `qnx`/`freedos`
  (`spa/src/three/archetypeRegistry.ts`; `msdoswin1` was another owner's then —
  `25e27b3` flags all three) + the
  pointer-lock type=4 wiring — this repo does NOT touch the UI bundle.
- **Browser pointer-lock drag-test** through the deployed UI against the live
  `qnx` (and `freedos`) station to confirm end-user 1:1 pointer in a real browser
  (the daemon-side 1:1 is already proven above).
- freedos needed NO checkpoint change (already PS/2); it just got the Part A daemon
  override + the UI flag.

Both remaining items landed the same day: commit `25e27b3` shipped
`pointerRel: true` for qnx/freedos/msdoswin1 and the browser drag-test verified
1:1 live (2026-07-14).

## 2026-07-15 — Cirrus/1024 upgrade and absolute-pointer go/no-go

This section is the current production state and supersedes the older 640x480,
800x600, `-vga std`, and tablet recommendations retained above as investigation
history.

### Shipped state

- QEMU is pinned to `-machine pc-i440fx-11.0 -vga cirrus`, AC97, and the built-in
  PS/2 keyboard/mouse. There is no USB controller and no tablet in the saved
  snapshot or launcher. `SH_POINTER=rel` maps compatibly to the shared daemon's
  `InputBackend::DbusRel` bounded-relative path.
- Photon is saved at **1024x768, 64K colour, Driver `svga`** (`devg-svga`). On a
  fresh phgrafx screen, the reproducible keyboard sequence is `Tab` x3,
  `Down` x2, `Tab` x5, `Space`; wait two seconds; `Alt+A` accepts the timed mode
  test; wait 12 seconds; `Alt+X`; then login `root`, `Enter`, `Enter` for the
  empty password. The old claim that the 1024 mode required a pointer click was
  wrong: the Accept button has a working `Alt+A` mnemonic.
- `devg-svga` is the stable best-achievable driver on this LiveCD/QEMU pairing,
  but it is not accelerated. QNX's driver documentation explicitly says the
  SVGA driver has no acceleration. A clone using QEMU `ati-vga` (PCI
  `1002:5046`) exposed the LiveCD's `devg-ati_rage128.so`; forcing
  `drivername=ati_rage128` still ended with `Unable to start graphics driver(s)`.
  QNX's VMware driver is also documented as unaccelerated, so changing to it
  offers no performance-driver win. Do not describe this part as accelerated or
  measured faster; Cirrus fixes pointer/cursor alignment and 1024 provides more
  workspace, while repaint acceleration remains a no-go.

### Absolute-pointer result: NO-GO

A bare PIIX3 UHCI controller plus a Photon-time QMP
`device_add usb-tablet,id=tab0` enumerated reliably. QEMU reported the tablet
active and absolute, and tablet button events arrived. The production QEMU D-Bus
Mouse interface was then exercised with pixel coordinates, not the QMP HID
0..32767 coordinate range. Clicks at `(940,72)` and `(940,696)` both activated
the bottom-right clock/Localization widget: Photon ignores the tablet's absolute
Y coordinate. Therefore four-corner/centre alignment cannot pass and
`SH_POINTER=abs` is unsafe. The reliable shipped fallback is the already proven
PS/2 + `SH_POINTER=rel` + bounded direct-relative daemon. A hot-added tablet is
useful for diagnosis only and must not be saved into `golden`.

Snapshot migration also keys a hot-plugged tablet by USB topology. The diagnostic
snapshot restored only when the tablet was recreated on `bus=usb-bus.0,port=2`;
port 1 produced a migration-section mismatch. This is another reason not to ship
the tablet path.

### Clone validation, proofs, and rollback

- Stable clone: `/data/vms/sandbox/qnx-upgrade-20260715T223953Z-final/clone.qcow2`.
  It cold-booted, reached phgrafx after one correctly timed F2, saved `golden`,
  then restarted with the exact D-Bus production profile and `-loadvm golden`.
  Both frames were 1024x768; `query-mice` showed only `QEMU PS/2 Mouse`, current,
  `absolute=false`.
- First desktop proof:
  `/data/vms/sandbox/qnx-upgrade-20260715T223953Z-final/desktop.png`, SHA-256
  `8cc99c81b79185a6a71de9e0c741965b9d12cad29b33badf1de83c38c9c1743c`.
  Reload proof: `reload.png`, SHA-256
  `907db62abde589281ad594a40d1060be3709c4423e4eea34c75ee92ba53b7137`.
- Consistent pre-change rollback:
  `/data/vms/streamhost/backups/qnx-upgrade-20260715T223953Z/`. The backed-up
  `golden.qcow2` SHA-256 is
  `7bacd8ce4dec966e8a1fb76980c9715e0e4b12d15a388f7ddd86b349e5a73de1`;
  `SHA256SUMS` covers the launcher, env, manifest, registry/build inputs, and the
  640x480 baseline framebuffer.

Do not send F2 merely because the framebuffer is 720x400: the scan phase has the
same dimensions. Wait for the final `Select?` menu to become stable, then send F2
exactly once. An early F2 selected `Apply Driver Update` during this work; that
clone run was discarded by its pidfile and restarted.

### Live promotion and verification

- Promoted the stopped clone to `/data/vms/streamhost/stations/qnx/golden.qcow2`
  under a stopped `streamhost@qnx`; clone and live SHA-256 both
  `f9994f3e9542583c6164a44b928a0cab9809d8eff8e8cd40c4393d88e6ae31b0`.
  The deployed launcher SHA-256 is
  `837779438ea00ec23076d8185e13d2b129a1e44bf826b4c33dbffaa2ad9391e8`.
- Live framebuffer proof:
  `/data/vms/streamhost/backups/qnx-upgrade-20260715T223953Z/live-1024-cirrus.png`,
  1024x768, SHA-256
  `e292d4e1512a0c9894c2800faa3c980a1ee59512328c7b909a24545932cebc7f`.
  `labctl reset qnx` and a full `systemctl restart streamhost@qnx` each returned
  the same byte-identical frame (`live-after-reset.png` and
  `live-after-restart.png`).
- The live command line pins `pc-i440fx-11.0` and Cirrus and has no USB devices;
  QMP reports only the current, non-absolute PS/2 mouse. The service is active on
  UDP 54112, and its log records `first frame 1024x768`, the 1024x768 encoder,
  audio initialization, and `LISTENING udp/54112`.
- Direct relative QMP motion visibly moved the cursor across the 1024x768 live
  framebuffer, confirming the PS/2 path survived the graphics change. As already
  known for this guest, a synthetic PS/2 left click did not open the Launch menu;
  absolute tablet buttons arrive but cannot be shipped because the tablet Y axis
  is wrong. Pointer buttons therefore remain a QNX 6.5 limitation in the safe
  relative fallback—not a claimed pass.
- `labctl gen` is currently blocked before generation by the unrelated existing
  `amigaos.pointer_mode` declared/live mismatch (`abs` versus `rel`). QNX itself
  reset and restarted successfully; no Amiga/shared configuration was changed.

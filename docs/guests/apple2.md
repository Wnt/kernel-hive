# Apple //e + Apple GEOS deskTop — gallery tile notes (:8117)

**Guest:** a captured **Debian 12 x86_64 kiosk** running **LinApple 2.3.0 `linapple`**
in a window, emulating an **Apple //e (enhanced)** that auto-boots the **Apple GEOS
deskTop** off a ProDOS hard-disk image. This is an **"emulator bridge"** tile (see
**`streamhost/docs/BRIDGE.md`**, reference impl `c64`) — streamhost captures the Linux
framebuffer + AC97 audio (the Apple II 1-bit **speaker** routed through ALSA).

**Emulator used: LinApple (NOT MAME).** The base's LinApple build had failed; it is
FIXED in the overlay (see below). MAME `apple2e` remains the documented fallback but
was not needed — LinApple reaches the GEOS deskTop reliably and bundles the //e ROM
(no external ROM set required).

**Shared base:** `/data/vms/bridge/bridge-base.qcow2` (read-only backing; built by
`scripts/build-guests/bridge-base.sh`). Contains the bare-X kiosk + LinApple *source*
at `/usr/local/src/linapple` (its build had failed in the base).
**Build script (tile):** `scripts/build-guests/apple2.sh` (thin overlay + LinApple
build fix + GEOS media + kiosk `launch.sh` + golden bake + verify).
**Tile dir (host):** `/data/vms/streamhost/tiles/apple2/` — `overlay.qcow2` (thin, on
the base; holds the INTERNAL `golden` snapshot), `qemu-streamhost.sh`, `tile.env`.
**Proof:** `/data/vms/streamhost/tiles/apple2/proof/geos-desktop.png` (the GEOS
deskTop in monochrome white, BIGWON window open; refreshed 2026-07-12 v2 — earlier
proofs kept as `geos-desktop-color-pre-2026-07-12.png` / `geos-desktop-green-2026-07-12.png`),
`geos-loadvm-golden-restore.png` (cold `-loadvm golden`
lands on the same deskTop), `apple2-speaker-beep.wav` (the measured non-silent beep).

## UPDATE 2026-07-12 v2 — GEOS mouse ACTUALLY works now + mono white (browser-verified, golden re-baked)
Supersedes the earlier 2026-07-12 green-palette bake. The user-visible symptoms —
"the GEOS cursor never tracks, the host cursor disappears after one click, and the
mono display looks broken/smeared in the browser" — came from FOUR stacked defects,
all fixed and re-verified END-TO-END through the actual browser stream (Playwright
driving the SPA at https://192.0.2.10:8443, decoding the `<video>` frames):
1. **`Clock Enable = 4` (stock linapple.conf default) clobbered the mouse card.**
   `Clock_Insert()` runs AFTER `MemInitialize()` and copies a ProDOS clock-card ROM
   + IO handler over slot 4 — on top of the AppleMouse card. GEOS's driver scans
   `$Cn0C=$20 / $CnFB=$D6 / $Cn11=$00`, found clock bytes instead, and booted with
   **no mouse driver at all** ("Input driver error: No mouse card found" — the
   "benign dialog" of the original bake was actually the smoking gun; the "GEOS
   arrow follows the tablet" claim was a misread of the X cursor). Clock moved to
   free slot 5; with the mouse card visible GEOS also finds its **VBL interrupt
   source**, so BOTH boot dialogs are gone — cold boot lands straight on the deskTop.
2. **LinApple gated all mouse input behind SDL click-capture** (`SetUsingCursor`/
   `SDL_WM_GrabInput`): first click eaten, then grab+hidden-cursor = SDL1.2
   warp-based relative mode, broken with the absolute usb-tablet. Patched
   (`scripts/build-guests/assets/apple2/linapple-kiosk.patch`, Frame.cpp): mouse-card motion/buttons
   feed directly, no grab, host X cursor hidden over the window (GEOS draws the
   only visible arrow).
3. **LinApple's MOUSE_POS scaling bug + GEOS's delta-based driver.** GEOS re-homes
   the card to (16384,16384) every poll and consumes `READ - centre` as a movement
   delta in Apple-screen pixels; stock LinApple mis-scaled the re-home (16384 →
   533122, outside the clamps) and fed absolute window positions. Patched
   (MouseInterface.cpp): clamp-space writes clamp instead of scale, and host
   motion feeds exact correction deltas against a mirrored arrow-position estimate
   with a pin-to-corner sync handshake on driver init → true absolute 1:1 tracking
   (browser-verified: GEOS arrow lands under the SPA pointer; click/drag/menu work).
4. **Scanline blanking + green chroma murdered the stream.** LinApple blanks every
   other line for all video modes ≥ TV-emu (incl. monochrome) → moire striping
   through the 1.8x scale + H.264; and mono GREEN puts the signal in the chroma
   planes, which 4:2:0 halves. Patched (Video.cpp: solid lines) + `Video
   Emulation = 7` (Monochrome WHITE = pure luma; also the period-authentic choice
   for GEOS's 1-bit B/W desktop). Browser frames are now crisp with no fringing,
   no striping, no chroma smear.

## LIVE TILE STATUS (2026-07-08) — LIVE at udp/54117, GEOS deskTop CONFIRMED, speaker non-silent
- **streamhost@apple2 is active** and serving udp/54117. The daemon attached to the
  QMP socket, captured the framebuffer ("first frame 1024x768"), registered the
  **dbus AudioOutListener (Opus @96k)**, and spawned its **ffmpeg/libx264** child.
- **Framebuffer CONFIRMED (real screendump, not inference):** the Apple GEOS deskTop
  renders — menu bar (`geos apple file folder view disk options`), the open **BIGWON**
  disk window ("18 files, 125.5 K bytes used, 3451 K bytes free") with icons
  **GEOS KERNAL, GEOS SYSTEM, SYSTEM, GEODIALSYST, PRODOS, DEMOS, GEOWRITE, GEOPAINT**,
  the right-hand disk icons (BIGWON / DRIVE B / DRIVE C), the Panasonic printer, the
  wastebasket, and the GEOS arrow pointer (which tracks the abs usb-tablet).
- **Speaker audio CONFIRMED non-silent:** LinApple holds the ALSA `default` device
  (`aplay` returns EBUSY -> audio init succeeded). A verify run captured a cold Apple
  //e **power-on beep** to a wav via QEMU `wavcapture snd0`:
  **PEAK=8191** (pure silence = 0; 8191 is the 1-bit speaker's fixed amplitude),
  loudest-1s-window **RMS≈3409** on a 44.1 kHz / 16-bit / 9.7 s capture. The live path
  is **Apple II speaker → ALSA default (hw:0,0) → AC97 → QEMU dbus audiodev →
  streamhost Opus**. NB: the *idle GEOS deskTop is silent* — Apple GEOS does not toggle
  the speaker at the deskTop; sound is proven via the boot beep / any sound-using app.
- **Golden fixture:** boots straight to the GEOS deskTop via `-loadvm golden` (INTERNAL
  snapshot in `overlay.qcow2`, VM_SIZE **876 MiB**). Verified: a cold `-loadvm golden`
  restart lands on the identical clean deskTop in ~4 s (no //e boot, no ProDOS load, no
  keypresses, and neither boot dialog).

## License / provenance
- **LinApple** (source, GPLv2) is an AppleWin fork; it **bundles the Apple //e ROM**
  (compiled into `inc/resource.h`) redistributed for emulation use.
- **Apple GEOS** — **freeware** (Breadbox Software released the Apple II GEOS in 2003).
  HDD image `GEOS-mouse supported by APPLEWIN.hdv` (ProDOS, Volume `/BIGWON`) from the
  Asimov Apple II archive mirror (`.../other_os/gui/geos/`). Copyrighted media here is
  free to use in this private home-lab collection (same stance as the C64 GEOS, OS/2,
  Win9x tiles); we just don't re-distribute the binary media files via the GitHub repo.
  Baked into the overlay as
  `/opt/bridge/media/geos.hdv`.

## Curated metadata (for the SPA placard)
- **Year:** Apple //e = **1983** (enhanced //e = 1985); **Apple GEOS** = **1988**
  (Berkeley Softworks, ported from the Commodore 64 original).
- **Lineage:** the Apple II line (MOS 6502 / 65C02) was the machine that made the
  personal computer mainstream; **GEOS** bolted a Mac-like WIMP desktop —
  pull-down menus, icons, a mouse pointer, geoWrite/geoPaint — onto a 1 MHz, 128 KB //e.
- **One line:** *"A windows-icons-menus desktop (GEOS) with geoWrite & geoPaint running
  on a 1 MHz Apple //e — the 8-bit era's Macintosh, on Apple hardware."*
- **Iconic era software:** the GEOS deskTop, geoWrite, geoPaint, ProDOS.
- **archetypeHint:** **platinum-apple2e** — the beige Apple //e with a green/amber
  monochrome or RGB monitor, DuoDisk drives and an AppleMouse; an early-80s desk setup.

## THE HARD-WON RECIPE (all non-obvious, all baked into apple2.sh)

### Fixing the base's failed LinApple build (in the overlay)
1. **ImageMagick `convert`** — LinApple's Makefile converts `res/*.png` splash/font
   assets to XPM at build time. (`convert` is present in the current base; the dep is
   kept in the list for a clean rebuild.)
2. **The "Video.o g++ error" was a MISSING SDL1.2 dev header, not a code bug.**
   LinApple 2.3.0 is an **SDL1.2** app (`#include <SDL_image.h>`); the base only carries
   **SDL2** (for VICE). Install **`libsdl1.2-dev` + `libsdl-image1.2-dev`** → Video.o
   compiles. Then `Disk.cpp` needs **`libzip-dev`** (`#include <zip.h>`). With those
   three (`+ libcurl4-openssl-dev zlib1g-dev`) the build completes and `make install`
   drops `/usr/local/bin/linapple` + `/usr/local/share/linapple/Master.dsk` +
   `/usr/local/etc/linapple/linapple.conf`. No patch to LinApple source was needed.
3. LinApple **bundles the //e ROM** and a valid **AppleMouse firmware** (Pascal
   signature `$Cn05=38,$Cn07=18,$Cn0B=01,$Cn0C=20` plus `$CnFB=D6` and `$Cn11=00`,
   which is exactly what GEOS's input driver scans for). No `apple2e.zip` /
   external ROM needed. **BUT** three stock-LinApple bugs and one conf default
   (`Clock Enable = 4`) broke GEOS mouse + the mono display until 2026-07-12 v2 —
   see the UPDATE section and `scripts/build-guests/assets/apple2/linapple-kiosk.patch`
   (applied by apple2.sh before the build).

### LinApple config (`/opt/bridge/media/linapple.conf`, loaded as `./linapple.conf`)
Started from the installed default, changed only:
```
Computer Emulation = 3      # enhanced //e (65C02) — Apple GEOS requires it
Harddisk Enable    = 1
Harddisk Image 1   = /opt/bridge/media/geos.hdv   # slot 7, ProDOS -> GEOS
Boot at Startup    = 1
Mouse in slot 4    = 1       # GEOS is mouse-driven (AppleMouse in slot 4)
Soundcard Type     = 1       # Mockingboard OFF — it SHARES slot 4 with the mouse;
                             #   Apple II tones use the built-in SPEAKER regardless.
Sound Emulation    = 1
Fullscreen         = 0       # WINDOW (real SDL fullscreen renders BLACK in capture)
Screen factor      = 1.8     # ~1008x691 window centred on the 1024x768 bare-X root
Video Emulation    = 7       # Monochrome WHITE — GEOS is 1-bit DHGR; "Color Standard"
                             #   rainbow-fringes it and mono green smears through
                             #   H.264 4:2:0 (see the display section below)
Clock Enable       = 5       # template DEFAULT IS 4 = clobbers the mouse card ROM/IO
                             #   in slot 4 -> GEOS "No mouse card found" (root cause
                             #   of the dead GEOS arrow; fixed 2026-07-12 v2)
```
Config search order is `./linapple.conf` first, so the launcher `cd`s into
`/opt/bridge/media` before `exec linapple`. The `.hdv` + conf are `chown bridge` so
LinApple (run as the `bridge` kiosk user) can write to them.

### Kiosk / LinApple launch (apple2.sh → /etc/bridge/launch.sh)
```
export SDL_VIDEODRIVER=x11
export SDL_VIDEO_CENTERED=1
export SDL_AUDIODRIVER=alsa
cd /opt/bridge/media
exec linapple
```
- **Windowed, not real fullscreen** — same capture gotcha as the c64 tile: SDL real
  fullscreen mode-switch renders BLACK in the std-VGA framebuffer; a window captures.
- Kiosk = getty autologin `bridge` on tty1 → `startx` → `~/.xinitrc` (xset s off,
  1024×768) → `/etc/bridge/launch.sh`. If a bad launcher looped getty into
  `start-limit-hit`, clear it with `systemctl reset-failed getty@tty1` before restart.

### The two GEOS "boot dialogs" were NOT benign (gone since 2026-07-12 v2)
The original bake documented two cold-boot dialogs as benign and dismissed them
before baking. In truth both were symptoms of the slot-4 clobber
(`Clock Enable = 4`): with no reachable mouse card GEOS finds **no VBL interrupt
source** (dialog 1) and **no input driver** (dialog 2, "No mouse card found") — the
GEOS arrow was DEAD, permanently, on the baked tile. With the clock card moved to
slot 5, a cold boot goes **straight to the deskTop with no dialogs**. If either
dialog ever reappears, slot 4 is occupied again: fix that, never dismiss-and-bake.

### GEOS mouse: delta-based driver + the kiosk patch (2026-07-12 v2)
The APPLEWIN-patched GEOS input driver detects the card by scanning slot ROM for
`$Cn0C=$20`, `$CnFB=$D6`, `$Cn11=$00` (found at HDV offset 0x58a2), then polls at
~60 Hz: **READMOUSE → interpret (pos − 16384) as a movement delta in Apple-screen
pixels (560×192 space) → re-home the card to (16384,16384) via MOUSE_POS**. The
kiosk patch (`scripts/build-guests/assets/apple2/linapple-kiosk.patch`) makes LinApple work with that
under an absolute usb-tablet host pointer:
- `Frame.cpp` — feed mouse-card motion/buttons directly (no click-to-capture, no
  `SDL_WM_GrabInput`; grab+hidden cursor = SDL1.2 warp-relative mode, broken with
  absolute input). Host X cursor hidden over the window; GEOS's arrow is the only
  cursor the stream shows.
- `MouseInterface.cpp` — MOUSE_POS/HOME/INIT writes are clamp-space absolute
  (stock code re-scaled them: the 16384 re-home became 533122). Host motion feeds
  exact correction deltas against a mirrored estimate of the GEOS arrow position;
  a pin-to-corner handshake on driver init (pin → wait for GEOS to consume it →
  synced) gives **absolute 1:1 tracking**: the GEOS arrow sits under the SPA
  pointer, and click / double-click / drag land where the user points.
- `Video.cpp` — no scanline blanking (see display section).

### Monochrome WHITE, not green, not "Color Standard" (display fixed 2026-07-12 v2)
Apple GEOS draws its whole desktop in **monochrome 560×192 double-hi-res** (1-bit
pixels). Three separate display defects were fixed:
1. **"Color Standard" (1)** emulates an NTSC color monitor, so GEOS's B/W desktop
   grew magenta/green/orange artifact fringes on every glyph (original bake).
2. **LinApple blanks every other scanline** for all video types ≥ TV-emu including
   the monochrome modes (`CopySource` in Video.cpp) — after the 1.8× window scale
   and H.264 encode that turned into heavy moire striping across the whole screen.
   The kiosk patch renders solid lines.
3. **Mono GREEN (6) smears through the encoder**: a green-on-black image carries
   most of its signal in the chroma planes, which H.264 4:2:0 subsampling halves →
   muddy edges in the browser. **Mono WHITE (7) is pure luma** and survives 4:2:0
   crisply — and it is period-authentic: GEOS is a 1-bit B/W desktop (the
   "Macintosh look" was the whole point). Compared side-by-side in the actual
   browser stream (green vs white) before choosing. `5` (amber) has the same
   chroma problem as green; `0` allows a custom `Monochrome Color = #RRGGBB`.

### In-guest pointer-wedge watchdog (added 2026-07-12)
**Symptom:** after ~3.5 days of continuous kiosk runtime, Xorg stopped applying
tablet events — the kernel verifiably kept receiving `EV_ABS` on the tablet's
`/dev/input/eventN` while the X core pointer stayed frozen; a kiosk/Xorg restart
(or `loadvm golden`) clears it instantly. The injection chain (SPA → streamhost →
dbus `SetAbsPosition` → usb-tablet → guest) is proven correct and identical to the
working c64/atarist/amiga tiles. Top suspect for the X-internal mechanism is
**systemd-logind pausing the libinput fd without a resume** (unconfirmed — forensics
were destroyed by a golden restore; root-causing needs a multi-day clone soak).

**Self-heal instead of rabbit-hole:** `pointer-watchdog.service` runs
`/opt/bridge/pointer-watchdog.py` (root, python3 stdlib + `xdotool`), baked into the
golden. Every 10 s it drains the tablet's raw evdev stream (a second evdev reader
does not disturb Xorg's client) and samples the X pointer via `xdotool
getmouselocation` (DISPLAY/XAUTHORITY resolved from the running Xorg's own cmdline,
so it survives kiosk restarts and serverauth rotation). It declares a wedge ONLY
when, across **6 consecutive samples (60 s)**: the kernel saw ≥20 ABS events with
≥3 distinct values spanning ≥800 raw units on **both** axes (someone is genuinely
sweeping the pointer) while the X pointer position was **identical in every
sample**. A healthy X always breaks the condition; an idle tile produces no kernel
events and can never trigger. On detection it logs to
`/var/log/pointer-watchdog.log`, restarts the kiosk (`systemctl restart getty@tty1`
— the proven recovery), best-effort presses Return+space after ~50 s (a leftover
from when cold boots showed dialogs — since 2026-07-12 v2 none appear and the two
keys are no-ops on the deskTop), and enters a 15-min cooldown. If X is
down/restarting it clears its window and never judges.

### Framebuffer keyboard focus (bare X, no WM)
There is no window manager, so X keyboard focus is not assigned to the SDL window.
QMP `send-key` only lands after moving the **abs tablet over the window** first
(PointerRoot routing) — the driver does `cdrv.py abs 16384 16384` before each `key`.
Pointer motion always follows the tablet regardless of focus, so GEOS is mouse-usable.

## Ports (assigned — CONFIRMED live 2026-07-08)
- streamhost UDP (WebTransport): **54117**.
- ssh hostfwd (host→guest :22): **127.0.0.1:5817** (guest user `bridge`, key
  `/data/vms/bridge/bridge_key`).
- SPA web port (reserved for integration): **8117**. VMID **217**.

## Proven raw QEMU profile (the exact tile device set — MUST match golden bake)
```
qemu-system-x86_64 -name streamhost-apple2 -enable-kvm -m 1536 -smp 2 -cpu host -rtc base=localtime \
  -drive file=overlay.qcow2,if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5817-:22 -device e1000,netdev=n0 \
  -loadvm golden   # when the snapshot is present
  -qmp unix:qmp.sock,server=on,wait=off -pidfile qemu.pid
```
Golden bake/verify (HMP over QMP):
```
python3 /root/qmp_hmp.py qmp.sock 'savevm golden'
python3 /root/qmp_hmp.py qmp.sock 'loadvm golden'
python3 /root/qmp_hmp.py qmp.sock 'info snapshots'
```

## Deviations / caveats
- **Idle GEOS deskTop is silent** — Apple GEOS does not toggle the speaker at the
  deskTop (unlike C64 GEOS's clicks). Audio is proven via the //e power-on beep and is
  live for any sound-using GEOS app; the tile is not silent-by-fault.
- **Pointer:** `SH_POINTER=abs` via usb-tablet → guest X → SDL → LinApple mouse (slot 4)
  → GEOS AppleMouse. Absolute 1:1 tracking, **verified through the browser stream**
  (Playwright on the SPA: move / icon click / drag / menu open, 2026-07-12 v2).
- **Multi-day Xorg input wedge:** X can stop applying tablet events after days of
  continuous runtime (kernel still gets EV_ABS). Mitigated by the baked-in
  pointer-wedge watchdog (see recipe section); the X-internal root cause (logind
  fd-pause suspected) is an open follow-up requiring a multi-day clone soak.
- **Windowed, not edge-to-edge:** the GEOS window is ~1008×691 on a black 1024×768 root
  (real SDL fullscreen renders black in capture). Cosmetic; the deskTop is fully visible.
- **MAME fallback unused:** `mame apple2e` (apt candidate 0.251) + `apple2e.zip` remains
  the documented alternative, but LinApple reached the deskTop reliably so MAME (which
  needs the external Apple ROM set) was not required.

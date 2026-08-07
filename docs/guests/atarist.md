# Atari ST + EmuTOS GEM desktop — gallery tile notes (:8116)

**Guest:** a captured **Debian 12 x86_64 kiosk** running **Hatari** (WINDOWED),
emulating an **Atari ST** that boots **EmuTOS** straight to the **GEM desktop**.
An **"emulator bridge"** tile (see **`streamhost/docs/BRIDGE.md`**, ref impl = the c64
tile) — streamhost captures the Linux framebuffer + AC97 audio (the ST **YM2149**
routed through ALSA) exactly like every other tile.

**Shared base:** `/data/vms/bridge/bridge-base.qcow2` (read-only backing; built by
`scripts/build-guests/bridge-base.sh`). Contains VICE(x64sc)+**hatari**+cap32 + the
bare-X kiosk + `/opt/bridge/media/etos1024k.img`.
**Build script (tile):** `scripts/build-guests/atarist.sh` (thin overlay + kiosk
`launch.sh` + golden bake + audio verify).
**Tile dir (host):** `/data/vms/streamhost/tiles/atarist/` — `overlay.qcow2` (thin,
on the base; holds the INTERNAL `golden` snapshot), `qemu-streamhost.sh`, `tile.env`.
**Mounted application disk:** guest folder `/opt/bridge/media/atarist-apps`, exposed
by Hatari as writable GEMDOS drive **C:** (`--harddrive ... --gemdos-drive C
--protect-hd off`). Root `EMUDESK.INF` creates four GEM desktop launchers and F1-F4
shortcuts.
**Proof:** clone `/data/vms/soltest/atarist-apps-codex-0715/apps-top.png` and
`pacman-launch-final.png`; live `/data/vms/streamhost/tiles/atarist/proof/` contains
`apps-desktop-final-cold-restart.png`, `pacman-final-golden.png`, and
`apps-desktop-final-loadvm.png`. All are real QMP framebuffer screendumps. Clone
desktop/app SHA-256 values are
`d565ba45570181e8a67ab423931eae6499585e8ec09d9843b7bf1e87be840caf` and
`df64a9b783c05fb36c4c8e07f0e61ee447e994942229a39b4a4252490659384b`;
the final live app framebuffer is
`ee9ae8e8d7bed716aa02c8c4575ec3036c8114802371502155bbbc8d62590dd9`.

## License
- **Hatari** (GPLv2) — emulator only; bundles no Atari ROMs.
- **EmuTOS** (`etos1024k.img`) — a **GPLv2 free-software** TOS replacement (the
  EmuTOS project). Freely redistributable; no Atari copyright material. Provenance
  recorded in `/opt/bridge/media/LICENSES`. (Using EmuTOS avoids the Atari TOS ROM
  redistribution question entirely — it is the clean, legal GEM desktop.)
- **AIM 3.1 (Another Image Manager)** — public-domain image-management/paint
  package, Floppyshop archive `ART-3488.zip`. SHA-256
  `a5b245ae886aaeedc7d98a0d7ae774c75c214faa567f5b3f88321c89a210e147`.
  Package description: <https://www.atariuptodate.de/en/3859/aim>; archive:
  <https://www.exxosforum.co.uk/atari/PDL/FLOPPYSHOP/dl.php?file=ART-3488.zip>
  (the builder first obtains the Floppyshop download cookie).
- **Ballerburg (original Atari ST edition)** — explicitly released as **public
  domain** by author Eckhard Kruse: <https://www.eckhardkruse.net/atari_st/baller.html>.
  Binary archive <https://www.eckhardkruse.net/atari_st/download/baller.zip>, SHA-256
  `8bcb4214cc6a30c02413f73923cabcf65437b9294f6148f3018f01bac9115d45`;
  source archive <https://www.eckhardkruse.net/atari_st/download/baller_sources.zip>,
  SHA-256 `63fb6c5aa14f4f912e4d5cff61f42fa35951932d0635b185e14da434212ed593`.
- **Pacman for GEM 0.2.5** — freeware; its included readme permits the unmodified
  archive to be distributed anywhere. Page:
  <https://www.atarimania.com/game-atari-st-pacman-for-gem_31902.html>; archive:
  <https://www.atarimania.com/pgedump.awp?id=31902>, SHA-256
  `6f33a9e7371f9fb6bd635dd6d67250e1c5adc6c0b44b609e726e0fed84f5fe3e`.
- **GEMBench 4.03** — unregistered redistributable **shareware** GEM benchmark,
  preserved in the Floppyshop PD-library archive `UTL-3762.zip`:
  <https://www.exxosforum.co.uk/atari/PDL/FLOPPYSHOP/dl.php?file=UTL-3762.zip>,
  SHA-256 `74bce9ec2c7ec4d0da144887e0a5848bde3feff165e4cdabde52c3a395824567`.

The five downloaded ZIP files are retained byte-for-byte under
`C:\ORIGINAL\`; the SHA-256 values above are verified both before extraction and
after assembly. NEOchrome and DEGAS were deliberately not bundled: the readily
available releases lack a sufficiently clear redistributable PD/freeware grant.

## Curated metadata (for the SPA placard)
- **Year:** Atari ST (520ST) = **1985**; TOS/GEM desktop = 1985. EmuTOS = 2001+
  (an open reimplementation of the ST's TOS + GEM).
- **Lineage:** the Atari ST ("Jackintosh") — Motorola **68000**, **GEM** WIMP
  desktop (Digital Research), the **YM2149** PSG, built-in MIDI. Rival to the
  Amiga and the Mac; a staple of 1980s music studios and bedroom coding.
- **One line:** *"The 16-bit 'Jackintosh' — a 68000 with the GEM windows-icons-
  menus desktop and built-in MIDI, shown here on the open-source EmuTOS."*
- **Iconic era software:** the GEM desktop (DISK A/B, TRASH), NEODESK, Cubase/
  Notator (MIDI), Degas Elite, First Word.
- **archetypeHint:** **wedge-beige** — the low beige ST wedge with the chunky
  keyboard and a monochrome SM124 monitor; a mid-1980s 16-bit desktop.

## LIVE TILE STATUS (2026-07-16) — LIVE at udp/54116, four apps + UI CONFIRMED, YM2149 non-silent
- **streamhost@atarist is active** and serving udp/54116. The daemon attached to
  the QMP socket, captured the framebuffer (`first frame 1024x768`), registered the
  **dbus AudioOutListener (Opus @96k)**, spawned its **ffmpeg/libx264** child, and
  `LISTENING udp/54116`.
- **Framebuffer CONFIRMED (real screendump, not inference):** the EmuTOS GEM desktop
  renders four top-row application shortcuts — **AIM 3.1**, **BALLERBURG**,
  **PACMAN GEM**, and **GEMBENCH** — plus DISK A/B, APPS C, TRASH, and PRINTER.
  Pressing F3 launches Pacman for GEM to its graphical welcome/game window. The
  accepted clone and live proof files are listed above.
- **YM2149 audio CONFIRMED non-silent:** a verify run routed the guest ALSA default
  to a real-time-paced WAV tee (slave `hw:0,0`) and injected ST keyclicks via QMP
  send-key — **PEAK=18170** (pure silence = 0), RMS_overall **1426**, loudest-1s-window
  RMS **2127** on a 48 kHz / 16-bit stereo wav; ~22% of frames non-silent. The live
  path is **YM2149 → SDL/ALSA default (hw:0,0) → AC97 → QEMU dbus audiodev → streamhost Opus**.
- **Golden fixture:** boots straight to the application-populated GEM desktop via
  `-loadvm golden` (INTERNAL snapshot in `overlay.qcow2`, VM_SIZE **583 MiB**, baked
  2026-07-16). Verified after an explicit `loadvm golden`, after launching Pacman
  and resetting, and after a full `streamhost@atarist` restart. The three desktop
  PNGs are byte-identical, SHA-256
  `106006ef99488c0a8983631094f74b24ac559ca83b736ff06e124cf6db6c2297`.

## THE HARD-WON RECIPE (all non-obvious, all baked into the scripts)

### Kiosk / Hatari launch (atarist.sh → /etc/bridge/launch.sh)
The verified launcher (WHY each flag — Hatari 2.4.1):
```
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software    # GPU-less host: software SDL renderer, no GL
export SDL_VIDEODRIVER=x11
export SDL_VIDEO_CENTERED=1
exec hatari --tos /opt/bridge/media/etos1024k.img --machine st --monitor mono \
  --harddrive /opt/bridge/media/atarist-apps --gemdos-drive C --protect-hd off \
  --window --zoom 1.6 --statusbar 0 --drive-led 0 --borders 0 \
  --sound 48000 --ym-mixing model --sound-sync off --frameskips 0
```
- **`--window` (NOT `--fullscreen`)** — the SAME trap as VICE's `-VICIIfull`: real
  SDL fullscreen mode-switch renders **BLACK** in the captured std-VGA framebuffer.
  A window on the bare-X root captures correctly.
- **`--monitor mono`** — ST-high 640x400 mono, the crisp classic black-on-grey GEM
  desktop. (rgb/tv give chunky ST-low/med colour; mono is the iconic ST look.)
- **`--zoom 1.6`** — 640x400 → **1024x640**, fills the framebuffer WIDTH. The max
  fully-visible zoom on a 1024x768 root (zoom 1.92 would be 768 tall but 1229 wide →
  clipped). Leaves ~64 px black bands top/bottom (cosmetic; whole desktop visible).
- **`--sound 48000 --ym-mixing model`** — YM2149 → SDL → ALSA default → AC97. The
  AC97 card (tile device set) MUST be present + `/etc/asound.conf` routes default →
  hw:0,0 (already true in the base).
- Kiosk = getty autologin `bridge` on tty1 → `startx` → `~/.xinitrc` (xset s off,
  1024×768) → `exec /etc/bridge/launch.sh` (= `exec hatari`). Because `.xinitrc`
  `exec`s the launcher, **hatari IS the X session leader**: killing hatari tears X
  down, and `systemctl stop getty@tty1` (no respawn) is the clean way to end it.

### GEMDOS application drive and launchers

- Hatari maps `/opt/bridge/media/atarist-apps` as writable drive **C:**. This is a
  normal host folder stored inside the Debian bridge overlay, not a floppy image;
  it avoids floppy-size limits and keeps the original archives with their apps.
- `C:\EMUDESK.INF` is CRLF-encoded. Its `#X` records place the four shortcuts on
  the top row; its app records select each program's working directory and bind
  **F1 AIM**, **F2 Ballerburg**, **F3 Pacman**, and **F4 GEMBench**. This also makes
  launching reliable when absolute-pointer calibration differs between clients.
- Payload layout is `C:\APPS\{AIM,BALLER,PACMAN,GEMBNCH}` and
  `C:\ORIGINAL\*.zip`. The builder downloads and SHA-verifies each original,
  extracts only these four app trees, writes `EMUDESK.INF`, transfers the folder,
  and then launches Hatari with the GEMDOS flags.

### AUDIO VERIFY — the two traps
1. **Never use a `null` slave for the WAV tee.** A `type file` default with a
   `slave { type null }` has **NO clock** — Hatari's SDL callback drains it at max
   speed and wrote a **3.16 GB** wav in seconds, filling the guest `/` and inflating
   the overlay. Use a **real-time-clocked slave = `hw:0,0`** (QEMU's AC97 free-runs
   at 48 kHz), which paces the capture to real time (~192 KB/s stereo).
2. **The streamed ALSA wav header is not backpatched** — its frame-count field stays
   0/placeholder, so Python's `wave` module reports 0 frames. Measure by reading the
   **raw PCM after the `data` chunk** as int16-LE and computing PEAK/RMS with numpy.
   Sound source = EmuTOS's **YM2149 keyclick** (one click per ST key) driven by QMP
   `send-key` (`/root/cdrv.py <qmp> key a`). See the AUDIO VERIFY block in atarist.sh.

## Ports (assigned — CONFIRMED live 2026-07-08)
- streamhost UDP (WebTransport): **54116**.
- ssh hostfwd (host→guest :22, for `labctl exec` later): **127.0.0.1:5816**
  (guest user `bridge`, key `/data/vms/bridge/bridge_key`).
- SPA web port (reserved for integration): **8116**. VMID **216**.

## Proven raw QEMU profile (the exact tile device set — MUST match golden bake)
```
qemu-system-x86_64 -name streamhost-atarist -enable-kvm -m 1536 -smp 2 -cpu host -rtc base=localtime \
  -drive file=overlay.qcow2,if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5816-:22 -device e1000,netdev=n0 \
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
- **Overlay is larger than the c64 tile's (~4.1 GB apparent vs 790 MB).** The
  aborted `null`-slave audio-verify balloon (see trap #1) left ~3 GB of allocated
  qcow2 clusters even after the guest deleted the file + `fstrim`. Harmless on the
  **ZFS-compressed `/data`** (the zeroed clusters compress away — `df /data` is
  healthy), and functionally irrelevant. To compact it you'd `qemu-img convert`,
  which would DESTROY the golden snapshot — so it is left as-is.
- **Pointer:** `SH_POINTER=abs` via usb-tablet. GEM is mouse-driven; the abs tablet
  maps into guest X → SDL → Hatari's emulated ST mouse. Desktop function keys
  F1-F4 are an additional deterministic launch path and were used for acceptance.
- **QEMU user-network after an in-process restore:** `labctl reset atarist`
  (`loadvm golden`) restores the correct app desktop, but the existing QEMU
  process can subsequently accept hostfwd TCP/5816 without completing the guest
  SSH banner. A `systemctl restart streamhost@atarist` starts fresh QEMU slirp,
  loads the same golden, preserves the identical framebuffer, and restores SSH.
  The live tile was left in this cold-restart/SSH-healthy state.
- **Windowed, not true-fullscreen:** the GEM window is 1024x640 centred on a black
  1024x768 root (real SDL fullscreen renders black in capture). Cosmetic; the desktop
  is fully visible and captured. A future option is to match the X screen resolution
  to the Hatari window for edge-to-edge fill.
- **Rollback for the 2026-07-16 app re-bake:** pre-change overlay copy
  `/data/vms/streamhost/backups/atarist-apps-20260715T234437Z/overlay.qcow2`,
  SHA-256 `144888cdb7e3cef500e5d6765e8b840036c56f63d0092aa86d8e5f9728c787bf`.
  Stop `streamhost@atarist` (its ExecStop kills only the pidfile-owned QEMU), copy
  that file over the tile overlay with `nice -n15 cp --reflink=auto`, then start
  the service. The backup contains the prior internal `golden` (543 MiB, dated
  2026-07-15 10:57:58).

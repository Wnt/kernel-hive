# Commodore Amiga 500 + Workbench 1.3 — gallery station notes (:8118)

**Guest:** a captured **Debian 12 x86_64 kiosk** running **FS-UAE** (windowed),
emulating a genuine **Commodore Amiga 500** (Motorola **68000**, OCS chipset) that
auto-boots **Workbench 1.3** off a real **Kickstart 1.3** ROM. This is a
**kiosk** — streamhost captures the Linux framebuffer + AC97 audio
(the Amiga **Paula** chip routed through OpenAL -> ALSA -> AC97) exactly like every
other station. See **`streamhost/docs/BRIDGE.md`** for the reusable bridge pattern.

> **DISTINCT FROM the `aros` station.** `aros` (VMID 110, udp 54110) is
> **native AROS-on-x86** — QEMU boots `aros-pc-i386.iso` directly on an i386 CPU;
> it is an *AmigaOS-compatible reimplementation*, not the real thing. **This
> `amiga` station is the real 68000 Amiga 500** running Commodore's actual
> Kickstart/Workbench ROMs under a software emulator. Different CPU, different OS,
> different era — two separate placards.

**Shared base:** `/data/vms/bridge/bridge-base.qcow2` (read-only backing; built by
`scripts/build-guests/lib/bridge-base.sh`). FS-UAE is **not** in the frozen base image
that predates this station — the build script installs it into the overlay (and
`bridge-base.sh` has been updated to capture fs-uae + the media in on a from-scratch
NVMe rebuild).
**Build script (station):** `scripts/build-guests/tiles/amiga.sh` (thin overlay + fs-uae
install + media fetch + kiosk `launch.sh` + checkpoint capture + verify).
**Station dir (host):** `/data/vms/streamhost/stations/amiga/` — `overlay.qcow2` (thin, on
the base; holds the INTERNAL `golden` snapshot), `qemu-streamhost.sh`, `station.env`.
**Proof:** `/data/vms/streamhost/stations/amiga/proof/workbench-desktop.png` (the
Workbench 1.3 desktop), `loadvm-golden-restore.png` (cold `-loadvm golden` lands on
the same desktop), `streamhost-live.png` (the live station under streamhost@amiga).

## License / media provenance (copyrighted media — free in this private collection; binaries NEVER committed)
The Kickstart ROM + Workbench ADF are copyrighted Commodore/Cloanto property,
**free to use in this private home-lab collection** (same stance as the OS/2,
Win9x, NeXTSTEP stations). The only rule: don't re-distribute those copyrighted binary
media files via the GitHub repo. They are **gitignored** (`*.adf`, `*.rom`, `Kickstart*.rom`,
`kick*.rom`) and **re-fetched at build time** — never stored in the repo. Live copies
+ provenance are in the guest at `/opt/bridge/media/amiga/{kick13.rom,workbench13.adf,PROVENANCE}`.

- **Kickstart 1.3 rev 34.005** (A500/A1000/A2000/CDTV), 262 144 bytes,
  md5 `82a21c1890cae844b3df741f2762d48d`. Source: archive.org item
  **`commodore-amiga-firmware`**, file
  `Kickstart v1.3 r34.005 (1987-12)(Commodore)(A500-A1000-A2000-CDTV)[!].zip`.
- **Workbench 1.3 (34.20) Boot disk** (Commodore, 1988), 901 120-byte ADF,
  md5 `d10f4907697c4eafcf976b4ef6ea829b`. Source: the **emu-france amigamuseum**
  preservation mirror (`Workbench 1.3 (34.20) - Boot (Commodore) (1988).zip`).
  (archive.org has the Kickstart firmware set but no readily-locatable *bootable*
  WB1.3 boot ADF — hence the emu-france preservation mirror for the disk only.)

## Curated metadata (for the UI placard)
- **Year:** Amiga 500 = **1987**; Workbench/Kickstart 1.3 = **1988** (rev 34.x).
- **Lineage:** Commodore's best-selling Amiga — Motorola **68000** @ 7 MHz + the
  custom chipset **Agnus/Denise/Paula** (blitter, copper, 4-channel sampled sound,
  4096-colour HAM). The multitasking **AmigaOS**/Workbench was years ahead: a
  colour, mouse-driven, pre-emptively multitasking desktop on a home computer.
- **One line:** *"A 1987 home computer whose custom chips (blitter + copper +
  4-channel Paula sound) gave it colour multitasking and arcade graphics the PC
  and Mac couldn't touch for years."*
- **Iconic era software:** Workbench 1.3, the AmigaDOS CLI, Deluxe Paint,
  the boot "insert disk" hand, the famous floppy-drive click.
- **archetypeHint:** **wedge-beige** — the low-profile beige A500 "wedge" keyboard-
  computer with a chunky external floppy and a 1080 CRT.

## LIVE STATION STATUS (2026-07-08) — LIVE at udp/54118, Workbench 1.3 desktop CONFIRMED, Paula non-silent
- **streamhost@amiga is active** and serving udp/54118. The daemon attached to the
  QMP socket, captured the framebuffer ("first frame 1024x768"), registered the
  **dbus AudioOutListener (Opus @96k)**, and spawned its **ffmpeg/libx264** child.
- **Framebuffer CONFIRMED (real screendump, not inference):** the Workbench 1.3
  desktop renders — the white menu/title bar ("Workbench release.   888248 free
  memory"), the **RAM DISK** icon and the **Workbench1.3** floppy icon on the classic
  1.3 blue background. The transient AmigaDOS CLI boot window
  ("A500/A2000 DK Workbench disk.  Release 1.3 version 34.20") closes after LoadWB.
- **Paula audio CONFIRMED non-silent:** a verify run teed ALSA `default` to a WAV
  while FS-UAE booted (drive-click + startup audio) — **PEAK=19660** (pure silence
  = 0), overall **RMS=1740.8**, loudest-1s **RMS=4095.1** on a 23 s / 48 kHz / 16-bit
  stereo capture. The live path is
  **Paula -> OpenAL (ALSA backend) -> ALSA default (hw:0,0) -> QEMU AC97 -> streamhost Opus**.
- **Checkpoint scene:** boots straight to the Workbench desktop via `-loadvm golden`
  (INTERNAL snapshot in `overlay.qcow2`, VM_SIZE 802 MiB). Verified: a live
  `loadvm golden` restore lands on the identical desktop (no Amiga boot, no floppy
  load, no keypresses).

## THE HARD-WON RECIPE (all non-obvious, all baked into the scripts)

### FS-UAE install (amiga.sh -> overlay)
1. **FS-UAE is NOT in the frozen bridge seed** (this station postdates the base freeze).
   `apt-get install -y fs-uae` runs INTO the overlay (`fs-uae 3.1.66-2` on bookworm).
   It pulls `libopenal1` (Paula audio) + mesa (llvmpipe software GL). The guest has
   working SLIRP internet (static `10.0.2.15`, dns `10.0.2.3`), so apt + the media
   fetch both work in-guest.

### Kiosk / FS-UAE launch (amiga.sh -> /etc/bridge/launch.sh)
The verified launcher (WHY each flag — FS-UAE 3.1.66; options passed as `--key=value`,
no config file needed):
```
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export LIBGL_ALWAYS_SOFTWARE=1     # GPU-less host: llvmpipe software OpenGL for FS-UAE
export SDL_VIDEODRIVER=x11
export ALSOFT_DRIVERS=alsa
exec fs-uae --amiga_model=A500 --kickstart_file=.../kick13.rom \
  --floppy_drive_0=.../workbench13.adf --floppy_drive_volume=100 \
  --fullscreen=0 --window_width=720 --window_height=568 \
  --automatic_input_grab=0 --initial_input_grab=0 2> /tmp/fs-uae.err
```
- **`LIBGL_ALWAYS_SOFTWARE=1`** — FS-UAE renders via OpenGL and the host has NO GPU.
  Force mesa **llvmpipe** software GL or FS-UAE fails to get a GL context.
- **`--fullscreen=0` + fixed `window_width/height`** — real fullscreen renders **BLACK**
  in the captured std-VGA framebuffer (identical trap to VICE `-VICIIfull` on the C64
  station). A **WINDOW** (720x568) on the bare-X root captures correctly (centred, black
  border — cosmetic).
- **`--floppy_drive_volume=100`** — enables FS-UAE's authentic drive-**click** sound.
  This is the guaranteed non-silent audio source used for the acceptance gate (the idle
  Workbench desktop is otherwise silent).
- **`ALSOFT_DRIVERS=alsa`** — force OpenAL to the ALSA backend so Paula deterministically
  reaches `default` -> `hw:0,0` -> AC97 (no PulseAudio on labhost).
- **`--automatic_input_grab=0 --initial_input_grab=0`** — don't let FS-UAE grab/hide the
  pointer; the streamhost abs pointer drives the guest X cursor.
- **THE STDERR-REDIRECT TRAP:** launch.sh runs as user `bridge`. Redirecting stderr to a
  **root-owned** dir (`2> /var/log/fs-uae.err`) makes bash fail to open the file, aborts
  the `exec`, and the whole X session dies in **~1.7 s** (getty then hits `start-limit`).
  Redirect only to a **bridge-writable** path (`/tmp/fs-uae.err`). Clear a looped getty
  with `systemctl reset-failed getty@tty1` before restart.
- Kiosk = getty autologin `bridge` on tty1 -> `startx` -> `~/.xinitrc` (xset s off,
  1024x768) -> `/etc/bridge/launch.sh`.

### Audio verify (how the non-silent number was measured)
Temporarily swap `/etc/asound.conf` so `default` is a **tee**:
```
pcm.!default { type file; slave.pcm "hw:0,0"; file "/tmp/paula.wav"; format "wav" }
```
restart the kiosk (fresh FS-UAE boot -> drive clicks), let ~15 s accumulate, `pkill
fs-uae` to release the device, then measure. NOTE: the ALSA `file` plugin does **not**
finalise the WAV header on an abrupt kill (`nframes`=0), so measure the **raw PCM**
(skip the 44-byte header, interpret as s16le stereo) rather than trusting `wave.getnframes()`.
Restore the live `asound.conf` (`type plug; slave.pcm "hw:0,0"`) before the checkpoint capture.

## Ports (assigned — CONFIRMED live 2026-07-08)
- streamhost UDP (WebTransport): **54118**.
- ssh hostfwd (host->guest :22, for `labctl exec` later): **127.0.0.1:5818**
  (guest user `bridge`, key `/data/vms/bridge/bridge_key`).
- UI web port (reserved for integration): **8118**. VMID **218**.

## Proven raw QEMU profile (the exact station device set — MUST match checkpoint capture)
```
qemu-system-x86_64 -name streamhost-amiga -enable-kvm -m 1536 -smp 2 -cpu host -rtc base=localtime \
  -drive file=overlay.qcow2,if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5818-:22 -device e1000,netdev=n0 \
  -loadvm golden   # when the snapshot is present
  -qmp unix:qmp.sock,server=on,wait=off -pidfile qemu.pid
```
Checkpoint capture/verify (HMP over QMP): `savevm golden` / `loadvm golden` / `info snapshots`.

## Deviations / caveats
- **Windowed, not true-fullscreen:** the Workbench window is 720x568 centred on a black
  1024x768 root (real fullscreen renders black in capture). Cosmetic; the desktop is
  fully visible and captured. A future option is to match the X screen resolution to the
  FS-UAE window for edge-to-edge fill.
- **Pointer:** `SH_POINTER=abs` via usb-tablet. Workbench is mouse-driven; the abs tablet
  maps into the guest X -> FS-UAE's emulated mouse. FS-UAE input-grab is disabled so the
  streamhost cursor drives it directly; end-user click calibration through the UI is a
  follow-up (not blocking; not yet exercised), same status as the C64 station.
- **Media source split:** Kickstart from archive.org; Workbench boot ADF from the
  emu-france amigamuseum preservation mirror (no easily-locatable bootable WB1.3 boot
  ADF on archive.org). Both md5-verified in `amiga.sh`.
- **Fallback not needed:** the task allowed a KS3.1 + WB3.1 "prettier" fallback if 1.3
  was troublesome — it was NOT; KS1.3 + WB1.3 built and verified cleanly, so the station
  ships the requested 1.3 pairing (a real A500 boot, not the later AGA look).

## History — cold-boot-on-visit experiment REVERTED (2026-07-13)
A short-lived "cold-boot-on-visit" pilot (labhost `amiga-coldboot-watch.service`, a guest
`amiga-emu` supervisor, a modified `/etc/bridge/launch.sh`, and a coldboot-aware station
launcher) broke the station: it left the checkpoint on a **bare-X** moment (fs-uae
NOT running), so `-loadvm golden` restored a **black 1024x768 X root** instead of the
Workbench desktop. The pilot was fully reverted:
- labhost watcher service removed; guest `/etc/bridge/launch.sh` restored from
  `launch.sh.golden-desktop.bak` (plain `exec fs-uae … --floppy_drive_0=workbench13.adf`);
  guest `/usr/local/bin/amiga-emu` and `/run/emu-on` removed.
- Station launcher restored from `qemu-streamhost.sh.pre-coldboot.bak` (byte-identical to the
  canonical device set below); `station.env` restored from `station.env.pre-coldboot.bak`
  (dropped the coldboot `SH_IDLE_PAUSE_SECS=0` line — kiosks c64/atarist don't set it).
- **Checkpoint recaptured** on a clean Workbench 1.3 desktop: started fs-uae in the live kiosk X
  session (as user `bridge`, `DISPLAY=:0`), let it auto-boot Workbench, then HMP
  recaptured over the station qmp.sock (new checkpoint 814 MiB, device set unchanged;
  today that recapture is `ssh lab 'checkpoint-guard recapture amiga'` — see
  [`../lab/checkpoint-guard.md`](../lab/checkpoint-guard.md)).
  Verified: cold service restart with `-loadvm golden` and `labctl reset amiga`
  both land on the Workbench 1.3 desktop; daemon LISTENING udp/54118, AC97→dbus audio intact.
  Prior overlay preserved at `overlay.qcow2.bak-prerecover`.

## History — idle auto-pause enabled (2026-08-11)
The revert above *said* it dropped the coldboot `SH_IDLE_PAUSE_SECS=0` line, but the
line survived in both the live `station.env` and the repo fixture — so amiga stayed the
fleet's single always-running kiosk for another month (its daemon alone burned
~43% of a core draining PAL-rate FS-UAE frames with zero viewers). 2026-08-11 the
leftover was actually removed: the fixture now carries no idle-pause stanza at all,
so the daemon default applies (QMP stop/cont, grace 60 s) — identical to c64 and
atarist, which have paused this way since registration, audio and all. No new capture,
no launcher change; rollback is one line (`SH_IDLE_PAUSE_SECS=0`) in `station.env` +
`systemctl restart streamhost@amiga`. The pilot's disabled
`amiga-coldboot-watch.service` unit file, also documented as removed but still
present on labhost, was moved aside the same day.

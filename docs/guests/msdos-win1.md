# msdos-win1 station — MS-DOS 6.22 + Windows 1.01 (:8113)

**One image, TWO UI exhibits.** This single `msdos-win1.qcow2` boots to the
genuine **MS-DOS 6.22** `C:\>` prompt AND launches **Windows 1.01** (`WIN`). Use
it to back both a "MS-DOS 6.22" exhibit and a "Windows 1.0" exhibit later.

- **Live station:** streamhost `msdoswin1` (the neko :8113 URL that used to sit here
  is historical — see the banner below)
- **Build script:** `scripts/build-guests/tiles/msdos-win1.sh` (from-scratch, `bash -n` clean)
- **Artifact:** `/data/gallery-guests/MSDOSWin1/msdos-win1.qcow2` (120 MB virtual, ~2 MB real)
- **Proof shots:** `/data/gallery-guests/MSDOSWin1/verify-dos-prompt.png` (C:\>),
  `verify-win101-gui.png` (Win 1.01 MS-DOS Executive GUI)

> **Historical (neko-era) wiring below.** The exhibit runs today as the streamhost
> station **`msdoswin1`** — see its stanza in `streamhost/tiles-manifest.sh`
> (`streamhost@msdoswin1`). The neko compose/:8113 wiring and the
> `gallery-integrate-all.sh` reconciliation plan below are neko-era; that integrator
> was deleted in the 2026-07 restructure — git history. Build script, artifact and
> guest quirks still apply.

## Win 1.01 four-issue deep fix — 2026-07-13 (PROMOTED LIVE 2026-07-14 via Option B below)

Four user-reported Windows 1.01 problems were root-caused and fixed on a **clone**
(`/data/vms/soltest/win101-aeeb/`), every step verified by real framebuffer
screendumps, then promoted into the live checkpoint on 2026-07-14 (see "Option B —
PROMOTED LIVE"). **Supersedes the "mouse BLOCKED" note in the older section below.**

Authoritative background (WinWorld/Computernewb/BetaArchive/pcjs, MS KB Q28502):
Win 1.01 links the display/keyboard/mouse `.DRV` modules into the FASTBOOT blobs
`WIN100.BIN`/`WIN100.OVL` **at SETUP time** — the prebuilt `WIN10.zip` tree has no
separate driver files and no `SETUP.EXE`, so the bound-in driver can only be changed
by re-running SETUP. The tree also ships a **1-byte `MSDOS.EXE`** (genuine media has
the real MS-DOS Executive here) — a marker that the single-floppy redistribution is
damaged.

### 1. Mouse doesn't work — FIXED on clone (needs checkpoint recapture; NO device-set change)
- **Diagnosis.** The bound-in "Microsoft Mouse" driver in the prebuilt `WIN100.OVL`
  drives a serial/bus mouse directly (it does NOT use INT 33h). Two independent
  problems: (a) the live launcher gives QEMU only the default **PS/2** mouse, which
  the 1985 driver can't use; (b) even adding a QEMU serial mouse
  (`-chardev msmouse -device isa-serial`, COM1) shows **no cursor** — QEMU's
  `msmouse` is documented not to be detected by Win 1.01's stock driver (QEMU
  msmouse reset-handshake bug, GitLab #78). Framebuffer-confirmed: stock driver +
  serial msmouse = no cursor, no motion.
- **Fix (validated).** Do a **fresh SETUP install from genuine Win 1.01 media**
  (archive.org `microsoft-windows-1.01-install-disks`, 5 disks) with the
  **Windows 2.03 `MOUSE.DRV`** (3667 B, from `microsoft-windows-2.03-5.25`
  D2_Build.img) copied over the 1.01 `MOUSE.DRV` on the SETUP disk BEFORE installing;
  pick "Microsoft Mouse (Bus/Serial)" + "EGA (more than 64K) with Enhanced Color
  Display". The 2.03 driver **works with QEMU's DEFAULT PS/2 mouse** — so the live
  launcher needs **no new device** (`loadvm golden` device-set preserved).
- **Proof.** After `WIN`, injected relative motion moves a visible arrow cursor; a
  left-click on the **File** menu opened it (Run/Load/Copy/Get Info/Delete/Rename).
  Cursor move + click both confirmed by screendump.

### 2. "Cannot run NOTEPAD.EXE" for every app — FIXED on clone (config only; NO device-set change)
- **Diagnosis.** Systemic (CALC/NOTEPAD/CLOCK/PAINT all fail identically) and **not**
  memory — CHKDSK shows 584 KB conventional free. Root cause is Win 1.x's **DOS
  major-version check**: it accepts DOS 2.x/3.x and refuses to launch tasks under
  DOS 6.22. (Win 1.01 boots to the Executive fine; only app-launch trips the check.)
- **Fix (validated).** Put `SETVER.EXE` in `C:\DOS` (`EXPAND` it from Disk2's
  `SETVER.EX_`), add `DEVICE=C:\DOS\SETVER.EXE` to `CONFIG.SYS`, and register
  `SETVER WIN100.BIN 3.30` **and** `SETVER WIN.COM 3.30`, reboot. SETVER matches by
  filename regardless of path, so it also covers a `C:\WINDOWS` install.
- **Proof.** With SETVER active, NOTEPAD, Calculator, Paint and Clock all open into
  real windows (screendumped). This is the single highest-value fix.

### 3. "Sometimes one Enter is not enough" — ROOT-CAUSED (focus, not send-key timing)
- **Diagnosis.** From a **freshly-focused MS-DOS Executive**, a single held Enter
  launches the selected app **6/6** across reboots. The nondeterminism appears only
  after another window/dialog has taken focus — Win 1.01 has **no Alt-Tab**, so once
  an app window is open, Enter goes to *it*, not the Executive, and app-launch
  "stops working" until the Executive is re-focused (which needs the mouse). Earlier
  ~10% readings were on VMs where a prior window/`Cannot run` dialog held focus. It
  is **not** a QMP send-key timing bug for Enter/letters (those are reliable);
  contrast the separate `SH_LEGACY_KBD` arrow-key remap, which IS a real extended-
  scancode issue.
- **Fix.** Deterministic keyboard flow from a focused Executive: type the file's
  first letter(s) to select, then one Enter. Full determinism comes with the mouse
  (issue 1): click the Executive to focus, double-click the app.

### 4. Weird characters during launch — DIAGNOSED (splash redraw artifact)
- **Diagnosis.** Captured mid-blit frames of the `WIN` startup splash show the
  MICROSOFT logo painting with torn/interlaced streaking and a partially-drawn
  copyright line, which resolve to a clean splash a frame later. It is a **display/
  redraw artifact** — Win 1.01 paints the splash progressively and the streaming
  encoder captures intermediate frames; it is not a guest data/keyboard/codepage
  bug (type-ahead does not echo characters, and app windows paint clean).
- **Mitigation.** Guest-side there is nothing to fix; if objectionable it is a
  streamhost concern (suppress/discard the mid-blit transition frames).

### Promotion (go/no-go for the human)
- **Option A — minimal (issue 2 only, lowest risk).** Capture **SETVER** into the live
  checkpoint (add `SETVER.EXE`, `DEVICE=` line, the two `SETVER` entries) and re-save
  `golden`. Config-only, **no device-set change**; fixes app-launch. Mouse stays
  broken.
- **Option B — complete (issues 1+2, recommended).** Replace the prebuilt `C:\WIN10`
  tree with the **clone-validated genuine Win 1.01 install + Windows 2.03 MOUSE.DRV**
  (already built at `/data/vms/soltest/win101-aeeb/disk_install2.qcow2`), keep the
  SETVER entries, point the `WIN` launcher/menu at the install dir, and re-save
  `golden`. **No device-set change** (default PS/2 mouse) -> `loadvm golden` stays
  valid; but it is a **from-scratch Windows rebuild**, so it needs a human go and a
  post-capture framebuffer gate. The DOS side (gallery menu, KEEN/COSMO/DOOM games) is
  independent and unaffected.

### Option B — PROMOTED LIVE 2026-07-14 (user-approved; guest checkpoint done + framebuffer-gated)

The complete fix (issues 1+2) is now **captured into the live `msdoswin1` checkpoint**.
Built on a namespaced clone (`/data/vms/soltest/win101-integ`, since removed) from
`disk_install2.qcow2`, framebuffer-gated on the clone AND on the live station, then
swapped in with a timestamped backup.

- **What changed in the checkpoint** (`/data/gallery-guests/MSDOSWin1/msdos-win1.qcow2`):
  - The genuine SETUP install lives at **`C:\WINDOWS`** (Windows 2.03 `MOUSE.DRV`
    bound into `WIN100.OVL`/`WIN100.BIN` at SETUP time — no separate `.DRV` file, as
    expected; it drives QEMU's default PS/2 mouse, **no device-set change**).
  - **`WIN.BAT` and the `AUTOEXEC.BAT` PATH were repointed from `C:\WIN10` →
    `C:\WINDOWS`** — this was the missing Option-B step (`WIN.BAT` still `CD \WIN10`'d
    into the old broken prebuilt tree). Edited offline via `qemu-nbd` + `mtools mcopy`.
  - SETVER already captured: `C:\DOS\SETVER.EXE`, `DEVICE=C:\DOS\SETVER.EXE` in
    `CONFIG.SYS`, and the version table carries **`WIN100.BIN 3.30` + `WIN.COM 3.30`**
    (verified at runtime with `SETVER` no-args). SETVER matches by filename, so it
    covers the `C:\WINDOWS` launch.
  - DOS gallery menu + `KEEN`/`COSMO`/`DOOM` (`GAMES\KEEN1`, `COSMO1`, `DOOM`) intact.
  - New `golden` live-RAM snapshot = clean MS-DOS Executive at `C:\MSDOS622\WINDOWS`,
    mouse-ready (snapshot `golden` 2026-07-14 03:28:45, VM_SIZE 1.63 MiB).
- **Framebuffer proof (LIVE station):** `labctl shot` → genuine Win 1.01 Executive;
  injected QMP rel move → arrow cursor tracks; typed `N` → NOTEPAD.EXE selected;
  single Enter → **Notepad window opened, no "Cannot run"**. On the clone also proved:
  left-click opens the window System menu, and a **double-click launched an app**
  (Clipboard) — no "Cannot run". `loadvm golden` restores straight to the mouse-ready
  Executive.
- **Backup / rollback.** Pre-swap live checkpoint saved to
  `/data/gallery-guests/MSDOSWin1/msdos-win1.qcow2.bak-preB-1783989036`. Rollback:
  ```
  systemctl stop streamhost@msdoswin1
  kill "$(cat /data/vms/streamhost/tiles/msdoswin1/qemu.pid)" 2>/dev/null
  cp -f /data/gallery-guests/MSDOSWin1/msdos-win1.qcow2.bak-preB-1783989036 \
        /data/gallery-guests/MSDOSWin1/msdos-win1.qcow2
  bash /data/vms/streamhost/tiles/msdoswin1/qemu-streamhost.sh
  systemctl start streamhost@msdoswin1
  ```
- **GOTCHA — "input dead" is idle auto-pause, not a guest bug.** The shared
  streamhost daemon idle-auto-pauses the VM after ~60 s with no client
  (`query-status` → `paused`). QMP input on a paused VM is **silently dropped** — so
  a direct-QMP framebuffer gate must `{"execute":"cont"}` (or connect a browser
  client) first. Keyboard + mouse are fully functional once `running:true`. This cost
  a detour during the gate; noted so the next agent doesn't mis-diagnose it as a
  keyboard regression.
- **Still host-side (not the guest checkpoint):** issue #4 (splash mid-blit streaking) is
  cosmetic/streamhost-side (progressive splash paint captured mid-frame); unchanged.
  End-to-end 1:1 browser mouse depends on the daemon's merged bounded-relative
  path + the UI `pointerRel` flag (main chat) — both since shipped
  (commit `25e27b3`) and browser-verified 1:1 live 2026-07-14.

## Streamhost fixes 2026-07-13 (keyboard / mouse / sound)

Three user-reported issues on the live `msdoswin1` streamhost station were
root-caused and two of the three shipped live (the third is device-set-blocked).

1. **Keyboard "stops working" in Windows 1.01 — FIXED (live).** Windows 1.01
   (1985) predates the 1986 101-key *Enhanced* keyboard and its bound KEYBOARD
   driver does **not** decode the `0xE0`-prefixed EXTENDED scancodes the browser
   sends for the dedicated Arrow/Home/End/PgUp/PgDn/Ins/Del cluster — so those
   keys silently drop once Win installs its own INT 09h handler (DOS's BIOS
   handler accepts both forms, which is why DOS keyboard works). Letters/Enter/Esc
   always worked. Fix is host-side, **no checkpoint recapture**: a per-station
   `SH_LEGACY_KBD=1` quirk in streamhost `input.rs` `key_qnum()` remaps wire codes
   `0xE047..=0xE053` to the BARE numeric-keypad scancode (`code & 0x7f`: Up=0x48,
   Down=0x50, Left=0x4B, Right=0x4D, …) instead of the enhanced `0x80|` form. Guest
   NumLock is OFF in the checkpoint, so the keypad codes act as cursor keys. Gated by
   `SH_LEGACY_KBD` in `tile.env` (default off elsewhere; reuse for any pre-1986
   Win 1.x/2.x guest). Unit-tested (`input::tests::legacy_arrows_*`).

2. **No mouse cursor in Windows 1.01 — NOT shipped (blocked; needs checkpoint recapture +
   Win 1.01 SETUP media).** Win 1.01 predates PS/2 and needs a Microsoft SERIAL
   mouse. Adding QEMU `-chardev msmouse,id=msmouse0 -device isa-serial,chardev=msmouse0`
   (COM1) is validated to boot clean, BUT the prebuilt `WIN10.zip` in this build
   has **no mouse driver bound into `WIN.COM`** (only `HPLASER.DRV` ships as a
   separate `.drv`; display/kbd/mouse drivers are bound at SETUP time) and the tree
   has **no `SETUP.EXE`** to add one — so a cold-boot with the serial mouse still
   shows no cursor (framebuffer-verified on a soltest clone). Completing this needs
   the genuine Win 1.01 SETUP disk set (WinWorldPC/archive.org), an interactive
   re-SETUP selecting *Microsoft Mouse → Com1* to rebuild `WIN.COM`, then a checkpoint
   recapture with the new device set. Deferred for green-light — the serial device is
   NOT in the live launcher (it would break `loadvm golden` with no working driver).

3. **No sound in Commander Keen (MS-DOS) — FIXED (live).** Keen 1 *Marooned on
   Mars* is PC-speaker only and the launcher had no audio path (`SH_AUDIO=off`, no
   `-audiodev`). Fix mirrors the freedos station but PC-speaker-only: launcher now has
   `-machine pc,pcspk-audiodev=snd0`, `-display dbus,p2p=on,audiodev=snd0`,
   `-audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16`, and
   `tile.env` sets `SH_AUDIO=on`. **No checkpoint recapture** — `pcspk-audiodev` is a
   backend-only change (the `isa-pcspk` device already exists on the `pc` machine),
   so `loadvm golden` still restores (verified). Confirmed under **KVM** (the live
   accel) on a soltest clone: a `-audiodev wav` capture of Keen produced **185,228
   non-silent samples, peak level 24831/32767 (max_volume −2.4 dB)** — a real
   PC-speaker square wave. Live daemon logs the active path: `audio=true`,
   `registered dbus AudioOutListener (Opus @96k)`, `[audio] Init … freq=48000 ch=2`.
   (Note: QEMU `pcspk` audio DOES work under KVM here; the in-kernel PIT does not
   block it. Keen 1 has no sound-config menu — PC-speaker effects are always on.)

**Supersedes** the old "PS/2 kbd+mouse only — do NOT add usb-tablet" note below:
Win 1.01 needs a *serial* mouse (msmouse on COM1), not USB and not PS/2. Interim
navigation stopgap (until/if a browser client confirms the keyboard remap E2E):
type a file's first letter (type-ahead) + Enter to launch in the MS-DOS Executive.

## Status
- GUI CONFIRMED rendering two ways: QEMU `screendump` of the artifact (C:\> prompt
  **and** the Windows 1.01 tiled MS-DOS Executive after `WIN`), and the **neko
  screenshot API** on the live :8113 container (C:\> boot screen).
- Was wired LIVE as its own isolated compose project `osgallery-msdoswin1` and added
  to the :8080 index. Did NOT touch `docker-compose.gallery-guests.yml`,
  `gallery-integrate-all.sh` (neko-era, deleted), or `launch-qemu.sh`.

## License / sourcing (copyrighted media — free in this private collection)
MS-DOS 6.22 and Windows 1.01 are copyrighted Microsoft media. Microsoft
open-sourced only MS-DOS **1.25 / 2.0** (MIT) — **NOT** 6.22, and **no** Windows.
No faithful free/open substitute exists for this pairing (FreeDOS is a separate
station and isn't MS-DOS; Win 1.01 needs real MS-DOS-family binaries beneath it).
Images pulled from archive.org and are **free to use in this private, LAN-only,
edge-passkey collection** — same stance as the project's Win 3.11/95/98/2000/XP
stations; the only rule is not re-distributing the copyrighted binary media via the
GitHub repo.

Sources (archive.org):
- MS-DOS 6.22 Setup Disks 1-3 — `disk-1_202101/MS-DOS 6.22 Install Diskettes/Disk{1,2,3}.img`
- Windows 1.01 single-floppy (carries pre-built `WIN10.zip`) — `windows-1.01_1floppy/Windows 1.01.img`

## Canonical compose service (live on labhost)
File on labhost inside CT 110: `/opt/osgallery/docker-compose.msdoswin1.yml`
Brought up with: `docker compose -p osgallery-msdoswin1 -f docker-compose.msdoswin1.yml up -d`

```yaml
services:
  msdoswin1:
    image: neko-qemu:latest
    restart: unless-stopped
    shm_size: 1gb
    ports: ["8113:8080","53360-53379:53360-53379/udp"]
    volumes: ["./gallery-guests:/guests:ro"]
    devices: ["/dev/kvm:/dev/kvm"]
    environment:
      NEKO_SCREEN: "1280x720@30"
      NEKO_PASSWORD: "neko"
      NEKO_PASSWORD_ADMIN: "admin"
      NEKO_EPR: "53360-53379"
      NEKO_ICELITE: "true"
      NEKO_NAT1TO1: "192.0.2.12"
      NEKO_SESSION_IMPLICIT_HOSTING: "true"
      OS_NAME: "MS-DOS 6.22 + Windows 1.01"
      QEMU_MEM: "16"
      QEMU_SMP: "1"
      QEMU_MACHINE: "pc"
      QEMU_VGA: "std"
      GUEST_DISK: "/guests/MSDOSWin1/msdos-win1.qcow2"
      GUEST_FMT: "qcow2"
      GUEST_IF: "ide"
      GUEST_BOOT: "c"
      QEMU_EXTRA: "-cpu host -snapshot"
      ACCEL: "kvm"
```

**Perf: KVM flip (2026-07-04).** Flipped TCG→KVM per the perf-baseline report
(§4 KVM-safe set; "DOS busy-waits under TCG; KVM big win"). `ACCEL: "kvm"` emits
`-enable-kvm` via `launch-qemu.sh`; `-cpu pentium`→`-cpu host`. Kept `QEMU_SMP:1`,
`QEMU_MACHINE:pc`, `QEMU_VGA:std`, and **PS/2-only** (NO `usb-tablet` — 1985/1994
hardware has no USB HID stack). Recreating the container also picks up the
gallery-wide audio-buffer knob (`out.buffer-length=100000,out.latency=50000`,
now the `launch-qemu.sh` default). Verified under KVM (`/dev/kvm` fd open,
`-enable-kvm -cpu host` on the live cmdline): C:\> renders identically, and the
guest input→photon probe improved — mouse median 573→195 ms, keyboard 436→379 ms,
5/5 hits on both (low-contention window). No Win9x knobs apply here (this is real
MS-DOS + Win 1.01, not a protected-mode Win9x guest). Prior TCG config backed up
on host at `docker-compose.msdoswin1.yml.bak-preKVM`.

UDP EPR range `53360-53379` was chosen clear of all existing stations (max in use
was TempleOS `53300-53319`).

## Raw QEMU args (what launch-qemu.sh actually runs — from the container log)
```
qemu-system-x86_64 -name "MS-DOS 6.22 + Windows 1.01" -m 16 -smp 1 \
  -audiodev pa,id=snd,out.buffer-length=100000,out.latency=50000 \
  -display gtk,full-screen=on,zoom-to-fit=on,grab-on-hover=off \
  -vga std -rtc base=localtime -machine pc -enable-kvm -device AC97,audiodev=snd \
  -drive file=/guests/MSDOSWin1/msdos-win1.qcow2,format=qcow2,if=ide \
  -boot c -cpu host -snapshot
```
(KVM: `-enable-kvm -cpu host` from `ACCEL=kvm`. AC97 is harmless — DOS/Win 1.01
have no sound; the `out.buffer-length/out.latency` audio-buffer knob is the
launch-qemu.sh default. std VGA renders the Win 1.01 EGA driver. PS/2 kbd+mouse
only — do NOT add usb-tablet.)

## Manifest row for gallery-integrate-all.sh (historical — the reconciliation never ran; neko-era, deleted)
Index entry already inserted into `/opt/osgallery/gallery/index.html`:
```json
{"label":"MS-DOS 6.22 + Windows 1.01","url":"http://192.0.2.12:8113/?usr=guest&pwd=neko"}
```
Suggested integrator row fields:
- id: `msdoswin1`  port: `8113`  epr: `53360-53379`
- disk: `MSDOSWin1/msdos-win1.qcow2` (qcow2, ide, boot c, `-cpu host -snapshot`, `ACCEL=kvm`)
- mem: 16  smp: 1  machine: `pc`  vga: `std`  sound: default AC97 (or none)
- accel: `kvm` (KVM-safe DOS guest per perf report §4; PS/2-only, no usb-tablet)

## UI integration metadata
- **archetypeHint:** `beige-ibm-pc` — a boxy 1985-era IBM PC/XT/AT with a beige
  case + amber-or-white text CRT. (The image spans 1985 Win 1.01 → 1994 DOS 6.22;
  lead the exhibit with the 5150/5160 IBM PC silhouette.)
- **curatedMetadata:**
  - MS-DOS 6.22 — Microsoft, 1994. Last standalone retail MS-DOS. 16-bit real-mode
    single-tasking command-line OS; `C:\>` prompt, `DIR`/`CD`/`EDIT`/`QBASIC`.
    Iconic era software: EDIT, QBASIC, DOS games (Doom/Duke via the FreeDOS station).
  - Windows 1.01 — Microsoft, 1985. First-ever Windows release; a DOS "operating
    environment", not an OS. Tiled (non-overlapping) windows, the MS-DOS Executive
    file shell, and bundled apps: Calculator, Paint, Reversi, Cardfile, Calendar,
    Clock, Control Panel, Notepad, Terminal, Write. Runs on top of MS-DOS via `WIN`.

## Reproduce
```
# on labhost (writes to /data/gallery-guests/MSDOSWin1/)
bash scripts/build-guests/tiles/msdos-win1.sh          # download, build, verify
FORCE=1 bash scripts/build-guests/tiles/msdos-win1.sh  # force full rebuild
VERIFY=0 bash scripts/build-guests/tiles/msdos-win1.sh # skip the framebuffer boot
```

## Build gotchas (hard-won)
- **`FDISK /MBR` is mandatory.** `sfdisk` writes the partition table but leaves the
  MBR bootstrap code zeroed → guest hangs forever at "Booting from Hard Disk...".
  Running `FDISK /MBR` on the provisioning floppy lays down the MS-DOS master boot
  record that chain-loads the active partition. This was the key fix.
- **`FORMAT C: /S < A:\YES.TXT`** answers the "Proceed (Y/N)?" prompt from a piped
  file — fully unattended, no QEMU `sendkey` timing.
- **`WIN.BAT` does `CD \WIN10` first** — Win 1.01's `WIN.COM` loads `WIN100.BIN`
  from the current directory.
- Compressed Setup-disk files (`*.??_`, SZDD-packed) are skipped; the uncompressed
  core DOS utilities are injected into `C:\DOS`.

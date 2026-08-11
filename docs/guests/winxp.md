# Windows XP Professional — Kernel Hive retro guest (build notes)

Built from the user's own legit media, automated as far as practical, on
labhost (192.0.2.10) as a neko-qemu gallery guest.

> **CURRENT STATE — see [§12](#12-2026-07-27-rebuild--revived-at-1920×1200-after-the-nvme-migration).**
> The station runs today as the **streamhost** guest `winxp` (VMID 94) at **1920×1200**
> from `/data/vms/streamhost/stations/winxp/winxp-golden.qcow2` (checkpoint,
> resetMode=loadvm). §1–§11 below are the original neko-era usermedia build + the
> 1024×768 polish, kept for the record; the paths/resolution there are superseded.

## Final result (TL;DR)

- **Install state: COMPLETE — boots to the desktop via auto-logon.**
- **Image:** `/data/gallery-guests/WinXP-usermedia/winxp.qcow2`
  (qcow2, 10 GiB virtual, **~841 MiB** actual, IDE, integrity-checked clean).
- **Games — all three verified running in-game:** DOOM, Duke Nukem 3D, Quake.
- **Staged installers:** Firefox 3.6.28, Winamp 5.666 (in `C:\RetroApps\Installers\`).
- Pool `data` at 48% CAP after the build (well under the 85% stop line).
- **NOTE:** run this guest under **`qemu-system-x86_64`**, not `qemu-system-i386`
  (see §7). And it lives in a **DISTINCT dir** because another workflow grabbed
  the obvious one (see §6).

---

## 1. Media handling

- Source (Mac): a pre-integrated XP Pro SP3 (Nov 2014, DriverPacks slipstreamed) zip from the private media collection
  (624 MB ZIP). Contains one install ISO + a "Remove Maher's Digital World"
  cleanup .cmd/screenshot (ignored).
- Extracted on the Mac; the **ISO** (624 MB) was `scp`'d to labhost, then copied
  into the isolated build dir as `winxp-sp3.iso`.

## 2. Unattended detection — partial

Mounted the ISO: it is an **nLite + DriverPacks** repack. `I386\WINNT.SIF`:
- `UnattendedInstall="Yes"`, `UnattendMode=DefaultHide`, `OemSkipEula="Yes"`,
  `OemSkipWelcome=1`, `DriverSigningPolicy=Ignore`.
- **Embedded ProductKey `<REDACTED-see-private-notes>`** (no key prompt — good).
- `Autopartition=0` → text-mode partition/format still needs keystrokes.
- `[GUIRunOnce] command9=%SystemDrive%\DPsFnshr.exe` (DriverPacks finisher).
- `$OEM$\$$\System32\OEMINFO.INI` + top-level `OEM\` DriverPacks mass-storage set.

**Reality check — the GUI phase is NOT fully hands-off.** The answer file omits
`FullName`, `ComputerName`/`AdminPassword`, and `JoinWorkgroup`, so GUI setup
stops at three pages that must be filled by keystroke:
- *Personalize Your Software* — type a Name (I used `labuser`). (Empty → error
  "Administrator and Guest are not allowable names".)
- *Computer Name & Administrator Password* — name auto-suggested; I left the
  **Administrator password blank** (this is what enables clean auto-logon).
- *Workgroup* — Next is greyed until a workgroup is typed (I used `WORKGROUP`).

Everything else (EULA, product key, regional, devices, network, DriverPacks
finisher) IS silent.

## 3. QEMU XP profile (i440fx) — the final boot args

```
qemu-system-x86_64 -name winxp-um-gallery \
  -enable-kvm -machine pc -cpu host -m 1024 \
  -drive file=<dir>/winxp.qcow2,format=qcow2,if=ide,index=0,media=disk \
  -boot c \
  -netdev user,id=n0 -device rtl8139,netdev=n0 \
  -vga std \
  -audiodev none,id=snd0 -device AC97,audiodev=snd0 \
  -rtc base=localtime \
  -monitor unix:<dir>/mon.sock,server,nowait \
  -display none
```
- Machine `pc` (i440fx), 1 GB RAM, **IDE** disk (XP has no AHCI/virtio driver
  without F6), **rtl8139** NIC (native XP driver), **std** VGA, **AC97** sound.
- **Install-time only:** add the CD + boot order:
  `-drive file=<dir>/winxp-sp3.iso,format=raw,if=ide,index=2,media=cdrom`
  `-boot order=dc,menu=off`  (drop both after install; use `-boot c`).
- On reboots during install, do NOT press a key at "Press any key to boot from
  CD" — it times out to the HDD.
- For the gallery LXC (neko-qemu): swap `-display none` / `-audiodev none` for
  the neko VNC + pulse audiodev the other stations use; keep the rest identical.

## 4. Headless framebuffer automation (REQUIRED — do not fly blind)

Everything was driven through the QEMU **monitor unix socket** — no VNC /
vncdotool / socat-to-TCP needed:

- **Screenshot every step** (framebuffer = ground truth, NOT logs):
  `echo "screendump /path/x.ppm" | socat - UNIX-CONNECT:<mon.sock>` then
  `pnmtopng x.ppm > x.png`, scp to the Mac, view it.
- **Send input:** `echo "sendkey <keys>" | socat - UNIX-CONNECT:<mon.sock>`
  (`ret`, `up`, `esc`, `tab`, `alt-tab`, `meta_l-r`, letters, `backslash`,
  `shift-semicolon` for `:`, `ctrl-f9` to kill DOSBox, etc.).
- This screenshot→detect→sendkey loop is **mandatory**: XP text-mode + GUI setup
  stall on the partition ENTER, the NTFS-Quick format choice, the three GUI
  answer-file gaps (§2), the first-logon "Display Settings"/"Monitor Settings"
  dialogs, and the F8 "Windows did not start successfully" recovery menu after
  any hard kill. Judging from disk/logs alone hangs forever.

### Pitfalls hit + fixes
- **First-logon "Display Settings" dialog isn't keyboard-focused** (shell /
  DriverPacks RunOnce holds focus). Fix: `sendkey alt-tab` ×3 to focus it, then
  `ret` (OK); accept the follow-up "Monitor Settings" dialog with `ret`.
- **Do NOT run a blind, timed key-loop to clear those dialogs.** I tried an
  "autoclear" loop that sent `alt-tab/ret` every ~28 s; it fired during GUI
  setup and pressed *Next* on the empty *Personalize* page, throwing the
  "enter your name" error repeatedly. Kill any such loop and use ONE verified
  action per dialog instead. (And the loop process survives `mv`-ing its
  script — kill it by PID.)
- **screendump occasionally writes a 0-byte PPM** (race) — just retake.
- Text-mode disk geometry sometimes shows the 10 GB disk as ~6 GB (ATA CHS cap);
  harmless, XP installs to whatever it reports.

## 5. Offline injection (no in-guest clicking) via qemu-nbd + ntfs-3g

Software + tweaks applied offline on the host after shutdown — far more reliable
than GUI automation:
```
modprobe nbd max_part=8
qemu-nbd --connect=/dev/nbd0 -f qcow2 <dir>/winxp.qcow2
partprobe /dev/nbd0
mount -t ntfs-3g /dev/nbd0p1 /mnt/xpwin      # auto-clears the NTFS dirty flag
# ... copy files / edit hives ...
sync; umount /mnt/xpwin; qemu-nbd -d /dev/nbd0
```
- **RetroApps** copied to `C:\RetroApps\`; the `Play-*.bat` launchers +
  `RetroApps-README.txt` also placed in
  `C:\Documents and Settings\All Users\Desktop\`.
  (Launchers use **absolute `C:\RetroApps\...` paths** — an early version used
  `%~dp0`, which on the Desktop copy resolves to the Desktop, not RetroApps.)
- **Auto-logon** (Administrator already has a blank password from §2), set via
  **hivexregedit --merge** into the SOFTWARE hive
  (`\Microsoft\Windows NT\CurrentVersion\Winlogon`):
  `AutoAdminLogon="1"`, `DefaultUserName="Administrator"`,
  `DefaultPassword=""`, `ForceAutoLogon="1"`.
  (`chntpw` is only needed if a build sets a non-blank/locked Administrator —
  the first, later-clobbered build did; this final build's admin is blank.)
- After any hard kill, XP shows the F8 recovery menu next boot — clear it
  offline by removing `C:\WINDOWS\bootstat.dat` (XP recreates it). A **clean
  ACPI shutdown** (`system_powerdown`) avoids it entirely; that's how the final
  image was closed.

## 6. DIRECTORY COLLISION (important — why the path is "…-usermedia")

A **separate concurrent retro-build workflow** independently chose the exact
same `/data/gallery-guests/WinXP/winxp.qcow2` (it runs
`qemu -name winxp-install … -fda unattend.flp … -display vnc`, and even reused
the helper scripts I wrote there). Mid-build it **re-created that qcow2 from
scratch**, destroying my first completed image (both qemus briefly had the file
open r/w). I **ceded `/data/gallery-guests/WinXP/` to that workflow** and rebuilt
mine in the isolated **`/data/gallery-guests/WinXP-usermedia/`** with a unique
image name, VM `-name`, and monitor socket. Two "WinXP" stations were in flight at
the time — since **resolved**: one XP exhibit ships, the live streamhost `winxp`
station (VMID 94).

## 7. Killer/reaper: use qemu-system-x86_64, not -i386

Both my `qemu-system-i386` XP installs were killed mid-GUI-phase
("terminating on signal 15 from pid … (bash)"). The persistent gallery guests
(TinyCore, Alpine, toaruos) all run **`qemu-system-x86_64`** and survive for
many minutes — the concurrent XP workflow almost certainly does a name-based
`pkill qemu-system-i386` cleanup that also catches strays. **Running XP under
`qemu-system-x86_64 -cpu host` evaded it** and the install completed. (A 32-bit
guest runs fine on the x86_64 emulator.) It installs a bit slower than -i386 but
is stable. Keep the guest on `qemu-system-x86_64`.

## 8. Software — all free/shareware/freeware, under `C:\RetroApps\`

Working (double-click a Desktop `Play-*.bat`; all three verified in-game):
- **DOOM** — shareware `DOOM1.WAD` + **Chocolate Doom 3.0.1** (native Win32 GPL
  port). **SDL2 fix:** the launcher sets `SDL_RENDER_DRIVER=software` (QEMU std
  VGA has no HW render driver, else "Couldn't find matching render driver"). Do
  NOT set `SDL_VIDEODRIVER=windib` for SDL2 — it errors "windib not available".
- **Duke Nukem 3D** shareware v1.3D (`DUKE3D.EXE`+`.GRP`) via bundled **DOSBox
  0.74-3**. Required a one-time `SETUP.EXE` → "Save and launch" to create
  `DUKE3D.CFG` (captured into the image; the launcher now runs the game directly).
- **Quake** shareware (`QUAKE.EXE`+`ID1\PAK0.PAK`) via DOSBox. Runs directly
  (reaches the Quake MAIN menu).
- DOSBox itself works on std VGA (SDL 1.2) with no env tweaks.

Period browser: **IE6** preinstalled. Firefox 3.6.28 installer also provided.

Staged installers (`C:\RetroApps\Installers\`, run manually — not silent):
- **Firefox 3.6.28** (Mozilla official archive)
- **Winamp 5.666** (last free classic)

Not bundled — **GTA1** (Rockstar freeware): the free distribution is a 300 MB+
ISO needing an interactive installer; staged as a README note rather than
bloating the image / doing an unreliable in-guest install. Fetch from
archive.org (`grandtheftauto1997rockstargames`) if wanted.

Download-source gotcha: SourceForge/fossies serve an HTML interstitial to curl.
DOSBox 0.74-3 came from `archive.org/download/dosbox-0.74-3/`; Duke3D/Quake
shareware from archive.org / dosgamesarchive.com; Firefox/Winamp from Mozilla /
archive.org.

### Desktop-shortcut payload: Winamp 2.95 (not bundled in the repo)

Separately from the staged `C:\RetroApps\Installers\` Winamp 5.666 installer
above, `winxp.sh`'s `bake_desktop_shortcuts` step drops a real desktop icon
for **Winamp 2.95** onto the checkpoint's desktop so a first-time viewer can just
double-click it. Because Nullsoft's installer can't run headlessly, this was
built once from an already-installed `C:\Program Files\Winamp` tree and
repacked as `scripts/build-guests/assets/winxp/Winamp-2.95-installed.tar.gz`
(sha256 `cd0bbbc4ceebfc2fd8c9b22d63a03fdb3c7a182be680af6dcea032f33c2a8dd9`,
1 797 575 bytes).

That tarball is **not shipped in this repo** (it is a custom repack, not a
stock installer, so there is no stable public URL to fetch it from
automatically). If you want the Winamp desktop icon on a build from a public
checkout:

1. Install Winamp 2.95 freeware into a scratch Windows environment.
2. Disable the first-run registration nag and the startup mini-browser /
   version-check in its `winamp.ini` (so the checkpoint opens straight to the
   player).
3. `tar czf Winamp-2.95-installed.tar.gz -C <scratch-dir> "Program Files/Winamp"`
   and place the result at
   `scripts/build-guests/assets/winxp/Winamp-2.95-installed.tar.gz` (gitignored,
   safe to keep locally).

Without it, `winxp.sh` logs a WARN and simply skips the Winamp shortcut — the
rest of the build (including the staged 5.666 installer above) is unaffected.

## 9. Remaining step — add it as a gallery station (DONE — historical)

> **Status:** done, though not via neko — the exhibit runs today as the live
> **streamhost** station `winxp` (VMID 94). The neko-qemu wiring below was never
> executed; kept for the record.

Add one neko-qemu station in CTID 110 pointing at
`/data/gallery-guests/WinXP-usermedia/winxp.qcow2` with the §3 args (swap
`-display none` / `-audiodev none` for the neko VNC + pulse audiodev the other
stations use, and keep **`qemu-system-x86_64`**). Do **not** hand-edit the live
`setup.sh`/compose here — that belongs to the gallery workflow. The image is
self-contained and boots to the desktop via auto-logon.

## 10. Files on labhost (isolated dir `/data/gallery-guests/WinXP-usermedia/`)

- `winxp.qcow2` — the deliverable disk image (~841 MiB, boots to desktop)
- `winxp-sp3.iso` — the source install ISO (only needed to re-install; optional)
- `boot.sh` — launches the final profile (§3)
- `start-install.sh` — the install-time profile (CD + boot dc)
- `mon.sh` / `shot.sh` — monitor-command and screendump→png helpers
- `payload_RetroApps/` — labhost-side copy of the injected software (source of truth)

## 11. Station polish — 1024×768 display + cursor + drag perf (2026-07-06)

Applied to the canonical `WinXPpro/winxp.qcow2` checkpoint (the one the live station
uses); original backed up as `winxp.qcow2.bak-20260706-032724`.

**RESOLUTION → 1024×768×32 (achieved).** The QEMU **std** (Bochs) VGA that the
station uses has NO XP inbox driver above 640×480, and QEMU **cirrus** is a dead
end here: under KVM the XP desktop only scans out the top ~half of the frame on
a cold `-snapshot` boot (partial paint / no taskbar) at 800×600 and 1024×768 —
it *looks* fine after a live mode-reset but never survives a fresh boot. The
reliable fix is the **VBEMP universal-VESA display miniport** (bearwindows /
AnaPa, `vbempk.zip`) bound to the std-VGA PCI device (`PCI\CC_0300`):
- Use the **VBE 2.0** XP build (`VBE20/XP/PNP/{vbemp.sys,vbemppnp.inf}`). The
  **VBE 3.0** build (`VBE30/`) installs fine but renders **BLACK** on this QEMU
  std VGA (its VBE3 BIOS calls mis-set the mode).
- Installed via a FAT12 driver floppy → Device Manager → the driverless "Video
  Controller (VGA Compatible)" → Update Driver → Install automatically. No
  signing prompt (the repack's WINNT.SIF set `DriverSigningPolicy=Ignore`).
- VBEMP defaults to 1280×800; stepped down to **1024×768, Highest (32 bit)**.
- The image's `winnt.sif` MRU/desk keystroke gotchas from §2/§4 all still apply.

**Screendump vs. neko — important gotcha.** Driving an isolated boot with
`-display none` + monitor `screendump` shows the high-res desktop with a BLACK
bottom on a cold boot (screendump only re-converts dirty framebuffer regions
when there is no active display client). This is a *capture artifact*, NOT a
guest defect: the real station runs `-display gtk` + neko's live ximagesrc capture
and paints the **full frame**. Always verify resolution via the live station's
neko `GET /api/room/screen` (returned `{"width":1024,"height":768}`), not via a
`-display none` screendump.

**CURSOR → usb-tablet (kept).** The station already carries `-usb -device
usb-tablet`; XP has an inbox USB-HID stack (Device Manager shows "Human
Interface Devices"), so the absolute tablet binds and the guest cursor tracks
neko's absolute injection 1:1 — no PS/2 offset. Left as-is.

**PERF → full-window drag OFF (achieved).** Display Properties → Appearance →
Effects → unchecked "Show window contents while dragging"
(`HKCU\Control Panel\Desktop\DragFullWindows="0"`). Luna visual style and font
smoothing kept, so the station still looks like XP.

**IDLE-HLT → N/A.** XP uses ACPI/HLT idle under KVM; the station idles at a few %
of a vCPU (the visible ~8% is mostly neko H.264 encoding), no pegged vCPU. No
DOSidle/AmnHLT-class tool needed (that's a DOS/Win9x problem).

**Reproducibility (captured in, from-scratch NVMe rebuild reproduces it):**
- `scripts/build-guests/stages/winxp-vbemp-hires.sh` — fetches VBEMP, builds the
  driver floppy, and replays the exact monitor-driven install + 1024×768 +
  drag-off + verify sequence. Called from `winxp.sh` after auto-logon injection
  (guard `HIRES=1`). This is the surviving reproducer; the guest runs today as
  the streamhost station `winxp` (see its stanza in `streamhost/stations-manifest.sh`).
- Neko-era canvas wiring (historical): `gallery-integrate-all.sh` carried
  `FIXED_SCREEN[winxp]="1024x768@30"` and the winxp block of
  `docker-compose.gallery-guests.yml` pinned `NEKO_SCREEN=1024x768@30`
  (QEMU_VGA `std`; usb-tablet present). The integrator and the
  `win95-perf-override.yml` / `win311-perf-override.yml` overrides used in the
  neko recreate command are all neko-era, deleted in the 2026-07 restructure —
  git history. (That neko recreate also cleared a pre-existing hung boot — the
  station had been stuck on the XP splash for hours.)

## 12. 2026-07-27 rebuild — revived at 1920×1200 after the NVMe migration

The NVMe migration wiped every checkpoint qcow2 (checkpoints weren't transferred), so the
`winxp` station was DOWN with an intact skeleton but no disk. Rebuilt from source, and
the **fleet resolution target was raised 1024×768 → 1920×1200** (packed-VBEMP on
`-vga std` stays inside the 30 fps encode budget on KVM — see
`docs/lab/tile-resolution-responsiveness.md`).

- **Media:** `/data/images/winxp-sp3-maherz.iso` — the same integrated-SP3 nLite +
  DriverPacks repack the builder targets (`GRTMPVOL_EN` / `WIN51IP.SP3`, Nov-2014,
  654 MB). Install: `scripts/build-guests/tiles/winxp.sh` with `XP_ISO_LOCAL=<iso>` and
  `WINXP_PRODUCT_KEY` = the key already embedded in the ISO's `I386\WINNT.SIF`
  (VLK; no activation). `WANT_GTA1=0` skips the 330 MB GTA download.
- **Install automation reality:** the builder's `A:\WINNT.SIF` (FullUnattended)
  **does** drive the whole GUI phase — no Name/Computer/Workgroup prompts — but its
  `AutoPartition=1` does NOT skip the text-mode partition screen on a blank disk, so
  the run needs ~2 keystrokes (ENTER at the partition list, then pick "NTFS (Quick)").
  Its `[GuiRunOnce] shutdown -s` ends first-logon with a clean power-off. Computer
  name `RETROXP`, Administrator password `retro`.
- **Permanent auto-logon (offline hivexregedit into SOFTWARE):** the in-setup
  `AutoLogonCount=1` is one-shot, so the gallery injects `AutoAdminLogon=1` +
  `DefaultUserName=Administrator` + `DefaultPassword=retro` + `ForceAutoLogon=1`.
  **GOTCHA:** you MUST also set `DefaultDomainName=RETROXP` (the computer name) and
  clear `AutoLogonCount`, or Winlogon can't resolve the local account, silently
  falls to the logon prompt, and resets `AutoAdminLogon=0`. Fixed in `winxp.sh`.
- **1920×1200×32 via VBEMP 2.0 NT** (`winxp-vbemp-hires.sh`): install the `VBE20`
  miniport on the driverless "Video Controller (VGA Compatible)". **KEY DISCOVERY:**
  QEMU's std VGA advertises a Plug-and-Play monitor whose EDID caps the resolution
  slider at 1920×1080. Clear **Advanced → Monitor → "Hide modes that this monitor
  cannot display"** and VBEMP's full list appears (up to 3840×2160); slider End
  (=3840×2160) then 3× Left lands on **1920×1200** (Highest/32-bit). 1920×1200×32 =
  9.2 MiB fits the std-VGA default 16 MiB vgamem, so the production launcher's plain
  `-vga std` renders it full-frame; the mode persists across reboot.
- **Checkpoint scene** (`streamhost/stations/winxp/golden-bake.sh`, resetMode=loadvm):
  station-local `winxp-golden.qcow2` (copy of the pristine `WinXPpro/winxp.qcow2`) with
  an internal `savevm golden` checkpoint. Notepad open+focused (empty, caret top-left),
  Bliss, pointer parked right; screensaver OFF, powercfg "Always On" + timeouts 0,
  tray clock hidden (`HideClock=1`), caret quieted (`CursorBlinkRate=2000000000`),
  Security Center (`wscsvc`) + Automatic Updates (`wuauserv`) disabled. **Two
  no-input frames 3 s apart are byte-identical** (acceptance PASS). The capture does a
  **warm-up reboot** so the AC97 "Found New Hardware" event (the launcher attaches
  `-device AC97`, which the hires boot's device order slots differently) installs and
  clears BEFORE the checkpoint — otherwise the balloon gets captured into the scene.
- **Station:** `streamhost@winxp` (VMID 94, udp 54094, ptr abs / usb-tablet, AC97). The
  launcher (`qemu-streamhost.sh`) gained the `-loadvm golden` conditional (mirroring
  win95/win311) so `systemctl start` comes up straight in the scene; `labctl reset
  winxp` (loadvm golden) restores it. Verified live: streams 1920×1200, autologon →
  Notepad scene, reset clean, abs pointer maps across the full 1920×1200 surface.

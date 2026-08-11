# win98se boot-capture — zero-input prep + detection notes

Reproduction notes for baking a boot video on the **win98se** vmstate tile with
`record-boot.sh` (spec `BOOT-VIDEO-REPLAY-SPEC.md` §3.1/§3.2). Verified end to end on a
`/data/vms/soltest` clone 2026-07-13; the **live win98se tile / golden / service were never
touched**. Model: `win95-zero-input-prep.md` (win98se is win95-like — absolute pointer via
usb-tablet under acpi=on — but its cold-boot needs MORE prep than win95).

## The big win98se-specific gotcha: disks live OUTSIDE the tile dir

Unlike win95 (`DISK="$D/win95-golden.qcow2"` under the tile dir), the win98se launcher
references its disks by **absolute** paths:

```
B=/data/vms/streamhost/stations/win98se
KVM=/data/gallery-guests/Win98SE/win98se-kvm.qcow2      # C:  (1.16 GB, golden vmstate inside)
GAMES=/data/gallery-guests/Win98SE/win98se-games.qcow2  # D:  (391 MB, golden marker inside)
```

`record-boot.sh` rewrites only `$TILE_DIR` → clone dir, so a **naive** run would leave the
clone's `-drive` lines (and therefore `savevm golden`!) pointing at the **LIVE** disks —
catastrophic. Both disks also carry the `golden` VM-state snapshot (spans C:+D:), so both are
part of the device set and both must be present.

**Fix (staging), used here:** point `BOOTREC_TILES_ROOT` at a soltest staging dir holding
COPIES of both disks and a launcher whose `B=`/`KVM=`/`GAMES=` use `$B` so the sed redirects
them into the clone:

```
STAGE=/data/vms/soltest/w98se-bootrec-stage/win98se
cp /data/gallery-guests/Win98SE/win98se-kvm.qcow2   $STAGE/    # cross-dataset => full copy
cp /data/gallery-guests/Win98SE/win98se-games.qcow2 $STAGE/
# staged launcher: sed the live launcher so
#   B=$STAGE   KVM=$B/win98se-kvm.qcow2   GAMES=$B/win98se-games.qcow2
BOOTREC_TILES_ROOT=/data/vms/soltest/w98se-bootrec-stage record-boot.sh win98se --dry-run
```
`--dry-run` + a `diff` of the emitted clone launcher vs the live launcher must show **only**
`B/KVM/GAMES` paths, `LOADVM` neutralise, and `-name …-bootrec` changed — the whole device set
(`-machine pc,acpi=on -cpu pentium3 -vga std -display dbus -audiodev dbus -device sb16 -drive
C:/D: IDE -netdev user -device pcnet -usb -device usb-tablet -qmp -pidfile`) byte-identical.
(`/data/gallery-guests` and `/data/vms` are separate ZFS datasets, so gallery→soltest is a full
copy; the record-boot clone of the staged disk is a same-dataset reflink → instant CoW.)

## Why cold boot ≠ zero-input (FOUR blockers, all seen on the clone framebuffer)

The live golden serves via `loadvm golden` (curated Notepad fixture). `record-boot.sh`
**cold-boots** (no `loadvm`) to film POST → splash → desktop. A cold Win98SE boot of the golden
disk hits, in order:

1. **ScanDisk** — the crash-consistent disk copy boots "dirty" (`AutoScan=1` in `MSDOS.SYS`),
   so ScanDisk auto-runs (~15 s of churn).
2. **A cascade of PnP re-detection wizards** — the golden's on-disk hardware tree does not match
   a cold `acpi=on` enumeration (`golden.env` still reads `acpi=off`; the live tile switched to
   `acpi=on` + `usb-tablet` on 2026-07-12 and re-baked via loadvm/savevm, which NEVER does a
   cold PnP settle on disk). Observed, one Add-New-Hardware-Wizard after another:
   *Plug and Play Monitor*, *Intel 82371SB PCI Bus Master IDE Controller*, and several
   *Unknown Device*s. Installing the real drivers pops a **restart-required** and a transient
   striped-framebuffer display glitch (a display-mode reprobe; recovers on the next clean boot).
3. **"Enter Network Password"** modal (User: `Administrator`, blank pw) over the desktop —
   Primary Network Logon = *Client for Microsoft Networks* (the classic Win9x zero-input killer).
4. **Taskbar clock visible** — the golden hides it via a per-user Explorer setting captured only
   in the snapshot; a cold boot shows the ticking clock (defeats Tier-1 stability + threatens the
   last-frame invariant). NB: win98se golden historically had a taskbar-clock re-encode issue.

## The prep (done on the CLONE's staged qcow2 only), verified by screendump each step

Driven over QMP against the prep VM's own `prep-qmp.sock` (usb-tablet abs clicks via
`input-send-event`; keyboard via HMP `sendkey`), screendumping every step:

1. **Cold-boot** the staged C: (LOADVM forced empty, own qmp/pid/name). ScanDisk auto-completes.
2. **Work every PnP wizard to completion (do NOT Cancel):**
   - *Plug and Play Monitor* → install `C:\WINDOWS\INF\MONITOR.INF`.
   - *Intel 82371SB PCI Bus Master IDE Controller* → install the built-in driver.
   - *Unknown Device*(s) → drive to Finish ("Windows has not installed a driver").
   Accept the **restart** (finalises the drivers; the transient striped display recovers on the
   clean boot — a full power-cycle re-inits QEMU's display cleanly). *Cancelling* a wizard makes it
   re-prompt every boot; *Finishing* records it.
3. **Primary Network Logon → "Windows Logon":** Run → `control netcpl.cpl` → Configuration →
   Primary Network Logon combo → *Windows Logon* → OK. Defer the restart (setting persists on the
   clean shutdown). Persistent fix: with Windows Logon the boot skips the network modal entirely.
4. **Hide the taskbar clock:** Start → Settings → Taskbar & Start Menu… → uncheck **Show clock** →
   OK. Persists to the registry on a clean shutdown → static settled desktop.
5. **Disable the residual driverless device:** Run → `control sysdm.cpl` → Device Manager →
   *Other devices → Unknown Device* (Code 28, no driver — the one that re-prompts every boot) →
   Properties → check **Disable in this hardware profile** → OK. (A separate *VMware Pointing
   Device* under Mouse carries a yellow-! but does NOT pop a boot wizard and the working abs
   pointer is the *HID-compliant mouse*, so it is left as-is.)
6. **Clean Win98 shutdown** (Start → Shut Down → **Shut down** → OK). Win98SE has no ACPI soft-off
   here, so it parks at "It is now safe to turn off"; wait for the disk mtime to quiesce (flush
   done) then kill the prep VM **by pidfile**. Leaves the disk pristine → next cold boot skips
   ScanDisk.
7. **Belt-and-suspenders (offline, `qemu-nbd`):** set `MSDOS.SYS` `AutoScan=1` → **`AutoScan=0`**
   so ScanDisk is skipped even if a boot is ever marked dirty. (WIN.INI `[windows] run=`/`load=`
   are already **empty** — the Notepad fixture lives only in the snapshot, so no cold-boot
   auto-launch; `StartUp\Rain.lnk` (idle-HLT TSR) is benign and left in place.)

## Zero-input result (clone, framebuffer truth)

A fresh cold boot of the prepped disk reaches the **clean, static desktop with ZERO input**:
Win98 splash → desktop (~+30 s, busy) → **settled by ~+45 s**, then **byte-identical screendumps
from +45 s to +90 s** (`v-t45 == v-t60 == v-t75 == v-t90`, md5 `69859923…`). No ScanDisk, no PnP
wizard, no network modal. Settled desktop = **teal background, game icons** (My Computer, Doom95,
My Documents, Duke3d, Internet Explorer, QUAKE, Network Neighborhood, Winamp, Recycle Bin, Opera),
Start taskbar + quick-launch, **tray with NO clock**.

## Detection: Tier-3 fixed settle (~50 s) + Tier-2 region confirm

Two failure modes ruled out on the clone:
- **Tier-1 framebuffer-stability false-settles** on the teal **pre-shell** phase before Explorer
  paints the taskbar/icons (the win95 lesson).
- **Bare Tier-2 Start-button match fires too EARLY** (~+28 s): the Start button appears when the
  shell loads, but the cursor is still a **busy hourglass** until ~+45 s, so the freeze/poster
  lands on the busy-cursor frame (ugly). (This was the first recording; SSIM still passed — the
  invariant holds — but the poster showed an hourglass mid-screen.)

The desktop reaches **full idle (arrow cursor) + byte-static by ~+45 s** (verified 45 s
byte-identical: `v-t45 == v-t60 == v-t75 == v-t90`). So use **Tier-3**: a fixed **50 s** timer lands
the freeze on the fully-idle desktop, then a **Tier-2** crop of the **Start button**
(`crop=56:18:2:458`, present only once the shell is up) against `boot-ref-desktop.png` (K=3)
confirms the shell is up before the bake. The reference PNG (the idle settled-desktop screendump,
arrow cursor at bottom-right — the crop excludes the cursor) lives beside the staged disk; for a
live bake, drop the golden fixture screendump there under that name.

## GOLDEN-CHANGE RISK (for the human go/no-go)

Promoting this cold-boot golden would **replace** the curated live golden. The live golden
(`loadvm golden`) is the **Notepad-focused fixture** (active blue Notepad window, steady caret,
clock hidden). The clean-boot golden staged here is a **bare clean desktop** (no Notepad; teal +
game icons; clock hidden) — AND its on-disk hardware tree/registry is materially changed by the
prep (installed PnP Monitor + Intel 82371SB IDE drivers, a disabled Unknown Device, Windows-Logon,
AutoScan=0). This is a **larger** golden change than win95's (which only flipped the logon + removed
auto-launches). A human must decide whether to (a) promote the clean-desktop cold-boot golden, or
(b) keep the Notepad fixture and instead capture the boot video some other way. This tooling only
records + verifies + STAGES on the clone; it never promotes.

## LIVE promotion (2026-07-13, supervised — DONE)

The clean-desktop cold-boot golden **was promoted** (human go-ahead). Re-baked fresh on a
`/data/vms/soltest` clone (the discovery run's clone had been cleaned up), then swapped live with a
backup + framebuffer gate. The live golden is now the **bare clean desktop** (teal + game icons,
clock hidden) — replacing the Notepad fixture.

### Re-bake + validate (Phase A, on the clone)
- Staged COPIES of BOTH disks under `/data/vms/soltest/w98se-bootrec-stage/win98se` (reflink from
  the live `/data/gallery-guests/Win98SE/`), applied the documented zero-input prep on the staged
  qcow2 via a headless prep VM (`-display none`, own `prep-qmp.sock`/`prep.pid`; usb-tablet abs
  clicks + HMP sendkey, screendump every step): worked every PnP wizard to Finish (2× *Unknown
  Device* → no driver; *Plug and Play Monitor* → `MONITOR.INF`; *Intel 82371SB PCI Bus Master IDE
  Controller* → `MSHDC.INF` + child *Primary IDE controller (dual fifo)*), accepted the restart,
  set Primary Network Logon → **Windows Logon**, unchecked **Show clock**, disabled the residual
  **Unknown Device (Code 28)** in the hardware profile, clean Win98 shutdown, then offline
  `qemu-nbd` byte-patch `MSDOS.SYS` `AutoScan=1`→`0`.
- **Zero-input gate:** a fresh cold boot of the prepped disk reached the clean static desktop with
  ZERO input — framebuffer **byte-identical** across +45/+75/+90 s (md5 `745b9e1c…`): no ScanDisk,
  no PnP wizard, no network modal, no clock. (The transient striped std-VGA reprobe glitch after a
  warm restart/shutdown is host-side only; a fresh cold-boot QEMU renders clean.)
- `record-boot.sh win98se` (staged launcher = live device set, only `B/KVM/GAMES` redirected):
  cold-boot → detect **tier-3 fixed 50 s + tier-2 Start-button confirm** (region-ssim 0.999552 ×3,
  interactive at +53.3 s) → freeze → poster → `savevm golden` (paused) → **verify** `loadvm golden`
  → screendump.
- **M1 seam invariant (the gate):** `poster.png == verify.png` **md5-identical** (`6985992320…`),
  SSIM **1.000000**. Clip **53.60 s** 640×480 H.264 high yuv420p 30fps + AAC 48k stereo,
  `hasAudio: true`, `goldenSha 59901d1e…`, `durationMs 53600`.

### Live promotion (Phase B, gated + reversible)
- **Backup** (both disks carry the vmstate golden — back up BOTH), timestamped `TS=1783974597`:
  - `/data/gallery-guests/Win98SE/win98se-kvm.qcow2.bak-promote-1783974597`   (md5 `d5c8288c…`)
  - `/data/gallery-guests/Win98SE/win98se-games.qcow2.bak-promote-1783974597` (md5 `a98792fa…`)
  - **Rollback:** `systemctl stop streamhost@win98se; kill $(cat /data/vms/streamhost/stations/win98se/qemu.pid);`
    `cp -f …bak-promote-1783974597 → win98se-{kvm,games}.qcow2;`
    `bash /data/vms/streamhost/stations/win98se/qemu-streamhost.sh; systemctl start streamhost@win98se`.
- **Swap:** stop `streamhost@win98se` → kill live QEMU by pidfile → `cp` the validated clone golden
  (BOTH disks) onto the live paths (device set identical → `-loadvm golden` matches) → relaunch the
  live launcher (auto `-loadvm golden`). New live golden md5: C `453c764a…`, D `ebe63954…`.
- **Framebuffer gate (money shot):** post-swap `labctl shot win98se` = the **clean interactive
  desktop** (teal, game icons, tray with **no clock**, no error/login/wizard/ScanDisk/greeter) —
  matches the clip end. Confirmed again via `labctl reset win98se` (`loadvm golden`, the visitor
  path). Then restarted the daemon (healthy: service active, golden=yes).
- **Publish:** `gen-boot-manifest.sh win98se` rsynced `{boot.mp4,poster.jpg,sprite.jpg,thumbs.vtt}`
  → `$WEBROOT/boot/win98se/` and merged `win98se` into `/boot/index.json` (kept amiga+win95+haiku+
  os2warp). Verified: `/boot/win98se/boot.mp4` → **206 `video/mp4`** (`Content-Range …/2597204`);
  `/boot/index.json` keys = `[amiga, win95, haiku, os2warp, win98se]`; `poster.jpg` → 200 image/jpeg.

The SPA `▶Boot` badge/registry flag is wired separately (SPA agent); this work re-bakes the golden
and serves the assets only.

## Startup SOUND re-bake (2026-07-14, supervised — DONE)

The 2026-07-13 promotion's boot clip was **SILENT** (`max_volume −91 dB`). Root cause was NOT an
unmapped event: `HKCU\AppEvents\…\SystemStart` was **already** mapped to *"The Microsoft Sound"*.
The real cause — **the guest had NO audio driver bound to the QEMU `sb16`**:
Control Panel → **Multimedia → Audio** showed *Preferred device: "No Playback Devices"*, and
Device Manager had **no "Sound, video and game controllers" category at all**. Diagnosed by
attaching the dbus tap (`bootrec-tap`) to a prep VM and clicking the Sounds-applet **Preview** —
the tap captured **0 bytes of guest PCM**. (The QEMU `sb16` is a *legacy ISA* device with no PnP
ID, so it is never auto-enumerated → first-boot PnP never offered its driver, and the card sat
undriven since the image was built.)

### The fix — install the Sound Blaster 16 driver in-guest (on the CLONE only)
Headless prep VM off the CURRENT live golden (staged COPIES of BOTH disks under
`/data/vms/soltest/w98snd-stage/win98se`, reflink; own `prep-qmp.sock`/`prep.pid`, cold-boot
forced, full golden device set incl. `-audiodev dbus … -device sb16`; usb-tablet abs clicks + HMP
sendkey via `/root/cdrv.py`, screendump every step):

1. **Control Panel → Add New Hardware** → *No, the device isn't in the list* → *No, I want to
   select from a list* → **Sound, video and game controllers** → manufacturer **Creative** →
   **"Sound Blaster 16 or AWE-32 or compatible"** (the plain SB16 driver — NOT the *Plug and Play*
   variant; QEMU's `sb16` is legacy ISA). Its **factory default resources exactly match** QEMU's
   `sb16`: I/O `0220-022F`, MPU-401 `0330`, OPL `0388`, DMA `1`, DMA16 `5`, IRQ `5` (verified via
   *Details* before committing).
2. File copy prompted for the *"Windows 98 Second Edition CD-ROM"* → point **"Copy files from"** at
   **`C:\WINDOWS\OPTIONS\CABS`** (the base CABs are already on disk, `SourcePath` too — see
   `scripts/build-guests/tiles/win98.sh`). No media needed. → *Windows has finished installing…* → Finish.
3. Accept the shutdown, cold-reboot the prep VM → driver active. The already-mapped *"The Microsoft
   Sound"* now fires on the shell load. **Clean Win98 shutdown**, kill by pidfile → pristine disk.
   (Enabling audio also flips *Show volume control on the taskbar* → a **static speaker icon** now
   sits in the tray; it is bottom-**right**, outside the Tier-2 Start-button crop, so detection is
   unaffected, and `poster == golden` stays md5-identical since both come from the same bake.)

### Sound proof (on the clone, before baking)
A cold boot with the tap capturing audio: **`max_volume −5.7 dB`** (was −91 dB), tap log
`[audio] Init … freq=48000 ch=2` — real SB16 PCM. The startup chime lands **≈ 39.6–47.4 s** (the
shell-load moment). Contrast the pre-fix Preview test: `0 bytes (SILENT)`.

### Re-bake + validate (Phase A, on the clone)
`record-boot.sh win98se` (staged launcher = live device set, only `B/KVM/GAMES` redirected;
`SH_DBUS_TAP=/data/vms/bootrec-build-a97055/target/release/bootrec-tap`): cold-boot → detect
**tier-3 fixed 50 s + tier-2 Start-button confirm** (`crop=56:18:2:458`, region-ssim **1.000000 ×3**,
interactive at **+53.3 s**) → freeze → poster → `savevm golden` (paused) → **verify** `loadvm golden`
→ screendump. **Seam invariant:** `poster == verify` **SSIM 1.000000**. Raw clip 53.6 s,
`max_volume −4.9 dB`. `postprocess-boot.sh` then **`trim-boot.sh`** cut the dead tail
**53.60 s → 49.109 s** (videoSettle 45.7 s, audioEnd 47.418 s → cut 48.6 s; **last frame stays
byte-identical**, md5 `c450449f…`; chime never touched). Delivered: 640×480 H.264 high/yuv420p/30fps
+ AAC 48k stereo, `hasAudio: true`, **`max_volume −4.9 dB`**, `durationMs 49109`,
`goldenSha 3bf629d6…`.

### Live promotion (Phase B, gated + reversible)
- **Backup** BOTH disks, `TS=1783988386`:
  `win98se-{kvm,games}.qcow2.bak-win98se-sound-1783988386` (pre-swap md5 C `81756638…`, D `ebe63954…`).
  **Rollback:** `systemctl stop streamhost@win98se; kill $(cat /data/vms/streamhost/stations/win98se/qemu.pid);`
  `cp -f …bak-win98se-sound-1783988386 → win98se-{kvm,games}.qcow2;`
  `bash /data/vms/streamhost/stations/win98se/qemu-streamhost.sh; systemctl start streamhost@win98se`.
- **Swap:** stop daemon → kill live QEMU by pidfile → `cp --reflink` the validated clone golden
  (BOTH disks) onto live (device set identical → `-loadvm golden` matches) → relaunch. New live
  golden md5: C `65a05c9e…`, D `c7c97b26…`.
- **Framebuffer gate:** post-swap live screendump = the **clean interactive desktop** (teal, game
  icons, tray speaker icon, **no clock**, no error/login/wizard/ScanDisk) — matches the clip end;
  full-frame SSIM **0.997**, Start-button region **0.9989** vs the poster. Daemon restarted (active,
  golden=yes).
- **Publish:** `gen-boot-manifest.sh win98se` → `$WEBROOT/boot/win98se/` + merged `/boot/index.json`
  (kept all: amiga/win95/haiku/os2warp/solaris/winxp/win2000). Verified `/boot/win98se/boot.mp4`
  → **206 `video/mp4`** (`Content-Range …/2388747`); poster 200 image/jpeg; vtt 200 text/vtt;
  index `hasAudio=true durationMs=49109`.

A dedicated `win98se)` arm now lives in `bootrec-tiles.conf` (was the generic Tier-1 group): 640×480,
SB16 dbus audio 48000/2, Tier-3(50 s)+Tier-2 Start-button, BOTH disks in `BR_DISKS`.

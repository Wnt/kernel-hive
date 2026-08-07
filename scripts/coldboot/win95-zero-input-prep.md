# win95 boot-capture — zero-input prep + detection notes

Reproduction notes for baking a boot video on the **win95** vmstate tile with
`record-boot.sh` (spec `BOOT-VIDEO-REPLAY-SPEC.md` §3.1/§3.2). Verified end to end
on a `/data/vms/soltest` clone 2026-07-13; the live tile was never touched.

## Why prep is needed (cold boot ≠ zero-input)

The live golden serves via `loadvm golden` (already at the curated Notepad fixture).
But `record-boot.sh` **cold-boots** (no `loadvm`) to film POST → splash → desktop, and
a cold Win95 boot of `win95-golden.qcow2` does **not** reach the desktop unattended
(GOLDEN.md confirms this). Two blockers, both seen on the clone framebuffer:

1. **`Enter Network Password` modal** (user "Steve Jobs", blank password) — hard block
   at the teal desktop. Caused by **Primary Network Logon = "Client for Microsoft
   Networks"**. Pressing Enter (blank pw) reaches the desktop but that is per-boot input,
   not a disk fix.
2. **ScanDisk** (dirty-shutdown scan) — auto-runs on a crash-consistent disk copy; it
   auto-completes but adds ~15 s of churn and can prompt on errors.

## The prep (done on the CLONE's copied qcow2 only)

Driven over QMP (`tiles/win95/drive.py`), verifying every step by screendump:

1. Cold-boot the copied disk; dismiss the network modal once (Enter, blank pw).
2. **Control Panel → Network → Primary Network Logon → "Windows Logon" → OK → restart.**
   This is the persistent fix: with Windows Logon + the existing blank-password `.PWL`,
   Win95 boots **straight to the desktop, no dialog**. (Verified: a fresh cold boot after
   the change reached the desktop with zero input.)
3. Close any stray folder windows (Win95 OSR2 reopens folders that were open at
   shutdown), leaving the WIN.INI `run=notepad.exe` fixture surface.
4. **Clean Win95 shutdown** (Start → Shut Down → Shut down) → the disk is left clean, so
   the subsequent cold boot in `record-boot.sh` skips ScanDisk.

ScanDisk needs no extra step once the source disk is cleanly shut down; `msdos.sys`
`AutoScan=0` is a belt-and-suspenders alternative if a clean shutdown can't be guaranteed.

Screensaver/DPMS/clock/caret determinism is already baked into the golden (GOLDEN.md):
taskbar **clock hidden** (no per-minute repaint) and caret blink quieted (`NOBLINK.reg`),
so the settled desktop is genuinely static (30 s byte-identical screendumps observed).

## Detection: Tier-1 false-settles → use Tier-2

Tier-1 framebuffer-stability **bakes a blank golden**: after logon the teal background
paints and stays byte-static for >3 s while Explorer is still drawing the shell, so
Tier-1 settles on the **bare teal desktop** (measured: poster == teal, +26 s). Use
**Tier-2 reference-region** (see the `win95)` arm in `bootrec-tiles.conf`): SSIM a crop of
the **Start button** (`crop=56:18:2:458`, present only once the shell is up) against
`boot-ref-desktop.png` for K=3 frames. Result: settled at +36.8 s on the **full desktop**.

`boot-ref-desktop.png` (the settled-desktop reference) lives beside the golden in the
tile dir. For a live bake, drop the golden fixture screendump there under that name.

## Invariant result (clone, framebuffer truth)

`poster == screendump(loadvm golden)` **SSIM 1.000000 (md5-identical)**; the boot.mp4
last decoded frame matches at **SSIM 0.999491 luma** (H.264/yuv420p residual only). Clip
37.2 s, 640×480, H.264+AAC, `hasAudio: true` (the Win95 ta-da chime is captured,
max_volume −2.2 dB).

## CLEAN-DESKTOP bake + LIVE promotion (2026-07-13, supervised — DONE)

The curated live golden ended on **Notepad MAXIMIZED**. For the boot-video feature the
authorised decision was a **bare clean desktop** (icons only: My Computer, DOOM, Duke
Nukem 3D, 3D Pinball, Quake, GTA, SkiFree, …), keeping the Windows-Logon zero-input fix;
the games stay on disk. This was baked on a clone, validated, then swapped live.

### What auto-launches on this image (both removed for the clean desktop)
1. **WIN.INI `[windows] run=notepad.exe`** (per GOLDEN.md) — the Notepad fixture.
2. **`C:\WINDOWS\Start Menu\Programs\StartUp\Rain.lnk`** — a second StartUp auto-launch
   also present on the base FS.

### Clean-desktop prep (offline + GUI, on a `/data/vms/soltest` clone)
1. **OFFLINE (qemu-nbd, reliable):** mount the copied qcow2's C: (vfat `${NBD}p1`), set
   WIN.INI `[windows]` `run=` **empty**, and delete any StartUp `*.lnk`/`*.pif`. (Win9x
   registry is CREG format — no offline Linux editor — so the logon change is GUI, below.)
2. **GUI (QMP `drive.py`, screendump-verified each step):** cold-boot (ScanDisk auto-runs
   on the crash-consistent copy and self-completes; no Notepad launches — confirms step 1),
   dismiss the `Enter Network Password` modal once (Enter, blank pw), then
   **Run → `control netcpl.cpl` → Configuration → Primary Network Logon → "Windows Logon"
   → OK → restart**. Reaching the combo: it is NOT the dialog default (Enter fires the
   **Add…** button), so Tab onto the combo, type `w`, then Tab to **OK** and press **Space**.
   After the restart the guest reaches the **bare clean desktop with zero input**.
3. **Clean Win95 shutdown** (Start → Shut Down → Shut down) so the next cold boot in
   `record-boot.sh` skips ScanDisk.

### Re-recording the clean bake against the prepped disk
`record-boot.sh` clones from `$BOOTREC_TILES_ROOT/<tile>` and its clone-launcher rewrite
`sed`s occurrences of `$TILE_DIR`. To feed it the **prepped** disk without touching live,
stage a dir and point `BOOTREC_TILES_ROOT` at it — **but the staged `qemu-streamhost.sh`
must have its `D=` line redirected to the staged dir**, else the launcher's hardcoded
`D=/data/vms/streamhost/tiles/win95` survives the rewrite and the clone would run on the
LIVE tile. Verify with `record-boot.sh <tile> --dry-run`: the emitted clone launcher's
`D=`/disk/pidfile/qmp must all be under `/data/vms/soltest/bootrec-<tile>-<pid>`.
The existing **win95 Tier-2 arm is unchanged** — the Start-button crop `crop=56:18:2:458`
is identical clean vs. Notepad, so no `bootrec-tiles.conf` edit was needed; capture the
clean settled-desktop screendump as `boot-ref-desktop.png` beside the staged disk.

### Result (clone, framebuffer truth)
`poster == screendump(loadvm golden)` **SSIM 1.000000 (md5-identical)**; settle at +36.7 s
on the **clean desktop** (region-ssim 1.0 ×3, no ScanDisk stall); boot.mp4 last frame vs
poster **SSIM 0.999541**. Clip **37.06 s**, 640×480, H.264+AAC, `hasAudio: true`.
`goldenSha 48edfc63…`.

### Live promotion (gated, reversible)
- **Backup** the live golden to `win95-golden.qcow2.bak-clean-swap-<TS>` (pre-swap md5
  `e621068d…`); the running QEMU is a standalone process (kill by pidfile) — the systemd
  `streamhost@win95` is only the streaming daemon.
- **Swap:** stop daemon → kill QEMU by pidfile → `cp` the validated clone golden onto the
  live path (device set identical, so `-loadvm golden` matches) → relaunch the live
  launcher (auto `-loadvm golden`) → **framebuffer-gate** (screendump = clean desktop,
  game icons, no Notepad/modal/ScanDisk) BEFORE restarting the daemon. Roll back = restore
  the `.bak` and relaunch. New live golden md5 `dd0a377b…`.
- **Publish:** `gen-boot-manifest.sh win95` rsyncs the staged assets to
  `$WEBROOT/boot/win95/` and merge-updates `/boot/index.json` (keeps amiga). Verified:
  `/boot/win95/boot.mp4` → 206 `video/mp4`; index has both amiga + win95.

The SPA `▶Boot` badge/registry flag is wired separately (SPA agent); this work only
re-bakes the golden and serves the assets.

# winxp boot-capture — zero-input prep + startup-sound + detection notes

Reproduction notes for baking a boot video on the **winxp** vmstate tile with
`record-boot.sh` (spec `BOOT-VIDEO-REPLAY-SPEC.md` §3.1/§3.2). Verified end to end
on a `/data/vms/soltest` clone 2026-07-14; the live tile was only touched by the
gated promotion at the end.

## Why prep is needed (cold boot ≠ the served golden)

The live golden serves via `loadvm golden` (RAM+disk snapshot). But `record-boot.sh`
**cold-boots** the disk (the winxp launcher has NO `-loadvm` — it always cold-boots;
the served golden is restored by QMP `loadvm golden` after launch). Two things must be
true for a clean, zero-input, iconic XP boot clip **with** the startup chime:

1. **Zero-input logon** — reach the desktop with no Welcome-screen user pick.
2. **The iconic "Windows XP Startup" chime must be audible** in the clip.
3. **The cold boot must not stall on autochk** (dirty NTFS from a crash-consistent
   `savevm`/kill copy triggers a chkdsk pass).

## What was ALREADY correct in the base golden (verified, no change needed)

Inspected offline via `qemu-nbd` + `ntfs-3g` + `reged`/`hivexregedit`:

- **AutoAdminLogon fully configured** — `HKLM\…\Winlogon`: `AutoAdminLogon="1"`,
  `DefaultUserName="Administrator"`, `DefaultPassword="retro"`, `ForceAutoLogon="1"`,
  `LogonType=0` (classic logon, **no Welcome-screen user list**). Cold boot reaches the
  Administrator desktop with zero input.
- **Startup sound already mapped** — `HKCU\AppEvents\Schemes` active scheme = `.current`
  (the Windows Default scheme, **not** `.None`), with
  `…\Apps\.Default\SystemStart\.Current = %SystemRoot%\media\Windows XP Startup.wav`
  and `…\WindowsLogon\.Current = …\Windows XP Logon Sound.wav`. Both events fire under
  AutoAdminLogon → the clip captures a real settle-time chime (measured
  `max_volume −5.4 dB`, chime ≈ 17.6–21.1 s). No mute in `Run`/`RunOnce`/StartUp
  (the stray `C:\mute.exe` is not auto-run).
- **First-run balloons/tour suppressed** — Security Center + Automatic Updates disabled
  (GOLDEN.md), `HKCU\…\Applets\Tour\RunCount=0`. No balloon/tour on the settled desktop.
- **Idle animation quieted** (GOLDEN.md) — taskbar clock hidden, caret steady, screensaver
  + DPMS off. The settled desktop is byte-static (two screendumps 2 s apart md5-identical).

## The prep actually applied (on the CLONE's copied qcow2 only)

Offline, `qemu-nbd --connect` + `mount -t ntfs-3g` the copied `winxp-golden.qcow2`:

1. **Clean Bliss desktop (win95-style):** delete the `start notepad.exe` line from
   `C:\golden-setup.bat` (the `HKLM\…\Run "GoldenSetup"` logon fixture). The remaining
   `powercfg` lines (never power down monitor/disk/standby) stay. Cold boot now settles on
   the **bare Bliss desktop** — icons only (Recycle Bin, 3D Pinball, DOOM, IE, Minesweeper,
   Quake, Solitaire, Winamp) + taskbar/Start — instead of Notepad-on-Bliss. This is the
   iconic clean XP boot and makes Tier-2 detection deterministic (no Notepad-timing variance).
2. **Skip autochk:** `umount`, then `ntfsfix -d <part>` to **clear the NTFS dirty flag** so
   the subsequent cold boot does not run a chkdsk pass (the win95 "clean shutdown" analogue).
   Re-run after any test boot that re-dirties the disk (a kill-by-pidfile leaves it dirty).

No registry edit was needed for the sound — it was already mapped (above); the boot capture
is the proof it plays.

## Detection: Tier-1 false-settles → use Tier-2 on the Start button

Tier-1 framebuffer-stability **bakes a wallpaper-only golden**: the Bliss wallpaper paints
and stays byte-static for >3 s while Explorer is still drawing the taskbar/tray/icons (same
failure mode as win95's teal desktop), and the XP taskbar keeps animating. Use **Tier-2
reference-region** (`winxp)` arm in `bootrec-tiles.conf`): SSIM a crop of the green **Start
button** (`crop=98:26:0:742`, bottom-left, present ONLY once the shell is up) vs
`boot-ref-desktop.png` for K=3 frames. Structurally distinct from the green grass wallpaper
(measured: region-ssim ≈ 0 during boot, **1.000000** once the Start button is drawn).
Settled at **+21.7 s** on the full clean desktop.

`boot-ref-desktop.png` (the settled clean-desktop screendump) lives beside the golden in the
tile dir. For a live re-bake it is placed at
`/data/vms/streamhost/tiles/winxp/boot-ref-desktop.png`.

## Invariant result (clone, framebuffer truth)

`poster == screendump(loadvm golden)` **SSIM 1.000000 (md5-identical)** — the §1.1 seam is
invisible. Clip **23.28 s**, 1024×768, H.264 (crf18, high/yuv420p, keyint=15, +faststart)
+ AAC, `hasAudio: true`. First frame = black (SeaBIOS); last frame = the clean Bliss golden
desktop. Startup chime `max_volume −5.4 dB` (17.6–21.1 s). `goldenSha 9205336542…`.

### Trim (`trim-boot.sh`) — no-op here (clip already tight)

`record-boot.sh` stops the recorder **at settle**, so the clip has no long dead tail. The
genuinely dead (silent + static) tail is only ≈ 2.2 s (21.1 → 23.3 s), and because the
seam gate requires keeping the **final GOP verbatim** (keyint=15 → 0.5 s GOPs; `kfLast=23.0 s`)
only ≈ 0.5 s is GOP-safely removable — below the tool's `TRIM_MIN_SAVE_S=1.5 s` guard. The
tool correctly **no-ops** (`removable 0.5 s < 1.5 s`), leaving `boot.mp4` untouched with the
chime intact and the last frame byte-identical to the golden. Original == trimmed = 23.28 s.

## LIVE promotion (2026-07-14, gated + reversible — DONE)

The curated live golden ended on **Notepad open**; for the boot-video feature the authorised
decision (win95 precedent) was a **bare clean Bliss desktop**, keeping AutoAdminLogon and the
startup sound; the games/shortcuts stay on disk. Baked on a clone, validated, swapped live.

- **Backup** the live golden to `winxp-golden.qcow2.bak-winxp-sound-<TS>` (pre-swap md5
  `b9882307…`). The running QEMU is a standalone process (kill by pidfile); the systemd
  `streamhost@winxp` is only the streaming daemon.
- **Swap:** stop daemon → kill QEMU by pidfile → `cp --reflink` the validated clone golden
  (fresh `savevm golden` at the clean desktop) onto the live path (device set identical, so
  `-loadvm golden` matches) → relaunch the live launcher (cold) → `loadvm golden` →
  **framebuffer-gate** (screendump = clean Bliss desktop; Start-button region SSIM
  **1.000000**, full-frame 0.998 vs the settled reference; no Notepad/modal/boot-in-progress)
  BEFORE restarting the daemon. Rollback = restore the `.bak`, relaunch, restart. New live
  golden md5 `018a4163…`.
- **Publish:** `WEBROOT=/data/vms/streamhost/serve/webroot gen-boot-manifest.sh winxp` rsyncs
  the staged assets to `$WEBROOT/boot/winxp/` and merge-updates `/boot/index.json` (keeps
  amiga/haiku/os2warp/solariscde/win95/win98se). Verified: `/boot/winxp/boot.mp4` → 206
  `video/mp4` (`Content-Range bytes 0-1023/4822615`); poster 200 `image/jpeg`; vtt 200
  `text/vtt`; index has all 7 tiles.

The SPA `▶Boot` badge/registry flag is wired separately (SPA agent); this work only re-bakes
the golden and serves the assets.

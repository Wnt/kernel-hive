# tru64 — Tru64 UNIX 5.1B on es40 (AlphaServer ES40)

**Status: LIVE AND LISTED (2026-08-16).** `/os/tru64` streams and the
station appears in the grid and museum hall. Every launch is pristine because
the launcher reflink-copies a read-only disk, exactly the w2kalpha shape — and
since the same day it **restores a checkpoint**: the CDE desktop is back
**~3 s after exec** instead of the ~7-10 min cold boot (see
[Checkpoint restore](#checkpoint-restore)). The cold path still exists as the
fallback and still needs no greeter (dtlogin autologin).

## How boot-to-desktop works (mimics w2kalpha)

Three pieces, all baked into the seed:

1. **dtlogin autoLogin.** `/etc/dt/config/Xconfig` carries
   `Dtlogin*autoLogin: root` (plus the display-scoped `Dtlogin*0*autoLogin`).
   The resource is UNDOCUMENTED but real — `strings /usr/dt/bin/dtlogin`
   shows `autoLogin`/`AutoLogin`/`AUTOLOGIN`, and with only the resource set
   dtlogin greets "Welcome root" and then fails with "Login incorrect",
   which is what proved it live.
2. **Passwordless root.** dtlogin's auto-attempt supplies no password, so
   root's hash was cleared in `/etc/passwd` (`root::0:1:…`). The station is
   air-gapped (no NIC in `es40.cfg`), so this is console-only exposure —
   the same trade w2kalpha's blank Administrator makes.
3. **Clean session.** `/etc/dt/config/C/sys.session` is a copy of
   `/usr/dt/config/C/sys.session` minus the `dtfile` and `dthelpview` lines,
   so the desktop comes up bare (front panel only) instead of with a File
   Manager and "Introducing the Desktop" window.

**Seed**: `assets/tru64/img/tru64-seed.img` (8 GiB), lineage = the install
disk `img/tru64.img` after the three changes above and a clean `halt`.
`TRU64_SEED` pins a different one. The launcher never opens it for write.

## Driving this station by hand (what works, what does not)

- **Keyboard only.** `MOVEA`+`DOWN1` clicks do NOT land — the es40 pointer
  needs the seed-polish pass w2kalpha documents. Everything below is
  keyboard.
- **Root shell without a desktop**: restart the station and send Ctrl+C
  repeatedly through the rc phase (`K 1 Left Ctrl` / `K 1 C`); rc aborts into
  **INIT: SINGLE-USER MODE** with a `#` prompt on the console. `mount -a`
  first — `/usr` is not mounted in single-user.
- **Typing symbols**: `uibench/ctltest.py` only emits letters, digits and a
  few punctuation marks, which cannot write a config file. Use
  `/tmp/gtype.py` (this session; source in the job dir) — it maps the full US
  layout onto the key fields the ctlsock accepts. Keep the inter-key delay at
  ~45 ms; faster drops and transposes characters, and a mangled `sed` can
  corrupt a system file.
- **Screenshots**: `uibench/shmread.py <fb.shm> <out.png>`.

## Idle auto-pause and checkpoint restore — the two halves of "instant"

This station is the w2kalpha family, not the QEMU family, and it now gets its
instant feel the same way its sibling does — from two mechanisms that compose:

- **Between visits** the guest stays powered on and SIGSTOPped:
  `SH_IDLE_PAUSE_SECS=60` freezes the emulator at ~0 CPU when no visitor is
  connected, and the next session SIGCONTs it sub-second. Fork `fc82f05`
  (`host_freeze_reanchor`) makes the guest clocks resume where they stopped.
- **On reset (and on every launch)** the launcher restores a checkpoint —
  an es40 savestate baked from the very disk image it reflink-copies — so the
  station reaches the finished CDE desktop in ~3 s instead of ~7-10 min. This
  is what QEMU stations get from `-loadvm golden`; it needed es40 fork
  `a09816d`, which fixed the savestate defects that made restore unusable
  (8514/A accelerator state missing from the state file, host pointers in the
  NIC's saved state, and the ~30 s SRM decompress that every restore
  overwrote). See [`w2kalpha.md`](w2kalpha.md) for the full diagnosis.

`SH_IDLE_PAUSE_WARMUP_SECS` came down from **540 s to 60 s** with the
checkpoint: 540 existed only because a cold boot took ~400-450 s to reach CDE
and a mid-boot freeze would strand an unvisited station part-booted. Verified
2026-08-16: boot/restore completes, then `[idle] no sessions for 60s -> guest
paused` with es40 in state `T` at 0.0 % CPU and the finished desktop in shm.

## Checkpoint restore

`assets/tru64/checkpoint/` holds the pair — `tru64.axp` (es40 savestate),
`tru64.img` (the disk it was baked from) and `rom/` (dpr/flash carry state).
The launcher restores when all of it is present and cold-boots
`img/tru64-seed.img` when it is not, so **deleting the checkpoint directory is
the whole rollback**.

The state and the disk are a PAIR: restoring a memory image onto a disk the
guest kept writing to corrupts the filesystem, which is why the bake exits the
emulator in the same breath as the save.

**Re-bake** — in a namespaced clone under `/data/vms/soltest/`, never on the
live station:

1. Boot the clone (cold from the seed, or restored from the current
   checkpoint if you are amending it) and drive it to the state you want,
   framebuffer-verified.
2. Send a telnet `IAC BREAK` (`\xff\xf3`) on serial0 and answer **5** — "save
   state to autosave.axp and exit". Device threads are stopped for the menu,
   so no guest write can land after the save.
3. Stage `work/img/tru64.img`, `work/autosave.axp` and `work/rom/` as
   `checkpoint/{tru64.img,tru64.axp,rom/}` — write to a temp name and `mv`
   into place so a running es40 never has its mapped image truncated — keeping
   `.bak-<reason>-<date>` copies of what you replace.
4. Restart the station and check the framebuffer: the desktop must come back
   in seconds AND a **new** window must paint in full (open the File Manager
   from the front panel, then `Ctrl+T` for a dtterm — frame, menu bar and
   client area all present, not just the title bar).

A device-set change (`es40.cfg`) orphans the checkpoint — re-bake after one.
Host-side config (serial ports, file paths) does not.

## Driving the desktop by keyboard — the route to a root shell

There is no network in this device set, so the ctlsock keyboard is the only
channel into the running desktop. The route that works:

1. Focus starts on the Front Panel. `Alt+Space` opens ITS window menu (proof
   of where focus is); `Esc` closes it — the key field is `Esc`, not
   `Escape`.
2. `Cursor Down` moves onto the panel's icon row, `Enter` activates the
   focused control. The File Manager control opens `dtfile`.
3. In `dtfile`, **`Ctrl+T` opens a dtterm** — a root shell (`#`), the guest is
   passwordless root.
4. Type into it with `scripts/dev/es40-gtype.py <ctl.sock>` (full US layout;
   `ctltest.py` cannot type `*`, `:` or `/`).

**The screen lock is disabled in the checkpoint** (2026-08-16). CDE ships
`dtsession*saverTimeout: 10` / `dtsession*lockTimeout: 30`, so the live
station used to blank after 10 idle minutes and then sit behind "Display
locked by user root" — a black screen for the next visitor, and the empty root
password did not unlock it from the injected keyboard. The checkpoint's disk
carries `/etc/dt/config/C/sys.resources` (a copy of the CDE default with both
timeouts set to **0**) and was baked from a session started after that change,
so the restored desktop never blanks. **The seed still has the CDE defaults**:
a cold-boot fallback will blank and lock again — re-bake the seed from a
checkpoint-restored, cleanly halted guest to close that.

## Known cosmetic item

The Tru64 `dxconsole` "Console Log" window still opens bottom-right and
shows `Can't find an OSF-BASE … PAK`. It is not started from any
`/usr/dt/config` or `/etc/dt/config` file (grep finds nothing), so silencing
it needs a different hook; the PAK line itself is expected on a PAK-less
base install and gates non-root logins only.

## Not used: es40 savestates

The deployed `assets/tru64/es40` carries a `SAVEST <path>` ctlsock verb added
2026-08-16 (previous binary kept as `es40.prev-b52678995574`) while a
checkpoint route was explored. It is UNUSED: this station boots from a seed
like w2kalpha, whose doc records why restore is avoided (post-restore repaint
fragility). The verb is harmless and left in place for future work.

The research that selected this OS (candidates, media, licensing, risk):
[`docs/lab/research/alpha-second-os-candidates.md`](../lab/research/alpha-second-os-candidates.md).
The sibling station's machinery this one reuses:
[`docs/lab/research/w2kalpha-HANDOFF.md`](../lab/research/w2kalpha-HANDOFF.md).

## Identity

- `osId` = `stationDir` = `tru64`; slot 141, udp 54141; archetype `putty-lcd`.
- The SIBLING of `w2kalpha`: the identical emulated machine (es40 fork
  `Wnt/es40`, AlphaServer ES40, Tsunami, 1× EV68 800 MHz, 512 MB, S3 Trio64,
  sym53c810 SCSI, ALi PS/2, two serial ports) with a DIFFERENT firmware
  lineage: this station's `flash.rom` has **no `arc` nvram autoboot** — SRM
  boots UNIX directly. Do not share `rom/` between the two stations.

## Media (verified this session)

| item | value |
|---|---|
| Source | archive.org item `tru-64-unix-5.1-b`, member `Tru64 UNIX 5.1B - Operating System.iso` extracted from `Tru64 Unix 5.1B.zip` via the single-member download endpoint |
| Staged | `/data/assets-staging/tru64/tru64-os-5.1B.iso` (+ `MANIFEST.sha256`) |
| sha256 | `9d1cbf8c50d6d5d94a2790f52334a0967ee60aa939a08a71b723ecdaf780d96c` |
| Size / label | 676 808 704 bytes, ISO 9660 volume `V5.1Br2650_O1` |
| Class | preservation-archive (contested-commercial, HPE) — same posture class as irix/solaris; never commit the bits |

Associated Products vols 1–2, Patch Kit 4 and firmware v6.8 exist in the same
archive.org ZIP if layered products are ever wanted.

## Acceptance criteria (the release gate for LISTING the station)

- Installed system on `dka0`, booting via SRM `boot dka0` unattended
  (`set bootdef_dev dka0`, `set auto_action boot` in the flashed SRM env).
- **CDE login → CDE desktop on the framebuffer** — settles the PAK question
  (whether a PAK-less base install reaches CDE is the recorded unknown; the
  base OS license `OSF-BASE` is expected on the media, CDE is a base subset).
- Keyboard PASS (already proven at SRM), pointer verified or honestly
  UNVERIFIED with keyboard as the drive channel.
- Checkpoint captured (disk + flash.rom pair), launcher flipped to the w2kalpha
  reflink shape, reset → pristine CDE, then `listing` lifted.

## What is proven so far (all framebuffer evidence, 2026-08-11)

1. **SRM console on shm**: `AlphaServer ES40 Console V7.3-1`, `P00>>>`,
   S3 Trio64 + NCR 53C810 probed. Fresh `flash.rom` created from
   `cl67srmrom.exe` on first start — no firmware-CD flash needed for a
   SRM-only station (ARC/AlphaBIOS is not on the UNIX path at all).
2. **Keyboard over ctlsock**: typed `show device` echoed and executed at the
   SRM prompt. Devices: `DKA0` (8 GiB system disk, shows as RZ58),
   `DKA400` (OS CD, RRD42), `DVA0`, `PKA0`.
3. **`boot dka400` boots the 5.1B kernel from the SCSI CD** with
   `kernel console: s3trio0` — graphics console, not serial.
4. **The X11 installer runs**: 1024×768 language chooser (installer X server
   from the CD), X cursor drawn. This single frame overturns the
   `os-media-catalog.md` "Tru64 = dead-end" verdict (recorded before es40's
   S3 worked).
5. **The whole install ran on the emulated SCSI disk** — labeling, AdvFS
   domain creation, 115-subset load+configure, kernel build — upstream's
   "installation still fails on SCSI disk" README caveat did NOT reproduce
   on fork tip (`e781c20`, base `328b20b`). Wall clock ≈ 2.5 h on a loaded
   host, dominated by the subset load (the installer's own 45–120 min
   estimate held).
6. **First boot + reboot proven**: root/CDE desktop (Front Panel, four
   workspaces, System Setup clipboard), clean `shutdown -h now`, SRM env
   set, and an unattended `auto_action` boot back to the CDE greeter.
   Guest answers baked into the disk: hostname `tru64`, date pinned
   09-01-2003 12:00 EDT (matches the cfg `time` pin), root password in the
   gitignored credential stores (`credentialsRef: guest/tru64`).
   Install-driving technique (dialogs, pointer visual-servo, the `_`/`:`
   TYPE-map gaps) is recorded in the session memory
   `tru64-dark-launch-install`.

## Gotchas (earned here, do not relearn)

- **es40 serial `bind()` was unchecked upstream**: a relaunch that races the
  dying predecessor's listener silently rebinds to a KERNEL-ASSIGNED
  ephemeral port and the guest waits forever for serial clients. Fixed in
  the fork (fail loudly, `FAILURE(Configuration, ...)`); the launcher also
  waits for the old pid to exit and verifies both listeners belong to the
  new es40 before declaring the station up.
- **ctlsock is MULTI-CLIENT since this station's fork build** (`ES40_TILE_NAME`
  names the HELLO banner): the streamhost daemon stays attached while
  `ctltest.py` injects keystrokes beside it. w2kalpha carries the same binary
  since 2026-08-16, so its old single-client caveat is gone too.
- **Guest TOY clock**: the cfg pins `time` (es40 knob) so the installer does
  not start from a "preposterous time" 1996 reset. Set before the install's
  first boot; Tru64 has no timebomb, this is date sanity, not license work.
- The installer waits indefinitely at its dialogs — parking the guest at a
  prompt is free; a `relaunch` reset mid-**setld** (package extraction) is
  the one window where in-place disk mutation could corrupt the target
  filesystem. During the dark phase only the operator holds the URL.

## Runtime shape (install phase)

`streamhost/stations/tru64/{x11-runtime.sh,pumps.py,station.env.fixture}`:
headless es40 (`SDL_VIDEODRIVER=dummy`, `ES40_SHM_PATH`, `ES40_CTL_SOCK`,
`ES40_TILE_NAME=tru64`), serial pair **21974/21975** (w2kalpha owns
21964/21965), `SH_IDLE_PAUSE_SECS=0` (an unwatched SIGSTOP'd installer makes
no progress), reset=relaunch REBOOTS to SRM and re-enters the installer from
whatever the persistent disk holds. Assets:
`/data/vms/streamhost/assets/tru64/{es40,es40.cfg,rom/,img/,root/}` — the
disk `img/tru64.img` is the live install target, deliberately not copied
per launch until the checkpoint exists.

## Rollback

Stop `streamhost@tru64`, remove the station dir + assets, drop the registry
entry (+ UI wiring: keyboardProfiles/machines/machineIdentity), regenerate,
republish the three runtime manifests. The staged ISO under
`/data/assets-staging/tru64/` and this doc stay as the record. w2kalpha is
untouched by any of it (separate assets, rom lineage, serial pair, slot).

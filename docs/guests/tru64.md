# tru64 — Tru64 UNIX 5.1B on es40 (AlphaServer ES40)

**Status: LIVE AND LISTED (2026-08-16).** `/os/tru64` streams and the
station appears in the grid and museum hall. Every launch is pristine because
the launcher reflink-copies a read-only disk, exactly the w2kalpha shape — and
since the same day it **restores a checkpoint**: the 1280x1024 CDE desktop is
back **~3 s after exec** instead of the ~7-10 min cold boot (see
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

## Driving this station: `labctl exec tru64 "<cmd>"`

**Use the exec channel, not the screen.** This machine has no network device,
so exec rides the emulated **com2**: the guest runs a getty on `/dev/tty01`
(`/etc/inittab`, `/etc/securettys`), and the station's `pumps.py` — which must
hold both serial ports from boot anyway, because es40 blocks until they have
clients — lends that line to one client at a time over `serial-exec.sock` in
the station dir. So the address is the station DIRECTORY, not a port, and the
channel survives relaunches.

    labctl exec tru64 "uname -a"          # captured stdout, guest's exit code
    labctl exec tru64 "DISPLAY=:0 xdpyinfo | grep dimensions"

What the client (`streamhost/guest-agents/tru64/tru64exec.py`) does per call:
thaws the guest if idle auto-pause has it SIGSTOPped (a frozen guest answers
nothing, and the pauser can re-freeze it mid-command), converges whatever it
finds on the line back to a fresh `login:`, logs in as root (passwordless),
`exec /bin/ksh` (root's login shell is `/bin/sh`, Tru64's legacy Bourne shell,
which predates `$(...)`), `stty -echo` so the shell's own echo cannot be mistaken for output,
then the command inside a **subshell** between sentinels — a bare `exit 3`
returns 3 rather than killing the session. stdout and stderr come back merged:
it is one serial line.

Two details are load-bearing, both learned the hard way here:

- **Synchronise, never sleep.** After `stty -echo` the client waits for a
  marker it asked the shell to echo. A fixed pause let the next line interleave
  with the previous one still being echoed (`stt# y -echo`), producing a
  corrupted command and no sentinel — intermittently, about one call in three.
- **One retry on a fresh login.** The line is shared with a getty and carries
  state this client did not create; restarting the exchange is the honest
  recovery. Measured after both: 8/8 clean calls, exit codes 0/3/5 preserved,
  including a call issued while the guest was frozen.

**The same relay bakes checkpoints.** A telnet `IAC BREAK` (`\xff\xf3`) written
into `serial-exec.sock` opens es40's serial menu; answer `5` for
save-and-exit. No fifo, no keyboard, no pixels.

### When you must drive the desktop instead

- **Keyboard** over the ctlsock: focus starts on the Front Panel. `Alt+Space`
  opens ITS window menu (which is how you tell where focus is); `Esc` closes it
  — the key field is `Esc`, not `Escape`. `Cursor Down` moves to the icon row,
  `Enter` activates: File Manager, then **`Ctrl+T`** for a dtterm.
- **Pointer** is absolute now (see below), so `MOVEA x y` + `DOWN1`/`UP1`
  presses what is at those coordinates.
- Typing symbols: `scripts/dev/es40-gtype.py <ctl.sock>` maps the full US
  layout; `ctltest.py` only does letters, digits and a little punctuation.
- Screenshots: `uibench/shmread.py <fb.shm> <out.png>`.

## Screen: 1280x1024 (2026-08-17)

The X server takes the mode on its command line, so the site copy of the
dtlogin server file does it:

    /etc/dt/config/Xservers:
      :0   Local local@console /usr/bin/X11/X :0 -screen 1280x1024 -a 1 -t 0

`-screen WxH` is a Tru64 X option (`X -help`, "Device Dependent Usage"), and
`-a 1 -t 0` pins pointer acceleration flat at the server rather than trusting
the session. Depth stays 8 planes — period-correct for CDE, and 1280x1024x8 is
1.25 MB of the emulated S3's VRAM. Restarting X after a change is
`/sbin/init.d/xlogin stop`, kill any surviving `dtlogin`, then `start`; the
station's own reset does it for free by restoring the checkpoint.

## Pointer: absolute and pixel-exact (2026-08-17)

`reset.mouse` is **PASS**. Two things had to be true:

1. **The guest must not accelerate.** X's default was `2/1 threshold 4`; the
   server line pins `1/1 threshold 0`, and `/root/.dt/sessionetc` re-applies
   `xset m 1/1 0` (plus `xset s off` / `-dpms`) at session start, because CDE
   restores its own saved mouse settings over the server flags.
2. **The gain had to be measured, not assumed.** Even with acceleration flat,
   this guest moves **2 screen pixels per injected PS/2 count** — injected
   10/25/50/100/200 moved 20/50/100/200/400, linearly. es40's ctlsock
   dead-reckons an absolute target from injected deltas, so every MOVEA landed
   at twice its delta and the cursor ended up clamped in a corner. The
   launcher now exports **`ES40_POINTER_GAIN=2`** (es40 fork `936760c`), which
   divides the delta and carries the leftover pixel.

Measured after the fix, against the guest's own `XQueryPointer`: exact on even
coordinates, 1 px short on odd ones (a count cannot express one pixel), and a
`MOVEA` + `DOWN1`/`UP1` at a CDE button's coordinates presses that button.

**`xptr` is the measuring instrument** — `/usr/local/bin/xptr` in the guest
prints the true pointer position; it is 6 lines of C compiled in-guest (`cc`
and `libXtst`/`libX11` are present in this install). Use it before believing
any pointer claim here.

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

## Screen lock: disabled in the checkpoint

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

## The scene: a bare CDE desktop

What visitors see is the finished desktop and nothing else — wallpaper and the
front panel. The `dxconsole` "Console Log" window that used to open
bottom-right (repeating `Can't find an OSF-BASE … PAK`) was closed before the
checkpoint was baked 2026-08-17, so the restore no longer brings it back. It
was never started from any `/usr/dt/config` or `/etc/dt/config` file — grep
finds nothing — which is why closing it in the CHECKPOINT was the fix that
worked; a cold boot from the seed still opens it. The PAK line itself is
expected on a PAK-less base install and gates non-root logins only.

## es40 savestates: this station's reset

The station restores an es40 savestate on every launch — see
[Checkpoint restore](#checkpoint-restore). The deployed binary also carries a
`SAVEST <path>` ctlsock verb added 2026-08-16 while the checkpoint route was
being explored; the shipped bake path does not use it (the serial menu's
save-and-exit is what guarantees the state and the disk cannot disagree), and
it is left in place for future work.

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

## Runtime shape

`streamhost/stations/tru64/{x11-runtime.sh,pumps.py,station.env.fixture}`:
headless es40 (`SDL_VIDEODRIVER=dummy`, `ES40_SHM_PATH`, `ES40_CTL_SOCK`,
`ES40_TILE_NAME=tru64`, `ES40_POINTER_GAIN=2`, and `ES40_RESTORE` when a
checkpoint is staged), serial pair **21974/21975** (w2kalpha owns
21964/21965) with ser1 lent out as the exec channel, `SH_IDLE_PAUSE_SECS=60`
with a 60 s warmup, reset=relaunch restoring the checkpoint. Assets:
`/data/vms/streamhost/assets/tru64/{es40,es40.cfg,rom/,img/,checkpoint/,root/}`
— every launch reflink-copies a read-only disk into the station's `work/`, so
`img/tru64-seed.img` and `checkpoint/tru64.img` are never opened for write.

**The install phase is history.** It ran 2026-08-11/12 with the disk mutated
in place, `SH_IDLE_PAUSE_SECS=0`, and reset=relaunch REBOOTING into the
installer; the notes above about parking at installer dialogs and the
mid-`setld` corruption window describe that period, not the exhibit as it
stands.

## Rollback

Stop `streamhost@tru64`, remove the station dir + assets, drop the registry
entry (+ UI wiring: keyboardProfiles/machines/machineIdentity), regenerate,
republish the three runtime manifests. The staged ISO under
`/data/assets-staging/tru64/` and this doc stay as the record. w2kalpha is
untouched by any of it (separate assets, rom lineage, serial pair, slot).

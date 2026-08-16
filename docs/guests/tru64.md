# tru64 — Tru64 UNIX 5.1B on es40 (AlphaServer ES40)

**Status: LIVE AND LISTED (2026-08-16).** `/os/tru64` streams and the
station appears in the grid and museum hall. A cold boot lands on the CDE
desktop with **no greeter** — the Tru64 equivalent of w2kalpha's Windows
autologon — and every launch is pristine because the launcher reflink-copies
a seed disk, exactly the w2kalpha shape.

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

## Idle auto-pause — what "instant" means here (2026-08-16)

This station is the w2kalpha family, not the QEMU family, and the two get
their instant feel differently:

- **QEMU stations** hold a `savevm golden` snapshot inside the qcow2. They
  launch `-loadvm golden -S` (restored, paused) and their reset is a QMP
  `loadvm` — a genuine instant restore, no boot.
- **es40 stations (w2kalpha, tru64)** do not use savestate restore at all
  (see w2kalpha's post-restore repaint fragility). They boot ONCE from the
  seed and then simply stay powered on: `SH_IDLE_PAUSE_SECS=60` SIGSTOPs the
  emulator at ~0 CPU when no visitor is connected, and the next session
  SIGCONTs it sub-second. Fork `fc82f05` (`host_freeze_reanchor`) makes the
  guest clocks resume where they stopped.

tru64 had `SH_IDLE_PAUSE_SECS=0` left over from the install phase, so it
burned a core around the clock and had no resume path. It now carries the
w2kalpha stanza, with one deliberate difference: `SH_IDLE_PAUSE_WARMUP_SECS`
is **540**, not w2kalpha's 120, because this guest needs ~400-450 s to reach
the CDE desktop. A shorter warmup would freeze an unvisited station
mid-boot and the next visitor would sit through the rest of it. Verified
2026-08-16: boot completes, then `[idle] no sessions for 60s -> guest paused`
with es40 in state `T` at 0.0 % CPU and the finished desktop in shm.

**"Restore to golden" still relaunches** on this station — reset mode is
`relaunch` for the whole es40 family (w2kalpha included), so it is a cold
boot, which here costs the full ~7 min rather than w2kalpha's ~80 s. Making
reset instant would need es40 savestate restore (`ES40_RESTORE` exists; a
`SAVEST` ctlsock verb was added 2026-08-16) plus the pairing and repaint
proofs w2kalpha's doc calls out — not done, and not required for the
visitor-facing instant resume above.

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
  `ctltest.py` injects install keystrokes beside it. w2kalpha's binary
  predates this — its single-client caveat still applies there until its
  binary is promoted.
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

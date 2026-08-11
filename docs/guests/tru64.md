# tru64 — Tru64 UNIX 5.1B on es40 (AlphaServer ES40)

**Status: DARK-LAUNCHED, INSTALL COMPLETE (2026-08-11/12) — checkpoint
bake pending.** The station is registered with `listing.state=hidden` —
`/os/tru64` streams, the grid and museum hall do not show it. The full
"All Software" install (115 subsets, AdvFS on dka0) was performed live
over the streamed station and is DONE: the machine SRM-auto-boots
unattended (`auto_action=BOOT`, `bootdef_dev=dka0`) to the CDE login
greeter, and root logs into a full CDE desktop. **The PAK question is
settled: a PAK-less base install boots root into CDE** ("Can't find an
OSF-BASE … PAK" appears in the console log and gates non-root logins
only). Re-install = restore, never re-run: milestone pairs live under
`/data/vms/soltest/TRU64/milestones/` — `m1-installed-frozen-copy/`
(post-install, frozen live copy) and `m2-clean-shutdown/` (cleanly halted
disk+flash+cfg with `MANIFEST.sha256`; **this is the checkpoint-lineage
source**). Remaining: checkpoint bake from m2 + launcher flip to the
w2kalpha reflink shape, fixture/registry rewrite, poster hero swap to the
CDE desktop, lift `listing`.

The research that selected this OS (candidates, media, licensing, risk):
[`docs/lab/research/alpha-second-os-candidates.md`](../lab/research/alpha-second-os-candidates.md).
The sibling station's machinery this one reuses:
[`docs/lab/research/w2kalpha-HANDOFF.md`](../lab/research/w2kalpha-HANDOFF.md).

## Identity

- `osId` = `tileDir` = `tru64`; slot 141, udp 54141; archetype `putty-lcd`.
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

`streamhost/tiles/tru64/{x11-runtime.sh,pumps.py,tile.env.fixture}`:
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

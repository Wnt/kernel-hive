# macos753 — Mac OS 7.5.3 (Quadra 800, m68k)

**Status:** built, checkpointed, wired. Streaming through the daemon is the last
unproven step — see [Blockers](#blockers).

The fleet's **first foreign-architecture QEMU station**. Every other QEMU
station launches `qemu-system-x86_64` or `qemu-system-i386`; the two non-x86
exhibits (`w2kalpha`/`tru64` on es40, `irix` on MAME) reached their architecture
by other means. This one runs `qemu-system-m68k -M q800`.

## Machine

| | |
|---|---|
| Emulator | `qemu-system-m68k` 11.0.2, built from `github.com/Wnt/qemu` @ `kernel-hive` |
| Binary | `/opt/qemu-m68k/bin/qemu-system-m68k` — **not** pve-qemu |
| Machine | `q800` (Macintosh Quadra 800), `-cpu m68040`, 128 MB |
| Acceleration | **TCG only.** There is no KVM path for m68k. |
| Display | `macfb` at **1152x870x8** (the Apple 21-inch mode) |
| Pointer | ADB relative — no absolute path exists on this machine |
| Keyboard | ADB. Command reaches the guest as `meta_l` → ADB `0x37`. |
| Audio | Apple Sound Chip (`asc`) over `-audiodev dbus` |
| Disk | 1900 MB qcow2, single HFS partition, ~29.5 MB used |
| Network | none, deliberately |

### Why not pve-qemu

The fleet package builds `x86_64`, `i386`, `arm` and `aarch64` and **no m68k
target at all**. Adding one would mean rebuilding and reinstalling the `.deb`
that every other station runs, for the benefit of one exhibit. So this station
takes the `nt4` route instead — a standalone build under `/opt/` — and the usual
objection does not apply: an upstream binary cannot `loadvm` a checkpoint
carrying pve's `pbs-state` vmstate section, but this station's checkpoint is
baked *and* restored by this binary and never contains that section.

## Media

Both artifacts are preservation-class, staged on labhost, **never committed**.
Recorded in [`ASSETS-MANIFEST.md`](../lab/ASSETS-MANIFEST.md).

| Artifact | Source | sha256 |
|---|---|---|
| `800.ROM` (1 MiB) | archive.org `800_20250604` | `05ad753f…6b09ca` |
| `System753 691-1079-A.iso` (268 MB) | archive.org `Macintosh-68K-PPC-System-7.5.3-Bootable-ISO` (Apple part 691-1079-A) | zip `b65d41bd…9e19dc` |

## Device set, and the two flags that are load-bearing

```
-M q800,audiodev=snd0 -cpu m68040 -m 128
-bios .../800.ROM -g 1152x870x8
-display dbus,p2p=on,audiodev=snd0
-audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16
-drive file=pram-golden.qcow2,format=qcow2,if=mtd
-device scsi-hd,scsi-id=6,drive=hd0
-drive file=macos753-golden.qcow2,format=qcow2,cache=writeback,aio=threads,if=none,id=hd0
```

- **`audiodev=snd0` on `-M` is required.** The Apple Sound Chip is part of the
  machine and QEMU exits with `Initializing audio stream failed` without it.
  This station cannot be made silent by removing the audio device.
- **The PRAM must be qcow2.** As a raw `if=mtd` drive it makes `savevm` refuse
  outright — `Device 'mtd0' is writable but does not support snapshots` — which
  takes the entire checkpoint plane with it. The PRAM is also fixture state, not
  scratch: it carries the boot device (offset 120) and the mouse-tracking
  setting the pointer calibration depends on.

## Checkpoint

`resetMode: loadvm`, snapshot `golden`. Measured on the production device set:

| | |
|---|---|
| `savevm golden` | 0.5 s, 130 MiB vmstate |
| `loadvm golden` | **0.32 s** |
| Restore proof | window opened = 86 357 px differ; after restore **0 px** differ |

The scene is a quiet Finder desktop: `Macintosh HD` top-right, empty Trash
bottom-right, no window open, nothing selected.

**Baked into the checkpoint, and none of it cosmetic:**

- **Mouse tracking = "Very Slow".** The only *non-accelerated* setting Mac OS
  offers. Under any other setting 1:1 pointing is unreachable by construction,
  because the OS is applying a curve.
- **Double-click speed = slowest**, which widens the window a click pair has to
  land in over a video stream.
- **32-bit addressing ON.** It defaults **off**, which caps usable memory at
  8 MB of the 128 installed.
- **Disk cache 32K → 7680K**, which matters more than usual because every
  emulated SCSI transaction is TCG work.

## Pointer

`SH_INPUT_BACKEND=dbus-rel`, `SH_CURSOR_SCALE=2.7778`.

The guest moves **exactly 0.36 px per delta unit** — measured on the
framebuffer, linear, and identical at every send chunk size from 1 to 32 units
(1000 → 360 px, 1500 → 540, 2000 → 720, 3000 → 1079). `cursor_scale` is that
factor's reciprocal. Re-measure with:

```bash
scripts/install-vision/adb_pointer.py --qmp <CLONE>/qmp.sock gain
```

**This station is why `HOME_PIN` is now scaled by `cursor_scale`.** The daemon's
corner-slam was a fixed 2048 units, documented as "exceeds the largest guest
surface we drive" — a pixel claim about a value sent in guest units, which
silently assumes gain 1.0. At 0.36 it travels 737 px and cannot cross this
station's 1152 px screen, leaving the cursor stranded while the daemon's model
believed it was pinned at 0,0.

## Driving the guest (clone only)

System 7.5.3 has **no shell, no telnet, no serial console**. The framebuffer is
the only observation surface and the pointer is the only control surface, so
there is no `labctl exec` for this station and there never will be. Use
`scripts/install-vision/adb_pointer.py`, which encodes what works:

- **Double-clicks are unreliable** over an emulated ADB mouse — select, then
  **Command-O** (`pointer open X Y`).
- **Targeting must be closed-loop.** Slam to a known origin, then correct
  against the framebuffer.
- **Menus need the button held** (`pointer menu TX TY IX IY`); a click-release
  on the title leaves nothing for a screendump to catch.
- **Drops carry a ~(+31,+11) grab offset** (`pointer drag ... --onto`). Three
  drags "failed" before this was measured — they had actually succeeded, one
  icon-width to the right of the Trash.
- **QMP `system_reset` hangs the q800.** A guest-initiated `Special → Restart`
  works; otherwise relaunch the process.

## Rebuild

```bash
scripts/build-guests/tiles/macos753.sh --all      # or a single --phase
```

The builder encodes the whole recipe, including the disk trick that avoids a
four-hour surface verify: initialize a **300 MB** disk (~4 min) purely to get the
`Apple_Driver43` boot partition, grow the image to 1900 MB, extend the Apple
Partition Map host-side, then let Finder's *instant* Erase Disk lay HFS across
all of it. Patch images through `qemu-nbd`; `qemu-img dd` writes a **raw** image
and destroys a qcow2 header.

## Blockers

1. **Never streamed.** Every frame verified so far came from QMP `screendump`.
   Capture, audio and input through the daemon are unproven, and with them the
   XT set1 → qcode → ADB keyboard path (Command and Option arrive from a browser
   as Meta and Alt).
2. **Idle auto-pause unproven across a TCG guest.** Declared
   (`SH_IDLE_PAUSE_SECS=60`) and the launcher starts paused, but not observed.
3. **No interactive latency number yet.** TCG latency is a finding about the
   *tier*, and it should be measured before HP-UX/SunOS are planned on this
   pattern.
4. **Cosmetic:** an empty `untitled folder` inside the System Folder, from a
   stray Command-N while hand-driving. Invisible to visitors; the builder does
   not create it.

## Rollback

The station is additive: a new `stationDir`, a new slot, a new `/opt/` binary.
Nothing existing shares any of them. To remove it, disable the registry entry
and regenerate; to revert the checkpoint alone, `loadvm golden` is idempotent
and the pre-change `macos753-golden.qcow2` should be kept until repeated cold
boots and restores have passed.

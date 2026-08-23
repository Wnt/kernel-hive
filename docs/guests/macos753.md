# macos753 — Mac OS 7.5.3 (Quadra 800, m68k)

**Status:** LIVE. Built, checkpointed, wired, deployed and streaming; the
station serves on udp/54142 and its reset endpoint restores the checkpoint.
**On the retronet web plane since 2026-08-23** — see
[`../lab/retronet/WEB-STATION-macos753.md`](../lab/retronet/WEB-STATION-macos753.md).

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
| Network | **`dp83932` (SONIC), on the retronet bridge `vmbr-rn` at `10.99.0.23`** (2026-08-23) |

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

**The vmstate is in the PRAM image, not the disk.** QEMU writes it to the first
snapshot-capable drive, and on this machine that is the 256-byte PRAM. The two
qcow2 files are therefore one unit: back up or clone `macos753-golden.qcow2`
alone and you have a `golden` tag with no machine state behind it.

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

## Networking — MacTCP, and four facts that mislead

The station joined the retronet on 2026-08-23. The bridge as-built is in
[`WEB-STATION-macos753.md`](../lab/retronet/WEB-STATION-macos753.md); these are
the *guest* facts, which are true of Mac OS 7.5.3 on this machine regardless of
what it is plugged into.

- **The NIC is not a choice.** `-M q800 -nic model=help` offers exactly one
  model, `dp8393x` (aka `dp83932`) — the SONIC the real Quadra 800 had on its
  logic board. Mac OS 7.5.3 drives it with **nothing installed**: MacTCP lists
  `Ethernet` beside `LocalTalk` on the first cold boot with the card present.
- **MacTCP 2.0.6 has no DHCP client.** Its "Obtain Address" choices are
  **Manually**, **Server** (BOOTP/RARP — the 1993 mechanism) and **Dynamically**.
  There is no DHCP anywhere in it, so this guest is addressed statically. MacTCP
  stores its settings in the **`MacTCP Prep`** file in the System Folder — on the
  **disk**, not in PRAM — so they survive a cold boot and are bakeable, and every
  change demands a guest restart (MacTCP says so itself in an alert).
- **MacTCP is dormant until an application opens it.** With no TCP/IP app
  running the stack is inactive and the guest emits nothing at all — not even an
  ARP reply, so it does not answer ping. **Silence on the wire is the resting
  state**, never evidence of a broken NIC.
- **MacTCP does not survive a force-quit** of an application holding it open: the
  next app to start hangs forever on its first name lookup with nothing on the
  wire. Only a guest restart clears it.

### Two checkpoint settings that are NOT on the disk

Cold-booting this guest (which a device-set change forces) revealed that two of
the settings the checkpoint records lived only in the **checkpoint's RAM state**
and were never written to disk or PRAM. A cold boot brings back the defaults:

- **32-bit addressing OFF**, capping usable RAM at 8 MB of the 128 installed;
- **disk cache back to 32K**, not the 7680K the fixture records.

Both are in the **Memory** control panel and both need a restart. Any future cold
re-bake of this station must re-apply them, or the guest comes up with 5.9 MB
free and most period software will not launch at all.

### Browsers

**Netscape Navigator 3.04 (68K)** is installed (`Macintosh HD:Netscape
Navigator™ Folder:`) and renders the museum corpus. Two things it needs, both
learned the hard way:

- **Raise its memory partition** — Get Info → Preferred size **24000K**. At the
  9000K default it dies at launch with a **type 16** (floating-point) or
  **type 1** (bus) error, which is classic-Mac heap exhaustion, not an FPU fault.
- Even at 24000K it is **intermittently unstable** on this emulated 68040 —
  some launches hang spinning with a blank window. It is the best renderer
  available for this guest and it does work, but it is not reliable.

**MacWeb 2.0** is also installed and is far lighter, but it sends **no `Host:`
header**, so it cannot use the retronet's `:80` origin at all (the origin answers
`400`); it would need the `:3128` forward proxy. The copy sourced is the French
build.

### Getting files into this guest

It has no shell, no telnet, no serial console — and, before the NIC, no network.
Files go in **offline** with `hfsutils` against a raw copy of the disk:
`qemu-img convert` to raw → `hmount` → `hcopy -b` (BinHex `.hqx`) or `hcopy -m`
(MacBinary `.bin`) → `humount` → convert back to qcow2. **The resource fork is
the whole point** — a classic Mac application *is* its resource fork, so a plain
`.zip` of one is useless. The proof it worked is the file appearing in the Finder
with its real icon.

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

## Proven live (2026-08-16)

| Check | Result |
|---|---|
| Capture | `first frame 1152x870 (shm=true)`; x264 encoder up at 1152x870 |
| Audio | dbus `AudioOutListener` registered, Opus @96k, `Init bits=16 freq=48000 ch=2` — the Apple Sound Chip reaches the daemon |
| Signaling | `/signal/macos753.json` → 200, udpPort 54142, cert hash present |
| Framebuffer | `labctl shot macos753` = the checkpoint scene |
| Reset endpoint | `POST /restore/macos753` → 200, `loadvm golden on macos753: OK` |
| **Idle auto-pause** | guest **paused** with no visitor, **0.50 % of one core** measured over 20 s |

The idle result is the one that matters most for this station: m68k is TCG-only,
so an unpaused idle exhibit would burn a real core continuously. It does not.

## Blockers

1. **Pointer and keyboard are UNVERIFIED through a browser** — deliberately, and
   the registry says so. The daemon only injects while a client is connected, so
   1:1 pointing and the XT set1 → qcode → ADB keyboard path (Command and Option
   arrive from a browser as Meta and Alt) are an operator eyeball pass. The
   `classicmac` on-screen keyboard profile exists for exactly that reason.
2. **No interactive latency number yet.** TCG latency is a finding about the
   *tier*, and it should be measured before HP-UX/SunOS are planned on this
   pattern.
3. **Cosmetic:** an empty `untitled folder` inside the System Folder, from a
   stray Command-N while hand-driving. Invisible to visitors; the builder does
   not create it.

## Rollback

The station is additive: a new `stationDir`, a new slot, a new `/opt/` binary.
Nothing existing shares any of them. To remove it, disable the registry entry
and regenerate; to revert the checkpoint alone, `loadvm golden` is idempotent
and the pre-change `macos753-golden.qcow2` should be kept until repeated cold
boots and restores have passed.

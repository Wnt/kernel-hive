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

## Pointer — an absolute WRITE into Mac OS's own globals

`SH_INPUT_BACKEND=ramabs`, `SH_RAMABS_SOCK=<dir>/ptr.sock`, and the launcher's

```
-chardev socket,id=ptr0,path=$D/ptr.sock,server=on,wait=off
-global nubus-macfb.ptrctl=ptr0
```

plus `-global nubus-macfb.ptr-trace=${PTR_TRACE:-off}` for the engine-side trace.

**The type name is `nubus-macfb`, and getting it wrong fails silently.** `-M
q800` instantiates `TYPE_NUBUS_MACFB` (`hw/m68k/q800.c`), not `TYPE_MACFB`
(`"sysbus-macfb"`). QEMU does not warn about a `-global` naming a type it never
instantiated — it just does nothing, the chardev stays `frontend-open: false`,
no HELLO is ever sent, and the only symptom is a pointer that never moves. The
opposite mistake is loud: `ptrctl` on a binary that predates the engine is an
unknown *property* and QEMU refuses to start. The engine itself is
`streamhost/qemu-patches/0007-macfb-ramabs-absolute-pointer.patch`, and its
banner is exactly `HELLO ramabs/1 caps=movea,btn,sync,stat surf=1152x870`.

**This is not a closed loop, and calling it one would mislead every future
reader.** `aix432` and `irix` converge on a HARDWARE CURSOR register. The
Quadra 800 has no hardware cursor at all: classic Mac OS composites the sprite
in software, so there is nothing to read. What there *is* is Mac OS's own
pointer state in LOW MEMORY, and the emulator can both read and write it. So
the engine states the answer instead of hunting for it.

### The mechanism, exactly

Per `MOVEA x y` the engine:

1. writes the target into **`MTemp` ($0828)** and **`RawMouse` ($082C)**;
2. sets **`CrsrNew` ($08CE) := `CrsrCouple` ($08CF)** — the publish barrier;
3. Mac OS's own cursor VBL task notices, moves the pointer, and states where it
   landed in **`Mouse` ($0830)**;
4. the MOVEA acks when `Mouse` reads back **== the target**.

Both `Point`s are **two signed BIG-ENDIAN int16, VERTICAL first, then
horizontal** — `(v,h)`, the opposite order from the `(x,y)` the rest of the
fleet speaks. Get that backwards and the cursor moves to the transposed point,
which looks like a scaling bug and is not one.

### THE TRAP: never write `Mouse` ($0830)

This is the single most important line on this page. `Mouse` is the cursor VBL
task's **OUTPUT**, and it is the task's own change detector: it moves the
pointer when `RawMouse` differs from `Mouse`. Pre-write `Mouse` to the target
"to help", and the task sees no change, does nothing, and **the cursor silently
does not move** — no error, no log, no partial motion. Proven empirically
against a sandbox clone restored from the golden. `Mouse` is a sensor. Write
`MTemp` and `RawMouse`; read `Mouse`.

### Why the aix432 "magnet" cannot happen here

`Mouse` holds the **POINTER**, not a sprite origin, so the hotspot never enters
the control path — there is no `reading = pointer - hotspot` to get wrong, and
therefore no guessed-hotspot magnet (`docs/guests/aix432.md`). The hotspot is
still available when something needs it: it is read **live** from `TheCrsr`+64
= **$0884** (reads `h=1,v=1` for the arrow), never measured by a screen clamp.

Two more measured facts from the same probe session (2026-08-30, QMP
`pmemsave` against a sandbox clone restored from the golden):

- **`CrsrPin` ($0834)** reads exactly `l=0, t=0, r=1152, b=870` — the clamp
  matches the surface, so no target inside the surface is out of reach.
- sprite origin == `Mouse` − hotspot, confirmed against
  `scripts/dev/cursor-locate.py` on QMP screendumps at several targets.

The addresses, the layout and **which golden they were derived against** are
recorded machine-visibly in `registry/stations/macos753.json` under
`stream.pointer.guestState`, because they are per-station: the other station on
this method (`rhapsody`) uses a `Point{int16 x, int16 y}` — the opposite field
order — which is exactly why none of this lives in the daemon or the wire.

### What stays on the ADB mouse

Buttons. The emulated ADB mouse remains in the machine and carries `DOWN1`/`UP1`
as **button-only edges** (no motion). `DOWN2/UP2/DOWN3/UP3` are accepted and
acked as no-ops — the Mac has one button, and the daemon's reconnect resync
preamble always sends all three releases.

**Single injector (BINDING).** While the socket is connected the engine owns the
guest pointer: no `rel_bridge`, no QMP `input-send-event`, no
`adb_pointer.py` against the LIVE station dir.

### No golden re-bake

A `-chardev` is not a guest device, and the `-global` sets a property on the
`macfb` the `q800` machine already instantiates. The **guest-visible device set
is unchanged**, so `loadvm golden` still binds, and the engine registers no
migration state. Install order is binding in both directions: QEMU binary
before the launcher (`-global nubus-macfb.ptrctl=` is an unknown property on an
older binary and QEMU refuses to start), streamhost binary before the env
fixture (`SH_INPUT_BACKEND=ramabs` panics an older daemon at startup).

### Proven on the framebuffer (rule 9)

Bring-up evidence, 2026-08-30, on a sandbox clone restored from the golden:
**14 targets, three independent observers each** — what the daemon commanded,
what the guest's own `Mouse` global read back, and what
`scripts/dev/cursor-locate.py` found in a QMP screendump — **all 14 agreeing
exactly**, including four screen edges and five window-frame targets (the
glyph-swap territory that produced the aix432 magnet). Plus: a double-click that
opened the Macintosh HD window (85 255 pixels repainted), clamping proven in
both directions (`5000,5000` → `1151,869`, `-400,-400` → `0,0`), and 5 s at rest
with **zero** additional MOVEAs and **zero** re-aims.

### Two live-fleet inaccuracies found while doing this, recorded not fixed

**1. `SH_REL_HOME_TO=599,500` in the fixture is WRONG.** The golden's actual
baked cursor position is **(15,15)** — read 2026-08-30 from the restored
vmstate via QMP `pmemsave` of the `Mouse` global at `$0830` **before `cont`**.
The 599,500 value was measured 2026-08-18 as "dead-centre of the desktop"; the
golden was then **COLD re-baked 2026-08-23/24** for the SONIC NIC and the
constant was never re-measured. It is deliberately **left wrong**: under
`ramabs` nothing reads it, and retiring the relative scaffolding
(`SH_CURSOR_SCALE`, `SH_REL_HOME_ON`, `SH_REL_HOME_TO`, and the checkpoint's
"Very Slow" mouse tracking) is a separate, later commit so that rolling back one
change cannot strand the other. **If `dbus-rel` is ever rolled back to, fix this
first** — a re-home to 599,500 seeds the bridge's model ~585 px away from the
guest's real cursor.

**2. `cursor-locate.py learn` needs `--at` on this station.** A plain two-frame
`learn` drowns in the Mac desktop's 50% dither: it yields a degenerate template
that matches everywhere, and `find` reports AMBIGUOUS at *thousands* of
positions. The working invocation pins the origin and the box:

```bash
scripts/dev/cursor-locate.py learn a.ppm b.ppm --at X,Y --size 16
```

### The relative path this replaced (kept for rollback)

Rollback is two lines: drop the `-chardev`/`-global` pair from the launcher and
set `SH_INPUT_BACKEND=dbus-rel` in the fixture. Everything below still applies
under it, and the fixture still carries the constants.

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

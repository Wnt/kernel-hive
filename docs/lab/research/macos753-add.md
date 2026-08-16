# Add Classic Mac OS 7.5.3 — plan (native m68k `q800`)

Plan for [`Wnt/osgallery#26`](https://github.com/Wnt/osgallery/issues/26), the
predecessor repo's exhibit request. Follow
[`ADD-NEW-OS-PLAYBOOK.md`](../ADD-NEW-OS-PLAYBOOK.md) for anything this file
does not contradict; the phases below map onto its sections.

**The tracking issue stays on the predecessor repo.** Nothing is mirrored here;
the acceptance criteria are restated in current terms in the last section, and
this file is the working contract.

## Decisions (operator, 2026-08-16)

| Question | Decision |
|---|---|
| Which version | **7.5.3**, outright. Not 7.1, and no fallback dance. |
| Station id | **`macos753`** — id == `stationDir` == `SH_STATION`, and the name must not lie about the version. Slot **142**, udpPort **54142** (next after `tru64` at 141). |
| Autonomy | Build, install, bake, wire, deploy **live**, green gate, merge to `main`. |
| Pointer calibration | Ship `scale 1.0` with linear mouse tracking baked into the checkpoint; operator eyeballs and re-calibrates later if it is not 1:1. **Superseded by measurement** — the gain turned out to be cleanly measurable from the framebuffer, so the station ships `2.7778` instead of an unverified 1.0. |

## What is actually new here

The issue frames this as a routine native-QEMU exhibit. It is not: **the whole
fleet launches only `qemu-system-x86_64` (47 call sites) and `qemu-system-i386`
(3). There is no foreign-architecture QEMU station today.** The two non-x86
exhibits reached their architecture by other means — `w2kalpha`/`tru64` run the
`es40` Alpha emulator, `irix` runs MAME. So the first deliverable is not a
station, it is a **build**: a working `qemu-system-m68k` that still carries the
kernel-hive fork's own patches.

## Phase 1 — build `qemu-system-m68k` from the kernel-hive fork — **DONE**

Built 2026-08-16 on labhost from `github.com/Wnt/qemu` @ `kernel-hive`
(`73f67ff`), QEMU **11.0.2** — the same upstream version as the installed
`pve-qemu-kvm 11.0.2-1`.

```sh
../configure --target-list=m68k-softmmu --enable-slirp --enable-dbus-display \
  --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-spice \
  --disable-opengl --disable-werror --disable-tools --prefix=/opt/qemu-m68k
ninja qemu-system-m68k
```

**Answers to the questions this phase existed to ask:**

- **Do the fork's patches survive on a non-x86 target?** Yes, and the question
  was mis-framed. `0001-dbus-display-fast-poll` touches only `ui/console.c` and
  `ui/dbus-listener.c` — both arch-neutral. Verified in the binary:
  `SH_DBUS_UPDATE_MS` and `SH_DBUS_TRACE` are present.
- **Is there an x86/PS2 assumption in "the fastpoll input path"?** There is no
  such thing — fast-poll is a *display* patch. The low-latency **input** device
  is `gallery-hid-pci`, which is PCI and therefore simply unavailable on q800
  (no PCI bus). It is also not needed: the generic dbus `Mouse.RelMotion` path
  drives the ADB mouse.
- **Does dbus scan out the q800 framebuffer, and at what geometry?** Yes.
  QMP `screendump` off a ROM-only boot returned a live `P6 640 480` frame with
  the arrow cursor drawn. The geometry is **not** fixed as assumed — `macfb`
  accepts `640x480` / `800x600` at depth 1,2,4,8,24 and `1152x870` at depth
  1,2,4,8, selected with `-g WxHxD`.
- **Packaging.** Standalone build under `/opt/`, **not** a `pve-qemu-kvm` .deb
  rebuild. Precedent: `nt4` already runs `/opt/qemu-cirrusfix2/bin/qemu-system-i386`
  (`streamhost/stations/nt4/qemu-streamhost.sh:62`). The `pbs-state` objection in
  `qemu-patches/README.md` only bites when a **pve-baked** checkpoint is loaded by an
  upstream binary; a checkpoint baked by this binary and loaded by this binary is
  self-consistent, and a fleet-wide .deb swap for one station is not a trade
  worth making.

**Also settled here — can q800 `savevm` at all?** This was the unstated risk
that could have killed the exhibit, since the whole checkpoint/reset plane is
`savevm`/`loadvm`. `target/m68k/cpu.c` carries `vmstate_m68k_cpu`, and `macfb`,
`mac_via`, `q800-glue`, `esp`, `dp8393x`, `swim`, `asc`, `adb-kbd` and
`adb-mouse` all carry a `VMStateDescription`. Proven in practice at Phase 3.

## Phase 2 — media (agent-sourced) — **DONE**

Staged on labhost, hashed, never committed. Provenance for
`ASSETS-MANIFEST.md`, class **preservation-source**:

| Artifact | Source | sha256 |
|---|---|---|
| `800.ROM` (1 MiB, Quadra 800) | archive.org item `800_20250604` | `05ad753f…6b09ca` (md5 `69489153dde910a69d5ae6de5dd65323`) |
| `System753 691-1079-A.iso` (268 MB) | archive.org `Macintosh-68K-PPC-System-7.5.3-Bootable-ISO`, Apple part **691-1079-A** | zip `b65d41bd…9e19dc` |
| `macos753-retail.toast` (268 MB) | archive.org `96073-016AU…_CD` (retail 96073-016A) | `ab3382fe…9e3b5d` — held as the fallback image |

## Phase 3 — install — **DONE** (7.5.3 boots from disk to the Finder)

Reference automation worth reading first: `matthewdeaves/QemuMac` (cloned to
the build dir). Corrections it forces on the recipe originally planned here:

- **`-boot d` does nothing on q800.** Boot device selection is a **PRAM patch**:
  write `ffff` + `~(scsi_id + 32)` as two big-endian bytes at offset **120** of
  the PRAM image.
- **SCSI IDs are HD=6, CD=3**, not HD=0.
- **The machine needs an audiodev or it refuses to start** — the Apple Sound
  Chip is not optional. `-M q800,audiodev=audio0 -audiodev …,id=audio0`.
  (Hit this for real: `Initializing audio stream failed`.)

### The disk, and the four-hour trap

Apple HD SC Setup's **surface verify runs at ~145 KB/s under TCG** and scales
with the **whole drive**, not the partition: a 2 GB image would have taken
~4 hours. And its `Initialize` default is **"Minimum Macintosh"** — on a 300 MB
drive that is a **19 MB** volume, which the installer then rejects for want of
space. `Partition → Maximum Macintosh` reported success and changed nothing.

The recipe that works, and is what the build script should do:

1. `qemu-img create -f qcow2 disk.qcow2 300M` — small **on purpose**.
2. GUI-drive HD SC Setup `Initialize` (~4 min at this size). This writes the
   `Apple_Driver43` partition, which is the boot driver the ROM needs and the
   only reason HD SC Setup is involved at all.
3. Guest `Shut Down`, then **`qemu-img resize disk.qcow2 1900M`**.
4. Rewrite the Apple Partition Map host-side so the single `Apple_HFS`
   partition spans the grown drive: update `sbBlkCount` in the block-0 driver
   descriptor, `pmPartBlkCnt` + `pmDataCnt` in the HFS entry, zero the
   `Apple_Free` entry, drop `pmMapBlkCnt` to 3.
5. Boot, `Special → Erase Disk`. Finder's erase is **instant** — no surface
   scan — and lays HFS across the whole 1900 MB.

**Use `qemu-nbd`, never `qemu-img dd`, to patch the image.** `qemu-img dd`
writes a **raw** output image; pointing it at a qcow2 destroys the header. That
mistake cost one rebuild here.

1900 MB keeps the boot partition under the 2 GB limit with room for apps and
games. The Easy Install itself is only **29.5 MB**.

### Checkpoint scene

A quiet Finder desktop at 1152x870: `Macintosh HD` top-right, empty Trash
bottom-right, no open windows, no menu pulled down.

Two things baked in before capture:

- **Mouse control panel → "Very Slow" tracking.** It is the only **linear**
  setting; every other one applies Mac OS's acceleration curve, under which 1:1
  is unreachable by construction. Double-click speed set to its slowest, which
  widens the window a click pair has to land in over a video stream.
- Desktop icon layout, since icon positions were saved against 640x480 and land
  mid-screen after the mode change.

Known cosmetic debt: an empty `untitled folder` inside the System Folder, from
a stray Cmd-N while hand-driving. Invisible to visitors; the build script will
not create it.

### Driving the Finder from QMP — what actually works

- **Double-clicks are unreliable** over the emulated ADB mouse. Select, then
  **Command-O**. (Command maps correctly: `meta_l` → ADB `0x37`.)
- **Absolute targeting must be closed-loop.** Slam to a known origin, then
  correct against the framebuffer; open-loop deltas land short.
- **Menus need the button held.** A click-release on the title leaves nothing
  for a screendump to catch; press, walk closed-loop to the item, release.
- **Drops carry a grab offset.** A dragged icon lands ~(+31,+11) from the
  cursor, so dropping *onto* the Trash means aiming up-left of it. Three drags
  failed before this was measured.
- **QMP `system_reset` hangs the q800** — it never comes back. A guest-initiated
  `Special → Restart` works; otherwise relaunch the process. Irrelevant to the
  station, whose reset is `loadvm`.

## Phase 4 — pointer — **measured, not assumed**

The q800's mouse is **ADB relative**: no absolute path, no USB tablet. The
station therefore runs `InputBackend::DbusRel` (`SH_INPUT_BACKEND=dbus-rel`),
the same backend `nt351` uses.

**Measured gain: exactly 0.36** (1000 units → 360 px, 1500 → 540, 2000 → 720,
3000 → 1079), linear and **chunk-size invariant** (identical at 1, 2, 4, 8, 16
and 32 units per send). So `cursor_scale = 1/0.36 = **2.7778**`, framebuffer-
verified rather than shipped as an unverified 1.0.

### The defect this uncovered in the daemon

`HOME_PIN` (`streamhost/streamhost/src/input.rs:157`) is **2048**, and its own
comment states the invariant: *"It only has to EXCEED the largest guest surface
we drive (1280x1024)"*. That silently assumes **gain 1.0**. At gain 0.36 a 2048
pin travels only **737 px** — short of this station's 1152 px width — so the
corner slam would leave the cursor somewhere unknown while the daemon's model
believed it was at 0,0. That is precisely the fixed-offset bug FIX 4 exists to
prevent.

The fix is to scale the pin by the station's own measured calibration —
`HOME_PIN * cursor_scale.max(1.0)` — which leaves every existing station
**byte-identical** (the only other `dbus-rel` station, `nt351`, has scale 1.0)
and makes it correct for any guest that divides incoming deltas.

The comment's reason for *reducing* the pin from 8192 (the Xerox Star incident:
the PS/2 wire carries ~127 counts/packet at 100 Hz, so a big pin takes most of a
second to drain and merges with the walk behind it) **does not apply on ADB**.
Measured here: with a 3200-unit pin, settle times of 0.25 s through 3.0 s all
produce the same result — the pin and the following walk are observed as two
separate movements even at the existing `HOME_SETTLE_MS` of 250 ms.

### Display mode

`macfb` accepts 640x480 / 800x600 (depth 1-24) and 1152x870 (depth 1-8), but
**800x600 never takes** — the VGA display type always comes up 640x480, with or
without `-g`, with a fresh PRAM, and Monitors offers no resolution list (the
declaration ROM exposes one mode). The real choice is 640x480 or **1152x870x8**,
the authentic Apple 21" mode. Chose **1152x870x8**: it sits between the fleet's
`1024x768` and `1280x1024`, and leaves room for the apps and games this station
is meant to carry.

### What the original plan got wrong here

It carried tinycore's technique, which does not apply — tinycore runs an
absolute USB tablet that the *guest kernel* re-reads as relative, and q800 has
no equivalent. And the "first cursor move lands at an arbitrary offset" problem
it flags as a decision to make is **already solved in the daemon**: `dbus-rel`
corner-slams on the first sample of a session
(`streamhost/streamhost/src/input.rs:377`, "FIX 4: HOME on seed") and tracks
from a known 0,0. No launcher-side corner-slam is needed, and none should be
added — only the pin's *magnitude* needed fixing.

## Phase 5 — station wiring, deploy, acceptance

Ordinary playbook work, in order: §5 input transport → §6 registry
(`registry/stations/macos753.json`, streamhost station dir, serve/reset/operator
maps, runtime UI manifest, cold-boot video) → §7 supervised deploy and the
acceptance matrix.

- **Idle auto-pause is mandatory.** m68k runs under **TCG** — no KVM — so an
  idle station burns real CPU. Declared from day one.
- **TCG latency needs measuring, not assuming.** Use
  [`MEASUREMENT-METHODOLOGY.md`](../MEASUREMENT-METHODOLOGY.md) and state a
  number. Poor interactive latency is a finding about the *tier*, not a defect
  in this station — and worth knowing before HP-UX/SunOS are planned on the
  same pattern.

## Acceptance (restated in current terms)

1. Mac OS 7.5.3 boots to the Finder desktop (Happy Mac on the way) and streams.
2. Pointer tracks relatively via `dbus-rel` with guest acceleration off and
   `cursor_scale` **2.7778** (measured on the framebuffer, not assumed); 1:1
   confirmation through a real browser client is an operator pass.
3. Checkpoint reset returns to the quiet Finder scene.
4. `registry/stations/macos753.json` exists and `make station-registry-check`
   passes.
5. Idle auto-pause proven: station at ~0 % CPU with no visitor.
6. The full quality gate is green.

## Why this is worth doing beyond the exhibit itself

It validates the **`qemu-system-<arch>` + dbus display** pattern for the whole
foreign-architecture wing. HP-UX 11i (HPPA), SunOS 4.1.4 (SPARC) and Mac OS
9.2.2 (PPC) are all catalogued as native QEMU stations and all waited on the
Phase 1 build question — which is now answered: the fork builds, its patches are
arch-neutral, dbus scans out, and a standalone `/opt/` binary is the packaging.

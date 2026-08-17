# Candidate: Apple A/UX 3.1.1

**Target: A/UX 3.1.1 on QEMU `q800`, with a patched QEMU build and an extra
Nubus-framebuffer ROM.** Tier 1, reuses the `macos753` pattern (same machine,
same capture shape); the QEMU fork is the main new work. Fallback if the
patched build can't be reproduced on this box: MAME `maciici` (Tier 3, needs
a Mac IIci ROM) — see below for why it's the fallback, not the plan.

**Status: nothing verified on this box.** No media or ROM sourced or hashed,
no boot attempted, no patched-QEMU build reproduced here. Everything below is
desk research plus the Virtual OS Museum's package metadata (read, not
booted) — the recipe is real and someone else's install reaches the Finder
with it, but nothing here has been confirmed independently yet.

## What the exhibit is

A/UX is System V.2/3 Unix wearing the Macintosh Finder as its shell: under
the familiar desktop, `/bin/sh`, `/etc/passwd`, NFS, and X11 (CommandShell /
MacX) all run for real, and Unix processes can be dropped onto the desktop
next to System 6/7-flavoured Mac apps via the "A/UX Toolbox". No other
station in the lineup shows Unix and a proprietary GUI environment
cohabiting the same desktop metaphor — it's a distinct genre from both the
Unix workstation stations (irix, tru64) and the classic-Mac stations
(macos753, and the `macos` poster). That "commercial Unix in a business
suit" angle is the slot it earns.

## Machine and emulator

**QEMU `q800` — the same Quadra 800 target the `macos753` station already
runs — via a patched build, with its built-in framebuffer turned off and
video supplied by a Nubus card instead.** A/UX 3.1.1 wants a
68851/68030-integral PMMU for its memory management; that requirement rules
out the *stock* `q800` machine model, but it does not rule out `q800`
itself, because the community A/UX-on-q800 work adds PMMU support to a
patched QEMU rather than switching machines. A/UX also doesn't drive the
q800's built-in framebuffer at all: per the Virtual OS Museum's working
install, the machine is booted with the built-in fb disabled (`fb=none`)
and video comes from a separate Nubus framebuffer card device,
`nubus-qfb`, configured for 1280×1024 at 16-bit depth. `mac_qfb.rom` —
already known from the VOM package metadata — is that card's Nubus
declaration ROM, not a general graphics-path patch; it sits alongside the
Quadra 800 ROM already in use for macos753 (`quadra800.rom`), which A/UX
still uses as the machine BIOS. RAM is 128 MB. Concretely, the patched
binary the museum records is `qemu-system-m68k-7.1.50-q800` — a ~7.2-era
QEMU development build carrying the community A/UX/q800 PMMU and
`nubus-qfb` work, not a mainline release.

The practical effect: the machine, ROM base, PRAM-as-mtd pattern, and
capture shape are not new work — they're the `macos753` recipe. The new
work is (a) building or sourcing a QEMU with the `nubus-qfb` device and the
A/UX-capable PMMU, and (b) wiring in `mac_qfb.rom` as that card's
declaration ROM. Whether (a) is actually new work — i.e. whether
`nubus-qfb` already exists in the QEMU built in this repo — is the first
thing to check; see Open questions.

**Fallback — MAME `maciici`.** A Mac IIci-class machine with a genuine
hardware PMMU would also satisfy A/UX's memory-management requirement, using
a Mac IIci (or IIx/IIcx-family) ROM instead of the Quadra 800 one. Its MAME
driver is listed WORKING for Mac OS System 6/7 with SCSI CD-ROM, but no
A/UX-version × MAME-version × ROM triple booting to the Finder is confirmed,
and it would land as Tier 3 (host video off, `x11-runtime.sh`, KEYDUMP
keymap, `SAVEST golden` contingent on `MACHINE_SUPPORTS_SAVE`). Only take
this path if the patched-QEMU build can't be reproduced or doesn't boot on
this box.

## Evidence from the Virtual OS Museum

VOM ships a working A/UX 3.1.1 install. We take no media from it — it is a
recipe reference only, per the media rule in
[`AGENTS.md`](../../../AGENTS.md) — but its package metadata (dpkg file
lists on the host rootfs) names the emulator and files, and the author's
screenshot filenames are effectively his verdict on what the install
reaches. The boot scripts themselves live on the 173 GB guest-image disk,
which has not been extracted, so the exact command line is inferred from
filenames, not read.

| VOM install | Files | Screenshot |
|---|---|---|
| `mac68k/.../aux_3.1.1_config/` | `RUN_QEMU`, `aux_3.1.1.qcow2`, `quadra800.rom`, `mac_qfb.rom`, `pram.bin`, `AUXBootfloppy.img`, `TuneUp2.0.img`, `systemupdate.sh` | `00_Finder_with_utilities.png` |

What this tells us:

- **QEMU `q800`, not MAME `maciici`**, and via a purpose-built
  `qemu-system-m68k-7.1.50-q800` binary — a patched QEMU, not a distro
  package. The `RUN_QEMU` scriptlet and `INFO/info` file (read, not the
  guest image itself) confirm the machine is `q800` with the built-in
  framebuffer disabled and a `nubus-qfb` card at 1280×1024×16 doing the
  actual display work, 128 MB RAM, and the Quadra 800 ROM as BIOS.
- **The target machine and ROM base are the same ones `macos753` already
  runs**, including PRAM attached as an `mtd` drive — the same pattern
  already in use for macos753's checkpoint/vmstate. `mac_qfb.rom` and the
  `nubus-qfb` device are the one addition, needed because A/UX doesn't use
  the built-in fb at all.
- **Disk choreography**: the A/UX system disk is a SCSI hard disk at SCSI ID
  1; the A/UX boot floppy image (`AUXBootfloppy.img`) is attached as a SCSI
  *hard disk* at ID 0, not as a floppy device — a specific, easy-to-miss
  wiring choice. A commented-out CD-ROM line for the 3.0.1 install ISO shows
  the install was originally done from CD, then that device removed once
  the system disk was in place.
- **A/UX reaches the Finder** in this configuration — `00_Finder_with_
  utilities.png` is direct confirmation, resolving what would otherwise be
  the biggest open question here.
- **A helper floppy and a post-install update step are part of the
  choreography**: `AUXBootfloppy.img` plus `TuneUp2.0.img` plus
  `systemupdate.sh` imply the install isn't a single pass — budget for it.
- **Version signal**: 3.1.1 has a screenshot and 3.0.0 does not (VOM doesn't
  carry a 3.0.x install at all) — target 3.1.1, not 3.0.1. The museum
  credits this particular install to its own author rather than a
  third-party image, dated 1995.

## Media and ROMs

**Unverified — no sourcing done yet, only hub identification.** A/UX 3.1.1
was a commercial CD release (the last, widest-driver version). Per
[`docs/catalog/os-media-catalog.md`](../../catalog/os-media-catalog.md) §3,
Macintosh Garden and Macintosh Repository are the hubs already trusted for
classic-Mac media/ROM archival copies in this repo; A/UX install CD images
are reported to circulate there and on archive.org preservation uploads, but
no specific URL has been located and hashed yet — that's the first real
task. Licensing posture: same "preservation copy of abandoned commercial
software" posture as the other classic-Mac entries in the catalog, not
free/open.

ROMs needed: `quadra800.rom` (already sourced and hashed for `macos753` —
reuse it) and `mac_qfb.rom`, the declaration ROM for the `nubus-qfb`
framebuffer card (not yet sourced; needs identifying against the community
q800-A/UX work that produces it). If the MAME fallback is taken instead,
that needs a Mac IIci ROM from the same archive family, hashed separately.

## Boot recipe

Not yet reproduced on this box. Our own derived invocation, built from the
facts above rather than copied from the museum's scriptlet: the patched
`qemu-system-m68k-7.1.50-q800`-equivalent binary, `q800` as the machine with
its built-in framebuffer turned off, a `nubus-qfb` card added and sized to
1280×1024×16, 128 MB of RAM, `quadra800.rom` as the machine BIOS, the PRAM
image attached as an `mtd` drive (the macos753 pattern), the A/UX system
disk as a SCSI hard disk at ID 1, the boot-helper image
(`AUXBootfloppy.img`-equivalent) as a second SCSI hard disk at ID 0, and our
own standard `-display dbus,p2p=on` for host-native capture in place of
VOM's VDE networking setup, which we don't need. `systemupdate.sh`-equivalent
post-install steps run once the system disk boots, per `TuneUp2.0.img`. The
first real task on this candidate is confirming the `nubus-qfb` device
exists in the QEMU built for this repo (see Open questions), then building
or sourcing the patched binary and confirming this shape holds.

## Graphical target

**1280×1024 at 16-bit depth is the known-good geometry** — the Nubus
`nubus-qfb` card's configuration in the Virtual OS Museum's working install,
not the Quadra 800's built-in framebuffer, which A/UX doesn't use at all
(booted with `fb=none`). This is a materially different display pipeline
from `macos753`, which does use the built-in fb — the shared piece between
the two stations is the ROM and machine, not the graphics path. Expect this
resolution/depth to hold once the `nubus-qfb` device is confirmed working
here; it's a known-good number from a working install, not a guess.

## Pointer and keyboard

Same pointer-precision bar as `macos753`: A/UX's Finder is a precision
desktop UI (drag-select, double-click hit-testing, menu tracking), not an
arcade ROM. Expect the same relative-mouse + measured `cursor_scale`
calibration dance `macos753` already solved (measured gain 0.36 →
`cursor_scale` 2.7778 there) — the gain still needs measuring for this
platform specifically, not assumed to match. Keyboard: ADB, same
KEYDUMP-generated keymap approach used across the fleet.

## Host-native capture plan

Tier 1, following the `macos753` shape directly: `-display dbus,p2p=on`,
foreign-arch QEMU under TCG, dbus scanout, measured pointer calibration. The
capture side is not new work; the patched-QEMU build and its `mac_qfb.rom`
are.

If the MAME fallback is taken instead, it drops to Tier 3 and follows
[`DEBRIDGE-CONVERSION-BRIEF.md`](../DEBRIDGE-CONVERSION-BRIEF.md): shared
`x11-runtime.sh`, KEYDUMP-generated keymap, `MAME_CTL_KEY_EXCL` set (ADB is a
scanned matrix like the other de-bridged MAME kiosks), and a `SAVEST golden`
checkpoint contingent on `MACHINE_SUPPORTS_SAVE` covering `maciici`.

## Known gotchas

- **A patched QEMU is required** — the stock `q800` machine model in this
  repo's existing QEMU fork does not have the A/UX-capable PMMU/build; a
  separate `qemu-system-m68k-7.1.50-q800`-equivalent build has to be
  reproduced or sourced.
- **The built-in framebuffer must be disabled, not just unused.** A/UX
  drives display through the `nubus-qfb` card with `fb=none` set on the
  machine; leaving the built-in fb on is not merely redundant with
  `macos753`'s setup, it's the wrong device for this guest.
- **The boot-helper floppy image attaches as a SCSI hard disk, not a floppy
  device.** `AUXBootfloppy.img`-equivalent goes on SCSI ID 0 as a second
  hard disk, with the system disk on SCSI ID 1 — attaching it as an actual
  floppy device would silently fail to reproduce the working shape.
- **Choreographed install**: boot floppy (`AUXBootfloppy.img`) plus a
  post-install update pass (`TuneUp2.0.img` + `systemupdate.sh`) on top of
  the base install — expect a materially longer, more multi-stage install
  than the classic Mac OS 7.5.3 recipe's straightforward path.
- **Disk size**: classic Mac OS install notes in the media catalog flag a
  ≤2 GB first-partition ceiling for pre-8.x System software on `q800`; A/UX's
  own disk/partition limits are unverified and should be checked against
  period documentation, not assumed to match.
- **Emulated SCSI pickiness**: period Unix-on-Mac installs have a reputation
  for being sensitive to SCSI device/ID timing during install; the
  `macos753` recipe's "must init the disk with Apple HD SC Setup, not Drive
  Setup" gotcha for pre-8.x Mac OS suggests A/UX likely has an equally
  particular disk-init step — needs confirming against an actual A/UX
  install walkthrough.

## Effort, risk, open questions

**Effort**: medium — smaller than previously estimated now that the machine
and capture shape are known to be `macos753`'s, but the patched-QEMU build
is real new work, and the install choreography (boot floppy, tune-up,
system-update script) is reported to be longer than a typical classic-Mac
install even when everything works.

**Risks**, in the order they would bite:

1. **The patched QEMU build doesn't reproduce cleanly on this box** — different
   host, different QEMU baseline, unclear how invasive the PMMU/q800 patch
   is versus mainline QEMU.
2. **Media and `mac_qfb.rom` sourcing**: install CDs are unstarted, and the
   Nubus-framebuffer ROM specifically hasn't been identified against a
   trusted archive entry yet.
3. **Install choreography**: boot-floppy + tune-up + system-update-script is
   a multi-stage sequence inferred from filenames, not read from a working
   command line — the exact order and any manual steps are unconfirmed.
4. **No confirmed save-state story** for this patched build specifically —
   `macos753`'s instant-resume checkpoint applies to the stock fork; whether
   the patched q800 binary checkpoints the same way is unverified.

**Open questions**:

- **Does the `nubus-qfb` device exist in the QEMU already built for this
  repo, or only in the A/UX/q800 patch series the museum used?** This is now
  the first question to answer, and it's cheaper to resolve than anything
  else on this list — no media or ROM sourcing required, just a `-device
  help`/`-M help`-style probe of the QEMU already built here. It decides
  whether "patched QEMU" is real new work or whether the piece we actually
  need has already landed upstream.
- If it isn't there yet: can `qemu-system-m68k-7.1.50-q800` (or an
  equivalent patched build) be reproduced from source on this box, and what
  exactly does the patch touch relative to the fork already running
  `macos753`?
- Where are the A/UX 3.1.1 install CD images and `mac_qfb.rom` archived, and
  do their hashes check out?
- What does `AUXBootfloppy.img` → install → `TuneUp2.0.img` +
  `systemupdate.sh` actually do, step by step — is any of it interactive?
- What pointer gain does this platform need? No measurement exists.
- Does checkpoint/instant-resume work the same way on the patched build as
  it does for `macos753`, or does the PMMU patch change save-state behavior?

**Fastest-resolving experiment**: check whether the `nubus-qfb` device is
already present in the QEMU built for this repo. If it is, the "patched
QEMU" risk collapses to just the PMMU/A/UX piece, and the plan gets
materially cheaper; if it isn't, that confirms the patched build is real new
work before any media is sourced. Either way, follow up by building or
sourcing the patched binary and booting the system disk with
`quadra800.rom` + `mac_qfb.rom`, `fb=none`, and the `nubus-qfb` card wired up
by hand — no station scaffold, no install — and confirm it reaches the
Finder on this box's hardware. That single boot validates the entire plan
above before any scaffolding work begins.

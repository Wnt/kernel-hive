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
runs — via a patched build, plus one extra ROM.** A/UX 3.1.1 wants a
68851/68030-integral PMMU for its memory management; that requirement rules
out the *stock* `q800` machine model, but it does not rule out `q800`
itself, because the community A/UX-on-q800 work adds PMMU support to a
patched QEMU rather than switching machines. Concretely, that build is
`qemu-system-m68k-7.1.50-q800` — the Quadra 800 ROM already in use for
macos753 (`quadra800.rom`), plus a second ROM, `mac_qfb.rom`, which is the
Nubus-framebuffer piece the patched build expects.

The practical effect: the machine, ROM base, and capture shape are not new
work — they're the `macos753` recipe. The new work is building (or sourcing
a prebuilt) `qemu-system-m68k-7.1.50-q800`, plus wiring in `mac_qfb.rom`.

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
  package.
- **The target machine is the same one `macos753` already runs.** The
  Quadra-800 ROM is shared; `mac_qfb.rom` is the one addition.
- **A/UX reaches the Finder** in this configuration — `00_Finder_with_
  utilities.png` is direct confirmation, resolving what would otherwise be
  the biggest open question here.
- **A helper floppy and a post-install update step are part of the
  choreography**: `AUXBootfloppy.img` plus `TuneUp2.0.img` plus
  `systemupdate.sh` imply the install isn't a single pass — budget for it.
- **Version signal**: 3.1.1 has a screenshot and 3.0.0 does not (VOM doesn't
  carry a 3.0.x install at all) — target 3.1.1, not 3.0.1.

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
reuse it) and `mac_qfb.rom` (not yet sourced; needs identifying against the
community q800-A/UX work that produces it). If the MAME fallback is taken
instead, that needs a Mac IIci ROM from the same archive family, hashed
separately.

## Boot recipe

Not yet reproduced on this box. Shape, inferred from VOM's file list rather
than a read command line: `qemu-system-m68k-7.1.50-q800` (patched build),
`-M q800`, `quadra800.rom` + `mac_qfb.rom` as the ROM pair, `aux_3.1.1.qcow2`
as the boot disk, `pram.bin` for PRAM state, `AUXBootfloppy.img` attached for
first boot, and `systemupdate.sh` run post-install per `TuneUp2.0.img`. The
first real task on this candidate is building or sourcing the patched
binary and confirming this shape holds.

## Graphical target

Quadra 800 built-in video via the `mac_qfb.rom` Nubus-framebuffer path —
same display pipeline family as `macos753`, so expect a comparable
resolution/depth ceiling rather than the low-res/1-bit path a Mac II-class
machine would have implied under MAME. Exact resolution/depth is unverified
until the build boots.

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

- Can `qemu-system-m68k-7.1.50-q800` (or an equivalent patched build) be
  reproduced from source on this box, and what exactly does the patch touch
  relative to the fork already running `macos753`?
- Where are the A/UX 3.1.1 install CD images and `mac_qfb.rom` archived, and
  do their hashes check out?
- What does `AUXBootfloppy.img` → install → `TuneUp2.0.img` +
  `systemupdate.sh` actually do, step by step — is any of it interactive?
- What pointer gain does this platform need? No measurement exists.
- Does checkpoint/instant-resume work the same way on the patched build as
  it does for `macos753`, or does the PMMU patch change save-state behavior?

**Fastest-resolving experiment**: build (or source) the patched
`qemu-system-m68k-7.1.50-q800` binary and boot `aux_3.1.1.qcow2` with
`quadra800.rom` + `mac_qfb.rom` by hand — no station scaffold, no install —
and confirm it reaches the Finder on this box's hardware. That single boot
validates the entire plan above before any media is sourced independently or
any scaffolding work begins.

# Candidate: Apple A/UX (3.0.1 / 3.1.1) — first-pass research

Follows [`ADD-NEW-OS-PLAYBOOK.md`](../ADD-NEW-OS-PLAYBOOK.md) and the tier
model in [`GUEST-TIERS.md`](../../GUEST-TIERS.md). Compare against the live
`macos753` station ([`macos753-add.md`](macos753-add.md)) — same OS family,
very different machine/tier.

## What the exhibit is

A/UX is System V.2/3 Unix wearing the Macintosh Finder as its shell: under the
familiar desktop, `/bin/sh`, `/etc/passwd`, NFS, and X11 (CommandShell / MacX)
all run for real, and Unix processes can be dropped onto the desktop next to
System 6/7-flavoured Mac apps via the "A/UX Toolbox". No other station in the
lineup shows Unix and a proprietary GUI environment cohabiting the same
desktop metaphor — it's a distinct genre from both the Unix workstation
stations (irix, tru64) and the classic-Mac stations (macos753, and the
`macos` poster). That "commercial Unix in a business suit" angle is the slot
it earns.

## Media and ROMs

**Unverified — no sourcing done yet, only hub identification.** A/UX 3.0.1
and 3.1.1 were commercial CD releases (3.1.1 was the last, widest-driver
version, generally the better target). Per
[`docs/catalog/os-media-catalog.md`](../../catalog/os-media-catalog.md) §3,
Macintosh Garden and Macintosh Repository are the hubs already trusted for
classic-Mac media/ROM archival copies in this repo; A/UX install CD images are
reported to circulate there and on archive.org preservation uploads, but I
have not located and hashed a specific URL this pass — that's the first real
task, not a citation here. Licensing posture: same "preservation copy of
abandoned commercial software" posture as the other classic-Mac entries in the
catalog, not free/open.

ROM: a Mac II-class machine needs a **Mac IIci ROM** (or IIx/IIcx-family ROM —
MAME's `maciici` driver specifically wants the IIci's 32-bit-clean ROM,
distinct from the Quadra 800 ROM the `macos753`/`q800` recipe uses). Source
would be the same Macintosh Garden/Repository ROM archive already used for
the Quadra 800 dump, hash to confirm — unverified which exact archive entry.

## Emulator and machine

**MAME `maciici` is the only credible path; QEMU is not.** QEMU's Mac
emulation (`q800`, in the fork already built for `macos753`) targets the
68040-based Quadra/LC family with a memory/bus model that does not include a
PMMU-equipped Mac II-class machine — A/UX **requires the 68851/68030-integral
PMMU** for its memory management (paging/protection), which is why it won't
just boot under `q800` even if the ROM were swapped. This needs to be stated
plainly for any reviewer tempted to reuse the macos753 QEMU build: **it
cannot**, without someone first adding Mac II PMMU support to the fork's
QEMU, which is out of scope here. So this is a **MAME driver station**, not a
QEMU one, unlike every classic-Mac entry documented so far.

MAME's `maciici` driver status is only loosely known to me at this pass:
MAME lists `maciici` as WORKING for Mac OS (System 6/7) with SCSI CD-ROM,
but A/UX specifically booting to the Finder under `maciici` is
**unverified** — I did not find a documented working version pairing this
pass (no A/UX-version × MAME-version × ROM triple confirmed). This is the
single biggest unknown and the right first experiment (see below).

## Graphical target

Mac II-class video is a separate NuBus video card in real hardware; MAME's
`maciici` driver emulates a fixed built-in framebuffer. Expect classic 640×480
or similar low-res, 1-bit to 8-bit depth depending on the card MAME emulates
— **unverified**, needs checking against MAME's `-listslots`/`-video` for
`maciici` (it lacks the framebuffer choices `mac128k`/`maciici`'s onboard
video path may or may not expose). A/UX's Finder is graphical and expects at
least a few hundred KB of VRAM; not expecting anything above 8-bit greyscale
or color at this vintage.

## Pointer and keyboard

Same family as the nine de-bridged MAME kiosks: MAME natively drives a
**relative** mouse (ADB on real Mac II hardware, emulated inside MAME), so
the pointer path is the same `cursor_scale` calibration dance those stations
already solved, not a new problem — but it does matter more here than on a
game-like MAME title because A/UX's Finder is a precision desktop UI
(drag-select, double-click hit-testing, menu tracking), much closer to the
macos753 pointer-precision bar than to an arcade ROM. A true 1:1 absolute
pointer would need MAME ADB absolute-mouse support wired through, which is
unverified as existing for this driver — likely the same relative + gain
calibration used elsewhere in the fleet, tuned per-resolution like macos753's
measured `2.7778` gain rather than assumed. Keyboard: ADB keyboard, same
KEYDUMP-generated keymap approach as the other native.d MAME stations should
apply directly.

## Host-native capture plan (Tier 3)

Follows the de-bridging template exactly:
[`DEBRIDGE-CONVERSION-BRIEF.md`](../DEBRIDGE-CONVERSION-BRIEF.md) — shared
`stations/mame-native/x11-runtime.sh`, a `native.d` build stanza invoking
`maciici` with its ROM + hard disk + CD images, `MAME_CTL_KEY_EXCL` set (ADB
is a scanned matrix like the other nine, same ambiguous-simultaneous-keys
problem), KEYDUMP-generated keymap, and a `SAVEST golden` checkpoint —
contingent on `MACHINE_SUPPORTS_SAVE` actually covering `maciici` (unverified;
some MAME drivers with real SCSI/HDD state don't save cleanly). If save-state
isn't supported for this driver, the station would need a cold-boot-every-time
launcher instead of instant resume, which changes the operator experience and
should be flagged early, not discovered at the end.

## Known gotchas

- **PMMU requirement** rules out the QEMU q800 path outright (see above) —
  this is the one fact most likely to get "just reuse macos753" wrong.
- **A/UX install is long and multi-stage** (multiple install CDs/floppies in
  real deployments, custom disk partitioning via Apple HD SC Setup-equivalent,
  post-install configuration) — expect a materially longer and more
  choreography-heavy install than the classic Mac OS 7.5.3 recipe's
  documented straightforward path.
- **Disk size**: classic Mac OS install notes in the media catalog flag a
  ≤2 GB first-partition ceiling for pre-8.x System software on `q800`; A/UX's
  own disk/partition limits under `maciici`'s emulated SCSI are unverified
  and should be checked against period documentation, not assumed to match.
- **Emulated SCSI pickiness**: A/UX, like several period Unix-on-Mac-II
  installs, has a reputation (unverified specifically for MAME) for being
  sensitive to SCSI device/ID timing during install; the macos753 recipe's
  "must init the disk with Apple HD SC Setup, not Drive Setup" gotcha for
  pre-8.x Mac OS suggests A/UX likely has an equally particular disk-init
  step — needs confirming against an actual A/UX install walkthrough.

## Effort, risk, open questions

**Effort**: medium-to-large — larger than the last MAME-native additions,
because (a) the media/ROM sourcing is unstarted, (b) the MAME driver's
A/UX-specific maturity is unconfirmed, and (c) the install choreography is
reported to be long even when everything works. Not a small/known-working
slot like Mac OS 7.5.3 was.

**Risk**: the dominant risk is that `maciici` in MAME simply doesn't boot
A/UX to a usable Finder desktop at all, or only does so for one specific
A/UX-version × ROM-version pairing that hasn't been identified yet. Secondary
risk: no confirmed save-state support for the driver would mean no instant
checkpoint resume, undercutting the "instant" bar the rest of the fleet has
converged on.

**Open questions**:
- Which exact A/UX version (3.0.1 vs 3.1.1) and Mac IIci ROM revision is
  reported (by anyone, anywhere) to boot to the Finder under MAME `maciici`?
- Does `maciici` support MAME save states (`MACHINE_SUPPORTS_SAVE`) at all?
- Where, specifically, are the A/UX install CD images and the correct Mac
  IIci ROM archived, and do their hashes check out?

**Fastest-resolving experiment**: boot a plain, empty `maciici` MAME session
by hand (no install yet, no station scaffold) with a sourced Mac IIci ROM and
confirm the driver reaches its ROM/diagnostic screen at all under this box's
MAME build — that single boot answers driver viability before any media is
even sourced, and is far cheaper than starting the install.

---

**This is an unvalidated first pass written under a 5-minute timebox.** No
media or ROM has been sourced, no MAME boot attempted, no version pairing
confirmed. Treat every "unverified" claim above as a to-do, not a fact.

---

## VOM hints (reference only, added 2026-08-17)

The Virtual OS Museum collection on this box ships a working installation of
this OS. **We take no media from it** — see the media rule in
[`AGENTS.md`](../../../AGENTS.md); it is a recipe reference only. These hints were read from its *package metadata* (dpkg file
lists on the host rootfs), which names the emulator, the ROM/firmware files and
the author's own screenshots — the screenshot filenames are effectively his
verdict on what the install actually reaches. The boot scripts themselves live
on the 173 GB guest-image disk, which has NOT been extracted, so the exact
command lines below are inferred from filenames, not read.

**VOM install:** `mac68k/.../aux_3.1.1_config/` — and it **overturns the
machine/tier conclusion above.**

- Files: `RUN_QEMU`, `aux_3.1.1.qcow2`, **`quadra800.rom`**, **`mac_qfb.rom`**,
  `pram.bin`, `AUXBootfloppy.img`, `TuneUp2.0.img`, `systemupdate.sh`.
- **A/UX runs under QEMU `q800`, not MAME `maciici`.** The host carries a
  purpose-built **`qemu-system-m68k-7.1.50-q800`** binary — a patched QEMU, and
  the extra `mac_qfb.rom` is the Nubus-framebuffer piece that goes with the
  community q800 A/UX work. So the PMMU objection in the section above is wrong
  for this path: the target is the same machine our **`macos753` station already
  runs**, with a patched QEMU and one extra ROM.
- That moves A/UX from "Tier 3 MAME, largely unknown" to **"Tier 1, reuse the
  `macos753` pattern, plus a patched-QEMU build"** — a much better position, and
  the QEMU fork is the main new work.
- `00_Finder_with_utilities.png` resolves the biggest open question in this
  note positively: **A/UX does reach the Finder** in this configuration.
- `AUXBootfloppy.img` + `TuneUp2.0.img` + `systemupdate.sh` say the boot needs a
  helper floppy and a post-install update step — budget for choreography.
- Version signal: **3.1.1 has a screenshot and 3.0.0 does not.** Target 3.1.1.

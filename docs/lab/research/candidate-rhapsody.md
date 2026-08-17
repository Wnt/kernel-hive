# Candidate: Rhapsody 5.1 for Intel (Mac OS X Server 1.x era)

## What the exhibit is

A visitor sees Apple's Platinum Finder — Mac-style menu bar, Finder windows,
the Mac OS 8 look — running on top of a visibly NeXT/Mach substrate (the
NeXT-style installer, `bash`/Display PostScript underpinnings, NetInfo). The
story: this is the moment Apple grafted the Mac face onto the NeXT operating
system it had just bought, mid-transition, before the Aqua redesign. It is the
**direct ancestor of Mac OS X** — not a NeXTSTEP variant with a new skin, but
literally the release where "Mac OS X" (as Mac OS X Server 1.0) starts. Placed
next to the existing `nextstep` station (NeXTSTEP 3.3, pure NeXT UI) and the
`macos` poster (classic/OS X showcase), Rhapsody is the hinge exhibit: it
makes the NeXT→Mac OS X lineage visible in a way neither endpoint can alone.
That is what makes it a distinct third exhibit rather than "NeXTSTEP again" —
the Yellow Box/Blue Box duality and the Platinum-over-Mach chimera look are
unique to this one release window.

## Which release

Public/semi-public Rhapsody-family builds, in rough chronology:

- **Developer Release 1 (DR1, 1997)** and **DR2 (1998)** — early developer
  previews, PowerPC-only or PowerPC-first; x86 support was present but thin
  and buggy. Hard to source and harder to boot reliably. **Not the target.**
- **Rhapsody 5.1** — the mature developer release, ships as **Mac OS X Server
  1.0** for shipping purposes; this is the one most commonly circulating in
  preservation channels with an Intel installer track, and the one this
  candidate targets.
- **Mac OS X Server 1.2 (build 5.3 / "Hera")** — later refinement of the same
  lineage; PowerPC-focused in practice, Intel path less commonly preserved.

**Target: Rhapsody 5.1 for Intel specifically**, not PowerPC. Two reasons:
(1) this repo's whole guest fleet is host-native x86/x86_64 QEMU — there is no
PowerPC (`mac99`) NeXT-lineage station yet and standing one up is a much
bigger lift than reusing the existing i386 QEMU path already proven for
NeXTSTEP 3.3; (2) x86 keeps this in the same "fussy PC-era Mac-adjacent OS"
family as the NeXTSTEP 3.3 station, so its install gotchas (SCSI driver
quirks, NIC driver narrowness, keyboard remap) are a direct precedent to reuse
rather than a fresh unknown.

## Media

**Unverified — no search performed this pass beyond a repo grep (no hits in
`docs/catalog/os-media-catalog.md` or `~/vom-repo/info/emulators/`).** Rhapsody
is not currently in the media catalog at all. Candidate sources to check next,
per this project's standing sourcing rule (source ourselves, hash it):

- **archive.org** — searches for "Rhapsody 5.1", "Mac OS X Server 1.0 Intel",
  "Rhapsody DR2 x86" have historically turned up ISO/floppy sets in Apple
  preservation communities; not confirmed present today.
- **WinWorld** — lists NeXTSTEP already (confirmed in catalog); Rhapsody
  presence unconfirmed, worth checking since WinWorld's catalog scope overlaps
  (pre-Mac-OS-X Apple software is spottier there than NeXTSTEP/BeOS).
- **Macintosh Garden / Macintosh Repository** — primarily classic Mac OS media
  + ROMs; Rhapsody is a boundary case (it's Mac-branded but NeXT-kerneled) so
  presence is plausible but unconfirmed.

Licensing posture: **contested/preservation, not clean-freeware** — unlike
BeOS PE or EmuTOS, Rhapsody/Mac OS X Server 1.x was commercial Apple software
with no known freeware re-release. Treat any found copy as preservation-only,
same posture as NeXTSTEP 3.3, and say so plainly in any station doc that
results from this research. Format is presumed multi-floppy boot set + CD
ISO, by analogy with NeXTSTEP 3.3's packaging; size unconfirmed, likely in the
several-hundred-MB range for the CD.

## Emulator, machine, boot recipe

Tier 1 expected — native x86 QEMU, no bridge, same pipeline as NeXTSTEP 3.3.
No Rhapsody-specific recipe verified this pass; best-known starting point by
direct analogy with the working NeXTSTEP 3.3 x86 station:

```
qemu-system-i386 -M pc -cpu pentium2 -m 256 \
  -drive file=rhapsody.qcow2,format=qcow2,if=ide \
  -drive file=rhapsody-cd.iso,format=raw,media=cdrom,if=ide \
  -device VGA -netdev user,id=n0 -device ne2k_pci,netdev=n0 \
  -display dbus,p2p=on -boot d
```

- **CPU**: conservative Pentium-II-class model — Rhapsody's Mach kernel and
  driver set are period Intel PC hardware, not tolerant of exotic CPU feature
  bits. **Unverified** exact ceiling.
- **RAM**: NeXT-lineage kernels of this era are typically capped well under
  1 GB; NeXTSTEP 3.3's practical ceiling is far lower still. Start low (256 MB)
  and raise only if boot succeeds; no confirmed number for Rhapsody specifically.
- **Disk controller**: IDE is the safer first guess (NeXTSTEP 3.3's SCSI
  install path is the known-fussy one on this same lineage per the catalog
  gotcha below) — but Rhapsody's Hardware Compatibility List may push the
  other way; needs checking once media is in hand.
- **VGA**: stock `VGA` device, matching the rest of the native-QEMU fleet.
  Display PostScript compositing may be heavier than a plain framebuffer OS;
  worth watching for redraw/damage-tracking cost once a checkpoint exists.
  **Unverified.**
  - **NIC**: `ne2k_pci` as the first guess, same reasoning as BeOS R5 and the
  NeXTSTEP precedent (narrow, old driver sets favor the oldest common NIC
  model) — **unverified for Rhapsody**.
- **KVM vs TCG**: NeXTSTEP 3.3's catalog gotcha says TCG or a plain `-cpu` is
  *more* stable than aggressive KVM on this OS family; treat that as the prior
  for Rhapsody too until proven otherwise.

## Graphical target

Platinum Finder desktop — Mac OS 8-style menu bar, windows, icons — running
over Display PostScript. Resolution/depth unconfirmed; period-correct target
is likely 640×480 or 800×600 at 8/16-bit, similar to contemporaneous Mac OS
and NeXTSTEP defaults, gated by whatever VGA/VESA mode the installed video
driver actually claims. The Rhapsody driver set is much narrower than mature
Mac OS X — this is the single biggest unknown constraining what resolution is
achievable at all.

## Pointer and keyboard

No confirmed answer this pass. NeXTSTEP-family systems of this era generally
expect **relative PS/2** input rather than absolute USB tablet — the NeXTSTEP
3.3 precedent implies calibration via `cursor_scale` rather than `usb-tablet`
would be the safer first attempt, but Rhapsody's driver stack (closer to early
Mac OS X's IOKit than to raw NeXTSTEP) may behave differently. **Try
`usb-tablet` first for the lower integration cost, fall back to PS/2 +
calibration if pointer tracking is unusable** — same triage order the project
already uses elsewhere.

## Known gotchas

Carried forward from the NeXTSTEP 3.3 x86 entry (catalog line, same lineage,
treat as the working prior until disproven):

- **SCSI driver choice matters** — NeXTSTEP 3.3 needed driver option #2 to
  dodge a corrupt beta driver disk; Rhapsody's installer may have an
  analogous trap given it shares NeXT installer ancestry.
- **Networking is likely to be the weak link** — ne2000-class NICs were
  "effectively broken" on NeXTSTEP 3.3 (worked around with a small extra
  partition for file transfer instead of network transfer); budget for the
  same workaround on Rhapsody until proven otherwise.
- **Keyboard remap after updates** — NeXTSTEP 3.3 needed a keyboard remap
  after applying update #3; Rhapsody's own update/patch history (if any patch
  set is findable) may carry the same trap.
- **Rhapsody-specific unknowns (genuinely unverified, not inherited)**: exact
  Hardware Compatibility List for Intel (which chipsets/disk controllers the
  installer actually recognizes), which video drivers ship for Intel VGA
  clones under QEMU, and whether the Yellow Box / Blue Box split matters for a
  static museum boot (it should not, since no third-party apps are being
  installed — but this is a guess, not a checked fact).

## Effort, risk, open questions

**Effort/risk: high, comparable to or above NeXTSTEP 3.3** (which the catalog
already scores MV 5, its top difficulty tier) — Rhapsody adds an extra layer
of uncertainty on top of NeXTSTEP's known fussiness: media is unconfirmed to
even exist in an accessible preservation form, and there is zero prior art in
this repo (no catalog entry, no vom-repo hint, no prior gotcha writeup) to
lean on beyond the NeXTSTEP 3.3 analogy used throughout this note.

**Open questions, in priority order:**
1. Does a bootable Rhapsody 5.1 (or DR2) **Intel** install image actually
   exist in an archive.org / WinWorld holding? This is unconfirmed and gates
   everything else.
2. If found, does it boot at all under `qemu-system-i386` with a
   NeXTSTEP-3.3-style device set, or does it need a materially different
   machine/driver configuration?

**Fastest single experiment to resolve the most uncertainty**: do the media
search (archive.org + WinWorld, ~15 minutes) and, if an image turns up,
attempt one raw boot to the installer's first graphical (or text) screen under
the NeXTSTEP-3.3-derived QEMU command line above, with no attempt at a full
install. That one boot attempt answers "is this even reachable with known
tooling" before any further recipe tuning is worth doing.

---

This is an unvalidated first pass written under a 5-minute timebox. No media
search, no emulator run, and no cross-check against `~/vom-repo/info/emulators/`
beyond a filename grep were performed. Treat every recipe value above as a
starting guess to be revised once real media is in hand.

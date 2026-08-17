# Candidate: BeOS R5 (Personal/Professional Edition)

## What the exhibit is

A visitor lands on BeOS's native desktop — the Tracker file manager, Deskbar,
and the pervasive multithreaded-media demos (`Pulse`, media player scrubbing
video with zero stutter on period hardware) that made BeOS famous as "the OS
that never dropped a frame." It earns a slot as the deliberate **BeOS↔Haiku
pairing** already called out in the media catalog (§ "Deliberate pairings"):
Haiku is the open-source recreation, already live in the gallery
(`registry/stations/haiku.json`); BeOS R5 is the original it recreates. Seeing
both side by side is the exhibit.

## Media

From `docs/catalog/os-media-catalog.md` §3 (already verified there — reusing,
not re-deriving):

- **BeOS R5 Personal Edition / Professional 5.0.3** —
  `https://archive.org/details/beos-professional-edition-5.0.3` — **verified**
  present in catalog. Format: bin/cue CD image(s). Size ~641 MB. Licensing
  posture: preservation (PE was freeware at release, so redistribution risk is
  low relative to Pro).
- No second/alternate source was checked in this pass — WinWorld likely also
  mirrors BeOS R5; **unverified**, not looked up.

## Emulator, machine, boot recipe

Tier 1, native x86 QEMU — no bridge needed (BeOS R5 has a plain VGA/VESA
framebuffer QEMU scans out directly). Best-known recipe, adapted from the
catalog's NT4/Mac patterns plus the BeOS-specific gotchas below (**unverified
end-to-end** — not yet run in this pass):

```
qemu-system-i386 -M pc -cpu pentium3 -m 512 \
  -drive file=beos.qcow2,format=qcow2 \
  -drive file=beos-r5.iso,format=raw,media=cdrom \
  -device VGA -device ne2k_pci,netdev=n0 -netdev user,id=n0 \
  -display dbus,p2p=on -boot d
```

- **CPU**: `pentium3` (or plain default) — BeOS R5 predates SSE-heavy guest
  assumptions; not yet stress-tested against `-cpu host`.
- **RAM**: cap **≤768 MB** (catalog gotcha — R5's kernel has a hard ceiling;
  above it, boot fails or behaves unpredictably).
- **VGA**: stock `VGA` device; BeOS boots to 640×480 greyscale by default and
  needs an explicit VESA mode set post-install (see Graphical target).
- **NIC**: `ne2k_pci` specifically (catalog gotcha) — BeOS R5's driver set is
  narrow; other NIC models are not known-good.
- **Media prep**: source is bin/cue, not ISO — must extract with `bchunk`
  before QEMU can use it as `-cdrom`.

## Graphical target

Out of the box: 640×480, 256-colour/greyscale VESA fallback. Target after
setup: **1024×768×16** via the BeOS "Screen" preferences, matching the catalog
gotcha's VESA mode note (`1024 768 16`). Desktop is Tracker + Deskbar,
consistent with what a Haiku station visitor already sees, which is the point
of the pairing.

## Pointer and keyboard

**Unverified — not determined in this pass.** BeOS R5 is contemporaneous with
PS/2-only mice (R5 predates broad USB tablet/absolute-pointer support in its
driver stack), so the working assumption is **relative pointer (PS/2 +
cursor_scale calibration)**, same family as other pre-USB-era Tier 1 stations,
rather than `usb-tablet` absolute mode like Haiku uses. This needs an actual
boot to confirm: watch whether the BeOS cursor tracks 1:1 with a QEMU
`usb-tablet` device (if BeOS enumerates it at all) or drifts/scales, which
would confirm PS/2 relative mode is required instead.

## Host-native capture plan

**Tier 1** — direct QEMU framebuffer via `-display dbus,p2p=on`, same pipeline
as every other native x86 Tier 1 station (NT 3.51/4.0, etc. in the same
catalog section). No bridge, no captured-Linux kiosk PoC needed — BeOS
produces a real VGA/VESA framebuffer natively. streamhost needs: a station
dir under `/data/vms/streamhost/stations/beosr5/` (scaffold via
`stations-registry.py new`), a QMP socket for build-time automation
(`scripts/lib/labqmp.py`), a checkpoint captured post-VESA-mode-setup so the
station launches straight to the 1024×768 Tracker desktop, and — pending the
pointer question above — either `usb-tablet` or PS/2 relative wiring in the
station's device set to match whatever the pointer test finds.

## Known gotchas

(All from the catalog's existing BeOS R5 entry — carried forward, not
re-derived this pass.)

- **bin/cue extraction**: source images are bin/cue, need `bchunk` to produce
  a plain ISO/raw image QEMU can mount.
- **"Disable BIOS calls"**: at the R5 boot menu, must be toggled off **before
  first install completes** — a known R5-under-QEMU install blocker.
- **RAM cap ≤768 MB**: exceeding it breaks boot/install.
- **VESA mode**: defaults to 640×480 greyscale; must be explicitly set to
  1024×768×16 post-install for a presentable exhibit.
- **NIC must be `ne2k_pci`**: other NIC emulations are not known-good with
  R5's driver set.

## Effort, risk, open questions

**Effort estimate**: small–medium (catalog rates it MV 5 / "works-known" —
someone else has clearly booted this combination before, but this session has
not run it). Comparable in shape to the NT 3.51/NT 4.0 native x86 recipes
already in the lineup.

**Risk**: low on the emulation side (native x86, no ROM dependency, no bridge)
— main risk is the pointer-mode unknown turning into real calibration work,
and PE-vs-Pro licensing nuance if a non-PE image is substituted later.

**Open questions** (genuinely unresolved, not just unverified detail):
1. Absolute (`usb-tablet`) vs relative (PS/2) pointer — needs an actual boot
   to determine; this note's PS/2 assumption is a guess based on era, not a
   tested fact.
2. Audio support and whether it's worth wiring for the exhibit (BeOS's media
   story is part of its historical draw).
3. Whether the archive.org disc is truly a clean single-CD install or needs a
   second (Pro) disc for full driver coverage.
4. No second media source was cross-checked against the archive.org one in
   this pass.

---

This is an unvalidated first pass written under a 5-minute research timebox —
treat every "unverified" and "best-known" line above as a starting point for
the actual scaffold-and-boot work, not a confirmed recipe.

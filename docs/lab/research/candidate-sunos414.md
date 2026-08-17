# Candidate: SunOS 4.1.4 / Solaris 1.1.2 (OpenWindows / OpenLook)

Registry id (proposed): `sunos414` (or `sunos4`, TBD at scaffold time).

## What the exhibit is

Sun's classic BSD-derived UNIX on SPARC, running **OpenWindows 3.x**, the
pre-CDE desktop built on the **OpenLook** toolkit (`olwm` window manager,
diagonal-hatch three.dimensional widgets, the pinnable workspace menu). This
is what Sun workstations looked like from the late 1980s through ~1995,
before Sun adopted CDE/Motif for Solaris 2.x.

The existing `solaris` station in the lineup is Solaris (SVR4) on SPARC
running CDE — Motif widgets, the CDE front panel, a desktop that looks
close to HP-UX/AIX/Tru64's CDE. This candidate is visually and historically
distinct: OpenLook is angular/beveled rather than Motif's shaded 3D, has no
front panel, and represents the *other* branch of Sun's desktop history
(NeWS-derived OPEN LOOK vs. OSF/Motif). Placing both side by side tells the
"Sun's own desktop before CDE won" story — same vendor, same SPARC silicon,
different toolkit war outcome. Worth a slot on that contrast alone.

## Media

From `docs/catalog/os-media-catalog.md` §5 (already catalogued, reuse as-is):

| | |
|---|---|
| Candidates | https://winworldpc.com/product/sun-solaris/1x ; https://fsck.technology/software/Sun%20Microsystems/SunOS%20Install%20Media/ (marked ✓ in the catalog) |
| Format | install CD ISO |
| Size | ~500 MB – 1 GB |
| Licensing | **contested-commercial** — say so plainly in the guest doc; source and hash ourselves per project rule, never take media from the `vom-repo` collection on this box |
| Firmware | none needed — OpenBIOS covers SPARC boot |
| Catalog's own difficulty/priority | medium / MV 5 |

Unverified beyond what the catalog already asserts (I did not re-check these
URLs live during this pass).

## Emulator, machine, boot recipe

Straight from the catalog's already-verified recipe — do not redo this work,
just execute it in a builder:

```
qemu-system-sparc -M SS-5 -m 256 \
  -vga cg3 \
  -drive file=sunos414.qcow2,if=scsi,bus=0,unit=0,media=disk \
  -drive file=sunos_4.1.4_install.iso,if=scsi,bus=0,unit=2,media=cdrom \
  -net nic,model=lance -net user
```

- Machine: `SS-5` (SPARCstation 5), the QEMU `sun4m` target with the widest
  guest compatibility for this vintage.
- RAM ceiling: 256 MB is what the catalog recipe uses; SS-5 hardware topped
  out well below modern QEMU defaults, so don't casually raise this without
  checking SunOS's own upper limit for the `sun4m` kernel.
- Disk/CD: both on SCSI (`if=scsi`), consistent with real SS-5 wiring — no
  IDE on this machine class.
- NIC: `lance` model — matches the SS-5's onboard Ethernet.
- **`-vga cg3` is load-bearing**: QEMU's `sun4m` default framebuffer is TCX,
  and SunOS 4.1.4 has no driver for it. `cg3` (the older Sun color
  framebuffer) is what SunOS actually ships a driver for. Omitting this flag
  is the single most likely way to get a black screen that looks like a
  boot failure but is actually a missing video driver.

## Graphical target

OpenWindows is not started automatically at console login on a stock
install — `/usr/openwin/bin/openwin` is the launcher and it is **not on
`PATH`** by default (per the catalog note). The checkpoint/launcher will
need to either invoke that path directly or arrange autostart (`.xinitrc`/
inittab entry) so the streamhost captures a live desktop rather than a bare
console login. Resolution/depth of the OpenWindows session itself is
unverified this pass — likely constrained by whatever `cg3` exposes (cg3
historically tops out at 8-bit color), needs confirming against an actual
boot.

## Pointer and keyboard

- Expect the same relative-mouse story as other SPARC/QEMU stations in the
  lineup: QEMU's SPARC pointer input is relative, so the streamhost side
  will need a `cursor_scale` calibration pass against the guest's actual
  pointer acceleration, same as done for `solaris`. Copy that station's
  calibration approach rather than re-deriving it.
- Sun type-4/5 keyboard layout differences (compose key, `Stop`/`Again`
  L-keys, different placement of some punctuation) are a known class of
  gotcha on Sun guests generally; unverified whether SunOS 4.1.4 under QEMU
  needs any special scancode remap beyond what the existing `solaris`
  station already solved — check that station's keyboard notes first.

## Host-native capture plan

Tier 1 (direct QEMU), same as `solaris`: `-display dbus,p2p=on`, no bridge,
no kiosk VM. streamhost needs the usual per-station `station.env`, a
signaling entry, framebuffer capture off the `cg3` surface, and the same
input-forwarding path already proven for other SPARC/QEMU stations. No new
tier-3/tier-2 machinery required — this is meant to be a cheap addition
riding on infrastructure that already exists for `solaris`.

## Known gotchas

- **TCG, not KVM**: SPARC guests on an x86_64 host run under QEMU's software
  emulator (TCG). Expect meaningfully slower boot/install and possibly
  visible input lag versus the KVM-accelerated x86 stations — budget more
  wall-clock time for the install and checkpoint capture.
- **Disk geometry / `format`+`suninstall`**: SunOS 4.1.4 install is old-school
  Sun `suninstall`, which historically wants to partition via `format` with
  SunOS-native disk labels (not a modern partition table). Getting the
  target `.qcow2` disk labeled and sliced correctly before/during install
  is a known sharp edge on this OS family; expect to need to walk the
  `format` menu interactively rather than fully unattended.
- **OpenBIOS quirks**: QEMU's `sun4m` OpenBIOS is not a bit-perfect Sun
  OpenBoot clone; boot-arg syntax and device paths sometimes differ from
  real hardware docs of the era. Treat any SunOS-4.1.4-on-real-hardware
  install guide as approximate, not literal, for the OpenBIOS boot prompt.
- The `-vga cg3` requirement above is worth repeating as the single most
  likely first failure mode for anyone reproducing this from scratch.

## Effort, risk, open questions

- **Effort**: catalog rates it "medium" difficulty, MV 5 (matches other
  Tier-1 SPARC/legacy-UNIX adds). The recipe is already fully specified —
  most of the remaining work is executing the install interactively
  (partitioning, `suninstall` walk-through) and then getting OpenWindows to
  autostart and calibrating pointer/keyboard.
- **Risk**: TCG slowness could make the install session long; disk
  labeling via `format` is the most likely place to get stuck; OpenWindows
  color depth/resolution under `cg3` needs a real boot to confirm before
  planning the checkpoint capture.
- **Open questions** (all unverified this pass):
  - Confirm the WinWorld/fsck.technology media URLs are still live and get
    an actual hash.
  - What resolution/depth does `cg3` actually give OpenWindows, and is it
    fixed or configurable?
  - Does the existing `solaris` station's `cursor_scale` value transfer
    directly, or does SunOS 4.1.4's older mouse driver need its own
    calibration pass?
  - Any keyboard remap needed beyond what `solaris` already solved?
  - Proposed registry id (`sunos414` vs `sunos4`) — pick at scaffold time,
    check for collisions with `stations-registry.py new`.

---

This is an unvalidated first pass, written under a ~5-minute research
timebox. Treat every claim above as needing verification before it drives a
real builder; only the recipe/`-vga cg3` note is carried over from the
already-verified `docs/catalog/os-media-catalog.md` §5 entry.

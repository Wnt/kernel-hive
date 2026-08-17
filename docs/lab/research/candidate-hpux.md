# Candidate: HP-UX on PA-RISC

Initial research notes for adding HP-UX as a gallery station. Primary target
**HP-UX 11i v1 (11.11) with CDE**; 10.20 assessed as a fallback.

## What the exhibit is

A visitor sees a Common Desktop Environment (CDE) session — front panel, Motif
window manager, the HP "toolbox" look — rendered over HP's built-in **Artist**
framebuffer inside `qemu-system-hppa`. It is PA-RISC UNIX, the workstation OS
of the HP 9000 line, and slots next to the existing `solaris` CDE station as a
second, visibly-different CDE (different vendor chrome, different window
manager defaults, HP-specific front panel controls) — same desktop paradigm,
different silicon and vendor. Museum value is rated 5/5 in the existing
catalog entry for exactly this reason: full graphical CDE, no bridge required.

## Media

Already catalogued and marked verified/unverified in
`docs/catalog/os-media-catalog.md` §5 (row: "HP-UX 11i v1 (11.11) PA-RISC").
Reusing that entry rather than re-deriving:

- Candidate sources: `http://tenox.pdp-11.ru/` and archive.org item
  `hpux1100`; depot mirror `http://hpux.connect.org.uk/` (has a written
  install walkthrough — marked ✓ in the catalog, i.e. the writeup itself was
  checked, not that we've downloaded and hashed the media yet).
- Format: install ISO set (multi-disc: `mcoe.1_5.iso` referenced in the boot
  recipe below is one of them — "MCOE" = HP's Multi-User/CDE base OS bundle).
- Size: ~1.5–2 GB total.
- Licensing posture: **contested-commercial** — HP-UX is still owned/sold by
  HPE. Archived copies exist on preservation mirrors but this is not
  officially-free or public-domain; same bucket as AIX, Solaris, IRIX. Per
  project rule, we source and hash this ourselves from archival mirrors — the
  VOM collection on this box (`~/vom-repo/info/emulators/`) may be read for
  emulator/flag notes only, never as a media source.
- **11.11 constraint**: needs PA-RISC **1.1, 32-bit** media specifically —
  not PA-RISC 2.0/64-bit media, which QEMU's `hppa` target does not support.
  This caps the release at 11.11 (11i v1); later HP-UX releases (11.23/11.31,
  PA-RISC 2.0 or Itanium) are out of scope for this candidate.

None of the media has been downloaded or hashed yet as part of this note —
that is future work, flagged under Open Questions.

## Emulator, machine, boot recipe

From the catalog's verified recipe (virtuallyfun.com writeup, Oct 2025, qemu
10.1 — treat as works-known but unverified on this box/this qemu version):

```
qemu-system-hppa -machine B160L -smp cpus=4 -accel tcg,thread=multi \
  -boot d -drive if=scsi,bus=0,index=6,file=hpux.qcow2,format=qcow2 \
  -m 512 -d nochain -cdrom mcoe.1_5.iso \
  -net nic,model=tulip -net user
```

- Machine: `B160L` (HP Visualize workstation model QEMU emulates).
- Firmware: none needed — PA-RISC boots via built-in PDC (Processor
  Dependent Code), no separate ROM/BIOS blob to source.
- Threading: TCG multi-threaded accel (`-accel tcg,thread=multi`) — this is
  a non-x86 target, so no KVM; expect slow-but-usable emulation, same
  posture as the m68k/PPC/SPARC/HPPA family called out in the playbook.
- Disk: SCSI bus, target qcow2 for the install disk.
- CD: `-cdrom` for install media, `-boot d` to boot from it initially, then
  switch boot device once installed.
- NIC: `tulip` model — HP-UX's native driver expectation, not `virtio`/`e1000`.

## Graphical target

CDE on the Artist framebuffer, HP-UX's native GSP/graphics driver path under
QEMU. Resolution ceiling: **do not exceed 1280×1024** — going higher is a
known crash/hang risk and, even short of a crash, `dtwm`'s pointer cannot
reach y≥1146 at higher resolutions (a real interaction bug, not just a
cosmetic one). This ceiling is tighter and more failure-prone than most
existing CDE-family stations and needs explicit registry/geometry handling.

## Pointer and keyboard

Expect the standard relative-mouse calibration problem this lab has solved
repeatedly (`macos753`'s `cursor_scale` being the most recent worked example:
measured framebuffer gain 0.36 → `cursor_scale = 1/0.36 = 2.7778`). HP-UX/PA-RISC
under QEMU likely needs its own measured gain rather than reusing another
station's constant — pointer devices and the graphics-adapter interaction
vary per platform. To verify once a checkpoint exists: click-precision
against the CDE front panel and against dtwm's known-bad y≥1146 dead zone
above, and confirm keyboard modifier keys aren't scrambled (per the
ADD-NEW-OS-PLAYBOOK §5.1 pointer to the keys-vanishing debugging doc).

## Host-native capture plan

Tier 1, `-display dbus,p2p=on` (swap in for whatever display backend the
source writeup used) — same pattern already proven end-to-end by `macos753`,
the first foreign-arch QEMU station on this host. What carries over directly:
the dbus/p2p capture wiring itself, the general shape of "foreign-arch QEMU +
TCG + framebuffer scanout is fine for a museum tile," and the
measure-then-calibrate approach to `cursor_scale`. What's new for HP-UX: SCSI
disk wiring instead of macos753's disk bus, `tulip` NIC quirks, and the
1280×1024 ceiling being an actual crash boundary rather than just a
preference.

## Known gotchas

- **CDE login hang**: must copy `/etc/nsswitch.files` → `/etc/nsswitch.conf`
  post-install, or CDE's login manager hangs. This is a known, specific,
  named fix — not a vague "sometimes it hangs."
- **1280×1024 hard ceiling** — see Graphical target above; treat as a build
  constraint, not a nice-to-have.
- **Filesystem growth**: HP-UX's LVM needs `lvextend` + `extendfs`, not a
  generic resize; factor into the qcow2 sizing plan up front.
- **No OpenGL** — fine, CDE/Motif doesn't need it.
- **TCG speed**: expect slow boot/install, same caveat as every non-x86 QEMU
  target in this catalog; budget install time accordingly and prefer a
  scripted/unattended install path if HP-UX's installer supports one (not
  yet checked).

## 11i v1 (11.11) vs 10.20

Recommend **11.11** as primary target. The catalog's verified recipe and
writeup target 11.11 specifically, it's the newest release still reachable
on PA-RISC 1.1/32-bit media (QEMU's ceiling), and CDE is standard/complete on
11.11 whereas 10.20 predates CDE being the default desktop on many HP-UX
configs (VUE was the 10.x-era desktop in some configurations) — 11.11 gets a
cleaner, more recognizable "museum CDE" exhibit for the same or less
install effort. 10.20 is worth keeping as a fallback only if 11.11 media
turns out to be unobtainable or the install proves intractable on this box.

## Effort, risk, open questions

- **Effort**: medium (per catalog's own `effort` classification for this
  row) — multi-disc install, TCG-slow, and the resolution/nsswitch gotchas
  are known going in, which lowers risk relative to a from-scratch unknown.
- **Risk**: mainly around (a) actually sourcing and hashing 11.11 install
  media from an archival mirror — not yet done, and preservation mirrors for
  contested-commercial OSes can go stale/disappear; (b) the 1280×1024 ceiling
  being a hard crash rather than a soft limit, which constrains registry
  geometry choices; (c) recipe is from a single external writeup (Oct 2025,
  qemu 10.1) and hasn't been reproduced on this box's qemu version.
- **Open questions**:
  - Which specific ISO set from tenox.pdp-11.ru / archive.org `hpux1100` /
    hpux.connect.org.uk corresponds to a complete, installable 11.11 MCOE
    bundle, and can it be hashed against a known-good checksum?
  - Does HP-UX 11.11's installer support any unattended/scripted mode, or is
    this a fully interactive multi-stage install (affects build-script
    design)?
  - Has anyone reproduced the virtuallyfun.com recipe on qemu versions other
    than 10.1, and does `-machine B160L` exist/behave identically on this
    box's qemu build?
  - What pointer gain does this platform actually need — no measurement
    exists yet, only the general calibration method.

---

This is an unvalidated first pass written under a 5-minute research timebox —
shallow, not exhaustive. Media has not been sourced or hashed; no boot has
been attempted on this box.

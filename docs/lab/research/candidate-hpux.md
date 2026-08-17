# Candidate: HP-UX with HP VUE

**Target: HP-UX 10.20 on `qemu-system-hppa`, running HP VUE.** Tier 1, direct
framebuffer capture, no ROM. Fallback if VUE turns out to be unreachable on
10.20: HP-UX 9.x on a Series 300 under MAME (Tier 3, needs a ROM set).

**Status: nothing verified on this box.** No media sourced or hashed, no boot
attempted. Everything below is desk research — the recipe comes from an
external writeup, and the VUE-on-10.20 claim is the thing to test first.

## What the exhibit is

A visitor sees **HP VUE** — the Visual User Environment, HP's early-90s
workstation desktop: the sliding front panel with its workspace switch, the
Motif window manager underneath, HP's own file manager and toolbox. It is the
direct ancestor of CDE — HP contributed VUE as the base of the CDE standard —
so this station shows the *thing CDE was made from*, one generation earlier and
visually distinct from it.

**That distinction is the entire reason this candidate is scoped to VUE.** The
gallery already shows CDE three times (`solaris`, `tru64`, `openvms`). A fourth
CDE, however faithful, adds a vendor variation on a desktop visitors have
already seen. VUE adds a desktop they have not.

Underneath it is PA-RISC UNIX — the workstation OS of the HP 9000 line, running
on emulated HP silicon, painting into HP's built-in **Artist** framebuffer.

## Which release, and why not 11.11

VUE's lifespan decides this:

- **HP VUE 3.0 shipped with HP-UX 9.0** (July 1992) and stayed available
  through the 10.x line.
- **CDE became the default desktop in 10.20** — but VUE is still shipped and
  still selectable at the login screen.
- **VUE is gone entirely in 11.00.**

So 11.11 (11i v1) can only ever be a CDE exhibit, which is what we are
deliberately not building. It stays in `docs/catalog/os-media-catalog.md` §5 as
a catalogued OS; it is not this station.

That leaves two routes to VUE:

**Route A — HP-UX 10.20 under `qemu-system-hppa`, VUE selected at login.**
Primary. PA-RISC, Tier 1, no ROM to source, and the machine/firmware/recipe
shape is the same one the catalog already documents for 11.11, so nothing about
the QEMU side is new work. There is a published writeup of exactly this
combination — 10.20 on an emulated 9000/778 under QEMU, running VUE.

**Route B — HP-UX 9.x on an HP 9000/300-series under MAME.**
Fallback. The authentic VUE-era pairing: 9.x is the release VUE was born on,
and the desktop is VUE by default rather than by login-time choice. But it is a
68030 machine under MAME, needing the machine's ROM set, and it lands as a
**Tier 3** station following the de-bridging template — more work, slower
emulation, an extra sourcing problem. Only take this route if Route A's VUE
proves broken or absent.

**The question that decides between them:** does the 10.20 media we can source
actually include the VUE filesets, and does its login screen still offer a VUE
session? One boot answers it, and that boot should happen before any other work
on this candidate.

## Evidence from the Virtual OS Museum

VOM ships three working HP-UX installs. We take no media from it — it is a
recipe reference only, per the media rule in
[`AGENTS.md`](../../../AGENTS.md) — but its package metadata names each
install's emulator and files, and the author's screenshot filenames are
effectively his verdict on what each one reaches:

| VOM install | Family | Emulator + files | Screenshot |
|---|---|---|---|
| `hp-ux-9.10` | `hp9k68k/s300` | **MAME** — `hpux_9.10.chd`, `cfg/hp9k370.cfg`, `nvram/hp9k370/`, `roms/` | `00_VUE_with_applications.png` |
| `hp-ux-10.20` | `hp9kpa` | **QEMU** — `RUN_QEMU`, `hpux.img`, `hppa-firmware.img` | *(none)* |
| `hp-ux-11i-v1` | `hp9kpa` | **QEMU** — `RUN_QEMU` | `00_CDE_with_utilities.png` |

What this tells us:

- **Route B is corroborated**: VUE genuinely runs, on a 68k HP 9000/370 under
  MAME. If Route A fails, the fallback is known to work somewhere.
- **Route A is not corroborated**: 10.20 carries no screenshot and no recorded
  credentials, the only one of the three that doesn't. Weak evidence — possibly
  just unphotographed — but nobody has confirmed 10.20-under-QEMU for us.
- **Pin the emulator and carry a firmware blob.** VOM runs its hppa installs on
  a git build (`qemu-system-hppa-10.1.94-rc4-git-bb7fc154`) with an external
  `hppa-firmware.img` (SeaBIOS-hppa), rather than a distro package with
  built-in PDC. Expect to do the same.

## Media

Catalogued in `docs/catalog/os-media-catalog.md` §5 — note that entry is
written for 11.11, so **the media rows there are the wrong release for this
station** and 10.20 media has to be sourced separately.

- Candidate hubs: `tenox.pdp-11.ru`, archive.org, and `hpux.connect.org.uk`
  (depots plus an install walkthrough).
- Format: install ISO set, multi-disc. HP's base OS bundle is "MCOE".
- Size: roughly 1.5–2 GB.
- Licensing: **contested-commercial** — HP-UX is still owned by HPE. Archived
  copies exist on preservation mirrors; this is not officially-free. Same
  bucket as AIX, Solaris and IRIX. We source and hash it ourselves.
- **PA-RISC 1.1, 32-bit media only.** QEMU's `hppa` target does not do PA-RISC
  2.0/64-bit. This is what caps the family at 11.11 and makes 10.20 comfortably
  in range.
- For Route B, 9.x media is a *different architecture* — Series 300 is 68k, not
  PA-RISC — plus the machine ROM set.

Nothing has been downloaded or hashed yet.

## Emulator, machine, boot recipe

Route A, adapted from the catalog's 11.11 recipe (virtuallyfun.com, Oct 2025,
qemu 10.1 — works-known elsewhere, unverified here):

```
qemu-system-hppa -machine B160L -smp cpus=4 -accel tcg,thread=multi \
  -boot d -drive if=scsi,bus=0,index=6,file=hpux.qcow2,format=qcow2 \
  -m 512 -d nochain -cdrom <install>.iso \
  -net nic,model=tulip -net user \
  -display dbus,p2p=on
```

- **Machine** `B160L`, an HP Visualize workstation. VOM's 10.20 install uses
  the same `hp9kpa` family.
- **Firmware**: PA-RISC boots via built-in PDC, so no ROM to source — but see
  the VOM note above about carrying an explicit `hppa-firmware.img`.
- **Accel**: TCG only (non-x86 target), multi-threaded. Slow but usable, same
  posture as every foreign-arch station here.
- **Disk** on SCSI; **NIC** must be `tulip` (HP-UX's native driver
  expectation), not virtio/e1000.

## Graphical target

VUE over the Artist framebuffer. **Do not exceed 1280×1024** — beyond it is a
known crash risk, and short of a crash the window manager's pointer cannot
reach y≥1146, which is an interaction bug rather than a cosmetic one. Treat
this as a hard build constraint on registry geometry.

## Pointer and keyboard

Relative mouse, so this needs the measured `cursor_scale` calibration the lab
has done repeatedly — `macos753` is the most recent worked example (measured
gain 0.36 → `cursor_scale` 2.7778). The gain must be **measured for this
platform**, not borrowed: it varies with the pointer device and graphics
adapter. Verify against VUE's front panel for click precision, against the
y≥1146 dead zone above, and check modifier keys aren't scrambled (see
ADD-NEW-OS-PLAYBOOK §5.1).

## Host-native capture plan

Tier 1, `-display dbus,p2p=on`. `macos753` already proved this exact shape on
this host — foreign-arch QEMU under TCG, dbus scanout, measured pointer
calibration — so the capture side is not new work.

New for HP-UX: SCSI disk wiring, `tulip` NIC quirks, and the 1280×1024 ceiling
being a real crash boundary rather than a preference.

Route B would instead be Tier 3 — MAME on the host with its video backend off,
following `docs/lab/DEBRIDGE-CONVERSION-BRIEF.md`: shared `x11-runtime.sh`,
KEYDUMP-generated keymap, `SAVEST golden` checkpoint (subject to the driver
setting `MACHINE_SUPPORTS_SAVE`).

## Known gotchas

- **CDE/VUE login hang**: copy `/etc/nsswitch.files` → `/etc/nsswitch.conf`
  after install or the login manager hangs. Named, specific, known.
- **1280×1024 ceiling** — above.
- **Filesystem growth** goes through LVM: `lvextend` + `extendfs`, not a
  generic resize. Size the qcow2 accordingly up front.
- **No OpenGL** — irrelevant for VUE/Motif.
- **TCG speed**: slow install. Budget for it, and check whether HP-UX's
  installer has any scripted/unattended mode.

## Effort, risk, open questions

**Effort**: medium. Multi-disc interactive install, TCG-slow, but the QEMU
shape is documented and the gotchas are known going in.

**Risks**, in the order they would bite:

1. **VUE may not be reachable on the 10.20 media we source** — the assumption
   the whole station rests on, and the cheapest to test.
2. **Media sourcing**: 10.20 is a different release from the catalogued 11.11
   rows, and preservation mirrors for contested-commercial OSes go stale.
3. **Recipe reproducibility**: single external writeup on qemu 10.1, not yet
   reproduced on this box's QEMU, and VOM's use of a pinned git build hints
   that the version matters.
4. **The 1280×1024 ceiling** constrains geometry choices harder than most
   stations.

**Open questions**:

- Which specific 10.20 ISO set is complete and installable, and can it be
  hashed against a known-good checksum?
- Does 10.20's `dtlogin` offer a VUE session out of the box, or does VUE need
  installing/selecting explicitly from the media?
- Does `-machine B160L` behave identically on this box's QEMU build, or do we
  need to pin a version and carry `hppa-firmware.img` as VOM does?
- What pointer gain does this platform need? No measurement exists.
- For Route B: is HP 9000/370 ROM material sourceable, and does MAME's driver
  set `MACHINE_SUPPORTS_SAVE` (i.e. can the station have a checkpoint at all)?

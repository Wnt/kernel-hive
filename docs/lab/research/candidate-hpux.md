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
combination — 10.20 on an emulated 9000/778 under QEMU, running VUE. The
Virtual OS Museum reinforces this from a different angle: its 10.20 and 11i v1
installs are configured *identically* — same machine, same emulator, same
flags, same firmware — so the QEMU side of Route A is exercised and working in
a real install, just under a different disk image than the one we'd boot.

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
install's emulator, machine and flags, and the author's screenshot filenames
are effectively his verdict on what each one reaches:

| VOM install | Family | Emulator + config | Screenshot |
|---|---|---|---|
| `hp-ux-9.10` | `hp9k68k/s300` | **MAME 0.238**, driver `hp9k370` (HP 9000/370, Series 300), mouse enabled, HIL keyboard `hp_46021a`, HP 98643 LAN card in slot 2 | `00_VUE_with_applications.png` |
| `hp-ux-10.20` | `hp9kpa` | **QEMU**, machine `B160L`, 4 CPUs, 512 MB, SCSI index 6, `tulip` NIC, explicit `hppa-firmware.img`, `-d nochain`, TFTP enabled | *(none)* |
| `hp-ux-11i-v1` | `hp9kpa` | **QEMU**, same machine/CPU/RAM/SCSI-index/NIC/firmware/`-d nochain` as 10.20 | `00_CDE_with_utilities.png` |

What this tells us:

- **Route B is corroborated in detail**: VUE genuinely runs, on a 68k HP
  9000/370 under MAME 0.238 with driver `hp9k370`, HIL keyboard `hp_46021a`,
  and an HP 98643 LAN card in slot 2. If Route A fails, the fallback is known
  to work somewhere, with a concrete config to start from.
- **Route A is mechanically corroborated, VUE itself is not.** 10.20 carries no
  screenshot, but its QEMU configuration is *identical* to the 11i v1 install
  that does have one — same `B160L` machine, same 4 CPUs/512 MB, same SCSI
  index 6, same `tulip` NIC, same explicit firmware, same `-d nochain`. Only
  the disk image differs. So the emulator/machine/firmware stack is proven to
  boot HP-UX on this hardware; what's still unconfirmed is narrower than it
  looked — specifically whether the VUE session is present and selectable on
  the 10.20 media, not whether 10.20-under-QEMU works at all.
- **Pin the emulator and carry a firmware blob.** VOM runs both hppa installs
  on a pinned git build (`qemu-system-hppa-10.1.94-rc4-git-bb7fc154`), not a
  release, with an external `hppa-firmware.img` (SeaBIOS-hppa) rather than a
  distro package's built-in PDC. Expect to pin a version and carry firmware the
  same way rather than relying on whatever `qemu-system-hppa` the distro ships.
- **`-d nochain` is a known-needed workaround, not a stray debug flag.** Both
  hppa installs set it, and it disables TCG translation-block chaining — a
  real speed cost, paid deliberately. Worth finding out *why* it's needed
  before assuming we must carry it too.

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
qemu 10.1) and now doubly grounded — the same shape is also what the Virtual
OS Museum runs for both of its working hppa installs. Our own recipe, in our
own words: `qemu-system-hppa` on machine `B160L`, 4 vCPUs, multi-threaded TCG,
512 MB RAM, system disk as qcow2 on the SCSI bus at index 6, a `tulip` NIC on
user networking, QEMU pointed at an explicit `hppa-firmware.img` rather than
its built-in PDC, `-d nochain` set, plus our own `-display dbus,p2p=on` for
host-native capture.

- **Machine** `B160L`, an HP Visualize workstation, `hp9kpa` family — the same
  machine the Virtual OS Museum uses for both its 10.20 and 11i v1 installs.
- **Firmware**: PA-RISC boots via built-in PDC, but both of VOM's working hppa
  installs instead point QEMU at an explicit `hppa-firmware.img`
  (SeaBIOS-hppa). Treat that as required, not optional, until proven otherwise.
- **`-d nochain`**: disables TCG translation-block chaining. A known-needed
  workaround in the corroborated configs, at a real speed cost. Why it's
  needed here is still open — see below.
- **Accel**: TCG only (non-x86 target), multi-threaded. Slow but usable, same
  posture as every foreign-arch station here.
- **Disk** on SCSI at index 6; **NIC** must be `tulip` (HP-UX's native driver
  expectation), not virtio/e1000.
- **RAM**: 512 MB, 4 vCPUs — both corroborated configs agree on this, so it's
  a safe default rather than a guess.

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
setting `MACHINE_SUPPORTS_SAVE`). The corroborated config to start from is
driver `hp9k370` with the HIL keyboard `hp_46021a` and mouse enabled, plus an
HP 98643 LAN card in slot 2 if network is wanted.

## Known gotchas

- **CDE/VUE login hang**: copy `/etc/nsswitch.files` → `/etc/nsswitch.conf`
  after install or the login manager hangs. Named, specific, known.
- **1280×1024 ceiling** — above.
- **Filesystem growth** goes through LVM: `lvextend` + `extendfs`, not a
  generic resize. Size the qcow2 accordingly up front.
- **No OpenGL** — irrelevant for VUE/Motif.
- **TCG speed**: slow install. Budget for it, and check whether HP-UX's
  installer has any scripted/unattended mode.
- **Route B boot-ROM input hang**: pressing keys or moving the mouse while the
  MAME `hp9k370` boot ROM is still searching for a boot disk can hang the
  boot. Directly threatens any automated type-at-boot or early-input behaviour
  a station might have — Route B needs to stay hands-off until the boot disk
  is found.

## Effort, risk, open questions

**Effort**: medium. Multi-disc interactive install, TCG-slow, but the QEMU
shape is documented and the gotchas are known going in.

**Risks**, in the order they would bite:

1. **VUE may not be present or selectable on the 10.20 media we source** — the
   platform underneath is now mechanically corroborated (same machine, RAM,
   firmware and flags as the working 11i v1 install), so this narrows to a
   media/fileset question rather than a QEMU-side one, but it's still the
   assumption the whole station rests on, and the cheapest to test.
2. **Media sourcing**: 10.20 is a different release from the catalogued 11.11
   rows, and preservation mirrors for contested-commercial OSes go stale.
3. **Recipe reproducibility**: the corroborated configs (VOM and the
   virtuallyfun.com writeup) run a pinned QEMU git build with a carried
   firmware image and `-d nochain` set, not yet reproduced on this box's QEMU.
   Budget for pinning a version rather than using the distro package.
4. **The 1280×1024 ceiling** constrains geometry choices harder than most
   stations.

**Open questions**:

- Which specific 10.20 ISO set is complete and installable, and can it be
  hashed against a known-good checksum?
- Does 10.20's `dtlogin` offer a VUE session out of the box, or does VUE need
  installing/selecting explicitly from the media?
- Why does `-d nochain` matter here — what does it work around, and does this
  box's QEMU need it too?
- Does `-machine B160L` behave identically on this box's QEMU build, or do we
  need to pin the same git build VOM and the writeup use and carry
  `hppa-firmware.img` alongside it?
- What pointer gain does this platform need? No measurement exists.
- For Route B: is HP 9000/370 ROM material sourceable, and does MAME's
  `hp9k370` driver set `MACHINE_SUPPORTS_SAVE` (i.e. can the station have a
  checkpoint at all)?

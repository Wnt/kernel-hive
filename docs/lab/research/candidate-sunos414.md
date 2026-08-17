# Candidate: SunOS 4.1.4 / Solaris 1.1.2 (OpenWindows / OpenLook)

**Target: SunOS 4.1.4 on `qemu-system-sparc -M SS-5` with `-vga cg3`, running
OpenWindows 3.x.** Tier 1, direct framebuffer capture, no PROM to source.
Fallback if the QEMU/OpenBIOS path proves harder than the catalog's score
suggests: SunOS 4.1.4 on a sun4c under TME with real Sun PROM dumps (Tier 3,
host-native).

**Status: nothing verified on this box.** No media sourced or hashed, no boot
attempted. The QEMU recipe below comes from the catalog's already-verified
entry; everything else, including the registry id (`sunos414` vs `sunos4`,
pick at scaffold time), is desk research.

## What the exhibit is

Sun's classic BSD-derived UNIX on SPARC, running **OpenWindows 3.x**, the
pre-CDE desktop built on the **OpenLook** toolkit (`olwm` window manager,
diagonal-hatch three-dimensional widgets, the pinnable workspace menu). This
is what Sun workstations looked like from the late 1980s through ~1995,
before Sun adopted CDE/Motif for Solaris 2.x.

The existing `solaris` station is Solaris (SVR4) on SPARC running CDE —
Motif widgets, the CDE front panel, a desktop that looks close to
HP-UX/AIX/Tru64's CDE. The gallery is deliberately steering away from more
CDE, and that is what makes this candidate the point of the slot: OpenLook is
angular/beveled rather than Motif's shaded 3D, has no front panel, and
represents the *other* branch of Sun's desktop history (NeWS-derived OPEN
LOOK vs. OSF/Motif). Placing both side by side tells the "Sun's own desktop
before CDE won" story — same vendor, same SPARC silicon, different toolkit
war outcome.

## Emulator, machine, boot recipe

```
qemu-system-sparc -M SS-5 -m 256 \
  -vga cg3 \
  -drive file=sunos414.qcow2,if=scsi,bus=0,unit=0,media=disk \
  -drive file=sunos_4.1.4_install.iso,if=scsi,bus=0,unit=2,media=cdrom \
  -net nic,model=lance -net user
```

From `docs/catalog/os-media-catalog.md` §5, works-known elsewhere — treat
that score as **unproven until someone boots it here** (see Evidence,
below).

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
  is the single most likely way to get a black screen that looks like a boot
  failure but is actually a missing video driver.
- Firmware: none to source on this route — QEMU's OpenBIOS covers SPARC
  boot.

## Evidence from the Virtual OS Museum

VOM ships a working SunOS 4.1.4 install. We take no media from it — recipe
reference only, per the media rule in [`AGENTS.md`](../../../AGENTS.md).
These notes come from its *package metadata* (dpkg file lists on the host
rootfs), which names the emulator and firmware files, plus the author's own
screenshot filenames; the boot scripts themselves live on the 173 GB
guest-image disk, which has not been extracted, so exact command lines are
inferred from filenames, not read.

- **VOM does not use QEMU for this OS.** The install
  (`sun4/.../sunos_4.1.4_config/`) runs under **TME (The Machine Emulator)**
  — config `config.tmesh` — on a host that carries `tmesh`,
  `tme-sun-eeprom`, `tme-sun-idprom`.
- **The machine is a sun4c** (`sun4-75-rev-2.9.bin` = SPARCstation 2), driven
  by **real Sun PROM dumps** (`SUNW,501-1415.bin`, `SUNW,501-1561.bin`) and a
  hand-built NVRAM image (`my-sun4c-nvram.bin`) — not OpenBIOS.
- **This is the important part.** VOM has `qemu-system-sparc-5.2.0`
  installed and uses it for its Solaris entries, yet chose TME + real PROMs
  specifically for SunOS 4.1.4. That is circumstantial evidence that the
  QEMU/OpenBIOS `-M SS-5` path is harder than the catalog's "works-known"
  score implies — the author had QEMU available and passed on it for this
  OS.
- **What the fallback would cost us.** TME is not QEMU, so a sun4c station
  lands as **Tier 3** (host-native, per the de-bridging template) rather
  than Tier 1, and it trades "no firmware to source" for a real-PROM
  sourcing problem the QEMU route does not have.
- **Corroboration the exhibit is worth building**, independent of which
  emulator wins: `00_OpenWindows_with_terminal_,_help_,_and_file_manager.png`
  and `01_OpenWindows_SunView_compatibility.png` show a live, working
  OpenWindows desktop.
- `sun-keyboards.txt` and `my-sun-macros.txt` sit beside the config — Sun
  keyboard mapping is evidently fiddly enough that the author kept notes.
- One more cross-link worth noting: this install also carries Xerox
  GlobalView on top of SunOS (a `dmachine` dependency and
  `PASSWD.pilot_globalview_1.05_x`) — a direct tie to our existing `star`
  and `daybreak` Xerox stations.

## Media

From `docs/catalog/os-media-catalog.md` §5 (already catalogued, reuse
as-is; URLs not re-checked live for this rewrite):

| | |
|---|---|
| Candidates | https://winworldpc.com/product/sun-solaris/1x ; https://fsck.technology/software/Sun%20Microsystems/SunOS%20Install%20Media/ (marked checked in the catalog) |
| Format | install CD ISO |
| Size | ~500 MB – 1 GB |
| Licensing | **contested-commercial** — say so plainly in the guest doc; source and hash ourselves per project rule, never take media from the `vom-repo` collection on this box |
| Firmware | none needed on the QEMU route — OpenBIOS covers SPARC boot |
| Catalog's own difficulty/priority | medium / MV 5 |

## Graphical target

OpenWindows is not started automatically at console login on a stock
install — `/usr/openwin/bin/openwin` is the launcher and it is **not on
`PATH`** by default. The checkpoint/launcher will need to either invoke that
path directly or arrange autostart (`.xinitrc`/inittab entry) so the
streamhost captures a live desktop rather than a bare console login.
Resolution/depth of the OpenWindows session is unverified — likely
constrained by whatever `cg3` exposes (cg3 historically tops out at 8-bit
color) — and needs confirming against an actual boot.

## Pointer and keyboard

- Expect the same relative-mouse story as other SPARC/QEMU stations: QEMU's
  SPARC pointer input is relative, so the streamhost side needs a
  `cursor_scale` calibration pass against the guest's actual pointer
  acceleration. Copy the `solaris` station's calibration approach rather
  than re-deriving it, but confirm the value transfers — SunOS 4.1.4's older
  mouse driver may need its own pass.
- Sun type-4/5 keyboard layout differences (compose key, `Stop`/`Again`
  L-keys, different placement of some punctuation) are a known class of
  gotcha on Sun guests generally. Check `solaris`'s keyboard notes first;
  unverified whether SunOS 4.1.4 under QEMU needs any remap beyond what that
  station already solved.

## Host-native capture plan

Tier 1 (direct QEMU) on the primary route, same as `solaris`: `-display
dbus,p2p=on`, no bridge, no kiosk VM. streamhost needs the usual per-station
`station.env`, a signaling entry, framebuffer capture off the `cg3` surface,
and the same input-forwarding path already proven for other SPARC/QEMU
stations — a cheap addition riding on infrastructure that already exists for
`solaris`.

The TME/sun4c fallback is Tier 3 instead: a non-QEMU emulator, host-native
per `docs/lab/DEBRIDGE-CONVERSION-BRIEF.md`, plus the real-PROM sourcing
problem noted above. Only take this route if the QEMU path proves broken —
one boot attempt on the primary recipe should decide it.

## Known gotchas

- **TCG, not KVM**: SPARC guests on an x86_64 host run under QEMU's software
  emulator (TCG). Expect meaningfully slower boot/install and possibly
  visible input lag versus the KVM-accelerated x86 stations — budget more
  wall-clock time for the install and checkpoint capture.
- **Disk geometry / `format`+`suninstall`**: SunOS 4.1.4 install is
  old-school Sun `suninstall`, which wants to partition via `format` with
  SunOS-native disk labels (not a modern partition table). Getting the
  target `.qcow2` disk labeled and sliced correctly before/during install is
  a known sharp edge on this OS family; expect to walk the `format` menu
  interactively rather than fully unattended.
- **OpenBIOS quirks**: QEMU's `sun4m` OpenBIOS is not a bit-perfect Sun
  OpenBoot clone; boot-arg syntax and device paths sometimes differ from
  real-hardware docs of the era. Treat any SunOS-4.1.4-on-real-hardware
  install guide as approximate, not literal, for the OpenBIOS boot prompt.
- `-vga cg3` is the single most likely first failure mode for anyone
  reproducing this from scratch — see above.

## Effort, risk, open questions

**Effort**: catalog rates it "medium" difficulty, MV 5 (matches other Tier-1
SPARC/legacy-UNIX adds) — on the assumption the QEMU route holds. VOM's
choice of TME for this exact OS is a reason to treat that assumption as
unconfirmed rather than settled.

**Risks**, in the order they would bite:

1. **The QEMU/OpenBIOS path may not reach a working OpenWindows desktop at
   all** — VOM's avoidance of it, despite having QEMU installed, is the
   specific reason to doubt the catalog's "works-known" score. Cheapest to
   test: one boot attempt on the recipe above.
2. **Disk labeling via `format`** is the most likely place to get stuck if
   the boot itself works.
3. **TCG slowness** could make the install session long.
4. **Media sourcing**: contested-commercial, preservation mirrors for OSes
   in this bucket go stale; the WinWorld/fsck.technology URLs need a live
   re-check and an actual hash.

**Open questions**:

- Does `qemu-system-sparc -M SS-5` with `-vga cg3` actually reach a working
  OpenWindows desktop, or does it hit whatever problem made VOM choose TME
  instead?
- What resolution/depth does `cg3` actually give OpenWindows, and is it
  fixed or configurable?
- Does the existing `solaris` station's `cursor_scale` value transfer
  directly, or does SunOS 4.1.4's older mouse driver need its own
  calibration pass?
- Any keyboard remap needed beyond what `solaris` already solved?
- If the QEMU route fails: is sun4c PROM material (`SUNW,501-1415.bin`,
  `SUNW,501-1561.bin` or equivalent dumps) sourceable independent of VOM,
  and is TME buildable/packaged on this host?

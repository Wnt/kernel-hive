# netbsd14 wave — NetBSD 1.4.1 i386 (1999), XFree86 3.3 desktop, absolute pointer

Operator ask (2026-09-02): "a new record in how fast we can integrate a new
station … NetBSD from 1995–1999 with graphical interface and absolute cursor".
Procedure: `docs/lab/ADD-NEW-OS-PLAYBOOK.md` §0. Sibling: `pcgeos` (device set),
`sunos414` (pointer route).

## Allocation ledger (claimed by smoke-rig under KH_SESSION=netbsd14)

| Value | Assigned |
|---|---|
| id / stationDir / SH_STATION | `netbsd14` |
| slot / UDP / VMID | 176 / 54176 / 176 |
| X forward (host loopback → guest) | 127.0.0.1:6076 → 10.0.2.15:6000, `SH_X11WARP_DISPLAY=127.0.0.1:76` |
| render orders | as assigned by `stations-registry.py new --like pcgeos` |
| QEMU | `/opt/qemu-beos/bin/qemu-system-x86_64`, `pc-i440fx-11.0,acpi=off`, KVM, `-cpu host`, 128 MB, 1 vCPU, `-vga cirrus`, one IDE qcow2, `ne2k_pci` on SLIRP |
| Release | NetBSD 1.4.1 (1999-08-26), i386, XFree86 3.3.3.1 (the X sets shipped with 1.4.1) |
| Media | `archive.netbsd.org/pub/NetBSD-archive/NetBSD-1.4.1/i386/`: `installation/floppy/boot.fs` (1 474 560 B) + `binary/sets/{base,comp,etc,games,kern,man,misc,text,xbase,xcomp,xcontrib,xfont,xserver}.tgz`; all 13 sets verify against the archive `MD5`; staged in `/data/assets-staging/netbsd14/` with `MANIFEST.sha256` |
| Install medium | sets composed into `sets.iso` (`genisoimage -R -J`, tree `i386/binary/sets/`, 61 026 304 B) attached as the IDE CD; sysinst "CD-ROM" source, device `cd0`, dir `/i386/binary/sets` |
| Smoke rig | `/data/vms/sandbox/netbsd14/smoke/` (`launch-smoke.sh [a|c]`, `run-daemon.sh`), published at `/os/netbsd14` |

Measured on the smoke boot (framebuffer, 720x400 text): kernel probes `wd0`
(IDE), `cd0`, `ne2` (RTL8029), `pc0` (**pccons**, not wscons), `com0`, `fdc0`;
sysinst main menu ~25 s after power-on. No `pms0` line was seen on the INSTALL
kernel — the golden stream verifies the PS/2 mouse on GENERIC (fallback:
`-chardev msmouse` serial mouse on `com0`, XFree86 protocol `Microsoft`).

## Streams (each `wt.sh new netbsd14-<stream> --from netbsd14`, 4-minute stop except golden)

| Stream | Model | Owns |
|---|---|---|
| golden | Fable | the smoke rig: sysinst install, XF86Config (cirrus), console autologin → `xinit` ctwm session, `xhost +10.0.2.2`, bake `golden` with the station launcher, one `loadvm` proof, stage `disk.qcow2` into the station dir, `station.env.fixture` checkpoint facts, `registry` runtime/reset truth |
| build | sonnet-low | `scripts/build-guests/tiles/netbsd14.sh`, `check-assets.sh`, `ASSETS-MANIFEST.md`, `os-media-catalog.md` |
| spa | Fable | `registry/posters/netbsd14.md`, hero + frames, `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`, `museum`/`spa`/`demoProgram` |
| docs | sonnet-low (after golden) | `docs/guests/netbsd14.md`, `GUEST-TIERS.md`, release notes, `docs/README.md` |

## The wall, and the race that solved it (2026-09-03)

The installed GENERIC kernel hangs in autoconf right after
`lpt0 at isa0 port 0x378-0x37b irq 7`; the INSTALL floppy kernel probes fine.
The golden stream bisected it serially (reboot, guessed sleep, look) and was
stopped; the operator's rule from this is AGENTS.md rule 14 / OPERATING-RULES
§13, with `scripts/dev/rig-clone.sh` + `scripts/dev/fb-wait.py` written on the
spot. Two rounds of cheap runners (`sonnet-low`, one clone each, 0.6 s to clone):

| Theory | Result | Evidence |
|---|---|---|
| userconf `disable wdc0/wdc1` (ISA IDE vs pciide) | blocked by method | **1.4.1 has no userconf**: the boot block rejects `-c` (`boot [xdNx:][filename] [-adrs]`) |
| userconf `disable pcic*` | blocked by method | same |
| userconf disable every optional ISA device | blocked by method | same |
| KVM-specific: `-accel tcg -cpu pentium` | LOSS | identical hang under TCG |
| Sound Blaster probe spinning: `-device sb16` at 0x220 | LOSS | identical hang, no `sb0` line |
| pciide port conflict: `-machine isapc` (IDE on ISA) | LOSS, but decisive | `wdc0 at isa0` attached BEFORE `lpt0` there and the hang stayed after `lpt0` — IDE is exonerated |
| INSTALL kernel from the floppy, `boot -a`, root `wd0a` | **WIN** | full multiuser boot of the installed disk (`evidence/instk-boot-a-wd0a-multiuser.png`) — the enabler for an in-guest kernel build |

Round 3 — **WIN: `KHMIN`** (`scripts/build-guests/tiles/netbsd14/KHMIN`), built in-guest from the INSTALL ramdisk chroot and booted from `wd0` to the wscons `login:`; `KHCONS` never built (its runner stayed on the multiuser route, where every CD mount and TFTP transfer hangs). Two `sonnet` runners built custom kernels
in-guest from `syssrc.tgz` (14 234 946 B, staged) on a second CD (`extras.iso`):
`KHCONS` = GENERIC minus the ISA devices INSTALL lacks (sound, bus mice,
joystick, tape, mcd, nca, lpt1/lpt2) and `KHMIN` = only the ISA devices the
emulated PC has. Whichever boots past `lpt0` ships as `/netbsd`
(GENERIC kept as `/netbsd.GENERIC`). Mouse: GENERIC 1.4.1 has `opms* at pckbc?`
(the XFree86-3.3 PS/2 `/dev/pms0`), kept in both.

Trap met in round 3: a SECOND IDE CD (`-drive ...,media=cdrom,index=3` → `cd1`) mounts forever under the INSTALL kernel — no error, the shell blocks in the syscall. Serve everything from the one `-cdrom` slot (`cd0`, which sysinst mounted fine).

Disk layout (sysinst "standard with X"): wd0a=/ 277 MB, wd0b=swap 513 MB, wd0e=/usr 1257 MB — a chroot from the INSTALL ramdisk must mount BOTH wd0a and wd0e, or every /usr tool reads as missing. The ramdisk route (sysinst Utility menu → Run /bin/sh → mount → chroot) needs no `boot -a` dance and its CD mount does not hang.

A hung guest is not idle: the GENERIC kernel spinning after `lpt0` burned 91 % of a core for 55 minutes in the forgotten smoke rig (box load 57 on 16 cores, coordinator alert). Kill a loser or a stale rig the minute its verdict is in — `rig-clone.sh down --rm`, `smoke-rig.sh --down`.

Two more facts from the X step: the QEMU cirrus BitBLT path leaves client text unpainted under XFree86 3.3 — `Option "no_bitblt"` (found by the slackware wave); and a kernel with fewer `ne` instances renames the NIC (`ne2` under GENERIC → `ne0` under KHMIN), so a per-interface config file written for one kernel silently does nothing under the other — the guest had no IP and every X-forward probe died in SYN_SENT.

Rule for the next OS: a theory list must first name the MECHANISM each theory
needs (here: userconf), and one runner tests the mechanism before three depend
on it.

## Timeline (measured after landing with session-timeline.py)

TODO(coordinator)

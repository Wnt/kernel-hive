# macosx wave — Mac OS X on PowerPC (issue #50, record wave 2026-09-21, Lane C)

**STATUS: PAUSED BEFORE INSTALL, by coordinator instruction** (labhost 1-min
load 116 against the documented cap of 50 — see `docs/lab/OPERATING-RULES.md`
"The load rule"). Nothing here is landed, nothing is live. This file is written
so the stream can be *resumed* rather than restarted: every fact below was
measured on a framebuffer or with `stat`/`sha256sum`, and the two expensive
questions this station was expected to burn an hour on are already answered.

## Allocation ledger

| Station | Session | Slot / UDP / VMID | X-warp | retronet (addr / tap / chain / UIN) |
|---|---|---|---|---|
| macosx | macosx-work | 212 / 54212 / 212 | — | — |

No `--retronet` and no `--x11warp` were taken: the integration seed scopes the
first release as an ordinary offline station, and OS X drives QEMU's tablet
natively so no X-warp display is needed.

Claims were **released** when the stream stood down (see §Teardown).

## Media (measured on the box, not copied from a README)

Both images came from the Internet Archive item `cheetah-to-tahoe-mac.os.x`
("Apple mac OS X - 2001 to 2026"), which carries retail PowerPC install discs.

| File | Bytes | SHA-256 | Upstream |
|---|---|---|---|
| `jaguar-10.2-cd1.iso` | 655364096 | `e0891480aa027069fafb94f8a951a2c115e52551efdd2b6b6e7e3212139d25d2` | `archive.org/download/cheetah-to-tahoe-mac.os.x/2002 - Mac OS X Jaguar 10.2.iso` |
| `panther-10.3-cd1.iso` | 679043072 | `5383331ad0850f03859be5a79101d6ebc1e9fe4d7379328c46362d5620aa45cb` | `archive.org/download/cheetah-to-tahoe-mac.os.x/2003 - Mac OS X Panther 10.3.0 - Disk 1.iso` |

Staged at `/data/assets-staging/macosx/`. Both are genuine Apple Partition Map
hybrid discs (`file` reports `Apple_Driver43_CD` / `Apple_Patches` partitions),
so OpenBIOS boots them directly from `-boot d` with no `boot cd:,\\:tbxi`
incantation.

Panther is a three-disc set. **Only disc 1 is staged.** Disc 2 and 3 carry the
bundled applications and extra printer/language packages; a minimal install
that stops at disc 1 is expected to be enough for the intended scene (Finder,
Dock, Terminal, System Preferences) — but that is an assumption, not a
measurement, and it is the first thing the resumed stream will find out.

## The release race — Jaguar LOSES, Panther WINS (decided on the framebuffer)

Both ISOs were raced on identical device sets, one clone each
(`ptrA`, `ptrB` under `/data/vms/sandbox/macosx-work/`), per AGENTS.md rule 14.

**Mac OS X 10.2 Jaguar panics, reproducibly.** ~50 s into a CD boot it drops the
four-language "You need to restart your computer" panel. Booted verbose
(`-prom-env 'boot-args=-v'`) the panic names itself:

```
Darwin Kernel Version 6.0: Sat Jul 27 13:18:52 PDT 2002; root:xnu/xnu-344.obj~1/RELEASE_PPC
Exception state (sv=0x20011500)
  PC=0x00219DF8; ... DSISR=0x40000000; ... (0x300 - Data access)
Kernel loadable modules in backtrace (with dependencies):
  com.apple.iokit.IOSCSIMultimediaCommandsDevice(1.2.0)
    dependency: com.apple.iokit.IODVDStorageFamily(1.2)
    dependency: com.apple.iokit.IOCDStorageFamily(1.2)
    dependency: com.apple.iokit.IOSCSIArchitectureModelFamily(1.2.0)
panic: We are hanging here...
```

That is Jaguar's ATAPI/optical stack faulting on QEMU's emulated CD device, not
a CPU, RAM or firmware problem — so the usual knobs (`-cpu`, `-m`, `via=`) are
the wrong things to bisect. The frame is the proof; the non-verbose panel is
not, because it names nothing.

**Mac OS X 10.3.0 Panther boots the same device set clean.** Painted Aqua
installer ("Install Mac OS X", Select Language, English preselected) in
**~7 minutes** of TCG wall-clock on a box already at load ~110.

Registry identity therefore follows Panther: **Mac OS X 10.3 Panther, 2003**,
not the seed's provisional Jaguar/2002.

## The pointer race — `usb-tablet` WINS, and this is the headline finding

macos9, the closest sibling, is a *relative* pointer station: Mac OS 9 has no
driver for QEMU's `usb-tablet`, so it runs the daemon's abs->rel bridge at
`SH_CURSOR_SCALE=5.5556` with a re-home-on-reset hack. macos9's launcher
additionally warns that adding a second USB HID behind `via=pmu` splits QEMU's
input routing and sends clicks nowhere — an hour of that station's bring-up.

**That warning does not carry over to Mac OS X.** Raced as two clones on the
Panther installer:

* QMP `abs` to (200,150) → guest arrow rendered at (200,150).
* QMP `abs` to (800,600) → guest arrow rendered at (800,600).
* A click at the Continue button's own coordinates activated Continue; later
  clicks drove the Installer menu, "Open Disk Utility…", Disk Utility's
  Partition tab, two popup menus and the Partition confirmation sheet — every
  one landed on the control it was aimed at.
* `Cmd-A` then typed text replaced the volume name field, and `Cmd-Q` quit Disk
  Utility, so the built-in `via=pmu` keyboard works alongside the tablet.

So macosx is the museum's **first mac99 station with a true absolute pointer**:
unity scale, no bridge, no reset teleport. Frozen into
`streamhost/stations/macosx/station.env.fixture`.

OPEN: the formal five-target accuracy sweep and the exact hotspot offset were
not run — they belong on the installed Aqua desktop, not on the installer, and
the stream was paused first. The two points above agree with 1:1 at offset 0 to
within the arrow glyph, which is why the fixture ships `SH_CURSOR_SCALE=1.0`
and `SH_CURSOR_OFF_{X,Y}=0` as the starting hypothesis to be *verified*, not as
a measured constant.

## Frozen device set (complete, before any `savevm golden`)

```
/opt/qemu-ppc/bin/qemu-system-ppc
  -name streamhost-macosx
  -accel tcg -m 1024
  -M mac99,via=pmu -cpu g4
  -g 1024x768x32
  -display dbus,p2p=on
  -nic none
  -device usb-tablet
  -drive file=$D/macosx-golden.qcow2,format=qcow2,cache=writeback,aio=threads
  [-loadvm golden -S when the checkpoint exists]
  -qmp unix:$D/qmp.sock,server=on,wait=off -pidfile $D/qemu.pid
```

RAM is 1024 MB, not macos9's 512: Mac OS X is a Mach/BSD system with a real VM
subsystem, and a guest that swaps under TCG is a guest that never finishes.
This is the COMPLETE intended first-release set — pointer backend and NIC
decision both included — so the first golden bake does not owe a re-bake.

## Install throughput — measured, and NOT the wall

The playbook says to time the installer's first disk write in the spine, because
a pathological write path (debian22's 27 KB/s 16-bit PIO) must be raced rather
than waited out. Measured here:

* Disk Utility partition + HFS+ (non-journaled) format of the 12 GB qcow2:
  **32 s wall, 19,464,192 bytes materialised in the qcow2.**

That is a healthy path. **Mac OS X on mac99 is CPU-bound under TCG, not
I/O-bound** — so the resumed stream should not spend an agent racing disk
transports, and should instead expect the package copy to be paced by
emulation speed and by whatever else is running on the box.

Journaling was deliberately switched off at format time ("Mac OS Extended", not
"Mac OS Extended (Journaled)") to cut write amplification during the install.

## Exactly where this stopped

The rig `ptrA` was at the installer's **Select a Destination** step with a
formatted, mounted `Macintosh HD` (11.87 GB) already visible and just selected.
The Mac OS X package copy had **not begun** — which is why killing the guest was
cheap and was done rather than escalated.

`/data/vms/sandbox/macosx-work/ptrA/macosx.qcow2` still holds that partitioned,
formatted, empty `Macintosh HD`. It is a plain file and it survives; a resumed
stream can boot the Panther CD against it and skip Disk Utility entirely.

## Next concrete step for whoever resumes this

1. Relaunch `ptrA` on the frozen device set above with
   `-drive file=/data/assets-staging/macosx/panther-10.3-cd1.iso,format=raw,media=cdrom -boot d`
   (the rig's own `run-rig.sh` in the sandbox already does exactly this, given
   `ISO=` and `-device usb-tablet`).
2. Skip Disk Utility — `Macintosh HD` is already there.
3. At **Installation Type**, click **Customize** and deselect the optional
   package groups (additional print drivers, additional Asian fonts, localized
   files, bundled applications). Under TCG every deselected megabyte is wall
   clock, and none of it appears in the intended scene.
4. Install, then first boot, then walk the Setup Assistant (create the visitor
   account, decline registration/.Mac) — the fixture's scene explicitly
   requires the Setup Assistant to be gone.
5. Only then: build the rest scene, run the five-target pointer sweep on the
   real desktop, bake `savevm golden`, prove `loadvm golden` in a FRESH process.
6. Land with `scripts/dev/station-land.sh macosx --golden <disk>`. The golden is
   expected to live entirely in the single main disk (no oberon-style extra
   device), so no `--golden-extra` should be needed — confirm with
   `qemu-img snapshot -l` before landing.

## Teardown (done at pause)

See the stream's final report for the released claims and the check that proved
each one.

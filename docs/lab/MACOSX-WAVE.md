# macosx wave — Mac OS X on PowerPC (issue #50, record wave 2026-09-21, Lane C)

**STATUS: LIVE 2026-09-20 (session `macosx-live`).** Golden baked and
restore-proven; the station is listed. The
first stream stood down before the install; this file now carries both streams'
measurements. Every fact below was measured on a framebuffer or with
`stat`/`sha256sum`.

## Allocation ledger

| Station | Session | Slot / UDP / VMID | X-warp | retronet (addr / tap / chain / UIN) |
|---|---|---|---|---|
| macosx | macosx-live | 218 / 54218 / 218 | — | — |

The first stream's 212 / 54212 / 212 were RELEASED and 212 had been taken by
another wave by the time this one resumed; `scripts/dev/wave.sh alloc macosx`
handed out **218** and the registry entry, the launcher echo and this ledger
were rewritten to it. That is exactly the landmine the first stream documented.

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

## THE INSTALL WALL, and the one-line fix (measured 2026-09-20)

The Panther installer reaches **Select a Destination**, shows the freshly
partitioned `Macintosh HD`, and refuses it:

> You cannot install Mac OS X on this volume. You cannot start up your computer
> using this volume.

This is NOT a bad partition map, and three expensive theories were killed on the
framebuffer before the real cause was found — record them so nobody re-buys them:

* **NOT the disk size.** The refusal reproduced identically on a 12 GB and on a
  6 GB qcow2. (The e-maculation wiki's "max bootable disk is 8 GB" is real
  folklore but it is not this symptom.)
* **NOT the "Install Mac OS 9 Disk Drivers" checkbox.** It reproduced with the
  box unticked AND ticked.
* **NOT a malformed map.** Dumped straight off the qcow2 with
  `qemu-img dd -f qcow2 -O raw bs=512 count=64` and decoded: a textbook Apple
  Partition Map — `Apple_partition_map`, two `Apple_Driver43`, two
  `Apple_Driver_ATA`, `Apple_FWDriver`, `Apple_Driver_IOKit`, `Apple_Patches`,
  then `Apple_HFS` at block 263968. Nothing missing.

**THE FIX: restart QEMU after partitioning, boot the CD again, and walk to
Select a Destination on the SECOND boot.** The installer decides a volume's
bootability from state it captured when the installer environment booted, so a
disk that was blank at boot stays "not bootable" for that whole session no
matter what Disk Utility does to it afterwards. On the second boot the same
volume shows the green install arrow and "Installing this software requires
3.0GB of space".

So the destination step is a **two-boot procedure**, and the first boot exists
only to run Disk Utility. Budget two CD boots (~3.5 min each under TCG).

## Install settings that were actually used

* Disk: **6 GB qcow2**, one partition, **Mac OS Extended (non-journaled)**,
  named `Macintosh HD`, "Install Mac OS 9 Disk Drivers" left ticked (it is the
  Disk Utility default and it costs ~1 MB).
* **Customize** at Installation Type, everything off except the forced
  *Essential System Software* (925 MB) and *BSD Subsystem* (225 MB). Dropped:
  Additional Applications, Printer Drivers, Additional Speech Voices, Fonts,
  Language Translations, X11. **Space Required falls 3.0 GB -> 1.1 GB**, and
  with it the Easy Install pane's demand for *Mac OS X Install Disc 2* — so
  **disc 1 alone is enough**, which was the first stream's open question.
  Trap: Printer Drivers and Fonts start as PARTIAL ticks ("-"), so the first
  click SELECTS them (Printer Drivers jumps to 1.1 GB). Click them twice.
* **Skip the "Checking your installation disc" pass** — it reads the whole
  679 MB ISO under TCG for nothing. The Skip button is at the Continue position.

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

## Timeline, measured from `date -u`

| T (UTC) | Milestone |
|---|---|
| 17:39 | session start, `wt.sh new macosx-live`, merge main |
| 17:44 | `wave.sh alloc macosx` -> slot/UDP/VMID **218** (212 was gone) |
| 17:56 | first Panther CD boot |
| 18:44 | the destination wall reproduced on a 6 GB disk with OS 9 drivers on — theories exhausted |
| 18:51 | **fix found**: restart QEMU, second CD boot, volume accepted |
| 18:54 | install starts (Customize -> 1.1 GB) |
| 20:00 | install ends, 66 min of package copy |
| 20:05 | first boot from the HD reaches Setup Assistant |
| 20:29 | **Aqua desktop** |
| 20:30 | five-target pointer sweep: 0 px error at all five |
| 20:55 | golden baked; restored in a fresh process and proven alive |

## Teardown (first stream, at pause)

Released and verified:

| Thing | Released with | Check that proved it |
|---|---|---|
| slot 212, UDP 54212, VMID 212 | `smoke-rig.sh macosx --down --release-claims` | `kh-claim ls --all \| grep -i macosx` -> no rows |
| `/os/macosx` dark-launch | `smoke-rig.sh macosx --down` | no `darklaunch.d/macosx.json` |
| both rigs (`ptrA`, `ptrB`) | `kill` resolved through `/proc/<pid>/exe` | no stray `qemu-system-ppc` |
| sandbox `macosx-work` | `wt.sh rm macosx-work --force` | directory gone |

The staged media is kept at `/data/assets-staging/macosx/` (1.3 GB, both ISOs,
hashes above) — it costs no CPU and it is the slow part to re-acquire. Note the
first stream's `ptrA/macosx.qcow2`, which that handoff said would survive, did
NOT: `wt.sh rm` took the sandbox and the formatted volume with it. Re-running
Disk Utility cost six minutes, which is why this is recorded rather than
mourned.

## Resume tooling (committed)

The throwaway helpers are under `docs/lab/integration-drafts/macosx/`:

| File | What it does |
|---|---|
| `rig-launch.sh` | launches a namespaced rig on the frozen device set; takes `ISO=` and extra QEMU args |
| `rig-drive.py` | minimal QMP driver: `abs X Y`, `rel dx dy`, `click`, `down`/`up`, `key`, `type`, `shot`, `sleep`, `hmp` |
| `rig-step.sh` | click at (x,y), then `fb-wait.py --settle` (never `sleep N`), then emit a PNG |

They hardcode a sandbox path; repoint it. Traps carried forward:

* `rig-drive.py`'s `key` takes each qcode as its own argument — `key meta_l q`,
  never `key meta_l-q`, which QMP rejects outright.
* `-display dbus,p2p=on` screendumps come back all-black while the guest is
  mid-repaint, and this happened FOUR times during this bring-up, always right
  after a click that opened a sheet. A pointer nudge and a re-shot distinguish
  "blanked" from "dead". Do not conclude a guest died from one black frame.
* `fb-wait.py --settle` never settles on the Screen Saver preference pane (the
  Flurry preview animates forever); expect it to burn its full timeout there.
* labhost's `qemu-img` is `/usr/bin/qemu-img`; `/opt/qemu-ppc` is built
  `--disable-tools` and ships no `qemu-img`.

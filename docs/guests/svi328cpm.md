# Spectravideo SV-328 CP/M

Host-native offline expanded SV-328 exhibit, implemented and sandbox-proven
2026-10-03. ID `svi328cpm`, slot/VMID label 222, UDP 54222; keyboard only.

Hardware: PAL SV-328, 64 KiB main RAM, 16 KiB VDP RAM; SV-601 seven-slot
expander; SV-801 disk controller in slot 6 (two 5¼-inch DD drives); SV-806
80-column display card in slot 0. No extra RAM, cartridge or network. The
disk's own banner says **Spectravideo CP/M-80 version 2.24 / For SV-605B**.
This describes its software package; the emulated enclosure is SV-601,
not a claim that MAME emulates a literal SV-605B enclosure.

## Native runtime

The narrow `svi328` MAME binary uses the fleet 0.289 pin and the shared
ctlsock/drawshm/no-UI patches plus the station-scoped SV-801 READY wiring
patch. The initial build used the shared compiler cache; the READY rebuild
hit 7 of 8 cacheable compiles, with one miss for the changed controller.
The final reproducible rebuild hit all 8 compiles. Its binary SHA256 is
`6d0502f498ca2f140b5f45c86819a8e1db8b9c07573c1167ccaf226fdc3933bf`.
The CP/M build gate uses the actual SV-601/SV-801/SV-806 configuration and
a fresh disk copy, waits for the guest motor countdown to expire, then
launches MBASIC and verifies its computed result `328` on the SV-806 display.
BASIC and CP/M assets remain separate; BASIC retains its existing binary.
SV-806 is **Screen 0**, and the ordinary VDP is **Screen 1** in the built
configuration. Use one output window and `-view0 "Screen 0"`; selecting
Screen 1 shows the VDP's blank blue CP/M scene. Framebuffer is 1024×768,
keyboard mamesock, audio SDL→FIFO. This station has no pointer or RetroNet.

`MAME_NATIVE_CHECKPOINT=0`, reset mode relaunch. The shared launcher's
immutable disk template is copied to writable `session.imd` before each
start, so RAM and disk changes are discarded together. No state file is
shipped. Both drives remain in the device set; drive B starts empty.

## Disk composition and acquisition

Run `scripts/build-guests/tiles/svi328cpm.sh`, then the native builder.
Media and ROM bytes remain outside Git; acquisition is preservation
provenance and does not grant redistribution rights.

The native `cpm224dd.imd` system disk is the source. The independently
written `svi_cpm_media.py` reads ImageDisk sector IDs and compressed sectors,
retains cylinder/head geometry and the original physical sector interleave,
and overlays CP/M allocation blocks in
**head 0 cylinders 3..39, then head 1 cylinders 0..39** order. CP/M uses
2048-byte allocations, 64 directory entries and EXM=1. MAME's raw SVI
representation interleaves both heads per cylinder. Track 0/head 0 has
18×128 FM sectors; every other head has 17×256 MFM sectors. The output remains
ImageDisk, 218788 bytes, with all 80 track headers, their physical sector-ID
orders and the original boot tracks unchanged.

The composer adds exact MBASIC.COM and an original WELCOME.TXT. A byte-level
reconstruction verifies MBASIC against the acquired binary. The resulting
disk boots, DIR finds MBASIC, TYPE WELCOME.TXT displays the complete original
text, and lowercase `mbasic` launches BASIC-80 Rev. 5.21 with **29752 Bytes
free** and `Ok` directly from a fresh cold-boot `A>` prompt. The Type fixture
uses the proven lower-case `mbasic` command.

The final ImageDisk fixture preserves the acquisition's physical interleave.
Earlier failures were initially associated with raw-sector conversion, but the
native ImageDisk fixture reproduced the same failure after guest idle time.
Sector ordering was not the demonstrated cause.

The original CP/M BIOS stops the motor when its countdown at RAM `F078`
expires. The next command spins it up and reads immediately. Unpatched MAME
rejects that read until the drive has seen two index pulses, while the BIOS
ignores the NOT READY status bit and accepts a zero-byte transfer. Thus the
first delayed `mbasic` returned `MBASIC?`, and DIR could return NO FILE.
The production browser exposed this after a delayed first command. Native
regression probes use physical matrix keys with 150 ms holds and 350 ms gaps;
natural keyboard posting at its default 50 ms can drop letters and is not
accepted as a disk-read proof.

The [original SV-801 STM-001-C schematic, March 1984, page 1](https://hansotten.file-hunter.com/uploads/files/STM-C_SVI801.pdf)
connects FD1793 IC1 pin 32 READY to +5 V through R1 (1K); drive connector
pin 34 is reserved. `mame-sv801-ready.patch` models that wiring with
`set_force_ready(true)` on this controller alone. Firmware, boot tracks,
CP/M filesystem and MBASIC bytes remain unchanged. The paired physical-key
regression waited for the countdown to reach zero at 40.08 emulated seconds:
the original binary echoed complete `mbasic` then returned `MBASIC?`; the
READY-corrected binary loaded BASIC-80 and computed `300+28` as `328`.

| Asset | Source / measured SHA256 |
|---|---|
| SV-328 BIOS ZIP, 77948 B | Individual `svi328.zip` from archive.org item `mame-0.264-roms-non-merged`; `c04e51b23da6b13f30541f5fe8cdf45e79b114350c2b5e541efa54921308378e` |
| SV-806 ZIP, 2717 B | Same item, individual `sv806.zip`; `73aeb55e8dc1e39580db3177598a2ec6f129969eb1af5be88cc7a16f22493bfa` |
| CP/M ImageDisk ZIP, 145587 B | [Individual nested archive](https://archive.org/download/MAME_0.228_Software_List_ROMs_merged/MAME_0.228_Software_List_ROMs_merged.zip/svi318_flop%2Fcpm224dd.zip); `7a6cc43d8e204d3ac3163db3d083650a5e55b8a2a7aba81b591776d6f90f2d29` |
| MBASIC.COM, 24320 B | [Retroarchive preserved binary](http://www.retroarchive.org/cpm/lang/Mbasic.com); `29d957fc6899c24f6296a1662a27eca545d85ee3f7d70d2794c9d045d92ff157` |
| Curated pristine ImageDisk, 218788 B | `ccb36857bead40a119acced4ff179325eb90ca28a66dd0faf7a4b6c9d9fe2dfa` |

ROM members match the built driver: v111 `svi111.rom` SHA1
`10349ce675f6d6d47f0976e39cb7188eba858d89`; English SV-806 `sv806.ic27`
SHA1 `ed45cb0e9bd18a9d7bd74f87e620f016a7ae840f`. The system IMD matches MAME
software-list SHA1 `2326ad4de147638194645df82ea9e803cea4eb79`.
The other archived raw `cpm224ds.dsk` booted but DIR returned NO FILE; it is
excluded from the builder. Native ImageDisk preserves the acquisition's
physical track layout and is the only final fixture.

## Input and visitor program

Keymap comes from the running SV-328 KEYDUMP (93 fields, 85 mapped keys).
100 ms hold/gap, matrix exclusion `:KEY`, 500 ms Type character pace.
Colon and semicolon require the registry character-map swap; quotes, comma,
asterisk and Control use the generated matrix. Ctrl+C interrupts CP/M;
Ctrl+End is SV STOP. Finnish characters are not claimed.

The Type program launches MBASIC from `A>`, clears program memory and enters
an original numbered loop. RUN prints **SPECTRAVIDEO CP/M** and the five
squares **1 1**, **2 4**, **3 9**, **4 16**, **5 25**; LIST permits editing,
and SYSTEM returns to CP/M. The first-command loading delay is 20000 ms.

The ImageDisk fixture initially passed three independent cold process launches
through the production daemon in the staged SPA, with idle suspension disabled.
Those early-command tests did not cover the BIOS motor timeout. Trial 1 used physical browser keys to start MBASIC; trials 2 and 3 used
the actual Type demo button followed by visitor Enter on RUN. Both full demos showed the title, all five square
values and `Ok`. No Ctrl+C or warm-boot preamble was used.

Browser-entered `SAVE "VISITOR"`, NEW, `LOAD "VISITOR"` and LIST restored
all four original numbered lines from the writable disk. SYSTEM followed by
`DIR VISITOR.BAS` listed the created file. A cold relaunch restored the exact
pristine ImageDisk hash, and `DIR VISITOR.BAS` then reported NO FILE.
The READY-corrected binary also passed the actual web Type demo after more
than 206 emulated seconds at the untouched cold prompt, with production's
12-second startup standby and 60-second idle policy enabled. Visitor Enter
executed RUN and displayed the title and all five squares. Browser SAVE,
NEW, LOAD and LIST restored the exact four program lines; SYSTEM and DIR
showed VISITOR.BAS. A full private relaunch restored the pristine disk hash,
and the browser directory listing confirmed that VISITOR.BAS was absent.

Final production browser acceptance passed on 2026-10-03. The actual web
Restore button returned HTTP 200 and recreated the exact pristine disk hash.
After 96 wall-clock seconds (over 72 emulated seconds) at the cold prompt,
the actual Type button loaded MBASIC and entered every program line correctly.
Visitor Enter executed RUN, showing the title, all five square values and Ok.
The production binary hash matches the cached, regression-tested build above.

The synthetic regression test in `scripts/test_svi_cpm_media.py` checks
unsorted physical sector IDs, mixed compressed/full sectors and byte-exact
logical overlays without requiring proprietary media.

## Shifted characters: the modifier lead (2026-10-04)

`SH_KEY_MOD_LEAD_MS=10` in the station fixture: the `ctlsock` module holds a
key press until the Shift edge in front of it has been in the matrix for 10
emulated ms, so the BIOS's matrix scan sees SHIFT before the key it modifies.
This machine lost no shifted character on the old engine. It gets the fleet's
10 ms anyway, five times the largest threshold measured on a MAME machine
([`../TYPE-IN-EDITOR.md`](../TYPE-IN-EDITOR.md#shifted-characters-the-modifier-lead)).
The demo's `perCharMs` 500 already covers it: HOLD 100 + max(GAP 100, LEAD) +
LEAD = 210.

**Rig proof (2026-10-04).** A rig of this station's own binary and golden took
the keys through a sandbox daemon at 0.99 to 1.00x real time. The demo listing
and a 10-line MBASIC listing with `"A+B*C:D(E)$!";1+2*3` on every line came
out pixel-identical on the old binary and twice on the new one (LIST included).
The golden is pixel-identical under the new binary, and the savestate
signature is unchanged (`bf0585be`, 1359 entries).

**Live since 2026-10-04.** The stage menu's demo typed exactly, and Restore to
golden brought back the `A>` prompt. Rollback:
`assets/svi328cpm/mame-native/svi328.pre-shiftlead-20261004` and
`station.env.pre-shiftlead-20261004`. Evidence:
`/data/vms/streamhost/stations/svi328cpm/evidence/shift-lead-2026-10-04/`.

## Source references

- [Pinned MAME machine](https://github.com/mamedev/mame/blob/mame0289/src/mame/svi/svi318.cpp)
- [Original SV-801 controller schematic](https://hansotten.file-hunter.com/uploads/files/STM-C_SVI801.pdf)
- [Pinned MAME disk format](https://github.com/mamedev/mame/blob/mame0289/src/lib/formats/svi_dsk.cpp)
- [Preserver's physical/CP/M disk format](https://www.samdal.com/svdiskformat.htm)
- [SV-806 original manual](https://hansotten.file-hunter.com/uploads/files/SVI-806_80ColumnUsersManual.pdf)

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
ctlsock/drawshm/no-UI patches. Its build is cached: 43 cacheable compiles,
5 hits, 38 misses, with generated `ccache gcc`/`ccache g++` make commands.
The final rebuild hit all 7 cacheable compiles. The CP/M build gate uses
the actual SV-601/SV-801/SV-806 configuration and a fresh disk copy.
The same binary is copied into separate BASIC and CP/M assets directories.
SV-806 is **Screen 0**, and the ordinary VDP is **Screen 1** in the built
configuration. Use one output window and `-view0 "Screen 0"`; selecting
Screen 1 shows the VDP's blank blue CP/M scene. Framebuffer is 1024×768,
keyboard mamesock, audio SDL→FIFO. This station has no pointer or RetroNet.

`MAME_NATIVE_CHECKPOINT=0`, reset mode relaunch. The shared launcher's
immutable disk template is copied to writable `session.dsk` before each
start, so RAM and disk changes are discarded together. No state file is
shipped. Both drives remain in the device set; drive B starts empty.

## Disk composition and acquisition

Run `scripts/build-guests/tiles/svi328cpm.sh`, then the native builder.
Media and ROM bytes remain outside Git; acquisition is preservation
provenance and does not grant redistribution rights.

The native `cpm224dd.imd` system disk is the source. The independently
written `svi_cpm_media.py` reads ImageDisk sector IDs and compressed sectors,
retains cylinder/head geometry, and overlays CP/M allocation blocks in
**head 0 cylinders 3..39, then head 1 cylinders 0..39** order. CP/M uses
2048-byte allocations, 64 directory entries and EXM=1. MAME's raw SVI
representation interleaves both heads per cylinder. Track 0/head 0 has
18×128 FM sectors; every other head has 17×256 MFM sectors. Output is exactly
346112 bytes, with the original boot tracks unchanged.

The composer adds exact MBASIC.COM and an original WELCOME.TXT. A byte-level
reconstruction verifies MBASIC against the acquired binary. The resulting
disk boots, DIR finds MBASIC, TYPE WELCOME.TXT displays the complete original
text, and lowercase `mbasic` launches BASIC-80 Rev. 5.21 with **29752 Bytes
free** and `Ok` directly from a fresh cold-boot `A>` prompt. The Type fixture
uses the proven lower-case `mbasic` command. Initial upper-case Shift-entered
transient commands returned `?`; lower-case transient commands work.

| Asset | Source / measured SHA256 |
|---|---|
| SV-328 BIOS ZIP, 77948 B | Individual `svi328.zip` from archive.org item `mame-0.264-roms-non-merged`; `c04e51b23da6b13f30541f5fe8cdf45e79b114350c2b5e541efa54921308378e` |
| SV-806 ZIP, 2717 B | Same item, individual `sv806.zip`; `73aeb55e8dc1e39580db3177598a2ec6f129969eb1af5be88cc7a16f22493bfa` |
| CP/M ImageDisk ZIP, 145587 B | [Individual nested archive](https://archive.org/download/MAME_0.228_Software_List_ROMs_merged/MAME_0.228_Software_List_ROMs_merged.zip/svi318_flop%2Fcpm224dd.zip); `7a6cc43d8e204d3ac3163db3d083650a5e55b8a2a7aba81b591776d6f90f2d29` |
| MBASIC.COM, 24320 B | [Retroarchive preserved binary](http://www.retroarchive.org/cpm/lang/Mbasic.com); `29d957fc6899c24f6296a1662a27eca545d85ee3f7d70d2794c9d045d92ff157` |
| Curated pristine disk | `43dcc23df08e77868cd2d69b79fda457759df837dde7d8b9a55c9b3263fddca9` |

ROM members match the built driver: v111 `svi111.rom` SHA1
`10349ce675f6d6d47f0976e39cb7188eba858d89`; English SV-806 `sv806.ic27`
SHA1 `ed45cb0e9bd18a9d7bd74f87e620f016a7ae840f`. The system IMD matches MAME
software-list SHA1 `2326ad4de147638194645df82ea9e803cea4eb79`.
The other archived raw `cpm224ds.dsk` booted but DIR returned NO FILE; it is
excluded from the builder. Parallel native-IMD and sorted-raw proofs showed
that native `cpm224dd.imd` and its sector-ID conversion read the directory.

## Input and visitor program

Keymap comes from the running SV-328 KEYDUMP (93 fields, 85 mapped keys).
100 ms hold/gap, matrix exclusion `:KEY`, 500 ms Type character pace.
Colon and semicolon require the registry character-map swap; quotes, comma,
asterisk and Control use the generated matrix. Ctrl+C interrupts CP/M;
Ctrl+End is SV STOP. Finnish characters are not claimed.

The Type program launches MBASIC from `A>`, clears program memory and enters
an original numbered loop. RUN prints **SPECTRAVIDEO CP/M** and the five
squares **1 1**, **2 4**, **3 9**, **4 16**, **5 25**; LIST permits editing,
and SYSTEM returns to CP/M. The coordinator adds the measured first-command
loading delay and verifies the button through the actual SPA before deployment.

## Source references

- [Pinned MAME machine](https://github.com/mamedev/mame/blob/mame0289/src/mame/svi/svi318.cpp)
- [Pinned MAME disk format](https://github.com/mamedev/mame/blob/mame0289/src/lib/formats/svi_dsk.cpp)
- [Preserver's physical/CP/M disk format](https://www.samdal.com/svdiskformat.htm)
- [SV-806 original manual](https://hansotten.file-hunter.com/uploads/files/SVI-806_80ColumnUsersManual.pdf)

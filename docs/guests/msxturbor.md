# Panasonic FS-A1GT / MSX turbo R

Host-native openMSX 21.0, pinned to
`cb61db762aba16752ff649990bf85e40627777af`. Station `msxturbor`,
slot/VMID label 220, UDP 54220. No QEMU guest, X server, kiosk, network
cartridge, retronet wiring, microphone or host MIDI connection.

## Hardware and software

The Japanese FS-A1GT includes R800 and Z80 processors, 512 KiB mapper RAM,
V9958 video with 128 KiB VRAM, MSX-MUSIC, PCM, built-in DOS2 and MSX View.
The public copy uses “early 1990s”: upstream machine metadata disagree on
1991 versus 1992. The integer catalogue year remains provisional at 1991.
This is a later Panasonic MSX relative, not a Spectravideo model.

The GUI profile enables the firmware switch and inserts original system
disk 3. `MSX_PROFILE=dos` disables the switch and inserts original system
disk 2. In the DOS profile, only the throwaway copy’s AUTOEXEC.BAT is
replaced with `PATH \UTILS`, leaving the original DOS kernel and utilities
intact and resting at the prompt; enter `TOOL` to open the period menu.
Disk 1 is the original Japanese word processor. All three disks
are copied into the instance's work directory on each launch.

## Reproduce

Run through `ssh lab` or `scripts/dev/labrun` from the isolated sandbox:

```
scripts/build-guests/tiles/msxturbor.sh
scripts/build-guests/emulators/build-openmsx-native.sh
```

The defaults stage exclusively under `/data/vms/sandbox/msxturbor`.
Override `MSXTURBOR_ASSETS`, `OPENMSX_BUILD`, `OPENMSX_DEST` when preparing
an independently named instance. Build dependencies include Tcl, SDL2,
SDL2_ttf, PNG, GLEW, zlib and the optional Ogg/Theora/Vorbis libraries.
`CXX=/usr/lib/ccache/g++` enables the compiler cache; upstream's probe
misparses the two-word `CXX="ccache g++"`. The builder prints cache stats.

Runtime files live in `streamhost/stations/msxturbor/`. The historical
`x11-runtime.sh` name is the daemon's launcher contract; it does not mean
this implementation uses X11. The adapter records the emulator PID in
`mame.pid`, so the existing lifecycle and idle-pause machinery applies.
Stop through the clone guard before relaunch; a live PID makes the launcher
refuse. Runtime logs are `openmsx.log` in the instance directory.

## Native transport

The patch exports the completed native `FrameSource` from openMSX's
postprocessor directly into shared memory. SDL uses its offscreen driver
and Mesa software rendering (`LP_NUM_THREADS=1`), with no display server.
The upstream postprocessor selects/deinterlaces fields before export.
Finished frames publish fixed 640×480 BGRA through the daemon's existing
IFB1 64-byte header and atomic sequence lock. Geometry stays stable across
MSX text and graphics modes. No PNG polling or window capture is involved.

The 48 kHz SDL dummy audio callback converts normalized float stereo to
S16 stereo FIFO writes of at most PIPE_BUF, nonblocking. A reader that
stalls cannot freeze emulation; surplus audio is dropped. The FIFO retains
only the operating system's bounded pipe capacity.

The private mode-0600 Unix adapter implements the existing `mamectl/1`
input wire protocol. Only bounded integer mouse movement, button edges,
and validated keyboard matrix bits are converted to XML commands. Visitor
text is never evaluated as Tcl. The emulator adds `hive_mouse`, which
routes motion and buttons through the same MSX event/state-change path as
physical input. Keys have 40 ms hold/gap pacing; all held keys and buttons
are released on disconnect. Mouse packets wait for two actual joystick-port sampling cycles,
so a busy redraw cannot merge homing and target movement. Button edges
also wait three completed guest frames after motion or the previous edge,
allowing MSX View to process its software cursor. Repeated absolute targets
are no-ops, while preserving that pending edge barrier. A bounded 128-request
receive queue combines adjacent absolute movements into their latest target,
acknowledging every sequence. It never combines across a key or button edge:
that edge first receives its preceding pointer target. Keyboard edges
also wait for two guest matrix-row reads, retaining the 40 ms minimum hold/gap. GUI readiness waits
for the real VSHELL content pane: the preceding blue BIOS screen can appear
stable for several seconds and is not a valid readiness signal. The keymap is derived from the pinned
`unicodemap.jp_jis`; registry punctuation remapping reflects Japanese JIS.

## Reset and isolation

Every launch deletes only its own `work/` directory and makes fresh writable
copies of the disks plus a new `OPENMSX_HOME` / `OPENMSX_USER_DATA` profile. That profile
contains the machine's SRAM, CMOS, firmware-switch and settings state.
Original staged assets are read-only. Cold boot is the reset baseline;
there is no external-media-dependent savestate masquerading as a rollback.
Each instance owns its framebuffer, audio FIFO, input socket, profile and
PID files. No station network devices or bridge scripts are installed.

## Original-media manifest

Fetched 2026-10-03. Original copyrighted ROM and disk bytes are excluded
from the repository; public availability is not a redistribution licence.
The reproducible staging script records source URLs and checks all SHA-256
values before use.

| Asset | Bytes | SHA-1 |
|---|---:|---|
| FS-A1GT firmware | 4194304 | e779c338eb91a7dea3ff75f3fde76b8af22c4a3a |
| Kanji font | 262144 | 5aff2d9b6efc723bc395b0f96f0adfa83cc54a49 |
| System disk 1 | 737280 | e76af38ac8d9b83705f63d4d13147fbebf0c4e8e |
| System disk 2 | 737280 | fd1f052485d22631c0e340f8466ac22af991176d |
| System disk 3 | 737280 | da1ac7d37e52e09eba400ec3edee8542cc4a9e04 |

ROM archive: Internet Archive `mame-0.264-roms-non-merged`, `fsa1gt.zip`.
Disks: File-Hunter `System Disks/Computers/Panasonic/FSA1GT/`, the three
original system disk ZIPs. A normal browser User-Agent is required by that
mirror. MAME labels the 4 MiB firmware variant BAD_DUMP; openMSX explicitly
accepts its SHA-1. This integration does not relabel it a clean physical ROM.

## Acceptance ledger

Validated in isolated GUI and DOS instances on 2026-10-03:

- All five expected SHA-1 media identities match; canonical native build and
  subsequent cached rebuild completed. The rebuild made two direct cache hits
  and zero misses. Binary SHA-256:
  `220824867fdc443c4dc03effc80a04c7ad3bc492dc5c581b759295eff5cfb9a3`.
- IFB1 shows VSHELL, ViewDRAW 1.1 and MSX-DOS 2.30 / MSX-BASIC 4.1.
  Native input opens DRAW through 道具 (Tools), places a rectangle, creates
  a text box and types through the period Japanese input mode. GUI Save
  also completed: the title changed to HIVE and the writable disk copy
  contains the 60-byte `HHIVE.DRW` file.
- Native keyboard saved `HIVE.BAS`, cleared memory with NEW, reloaded it and
  listed the original `10 PRINT "HIVE TURBO R"` program on the framebuffer.
- BASIC BEEP produced 2,306,048 captured PCM bytes, 22,340 nonzero S16 samples
  and peak magnitude 2921, at 48 kHz stereo.
- Relaunch removed the saved file, restored byte-identical original disk 3,
  and recreated separate profile directories. Both profiles ran concurrently.
- Adapter tests, Python lint/format, shell checks, SPA lint/type/knip,
  2,261 SPA tests/build, registry parity and file-size checks passed. The
  inherited Python-suite read-path failure is fixed in coordinator main
  (`01c1e1cf`); coordinator owns the final integrated full-suite gate.

Browser acceptance passed in the staged SPA: Tools → DRAW, rapid rectangle
and text-box placement, physical keyboard text, and Save to drive A produced
BROWSER.DRW (44 bytes). The production reset endpoint is checked at bring-up.
The poster uses actual desktop and DRAW frames.
Proof artifacts are under the sandbox's `rig-view/`, `rig-dos/` and `build/`
directories. They are not live station files.

DRAW uses click-to-start / click-to-finish placement. Finish the second corner
before selecting another toolbar item; a plain drag can leave an object active.
To save from DRAW, open the top-left application menu, choose 保存, choose
drive A, wait for its directory listing, enter a name in the bottom field,
then click 保存. Drive C is the read-only ROM disk.

The Japanese application input mode may produce kana from Latin-position keys;
this is original guest behavior, not UTF-8 host text injection. Press Enter
to commit that composition before leaving the text box; Escape cancels it.

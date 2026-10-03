# SymbOS on MSX2

SymbOS 4.0 (31 January 2025) is later enthusiast software on a Philips NMS
8250 MSX2 (1987), with an explicitly added 512 KiB mapper. The MSX port first
appeared in 2006. This exhibit is offline and has no RetroNet attachment.

## Runtime and reset

ID `symbos`, slot/VMID 225, UDP 54225. Host-native MAME 0.289, driver `nms8250`,
`-cartslot1 mm512k -gen1 mouse`, a single writable 720K floppy and the
`Screen 0 Standard (4:3)` view. Task Manager reports 512 KiB total memory.
No QEMU, kiosk, networking or guest credentials are involved.

The shared `mame-native/x11-runtime.sh` launcher copies the immutable private
`assets/symbos/media/symbos4.dsk` to the station's `runtime.dsk` on every launch.
Reset relaunches MAME and discards visitor disk changes. Save states are disabled:
this driver does not have a supported checkpoint contract. Cold boot takes about
40 seconds on the loaded lab host; standby waits 75 seconds to avoid freezing DOS
before the desktop starts. Every reset requires a new desktop framebuffer.

## Private source media

Third-party executables, disk images and ROMs are private assets, never Git files.
SymbOS is freeware from its project; MSX-DOS and the Philips ROM are proprietary
legacy software, not covered by this repository's MIT license.

| Input | Source | SHA-256 |
| --- | --- | --- |
| Core 4.0 | [Official MSX package](https://www.symbos.org/download/20250131-V40/symbos-msx40.zip) | `27fa0201e0dbf08bdeb951a4aaa22e61a43ec3fc29c20a89bc7299478d322d6a` |
| Matched apps | [Official 4.0 completion archive](https://www.symbos.org/download/20250131-V40/SymbOS-40-MassStorageCompletion.zip) | `65b24b3b955a6a2ff1dc51f20b8226b68c516da2e6e31ef3c312bd10ca2187e4` |
| DOS1 system files | [MSXHub MSXDOS1 1.03-2](https://msxhub.com/api/MSXDOS1/1.03-2/get/MSXDOS1.zip) | `89722f4038a4ea93d3515fa0891f60f957f4ba9aad8760e4baaaa46d4393e10c` |
| DOS1 boot code | [Original DOS1 disk archive](https://download.file-hunter.com/OS/MSXDOS/MSX-DOS%201%20original%20versions/msxdos101-108%20clean.zip) | `88953799ca8a196c0b22596e99b6c39620a50576990ede9a3adbd990dd0571bf` |

The cached Philips ROM set is staged with `stage-romset.py`, then verified by
MAME's ROM audit. Cached station binary SHA-256:
`fcb509b2c1fa7394ecc4b406e282f108c5fd6ce3200d785feeafc3c2a60124a6`.
Build source and pointer patch list are in `emulators/native.d/symbos.sh`.

## Rebuild the boot master

Run `scripts/build-guests/tiles/symbos.sh --prepare` with mtools, unzip and curl.
It checks the archive hashes, formats a 737280-byte FAT12 disk, preserves its
720K BPB bytes 11–29, copies original DOS1 boot code around that BPB, and adds
MSXDOS.SYS, COMMAND.COM and the nested official SYMSETUP.COM/DAT.
The completion archive supplies release-matched Notepad, Calculator and Game of
Life. The prepare operation has been exercised on an isolated staging tree.

Launch an isolated copy with the exact device set above. At DOS, run `SYMSETUP`.
The proven installer sequence is: `1`, Enter, Enter; wait for file copying;
Enter, `S`, Enter, `1`, `A`, `Y`, Enter, Enter. The selected MSX storage driver is
the Philips floppy controller and the boot drive is A. Installation is guided,
not unattended: inspect each prompt and wait for copying to finish.

Exit MAME through its control socket and wait for its PID to disappear before
using mtools. A forced process kill loses buffered disk writes. Run
`symbos-finish-media.sh installed.dsk staging/apps/release40`; this removes setup
files, copies the eight selected application files, writes `SYM` plus CRLF to
AUTOEXEC.BAT, and changes three classic desktop shortcut slots in SYMBOS.INI.
It preserves the installer-selected hardware configuration and rejects an
unexpected shortcut layout. The original installer-selected core is retained.

Prove the finished master on a writable clone. Preserve the stopped master and
its `.sha256` sidecar privately, then use `symbos.sh --stage-installed FILE`.
The staged template is mode 0444 and its hash is recorded beside it. Validated
master SHA-256: `a592b4a8d8688b23682b79361b914e961544c7a511eabb42b9bc0bbe22af15a3`. The builder
requires the exact 720K size and verifies the sidecar before staging.

Do not substitute the current application ZIPs for the pinned collection. The
2026 multilingual Notepad/Calculator builds allocated processes without showing
windows under 4.0. Their language startup calls the extended language loader;
API mismatch is the inferred cause. The 2025 release-matched binaries visibly
open and function on this fixture.

## Input and activities

The CPU-scanned MSX matrix uses the station's KEYDUMP-derived keymap through
mamesock, with 120 ms hold and 80 ms gap. SymbOS's US-layout backslash/grave
legends differ from MAME's Dutch machine labels: scancode 0x2b uses KEY1
`\\ |`, and 0x29 uses KEY2 `` ` ~ ``. Slow physical key events typed the exact
25-byte string `Hello from SymbOS! 2+2=4.`; natural-keyboard CODE is for DOS,
not the desktop's matrix scanner.

Mouse input uses the actual joystick-port-1 mouse fields, including left/right
buttons and X/Y axes. The published 1024×768 framebuffer contains a 964×572
active raster at (30,103), mapping a 512×212 guest desktop. Measured gain is
1.8828125 horizontal and 2.6981132 vertical pixels per count. Narrow 8-bit deltas
are paced; the fixture carries the proven timing and screen-origin settings.
The opt-in `MAME_CTL_MSX_CURSOR=:v9938` observer reads sprite 0, its colour
early-clock bit, vertical scroll and the VDP mode-dependent VRAM bank mapping.
It writes no guest memory. Closed-loop MOVEA corrects lost counts against the
actual hardware cursor. Other stations retain their existing cursor path.
Framebuffer landing checks determine acceptance; browser acceptance is separate.

Double-click the labeled shortcuts for Notepad, Pocket Calculator and Game of
Life. Notepad supports drive-A text files. Click the File name field before typing
a name in the file chooser, then click Save. File → Save As renames an existing
document; Ctrl+S writes its current name. Calculator has visibly produced 4
from 2 + 2. Game of Life's Random and Start buttons visibly advance generations
while the other applications remain open. SymCommander browses the disk. Start
→ Run can also open `A:\\TASKMGR.EXE`, `A:\\CP.EXE` or `A:\\CMD.EXE`.

## Acceptance and rollback

Isolated proof artifacts are kept in `/data/vms/sandbox/symbos/proof`; they are
operator evidence, not distributable disk binaries. Actual desktop/app imagery
is included in the station poster. Local acceptance covers cold boot, repeated absolute pointer targets,
click/double-click, a held window outline followed by release, complete keyboard
text, save/reopen, and cold reset. HIVE.TXT contains the exact 25-byte sentence
plus DOS EOF byte 0x1a; reset removes that visitor file. The production reset
restarts the whole service so its framebuffer reader attaches afresh. A manual
emulator-only restart can leave an existing stream reader on a stale frame.
Audio is disabled: these GUI activities have no proven sound-output path.
No mouse wheel device is claimed.

Registry and scene rows must validate together, with a unique hardware tuple.
Browser acceptance on the isolated native fixture passed: decoded 1024×768
video, an ordered click reopening HIVE.TXT, a real browser double-click opening
Notepad, and complete physical keyboard text `browser test!` (including Shift).
Evidence: `work/symbos-browser-accepted.png` in the task workspace. The browser
context is closed. A private copy of the shared native launcher changed only
BASE to the proof directory; device flags and reset template came from the fixture.
The coordinator performs the final production Restore-button acceptance and
integrated gates.
Rollback disables the registry row and regenerates surfaces; stop only this
station and restore its previous immutable template. Never capture a new golden
or edit an attached disk as a rollback shortcut.

The local full SPA suite passed 123 files / 2269 tests; eslint, knip, tsc, Vite
build, full Bash shfmt/shellcheck, registry drift and strict file-size checks
passed. The custom native observer compiled and linked against cached MAME
0.289 objects; the final ROM audit accepts the Philips set.

The canonical native builder emits `assets/symbos/mame-native/msx2`
(`NATIVE_SUBTARGET=msx2`); the production fixture uses that same binary path.

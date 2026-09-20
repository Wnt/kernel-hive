# msx2 — facts for the week closing 2026-09-20

Raw material for the Sunday authoring pass.

## New stations

<u>[MSX2](station:msx2) joins the museum</u> — a **Philips NMS 8250** (1987),
one of dozens of machines built to a shared MSX specification instead of one
vendor's own design. BASIC lives in ROM (the same "MSX BASIC version 2.1"
banner a visitor would have seen on a Sony, Panasonic or Yamaha MSX2 machine
alike), and the station's internal floppy drive carries a genuine period
MSX-DOS 2 system disk.

The station runs host-native on MAME's own `nms8250` driver — the same
engine already running the museum's SAM Coupé and Apple IIe stations — with
no QEMU and no guest OS underneath.

What was hard: the keyboard. The MSX2's 8255 PPI keyboard matrix is scanned
by the host CPU, the same shape as the SAM Coupé's, and a browser's typed
line arrives at the daemon as one burst rather than paced keystrokes — a
raw burst against a CPU-scanned matrix reads as an impossible chord. The
fix already had a name from the SAM Coupé wave (`MAME_CTL_KEY_EXCL`,
serializing the matrix's key presses); this station set it from the start
rather than rediscovering the symptom, and a real browser tab typing
`PRINT 1+1` landed byte-perfect on the first try.

What's open: reaching an **MSX-DOS 2** command line. The disk is in the
drive, but this machine's built-in disk ROM only speaks MSX-DOS 1 (visible
in the boot banner, "Disk BASIC version 1.0") — a real MSX-DOS 2 prompt
needs its own cartridge ROM, which this wave didn't source. The station
ships honestly as an MSX-BASIC exhibit with the DOS2 disk present but not
yet reachable.

No pointer (keyboard-only exhibit) and no golden checkpoint yet — the
`msx/msx2.cpp` MAME driver's savestate support wasn't confirmed on this
build, so every reset is a fresh cold boot rather than a restore.

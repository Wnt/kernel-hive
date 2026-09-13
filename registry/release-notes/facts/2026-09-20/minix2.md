# minix2 — facts for the week closing 2026-09-20

Raw material for the Sunday authoring pass.

## New stations

<u>[Minix 2.0.4](station:minix2) joins the museum, Andrew Tanenbaum's teaching
Unix from 2001</u> — the operating system Linus Torvalds famously started out
comparing his own kernel against. The exhibit is a bare text console that
lands a visitor straight on a logged-in root shell inside `/usr/src`: the
complete Minix kernel source tree, `kernel`/`mm`/`fs`/`inet` and all, ready to
`cat`. There is no window manager and no pointer to click — Minix 2 predates
any GUI this museum runs, and the point of the station is the code itself,
not a desktop.

What was hard: getting a *bootable* disk at all. The official install floppy
set hits an unrecoverable disk error in QEMU's floppy emulation on roughly
one sector in eighteen — looks like a track-boundary bug in the floppy path
under KVM — and that install route was abandoned rather than chased down. A
pre-installed disk image survives from the Minix community (woodhull.com's
Bochs demo package) with the same 2.0.4 release inside it; its files came out
byte-identical, by hash, to the official install set fetched independently
from minix3.org, so the shortcut lost nothing. The other trap was the disk's
geometry: the source image is a 50 MB flat raw disk with a specific
200-heads/16-cylinders/32-sectors layout baked into its own partition table,
and QEMU has to be told that exact CHS or the partition map reads as
corrupt.

No pointer, no sound card (the console bell rides the shared PC-speaker
audio path), and no retronet join this wave — Minix 2 has a network stack,
but there is no period browser or IM client to point it at, so a tap would
have nothing to reach.

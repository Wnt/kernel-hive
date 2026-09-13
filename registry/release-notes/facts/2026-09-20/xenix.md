# xenix — facts for the week closing 2026-09-20

Raw material for the Sunday authoring pass.

## New stations

<u>[SCO Xenix System V/386 2.3.4](station:xenix) joins the museum</u> —
Microsoft's own Unix, licensed to the Santa Cruz Operation in 1987 and, by
AT&T's own 1988 figures, running on about half of all installed Unix seats
in the world. This build dates from 1989/1991 (the kernel's own banner reads
`91/03/22`), the last release of the line SCO would later carry into the
1990s as SCO UNIX. A visitor lands on a plain 80x25 text console — a
pre-installed disk boots straight to a logged-in root shell — and can look
around with `uname -a`, `who`, `ls /usr`. The one thing worth the visit:
**Alt-F2** switches to a second, completely independent login session on the
same kernel, **Alt-F1** switches back. That's Multiscreen, and it's where
Linux's virtual consoles (same keystrokes, a decade later) come from.

What was hard: getting the emulator to run it at all. Under QEMU's normal
TCG software accelerator the kernel boots and prints its banner fine, but
every single program the guest tries to run then dies with `no stack space`
— reproduced identically on the original install floppy and on an
independently-built pre-installed disk from years earlier, so it was a QEMU
defect, not bad media. The fix was one flag, `-enable-kvm`, after a wall of
sweeps (memory size, machine type, CPU model, boot-string arguments) found
nothing. Separately, the archive.org install-floppy set turned out to mix
two incompatible machine classes in one download — the installer floppies
were built for IBM's MicroChannel bus, which QEMU cannot emulate, while the
utility floppies were a different, ordinary AT-class build — so no clean
from-floppy install currently exists on this box; the station ships from a
pre-installed disk image instead. And the boot floppies themselves carry no
boot-sector signature IBM PCs require, so a naive one-byte "fix" (write the
signature) breaks a length-14 filename compare on the very next bytes;
getting a bootable floppy needed a two-byte patch at two different offsets,
worked out from disassembly, not trial and error.

No mouse (Xenix has no concept of one on a text console), and no retronet
join — SCO sold TCP/IP for Xenix as a separate product with its own
installer, so the base disk has no network stack and the station ships with
no network card at all rather than one it can't use.

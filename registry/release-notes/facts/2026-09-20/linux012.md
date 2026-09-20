# linux012 — facts for the week closing 2026-09-20

Raw material for the Sunday authoring pass.

## New stations

<u>[Linux 0.12](station:linux012) joins the museum</u> — January 1992, the
fourth month the Linux kernel existed, and the release that mattered:
0.12 added demand paging to disk and quietly switched the kernel's
license to the GNU copyleft in its release notes. The exhibit boots
straight to a root shell — running under QEMU with only 16 MB of RAM and
one virtual CPU, because 0.12 is uniprocessor and that's the ceiling it
was written for. There's no mouse driver of any kind yet and no
networking stack at all (that arrived later in 1992), so this is a
text-only, keyboard-only exhibit, and honestly so — those aren't missing
features, they didn't exist yet.

A visitor can look around a genuinely tiny, genuinely early Unix: `ls /`,
`cat /etc/passwd` (root has no password), `ls /usr/bin` — a userland of a
few dozen basic commands, all that fits on a 1.44 MB root floppy image
with only a handful of free blocks left. The boot banner itself proves the
headline feature: "Swap device ok: 1023 pages" is 0.12's own demand-paging
subsystem confirming itself live, not a decoration.

What was hard: this kernel's floppy driver has no I/O timeout anywhere, so
when it can't get along with QEMU's virtual floppy controller, it doesn't
error — it just hangs silently forever, waiting on interrupts that
stopped coming after the controller had already answered 43 times. Seven
different device-set and CPU combinations produced the exact same hang.
The fix wasn't a QEMU flag: it came from reading the kernel's own release
notes from 1992, which describe exactly this — moving the root filesystem
off the floppy and onto a hard-disk partition, which is a path the
IDE emulation drives correctly. That also meant the emulated hard disk
needed a second, otherwise-blank IDE drive attached: this kernel's disk
driver polls a status register that only reads sensibly when both drive
slots exist, blank or not.

Reset restores a golden checkpoint captured right after the boot banner,
with a keyboard proof and a restore proof both taken on the live station.

What's open: nothing beyond what doesn't exist for this OS release —
pointer and networking are not applicable to Linux 0.12, not deferred.

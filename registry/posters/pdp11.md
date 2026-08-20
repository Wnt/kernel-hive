---
title: DEC PDP-11/70 — 2.11BSD
subtitle: 1975 · PDP-11/70 (2.11BSD, 1991)
hero: /posters/pdp11/desktop.webp
images:
  - src: /posters/pdp11/desktop.webp
    alt: A DEC PDP-11/70 in its tall cabinets, the purple and magenta operator's console with its rows of switches and indicator lamps at the top
    caption: The hero photograph should be a PDP-11/70 in its DEC cabinets, shot square on the operator's console — the magenta and purple front panel with its bank of address and data switches and the lamps above them — with the disk drives and a VT100 terminal in frame if possible. A machine that filled a room and ran twenty people at once.
---
## Origins

Digital Equipment Corporation shipped the first PDP-11 in 1970. It was a
16-bit minicomputer, and its defining idea was that everything — memory,
registers, the terminal, the disk — sat on one bus, the Unibus, at an address.
There were no special instructions for input and output. A program wrote to a
device the way it wrote to memory.

That decision, plus a genuinely orthogonal instruction set, made the PDP-11 a
pleasure to program and a natural target for a compiler. It was also cheap
enough, by the standards of 1970, that a university department or a laboratory
could own one outright rather than renting time on someone else's mainframe.
DEC sold something like 600,000 of them, and kept the line alive until 1997.

The 11/70, announced in 1975, was the top of the range: 22-bit addressing for
up to four megabytes of memory, the line's first cache, a separate high-speed
bus — the Massbus — for the big disks, and, for the first time, a
floating-point processor built into the CPU package. It is the machine most
people picture when they picture a PDP-11 — two tall cabinets, a magenta
console panel, washing-machine disk drives, and a room full of terminals.

## Significance

In 1969 Ken Thompson had written the beginnings of an operating system on a
cast-off PDP-7. In 1970 the work moved to a PDP-11, and it is on this
architecture that both Unix and the C language grew up. Dennis Ritchie designed
C between 1972 and 1973 with this instruction set in front of him; the kernel
was rewritten in it, which is what eventually made Unix portable to anything
else. Sixth Edition Unix (1975) and Seventh Edition (1979) — the versions that
escaped Bell Labs into universities and shaped everything that followed — are
PDP-11 operating systems.

The influence runs in more than one direction from here. DEC's own real-time
system for the PDP-11, RSX-11M, was led by Dave Cutler; when DEC built the VAX
as the PDP-11's 32-bit successor, Cutler's team wrote VMS for it, and Cutler
later went to Microsoft and led Windows NT. Two of the three great operating
system families in this gallery start in this cabinet.

What you are looking at runs **2.11BSD**, released from the University of
California, Berkeley on March 14, 1991, to mark the PDP-11's thirtieth
birthday, and maintained by volunteers ever since. It is the
last BSD for the PDP-11: a backport of 4.3BSD's userland, networking and
development tools onto a machine with a 64 KB address space per process, which
is an extraordinary piece of engineering in its own right. By 1991 the PDP-11
was long obsolete and the people doing this work knew it. They did it anyway.

## What you're looking at

The console of a PDP-11/70 a few seconds after it finished booting, with the
tail of its own startup still on the screen and the machine waiting to be told
who you are.

**Log in as `root`. There is no password.** This image is preserved exactly as
it was distributed, and in 1991 a machine on a departmental network with no
password on root was ordinary.

Then try the things that make it obviously a real Unix and not a picture of
one: `uname -a` names the kernel and the day it was built; `ls /usr/src` is the
complete source code of the operating system you are typing into, kernel
included; `ls /usr/games` still has the games; `man cc` still works. The machine
prints its own line-editing keys at every login — `erase, kill ^U, intr ^C` —
and `^D` logs you out again.

It is slow. It should be. Every character you type crosses a simulated serial
line into a 16-bit machine with four megabytes of memory.

## Legacy

The PDP-11 is the most consequential minicomputer ever built, and its
descendants are all around it in this gallery. Every Unix and Linux tile here —
Solaris, IRIX, 9front, Alpine, Android, postmarketOS — traces back
through a chain of source and ideas to code written on this architecture. So
does the C in which almost all of them are written. Its own successor, the VAX,
gave rise to VMS, and VMS to Windows NT — and the VAX's own descendant,
OpenVMS, still has a tile of its own in this gallery.

The architecture outlived its own obsolescence in the least glamorous way
possible: PDP-11s ran nuclear power stations, air traffic control and factory
floors for decades after DEC stopped selling them, and a few are still running.
The last new PDP-11 left the factory in 1997, twenty-seven years after the
first.

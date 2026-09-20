---
title: RISC OS 3.11 — Acorn Archimedes
subtitle: 1992 · Acorn's ARM desktop — the icon bar, Filer and !applications
hero: /posters/riscos3/desktop.webp
images:
  - src: /posters/riscos3/desktop.webp
    alt: RISC OS 3.11 desktop with the Resources:$.Apps directory window open in the top left showing !Alarm, !Calc, !Chars, !Configure, !Draw, !Edit, !Help and !Paint, the icon bar along the bottom edge, and the pointer on a mid-grey backdrop
    caption: RISC OS at the desktop, with the Apps directory open. Drives, running applications and system tools live on the icon bar instead of in a Start menu, Dock or desktop folder; applications are directories whose names begin with an exclamation mark.
---

## Origins

RISC OS grew out of the same Acorn engineering line that produced the BBC
Micro and the first **ARM** processor. Acorn designed ARM because it wanted
a fast, simple processor for the generation after the 6502. The first
Archimedes machines arrived in 1987; their early desktop software was
called **Arthur**, and the system was renamed **RISC OS** as the desktop and
filing environment matured.

That lineage matters here because Kernel Hive already shows both ends of
the beginning: the **BBC Micro**, whose 6502 generation made Acorn a
fixture in British schools, and the **ARM Evaluation System**, built around
the processor Acorn created to escape that generation's limits. RISC OS is
what happened when that processor became a personal computer platform
rather than an experiment.

RISC OS 3.11 (29 September 1992) is the mature early-1990s form of the
system: recognisably the desktop people remember, on the original
Archimedes 310 hardware rather than a later, faster machine.

## Significance

The RISC OS desktop does not organize itself like Windows or the
Macintosh. Its centre of gravity is the **icon bar** along the bottom
edge. Disks, running applications and system tools appear there; clicking
different mouse buttons on the same object intentionally does different
things — Select, Menu and Adjust are three separate verbs, not one click
and a modifier. The **Filer** presents directories as icon windows, but
applications themselves are usually directories whose names begin with an
exclamation mark — `!Draw`, `!Paint`, `!Edit` — bundles before application
bundles became ordinary elsewhere.

The operating system and the machine were designed together. ARM's low
power and compact instruction set would eventually escape Acorn and
dominate phones, embedded devices and, decades later, personal computers
at global scale. RISC OS shows ARM before that future was obvious: not an
invisible chip inside something else, but the processor underneath a
complete desktop computer, running at 8 MHz with 4 MB of RAM.

For British visitors it is also a school-computing story. Acorn's machines
occupied classrooms and laboratories that elsewhere would have held Apple
IIs, IBM PCs or Commodores, and RISC OS carried that line into the
graphical era.

## What you're looking at

MAME's `aa310` driver emulating an **Acorn Archimedes 310** (ARM2, 8 MHz,
4 MB), running entirely from ROM — the `bios=311` romset selects RISC OS
3.11 and there is no disk attached at all. Power-on reaches the Desktop
directly, in about twenty seconds: a mid-grey Pinboard backdrop and the
icon bar along the bottom, with the floppy drive at `:0`, an Apps
directory viewer, and the palette and Acorn task-manager icons at the
right. The station opens with that Apps directory already on screen, so
`!Draw`, `!Paint`, `!Edit` and the rest are one click away.

All three mouse buttons are live, which matters more here than on most
exhibits: Select opens, **Menu** — the middle button — opens the menu for
whatever is under the pointer, and Adjust does the variant action. Try the
middle button on empty backdrop and the Pinboard menu appears where the
pointer is, rather than in a fixed bar at the top of the screen.

This driver is still `status=preliminary` in MAME's own listing, so the
emulator's ordinary "known problems" panel is suppressed for the exhibit
rather than left in front of visitors — what is on screen once the Desktop
appears is the genuine ROM-resident RISC OS, not a curated substitute.
There is no sound and no networking on this exhibit.

## Legacy

Acorn's computer business eventually disappeared from the mainstream, but
its processor architecture did the opposite. ARM became the dominant
architecture of mobile computing and later returned to laptops and
desktops at enormous scale. RISC OS survived too — its source and
community continued long after the original Archimedes and RiscPC era.

That makes this screen a useful historical inversion. Today ARM is
everywhere and usually invisible. Here it is the thing that makes the
computer unusual, running the desktop built for it.

## Sources

- MAME RISC OS driver notes: https://wiki.mamedev.org/index.php?title=Driver:RiscOS
- RISC OS 3.10/3.11 reference material: https://www.riscos.com/riscos/310/index.php
- Arculator emulator project: https://github.com/dboddie/arculator

---
title: A/UX 3.0.1
subtitle: 1993 · Apple's own System V Unix, wearing the Macintosh Finder
hero: /posters/aux/desktop.webp
images:
  - src: /posters/aux/desktop.webp
    alt: Placeholder card for the A/UX station while the operating system is being installed live — a dark slate frame with the station name
    caption: Install in progress. This card is replaced by the real A/UX desktop once the installation completes and the golden fixture is baked.
---
## Origins

A/UX — "Apple Unix" — was Apple's own port of AT&T's System V Release 2 (with a generous helping of BSD 4.2/4.3 and later SVR3/SVR4 features) to the Macintosh II family, first shipped in 1988. It existed because the U.S. federal government of the late 1980s was writing POSIX compliance into its purchasing rules, and Apple wanted those contracts; it also existed because a handful of engineers inside Apple thought a Macintosh ought to be able to run real Unix.

What made it unlike every other vendor Unix of its day is the desktop. From version 2.0 onward the login shell *is the Macintosh Finder*: the same menu bar, icons and Trash as System 7 — but underneath, `/etc/passwd`, `init`, NFS, TCP/IP and an X11 server are all real, and Unix processes can be dropped onto the desktop next to Mac applications through the "A/UX Toolbox", a Mac OS compatibility layer that runs a genuine System 7 inside a Unix process. Version 3.0 (1992) and 3.0.1 (1993) — the release running here — brought System 7 compatibility and support for the 68040 Quadras.

## Significance

No other station in this hall shows a proprietary GUI and a real Unix cohabiting one desktop metaphor. The Unix workstations (IRIX, HP-UX, Tru64) draw their desktops with Motif; the classic Macs have no shell at all. A/UX has both at once — a `CommandShell` window with a Bourne prompt sits beside a Finder window, and the same files appear in each. It is the direct ancestor of an idea Apple would only fully realise a decade later, with a NeXT-derived Unix under the Mac desktop, in Mac OS X.

The machine is a **Quadra 800** — a 33 MHz 68040 tower from 1993, the same emulated hardware the Mac OS 7.5.3 station runs — because A/UX needs a paged MMU and an FPU, which every 68030/68040 Mac has.

## What you're looking at

Right now: the A/UX 3.0.1 installer, running live from the install CD, on an emulated Quadra 800. Because the archived install CD is not itself ROM-bootable, a small System 7.5.3 helper disk boots the machine and launches Apple's own A/UX disk-setup and startup tools from the CD. The install is being done on camera; this station is not yet announced in the hall.

## Legacy

Apple abandoned A/UX in 1995 with version 3.1.1, in favour of a short-lived alliance with IBM's AIX for the Network Server line. Its ideas did not go anywhere, though: the "familiar desktop, real Unix underneath" wager was exactly the one Apple made again with Mac OS X in 2001 — this time for keeps.

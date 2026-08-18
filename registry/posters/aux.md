---
title: A/UX 3.0.1
subtitle: 1993 · Apple's own System V Unix, wearing the Macintosh Finder
hero: /posters/aux/desktop.webp
images:
  - src: /posters/aux/desktop.webp
    alt: The A/UX 3.0.1 desktop at 1152×870 — a Macintosh menu bar reading File, Edit, Window, Fonts, Commands, Preferences, Keys; a CommandShell window top-left with a "WELCOME TO A/UX" banner, `uname -a`, the date, a fortune and a "localhost.root #" prompt; the Unix root "/" and "MacPartition" disk icons top-right; the Trash bottom-right
    caption: A Unix root prompt in a Macintosh window, with the Unix root directory sitting on the desktop as a disk. That is the whole idea of A/UX in one screen.
---
## Origins

A/UX — "Apple Unix" — was Apple's own port of AT&T's System V Release 2 (with a generous helping of BSD 4.2/4.3 and later SVR3/SVR4 features) to the Macintosh II family, first shipped in 1988. It existed because the U.S. federal government of the late 1980s was writing POSIX compliance into its purchasing rules, and Apple wanted those contracts; it also existed because a handful of engineers inside Apple thought a Macintosh ought to be able to run real Unix.

What made it unlike every other vendor Unix of its day is the desktop. From version 2.0 onward the login shell *is the Macintosh Finder*: the same menu bar, icons and Trash as System 7 — but underneath, `/etc/passwd`, `init`, NFS, TCP/IP and an X11 server are all real, and Unix processes can be dropped onto the desktop next to Mac applications through the "A/UX Toolbox", a Mac OS compatibility layer that runs a genuine System 7 inside a Unix process. Version 3.0 (1992) and 3.0.1 (1993) — the release running here — brought System 7 compatibility and support for the 68040 Quadras.

## Significance

No other station in this hall shows a proprietary GUI and a real Unix cohabiting one desktop metaphor. The Unix workstations (IRIX, HP-UX, Tru64) draw their desktops with Motif; the classic Macs have no shell at all. A/UX has both at once — a `CommandShell` window with a Bourne prompt sits beside a Finder window, and the same files appear in each. It is the direct ancestor of an idea Apple would only fully realise a decade later, with a NeXT-derived Unix under the Mac desktop, in Mac OS X.

The machine is a **Quadra 800** — a 33 MHz 68040 tower from 1993, the same emulated hardware the Mac OS 7.5.3 station runs — because A/UX needs a paged MMU and an FPU, which every 68030/68040 Mac has.

## What you're looking at

A/UX 3.0.1 booted to its desktop on an emulated Quadra 800 at 1152×870, logged in as root. The window top-left is **CommandShell** — a Bourne shell in a Macintosh window, showing the system's welcome banner, `uname -a` and a fortune (the BSD games are installed, along with QuickTime, the manual pages and networking). The disk icon named `/` top-right *is* the Unix root filesystem, browsable in the Finder like any Macintosh volume; `MacPartition` is the small HFS volume that holds A/UX Startup, the Mac program that boots the Unix kernel. Type into the shell, or open folders in the Finder — it is the same filesystem either way.

## Legacy

Apple abandoned A/UX in 1995 with version 3.1.1, in favour of a short-lived alliance with IBM's AIX for the Network Server line. Its ideas did not go anywhere, though: the "familiar desktop, real Unix underneath" wager was exactly the one Apple made again with Mac OS X in 2001 — this time for keeps.

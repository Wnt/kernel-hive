---
title: Amiga UNIX (AMIX)
subtitle: 1992 · Amiga 3000 · System V Release 4 with OPEN LOOK
hero: /posters/amix/desktop.webp
images:
  - src: /posters/amix/desktop.webp
    alt: The AMIX 2.1 desktop — a black-and-white screen one bit deep, with an xterm titled "Amiga UNIX 2.1" showing a uname line over a root prompt, a Calculator window with rounded buttons, and an analogue clock, on a stippled grey background
    caption: AMIX 2.1 on a screen one bit deep. The rounded buttons, the small triangular window menus and the L-shaped resize corners are OPEN LOOK — the desktop AT&T specified for System V Release 4, and the one Motif beat.
---
## Origins

The Amiga 3000, released in June 1990, was Commodore's attempt at a machine an engineering department would take seriously: a 68030 with its memory management unit fitted rather than left out, a 68882 floating-point unit beside it on the 25 MHz model, four 32-bit Zorro III slots, a DMA SCSI controller on the motherboard, and a display enhancer that de-interlaced the Amiga's flickering high-resolution screens onto an ordinary VGA monitor. For the first time an Amiga arrived with the parts a Unix actually needs already on the board.

The MMU is why this exhibit exists. It is what separates a machine that can run one program carefully from a machine that can run many programs safely. Commodore sold that configuration as the **Amiga 3000UX**, launched at UniForum in Dallas in January 1991 with Amiga UNIX installed — $4,999 for five megabytes of memory and a 100 MB disk, $6,999 for nine megabytes, 200 MB and an Ethernet card. The tape drive you needed in order to install it was not in the box; you ordered that separately.

AMIX was not a Unix-like layer over AmigaOS, and it was not a hobby port. It was a licensed **AT&T System V Release 4**, written in-house by Commodore's own Unix group; its architect, Michael Ditto, worked with AT&T as an early-access SVR4 developer and brought a pre-release SVR4 kernel up on Amiga hardware. The whole apparatus came with it — the filesystem switch, STREAMS, TCP/IP, NFS and RFS, the Berkeley commands under `/usr/ucb`, uucp and C News, and GNU Emacs on the installation tape.

The desktop looks eccentric now and was orthodox then. **OPEN LOOK** — pushpins that hold a menu open, rounded buttons, a workspace menu under the right mouse button — was the interface AT&T had specified for System V Release 4 itself, and the one Sun shipped on its own workstations; the rival Open Software Foundation answered with Motif. Commodore licensed SVR4 and took AT&T's desktop along with it, and at that January 1991 UniForum both Sun and Unix International put an Amiga 3000UX on their own stands, as evidence that somebody else had adopted their standard. Motif won anyway: the vendors settled on it for the Common Desktop Environment in 1993, and two exhibits in this hall are that settlement's winning side — Solaris under CDE, and HP-UX under VUE, the Motif environment CDE was built from. Motif was never shipped for AMIX at all.

## Significance

Nobody has ever published how many were sold. Around a thousand machines reportedly went to beta sites before general availability, and no total was announced afterwards, which is its own kind of answer. The software alone cost $995 for a two-user licence and $1,195 for an unlimited one, on top of a machine starting just under $5,000 — sold against a Sun 3/80 at $5,990 and a SPARCstation IPC near $6,695, from companies whose reputation in this business was already made.

Version 2.1, announced in February 1992, was a repricing rather than a technical leap: the same SVR4, X11R4 and OPEN LOOK, now sold as software on its own for A2000s as well as A3000s, with the loaded colour bundle cut for a while to roughly the price of the bare machine. It was also the end. The Unix group's architect had left in October 1991, the A3000UX was gone during 1992, and AMIX never supported the 68040 — so when the Amiga line moved to that processor in the A4000, the machine running AmigaOS 3.5 one tile over, Unix simply did not follow. Support was dropped before Commodore itself collapsed in 1994.

The scarcity is the reason it belongs on a wall. Most people who owned an Amiga never saw one reach a `login:` prompt, and the platform's reputation — games, the Video Toaster, the demoscene — has nothing to do with what is on this screen. The hardware was thought of more highly than the reputation suggests: Virginia Tech's computer science department chose the Amiga 3000 over Sun, DEC, NeXT and Apple in a seventeen-vendor evaluation and required its students to buy one. AMIX is the road the platform did not take — the same custom-chip silicon underneath a multi-user, memory-protected, virtual-memory Unix, in the year Linux was still a student's hobby kernel being announced to Usenet a version at a time.

## What you're looking at

An emulated **Amiga 3000** — 68030 with its MMU, a 68882, 16 MB of memory, Kickstart 2.04 — cold-booting AMIX 2.1 from a SCSI disk. The terminal holds the machine's own account of itself: `UNIX_System_V amix 4.0 2.1 0800430 Amiga (Unlimited) m68k`. The `4.0` is System V Release 4, the `2.1` is Amiga UNIX's own version, and `(Unlimited)` is the licence class — the $1,195 one.

One liberty has been taken with the arrangement. A real A3000UX booted to a text console, and OPEN LOOK was something you started afterwards by typing `olinit`; this station starts it from `/etc/inittab` instead, so the desktop is already up when a visitor arrives.

The two windows beside the terminal are stock X clients. The clock is `xclock`, with hands rather than digits. The calculator is `xcalc` in the TI-30 layout it has worn since the 1980s — but look at the buttons: rounded, not the square Athena rectangles the same program has on every other Unix system in this gallery. The window frames tell the same story. That small triangular button at the left of each title bar is olwm's window menu, and the L-shaped brackets at the four corners are its resize handles.

The screen is **monochrome, 640×512**, and that is the exhibit being accurate rather than cutting a corner. AMIX's X server for the Amiga's own chipset is one bit deep — black and white and nothing else, so the grey backdrop is not a grey at all but a checkerboard of alternating pixels, and every shade on the screen is a dither pattern. Colour did not come from a setting; it came from buying a board. Amiga UNIX had no colour X at all until version 2.0, and even then the installer offers exactly three cards — Commodore's own A2410, the Digital Micronics Resolver, and the Ameristar 1600GX. The A2410 listed at $998 on its own, and the configuration with that board and the multiscanning monitor it wanted came to $7,713. This is the screen the cheaper answer gave you.

## Legacy

Amiga UNIX left no descendants of its own. Unix on the Amiga carried on without Commodore — NetBSD and Linux both ran on 68030 Amigas through the 1990s, for exactly the reason Commodore had been able to ship AMIX at all: the MMU was there. What AMIX proves is the harder half of it. The architecture could carry a full, licensed, commercial Unix, which makes the Amiga's reputation as a games machine a decision the market made rather than a limit the hardware imposed.

The other thing it left is an unusually complete set of survivals. The boot and root floppies and all 29 segments of the installation tape are still around, which is why this station could be installed the way an A3000UX owner installed it — from the tape, one segment at a time, over about two hours — instead of being cloned from somebody else's finished disk.

---
title: SunOS 4.1.4 / OpenWindows
subtitle: 1994 · Sun's BSD Unix and the OPEN LOOK desktop, before CDE
hero: /posters/sunos414/desktop.webp
images:
  - src: /posters/sunos414/desktop.webp
    alt: Placeholder card for the SunOS 4.1.4 station while the operating system is being installed live — a dark frame with the station name
    caption: Install in progress. This card is replaced by the real OpenWindows desktop once the installation completes and the golden fixture is baked.
---
## Origins

SunOS 4 is the last of Sun's BSD-derived operating systems: 4.2BSD networking and virtual memory, Sun's own NFS, and by 4.1.4 (1994, marketed as Solaris 1.1.2) a mature, portable UNIX that ran the SPARC workstations of the late 1980s and early 1990s. It is the SunOS that a generation of universities and engineering shops learned UNIX on — `/etc/rc.local`, `vipw`, the SunView and then OpenWindows desktops.

The desktop matters here. **OpenWindows** was Sun's X11 server with the **OPEN LOOK** toolkit — a look Sun and AT&T designed together for UNIX System V Release 4: bevelled buttons, pushpins that keep menus open, a workspace menu on the right mouse button, `olwm` as the window manager and `cmdtool`, File Manager and Mail Tool as the everyday applications. When the Common Desktop Environment (Motif-based) won the toolkit war in 1993–95, OPEN LOOK went with it; Solaris 2.6 was the last release to ship OpenWindows as a first-class desktop.

## Significance

The hall already has a CDE-era **solaris** station. This one is the other branch of the same family tree: same vendor, same SPARC silicon, a different answer to what a workstation desktop should look like — angular and beveled instead of Motif's shaded 3D, no front panel, menus you can pin to the screen. Side by side they show what Sun gave up when it standardised on CDE.

The machine underneath is a **SPARCstation 5** (`sun4m`) with Sun's older **cg3** colour framebuffer — the one SunOS 4.1.4 actually has a driver for. There is no Sun PROM to source: the emulator boots the machine through OpenBIOS.

## What you're looking at

Right now: `suninstall`, SunOS 4.1.4's text-forms installer, running live from the sun4m install CD on an emulated SPARCstation 5. The install is being done on camera; this station is not yet announced in the hall. When it is finished, this card will show the OpenWindows desktop.

## Legacy

SunOS 4.1.4 was the end of the line: Sun's future was Solaris 2 (SVR4), and 4.1.4 received its last patches in the late 1990s. Its influence is everywhere anyway — NFS, the SunOS/BSD virtual memory design that Solaris kept, and OPEN LOOK's pushpins and pop-up workspace menu, which survive as folklore in every UNIX desktop that came after.

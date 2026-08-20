---
title: SunOS 4.1.4 / OpenWindows
subtitle: 1994 · Sun's BSD Unix and the OPEN LOOK desktop, before CDE
hero: /posters/sunos414/desktop.webp
images:
  - src: /posters/sunos414/desktop.webp
    alt: The OpenWindows 3 desktop on SunOS 4.1.4 — a teal backdrop with the OPEN LOOK cmdtool console, a File Manager, and the "Introducing Your Sun Desktop" help window
    caption: OpenWindows 3 on a SPARCstation 5, logged in as an unprivileged guest — the OPEN LOOK cmdtool, File Manager, and the Sun Desktop introduction.
---
## Origins

SunOS 4 is the last of Sun's BSD-derived operating systems: 4.2BSD networking and virtual memory, Sun's own NFS, and by 4.1.4 — released in 1994 and marketed as **Solaris 1.1.2** — a mature, portable UNIX that ran the SPARC workstations of the late 1980s and early 1990s. It is the SunOS a generation of universities and engineering shops learned UNIX on: `/etc/rc.local`, `vipw`, and the SunView and then OpenWindows desktops.

The desktop is the point of this exhibit. **OpenWindows** was Sun's X11 server married to the **OPEN LOOK** toolkit — a look Sun and AT&T designed together for UNIX System V Release 4. Its widgets are angular and beveled rather than Motif's soft shading; menus carry **pushpins** that keep them open; the right mouse button raises a **workspace menu** anywhere on the backdrop; `olwm` manages the windows, and `cmdtool`, File Manager and Mail Tool are the everyday tools. When the vendors agreed on a Motif-based Common Desktop Environment in 1993, OPEN LOOK's days were numbered — CDE became the default desktop, and OpenWindows lingered on as an option until Solaris 9 dropped it altogether. The end was never in doubt: Sun itself published an OPEN LOOK-to-Motif transition guide that same year.

## Significance

The hall already has a CDE-era **Solaris** station. This one is the other branch of the same family tree: same vendor, same SPARC silicon, a different answer to what a workstation desktop should be. Place them side by side and you can see exactly what Sun set aside when it standardised on CDE — the pushpins, the pop-up workspace menu, the diagonal-hatched three-dimensional widgets that were OPEN LOOK's signature. The hall's HP-UX tile is the other side of the same 1993 settlement: the Motif-based Visual User Environment that machine runs was the primary environment that HP gave to the CDE standard.

The machine underneath is an emulated **SPARCstation 5** (`sun4m`) with Sun's older **cg3** colour framebuffer — the one SunOS 4.1.4 actually ships a driver for. There is no Sun PROM to source: the emulator boots the machine through OpenBIOS.

## What you're looking at

The desktop is logged in as an **unprivileged `guest` user** — note the `sunos414%` shell prompt and the File Manager opened on `/export/home/guest`. Drive it with the **mouse**: the right button raises the OPEN LOOK workspace menu, the File Manager browses the filesystem, windows drag and resize. The "Introducing Your Sun Desktop" window is Sun's own first-run tutorial, exactly as a new SPARCstation owner met it in 1994.

## Legacy

SunOS 4.1.4 was the end of the line: Sun's future was Solaris 2 (the SVR4 rewrite), and 4.1.4 received its last patches in the late 1990s. Its influence outlived it everywhere anyway — NFS, the SunOS/BSD virtual-memory design Solaris kept, and OPEN LOOK's pushpins and pop-up workspace menu, which survive as folklore in every UNIX desktop that came after.

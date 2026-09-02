---
title: Slackware 3.4
subtitle: 1997 · Linux 2.0.30 and a Windows-95-look desktop, from the oldest distribution still run by its founder
hero: /posters/slackware/desktop.webp
images:
  - src: /posters/slackware/desktop.webp
    alt: The fvwm95 desktop at 1024x768 — a flat teal background, an xterm window titled darkstar at the top left with a shell prompt, an analogue xclock at the top right, an FvwmButtons dock at the bottom right with xclock, xload, xterm, xfm, xcalc, xv, kill and a Desktop pager, and a grey Start bar along the bottom edge with a Start button and a clock
    caption: fvwm95 as Slackware 3.4 shipped it — a Start button, a task bar and Windows-95 title bars over a plain X11 desktop. Every button on the dock at the bottom right launches one of the X programs from the distribution's own package series.
  - src: /posters/slackware/xcalc.webp
    alt: The same desktop with the xcalc Calculator window open over the xterm; the xterm behind it shows the output of uname -a, a Linux 2.0.30 kernel built on Tue Jun 24 1997, and the task bar now lists both darkstar and Calculator
    caption: xcalc, the Athena-widget calculator from the X distribution, over an xterm that has just been asked which kernel it runs — Linux 2.0.30, built in June 1997.
---
## Origins

**Slackware** began in 1993 when **Patrick Volkerding** cleaned up the Softlanding Linux System (SLS) — the first distribution most early Linux users had installed — and released his own version of it. It became one of the first widely used Linux distributions, and it is the oldest one still maintained by the person who started it. **Slackware 3.4**, released on 5 October 1997, is a snapshot of Linux at the moment it was turning from a hobbyist kernel into something people ran as a workstation: **Linux 2.0.30**, **XFree86 3.3.1** and a full set of X applications, all installed from tarballs in lettered package series.

The desktop is **fvwm95**, a fork of the fvwm2 window manager that Slackware shipped as its default X session. It reproduces the look of Windows 95 — the Start button, the task bar, the grey title bars — on top of an ordinary X server, which in 1997 was how a Unix machine could be made to look familiar to someone who had just left a PC.

## Significance

Slackware's philosophy has barely changed since this release: plain packages, plain configuration files, no dependency resolution and no distribution-specific tooling between the user and the system. That made it the distribution people learned Unix on, and the one that later distributions defined themselves against. Release 3.4 sits in the 2.0 kernel era, before the 2.2 kernel, before KDE and GNOME, when a Linux desktop meant a window manager, an xterm and whichever X programs came in the `xap` series.

## What you're looking at

An i386 PC with 32 MB of RAM and a Cirrus Logic CL-GD5446 graphics card, which XFree86 3.3.1 drives at 1024 by 768 in 16-bit colour. A serial mouse moves the pointer, so it follows your movements relative to where it is rather than jumping to where you click. The machine's hostname is `darkstar`, the name Slackware has given to a fresh install since the beginning.

The **xterm** at the top left is a bash shell on the running system: `uname -a` reports the kernel, `ls /usr/games` lists the BSD games. The dock at the bottom right opens **xclock**, **xload**, a second **xterm**, the **xfm** file manager, **xcalc**, the **xv** image viewer and a **kill** cursor for closing a misbehaving window; the **Start** button at the bottom left opens fvwm95's menu of the same programs. **Midnight Commander** and **xpaint** are installed alongside.

The exhibit's root filesystem was composed from the release's own `.tgz` packages rather than by running the floppy installer, so what runs is the shipped 1997 software on a disk the exhibit restores when it resets.

## Legacy

Slackware is still released today, still by Patrick Volkerding, and a current install looks and feels much as this one does. This exhibit sits alongside the hall's other small Linux desktop, `tinycore`, and next to the Windows 95 it borrowed its face from.

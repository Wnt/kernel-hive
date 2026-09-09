---
title: OpenBSD 7.9
subtitle: 2026 · the security-first BSD, with the fvwm desktop its own X tree still ships
hero: /posters/openbsd/desktop.webp
images:
  - src: /posters/openbsd/desktop.webp
    alt: The OpenBSD 7.9 fvwm desktop — a flat dark-blue root window; a large white xterm titled root@openbsd top left with the prompt "openbsd#"; an analogue xclock and a pair of xeyes in the top-right corner; the xcalc scientific calculator, reading 0 in DEG and DEC, in the bottom-right corner
    caption: The desktop as it comes up after the console autologin — fvwm 2.2.5 from OpenBSD's own X tree, an xterm as root, and the three classic X toys parked in the corners. Nothing here comes from a package; it is all in the base and X sets.
  - src: /posters/openbsd/corner.webp
    alt: Detail of the top-right and bottom-right corners — xclock with its analogue face, xeyes staring toward the pointer, and the xcalc keypad with its DEG/DEC display and rows of sin, cos, tan, log, ln, hex-digit and arithmetic keys
    caption: xclock, xeyes and xcalc are 1980s X Consortium programs, unchanged in spirit and still built and shipped by Xenocara in 2026. The eyes follow the pointer across the whole screen.
---
## Origins

OpenBSD began at the end of 1995, when **Theo de Raadt** — one of the four founders of NetBSD — was pushed out of that project and started his own from the NetBSD 1.0 tree. The first release, OpenBSD 1.2, followed in mid-1996, and since then a new version has appeared every six months with a regularity most projects only aspire to; **7.9**, the release on this machine, is the one from May 2026.

The project set itself apart with a stated purpose rather than a feature list: to be the most secure general-purpose operating system, by auditing the whole source tree line by line, by turning dangerous behaviour off by default, and by refusing to ship code whose licence the project could not read. That culture produced tools the rest of the world now takes for granted. **OpenSSH**, written by the OpenBSD developers in 1999, is the remote shell on nearly every Unix-like machine on earth. **pf**, the packet filter, replaced a firewall whose licence had become a problem and went on to be adopted by FreeBSD, macOS and others. **LibreSSL** was forked from OpenSSL in 2014 after Heartbleed. **pledge** and **unveil**, two system calls that let a program give up privileges it will never need, are the same idea applied inside the OS itself.

## Significance

OpenBSD's other habit is to keep what works. Where the Linux distributions and the other BSDs took their X Window System from the X.Org release cycle, OpenBSD maintains its own tree, **Xenocara**, built with the same tools and the same care as the kernel, and still ships **fvwm 2.2.5** as the default window manager — a build of a program from the late 1990s, with its Motif-style bevelled frames and root menu, that the project has judged small enough to audit and good enough to keep. The X toys around it — xterm, xclock, xeyes, xcalc, xedit, xman, xlogo — are the applications the X Consortium shipped in the 1980s, and they are still in the X sets today.

That is what this station is for. Most of the hall shows operating systems as they were; this one shows a living system that has chosen not to change the parts it considers finished. The shell is the project's own **ksh**, the compiler is clang, the firewall is pf, and the desktop is the one a visitor to a 1998 Unix workstation would recognise.

## What you're looking at

An amd64 PC with 1 GB of memory, two processor cores, a plain VGA card at 1024 by 768, one virtio disk and a USB tablet for the pointer. OpenBSD boots to a console, logs root in on the first virtual terminal and starts X; about thirty-five seconds after power-on fvwm is up with the layout in the hero image.

The big white window is an **xterm**, running as root — type into it, and the keyboard is yours. `uname -a` names the kernel; `ls /usr/X11R6/bin` lists the X programs; `xlogo &` puts the X logo on the screen. The **xclock** and the **xeyes** live in the top-right corner, the **xcalc** scientific calculator in the bottom-right. **Left- or right-click the empty blue root window** for the applications menu, **middle-click** for the window list, and drag a window by its title bar; fvwm's focus follows the mouse, so the window under the pointer is the one that gets your keystrokes.

The disk is a single image, and the exhibit restores it when it resets, so anything you change belongs to your visit.

## Legacy

Thirty years after the fork, OpenBSD is a small project by headcount and an enormous one by reach: every ssh login, every pf-based firewall and every LibreSSL build carries its code. This exhibit's neighbours from the same family — `netbsd14`, `freebsd411`, `pcbsd` — show the other directions 4.4BSD-Lite went; this is the one that decided correctness was the feature.

---
title: Debian GNU/Linux 2.2
subtitle: 2000 · "potato" · the first Debian with a packaged GNOME desktop
hero: /posters/debian22/desktop.webp
images:
  - src: /posters/debian22/desktop.webp
    alt: Debian GNU/Linux 2.2 running a GNOME 1.0 desktop under XFree86 3.3.6
    caption: GNOME 1.0 on Debian 2.2 — the panel along the bottom edge, a gnome-terminal open on the desktop.
---
## Origins

Debian GNU/Linux 2.2, code-named "potato" after the Mr. Potato Head character in *Toy Story*, was released on 14 August 2000 with Richard Braakman as release manager. It carried Linux kernel 2.2 (2.2.19 by the later point releases), XFree86 3.3.6, GNOME 1.0 and version 0.3 of apt, across roughly 3,900 binary packages for six architectures: i386, m68k, Alpha, SPARC, PowerPC and ARM.

Potato belongs to the Debian of the Social Contract and the Debian Free Software Guidelines, adopted in 1997. Every package in `main` had to meet the DFSG; software that did not — including the Netscape browsers of the day — lived in `non-free`, outside the distribution proper. It was also the last Debian to install from the *boot-floppies* system; its successor, 3.0 "woody", began the move to debian-installer.

## Significance

Potato is the release in which the pieces later distributions took for granted first fit together: a dependency-resolving package manager (apt) over a very large archive, a graphical desktop in `main`, and a release process run by volunteers to a stated policy rather than a schedule. Those properties made Debian the base that others built on; Knoppix, and after it Ubuntu, started from this archive.

GNOME 1.0 itself was under a year old. Potato was the first Debian to ship it packaged and integrated — the panel, the gmc file manager, gnome-terminal and the control centre — alongside the older window managers and the fvwm-era X of XFree86 3.3.6.

## What you're looking at

A GNOME 1.0 desktop, logged in and waiting, with the GNOME panel and a gnome-terminal already focused. XFree86 3.3.6's SVGA server is driving an emulated Cirrus Logic card at 1024×768. The mouse is a PS/2 device reporting relative motion, so the pointer follows your drags rather than jumping to where you point. The guest has no network adapter at all: this is potato as it was on a desk in 2000, before the first `apt-get update`.

Try `cat /etc/debian_version`, `uname -sr`, or `dpkg -l | grep -c '^ii'` to count what is installed.

## Legacy

Debian still releases from the same archive lineage, under the same Social Contract, and its package format and apt are the common ground of most of the Linux desktop. Potato is the last time that machinery could be seen whole on a single CD set, with a desktop small enough to run in 256 MB and floppies still in the box.

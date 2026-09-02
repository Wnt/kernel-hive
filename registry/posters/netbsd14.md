---
title: NetBSD 1.4.1
subtitle: 1999 · the portable BSD, on i386 under the last XFree86 3.3 server
hero: /posters/netbsd14/desktop.webp
images:
  - src: /posters/netbsd14/desktop.webp
    alt: NetBSD 1.4.1 on an i386 PC — the XFree86 3.3.3.1 desktop with an xterm, xclock and xcalc under the ctwm window manager
    caption: NetBSD 1.4.1 booted to an XFree86 3.3.3.1 session on an emulated Cirrus Logic GD5446 — an xterm, xclock and xcalc under the window manager the install sets provide.
---
## Origins

NetBSD descends from **386BSD** and the Berkeley **Net/2** release: the project formed in early 1993 when a group of 386BSD users, tired of waiting on the original maintainers, took the patch kits and published **NetBSD 0.8** in April 1993. The name was a statement of intent — a BSD built and maintained over the network — and from the start its defining goal was portability: one source tree, many architectures, with a clean split between machine-dependent and machine-independent code that the other BSDs later borrowed.

**NetBSD 1.4**, released in May 1999, was the big mid-decade rework. It introduced **sysinst**, a curses installer that replaced a manual shell procedure; the **UVM** virtual-memory system, which replaced the Mach-derived VM inherited from 4.4BSD; the first **USB** support in a BSD; and the machine-independent **wscons** console layer (though the stock i386 GENERIC kernel still shipped with the older `pccons`). It was also the release where the slogan **"Of course it runs NetBSD"** became the project's public face. **pkgsrc**, the packages collection begun in 1997 from FreeBSD's ports, was by then the way third-party software reached the system. **1.4.1**, released 26 August 1999, is the first patch release of that line — the same system with three months of fixes — and it is what runs here.

## Significance

The X server on screen is **XFree86 3.3.3.1**, the last generation of the monolithic XFree86 design: one server binary per card family (`XF86_SVGA` here), each linking its own drivers, configured through an `XF86Config` full of modelines. XFree86 4.0, with a single server and loadable driver modules, arrived in March 2000 and made this arrangement obsolete within a year. The emulated card is a **Cirrus Logic GD5446**, one of the SVGA chips the 3.3 servers supported best, which is why the desktop comes up in colour at all.

The hall's other Unix stations mostly show a vendor's desktop — CDE, OPEN LOOK, Indigo Magic, VUE. This one shows the other tradition: a free BSD on commodity hardware with the bare X Window System and a plain window manager, which is what a 1999 user got after typing `startx`.

## What you're looking at

A 128 MB i486-class PC with an IDE disk, a PS/2 keyboard and mouse, and the Cirrus SVGA card, booted into an X session with an **xterm**, an **xclock** and **xcalc**. Type into the xterm — `uname -a`, `ls /usr/X11R6/bin` — and open more windows from the root menu. The pointer tracks your cursor exactly. That is unusual for a 1999 X server, which only knows a relative PS/2 mouse: here the streamhost daemon connects to the guest's own X server over a loopback port forward and, for every visitor pointer event, warps the X pointer to the visitor's pixel and reads the position back to confirm it landed. Only clicks and keystrokes travel the emulated PS/2 path, so the cursor never drifts from where you point.

## Legacy

NetBSD is still developed — NetBSD 10 shipped in 2024 — and it still runs on more architectures than any other general-purpose operating system, on the same machine-independent design that 1.4 codified. pkgsrc outgrew its home and now builds on Linux, Solaris, macOS and others. sysinst is still the installer. The XFree86 line, by contrast, ended: after the 4.4 licence dispute in 2004 the developers regrouped as X.Org, whose server descends from the 4.x modular design and not from the 3.3 servers you see here.

---
title: Tru64 UNIX 5.1B
subtitle: 2003 · DEC's own UNIX on DEC's own 64-bit iron
hero: /posters/tru64/desktop.webp
images:
  - src: /posters/tru64/desktop.webp
    alt: The Tru64 UNIX 5.1B desktop at 1280×1024 — the Common Desktop Environment's blue-grey backdrop, bare except for a small "Console Log for tru64" window, with the CDE front panel (clock, calendar, file manager, workspace switches, style manager, help, trash) running along the bottom
    caption: The Common Desktop Environment on Tru64 UNIX 5.1B, logged in as an ordinary unprivileged user — the desktop a 2003 DEC Alpha operator sat down to.
---
## Origins

When Digital Equipment Corporation launched the 64-bit Alpha AXP architecture in 1992, it launched an operating system with it: DEC OSF/1, the first commercial release built on the Open Software Foundation's UNIX — the industry consortium's answer to System V — and the first mainstream UNIX to be 64-bit from the start. Renamed Digital UNIX in 1995 and Tru64 UNIX after Compaq's 1998 acquisition of DEC, it stayed what it had always been: the operating system the Alpha was designed around, engineered by the same company that engineered the processor.

Tru64 carried serious machinery for its day — AdvFS, a journaling file system with online resizing years before Linux had an answer; TruCluster, single-system-image clustering that survived node failures; and the CDE desktop that the commercial UNIX world had standardised on.

## Significance

The AlphaServer ES40 emulated here is the natural home of this operating system in a way few pairings in the museum can match: Windows on Alpha was a port that died, Linux on Alpha was an enthusiast effort, but Tru64 *was* the Alpha's system software, tested against every generation of the silicon by the people who designed both. Version 5.1B, released in 2003, was the end of that line. Hewlett-Packard — which had absorbed Compaq, which had absorbed DEC — was winding Alpha down in favour of Itanium, and Tru64's crown jewels (AdvFS, TruCluster) were slated for transplant into HP-UX, the system this museum runs in its own exhibit. The transplant largely never happened; the customers migrated, the platform sunset stretched to 2012, and Tru64 became the last UNIX Digital ever shipped.

## What you're looking at

A finished Tru64 UNIX 5.1B system at its desktop, logged in as an ordinary unprivileged user — the seat a DEC Alpha operator took in 2003. The desktop is the Common Desktop Environment at 1280×1024: CDE as the industry standardised it, the same environment shipped by Sun, HP, IBM and DEC, here in DEC's own colours on DEC's own operating system. It opens bare — the front panel and a console-log window — because the interesting object is the environment itself: press the controls, open the file manager, walk the file system of a UNIX that was engineered alongside the processor it runs on.

There is a real machine underneath. It has a DEC 21143 Ethernet controller, a genuine TCP/IP stack, and a route to the internet — so from the front panel's Netscape control you can open **Netscape Navigator 4.76** and browse the live web, as much of it as still speaks plain HTTP to a browser from the turn of the century — including the world's first website, whose 1992 edition CERN restored in 2013 and still serves from its original address. The machine resolves the name and fetches the document itself; nothing is a recording.

Nothing is staged. The installation you would otherwise be reading about really happened on this exhibit — all 115 software subsets onto an AdvFS file system — and what you see is that installed machine, brought back to this exact moment. Between visits it is frozen mid-instruction rather than shut down, so it resumes where it stood; and when it is reset it returns to this desktop in about three seconds, however the previous visitor left it.

## Legacy

Tru64's ideas outlived it: AdvFS's source was donated to open source in 2008, TruCluster's design shaped later clustering work, and the OSF/1 Mach heritage it carried is a direct ancestor of the kernel architecture in today's macOS. The engineers who built the Alpha and its UNIX scattered into AMD, Intel, and Microsoft, taking out-of-order execution and 64-bit discipline with them. What remains runnable is exactly what this exhibit runs: the 2003 system, on a faithful software recreation of the server it was written for — the same emulated AlphaServer ES40 that hosts the museum's Windows 2000 for Alpha exhibit, the port that never shipped, on the machine the one that did was written for.

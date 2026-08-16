---
title: Tru64 UNIX 5.1B
subtitle: 2003 · DEC's own UNIX on DEC's own 64-bit iron
hero: /posters/tru64/desktop.webp
images:
  - src: /posters/tru64/desktop.webp
    alt: The Tru64 UNIX 5.1B desktop at 1280×1024 — the Common Desktop Environment's blue-grey stippled backdrop, empty, with the CDE front panel across the bottom: analogue clock, date calendar, file manager, text editor, mail, a four-square workspace switcher flanked by lock and exit controls, then printer, style manager, application manager, help and trash
    caption: The Common Desktop Environment on DEC's own UNIX — the 5.1B desktop as it comes up, logged in and idle, drawn by Tru64's own X server on the emulated AlphaServer's S3 graphics.
---
## Origins

When Digital Equipment Corporation launched the 64-bit Alpha AXP architecture in 1992, it launched an operating system with it: DEC OSF/1, the first commercial release built on the Open Software Foundation's UNIX — the industry consortium's answer to System V — and the first mainstream UNIX to be 64-bit from the start. Renamed Digital UNIX in 1995 and Tru64 UNIX after Compaq's 1998 acquisition of DEC, it stayed what it had always been: the operating system the Alpha was designed around, engineered by the same company that engineered the processor.

Tru64 carried serious machinery for its day — AdvFS, a journaling file system with online resizing years before Linux had an answer; TruCluster, single-system-image clustering that survived node failures; and the CDE desktop that the commercial UNIX world had standardised on.

## Significance

The AlphaServer ES40 emulated here is the natural home of this operating system in a way few pairings in the museum can match: Windows on Alpha was a port that died, Linux on Alpha was an enthusiast effort, but Tru64 *was* the Alpha's system software, tested against every generation of the silicon by the people who designed both. Version 5.1B, released in 2003, was the end of that line. Hewlett-Packard — which had absorbed Compaq, which had absorbed DEC — was winding Alpha down in favour of Itanium, and Tru64's crown jewels (AdvFS, TruCluster) were slated for transplant into HP-UX. The transplant largely never happened; the customers migrated, the platform sunset stretched to 2012, and Tru64 became the last UNIX Digital ever shipped.

## What you're looking at

A finished Tru64 UNIX 5.1B system, logged in and sitting at its desktop: the Common Desktop Environment at 1280×1024, its front panel along the bottom edge — clock, calendar, file manager, text editor, mail, four workspaces, and the tools of a 2003 commercial UNIX workstation. This is CDE as the industry standardised it, the same desktop shipped by Sun, HP, IBM and DEC, here in DEC's own colours on DEC's own operating system.

Nothing is staged. The installation you would otherwise be reading about really happened on this exhibit — all 115 software subsets onto an AdvFS file system — and what you see is that installed machine, brought back to this exact moment. Between visits it is frozen mid-instruction rather than shut down, so it resumes where it stood; and when it is reset it returns to this desktop in about three seconds, however the previous visitor left it.

The desktop is deliberately bare. CDE opens with the front panel and nothing else, because the interesting object here is the environment itself: press the controls, open the file manager, walk the file system of a UNIX that was engineered alongside the processor it runs on.

## Legacy

Tru64's ideas outlived it: AdvFS's source was donated to open source in 2008, TruCluster's design shaped later clustering work, and the OSF/1 Mach heritage it carried is a direct ancestor of the kernel architecture in today's macOS. The engineers who built the Alpha and its UNIX scattered into AMD, Intel, and Microsoft, taking out-of-order execution and 64-bit discipline with them. What remains runnable is exactly what this exhibit runs: the final release, on a faithful software recreation of the server it was written for.

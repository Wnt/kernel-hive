---
title: Tru64 UNIX 5.1B
subtitle: 2003 · DEC's own UNIX on DEC's own 64-bit iron
hero: /posters/tru64/desktop.webp
images:
  - src: /posters/tru64/desktop.webp
    alt: The Tru64 UNIX 5.1B graphical installer's opening screen at 1024×768 — a grey dialog on a deep maroon backdrop offering English Installation, Japanese, and Chinese, with English preselected and an OK button below
    caption: The installation begins — the 5.1B installer's X11 language chooser, drawn by the operating system's own X server running straight off the install CD.
---
## Origins

When Digital Equipment Corporation launched the 64-bit Alpha AXP architecture in 1992, it launched an operating system with it: DEC OSF/1, the first commercial release built on the Open Software Foundation's UNIX — the industry consortium's answer to System V — and the first mainstream UNIX to be 64-bit from the start. Renamed Digital UNIX in 1995 and Tru64 UNIX after Compaq's 1998 acquisition of DEC, it stayed what it had always been: the operating system the Alpha was designed around, engineered by the same company that engineered the processor.

Tru64 carried serious machinery for its day — AdvFS, a journaling file system with online resizing years before Linux had an answer; TruCluster, single-system-image clustering that survived node failures; and the CDE desktop that the commercial UNIX world had standardised on.

## Significance

The AlphaServer ES40 emulated here is the natural home of this operating system in a way few pairings in the museum can match: Windows on Alpha was a port that died, Linux on Alpha was an enthusiast effort, but Tru64 *was* the Alpha's system software, tested against every generation of the silicon by the people who designed both. Version 5.1B, released in 2003, was the end of that line. Hewlett-Packard — which had absorbed Compaq, which had absorbed DEC — was winding Alpha down in favour of Itanium, and Tru64's crown jewels (AdvFS, TruCluster) were slated for transplant into HP-UX. The transplant largely never happened; the customers migrated, the platform sunset stretched to 2012, and Tru64 became the last UNIX Digital ever shipped.

## What you're looking at

The exhibit currently shows Tru64 UNIX **being installed** — a deliberately unusual museum piece. The opening frame is the 5.1B installer's language chooser, an X11 dialog drawn at 1024×768 by the X server that boots straight off the installation CD; from there the installation proceeds through disk labelling, subset selection, and the long file-set copy to its first boot of the CDE desktop. Once the installation completes, this poster's hero image becomes the finished CDE session — the Common Desktop Environment's front panel on DEC's own UNIX.

## Legacy

Tru64's ideas outlived it: AdvFS's source was donated to open source in 2008, TruCluster's design shaped later clustering work, and the OSF/1 Mach heritage it carried is a direct ancestor of the kernel architecture in today's macOS. The engineers who built the Alpha and its UNIX scattered into AMD, Intel, and Microsoft, taking out-of-order execution and 64-bit discipline with them. What remains runnable is exactly what this exhibit runs: the final release, on a faithful software recreation of the server it was written for.

---
title: Windows 2000 for Alpha — RC2
subtitle: 1999 · the Windows that never shipped
hero: /posters/w2kalpha/desktop.webp
images:
  - src: /posters/w2kalpha/desktop.webp
    alt: Windows 2000 RC2 build 2128 desktop with System Properties open, reporting Microsoft Windows 2000 5.00.2128 on a DEC-221264 Clipper/Tsunami platform with 512 MB of RAM
    caption: System Properties tells the whole story in three lines — Windows 2000 build 2128, a DEC 21264 processor, and the Clipper/Tsunami AlphaServer platform. The "Evaluation copy. Build 2128" badge at lower right marks Release Candidate 2, the last Windows ever built for Alpha.
---
## Origins

Digital Equipment Corporation launched the Alpha AXP architecture in 1992 as a clean-sheet 64-bit RISC design, and for most of the decade it was simply the fastest processor money could buy. Windows NT was on Alpha from the very beginning — NT 3.1 shipped for it in 1993 — and through NT 4.0 the Alpha remained the flagship non-Intel port, complete with FX!32, the binary translator that ran ordinary x86 Windows applications on Alpha at usable speed. DEC's engineers liked to point out that NT's famous portability was not an abstraction: it was tested, released, and sold on their hardware.

Windows 2000 — NT 5.0 — was to continue that line, and Microsoft carried the Alpha port through every beta. The machine emulated here, Compaq's AlphaServer ES40, was the platform at the end of that road: a server built around the 21264, the out-of-order Alpha that traded blows with everything else in the industry, on the Tsunami "Clipper" chipset that System Properties names on screen.

## Significance

In August 1999, Compaq — which had bought DEC the year before — announced it was ending support for Windows NT on Alpha, and Microsoft stopped the port. The timing gave the story its edge: Windows 2000 was feature-complete and weeks from Release Candidate 2. Build 2128, stamped September 1999, was produced for Alpha as well as x86 — and then the Alpha version simply never shipped. No retail box, no support lifecycle, no service packs. The 64-bit Windows work that had been pathfinding on Alpha moved over to Intel's coming Itanium instead, which meant the first 64-bit Windows the public ever saw arrived years later on a different architecture.

Release Candidate 2 for Alpha survived anyway, the way interesting software does, and became a small legend among collectors: a complete, working, professional operating system for a dead platform — the last Windows for Alpha in existence.

## What you're looking at

The screen shows Windows 2000 Professional, build 2128, logged on to a clean desktop at 1280×1024 with the System Properties dialog open. The three lines under "Computer:" are the exhibit's credentials: DEC-221264 is the 21264 Alpha processor, DEC-00Clipper_tsunmp is the ES40's Clipper platform on the Tsunami chipset, and the machine reports 512 MB of RAM. The "Evaluation copy. Build 2128" watermark above the clock is Microsoft's own release-candidate marking.

Everything else is exactly the Windows 2000 the world remembers — the same Explorer shell, the same five desktop icons, the same taskbar — which is precisely the point. This was not a port in progress; it was a finished Windows on the wrong side of a business decision.

## Legacy

Alpha's own story ended in stages — Compaq wound the architecture down and the design teams dispersed, taking their ideas into AMD's Athlon and Opteron and into Intel — but NT's multi-architecture discipline, which Alpha did more than any other platform to keep honest, is why Windows later moved to x86-64 and ARM with its kernel intact. The emulated AlphaServer ES40 running this exhibit is itself a piece of preservation engineering: es40, an open-source emulation of the real machine's firmware, chipset, and devices, faithful enough that an operating system Microsoft never released boots on hardware that no longer needs to exist.

---
title: Windows 2000 for Alpha — RC2
subtitle: 1999 · the Windows that never shipped
hero: /posters/w2kalpha/dxdiag.webp
images:
  - src: /posters/w2kalpha/dxdiag.webp
    alt: The Windows 2000 DirectX Diagnostic Tool on the Alpha guest, its System page reporting the processor outright as "Alpha 21264 Model A - Pass 2", the computer name W2KALPHA, Windows 2000 build 2128, and 512 MB of RAM
    caption: The DirectX Diagnostic Tool (run "dxdiag") says in plain words what System Properties only hints at — Processor "Alpha 21264 Model A - Pass 2". No x86 machine ever names that chip. It is the clearest single view that this Windows is running on Digital's 64-bit RISC, not an Intel PC.
  - src: /posters/w2kalpha/x86prog.webp
    alt: The x86 Program Optimization window ("x86 Programs") listing Winamp v2.5e, the Winamp installer, and Windows games — Solitaire, FreeCell, Minesweeper, Calculator, Notepad — each translated by FX!32 and shown at 100% optimization
    caption: Because the CPU is not x86, ordinary x86 Windows software runs here through FX!32, the binary translator. The "x86 Program Optimization" panel (run "x86prog") lists what it has translated and cached to native Alpha code — Winamp 2.5e, Solitaire, Minesweeper and more — each optimized to 100%. This control panel simply cannot exist on an x86 PC.
  - src: /posters/w2kalpha/desktop.webp
    alt: Windows 2000 RC2 build 2128 desktop with System Properties open, reporting Microsoft Windows 2000 5.00.2128 on a DEC-221264 Clipper/Tsunami platform with 512 MB of RAM
    caption: System Properties tells the same story in three cryptic lines — Windows 2000 build 2128, the DEC-221264 (21264) processor, and the DEC Clipper/Tsunami AlphaServer platform. The "Evaluation copy. Build 2128" badge at lower right marks Release Candidate 2, the last Windows ever built for Alpha.
---
## Origins

Digital Equipment Corporation launched the Alpha AXP architecture in 1992 as a clean-sheet 64-bit RISC design, and for most of the decade it was simply the fastest processor money could buy. Windows NT was on Alpha from the very beginning — NT 3.1 shipped for it in 1993 — and through NT 4.0 the Alpha remained the flagship non-Intel port, complete with FX!32, the binary translator that ran ordinary x86 Windows applications on Alpha at usable speed. DEC's engineers liked to point out that NT's famous portability was not an abstraction: it was tested, released, and sold on their hardware.

Windows 2000 — NT 5.0 — was to continue that line, and Microsoft carried the Alpha port through every beta. The machine emulated here, Compaq's AlphaServer ES40, was the platform at the end of that road: a server built around the 21264, the out-of-order Alpha that traded blows with everything else in the industry, on the Tsunami "Clipper" chipset that System Properties names on screen.

## Significance

In August 1999, Compaq — which had bought DEC the year before — announced it was ending support for Windows NT on Alpha, and Microsoft stopped the port. The timing gave the story its edge: Windows 2000 was feature-complete and weeks from Release Candidate 2. Build 2128, stamped September 1999, was produced for Alpha as well as x86 — and then the Alpha version simply never shipped. No retail box, no support lifecycle, no service packs. The 64-bit Windows work that had been pathfinding on Alpha moved over to Intel's coming Itanium instead, which meant the first 64-bit Windows the public ever saw arrived years later on a different architecture.

Release Candidate 2 for Alpha survived anyway, the way interesting software does, and became a small legend among collectors: a complete, working, professional operating system for a dead platform — the last Windows for Alpha in existence.

## What you're looking at

The exhibit runs Windows 2000 Professional, build 2128, logged on to a clean desktop at 1280×1024. Two built-in tools make the machine name itself. The **DirectX Diagnostic Tool** — Microsoft's own `dxdiag`, on every Windows of the era — puts it plainly on its System page: Processor "Alpha 21264 Model A - Pass 2", computer name W2KALPHA, 512 MB of RAM. No Intel or AMD PC ever reports that processor line; it is the single most obvious proof of what the CPU really is. System Properties says the same thing in three cryptic strings — DEC-221264, the DEC Clipper/Tsunami platform, 512 MB — which is why the diagnostic tool reads so much more clearly.

The second window is stranger and more revealing: **x86 Program Optimization** (`x86prog`, reached from System Properties → Advanced → Performance Options). Because the processor is not x86, ordinary 32-bit Windows software cannot run natively — it is translated on the fly by **FX!32**, the same binary translator that let NT-on-Alpha run x86 applications through the NT 4.0 years. The panel lists what FX!32 has profiled and compiled to native Alpha code — Winamp 2.5e and its installer, Solitaire, FreeCell, Minesweeper, Calculator, Notepad — each at 100% optimization. A control panel devoted to *optimizing x86 programs* is something an x86 PC has no reason to contain; its mere presence is an architecture fingerprint.

Everything around them is exactly the Windows 2000 the world remembers — the same Explorer shell, the same desktop icons, the same taskbar, even Winamp — which is precisely the point. This was not a port in progress; it was a finished Windows, able to run the everyday software of its day, on the wrong side of a business decision.

## Legacy

Alpha's own story ended in stages — Compaq wound the architecture down and the design teams dispersed, taking their ideas into AMD's Athlon and Opteron and into Intel — but NT's multi-architecture discipline, which Alpha did more than any other platform to keep honest, is why Windows later moved to x86-64 and ARM with its kernel intact. The emulated AlphaServer ES40 running this exhibit is itself a piece of preservation engineering: es40, an open-source emulation of the real machine's firmware, chipset, and devices, faithful enough that an operating system Microsoft never released boots on hardware that no longer needs to exist.

---
title: Apple IIGS
subtitle: 1986 · GS/OS 6.0.1 — the Apple II gets a colour desktop
hero: /posters/apple2gs/desktop.webp
images:
  - src: /posters/apple2gs/desktop.webp
    alt: The GS/OS 6.0.1 Finder on an Apple IIGS — a colour Super Hi-Res desktop with the boot volume's window open on folder and document icons, the menu bar across the top and the disk icon at the right edge
    caption: A Finder desktop in colour on a machine descended from the 1977 Apple II — and six months before any Macintosh could show a colour screen at all.
---
## Origins

The Apple IIGS shipped on **15 September 1986** at **$999** without a monitor, and it was two arguments settled at once. Apple's 8-bit line was still paying the bills — the //e was in every school district in the country — while the Macintosh was the future the company had bet on and had so far sold in disappointing numbers. The IIGS was the machine that tried to be both: a **WDC 65C816** at **2.8 MHz**, a 16-bit processor that runs the 6502's instruction set natively, so that the entire Apple II software library of the previous decade kept working, and on top of it a bitmapped colour screen, a mouse, an ADB keyboard and a windowing operating system.

The hardware Apple put around that processor was better than the machine's reputation suggests. The **Super Hi-Res** display gives 320×200 in sixteen colours or 640×200 in four, both chosen from a palette of **4,096** — and the palette can be swapped per scan line, which is how demo programmers got 3,200 colours onto one screen. Sound is an **Ensoniq ES5503 DOC**, a 32-oscillator wavetable chip designed by the company that would build the Mirage sampler; nothing else on a desk in 1986 sounded like it, and nothing in the Macintosh line would for years. Memory started at 256 KB and went to 8 MB. The first 50,000 machines carried **Steve Wozniak's facsimile signature** on the faceplate with "Limited Edition" beneath it, marking ten years since the Apple II.

The IIGS also carried the family's quiet compromise. At 2.8 MHz it was clocked well below what a 65C816 could do, the operating system spent its first two years as **ProDOS 16**, essentially 8-bit ProDOS wearing a 16-bit coat, and the software that made the machine worth owning arrived late. **GS/OS** — written properly in 65816 code — did not land until 1988. The version this station runs, **System 6.0.1**, is the last one Apple ever shipped for the Apple II, released on **6 May 1993**, seven years after the hardware and a year before Apple discontinued the line.

## Significance

The date is the whole argument. The Macintosh of 1986 was a monochrome machine; the **Macintosh II**, the first Mac that could show colour, arrived in **March 1987**. For roughly six months, the only Apple computer with a colour graphical desktop was the one in the 8-bit family — running on a processor whose ancestor cost twenty-five dollars, addressing the same slots and reading the same 5.25" floppies as a 1977 Apple II sitting two exhibits down this hall.

That is not a trivia point. The Apple II group in this hall runs three ways of meeting the same architecture: the **Apple //e** exhibit boots ProDOS to a text menu, which is what the machine actually was to most of the people who used it; the **Apple GEOS** exhibit shows what that hardware could be persuaded to look like in 1988 with enough hand-tuned 6502 assembly; and this one shows what happened when Apple stopped persuading and built the colour desktop into the silicon. Same bus, same disks, three decades of interface history laid end to end.

What the IIGS proves, and what makes it a slightly sad machine, is that the constraint on a good graphical desktop in the mid-1980s was never the idea and by 1986 was no longer the hardware — it was which product line a company had decided to bet on. The IIGS was faster than the Mac at colour, better than the Mac at sound, compatible with a library the Mac could not touch, and it was the machine Apple chose not to push. It was discontinued in December 1992; the Macintosh got the decade.

## What you're looking at

An Apple IIGS with **ROM 3** and **1 MB** of memory, emulated cycle-accurately by MAME running host-native on the exhibit machine. The boot volume is a ProDOS hard disk on a CFFA 2.0 card in slot 7 — the same period-correct hard-disk trick the //e exhibit uses — carrying **GS/OS System 6.0.1** and **Finder 6.0.1**, which is where the machine lands and stays.

The desktop in front of you is Super Hi-Res: icons, overlapping windows, a menu bar, and a two-button **ADB mouse** on the motherboard rather than a card in a slot. Open the boot volume and the folders behave the way the Macintosh taught everyone folders behave, because this Finder and that one were built to the same human-interface guidelines by the same company in the same building. The **Control Panel** is the exhibit's own demonstration: it is where the colour palette lives, and changing a desktop colour on a machine from the Apple II family is the moment that makes the point better than any caption can.

The keyboard is the Apple Extended ADB layout, and the modifier marked with an open apple is doing **Command**'s job here, not the joystick-button job it does on a //e. Reset returns the disk and the desktop to the state above, so whatever you open, drag or recolour belongs to your visit alone.

## Legacy

Apple stopped selling the IIGS in December 1992 and released its last system software the following May. Nothing was built on it afterwards; GS/OS has no descendants, and the Apple II line ended with it. What survives is a demonstration, and it is the reason this exhibit is here rather than as a footnote to the //e: the ideas that the Macintosh is credited with carrying into colour were already running, in colour, on the architecture the Macintosh was built to replace. The machine that lost is sitting in front of you doing the winner's job first.

## Sources

- [Apple IIGS — Wikipedia](https://en.wikipedia.org/wiki/Apple_IIGS) — release date, $999 introductory price, 65C816 at 2.8 MHz, Super Hi-Res modes and the 4,096-colour palette, Ensoniq ES5503, the Woz Limited Edition faceplate on the first 50,000 units.
- [Apple GS/OS — Wikipedia](https://en.wikipedia.org/wiki/Apple_GS/OS) — ProDOS 16 to GS/OS, and System 6.0.1 / GS/OS 4.02 as the final release.
- [GS/OS System 6.0.1 FST Disassembly — 6502disassembly.com](https://6502disassembly.com/a2-gsos/) — the 6 May 1993 release date of System 6.0.1.
- [Apple II History §11, The Apple IIGS](https://www.apple2history.org/history/ah11/) and [§15, DOS 3.3, ProDOS & Beyond](https://www.apple2history.org/history/ah15/) — the ProDOS 16 interim years and the system-software timeline.
- [apple-history.com — Apple IIGS](https://apple-history.com/aIIgs) — memory configurations and the end of the line.
- Machine facts (ROM set, `macadb` HLE ports, CFFA 2.0 slot availability) read from MAME's own `-listxml apple2gs` in this wave; see `docs/lab/APPLE2GS-WAVE.md`.

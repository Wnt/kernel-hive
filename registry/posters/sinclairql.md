---
title: Sinclair QL — the serious machine, shipped early
subtitle: 1984 · Sinclair QL (QDOS · SuperBASIC)
hero: /posters/sinclairql/desktop.webp
images:
  - src: /posters/sinclairql/desktop.webp
    alt: The Sinclair QL's power-on screen — a green-bordered box reading "F1...monitor / F2...TV" above a red bar reading "(c) 1983 Sinclair Research Ltd"
    caption: Before the QL will draw anything else it asks what it is plugged into. This exhibit answered F1.
---
## Origins

Sinclair Research announced the QL on 12 January 1984, twelve days before Apple announced the Macintosh, and the timing was not an accident: this was the machine with which Clive Sinclair intended to leave the toy market behind. "QL" stood for Quantum Leap. Inside a flat black wedge the size of a keyboard sat a Motorola 68008 — a 68000 with an eight-bit bus, so a 32-bit processor at a price Sinclair could bear — 128 KB of memory, two Microdrive tape cartridges for storage, and an operating system called QDOS that could genuinely run several programs at once, on a machine costing £399. Psion wrote four applications to go with it: a word processor, a spreadsheet, a database and a business graphics package.

It was not finished. Orders were taken from January with a promise of delivery in twenty-eight days; the first machines went out around April, and supply only became normal in the second half of the year. **The firmware did not fit.** The QL's ROM had grown past the space on the board, and the earliest machines were shipped with the overflow on a small circuit board plugged into the expansion connector at the back — a ROM cartridge, universally nicknamed the "kludge", sticking out of the machine like an afterthought, because it was one. Later revisions of the firmware fitted inside, and Sinclair swapped them out; the ones already sold kept their dongles.

## Significance

Strip away the launch and the QL is a genuinely interesting computer, and it was interesting in ways the rest of 1984 was not.

QDOS, designed in-house by Tony Tebby, multitasked pre-emptively in 48 KB of ROM, at a time when the Macintosh and the IBM PC both ran one program at a time. SuperBASIC, its built-in language, had proper procedures and functions with parameters, local variables and recursion, and no line numbers were required to call any of it — a structured language in the ROM of a home computer. The screen was addressable as two graphics modes and as independently scrolling windows, which is why this exhibit shows three coloured panels rather than one blank page: the QL divides its display before you have typed anything.

Its weakness was where its data lived. The Microdrive was Sinclair's answer to the floppy disc: a continuous loop of video tape in a cartridge the size of a matchbox, holding about 100 KB, spinning past a fixed head. It was cheap and it was fast for tape, and it was not reliable enough for work you cared about, which is the single fact most people who owned a QL will mention first.

## What you're looking at

The machine one keystroke after power-on. The QL's very first act is to ask whether it is connected to a monitor or a television, because the two need different screen widths; the placard image above is that question, and this exhibit answered **F1** for the 80-column monitor mode.

What is left is a SuperBASIC screen with nothing on it: a white window, a red window, and a black command strip along the bottom. There is no `READY.` — the QL simply waits. Type into the command strip and it answers, and the on-screen keyboard offers the three lines worth knowing: **MODE 8** drops the display into the eight-colour television mode the machine was usually seen in, **MODE 4** brings back the sharp 512-pixel monitor mode, and **CLS** clears the strip. The QL's own F1–F5 keys are there too, along with its BREAK (Ctrl+Space).

## Legacy

Sinclair sold his computer business to Alan Sugar's Amstrad in April 1986 — the company whose own CPC range has a tile in this museum — and the QL, some 150,000 of them made, was discontinued within months. It never became the office machine it was built to be.

It kept working on people, though. The Psion suite's descendants ran on Psion's own organisers and, through them, on Symbian phones for two decades. And a Finnish student — who at ten had dabbled on his grandfather's Commodore VIC-20, on its own tile in this museum — bought a QL in 1987 with his savings, found QDOS too closed to modify, wrote his own machine-code tools for it, and later described the experience as the reason he wanted an operating system whose source he could change. His next computer was a 386, and what he wrote on it was Linux.

---
title: Acorn ARM Evaluation System — the first ARM you could buy
subtitle: 1986 · ARM Evaluation System (ARM BBC Basic V)
hero: /posters/armeval/desktop.webp
images:
  - src: /posters/armeval/desktop.webp
    alt: The ARM Evaluation System's screen — ARM Second Processor 4096K, Acorn ADFS, BASIC, two blue A* supervisor lines reading *LIB $ and AB, then the ARM BBC Basic V 1.00 banner and a > prompt
    caption: Three colours, black, white and one blue. The two blue lines are the machine loading its own language off a floppy; everything below them is running on the ARM.
---
## Origins

Acorn had a problem that its own success created. The BBC Micro had sold in numbers nobody forecast, but its 6502 was an eight-bit part from 1975 and the sixteen-bit successors on the market — the 68000, the 16032, the 286 — were, when Acorn's engineers actually measured them, disappointing. The chips were large, slow to respond to interrupts, and expensive. Acorn's own Cambridge instinct was that the right answer was smaller, not bigger.

Sophie Wilson wrote the instruction set. Steve Furber designed the chip. The team was a dozen people, the budget was nothing like a semiconductor company's, and the constraint that shaped everything was that Acorn could not afford to be wrong twice — so the design was kept simple enough to be fully understood by the people building it. Sophie Wilson and Furber's Acorn RISC Machine had a fixed 32-bit instruction word, sixteen registers, and conditional execution on every instruction.

**The first ARM silicon arrived on 26 April 1985, and it worked first time.** The famous part of the story is what happened next: the engineers ran their test programs, watched the chip execute them correctly, and then noticed that the ammeter wired in series with its power supply was reading **zero**. The board had a fault and was not delivering power to the chip at all. The ARM was running on leakage current bleeding in through the signals on its I/O pins — a few milliwatts, from a design so austere it had never been told it needed more. Acorn had not set out to build a low-power processor. It had built one anyway, and that accident is the reason the chip in your pocket is an ARM.

That silicon needed customers before there was a computer to put it in. In 1986 Acorn shipped the ARM Evaluation System: an ARM, 4 MB of memory and a supervisor ROM on a second-processor board that hung off a BBC Micro's Tube, with a six-disc ADFS software set — assembler, utilities, Cambridge LISP, PROLOG and FORTRAN 77 — for around £4,500. It is the first ARM product ever sold.

## Significance

The ARM Evaluation System is not a computer. It has no operating system, no keyboard, no screen and no filing system of its own. It is a processor on the end of a cable, and the BBC Micro on the other end — the machine that a moment ago *was* the computer — is demoted to a terminal and a disc controller. The BBC Micro doing that terminal work is this hall's other Acorn exhibit, and its Tube port — built to hand a machine's main job to a second processor — was designed for exactly this moment.

That inversion is the whole point of Acorn's Tube, and it is why the Tube existed years before there was anything worth putting on the far end of it. The host handles the keyboard, the screen and the discs; the second processor gets the memory and the work. When ARM BBC Basic V asks to print a line, the request travels back down the Tube to a 2 MHz 6502 to be drawn.

What Acorn sold in that box was time. The Archimedes did not ship until 1987, and the software that made it worth buying had to be written before the machine existed. Everyone who wrote ARM code in that window — the compiler people, the Cambridge LISP and PROLOG ports, the operating system that became RISC OS and still runs in this hall as the 2022 RISC OS 5.30 exhibit — wrote it on one of these.

The processor inside it is the direct ancestor of a design that now ships in the region of thirty billion units a year, in phones, cars, drives, watches, and the machine you are almost certainly reading this on.

## What you're looking at

The ARM's own screen, drawn through the BBC Micro that is acting as its terminal.

`ARM Second Processor 4096K` is the co-processor announcing itself and its four megabytes — a hundred and twenty-eight times the host's 32 KB, in 1986. `Acorn ADFS` and `BASIC` are what the *host* has fitted: the Advanced Disc Filing System, needed because the evaluation system's discs are double density and the BBC's standard 8271 controller cannot read them at all, and the host's own BBC BASIC, which nothing here will use.

Then two lines in blue. `A*` is the ARM supervisor's prompt — the 16 KB monitor in ROM that is the only software the board owns. `*LIB $` sets the disc library, and `AB` runs a program off Disc 3 of the evaluation set. `AB` is ARM BBC Basic V, and the line under it is that language introducing itself: **ARM BBC Basic V version 1.00 for ARM Second Processor (C) Acorn 1986.**

Those two blue lines are left on the screen deliberately. They are the provenance of the prompt beneath them: a processor with no operating system, fetching a language off a floppy through a computer it has taken over.

The `>` is ARM BASIC waiting. Type a line and a 1986 ARM executes it. Twenty thousand empty `FOR` loops take it about a fifth of a second; the 6502 sitting between you and it would need the better part of a minute for the same work.

## Legacy

Acorn spun the processor out in 1990 as a joint venture with Apple and VLSI Technology, on the strength of Apple wanting an ARM for the Newton. The new company, Advanced RISC Machines Ltd., started with twelve engineers in a converted barn in Cambridgeshire and a business model nobody in the industry rated: it would not make chips at all, it would license the design and let other people make them.

That model, and the accidental low power that made the design worth licensing, are why the ARM instruction set outlived every processor family it was benchmarked against in 1985. The Archimedes it was built for is a footnote. The instruction set is not.

This board is where that became purchasable. What is on the screen in front of you — an ARM running a language it loaded off a floppy through a borrowed 6502 — is what "the first ARM product" actually looked like to the first people who bought one.

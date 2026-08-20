---
title: Acorn BBC Micro Model B — the machine that taught Britain to program
subtitle: 1981 · BBC Micro Model B (BBC BASIC II)
hero: /posters/bbcmicro/desktop.webp
images:
  - src: /posters/bbcmicro/desktop.webp
    alt: The BBC Micro's power-on screen — BBC Computer 32K, Acorn DFS, BASIC, and a blinking > prompt in white teletext on black
    caption: Four lines and a prompt. The machine tells you how much memory it has, what filing system is fitted, what language it speaks, and then waits for you.
---
## Origins

In 1980 the BBC decided to make a television series about computers, and then made an unusual decision about it: rather than film whatever machines happened to be on sale, it would specify a computer of its own and put the corporation's name on it. The Computer Literacy Project needed a machine that could demonstrate everything the programmes wanted to cover — graphics, sound, networking, control of external hardware, several programming languages — and that schools could actually buy.

The specification went out to British manufacturers. Acorn Computers, a small Cambridge firm founded by Hermann Hauser and Chris Curry, had an unfinished successor to its Atom, the Proton, in the drawer. The story of the week that followed is well attested: Acorn's engineers, Sophie Wilson and Steve Furber among them, built a working prototype of a machine that did not yet exist in time for the BBC's visit — reportedly, by 7 a.m. the morning the delegation was due. Acorn won the contract.

The BBC Microcomputer shipped in December 1981 in two versions; the Model B, with 32 KB of memory and the full complement of ports, is the one that mattered. It was expensive — around £335 at launch, well over the price of a Sinclair; the ZX Spectrum in this gallery was the machine most families bought instead — and the government paid half the cost for schools. Acorn had estimated it might sell twelve thousand. It sold 1.5 million, and by the mid-1980s more than 80 per cent of British primary schools had one.

## Significance

The BBC Micro is the most thoroughly *educational* computer ever mass-produced, in a specific and unfashionable sense: it was designed on the assumption that the person using it would want to know how it worked.

BBC BASIC, written by Sophie Wilson, is the best BASIC of the eight-bit era and it is not close. It had named procedures and functions with local variables, `REPEAT…UNTIL` and `IF…THEN…ELSE`, long variable names, and — the thing no rival had — a **built-in 6502 assembler**, invoked with square brackets in the middle of an ordinary BASIC program. A child could write a game in BASIC, find one loop too slow, and rewrite that loop in machine code without leaving the language or buying anything. The distance from beginner to systems programmer, on this machine, was a pair of brackets.

The hardware matched the ambition. Eight screen modes, from teletext to 640×256; a four-channel sound chip; an analogue port, a user port, a 1 MHz bus and a printer port, all documented and all meant to be wired to things. Econet networked a classroom before networking was a consumer idea. And the Tube — a buffered interface that let a *second processor* take over as the main CPU while the 6502 handled input, output and the screen — was the most forward-looking port on any home computer, and the one that mattered most to what came next.

## What you're looking at

The machine exactly as it wakes up, in MODE 7: white teletext characters on black, and a prompt that expects you to type a program.

`BBC Computer 32K` is the memory count. `Acorn DFS` means the disc filing system is fitted — this is the school configuration, a Model B with the Acorn disc interface, not the bare cassette machine. `BASIC` is the language currently selected from the sideways ROM sockets. The `>` is BBC BASIC waiting.

Two things are worth knowing before you type. **CAPS LOCK is on** — the operating system switches it on at reset, because BASIC's keywords must be upper case, so unshifted letters arrive as capitals. And this keyboard is not a PC's: `"` lives on Shift+2 and `=` on Shift+`-`, as on any British machine of the period. The exhibit translates for you.

The type-in demo draws a fan of coloured lines in MODE 1. It is five lines long, and it is the shortest honest demonstration of what a million British children did with this machine after school.

## Legacy

Acorn's engineers finished the BBC Micro and immediately faced the question of what to put in it next. Nothing on the market satisfied them, so in 1983 Sophie Wilson and Steve Furber began designing a processor of their own — a small team, no prior CPU experience, and a deliberately reduced instruction set.

The first ARM silicon arrived on 26 April 1985 and ran correctly the first time it was switched on, which is not how first silicon usually behaves. Then somebody looked at the ammeter wired in series with the chip's supply. It read zero. The evaluation board had a fault and had never connected the processor's power pins at all: the ARM1 had been running on leakage current through its I/O pins. The design was so frugal that its designers had accidentally proved it before they meant to.

That processor was developed on a board plugged into this machine's Tube interface, and the gallery's `armeval` exhibit shows exactly that — the same emulated BBC Micro, with an ARM second processor fitted, announcing itself in blue where this one is white. Roughly thirty billion ARM cores now ship every year, and the line runs from the machine on this bench.

The other legacy is quieter and closer to home. A generation of British programmers learned on this keyboard, and when the Raspberry Pi Foundation set out in 2012 to do the same thing again — a cheap, open, deliberately unfinished computer for children — it was founded in Cambridge by people who had learned on a BBC Micro, and the first Pi ran an ARM chip.

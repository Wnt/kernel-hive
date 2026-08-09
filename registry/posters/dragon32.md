---
title: Dragon 32 — Microsoft BASIC, made in Wales
subtitle: 1982 · Dragon 32 (Microsoft BASIC)
hero: /posters/dragon32/desktop.webp
images:
  - src: /posters/dragon32/desktop.webp
    alt: The Dragon 32's power-on screen — (C) 1982 DRAGON DATA LTD, 16K BASIC INTERPRETER 1.0, (C) 1982 BY MICROSOFT, OK
    caption: Three lines and a prompt. The middle one is Microsoft's, the top one is Welsh, and the colour is the only one the machine's video chip was really good at.
---
## Origins

The Dragon came out of a toy company. Mettoy, the Northampton firm behind Corgi die-cast cars, set up Dragon Data in Port Talbot, South Wales, to build a home computer for the boom that Britain was in the middle of in 1982. The machine went on sale that August for just under £200, against a ZX Spectrum that cost less and a BBC Micro that cost more.

What Dragon Data actually built was Motorola's own reference design, taken almost as published: an MC6809E processor, an MC6847 video display generator, and the SAM chip that glued them to memory. Tandy had done the same thing a couple of years earlier and called the result the TRS-80 Color Computer, which is why the Dragon and the CoCo are near relatives that are not quite compatible — close enough that cassettes often crossed over, different enough in ROM that plenty did not.

The BASIC was bought in. Microsoft's 16K Extended Color BASIC is what the machine boots into, and the copyright line it prints is Microsoft's own.

## Significance

**The Dragon's processor was the best 8-bit chip anyone shipped.** The 6809 had two 8-bit accumulators that paired into a 16-bit one, two index registers, two stack pointers, hardware multiply and genuinely position-independent code — an architecture people who had used it spent the next decade missing. OS-9 Level 1, a real multitasking, multi-user operating system with a Unix-shaped filesystem, ran on this machine.

And then it was wired to the MC6847, which could manage nine colours, a 32-by-16 text screen, and no lower-case letters at all. Text that should have been lower case came out as inverse-video capitals. In a market where Sinclair was selling a colour attribute clash and Acorn was selling eighty columns of text to schools, the Dragon offered a superb processor behind a display that looked cheaper than either.

It sold respectably at first and then stopped. Dragon Data went into receivership in June 1984, less than two years after launch. The designs went to Eurohard S.A. in Spain, which built Dragons in Extremadura until 1987.

## What you're looking at

The machine's own power-on screen, untouched. Nothing has been typed and nothing has been loaded: this is what a Dragon 32 puts on a television about a second after the switch, and `OK` is Microsoft BASIC waiting for a line.

Getting here is less obvious than it looks. The emulated Dragon has an expansion slot, and the emulator's default for that slot is the disk controller — so a Dragon booted with no options at all comes up in DragonDOS, a disk operating system for hardware this exhibit does not have, and the three lines above never appear. The exhibit empties that slot deliberately. The build checks the result by reading the words off the screen, because the wrong screen is the same two greens as the right one.

The keyboard is the only input. It was one of the machine's genuine strengths — full-travel keys with a proper feel, at a time when the competition was selling rubber. What it is not is a PC's: the Dragon puts the double quote on shift-2, the colon and the asterisk together on one key, and its unshifted letters are the capitals, so the gallery translates every keystroke on the way in.

## Legacy

The Dragon is remembered in Britain out of proportion to how many were sold, partly because it was so nearly right. Dragon User ran for years after the company that named it had gone. A small, stubborn user community kept the machines running, and it is still going: new hardware, new software and an annual meet-up, four decades after Port Talbot stopped making them.

The wider lesson is one the 1982 market taught several times over. A home computer was judged on what it drew, not on what it computed, and the Dragon lost that argument with the finest processor in the room.

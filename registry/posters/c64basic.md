---
title: Commodore 64 — BASIC V2
subtitle: 1982 · Commodore 64 (BASIC V2)
hero: /posters/c64basic/desktop.webp
images:
  - src: /posters/c64basic/desktop.webp
    alt: The Commodore 64 power-on screen, light blue text on a dark blue background inside a light blue border, reading COMMODORE 64 BASIC V2, 64K RAM SYSTEM 38911 BASIC BYTES FREE, READY.
    caption: Sixty-four kilobytes of RAM, of which BASIC can see 38911 bytes. The rest sits underneath the ROMs and the chips, and belongs to whoever learns to reach it.
  - src: /posters/c64basic/rings.webp
    alt: Concentric diamond-shaped rings of solid blocks in all sixteen Commodore 64 colours, filling the screen inside a black border
    caption: Diamond Rings, one of this exhibit's example programs. BASIC V2 has no graphics commands, so the picture is a thousand POKEs into screen and colour memory.
---
## Origins

Commodore announced the 64 at the Consumer Electronics Show in January 1982 and shipped it that August for $595. The machine was built in a matter of months around two chips from MOS Technology, Commodore's own semiconductor company, both first meant for a games machine. The VIC-II, designed by Al Charpentier, drew sixteen colours, eight hardware sprites and finely scrolling backgrounds. The SID, by Bob Yannes, was a three-voice synthesizer with filters and envelopes that musicians took seriously. Because Commodore made its own chips, it could keep cutting the price, and it did.

The software was borrowed. The ROM holds Commodore BASIC V2, the version of Microsoft BASIC that Commodore had licensed for the PET in 1977 and already shipped in the VIC-20. It was compact and quick, and it knew nothing about the new chips. There is no command to draw a line, choose a colour or play a note.

## Significance

That gap gave the machine its character. To change the border colour you POKE 53280. To make a sound you write numbers into the SID's registers from 54272 upwards. To put a character on the screen without PRINT, you store its code in screen memory at 1024 and its colour at 55296. Commodore's own Programmer's Reference Guide answered with a complete memory map, and a generation of owners learned what an address is because BASIC gave them no other way in.

It also made the type-in listing a mass medium. Magazines such as Compute!'s Gazette printed page after page of games, utilities and music, and readers keyed them in by hand, line by line, hunting for the one mistyped DATA statement that broke the program. Estimates of C64 sales run from about 12.5 to 17 million, and it is generally counted as the best-selling single computer model ever made.

## What you're looking at

This is the museum's second Commodore 64. The other one boots GEOS, the graphical desktop that made the machine look like a small Macintosh. This one stops where every C64 started: the banner, 38911 BASIC bytes free, READY., and a blinking cursor. The emulated machine is a PAL breadbin of 1982, with the original VIC-II and the 6581 SID.

There is no mouse here; the keyboard is the instrument. Letters arrive as capitals, and with Shift they become the graphics characters printed on the key fronts. The code editor in the stage menu types a listing into the machine at its own pace. You can paste your own, or pick one of three short programs written for this exhibit: a picture made of POKEs, a border colour picker and a reaction game. The two Commodore manuals are linked there as well.

## Legacy

Commodore kept making the 64 until the company went bankrupt in 1994, twelve years after launch. Its READY prompt outlived the company. The one-line maze generator `10 PRINT CHR$(205.5+RND(1)); : GOTO 10` became the subject of a whole book from MIT Press in 2012. SID music, demos and new C64 games are still being written. For a great many programmers, this was the first prompt they ever typed at.

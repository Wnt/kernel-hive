---
title: Atari 800XL
subtitle: 1983 · Atari BASIC, a 1050 drive and a disk full of the software people ran
hero: /posters/atari800xl/desktop.webp
images:
  - src: /posters/atari800xl/desktop.webp
    alt: The MyPicoDos boot menu on a black screen, seven filenames listed with the first one highlighted
    caption: The station's boot disk as the 800XL finds it. MyPicoDos loads from the first sector of D1: and its boot screen is the menu — arrow keys move the bar, RETURN loads the highlighted file, and the last entry drops out to Atari BASIC.
  - src: /posters/atari800xl/loading.webp
    alt: The same menu with the file list cleared, the drive reading a program
    caption: A RETURN clears the list and the 1050 starts reading. A title takes about fifteen seconds to come in over the SIO bus, at the speed a real drive managed in 1983.
  - src: /posters/atari800xl/basic.webp
    alt: A blue screen with READY, the line PRINT 40+2, and the answer 42
    caption: Atari BASIC, revision C, in the machine's own ROM — no cartridge and no disk. The blue screen was the first thing an 800XL showed you when you switched it on with no disk in the drive.
---
## Origins

The Atari 8-bit line began as a games console. The machine that became the Atari 400 and 800 of 1979 was designed by a team under Jay Miner around three custom chips, and it is the chips rather than the 6502 that made it what it was. ANTIC is a coprocessor with its own instruction set: the programmer writes a *display list* in memory, a small program describing the screen line by line, and ANTIC executes it while fetching the picture. GTIA turns what ANTIC fetches into colour, from a palette of 128 rather than the sixteen a contemporary machine offered. POKEY does the sound in four channels, and also reads the keyboard, generates random numbers and clocks the serial bus. Nothing else on the American market in 1979 had hardware smooth scrolling and per-scanline colour changes, and for years afterwards an Atari 8-bit could put a moving, coloured screen up that competitors had to fake.

That serial bus, SIO, was the other unusual decision. Every peripheral — disk drive, printer, modem, cassette — hangs off one daisy-chained port, each with its own processor and its own address, so the computer never needed an expansion card to talk to a drive. It cost speed: an Atari 1050 disk drive holds 130 KB and reads it slowly, which is why the loads on this station take the time they do.

The 800XL of late 1983 is the version most people actually owned. It is the same architecture in a slimmer case, with 64 KB as standard and Atari BASIC built into ROM instead of sold as a cartridge, plus a Parallel Bus Interface on the back for expansion. When Jack Tramiel bought Atari's consumer division in 1984 and cut prices to fight the Commodore 64 he had just left behind, the 800XL was the machine he cut, and it sold heavily — in Britain, Germany and Poland especially, where it stayed in bedrooms well past the point the American market had moved on. The XE line replaced it in 1985. Jay Miner had already left; the machine he designed next was the Amiga.

## The software people actually ran

Star Raiders, written by Doug Neubauer in 1979, is on this disk because it is the reason the hardware exists in the form it does. It is first-person space combat with a galactic map, a fuel budget and enemies that hunt your starbases while you are elsewhere, and it ran on 8 KB of cartridge. It was the machine's launch showpiece and stayed the demonstration program salesmen reached for.

Boulder Dash, by Peter Liepa and Chris Gray for First Star Software in 1984, is an Atari 8-bit original — written here first and ported everywhere afterwards. Dropzone, Archer Maclean's 1984 rescue game, was also written for this machine, and is one of the few things on any 8-bit that moves as many objects as it does without tearing. River Raid was Carol Shaw's 1982 game for the Atari 2600, one of the first commercial titles credited to a woman programmer; Activision's 1984 conversion is the version on this disk.

The Last Word is the odd one out in time rather than in kind. Jonathan Halliday released it as freeware, an 80-column word processor for a machine whose screen is forty columns wide, which it manages by drawing the text itself in graphics. It stands in here for the AtariWriter-shaped half of the machine's life — the half that was homework and letters rather than caves and starbases.

The last entry on the menu is Atari BASIC, revision C. Selecting it pages the BASIC ROM back over the memory the disk menu was using and warm-starts the machine, which is the same `READY` an 800XL gave you in 1983 with the drive switched off. It is slow, it has no integer type and its error messages are numbers, and it is what a whole generation's first program was written in.

## Legacy

The Atari 8-bits were never the best-selling home computers — the Commodore 64 was — but they were the ones that established what custom silicon could do for a cheap computer. The display-list idea, the sprite-and-scroll hardware, the coprocessor that draws while the CPU thinks: those go from ANTIC through Jay Miner's Amiga chipset and, by way of a dozen imitations, into everything with a graphics chip in it. The machines themselves lasted, too. Atari sold the XE line until 1992, thirteen years after the 400, and the demoscene never quite stopped — there are still new games written for this hardware, on the same 64 KB, by people who were not born when it stopped being made.

---
title: Macintosh System 1.0 — Finder 1.0
subtitle: 1984 · Macintosh 128K · Motorola 68000, 128 KB, one 400 KB floppy
hero: /posters/macsys1/desktop.webp
images:
  - src: /posters/macsys1/desktop.webp
    alt: The Finder 1.0 desktop on a Macintosh 128K — a black-and-white 1-bit screen with a menu bar reading Apple, File, Edit, View, Special, a finely dithered desktop pattern, floppy icons labelled System Disk and Write/Paint at the top right, and the Trash at the bottom right
    caption: Finder 1.0 at rest, 37 seconds after power-on — the menu bar, two 400 KB floppies mounted as icons, and the Trash. Everything the Macintosh had in January 1984.
  - src: /posters/macsys1/welcome.webp
    alt: The Welcome to Macintosh startup box — a white rectangle across the dithered screen with a small 1-bit drawing of a Macintosh and its mouse at the left and the words Welcome to Macintosh
    caption: The greeting, twelve seconds in. Apple spent some of a 64 KB ROM on the idea that a computer should say hello.
---
## Origins

On **24 January 1984** Apple put a beige box on a stage and it said hello. The **Macintosh 128K** cost **$2,495** — a quarter of what the Lisa had cost a year earlier — and it ran the software on this screen: **System 1.0** and **Finder 1.0**, a desktop with icons, a menu bar pinned to the top of the display, overlapping windows, a one-button mouse, and a wastebasket.

None of that was new. Xerox PARC had built it, and Apple's own **Lisa**, the exhibit one year earlier in this hall, had shipped a more complete version of the same desktop in 1983 for $9,995. What was new was that it *fit*. The Lisa had a megabyte of memory, protected memory, preemptive multitasking and a 5 MB hard disk. The Macintosh had **128 KB of RAM**, a **68000 at 7.8336 MHz**, **64 KB of ROM**, no hard disk, and a single **400 KB** Sony 3.5-inch floppy drive. Everything the Lisa did with hardware, the Macintosh had to do with cleverness or not do at all.

The system software is the record of those choices. The entire release — System, Finder, desk accessories, fonts — was squeezed into roughly **216 KB**, so that it, a program and your documents could share one floppy; the **Finder itself was about 42 KB**. Most of what a modern reader would call the operating system was not on the disk at all but burned into that **64 KB ROM**: **QuickDraw**, Bill Atkinson's graphics library, together with the window, menu, event and dialog managers Apple called the **Toolbox**. Every application drew through the same code, which is why every Macintosh application looked and behaved alike from the first day — a consistency the PC world would argue about for another decade.

## What it could not do

The honest half of this exhibit is the list of things System 1.0 does *not* have, because each absence explains a later version of the Macintosh.

There is **no hierarchical file system**. The disk is **MFS**, the Macintosh File System, and MFS is flat: every file on a volume lives in one list. The folders you can make and drag on this desktop are an illusion the Finder maintains in a hidden `Desktop` file, and they evaporate the moment you leave it — open a document from inside MacWrite and the dialog offers you every file on the disk in one long scroll, folders or not. Real directories arrive with **HFS** in 1985.

There is **no multitasking**. One application runs; to start another, you quit the first. The only things that live alongside it are the **desk accessories** under the Apple menu — Calculator, Alarm Clock, Note Pad, Scrapbook, Control Panel, Key Caps and the Puzzle — which are not applications at all but small code resources the system draws into a window on top of whatever is running. That is the entire story of concurrency in 1984. Switcher follows in 1985, MultiFinder in 1987, and genuine preemption not until Mac OS X in 2001.

And there is **one floppy drive**. With the system disk in the slot and a document disk in your hand, copying a file means the machine ejecting and asking for the other disk, again and again, in a ritual every early Macintosh owner remembers with feeling.

## Why this screen matters

The display is **512 by 342 pixels, one bit deep**, on a 9-inch tube — and it is **72 dots per inch on purpose**. A typographic point is 1/72 of an inch, so one pixel here is exactly one point on paper coming out of an ImageWriter. That arithmetic is what the word **WYSIWYG** was standing on, and it is why a machine with no colour, no hard disk and 128 KB of memory is the one that started desktop publishing. **MacPaint 1.0** and **MacWrite 1.0**, both bundled with the machine and both on the second disk mounted on this desktop, exist to prove it: a bitmap painted at printer resolution, and a document with proportional fonts and styles shown on screen the way it will print.

There is no colour to miss, either. Look closely at the desktop pattern — it is a 50% checkerboard of single pixels, and the grey you think you see is your eye doing the work. The whole visual language of the early Macintosh is built out of that trick.

## What you're looking at

An emulated **Macintosh 128K** — Motorola 68000 at 7.8336 MHz, 128 KB of RAM, the 64 KB `342-0220-A`/`342-0221-A` boot ROM, and the IWM floppy controller driving **two** 400 KB single-sided drives. The keyboard is the **M0110**, which on a real Macintosh is a separate little computer: an Intel 8021 with its own firmware, talking to the main board over a coiled telephone cord. The emulator runs that MCU's ROM too.

In the first drive is the January 1984 **Macintosh System Disk** — System 1.0, the version string inside it reads 0.97, with Finder 1.0. In the second is the companion **Write/Paint** disk with MacWrite 1.0 and MacPaint 1.0. Both mount as icons at the top right of the screen; double-click one and its window opens. There is no hard disk, because in 1984 there was none to have.

The screen is the Mac's own 512 by 342 pixels doubled to 1024 by 684 and letterboxed, so no pixel is ever guessed at — what you see is the 1-bit raster exactly as the video circuit drew it.

This Macintosh is not on a network and never was. AppleTalk was still a year away, TCP/IP was a research network, and the exhibit does not pretend otherwise: there is no browser and no chat here, only the machine and two floppies.

## Legacy

The 128K machine was underpowered on the day it shipped, and everyone knew it; the 512K "Fat Mac" followed that September, and the Macintosh Plus, with HFS and SCSI, in 1986. But the line from this desktop to the two later Macintosh exhibits in this museum — **System 7.5.3** of 1996 and **Mac OS 9** — never breaks: the same menu bar, the same Finder, the same Command-key chords, the same Trash in the same corner. When Apple finally replaced the foundations in 2001 it kept the surface. What it kept is what you are looking at.

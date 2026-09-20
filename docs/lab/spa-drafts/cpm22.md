# Exhibit draft — CP/M 2.2 on a Kaypro

> Prep branch: `cpm22` · tracking issue: #55  
> Intended destination: `registry/posters/cpm22.md`.

---
title: CP/M 2.2 — the A> prompt before DOS
subtitle: Early 1980s · Kaypro II · Z80 business computing, floppy disks and WordStar
hero: /posters/cpm22/desktop.webp
images:
  - src: /posters/cpm22/desktop.webp
    alt: A Kaypro-style green phosphor text display showing the CP/M A greater-than prompt and a directory or WordStar session
    caption: Before the IBM PC made DOS the default, CP/M was the portable operating environment shared by a whole market of incompatible microcomputers.
---

## Origins

**CP/M** was created by Gary Kildall at Digital Research in the 1970s for Intel 8080 and later Z80 microcomputers. Its crucial idea was portability. Hardware-specific details were pushed into a small **BIOS** layer while the command processor and disk operating system could remain largely the same.

That mattered because the early microcomputer market had no single standard machine. S-100 systems, business computers and later all-in-one machines could look completely different inside while presenting the same `A>` prompt and running the same application software.

**CP/M 2.2** became the version most closely associated with that era.

## Significance

The vocabulary later PC users took for granted is already visible here: drive letters, command-line programs, filenames with short extensions and software distributed on floppy disks.

The important difference is that this world predates the IBM PC's victory. A Kaypro owner could run **WordStar**, spreadsheets, database tools and programming languages on a Z80 machine whose hardware was not IBM-compatible at all.

CP/M also sits directly behind the DOS story. When IBM entered the personal-computer market, CP/M was one of the obvious operating-system choices. MS-DOS and PC DOS ultimately became the standard instead, but they entered a market whose expectations CP/M had already shaped.

## What you're looking at

The target hardware is a **Kaypro II**, an all-in-one portable business computer with a Z80 processor, floppy drives and a built-in text display. It should boot CP/M 2.2 directly to the `A>` prompt.

From there, `DIR` shows the disk and **WordStar** demonstrates why this was a working office machine rather than a hobbyist command prompt. The exhibit is keyboard-only because the original computer was keyboard-only.

The final station paragraph should name the exact Kaypro model, ROM revision and disk images after MAME compatibility is proven.

## Legacy

CP/M did not survive the IBM-compatible PC becoming the center of business microcomputing, but much of its software culture did. WordStar, dBASE and other application families crossed into DOS, and the drive-letter command-line world remained familiar for decades.

The museum already lets a visitor reach CP/M Plus through the Commodore 128. This dedicated station tells the story CP/M actually owned: business computing before DOS.

## Sources

- MAME Kaypro software list: https://sources.debian.org/src/mame/0.251%2Bdfsg.1-1/hash/kaypro.xml
- Kaypro CP/M disk archive: https://oldcomputers.dyndns.org/public/pub/archiv/maslin/masl-dsk/images-97/kpro/index.html

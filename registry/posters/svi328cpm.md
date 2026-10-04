---
title: Spectravideo SV-328 — CP/M
subtitle: 1984 · CP/M-80 2.24 · SV-601, disks and 80 columns
hero: /posters/svi328cpm/desktop.webp
images:
  - src: /posters/svi328cpm/desktop.webp
    alt: Spectravideo SV-328 CP/M prompt on its green 80-column display
    caption: The expanded SV-328 starts CP/M from a fresh disk image.
---

## Origins

Spectravideo designed the **SV-328** of 1983 to expand beyond the BASIC prompt. Its manual pictured a seven-slot expansion unit carrying disk, memory, serial and display interfaces. Adding floppy drives and an 80-column card gave the same keyboard computer the equipment for a different working environment: **CP/M**.

Digital Research's operating system supplied disk files, commands and a common interface for programs on many 8080 and Z80 computers. Manufacturers adapted its hardware-dependent routines to their own machines. Spectravideo's version brought that approach to a computer whose unexpanded form started in BASIC.

## Significance

The change is visible in the prompt. BASIC's `Ok` waits for a language statement; CP/M's `A>` waits for an operating-system command or the name of a program on disk. A programming language can now be something you load, use and leave, alongside other disk-based tools.

The separate 80-column display matters as much as the disks. It gives text twice the horizontal room of a 40-column screen, making longer lines and wider tables practical. Spectravideo's SV-806 card provided this through its own display hardware. This exhibit shows how expansion could change the work a home computer was equipped to do without replacing its main processor.

## What you're looking at

The green screen belongs to an **SV-806 80-column card** attached to a PAL SV-328 through the **SV-601 expansion unit**. An SV-801 controller provides two 5¼-inch floppy drives; drive A holds the system disk and drive B is empty.

The startup banner reads **Spectravideo CP/M-80 version 2.24 / For SV-605B**. That is the software package's own identification; the expansion unit represented here is the SV-601. The exhibit's disk adds Microsoft's **BASIC-80 5.21** and a museum-written `WELCOME.TXT` to the preserved system disk.

### Try it

At `A>`, type `DIR` to list the disk or `TYPE WELCOME.TXT` to read the welcome file. Open **Controls** and choose **Type in a demo program** from this CP/M prompt. It loads BASIC-80, clears any BASIC program and enters a short listing. Allow time for BASIC to load; when the final `RUN` appears, press Enter to print the title and the squares of 1 through 5.

Inside BASIC, `LIST` shows the program and `SYSTEM` returns to CP/M. To try disk storage, enter `SAVE "VISITOR"`, then `NEW`, `LOAD "VISITOR"` and `LIST`. The saved listing is available during this session. Use **Ctrl+C** to interrupt a CP/M command.

**Restore to golden snapshot** resets the exhibit to `A>` with a fresh system disk. It discards both memory changes and files you saved, including `VISITOR.BAS`. The exhibit runs offline.

## Legacy

Beside the unexpanded SV-328, this station makes the move from a built-in language to a disk operating system tangible. The keyboard and Z80 remain, but files and separately loaded programs reorganize the session. CP/M's separation of common software services from machine-specific hardware helped make that pattern available across different manufacturers' computers.

## Sources

- [Spectravideo SV-328 User's Manual](https://hansotten.file-hunter.com/uploads/files/svi328usermanual.pdf), expansion overview and peripheral map.
- [Spectravideo SV-806 80-Column Card User's Manual](https://hansotten.file-hunter.com/uploads/files/SVI-806_80ColumnUsersManual.pdf).
- [Digital Research CP/M Operating System Manual](https://hansotten.file-hunter.com/uploads/files/CPMOperatingSystemManual.pdf), features, commands and hardware adaptation.

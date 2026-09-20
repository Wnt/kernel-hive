# Exhibit draft — RISC OS 3.x on Acorn Archimedes

> Prep branch: `riscos3` · tracking issue: #47  
> Intended destination after the station scaffold exists: `registry/posters/riscos3.md`  
> Scene-specific hardware and screenshot wording should be finalized from the golden framebuffer.

---
title: RISC OS 3.11 — Acorn Archimedes
subtitle: Early 1990s · Acorn's ARM desktop — the icon bar, Filer and !applications
hero: /posters/riscos3/desktop.webp
images:
  - src: /posters/riscos3/desktop.webp
    alt: RISC OS desktop with the icon bar along the bottom edge, filer windows open above it, and Acorn desktop applications visible
    caption: RISC OS at the desktop: drives, applications and system tools live on the icon bar instead of in a Start menu, Dock or desktop folder.
---

## Origins

RISC OS grew out of the same Acorn engineering line that produced the BBC Micro and the first **ARM** processor. Acorn had designed ARM because the company wanted a fast, simple processor for the generation after the 6502. The first Archimedes machines arrived in 1987; their early desktop software was called **Arthur**, and the system was renamed **RISC OS** as the desktop and filing environment matured.

That lineage matters here because Kernel Hive already shows both ends of the beginning: the **BBC Micro**, whose 6502 generation made Acorn a fixture in British schools, and the **ARM Evaluation System**, built around the new processor Acorn created to escape the limits of that generation. RISC OS is what happened when that processor became a personal computer platform rather than an experiment.

RISC OS 3.x is the early-1990s form of the system: mature enough to show the desktop people remember, but still unmistakably an Acorn machine rather than a modern compatibility port.

## Significance

The RISC OS desktop does not organize itself like Windows or the Macintosh. Its center of gravity is the **icon bar** along the bottom edge. Disks, running applications and system tools appear there; clicking different mouse buttons on the same object intentionally does different things. The **Filer** presents directories as icon windows, but applications themselves are often directories whose names begin with an exclamation mark — `!Draw`, `!Paint`, `!Edit` — bundles before application bundles became ordinary elsewhere.

The operating system and the machine were designed together. ARM's low power and compact instruction set would eventually escape Acorn and dominate phones, embedded devices and then personal computers on a global scale. RISC OS shows ARM before that future was obvious: not as an invisible chip inside something else, but as the processor underneath a complete desktop computer.

For British visitors it is also a school-computing story. Acorn's machines occupied classrooms and laboratories that elsewhere would have held Apple IIs, IBM PCs or Commodores, and RISC OS carried that line into the graphical era.

## What you're looking at

The intended exhibit is a period Acorn Archimedes/A-series machine running **RISC OS 3.11**, opening directly onto the native desktop. The important visual cues are the icon bar, Filer windows and one or two characteristic `!applications` such as Draw or Paint.

The mouse should be used as RISC OS expected it to be used, including its three-button vocabulary where practical. Keyboard shortcuts are useful, but this is a desktop whose personality is in pointing, dragging and opening objects.

The final station paragraph should name the exact emulated Acorn model, RAM, display mode, ROM set and applications only after those are fixed by the golden.

## Legacy

Acorn's computer business eventually disappeared from the mainstream, but its processor architecture did the opposite. ARM became the dominant architecture of mobile computing and later returned to laptops and desktops at enormous scale. RISC OS survived too: its source and community continued long after the original Archimedes and RiscPC era.

That makes this screen a useful historical inversion. Today ARM is everywhere and usually invisible. Here it is the thing that makes the computer unusual, running the desktop built for it.

## Sources

- MAME RISC OS driver notes: https://wiki.mamedev.org/index.php?title=Driver:RiscOS
- RISC OS 3.10/3.11 reference material: https://www.riscos.com/riscos/310/index.php
- Arculator emulator project: https://github.com/dboddie/arculator

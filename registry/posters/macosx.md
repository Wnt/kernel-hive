---
title: Mac OS X — Aqua arrives
subtitle: 2003 · Mac OS X 10.3 Panther · PowerPC G4 · Unix underneath, the Dock and Finder on top
hero: /posters/macosx/desktop.webp
images:
  - src: /posters/macosx/desktop.webp
    alt: An early Mac OS X Aqua desktop with the translucent menu bar, striped windows, Finder and the magnifying Dock along the bottom
    caption: Aqua made Apple's new operating-system foundations visible: translucent controls, sheets, the Dock and a Finder rebuilt on top of Unix.
---

## Origins

By the mid-1990s the classic Macintosh operating system had reached the edge of what its original architecture could comfortably support. Apple tried several internal replacement projects and then changed direction completely: in 1996 it bought **NeXT**, bringing NeXTSTEP's Mach/BSD foundations and Steve Jobs back into the company.

Kernel Hive already shows that transition in pieces. **NeXTSTEP** is the system Apple bought. **Rhapsody** is Apple's first attempt to turn it into a Macintosh successor. **Mac OS 9** is the classic system still shipping while the replacement was being finished.

Mac OS X is where those lines finally meet.

Apple unveiled **Aqua** in January 2000. Mac OS X 10.0 shipped on 24 March 2001 with a Darwin/Unix foundation, protected memory and preemptive multitasking underneath an interface that was deliberately unlike both classic Mac OS and NeXTSTEP.

## Significance

The operating-system architecture changed almost completely while Apple tried to preserve the idea of using a Macintosh.

The menu bar stayed at the top. The Finder kept its name. But processes were no longer cooperative guests in one fragile address space; the system underneath was built from Mach, BSD and Apple's XNU kernel. Unix tools lived a Terminal window away.

Aqua announced the break visually. Windows used luminous controls, pinstripes and transparency. Dialogs could descend as **sheets** from the window they belonged to. The **Dock** combined running applications, launchers, documents and minimized windows into one animated strip.

This was not just a new skin. It was Apple teaching existing Mac users a new operating system while convincing them it was still their Mac.

## What you're looking at

The exhibit is **Mac OS X 10.3 Panther** on an emulated PowerPC G4. Panther was chosen by measurement, not preference: 10.2 Jaguar panics on this machine inside its ATAPI CD driver, while 10.3 boots the same hardware straight into Aqua.

The scene should make the transition obvious: Finder open, Dock visible, and a Terminal window available so the visitor can see that the glossy desktop and a Unix command line are the same machine.

PLACEHOLDER: the exact machine profile, RAM and QEMU device set go here once the golden is baked and measured (see `docs/lab/MACOSX-WAVE.md`).

## Legacy

Every modern Mac descends from this architecture. The processor changed from PowerPC to Intel and then to Apple silicon; the visual design changed repeatedly; many frameworks came and went. The fundamental split established here — Darwin/XNU underneath, the Macintosh experience above it — survived all of them.

Placed between Rhapsody and a modern macOS poster, early Mac OS X turns Apple's late-1990s rescue plan into a sequence you can actually use.

## Sources

- Apple, “Apple Unveils Mac OS X” (5 Jan 2000): https://www.apple.com/newsroom/2000/01/05Apple-Unveils-Mac-OS-X/
- Apple, “Mac OS X to Ship on March 24” (9 Jan 2001): https://www.apple.com/newsroom/2001/01/09Apples-Mac-OS-X-to-Ship-on-March-24/
- PowerPC QEMU notes: https://www.emaculation.com/doku.php/ppc-osx-on-qemu-for-osx

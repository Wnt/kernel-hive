---
title: Palm OS — the pocket computer that expected a pen
subtitle: 1998 · Palm III · launcher, Graffiti and stylus-first computing
hero: /posters/palmos/desktop.webp
images:
  - src: /posters/palmos/desktop.webp
    alt: Palm OS on a small portrait handheld display with monochrome application icons and the Graffiti writing area below
    caption: Palm OS was designed around a pocket screen, a stylus and a few seconds of attention — not around shrinking a desktop computer.
---

## Origins

Palm's breakthrough was not inventing the handheld computer. It was deciding what to leave out.

The first **PalmPilot** organizers appeared in 1996, small enough for a shirt pocket and focused on a tight set of tasks: calendar, contacts, notes and to-do lists. Instead of a miniature desktop with tiny menus, Palm built an interface around a stylus and a fixed writing area. **Graffiti** turned simplified pen strokes into characters, and **HotSync** made the handheld an extension of the computer on your desk rather than an isolated gadget.

Palm OS evolved quickly through the late 1990s. The **Palm III**, launched in 1998, refined the same basic idea rather than replacing it: press a hardware button and the right application is there; tap an object and it opens; write in the Graffiti area and text appears.

## Significance

Palm OS established the interaction grammar of the successful PDA. The machine was expected to wake instantly, preserve its state, and let you complete a small task before a desktop PC would have finished booting.

That sounds ordinary now because phones inherited the expectation. It was not ordinary then. Contemporary handhelds often tried to reproduce a Windows-like desktop or carried a laptop-style keyboard. Palm made the opposite bet: design around the constraints of the pocket.

The result created its own software ecosystem. Thousands of small Palm applications treated the organizer as a real programmable computer, while synchronization made address books and calendars portable years before cloud accounts made that invisible.

## What you're looking at

This exhibit is a **Palm III**, the MC68328 ("DragonBall")-based handheld that established the classic Palm shape, running **Palm OS 3.3**. The firmware image behind this exhibit is the **French-language release** — the only byte-exact Palm OS 3.x ROM this wave could verify against MAME's `palmiii` driver inside its time budget; an English dump exists on the usual preservation archives but did not match any ROM option this emulator build recognizes. The interaction model is identical regardless of language: application icons, Graffiti, and the four hardware quick-launch buttons for Date Book, Address Book, To Do List and Memo Pad.

The pointer in the browser stands in for the stylus. Tap, drag and write; this is an operating system where accurate absolute pointer input matters more than mouse acceleration or double-click timing. Unlike most other machines in this collection, Palm's touch input is not a mouse pretending to be a pen — it is a genuine absolute digitizer reading, and this exhibit drives it with a matching direct-write pointer route built for this station.

## Legacy

Palm OS sits between two worlds in this collection. Behind it are organizers and pen computers such as Psion and Newton; ahead are webOS, Symbian and the modern smartphone systems.

Palm itself would later abandon this software foundation and build webOS, but the more important inheritance is behavioral: instant wake, small focused applications, synchronization, and the assumption that a pocket computer is something you consult continuously rather than sit down to use.

## Sources

- Palm OS 3.3 ROM preservation, PalmDB "palm-roms-complete" collection: https://palmdb.net/app/palm-roms-complete
- MAME `palmiii` driver: `src/mame/palm/palm.cpp` (mainline MAME)

---
title: ETH Native Oberon 2.3.6
subtitle: 1999 · Wirth & Gutknecht's Oberon System 3 · the desktop that is also the source code
hero: /posters/oberon/desktop.webp
images:
  - src: /posters/oberon/desktop.webp
    alt: The Native Oberon Gadgets desktop at 1280x1024 — a flat grey field with two tiled text viewers along the top right, System.Log showing a one-line boot banner and System.Tool below it listing command words like Compiler.Compile and System.Directory, an arrow pointer resting in the empty grey user track
    caption: The Gadgets desktop at rest — every word you see is either a note or a command, and the mouse decides which.
---
## Origins

Niklaus Wirth built Pascal, then Modula-2, then, with Jürg Gutknecht at ETH
Zurich, an entire third act: a language called Oberon and an operating
system of the same name to run it, designed together from 1985 as one small
system rather than a language bolted onto somebody else's kernel. The whole
thing — kernel, compiler, file system, and a windowing desktop years before
most PCs had one worth using — first ran on the Ceres workstation the two of
them also had built. By the mid-1990s ETH had ported it to bare PC hardware
as **Native Oberon**, and in 1999 released 2.3.6: no host operating system
underneath, no BIOS calls once it is running, no DOS. Oberon boots straight
into itself.

The desktop you're looking at is **System 3**, Oberon's second-generation
UI, built around a toolkit called **Gadgets**. It abandoned the
overlapping-window metaphor Oberon's first desktop had used for something
stranger and, in its own way, more direct: a tiled surface of text and
components where the boundary between "document" and "program" barely
exists.

## Significance

Oberon is famous for a number: the whole system — compiler, linker, file
system, network stack, windowing, and the applications — fit in about 200,000
lines of Oberon source, written and maintained by a handful of people. Wirth
and Gutknecht treated that as the point, not a limitation: every layer stays
legible to one person, and the language enforces enough discipline (strong
typing, no unchecked pointer arithmetic, garbage collection from day one)
that the whole stack can be this small and still be robust.

The interaction model is the part that still surprises people. There is no
Start menu, no icon you double-click, no OK button. The desktop is a tiling
arrangement of text viewers, and text **is** the interface: type or read a
command word like `Compiler.Compile` or `System.Directory` anywhere on
screen, aim the pointer at it, and the **middle** mouse button runs it as
code. The left button just places a text caret; the right button selects a
range. A menu in Oberon is not a widget — it is a paragraph you could also
edit, comment on, or delete. That collapse of "document" and "program" into
one thing, browsable and executable in place, is the idea Oberon is
remembered for, and one modern computing never fully adopted.

## What you're looking at

An emulated PC running **ETH Native Oberon 2.3.6**, released 13 May 1999,
booting directly off its own IDE partition to the **Gadgets** desktop at
1280x1024 — no host OS, no boot loader handing off to anything else. The
right-hand track holds two tiled viewers: `System.Log` at top, echoing the
one-line boot banner, and `System.Tool` below it, a standing menu of command
words — `Script.Open`, `Compiler.Compile`, `System.Directory`,
`NetSystem.Tool`, `Desktops.OpenDoc` — that you run with a middle click. The
rest of the screen is empty grey desk, ready for whatever viewer you open
next.

This Oberon carries its own TCP/IP stack, NetSystem, and its own Ethernet
driver — 1999 PCs plugged into real networks, and this one was built to. The
mouse here is a plain three-button PS/2 device, tracked one-to-one with no
acceleration, because that is exactly what the system itself expects: an
arrow, three buttons, and text that means what it says.

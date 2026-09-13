---
title: ETH Native Oberon
subtitle: 1999 · Wirth's whole operating system, in twelve thousand lines, running on bare PC hardware
hero: /posters/oberon/desktop.webp
images:
  - src: /posters/oberon/desktop.webp
    alt: The ETH Native Oberon 2.3.6 screen — a black-on-white tiling display split into two vertical tracks, the narrow System track on the left carrying the System log and a directory listing, the wide User track on the right holding an open text viewer, every window a plain framed panel of text with a title bar of command words
    caption: The rest state. Two tracks, no overlapping windows, no menus — the words along each viewer's title bar are the commands, and you run one by clicking it with the middle mouse button.
---
## Origins

**Oberon** is two things with one name, and that is the point. In 1985 **Niklaus
Wirth** — already the author of Pascal and Modula-2 — and **Jürg Gutknecht**
set out at **ETH Zürich** to build a programming language and an operating
system together, each shaped by the other, on a workstation of their own design
called the **Ceres**. The result was published in 1992 as *Project Oberon*, a
book that prints the entire system as source: compiler, kernel, file system,
display, text editor, network. The whole thing is roughly **twelve thousand
lines of code**.

The system kept going after the book. **Gutknecht's System 3**, through the
1990s, added **Gadgets** — a persistent-object toolkit that turned the screen
into a document-centric desktop where a button, a text or a running panel is an
object you can keep, copy and store rather than a widget an application owns.
And from 1994 **Pieter Muller** wrote **Native Oberon**: the same system with
its own PC device drivers, booting from the disk and running directly on
commodity Intel hardware with no host operating system underneath it at all.
This exhibit is **release 2.3.6, dated 1999**, under the ETH Oberon licence.

## Significance

Oberon's user interface is the most radical idea in this hall, and it is barely
an interface at all: **any text on the screen is executable**. Type
`Edit.Open Hello.Mod` anywhere — in a log, in a document, in the middle of a
sentence you are writing — point at it and click the **middle mouse button**,
and it runs. There are no menus and no dialog boxes, because a command is just
a module name, a dot and a procedure name, written wherever it is convenient to
write it. The title bar of every viewer is a row of such words. Documentation
is live: the manual page for a tool contains the commands that operate it.

The display follows the same logic. The screen is divided into vertical
**tracks** — a narrow *System* track for the log and directories, a wide *User*
track for work — and viewers tile within them. Nothing overlaps, nothing is
hidden, and there is no window to drag. The mouse has **three buttons and
Oberon uses all three**, plus *interclicks*: press one button, and while it is
down click another to change what the first one means. The left button places
a text caret, the middle button runs the command word under the pointer, and
the right button selects a range — that is how copy, paste and delete are
expressed without a single menu.

Underneath, the kernel is garbage-collected and the language is type-safe, so a
module can be compiled and loaded into the running system in a second without a
link step or a reboot. Wirth's argument was that a system small enough to read
end to end is a system you can actually trust — and *Project Oberon* is the only
operating system in this museum that a single person has plausibly read in full.

## What you're looking at

An emulated PC running **ETH Native Oberon 2.3.6**, released 13 May 1999,
booting directly off its own IDE partition to the **Gadgets** desktop at
1280x1024 — no host OS, no boot loader handing off to anything else. One
track holds two tiled viewers: `System.Log` at top, echoing the one-line boot
banner (`ETH Oberon System 3 / PC Native 2.3.6 (13 May 1999)`), and
`System.Tool` below it, a standing menu of command words — `Script.Open`,
`Compiler.Compile`, `System.Directory`, `NetSystem.Tool`, `Desktops.OpenDoc`
— that you run with a **middle click**. The rest of the screen is empty grey
desk, the User track, ready for whatever viewer you open next. A **left
click** anywhere in a text sets the caret there, and typing inserts text at
it — try it in `System.Log`.

The mouse here is a plain three-button PS/2 device, tracked at a fixed scale
with no acceleration, because that is exactly what the system itself
expects: an arrow, three buttons, and text that means what it says.

## Legacy

Oberon never had a mass market, and it was never meant to have one. It had
students: a generation of them at ETH learned what an operating system is by
reading this one, and Wirth's compiler course shipped with a compiler small
enough to fit in the same book. The line continued as **Active Oberon** and
then **A2** (once called Bluebottle), a version of the same system rebuilt
around active objects and symmetric multiprocessing, still developed long after
1999.

Its influence is easiest to see by contrast. Everything else in this hall grew
by accumulation — layers, compatibility, megabytes. Oberon is the argument that
the alternative was always available: build the language and the system
together, keep both small enough to understand, and you get a machine whose
every part can be explained on a single afternoon.

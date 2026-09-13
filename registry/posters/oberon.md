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
down click another to change what the first one means. That is how copy, paste
and delete are expressed without a single menu.

Underneath, the kernel is garbage-collected and the language is type-safe, so a
module can be compiled and loaded into the running system in a second without a
link step or a reboot. Wirth's argument was that a system small enough to read
end to end is a system you can actually trust — and *Project Oberon* is the only
operating system in this museum that a single person has plausibly read in full.

## What you're looking at

A PC booting Native Oberon 2.3.6 straight from its own disk. There is no DOS,
no Linux and no BIOS-hosted runtime beneath it: Oberon's own drivers own the
display, the keyboard, the mouse and the disk.

The screen is black on white, two tracks wide. The **System track** on the left
carries the **System log**, where every command reports; the **User track** on
the right is where texts and tools open. Click a command word with the **middle
button** to execute it — `System.Directory *.Mod` to list the sources,
`Edit.Open <name>` to open a text, `Desktops.OpenDoc` to open a Gadgets
document. Anything you type becomes a command the moment you middle-click it,
which is worth trying once just to feel how strange and how obvious it is.

The **Gadgets** desktop that System 3 added lives one command away, and it
inverts the usual arrangement: the objects persist and the applications are
incidental. The exhibit restores its pristine 1999 disk on reset, so whatever
you compile belongs to your visit.

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

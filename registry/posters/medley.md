---
title: Interlisp Medley
subtitle: 1987 · Xerox PARC's Lisp machine desktop, on the Interlisp project's own virtual machine
hero: /posters/medley/desktop.webp
images:
  - src: /posters/medley/desktop.webp
    alt: Medley's default screen at 1024x768 — the XCL Exec listener at the top-left, the Medley logo at the top-right, the one-line status bar across the top
    caption: The rest state — the Exec listener after the greet file has run, and the Medley logo. Every window here is a Lisp object you can inspect.
---
## Origins

Xerox PARC built Interlisp through the 1970s as the programming environment
of its AI group, and in 1981 moved it onto the same microcoded "D-machines"
(the Dolphin, Dorado and Dandelion) that ran the Star office system. That
port, **Interlisp-D**, put the whole Lisp system behind a bitmap display and a
three-button mouse: the editor, the debugger and the inspector became windows,
and the operating system disappeared into Lisp itself. There is no shell and
no file manager, because there is nothing that is not already a Lisp object.

**Medley** is the name of the 1987 release, the last one Xerox shipped before
the environment left the company, first to Envos and then to Venue, where it
was maintained into the 1990s on Sun workstations through **maiko**, a
byte-code virtual machine written in C so the system no longer needed Xerox
hardware. In 2020 the original developers and the Computer History Museum's
software preservation group revived it as the open-source **Interlisp
project**, and this is that revival.

## Significance

Interlisp-D is where a good deal of the modern development environment was
first tried in one place. **SEdit** and its predecessor DEdit edit programs as
structures, not text; the **Inspector** opens any object and lets you change
its fields while the program is still running; the **Break** window turns an
error into a live conversation with the stack, from which you fix the
function and continue. **NoteCards**, written in it in 1985, was one of the
first hypertext systems. **Rooms** (1986) is the ancestor of every virtual
desktop. Xerox's own 1108 sold in the low thousands and Medley never had a
mass market, but the ideas, and the people, went on into Smalltalk, Emacs
and the IDEs that came after.

## What you're looking at

The screen you see is Medley's default greet at 1024x768: the **Exec**, a
listener that speaks both Interlisp and Common Lisp (the `XCL` in its title),
with the transcript of its startup file, and the Medley logo. Click in the
Exec and type a form; the demo defines a Fibonacci function and maps it over
a list. Right-click on the grey background for the background menu, which
opens every other tool: the Inspector, SEdit, TEdit, Sketch. Reset returns the
pristine release image in about two seconds.

Nothing under this exhibit is an emulated computer. **maiko** is a native
Linux program that renders the Lisp display straight into an X window, so the
museum captures that window and forwards the pointer and keys to it. It is
the first station in the lineup with no machine underneath at all, which is
the most honest way to show an environment that was always more software than
hardware.
